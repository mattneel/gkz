//! The Phase-2b WITNESS (SPEC §4 / §2, PLAN.md §13.6): proves the in-process multithreaded scheduler
//! (`step_par.zig`) is bit-/byte-identical to the single-threaded spine and that the parallelism is
//! GENUINE — not a disguised serial loop. Folded into the base 3-mode `tmod` test via root.zig's
//! `test {}` block (`_ = @import("step_par_gate.zig")`): the base matrix already runs across
//! Debug/ReleaseSafe/ReleaseFast with a Threaded-backed `std.testing.io`, so a pure in-process thread
//! gate needs no build.zig artifact and gets the D2 cross-mode matrix for free.
//!
//! FORCED OVERLAP (the lesson of the Phase-2b review): `std.Io.Threaded` eager-inlines a `group.async`
//! task on the CALLER once `busy_count >= async_limit` (default `cpu_count - 1`). On a low-core box that
//! default is `.limited(0)` → EVERY task inlines → the "parallel" path is fully serial, and a
//! determinism-equality assertion still passes (the spine is deterministic when serial). So a witness
//! that only asserts equality at the DEFAULT limit proves determinism, NOT thread-safety. Every test
//! that must exercise the concurrency hazards (concurrent disjoint-column writes, concurrent keyed RNG,
//! concurrent sub-recorder emits + merge) therefore brackets the run with `setAsyncLimit(.unlimited)`
//! (`forceOverlap`), which makes the pool grow a thread per task on ANY core count. T9 goes further: its
//! systems SLEEP, so they provably execute SIMULTANEOUSLY (measured wall-clock overlap) while writing
//! disjoint columns / drawing RNG / emitting — the real race witness.
//!
//! NO `std.debug.print` in any test body — it corrupts the `--listen` test-runner IPC (the Phase-9
//! lesson). Pins (the cross-build D2 witnesses, T2/T4/T5) are frozen constants; recompute them with the
//! guarded `dumpPin` run standalone (per-module `zig test`, which does not use `--listen`).

const std = @import("std");
const builtin = @import("builtin");
const world = @import("world.zig");
const schedule = @import("schedule.zig");
const simctx = @import("simctx.zig");
const query = @import("query.zig");
const registry = @import("registry.zig");
const step = @import("step.zig");
const step_par = @import("step_par.zig");
const recorder = @import("recorder.zig");
const event_log = @import("event_log.zig");
const entity = @import("entity.zig");
const input = @import("input.zig");
const serialize = @import("serialize.zig");

const testing = std.testing;
const Read = query.Read;
const Write = query.Write;
const Query = query.Query;
const Sys = schedule.Sys;
const SimCtx = simctx.SimCtx;

/// Force one-thread-per-task on `std.testing.io` regardless of host core count, restoring the previous
/// limit on `deinit`. Without this, a low-core box silently serializes the "parallel" path (see header).
const ForceOverlap = struct {
    saved: std.Io.Limit,
    fn begin() ForceOverlap {
        const s = std.testing.io_instance.async_limit;
        std.testing.io_instance.setAsyncLimit(.unlimited);
        return .{ .saved = s };
    }
    fn end(self: ForceOverlap) void {
        std.testing.io_instance.setAsyncLimit(self.saved);
    }
};

// --- the functional system set (T1–T5, T7, T8) ----------------------------------------------------

const A = struct {
    v: i32,
    pub const kind_id: u16 = 1;
};
const B = struct {
    v: i32,
    pub const kind_id: u16 = 2;
};
const C = struct {
    v: i32,
    pub const kind_id: u16 = 3;
};
const D = struct {
    v: i32,
    pub const kind_id: u16 = 4;
};
const FReg = registry.Registry(.{ A, B, C, D });
const FW = world.World(FReg);
const Ev = struct {
    n: i32,
    pub const kind_id: u16 = 50;
};
const E0: entity.Entity = .{ .index = 0, .generation = 0 };

