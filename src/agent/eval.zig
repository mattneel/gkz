//! Mass evaluation (PLAN.md Phase 7, §10): run agent playthroughs faster-than-realtime and aggregate the
//! §8 intent-metrics — making the DETERMINISM CLASS explicit to the caller.
//!
//! `aggregateAgent` routes on `agent.class`: a REPRODUCIBLE policy (deterministic*/replay) delegates to
//! Phase-6 `metric.aggregate` VERBATIM — inputs re-derive from the seed range, the `Aggregate` is bit-
//! reproducible, nothing is retained. An `.external` policy is run-level nondeterministic: each seed is
//! built ONCE, the resulting `Run` is KEPT (the Run IS the revisit artifact — `Run.inputs` is the full
//! record), measured, and reduced into the same `Aggregate`. The return shape signals the regime: the
//! `runs` slice is non-empty ONLY for `.external`. `sweepAgent` forwards to the VOPR `sweep`; debugging a
//! specific captured run means `asAgent`-ing it (→ a `.replay` agent) and sweeping THAT, so minimize/
//! provenance consume the captured inputs and never re-invoke the source.

const std = @import("std");
const Allocator = std.mem.Allocator;
const agentmod = @import("agent.zig");
const Agent = agentmod.Agent;
const isReproducible = agentmod.isReproducible;
const metric = @import("../spec/metric.zig");
const Metric = metric.Metric;
const Aggregate = metric.Aggregate;
const runmod = @import("../vopr/run.zig");
const Run = runmod.Run;
const vopr = @import("../vopr/vopr.zig");
const worldmod = @import("../world.zig");
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const atommod = @import("../spec/atom.zig");
const oraclemod = @import("../vopr/oracle.zig");

/// The result of an agent evaluation. `runs` is owned by the caller — ALWAYS free it uniformly:
/// `for (res.runs) |*r| r.deinit(gpa); gpa.free(res.runs);`. It is a heap-allocated EMPTY slice for the
/// reproducible regime and the per-seed captured Runs for the `.external` regime.
pub fn AgentEval(comptime R: type, comptime T: type) type {
    return struct { agg: Aggregate(T), runs: []Run(R) };
}

/// Aggregate `metric` over `[seed_lo, seed_hi)` driven by `agent`. Reproducible regime → delegate to
/// `metric.aggregate`; `.external` regime → capture each run, measure, reduce, return the captured runs.
pub fn aggregateAgent(
    comptime R: type,
    comptime systems: []const Sys(R),
    comptime atoms: []const atommod.Atom(R),
    comptime want_log: bool,
    comptime T: type,
    gpa: Allocator,
    seed_world: *const fn (Allocator, u64) Allocator.Error!worldmod.World(R),
    agent: Agent(R),
    metric_def: Metric(T),
    seed_lo: u64,
    seed_hi: u64,
    max_ticks: usize,
) Allocator.Error!AgentEval(R, T) {
    if (isReproducible(agent.class)) {
        const agg = metric.aggregate(R, systems, atoms, want_log, T, gpa, seed_world, agent.gen, metric_def, seed_lo, seed_hi, max_ticks) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TraceDiverged => unreachable, // freshly-built runs match their own hashes
        };
        return .{ .agg = agg, .runs = try gpa.alloc(Run(R), 0) }; // freeable empty slice (uniform cleanup)
    }
    // .external: capture-once, record-to-revisit
    var agg: Aggregate(T) = .{};
    var runs: std.ArrayList(Run(R)) = .empty;
    errdefer {
        for (runs.items) |*r| r.deinit(gpa);
        runs.deinit(gpa);
    }
    var seed = seed_lo;
    while (seed < seed_hi) : (seed += 1) {
        const w0 = try seed_world(gpa, seed);
        var run = try runmod.buildRun(R, gpa, systems, w0, seed, agent.gen, max_ticks);
        const v = metric.measureRun(R, systems, atoms, want_log, T, gpa, &run, metric_def) catch |e| {
            run.deinit(gpa); // current run not yet in the list — free it
            switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TraceDiverged => unreachable, // a freshly-built run's trace matches its own hashes
            }
        };
        agg.add(v);
        runs.append(gpa, run) catch |e| {
            run.deinit(gpa);
            return e;
        };
    }
    return .{ .agg = agg, .runs = try runs.toOwnedSlice(gpa) };
}

