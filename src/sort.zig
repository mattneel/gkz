//! Pinned deterministic sort (PLAN.md build-order step 3).
//!
//! The canonical world ordering (serialize/hash) is produced by sorting row indices by their owning
//! entity. That sort is on the determinism-critical path, so the kernel routes **all** order-sensitive
//! sorting through this one wrapper — never `std.sort.*` directly — so the algorithm choice is pinned
//! in exactly one place and a future std change is contained here.
//!
//! We use a **stable** sort (`std.sort.block`, allocation-free, in-place). Rationale: a stable sort's
//! output is uniquely determined by the comparator (equal elements keep input order), so it is
//! deterministic across architectures *and* across Zig versions even if the underlying algorithm
//! changes — and it stays deterministic even if a caller ever sorts on a non-unique key. (The
//! canonical key, `entity.index`, is unique among live rows, so any correct sort would agree here;
//! stability is defense-in-depth against future misuse — see PLAN.md open-risk #5.)

const std = @import("std");

/// Stable, deterministic, in-place sort. `lessThan(context, a, b)` must define a strict weak ordering.
pub fn sort(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), T, T) bool,
) void {
    std.sort.block(T, items, context, lessThan);
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

fn asc(_: void, a: u32, b: u32) bool {
    return a < b;
}

test "sorts ascending, deterministically" {
    var xs = [_]u32{ 5, 1, 4, 2, 3, 0 };
    sort(u32, &xs, {}, asc);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, &xs);
}

const Keyed = struct { key: u32, tag: u32 };

fn byKey(_: void, a: Keyed, b: Keyed) bool {
    return a.key < b.key;
}

test "stable on equal keys: input order of ties is preserved" {
    var xs = [_]Keyed{
        .{ .key = 1, .tag = 0 },
        .{ .key = 0, .tag = 1 },
        .{ .key = 1, .tag = 2 },
        .{ .key = 0, .tag = 3 },
        .{ .key = 1, .tag = 4 },
    };
    sort(Keyed, &xs, {}, byKey);
    // key 0: tags 1,3 in original order; key 1: tags 0,2,4 in original order
    try testing.expectEqual(@as(u32, 1), xs[0].tag);
    try testing.expectEqual(@as(u32, 3), xs[1].tag);
    try testing.expectEqual(@as(u32, 0), xs[2].tag);
    try testing.expectEqual(@as(u32, 2), xs[3].tag);
    try testing.expectEqual(@as(u32, 4), xs[4].tag);
}

test "idempotent: sorting an already-sorted slice is a no-op" {
    var xs = [_]u32{ 0, 1, 2, 3, 4 };
    sort(u32, &xs, {}, asc);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, &xs);
}
