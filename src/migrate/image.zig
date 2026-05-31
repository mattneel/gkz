//! Schema-agnostic record substrate for §12 migration (PLAN.md Phase 8).
//!
//! A migration must reshape a serialized World WITHOUT instantiating the old `Registry` type (the old
//! component types may no longer exist in source). `Image` is the record-layer view that makes this
//! possible: `decode` splits ANY serialize image into header + per-Kind fingerprint + per-row
//! `(entity, mask, [{kind_id, raw value-bytes}])` records using ONLY the image's OWN fingerprint — the
//! per-Kind `{kind_id, size}` fingerprint that `serialize.writeWorld` already emits carries each
//! component's exact canonical byte-WIDTH, so a row is sliced blindly by mask-bit rank with zero
//! comptime type knowledge. `encode(R_target, ...)` re-emits in `R_target`'s ascending-kind_id order with
//! `R_target`'s widths, byte-IDENTICAL to `serialize.writeWorld` for equivalent content — so migrated
//! output is canonically serializable BY CONSTRUCTION (D5/D7 fall out: only whole canonical-LE slices
//! move, never floats or pointers).
//!
//! `decode` reads UNTRUSTED bytes (a migration source may come from anywhere), so it is hardened beyond
//! `serialize.readWorld` (which reads trusted kernel output): every variable-length section is parsed
//! incrementally so a hostile count never drives a pre-allocation, and a mask bit with no covering
//! fingerprint entry (an unsizeable row) is `error.Corrupt` rather than a panic — validate before alloc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const entity = @import("../entity.zig");
const Entity = entity.Entity;
const serialize = @import("../serialize.zig");

/// One entry of the per-Kind schema fingerprint: a `kind_id` and its canonical serialized byte-width.
/// The canonical fingerprint definition lives here and is re-used by fingerprint.zig and migrate.zig.
pub const KindFp = struct { kind_id: u16, size: u32 };

/// One component cell of a row: its `kind_id` plus its raw canonical-LE value bytes (NOT typed — the
/// whole point is that bytes flow through a migration untyped, exactly `size` wide).
pub const KindRecord = struct { kind_id: u16, bytes: []const u8 };

/// One row: the owning entity handle, the presence mask as read (u64), and its component cells. `comps`
/// is in ascending-kind_id order (the order the fingerprint — and therefore the stream — uses).
pub const RowRecord = struct { entity: Entity, mask: u64, comps: []const KindRecord };

/// The fully-decoded, schema-agnostic image. Arena-backed: all slices live in `arena`, freed by `deinit`.
pub const Image = struct {
    format_version: u16,
    schema_version: u32,
    tick: u64,
    /// Per-Kind fingerprint, ascending kind_id (as it appears in the stream). `fingerprint[p]` is the
    /// kind whose presence is mask bit `p`.
    fingerprint: []const KindFp,
    gens: []const u32,
    outs: []const u32,
    rng_seed: u64,
    rows: []const RowRecord,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Image) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The allocator backing this image's storage — use it to build derived images (apply()).
    pub fn allocator(self: *Image) Allocator {
        return self.arena.allocator();
    }
};

/// Find a component cell for `kind_id` in a cell slice, or null. Linear scan (≤64 cells per row).
pub fn findCell(comps: []const KindRecord, kind_id: u16) ?KindRecord {
    for (comps) |c| {
        if (c.kind_id == kind_id) return c;
    }
    return null;
}

/// Find a row's component cell for `kind_id`, or null.
pub fn findComp(row: RowRecord, kind_id: u16) ?KindRecord {
    return findCell(row.comps, kind_id);
}

/// The presence mask of `comps` relative to a fingerprint: bit `p` is set iff a cell exists for
/// `fingerprint[p].kind_id`. The inverse of `decode`'s blind row-slicing; used by `migrate.apply` to
/// recompute a row's mask against its NEW schema after ops reshape its cells.
pub fn maskFor(fingerprint: []const KindFp, comps: []const KindRecord) u64 {
    var mask: u64 = 0;
    for (fingerprint, 0..) |fp, p| {
        if (p >= 64) break;
        if (findCell(comps, fp.kind_id) != null) mask |= @as(u64, 1) << @as(u6, @intCast(p));
    }
    return mask;
}

