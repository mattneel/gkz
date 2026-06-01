---
name: gkz-measure
description: How to DRIVE and MEASURE a gkz sim in Zig — the author's loop: step + observe, snapshot/replay, fork to A/B a tweak, sweep a metric across seeds, VOPR a defect into a minimal repro, and read provenance. Use when running/measuring/iterating on a gkz game (write a Zig harness or test; there is no CLI). Anchored on examples/roguelike/src/main.zig.
---

# Driving + measuring a gkz sim

You drive gkz by writing a Zig harness (a `main` or a `test`) that calls the library, running it with
`zig build run` / `zig build test`, and reading the output. There is no CLI/socket/MCP — the library IS
the interface. Read `examples/roguelike/src/main.zig` alongside this; it demonstrates every step below.
Read `gkz-authoring` for how the sim being driven is defined.

Throughout: `R` = your registry, `game.systems` = your `Sys(R)` slice, `gpa` = an allocator.

## 1. Step — the pure tick

`gkz.step(R, gpa, prev, input, systems)` is `(World, Input) → World`. It clones, advances the tick,
applies the input's commands, runs the systems, drains the command buffer. Own the loop:

```zig
var w = try game.seedWorld(gpa, seed);
defer w.deinit(gpa);
var t: usize = 0;
while (t < n) : (t += 1) {
    const next = try gkz.step(R, gpa, w, gkz.input.EMPTY, &game.systems); // EMPTY = no exogenous input
    w.deinit(gpa);
    w = next;
}
const h = (try w.digest(gpa)).hash;   // the per-tick content hash — same seed ⇒ same hash, every build mode
```

Drive a *player* by passing a non-empty `gkz.Input{ .tick, .commands }` (recorded inputs are the only
nondeterminism ingress, and replaying them reproduces a run exactly).

## 2. Observe — read state read-only

`w.iterate(C)` yields every live entity carrying `C` (`.entity`, `.value: *const C`); `w.getConst(e, C)`
reads another component. (A *system* uses a `Query`; this is the outside-a-system front door.)

```zig
var it = w.iterate(game.Position);
while (it.next()) |row| {
    const hp = w.getConst(row.entity, game.Health).?.hp;
    // … inspect row.value.x, row.value.y, hp …
}
```

For the relational §7 surface (component/event/caused-by/system queries, wire-serializable for an external
client) use `gkz.QueryEngine(R, systems).init(&w, &log)` + `gkz.query_wire`.

## 3. Snapshot / replay — reproduce bit-exactly

```zig
var snap = try gkz.snapshot(R, gpa, &w);  defer snap.deinit(gpa);
var w2 = try gkz.restore(R, gpa, snap);   defer w2.deinit(gpa);
// running w and w2 forward the same number of ticks yields the IDENTICAL digest
```

## 4. Fork — A/B from one state

Clone a mid-run World, change one thing (a stat, a tuning), run both, compare — two timelines from the
*identical* start. This is balance experimentation:

```zig
var base   = try runTicks(gpa, try w.clone(gpa), 30);  defer base.deinit(gpa);
var buffed = try w.clone(gpa);
if (buffed.get(game.HERO, game.Power)) |p| p.atk += 6;  // the tweak
buffed = try runTicks(gpa, buffed, 30);                 defer buffed.deinit(gpa);
// compare base vs buffed (hero hp, monsters left, who won) — the buff's measured effect
```

## 5. Sweep a metric — balance as a distribution

`gkz.spec.metric.aggregate` runs a metric across a seed range and reduces it (count/min/max/sum — integer,
no float):

```zig
const agg = try gkz.spec.metric.aggregate(
    R, &game.systems, &game.atoms, false, u64, gpa,
    game.seedWorld, gkz.idleGen(R), game.turnsSurvived(),
    0, 200, 80,   // seeds [0,200), max 80 ticks each
);
// agg.count, agg.min, agg.max, agg.sum  → the distribution of your fun-proxy across 200 playthroughs
```

(`gkz.idleGen(R)` is the no-input generator; supply a scripted/agent generator to drive a player.)

## 6. VOPR — find + minimize a defect

`gkz.sweep` runs an Oracle across seeds and returns minimized `DefectReport`s (each carries the
`(seed, tick, oracle)` + a minimized repro + a cause chain). Build an invariant oracle from your spec:

```zig
const inv = comptime game.noStackingInvariant();
const oracles = [_]gkz.Oracle(R){ gkz.spec.invariant.invariantOracle(R, &game.systems, inv) };
var reports = try gkz.sweep(R, gpa, &game.systems, game.seedWorld, gkz.idleGen(R), &oracles, 0, 300, 80);
defer { for (reports.items) |*r| r.deinit(gpa); reports.deinit(gpa); }
for (reports.items) |r| { const d = r.defect; /* d.seed, d.tick, d.oracle — a re-runnable repro */ }
```

A correct system set reports zero; a bug surfaces as the first violating `(seed, tick)`. This is how you
catch a logic/balance regression across thousands of playthroughs and get a *minimal* reproduction.

## 7. Provenance — why did X happen (§5)

Re-run a tick with a `Recorder` to capture the causal event log, *without* changing the World/hash:

```zig
var rec = gkz.Recorder.init(gpa); defer rec.deinit();
var next = try gkz.stepRec(R, gpa, w, gkz.input.EMPTY, &game.systems, &rec);
defer next.deinit(gpa);
// rec.log.count() events recorded; rec.log carries causesOf / causeChain for "why did this entity die"
```

## The loop

write systems (`gkz-authoring`) → **measure across seeds** → **fork to A/B** → **VOPR to a repro** →
iterate. Run it with `zig build test` (assertions) / `zig build run` (narrated). Memory is explicit:
`defer w.deinit(gpa)` every World, `defer snap.deinit(gpa)` every Snapshot, free the sweep reports.
