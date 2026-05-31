//! The PARALLEL scheduler twin (SPEC §4, PLAN.md §13 "Phase 2b") — real in-process multithreaded
//! execution of the comptime stage schedule. Phase 9 shipped cross-*process* parallelism; this is
//! different: THREADS inside one process running a stage's conflict-free systems against shared sim
//! state, with the per-tick hash stream and (recording-on) event log staying BIT-/BYTE-identical to the
//! single-threaded spine (`step.zig`). The spine is the canonical referent; this is an additive twin in
//! its own file (the Phase-8 `reload.zig` / Phase-9 `proc/` precedent).
//!
//! WHY IT IS SAFE (each verified against the code):
//!   * Same-stage systems are pairwise NON-conflicting (`schedule.conflict`: a write never intersects
//!     another's read-or-write, symmetric) ⇒ each component column has AT MOST ONE writer per stage and
//!     no reader of a written column co-runs with it ⇒ concurrent column writes hit DISJOINT memory
//!     (`storage.Table.column(i)` returns a distinct backing slice). No data race is possible.
//!   * Structural change stays deferred to per-system command buffers; the drain runs single-threaded
//!     after the last stage (`step.drainAndApply`, the SAME (system_id, seq) comparator — no drift).
//!   * RNG is keyed & pure (`rng.draw(root, tick, entity, stream)`), no shared cursor; `rng_root` is
//!     copied by value into each task's SimCtx. Concurrent draws are pure reads.
//!   * `group.await` is a happens-before fence (`.acq_rel`/`.acquire` in std.Io.Threaded, the same edge
//!     `proc/supervisor.zig` relies on), so stage s's writes are published before stage s+1 reads them
//!     and before the post-barrier drain.
//!   * The recorder is shared & order-sensitive, so each system records into its OWN sub-Recorder; the
//!     sub-logs are merged in `exec` order AFTER the barrier (`mergeSubLogs`), reproducing the
//!     single-threaded log BYTE-for-byte (EventIds are execution-order-independent, so only physical
//!     append order changed — and the merge fixes that). See §13.3 of PLAN.md.
//!
//! ALLOCATOR CONSTRAINT: each system runs against its OWN per-tick `ArenaAllocator` (command buffer +
//! sub-recorder), so the hot path is contention-free. Intra-arena bumps need no `gpa`; an arena
//! page-refill mid-task calls `gpa.alloc` from a worker thread, so WHEN `n_threads > 1` THE `gpa` MUST
//! BE THREAD-SAFE (`std.testing.allocator` / `DebugAllocator` qualify, as does any production
//! thread-safe allocator). The arenas are pre-warmed on the orchestrator thread to remove the
//! common-case refill. Arena addresses never enter hashed state (D8): commands carry inline value
//! payloads, sub-log entries store ids/values/u32 offsets, and `hashWorld` reads only World columns —
//! so which arena an allocation lands in is invisible to every digest (Debug==ReleaseSafe==ReleaseFast).
//!
//! TRUST BOUNDARY (unchanged from single-threaded): a CONFORMING system (declares exactly the components
//! it touches) is race-free here. A rogue system touching an undeclared column is out of contract (SPEC
//! §15 trusts the author; the §9 VOPR detects the resulting divergence) — the parallel path opens no new
//! hole. `runScheduledParDynamic` (a threaded twin over a dlopen'd runtime system set) is a declared
//! follow-on seam, not built here.

const std = @import("std");
const worldmod = @import("world.zig");
const input = @import("input.zig");
const mutation = @import("mutation.zig");
const schedule = @import("schedule.zig");
const simctx = @import("simctx.zig");
const cmdbuf = @import("command_buffer.zig");
const recorder = @import("recorder.zig");
const event_log = @import("event_log.zig");
const storage = @import("storage.zig");
const rng = @import("rng.zig");
const step = @import("step.zig");
const Sys = schedule.Sys;

pub const ParError = std.mem.Allocator.Error; // no new error set; Group task faults captured via slots

/// Per-arena warm size: a small high-water reserved on the ORCHESTRATOR thread (alloc-then-reset) so a
/// typical system's per-tick command-buffer + event allocations bump within an already-owned page and
/// never hit `gpa` concurrently. A system that allocates beyond this refills (needs the thread-safe gpa).
const ARENA_WARM: usize = 4096;

