# gkz — Implementation Plan

> Companion to [SPEC.md](./SPEC.md). SPEC says **what** the kernel is; this says **how** and **in what
> order** it gets built, and records the architectural decisions made along the way. The primary user
> is an AI; every decision below favors determinism, legibility, and a tight feedback loop.

Status: **Phases 1–2 implemented; all determinism gates green; both adversarial reviews passed.**
**Phase 1 (Foundation)** + **Phase 2 (Systems & deterministic scheduler, §4)** are complete: **279 tests**
passing across Debug/ReleaseSafe/ReleaseFast, with pinned end-to-end + per-tick-stream hashes proving
cross-build bit-identity (D2) and an order-permutation gate proving execution-order independence. Two
5-lens adversarial reviews raised 37 findings (31 confirmed, none critical/high); all fixed or
documented (see §7). Phase 1 committed as `a589d39`; Phase 2 pending commit. This document is the decision of record. It was produced from a
3-architecture judge panel (5 independent lenses + synthesis) over ground truth extracted from
SPEC.md, the `fpz` dependency, and the live Zig 0.16.0 toolchain.

---

## 0. North star

```
step : (State, Input) -> State          State = the World, a value (serializable, hashable, diffable)
```

A run is `(seed, inputs)`; it reproduces **bit-for-bit** across arch, build mode, and the SIMD/scalar
split. Record/replay, time-travel, forks, and divergence detection are **corollaries** of `step` being
pure and `State` being a value — not separately-built features. Everything in Phase 1 exists to make
that one equation true and observable.

---

## 1. Toolchain ground truth (verified on the live 0.16.0 compiler — do not regress)

These were confirmed by compiling probes against the pinned toolchain (anyzig → Zig 0.16.0). They
correct at least one plausible-but-wrong assumption, so they are recorded here permanently.

| Fact | Verdict | Consequence |
|---|---|---|
| **`@Type(.{...})` builtin** | ❌ **REMOVED** (`error: invalid builtin function: '@Type'`) | Do **not** reify structs with `@Type`. Build the column store with `std.meta.Tuple(&types)` instead (see §5). Split builtins `@Struct`/`@Enum`/`@Union` exist but we don't need them. |
| `std.meta.Tuple(&types)` of `ArrayList(C)` | ✅ compiles & runs | The `@Type`-free typed-column mechanism. |
| `@typeInfo(T)` active tags | ✅ `.@"struct"`, `.@"enum"`, layout `.@"extern"` / `.auto` | Quoted/snake forms. POD guard = reject `.auto`. |
| `std.hash.XxHash64.hash(0, "abc")` | ✅ `0x44bc2cf5ad770999`; streaming `update()` == one-shot | Frozen published spec → cross-version/cross-arch stable. **This is the content hash.** Pin seed=0 + this vector as a CI tripwire. |
| `std.mem.writeInt(i64, &buf, -1, .little)` | ✅ all-`0xFF`; `u32 0x01020304` → `04 03 02 01` | All serialization is explicit little-endian via `writeInt`. Never host-endian, never `@bitCast` a struct. |
| `std.meta.Int(.unsigned, 64)` | ✅ → `u64` | Component presence `Mask`. |
| `std.ArrayList(T)` | unmanaged: `.empty`, allocator passed per call | `append(gpa, x)`, `deinit(gpa)`, etc. (matches scaffold). |
| `std.MultiArrayList(Row)` | ✅ SoA columns; `.items(.field)` → mutable column slices; `swapRemove(i)` fixes **all** columns atomically; **accepts a `std.meta.Tuple` row** built from the comptime component list (no `@Type`) | **The column container** (§5). Replaces the hand-rolled tuple-of-`ArrayList` and its multi-column lockstep — MAL keeps all row-indexed columns in sync by construction. Internal alignment-packing is invisible behind `.items(.field)`, which is all the hash codec touches. |
| `main` | `pub fn main(init: std.process.Init) !void` | arena via `init.arena.allocator()`. |

**`fpz` substrate facts** (numeric path is fixed-point only; no float ever on the sim path):
- `Fixed = struct { raw: i64 }` (Q40.24), `Angle = struct { raw: u32 }` (BAM). Single-field,
  padding-free, 8/4 bytes, exactly one bit-pattern per value (no NaN, no negative zero) → byte-comparable.
