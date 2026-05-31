//! The step function — now scheduler-driven (SPEC §1/§4, PLAN.md Phase 2; F7). Build-order step 6.
//!
//! `step` is still the pure spine `(World, Input) -> World`. Per tick it: clones `prev` (value
//! semantics, D1); advances the tick; applies the tick's *input* commands (the Phase-1 structural path,
//! unchanged); then runs a comptime-scheduled set of systems and drains their command buffers.
//!
//! Systems run in the deterministic order derived by the comptime `Schedule` (stage-grouped, ascending
//! system id within a stage). Each system gets a restricted `SimCtx` and a `Query`; it edits its
//! declared-Write components in place (stage-disjoint, so order-free) and defers structural /
//! cross-entity changes into its own command buffer. After ALL systems run, the single end-of-tick
//! drain concatenates every buffer, stable-sorts by `(system_id, seq)`, and applies them via
//! `mutation.applyCommand`. Because no system observes another's structural change mid-tick, and the
//! drain order is a pure function of (which system, that system's emission count) — never of physical
//! execution order — the result is independent of the order systems ran in (and, in Phase 2b, of
//! threads). See the order-permutation gate in replay.zig.
//!
//! SPEC-text deviation (documented in mutation.zig): the drain key is `(system_id, seq)`, not the
//! literal "(system id, then entity id)" — the latter is not a total order when one system emits two
//! commands at the same entity.

const std = @import("std");
const worldmod = @import("world.zig");
const input = @import("input.zig");
const mutation = @import("mutation.zig");
const schedule = @import("schedule.zig");
const simctx = @import("simctx.zig");
const cmdbuf = @import("command_buffer.zig");
const recorder = @import("recorder.zig");
const sortmod = @import("sort.zig");
const Input = input.Input;
const Sys = schedule.Sys;
const SimCtx = simctx.SimCtx;

/// Advance the simulation one tick. Returns a new World; `prev` is untouched (caller owns both).
pub fn step(
    comptime R: type,
    gpa: std.mem.Allocator,
    prev: worldmod.World(R),
    in: Input,
    comptime systems: []const Sys(R),
) std.mem.Allocator.Error!worldmod.World(R) {
    return stepRec(R, gpa, prev, in, systems, null);
}

/// `step` with an optional provenance Recorder (SPEC §5, §2.6). `rec == null` is the throughput
/// default (no events). A live Recorder records the deterministic event log for this tick WITHOUT
/// changing the returned World or its hash — events are pure side-output. The §9 VOPR re-runs an
/// interesting (seed, inputs) by swapping `null` for a Recorder here.
pub fn stepRec(
    comptime R: type,
    gpa: std.mem.Allocator,
    prev: worldmod.World(R),
    in: Input,
    comptime systems: []const Sys(R),
    rec: ?*recorder.Recorder,
) std.mem.Allocator.Error!worldmod.World(R) {
    // The canonical, comptime-derived stage order.
    const exec = comptime &schedule.Schedule(R, systems).exec_order;
    return stepExec(R, gpa, prev, in, systems, exec, rec);
}

/// `stepRec` with an EXPLICIT system execution order — the full per-tick transform (clone, advance,
/// apply input commands, run systems in `exec` order, drain) parameterized by `exec`. `exec` must be a
/// permutation of `[0, systems.len)` (the VOPR passes stage-respecting permutations as fault injection;
/// `stepRec`/`step` pass the canonical `Schedule.exec_order`). Unlike `runScheduled`, this includes the
/// input-command prologue and the tick advance, so it is the entry the VOPR drives.
pub fn stepExec(
    comptime R: type,
    gpa: std.mem.Allocator,
    prev: worldmod.World(R),
    in: Input,
    comptime systems: []const Sys(R),
    exec: []const u16,
    rec: ?*recorder.Recorder,
) std.mem.Allocator.Error!worldmod.World(R) {
    var w = try prev.clone(gpa);
    errdefer w.deinit(gpa);

    w.tick +%= 1; // wrapping (D2)

    // Input-command path (Phase 1, unchanged): structural verbs applied in canonical order.
    const cmds = try input.canonicalize(gpa, in.commands);
    defer gpa.free(cmds);
    for (cmds) |c| {
        if (mutation.commandToMutation(R, c)) |m| try mutation.apply(R, &w, gpa, m);
    }

    try runScheduled(R, &w, gpa, systems, exec, rec);
    return w;
}