// writeA / writeB / writeC write DISJOINT columns → no conflict → they share stage 0 (parallel).
fn writeA(ctx: *SimCtx(FReg), q: *Query(FReg, .{Write(A)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| row.write(A).v += 1;
    _ = try ctx.emitS(Ev, E0, .{ .n = 1 }); // 1 event → one SystemCause node
}
fn writeB(ctx: *SimCtx(FReg), q: *Query(FReg, .{Write(B)})) std.mem.Allocator.Error!void {
    while (q.next()) |row| {
        const e = row.entity();
        row.write(B).v += @as(i32, @intCast(ctx.rng(e.index, 1) % 3)); // keyed RNG, drawn concurrently
    }
    // TWO events from one system → exercises the per-sub-recorder cur_sa dedup (one SystemCause node) AND
    // a multi-element explicit cause list ([SystemCause, first]) through mergeSubLogs' cause_off/len slice.
    const first = try ctx.emitS(Ev, E0, .{ .n = 2 });
    _ = try ctx.emit(Ev, E0, .{ .n = 20 }, &.{first});
}
fn writeC(ctx: *SimCtx(FReg), q: *Query(FReg, .{Write(C)})) std.mem.Allocator.Error!void {
    _ = ctx; // ZERO-emit system → an EMPTY sub-log, must contribute nothing to the merge (no node).
    while (q.next()) |row| row.write(C).v += 3;
}
// gather READS A,B,C and WRITES D → conflicts with all three writers → stage 1.
fn gather(ctx: *SimCtx(FReg), q: *Query(FReg, .{ Read(A), Read(B), Read(C), Write(D) })) std.mem.Allocator.Error!void {
    while (q.next()) |row| {
        const d = row.write(D);
        d.v = row.read(A).v + row.read(B).v + row.read(C).v;
    }
    _ = try ctx.emitS(Ev, E0, .{ .n = 4 });
}
const fsystems = [_]Sys(FReg){
    schedule.system(FReg, "writeA", writeA),
    schedule.system(FReg, "writeB", writeB),
    schedule.system(FReg, "writeC", writeC),
    schedule.system(FReg, "gather", gather),
};

const NENT: u32 = 5;
const TICKS: u64 = 10;
const empty_in = input.Input{ .tick = 0, .commands = &.{} };

fn fSeed(gpa: std.mem.Allocator, n: u32) !FW {
    var w = FW.init(0xBEEF);
    errdefer w.deinit(gpa);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const e = try w.spawn(gpa);
        w.add(e, A, .{ .v = 0 });
        w.add(e, B, .{ .v = 0 });
        w.add(e, C, .{ .v = 0 });
        w.add(e, D, .{ .v = 0 });
    }
    return w;
}

const Trace = struct { final: u64, stream: u64 };

/// Single-threaded reference trajectory: fold each tick's content hash into a rolling stream digest.
fn fRunSer(gpa: std.mem.Allocator, ticks: u64) !Trace {
    var w = try fSeed(gpa, NENT);
    errdefer w.deinit(gpa);
    var h = std.hash.XxHash64.init(0);
    var t: u64 = 0;
    while (t < ticks) : (t += 1) {
        const nw = try step.step(FReg, gpa, w, empty_in, &fsystems);
        w.deinit(gpa);
        w = nw;
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, (try w.digest(gpa)).hash, .little);
        h.update(&b);
    }
    const final = (try w.digest(gpa)).hash;
    w.deinit(gpa);
    return .{ .final = final, .stream = h.final() };
}

/// Parallel trajectory through `step_par.stepExecPar` with the given `exec`, io, and thread count.
fn fRunPar(gpa: std.mem.Allocator, ticks: u64, io: ?std.Io, n: usize, exec: []const u16) !Trace {
    var w = try fSeed(gpa, NENT);
    errdefer w.deinit(gpa);
    var h = std.hash.XxHash64.init(0);
    var t: u64 = 0;
    while (t < ticks) : (t += 1) {
        const nw = try step_par.stepExecPar(FReg, gpa, w, empty_in, &fsystems, exec, null, io, n);
        w.deinit(gpa);
        w = nw;
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, (try w.digest(gpa)).hash, .little);
        h.update(&b);
    }
    const final = (try w.digest(gpa)).hash;
    w.deinit(gpa);
    return .{ .final = final, .stream = h.final() };
}

