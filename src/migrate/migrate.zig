//! Version-tagged migrations: validate, apply, chain, and the public byte/snapshot/world wrappers
//! (PLAN.md Phase 8, §12).
//!
//! A `Migration` is a declared, inspectable reconciliation of one schema version into the next: an
//! ordered list of `Op`s plus the exact `target_fingerprint` it must produce. `validateMigration` proves
//! — BEFORE any byte moves — that the declared ops EXACTLY cover the per-Kind fingerprint delta (every
//! added/dropped/resized kind has a covering op, no op addresses an unchanged kind, and every declared
//! width matches the target). `apply` folds the ops over a schema-agnostic `Image` (image.zig), recomputes
//! each row's mask against the NEW fingerprint, bumps the schema_version, and ASSERTS the produced schema
//! equals the target (`serialize.Error.SchemaMismatch` otherwise) — so a wrong op list can never silently
//! land a malformed image. `Chain` folds migrations left-to-right with a `from_version == running` gate.
//! The public wrappers terminate in `serialize.readWorld(R_target)` via the same `Parts -> fromParts`
//! ownership handoff `snapshot.restore` uses (no outer errdefer over the consumed Parts — D-memory).

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const worldmod = @import("../world.zig");
const snapshotmod = @import("../snapshot.zig");
const image = @import("image.zig");
const Image = image.Image;
const KindFp = image.KindFp;
const KindRecord = image.KindRecord;
const RowRecord = image.RowRecord;
const fingerprint = @import("fingerprint.zig");
const ops = @import("ops.zig");
const Op = ops.Op;

/// The structural-validation errors `validateMigration` may raise (a superset of these, plus the wire/
/// alloc errors, is `MigrateError`).
pub const ValidateError = error{ MigrationIncomplete, MigrationSpurious, BadDefaultWidth };

/// Everything a migration can fail with: structural validation, the wire codec (SchemaMismatch/Corrupt/
/// Truncated/…), and allocation. `ops.ApplyError` ⊆ `serialize.Error || Allocator.Error`.
pub const MigrateError = serialize.Error || Allocator.Error || ValidateError;

/// A declared version-to-version migration.
pub const Migration = struct {
    from_version: u32,
    to_version: u32,
    ops: []const Op,
    /// The exact fingerprint the migration must produce (ascending kind_id). `apply` asserts equality.
    target_fingerprint: []const KindFp,
    /// Optional label (surfaced by catalog.zig as the §7 migration/3 relation).
    name: []const u8 = "",
};

/// A left-to-right sequence of migrations (e.g. v1→v2→v3).
pub const Chain = struct { migrations: []const Migration };

// --- validation -----------------------------------------------------------------------------------

fn coveredByAddOrRenameTo(op_list: []const Op, kid: u16) bool {
    for (op_list) |op| switch (op) {
        .add_kind => |ak| if (ak.kind_id == kid) return true,
        .rename_kind => |rk| if (rk.to == kid) return true,
        else => {},
    };
    return false;
}
fn coveredByDropOrRenameFrom(op_list: []const Op, kid: u16) bool {
    for (op_list) |op| switch (op) {
        .drop_kind => |d| if (d == kid) return true,
        .rename_kind => |rk| if (rk.from == kid) return true,
        else => {},
    };
    return false;
}
fn coveredByTransform(op_list: []const Op, kid: u16) bool {
    for (op_list) |op| switch (op) {
        .transform_kind => |tk| if (tk.kind_id == kid) return true,
        else => {},
    };
    return false;
}