- `fpz` ships **no** rng / hash / serialize / canonicalization helpers. The kernel builds all of them.
- Deserialize numeric leaves via `Fixed.fromRaw(i64)` / `Angle.fromRaw(u32)` (no validation).
- Raw integers live in **host-endian** memory → snapshots/hashes **must** serialize little-endian.
- **Assert-only / non-total `fpz` ops** (panic in Debug/ReleaseSafe, UB/silent-wrong in ReleaseFast)
  — keep operands in-domain or use the total variant: `div` by 0; `fromInt` outside ±2³⁹;
  `neg`/`abs(Fixed.MIN)`; `atan2(0,0)`. Totally-defined choices: `addSat`/`subSat`/`mulSat`, and the
  overflow-defined `add`/`sub` (wrap-and-assert) when operands are provably in range.
- `toFloat` is **debug/display only** — never on a sim path.
- ⚠️ Scalar `add/sub` assert-then-wrap (Debug panic vs ReleaseFast wrap), while `fpz.simd` add/sub/mul
  **wrap silently in all modes**. When the SIMD batch path lands (Phase 2+), scalar vs SIMD overflow
  semantics differ — a future divergence source the cross-build gate must be extended to cover.

---

## 2. Architecture decision: the storage fork (SPEC Q9)

Three fully-committed foundation architectures were designed and scored by five independent expert
lenses (1–10 each):

| Lens (weight) | A — sparse-set columns | B — archetype tables | **C — flat dense table + per-row bitmask** |
|---|:--:|:--:|:--:|
| Determinism (high) | 7 | 5 | **9** |
| Spec fidelity (high) | 6 | **9** | 7 |
| Simplicity (tiebreak) | 6 | 3 | **9** |
| Forward-compat | 7 | **9** | 6 |
| Zig 0.16 idiom | 5 | 4 | **8** |
| **Total** | 31 | 30 | **39** |

**Decision: Candidate C is the base.** It wins the two highest-weighted lenses (determinism, spec) on
balance and the designated tiebreaker (simplicity) outright, and is the only one that compiles cleanly
on 0.16 (A and B both relied on the removed `@Type`; B additionally carried `@ptrCast` type-erasure
UB). Its determinism edge is structural, not disciplinary: **zero HashMaps in State** (the
entity→row map is a plain array), canonical order is an argsort on a unique key, and clearing a
component canonically zeroes its slot — eliminating whole classes of silent divergence by construction.

**B's genuine win (SIMD-contiguous archetype layout, SPEC §3's literal "archetype" noun) is not
discarded — it is deferred and sealed behind the storage seam (S1).** Because the hash/serialization
contract depends only on the canonical `(Entity, mask, values)` projection and never on physical
layout, a later phase can swap the flat table for archetype tables **without changing the hash,
serialization, `step` signature, or Q1–Q8.** That clause's stated purpose (the SIMD batch path) is a
deferred subsystem, so the deferral is principled and reversible.

**Grafted into C:**
- From **A**: the `Mutation` tagged union + single `apply(World, Mutation)` entry point (the cleanest
  S2 command-buffer seam — storage mutators *are* the command-buffer vocabulary); the `relation(kind_id)`
  projection name for the S5 query surface; the belt-and-suspenders "extern/packed **and** field-by-field" rule.
- From **B**: per-system `(read_mask, write_mask)` access sets over the registry bit-space as the §4
  DAG conflict primitive (`(writeA & (readB|writeB)) != 0`); per-Kind `{kind_id, size_bytes}` schema
  fingerprint in the snapshot header for §12 migration; the archetype layout itself as the documented S1 upgrade target.

---

## 3. Resolved design questions (Q1–Q9) — decision of record

- **Q1 — Kind id:** explicit author-assigned `pub const kind_id: u16 = N;` on each component. The
  comptime registry gives the *set*; `kind_id` gives *stable identity*. Serialization orders by
  ascending `kind_id`, decoupled from tuple position. Rationale: position-derived ids silently re-key
  every prior snapshot on a source reorder and break §12 migration. `kind_id` is the migration anchor.
- **Q2 — Snapshot cadence:** default interval **64** ticks; tick 0 always snapshotted (replay origin).
  An **interval=1 (every-tick)** mode is required and is the default in test builds — the per-tick hash
  stream is the determinism oracle. Cadence lives in the Recorder/replay config, **never** in the hashed World.
