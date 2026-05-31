//! The named-Atom leaf substrate for §8 specs (PLAN.md Phase 6, build-order step 1).
//!
//! An `Atom(R)` is a NAMED, PURE observation over a `*const World(R)` — `eval` returns an `AtomHit`
//! carrying whether the atom holds, an optional scalar (for metrics / `monotonic_unless`), and a
//! canonical multi-entity `Witness` (so "no two solids overlap … the entities involved" can pin BOTH,
//! honoring §8's plural). Atoms are the leaves invariants, temporal properties, and metrics are built
//! from. `eval` takes no allocator, so a witness is found by an allocation-free min-scan that tracks the
//! canonical-smallest offender — deterministic without `canonicalOrder` (D9). Atoms are comptime-declared
//! (the `eval` fn closes over comptime params); runtime-parameterized atoms are a future extension.
//!
//! D-contract: every field of `Witness`/`AtomHit` is POD (no float D7, no pointer D8) so a witness rides
//! the §4 `Defect` and the §7 `Value` space unchanged. Reads go through `World.table`'s const accessors
//! (`World.get` is `*Self`); a `*const World` makes mutation type-impossible (D1).

const std = @import("std");
const worldmod = @import("../world.zig");
const entity = @import("../entity.zig");
const Entity = entity.Entity;
const event_log = @import("../event_log.zig");

/// Max entities a single witness pins (§8's "no two solids overlap" needs 2; headroom to 4).
pub const MAX_WITNESS: usize = 4;

/// A canonically-ordered, pointer-free set of the entities a violation implicates.
pub const Witness = struct {
    n: u8 = 0,
    ents: [MAX_WITNESS]Entity = [_]Entity{.{ .index = 0, .generation = 0 }} ** MAX_WITNESS,

    pub fn single(e: Entity) Witness {
        var w: Witness = .{};
        w.add(e);
        return w;
    }

    /// Insert `e` in canonical (index, generation) order, deduped; drops the largest if already full
    /// (the kept set stays the MAX_WITNESS canonical-smallest — deterministic).
    pub fn add(self: *Witness, e: Entity) void {
        // dedup
        for (self.ents[0..self.n]) |x| {
            if (x.index == e.index and x.generation == e.generation) return;
        }
        // find sorted insert position
        var pos: usize = 0;
        while (pos < self.n and lessEnt(self.ents[pos], e)) : (pos += 1) {}
        if (pos >= MAX_WITNESS) return; // e is larger than everything we keep
        // shift right (drop the last if full)
        var i: usize = @min(self.n, MAX_WITNESS - 1);
        while (i > pos) : (i -= 1) self.ents[i] = self.ents[i - 1];
        self.ents[pos] = e;
        if (self.n < MAX_WITNESS) self.n += 1;
    }
};

fn lessEnt(a: Entity, b: Entity) bool {
    if (a.index != b.index) return a.index < b.index;
    return a.generation < b.generation;
}

/// The result of evaluating an atom at one tick/World.
pub const AtomHit = struct {
    holds: bool,
    scalar: i64 = 0, // meaningful for scalar atoms (metrics, monotonic_unless); 0 otherwise
    witness: Witness = .{},
};

/// A named pure observation over a World. `eval` is allocation-free and side-effect-free.
pub fn Atom(comptime R: type) type {
    return struct {
        name: []const u8,
        eval: *const fn (*const worldmod.World(R)) AtomHit,
    };
}

/// The declared type of struct field `field` on `C`.
fn FieldType(comptime C: type, comptime field: []const u8) type {
    inline for (@typeInfo(C).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, field)) return f.type;
    }
    @compileError(@typeName(C) ++ " has no field '" ++ field ++ "'");
}

/// Comptime-assert `C.field` is an integer that fits losslessly in `i64`, so the per-tick
/// `@intCast(... -> i64)` in the scalar/range atoms can NEVER trap (Debug/Safe) or wrap (ReleaseFast) —
/// a u64 with the high bit set would otherwise be a D2 build-mode divergence. Over-wide / non-integer
/// fields are a compile error here, not a runtime hazard.
fn assertI64Field(comptime C: type, comptime field: []const u8) void {
    switch (@typeInfo(FieldType(C, field))) {
        .int => |info| {
            const fits = if (info.signedness == .signed) info.bits <= 64 else info.bits <= 63;
            if (!fits) @compileError("spec atom field '" ++ field ++ "' of " ++ @typeName(C) ++ " must fit i64 (signed<=64 / unsigned<=63 bits)");
        },
        else => @compileError("spec atom field '" ++ field ++ "' of " ++ @typeName(C) ++ " must be an integer"),
    }
}

