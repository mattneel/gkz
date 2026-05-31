//! Reference DETERMINISTIC policies (PLAN.md Phase 7, §10): `scriptedAgent` (blind) and `greedyAgent`
//! (a rule-based observer). Both are pure in (seed, tick, observed World) — `greedyAgent` keys every
//! choice through `rng.draw` on dedicated `STREAM_AGENT_*` ids (never an ambient cursor, never colliding
//! with a system's draws) — so a sweep over either is bit-reproducible from the seed range alone. They
//! prove the two `deterministic_*` classes; an NN/LLM/search policy is just another `Policy` (greedy) or
//! `ExternalAgent` (external) plugged into the same seam.

const std = @import("std");
const Allocator = std.mem.Allocator;
const observe = @import("observe.zig");
const ObsView = observe.ObsView;
const agentmod = @import("agent.zig");
const Agent = agentmod.Agent;
const policymod = @import("policy.zig");
const generator = @import("../vopr/generator.zig");
const ScriptedSpec = generator.ScriptedSpec;
const rng = @import("../rng.zig");
const input = @import("../input.zig");
const Command = input.Command;
const Entity = @import("../entity.zig").Entity;

/// Dedicated agent RNG streams (disjoint from generator/system streams) so a policy's keyed draws never
/// collide with a system's draws.
pub const STREAM_AGENT_CHOICE: u32 = 0x6A00_0001;

/// A fixed, World-blind input stream (a recorded/authored script). Class `deterministic_blind`. `spec` is
/// caller-owned storage that must outlive the Agent.
pub fn scriptedAgent(comptime R: type, spec: *const ScriptedSpec) Agent(R) {
    return .{ .name = "scripted", .class = .deterministic_blind, .gen = generator.scriptedGen(R, spec) };
}

/// Tuning for `greedyAgent`: which verbs spawn/despawn and the live-entity cap it maintains.
pub const GreedySpec = struct { spawn_verb: u16 = 1, despawn_verb: u16 = 2, max_entities: u32 = 4 };

/// A rule-based OBSERVING policy: keep the live-entity count near `max_entities`. While under the cap it
/// spawns (spawn-biased via a keyed `rng.draw` so the choice is reproducible); at/over the cap it despawns
/// the lowest-index live entity. Pure in (seed, tick, view) — class `deterministic_observing`.
pub fn greedyAgent(comptime R: type, comptime spec: GreedySpec) Agent(R) {
    const Pol = struct {
        fn observe(ov: ObsView(R), gpa: Allocator, tick: u64, root: rng.RngRoot) Allocator.Error!?input.Input {
            const w = ov.world();
            const n = w.table.rowCount();
            const r = rng.draw(root, tick, 0, STREAM_AGENT_CHOICE);
            var cmd: Command = undefined;
            if (n == 0 or (n < spec.max_entities and r % 4 != 0)) {
                cmd = .{ .actor = .{ .index = 0, .generation = 0 }, .verb = spec.spawn_verb }; // spawn (actor ignored)
            } else {
                // despawn the canonical-lowest-index live entity (every table row is a live owner)
                const owners = w.table.owners();
                if (owners.len == 0) return input.Input{ .tick = tick, .commands = &.{} };
                var lo = owners[0];
                for (owners[1..]) |e| {
                    if (e.index < lo.index) lo = e;
                }
                cmd = .{ .actor = lo, .verb = spec.despawn_verb };
            }
            const cmds = try gpa.alloc(Command, 1);
            cmds[0] = cmd;
            return input.Input{ .tick = tick, .commands = cmds };
        }
    };
    return policymod.policyGen(R, .deterministic_observing, "greedy", Pol.observe);
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

const Tag = struct {
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Tag});
fn noop(ctx: *simctx.SimCtx(Game), qq: *q2.Query(Game, .{Write(Tag)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = qq;
}
const game_systems = [_]Sys(Game){system(Game, "noop", noop)};

test "scriptedAgent re-emits its script and is deterministic_blind" {
    const gpa = testing.allocator;
    const spawn = [_]Command{.{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 }};
    const script = [_]input.Input{ .{ .tick = 0, .commands = &spawn }, .{ .tick = 0, .commands = &.{} } };
    var spec = ScriptedSpec{ .inputs = &script };
    const a = scriptedAgent(Game, &spec);
    try testing.expectEqual(agentmod.DeterminismClass.deterministic_blind, a.class);
    var run = try runmod.buildRun(Game, gpa, &game_systems, worldmod.World(Game).init(0), 0, a.gen, 2);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), run.final.table.rowCount()); // the one scripted spawn
}

test "greedyAgent is pure in (seed,tick,view): two buildRuns from one seed are bit-identical, and it caps live entities" {
    const gpa = testing.allocator;
    const a = greedyAgent(Game, .{ .spawn_verb = 1, .despawn_verb = 2, .max_entities = 3 });
    try testing.expectEqual(agentmod.DeterminismClass.deterministic_observing, a.class);
    var ra = try runmod.buildRun(Game, gpa, &game_systems, worldmod.World(Game).init(42), 42, a.gen, 12);
    defer ra.deinit(gpa);
    var rb = try runmod.buildRun(Game, gpa, &game_systems, worldmod.World(Game).init(42), 42, a.gen, 12);
    defer rb.deinit(gpa);
    try testing.expectEqualSlices(u64, ra.hashes, rb.hashes); // re-derivable from the seed
    try testing.expect(ra.final.table.rowCount() <= 3); // the observing policy holds the cap
}