/// Recording reference trajectory (single shared Recorder accumulating across ticks) with explicit exec.
fn fRunSerRec(gpa: std.mem.Allocator, ticks: u64, exec: []const u16, rec: *recorder.Recorder) !void {
    var w = try fSeed(gpa, NENT);
    defer w.deinit(gpa);
    var t: u64 = 0;
    while (t < ticks) : (t += 1) {
        const nw = try step.stepExec(FReg, gpa, w, empty_in, &fsystems, exec, rec);
        w.deinit(gpa);
        w = nw;
    }
}

/// Recording parallel trajectory (per-tick sub-recorders merged into `rec.log` in exec order).
fn fRunParRec(gpa: std.mem.Allocator, ticks: u64, io: ?std.Io, n: usize, exec: []const u16, rec: *recorder.Recorder) !void {
    var w = try fSeed(gpa, NENT);
    defer w.deinit(gpa);
    var t: u64 = 0;
    while (t < ticks) : (t += 1) {
        const nw = try step_par.stepExecPar(FReg, gpa, w, empty_in, &fsystems, exec, rec, io, n);
        w.deinit(gpa);
        w = nw;
    }
}

fn logBytes(gpa: std.mem.Allocator, log: *const event_log.EventLog, out: *std.ArrayList(u8)) !void {
    var sink = serialize.ByteSink{ .list = out, .gpa = gpa };
    try event_log.writeLog(&sink, log);
}

// --- the sleeping / data-bearing-overlap system sets (T6, T9) -------------------------------------

const S = struct {
    x: i32,
    pub const kind_id: u16 = 1;
};
const SReg = registry.Registry(.{S});
const SW = world.World(SReg);

/// Gate-only: a global io the fixture systems read so they can perform an in-process Io sleep (SimCtx
/// has no io by design — D3). The sleep touches NO hashed state, so the per-tick hash stays
/// deterministic; only wall-clock differs. Set under T6/T9 only, restored via defer.
var gate_io: ?std.Io = null;
const SLEEP_MS: u64 = 40;

