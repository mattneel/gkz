//! Hot-reload as a comptime system-set SWAP (PLAN.md Phase 8, §12).
//!
//! The §12 "reload the simulation logic without losing state" requirement reduces to a one-line
//! mechanism in this kernel: `step`/`runScheduled` already take the system set as a `comptime systems`
//! slice, and the World owns ZERO function pointers (step.zig) — so "reloading" is simply running a
//! DIFFERENT comptime `[]const Sys(R)` over the SAME World value at a tick boundary. There is no step-path
//! code to add and no World mutation: `reloadAt` is a World no-op that returns the next `SystemSet`.
//!
//! Because the swap changes only which pure systems run (never the World's bytes), determinism is
//! preserved BY CONSTRUCTION: a reload-to-the-SAME set produces a bit-identical per-tick hash stream
//! (proven below via `run.captureStream` + `run.streamDigest`), and a reload-to-a-DIFFERENT set is
//! observable exactly as a trajectory DIVERGENCE — the same signal the VOPR's `oracle.divergence` folds
//! into a `Defect` (`oracle.firstDivergentTick`). The kernel cannot prove opaque reloaded code
//! deterministic (§15 trusts the author); what it CAN do — and does — is DETECT a divergent reload.
//!
//! `SystemSource(R)` is the seam a real loader plugs into: `inProcessSource` (built + tested) wraps a
//! comptime set; `NativeLibSource` is a typed `error.NotImplemented` stub shaped exactly like a future
//! `std.DynLib` impl resolving an exported `gkz_systems` symbol. The actual `dlopen`/shared-object build
//! rule + file-watcher trigger are deferred (the swap + VOPR validation are identical regardless of what
//! triggers the load).

const std = @import("std");
const schedule = @import("schedule.zig");
const Sys = schedule.Sys;

/// A named set of systems to run. A thin wrapper over a `[]const Sys(R)`; when the wrapped slice is a
/// comptime constant it can be handed straight to `step`/`captureStream`'s `comptime systems` parameter.
pub fn SystemSet(comptime R: type) type {
    return struct { systems: []const Sys(R) };
}

/// Perform a reload at a tick boundary: select the `next` system set. This is a World NO-OP — a reload
/// never touches simulation state, only which systems execute from here on. (Returning `next` keeps the
/// call site honest: the World flows through untouched; only the set changes.)
pub fn reloadAt(comptime R: type, current: SystemSet(R), next: SystemSet(R)) SystemSet(R) {
    _ = current;
    return next;
}

/// The seam a reload trigger (build/watch driver, control plane) calls to obtain the next system set.
/// `load` may fail (a real loader can fail to open/resolve a library); `unload` releases a prior load.
pub fn SystemSource(comptime R: type) type {
    return struct {
        const Self = @This();
        ctx: *anyopaque,
        loadFn: *const fn (*anyopaque) anyerror!SystemSet(R),
        unloadFn: *const fn (*anyopaque) void,

        pub fn load(self: Self) anyerror!SystemSet(R) {
            return self.loadFn(self.ctx);
        }
        pub fn unload(self: Self) void {
            self.unloadFn(self.ctx);
        }
    };
}

var in_process_ctx: u8 = 0; // an ignored ctx — the systems are baked into the thunk at comptime

/// A `SystemSource` that returns a fixed comptime system set (the in-process, no-dynamic-loading path —
/// the trigger differs from a real loader, the swap semantics are identical).
pub fn inProcessSource(comptime R: type, comptime systems: []const Sys(R)) SystemSource(R) {
    const Impl = struct {
        fn load(_: *anyopaque) anyerror!SystemSet(R) {
            return .{ .systems = systems };
        }
        fn unload(_: *anyopaque) void {}
    };
    return .{ .ctx = &in_process_ctx, .loadFn = Impl.load, .unloadFn = Impl.unload };
}

/// A typed stub for a future native shared-object loader. Shaped exactly like a real `std.DynLib` impl
/// (open `path`, resolve an exported `gkz_systems` symbol, wrap it as a `SystemSet`); only the body is
/// unimplemented. `source().load()` returns `error.NotImplemented`.
pub fn NativeLibSource(comptime R: type) type {
    return struct {
        const Self = @This();
        path: []const u8,

        fn loadImpl(_: *anyopaque) anyerror!SystemSet(R) {
            return error.NotImplemented; // a real impl: std.DynLib.open(path) -> lookup("gkz_systems")
        }
        fn unloadImpl(_: *anyopaque) void {}

        pub fn source(self: *Self) SystemSource(R) {
            return .{ .ctx = self, .loadFn = loadImpl, .unloadFn = unloadImpl };
        }
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("registry.zig").Registry;
const worldmod = @import("world.zig");
const W = worldmod.World;
const query = @import("query.zig");
const Read = query.Read;
const Write = query.Write;
const Query = query.Query;
const simctx = @import("simctx.zig");
const SimCtx = simctx.SimCtx;
const system = schedule.system;
const Schedule = schedule.Schedule;
const input = @import("input.zig");
const run = @import("vopr/run.zig");
const oracle = @import("vopr/oracle.zig");

const Position = struct {
    x: fpz.Fixed,
    pub const kind_id: u16 = 1;
};
const Velocity = struct {
    dx: fpz.Fixed,
    pub const kind_id: u16 = 2;
};
const Reg = Registry(.{ Position, Velocity });

fn moveSystem(ctx: *SimCtx(Reg), q: *Query(Reg, .{ Read(Velocity), Write(Position) })) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Position).x = row.write(Position).x.addSat(row.read(Velocity).dx);
}
// the "reloaded" logic: also accelerates (a deterministic trajectory change)
fn jitterSystem(ctx: *SimCtx(Reg), q: *Query(Reg, .{Write(Velocity)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Velocity).dx = row.write(Velocity).dx.addSat(fpz.Fixed.ONE);
}

const move_only = [_]Sys(Reg){system(Reg, "move", moveSystem)};
const move_and_jitter = [_]Sys(Reg){ system(Reg, "jitter", jitterSystem), system(Reg, "move", moveSystem) };

const TICKS: usize = 8;
const SWAP: usize = 4;

fn seedWorld(gpa: std.mem.Allocator) !W(Reg) {
    var w = W(Reg).init(0xA11C);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Position, .{ .x = fpz.Fixed.ZERO });
    w.add(e, Velocity, .{ .dx = fpz.Fixed.ONE });
    return w;
}

