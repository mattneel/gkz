# Deterministic Simulation Kernel — Specification (Zig)

> This is not a game engine in the Unity/Unreal sense. It is a **deterministic, fully observable,
> forkable simulation kernel** that expresses games, with rendering, audio, input, and networking
> demoted to peripheral adapters. Its lineage is TigerBeetle (deterministic state machine +
> simulation testing), Elm/Redux (state-as-value, time-travel), and `rr` (record-replay) — not the
> mainstream engines.
>
> **The primary user is an AI** — authoring game logic and debugging running games. Every design
> choice below is justified by exactly one of those two jobs. Where a choice trades human ergonomics
> for machine legibility, determinism, or feedback-loop tightness, it takes the trade.

---

## 0. Scope

This document specifies **the kernel**: the simulation core, ECS substrate, system scheduler,
provenance/event model, snapshot/replay/fork machinery, the unified query surface, the
specification/invariant layer, the deterministic simulator (VOPR), the agent-harness contract, and
the process model. Rendering, audio, input backends, netcode, asset import, and the editor are
peripheral adapters hanging off defined seams (§14) and are out of scope here — which is the whole
point of the reframe.

Numeric substrate is the existing fixed-point library: 64-bit Q40.24 `Fixed`, BAM `Angle`, total
ops, ReleaseFast-certified, golden-vector conformance. **No floating point on any sim path**, ever.
The kernel's determinism contract inherits and extends the math library's.

---

## 1. Core model

The simulation is a pure function:

```
step : (State, Input) -> State
```

- **State** is the entire world: a value, fully serializable, content-hashable, diffable.
- **Input** is the only channel through which nondeterminism enters — player/agent actions, and
  nothing else (no wall clock, no ambient RNG, no syscalls).
- A **run** is a seed plus an ordered input stream. `(seed, inputs)` reproduces a run bit-for-bit.

Everything else in this spec is a consequence of making `step` pure and `State` a value:
record/replay, time-travel, reproducible repros, and counterfactual forks are not features — they
are corollaries.

**Tick model.** Logical fixed timestep, integer tick counter. No wall-clock time in logic. Headless,
the sim runs as fast as the host allows (no frame pacing), which is what makes mass fuzzing and
agent evaluation tractable. A view, if attached, interpolates between the two most recent states for
display smoothness and **never feeds back into the sim** (§14).

---

## 2. Determinism contract (the spine)

1. `step` is a pure function of `(State, Input)`. Same inputs → **bit-identical** State on every
   target arch, every build mode, and across the SIMD/scalar split.
