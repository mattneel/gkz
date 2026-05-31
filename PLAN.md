# gkz — Implementation Plan

> Companion to [SPEC.md](./SPEC.md). SPEC says **what** the kernel is; this says **how** and **in what
> order** it gets built, and records the architectural decisions made along the way. The primary user
> is an AI; every decision below favors determinism, legibility, and a tight feedback loop.

Status: **Phases 1–6 implemented; all determinism gates green; adversarial reviews passed.**
**Foundation (§1–§3/§6)** + **Systems & scheduler (§4)** + **Events & causality (§5)** + **the VOPR
(§9)** + **the §7 query surface** + **§8 specs/invariants/properties** are complete: **612 tests** across
Debug/ReleaseSafe/ReleaseFast — pinned end-to-end + per-tick-stream hashes (cross-build bit-identity, D2),
an order-permutation gate (execution-order independence), an events-OFF==events-ON hash-invariance gate +
a pinned event-log digest, the VOPR capstone (an injected determinism bug is caught/bisected/minimized/
explained; a clean schedule reports zero defects) with an `OutOfMemory`-injection sweep proving the VOPR
pipeline leak-/double-free-safe, the §7 query surface with 8 pinned cross-build GKZR1 result digests + a
SCRAMBLE invariance sub-gate, and the §8 spec layer (state invariants + seven closed temporal combinators
+ integer intent-metrics) with exact-(tick,witness) catches for both canonical temporal examples, pinned
violation/spec/metric digests, a checks-on==off hash-invariance sub-gate, and a temporal Defect riding
sweep→minimize→provenance. Commits: Phase 1 `a589d39`, Phase 2 `37748cf`, Phase 3 `1a33f29`, Phase 4
`9be50c3`, Phase 5 `0540f86`; Phase 6 lands in this commit (adversarial review 9/10 confirmed — fixes:
an `errdefer`-on-`buildRun`-consumed-world double-free in 5 test helpers, a `responds` overflow D2 hazard
(`+|`), an i64 field-cast comptime guard, and three test-coverage gaps).
This document is the decision of record. It was produced from a
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
| **3. Events & causality** ✅ | §5 | recording `EventEmitter` threaded through `SimCtx` into a **side** `EventLog` (owned by a `Recorder`, never in the hashed World); structural `EventId` + a **distinct, component-storable `CauseToken`** (storing an `EventId` in a component is a compile error); auto-attributed `SystemCause` nodes + cross-tick `causeTokenHere`/`causeFromToken`; `causesOf`/`causeChain` backward-walk; tiered on/off recording. **Events are hash-invariant** (events-OFF == events-ON, gated). Typed payload decode + the §7 relational surface deferred. | **S3** |
| **4. VOPR** ✅ | §9 | one `Oracle`/`Defect` abstraction (invariant · divergence; crash/`.trap` deferred to the build-mode/process boundary); seeded pluggable `Generator`; fault/timing injection (within-stage exec permutation + snapshot-cadence round-trip — none may change the per-tick hash) with first-tick bisection; kind-locked delta-debug minimization; provenance re-run (`causeChain`) on a hit; `sweep` a pure function of a seed range (the §13 sharding seam). Capstone: an undeclared-write system is caught/bisected/minimized/explained; the correct twin → zero defects. | reuses step/runScheduled/snapshot/digest/Recorder |
| **5. Query surface** ✅ | §7 | minimalist hand-canonicalized relations (`component/3`, `event/5`, `caused_by/2`, `system/3`, `diverge/3`) + the 4 canonical shapes (Why/What-affects-X/Where-broke/Reachability) over a uniform `Value` substrate; self-describing catalog (`relation_schema`/`relation_column`); reflection from §4 access sets (never drifts); GKZQ1/GKZR1 serializable wire codec (the socket transport is Phase-9/S7). | **S5** |
| **6. Specs / invariants / properties** ✅ | §8 | state invariants (the `fn(*const World)?Entity` shape, every-tick `checkAll` + VOPR `invariantOracle`); a CLOSED set of seven temporal combinators (always/eventually/stable/monotonic_unless/until/precedes/responds) folded over an O(T) projected-scalar `Trace` (bounded-trace/LTLf, witness-pinning); integer intent-metrics + sweep aggregate; the fun-oracle boundary as a TYPE distinction (checks→`?Violation`, metrics→`i64`, intent exogenous). Violations ride the §4 Defect (additive `.temporal` kind) through sweep→minimize→provenance and surface as the §7 `spec`/`violation` relations. | **S8** |
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