test "reloadAt selects the next set and is a World no-op" {
    const a = SystemSet(Reg){ .systems = &move_only };
    const b = SystemSet(Reg){ .systems = &move_and_jitter };
    const got = reloadAt(Reg, a, b);
    try testing.expectEqual(@as(usize, 2), got.systems.len);
    try testing.expectEqual(@as(usize, 2), b.systems.len); // both inputs are untouched
}

test "inProcessSource returns the comptime set; its stream matches the raw comptime slice" {
    const gpa = testing.allocator;
    const exec = &Schedule(Reg, &move_only).exec_order;
    const empties = [_]input.Input{.{ .tick = 0, .commands = &.{} }} ** TICKS;

    const set = try inProcessSource(Reg, &move_only).load();
    try testing.expectEqual(move_only.len, set.systems.len);
    try testing.expectEqual(@intFromPtr(&move_only), @intFromPtr(set.systems.ptr)); // same comptime slice

    // a run with the raw comptime slice (which the set wraps) is well-defined and stable.
    var cap = try run.captureStream(Reg, gpa, try seedWorld(gpa), &empties, &move_only, exec, null);
    defer cap.final.deinit(gpa);
    defer gpa.free(cap.hashes);
    try testing.expectEqual(TICKS, cap.hashes.len);
}

test "NativeLibSource.load returns error.NotImplemented (the typed seam)" {
    var nls = NativeLibSource(Reg){ .path = "libgkz_systems.so" };
    const src = nls.source();
    try testing.expectError(error.NotImplemented, src.load());
}

test "reload-to-SAME mid-stream is bit-identical to a continuous run (streamDigest equal)" {
    const gpa = testing.allocator;
    const exec = &Schedule(Reg, &move_only).exec_order;
    const empties = [_]input.Input{.{ .tick = 0, .commands = &.{} }} ** TICKS;

    // continuous reference
    var ref = try run.captureStream(Reg, gpa, try seedWorld(gpa), &empties, &move_only, exec, null);
    defer ref.final.deinit(gpa);
    defer gpa.free(ref.hashes);

    // split: [0,SWAP) then reload-to-same for [SWAP,TICKS)
    const seg1 = try run.captureStream(Reg, gpa, try seedWorld(gpa), empties[0..SWAP], &move_only, exec, null);
    defer gpa.free(seg1.hashes);
    var seg2 = try run.captureStream(Reg, gpa, seg1.final, empties[SWAP..], &move_only, exec, null);
    defer seg2.final.deinit(gpa);
    defer gpa.free(seg2.hashes);

    // concatenated hash stream must equal the continuous one, bit-for-bit
    var joined = try gpa.alloc(u64, TICKS);
    defer gpa.free(joined);
    @memcpy(joined[0..SWAP], seg1.hashes);
    @memcpy(joined[SWAP..], seg2.hashes);
    try testing.expectEqualSlices(u64, ref.hashes, joined);
    try testing.expectEqual(run.streamDigest(ref.hashes), run.streamDigest(joined));
}

test "reload-to-DIFFERENT mid-stream is caught as a divergence (firstDivergentTick non-null)" {
    const gpa = testing.allocator;
    const exec_a = &Schedule(Reg, &move_only).exec_order;
    const exec_b = &Schedule(Reg, &move_and_jitter).exec_order;
    const empties = [_]input.Input{.{ .tick = 0, .commands = &.{} }} ** TICKS;

    // reference: move_only throughout
    var ref = try run.captureStream(Reg, gpa, try seedWorld(gpa), &empties, &move_only, exec_a, null);
    defer ref.final.deinit(gpa);
    defer gpa.free(ref.hashes);

    // run [0,SWAP) with move_only, then RELOAD to move_and_jitter for the rest
    const seg1 = try run.captureStream(Reg, gpa, try seedWorld(gpa), empties[0..SWAP], &move_only, exec_a, null);
    defer gpa.free(seg1.hashes);
    var seg2 = try run.captureStream(Reg, gpa, seg1.final, empties[SWAP..], &move_and_jitter, exec_b, null);
    defer seg2.final.deinit(gpa);
    defer gpa.free(seg2.hashes);

    var joined = try gpa.alloc(u64, TICKS);
    defer gpa.free(joined);
    @memcpy(joined[0..SWAP], seg1.hashes);
    @memcpy(joined[SWAP..], seg2.hashes);

    // the divergent reload is detected; the first divergence is at or after the swap tick.
    const div = oracle.firstDivergentTick(ref.hashes, joined);
    try testing.expect(div != null);
    try testing.expect(div.? >= SWAP);
    // and the prefix before the swap is identical (the reload preserved state up to the boundary)
    try testing.expectEqualSlices(u64, ref.hashes[0..SWAP], joined[0..SWAP]);
}
