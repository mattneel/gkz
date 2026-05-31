//! The §13 sharding MATH seam (PLAN.md Phase 7): a pure seed-range partition + an associative
//! `Aggregate` merge, so a future multi-process sharded sweep equals a single-process one field-for-field.
//! NO process model, NO sockets (that is Phase 9) — only the partition + merge that makes sharding
//! provably equivalent. `sweep`/`aggregate` are already pure in the seed range, so a sharded run is just
//! `for each shard: aggregate(shardRanges(...))` then `mergeAggregates(parts)`.

const std = @import("std");
const metric = @import("../spec/metric.zig");

pub const ShardRange = struct { lo: u64, hi: u64 };

/// Partition `[seed_lo, seed_hi)` into `n_shards` contiguous balanced tiles and return tile `shard_i`.
/// The first `rem` tiles get one extra seed (`rem = total % n_shards`), so the tiles cover the range with
/// NO gap and NO overlap and differ in size by at most one. `n_shards` must be >= 1; `shard_i < n_shards`.
pub fn shardRanges(seed_lo: u64, seed_hi: u64, n_shards: u64, shard_i: u64) ShardRange {
    std.debug.assert(n_shards >= 1 and shard_i < n_shards and seed_hi >= seed_lo);
    const total = seed_hi - seed_lo;
    const base = total / n_shards;
    const rem = total % n_shards;
    const lo = seed_lo + shard_i * base + @min(shard_i, rem);
    const cnt = base + (if (shard_i < rem) @as(u64, 1) else 0);
    return .{ .lo = lo, .hi = lo + cnt };
}

/// Associative merge of per-shard `Aggregate(T)`s into the single-process result: count and i128 sum add,
/// min/max combine, EMPTY parts (count==0) are skipped (their sentinel min/max would corrupt the merge).
/// `mean` is deferred to display exactly as `metric.Aggregate` does, so the merge never divides — the
/// result is bit-identical to aggregating the whole range in one process.
pub fn mergeAggregates(comptime T: type, parts: []const metric.Aggregate(T)) metric.Aggregate(T) {
    var out: metric.Aggregate(T) = .{};
    for (parts) |p| {
        if (p.count == 0) continue;
        out.count += p.count;
        if (p.min < out.min) out.min = p.min;
        if (p.max > out.max) out.max = p.max;
        out.sum += p.sum;
    }
    return out;
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "shardRanges tiles [lo,hi) with no gap and no overlap, for 2/3/4 shards" {
    inline for (.{ 2, 3, 4 }) |n| {
        const lo: u64 = 10;
        const hi: u64 = 27; // 17 seeds over n shards (uneven for 3/4)
        var prev: u64 = lo;
        var covered: u64 = 0;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const s = shardRanges(lo, hi, n, i);
            try testing.expectEqual(prev, s.lo); // contiguous: this shard starts where the last ended
            try testing.expect(s.hi >= s.lo);
            covered += s.hi - s.lo;
            prev = s.hi;
        }
        try testing.expectEqual(hi, prev); // last shard ends exactly at hi
        try testing.expectEqual(hi - lo, covered); // union == full range, no overlap
    }
}

test "mergeAggregates equals a single-process Aggregate field-for-field (associative integer merge)" {
    // single-process: aggregate values 1..6
    var whole: metric.Aggregate(i64) = .{};
    var v: i64 = 1;
    while (v <= 6) : (v += 1) whole.add(v);

    // sharded: {1,2,3} and {4,5,6} merged
    var a: metric.Aggregate(i64) = .{};
    for ([_]i64{ 1, 2, 3 }) |x| a.add(x);
    var b: metric.Aggregate(i64) = .{};
    for ([_]i64{ 4, 5, 6 }) |x| b.add(x);
    const merged = mergeAggregates(i64, &.{ a, b });

    try testing.expectEqual(whole.count, merged.count);
    try testing.expectEqual(whole.min, merged.min);
    try testing.expectEqual(whole.max, merged.max);
    try testing.expectEqual(whole.sum, merged.sum);
    // a 3-way merge with an EMPTY part is identical (empty parts skipped)
    const merged3 = mergeAggregates(i64, &.{ a, .{}, b });
    try testing.expectEqual(whole.sum, merged3.sum);
    try testing.expectEqual(whole.min, merged3.min);
}
