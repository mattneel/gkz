//! The query result table + its GKZR1 wire codec (PLAN.md Phase 5, build-order step 2).
//!
//! A `QueryResult` is a relation-tagged, columnar, CANONICALLY-ORDERED set of `term.Row`s plus an owned
//! byte arena backing every `bytes` cell. It is the pinned-artifact carrier: `resultDigest` (XXH64+CRC32
//! over the GKZR1 encoding) is asserted byte-identical across build modes by the Phase-5 gate.
//!
//! Determinism rests on `Builder.finalize`: rows are appended in whatever order a producer scans, then
//! finalize SORTS them by `Row.tupleOrder` (content-based, so layout-independent — D9) and drops exact
//! duplicates. So a result's canonical form — and therefore its digest and its GKZR1 bytes — is a pure
//! function of the SET of rows, never of producer iteration order. The GKZR1 codec mirrors `event_log`'s
//! GKZE1 discipline: a magic+version header, then counts/sizes validated against the remaining buffer
//! BEFORE any allocation and every `bytes` slice bounds-checked before use, returning `serialize.Error`
//! (never a panic) on hostile input — this surface will face untrusted control-plane bytes (§13/Phase 9).

const std = @import("std");
const Allocator = std.mem.Allocator;
const term = @import("term.zig");
const Value = term.Value;
const Row = term.Row;
const Schema = term.Schema;
const RelId = term.RelId;
const TermTag = term.TermTag;
const BytesRef = term.BytesRef;
const serialize = @import("../serialize.zig");
const sortmod = @import("../sort.zig");
const hashmod = @import("../hash.zig");

pub const MAGIC = [5]u8{ 'G', 'K', 'Z', 'R', '1' }; // GKZR1: the query-result wire format
pub const FORMAT_VERSION: u16 = 1;

/// A canonically-ordered relation result + the byte arena its `bytes` cells slice into. Owns its memory.
pub const QueryResult = struct {
    rel: RelId,
    schema: Schema,
    rows: std.ArrayList(Row) = .empty,
    arena: std.ArrayList(u8) = .empty, // backing bytes for every BytesRef cell

    pub fn deinit(self: *QueryResult, gpa: Allocator) void {
        self.rows.deinit(gpa);
        self.arena.deinit(gpa);
        self.* = undefined;
    }

    /// Resolve a `bytes` cell against this result's arena.
    pub fn bytesOf(self: *const QueryResult, ref: BytesRef) []const u8 {
        return self.arena.items[ref.off..][0..ref.len];
    }
};

/// Accumulates rows + their backing bytes, then `finalize`s into a canonical `QueryResult`. On any error
/// before finalize, `deinit` frees everything; finalize MOVES ownership out (do not deinit after).
pub const Builder = struct {
    gpa: Allocator,
    res: QueryResult,

    pub fn init(gpa: Allocator, rel: RelId, schema: Schema) Builder {
        return .{ .gpa = gpa, .res = .{ .rel = rel, .schema = schema } };
    }

    pub fn deinit(self: *Builder) void {
        self.res.deinit(self.gpa);
    }

    /// Copy `bytes` into the arena and return a handle. (A `u32` arena ceiling guards the on-wire width.)
    pub fn pushBytes(self: *Builder, bytes: []const u8) Allocator.Error!BytesRef {
        const off: u32 = @intCast(self.res.arena.items.len);
        try self.res.arena.appendSlice(self.gpa, bytes);
        return .{ .off = off, .len = @intCast(bytes.len) };
    }

    pub fn pushRow(self: *Builder, row: Row) Allocator.Error!void {
        try self.res.rows.append(self.gpa, row);
    }

    const SortCtx = struct { arena: []const u8, arity: u8 };
    fn rowLess(ctx: SortCtx, a: Row, b: Row) bool {
        return a.tupleOrder(b, ctx.arity, ctx.arena) == .lt;
    }

    /// Canonical-sort the rows by `tupleOrder` and drop exact duplicates; return the owned result.
    pub fn finalize(self: *Builder) QueryResult {
        const arity = self.res.schema.arity;
        const items = self.res.rows.items;
        sortmod.sort(Row, items, SortCtx{ .arena = self.res.arena.items, .arity = arity }, rowLess);
        // dedup adjacent equal rows in place (orphaned arena bytes are harmless — GKZR1 emits only
        // referenced bytes, so they never reach the digest).
        if (items.len > 1) {
            var w: usize = 1;
            var r: usize = 1;
            while (r < items.len) : (r += 1) {
                if (!items[r].eql(items[w - 1], arity, self.res.arena.items)) {
                    items[w] = items[r];
                    w += 1;
                }
            }
            self.res.rows.items.len = w;
        }
        const out = self.res;
        self.res = .{ .rel = out.rel, .schema = out.schema }; // neutralize: deinit-after-finalize is a no-op
        return out;
    }
};

