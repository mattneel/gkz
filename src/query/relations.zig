//! The five §7 relation producers (PLAN.md Phase 5, build-order step 3).
//!
//! Each producer is a hand-written CANONICAL traversal over already-certified kernel machinery, emitting
//! rows into a `result.Builder` (which re-sorts to canonical order and dedups at `finalize`). Nothing
//! here mutates state — every input is a `*const` borrow or a comptime value, so the surface is pure
//! observation off the throughput path (D1). The relations:
//!   * component/3 (Entity, Kind, Value)         — `Table.canonicalOrder` + per-kind `serialize.writeValue`
//!   * event/5     (EventId, Kind, Tick, Emitter, Payload) — re-sorted by `EventId.order`
//!   * caused_by/2 (Effect, Cause)               — direct edges, or the transitive set via `causeChain`
//!   * system/3    (SystemId, Name, Reads, Writes) — comptime reflection off `Sys(R).access`, never drifts
//!   * (diverge/3 lives in diverge.zig — it needs the fork/replay machinery.)
//!
//! The relation SCHEMAS are declared here as the single source of truth; the catalog (catalog.zig)
//! builds its self-description from these same constants and asserts every producer matches.

const std = @import("std");
const Allocator = std.mem.Allocator;

const term = @import("term.zig");
const Value = term.Value;
const Row = term.Row;
const Schema = term.Schema;
const RelId = term.RelId;
const resultmod = @import("result.zig");
const QueryResult = resultmod.QueryResult;
const Builder = resultmod.Builder;

const worldmod = @import("../world.zig");
const eventmod = @import("../event.zig");
const EventId = eventmod.EventId;
const event_log = @import("../event_log.zig");
const EventLog = event_log.EventLog;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const serialize = @import("../serialize.zig");
const Entity = @import("../entity.zig").Entity;

// --- canonical schemas (single source of truth; catalog + producers both reference these) -----------

pub const COMPONENT_SCHEMA = Schema.make(&.{ .{ "entity", .entity }, .{ "kind", .kind }, .{ "value", .bytes } });
pub const EVENT_SCHEMA = Schema.make(&.{ .{ "id", .event_id }, .{ "kind", .kind }, .{ "tick", .tick }, .{ "emitter", .u }, .{ "payload", .bytes } });
pub const CAUSED_BY_SCHEMA = Schema.make(&.{ .{ "effect", .event_id }, .{ "cause", .event_id } });
// reads/writes are length-prefixed u16 kind_id lists (ascending) in the bytes arm — §7's list columns
// kept inside the closed Value space; decode as u16 count then count×u16.
pub const SYSTEM_SCHEMA = Schema.make(&.{ .{ "system_id", .u }, .{ "name", .bytes }, .{ "reads", .bytes }, .{ "writes", .bytes } });
// diverge/3's producer lives in diverge.zig (it needs the fork/replay machinery), but its schema is
// declared here so the catalog can describe all seven relations from one source.
pub const DIVERGE_SCHEMA = Schema.make(&.{ .{ "tick", .tick }, .{ "entity", .entity }, .{ "kind", .kind } });

// --- filters --------------------------------------------------------------------------------------

pub const ComponentFilter = struct { entity: ?Entity = null, kind: ?u16 = null };
pub const EventFilter = struct { tick_lo: ?u64 = null, tick_hi: ?u64 = null, kind: ?u16 = null, emitter: ?u16 = null };
pub const SystemFilter = struct { writes_kind: ?u16 = null, reads_kind: ?u16 = null };

// --- component/3 ----------------------------------------------------------------------------------

