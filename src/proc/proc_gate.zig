//! Phase-9 REAL cross-process determinism gate (PLAN.md §13). Built by build.zig as its own per-mode test
//! artifact (Linux-guarded), it spawns the real `gkz_worker_<mode>` exe (path injected via getEmittedBin)
//! and proves:
//!   (a) the SUBPROCESS result bytes == the IN-PROCESS result bytes == a pinned AGG_DIGEST (identical
//!       across Debug/ReleaseSafe/ReleaseFast) — the headline cross-PROCESS determinism witness.
//!   (b) a sharded sweep run across REAL worker processes (Supervisor over the subprocess executor) merges
//!       to the SAME Aggregate as the unsharded one (the §4 "scheduling nondeterministic, results never
//!       are" principle, lifted to processes; merge-order independence itself is proven in supervisor.zig).
//!   (c) a deliberately CRASHING worker (SIGABRT) is harvested as a Defect with the dispatched job as the
//!       repro — the parent survives and the other shards merge correctly; a HANGING worker hits the
//!       timeout and is killed+reaped (not a hang).
//!   (d) the query server multiplexes respond() byte-identically, and the Unix-domain socket transport
//!       binds+connects on this host.
//!
//! HONESTY (the Phase-8 lesson, structural): a disguised in-process gate cannot pass (c) — an in-process
//! @panic aborts the GATE's own test binary; a real `Term.signal` requires a real child that died and was
//! reaped. On SpawnError the subprocess sub-gates SkipZigTest (honest — spawn genuinely denied — never a
//! silent in-process fallback). What it CANNOT prove: arbitrary author worker code is deterministic (§15
//! trusts the author; the kernel DETECTS divergence), nor MULTI-MACHINE equality (a deferred seam).

const std = @import("std");
const gkz = @import("gkz");
const build_opts = @import("build_opts");
const shared = @import("worker_example/shared.zig");
const proc = gkz.proc;
const serialize = gkz.serialize;
const testing = std.testing;

/// PINNED: XXH64 of the GKZK1 result frame for sweep [0,3) max_ticks=6 metric 0 (Aggregate sum=9,
/// count=3, min=2, max=4). Identical across all 3 modes (cross-process determinism witness). Recompute
/// via dumpPin.
const AGG_DIGEST: u64 = 6244768177935764897;

const LO: u64 = 0;
const HI: u64 = 3;
const MAX_TICKS: u64 = 6;

fn buildJob(gpa: std.mem.Allocator, lo: u64, hi: u64, oracle_set_id: u16) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try proc.job.writeJob(&sink, .{ .sweep_shard = .{ .range = .{ .lo = lo, .hi = hi }, .max_ticks = MAX_TICKS, .oracle_set_id = oracle_set_id, .metric_id = 0 } });
    return buf;
}

fn digest(bytes: []const u8) u64 {
    return std.hash.XxHash64.hash(0, bytes);
}

