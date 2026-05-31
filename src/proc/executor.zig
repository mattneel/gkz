//! The §13 execution-transport seam (PLAN.md Phase 9), modeled on Phase-8's `reload.SystemSource`: a job
//! (GKZJ1 bytes) goes IN, a result (GKZK1 bytes) comes OUT, and the transport — in-process vs a real OS
//! subprocess — is interchangeable behind one `Executor` value. The byte interface is registry-agnostic;
//! the R-fixed CODE lives in `runJobBytes(comptime Spec, ...)` (the worker config = the example's
//! shared.zig), so the in-process executor and the worker exe run the IDENTICAL dispatch.
//!
//! The in-process executor is the determinism FLOOR — it runs in every CI, no spawn. The subprocess
//! executor is the real one-process-per-sim mechanism: it ships the job via a TEMP FILE and collects the
//! result over stdout using `std.process.run`, the ONLY spawn+collect path that carries a timeout
//! (`Child.wait` has none) and forces `.stdin=.ignore` — so a hung child is killed (`error.Timeout`) and a
//! crashed child surfaces as `Term.signal` (a harvested repro, §9), never a parent crash or a hang.

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const metric = @import("../spec/metric.zig");
const generator = @import("../vopr/generator.zig");
const job = @import("job.zig");

/// How a worker terminated, from the parent's view. All are faults to be harvested with the dispatched
/// job as the repro: `signal` (e.g. SIGABRT/SIGSEGV), `exited` (nonzero), `timed_out` (hung, killed by
/// the parent), `bad_result` (exited 0 but produced a malformed/unexpected result frame — a protocol
/// fault the supervisor isolates per-shard rather than aborting the whole sweep).
pub const ChildTerm = union(enum) { exited: u8, signal: u8, timed_out, bad_result };

/// The transport outcome. `.ok` ⇒ `out` holds the GKZK1 result frame (caller owns). `.crashed` ⇒ the
/// child died/timed out (the supervisor records the dispatched job as the repro). `.spawn_failed` ⇒ the
/// OS refused to spawn (a sandbox-deny path → the gate maps it to SkipZigTest, never a silent fallback).
pub const Outcome = union(enum) { ok, crashed: ChildTerm, spawn_failed };

pub const RunError = serialize.Error || Allocator.Error || error{WorkerProtocol};

/// A registry-agnostic execution transport: bytes in (`job_bytes`), bytes out (`out`), with a coarse
/// `Outcome`. (Deliberately NOT generic over R — the transport moves bytes; the R-fixed code is in
/// `runJobBytes(Spec)`. Type safety against an R mismatch is the gate's byte-equality assertion + the
/// GKZJ1/GKZK1 magic-version header, exactly as the dlopen gate relied on byte equality.)
pub const Executor = struct {
    ctx: *anyopaque,
    runFn: *const fn (*anyopaque, gpa: Allocator, job_bytes: []const u8, out: *serialize.ByteSink) RunError!Outcome,

    pub fn run(self: Executor, gpa: Allocator, job_bytes: []const u8, out: *serialize.ByteSink) RunError!Outcome {
        return self.runFn(self.ctx, gpa, job_bytes, out);
    }
};

// --- the R-fixed job dispatcher (shared by in-process AND the worker exe) --------------------------

/// Decode a job and run it against `Spec` (the worker config: `Spec.R`, `Spec.systems`, `Spec.atoms`,
/// `Spec.seedHp`, `Spec.MetricT`, `Spec.metricOf`, `Spec.metric_count`), encoding the GKZK1 result into
/// `out`. PURE (no IO, no spawn) — the in-process executor and `worker_main` both call this, so the two
/// are the identical computation. A worker-side failure that isn't OOM (e.g. a diverged trace) is
/// `error.WorkerProtocol` (OOM propagates).
pub fn runJobBytes(comptime Spec: type, gpa: Allocator, job_bytes: []const u8, out: *serialize.ByteSink) RunError!void {
    var dec = try job.decodeJob(gpa, job_bytes);
    defer dec.deinit();
    switch (dec.job) {
        .sweep_shard => |s| {
            if (s.metric_id >= Spec.metric_count) return error.WorkerProtocol;
            var agg: metric.Aggregate(Spec.MetricT) = .{};
            // runtime metric_id (DATA) -> comptime Metric (CODE) via the R-fixed table.
            inline for (0..Spec.metric_count) |mid| {
                if (s.metric_id == @as(u16, mid)) {
                    agg = metric.aggregate(
                        Spec.R,
                        &Spec.systems,
                        &Spec.atoms,
                        false,
                        Spec.MetricT,
                        gpa,
                        Spec.seedHp,
                        generator.idleGen(Spec.R),
                        Spec.metricOf(@as(u16, mid)),
                        s.range.lo,
                        s.range.hi,
                        @intCast(s.max_ticks),
                    ) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.WorkerProtocol, // a worker-side fault (e.g. TraceDiverged)
                    };
                }
            }
            try job.writeResult(Spec.MetricT, out, .{ .aggregate = .{ .agg = agg, .defect = null } });
        },
        .fork => return error.WorkerProtocol, // fork EXECUTION is a deferred seam (codec supported, not gated)
    }
}