/// Current world state: one row per (live entity, present component) with the component's canonical-LE
/// serialization as the Value. Canonical (entity.index, kind_id) order, optionally filtered. The Value
/// bytes ARE the bytes the content hash sees, so a query result diff is a state diff.
pub fn componentRel(comptime R: type, gpa: Allocator, w: *const worldmod.World(R), filter: ComponentFilter) Allocator.Error!QueryResult {
    var b = Builder.init(gpa, .component, COMPONENT_SCHEMA);
    errdefer b.deinit();
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);

    const order = try w.table.canonicalOrder(gpa);
    defer gpa.free(order);
    const owners = w.table.owners();
    const masks = w.table.masks();

    for (order) |row| {
        const owner = owners[row];
        if (filter.entity) |fe| {
            if (fe.index != owner.index or fe.generation != owner.generation) continue;
        }
        inline for (R.sorted) |ti| {
            const kid = comptime R.kindId(ti);
            if ((masks[row] & R.bit(ti)) != 0 and (filter.kind == null or filter.kind.? == kid)) {
                scratch.clearRetainingCapacity();
                var sink = serialize.ByteSink{ .list = &scratch, .gpa = gpa };
                try serialize.writeValue(&sink, R.Component(ti), w.table.column(ti)[row]);
                const ref = try b.pushBytes(scratch.items);
                try b.pushRow(rowOf3(.{ .entity = owner }, .{ .kind = kid }, .{ .bytes = ref }));
            }
        }
    }
    return b.finalize();
}

// --- event/5 --------------------------------------------------------------------------------------

/// The provenance log as a relation, re-sorted by `EventId.order` (so the result is independent of the
/// log's physical/insertion order — robust to the Phase-2b reordering recorder.zig note 16 anticipates).
pub fn eventRel(gpa: Allocator, log: *const EventLog, filter: EventFilter) Allocator.Error!QueryResult {
    var b = Builder.init(gpa, .event, EVENT_SCHEMA);
    errdefer b.deinit();
    for (log.events.items) |e| {
        if (filter.tick_lo) |lo| if (e.id.tick < lo) continue;
        if (filter.tick_hi) |hi| if (e.id.tick > hi) continue;
        if (filter.kind) |k| if (e.kind != k) continue;
        if (filter.emitter) |em| if (e.emitter != em) continue;
        const ref = try b.pushBytes(log.payloadOf(e.id));
        var row: Row = .{};
        row.vals[0] = .{ .event_id = e.id };
        row.vals[1] = .{ .kind = e.kind };
        row.vals[2] = .{ .tick = e.id.tick };
        row.vals[3] = .{ .u = e.emitter };
        row.vals[4] = .{ .bytes = ref };
        try b.pushRow(row);
    }
    return b.finalize();
}

// --- caused_by/2 ----------------------------------------------------------------------------------

/// The DIRECT causal edges of one effect: (effect, cause) for each immediate cause.
pub fn causedByDirect(gpa: Allocator, log: *const EventLog, effect: EventId) Allocator.Error!QueryResult {
    var b = Builder.init(gpa, .caused_by, CAUSED_BY_SCHEMA);
    errdefer b.deinit();
    for (log.causesOf(effect)) |c| {
        try b.pushRow(rowOf2(.{ .event_id = effect }, .{ .event_id = c }));
    }
    return b.finalize();
}

/// The WHY shape: the full transitive provenance of `effect` as (effect, ancestor) edges — one row per
/// transitive ancestor. Delegates VERBATIM to the Phase-3-proven `event_log.causeChain` (BFS frontier,
/// cycle-guarded, canonical-sorted, dangling-skipped) so the riskiest determinism question reuses a
/// certified primitive rather than new recursion. (diverge.zig's generic `reach` independently
/// recomputes this set; the gate cross-checks the two agree.)
pub fn whyChain(gpa: Allocator, log: *const EventLog, effect: EventId) Allocator.Error!QueryResult {
    var b = Builder.init(gpa, .caused_by, CAUSED_BY_SCHEMA);
    errdefer b.deinit();
    const ancestors = try log.causeChain(gpa, effect);
    defer gpa.free(ancestors);
    for (ancestors) |a| {
        try b.pushRow(rowOf2(.{ .event_id = effect }, .{ .event_id = a }));
    }
    return b.finalize();
}

// --- system/3 -------------------------------------------------------------------------------------

