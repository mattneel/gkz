//! The VOPR's per-seed evidence bundle (SPEC §9, PLAN.md Phase 4). Build-order step 1.
//!
//! A `Run(R)` is everything an oracle needs to render a verdict on one seed: the materialized input
//! stream, the per-tick World content-hash stream (the divergence oracle), the final World, and a
//! snapshot of the initial World (so any tick can be reconstructed via snapshot+replay). The VOPR
//! sits strictly ABOVE the kernel — this module imports kernel modules; the kernel never imports it.
//!
//! `captureStream` folds `step.stepExec` over a given input stream under a given execution order,
//! recording each tick's `World.digest().hash`. It is the same machinery the determinism gates
//! already certify (proven by a test that pins its output to replay.zig's frozen constant), and the
//! explicit `exec` parameter is what lets the VOPR inject a fault (a within-stage permutation) and
//! check the hash stream is unchanged.

const std = @import("std");
const worldmod = @import("../world.zig");
const snapshotmod = @import("../snapshot.zig");
const input = @import("../input.zig");
const schedule = @import("../schedule.zig");
const stepmod = @import("../step.zig");
const recorder = @import("../recorder.zig");
const rng = @import("../rng.zig");
const generator = @import("generator.zig");
const Sys = schedule.Sys;

/// The result of a capture: the per-tick hash stream and the final World (named so divergence-oracle
/// `switch` arms over different capture fns share one type).
pub fn Capture(comptime R: type) type {
    return struct { hashes: []u64, final: worldmod.World(R) };
}

/// Fold `stepExec` over `inputs` from `w0` (consumed), returning the per-tick hash stream and the final
/// World. `exec` is the system execution order (canonical for a reference run, a stage-respecting
/// permutation for a fault-injected run). `rec` optionally records provenance.
pub fn captureStream(
    comptime R: type,
    gpa: std.mem.Allocator,
    w0: worldmod.World(R),
    inputs: []const input.Input,
    comptime systems: []const Sys(R),
    exec: []const u16,
    rec: ?*recorder.Recorder,
) std.mem.Allocator.Error!Capture(R) {
    var w = w0; // take ownership BEFORE the first fallible call, so an OOM in `hashes` can't leak w0
    errdefer w.deinit(gpa);
    const hashes = try gpa.alloc(u64, inputs.len);
    errdefer gpa.free(hashes);
    for (inputs, 0..) |in, i| {
        const nxt = try stepmod.stepExec(R, gpa, w, in, systems, exec, rec);
        w.deinit(gpa);
        w = nxt;
        hashes[i] = (try w.digest(gpa)).hash;
    }
    return .{ .hashes = hashes, .final = w };
}

/// Like `captureStream` but round-trips the World through snapshot+restore every `k` ticks — the
/// snapshot-cadence fault injection. If serialization is identity (it must be), the hash stream is
/// bit-identical to the continuous run; a difference is a snapshot/restore bug. `exec` is canonical.
pub fn captureStreamCadence(
    comptime R: type,
    gpa: std.mem.Allocator,
    w0: worldmod.World(R),
    inputs: []const input.Input,
    comptime systems: []const Sys(R),
    exec: []const u16,
    k: u64,
) !Capture(R) {
    var w = w0; // take ownership BEFORE the first fallible call, so an OOM in `hashes` can't leak w0
    errdefer w.deinit(gpa);
    const hashes = try gpa.alloc(u64, inputs.len);
    errdefer gpa.free(hashes);
    for (inputs, 0..) |in, i| {
        const nxt = try stepmod.stepExec(R, gpa, w, in, systems, exec, null);
        w.deinit(gpa);
        w = nxt;
        if (k > 0 and (i + 1) % k == 0) {
            var snap = try snapshotmod.snapshot(R, gpa, &w);
            defer snap.deinit(gpa);
            const restored = try snapshotmod.restore(R, gpa, snap);
            w.deinit(gpa);
            w = restored;
        }
        hashes[i] = (try w.digest(gpa)).hash;
    }
    return .{ .hashes = hashes, .final = w };
}

/// XXH64 over a per-tick hash stream — a single fingerprint for the whole trajectory (matches
/// replay.zig's per-tick-stream digest discipline).
pub fn streamDigest(hashes: []const u64) u64 {
    var h = std.hash.XxHash64.init(0);
    for (hashes) |x| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, x, .little);
        h.update(&b);
    }
    return h.final();
}