// --- decode ---------------------------------------------------------------------------------------

/// Decode any serialize image into a schema-agnostic `Image`. Reads UNTRUSTED bytes: a malformed image
/// is a returned `Error`, never a panic, and a hostile count never drives a pre-allocation. The caller
/// owns the result and must `deinit` it.
pub fn decode(gpa: Allocator, bytes: []const u8) (serialize.Error || Allocator.Error)!Image {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var reader = serialize.ByteReader{ .bytes = bytes };

    // header
    const magic = try reader.readSlice(4);
    if (!std.mem.eql(u8, magic, &serialize.MAGIC)) return error.BadMagic;
    const format_version = try serialize.getInt(&reader, u16);
    if (format_version != serialize.FORMAT_VERSION) return error.UnsupportedFormat;
    const schema_version = try serialize.getInt(&reader, u32);
    const tick = try serialize.getInt(&reader, u64);
    const kind_count = try serialize.getInt(&reader, u16);
    // A mask is a u64, so a row can encode at most 64 component ranks; a fingerprint claiming more kinds
    // could never be addressed by any mask and would overflow the rank shift below — reject as Corrupt.
    if (kind_count > 64) return error.Corrupt;
    const row_count = try serialize.getInt(&reader, u32);

    // per-Kind fingerprint (kind_count ≤ 64, so a direct alloc is bounded)
    const fingerprint = try a.alloc(KindFp, kind_count);
    for (fingerprint) |*fp| {
        fp.kind_id = try serialize.getInt(&reader, u16);
        fp.size = try serialize.getInt(&reader, u32);
    }

    // entity allocator — gen_count/out_count are attacker-controlled u32; append incrementally so the
    // count never drives a pre-alloc. A short image runs out of bytes (Truncated) within input.len/4
    // iterations, so the ArrayList grows only proportionally to bytes actually present.
    const gen_count = try serialize.getInt(&reader, u32);
    var gens: std.ArrayList(u32) = .empty;
    {
        var i: u32 = 0;
        while (i < gen_count) : (i += 1) try gens.append(a, try serialize.getInt(&reader, u32));
    }
    const out_count = try serialize.getInt(&reader, u32);
    var outs: std.ArrayList(u32) = .empty;
    {
        var i: u32 = 0;
        while (i < out_count) : (i += 1) try outs.append(a, try serialize.getInt(&reader, u32));
    }

    const rng_seed = try serialize.getInt(&reader, u64);

    // rows — also count-driven and attacker-controlled; parse incrementally, appending only after a
    // full row is read. Each row is ≥16 bytes (entity+mask), so the list is bounded by input length.
    var rows: std.ArrayList(RowRecord) = .empty;
    {
        var r: u32 = 0;
        while (r < row_count) : (r += 1) {
            const idx = try serialize.getInt(&reader, u32);
            const gen = try serialize.getInt(&reader, u32);
            const mask = try serialize.getInt(&reader, u64);
            // A mask bit at rank p ≥ fingerprint.len has no covering size — the row width is
            // undeterminable. Reject before slicing (validate before alloc). (len==64 ⇒ every bit valid.)
            if (fingerprint.len < 64 and (mask >> @as(u6, @intCast(fingerprint.len))) != 0) {
                return error.Corrupt;
            }
            // popCount(mask) ≤ fingerprint.len ≤ 64, so this alloc is bounded by the row's own (already
            // consumed) header — never by an unjustified count. (A hostile all-size-0 fingerprint can
            // make a 16-byte row allocate ~64 zero-byte cells: a bounded, input-PROPORTIONAL constant
            // factor, not an unbounded blow-up — size-0 is legitimate for field-less tag components.)
            const comps = try a.alloc(KindRecord, @as(usize, @popCount(mask)));
            var ci: usize = 0;
            for (fingerprint, 0..) |fp, p| {
                if ((mask & (@as(u64, 1) << @as(u6, @intCast(p)))) != 0) {
                    const raw = try reader.readSlice(fp.size);
                    comps[ci] = .{ .kind_id = fp.kind_id, .bytes = try a.dupe(u8, raw) };
                    ci += 1;
                }
            }
            try rows.append(a, .{ .entity = .{ .index = idx, .generation = gen }, .mask = mask, .comps = comps });
        }
    }

    return .{
        .format_version = format_version,
        .schema_version = schema_version,
        .tick = tick,
        .fingerprint = fingerprint,
        .gens = gens.items,
        .outs = outs.items,
        .rng_seed = rng_seed,
        .rows = rows.items,
        .arena = arena,
    };
}

