//! Phase-8 cross-build determinism gate + pinned artifacts (PLAN.md Phase 8, §12).
//!
//! This file is the empirical contract for migration & hot-reload. It freezes a v1 image as a literal
//! byte blob (`PINNED_V1` — a genuine "old" image, NOT re-serialized by the current writer each run) and
//! pins the migrated World digests + a migrated-image CRC32, then asserts, under the Debug /
//! ReleaseSafe / ReleaseFast matrix that build.zig runs:
//!   (a) migrating v1→v2 is BYTE-IDENTICAL to a separately native-built v2 World (digest + an
//!       independent-family CRC32 of the bytes), so the migration path and the writer agree to the bit.
//!   (b) the chain v1→v2→v3 equals the direct v1→v3 equals a native v3 World.
//!   (c) fingerprint dispatch + validateMigration: an identity migration is byte-identical; a
//!       mismatch / incomplete / spurious / bad-width is the corresponding error.
//!   (d) purity: migrating twice yields the same bytes and the same hash.
//!   (e) reload: a reload-to-same mid-stream is a bit-identical hash stream (pinned digest); a
//!       reload-to-DIFFERENT set is caught as a divergence; a wrong transform diverges from native.
//!   (f) OOM-injection over decode→validate→apply→encode→readWorld + the reload swap is leak/double-free
//!       free.
//! The byte-identity assertion in (a) is the primary proof that the migrated image IS the canonical one.
//! A pinned CRC32 of the migrated bytes sits alongside the (XXH64) World digest as a SEPARATE hash FAMILY
//! — genuinely independent, so a non-canonical encode that happened to XXH64-collide with the canonical
//! image would still be caught (the spine's single determinism risk).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const serialize = @import("../serialize.zig");
const worldmod = @import("../world.zig");
const storage = @import("../storage.zig");
const entity = @import("../entity.zig");
const EntityAllocator = entity.EntityAllocator;
const Registry = @import("../registry.zig").Registry;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const system = schedule.system;
const Schedule = schedule.Schedule;
const query = @import("../query.zig");
const Write = query.Write;
const Query = query.Query;
const SimCtx = @import("../simctx.zig").SimCtx;
const input = @import("../input.zig");
const run = @import("../vopr/run.zig");
const oracle = @import("../vopr/oracle.zig");
const reload = @import("../reload.zig");

const image = @import("image.zig");
const fingerprint = @import("fingerprint.zig");
const ops = @import("ops.zig");
const migrate = @import("migrate.zig");
const Migration = migrate.Migration;
const FieldBuilder = ops.FieldBuilder;
const FieldReader = ops.FieldReader;

// --- the frozen test schemas (v1 -> v2 -> v3) -----------------------------------------------------

const A = struct {
    x: i32,
    pub const kind_id: u16 = 1;
};
const B1 = struct {
    hp: i32,
    pub const kind_id: u16 = 2;
};
const B2 = struct {
    hp: i64, // v2: B widened i32 -> i64
    pub const kind_id: u16 = 2;
};
const C = struct {
    level: u8,
    pub const kind_id: u16 = 3;
};
const D = struct {
    tag: u16,
    pub const kind_id: u16 = 4;
};

const R_v1 = Registry(.{ A, B1 });
const R_v2 = Registry(.{ A, B2, C });
const R_v3 = Registry(.{ A, B2, C, D });

// transform B: read the old i32 hp, write it sign-extended into an i64 (the correct widening).
fn growHp(old_bytes: []const u8, out: *FieldBuilder) ops.ApplyError!void {
    var r = FieldReader.init(old_bytes);
    const v = try r.getI(i32);
    try out.addI(i64, v);
}
// a DELIBERATELY WRONG transform: zero-extends instead of sign-extending (diverges for negative hp).
fn growHpWrong(old_bytes: []const u8, out: *FieldBuilder) ops.ApplyError!void {
    var r = FieldReader.init(old_bytes);
    const v = try r.getU(u32); // read as unsigned -> negative becomes a large positive
    try out.addU(u64, v);
}