### Phase 3 notes (from the Phase-3 adversarial review — 14/16 confirmed, one HIGH fixed, rest fixed/documented)

14. **Event payload ceiling = 64 KB** (fixed). `Event.payload_len` is a `u16`; a `>64KB`-serialized
    event type is now a **compile error** (`comptime` assert in `recorder.record`), matching the
    command-buffer ceiling — closing a HIGH-severity D2 build-mode divergence (ReleaseFast would have
    silently truncated the recorded log while Debug/ReleaseSafe trapped). *(zig#0/determinism#0.)*
15. **Input/command provenance is deferred.** Phase 3 auto-attributes each event to a per-(tick,system)
    `SystemCause` root node; the bottom of SPEC §5's canonical chain (`… ← input command`) is not yet
    represented, because the Phase-2 input path applies structural commands without an emitter. SPEC §5's
    example is thus *partially* realized (event ← system ← … holds; ← input deferred). Lands when the
    input path gains emission. *(spec#0, accepted.)*
16. **Event-log physical order = system execution order.** `EventId` *identity* is structural and
    `causeChain` output is canonically sorted, so causal *queries* are order-independent — but the log's
    physical array order (and thus `logDigest`) follows the order systems ran. Canonical today
    (single-threaded, canonical `exec_order`; the order-permutation gate runs permutations with
    recording **off**). **Phase 2b** (real within-stage threads) must record into per-system sub-logs
    merged deterministically (e.g. by `EventId`) before `logDigest` is order-stable under parallelism;
    the `cur_sa` single-slot `SystemCause` dedup likewise assumes serialized per-(tick,system) emission.
    *(determinism#1 / spec#2, documented; a 2b seam.)*
17. **`readLog` hardened for untrusted bytes** (fixed). Validates declared sizes against the buffer
    before allocating (no unbounded reservation) and each event's offsets against the arenas (no OOB in
    `causesOf`/`payloadOf`); arena lengths assert a 4 GB ceiling. *(zig#1, zig#2, memory#0.)*

### Phase 4 notes (from the Phase-4 adversarial review — 16/16 confirmed; two HIGH + the rest fixed/documented)

18. **Provenance re-anchors at the MINIMIZED failing tick** (HIGH, fixed). Minimization renumbers ticks
    (dropping leading no-ops moves the failing tick earlier), so anchoring `provenanceRerun` at the
    *original* `d.tick` silently produced an empty/wrong cause chain on any defect that wasn't already at
    tick 1. `sweep` now re-evaluates the oracle on the minimized stream to get the post-minimization
    defect (`d_min`), stores *that* in the report, and anchors provenance at `d_min.tick`. Regression: a
    defect first appearing at tick 5 with two droppable leading ticks minimizes to tick 3 — the report
    tick is 3 and the chain is non-empty. *(soundness#0 / zig#0.)*
19. **Ownership is taken before the first fallible call** (HIGH, fixed). `buildRun` (and, found by the new
    OOM-injection test, `captureStream` / `captureStreamCadence`) consumed a `World` by value but ran a
    fallible allocation — the snapshot, resp. the `hashes` alloc — *before* registering `errdefer
    w.deinit`, leaking the consumed World on OOM. Each now does `var w = w0; errdefer w.deinit(gpa);`
    first. Likewise `provenanceRerun` had an explicit `w.deinit` *plus* an `errdefer w.deinit` (a trailing
    `causeChain` OOM would double-free) — collapsed to one `defer`. `sweep`'s `cause_chain` gets an
    `errdefer gpa.free` between build and append. A `checkAllAllocationFailures` sweep over the full
    pipeline now proves leak-/double-free-freedom. *(memory#0, memory#1 + two bonus catches.)*
20. **`enumerate` guarantees non-identity exec-permutation coverage** (LOW, fixed). `execPermutation` was a
    seed-keyed Fisher-Yates that could (≈2^-budget) emit only identities for a small racy stage —
    a false-negative coverage gap. It is now a deterministic, seed-independent per-stage left-rotation:
    `perm_index == 1` rotates every multi-member stage by 1 (a guaranteed swap for size 2), so
    `enumerate(budget ≥ 2)` always covers a real reordering. A test wires `enumerate` into the leaky
    sweep and confirms the divergence is caught with no hand-picked index. Rotation covers the
    neighbour-order classes that matter for detecting order-dependence; full-permutation enumeration of a
    stage is a later enhancement. *(soundness#1, tests#6.)*
21. **Hardening + recorded deferrals** (the remaining mediums/lows/nits). The cadence (snapshot/restore)
    path now has an identity test (cadence-k hashes == continuous), `randomGen` is driven end-to-end
    through a sweep against an invariant, the divergence `firstDivergentTick` detail read is length-
    guarded, and the divergence `Defect.Detail.hashes` is documented as (seed, tick)-only — per-component
    /per-system bisection of *which* write diverged needs the §7 typed-component diff and is deferred, as
    is input-command provenance at the bottom of a chain (shared with Phase 3 note 15). Command-buffer
    apply-timing is *subsumed* by `exec_perm` (the drain is already `(system_id, seq)`-ordered and
    exec-order-independent), documented in `inject.zig`. *(tests#0/#2/#4/#5, zig#1, spec#0/#1/#2.)*

---

## 8. Phase 5 design — the §7 relational query surface (decision of record, from the design judge-panel)

Produced by a 5-architect / 5-lens judge panel (determinism · spec_fidelity · ai_ergonomics · scope_realism ·
forward_compat) + synthesis. **Spine = the minimalist hand-canonicalized relation surface** (the only design judged
buildable at prior-phase size *and* highest on determinism: every relation is a hand-written canonical traversal over
already-certified kernel machinery; recursion delegates verbatim to `event_log.causeChain`; no parser, no general join
planner, no fixpoint solver). **Rejected as spine:** a real text-Datalog engine (#2 — scope-fatal: parser + stratified-
negation semi-naive evaluator are net-new no-reuse subsystems, and stratified negation is a determinism hazard) and the
volcano pull-iterator algebra (#5 — pays Cursor-vtable + borrow-lifetime cost for laziness that materialize-at-boundary
makes moot). **Four grafts onto the spine** (each flagged by ≥1 lens): (1) a **uniform closed-tag `Value` substrate** —
fixes #1's fatal ai_ergonomics flaw so every result row is the same machine-parseable value space and the diverge diff +
GKZR1 codec are one `writeValue` loop; (2) a **self-describing catalog** (`relation_schema`/`relation_column` as
queryable relations + a comptime producer-vs-meta drift tripwire) so an AI with no source access discovers the surface
by querying it; (3) the **scramble-invariance sub-gate** — proves the canonical re-sort *severs* observation order
(Phase-2/3 gate analogue); (4) a **dual-path recursion cross-check** (`why`-via-generic-walk == `causeChain`).

**Modules (`src/query/`), in build order:** `term.zig` (the `Value` union + total `Value.order`/`tupleOrder` + named
`Schema`/`Row`/`RelId`/`BytesRef`); `result.zig` (`QueryResult` + `Builder` with errdefer cleanup + `finalize` canonical-
sort/dedup + `resultDigest`); `relations.zig` (the five producers over borrowed `*const World`/`*const EventLog`/comptime
`Schedule`: `component/3` via `Table.canonicalOrder`+`writeValue`, `event/5` re-sorted by `EventId.order`, `caused_by`
+`whyChain` delegating to `causeChain`, `system/3` comptime from `Sys(R).access` via `R.sorted`/`kindId`, +
`whatWrites`/`whatReads` mask-scans); `catalog.zig` (comptime `RelMeta` → the two catalog relations + the drift assert);
`diverge.zig` (component-level `diverge/3` = `firstDivergentTick` bisect → `worldAt(t)` both runs → canonical
`(entity.index,kind_id)` component-byte diff; `firstTickWhere` reusing `oracle.invariant`'s predicate shape; generic
`reach()` fixpoint over an exogenous adjacency relation); `wire.zig` (GKZQ1 query + GKZR1 result codecs reusing
`serialize.ByteSink`/`ByteReader`/`writeValue`, magic+version header, readLog-style validate-before-alloc, never panic;
the `respond(bytes,gpa,env,*ByteSink)` S7 seam, zero io); `query.zig` (the `Query(R)` tagged union + `Engine(R)` +
exhaustive `evaluate` switch); `gate.zig` (the cross-build gate + pinned per-relation/-shape/-catalog GKZR1 digests + the
5 sub-gates). Covers all five relations and all four canonical shapes (Why/What-affects-X/Where-broke/Reachability).

**Phase-5 gate:** all 3 build modes assert the SAME pinned GKZR1 `resultDigest` constants (D2/D5), plus five mechanism
sub-gates: SCRAMBLE invariance (churn table layout + permute exec order + shuffle log order → digests unchanged);
comptime `system/3` reflection-exactness (reflected masks == independently recomputed `Access`); dual-path
`why==causeChain`; GKZQ1/GKZR1 wire round-trip identity + hostile-input rejection (never panic); OOM-injection leak-
freedom. **Deferred behind seams:** socket transport / live-sim server (S7, Phase 9 — `respond` is a pure bytes→bytes
handler, engine borrows by const pointer); textual Datalog parser (S5-text — `Query(R)` is the serializable language; a
future `parse([]u8)->Query(R)` bolts on); invariant/LTL semantics for Where-broke (S8, Phase 6 — `firstTickWhere` takes
the opaque predicate); the exogenous reachability adjacency relation (S8/S5, Phase 7 — `reach()` takes it as a param);
typed event-payload decode (S5 — payload stays canonical bytes tagged with `kind_id`; a comptime `decodeValue` is a non-
breaking add); runtime relation registration / general join / aggregation (S5 — a future relation is a new arm+producer
+catalog entry+pinned digest, additive-by-recompile). `diverge`/`reach`/`first_tick_where` Query arms carry in-process
pointers (Run/pred/adjacency) → wire-encoded as Phase-9-resolved handles, real pointers in in-process tests.

### Phase 5 notes (from the Phase-5 adversarial review — 7/8 confirmed, one HIGH fixed, rest fixed/documented)

18. **`readResult` rejects `arity==0`** (HIGH, fixed). A 14-byte hostile GKZR1 frame with `arity=0` and
    `row_count=0xFFFFFFFF` drove an unbounded (~824 GB) allocation: with zero cells per row the per-cell
    bounds-checked-reader advance never fires, so the decoder pushed billions of empty rows before
    `OutOfMemory`. Every real relation has arity ≥ 2 (the catalog asserts it), so the guard is now
    `if (arity == 0 or arity > MAX_ARITY) return error.Corrupt;` — a fail-fast on the untrusted §13
    control-plane decode path. Regression: the arity-0 huge-`row_count` frame now returns `Corrupt`.
    *(hostile#0.)*
19. **`diverge/3` empty-result semantics made precise** (fixed/documented). diverge/3 locates COMPONENT-CELL
    divergences; it returns empty in three cases — runs never diverge, length-only divergence, OR the first
    hash-divergent tick differs only in non-component World state (entity-allocator generation/free-queue,
    tick, rng_root), which has no `(entity, kind)` cell. The hash-level `firstDivergentTick` always detects
    *existence*. Docstring corrected + a regression test (an extra bare entity diverges the allocator/hash
    but yields an empty diverge/3 while `firstDivergentTick != null`). A structural/allocator-level diff is
    a deferred enhancement. *(ce#0 / spec#0.)*
20. **Gate sub-gates hardened** (fixed). (a) The component SCRAMBLE twin was vacuous — both despawn orders
    converged to the same physical layout; replaced with a genuine layout scramble (a component-less
    throwaway kept live vs. despawned, which swap-relocates a content row while the relation stays
    identical), asserting equal digests across differing `rowCount`. (b) The OOM-injection battery now
    includes `firstTickWhere` + `reach` (previously omitted despite the "whole query battery" claim). (c)
    The battery now exercises the GKZQ1 query codec (write→read→evaluate), not only GKZR1. (d) The
    `system/3` reflection-exactness oracle recomputes expected kind lists via a DIFFERENT primitive
    (iterating component types + `bitOf` + insertion sort) instead of the producer's `R.sorted[p]` loop, so
    it is no longer circular. *(tests#0/#1/#2/#4.)*

Bonus catches fixed during implementation (before review): a `buildForks` double-free (an `errdefer` on a
world that `buildRun` consumes) surfaced by the OOM sub-gate, and a dangling column-name borrow in
`readResult` (decoded `schema.names` borrowed the caller's reader buffer) — names are now owned in the
result's arena.

---

## 9. Phase 6 design — §8 specs/invariants/properties (decision of record, from the design judge-panel)

5-architect / 5-lens judge panel + synthesis. **Spine = the minimalist closed-combinator spec layer** (judge winner on
determinism=90 and scope_realism=88: almost no NEW determinism surface — invariants reuse the verified
`fn(*const World(R)) ?Entity` shape, temporal checks are auditable ascending-tick folds, metrics are integer-only,
the every-tick hook is `*const`-borrow-only and `runtime_safety`-gated so on==off is bit-identical by construction).
**Rejected:** the full-LTL AST as the temporal representation (scope_realism=42 — a logic engine, not one phase;
witness-descent over nested operators an unproven determinism hazard) — but its **atom layer is kept**; and the
full-component-per-tick Frame trace (memory blowup over a sweep). **Four grafts onto the spine:** (1) a single **O(T)
forward-replay projected-scalar `Trace`** (one replay feeds every combinator + metric; cheaper than per-property O(T²)
`worldAt`) storing only `[]i64`/`[]bool` probe columns + at most one optional `EventLog`; (2) a **named-`Atom` leaf
substrate + multi-entity `Witness`** so "no two solids overlap … the entities involved" can pin plural entities and the
canonical examples are honest compositions; (3) a self-describing **`spec` §7 relation** alongside **`violation`** so an
AI enumerates declared intent the way it bootstraps the schema catalog; (4) a gate assertion that the `Trace`'s per-tick
projection digests equal `run.hashes` AND `captureStream`'s certified stream — turning the one silent trace-rerun
assumption into a hard cross-build tripwire.

**Decisions:** temporal = a CLOSED set of **seven combinators** (`always`/`eventually`/`stable`/`monotonic_unless`/
`until`/`precedes`/`responds`) as hand-written deterministic folds — NO parser/AST/automaton (the `Combinator` enum is
non-exhaustive `_` so a future bounded-trace `composite` AST arm is additive over the same `Trace` fold + `Witness`).
Both SPEC canonical examples are covered exactly (`stable`=boss-stays-dead; `monotonic_unless`=score-never-drops-except-
Penalty). The **fun-oracle boundary is a TYPE distinction**: checks return `?Violation` (the engine GUARANTEES a
verdict → a `Defect`); metrics return an integer scalar (the engine MEASURES, never judges; a metric becomes checkable
only when a human/agent EXOGENOUSLY declares a bound). Violations integrate via an **additive `Defect.Kind.temporal`**
(both `Defect.Kind` and `RelId` are non-exhaustive, so nothing renumbers and the Phase-1..5 pinned digests are
untouched) flowing through `sweep→minimize→provenance` for free; `monotonic_unless`'s `EventLog` comes from a single
`provenanceRerun`-style Recorder rerun whose per-tick hashes the gate asserts == `run.hashes`. The every-tick Debug/Safe
`checkAll` hook is **optional** (oracle.invariant already checks every tick on demand) — the scope risk-valve.

**Modules (`src/spec/`), build order:** `atom.zig` (`Atom`/`AtomHit`/`Witness` + built-in `rangeI`/`referencedLive`/
`noOverlap`/`entityLive`); `invariant.zig` (`Invariant` + `invariantOracle` wrapping the unchanged `oracle.invariant`
+ `firstViolation` delegating to `firstTickWhere`); `defect.zig` (the additive `.temporal` `Kind`/`Detail` arm in
`vopr/oracle.zig` + `violationToDefect`); `check.zig` (`checkAll` under `if (std.debug.runtime_safety)`); `trace.zig`
(the O(T) projected-scalar `Trace` + optional Recorder-rerun log + the `run.hashes` cross-check); `temporal.zig` (the
seven combinator folds + `temporalOracle`); `metric.zig` (`Metric`/`Aggregate`/`measureRun`/`aggregate` integer-only +
optional `metricBound`); `relations.zig` (the `spec` + `violation` §7 producers + 2 `CATALOG` entries); `spec.zig`
(umbrella + `oracles()` for the VOPR) + `root.zig` wiring + the optional `step.runScheduled` hook; `gate.zig` (the
cross-build gate). **Phase-6 gate:** exact-(tick,witness) catch for an invariant + both canonical temporals + a
two-entity `noOverlap`; satisfying twins clean; pinned `violation`/`spec` GKZR1 digests + a pinned metric scalar/Aggregate
across 3 modes; the **checks-on==off + Trace==run.hashes hash-invariance sub-gate**; a temporal Defect through
`sweep→minimize→provenance`; OOM-injection leak-freedom. **Deferred behind seams:** richer LTL (composite AST arm /
Phase-9 text front-end), agent-driven metrics (the `Run(R)`/`Generator` boundary — Phase 7), socket serving of the
relations (Phase 9), a stateful `SpecEngine` facade, kernel-chosen intent (never — exogenous).

### Phase 6 notes (from the Phase-6 adversarial review — 9/10 confirmed, no critical/high; all fixed)

22. **`errdefer`-on-`buildRun`-consumed-world double-free in test helpers** (MEDIUM+LOW, fixed). Five spec
    test helpers (`invariant.zig` ×2, `metric.zig` ×2, `trace.zig` `mkRun`) held an `errdefer
    w0.deinit(gpa)` that was still active when `buildRun` consumed `w0` — so a *future* failing `try`
    (e.g. an `expectEqual` mismatch or an injected OOM) would double-free the world `buildRun` already
    owns, crashing the runner and masking the real failure. The exact trap `query/gate.zig`'s `buildForks`
    documents; fixed by the same pattern (a `blk:`-scoped construction errdefer that ends before
    `buildRun`, or dropping the errdefer where the world is already cleanly constructed). Test-only, latent
    — no production/determinism impact. *(MS-1, MS-2.)*
23. **`responds` window overflow = a D2 build-mode divergence** (fixed). `t + prop.within` (both `u64`)
    overflows for a huge `within`, which TRAPS in Debug/ReleaseSafe but WRAPS in ReleaseFast — exactly the
    "determinism must not depend on safety checks" rule. Now a saturating add `t +| prop.within` (clamped
    to T anyway), build-mode-identical. *(CS-1 / zig016-1.)*
24. **Atom field→`i64` cast hardened** (fixed). `rangeI`/`noOverlap`/`fieldLE`/`scalarField` `@intCast` a
    component field to `i64`; a `u64` field with the high bit set would trap (Debug/Safe) / be UB
    (ReleaseFast) — another D2 hazard. A comptime `assertI64Field` guard now makes over-wide / non-integer
    fields a COMPILE error, so the cast is provably trap-free. *(zig016-2.)*
25. **Test/doc hardening** (fixed). The VOPR-flow gate now asserts minimization actually ran (6→5 ticks,
    not just that a defect was found); a negative `Trace.build` test perturbs a `run.hashes` entry and
    asserts `error.TraceDiverged` (proving the load-bearing cross-check fires); the `until` strong-release
    (`q` never holds) bounded-trace branch is now tested; and `precedes`'s doc is corrected to "p at OR
    THE SAME tick" (a same-tick `p` satisfies precedence — the code was right, the comment overstated).
    *(TG-1/2/3, CS-2.)*

Dismissed (1): a claim that the VOPR-flow re-anchor assertion is vacuous because the temporal fixture's
failing tick (5) doesn't move under minimization — correct observation, but the assertion is valid and the
tick-MOVING re-anchor case is already covered by the Phase-4 provenance regression on the shared
minimize/provenance machinery a temporal Defect rides unchanged.
