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
const serialize = @import("serialize.zig");
const cmdbuf = @import("command_buffer.zig");
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

/// Apply one system-emitted `command_buffer.Command(R)` to the World (the end-of-tick drain path,
/// SPEC §4). Total: a `.noop`/unknown op, an unknown `kind_id`, or a stale entity is a deterministic
/// no-op (D2). `.add` and `.set` are equivalent in Phase 1 (both ensure the component is present with
/// the given value; a future `.set` may require prior presence).
///
/// NOTE (SPEC-text deviation, see step.zig): the drain order is `(system_id, seq)`, not the literal
/// "(system id, then entity id)" — entity_id is not a total order when one system emits two commands at
/// the same entity. The per-system monotonic `seq` is the tiebreaker.
///
/// The payload of a system-emitted add/set was just encoded by this same codec, so a decode failure is
/// a kernel bug, not hostile input — hence `catch unreachable` (a loud panic in Debug/ReleaseSafe)
/// rather than a silent no-op that would hide a divergence.
pub fn applyCommand(
    comptime R: type,
    w: *worldmod.World(R),
    gpa: std.mem.Allocator,
    c: cmdbuf.Command(R),
) std.mem.Allocator.Error!void {
    switch (c.op) {
        .noop => {},
        .spawn => _ = try w.spawn(gpa),
        .despawn => try w.despawn(gpa, c.entity),
        .add, .set => {
            inline for (R.Components) |C| {
                if (C.kind_id == c.kind_id) {
                    var rd = serialize.ByteReader{ .bytes = c.payload[0..c.payload_len] };
                    const v = serialize.readValue(C, &rd) catch unreachable; // kernel-encoded, cannot fail
                    w.add(c.entity, C, v);
                    return;
                }
            }
            // unknown kind_id: deterministic no-op
        },
        .remove => {
            inline for (R.Components) |C| {
                if (C.kind_id == c.kind_id) {
                    w.remove(c.entity, C);
                    return;
                }
            }
        },
        _ => {}, // unknown op: deterministic no-op
    }
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

const Cmd = cmdbuf.Command(Game);

test "applyCommand drives spawn/add/remove/despawn" {
    const gpa = testing.allocator;
    var w = W.init(0);
    defer w.deinit(gpa);

    var buf = cmdbuf.CommandBuffer(Game).init(gpa, 0);
    defer buf.deinit();
    try buf.spawn(); // entity (0,0)
    const e = Entity{ .index = 0, .generation = 0 };
    try buf.add(e, Tag, .{ .v = 42 });
    for (buf.list.items) |c| try applyCommand(Game, &w, gpa, c);

    try testing.expectEqual(@as(usize, 1), w.table.rowCount());
    try testing.expectEqual(@as(u8, 42), w.get(e, Tag).?.v);

    // now remove + despawn via fresh commands
    var buf2 = cmdbuf.CommandBuffer(Game).init(gpa, 1);
    defer buf2.deinit();
    try buf2.remove(e, Tag);
    try buf2.despawn(e);
    for (buf2.list.items) |c| try applyCommand(Game, &w, gpa, c);
    try testing.expect(!w.isLive(e));
    try testing.expectEqual(@as(usize, 0), w.table.rowCount());
}

test "applyCommand is a total no-op on unknown kind_id, unknown op, and stale entity (D2)" {
    const gpa = testing.allocator;
    var w = W.init(0);
    defer w.deinit(gpa);
    _ = try w.spawn(gpa); // (0,0)
    const before = (try w.digest(gpa)).hash;

    try applyCommand(Game, &w, gpa, Cmd{ .system_id = 0, .seq = 0, .op = .add, .entity = .{ .index = 0, .generation = 0 }, .kind_id = 9999 });
    try applyCommand(Game, &w, gpa, Cmd{ .system_id = 0, .seq = 0, .op = @enumFromInt(200), .entity = .{ .index = 0, .generation = 0 } });
    try applyCommand(Game, &w, gpa, Cmd{ .system_id = 0, .seq = 0, .op = .despawn, .entity = .{ .index = 7, .generation = 0 } }); // stale

    try testing.expectEqual(before, (try w.digest(gpa)).hash); // nothing changed
}

test "add-then-remove via commands hashes identically to never-added (canonical-zero through the drain)" {
    const gpa = testing.allocator;
    // World A: spawn, add Tag, remove Tag
    var a = W.init(0);
    defer a.deinit(gpa);
    var ba = cmdbuf.CommandBuffer(Game).init(gpa, 0);
    defer ba.deinit();
    try ba.spawn();
    try ba.add(.{ .index = 0, .generation = 0 }, Tag, .{ .v = 200 });
    try ba.remove(.{ .index = 0, .generation = 0 }, Tag);
    for (ba.list.items) |c| try applyCommand(Game, &a, gpa, c);

    // World B: spawn only
    var b = W.init(0);
    defer b.deinit(gpa);
    var bb = cmdbuf.CommandBuffer(Game).init(gpa, 0);
    defer bb.deinit();
    try bb.spawn();
    for (bb.list.items) |c| try applyCommand(Game, &b, gpa, c);

    try testing.expectEqual((try b.digest(gpa)).hash, (try a.digest(gpa)).hash);
}
