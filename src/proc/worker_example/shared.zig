//! The fixed-R example sim shared by the §13 worker exe, the in-process executor, and the proc gate
//! (PLAN.md Phase 9). The direct analog of reload_example/shared.zig: because the worker exe and the host
//! both import THIS module, `R`, `Aggregate`, and the job/result byte layouts match by construction —
//! a registry mismatch is impossible, and `R` (which is CODE) never crosses the process boundary; only
//! the job's DATA + `u16` selector ids do.
//!
//! It is the verbatim eval.zig metric demo: a `drain` system decrements hp each tick; `seedHp(seed)` sets
//! hp = 2 + seed; the `dead` atom holds when entity 0's hp ≤ 0; `timeToCondition(0)` therefore yields the
//! kill tick 2, 3, 4 for seeds 0, 1, 2 — so a sweep over [0,3) reduces to Aggregate.sum = 9, a known
//! in-tree number the gate pins.

const std = @import("std");
const gkz = @import("gkz");

pub const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 1;
};

pub const R = gkz.Registry(.{Health});

/// The metric's integer type (timeToCondition returns a tick count).
pub const MetricT = u64;

fn drain(ctx: *gkz.SimCtx(R), q: *gkz.Query(R, .{gkz.Write(Health)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Health).hp -= 1;
}

/// The system set (R-fixed CODE; never serialized).
pub const systems = [_]gkz.Sys(R){gkz.system(R, "drain", drain)};

/// Atom 0: entity 0 is "dead" (hp ≤ 0). `timeToCondition(0)` measures the first tick it holds.
const dead = gkz.spec.atom.fieldLE(R, Health, "hp", .{ .index = 0, .generation = 0 }, 0);
pub const atoms = [_]gkz.spec.Atom(R){dead};

/// Seed a one-entity World with hp = 2 + seed (so the kill tick is 2 + seed).
pub fn seedHp(gpa: std.mem.Allocator, seed: u64) std.mem.Allocator.Error!gkz.World(R) {
    var w = gkz.World(R).init(seed);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Health, .{ .hp = @intCast(2 + seed) });
    return w;
}

/// The R-fixed metric table: a job's runtime `metric_id` (DATA) selects a comptime `Metric` (CODE). The
/// worker holds the code; the job names which one. Phase-9 MVP ships one metric (time-to-dead).
pub fn metricOf(comptime id: u16) gkz.spec.Metric(MetricT) {
    return switch (id) {
        0 => gkz.spec.metric.timeToCondition(0), // first tick atom 0 (dead) holds
        else => @compileError("unknown metric_id for the example sim"),
    };
}

/// The number of metrics in the table (runtime bound for the executor's dispatch + a validity check).
pub const metric_count: u16 = 1;
