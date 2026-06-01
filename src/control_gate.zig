//! The reload/migrate control-trigger WITNESS (PLAN.md §16.12): a reload and a schema migration, driven
//! LIVE by an exogenous trigger and CAPTURED into a ControlSchedule, then REPLAYED from that schedule —
//! bit-identically, across build modes AND the cross-arch matrix (folded into root's 3-mode test and the
//! `zig build cross` run on aarch64/s390x/arm/mips). Proves: reproducibility of reload+migrate from the
//! captured triple (seed, inputs, schedule); the live trigger is NEVER re-invoked on replay (a tamper
//! counter stays put); an exogenous clock-reading decider influences only WHICH ops are captured, never
//! replay. No `std.debug.print` in a test body; pins recomputed via the guarded `dumpPin`.

const std = @import("std");
const input = @import("input.zig");
const control = @import("control.zig");
const reload = @import("reload.zig");
const migrate = @import("migrate.zig");
const serialize = @import("serialize.zig");
const worldmod = @import("world.zig");
const registry = @import("registry.zig");
const schedule = @import("schedule.zig");
const simctx = @import("simctx.zig");
const query = @import("query.zig");

const testing = std.testing;
const Read = query.Read;
const Write = query.Write;
const Query = query.Query;
const Sys = schedule.Sys;
const SimCtx = simctx.SimCtx;

// --- two schema versions + a v1→v2 migration (mirrors migrate/gate.zig) ----------------------------

const Pos = struct {
    x: i32,
    y: i32,
    pub const kind_id: u16 = 1;
};
const Vel = struct {
    dx: i32,
    dy: i32,
    pub const kind_id: u16 = 2;
};
const Tag = struct {
    t: u32,
    pub const kind_id: u16 = 3;
};
const RV1 = registry.Registry(.{ Pos, Vel });
const RV2 = registry.Registry(.{ Pos, Vel, Tag });
const WV1 = worldmod.World(RV1);
const WV2 = worldmod.World(RV2);

/// v1→v2: add the Tag component (default t=0). target fingerprint pinned to R_v2's current schema.
const m_1_2 = migrate.Migration{
    .from_version = 1,
    .to_version = 2,
    .ops = &.{.{ .add_kind = .{ .kind_id = 3, .default_bytes = &.{ 0, 0, 0, 0 } } }},
    .target_fingerprint = migrate.currentFingerprint(RV2),
};
const chain_1_2 = migrate.Chain{ .migrations = &.{m_1_2} };

// --- systems: two same-R sets for V1 (the reload swap), one for V2 ---------------------------------

fn moveV1(ctx: *SimCtx(RV1), q: *Query(RV1, .{ Read(Vel), Write(Pos) })) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |r| {
        const v = r.read(Vel).*;
        const p = r.write(Pos);
        p.x += v.dx;
        p.y += v.dy;
    }
}
fn jitterV1(ctx: *SimCtx(RV1), q: *Query(RV1, .{Write(Vel)})) std.mem.Allocator.Error!void {
    while (q.next()) |r| {
        const e = r.entity();
        r.write(Vel).dx += @as(i32, @intCast(ctx.rng(e.index, 0) % 3)) - 1; // keyed RNG → deterministic jitter
    }
}
fn moveV2(ctx: *SimCtx(RV2), q: *Query(RV2, .{ Read(Vel), Write(Pos) })) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |r| {
        const v = r.read(Vel).*;
        const p = r.write(Pos);
        p.x += v.dx;
        p.y += v.dy;
    }
}
const set0_v1 = [_]Sys(RV1){schedule.system(RV1, "move", moveV1)}; // plain move
const set1_v1 = [_]Sys(RV1){ schedule.system(RV1, "move", moveV1), schedule.system(RV1, "jitter", jitterV1) }; // move + jitter (diverges)
const set0_v2 = [_]Sys(RV2){schedule.system(RV2, "move", moveV2)};

const srcs_v1 = [_]reload.SystemSource(RV1){ reload.inProcessSource(RV1, &set0_v1), reload.inProcessSource(RV1, &set1_v1) };
const srcs_v2 = [_]reload.SystemSource(RV2){reload.inProcessSource(RV2, &set0_v2)};
const setsV1 = control.SetTable(RV1){ .sources = &srcs_v1 };
const setsV2 = control.SetTable(RV2){ .sources = &srcs_v2 };

