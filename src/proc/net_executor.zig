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
//! Peer-failure harvesting (coarse `Outcome`, never a parent crash): a peer that REFUSES the connection or
//! is unreachable → `.spawn_failed` (no peer — the honest skip path, like a denied subprocess spawn); a peer
//! that DIES mid-exchange (EOF/reset before a full result) → `.crashed`. NOT bounded here: a peer that
//! completes the TCP handshake, accepts the job, then STALLS forever without replying or closing — the
//! blocking framed read has no per-read deadline (the 0.16 Threaded backend `@panic`s on a connect timeout
//! and maps a recv `EAGAIN` to a bug-assert, so neither a connect timeout nor `SO_RCVTIMEO` is usable here).
//! Bounding a live-stall is therefore the caller's responsibility (an `Io` deadline around `.run`, or the
//! Supervisor's orchestration) — a DECLARED refinement, not a hidden gap; the gated `net_worker` always
//! replies promptly. (The subprocess executor, whose child it must reap, does carry a `std.process.run`
//! timeout; the TCP path's equivalent total-deadline is the named follow-on.)

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const executor = @import("executor.zig");
const RunError = executor.RunError;
const Outcome = executor.Outcome;
const net = std.Io.net;

const RESULT_CAP: usize = 16 * 1024 * 1024; // bound a hostile/runaway peer's result frame

/// Connection target for a `networkExecutor`. `host`/`port` name the `net_worker` daemon (IPv4 dotted-quad).
/// (No connect/read timeout field: the 0.16 Threaded backend `@panic`s on a non-`.none` connect timeout, so
/// exposing one would be a footgun — see the module doc on the declared live-stall refinement.)
pub const NetCtx = struct {
    io: std.Io,
    host: []const u8,
    port: u16,
};

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
            const io = self.io;

            const addr = net.IpAddress.parseIp4(self.host, self.port) catch return .spawn_failed; // bad host literal
            var stream = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch |e| switch (e) {
                error.ConnectionRefused => return .spawn_failed, // no daemon listening
                error.HostUnreachable, error.NetworkUnreachable, error.NetworkDown, error.AddressUnavailable, error.AddressFamilyUnsupported => return .spawn_failed,
                error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => return .spawn_failed,
                error.AccessDenied => return .spawn_failed,
                error.Timeout, error.Canceled => return .{ .crashed = .timed_out },
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

            // read [u32 LE len][GKZK1] — EOF before a full frame ⇒ the peer died (a crash to harvest).
            var rbuf: [8192]u8 = undefined;
            var sr = stream.reader(io, &rbuf);
            const r = &sr.interface;
            const lh = r.takeArray(4) catch return .{ .crashed = .{ .exited = 255 } };
            const len = std.mem.readInt(u32, lh, .little);
            if (len > RESULT_CAP) return error.WorkerProtocol; // runaway/hostile peer
            const frame = r.readAlloc(gpa, len) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .crashed = .{ .exited = 255 } }, // truncated frame ⇒ peer died mid-result
            };
            defer gpa.free(frame);
            try out.update(frame);
            return .ok;
        }
    };
    return .{ .ctx = ctx, .runFn = Impl.run };
}

// ---------------------------------------------------------------------------------------------------
// Tests — the connect-failure mapping (no peer → spawn_failed, never a hang). The full TCP round-trip +
// byte-equality vs inProcessExecutor is gated in proc_gate.zig (a real net_worker in an Io.Group).
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

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
