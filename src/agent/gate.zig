//! The Phase-7 cross-build determinism gate + frozen pinned artifact (PLAN.md Phase 7, §10), run under
//! the existing Debug/ReleaseSafe/ReleaseFast matrix. Sub-gates: (a) a deterministic greedy sweep is
//! bit-reproducible; (b) THE CAPSTONE — an agent genuinely irreproducible at the boundary is captured
//! once and replays bit-identically from Run.inputs WITHOUT re-invoking it; (c) the captured run is
//! VOPR-debuggable; (d) observation is read-only; (e) intent-metrics aggregate over agent runs; (f) a
//! sharded sweep equals a single-process one; (g) OOM-injection leak-freedom.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Registry = @import("../registry.zig").Registry;
const Entity = @import("../entity.zig").Entity;
const worldmod = @import("../world.zig");
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const system = schedule.system;
const q2 = @import("../query.zig");
const simctx = @import("../simctx.zig");
const Write = q2.Write;
const Query = q2.Query;
const runmod = @import("../vopr/run.zig");
const oraclemod = @import("../vopr/oracle.zig");
const input = @import("../input.zig");
const Command = input.Command;
const generator = @import("../vopr/generator.zig");
const ScriptedSpec = generator.ScriptedSpec;

const agent = @import("agent.zig");
const observe = @import("observe.zig");
const ObsView = observe.ObsView;
const reference = @import("reference.zig");
const external = @import("external.zig");
const evalmod = @import("eval.zig");
const shard = @import("shard.zig");
const atommod = @import("../spec/atom.zig");
const invariantmod = @import("../spec/invariant.zig");
const metric = @import("../spec/metric.zig");

// --- fixture: a drain-and-emit system over Health ------------------------------------------------

const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 1;
};
const Marker = struct {
    pub const kind_id: u16 = 50;
};
const G = Registry(.{Health});

// drains every Health entity -1/tick AND emits a Marker (so provenance has a real anchor; events are
// hash-invariant so this never perturbs the World).
fn drainEmit(ctx: *simctx.SimCtx(G), qq: *Query(G, .{Write(Health)})) std.mem.Allocator.Error!void {
    while (qq.next()) |row| {
        row.write(Health).hp -= 1;
        _ = try ctx.emitS(Marker, row.entity(), .{});
    }
}
const gsys = [_]Sys(G){system(G, "drainEmit", drainEmit)};

const dead = atommod.fieldLE(G, Health, "hp", .{ .index = 0, .generation = 0 }, 0);
const g_atoms = [_]atommod.Atom(G){dead};
const hp_inv = invariantmod.fromAtom(G, atommod.rangeI(G, Health, "hp", 0, 1_000_000));

fn seedHp(gpa: Allocator, seed: u64) Allocator.Error!worldmod.World(G) {
    var w = worldmod.World(G).init(seed);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Health, .{ .hp = @intCast(3 + seed) }); // idle-drains dead at tick 3+seed
    return w;
}

const greedy = reference.greedyAgent(G, .{ .spawn_verb = 1, .despawn_verb = 2, .max_entities = 3 });

// --- pinned artifact (filled from the first green run; asserted identical across the 3-mode matrix) --

pub const AGENT_GATE = struct {
    pub const GREEDY_STREAM_FOLD: u64 = 17955964333554436617;
    pub const GREEDY_SWEEP_SUM: i128 = 36;
    pub const CAPSTONE_STREAM_DIGEST: u64 = 12596015066932244834;
    pub const CAPSTONE_FINAL: u64 = 13021412458969304696;
    pub const AGENT_METRIC_SUM: i128 = 12;
};

/// Fold each seed's greedy-run stream digest (XOR) — a deterministic fingerprint of the whole sweep.
fn greedyStreamFold(gpa: Allocator, lo: u64, hi: u64) !u64 {
    var acc: u64 = 0;
    var seed = lo;
    while (seed < hi) : (seed += 1) {
        const w0 = try seedHp(gpa, seed); // clean world; buildRun consumes it (no errdefer here)
        var run = try runmod.buildRun(G, gpa, &gsys, w0, seed, greedy.gen, 8);
        defer run.deinit(gpa);
        acc ^= runmod.streamDigest(run.hashes);
    }
    return acc;
}

