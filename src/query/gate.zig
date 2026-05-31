//! The Phase-5 cross-build determinism gate (PLAN.md Phase 5, build-order step 7).
//!
//! Pins a GKZR1 `resultDigest` for each relation/shape over a FIXED fixture (a small registry + system
//! set + a diamond cause-graph EventLog + a despawn-forked RunA/RunB), asserted byte-identical across
//! Debug/ReleaseSafe/ReleaseFast (D2/D5) — query results are a deterministic, canonically-ordered,
//! build-mode-invariant pure function of the observed state. Five companion sub-gates prove the
//! MECHANISM rather than just freezing one output:
//!   1. SCRAMBLE invariance — appending the EventLog in reverse and building the World via a different
//!      despawn history leave every digest unchanged (the canonical re-sort severs observation order;
//!      the Phase-2 order-permutation / Phase-3 events-OFF==ON analogue, guarding recorder.zig note 16).
//!   2. system/3 reflection-exactness — the reflected reads/writes equal masks recomputed independently
//!      from each system's `Access` (§7's "always exact, never drifts").
//!   3. DUAL-PATH recursion — the `why` shape's cause set equals both `event_log.causeChain` AND an
//!      independent generic `reach` over the caused_by adjacency.
//!   4. GKZR1/GKZQ1 wire round-trip identity over the battery.
//!   5. OOM-injection leak-freedom (the Phase-4 posture) across the whole battery.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const term = @import("term.zig");
const resultmod = @import("result.zig");
const QueryResult = resultmod.QueryResult;
const resultDigest = resultmod.resultDigest;
const relations = @import("relations.zig");
const catalog = @import("catalog.zig");
const divergemod = @import("diverge.zig");
const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const wire = @import("wire.zig");

const worldmod = @import("../world.zig");
const Entity = @import("../entity.zig").Entity;
const eventmod = @import("../event.zig");
const EventId = eventmod.EventId;
const EventLog = @import("../event_log.zig").EventLog;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const system = schedule.system;
const q2 = @import("../query.zig");
const Read = q2.Read;
const Write = q2.Write;
const With = q2.With;
const Query2 = q2.Query;
const simctx = @import("../simctx.zig");
const SimCtx = simctx.SimCtx;
const runmod = @import("../vopr/run.zig");
const generator = @import("../vopr/generator.zig");
const input = @import("../input.zig");
const serialize = @import("../serialize.zig");

// --- the fixture registry + systems ---------------------------------------------------------------

const Position = struct {
    x: i64,
    y: i64,
    pub const kind_id: u16 = 10;
};
const Velocity = struct {
    dx: i64,
    pub const kind_id: u16 = 5;
};
const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 20;
};
const G = Registry(.{ Position, Velocity, Health });
const Registry = @import("../registry.zig").Registry;

fn move(ctx: *SimCtx(G), q: *Query2(G, .{ Read(Velocity), Write(Position) })) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Position).x += row.read(Velocity).dx;
}
fn drainHealth(ctx: *SimCtx(G), q: *Query2(G, .{Write(Health)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Health).hp -= 1;
}
fn tagScan(ctx: *SimCtx(G), q: *Query2(G, .{ Read(Health), With(Position) })) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}
const fixture_systems = [_]Sys(G){
    system(G, "move", move),
    system(G, "drainHealth", drainHealth),
    system(G, "tagScan", tagScan),
};

// --- fixture builders -----------------------------------------------------------------------------

/// 5 entities spawned (0..4); components on 0,2,4; entities 1 and 3 despawned in `despawn_order`. The
/// two despawn orders yield IDENTICAL logical content but DIFFERENT physical row layouts (the scramble).
fn buildWorld(gpa: Allocator, despawn_order: [2]u32) !worldmod.World(G) {
    var w = worldmod.World(G).init(0xC0FFEE);
    errdefer w.deinit(gpa);
    var es: [5]Entity = undefined;
    for (&es) |*e| e.* = try w.spawn(gpa);
    w.add(es[0], Position, .{ .x = 1, .y = 2 });
    w.add(es[2], Position, .{ .x = 3, .y = 4 });
    w.add(es[2], Velocity, .{ .dx = 7 });
    w.add(es[4], Health, .{ .hp = 42 });
    w.add(es[4], Position, .{ .x = -5, .y = 0 });
    for (despawn_order) |idx| try w.despawn(gpa, es[idx]);
    return w;
}

