//! The across-machines execution transport (SPEC §13, PLAN.md §17.4): a third `Executor` impl, alongside
//! `inProcessExecutor` (the determinism floor) and `subprocessExecutor` (one OS process per sim). This one
//! ships the job over a TCP stream to a `net_worker` daemon — which need not be on this host. It closes the
//! proc-gate's stated gap ("nor MULTI-MACHINE equality (a deferred seam)"): nothing here assumes a local
//! peer; the gate proves byte-equality over a REAL kernel TCP socket (localhost is merely the test substrate).
//!
//! The byte interface is registry-agnostic exactly like the other executors — `[u32 LE len][GKZJ1 job]` out,
//! `[u32 LE len][GKZK1 result]` back — so the SAME `runJobBytes(Spec)` runs whether in-process, in a child,
//! or across the network; an R mismatch is caught by the GKZJ1/GKZK1 magic+version header and the gate's
//! byte-equality assertion (the dlopen-gate discipline).
//!
//! Peer-failure harvesting (coarse `Outcome`, never a parent crash OR hang): a peer that REFUSES the
//! connection or is unreachable → `.spawn_failed` (no peer — the honest skip path, like a denied subprocess
//! spawn); a peer that DIES mid-exchange (EOF/reset before a full result) → `.crashed.exited`; and a peer
//! that completes the TCP handshake, accepts the job, then STALLS forever without replying — the case the
//! subprocess executor handles with `std.process.run`'s timeout — → `.crashed.timed_out`. The stall bound is
//! the 0.16 way: the whole connect→write→read exchange runs as ONE `io.concurrent` task raced against a
//! timer in an `Io.Select`; whichever finishes first wins, the loser is `cancelDiscard`'d. On `Io.Threaded`
//! cancelation interrupts the blocked `recv` via a signal (`EINTR`), so a wedged peer is genuinely unblocked
//! — the `Reader` surfaces that as a generic read error (`ReadFailed`, NOT `error.Canceled`), but it does
//! not matter WHICH error doExchange returns on the timeout path: the deadline is decided by the `.timer`
//! Select branch winning, and the loser's result is discarded. No `SO_RCVTIMEO` (the backend bug-asserts on
//! a recv `EAGAIN`) and no connect-timeout `@panic`. The exchange task OWNS its stream (`defer stream.close`),
//! so a canceled exchange still releases the socket.
//! `timeout_ms == 0` (the default) means no deadline. On a single-threaded `Io` (no concurrency) the deadline
//! cannot be enforced concurrently, so the exchange runs inline unbounded — the documented single-threaded
//! degradation, surfaced via `ConcurrencyUnavailable`, never a silent claim of a deadline that isn't there.

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const executor = @import("executor.zig");
const RunError = executor.RunError;
const Outcome = executor.Outcome;
const net = std.Io.net;

const RESULT_CAP: usize = 16 * 1024 * 1024; // bound a hostile/runaway peer's result frame

/// Connection target for a `networkExecutor`. `host`/`port` name the `net_worker` daemon (IPv4 dotted-quad).
/// `timeout_ms` bounds the WHOLE exchange (connect+write+read); `0` = unbounded (the prior behavior). A
/// stalled-but-alive peer past the deadline is harvested as `.crashed.timed_out` (the subprocess executor's
/// `std.process.run` timeout, lifted to TCP via `Io.Select` cancelation — see the module doc).
pub const NetCtx = struct {
    io: std.Io,
    host: []const u8,
    port: u16,
    timeout_ms: u32 = 0,
};