- **Q3 — Input:** typed, length-prefixed **command list**.
  `Command = extern struct { actor: Entity, verb: u16, _pad: u16 = 0, a0: i64, a1: i64, a2: i64 }`;
  `Input = struct { tick: u64, commands: []const Command }`. Sole nondeterminism channel; the identical
  channel a human, a script, and a future `observe(State)->Input` agent all emit. Canonical intra-tick
  order = sort by `(actor.index, verb, arrival-index)`. Chosen over an opaque blob (illegible/undiffable)
  and over fixed per-player action sets (too rigid for the §4 command-buffer future).
- **Q4 — Entity-id stability across replay:** **guaranteed.** `{index,generation}` is a pure function
  of allocator history, which is a pure function of `(restored allocator state, ordered commands)`. The
  **full** allocator state (`generation[]`, `free_list`, `free_head`, `next_index`) lives in the World
  and is serialized/restored byte-exact. Recycle policy is fixed: **FIFO**, generation bumped with `+%1`
  on free. Rows are not identity and are not serialized, so swap-remove churn cannot perturb ids.
- **Q5 — Hash:** `std.hash.XxHash64`, 64-bit, seed pinned `0`; every integer enters little-endian via
  `writeInt`. `Fixed.raw` as i64 LE, `Angle.raw` as u32 LE, `Entity` as `index:u32` then `generation:u32`
  LE, mask at its `uN` width LE, bool as one byte, enum as its tag int LE. A `Crc32` over the identical
  byte stream runs alongside as a codec-vs-collision tripwire.
- **Q6 — On-wire format:** self-describing versioned container. Header (LE): `magic [4]u8="GKZ1"` |
  `format_version:u16` | `schema_version:u32` | `tick:u64` | `component_count:u16` | `row_count:u32`.
  Then allocator block, then RNG root (`seed:u64`), then the table in canonical by-entity order
  (`owner.index`, `owner.generation`, `mask`, then each present component field-by-field by ascending
  `kind_id`). Per-Kind `{kind_id, size_bytes}` fingerprint in the header. Hash covers the whole stream
  incl. header. Unknown `kind_id` on restore is an explicit error, never a silent skip.
- **Q7 — Canonical bytes:** **field-by-field little-endian, padding-free, canonical-zero-on-clear.**
  Recurse `@typeInfo(...).@"struct".fields`; `writeInt` each leaf `.little`. Components are
  comptime-rejected unless `extern`/`packed` (belt) **and** still serialized field-by-field (suspenders).
  `removeComponent` overwrites the cleared slot with canonical zero so stale bytes can never reach the hash.
- **Q8 — `step` body (minimal end-to-end):** `step` takes a caller-supplied ordered `systems` slice
  (Phase-1 passes a 1-element comptime slice; §4 passes a topo-ordered slice). Per tick: `tick +%= 1`;
  canonicalize the command list and `apply` each mutation; run the systems slice. The Phase-1
  `demoSystem` walks the table in canonical order, draws one keyed-RNG value per live entity owning a
  designated "moving" component, and integrates with `Fixed.addSat` — exercising structural mutation +
  keyed RNG + fixed-point math + tick advance through one real loop.
- **Q9 — Storage model:** **flat dense table + per-row component bitmask** (Candidate C above),
  realized with **one `std.MultiArrayList`** over a tuple row `(Entity, Mask, …components)` — *not* a
  hand-rolled set of columns. MAL gives SoA columns, a single backing allocation, and a `swapRemove`
  that fixes owner + mask + every component atomically (eliminating multi-column lockstep as a
  determinism risk). `Mask = std.meta.Int(.unsigned, ≤64)` (Phase-1 ≤64 Kinds → `u64`). `index_to_row:
  ArrayList(u32)` (an **array**, not a map) is the *one* separate sparse index, patched by a single
  line after a swap. spawn appends a canonical-zero row (`mask=0`); despawn = `swapRemove` + patch the
  moved row's `index_to_row`; add = set bit + write `items(.kᵢ)[row]`; remove = clear bit +
  canonical-zero that slot. Canonical order = argsort of the owner column by `entity.index`, recomputed
  (never cached) at hash/serialize time. (MAL is the column container for *either* fork — one MAL here,
  one-per-archetype in the deferred S1 archetype upgrade — so it does not bind the C-vs-B choice.)

---

## 4. Determinism rules the code must obey (D1–D9, enforced by §7 gates)