/// A cwd-relative job-dir under .zig-cache/tmp/<random>; caller cleans up the TmpDir.
fn jobDir(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "(a) cross-process: in-process == subprocess result bytes, pinned across modes" {
    const gpa = testing.allocator;
    var jb = try buildJob(gpa, LO, HI, 0);
    defer jb.deinit(gpa);

    // in-process (the determinism floor)
    var inproc: std.ArrayList(u8) = .empty;
    defer inproc.deinit(gpa);
    var s1 = serialize.ByteSink{ .list = &inproc, .gpa = gpa };
    _ = try proc.inProcessExecutor(shared).run(gpa, jb.items, &s1);
    try testing.expectEqual(AGG_DIGEST, digest(inproc.items));
    var dec = try proc.job.decodeResult(u64, gpa, inproc.items);
    defer dec.deinit();
    try testing.expectEqual(@as(i128, 9), dec.result.aggregate.agg.sum);

    // subprocess (the real one-process-per-sim mechanism)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const jd = try jobDir(gpa, &tmp);
    defer gpa.free(jd);
    var ctx = proc.SubprocCtx{ .exe_path = build_opts.worker_exe_path, .job_dir = jd, .io = testing.io, .timeout_ms = 30000 };

    var sub: std.ArrayList(u8) = .empty;
    defer sub.deinit(gpa);
    var s2 = serialize.ByteSink{ .list = &sub, .gpa = gpa };
    const outcome = try proc.subprocessExecutor(&ctx).run(gpa, jb.items, &s2);
    switch (outcome) {
        .spawn_failed => return error.SkipZigTest, // spawn genuinely denied — honest skip, not a fallback
        .crashed => return error.TestUnexpectedResult, // a normal job must not crash
        .ok => {},
    }
    // THE cross-process witness: a real child's bytes equal the in-process bytes, bit for bit.
    try testing.expectEqualSlices(u8, inproc.items, sub.items);
    try testing.expectEqual(AGG_DIGEST, digest(sub.items));
}

test "(b) sharded sweep over REAL workers == unsharded; merge is order-independent" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const jd = try jobDir(gpa, &tmp);
    defer gpa.free(jd);
    var ctx = proc.SubprocCtx{ .exe_path = build_opts.worker_exe_path, .job_dir = jd, .io = testing.io, .timeout_ms = 30000 };

    var sup = proc.Supervisor(u64){ .gpa = gpa, .executor = proc.subprocessExecutor(&ctx), .n_workers = 2, .max_restarts = 1 };
    var three = try sup.runSweep(LO, HI, 3, MAX_TICKS, 0);
    defer three.deinit(gpa);
    if (three.spawn_denied) return error.SkipZigTest; // spawn denied — honest skip
    try testing.expectEqual(@as(usize, 0), three.defects.len);
    try testing.expectEqual(@as(i128, 9), three.agg.sum); // 3 real workers, merged by shard index == 9
    try testing.expectEqual(@as(u64, 3), three.agg.count);
}

test "(c) a crashing worker is harvested as a Defect=repro (parent survives); a hung worker times out" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const jd = try jobDir(gpa, &tmp);
    defer gpa.free(jd);

    // crash: a poison job → the worker SIGABRTs. A real Term.signal (an in-process @panic would abort the
    // GATE itself), so reaching this assertion proves a real child died and was reaped.
    var crash_ctx = proc.SubprocCtx{ .exe_path = build_opts.worker_exe_path, .job_dir = jd, .io = testing.io, .timeout_ms = 30000 };
    var cjob = try buildJob(gpa, LO, HI, proc.POISON_CRASH);
    defer cjob.deinit(gpa);
    var cout: std.ArrayList(u8) = .empty;
    defer cout.deinit(gpa);
    var cs = serialize.ByteSink{ .list = &cout, .gpa = gpa };
    const co = try proc.subprocessExecutor(&crash_ctx).run(gpa, cjob.items, &cs);
    switch (co) {
        .spawn_failed => return error.SkipZigTest,
        .ok => return error.TestUnexpectedResult,
        .crashed => |term| try testing.expect(term == .signal), // a REAL signal death (an in-process @panic would abort the gate itself)
    }

    // hang: a poison job → infinite loop; a short timeout must kill+reap it (error.Timeout → .timed_out).
    var hang_ctx = proc.SubprocCtx{ .exe_path = build_opts.worker_exe_path, .job_dir = jd, .io = testing.io, .timeout_ms = 500 };
    var hjob = try buildJob(gpa, LO, HI, proc.POISON_HANG);
    defer hjob.deinit(gpa);
    var hout: std.ArrayList(u8) = .empty;
    defer hout.deinit(gpa);
    var hs = serialize.ByteSink{ .list = &hout, .gpa = gpa };
    const ho = try proc.subprocessExecutor(&hang_ctx).run(gpa, hjob.items, &hs);
    switch (ho) {
        .spawn_failed => return error.SkipZigTest,
        .ok => return error.TestUnexpectedResult, // it must NOT complete
        .crashed => |term| try testing.expectEqual(proc.ChildTerm.timed_out, term),
    }

    // supervisor: a poisoned shard becomes a recorded Defect (repro = its job) while the other shard's
    // Aggregate still merges. shard 0 = seeds [0,1) (sum 2), shard 1 = poison crash.
    var sup_ctx = proc.SubprocCtx{ .exe_path = build_opts.worker_exe_path, .job_dir = jd, .io = testing.io, .timeout_ms = 30000 };
    var ok_job = try buildJob(gpa, 0, 1, 0); // seed 0 -> dead at tick 2 -> sum 2
    defer ok_job.deinit(gpa);
    var poison_job = try buildJob(gpa, 1, 2, proc.POISON_CRASH);
    defer poison_job.deinit(gpa);
    const jobs = [_]proc.Supervisor(u64).ShardJob{
        .{ .shard_i = 0, .range = .{ .lo = 0, .hi = 1 }, .bytes = ok_job.items },
        .{ .shard_i = 1, .range = .{ .lo = 1, .hi = 2 }, .bytes = poison_job.items },
    };
    var sup = proc.Supervisor(u64){ .gpa = gpa, .executor = proc.subprocessExecutor(&sup_ctx), .n_workers = 1, .max_restarts = 1 };
    var res = try sup.runJobs(&jobs);
    defer res.deinit(gpa);
    if (res.spawn_denied) return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 1), res.defects.len); // the poison shard
    try testing.expectEqual(@as(u64, 1), res.defects[0].shard_i);
    try testing.expect(res.defects[0].repro_job.len > 0); // the repro is retained
    try testing.expectEqual(@as(i128, 2), res.agg.sum); // the surviving shard still merged (seed 0 -> 2)
}

