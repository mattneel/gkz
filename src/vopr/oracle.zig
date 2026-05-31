//! The unified oracle / defect abstraction (SPEC §9, PLAN.md Phase 4). Build-order steps 3 + 5.
//!
//! SPEC §9's central thesis — "a crash, an assertion failure, an invariant violation, and a hash
//! divergence are all the same event class: a reproducible defect with an exact location" — is realized
//! as ONE `Oracle(R)` (a check `eval(*const Run) ?Defect`) and ONE `Defect(R)` (`{seed, tick, kind,
//! oracle, detail}`). The sweep/minimize/provenance machinery downstream is identical for every kind,
//! so adding a check later (§8 temporal properties, cross-arch divergence) is just another oracle.
//!
//! Phase 4 ships two constructors: `invariant` (a predicate over the World, reporting the first tick it
//! flips) and `divergence` (re-run under a fault injection and compare the per-tick hash stream).
//! `.trap` (a crash/safety-trap) is realized across the process boundary by the build-mode matrix, not
//! in-process (Zig has no catchable panic) — its `Detail` is pre-shaped for the §13 supervisor.

const std = @import("std");
const runmod = @import("run.zig");
const inject = @import("inject.zig");
const worldmod = @import("../world.zig");
const snapshotmod = @import("../snapshot.zig");
const schedule = @import("../schedule.zig");
const Entity = @import("../entity.zig").Entity;
const Run = runmod.Run;
const Sys = schedule.Sys;

pub fn Defect(comptime R: type) type {
    _ = R;
    return struct {
        pub const Kind = enum(u8) { invariant, divergence, trap, _ };
        /// Decoupled from Kind (NOT a union(Kind)) — a plain payload describing the location.
        pub const Detail = union(enum) {
            none,
            entity: Entity,
            // A divergence is located to (seed, tick) only; per-component / per-system bisection of WHICH
            // write diverged is deferred (needs the §7 typed-component diff). `ref`/`got` are the
            // whole-World hashes at the divergent tick.
            hashes: struct { ref: u64, got: u64 },
            trap: struct { signal: u32, last_tick: u64 },
        };
        seed: u64,
        tick: u64,
        kind: Kind,
        oracle: []const u8,
        detail: Detail,
    };
}

pub fn Oracle(comptime R: type) type {
    return struct {
        const Self = @This();
        name: []const u8,
        kind: Defect(R).Kind,
        ctx: *anyopaque,
        eval_fn: *const fn (ctx: *anyopaque, run: *const Run(R), gpa: std.mem.Allocator) std.mem.Allocator.Error!?Defect(R),

        pub fn eval(self: Self, run: *const Run(R), gpa: std.mem.Allocator) std.mem.Allocator.Error!?Defect(R) {
            return self.eval_fn(self.ctx, run, gpa);
        }
    };
}

/// First index where the two per-tick hash streams differ (the §9 (seed, tick) location), or null.
pub fn firstDivergentTick(ref: []const u64, got: []const u64) ?usize {
    const n = @min(ref.len, got.len);
    for (0..n) |i| {
        if (ref[i] != got[i]) return i;
    }
    if (ref.len != got.len) return n;
    return null;
}

/// An oracle that checks a World predicate at every tick and reports the FIRST tick it flips. `pred`
/// returns the offending `Entity` (or null if the invariant holds). Reconstructs each tick via
/// snapshot+replay (O(T^2) at interval=1 — on-demand, off the throughput path).
pub fn invariant(
    comptime R: type,
    comptime systems: []const Sys(R),
    comptime name: []const u8,
    comptime pred: fn (*const worldmod.World(R)) ?Entity,
) Oracle(R) {
    const Impl = struct {
        fn eval(ctx: *anyopaque, run: *const Run(R), gpa: std.mem.Allocator) std.mem.Allocator.Error!?Defect(R) {
            _ = ctx;
            var t: usize = 1;
            while (t <= run.inputs.len) : (t += 1) {
                var w = run.worldAt(gpa, systems, t) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable, // base is a kernel-produced valid snapshot; replay uses step
                };
                defer w.deinit(gpa);
                if (pred(&w)) |ent| {
                    return Defect(R){ .seed = run.seed, .tick = @intCast(t), .kind = .invariant, .oracle = name, .detail = .{ .entity = ent } };
                }
            }
            return null;
        }
    };
    return .{ .name = name, .kind = .invariant, .ctx = &unused_ctx, .eval_fn = Impl.eval };
}

var unused_ctx: u8 = 0; // a real (ignored) ctx for oracles that carry no data

