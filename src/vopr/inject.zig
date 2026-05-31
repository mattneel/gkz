//! Fault / timing injection (SPEC §9, PLAN.md Phase 4). Build-order step 4.
//!
//! SPEC §9: "fault & timing injection — vary thread scheduling, command-buffer apply timing, snapshot
//! cadence — none of which may change results (that's the test)." Two knobs, both reusing existing
//! kernel seams:
//!   * `exec_perm` — a within-stage permutation of the system execution order (run via `stepExec`'s
//!     explicit `exec`). Command-buffer apply-timing is subsumed: the drain is already `(system_id,
//!     seq)`-ordered and exec-order-independent, so permuting execution covers it.
//!   * `cadence` — round-trip the World through snapshot+restore every k ticks.
//! An `Injection` is a cheap descriptor; the oracle (oracle.zig) resolves it against the run's seed and
//! re-runs the variant, asserting the per-tick hash stream is unchanged. This module is pure
//! combinatorics — it runs nothing.

const std = @import("std");
const schedule = @import("../schedule.zig");
const rng = @import("../rng.zig");

pub const Injection = union(enum) {
    exec_perm: u32, // a within-stage permutation index, resolved against the run's seed
    cadence: u64, // snapshot+restore round-trip every k ticks
};

/// Write a stage-respecting permutation of the system execution order into `out` (len == systems.len):
/// start from the canonical `exec_order` (stage-grouped, ascending) and left-rotate each stage's
/// contiguous run by `perm_index % stage_size`. Deterministic and SEED-INDEPENDENT, and crucially
/// `perm_index == 1` rotates every multi-member stage by 1 (a guaranteed NON-identity for any stage of
/// size >= 2), so `enumerate(budget >= 2)` always covers a real reordering of a racy stage — closing
/// the false-negative gap a keyed-random shuffle had. (Rotation covers the neighbor-order classes that
/// matter for detecting order-dependence; full-permutation enumeration is a later enhancement.)
pub fn execPermutation(comptime R: type, comptime systems: []const schedule.Sys(R), perm_index: u32, out: []u16) void {
    const Sched = schedule.Schedule(R, systems);
    std.debug.assert(out.len == systems.len);
    @memcpy(out, &Sched.exec_order);
    var i: usize = 0;
    while (i < out.len) {
        const stage = Sched.stage_of[out[i]];
        var j = i + 1;
        while (j < out.len and Sched.stage_of[out[j]] == stage) : (j += 1) {}
        const m: u32 = @intCast(j - i);
        if (m >= 2) {
            const rot = perm_index % m;
            if (rot != 0) std.mem.rotate(u16, out[i..j], rot); // left-rotate this stage's members
        }
        i = j;
    }
}

/// A deterministic, budgeted set of injections: `budget` exec-permutation indices plus a fixed set of
/// snapshot cadences. Caller frees the returned slice.
pub fn enumerate(gpa: std.mem.Allocator, budget: u32) std.mem.Allocator.Error![]Injection {
    var list: std.ArrayList(Injection) = .empty;
    errdefer list.deinit(gpa);
    var p: u32 = 0;
    while (p < budget) : (p += 1) try list.append(gpa, .{ .exec_perm = p });
    inline for (.{ 1, 2, 3, 7 }) |k| try list.append(gpa, .{ .cadence = k });
    return list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const query = @import("../query.zig");
const simctx = @import("../simctx.zig");
const worldmod = @import("../world.zig");
const Read = query.Read;
const Write = query.Write;
const Query = query.Query;
const SimCtx = simctx.SimCtx;
const system = schedule.system;

const A = struct {
    pub const kind_id: u16 = 1;
};
const B = struct {
    pub const kind_id: u16 = 2;
};
const Reg = Registry(.{ A, B });

fn rA(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(A)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}
fn rA2(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(A)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}
fn wA(ctx: *SimCtx(Reg), q: *Query(Reg, .{Write(A)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}
// stage0 = {rA(0), rA2(1)} (both read-only, co-stage); stage1 = {wA(2)} (writes A -> conflicts)
const sys = [_]schedule.Sys(Reg){ system(Reg, "rA", rA), system(Reg, "rA2", rA2), system(Reg, "wA", wA) };

test "execPermutation yields a stage-respecting permutation of the execution order" {
    const Sched = schedule.Schedule(Reg, &sys);
    var seen_swap = false;
    var p: u32 = 0;
    while (p < 16) : (p += 1) {
        var out: [3]u16 = undefined;
        execPermutation(Reg, &sys, p, &out);
        // it is a permutation of [0,3)
        var mask: u8 = 0;
        for (out) |s| mask |= @as(u8, 1) << @intCast(s);
        try testing.expectEqual(@as(u8, 0b111), mask);
        // stage_of is non-decreasing along the output (stage order preserved)
        var prev_stage: usize = 0;
        for (out) |s| {
            try testing.expect(Sched.stage_of[s] >= prev_stage);
            prev_stage = Sched.stage_of[s];
        }
        // the writer (system 2, the only stage-1 member) is always last
        try testing.expectEqual(@as(u16, 2), out[2]);
        if (out[0] == 1 and out[1] == 0) seen_swap = true; // stage-0 members got swapped
    }
    try testing.expect(seen_swap); // some perm_index actually permutes the multi-member stage
}

test "enumerate is deterministic and budgeted" {
    const gpa = testing.allocator;
    const a = try enumerate(gpa, 5);
    defer gpa.free(a);
    const b = try enumerate(gpa, 5);
    defer gpa.free(b);
    try testing.expectEqual(@as(usize, 5 + 4), a.len); // 5 perms + 4 cadences
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try testing.expectEqual(std.meta.activeTag(x), std.meta.activeTag(y));
}