// --- in-process executor (the determinism floor; always gateable) ---------------------------------

var inproc_ctx: u8 = 0; // ignored ctx — the Spec is baked into the thunk at comptime

/// An `Executor` that runs the job INLINE via `runJobBytes(Spec)` — no spawn, runs everywhere. Always
/// returns `.ok` (an in-process worker fault propagates as `RunError`, not a `.crashed` Outcome — a real
/// crash requires a real child, which is the subprocess executor's job to harvest).
pub fn inProcessExecutor(comptime Spec: type) Executor {
    const Impl = struct {
        fn run(_: *anyopaque, gpa: Allocator, job_bytes: []const u8, out: *serialize.ByteSink) RunError!Outcome {
            try runJobBytes(Spec, gpa, job_bytes, out);
            return .ok;
        }
    };
    return .{ .ctx = &inproc_ctx, .runFn = Impl.run };
}

// --- subprocess executor (the real one-process-per-sim mechanism) ---------------------------------

/// Context for a real-subprocess executor. `exe_path` and `job_dir` are interpreted relative to the
/// (inherited) child cwd = the parent's cwd; the child opens the job file from that same cwd, so no
/// absolute paths or cwd juggling are needed. `seq` makes each job file name unique within a run.
pub const SubprocCtx = struct {
    exe_path: []const u8,
    job_dir: []const u8,
    io: std.Io,
    timeout_ms: u32 = 5000,
    seq: u64 = 0,
};

const RESULT_CAP: usize = 16 * 1024 * 1024; // bound the child's stdout/stderr (hostile/runaway worker)

/// An `Executor` that spawns `exe_path worker <job_file>` as a real OS process, ships the job via a temp
/// file, and collects `[u32 len][GKZK1]` from the child's stdout via `std.process.run` (timeout-bounded,
/// stdin-ignored). Harvests `Term.exited(0)` → `.ok`; nonzero/`signal`/`error.Timeout` → `.crashed`;
/// `SpawnError` → `.spawn_failed`.
pub fn subprocessExecutor(ctx: *SubprocCtx) Executor {
    const Impl = struct {
        fn run(opaque_ctx: *anyopaque, gpa: Allocator, job_bytes: []const u8, out: *serialize.ByteSink) RunError!Outcome {
            const self: *SubprocCtx = @ptrCast(@alignCast(opaque_ctx));
            const io = self.io;

            // unique cwd-relative job-file path: <job_dir>/gkzjob_<seq>.gkzj
            const name = std.fmt.allocPrint(gpa, "{s}/gkzjob_{d}.gkzj", .{ self.job_dir, self.seq }) catch return error.OutOfMemory;
            defer gpa.free(name);
            self.seq += 1;

            // write the job to the temp file (relative to cwd, which the child inherits)
            writeJobFile(io, name, job_bytes) catch return error.WorkerProtocol;
            defer std.Io.Dir.cwd().deleteFile(io, name) catch {};

            const rr = std.process.run(gpa, io, .{
                .argv = &.{ self.exe_path, "worker", name },
                .stdout_limit = .limited(RESULT_CAP),
                .stderr_limit = .limited(RESULT_CAP),
                .timeout = .{ .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(self.timeout_ms) } },
            }) catch |e| switch (e) {
                error.Timeout => return .{ .crashed = .timed_out }, // run() already killed+reaped the child
                error.OutOfMemory => return error.OutOfMemory,
                error.StreamTooLong => return .{ .crashed = .{ .exited = 255 } }, // a runaway worker is a crash, not a spawn fail
                // ONLY genuine spawn-denial / resource-exhaustion is the skippable sandbox path.
                error.OperationUnsupported, error.AccessDenied, error.PermissionDenied, error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.ResourceLimitReached => return .spawn_failed,
                // everything else — FileNotFound/InvalidExe (a BROKEN exe path), a mid-stream read error,
                // etc. — is a HARD failure, never a silent skip that could hide a dead gate.
                else => return error.WorkerProtocol,
            };
            defer gpa.free(rr.stdout);
            defer gpa.free(rr.stderr);

            switch (rr.term) {
                .exited => |code| {
                    if (code != 0) return .{ .crashed = .{ .exited = code } };
                    // parse [u32 LE len][GKZK1] from stdout into `out`
                    var r = serialize.ByteReader{ .bytes = rr.stdout };
                    const len = serialize.getInt(&r, u32) catch return error.WorkerProtocol;
                    const frame = r.readSlice(len) catch return error.WorkerProtocol;
                    try out.update(frame);
                    return .ok;
                },
                .signal => |sig| return .{ .crashed = .{ .signal = @intCast(@intFromEnum(sig)) } },
                else => return .{ .crashed = .{ .exited = 255 } }, // stopped/unknown -> treat as a crash
            }
        }
    };
    return .{ .ctx = ctx, .runFn = Impl.run };
}

