//! Replay & the determinism harness (SPEC §1/§6, PLAN.md build-order step 12; gates R25/R26/Q4).
//!
//! Canonical truth for reconstructing any tick is `snapshot + input stream via deterministic replay`
//! (SPEC §5's source-of-truth call) — never a fold over events. `replay` restores a base snapshot and
//! folds `step` over the recorded inputs. The tests are the determinism gates: replaying from a
//! mid-run snapshot reproduces the live per-tick hash stream bit-for-bit and preserves entity
//! identities, and a pinned end-to-end hash freezes the whole pipeline (the same constant must be
//! reproduced under Debug, ReleaseSafe, and ReleaseFast — see build.zig's `test` matrix).

const std = @import("std");
const worldmod = @import("world.zig");
const stepmod = @import("step.zig");
const snapshotmod = @import("snapshot.zig");
const input = @import("input.zig");

/// Reconstruct a World by restoring `base` and folding `step` over `inputs`. Returns the final World
/// (caller `deinit`s it).
pub fn replay(
    comptime Reg: type,
    gpa: std.mem.Allocator,
    base: snapshotmod.Snapshot,
    inputs: []const input.Input,
    comptime systems: []const stepmod.System(Reg),
) !worldmod.World(Reg) {
    var w = try snapshotmod.restore(Reg, gpa, base);
    errdefer w.deinit(gpa);
    for (inputs) |in| {
        const next = try stepmod.step(Reg, gpa, w, in, systems);
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
const rng = @import("rng.zig");
const Registry = @import("registry.zig").Registry;
const Snapshot = snapshotmod.Snapshot;
const Input = input.Input;
const Command = input.Command;

const Position = struct {
    x: fpz.Fixed,
    y: fpz.Fixed,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Position});
const W = worldmod.World(Game);

fn demoSystem(w: *W, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    const order = try w.table.canonicalOrder(gpa);
    defer gpa.free(order);
    const owners = w.table.owners();
    for (order) |row| {
        const e = owners[row];
        if (!w.has(e, Position)) w.add(e, Position, .{ .x = fpz.Fixed.ZERO, .y = fpz.Fixed.ZERO });
        const p = w.get(e, Position).?;
        const dx = rng.drawFixed(w.rng_root, w.tick, e.index, 0, fpz.Fixed.NEG_ONE, fpz.Fixed.ONE);
        const dy = rng.drawFixed(w.rng_root, w.tick, e.index, 1, fpz.Fixed.NEG_ONE, fpz.Fixed.ONE);
        p.x = p.x.addSat(dx);
        p.y = p.y.addSat(dy);
    }
}
const demo_systems = [_]stepmod.System(Game){&demoSystem};

const SEED: u64 = 0x5EED;
const TICKS: usize = 10;
const SNAP_AT: u64 = 5;

/// Build the fixed scenario inputs: spawn 4 entities at tick 1, then empty inputs.
fn scenarioInputs() [TICKS]Input {
    const spawn = Command{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 };
    const spawn4 = [_]Command{ spawn, spawn, spawn, spawn };
    var inputs: [TICKS]Input = undefined;
    inputs[0] = .{ .tick = 1, .commands = &spawn4 };
    var i: usize = 1;
    while (i < TICKS) : (i += 1) inputs[i] = .{ .tick = @intCast(i + 1), .commands = &.{} };
    return inputs;
}

test "replay from a mid-run snapshot reproduces the live hash stream and entity identities (Q4/R26)" {
    const gpa = testing.allocator;
    const inputs = scenarioInputs();

    // --- live run: step through all inputs, record per-tick hashes, snapshot at SNAP_AT ---
    var live_hashes: [TICKS]u64 = undefined;
    var snap: ?Snapshot = null;
    defer if (snap) |*s| s.deinit(gpa);

    var w = W.init(SEED);
    for (inputs, 0..) |in, i| {
        const next = try stepmod.step(Game, gpa, w, in, &demo_systems);
        w.deinit(gpa);
        w = next;
        live_hashes[i] = (try w.digest(gpa)).hash;
        if (w.tick == SNAP_AT) snap = try snapshotmod.snapshot(Game, gpa, &w);
    }
    // capture the live final owners for the entity-identity check
    const live_order = try w.table.canonicalOrder(gpa);
    defer gpa.free(live_order);
    const live_owners = try gpa.dupe(@TypeOf(w.table.owners()[0]), w.table.owners());
    defer gpa.free(live_owners);
    const live_final_hash = (try w.digest(gpa)).hash;
    w.deinit(gpa);

    try testing.expect(snap != null);

    // --- replay from the snapshot at SNAP_AT, recording the tail hash stream ---
    var r = try snapshotmod.restore(Game, gpa, snap.?);
    var j: usize = SNAP_AT;
    while (j < TICKS) : (j += 1) {
        const next = try stepmod.step(Game, gpa, r, inputs[j], &demo_systems);
        r.deinit(gpa);
        r = next;
        try testing.expectEqual(live_hashes[j], (try r.digest(gpa)).hash); // tail matches live
    }
    defer r.deinit(gpa);

    // final world is bit-identical, and every entity keeps its exact {index, generation} (Q4)
    try testing.expectEqual(live_final_hash, (try r.digest(gpa)).hash);
    const replay_order = try r.table.canonicalOrder(gpa);
    defer gpa.free(replay_order);
    try testing.expectEqual(live_owners.len, replay_order.len);
    for (replay_order, 0..) |row, k| {
        try testing.expectEqual(live_owners[live_order[k]], r.table.owners()[row]);
    }
}

test "two forks from one snapshot share the pre-fork entity identities (counterfactual substrate)" {
    const gpa = testing.allocator;
    const inputs = scenarioInputs();

    // run to SNAP_AT and snapshot
    var w = W.init(SEED);
    for (inputs[0..SNAP_AT]) |in| {
        const next = try stepmod.step(Game, gpa, w, in, &demo_systems);
        w.deinit(gpa);
        w = next;
    }
    var snap = try snapshotmod.snapshot(Game, gpa, &w);
    defer snap.deinit(gpa);
    w.deinit(gpa);

    // fork A: one more empty tick; fork B: a despawn of entity 0 then a tick
    var forkA = try replay(Game, gpa, snap, &.{.{ .tick = SNAP_AT + 1, .commands = &.{} }}, &demo_systems);
    defer forkA.deinit(gpa);
    const despawn0 = [_]Command{.{ .actor = .{ .index = 0, .generation = 0 }, .verb = 2 }};
    var forkB = try replay(Game, gpa, snap, &.{.{ .tick = SNAP_AT + 1, .commands = &despawn0 }}, &demo_systems);
    defer forkB.deinit(gpa);

    // the forks diverge...
    try testing.expect((try forkA.digest(gpa)).hash != (try forkB.digest(gpa)).hash);
    // ...but a shared pre-fork entity (index 1) keeps the same identity in both
    const id1 = @TypeOf(forkA.table.owners()[0]){ .index = 1, .generation = 0 };
    try testing.expect(forkA.isLive(id1));
    try testing.expect(forkB.isLive(id1));
}

test "addSat saturates without overflow panic (no build-mode divergence on overflow, gate 4)" {
    const gpa = testing.allocator;
    var w = W.init(1);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Position, .{ .x = fpz.Fixed.MAX, .y = fpz.Fixed.MAX });
    // one demo tick adds a positive delta to an already-MAX value: addSat clamps, never panics/wraps.
    var next = try stepmod.step(Game, gpa, w, .{ .tick = 1, .commands = &.{} }, &demo_systems);
    defer next.deinit(gpa);
    const x = next.get(e, Position).?.x;
    try testing.expect(x.raw <= fpz.Fixed.MAX.raw); // saturated, still in range
}

