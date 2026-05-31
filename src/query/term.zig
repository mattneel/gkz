//! The uniform Datalog-ish term substrate for the §7 query surface (PLAN.md Phase 5, build-order step 1).
//!
//! Every relation row is a tuple of `Value`s drawn from ONE closed tag space — so an AI consumer parses
//! all five §7 relations (and the self-describing catalog) the same way, and re-feeds a result row as a
//! query input. The space is deliberately a CLOSED set of serializable leaves: integers, bool, the
//! generational `Entity` handle, a `u16` component-kind id, the structural `EventId`, a tick, and an
//! arena-offset byte handle. There is NO float arm (D7) and NO pointer arm (D8) — the `bytes` arm is a
//! `{off,len}` slice into the owning result's byte arena, never a live pointer — so a `Value` is always
//! canonically serializable by the existing `serialize.writeValue` discipline and order is a pure
//! function of content, never of memory layout (D5/D9).
//!
//! `order`/`tupleOrder` take the arena so the `bytes` arm orders by CONTENT (lexicographic), making the
//! canonical row order — and thus the pinned result digest — independent of where bytes happen to land
//! in the arena. (No relation uses a `bytes` column as its distinguishing sort key, so this only
//! decides true-duplicate equality; content ordering keeps that correct and layout-independent.)

const std = @import("std");
const entity = @import("../entity.zig");
const Entity = entity.Entity;
const eventmod = @import("../event.zig");
const EventId = eventmod.EventId;
const serialize = @import("../serialize.zig");

/// Maximum relation arity. `event/5` is the widest built-in relation; the headroom covers the catalog
/// and near-term additions. A wider future relation is a one-line bump that changes no existing result
/// bytes (a `Schema` carries explicit `arity`; columns past `arity` are never serialized).
pub const MAX_ARITY: usize = 8;

/// A slice into the owning `QueryResult`'s byte arena — pointer-free, so a `Row` stays POD/serializable.
pub const BytesRef = struct { off: u32, len: u32 };

/// The closed tag set (explicit `u8` so it is wire-stable and reflectable by the catalog).
pub const TermTag = enum(u8) {
    u, // a generic unsigned id/count (system id, relation id, arity, column index)
    i, // a generic signed integer
    bool_,
    entity, // a generational entity handle
    kind, // a u16 component kind_id
    event_id, // a structural EventId {tick, emitter, seq}
    tick, // a u64 tick number
    bytes, // canonical-LE bytes in the result arena (a serialized value or a UTF-8 name)
};

/// Validate an on-wire tag byte into a `TermTag`, or null if it names no tag. (`std.meta.intToEnum` was
/// removed in 0.16; we validate exhaustively so a corrupt frame is a returned error, not UB — D2.)
pub fn tagFromInt(raw: u8) ?TermTag {
    inline for (@typeInfo(TermTag).@"enum".fields) |f| {
        if (f.value == raw) return @enumFromInt(raw);
    }
    return null;
}

/// A single relation cell. The tag is carried explicitly (`union(TermTag)`) so `std.meta.activeTag`
/// and the catalog can name each column's type.
pub const Value = union(TermTag) {
    u: u64,
    i: i64,
    bool_: bool,
    entity: Entity,
    kind: u16,
    event_id: EventId,
    tick: u64,
    bytes: BytesRef,

    /// Total order over ALL arms: tag byte first (so a `u` and an `entity` with equal numeric payloads
    /// order by tag and never compare-equal), then the leaf. `arena` resolves the `bytes` arm's content.
    pub fn order(a: Value, b: Value, arena: []const u8) std.math.Order {
        const ta = @intFromEnum(std.meta.activeTag(a));
        const tb = @intFromEnum(std.meta.activeTag(b));
        if (ta != tb) return std.math.order(ta, tb);
        return switch (a) {
            .u => |x| std.math.order(x, b.u),
            .i => |x| std.math.order(x, b.i),
            .bool_ => |x| std.math.order(@intFromBool(x), @intFromBool(b.bool_)),
            .entity => |x| switch (std.math.order(x.index, b.entity.index)) {
                .eq => std.math.order(x.generation, b.entity.generation),
                else => |o| o,
            },
            .kind => |x| std.math.order(x, b.kind),
            .event_id => |x| x.order(b.event_id),
            .tick => |x| std.math.order(x, b.tick),
            .bytes => |x| std.mem.order(u8, arena[x.off..][0..x.len], arena[b.bytes.off..][0..b.bytes.len]),
        };
    }

    comptime {
        // Structural D7/D8 guarantee: every arm's payload is canonically serializable (serializedSizeOf
        // @compileErrors on a float or pointer), so no `Value` can ever carry non-deterministic state.
        for (@typeInfo(Value).@"union".fields) |f| {
            _ = serialize.serializedSizeOf(f.type);
        }
    }
};

