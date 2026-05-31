//! Input — the sole nondeterminism channel (SPEC §1/§2.3, PLAN.md build-order step 9; resolves Q3).
//!
//! An `Input` is one tick's worth of `Command`s: a typed, fixed-shape, POD command list. It is the only
//! way nondeterminism enters the sim, and it is the identical channel a human, a script, and a future
//! `observe(State)->Input` agent (§10) all emit. A `Command` is structurally a command-buffer entry
//! (S2), so the §4 per-system buffers reuse it verbatim.
//!
//! Intra-tick order is canonicalized to a stable total order — sort by `(actor.index, verb)`, ties
//! broken by arrival order (the sort is stable) — so the applied order is a pure function of the
//! command set, never of producer iteration order.

const std = @import("std");
const entity = @import("entity.zig");
const serialize = @import("serialize.zig");
const sortmod = @import("sort.zig");
const Entity = entity.Entity;

/// A single action. `extern` + fixed-shape so it is trivially POD, recordable, and diffable. The
/// scalar args carry `Fixed.raw` / `Angle.raw` / entity bits / a `kind_id`, interpreted by `verb`.
pub const Command = extern struct {
    actor: Entity,
    verb: u16,
    _pad: u16 = 0,
    a0: i64 = 0,
    a1: i64 = 0,
    a2: i64 = 0,
};

/// One tick's commands. `tick` is the tick the input applies to (recorded for replay alignment).
pub const Input = struct {
    tick: u64,
    commands: []const Command,
};

fn lessThan(_: void, a: Command, b: Command) bool {
    if (a.actor.index != b.actor.index) return a.actor.index < b.actor.index;
    return a.verb < b.verb;
}

/// Return a freshly-allocated copy of `commands` in canonical order (stable sort by actor.index then
/// verb; ties keep arrival order). Caller frees.
pub fn canonicalize(gpa: std.mem.Allocator, commands: []const Command) std.mem.Allocator.Error![]Command {
    const copy = try gpa.dupe(Command, commands);
    sortmod.sort(Command, copy, {}, lessThan);
    return copy;
}

// --- input-log codec (record/replay of the (seed, inputs) stream) ---------------------------------

/// Append one `Input` to a serialization sink (little-endian, via the shared codec).
pub fn writeInput(sink: anytype, in: Input) !void {
    try serialize.putInt(sink, u64, in.tick);
    try serialize.putInt(sink, u32, @intCast(in.commands.len));
    for (in.commands) |c| try serialize.writeValue(sink, Command, c);
}

/// Read one `Input` (allocating its command slice; caller frees `.commands`).
pub fn readInput(gpa: std.mem.Allocator, reader: *serialize.ByteReader) !Input {
    const tick = try serialize.getInt(reader, u64);
    const n = try serialize.getInt(reader, u32);
    const cmds = try gpa.alloc(Command, n);
    errdefer gpa.free(cmds);
    for (cmds) |*c| c.* = try serialize.readValue(Command, reader);
    return .{ .tick = tick, .commands = cmds };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

fn cmd(idx: u32, verb: u16) Command {
    return .{ .actor = .{ .index = idx, .generation = 0 }, .verb = verb };
}

test "canonicalize sorts by (actor.index, verb), stable on ties" {
    const gpa = testing.allocator;
    // arrival order deliberately scrambled; two entries tie on (1, 7) with distinct a0 to check stability
    var two_a = cmd(1, 7);
    two_a.a0 = 100;
    var two_b = cmd(1, 7);
    two_b.a0 = 200;
    const raw = [_]Command{ cmd(2, 0), two_a, cmd(0, 9), cmd(1, 3), two_b };
    const out = try canonicalize(gpa, &raw);
    defer gpa.free(out);

    try testing.expectEqual(@as(u32, 0), out[0].actor.index);
    try testing.expectEqual(@as(u32, 1), out[1].actor.index); // (1,3) before (1,7)
    try testing.expectEqual(@as(u16, 3), out[1].verb);
    try testing.expectEqual(@as(u16, 7), out[2].verb);
    try testing.expectEqual(@as(i64, 100), out[2].a0); // tie kept arrival order: two_a before two_b
    try testing.expectEqual(@as(i64, 200), out[3].a0);
    try testing.expectEqual(@as(u32, 2), out[4].actor.index);
}

test "input-log codec round-trips" {
    const gpa = testing.allocator;
    const cmds = [_]Command{ cmd(3, 1), .{ .actor = .{ .index = 9, .generation = 2 }, .verb = 2, .a0 = -7, .a1 = 42 } };
    const in = Input{ .tick = 99, .commands = &cmds };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try writeInput(&sink, in);

    var reader = serialize.ByteReader{ .bytes = buf.items };
    const got = try readInput(gpa, &reader);
    defer gpa.free(got.commands);
    try testing.expectEqual(@as(u64, 99), got.tick);
    try testing.expectEqual(@as(usize, 2), got.commands.len);
    try testing.expectEqual(@as(i64, -7), got.commands[1].a0);
    try testing.expectEqual(@as(u32, 9), got.commands[1].actor.index);
}