/// The full connect→write→read exchange, owning its stream (so cancelation — the deadline path — closes the
/// socket via `defer`). Returns the coarse `Outcome`; cancelation maps to `.crashed.timed_out` (it is
/// discarded on the timeout path anyway). This is what `run` races against a timer when `timeout_ms > 0`.
fn doExchange(self: *NetCtx, gpa: Allocator, job_bytes: []const u8, out: *serialize.ByteSink) RunError!Outcome {
    const io = self.io;
    const addr = net.IpAddress.parseIp4(self.host, self.port) catch return .spawn_failed; // bad host literal
    var stream = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch |e| switch (e) {
        error.ConnectionRefused => return .spawn_failed, // no daemon listening
        error.HostUnreachable, error.NetworkUnreachable, error.NetworkDown, error.AddressUnavailable, error.AddressFamilyUnsupported => return .spawn_failed,
        error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => return .spawn_failed,
        error.AccessDenied => return .spawn_failed,
        error.Timeout, error.Canceled => return .{ .crashed = .timed_out }, // deadline cancelation during connect
        error.ConnectionResetByPeer => return .{ .crashed = .{ .exited = 255 } },
        else => return error.WorkerProtocol, // ConnectionPending/WouldBlock/Option|Protocol|Mode-unsupported/Unexpected — a config/impl bug, surfaced loudly
    };
    defer stream.close(io);

    // send [u32 LE len][job_bytes]; a write failure ⇒ the peer is gone ⇒ a crash, not a hang.
    {
        var wbuf: [8192]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        const w = &sw.interface;
        var lh: [4]u8 = undefined;
        std.mem.writeInt(u32, &lh, @intCast(job_bytes.len), .little);
        w.writeAll(&lh) catch return .{ .crashed = .{ .exited = 255 } };
        w.writeAll(job_bytes) catch return .{ .crashed = .{ .exited = 255 } };
        w.flush() catch return .{ .crashed = .{ .exited = 255 } };
    }

    // read [u32 LE len][GKZK1] — EOF before a full frame ⇒ the peer died; a deadline cancel ⇒ Canceled (the
    // blocked recv is signal-interrupted) ⇒ timed_out. Both are discarded on the timeout path.
    var rbuf: [8192]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;
    // The Reader interface folds a signal-interrupted recv into ReadFailed (it does not surface Canceled),
    // so on the deadline path takeArray/readAlloc just error out here — and `run`'s `.timer` Select branch is
    // what reports `timed_out`; this branch's return is discarded on that path.
    const lh = r.takeArray(4) catch return .{ .crashed = .{ .exited = 255 } }; // EOF/ReadFailed ⇒ peer gone (or canceled)
    const len = std.mem.readInt(u32, lh, .little);
    if (len > RESULT_CAP) return error.WorkerProtocol; // runaway/hostile peer
    const frame = r.readAlloc(gpa, len) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .crashed = .{ .exited = 255 } }, // truncated frame ⇒ peer died mid-result (or canceled)
    };
    defer gpa.free(frame);
    try out.update(frame);
    return .ok;
}

fn deadlineTimer(io: std.Io, ms: u32) void {
    io.sleep(std.Io.Duration.fromMilliseconds(ms), .awake) catch {}; // canceled (exchange won) → just return
}