/// Two worlds with IDENTICAL component content but different physical table layouts: a component-less
/// throwaway at index 1 is either kept live (false → physical [c0,t1,c2,c3]) or despawned (true →
/// swap-removes the last content row into slot 1 → physical [c0,c3,c2]). The genuine layout scramble.
fn buildLayout(gpa: Allocator, despawn_throwaway: bool) !worldmod.World(G) {
    var w = worldmod.World(G).init(0xC0FFEE);
    errdefer w.deinit(gpa);
    const c0 = try w.spawn(gpa); // idx0
    const t1 = try w.spawn(gpa); // idx1 — component-less throwaway
    const c2 = try w.spawn(gpa); // idx2
    const c3 = try w.spawn(gpa); // idx3
    w.add(c0, Position, .{ .x = 1, .y = 1 });
    w.add(c2, Position, .{ .x = 2, .y = 2 });
    w.add(c3, Velocity, .{ .dx = 3 });
    if (despawn_throwaway) try w.despawn(gpa, t1);
    return w;
}

const A: EventId = .{ .tick = 1, .emitter = 0, .seq = 0 };
const B: EventId = .{ .tick = 2, .emitter = 1, .seq = 0 };
const C: EventId = .{ .tick = 2, .emitter = 2, .seq = 0 };
const D: EventId = .{ .tick = 3, .emitter = 1, .seq = 0 };

/// The diamond D<-{B,C}, B<-A, C<-A, appended in normal or reversed order (the log-order scramble).
fn buildLog(gpa: Allocator, reversed: bool) !EventLog {
    var log: EventLog = .{};
    errdefer log.deinit(gpa);
    const subj: Entity = .{ .index = 0, .generation = 0 };
    const Step = struct { id: EventId, kind: u16, em: u16, payload: []const u8, causes: []const EventId };
    const steps = [_]Step{
        .{ .id = A, .kind = 100, .em = 0, .payload = &.{0xAA}, .causes = &.{} },
        .{ .id = B, .kind = 100, .em = 1, .payload = &.{0xBB}, .causes = &.{A} },
        .{ .id = C, .kind = 100, .em = 2, .payload = &.{0xCC}, .causes = &.{A} },
        .{ .id = D, .kind = 101, .em = 1, .payload = &.{0xDD}, .causes = &.{ B, C } },
    };
    if (reversed) {
        var i: usize = steps.len;
        while (i > 0) {
            i -= 1;
            try log.append(gpa, steps[i].id, steps[i].kind, steps[i].em, subj, steps[i].payload, steps[i].causes);
        }
    } else {
        for (steps) |s| try log.append(gpa, s.id, s.kind, s.em, subj, s.payload, s.causes);
    }
    return log;
}

fn seedForkBase(gpa: Allocator) !worldmod.World(G) {
    var w = worldmod.World(G).init(0);
    errdefer w.deinit(gpa); // scoped to construction; does not escape (return moves ownership out)
    const x = try w.spawn(gpa);
    const y = try w.spawn(gpa);
    w.add(x, Health, .{ .hp = 5 });
    w.add(y, Health, .{ .hp = 5 });
    return w;
}

