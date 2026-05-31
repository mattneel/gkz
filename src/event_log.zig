//! The event log — the recorded provenance (SPEC §5, PLAN.md Phase 3). Build-order step 3.
//!
//! A side structure (owned by a Recorder, never by the World, never serialized into a snapshot, never
//! seen by hash.zig) holding recorded events plus their causal edges. Payloads and cause lists live in
//! out-of-line arenas sliced by per-event offsets, so causal fan-in is unbounded and the on-wire layout
//! never changes with it.
//!
//! Causal queries are backward graph-walks — the §5 debugging primitive. `causesOf` returns an event's
//! direct causes; `causeChain` returns all transitive ancestors in canonical (ascending-EventId) order,
//! cycle-guarded, dangling edges skipped. (The §7 Datalog-ish relational surface over a socket is a
//! later phase; it bolts onto these primitives. A sorted-id index for sub-linear lookup is a deferred
//! optimization — Phase 3 uses a linear scan, fine for on-demand provenance.)
//!
//! The log serializes via the existing field-by-field little-endian codec (serialize.zig), so it is
//! loggable / diffable / cross-process-shippable; `logDigest` reuses hash.zig's XXH64+CRC32.

const std = @import("std");
const event = @import("event.zig");
const serialize = @import("serialize.zig");
const hashmod = @import("hash.zig");
const sortmod = @import("sort.zig");
const entity = @import("entity.zig");
const EventId = event.EventId;
const Event = event.Event;
const Entity = entity.Entity;
const Allocator = std.mem.Allocator;

pub const MAGIC = [5]u8{ 'G', 'K', 'Z', 'E', '1' };
pub const FORMAT_VERSION: u16 = 1;

pub const EventLog = struct {
    events: std.ArrayList(Event) = .empty,
    edge_arena: std.ArrayList(EventId) = .empty, // flattened cause lists, sliced by cause_off/cause_len
    payload_arena: std.ArrayList(u8) = .empty, // LE-encoded payloads, sliced by payload_off/payload_len

    pub fn deinit(self: *EventLog, gpa: Allocator) void {
        self.events.deinit(gpa);
        self.edge_arena.deinit(gpa);
        self.payload_arena.deinit(gpa);
        self.* = undefined;
    }

    pub fn count(self: *const EventLog) usize {
        return self.events.items.len;
    }

    /// Append a recorded event, copying its payload + causes into the arenas. The single append path
    /// (used by the Recorder and tests).
    pub fn append(
        self: *EventLog,
        gpa: Allocator,
        id: EventId,
        kind: u16,
        emitter: u16,
        subject: Entity,
        payload: []const u8,
        causes: []const EventId,
    ) Allocator.Error!void {
        const payload_off: u32 = @intCast(self.payload_arena.items.len);
        try self.payload_arena.appendSlice(gpa, payload);
        const cause_off: u32 = @intCast(self.edge_arena.items.len);
        try self.edge_arena.appendSlice(gpa, causes);
        try self.events.append(gpa, .{
            .id = id,
            .kind = kind,
            .emitter = emitter,
            .subject = subject,
            .payload_off = payload_off,
            .payload_len = @intCast(payload.len),
            .cause_off = cause_off,
            .cause_len = @intCast(causes.len),
        });
    }

    fn find(self: *const EventLog, id: EventId) ?*const Event {
        for (self.events.items) |*e| {
            if (e.id.eql(id)) return e;
        }
        return null;
    }

    /// The direct causes of `id` (empty if `id` is unknown or has no causes).
    pub fn causesOf(self: *const EventLog, id: EventId) []const EventId {
        const e = self.find(id) orelse return &.{};
        return self.edge_arena.items[e.cause_off..][0..e.cause_len];
    }

    /// The payload bytes of `id` (empty if unknown). Decode with serialize.readValue + the type for
    /// `kind` (typed decoding is a §7 concern; Phase 3 keeps bytes).
    pub fn payloadOf(self: *const EventLog, id: EventId) []const u8 {
        const e = self.find(id) orelse return &.{};
        return self.payload_arena.items[e.payload_off..][0..e.payload_len];
    }

    /// All transitive ancestors of `id`, canonical ascending-EventId order, deduped, cycle-guarded.
    /// Caller frees. (On-demand provenance; O(events × chain) — never on the throughput path.)
    pub fn causeChain(self: *const EventLog, gpa: Allocator, id: EventId) Allocator.Error![]EventId {
        var seen: std.ArrayList(EventId) = .empty; // discovered nodes incl. the root (BFS frontier)
        defer seen.deinit(gpa);
        try seen.append(gpa, id);
        var i: usize = 0;
        while (i < seen.items.len) : (i += 1) {
            for (self.causesOf(seen.items[i])) |c| {
                if (!containsId(seen.items, c)) try seen.append(gpa, c);
            }
        }
        // result = ancestors (everything discovered except the root), sorted canonically
        var result: std.ArrayList(EventId) = .empty;
        errdefer result.deinit(gpa);
        for (seen.items[1..]) |a| try result.append(gpa, a);
        sortmod.sort(EventId, result.items, {}, EventId.lessThan);
        return result.toOwnedSlice(gpa);
    }
};

