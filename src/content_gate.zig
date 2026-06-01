//! The §11 content-as-data WITNESS (PLAN.md §15.12): pinned cross-build + cross-arch digests proving a
//! Level loads to a fixed World, proc-gen is deterministic, and a world full of asset handles runs
//! headless with zero art. Folded into the base 3-mode `tmod` test via root.zig's `test {}` block, so the
//! pins are re-checked across Debug/ReleaseSafe/ReleaseFast AND under qemu on aarch64/s390x/arm/mips
//! (`zig build cross`) — the big-endian/32-bit runs are the decisive cross-arch witnesses.
//!
//! NO `std.debug.print` in any test body (corrupts the --listen runner). Pins are frozen constants;
//! recompute with the guarded `dumpPin` run standalone (per-module `zig test`, no --listen).

const std = @import("std");
const content = @import("content.zig");
const serialize = @import("serialize.zig");
const worldmod = @import("world.zig");
const entitymod = @import("entity.zig");
const Entity = entitymod.Entity;
const registry = @import("registry.zig");
const rng = @import("rng.zig");
const step = @import("step.zig");
const schedule = @import("schedule.zig");
const query = @import("query.zig");
const simctx = @import("simctx.zig");

const testing = std.testing;

// --- the gate's registry: a Position, a cross-entity ref, and an ASSET HANDLE ---------------------

const Position = struct {
    x: i32,
    y: i32,
    pub const kind_id: u16 = 1;
};
const Follows = struct {
    target: Entity, // a managed cross-entity reference
    pub const kind_id: u16 = 2;
};
/// A game-side asset handle: a plain fixed-width int the kernel never dereferences. NOT a kernel type.
const AssetHandle = enum(u64) { none = 0, _ };
const Sprite = struct {
    mesh: AssetHandle, // referenced by handle; no asset table needed to run
    tint: u32,
    pub const kind_id: u16 = 3;
};
const GReg = registry.Registry(.{ Position, Follows, Sprite });
const GW = worldmod.World(GReg);

// --- a reference prefab: a leader + a chaser that follows it, the chaser carrying a Sprite -----------

fn buildChaser(gpa: std.mem.Allocator) !content.Prefab(GReg) {
    var b = content.Builder(GReg).init(gpa);
    errdefer b.deinit();
    const leader = try b.addEntity(); // local 0
    const chaser = try b.addEntity(); // local 1
    try b.add(leader, Position, .{ .x = 10, .y = 20 });
    try b.add(chaser, Position, .{ .x = 11, .y = 21 });
    try b.add(chaser, Follows, .{ .target = content.localRef(leader) });
    try b.add(chaser, Sprite, .{ .mesh = @enumFromInt(0xCAFE), .tint = 0x00FF00 });
    return b.build();
}

/// The fixed reference Level: the chaser prefab (Position + a cross-entity ref + a Sprite asset handle)
/// placed twice. (The loose-node path is witnessed by a dedicated content.zig test.)
fn buildRefLevel(gpa: std.mem.Allocator) !content.Level(GReg) {
    var pf = try buildChaser(gpa);
    defer pf.deinit();
    var lb = content.LevelBuilder(GReg).init(gpa, 0x5EED_0011);
    errdefer lb.deinit();
    lb.tick0 = 3;
    const pi = try lb.addPrefab(&pf);
    try lb.place(pi);
    try lb.place(pi);
    return lb.build();
}

// --- seeded proc-gen: content-code emitting content-data --------------------------------------------

/// Deterministic dungeon: N (seed-driven) placements of the chaser prefab + loose Position nodes whose
/// coordinates come from the keyed RNG. content-code → content-data → a deterministic World.
fn genDungeon(gpa: std.mem.Allocator, seed: u64) !content.Level(GReg) {
    const root = rng.RngRoot{ .seed = seed };
    var pf = try buildChaser(gpa);
    defer pf.deinit();
    var lb = content.LevelBuilder(GReg).init(gpa, seed);
    errdefer lb.deinit();
    const pi = try lb.addPrefab(&pf);
    const n: u64 = 2 + (rng.draw(root, 0, 0, 0) % 3);
    var i: u64 = 0;
    while (i < n) : (i += 1) try lb.place(pi);
    return lb.build();
}

