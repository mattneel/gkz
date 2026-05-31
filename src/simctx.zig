//! SimCtx — the restricted capability surface handed to each system (SPEC §4, PLAN.md Phase 2; F6).
//! Build-order step 4.
//!
//! A system can reach, and only reach, four things through its `*SimCtx(R)`:
//!   1. `tick` — read-only metadata.
//!   2. keyed RNG — `rng(entity, stream)` / `rngFixed(...)`, thin wrappers over `rng.draw` keyed off the
//!      *fixed* tick + seed root. There is no cursor: a draw is a pure function of its key, so systems
//!      running in any order (and later, on any thread) cannot perturb each other's draws (D4).
//!   3. the command buffer — `cmd.spawn/.despawn/.add/.set/.remove`, the ONLY structural / cross-entity
//!      mutation path (deferred, applied at the end-of-tick sync point in deterministic order).
//!   4. a no-op `events` emitter — events live OUTSIDE the hashed World (S3, §5 deferred).
//!
//! Structurally ABSENT, so obvious nondeterminism is *uncompilable* rather than merely discouraged
//! (SPEC §4): no `*World` field (no arbitrary mutation — in-place edits go through the write-masked
//! Query), no allocator field (the command buffer holds its own privately), no clock, no OS RNG, no
//! syscalls. In-place Read/Write of the *current* entity is on the Query's RowView, not here.

const std = @import("std");
const fpz = @import("fpz");
const rngmod = @import("rng.zig");
const cmdbuf = @import("command_buffer.zig");
const Fixed = fpz.Fixed;
const RngRoot = rngmod.RngRoot;

/// Phase-1 stub: events are not recorded yet (S3, §5). A real emitter consumes the command stream.
pub const EventEmitter = struct {
    pub fn emit(_: *EventEmitter, _: anytype) void {}
};

pub fn SimCtx(comptime R: type) type {
    return struct {
        const Self = @This();

        tick: u64,
        rng_root: RngRoot,
        system_id: u16,
        cmd: *cmdbuf.CommandBuffer(R),
        events: *EventEmitter,

        /// A keyed RNG draw — pure in (tick, entity_id, stream_id); no shared cursor.
        ///
        /// The key is exactly (seed, tick, entity_id, stream_id) per SPEC §2.4 — `system_id` is
        /// deliberately NOT folded in. `stream_id` is the isolation knob: two *different* systems that
        /// draw with the same (entity_id, stream_id) in the same tick get the *same* value (sometimes
        /// desired — a shared deterministic decision). If a system wants randomness independent of
        /// other systems, it must pick a distinct `stream_id`.
        pub fn rng(self: *const Self, entity_id: u32, stream_id: u32) u64 {
            return rngmod.draw(self.rng_root, self.tick, entity_id, stream_id);
        }
        /// A keyed RNG draw mapped into `[lo, hi]` Fixed.
        pub fn rngFixed(self: *const Self, entity_id: u32, stream_id: u32, lo: Fixed, hi: Fixed) Fixed {
            return rngmod.drawFixed(self.rng_root, self.tick, entity_id, stream_id, lo, hi);
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

test "rng / rngFixed match the bare keyed draw (pinned to rng.zig's frozen vectors)" {
    const gpa = testing.allocator;
    var buf = cmdbuf.CommandBuffer(Reg).init(gpa, 0);
    defer buf.deinit();
    var ev = EventEmitter{};
    var ctx = SimCtx(Reg){ .tick = 0, .rng_root = .{ .seed = 0 }, .system_id = 0, .cmd = &buf, .events = &ev };

    try testing.expectEqual(@as(u64, 0x1957_a760_4e21_5178), ctx.rng(0, 0)); // Phase-1 pinned vector
    try testing.expectEqual(rngmod.draw(.{ .seed = 0 }, 0, 3, 1), ctx.rng(3, 1));
    const lo = Fixed.fromInt(-5);
    const hi = Fixed.fromInt(5);
    try testing.expectEqual(rngmod.drawFixed(.{ .seed = 0 }, 0, 2, 0, lo, hi).raw, ctx.rngFixed(2, 0, lo, hi).raw);
}

test "SimCtx exposes only the restricted capability surface (no World/allocator/clock)" {
    const S = SimCtx(Reg);
    try testing.expect(@hasField(S, "tick"));
    try testing.expect(@hasField(S, "rng_root"));
    try testing.expect(@hasField(S, "system_id"));
    try testing.expect(@hasField(S, "cmd"));
    try testing.expect(@hasField(S, "events"));
    // the forbidden fields are structurally absent (D3)
    try testing.expect(!@hasField(S, "world"));
    try testing.expect(!@hasField(S, "table"));
    try testing.expect(!@hasField(S, "gpa"));
    try testing.expect(!@hasField(S, "allocator"));
    try testing.expect(!@hasField(S, "clock"));
    try testing.expect(!@hasField(S, "time"));
    try testing.expectEqual(@as(usize, 5), @typeInfo(S).@"struct".fields.len);
}