// --- encode ---------------------------------------------------------------------------------------

/// Canonical row order = indices into `rows` argsorted by ascending (unique) `entity.index`, matching
/// `serialize`'s `canonicalOrder`. Indices are unique, so the permutation is fully determined.
fn canonicalRowOrder(gpa: Allocator, rows: []const RowRecord) Allocator.Error![]usize {
    const order = try gpa.alloc(usize, rows.len);
    errdefer gpa.free(order);
    for (order, 0..) |*o, i| o.* = i;
    const Ctx = struct {
        rows: []const RowRecord,
        fn lessThan(ctx: @This(), ai: usize, bi: usize) bool {
            return ctx.rows[ai].entity.index < ctx.rows[bi].entity.index;
        }
    };
    std.mem.sort(usize, order, Ctx{ .rows = rows }, Ctx.lessThan);
    return order;
}

/// Re-emit `image` as a serialize image in `R_target`'s schema, byte-identical to `serialize.writeWorld`
/// for equivalent content. The mask is REBUILT from `R_target`'s kind set (so a row's stored mask is
/// never trusted — any spurious high bit is simply ignored, mirroring serialize's `@truncate` totality),
/// and cells are re-selected + re-ordered into ascending `R_target` kind_id. A cell whose `kind_id` is
/// absent from `R_target` is dropped; a kind `R_target` expects but the row lacks leaves its bit unset.
/// Returns a caller-owned byte buffer.
pub fn encode(comptime R_target: type, gpa: Allocator, image: *const Image) (serialize.Error || Allocator.Error)!std.ArrayList(u8) {
    // Guard: for every kind R_target expects that the image ALSO carries, the canonical widths must
    // agree — otherwise encode would emit `image`-width bytes where readWorld(R_target) expects
    // R_target-width bytes, silently producing a corrupt stream. (A kind the image lacks is fine — its
    // bit stays unset; an extra image kind absent from R_target is fine — it is dropped.) This makes the
    // "canonical by construction" claim TOTAL: a shared-kind width mismatch is an explicit SchemaMismatch
    // rather than silent corruption, regardless of how `image` was produced.
    inline for (R_target.sorted) |ti| {
        const want: u32 = @intCast(comptime serialize.serializedSizeOf(R_target.Component(ti)));
        for (image.fingerprint) |fp| {
            if (fp.kind_id == R_target.kindId(ti) and fp.size != want) return error.SchemaMismatch;
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };

    // header (mirrors serialize.writeWorld exactly)
    try sink.update(&serialize.MAGIC);
    try serialize.putInt(&sink, u16, serialize.FORMAT_VERSION);
    try serialize.putInt(&sink, u32, image.schema_version);
    try serialize.putInt(&sink, u64, image.tick);
    try serialize.putInt(&sink, u16, @intCast(R_target.count));
    try serialize.putInt(&sink, u32, @intCast(image.rows.len));

    // per-Kind fingerprint from R_target (comptime), ascending kind_id
    inline for (R_target.sorted) |ti| {
        try serialize.putInt(&sink, u16, R_target.kindId(ti));
        try serialize.putInt(&sink, u32, @intCast(comptime serialize.serializedSizeOf(R_target.Component(ti))));
    }

    // entity allocator
    try serialize.putInt(&sink, u32, @intCast(image.gens.len));
    for (image.gens) |g| try serialize.putInt(&sink, u32, g);
    try serialize.putInt(&sink, u32, @intCast(image.outs.len));
    for (image.outs) |o| try serialize.putInt(&sink, u32, o);

    // rng root
    try serialize.putInt(&sink, u64, image.rng_seed);

    // rows in canonical entity.index order
    const order = try canonicalRowOrder(gpa, image.rows);
    defer gpa.free(order);
    for (order) |ri| {
        const row = image.rows[ri];
        try serialize.putInt(&sink, u32, row.entity.index);
        try serialize.putInt(&sink, u32, row.entity.generation);
        var new_mask: u64 = 0;
        inline for (R_target.sorted, 0..) |ti, p| {
            if (findComp(row, R_target.kindId(ti)) != null) new_mask |= @as(u64, 1) << @as(u6, @intCast(p));
        }
        try serialize.putInt(&sink, u64, new_mask);
        inline for (R_target.sorted) |ti| {
            if (findComp(row, R_target.kindId(ti))) |c| try sink.update(c.bytes);
        }
    }
    return buf;
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("../registry.zig").Registry;
const storage = @import("../storage.zig");
const EntityAllocator = entity.EntityAllocator;

const Position = struct {
    x: fpz.Fixed,
    y: fpz.Fixed,
    pub const kind_id: u16 = 10;
};
const Velocity = struct {
    dx: fpz.Fixed,
    pub const kind_id: u16 = 5;
};
const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 20;
};
const Reg = Registry(.{ Position, Velocity, Health });
const RegVelHealth = Registry(.{ Velocity, Health }); // drops Position (kind 10)
const RegVel = Registry(.{Velocity});

/// Mirror of serialize's buildParts: entities 0,1,2 spawned, entity 1 freed (allocator churn), with
/// Position+Velocity on e0 and Health on e2.
fn buildParts(gpa: Allocator) !serialize.Parts(Reg) {
    var entities: EntityAllocator = .{};
    errdefer entities.deinit(gpa);
    const e0 = try entities.alloc(gpa);
    const e1 = try entities.alloc(gpa);
    const e2 = try entities.alloc(gpa);
    try entities.free(gpa, e1);

    var table: storage.Table(Reg) = .{};
    errdefer table.deinit(gpa);
    _ = try table.spawnRow(gpa, e0);
    _ = try table.spawnRow(gpa, e2);
    table.addComponent(e0, Position, .{ .x = fpz.Fixed.fromInt(3), .y = fpz.Fixed.fromInt(-4) });
    table.addComponent(e0, Velocity, .{ .dx = fpz.Fixed.HALF });
    table.addComponent(e2, Health, .{ .hp = 77 });

    return .{ .tick = 42, .schema_version = 1, .rng_root = .{ .seed = 0xDEAD }, .entities = entities, .table = table };
}

fn serializeBytes(gpa: Allocator, comptime R: type, parts: anytype) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try serialize.writeWorld(R, gpa, &sink, parts);
    return buf;
}