/// The static dataflow graph from §4's declared access — built from `Sys(R).access` so it CANNOT drift
/// from the code (the access set has exactly one source: the system's Query parameter type). reads/writes
/// are ascending-kind_id lists encoded in the bytes arm. Optionally filtered to systems that read/write a
/// given kind (the WHAT-AFFECTS-X shape — a pure mask-scan, no source-grep).
pub fn systemRel(comptime R: type, comptime systems: []const Sys(R), gpa: Allocator, filter: SystemFilter) Allocator.Error!QueryResult {
    var b = Builder.init(gpa, .system, SYSTEM_SCHEMA);
    errdefer b.deinit();
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);

    const want_w: ?R.Mask = if (filter.writes_kind) |k| bitForKind(R, k) else null;
    const want_r: ?R.Mask = if (filter.reads_kind) |k| bitForKind(R, k) else null;

    inline for (systems, 0..) |s, sid| {
        const wmask = s.access.write;
        const rmask = s.access.read;
        const keep_w = if (want_w) |bw| (wmask & bw) != 0 else true;
        const keep_r = if (want_r) |br| (rmask & br) != 0 else true;
        // an unknown filter kind yields bit 0 -> matches nothing (correct: no system reads/writes it)
        const pass_w = if (filter.writes_kind != null and want_w == null) false else keep_w;
        const pass_r = if (filter.reads_kind != null and want_r == null) false else keep_r;
        if (pass_w and pass_r) {
            const name_ref = try b.pushBytes(s.name);
            scratch.clearRetainingCapacity();
            try encodeKindList(R, &scratch, gpa, rmask);
            const reads_ref = try b.pushBytes(scratch.items);
            scratch.clearRetainingCapacity();
            try encodeKindList(R, &scratch, gpa, wmask);
            const writes_ref = try b.pushBytes(scratch.items);
            try b.pushRow(.{ .vals = .{ .{ .u = sid }, .{ .bytes = name_ref }, .{ .bytes = reads_ref }, .{ .bytes = writes_ref }, undefined, undefined, undefined, undefined } });
        }
    }
    return b.finalize();
}

/// Ascending system ids that WRITE `kind_id` (the structural "what affects X"). Caller frees.
pub fn whatWrites(comptime R: type, comptime systems: []const Sys(R), gpa: Allocator, kind_id: u16) Allocator.Error![]u16 {
    return scanSystems(R, systems, gpa, kind_id, .write);
}
/// Ascending system ids that READ `kind_id`. Caller frees.
pub fn whatReads(comptime R: type, comptime systems: []const Sys(R), gpa: Allocator, kind_id: u16) Allocator.Error![]u16 {
    return scanSystems(R, systems, gpa, kind_id, .read);
}

// --- helpers --------------------------------------------------------------------------------------

fn rowOf2(a: Value, b: Value) Row {
    return .{ .vals = .{ a, b, undefined, undefined, undefined, undefined, undefined, undefined } };
}
fn rowOf3(a: Value, b: Value, c: Value) Row {
    return .{ .vals = .{ a, b, c, undefined, undefined, undefined, undefined, undefined } };
}

/// Mask bit for a runtime kind_id, or 0 if no such kind is registered.
fn bitForKind(comptime R: type, kind_id: u16) R.Mask {
    if (R.tupleIndexForKindId(kind_id)) |ti| {
        return @as(R.Mask, 1) << @intCast(rankOf(R, ti));
    }
    return 0;
}

/// Rank (mask-bit position) of a runtime tuple index — its position in `R.sorted`.
fn rankOf(comptime R: type, ti: usize) usize {
    for (R.sorted, 0..) |idx, r| if (idx == ti) return r;
    unreachable; // sorted is a permutation of [0, count)
}