/// An `Executor` that ships `job_bytes` to a TCP `net_worker` and reads back its GKZK1 result.
///   * connect refused / host or net unreachable / resource-exhaustion → `.spawn_failed` (no peer — the
///     gate's honest skip path, exactly like a denied subprocess spawn; never a silent in-process fallback).
///   * connect cancellation → `.crashed.timed_out`.
///   * peer died mid-exchange (EOF before a full result, reset) → `.crashed.exited(255)`.
///   * a malformed result header or an over-cap length → `error.WorkerProtocol`.
pub fn networkExecutor(ctx: *NetCtx) executor.Executor {
    const Impl = struct {
        fn run(opaque_ctx: *anyopaque, gpa: Allocator, job_bytes: []const u8, out: *serialize.ByteSink) RunError!Outcome {
            const self: *NetCtx = @ptrCast(@alignCast(opaque_ctx));
            if (self.timeout_ms == 0) return doExchange(self, gpa, job_bytes, out); // unbounded (default)

            // Race the whole exchange against a deadline timer; the first to finish wins, the loser is
            // canceled+joined. On Io.Threaded, cancelation signal-interrupts a blocked recv (EINTR), so a
            // stalled peer is genuinely unblocked rather than hanging the dispatcher; the deadline outcome is
            // decided by the `.timer` branch winning, not by the (discarded) canceled-exchange return value.
            const io = self.io;
            const Winner = union(enum) { done: RunError!Outcome, timer: void };
            var buf: [2]Winner = undefined;
            var sel = std.Io.Select(Winner).init(io, &buf);
            sel.concurrent(.done, doExchange, .{ self, gpa, job_bytes, out }) catch {
                return doExchange(self, gpa, job_bytes, out); // ConcurrencyUnavailable (single-threaded) → inline, unbounded
            };
            sel.async(.timer, deadlineTimer, .{ io, self.timeout_ms });
            const first = sel.await() catch {
                sel.cancelDiscard(); // the awaiting fiber itself was canceled — join both tasks, surface as a stall
                return .{ .crashed = .timed_out };
            };
            sel.cancelDiscard(); // join the loser; doExchange's `defer stream.close` releases its socket on cancel
            return switch (first) {
                .done => |res| res, // RunError!Outcome — propagate the exchange's outcome/error
                .timer => .{ .crashed = .timed_out }, // the deadline beat the peer
            };
        }
    };
    return .{ .ctx = ctx, .runFn = Impl.run };
}

// ---------------------------------------------------------------------------------------------------
// Tests — the connect-failure mapping (no peer → spawn_failed, never a hang). The full TCP round-trip +
// byte-equality vs inProcessExecutor is gated in proc_gate.zig (a real net_worker in an Io.Group).
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

fn silentServe(io: std.Io, server: *net.Server, out_err: *?anyerror) void {
    var stream = server.accept(io) catch |e| {
        out_err.* = e;
        return;
    };
    defer stream.close(io);
    io.sleep(std.Io.Duration.fromMilliseconds(10_000), .awake) catch {}; // accept, then NEVER reply (until canceled)
}

test "a connected-but-silent peer is harvested as .crashed.timed_out (the deadline fires, no hang)" {
    const gpa = testing.allocator;
    const io = testing.io;
    const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
    var server = net.IpAddress.listen(&addr, io, .{ .reuse_address = true }) catch return error.SkipZigTest; // no networking → honest skip
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var serr: ?anyerror = null;
    var grp: std.Io.Group = .init;
    grp.async(io, silentServe, .{ io, &server, &serr });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &out, .gpa = gpa };
    var ctx = NetCtx{ .io = io, .host = "127.0.0.1", .port = port, .timeout_ms = 200 };
    const outcome = try networkExecutor(&ctx).run(gpa, "dummy-job-bytes", &sink);
    grp.cancel(io); // wake the still-sleeping server fiber so the test doesn't wait the full 10s
    if (serr) |e| if (e != error.Canceled) return e;
    // a peer that connected but never replied is bounded by the deadline — not an infinite parent hang.
    try testing.expectEqual(Outcome{ .crashed = .timed_out }, outcome);
}

test "connecting to a dead port is .spawn_failed (no peer; never a parent hang)" {
    const gpa = testing.allocator;
    // port 1 on loopback: nothing listens → ConnectionRefused → .spawn_failed (the honest no-peer outcome).
    var ctx = NetCtx{ .io = testing.io, .host = "127.0.0.1", .port = 1 };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &out, .gpa = gpa };
    const outcome = try networkExecutor(&ctx).run(gpa, "ignored-job-bytes", &sink);
    try testing.expectEqual(Outcome.spawn_failed, outcome);
}

test "a malformed host literal is .spawn_failed (never a panic)" {
    const gpa = testing.allocator;
    var ctx = NetCtx{ .io = testing.io, .host = "not-an-ip", .port = 9 };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &out, .gpa = gpa };
    try testing.expectEqual(Outcome.spawn_failed, try networkExecutor(&ctx).run(gpa, "x", &sink));
}