test "identity round-trip: encode(decode(writeWorld bytes), SAME R) == original, byte-for-byte" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);
    var bytes = try serializeBytes(gpa, Reg, &parts);
    defer bytes.deinit(gpa);

    var img = try decode(gpa, bytes.items);
    defer img.deinit();
    var out = try encode(Reg, gpa, &img);
    defer out.deinit(gpa);

    try testing.expectEqualSlices(u8, bytes.items, out.items);
}

test "decode recovers fingerprint, gens/outs, rng_seed, tick, and per-row (entity,mask,cells)" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);
    var bytes = try serializeBytes(gpa, Reg, &parts);
    defer bytes.deinit(gpa);
    var img = try decode(gpa, bytes.items);
    defer img.deinit();

    try testing.expectEqual(@as(u16, serialize.FORMAT_VERSION), img.format_version);
    try testing.expectEqual(@as(u32, 1), img.schema_version);
    try testing.expectEqual(@as(u64, 42), img.tick);
    try testing.expectEqual(@as(u64, 0xDEAD), img.rng_seed);

    // fingerprint ascending kind_id: 5 (Velocity, 8), 10 (Position, 16), 20 (Health, 4)
    try testing.expectEqual(@as(usize, 3), img.fingerprint.len);
    try testing.expectEqual(@as(u16, 5), img.fingerprint[0].kind_id);
    try testing.expectEqual(@as(u32, 8), img.fingerprint[0].size);
    try testing.expectEqual(@as(u16, 10), img.fingerprint[1].kind_id);
    try testing.expectEqual(@as(u32, 16), img.fingerprint[1].size);
    try testing.expectEqual(@as(u16, 20), img.fingerprint[2].kind_id);
    try testing.expectEqual(@as(u32, 4), img.fingerprint[2].size);

    // allocator churn: 3 generations, entity 1 outstanding-free
    try testing.expectEqual(@as(usize, 3), img.gens.len);
    try testing.expectEqual(@as(usize, 1), img.outs.len);
    try testing.expectEqual(@as(u32, 1), img.outs[0]);

    // rows in canonical order: e0 (index 0) has Velocity+Position; e2 (index 2) has Health
    try testing.expectEqual(@as(usize, 2), img.rows.len);
    try testing.expectEqual(@as(u32, 0), img.rows[0].entity.index);
    try testing.expectEqual(@as(u64, 0b011), img.rows[0].mask); // ranks 0 (V) + 1 (P)
    try testing.expectEqual(@as(usize, 2), img.rows[0].comps.len);
    try testing.expectEqual(@as(u16, 5), img.rows[0].comps[0].kind_id);
    try testing.expectEqual(@as(usize, 8), img.rows[0].comps[0].bytes.len);
    try testing.expectEqual(@as(u16, 10), img.rows[0].comps[1].kind_id);
    try testing.expectEqual(@as(usize, 16), img.rows[0].comps[1].bytes.len);
    try testing.expectEqual(@as(u32, 2), img.rows[1].entity.index);
    try testing.expectEqual(@as(u64, 0b100), img.rows[1].mask); // rank 2 (H)
    try testing.expectEqual(@as(u16, 20), img.rows[1].comps[0].kind_id);
    try testing.expectEqual(@as(usize, 4), img.rows[1].comps[0].bytes.len);
}

