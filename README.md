# gkz

A **deterministic, fully observable, forkable simulation kernel** in Zig.

This is not a game engine in the Unity/Unreal sense. It is a deterministic state machine that
*expresses* games, with rendering, audio, input, and networking demoted to peripheral adapters. Its
lineage is [TigerBeetle](https://tigerbeetle.com/) (deterministic state machine + simulation testing),
Elm/Redux (state-as-value, time-travel), and `rr` (record-replay) — not the mainstream engines.

The primary user is an **AI** — authoring game logic and debugging running games. Every design choice
is justified by one of those two jobs.

> **Status:** Phase 1 (the foundation) is complete and verified. The simulation core runs headless,
> end-to-end, with zero art. See [`PLAN.md`](./PLAN.md) for the full roadmap and [`SPEC.md`](./SPEC.md)
> for the design contract.

---

## The idea

The simulation is a pure function:

```
step : (State, Input) -> State
```

- **State** is the entire world: a value — fully serializable, content-hashable, diffable.
- **Input** is the *only* channel through which nondeterminism enters (no wall clock, no ambient RNG,
  no syscalls on the sim path).
- A **run** is `(seed, inputs)`. The same `(seed, inputs)` reproduces a run **bit-for-bit** — on every
  architecture, every build mode, and across the SIMD/scalar split.

Because `step` is pure and `State` is a value, record/replay, time-travel debugging, reproducible
repros, and counterfactual forks are not features — they are **corollaries**.

All numbers on the sim path are fixed-point ([`fpz`](https://github.com/mattneel/fpz): 64-bit Q40.24
`Fixed`, BAM `Angle`). **No floating point, ever.**

---

## Quick start

Requires **Zig 0.16.0** (the build pins it via `build.zig.zon`; the `fpz` dependency is fetched
automatically on first build).

```sh
zig build test     # run the full suite under Debug + ReleaseSafe + ReleaseFast (the determinism gate)
zig build run      # build and run the CLI
zig build          # build the CLI to zig-out/bin/gkz
```

`zig build test` is the determinism gate: it runs **219 tests in all three optimize modes** and pins
both an end-to-end content hash and a per-tick hash-stream digest, asserted identically in every mode.
All three passing *proves* `Debug == ReleaseSafe == ReleaseFast` bit-identity — including under integer
overflow, which ReleaseFast does not trap.

---

## What's implemented (Phase 1 — Foundation)

| Module | Responsibility |
|---|---|
| `entity.zig` | Generational entity allocator (`{index, generation}`), parity-encoded liveness, FIFO recycle |
| `registry.zig` | Comptime component registry: stable `kind_id`, presence `Mask`, the `MultiArrayList` row type |
| `storage.zig` | Flat dense table (`std.MultiArrayList`) + sparse `index_to_row`; spawn/despawn/add/remove |
| `sort.zig` | Pinned, stable, deterministic sort (the canonical-order primitive) |
| `rng.zig` | Counter-based keyed RNG — `draw(seed, tick, entity, stream)`, pure, no float, no shared cursor |
| `serialize.zig` | Canonical field-by-field little-endian codec + restore (padding never serialized) |
| `hash.zig` | Per-tick content hash: XXH64 + CRC32 over the *same* canonical traversal |
| `world.zig` | The World as a value: `{ component columns, entity allocator, RNG root, tick }` |
| `input.zig` | The `Command`/`Input` channel — the sole ingress for nondeterminism |
| `mutation.zig` | Structural mutations (`spawn`/`despawn`) via a single `apply` — the command-buffer seam |
| `step.zig` | The pure `step(World, Input) -> World` |
| `snapshot.zig` · `replay.zig` | Snapshot/restore and deterministic replay; the determinism harness |

The world is fully playable, testable, and fuzzable with **zero art** — abstract placeholders only.

### Determinism contract (the spine)

`step` is pure; the World is a value; all randomness is a keyed, counter-based pure function; the
per-tick content hash is taken over a **canonical serialization with a stable total ordering** (never
raw memory, never hash-map order, never pointers, always little-endian). These rules (`D1`–`D9` in
`PLAN.md`) are what make cross-run / cross-build / cross-arch divergence detectable.

---

## Roadmap

Phase 1 (Foundation) is done. Later phases bolt onto clean seams without reworking the
storage/serialize/hash contract:

- **Phase 2** — Systems & deterministic scheduler (comptime access sets, query DAG, command buffers)
- **Phase 3** — Events & causality (provenance graph, "why did this happen")
- **Phase 4** — The VOPR (deterministic simulator: fuzzing, divergence detection, minimal repro)
- **Phase 5** — Introspection & relational query surface
- **Phase 6+** — Invariants/properties, agent harnesses, hot-reload & migration, process model

See [`PLAN.md`](./PLAN.md) §6 for the full phase map.

---

## Documents

- [`SPEC.md`](./SPEC.md) — the design contract: *what* the kernel is and why.
- [`PLAN.md`](./PLAN.md) — the implementation plan: architecture decisions (the storage-model judge
  panel, resolved design questions Q1–Q9), the determinism rules, the per-module build order, the
  verified Zig 0.16 facts, and the open risks.
