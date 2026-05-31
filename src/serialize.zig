//! Canonical serialization codec (SPEC §3/§6, PLAN.md build-order step 6; resolves Q6/Q7).
//!
//! Serializing the World produces a byte-exact, cross-architecture-stable image. Two invariants make
//! it deterministic (D5):
//!   1. **Field-by-field little-endian.** Every leaf integer is emitted via an explicit byte loop in
//!      `.little` order; structs recurse in `@typeInfo` *declaration* order. Raw struct memory is never
//!      touched, so padding bytes and host endianness can never reach the stream (Q7). `putInt` handles
//!      arbitrary bit widths (e.g. a `u3` presence mask, an `i12` field), so nothing is constrained to
//!      byte-multiple widths.
//!   2. **Stable total ordering.** Components are visited in ascending `kind_id` (`R.sorted`); rows in
//!      canonical by-entity order (argsort on the unique `entity.index`). Physical row order
//!      (swap-remove history) never appears.
//!
//! The traversal is generic over an `anytype` *sink* exposing `update(bytes) !void`. `ByteSink` appends
//! to a buffer (snapshots); hash.zig supplies a hashing sink. Because hash and snapshot share this one
//! traversal, the content hash is provably over the canonical serialization (D5) — no duplicated
//! ordering logic, and the hash needs no materialized buffer.
//!
//! Restore is the inverse, reading kernel-produced (trusted) bytes. The header carries a magic, a
//! format version, and a per-Kind `{kind_id, serialized_size}` fingerprint that anchors §12 migration
//! and rejects a mismatched registry; an unknown/short/garbled image is a returned error, not a panic.

const std = @import("std");
const entity = @import("entity.zig");
const storage = @import("storage.zig");
const rng = @import("rng.zig");
const Entity = entity.Entity;
const EntityAllocator = entity.EntityAllocator;
const Allocator = std.mem.Allocator;

pub const MAGIC = [4]u8{ 'G', 'K', 'Z', '1' };
pub const FORMAT_VERSION: u16 = 1;

pub const Error = error{ BadMagic, UnsupportedFormat, SchemaMismatch, Truncated, Corrupt };

/// The deserialized World contents (world.zig assembles a `World` from these).
pub fn Parts(comptime R: type) type {
    return struct {
        tick: u64,
        schema_version: u32,
        rng_root: rng.RngRoot,
        entities: EntityAllocator,
        table: storage.Table(R),

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            self.entities.deinit(gpa);
            self.table.deinit(gpa);
            self.* = undefined;
        }
    };
}

// --- byte sinks / readers -------------------------------------------------------------------------

/// A sink that appends the canonical bytes to a caller-owned buffer (the snapshot path).
pub const ByteSink = struct {
    list: *std.ArrayList(u8),
    gpa: Allocator,
    pub fn update(self: *ByteSink, bytes: []const u8) Allocator.Error!void {
        try self.list.appendSlice(self.gpa, bytes);
    }
};

/// A forward byte cursor over a serialized image.
pub const ByteReader = struct {
    bytes: []const u8,
    pos: usize = 0,
    pub fn readByte(self: *ByteReader) Error!u8 {
        if (self.pos >= self.bytes.len) return error.Truncated;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }
    pub fn readSlice(self: *ByteReader, n: usize) Error![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Truncated;
        defer self.pos += n;
        return self.bytes[self.pos .. self.pos + n];
    }
};

// --- leaf codecs ----------------------------------------------------------------------------------

/// Comptime: the number of bytes a value of type `T` occupies in the canonical stream (the sum of leaf
/// byte-widths — independent of in-memory padding/layout). Used for the per-Kind schema fingerprint.
pub fn serializedSizeOf(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .int => |i| (i.bits + 7) / 8,
        .bool => 1,
        .@"enum" => |e| serializedSizeOf(e.tag_type),
        .@"struct" => |s| blk: {
            var n: usize = 0;
            inline for (s.fields) |f| n += serializedSizeOf(f.type);
            break :blk n;
        },
        .array => |a| a.len * serializedSizeOf(a.child),
        else => @compileError("non-serializable type: " ++ @typeName(T)),
    };
}

