//! SimCtx — the restricted capability surface handed to each system (SPEC §4/§5, PLAN.md Phase 2/3).
//!
//! A system reaches, and only reaches, through its `*SimCtx(R)`:
//!   1. `tick` — read-only metadata.
//!   2. keyed RNG — `rng`/`rngFixed`, pure in (seed, tick, entity, stream); no cursor (D4).
//!   3. the command buffer — `cmd.spawn/.despawn/.add/.set/.remove`, the only structural / cross-entity
//!      mutation path (deferred to the end-of-tick drain).
//!   4. the event emitter (SPEC §5) — `emit`/`emitS` record provenance into a side log; a no-op when
//!      recording is off. Events are PURE SIDE-OUTPUT: emitting never perturbs the hashed World.
//!
//! Structurally ABSENT (D3): no `*World`, no allocator (the recorder/command-buffer hold their own
//! privately), no clock, no OS RNG, no syscalls.
//!
//! THE PHASE-3 DETERMINISM INVARIANT: `emit` advances `emit_ordinal` UNCONDITIONALLY — identically
//! whether the emitter is `.noop` or `.recording`. `causeTokenHere()` reads only (tick, system_id,
//! emit_ordinal), never the recorder, so a `CauseToken` a system mints and stores in a component is
//! byte-identical events-on vs events-off. That is what keeps cross-tick causality hash-safe. The
//! events-OFF == events-ON gate in replay.zig guards this invariant permanently.

const std = @import("std");
const fpz = @import("fpz");
const rngmod = @import("rng.zig");
const cmdbuf = @import("command_buffer.zig");
const event = @import("event.zig");
const recorder = @import("recorder.zig");
const Fixed = fpz.Fixed;
const RngRoot = rngmod.RngRoot;
const Entity = @import("entity.zig").Entity;
const EventId = event.EventId;
const CauseToken = event.CauseToken;

/// The event sink. `.noop` (the throughput default) discards everything in O(1) and returns
/// `EventId.NONE`; `.recording` forwards to a Recorder owning the side log.
pub const EventEmitter = union(enum) {
    noop,
    recording: *recorder.Recorder,

    pub fn record(
        self: *EventEmitter,
        comptime E: type,
        tick: u64,
        system_id: u16,
        seq: u32,
        subject: Entity,
        value: E,
        extra: []const EventId,
    ) std.mem.Allocator.Error!EventId {
        return switch (self.*) {
            .noop => EventId.NONE,
            .recording => |rec| rec.record(E, tick, system_id, seq, subject, value, extra),
        };
    }
};