test "(a) a deterministic greedy sweep is bit-reproducible (re-derivable from the seed range)" {
    const gpa = testing.allocator;
    const f1 = try greedyStreamFold(gpa, 0, 4);
    const f2 = try greedyStreamFold(gpa, 0, 4);
    try testing.expectEqual(f1, f2); // run twice -> identical (pure in seed,tick,view)
    try testing.expectEqual(AGENT_GATE.GREEDY_STREAM_FOLD, f1); // pinned across the 3-mode matrix

    const res = try evalmod.aggregateAgent(G, &gsys, &g_atoms, false, u64, gpa, seedHp, greedy, metric.timeToCondition(0), 0, 4, 8);
    defer {
        for (res.runs) |*r| r.deinit(gpa);
        gpa.free(res.runs);
    }
    try testing.expectEqual(AGENT_GATE.GREEDY_SWEEP_SUM, res.agg.sum);
    try testing.expectEqual(@as(usize, 0), res.runs.len); // reproducible regime retains nothing
}

// --- the capstone: a genuinely irreproducible external agent, captured then replayed ----------------

// output depends on a MUTABLE in-ctx counter (stands in for INT8/GPU reduction-order nonreproducibility):
// spawn a bare entity on counter%3!=0, else idle. NOT a function of (seed,tick). `invoked` counts calls.
const Impure = struct { counter: u64 = 0, invoked: u64 = 0 };
fn impureInfer(ctx: *anyopaque, gpa: Allocator, tick: u64, view: ObsView(G)) Allocator.Error!?input.Input {
    _ = view;
    const s: *Impure = @ptrCast(@alignCast(ctx));
    s.invoked += 1;
    const spawn = (s.counter % 3) != 0;
    s.counter += 1;
    if (!spawn) return input.Input{ .tick = tick, .commands = &.{} };
    const cmds = try gpa.alloc(Command, 1);
    cmds[0] = .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 };
    return input.Input{ .tick = tick, .commands = cmds };
}

test "(b) CAPSTONE: an irreproducible external agent is captured once and replays bit-identically without re-invoking it" {
    const gpa = testing.allocator;
    var imp = Impure{};
    var ea = external.ExternalAgent(G){ .ctx = &imp, .infer_fn = impureInfer };
    const ext = external.externalAgent(G, &ea);

    // GUARD: two DIRECT buildRuns of the same external agent DIFFER (the counter persists) — so a
    // bit-identical replay can ONLY come from captured inputs, never from re-deriving the agent.
    // (5 ticks is deliberately COPRIME to impureInfer's counter%3 period, so the two runs' spawn patterns
    //  cannot accidentally coincide — a multiple-of-3 tick count would make the guard a false pass.)
    {
        var g1 = try runmod.buildRun(G, gpa, &gsys, try seedHp(gpa, 0), 0, ext.gen, 5);
        defer g1.deinit(gpa);
        var g2 = try runmod.buildRun(G, gpa, &gsys, try seedHp(gpa, 0), 0, ext.gen, 5);
        defer g2.deinit(gpa);
        try testing.expect(!std.mem.eql(u64, g1.hashes, g2.hashes));
    }

    // CAPTURE once (reset the counter so the capture is independent of the guard + pinnable).
    imp = .{};
    var cap = try runmod.buildRun(G, gpa, &gsys, try seedHp(gpa, 0), 0, ext.gen, 5);
    defer cap.deinit(gpa);
    const invoked_after_capture = imp.invoked;
    try testing.expectEqual(@as(u64, 5), invoked_after_capture); // 5 ticks -> 5 infer calls

    // REPLAY from the captured inputs WITHOUT re-invoking the agent (asAgent -> scriptedGen).
    var spec: ScriptedSpec = undefined;
    const replay = agent.asAgent(G, &cap, &spec);
    var rep = try runmod.buildRun(G, gpa, &gsys, try seedHp(gpa, 0), 0, replay.gen, cap.inputs.len);
    defer rep.deinit(gpa);
    var rep3 = try runmod.buildRun(G, gpa, &gsys, try seedHp(gpa, 0), 0, replay.gen, cap.inputs.len);
    defer rep3.deinit(gpa);

    try testing.expectEqualSlices(u64, cap.hashes, rep.hashes); // bit-identical replay
    try testing.expectEqualSlices(u64, cap.hashes, rep3.hashes);
    try testing.expectEqual(invoked_after_capture, imp.invoked); // infer_fn NOT called during replay
    try testing.expectEqual(AGENT_GATE.CAPSTONE_STREAM_DIGEST, runmod.streamDigest(cap.hashes));
    try testing.expectEqual(AGENT_GATE.CAPSTONE_FINAL, (try cap.final.digest(gpa)).hash);
}

