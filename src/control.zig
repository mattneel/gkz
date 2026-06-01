//! The reload/migrate CONTROL TRIGGER (SPEC §12↔§13, PLAN.md §16). Phase 8 built the mechanisms
//! (`reload.reloadAt`/`SystemSource`, `migrate.migrateWorld`/`Chain`); Phase 9 built the control plane.
//! This is the missing connection: a CAPTURED, serializable, replayable CONTROL SCHEDULE of (at_tick, op)
//! decisions + a DETERMINISTIC driver that applies them at tick boundaries + the EXOGENOUS trigger seam.
//!
//! The discipline is the §10 agent-capture pattern transposed to control: the exogenous decider (an
//! operator / watch loop reacting to wall-clock or external signals — OUTSIDE the determinism boundary)
//! is invoked LIVE by `captureWithControl`, which records each emitted op into the schedule; REPLAY
//! consumes the schedule via `runWithControl`, which has NO trigger parameter and is STRUCTURALLY
//! incapable of re-invoking the live decider. A run is fully determined by the triple
//! (seed, inputs, ControlSchedule) — every member is frozen data the sim path reads but never re-derives.
//!
//!   * RELOAD = swap the running system set, SAME R (a `reload.reloadAt` World no-op); applied in place.
//!   * MIGRATE = advance the schema R_old→R_new. This RE-TYPES the World, so a single comptime-R driver
//!     cannot continue past it: the driver SNAPSHOTS the pre-migration World to canonical bytes and
//!     SURRENDERS via `ControlOutcome.migrate`; the caller (which knows the schema graph at comptime)
//!     `migrateWorld`s to the new R and re-enters the driver. The schedule (integer ids) spans phases.

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("serialize.zig");
const worldmod = @import("world.zig");
const reload = @import("reload.zig");
const schedule = @import("schedule.zig");
const stepmod = @import("step.zig");
const snapshotmod = @import("snapshot.zig");
const input = @import("input.zig");
const recorder = @import("recorder.zig");
const migrate = @import("migrate.zig");

// --- the control schedule -------------------------------------------------------------------------

/// A single control decision. NO R parameter — it names INTEGERS, not types/systems, so one
/// ControlSchedule spans every phase of a multi-R run and is wire-serializable verbatim.
pub const ControlOp = union(enum(u8)) {
    /// Swap the running system set, SAME R. `set_id` indexes the live phase's SetTable(R).
    reload: u16,
    /// Advance the schema R_old → R_new. `migration_id` indexes the caller's comptime schema graph.
    migrate: u16,
};

/// One scheduled decision: apply `op` AT the boundary AFTER tick `at_tick` completes (between
/// World@(at_tick) and World@(at_tick+1)). `at_tick` is the tick NUMBER (matches `World.tick`).
pub const ControlEvent = struct { at_tick: u64, op: ControlOp };

/// The captured, replayable program of control decisions for a whole (possibly multi-R) run. Events are
/// STRICTLY ASCENDING by `at_tick` — at most one op per boundary. The §12/§13 analog of `Run.inputs`:
/// (seed, inputs, ControlSchedule) reproduces a run bit-exactly INCLUDING its reloads and migrations.
pub const ControlSchedule = struct {
    events: []const ControlEvent,
    /// The op scheduled exactly at `tick`, or null. Linear scan (N is tiny — operator decisions, not
    /// per-tick).
    pub fn opAt(self: ControlSchedule, tick: u64) ?ControlOp {
        for (self.events) |e| if (e.at_tick == tick) return e.op;
        return null;
    }
};

pub const RunError = serialize.Error || Allocator.Error || error{ TooManySystems, BadSetId, NonMonotonicSchedule };

// --- the set table: integer-indexed adapter over reload.SystemSource --------------------------------

/// Resolves a reload `set_id` to a `reload.SystemSet(R)` — the integer lookup the schedule needs over the
/// existing loader (`inProcessSource` OR `NativeLibSource`), reused verbatim.
pub fn SetTable(comptime R: type) type {
    return struct {
        sources: []const reload.SystemSource(R), // set_id is the index
        pub fn load(self: @This(), set_id: u16) RunError!reload.SystemSet(R) {
            if (set_id >= self.sources.len) return error.BadSetId;
            return self.sources[set_id].load() catch return error.BadSetId;
        }
        pub fn unload(self: @This(), set_id: u16) void {
            if (set_id < self.sources.len) self.sources[set_id].unload();
        }
    };
}