test "decode of a truncated image returns Truncated (never panics)" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);
    var bytes = try serializeBytes(gpa, Reg, &parts);
    defer bytes.deinit(gpa);
    try testing.expectError(error.Truncated, decode(gpa, bytes.items[0..10]));
}

test "decode of an unexpected FORMAT_VERSION returns UnsupportedFormat" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);
    var bytes = try serializeBytes(gpa, Reg, &parts);
    defer bytes.deinit(gpa);
    bytes.items[4] = 0xFF; // format_version (u16) is right after the 4-byte magic
    try testing.expectError(error.UnsupportedFormat, decode(gpa, bytes.items));
}

/// Hand-build a minimal image with a controllable mask, to exercise the decode/encode edges that a
/// well-formed kernel image can't reach.
fn handImage(gpa: Allocator, kind_count: u16, fp: []const KindFp, mask: u64, cell_bytes: []const u8) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try sink.update(&serialize.MAGIC);
    try serialize.putInt(&sink, u16, serialize.FORMAT_VERSION);
    try serialize.putInt(&sink, u32, 1); // schema_version
    try serialize.putInt(&sink, u64, 0); // tick
    try serialize.putInt(&sink, u16, kind_count);
    try serialize.putInt(&sink, u32, 1); // row_count
    for (fp) |f| {
        try serialize.putInt(&sink, u16, f.kind_id);
        try serialize.putInt(&sink, u32, f.size);
    }
    try serialize.putInt(&sink, u32, 0); // gen_count
    try serialize.putInt(&sink, u32, 0); // out_count
    try serialize.putInt(&sink, u64, 0); // rng_seed
    try serialize.putInt(&sink, u32, 0); // row entity index
    try serialize.putInt(&sink, u32, 0); // row entity generation
    try serialize.putInt(&sink, u64, mask);
    try sink.update(cell_bytes);
    return buf;
}

test "decode where a mask bit has no covering fingerprint entry returns Corrupt" {
    const gpa = testing.allocator;
    // one kind (rank 0 valid); a row mask with bit 1 set is unsizeable.
    var bytes = try handImage(gpa, 1, &.{.{ .kind_id = 7, .size = 4 }}, 0b10, &.{ 0, 0, 0, 0 });
    defer bytes.deinit(gpa);
    try testing.expectError(error.Corrupt, decode(gpa, bytes.items));
}

test "decode rejects a fingerprint claiming more than 64 kinds (Corrupt, no shift overflow)" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try sink.update(&serialize.MAGIC);
    try serialize.putInt(&sink, u16, serialize.FORMAT_VERSION);
    try serialize.putInt(&sink, u32, 1);
    try serialize.putInt(&sink, u64, 0);
    try serialize.putInt(&sink, u16, 65); // kind_count > 64
    try testing.expectError(error.Corrupt, decode(gpa, buf.items));
}

