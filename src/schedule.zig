//! The deterministic scheduler (SPEC §4, PLAN.md Phase 2; seam S1, F4). Build-order step 5.
//!
//! A system is registered with `system(R, name, fn)`, which extracts the system's access set from the
//! type of its `Query` parameter (the single source of truth — §7 reflection reads the same `access`)
//! and builds a uniform invoke thunk. From the systems' access masks the scheduler derives — entirely
//! at comptime, never from runtime timing (§4) — a partition into STAGES: each stage is a set of
//! systems that pairwise do not conflict, so a stage is provably safe to run in any order (and later,
//! in parallel — Phase 2b). Conflict is the PLAN S1 primitive: a write that intersects another
//! system's reads-or-writes. `with`/`without` are pure row filters and never cause a conflict.
//!
//! Greedy first-fit in registration order is non-minimal (optimal coloring is NP-hard) but
//! deterministic and legible; `computeStageOf` is swappable without touching any consumer.

const std = @import("std");
const query = @import("query.zig");
const simctx = @import("simctx.zig");
const storage = @import("storage.zig");

/// Two access sets conflict iff one's writes intersect the other's reads or writes.
pub fn conflict(comptime R: type, a: query.Access(R), b: query.Access(R)) bool {
    return (a.write & (b.read | b.write)) != 0 or (b.write & (a.read | a.write)) != 0;
}

/// A registered system: its name, its folded access set, and a uniform invoke thunk that builds the
/// concrete Query and calls the system fn.
pub fn Sys(comptime R: type) type {
    return struct {
        name: []const u8,
        access: query.Access(R),
        invoke: *const fn (*simctx.SimCtx(R), *storage.Table(R), []const u32) std.mem.Allocator.Error!void,
    };
}

/// Register a system. `f` must be `fn(*SimCtx(R), *Query(R, markers)) Allocator.Error!void`; its access
/// set is read off the Query parameter type at comptime.
pub fn system(comptime R: type, comptime name: []const u8, comptime f: anytype) Sys(R) {
    const fn_info = @typeInfo(@TypeOf(f)).@"fn";
    if (fn_info.params.len != 2) @compileError("a system '" ++ name ++ "' must take (*SimCtx(R), *Query(R, ...))");
    const P1 = fn_info.params[1].type orelse @compileError("system '" ++ name ++ "': 2nd parameter must be a concrete *Query(R, ...) (no anytype)");
    const p1_info = @typeInfo(P1);
    if (p1_info != .pointer) @compileError("system '" ++ name ++ "': 2nd parameter must be a POINTER to Query(R, ...), got " ++ @typeName(P1));
    const QType = p1_info.pointer.child;
    if (!@hasDecl(QType, "access")) @compileError("system '" ++ name ++ "': 2nd parameter must be *Query(R, ...), got *" ++ @typeName(QType));
    const thunk = struct {
        fn invoke(ctx: *simctx.SimCtx(R), table: *storage.Table(R), order: []const u32) std.mem.Allocator.Error!void {
            var q = QType.init(table, order);
            return f(ctx, &q);
        }
    }.invoke;
    return .{ .name = name, .access = QType.access, .invoke = thunk };
}

/// Greedy first-fit stage assignment in registration order. Pure function of (conflict matrix, order).
fn computeStageOf(comptime R: type, comptime systems: []const Sys(R)) [systems.len]usize {
    var so: [systems.len]usize = undefined;
    for (0..systems.len) |i| {
        var st: usize = 0;
        outer: while (true) : (st += 1) {
            for (0..i) |j| {
                if (so[j] == st and conflict(R, systems[i].access, systems[j].access)) continue :outer;
            }
            break;
        }
        so[i] = st;
    }
    return so;
}

/// Canonical flattened execution order: system ids stable-sorted by stage (ascending), ties (within a
/// stage) keeping ascending system id. This is the deterministic order `step` runs systems in.
fn computeExecOrder(comptime R: type, comptime systems: []const Sys(R), comptime stage_of: [systems.len]usize) [systems.len]u16 {
    var ids: [systems.len]u16 = undefined;
    for (0..systems.len) |i| ids[i] = @intCast(i);
    var i: usize = 1;
    while (i < systems.len) : (i += 1) {
        var j = i;
        while (j > 0 and stage_of[ids[j - 1]] > stage_of[ids[j]]) : (j -= 1) {
            const tmp = ids[j - 1];
            ids[j - 1] = ids[j];
            ids[j] = tmp;
        }
    }
    return ids;
}

