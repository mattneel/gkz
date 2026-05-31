//! Counter-based keyed RNG (SPEC §2.4, PLAN.md build-order step 5; D4).
//!
//! A draw is a **pure function** `draw(seed, tick, entity_id, stream_id)` — there is no shared mutable
//! cursor. The World holds only the seed root (`RngRoot`), never a running counter. This is mandatory
//! for determinism under future parallel systems (§4): a shared incrementing stream read by systems on
//! different threads is order-dependent and silently nondeterministic; a keyed counter function is
//! order-independent by construction.
//!
//! The mixer is a chain of SplitMix64 finalizers (Stafford variant 13). Every operation is wrapping
//! (`*%`) / xor / shift, so the result is bit-identical across build modes and architectures (D2/D7) —
//! no float, ever. It is not cryptographic; it is a fast, well-distributed game RNG whose only hard
//! requirement is determinism. `stream_id` lets one entity draw independent streams in one tick.

const std = @import("std");
const fpz = @import("fpz");
const Fixed = fpz.Fixed;

/// The only RNG state stored in the World: the seed root. Keyed draws derive from it deterministically.
pub const RngRoot = extern struct { seed: u64 };

/// SplitMix64 finalizer (Stafford variant 13): a strong 64-bit avalanche. mix(0) == 0, so callers must
/// fold in a nonzero constant before mixing (see `draw`).
inline fn mix(x: u64) u64 {
    var z = x;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    z = z ^ (z >> 31);
    return z;
}

/// Draw a 64-bit value keyed by (seed, tick, entity_id, stream_id). Pure: identical arguments always
/// produce the identical result, on every thread, build mode, and architecture.
pub fn draw(root: RngRoot, tick: u64, entity_id: u32, stream_id: u32) u64 {
    // Each input is folded in with a distinct large odd constant and then fully avalanched, so no
    // input is left un-diffused and the all-zero key does not map to a fixed point of `mix`.
    var z = mix(root.seed +% 0x9E3779B97F4A7C15);
    z = mix(z ^ (tick *% 0x9E3779B97F4A7C15));
    z = mix(z ^ (@as(u64, entity_id) *% 0xD1B54A32D192ED03));
    z = mix(z ^ (@as(u64, stream_id) *% 0xCBF29CE484222325));
    return z;
}

/// Draw a `Fixed` uniformly in `[lo, hi]` (inclusive). Returns `lo` if `lo >= hi`. Builds the result's
/// raw `i64` directly via `Fixed.fromRaw` and computes the span in `i128`, so it can never overflow or
/// trip an `fpz` assert (div-by-zero, range, MIN-negation), even for `lo = Fixed.MIN, hi = Fixed.MAX`.
pub fn drawFixed(root: RngRoot, tick: u64, entity_id: u32, stream_id: u32, lo: Fixed, hi: Fixed) Fixed {
    if (lo.raw >= hi.raw) return lo;
    const span: u128 = @intCast(@as(i128, hi.raw) - @as(i128, lo.raw)); // > 0
    const modulus: u128 = span + 1;
    const offset: u128 = @as(u128, draw(root, tick, entity_id, stream_id)) % modulus;
    const result: i64 = @intCast(@as(i128, lo.raw) + @as(i128, @intCast(offset)));
    return Fixed.fromRaw(result);
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "draw is a pure function of its key" {
    const root: RngRoot = .{ .seed = 12345 };
    try testing.expectEqual(draw(root, 7, 3, 1), draw(root, 7, 3, 1));
    try testing.expectEqual(draw(.{ .seed = 0 }, 0, 0, 0), draw(.{ .seed = 0 }, 0, 0, 0));
}

test "all-zero key is not a degenerate zero output" {
    try testing.expect(draw(.{ .seed = 0 }, 0, 0, 0) != 0);
}

test "varying each key dimension changes the output" {
    const r: RngRoot = .{ .seed = 99 };
    const base = draw(r, 1, 1, 1);
    try testing.expect(draw(r, 2, 1, 1) != base); // tick
    try testing.expect(draw(r, 1, 2, 1) != base); // entity
    try testing.expect(draw(r, 1, 1, 2) != base); // stream
    try testing.expect(draw(.{ .seed = 100 }, 1, 1, 1) != base); // seed
}

test "rough uniformity of the low bit over many draws" {
    var ones: usize = 0;
    var i: u32 = 0;
    while (i < 4096) : (i += 1) {
        if (draw(.{ .seed = 1 }, 0, i, 0) & 1 == 1) ones += 1;
    }
    // expect ~2048; allow a generous band so this is a sanity check, not a statistical gate.
    try testing.expect(ones > 1900 and ones < 2196);
}

test "drawFixed stays within [lo, hi], including the full Fixed range" {
    const r: RngRoot = .{ .seed = 7 };
    const lo = Fixed.fromInt(-5);
    const hi = Fixed.fromInt(5);
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const v = drawFixed(r, 0, i, 0, lo, hi);
        try testing.expect(v.raw >= lo.raw and v.raw <= hi.raw);
    }
    // extreme range must not overflow / trip an fpz assert
    const ext = drawFixed(r, 1, 0, 0, Fixed.MIN, Fixed.MAX);
    try testing.expect(ext.raw >= Fixed.MIN.raw and ext.raw <= Fixed.MAX.raw);
}

test "drawFixed degenerate ranges return lo deterministically" {
    const r: RngRoot = .{ .seed = 7 };
    const five = Fixed.fromInt(5);
    try testing.expectEqual(five.raw, drawFixed(r, 0, 0, 0, five, five).raw); // lo == hi
    try testing.expectEqual(five.raw, drawFixed(r, 0, 0, 0, five, Fixed.fromInt(1)).raw); // lo > hi
}

test "PINNED RNG vectors (freeze the algorithm; a change here is intentional and breaks replays)" {
    try testing.expectEqual(@as(u64, 0x1957_a760_4e21_5178), draw(.{ .seed = 0 }, 0, 0, 0));
    try testing.expectEqual(@as(u64, 0x1ffc_c93b_9172_1264), draw(.{ .seed = 1 }, 2, 3, 4));
}