/// Build a `Run` for one seed: snapshot the initial World, then step it forward while the generator
/// produces the input stream (observing each tick's World), capturing the per-tick hash stream. `w0` is
/// consumed. Stops at `max_ticks` or when the generator returns null. Caller `deinit`s the Run.
pub fn buildRun(
    comptime R: type,
    gpa: std.mem.Allocator,
    comptime systems: []const Sys(R),
    w0: worldmod.World(R),
    seed: u64,
    gen: generator.Generator(R),
    max_ticks: usize,
) !Run(R) {
    const exec = comptime &schedule.Schedule(R, systems).exec_order;
    // Take ownership of `w0` FIRST (before any fallible call) so an OOM in `snapshot` cannot leak it.
    var w = w0;
    errdefer w.deinit(gpa);
    var base = try snapshotmod.snapshot(R, gpa, &w);
    errdefer base.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var inputs: std.ArrayList(input.Input) = .empty; // arena-backed
    var hashes: std.ArrayList(u64) = .empty;
    errdefer hashes.deinit(gpa);

    const root: rng.RngRoot = .{ .seed = seed };
    var t: u64 = 1;
    while (t <= max_ticks) : (t += 1) {
        const in = (try gen.next(arena.allocator(), t, root, &w)) orelse break;
        try inputs.append(arena.allocator(), in);
        const nxt = try stepmod.stepExec(R, gpa, w, in, systems, exec, null);
        w.deinit(gpa);
        w = nxt;
        try hashes.append(gpa, (try w.digest(gpa)).hash);
    }
    return .{
        .seed = seed,
        .inputs = try inputs.toOwnedSlice(arena.allocator()),
        .hashes = try hashes.toOwnedSlice(gpa),
        .final = w,
        .base = base,
        .arena = arena,
    };
}

pub fn Run(comptime R: type) type {
    return struct {
        const Self = @This();
        seed: u64,
        inputs: []const input.Input, // backed by `arena`
        hashes: []const u64, // per-tick World.digest().hash (interval = 1)
        final: worldmod.World(R),
        base: snapshotmod.Snapshot, // snapshot of the initial World (tick 0)
        arena: std.heap.ArenaAllocator, // owns the input stream + its commands

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.arena.deinit();
            gpa.free(self.hashes);
            self.final.deinit(gpa);
            self.base.deinit(gpa);
            self.* = undefined;
        }

        /// Reconstruct the World at tick `t` (0..=inputs.len) via snapshot@0 + replay forward. Caller
        /// frees the returned World. O(t) — on-demand provenance, never the throughput path.
        pub fn worldAt(self: *const Self, gpa: std.mem.Allocator, comptime systems: []const Sys(R), t: usize) !worldmod.World(R) {
            var w = try snapshotmod.restore(R, gpa, self.base);
            errdefer w.deinit(gpa);
            for (self.inputs[0..t]) |in| {
                const nxt = try stepmod.step(R, gpa, w, in, systems);
                w.deinit(gpa);
                w = nxt;
            }
            return w;
        }
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------
//
// The headline test reproduces replay.zig's sys3 scenario (the same components, systems, seed, and
// tick count) and asserts captureStream's per-tick-stream digest equals replay.zig's FROZEN constant —
// proving the VOPR's capture is the very machinery the determinism gates already certify.

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("../registry.zig").Registry;
const query = @import("../query.zig");
const simctx = @import("../simctx.zig");
const Read = query.Read;
const Write = query.Write;
const Query = query.Query;
const SimCtx = simctx.SimCtx;
const system = schedule.system;
const Entity = @import("../entity.zig").Entity;

const Position = struct {
    x: fpz.Fixed,
    y: fpz.Fixed,
    pub const kind_id: u16 = 1;
};
const Velocity = struct {
    dx: fpz.Fixed,
    dy: fpz.Fixed,
    pub const kind_id: u16 = 2;
};
const Reg = Registry(.{ Position, Velocity });
const W = worldmod.World(Reg);

fn moveSystem(ctx: *SimCtx(Reg), q: *Query(Reg, .{ Read(Velocity), Write(Position) })) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| {
        const v = row.read(Velocity).*;
        const p = row.write(Position);
        p.x = p.x.addSat(v.dx);
        p.y = p.y.addSat(v.dy);
    }
}
fn jitterSystem(ctx: *SimCtx(Reg), q: *Query(Reg, .{Write(Velocity)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| {
        const e = row.entity();
        row.write(Velocity).dx = ctx.rngFixed(e.index, 0, fpz.Fixed.NEG_ONE, fpz.Fixed.ONE);
    }
}
fn spawnerSystem(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(Position)})) std.mem.Allocator.Error!void {
    if (q.next()) |_| try ctx.cmd.spawn();
}
const sys3 = [_]Sys(Reg){ system(Reg, "move", moveSystem), system(Reg, "jitter", jitterSystem), system(Reg, "spawner", spawnerSystem) };
const SEED: u64 = 0x5EED;
const TICKS: usize = 10;

