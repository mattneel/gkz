//! The Phase-6 cross-build determinism gate (PLAN.md Phase 6, build-order step 10), mirroring
//! query/gate.zig: exact-(tick, witness) catches for the §8 pillars over a fixed fixture, pinned GKZR1
//! digests + a pinned metric across the 3-mode matrix, a checks-on==off hash-invariance sub-gate, a
//! temporal Defect driven through the VOPR sweep→minimize→provenance, and OOM-injection leak-freedom.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Registry = @import("../registry.zig").Registry;
const Entity = @import("../entity.zig").Entity;
const worldmod = @import("../world.zig");
const query = @import("../query.zig");
const simctx = @import("../simctx.zig");
const SimCtx = simctx.SimCtx;
const Write = query.Write;
const Query = query.Query;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const system = schedule.system;
const runmod = @import("../vopr/run.zig");
const generator = @import("../vopr/generator.zig");
const vopr = @import("../vopr/vopr.zig");
const oraclemod = @import("../vopr/oracle.zig");

const atom = @import("atom.zig");
const Atom = atom.Atom;
const invariantmod = @import("invariant.zig");
const checkmod = @import("check.zig");
const tracemod = @import("trace.zig");
const temporal = @import("temporal.zig");
const metricmod = @import("metric.zig");
const relmod = @import("relations.zig");
const defectmod = @import("defect.zig");
const resultmod = @import("../query/result.zig");

// --- fixture registry, events, systems ------------------------------------------------------------

const Boss = struct {
    hp: i32,
    pub const kind_id: u16 = 10;
};
const Score = struct {
    v: i64,
    pub const kind_id: u16 = 11;
};
const Pos = struct {
    x: i64,
    y: i64,
    pub const kind_id: u16 = 12;
};
const G = Registry(.{ Boss, Score, Pos });

const Penalty = struct {
    amount: i64,
    pub const kind_id: u16 = 200;
};
const BossTick = struct {
    pub const kind_id: u16 = 201;
};

