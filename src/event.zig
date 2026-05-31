//! Event value types (SPEC §5, PLAN.md Phase 3). Build-order step 1.
//!
//! Events are the provenance channel — pure side-output recorded alongside state, never input to the
//! sim (the iron constraint: nothing event-derived may reach hashed World state). These are the value
//! types; the log, recorder, and emitter live in event_log.zig / recorder.zig / simctx.zig, all of
//! which sit ABOVE the hashed core (world/storage/serialize/hash never import them).
//!
//! `EventId` is STRUCTURAL — `{tick, emitter, seq}` — not a global counter, so re-running a tick in
//! isolation (the tiered §2.6 provenance re-run) reconstructs identical ids without replaying earlier
//! ticks to advance a counter, and a cause can name a node by address without observing a return value.
//!
//! `CauseToken` is byte-identical to `EventId` but a DISTINCT, component-storable type. An `EventId`
//! carries the `__no_component_store` marker so `registry.assertSerializable` rejects it: storing a
//! recorder-returned `EventId` in a (hashed) component is a compile error, because that id is `NONE`
//! when events are off and a real id when they're on — storing it would diverge the hash. A
//! `CauseToken`, minted from `(tick, system_id, emit_ordinal)` which evolve identically on/off, is the
//! only event-naming value that may live in state.

const std = @import("std");
const entity = @import("entity.zig");
const Entity = entity.Entity;

/// Reserved `emitter` values for synthetic cause nodes (they shrink the real system-id space by 2,
/// plus `NONE`'s sentinel — a documented ceiling well above the Phase-1 ≤64-kind/system bound).
pub const RESERVED_INPUT: u16 = std.math.maxInt(u16) - 1; // input-command root nodes (future)
pub const RESERVED_SYSACT: u16 = std.math.maxInt(u16) - 2; // per-(tick, system) activation nodes

/// A structural event identity. Deterministic within a provenance run; NEVER stored in hashed state.
pub const EventId = struct {
    tick: u64,
    emitter: u16,
    seq: u32,

    /// Marker read by `registry.assertSerializable` to forbid storing an `EventId` in a component.
    pub const __no_component_store = {};

    /// The "no event" sentinel returned by the no-op emitter (distinct from any real id).
    pub const NONE: EventId = .{ .tick = std.math.maxInt(u64), .emitter = std.math.maxInt(u16), .seq = std.math.maxInt(u32) };

    pub fn eql(a: EventId, b: EventId) bool {
        return a.tick == b.tick and a.emitter == b.emitter and a.seq == b.seq;
    }
    pub fn isNone(a: EventId) bool {
        return a.eql(NONE);
    }
    /// Total lexicographic order over (tick, emitter, seq) — the canonical ordering for query output.
    pub fn order(a: EventId, b: EventId) std.math.Order {
        if (a.tick != b.tick) return std.math.order(a.tick, b.tick);
        if (a.emitter != b.emitter) return std.math.order(a.emitter, b.emitter);
        return std.math.order(a.seq, b.seq);
    }
    pub fn lessThan(_: void, a: EventId, b: EventId) bool {
        return a.order(b) == .lt;
    }
};

/// A hash-safe, component-storable handle that names an event by its structural address. Distinct type
/// from `EventId` (no `__no_component_store` marker) so it — and only it — may live in a component.
pub const CauseToken = struct {
    tick: u64,
    emitter: u16,
    seq: u32,
};

/// Reinterpret a token as the event id it names (pure; no log access).
pub fn idOfToken(t: CauseToken) EventId {
    return .{ .tick = t.tick, .emitter = t.emitter, .seq = t.seq };
}

/// A recorded event. Payload bytes and cause edges live OUT OF LINE in the EventLog's arenas (sliced
/// by the offsets), so causal fan-in is unbounded and the on-wire layout never changes with it.
pub const Event = struct {
    id: EventId,
    kind: u16,
    emitter: u16,
    subject: Entity,
    payload_off: u32,
    payload_len: u16,
    cause_off: u32,
    cause_len: u32,
};

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const serialize = @import("serialize.zig");

test "EventId order is a total lexicographic order over (tick, emitter, seq)" {
    const a: EventId = .{ .tick = 1, .emitter = 2, .seq = 3 };
    const b: EventId = .{ .tick = 1, .emitter = 2, .seq = 4 };
    const c: EventId = .{ .tick = 1, .emitter = 3, .seq = 0 };
    const d: EventId = .{ .tick = 2, .emitter = 0, .seq = 0 };
    try testing.expect(a.order(b) == .lt);
    try testing.expect(b.order(c) == .lt);
    try testing.expect(c.order(d) == .lt);
    try testing.expect(a.order(a) == .eq);
    try testing.expect(d.order(a) == .gt);
}

test "NONE is distinct and idOfToken is a faithful reinterpretation" {
    try testing.expect(EventId.NONE.isNone());
    try testing.expect(!(EventId{ .tick = 0, .emitter = 0, .seq = 0 }).isNone());
    const tok: CauseToken = .{ .tick = 7, .emitter = 3, .seq = 9 };
    try testing.expect(idOfToken(tok).eql(.{ .tick = 7, .emitter = 3, .seq = 9 }));
    // distinct types: CauseToken and EventId are not assignable to each other (nominal typing)
    try testing.expect(CauseToken != EventId);
}

test "EventId serializes field-by-field as 14 bytes (codec works even though it is not component-storable)" {
    // The log codec serializes EventId; only the component registry forbids it. Confirm both facts.
    try testing.expectEqual(@as(usize, 14), serialize.serializedSizeOf(EventId)); // u64+u16+u32, padding excluded
    try testing.expect(@sizeOf(EventId) >= 14); // in-memory may pad to 16; the codec uses 14

    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    const id: EventId = .{ .tick = 0xAABBCCDD, .emitter = 0x1122, .seq = 0x99887766 };
    try serialize.writeValue(&sink, EventId, id);
    try testing.expectEqual(@as(usize, 14), buf.items.len);
    var rd = serialize.ByteReader{ .bytes = buf.items };
    try testing.expect((try serialize.readValue(EventId, &rd)).eql(id));

    try testing.expect(@hasDecl(EventId, "__no_component_store"));
    try testing.expect(!@hasDecl(CauseToken, "__no_component_store"));
}