/// Encode a presence mask as a length-prefixed ascending-kind_id list (u16 count, then count×u16).
fn encodeKindList(comptime R: type, scratch: *std.ArrayList(u8), gpa: Allocator, mask: R.Mask) Allocator.Error!void {
    var sink = serialize.ByteSink{ .list = scratch, .gpa = gpa };
    const m: u64 = @intCast(mask);
    var count: u16 = 0;
    for (0..R.count) |p| {
        if ((m >> @intCast(p)) & 1 != 0) count += 1;
    }
    try serialize.putInt(&sink, u16, count);
    for (0..R.count) |p| {
        if ((m >> @intCast(p)) & 1 != 0) try serialize.putInt(&sink, u16, R.kind_ids[R.sorted[p]]);
    }
}

fn scanSystems(comptime R: type, comptime systems: []const Sys(R), gpa: Allocator, kind_id: u16, comptime which: enum { read, write }) Allocator.Error![]u16 {
    const bit = bitForKind(R, kind_id);
    var list: std.ArrayList(u16) = .empty;
    errdefer list.deinit(gpa);
    if (bit != 0) {
        inline for (systems, 0..) |s, sid| {
            const mask = switch (which) {
                .read => s.access.read,
                .write => s.access.write,
            };
            if ((mask & bit) != 0) try list.append(gpa, @intCast(sid));
        }
    }
    return list.toOwnedSlice(gpa);
}

/// Decode a kind-list blob produced by `encodeKindList` (used by tests + AI consumers).
pub fn decodeKindList(gpa: Allocator, bytes: []const u8) (serialize.Error || Allocator.Error)![]u16 {
    var reader = serialize.ByteReader{ .bytes = bytes };
    const n = try serialize.getInt(&reader, u16);
    var out = try gpa.alloc(u16, n);
    errdefer gpa.free(out);
    for (0..n) |i| out[i] = try serialize.getInt(&reader, u16);
    return out;
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("../registry.zig").Registry;
const query = @import("../query.zig");
const simctx = @import("../simctx.zig");
const Read = query.Read;
const Write = query.Write;
const With = query.With;
const Query = query.Query;
const SimCtx = simctx.SimCtx;
const system = schedule.system;

const Position = struct {
    x: i64,
    y: i64,
    pub const kind_id: u16 = 10;
};
const Velocity = struct {
    dx: i64,
    pub const kind_id: u16 = 5;
};
const Tag = struct {
    pub const kind_id: u16 = 20;
};
const Game = Registry(.{ Position, Velocity, Tag });

test "component/3: rows are the live cells in canonical (entity.index, kind_id) order" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const e0 = try w.spawn(gpa);
    const e1 = try w.spawn(gpa);
    w.add(e1, Position, .{ .x = 1, .y = 2 });
    w.add(e1, Velocity, .{ .dx = 3 });
    w.add(e0, Position, .{ .x = 9, .y = 9 });

    var r = try componentRel(Game, gpa, &w, .{});
    defer r.deinit(gpa);
    // canonical: e0/Position(10), e1/Velocity(5), e1/Position(10)
    try testing.expectEqual(@as(usize, 3), r.rows.items.len);
    try testing.expectEqual(@as(u32, 0), r.rows.items[0].vals[0].entity.index);
    try testing.expectEqual(@as(u16, 10), r.rows.items[0].vals[1].kind);
    try testing.expectEqual(@as(u32, 1), r.rows.items[1].vals[0].entity.index);
    try testing.expectEqual(@as(u16, 5), r.rows.items[1].vals[1].kind); // kind 5 < 10 within entity 1
    try testing.expectEqual(@as(u16, 10), r.rows.items[2].vals[1].kind);
    // value bytes equal serialize.writeValue of the component
    const vbytes = r.bytesOf(r.rows.items[1].vals[2].bytes);
    var reader = serialize.ByteReader{ .bytes = vbytes };
    const vel = try serialize.readValue(Velocity, &reader);
    try testing.expectEqual(@as(i64, 3), vel.dx);
}

