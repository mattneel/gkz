//! GKZQ1: the serializable query codec + the `respond` control-plane seam (PLAN.md Phase 5, step 6).
//!
//! `writeQuery`/`readQuery` serialize the `Query(R)` union (a 1-byte arm tag + per-arm fields, mirroring
//! the GKZE1/GKZR1 discipline since `serialize.writeValue` has no union arm). `respond` is the entire
//! §13/Phase-9 seam (S7): it reads a GKZQ1 frame from a borrowed byte buffer, evaluates it against a
//! borrowed Engine, and writes a GKZR1 result frame — ZERO io, zero global state. Phase 9 wraps it in a
//! socket accept/read-frame/respond/write-frame loop, one Engine per borrowed World, with no change here.
//! Hostile input (bad magic / truncation / unknown tag / bad optional flag) returns `serialize.Error`,
//! never a panic — this surface faces untrusted control-plane bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const ByteSink = serialize.ByteSink;
const ByteReader = serialize.ByteReader;
const Entity = @import("../entity.zig").Entity;
const EventId = @import("../event.zig").EventId;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const engine_mod = @import("engine.zig");
const Query = engine_mod.Query;
const Engine = engine_mod.Engine;
const resultmod = @import("result.zig");

pub const MAGIC = [5]u8{ 'G', 'K', 'Z', 'Q', '1' };
pub const FORMAT_VERSION: u16 = 1;

/// Optional encode: a present flag (u8: 0/1) then, if present, the value via `writeValue`.
fn putOpt(sink: *ByteSink, comptime T: type, v: ?T) Allocator.Error!void {
    if (v) |x| {
        try serialize.putInt(sink, u8, 1);
        try serialize.writeValue(sink, T, x);
    } else {
        try serialize.putInt(sink, u8, 0);
    }
}
fn getOpt(reader: *ByteReader, comptime T: type) serialize.Error!?T {
    return switch (try serialize.getInt(reader, u8)) {
        0 => null,
        1 => try serialize.readValue(T, reader),
        else => error.Corrupt, // a present-flag is strictly 0 or 1
    };
}

/// Serialize a query into GKZQ1: header, arm tag, per-arm fields. The inverse of `readQuery`.
pub fn writeQuery(sink: *ByteSink, comptime R: type, q: Query(R)) Allocator.Error!void {
    try sink.update(&MAGIC);
    try serialize.putInt(sink, u16, FORMAT_VERSION);
    try serialize.putInt(sink, u8, @intFromEnum(std.meta.activeTag(q)));
    switch (q) {
        .component => |f| {
            try putOpt(sink, Entity, f.entity);
            try putOpt(sink, u16, f.kind);
        },
        .event => |f| {
            try putOpt(sink, u64, f.tick_lo);
            try putOpt(sink, u64, f.tick_hi);
            try putOpt(sink, u16, f.kind);
            try putOpt(sink, u16, f.emitter);
        },
        .caused_by_direct => |id| try serialize.writeValue(sink, EventId, id),
        .why => |id| try serialize.writeValue(sink, EventId, id),
        .what_writes => |k| try serialize.putInt(sink, u16, k),
        .what_reads => |k| try serialize.putInt(sink, u16, k),
        .systems_all, .schema, .columns => {},
    }
}

/// Decode a GKZQ1 image into a `Query(R)`. No allocation (a Query is a value). Rejects hostile bytes.
pub fn readQuery(comptime R: type, reader: *ByteReader) serialize.Error!Query(R) {
    const magic = try reader.readSlice(MAGIC.len);
    if (!std.mem.eql(u8, magic, &MAGIC)) return error.BadMagic;
    if (try serialize.getInt(reader, u16) != FORMAT_VERSION) return error.UnsupportedFormat;
    const tag = try serialize.getInt(reader, u8);
    return switch (tag) {
        0 => .{ .component = .{ .entity = try getOpt(reader, Entity), .kind = try getOpt(reader, u16) } },
        1 => .{ .event = .{
            .tick_lo = try getOpt(reader, u64),
            .tick_hi = try getOpt(reader, u64),
            .kind = try getOpt(reader, u16),
            .emitter = try getOpt(reader, u16),
        } },
        2 => .{ .caused_by_direct = try serialize.readValue(EventId, reader) },
        3 => .{ .why = try serialize.readValue(EventId, reader) },
        4 => .{ .what_writes = try serialize.getInt(reader, u16) },
        5 => .{ .what_reads = try serialize.getInt(reader, u16) },
        6 => .systems_all,
        7 => .schema,
        8 => .columns,
        else => error.Corrupt, // unknown arm tag
    };
}

