//! State invariants (PLAN.md Phase 6, build-order step 2): the §8 first pillar.
//!
//! An `Invariant(R)` is the EXACT `fn(*const World(R)) ?Entity` shape `vopr/oracle.invariant` and
//! `query/diverge.firstTickWhere` already consume — promoted to a named struct so ONE declaration feeds
//! both the VOPR oracle path and the every-tick Debug/Safe check (check.zig). `invariantOracle` wraps the
//! UNCHANGED `oracle.invariant` (so the every-tick scan + first-violating-(tick,entity) Defect are reused
//! verbatim); `firstViolation` delegates to `firstTickWhere` (the on-demand bisection, no second
//! implementation). `fromAtom` adapts an `Atom(R)` to the `?Entity` shape (the atom's canonical-smallest
//! witness entity), so the §8 built-in atoms (rangeI/referencedLive/noOverlap/entityLive) become
//! invariants directly.

const std = @import("std");
const atom = @import("atom.zig");
const worldmod = @import("../world.zig");
const Entity = @import("../entity.zig").Entity;
const oraclemod = @import("../vopr/oracle.zig");
const Oracle = oraclemod.Oracle;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const diverge = @import("../query/diverge.zig");
const runmod = @import("../vopr/run.zig");

/// A named state invariant: a pure predicate over the current World returning the offending entity (or
/// null if it holds). The single source of truth read by the oracle path and the every-tick check.
pub fn Invariant(comptime R: type) type {
    return struct {
        name: []const u8,
        pred: *const fn (*const worldmod.World(R)) ?Entity,
    };
}

/// Adapt an `Atom(R)` to the invariant `?Entity` predicate: the atom's canonical-smallest witness entity
/// when it does not hold, else null. (The multi-entity witness is preserved at the atom level / in the
/// §7 violation relation; the hot invariant path is single-entity, matching oracle.invariant.)
pub fn predFromAtom(comptime R: type, comptime a: atom.Atom(R)) *const fn (*const worldmod.World(R)) ?Entity {
    const Impl = struct {
        fn pred(w: *const worldmod.World(R)) ?Entity {
            const hit = a.eval(w);
            if (hit.holds or hit.witness.n == 0) return null;
            return hit.witness.ents[0];
        }
    };
    return Impl.pred;
}

/// Build a named `Invariant(R)` from an `Atom(R)` (uses the atom's name).
pub fn fromAtom(comptime R: type, comptime a: atom.Atom(R)) Invariant(R) {
    return .{ .name = a.name, .pred = predFromAtom(R, a) };
}

/// An Oracle that checks the invariant at every tick and reports the first violating (tick, entity) as a
/// `Defect{kind=.invariant}` — a thin wrapper over the UNCHANGED `oracle.invariant`.
pub fn invariantOracle(comptime R: type, comptime systems: []const Sys(R), comptime inv: Invariant(R)) Oracle(R) {
    return oraclemod.invariant(R, systems, inv.name, inv.pred.*); // .* : pass the fn, not the fn-pointer
}

/// The first tick (1..=inputs.len) the invariant flips, via `firstTickWhere` (the §8 WHERE-DID-IT-BREAK
/// bisection) — no second scan implementation.
pub fn firstViolation(comptime R: type, gpa: std.mem.Allocator, run: *const runmod.Run(R), comptime systems: []const Sys(R), comptime inv: Invariant(R)) std.mem.Allocator.Error!?diverge.BreakPoint {
    return diverge.firstTickWhere(R, gpa, run, systems, inv.pred.*);
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

// hp>=0 as an invariant built from the rangeI atom
const hp_inv = fromAtom(Game, atom.rangeI(Game, Health, "hp", 0, 1_000_000));

test "invariantOracle yields the same first-violating (tick, entity) as oracle.invariant; firstViolation agrees" {
    const gpa = testing.allocator;
    // blk-scoped construction errdefer ends BEFORE buildRun consumes w0 (else a later failing `try`
    // would double-free the world buildRun already owns) — the gate.zig pattern.
    const e: Entity = .{ .index = 0, .generation = 0 };
    const w0 = blk: {
        var w = worldmod.World(Game).init(0);
        errdefer w.deinit(gpa);
        const spawned = try w.spawn(gpa);
        w.add(spawned, Health, .{ .hp = 3 }); // 3 -> t1=2,t2=1,t3=0,t4=-1 : flips at tick 4
        break :blk w;
    };
    var run = try runmod.buildRun(Game, gpa, &game_systems, w0, 0, generator.idleGen(Game), 6);
    defer run.deinit(gpa);

    // the spec oracle == the raw oracle.invariant on the same predicate
    const orc = invariantOracle(Game, &game_systems, hp_inv);
    const d = (try orc.eval(&run, gpa)).?;
    try testing.expectEqual(@import("../vopr/oracle.zig").Defect(Game).Kind.invariant, d.kind);
    try testing.expectEqual(@as(u64, 4), d.tick);
    try testing.expectEqual(e.index, d.detail.entity.index);

    // firstViolation (firstTickWhere) agrees on tick + entity
    const bp = (try firstViolation(Game, gpa, &run, &game_systems, hp_inv)).?;
    try testing.expectEqual(@as(u64, 4), bp.tick);
    try testing.expectEqual(e.index, bp.entity.index);
}

test "a holding invariant yields null from both paths" {
    const gpa = testing.allocator;
    const w0 = blk: {
        var w = worldmod.World(Game).init(0);
        errdefer w.deinit(gpa);
        const e = try w.spawn(gpa);
        w.add(e, Health, .{ .hp = 100 }); // stays >= 0 over 3 ticks
        break :blk w;
    };
    var run = try runmod.buildRun(Game, gpa, &game_systems, w0, 0, generator.idleGen(Game), 3);
    defer run.deinit(gpa);
    const orc = invariantOracle(Game, &game_systems, hp_inv);
    try testing.expectEqual(@as(?@import("../vopr/oracle.zig").Defect(Game), null), try orc.eval(&run, gpa));
    try testing.expectEqual(@as(?diverge.BreakPoint, null), try firstViolation(Game, gpa, &run, &game_systems, hp_inv));
}
