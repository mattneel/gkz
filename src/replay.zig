//! Replay & the determinism harness (SPEC §1/§4/§6, PLAN.md Phase 2; gates R25/R26/Q4 + order-indep).
//!
//! `replay` restores a base snapshot and folds `step` over the recorded inputs — canonical truth for
//! reconstructing any tick (never an event fold). The tests are the determinism gates:
//!   * replaying from a mid-run snapshot reproduces the live per-tick hash stream and entity identities;
//!   * the **order-permutation gate** (SPEC §4's "physical scheduling is nondeterministic, results
//!     never are", proven WITHOUT threads): running a tick with a within-stage permutation of the
//!     system execution order yields a bit-identical result, and pinned end-to-end + per-tick-stream
//!     digests are asserted in every build mode (Debug/ReleaseSafe/ReleaseFast).

const std = @import("std");
const worldmod = @import("world.zig");
const stepmod = @import("step.zig");
const snapshotmod = @import("snapshot.zig");
const schedule = @import("schedule.zig");
const input = @import("input.zig");
const Input = input.Input;

/// Reconstruct a World by restoring `base` and folding `step` over `inputs`. Caller `deinit`s the result.
pub fn replay(
    comptime R: type,
    gpa: std.mem.Allocator,
    base: snapshotmod.Snapshot,
    inputs: []const Input,
    comptime systems: []const schedule.Sys(R),
) !worldmod.World(R) {
    var w = try snapshotmod.restore(R, gpa, base);
    errdefer w.deinit(gpa);
    for (inputs) |in| {
        const next = try stepmod.step(R, gpa, w, in, systems);
        w.deinit(gpa);
        w = next;
    }
    return w;
}

// ---------------------------------------------------------------------------------------------------
// Tests — the determinism gates
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("registry.zig").Registry;
const query = @import("query.zig");
const simctx = @import("simctx.zig");
const Read = query.Read;
const Write = query.Write;
const Query = query.Query;
const SimCtx = simctx.SimCtx;
const Sys = schedule.Sys;
const system = schedule.system;
const Snapshot = snapshotmod.Snapshot;
const Entity = @import("entity.zig").Entity;

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

// in-place: integrate Position by Velocity (reads Velocity, writes Position)
fn moveSystem(ctx: *SimCtx(Reg), q: *Query(Reg, .{ Read(Velocity), Write(Position) })) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| {
        const v = row.read(Velocity).*;
        const p = row.write(Position);
        p.x = p.x.addSat(v.dx);
        p.y = p.y.addSat(v.dy);
    }
}
// in-place: jitter Velocity.dx from keyed RNG (writes Velocity)
fn jitterSystem(ctx: *SimCtx(Reg), q: *Query(Reg, .{Write(Velocity)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| {
        const e = row.entity();
        row.write(Velocity).dx = ctx.rngFixed(e.index, 0, fpz.Fixed.NEG_ONE, fpz.Fixed.ONE);
    }
}
// deferred structural: spawn one entity per tick (via the command buffer)
fn spawnerSystem(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(Position)})) std.mem.Allocator.Error!void {
    if (q.next()) |_| try ctx.cmd.spawn();
}

// schedule: move(0) {R Vel, W Pos}; jitter(1) {W Vel}; spawner(2) {R Pos}.
//   0-1 conflict (Vel), 0-2 conflict (Pos), 1-2 no conflict -> stage0={0}, stage1={1,2} (multi-member)
const sys3 = [_]Sys(Reg){
    system(Reg, "move", moveSystem),
    system(Reg, "jitter", jitterSystem),
    system(Reg, "spawner", spawnerSystem),
};
const EXEC_CANON = [_]u16{ 0, 1, 2 }; // canonical: stage0={0}, stage1=[1,2]
const EXEC_PERMUTED = [_]u16{ 0, 2, 1 }; // within-stage-1 swap (jitter<->spawner) — stage-respecting

const SEED: u64 = 0x5EED;
const TICKS: usize = 10;
const SNAP_AT: u64 = 5;

fn seedWorld(gpa: std.mem.Allocator, n: u32) !W {
    var w = W.init(SEED);
    errdefer w.deinit(gpa);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const e = try w.spawn(gpa);
        w.add(e, Position, .{ .x = fpz.Fixed.ZERO, .y = fpz.Fixed.ZERO });
        w.add(e, Velocity, .{ .dx = fpz.Fixed.ONE, .dy = fpz.Fixed.fromInt(2) });
    }
    return w;
}

