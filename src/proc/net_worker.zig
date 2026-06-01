//! The TCP worker daemon (SPEC §13, PLAN.md §17.4): the network peer a `net_executor` ships jobs to. It is
//! the socket twin of `worker.runWorker` — read a GKZJ1 job, run it against the comptime `Spec` (the R-fixed
//! tables) via the SHARED `executor.runJobBytes`, write the GKZK1 result — so a job computed across the
//! network is bit-identical to the in-process and subprocess paths (same dispatcher, only the transport
//! differs). One job per connection (the `net_executor` opens a fresh connection per `run()`), mirroring the
//! one-process-per-job crash-isolation unit.
//!
//! A worker-side FAULT (a non-OOM `runJobBytes` error — e.g. a diverged trace, a bad metric id) closes the
//! connection WITHOUT a reply, so the `net_executor` peer sees EOF and harvests a `.crashed` — the network
//! analog of a child exiting nonzero. OOM is fatal (propagated). The poison markers from `worker.zig` are
//! honored identically so the gate can exercise the crash path over TCP too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const job = @import("job.zig");
const executor = @import("executor.zig");
const worker = @import("worker.zig");
const net = std.Io.net;

const JOB_CAP: usize = 64 * 1024 * 1024; // bound a single job frame (defensive against a hostile/runaway peer)

/// Serve up to `n_requests` jobs on `server` (a bound TCP listener), one job per accepted connection,
/// running each against `Spec`. Run it in an `Io.Group` alongside a `net_executor` client (the proc gate),
/// or as the main loop of a standalone daemon exe (`net_worker_main.zig`). Returns after `n_requests`
/// connections (so the gate can bound the daemon's lifetime deterministically).
pub fn runNetWorker(comptime Spec: type, io: std.Io, gpa: Allocator, server: *net.Server, n_requests: usize) !void {
    var i: usize = 0;
    while (i < n_requests) : (i += 1) {
        var stream = try server.accept(io);
        defer stream.close(io);

        var rbuf: [8192]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        const r = &sr.interface;
        const lh = r.takeArray(4) catch |e| switch (e) {
            error.EndOfStream => continue, // peer connected then closed without a job — just move on
            else => return e,
        };
        const len = std.mem.readInt(u32, lh, .little);
        if (len > JOB_CAP) continue; // hostile length: drop the connection (peer harvests EOF as a crash)
        const job_bytes = r.readAlloc(gpa, len) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue, // truncated job → drop (peer sees EOF)
        };
        defer gpa.free(job_bytes);

        // poison harness (gate-only) — identical to worker.runWorker, so the crash path is exercised over TCP.
        if (poisoned(gpa, job_bytes)) |p| switch (p) {
            .crash => std.process.abort(),
            // hang via a YIELDING loop, not a bare `while (true) {}`: when runNetWorker is a fiber in an
            // in-process Io.Group (its documented usage), a non-yielding spin would wedge the whole event
            // loop (and group.await) with no cancellation point; sleeping in a loop keeps it cancellable
            // while still never returning a result (the peer harvests a timeout/crash).
            .hang => while (true) {
                const dur = std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(1000) };
                dur.sleep(io) catch return; // cancellation (or any io error) ends the fiber cleanly
            },
            .sleep => {
                const dur = std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(worker.POISON_SLEEP_MS) };
                dur.sleep(io) catch {};
            },
        };

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var sink = serialize.ByteSink{ .list = &out, .gpa = gpa };
        executor.runJobBytes(Spec, gpa, job_bytes, &sink) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue, // a worker-side fault → no reply → peer harvests a .crashed (the §9 repro)
        };

        var wbuf: [8192]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        const w = &sw.interface;
        var ol: [4]u8 = undefined;
        std.mem.writeInt(u32, &ol, @intCast(out.items.len), .little);
        try w.writeAll(&ol);
        try w.writeAll(out.items);
        try w.flush();
    }
}

const Poison = enum { crash, hang, sleep };

/// Decode just enough to detect a poison marker (gate-only); a malformed job is not poison (it falls through
/// to `runJobBytes`, which rejects it as a worker fault).
fn poisoned(gpa: Allocator, job_bytes: []const u8) ?Poison {
    var dec = job.decodeJob(gpa, job_bytes) catch return null;
    defer dec.deinit();
    switch (dec.job) {
        .sweep_shard => |s| return switch (s.oracle_set_id) {
            worker.POISON_CRASH => .crash,
            worker.POISON_HANG => .hang,
            worker.POISON_SLEEP => .sleep,
            else => null,
        },
        else => return null,
    }
}

/// Bind a loopback TCP listener on `port` (0 ⇒ an OS-assigned ephemeral port), returning the `Server`. The
/// assigned port is readable via `server.socket.address.getPort()` (the standalone daemon prints it to
/// stdout so a parent/operator can connect).
pub fn listenLoopback(io: std.Io, port: u16) !net.Server {
    const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
    return net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
}

const testing = std.testing;
test "listenLoopback binds an ephemeral port that is then readable" {
    const io = testing.io;
    var server = listenLoopback(io, 0) catch return error.SkipZigTest; // no networking in this sandbox → honest skip
    defer server.deinit(io);
    try testing.expect(server.socket.address.getPort() != 0); // the OS assigned a real port
}