// boss drains 1/tick; REVIVES (+10) at tick 5 — so boss_dead flips false at tick 5 (the stable breach).
// Emits BossTick each tick so provenance has a real anchor at the failing tick.
fn bossRevive(ctx: *SimCtx(G), q: *Query(G, .{Write(Boss)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| {
        const b = row.write(Boss);
        if (ctx.tick == 5) b.hp += 10 else b.hp -= 1;
        _ = try ctx.emitS(BossTick, row.entity(), .{});
    }
}
// boss just drains — stays dead once dead (stable holds); also the hp>=0 invariant fixture.
fn bossDrain(ctx: *SimCtx(G), q: *Query(G, .{Write(Boss)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Boss).hp -= 1;
}
// score rises, but DROPS at tick 3 with NO Penalty event -> monotonic_unless breach at tick 3.
fn scoreDropBad(ctx: *SimCtx(G), q: *Query(G, .{Write(Score)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| {
        const s = row.write(Score);
        if (ctx.tick == 3) s.v -= 5 else s.v += 1;
    }
}
// score drops at tick 3 but EMITS a Penalty there -> monotonic_unless is satisfied (the exception).
fn scoreDropOk(ctx: *SimCtx(G), q: *Query(G, .{Write(Score)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| {
        const s = row.write(Score);
        if (ctx.tick == 3) {
            s.v -= 5;
            _ = try ctx.emitS(Penalty, row.entity(), .{ .amount = 5 });
        } else s.v += 1;
    }
}

const revive_sys = [_]Sys(G){system(G, "bossRevive", bossRevive)};
const drain_sys = [_]Sys(G){system(G, "bossDrain", bossDrain)};
const score_bad_sys = [_]Sys(G){system(G, "scoreDropBad", scoreDropBad)};
const score_ok_sys = [_]Sys(G){system(G, "scoreDropOk", scoreDropOk)};

// --- atoms / properties / invariants --------------------------------------------------------------

const BOSS: Entity = .{ .index = 0, .generation = 0 };
const SCOREE: Entity = .{ .index = 0, .generation = 0 };
const boss_dead = atom.fieldLE(G, Boss, "hp", BOSS, 0);
const score_val = atom.scalarField(G, Score, "v", SCOREE);
const boss_atoms = [_]Atom(G){boss_dead};
const score_atoms = [_]Atom(G){score_val};

const hp_inv = invariantmod.fromAtom(G, atom.rangeI(G, Boss, "hp", 0, 1_000_000));
const stable_boss = temporal.Property{ .name = "boss_stays_dead", .comb = .stable, .p = 0 };
const score_monotone = temporal.Property{ .name = "score_monotone", .comb = .monotonic_unless, .p = 0, .event_kind = Penalty.kind_id };

// --- fixture run builders -------------------------------------------------------------------------

// NOTE: the construction errdefer is scoped to a `blk` that ENDS before `buildRun` — `buildRun` consumes
// the world (freeing it on its own OOM), so a lingering errdefer here would double-free (the same trap
// fixed in query/gate.zig's buildForks).
fn bossRun(gpa: Allocator, comptime systems: []const Sys(G), hp: i32, ticks: usize) !runmod.Run(G) {
    const w0 = blk: {
        var w = worldmod.World(G).init(0);
        errdefer w.deinit(gpa);
        const e = try w.spawn(gpa);
        w.add(e, Boss, .{ .hp = hp });
        break :blk w;
    };
    return runmod.buildRun(G, gpa, systems, w0, 0, generator.idleGen(G), ticks);
}
fn scoreRun(gpa: Allocator, comptime systems: []const Sys(G)) !runmod.Run(G) {
    const w0 = blk: {
        var w = worldmod.World(G).init(0);
        errdefer w.deinit(gpa);
        const e = try w.spawn(gpa);
        w.add(e, Score, .{ .v = 10 });
        break :blk w;
    };
    return runmod.buildRun(G, gpa, systems, w0, 0, generator.idleGen(G), 5);
}

// --- pinned digests (filled from the first green run; asserted identical across the 3-mode matrix) --

pub const VIOLATION_DIGEST: u64 = 0x954f5b6fffe16676;
pub const SPEC_DIGEST: u64 = 0x0c4e674a455559f6;
pub const METRIC_TTC: u64 = 2; // time-to-boss-dead for hp=2 (t2: 2->1->0)
pub const METRIC_SUM: i128 = 9; // aggregate sum over hp 2,3,4 -> ttc 2,3,4

const declared_specs = [_]relmod.DeclaredSpec{
    .{ .category = .invariant, .name = "boss_hp>=0" },
    .{ .category = .temporal, .name = "boss_stays_dead" },
    .{ .category = .temporal, .name = "score_monotone" },
    .{ .category = .metric, .name = "time_to_clear" },
};

/// The canonical caught findings (used for the pinned violation-relation digest).
fn caughtFindings(gpa: Allocator) ![]defectmod.Finding(G) {
    var list: std.ArrayList(defectmod.Finding(G)) = .empty;
    errdefer list.deinit(gpa);

    // invariant hp>=0 over a drain run: hp 2 -> t1=1,t2=0,t3=-1 : caught at tick 3
    var dr = try bossRun(gpa, &drain_sys, 2, 4);
    defer dr.deinit(gpa);
    const inv_d = (try invariantmod.invariantOracle(G, &drain_sys, hp_inv).eval(&dr, gpa)).?;
    try list.append(gpa, defectmod.fromDefect(G, inv_d));

    // stable(boss_dead) over a revive run: caught at the revive tick 5
    var rr = try bossRun(gpa, &revive_sys, 2, 6);
    defer rr.deinit(gpa);
    const st_d = (try temporal.temporalOracle(G, &revive_sys, "boss_stays_dead", stable_boss, &boss_atoms).eval(&rr, gpa)).?;
    try list.append(gpa, defectmod.fromDefect(G, st_d));

    // monotonic_unless(score, Penalty) over a no-penalty drop run: caught at tick 3
    var sr = try scoreRun(gpa, &score_bad_sys);
    defer sr.deinit(gpa);
    const mo_d = (try temporal.temporalOracle(G, &score_bad_sys, "score_monotone", score_monotone, &score_atoms).eval(&sr, gpa)).?;
    try list.append(gpa, defectmod.fromDefect(G, mo_d));

    return list.toOwnedSlice(gpa);
}

// --- the gate -------------------------------------------------------------------------------------

test "EXACT-CATCH: invariant hp>=0 caught at the exact tick; a healthy boss is clean" {
    const gpa = testing.allocator;
    var bad = try bossRun(gpa, &drain_sys, 2, 4);
    defer bad.deinit(gpa);
    const d = (try invariantmod.invariantOracle(G, &drain_sys, hp_inv).eval(&bad, gpa)).?;
    try testing.expectEqual(oraclemod.Defect(G).Kind.invariant, d.kind);
    try testing.expectEqual(@as(u64, 3), d.tick); // hp -1 first at tick 3
    var ok = try bossRun(gpa, &drain_sys, 100, 4);
    defer ok.deinit(gpa);
    try testing.expectEqual(@as(?oraclemod.Defect(G), null), try invariantmod.invariantOracle(G, &drain_sys, hp_inv).eval(&ok, gpa));
}

test "EXACT-CATCH: stable(boss stays dead) caught at the revive tick; a boss that stays dead is clean" {
    const gpa = testing.allocator;
    var rr = try bossRun(gpa, &revive_sys, 2, 6);
    defer rr.deinit(gpa);
    const d = (try temporal.temporalOracle(G, &revive_sys, "boss_stays_dead", stable_boss, &boss_atoms).eval(&rr, gpa)).?;
    try testing.expectEqual(oraclemod.Defect(G).Kind.temporal, d.kind);
    try testing.expectEqual(@as(u64, 5), d.tick); // boss revives at tick 5
    try testing.expectEqual(BOSS.index, d.detail.entity.index);
    var ok = try bossRun(gpa, &drain_sys, 2, 6); // never revives
    defer ok.deinit(gpa);
    try testing.expectEqual(@as(?oraclemod.Defect(G), null), try temporal.temporalOracle(G, &drain_sys, "x", stable_boss, &boss_atoms).eval(&ok, gpa));
}

test "EXACT-CATCH: monotonic_unless(score, Penalty) caught on a no-penalty drop; a penalty-covered drop is clean" {
    const gpa = testing.allocator;
    var bad = try scoreRun(gpa, &score_bad_sys);
    defer bad.deinit(gpa);
    const d = (try temporal.temporalOracle(G, &score_bad_sys, "score_monotone", score_monotone, &score_atoms).eval(&bad, gpa)).?;
    try testing.expectEqual(oraclemod.Defect(G).Kind.temporal, d.kind);
    try testing.expectEqual(@as(u64, 3), d.tick); // score drops at tick 3 with no Penalty
    var ok = try scoreRun(gpa, &score_ok_sys); // drops at 3 but emits Penalty
    defer ok.deinit(gpa);
    try testing.expectEqual(@as(?oraclemod.Defect(G), null), try temporal.temporalOracle(G, &score_ok_sys, "x", score_monotone, &score_atoms).eval(&ok, gpa));
}

test "EXACT-CATCH: noOverlap pins BOTH overlapping entities (the multi-entity §8 witness)" {
    const gpa = testing.allocator;
    var w = worldmod.World(G).init(0);
    defer w.deinit(gpa);
    const a = try w.spawn(gpa);
    const b = try w.spawn(gpa);
    w.add(a, Pos, .{ .x = 1, .y = 1 });
    w.add(b, Pos, .{ .x = 1, .y = 1 }); // overlap
    const hit = atom.noOverlap(G, Pos, "x", "y").eval(&w);
    try testing.expect(!hit.holds);
    try testing.expectEqual(@as(u8, 2), hit.witness.n);
}

test "PINNED: violation/spec digests + metric are byte-identical across build modes" {
    const gpa = testing.allocator;
    const findings = try caughtFindings(gpa);
    defer gpa.free(findings);
    var vr = try relmod.violationRel(G, gpa, findings);
    defer vr.deinit(gpa);
    try testing.expectEqual(VIOLATION_DIGEST, (try resultmod.resultDigest(gpa, &vr)).hash);

    var sr = try relmod.specRel(gpa, &declared_specs);
    defer sr.deinit(gpa);
    try testing.expectEqual(SPEC_DIGEST, (try resultmod.resultDigest(gpa, &sr)).hash);

    // time-to-clear (boss_dead) over a drain run hp=2 -> tick 2
    var dr = try bossRun(gpa, &drain_sys, 2, 8);
    defer dr.deinit(gpa);
    const ttc = try metricmod.measureRun(G, &drain_sys, &boss_atoms, false, u64, gpa, &dr, metricmod.timeToCondition(0));
    try testing.expectEqual(METRIC_TTC, ttc);

    // aggregate over hp 2,3,4 -> ttc 2,3,4 -> sum 9
    const agg = try metricmod.aggregate(G, &drain_sys, &boss_atoms, false, u64, gpa, seedBoss, generator.idleGen(G), metricmod.timeToCondition(0), 0, 3, 10);
    try testing.expectEqual(METRIC_SUM, agg.sum);
}

fn seedBoss(gpa: Allocator, seed: u64) Allocator.Error!worldmod.World(G) {
    var w = worldmod.World(G).init(seed);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Boss, .{ .hp = @intCast(2 + seed) }); // hp 2,3,4 -> dead at tick 2,3,4
    return w;
}

test "HASH-INVARIANCE: checkAll is a pure observation — reconstructed tick hashes are unchanged by it" {
    const gpa = testing.allocator;
    var dr = try bossRun(gpa, &drain_sys, 100, 5); // hp stays >= 0 (the invariant HOLDS — no panic)
    defer dr.deinit(gpa);
    const invs = [_]invariantmod.Invariant(G){hp_inv};
    var t: usize = 1;
    while (t <= dr.inputs.len) : (t += 1) {
        var w = try dr.worldAt(gpa, &drain_sys, t);
        defer w.deinit(gpa);
        checkmod.checkAll(G, &invs, &w); // borrow-only pure observation: must not perturb the World
        try testing.expectEqual(dr.hashes[t - 1], (try w.digest(gpa)).hash);
    }
}

test "VOPR-FLOW: a temporal violation rides sweep -> minimize -> provenance" {
    const gpa = testing.allocator;
    const orc = temporal.temporalOracle(G, &revive_sys, "boss_stays_dead", stable_boss, &boss_atoms);
    const oracles = [_]oraclemod.Oracle(G){orc};
    var reports = try vopr.sweep(G, gpa, &revive_sys, seedBossRevive, generator.idleGen(G), &oracles, 0, 1, 6);
    defer {
        for (reports.items) |*r| r.deinit(gpa);
        reports.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 1), reports.items.len);
    try testing.expectEqual(oraclemod.Defect(G).Kind.temporal, reports.items[0].defect.kind);
    try testing.expectEqual(@as(u64, 5), reports.items[0].defect.tick); // bisected to the revive tick
    // minimization actually ran: the 6-tick run shrinks to the 5 ticks the revive (tick==5) needs
    try testing.expect(reports.items[0].min.inputs.len < 6);
    try testing.expectEqual(@as(usize, 5), reports.items[0].min.inputs.len);
    try testing.expect(reports.items[0].cause_chain.len > 0); // provenance anchored at a real BossTick event
}

fn seedBossRevive(gpa: Allocator, seed: u64) Allocator.Error!worldmod.World(G) {
    var w = worldmod.World(G).init(seed);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Boss, .{ .hp = 2 });
    return w;
}

fn specBatteryOnce(gpa: Allocator) !void {
    const findings = try caughtFindings(gpa);
    defer gpa.free(findings);
    var vr = try relmod.violationRel(G, gpa, findings);
    vr.deinit(gpa);
    var sr = try relmod.specRel(gpa, &declared_specs);
    sr.deinit(gpa);
}

test "OOM-injection: the spec relation + trace/temporal battery is leak-free under allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, specBatteryOnce, .{});
}
