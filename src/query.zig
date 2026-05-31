//! Comptime access markers + the Query iterator (SPEC §4, PLAN.md Phase 2; seam S1). Build step 3.
//!
//! A system declares its data dependencies *only* through the type of its `Query` parameter:
//!
//!     fn movement(ctx: *SimCtx(R), q: *Query(R, .{ Read(Position), Write(Velocity), With(Active), Without(Frozen) })) !void
//!
//! That single declaration is the one source of truth for (a) the scheduler's conflict DAG and (b) §7
//! reflection — they can never drift because there is no second place to declare access. `Read`/`Write`
//! grant component access (and imply "must have"); `With`/`Without` are pure row filters.
//!
//! The iterator walks the table in canonical order (the existing argsort — D9), filtered by the access
//! masks, yielding a `RowView` whose `read(C)`/`write(C)` are **compile-time gated**: writing a `Read`
//! component, or touching an undeclared one, is a `@compileError`, not a runtime check. In-place
//! Read/Write edits hit the live MAL columns and are valid within a stage (structural change is
//! deferred to the command buffer). SIMD column-batch access is the deferred S1 archetype upgrade.
//!
//! The access gate is an **authoring aid**, not a sandbox. The system author is trusted (SPEC §15: no
//! scripting sandbox — native Zig systems), so the bare `*Table` is reachable on the handle; a system
//! that deliberately reaches around `read`/`write` to touch an undeclared column would be scheduled
//! wrong, and the VOPR (§9) catches the resulting divergence. The gate makes the *honest* mistake
//! uncompilable; it does not defend against a malicious one.

const std = @import("std");
const storage = @import("storage.zig");
const entity = @import("entity.zig");
const Entity = entity.Entity;

/// The four kinds of declared access. A *declared* enum (not an enum literal) so switches are total.
pub const AccessKind = enum { read, write, with, without };

pub fn Read(comptime C: type) type {
    return struct {
        pub const access: AccessKind = .read;
        pub const Comp = C;
    };
}
pub fn Write(comptime C: type) type {
    return struct {
        pub const access: AccessKind = .write;
        pub const Comp = C;
    };
}
pub fn With(comptime C: type) type {
    return struct {
        pub const access: AccessKind = .with;
        pub const Comp = C;
    };
}
pub fn Without(comptime C: type) type {
    return struct {
        pub const access: AccessKind = .without;
        pub const Comp = C;
    };
}

/// The folded access of a Query, as masks over the registry bit space. Consumed by the scheduler
/// (conflict detection) and §7 reflection.
pub fn Access(comptime R: type) type {
    return struct {
        read: R.Mask = 0,
        write: R.Mask = 0,
        with: R.Mask = 0,
        without: R.Mask = 0,
    };
}

/// Fold a comptime tuple of access markers into the four masks.
pub fn foldAccess(comptime R: type, comptime markers: anytype) Access(R) {
    var a: Access(R) = .{};
    inline for (markers) |M| {
        const b = R.bitOf(M.Comp);
        switch (M.access) {
            .read => a.read |= b,
            .write => a.write |= b,
            .with => a.with |= b,
            .without => a.without |= b,
        }
    }
    return a;
}

