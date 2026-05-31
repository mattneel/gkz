//! Delta-debug minimization of a failing input stream (SPEC §9, PLAN.md Phase 4). Build-order step 6.
//!
//! Given a failing `(seed, inputs)`, shrink the input stream to a minimal reproducing case. Two
//! granularities, greedy left-to-right element removal to a 1-minimal fixpoint (a deterministic
//! delta-debug; full Zeller block-removal is a later optimization): first whole ticks (drop an
//! `Input`; survivors replay at dense consecutive ticks via `scriptedGen`), then commands within the
//! surviving ticks. The predicate is KIND-LOCKED: a candidate must reproduce the SAME `Defect.Kind`
//! (the first tick may move earlier — acceptable shrinkage — but the kind must match), so ddmin never
//! drifts into a different bug. Deterministic: fixed traversal order, no RNG, no clock. The oracle is
//! injected as a value, so this module does not import the sweep — it is unit-testable alone.

const std = @import("std");
const runmod = @import("run.zig");
const oraclemod = @import("oracle.zig");
const snapshotmod = @import("../snapshot.zig");
const generator = @import("generator.zig");
const input = @import("../input.zig");
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const Allocator = std.mem.Allocator;

pub const Minimized = struct {
    inputs: []const input.Input,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *Minimized) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn copyInputs(a: Allocator, inputs: []const input.Input) Allocator.Error![]input.Input {
    const out = try a.alloc(input.Input, inputs.len);
    for (inputs, 0..) |in, i| out[i] = .{ .tick = @intCast(i + 1), .commands = try a.dupe(input.Command, in.commands) };
    return out;
}

fn withoutInput(a: Allocator, inputs: []const input.Input, drop: usize) Allocator.Error![]input.Input {
    const out = try a.alloc(input.Input, inputs.len - 1);
    var j: usize = 0;
    for (inputs, 0..) |in, i| {
        if (i == drop) continue;
        out[j] = .{ .tick = @intCast(j + 1), .commands = in.commands }; // renumber to dense ticks
        j += 1;
    }
    return out;
}

fn withoutCommand(a: Allocator, inputs: []const input.Input, ti: usize, ci: usize) Allocator.Error![]input.Input {
    const out = try a.alloc(input.Input, inputs.len);
    for (inputs, 0..) |in, i| {
        if (i != ti) {
            out[i] = in;
            continue;
        }
        const cmds = try a.alloc(input.Command, in.commands.len - 1);
        var j: usize = 0;
        for (in.commands, 0..) |c, k| {
            if (k == ci) continue;
            cmds[j] = c;
            j += 1;
        }
        out[i] = .{ .tick = in.tick, .commands = cmds };
    }
    return out;
}

/// Re-check: does `candidate` (replayed from the run's initial snapshot under `seed`) still trip the
/// SAME defect kind? Builds and frees a fresh Run per call (self-contained).
fn stillFails(
    comptime R: type,
    gpa: Allocator,
    comptime systems: []const Sys(R),
    base: snapshotmod.Snapshot,
    seed: u64,
    oracle: oraclemod.Oracle(R),
    target: oraclemod.Defect(R).Kind,
    candidate: []const input.Input,
) Allocator.Error!bool {
    const w0 = snapshotmod.restore(R, gpa, base) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // base is a kernel-produced valid snapshot
    };
    var spec = generator.ScriptedSpec{ .inputs = candidate };
    const gen = generator.scriptedGen(R, &spec);
    var run = try runmod.buildRun(R, gpa, systems, w0, seed, gen, candidate.len);
    defer run.deinit(gpa);
    const d = try oracle.eval(&run, gpa);
    return d != null and d.?.kind == target;
}

/// Shrink `inputs` to a 1-minimal reproducing stream. `target` is the defect kind to preserve. Caller
/// `deinit`s the result.
pub fn minimize(
    comptime R: type,
    gpa: Allocator,
    comptime systems: []const Sys(R),
    base: snapshotmod.Snapshot,
    seed: u64,
    oracle: oraclemod.Oracle(R),
    target: oraclemod.Defect(R).Kind,
    inputs: []const input.Input,
) !Minimized {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var cur = try copyInputs(a, inputs);

    // Pass 1: drop whole ticks.
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < cur.len) {
            const cand = try withoutInput(a, cur, i);
            if (try stillFails(R, gpa, systems, base, seed, oracle, target, cand)) {
                cur = cand;
                changed = true; // keep shrinking from the same position
            } else i += 1;
        }
    }

    // Pass 2: drop commands within surviving ticks.
    changed = true;
    while (changed) {
        changed = false;
        outer: for (cur, 0..) |in, ti| {
            var ci: usize = 0;
            while (ci < in.commands.len) {
                const cand = try withoutCommand(a, cur, ti, ci);
                if (try stillFails(R, gpa, systems, base, seed, oracle, target, cand)) {
                    cur = cand;
                    changed = true;
                    break :outer; // restart the scan after any change
                } else ci += 1;
            }
        }
    }

    return .{ .inputs = cur, .arena = arena };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("../registry.zig").Registry;
