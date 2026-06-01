//! The AI control-plane command/response codec (SPEC §13, PLAN.md §17.2). The query server (qserver.zig)
//! lets the AI OBSERVE a live sim; this is how it DRIVES one. A request frame is `[u32 sim_id]
//! [GKZC2 ControlCommand]`; a reply is `[GKZD1 ControlResponse]`. Like `proc/job.zig`, these bytes cross
//! a socket (an OS boundary), so the codec is hostile-input-hardened: 5-byte magic + `u16` version + `u8`
//! arm tag; every variable-length section (Input streams, byte payloads) parsed INCREMENTALLY so a
//! hostile count never drives a pre-allocation; a malformed frame is a returned `serialize.Error`, never a
//! panic; trailing garbage after a valid frame is `Corrupt`. `R` is NEVER serialized — commands name `u16`
//! selector ids into the server's R-fixed comptime tables (the data↔code boundary, exactly as GKZJ1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const input = @import("../input.zig");
const Command = input.Command;
const Input = input.Input;

pub const CMD_MAGIC = [5]u8{ 'G', 'K', 'Z', 'C', '2' }; // C1 is control.zig's ControlSchedule codec
pub const RSP_MAGIC = [5]u8{ 'G', 'K', 'Z', 'D', '1' };
pub const WIRE_VERSION: u16 = 1;

/// The AI control-command vocabulary — DATA + selector ids only (no `R`, no fn-ptrs).
pub const ControlCommand = union(enum) {
    // R-fingerprint handshake + a capability token. `fingerprint` is currentFingerprint(R)'s bytes (so a
    // wrong-R client is refused); `token` is the shared secret the server may require before any command
    // (empty when the server runs token-less / open). The control plane crosses a socket to a privileged
    // mutate surface, so a server with a configured secret refuses an unauthenticated client.
    hello: struct { fingerprint: []const u8, token: []const u8 },
    query: []const u8, // a GKZQ1 query frame, delegated verbatim to query/wire.respond
    step: struct { n: u64, inline_inputs: []const Input }, // advance n ticks (drives a divergent live trajectory)
    reload: struct { set_id: u16 }, // swap the live system set (SAME R)
    fork: struct { new_sim_id: u32, diverged_inputs: []const Input, tick_budget: u64 }, // → a NEW owned sim
    snapshot, // canonical bytes of the owned World
    migrate: struct { migration_id: u16 }, // the R re-typing boundary (returns migrated canonical bytes)
};

/// Every failure is a TYPED arm — never a dropped connection (an AI operator MUST observe the failure).
pub const ControlErr = enum(u16) {
    unknown_sim = 0,
    bad_set_id = 1,
    bad_migration_id = 2,
    bad_command = 3,
    no_such_migration = 4,
    capture_full = 5,
    sim_id_in_use = 6,
    schema_mismatch = 7, // the hello fingerprint did not match this server's R
    unauthorized = 8, // a command before a valid hello, or a hello whose token did not match the server secret
    _,
};

pub const ControlResponse = union(enum) {
    hello_ok: struct { ok: bool },
    query_result: []const u8,
    stepped: struct { tick: u64, digest: u64 },
    reloaded: struct { set_id: u16, tick: u64 },
    forked: struct { new_sim_id: u32, tick: u64, digest: u64 },
    snapshot_bytes: []const u8,
    migrated: struct { migration_id: u16, at_tick: u64, bytes: []const u8 },
    err: ControlErr,
};

fn u32Len(n: usize) serialize.Error!u32 {
    if (n > std.math.maxInt(u32)) return error.Corrupt;
    return @intCast(n);
}

// --- shared Input-stream codec (step.inline_inputs + fork.diverged_inputs) ------------------------

fn writeInputs(sink: *serialize.ByteSink, inputs: []const Input) (serialize.Error || Allocator.Error)!void {
    try serialize.putInt(sink, u32, try u32Len(inputs.len));
    for (inputs) |in| {
        try serialize.putInt(sink, u64, in.tick);
        try serialize.putInt(sink, u32, try u32Len(in.commands.len));
        for (in.commands) |c| try serialize.writeValue(sink, Command, c);
    }
}