test "encode into a DIFFERENT R_target re-sorts cells, rebuilds the mask, and readWorld accepts it" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);
    var bytes = try serializeBytes(gpa, Reg, &parts);
    defer bytes.deinit(gpa);
    var img = try decode(gpa, bytes.items);
    defer img.deinit();

    // re-emit into a registry that DROPS Position (kind 10): e0 keeps only Velocity, e2 keeps Health.
    var out = try encode(RegVelHealth, gpa, &img);
    defer out.deinit(gpa);
    var reader = serialize.ByteReader{ .bytes = out.items };
    var restored = try serialize.readWorld(RegVelHealth, gpa, &reader);
    defer restored.deinit(gpa);

    const e0 = Entity{ .index = 0, .generation = 0 };
    const e2 = Entity{ .index = 2, .generation = 0 };
    try testing.expectEqual(fpz.Fixed.HALF.raw, restored.table.get(e0, Velocity).?.dx.raw);
    try testing.expectEqual(@as(i32, 77), restored.table.get(e2, Health).?.hp);
    try testing.expect(!restored.table.has(e0, Health));
}

test "encode rejects a shared-kind WIDTH mismatch (SchemaMismatch, not a silent corrupt stream)" {
    const gpa = testing.allocator;
    // Hand-build an image whose fingerprint claims Velocity (kind 5) is 4 bytes; RegVel expects 8. The
    // kind is shared between image and R_target but the widths disagree -> must be rejected.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const comps = try a.alloc(KindRecord, 1);
    comps[0] = .{ .kind_id = 5, .bytes = try a.dupe(u8, &.{ 0, 0, 0, 0 }) }; // 4 bytes (wrong for Velocity)
    const rows = try a.alloc(RowRecord, 1);
    rows[0] = .{ .entity = .{ .index = 0, .generation = 0 }, .mask = 0b1, .comps = comps };
    var img = Image{
        .format_version = serialize.FORMAT_VERSION,
        .schema_version = 1,
        .tick = 0,
        .fingerprint = &.{.{ .kind_id = 5, .size = 4 }},
        .gens = &.{},
        .outs = &.{},
        .rng_seed = 0,
        .rows = rows,
        .arena = arena,
    };
    try testing.expectError(error.SchemaMismatch, encode(RegVel, gpa, &img));
}

test "encode ignores a row's spurious high mask bits and rebuilds from R_target (no panic)" {
    const gpa = testing.allocator;
    // Hand-build an Image (not via decode, which would reject the wide mask) whose row.mask has bit 40
    // set but whose only cell is Velocity (kind 5). encode(RegVel) must rebuild mask=0b1 and emit the
    // 8 Velocity bytes regardless of the bogus stored mask.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var vbuf: std.ArrayList(u8) = .empty;
    var vsink = serialize.ByteSink{ .list = &vbuf, .gpa = a };
    try serialize.writeValue(&vsink, Velocity, .{ .dx = fpz.Fixed.fromInt(2) });
    const comps = try a.alloc(KindRecord, 1);
    comps[0] = .{ .kind_id = 5, .bytes = vbuf.items };
    const rows = try a.alloc(RowRecord, 1);
    rows[0] = .{ .entity = .{ .index = 0, .generation = 0 }, .mask = @as(u64, 1) << 40, .comps = comps };
    var img = Image{
        .format_version = serialize.FORMAT_VERSION,
        .schema_version = 1,
        .tick = 0,
        .fingerprint = &.{.{ .kind_id = 5, .size = 8 }},
        .gens = &.{},
        .outs = &.{},
        .rng_seed = 0,
        .rows = rows,
        .arena = arena, // moved; arena.deinit() above still valid (struct copied, buffers shared)
    };
    var out = try encode(RegVel, gpa, &img);
    defer out.deinit(gpa);
    var reader = serialize.ByteReader{ .bytes = out.items };
    var restored = try serialize.readWorld(RegVel, gpa, &reader);
    defer restored.deinit(gpa);
    try testing.expectEqual(fpz.Fixed.fromInt(2).raw, restored.table.get(.{ .index = 0, .generation = 0 }, Velocity).?.dx.raw);
}
