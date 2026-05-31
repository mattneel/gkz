//! The Recorder — owns the event log + the cause-context (SPEC §5, PLAN.md Phase 3). Build step 4.
//!
//! Minted by the RUN driver (replay/VOPR), NEVER by the World; holds its own private allocator (like
//! CommandBuffer) so SimCtx never gains an allocator. When recording is on, each `record` assigns the
//! structural EventId `{tick, system_id, seq}` (seq is the SimCtx emit-ordinal — see simctx.zig),
//! encodes the payload via the existing field-by-field codec, and appends the event plus its causes.
//!
//! Auto-attribution (the grafted kernel cause-context): every event's first cause is the per-(tick,
//! system) `SystemCause` node, lazily materialized on the system's first emit. Because runScheduled
//! runs each system's whole invocation before the next, `record` calls for a given (tick, system) are
//! contiguous, so a single `cur_sa` "is this a new (tick,system)?" check dedupes the synthetic node
//! deterministically. Explicit `extra` causes (same-invocation ids, cross-tick CauseToken-derived ids)
//! are appended after.
//!
//! DEFERRED (PLAN.md §7 #15/#16): SystemCause nodes are *roots* — input-command provenance (the bottom
//! of SPEC §5's chain) is not yet represented, because the Phase-2 input path applies commands without
//! an emitter. And the log's physical order equals system execution order (canonical only under
//! single-threaded execution); Phase 2b parallel within-stage execution must record into per-system
//! sub-logs merged deterministically (and rework this single-slot `cur_sa` dedup) before the log digest
//! is order-stable under threads.

const std = @import("std");
const event = @import("event.zig");
const event_log = @import("event_log.zig");
const serialize = @import("serialize.zig");
const entity = @import("entity.zig");
const EventId = event.EventId;
const Entity = entity.Entity;
const Allocator = std.mem.Allocator;

const ZERO_ENTITY: Entity = .{ .index = 0, .generation = 0 };

pub const Recorder = struct {
    gpa: Allocator, // PRIVATE; never surfaced on SimCtx
    log: event_log.EventLog = .{},
    cur_sa: ?EventId = null, // last materialized SystemCause node (dedup; relies on contiguous records)
    scratch_bytes: std.ArrayList(u8) = .empty,
    scratch_causes: std.ArrayList(EventId) = .empty,

    pub fn init(gpa: Allocator) Recorder {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Recorder) void {
        self.log.deinit(self.gpa);
        self.scratch_bytes.deinit(self.gpa);
        self.scratch_causes.deinit(self.gpa);
        self.* = undefined;
    }

    /// Record an event of type `E` (which must declare `pub const kind_id: u16`). Returns its EventId.
    pub fn record(
        self: *Recorder,
        comptime E: type,
        tick: u64,
        system_id: u16,
        seq: u32,
        subject: Entity,
        value: E,
        extra: []const EventId,
    ) Allocator.Error!EventId {
        // `EventLog.Event.payload_len` is a u16, so the widest serialized event payload must fit — a
        // comptime resource ceiling (a >64KB-serialized event type is a compile error), matching the
        // command-buffer treatment. Without this, the `@intCast` to u16 in EventLog.append would panic
        // in Debug/ReleaseSafe and silently truncate in ReleaseFast — a D2 build-mode divergence in the
        // recorded log.
        comptime std.debug.assert(serialize.serializedSizeOf(E) <= std.math.maxInt(u16));

        // Lazily materialize the per-(tick, system) SystemCause node (the auto-attributed parent).
        const sa: EventId = .{ .tick = tick, .emitter = event.RESERVED_SYSACT, .seq = @as(u32, system_id) };
        if (self.cur_sa == null or !self.cur_sa.?.eql(sa)) {
            try self.log.append(self.gpa, sa, 0, event.RESERVED_SYSACT, ZERO_ENTITY, "", &.{});
            self.cur_sa = sa;
        }

        // Encode the payload into the reusable scratch buffer.
        self.scratch_bytes.clearRetainingCapacity();
        var sink = serialize.ByteSink{ .list = &self.scratch_bytes, .gpa = self.gpa };
        try serialize.writeValue(&sink, E, value);

        // causes = [SystemCause] ++ explicit extra
        self.scratch_causes.clearRetainingCapacity();
        try self.scratch_causes.append(self.gpa, sa);
        try self.scratch_causes.appendSlice(self.gpa, extra);

        const id: EventId = .{ .tick = tick, .emitter = system_id, .seq = seq };
        try self.log.append(self.gpa, id, E.kind_id, system_id, subject, self.scratch_bytes.items, self.scratch_causes.items);
        return id;
    }
};

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