const m_1_2 = Migration{
    .from_version = 1,
    .to_version = 2,
    .ops = &.{
        .{ .transform_kind = .{ .kind_id = 2, .new_size = 8, .rewrite = growHp } },
        .{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{1} } }, // C.level = 1
    },
    .target_fingerprint = fingerprint.currentFingerprint(R_v2),
    .name = "v1->v2",
};
const m_2_3 = Migration{
    .from_version = 2,
    .to_version = 3,
    .ops = &.{.{ .add_kind = .{ .kind_id = 4, .default_bytes = &.{ 0, 0 } } }}, // D.tag = 0
    .target_fingerprint = fingerprint.currentFingerprint(R_v3),
    .name = "v2->v3",
};
const m_1_3 = Migration{
    .from_version = 1,
    .to_version = 3,
    .ops = &.{
        .{ .transform_kind = .{ .kind_id = 2, .new_size = 8, .rewrite = growHp } },
        .{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{1} } },
        .{ .add_kind = .{ .kind_id = 4, .default_bytes = &.{ 0, 0 } } },
    },
    .target_fingerprint = fingerprint.currentFingerprint(R_v3),
    .name = "v1->v3 direct",
};
const m_identity_v2 = Migration{
    .from_version = 2,
    .to_version = 2,
    .ops = &.{.identity},
    .target_fingerprint = fingerprint.currentFingerprint(R_v2),
    .name = "v2 identity",
};

// --- pinned artifacts (frozen below after the first dump run) -------------------------------------

/// The frozen v1 image: two entities e0{A.x=7, B.hp=-3}, e1{A.x=100, B.hp=50}, tick=5, seed=0x1234.
pub const PINNED_V1 = [_]u8{
    0x47, 0x4b, 0x5a, 0x31, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x34, 0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00,
    0xfd, 0xff, 0xff, 0xff, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00, 0x00,
};
pub const EXPECTED_V2_HASH: u64 = 9221401944289118882; // World digest (XXH64) of the migrated/native v2 world
pub const EXPECTED_V3_HASH: u64 = 14454402369660666389; // World digest (XXH64) of the migrated/native v3 world
pub const MIGRATED_IMAGE_CRC32: u32 = 1847335896; // CRC32 of the migrated v2 image bytes — a SEPARATE hash family from the XXH64 digest
pub const GATE_RELOAD_DIGEST: u64 = 15949133225501398549; // streamDigest of the pinned reload reference run

// --- native reference worlds ----------------------------------------------------------------------

fn buildV1Bytes(gpa: Allocator) !std.ArrayList(u8) {
    var ents: EntityAllocator = .{};
    errdefer ents.deinit(gpa);
    const e0 = try ents.alloc(gpa);
    const e1 = try ents.alloc(gpa);
    var table: storage.Table(R_v1) = .{};
    errdefer table.deinit(gpa);
    _ = try table.spawnRow(gpa, e0);
    _ = try table.spawnRow(gpa, e1);
    table.addComponent(e0, A, .{ .x = 7 });
    table.addComponent(e0, B1, .{ .hp = -3 });
    table.addComponent(e1, A, .{ .x = 100 });
    table.addComponent(e1, B1, .{ .hp = 50 });
    var parts = serialize.Parts(R_v1){ .tick = 5, .schema_version = 1, .rng_root = .{ .seed = 0x1234 }, .entities = ents, .table = table };
    defer parts.deinit(gpa);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try serialize.writeWorld(R_v1, gpa, &sink, &parts);
    return buf;
}

fn buildNativeV2(gpa: Allocator) !worldmod.World(R_v2) {
    var w = worldmod.World(R_v2).init(0x1234);
    errdefer w.deinit(gpa);
    w.tick = 5;
    w.schema_version = 2; // a migrated v1->v2 image carries the bumped version; the native must match
    const e0 = try w.spawn(gpa);
    const e1 = try w.spawn(gpa);
    w.add(e0, A, .{ .x = 7 });
    w.add(e0, B2, .{ .hp = -3 });
    w.add(e0, C, .{ .level = 1 });
    w.add(e1, A, .{ .x = 100 });
    w.add(e1, B2, .{ .hp = 50 });
    w.add(e1, C, .{ .level = 1 });
    return w;
}

fn buildNativeV3(gpa: Allocator) !worldmod.World(R_v3) {
    var w = worldmod.World(R_v3).init(0x1234);
    errdefer w.deinit(gpa);
    w.tick = 5;
    w.schema_version = 3;
    const e0 = try w.spawn(gpa);
    const e1 = try w.spawn(gpa);
    w.add(e0, A, .{ .x = 7 });
    w.add(e0, B2, .{ .hp = -3 });
    w.add(e0, C, .{ .level = 1 });
    w.add(e0, D, .{ .tag = 0 });
    w.add(e1, A, .{ .x = 100 });
    w.add(e1, B2, .{ .hp = 50 });
    w.add(e1, C, .{ .level = 1 });
    w.add(e1, D, .{ .tag = 0 });
    return w;
}

fn serializeWorld(comptime R: type, gpa: Allocator, w: *const worldmod.World(R)) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try serialize.writeWorld(R, gpa, &sink, w);
    return buf;
}

