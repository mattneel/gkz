//! Seeded input-stream generators (SPEC §9, PLAN.md Phase 4). Build-order step 2.
//!
//! A `Generator(R)` is a closure `next(ctx, gpa, tick, root, view) ?Input` that is **pure** in
//! (seed, tick[, observed World]) — every random choice keys through the kernel RNG `rng.draw`, never
//! an ambient cursor — so the generated stream is a deterministic function of the seed (and, if it
//! reads `view`, of the deterministic World). The stream is materialized once into the `Run`, so a
//! failing run reduces to `(seed, inputs)` with no generator replay needed.
//!
//! `view: ?*const World(R)` is null in the Phase-4 default but present so §10's `observe(State)->Input`
//! agent is just a Generator with `view` non-null — zero contract change.

const std = @import("std");
const worldmod = @import("../world.zig");
const input = @import("../input.zig");
const rng = @import("../rng.zig");
const entity = @import("../entity.zig");
const Entity = entity.Entity;
const Allocator = std.mem.Allocator;

/// Dedicated RNG streams so generator draws never collide with a system's keyed draws.
pub const STREAM_COUNT: u32 = 0x6E00_0001;
pub const STREAM_VERB: u32 = 0x6E00_0002;
pub const STREAM_ACTOR: u32 = 0x6E00_0003;

pub fn Generator(comptime R: type) type {
    return struct {
        const Self = @This();
        ctx: *anyopaque,
        next_fn: *const fn (ctx: *anyopaque, gpa: Allocator, tick: u64, root: rng.RngRoot, view: ?*const worldmod.World(R)) Allocator.Error!?input.Input,

        /// Produce the input for `tick` (allocating its commands via `gpa`), or null to stop early.
        pub fn next(self: Self, gpa: Allocator, tick: u64, root: rng.RngRoot, view: ?*const worldmod.World(R)) Allocator.Error!?input.Input {
            return self.next_fn(self.ctx, gpa, tick, root, view);
        }
    };
}

/// Replay a fixed, state-blind input list (one `Input` per tick; null past the end).
pub const ScriptedSpec = struct { inputs: []const input.Input };

pub fn scriptedGen(comptime R: type, spec: *const ScriptedSpec) Generator(R) {
    const Impl = struct {
        fn next(ctx: *anyopaque, gpa: Allocator, tick: u64, root: rng.RngRoot, view: ?*const worldmod.World(R)) Allocator.Error!?input.Input {
            _ = root;
            _ = view;
            const s: *const ScriptedSpec = @ptrCast(@alignCast(ctx));
            // tick is 1-based (tick N is produced before the Nth step); index by tick-1.
            const idx = tick - 1;
            if (idx >= s.inputs.len) return null;
            const src = s.inputs[idx];
            const cmds = try gpa.dupe(input.Command, src.commands);
            return input.Input{ .tick = tick, .commands = cmds };
        }
    };
    return .{ .ctx = @constCast(spec), .next_fn = Impl.next };
}

var idle_ctx: u8 = 0;

/// A generator that issues an empty-command `Input` every tick (never stops) — "no input; let the
/// systems run". Bound the trajectory with `buildRun`'s `max_ticks`.
pub fn idleGen(comptime R: type) Generator(R) {
    const Impl = struct {
        fn next(ctx: *anyopaque, gpa: Allocator, tick: u64, root: rng.RngRoot, view: ?*const worldmod.World(R)) Allocator.Error!?input.Input {
            _ = ctx;
            _ = gpa;
            _ = root;
            _ = view;
            return input.Input{ .tick = tick, .commands = &.{} };
        }
    };
    return .{ .ctx = &idle_ctx, .next_fn = Impl.next };
}

/// Draw a random command stream: each tick, [0, max] commands of spawn/despawn (despawn targets a slot
/// in range when a `view` is available). Spawn-biased so entities accumulate. Pure in (seed, tick).
pub const RandomSpec = struct {
    max_commands_per_tick: u32 = 4,
    despawn_in_n: u32 = 4, // ~1-in-N commands is a despawn; the rest are spawns
};

pub fn randomGen(comptime R: type, spec: *const RandomSpec) Generator(R) {
    const Impl = struct {
        fn next(ctx: *anyopaque, gpa: Allocator, tick: u64, root: rng.RngRoot, view: ?*const worldmod.World(R)) Allocator.Error!?input.Input {
            const s: *const RandomSpec = @ptrCast(@alignCast(ctx));
            const n: usize = @intCast(rng.draw(root, tick, 0, STREAM_COUNT) % (@as(u64, s.max_commands_per_tick) + 1));
            const cmds = try gpa.alloc(input.Command, n);
            for (cmds, 0..) |*c, i| {
                const idx: u32 = @intCast(i);
                const is_despawn = (rng.draw(root, tick, idx, STREAM_VERB) % s.despawn_in_n) == 0;
                var actor: Entity = .{ .index = 0, .generation = 0 };
                if (is_despawn) {
                    if (view) |w| {
                        const slots = w.entities.generation.items.len;
                        if (slots > 0) actor.index = @intCast(rng.draw(root, tick, idx, STREAM_ACTOR) % slots);
                    }
                }
                c.* = .{ .actor = actor, .verb = if (is_despawn) 2 else 1 }; // 1 = spawn, 2 = despawn
            }
            return input.Input{ .tick = tick, .commands = cmds };
        }
    };
    return .{ .ctx = @constCast(spec), .next_fn = Impl.next };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;

const Tag = struct {
    v: u8,
    pub const kind_id: u16 = 1;
};
const Reg = Registry(.{Tag});

test "randomGen is a pure function of the seed (two materializations are byte-identical)" {
    const gpa = testing.allocator;
    var spec = RandomSpec{};
    const gen = randomGen(Reg, &spec);
    const root: rng.RngRoot = .{ .seed = 0xABCD };

    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    var b = std.heap.ArenaAllocator.init(gpa);
    defer b.deinit();

    var t: u64 = 1;
    while (t <= 8) : (t += 1) {
        const ia = (try gen.next(a.allocator(), t, root, null)).?;
        const ib = (try gen.next(b.allocator(), t, root, null)).?;
        try testing.expectEqual(ia.commands.len, ib.commands.len);
        for (ia.commands, ib.commands) |ca, cb| {
            try testing.expectEqual(ca.verb, cb.verb);
            try testing.expectEqual(ca.actor.index, cb.actor.index);
        }
    }
}

test "scriptedGen replays the fixed list and stops past the end" {
    const gpa = testing.allocator;
    const c0 = [_]input.Command{.{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 }};
    const script = [_]input.Input{ .{ .tick = 1, .commands = &c0 }, .{ .tick = 2, .commands = &.{} } };
    var spec = ScriptedSpec{ .inputs = &script };
    const gen = scriptedGen(Reg, &spec);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const in1 = (try gen.next(a, 1, .{ .seed = 0 }, null)).?;
    try testing.expectEqual(@as(usize, 1), in1.commands.len);
    try testing.expectEqual(@as(u16, 1), in1.commands[0].verb);
    const in2 = (try gen.next(a, 2, .{ .seed = 0 }, null)).?;
    try testing.expectEqual(@as(usize, 0), in2.commands.len);
    try testing.expectEqual(@as(?input.Input, null), try gen.next(a, 3, .{ .seed = 0 }, null)); // past end
}