test "(c) a captured external run is VOPR-debuggable: sweepAgent->minimize->provenance on the replay agent" {
    const gpa = testing.allocator;
    var imp = Impure{};
    var ea = external.ExternalAgent(G){ .ctx = &imp, .infer_fn = impureInfer };
    const ext = external.externalAgent(G, &ea);
    // entity 0 (hp 3) idle/drain reaches hp<0 -> the hp>=0 invariant trips within the captured run
    var cap = try runmod.buildRun(G, gpa, &gsys, try seedHp(gpa, 0), 0, ext.gen, 8);
    defer cap.deinit(gpa);

    var spec: ScriptedSpec = undefined;
    const replay = agent.asAgent(G, &cap, &spec);
    const oracles = [_]oraclemod.Oracle(G){invariantmod.invariantOracle(G, &gsys, hp_inv)};
    var reports = try evalmod.sweepAgent(G, &gsys, gpa, seedHp, replay, &oracles, 0, 1, cap.inputs.len);
    defer {
        for (reports.items) |*r| r.deinit(gpa);
        reports.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 1), reports.items.len);
    try testing.expectEqual(oraclemod.Defect(G).Kind.invariant, reports.items[0].defect.kind);
    // minimization actually ran: the 8-tick captured run shrinks (hp<0 trips at tick 4, post-violation
    // ticks are droppable) — strict `<` proves the captured run was REDUCED, not merely re-checked.
    try testing.expect(reports.items[0].min.inputs.len < cap.inputs.len);
    try testing.expect(reports.items[0].cause_chain.len > 0); // provenance anchored at a real Marker event
}

test "(d) observation is read-only: the accessor surface is const-correct AND observing does not mutate" {
    const gpa = testing.allocator;
    // STRUCTURAL: through a *const World (what ObsView holds), the read accessors yield const slices, and
    // the mutable `column` requires *Self — so a write through the observation surface does not compile.
    // (This is the real player-not-world enforcement the (d) gate must assert, not the prior tautology.)
    const T = worldmod.World(G).TableType;
    try testing.expectEqual([]const Entity, @TypeOf(@as(*const T, undefined).owners()));
    try testing.expectEqual([]const G.Mask, @TypeOf(@as(*const T, undefined).masks()));
    try testing.expectEqual([]const Health, @TypeOf(@as(*const T, undefined).columnConst(0)));
    try testing.expectEqual(@as(usize, 1), @typeInfo(ObsView(G)).@"struct".fields.len);
    // EMPIRICAL: observing through the ObsView surface does not perturb the World hash.
    var w = worldmod.World(G).init(0);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Health, .{ .hp = 5 });
    const before = try w.digest(gpa);
    const ov = ObsView(G).init(&w);
    _ = ov.world().table.rowCount();
    _ = ov.engine(&gsys);
    try testing.expectEqual(before.hash, (try w.digest(gpa)).hash); // unchanged
}

