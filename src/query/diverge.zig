//! diverge/3, firstTickWhere (WHERE-DID-IT-BREAK), and reach (REACHABILITY) — the §7 shapes that need
//! the fork/replay machinery (PLAN.md Phase 5, build-order step 5).
//!
//!   * diverge/3 — closes the gap oracle.zig defers (oracle.zig: "per-component bisection of WHICH write
//!     diverged is deferred — needs the §7 typed-component diff"). Given two `Run`s sharing a base,
//!     `oracle.firstDivergentTick` bisects the first divergent tick over the cheap per-tick hash streams
//!     (O(T), not O(T²)), then both Worlds are reconstructed at that tick via the certified `Run.worldAt`
//!     and diffed by a sorted MERGE of their `component/3` relations — emitting every (tick, entity, kind)
//!     whose presence-bit or canonical bytes differ, in canonical order.
//!   * firstTickWhere — the bisection operator for WHERE-DID-IT-BREAK: it takes the EXACT predicate shape
//!     `oracle.invariant` consumes (`fn(*const World(R)) ?Entity`), so Phase-6 compiled invariants plug in
//!     unchanged (seam S8). It is an operator (returns a tick), not a stored relation.
//!   * reach — the generic deterministic fixpoint for REACHABILITY over an EXOGENOUS, game-supplied
//!     adjacency (intent is exogenous, §8): same shape as `event_log.causeChain` (BFS frontier +
//!     visited-set cycle guard + canonical final sort), generic over the node type. The adjacency and the
//!     node order are parameters the game/agent layer (Phase 7) supplies.

const std = @import("std");
const Allocator = std.mem.Allocator;

const term = @import("term.zig");
const Value = term.Value;
const Row = term.Row;
const resultmod = @import("result.zig");
const QueryResult = resultmod.QueryResult;
const Builder = resultmod.Builder;
const relations = @import("relations.zig");

const worldmod = @import("../world.zig");
const Entity = @import("../entity.zig").Entity;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const runmod = @import("../vopr/run.zig");
const oracle = @import("../vopr/oracle.zig");
const sortmod = @import("../sort.zig");

// --- diverge/3 ------------------------------------------------------------------------------------

/// First component-level divergence between two runs sharing a base: emits every (tick, entity, kind)
/// cell that differs at the first divergent tick (full mode), in canonical (entity.index, kind) order.
/// diverge/3 locates COMPONENT-CELL divergences. The result is EMPTY in three cases: (1) the runs never
/// diverge; (2) length-only divergence (one run outlived the other); (3) the first hash-divergent tick
/// differs ONLY in non-component World state — the entity-allocator generation array / free queue, the
/// tick counter, or rng_root — which has no (entity, kind) cell to point at. The hash-level
/// `firstDivergentTick` always detects EXISTENCE of a divergence; an empty diverge/3 with a non-null
/// `firstDivergentTick` means "diverged, but not in a live component cell" (a structural/allocator-level
/// diff is a deferred enhancement). Callers distinguishing case (1) from (3) should consult
/// `firstDivergentTick` directly.
pub fn diverge(comptime R: type, gpa: Allocator, a: *const runmod.Run(R), b: *const runmod.Run(R), comptime systems: []const Sys(R)) (error{OutOfMemory})!QueryResult {
    var bld = Builder.init(gpa, .diverge, relations.DIVERGE_SCHEMA);
    errdefer bld.deinit();

    const i = oracle.firstDivergentTick(a.hashes, b.hashes) orelse return bld.finalize();
    const min_len = @min(a.hashes.len, b.hashes.len);
    if (i >= min_len) return bld.finalize(); // length-only divergence: no shared tick with a cell diff
    const tick: u64 = @intCast(i + 1); // hashes[i] is the World at tick i+1 (oracle.zig)

    var wa = a.worldAt(gpa, systems, @intCast(tick)) catch |e| return mapErr(e);
    defer wa.deinit(gpa);
    var wb = b.worldAt(gpa, systems, @intCast(tick)) catch |e| return mapErr(e);
    defer wb.deinit(gpa);

    var ca = try relations.componentRel(R, gpa, &wa, .{});
    defer ca.deinit(gpa);
    var cb = try relations.componentRel(R, gpa, &wb, .{});
    defer cb.deinit(gpa);

    // merge-walk the two canonical (entity, kind, value) row streams
    var ia: usize = 0;
    var ib: usize = 0;
    while (ia < ca.rows.items.len or ib < cb.rows.items.len) {
        const ra: ?Row = if (ia < ca.rows.items.len) ca.rows.items[ia] else null;
        const rb: ?Row = if (ib < cb.rows.items.len) cb.rows.items[ib] else null;
        switch (keyCompare(ra, rb)) {
            .a_only => {
                try emit(&bld, tick, ra.?);
                ia += 1;
            },
            .b_only => {
                try emit(&bld, tick, rb.?);
                ib += 1;
            },
            .both => {
                // same (entity, kind); compare the canonical value bytes (across the two arenas)
                if (!std.mem.eql(u8, ca.bytesOf(ra.?.vals[2].bytes), cb.bytesOf(rb.?.vals[2].bytes))) {
                    try emit(&bld, tick, ra.?);
                }
                ia += 1;
                ib += 1;
            },
        }
    }
    return bld.finalize();
}