// --- built-in atom constructors -------------------------------------------------------------------
// Each returns an Atom(R); a violation yields holds=false + a canonical Witness. invariant.zig adapts
// an Atom to the `fn(*const World) ?Entity` shape oracle.invariant/firstTickWhere consume.

/// Holds iff every live entity carrying `C` has integer field `field` within [lo, hi]. Witness = the
/// canonical-smallest out-of-range entity (the §8 `health ∈ [0,max]` invariant).
pub fn rangeI(comptime R: type, comptime C: type, comptime field: []const u8, comptime lo: i64, comptime hi: i64) Atom(R) {
    comptime assertI64Field(C, field);
    const Impl = struct {
        fn eval(w: *const worldmod.World(R)) AtomHit {
            const ti = comptime R.indexOf(C);
            const col = w.table.column(ti);
            const owners = w.table.owners();
            const masks = w.table.masks();
            const bit = R.bit(ti);
            var hit: ?Entity = null;
            for (owners, 0..) |e, row| {
                if ((masks[row] & bit) == 0) continue;
                const v: i64 = @intCast(@field(col[row], field));
                if (v < lo or v > hi) {
                    if (hit == null or lessEnt(e, hit.?)) hit = e;
                }
            }
            if (hit) |e| return .{ .holds = false, .witness = Witness.single(e) };
            return .{ .holds = true };
        }
    };
    return .{ .name = "rangeI(" ++ @typeName(C) ++ "." ++ field ++ ")", .eval = Impl.eval };
}

/// Holds iff every live `C` entity's `ref_field` (an `Entity`) is itself live (the §8 "every entity
/// referenced by a component exists"). Witness = the canonical-smallest entity with a dangling ref.
pub fn referencedLive(comptime R: type, comptime C: type, comptime ref_field: []const u8) Atom(R) {
    const Impl = struct {
        fn eval(w: *const worldmod.World(R)) AtomHit {
            const ti = comptime R.indexOf(C);
            const col = w.table.column(ti);
            const owners = w.table.owners();
            const masks = w.table.masks();
            const bit = R.bit(ti);
            var hit: ?Entity = null;
            for (owners, 0..) |e, row| {
                if ((masks[row] & bit) == 0) continue;
                const ref: Entity = @field(col[row], ref_field);
                if (!w.isLive(ref)) {
                    if (hit == null or lessEnt(e, hit.?)) hit = e;
                }
            }
            if (hit) |e| return .{ .holds = false, .witness = Witness.single(e) };
            return .{ .holds = true };
        }
    };
    return .{ .name = "referencedLive(" ++ @typeName(C) ++ "." ++ ref_field ++ ")", .eval = Impl.eval };
}

/// Holds iff no two live `C` entities share the same (fx, fy) integer position (the §8 "no two solids
/// overlap"). Witness pins BOTH entities of the canonical-smallest colliding pair (multi-entity).
pub fn noOverlap(comptime R: type, comptime C: type, comptime fx: []const u8, comptime fy: []const u8) Atom(R) {
    comptime assertI64Field(C, fx);
    comptime assertI64Field(C, fy);
    const Impl = struct {
        fn eval(w: *const worldmod.World(R)) AtomHit {
            const ti = comptime R.indexOf(C);
            const col = w.table.column(ti);
            const owners = w.table.owners();
            const masks = w.table.masks();
            const bit = R.bit(ti);
            var best: ?[2]Entity = null;
            for (owners, 0..) |a, ra| {
                if ((masks[ra] & bit) == 0) continue;
                for (owners[ra + 1 ..], ra + 1..) |b, rb| {
                    if ((masks[rb] & bit) == 0) continue;
                    const ax: i64 = @intCast(@field(col[ra], fx));
                    const ay: i64 = @intCast(@field(col[ra], fy));
                    const bx: i64 = @intCast(@field(col[rb], fx));
                    const by: i64 = @intCast(@field(col[rb], fy));
                    if (ax == bx and ay == by) {
                        // canonical pair (smaller entity first); keep the canonical-smallest pair
                        const lo = if (lessEnt(a, b)) a else b;
                        const hi = if (lessEnt(a, b)) b else a;
                        if (best == null or lessEnt(lo, best.?[0]) or (eqEnt(lo, best.?[0]) and lessEnt(hi, best.?[1]))) {
                            best = .{ lo, hi };
                        }
                    }
                }
            }
            if (best) |pair| {
                var wit: Witness = .{};
                wit.add(pair[0]);
                wit.add(pair[1]);
                return .{ .holds = false, .witness = wit };
            }
            return .{ .holds = true };
        }
    };
    return .{ .name = "noOverlap(" ++ @typeName(C) ++ ")", .eval = Impl.eval };
}

