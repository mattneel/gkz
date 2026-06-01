---
name: gkz-overview
description: Orienting overview of the gkz deterministic simulation kernel — what it is, its determinism contract, the mental model (a LIBRARY you drive by writing Zig + a measure-and-iterate loop), and when to reach for it. Read this first before authoring or driving a gkz sim.
---

# gkz — what it is

gkz is a **deterministic, fully observable, forkable simulation kernel** in Zig (lineage: TigerBeetle +
Elm/Redux + rr). The primary user is an AI. It is the simulation **core** of a game — logic, balance,
content — **not** an engine you "make a game in." Rendering/audio/input are a one-way view seam
(SPEC §14): a renderer reads snapshots; gkz never draws.

## It is a LIBRARY

There is no CLI, no daemon, no protocol you talk to. You drive gkz the way you drive any library: write
Zig against its API, run it with `zig build` / `zig test`, read the output, edit. An agent that can write
and run code does not need a remote-control surface — the library *is* the interface.

(The `proc` / control-plane / `networkExecutor` layer exists for an *optional* operational shell — running
many sims decoupled from the build, a fuzz/training fleet, cross-machine sweeps. It is the deployment
story, not how you author a game. Ignore it while building.)

## The spine (why everything else falls out)

```
step : (State, Input) -> State     // a PURE function
State (the World)                   // a VALUE — serializable, content-hashable, diffable
```

Because `step` is pure and the World is a value: record/replay, time-travel, **forks**, and divergence
detection are corollaries, not separate features. A run is fully determined by `(seed, inputs)`.

## The determinism contract (D1–D9) — the rules you MUST follow when authoring

- **No floating point on any sim path.** Integers only (the `fpz` fixed-point lib if you need fractions).
  A `Metric`/atom over a float field is a compile error.
- **No clock, no syscall, no ambient RNG** inside `step`. Randomness is a *keyed* pure function
  (`ctx.rng(entity, stream)`) — no cursor.
- **No pointers/addresses in hashed state.** Components are plain integer/struct data; cross-entity links
  are `Entity` handles, never pointers.
- **Canonical serialization, little-endian, stable total order.** The per-tick content hash is taken over
  this, never raw memory or hash-map order.

These are what make cross-run / cross-build / cross-arch divergence *detectable* — and they are enforced
(comptime guards + the VOPR). The kernel does not prevent a logic bug; it **detects** divergence and hands
you a minimal repro.

## The loop (how an AI builds a game with it)

Write the deterministic core, then iterate on it with **measurement, not vibes**:

1. **author** (Zig) — components, systems, content-as-data, specs (invariants = "correct", metrics =
   fun/balance proxies). See the `gkz-authoring` skill.
2. **measure** (Zig harness you run) — step + observe; snapshot/replay; **fork** to A/B a tweak from one
   state; **sweep** a metric across thousands of seeds; **VOPR** a defect into a minimal repro; read
   provenance ("why did X die"). See the `gkz-measure` skill.
3. **iterate** — change systems, re-measure. Hot-reload swaps systems on a live world; schema migration
   evolves components.

## The worked example — read it

`examples/roguelike/` is a complete, runnable reference (a headless grid roguelike) consuming gkz as a
path dependency — the downstream template. `src/game.zig` is the authored core; `src/main.zig` is the
measure-and-iterate loop. `zig build run` narrates the whole loop; `zig build test` pins it.

## Public front door

`@import("gkz")` (`src/root.zig`) re-exports everything: `Registry`, `World`, `Entity`; `system`/`Sys`,
`Query`/`Read`/`Write`/`With`/`Without`, `SimCtx`, `step`/`runScheduled`; `Input`/`Command`; `snapshot`/
`restore`; `spec` (atoms/invariants/metrics); `vopr`/`sweep`/`Oracle`; the `query` Engine; `content`
(prefabs/levels); `reload`/`migrate`. SPEC.md is the contract; PLAN.md is the decisions-of-record.