// --- the exogenous trigger seam ---------------------------------------------------------------------

/// The EXOGENOUS live decider — an operator / watch loop / socket reactor OUTSIDE the determinism
/// boundary. `decide` MAY read wall-clock, a socket, a console — anything — to choose whether to fire an
/// op at THIS tick boundary, and gets a READ-ONLY `*const World(R)` to INSPECT (but not mutate) the sim.
/// Its SOLE egress is the `?ControlOp` it returns, captured into the schedule. Reproducibility comes from
/// CAPTURE, never from re-invoking it (no seed is passed — it makes no false promise of replayability).
pub fn Trigger(comptime R: type) type {
    return struct {
        ctx: *anyopaque,
        decide_fn: *const fn (*anyopaque, u64, *const worldmod.World(R)) ?ControlOp,
        pub fn decide(self: @This(), tick: u64, view: *const worldmod.World(R)) ?ControlOp {
            return self.decide_fn(self.ctx, tick, view);
        }
    };
}

// --- the driver outcome -----------------------------------------------------------------------------

/// What ONE R-phase yielded. Cannot be a plain World(R): a migrate changes R, and a fn parameterized on
/// R_old cannot construct a World(R_new). The `.migrate` arm hands the caller the PRE-migration World as
/// CANONICAL BYTES (a Snapshot, never a live World — so even a live run resumes the next phase by
/// replaying canonical bytes) plus the migration_id and the two resume cursors.
pub fn ControlOutcome(comptime R: type) type {
    return union(enum) {
        completed: worldmod.World(R), // schedule/budget exhausted at this R; the final World (caller deinits)
        migrate: struct {
            at_tick: u64,
            migration_id: u16,
            pre: snapshotmod.Snapshot, // canonical bytes of World@(at_tick); caller deinits
            resume_from: usize, // next index into schedule.events
            next_inputs_from: usize, // next index into inputs
        },
    };
}

/// Swap the running set in place (SAME R): load the new set (BadSetId if out of range), recompute exec,
/// then `reload.reloadAt` by name (the World no-op), then unload the prior set AFTER the swap+recompute
/// (the dlopen "valid only while open" hazard). `new_exec` is computed BEFORE freeing the old, so an error
/// leaves `exec` pointing at the still-valid old slice (the caller's errdefer frees it exactly once).
/// Used by both control drivers (runWithControl/captureWithControl) for the single-sim reload. The live
/// control server's reload (`control_server.reloadSim`) is a refcount-AWARE re-implementation with the
/// IDENTICAL World semantics (this same `reloadAt` no-op + `execOrderDynamic` recompute) — it cannot call
/// this directly because it must share+refcount one dlopen handle across multiple in-process sims, which a
/// raw `sets.load`/`sets.unload` here does not; the produced World (hence every digest) is the same.
pub fn applyReload(
    comptime R: type,
    gpa: Allocator,
    cur_set: *reload.SystemSet(R),
    cur_set_id: *u16,
    exec: *[]u16,
    sets: SetTable(R),
    set_id: u16,
) RunError!void {
    const prev_id = cur_set_id.*;
    const next = try sets.load(set_id); // BadSetId
    const new_exec = try schedule.execOrderDynamic(R, gpa, next.systems); // TooManySystems; old exec intact
    gpa.free(exec.*);
    exec.* = new_exec;
    cur_set.* = reload.reloadAt(R, cur_set.*, next); // BY NAME — the documented World no-op
    cur_set_id.* = set_id;
    sets.unload(prev_id); // AFTER the swap (never while the prior .so's fn-ptrs could still run a tick)
}

// --- the drivers ------------------------------------------------------------------------------------

