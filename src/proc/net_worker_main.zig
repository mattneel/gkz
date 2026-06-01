//! The standalone §13 network worker daemon (PLAN.md §17.4) — the cross-PROCESS (and, by construction,
//! cross-MACHINE) peer the proc gate spawns to prove the `networkExecutor` transport over a REAL OS process
//! boundary, closing the gate's prior "nor MULTI-MACHINE equality (a deferred seam)" gap. R is pinned via
//! `worker_example/shared.zig` (the worker_main.zig pattern) so the daemon and the parent share the byte
//! layout by construction. Production deployments run their own registry's equivalent.
//!
//! Invocation: `gkz_net_worker net-worker <n_requests>`. It binds a loopback TCP ephemeral port, writes the
//! assigned port as a 4-byte LE u32 to stdout (a fixed-width handshake — no delimiter parsing, no ambiguity)
//! and flushes, then serves `n_requests` jobs via `runNetWorker` and exits 0. The parent reads the 4 port
//! bytes, connects, dispatches, and reaps the child.

const std = @import("std");
const gkz = @import("gkz");
const shared = @import("worker_example/shared.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or !std.mem.eql(u8, args[1], "net-worker")) return error.BadWorkerArgs;
    const n_requests = try std.fmt.parseInt(usize, args[2], 10);

    var server = try gkz.proc.listenLoopback(io, 0); // OS-assigned ephemeral port
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    // fixed-width port handshake: 4-byte LE u32 to stdout, flushed BEFORE accepting (so the parent can read
    // the port, then connect → we accept). No deadlock: we publish before we block on accept.
    var sbuf: [16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &sbuf);
    const w = &fw.interface;
    var pb: [4]u8 = undefined;
    std.mem.writeInt(u32, &pb, port, .little);
    try w.writeAll(&pb);
    try w.flush();

    try gkz.proc.runNetWorker(shared, io, gpa, &server, n_requests);
}
