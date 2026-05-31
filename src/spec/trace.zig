//! The shared projected-scalar Trace (PLAN.md Phase 6, build-order step 5): the single substrate every
//! temporal combinator and metric folds over.
//!
//! ONE O(T) forward replay (restore@0 + `stepRec`, the buildRun trajectory) samples each declared `Atom`
//! into `[]bool` (holds) + `[]i64` (scalar) columns per tick, and — when `want_log` — keeps a single
//! Recorder's `EventLog` (events are hash-invariant, Phase 3, so the trajectory is unchanged). It stores
//! NO Worlds and NO per-tick QueryResults — just the projected scalar columns. This is strictly cheaper
//! than the per-property O(T²) `worldAt` rescan `oracle.invariant` uses, and SPEC wants metrics measured
//! "cheaply across many fast-forwarded runs".
//!
//! THE LOAD-BEARING DETERMINISM CROSS-CHECK: build recomputes each tick's World digest and asserts it
//! equals `run.hashes[t-1]` (returning `error.TraceDiverged` on mismatch). Since the replay uses the same
//! `stepRec` trajectory that produced `run.hashes`, this must hold — and it converts the one silent
//! trace-reconstruction assumption (esp. the `want_log` Recorder rerun) into a hard, build-mode-checked
//! tripwire: a probe sampled on a subtly different branch, or a rerun that diverges, fails at build.

const std = @import("std");
const Allocator = std.mem.Allocator;
const worldmod = @import("../world.zig");
const atom = @import("atom.zig");
const Atom = atom.Atom;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const runmod = @import("../vopr/run.zig");
const stepmod = @import("../step.zig");
const recordermod = @import("../recorder.zig");
const snapshotmod = @import("../snapshot.zig");
const event_log = @import("../event_log.zig");
const EventId = @import("../event.zig").EventId;

pub const Error = error{TraceDiverged} || Allocator.Error;

/// A read-only projected trace over a Run. R-agnostic (holds only bool/i64 columns + an R-agnostic
/// Recorder), so it is a plain struct; `build` is the R-specific producer. Columns flatten as
/// `atom_id * ticks + (t-1)`.
pub const Trace = struct {
    const Self = @This();
    ticks: usize, // == run.inputs.len (ticks 1..=ticks)
    atom_count: usize,
    holds_col: []bool,
    scalar_col: []i64,
    witness_col: []atom.Witness, // per (atom, tick) — so a combinator can pin the offending entities
    recorder: ?recordermod.Recorder, // owns the EventLog when want_log

    /// Whether atom `atom_id` holds at tick `t` (1-based).
    pub fn holds(self: *const Self, atom_id: usize, t: u64) bool {
        return self.holds_col[atom_id * self.ticks + (t - 1)];
    }
    /// Atom `atom_id`'s scalar at tick `t` (1-based).
    pub fn scalar(self: *const Self, atom_id: usize, t: u64) i64 {
        return self.scalar_col[atom_id * self.ticks + (t - 1)];
    }
    /// Atom `atom_id`'s witness at tick `t` (1-based) — the entities it implicated at that tick.
    pub fn witnessAt(self: *const Self, atom_id: usize, t: u64) atom.Witness {
        return self.witness_col[atom_id * self.ticks + (t - 1)];
    }
    pub fn len(self: *const Self) usize {
        return self.ticks;
    }
    /// The borrowed EventLog (null unless built with want_log).
    pub fn log(self: *const Self) ?*const event_log.EventLog {
        if (self.recorder) |*r| return &r.log;
        return null;
    }
    /// True iff an event of `kind_id` was emitted at tick `t` (for `monotonic_unless`'s "except on").
    pub fn hasEventKind(self: *const Self, t: u64, kind_id: u16) bool {
        if (self.log()) |l| return atom.hasEventKind(l, t, kind_id);
        return false;
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        gpa.free(self.holds_col);
        gpa.free(self.scalar_col);
        gpa.free(self.witness_col);
        if (self.recorder) |*r| r.deinit();
        self.* = undefined;
    }
};