/// Bind `R` so the spawned task fn has ONLY runtime parameters (no comptime type/slice in the Group.async
/// args tuple — the `supervisor.resolveShard` discipline). `systems[sid]` is read as a runtime `Sys(R)`
/// value at the call site and passed by value.
fn Par(comptime R: type) type {
    return struct {
        /// One system's whole invocation, on whichever thread runs it. Touches only: its declared
        /// (stage-disjoint) columns via `sys.invoke`, the shared read-only `order`, by-value `tick`/
        /// `rng_root`, and its OWN `buf`/`emitter`/`err` slots (distinct addresses). No shared mutable
        /// cell. A failed allocation is captured into `err` (surfaced post-barrier in sid order) — never
        /// swallowed, since `Group.async` `catch {}`-drops the task result.
        fn runOne(
            sys: Sys(R),
            sid: u16,
            table: *storage.Table(R),
            order: []const u32,
            tick: u64,
            rng_root: rng.RngRoot,
            buf: *cmdbuf.CommandBuffer(R),
            emitter: *simctx.EventEmitter,
            err: *?ParError,
        ) void {
            var ctx = simctx.SimCtx(R){ .tick = tick, .rng_root = rng_root, .system_id = sid, .cmd = buf, .events = emitter };
            sys.invoke(&ctx, table, order) catch |e| {
                err.* = e;
            };
        }
    };
}

/// Parallel twin of `step.runScheduled`. Runs each stage's systems across an `Io.Group`, barriers
/// (`group.await`) between stages, then the SAME end-of-tick `(system_id, seq)` drain. The per-tick hash
/// is bit-identical to `runScheduled`, and (when `rec != null`) the merged log is byte-identical.
///
/// Degenerate cases collapse to the proven serial path: `io == null` OR `n_threads <= 1` delegates
/// VERBATIM to `step.runScheduled` (caller gpa, no arenas — the literal referent the bit-identity gate
/// compares against). A size-1 stage runs inline (no spawn). `exec` may be a stage-respecting within-
/// stage permutation (the §4 order-permutation property holds under threads).
///
/// `n_threads` is the parallel ENABLE (`> 1`) + the inline-last threshold; the ACTUAL degree of overlap
/// is owned by the passed `io` (its `async_limit`), NOT by `n_threads` — a caller that wants forced or
/// bounded concurrency configures the `io` (e.g. `setAsyncLimit`), as the overlap gate does.
/// CONSTRAINT (`n_threads > 1`): `gpa` must be thread-safe (per-system arena refill) — see the header.
pub fn runScheduledPar(
    comptime R: type,
    w: *worldmod.World(R),
    gpa: std.mem.Allocator,
    comptime systems: []const Sys(R),
    exec: []const u16,
    rec: ?*recorder.Recorder,
    io: ?std.Io,
    n_threads: usize,
) ParError!void {
    std.debug.assert(exec.len == systems.len);

    // Degenerate: no threads available or requested → the proven serial code, verbatim (also the
    // systems.len == 0 case — runScheduled's own comptime guard handles it).
    if (io == null or n_threads <= 1) return step.runScheduled(R, w, gpa, systems, exec, rec);

    // The threaded body builds [systems.len]-sized stack arrays, so it must be a comptime-elided branch
    // when there are no systems (a fixed [0] array cannot be indexed even on a dead path).
    if (systems.len != 0) {
        const N = systems.len;
        // The parallel path requires `exec` to be a stage-GROUPED permutation: unlike the serial path
        // (where a malformed exec is a benign wrong result), here a mis-grouped exec would co-schedule
        // CONFLICTING systems on different threads and escalate to a data race. Assert the precondition in
        // safe builds — each system exactly once, stage labels non-decreasing across exec — so a bad exec
        // is caught, never raced. Negligible cost; elided in ReleaseFast.
        if (std.debug.runtime_safety) {
            const so = comptime schedule.Schedule(R, systems).stage_of;
            var seen = [_]bool{false} ** N;
            var prev_stg: usize = 0;
            for (exec, 0..) |sid, idx| {
                std.debug.assert(sid < N and !seen[sid]);
                seen[sid] = true;
                if (idx > 0) std.debug.assert(so[sid] >= prev_stg);
                prev_stg = so[sid];
            }
        }

        // Per-system arenas, created + pre-warmed on THIS (orchestrator) thread before any fan-out.
        var arenas: [N]std.heap.ArenaAllocator = undefined;
        inline for (0..N) |i| arenas[i] = std.heap.ArenaAllocator.init(gpa);
        defer inline for (0..N) |i| arenas[i].deinit(); // runs LAST — after drain + merge consume the arenas
        inline for (0..N) |i| {
            // warm the arena to ARENA_WARM, then reset-retaining so the page is owned but empty; a
            // worker thread then bumps within it with no concurrent gpa hit (best-effort: OOM here just
            // means the first worker alloc refills — still correct under the thread-safe-gpa constraint).
            if (arenas[i].allocator().alloc(u8, ARENA_WARM)) |_| {} else |_| {}
            _ = arenas[i].reset(.retain_capacity);
        }

        var bufs: [N]cmdbuf.CommandBuffer(R) = undefined;
        inline for (0..N) |i| bufs[i] = cmdbuf.CommandBuffer(R).init(arenas[i].allocator(), @intCast(i));
        // bufs are arena-backed — no per-buffer deinit; the arena deinit frees everything.

        var subs: [N]recorder.Recorder = undefined;
        var emitters: [N]simctx.EventEmitter = undefined;
        if (rec != null) {
            inline for (0..N) |i| subs[i] = recorder.Recorder.init(arenas[i].allocator());
            inline for (0..N) |i| emitters[i] = .{ .recording = &subs[i] };
        } else {
            inline for (0..N) |i| emitters[i] = .noop;
        }

        var errs: [N]?ParError = .{null} ** N;

        // The table is structurally frozen during the run phase, so the canonical order is computed once
        // on the orchestrator thread and shared read-only by every task.
        const order = try w.table.canonicalOrder(gpa);
        defer gpa.free(order);

        // Per-stage dispatch. `exec` is stage-grouped ascending, so a stage is a CONTIGUOUS run of equal
        // comptime `stage_of[exec[k]]` — segment by stage LABEL (robust to a within-stage permutation),
        // never by position.
        const stage_of = comptime schedule.Schedule(R, systems).stage_of;
        var k: usize = 0;
        while (k < exec.len) {
            const stg = stage_of[exec[k]];
            var end = k + 1;
            while (end < exec.len and stage_of[exec[end]] == stg) : (end += 1) {}
            const slice = exec[k..end];

            if (slice.len == 1) {
                const sid = slice[0];
                Par(R).runOne(systems[sid], sid, &w.table, order, w.tick, w.rng_root, &bufs[sid], &emitters[sid], &errs[sid]);
            } else {
                // INLINE-LAST: spawn k-1 tasks, run the last sid on THIS thread (frees a pool slot, keeps
                // a core hot; mirrors supervisor.zig's inline+Group mix). `group.await` is the barrier and
                // a happens-before fence (std.Io.Threaded).
                var group: std.Io.Group = .init;
                for (slice[0 .. slice.len - 1]) |sid|
                    group.async(io.?, Par(R).runOne, .{ systems[sid], sid, &w.table, order, w.tick, w.rng_root, &bufs[sid], &emitters[sid], &errs[sid] });
                const last = slice[slice.len - 1];
                Par(R).runOne(systems[last], last, &w.table, order, w.tick, w.rng_root, &bufs[last], &emitters[last], &errs[last]);
                group.await(io.?) catch {};
            }

            // Surface this stage's allocation faults in ascending-sid order (deterministic), before
            // running the next stage on possibly-incomplete state. OOM is a failed run, not a divergence.
            for (slice) |sid| if (errs[sid]) |e| return e;
            k = end;
        }

        // Merge per-system sub-logs into the caller's recorder log, in exec order. Done BEFORE the drain
        // (recording conceptually precedes the end-of-tick drain, mirroring the spine) and BEFORE the
        // arenas are freed; the merge only reads sub-logs and writes `r.log`, independent of the drain.
        // Uses the recorder's OWN gpa so the merged log is freed consistently by `rec.deinit`.
        if (rec) |r| try mergeSubLogs(r.gpa, &r.log, subs[0..], exec);

        // Drain (single-threaded, after the last barrier) — byte-identical to runScheduled.
        try step.drainAndApply(R, w, gpa, bufs[0..]);
    }
}