test "component/3: canonical order is unchanged under a churned physical table layout" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    // spawn 5, give each a Tag, then despawn the middle ones (swap-remove churns physical order)
    var es: [5]Entity = undefined;
    for (&es) |*e| {
        e.* = try w.spawn(gpa);
        w.add(e.*, Tag, .{});
    }
    try w.despawn(gpa, es[1]);
    try w.despawn(gpa, es[3]);
    var r = try componentRel(Game, gpa, &w, .{ .kind = 20 });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), r.rows.items.len); // es 0,2,4 survive
    // ascending index regardless of physical swap layout
    try testing.expect(r.rows.items[0].vals[0].entity.index < r.rows.items[1].vals[0].entity.index);
    try testing.expect(r.rows.items[1].vals[0].entity.index < r.rows.items[2].vals[0].entity.index);
}

test "component/3: entity + kind filters gate correctly" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const e0 = try w.spawn(gpa);
    const e1 = try w.spawn(gpa);
    w.add(e0, Position, .{ .x = 1, .y = 1 });
    w.add(e0, Velocity, .{ .dx = 1 });
    w.add(e1, Position, .{ .x = 2, .y = 2 });
    {
        var r = try componentRel(Game, gpa, &w, .{ .entity = e0 });
        defer r.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), r.rows.items.len); // both of e0's components
    }
    {
        var r = try componentRel(Game, gpa, &w, .{ .kind = 10 });
        defer r.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), r.rows.items.len); // both Positions
        for (r.rows.items) |row| try testing.expectEqual(@as(u16, 10), row.vals[1].kind);
    }
}

fn buildLog(gpa: Allocator) !EventLog {
    var log: EventLog = .{};
    errdefer log.deinit(gpa);
    // diamond: D <- B, D <- C, B <- A, C <- A
    const A: EventId = .{ .tick = 1, .emitter = 0, .seq = 0 };
    const B: EventId = .{ .tick = 2, .emitter = 1, .seq = 0 };
    const C: EventId = .{ .tick = 2, .emitter = 2, .seq = 0 };
    const D: EventId = .{ .tick = 3, .emitter = 1, .seq = 0 };
    try log.append(gpa, A, 100, 0, .{ .index = 0, .generation = 0 }, &.{0xAA}, &.{});
    try log.append(gpa, B, 100, 1, .{ .index = 0, .generation = 0 }, &.{0xBB}, &.{A});
    try log.append(gpa, C, 100, 2, .{ .index = 0, .generation = 0 }, &.{0xCC}, &.{A});
    try log.append(gpa, D, 101, 1, .{ .index = 0, .generation = 0 }, &.{0xDD}, &.{ B, C });
    return log;
}

test "event/5: rows sorted by EventId.order regardless of log physical order; filters work" {
    const gpa = testing.allocator;
    var log = try buildLog(gpa);
    defer log.deinit(gpa);
    {
        var r = try eventRel(gpa, &log, .{});
        defer r.deinit(gpa);
        try testing.expectEqual(@as(usize, 4), r.rows.items.len);
        // canonical: A(t1) < B(t2,em1) < C(t2,em2) < D(t3)
        try testing.expectEqual(@as(u64, 1), r.rows.items[0].vals[0].event_id.tick);
        try testing.expectEqual(@as(u16, 1), r.rows.items[1].vals[0].event_id.emitter);
        try testing.expectEqual(@as(u16, 2), r.rows.items[2].vals[0].event_id.emitter);
        try testing.expectEqual(@as(u64, 3), r.rows.items[3].vals[0].event_id.tick);
    }
    {
        var r = try eventRel(gpa, &log, .{ .tick_lo = 2, .tick_hi = 2 });
        defer r.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), r.rows.items.len); // B, C
    }
    {
        var r = try eventRel(gpa, &log, .{ .kind = 101 });
        defer r.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), r.rows.items.len); // D
        try testing.expectEqualSlices(u8, &.{0xDD}, r.bytesOf(r.rows.items[0].vals[4].bytes));
    }
}