/// REPLAY/CONSUME driver: run ONE R-phase, ticks via `stepDynamic`, applying the SCHEDULE's ops at each
/// tick boundary until a MIGRATE op falls due (return `.migrate`) or `World.tick == until_tick` (return
/// `.completed`). Has NO `Trigger` parameter — the replay path is STRUCTURALLY incapable of invoking a
/// live decider. `inputs[start_in..]` are this phase's tick inputs (defaulting to `input.EMPTY` past the
/// end, so the schedule bounds the phase). `start_event` skips already-applied events on a resumed phase.
/// `stream`, if present, folds each tick's content hash (the per-tick determinism witness).
pub fn runWithControl(
    comptime R: type,
    gpa: Allocator,
    w0: worldmod.World(R), // consumed (ownership taken before the first fallible call)
    inputs: []const input.Input,
    start_in: usize,
    sched: ControlSchedule,
    start_event: usize,
    sets: SetTable(R),
    start_set_id: u16,
    until_tick: u64,
    stream: ?*std.hash.XxHash64,
    rec: ?*recorder.Recorder,
) RunError!ControlOutcome(R) {
    var w = w0;
    errdefer w.deinit(gpa);
    var cur_set_id = start_set_id;
    var cur_set = try sets.load(cur_set_id);
    var exec = try schedule.execOrderDynamic(R, gpa, cur_set.systems);
    errdefer gpa.free(exec);
    var ev = start_event;
    var i = start_in;
    while (w.tick < until_tick) : (i += 1) {
        const in = if (i < inputs.len) inputs[i] else input.EMPTY;
        const nxt = try stepmod.stepDynamic(R, gpa, w, in, cur_set.systems, exec, rec);
        w.deinit(gpa);
        w = nxt; // w.tick is now this tick's number (D2)
        foldStream(R, gpa, stream, &w) catch |e| return e;
        // A pending event keyed BEFORE this boundary can never fire — `at_tick == 0` (ops apply AFTER a
        // tick, so the lowest reachable boundary is 1), a non-ascending in-memory schedule, or a stale
        // resumed event. Fail LOUDLY instead of silently wedging the cursor and dropping the rest.
        if (ev < sched.events.len and sched.events[ev].at_tick < w.tick) return error.NonMonotonicSchedule;
        if (ev < sched.events.len and sched.events[ev].at_tick == w.tick) {
            switch (sched.events[ev].op) {
                .reload => |set_id| {
                    try applyReload(R, gpa, &cur_set, &cur_set_id, &exec, sets, set_id);
                    ev += 1;
                },
                .migrate => |migration_id| {
                    const at = w.tick; // BEFORE deinit (deinit sets w.* = undefined)
                    const snap = try snapshotmod.snapshot(R, gpa, &w); // BEFORE freeing exec → an error here won't double-free exec
                    gpa.free(exec);
                    w.deinit(gpa);
                    sets.unload(cur_set_id); // release the active set's handle (dlopen); no-op in-process
                    return .{ .migrate = .{ .at_tick = at, .migration_id = migration_id, .pre = snap, .resume_from = ev + 1, .next_inputs_from = i + 1 } };
                },
            }
        }
    }
    gpa.free(exec);
    sets.unload(cur_set_id); // release the active set's handle at phase end (pairs the entry + reload loads)
    return .{ .completed = w };
}

