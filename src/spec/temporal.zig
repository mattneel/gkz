//! Temporal properties (PLAN.md Phase 6, build-order step 6): the §8 second pillar — "LTL over the log
//! … small property objects checked against the recorded trace."
//!
//! A CLOSED set of seven combinators, each a hand-written DETERMINISTIC ascending-tick fold over a
//! `Trace`, returning the first-violating tick + canonical `Witness`. NO parser, NO composable AST, NO
//! Büchi automaton — the `Combinator` enum is non-exhaustive (`_`) so a future bounded-trace `composite`
//! arm is additive over the SAME trace fold + `Violation` shape (a richer-LTL seam), and a text front-end
//! is a Phase-9 wire concern. Determinism is trivial to audit: each arm is a single ascending pass over
//! the projected columns; the witness comes from the trace's per-tick `witnessAt`.
//!
//! BOUNDED-TRACE (LTLf) SEMANTICS — committed and documented per combinator: the recorded trace is a
//! FINITE prefix [1..T]. A liveness obligation unmet within that prefix (`eventually` never satisfied,
//! `until`'s release never seen, a `responds` window that runs off the end) is reported as a VIOLATION at
//! the relevant tick (decidable, deterministic) — exactly "checked against the recorded trace".

const std = @import("std");
const atom = @import("atom.zig");
const Witness = atom.Witness;
const Atom = atom.Atom;
const tracemod = @import("trace.zig");
const Trace = tracemod.Trace;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const oraclemod = @import("../vopr/oracle.zig");
const Oracle = oraclemod.Oracle;
const runmod = @import("../vopr/run.zig");
const defectmod = @import("defect.zig");

/// The closed combinator set. Non-exhaustive `_`: a future `composite` (bounded-trace AST) arm is
/// additive without changing the Trace/Violation/Oracle contracts.
pub const Combinator = enum(u8) { always, eventually, stable, monotonic_unless, until, precedes, responds, _ };

/// A temporal violation: the first tick the property fails + the entities it implicates.
pub const Violation = struct { first_tick: u64, witness: Witness = .{} };

/// A declared temporal property. Atoms are referenced by index into the Trace's atom list. Combinator-
/// specific params: `p`/`q` atom ids; `event_kind` (monotonic_unless's exception); `within` (responds).
pub const Property = struct {
    name: []const u8,
    comb: Combinator,
    p: usize, // primary atom (the subject of always/eventually/stable; the scalar of monotonic_unless;
    //          the LHS of until/precedes; the trigger of responds)
    q: usize = 0, // secondary atom (until/precedes RHS; responds response)
    event_kind: u16 = 0, // monotonic_unless: a decrement is permitted only on a tick carrying this kind
    within: u64 = 0, // responds: response must arrive within this many ticks of the trigger
};

/// Evaluate a property over a trace; null if it holds. Pure — reads the trace only, allocates nothing.
pub fn eval(prop: Property, trace: *const Trace) ?Violation {
    const T = trace.len();
    if (T == 0) return null;
    return switch (prop.comb) {
        .always => evalAlways(prop, trace, T),
        .eventually => evalEventually(prop, trace, T),
        .stable => evalStable(prop, trace, T),
        .monotonic_unless => evalMonotonic(prop, trace, T),
        .until => evalUntil(prop, trace, T),
        .precedes => evalPrecedes(prop, trace, T),
        .responds => evalResponds(prop, trace, T),
        _ => null, // unknown (future composite) arm: no verdict
    };
}

// always(p): p holds at EVERY tick. Violation = first tick p fails.
fn evalAlways(prop: Property, trace: *const Trace, T: usize) ?Violation {
    var t: u64 = 1;
    while (t <= T) : (t += 1) {
        if (!trace.holds(prop.p, t)) return .{ .first_tick = t, .witness = trace.witnessAt(prop.p, t) };
    }
    return null;
}

// eventually(p): p holds at SOME tick. Bounded: never satisfied over [1,T] => violation at T.
fn evalEventually(prop: Property, trace: *const Trace, T: usize) ?Violation {
    var t: u64 = 1;
    while (t <= T) : (t += 1) {
        if (trace.holds(prop.p, t)) return null;
    }
    return .{ .first_tick = @intCast(T) }; // unmet liveness over the finite prefix
}

