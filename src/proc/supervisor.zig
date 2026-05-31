//! The §13 supervisor (PLAN.md Phase 9): a process pool that dispatches sweep-shard jobs through an
//! `Executor`, harvests results INDEX-ADDRESSED by shard, restarts a crashed worker a bounded number of
//! times (recording the dispatched job bytes as a re-runnable repro, §9), and merges the survivors in
//! CANONICAL shard-index order. This lifts the §4 "physical scheduling is nondeterministic, results never
//! are" principle to PROCESSES: which slot runs which shard, completion order, and restarts are all
//! nondeterministic, but the merged `Aggregate` is bit-identical to the unsharded single-process sweep
//! because results are keyed by shard index (never appended on arrival) and `mergeAggregates` is
//! associative over the canonically-ordered survivors; the defect set is sorted by `(shard_i, seed, tick)`.
//!
//! Generic over the metric's integer type `T` — the supervisor moves job/result BYTES and merges
//! `Aggregate(T)`; the R-fixed sim lives in the `Executor` (in-process `Spec` or the worker exe). No
//! globals; explicit `gpa` + `Executor`. The MVP dispatches sequentially through the pool
//! (correctness-first); parallel `Io.async` dispatch is a drop-in behind the same merge-by-index.

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const job = @import("job.zig");
const exe = @import("executor.zig");
const shard = @import("../agent/shard.zig");
const metric = @import("../spec/metric.zig");