// --- GKZR1 codec ----------------------------------------------------------------------------------

/// Encode one `Value` into `sink`: a 1-byte tag, then the leaf. `bytes` is emitted INLINE (len-prefixed)
/// resolving the arena ref — so the wire form carries content, never an offset, making it
/// arena-layout-independent and self-contained. (`serialize.writeValue` has no union arm, so the tag
/// dispatch is hand-rolled, mirroring the GKZE1 discipline.)
fn writeValueCell(sink: *serialize.ByteSink, v: Value, arena: []const u8) Allocator.Error!void {
    try serialize.putInt(sink, u8, @intFromEnum(std.meta.activeTag(v)));
    switch (v) {
        .u => |x| try serialize.putInt(sink, u64, x),
        .i => |x| try serialize.putInt(sink, i64, x),
        .bool_ => |x| try serialize.writeValue(sink, bool, x),
        .entity => |x| try serialize.writeValue(sink, @TypeOf(x), x),
        .kind => |x| try serialize.putInt(sink, u16, x),
        .event_id => |x| try serialize.writeValue(sink, @TypeOf(x), x),
        .tick => |x| try serialize.putInt(sink, u64, x),
        .bytes => |r| {
            try serialize.putInt(sink, u32, r.len);
            try sink.update(arena[r.off..][0..r.len]);
        },
    }
}

/// Serialize a result into GKZR1: header, RelId, schema (arity + per-column tag + name), row count, then
/// each row's `arity` cells in canonical order. Self-contained (bytes inlined); the inverse of `read`.
pub fn writeResult(sink: *serialize.ByteSink, r: *const QueryResult) Allocator.Error!void {
    try sink.update(&MAGIC);
    try serialize.putInt(sink, u16, FORMAT_VERSION);
    try serialize.putInt(sink, u16, @intFromEnum(r.rel));
    const arity = r.schema.arity;
    try serialize.putInt(sink, u8, arity);
    var c: usize = 0;
    while (c < arity) : (c += 1) {
        try serialize.putInt(sink, u8, @intFromEnum(r.schema.cols[c]));
        const name = r.schema.names[c];
        try serialize.putInt(sink, u16, @intCast(name.len));
        try sink.update(name);
    }
    try serialize.putInt(sink, u32, @intCast(r.rows.items.len));
    for (r.rows.items) |row| {
        var col: usize = 0;
        while (col < arity) : (col += 1) try writeValueCell(sink, row.vals[col], r.arena.items);
    }
}