fn containsId(haystack: []const EventId, needle: EventId) bool {
    for (haystack) |h| {
        if (h.eql(needle)) return true;
    }
    return false;
}

// --- codec (GKZE1): canonical little-endian, mirroring serialize.writeWorld discipline ------------

/// Serialized size of one `Event` record and one `EventId`, used to length-validate `readLog`.
const EVENT_BYTES: usize = serialize.serializedSizeOf(Event);
const EVENTID_BYTES: usize = serialize.serializedSizeOf(EventId);

pub fn writeLog(sink: anytype, log: *const EventLog) !void {
    // 4 GB ceilings on the arenas (a documented resource limit; the counts are u32 on the wire).
    std.debug.assert(log.events.items.len <= std.math.maxInt(u32));
    std.debug.assert(log.edge_arena.items.len <= std.math.maxInt(u32));
    std.debug.assert(log.payload_arena.items.len <= std.math.maxInt(u32));
    try sink.update(&MAGIC);
    try serialize.putInt(sink, u16, FORMAT_VERSION);
    try serialize.putInt(sink, u32, @intCast(log.events.items.len));
    try serialize.putInt(sink, u32, @intCast(log.edge_arena.items.len));
    try serialize.putInt(sink, u32, @intCast(log.payload_arena.items.len));
    for (log.events.items) |e| try serialize.writeValue(sink, Event, e);
    for (log.edge_arena.items) |id| try serialize.writeValue(sink, EventId, id);
    try sink.update(log.payload_arena.items); // raw canonical payload bytes
}

pub fn readLog(gpa: Allocator, reader: *serialize.ByteReader) (serialize.Error || Allocator.Error)!EventLog {
    const magic = try reader.readSlice(MAGIC.len);
    if (!std.mem.eql(u8, magic, &MAGIC)) return error.BadMagic;
    if (try serialize.getInt(reader, u16) != FORMAT_VERSION) return error.UnsupportedFormat;
    const n_events = try serialize.getInt(reader, u32);
    const n_edges = try serialize.getInt(reader, u32);
    const n_payload = try serialize.getInt(reader, u32);

    // Validate the declared sizes against the actual remaining bytes BEFORE allocating, so a corrupt
    // or hostile header cannot drive an unbounded reservation (the body must be exactly this big).
    const remaining = reader.bytes.len - reader.pos;
    const expected = @as(u64, n_events) * EVENT_BYTES + @as(u64, n_edges) * EVENTID_BYTES + @as(u64, n_payload);
    if (expected != remaining) return error.Truncated;

    var log: EventLog = .{};
    errdefer log.deinit(gpa);
    try log.events.ensureTotalCapacity(gpa, n_events);
    var i: u32 = 0;
    while (i < n_events) : (i += 1) log.events.appendAssumeCapacity(try serialize.readValue(Event, reader));
    try log.edge_arena.ensureTotalCapacity(gpa, n_edges);
    i = 0;
    while (i < n_edges) : (i += 1) log.edge_arena.appendAssumeCapacity(try serialize.readValue(EventId, reader));
    const bytes = try reader.readSlice(n_payload);
    try log.payload_arena.appendSlice(gpa, bytes);

    // Validate each event's offsets so a malformed (but length-consistent) image cannot cause an
    // out-of-bounds slice in causesOf/payloadOf later.
    for (log.events.items) |e| {
        if (@as(u64, e.payload_off) + e.payload_len > n_payload) return error.Corrupt;
        if (@as(u64, e.cause_off) + e.cause_len > n_edges) return error.Corrupt;
    }
    return log;
}