// --- a system + a level→run path for the headless witness -------------------------------------------

// drift Position east; READS the Sprite is irrelevant — the sim never needs the asset.
fn drift(ctx: *simctx.SimCtx(GReg), q: *query.Query(GReg, .{query.Write(Position)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Position).x += 1;
}
const drift_systems = [_]schedule.Sys(GReg){schedule.system(GReg, "drift", drift)};

/// Run a loaded World N ticks under the canonical schedule, folding the per-tick hash into a stream.
fn runHeadless(gpa: std.mem.Allocator, w0: GW, ticks: u64) !u64 {
    var w = try w0.clone(gpa);
    defer w.deinit(gpa);
    const exec = comptime &schedule.Schedule(GReg, &drift_systems).exec_order;
    var hstream = std.hash.XxHash64.init(0);
    var t: u64 = 0;
    while (t < ticks) : (t += 1) {
        w.tick +%= 1;
        try step.runScheduled(GReg, &w, gpa, &drift_systems, exec, null);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, (try w.digest(gpa)).hash, .little);
        hstream.update(&b);
    }
    return hstream.final();
}

// --- pinned cross-build / cross-arch witnesses (recompute via dumpPin) ------------------------------
const PIN_REF_LEVEL: u64 = 7964373861897932525;
const PIN_REF_CRC: u32 = 1763540242;
const PIN_GEN7: u64 = 10415364081221257391;
const PIN_HEADLESS_STREAM: u64 = 16059257981423164502;

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

test "C1: pinned loaded-World digest of the reference level (cross-build + cross-arch)" {
    const gpa = testing.allocator;
    var lvl = try buildRefLevel(gpa);
    defer lvl.deinit();
    var w = try content.loadLevel(GReg, gpa, &lvl);
    defer w.deinit(gpa);
    const d = try w.digest(gpa);
    try testing.expectEqual(PIN_REF_LEVEL, d.hash);
    try testing.expectEqual(PIN_REF_CRC, d.crc);
    // structural sanity: 2 instances × 2 nodes = 4 live entities, tick0 carried.
    try testing.expectEqual(@as(usize, 4), w.table.rowCount());
    try testing.expectEqual(@as(u64, 3), w.tick);
}

test "C2: level round-trips byte-identically and re-loads to the same digest" {
    const gpa = testing.allocator;
    var lvl = try buildRefLevel(gpa);
    defer lvl.deinit();

    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var sa = serialize.ByteSink{ .list = &a, .gpa = gpa };
    try content.writeLevel(GReg, &sa, &lvl);

    var rd = serialize.ByteReader{ .bytes = a.items };
    var lvl2 = try content.readLevel(GReg, gpa, &rd);
    defer lvl2.deinit();

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    var sb = serialize.ByteSink{ .list = &b, .gpa = gpa };
    try content.writeLevel(GReg, &sb, &lvl2);
    try testing.expectEqualSlices(u8, a.items, b.items); // canonical fixed point

    var w2 = try content.loadLevel(GReg, gpa, &lvl2);
    defer w2.deinit(gpa);
    try testing.expectEqual(PIN_REF_LEVEL, (try w2.digest(gpa)).hash);
}

test "C3: proc-gen is deterministic and seed-driven (cross-build + cross-arch pin)" {
    const gpa = testing.allocator;
    const Runner = struct {
        fn digestOf(g: std.mem.Allocator, seed: u64) !u64 {
            var lvl = try genDungeon(g, seed);
            defer lvl.deinit();
            var w = try content.loadLevel(GReg, g, &lvl);
            defer w.deinit(g);
            return (try w.digest(g)).hash;
        }
    };
    const d7a = try Runner.digestOf(gpa, 7);
    const d7b = try Runner.digestOf(gpa, 7);
    try testing.expectEqual(d7a, d7b); // same seed → identical World
    try testing.expectEqual(PIN_GEN7, d7a); // frozen across modes + arches
    try testing.expect(d7a != try Runner.digestOf(gpa, 8)); // seed drives content
}