- **D1** `step` reads only its two params, writes only its returned World. No globals/statics/IO.
- **D2** Determinism never depends on safety checks being compiled in. ReleaseFast is canonical. No
  `unreachable` on input-dependent conditions. `Debug == ReleaseSafe == ReleaseFast` per-tick hash
  stream (tested). Arithmetic that can overflow uses an explicit `+%`/`+|`/`@addWithOverflow` choice.
- **D3** No clock / OS-rng / syscall / file / network on the step path.
- **D4** RNG is counter-based & keyed: `draw(seed, tick, entity_id, stream_id)`, pure, no float, no
  cursor. World holds only the seed root.
- **D5** Per-tick hash is over the canonical serialization with a stable total ordering. Never hash raw
  struct memory/padding, hashmap order, addresses, or insertion history. Fixed endianness.
- **D7** No floating point on the sim path (`Fixed`/`Angle` only; float only for comptime constants/display).
- **D8** No pointers in State; entity refs are generational `{index,generation}` handles.
- **D9** Deterministic iteration everywhere; sort keys before any order-sensitive traversal; never bucket order.

---

## 5. Phase 1 — Foundation (module layout)

Dependency arrows point downward (importer above its dependency); no cycles. All under `src/`.

```
root.zig          public re-exports (the kernel API surface)
 ├─ replay.zig    Recorder(seed+input log); replay(base, inputs); round-trip + cross-build + fork harness
 │   ├─ snapshot.zig   Snapshot{bytes,tick,hash,crc}; snapshot/restore; cadence config (NOT in World)
 │   └─ step.zig       step(comptime R) : (gpa, World, Input) -> World; clone, tick+%1, apply cmds, run systems
 │       ├─ mutation.zig   Mutation union {spawn,despawn} + apply(World,Mutation)   [S2 seam; add/remove/set → Phase 2]
 │       └─ input.zig      Command/Input; canonical command ordering; input-log record/replay codec
 ├─ hash.zig       hashWorld(world) u64 : streaming XXH64(0) + Crc32 over the shared canonical traversal
 │   └─ serialize.zig  canonical field-by-field LE writer + reader; header(Q6); forEachCanonicalByteRun(sink)
 └─ world.zig      World(comptime R){tick,schema_version,rng_root,entities,table}; clone (MAL.clone + arrays); deinit
     ├─ storage.zig    Table(R): std.MultiArrayList(Row=(Entity,Mask,...components)) + index_to_row array; mutators; canonicalOrder
     │   ├─ registry.zig   Registry(components): comptime validate (extern/packed, unique kind_id, no float/ptr); Mask; kind order
     │   ├─ sort.zig       sortPermutation wrapper over std.sort.pdq w/ documented total comparator (pinned)
     │   └─ entity.zig     Entity{index,generation}; ROW_NONE; EntityAllocator (FIFO free-list, +%1 gen, isLive)
     └─ rng.zig        RngRoot{seed}; draw(root,tick,eid,sid) u64 (threefry/PCG, pure); drawFixed(...) range-clamped
```

The **serialize/hash split shares exactly one traversal** (`forEachCanonicalByteRun(world, sink)` where
`sink` is either a byte-appender or a hasher), so the hash is *provably* over the canonical
serialization (D5) with zero duplicated ordering logic.

### Key types (sketch; see synthesis for full signatures)