/// XXH64 + CRC32 over the canonical log bytes — the pinned provenance fingerprint.
pub fn logDigest(log: *const EventLog) hashmod.Digest {
    var sink = hashmod.HashSink.init();
    writeLog(&sink, log) catch unreachable; // HashSink.update cannot fail
    return sink.digest();
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

fn eid(tick: u64, emitter: u16, seq: u32) EventId {
    return .{ .tick = tick, .emitter = emitter, .seq = seq };
}
fn subj(i: u32) Entity {
    return .{ .index = i, .generation = 0 };
}

test "causesOf returns an event's direct causes; unknown id -> empty" {
    const gpa = testing.allocator;
    var log: EventLog = .{};
    defer log.deinit(gpa);
    const a = eid(0, 1, 0);
    const b = eid(1, 2, 0);
    try log.append(gpa, a, 100, 1, subj(0), "ab", &.{});
    try log.append(gpa, b, 101, 2, subj(1), "", &.{a});
    try testing.expectEqual(@as(usize, 0), log.causesOf(a).len);
    try testing.expectEqual(@as(usize, 1), log.causesOf(b).len);
    try testing.expect(log.causesOf(b)[0].eql(a));
    try testing.expectEqual(@as(usize, 0), log.causesOf(eid(9, 9, 9)).len); // unknown
    try testing.expectEqualStrings("ab", log.payloadOf(a));
}

test "causeChain walks transitive ancestors in canonical order, cycle-guarded, dangling skipped" {
    const gpa = testing.allocator;
    var log: EventLog = .{};
    defer log.deinit(gpa);
    // diamond: D <- {B, C}; B <- A; C <- A; plus a dangling cause on A
    const a = eid(0, 1, 0);
    const b = eid(1, 1, 0);
    const c = eid(1, 2, 0);
    const d = eid(2, 1, 0);
    const dangling = eid(99, 9, 9);
    try log.append(gpa, a, 0, 1, subj(0), "", &.{dangling}); // dangling: no such event
    try log.append(gpa, b, 0, 1, subj(0), "", &.{a});
    try log.append(gpa, c, 0, 2, subj(0), "", &.{a});
    try log.append(gpa, d, 0, 1, subj(0), "", &.{ b, c });

    const chain = try log.causeChain(gpa, d);
    defer gpa.free(chain);
    // ancestors of D = {A, B, C, dangling} (dangling discovered as a cause of A but has no event)
    try testing.expectEqual(@as(usize, 4), chain.len);
    // canonical ascending order: A(0,1,0) < B(1,1,0) < C(1,2,0) < dangling(99,9,9)
    try testing.expect(chain[0].eql(a));
    try testing.expect(chain[1].eql(b));
    try testing.expect(chain[2].eql(c));
    try testing.expect(chain[3].eql(dangling));
}

test "causeChain terminates on a cycle" {
    const gpa = testing.allocator;
    var log: EventLog = .{};
    defer log.deinit(gpa);
    const x = eid(0, 1, 0);
    const y = eid(0, 1, 1);
    try log.append(gpa, x, 0, 1, subj(0), "", &.{y});
    try log.append(gpa, y, 0, 1, subj(0), "", &.{x}); // cycle x<->y
    const chain = try log.causeChain(gpa, x);
    defer gpa.free(chain);
    try testing.expectEqual(@as(usize, 1), chain.len); // only y (x is the root, excluded)
    try testing.expect(chain[0].eql(y));
}

test "log codec round-trips byte-identically and logDigest is stable" {
    const gpa = testing.allocator;
    var log: EventLog = .{};
    defer log.deinit(gpa);
    try log.append(gpa, eid(0, 1, 0), 100, 1, subj(3), "hello", &.{});
    try log.append(gpa, eid(1, 2, 0), 101, 2, subj(4), "", &.{eid(0, 1, 0)});

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try writeLog(&sink, &log);

    var reader = serialize.ByteReader{ .bytes = buf.items };
    var restored = try readLog(gpa, &reader);
    defer restored.deinit(gpa);
    try testing.expectEqual(log.count(), restored.count());

    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(gpa);
    var sink2 = serialize.ByteSink{ .list = &buf2, .gpa = gpa };
    try writeLog(&sink2, &restored);
    try testing.expectEqualSlices(u8, buf.items, buf2.items); // byte-identical round-trip

    try testing.expectEqual(logDigest(&log).hash, logDigest(&restored).hash);
    try testing.expect(logDigest(&log).hash != 0);
}

test "readLog rejects bad magic" {
    const gpa = testing.allocator;
    var bad = serialize.ByteReader{ .bytes = "XXXXX\x01\x00" };
    try testing.expectError(error.BadMagic, readLog(gpa, &bad));
}

test "readLog round-trips an empty log and rejects truncation" {
    const gpa = testing.allocator;
    var empty: EventLog = .{};
    defer empty.deinit(gpa);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try writeLog(&sink, &empty);

    var rd = serialize.ByteReader{ .bytes = buf.items };
    var restored = try readLog(gpa, &rd);
    defer restored.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), restored.count());

    // a non-empty log truncated mid-body is rejected (declared sizes != remaining bytes)
    var log: EventLog = .{};
    defer log.deinit(gpa);
    try log.append(gpa, eid(0, 1, 0), 5, 1, subj(0), "payload", &.{});
    var b2: std.ArrayList(u8) = .empty;
    defer b2.deinit(gpa);
    var s2 = serialize.ByteSink{ .list = &b2, .gpa = gpa };
    try writeLog(&s2, &log);
    var rd_trunc = serialize.ByteReader{ .bytes = b2.items[0 .. b2.items.len - 2] };
    try testing.expectError(error.Truncated, readLog(gpa, &rd_trunc));
}

test "causeChain handles a long linear chain (frontier growth + canonical re-sort)" {
    const gpa = testing.allocator;
    var log: EventLog = .{};
    defer log.deinit(gpa);
    const N: u64 = 150;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const id = eid(i, 1, 0); // ordered by tick
        if (i == 0) {
            try log.append(gpa, id, 0, 1, subj(0), "", &.{});
        } else {
            try log.append(gpa, id, 0, 1, subj(0), "", &[_]EventId{eid(i - 1, 1, 0)});
        }
    }
    const chain = try log.causeChain(gpa, eid(N - 1, 1, 0));
    defer gpa.free(chain);
    try testing.expectEqual(@as(usize, N - 1), chain.len); // all ancestors except the root
    for (chain, 0..) |c, k| {
        if (k > 0) try testing.expect(chain[k - 1].order(c) == .lt); // strictly ascending
    }
}
