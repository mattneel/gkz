//! The §13 query server (PLAN.md Phase 9): the IO shell around the ALREADY-PURE `query/wire.respond()`
//! (unchanged — wire.zig anticipates exactly this). It multiplexes the §7 relational surface across live
//! sims: a `SimRegistry` maps a `u32 sim_id` to a borrowed `*const World` + `*const EventLog`, and a
//! request frame `[u32 sim_id][GKZQ1]` routes to `respond()` against the chosen sim's Engine, replying
//! `[GKZR1]`. The Engine borrows `*const` (D1: the server never mutates a World).
//!
//! `handle()` is the multiplexing CORE — pure-ish (no IO), testable everywhere, byte-equal to calling
//! `respond()` directly. `serveUnix()` is the REAL socket transport: a `std.Io.net` Unix-domain accept
//! loop (no TCP port to collide in CI) that frames `[u32 len][u32 sim_id][GKZQ1]` requests and `[u32 len]
//! [GKZR1]` replies over `handle`. The proc gate runs it in an `Io.Group` with a real client and asserts
//! the socket reply equals `respond()` byte-for-byte. Auth/TLS, a persistent multi-request connection, and
//! a live worker-attach registry are the deferred control-plane refinements.

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const wire = @import("../query/wire.zig");
const engine = @import("../query/engine.zig");
const worldmod = @import("../world.zig");
const EventLog = @import("../event_log.zig").EventLog;
const Sys = @import("../schedule.zig").Sys;
const net = std.Io.net;

pub const ServerError = error{UnknownSim} || serialize.Error || Allocator.Error;

pub fn QueryServer(comptime R: type, comptime systems: []const Sys(R)) type {
    return struct {
        const Self = @This();
        /// A borrowed live sim: its World + provenance log (both `*const` — read-only, D1).
        pub const Handle = struct { world: *const worldmod.World(R), log: *const EventLog };

        gpa: Allocator,
        sims: std.AutoHashMapUnmanaged(u32, Handle) = .empty,

        pub fn deinit(self: *Self) void {
            self.sims.deinit(self.gpa);
            self.* = undefined;
        }

        pub fn register(self: *Self, sim_id: u32, world: *const worldmod.World(R), log: *const EventLog) Allocator.Error!void {
            try self.sims.put(self.gpa, sim_id, .{ .world = world, .log = log });
        }
        pub fn unregister(self: *Self, sim_id: u32) void {
            _ = self.sims.remove(sim_id);
        }

        /// Route one request frame `[u32 LE sim_id][GKZQ1 query]` → write the `[GKZR1]` reply into `out`.
        /// An unknown sim_id is `error.UnknownSim` (the socket transport turns that into an error frame;
        /// never a panic). On the happy path the bytes are IDENTICAL to calling `respond()` directly. This
        /// is the multiplexing CORE; the IO transport (below) is a thin shell over it.
        pub fn handle(self: *Self, gpa: Allocator, frame: []const u8, out: *serialize.ByteSink) ServerError!void {
            var r = serialize.ByteReader{ .bytes = frame };
            const sim_id = try serialize.getInt(&r, u32);
            const h = self.sims.get(sim_id) orelse return error.UnknownSim;
            const eng = engine.Engine(R, systems).init(h.world, h.log);
            try wire.respond(R, systems, gpa, eng, frame[r.pos..], out);
        }

        /// The real socket transport: accept up to `n_requests` connections on `server` (a bound
        /// `std.Io.net` Unix-domain listener), and for each read a length-framed `[u32 len][u32 sim_id]
        /// [GKZQ1]` request, route it via `handle`, and write a length-framed `[u32 len][GKZR1]` reply.
        /// One request per connection (a persistent multi-request connection is a refinement). Run it in
        /// an `Io.Group` alongside the client (the proc gate does exactly this). A malformed/unknown
        /// request replies an empty frame rather than aborting the server (a typed error frame is a
        /// deferred refinement); OOM propagates.
        pub fn serveUnix(self: *Self, io: std.Io, gpa: Allocator, server: *net.Server, n_requests: usize) !void {
            var i: usize = 0;
            while (i < n_requests) : (i += 1) {
                var stream = try server.accept(io);
                defer stream.close(io);

                var rbuf: [4096]u8 = undefined;
                var sr = stream.reader(io, &rbuf);
                const r = &sr.interface;
                const len = std.mem.readInt(u32, try r.takeArray(4), .little);
                const frame = try r.readAlloc(gpa, len);
                defer gpa.free(frame);

                var resp: std.ArrayList(u8) = .empty;
                defer resp.deinit(gpa);
                var osink = serialize.ByteSink{ .list = &resp, .gpa = gpa };
                self.handle(gpa, frame, &osink) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {}, // unknown sim / malformed request → empty reply, server stays up
                };

                var wbuf: [4096]u8 = undefined;
                var sw = stream.writer(io, &wbuf);
                const w = &sw.interface;
                var lh: [4]u8 = undefined;
                std.mem.writeInt(u32, &lh, @intCast(resp.items.len), .little);
                try w.writeAll(&lh);
                try w.writeAll(resp.items);
                try w.flush();
            }
        }
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests (handle() parity — the multiplexing core; the socket is gated in proc_gate.zig)
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const q = @import("../query.zig");
const simctx = @import("../simctx.zig");
const schedule = @import("../schedule.zig");
const term = @import("../query/term.zig");

const Position = struct {
    x: i64,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Position});
fn rP(ctx: *simctx.SimCtx(Game), qq: *q.Query(Game, .{q.Read(Position)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = qq;
}
const demo_systems = [_]Sys(Game){schedule.system(Game, "rP", rP)};

fn componentQueryFrame(gpa: Allocator, sim_id: u32) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try serialize.putInt(&sink, u32, sim_id);
    // a component query filtered to Position (kind 1) — the GKZQ1 query bytes follow the sim_id
    try wire.writeQuery(&sink, Game, .{ .component = .{ .kind = 1 } });
    return buf;
}

test "handle() routes to the right sim and is byte-identical to respond() directly" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Position, .{ .x = 42 });
    var log = EventLog{};
    defer log.deinit(gpa);

    var srv = QueryServer(Game, &demo_systems){ .gpa = gpa };
    defer srv.deinit();
    try srv.register(7, &w, &log);

    var frame = try componentQueryFrame(gpa, 7);
    defer frame.deinit(gpa);

    // via the server
    var via_srv: std.ArrayList(u8) = .empty;
    defer via_srv.deinit(gpa);
    var s1 = serialize.ByteSink{ .list = &via_srv, .gpa = gpa };
    try srv.handle(gpa, frame.items, &s1);

    // directly via respond() against the same Engine + the same GKZQ1 bytes (strip the 4-byte sim_id)
    var direct: std.ArrayList(u8) = .empty;
    defer direct.deinit(gpa);
    var s2 = serialize.ByteSink{ .list = &direct, .gpa = gpa };
    const eng = engine.Engine(Game, &demo_systems).init(&w, &log);
    try wire.respond(Game, &demo_systems, gpa, eng, frame.items[4..], &s2);

    try testing.expectEqualSlices(u8, direct.items, via_srv.items);
    try testing.expect(via_srv.items.len > 0);
}

test "handle() returns UnknownSim for an unregistered id (never a panic)" {
    const gpa = testing.allocator;
    var srv = QueryServer(Game, &demo_systems){ .gpa = gpa };
    defer srv.deinit();
    var frame = try componentQueryFrame(gpa, 999);
    defer frame.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &out, .gpa = gpa };
    try testing.expectError(error.UnknownSim, srv.handle(gpa, frame.items, &sink));
}
