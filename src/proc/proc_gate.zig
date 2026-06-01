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
//!   (d) the query server multiplexes respond() byte-identically over a REAL Unix-domain socket round-trip.
//!   (e) fork execution: in-process == subprocess final snapshot + stream digest (pinned).
//!   (f) parallel dispatch genuinely OVERLAPS — N sleep-workers run concurrently (parallel wall-clock well
//!       under sequential), proving real cross-process concurrency, not a serialized "parallel" path.
//!   (g) §17 control plane (the WRITE half): a live socket-DRIVEN control session (hello → step → reload →
//!       step over ONE persistent TCP connection) reaches a World digest bit-identical to the SAME
//!       trajectory expressed as a frozen ControlSchedule and run by the deterministic replay driver —
//!       a live mutation session and its replay are one computation.
//!   (h) §17 networkExecutor over a REAL loopback TCP socket == the in-process bytes == the pinned digest.
//!   (i) §17 networkExecutor across a REAL SEPARATE OS PROCESS (the standalone gkz_net_worker daemon, port
//!       handed back over its stdout) == the pinned digest — the across-machines transport, end to end.
//!
//! HONESTY (the Phase-8 lesson, structural): a disguised in-process gate cannot pass (c) — an in-process
//! @panic aborts the GATE's own test binary; a real `Term.signal` requires a real child that died and was
//! reaped. On SpawnError the subprocess sub-gates SkipZigTest (honest — spawn genuinely denied — never a
//! silent in-process fallback). (i) closes the prior "MULTI-MACHINE equality" gap: a job computed in a
//! separate process and carried over TCP is bit-identical to the in-process result (localhost is only the
//! test substrate — nothing in the path assumes a co-located peer). What it still CANNOT prove: arbitrary
//! author worker code is deterministic (§15 trusts the author; the kernel DETECTS divergence).

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

test "(f) parallel dispatch genuinely OVERLAPS workers (concurrent wall-clock, not serialized)" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const jd = try jobDir(gpa, &tmp);
    defer gpa.free(jd);

    const N = 4;
    // N sleep-workers: each sleeps ~POISON_SLEEP_MS, then computes its (normal) aggregate.
    var built: [N]std.ArrayList(u8) = undefined;
    var nbuilt: usize = 0;
    defer for (built[0..nbuilt]) |*b| b.deinit(gpa);
    var jobs: [N]proc.Supervisor(u64).ShardJob = undefined;
    for (0..N) |i| {
        built[i] = try buildJob(gpa, @intCast(i), @intCast(i + 1), proc.POISON_SLEEP);
        nbuilt += 1;
        jobs[i] = .{ .shard_i = @intCast(i), .range = .{ .lo = @intCast(i), .hi = @intCast(i + 1) }, .bytes = built[i].items };
    }
    var ctx = proc.SubprocCtx{ .exe_path = build_opts.worker_exe_path, .job_dir = jd, .io = io, .timeout_ms = 30000 };

    // PARALLEL dispatch (Io.Group across N worker processes)
    var par = proc.Supervisor(u64){ .gpa = gpa, .executor = proc.subprocessExecutor(&ctx), .io = io, .n_workers = N };
    const p0 = std.Io.Clock.now(.awake, io);
    var rp = try par.runJobs(&jobs);
    const p1 = std.Io.Clock.now(.awake, io);
    defer rp.deinit(gpa);
    if (rp.spawn_denied) return error.SkipZigTest;
    const par_ms = @divTrunc(p1.nanoseconds - p0.nanoseconds, std.time.ns_per_ms);

    // SEQUENTIAL dispatch (same jobs, io=null → one at a time)
    var seqv = proc.Supervisor(u64){ .gpa = gpa, .executor = proc.subprocessExecutor(&ctx), .n_workers = 1 };
    const s0 = std.Io.Clock.now(.awake, io);
    var rs = try seqv.runJobs(&jobs);
    const s1 = std.Io.Clock.now(.awake, io);
    defer rs.deinit(gpa);
    const seq_ms = @divTrunc(s1.nanoseconds - s0.nanoseconds, std.time.ns_per_ms);

    // determinism: identical merged result regardless of dispatch.
    try testing.expectEqual(rs.agg.sum, rp.agg.sum);
    try testing.expectEqual(rs.agg.count, rp.agg.count);
    // OVERLAP: N workers each sleep ~the same time, so parallel ≈ 1 sleep + spawn overhead while sequential
    // ≈ N sleeps. Assert parallel < 60% of sequential — a huge margin (sleep isn't CPU-bound, so this holds
    // on ANY core count); it fails only if the dispatch actually serializes the spawns.
    try testing.expect(par_ms * 100 < seq_ms * 60);
}