/// The control-plane seam (S7): read a GKZQ1 request, evaluate against `engine`, write a GKZR1 result.
/// Pure (bytes -> bytes), no io. A malformed request returns its `serialize.Error` (Phase 9 turns that
/// into an error frame). The wire-serializable arms only — the diverge/firstTickWhere/reach operators
/// carry live references Phase 9 resolves from handles before calling the Engine methods directly.
pub fn respond(
    comptime R: type,
    comptime systems: []const Sys(R),
    gpa: Allocator,
    engine: Engine(R, systems),
    request: []const u8,
    out: *ByteSink,
) (serialize.Error || Allocator.Error)!void {
    var reader = ByteReader{ .bytes = request };
    const q = try readQuery(R, &reader);
    var result = try engine.evaluate(gpa, q);
    defer result.deinit(gpa);
    try resultmod.writeResult(out, &result);
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const q2 = @import("../query.zig");
const simctx = @import("../simctx.zig");
const worldmod = @import("../world.zig");
const EventLog = @import("../event_log.zig").EventLog;
const Read = q2.Read;
const system = schedule.system;

const Position = struct {
    x: i64,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Position});
fn rP(ctx: *simctx.SimCtx(Game), qq: *q2.Query(Game, .{Read(Position)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = qq;
}
const demo_systems = [_]Sys(Game){system(Game, "rP", rP)};

fn roundtrips(gpa: Allocator, q: Query(Game)) !void {
    var b1: std.ArrayList(u8) = .empty;
    defer b1.deinit(gpa);
    var s1 = ByteSink{ .list = &b1, .gpa = gpa };
    try writeQuery(&s1, Game, q);

    var reader = ByteReader{ .bytes = b1.items };
    const q2v = try readQuery(Game, &reader);

    var b2: std.ArrayList(u8) = .empty;
    defer b2.deinit(gpa);
    var s2 = ByteSink{ .list = &b2, .gpa = gpa };
    try writeQuery(&s2, Game, q2v);
    try testing.expectEqualSlices(u8, b1.items, b2.items); // byte-identical round-trip
}

test "GKZQ1 round-trips every query arm byte-identically" {
    const gpa = testing.allocator;
    try roundtrips(gpa, .{ .component = .{} });
    try roundtrips(gpa, .{ .component = .{ .entity = .{ .index = 3, .generation = 2 }, .kind = 1 } });
    try roundtrips(gpa, .{ .event = .{ .tick_lo = 2, .tick_hi = 9, .kind = 100, .emitter = 1 } });
    try roundtrips(gpa, .{ .event = .{} });
    try roundtrips(gpa, .{ .caused_by_direct = .{ .tick = 5, .emitter = 1, .seq = 0 } });
    try roundtrips(gpa, .{ .why = .{ .tick = 5, .emitter = 1, .seq = 0 } });
    try roundtrips(gpa, .{ .what_writes = 1 });
    try roundtrips(gpa, .{ .what_reads = 1 });
    try roundtrips(gpa, .systems_all);
    try roundtrips(gpa, .schema);
    try roundtrips(gpa, .columns);
}

test "readQuery rejects hostile input with an Error, never a panic" {
    // bad magic
    {
        var reader = ByteReader{ .bytes = "NOPE!" ++ [_]u8{ 0, 0, 0 } };
        try testing.expectError(error.BadMagic, readQuery(Game, &reader));
    }
    // good header, unknown arm tag
    {
        const gpa = testing.allocator;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var sink = ByteSink{ .list = &buf, .gpa = gpa };
        try sink.update(&MAGIC);
        try serialize.putInt(&sink, u16, FORMAT_VERSION);
        try serialize.putInt(&sink, u8, 99); // no such arm
        var reader = ByteReader{ .bytes = buf.items };
        try testing.expectError(error.Corrupt, readQuery(Game, &reader));
    }
    // truncated before the optional flag
    {
        const gpa = testing.allocator;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var sink = ByteSink{ .list = &buf, .gpa = gpa };
        try sink.update(&MAGIC);
        try serialize.putInt(&sink, u16, FORMAT_VERSION);
        try serialize.putInt(&sink, u8, 0); // component arm, but no filter bytes follow
        var reader = ByteReader{ .bytes = buf.items };
        try testing.expectError(error.Truncated, readQuery(Game, &reader));
    }
}

test "respond reads a GKZQ1 request and writes a valid GKZR1 result frame" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Position, .{ .x = 42 });
    var log: EventLog = .{};
    defer log.deinit(gpa);

    const eng = Engine(Game, &demo_systems).init(&w, &log);

    // build a component request frame
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    var rs = ByteSink{ .list = &req, .gpa = gpa };
    try writeQuery(&rs, Game, .{ .component = .{} });

    // respond -> GKZR1 frame
    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    var os = ByteSink{ .list = &resp, .gpa = gpa };
    try respond(Game, &demo_systems, gpa, eng, req.items, &os);

    // the response decodes to the component relation with the one cell
    var reader = ByteReader{ .bytes = resp.items };
    var result = try resultmod.readResult(gpa, &reader);
    defer result.deinit(gpa);
    try testing.expectEqual(@import("term.zig").RelId.component, result.rel);
    try testing.expectEqual(@as(usize, 1), result.rows.items.len);
    try testing.expectEqual(@as(u32, 0), result.rows.items[0].vals[0].entity.index);
}