fn sleepGate() void {
    if (gate_io) |io| {
        const dur = std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(SLEEP_MS) };
        dur.sleep(io) catch {};
    }
}
// Read-only (Read(S)) → no conflict → all sleepers share ONE stage; the same fn registered K times.
fn sleeper(ctx: *SimCtx(SReg), q: *Query(SReg, .{Read(S)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
    sleepGate();
}
const sleep4 = [_]Sys(SReg){
    schedule.system(SReg, "s0", sleeper), schedule.system(SReg, "s1", sleeper),
    schedule.system(SReg, "s2", sleeper), schedule.system(SReg, "s3", sleeper),
};
const sleep8 = [_]Sys(SReg){
    schedule.system(SReg, "s0", sleeper), schedule.system(SReg, "s1", sleeper),
    schedule.system(SReg, "s2", sleeper), schedule.system(SReg, "s3", sleeper),
    schedule.system(SReg, "s4", sleeper), schedule.system(SReg, "s5", sleeper),
    schedule.system(SReg, "s6", sleeper), schedule.system(SReg, "s7", sleeper),
};

fn sSeed(gpa: std.mem.Allocator) !SW {
    var w = SW.init(1);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, S, .{ .x = 0 });
    return w;
}

fn sleepTickMs(gpa: std.mem.Allocator, comptime sset: []const Sys(SReg), io: ?std.Io, n: usize, clock_io: std.Io) !u64 {
    var w = try sSeed(gpa);
    defer w.deinit(gpa);
    w.tick +%= 1;
    const exec = comptime &schedule.Schedule(SReg, sset).exec_order;
    const t0 = std.Io.Clock.now(.awake, clock_io);
    try step_par.runScheduledPar(SReg, &w, gpa, sset, exec, null, io, n);
    const t1 = std.Io.Clock.now(.awake, clock_io);
    return @intCast(@divTrunc(t1.nanoseconds - t0.nanoseconds, std.time.ns_per_ms));
}

// T9's set: FOUR systems that each write a DISJOINT column → one 4-member stage. They additionally
// sleep (so they provably overlap in wall-clock), and they draw keyed RNG (ow0) and emit (ow1) — so a
// single test forces the disjoint-column-write, concurrent-RNG, and concurrent-emit paths to run
// SIMULTANEOUSLY, then asserts the result is bit-identical to serial (no race) AND overlapped (genuine).
const C0 = struct {
    v: i32,
    pub const kind_id: u16 = 1;
};
const C1 = struct {
    v: i32,
    pub const kind_id: u16 = 2;
};
const C2 = struct {
    v: i32,
    pub const kind_id: u16 = 3;
};
const C3 = struct {
    v: i32,
    pub const kind_id: u16 = 4;
};
const OWReg = registry.Registry(.{ C0, C1, C2, C3 });
const OWW = world.World(OWReg);
const OwEv = struct {
    n: i32,
    pub const kind_id: u16 = 51;
};
fn ow0(ctx: *SimCtx(OWReg), q: *Query(OWReg, .{Write(C0)})) std.mem.Allocator.Error!void {
    sleepGate();
    while (q.next()) |row| {
        const e = row.entity();
        row.write(C0).v += @as(i32, @intCast(ctx.rng(e.index, 0) % 5)); // concurrent keyed RNG draw
    }
}
fn ow1(ctx: *SimCtx(OWReg), q: *Query(OWReg, .{Write(C1)})) std.mem.Allocator.Error!void {
    sleepGate();
    while (q.next()) |row| row.write(C1).v += 7;
    _ = try ctx.emitS(OwEv, E0, .{ .n = 1 }); // concurrent sub-recorder emit
}
fn ow2(ctx: *SimCtx(OWReg), q: *Query(OWReg, .{Write(C2)})) std.mem.Allocator.Error!void {
    _ = ctx;
    sleepGate();
    while (q.next()) |row| row.write(C2).v += 11;
}
fn ow3(ctx: *SimCtx(OWReg), q: *Query(OWReg, .{Write(C3)})) std.mem.Allocator.Error!void {
    _ = ctx;
    sleepGate();
    while (q.next()) |row| row.write(C3).v += 13;
}
const ow_systems = [_]Sys(OWReg){
    schedule.system(OWReg, "ow0", ow0), schedule.system(OWReg, "ow1", ow1),
    schedule.system(OWReg, "ow2", ow2), schedule.system(OWReg, "ow3", ow3),
};
fn owSeed(gpa: std.mem.Allocator) !OWW {
    var w = OWW.init(0xA5A5);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, C0, .{ .v = 0 });
    w.add(e, C1, .{ .v = 0 });
    w.add(e, C2, .{ .v = 0 });
    w.add(e, C3, .{ .v = 0 });
    return w;
}