/// Run `systems` in the given `exec` order (a permutation of all system ids), then drain their command
/// buffers deterministically. Production passes the canonical `Schedule.exec_order`; the
/// order-permutation determinism gate (replay.zig) passes within-stage permutations to prove the result
/// is independent of execution order. `exec` must contain each system id exactly once.
pub fn runScheduled(
    comptime R: type,
    w: *worldmod.World(R),
    gpa: std.mem.Allocator,
    comptime systems: []const Sys(R),
    exec: []const u16,
    rec: ?*recorder.Recorder,
) std.mem.Allocator.Error!void {
    // Precondition: `exec` is a permutation of [0, systems.len) — each system runs exactly once. The
    // production caller passes `Schedule.exec_order`; the order-permutation gate passes valid within-
    // stage permutations. Asserted (safe builds) so a malformed `exec` is caught, not a silent OOB.
    std.debug.assert(exec.len == systems.len);
    for (exec) |sid| std.debug.assert(sid < systems.len);

    // `systems.len` is comptime, so this `if` is a comptime-known branch: with no systems the body —
    // which builds and indexes a `[systems.len]` buffer array — is never *analyzed* (a fixed `[0]`
    // array cannot be indexed even on an unreachable path, so an early `return` would not suffice).
    if (systems.len != 0) {
        // The table is structurally frozen during the run phase (structural change is deferred), so
        // the canonical iteration order is computed once and shared by every system's Query.
        const order = try w.table.canonicalOrder(gpa);
        defer gpa.free(order);

        var bufs: [systems.len]cmdbuf.CommandBuffer(R) = undefined;
        inline for (0..systems.len) |i| bufs[i] = cmdbuf.CommandBuffer(R).init(gpa, @intCast(i));
        defer {
            inline for (0..systems.len) |i| bufs[i].deinit();
        }
        // One emitter for the whole tick: recording into `rec` if present, else a no-op. Each SimCtx
        // points at it and supplies its own system_id; `emit_ordinal` defaults to 0 per invocation.
        var emitter: simctx.EventEmitter = if (rec) |r| .{ .recording = r } else .noop;

        for (exec) |sid| {
            var ctx = SimCtx(R){
                .tick = w.tick,
                .rng_root = w.rng_root,
                .system_id = sid,
                .cmd = &bufs[sid],
                .events = &emitter,
            };
            try systems[sid].invoke(&ctx, &w.table, order);
        }

        // End-of-tick drain: gather every buffered command, stable-sort by (system_id, seq), apply.
        // Extracted into `drainAndApply` so the parallel twin (step_par.runScheduledPar) shares the EXACT
        // comparator + apply order — the (system_id, seq) total order can never drift serial vs threaded.
        try drainAndApply(R, w, gpa, bufs[0..]);
    }
}

/// The end-of-tick drain, shared by `runScheduled`, `runScheduledDynamic`, and the parallel twin
/// (`step_par.runScheduledPar`): gather every buffered command, stable-sort by `(system_id, seq)`, and
/// apply in that order. The order is a pure function of (which system, that system's emission seq) —
/// never of physical execution order or thread scheduling. Single-sourced here so the comparator cannot
/// drift between the serial and threaded paths (a determinism hazard).
pub fn drainAndApply(
    comptime R: type,
    w: *worldmod.World(R),
    gpa: std.mem.Allocator,
    bufs: []cmdbuf.CommandBuffer(R),
) std.mem.Allocator.Error!void {
    var all: std.ArrayList(cmdbuf.Command(R)) = .empty;
    defer all.deinit(gpa);
    for (bufs) |*b| try all.appendSlice(gpa, b.list.items);
    const Less = struct {
        fn lt(_: void, a: cmdbuf.Command(R), b: cmdbuf.Command(R)) bool {
            return if (a.system_id != b.system_id) a.system_id < b.system_id else a.seq < b.seq;
        }
    };
    sortmod.sort(cmdbuf.Command(R), all.items, {}, Less.lt);
    for (all.items) |c| try mutation.applyCommand(R, w, gpa, c);
}

