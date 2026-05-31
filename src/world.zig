//! The World — the simulation state as a value (SPEC §1/§3, PLAN.md build-order step 8).
//!
//! `World(Reg)` is exactly SPEC §3's enumeration: the component columns (`table`) + the entity
//! allocator (`entities`) + the keyed RNG root (`rng_root`) + the tick counter — plus a
//! `schema_version` carried for §12 migration. It owns no pointers out and exposes none in (D8/D1), so
//! it can be cloned, serialized, hashed, and diffed as a value; `step` produces a successor World from
//! a World and an Input.

const std = @import("std");
const entity = @import("entity.zig");
const storage = @import("storage.zig");
const rng = @import("rng.zig");
const hashmod = @import("hash.zig");
const serialize = @import("serialize.zig");
const Entity = entity.Entity;

pub fn World(comptime Reg: type) type {
    return struct {
        const Self = @This();
        /// The component registry this World is specialized to.
        pub const Components = Reg;
        /// The component-table type.
        pub const TableType = storage.Table(Reg);

        tick: u64 = 0,
        schema_version: u32 = 1,
        rng_root: rng.RngRoot = .{ .seed = 0 },
        entities: entity.EntityAllocator = .{},
        table: TableType = .{},

        /// A fresh, empty World seeded for RNG.
        pub fn init(seed: u64) Self {
            return .{ .rng_root = .{ .seed = seed } };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.entities.deinit(gpa);
            self.table.deinit(gpa);
            self.* = undefined;
        }

        /// Deep, independent copy (value semantics, D1). The source is untouched.
        pub fn clone(self: *const Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!Self {
            var ents = try self.entities.clone(gpa);
            errdefer ents.deinit(gpa);
            var tbl = try self.table.clone(gpa);
            errdefer tbl.deinit(gpa);
            return .{
                .tick = self.tick,
                .schema_version = self.schema_version,
                .rng_root = self.rng_root,
                .entities = ents,
                .table = tbl,
            };
        }

        /// Allocate an entity and create its empty row. Returns the handle. On allocation failure (OOM,
        /// which is off the determinism contract — a failed run, not a divergence) the World remains
        /// safe to `deinit` but may hold a live entity without a row; discard the World in that case.
        pub fn spawn(self: *Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!Entity {
            const e = try self.entities.alloc(gpa);
            _ = try self.table.spawnRow(gpa, e);
            return e;
        }

        /// Remove an entity's row then free its handle. Total no-op on a stale/dead handle. (Table
        /// first: `despawnRow` resolves via the table's own owner record, so ordering is safe.)
        pub fn despawn(self: *Self, gpa: std.mem.Allocator, e: Entity) std.mem.Allocator.Error!void {
            self.table.despawnRow(e);
            try self.entities.free(gpa, e);
        }

        pub fn isLive(self: *const Self, e: Entity) bool {
            return self.entities.isLive(e);
        }
        pub fn add(self: *Self, e: Entity, comptime C: type, value: C) void {
            self.table.addComponent(e, C, value);
        }
        pub fn remove(self: *Self, e: Entity, comptime C: type) void {
            self.table.removeComponent(e, C);
        }
        pub fn get(self: *Self, e: Entity, comptime C: type) ?*C {
            return self.table.get(e, C);
        }
        pub fn has(self: *const Self, e: Entity, comptime C: type) bool {
            return self.table.has(e, C);
        }

        /// Content hash (XXH64 + CRC32) of this World's canonical serialization.
        pub fn digest(self: *const Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!hashmod.Digest {
            return hashmod.hashWorld(Reg, gpa, self);
        }

        /// Assemble a World by taking ownership of deserialized `Parts` (restore path).
        pub fn fromParts(parts: serialize.Parts(Reg)) Self {
            return .{
                .tick = parts.tick,
                .schema_version = parts.schema_version,
                .rng_root = parts.rng_root,
                .entities = parts.entities,
                .table = parts.table,
            };
        }
    };
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
const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 2;
};
const Game = Registry(.{ Position, Health });
const W = World(Game);

test "spawn creates a live entity with a row; add/get/has work" {
    const gpa = testing.allocator;
    var w = W.init(123);
    defer w.deinit(gpa);

    const e = try w.spawn(gpa);
    try testing.expect(w.isLive(e));
    try testing.expect(!w.has(e, Position));
    w.add(e, Position, .{ .x = fpz.Fixed.fromInt(2), .y = fpz.Fixed.fromInt(3) });
    try testing.expect(w.has(e, Position));
    try testing.expectEqual(@as(i64, 2), w.get(e, Position).?.x.toInt());
    try testing.expectEqual(@as(usize, 1), w.table.rowCount());
}

test "despawn frees the handle and removes the row" {
    const gpa = testing.allocator;
    var w = W.init(0);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    try w.despawn(gpa, e);
    try testing.expect(!w.isLive(e));
    try testing.expectEqual(@as(usize, 0), w.table.rowCount());
    // a recycled entity gets a fresh even generation
    const e2 = try w.spawn(gpa);
    try testing.expect(w.isLive(e2));
    try testing.expect(!w.isLive(e)); // old handle stays dead
}

test "clone is independent and hashes identically" {
    const gpa = testing.allocator;
    var w = W.init(7);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Health, .{ .hp = 10 });

    var c = try w.clone(gpa);
    defer c.deinit(gpa);
    try testing.expectEqual((try w.digest(gpa)).hash, (try c.digest(gpa)).hash);

    // mutating the clone does not perturb the original
    _ = try c.spawn(gpa);
    try testing.expect((try w.digest(gpa)).hash != (try c.digest(gpa)).hash);
    try testing.expectEqual(@as(usize, 1), w.table.rowCount());
}

test "tick and rng_root are part of the hashed value" {
    const gpa = testing.allocator;
    var a = W.init(1);
    defer a.deinit(gpa);
    var b = W.init(1);
    defer b.deinit(gpa);
    try testing.expectEqual((try a.digest(gpa)).hash, (try b.digest(gpa)).hash);

    b.tick = 5;
    try testing.expect((try a.digest(gpa)).hash != (try b.digest(gpa)).hash);
}