/// Holds iff `handle` is live. Witness = `handle` when dead. (A presence guard.)
pub fn entityLive(comptime R: type, comptime handle: Entity) Atom(R) {
    const Impl = struct {
        fn eval(w: *const worldmod.World(R)) AtomHit {
            if (w.isLive(handle)) return .{ .holds = true };
            return .{ .holds = false, .witness = Witness.single(handle) };
        }
    };
    return .{ .name = "entityLive", .eval = Impl.eval };
}

/// Bool atom: holds iff `handle`'s `C.field` ≤ `thresh` (e.g. boss_dead = hp ≤ 0). Witness = `handle`.
/// If `handle` lacks `C`, treated as NOT holding (witness=handle) — a missing boss is "not dead".
pub fn fieldLE(comptime R: type, comptime C: type, comptime field: []const u8, comptime handle: Entity, comptime thresh: i64) Atom(R) {
    comptime assertI64Field(C, field);
    const Impl = struct {
        fn eval(w: *const worldmod.World(R)) AtomHit {
            if (w.table.rowOf(handle)) |row| {
                const ti = comptime R.indexOf(C);
                if ((w.table.masks()[row] & R.bit(ti)) != 0) {
                    const v: i64 = @intCast(@field(w.table.column(ti)[row], field));
                    if (v <= thresh) return .{ .holds = true, .scalar = v };
                    return .{ .holds = false, .scalar = v, .witness = Witness.single(handle) };
                }
            }
            return .{ .holds = false, .witness = Witness.single(handle) };
        }
    };
    return .{ .name = "fieldLE(" ++ @typeName(C) ++ "." ++ field ++ ")", .eval = Impl.eval };
}

/// Scalar atom: `scalar` = `handle`'s `C.field` (e.g. the score). `holds` mirrors presence. Used by
/// `monotonic_unless` and metrics. Missing component → scalar 0, holds=false.
pub fn scalarField(comptime R: type, comptime C: type, comptime field: []const u8, comptime handle: Entity) Atom(R) {
    comptime assertI64Field(C, field);
    const Impl = struct {
        fn eval(w: *const worldmod.World(R)) AtomHit {
            if (w.table.rowOf(handle)) |row| {
                const ti = comptime R.indexOf(C);
                if ((w.table.masks()[row] & R.bit(ti)) != 0) {
                    return .{ .holds = true, .scalar = @intCast(@field(w.table.column(ti)[row], field)) };
                }
            }
            return .{ .holds = false };
        }
    };
    return .{ .name = "scalarField(" ++ @typeName(C) ++ "." ++ field ++ ")", .eval = Impl.eval };
}

fn eqEnt(a: Entity, b: Entity) bool {
    return a.index == b.index and a.generation == b.generation;
}