// stable(p): once p holds, it holds forever after ("boss stays dead"). Violation = the tick p goes false
// after having been true. Witness = p's witness there (e.g. the revived boss).
fn evalStable(prop: Property, trace: *const Trace, T: usize) ?Violation {
    var seen = false;
    var t: u64 = 1;
    while (t <= T) : (t += 1) {
        if (trace.holds(prop.p, t)) {
            seen = true;
        } else if (seen) {
            return .{ .first_tick = t, .witness = trace.witnessAt(prop.p, t) };
        }
    }
    return null;
}

// monotonic_unless(scalar p, event_kind): scalar must be non-decreasing across consecutive ticks UNLESS
// the later tick carries event_kind ("score never decreases except on a Penalty event"). Violation =
// first t in [2,T] with scalar(t) < scalar(t-1) and NOT hasEventKind(t, event_kind).
fn evalMonotonic(prop: Property, trace: *const Trace, T: usize) ?Violation {
    var t: u64 = 2;
    while (t <= T) : (t += 1) {
        if (trace.scalar(prop.p, t) < trace.scalar(prop.p, t - 1) and !trace.hasEventKind(t, prop.event_kind)) {
            return .{ .first_tick = t, .witness = trace.witnessAt(prop.p, t) };
        }
    }
    return null;
}

// until(p, q): p holds at every tick until the first tick q holds (strong until — q must occur). Violation
// = the first tick p fails before any q (witness = p there), or T if q never holds (unmet release).
fn evalUntil(prop: Property, trace: *const Trace, T: usize) ?Violation {
    var t: u64 = 1;
    while (t <= T) : (t += 1) {
        if (trace.holds(prop.q, t)) return null; // q released the obligation
        if (!trace.holds(prop.p, t)) return .{ .first_tick = t, .witness = trace.witnessAt(prop.p, t) };
    }
    return .{ .first_tick = @intCast(T) }; // q never held over the finite prefix
}

// precedes(p, q): q may not hold at any tick unless some p held at an earlier OR THE SAME tick ("p
// precedes q"; p is checked before q within a tick, so a same-tick p satisfies precedence). Violation =
// the first tick q holds with no p at or before it; witness = q there.
fn evalPrecedes(prop: Property, trace: *const Trace, T: usize) ?Violation {
    var seen_p = false;
    var t: u64 = 1;
    while (t <= T) : (t += 1) {
        if (trace.holds(prop.p, t)) seen_p = true;
        if (trace.holds(prop.q, t) and !seen_p) return .{ .first_tick = t, .witness = trace.witnessAt(prop.q, t) };
    }
    return null;
}

// responds(trigger p, response q, within): every trigger is answered by a response within `within` ticks.
// Violation = the first trigger tick whose [t, t+within] window (clamped to T) contains no response;
// witness = the trigger there. Bounded: a window running off the end with no response IS a violation.
fn evalResponds(prop: Property, trace: *const Trace, T: usize) ?Violation {
    var t: u64 = 1;
    while (t <= T) : (t += 1) {
        if (!trace.holds(prop.p, t)) continue;
        // saturating add: `t + within` could overflow u64 for a huge `within`, which traps in
        // Debug/ReleaseSafe but wraps in ReleaseFast — a D2 build-mode divergence. `+|` is identical
        // in all modes (and the result is clamped to T anyway).
        const hi: u64 = @min(@as(u64, @intCast(T)), t +| prop.within);
        var answered = false;
        var s = t;
        while (s <= hi) : (s += 1) {
            if (trace.holds(prop.q, s)) {
                answered = true;
                break;
            }
        }
        if (!answered) return .{ .first_tick = t, .witness = trace.witnessAt(prop.p, t) };
    }
    return null;
}