/// An oracle that re-runs the same (seed, inputs) under a fault injection and reports the first tick
/// whose World hash differs from the reference run — SPEC §9's "fault injection must not change
/// results". A non-null result is ALWAYS a real defect (a genuine determinism violation).
pub fn divergence(
    comptime R: type,
    comptime systems: []const Sys(R),
    comptime name: []const u8,
    inj: *const inject.Injection,
) Oracle(R) {
    const Impl = struct {
        fn eval(ctx: *anyopaque, run: *const Run(R), gpa: std.mem.Allocator) std.mem.Allocator.Error!?Defect(R) {
            const injection: *const inject.Injection = @ptrCast(@alignCast(ctx));
            const exec_canon = comptime &schedule.Schedule(R, systems).exec_order;
            const w0 = snapshotmod.restore(R, gpa, run.base) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable, // run.base is a kernel-produced valid snapshot
            };
            var variant = switch (injection.*) {
                .exec_perm => |idx| blk: {
                    var buf: [systems.len]u16 = undefined;
                    inject.execPermutation(R, systems, idx, &buf);
                    break :blk try runmod.captureStream(R, gpa, w0, run.inputs, systems, &buf, null);
                },
                .cadence => |k| runmod.captureStreamCadence(R, gpa, w0, run.inputs, systems, exec_canon, k) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable, // in-run snapshots are kernel-produced
                },
            };
            defer gpa.free(variant.hashes);
            defer variant.final.deinit(gpa);
            if (firstDivergentTick(run.hashes, variant.hashes)) |i| {
                // Guard the detail read: a length-mismatch makes `i` index-equal to the shorter len.
                const detail: Defect(R).Detail = if (i < run.hashes.len and i < variant.hashes.len)
                    .{ .hashes = .{ .ref = run.hashes[i], .got = variant.hashes[i] } }
                else
                    .none;
                return Defect(R){
                    .seed = run.seed,
                    .tick = @intCast(i + 1), // hashes[i] is the world at tick i+1
                    .kind = .divergence,
                    .oracle = name,
                    .detail = detail,
                };
            }
            return null;
        }
    };
    return .{ .name = name, .kind = .divergence, .ctx = @constCast(inj), .eval_fn = Impl.eval };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "firstDivergentTick: identical -> null; differ-at-k -> k; length mismatch -> shorter len" {
    try testing.expectEqual(@as(?usize, null), firstDivergentTick(&.{ 1, 2, 3 }, &.{ 1, 2, 3 }));
    try testing.expectEqual(@as(?usize, 1), firstDivergentTick(&.{ 1, 2, 3 }, &.{ 1, 9, 3 }));
    try testing.expectEqual(@as(?usize, 0), firstDivergentTick(&.{1}, &.{9}));
    try testing.expectEqual(@as(?usize, 2), firstDivergentTick(&.{ 1, 2, 3 }, &.{ 1, 2 }));
}

const fpz = @import("fpz");
const Registry = @import("../registry.zig").Registry;
const query = @import("../query.zig");
const simctx = @import("../simctx.zig");
const generator = @import("generator.zig");
const Read = query.Read;
const Write = query.Write;
const Query = query.Query;
const SimCtx = simctx.SimCtx;
const system = schedule.system;
const input = @import("../input.zig");

const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 1;
};
const OReg = Registry(.{Health});
const OW = worldmod.World(OReg);
// a system that decrements every entity's hp each tick (drives it negative eventually)
fn drainSystem(ctx: *SimCtx(OReg), q: *Query(OReg, .{Write(Health)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Health).hp -= 1;
}
const osys = [_]Sys(OReg){system(OReg, "drain", drainSystem)};
// invariant: hp must stay >= 0 (uses const column accessors — no mutation)
fn hpNonNegative(w: *const OW) ?Entity {
    const owners = w.table.owners();
    const masks = w.table.masks();
    const col = w.table.column(OReg.indexOf(Health));
    const hp_bit = OReg.bitOf(Health);
    for (owners, 0..) |e, row| {
        if ((masks[row] & hp_bit) != 0 and col[row].hp < 0) return e;
    }
    return null;
}

test "invariant oracle reports the first tick a predicate flips" {
    const gpa = testing.allocator;
    var w0 = OW.init(0);
    errdefer w0.deinit(gpa);
    const e = try w0.spawn(gpa);
    w0.add(e, Health, .{ .hp = 3 }); // hp 3 -> goes negative at tick 4

    const gen = generator.idleGen(OReg); // no input; the system drives it for 6 ticks
    var run = try runmod.buildRun(OReg, gpa, &osys, w0, 0, gen, 6);
    defer run.deinit(gpa);

    const orc = invariant(OReg, &osys, "hp>=0", hpNonNegative);
    const defect = (try orc.eval(&run, gpa)).?;
    try testing.expectEqual(Defect(OReg).Kind.invariant, defect.kind);
    try testing.expectEqual(@as(u64, 4), defect.tick); // hp: t1=2,t2=1,t3=0,t4=-1 -> first violation tick 4
    try testing.expectEqual(e, defect.detail.entity);
}