/// Merge per-system sub-logs into `dst` in `exec` order (stages ascending, ascending sid within a stage),
/// reproducing the single-threaded `EventLog` BYTE-for-byte. Slices each sub-log's arenas by the event's
/// OWN offsets (`payload_off/len`, `cause_off/len`) — the direct-slice merge, no O(n²) find-by-id.
/// `EventLog.append` re-bases the offsets into `dst`'s arenas and copies the bytes in append order, so
/// `writeLog(dst)` == `writeLog(single_threaded_log)` ⇒ `logDigest` identical. Public so the gate can
/// drive it directly. `gpa` must be the allocator that owns (and will free) `dst`.
pub fn mergeSubLogs(
    gpa: std.mem.Allocator,
    dst: *event_log.EventLog,
    subs: []const recorder.Recorder,
    exec: []const u16,
) ParError!void {
    for (exec) |sid| {
        const src = &subs[sid].log;
        for (src.events.items) |e| {
            const payload = src.payload_arena.items[e.payload_off..][0..e.payload_len];
            const causes = src.edge_arena.items[e.cause_off..][0..e.cause_len];
            try dst.append(gpa, e.id, e.kind, e.emitter, e.subject, payload, causes);
        }
    }
}

/// Parallel twin of `step.stepExec`: the full per-tick transform (clone, tick +%1, single-threaded
/// input-command prologue, parallel system run, single-threaded drain). Only the system run is parallel.
pub fn stepExecPar(
    comptime R: type,
    gpa: std.mem.Allocator,
    prev: worldmod.World(R),
    in: input.Input,
    comptime systems: []const Sys(R),
    exec: []const u16,
    rec: ?*recorder.Recorder,
    io: ?std.Io,
    n_threads: usize,
) ParError!worldmod.World(R) {
    var w = try prev.clone(gpa);
    errdefer w.deinit(gpa);
    w.tick +%= 1;
    const cmds = try input.canonicalize(gpa, in.commands);
    defer gpa.free(cmds);
    for (cmds) |c| {
        if (mutation.commandToMutation(R, c)) |m| try mutation.apply(R, &w, gpa, m);
    }
    try runScheduledPar(R, &w, gpa, systems, exec, rec, io, n_threads);
    return w;
}