// T10's set: two disjoint writers, one deliberately returns error.OutOfMemory (a "system fault").
fn okSys(ctx: *SimCtx(OWReg), q: *Query(OWReg, .{Write(C0)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(C0).v += 1;
}
fn oomSys(ctx: *SimCtx(OWReg), q: *Query(OWReg, .{Write(C1)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = q;
    return error.OutOfMemory; // a task fault that group.async would `catch {}`-drop if not captured
}
const oom_set = [_]Sys(OWReg){ schedule.system(OWReg, "ok", okSys), schedule.system(OWReg, "oom", oomSys) };

// --- pinned cross-build (D2) witnesses; recompute via dumpPin (standalone) -------------------------
const PIN_FINAL: u64 = 671562654818080236;
const PIN_STREAM: u64 = 4839735521086686451;
const PIN_LOG: u64 = 11505390851613485242;

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

test "T0: the system set has a genuine multi-member parallel stage" {
    const Sched = schedule.Schedule(FReg, &fsystems);
    try testing.expectEqual(@as(usize, 2), Sched.stage_count); // {writeA,writeB,writeC} | {gather}
    try testing.expectEqual(@as(usize, 1), schedule.Schedule(SReg, &sleep4).stage_count);
    try testing.expectEqual(@as(usize, 1), schedule.Schedule(SReg, &sleep8).stage_count);
    try testing.expectEqual(@as(usize, 1), schedule.Schedule(OWReg, &ow_systems).stage_count); // 4-wide
}

test "T1: threaded per-tick stream == single-threaded, bit for bit (FORCED overlap)" {
    const gpa = testing.allocator;
    const exec = comptime &schedule.Schedule(FReg, &fsystems).exec_order;
    const fo = ForceOverlap.begin(); // force the column-write/RNG/emit stage onto real threads, any host
    defer fo.end();
    const ser = try fRunSer(gpa, TICKS);
    const par = try fRunPar(gpa, TICKS, std.testing.io, 8, exec);
    try testing.expectEqual(ser.stream, par.stream);
    try testing.expectEqual(ser.final, par.final);
}

test "T2: pinned cross-build (Debug==ReleaseSafe==ReleaseFast) bit-identity of the threaded path" {
    const gpa = testing.allocator;
    const exec = comptime &schedule.Schedule(FReg, &fsystems).exec_order;
    const fo = ForceOverlap.begin();
    defer fo.end();
    const par = try fRunPar(gpa, TICKS, std.testing.io, 8, exec);
    try testing.expectEqual(PIN_FINAL, par.final);
    try testing.expectEqual(PIN_STREAM, par.stream);
}

test "T3: repeated FORCED-overlap runs all yield the identical stream (scheduling never leaks into state)" {
    const gpa = testing.allocator;
    const exec = comptime &schedule.Schedule(FReg, &fsystems).exec_order;
    const fo = ForceOverlap.begin();
    defer fo.end();
    const first = try fRunPar(gpa, TICKS, std.testing.io, 8, exec);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const r = try fRunPar(gpa, TICKS, std.testing.io, 8, exec);
        try testing.expectEqual(first.stream, r.stream);
        try testing.expectEqual(first.final, r.final);
    }
}

test "T4: recording-on merged log is byte-identical to single-threaded (FORCED overlap)" {
    const gpa = testing.allocator;
    const exec = comptime &schedule.Schedule(FReg, &fsystems).exec_order;
    const fo = ForceOverlap.begin(); // force concurrent sub-recorder emits feeding mergeSubLogs
    defer fo.end();

    var rec_ser = recorder.Recorder.init(gpa);
    defer rec_ser.deinit();
    try fRunSerRec(gpa, TICKS, exec, &rec_ser);

    var rec_par = recorder.Recorder.init(gpa);
    defer rec_par.deinit();
    try fRunParRec(gpa, TICKS, std.testing.io, 8, exec, &rec_par);

    var b_ser: std.ArrayList(u8) = .empty;
    defer b_ser.deinit(gpa);
    var b_par: std.ArrayList(u8) = .empty;
    defer b_par.deinit(gpa);
    try logBytes(gpa, &rec_ser.log, &b_ser);
    try logBytes(gpa, &rec_par.log, &b_par);

    try testing.expectEqualSlices(u8, b_ser.items, b_par.items); // byte-for-byte
    try testing.expectEqual(event_log.logDigest(&rec_ser.log).hash, event_log.logDigest(&rec_par.log).hash);
    try testing.expectEqual(PIN_LOG, event_log.logDigest(&rec_par.log).hash); // cross-build pin
    // recording must not perturb the hashed World (events are pure side-output, even under threads).
    const par_off = try fRunPar(gpa, TICKS, std.testing.io, 8, exec);
    try testing.expectEqual(PIN_FINAL, par_off.final);
}

test "T5: order-permutation under threads — within-stage permutation yields identical stream AND log" {
    const gpa = testing.allocator;
    const canon = comptime &schedule.Schedule(FReg, &fsystems).exec_order; // [0,1,2,3]
    const permuted = [_]u16{ 2, 1, 0, 3 }; // swap stage-0 ids writeA<->writeC; still stage-respecting
    const fo = ForceOverlap.begin();
    defer fo.end();

    const a = try fRunPar(gpa, TICKS, std.testing.io, 8, canon);
    const b = try fRunPar(gpa, TICKS, std.testing.io, 8, &permuted);
    try testing.expectEqual(a.stream, b.stream);
    try testing.expectEqual(a.final, b.final);

    // the MERGED LOG under a within-stage permutation must also equal the serial-permuted log (the merge
    // is exec-ordered, so a permuted exec produces a permuted-but-consistent log on BOTH paths).
    var lp_ser = recorder.Recorder.init(gpa);
    defer lp_ser.deinit();
    try fRunSerRec(gpa, TICKS, &permuted, &lp_ser);
    var lp_par = recorder.Recorder.init(gpa);
    defer lp_par.deinit();
    try fRunParRec(gpa, TICKS, std.testing.io, 8, &permuted, &lp_par);
    var bs: std.ArrayList(u8) = .empty;
    defer bs.deinit(gpa);
    var bp: std.ArrayList(u8) = .empty;
    defer bp.deinit(gpa);
    try logBytes(gpa, &lp_ser.log, &bs);
    try logBytes(gpa, &lp_par.log, &bp);
    try testing.expectEqualSlices(u8, bs.items, bp.items);
}

test "T6: ACTUAL overlap — a wide read-only stage runs concurrently, robust to core count" {
    if (builtin.single_threaded) return error.SkipZigTest; // no threads to overlap — honest skip (§13.6)
    const gpa = testing.allocator;
    const io = std.testing.io;
    gate_io = io;
    defer gate_io = null;
    const fo = ForceOverlap.begin();
    defer fo.end();

    // narrow (K=4) and wide (K=8) — both must overlap (proves it scales, not a core-count artifact).
    inline for (.{ sleep4, sleep8 }) |sset| {
        const par_ms = try sleepTickMs(gpa, &sset, io, 8, io); // parallel
        const seq_ms = try sleepTickMs(gpa, &sset, null, 1, io); // serial (delegates to runScheduled)
        try testing.expect(par_ms * 100 < seq_ms * 60); // parallel < 60% of serial — huge margin
    }
}

test "T9: DATA-BEARING overlap — concurrent disjoint-column writes + RNG + emit overlap AND stay race-free" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = std.testing.io;
    gate_io = io;
    defer gate_io = null;
    const fo = ForceOverlap.begin();
    defer fo.end();
    const exec = comptime &schedule.Schedule(OWReg, &ow_systems).exec_order;

    // serial baseline: the 4 writers run one-after-another, each sleeping → ~4 sleeps.
    var ws = try owSeed(gpa);
    defer ws.deinit(gpa);
    ws.tick +%= 1;
    const s0 = std.Io.Clock.now(.awake, io);
    try step_par.runScheduledPar(OWReg, &ws, gpa, &ow_systems, exec, null, null, 1);
    const s1 = std.Io.Clock.now(.awake, io);
    const seq_ms: u64 = @intCast(@divTrunc(s1.nanoseconds - s0.nanoseconds, std.time.ns_per_ms));

    // parallel: the 4 writers (disjoint columns + RNG + emit) execute SIMULTANEOUSLY → ~1 sleep.
    var wp = try owSeed(gpa);
    defer wp.deinit(gpa);
    wp.tick +%= 1;
    const p0 = std.Io.Clock.now(.awake, io);
    try step_par.runScheduledPar(OWReg, &wp, gpa, &ow_systems, exec, null, io, 8);
    const p1 = std.Io.Clock.now(.awake, io);
    const par_ms: u64 = @intCast(@divTrunc(p1.nanoseconds - p0.nanoseconds, std.time.ns_per_ms));

    // (i) race-freedom: concurrent disjoint-column writes + concurrent keyed RNG produce the serial result.
    try testing.expectEqual((try ws.digest(gpa)).hash, (try wp.digest(gpa)).hash);
    // (ii) genuine overlap of the DATA-BEARING path (not just read-only sleepers).
    try testing.expect(par_ms * 100 < seq_ms * 60);
}

test "T7: degenerate delegation — io==null and n_threads<=1 match the serial path exactly" {
    const gpa = testing.allocator;
    const exec = comptime &schedule.Schedule(FReg, &fsystems).exec_order;
    const ser = try fRunSer(gpa, TICKS);
    const par_null = try fRunPar(gpa, TICKS, null, 8, exec); // io==null → serial
    const par_one = try fRunPar(gpa, TICKS, std.testing.io, 1, exec); // n_threads==1 → serial
    try testing.expectEqual(ser.final, par_null.final);
    try testing.expectEqual(ser.stream, par_null.stream);
    try testing.expectEqual(ser.final, par_one.final);

    // empty systems: the parallel entry still runs the input-command prologue.
    const no_sys = [_]Sys(FReg){};
    const spawn1 = [_]input.Command{.{ .actor = .{ .index = 0, .generation = 0 }, .verb = 1 }};
    var w0 = FW.init(3);
    defer w0.deinit(gpa);
    var w1 = try step_par.stepExecPar(FReg, gpa, w0, .{ .tick = 1, .commands = &spawn1 }, &no_sys, &.{}, null, std.testing.io, 8);
    defer w1.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), w1.table.rowCount());
}