/// LIVE/CAPTURE driver: identical loop to `runWithControl`, but at each tick boundary it consults the
/// EXOGENOUS `trigger` (which may read a clock) and, if it emits an op, APPENDS `ControlEvent{w.tick, op}`
/// to `out` BEFORE applying it identically (the reload/migrate apply is single-sourced with the replay
/// path). The schedule it builds is exactly what `runWithControl` later consumes — and on a migrate it
/// returns the SAME `.migrate` (canonical bytes), so the caller resumes via the REPLAY driver even
/// mid-live-run. There is deliberately NO path that threads a `Trigger` into `runWithControl`.
pub fn captureWithControl(
    comptime R: type,
    gpa: Allocator,
    w0: worldmod.World(R),
    inputs: []const input.Input,
    start_in: usize,
    trigger: Trigger(R),
    sets: SetTable(R),
    start_set_id: u16,
    until_tick: u64,
    out: *std.ArrayList(ControlEvent),
    out_gpa: Allocator,
    stream: ?*std.hash.XxHash64,
    rec: ?*recorder.Recorder,
) RunError!ControlOutcome(R) {
    var w = w0;
    errdefer w.deinit(gpa);
    var cur_set_id = start_set_id;
    var cur_set = try sets.load(cur_set_id);
    var exec = try schedule.execOrderDynamic(R, gpa, cur_set.systems);
    errdefer gpa.free(exec);
    var i = start_in;
    while (w.tick < until_tick) : (i += 1) {
        const in = if (i < inputs.len) inputs[i] else input.EMPTY;
        const nxt = try stepmod.stepDynamic(R, gpa, w, in, cur_set.systems, exec, rec);
        w.deinit(gpa);
        w = nxt;
        foldStream(R, gpa, stream, &w) catch |e| return e;
        if (trigger.decide(w.tick, &w)) |op| {
            // capture FIRST (ascending by construction — w.tick strictly increases), then apply.
            try out.append(out_gpa, .{ .at_tick = w.tick, .op = op });
            switch (op) {
                .reload => |set_id| try applyReload(R, gpa, &cur_set, &cur_set_id, &exec, sets, set_id),
                .migrate => |migration_id| {
                    const at = w.tick; // BEFORE deinit
                    const snap = try snapshotmod.snapshot(R, gpa, &w);
                    gpa.free(exec);
                    w.deinit(gpa);
                    sets.unload(cur_set_id); // release the active set's handle (dlopen); no-op in-process
                    return .{ .migrate = .{ .at_tick = at, .migration_id = migration_id, .pre = snap, .resume_from = out.items.len, .next_inputs_from = i + 1 } };
                },
            }
        }
    }
    gpa.free(exec);
    sets.unload(cur_set_id); // release the active set's handle at phase end
    return .{ .completed = w };
}

fn foldStream(comptime R: type, gpa: Allocator, stream: ?*std.hash.XxHash64, w: *const worldmod.World(R)) Allocator.Error!void {
    if (stream) |s| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, (try w.digest(gpa)).hash, .little);
        s.update(&b);
    }
}

// --- the generic multi-phase session driver (reload + migrate across R-retyping boundaries) --------

/// One phase of a multi-R session: its registry + the SetTable resolving reload ids IN THIS phase.
pub fn Phase(comptime R_: type) type {
    return struct {
        pub const R = R_;
        sets: SetTable(R),
        start_set_id: u16 = 0,
    };
}

/// A migration edge LEAVING phase i → phase i+1 (comptime-resolved). migration_id == departing phase index.
pub fn MigrateEdge(comptime R_from: type, comptime R_to: type) type {
    return struct {
        pub const From = R_from;
        pub const To = R_to;
        chain: migrate.Chain,
    };
}

pub const SessionError = RunError || migrate.MigrateError || error{ UnexpectedCompletion, TooManyMigrations, BadMigrationId };

/// REPLAY a multi-R session from a frozen schedule, starting at comptime `phase_i` with an
/// already-constructed `w0` for `phases[phase_i].R`. A `.migrate` is the ONLY thing that advances the
/// phase — it tail-recurses into the NEXT R's monomorphization (the World type changes per phase, which a
/// flat loop cannot express); `.completed` ends the session. NO Trigger parameter → structurally
/// replay-only. Returns the FINAL World digest. Loud errors on an under/over/mis-migrated schedule.
pub fn runSession(
    comptime phases: anytype,
    comptime edges: anytype,
    comptime phase_i: usize,
    gpa: Allocator,
    w0: worldmod.World(@TypeOf(phases[phase_i]).R),
    inputs: []const input.Input,
    start_in: usize,
    sched: ControlSchedule,
    start_event: usize,
    until_tick: u64,
    stream: ?*std.hash.XxHash64,
    rec: ?*recorder.Recorder,
) SessionError!u64 {
    const R = @TypeOf(phases[phase_i]).R;
    const ph = phases[phase_i];
    const oc = try runWithControl(R, gpa, w0, inputs, start_in, sched, start_event, ph.sets, ph.start_set_id, until_tick, stream, rec);
    switch (oc) {
        .completed => |w| {
            var ww = w;
            if (phase_i + 1 != phases.len) { // schedule under-migrated: a later phase was never reached
                ww.deinit(gpa);
                return error.UnexpectedCompletion;
            }
            defer ww.deinit(gpa);
            return (try ww.digest(gpa)).hash;
        },
        .migrate => |m| {
            var snap = m.pre;
            defer snap.deinit(gpa);
            if (phase_i + 1 >= phases.len) return error.TooManyMigrations; // migrate off the terminal phase
            if (m.migration_id != phase_i) return error.BadMigrationId; // never a silent mis-route
            const edge = edges[phase_i];
            const RNext = @TypeOf(edge).To;
            const w_next = try migrate.migrateWorld(RNext, gpa, edge.chain, snap.bytes);
            return runSession(phases, edges, phase_i + 1, gpa, w_next, inputs, m.next_inputs_from, sched, m.resume_from, until_tick, stream, rec);
        },
    }
}

