//! Generational entity allocator (SPEC §3, PLAN.md build-order step 1).
//!
//! An `Entity` is a generational index `{ index, generation }`. The generation discriminates a live
//! handle from a stale one that points at a recycled slot. Determinism (D1/D4/D8, Q4) requires that
//! the sequence of `{index, generation}` values be a pure function of the alloc/free operation
//! stream and nothing else — no addresses, no allocator-order dependence — and that the full
//! allocator state live inside the World so it is snapshotted/restored byte-exact.
//!
//! Liveness is encoded in the generation's low bit: **even = alive, odd = free**. Every handed-out
//! handle has an even generation; a slot's generation is bumped (`+%1`) on both free (even→odd) and
//! recycle (odd→even). This makes `isLive` total and correct for *any* handle, including a forged one
//! pointing at a freed-but-not-yet-recycled slot — a gen-only check would wrongly report that slot
//! live, and the §9 fuzzer feeds exactly such adversarial handles. Wrapping `+%1` (never `+`) keeps
//! the bump build-mode-identical (D2); a slot recycled 2^32 times wraps deterministically (a
//! documented astronomical edge, shared by every candidate design).

const std = @import("std");

/// Generational entity handle. `extern` for a fixed, padding-free 8-byte layout (Q7); serialized as
/// `index:u32` then `generation:u32`, little-endian (Q5/Q6).
pub const Entity = extern struct {
    index: u32,
    generation: u32,
};

/// Sentinel "no row" for an entity→row sparse index (used by storage.zig).
pub const ROW_NONE: u32 = std.math.maxInt(u32);

/// Deterministic generational allocator. The whole of this struct is World state and is
/// serialized/restored byte-exact (Q4). Recycle policy is FIFO: the oldest freed index is reused
/// first, so the index stream is fixed by the op stream alone.
pub const EntityAllocator = struct {
    /// `generation[i]` is slot i's current generation. Length is the entity-slot high-water mark and
    /// is the only source of truth for the next fresh index.
    generation: std.ArrayList(u32) = .empty,
    /// FIFO queue of freed indices awaiting recycle. Entries before `free_head` are already consumed.
    free_list: std.ArrayList(u32) = .empty,
    /// Cursor into `free_list`: the oldest not-yet-recycled freed index.
    free_head: u32 = 0,

    pub fn deinit(self: *EntityAllocator, gpa: std.mem.Allocator) void {
        self.generation.deinit(gpa);
        self.free_list.deinit(gpa);
        self.* = undefined;
    }

    /// Allocate an entity. Recycles the front of the FIFO free queue if any, else extends with a
    /// fresh slot. Returned generation is always even (alive).
    pub fn alloc(self: *EntityAllocator, gpa: std.mem.Allocator) std.mem.Allocator.Error!Entity {
        if (self.free_head < self.free_list.items.len) {
            const idx = self.free_list.items[self.free_head];
            self.free_head +%= 1; // wrapping per D2 (bounded by free_list.len; wrap is unreachable)
            // When the queue drains, compact it deterministically (depends only on the op stream),
            // bounding free_list to the max outstanding-freed count instead of growing forever.
            if (self.free_head == self.free_list.items.len) {
                self.free_list.clearRetainingCapacity();
                self.free_head = 0;
            }
            self.generation.items[idx] +%= 1; // odd (free) -> even (alive)
            return .{ .index = idx, .generation = self.generation.items[idx] };
        }
        const idx: u32 = @intCast(self.generation.items.len);
        try self.generation.append(gpa, 0); // fresh slot, generation 0 (even = alive)
        return .{ .index = idx, .generation = 0 };
    }

    /// Free an entity. No-op (idempotent) if the handle is not live, so a double-free or a stale
    /// command-driven despawn is harmless and deterministic.
    pub fn free(self: *EntityAllocator, gpa: std.mem.Allocator, e: Entity) std.mem.Allocator.Error!void {
        if (!self.isLive(e)) return;
        self.generation.items[e.index] +%= 1; // even (alive) -> odd (free)
        try self.free_list.append(gpa, e.index);
    }

    /// True iff `e` names a currently-live slot. Total: rejects out-of-range, stale (generation
    /// mismatch), and forged free-slot (odd generation) handles.
    pub fn isLive(self: *const EntityAllocator, e: Entity) bool {
        return e.index < self.generation.items.len and
            self.generation.items[e.index] == e.generation and
            (e.generation & 1) == 0;
    }

    /// The outstanding freed indices in FIFO order — the canonical free-queue content for
    /// serialization (the consumed prefix `[0, free_head)` is dead data excluded from the snapshot).
    pub fn outstandingFree(self: *const EntityAllocator) []const u32 {
        return self.free_list.items[self.free_head..];
    }

    /// Number of live slots = total slots minus outstanding-free.
    pub fn liveCount(self: *const EntityAllocator) usize {
        return self.generation.items.len - self.outstandingFree().len;
    }

    pub fn clone(self: *const EntityAllocator, gpa: std.mem.Allocator) std.mem.Allocator.Error!EntityAllocator {
        var generation: std.ArrayList(u32) = .empty;
        errdefer generation.deinit(gpa);
        try generation.appendSlice(gpa, self.generation.items);
        var free_list: std.ArrayList(u32) = .empty;
        errdefer free_list.deinit(gpa);
        try free_list.appendSlice(gpa, self.free_list.items);
        return .{ .generation = generation, .free_list = free_list, .free_head = self.free_head };
    }

    /// Reconstruct an allocator from its canonical serialized parts (Q6 restore path). `generations`
    /// is the per-slot generation array; `outstanding` is the FIFO free queue (free_head becomes 0).
    pub fn fromParts(
        gpa: std.mem.Allocator,
        generations: []const u32,
        outstanding: []const u32,
    ) std.mem.Allocator.Error!EntityAllocator {
        var generation: std.ArrayList(u32) = .empty;
        errdefer generation.deinit(gpa);
        try generation.appendSlice(gpa, generations);
        var free_list: std.ArrayList(u32) = .empty;
        errdefer free_list.deinit(gpa);
        try free_list.appendSlice(gpa, outstanding);
        return .{ .generation = generation, .free_list = free_list, .free_head = 0 };
    }
};

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "fresh allocation hands out dense even-generation indices" {
    const gpa = testing.allocator;
    var a: EntityAllocator = .{};
    defer a.deinit(gpa);

    const e0 = try a.alloc(gpa);
    const e1 = try a.alloc(gpa);
    const e2 = try a.alloc(gpa);
    try testing.expectEqual(Entity{ .index = 0, .generation = 0 }, e0);
    try testing.expectEqual(Entity{ .index = 1, .generation = 0 }, e1);
    try testing.expectEqual(Entity{ .index = 2, .generation = 0 }, e2);
    try testing.expect(a.isLive(e0) and a.isLive(e1) and a.isLive(e2));
    try testing.expectEqual(@as(usize, 3), a.liveCount());
}