/// Refuse to encode/decode a POINTER-WIDTH integer. `usize`/`isize` are the host word width
/// (`@typeInfo(usize).int.bits` is 64 on a 64-bit target, 32 on a 32-bit one), so serializing one would
/// emit a different number of bytes per architecture and break cross-architecture bit-identity (SPEC §2,
/// proven by `zig build cross`). The codec is fixed-width BY CONSTRUCTION; this makes that invariant
/// structural — a future `usize`/`isize` on the wire is a compile error, not a silent 32-bit divergence
/// the cross gate would otherwise have to catch. Sits alongside the D7 (float) / D8 (pointer) guards in
/// registry.assertSerializable. Cast to an explicit fixed-width int (u16/u32/u64/i64/…) at the call site.
inline fn assertFixedWidth(comptime T: type) void {
    comptime if (T == usize or T == isize) @compileError("serialize: refusing to encode pointer-width int '" ++ @typeName(T) ++ "' — usize/isize are the host word width and would break cross-arch bit-identity (SPEC §2). Cast to a fixed-width int at the call site.");
}

/// Write an integer of any bit width as ceil(bits/8) little-endian bytes (zero-extended to the byte
/// boundary). Inverse of `getInt`.
pub fn putInt(sink: anytype, comptime T: type, v: T) !void {
    comptime assertFixedWidth(T);
    const bits = @typeInfo(T).int.bits;
    const nbytes = (bits + 7) / 8;
    const UB = std.meta.Int(.unsigned, bits);
    const W = std.meta.Int(.unsigned, nbytes * 8);
    const wv: W = @as(UB, @bitCast(v)); // exact-width bit pattern, zero-extended to a byte multiple
    var buf: [nbytes]u8 = undefined;
    inline for (0..nbytes) |k| buf[k] = @truncate(wv >> (8 * k));
    try sink.update(&buf);
}

pub fn getInt(reader: *ByteReader, comptime T: type) Error!T {
    comptime assertFixedWidth(T);
    const bits = @typeInfo(T).int.bits;
    const nbytes = (bits + 7) / 8;
    const W = std.meta.Int(.unsigned, nbytes * 8);
    var wv: W = 0;
    inline for (0..nbytes) |k| {
        wv |= @as(W, try reader.readByte()) << (8 * k);
    }
    const UB = std.meta.Int(.unsigned, bits);
    const ubits: UB = @truncate(wv);
    return @bitCast(ubits);
}

/// Write any POD value field-by-field, little-endian. Inverse of `readValue`.
pub fn writeValue(sink: anytype, comptime T: type, v: T) !void {
    switch (@typeInfo(T)) {
        .int => try putInt(sink, T, v),
        .bool => {
            var b = [1]u8{@intFromBool(v)};
            try sink.update(&b);
        },
        .@"enum" => |e| try putInt(sink, e.tag_type, @intFromEnum(v)),
        .@"struct" => |s| inline for (s.fields) |f| try writeValue(sink, f.type, @field(v, f.name)),
        .array => |a| for (v) |elem| try writeValue(sink, a.child, elem),
        else => @compileError("non-serializable type: " ++ @typeName(T)),
    }
}

pub fn readValue(comptime T: type, reader: *ByteReader) Error!T {
    return switch (@typeInfo(T)) {
        .int => try getInt(reader, T),
        .bool => (try reader.readByte()) != 0,
        .@"enum" => |e| blk: {
            const raw = try getInt(reader, e.tag_type);
            // Validate exhaustive tags so a corrupt/garbled image is a returned error, not UB/panic
            // (D2). Non-exhaustive enums accept any value by definition.
            if (e.is_exhaustive) {
                inline for (e.fields) |f| {
                    if (@as(e.tag_type, f.value) == raw) break :blk @enumFromInt(raw);
                }
                return error.Corrupt;
            }
            break :blk @enumFromInt(raw);
        },
        .@"struct" => |s| blk: {
            var v: T = undefined;
            inline for (s.fields) |f| @field(v, f.name) = try readValue(f.type, reader);
            break :blk v;
        },
        .array => |a| blk: {
            var v: T = undefined;
            for (&v) |*elem| elem.* = try readValue(a.child, reader);
            break :blk v;
        },
        else => @compileError("non-serializable type: " ++ @typeName(T)),
    };
}

// --- World <-> bytes ------------------------------------------------------------------------------