pub fn Supervisor(comptime T: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        executor: exe.Executor,
        /// Concurrency cap (MVP dispatches sequentially; parallel is a deferred drop-in). Bounded ≥ 1.
        n_workers: usize = 1,
        /// How many times a crashed shard is re-dispatched before it is permanently failed (its repro
        /// retained). A deterministic crash reproduces (keeps crashing) → bounded, no infinite loop.
        max_restarts: u32 = 2,

        /// A harvested permanently-failed shard: its job is the exact repro.
        pub const Defect = struct {
            shard_i: u64,
            range: shard.ShardRange,
            term: exe.ChildTerm,
            repro_job: []u8,
        };

        /// One shard's job (bytes borrowed from the caller for the duration of the call).
        pub const ShardJob = struct { shard_i: u64, range: shard.ShardRange, bytes: []const u8 };

        pub const SweepResult = struct {
            agg: metric.Aggregate(T),
            defects: []Defect,
            /// True if any shard hit `.spawn_failed` (the OS refused to spawn — the gate maps this to a
            /// SkipZigTest, never a silent in-process fallback).
            spawn_denied: bool,
            pub fn deinit(self: *SweepResult, gpa: Allocator) void {
                for (self.defects) |d| gpa.free(d.repro_job);
                gpa.free(self.defects);
                self.* = undefined;
            }
        };

        /// Dispatch a caller-supplied list of shard jobs (in shard-index order: `jobs[i].shard_i == i`),
        /// harvesting each into an index-addressed slot, restarting crashes, and merging survivors in
        /// canonical order. The gate uses this to inject a poison shard; `runSweep` is the normal sugar.
        pub fn runJobs(self: *Self, jobs: []const ShardJob) !SweepResult {
            std.debug.assert(self.n_workers >= 1); // advisory in the MVP (sequential dispatch); ≥1 by contract
            const results = try self.gpa.alloc(?metric.Aggregate(T), jobs.len);
            defer self.gpa.free(results);
            @memset(results, null);

            var defects: std.ArrayList(Defect) = .empty;
            errdefer {
                for (defects.items) |d| self.gpa.free(d.repro_job);
                defects.deinit(self.gpa);
            }
            var spawn_denied = false;

            for (jobs, 0..) |sj, slot| {
                var attempt: u32 = 0;
                dispatch: while (true) : (attempt += 1) {
                    var out: std.ArrayList(u8) = .empty;
                    defer out.deinit(self.gpa);
                    var osink = serialize.ByteSink{ .list = &out, .gpa = self.gpa };
                    const outcome = try self.executor.run(self.gpa, sj.bytes, &osink);

                    // Resolve to either success (results[slot] set, break) or a FAULT term to harvest. A
                    // worker that exits 0 with a malformed / wrong-arm result frame is a per-shard protocol
                    // fault (.bad_result) routed through the SAME restart/defect path as a crash — one bad
                    // worker never aborts the whole sweep (§13 crash-isolation).
                    const fault: exe.ChildTerm = switch (outcome) {
                        .ok => blk: {
                            if (job.decodeResult(T, self.gpa, out.items)) |dv| {
                                var dec = dv;
                                defer dec.deinit();
                                switch (dec.result) {
                                    .aggregate => |x| {
                                        results[slot] = x.agg;
                                        break :dispatch; // success
                                    },
                                    .final => {}, // a fork result for a sweep job → protocol fault
                                }
                            } else |_| {} // a malformed result frame → protocol fault
                            break :blk .bad_result;
                        },
                        .spawn_failed => {
                            spawn_denied = true;
                            break :dispatch; // genuine spawn-denial; the gate SkipZigTests
                        },
                        .crashed => |term| term,
                    };

                    // a fault (crash / timeout / bad_result): retry up to max_restarts, else harvest a
                    // Defect=repro and exclude the shard (its siblings still merge by index).
                    if (attempt >= self.max_restarts) {
                        try defects.append(self.gpa, .{
                            .shard_i = sj.shard_i,
                            .range = sj.range,
                            .term = fault,
                            .repro_job = try self.gpa.dupe(u8, sj.bytes),
                        });
                        break :dispatch;
                    } // else re-dispatch the SAME job (a transient fault may recover; a deterministic one re-faults)
                }
            }

            // merge survivors in canonical shard-index order (results is index-addressed, so iterating it
            // ascending is canonical; mergeAggregates is associative + order-independent regardless).
            var parts: std.ArrayList(metric.Aggregate(T)) = .empty;
            defer parts.deinit(self.gpa);
            for (results) |maybe| if (maybe) |a| try parts.append(self.gpa, a);
            const merged = shard.mergeAggregates(T, parts.items);

            // defects are appended in shard order already (we iterate jobs ascending); a sort keeps the
            // contract explicit even if a future parallel dispatch appends out of order.
            const def_slice = try defects.toOwnedSlice(self.gpa);
            std.mem.sort(Defect, def_slice, {}, lessDefect);
            return .{ .agg = merged, .defects = def_slice, .spawn_denied = spawn_denied };
        }

        fn lessDefect(_: void, a: Defect, b: Defect) bool {
            if (a.shard_i != b.shard_i) return a.shard_i < b.shard_i;
            return a.range.lo < b.range.lo;
        }

        /// Plan a sharded sweep over `[seed_lo, seed_hi)` into `n_shards` jobs (normal, `oracle_set_id=0`)
        /// and dispatch them. The merged `Aggregate` is bit-identical to a single unsharded sweep.
        pub fn runSweep(self: *Self, seed_lo: u64, seed_hi: u64, n_shards: u64, max_ticks: u64, metric_id: u16) !SweepResult {
            std.debug.assert(n_shards >= 1);
            // build all job bytes (owned here; borrowed by runJobs for the call)
            var jobs = try self.gpa.alloc(ShardJob, n_shards);
            var built: usize = 0;
            defer {
                for (jobs[0..built]) |sj| self.gpa.free(sj.bytes);
                self.gpa.free(jobs);
            }
            var shard_i: u64 = 0;
            while (shard_i < n_shards) : (shard_i += 1) {
                const range = shard.shardRanges(seed_lo, seed_hi, n_shards, shard_i);
                var jb: std.ArrayList(u8) = .empty;
                errdefer jb.deinit(self.gpa); // frees jb only if writeJob fails before toOwnedSlice
                var jsink = serialize.ByteSink{ .list = &jb, .gpa = self.gpa };
                try job.writeJob(&jsink, .{ .sweep_shard = .{ .range = range, .max_ticks = max_ticks, .oracle_set_id = 0, .metric_id = metric_id } });
                // toOwnedSlice gives an EXACT-sized slice (gpa.free of jb.items, a len≤cap slice, is an invalid free)
                const owned = try jb.toOwnedSlice(self.gpa);
                jobs[@intCast(shard_i)] = .{ .shard_i = shard_i, .range = range, .bytes = owned };
                built += 1;
            }
            return self.runJobs(jobs);
        }
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests (against the in-process executor — the determinism core; the subprocess/crash path is gated)
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const worldmod = @import("../world.zig");
const q = @import("../query.zig");
const simctx = @import("../simctx.zig");
const schedule = @import("../schedule.zig");
const atommod = @import("../spec/atom.zig");
const metricmod = @import("../spec/metric.zig");

const TestSpec = struct {
    const Health = struct {
        hp: i32,
        pub const kind_id: u16 = 1;
    };
    pub const R = Registry(.{Health});
    pub const MetricT = u64;
    fn drain(ctx: *simctx.SimCtx(R), qq: *q.Query(R, .{q.Write(Health)})) std.mem.Allocator.Error!void {
        _ = ctx;
        while (qq.next()) |row| row.write(Health).hp -= 1;
    }
    pub const systems = [_]schedule.Sys(R){schedule.system(R, "drain", drain)};
    const dead = atommod.fieldLE(R, Health, "hp", .{ .index = 0, .generation = 0 }, 0);
    pub const atoms = [_]atommod.Atom(R){dead};
    pub fn seedHp(gpa: Allocator, seed: u64) Allocator.Error!worldmod.World(R) {
        var w = worldmod.World(R).init(seed);
        errdefer w.deinit(gpa);
        const e = try w.spawn(gpa);
        w.add(e, Health, .{ .hp = @intCast(2 + seed) });
        return w;
    }
    pub fn metricOf(comptime id: u16) metricmod.Metric(MetricT) {
        return switch (id) {
            0 => metricmod.timeToCondition(0),
            else => @compileError("unknown metric_id"),
        };
    }
    pub const metric_count: u16 = 1;
};

test "runSweep over the in-process executor: unsharded == sharded == 9, no defects" {
    const gpa = testing.allocator;
    var sup = Supervisor(u64){ .gpa = gpa, .executor = exe.inProcessExecutor(TestSpec), .n_workers = 2, .max_restarts = 2 };

    var one = try sup.runSweep(0, 3, 1, 6, 0); // 1 shard
    defer one.deinit(gpa);
    try testing.expectEqual(@as(i128, 9), one.agg.sum);
    try testing.expectEqual(@as(usize, 0), one.defects.len);

    var three = try sup.runSweep(0, 3, 3, 6, 0); // 3 shards, merged
    defer three.deinit(gpa);
    try testing.expectEqual(@as(i128, 9), three.agg.sum); // sharded == unsharded (merge-by-index)
    try testing.expectEqual(@as(u64, 3), three.agg.count);
}

var garbage_ctx: u8 = 0;
fn garbageRun(_: std.mem.Allocator, job_bytes: []const u8, out: *serialize.ByteSink) exe.RunError!exe.Outcome {
    _ = job_bytes;
    try out.update("GARBAGE-not-a-GKZK1-frame"); // exits .ok but the result body is malformed
    return .ok;
}

test "a worker that returns a malformed result is harvested as a per-shard defect, NOT a sweep abort" {
    const gpa = testing.allocator;
    // executor.run's signature passes (ctx, gpa, job_bytes, out); wrap garbageRun to match.
    const Wrap = struct {
        fn run(_: *anyopaque, g: std.mem.Allocator, jb: []const u8, out: *serialize.ByteSink) exe.RunError!exe.Outcome {
            return garbageRun(g, jb, out);
        }
    };
    const garbage = exe.Executor{ .ctx = &garbage_ctx, .runFn = Wrap.run };
    var sup = Supervisor(u64){ .gpa = gpa, .executor = garbage, .max_restarts = 0 };

    var jb0: std.ArrayList(u8) = .empty;
    defer jb0.deinit(gpa);
    var s0 = serialize.ByteSink{ .list = &jb0, .gpa = gpa };
    try job.writeJob(&s0, .{ .sweep_shard = .{ .range = .{ .lo = 0, .hi = 1 }, .max_ticks = 4, .oracle_set_id = 0, .metric_id = 0 } });
    const jobs = [_]Supervisor(u64).ShardJob{
        .{ .shard_i = 0, .range = .{ .lo = 0, .hi = 1 }, .bytes = jb0.items },
        .{ .shard_i = 1, .range = .{ .lo = 1, .hi = 2 }, .bytes = jb0.items },
    };
    var res = try sup.runJobs(&jobs); // must NOT propagate an error
    defer res.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), res.defects.len); // both malformed shards became defects
    try testing.expectEqual(exe.ChildTerm.bad_result, res.defects[0].term);
    try testing.expect(res.defects[0].repro_job.len > 0); // the repro is retained
    try testing.expectEqual(@as(u64, 0), res.agg.count); // no survivor merged
}

