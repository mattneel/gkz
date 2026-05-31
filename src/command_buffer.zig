//! Per-system command buffer (SPEC §4, PLAN.md Phase 2; seam S2). Build-order step 1.
//!
//! A system never mutates shared/contended state directly. Structural changes (spawn/despawn) and
//! cross-entity component writes are enqueued as `Command`s into the system's own buffer, then applied
//! at a single end-of-tick sync point in a deterministic order (mutation.zig). Each command carries its
//! emitting `system_id` and a per-system monotonic `seq`; `(system_id, seq)` is a strict total order
//! assigned at emission, independent of the physical order systems ran in — that is what makes results
//! independent of scheduling (and, later, of threads).
//!
//! Representation (design fork F3 = uniform serializable record): ONE `Command(R)` for every op, with
//! the component value encoded into an inline byte payload via the *existing* field-by-field LE codec
//! (serialize.zig). One record type regardless of component count, and the command stream is already
//! the §5 provenance payload / §13 wire artifact with no second codec. Type safety is recovered at the
//! ENQUEUE front door: `add/set/remove` take a comptime component type `C` and a value of type `C`, and
//! derive `kind_id` from `C.kind_id` — a caller can never pass a raw id or a wrong-typed value.
//!
//! `Command` is a plain (non-`extern`) struct: it is never hashed (commands are not World state), and
//! shipping it cross-process goes through the serialize codec (little-endian), not a raw-bytes memcpy —
//! so `extern` would buy nothing while complicating the enum + array fields.

const std = @import("std");
const serialize = @import("serialize.zig");
const entity = @import("entity.zig");
const Entity = entity.Entity;
const Allocator = std.mem.Allocator;

/// Command opcodes. Non-exhaustive so a decoded/garbled op is a deterministic no-op (D2), never UB.
pub const Op = enum(u8) { noop = 0, spawn, despawn, add, set, remove, _ };

/// The widest serialized component payload across the registry (≥1). Sizes the inline payload buffer.
pub fn maxPayload(comptime R: type) usize {
    var m: usize = 0;
    inline for (R.Components) |C| {
        const s = serialize.serializedSizeOf(C);
        if (s > m) m = s;
    }
    return if (m == 0) 1 else m;
}

/// A single deferred mutation. `payload[0..payload_len]` holds the LE-encoded component value for
/// add/set (empty for spawn/despawn/remove).
pub fn Command(comptime R: type) type {
    const max = maxPayload(R);
    // `payload_len` is a u16, so the widest serialized component must fit (a comptime resource ceiling,
    // like the u32 entity-index ceiling — PLAN.md §7). A >64KB-serialized component is a compile error,
    // not a runtime trap.
    comptime std.debug.assert(max <= std.math.maxInt(u16));
    return struct {
        system_id: u16,
        seq: u32,
        op: Op,
        entity: Entity = .{ .index = 0, .generation = 0 },
        kind_id: u16 = 0,
        payload_len: u16 = 0,
        payload: [max]u8 = std.mem.zeroes([max]u8),
    };
}