/// Incremental: a hostile count never drives a pre-alloc — each Input is ≥ 12 bytes, so the list grows
/// only proportionally to bytes actually present (the job.zig / image.decode discipline).
fn readInputs(a: Allocator, r: *serialize.ByteReader) (serialize.Error || Allocator.Error)![]const Input {
    const n = try serialize.getInt(r, u32);
    var inputs: std.ArrayList(Input) = .empty;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const tick = try serialize.getInt(r, u64);
        const n_cmd = try serialize.getInt(r, u32);
        var cmds: std.ArrayList(Command) = .empty;
        var j: u32 = 0;
        while (j < n_cmd) : (j += 1) try cmds.append(a, try serialize.readValue(Command, r));
        try inputs.append(a, .{ .tick = tick, .commands = cmds.items });
    }
    return inputs.items;
}

fn writeBytes(sink: *serialize.ByteSink, bytes: []const u8) (serialize.Error || Allocator.Error)!void {
    try serialize.putInt(sink, u32, try u32Len(bytes.len));
    try sink.update(bytes);
}
fn readBytes(a: Allocator, r: *serialize.ByteReader) (serialize.Error || Allocator.Error)![]const u8 {
    const n = try serialize.getInt(r, u32);
    return a.dupe(u8, try r.readSlice(n)); // readSlice bounds-checks → no over-alloc
}

// --- command codec --------------------------------------------------------------------------------

pub fn writeCommand(sink: *serialize.ByteSink, sim_id: u32, cmd: ControlCommand) (serialize.Error || Allocator.Error)!void {
    try serialize.putInt(sink, u32, sim_id);
    try sink.update(&CMD_MAGIC);
    try serialize.putInt(sink, u16, WIRE_VERSION);
    try serialize.putInt(sink, u8, @intFromEnum(cmd));
    switch (cmd) {
        .hello => |h| {
            try writeBytes(sink, h.fingerprint);
            try writeBytes(sink, h.token);
        },
        .query => |b| try writeBytes(sink, b),
        .step => |s| {
            try serialize.putInt(sink, u64, s.n);
            try writeInputs(sink, s.inline_inputs);
        },
        .reload => |r| try serialize.putInt(sink, u16, r.set_id),
        .fork => |f| {
            try serialize.putInt(sink, u32, f.new_sim_id);
            try serialize.putInt(sink, u64, f.tick_budget);
            try writeInputs(sink, f.diverged_inputs);
        },
        .snapshot => {},
        .migrate => |m| try serialize.putInt(sink, u16, m.migration_id),
    }
}

pub const DecodedCommand = struct {
    sim_id: u32,
    cmd: ControlCommand,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *DecodedCommand) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decodeCommand(gpa: Allocator, bytes: []const u8) (serialize.Error || Allocator.Error)!DecodedCommand {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var r = serialize.ByteReader{ .bytes = bytes };

    const sim_id = try serialize.getInt(&r, u32);
    if (!std.mem.eql(u8, try r.readSlice(5), &CMD_MAGIC)) return error.BadMagic;
    if (try serialize.getInt(&r, u16) != WIRE_VERSION) return error.UnsupportedFormat;
    const tag = try serialize.getInt(&r, u8);
    const cmd: ControlCommand = switch (tag) {
        0 => .{ .hello = .{ .fingerprint = try readBytes(a, &r), .token = try readBytes(a, &r) } },
        1 => .{ .query = try readBytes(a, &r) },
        2 => .{ .step = .{ .n = try serialize.getInt(&r, u64), .inline_inputs = try readInputs(a, &r) } },
        3 => .{ .reload = .{ .set_id = try serialize.getInt(&r, u16) } },
        4 => blk: {
            const new_sim_id = try serialize.getInt(&r, u32);
            const tick_budget = try serialize.getInt(&r, u64);
            break :blk .{ .fork = .{ .new_sim_id = new_sim_id, .tick_budget = tick_budget, .diverged_inputs = try readInputs(a, &r) } };
        },
        5 => .snapshot,
        6 => .{ .migrate = .{ .migration_id = try serialize.getInt(&r, u16) } },
        else => return error.Corrupt,
    };
    if (r.pos != bytes.len) return error.Corrupt; // reject trailing garbage
    return .{ .sim_id = sim_id, .cmd = cmd, .arena = arena };
}

