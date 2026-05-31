//! The external / NN / LLM inference seam (PLAN.md Phase 7, §10): the ONLY contact point a learned or
//! out-of-process player has with the kernel.
//!
//! `ExternalAgent(R)` is a bare function pointer + an opaque `ctx`: the kernel CALLS `infer_fn` with a
//! read-only `ObsView` and CAPTURES the returned `Input` (buildRun appends it to `Run.inputs`). The
//! NN/LLM/RL engine, INT8 tensor cores, GPU, or an out-of-process socket proxy all live BEHIND `ctx` —
//! the kernel links no inference runtime, runs no float, and stays integer-deterministic. `root` (the
//! seed) is deliberately NOT forwarded: an external source makes no false promise of seed-reproducibility
//! (class `.external`). Its sole egress is the `?Input` it returns, through the normal step channel — it
//! CANNOT touch the sim path (the `ObsView` is `*const`). Reproducibility of any run it drives comes from
//! CAPTURING it, never from re-invoking it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const observe = @import("observe.zig");
const ObsView = observe.ObsView;
const agentmod = @import("agent.zig");
const Agent = agentmod.Agent;
const worldmod = @import("../world.zig");
const rng = @import("../rng.zig");
const input = @import("../input.zig");

/// An external player. `infer_fn(ctx, gpa, tick, view)` observes (read-only) and emits an `?Input`.
pub fn ExternalAgent(comptime R: type) type {
    return struct {
        ctx: *anyopaque,
        infer_fn: *const fn (*anyopaque, Allocator, u64, ObsView(R)) Allocator.Error!?input.Input,
    };
}

var unused_ctx: u8 = 0;

/// Lift an `ExternalAgent` into a `.external`-class `Agent`. The lowered Generator DISCARDS `root` (no
/// seed promise) and calls `infer_fn` with a read-only `ObsView`. `ea` is caller-owned storage outliving
/// the Agent.
pub fn externalAgent(comptime R: type, ea: *ExternalAgent(R)) Agent(R) {
    const Impl = struct {
        fn next(ctx: *anyopaque, gpa: Allocator, tick: u64, root: rng.RngRoot, view: ?*const worldmod.World(R)) Allocator.Error!?input.Input {
            _ = root; // external sources get no seed
            const e: *ExternalAgent(R) = @ptrCast(@alignCast(ctx));
            const w = view orelse return null;
            return e.infer_fn(e.ctx, gpa, tick, ObsView(R).init(w));
        }
    };
    return .{ .name = "external", .class = .external, .gen = .{ .ctx = ea, .next_fn = Impl.next } };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const system = schedule.system;
const q2 = @import("../query.zig");
const simctx = @import("../simctx.zig");
const Write = q2.Write;
const runmod = @import("../vopr/run.zig");
const serialize = @import("../serialize.zig");
const Command = input.Command;

const Tag = struct {
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Tag});
fn noop(ctx: *simctx.SimCtx(Game), qq: *q2.Query(Game, .{Write(Tag)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = qq;
}
const game_systems = [_]Sys(Game){system(Game, "noop", noop)};

// a deterministic external player: spawn every tick (fixed table) — captured into Run.inputs
fn fixedInfer(ctx: *anyopaque, gpa: Allocator, tick: u64, view: ObsView(Game)) Allocator.Error!?input.Input {
    _ = ctx;
    _ = view;
    const cmds = try gpa.alloc(Command, 1);
    cmds[0] = .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 }; // spawn
    return input.Input{ .tick = tick, .commands = cmds };
}

test "externalAgent: a fixed infer_fn is captured into Run.inputs (class .external)" {
    const gpa = testing.allocator;
    var ea = ExternalAgent(Game){ .ctx = &unused_ctx, .infer_fn = fixedInfer };
    const a = externalAgent(Game, &ea);
    try testing.expectEqual(agentmod.DeterminismClass.external, a.class);
    var run = try runmod.buildRun(Game, gpa, &game_systems, worldmod.World(Game).init(0), 0, a.gen, 3);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), run.final.table.rowCount()); // spawned 3 times, captured
    for (run.inputs) |in| try testing.expectEqual(@as(usize, 1), in.commands.len);
}

// an IMPURE external player: output depends on a MUTABLE in-ctx counter (stands in for INT8/GPU
// reduction-order nonreproducibility) — NOT a function of (seed, tick). `invoked` counts calls.
const Impure = struct { counter: u64 = 0, invoked: u64 = 0 };
fn impureInfer(ctx: *anyopaque, gpa: Allocator, tick: u64, view: ObsView(Game)) Allocator.Error!?input.Input {
    _ = view;
    const s: *Impure = @ptrCast(@alignCast(ctx));
    s.invoked += 1;
    const verb: u16 = if (s.counter % 2 == 0) 1 else 2; // alternates spawn/despawn on the external counter
    s.counter += 1;
    const cmds = try gpa.alloc(Command, 1);
    cmds[0] = .{ .actor = .{ .index = 0, .generation = 0 }, .verb = verb };
    return input.Input{ .tick = tick, .commands = cmds };
}

test "an impure external agent produces DIFFERENT inputs on two buildRuns (genuine irreproducibility)" {
    const gpa = testing.allocator;
    var st = Impure{};
    var ea = ExternalAgent(Game){ .ctx = &st, .infer_fn = impureInfer };
    const a = externalAgent(Game, &ea);
    // same seed, same world — but the mutable counter carries across runs, so the streams diverge
    var r1 = try runmod.buildRun(Game, gpa, &game_systems, worldmod.World(Game).init(0), 0, a.gen, 3);
    defer r1.deinit(gpa);
    var r2 = try runmod.buildRun(Game, gpa, &game_systems, worldmod.World(Game).init(0), 0, a.gen, 3);
    defer r2.deinit(gpa);
    // the two runs do NOT agree — reproducibility cannot come from (seed, tick); only capture works
    try testing.expect(!std.mem.eql(u64, r1.hashes, r2.hashes));
    try testing.expectEqual(@as(u64, 6), st.invoked); // 3 + 3 calls
}

// an out-of-process-SHAPED infer_fn: it builds an Input, round-trips it through the wire codec
// (input.writeInput/readInput) and returns the reconstructed Input — proving the boundary is
// transport-ready WITHOUT building transport or linking IPC.
fn wireShapedInfer(ctx: *anyopaque, gpa: Allocator, tick: u64, view: ObsView(Game)) Allocator.Error!?input.Input {
    _ = ctx;
    _ = view;
    const cmds = try gpa.alloc(Command, 1);
    cmds[0] = .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 };
    const out = input.Input{ .tick = tick, .commands = cmds };
    // serialize -> deserialize (as if crossing a process boundary), then return the reconstructed Input
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    input.writeInput(&sink, out) catch return error.OutOfMemory;
    gpa.free(cmds);
    var reader = serialize.ByteReader{ .bytes = buf.items };
    return input.readInput(gpa, &reader) catch return error.OutOfMemory;
}

test "the external seam is transport-ready: an infer_fn round-tripping its Input through the wire codec works" {
    const gpa = testing.allocator;
    var ea = ExternalAgent(Game){ .ctx = &unused_ctx, .infer_fn = wireShapedInfer };
    const a = externalAgent(Game, &ea);
    var run = try runmod.buildRun(Game, gpa, &game_systems, worldmod.World(Game).init(0), 0, a.gen, 2);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), run.final.table.rowCount()); // both wire-reconstructed spawns applied
}