/// Build a Trace from `run` by one forward replay, sampling `atoms` per tick. `want_log` keeps a Recorder
/// EventLog (only pay the recording cost when a property/metric needs events). Asserts the replay's
/// per-tick World hash equals `run.hashes` (the determinism cross-check). Caller `deinit`s the Trace.
pub fn build(
    comptime R: type,
    gpa: Allocator,
    run: *const runmod.Run(R),
    comptime systems: []const Sys(R),
    comptime atoms: []const Atom(R),
    want_log: bool,
) Error!Trace {
    const ticks = run.inputs.len;
    const n = atoms.len;

    var holds_col = try gpa.alloc(bool, n * ticks);
    errdefer gpa.free(holds_col);
    var scalar_col = try gpa.alloc(i64, n * ticks);
    errdefer gpa.free(scalar_col);
    var witness_col = try gpa.alloc(atom.Witness, n * ticks);
    errdefer gpa.free(witness_col);

    var recorder_opt: ?recordermod.Recorder = if (want_log) recordermod.Recorder.init(gpa) else null;
    errdefer if (recorder_opt) |*r| r.deinit();

    var w = snapshotmod.restore(R, gpa, run.base) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // run.base is a kernel-produced valid snapshot
    };
    defer w.deinit(gpa); // single deinit of the final World (loop frees intermediates)

    var t: usize = 0;
    while (t < ticks) : (t += 1) {
        const rec_ptr: ?*recordermod.Recorder = if (recorder_opt) |*r| r else null;
        const nxt = try stepmod.stepRec(R, gpa, w, run.inputs[t], systems, rec_ptr);
        w.deinit(gpa);
        w = nxt;
        // sample every atom at this tick (the post-step World IS tick t+1's World)
        inline for (atoms, 0..) |a, ai| {
            const hit = a.eval(&w);
            holds_col[ai * ticks + t] = hit.holds;
            scalar_col[ai * ticks + t] = hit.scalar;
            witness_col[ai * ticks + t] = hit.witness;
        }
        // cross-check: the replayed tick hash must equal the run's recorded hash (D2/D5 tripwire)
        const h = (try w.digest(gpa)).hash;
        if (h != run.hashes[t]) return error.TraceDiverged;
    }

    return .{
        .ticks = ticks,
        .atom_count = n,
        .holds_col = holds_col,
        .scalar_col = scalar_col,
        .witness_col = witness_col,
        .recorder = recorder_opt,
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const query = @import("../query.zig");
const simctx = @import("../simctx.zig");
const Write = query.Write;
const Query = query.Query;
const SimCtx = simctx.SimCtx;
const system = schedule.system;
const generator = @import("../vopr/generator.zig");
const runfns = runmod;

const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Health});
fn drain(ctx: *SimCtx(Game), q: *Query(Game, .{Write(Health)})) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Health).hp -= 1;
}
const game_systems = [_]Sys(Game){system(Game, "drain", drain)};
const hp_atom = atom.scalarField(Game, Health, "hp", .{ .index = 0, .generation = 0 });
const dead_atom = atom.fieldLE(Game, Health, "hp", .{ .index = 0, .generation = 0 }, 0);
const trace_atoms = [_]Atom(Game){ hp_atom, dead_atom };

fn mkRun(gpa: Allocator) !runmod.Run(Game) {
    const w0 = blk: { // construction errdefer ends before buildRun consumes w0 (no double-free)
        var w = worldmod.World(Game).init(0);
        errdefer w.deinit(gpa);
        const e = try w.spawn(gpa);
        w.add(e, Health, .{ .hp = 3 }); // hp: t1=2,t2=1,t3=0,t4=-1,t5=-2
        break :blk w;
    };
    return runmod.buildRun(Game, gpa, &game_systems, w0, 0, generator.idleGen(Game), 5);
}

test "Trace.build: per-tick projection digest equals run.hashes (the cross-check); columns match" {
    const gpa = testing.allocator;
    var run = try mkRun(gpa);
    defer run.deinit(gpa);
    var tr = try build(Game, gpa, &run, &game_systems, &trace_atoms, false);
    defer tr.deinit(gpa);

    try testing.expectEqual(@as(usize, 5), tr.len());
    // scalar column = hp per tick: 2,1,0,-1,-2
    try testing.expectEqual(@as(i64, 2), tr.scalar(0, 1));
    try testing.expectEqual(@as(i64, 0), tr.scalar(0, 3));
    try testing.expectEqual(@as(i64, -2), tr.scalar(0, 5));
    // dead atom (hp<=0): false,false,true,true,true
    try testing.expect(!tr.holds(1, 1));
    try testing.expect(!tr.holds(1, 2));
    try testing.expect(tr.holds(1, 3));
    try testing.expect(tr.holds(1, 5));
    // (build would have returned error.TraceDiverged if any tick hash != run.hashes)
}

test "Trace.build returns error.TraceDiverged if a tick's projected hash != run.hashes (the cross-check fires)" {
    const gpa = testing.allocator;
    var run = try mkRun(gpa);
    defer run.deinit(gpa);
    // perturb one recorded hash so the replayed tick can't match — the load-bearing cross-check must trip
    const hashes_mut = @constCast(run.hashes);
    hashes_mut[2] ^= 1;
    try testing.expectError(error.TraceDiverged, build(Game, gpa, &run, &game_systems, &trace_atoms, false));
    hashes_mut[2] ^= 1; // restore so run.deinit is consistent (not required — deinit frees regardless)
}

test "Trace.build want_log keeps an EventLog whose presence does not change the trajectory" {
    const gpa = testing.allocator;
    var run = try mkRun(gpa);
    defer run.deinit(gpa);
    // want_log=true builds with a Recorder; the cross-check (tick hash == run.hashes) still holds,
    // which IS the events-OFF==events-ON guarantee re-asserted over the trace.
    var tr = try build(Game, gpa, &run, &game_systems, &trace_atoms, true);
    defer tr.deinit(gpa);
    try testing.expect(tr.log() != null);
    // hp column identical to the want_log=false build
    var tr2 = try build(Game, gpa, &run, &game_systems, &trace_atoms, false);
    defer tr2.deinit(gpa);
    var t: u64 = 1;
    while (t <= 5) : (t += 1) try testing.expectEqual(tr2.scalar(0, t), tr.scalar(0, t));
}