test "free then realloc recycles oldest index first (FIFO) and bumps generation" {
    const gpa = testing.allocator;
    var a: EntityAllocator = .{};
    defer a.deinit(gpa);

    const e0 = try a.alloc(gpa);
    const e1 = try a.alloc(gpa);
    try a.free(gpa, e0);
    try a.free(gpa, e1);
    // FIFO: e0's slot (index 0) recycles before e1's (index 1).
    const r0 = try a.alloc(gpa);
    const r1 = try a.alloc(gpa);
    try testing.expectEqual(@as(u32, 0), r0.index);
    try testing.expectEqual(@as(u32, 1), r1.index);
    // recycled slots come back at an even generation, distinct from the originals.
    try testing.expectEqual(@as(u32, 2), r0.generation);
    try testing.expectEqual(@as(u32, 2), r1.generation);
}

test "isLive is total: rejects stale, out-of-range, and forged free-slot handles" {
    const gpa = testing.allocator;
    var a: EntityAllocator = .{};
    defer a.deinit(gpa);

    const e0 = try a.alloc(gpa);
    try a.free(gpa, e0); // slot 0 generation is now 1 (odd = free)

    try testing.expect(!a.isLive(e0)); // stale: handle gen 0, slot gen 1
    try testing.expect(!a.isLive(.{ .index = 0, .generation = 1 })); // forged free-slot: odd gen
    try testing.expect(!a.isLive(.{ .index = 99, .generation = 0 })); // out of range

    const r0 = try a.alloc(gpa); // recycles slot 0 at gen 2
    try testing.expect(a.isLive(r0));
    try testing.expect(!a.isLive(e0)); // original handle still dead
}

test "double free and stale free are idempotent no-ops" {
    const gpa = testing.allocator;
    var a: EntityAllocator = .{};
    defer a.deinit(gpa);

    const e0 = try a.alloc(gpa);
    try a.free(gpa, e0);
    try a.free(gpa, e0); // double free: no-op
    try a.free(gpa, .{ .index = 0, .generation = 0 }); // stale: no-op
    try testing.expectEqual(@as(usize, 1), a.outstandingFree().len);
}

test "free queue compacts when drained, bounding its length" {
    const gpa = testing.allocator;
    var a: EntityAllocator = .{};
    defer a.deinit(gpa);

    const e0 = try a.alloc(gpa);
    const e1 = try a.alloc(gpa);
    try a.free(gpa, e0);
    try a.free(gpa, e1); // free_list = [0, 1], free_head = 0
    try testing.expectEqual(@as(usize, 2), a.outstandingFree().len);
    _ = try a.alloc(gpa); // consume index 0, free_head = 1
    _ = try a.alloc(gpa); // consume index 1, free_head == len -> compact
    try testing.expectEqual(@as(u32, 0), a.free_head);
    try testing.expectEqual(@as(usize, 0), a.free_list.items.len);
}

test "clone is independent and value-identical" {
    const gpa = testing.allocator;
    var a: EntityAllocator = .{};
    defer a.deinit(gpa);
    _ = try a.alloc(gpa);
    const e1 = try a.alloc(gpa);
    try a.free(gpa, e1);

    var b = try a.clone(gpa);
    defer b.deinit(gpa);
    try testing.expectEqualSlices(u32, a.generation.items, b.generation.items);
    try testing.expectEqualSlices(u32, a.outstandingFree(), b.outstandingFree());

    // mutating the clone does not perturb the original (D1 value semantics)
    _ = try b.alloc(gpa);
    try testing.expectEqual(@as(usize, 1), a.outstandingFree().len);
    try testing.expectEqual(@as(usize, 0), b.outstandingFree().len);
}

test "fromParts round-trips allocator state and preserves the next allocation" {
    const gpa = testing.allocator;
    var a: EntityAllocator = .{};
    defer a.deinit(gpa);
    _ = try a.alloc(gpa);
    _ = try a.alloc(gpa);
    const e2 = try a.alloc(gpa);
    try a.free(gpa, e2); // generation = [0,0,1], outstanding = [2]

    var restored = try EntityAllocator.fromParts(gpa, a.generation.items, a.outstandingFree());
    defer restored.deinit(gpa);
    try testing.expectEqualSlices(u32, a.generation.items, restored.generation.items);

    // the next alloc on the restored allocator matches the original's next alloc
    const next_orig = try a.alloc(gpa);
    const next_rest = try restored.alloc(gpa);
    try testing.expectEqual(next_orig, next_rest);
    try testing.expectEqual(Entity{ .index = 2, .generation = 2 }, next_rest);
}