/// Drive `agent` through the VOPR `sweep` over `[seed_lo, seed_hi)` against `oracles`. For a `.replay`
/// agent (from `asAgent(captured_run)`) this minimizes/provenances the captured inputs WITHOUT re-invoking
/// the source. Caller owns the returned reports (deinit each + the list).
pub fn sweepAgent(
    comptime R: type,
    comptime systems: []const Sys(R),
    gpa: Allocator,
    seed_world: *const fn (Allocator, u64) Allocator.Error!worldmod.World(R),
    agent: Agent(R),
    oracles: []const oraclemod.Oracle(R),
    seed_lo: u64,
    seed_hi: u64,
    max_ticks: usize,
) !std.ArrayList(vopr.DefectReport(R)) {
    return vopr.sweep(R, gpa, systems, seed_world, agent.gen, oracles, seed_lo, seed_hi, max_ticks);
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const q2 = @import("../query.zig");
const simctx = @import("../simctx.zig");
const Write = q2.Write;
const system = schedule.system;
const reference = @import("reference.zig");
const external = @import("external.zig");
const agentfns = agentmod;
const ScriptedSpec = @import("../vopr/generator.zig").ScriptedSpec;
const input = @import("../input.zig");
const Command = input.Command;

const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Health});
fn drain(ctx: *simctx.SimCtx(Game), qq: *q2.Query(Game, .{Write(Health)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (qq.next()) |row| row.write(Health).hp -= 1;
}
const game_systems = [_]Sys(Game){system(Game, "drain", drain)};
const dead = atommod.fieldLE(Game, Health, "hp", .{ .index = 0, .generation = 0 }, 0);
const game_atoms = [_]atommod.Atom(Game){dead};

fn seedHp(gpa: Allocator, seed: u64) Allocator.Error!worldmod.World(Game) {
    var w = worldmod.World(Game).init(seed);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Health, .{ .hp = @intCast(2 + seed) }); // hp 2,3,4 -> dead at tick 2,3,4
    return w;
}

test "aggregateAgent over a deterministic (replay/scripted) agent equals a direct metric.aggregate; runs empty" {
    const gpa = testing.allocator;
    // a deterministic_blind scripted agent (idle stream) — reproducible regime
    const empties = [_]input.Input{ .{ .tick = 0, .commands = &.{} }, .{ .tick = 0, .commands = &.{} }, .{ .tick = 0, .commands = &.{} }, .{ .tick = 0, .commands = &.{} } };
    var spec = ScriptedSpec{ .inputs = &empties };
    const a = reference.scriptedAgent(Game, &spec);
    const res = try aggregateAgent(Game, &game_systems, &game_atoms, false, u64, gpa, seedHp, a, metric.timeToCondition(0), 0, 3, 4);
    defer {
        for (res.runs) |*r| r.deinit(gpa);
        gpa.free(res.runs);
    }
    // hp 2,3,4 -> time-to-dead 2,3,4 -> sum 9 (matches a plain metric.aggregate)
    try testing.expectEqual(@as(i128, 9), res.agg.sum);
    try testing.expectEqual(@as(usize, 0), res.runs.len); // reproducible: nothing retained
}

const ObsView = @import("observe.zig").ObsView;

// an impure external player: idle (lets the drain run), but advances an in-ctx counter every call so it is
// NOT a pure function of (seed, tick) — only capture can reproduce it. (The genuine capture-saves-an-
// irreproducible-agent capstone lives in gate.zig; here we exercise the .external eval REGIME.)
const Imp = struct { n: u64 = 0 };
fn impInfer(ctx: *anyopaque, gpa: Allocator, tick: u64, view: ObsView(Game)) Allocator.Error!?input.Input {
    _ = gpa;
    _ = view;
    const s: *Imp = @ptrCast(@alignCast(ctx));
    s.n += 1;
    return input.Input{ .tick = tick, .commands = &.{} };
}

test "aggregateAgent over an external agent captures one Run per seed; each replays bit-identically" {
    const gpa = testing.allocator;
    var imp = Imp{};
    var ea = external.ExternalAgent(Game){ .ctx = &imp, .infer_fn = impInfer };
    const a = external.externalAgent(Game, &ea);
    const res = try aggregateAgent(Game, &game_systems, &game_atoms, false, u64, gpa, seedHp, a, metric.timeToCondition(0), 0, 3, 6);
    defer {
        for (res.runs) |*r| r.deinit(gpa);
        gpa.free(res.runs);
    }
    try testing.expectEqual(@as(usize, 3), res.runs.len); // .external: one captured Run per seed
    try testing.expectEqual(@as(i128, 9), res.agg.sum); // metric: drain kills entity 0 at tick 2,3,4
    // each captured Run replays bit-identically via asAgent (the source is NEVER re-invoked)
    for (res.runs) |*captured| {
        const w0 = try seedHp(gpa, captured.seed);
        var spec: ScriptedSpec = undefined;
        const replay = agentfns.asAgent(Game, captured, &spec);
        var rep = try runmod.buildRun(Game, gpa, &game_systems, w0, captured.seed, replay.gen, captured.inputs.len);
        defer rep.deinit(gpa);
        try testing.expectEqualSlices(u64, captured.hashes, rep.hashes);
    }
}