/// Serialize a World (or `Parts`) into `sink` in canonical order. `world` is anything exposing
/// `.tick`, `.schema_version`, `.rng_root`, `.entities`, `.table` (pass a pointer). `gpa` is needed to
/// compute the canonical row order.
pub fn writeWorld(comptime R: type, gpa: Allocator, sink: anytype, world: anytype) !void {
    // header
    try sink.update(&MAGIC);
    try putInt(sink, u16, FORMAT_VERSION);
    try putInt(sink, u32, world.schema_version);
    try putInt(sink, u64, world.tick);
    try putInt(sink, u16, @intCast(R.count));

    const order = try world.table.canonicalOrder(gpa);
    defer gpa.free(order);
    try putInt(sink, u32, @intCast(order.len));

    // per-Kind schema fingerprint, ascending kind_id (§12 migration anchor)
    inline for (R.sorted) |ti| {
        try putInt(sink, u16, R.kindId(ti));
        try putInt(sink, u32, @intCast(comptime serializedSizeOf(R.Component(ti))));
    }

    // entity allocator (canonical: full generation array, then the outstanding FIFO free queue)
    const gens = world.entities.generation.items;
    try putInt(sink, u32, @intCast(gens.len));
    for (gens) |g| try putInt(sink, u32, g);
    const outs = world.entities.outstandingFree();
    try putInt(sink, u32, @intCast(outs.len));
    for (outs) |o| try putInt(sink, u32, o);

    // rng root
    try putInt(sink, u64, world.rng_root.seed);

    // table rows in canonical order
    const masks = world.table.masks();
    const owners = world.table.owners();
    for (order) |row| {
        try putInt(sink, u32, owners[row].index);
        try putInt(sink, u32, owners[row].generation);
        const m: u64 = @intCast(masks[row]);
        try putInt(sink, u64, m);
        inline for (R.sorted, 0..) |ti, p| {
            if ((m & (@as(u64, 1) << @intCast(p))) != 0) {
                try writeValue(sink, R.Component(ti), world.table.columnConst(ti)[row]);
            }
        }
    }
}

