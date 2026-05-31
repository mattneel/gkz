# gkz

A **deterministic, fully observable, forkable simulation kernel** in Zig.

This is not a game engine in the Unity/Unreal sense. It is a deterministic state machine that
*expresses* games, with rendering, audio, input, and networking demoted to peripheral adapters. Its
lineage is [TigerBeetle](https://tigerbeetle.com/) (deterministic state machine + simulation testing),
Elm/Redux (state-as-value, time-travel), and `rr` (record-replay) — not the mainstream engines.

The primary user is an **AI** — authoring game logic and debugging running games. Every design choice
is justified by one of those two jobs.

> **Status:** Phases 1–7 are complete and verified — the foundation (the World as a value + pure
> `step`), the deterministic scheduler (§4), events & causality (§5), the **VOPR** deterministic
> simulator/defect-finder (§9), the **relational query surface** (§7), **specs/invariants/temporal
> properties** (§8), and **agent harnesses & evaluation** (§10). The kernel runs headless, end-to-end,
> with zero art, bit-identically across Debug/ReleaseSafe/ReleaseFast. See [`PLAN.md`](./PLAN.md) for the
> full roadmap and [`SPEC.md`](./SPEC.md) for the design contract.

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

`zig build test` is the determinism gate: it runs **693 tests in all three optimize modes** and pins a
suite of digests — an end-to-end content hash, a per-tick hash-stream digest, an event-log digest, the
VOPR's frozen replay constants, the eight query-result digests, and the violation/spec/metric digests —
asserted identically in every mode. All three modes passing *proves* `Debug == ReleaseSafe ==
ReleaseFast` bit-identity: under integer overflow (which ReleaseFast does not trap), across permuted
system execution order, whether or not events are recorded, regardless of physical table/log layout, and
with invariant checks compiled in or out.

---

## What's implemented (Phases 1–7)

The world is fully playable, testable, fuzzable, queryable, checkable, and agent-evaluable with **zero
art** — abstract placeholders only.

### Phase 1 — Foundation (SPEC §1–§3, §6)

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
| `input.zig` · `mutation.zig` | The `Command`/`Input` channel and the `apply` mutation vocabulary |
| `step.zig` · `snapshot.zig` · `replay.zig` | Pure `step`; snapshot/restore + deterministic replay; the determinism harness |

### Phase 2 — Systems & deterministic scheduler (SPEC §4)

| Module | Responsibility |
|---|---|
| `query.zig` | Comptime `Read/Write/With/Without` markers; a `Query` iterator whose `read`/`write` are `@compileError`-gated |
| `command_buffer.zig` | Uniform serializable `Command` records; comptime-typed `add/set/remove` enqueue |
| `simctx.zig` | The restricted `SimCtx` capability surface (tick, keyed RNG, command buffer, events) — no World/alloc/clock |
| `schedule.zig` | Comptime conflict-DAG → greedy stages; the access set is reflected off the system's `Query` parameter type |

A system declares its data access *in its `Query` type*; the scheduler derives a deterministic stage
order, and all structural change is deferred to one end-of-tick command-buffer drain (applied in
`(system_id, seq)` order). So results are **independent of execution order** — proven by an
order-permutation gate. Real multithreaded execution (Phase 2b) is a drop-in the architecture already
makes safe.

### Phase 3 — Events & causality (SPEC §5)

| Module | Responsibility |
|---|---|
| `event.zig` | Structural `EventId`; a distinct, component-storable `CauseToken`; an `EventId` in a component is a *compile error* |
| `event_log.zig` | A side log (never in the hashed World); `causesOf`/`causeChain` backward-walk; a versioned codec + digest |
| `recorder.zig` | Owns the log; auto-attributes each event to its per-(tick, system) cause node |

Events are **pure side-output** — recording them never perturbs the World (the per-tick hash is
bit-identical events-on vs events-off, gated), and nothing event-derived can enter hashed state.
Recording is *tiered*: off on the throughput path, switched on to re-run an interesting `(seed,
inputs)` and reconstruct the full causal graph. Causal queries are backward graph-walks
(`causeChain`) — the debugging primitive the kernel exists to provide.

### Phase 4 — The VOPR: a deterministic simulator (SPEC §9)

| Module (`src/vopr/`) | Responsibility |
|---|---|
| `run.zig` | The per-seed `Run` evidence bundle: `buildRun`/`worldAt`/`captureStream` + the per-tick hash stream |
| `generator.zig` | Seeded input-stream policies (idle/scripted/random); `view` is the §10 agent seam |
| `inject.zig` | Fault/timing injection — within-stage exec permutations + snapshot cadences (none may change the hash) |
| `oracle.zig` | The ONE `Oracle`/`Defect` abstraction: `invariant`, `divergence`, `firstDivergentTick` |
| `minimize.zig` · `vopr.zig` | Kind-locked delta-debug minimization; `sweep` + `provenanceRerun` |

One `Oracle`/`Defect` unifies "a crash, an assertion failure, an invariant violation, and a hash
divergence" as the same event class — a reproducible defect with an exact location. The capstone:
an injected determinism bug (a system writing around its declared access) is **caught, bisected to the
first tick, minimized to the smallest reproducing stream, and provenance-attached**; its correctly
declared twin reports zero defects. An `OutOfMemory`-injection sweep proves the whole pipeline is
leak-/double-free-safe.

### Phase 5 — Introspection & relational query surface (SPEC §7)

| Module (`src/query/`) | Responsibility |
|---|---|
| `term.zig` · `result.zig` | A uniform closed-tag `Value` substrate; `QueryResult` (canonical-sorted, deduped) + the GKZR1 wire codec |
| `relations.zig` · `catalog.zig` | The five §7 relations (`component`/`event`/`caused_by`/`system`/`diverge`) + a self-describing catalog |
| `diverge.zig` · `engine.zig` · `wire.zig` | Component-level `diverge`, `firstTickWhere`, `reach`; the `Query` request union; the zero-io `respond` seam |

The AI reasons over the engine's **runtime self-model**, not source code: entities, components, events,
causal edges, and the system dataflow graph are all queryable relations, with the four canonical shapes
(*why* · *what-affects-X* · *where-did-it-break* · *reachability*). `system/3` reflection is generated
from the §4 access sets, so it is always exact and never drifts. Results are a deterministic,
canonically-ordered, build-mode-invariant pure function of observed state — proven by eight pinned
result digests + a scramble-invariance gate.

### Phase 6 — Specifications, invariants & properties (SPEC §8)

| Module (`src/spec/`) | Responsibility |
|---|---|
| `atom.zig` · `invariant.zig` · `check.zig` | The `Atom`/multi-entity `Witness` substrate; state invariants; the every-tick `checkAll` hook (DCE'd in ReleaseFast) |
| `trace.zig` · `temporal.zig` | An O(T) projected-scalar trace; seven closed temporal combinators (LTL-over-the-log) folded over it |
| `metric.zig` · `relations.zig` | Integer intent-metrics + sweep aggregation; the `spec`/`violation` §7 relations |

Machine-checkable intent: state invariants pin the offending tick + entities; temporal properties
(`always`/`eventually`/`stable`/`monotonic_unless`/`until`/`precedes`/`responds`) catch the exact tick a
property flips. Violations ride the VOPR's `sweep → minimize → provenance` as an additive defect kind.
The **fun-oracle boundary** is enforced in the type system: invariants/properties return a *verdict* (the
engine guarantees them); metrics return a *quantity* (the engine measures, never judges) — intent is
exogenous, declared by the human/AI, never supplied by the kernel.

### Phase 7 — Agent harnesses & evaluation (SPEC §10)

| Module (`src/agent/`) | Responsibility |
|---|---|
| `observe.zig` · `agent.zig` | `ObsView` (read-only `*const` World + the §7 query lens); `Agent` = a `Generator` + `DeterminismClass`; `asAgent`/`replayGen` |
| `policy.zig` · `reference.zig` | `observe(State)->Input` policies; `scriptedAgent` + `greedyAgent` (rule-based, rng-keyed, re-derivable) |
| `external.zig` · `eval.zig` · `shard.zig` | the `ExternalAgent` NN/LLM fn-ptr seam; mass `aggregateAgent`/`sweepAgent`; the §13 shard math |

An agent is a policy `observe(State) -> Input` on the **same Input channel as a human**. A learned/NN/LLM
agent's inference is bit-irreproducible, so the kernel treats it as an **external nondeterministic source
captured at the Input boundary** — reproducibility comes from *recording the emitted inputs*, never from
reproducing the agent, and replay/VOPR **never re-invoke** it. That flips the apparent problem into a
feature: a black-box agent's playthrough is captured as `(seed, inputs)` and becomes **bit-exactly
replayable and VOPR-minimizable**. NN inference is the *player*, not the *world* — it reads a read-only
observation and emits inputs; it never touches the integer-deterministic sim path. Deterministic policies
give bit-reproducible sweeps; NN policies give run-level nondeterminism (fine for statistical metrics,
captured per run to revisit).

### Determinism contract (the spine)

`step` is pure; the World is a value; all randomness is a keyed, counter-based pure function; the
per-tick content hash is taken over a **canonical serialization with a stable total ordering** (never
raw memory, never hash-map order, never pointers, always little-endian). These rules (`D1`–`D9` in
`PLAN.md`) are what make cross-run / cross-build / cross-arch divergence detectable.

---

## Roadmap

Phases 1–6 are done. Later phases bolt onto clean seams without reworking the storage/serialize/hash
contract:

- **Phase 1** — Foundation ✅
- **Phase 2** — Systems & deterministic scheduler ✅
- **Phase 3** — Events & causality ✅
- **Phase 4** — The VOPR (deterministic simulator: fuzzing, divergence detection, minimal repro) ✅
- **Phase 5** — Introspection & relational query surface (§7) ✅
- **Phase 6** — Specifications, invariants & properties (§8) ✅
- **Phase 7** — Agent harnesses & evaluation (§10) ✅
- **Phase 8** — Hot-reload & migration (§12): `dlopen` native systems, version-tagged `World→World` migrations ← *next*
- **Phase 9+** — Process model & control plane (§13): supervisor pool, the query server, cross-process sweep sharding
- **Phase 2b** — real thread-pool execution (the scheduler architecture already makes it safe)

See [`PLAN.md`](./PLAN.md) §6 for the full phase map.

---

## Documents

- [`SPEC.md`](./SPEC.md) — the design contract: *what* the kernel is and why.
- [`PLAN.md`](./PLAN.md) — the implementation plan: architecture decisions (the storage-model judge
  panel, resolved design questions Q1–Q9), the determinism rules, the per-module build order, the
  verified Zig 0.16 facts, and the open risks.