/// REPLAY a whole multi-R session: build the entry World via `seed0`, then drive phase 0 onward.
pub fn runAllPhases(
    comptime phases: anytype,
    comptime edges: anytype,
    gpa: Allocator,
    seed0: *const fn (Allocator) anyerror!worldmod.World(@TypeOf(phases[0]).R),
    inputs: []const input.Input,
    sched: ControlSchedule,
    until_tick: u64,
    stream: ?*std.hash.XxHash64,
    rec: ?*recorder.Recorder,
) SessionError!u64 {
    comptime std.debug.assert(edges.len == phases.len - 1);
    const w0 = seed0(gpa) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UnexpectedCompletion, // a seed-builder failure is surfaced, never swallowed
    };
    return runSession(phases, edges, 0, gpa, w0, inputs, 0, sched, 0, until_tick, stream, rec);
}

/// LIVE-CAPTURE twin of runSession: invokes per-phase exogenous triggers, capturing each op into `out`,
/// crossing R-boundaries identically (snapshot → migrateWorld → recurse). `triggers` is a comptime tuple
/// of Trigger(phases[i].R). Returns the FINAL World digest; `out` holds the captured ControlSchedule.
pub fn captureSession(
    comptime phases: anytype,
    comptime edges: anytype,
    comptime phase_i: usize,
    gpa: Allocator,
    w0: worldmod.World(@TypeOf(phases[phase_i]).R),
    inputs: []const input.Input,
    start_in: usize,
    triggers: anytype,
    until_tick: u64,
    out: *std.ArrayList(ControlEvent),
    out_gpa: Allocator,
    stream: ?*std.hash.XxHash64,
    rec: ?*recorder.Recorder,
) SessionError!u64 {
    const R = @TypeOf(phases[phase_i]).R;
    const ph = phases[phase_i];
    const oc = try captureWithControl(R, gpa, w0, inputs, start_in, triggers[phase_i], ph.sets, ph.start_set_id, until_tick, out, out_gpa, stream, rec);
    switch (oc) {
        .completed => |w| {
            var ww = w;
            if (phase_i + 1 != phases.len) {
                ww.deinit(gpa);
                return error.UnexpectedCompletion;
            }
            defer ww.deinit(gpa);
            return (try ww.digest(gpa)).hash;
        },
        .migrate => |m| {
            var snap = m.pre;
            defer snap.deinit(gpa);
            if (phase_i + 1 >= phases.len) return error.TooManyMigrations;
            if (m.migration_id != phase_i) return error.BadMigrationId;
            const edge = edges[phase_i];
            const RNext = @TypeOf(edge).To;
            const w_next = try migrate.migrateWorld(RNext, gpa, edge.chain, snap.bytes);
            return captureSession(phases, edges, phase_i + 1, gpa, w_next, inputs, m.next_inputs_from, triggers, until_tick, out, out_gpa, stream, rec);
        },
    }
}

