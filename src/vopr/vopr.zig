//! The VOPR sweep — the fuzzer and the debugger in one machine (SPEC §9). Build-order steps 7 + 8.
//!
//! `sweep` runs each seed in a range: build the per-seed `Run`, evaluate every registered `Oracle`,
//! and on the first `Defect` per seed, delta-debug-minimize the input and re-run the minimized case
//! with a `Recorder` on to attach the cause chain. A defect's location is `(seed, tick)`; minimization
//! and provenance use the SAME (seed, inputs) — the §9 payoff. `sweep` is a PURE function of its
//! arguments and the seed range, so §13 multi-process sharding is `for shard: sweep(sub_range)`.

const std = @import("std");
const runmod = @import("run.zig");
const oraclemod = @import("oracle.zig");
const minimizemod = @import("minimize.zig");
const generator = @import("generator.zig");
const recorder = @import("../recorder.zig");
const event = @import("../event.zig");
const snapshotmod = @import("../snapshot.zig");
const stepmod = @import("../step.zig");
const schedule = @import("../schedule.zig");
const worldmod = @import("../world.zig");
const input = @import("../input.zig");
const Sys = schedule.Sys;
const Oracle = oraclemod.Oracle;
const Defect = oraclemod.Defect;
const Allocator = std.mem.Allocator;

pub fn DefectReport(comptime R: type) type {
    return struct {
        defect: Defect(R),
        min: minimizemod.Minimized,
        cause_chain: []event.EventId,
        pub fn deinit(self: *@This(), gpa: Allocator) void {
            self.min.deinit();
            gpa.free(self.cause_chain);
            self.* = undefined;
        }
    };
}

/// Re-run the minimized `(seed, inputs)` with a Recorder ON and return the cause chain anchored at a
/// real (non-synthetic) event at `fail_tick` — the provenance payoff. Empty if nothing was emitted
/// there. Caller frees. Note: for a DIVERGENCE the chain contextualizes the failing tick (what was
/// emitted there) but does not — and structurally cannot, without the §7 component diff — single out
/// THE racing write; for an invariant/trap it anchors at the tick the property flipped.
fn provenanceRerun(
    comptime R: type,
    gpa: Allocator,
    comptime systems: []const Sys(R),
    base: snapshotmod.Snapshot,
    min_inputs: []const input.Input,
    fail_tick: u64,
) ![]event.EventId {
    var rec = recorder.Recorder.init(gpa);
    defer rec.deinit();
    const exec = comptime &schedule.Schedule(R, systems).exec_order;
    var w = snapshotmod.restore(R, gpa, base) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    defer w.deinit(gpa); // deinit the (final) world exactly once at exit — covers loop OOM AND a later
    // causeChain OOM without a double-free (an explicit deinit + errdefer would double-free here).
    for (min_inputs) |in| {
        const nxt = try stepmod.stepExec(R, gpa, w, in, systems, exec, &rec);
        w.deinit(gpa);
        w = nxt;
    }
    // anchor at the first real system event (not a synthetic SystemCause/Input node) at fail_tick
    for (rec.log.events.items) |e| {
        if (e.id.tick == fail_tick and e.emitter != event.RESERVED_SYSACT and e.emitter != event.RESERVED_INPUT) {
            return rec.log.causeChain(gpa, e.id);
        }
    }
    return gpa.alloc(event.EventId, 0);
}

/// Re-evaluate `oracle` against a freshly-built Run over `min_inputs` (same seed/systems), to obtain
/// the defect as it stands AFTER minimization (its tick may have moved earlier under tick renumbering).
fn reeval(
    comptime R: type,
    gpa: Allocator,
    comptime systems: []const Sys(R),
    base: snapshotmod.Snapshot,
    seed: u64,
    oracle: Oracle(R),
    min_inputs: []const input.Input,
) !?Defect(R) {
    const w0 = snapshotmod.restore(R, gpa, base) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    var spec = generator.ScriptedSpec{ .inputs = min_inputs };
    const gen = generator.scriptedGen(R, &spec);
    var run = try runmod.buildRun(R, gpa, systems, w0, seed, gen, min_inputs.len);
    defer run.deinit(gpa);
    return oracle.eval(&run, gpa);
}