/// A serialization sink that writes into a fixed inline buffer (cannot fail — the caller sizes it via
/// the comptime `serializedSizeOf(C) <= maxPayload(R)` assertion in `encode`).
pub const FixedSink = struct {
    buf: []u8,
    len: usize = 0,
    pub fn update(self: *FixedSink, bytes: []const u8) error{}!void {
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

/// One buffer per system (keyed by `system_id`), written by exactly that system during the run phase.
pub fn CommandBuffer(comptime R: type) type {
    return struct {
        const Self = @This();
        list: std.ArrayList(Command(R)) = .empty,
        gpa: Allocator, // PRIVATE: the only allocator near a system; never surfaced on SimCtx (D3)
        system_id: u16,
        seq: u32 = 0,

        pub fn init(gpa: Allocator, system_id: u16) Self {
            return .{ .gpa = gpa, .system_id = system_id };
        }
        pub fn deinit(self: *Self) void {
            self.list.deinit(self.gpa);
            self.* = undefined;
        }

        fn stamp(self: *Self, op: Op, e: Entity, kid: u16) Command(R) {
            defer self.seq +%= 1; // wrapping per D2 (a single system cannot realistically emit 2^32/tick)
            return .{ .system_id = self.system_id, .seq = self.seq, .op = op, .entity = e, .kind_id = kid };
        }

        pub fn spawn(self: *Self) Allocator.Error!void {
            try self.list.append(self.gpa, self.stamp(.spawn, .{ .index = 0, .generation = 0 }, 0));
        }
        pub fn despawn(self: *Self, e: Entity) Allocator.Error!void {
            try self.list.append(self.gpa, self.stamp(.despawn, e, 0));
        }
        pub fn remove(self: *Self, e: Entity, comptime C: type) Allocator.Error!void {
            _ = R.indexOf(C); // compile error if C is not registered
            try self.list.append(self.gpa, self.stamp(.remove, e, C.kind_id));
        }
        pub fn add(self: *Self, e: Entity, comptime C: type, v: C) Allocator.Error!void {
            try self.encode(.add, e, C, v);
        }
        pub fn set(self: *Self, e: Entity, comptime C: type, v: C) Allocator.Error!void {
            try self.encode(.set, e, C, v);
        }

        fn encode(self: *Self, op: Op, e: Entity, comptime C: type, v: C) Allocator.Error!void {
            comptime std.debug.assert(serialize.serializedSizeOf(C) <= maxPayload(R));
            var c = self.stamp(op, e, C.kind_id);
            var fs = FixedSink{ .buf = &c.payload };
            serialize.writeValue(&fs, C, v) catch unreachable; // FixedSink cannot fail (sized above)
            c.payload_len = @intCast(fs.len);
            try self.list.append(self.gpa, c);
        }
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("registry.zig").Registry;

const Position = struct {
    x: fpz.Fixed,
    y: fpz.Fixed,
    pub const kind_id: u16 = 10;
};
const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 20;
};
const Reg = Registry(.{ Position, Health });

test "maxPayload is the comptime-max serialized component size" {
    // Position = 2 * i64 (16); Health = i32 (4) -> 16
    try testing.expectEqual(@as(usize, 16), maxPayload(Reg));
}

test "stamp sets system_id and increments seq per enqueue" {
    const gpa = testing.allocator;
    var buf = CommandBuffer(Reg).init(gpa, 3);
    defer buf.deinit();
    try buf.spawn();
    try buf.despawn(.{ .index = 1, .generation = 0 });
    try testing.expectEqual(@as(usize, 2), buf.list.items.len);
    try testing.expectEqual(@as(u16, 3), buf.list.items[0].system_id);
    try testing.expectEqual(@as(u32, 0), buf.list.items[0].seq);
    try testing.expectEqual(@as(u32, 1), buf.list.items[1].seq);
    try testing.expectEqual(Op.spawn, buf.list.items[0].op);
    try testing.expectEqual(Op.despawn, buf.list.items[1].op);
}

test "add encodes the component value into the payload and decodes back identically" {
    const gpa = testing.allocator;
    var buf = CommandBuffer(Reg).init(gpa, 0);
    defer buf.deinit();
    const e = Entity{ .index = 5, .generation = 2 };
    try buf.add(e, Position, .{ .x = fpz.Fixed.fromInt(7), .y = fpz.Fixed.fromInt(-3) });

    const c = buf.list.items[0];
    try testing.expectEqual(Op.add, c.op);
    try testing.expectEqual(@as(u16, Position.kind_id), c.kind_id);
    try testing.expectEqual(e, c.entity);
    try testing.expectEqual(@as(u16, 16), c.payload_len);

    var rd = serialize.ByteReader{ .bytes = c.payload[0..c.payload_len] };
    const got = try serialize.readValue(Position, &rd);
    try testing.expectEqual(@as(i64, 7), got.x.toInt());
    try testing.expectEqual(@as(i64, -3), got.y.toInt());
}

test "remove and set carry the right kind_id" {
    const gpa = testing.allocator;
    var buf = CommandBuffer(Reg).init(gpa, 1);
    defer buf.deinit();
    const e = Entity{ .index = 0, .generation = 0 };
    try buf.remove(e, Health);
    try buf.set(e, Health, .{ .hp = 99 });
    try testing.expectEqual(Op.remove, buf.list.items[0].op);
    try testing.expectEqual(@as(u16, Health.kind_id), buf.list.items[0].kind_id);
    try testing.expectEqual(@as(u16, 0), buf.list.items[0].payload_len); // remove has no payload
    try testing.expectEqual(Op.set, buf.list.items[1].op);
    var rd = serialize.ByteReader{ .bytes = buf.list.items[1].payload[0..buf.list.items[1].payload_len] };
    try testing.expectEqual(@as(i32, 99), (try serialize.readValue(Health, &rd)).hp);
}