/// The comptime-derived schedule for a fixed set of systems.
pub fn Schedule(comptime R: type, comptime systems: []const Sys(R)) type {
    return struct {
        /// stage_of[system_id] = the stage that system runs in.
        pub const stage_of: [systems.len]usize = computeStageOf(R, systems);
        pub const stage_count: usize = blk: {
            var m: usize = 0;
            for (stage_of) |x| if (x + 1 > m) {
                m = x + 1;
            };
            break :blk m;
        };
        /// The flat, stage-grouped, ascending-within-stage system execution order.
        pub const exec_order: [systems.len]u16 = computeExecOrder(R, systems, stage_of);
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("registry.zig").Registry;
const Read = query.Read;
const Write = query.Write;
const With = query.With;
const Without = query.Without;
const Query = query.Query;
const SimCtx = simctx.SimCtx;

const Position = struct {
    x: i64,
    pub const kind_id: u16 = 1;
};
const Velocity = struct {
    y: i64,
    pub const kind_id: u16 = 2;
};
const Tag = struct {
    pub const kind_id: u16 = 3;
};
const Reg = Registry(.{ Position, Velocity, Tag });

fn mk(read: Reg.Mask, write: Reg.Mask) query.Access(Reg) {
    return .{ .read = read, .write = write };
}

test "conflict truth table" {
    const bP = Reg.bitOf(Position);
    const bV = Reg.bitOf(Velocity);
    try testing.expect(!conflict(Reg, mk(bP, 0), mk(bP, 0))); // read/read disjoint of writes -> no
    try testing.expect(conflict(Reg, mk(0, bP), mk(bP, 0))); // WAR -> yes
    try testing.expect(conflict(Reg, mk(bP, 0), mk(0, bP))); // RAW -> yes
    try testing.expect(conflict(Reg, mk(0, bP), mk(0, bP))); // WAW -> yes
    try testing.expect(!conflict(Reg, mk(0, bP), mk(bV, 0))); // disjoint components -> no
    // with/without never enter conflict
    try testing.expect(!conflict(Reg, .{ .with = Reg.bitOf(Tag) }, .{ .without = Reg.bitOf(Tag) }));
}

fn sysReadP(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(Position)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}
fn sysReadP2(ctx: *SimCtx(Reg), q: *Query(Reg, .{ Read(Position), With(Tag) })) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}
fn sysWriteP(ctx: *SimCtx(Reg), q: *Query(Reg, .{Write(Position)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}
fn sysReadV(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(Velocity)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
}

test "system() extracts the access set from the Query parameter type" {
    const s = system(Reg, "writeP", sysWriteP);
    try testing.expectEqual(Reg.bitOf(Position), s.access.write);
    try testing.expectEqual(@as(Reg.Mask, 0), s.access.read);
    try testing.expectEqualStrings("writeP", s.name);
}

// systems arrays are file-scope consts so `&array` is a comptime pointer (a `&local` is not).
const systems_stage = [_]Sys(Reg){
    system(Reg, "rP", sysReadP),
    system(Reg, "rP2", sysReadP2),
    system(Reg, "rV", sysReadV),
    system(Reg, "wP", sysWriteP),
};
const systems_inv = [_]Sys(Reg){
    system(Reg, "wP", sysWriteP),
    system(Reg, "rP", sysReadP),
    system(Reg, "rV", sysReadV),
    system(Reg, "wP2", sysWriteP),
};

test "stage assignment: read-only systems share a stage; a writer is serialized after" {
    const Sched = Schedule(Reg, &systems_stage);
    // rP, rP2, rV are mutually non-conflicting -> stage 0; wP conflicts with rP/rP2 -> stage 1
    try testing.expectEqual(@as(usize, 0), Sched.stage_of[0]);
    try testing.expectEqual(@as(usize, 0), Sched.stage_of[1]);
    try testing.expectEqual(@as(usize, 0), Sched.stage_of[2]);
    try testing.expectEqual(@as(usize, 1), Sched.stage_of[3]);
    try testing.expectEqual(@as(usize, 2), Sched.stage_count);
    // exec order is stage-grouped, ascending system id within a stage
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3 }, &Sched.exec_order);
}

test "invariant: no two systems sharing a stage conflict (the parallel-safety witness)" {
    const Sched = Schedule(Reg, &systems_inv);
    for (0..systems_inv.len) |a| {
        for (a + 1..systems_inv.len) |b| {
            if (Sched.stage_of[a] == Sched.stage_of[b]) {
                try testing.expect(!conflict(Reg, systems_inv[a].access, systems_inv[b].access));
            }
        }
    }
}