/// Deserialize a World image into `Parts(R)`. The caller owns and must `deinit` the result. Reads
/// kernel-produced bytes; a malformed image returns an `Error`.
pub fn readWorld(comptime R: type, gpa: Allocator, reader: *ByteReader) (Error || Allocator.Error)!Parts(R) {
    const magic = try reader.readSlice(4);
    if (!std.mem.eql(u8, magic, &MAGIC)) return error.BadMagic;
    if (try getInt(reader, u16) != FORMAT_VERSION) return error.UnsupportedFormat;
    const schema_version = try getInt(reader, u32);
    const tick = try getInt(reader, u64);
    if (try getInt(reader, u16) != @as(u16, @intCast(R.count))) return error.SchemaMismatch;
    const row_count = try getInt(reader, u32);

    inline for (R.sorted) |ti| {
        if (try getInt(reader, u16) != R.kindId(ti)) return error.SchemaMismatch;
        if (try getInt(reader, u32) != @as(u32, @intCast(comptime serializedSizeOf(R.Component(ti))))) {
            return error.SchemaMismatch;
        }
    }

    const gen_count = try getInt(reader, u32);
    const gens = try gpa.alloc(u32, gen_count);
    defer gpa.free(gens);
    for (gens) |*g| g.* = try getInt(reader, u32);
    const out_count = try getInt(reader, u32);
    const outs = try gpa.alloc(u32, out_count);
    defer gpa.free(outs);
    for (outs) |*o| o.* = try getInt(reader, u32);

    var entities = try EntityAllocator.fromParts(gpa, gens, outs);
    errdefer entities.deinit(gpa);

    const seed = try getInt(reader, u64);

    var table: storage.Table(R) = .{};
    errdefer table.deinit(gpa);
    var i: u32 = 0;
    while (i < row_count) : (i += 1) {
        const idx = try getInt(reader, u32);
        const gen = try getInt(reader, u32);
        const m = try getInt(reader, u64);
        const e = Entity{ .index = idx, .generation = gen };
        const row = try table.spawnRow(gpa, e);
        table.masksMut()[row] = @truncate(m); // total: never panics on a wide mask
        inline for (R.sorted, 0..) |ti, p| {
            if ((m & (@as(u64, 1) << @intCast(p))) != 0) {
                table.column(ti)[row] = try readValue(R.Component(ti), reader);
            }
        }
    }

    return .{
        .tick = tick,
        .schema_version = schema_version,
        .rng_root = .{ .seed = seed },
        .entities = entities,
        .table = table,
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("registry.zig").Registry;

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

/// Build a small Parts for tests: entities 0,1,2 spawned, entity 1 freed (allocator churn), with
/// components on the survivors. The table is constructed directly with chosen handles.
fn buildParts(gpa: Allocator) !Parts(Reg) {
    var entities: EntityAllocator = .{};
    errdefer entities.deinit(gpa);
    const e0 = try entities.alloc(gpa);
    const e1 = try entities.alloc(gpa);
    const e2 = try entities.alloc(gpa);
    try entities.free(gpa, e1); // churn: gen[1]=1, outstanding=[1]

    var table: storage.Table(Reg) = .{};
    errdefer table.deinit(gpa);
    _ = try table.spawnRow(gpa, e0);
    _ = try table.spawnRow(gpa, e2);
    table.addComponent(e0, Position, .{ .x = fpz.Fixed.fromInt(3), .y = fpz.Fixed.fromInt(-4) });
    table.addComponent(e0, Velocity, .{ .dx = fpz.Fixed.HALF });
    table.addComponent(e2, Health, .{ .hp = 77 });

    return .{ .tick = 42, .schema_version = 1, .rng_root = .{ .seed = 0xDEAD }, .entities = entities, .table = table };
}

fn serializeToBytes(gpa: Allocator, parts: anytype) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = ByteSink{ .list = &buf, .gpa = gpa };
    try writeWorld(Reg, gpa, &sink, parts);
    return buf;
}

test "serialize -> restore -> re-serialize is byte-identical" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);

    var bytes = try serializeToBytes(gpa, &parts);
    defer bytes.deinit(gpa);

    var reader = ByteReader{ .bytes = bytes.items };
    var restored = try readWorld(Reg, gpa, &reader);
    defer restored.deinit(gpa);

    try testing.expectEqual(@as(u64, 42), restored.tick);
    try testing.expectEqual(@as(u64, 0xDEAD), restored.rng_root.seed);

    var bytes2 = try serializeToBytes(gpa, &restored);
    defer bytes2.deinit(gpa);
    try testing.expectEqualSlices(u8, bytes.items, bytes2.items);
}

test "restored component values match the original" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);
    var bytes = try serializeToBytes(gpa, &parts);
    defer bytes.deinit(gpa);
    var reader = ByteReader{ .bytes = bytes.items };
    var restored = try readWorld(Reg, gpa, &reader);
    defer restored.deinit(gpa);

    const e0 = Entity{ .index = 0, .generation = 0 };
    const e2 = Entity{ .index = 2, .generation = 0 };
    try testing.expectEqual(@as(i64, 3), restored.table.get(e0, Position).?.x.toInt());
    try testing.expectEqual(@as(i64, -4), restored.table.get(e0, Position).?.y.toInt());
    try testing.expectEqual(fpz.Fixed.HALF.raw, restored.table.get(e0, Velocity).?.dx.raw);
    try testing.expectEqual(@as(i32, 77), restored.table.get(e2, Health).?.hp);
    try testing.expect(!restored.table.has(e2, Position));
    try testing.expectEqual(@as(?u32, null), restored.table.rowOf(.{ .index = 1, .generation = 0 }));
}

