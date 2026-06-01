//! The canonical gkz example — a headless grid-roguelike combat arena, authored as a `gkz` Spec.
//!
//! This file is the GAME: the registry (components), the systems (rules), the events (provenance), the
//! specs (an invariant + a fun-proxy metric), and the seed→World builder. It is pure simulation — no
//! rendering, no clock, no float, no RNG cursor (the §14 view seam reads snapshots; it is not gkz's job).
//! `main.zig` is the harness that DRIVES this: step + observe + snapshot/replay + fork + sweep + VOPR.
//!
//! The map: a hero (team 0) stands in an arena; monsters (team 1) seek the hero, and adjacent enemies
//! trade blows until someone dies. Every mutation is deferred through the command buffer (`ctx.cmd`), so
//! all systems read one consistent start-of-tick snapshot and the result is order-independent — the §4
//! "scheduling is nondeterministic, results never are" property, for free.

const std = @import("std");
const gkz = @import("gkz");

// --- components (the world's columns) — each declares a unique kind_id; all integer (D7) -------------

pub const Position = struct {
    x: i32,
    y: i32,
    pub const kind_id: u16 = 1;
};
pub const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 2;
};
pub const Team = struct {
    id: u8, // 0 = hero, 1 = monster
    pub const kind_id: u16 = 3;
};
pub const Power = struct {
    atk: i32,
    pub const kind_id: u16 = 4;
};

/// The registry IS the schema: the comptime set of component types this game's worlds are made of.
pub const R = gkz.Registry(.{ Position, Health, Team, Power });

// --- events (pure side-output provenance, §5) — emitted only when a Recorder is attached -------------

pub const Damaged = struct {
    amount: i32,
    by: u32, // attacker entity index — "who hit me"
    pub const kind_id: u16 = 100;
};
pub const Slain = struct {
    by: u32,
    pub const kind_id: u16 = 101;
};

// --- the hero is always spawned first, so it is entity {index 0, generation 0} -----------------------
pub const HERO = gkz.Entity{ .index = 0, .generation = 0 };
const ARENA: i32 = 6; // a 13x13 arena, [-6, 6] on each axis
const MAX_ENTITIES = 256; // a system's allocation-free scratch bound (this game's levels stay well under)

fn cheb(a: Position, b: Position) i32 {
    return @intCast(@max(@abs(a.x - b.x), @abs(a.y - b.y))); // @abs(i32) is u32 → narrow back to i32
}
fn stepToward(from: Position, to: Position) Position {
    return .{ .x = from.x + std.math.sign(to.x - from.x), .y = from.y + std.math.sign(to.y - from.y) };
}

// A start-of-tick row snapshot a system collects into stack scratch (systems get no allocator — only the
// command buffer — so cross-entity logic reads into a bounded local array, then enqueues deferred edits).
pub const Row = struct { e: gkz.Entity, pos: Position, team: u8, hp: i32, atk: i32 };

fn collect(comptime markers: anytype, q: *gkz.Query(R, markers), buf: *[MAX_ENTITIES]Row) usize {
    var n: usize = 0;
    while (q.next()) |row| {
        if (n == MAX_ENTITIES) break;
        buf[n] = .{
            .e = row.entity(),
            .pos = row.read(Position).*,
            .team = row.read(Team).id,
            .hp = row.read(Health).hp,
            .atk = row.read(Power).atk,
        };
        n += 1;
    }
    return n;
}

/// Read every live entity into `buf` — OBSERVE a World between ticks, outside a system. `w.iterate(C)`
/// is the read-only front door (a system would use a `Query` instead); `w.getConst` reads an entity's
/// other components. Returns the count.
pub fn liveRows(w: *const gkz.World(R), buf: *[MAX_ENTITIES]Row) usize {
    var n: usize = 0;
    var it = w.iterate(Position);
    while (it.next()) |row| {
        if (n == MAX_ENTITIES) break;
        const e = row.entity;
        buf[n] = .{
            .e = e,
            .pos = row.value.*,
            .team = w.getConst(e, Team).?.id,
            .hp = w.getConst(e, Health).?.hp,
            .atk = w.getConst(e, Power).?.atk,
        };
        n += 1;
    }
    return n;
}

// --- systems (the rules). All read-only queries + deferred `cmd` edits ⇒ no write-conflicts, one stage,
//     order-independent result. The CORRECT seek refuses to stack two entities on one tile; the BUGGY
//     variant omits that check — a planted defect the VOPR catches against the no-stacking invariant. ----

const FULL = .{ gkz.Read(Position), gkz.Read(Team), gkz.Read(Health), gkz.Read(Power) };