// --- response codec -------------------------------------------------------------------------------

pub fn writeResponse(sink: *serialize.ByteSink, resp: ControlResponse) (serialize.Error || Allocator.Error)!void {
    try sink.update(&RSP_MAGIC);
    try serialize.putInt(sink, u16, WIRE_VERSION);
    try serialize.putInt(sink, u8, @intFromEnum(resp));
    switch (resp) {
        .hello_ok => |x| try serialize.putInt(sink, u8, @intFromBool(x.ok)),
        .query_result => |b| try writeBytes(sink, b),
        .stepped => |x| {
            try serialize.putInt(sink, u64, x.tick);
            try serialize.putInt(sink, u64, x.digest);
        },
        .reloaded => |x| {
            try serialize.putInt(sink, u16, x.set_id);
            try serialize.putInt(sink, u64, x.tick);
        },
        .forked => |x| {
            try serialize.putInt(sink, u32, x.new_sim_id);
            try serialize.putInt(sink, u64, x.tick);
            try serialize.putInt(sink, u64, x.digest);
        },
        .snapshot_bytes => |b| try writeBytes(sink, b),
        .migrated => |x| {
            try serialize.putInt(sink, u16, x.migration_id);
            try serialize.putInt(sink, u64, x.at_tick);
            try writeBytes(sink, x.bytes);
        },
        .err => |e| try serialize.putInt(sink, u16, @intFromEnum(e)),
    }
}

pub const DecodedResponse = struct {
    resp: ControlResponse,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *DecodedResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decodeResponse(gpa: Allocator, bytes: []const u8) (serialize.Error || Allocator.Error)!DecodedResponse {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var r = serialize.ByteReader{ .bytes = bytes };

    if (!std.mem.eql(u8, try r.readSlice(5), &RSP_MAGIC)) return error.BadMagic;
    if (try serialize.getInt(&r, u16) != WIRE_VERSION) return error.UnsupportedFormat;
    const tag = try serialize.getInt(&r, u8);
    const resp: ControlResponse = switch (tag) {
        0 => .{ .hello_ok = .{ .ok = (try serialize.getInt(&r, u8)) != 0 } },
        1 => .{ .query_result = try readBytes(a, &r) },
        2 => .{ .stepped = .{ .tick = try serialize.getInt(&r, u64), .digest = try serialize.getInt(&r, u64) } },
        3 => .{ .reloaded = .{ .set_id = try serialize.getInt(&r, u16), .tick = try serialize.getInt(&r, u64) } },
        4 => .{ .forked = .{ .new_sim_id = try serialize.getInt(&r, u32), .tick = try serialize.getInt(&r, u64), .digest = try serialize.getInt(&r, u64) } },
        5 => .{ .snapshot_bytes = try readBytes(a, &r) },
        6 => .{ .migrated = .{ .migration_id = try serialize.getInt(&r, u16), .at_tick = try serialize.getInt(&r, u64), .bytes = try readBytes(a, &r) } },
        7 => .{ .err = @enumFromInt(try serialize.getInt(&r, u16)) }, // @intFromEnum(.err) == 7 (the 8th arm)
        else => return error.Corrupt,
    };
    if (r.pos != bytes.len) return error.Corrupt;
    return .{ .resp = resp, .arena = arena };
}

// ---------------------------------------------------------------------------------------------------
// Tests — round-trip byte-identity + hostile rejection (the job.zig discipline)
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

fn roundTripCmd(gpa: Allocator, sim_id: u32, cmd: ControlCommand) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try writeCommand(&sink, sim_id, cmd);
    var dec = try decodeCommand(gpa, buf.items);
    defer dec.deinit();
    try testing.expectEqual(sim_id, dec.sim_id);
    // re-encode the decoded command → byte-identical (canonical fixed point)
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(gpa);
    var s2 = serialize.ByteSink{ .list = &buf2, .gpa = gpa };
    try writeCommand(&s2, dec.sim_id, dec.cmd);
    try testing.expectEqualSlices(u8, buf.items, buf2.items);
}

