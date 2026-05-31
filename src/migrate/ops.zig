//! The declared per-Kind migration op vocabulary + leaf field helpers (PLAN.md Phase 8, §12).
//!
//! A `Migration` is a list of these `Op`s — the §12 "add field → default / remove → drop / rename → map"
//! vocabulary, made into data so a migration is INSPECTABLE (validateMigration checks the declared ops
//! exactly cover the fingerprint delta; catalog.zig can project them as §7 relations). Each op has two
//! pure, table-free interpretations applied during `migrate.apply`: `applyToFingerprint` (how it reshapes
//! the schema's `{kind_id,size}` list) and `applyToCells` (how it reshapes one row's component cells).
//! The two are kept consistent here so a row and the fingerprint can never drift.
//!
//! A `transform_kind` rewrite speaks the LEAF vocabulary via `FieldReader`/`FieldBuilder` (read the old
//! value's fields, write the new value's fields) — it never does raw byte math, so a migration is
//! structurally float-free (D7) and pointer-free (D8) like every other sim-path value. All bytes are
//! canonical little-endian (the same `serialize.putInt`/`getInt` the wire uses), so a transformed cell is
//! byte-compatible with `serialize.readWorld` by construction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const image = @import("image.zig");
const KindFp = image.KindFp;
const KindRecord = image.KindRecord;

/// The error set a `transform_kind` rewrite (and op application) may raise: a malformed read of the old
/// bytes (`serialize.Error`) or an allocation failure. A rewrite that emits the wrong number of bytes for
/// its declared `new_size` is `error.Corrupt` (it would produce a non-conformant image).
pub const ApplyError = serialize.Error || Allocator.Error;

/// A value rewrite: read the OLD canonical bytes (via a `FieldReader`), write the NEW value's leaves
/// (via the `FieldBuilder`). The builder's accumulated length must equal the op's declared `new_size`.
pub const RewriteFn = *const fn (old_bytes: []const u8, out: *FieldBuilder) ApplyError!void;

pub const AddKind = struct { kind_id: u16, default_bytes: []const u8 };
pub const RenameKind = struct { from: u16, to: u16 };
pub const TransformKind = struct { kind_id: u16, new_size: u32, rewrite: RewriteFn };

/// One declared schema-reconciliation operation, keyed by `kind_id`.
pub const Op = union(enum) {
    /// No change (a kind survives untouched). Carries nothing; never covers a delta, never spurious.
    identity,
    /// Remove a component kind: drop its cell from every row, drop it from the fingerprint.
    drop_kind: u16,
    /// Add a component kind to EVERY row with `default_bytes` (Phase-8 scope: unconditional; a future
    /// `.add_kind_where` arm would filter). `default_bytes` must be exactly the new kind's serialized
    /// width.
    add_kind: AddKind,
    /// Relabel a kind's `kind_id` (size-preserving): the cell's bytes are kept, the key changes, rows
    /// re-sort ascending.
    rename_kind: RenameKind,
    /// Rewrite a kind's value bytes (and possibly its width) via `rewrite`. The produced bytes must be
    /// exactly `new_size` wide.
    transform_kind: TransformKind,
};

// --- leaf field codecs (the transform vocabulary) ------------------------------------------------

/// Accumulates canonical little-endian leaf bytes for a transformed value — the same encoding the wire
/// uses, so the result drops straight into a serialize image.
pub const FieldBuilder = struct {
    list: *std.ArrayList(u8),
    gpa: Allocator,

    /// Append an unsigned integer of any bit width (canonical little-endian).
    pub fn addU(self: *FieldBuilder, comptime T: type, v: T) Allocator.Error!void {
        var sink = serialize.ByteSink{ .list = self.list, .gpa = self.gpa };
        try serialize.putInt(&sink, T, v);
    }
    /// Append a signed integer of any bit width (canonical little-endian, two's-complement bit pattern).
    pub fn addI(self: *FieldBuilder, comptime T: type, v: T) Allocator.Error!void {
        var sink = serialize.ByteSink{ .list = self.list, .gpa = self.gpa };
        try serialize.putInt(&sink, T, v);
    }
    /// Append a bool as a single 0/1 byte.
    pub fn addBool(self: *FieldBuilder, v: bool) Allocator.Error!void {
        try self.list.append(self.gpa, @intFromBool(v));
    }
    /// Append raw canonical bytes verbatim (e.g. copy an unchanged leaf through).
    pub fn copy(self: *FieldBuilder, raw: []const u8) Allocator.Error!void {
        try self.list.appendSlice(self.gpa, raw);
    }
    /// The bytes accumulated so far.
    pub fn bytes(self: *const FieldBuilder) []const u8 {
        return self.list.items;
    }
};

