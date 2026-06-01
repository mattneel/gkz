# gkz example — grid roguelike

The canonical worked example for [gkz](../../): the simulation core of a small grid roguelike, built as
its **own Zig project that consumes gkz as a path dependency** — exactly how a downstream game links the
library. It is the reference for *how an AI builds a game with gkz*: author the deterministic core in Zig,
then **measure and iterate** with hard data instead of vibes.

It is headless. There are no pixels — rendering/audio/input are the SPEC §14 view seam (a renderer reads
snapshots one-way; it is not gkz's job). What you build here is the **simulation, balance, and content**.

## Run it

```sh
zig build run     # the author's measure-and-iterate loop, narrated
zig build test    # the same properties, as assertions
```

`zig build run` prints the whole loop:

```
(1) step — a deterministic tick stream (per-tick content hash):
    tick  1  digest 0x3ad335bf7039b57a  live=5
    ...
(3) snapshot + replay — reproduce a run bit-exactly:
    live run  0x0786027e187e3af8
    replayed   0x0786027e187e3af8   ✓ identical
(4) fork — A/B a balance tweak from one mid-fight state (seed 4):
    baseline (atk 5)   hero ALIVE, hp  +6, monsters left 0
    +6 atk   (atk 11)  hero ALIVE, hp +12, monsters left 0
(5) sweep — turns_survived across 200 seeds:
    seeds=200  min=11  max=81  mean=11816/200
(6) VOPR — does the no-stacking invariant hold across seeds 0..300?
    correct systems : 0 defective seeds
    buggy systems   : 271 defective seeds  → first: seed 1, invariant 'no_stacking' broke at tick 1 ...
(7) provenance — record the causal log of one combat tick:
    3 events recorded; tick digest WITH events ... == without ...  ✓ events are pure side-output
```

## Two files

| File | What it is |
|---|---|
| [`src/game.zig`](src/game.zig) | **the game** — the Registry (components), the systems (rules), the events (provenance), the specs (an invariant + a fun-proxy metric), and the seed→World builder. Pure simulation. |
| [`src/main.zig`](src/main.zig) | **the harness** — the author's loop, as ordinary Zig: step, observe, snapshot/replay, fork A/B, sweep a metric, VOPR a planted bug, record provenance. |

## The map

- **Components** `Position` `Health` `Team` `Power` — integer columns (no float, ever).
- **Systems** `seek → melee → death`. Monsters seek the hero; adjacent enemies trade blows; the dead are
  removed. Every mutation is deferred through the command buffer (`ctx.cmd`), so all systems read one
  consistent start-of-tick snapshot and the result is order-independent (the §4 "scheduling is
  nondeterministic, results never are" property — for free).
- **Specs** — an *invariant* (no two live entities share a tile = correctness) and a *metric*
  (`turns_survived` = a fun/balance proxy).
- **Planted bug** — `seekBuggy` omits the occupancy check; the VOPR catches it against the invariant
  across a seed sweep and hands back a *minimized* repro. The correct set reports zero defects.

## The loop (what `main.zig` demonstrates)

1. **step** — `step : (World, Input) → World` is pure; the World is a value. Same seed ⇒ same per-tick
   content hash, in every build mode.
2. **observe** — read live state with `w.iterate(C)` + `w.getConst` (the read-only front door; a *system*
   uses a `Query`). The AI inspects with measurement, not guesswork.
3. **snapshot + replay** — the World serializes, so a snapshot + the rest of the run reproduces bit-exactly.
4. **fork** — clone one mid-fight state into two timelines and A/B a balance tweak from the *identical*
   start. (Here, a +6 attack buff crosses the monster's 10-hp one-shot breakpoint and halves damage taken.)
5. **sweep + metric** — balance as a *distribution*: run the fun-proxy metric across 200 seeds and
   aggregate (min/mean/max), no float.
6. **VOPR** — the deterministic fuzzer finds the planted bug as an invariant violation across a seed range
   and minimizes it to a repro.
7. **provenance** — re-run a tick with a `Recorder`: every effect is recorded with its cause, *without*
   changing the World or its hash (events are pure side-output).

That is the loop an AI runs to build and balance the core of a game: **write systems → measure across
seeds → fork to A/B → VOPR to a repro → iterate.**

## How it links gkz (the downstream template)

[`build.zig.zon`](build.zig.zon) declares a path dependency:

```zig
.dependencies = .{ .gkz = .{ .path = "../.." } },
```

and [`build.zig`](build.zig) imports the module:

```zig
const gkz = b.dependency("gkz", .{ .target = target, .optimize = optimize }).module("gkz");
exe_mod.addImport("gkz", gkz);
```

A real game would `.path` to a checkout or `.url`-pin a release instead. Copy this directory as a
starting skeleton.