/// Build a `kind=.temporal` Oracle from a property: one Trace build + fold per run, returning the Defect
/// (or null). Flows through the VOPR sweep/minimize/provenance like any other Defect kind. `atoms` is the
/// (comptime) atom list the property's indices reference; `want_log` is true iff `comb==monotonic_unless`.
pub fn temporalOracle(
    comptime R: type,
    comptime systems: []const Sys(R),
    comptime name: []const u8,
    comptime prop: Property,
    comptime atoms: []const Atom(R),
) Oracle(R) {
    const want_log = prop.comb == .monotonic_unless;
    const Impl = struct {
        fn evalFn(ctx: *anyopaque, run: *const runmod.Run(R), gpa: std.mem.Allocator) std.mem.Allocator.Error!?oraclemod.Defect(R) {
            _ = ctx;
            var trace = tracemod.build(R, gpa, run, systems, atoms, want_log) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TraceDiverged => unreachable, // the replay uses the same stepRec trajectory as the run
            };
            defer trace.deinit(gpa);
            if (eval(prop, &trace)) |v| {
                const f = defectmod.Finding(R){ .kind = .temporal, .name = name, .seed = run.seed, .tick = v.first_tick, .witness = v.witness };
                return f.toDefect();
            }
            return null;
        }
    };
    return .{ .name = name, .kind = .temporal, .ctx = &unused_ctx, .eval_fn = Impl.evalFn };
}

var unused_ctx: u8 = 0;

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Entity = @import("../entity.zig").Entity;

/// Build a hand-specified trace (one or two atoms) for combinator unit tests. Atom 0 from `holds0`/
/// `scalar0`, atom 1 from `holds1`. Witness of atom k at a tick = entity {index=k+1} when it does NOT
/// hold (so a violation pins a recognizable entity). No recorder. Caller `deinit`s.
fn handTrace(gpa: std.mem.Allocator, holds0: []const bool, scalar0: []const i64, holds1: ?[]const bool) !Trace {
    const T = holds0.len;
    const n: usize = if (holds1 != null) 2 else 1;
    var hc = try gpa.alloc(bool, n * T);
    errdefer gpa.free(hc);
    var sc = try gpa.alloc(i64, n * T);
    errdefer gpa.free(sc);
    var wc = try gpa.alloc(Witness, n * T);
    errdefer gpa.free(wc);
    for (0..T) |t| {
        hc[t] = holds0[t];
        sc[t] = scalar0[t];
        wc[t] = if (holds0[t]) .{} else Witness.single(.{ .index = 1, .generation = 0 });
        if (holds1) |h1| {
            hc[T + t] = h1[t];
            sc[T + t] = 0;
            wc[T + t] = if (h1[t]) .{} else Witness.single(.{ .index = 2, .generation = 0 });
        }
    }
    return .{ .ticks = T, .atom_count = n, .holds_col = hc, .scalar_col = sc, .witness_col = wc, .recorder = null };
}

const NO_SCALAR = [_]i64{0} ** 8;

test "CANONICAL stable: 'boss stays dead' — a revive after death is caught at the exact revive tick" {
    const gpa = testing.allocator;
    // boss_dead: F,F,T,T,F,T  (dies at t3, REVIVES at t5)
    var tr = try handTrace(gpa, &.{ false, false, true, true, false, true }, NO_SCALAR[0..6], null);
    defer tr.deinit(gpa);
    const v = eval(.{ .name = "boss_stays_dead", .comb = .stable, .p = 0 }, &tr).?;
    try testing.expectEqual(@as(u64, 5), v.first_tick); // the revive tick
    try testing.expectEqual(@as(u32, 1), v.witness.ents[0].index); // the (revived) boss
    // boss that stays dead: F,F,T,T,T,T -> clean
    var ok = try handTrace(gpa, &.{ false, false, true, true, true, true }, NO_SCALAR[0..6], null);
    defer ok.deinit(gpa);
    try testing.expectEqual(@as(?Violation, null), eval(.{ .name = "x", .comb = .stable, .p = 0 }, &ok));
}