// --- reload systems over R_v3 (plain-int components; no fpz needed) --------------------------------

fn bumpD(ctx: *SimCtx(R_v3), q: *Query(R_v3, .{Write(D)})) Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(D).tag +%= 1;
}
fn bumpD2(ctx: *SimCtx(R_v3), q: *Query(R_v3, .{Write(D)})) Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(D).tag +%= 2;
}
const reload_a = [_]Sys(R_v3){system(R_v3, "bumpD", bumpD)};
const reload_b = [_]Sys(R_v3){system(R_v3, "bumpD2", bumpD2)};
const RTICKS: usize = 6;
const RSWAP: usize = 3;

fn reloadWorld(gpa: Allocator) !worldmod.World(R_v3) {
    return buildNativeV3(gpa); // a v3 world with two D-carrying entities
}

// --- the battery -----------------------------------------------------------------------------------

test "(a) migrating v1->v2 is byte-identical to a native v2 world (digest + raw image XXH64)" {
    const gpa = testing.allocator;

    // the pinned blob must equal a freshly-built v1 image (catches any v1 wire drift).
    var fresh = try buildV1Bytes(gpa);
    defer fresh.deinit(gpa);
    try testing.expectEqualSlices(u8, &PINNED_V1, fresh.items);

    var migrated = try migrate.migrateBytes(R_v2, gpa, .{ .migrations = &.{m_1_2} }, &PINNED_V1);
    defer migrated.deinit(gpa);

    var native = try buildNativeV2(gpa);
    defer native.deinit(gpa);
    var native_bytes = try serializeWorld(R_v2, gpa, &native);
    defer native_bytes.deinit(gpa);

    try testing.expectEqualSlices(u8, native_bytes.items, migrated.items); // byte-identical (canonicality)
    try testing.expectEqual(MIGRATED_IMAGE_CRC32, std.hash.Crc32.hash(migrated.items)); // independent family
    try testing.expectEqual(EXPECTED_V2_HASH, (try native.digest(gpa)).hash);

    // and the migrated bytes restore to a v2 world with the right digest
    var reader = serialize.ByteReader{ .bytes = migrated.items };
    var restored = try serialize.readWorld(R_v2, gpa, &reader);
    defer restored.deinit(gpa);
    const w = worldmod.World(R_v2).fromParts(restored);
    try testing.expectEqual(EXPECTED_V2_HASH, (try w.digest(gpa)).hash);
}

test "(b) chain v1->v2->v3 == direct v1->v3 == native v3" {
    const gpa = testing.allocator;
    var chained = try migrate.migrateBytes(R_v3, gpa, .{ .migrations = &.{ m_1_2, m_2_3 } }, &PINNED_V1);
    defer chained.deinit(gpa);
    var direct = try migrate.migrateBytes(R_v3, gpa, .{ .migrations = &.{m_1_3} }, &PINNED_V1);
    defer direct.deinit(gpa);
    var native = try buildNativeV3(gpa);
    defer native.deinit(gpa);
    var native_bytes = try serializeWorld(R_v3, gpa, &native);
    defer native_bytes.deinit(gpa);

    try testing.expectEqualSlices(u8, direct.items, chained.items);
    try testing.expectEqualSlices(u8, native_bytes.items, chained.items);
    try testing.expectEqual(EXPECTED_V3_HASH, (try native.digest(gpa)).hash);
}

