//! Snapshots & restore (SPEC §6, PLAN.md build-order step 12).
//!
//! A `Snapshot` is the canonical serialization of a World at a chosen tick, plus its content hash — a
//! self-contained, process-portable blob (no internal references), which is what makes forks (§13)
//! shippable to another process. `restore` is the inverse. Snapshot cadence is a replay/deployment
//! concern and lives here in `SnapshotConfig`, **never** in the hashed World value (Q2).

const std = @import("std");
const serialize = @import("serialize.zig");
const worldmod = @import("world.zig");

/// A serialized World plus its content fingerprint.
pub const Snapshot = struct {
    bytes: []u8,
    tick: u64,
    hash: u64,
    crc: u32,

    pub fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Snapshot cadence (Q2). Not part of World; chosen per deployment. `interval = 1` (every tick) is the
/// test/divergence-detection default; production trades reconstruction latency for throughput.
pub const SnapshotConfig = struct {
    interval: u64 = 64,
    /// Whether tick 0 is always snapshotted (the replay origin). Always true in Phase 1.
    snapshot_origin: bool = true,
};

/// Serialize `w` into a self-contained snapshot (canonical bytes + XXH64 + CRC32). Caller owns the
/// returned snapshot's bytes.
pub fn snapshot(comptime Reg: type, gpa: std.mem.Allocator, w: *const worldmod.World(Reg)) !Snapshot {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try serialize.writeWorld(Reg, gpa, &sink, w);

    const h = std.hash.XxHash64.hash(0, buf.items);
    const c = std.hash.Crc32.hash(buf.items);
    const owned = try buf.toOwnedSlice(gpa);
    return .{ .bytes = owned, .tick = w.tick, .hash = h, .crc = c };
}

/// Reconstruct a World from a snapshot. The returned World owns its buffers (caller `deinit`s it).
pub fn restore(comptime Reg: type, gpa: std.mem.Allocator, snap: Snapshot) !worldmod.World(Reg) {
    var reader = serialize.ByteReader{ .bytes = snap.bytes };
    const parts = try serialize.readWorld(Reg, gpa, &reader); // World takes ownership of parts
    return worldmod.World(Reg).fromParts(parts);
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("registry.zig").Registry;

const Position = struct {
    x: fpz.Fixed,
    y: fpz.Fixed,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Position});
const W = worldmod.World(Game);

test "snapshot then restore reproduces a bit-identical world" {
    const gpa = testing.allocator;
    var w = W.init(0xBEEF);
    defer w.deinit(gpa);
    const a = try w.spawn(gpa);
    _ = try w.spawn(gpa);
    w.add(a, Position, .{ .x = fpz.Fixed.fromInt(11), .y = fpz.Fixed.fromInt(-22) });
    w.tick = 7;

    var snap = try snapshot(Game, gpa, &w);
    defer snap.deinit(gpa);
    try testing.expectEqual((try w.digest(gpa)).hash, snap.hash);

    var r = try restore(Game, gpa, snap);
    defer r.deinit(gpa);
    try testing.expectEqual(snap.hash, (try r.digest(gpa)).hash);
    try testing.expectEqual(@as(u64, 7), r.tick);
    try testing.expectEqual(@as(i64, 11), r.get(a, Position).?.x.toInt());
    // entity identity survives the round-trip (Q4)
    try testing.expect(r.isLive(a));
}

test "snapshot hash equals the world digest" {
    const gpa = testing.allocator;
    var w = W.init(3);
    defer w.deinit(gpa);
    _ = try w.spawn(gpa);
    var snap = try snapshot(Game, gpa, &w);
    defer snap.deinit(gpa);
    const d = try w.digest(gpa);
    try testing.expectEqual(d.hash, snap.hash);
    try testing.expectEqual(d.crc, snap.crc);
}
