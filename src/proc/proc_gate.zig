//! Phase-9 REAL cross-process determinism gate (PLAN.md §13). Built by build.zig as its own per-mode test
//! artifact (Linux-guarded), it spawns the real `gkz_worker_<mode>` exe (path injected via getEmittedBin)
//! and proves:
//!   (a) the SUBPROCESS result bytes == the IN-PROCESS result bytes == a pinned AGG_DIGEST (identical
//!       across Debug/ReleaseSafe/ReleaseFast) — the headline cross-PROCESS determinism witness.
//!   (b) a sharded sweep dispatched in PARALLEL across REAL worker processes (Supervisor + Io.Group) merges
//!       to the SAME Aggregate as a sequential run and as the unsharded one (the §4 "scheduling
//!       nondeterministic, results never are" principle, lifted to concurrent processes).
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

/// PINNED: the per-tick stream digest of the fork job (base hp=2, drain 2 ticks). Identical across modes
/// and across the in-process / subprocess transports. Recompute via dumpPin.
const FORK_STREAM_DIGEST: u64 = 13641851403073915758;

const net = std.Io.net;
const QS = proc.QueryServer(shared.R, &shared.systems);
/// Run the query server for one request inside an Io.Group (errors captured for the test to surface).
fn serveOne(srv: *QS, io: std.Io, gpa: std.mem.Allocator, server: *net.Server, out_err: *?anyerror) void {
    srv.serveUnix(io, gpa, server, 1) catch |e| {
        out_err.* = e;
    };
}

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

test "(b) sharded sweep over REAL workers dispatched in PARALLEL == sequential == unsharded" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const jd = try jobDir(gpa, &tmp);
    defer gpa.free(jd);
    var ctx = proc.SubprocCtx{ .exe_path = build_opts.worker_exe_path, .job_dir = jd, .io = io, .timeout_ms = 30000 };

    // PARALLEL: 3 shards run concurrently across worker PROCESSES (Io.Group). Merge is by shard index, so
    // the result is independent of which child finished when — the §4 principle lifted to real processes.
    var par = proc.Supervisor(u64){ .gpa = gpa, .executor = proc.subprocessExecutor(&ctx), .io = io, .n_workers = 3, .max_restarts = 1 };
    var rp = try par.runSweep(LO, HI, 3, MAX_TICKS, 0);
    defer rp.deinit(gpa);
    if (rp.spawn_denied) return error.SkipZigTest; // spawn denied — honest skip
    try testing.expectEqual(@as(usize, 0), rp.defects.len);
    try testing.expectEqual(@as(i128, 9), rp.agg.sum); // 3 real workers, concurrent, merged by index == 9
    try testing.expectEqual(@as(u64, 3), rp.agg.count);

    // SEQUENTIAL: same range, no concurrency (io=null) — bit-identical merged Aggregate (parallelism does
    // not perturb the result, only the wall-clock).
    var seqv = proc.Supervisor(u64){ .gpa = gpa, .executor = proc.subprocessExecutor(&ctx), .n_workers = 1, .max_restarts = 1 };
    var rs = try seqv.runSweep(LO, HI, 3, MAX_TICKS, 0);
    defer rs.deinit(gpa);
    try testing.expectEqual(rp.agg.sum, rs.agg.sum);
    try testing.expectEqual(rp.agg.count, rs.agg.count);
    try testing.expectEqual(rp.agg.min, rs.agg.min);
    try testing.expectEqual(rp.agg.max, rs.agg.max);
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

    // REAL socket round-trip: serve one request over a Unix-domain socket (server in an Io.Group), have a
    // client send the framed [u32 len][sim_id][GKZQ1] request and read the [u32 len][GKZR1] reply, and
    // assert the socket reply equals respond() byte-for-byte. (Not a bind-only smoke — the whole transport.)
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sock_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/q.sock", .{tmp.sub_path});
    defer gpa.free(sock_path);
    const ua = net.UnixAddress.init(sock_path) catch return error.SkipZigTest;
    var listener = ua.listen(io, .{}) catch return error.SkipZigTest;
    defer listener.deinit(io);

    var serr: ?anyerror = null;
    var group: std.Io.Group = .init;
    group.async(io, serveOne, .{ &srv, io, gpa, &listener, &serr });

    var sock_reply: std.ArrayList(u8) = .empty;
    defer sock_reply.deinit(gpa);
    {
        var stream = try ua.connect(io);
        defer stream.close(io);
        // send [u32 len][frame]
        var wbuf: [4096]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        const cw = &sw.interface;
        var lh: [4]u8 = undefined;
        std.mem.writeInt(u32, &lh, @intCast(frame.items.len), .little);
        try cw.writeAll(&lh);
        try cw.writeAll(frame.items);
        try cw.flush();
        // read [u32 len][GKZR1]
        var rbuf: [4096]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        const r = &sr.interface;
        const rlen = std.mem.readInt(u32, try r.takeArray(4), .little);
        const reply = try r.readAlloc(gpa, rlen);
        defer gpa.free(reply);
        try sock_reply.appendSlice(gpa, reply);
    }
    try group.await(io);
    if (serr) |se| return se;
    try testing.expectEqualSlices(u8, direct.items, sock_reply.items); // socket reply == respond() bytes
}