test "T8: arena lifetime — a 2-tick recording run never reads freed sub-log bytes (UAF guard)" {
    const gpa = testing.allocator;
    const exec = comptime &schedule.Schedule(FReg, &fsystems).exec_order;
    const fo = ForceOverlap.begin();
    defer fo.end();
    var rec_ser = recorder.Recorder.init(gpa);
    defer rec_ser.deinit();
    try fRunSerRec(gpa, 2, exec, &rec_ser);
    var rec_par = recorder.Recorder.init(gpa);
    defer rec_par.deinit();
    try fRunParRec(gpa, 2, std.testing.io, 8, exec, &rec_par);
    try testing.expectEqual(event_log.logDigest(&rec_ser.log).hash, event_log.logDigest(&rec_par.log).hash);
}

test "T10: a system's error is SURFACED in ascending-sid order (not swallowed by Group.async catch{})" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    const fo = ForceOverlap.begin();
    defer fo.end();
    var w = try owSeed(gpa);
    defer w.deinit(gpa);
    w.tick +%= 1;
    const exec = comptime &schedule.Schedule(OWReg, &oom_set).exec_order;
    // ok (sid 0) + oom (sid 1) share one stage; runScheduledPar must surface the captured OOM, not drop it.
    try testing.expectError(error.OutOfMemory, step_par.runScheduledPar(OWReg, &w, gpa, &oom_set, exec, null, io, 8));
}