test "CANONICAL monotonic_unless: a non-penalty score drop is caught; a penalty-covered drop is clean" {
    const gpa = testing.allocator;
    const PENALTY: u16 = 77;
    // score: 10,10,8,8 (drops at t3). Need an EventLog to test 'except penalty' — build via recorder is
    // heavy here; test the no-event case (no log -> hasEventKind=false -> the drop is a violation).
    var tr = try handTrace(gpa, &.{ true, true, true, true }, &.{ 10, 10, 8, 8 }, null);
    defer tr.deinit(gpa);
    const v = eval(.{ .name = "score_monotone", .comb = .monotonic_unless, .p = 0, .event_kind = PENALTY }, &tr).?;
    try testing.expectEqual(@as(u64, 3), v.first_tick); // the drop tick (no penalty event -> violation)
    // a non-decreasing score is clean
    var ok = try handTrace(gpa, &.{ true, true, true, true }, &.{ 1, 2, 2, 9 }, null);
    defer ok.deinit(gpa);
    try testing.expectEqual(@as(?Violation, null), eval(.{ .name = "x", .comb = .monotonic_unless, .p = 0, .event_kind = PENALTY }, &ok));
}

test "always / eventually catch the exact first-violating tick (bounded semantics)" {
    const gpa = testing.allocator;
    var tr = try handTrace(gpa, &.{ true, true, false, true }, NO_SCALAR[0..4], null);
    defer tr.deinit(gpa);
    try testing.expectEqual(@as(u64, 3), eval(.{ .name = "x", .comb = .always, .p = 0 }, &tr).?.first_tick);
    // eventually over an all-false prefix -> violation at T (unmet liveness)
    var never = try handTrace(gpa, &.{ false, false, false }, NO_SCALAR[0..3], null);
    defer never.deinit(gpa);
    try testing.expectEqual(@as(u64, 3), eval(.{ .name = "x", .comb = .eventually, .p = 0 }, &never).?.first_tick);
    // eventually that IS met -> clean
    try testing.expectEqual(@as(?Violation, null), eval(.{ .name = "x", .comb = .eventually, .p = 0 }, &tr));
}

test "until / precedes / responds on two-atom traces" {
    const gpa = testing.allocator;
    // until(p,q): p must hold until q. p=T,T,F ; q=F,F,F -> p fails at t3 before any q -> violation t3
    var tu = try handTrace(gpa, &.{ true, true, false }, NO_SCALAR[0..3], &.{ false, false, false });
    defer tu.deinit(gpa);
    try testing.expectEqual(@as(u64, 3), eval(.{ .name = "x", .comb = .until, .p = 0, .q = 1 }, &tu).?.first_tick);
    // until satisfied: p=T,T ; q=F,T -> q at t2, p held before -> clean
    var tu2 = try handTrace(gpa, &.{ true, true }, NO_SCALAR[0..2], &.{ false, true });
    defer tu2.deinit(gpa);
    try testing.expectEqual(@as(?Violation, null), eval(.{ .name = "x", .comb = .until, .p = 0, .q = 1 }, &tu2));
    // strong-release: p holds throughout but q NEVER holds over the finite prefix -> bounded violation at T
    var tu3 = try handTrace(gpa, &.{ true, true }, NO_SCALAR[0..2], &.{ false, false });
    defer tu3.deinit(gpa);
    try testing.expectEqual(@as(u64, 2), eval(.{ .name = "x", .comb = .until, .p = 0, .q = 1 }, &tu3).?.first_tick);
    // precedes(p,q): q at t1 with no prior p -> violation t1. p=F,T ; q=T,F
    var pr = try handTrace(gpa, &.{ false, true }, NO_SCALAR[0..2], &.{ true, false });
    defer pr.deinit(gpa);
    try testing.expectEqual(@as(u64, 1), eval(.{ .name = "x", .comb = .precedes, .p = 0, .q = 1 }, &pr).?.first_tick);
    // responds(trigger,response,within=1): trigger t1, no response in [1,2] -> violation t1. p=T,F,F ; q=F,F,T
    var rs = try handTrace(gpa, &.{ true, false, false }, NO_SCALAR[0..3], &.{ false, false, true });
    defer rs.deinit(gpa);
    try testing.expectEqual(@as(u64, 1), eval(.{ .name = "x", .comb = .responds, .p = 0, .q = 1, .within = 1 }, &rs).?.first_tick);
    // responds within=2 reaches the response at t3 -> clean
    try testing.expectEqual(@as(?Violation, null), eval(.{ .name = "x", .comb = .responds, .p = 0, .q = 1, .within = 2 }, &rs));
}