test "PINNED end-to-end + per-tick-stream hash (cross-build gate: Debug == ReleaseSafe == ReleaseFast)" {
    const gpa = testing.allocator;
    const inputs = scenarioInputs();
    var stream = std.hash.XxHash64.init(0); // rolling digest over every tick's hash
    var w = W.init(SEED);
    defer w.deinit(gpa);
    for (inputs) |in| {
        const next = try stepmod.step(Game, gpa, w, in, &demo_systems);
        w.deinit(gpa);
        w = next;
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, (try w.digest(gpa)).hash, .little);
        stream.update(&b);
    }
    // All three optimize modes assert the SAME two constants, so passing in all modes proves the
    // per-tick hash stream (not just the end state) is bit-identical across build modes (D2).
    try testing.expectEqual(@as(u64, 2548848807784252766), (try w.digest(gpa)).hash); // final state
    try testing.expectEqual(@as(u64, 18260946131602188893), stream.final()); // frozen per-tick stream digest
}

test "replay reproduces a tail containing structural commands after the snapshot (tests#7)" {
    const gpa = testing.allocator;
    const spawn = Command{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 };
    const spawn4 = [_]Command{ spawn, spawn, spawn, spawn };
    const despawn1 = [_]Command{.{ .actor = .{ .index = 1, .generation = 0 }, .verb = 2 }};

    var inputs: [TICKS]Input = undefined;
    inputs[0] = .{ .tick = 1, .commands = &spawn4 };
    var i: usize = 1;
    while (i < TICKS) : (i += 1) inputs[i] = .{ .tick = @intCast(i + 1), .commands = &.{} };
    inputs[6] = .{ .tick = 7, .commands = &despawn1 }; // despawn entity (1,0) at tick 7 (> SNAP_AT)
    inputs[7] = .{ .tick = 8, .commands = spawn4[0..1] }; // spawn one (recycles index 1) at tick 8

    // live run, recording per-tick hashes and snapshotting at SNAP_AT
    var live_hashes: [TICKS]u64 = undefined;
    var snap: ?Snapshot = null;
    defer if (snap) |*s| s.deinit(gpa);
    var w = W.init(SEED);
    for (inputs, 0..) |in, k| {
        const next = try stepmod.step(Game, gpa, w, in, &demo_systems);
        w.deinit(gpa);
        w = next;
        live_hashes[k] = (try w.digest(gpa)).hash;
        if (w.tick == SNAP_AT) snap = try snapshotmod.snapshot(Game, gpa, &w);
    }
    const live_final = (try w.digest(gpa)).hash;
    w.deinit(gpa);
    try testing.expect(snap != null);

    // replay the tail (which contains the despawn at tick 7 and the recycling spawn at tick 8)
    var r = try snapshotmod.restore(Game, gpa, snap.?);
    var j: usize = SNAP_AT;
    while (j < TICKS) : (j += 1) {
        const next = try stepmod.step(Game, gpa, r, inputs[j], &demo_systems);
        r.deinit(gpa);
        r = next;
        try testing.expectEqual(live_hashes[j], (try r.digest(gpa)).hash);
    }
    defer r.deinit(gpa);
    try testing.expectEqual(live_final, (try r.digest(gpa)).hash);
    // the recycled entity exists with the predicted generation in both live and replay (Q4)
    try testing.expect(r.isLive(.{ .index = 1, .generation = 2 }));
}