2. **ReleaseFast is the certified canonical runtime** (this is a game). Determinism therefore cannot
   depend on assertions being compiled in: no `unreachable` on input-dependent conditions, every
   operation total (inherited from the math lib's contract).
3. **All nondeterminism enters through Input and is recorded.** No `std.time`, no OS RNG, no
   syscalls on sim paths. Systems receive a restricted context (§4) that makes these unavailable.
4. **RNG is counter-based and keyed**, never a shared mutable stream. Any draw is
   `rng(seed, tick, entity_id, stream_id)` (PCG/Philox-style). This is mandatory: a shared
   incrementing RNG read by parallel systems is order-dependent and silently nondeterministic.
5. **State is content-hashed every tick.** The hash is over a canonical serialization of component
   storage. Cross-run, cross-build, cross-arch hash comparison is how divergence is detected (§9).
6. **Replayable instrumentation.** Record only `(seed, inputs)` cheaply on every run. Re-execute with
   full provenance/instrumentation only on the runs that matter. Instrumentation cost is paid on
   demand, never on the throughput path.

A corollary the math lib already proved out: because every op is total and assertion-independent,
`Debug`, `ReleaseSafe`, and `ReleaseFast` agree bit-for-bit. A divergence found in a ReleaseFast
fuzzing run reproduces under a debugger at `-O0`, exactly.

---

## 3. ECS substrate

**Components are plain data (POD).** No methods, no pointers-to-heap inside a component, no hidden
state. The consequence is the load-bearing one: **the world is a value** — snapshot, diff, hash, and
transmit come for free, and the AI reads world state as a structured document rather than walking an
object graph.

- **Entity** = a generational index (`{ index: u32, generation: u32 }`). Generation prevents stale
  references resolving to recycled slots.
- **Storage** is archetype/column-oriented (structure-of-arrays), cache-friendly and the substrate
  for the SIMD batch path. Component arrays are contiguous and POD → a snapshot is a serialization
  of columns.
- **World** = the set of component columns + entity allocator + the keyed RNG root + the tick
  counter. Serializing the World is serializing those. Hashing the World is hashing the canonical
  serialization (stable column/entity ordering — ordering is part of the contract).
- **Relationships / references** between entities are stored as `Entity` values inside components,
  resolved through the generational allocator. No raw pointers in state (pointers aren't
  serializable, hashable, or relocatable).

---

## 4. Systems & scheduling

A **system** is a pure Zig function over a declared set of component accesses:

```zig
// Sketch — access set is comptime, extracted for BOTH scheduling and reflection.
fn movement(ctx: *SimCtx, q: Query(.{ Read(Position), Write(Velocity) })) void { ... }
```

- **Access is declared at comptime** (`Read`/`Write`/`With`/`Without`). The comptime layer extracts
  the access set, which drives two things at once: the scheduler's dependency graph, and the
  reflection/dataflow graph the query surface exposes (§7). Declaring access isn't bureaucracy — the
  engine *needs* it for scheduling, so reflection is free.
- **The scheduler builds a DAG** from declared accesses. Two systems with disjoint access may run on
  any threads in any order; the result is identical because there is no shared mutable state. The
  schedule itself is derived deterministically from the DAG, **not** from runtime timing.
- **Conflicting writes go through command buffers.** A system that must mutate shared/contended state
  (spawn/despawn, write another entity, mutate a singleton) emits **commands** into a per-system
  buffer. Buffers are applied at a sync point in a **deterministic order** (by system id, then entity
  id). Physical thread scheduling is nondeterministic; the applied order never is. This is the crux
  of deterministic-parallel ECS — get it wrong and determinism is gone.
- **`SimCtx` is a restricted capability surface.** It exposes the keyed RNG (§2.4), the command
  buffer, the event emitter (§5), and tick metadata — and deliberately does **not** expose a clock,
  OS RNG, allocator with nondeterministic behavior, or syscalls. Obvious nondeterminism is therefore
  *uncompilable*, not merely discouraged.

**Enforcement posture (a fork worth naming).** comptime enforces what it can cheaply: declared
access is mandatory (scheduling needs it) and the obvious nondeterminism sources are absent from the
context. The *subtle* sources — uninitialized reads, accidental order-dependence, an unintended
saturation — are caught by the VOPR as divergence (§9). The split is intentional: hard-forbid the
cheap cases at compile time, detect the rest at fuzz time. (If you want to push more enforcement into
comptime — e.g. effect typing on every helper — that's a knob, with author friction as the cost.)

**Authoring is native Zig, no VM.** Systems compile in (or `dlopen` for hot-reload, §12). There is no
bytecode interpreter and no sandbox, because the author is trusted and the VOPR detects what a
sandbox would have prevented; a crash is a reproducible repro, not a safety breach. (WASM re-enters
only under untrusted/polyglot/instruction-metering requirements, which are out of scope.)

---

## 5. Events & causality

Events are the **provenance channel**, recorded alongside state — they are how the AI asks "why did
this happen."

- A system emits events through `ctx`. Every event carries provenance: emitting system, tick, and
  the cause(s) that triggered it (the event/command it was reacting to). Provenance edges form a
  **causal graph**.
- **Source-of-truth call (resolves the event-sourcing fork).** Live state is the **mutable component
  columns** (for ReleaseFast speed). The event log is **append-only recorded provenance**, not the
  authoritative state. Canonical truth for *reconstruction* is `snapshot + input stream` via
  deterministic replay — **not** a fold over events. Folding events at runtime is too slow for a
  game; determinism makes the input stream the cheap source of truth instead, and frees the event
  log to be a pure provenance/query artifact.
- **Tiered recording.** Full provenance (every event + every causal edge) is expensive at fuzzing
  scale. Default: record `(seed, inputs)` only. On any run flagged interesting (a found bug, a seed
  under investigation), re-run deterministically with provenance recording ON. This is §2.6 applied
  to causality.
- **Causal queries** are backward graph-walks: from an observed effect ("entity 42 died at tick
  9120") to its cause chain (DamageEvent ← CombatSystem ← CollisionEvent ← projectile spawned by…).
  This is the debugging primitive the kernel exists to provide.

---

## 6. Time, snapshots, replay, forking

- **Snapshots** are serializations of the World at chosen tick intervals. Cheap because columns are
  POD. Cadence is tunable (perf vs reconstruction latency — a fork to set per deployment).
- **Reconstruct any tick** = nearest prior snapshot + replay the input stream forward. Cost is
  O(snapshot interval) ticks. This is time-travel debugging.
- **Diff** two snapshots → exactly which components/entities changed between ticks, for free.
- **Counterfactual fork** = take a snapshot at tick *t*, branch the input stream (inject different
  input, or re-roll a seed-derived decision), replay both forward, and **diff the divergence**. "What
  if the player hadn't jumped here" is a fork; "where do these two runs first differ" is a snapshot
  diff over the fork. This is the substrate for both debugging (counterfactual isolation) and design
  evaluation (consequence of a change across many runs).
- Headless replay runs faster-than-realtime, so forks and sweeps are cheap to run at volume.

---

## 7. Introspection & query surface

The single most differentiating subsystem. The AI reasons over the engine's **runtime self-model**,
not over source code.

Expose these as **relations** queried through a Datalog-ish language (entities, components, events,
causal edges, and the system dataflow graph are all just relations; the questions you want are
recursive relational queries):

- `component(Entity, Kind, Value)` — current world state.
- `event(EventId, Kind, Tick, EmitterSystem, Payload)` — the provenance log.
- `caused_by(EventId, EventId)` — causal edges (recursive → full cause chains).
- `system(SystemId, reads: [Kind], writes: [Kind])` — the static dataflow graph from §4's declared
  access.
- `diverge(RunA, RunB) -> (Tick, Entity, Kind)` — first divergence between two runs (snapshot diff
  over a fork).

Canonical query shapes the AI issues:

- *Why* — backward walk on `caused_by` from an effect.
- *What affects X* — which systems `write` component `X` (structural, no source-grep).
- *Where did it break* — first tick an invariant (§8) flips, bisected via replay.
- *Reachability / "can the player still win"* — recursive query over the navigable state graph.

The surface is served over a socket to the control plane (§13). Reflection (`system/3`) is generated
by the comptime layer (§4), so it is always exact and never drifts from the code.

---

## 8. Specifications, invariants, properties

Machine-checkable intent, co-located with the systems it constrains. This is where "is it correct"
becomes tractable, and where "is it fun" gets an honest boundary.

- **State invariants** — predicates over the current World: `no two solids overlap`,
  `health ∈ [0, max]`, `every entity referenced by a component exists`. Checked every tick in
  ReleaseSafe/Debug and by the VOPR (§9). A violation pins the tick + entities involved.
- **Temporal properties** — predicates over the event log / tick sequence: `once the boss is dead it
  stays dead`, `score never decreases except on a Penalty event`. This is LTL over the log whether or
  not you call it that. Declared as small property objects checked against the recorded trace.
- **Intent-metrics** — *measured* quantities over agent-driven playthroughs (§10): time-to-clear,
  death heatmaps, economy curves, a competent bot's win rate as a difficulty proxy.

**The fun-oracle boundary, stated plainly.** Invariants and temporal properties are *checkable* — the
engine guarantees them. "Fun" is not; it collapses to a **proxy metric you declared**, measured
cheaply and reproducibly across many fast-forwarded runs. The engine makes measurement dense,
reproducible, and high-throughput, and lets you declare *what* to measure. It cannot choose the
proxy, and choosing the right proxy for designer intent is the irreducible judgment that stays with
the human (or a higher-level agent). **Intent is exogenous**; the kernel makes intent executable and
checkable, never supplies it.

---

## 9. The VOPR (deterministic simulator)

The TigerBeetle-style simulator that drives the kernel adversarially — and the unifying insight:
**the fuzzer and the debugger are the same machine.** The thing that lets you fuzz the game for
correctness is the thing that lets the AI bisect a gameplay bug.

- **Seeded driver** generates input streams (random, scripted, agent-driven, adversarial).
- **Fault & timing injection** — vary thread scheduling, command-buffer apply timing, snapshot
  cadence — none of which may change results (that's the test). Inject malformed/adversarial input.
- **Property checking** — runs all invariants and temporal properties (§8) continuously across
  millions of seeds.
- **Divergence detection** — compares per-tick state hashes across runs/builds/arches; any mismatch
  is a hit, **bisected to the tick + component + system** via replay.
- **Minimal repro** — a found bug reduces to `(seed, inputs)`; the input stream is then delta-debugged
  to the shortest reproducing prefix. Re-run with provenance ON (§5) to get the full cause chain.

A crash, an assertion failure (in safe builds during fuzzing), an invariant violation, and a hash
divergence are all the same event class to the VOPR: a reproducible defect with an exact location.

---

## 10. Agent harnesses & evaluation

Bots that play the game, so the AI author can *measure* the experience instead of guessing it.

- **Harness contract** — an agent is a policy `observe(State) -> Input` plugged into the same Input
  channel as a human. Scripted, search-based, learned (RL), or LLM-driven.
- **Mass evaluation** — run thousands of agent playthroughs faster-than-realtime, aggregate the
  declared intent-metrics (§8). This is how a balance change, a level edit, or a new mechanic gets a
  dense, reproducible signal.
- **Separation of concerns** — the agent's neural-net *inference* is where quantized hardware (INT8
  tensor cores) legitimately accelerates things. That is the **player**, not the **world**; the world
  sim stays integer-deterministic on the CPU. Never conflate the two paths.

---

## 11. Content as data

- Entities, prefabs, and levels are **structured, diffable, mergeable data** (not opaque binary
  scenes). Git-friendly; the AI authors content as data the same way it authors systems as code.
- **Procedural generation** is natural — content-as-code emitting content-as-data, deterministically
  seeded.
- **Rendering assets** (meshes, textures, audio) are referenced by handle and are **not required for
  the sim to run.** A game is fully playable, testable, fuzzable, and evaluable with zero art, using
  abstract placeholders. The game exists and is correct before a single pixel is drawn — the cleanest
  statement of the headless-first thesis.

---

## 12. Hot-reload & migration

- **Systems hot-reload via `dlopen`/`dlclose`** of native Zig. Safe because systems are stateless and
  all state lives in the kernel's columns (§3/§4). A reload swaps function pointers; no state lives in
  the reloaded image.
- **Schema migration is a declared, deterministic operation** (the DB-migration / Erlang
  `code_change` discipline). Adding a component field → default; removing → drop; renaming → map.
  Migrations are pure functions over the World, version-tagged, and themselves deterministic so a
  migrated replay stays bit-exact.
- The author→run loop is therefore sub-rebuild where it matters, without losing an expensive live
  world.

---

## 13. Process model & control plane

BEAM is gone; the control plane is Zig.

- **One OS process per sim instance.** This single mechanism gives three things at once:
  crash-isolation (a defect in one sim can't take down the node — and a crash is a *repro*, §9),
  parallel-experiment throughput (thousands of forks/seeds across cores and machines), and the
  isolation a sandbox would have provided.
- **Supervisor** — a Zig process pool that spawns, monitors, restarts, and harvests results from sim
  processes. Forks (§6) are spawned from a snapshot + a diverged input stream.
- **Query server** — exposes the §7 relational surface over a socket, multiplexing across live sims
  for the AI control plane.
- Observability is not a separate concern: it *is* the §5/§6/§7 provenance/snapshot/query surface,
  which is also the product.

---

## 14. Seams to peripheral layers (out of scope, defined here)

Each is an adapter on a defined seam; none participates in the determinism guarantee.

- **View / rendering** — reads snapshots, interpolates between the two most recent states for
  smoothness, renders. **Never writes back into the sim.** Can run at display rate independent of the
  fixed sim tick. GPU lives here.
- **Input** — captures human/device input and feeds it into the recorded Input channel (§1). The only
  ingress for nondeterminism.
- **Audio** — a view over state/events; same one-way constraint as rendering.
- **Netcode** — lockstep / rollback netcode falls out of determinism almost for free (the sim is
  already a deterministic function of an input stream); it is a layer that synchronizes input streams
  across peers, not a kernel concern.
- **Asset import** — converts external art into handle-referenced resources (§11); offline, not on a
  sim path.
- **Editor** — there is no privileged editor. The editor is *a query client* (§7) plus a view (above).
  Human authoring tools and AI authoring use the same surfaces.

---

## 15. Non-goals

- **No floating point on any sim path.** `Fixed`/`Angle` only; comptime constants and debug display
  excepted.
- **No bytecode VM, no scripting sandbox.** Native Zig systems; VOPR detection in place of
  construction-time prevention.
- **No GPU on the canonical sim path.** Scalar + SIMD CPU; GPU is a rendering (view) concern.
- **No rendering/audio/input/netcode implementations here** — seams only (§14).
- **No game content, no asset pipelines, no editor GUI** in this document.
- **The kernel does not supply intent.** It makes intent executable, checkable, and measurable; the
  proxy for "fun" and the definition of "correct" come from outside (§8).