// --- runtime-systems path (hot-reload / dlopen) ---------------------------------------------------
//
// `step`/`stepExec`/`runScheduled` take a `comptime systems` slice — the ONLY thing that forces comptime
// is the fixed-size `[systems.len]CommandBuffer` stack array + the inline-for init/drain. A hot-reloaded
// (dlopen'd) system set is only known at RUNTIME, so these siblings take `systems: []const Sys(R)` and
// heap-allocate the command buffers instead. Everything else — clone, tick, input prologue, per-system
// SimCtx, the `(system_id, seq)` drain — is byte-for-byte the same, so for any set expressible at comptime
// the dynamic path produces an identical per-tick stream (asserted in the reload gate). This adds ZERO
// code to the comptime path and does not touch its determinism gate.

/// Runtime twin of `runScheduled` over a runtime `systems` slice (the dlopen entry). `exec` must be a
/// permutation of `[0, systems.len)` — pass `schedule.execOrderDynamic(R, gpa, systems)`.
pub fn runScheduledDynamic(
    comptime R: type,
    w: *worldmod.World(R),
    gpa: std.mem.Allocator,
    systems: []const Sys(R),
    exec: []const u16,
    rec: ?*recorder.Recorder,
) std.mem.Allocator.Error!void {
    std.debug.assert(exec.len == systems.len);
    for (exec) |sid| std.debug.assert(sid < systems.len);
    if (systems.len == 0) return;

    const order = try w.table.canonicalOrder(gpa);
    defer gpa.free(order);

    const bufs = try gpa.alloc(cmdbuf.CommandBuffer(R), systems.len);
    defer gpa.free(bufs);
    for (bufs, 0..) |*b, i| b.* = cmdbuf.CommandBuffer(R).init(gpa, @intCast(i));
    defer for (bufs) |*b| b.deinit();

    var emitter: simctx.EventEmitter = if (rec) |r| .{ .recording = r } else .noop;

    for (exec) |sid| {
        var ctx = SimCtx(R){
            .tick = w.tick,
            .rng_root = w.rng_root,
            .system_id = sid,
            .cmd = &bufs[sid],
            .events = &emitter,
        };
        try systems[sid].invoke(&ctx, &w.table, order);
    }

    try drainAndApply(R, w, gpa, bufs);
}

/// Runtime twin of `stepExec`: the pure `(World, Input) -> World` over a runtime `systems` slice.
pub fn stepDynamic(
    comptime R: type,
    gpa: std.mem.Allocator,
    prev: worldmod.World(R),
    in: Input,
    systems: []const Sys(R),
    exec: []const u16,
    rec: ?*recorder.Recorder,
) std.mem.Allocator.Error!worldmod.World(R) {
    var w = try prev.clone(gpa);
    errdefer w.deinit(gpa);
    w.tick +%= 1;
    const cmds = try input.canonicalize(gpa, in.commands);
    defer gpa.free(cmds);
    for (cmds) |c| {
        if (mutation.commandToMutation(R, c)) |m| try mutation.apply(R, &w, gpa, m);
    }
    try runScheduledDynamic(R, &w, gpa, systems, exec, rec);
    return w;
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("registry.zig").Registry;
const query = @import("query.zig");
const Read = query.Read;
const Write = query.Write;
const Query = query.Query;
const system = schedule.system;

const Position = struct {
    x: fpz.Fixed,
    y: fpz.Fixed,
    pub const kind_id: u16 = 1;
};
const Velocity = struct {
    dx: fpz.Fixed,
    dy: fpz.Fixed,
    pub const kind_id: u16 = 2;
};
const Reg = Registry(.{ Position, Velocity });
const W = worldmod.World(Reg);

// in-place: integrate Position by Velocity (reads Velocity, writes Position)
fn moveSystem(ctx: *SimCtx(Reg), q: *Query(Reg, .{ Read(Velocity), Write(Position) })) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| {
        const v = row.read(Velocity).*;
        const p = row.write(Position);
        p.x = p.x.addSat(v.dx);
        p.y = p.y.addSat(v.dy);
    }
}
// in-place: jitter Velocity from keyed RNG (writes Velocity) — disjoint from Position
fn jitterSystem(ctx: *SimCtx(Reg), q: *Query(Reg, .{Write(Velocity)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| {
        const e = row.entity();
        row.write(Velocity).dx = ctx.rngFixed(e.index, 0, fpz.Fixed.NEG_ONE, fpz.Fixed.ONE);
    }
}
// deferred structural: spawn one new entity per tick (via the command buffer)
fn spawnerSystem(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(Position)})) std.mem.Allocator.Error!void {
    if (q.next()) |_| try ctx.cmd.spawn(); // at most one spawn/tick (first matched entity)
}