pub fn SimCtx(comptime R: type) type {
    return struct {
        const Self = @This();

        tick: u64,
        rng_root: RngRoot,
        system_id: u16,
        cmd: *cmdbuf.CommandBuffer(R),
        events: *EventEmitter,
        /// Per-invocation emit counter; the seq of the next emitted event. Advanced by every `emit`
        /// regardless of the emitter arm (the Phase-3 hash-safety invariant).
        emit_ordinal: u32 = 0,

        /// A keyed RNG draw — pure in (tick, entity_id, stream_id); no cursor. The key is exactly
        /// (seed, tick, entity_id, stream_id) per SPEC §2.4; `stream_id` is the cross-system isolation
        /// knob (two systems sharing (entity, stream) intentionally share a draw).
        pub fn rng(self: *const Self, entity_id: u32, stream_id: u32) u64 {
            return rngmod.draw(self.rng_root, self.tick, entity_id, stream_id);
        }
        pub fn rngFixed(self: *const Self, entity_id: u32, stream_id: u32, lo: Fixed, hi: Fixed) Fixed {
            return rngmod.drawFixed(self.rng_root, self.tick, entity_id, stream_id, lo, hi);
        }

        /// Record a provenance event about `subject`, with explicit additional `causes` (ids this
        /// invocation already holds). The recorder auto-attributes the enclosing SystemCause node as
        /// the first cause. Returns the new EventId (`EventId.NONE` when recording is off). Advances
        /// `emit_ordinal` either way.
        pub fn emit(self: *Self, comptime E: type, subject: Entity, value: E, causes: []const EventId) std.mem.Allocator.Error!EventId {
            const seq = self.emit_ordinal;
            self.emit_ordinal +%= 1; // UNCONDITIONAL advance (the invariant) — both arms
            return self.events.record(E, self.tick, self.system_id, seq, subject, value, causes);
        }
        pub fn emitS(self: *Self, comptime E: type, subject: Entity, value: E) std.mem.Allocator.Error!EventId {
            return self.emit(E, subject, value, &.{});
        }

        /// Mint a hash-safe token naming the event the NEXT `emit` will produce. Pure in (tick,
        /// system_id, emit_ordinal) — identical events-on vs events-off — so it may be stored in a
        /// component to thread causality across ticks. Usage: mint, then emit the event it names.
        pub fn causeTokenHere(self: *const Self) CauseToken {
            return .{ .tick = self.tick, .emitter = self.system_id, .seq = self.emit_ordinal };
        }
        /// Resolve a stored token back to the EventId it names (pure; no log access).
        pub fn causeFromToken(_: *const Self, t: CauseToken) EventId {
            return event.idOfToken(t);
        }
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("registry.zig").Registry;

const Tag = struct {
    v: u8,
    pub const kind_id: u16 = 1;
};
const Reg = Registry(.{Tag});

const Hit = struct {
    amount: i32,
    pub const kind_id: u16 = 100;
};

fn ent(i: u32) Entity {
    return .{ .index = i, .generation = 0 };
}

test "rng / rngFixed match the bare keyed draw (pinned to rng.zig's frozen vectors)" {
    const gpa = testing.allocator;
    var buf = cmdbuf.CommandBuffer(Reg).init(gpa, 0);
    defer buf.deinit();
    var ev: EventEmitter = .noop;
    var ctx = SimCtx(Reg){ .tick = 0, .rng_root = .{ .seed = 0 }, .system_id = 0, .cmd = &buf, .events = &ev };

    try testing.expectEqual(@as(u64, 0x1957_a760_4e21_5178), ctx.rng(0, 0));
    try testing.expectEqual(rngmod.draw(.{ .seed = 0 }, 0, 3, 1), ctx.rng(3, 1));
}

test "SimCtx exposes only the restricted capability surface (no World/allocator/clock)" {
    const S = SimCtx(Reg);
    inline for (.{ "tick", "rng_root", "system_id", "cmd", "events", "emit_ordinal" }) |f| {
        try testing.expect(@hasField(S, f));
    }
    inline for (.{ "world", "table", "gpa", "allocator", "clock", "time" }) |f| {
        try testing.expect(!@hasField(S, f));
    }
    try testing.expectEqual(@as(usize, 6), @typeInfo(S).@"struct".fields.len);
}

test "causeTokenHere is identical events-OFF vs events-ON, and emit advances the ordinal either way" {
    const gpa = testing.allocator;

    var buf_a = cmdbuf.CommandBuffer(Reg).init(gpa, 4);
    defer buf_a.deinit();
    var noop: EventEmitter = .noop;
    var a = SimCtx(Reg){ .tick = 9, .rng_root = .{ .seed = 0 }, .system_id = 4, .cmd = &buf_a, .events = &noop };

    var rec = recorder.Recorder.init(gpa);
    defer rec.deinit();
    var buf_b = cmdbuf.CommandBuffer(Reg).init(gpa, 4);
    defer buf_b.deinit();
    var recemit: EventEmitter = .{ .recording = &rec };
    var b = SimCtx(Reg){ .tick = 9, .rng_root = .{ .seed = 0 }, .system_id = 4, .cmd = &buf_b, .events = &recemit };

    // before any emit: identical tokens
    try testing.expectEqual(a.causeTokenHere(), b.causeTokenHere());
    try testing.expectEqual(CauseToken{ .tick = 9, .emitter = 4, .seq = 0 }, a.causeTokenHere());

    const ida = try a.emitS(Hit, ent(0), .{ .amount = 1 });
    const idb = try b.emitS(Hit, ent(0), .{ .amount = 1 });
    try testing.expect(ida.isNone()); // noop returned NONE
    try testing.expect(idb.eql(.{ .tick = 9, .emitter = 4, .seq = 0 })); // recording returned the real id

    // ordinal advanced identically, so the next token is STILL identical across arms
    try testing.expectEqual(@as(u32, 1), a.emit_ordinal);
    try testing.expectEqual(@as(u32, 1), b.emit_ordinal);
    try testing.expectEqual(a.causeTokenHere(), b.causeTokenHere());
    // the recording side logged the event (+ its SystemCause node)
    try testing.expectEqual(@as(usize, 2), rec.log.count());
}

test "the noop emitter advances the ordinal but records nothing" {
    const gpa = testing.allocator;
    var buf = cmdbuf.CommandBuffer(Reg).init(gpa, 0);
    defer buf.deinit();
    var noop: EventEmitter = .noop;
    var ctx = SimCtx(Reg){ .tick = 0, .rng_root = .{ .seed = 0 }, .system_id = 0, .cmd = &buf, .events = &noop };
    _ = try ctx.emitS(Hit, ent(0), .{ .amount = 1 });
    _ = try ctx.emit(Hit, ent(0), .{ .amount = 2 }, &.{});
    try testing.expectEqual(@as(u32, 2), ctx.emit_ordinal); // ordinal advanced both times
    try testing.expect(std.meta.activeTag(noop) == .noop); // still a no-op; no recorder, nothing recorded
}