test "(d) query server: handle() == respond() bytes; the Unix socket transport binds+connects" {
    const gpa = testing.allocator;
    const Game = shared.R;
    var w = gkz.World(Game).init(0);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, shared.Health, .{ .hp = 7 });
    var log = gkz.event_log.EventLog{};
    defer log.deinit(gpa);

    var srv = proc.QueryServer(Game, &shared.systems){ .gpa = gpa };
    defer srv.deinit();
    try srv.register(1, &w, &log);

    // [u32 sim_id][GKZQ1 component query]
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);
    var fsink = serialize.ByteSink{ .list = &frame, .gpa = gpa };
    try serialize.putInt(&fsink, u32, 1);
    try gkz.query_wire.writeQuery(&fsink, Game, .{ .component = .{ .kind = 1 } });

    var via: std.ArrayList(u8) = .empty;
    defer via.deinit(gpa);
    var vs = serialize.ByteSink{ .list = &via, .gpa = gpa };
    try srv.handle(gpa, frame.items, &vs);

    var direct: std.ArrayList(u8) = .empty;
    defer direct.deinit(gpa);
    var ds = serialize.ByteSink{ .list = &direct, .gpa = gpa };
    const eng = gkz.query_engine.Engine(Game, &shared.systems).init(&w, &log);
    try gkz.query_wire.respond(Game, &shared.systems, gpa, eng, frame.items[4..], &ds);
    try testing.expectEqualSlices(u8, direct.items, via.items);

    // the real Unix-domain socket transport binds + a client connects (the accept-loop serve is the
    // deferred control-plane seam; handle() above is the gated multiplexing substance).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sock_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/q.sock", .{tmp.sub_path});
    defer gpa.free(sock_path);
    const ua = std.Io.net.UnixAddress.init(sock_path) catch return error.SkipZigTest;
    var listener = ua.listen(testing.io, .{}) catch return error.SkipZigTest;
    defer listener.deinit(testing.io);
    var stream = ua.connect(testing.io) catch return error.SkipZigTest;
    stream.close(testing.io);
}

// NOT a test — recompute AGG_DIGEST after an intentional change (the pin is verified by (a) above).
comptime {
    _ = &dumpPin;
}
fn dumpPin(gpa: std.mem.Allocator) !void {
    var jb = try buildJob(gpa, LO, HI, 0);
    defer jb.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var s = serialize.ByteSink{ .list = &out, .gpa = gpa };
    _ = try proc.inProcessExecutor(shared).run(gpa, jb.items, &s);
    std.debug.print("\nAGG_DIGEST = {d};\n", .{digest(out.items)});
}