/// Parallel twin of `step.stepRec`: `stepExecPar` driven by the canonical `Schedule.exec_order` (the
/// production threaded entry).
pub fn stepPar(
    comptime R: type,
    gpa: std.mem.Allocator,
    prev: worldmod.World(R),
    in: input.Input,
    comptime systems: []const Sys(R),
    rec: ?*recorder.Recorder,
    io: ?std.Io,
    n_threads: usize,
) ParError!worldmod.World(R) {
    const exec = comptime &schedule.Schedule(R, systems).exec_order;
    return stepExecPar(R, gpa, prev, in, systems, exec, rec, io, n_threads);
}

// ---------------------------------------------------------------------------------------------------
// Tests — the witness lives in step_par_gate.zig (folded into the base 3-mode matrix via root.zig).
// A couple of fast structural checks here keep the file self-testing under the per-module command.
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("registry.zig").Registry;
const query = @import("query.zig");
const Read = query.Read;
const Write = query.Write;
const Query = query.Query;
const system = schedule.system;

const A = struct {
    v: i32,
    pub const kind_id: u16 = 1;
};
const B = struct {
    v: i32,
    pub const kind_id: u16 = 2;
};
const ParReg = Registry(.{ A, B });
const PW = worldmod.World(ParReg);

fn bumpA(ctx: *simctx.SimCtx(ParReg), q: *Query(ParReg, .{Write(A)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(A).v += 1;
}
fn bumpB(ctx: *simctx.SimCtx(ParReg), q: *Query(ParReg, .{Write(B)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(B).v += 2;
}
const two_disjoint = [_]Sys(ParReg){ system(ParReg, "bumpA", bumpA), system(ParReg, "bumpB", bumpB) };

fn seedAB(gpa: std.mem.Allocator, n: u32) !PW {
    var w = PW.init(7);
    errdefer w.deinit(gpa);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const e = try w.spawn(gpa);
        w.add(e, A, .{ .v = 0 });
        w.add(e, B, .{ .v = 0 });
    }
    return w;
}

test "two disjoint writers share ONE stage (the parallel precondition)" {
    // bumpA writes A, bumpB writes B — no conflict → a single 2-member stage we can run in parallel.
    try testing.expectEqual(@as(usize, 1), schedule.Schedule(ParReg, &two_disjoint).stage_count);
}

test "io==null delegates to the serial path and matches step.runScheduled bit for bit" {
    const gpa = testing.allocator;
    var w0 = try seedAB(gpa, 4);
    defer w0.deinit(gpa);

    var a = try stepExecPar(ParReg, gpa, w0, .{ .tick = 1, .commands = &.{} }, &two_disjoint, comptime &schedule.Schedule(ParReg, &two_disjoint).exec_order, null, null, 1);
    defer a.deinit(gpa);
    var b = try step.step(ParReg, gpa, w0, .{ .tick = 1, .commands = &.{} }, &two_disjoint);
    defer b.deinit(gpa);
    try testing.expectEqual((try b.digest(gpa)).hash, (try a.digest(gpa)).hash);
    try testing.expectEqual(@as(i32, 1), a.get(.{ .index = 0, .generation = 0 }, A).?.v);
    try testing.expectEqual(@as(i32, 2), a.get(.{ .index = 0, .generation = 0 }, B).?.v);
}

test "threaded run (testing.io, n=4) equals the single-threaded successor" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    var w0 = try seedAB(gpa, 8);
    defer w0.deinit(gpa);

    var par = try stepPar(ParReg, gpa, w0, .{ .tick = 1, .commands = &.{} }, &two_disjoint, null, io, 4);
    defer par.deinit(gpa);
    var ser = try step.step(ParReg, gpa, w0, .{ .tick = 1, .commands = &.{} }, &two_disjoint);
    defer ser.deinit(gpa);
    try testing.expectEqual((try ser.digest(gpa)).hash, (try par.digest(gpa)).hash);
}