fn readValueCell(reader: *serialize.ByteReader, b: *Builder) (serialize.Error || Allocator.Error)!Value {
    const tag_raw = try serialize.getInt(reader, u8);
    const tag = term.tagFromInt(tag_raw) orelse return error.Corrupt;
    return switch (tag) {
        .u => .{ .u = try serialize.getInt(reader, u64) },
        .i => .{ .i = try serialize.getInt(reader, i64) },
        .bool_ => .{ .bool_ = try serialize.readValue(bool, reader) },
        .entity => .{ .entity = try serialize.readValue(@import("../entity.zig").Entity, reader) },
        .kind => .{ .kind = try serialize.getInt(reader, u16) },
        .event_id => .{ .event_id = try serialize.readValue(@import("../event.zig").EventId, reader) },
        .tick => .{ .tick = try serialize.getInt(reader, u64) },
        .bytes => blk: {
            const len = try serialize.getInt(reader, u32);
            const slice = try reader.readSlice(len); // bounds-checked against the buffer
            break :blk .{ .bytes = try b.pushBytes(slice) };
        },
    };
}

/// Decode a GKZR1 image. Validates magic/version and every length against the remaining buffer before
/// allocating; a malformed image returns `serialize.Error`, never a panic. Caller `deinit`s the result.
pub fn readResult(gpa: Allocator, reader: *serialize.ByteReader) (serialize.Error || Allocator.Error)!QueryResult {
    const magic = try reader.readSlice(MAGIC.len);
    if (!std.mem.eql(u8, magic, &MAGIC)) return error.BadMagic;
    if (try serialize.getInt(reader, u16) != FORMAT_VERSION) return error.UnsupportedFormat;
    const rel: RelId = @enumFromInt(try serialize.getInt(reader, u16)); // non-exhaustive: any u16 is a valid RelId
    const arity = try serialize.getInt(reader, u8);
    // arity must be 1..=MAX_ARITY. Rejecting 0 closes a DoS: with arity==0 the per-cell loop body never
    // runs, so the reader never advances and a huge declared `row_count` would push billions of empty
    // rows (unbounded alloc) before failing. Every real relation has arity >= 2 (the catalog asserts it).
    if (arity == 0 or arity > term.MAX_ARITY) return error.Corrupt;

    var b = Builder.init(gpa, rel, .{ .arity = arity }); // cols/names filled below
    errdefer b.deinit();
    // Read each column's (tag, name) — interleaved exactly as `writeResult` emits them — copying the name
    // into the result's OWN arena (the names precede all row bytes, so their offsets stay valid as the
    // arena grows). NOT a borrow of the caller's reader buffer, which would dangle once freed. Names are
    // patched into schema.names after finalize, against the final arena.
    var name_refs: [term.MAX_ARITY]BytesRef = undefined;
    var c: usize = 0;
    while (c < arity) : (c += 1) {
        b.res.schema.cols[c] = term.tagFromInt(try serialize.getInt(reader, u8)) orelse return error.Corrupt;
        const nlen = try serialize.getInt(reader, u16);
        const name = try reader.readSlice(nlen); // bounds-checked against the buffer
        name_refs[c] = try b.pushBytes(name);
    }

    const row_count = try serialize.getInt(reader, u32);
    // do NOT pre-reserve row_count*... — validate incrementally so a huge declared count can't OOM us:
    // each cell read advances the bounds-checked reader, so a truncated buffer fails fast.
    var n: u32 = 0;
    while (n < row_count) : (n += 1) {
        var row: Row = .{};
        var col: usize = 0;
        while (col < arity) : (col += 1) row.vals[col] = try readValueCell(reader, &b);
        try b.pushRow(row);
    }
    var result = b.finalize(); // sorts rows; never touches the arena, so name offsets remain valid
    c = 0;
    while (c < arity) : (c += 1) result.schema.names[c] = result.arena.items[name_refs[c].off..][0..name_refs[c].len];
    return result;
}