/// Two Health entities, drained each tick; RunB despawns entity 0 at tick 2 (the diverge fork). Uses
/// explicit catch-cleanup (NOT errdefer) because `buildRun` CONSUMES the world it is given — an errdefer
/// on a consumed world double-frees (it would fire after buildRun already owns/freed it).
fn buildForks(gpa: Allocator) !struct { a: runmod.Run(G), b: runmod.Run(G) } {
    var base = try seedForkBase(gpa);
    var wB0 = base.clone(gpa) catch |e| {
        base.deinit(gpa);
        return e;
    };
    var runA = runmod.buildRun(G, gpa, &fixture_systems, base, 0, generator.idleGen(G), 3) catch |e| {
        wB0.deinit(gpa); // buildRun freed `base` on its own error; free the still-owned clone
        return e;
    };
    const despawn0 = [_]input.Command{.{ .actor = .{ .index = 0, .generation = 0 }, .verb = 2 }};
    const scriptB = [_]input.Input{ .{ .tick = 0, .commands = &.{} }, .{ .tick = 0, .commands = &despawn0 }, .{ .tick = 0, .commands = &.{} } };
    var specB = generator.ScriptedSpec{ .inputs = &scriptB };
    const runB = runmod.buildRun(G, gpa, &fixture_systems, wB0, 0, generator.scriptedGen(G, &specB), 3) catch |e| {
        runA.deinit(gpa); // buildRun freed `wB0`; free the completed runA
        return e;
    };
    return .{ .a = runA, .b = runB };
}

// --- pinned digests (filled from the first green run; asserted identical across the 3-mode matrix) --

pub const QUERY_COMPONENT_DIGEST: u64 = 0x683f6d6bea6e6c91;
pub const QUERY_EVENT_DIGEST: u64 = 0x7f2018d0223e56eb;
pub const QUERY_CAUSEDBY_DIGEST: u64 = 0x7a3c8ea327fb2739;
pub const QUERY_WHY_DIGEST: u64 = 0x53fb69bac6f69ebf;
pub const QUERY_SYSTEM_DIGEST: u64 = 0x70655d5a2fe151e5;
pub const QUERY_DIVERGE_DIGEST: u64 = 0xfa6944c9c9b50740;
pub const QUERY_SCHEMA_DIGEST: u64 = 0x2561d636c8582012;
pub const QUERY_COLUMN_DIGEST: u64 = 0x9de812ed4aa09afb;

/// Compute the eight fixture digests (the canonical, non-scrambled fixture). Caller frees nothing.
fn fixtureDigests(gpa: Allocator) ![8]u64 {
    var w = try buildWorld(gpa, .{ 1, 3 });
    defer w.deinit(gpa);
    var log = try buildLog(gpa, false);
    defer log.deinit(gpa);
    var forks = try buildForks(gpa);
    defer forks.a.deinit(gpa);
    defer forks.b.deinit(gpa);

    const eng = Engine(G, &fixture_systems).init(&w, &log);
    var out: [8]u64 = undefined;
    const Q = engine_mod.Query(G);

    const specs = [_]Q{ .{ .component = .{} }, .{ .event = .{} }, .{ .caused_by_direct = D }, .{ .why = D }, .systems_all, .schema, .columns };
    inline for (specs, 0..) |qspec, i| {
        var r = try eng.evaluate(gpa, qspec);
        defer r.deinit(gpa);
        out[mapIdx(i)] = (try resultDigest(gpa, &r)).hash;
    }
    // diverge is an operator (run pointers), index 5
    var dr = try eng.diverge(gpa, &forks.a, &forks.b);
    defer dr.deinit(gpa);
    out[5] = (try resultDigest(gpa, &dr)).hash;
    return out;
}

// map evaluate-spec index -> the out[] slot (component0,event1,causedby2,why3,system4,[diverge5],schema6,column7)
fn mapIdx(i: usize) usize {
    return switch (i) {
        0 => 0, // component
        1 => 1, // event
        2 => 2, // caused_by
        3 => 3, // why
        4 => 4, // systems_all
        5 => 6, // schema
        6 => 7, // columns
        else => unreachable,
    };
}