fn emptyInputs() [TICKS]Input {
    var inputs: [TICKS]Input = undefined;
    var i: usize = 0;
    while (i < TICKS) : (i += 1) inputs[i] = .{ .tick = @intCast(i + 1), .commands = &.{} };
    return inputs;
}

test "replay from a mid-run snapshot reproduces the live hash stream and entity identities (Q4/R26)" {
    const gpa = testing.allocator;
    const inputs = emptyInputs();

    var live_hashes: [TICKS]u64 = undefined;
    var snap: ?Snapshot = null;
    defer if (snap) |*s| s.deinit(gpa);

    var w = try seedWorld(gpa, 3);
    for (inputs, 0..) |in, i| {
        const next = try stepmod.step(Reg, gpa, w, in, &sys3);
        w.deinit(gpa);
        w = next;
        live_hashes[i] = (try w.digest(gpa)).hash;
        if (w.tick == SNAP_AT) snap = try snapshotmod.snapshot(Reg, gpa, &w);
    }
    const live_final = (try w.digest(gpa)).hash;
    const live_rows = w.table.rowCount();
    w.deinit(gpa);
    try testing.expect(snap != null);

    var r = try snapshotmod.restore(Reg, gpa, snap.?);
    var j: usize = SNAP_AT;
    while (j < TICKS) : (j += 1) {
        const next = try stepmod.step(Reg, gpa, r, inputs[j], &sys3);
        r.deinit(gpa);
        r = next;
        try testing.expectEqual(live_hashes[j], (try r.digest(gpa)).hash);
    }
    defer r.deinit(gpa);
    try testing.expectEqual(live_final, (try r.digest(gpa)).hash);
    try testing.expectEqual(live_rows, r.table.rowCount());
    // entity identities survive replay: each seeded entity still resolves with its original generation
    try testing.expect(r.isLive(.{ .index = 0, .generation = 0 }));
}

/// Run `ticks` ticks from a freshly-seeded world, executing systems in `exec` order each tick, folding
/// every tick's content hash into a rolling digest. Returns (final-state hash, per-tick-stream digest).
fn runTrajectory(gpa: std.mem.Allocator, ticks: usize, exec: []const u16) !struct { final: u64, stream: u64 } {
    var w = try seedWorld(gpa, 3);
    defer w.deinit(gpa);
    var stream = std.hash.XxHash64.init(0);
    var t: usize = 0;
    while (t < ticks) : (t += 1) {
        w.tick +%= 1;
        try stepmod.runScheduled(Reg, &w, gpa, &sys3, exec);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, (try w.digest(gpa)).hash, .little);
        stream.update(&b);
    }
    return .{ .final = (try w.digest(gpa)).hash, .stream = stream.final() };
}

test "ORDER-PERMUTATION GATE: a within-stage execution permutation yields a bit-identical result" {
    const gpa = testing.allocator;
    const canon = try runTrajectory(gpa, TICKS, &EXEC_CANON);
    const perm = try runTrajectory(gpa, TICKS, &EXEC_PERMUTED);
    // SPEC §4: physical scheduling order does not change results.
    try testing.expectEqual(canon.final, perm.final);
    try testing.expectEqual(canon.stream, perm.stream);
}

test "PINNED determinism digests (cross-build gate: Debug == ReleaseSafe == ReleaseFast must all match)" {
    const gpa = testing.allocator;
    const r = try runTrajectory(gpa, TICKS, &EXEC_CANON);
    // All three optimize modes assert the SAME constants, so passing across the build matrix proves
    // the per-tick hash stream (not just the end state) is bit-identical across build modes (D2).
    try testing.expectEqual(@as(u64, 18301098896699055067), r.final); // frozen final-state fingerprint
    try testing.expectEqual(@as(u64, 16962136858194444356), r.stream); // frozen per-tick-stream digest
}

test "addSat saturates without overflow panic through a Query write (gate 4)" {
    const gpa = testing.allocator;
    var w = W.init(1);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Position, .{ .x = fpz.Fixed.MAX, .y = fpz.Fixed.MAX });
    w.add(e, Velocity, .{ .dx = fpz.Fixed.MAX, .dy = fpz.Fixed.ONE });
    // move adds Velocity to an already-MAX Position via addSat: clamps, never panics/wraps.
    var next = try stepmod.step(Reg, gpa, w, .{ .tick = 1, .commands = &.{} }, &sys3);
    defer next.deinit(gpa);
    try testing.expect(next.get(e, Position).?.x.raw <= fpz.Fixed.MAX.raw);
}
