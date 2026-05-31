//! Intent-metrics (PLAN.md Phase 6, build-order step 7): the §8 third pillar, and the fun-oracle boundary
//! drawn as a TYPE distinction.
//!
//! A `Metric(T)` MEASURES an integer quantity over a run's Trace (time-to-clear, an economy endpoint, a
//! count) — it returns a scalar, NEVER a verdict. The engine measures; it does not judge. "Fun" stays a
//! DECLARED proxy: a metric becomes checkable ONLY when a human/agent EXOGENOUSLY supplies a bound via
//! `metricBound` (which yields a `kind=.temporal` Defect). Intent is exogenous — the kernel never picks
//! the proxy or the threshold. T is integer-only (`i64`/`u64`): a comptime `serializedSizeOf(T)` guard
//! @compileErrors on a float (D7) or pointer (D8), and `Aggregate` sums in `i128` with the mean exposed
//! as an exact `{num, den}` pair (division deferred to display — no float on any path).
//!
//! The Phase-7 agent seam is the existing `Run(R)`/`Generator` boundary: `aggregate` takes a
//! `seed_world` + `Generator` (idle/scripted today, an agent `observe(State)->Input` Generator later) —
//! zero change to the measurement contract, because a Trace is a pure fold over whatever Run was produced.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tracemod = @import("trace.zig");
const Trace = tracemod.Trace;
const Atom = @import("atom.zig").Atom;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const worldmod = @import("../world.zig");
const runmod = @import("../vopr/run.zig");
const generator = @import("../vopr/generator.zig");
const oraclemod = @import("../vopr/oracle.zig");
const Oracle = oraclemod.Oracle;
const serialize = @import("../serialize.zig");

/// A named integer measurement over a Trace. R-agnostic (a metric folds Trace columns, like a property).
pub fn Metric(comptime T: type) type {
    comptime {
        _ = serialize.serializedSizeOf(T); // D7/D8 guard: @compileError on a float/pointer measurement
        switch (@typeInfo(T)) {
            .int => {},
            else => @compileError("a Metric measures an INTEGER quantity (i64/u64); got " ++ @typeName(T)),
        }
    }
    return struct {
        name: []const u8,
        measure: *const fn (*const Trace, Allocator) Allocator.Error!T,
    };
}

/// Integer reduction over a sweep. `sum` is `i128` (headroom over a large seed range); `mean` is an exact
/// `{num, den}` rational (no float). A non-deterministic or overflowing fold fails the gate's pinned tuple.
pub fn Aggregate(comptime T: type) type {
    return struct {
        const Self = @This();
        count: u64 = 0,
        min: T = std.math.maxInt(T),
        max: T = std.math.minInt(T),
        sum: i128 = 0,

        pub fn add(self: *Self, v: T) void {
            self.count += 1;
            if (v < self.min) self.min = v;
            if (v > self.max) self.max = v;
            self.sum += v;
        }
        /// Exact mean as numerator/denominator (division deferred to display — D7).
        pub fn mean(self: Self) struct { num: i128, den: u64 } {
            return .{ .num = self.sum, .den = self.count };
        }
    };
}

/// Measure `metric` over one prebuilt Run: build the Trace from `atoms`, fold. `want_log` only when the
/// metric reads events.
pub fn measureRun(
    comptime R: type,
    comptime systems: []const Sys(R),
    comptime atoms: []const Atom(R),
    comptime want_log: bool,
    comptime T: type,
    gpa: Allocator,
    run: *const runmod.Run(R),
    metric: Metric(T),
) (tracemod.Error)!T {
    var trace = try tracemod.build(R, gpa, run, systems, atoms, want_log);
    defer trace.deinit(gpa);
    return metric.measure(&trace, gpa);
}

/// Aggregate `metric` over the seed range `[seed_lo, seed_hi)`: build a Run per seed (the §9 sweep shape;
/// the Phase-7 agent seam is `gen`), measure, reduce. Pure in the seed range + generator + systems.
pub fn aggregate(
    comptime R: type,
    comptime systems: []const Sys(R),
    comptime atoms: []const Atom(R),
    comptime want_log: bool,
    comptime T: type,
    gpa: Allocator,
    seed_world: *const fn (Allocator, u64) Allocator.Error!worldmod.World(R),
    gen: generator.Generator(R),
    metric: Metric(T),
    seed_lo: u64,
    seed_hi: u64,
    max_ticks: usize,
) !Aggregate(T) {
    var agg: Aggregate(T) = .{};
    var seed = seed_lo;
    while (seed < seed_hi) : (seed += 1) {
        const w0 = try seed_world(gpa, seed);
        var run = try runmod.buildRun(R, gpa, systems, w0, seed, gen, max_ticks);
        defer run.deinit(gpa);
        agg.add(try measureRun(R, systems, atoms, want_log, T, gpa, &run, metric));
    }
    return agg;
}

/// EXOGENOUS promotion: a metric + a bound become a checkable Oracle. `cmp=.le` means "metric must be ≤
/// bound" (violation when it exceeds). The whole-run scalar has no specific tick, so the Defect is
/// anchored at the final tick with `.none` detail. This is the ONLY way a measured proxy becomes a
/// guarantee — and only because the caller supplied the bound (the fun-oracle boundary).
pub const Cmp = enum { le, ge };
pub fn metricBound(
    comptime R: type,
    comptime systems: []const Sys(R),
    comptime atoms: []const Atom(R),
    comptime want_log: bool,
    comptime T: type,
    comptime name: []const u8,
    comptime metric: Metric(T),
    comptime bound: T,
    comptime cmp: Cmp,
) Oracle(R) {
    const Impl = struct {
        fn evalFn(ctx: *anyopaque, run: *const runmod.Run(R), gpa: Allocator) Allocator.Error!?oraclemod.Defect(R) {
            _ = ctx;
            const v = measureRun(R, systems, atoms, want_log, T, gpa, run, metric) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TraceDiverged => unreachable,
            };
            const ok = switch (cmp) {
                .le => v <= bound,
                .ge => v >= bound,
            };
            if (ok) return null;
            return oraclemod.Defect(R){ .seed = run.seed, .tick = @intCast(run.inputs.len), .kind = .temporal, .oracle = name, .detail = .none };
        }
    };
    return .{ .name = name, .kind = .temporal, .ctx = &mb_ctx, .eval_fn = Impl.evalFn };
}