/// Reads canonical little-endian leaves from a value's old bytes (a forward cursor).
pub const FieldReader = struct {
    reader: serialize.ByteReader,

    pub fn init(old_bytes: []const u8) FieldReader {
        return .{ .reader = .{ .bytes = old_bytes } };
    }
    pub fn getU(self: *FieldReader, comptime T: type) serialize.Error!T {
        return serialize.getInt(&self.reader, T);
    }
    pub fn getI(self: *FieldReader, comptime T: type) serialize.Error!T {
        return serialize.getInt(&self.reader, T);
    }
    pub fn getBool(self: *FieldReader) serialize.Error!bool {
        return (try self.reader.readByte()) != 0;
    }
};

// --- op application -------------------------------------------------------------------------------

fn lessByKindFp(_: void, a: KindFp, b: KindFp) bool {
    return a.kind_id < b.kind_id;
}
fn lessByKindRecord(_: void, a: KindRecord, b: KindRecord) bool {
    return a.kind_id < b.kind_id;
}

/// Reshape a fingerprint by one op (pure; result is a fresh ascending-kind_id slice in `a`).
pub fn applyToFingerprint(a: Allocator, op: Op, fp: []const KindFp) Allocator.Error![]KindFp {
    var out: std.ArrayList(KindFp) = .empty;
    switch (op) {
        .identity => try out.appendSlice(a, fp),
        .drop_kind => |kid| {
            for (fp) |k| if (k.kind_id != kid) try out.append(a, k);
        },
        .add_kind => |ak| {
            try out.appendSlice(a, fp);
            try out.append(a, .{ .kind_id = ak.kind_id, .size = @intCast(ak.default_bytes.len) });
        },
        .rename_kind => |rk| {
            for (fp) |k| try out.append(a, if (k.kind_id == rk.from) .{ .kind_id = rk.to, .size = k.size } else k);
        },
        .transform_kind => |tk| {
            for (fp) |k| try out.append(a, if (k.kind_id == tk.kind_id) .{ .kind_id = k.kind_id, .size = tk.new_size } else k);
        },
    }
    std.mem.sort(KindFp, out.items, {}, lessByKindFp);
    return out.items;
}

/// Reshape one row's cells by one op (pure; result is a fresh ascending-kind_id slice in `a`, with ALL
/// cell bytes deep-copied into `a` so the produced image owns its storage independent of the source).
pub fn applyToCells(a: Allocator, op: Op, comps: []const KindRecord) ApplyError![]KindRecord {
    var out: std.ArrayList(KindRecord) = .empty;
    switch (op) {
        .identity => for (comps) |c| try out.append(a, try dupCell(a, c)),
        .drop_kind => |kid| {
            for (comps) |c| if (c.kind_id != kid) try out.append(a, try dupCell(a, c));
        },
        .add_kind => |ak| {
            for (comps) |c| try out.append(a, try dupCell(a, c));
            try out.append(a, .{ .kind_id = ak.kind_id, .bytes = try a.dupe(u8, ak.default_bytes) });
        },
        .rename_kind => |rk| {
            for (comps) |c| {
                const kid = if (c.kind_id == rk.from) rk.to else c.kind_id;
                try out.append(a, .{ .kind_id = kid, .bytes = try a.dupe(u8, c.bytes) });
            }
        },
        .transform_kind => |tk| {
            for (comps) |c| {
                if (c.kind_id == tk.kind_id) {
                    var nb: std.ArrayList(u8) = .empty;
                    var fb = FieldBuilder{ .list = &nb, .gpa = a };
                    try tk.rewrite(c.bytes, &fb);
                    if (nb.items.len != tk.new_size) return error.Corrupt; // non-conformant rewrite
                    try out.append(a, .{ .kind_id = c.kind_id, .bytes = nb.items });
                } else {
                    try out.append(a, try dupCell(a, c));
                }
            }
        },
    }
    std.mem.sort(KindRecord, out.items, {}, lessByKindRecord);
    return out.items;
}

fn dupCell(a: Allocator, c: KindRecord) Allocator.Error!KindRecord {
    return .{ .kind_id = c.kind_id, .bytes = try a.dupe(u8, c.bytes) };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

fn cellsFixture(a: Allocator) ![]KindRecord {
    const c = try a.alloc(KindRecord, 2);
    c[0] = .{ .kind_id = 5, .bytes = try a.dupe(u8, &.{ 1, 2, 3, 4 }) };
    c[1] = .{ .kind_id = 10, .bytes = try a.dupe(u8, &.{ 9, 9 }) };
    return c;
}

test "add_kind inserts a cell with default_bytes and the row re-sorts ascending" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comps = try cellsFixture(a);
    const out = try applyToCells(a, .{ .add_kind = .{ .kind_id = 8, .default_bytes = &.{ 0xAA, 0xBB } } }, comps);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(u16, 5), out[0].kind_id);
    try testing.expectEqual(@as(u16, 8), out[1].kind_id); // inserted between 5 and 10
    try testing.expectEqual(@as(u16, 10), out[2].kind_id);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, out[1].bytes);
}