const Hit = struct {
    target: Entity,
    amount: i32,
    pub const kind_id: u16 = 100;
};

fn ent(i: u32) Entity {
    return .{ .index = i, .generation = 0 };
}

test "record assigns the structural id, auto-attributes the SystemCause node, encodes the payload" {
    const gpa = testing.allocator;
    var rec = Recorder.init(gpa);
    defer rec.deinit();

    const id = try rec.record(Hit, 7, 3, 0, ent(1), .{ .target = ent(2), .amount = 5 }, &.{});
    try testing.expect(id.eql(.{ .tick = 7, .emitter = 3, .seq = 0 }));

    // log holds the SystemCause node + the event
    try testing.expectEqual(@as(usize, 2), rec.log.count());
    const sa: EventId = .{ .tick = 7, .emitter = event.RESERVED_SYSACT, .seq = 3 };
    // the event's first cause is the auto-attributed SystemCause node
    const causes = rec.log.causesOf(id);
    try testing.expectEqual(@as(usize, 1), causes.len);
    try testing.expect(causes[0].eql(sa));

    // payload decodes back
    var rd = serialize.ByteReader{ .bytes = rec.log.payloadOf(id) };
    const got = try serialize.readValue(Hit, &rd);
    try testing.expectEqual(@as(i32, 5), got.amount);
    try testing.expectEqual(@as(u32, 2), got.target.index);
}

test "SystemCause node is materialized once per (tick, system); explicit causes append after it" {
    const gpa = testing.allocator;
    var rec = Recorder.init(gpa);
    defer rec.deinit();

    const e0 = try rec.record(Hit, 1, 2, 0, ent(0), .{ .target = ent(0), .amount = 1 }, &.{});
    const e1 = try rec.record(Hit, 1, 2, 1, ent(0), .{ .target = ent(0), .amount = 2 }, &.{e0}); // cite e0
    // 1 SystemCause node + 2 events
    try testing.expectEqual(@as(usize, 3), rec.log.count());
    const sa: EventId = .{ .tick = 1, .emitter = event.RESERVED_SYSACT, .seq = 2 };
    try testing.expect(rec.log.causesOf(e0)[0].eql(sa));
    // e1: [SystemCause, e0]
    const c1 = rec.log.causesOf(e1);
    try testing.expectEqual(@as(usize, 2), c1.len);
    try testing.expect(c1[0].eql(sa));
    try testing.expect(c1[1].eql(e0));
}

test "a different (tick, system) materializes a fresh SystemCause node" {
    const gpa = testing.allocator;
    var rec = Recorder.init(gpa);
    defer rec.deinit();
    _ = try rec.record(Hit, 1, 2, 0, ent(0), .{ .target = ent(0), .amount = 1 }, &.{}); // sa(1,_,2)
    _ = try rec.record(Hit, 1, 5, 0, ent(0), .{ .target = ent(0), .amount = 1 }, &.{}); // sa(1,_,5)
    _ = try rec.record(Hit, 2, 2, 0, ent(0), .{ .target = ent(0), .amount = 1 }, &.{}); // sa(2,_,2)
    // 3 distinct SystemCause nodes + 3 events
    try testing.expectEqual(@as(usize, 6), rec.log.count());
}