var mb_ctx: u8 = 0;

/// Metric: the first tick atom `atom_id` holds (e.g. boss_dead → time-to-clear), or `len+1` if never.
pub fn timeToCondition(comptime atom_id: usize) Metric(u64) {
    const Impl = struct {
        fn m(tr: *const Trace, _: Allocator) Allocator.Error!u64 {
            var t: u64 = 1;
            while (t <= tr.len()) : (t += 1) {
                if (tr.holds(atom_id, t)) return t;
            }
            return @intCast(tr.len() + 1); // sentinel: condition never met over the recorded prefix
        }
    };
    return .{ .name = "timeToCondition", .measure = Impl.m };
}

/// Metric: atom `atom_id`'s scalar at the final tick (e.g. an economy endpoint).
pub fn endpointScalar(comptime atom_id: usize) Metric(i64) {
    const Impl = struct {
        fn m(tr: *const Trace, _: Allocator) Allocator.Error!i64 {
            if (tr.len() == 0) return 0;
            return tr.scalar(atom_id, @intCast(tr.len()));
        }
    };
    return .{ .name = "endpointScalar", .measure = Impl.m };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const query = @import("../query.zig");
const simctx = @import("../simctx.zig");
const Write = query.Write;
const Query = query.Query;
const SimCtx = simctx.SimCtx;
const system = schedule.system;
const atom = @import("atom.zig");

const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Health});
fn drain(ctx: *SimCtx(Game), q: *Query(Game, .{Write(Health)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Health).hp -= 1;
}
const game_systems = [_]Sys(Game){system(Game, "drain", drain)};
const dead_atom = atom.fieldLE(Game, Health, "hp", .{ .index = 0, .generation = 0 }, 0);
const hp_atom = atom.scalarField(Game, Health, "hp", .{ .index = 0, .generation = 0 });
const metric_atoms = [_]Atom(Game){ dead_atom, hp_atom };

fn seedHp(gpa: Allocator, seed: u64) Allocator.Error!worldmod.World(Game) {
    var w = worldmod.World(Game).init(seed);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    // hp = 3 + seed; reaches <= 0 at tick (3 + seed + 1)
    w.add(e, Health, .{ .hp = @intCast(3 + seed) });
    return w;
}

test "measureRun: time-to-clear (boss hp<=0) is exact" {
    const gpa = testing.allocator;
    const w0 = try seedHp(gpa, 0); // hp 3; buildRun consumes it (frees on its own OOM) — no errdefer here
    var run = try runmod.buildRun(Game, gpa, &game_systems, w0, 0, generator.idleGen(Game), 8);
    defer run.deinit(gpa);
    const t = try measureRun(Game, &game_systems, &metric_atoms, false, u64, gpa, &run, timeToCondition(0));
    try testing.expectEqual(@as(u64, 3), t); // hp: t1=2,t2=1,t3=0 -> dead (<=0) at tick 3
    const end = try measureRun(Game, &game_systems, &metric_atoms, false, i64, gpa, &run, endpointScalar(1));
    try testing.expectEqual(@as(i64, -5), end); // hp at tick 8 = 3-8
}

test "aggregate over a seed range reduces to an exact integer Aggregate (no float)" {
    const gpa = testing.allocator;
    // seeds 0..3: hp 3,4,5 -> time-to-clear 3,4,5
    var agg = try aggregate(Game, &game_systems, &metric_atoms, false, u64, gpa, seedHp, generator.idleGen(Game), timeToCondition(0), 0, 3, 10);
    try testing.expectEqual(@as(u64, 3), agg.count);
    try testing.expectEqual(@as(u64, 3), agg.min);
    try testing.expectEqual(@as(u64, 5), agg.max);
    try testing.expectEqual(@as(i128, 12), agg.sum); // 3+4+5
    const m = agg.mean();
    try testing.expectEqual(@as(i128, 12), m.num);
    try testing.expectEqual(@as(u64, 3), m.den); // 12/3 = 4, exact, no float
}

test "metricBound: an exogenous bound promotes a metric to a checkable Oracle (the fun-oracle boundary)" {
    const gpa = testing.allocator;
    const w0 = try seedHp(gpa, 0); // buildRun consumes it (frees on its own OOM) — no errdefer here
    var run = try runmod.buildRun(Game, gpa, &game_systems, w0, 0, generator.idleGen(Game), 8);
    defer run.deinit(gpa);
    // "clears within 5 ticks" holds (3 <= 5) -> no defect
    const ok = metricBound(Game, &game_systems, &metric_atoms, false, u64, "clears<=5", timeToCondition(0), 5, .le);
    try testing.expectEqual(@as(?oraclemod.Defect(Game), null), try ok.eval(&run, gpa));
    // "clears within 2 ticks" fails (3 > 2) -> a temporal Defect
    const bad = metricBound(Game, &game_systems, &metric_atoms, false, u64, "clears<=2", timeToCondition(0), 2, .le);
    const d = (try bad.eval(&run, gpa)).?;
    try testing.expectEqual(oraclemod.Defect(Game).Kind.temporal, d.kind);
}
