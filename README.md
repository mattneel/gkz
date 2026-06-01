# gkz

A **deterministic, fully observable, forkable simulation kernel** in Zig.

This is not a game engine in the Unity/Unreal sense. It is a deterministic state machine that
*expresses* games, with rendering, audio, input, and networking demoted to peripheral adapters. Its
lineage is [TigerBeetle](https://tigerbeetle.com/) (deterministic state machine + simulation testing),
Elm/Redux (state-as-value, time-travel), and `rr` (record-replay) — not the mainstream engines.

The primary user is an **AI** — authoring game logic and debugging running games. Every design choice
is justified by one of those two jobs.

> **Status:** Phases 1–10 (plus **Phase 2b**, real in-process multithreaded stage execution) are complete
> and verified — the foundation (the World as a value + pure
> `step`), the deterministic scheduler (§4) now running stages **across threads** bit-identically to the
> serial spine, events & causality (§5), the **VOPR** deterministic
> simulator/defect-finder (§9), the **relational query surface** (§7), **specs/invariants/temporal
> properties** (§8), **agent harnesses & evaluation** (§10), **hot-reload & schema migration** (§12),
> the **process model & control plane** (§13): one-process-per-sim supervision with real cross-process
> determinism, sharded sweeps over worker processes, crash-as-repro harvesting, and a query server — and
> **content as data** (§11): prefabs/levels as diffable records that instantiate to a pinned World, seeded
> proc-gen, and asset-handles-as-data. The
> kernel runs headless, end-to-end, with zero art, bit-identically across Debug/ReleaseSafe/ReleaseFast —
> and, verified under qemu, byte-identically across architectures: aarch64, s390x (big-endian), and 32-bit
> arm/mips (`zig build cross`).
> See [`PLAN.md`](./PLAN.md) for the full roadmap and [`SPEC.md`](./SPEC.md) for the design contract.

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
zig build cross    # CROSS-ARCH gate: re-check every pin under qemu on aarch64/s390x/arm/mips (needs qemu-user)
zig build run      # build and run the CLI
zig build          # build the CLI to zig-out/bin/gkz
```

`zig build test` is the determinism gate: it runs **948 tests in all three optimize modes** and pins a
suite of digests — an end-to-end content hash, a per-tick hash-stream digest, an event-log digest, the
VOPR's frozen replay constants, the eight query-result digests, the violation/spec/metric digests, a
frozen v1 migration image + migrated-World digests + reload-stream digest, and the **threaded** per-tick /
merged-log pins (the Phase-2b cross-build witness) — asserted identically in every mode. All three modes passing *proves* `Debug == ReleaseSafe ==
ReleaseFast` bit-identity: under integer overflow (which ReleaseFast does not trap), across permuted
system execution order, whether or not events are recorded, regardless of physical table/log layout, and
with invariant checks compiled in or out.

`zig build cross` extends that proof to **SPEC §2's "every architecture"** claim: it cross-compiles the
whole suite and re-checks every pin under qemu-user on the four quadrants of {word size} × {endianness} —
**aarch64** (64-bit LE), **s390x** (64-bit **big-endian**), **arm** (32-bit LE), and **mips** (32-bit
**big-endian**) — all 3 modes. Every digest is byte-identical on all of them. This is a real witness, not
a hope: the codec is fixed-width canonical-LE by construction (`putInt`/`getInt` derive width from the
type's declared bits and emit an explicit LE byte loop; `usize`/`isize` on the wire is a compile error;
no `@bitCast`/native-endian/`@sizeOf(usize)` ever reaches a hashed byte), and an endian/word-size audit
confirmed it. The big-endian + 32-bit runs are what make recording, replay, and forking exact *across
machines of any architecture* — the headless-first thesis.

---

## What's implemented (Phases 1–9)

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
order-permutation gate.

**Phase 2b — real in-process multithreading (`step_par.zig`).** Each stage's conflict-free systems now
run on a thread pool (`Io.Group` per stage, barrier between stages), the dual of Phase 9's cross-*process*
parallelism. Because same-stage systems write disjoint columns (the conflict rule), defer structural
change to per-system command buffers, draw only keyed/pure RNG, and record into per-system event sub-logs
merged in `exec` order, the threaded per-tick hash and merged event log are **bit-/byte-identical** to the
single-threaded spine. The witness *forces* real overlap (`setAsyncLimit(.unlimited)`) on the
column-write / RNG / emit paths and proves it (sleeping disjoint-column writers measurably overlap while
producing the serial result) — not a disguised serial loop on a high-core box.

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

### Phase 8 — Hot-reload & schema migration (SPEC §12)

| Module | Responsibility |
|---|---|
| `migrate/image.zig` | the schema-agnostic record substrate: `decode` lifts ANY serialize image into per-row `(entity, mask, [{kind_id, raw bytes}])` records using only the image's own per-Kind fingerprint (which carries each kind's byte width) — no old `Registry` types; `encode(R_target)` re-emits bytes byte-identical to `writeWorld` |
| `migrate/fingerprint.zig` · `migrate/ops.zig` | fingerprint extract/compare/`diff`/`requireMatch`; the declared `Op` vocabulary (`drop`/`add`/`rename`/`transform`) + `FieldBuilder`/`FieldReader` leaf codecs |
| `migrate/migrate.zig` | `validateMigration` (ops must exactly cover the fingerprint delta), `apply` (folds ops, recomputes masks, asserts the target fingerprint), `Chain`, and `migrateBytes`/`migrateWorld`/`migrateSnapshot` |
| `reload.zig` · `reload_example/*` | hot-reload via `SystemSet`/`reloadAt` (a World no-op) + a **real `std.DynLib` loader** (`NativeLibSource` opens a `.so`, resolves `gkz_systems`, hands back its `[]const Sys(R)`); two example systems compiled to actual shared objects by `build.zig` |
| `step.zig` · `schedule.zig` (runtime path) | `stepDynamic`/`runScheduledDynamic` + `execOrderDynamic` — the runtime-systems twins that run `dlopen`'d fn-pointers, gated bit-identical to the comptime path |

A migration **never instantiates the old registry** — it decodes a serialized World into a schema-agnostic
record `Image`, applies a list of **declared, validated ops** (add a field with a default, drop a kind,
rename, transform a value), and re-emits bytes that are **canonical by construction** (only whole
canonical-LE slices move; the result is byte-identical to what `writeWorld` would produce, so D5/D7/D8 fall
out). `validateMigration` proves the ops *exactly* reconcile the per-Kind fingerprint delta **before any byte
moves**; `apply` asserts the produced schema equals the declared target. The gate freezes a real v1 image and
proves migrated-v1 **== natively-built v2**, chain v1→v2→v3 **== direct v1→v3 == native v3**, and purity —
all pinned across the three optimize modes. **Hot-reload** loads simulation systems from a compiled shared
object at runtime: `build.zig` compiles example systems into real `.so`s, `NativeLibSource` `dlopen`s one
(via `std.DynLib`), and a runtime-systems path (`stepDynamic`) runs its fn-pointers over the same World —
the comptime path is untouched, so the determinism gate is unchanged. The gate is genuinely honest: a
loaded `.so`'s per-tick stream must equal the in-tree reference logic's stream (tampering the `.so` makes
it fail), and hot-swapping to a *different* `.so` mid-stream diverges at exactly the swap tick, caught by
the VOPR's divergence oracle. The kernel can't *prove* opaque reloaded code deterministic (§15 trusts the
author), but it **detects** a bad reload.

### Phase 9 — Process model & control plane (SPEC §13)

| Module (`src/proc/`) | Responsibility |
|---|---|
| `job.zig` | The serializable job/result codecs (GKZJ1 sweep-shard/fork jobs, GKZK1 aggregate/final results); hostile-input hardened (job bytes cross an OS boundary). `R` is never serialized |
| `executor.zig` | The `Executor` transport seam: `inProcessExecutor` (determinism floor) + `subprocessExecutor` (a real `std.process.run` child, temp-file job, timeout-bounded, crash/hang/spawn-fail harvested) |
| `worker.zig` · `worker_main.zig` | The one-shot worker (`gkz worker <job>`): read a job, run it against a comptime-fixed registry, write the result frame to stdout |
| `supervisor.zig` | The process pool: shard a sweep, dispatch index-addressed, restart-on-crash (the job is the repro), merge survivors in canonical shard-index order |
| `qserver.zig` | The query server (the **read** half of the control plane): `respond()` (unchanged) multiplexed across live sims by `sim_id`, served over a real `std.Io.net` Unix-domain socket (`serveUnix`) |
| `control_wire.zig` | The AI control-command codec (`GKZC2` commands / `GKZD1` responses): `hello`/`query`/`step`/`reload`/`fork`/`snapshot`/`migrate` + typed `ControlErr`; hostile-input hardened like `job.zig` (incremental Input decode, trailing-garbage → `Corrupt`) |
| `control_server.zig` | The **write** half of the control plane: `ControlServer(R, systems)` owns mutable live sims and **drives** them — step/reload/fork/snapshot/migrate — through the SAME `stepDynamic`/`applyReload`/`snapshot` primitives as the replay driver, so a live-driven session is byte-identical to its replay. `serveSession` = a persistent multi-command connection |
| `net_executor.zig` · `net_worker.zig` · `net_worker_main.zig` | The **across-machines** transport: `networkExecutor` is a third `Executor` impl shipping the same `GKZJ1`/`GKZK1` frames over TCP to a `gkz_net_worker` daemon running the SHARED `runJobBytes` |

A sim runs as **one OS process** (crash-isolation: a defect can't take the node down, *and* a crash is a
repro, §9). A `Supervisor` shards a seed sweep across worker processes via an `Executor` and dispatches them
**in parallel** (`Io.Group`, real across-cores throughput), harvests each shard into an **index-addressed**
slot, restarts a crashed worker a bounded number of times (recording the job as a re-runnable repro), and
merges survivors by shard index — so the result is bit-identical to a single-process sweep, regardless of
which process finished when (§4's "scheduling nondeterministic, results never are", lifted to concurrent
processes). **Forks** restore a snapshot and replay a diverged input stream in a worker. The **query server**
serves the §7 `respond()` surface over a real Unix-domain socket, multiplexed by `sim_id`. The control plane
is **exogenous** — it never enters the determinism guarantee — but it must *preserve* determinism, and the
gate proves it: a real subprocess's per-tick result bytes **equal the in-process bytes and pin to the same
digest in all three modes**, a sharded sweep run concurrently across real worker processes equals the
sequential one, a deliberately crashing worker is harvested as a `Term.signal` repro (which a disguised
in-process run structurally cannot fake), a hung worker is killed by the timeout, and the socket reply equals
`respond()` byte-for-byte. The control plane is now complete on **both** halves: beyond the read-only query
server, a **`ControlServer` drives live sims** (step/reload/fork/snapshot/migrate) over a persistent command
socket, and a **`networkExecutor` distributes work across machines** — the gate proves a live socket-driven
session is **bit-identical to its deterministic replay**, and that a job computed in a **genuinely separate
OS process** carried over TCP equals the in-process bytes and the pinned cross-mode digest (localhost is only
the test substrate; nothing in the path assumes a co-located peer). The remaining refinements are now
narrow: auth/TLS, and a physical second host as a *stronger* (not *missing*) network witness (see PLAN §17).

### Phase 10 — Content as data (SPEC §11)

| Module | Responsibility |
|---|---|
| `content.zig` | `Prefab(R)`/`Level(R)` as structured records (component cells = canonical-LE bytes + an explicit local-ref patch list); a `Builder`/`LevelBuilder`; deterministic `instantiate`/`loadLevel`; canonical `writePrefab`/`readPrefab`/`writeLevel`/`readLevel` with hostile-hardened decode |
| `mutation.applyAdd` | One `kind_id`→type dispatch shared by the command-buffer drain (`.kernel`) and content instantiation (`.content`) — untrusted content can never reach the `.kernel` `catch unreachable` |

A **prefab** is a reusable template of entities + component values with **local** cross-entity references;
a **level** composes prefab instances (+ per-instance overrides) and standalone entities into a starting
World. Instantiation spawns over the deterministic entity allocator and resolves refs, so a level's
**loaded-World digest is a fixed pin** — across build modes *and* the cross-arch matrix. Content is
authored as data the same way systems are authored as code (a runtime `Builder` program or a comptime
literal — git-diffable), so **procedural generation** is just content-code emitting content-data
(`genDungeon(seed)` → a deterministic World). A cross-entity reference is a component `Entity` field set to
the `localRef(target)` **sentinel** (odd generation → fail-closed if a rewrite is ever missed); the builder
emits an explicit, auditable ref-patch for each — never a blind reflection rewrite, so a same-shaped
**asset handle** (`enum(u64)`) is left untouched. Which is the headless-first thesis made executable:
**rendering assets are referenced by handle, and a world full of handles loads, runs, and hashes with zero
art and no asset table.** (Mid-tick prefab spawning, ZON authoring, and asset *import* are declared
seams/non-goals — see PLAN §15.)

### The reload/migrate control trigger (SPEC §12↔§13)

| Module | Responsibility |
|---|---|
| `control.zig` | `ControlSchedule` (captured `(at_tick, reload\|migrate)` ops) + canonical codec; `runWithControl` (replay driver, **no trigger param**) and `captureWithControl` (live driver + capture); `Trigger(R)` (the exogenous decider); `SetTable(R)` over `reload.SystemSource` |

Phase 8 built the reload/migrate *mechanisms* and Phase 9 the control plane; this is the missing
*trigger* — what decides **when** to reload or migrate, reproducibly. The decision is **exogenous** (an
operator/watch loop reacting to wall-clock or external signals, off the sim path) but determinism is
**preserved** by the same capture discipline as agents (§10): the live `Trigger` is invoked by
`captureWithControl`, which records each `(tick, op)` into a `ControlSchedule`; **replay consumes the
schedule via `runWithControl`, which has no trigger parameter and is structurally incapable of
re-invoking the live decider.** A run is determined by the triple **(seed, inputs, ControlSchedule)**. A
**reload** swaps the running system set in place (same `R`, a `reloadAt` World no-op); a **migrate** is a
re-typing boundary (`R_old→R_new`) — the driver snapshots to canonical bytes and surrenders, the caller
`migrateWorld`s and resumes. The gate witnesses it: a reload+migrate captured live then replayed from the
schedule is bit-identical and cross-arch-pinned; a tamper trigger that would diverge if re-invoked is
never called on replay (its counter stays put); a clock-reading decider influences only *which* ops are
captured, never replay. The control plane is now **completed end-to-end** (PLAN §17): the generic
multi-phase **`runSession`** drives reload+migrate across `R`-retyping boundaries (recursing into each
phase's monomorphization), the **`ControlServer`** is the socket-driven live trigger (an AI drives a sim
over a `GKZC2`/`GKZD1` command connection), and the **`networkExecutor`** distributes work across machines
— each gated, including a **live-session == deterministic-replay** witness and a **separate-process TCP**
witness.

### Determinism contract (the spine)

`step` is pure; the World is a value; all randomness is a keyed, counter-based pure function; the
per-tick content hash is taken over a **canonical serialization with a stable total ordering** (never
raw memory, never hash-map order, never pointers, always little-endian). These rules (`D1`–`D9` in
`PLAN.md`) are what make cross-run / cross-build / cross-arch divergence detectable.

---

## Roadmap

Phases 1–9 are done. Later work bolts onto clean seams without reworking the storage/serialize/hash
contract:

- **Phase 1** — Foundation ✅
- **Phase 2** — Systems & deterministic scheduler ✅
- **Phase 2b** — real in-process multithreaded stage execution (`step_par.zig`): threads per stage, bit-/byte-identical to the spine, with forced + measured overlap on the data-bearing path ✅
- **Phase 3** — Events & causality ✅
- **Phase 4** — The VOPR (deterministic simulator: fuzzing, divergence detection, minimal repro) ✅
- **Phase 5** — Introspection & relational query surface (§7) ✅
- **Phase 6** — Specifications, invariants & properties (§8) ✅
- **Phase 7** — Agent harnesses & evaluation (§10) ✅
- **Phase 8** — Hot-reload & schema migration (§12): real `dlopen` native-systems loading + version-tagged `World→World` migrations ✅
- **Phase 9** — Process model & control plane (§13): one-process-per-sim supervisor pool, cross-process sweep sharding, crash-as-repro harvesting, the query server ✅
- **Phase 10** — Content as data (§11): `Prefab`/`Level` as diffable records, deterministic instantiation (a pinned loaded-World digest, cross-arch), seeded proc-gen, asset-handles-as-data (headless-first) ✅
- **Cross-architecture determinism gate** (`zig build cross`): every pin re-checked under qemu on aarch64/s390x/arm/mips — the {32,64}-bit × {LE,BE} matrix ✅
- **Reload/migrate control trigger** (§12↔§13, `control.zig`): a captured, replayable `ControlSchedule`; reload+migrate driven reproducibly at tick boundaries; the exogenous trigger captured live and never re-invoked on replay (cross-arch pinned) ✅
- **Control-plane completion** (§13/§17): the generic multi-phase **`runSession`** (reload+migrate across `R`-retyping phases); the live **`ControlServer`** write surface (step/reload/fork/snapshot/migrate over a `GKZC2`/`GKZD1` command socket) with a **driven-session == deterministic-replay** gate; the across-machines **`networkExecutor`** (TCP) gated over a real socket *and* a genuinely separate OS process ✅
- **Next** — control-plane **auth/TLS**, a **physical second host** as a stronger (not missing) network witness, and persistent-connection refinements (see PLAN §17.14)

See [`PLAN.md`](./PLAN.md) §6 for the full phase map.

---

## Documents

- [`SPEC.md`](./SPEC.md) — the design contract: *what* the kernel is and why.
- [`PLAN.md`](./PLAN.md) — the implementation plan: architecture decisions (the storage-model judge
  panel, resolved design questions Q1–Q9), the determinism rules, the per-module build order, the
  verified Zig 0.16 facts, and the open risks.