fn seedWorld(gpa: std.mem.Allocator) !W {
    var w = W.init(SEED);
    errdefer w.deinit(gpa);
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const e = try w.spawn(gpa);
        w.add(e, Position, .{ .x = fpz.Fixed.ZERO, .y = fpz.Fixed.ZERO });
        w.add(e, Velocity, .{ .dx = fpz.Fixed.ONE, .dy = fpz.Fixed.fromInt(2) });
    }
    return w;
}

test "captureStream reproduces replay.zig's frozen per-tick-stream digest (the VOPR uses the certified machinery)" {
    const gpa = testing.allocator;
    const w0 = try seedWorld(gpa);
    const empties = [_]input.Input{.{ .tick = 0, .commands = &.{} }} ** TICKS;
    const exec = comptime &schedule.Schedule(Reg, &sys3).exec_order;

    var cap = try captureStream(Reg, gpa, w0, &empties, &sys3, exec, null);
    defer cap.final.deinit(gpa);
    defer gpa.free(cap.hashes);

    try testing.expectEqual(@as(u64, 18301098896699055067), (try cap.final.digest(gpa)).hash); // frozen final
    try testing.expectEqual(@as(u64, 16962136858194444356), streamDigest(cap.hashes)); // frozen stream
}

test "Run.worldAt reconstructs an intermediate tick's World" {
    const gpa = testing.allocator;

    // build a Run by hand: snapshot@0 + capture, with the input stream in an arena
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const empties = try arena.allocator().alloc(input.Input, TICKS);
    for (empties) |*in| in.* = .{ .tick = 0, .commands = &.{} };

    const w0 = try seedWorld(gpa);
    var base = try snapshotmod.snapshot(Reg, gpa, &w0);
    errdefer base.deinit(gpa);
    const exec = comptime &schedule.Schedule(Reg, &sys3).exec_order;
    const cap = try captureStream(Reg, gpa, w0, empties, &sys3, exec, null);

    var run = Run(Reg){ .seed = SEED, .inputs = empties, .hashes = cap.hashes, .final = cap.final, .base = base, .arena = arena };
    defer run.deinit(gpa);

    // worldAt(5) reconstructed must match hashes[4] (the world after 5 steps = tick 5)
    var w5 = try run.worldAt(gpa, &sys3, 5);
    defer w5.deinit(gpa);
    try testing.expectEqual(run.hashes[4], (try w5.digest(gpa)).hash);
    // worldAt(TICKS) matches the final
    var wN = try run.worldAt(gpa, &sys3, TICKS);
    defer wN.deinit(gpa);
    try testing.expectEqual((try run.final.digest(gpa)).hash, (try wN.digest(gpa)).hash);
}

test "captureStreamCadence is identity: snapshot round-trips every k ticks do not change the hash stream" {
    const gpa = testing.allocator;
    const empties = [_]input.Input{.{ .tick = 0, .commands = &.{} }} ** TICKS;
    const exec = comptime &schedule.Schedule(Reg, &sys3).exec_order;

    var ref = try captureStream(Reg, gpa, try seedWorld(gpa), &empties, &sys3, exec, null);
    defer ref.final.deinit(gpa);
    defer gpa.free(ref.hashes);

    inline for (.{ 1, 2, 3, 7 }) |k| {
        var cad = try captureStreamCadence(Reg, gpa, try seedWorld(gpa), &empties, &sys3, exec, k);
        defer cad.final.deinit(gpa);
        defer gpa.free(cad.hashes);
        // a correct snapshot/restore is an identity, so cadence-k hashes equal the continuous run's
        try testing.expectEqualSlices(u64, ref.hashes, cad.hashes);
    }
}