// ===================================================================================================
// §17 control-plane completion: the live mutate-a-sim command surface (g) + the across-machines TCP
// execution transport (h: same-process real socket; i: a REAL separate process — the multi-machine
// seam, now closed). These were the "seams" the control plane was previously left at.
// ===================================================================================================

const control = gkz.control;
const reload = gkz.reload;
const schedule_g = gkz.schedule;
const cwire = proc.control_wire;

// A 2-set demo registry for the control session: set_a adds +1/tick, set_b adds +10/tick — so a RELOAD
// mid-session visibly changes behaviour (and the digest), and the reload is a real set swap, not a no-op.
const Counter = struct {
    n: i64,
    pub const kind_id: u16 = 1;
};
const CR = gkz.Registry(.{Counter});
fn cIncA(ctx: *gkz.SimCtx(CR), qq: *gkz.Query(CR, .{gkz.Write(Counter)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (qq.next()) |row| row.write(Counter).n += 1;
}
fn cIncB(ctx: *gkz.SimCtx(CR), qq: *gkz.Query(CR, .{gkz.Write(Counter)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (qq.next()) |row| row.write(Counter).n += 10;
}
const c_set_a = [_]gkz.Sys(CR){gkz.system(CR, "cIncA", cIncA)};
const c_set_b = [_]gkz.Sys(CR){gkz.system(CR, "cIncB", cIncB)};
const c_srcs = [_]reload.SystemSource(CR){ reload.inProcessSource(CR, &c_set_a), reload.inProcessSource(CR, &c_set_b) };
const c_sets = control.SetTable(CR){ .sources = &c_srcs };
const CSrv = gkz.ControlServer(CR, &c_set_a);

fn seedCtr(gpa: std.mem.Allocator) std.mem.Allocator.Error!gkz.World(CR) {
    var w = gkz.World(CR).init(0);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Counter, .{ .n = 0 });
    return w;
}

fn serveCtl(srv: *CSrv, io: std.Io, gpa: std.mem.Allocator, server: *net.Server, max_cmds: usize, out_err: *?anyerror) void {
    srv.serveSession(io, gpa, server, max_cmds) catch |e| {
        out_err.* = e;
    };
}

/// Drive ONE command over an open control stream (write `[u32 len][GKZC2]`, read `[u32 len][GKZD1]`).
fn driveCmd(gpa: std.mem.Allocator, w: *std.Io.Writer, r: *std.Io.Reader, sim_id: u32, cmd: cwire.ControlCommand) !cwire.DecodedResponse {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);
    var fsink = serialize.ByteSink{ .list = &frame, .gpa = gpa };
    try cwire.writeCommand(&fsink, sim_id, cmd);
    var lh: [4]u8 = undefined;
    std.mem.writeInt(u32, &lh, @intCast(frame.items.len), .little);
    try w.writeAll(&lh);
    try w.writeAll(frame.items);
    try w.flush();
    const rl = std.mem.readInt(u32, try r.takeArray(4), .little);
    const reply = try r.readAlloc(gpa, rl);
    defer gpa.free(reply);
    return cwire.decodeResponse(gpa, reply);
}

test "(g) control plane: a live socket-DRIVEN session == its deterministic replay (step+reload+step)" {
    const gpa = testing.allocator;
    const io = testing.io;

    var srv = try CSrv.init(gpa, c_sets);
    defer srv.deinit();
    try srv.spawn(1, try seedCtr(gpa), 0);

    // bind a loopback TCP ephemeral port; serve the session in an Io.Group while the client drives it.
    const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
    var listener = net.IpAddress.listen(&addr, io, .{ .reuse_address = true }) catch return error.SkipZigTest; // no networking → honest skip
    defer listener.deinit(io);

    var serr: ?anyerror = null;
    var group: std.Io.Group = .init;
    group.async(io, serveCtl, .{ &srv, io, gpa, &listener, @as(usize, 6), &serr });

    var driven_digest: u64 = 0;
    {
        const caddr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(listener.socket.address.getPort()) };
        var stream = try net.IpAddress.connect(&caddr, io, .{ .mode = .stream });
        defer stream.close(io);
        var wbuf: [8192]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        var rbuf: [8192]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        const w = &sw.interface;
        const r = &sr.interface;

        // ENFORCEMENT: a command BEFORE a valid hello is refused (unauthorized) — the handshake is not
        // advisory over a real session (a wrong-R / unauthenticated / no-hello client cannot touch the sim).
        var r0 = try driveCmd(gpa, w, r, 1, .{ .step = .{ .n = 1, .inline_inputs = &.{} } });
        defer r0.deinit();
        try testing.expectEqual(cwire.ControlErr.unauthorized, r0.resp.err);

        // hello (R handshake; token-less server), then step 2 (set_a: +1,+1), reload→set_b, step 1 (set_b: +10)
        var rh = try driveCmd(gpa, w, r, 1, .{ .hello = .{ .fingerprint = srv.fp_bytes, .token = "" } });
        defer rh.deinit();
        try testing.expect(rh.resp.hello_ok.ok);
        var r1 = try driveCmd(gpa, w, r, 1, .{ .step = .{ .n = 2, .inline_inputs = &.{} } });
        defer r1.deinit();
        var r2 = try driveCmd(gpa, w, r, 1, .{ .reload = .{ .set_id = 1 } });
        defer r2.deinit();
        try testing.expectEqual(@as(u16, 1), r2.resp.reloaded.set_id);
        var r3 = try driveCmd(gpa, w, r, 1, .{ .step = .{ .n = 1, .inline_inputs = &.{} } });
        defer r3.deinit();
        driven_digest = r3.resp.stepped.digest; // world digest after the driven session
    }
    try group.await(io);
    if (serr) |e| return e;

    // THE witness: the same trajectory expressed as a frozen ControlSchedule (reload set 1 at tick 2,
    // run until tick 3) and executed by the REPLAY driver must reach the SAME digest, bit for bit. The
    // socket-driven live session and the deterministic replay are one computation (single-sourced through
    // stepDynamic + applyReload), so this equality holds in EVERY build mode (the gate runs in all 3).
    // Cross-build/cross-arch determinism of those underlying primitives is pinned in control_gate.zig
    // (the K-pins, over the same stepDynamic/applyReload — a different registry, hence no shared numeric
    // pin here); this gate proves the live socket path drives them faithfully.
    const evs = [_]control.ControlEvent{.{ .at_tick = 2, .op = .{ .reload = 1 } }};
    const sched = control.ControlSchedule{ .events = &evs };
    const oc = try control.runWithControl(CR, gpa, try seedCtr(gpa), &.{}, 0, sched, 0, c_sets, 0, 3, null, null);
    switch (oc) {
        .migrate => return error.TestUnexpectedResult,
        .completed => |w| {
            var ww = w;
            defer ww.deinit(gpa);
            try testing.expectEqual((try ww.digest(gpa)).hash, driven_digest);
            try testing.expectEqual(@as(i64, 12), ww.get(.{ .index = 0, .generation = 0 }, Counter).?.n); // 1+1 then +10
        },
    }
}

const NW = struct {
    fn serve(io: std.Io, gpa: std.mem.Allocator, server: *net.Server, n: usize, out_err: *?anyerror) void {
        proc.runNetWorker(shared, io, gpa, server, n) catch |e| {
            out_err.* = e;
        };
    }
};

test "(h) networkExecutor over a REAL loopback TCP socket == in-process bytes == pinned AGG_DIGEST" {
    const gpa = testing.allocator;
    const io = testing.io;

    var jb = try buildJob(gpa, LO, HI, 0);
    defer jb.deinit(gpa);

    // in-process reference
    var inproc: std.ArrayList(u8) = .empty;
    defer inproc.deinit(gpa);
    var s1 = serialize.ByteSink{ .list = &inproc, .gpa = gpa };
    _ = try proc.inProcessExecutor(shared).run(gpa, jb.items, &s1);
    try testing.expectEqual(AGG_DIGEST, digest(inproc.items));

    // a real TCP worker in an Io.Group, served over loopback; the networkExecutor client connects to it.
    var server = proc.listenLoopback(io, 0) catch return error.SkipZigTest; // no networking → honest skip
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var serr: ?anyerror = null;
    var group: std.Io.Group = .init;
    group.async(io, NW.serve, .{ io, gpa, &server, @as(usize, 1), &serr });

    var net_out: std.ArrayList(u8) = .empty;
    defer net_out.deinit(gpa);
    var s2 = serialize.ByteSink{ .list = &net_out, .gpa = gpa };
    var ctx = proc.NetCtx{ .io = io, .host = "127.0.0.1", .port = port };
    const outcome = try proc.networkExecutor(&ctx).run(gpa, jb.items, &s2);
    try group.await(io);
    if (serr) |e| return e;

    switch (outcome) {
        .spawn_failed => return error.SkipZigTest, // (only if connect was refused — peer should be up here)
        .crashed => return error.TestUnexpectedResult,
        .ok => {},
    }
    // THE transport witness: bytes that crossed a real kernel TCP socket equal the in-process bytes exactly.
    try testing.expectEqualSlices(u8, inproc.items, net_out.items);
    try testing.expectEqual(AGG_DIGEST, digest(net_out.items));
}

test "(i) networkExecutor across a REAL separate process (the multi-machine seam) == pinned AGG_DIGEST" {
    const gpa = testing.allocator;
    const io = testing.io;

    var jb = try buildJob(gpa, LO, HI, 0);
    defer jb.deinit(gpa);

    // spawn the standalone TCP daemon as a REAL child process (separate address space) with a stdout pipe.
    var child = std.process.spawn(io, .{
        .argv = &.{ build_opts.net_worker_exe_path, "net-worker", "1" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |e| switch (e) {
        error.AccessDenied, error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => return error.SkipZigTest, // spawn genuinely denied
        else => return e, // FileNotFound/InvalidExe etc. are HARD failures (never hide a dead gate)
    };
    errdefer _ = child.kill(io);

    // read the daemon's 4-byte LE port handshake from its live stdout (it publishes BEFORE accepting).
    var pbuf: [64]u8 = undefined;
    var cr = child.stdout.?.reader(io, &pbuf);
    const port = std.mem.readInt(u32, try cr.interface.takeArray(4), .little);

    var net_out: std.ArrayList(u8) = .empty;
    defer net_out.deinit(gpa);
    var s2 = serialize.ByteSink{ .list = &net_out, .gpa = gpa };
    var ctx = proc.NetCtx{ .io = io, .host = "127.0.0.1", .port = @intCast(port) };
    const outcome = try proc.networkExecutor(&ctx).run(gpa, jb.items, &s2);

    const term = try child.wait(io);
    switch (outcome) {
        .spawn_failed => return error.SkipZigTest,
        .crashed => return error.TestUnexpectedResult,
        .ok => {},
    }
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term); // the daemon served 1 job and exited cleanly
    // THE multi-machine witness: bytes computed in a SEPARATE OS process, carried over TCP, are bit-identical
    // to the in-process result and the pinned cross-mode digest. Localhost is merely the test substrate —
    // nothing in the path assumes a co-located peer.
    try testing.expectEqual(AGG_DIGEST, digest(net_out.items));
    var dec = try proc.job.decodeResult(u64, gpa, net_out.items);
    defer dec.deinit();
    try testing.expectEqual(@as(i128, 9), dec.result.aggregate.agg.sum);
}

test "(k) networkExecutor across a REAL BIG-ENDIAN process (s390x/qemu) over TCP == pinned AGG_DIGEST" {
    const gpa = testing.allocator;
    const io = testing.io;

    var jb = try buildJob(gpa, LO, HI, 0);
    defer jb.deinit(gpa);

    // Spawn the BIG-ENDIAN s390x daemon under qemu-user. qemu-user forwards the guest's socket syscalls to
    // THIS host's kernel, so its TCP listener is reachable from this little-endian x86_64 client over a real
    // loopback socket — two different-arch peers on one live connection. (`zig build cross` proves the codec
    // is endian-stable in isolation; THIS proves two arches actually agree transacting over a socket.)
    var child = std.process.spawn(io, .{
        .argv = &.{ build_opts.qemu_s390x, build_opts.net_worker_s390x_path, "net-worker", "1" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |e| switch (e) {
        // qemu-s390x absent / spawn denied → honest skip (the host x86_64 (i) gate already proves the
        // separate-process path; this is the stronger cross-endian witness, gated where qemu exists).
        error.FileNotFound, error.AccessDenied, error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => return error.SkipZigTest,
        else => return e,
    };
    errdefer _ = child.kill(io);

    // 4-byte LE port handshake. If the guest couldn't bind (qemu-user networking unsupported here), it exits
    // without publishing a port → EOF → honest skip (this env can't host the witness), never a false failure.
    var pbuf: [64]u8 = undefined;
    var cr = child.stdout.?.reader(io, &pbuf);
    const port = std.mem.readInt(u32, cr.interface.takeArray(4) catch {
        _ = child.kill(io);
        return error.SkipZigTest;
    }, .little);

    var net_out: std.ArrayList(u8) = .empty;
    defer net_out.deinit(gpa);
    var s2 = serialize.ByteSink{ .list = &net_out, .gpa = gpa };
    var ctx = proc.NetCtx{ .io = io, .host = "127.0.0.1", .port = @intCast(port), .timeout_ms = 60_000 }; // qemu is slow → generous deadline
    const outcome = try proc.networkExecutor(&ctx).run(gpa, jb.items, &s2);

    const term = try child.wait(io);
    switch (outcome) {
        .spawn_failed => return error.SkipZigTest,
        .crashed => return error.TestUnexpectedResult, // it published a port (networking works) → a crash now is real
        .ok => {},
    }
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    // THE cross-endian multi-machine witness: a job aggregated by a BIG-ENDIAN peer, carried over TCP, is
    // byte-identical to this little-endian host's pinned digest. The canonical-LE codec holds across the wire.
    try testing.expectEqual(AGG_DIGEST, digest(net_out.items));
    var dec = try proc.job.decodeResult(u64, gpa, net_out.items);
    defer dec.deinit();
    try testing.expectEqual(@as(i128, 9), dec.result.aggregate.agg.sum);
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