/// A relation's column schema: arity plus, per column, its term tag and a human/AI-readable name. The
/// names make a result self-describing alongside the `relation_column` catalog relation.
pub const Schema = struct {
    arity: u8,
    cols: [MAX_ARITY]TermTag = undefined,
    names: [MAX_ARITY][]const u8 = undefined,

    /// Build a Schema from a comptime list of (name, tag) pairs (`arity` derived from the list length).
    pub fn make(comptime pairs: []const struct { []const u8, TermTag }) Schema {
        if (pairs.len > MAX_ARITY) @compileError("relation arity exceeds MAX_ARITY");
        var s: Schema = .{ .arity = @intCast(pairs.len) };
        for (pairs, 0..) |p, idx| {
            s.cols[idx] = p[1];
            s.names[idx] = p[0];
        }
        return s;
    }
};

/// One relation tuple: a fixed-arity array of cells. Only the first `Schema.arity` cells are meaningful.
pub const Row = struct {
    vals: [MAX_ARITY]Value = undefined,

    /// Lexicographic order over the first `arity` columns — the single D9 canonical sort key for rows.
    pub fn tupleOrder(a: Row, b: Row, arity: u8, arena: []const u8) std.math.Order {
        var i: usize = 0;
        while (i < arity) : (i += 1) {
            switch (Value.order(a.vals[i], b.vals[i], arena)) {
                .eq => {},
                else => |o| return o,
            }
        }
        return .eq;
    }

    pub fn eql(a: Row, b: Row, arity: u8, arena: []const u8) bool {
        return a.tupleOrder(b, arity, arena) == .eq;
    }
};

/// The five §7 relations plus the two self-describing catalog relations. `enum(u16)` with a trailing `_`
/// so a future-phase relation is an additive variant, never a renumber.
pub const RelId = enum(u16) {
    component,
    event,
    caused_by,
    system,
    diverge,
    relation_schema,
    relation_column,
    // §8 (Phase 6) relations — appended before `_` so the §7 relations never renumber (their GKZR1
    // digests are unchanged); the catalog relations grow to list these, which is expected.
    spec,
    violation,
    _,
};

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "Value.order is tag-first then leaf, and never equates across tags" {
    const arena: []const u8 = &.{};
    // same numeric payload, different tag -> ordered by tag, never .eq
    try testing.expectEqual(std.math.Order.lt, Value.order(.{ .u = 5 }, .{ .entity = .{ .index = 5, .generation = 0 } }, arena));
    try testing.expectEqual(std.math.Order.gt, Value.order(.{ .tick = 0 }, .{ .kind = 0 }, arena)); // tick(tag6) > kind(tag4)
    // within a tag, leaf order
    try testing.expectEqual(std.math.Order.lt, Value.order(.{ .u = 3 }, .{ .u = 4 }, arena));
    try testing.expectEqual(std.math.Order.eq, Value.order(.{ .u = 7 }, .{ .u = 7 }, arena));
    try testing.expectEqual(std.math.Order.gt, Value.order(.{ .i = 1 }, .{ .i = -1 }, arena));
    try testing.expectEqual(std.math.Order.lt, Value.order(.{ .bool_ = false }, .{ .bool_ = true }, arena));
}

