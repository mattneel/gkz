//! Flat dense component table (SPEC §3, PLAN.md build-order step 4; resolves Q9).
//!
//! Candidate C: every live entity occupies one row; a per-row bitmask records which components are
//! present; every registered component has a column with a slot in every row. The columns are a
//! single `std.MultiArrayList` over the registry's `Row` tuple `(Entity, Mask, C₀, C₁, …)`, so:
//!   * the SoA columns share one backing allocation, and
//!   * `swapRemove` relocates owner + mask + every component atomically — multi-column lockstep, the
//!     biggest hand-rolled determinism hazard, is handled by MAL by construction.
//! `index_to_row` (a plain array, never a HashMap — D5/D9) is the only separate structure: it maps an
//! `entity.index` to its row, patched by a single line after a swap.
//!
//! Determinism: physical row order is swap-remove-history-dependent and is NEVER serialized or hashed;
//! the canonical order is recomputed each tick by argsort of the owner column on the unique
//! `entity.index` key (D5). Mutators are total — a stale/missing handle is a deterministic no-op, never
//! an `unreachable` (D2). Clearing a component canonically zeroes its slot so stale bytes can never
//! reach the hash even under a mask-gating bug (Q7).

const std = @import("std");
const entity = @import("entity.zig");
const sortmod = @import("sort.zig");
const Entity = entity.Entity;
const ROW_NONE = entity.ROW_NONE;

