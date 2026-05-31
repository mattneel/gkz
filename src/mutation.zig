//! Structural mutations — the command-buffer seam (SPEC §4, PLAN.md build-order step 10; seam S2).
//!
//! A `Mutation` is one order-defined structural change to the World. In Phase 1 the only producer is
//! `step`, which translates each canonicalized `Command` into a `Mutation` and applies it immediately.
//! The point of routing through this single `apply` vocabulary now is the §4 seam: a per-system command
//! buffer is later just a `[]Mutation` drained at a sync point in `(system_id, entity_id)` order — a
//! WHEN-not-WHAT change, with no rework to storage or `apply`.
//!
//! `commandToMutation` is total: a `noop` or any unknown `verb` maps to `null` (a deterministic no-op),
//! so adversarial/garbled input cannot panic or diverge (D2). Phase-1 verbs are structural only
//! (`spawn`/`despawn`); component-valued commands (`add`/`set` carrying a `kind_id` + payload) are a
//! Phase-2 extension of the encoding.

const std = @import("std");
const entity = @import("entity.zig");
const worldmod = @import("world.zig");
const input = @import("input.zig");
const Entity = entity.Entity;
const Command = input.Command;

/// Phase-1 command verbs. Non-exhaustive: any unrecognized `u16` is a no-op.
pub const Verb = enum(u16) {
    noop = 0,
    spawn = 1,
    despawn = 2,
    _,
};

/// An order-defined structural mutation.
pub fn Mutation(comptime Reg: type) type {
    _ = Reg; // Phase-1 mutations are registry-independent; the param keeps the API uniform for §4.
    return union(enum) {
        spawn,
        despawn: Entity,
    };
}

/// Apply one mutation to the World. Deterministic; despawn of a stale handle is a no-op.
pub fn apply(comptime Reg: type, w: *worldmod.World(Reg), gpa: std.mem.Allocator, m: Mutation(Reg)) std.mem.Allocator.Error!void {
    switch (m) {
        .spawn => _ = try w.spawn(gpa),
        .despawn => |e| try w.despawn(gpa, e),
    }
}

/// Translate a recorded command into a mutation, or `null` for noop/unknown verbs (total).
pub fn commandToMutation(comptime Reg: type, c: Command) ?Mutation(Reg) {
    return switch (@as(Verb, @enumFromInt(c.verb))) {
        .spawn => .spawn,
        .despawn => .{ .despawn = c.actor },
        else => null,
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("registry.zig").Registry;

const Tag = struct {
    v: u8,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Tag});
const W = worldmod.World(Game);

test "spawn mutation allocates a live entity" {
    const gpa = testing.allocator;
    var w = W.init(0);
    defer w.deinit(gpa);
    try apply(Game, &w, gpa, .spawn);
    try testing.expectEqual(@as(usize, 1), w.table.rowCount());
}

test "despawn mutation removes the entity" {
    const gpa = testing.allocator;
    var w = W.init(0);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    try apply(Game, &w, gpa, .{ .despawn = e });
    try testing.expect(!w.isLive(e));
    try testing.expectEqual(@as(usize, 0), w.table.rowCount());
}

test "commandToMutation maps verbs and rejects unknown/noop as null" {
    const e = Entity{ .index = 4, .generation = 0 };
    try testing.expect(commandToMutation(Game, .{ .actor = e, .verb = 1 }) != null); // spawn
    const d = commandToMutation(Game, .{ .actor = e, .verb = 2 }).?; // despawn
    try testing.expectEqual(e, d.despawn);
    try testing.expectEqual(@as(?Mutation(Game), null), commandToMutation(Game, .{ .actor = e, .verb = 0 })); // noop
    try testing.expectEqual(@as(?Mutation(Game), null), commandToMutation(Game, .{ .actor = e, .verb = 9999 })); // unknown
}