const T1: u64 = 3; // reload here
const T2: u64 = 6; // migrate here
const TOTAL: u64 = 10;

fn seedV1(gpa: std.mem.Allocator) !WV1 {
    var w = WV1.init(0xC0DE);
    errdefer w.deinit(gpa);
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const e = try w.spawn(gpa);
        w.add(e, Pos, .{ .x = 0, .y = 0 });
        w.add(e, Vel, .{ .dx = @intCast(1 + i), .dy = 2 });
    }
    return w;
}

const no_inputs = [_]input.Input{};
const FROZEN = [_]control.ControlEvent{
    .{ .at_tick = T1, .op = .{ .reload = 1 } },
    .{ .at_tick = T2, .op = .{ .migrate = 0 } },
};

// --- sessions: a concrete V1→V2 phase walk (replay and live capture) --------------------------------

/// REPLAY a V1→V2 session from a frozen schedule; returns the final V2 World digest. Folds the per-tick
/// stream if `stream != null`.
fn replaySession(gpa: std.mem.Allocator, sched: control.ControlSchedule, stream: ?*std.hash.XxHash64) !u64 {
    const w1 = try seedV1(gpa);
    const oc1 = try control.runWithControl(RV1, gpa, w1, &no_inputs, 0, sched, 0, setsV1, 0, TOTAL, stream, null);
    switch (oc1) {
        .completed => |w| {
            var ww = w;
            defer ww.deinit(gpa);
            return (try ww.digest(gpa)).hash; // (no migrate scheduled — not our case, but total)
        },
        .migrate => |m| {
            defer {
                var s = m.pre;
                s.deinit(gpa);
            }
            std.debug.assert(m.migration_id == 0);
            std.debug.assert(m.at_tick == T2);
            const w2 = try migrate.migrateWorld(RV2, gpa, chain_1_2, m.pre.bytes);
            const oc2 = try control.runWithControl(RV2, gpa, w2, &no_inputs, m.next_inputs_from, sched, m.resume_from, setsV2, 0, TOTAL, stream, null);
            switch (oc2) {
                .completed => |w| {
                    var ww = w;
                    defer ww.deinit(gpa);
                    return (try ww.digest(gpa)).hash;
                },
                .migrate => unreachable, // only one migrate in this schedule
            }
        },
    }
}

/// LIVE-CAPTURE a V1→V2 session driven by exogenous triggers; appends the captured schedule into `out`.
fn captureSession(gpa: std.mem.Allocator, tV1: control.Trigger(RV1), tV2: control.Trigger(RV2), out: *std.ArrayList(control.ControlEvent), stream: ?*std.hash.XxHash64) !u64 {
    const w1 = try seedV1(gpa);
    const oc1 = try control.captureWithControl(RV1, gpa, w1, &no_inputs, 0, tV1, setsV1, 0, TOTAL, out, gpa, stream, null);
    switch (oc1) {
        .completed => |w| {
            var ww = w;
            defer ww.deinit(gpa);
            return (try ww.digest(gpa)).hash;
        },
        .migrate => |m| {
            defer {
                var s = m.pre;
                s.deinit(gpa);
            }
            const w2 = try migrate.migrateWorld(RV2, gpa, chain_1_2, m.pre.bytes);
            const oc2 = try control.captureWithControl(RV2, gpa, w2, &no_inputs, m.next_inputs_from, tV2, setsV2, 0, TOTAL, out, gpa, stream, null);
            switch (oc2) {
                .completed => |w| {
                    var ww = w;
                    defer ww.deinit(gpa);
                    return (try ww.digest(gpa)).hash;
                },
                .migrate => unreachable,
            }
        },
    }
}

// --- triggers ---------------------------------------------------------------------------------------

var trig_ctx: u8 = 0;
fn decideReloadMigrate(_: *anyopaque, tick: u64, _: *const WV1) ?control.ControlOp {
    if (tick == T1) return .{ .reload = 1 };
    if (tick == T2) return .{ .migrate = 0 };
    return null;
}
fn decideNone(_: *anyopaque, _: u64, _: *const WV2) ?control.ControlOp {
    return null;
}
const trigV1 = control.Trigger(RV1){ .ctx = &trig_ctx, .decide_fn = decideReloadMigrate };
const trigV2 = control.Trigger(RV2){ .ctx = &trig_ctx, .decide_fn = decideNone };

