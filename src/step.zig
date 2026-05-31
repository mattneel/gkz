//! The step function — the kernel's spine (SPEC §1/§4, PLAN.md build-order step 11; resolves Q8).
//!
//! `step` is a pure function `(World, Input) -> World`: it clones the previous World (value semantics —
//! the input is never mutated, D1), advances the tick, applies the tick's commands in canonical order
//! through the `Mutation`/`apply` seam (S2), then runs a caller-supplied ordered list of systems. In
//! Phase 1 the systems list is a fixed 1-element slice; in §4 the scheduler supplies a DAG-ordered
//! slice — a call-site change, not a rewrite of `step`. Everything `step` touches is integer/fixed-point
//! and total, so the result is bit-identical across build modes and architectures (D2/D7).

const std = @import("std");
const worldmod = @import("world.zig");
const input = @import("input.zig");
const mutation = @import("mutation.zig");
const Input = input.Input;

/// A system is a pure transform over the World. (Phase 1: receives the World + an allocator for
/// transient working memory such as the canonical iteration order. The §4 `SimCtx` — event emitter,
/// declared access set — is layered here later without changing the World/Input contract.)
pub fn System(comptime Reg: type) type {
    return *const fn (w: *worldmod.World(Reg), gpa: std.mem.Allocator) std.mem.Allocator.Error!void;
}

/// Advance the simulation one tick. Returns a new World; `prev` is untouched and remains owned by the
/// caller. The returned World must be `deinit`'d by the caller.
pub fn step(
    comptime Reg: type,
    gpa: std.mem.Allocator,
    prev: worldmod.World(Reg),
    in: Input,
    comptime systems: []const System(Reg),
) std.mem.Allocator.Error!worldmod.World(Reg) {
    var w = try prev.clone(gpa);
    errdefer w.deinit(gpa);

    w.tick +%= 1; // wrapping (D2): never a build-mode-divergent overflow

    const cmds = try input.canonicalize(gpa, in.commands);
    defer gpa.free(cmds);
    for (cmds) |c| {
        if (mutation.commandToMutation(Reg, c)) |m| try mutation.apply(Reg, &w, gpa, m);
    }

    inline for (systems) |sys| try sys(&w, gpa);
    return w;
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const rng = @import("rng.zig");
const Registry = @import("registry.zig").Registry;

const Position = struct {
    x: fpz.Fixed,
    y: fpz.Fixed,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Position});
const W = worldmod.World(Game);

/// Phase-1 demo system: ensure every live entity has a Position, then nudge each by a keyed-RNG delta
/// in [-1,1] using the total `addSat` (no overflow panic → no build-mode divergence). Exercises keyed
/// RNG + fixed-point math + component add/get + canonical iteration in one loop.
fn demoSystem(w: *W, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    const order = try w.table.canonicalOrder(gpa);
    defer gpa.free(order);
    const owners = w.table.owners();
    for (order) |row| {
        const e = owners[row];
        if (!w.has(e, Position)) w.add(e, Position, .{ .x = fpz.Fixed.ZERO, .y = fpz.Fixed.ZERO });
        const p = w.get(e, Position).?;
        const dx = rng.drawFixed(w.rng_root, w.tick, e.index, 0, fpz.Fixed.NEG_ONE, fpz.Fixed.ONE);
        const dy = rng.drawFixed(w.rng_root, w.tick, e.index, 1, fpz.Fixed.NEG_ONE, fpz.Fixed.ONE);
        p.x = p.x.addSat(dx);
        p.y = p.y.addSat(dy);
    }
}

const demo_systems = [_]System(Game){&demoSystem};

const no_input = Input{ .tick = 0, .commands = &.{} };

test "step is pure: same (world, input) yields identical successors, input untouched" {
    const gpa = testing.allocator;
    var w0 = W.init(0xC0FFEE);
    defer w0.deinit(gpa);
    _ = try w0.spawn(gpa);
    _ = try w0.spawn(gpa);
    const h_before = (try w0.digest(gpa)).hash;

    var a = try step(Game, gpa, w0, no_input, &demo_systems);
    defer a.deinit(gpa);
    var b = try step(Game, gpa, w0, no_input, &demo_systems);
    defer b.deinit(gpa);

    try testing.expectEqual((try a.digest(gpa)).hash, (try b.digest(gpa)).hash); // pure
    try testing.expectEqual(h_before, (try w0.digest(gpa)).hash); // prev untouched
    try testing.expectEqual(@as(u64, 1), a.tick);
    try testing.expect((try a.digest(gpa)).hash != h_before); // state advanced
}

test "spawn/despawn commands drive structural change through step" {
    const gpa = testing.allocator;
    var w0 = W.init(1);
    defer w0.deinit(gpa);

    const spawn_cmd = [_]input.Command{
        .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 },
        .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 },
    };
    var w1 = try step(Game, gpa, w0, .{ .tick = 1, .commands = &spawn_cmd }, &demo_systems);
    defer w1.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), w1.table.rowCount());
}

test "multi-tick run is deterministic across independent executions" {
    const gpa = testing.allocator;

    const RunResult = struct {
        fn run(g: std.mem.Allocator) !u64 {
            var w = W.init(0xABCDEF);
            // seed three entities
            const c = [_]input.Command{
                .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 },
                .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 },
                .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 },
            };
            var next = try step(Game, g, w, .{ .tick = 1, .commands = &c }, &demo_systems);
            w.deinit(g);
            w = next;
            var t: u64 = 0;
            while (t < 20) : (t += 1) {
                next = try step(Game, g, w, no_input, &demo_systems);
                w.deinit(g);
                w = next;
            }
            const h = (try w.digest(g)).hash;
            w.deinit(g);
            return h;
        }
    };

    const h1 = try RunResult.run(gpa);
    const h2 = try RunResult.run(gpa);
    try testing.expectEqual(h1, h2);
}

test "commands referencing never-existed / stale entities are deterministic no-ops (D2, tests#8)" {
    const gpa = testing.allocator;
    var w0 = W.init(0x1234);
    defer w0.deinit(gpa);
    _ = try w0.spawn(gpa); // entity (0,0)

    var base = try step(Game, gpa, w0, .{ .tick = 1, .commands = &.{} }, &demo_systems);
    defer base.deinit(gpa);

    const junk = [_]input.Command{
        .{ .actor = .{ .index = 9999, .generation = 0 }, .verb = 2 }, // out-of-range despawn
        .{ .actor = .{ .index = 0, .generation = 7 }, .verb = 2 }, // stale-generation despawn
    };
    var with_junk = try step(Game, gpa, w0, .{ .tick = 1, .commands = &junk }, &demo_systems);
    defer with_junk.deinit(gpa);

    // junk commands change nothing and never panic in any build mode
    try testing.expectEqual((try base.digest(gpa)).hash, (try with_junk.digest(gpa)).hash);
}