/// Prove the declared ops exactly reconcile `old_fp` into `m.target_fingerprint`. Allocation-free (so
/// validation can never OOM): per-op spuriousness + declared-width checks, then per-delta coverage.
///
/// Each op is validated INDEPENDENTLY against `(old_fp, target)` — i.e. every op must be a single-step
/// reconciliation of one kind relative to the ORIGINAL old fingerprint. `apply` folds ops sequentially,
/// so it can execute a multi-step same-kind sequence (e.g. rename 1→5 then transform 5's width) that
/// this check intentionally REJECTS (the rename is measured against `target`'s final size, and the
/// transform's pre-state kind doesn't exist in `old_fp`). This is deliberately strict, never unsafe:
/// validate only ever OVER-rejects, never wrongly accepts. Express a multi-step change to one kind as
/// successive `Chain` links (each link's target is a real intermediate fingerprint that both validate
/// and `apply` agree on), not as two ops on the same kind in one `Migration`.
pub fn validateMigration(old_fp: []const KindFp, m: *const Migration) ValidateError!void {
    const target = m.target_fingerprint;

    // (1) every op must address a real delta entry (else spurious), with a correct declared width.
    for (m.ops) |op| switch (op) {
        .identity => {},
        .drop_kind => |kid| {
            const in_old = fingerprint.find(old_fp, kid) != null;
            const in_target = fingerprint.find(target, kid) != null;
            if (!(in_old and !in_target)) return error.MigrationSpurious; // not a real drop
        },
        .add_kind => |ak| {
            const in_old = fingerprint.find(old_fp, ak.kind_id) != null;
            const tk = fingerprint.find(target, ak.kind_id);
            if (!(tk != null and !in_old)) return error.MigrationSpurious; // not a real add
            if (ak.default_bytes.len != tk.?.size) return error.BadDefaultWidth;
        },
        .rename_kind => |rk| {
            const from_old = fingerprint.find(old_fp, rk.from);
            const from_in_target = fingerprint.find(target, rk.from) != null;
            const to_in_old = fingerprint.find(old_fp, rk.to) != null;
            const to_target = fingerprint.find(target, rk.to);
            // from must be dropped, to must be added
            if (!(from_old != null and !from_in_target and to_target != null and !to_in_old)) return error.MigrationSpurious;
            if (from_old.?.size != to_target.?.size) return error.BadDefaultWidth; // rename is size-preserving
        },
        .transform_kind => |tk| {
            const old_k = fingerprint.find(old_fp, tk.kind_id);
            const tgt_k = fingerprint.find(target, tk.kind_id);
            // transform addresses a kind that exists before AND after (a value/width migration). A
            // same-size transform is a legitimate value-only migration (covers nothing, not spurious).
            if (!(old_k != null and tgt_k != null)) return error.MigrationSpurious;
            if (tk.new_size != tgt_k.?.size) return error.BadDefaultWidth;
        },
    };

    // (2) every delta entry must be covered by some op (else the migration is incomplete).
    for (target) |kt| {
        const ko = fingerprint.find(old_fp, kt.kind_id);
        if (ko == null) {
            if (!coveredByAddOrRenameTo(m.ops, kt.kind_id)) return error.MigrationIncomplete; // added
        } else if (ko.?.size != kt.size) {
            if (!coveredByTransform(m.ops, kt.kind_id)) return error.MigrationIncomplete; // resized
        }
    }
    for (old_fp) |ko| {
        if (fingerprint.find(target, ko.kind_id) == null) {
            if (!coveredByDropOrRenameFrom(m.ops, ko.kind_id)) return error.MigrationIncomplete; // dropped
        }
    }
}

// --- apply ----------------------------------------------------------------------------------------

/// Apply one migration to an image, returning a FRESH image (its own arena; caller `deinit`s both).
/// Folds the ops over the fingerprint and over every row's cells consistently, recomputes each row's
/// mask against the produced fingerprint, bumps the schema_version, and asserts the produced fingerprint
/// equals `m.target_fingerprint` (SchemaMismatch otherwise). Does NOT call `validateMigration` — the
/// public wrappers do that first; `apply` is the lower-level transform + the final structural assertion.
pub fn apply(gpa: Allocator, m: *const Migration, img: *const Image) MigrateError!Image {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // fold the ops over the fingerprint, then assert the result is exactly the declared target.
    var fp: []const KindFp = img.fingerprint;
    for (m.ops) |op| fp = try ops.applyToFingerprint(a, op, fp);
    try fingerprint.requireMatch(fp, m.target_fingerprint); // SchemaMismatch on a wrong op list

    // fold the ops over each row's cells; recompute the mask against the produced fingerprint.
    const rows = try a.alloc(RowRecord, img.rows.len);
    for (img.rows, 0..) |row, i| {
        var comps: []const KindRecord = row.comps;
        for (m.ops) |op| comps = try ops.applyToCells(a, op, comps);
        rows[i] = .{ .entity = row.entity, .mask = image.maskFor(fp, comps), .comps = comps };
    }

    // the entity allocator + rng pass through untouched (Phase-8 scope; a future op arm could reshape).
    return .{
        .format_version = img.format_version,
        .schema_version = m.to_version,
        .tick = img.tick,
        .fingerprint = fp,
        .gens = try a.dupe(u32, img.gens),
        .outs = try a.dupe(u32, img.outs),
        .rng_seed = img.rng_seed,
        .rows = rows,
        .arena = arena,
    };
}