```zig
// entity.zig
pub const Entity = extern struct { index: u32, generation: u32 };
pub const ROW_NONE: u32 = std.math.maxInt(u32);
pub const EntityAllocator = struct { generation: ArrayList(u32), free_list: ArrayList(u32),
                                     free_head: u32, next_index: u32, /* alloc/free(+%1)/isLive */ };

// registry.zig — comptime; validate(), Mask = std.meta.Int(.unsigned, <=64), kindIndex/bit/sorted_by_kind_id
pub fn Registry(comptime components: anytype) type { ... }

// storage.zig — columns = ONE std.MultiArrayList over a tuple row (Entity, Mask, ...components).
//   Row = std.meta.Tuple(&(.{Entity, Mask} ++ R.Components))  (no @Type; verified on 0.16).
//   swapRemove fixes owner+mask+all components atomically; index_to_row is the one separate array.
pub fn Table(comptime R: type) type {
    return struct {
        rows: std.MultiArrayList(R.Row) = .empty,      // owner=.@"0", mask=.@"1", component k=.@"k+2"
        index_to_row: std.ArrayList(u32) = .empty,     // entity.index -> row, ROW_NONE if dead (array, not a map)
        // spawnRow/despawnRow(swapRemove + patch one index_to_row)/addComponent/removeComponent(zero slot)/get/canonicalOrder
    };
}

// rng.zig
pub const RngRoot = extern struct { seed: u64 };
pub fn draw(root: RngRoot, tick: u64, entity_id: u32, stream_id: u32) u64 { ... }

// input.zig
pub const Command = extern struct { actor: Entity, verb: u16, _pad: u16 = 0, a0: i64, a1: i64, a2: i64 };
pub const Input = struct { tick: u64, commands: []const Command };

// world.zig
pub fn World(comptime R: type) type { return struct { tick: u64, schema_version: u32,
    rng_root: RngRoot, entities: EntityAllocator, table: Table(R), /* clone/deinit */ }; }

// public contract
pub fn step(comptime R: type) fn (std.mem.Allocator, World(R), Input) World(R);
pub fn snapshot(gpa, world) Snapshot;          // bytes + tick + hash + crc
pub fn restore(comptime W: type, gpa, bytes) W;
pub fn replay(comptime W: type, gpa, base: Snapshot, inputs: []const Input) W;
pub fn hashWorld(world) u64;
pub const Snapshot = struct { bytes: []u8, tick: u64, hash: u64, crc: u32 };
```

### Build order (test after each step; capstone = cross-build hash gate)

1. **entity.zig** — alloc/free/FIFO recycle fixed; `+%1` gen; `isLive` rejects stale. *(Q4 foundation.)*
2. **registry.zig** — comptime: `.auto` layout fails to compile; duplicate `kind_id` fails; `Mask`
   width; `sorted_by_kind_id` is a permutation independent of tuple order. *(Q1.)*
3. **sort.zig** — `sortPermutation` deterministic on unique keys; property test over random permutations.
4. **storage.zig** — mutator round-trips; `removeComponent` zeroes the slot (read raw bytes); despawn
   `swapRemove` + `index_to_row` patch resolves the moved entity; invariant after fuzzed mutations:
   `rows.len` consistent and every live entity's `index_to_row` points at a row it owns. (MAL gives
   same-length columns + atomic swap for free, so tests focus on the mask, the zero-on-clear, and the
   single `index_to_row` patch — the parts MAL does *not* do.)
5. **rng.zig** — `draw` pure; pinned vector; `drawFixed` never produces an operand that trips an `fpz` assert.
6. **serialize.zig** — writer/reader round-trip byte-identical; **padding-poison test** (garbage in pad
   bytes → identical hash). *(Q6/Q7.)*
7. **hash.zig** — pinned XXH64 vector; streaming==one-shot; `hashWorld` invariant to spawn/despawn
   *history*; Crc32 tripwire. *(D5.)*
8. **world.zig** — `clone` independent + identical hash; mutating clone doesn't perturb original. *(D1.)*
9. **input.zig** — canonical command order is a stable total order; input-log record/replay round-trips.
10. **mutation.zig** — each variant drives the right mutator; canonicalized command apply is order-deterministic.
11. **step.zig** — `step` pure; `tick +%1`; one tick changes hash deterministically; re-run on clone == identical hash.
12. **snapshot.zig + replay.zig** — snapshot@0, run N ticks (record per-tick hash stream + spawned-Entity
    map), replay from @0, assert hash stream + spawned-Entity map + sorted `row_owner` bit-identical. Add the fork test. *(Q4 end-to-end.)*