fn buildForkJob(gpa: std.mem.Allocator, snap_bytes: []const u8, tick_budget: u64) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try proc.job.writeJob(&sink, .{ .fork = .{ .snapshot_bytes = snap_bytes, .base_tick = 0, .base_hash = 0, .diverged_inputs = &.{}, .tick_budget = tick_budget } });
    return buf;
}

test "(e) fork execution: in-process == subprocess final snapshot + stream digest (pinned)" {
    const gpa = testing.allocator;
    // base World: one Health entity hp=2; snapshot it (the process-portable fork seed)
    var w0 = try shared.seedHp(gpa, 0);
    defer w0.deinit(gpa);
    var base = try gkz.snapshot(shared.R, gpa, &w0);
    defer base.deinit(gpa);

    var fjob = try buildForkJob(gpa, base.bytes, 2); // drain runs 2 ticks → hp 2 → 0
    defer fjob.deinit(gpa);

    // in-process fork
    var inproc: std.ArrayList(u8) = .empty;
    defer inproc.deinit(gpa);
    var s1 = serialize.ByteSink{ .list = &inproc, .gpa = gpa };
    _ = try proc.inProcessExecutor(shared).run(gpa, fjob.items, &s1);
    var d1 = try proc.job.decodeResult(u64, gpa, inproc.items);
    defer d1.deinit();
    try testing.expectEqual(FORK_STREAM_DIGEST, d1.result.final.stream_digest);
    // the fork genuinely ADVANCED the World: restore the final snapshot, entity 0's hp == 0.
    var rdr = serialize.ByteReader{ .bytes = d1.result.final.snapshot_bytes };
    const parts = try serialize.readWorld(shared.R, gpa, &rdr);
    var wf = gkz.World(shared.R).fromParts(parts);
    defer wf.deinit(gpa);
    try testing.expectEqual(@as(i32, 0), wf.get(.{ .index = 0, .generation = 0 }, shared.Health).?.hp);

    // subprocess fork — a real worker restores the snapshot, steps, and returns the final snapshot.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const jd = try jobDir(gpa, &tmp);
    defer gpa.free(jd);
    var ctx = proc.SubprocCtx{ .exe_path = build_opts.worker_exe_path, .job_dir = jd, .io = testing.io, .timeout_ms = 30000 };
    var sub: std.ArrayList(u8) = .empty;
    defer sub.deinit(gpa);
    var s2 = serialize.ByteSink{ .list = &sub, .gpa = gpa };
    const outcome = try proc.subprocessExecutor(&ctx).run(gpa, fjob.items, &s2);
    switch (outcome) {
        .spawn_failed => return error.SkipZigTest,
        .crashed => return error.TestUnexpectedResult,
        .ok => {},
    }
    try testing.expectEqualSlices(u8, inproc.items, sub.items); // cross-process fork determinism, bit for bit
}

// NOT a test — recompute the pins after an intentional change (each is verified by a test above).
comptime {
    _ = &dumpPin;
}
fn dumpPin(gpa: std.mem.Allocator) !void {
    var w0 = try shared.seedHp(gpa, 0);
    defer w0.deinit(gpa);
    var base = try gkz.snapshot(shared.R, gpa, &w0);
    defer base.deinit(gpa);
    var fjob = try buildForkJob(gpa, base.bytes, 2);
    defer fjob.deinit(gpa);
    var fout: std.ArrayList(u8) = .empty;
    defer fout.deinit(gpa);
    var fs = serialize.ByteSink{ .list = &fout, .gpa = gpa };
    _ = try proc.inProcessExecutor(shared).run(gpa, fjob.items, &fs);
    var fd = try proc.job.decodeResult(u64, gpa, fout.items);
    defer fd.deinit();
    std.debug.print("\nFORK_STREAM_DIGEST = {d};\n", .{fd.result.final.stream_digest});

    var jb = try buildJob(gpa, LO, HI, 0);
    defer jb.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var s = serialize.ByteSink{ .list = &out, .gpa = gpa };
    _ = try proc.inProcessExecutor(shared).run(gpa, jb.items, &s);
    std.debug.print("\nAGG_DIGEST = {d};\n", .{digest(out.items)});
}