/// Deep-copy an image into a fresh arena (used to seed an empty/iterated chain fold).
fn cloneImage(gpa: Allocator, img: *const Image) Allocator.Error!Image {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const rows = try a.alloc(RowRecord, img.rows.len);
    for (img.rows, 0..) |row, i| {
        const comps = try a.alloc(KindRecord, row.comps.len);
        for (row.comps, 0..) |c, j| comps[j] = .{ .kind_id = c.kind_id, .bytes = try a.dupe(u8, c.bytes) };
        rows[i] = .{ .entity = row.entity, .mask = row.mask, .comps = comps };
    }
    return .{
        .format_version = img.format_version,
        .schema_version = img.schema_version,
        .tick = img.tick,
        .fingerprint = try a.dupe(KindFp, img.fingerprint),
        .gens = try a.dupe(u32, img.gens),
        .outs = try a.dupe(u32, img.outs),
        .rng_seed = img.rng_seed,
        .rows = rows,
        .arena = arena,
    };
}

/// Fold a chain of migrations over an image. Each link is gated on `from_version == running schema`
/// (a gap is `SchemaMismatch`) and validated before it is applied. Returns a fresh image.
pub fn applyChain(gpa: Allocator, chain: Chain, img: *const Image) MigrateError!Image {
    var acc = try cloneImage(gpa, img);
    errdefer acc.deinit();
    for (chain.migrations) |*m| {
        if (m.from_version != acc.schema_version) return error.SchemaMismatch; // version gap in the chain
        try validateMigration(acc.fingerprint, m);
        const next = try apply(gpa, m, &acc);
        acc.deinit();
        acc = next;
    }
    return acc;
}

// --- public wrappers ------------------------------------------------------------------------------

/// Migrate a serialized World image through `chain`, re-emitting in `R_target`'s schema. Returns a
/// caller-owned byte buffer. The single determinism break-point is `image.encode` (canonical by
/// construction); the gate pins its output.
pub fn migrateBytes(comptime R_target: type, gpa: Allocator, chain: Chain, old_bytes: []const u8) MigrateError!std.ArrayList(u8) {
    var img = try image.decode(gpa, old_bytes);
    defer img.deinit();
    var migrated = try applyChain(gpa, chain, &img);
    defer migrated.deinit();
    return image.encode(R_target, gpa, &migrated);
}

/// Migrate a World image and reconstruct a live `World(R_target)`. The Parts→World handoff mirrors
/// `snapshot.restore` exactly: `fromParts` takes ownership, and there is deliberately NO errdefer over
/// the consumed Parts (that would double-free what the World now owns).
pub fn migrateWorld(comptime R_target: type, gpa: Allocator, chain: Chain, old_bytes: []const u8) MigrateError!worldmod.World(R_target) {
    var bytes = try migrateBytes(R_target, gpa, chain, old_bytes);
    defer bytes.deinit(gpa);
    var reader = serialize.ByteReader{ .bytes = bytes.items };
    const parts = try serialize.readWorld(R_target, gpa, &reader); // World takes ownership
    return worldmod.World(R_target).fromParts(parts);
}