const move_only = [_]Sys(Reg){system(Reg, "move", moveSystem)};
const move_and_spawn = [_]Sys(Reg){ system(Reg, "move", moveSystem), system(Reg, "spawner", spawnerSystem) };
const move_and_jitter = [_]Sys(Reg){ system(Reg, "move", moveSystem), system(Reg, "jitter", jitterSystem) };

fn seedWorld(gpa: std.mem.Allocator, n: u32) !W {
    var w = W.init(0xC0FFEE);
    errdefer w.deinit(gpa);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const e = try w.spawn(gpa);
        w.add(e, Position, .{ .x = fpz.Fixed.ZERO, .y = fpz.Fixed.ZERO });
        w.add(e, Velocity, .{ .dx = fpz.Fixed.ONE, .dy = fpz.Fixed.fromInt(2) });
    }
    return w;
}

test "step is pure: same (world, input) yields identical successors; prev untouched; tick advances" {
    const gpa = testing.allocator;
    var w0 = try seedWorld(gpa, 3);
    defer w0.deinit(gpa);
    const before = (try w0.digest(gpa)).hash;

    const empty = Input{ .tick = 0, .commands = &.{} };
    var a = try step(Reg, gpa, w0, empty, &move_only);
    defer a.deinit(gpa);
    var b = try step(Reg, gpa, w0, empty, &move_only);
    defer b.deinit(gpa);

    try testing.expectEqual((try a.digest(gpa)).hash, (try b.digest(gpa)).hash); // pure
    try testing.expectEqual(before, (try w0.digest(gpa)).hash); // prev untouched
    try testing.expectEqual(@as(u64, 1), a.tick);
    // move integrated Position by Velocity(1,2): entity 0 now at (1,2)
    try testing.expectEqual(@as(i64, 1), a.get(.{ .index = 0, .generation = 0 }, Position).?.x.toInt());
    try testing.expectEqual(@as(i64, 2), a.get(.{ .index = 0, .generation = 0 }, Position).?.y.toInt());
}

test "a system's deferred spawn appears after the end-of-tick drain" {
    const gpa = testing.allocator;
    var w0 = try seedWorld(gpa, 2);
    defer w0.deinit(gpa);

    var w1 = try step(Reg, gpa, w0, .{ .tick = 1, .commands = &.{} }, &move_and_spawn);
    defer w1.deinit(gpa);
    // 2 seeded + 1 deferred spawn = 3
    try testing.expectEqual(@as(usize, 3), w1.table.rowCount());
}

test "in-place writes are stage-disjoint and land; jitter+move compose deterministically" {
    const gpa = testing.allocator;
    // move reads Velocity & writes Position; jitter writes Velocity -> conflict -> 2 stages
    const Sched = schedule.Schedule(Reg, &move_and_jitter);
    try testing.expectEqual(@as(usize, 2), Sched.stage_count);

    var w0 = try seedWorld(gpa, 2);
    defer w0.deinit(gpa);
    var a = try step(Reg, gpa, w0, .{ .tick = 1, .commands = &.{} }, &move_and_jitter);
    defer a.deinit(gpa);
    var b = try step(Reg, gpa, w0, .{ .tick = 1, .commands = &.{} }, &move_and_jitter);
    defer b.deinit(gpa);
    try testing.expectEqual((try a.digest(gpa)).hash, (try b.digest(gpa)).hash);
}

