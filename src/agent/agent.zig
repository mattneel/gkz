//! Agent(R) — the §10 harness contract named over the existing Generator/Run seams (PLAN.md Phase 7).
//!
//! An agent is a policy `observe(State) -> Input` plugged into the SAME Input channel as a human. The
//! CONTRACT REFINEMENT: a learned/NN/LLM agent's inference is bit-irreproducible (INT8 tensor-core / GPU
//! reduction order), so an agent is an EXTERNAL NONDETERMINISTIC SOURCE — reproducibility comes from
//! CAPTURING what it emits at the Input boundary (`buildRun` materializes `gen.next` into `Run.inputs`),
//! NEVER from reproducing the agent. On replay/VOPR the agent is NEVER re-invoked.
//!
//! `Agent(R)` is a THIN newtype over `Generator(R)` carrying a `DeterminismClass` tag — it inherits every
//! Phase-4/6 guarantee verbatim (capture = `buildRun`, replay = `scriptedGen(Run.inputs)`, mass-eval =
//! `aggregate`/`sweep`). Never-re-invoke-on-replay is STRUCTURAL: `asAgent`/`replayGen` are the only
//! replay constructors, both build a `.replay` Agent over `scriptedGen` (whose `next` discards `root` and
//! `view` — generator.zig — so a replay agent is INCAPABLE of consulting the world or the seed; it can
//! only re-emit the captured bytes), and NO constructor here couples a `Run` to a live policy/source ctx.

const std = @import("std");
const generator = @import("../vopr/generator.zig");
const Generator = generator.Generator;
const ScriptedSpec = generator.ScriptedSpec;
const runmod = @import("../vopr/run.zig");

/// The provenance/reproducibility class of an agent, fixed by which constructor built it.
///   * deterministic_blind     — a fixed scripted stream (ignores the World; pure in tick).
///   * deterministic_observing — a rule/search policy pure in (seed, tick, observed World): re-derivable.
///   * external                — an NN/LLM/out-of-process source: NOT reproducible; must be captured.
///   * replay                  — re-emits a captured `Run.inputs`; the source is structurally gone.
pub const DeterminismClass = enum { deterministic_blind, deterministic_observing, external, replay };

/// The one bit the eval layer needs: can a sweep over this agent be re-derived from the seed range alone
/// (true), or must each run be captured to be revisited (false, the `.external` regime)?
pub fn isReproducible(c: DeterminismClass) bool {
    return c != .external;
}

/// A policy plugged into the Input channel: a `Generator(R)` + its determinism class + a label.
pub fn Agent(comptime R: type) type {
    return struct {
        name: []const u8,
        class: DeterminismClass,
        gen: Generator(R),
    };
}

/// Build a `Generator` that re-emits a captured run's inputs — the ONLY replay primitive. BOTH `run` and
/// `spec` are caller-owned and must outlive the generator's use: the generator re-emits `run.inputs` (it
/// does not copy them) via `spec` (an Agent returned by value cannot hold a self-referential spec
/// pointer). The generator is `scriptedGen`, which discards `root` and `view`, so it can never consult
/// the world or the seed — the captured agent is structurally never re-invoked.
pub fn replayGen(comptime R: type, run: *const runmod.Run(R), spec: *ScriptedSpec) Generator(R) {
    spec.* = .{ .inputs = run.inputs };
    return generator.scriptedGen(R, spec);
}

/// Wrap a captured run as a `.replay`-class Agent. BOTH `run` and `spec` are caller-owned and must
/// outlive the Agent (the replay generator re-emits `run.inputs` through `spec`, copying neither). There
/// is deliberately NO overload taking a live policy/source — replay can only re-emit captured bytes.
pub fn asAgent(comptime R: type, run: *const runmod.Run(R), spec: *ScriptedSpec) Agent(R) {
    return .{ .name = "replay", .class = .replay, .gen = replayGen(R, run, spec) };
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
const rng = @import("../rng.zig");
const input = @import("../input.zig");

const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Health});
fn drain(ctx: *simctx.SimCtx(Game), qq: *q2.Query(Game, .{Write(Health)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (qq.next()) |row| row.write(Health).hp -= 1;
}
const game_systems = [_]Sys(Game){system(Game, "drain", drain)};

fn seedHp(gpa: std.mem.Allocator) !worldmod.World(Game) {
    var w = worldmod.World(Game).init(0);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Health, .{ .hp = 5 });
    return w;
}

test "isReproducible: only .external is non-reproducible" {
    try testing.expect(isReproducible(.deterministic_blind));
    try testing.expect(isReproducible(.deterministic_observing));
    try testing.expect(isReproducible(.replay));
    try testing.expect(!isReproducible(.external));
}

test "asAgent yields a .replay Agent whose next re-emits run.inputs, ignoring root and view" {
    const gpa = testing.allocator;
    const w0 = blk: {
        var w = try seedHp(gpa);
        errdefer w.deinit(gpa);
        break :blk w;
    };
    var run = try runmod.buildRun(Game, gpa, &game_systems, w0, 0, generator.idleGen(Game), 3);
    defer run.deinit(gpa);

    var spec: ScriptedSpec = undefined;
    const a = asAgent(Game, &run, &spec);
    try testing.expectEqual(DeterminismClass.replay, a.class);
    // the replay gen re-emits the captured inputs regardless of root/view (here run.inputs are empties)
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const emitted = (try a.gen.next(arena.allocator(), 1, .{ .seed = 999 }, null)).?;
    try testing.expectEqual(run.inputs[0].commands.len, emitted.commands.len);
}

test "replayGen fed back through buildRun reproduces the source run's hashes bit-for-bit (no re-invoke)" {
    const gpa = testing.allocator;
    const w0 = blk: {
        var w = try seedHp(gpa);
        errdefer w.deinit(gpa);
        break :blk w;
    };
    var run = try runmod.buildRun(Game, gpa, &game_systems, w0, 0, generator.idleGen(Game), 4);
    defer run.deinit(gpa);

    // replay: a fresh base + the captured inputs, never consulting the original source
    const w0b = blk: {
        var w = try seedHp(gpa);
        errdefer w.deinit(gpa);
        break :blk w;
    };
    var spec: ScriptedSpec = undefined;
    const rgen = replayGen(Game, &run, &spec);
    var run2 = try runmod.buildRun(Game, gpa, &game_systems, w0b, 0, rgen, 4);
    defer run2.deinit(gpa);

    try testing.expectEqualSlices(u64, run.hashes, run2.hashes);
}
