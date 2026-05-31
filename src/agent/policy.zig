//! Policy — the `observe(State) -> Input` adapter (PLAN.md Phase 7, §10).
//!
//! A `Policy(R)` reads a read-only `ObsView(R)` and emits an `?Input` — the player half of the harness.
//! Deterministic policies RECEIVE `root: RngRoot` and key ALL randomness through `rng.draw` (never an
//! ambient cursor), so they are pure in (seed, tick, observed World) and a sweep over them is re-derivable
//! from the seed range alone (the value-level discipline that distinguishes them from `.external`).
//! `policyGen` lifts a (comptime) policy into an `Agent(R)`: it constructs an `ObsView` over the
//! buildRun-supplied `*const World` view each tick and forwards `root` — so the player-not-world boundary
//! is in the signature (the policy can name only a `*const` World, and its sole egress is the `?Input`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const observe = @import("observe.zig");
const ObsView = observe.ObsView;
const agentmod = @import("agent.zig");
const Agent = agentmod.Agent;
const DeterminismClass = agentmod.DeterminismClass;
const generator = @import("../vopr/generator.zig");
const Generator = generator.Generator;
const rng = @import("../rng.zig");
const input = @import("../input.zig");

/// A read-only observe-then-emit policy. Pure deterministic policies must be a pure function of
/// (view, tick, root) and key randomness only through `rng.draw(root, ...)`.
pub fn Policy(comptime R: type) type {
    return *const fn (ObsView(R), Allocator, u64, rng.RngRoot) Allocator.Error!?input.Input;
}

var unused_ctx: u8 = 0; // a real (ignored) Generator ctx — the policy is baked comptime into the thunk

/// Lift a comptime `policy` into an `Agent(R)` of the given `class`. The lowered `Generator` builds an
/// `ObsView` over the `*const World` view buildRun supplies each tick and calls the policy; if no view is
/// available (only off the buildRun path) it emits nothing.
pub fn policyGen(comptime R: type, comptime class: DeterminismClass, comptime name: []const u8, comptime policy: Policy(R)) Agent(R) {
    const Impl = struct {
        fn next(ctx: *anyopaque, gpa: Allocator, tick: u64, root: rng.RngRoot, view: ?*const @import("../world.zig").World(R)) Allocator.Error!?input.Input {
            _ = ctx;
            const w = view orelse return null;
            return policy(ObsView(R).init(w), gpa, tick, root);
        }
    };
    return .{ .name = name, .class = class, .gen = .{ .ctx = &unused_ctx, .next_fn = Impl.next } };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const worldmod = @import("../world.zig");
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const system = schedule.system;
const q2 = @import("../query.zig");
const simctx = @import("../simctx.zig");
const Write = q2.Write;
const runmod = @import("../vopr/run.zig");
const Command = input.Command;

const Tag = struct {
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Tag});
// a system that does nothing (the policy drives the world via spawn/despawn inputs)
fn noop(ctx: *simctx.SimCtx(Game), qq: *q2.Query(Game, .{Write(Tag)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = qq;
}
const game_systems = [_]Sys(Game){system(Game, "noop", noop)};

// a policy: spawn (verb 1) while the world is empty, else emit nothing — reads ObsView.world()
fn spawnWhenEmpty(ov: ObsView(Game), gpa: Allocator, tick: u64, root: rng.RngRoot) Allocator.Error!?input.Input {
    _ = root;
    if (ov.world().table.rowCount() == 0) {
        const cmds = try gpa.alloc(Command, 1);
        cmds[0] = .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 };
        return input.Input{ .tick = tick, .commands = cmds };
    }
    return input.Input{ .tick = tick, .commands = &.{} };
}

test "a policy reading ObsView.world() influences the World only via the emitted Input" {
    const gpa = testing.allocator;
    const agent = policyGen(Game, .deterministic_observing, "spawnWhenEmpty", spawnWhenEmpty);
    const w0 = worldmod.World(Game).init(0); // empty
    var run = try runmod.buildRun(Game, gpa, &game_systems, w0, 0, agent.gen, 3);
    defer run.deinit(gpa);
    // tick 1 sees empty world -> spawns; afterwards rowCount==1 -> no more spawns. Final has exactly 1 entity.
    try testing.expectEqual(@as(usize, 1), run.final.table.rowCount());
    try testing.expectEqual(@as(usize, 1), run.inputs[0].commands.len); // spawn at tick 1
    try testing.expectEqual(@as(usize, 0), run.inputs[1].commands.len); // nothing after
}

// a policy that ignores the world and draws via rng.draw — must be pure in (seed, tick)
fn rngSpawner(ov: ObsView(Game), gpa: Allocator, tick: u64, root: rng.RngRoot) Allocator.Error!?input.Input {
    _ = ov;
    if (rng.draw(root, tick, 0, 0xABCD) % 2 == 0) {
        const cmds = try gpa.alloc(Command, 1);
        cmds[0] = .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 };
        return input.Input{ .tick = tick, .commands = cmds };
    }
    return input.Input{ .tick = tick, .commands = &.{} };
}

test "policyGen with no view (off the buildRun path) emits nothing rather than crashing" {
    const gpa = testing.allocator;
    const agent = policyGen(Game, .deterministic_observing, "spawnWhenEmpty", spawnWhenEmpty);
    // view == null is the only off-buildRun fallback; the lowered generator must return null, not deref.
    try testing.expectEqual(@as(?input.Input, null), try agent.gen.next(gpa, 1, .{ .seed = 0 }, null));
}

test "an rng-keyed policy is byte-identical across two materializations from one seed (pure)" {
    const gpa = testing.allocator;
    const agent = policyGen(Game, .deterministic_observing, "rngSpawner", rngSpawner);
    var ra = try runmod.buildRun(Game, gpa, &game_systems, worldmod.World(Game).init(7), 7, agent.gen, 6);
    defer ra.deinit(gpa);
    var rb = try runmod.buildRun(Game, gpa, &game_systems, worldmod.World(Game).init(7), 7, agent.gen, 6);
    defer rb.deinit(gpa);
    try testing.expectEqualSlices(u64, ra.hashes, rb.hashes);
}