/// XXH64+CRC32 over a result's GKZR1 encoding — the Phase-5 pinned-artifact primitive. A pure function
/// of the canonical (relation, schema, row-set), so it is build-mode- and iteration-order-invariant.
pub fn resultDigest(gpa: Allocator, r: *const QueryResult) Allocator.Error!hashmod.Digest {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try writeResult(&sink, r);
    var hs = hashmod.HashSink.init();
    _ = hs.update(buf.items) catch {};
    return hs.digest();
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Entity = @import("../entity.zig").Entity;

fn demoSchema() Schema {
    return Schema.make(&.{ .{ "entity", .entity }, .{ "kind", .kind }, .{ "value", .bytes } });
}

test "Builder.finalize canonical-sorts rows and drops exact duplicates" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, .component, demoSchema());
    errdefer b.deinit();
    const v1 = try b.pushBytes(&.{ 1, 2 });
    const v2 = try b.pushBytes(&.{3});
    // push out of order + a duplicate of the first row (distinct arena bytes, same content)
    try b.pushRow(.{ .vals = .{ .{ .entity = .{ .index = 2, .generation = 0 } }, .{ .kind = 9 }, .{ .bytes = v2 }, undefined, undefined, undefined, undefined, undefined } });
    try b.pushRow(.{ .vals = .{ .{ .entity = .{ .index = 1, .generation = 0 } }, .{ .kind = 5 }, .{ .bytes = v1 }, undefined, undefined, undefined, undefined, undefined } });
    const v1dup = try b.pushBytes(&.{ 1, 2 });
    try b.pushRow(.{ .vals = .{ .{ .entity = .{ .index = 1, .generation = 0 } }, .{ .kind = 5 }, .{ .bytes = v1dup }, undefined, undefined, undefined, undefined, undefined } });
    var r = b.finalize();
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), r.rows.items.len); // dup removed
    try testing.expectEqual(@as(u32, 1), r.rows.items[0].vals[0].entity.index); // sorted: entity 1 first
    try testing.expectEqual(@as(u32, 2), r.rows.items[1].vals[0].entity.index);
}

test "resultDigest is invariant to row insertion order (canonical re-sort severs it)" {
    const gpa = testing.allocator;
    // build the same logical rows in two different insertion orders -> equal digest
    var d1: hashmod.Digest = undefined;
    var d2: hashmod.Digest = undefined;
    {
        var b = Builder.init(gpa, .component, demoSchema());
        errdefer b.deinit();
        const a = try b.pushBytes("xx");
        try b.pushRow(.{ .vals = .{ .{ .entity = .{ .index = 1, .generation = 0 } }, .{ .kind = 1 }, .{ .bytes = a }, undefined, undefined, undefined, undefined, undefined } });
        const c = try b.pushBytes("yy");
        try b.pushRow(.{ .vals = .{ .{ .entity = .{ .index = 2, .generation = 0 } }, .{ .kind = 2 }, .{ .bytes = c }, undefined, undefined, undefined, undefined, undefined } });
        var r = b.finalize();
        defer r.deinit(gpa);
        d1 = try resultDigest(gpa, &r);
    }
    {
        var b = Builder.init(gpa, .component, demoSchema());
        errdefer b.deinit();
        const c = try b.pushBytes("yy"); // reversed insertion + reversed arena layout
        try b.pushRow(.{ .vals = .{ .{ .entity = .{ .index = 2, .generation = 0 } }, .{ .kind = 2 }, .{ .bytes = c }, undefined, undefined, undefined, undefined, undefined } });
        const a = try b.pushBytes("xx");
        try b.pushRow(.{ .vals = .{ .{ .entity = .{ .index = 1, .generation = 0 } }, .{ .kind = 1 }, .{ .bytes = a }, undefined, undefined, undefined, undefined, undefined } });
        var r = b.finalize();
        defer r.deinit(gpa);
        d2 = try resultDigest(gpa, &r);
    }
    try testing.expectEqual(d1.hash, d2.hash);
    try testing.expectEqual(d1.crc, d2.crc);
    try testing.expect(d1.hash != 0);
}