/// A component table parameterized by a `Registry` type `R`.
pub fn Table(comptime R: type) type {
    return struct {
        const Self = @This();
        const Rows = std.MultiArrayList(R.Row);
        const Field = Rows.Field;

        rows: Rows = .empty,
        /// `index_to_row[entity.index]` = the entity's row, or `ROW_NONE`. An array, not a map.
        index_to_row: std.ArrayList(u32) = .empty,

        // MAL row field tags: owner = field 0, mask = field 1, component-at-tuple-index-i = field i+2.
        inline fn ownerField() Field {
            return @enumFromInt(0);
        }
        inline fn maskField() Field {
            return @enumFromInt(1);
        }
        inline fn compField(comptime i: usize) Field {
            return @enumFromInt(i + 2);
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.rows.deinit(gpa);
            self.index_to_row.deinit(gpa);
            self.* = undefined;
        }

        // --- column accessors (return mutable slices into the single backing allocation) ---

        /// The owner-entity column (one per row).
        pub fn owners(self: *const Self) []Entity {
            return self.rows.items(comptime ownerField());
        }
        /// The presence-mask column (one per row).
        pub fn masks(self: *const Self) []R.Mask {
            return self.rows.items(comptime maskField());
        }
        /// The storage column for component at tuple index `i`.
        pub fn column(self: *const Self, comptime i: usize) []R.Component(i) {
            return self.rows.items(comptime compField(i));
        }

        /// Number of rows (= live entities).
        pub fn rowCount(self: *const Self) usize {
            return self.rows.len;
        }

        /// Resolve a (possibly stale) handle to its row, or null. Rejects out-of-range, no-row, and
        /// stale-generation handles (the stored owner must equal `e` exactly).
        pub fn rowOf(self: *const Self, e: Entity) ?u32 {
            if (e.index >= self.index_to_row.items.len) return null;
            const row = self.index_to_row.items[e.index];
            if (row == ROW_NONE) return null;
            if (!std.meta.eql(self.owners()[row], e)) return null;
            return row;
        }

        /// Append a zeroed row owned by `e` (mask = 0, every component canonically zero). The caller
        /// (world/step) has already obtained `e` from the allocator. Returns the new row index.
        pub fn spawnRow(self: *Self, gpa: std.mem.Allocator, e: Entity) std.mem.Allocator.Error!u32 {
            // Grow the sparse index FIRST (a fallible step that does not touch row storage), so that
            // an OOM here leaves the table fully consistent — no orphaned row. (OOM is off the
            // determinism contract, but we keep the table self-consistent for clean teardown.)
            const need = @as(usize, e.index) + 1;
            if (need > self.index_to_row.items.len) {
                try self.index_to_row.ensureTotalCapacity(gpa, need);
                while (self.index_to_row.items.len < need) self.index_to_row.appendAssumeCapacity(ROW_NONE);
            }
            const row: u32 = @intCast(self.rows.len);
            var r: R.Row = undefined;
            r[0] = e;
            r[1] = 0;
            inline for (0..R.count) |i| r[i + 2] = std.mem.zeroes(R.Component(i));
            // If this append OOMs, index_to_row[e.index] is still ROW_NONE → table stays consistent.
            try self.rows.append(gpa, r);
            self.index_to_row.items[e.index] = row;
            return row;
        }

        /// Remove `e`'s row via swap-remove and patch the one relocated entity's `index_to_row`. Total:
        /// a stale/missing handle is a no-op.
        pub fn despawnRow(self: *Self, e: Entity) void {
            const row = self.rowOf(e) orelse return;
            const last: u32 = @intCast(self.rows.len - 1);
            self.rows.swapRemove(row);
            if (row != last) {
                // the entity formerly at `last` now occupies `row`.
                const moved = self.owners()[row];
                self.index_to_row.items[moved.index] = row;
            }
            self.index_to_row.items[e.index] = ROW_NONE;
        }

        /// True iff `e` is live and has component `C`.
        pub fn has(self: *const Self, e: Entity, comptime C: type) bool {
            const row = self.rowOf(e) orelse return false;
            return (self.masks()[row] & R.bitOf(C)) != 0;
        }

        /// Mutable pointer to `e`'s component `C`, or null if absent. Invalidated by any spawn (which
        /// may resize columns) — use within a tick, do not retain across structural change.
        pub fn get(self: *Self, e: Entity, comptime C: type) ?*C {
            const row = self.rowOf(e) orelse return null;
            if ((self.masks()[row] & R.bitOf(C)) == 0) return null;
            return &self.column(R.indexOf(C))[row];
        }

        /// Set component `C` on `e` (sets the presence bit + writes the value). Total no-op if `e` is
        /// not live.
        pub fn addComponent(self: *Self, e: Entity, comptime C: type, value: C) void {
            const row = self.rowOf(e) orelse return;
            self.masks()[row] |= R.bitOf(C);
            self.column(R.indexOf(C))[row] = value;
        }

        /// Clear component `C` on `e` (clears the bit + canonically zeroes the slot). Total no-op if
        /// `e` is not live.
        pub fn removeComponent(self: *Self, e: Entity, comptime C: type) void {
            const row = self.rowOf(e) orelse return;
            self.masks()[row] &= ~R.bitOf(C);
            self.column(R.indexOf(C))[row] = std.mem.zeroes(C);
        }

        /// Allocate and return the rows in canonical order: row indices sorted ascending by owner
        /// `entity.index` (unique among live rows). Recomputed every hash/serialize; caller frees.
        pub fn canonicalOrder(self: *const Self, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u32 {
            const n = self.rows.len;
            const order = try gpa.alloc(u32, n);
            for (0..n) |i| order[i] = @intCast(i);
            const Ctx = struct { owner: []const Entity };
            sortmod.sort(u32, order, Ctx{ .owner = self.owners() }, struct {
                fn lt(ctx: Ctx, a: u32, b: u32) bool {
                    return ctx.owner[a].index < ctx.owner[b].index;
                }
            }.lt);
            return order;
        }

        pub fn clone(self: *const Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!Self {
            var rows = try self.rows.clone(gpa);
            errdefer rows.deinit(gpa);
            var itr: std.ArrayList(u32) = .empty;
            errdefer itr.deinit(gpa);
            try itr.appendSlice(gpa, self.index_to_row.items);
            return .{ .rows = rows, .index_to_row = itr };
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
    pub const kind_id: u16 = 10;
};
const Velocity = struct {
    dx: fpz.Fixed,
    pub const kind_id: u16 = 5;
};
const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 20;
};
const Reg = Registry(.{ Position, Velocity, Health });
const T = Table(Reg);

fn ent(i: u32, g: u32) Entity {
    return .{ .index = i, .generation = g };
}

test "spawn records owner, row, and index_to_row" {
    const gpa = testing.allocator;
    var t: T = .{};
    defer t.deinit(gpa);

    const r0 = try t.spawnRow(gpa, ent(0, 0));
    const r1 = try t.spawnRow(gpa, ent(1, 0));
    try testing.expectEqual(@as(u32, 0), r0);
    try testing.expectEqual(@as(u32, 1), r1);
    try testing.expectEqual(@as(usize, 2), t.rowCount());
    try testing.expectEqual(@as(?u32, 0), t.rowOf(ent(0, 0)));
    try testing.expectEqual(@as(?u32, 1), t.rowOf(ent(1, 0)));
}

test "addComponent / get / has" {
    const gpa = testing.allocator;
    var t: T = .{};
    defer t.deinit(gpa);
    const e = ent(0, 0);
    _ = try t.spawnRow(gpa, e);

    try testing.expect(!t.has(e, Position));
    t.addComponent(e, Position, .{ .x = fpz.Fixed.fromInt(3), .y = fpz.Fixed.fromInt(4) });
    try testing.expect(t.has(e, Position));
    try testing.expect(!t.has(e, Velocity));
    const p = t.get(e, Position).?;
    try testing.expectEqual(@as(i64, 3), p.x.toInt());
    try testing.expectEqual(@as(i64, 4), p.y.toInt());
}

test "removeComponent clears the bit AND canonically zeroes the slot" {
    const gpa = testing.allocator;
    var t: T = .{};
    defer t.deinit(gpa);
    const e = ent(0, 0);
    _ = try t.spawnRow(gpa, e);
    t.addComponent(e, Health, .{ .hp = 123 });
    try testing.expect(t.has(e, Health));

    t.removeComponent(e, Health);
    try testing.expect(!t.has(e, Health));
    try testing.expectEqual(@as(?*Health, null), t.get(e, Health));
    // the underlying slot is canonical-zero (defense-in-depth, Q7)
    const row = t.index_to_row.items[e.index];
    try testing.expect(std.meta.eql(Health{ .hp = 0 }, t.column(Reg.indexOf(Health))[row]));
}

test "despawn swap-removes and fixes the relocated entity's index_to_row" {
    const gpa = testing.allocator;
    var t: T = .{};
    defer t.deinit(gpa);
    const a = ent(0, 0);
    const b = ent(1, 0);
    const c = ent(2, 0);
    _ = try t.spawnRow(gpa, a); // row 0
    _ = try t.spawnRow(gpa, b); // row 1
    _ = try t.spawnRow(gpa, c); // row 2
    t.addComponent(c, Health, .{ .hp = 7 });

    // despawn the middle row: c (row 2, last) swaps into row 1.
    t.despawnRow(b);
    try testing.expectEqual(@as(usize, 2), t.rowCount());
    try testing.expectEqual(@as(?u32, null), t.rowOf(b)); // gone
    try testing.expectEqual(@as(?u32, 0), t.rowOf(a)); // unchanged
    // c relocated to row 1 and still resolves with its component intact
    try testing.expectEqual(@as(?u32, 1), t.rowOf(c));
    try testing.expectEqual(@as(i32, 7), t.get(c, Health).?.hp);
}

test "rowOf rejects a stale-generation handle" {
    const gpa = testing.allocator;
    var t: T = .{};
    defer t.deinit(gpa);
    _ = try t.spawnRow(gpa, ent(0, 0));
    try testing.expectEqual(@as(?u32, null), t.rowOf(ent(0, 2))); // same slot, wrong generation
    try testing.expectEqual(@as(?u32, null), t.rowOf(ent(5, 0))); // out of range
}

test "mutators are total no-ops on stale/missing handles" {
    const gpa = testing.allocator;
    var t: T = .{};
    defer t.deinit(gpa);
    _ = try t.spawnRow(gpa, ent(0, 0));
    // these must not panic / corrupt; just no-op
    t.addComponent(ent(0, 9), Position, .{ .x = fpz.Fixed.ZERO, .y = fpz.Fixed.ZERO });
    t.removeComponent(ent(0, 9), Position);
    t.despawnRow(ent(7, 0));
    try testing.expect(!t.has(ent(0, 0), Position));
    try testing.expectEqual(@as(usize, 1), t.rowCount());
}

test "canonicalOrder sorts rows by owner index regardless of physical layout" {
    const gpa = testing.allocator;
    var t: T = .{};
    defer t.deinit(gpa);
    // spawn 0,1,2,3 then despawn 1 -> swap-remove churns physical order (3 moves into row 1)
    _ = try t.spawnRow(gpa, ent(0, 0));
    _ = try t.spawnRow(gpa, ent(1, 0));
    _ = try t.spawnRow(gpa, ent(2, 0));
    _ = try t.spawnRow(gpa, ent(3, 0));
    t.despawnRow(ent(1, 0));

    const order = try t.canonicalOrder(gpa);
    defer gpa.free(order);
    // canonical order must visit owners 0,2,3 ascending no matter the physical rows
    var prev: u32 = 0;
    for (order, 0..) |row, k| {
        const idx = t.owners()[row].index;
        if (k > 0) try testing.expect(idx > prev);
        prev = idx;
    }
    try testing.expectEqual(@as(usize, 3), order.len);
}

test "clone is independent and value-identical" {
    const gpa = testing.allocator;
    var t: T = .{};
    defer t.deinit(gpa);
    const e = ent(0, 0);
    _ = try t.spawnRow(gpa, e);
    t.addComponent(e, Position, .{ .x = fpz.Fixed.fromInt(9), .y = fpz.Fixed.ZERO });

    var c = try t.clone(gpa);
    defer c.deinit(gpa);
    try testing.expectEqual(@as(i64, 9), c.get(e, Position).?.x.toInt());
    // mutate the clone; original unaffected
    _ = try c.spawnRow(gpa, ent(1, 0));
    try testing.expectEqual(@as(usize, 1), t.rowCount());
    try testing.expectEqual(@as(usize, 2), c.rowCount());
}