test "(c) fingerprint dispatch + validateMigration rejections; identity is byte-identical" {
    const gpa = testing.allocator;
    const v1fp = fingerprint.currentFingerprint(R_v1);

    // identity migration over a v2 image reproduces the input bytes exactly.
    var v2_in = try migrate.migrateBytes(R_v2, gpa, .{ .migrations = &.{m_1_2} }, &PINNED_V1);
    defer v2_in.deinit(gpa);
    var v2_id = try migrate.migrateBytes(R_v2, gpa, .{ .migrations = &.{m_identity_v2} }, v2_in.items);
    defer v2_id.deinit(gpa);
    try testing.expectEqualSlices(u8, v2_in.items, v2_id.items);

    // validateMigration: complete accepts; the three structural faults and a schema mismatch are caught.
    try migrate.validateMigration(v1fp, &m_1_2);

    const incomplete = Migration{ .from_version = 1, .to_version = 2, .ops = &.{}, .target_fingerprint = fingerprint.currentFingerprint(R_v2) };
    try testing.expectError(error.MigrationIncomplete, migrate.validateMigration(v1fp, &incomplete));

    const spurious = Migration{ .from_version = 1, .to_version = 2, .ops = &.{
        .{ .transform_kind = .{ .kind_id = 2, .new_size = 8, .rewrite = growHp } },
        .{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{1} } },
        .{ .drop_kind = 1 }, // A still exists in v2 -> spurious
    }, .target_fingerprint = fingerprint.currentFingerprint(R_v2) };
    try testing.expectError(error.MigrationSpurious, migrate.validateMigration(v1fp, &spurious));

    const badwidth = Migration{ .from_version = 1, .to_version = 2, .ops = &.{
        .{ .transform_kind = .{ .kind_id = 2, .new_size = 8, .rewrite = growHp } },
        .{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{ 1, 2 } } }, // C is u8 (1 byte)
    }, .target_fingerprint = fingerprint.currentFingerprint(R_v2) };
    try testing.expectError(error.BadDefaultWidth, migrate.validateMigration(v1fp, &badwidth));

    // apply's own assertion: a migration whose ops PRODUCE v2 but DECLARE v1's fingerprint as the target
    // trips SchemaMismatch (defense-in-depth beneath validateMigration — exercised by calling apply
    // directly, since the public path's validate guard would reject this earlier with BadDefaultWidth).
    const wrong_target = Migration{ .from_version = 1, .to_version = 2, .ops = &.{
        .{ .transform_kind = .{ .kind_id = 2, .new_size = 8, .rewrite = growHp } },
        .{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{1} } },
    }, .target_fingerprint = fingerprint.currentFingerprint(R_v1) };
    var img = try image.decode(gpa, &PINNED_V1);
    defer img.deinit();
    try testing.expectError(error.SchemaMismatch, migrate.apply(gpa, &wrong_target, &img));
}

test "(d) purity: migrating twice yields identical bytes and hash" {
    const gpa = testing.allocator;
    var a1 = try migrate.migrateBytes(R_v3, gpa, .{ .migrations = &.{ m_1_2, m_2_3 } }, &PINNED_V1);
    defer a1.deinit(gpa);
    var a2 = try migrate.migrateBytes(R_v3, gpa, .{ .migrations = &.{ m_1_2, m_2_3 } }, &PINNED_V1);
    defer a2.deinit(gpa);
    try testing.expectEqualSlices(u8, a1.items, a2.items);
    try testing.expectEqual(std.hash.XxHash64.hash(0, a1.items), std.hash.XxHash64.hash(0, a2.items));
}

test "(e) reload-to-same is a bit-identical pinned stream; reload-to-different is caught as a divergence" {
    const gpa = testing.allocator;
    const exec_a = &Schedule(R_v3, &reload_a).exec_order;
    const exec_b = &Schedule(R_v3, &reload_b).exec_order;
    const empties = [_]input.Input{.{ .tick = 0, .commands = &.{} }} ** RTICKS;

    var ref = try run.captureStream(R_v3, gpa, try reloadWorld(gpa), &empties, &reload_a, exec_a, null);
    defer ref.final.deinit(gpa);
    defer gpa.free(ref.hashes);
    try testing.expectEqual(GATE_RELOAD_DIGEST, run.streamDigest(ref.hashes));

    // obtain the post-swap set through the ACTUAL reload surface (reloadAt + a SystemSource.load), so the
    // gate exercises the API it documents — not just a raw comptime slice. The wrapped slice is the
    // comptime `&reload_a`, which is what captureStream's comptime parameter consumes.
    const next_same = reload.reloadAt(R_v3, .{ .systems = &reload_a }, try reload.inProcessSource(R_v3, &reload_a).load());
    try testing.expectEqual(@intFromPtr(&reload_a), @intFromPtr(next_same.systems.ptr));

    const seg1 = try run.captureStream(R_v3, gpa, try reloadWorld(gpa), empties[0..RSWAP], &reload_a, exec_a, null);
    defer gpa.free(seg1.hashes);
    var seg2 = try run.captureStream(R_v3, gpa, seg1.final, empties[RSWAP..], &reload_a, exec_a, null);
    defer seg2.final.deinit(gpa);
    defer gpa.free(seg2.hashes);
    var joined = try gpa.alloc(u64, RTICKS);
    defer gpa.free(joined);
    @memcpy(joined[0..RSWAP], seg1.hashes);
    @memcpy(joined[RSWAP..], seg2.hashes);
    try testing.expectEqualSlices(u64, ref.hashes, joined); // reload-to-same is exact

    // reload-to-DIFFERENT (swap reload_a -> reload_b mid-stream): the VOPR's divergence primitive must
    // flag it, at or after the swap, with an identical pre-swap prefix.
    const seg1b = try run.captureStream(R_v3, gpa, try reloadWorld(gpa), empties[0..RSWAP], &reload_a, exec_a, null);
    defer gpa.free(seg1b.hashes);
    var seg2b = try run.captureStream(R_v3, gpa, seg1b.final, empties[RSWAP..], &reload_b, exec_b, null);
    defer seg2b.final.deinit(gpa);
    defer gpa.free(seg2b.hashes);
    var joinedb = try gpa.alloc(u64, RTICKS);
    defer gpa.free(joinedb);
    @memcpy(joinedb[0..RSWAP], seg1b.hashes);
    @memcpy(joinedb[RSWAP..], seg2b.hashes);
    const div = oracle.firstDivergentTick(ref.hashes, joinedb);
    try testing.expect(div != null and div.? >= RSWAP);
    try testing.expectEqualSlices(u64, ref.hashes[0..RSWAP], joinedb[0..RSWAP]);

    // and a wrong migration transform (zero- instead of sign-extend) is NOT byte-identical to native v2.
    const m_wrong = Migration{ .from_version = 1, .to_version = 2, .ops = &.{
        .{ .transform_kind = .{ .kind_id = 2, .new_size = 8, .rewrite = growHpWrong } },
        .{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{1} } },
    }, .target_fingerprint = fingerprint.currentFingerprint(R_v2) };
    var bad = try migrate.migrateBytes(R_v2, gpa, .{ .migrations = &.{m_wrong} }, &PINNED_V1);
    defer bad.deinit(gpa);
    var native = try buildNativeV2(gpa);
    defer native.deinit(gpa);
    var native_bytes = try serializeWorld(R_v2, gpa, &native);
    defer native_bytes.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, bad.items, native_bytes.items)); // caught: diverges from canonical
}