test "drop_kind removes the cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comps = try cellsFixture(a);
    const out = try applyToCells(a, .{ .drop_kind = 5 }, comps);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u16, 10), out[0].kind_id);
}

test "rename_kind relabels the kind_id key and the row re-sorts ascending" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comps = try cellsFixture(a); // [5, 10]
    const out = try applyToCells(a, .{ .rename_kind = .{ .from = 5, .to = 30 } }, comps);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(u16, 10), out[0].kind_id); // 5->30 moves to the end
    try testing.expectEqual(@as(u16, 30), out[1].kind_id);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, out[1].bytes); // bytes preserved
}

// grow: read a u32, write it back plus a fresh u32 = 0 leaf (4 -> 8 bytes)
fn growU32ToTwo(old_bytes: []const u8, out: *FieldBuilder) ApplyError!void {
    var r = FieldReader.init(old_bytes);
    const v = try r.getU(u32);
    try out.addU(u32, v);
    try out.addU(u32, 0);
}
// shrink: read a u32, write only its low u16 (4 -> 2 bytes)
fn shrinkU32ToU16(old_bytes: []const u8, out: *FieldBuilder) ApplyError!void {
    var r = FieldReader.init(old_bytes);
    const v = try r.getU(u32);
    try out.addU(u16, @truncate(v));
}

test "transform_kind grow appends new leaf bytes; shrink drops a tail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comps = try cellsFixture(a); // kind 5 has 4 bytes {1,2,3,4}

    const grown = try applyToCells(a, .{ .transform_kind = .{ .kind_id = 5, .new_size = 8, .rewrite = growU32ToTwo } }, comps);
    try testing.expectEqual(@as(usize, 8), grown[0].bytes.len);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 0, 0, 0, 0 }, grown[0].bytes);

    const shrunk = try applyToCells(a, .{ .transform_kind = .{ .kind_id = 5, .new_size = 2, .rewrite = shrinkU32ToU16 } }, comps);
    try testing.expectEqual(@as(usize, 2), shrunk[0].bytes.len);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, shrunk[0].bytes); // low 16 bits, little-endian
}

// a rewrite whose output width disagrees with the declared new_size -> Corrupt
fn liesAboutWidth(old_bytes: []const u8, out: *FieldBuilder) ApplyError!void {
    _ = old_bytes;
    try out.addU(u8, 1); // emits 1 byte, but the op will declare new_size = 4
}

test "transform_kind whose rewrite produces the wrong width is rejected (Corrupt)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comps = try cellsFixture(a);
    try testing.expectError(error.Corrupt, applyToCells(a, .{ .transform_kind = .{ .kind_id = 5, .new_size = 4, .rewrite = liesAboutWidth } }, comps));
}

test "FieldBuilder/FieldReader round-trip addU/getU, addI/getI, addBool/getBool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    var fb = FieldBuilder{ .list = &buf, .gpa = a };
    try fb.addU(u32, 0x11223344);
    try fb.addI(i16, -5);
    try fb.addBool(true);
    try fb.addBool(false);

    var r = FieldReader.init(buf.items);
    try testing.expectEqual(@as(u32, 0x11223344), try r.getU(u32));
    try testing.expectEqual(@as(i16, -5), try r.getI(i16));
    try testing.expectEqual(true, try r.getBool());
    try testing.expectEqual(false, try r.getBool());
}

test "applyToFingerprint mirrors the cell reshape (add/drop/rename/transform)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fp = &[_]KindFp{ .{ .kind_id = 5, .size = 4 }, .{ .kind_id = 10, .size = 2 } };

    const added = try applyToFingerprint(a, .{ .add_kind = .{ .kind_id = 8, .default_bytes = &.{ 0, 0, 0 } } }, fp);
    try testing.expectEqual(@as(usize, 3), added.len);
    try testing.expectEqual(@as(u16, 8), added[1].kind_id);
    try testing.expectEqual(@as(u32, 3), added[1].size); // size = default_bytes.len

    const transformed = try applyToFingerprint(a, .{ .transform_kind = .{ .kind_id = 5, .new_size = 8, .rewrite = growU32ToTwo } }, fp);
    try testing.expectEqual(@as(u32, 8), transformed[0].size);

    const renamed = try applyToFingerprint(a, .{ .rename_kind = .{ .from = 5, .to = 30 } }, fp);
    try testing.expectEqual(@as(u16, 10), renamed[0].kind_id);
    try testing.expectEqual(@as(u16, 30), renamed[1].kind_id);
    try testing.expectEqual(@as(u32, 4), renamed[1].size); // size preserved across rename
}