test "input-command path still drives spawn/despawn under the new step" {
    const gpa = testing.allocator;
    var w0 = W.init(1);
    defer w0.deinit(gpa);
    const spawn3 = [_]input.Command{
        .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 },
        .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 },
        .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 },
    };
    var w1 = try step(Reg, gpa, w0, .{ .tick = 1, .commands = &spawn3 }, &move_only);
    defer w1.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), w1.table.rowCount());
}

test "multi-tick run is deterministic across independent executions" {
    const gpa = testing.allocator;
    const Runner = struct {
        fn run(g: std.mem.Allocator) !u64 {
            var w = try seedWorld(g, 3);
            var t: u64 = 0;
            while (t < 15) : (t += 1) {
                const next = try step(Reg, g, w, .{ .tick = t + 1, .commands = &.{} }, &move_and_spawn);
                w.deinit(g);
                w = next;
            }
            const h = (try w.digest(g)).hash;
            w.deinit(g);
            return h;
        }
    };
    try testing.expectEqual(try Runner.run(gpa), try Runner.run(gpa));
}

// --- Phase-2 review coverage: (system_id, seq) drain order, deferred ops, empty schedule ---

// three read-only systems that each defer a set of Velocity.dx to a distinct value — mutually
// non-conflicting (no in-place writes) so they share ONE stage; the drain's (system_id, seq) order
// decides the winner (highest system_id last).
fn setVelA(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(Position)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| try ctx.cmd.set(row.entity(), Velocity, .{ .dx = fpz.Fixed.fromInt(1), .dy = fpz.Fixed.ZERO });
}
fn setVelB(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(Position)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| try ctx.cmd.set(row.entity(), Velocity, .{ .dx = fpz.Fixed.fromInt(2), .dy = fpz.Fixed.ZERO });
}
fn setVelC(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(Position)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| try ctx.cmd.set(row.entity(), Velocity, .{ .dx = fpz.Fixed.fromInt(3), .dy = fpz.Fixed.ZERO });
}
fn velAdder(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(Position)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| try ctx.cmd.add(row.entity(), Velocity, .{ .dx = fpz.Fixed.ONE, .dy = fpz.Fixed.ZERO });
}
fn despawnFirst(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(Position)})) std.mem.Allocator.Error!void {
    if (q.next()) |row| try ctx.cmd.despawn(row.entity());
}
fn addToFirst(ctx: *SimCtx(Reg), q: *Query(Reg, .{Read(Position)})) std.mem.Allocator.Error!void {
    if (q.next()) |row| try ctx.cmd.add(row.entity(), Velocity, .{ .dx = fpz.Fixed.ONE, .dy = fpz.Fixed.ZERO });
}

const setters = [_]Sys(Reg){ system(Reg, "setA", setVelA), system(Reg, "setB", setVelB), system(Reg, "setC", setVelC) };
const adder_only = [_]Sys(Reg){system(Reg, "adder", velAdder)};
const race = [_]Sys(Reg){ system(Reg, "despawnFirst", despawnFirst), system(Reg, "addToFirst", addToFirst) };
const no_systems = [_]Sys(Reg){};

test "(system_id, seq) drain order: highest system_id wins, invariant to within-stage exec order" {
    const gpa = testing.allocator;
    // all three setters are read-only -> no conflict -> a single 3-member stage
    try testing.expectEqual(@as(usize, 1), schedule.Schedule(Reg, &setters).stage_count);

    var w0 = try seedWorld(gpa, 2);
    defer w0.deinit(gpa);

    var a = try w0.clone(gpa);
    defer a.deinit(gpa);
    a.tick +%= 1;
    try runScheduled(Reg, &a, gpa, &setters, &[_]u16{ 0, 1, 2 }, null); // canonical

    var b = try w0.clone(gpa);
    defer b.deinit(gpa);
    b.tick +%= 1;
    try runScheduled(Reg, &b, gpa, &setters, &[_]u16{ 2, 0, 1 }, null); // within-stage permutation

    try testing.expectEqual((try a.digest(gpa)).hash, (try b.digest(gpa)).hash);
    // setC (highest system_id) applied last -> wins
    try testing.expectEqual(@as(i64, 3), a.get(.{ .index = 0, .generation = 0 }, Velocity).?.dx.toInt());
    try testing.expectEqual(@as(i64, 3), a.get(.{ .index = 1, .generation = 0 }, Velocity).?.dx.toInt());
}