// tamper trigger: counts invocations and would emit a DIFFERENT op if re-invoked — proves replay never calls it.
const TamperCtx = struct { invoked: u32 = 0 };
fn decideTamper(ctx: *anyopaque, tick: u64, _: *const WV1) ?control.ControlOp {
    const t: *TamperCtx = @ptrCast(@alignCast(ctx));
    t.invoked += 1;
    // The live pass calls decide once per tick 1..T2 (T2 invocations), capturing reload(1)@T1 + migrate@T2.
    // The trip-wire is REACHABLE: any invocation beyond the live count (i.e. a re-invoke on replay, which
    // must never happen) emits a DIVERGENT op — reload to the OTHER set — so a replay-path leak would both
    // bump the counter AND corrupt the run. (The counter-unchanged assert is the load-bearing witness.)
    if (tick == T1) return .{ .reload = if (t.invoked <= T2) 1 else 0 };
    if (tick == T2) return .{ .migrate = 0 };
    return null;
}

// clock/exogenous trigger: fires the reload at a tick chosen by an EXOGENOUS value in ctx — a MOCK CLOCK
// (a deterministic stand-in for a real `std.time` reading, so the test stays pinnable while still
// modelling an out-of-band decision). Two captures with different exo values produce DIFFERENT schedules;
// each replays deterministically. (A real-nanoTimestamp trigger is intentionally avoided here — its
// schedule is unpinnable; the determinism guarantee that the clock never reaches the sim path is
// structural: runWithControl has no Trigger parameter.)
const ExoCtx = struct { fire_reload_at: u64 };
fn decideExo(ctx: *anyopaque, tick: u64, _: *const WV1) ?control.ControlOp {
    const e: *ExoCtx = @ptrCast(@alignCast(ctx));
    if (tick == e.fire_reload_at) return .{ .reload = 1 };
    if (tick == T2) return .{ .migrate = 0 };
    return null;
}

// --- pinned cross-build / cross-arch witnesses (recompute via dumpPin) ------------------------------
const PIN_FINAL: u64 = 4655614313888839660;
const PIN_STREAM: u64 = 6509199026665494313;
const PIN_SCHED_BYTES: u64 = 4810095791281529757;

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

test "K1: reload+migrate captured live then replayed from the schedule is bit-identical + pinned" {
    const gpa = testing.allocator;

    // LIVE: drive with the exogenous trigger, capturing the schedule + per-tick stream.
    var out: std.ArrayList(control.ControlEvent) = .empty;
    defer out.deinit(gpa);
    var live_stream = std.hash.XxHash64.init(0);
    const live_final = try captureSession(gpa, trigV1, trigV2, &out, &live_stream);

    // the captured schedule is exactly the frozen reference (reload@T1, migrate@T2).
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(T1, out.items[0].at_tick);
    try testing.expectEqual(@as(u16, 1), out.items[0].op.reload);
    try testing.expectEqual(T2, out.items[1].at_tick);
    try testing.expectEqual(@as(u16, 0), out.items[1].op.migrate);

    // REPLAY from the captured schedule: bit-identical final + per-tick stream.
    var replay_stream = std.hash.XxHash64.init(0);
    const replay_final = try replaySession(gpa, .{ .events = out.items }, &replay_stream);
    try testing.expectEqual(live_final, replay_final);
    try testing.expectEqual(live_stream.final(), replay_stream.final());

    // pinned (cross-build + cross-arch).
    try testing.expectEqual(PIN_FINAL, replay_final);
    try testing.expectEqual(PIN_STREAM, replay_stream.final());
}

test "K2: the reload genuinely changed the trajectory (vs a no-reload reference)" {
    const gpa = testing.allocator;
    // reference schedule: NO reload, just the migrate — the V1 phase stays on set 0 (plain move).
    const ref_events = [_]control.ControlEvent{.{ .at_tick = T2, .op = .{ .migrate = 0 } }};
    const ref_final = try replaySession(gpa, .{ .events = &ref_events }, null);
    const with_reload = try replaySession(gpa, .{ .events = &FROZEN }, null);
    try testing.expect(ref_final != with_reload); // the reload@T1 (move→jitter) observably diverged
}