fn writeJobFile(io: std.Io, rel_path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, rel_path, .{});
    errdefer std.Io.Dir.cwd().deleteFile(io, rel_path) catch {}; // no partial file left if write/flush fails
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

// ---------------------------------------------------------------------------------------------------
// Tests (the in-process path + the pure dispatcher; the subprocess path is gated in proc_gate.zig)
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const worldmod = @import("../world.zig");
const q = @import("../query.zig");
const simctx = @import("../simctx.zig");
const schedule = @import("../schedule.zig");
const atommod = @import("../spec/atom.zig");
const metricmod = @import("../spec/metric.zig");

// A local Spec mirroring worker_example/shared.zig (the demo: drain hp, time-to-dead). Defined inline so
// this CORE module is testable standalone (no `gkz` named module needed).
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

fn sweepJobBytes(gpa: Allocator, lo: u64, hi: u64, max_ticks: u64) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try job.writeJob(&sink, .{ .sweep_shard = .{ .range = .{ .lo = lo, .hi = hi }, .max_ticks = max_ticks, .oracle_set_id = 0, .metric_id = 0 } });
    return buf;
}

test "runJobBytes computes the known sweep aggregate (seeds [0,3) -> sum 9)" {
    const gpa = testing.allocator;
    var jb = try sweepJobBytes(gpa, 0, 3, 6);
    defer jb.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &out, .gpa = gpa };
    try runJobBytes(TestSpec, gpa, jb.items, &sink);

    var dec = try job.decodeResult(u64, gpa, out.items);
    defer dec.deinit();
    try testing.expectEqual(@as(i128, 9), dec.result.aggregate.agg.sum); // 2+3+4
    try testing.expectEqual(@as(u64, 3), dec.result.aggregate.agg.count);
}

test "inProcessExecutor returns .ok and the same result bytes as runJobBytes" {
    const gpa = testing.allocator;
    var jb = try sweepJobBytes(gpa, 0, 3, 6);
    defer jb.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &out, .gpa = gpa };
    const ex = inProcessExecutor(TestSpec);
    const outcome = try ex.run(gpa, jb.items, &sink);
    try testing.expectEqual(Outcome.ok, outcome);
    var dec = try job.decodeResult(u64, gpa, out.items);
    defer dec.deinit();
    try testing.expectEqual(@as(i128, 9), dec.result.aggregate.agg.sum);
}

test "runJobBytes rejects an unknown metric_id (WorkerProtocol) and the fork arm (deferred)" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &out, .gpa = gpa };

    var bad: std.ArrayList(u8) = .empty;
    defer bad.deinit(gpa);
    var bsink = serialize.ByteSink{ .list = &bad, .gpa = gpa };
    try job.writeJob(&bsink, .{ .sweep_shard = .{ .range = .{ .lo = 0, .hi = 1 }, .max_ticks = 1, .oracle_set_id = 0, .metric_id = 99 } });
    try testing.expectError(error.WorkerProtocol, runJobBytes(TestSpec, gpa, bad.items, &sink));
}
