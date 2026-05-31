//! Per-tick content hash (SPEC §2.5, PLAN.md build-order step 7; resolves Q5, enforces D5).
//!
//! The hash is computed over the **canonical serialization** (serialize.zig) by driving its single
//! traversal with a hashing sink — so the hash is provably the hash of the canonical bytes, with no
//! duplicated ordering logic and no materialized snapshot buffer.
//!
//! Algorithm: `std.hash.XxHash64`, seed pinned to 0. XXH64 is a frozen, published specification with
//! canonical test vectors, so its output is stable across Zig versions *and* architectures (unlike
//! Wyhash, which has drifted) — exactly the property cross-build/cross-arch divergence detection needs.
//! A `Crc32` is computed over the identical byte stream as a structural tripwire: if XXH64 ever
//! disagreed while CRC agreed, the cause is a hash-implementation issue, not a state divergence.

const std = @import("std");
const serialize = @import("serialize.zig");

/// XXH64 seed, pinned. Changing it reseeds every hash in the system.
pub const XXH64_SEED: u64 = 0;

pub const Digest = struct { hash: u64, crc: u32 };

/// A serialization sink that feeds bytes into XXH64 + CRC32 instead of a buffer. `update` cannot fail.
pub const HashSink = struct {
    xxh: std.hash.XxHash64,
    crc: std.hash.Crc32,

    pub fn init() HashSink {
        return .{ .xxh = std.hash.XxHash64.init(XXH64_SEED), .crc = std.hash.Crc32.init() };
    }
    pub fn update(self: *HashSink, bytes: []const u8) error{}!void {
        self.xxh.update(bytes);
        self.crc.update(bytes);
    }
    pub fn digest(self: *HashSink) Digest {
        return .{ .hash = self.xxh.final(), .crc = self.crc.final() };
    }
};

/// Content-hash a World (or `Parts`): the XXH64 + CRC32 of its canonical serialization. `gpa` is needed
/// for the canonical row ordering; nothing is materialized beyond that small permutation.
pub fn hashWorld(comptime R: type, gpa: std.mem.Allocator, world: anytype) !Digest {
    var sink = HashSink.init();
    try serialize.writeWorld(R, gpa, &sink, world);
    return sink.digest();
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const entity = @import("entity.zig");
const storage = @import("storage.zig");
const Registry = @import("registry.zig").Registry;
const Entity = entity.Entity;
const EntityAllocator = entity.EntityAllocator;
const ByteSink = serialize.ByteSink;

const Position = struct {
    x: fpz.Fixed,
    y: fpz.Fixed,
    pub const kind_id: u16 = 10;
};
const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 20;
};
const Reg = Registry(.{ Position, Health });

fn Parts() type {
    return serialize.Parts(Reg);
}

test "PINNED XXH64 test vector (freezes the content-hash algorithm)" {
    try testing.expectEqual(@as(u64, 0x44bc2cf5ad770999), std.hash.XxHash64.hash(0, "abc"));
    // streaming in chunks equals the one-shot hash
    var h = std.hash.XxHash64.init(0);
    h.update("a");
    h.update("bc");
    try testing.expectEqual(@as(u64, 0x44bc2cf5ad770999), h.final());
}

fn buildParts(gpa: std.mem.Allocator) !Parts() {
    var entities: EntityAllocator = .{};
    errdefer entities.deinit(gpa);
    const e0 = try entities.alloc(gpa);
    const e1 = try entities.alloc(gpa);

    var table: storage.Table(Reg) = .{};
    errdefer table.deinit(gpa);
    _ = try table.spawnRow(gpa, e0);
    _ = try table.spawnRow(gpa, e1);
    table.addComponent(e0, Position, .{ .x = fpz.Fixed.fromInt(1), .y = fpz.Fixed.fromInt(2) });
    table.addComponent(e1, Health, .{ .hp = 50 });
    return .{ .tick = 3, .schema_version = 1, .rng_root = .{ .seed = 5 }, .entities = entities, .table = table };
}

test "hashWorld equals XXH64/CRC32 of the canonical bytes (the D5 guarantee)" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);

    // bytes via the ByteSink path
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var bs = ByteSink{ .list = &buf, .gpa = gpa };
    try serialize.writeWorld(Reg, gpa, &bs, &parts);

    const d = try hashWorld(Reg, gpa, &parts);
    try testing.expectEqual(std.hash.XxHash64.hash(0, buf.items), d.hash);
    try testing.expectEqual(std.hash.Crc32.hash(buf.items), d.crc);
}