/// Event-atom helper: true iff `log` carries an event of `kind_id` at `tick`. (The trace samples this
/// per tick into a bool column; `monotonic_unless`'s "except on a Penalty event" reads it.)
pub fn hasEventKind(log: *const event_log.EventLog, tick: u64, kind_id: u16) bool {
    for (log.events.items) |e| {
        if (e.id.tick == tick and e.kind == kind_id) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const serialize = @import("../serialize.zig");

const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 1;
};
const Pos = struct {
    x: i64,
    y: i64,
    pub const kind_id: u16 = 2;
};
const Link = struct {
    target: Entity,
    pub const kind_id: u16 = 3;
};
const Game = Registry(.{ Health, Pos, Link });

test "Witness pins entities in canonical (index,generation) order, deduped, pointer-free" {
    var w: Witness = .{};
    w.add(.{ .index = 5, .generation = 0 });
    w.add(.{ .index = 2, .generation = 1 });
    w.add(.{ .index = 5, .generation = 0 }); // dup
    w.add(.{ .index = 2, .generation = 0 });
    try testing.expectEqual(@as(u8, 3), w.n);
    try testing.expectEqual(@as(u32, 2), w.ents[0].index);
    try testing.expectEqual(@as(u32, 0), w.ents[0].generation); // (2,0) before (2,1)
    try testing.expectEqual(@as(u32, 1), w.ents[1].generation); // ents[1] = (2,1)
    try testing.expectEqual(@as(u32, 5), w.ents[2].index);
    // POD / serializable (no float, no pointer)
    try testing.expect(serialize.serializedSizeOf(Witness) > 0);
}

test "rangeI returns the canonical-first out-of-range entity, null when all in range" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const e0 = try w.spawn(gpa);
    const e1 = try w.spawn(gpa);
    const e2 = try w.spawn(gpa);
    w.add(e0, Health, .{ .hp = 10 });
    w.add(e1, Health, .{ .hp = -5 }); // out of range
    w.add(e2, Health, .{ .hp = -1 }); // also out of range, but e1 < e2 canonically
    const atom = rangeI(Game, Health, "hp", 0, 100);
    const hit = atom.eval(&w);
    try testing.expect(!hit.holds);
    try testing.expectEqual(@as(u32, 1), hit.witness.ents[0].index); // e1, the canonical-first offender
    // all in range -> holds
    w.get(e1, Health).?.hp = 3;
    w.get(e2, Health).?.hp = 3;
    try testing.expect(rangeI(Game, Health, "hp", 0, 100).eval(&w).holds);
}

test "noOverlap pins BOTH entities of the canonical-smallest colliding pair" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const e0 = try w.spawn(gpa);
    const e1 = try w.spawn(gpa);
    const e2 = try w.spawn(gpa);
    w.add(e0, Pos, .{ .x = 1, .y = 1 });
    w.add(e1, Pos, .{ .x = 9, .y = 9 });
    w.add(e2, Pos, .{ .x = 1, .y = 1 }); // overlaps e0
    const hit = noOverlap(Game, Pos, "x", "y").eval(&w);
    try testing.expect(!hit.holds);
    try testing.expectEqual(@as(u8, 2), hit.witness.n);
    try testing.expectEqual(@as(u32, 0), hit.witness.ents[0].index); // e0
    try testing.expectEqual(@as(u32, 2), hit.witness.ents[1].index); // e2
    // separate them -> holds
    w.get(e2, Pos).?.x = 5;
    try testing.expect(noOverlap(Game, Pos, "x", "y").eval(&w).holds);
}

test "referencedLive flags a dangling entity reference" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const a = try w.spawn(gpa);
    const b = try w.spawn(gpa);
    w.add(a, Link, .{ .target = b });
    try testing.expect(referencedLive(Game, Link, "target").eval(&w).holds);
    try w.despawn(gpa, b); // now a.target dangles
    const hit = referencedLive(Game, Link, "target").eval(&w);
    try testing.expect(!hit.holds);
    try testing.expectEqual(a.index, hit.witness.ents[0].index);
}

test "fieldLE / scalarField read a designated entity's field" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const boss = try w.spawn(gpa); // index 0
    w.add(boss, Health, .{ .hp = 7 });
    const dead = fieldLE(Game, Health, "hp", .{ .index = 0, .generation = 0 }, 0);
    try testing.expect(!dead.eval(&w).holds); // hp 7 > 0 -> not dead
    w.get(boss, Health).?.hp = 0;
    try testing.expect(dead.eval(&w).holds); // hp 0 <= 0 -> dead
    const score = scalarField(Game, Health, "hp", .{ .index = 0, .generation = 0 });
    try testing.expectEqual(@as(i64, 0), score.eval(&w).scalar);
}

test "hasEventKind reads the borrowed log at a tick" {
    const gpa = testing.allocator;
    var log: event_log.EventLog = .{};
    defer log.deinit(gpa);
    try log.append(gpa, .{ .tick = 3, .emitter = 0, .seq = 0 }, 99, 0, .{ .index = 0, .generation = 0 }, &.{}, &.{});
    try testing.expect(hasEventKind(&log, 3, 99));
    try testing.expect(!hasEventKind(&log, 3, 100));
    try testing.expect(!hasEventKind(&log, 4, 99));
}
