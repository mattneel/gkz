//! The one-shot worker entry logic (PLAN.md Phase 9, §13), shared by the dedicated gate exe
//! (`worker_main.zig`) and the production `worker` CLI subcommand (`main.zig`). A worker is a SINGLE job:
//! read the GKZJ1 job from `argv[2]`, run it against the comptime `Spec` (the R-fixed systems/metric
//! tables), write `[u32 LE len][GKZK1]` to stdout, exit. One process per job is the §13 crash-isolation
//! unit — a fault kills only this child, and the parent harvests it as a repro (the supervisor).
//!
//! The poison `oracle_set_id`s exist ONLY for the gate's crash/hang sub-gates (a normal job never sets
//! them): they make a worker deliberately abort (a real SIGABRT to harvest) or hang (so the parent's
//! timeout-kill path is exercised). This is how the gate proves cross-process crash handling is real and
//! not a disguised in-process call.

const std = @import("std");
const serialize = @import("../serialize.zig");
const job = @import("job.zig");
const executor = @import("executor.zig");

/// A job whose `sweep_shard.oracle_set_id` is this value makes the worker abort (gate crash sub-gate).
pub const POISON_CRASH: u16 = 0xFFFF;
/// …this value makes the worker hang forever (gate hang/timeout sub-gate).
pub const POISON_HANG: u16 = 0xFFFE;
/// …this value makes the worker sleep ~150ms before computing (then return a NORMAL result) — the gate's
/// concurrency sub-gate uses it to prove parallel dispatch genuinely OVERLAPS workers (N sleeps finish in
/// ~1 sleep when concurrent, ~N sleeps when serialized).
pub const POISON_SLEEP: u16 = 0xFFFD;
pub const POISON_SLEEP_MS: u64 = 150;

const JOB_CAP: usize = 64 * 1024 * 1024; // bound the job-file read (the job comes from our own supervisor)

/// Run one worker job to completion against `Spec`. `argv` must be `<exe> worker <job_file>`.
pub fn runWorker(comptime Spec: type, init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or !std.mem.eql(u8, args[1], "worker")) return error.BadWorkerArgs;
    const job_path = args[2];

    const job_bytes = try std.Io.Dir.cwd().readFileAlloc(io, job_path, gpa, .limited(JOB_CAP));
    defer gpa.free(job_bytes);

    // poison harness (gate-only): decode once to check for the deliberate crash/hang markers.
    {
        var dec = try job.decodeJob(gpa, job_bytes);
        defer dec.deinit();
        switch (dec.job) {
            .sweep_shard => |s| {
                if (s.oracle_set_id == POISON_CRASH) std.process.abort(); // SIGABRT — a real crash to harvest
                if (s.oracle_set_id == POISON_HANG) {
                    while (true) {} // the parent's timeout-kill path must reap us
                }
                if (s.oracle_set_id == POISON_SLEEP) {
                    const dur = std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(POISON_SLEEP_MS) };
                    dur.sleep(io) catch {}; // then fall through to compute the NORMAL result
                }
            },
            else => {},
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &out, .gpa = gpa };
    try executor.runJobBytes(Spec, gpa, job_bytes, &sink);

    // frame the result as [u32 LE len][GKZK1] on stdout
    var sbuf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &sbuf);
    const w = &fw.interface;
    var lenbuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenbuf, @intCast(out.items.len), .little);
    try w.writeAll(&lenbuf);
    try w.writeAll(out.items);
    try w.flush();
}