/// LIVE-CAPTURE a whole multi-R session: build the entry World via `seed0`, then capture from phase 0.
pub fn captureAllPhases(
    comptime phases: anytype,
    comptime edges: anytype,
    gpa: Allocator,
    seed0: *const fn (Allocator) anyerror!worldmod.World(@TypeOf(phases[0]).R),
    inputs: []const input.Input,
    triggers: anytype,
    until_tick: u64,
    out: *std.ArrayList(ControlEvent),
    out_gpa: Allocator,
    stream: ?*std.hash.XxHash64,
    rec: ?*recorder.Recorder,
) SessionError!u64 {
    comptime std.debug.assert(edges.len == phases.len - 1);
    const w0 = seed0(gpa) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UnexpectedCompletion,
    };
    return captureSession(phases, edges, 0, gpa, w0, inputs, 0, triggers, until_tick, out, out_gpa, stream, rec);
}

// --- the schedule codec (canonical, hostile-hardened) -----------------------------------------------

pub const CONTROL_MAGIC = [5]u8{ 'G', 'K', 'Z', 'C', '1' };
pub const CONTROL_FORMAT: u16 = 1;

pub fn writeSchedule(sink: anytype, sched: ControlSchedule) !void {
    try sink.update(&CONTROL_MAGIC);
    try serialize.putInt(sink, u16, CONTROL_FORMAT);
    try serialize.putInt(sink, u32, @intCast(sched.events.len));
    var prev: ?u64 = null;
    for (sched.events) |e| {
        if (e.at_tick == 0) return error.Corrupt; // tick 0 is unrepresentable: ops apply AFTER a tick (min 1)
        if (prev) |p| if (e.at_tick <= p) return error.Corrupt; // STRICT ascending, ≤1 op/tick (canonical)
        prev = e.at_tick;
        try serialize.putInt(sink, u64, e.at_tick);
        try serialize.putInt(sink, u8, @intFromEnum(e.op));
        switch (e.op) {
            .reload => |id| try serialize.putInt(sink, u16, id),
            .migrate => |id| try serialize.putInt(sink, u16, id),
        }
    }
}