/// A query over entities matching a comptime tuple of access markers.
pub fn Query(comptime R: type, comptime markers: anytype) type {
    return struct {
        const Self = @This();

        /// The folded access masks — the single source for scheduling and reflection.
        pub const access: Access(R) = foldAccess(R, markers);
        /// An entity must have every read/write/with component...
        pub const require: R.Mask = access.read | access.write | access.with;
        /// ...and none of the without components.
        pub const exclude: R.Mask = access.without;

        table: *storage.Table(R),
        order: []const u32,
        i: usize = 0,

        pub fn init(table: *storage.Table(R), order: []const u32) Self {
            return .{ .table = table, .order = order };
        }

        /// A handle to the current matched row. `read`/`write` are comptime-gated by the declared access.
        pub const RowView = struct {
            table: *storage.Table(R),
            row: u32,

            pub fn entity(self: RowView) Entity {
                return self.table.owners()[self.row];
            }
            /// Const access to a Read or Write component (compile error otherwise).
            pub fn read(self: RowView, comptime C: type) *const C {
                comptime assertAccess(C, true, true);
                return &self.table.column(R.indexOf(C))[self.row];
            }
            /// Mutable access to a Write component (compile error for Read/With/Without/undeclared).
            pub fn write(self: RowView, comptime C: type) *C {
                comptime assertAccess(C, false, true);
                return &self.table.column(R.indexOf(C))[self.row];
            }

            fn assertAccess(comptime C: type, comptime ok_read: bool, comptime ok_write: bool) void {
                inline for (markers) |M| {
                    if (M.Comp == C) {
                        if ((M.access == .read and ok_read) or (M.access == .write and ok_write)) return;
                        @compileError("access '" ++ @tagName(M.access) ++ "' of " ++ @typeName(C) ++ " not permitted in this Query");
                    }
                }
                @compileError("component " ++ @typeName(C) ++ " is not declared in this Query");
            }
        };

        /// Advance to the next matching row, or null when exhausted. Visits in canonical order.
        pub fn next(self: *Self) ?RowView {
            const ms = self.table.masks();
            while (self.i < self.order.len) {
                const row = self.order[self.i];
                self.i += 1;
                const m = ms[row];
                if ((m & require) == require and (m & exclude) == 0) {
                    return .{ .table = self.table, .row = row };
                }
            }
            return null;
        }
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------
//
// Negative cases are compile errors and so cannot be unit-tested in-suite (a failing compile fails the
// whole module). They are verified by design and documented here:
//   * `row.write(Position)` when Position is declared Read   -> @compileError "access 'read' ... not permitted"
//   * `row.read(Health)` when Health is not in the Query     -> @compileError "component ... not declared"
//   * `row.read(Active)` when Active is declared With         -> @compileError "access 'with' ... not permitted"

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("registry.zig").Registry;

const Position = struct {
    x: fpz.Fixed,
    y: fpz.Fixed,
    pub const kind_id: u16 = 1;
};
const Velocity = struct {
    dx: fpz.Fixed,
    pub const kind_id: u16 = 2;
};
const Active = struct {
    pub const kind_id: u16 = 3;
};
const Frozen = struct {
    pub const kind_id: u16 = 4;
};
const Reg = Registry(.{ Position, Velocity, Active, Frozen });
const T = storage.Table(Reg);

fn ent(i: u32) Entity {
    return .{ .index = i, .generation = 0 };
}

test "access masks fold correctly from markers" {
    const Q = Query(Reg, .{ Read(Position), Write(Velocity), With(Active), Without(Frozen) });
    try testing.expectEqual(Reg.bitOf(Position), Q.access.read);
    try testing.expectEqual(Reg.bitOf(Velocity), Q.access.write);
    try testing.expectEqual(Reg.bitOf(Active), Q.access.with);
    try testing.expectEqual(Reg.bitOf(Frozen), Q.access.without);
    try testing.expectEqual(Reg.bitOf(Position) | Reg.bitOf(Velocity) | Reg.bitOf(Active), Q.require);
    try testing.expectEqual(Reg.bitOf(Frozen), Q.exclude);
}

test "Query iterates exactly the matching entities in canonical order, and read/write hit the columns" {
    const gpa = testing.allocator;
    var t: T = .{};
    defer t.deinit(gpa);

    // e0: P,V,Active -> match ; e1: P,V,Active,Frozen -> excluded ; e2: P,Active (no V) -> excluded ;
    // e3: P,V,Active -> match
    inline for (.{ 0, 1, 2, 3 }) |i| _ = try t.spawnRow(gpa, ent(i));
    inline for (.{ 0, 1, 2, 3 }) |i| {
        t.addComponent(ent(i), Position, .{ .x = fpz.Fixed.fromInt(@intCast(i)), .y = fpz.Fixed.ZERO });
        t.addComponent(ent(i), Active, .{});
    }
    t.addComponent(ent(0), Velocity, .{ .dx = fpz.Fixed.ZERO });
    t.addComponent(ent(1), Velocity, .{ .dx = fpz.Fixed.ZERO });
    t.addComponent(ent(3), Velocity, .{ .dx = fpz.Fixed.ZERO });
    t.addComponent(ent(1), Frozen, .{});
    // churn physical order so canonical-order is doing real work
    _ = try t.spawnRow(gpa, ent(9));
    t.despawnRow(ent(9));

    const order = try t.canonicalOrder(gpa);
    defer gpa.free(order);

    var q = Query(Reg, .{ Read(Position), Write(Velocity), With(Active), Without(Frozen) }).init(&t, order);
    var seen: [4]bool = .{ false, false, false, false };
    var prev: i64 = -1;
    while (q.next()) |row| {
        const e = row.entity();
        seen[e.index] = true;
        try testing.expect(@as(i64, e.index) > prev); // canonical (ascending index) order
        prev = e.index;
        // read the Read component, write the Write component
        const px = row.read(Position).x.toInt();
        try testing.expectEqual(@as(i64, e.index), px);
        row.write(Velocity).dx = fpz.Fixed.fromInt(100 + px);
    }
    try testing.expect(seen[0] and seen[3]); // matched
    try testing.expect(!seen[1] and !seen[2]); // Frozen-excluded / missing-Velocity
    // the write landed in the column
    try testing.expectEqual(@as(i64, 100), t.get(ent(0), Velocity).?.dx.toInt());
    try testing.expectEqual(@as(i64, 103), t.get(ent(3), Velocity).?.dx.toInt());
}

test "a zero-marker Query matches every live entity in canonical order" {
    const gpa = testing.allocator;
    var t: T = .{};
    defer t.deinit(gpa);
    inline for (.{ 0, 1, 2 }) |i| _ = try t.spawnRow(gpa, ent(i));
    t.addComponent(ent(1), Position, .{ .x = fpz.Fixed.ZERO, .y = fpz.Fixed.ZERO }); // mixed: some bear components, some don't
    const order = try t.canonicalOrder(gpa);
    defer gpa.free(order);

    var q = Query(Reg, .{}).init(&t, order); // require == 0, exclude == 0 -> matches all live rows
    var n: usize = 0;
    var prev: i64 = -1;
    while (q.next()) |row| {
        const idx: i64 = row.entity().index;
        try testing.expect(idx > prev);
        prev = idx;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
}