fn mapErr(e: anytype) error{OutOfMemory} {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable, // worldAt over a kernel-produced base/inputs cannot Corrupt
    };
}

fn emit(bld: *Builder, tick: u64, comp_row: Row) Allocator.Error!void {
    try bld.pushRow(.{ .vals = .{ .{ .tick = tick }, comp_row.vals[0], comp_row.vals[1], undefined, undefined, undefined, undefined, undefined } });
}

const KeyRel = enum { a_only, b_only, both };

/// Compare two component rows by their (entity.index, entity.generation, kind) key; a null row sorts
/// after any real row (so the present side wins).
fn keyCompare(ra: ?Row, rb: ?Row) KeyRel {
    if (ra == null) return .b_only;
    if (rb == null) return .a_only;
    const ea = ra.?.vals[0].entity;
    const eb = rb.?.vals[0].entity;
    switch (std.math.order(ea.index, eb.index)) {
        .lt => return .a_only,
        .gt => return .b_only,
        .eq => {},
    }
    switch (std.math.order(ea.generation, eb.generation)) {
        .lt => return .a_only,
        .gt => return .b_only,
        .eq => {},
    }
    switch (std.math.order(ra.?.vals[1].kind, rb.?.vals[1].kind)) {
        .lt => return .a_only,
        .gt => return .b_only,
        .eq => return .both,
    }
}

// --- firstTickWhere (WHERE-DID-IT-BREAK) ----------------------------------------------------------

pub const BreakPoint = struct { tick: u64, entity: Entity };

/// First tick (1..=inputs.len) at which `pred` flips (returns a non-null offending entity), or null. The
/// predicate is the exact `oracle.invariant` shape, so Phase-6 invariants/temporal properties plug in.
pub fn firstTickWhere(
    comptime R: type,
    gpa: Allocator,
    run: *const runmod.Run(R),
    comptime systems: []const Sys(R),
    comptime pred: fn (*const worldmod.World(R)) ?Entity,
) (error{OutOfMemory})!?BreakPoint {
    var t: usize = 1;
    while (t <= run.inputs.len) : (t += 1) {
        var w = run.worldAt(gpa, systems, t) catch |e| return mapErr(e);
        defer w.deinit(gpa);
        if (pred(&w)) |e| return BreakPoint{ .tick = @intCast(t), .entity = e };
    }
    return null;
}

// --- reach (REACHABILITY) -------------------------------------------------------------------------