/// Decode an UNTRUSTED schedule. Validates MAGIC+FORMAT, re-asserts strict-ascending at_tick, rejects an
/// unknown tag, and parses INCREMENTALLY (the u32 count drives no pre-allocation — each event ≥ 11 bytes).
pub fn readSchedule(gpa: Allocator, reader: *serialize.ByteReader) (serialize.Error || Allocator.Error)!ControlSchedule {
    const magic = try reader.readSlice(5);
    if (!std.mem.eql(u8, magic, &CONTROL_MAGIC)) return error.BadMagic;
    if (try serialize.getInt(reader, u16) != CONTROL_FORMAT) return error.UnsupportedFormat;
    const n = try serialize.getInt(reader, u32);
    var list: std.ArrayList(ControlEvent) = .empty;
    errdefer list.deinit(gpa);
    var prev: ?u64 = null;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const at = try serialize.getInt(reader, u64);
        if (at == 0) return error.Corrupt; // tick 0 unrepresentable (see writeSchedule)
        if (prev) |p| if (at <= p) return error.Corrupt; // re-assert STRICT ascending on DECODE
        prev = at;
        const tag = try serialize.getInt(reader, u8);
        const op: ControlOp = switch (tag) {
            0 => .{ .reload = try serialize.getInt(reader, u16) },
            1 => .{ .migrate = try serialize.getInt(reader, u16) },
            else => return error.Corrupt, // unknown tag → error, never UB
        };
        try list.append(gpa, .{ .at_tick = at, .op = op });
    }
    return .{ .events = try list.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------------------------------
// Tests — unit-level; the pinned cross-build/cross-arch witnesses live in control_gate.zig.
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "schedule codec round-trips byte-identically and rejects hostile input" {
    const gpa = testing.allocator;
    const evs = [_]ControlEvent{
        .{ .at_tick = 3, .op = .{ .reload = 1 } },
        .{ .at_tick = 7, .op = .{ .migrate = 0 } },
    };
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var sa = serialize.ByteSink{ .list = &a, .gpa = gpa };
    try writeSchedule(&sa, .{ .events = &evs });

    var rd = serialize.ByteReader{ .bytes = a.items };
    const got = try readSchedule(gpa, &rd);
    defer gpa.free(got.events);
    try testing.expectEqual(@as(usize, 2), got.events.len);
    try testing.expectEqual(@as(u64, 3), got.events[0].at_tick);
    try testing.expectEqual(@as(u16, 1), got.events[0].op.reload);
    try testing.expectEqual(@as(u16, 0), got.events[1].op.migrate);

    // re-encode is byte-identical (canonical fixed point)
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    var sb = serialize.ByteSink{ .list = &b, .gpa = gpa };
    try writeSchedule(&sb, got);
    try testing.expectEqualSlices(u8, a.items, b.items);

    // hostile: bad magic, unknown tag, non-ascending, truncation
    var bad = serialize.ByteReader{ .bytes = "ZZZZZ\x01\x00" };
    try testing.expectError(error.BadMagic, readSchedule(gpa, &bad));
    var trunc = serialize.ByteReader{ .bytes = a.items[0 .. a.items.len - 1] };
    try testing.expectError(error.Truncated, readSchedule(gpa, &trunc));

    // a non-ascending schedule is rejected on ENCODE
    const bad_order = [_]ControlEvent{ .{ .at_tick = 7, .op = .{ .reload = 0 } }, .{ .at_tick = 3, .op = .{ .reload = 0 } } };
    var c: std.ArrayList(u8) = .empty;
    defer c.deinit(gpa);
    var sc = serialize.ByteSink{ .list = &c, .gpa = gpa };
    try testing.expectError(error.Corrupt, writeSchedule(&sc, .{ .events = &bad_order }));
}

test "decode-side hostile schedules are rejected (unknown tag, at_tick==0, non-ascending, bad version)" {
    const gpa = testing.allocator;
    const RawEv = struct { at: u64, tag: u8, id: u16 };
    const Raw = struct {
        fn build(g: Allocator, fmt: u16, evs: []const RawEv, list: *std.ArrayList(u8)) !void {
            var s = serialize.ByteSink{ .list = list, .gpa = g };
            try s.update(&CONTROL_MAGIC);
            try serialize.putInt(&s, u16, fmt);
            try serialize.putInt(&s, u32, @intCast(evs.len));
            for (evs) |e| {
                try serialize.putInt(&s, u64, e.at);
                try serialize.putInt(&s, u8, e.tag);
                try serialize.putInt(&s, u16, e.id);
            }
        }
    };
    const Case = struct { fmt: u16, evs: []const RawEv, want: anyerror };
    const cases = [_]Case{
        .{ .fmt = CONTROL_FORMAT, .evs = &.{.{ .at = 5, .tag = 2, .id = 0 }}, .want = error.Corrupt }, // unknown tag
        .{ .fmt = CONTROL_FORMAT, .evs = &.{.{ .at = 0, .tag = 0, .id = 0 }}, .want = error.Corrupt }, // at_tick==0
        .{ .fmt = CONTROL_FORMAT, .evs = &.{ .{ .at = 5, .tag = 0, .id = 0 }, .{ .at = 3, .tag = 0, .id = 0 } }, .want = error.Corrupt }, // non-ascending (decode guard)
        .{ .fmt = 99, .evs = &.{.{ .at = 5, .tag = 0, .id = 0 }}, .want = error.UnsupportedFormat }, // bad version
    };
    inline for (cases) |c| {
        var l: std.ArrayList(u8) = .empty;
        defer l.deinit(gpa);
        try Raw.build(gpa, c.fmt, c.evs, &l);
        var rd = serialize.ByteReader{ .bytes = l.items };
        try testing.expectError(c.want, readSchedule(gpa, &rd));
    }
    // at_tick==0 is also rejected on ENCODE.
    const bad0 = [_]ControlEvent{.{ .at_tick = 0, .op = .{ .reload = 0 } }};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try testing.expectError(error.Corrupt, writeSchedule(&sink, .{ .events = &bad0 }));
}

test "opAt finds the exact-tick op" {
    const evs = [_]ControlEvent{ .{ .at_tick = 5, .op = .{ .reload = 2 } }, .{ .at_tick = 9, .op = .{ .migrate = 1 } } };
    const s = ControlSchedule{ .events = &evs };
    try testing.expectEqual(@as(u16, 2), s.opAt(5).?.reload);
    try testing.expectEqual(@as(?ControlOp, null), s.opAt(6));
    try testing.expectEqual(@as(u16, 1), s.opAt(9).?.migrate);
}