fn seekImpl(ctx: *gkz.SimCtx(R), q: *gkz.Query(R, FULL), comptime check_occupancy: bool) std.mem.Allocator.Error!void {
    var buf: [MAX_ENTITIES]Row = undefined;
    const n = collect(FULL, q, &buf);

    // the hero is the move target
    var hero: ?Position = null;
    for (buf[0..n]) |r| if (r.team == 0) {
        hero = r.pos;
    };
    const target = hero orelse return; // hero already dead → monsters stop seeking

    // claimed tiles this tick (start-of-tick occupancy + tiles already moved into) — the no-stacking rule
    var claimed: [MAX_ENTITIES]Position = undefined;
    var cn: usize = 0;
    if (check_occupancy) for (buf[0..n]) |r| {
        claimed[cn] = r.pos;
        cn += 1;
    };

    for (buf[0..n]) |r| {
        if (r.team == 0 or r.hp <= 0) continue; // hero is passive; the dying don't move (death despawns them)
        if (cheb(r.pos, target) <= 1) continue; // already in melee range
        const want = stepToward(r.pos, target);
        if (check_occupancy) {
            var blocked = false;
            for (claimed[0..cn]) |c| if (c.x == want.x and c.y == want.y) {
                blocked = true;
            };
            if (blocked) continue; // tile taken — hold position (no two entities on one tile)
            claimed[cn] = want;
            cn += 1;
        }
        try ctx.cmd.set(r.e, Position, want);
    }
}

/// CORRECT seek — respects tile occupancy (maintains the no-stacking invariant).
pub fn seek(ctx: *gkz.SimCtx(R), q: *gkz.Query(R, FULL)) std.mem.Allocator.Error!void {
    return seekImpl(ctx, q, true);
}
/// BUGGY seek — ignores occupancy, so two monsters can pile onto one tile. The planted defect; the VOPR
/// catches it as a no-stacking invariant violation across a seed sweep.
pub fn seekBuggy(ctx: *gkz.SimCtx(R), q: *gkz.Query(R, FULL)) std.mem.Allocator.Error!void {
    return seekImpl(ctx, q, false);
}

/// Melee — every pair of adjacent enemies deals its `atk` to the other; damage from a whole tick lands
/// simultaneously (collected, then applied via `cmd`). Emits a `Damaged` event per hit (provenance).
pub fn melee(ctx: *gkz.SimCtx(R), q: *gkz.Query(R, FULL)) std.mem.Allocator.Error!void {
    var buf: [MAX_ENTITIES]Row = undefined;
    const n = collect(FULL, q, &buf);
    for (buf[0..n], 0..) |target, i| {
        if (target.hp <= 0) continue;
        var incoming: i32 = 0;
        var attacker: u32 = 0;
        for (buf[0..n], 0..) |src, j| {
            if (i == j or src.team == target.team or src.hp <= 0) continue;
            if (cheb(src.pos, target.pos) == 1) {
                incoming += src.atk;
                attacker = src.e.index;
            }
        }
        if (incoming > 0) {
            _ = try ctx.emitS(Damaged, target.e, .{ .amount = incoming, .by = attacker });
            try ctx.cmd.set(target.e, Health, .{ .hp = target.hp - incoming });
        }
    }
}

const DEATH = .{ gkz.Read(Health) };
/// Death — anything at hp ≤ 0 is removed (deferred) and a `Slain` event recorded.
pub fn death(ctx: *gkz.SimCtx(R), q: *gkz.Query(R, DEATH)) std.mem.Allocator.Error!void {
    while (q.next()) |row| {
        if (row.read(Health).hp <= 0) {
            try ctx.cmd.despawn(row.entity());
            _ = try ctx.emitS(Slain, row.entity(), .{ .by = 0 });
        }
    }
}

/// The CORRECT system set — what ships.
pub const systems = [_]gkz.Sys(R){
    gkz.system(R, "seek", seek),
    gkz.system(R, "melee", melee),
    gkz.system(R, "death", death),
};
/// The same game with the planted seek defect — used only to demonstrate the VOPR catching it.
pub const systems_buggy = [_]gkz.Sys(R){
    gkz.system(R, "seek", seekBuggy),
    gkz.system(R, "melee", melee),
    gkz.system(R, "death", death),
};

// --- specs: an invariant (correctness) + a fun-proxy metric (balance) --------------------------------

/// INVARIANT: no two live entities ever occupy the same tile. A custom atom (the read-only column scan
/// every built-in atom uses) — witnesses the canonical-smallest stacked entity when violated.
pub fn noStackingAtom() gkz.spec.atom.Atom(R) {
    const Impl = struct {
        fn eval(w: *const gkz.World(R)) gkz.spec.atom.AtomHit {
            const ti = comptime R.indexOf(Position);
            const col = w.table.columnConst(ti);
            const owners = w.table.owners();
            const masks = w.table.masks();
            const bit = R.bit(ti);
            var worst: ?gkz.Entity = null;
            for (owners, 0..) |e, row| {
                if ((masks[row] & bit) == 0) continue;
                for (owners, 0..) |e2, row2| {
                    if (row2 == row or (masks[row2] & bit) == 0) continue;
                    if (col[row].x == col[row2].x and col[row].y == col[row2].y) {
                        const c = if (e.index <= e2.index) e else e2;
                        if (worst == null or c.index < worst.?.index) worst = c;
                    }
                }
            }
            if (worst) |e| return .{ .holds = false, .witness = gkz.spec.atom.Witness.single(e) };
            return .{ .holds = true };
        }
    };
    return .{ .name = "no_stacking", .eval = Impl.eval };
}