test "hashWorld is invariant to physical row order" {
    const gpa = testing.allocator;
    const e0 = Entity{ .index = 0, .generation = 0 };
    const e1 = Entity{ .index = 1, .generation = 0 };

    var allocA: EntityAllocator = .{};
    _ = try allocA.alloc(gpa);
    _ = try allocA.alloc(gpa);
    const allocB = try allocA.clone(gpa);

    var tA: storage.Table(Reg) = .{};
    _ = try tA.spawnRow(gpa, e0);
    _ = try tA.spawnRow(gpa, e1);
    tA.addComponent(e1, Health, .{ .hp = 9 });
    var pA = Parts(){ .tick = 1, .schema_version = 1, .rng_root = .{ .seed = 0 }, .entities = allocA, .table = tA };
    defer pA.deinit(gpa);

    var tB: storage.Table(Reg) = .{};
    _ = try tB.spawnRow(gpa, e1); // reversed physical order
    _ = try tB.spawnRow(gpa, e0);
    tB.addComponent(e1, Health, .{ .hp = 9 });
    var pB = Parts(){ .tick = 1, .schema_version = 1, .rng_root = .{ .seed = 0 }, .entities = allocB, .table = tB };
    defer pB.deinit(gpa);

    const dA = try hashWorld(Reg, gpa, &pA);
    const dB = try hashWorld(Reg, gpa, &pB);
    try testing.expectEqual(dA.hash, dB.hash);
    try testing.expectEqual(dA.crc, dB.crc);
}

test "add-then-remove hashes identically to never-added (canonical-zero-on-clear)" {
    const gpa = testing.allocator;
    const e0 = Entity{ .index = 0, .generation = 0 };

    var allocA: EntityAllocator = .{};
    _ = try allocA.alloc(gpa);
    const allocB = try allocA.clone(gpa);

    // A: spawn, never touch Health
    var tA: storage.Table(Reg) = .{};
    _ = try tA.spawnRow(gpa, e0);
    var pA = Parts(){ .tick = 0, .schema_version = 1, .rng_root = .{ .seed = 0 }, .entities = allocA, .table = tA };
    defer pA.deinit(gpa);

    // B: spawn, add Health with a distinctive value, then remove it
    var tB: storage.Table(Reg) = .{};
    _ = try tB.spawnRow(gpa, e0);
    tB.addComponent(e0, Health, .{ .hp = 0x7FFFFFFF });
    tB.removeComponent(e0, Health);
    var pB = Parts(){ .tick = 0, .schema_version = 1, .rng_root = .{ .seed = 0 }, .entities = allocB, .table = tB };
    defer pB.deinit(gpa);

    const dA = try hashWorld(Reg, gpa, &pA);
    const dB = try hashWorld(Reg, gpa, &pB);
    try testing.expectEqual(dA.hash, dB.hash);
}

test "different content hashes differently" {
    const gpa = testing.allocator;
    var parts = try buildParts(gpa);
    defer parts.deinit(gpa);
    const d0 = try hashWorld(Reg, gpa, &parts);

    parts.table.get(.{ .index = 1, .generation = 0 }, Health).?.hp = 51; // perturb one value
    const d1 = try hashWorld(Reg, gpa, &parts);
    try testing.expect(d0.hash != d1.hash);
}

// --- additional coverage (adversarial review: tests#6, determinism#2) ---

test "PINNED CRC32 vector (freezes the structural tripwire alongside XXH64)" {
    try testing.expectEqual(@as(u32, 0x352441c2), std.hash.Crc32.hash("abc"));
}

test "recycle an index then attach different components hashes identically to the churn-free build" {
    const gpa = testing.allocator;

    // World A: reach (index 0, generation 2) carrying only Health, via despawn/respawn churn that
    // also touched Position before the despawn (which should leave no residue — canonical-zero + the
    // row being deleted and re-created fresh).
    var aAlloc: EntityAllocator = .{};
    const a0 = try aAlloc.alloc(gpa); // (0,0)
    var aTab: storage.Table(Reg) = .{};
    _ = try aTab.spawnRow(gpa, a0);
    aTab.addComponent(a0, Position, .{ .x = fpz.Fixed.fromInt(123), .y = fpz.Fixed.fromInt(456) });
    aTab.despawnRow(a0);
    try aAlloc.free(gpa, a0); // generation -> 1
    const a2 = try aAlloc.alloc(gpa); // recycle (0,2)
    _ = try aTab.spawnRow(gpa, a2);
    aTab.addComponent(a2, Health, .{ .hp = 5 });
    var pA = Parts(){ .tick = 0, .schema_version = 1, .rng_root = .{ .seed = 0 }, .entities = aAlloc, .table = aTab };
    defer pA.deinit(gpa);

    // World B: reach the same (0,2)+Health with no Position churn at all.
    var bAlloc: EntityAllocator = .{};
    const b0 = try bAlloc.alloc(gpa); // (0,0)
    try bAlloc.free(gpa, b0); // generation -> 1
    const b2 = try bAlloc.alloc(gpa); // recycle (0,2)
    var bTab: storage.Table(Reg) = .{};
    _ = try bTab.spawnRow(gpa, b2);
    bTab.addComponent(b2, Health, .{ .hp = 5 });
    var pB = Parts(){ .tick = 0, .schema_version = 1, .rng_root = .{ .seed = 0 }, .entities = bAlloc, .table = bTab };
    defer pB.deinit(gpa);

    try testing.expectEqual((try hashWorld(Reg, gpa, &pA)).hash, (try hashWorld(Reg, gpa, &pB)).hash);
}