const query = @import("../query.zig");
const simctx = @import("../simctx.zig");
const worldmod = @import("../world.zig");
const SimCtx = simctx.SimCtx;
const Query = query.Query;
const system = schedule.system;
const Read = query.Read;
const Defect = oraclemod.Defect;
const Run = runmod.Run;

const Tag = struct {
    v: u8,
    pub const kind_id: u16 = 1;
};
const MReg = Registry(.{Tag});
fn noop(ctx: *SimCtx(MReg), q: *Query(MReg, .{Read(Tag)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}
const msys = [_]Sys(MReg){system(MReg, "noop", noop)};

// A synthetic oracle: "fails" (kind .invariant) iff some command in the stream has verb == 99.
var marker_ctx: u8 = 0;
fn markerEval(ctx: *anyopaque, run: *const Run(MReg), gpa: std.mem.Allocator) std.mem.Allocator.Error!?Defect(MReg) {
    _ = ctx;
    _ = gpa;
    for (run.inputs, 0..) |in, ti| {
        for (in.commands) |c| {
            if (c.verb == 99) return Defect(MReg){ .seed = run.seed, .tick = @intCast(ti + 1), .kind = .invariant, .oracle = "marker", .detail = .none };
        }
    }
    return null;
}
const marker_oracle = oraclemod.Oracle(MReg){ .name = "marker", .kind = .invariant, .ctx = &marker_ctx, .eval_fn = markerEval };

test "minimize shrinks to exactly the one tick + one command that trips the oracle" {
    const gpa = testing.allocator;
    // a long noisy stream; the needle is verb==99 buried at tick 4, command 1
    var w0 = worldmod.World(MReg).init(0);
    var base = try snapshotmod.snapshot(MReg, gpa, &w0);
    defer base.deinit(gpa);
    w0.deinit(gpa);

    const noise = input.Command{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 };
    const needle = input.Command{ .actor = .{ .index = 0, .generation = 0 }, .verb = 99 };
    const t0 = [_]input.Command{ noise, noise };
    const t3 = [_]input.Command{ noise, needle, noise }; // tick 4 carries the needle
    const stream = [_]input.Input{
        .{ .tick = 1, .commands = &t0 },
        .{ .tick = 2, .commands = &t0 },
        .{ .tick = 3, .commands = &t0 },
        .{ .tick = 4, .commands = &t3 },
        .{ .tick = 5, .commands = &t0 },
    };

    var min = try minimize(MReg, gpa, &msys, base, 0, marker_oracle, .invariant, &stream);
    defer min.deinit();

    // exactly one surviving tick with exactly one command, and that command is the needle
    try testing.expectEqual(@as(usize, 1), min.inputs.len);
    try testing.expectEqual(@as(usize, 1), min.inputs[0].commands.len);
    try testing.expectEqual(@as(u16, 99), min.inputs[0].commands[0].verb);
}

test "minimize is kind-locked: a candidate tripping a DIFFERENT kind does not count as still-failing" {
    const gpa = testing.allocator;
    var w0 = worldmod.World(MReg).init(0);
    var base = try snapshotmod.snapshot(MReg, gpa, &w0);
    defer base.deinit(gpa);
    w0.deinit(gpa);
    const needle = input.Command{ .actor = .{ .index = 0, .generation = 0 }, .verb = 99 };
    const t = [_]input.Command{needle};
    const stream = [_]input.Input{.{ .tick = 1, .commands = &t }};
    // target .divergence, but the oracle only ever yields .invariant -> nothing "still fails" ->
    // minimize cannot drop the needle (every candidate is non-failing under the target kind),
    // so it returns the input unchanged (1 tick, 1 command).
    var min = try minimize(MReg, gpa, &msys, base, 0, marker_oracle, .divergence, &stream);
    defer min.deinit();
    try testing.expectEqual(@as(usize, 1), min.inputs.len);
}