test "PINNED: the eight fixture digests are byte-identical across build modes" {
    const gpa = testing.allocator;
    const d = try fixtureDigests(gpa);
    try testing.expectEqual(QUERY_COMPONENT_DIGEST, d[0]);
    try testing.expectEqual(QUERY_EVENT_DIGEST, d[1]);
    try testing.expectEqual(QUERY_CAUSEDBY_DIGEST, d[2]);
    try testing.expectEqual(QUERY_WHY_DIGEST, d[3]);
    try testing.expectEqual(QUERY_SYSTEM_DIGEST, d[4]);
    try testing.expectEqual(QUERY_DIVERGE_DIGEST, d[5]);
    try testing.expectEqual(QUERY_SCHEMA_DIGEST, d[6]);
    try testing.expectEqual(QUERY_COLUMN_DIGEST, d[7]);
}

test "SCRAMBLE invariance: log reversal + alternate despawn history leave every digest unchanged" {
    const gpa = testing.allocator;
    // component/3: identical logical content, GENUINELY different physical layout. World A keeps a
    // component-less throwaway live (occupying physical slot 1); World B despawns it, swap-removing the
    // last content row (c3) into slot 1 — so c2/c3 sit at different physical rows than in A. The two
    // componentRel results must be byte-identical because canonicalOrder sorts by entity.index.
    {
        var wa = try buildLayout(gpa, false);
        defer wa.deinit(gpa);
        var wb = try buildLayout(gpa, true);
        defer wb.deinit(gpa);
        // sanity: the physical row layouts actually differ (else the scramble would be vacuous)
        try testing.expect(wa.table.rowCount() != wb.table.rowCount());
        var r1 = try relations.componentRel(G, gpa, &wa, .{});
        defer r1.deinit(gpa);
        var r2 = try relations.componentRel(G, gpa, &wb, .{});
        defer r2.deinit(gpa);
        try testing.expectEqual(@as(usize, 3), r1.rows.items.len);
        try testing.expectEqual((try resultDigest(gpa, &r1)).hash, (try resultDigest(gpa, &r2)).hash);
    }
    // event/5, caused_by/2, why: identical content, reversed log append order
    {
        var ln = try buildLog(gpa, false);
        defer ln.deinit(gpa);
        var lr = try buildLog(gpa, true);
        defer lr.deinit(gpa);
        inline for (.{ "event", "causedby", "why" }) |which| {
            var a = try relForLog(gpa, &ln, which);
            defer a.deinit(gpa);
            var b = try relForLog(gpa, &lr, which);
            defer b.deinit(gpa);
            try testing.expectEqual((try resultDigest(gpa, &a)).hash, (try resultDigest(gpa, &b)).hash);
        }
    }
}

fn relForLog(gpa: Allocator, log: *const EventLog, comptime which: []const u8) !QueryResult {
    if (comptime std.mem.eql(u8, which, "event")) return relations.eventRel(gpa, log, .{});
    if (comptime std.mem.eql(u8, which, "causedby")) return relations.causedByDirect(gpa, log, D);
    return relations.whyChain(gpa, log, D);
}