test "K3: TAMPER trigger is never re-invoked on replay (the structural never-re-invoke witness)" {
    const gpa = testing.allocator;
    var tctx = TamperCtx{};
    const tamper = control.Trigger(RV1){ .ctx = &tctx, .decide_fn = decideTamper };

    var out: std.ArrayList(control.ControlEvent) = .empty;
    defer out.deinit(gpa);
    const live_final = try captureSession(gpa, tamper, trigV2, &out, null);
    const invoked_after_live = tctx.invoked;
    try testing.expect(invoked_after_live > 0); // it WAS called live

    // replay from the captured schedule — runWithControl has no Trigger parameter, so the counter cannot move.
    const replay_final = try replaySession(gpa, .{ .events = out.items }, null);
    try testing.expectEqual(live_final, replay_final); // reproduced bit-for-bit
    try testing.expectEqual(invoked_after_live, tctx.invoked); // tamper trigger NEVER re-invoked on replay
}

test "K4: an exogenous (clock-like) decider affects only capture, never replay" {
    const gpa = testing.allocator;
    // two captures with DIFFERENT exogenous fire ticks → DIFFERENT schedules ...
    var exoA = ExoCtx{ .fire_reload_at = 2 };
    var exoB = ExoCtx{ .fire_reload_at = 4 };
    const tA = control.Trigger(RV1){ .ctx = &exoA, .decide_fn = decideExo };
    const tB = control.Trigger(RV1){ .ctx = &exoB, .decide_fn = decideExo };

    var outA: std.ArrayList(control.ControlEvent) = .empty;
    defer outA.deinit(gpa);
    const liveA = try captureSession(gpa, tA, trigV2, &outA, null);
    var outB: std.ArrayList(control.ControlEvent) = .empty;
    defer outB.deinit(gpa);
    const liveB = try captureSession(gpa, tB, trigV2, &outB, null);

    try testing.expectEqual(@as(u64, 2), outA.items[0].at_tick);
    try testing.expectEqual(@as(u64, 4), outB.items[0].at_tick);
    try testing.expect(liveA != liveB); // different exogenous decision → different run

    // ... yet REPLAYING each frozen schedule reproduces its own live run exactly (clock off the replay path).
    try testing.expectEqual(liveA, try replaySession(gpa, .{ .events = outA.items }, null));
    try testing.expectEqual(liveB, try replaySession(gpa, .{ .events = outB.items }, null));
}

test "K5: a session driven by the DECODED schedule equals one driven by the original (wire identity)" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try control.writeSchedule(&sink, .{ .events = &FROZEN });

    var rd = serialize.ByteReader{ .bytes = buf.items };
    const decoded = try control.readSchedule(gpa, &rd);
    defer gpa.free(decoded.events);

    const a = try replaySession(gpa, .{ .events = &FROZEN }, null);
    const b = try replaySession(gpa, decoded, null);
    try testing.expectEqual(a, b);

    // the schedule bytes are a fixed-width canonical artifact, pinned cross-arch.
    try testing.expectEqual(PIN_SCHED_BYTES, std.hash.XxHash64.hash(0, buf.items));
}

test "K6: a past-due (unreachable) scheduled event is caught loudly, not silently dropped" {
    const gpa = testing.allocator;
    // An in-memory schedule with a tick-0 event (the codec rejects this; an in-memory schedule can hold
    // it). Tick 0 is unreachable — ops apply AFTER a tick completes, so the lowest boundary is tick 1 —
    // so the driver must fail with NonMonotonicSchedule, never silently drop the event (which would also
    // wedge every later event).
    const bad = [_]control.ControlEvent{.{ .at_tick = 0, .op = .{ .reload = 1 } }};
    const w1 = try seedV1(gpa);
    try testing.expectError(error.NonMonotonicSchedule, control.runWithControl(RV1, gpa, w1, &no_inputs, 0, .{ .events = &bad }, 0, setsV1, 0, TOTAL, null, null));
}

test "dumpPin compiles" {
    _ = &dumpPin;
}

fn dumpPin(gpa: std.mem.Allocator) !void {
    var stream = std.hash.XxHash64.init(0);
    const final = try replaySession(gpa, .{ .events = &FROZEN }, &stream);
    std.debug.print("PIN_FINAL={d} PIN_STREAM={d}\n", .{ final, stream.final() });
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try control.writeSchedule(&sink, .{ .events = &FROZEN });
    std.debug.print("PIN_SCHED_BYTES={d}\n", .{std.hash.XxHash64.hash(0, buf.items)});
}