/// Migrate a `Snapshot` to `R_target`, returning a fresh canonical snapshot (bytes + XXH64 + CRC32).
/// Round-trips through a live World (reusing snapshot.snapshot), so the result is verified-parseable and
/// its hash matches the migrated World's digest.
pub fn migrateSnapshot(comptime R_target: type, gpa: Allocator, chain: Chain, old: snapshotmod.Snapshot) MigrateError!snapshotmod.Snapshot {
    var w = try migrateWorld(R_target, gpa, chain, old.bytes);
    defer w.deinit(gpa);
    return snapshotmod.snapshot(R_target, gpa, &w);
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const storage = @import("../storage.zig");
const entity = @import("../entity.zig");
const EntityAllocator = entity.EntityAllocator;

// v1: A(id1,{x:i32}), B(id2,{y:i32})
const A1 = struct {
    x: i32,
    pub const kind_id: u16 = 1;
};
const B1 = struct {
    y: i32,
    pub const kind_id: u16 = 2;
};
const V1 = Registry(.{ A1, B1 });

// v2: A unchanged, B unchanged, C(id3,{z:u8}) ADDED
const A2 = struct {
    x: i32,
    pub const kind_id: u16 = 1;
};
const B2 = struct {
    y: i32,
    pub const kind_id: u16 = 2;
};
const C2 = struct {
    z: u8,
    pub const kind_id: u16 = 3;
};
const V2 = Registry(.{ A2, B2, C2 });

// v3: + D(id4,{w:u16}) ADDED on top of v2
const A3 = struct {
    x: i32,
    pub const kind_id: u16 = 1;
};
const B3 = struct {
    y: i32,
    pub const kind_id: u16 = 2;
};
const C3 = struct {
    z: u8,
    pub const kind_id: u16 = 3;
};
const D3 = struct {
    w: u16,
    pub const kind_id: u16 = 4;
};
const V3 = Registry(.{ A3, B3, C3, D3 });

const m_1_2 = Migration{
    .from_version = 1,
    .to_version = 2,
    .ops = &.{.{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{0} } }}, // C default z=0
    .target_fingerprint = fingerprint.currentFingerprint(V2),
    .name = "v1->v2 add C",
};
const m_2_3 = Migration{
    .from_version = 2,
    .to_version = 3,
    .ops = &.{.{ .add_kind = .{ .kind_id = 4, .default_bytes = &.{ 0, 0 } } }}, // D default w=0 (u16=2 bytes)
    .target_fingerprint = fingerprint.currentFingerprint(V3),
    .name = "v2->v3 add D",
};
const m_1_3 = Migration{
    .from_version = 1,
    .to_version = 3,
    .ops = &.{
        .{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{0} } },
        .{ .add_kind = .{ .kind_id = 4, .default_bytes = &.{ 0, 0 } } },
    },
    .target_fingerprint = fingerprint.currentFingerprint(V3),
    .name = "v1->v3 direct",
};

/// A v1 world: e0 has A{x=7}+B{y=9}, serialized bytes (caller owns).
fn v1Bytes(gpa: Allocator) !std.ArrayList(u8) {
    var entities: EntityAllocator = .{};
    errdefer entities.deinit(gpa);
    const e0 = try entities.alloc(gpa);
    var table: storage.Table(V1) = .{};
    errdefer table.deinit(gpa);
    _ = try table.spawnRow(gpa, e0);
    table.addComponent(e0, A1, .{ .x = 7 });
    table.addComponent(e0, B1, .{ .y = 9 });
    var parts = serialize.Parts(V1){ .tick = 5, .schema_version = 1, .rng_root = .{ .seed = 0x1234 }, .entities = entities, .table = table };
    defer parts.deinit(gpa);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try serialize.writeWorld(V1, gpa, &sink, &parts);
    return buf;
}

test "validateMigration accepts a complete, non-spurious, correctly-sized migration" {
    try validateMigration(fingerprint.currentFingerprint(V1), &m_1_2);
    try validateMigration(fingerprint.currentFingerprint(V2), &m_2_3);
    try validateMigration(fingerprint.currentFingerprint(V1), &m_1_3);
}

test "validateMigration returns MigrationIncomplete when a delta has no covering op" {
    const empty = Migration{ .from_version = 1, .to_version = 2, .ops = &.{}, .target_fingerprint = fingerprint.currentFingerprint(V2) };
    try testing.expectError(error.MigrationIncomplete, validateMigration(fingerprint.currentFingerprint(V1), &empty));
}

test "validateMigration returns MigrationSpurious when an op addresses an unchanged kind" {
    // drops kind 1, but kind 1 still exists in the target -> spurious.
    const bogus = Migration{ .from_version = 1, .to_version = 2, .ops = &.{
        .{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{0} } },
        .{ .drop_kind = 1 },
    }, .target_fingerprint = fingerprint.currentFingerprint(V2) };
    try testing.expectError(error.MigrationSpurious, validateMigration(fingerprint.currentFingerprint(V1), &bogus));
}

test "validateMigration returns BadDefaultWidth when a default length != target size" {
    // C is a u8 (1 byte), but the default is 2 bytes.
    const wide = Migration{ .from_version = 1, .to_version = 2, .ops = &.{
        .{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{ 0, 0 } } },
    }, .target_fingerprint = fingerprint.currentFingerprint(V2) };
    try testing.expectError(error.BadDefaultWidth, validateMigration(fingerprint.currentFingerprint(V1), &wide));
}