/// Deterministic transitive reachability over an EXOGENOUS adjacency: BFS frontier + visited-set cycle
/// guard + canonical final sort (the `causeChain` pattern, generalized). `neighbors(ctx, node, out, gpa)`
/// appends `node`'s successors to `out`; `lessThan` is the node total order (used for dedup + the
/// canonical result order). Caller frees. Pure in (seeds, adjacency).
pub fn reach(
    comptime Node: type,
    gpa: Allocator,
    seeds: []const Node,
    ctx: anytype,
    comptime neighbors: fn (@TypeOf(ctx), Node, *std.ArrayList(Node), Allocator) Allocator.Error!void,
    comptime lessThan: fn (void, Node, Node) bool,
) Allocator.Error![]Node {
    var seen: std.ArrayList(Node) = .empty; // BFS frontier, append-only (deduped on insert)
    errdefer seen.deinit(gpa);
    var scratch: std.ArrayList(Node) = .empty;
    defer scratch.deinit(gpa);

    for (seeds) |s| if (!containsNode(Node, seen.items, s, lessThan)) try seen.append(gpa, s);
    var i: usize = 0;
    while (i < seen.items.len) : (i += 1) {
        scratch.clearRetainingCapacity();
        try neighbors(ctx, seen.items[i], &scratch, gpa);
        for (scratch.items) |n| {
            if (!containsNode(Node, seen.items, n, lessThan)) try seen.append(gpa, n);
        }
    }
    sortmod.sort(Node, seen.items, {}, lessThan);
    return seen.toOwnedSlice(gpa);
}

fn containsNode(comptime Node: type, haystack: []const Node, needle: Node, comptime lessThan: fn (void, Node, Node) bool) bool {
    for (haystack) |h| {
        if (!lessThan({}, h, needle) and !lessThan({}, needle, h)) return true; // eql derived from order
    }
    return false;
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const query = @import("../query.zig");
const simctx = @import("../simctx.zig");
const Write = query.Write;
const Query = query.Query;
const SimCtx = simctx.SimCtx;
const system = schedule.system;
const generator = @import("../vopr/generator.zig");
const input = @import("../input.zig");

const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Health});
fn drain(ctx: *SimCtx(Game), q: *Query(Game, .{Write(Health)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Health).hp -= 1;
}
const game_systems = [_]Sys(Game){system(Game, "drain", drain)};

fn seedTwo(gpa: Allocator) !worldmod.World(Game) {
    var w = worldmod.World(Game).init(0);
    errdefer w.deinit(gpa);
    const x = try w.spawn(gpa); // index 0
    const y = try w.spawn(gpa); // index 1
    w.add(x, Health, .{ .hp = 5 });
    w.add(y, Health, .{ .hp = 5 });
    return w;
}

test "diverge/3: a despawn-fork yields the exact (tick, entity, kind) cell present in only one run" {
    const gpa = testing.allocator;
    // RunA: 3 idle ticks. RunB: despawn entity index 0 at tick 2. They share the base.
    var wA0 = try seedTwo(gpa);
    var wB0 = try wA0.clone(gpa);
    errdefer wB0.deinit(gpa);

    const genA = generator.idleGen(Game);
    var runA = try runmod.buildRun(Game, gpa, &game_systems, wA0, 0, genA, 3);
    defer runA.deinit(gpa);

    const despawn0 = [_]input.Command{.{ .actor = .{ .index = 0, .generation = 0 }, .verb = 2 }};
    const scriptB = [_]input.Input{
        .{ .tick = 0, .commands = &.{} },
        .{ .tick = 0, .commands = &despawn0 }, // tick 2 despawns entity 0
        .{ .tick = 0, .commands = &.{} },
    };
    var specB = generator.ScriptedSpec{ .inputs = &scriptB };
    const genB = generator.scriptedGen(Game, &specB);
    var runB = try runmod.buildRun(Game, gpa, &game_systems, wB0, 0, genB, 3);
    defer runB.deinit(gpa);

    var r = try diverge(Game, gpa, &runA, &runB, &game_systems);
    defer r.deinit(gpa);
    // exactly one differing cell: entity 0's Health, present only in RunA, at tick 2
    try testing.expectEqual(@as(usize, 1), r.rows.items.len);
    try testing.expectEqual(@as(u64, 2), r.rows.items[0].vals[0].tick);
    try testing.expectEqual(@as(u32, 0), r.rows.items[0].vals[1].entity.index);
    try testing.expectEqual(@as(u16, 1), r.rows.items[0].vals[2].kind);
}

test "diverge/3: a non-component divergence (extra bare entity) is empty, but firstDivergentTick detects it" {
    const gpa = testing.allocator;
    var wA0 = worldmod.World(Game).init(0);
    {
        errdefer wA0.deinit(gpa);
        const e = try wA0.spawn(gpa);
        wA0.add(e, Health, .{ .hp = 5 });
    }
    var wB0 = try wA0.clone(gpa);
    errdefer wB0.deinit(gpa);

    var runA = try runmod.buildRun(Game, gpa, &game_systems, wA0, 0, generator.idleGen(Game), 2);
    defer runA.deinit(gpa);
    const spawnBare = [_]input.Command{.{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 }}; // spawn a bare entity
    const scriptB = [_]input.Input{ .{ .tick = 0, .commands = &spawnBare }, .{ .tick = 0, .commands = &.{} } };
    var specB = generator.ScriptedSpec{ .inputs = &scriptB };
    var runB = try runmod.buildRun(Game, gpa, &game_systems, wB0, 0, generator.scriptedGen(Game, &specB), 2);
    defer runB.deinit(gpa);

    // the runs DO diverge: RunB has an extra (component-less) entity -> different allocator state -> hash
    try testing.expect(oracle.firstDivergentTick(runA.hashes, runB.hashes) != null);
    // ...but it is not in any live COMPONENT cell, so diverge/3 is empty (documented case 3)
    var r = try diverge(Game, gpa, &runA, &runB, &game_systems);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r.rows.items.len);
}