pub fn noStackingInvariant() gkz.spec.invariant.Invariant(R) {
    return gkz.spec.invariant.fromAtom(R, noStackingAtom());
}

/// METRIC (fun-proxy): turns the hero survives — the first tick the hero is dead (hp ≤ 0). `atoms[0]`.
pub const atoms = [_]gkz.spec.atom.Atom(R){
    gkz.spec.atom.fieldLE(R, Health, "hp", HERO, 0), // "hero is dead"
};
pub fn turnsSurvived() gkz.spec.metric.Metric(u64) {
    return gkz.spec.metric.timeToCondition(0);
}

// --- the seed → World builder (varies monster placement by seed; the sweep's `seed_world`) -----------

/// Build a starting arena for `seed`: the hero at the origin, plus a seed-determined ring of monsters.
/// Deterministic in `seed` alone — the only nondeterminism ingress, exactly as a recorded input would be.
pub fn seedWorld(gpa: std.mem.Allocator, seed: u64) std.mem.Allocator.Error!gkz.World(R) {
    var w = gkz.World(R).init(seed);
    errdefer w.deinit(gpa);

    // hero first ⇒ entity {0,0}
    const hero = try w.spawn(gpa);
    w.add(hero, Position, .{ .x = 0, .y = 0 });
    w.add(hero, Health, .{ .hp = 30 });
    w.add(hero, Team, .{ .id = 0 });
    w.add(hero, Power, .{ .atk = 5 });

    // a handful of monsters on DISTINCT edge tiles (never the origin, never a repeat) — a keyed,
    // cursor-free scatter pure in (seed, k). De-duping placement is the author's job; the no-stacking
    // INVARIANT (below) is what catches it if you forget — as it should.
    const n_monsters: u32 = 3 + @as(u32, @intCast(seed % 3)); // 3..5
    var taken: [16]Position = undefined;
    var placed: u32 = 0;
    var k: u64 = 0;
    while (placed < n_monsters and k < 256) : (k += 1) {
        const h = std.hash.XxHash64.hash(seed, std.mem.asBytes(&k));
        const x = @as(i32, @intCast(h % @as(u64, @intCast(2 * ARENA + 1)))) - ARENA;
        const sign: i32 = if ((h >> 32) & 1 == 0) -1 else 1;
        const p = Position{ .x = x, .y = sign * ARENA };
        if (p.x == 0 and p.y == 0) continue; // never spawn on the hero
        var dup = false;
        for (taken[0..placed]) |t| if (t.x == p.x and t.y == p.y) {
            dup = true;
        };
        if (dup) continue; // distinct tiles only
        taken[placed] = p;
        const m = try w.spawn(gpa);
        w.add(m, Position, p);
        w.add(m, Health, .{ .hp = 10 });
        w.add(m, Team, .{ .id = 1 });
        w.add(m, Power, .{ .atk = 3 });
        placed += 1;
    }
    return w;
}

// ----------------------------------------------------------------------------------------------------
// Tests — the game's own assertions (run by `zig build test`). The harness (main.zig) demonstrates the
// author-facing loop; these pin the properties.
// ----------------------------------------------------------------------------------------------------

const testing = std.testing;

test "a tick is deterministic and the hero eventually wins or dies (no crash, headless)" {
    const gpa = testing.allocator;
    var w = try seedWorld(gpa, 7);
    defer w.deinit(gpa);
    // run 40 ticks; just assert it advances + stays a valid World (digest computable each tick)
    var t: usize = 0;
    while (t < 40) : (t += 1) {
        const next = try gkz.step(R, gpa, w, gkz.input.EMPTY, &systems);
        w.deinit(gpa);
        w = next;
        _ = try w.digest(gpa);
    }
    try testing.expectEqual(@as(u64, 40), w.tick);
}

test "same seed ⇒ identical end-state digest (determinism)" {
    const gpa = testing.allocator;
    const runOnce = struct {
        fn f(g: std.mem.Allocator, seed: u64, ticks: usize) !u64 {
            var w = try seedWorld(g, seed);
            defer w.deinit(g);
            var t: usize = 0;
            while (t < ticks) : (t += 1) {
                const next = try gkz.step(R, g, w, gkz.input.EMPTY, &systems);
                w.deinit(g);
                w = next;
            }
            return (try w.digest(g)).hash;
        }
    }.f;
    try testing.expectEqual(try runOnce(gpa, 7, 30), try runOnce(gpa, 7, 30));
    try testing.expect(try runOnce(gpa, 7, 30) != try runOnce(gpa, 8, 30)); // different seed ⇒ different run
}