test "byte image is invariant to physical row order (canonical sort severs swap-remove history)" {
    const gpa = testing.allocator;
    // Same logical contents and identical allocator state, two different physical row orders.
    const e0 = Entity{ .index = 0, .generation = 0 };
    const e1 = Entity{ .index = 1, .generation = 0 };
    const e2 = Entity{ .index = 2, .generation = 0 };

    var allocA: EntityAllocator = .{};
    _ = try allocA.alloc(gpa);
    _ = try allocA.alloc(gpa);
    _ = try allocA.alloc(gpa);
    const allocB = try allocA.clone(gpa);

    var tA: storage.Table(Reg) = .{};
    _ = try tA.spawnRow(gpa, e0);
    _ = try tA.spawnRow(gpa, e1);
    _ = try tA.spawnRow(gpa, e2);
    tA.addComponent(e1, Health, .{ .hp = 5 });

    var tB: storage.Table(Reg) = .{};
    _ = try tB.spawnRow(gpa, e2); // different physical order
    _ = try tB.spawnRow(gpa, e0);
    _ = try tB.spawnRow(gpa, e1);
    tB.addComponent(e1, Health, .{ .hp = 5 });

    var pA = Parts(Reg){ .tick = 1, .schema_version = 1, .rng_root = .{ .seed = 9 }, .entities = allocA, .table = tA };
    defer pA.deinit(gpa);
    var pB = Parts(Reg){ .tick = 1, .schema_version = 1, .rng_root = .{ .seed = 9 }, .entities = allocB, .table = tB };
    defer pB.deinit(gpa);

    var bA = try serializeToBytes(gpa, &pA);
    defer bA.deinit(gpa);
    var bB = try serializeToBytes(gpa, &pB);
    defer bB.deinit(gpa);
    try testing.expectEqualSlices(u8, bA.items, bB.items);
}

test "field-by-field serialization excludes struct padding" {
    const gpa = testing.allocator;
    // extern struct with 7 bytes of padding between `a` and `b`; serialized size must be 1+8 = 9.
    const Padded = extern struct { a: u8, b: u64 };
    try testing.expect(@sizeOf(Padded) >= 16); // memory layout has padding
    try testing.expectEqual(@as(usize, 9), serializedSizeOf(Padded));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = ByteSink{ .list = &buf, .gpa = gpa };
    try writeValue(&sink, Padded, .{ .a = 0xAB, .b = 0x1122334455667788 });
    try testing.expectEqual(@as(usize, 9), buf.items.len); // no padding bytes emitted
    try testing.expectEqual(@as(u8, 0xAB), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x88), buf.items[1]); // little-endian low byte of b
}

test "arbitrary-width integers round-trip" {
    const gpa = testing.allocator;
    inline for (.{ u3, i12, u17, i7, u1 }) |T| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var sink = ByteSink{ .list = &buf, .gpa = gpa };
        const UB = std.meta.Int(.unsigned, @bitSizeOf(T));
        const v: T = @bitCast(@as(UB, @truncate(@as(u64, 0x5A))));
        try putInt(&sink, T, v);
        var reader = ByteReader{ .bytes = buf.items };
        try testing.expectEqual(v, try getInt(&reader, T));
    }
}

test "restore rejects bad magic and truncation" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);
    var bytes = try serializeToBytes(gpa, &parts);
    defer bytes.deinit(gpa);

    // corrupt magic
    var bad = try bytes.clone(gpa);
    defer bad.deinit(gpa);
    bad.items[0] = 'X';
    var r1 = ByteReader{ .bytes = bad.items };
    try testing.expectError(error.BadMagic, readWorld(Reg, gpa, &r1));

    // truncated
    var r2 = ByteReader{ .bytes = bytes.items[0..10] };
    try testing.expectError(error.Truncated, readWorld(Reg, gpa, &r2));
}

// --- additional coverage (adversarial review: tests#0/#2/#3, zig#0) ---

const HealthAlt = struct {
    hp: i32,
    pub const kind_id: u16 = 99; // same shape as Health, different id
};
const RegSmall = Registry(.{ Position, Velocity }); // count 2 vs Reg's 3
const RegDiff = Registry(.{ Position, Velocity, HealthAlt }); // count 3, but a different kind_id

const Color = enum(u8) { red, green, blue };
const Fancy = struct {
    color: Color,
    coords: [3]i16,
    nested: struct { a: u8, b: i32 },
    pub const kind_id: u16 = 7;
};
const FancyReg = Registry(.{Fancy});

test "empty world round-trips byte-identically and hashes stably" {
    const gpa = testing.allocator;
    const entities: EntityAllocator = .{};
    const table: storage.Table(Reg) = .{};
    var parts = Parts(Reg){ .tick = 0, .schema_version = 1, .rng_root = .{ .seed = 0 }, .entities = entities, .table = table };
    defer parts.deinit(gpa);

    var b1 = try serializeToBytes(gpa, &parts);
    defer b1.deinit(gpa);
    var reader = ByteReader{ .bytes = b1.items };
    var restored = try readWorld(Reg, gpa, &reader);
    defer restored.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), restored.table.rowCount());
    var b2 = try serializeToBytes(gpa, &restored);
    defer b2.deinit(gpa);
    try testing.expectEqualSlices(u8, b1.items, b2.items);
}