test "Value.order leaf correctness: entity by (index,generation), event_id by EventId.order" {
    const arena: []const u8 = &.{};
    // entity: index dominates, generation breaks ties
    try testing.expectEqual(std.math.Order.lt, Value.order(.{ .entity = .{ .index = 1, .generation = 9 } }, .{ .entity = .{ .index = 2, .generation = 0 } }, arena));
    try testing.expectEqual(std.math.Order.eq, Value.order(.{ .entity = .{ .index = 2, .generation = 0 } }, .{ .entity = .{ .index = 2, .generation = 0 } }, arena));
    try testing.expectEqual(std.math.Order.lt, Value.order(.{ .entity = .{ .index = 2, .generation = 0 } }, .{ .entity = .{ .index = 2, .generation = 2 } }, arena)); // generation breaks the index tie
    // event_id: lexicographic (tick, emitter, seq)
    const ea = Value{ .event_id = .{ .tick = 1, .emitter = 0, .seq = 5 } };
    const eb = Value{ .event_id = .{ .tick = 1, .emitter = 1, .seq = 0 } };
    try testing.expectEqual(std.math.Order.lt, Value.order(ea, eb, arena));
}

test "Value.order bytes arm is lexicographic over arena content (layout-independent)" {
    // the same logical bytes stored at different offsets must order identically
    const arena = "ABCAB\x00ABD"; // [0..3)="ABC" [3..5)="AB" [6..9)="ABD"
    const abc = Value{ .bytes = .{ .off = 0, .len = 3 } };
    const ab = Value{ .bytes = .{ .off = 3, .len = 2 } };
    const abd = Value{ .bytes = .{ .off = 6, .len = 3 } };
    try testing.expectEqual(std.math.Order.gt, Value.order(abc, ab, arena)); // "ABC" > "AB" (prefix, longer)
    try testing.expectEqual(std.math.Order.lt, Value.order(abc, abd, arena)); // "ABC" < "ABD"
    // content equality regardless of offset
    const abc2 = "xxABC";
    try testing.expectEqual(std.math.Order.eq, std.mem.order(u8, arena[0..3], abc2[2..5]));
}

test "Row.tupleOrder is lexicographic over the first `arity` columns and total" {
    const arena: []const u8 = &.{};
    const a = Row{ .vals = .{ .{ .u = 1 }, .{ .kind = 5 }, undefined, undefined, undefined, undefined, undefined, undefined } };
    const b = Row{ .vals = .{ .{ .u = 1 }, .{ .kind = 6 }, undefined, undefined, undefined, undefined, undefined, undefined } };
    const c = Row{ .vals = .{ .{ .u = 2 }, .{ .kind = 0 }, undefined, undefined, undefined, undefined, undefined, undefined } };
    try testing.expectEqual(std.math.Order.lt, a.tupleOrder(b, 2, arena)); // tie on col0, col1 5<6
    try testing.expectEqual(std.math.Order.lt, a.tupleOrder(c, 2, arena)); // col0 1<2 dominates
    try testing.expectEqual(std.math.Order.eq, a.tupleOrder(a, 2, arena));
    // arity 1 ignores the differing col1
    try testing.expectEqual(std.math.Order.eq, a.tupleOrder(b, 1, arena));
}

test "Schema.make derives arity and records per-column tag + name" {
    const s = Schema.make(&.{ .{ "entity", .entity }, .{ "kind", .kind }, .{ "value", .bytes } });
    try testing.expectEqual(@as(u8, 3), s.arity);
    try testing.expectEqual(TermTag.entity, s.cols[0]);
    try testing.expectEqual(TermTag.bytes, s.cols[2]);
    try testing.expectEqualStrings("kind", s.names[1]);
}

test "every Value arm payload is canonically serializable (the comptime D7/D8 guarantee holds at runtime too)" {
    // BytesRef and the scalar arms all have a defined serialized size (no float/pointer arm exists).
    try testing.expectEqual(@as(usize, 8), serialize.serializedSizeOf(BytesRef));
    try testing.expectEqual(@as(usize, 8), serialize.serializedSizeOf(Entity));
    try testing.expectEqual(@as(usize, 14), serialize.serializedSizeOf(EventId));
}