test "C4: asset-handle headless run — a world full of handles runs with zero art" {
    const gpa = testing.allocator;
    var lvl = try buildRefLevel(gpa);
    defer lvl.deinit();
    var w = try content.loadLevel(GReg, gpa, &lvl);
    defer w.deinit(gpa);

    // the asset handle is intact, hashed state, and never dereferenced by the kernel (no asset table).
    var found_sprite = false;
    inline for (.{ 0, 1, 2, 3 }) |i| {
        const e = Entity{ .index = i, .generation = 0 };
        if (w.get(e, Sprite)) |s| {
            if (s.mesh == @as(AssetHandle, @enumFromInt(0xCAFE))) found_sprite = true;
        }
    }
    try testing.expect(found_sprite);

    // it RUNS headless (a system that ignores the asset), and the per-tick stream is a fixed pin.
    const stream = try runHeadless(gpa, w, 8);
    try testing.expectEqual(PIN_HEADLESS_STREAM, stream);

    // changing ONLY a mesh handle changes the hashed state (it IS state) — proves the handle is real data.
    var lvl2 = try buildRefLevel(gpa);
    defer lvl2.deinit();
    var w2 = try content.loadLevel(GReg, gpa, &lvl2);
    defer w2.deinit(gpa);
    // patch the first Sprite's mesh via a fresh add through the same dispatch
    const e0sprite = blk: {
        inline for (.{ 0, 1, 2, 3 }) |i| {
            const e = Entity{ .index = i, .generation = 0 };
            if (w2.get(e, Sprite) != null) break :blk e;
        }
        break :blk Entity{ .index = 0, .generation = 0 };
    };
    w2.add(e0sprite, Sprite, .{ .mesh = @enumFromInt(0xBEEF), .tint = 0x00FF00 });
    try testing.expect((try w.digest(gpa)).hash != (try w2.digest(gpa)).hash);
}

test "C5: hostile decode battery never panics" {
    const gpa = testing.allocator;
    // bad magic
    var m = serialize.ByteReader{ .bytes = "ZZZZ\x01\x00" };
    try testing.expectError(error.BadMagic, content.readLevel(GReg, gpa, &m));
    // a good level, then truncate it
    var lvl = try buildRefLevel(gpa);
    defer lvl.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try content.writeLevel(GReg, &sink, &lvl);
    var trunc = serialize.ByteReader{ .bytes = buf.items[0 .. buf.items.len / 2] };
    try testing.expectError(error.Truncated, content.readLevel(GReg, gpa, &trunc));
}

test "C6: decode/instantiate is leak- and crash-free under injected allocation failure" {
    var lvl_src = try buildRefLevel(testing.allocator);
    defer lvl_src.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var sink = serialize.ByteSink{ .list = &bytes, .gpa = testing.allocator };
    try content.writeLevel(GReg, &sink, &lvl_src);

    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = fa.allocator();
        var rd = serialize.ByteReader{ .bytes = bytes.items };
        var lvl = content.readLevel(GReg, gpa, &rd) catch |e| {
            try testing.expect(e == error.OutOfMemory); // clean failure, arena freed by errdefer
            continue;
        };
        defer lvl.deinit();
        var w = content.loadLevel(GReg, gpa, &lvl) catch |e| {
            try testing.expect(e == error.OutOfMemory);
            continue;
        };
        w.deinit(gpa);
    }
}

test "dumpPin compiles" {
    _ = &dumpPin;
}

fn dumpPin(gpa: std.mem.Allocator) !void {
    var lvl = try buildRefLevel(gpa);
    defer lvl.deinit();
    var w = try content.loadLevel(GReg, gpa, &lvl);
    defer w.deinit(gpa);
    const d = try w.digest(gpa);
    std.debug.print("PIN_REF_LEVEL={d} PIN_REF_CRC={d}\n", .{ d.hash, d.crc });
    var g7 = try genDungeon(gpa, 7);
    defer g7.deinit();
    var w7 = try content.loadLevel(GReg, gpa, &g7);
    defer w7.deinit(gpa);
    std.debug.print("PIN_GEN7={d}\n", .{(try w7.digest(gpa)).hash});
    std.debug.print("PIN_HEADLESS_STREAM={d}\n", .{try runHeadless(gpa, w, 8)});
}