test "T11: stepExecPar OOM is clean (no leak; success-or-OutOfMemory) under a FailingAllocator" {
    // io==null path: exercises stepExecPar's clone/prologue/runScheduled/drain + errdefer teardown across
    // every allocation point. The underlying testing.allocator's leak detector enforces no-leak. (The
    // threaded arena path's task-fault surfacing is witnessed by T10; FailingAllocator's counter is not
    // thread-safe, so the leak sweep runs on the serial-delegation path.)
    const exec = comptime &schedule.Schedule(FReg, &fsystems).exec_order;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = fa.allocator();
        var w0 = fSeed(gpa, NENT) catch |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            continue;
        };
        defer w0.deinit(gpa);
        var w1 = step_par.stepExecPar(FReg, gpa, w0, empty_in, &fsystems, exec, null, null, 1) catch |e| {
            try testing.expectEqual(error.OutOfMemory, e); // clean failure, no leak (errdefer freed w1's clone)
            continue;
        };
        w1.deinit(gpa);
    }
}

test "dumpPin compiles (recompute pins by calling it from a standalone per-module run)" {
    _ = &dumpPin;
}

/// Recompute the T2/T4 pins. NOT auto-run (it prints, which corrupts `--listen`); call it from a
/// standalone `zig test -Mroot=src/step_par_gate.zig …` run to refreeze after an intentional change.
fn dumpPin(gpa: std.mem.Allocator) !void {
    const exec = comptime &schedule.Schedule(FReg, &fsystems).exec_order;
    const r = try fRunPar(gpa, TICKS, std.testing.io, 8, exec);
    std.debug.print("PIN_FINAL={d} PIN_STREAM={d}\n", .{ r.final, r.stream });
    var rec = recorder.Recorder.init(gpa);
    defer rec.deinit();
    try fRunParRec(gpa, TICKS, std.testing.io, 8, exec, &rec);
    std.debug.print("PIN_LOG={d}\n", .{event_log.logDigest(&rec.log).hash});
}