/// Sweep seeds `[seed_lo, seed_hi)`. For each: seed the World, run the generator's stream, evaluate the
/// oracles; the first defect is minimized + provenance-attached into a `DefectReport`. Caller deinits
/// each report and frees the slice.
pub fn sweep(
    comptime R: type,
    gpa: Allocator,
    comptime systems: []const Sys(R),
    seed_world: *const fn (Allocator, u64) Allocator.Error!worldmod.World(R),
    gen: generator.Generator(R),
    oracles: []const Oracle(R),
    seed_lo: u64,
    seed_hi: u64,
    max_ticks: usize,
) !std.ArrayList(DefectReport(R)) {
    var reports: std.ArrayList(DefectReport(R)) = .empty;
    errdefer {
        for (reports.items) |*r| r.deinit(gpa);
        reports.deinit(gpa);
    }
    var seed = seed_lo;
    while (seed < seed_hi) : (seed += 1) {
        const w0 = try seed_world(gpa, seed);
        var run = try runmod.buildRun(R, gpa, systems, w0, seed, gen, max_ticks);
        defer run.deinit(gpa);

        for (oracles) |orc| {
            if (try orc.eval(&run, gpa)) |d| {
                var min = try minimizemod.minimize(R, gpa, systems, run.base, seed, orc, d.kind, run.inputs);
                errdefer min.deinit();
                // Minimization renumbers ticks (dropping leading ticks moves the failing tick EARLIER),
                // so re-evaluate on the minimized stream to get the CURRENT defect + tick before
                // anchoring provenance — otherwise the cause chain anchors at a stale tick. (Review HIGH.)
                const d_min = (try reeval(R, gpa, systems, run.base, seed, orc, min.inputs)) orelse d;
                const chain = try provenanceRerun(R, gpa, systems, run.base, min.inputs, d_min.tick);
                errdefer gpa.free(chain);
                try reports.append(gpa, .{ .defect = d_min, .min = min, .cause_chain = chain });
                break; // first defect per seed
            }
        }
    }
    return reports;
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("../registry.zig").Registry;
const query = @import("../query.zig");
const simctx = @import("../simctx.zig");
const inject = @import("inject.zig");
const Read = query.Read;
const Write = query.Write;
const Query = query.Query;
const SimCtx = simctx.SimCtx;
const system = schedule.system;
const Injection = inject.Injection;

const Position = struct {
    x: fpz.Fixed,
    pub const kind_id: u16 = 1;
};
const Velocity = struct {
    dx: fpz.Fixed,
    pub const kind_id: u16 = 2;
};
const Marker = struct {
    pub const kind_id: u16 = 100;
};
const CReg = Registry(.{ Position, Velocity });
const CW = worldmod.World(CReg);

// LEAKY: both declare only Read(Position) (so the conflict checker co-stages them as "order-free"), but
// each reaches AROUND its declared access via q.table.get to write Velocity in place. The undeclared
// write races: within-stage execution order now decides Velocity, so a permutation diverges.
fn leakyA(ctx: *SimCtx(CReg), q: *Query(CReg, .{Read(Position)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| {
        const e = row.entity();
        q.table.get(e, Velocity).?.dx = fpz.Fixed.fromInt(1); // UNDECLARED in-place write
        _ = try ctx.emitS(Marker, e, .{}); // emit so provenance has something to anchor
    }
}
fn leakyB(ctx: *SimCtx(CReg), q: *Query(CReg, .{Read(Position)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| q.table.get(row.entity(), Velocity).?.dx = fpz.Fixed.fromInt(2); // UNDECLARED
}
const leaky_systems = [_]Sys(CReg){ system(CReg, "leakyA", leakyA), system(CReg, "leakyB", leakyB) };

// CLEAN twin: both correctly DECLARE Write(Velocity), so the checker conflicts them into separate
// stages with a fixed order — no race, no divergence.
fn cleanA(ctx: *SimCtx(CReg), q: *Query(CReg, .{Write(Velocity)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| {
        row.write(Velocity).dx = fpz.Fixed.fromInt(1);
        _ = try ctx.emitS(Marker, row.entity(), .{});
    }
}
fn cleanB(ctx: *SimCtx(CReg), q: *Query(CReg, .{Write(Velocity)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Velocity).dx = fpz.Fixed.fromInt(2);
}
const clean_systems = [_]Sys(CReg){ system(CReg, "cleanA", cleanA), system(CReg, "cleanB", cleanB) };

fn seedC(gpa: Allocator, seed: u64) Allocator.Error!CW {
    var w = CW.init(seed);
    errdefer w.deinit(gpa);
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const e = try w.spawn(gpa);
        w.add(e, Position, .{ .x = fpz.Fixed.fromInt(@intCast(i)) });
        w.add(e, Velocity, .{ .dx = fpz.Fixed.ZERO });
    }
    return w;
}

test "CAPSTONE: a leaky (undeclared-write) system is caught, bisected, minimized, and provenance-attached" {
    const gpa = testing.allocator;

    // perm_index 1 rotates the 2-member leaky stage by 1 (a guaranteed swap — execPermutation is now
    // deterministic rotation, so no hand-search for a swapping index is needed).
    var inj = Injection{ .exec_perm = 1 };
    const oracles = [_]Oracle(CReg){oraclemod.divergence(CReg, &leaky_systems, "exec-swap", &inj)};

    var reports = try sweep(CReg, gpa, &leaky_systems, &seedC, generator.idleGen(CReg), &oracles, 0, 1, 5);
    defer {
        for (reports.items) |*r| r.deinit(gpa);
        reports.deinit(gpa);
    }

    // (a) the divergence is caught
    try testing.expectEqual(@as(usize, 1), reports.items.len);
    const rep = reports.items[0];
    try testing.expectEqual(Defect(CReg).Kind.divergence, rep.defect.kind);
    // (b) bisected to the exact tick — the race shows on the very first tick
    try testing.expectEqual(@as(u64, 1), rep.defect.tick);
    // (c) minimized to the smallest reproducing stream (1 tick is enough; the race is system-caused)
    try testing.expectEqual(@as(usize, 1), rep.min.inputs.len);
    // (d) provenance attached: the chain reaches the leaky system's SystemCause node
    try testing.expect(rep.cause_chain.len > 0);
}

test "CAPSTONE clean half: the correctly-declared twin reports ZERO defects" {
    const gpa = testing.allocator;
    var inj0 = Injection{ .exec_perm = 0 };
    var inj1 = Injection{ .exec_perm = 1 };
    var cad = Injection{ .cadence = 2 };
    const oracles = [_]Oracle(CReg){
        oraclemod.divergence(CReg, &clean_systems, "perm0", &inj0),
        oraclemod.divergence(CReg, &clean_systems, "perm1", &inj1),
        oraclemod.divergence(CReg, &clean_systems, "cadence2", &cad),
    };
    var reports = try sweep(CReg, gpa, &clean_systems, &seedC, generator.idleGen(CReg), &oracles, 0, 8, 5);
    defer {
        for (reports.items) |*r| r.deinit(gpa);
        reports.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 0), reports.items.len); // a correct schedule never diverges
}

test "enumerate's default injection set catches the leaky divergence (non-identity coverage guaranteed)" {
    const gpa = testing.allocator;
    const injs = try inject.enumerate(gpa, 4);
    defer gpa.free(injs);
    var oracles: std.ArrayList(Oracle(CReg)) = .empty;
    defer oracles.deinit(gpa);
    for (injs) |*inj| try oracles.append(gpa, oraclemod.divergence(CReg, &leaky_systems, "enum", inj));

    var reports = try sweep(CReg, gpa, &leaky_systems, &seedC, generator.idleGen(CReg), oracles.items, 0, 1, 5);
    defer {
        for (reports.items) |*r| r.deinit(gpa);
        reports.deinit(gpa);
    }
    // perm_index 1 (in the enumerated set) rotates the racy stage -> the divergence is caught with no
    // hand-picked swap index.
    try testing.expect(reports.items.len >= 1);
    try testing.expectEqual(Defect(CReg).Kind.divergence, reports.items[0].defect.kind);
}

// --- provenance re-anchor regression (the HIGH finding): the failing tick MOVES under minimization ---

const Tag = struct {
    pub const kind_id: u16 = 1;
};
const TReg = Registry(.{Tag});
const TW = worldmod.World(TReg);
const TMarker = struct {
    pub const kind_id: u16 = 7;
};
fn markerSys(ctx: *SimCtx(TReg), q: *Query(TReg, .{Read(Tag)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| _ = try ctx.emitS(TMarker, row.entity(), .{}); // emit so provenance has an anchor
}
const tsys = [_]Sys(TReg){system(TReg, "marker", markerSys)};
fn countAtMost3(w: *const TW) ?@import("../entity.zig").Entity {
    if (w.table.rowCount() > 3) return w.table.owners()[0];
    return null;
}
fn seedT(gpa: Allocator, seed: u64) Allocator.Error!TW {
    var w = TW.init(seed);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Tag, .{});
    return w;
}

test "provenance re-anchors at the MINIMIZED failing tick (HIGH regression: tick moves under ddmin)" {
    const gpa = testing.allocator;
    // 2 leading no-op ticks, then 3 spawns: rowCount 1 -> 4 violates count<=3 at the ORIGINAL tick 5.
    // Minimization drops the 2 droppable leading ticks, so the violation moves to tick 3.
    const spawn = [_]input.Command{.{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 }};
    const script = [_]input.Input{
        .{ .tick = 0, .commands = &.{} },
        .{ .tick = 0, .commands = &.{} },
        .{ .tick = 0, .commands = &spawn },
        .{ .tick = 0, .commands = &spawn },
        .{ .tick = 0, .commands = &spawn },
    };
    var spec = generator.ScriptedSpec{ .inputs = &script };
    const gen = generator.scriptedGen(TReg, &spec);
    const oracles = [_]Oracle(TReg){oraclemod.invariant(TReg, &tsys, "count<=3", countAtMost3)};

    var reports = try sweep(TReg, gpa, &tsys, &seedT, gen, &oracles, 0, 1, 5);
    defer {
        for (reports.items) |*r| r.deinit(gpa);
        reports.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 1), reports.items.len);
    // the reported defect tick is the POST-minimization tick (3), not the stale original (5)
    try testing.expectEqual(@as(u64, 3), reports.items[0].defect.tick);
    // ...and the cause chain is non-empty (anchored at a real event at the post-min tick) — the bug
    // would have anchored at the stale tick 5 (absent from the 3-tick minimized run) and been empty.
    try testing.expect(reports.items[0].cause_chain.len > 0);
}

test "randomGen spawn/despawn fuzz, driven end-to-end through sweep, trips a planted invariant" {
    const gpa = testing.allocator;
    var rspec = generator.RandomSpec{};
    const gen = generator.randomGen(TReg, &rspec);
    const oracles = [_]Oracle(TReg){oraclemod.invariant(TReg, &tsys, "count<=3", countAtMost3)};

    // spawn-biased fuzz overruns count<=3 within a few seeds/ticks — the only path that drives randomGen
    // through buildRun -> sweep -> minimize -> provenance (it was unit-tested in isolation only).
    var reports = try sweep(TReg, gpa, &tsys, &seedT, gen, &oracles, 0, 4, 8);
    defer {
        for (reports.items) |*r| r.deinit(gpa);
        reports.deinit(gpa);
    }
    try testing.expect(reports.items.len >= 1);
    try testing.expectEqual(Defect(TReg).Kind.invariant, reports.items[0].defect.kind);
}

fn sweepLeakyOnce(gpa: Allocator) !void {
    var inj = Injection{ .exec_perm = 1 };
    const oracles = [_]Oracle(CReg){oraclemod.divergence(CReg, &leaky_systems, "x", &inj)};
    var reports = try sweep(CReg, gpa, &leaky_systems, &seedC, generator.idleGen(CReg), &oracles, 0, 1, 2);
    for (reports.items) |*r| r.deinit(gpa);
    reports.deinit(gpa);
}

test "no leak / no double-free under injected allocation failure (the full sweep+minimize+provenance path)" {
    try testing.checkAllAllocationFailures(testing.allocator, sweepLeakyOnce, .{});
}