test "apply bumps schema_version, recomputes the mask, and migrates values (v1 -> v2)" {
    const gpa = testing.allocator;
    var bytes = try v1Bytes(gpa);
    defer bytes.deinit(gpa);
    var img = try image.decode(gpa, bytes.items);
    defer img.deinit();

    var out = try apply(gpa, &m_1_2, &img);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 2), out.schema_version);
    try testing.expectEqual(@as(usize, 3), out.fingerprint.len); // A,B,C
    // e0 now carries all three kinds -> mask 0b111
    try testing.expectEqual(@as(u64, 0b111), out.rows[0].mask);
    const c = image.findComp(out.rows[0], 3).?;
    try testing.expectEqualSlices(u8, &.{0}, c.bytes);

    // round-trip into a live V2 world
    var enc = try image.encode(V2, gpa, &out);
    defer enc.deinit(gpa);
    var reader = serialize.ByteReader{ .bytes = enc.items };
    var restored = try serialize.readWorld(V2, gpa, &reader);
    defer restored.deinit(gpa);
    const e0 = entity.Entity{ .index = 0, .generation = 0 };
    try testing.expectEqual(@as(i32, 7), restored.table.get(e0, A2).?.x);
    try testing.expectEqual(@as(i32, 9), restored.table.get(e0, B2).?.y);
    try testing.expectEqual(@as(u8, 0), restored.table.get(e0, C2).?.z);
}

test "apply asserts the target fingerprint (a wrong op list trips SchemaMismatch)" {
    const gpa = testing.allocator;
    var bytes = try v1Bytes(gpa);
    defer bytes.deinit(gpa);
    var img = try image.decode(gpa, bytes.items);
    defer img.deinit();

    // ops add C, but target is declared as v1's fingerprint -> produced fp != target.
    const wrong = Migration{ .from_version = 1, .to_version = 2, .ops = &.{
        .{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{0} } },
    }, .target_fingerprint = fingerprint.currentFingerprint(V1) };
    try testing.expectError(error.SchemaMismatch, apply(gpa, &wrong, &img));
}

test "migrateBytes v1 -> v2 yields a V2-parseable image with the default-filled new component" {
    const gpa = testing.allocator;
    var bytes = try v1Bytes(gpa);
    defer bytes.deinit(gpa);
    var out = try migrateBytes(V2, gpa, .{ .migrations = &.{m_1_2} }, bytes.items);
    defer out.deinit(gpa);
    var reader = serialize.ByteReader{ .bytes = out.items };
    var restored = try serialize.readWorld(V2, gpa, &reader);
    defer restored.deinit(gpa);
    const e0 = entity.Entity{ .index = 0, .generation = 0 };
    try testing.expectEqual(@as(i32, 7), restored.table.get(e0, A2).?.x);
    try testing.expectEqual(@as(u8, 0), restored.table.get(e0, C2).?.z);
    try testing.expectEqual(@as(u64, 5), restored.tick); // tick preserved
}

test "chain v1->v2->v3 equals direct v1->v3, byte-for-byte" {
    const gpa = testing.allocator;
    var bytes = try v1Bytes(gpa);
    defer bytes.deinit(gpa);

    var chained = try migrateBytes(V3, gpa, .{ .migrations = &.{ m_1_2, m_2_3 } }, bytes.items);
    defer chained.deinit(gpa);
    var direct = try migrateBytes(V3, gpa, .{ .migrations = &.{m_1_3} }, bytes.items);
    defer direct.deinit(gpa);
    try testing.expectEqualSlices(u8, direct.items, chained.items);
}

test "chain fold requires from_version == running schema (a gap is SchemaMismatch)" {
    const gpa = testing.allocator;
    var bytes = try v1Bytes(gpa); // running schema_version == 1
    defer bytes.deinit(gpa);
    // m_2_3 expects from_version 2, but the running image is v1 -> gap.
    try testing.expectError(error.SchemaMismatch, migrateBytes(V3, gpa, .{ .migrations = &.{m_2_3} }, bytes.items));
}

test "migrateSnapshot round-trips through a World with no double-free, hash matches the digest" {
    const gpa = testing.allocator;
    var bytes = try v1Bytes(gpa);
    defer bytes.deinit(gpa);
    const old = snapshotmod.Snapshot{ .bytes = bytes.items, .tick = 5, .hash = 0, .crc = 0 };

    var migrated = try migrateSnapshot(V2, gpa, .{ .migrations = &.{m_1_2} }, old);
    defer migrated.deinit(gpa);

    // the migrated snapshot must restore to a V2 world whose digest equals the snapshot hash.
    var w = try snapshotmod.restore(V2, gpa, migrated);
    defer w.deinit(gpa);
    try testing.expectEqual(migrated.hash, (try w.digest(gpa)).hash);
    try testing.expectEqual(@as(u8, 0), w.get(.{ .index = 0, .generation = 0 }, C2).?.z);
}