test "system/3 reflection-exactness: reflected reads/writes equal independently-recomputed masks" {
    const gpa = testing.allocator;
    var r = try relations.systemRel(G, &fixture_systems, gpa, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(fixture_systems.len, r.rows.items.len);
    inline for (fixture_systems, 0..) |s, sid| {
        // recompute expected ascending kind lists straight from the Access masks
        const exp_reads = expectedKinds(s.access.read);
        const exp_writes = expectedKinds(s.access.write);
        const row = r.rows.items[sid]; // systemRel emits in system-id order (canonical)
        const got_reads = try relations.decodeKindList(gpa, r.bytesOf(row.vals[2].bytes));
        defer gpa.free(got_reads);
        const got_writes = try relations.decodeKindList(gpa, r.bytesOf(row.vals[3].bytes));
        defer gpa.free(got_writes);
        try testing.expectEqualSlices(u16, exp_reads, got_reads);
        try testing.expectEqualSlices(u16, exp_writes, got_writes);
    }
}

/// Independently recompute a mask's ascending kind_id list — via a DIFFERENT primitive than the producer
/// (`encodeKindList` iterates bit-positions through `R.sorted[p]`; this iterates the component TYPES,
/// taking membership from `bitOf(C)` and the id from `C.kind_id`, then insertion-sorts). A bug in the
/// rank↔kind_id mapping would make the two disagree, so the test is not circular.
fn expectedKinds(comptime mask: G.Mask) []const u16 {
    return comptime blk: {
        var list: []const u16 = &.{};
        for (G.Components) |Comp| {
            if ((mask & G.bitOf(Comp)) != 0) list = sortedInsert(list, Comp.kind_id);
        }
        break :blk list;
    };
}
fn sortedInsert(comptime list: []const u16, comptime v: u16) []const u16 {
    var out: []const u16 = &.{};
    var inserted = false;
    for (list) |x| {
        if (!inserted and v < x) {
            out = out ++ &[_]u16{v};
            inserted = true;
        }
        out = out ++ &[_]u16{x};
    }
    return if (inserted) out else out ++ &[_]u16{v};
}

// The independent cross-check is causeChain's BFS vs reach's SEPARATE BFS implementation. `whyChain`
// delegates to causeChain (it is the surfaced form, not a third implementation), so the why==causeChain
// leg verifies the surface plumbing while the causeChain==reach leg is the genuine two-implementation
// recursion witness.
test "DUAL-PATH recursion: causeChain (via why) and an independent reach over caused_by agree" {
    const gpa = testing.allocator;
    var log = try buildLog(gpa, false);
    defer log.deinit(gpa);

    // leg 1: the why shape (the surfaced form of causeChain), extract the cause column as a set
    var why = try relations.whyChain(gpa, &log, D);
    defer why.deinit(gpa);
    var from_why: std.ArrayList(EventId) = .empty;
    defer from_why.deinit(gpa);
    for (why.rows.items) |row| try from_why.append(gpa, row.vals[1].event_id);

    // path 2: causeChain directly
    const from_chain = try log.causeChain(gpa, D);
    defer gpa.free(from_chain);

    // path 3: an independent generic reach over the caused_by adjacency
    const Adj = struct {
        log: *const EventLog,
        fn nb(self: *const @This(), node: EventId, out: *std.ArrayList(EventId), a: Allocator) Allocator.Error!void {
            for (self.log.causesOf(node)) |c| try out.append(a, c);
        }
        fn less(_: void, x: EventId, y: EventId) bool {
            return x.order(y) == .lt;
        }
    };
    var adj = Adj{ .log = &log };
    const reached = try divergemod.reach(EventId, gpa, &.{D}, &adj, Adj.nb, Adj.less);
    defer gpa.free(reached);
    // reach includes the root D; the ancestors are reached \ {D}
    var anc: std.ArrayList(EventId) = .empty;
    defer anc.deinit(gpa);
    for (reached) |n| if (!n.eql(D)) try anc.append(gpa, n);

    // all three describe the same ancestor set {A,B,C}
    try testing.expectEqual(from_chain.len, from_why.items.len);
    try testing.expectEqual(from_chain.len, anc.items.len);
    for (from_chain, 0..) |id, i| {
        try testing.expect(id.eql(from_why.items[i]));
        try testing.expect(id.eql(anc.items[i]));
    }
}

test "GKZR1/GKZQ1 wire round-trip identity over the fixture battery" {
    const gpa = testing.allocator;
    var w = try buildWorld(gpa, .{ 1, 3 });
    defer w.deinit(gpa);
    var log = try buildLog(gpa, false);
    defer log.deinit(gpa);
    const eng = Engine(G, &fixture_systems).init(&w, &log);
    const Q = engine_mod.Query(G);
    inline for (.{ Q{ .component = .{} }, Q{ .event = .{} }, Q{ .why = D }, Q.systems_all, Q.schema, Q.columns }) |qspec| {
        var r = try eng.evaluate(gpa, qspec);
        defer r.deinit(gpa);
        // GKZR1: the RESULT round-trips byte-stable
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
        try resultmod.writeResult(&sink, &r);
        var reader = serialize.ByteReader{ .bytes = buf.items };
        var r2 = try resultmod.readResult(gpa, &reader);
        defer r2.deinit(gpa);
        try testing.expectEqual((try resultDigest(gpa, &r)).hash, (try resultDigest(gpa, &r2)).hash);
        // GKZQ1: the QUERY round-trips and the decoded query evaluates to the same result
        var qbuf: std.ArrayList(u8) = .empty;
        defer qbuf.deinit(gpa);
        var qsink = serialize.ByteSink{ .list = &qbuf, .gpa = gpa };
        try wire.writeQuery(&qsink, G, qspec);
        var qreader = serialize.ByteReader{ .bytes = qbuf.items };
        const decoded_q = try wire.readQuery(G, &qreader);
        var r3 = try eng.evaluate(gpa, decoded_q);
        defer r3.deinit(gpa);
        try testing.expectEqual((try resultDigest(gpa, &r)).hash, (try resultDigest(gpa, &r3)).hash);
    }
}

fn neverBreaks(_: *const worldmod.World(G)) ?Entity {
    return null; // forces firstTickWhere to scan (and worldAt-allocate) every tick — for the OOM battery
}

/// caused_by adjacency over a log (shared by the OOM battery's reach call).
const CausedByAdj = struct {
    log: *const EventLog,
    fn nb(self: *const CausedByAdj, node: EventId, out: *std.ArrayList(EventId), a: Allocator) Allocator.Error!void {
        for (self.log.causesOf(node)) |c| try out.append(a, c);
    }
    fn less(_: void, x: EventId, y: EventId) bool {
        return x.order(y) == .lt;
    }
};

/// Run every query producer AND operator (incl. firstTickWhere + reach) over PRE-BUILT fixtures with the
/// (failing) `gpa`. The fixtures are built once with a stable allocator outside the failure loop, so the
/// injection targets exactly the query layer (relations/result/wire/diverge/operators), not the Run
/// machinery the VOPR already OOM-tests.
fn queryBatteryOnce(gpa: Allocator, w: *const worldmod.World(G), log: *const EventLog, ra: *const runmod.Run(G), rb: *const runmod.Run(G)) !void {
    const eng = Engine(G, &fixture_systems).init(w, log);
    const Q = engine_mod.Query(G);
    inline for (.{ Q{ .component = .{} }, Q{ .event = .{} }, Q{ .caused_by_direct = D }, Q{ .why = D }, Q.systems_all, Q.schema, Q.columns }) |qspec| {
        var r = try eng.evaluate(gpa, qspec);
        r.deinit(gpa);
    }
    var dr = try eng.diverge(gpa, ra, rb);
    dr.deinit(gpa);
    _ = try eng.firstTickWhere(gpa, ra, neverBreaks); // scans every tick (worldAt-allocates each)
    var adj = CausedByAdj{ .log = log };
    const reached = try divergemod.reach(EventId, gpa, &.{D}, &adj, CausedByAdj.nb, CausedByAdj.less);
    gpa.free(reached);
}

test "OOM-injection: the whole query battery is leak-free under every allocation-failure point" {
    const gpa = testing.allocator;
    var w = try buildWorld(gpa, .{ 1, 3 });
    defer w.deinit(gpa);
    var log = try buildLog(gpa, false);
    defer log.deinit(gpa);
    var forks = try buildForks(gpa);
    defer forks.a.deinit(gpa);
    defer forks.b.deinit(gpa);
    try testing.checkAllAllocationFailures(testing.allocator, queryBatteryOnce, .{ &w, &log, &forks.a, &forks.b });
}