13. **build.zig multi-mode gate (capstone)** — `zig build test` runs the **whole suite under Debug +
    ReleaseSafe + ReleaseFast**. Instead of a separate `hashdump`/`hashcheck` exe pair, the suite pins
    two constants in `replay.zig` — the end-to-end final-state hash **and** a rolling digest over the
    per-tick hash stream — asserted identically in every mode; all three modes passing therefore proves
    `Debug == ReleaseSafe == ReleaseFast` for both the final state and the full per-tick stream (D2).
    Includes the deliberate-overflow (`addSat`) divergence test. *(Implemented; a big-endian qemu row
    remains future work — §7 risk #7.)*

### Determinism test plan (the gates)

1. **Round-trip serialize** — `snapshot → restore → re-serialize` byte-identical; `hashWorld` equal;
   over a fuzzed spawn/despawn/add/remove sequence (exercises swap-remove churn).
2. **Replay == live hash sequence** — interval=1; live N-tick hash stream == replayed tail; plus per-tick
   spawned-Entity map and sorted `row_owner` match. *(Q4.)*
3. **Cross-build hash agreement (D2 capstone)** — `zig build test` runs the suite in all 3 modes; a
   pinned final-state hash **and** a pinned per-tick-stream digest (`replay.zig`) are asserted in every
   mode, so passing across the matrix proves bit-identity for both. ReleaseFast canonical.
4. **Deliberate-overflow divergence test** — feed a `Command` whose `Fixed` operand would overflow an
   unguarded scalar `add` (which panics in Debug/ReleaseSafe, wraps in ReleaseFast); `demoSystem` uses
   `addSat` and `drawFixed` range-clamps; assert all three modes still agree. Also guards div-by-0,
   `neg/abs(MIN)`, `fromInt` range, `atan2(0,0)` on command-derived operands.
5. **Entity-id stability across replay** — gate 2 + a fork test (replay two divergent input tails; shared
   prefix entity ids match exactly).
6. **Padding-poison** — component with inter-field padding; garbage in pad; hash unchanged. *(Q7.)*
7. **History-invariance** — same logical world built two ways → equal hash. *(canonical argsort.)*
8. **Canonical-zero-on-clear** — add value, remove, re-add different; cleared slot raw bytes == zero;
   hash matches a churn-free build.

---

## 6. Full-kernel phased roadmap

Each phase ends with the cross-build determinism gate green. Seam labels (S1–S8) match SPEC §14 and the
Phase-1 `deferred_with_seams` provisions, so later phases bolt on without reworking storage/serialize/hash.

| Phase | SPEC | Scope | Key new seam consumed |
|---|---|---|---|
| **1. Foundation** *(this plan)* | §1,2,3,6 | ECS-as-value, pure `step`, canonical serialize+hash, snapshot, deterministic replay, cross-build gate. | — establishes all |
| **2. Systems & deterministic scheduler** ✅ | §4 | comptime `Read/Write/With/Without` access sets; `@compileError`-gated `Query`; DAG conflict detection `(writeA & (readB\|writeB))` → greedy comptime stages; per-system **command buffers** drained at one end-of-tick sync point in **`(system_id, seq)`** order (corrects the non-total "(system_id, entity_id)"); restricted `SimCtx`; single-thread + an **order-permutation determinism gate**. Real threads = 2b. | **S1, S2** |
| *2b. SIMD/archetype upgrade (perf track)* | §3 | swap flat table → archetype tables behind the storage seam; SIMD batch path via `fpz.simd`. Hash/serialize/`step` unchanged. Extend cross-build gate to scalar-vs-SIMD overflow. | **S1** (sealed upgrade) |
| **3. Events & causality** | §5 | event emitter threaded through `SimCtx` into a **side** log (never in the hashed World); causal graph; tiered (on-demand) provenance recording. | **S3** |
| **4. VOPR** | §9 | seeded input driver; fault/timing injection (none may change the hash); property checking across seeds; divergence detection (the Phase-1 hash-stream compare, scaled); delta-debugged minimal `(seed,inputs)` repro. | reuses gate-3 harness |
| **5. Query surface** | §7 | Datalog-ish relations (`component/3`, `event/5`, `caused_by/2`, `system/3`, `diverge/3`) over a socket; reflection from §4 access sets. | **S5** |
| **6. Specs / invariants / properties** | §8 | state invariants; temporal/LTL properties over the trace; intent-metrics over agent runs. | **S8** |
| **7. Agent harnesses & evaluation** | §10 | `observe(State)->Input` policies (scripted/search/learned); mass faster-than-realtime evaluation; aggregate intent-metrics. NN inference is the *player*, not the *world*. | reuses Input channel |
| **8. Hot-reload & migration** | §12 | `dlopen`/`dlclose` of native systems (state stays in columns); version-tagged pure `World→World` schema migrations dispatched on `schema_version` + per-Kind fingerprint. | **S6** |
| **9. Process model & control plane** | §13 | one-OS-process-per-sim; supervisor pool (spawn/monitor/restart/harvest); query server multiplexing live sims; forks from snapshot + diverged input. | **S7** |

Cross-cutting: **content-as-data** (§11) — prefabs/levels are diffable data authored via the same
serialization codec; informs Phases 1+. **Peripheral adapters** (§14: view/render, input, audio,
netcode, asset import, editor) are out of kernel scope (§15) — only their one-way seams are defined here.

---

## 7. Open risks to revisit

1. **Memory (accepted headline cost):** every live row reserves a slot in every column → storage =
   `row_count × Σ sizeof(C_k)` regardless of sparsity. At §9 mass-fuzz scale with many optional
   components this pressures cache/RAM and may force the S1 archetype upgrade earlier than planned.
2. **Iteration + per-tick sort cost:** a system over a rare component mask-scans all rows (`O(total)`);
   `canonicalOrder()` argsorts every hashed tick (`O(n log n)` at interval=1). Performance, not correctness.
3. **Panel disagreement worth weighing:** spec_fidelity and forward_compat lenses both preferred **B**
   for the literal §3 "archetype" noun and the native SIMD/DAG substrate. C was chosen because B is the
   determinism-weakest candidate and the archetype clause's purpose (SIMD) is deferred. **If a near-term
   roadmap item makes the §4/§9 SIMD query path Phase-2-imminent, reconsider starting from B / accelerating S1.**
4. **Mask-width ceiling:** Phase-1 caps at ≤64 Kinds (`Mask=u64`). Crossing 64 is a schema-version-visible
   on-wire change requiring an S6 migration. Confirm 64 ≫ Phase-1 component count.
5. **`std.sort.pdq` is unstable:** harmless today (row-sort key `entity.index` is unique among sorted
   items), but we pin our own `sort.zig` wrapper. A future sort over a non-unique key reintroduces
   tie-nondeterminism — a code-review invariant to enforce.
6. **Clone-per-tick cost:** `step` clones the whole World each tick (`O(total bytes)`) — `MultiArrayList`
   has a `.clone(gpa)` (single backing alloc), plus the small allocator/index arrays. Cheap for the flat
   table now; under the S1 upgrade or large worlds this may need copy-on-write or
   in-place-with-external-snapshot (a documented alternative).
7. **fpz scalar vs SIMD overflow asymmetry:** see §1. The cross-build gate must grow a scalar-vs-SIMD
   case once SIMD is on the sim path (Phase 2b).
8. **`Input.tick` is advisory, replay is positional.** `step` ignores `in.tick`; alignment of the input
   stream to ticks is by slice position. The recorded `tick` is metadata for the log, not a checked
   invariant. If misalignment becomes a real failure mode, add a validated `in.tick == w.tick` check
   (or drop the field). *(Review finding spec#0, accepted.)*
9. **Entity-index ceiling = 2³².** `EntityAllocator` indexes are `u32`; a sim that allocates >2³²
   distinct slots hits an `@intCast` panic (a resource ceiling, not malformed input — distinct from the
   D2 "no input-dependent panic" guarantee). Astronomically unreachable; documented, not handled.
   *(Review finding zig#1, accepted.)*

### Phase 2 notes (from the Phase-2 adversarial review — 15/17 confirmed, no critical/high)

10. **Command payload ceiling = 64 KB.** `Command.payload_len` is a `u16`; a component whose *serialized*
    size exceeds 65535 bytes is now a **compile error** (`comptime` assert in `command_buffer.zig`), the
    same class of explicit resource ceiling as #9.
11. **Keyed-RNG isolation is by `stream_id`, not `system_id`** (SPEC §2.4 faithful): two different
    systems drawing with the same `(entity_id, stream_id)` in the same tick get the *same* value — a
    feature (shared deterministic decision), not a bug. A system wanting independent randomness picks a
    distinct `stream_id`. Documented on `SimCtx.rng`. *(Review finding determinism#1.)*
12. **The Query access gate is an authoring aid, not a sandbox.** The system author is trusted (SPEC §15:
    no scripting sandbox); the bare `*Table` is reachable on the `Query`/`RowView` handle, so a system
    that deliberately reaches around `read`/`write` is possible and would be caught by the VOPR (§9) as
    divergence. The gate makes the *honest* mistake uncompilable. *(Review finding spec#0, accepted.)*
13. **Reflection negative cases are documented, not mechanically tested.** `Query.read`/`write` misuse
    and malformed `system()` fns are `@compileError`s (verified by design; `system()` now emits clear
    messages), but a failing-compile CI fixture is deferred. *(Review finding zig#1/tests#8, accepted.)*