test "GKZR1 writeResult/readResult round-trips byte-identically (digest preserved)" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, .event, Schema.make(&.{ .{ "id", .event_id }, .{ "kind", .kind }, .{ "tick", .tick }, .{ "emitter", .u }, .{ "payload", .bytes } }));
    errdefer b.deinit();
    const p = try b.pushBytes(&.{ 0xDE, 0xAD });
    try b.pushRow(.{ .vals = .{ .{ .event_id = .{ .tick = 3, .emitter = 1, .seq = 0 } }, .{ .kind = 100 }, .{ .tick = 3 }, .{ .u = 1 }, .{ .bytes = p }, undefined, undefined, undefined } });
    var r = b.finalize();
    defer r.deinit(gpa);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try writeResult(&sink, &r);

    var reader = serialize.ByteReader{ .bytes = buf.items };
    var r2 = try readResult(gpa, &reader);
    defer r2.deinit(gpa);

    try testing.expectEqual(r.rel, r2.rel);
    try testing.expectEqual(r.schema.arity, r2.schema.arity);
    try testing.expectEqual(@as(usize, 1), r2.rows.items.len);
    try testing.expectEqual(@as(u16, 100), r2.rows.items[0].vals[1].kind);
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD }, r2.bytesOf(r2.rows.items[0].vals[4].bytes));
    // re-encoding the decoded result reproduces the same digest
    const d1 = try resultDigest(gpa, &r);
    const d2 = try resultDigest(gpa, &r2);
    try testing.expectEqual(d1.hash, d2.hash);
}

test "readResult rejects hostile input with an Error, never a panic" {
    const gpa = testing.allocator;
    // bad magic
    {
        var reader = serialize.ByteReader{ .bytes = "XXXXX1" };
        try testing.expectError(error.BadMagic, readResult(gpa, &reader));
    }
    // good header, truncated before rows
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
        try sink.update(&MAGIC);
        try serialize.putInt(&sink, u16, FORMAT_VERSION);
        try serialize.putInt(&sink, u16, 0); // rel
        try serialize.putInt(&sink, u8, 99); // arity > MAX_ARITY
        var reader = serialize.ByteReader{ .bytes = buf.items };
        try testing.expectError(error.Corrupt, readResult(gpa, &reader));
    }
    // arity 0 + huge row_count must fail FAST (Corrupt), not attempt an unbounded allocation
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
        try sink.update(&MAGIC);
        try serialize.putInt(&sink, u16, FORMAT_VERSION);
        try serialize.putInt(&sink, u16, 0); // rel
        try serialize.putInt(&sink, u8, 0); // arity 0 — would freeze the reader
        try serialize.putInt(&sink, u32, 0xFFFFFFFF); // claims ~4.3B zero-width rows
        var reader = serialize.ByteReader{ .bytes = buf.items };
        try testing.expectError(error.Corrupt, readResult(gpa, &reader));
    }
    // declared row_count huge but buffer ends -> Truncated (no OOM from pre-reserve)
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
        try sink.update(&MAGIC);
        try serialize.putInt(&sink, u16, FORMAT_VERSION);
        try serialize.putInt(&sink, u16, 0);
        try serialize.putInt(&sink, u8, 1); // arity 1
        try serialize.putInt(&sink, u8, @intFromEnum(TermTag.u)); // col0 tag
        try serialize.putInt(&sink, u16, 0); // name len 0
        try serialize.putInt(&sink, u32, 1_000_000); // claims a million rows
        var reader = serialize.ByteReader{ .bytes = buf.items };
        try testing.expectError(error.Truncated, readResult(gpa, &reader));
    }
}

test "Builder.deinit frees a partially-built result with no leak (errdefer path)" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, .component, demoSchema());
    _ = try b.pushBytes("partial");
    try b.pushRow(.{ .vals = .{ .{ .entity = .{ .index = 0, .generation = 0 } }, .{ .kind = 0 }, .{ .bytes = .{ .off = 0, .len = 7 } }, undefined, undefined, undefined, undefined, undefined } });
    b.deinit(); // simulate an error before finalize: must free rows + arena
}