test "merge is order-independent: a reversed survivor list yields the identical Aggregate" {
    const gpa = testing.allocator;
    var sup = Supervisor(u64){ .gpa = gpa, .executor = exe.inProcessExecutor(TestSpec) };
    var fwd = try sup.runSweep(0, 6, 4, 8, 0);
    defer fwd.deinit(gpa);
    // recompute by merging the per-shard parts in REVERSE, asserting associativity/commutativity.
    var parts: [4]metric.Aggregate(u64) = undefined;
    for (0..4) |i| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        var sink = serialize.ByteSink{ .list = &bytes, .gpa = gpa };
        const range = shard.shardRanges(0, 6, 4, @intCast(i));
        try job.writeJob(&sink, .{ .sweep_shard = .{ .range = range, .max_ticks = 8, .oracle_set_id = 0, .metric_id = 0 } });
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var osink = serialize.ByteSink{ .list = &out, .gpa = gpa };
        _ = try exe.inProcessExecutor(TestSpec).run(gpa, bytes.items, &osink);
        var dec = try job.decodeResult(u64, gpa, out.items);
        defer dec.deinit();
        parts[i] = dec.result.aggregate.agg;
    }
    var rev: [4]metric.Aggregate(u64) = undefined;
    for (0..4) |i| rev[i] = parts[3 - i];
    const merged_rev = shard.mergeAggregates(u64, &rev);
    try testing.expectEqual(fwd.agg.sum, merged_rev.sum);
    try testing.expectEqual(fwd.agg.count, merged_rev.count);
}
