//! The every-tick state-invariant assertion hook (PLAN.md Phase 6, build-order step 4): §8's "checked
//! every tick in ReleaseSafe/Debug".
//!
//! D2 holds BY CONSTRUCTION: `checkAll` takes `*const World(R)` (mutation is type-impossible — pure
//! observation, D1), allocates nothing, and its body is wrapped in `if (std.debug.runtime_safety)` so it
//! is COMPLETELY ABSENT from the ReleaseFast object. Turning checks off removes the branch; since the
//! predicate never writes, checks-on and checks-off produce bit-identical Worlds and hashes — exactly the
//! "determinism never depends on safety checks being compiled in" rule (mirrors step.zig's existing
//! `std.debug.assert` discipline). The panic message formats ONLY canonical integers (tick:u64,
//! entity.index/generation:u32) + the invariant name — no float (D7), no pointer (D8).
//!
//! `findViolation` is the pure, always-compiled detector (so it is unit-testable without an uncatchable
//! panic); `checkAll` is the thin assertion built on it. The in-step hook (step.runScheduled) is
//! OPTIONAL — `oracle.invariant` already checks every tick on demand, so this is the Debug-time
//! fast-feedback path, cleanly droppable.

const std = @import("std");
const worldmod = @import("../world.zig");
const Entity = @import("../entity.zig").Entity;
const invariantmod = @import("invariant.zig");
const Invariant = invariantmod.Invariant;

/// A located invariant breach: which invariant, and the offending entity.
pub fn Breach(comptime R: type) type {
    _ = R;
    return struct { name: []const u8, entity: Entity };
}

/// The first invariant in `invs` (declaration order) that the World violates, or null if all hold. Pure,
/// allocation-free, always compiled — the testable core of `checkAll`.
pub fn findViolation(comptime R: type, comptime invs: []const Invariant(R), w: *const worldmod.World(R)) ?Breach(R) {
    inline for (invs) |inv| {
        if (inv.pred(w)) |e| return .{ .name = inv.name, .entity = e };
    }
    return null;
}

/// Assert every invariant holds for `w`. A no-op (DCE'd) in ReleaseFast; in Debug/ReleaseSafe a violation
/// panics with a canonical (name, tick, entity) message. Borrow-only — cannot perturb the hashed World.
pub fn checkAll(comptime R: type, comptime invs: []const Invariant(R), w: *const worldmod.World(R)) void {
    if (std.debug.runtime_safety) {
        if (findViolation(R, invs, w)) |b| {
            std.debug.panic("invariant '{s}' violated at tick {d} by entity {d}.{d}", .{ b.name, w.tick, b.entity.index, b.entity.generation });
        }
    }
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const atom = @import("atom.zig");

const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Health});
const demo_invs = [_]Invariant(Game){invariantmod.fromAtom(Game, atom.rangeI(Game, Health, "hp", 0, 1_000_000))};

test "findViolation returns null when all invariants hold, the breach when one fails" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Health, .{ .hp = 5 });
    try testing.expectEqual(@as(?Breach(Game), null), findViolation(Game, &demo_invs, &w));
    // checkAll is a no-op when satisfied (and would be DCE'd in ReleaseFast)
    checkAll(Game, &demo_invs, &w);

    w.get(e, Health).?.hp = -1; // now violates
    const b = findViolation(Game, &demo_invs, &w).?;
    try testing.expectEqualStrings(demo_invs[0].name, b.name);
    try testing.expectEqual(e.index, b.entity.index);
}

test "checkAll is hash-invariant: it does not touch the World (digest unchanged across a check)" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Health, .{ .hp = 7 });
    const before = try w.digest(gpa);
    checkAll(Game, &demo_invs, &w); // a satisfying world: no panic, no mutation
    const after = try w.digest(gpa);
    try testing.expectEqual(before.hash, after.hash);
    try testing.expectEqual(before.crc, after.crc);
}