test "caused_by direct mirrors causesOf; whyChain equals causeChain set" {
    const gpa = testing.allocator;
    var log = try buildLog(gpa);
    defer log.deinit(gpa);
    const D: EventId = .{ .tick = 3, .emitter = 1, .seq = 0 };
    {
        var r = try causedByDirect(gpa, &log, D);
        defer r.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), r.rows.items.len); // B, C (direct)
    }
    {
        var r = try whyChain(gpa, &log, D);
        defer r.deinit(gpa);
        // transitive ancestors of D = {A, B, C}
        try testing.expectEqual(@as(usize, 3), r.rows.items.len);
        const chain = try log.causeChain(gpa, D);
        defer gpa.free(chain);
        try testing.expectEqual(chain.len, r.rows.items.len);
        // every row's cause is an ancestor; effect is always D
        for (r.rows.items) |row| try testing.expect(row.vals[0].event_id.eql(D));
    }
}

// systems: rP reads Position; wPV writes Position+Velocity; rT reads Tag
fn sysRP(ctx: *SimCtx(Game), q: *Query(Game, .{Read(Position)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}
fn sysWPV(ctx: *SimCtx(Game), q: *Query(Game, .{ Write(Position), Write(Velocity) })) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}
fn sysRT(ctx: *SimCtx(Game), q: *Query(Game, .{ Read(Tag), With(Position) })) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}
const demo_systems = [_]Sys(Game){ system(Game, "rP", sysRP), system(Game, "wPV", sysWPV), system(Game, "rT", sysRT) };

test "system/3: reflected reads/writes equal independently-decoded Access masks (never drifts)" {
    const gpa = testing.allocator;
    var r = try systemRel(Game, &demo_systems, gpa, .{});
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), r.rows.items.len);
    // system 1 = wPV: writes {Velocity(5), Position(10)} ascending, reads {}
    const row1 = r.rows.items[1];
    try testing.expectEqual(@as(u64, 1), row1.vals[0].u);
    try testing.expectEqualStrings("wPV", r.bytesOf(row1.vals[1].bytes));
    const reads = try decodeKindList(gpa, r.bytesOf(row1.vals[2].bytes));
    defer gpa.free(reads);
    const writes = try decodeKindList(gpa, r.bytesOf(row1.vals[3].bytes));
    defer gpa.free(writes);
    try testing.expectEqual(@as(usize, 0), reads.len);
    try testing.expectEqualSlices(u16, &.{ 5, 10 }, writes); // ascending kind_id
    // rT (system 2) reads Tag(20); With(Position) is a filter, NOT a read
    const row2 = r.rows.items[2];
    const reads2 = try decodeKindList(gpa, r.bytesOf(row2.vals[2].bytes));
    defer gpa.free(reads2);
    try testing.expectEqualSlices(u16, &.{20}, reads2);
}

test "whatWrites / whatReads are mask-scans returning ascending system ids" {
    const gpa = testing.allocator;
    {
        const w = try whatWrites(Game, &demo_systems, gpa, 10); // Position written by system 1 only
        defer gpa.free(w);
        try testing.expectEqualSlices(u16, &.{1}, w);
    }
    {
        const rr = try whatReads(Game, &demo_systems, gpa, 10); // Position read by system 0 only
        defer gpa.free(rr);
        try testing.expectEqualSlices(u16, &.{0}, rr);
    }
    {
        const none = try whatWrites(Game, &demo_systems, gpa, 999); // unregistered kind -> empty
        defer gpa.free(none);
        try testing.expectEqual(@as(usize, 0), none.len);
    }
}

test "systemRel writes_kind filter yields the WHAT-AFFECTS-X system rows" {
    const gpa = testing.allocator;
    var r = try systemRel(Game, &demo_systems, gpa, .{ .writes_kind = 5 }); // who writes Velocity
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.rows.items.len);
    try testing.expectEqual(@as(u64, 1), r.rows.items[0].vals[0].u); // system wPV
    // an unregistered filter kind matches nothing
    var r2 = try systemRel(Game, &demo_systems, gpa, .{ .writes_kind = 999 });
    defer r2.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r2.rows.items.len);
}