test "diverge/3: identical runs produce an empty result" {
    const gpa = testing.allocator;
    var wA0 = try seedTwo(gpa);
    var wB0 = try wA0.clone(gpa);
    errdefer wB0.deinit(gpa);
    var runA = try runmod.buildRun(Game, gpa, &game_systems, wA0, 0, generator.idleGen(Game), 3);
    defer runA.deinit(gpa);
    var runB = try runmod.buildRun(Game, gpa, &game_systems, wB0, 0, generator.idleGen(Game), 3);
    defer runB.deinit(gpa);
    var r = try diverge(Game, gpa, &runA, &runB, &game_systems);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r.rows.items.len);
}

fn hpNegative(w: *const worldmod.World(Game)) ?Entity {
    const owners = w.table.owners();
    const masks = w.table.masks();
    const col = w.table.columnConst(Game.indexOf(Health));
    const bit = Game.bitOf(Health);
    for (owners, 0..) |e, row| {
        if ((masks[row] & bit) != 0 and col[row].hp < 0) return e;
    }
    return null;
}

test "firstTickWhere finds the first tick an invariant flips (hp<0 at tick 4 from hp=3)" {
    const gpa = testing.allocator;
    var w0 = worldmod.World(Game).init(0);
    errdefer w0.deinit(gpa);
    const e = try w0.spawn(gpa);
    w0.add(e, Health, .{ .hp = 3 }); // 3 -> t1=2,t2=1,t3=0,t4=-1
    var run = try runmod.buildRun(Game, gpa, &game_systems, w0, 0, generator.idleGen(Game), 6);
    defer run.deinit(gpa);

    const bp = (try firstTickWhere(Game, gpa, &run, &game_systems, hpNegative)).?;
    try testing.expectEqual(@as(u64, 4), bp.tick);
    try testing.expectEqual(@as(u32, 0), bp.entity.index);
}

// a tiny exogenous adjacency graph for reach: 0->{1,2}, 1->{3}, 2->{3}, 3->{1} (cycle)
const Graph = struct {
    fn neighbors(_: *const Graph, node: u32, out: *std.ArrayList(u32), gpa: Allocator) Allocator.Error!void {
        const edges: []const [2]u32 = &.{ .{ 0, 1 }, .{ 0, 2 }, .{ 1, 3 }, .{ 2, 3 }, .{ 3, 1 } };
        for (edges) |e| if (e[0] == node) try out.append(gpa, e[1]);
    }
};
fn u32Less(_: void, a: u32, b: u32) bool {
    return a < b;
}

test "reach is deterministic, cycle-safe, and canonical-ordered over an exogenous graph" {
    const gpa = testing.allocator;
    var g = Graph{};
    {
        const r = try reach(u32, gpa, &.{0}, &g, Graph.neighbors, u32Less);
        defer gpa.free(r);
        try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, r); // full closure, cycle 3->1 doesn't loop
    }
    {
        // seed-set insertion order does not change the canonical result
        const r = try reach(u32, gpa, &.{ 2, 1 }, &g, Graph.neighbors, u32Less);
        defer gpa.free(r);
        try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, r); // from {1,2}: reaches 3, not 0
    }
}