test "deferred add drives through the scheduler + drain" {
    const gpa = testing.allocator;
    var w = W.init(0);
    defer w.deinit(gpa);
    const e0 = try w.spawn(gpa);
    const e1 = try w.spawn(gpa);
    w.add(e0, Position, .{ .x = fpz.Fixed.ZERO, .y = fpz.Fixed.ZERO });
    w.add(e1, Position, .{ .x = fpz.Fixed.ZERO, .y = fpz.Fixed.ZERO });
    try testing.expect(!w.has(e0, Velocity));

    var w1 = try step(Reg, gpa, w, .{ .tick = 1, .commands = &.{} }, &adder_only);
    defer w1.deinit(gpa);
    try testing.expect(w1.has(e0, Velocity)); // deferred add landed at the drain
    try testing.expectEqual(@as(i64, 1), w1.get(e1, Velocity).?.dx.toInt());
}

test "deferred despawn racing a deferred add to the same entity is deterministic" {
    const gpa = testing.allocator;
    var w0 = try seedWorld(gpa, 2);
    defer w0.deinit(gpa);
    // despawnFirst (system_id 0) drains before addToFirst (1): entity 0 is despawned, the add no-ops.
    var a = try step(Reg, gpa, w0, .{ .tick = 1, .commands = &.{} }, &race);
    defer a.deinit(gpa);
    var b = try step(Reg, gpa, w0, .{ .tick = 1, .commands = &.{} }, &race);
    defer b.deinit(gpa);
    try testing.expectEqual((try a.digest(gpa)).hash, (try b.digest(gpa)).hash); // deterministic
    try testing.expect(!a.isLive(.{ .index = 0, .generation = 0 })); // entity 0 despawned
}

test "stepDynamic over a RUNTIME systems slice matches stepExec over the comptime set, tick for tick" {
    const gpa = testing.allocator;
    const exec_ct = comptime &schedule.Schedule(Reg, &move_and_jitter).exec_order;
    const exec_rt = try schedule.execOrderDynamic(Reg, gpa, &move_and_jitter);
    defer gpa.free(exec_rt);
    try testing.expectEqualSlices(u16, exec_ct, exec_rt);

    var a = try seedWorld(gpa, 3);
    defer a.deinit(gpa);
    var b = try seedWorld(gpa, 3);
    defer b.deinit(gpa);
    var t: u64 = 0;
    while (t < 6) : (t += 1) {
        const na = try stepExec(Reg, gpa, a, .{ .tick = t + 1, .commands = &.{} }, &move_and_jitter, exec_ct, null);
        a.deinit(gpa);
        a = na;
        const nb = try stepDynamic(Reg, gpa, b, .{ .tick = t + 1, .commands = &.{} }, &move_and_jitter, exec_rt, null);
        b.deinit(gpa);
        b = nb;
        try testing.expectEqual((try a.digest(gpa)).hash, (try b.digest(gpa)).hash); // runtime path is faithful
    }
}

test "empty systems list: schedule is empty and the input path still runs" {
    const gpa = testing.allocator;
    try testing.expectEqual(@as(usize, 0), schedule.Schedule(Reg, &no_systems).stage_count);
    try testing.expectEqual(@as(usize, 0), schedule.Schedule(Reg, &no_systems).exec_order.len);

    var w0 = W.init(1);
    defer w0.deinit(gpa);
    const spawn2 = [_]input.Command{
        .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 },
        .{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 },
    };
    var w1 = try step(Reg, gpa, w0, .{ .tick = 1, .commands = &spawn2 }, &no_systems);
    defer w1.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), w1.table.rowCount()); // input spawns applied, no systems
}