test "restore rejects a registry with a different component count (SchemaMismatch)" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);
    var bytes = try serializeToBytes(gpa, &parts);
    defer bytes.deinit(gpa);
    var reader = ByteReader{ .bytes = bytes.items };
    try testing.expectError(error.SchemaMismatch, readWorld(RegSmall, gpa, &reader));
}

test "restore rejects a matching count but a changed kind_id (SchemaMismatch)" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);
    var bytes = try serializeToBytes(gpa, &parts);
    defer bytes.deinit(gpa);
    var reader = ByteReader{ .bytes = bytes.items };
    try testing.expectError(error.SchemaMismatch, readWorld(RegDiff, gpa, &reader));
}

test "restore rejects an unsupported format version" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);
    var bytes = try serializeToBytes(gpa, &parts);
    defer bytes.deinit(gpa);
    bytes.items[4] = 0xFF; // format_version is the u16 right after the 4-byte magic
    var reader = ByteReader{ .bytes = bytes.items };
    try testing.expectError(error.UnsupportedFormat, readWorld(Reg, gpa, &reader));
}

test "enum, fixed-array, and nested-struct component fields round-trip" {
    const gpa = testing.allocator;
    var entities: EntityAllocator = .{};
    const e = try entities.alloc(gpa);
    var table: storage.Table(FancyReg) = .{};
    _ = try table.spawnRow(gpa, e);
    table.addComponent(e, Fancy, .{ .color = .green, .coords = .{ -1, 2, -3 }, .nested = .{ .a = 9, .b = -1000 } });
    var parts = Parts(FancyReg){ .tick = 1, .schema_version = 1, .rng_root = .{ .seed = 0 }, .entities = entities, .table = table };
    defer parts.deinit(gpa);

    var buf = try serializeToBytes2(gpa, FancyReg, &parts);
    defer buf.deinit(gpa);
    var reader = ByteReader{ .bytes = buf.items };
    var restored = try readWorld(FancyReg, gpa, &reader);
    defer restored.deinit(gpa);
    const got = restored.table.get(e, Fancy).?;
    try testing.expectEqual(Color.green, got.color);
    try testing.expectEqualSlices(i16, &.{ -1, 2, -3 }, &got.coords);
    try testing.expectEqual(@as(u8, 9), got.nested.a);
    try testing.expectEqual(@as(i32, -1000), got.nested.b);
}

test "a corrupt (out-of-range) exhaustive enum tag is rejected, not UB (Corrupt)" {
    const gpa = testing.allocator;
    var entities: EntityAllocator = .{};
    const e = try entities.alloc(gpa);
    var table: storage.Table(FancyReg) = .{};
    _ = try table.spawnRow(gpa, e);
    table.addComponent(e, Fancy, .{ .color = .red, .coords = .{ 0, 0, 0 }, .nested = .{ .a = 0, .b = 0 } });
    var parts = Parts(FancyReg){ .tick = 0, .schema_version = 1, .rng_root = .{ .seed = 0 }, .entities = entities, .table = table };
    defer parts.deinit(gpa);

    var buf = try serializeToBytes2(gpa, FancyReg, &parts);
    defer buf.deinit(gpa);
    // Fancy's bytes are last in the stream; `color` (1 byte) is its first field. Serialized Fancy size
    // = color(1) + coords(3*2) + nested(1+4) = 12, so the color byte is at len-12.
    buf.items[buf.items.len - 12] = 99; // not a valid Color tag (red/green/blue)
    var reader = ByteReader{ .bytes = buf.items };
    try testing.expectError(error.Corrupt, readWorld(FancyReg, gpa, &reader));
}

/// Like serializeToBytes but generic over the registry (the helper above is pinned to Reg).
fn serializeToBytes2(gpa: Allocator, comptime R: type, parts: anytype) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = ByteSink{ .list = &buf, .gpa = gpa };
    try writeWorld(R, gpa, &sink, parts);
    return buf;
}