test "(e) intent-metrics aggregate over agent-driven runs (a scripted-idle batch)" {
    const gpa = testing.allocator;
    const empties = [_]input.Input{.{ .tick = 0, .commands = &.{} }} ** 8;
    var spec = ScriptedSpec{ .inputs = &empties };
    const scripted = reference.scriptedAgent(G, &spec);
    const res = try evalmod.aggregateAgent(G, &gsys, &g_atoms, false, u64, gpa, seedHp, scripted, metric.timeToCondition(0), 0, 3, 8);
    defer {
        for (res.runs) |*r| r.deinit(gpa);
        gpa.free(res.runs);
    }
    // idle: entity 0 drains; hp 3,4,5 -> dead at tick 3,4,5 -> sum 12
    try testing.expectEqual(AGENT_GATE.AGENT_METRIC_SUM, res.agg.sum);
}

test "(f) a sharded greedy sweep equals the single-process Aggregate field-for-field" {
    const gpa = testing.allocator;
    const M = metric.timeToCondition(0);
    const whole = try evalmod.aggregateAgent(G, &gsys, &g_atoms, false, u64, gpa, seedHp, greedy, M, 0, 6, 8);
    defer gpa.free(whole.runs);
    // 3-way shard of [0,6) merged
    var parts: [3]metric.Aggregate(u64) = undefined;
    inline for (0..3) |i| {
        const sr = shard.shardRanges(0, 6, 3, i);
        const p = try evalmod.aggregateAgent(G, &gsys, &g_atoms, false, u64, gpa, seedHp, greedy, M, sr.lo, sr.hi, 8);
        defer gpa.free(p.runs);
        parts[i] = p.agg;
    }
    const merged = shard.mergeAggregates(u64, &parts);
    try testing.expectEqual(whole.agg.count, merged.count);
    try testing.expectEqual(whole.agg.min, merged.min);
    try testing.expectEqual(whole.agg.max, merged.max);
    try testing.expectEqual(whole.agg.sum, merged.sum);
}

fn oomCycle(gpa: Allocator) !void {
    // deterministic-regime aggregate (delegates to metric.aggregate; empty runs slice)
    {
        const res = try evalmod.aggregateAgent(G, &gsys, &g_atoms, false, u64, gpa, seedHp, greedy, metric.timeToCondition(0), 0, 2, 5);
        for (res.runs) |*r| r.deinit(gpa);
        gpa.free(res.runs);
    }
    // .external-regime aggregate (the ownership-complex path: the accumulating []Run errdefer + per-run
    // free on measure/append failure — multi-seed so the loop actually accumulates)
    {
        var imp = Impure{};
        var ea = external.ExternalAgent(G){ .ctx = &imp, .infer_fn = impureInfer };
        const ext = external.externalAgent(G, &ea);
        const res = try evalmod.aggregateAgent(G, &gsys, &g_atoms, false, u64, gpa, seedHp, ext, metric.timeToCondition(0), 0, 2, 4);
        for (res.runs) |*r| r.deinit(gpa);
        gpa.free(res.runs);
    }
    // capture-then-replay (asAgent / scriptedGen)
    {
        var imp = Impure{};
        var ea = external.ExternalAgent(G){ .ctx = &imp, .infer_fn = impureInfer };
        const ext = external.externalAgent(G, &ea);
        var cap = try runmod.buildRun(G, gpa, &gsys, try seedHp(gpa, 0), 0, ext.gen, 4);
        defer cap.deinit(gpa);
        var spec: ScriptedSpec = undefined;
        const replay = agent.asAgent(G, &cap, &spec);
        var rep = try runmod.buildRun(G, gpa, &gsys, try seedHp(gpa, 0), 0, replay.gen, cap.inputs.len);
        rep.deinit(gpa);
    }
}

test "(g) OOM-injection: the aggregate + capture-then-replay cycle is leak/double-free free" {
    try testing.checkAllAllocationFailures(testing.allocator, oomCycle, .{});
}