fn oomCycle(gpa: Allocator) !void {
    // decode -> validate -> apply -> encode -> readWorld (the whole migration path)
    {
        var w = try migrate.migrateWorld(R_v3, gpa, .{ .migrations = &.{ m_1_2, m_2_3 } }, &PINNED_V1);
        w.deinit(gpa);
    }
    // the reload swap (captureStream allocates the hash stream + per-tick worlds)
    {
        const exec = &Schedule(R_v3, &reload_a).exec_order;
        const empties = [_]input.Input{.{ .tick = 0, .commands = &.{} }} ** RTICKS;
        const seg1 = try run.captureStream(R_v3, gpa, try reloadWorld(gpa), empties[0..RSWAP], &reload_a, exec, null);
        defer gpa.free(seg1.hashes);
        var seg2 = try run.captureStream(R_v3, gpa, seg1.final, empties[RSWAP..], &reload_a, exec, null);
        seg2.final.deinit(gpa);
        gpa.free(seg2.hashes);
    }
}

test "(f) OOM-injection over the migration + reload cycle is leak/double-free free" {
    try testing.checkAllAllocationFailures(testing.allocator, oomCycle, .{});
}

test "DUMP pinned artifacts" {
    if (true) return error.SkipZigTest; // flip to false to recompute the pins
    const gpa = testing.allocator;
    var v1 = try buildV1Bytes(gpa);
    defer v1.deinit(gpa);
    std.debug.print("\nPINNED_V1 ({d} bytes):\n", .{v1.items.len});
    for (v1.items, 0..) |b, i| {
        std.debug.print("0x{x:0>2}, ", .{b});
        if ((i + 1) % 16 == 0) std.debug.print("\n", .{});
    }
    var mv2 = try migrate.migrateBytes(R_v2, gpa, .{ .migrations = &.{m_1_2} }, v1.items);
    defer mv2.deinit(gpa);
    var nv2 = try buildNativeV2(gpa);
    defer nv2.deinit(gpa);
    var nv3 = try buildNativeV3(gpa);
    defer nv3.deinit(gpa);
    const exec = &Schedule(R_v3, &reload_a).exec_order;
    const empties = [_]input.Input{.{ .tick = 0, .commands = &.{} }} ** RTICKS;
    var rref = try run.captureStream(R_v3, gpa, try reloadWorld(gpa), &empties, &reload_a, exec, null);
    defer rref.final.deinit(gpa);
    defer gpa.free(rref.hashes);
    std.debug.print("\nEXPECTED_V2_HASH = {d};\nEXPECTED_V3_HASH = {d};\nMIGRATED_IMAGE_CRC32 = {d};\nGATE_RELOAD_DIGEST = {d};\n", .{
        (try nv2.digest(gpa)).hash,
        (try nv3.digest(gpa)).hash,
        std.hash.Crc32.hash(mv2.items),
        run.streamDigest(rref.hashes),
    });
}