test "every command arm round-trips byte-identically" {
    const gpa = testing.allocator;
    const cmds = .{
        ControlCommand{ .hello = .{ .fingerprint = "fp-bytes", .token = "secret" } },
        ControlCommand{ .query = "GKZQ1..." },
        ControlCommand{ .step = .{ .n = 5, .inline_inputs = &.{.{ .tick = 1, .commands = &.{.{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 }} }} } },
        ControlCommand{ .reload = .{ .set_id = 2 } },
        ControlCommand{ .fork = .{ .new_sim_id = 99, .tick_budget = 7, .diverged_inputs = &.{} } },
        ControlCommand.snapshot,
        ControlCommand{ .migrate = .{ .migration_id = 1 } },
    };
    inline for (cmds) |c| try roundTripCmd(gpa, 7, c);
}

test "every response arm round-trips byte-identically" {
    const gpa = testing.allocator;
    const resps = .{
        ControlResponse{ .hello_ok = .{ .ok = true } },
        ControlResponse{ .query_result = "GKZR1..." },
        ControlResponse{ .stepped = .{ .tick = 9, .digest = 0xABCD } },
        ControlResponse{ .reloaded = .{ .set_id = 1, .tick = 9 } },
        ControlResponse{ .forked = .{ .new_sim_id = 99, .tick = 3, .digest = 0x1234 } },
        ControlResponse{ .snapshot_bytes = "world-bytes" },
        ControlResponse{ .migrated = .{ .migration_id = 0, .at_tick = 6, .bytes = "v2-bytes" } },
        ControlResponse{ .err = .unknown_sim },
    };
    inline for (resps) |resp| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
        try writeResponse(&sink, resp);
        var dec = try decodeResponse(gpa, buf.items);
        defer dec.deinit();
        var buf2: std.ArrayList(u8) = .empty;
        defer buf2.deinit(gpa);
        var s2 = serialize.ByteSink{ .list = &buf2, .gpa = gpa };
        try writeResponse(&s2, dec.resp);
        try testing.expectEqualSlices(u8, buf.items, buf2.items);
    }
}

test "hostile command frames are rejected, never a panic" {
    const gpa = testing.allocator;
    // bad magic (sim_id then wrong magic)
    var bad = serialize.ByteReader{ .bytes = "\x07\x00\x00\x00ZZZZZ\x01\x00\x05" };
    _ = &bad;
    try testing.expectError(error.BadMagic, decodeCommand(gpa, "\x07\x00\x00\x00ZZZZZ\x01\x00\x05"));

    // a valid step command, then truncate it → Truncated
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try writeCommand(&sink, 1, .{ .step = .{ .n = 2, .inline_inputs = &.{} } });
    try testing.expectError(error.Truncated, decodeCommand(gpa, buf.items[0 .. buf.items.len - 1]));
    // trailing garbage → Corrupt
    const padded = try std.mem.concat(gpa, u8, &.{ buf.items, "X" });
    defer gpa.free(padded);
    try testing.expectError(error.Corrupt, decodeCommand(gpa, padded));
    // unknown arm tag → Corrupt (sim_id + magic + version + tag=250)
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(gpa);
    var ts = serialize.ByteSink{ .list = &t, .gpa = gpa };
    try serialize.putInt(&ts, u32, 1);
    try ts.update(&CMD_MAGIC);
    try serialize.putInt(&ts, u16, WIRE_VERSION);
    try serialize.putInt(&ts, u8, 250);
    try testing.expectError(error.Corrupt, decodeCommand(gpa, t.items));
}
