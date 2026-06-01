# gkz — Implementation Plan

> Companion to [SPEC.md](./SPEC.md). SPEC says **what** the kernel is; this says **how** and **in what
> order** it gets built, and records the architectural decisions made along the way. The primary user
> is an AI; every decision below favors determinism, legibility, and a tight feedback loop.

Status: **Phases 1–7 implemented; all determinism gates green; adversarial reviews passed.**
**Foundation (§1–§3/§6)** + **Systems & scheduler (§4)** + **Events & causality (§5)** + **the VOPR
(§9)** + **the §7 query surface** + **§8 specs/invariants/properties** + **§10 agent harnesses** are
complete: **693 tests** across Debug/ReleaseSafe/ReleaseFast — pinned end-to-end + per-tick-stream hashes
(cross-build bit-identity, D2), an order-permutation gate, an events-OFF==events-ON hash-invariance gate +
a pinned event-log digest, the VOPR capstone with an `OutOfMemory`-injection sweep, the §7 query surface
with 8 pinned cross-build GKZR1 digests + a SCRAMBLE invariance sub-gate, the §8 spec layer (state
invariants + seven closed temporal combinators + integer intent-metrics) with exact-(tick,witness)
catches + pinned violation/spec/metric digests, and the §10 agent harness — an agent is an external
nondeterministic source CAPTURED at the Input boundary (never re-invoked on replay), with the capstone
proving a genuinely irreproducible agent's captured run replays bit-identically across all 3 modes (and
is then VOPR-minimizable). Commits: Phase 1 `a589d39`, Phase 2 `37748cf`, Phase 3 `1a33f29`, Phase 4
`9be50c3`, Phase 5 `0540f86`, Phase 6 `e6e6f00`; Phase 7 lands in this commit (adversarial review 8/10
confirmed, never-re-invoke held — one HIGH fixed: the player-not-world boundary is now type-enforced
(`Table.column` requires `*Self`; `owners`/`masks` return `[]const`), closing a `*const`-World mutable-
slice leak the (d) gate had only tautologically tested).
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
    Includes the deliberate-overflow (`addSat`) divergence test. *(Implemented. The cross-ARCHITECTURE
    axis — formerly "a big-endian qemu row remains future work" — is now the `zig build cross` gate: every
    pin re-checked under qemu on aarch64/s390x/arm/mips, the full {32,64}-bit × {LE,BE} matrix. See §14.)*

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
| **7. Agent harnesses & evaluation** ✅ | §10 | `Agent` = a thin newtype over `Generator(R)` + a `DeterminismClass`; an agent is an EXTERNAL source CAPTURED at the Input boundary (`buildRun`→`Run.inputs`), NEVER re-invoked on replay (`asAgent`/`scriptedGen` the only replay primitives — structural); `observe(State)->Input` via a read-only `ObsView` (the §7 query lens; player-not-world); reference deterministic policies (scripted/greedy, rng-keyed); the `ExternalAgent` fn-ptr seam (NN/LLM, root withheld); mass eval = reproducible sweep (deterministic) vs capture-to-revisit (`.external`) reusing §6 `aggregate`/§4 `sweep`; the §13 sharding math (`shardRanges`/`mergeAggregates`). NN inference is the *player*, not the *world*. | reuses Input channel; **S7** sharding math |
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

---

## 10. Phase 7 design — §10 agent harnesses & evaluation (decision of record, from the design judge-panel)

5-architect / 5-lens judge panel + synthesis, with the **harness contract refinement as a HARD constraint** (not
relitigated): a learned agent's inference is bit-irreproducible (INT8 tensor-core / GPU reduction order), so an agent
is an **external nondeterministic source captured at the Input boundary, like a human** — reproducibility comes from
recording the emitted `Input`s, never from reproducing the agent, and replay/VOPR **never re-invoke** it. **Spine =
"Minimalist-Generator-extension"** (scope_realism winner=90; top-3 on determinism/spec): an `Agent(R)` is a thin
newtype over the EXISTING `Generator(R)` carrying a `DeterminismClass` tag — capture is `buildRun`, replay is
`scriptedGen(Run.inputs)`, mass-eval is Phase-6 `aggregate` / Phase-4 `sweep` called verbatim. **Three grafts:** (1)
from External-seam (determinism + forward_compat winner) — make never-re-invoke **structural**: the only replay
primitive is `scriptedGen` over `Run.inputs` and NO signature in `src/agent/` couples a Run to a policy ctx, plus the
two-sided capstone (the source provably diverges on two direct calls AND an infer-call counter must NOT advance during
replay); (2) from Observation-as-Query (ai_ergonomics winner; primary user is an AI) — `ObsView.engine()` makes the §7
query `Engine` the first-class observation lens, so the policy's observation vocabulary IS the `term.Value` surface the
AI debugs with (over a borrowed `*const World` + a const `EMPTY_LOG`, so observation never depends on the recorder —
preserving events-off==events-on); (3) from Sweep-First (forward_compat graft) — ship the §13 sharding **math only**
(`shardRanges` + an associative `mergeAggregates`, mean deferred), gate-proven so a future sharded sweep equals a
single-process one field-for-field. **Rejected:** the typed Pure/External two-harness split (Contract-first, the
determinism/spec winner) as spine — it forces two concrete harness facades that fragment every future consumer
(ai_ergonomics=64, forward_compat=58); its strongest idea (deterministic policies RECEIVE `root` and key randomness
through `rng.draw`; external never receives `root`) is kept as **value-level discipline** on the spine. Also rejected:
a `RunCard` artifact and out-of-process transport (the Run IS the revisit record; IPC is Phase 9).

**Determinism classes** (`enum{ deterministic_blind, deterministic_observing, external, replay }`, constructor-fixed):
`isReproducible` = all but `.external`. Deterministic policies are pure in (seed,tick,view) → re-derivable, bit-
reproducible sweeps; `.external` → run-level nondeterminism, captured once per seed (the `Run` is the artifact), valid
for statistical metrics. **player-not-world** is enforced three ways: `ObsView` holds only `*const World` (a write is a
compile error), the only egress is `?Input` through the normal `step` channel, and a comptime `@hasField` negative-
surface test.

**Modules (`src/agent/`), build order:** `observe.zig` (`ObsView` + §7 `engine()` lens + `world()`); `agent.zig`
(`DeterminismClass`/`Agent` newtype + `asAgent`/`replayGen` — the structural never-re-invoke convertors);
`policy.zig` (`Policy = observe(State)->Input` + `policyGen`); `reference.zig` (`scriptedAgent` + `greedyAgent` keyed
through `rng.draw`); `external.zig` (the `ExternalAgent` fn-ptr seam; root withheld); `eval.zig` (`aggregateAgent`/
`sweepAgent` — reproducible→`aggregate`/`sweep` verbatim, `.external`→capture-once record-to-revisit `[]Run`);
`shard.zig` (`shardRanges` + `mergeAggregates`); `agent.zig` umbrella + `root.zig` wiring; `gate.zig`. **Phase-7 gate:**
(a) a deterministic greedy sweep is bit-reproducible (pinned `GREEDY_SWEEP_SUM` + per-seed `streamDigest`, identical on
a second run + across 3 modes); **(b) the capstone** — an impure `ExternalAgent` provably diverges on two direct
`buildRun`s, then its captured Run replays bit-identically (hashes + `streamDigest` + final) across 3 modes WITHOUT
advancing the invoked-counter; (c) the captured run rides `sweepAgent→minimize→provenance` (debuggable); (d) ObsView
read-only (`@hasField` + per-tick digest-invariance); (e) intent-metrics aggregate over agent runs; (f) shard-merge
equals single-process; (g) OOM-injection. **Deferred behind seams:** the actual NN/LLM/RL engine + GPU/INT8 (the
`ExternalAgent.infer_fn` boundary), the process model + socket transport + shard EXECUTION (Phase 9; `shardRanges`/
`mergeAggregates` + the §7 wire codec are the seams), training loops, search/MCTS policies, a feature-projection DSL,
a recording-harness observation variant — each with a concrete already-verified seam.

### Phase 7 notes (from the Phase-7 adversarial review — 8/10 confirmed, never-re-invoke held; one HIGH fixed)

26. **Player-not-world made type-enforced** (HIGH, fixed). The boundary was NOT actually structural:
    `Table.owners()/masks()/column()` were declared `*const Self` but returned MUTABLE slices (a
    `MultiArrayList.items` quirk — it copies the list by value and does not propagate receiver constness),
    so a policy could reach `ov.world().table.column(0)[0] = …` and corrupt hashed sim state with NO
    `@constCast` — and the (d) gate was a tautology that only exercised `rowCount()`/`engine()`, never the
    write path. Fixed in `storage.zig`: `column` now requires `*Self` (so `*const World.table.column(…)`
    is a COMPILE ERROR), `owners`/`masks` return `[]const`, and `columnConst`/`masksMut` split the read vs
    write paths (every read caller — serialize/hash/query/spec — uses the const variants; the §1 pinned
    digests are unchanged since the bytes are identical). `observe.zig` documents the irreducible Zig
    residual honestly (a policy reaching PAST the accessor API into the raw `rows.items`/`generation.items`
    backing is misuse outside the contract — the determinism guarantee rests on CAPTURE, not policy
    good-behavior; an out-of-band mutation would make the captured run un-replayable, a detectable
    violation). The (d) gate now asserts the const return types (a real test that would have failed
    before). *(PNW-1, TG-1.)*
27. **Test/gate + doc hardening** (fixed). The (c) gate now asserts STRICT minimization (`min.inputs.len <
    cap.inputs.len`), not `<=`; the (g) OOM-injection now covers the `.external` `aggregateAgent` branch
    (the accumulating-`[]Run` errdefer path), not only the reproducible path; the capstone GUARD documents
    why 5 ticks is coprime to the agent's `%3` counter period (a multiple-of-3 tick count would make the
    irreproducibility guard a false pass); a `policyGen` `view == null` fallback test was added; and
    `asAgent`/`replayGen` now document that BOTH `run` and `spec` must outlive the Agent. *(TG-2/3/4/5,
    MS-1, NR-2.)*

Dismissed (2): NR-1 (sweepAgent "re-invokes" an `.external` agent) — false positive: it misframes a
forward FUZZ (each seed = a fresh captured playthrough, then minimize operates on the captured inputs via
`scriptedGen`) as a forbidden REPLAY; the never-re-invoke contract holds. SF-1 (sweepAgent does not
route on `DeterminismClass`) — intentional: sweeping a `.external` agent is the valid fuzz-N-playthroughs
mode; debugging a SPECIFIC captured run uses `asAgent(run)` (`.replay`), and minimize/provenance never
re-invoke either way.

---

## 11. Phase 8 design — §12 hot-reload & migration (decision of record, from the design judge-panel)

5-architect / 5-lens judge panel + synthesis. **Spine = the schema-agnostic record substrate** (migration) +
**run-a-different-comptime-`systems`-slice** (hot-reload) — the determinism-cleanest, most scope-realistic pairing
(determinism 92, scope_realism 86, spec_fidelity 88; the dominant winner). A migration NEVER instantiates an old
`Registry` type: it decodes any serialize image into a schema-agnostic `Image` (per-row `(entity, mask, [{kind_id, raw
value-bytes}])` records), driven by the image's OWN per-Kind fingerprint — `serialize.writeWorld` already emits a
`{kind_id:u16, size:u32}` per-Kind fingerprint (lines 187-191), and that `size` column is exactly each component's
byte width, so `decode` splits an unknown row BLINDLY by mask-bit rank with zero comptime type knowledge. Migrated
output is canonically serializable BY CONSTRUCTION (only whole canonical-LE slices move; D5/D7 fall out), terminating
in the existing `readWorld`/`SchemaMismatch`. **Grafts:** (1) `validateMigration` (from the declarative designs) — a
pre-apply structural check that the declared ops EXACTLY cover the per-Kind fingerprint delta (`MigrationIncomplete`/
`MigrationSpurious`/`BadDefaultWidth`), turning "the ops happen to produce a conformant image" into "the ops are the
proven complete, non-spurious reconciliation BEFORE any byte moves" — the §12 "declared" discipline. (2) A SEPARATE
pinned raw-image XXH64 (`MIGRATED_IMAGE_BYTES`) alongside the migrated-World digest — catches a non-canonical encode
that happens to World-hash-collide (the spine's top risk). (3) The §7-catalog surfacing of migrations
(`migration/3`+`migration_op/4`) as an OPTIONAL adapter (the ai_ergonomics winner's idea, kept off the determinism
core + out of the gate). **Rejected:** typed versioned registries (keeps every `R_vN` forever; can't decode a snapshot
whose types were deleted — fails the live-evolution mandate; ai_ergonomics-fatal); a runtime invoke table read by a
new `stepTable` (puts runtime indirection on the determinism-critical step path to optimize the LESS-load-bearing
pillar); runtime `exec_order` recompute at swap (a greedy-first-fit drift hazard — with comptime `systems` the order
is already correct).

**Migration model:** `Migration{from_version, to_version, ops: []const Op, target_fingerprint}` where `Op =
union{identity, drop_kind, add_kind{kind_id, default_bytes}, rename_kind{from,to}, transform_kind{kind_id, new_size,
rewrite: fn([]const u8, *FieldBuilder)}}` (the §12 add-field→default / remove→drop / rename→map vocabulary; transforms
speak a `FieldBuilder` leaf vocabulary, never raw byte math — structurally float/pointer-free). Dispatch on
`schema_version` first, per-Kind fingerprint second. `Chain{migrations}` folds left-to-right with a
`from_version==running` gate (a gap is `SchemaMismatch`). **Hot-reload:** `SystemSet(R)` wraps a comptime `[]const
Sys(R)`; `reloadAt` is a World NO-OP returning the next set (running a different comptime slice on the same World at a
tick boundary — `step`/`runScheduled` already take comptime `systems` + the World owns zero fn-pointers, so this adds
ZERO step-path code); `SystemSource(R){loadFn,unloadFn}` with an `inProcessSource` impl built+tested and a
`NativeLibSource` typed `error.NotImplemented` stub. Reload-to-same is a HARD bit-identity gate (`captureStream` +
`streamDigest` equality); a diverging reloaded set is caught by `oracle.divergence` (the kernel DETECTS a bad reload —
it cannot prove opaque native code deterministic, §15 trusts the author).

**Modules (`src/migrate/` + `src/reload.zig`), build order:** `image.zig` (decode/encode = the record-layer inverse
of serialize; **prove the identity round-trip first**); `fingerprint.zig` (extract/compare + `requireMatch`→
`SchemaMismatch`); `ops.zig` (the Op union + `FieldBuilder`/`FieldReader`); `migrate.zig` (`validateMigration` then
`apply` then `Chain`/`migrateBytes`/`migrateSnapshot`); `reload.zig` (`SystemSet`/`reloadAt`/`SystemSource`); `gate.zig`
(pinned `PINNED_V1` blob + `EXPECTED_V2/V3_HASH` + `MIGRATED_IMAGE_BYTES`); `root.zig` wiring; `catalog.zig` (optional,
last). **Phase-8 gate:** migrated-v1 == native-v2 (digest AND a separately native-built v2 + the raw-image XXH64),
chain==direct==native-v3, fingerprint dispatch + `validateMigration` rejection (incomplete/spurious/bad-width/identity),
purity (migrate twice == same bytes), reload bit-identity + a diverging reload caught by the VOPR, OOM-injection — all
pinned across the 3-mode matrix. **Deferred behind seams:** the real `dlopen` loader + shared-object build rule
(`SystemSource.loadFn`; `NativeLibSource` stub), the Phase-9 control plane triggering reloads/migrations, allocator/rng
+ cross-entity + filtered-add migrations (a future Op arm on the same union), EventLog/relation-schema migration.

### Phase 8 review notes (adversarial judge-panel: 5 dimensions → adversarial verify → triage)

5 reviewers (determinism/memory, hostile-input, migration-correctness, spec-fidelity, Zig-idiom); every raw
finding was adversarially re-checked against the code before reaching triage. **8 confirmed/partial, 0
survived as false positives.** Fixes applied:
- **[MEDIUM] `image.encode` shared-kind width guard** — encode trusted that each cell's bytes matched
  `R_target`'s width; a shared `kind_id` with a mismatched width (e.g. encoding into the wrong `R_target`)
  silently produced a corrupt stream. Added a comptime-driven guard at the top of `encode`: for every kind
  `R_target` expects that the image also carries, the canonical widths must agree else `SchemaMismatch`.
  Missing/extra kinds remain fine (dropped / bit unset), so the legitimate "encode into a different schema"
  path is unaffected. Makes "canonical by construction" total. Covered by a new test.
- **[LOW] `validateMigration` per-op independence documented** — validate checks each op against
  `(old_fp, target)` independently while `apply` folds sequentially, so a rename-then-resize of the SAME kind
  inside one `Migration` is (correctly, safely) over-rejected; it must be split across `Chain` links. validate
  only ever over-rejects, never wrongly accepts. Documented on `validateMigration` + the constraint.
- **[LOW] gate second pin made genuinely independent** — `MIGRATED_IMAGE_BYTES` (XXH64 of the bytes) was
  tautological with `EXPECTED_V2_HASH` (the World digest IS the XXH64 of the canonical bytes — the D5
  guarantee). Replaced with `MIGRATED_IMAGE_CRC32` (a separate hash FAMILY), so a non-canonical encode that
  XXH64-collided would still be caught; the byte-identity assertion remains the primary canonicality proof.
- **[LOW/NITs] gate (e) now exercises the reload SURFACE** — obtains the post-swap set via
  `reloadAt` + `inProcessSource(...).load()` (asserting it wraps the comptime slice), adds a reload-to-DIFFERENT
  case (`reload_a`→`reload_b`) caught by `oracle.firstDivergentTick` with an identical pre-swap prefix, and
  removed the unused `Op` alias. The previously-unused `reload_b`/`bumpD2`/`oracle` are now load-bearing.
- **[NIT] hostile-input** — the bounded (input-proportional, ~constant-factor) all-size-0 cell amplification
  in `decode` is within the validate-before-alloc contract (size-0 is legitimate for field-less tags); noted
  in a comment, no functional change. decode still never panics and never pre-allocs on an unjustified count.

**Deferred (deliberate):** the optional §7 `migration/3` + `migration_op/4` catalog adapter — implementing it
would force re-pinning Phase-5 `QUERY_SCHEMA_DIGEST`/`QUERY_COLUMN_DIGEST` for a non-determinism-bearing
feature, coupling Phase 8 to Phase 5's gate. Migrations are already inspectable as data (`Migration{name, ops,
target_fingerprint}`); the adapter plugs in later behind the existing `RelId`/`CATALOG` seam.

Gate: **822 tests green across Debug/ReleaseSafe/ReleaseFast** (274/mode + the skipped pin-recompute dump).

### Phase 8 addendum — REAL dlopen native systems (delivering the named §12 deliverable, not a stub)

The first Phase-8 pass shipped migration in full but reduced "hot-reload" to a comptime system-set swap and
left `NativeLibSource` an `error.NotImplemented` stub — a punt on the roadmap's named "`dlopen` native
systems." This addendum delivers the real thing, validated by a design judge-panel and an adversarial review.

**The architecture problem & resolution.** `step`/`Schedule` take `comptime systems` (the only comptime
dependency is the fixed-size `[systems.len]CommandBuffer` stack array). A `dlopen`'d `.so` yields RUNTIME
fn-pointers. So the kernel grew a runtime-systems path COEXISTING with the comptime one (zero change to the
comptime path or its gate): `schedule.stagesDynamic`/`execOrderDynamic` (runtime twins of the comptime
stage/exec derivation — gated to produce the IDENTICAL permutation) and `step.runScheduledDynamic`/
`stepDynamic` (heap-allocate the command-buffer array; gated bit-identical to `stepExec` over a comptime
set). `Sys(R)` was already a runtime struct (fn-ptr + access mask), so it crosses the boundary unchanged.

**The loader & ABI.** `reload.Descriptor(R) = extern struct { count: usize, systems: [*]const Sys(R) }`,
handed across by pointer via `export fn gkz_systems() callconv(.c) *const Descriptor`. By-POINTER (not
by-value, not raw-fnptr-rebuild) because the host can't re-derive a system's access mask at runtime (it's
reflected off the comptime `Query` type) — the `.so` already holds the fully-built `Sys` with the correct
mask + thunk, and by-pointer keeps the descriptor `.so`-resident (lifetime = `[load .. unload)`).
`NativeLibSource(R)` is a real `std.DynLib` loader (`open` → `lookup(GetFn, "gkz_systems")` →
`desc.systems[0..count]`); `unload` closes. Soundness rests on host and `.so` sharing the IDENTICAL `gkz`
module + registry `R` (`reload_example/shared.zig` is the single `R` for both sides) so `Sys/Table/SimCtx/
World` layouts match (mode-independent for a fixed target). Caller contract (can't be enforced across the
opaque boundary, §15): finish every `stepDynamic` over a set BEFORE `unload`, swap only at a tick boundary.

**Two real bring-up bugs (both load-bearing, neither in any proposal):** (1) a libc-linked Zig dynamic lib
defaults to **static-PIE** — its statically-linked-libc TLS segment is never wired into the host thread
descriptor, so the first TLS access inside the `.so` (a ReleaseSafe stack-guard at `q.next()`) faults at
`0x0`, while the outer descriptor relocates fine so it *looks* loaded. Fix: `lib.pie = false` → a normal
`DT_NEEDED libc.so.6` dynamic ELF the OS loader relocates + shares host TLS (`link_libc` is necessary but
NOT sufficient). (2) A host-mode × `.so`-mode ABI-call mismatch SEGV'd ReleaseSafe/Fast when the `.so` was
built once in Debug. Fix: build the `.so`s PER MODE (host-mode == `.so`-mode) — which also STRENGTHENS the
gate (each mode dlopens a `.so` compiled in its own mode, re-proving cross-mode determinism of the native
internals, not just detecting it).

**build.zig.** Per mode: two `addLibrary(.{.linkage=.dynamic, .link_libc=true})` + `lib.pie=false`, paths
injected into the gate via `b.addOptions().addOptionPath(getEmittedBin())` (auto build-graph dependency), and
`reload_gate.zig` run as a SEPARATE per-mode test artifact (so the base 275-test suite takes no dependency on
the example `.so` paths).

**The honesty gate (`reload_gate.zig`, empirically verified non-rubber-stamp).** (g) the dlopen'd `.so`'s
per-tick stream `expectEqualSlices` the in-tree reference logic's stream + a pinned `REF_STREAM_DIGEST`
across all 3 modes — **proven honest**: tampering `lib_move.zig` to `x += dx + 1` makes (g) fail at exactly
that assertion (the `.so` rebuilds on source change; no stale-cache false-pass). (h) hot-swapping to a
DIFFERENT `.so` (move → move-2x) diverges at EXACTLY the swap tick, caught by the divergence primitive, with
an identical pre-swap prefix — a single in-process substitute cannot satisfy both (g) and (h). (i)
reload-to-same `.so` twice is bit-identical and `dlopen`/`close` is host-leak-free. **Deferred behind the
`SystemSource` seam:** a `gkz_abi_version` negotiation symbol, the file-watcher/control-plane reload TRIGGER
(Phase 9), recompile-from-edited-source, Windows/macOS validation (wiring is portable via `getEmittedBin`),
and reload across a CHANGED registry (that crosses into the migration layer). A seccomp/hermetic runner that
forbids `dlopen` fails the reload-gate honestly (the base suite is a separate, unaffected artifact).

Gate: **837 tests green** (275 base + 4 reload-gate per Debug/ReleaseSafe/ReleaseFast).

---

## 12. Phase 9 design — §13 process model & control plane (decision of record, from the design judge-panel)

4-architect / 4-lens judge panel + synthesis. **Spine = an `Executor(R)` transport seam** (modeled verbatim on Phase-8's
`reload.SystemSource{ctx, vtable}`) with TEMP-FILE job delivery via `std.process.run` and a supervisor that merges by shard
index. New namespace `src/proc/` (keeps clear of `src/migrate/`). Mirrors the Phase-8 dlopen pattern exactly: an **always-gateable
in-process** impl + a **real-subprocess** impl behind a Linux/capability guard, with a cross-process determinism witness that
can't be faked.

**Worker / job model (`proc/job.zig`):** a `Job = union{ sweep_shard{range: ShardRange, max_ticks, oracle_set_id:u16,
metric_id:u16}, fork{snapshot_bytes, base_tick, base_hash, diverged_inputs, tick_budget} }` and a `Result = union{ aggregate:
metric.Aggregate(T) (+ optional harvested defect coords), final{snapshot_bytes, stream_digest} }` — serializable VALUES via a
GKZJ1/GKZK1 codec (5-byte magic + u16 version + arm tag, reusing `serialize.putInt`/`writeValue` + the snapshot/Aggregate/input
codecs; hostile bytes → `serialize.Error`, never panic). **R is never serialized** — R is CODE (systems/oracles/seed_world), so
it is comptime-FIXED per worker build via a shared module (`proc/worker_example/shared.zig`, the `reload_example/shared.zig`
pattern); the job carries only DATA + `u16` selector ids into R-fixed comptime tables. Build the worker exe in the SAME optimize
mode as the gate (host-mode == worker-mode ABI discipline).

**Transport (`proc/executor.zig`):** `Executor(R){ctx, runFn}` → `Outcome = union{ ok, crashed: Crash{term, repro_job}, spawn_failed}`.
(a) `inProcessExecutor` decodes the job and runs `vopr.sweep`/`metric.aggregate`/`restore+step` INLINE — the determinism floor,
always gateable. (b) `subprocessExecutor` writes the job to a TEMP FILE and runs `std.process.run(gpa, io, .{argv={exe,"worker",
job_path}, .timeout=.{.duration=std.Io.Duration.fromMilliseconds(N)}})` — the ONLY spawn+collect path that carries a timeout
(`Child.wait` has none) and forces `.stdin=.ignore` (so temp-file delivery, not a stdin pipe, avoids deadlock and bounds every job
size). Harvest on `Child.Term`: `.exited==0`→parse `[u32 len][GKZK1]` from stdout; `.signal`/nonzero→`crashed{repro_job=job
bytes}` (a SIGSEGV surfaces here, NOT a parent crash — the one-process-per-sim isolation); `error.Timeout`→`crashed{.timed_out}`
(run's internal `defer child.kill` already reaped); `SpawnError`→`spawn_failed` (the sandbox-deny path → gate `SkipZigTest`).

**Supervisor (`proc/supervisor.zig`):** a process pool (no globals; explicit gpa+io+Executor+n_workers+max_restarts). PLAN
shards via `shardRanges`; DISPATCH through an n_worker slot pool into an INDEX-ADDRESSED `results[shard_i]` (never append-on-
arrival); RESTART-on-crash records `Defect{shard_i, range, term, repro_job}` (a re-runnable repro, §9) up to `max_restarts`;
HARVEST merges in CANONICAL shard-index order via `mergeAggregates`, defects sorted by (shard_i, seed, tick). The §4 "physical
scheduling nondeterministic, results never are" principle lifted to PROCESSES: arrival order never leaks into the bytes; the
merged Aggregate is bit-identical to the unsharded single-process sweep.

**Query server (`proc/qserver.zig`):** the IO shell around the ALREADY-PURE `query/wire.respond()` (unchanged — wire.zig:6-7
anticipates exactly this). A `SimRegistry` (`AutoHashMap(u32,*SimHandle)`, `SimHandle{world:*const World, log:*const EventLog}` —
Engine borrows `*const`, D1 preserved); routes `[u32 len][u32 sim_id][GKZQ1]` → `Engine(R,systems).init` → `respond` →
`[len][GKZR1]`. Transport mirrors the Executor seam: in-process channel (gate path, everywhere) + a Linux-gated
`std.Io.net.UnixAddress` Unix-domain socket at a temp path (no TCP port flakiness).

**Gate (`proc/proc_gate.zig`, Linux-guarded per-mode artifact):** example sim = the verbatim `eval.zig` demo (R=Registry{Health},
`drain` hp-=1, `seedHp(seed)=2+seed`, `timeToCondition(0)`; seeds 0..3 over max_ticks=4 → time-to-dead 2,3,4 → Aggregate.sum=9, a
known in-tree number). Pins `AGG_DIGEST:u64` across 3 modes and asserts: (a) **direct == in-process == subprocess** GKZK1 bytes
(the headline cross-PROCESS witness, analog of Phase-8 `REF_STREAM_DIGEST`); (b) 3-shard real-worker merge == unsharded ==
direct, AND a REVERSE-order `mergeAggregates` gives the identical pin (order-independence); (c) a `--crash` worker is harvested as
`Defect` with `term .signal` and `repro_job` == the dispatched job, parent survives, other shards' merge unaffected, AND a
`--hang` worker hits `error.Timeout` and is killed+reaped; (d) qserver GKZR1 bytes == `respond()` called directly. **Honesty is
STRUCTURAL** (the Phase-8 lesson): a disguised in-process gate CANNOT produce a real `Term.signal` (an in-process `@panic` aborts
the gate's own test binary) or a real kill-on-timeout, and B_sub must come from a child's stdout whose exe path was injected via
`getEmittedBin`. `SpawnError`→`SkipZigTest` (honest, never a silent in-process fallback). **build.zig** adds (Linux-guarded, per
mode) a `gkz_worker_{mode}` exe with `addOptionPath("worker_exe_path", getEmittedBin())` + a `proc-gate-{mode}` test artifact
(`has_side_effects=true`); NO `link_libc`/`pie=false` needed (std.process spawn, unlike dlopen, needs neither). The in-process
Executor/QueryTransport equality tests live in the BASE suite and run everywhere.

**Module build order:** `job.zig` → `worker_example/shared.zig` → `executor.zig` → `worker_main.zig` (+ a `worker` subcommand in
`main.zig`) → `supervisor.zig` → `qserver.zig` → `proc_gate.zig` → build.zig wiring → root.zig exports. **Deferred behind the
seam:** multi-MACHINE distribution (a `NetworkExecutor` shipping the same frames), parallel `Io.async` dispatch (merge-by-index
makes it a drop-in), the `.fork` arm proven end-to-end through the subprocess gate (codec+transport support it; only `sweep_shard`
is pinned cross-process), a real network protocol + auth/TLS, restart backoff/health policy, a persistent long-lived worker pool,
the higher-level AI control-plane verbs + the reload/migrate TRIGGER (reload.zig:21-24), stdin-pipe job delivery, and Windows/macOS
validation.

### Phase 9 review notes (adversarial judge-panel: 5 dimensions → adversarial verify → triage)

5 reviewers (process-lifecycle, determinism-honesty, codec-hostile, memory-ownership, zig-idiom-build); every
finding adversarially re-checked against the code. **14 confirmed/partial, 0 false positives.** Fixes:
- **[MEDIUM] crash-isolation gap (supervisor.zig):** a worker that exited 0 with a length-valid but
  MALFORMED GKZK1 body (a version/R-mismatched exe, a `.final` for a sweep, a garbage payload) propagated a
  `serialize.Error` straight out of `runJobs`, aborting the WHOLE sweep — violating §13 isolation. Fixed:
  the `.ok` arm now routes a decode failure / wrong-arm result through the SAME restart/defect path as a
  crash (a new `ChildTerm.bad_result`); one bad worker becomes a per-shard `Defect=repro` and its siblings
  still merge. Covered by a new unit test (a mock executor returning `.ok` + garbage → two defects, empty
  merge, no abort).
- **[MEDIUM] honesty false-skip (executor.zig):** the subprocess `run()` catch mapped EVERY non-Timeout/OOM
  error to `.spawn_failed` → the gate `SkipZigTest`s. So a BROKEN/missing worker-exe path (`FileNotFound`,
  `InvalidExe`) or a mid-stream read error would SILENTLY skip the entire real cross-process gate, hiding a
  dead gate. Fixed: only genuine spawn-denial/resource-exhaustion (`AccessDenied`/`PermissionDenied`/
  `OperationUnsupported`/`SystemResources`/fd-quota) → `.spawn_failed`; `StreamTooLong` (runaway worker) →
  `.crashed`; everything else → `error.WorkerProtocol` (a HARD failure, never a silent skip).
- **[MEDIUM] dead/broken code (qserver.zig):** `serveUnixOnce` used non-existent reader/writer APIs and
  would not compile if instantiated (it never was, so it slipped through). Deleted it — the socket
  accept-loop is now an honestly-documented deferred control-plane seam; the gate still proves the Unix
  socket binds+connects and that `handle()` (the multiplexing substance) matches `respond()` byte-for-byte.
- **[LOW] codec hardening (job.zig):** encode-side `@intCast(len)` to `u32` could panic (safe) / truncate
  (ReleaseFast) on a >4 GiB section — a D2 hazard; now guarded with an explicit `u32Len` check →
  `error.Corrupt`. `decodeJob`/`decodeResult` now reject trailing garbage after a valid frame
  (`r.pos != bytes.len` → `Corrupt`).
- **[LOW] partial-file leak (executor.zig):** `writeJobFile` now has an `errdefer deleteFile` so a failed
  write/flush leaves no orphaned temp file.
- **[LOW/NIT] gate + hygiene:** the crash sub-gate now asserts a REAL `.signal` (not `.signal or .exited`,
  which weakened the SIGABRT-isolation proof an in-process @panic could never produce); the (b) docstring no
  longer claims a reverse-order merge it doesn't run (that's proven in the supervisor unit test); a
  `n_workers >= 1` assert; a redundant no-op `catch` simplified to `try`.

**Left as-is (justified):** the worker decodes a (≈20-byte) job twice (poison check + `runJobBytes`) — a
negligible micro-cost not worth coupling the shared dispatcher to a pre-decoded job; the per-ctx `seq`
job-file naming is collision-free for the sequential MVP (a future parallel `Io.async` dispatch would need
an atomic counter — documented).

Gate: **891 tests green** (289 base + 4 reload-gate + 4 proc-gate per Debug/ReleaseSafe/ReleaseFast).

### Phase 9 — closing the §13 deferrals (socket server, fork execution, parallel dispatch)

The first Phase-9 pass delivered the core but deferred three things that are NAMED/implied §13 deliverables
and testable on one machine — a punt dressed as "behind a seam." All three are now built and gated (no
"deferred" category for SPEC clauses; a clause is met or it is a §14/§15 non-goal):
- **Query server OVER A SOCKET** (§13): `qserver.serveUnix` is a real `std.Io.net` Unix-domain accept loop
  framing `[u32 len][sim_id][GKZQ1]`→`[u32 len][GKZR1]` over `handle`. Gate (d) runs it in an `Io.Group`
  with a real client and asserts the socket reply equals `respond()` byte-for-byte (not a bind-only smoke).
- **Fork execution** (§13 "forks from a snapshot + a diverged input stream"): `executor.runJobBytes`'s
  `.fork` arm restores the base World from the snapshot bytes (`readWorld`→`fromParts`), replays the
  diverged input stream for `tick_budget` ticks via `captureStream`, and returns the final snapshot +
  per-tick stream digest. Gate (e): in-process == subprocess final bytes, pinned `FORK_STREAM_DIGEST`, and
  the restored final World shows the fork actually advanced (hp 2→0).
- **Parallel dispatch across cores** (§13 throughput): `Supervisor.runJobs` dispatches shards concurrently
  via `Io.Group` when `io != null and n_workers > 1` — each shard task writes its own index-addressed slot
  (no shared-state race; the executor's job-file `seq` is now `@atomicRmw`), and the merged result is
  assembled post-join in canonical shard-index order. Gate (b) runs 3 real worker processes concurrently
  and asserts the merged Aggregate equals the sequential run; a supervisor unit test proves parallel ==
  sequential in-process too (so the parallel path is gated even where spawn is denied).

Proven feasible before building (no more API-excuse punts): an 8-way concurrent `Io.Group` subprocess spawn
and a Unix-socket round-trip both pass in this sandbox.

**The one genuine edge left:** distributing workers to OTHER machines (a `NetworkExecutor` reaching a remote
worker daemon over TCP). It is the SAME GKZJ1/GKZK1 frames over the same socket transport the query server
already proves — but a true cross-HOST gate needs a second machine, which isn't available here (localhost
TCP would be a faithful proxy). §13's concrete bullets — one-process-per-sim, supervisor + forks, query
server over a socket, across-cores throughput — are all met and gated.

Gate: **897 tests green** (290 base + 4 reload-gate + 5 proc-gate per Debug/ReleaseSafe/ReleaseFast).

### Phase 9 — proving the parallelism is REAL (not a serialized "parallel" path)

A sharp review question: are the subprocesses *actually* parallel, or did the gate just assert
parallel-result == sequential-result (which a sequential impl passes too)? The latter — so the "parallel"
claim was unproven. Closed it: gate (f) dispatches N=4 worker processes that each sleep ~150ms then compute,
and measures wall-clock for PARALLEL (`Io.Group`, `n_workers=N`) vs SEQUENTIAL (`n_workers=1`) dispatch over
the SAME jobs. Measured (32-core host): parallel ≈ 160ms, sequential ≈ 640ms — a ~4× speedup, i.e. genuine
overlap. The gate asserts `parallel < sequential × 0.6` (a ~2× margin); because the workers SLEEP (not
CPU-bound), this proves the DISPATCH overlaps the spawns regardless of core count, and fails only if the
dispatch actually serializes. Empirically confirmed first via a standalone probe (4 × `sleep 0.25` in 282ms,
not 1000ms). So separate OS processes are the real (and, for a no-shared-mutable-state determinism kernel,
the principled) parallelism — and the overlap is now gated, not assumed. (`std.debug.print` corrupts the
`--listen` test-runner protocol — the timing is asserted, not printed, in the gate.)

Gate: **900 tests green** (290 base + 4 reload-gate + 6 proc-gate per Debug/ReleaseSafe/ReleaseFast).

## 13. Phase 2b design — real in-process multithreaded scheduler execution (decision of record, from the design judge-panel)

4-architect / 4-lens judge panel + synthesis. **Base = `determinism-purist`** (Judge#3's pick; tied-best determinism rigor and the only design honest about the arena/gpa boundary) **grafted with `throughput-first`'s eager-inline-degrade defusal** (Judge#1 and Judge#2's decisive separator). Phase 9 shipped cross-*process* parallelism; this is different — **threads inside one process** running a stage's conflict-free systems against shared sim state, with the per-tick hash stream and (recording-on) event log staying **bit-/byte-identical** to the single-threaded spine. The spine (`step.zig`) is the canonical referent and is barely touched; the threaded twin lives in a new file.

### 13.1 Concurrency model, API, files touched

**New file `src/step_par.zig`** (additive; mirrors the Phase-8 `reload.zig` / Phase-9 `proc/` "twin in its own file" precedent). The **only** edit to `step.zig` is a behavior-preserving extraction of the drain (see §13.3) so the `(system_id, seq)` comparator can never drift between the serial and parallel paths.

**New public API** (full Zig signatures):

```zig
// src/step_par.zig
pub const ParError = std.mem.Allocator.Error; // no new error set; Group task faults captured via slots

/// Parallel twin of step.runScheduled. Runs each stage's systems across an Io.Group, barrier
/// (group.await) between stages, then the SAME end-of-tick (system_id,seq) drain. Bit-identical
/// per-tick result + (rec!=null) byte-identical merged log vs runScheduled.
/// io==null OR n_threads<=1 OR systems.len<2-stages  ==>  delegates VERBATIM to step.runScheduled
/// (caller gpa, NO arenas) — so the bit-identity gate's referent is the literal proven serial code.
/// CONSTRAINT (n_threads>1): `gpa` must be thread-safe for the rare arena page-refill (§13.4).
pub fn runScheduledPar(
    comptime R: type, w: *world.World(R), gpa: std.mem.Allocator,
    comptime systems: []const schedule.Sys(R), exec: []const u16,
    rec: ?*recorder.Recorder, io: ?std.Io, n_threads: usize,
) ParError!void

/// stepExec's parallel twin: the full (clone, tick+%1, input-command prologue, parallel run, drain).
/// Prologue is single-threaded (runs before any stage); only the system run is parallel. `exec` may be
/// a stage-respecting within-stage permutation (the order-permutation property holds under threads).
pub fn stepExecPar(
    comptime R: type, gpa: std.mem.Allocator, prev: world.World(R), in: input.Input,
    comptime systems: []const schedule.Sys(R), exec: []const u16,
    rec: ?*recorder.Recorder, io: ?std.Io, n_threads: usize,
) ParError!world.World(R)

/// Convenience: stepExecPar with the canonical Schedule.exec_order (the production threaded entry,
/// the parallel twin of step.stepRec).
pub fn stepPar(
    comptime R: type, gpa: std.mem.Allocator, prev: world.World(R), in: input.Input,
    comptime systems: []const schedule.Sys(R),
    rec: ?*recorder.Recorder, io: ?std.Io, n_threads: usize,
) ParError!world.World(R)

/// The exec_order-driven merge of per-system sub-logs into a destination log (§13.3). Public so the
/// gate can drive it directly.
pub fn mergeSubLogs(
    gpa: std.mem.Allocator, dst: *event_log.EventLog,
    subs: []const recorder.Recorder, exec: []const u16,
) ParError!void
```

**File-private helpers in `step_par.zig`:** `runOne` (the per-system task fn) and a comptime stage-slicer.

**`root.zig` exports (append-only):**
```zig
pub const step_par = @import("step_par.zig");
pub const runScheduledPar = step_par.runScheduledPar;
pub const stepExecPar    = step_par.stepExecPar;
pub const stepPar        = step_par.stepPar;
pub const mergeSubLogs   = step_par.mergeSubLogs;
```
and `_ = step_par;` in the `test {}` refAllDecls block so its in-file tests run under the base 3-mode matrix.

**Stage recovery (comptime).** `exec` is stage-grouped ascending (`computeExecOrder`, schedule.zig:71-84), so a stage is a *contiguous run* of equal `Schedule(R,systems).stage_of[exec[k]]`. I do **not** re-derive stages at runtime; I segment `exec` by the comptime `stage_of` label of each id (cutting whenever `stage_of[exec[k]] != stage_of[exec[k-1]]`). This is robust to a within-stage permutation — segmenting by *label*, never by position — so each stage slice is a sub-slice of the canonical `exec` with identical ids/order.

**Per-stage execution (`group.await` is the barrier).** For each stage slice in stage order:

```zig
if (io == null or n_threads <= 1 or slice.len == 1) {
    for (slice) |sid| runOne(...);                 // inline (also the io==null / size-1-stage path)
} else {
    var group: std.Io.Group = .init;
    // INLINE-LAST: spawn k-1 tasks, run the LAST sid on THIS thread (frees a pool slot, keeps a core
    // hot, and mirrors supervisor.zig:121-124's inline+Group mix).
    for (slice[0 .. slice.len - 1]) |sid|
        group.async(io.?, runOne, .{ R, systems, sid, &w.table, order, w.tick, w.rng_root, &bufs[sid], &emitters[sid], &errs[sid] });
    const last = slice[slice.len - 1];
    runOne(R, systems, last, &w.table, order, w.tick, w.rng_root, &bufs[last], &emitters[last], &errs[last]);
    group.await(io.?) catch {};                    // BARRIER (see memory-model note below)
}
// after the barrier: scan errs[*] for this stage in ascending sid; first non-null -> return it.
```

**`group.await` is a real fence, not a bare join** — confirmed against `std.Io.Threaded`: `groupAwait` uses an `.acq_rel` `fetchOr` and an `.acquire` load on the completion counter, establishing happens-before so stage *s*'s column writes are visible to stage *s+1*'s reads (and to the post-barrier drain) on a different worker thread. This is the *same* pattern `supervisor.zig:119-142` already depends on for cross-thread index-addressed slot handoff. Pin this as a one-line comment + citation in the twin so a future reader need not re-derive it.

**Per-system task fn** (free-standing, captures nothing by closure — all by value or distinct-slot pointer, matching `supervisor.resolveShard`):

```zig
fn runOne(
    comptime R: type, comptime systems: []const Sys(R), sid: u16,
    table: *Table(R), order: []const u32, tick: u64, rng_root: RngRoot,
    buf: *CommandBuffer(R), emitter: *EventEmitter, err: *?std.mem.Allocator.Error,
) void {
    var ctx = SimCtx(R){ .tick = tick, .rng_root = rng_root, .system_id = sid, .cmd = buf, .events = emitter };
    systems[sid].invoke(&ctx, table, order) catch |e| { err.* = e; };
}
```
`Group.async` coerces the fn to `Cancelable!void` and `catch {}`-drops the result, so the `Allocator.Error` **must** be captured into a per-system out-slot `errs[sid]` (exactly the `proc_gate.serveOne` / `supervisor.resolveShard` discipline) and surfaced after `await` in ascending-sid order — deterministic, never swallowed. OOM is off the determinism contract (a failed run, not a divergence). `sid` and all slot pointers are passed **by value** in the args tuple (no loop-variable-by-reference aliasing).

**What each task touches:** its declared-Write columns (`table.column(i)[row]` — stage-disjoint, see §13.5 hazard #1), its Read columns (no co-running writer), the shared read-only `order: []const u32`, `tick`/`rng_root` (by value), its OWN `bufs[sid]` / `emitters[sid]` / `errs[sid]` (distinct addresses, indexed by `sid`). No task writes any shared mutable cell.

**Degenerate cases** (checked in order, all collapse to the proven serial path): `io == null` OR `n_threads <= 1` → delegate **verbatim** to `step.runScheduled`/`step.stepExec` (caller gpa, no arenas — the literal serial referent the bit-identity gate compares against). `systems.len == 0` → the comptime `if (systems.len != 0)` guard (so the `[0]` arrays are never analyzed). A stage of size 1 → run inline (no Group, no spawn). Arenas are used **only on the actually-threaded branch**.

### 13.2 The order-canonicalized columns and drain (single-threaded, post-barrier)

`order = w.table.canonicalOrder(gpa)` is computed **once** on the orchestrator thread before any fan-out (the table is structurally frozen during the run phase — all structural change is deferred to command buffers) and shared read-only by every task. The end-of-tick drain — gather every `bufs[i].list.items` in `0..len` order, stable-sort by `(system_id, seq)`, `mutation.applyCommand` in order — runs **single-threaded after the last stage's await**, byte-identical to `runScheduled`. It is never parallel.

### 13.3 Per-system sub-log merge — byte-for-byte reproduction of the single-threaded log

**The hazard (verified, recorder.zig:33-89).** A single shared `Recorder` has one append-ordered `log`, shared `scratch_bytes`/`scratch_causes` (`clearRetainingCapacity` then append — a data race), and a single-slot `cur_sa` SystemCause-dedup that assumes contiguous per-`(tick,system)` `record()` calls. Concurrent `record()` races all three **and** scrambles physical log order.

**The invariant that makes a deterministic merge possible (verified, simctx.zig:82-96).** `EventId = {tick, emitter=system_id, seq=emit_ordinal}` and the SystemCause id `{tick, RESERVED_SYSACT, seq=system_id}` are **pure functions of `(tick, system_id, emit_ordinal)`** — execution-order *independent*. `emit_ordinal` lives on each task's own stack `SimCtx` and advances unconditionally. So threading changes **only the physical append order**; every id is identical.

**Design — per-system sub-recorders, merged in `exec` order.** When `rec != null` and we take the threaded branch, allocate `subs: [systems.len]Recorder`, `subs[sid] = Recorder.init(arenas[sid].allocator())` (§13.4). Each task's emitter is `.{ .recording = &subs[sid] }`. Each system runs in exactly one stage and is invoked exactly once per tick on one task, so:
- its `scratch_bytes`/`scratch_causes` are private (no race);
- its `cur_sa` dedup works **unchanged** — its records are contiguous *within its own sub-log*, which is exactly the contiguity precondition; it fires its SystemCause node exactly once on first emit (recorder.zig:70);
- its sub-log holds exactly that system's tick-T block: `[SystemCause(tick, RESERVED_SYSACT, sid)] ++ ev0 ++ ev1 ++ …`, byte-identical to what the shared recorder produced for that system in isolation, because `record()`'s output depends only on `(E, tick, system_id, seq, subject, value, extra)` and the sub-recorder's own `cur_sa`.

**The exact merge** (single-threaded, after the last stage's `await`, before the drain frees the arenas):

```zig
pub fn mergeSubLogs(gpa, dst: *EventLog, subs: []const Recorder, exec: []const u16) !void {
    for (exec) |sid| {                                  // exec == stages in order, ascending sid within a stage
        const src = &subs[sid].log;
        for (src.events.items) |e| {                    // already in this system's emission order
            const payload = src.payload_arena.items[e.payload_off..][0..e.payload_len];
            const causes  = src.edge_arena.items[e.cause_off..][0..e.cause_len];
            try dst.append(gpa, e.id, e.kind, e.emitter, e.subject, payload, causes);
        }
    }
}
```

Slice each sub-log's `payload_arena`/`edge_arena` by the event's **own** `payload_off`/`payload_len`/`cause_off`/`cause_len` (verified field names: `payload_off:u32`, `payload_len:u16`, `cause_off:u32`, `cause_len:u32` — event.zig:77-80). This avoids the O(events²) `payloadOf(e.id)`/`causesOf(e.id)` find-by-id scan and is the canonical direct-slice merge.

**Why byte-for-byte identical to single-threaded:**
1. Single-threaded `runScheduled` appends, *per system in `exec` order*, exactly `[SystemCause, ev0, ev1, …]` (each emitting system's block starts with its lazily-materialized SystemCause node).
2. The merge re-appends, *per system in the same `exec` order*, exactly that system's block from its sub-log.
3. `record()`'s output for a given system is independent of any other system, so the blocks are identical.
4. `EventLog.append` (event_log.zig:49-73) re-bases `payload_off`/`cause_off` into the **destination** arenas and copies payload/cause bytes in append order; `writeLog` (event_log.zig:129-142) serializes `events[]` then `edge_arena` then raw `payload_arena`. Since the merged `events[]` order == single-threaded order, and per-event payload/cause bytes are identical, and the arenas are filled in the same sequence, `writeLog` produces identical bytes → `logDigest` identical.
5. **SystemCause lazy-materialization coincides exactly:** a system emitting ≥1 event materializes exactly one SystemCause node at the head of its block in BOTH paths; a system emitting nothing produces an empty sub-log (its `cur_sa` never fires) and contributes nothing — identical to single-threaded, where the spine never calls `record` for it.
6. **Cross-tick causes** (`CauseToken`, the `Spark`←`Boom` chain, replay.zig:246-261) are recorder-independent `{tick, system_id, emit_ordinal}` — identical threaded vs single — so tokens stored in components and the edges they resolve to are preserved verbatim.

**Lifecycle:** sub-recorders are per-tick scratch. Per tick: dispatch → await(barrier) → drain (reads `bufs`) → merge (copies sub-logs into the caller `rec.log` on the caller gpa) → reset/deinit arenas. The merge **copies** bytes into the caller-gpa master log before any arena reset.

### 13.4 Allocator decision — per-system arenas, with a documented gpa-thread-safety constraint for refill

Two concurrent allocation sites under N threads: (a) `CommandBuffer.list` growth on `cmd.spawn/add/set/…`; (b) per-system `Recorder` `log`/`scratch` growth on `record`.

**Decision: per-system `ArenaAllocator` per tick** (option b), NOT "require a thread-safe gpa globally". Each system gets `arenas: [systems.len]std.heap.ArenaAllocator`, `arenas[sid] = .init(gpa)`, created on the **orchestrator thread before fan-out**. `bufs[sid] = CommandBuffer(R).init(arenas[sid].allocator(), sid)`; `subs[sid] = Recorder.init(arenas[sid].allocator())`. An arena is touched by exactly one thread (the task owning `sid`) → zero contention, no lock, no false sharing — which is what keeps the §13.6 overlap genuine (a shared thread-safe gpa would serialize every append behind its mutex, defeating the point).

**The one residual all four designs share, closed two ways:**
- **Refill:** intra-arena bumps need no gpa; an arena *page-refill* mid-task calls `gpa.alloc` from a worker thread. To remove this structurally, **pre-reserve each arena to a small high-water capacity on the orchestrator thread before fan-out** (alloc-then-`reset(.retain_capacity)`), so the common case needs no concurrent gpa hit at all.
- **Constraint, documented in the module header:** when `n_threads > 1`, the `gpa` must be thread-safe for the rare over-the-high-water refill. `std.testing.allocator` / `DebugAllocator` satisfy it (`thread_safe` defaults true); any production thread-safe allocator does. This is the honest fallback the judges insisted on naming rather than papering over.

**D8 safety (no addresses in hashed state):** arena/bump addresses never enter hashed state. `Command.payload` is an inline `[max]u8` value copy (command_buffer.zig:55); the drain copies Command *values* into `all` and applies by value. Sub-log entries store ids/values/u32 offsets, never pointers; the merge re-bases offsets into the caller gpa's arenas. `hashWorld` reads only World columns (commands and the event log are side structures, never hashed — command_buffer.zig:18, event_log.zig:1-6). So which arena an allocation lands in is invisible to every digest → Debug==ReleaseSafe==ReleaseFast preserved. The gate's ARENA-EQUIVALENCE test (T7) pins this by asserting the arena-using threaded path equals the gpa-using serial pins.

### 13.5 Determinism-hazards table (hazard → eliminating mechanism, each verified against the code)

| # | Hazard | Eliminating mechanism (verified) |
|---|--------|----------------------------------|
| 1 | **Data race on component columns** | `computeStageOf` (schedule.zig:54-67) + `conflict` (schedule.zig:20-22: `a.write & (b.read\|b.write) != 0`, symmetric) ⇒ same-stage systems are pairwise non-conflicting ⇒ each column has **at most one writer per stage** and no reader of a written column co-runs with it. `column(i)` = `rows.items(compField(i))` (storage.zig:74); `MultiArrayList.items` copies the list by value and returns a slice into a **distinct, non-overlapping** backing span (storage.zig:57-59 confirms it does not propagate constness — distinct fields are distinct slices). Concurrent writes hit disjoint addresses. The in-tree invariant test "no two systems sharing a stage conflict" (schedule.zig:243-252) already asserts the precondition. |
| 2 | **Within-column row aliasing** | N/A — a column has ≤1 writer per stage (WAW conflicts forbid two), and that one system visits each row once via its own Query cursor. No two tasks touch the same column. |
| 3 | **Cross-stage WAR/WAW visibility / torn reads across the barrier** | `group.await` is a happens-before fence (`.acq_rel` fetchOr + `.acquire` load in `std.Io.Threaded`, the same edge `supervisor.zig:119-142` relies on). All stage-*s* writes are published before stage-*s+1* reads or the post-barrier drain. |
| 4 | **Command-buffer append race** | Each task writes ONLY `bufs[sid]` (distinct array element, indexed by `sid` passed by value); backing memory is a single-thread-owned arena. The gather+sort+apply drain runs single-threaded post-barrier (§13.2). Same index-addressed-slot discipline as `supervisor.zig:64-66`. |
| 5 | **Allocator contention / UB** | Per-system arenas (one thread per arena); residual gpa hit only on over-high-water refill, for which gpa must be thread-safe (§13.4, documented; testing.allocator qualifies). Pre-reservation removes it in the common case. |
| 6 | **Recorder scratch/`cur_sa`/log race** | Per-system sub-Recorders (own scratch, own `cur_sa`, own log). `rec.log` written only during the single-threaded merge. `cur_sa` dedup correct because each sub-recorder sees only its own contiguous records (§13.3). |
| 7 | **Physical log-order nondeterminism** | Merge replays sub-log appends in canonical `exec` order ⇒ `rec.log.events[]` order == single-threaded ⇒ `writeLog` bytes identical ⇒ `logDigest` identical. EventIds are order-independent already (§13.3 invariant). |
| 8 | **RNG race / shared cursor** | N/A — `rngmod.draw(rng_root, tick, entity, stream)` is pure, no cursor (D4, simctx.zig:71); `rng_root` copied by value into each `SimCtx`. Concurrent draws are pure reads. |
| 9 | **Float / clock / syscall leak into hashed state (D7)** | None introduced — the twin adds no arithmetic; systems use fpz fixed-point. `Io.Clock.now` appears ONLY in the gate's wall-clock assertion, never in step/digest. The sleeping overlap systems are pure w.r.t. hashed state (sleep is wall-clock only, never read into World). |
| 10 | **Pointer / address in hashed state (D8)** | None — arena addresses never enter Command payloads (inline value copies), sub-log entries (ids/values/u32 offsets), World columns, or digests. The merge re-bases offsets. Build-mode bit-identity preserved (§13.4). |
| 11 | **`Group.async` swallows task errors** | Allocator.Error captured into `errs[sid]` out-slot, surfaced after await in ascending-sid order. OOM propagates; never a silent short/empty buffer that diverges the hash. |
| 12 | **Loop-variable-by-reference capture** | `sid`, `table`, `order`, `tick`, `rng_root`, slot pointers all passed **by value** into the `Group.async` args tuple (matching `supervisor.resolveShard`). No task aliases a mutating loop variable. |
| 13 | **`Io.async` EAGER-inline degrade changing RESULTS** | None — eager execution (a surplus task runs on the caller when `busy_count >= async_limit`) is just another physical intra-stage order; determinism holds for ANY intra-stage order (the §4 order-permutation property). It affects only wall-clock overlap, addressed in the gate (§13.6). |
| 14 | **Drain comparator drift between spine and twin** | Eliminated by extracting the `(system_id, seq)` drain into a shared `step.drainAndApply(R, w, gpa, bufs)` called by BOTH `runScheduled` and the parallel twin (§13.7). |
| 15 | **Arena use-after-reset (cross-tick lifetime)** | Strict order: dispatch → await → drain (reads bufs) → merge (copies sub-logs into caller-gpa log) → reset/deinit arenas. No premature `defer` frees an arena before both consumers run. A dedicated gate test (T8) asserts a 2nd-tick merge never reads tick-1 freed bytes. |
| 16 | **Escape-hatch: a rogue system touching an undeclared column** | Out of contract, UNCHANGED from single-threaded (SPEC §15 trusts the author; the VOPR §9 detects divergence). A *conforming* system is race-free; the parallel path adds no new hole. Documented in the twin's header; the gate uses only conforming systems. |
| 17 | **`std.debug.print` under `--listen`** | No `debug.print` in any `step_par` or gate test body (Phase-9 lesson — it corrupts the test-runner IPC). Pins are asserted; recompute via a guarded non-test `dumpPin`. |

### 13.6 The gate (the witness) — exact test list, each witness bullet → its assertion

**New file `src/step_par_gate.zig`**, wired into the **base 3-mode `tmod` test** via `_ = @import("step_par_gate.zig");` in `root.zig`'s `test {}` block — NOT a dedicated build.zig artifact. The base matrix (build.zig:47-60) already runs `root`'s refAllDecls across Debug/ReleaseSafe/ReleaseFast, and `std.testing.io` is Threaded-backed there (the supervisor/proc tests prove it). A pure in-process thread gate has no worker-exe / `build_opts` dependency, so it needs no artifact of its own — strictly less build churn, and it gets the D2 cross-mode matrix for free. Uses `std.testing.io` and `testing.allocator` (thread-safe). NO `std.debug.print` in any test body; pins recomputed by a guarded non-test `dumpPin` (the `proc_gate.zig:370` idiom).

**System set** (must have ≥1 genuinely multi-member parallel stage): widen replay.zig's `sys3` shape — e.g. Registry `{A,B,C,D}` with `writeA`/`writeB`/`writeC` mutually disjoint (one 3-member stage 0) and a `gather` reading A,B,C writing D (stage 1). All systems CONFORMING (declare exactly what they touch). Confirm `Schedule.stage_count == 2` and the writers share stage 0 via the schedule invariant. Per-tick stream folded into an `XxHash64` exactly like `replay.runTrajectory` (replay.zig:161-174).

| # | Witness bullet | Assertion |
|---|----------------|-----------|
| T1 | **bit-identity (per build mode)** | Run K≈12 ticks twice from one seed: serial via `step.runScheduled`, parallel via `runScheduledPar(io=testing.io, n_threads=8)`. Fold each tick's `w.digest().hash` into a stream. `expectEqual(serial.stream, par.stream)` AND `expectEqual(serial.final, par.final)`. Multi-stage with a real parallel stage. |
| T2 | **pinned cross-build (D2)** | `expectEqual(@as(u64, <PIN_FINAL>), par.final)` and `expectEqual(@as(u64, <PIN_STREAM>), par.stream)`. Passing under all 3 modes proves Debug==ReleaseSafe==ReleaseFast bit-identity of the threaded path. Pins recomputed once via `dumpPin` (outside `--listen`). |
| T3 | **repeated-run identity** | Run `runScheduledPar(n_threads=8)` 16× → collect 16 stream digests → all equal the first. Scheduling nondeterminism does NOT leak into state. |
| T4 | **recording-on byte-identity** | One trajectory serial with a `Recorder`, one parallel (sub-recorders + `mergeSubLogs`). Serialize BOTH via `event_log.writeLog` into two ArrayLists; `expectEqualSlices(u8, serial_bytes, par_bytes)` AND `expectEqual(logDigest(serial).hash, logDigest(par).hash)`. Also assert events-ON par final hash == events-OFF par final hash (hash-invariance under threads). |
| T5 | **order-permutation under threads** | Run `runScheduledPar` with `EXEC_CANON` and with a within-stage permuted `exec` (swap two stage-0 ids); `expectEqual` stream+final. The §4 property survives threading. |
| T6 | **ACTUAL overlap (genuine parallelism, robust to high core count)** | A dedicated set where each of K mutually-non-conflicting same-stage systems does an in-process Io sleep before trivial deterministic work. **Before the run, `std.testing.io_instance.setAsyncLimit(.unlimited)` with `defer`-restore** (Threaded degrades `groupAsync` to inline-eager when `busy_count >= async_limit`, default `cpu_count-1` — Threaded.zig:1639/2197 — so an unraised limit can silently serialize a K-wide sleeping stage on a low-core box). Bracket wall-clock with `std.Io.Clock.now(.awake, io)` (proc_gate.zig:345-358). Assert `par_ms * 100 < seq_ms * 60`. Test BOTH a narrow (K=2) and a wide (K=6) sleeping stage to prove robustness to core count. On spawn-unavailable → `error.SkipZigTest` (honest, never a silent serial pass). |
| T7 | **arena equivalence / degenerate delegation** | `runScheduledPar(io=null,…)` and `runScheduledPar(n_threads=1,…)` produce the identical hash to `step.runScheduled` (delegation correctness — arenas are not on this path; addresses change nothing). Empty-systems path runs the input prologue. |
| T8 | **arena lifetime (cross-tick UAF guard)** | A ≥2-tick recording run where tick-2's merge must NOT read tick-1 freed arena bytes — asserts the strict dispatch→await→drain→merge→reset ordering by checking the merged log digest equals the single-threaded multi-tick log. |

**The in-process sleep primitive for T6 is confirmed in-tree** (`worker.zig:51-52`):
```zig
const dur = std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(MS) };
dur.sleep(io) catch {};
```
Use exactly this in a gate-only sleeping system body (reads NO hashed state). This retires the "needs a spike" open question and avoids any busy-loop fallback.

### 13.7 Ordered implementation checklist

1. **Extract the drain** in `step.zig`: factor the gather+stable-sort-by-`(system_id,seq)`+apply block (step.zig:139-149) into `pub fn drainAndApply(comptime R, w: *World(R), gpa, bufs: []CommandBuffer(R))`; call it from `runScheduled`. Behavior-preserving — the existing step.zig tests re-prove it. (Hazard #14.)
2. **Create `src/step_par.zig`**: imports, the comptime stage-slicer over `exec`, the `runOne` task fn, and the `await` happens-before citation comment.
3. **`runScheduledPar`**: degenerate fallbacks first (verbatim delegate to `step.runScheduled` / `stepExec`); else allocate `arenas`/`bufs`/`emitters`/`errs`/(opt.)`subs` on the orchestrator thread, **pre-reserve each arena** (alloc-then-`reset(.retain_capacity)`), compute `order` once, per-stage dispatch with inline-last + `group.await` barrier, surface `errs` in sid order, call `step.drainAndApply`, then `mergeSubLogs` (if `rec`), then reset/deinit arenas — in that strict order. (Hazards #4,#5,#11,#15.)
4. **`mergeSubLogs`**: the direct-slice merge (§13.3), slicing each sub-log arena by the event's own offsets.
5. **`stepExecPar` / `stepPar`**: clone + `tick +%= 1` + input-command prologue (single-threaded, copied from `stepExec`), then `runScheduledPar`.
6. **`root.zig`**: append the 5 exports + `_ = step_par;` and `_ = @import("step_par_gate.zig");` in the `test {}` block.
7. **`src/step_par_gate.zig`**: the 4-system set + the K-wide sleeping set; tests T1–T8; the guarded `dumpPin`.
8. **Recompute pins** via `dumpPin` (outside `--listen`), freeze `PIN_FINAL`/`PIN_STREAM` and the merged-log digest into T2/T4.
9. **Module header docs**: the `n_threads>1 ⇒ thread-safe-gpa-for-refill` constraint; the escape-hatch trust boundary; the `await`-is-a-fence citation.
10. **Run** `zig build test` (all 3 modes) — base matrix must stay green, the 8 new gate tests green per mode.

### 13.8 Residual risks

- **gpa thread-safety on arena refill.** Pre-reservation removes the *common-case* concurrent gpa hit, but a system that allocates beyond its arena's high-water still refills concurrently, requiring a thread-safe gpa (documented constraint, satisfied by testing.allocator and any production thread-safe allocator). T6 uses sleep-bound systems, so it proves *dispatch* overlap but not that a *malloc-heavy* workload avoids serializing on refill — the honest soft spot. A future variant could size the high-water from a per-system heuristic to make the path fully caller-constraint-free.
- **Overlap is proven "if given threads," not "the default pool overlaps."** `setAsyncLimit(.unlimited)` forces one thread per task in the gate; in production on a fixed pool a stage wider than the pool partially serializes (a throughput ceiling, not a correctness issue). **Open product decision:** production callers' limit policy — `.unlimited`, a tuned limit, or the default `cpu_count-1`. Document the chosen default; restore the process-global `testing.io_instance` limit with `defer` so the wide-stage and other gate tests in the same binary are not cross-coupled.
- **CI timing noise.** The 60% margin is inherited from proc_gate (which passes across processes on this toolchain); in-process thread spawn is cheaper than process spawn, so the margin should be safer, but a heavily loaded box can still be noisy — may need margin-tuning or a retry on unusual hardware.
- **Scope: comptime path only.** `runScheduledParDynamic` (a threaded twin of `runScheduledDynamic` for dlopen'd runtime system sets) is a declared follow-on seam — the merge/arena design is identical (recover stages from `schedule.stagesDynamic`, heap-allocate sized-at-runtime arenas/subs) — explicitly NOT silently dropped, out of scope here.

Gate target: **+16 in-process thread gate tests per mode** (Debug/ReleaseSafe/ReleaseFast) folded into the base suite — zero new build artifacts.

### Phase 2b notes (from the adversarial review — 6 dimensions, 14 confirmed / 2 refuted; the HIGH + both MEDIUMs and the substantive LOWs fixed before commit)

1. **HIGH — the witness only proved determinism, not thread-safety (fixed).** The functional bit-identity tests (T1–T5) ran at the DEFAULT `async_limit`. `std.Io.Threaded` eager-inlines a `group.async` task on the caller once `busy_count >= async_limit` (default `cpu_count-1`); on a low-core box that is `.limited(0)` → every task inlines → the "parallel" path is fully serial, yet an equality assertion still passes (the spine is deterministic when serial). Only T6 forced overlap, and it used READ-ONLY sleepers — so NO green test exercised the actual hazards (concurrent disjoint-column writes, concurrent keyed RNG, concurrent sub-recorder emits+merge) under true concurrency. The reviewer proved it by running T1 under `.limited(0)` (passed, fully serialized). **Fix:** every functional concurrency test now brackets the run with `setAsyncLimit(.unlimited)` (`forceOverlap`, restored via defer) so the pool grows a thread per task on ANY core count; and **T9** was added — a *data-bearing* overlap proof whose disjoint-column-WRITING systems SLEEP, so they provably execute SIMULTANEOUSLY (measured wall-clock overlap) while writing columns / drawing RNG / emitting, asserting the result is bit-identical to serial (race-free) AND overlapped (genuine).
2. **MEDIUM — T6 hard-failed instead of `error.SkipZigTest` on a spawn-incapable build (fixed).** §13.6 mandated an honest skip; T6 had none. Added `if (builtin.single_threaded) return error.SkipZigTest;` to T6 and T9 (the compile-time no-threads case).
3. **MEDIUM — the genuine-overlap witness used a read-only, RNG-free, record-free workload (fixed by T9).** The data-bearing concurrent path is now force-overlapped (see #1).
4. **LOW (fixed):** the parallel branch now validates `exec` is a stage-GROUPED permutation in safe builds (a malformed exec would escalate to a data race, unlike the serial path's benign wrong result); `mergeSubLogs` now runs BEFORE the drain (recording precedes the drain, mirroring the spine); T4's set gained a 2-emit-with-explicit-cause system (witnesses the per-sub-recorder `cur_sa` dedup + a multi-element cause list through the merge) and a zero-emit system (witnesses an empty sub-log contributes nothing); T5 now pins the permuted-exec MERGED LOG (not just the world hash); **T10** witnesses a system fault is SURFACED in ascending-sid order (not swallowed by `group.async`'s `catch {}`); **T11** drives `stepExecPar` through a `FailingAllocator` (clean teardown, no leak); the `n_threads` doc now states the actual overlap degree is owned by the passed `io` (`async_limit`), not `n_threads`.
5. **Refuted (2):** "`group.await catch {}` leaves torn buffers after a swallowed `error.Canceled`" — `await` completes all member tasks before returning, so post-barrier reads are well-defined; "per-system arena stack array has no documented ceiling" — the N-sized arrays are bounded by the comptime system count exactly as the serial path's `[N]CommandBuffer` is, and the warm-loop's gpa pressure premise was factually wrong.

---

## 14. Cross-architecture determinism gate — SPEC §2 "every architecture" (decision of record)

The base `zig build test` gate proves `Debug == ReleaseSafe == ReleaseFast` on the host (x86-64, 64-bit
LE). SPEC §2 claims the per-tick state hash and **every** frozen pin are bit-identical on EVERY
architecture — the premise that makes record/replay/forking exact across machines. `zig build cross`
closes that axis: it cross-compiles the whole root suite and re-checks every pin under **qemu-user** on
the four quadrants of {word size} × {endianness}, so each pin is verified against a different ISA, both
byte orders, AND both pointer widths.

| target | bits | endian | role |
|---|---|---|---|
| x86-64 | 64 | LE | the native baseline (`zig build test`) |
| **aarch64** | 64 | LE | a different ISA / codegen / alignment |
| **s390x** | 64 | **BE** | the canonical-LE serialization witness |
| **arm** | 32 | LE | a 32-bit word (the no-`usize`-leak witness) |
| **mips** | 32 | **BE** | 32-bit **and** big-endian at once (the strongest single stress) |

**Result: all 304 determinism tests pass on every quadrant × 3 modes (12 qemu suites, 0 fail).** Every
frozen digest — content hashes, the per-tick stream digest, the event-log digest, the VOPR replay
constants, the 8 query digests, the spec/metric/violation digests, the migration images + reload-stream
digest, and the threaded step_par pins — is byte-identical across all of them.

**Why the big-endian / 32-bit pass is PRINCIPLED, not lucky** (an endian/word-size audit — 39 agents,
clean bill of health). The hashed/serialized path is fixed-width and canonical-LE BY CONSTRUCTION:
`serialize.putInt`/`getInt` derive byte count from `@typeInfo(T).int.bits` and emit an explicit LE byte
loop — never `@bitCast`/`asBytes`/native-endian, never `@sizeOf(usize)`. Every length/count/mask is
`@intCast` to an explicit `u16`/`u32`/`u64` before it hits the wire; the presence mask is widened to a
fixed `u64`; `hashWorld` reads only codec bytes (never native SoA/struct layout); D7 (no float) and D8
(no pointer) are `@compileError`-enforced in `registry.assertSerializable`. So no host-endian or
word-width value ever reaches a hashed byte.

**Implementation notes / decisions:**
- `build.zig` sets `b.enable_qemu = true` and uses `addRunArtifact` on the foreign test (Zig auto-wraps
  with `qemu-<arch>` and uses the binary test-IPC protocol). An earlier `addSystemCommand` + self-run
  approach proved flaky — the 306-line stdout through a captured pipe intermittently SIGPIPE'd under
  emulation. The root test module links no libc, so each foreign binary is a static ELF qemu runs
  directly. Missing qemu is a hard error (`failing_to_execute_foreign_is_an_error` default) — never a
  vacuous pass. The qemu runs are CHAINED (serialized) so the emulated thread spawns of the step_par
  tests across many suites don't oversubscribe the host; kept SEPARATE from `zig build test` because
  qemu is ~10-20× slower.
- The wall-clock OVERLAP proofs (`step_par_gate` T6/T9) self-skip on the foreign targets
  (`timing_reliable = builtin.cpu.arch == .x86_64`): overlap is a host-runtime property, unreliable under
  emulation, and already proven natively. The cross gate re-checks DETERMINISM (the pins) + threaded
  determinism (T1–T5), which are robust under emulation — so each foreign suite reports 304 pass / 2 skip.
- The gate surfaced **5 genuine 32-bit portability bugs** (u64 values indexing slices / sizing an alloc,
  which only fail when `usize`=u32) in `vopr/generator.zig`, `spec/trace.zig`, `proc/supervisor.zig` —
  fixed with behavior-preserving `@intCast` (identity on 64-bit). gkz now compiles AND runs bit-identically
  on 32-bit.
- The fixed-width invariant is now STRUCTURAL: `serialize.assertFixedWidth` (`comptime` in
  `putInt`/`getInt`) `@compileError`-rejects `usize`/`isize`, so a future pointer-width field is a
  compile error rather than a silent 32-bit divergence — the audit's belt-and-suspenders fix (b),
  complementing the empirical gate (fix a).

**Residual scope:** 64-bit big-endian (s390x) + 32-bit both-endian (arm/mips) cover the realistic matrix.
Other targets (riscv64, ppc64, wasm) are reachable the same way (add the arch to `cross_arches`) but add
no new {wordsize,endian} quadrant. SIMD vs scalar (§7 risk #7) remains a separate axis once SIMD lands.

## 15. Phase 10 design — §11 content-as-data: prefabs, levels, proc-gen, asset handles (decision of record, from the design judge-panel)

> Base design: **determinism-purist** (panel winner, 270; Judge #1/#2/#3 all best). Grafted: reuse-minimal's **comptime Gate #8** (offset-vs-codec consistency), ai-authoring-first's **odd-generation `localRef` sentinel** + the **`mutation.applyAdd` slice extraction**, robustness-serialization's **OOM-injection sweep** and **persisted `field_path` patches**. Every open question is resolved below.
>
> **AS-BUILT NOTE — read §15.15 first.** The `field_path` graft (and the `ref(field-path)` builder method / `fieldOffset` helper it implies) was **NOT built**; it is demoted to a declared v1.1 non-goal. It only matters across a §12 prefab migration (itself v1.1), and the decode-time legal-offset validator + comptime Gate #8 deliver the same fail-closed safety without it. Wherever §15.2/§15.6/§15.10/§15.11/§15.13 below describe `field_path` / `ref(path)` / `fieldOffset` as built, read §15.15: the builder derives patches from the `localRef` **sentinel-walk** instead, and §15.15 records every adversarial-review delta.

### 15.1 What §11 demands, mapped to artifacts

SPEC §11 has exactly three clauses: (a) entities/prefabs/levels are *structured, diffable, mergeable data, not opaque scenes*; (b) procedural generation is *content-as-code emitting content-as-data, deterministically seeded*; (c) rendering assets are *referenced by handle and not required for the sim to run* — headless-first. There is no concrete artifact in tree today. Phase 10 delivers one new module, `src/content.zig` (exported from `root.zig` as `pub const content` / `pub const Prefab` / `pub const Level` / `pub const Builder`), plus a content gate folded into the existing 3-mode + 4-arch matrix.

### 15.2 Data model + exact signatures (`src/content.zig`)

A template entity is **not** an `Entity`: it has no generation and no allocator state, only a dense authoring position. A distinct newtype makes a local id a compile-time-distinct type from a real handle, so the two can never be confused at a call site.

```zig
//! SPEC §11 — content as data. Prefabs/levels are structured, diffable records (NOT opaque scenes):
//! a Prefab is a set of per-local-entity component CELLS (canonical-LE bytes, == image.KindRecord) plus
//! an explicit local->local ref-patch list; a Level composes prefab instances + standalone nodes into a
//! starting World. Instantiation spawns in canonical local-id order over the deterministic FIFO entity
//! allocator, sets cells through the shared kind_id->type dispatch, then rewrites refs — so a level's
//! loaded-World digest is a fixed pin across build modes AND the cross-arch matrix. Decode is UNTRUSTED
//! and hostile-hardened exactly like image.decode (validate-before-alloc, never panic, never a wild write).

const image = @import("migrate/image.zig");

/// A reference to an entity WITHIN a prefab/level template, valid only during authoring + instantiation.
/// `enum(u32)` so it serializes as a u32, orders trivially, and is a type DISTINCT from `Entity`.
pub const Local = enum(u32) { _ };

/// One authored component cell: kind_id + canonical-LE value bytes. ALIASED from image.KindRecord (not
/// re-declared) so prefab cells interoperate with image.findCell/maskFor/encode for free.
pub const Cell = image.KindRecord; // = struct { kind_id: u16, bytes: []const u8 }

/// One authored entity in a template: its local id and its component cells in ascending kind_id.
pub const Node = struct {
    local: Local,
    cells: []const Cell, // ascending kind_id (canonical), like image.RowRecord.comps
};

/// "Rewrite local entity `node`'s component `kind_id`, at canonical byte `byte_offset` (an 8-byte Entity
/// leaf), to the real handle of local entity `target`." Ref-ness is a property of the PATCH, not a type.
pub const RefPatch = struct {
    node: Local,        // the node whose cell is patched
    kind_id: u16,       // which component cell
    byte_offset: u32,   // offset of the 8-byte Entity leaf WITHIN that cell's canonical bytes
    target: Local,      // the local whose resolved real handle is written there
    /// PERSISTED-ONLY field-index path (e.g. &.{0,2} = field 0 then array elem 2), resolved to byte_offset
    /// at decode against the LIVE registry (migration-robust; see §15.6). Ignored on the in-memory path.
    field_path: []const u16 = &.{},
};

/// A reusable template of one-or-more entities. NO allocator state, NO generations. `R` validates
/// kind_ids/widths at build/decode. Instantiable many times.
pub fn Prefab(comptime R: type) type {
    return struct {
        const Self = @This();
        pub const Registry = R;
        nodes: []const Node,     // canonical order = ascending local id
        patches: []const RefPatch, // canonical order = ascending (node, kind_id, byte_offset)
        arena: ?std.heap.ArenaAllocator = null, // present iff this Prefab owns its slices (builder/decoded)
        pub fn deinit(self: *Self) void { if (self.arena) |*a| a.deinit(); self.* = undefined; }
    };
}

/// A composition that builds one initial World: prefab instances (+ per-instance overrides) + loose nodes.
pub fn Level(comptime R: type) type {
    return struct {
        const Self = @This();
        pub const Registry = R;
        tick0: u64 = 0,
        schema_version: u32 = 1,
        rng_seed: u64,                  // becomes World.rng_root.seed (hashed)
        prefabs: []const Prefab(R),     // the prefab table placements index into
        placements: []const Placement,  // each names a prefab + per-instance overrides
        loose: []const Node,            // standalone entity templates (no prefab)
        arena: ?std.heap.ArenaAllocator = null,
        pub fn deinit(self: *Self) void { if (self.arena) |*a| a.deinit(); self.* = undefined; }
    };
}

pub const Placement = struct { prefab_index: u32, overrides: []const Override = &.{} };
pub const Override = struct { local: Local, cell: Cell }; // v1: REPLACE one whole cell at instantiate time
```

Local ids are dense `0..nodes.len`, assigned sequentially by the builder. Denseness is what makes the local→real map a **flat `[]Entity`**, not a hashmap — no hash-iteration order participates anywhere (a determinism hazard eliminated structurally).

### 15.3 Entity-ref resolution — DECIDED: explicit ref-patches (not reflection-at-rewrite)

The rewrite mechanism is **explicit `RefPatch` data**, never a reflection walk over a component's `Entity`-typed fields. This is the load-bearing decision.

- **The managed-ref vs raw-data contract:** a field is a *managed ref* iff an author emits a `RefPatch` for it. The kernel uses `Entity` for *both* a managed cross-entity reference (`event.subject`, spec atoms) *and* potentially an opaque value an author wants left verbatim. Reflection would silently rewrite **all** `Entity`-shaped 8-byte windows — including raw-id data and the asset handle — corrupting them. The explicit patch makes "this is a ref" an auditable, diffable claim; the patch list literally *is* the prefab's dependency graph.
- **Ergonomics without reflection magic:** the builder offers `b.ref(node, C, "field.path", target)`, which computes `byte_offset` **at comptime** by walking `C`'s serialized leaves in declaration order, summing `serialize.serializedSizeOf` of every preceding leaf, asserting `@FieldType` resolves to `Entity` (compile error on a typo or a non-`Entity` field). Nested structs and array elements address as a single flat `u32` (`"links.2"`). So the author writes a normal typed call; the explicit patch is *generated* from the type.
- **Rewrite at instantiate:** after all nodes of an instance are spawned and `map: []Entity` is built, each patch overwrites the 8-byte window at `byte_offset` with `putInt(u32 index)` then `putInt(u32 generation)` of `map[target]` — byte-identical to what the codec would emit for a real handle. Then the cell is decoded+set normally. Patches touching overlapping bytes of the same `(node, kind_id, byte_offset)` are a **build-time and decode-time error** (rejected), so application is order-independent by construction; the canonical patch sort `(node, kind_id, byte_offset)` makes the serialized form byte-unique anyway.
- **GRAFT — odd-generation sentinel (ai-authoring-first):** the builder seeds every not-yet-resolved `Entity` leaf with `localRef(target) = Entity{ .index = target, .generation = 0xFFFF_FFFF }`. Because `0xFFFF_FFFF` is **odd**, `entity.isLive` (even = alive) treats it as a dead handle. If a patch is ever missed, the residual is a **loud dead handle (fail-closed)** in any system, never a plausible-looking live ref. Belt-and-suspenders for the computed-patch model.

```zig
pub const LOCAL_REF_GEN: u32 = 0xFFFF_FFFF; // odd => never live (entity.zig isLive)
pub fn localRef(target: Local) Entity {
    return .{ .index = @intFromEnum(target), .generation = LOCAL_REF_GEN };
}
```

### 15.4 Value storage + reuse decision

Component values are stored as **untyped canonical-LE bytes** (`Cell = image.KindRecord`), not a typed representation — uniform regardless of component count, serializable for free (the bytes *are* the wire form), and it reuses the codec for free. This is the same fork (`F3`, "uniform serializable record") the command buffer already chose.

- **Encode (author time):** `b.add(local, C, v)` runs `serialize.writeValue` into an arena buffer and asserts the encoded length equals `serializedSizeOf(C)`. Type safety is at this front door (`comptime C` + `value: C`), exactly like `CommandBuffer.add`.
- **Decode + set (instantiate):** reuse the **one** `kind_id → type → readValue → add` dispatch table — but with a *split error policy*. `mutation.applyCommand` stays the trusted path (`readValue(...) catch unreachable`, mutation.zig:83). Untrusted content MUST NOT reach that `unreachable`.
- **GRAFT — `mutation.applyAdd` slice extraction (ai-authoring-first / Judge #2 #3):** extract the dispatch loop into a slice-based core with an explicit error policy, so content sets a cell from a `[]const u8` **without** the inline `[maxPayload(R)]u8` Command-buffer memcpy round-trip, and the trusted/untrusted split is single-sourced:

```zig
// in mutation.zig — ONE dispatch table, TWO error policies. `Trust.content` returns error.Corrupt on a
// bad cell (a corrupt exhaustive-enum tag IS rejected by readValue, serialize.zig:161-165); `Trust.kernel`
// keeps `catch unreachable` for the command-buffer drain (a kernel-encoded payload cannot fail).
pub const Trust = enum { kernel, content };
pub fn applyAdd(comptime R: type, w: *World(R), gpa: Allocator, e: Entity, kind_id: u16,
                bytes: []const u8, comptime trust: Trust) (if (trust == .content) serialize.Error else error{})!void {
    inline for (R.Components) |C| if (C.kind_id == kind_id) {
        var rd = serialize.ByteReader{ .bytes = bytes };
        const v = switch (trust) {
            .kernel => serialize.readValue(C, &rd) catch unreachable,
            .content => try serialize.readValue(C, &rd),
        };
        w.add(e, C, v);
        return;
    };
    // unknown kind_id: deterministic no-op (D2), identical to applyCommand
}
```

`applyCommand`'s `.add/.set` arm now calls `applyAdd(R, w, gpa, c.entity, c.kind_id, c.payload[0..c.payload_len], .kernel)`. `content.instantiate` calls it with `.content`. The untrusted instantiate path **provably never reaches mutation.zig:83**.

**Reuse decision (matches all three judges' "reuse fidelity" axis):** alias `image.KindRecord` → `Cell` and `image.KindFp` → the fingerprint (no substrate fork; drift-free). **Do not** reuse `image.RowRecord` (it carries a real `Entity` + `u64 mask` — World-image state a template must not have) or the full `Image` (gens/outs/rng/tick). `Node{local, cells}` is the honest, lighter template row.

### 15.5 Deterministic instantiate / loadLevel — why the loaded-World hash is pinnable

```zig
pub const Error = error{ BadMagic, UnsupportedFormat, SchemaMismatch, Corrupt, BadPatch } || serialize.Error || Allocator.Error;

/// Instantiate one prefab into an EXISTING world; returns the caller-owned local->real map. Spawns nodes
/// in ascending-local order, applies ref-patches, sets cells via applyAdd(.content). Untrusted-safe.
pub fn instantiate(comptime R: type, w: *World(R), gpa: Allocator, pf: *const Prefab(R)) Error![]Entity;

/// Build a FRESH World from a Level — the §11 "initial World / proc-gen world / fork-injected content".
pub fn loadLevel(comptime R: type, gpa: Allocator, lvl: *const Level(R)) Error!World(R);
```

Deterministic spawn order (the heart of the pin):
1. `World(R).init(lvl.rng_seed); w.tick = lvl.tick0; w.schema_version = lvl.schema_version`.
2. Process `placements` in **array order**, then `loose` nodes in **array order**. For each placement, spawn its nodes in **ascending local-id order**. Each `w.spawn(gpa)` calls `entities.alloc` — the FIFO/dense allocator (entity.zig) that, from a fresh `World.init` (empty free queue, never frees during load), hands out `index = generation.items.len` at generation 0 as a **pure function of the spawn count**. So `map[local]` is a deterministic function of `(placement order, per-prefab node count)` alone — no addresses, no hash iteration.
3. The map is a flat `[]Entity` indexed by dense local id. **Spawn-all-before-patch-and-set** is required so a forward ref (A points at B authored later) resolves: B's handle is already in the map.
4. Per instance: apply `overrides` (replace named cells), then ref-patches (rewrite local→`map[target]`), then set every cell via `applyAdd(R, w, gpa, map[local], cell.kind_id, patched_bytes, .content)`.

**Pinnability:** the allocator is a pure function of the spawn sequence; cells are canonical-LE bytes; patches write the same canonical `Entity` encoding; component-set goes through the canonical `add`. So the loaded World's `digest()` (XXH64 over `serialize.writeWorld`'s canonical order — already cross-arch-proven by `zig build cross`) is a fixed constant for a given Level. `writeWorld`'s argsort-on-`entity.index` row order makes the hash invariant to physical row order; instantiation never despawns, so rows are already in index order.

### 15.6 Canonical serialization + authoring surface + hostile-hardened decode

Distinct magics so a prefab/level can never be confused with a World image (no `GKZ1` collision surface):

```zig
pub const PREFAB_MAGIC = [4]u8{ 'G', 'K', 'Z', 'P' };
pub const LEVEL_MAGIC  = [4]u8{ 'G', 'K', 'Z', 'L' };
pub const CONTENT_VERSION: u16 = 1;

pub fn writePrefab(comptime R: type, gpa: Allocator, sink: anytype, pf: *const Prefab(R)) !void;
pub fn readPrefab (comptime R: type, gpa: Allocator, reader: *serialize.ByteReader) Error!Prefab(R);
pub fn writeLevel (comptime R: type, gpa: Allocator, sink: anytype, lvl: *const Level(R)) !void;
pub fn readLevel  (comptime R: type, gpa: Allocator, reader: *serialize.ByteReader) Error!Level(R);
```

Prefab layout (all ints LE via `serialize.putInt`, reusing `ByteSink`):
```
PREFAB_MAGIC(4) | version u16 | kind_count u16 (<=64 else Corrupt) | fingerprint[kind_count]{kind_id u16, size u32}
node_count u32
  per node (ascending local): local u32 | cell_count u16 | per cell { kind_id u16 } (ascending) ; then cell bytes concatenated (width per fingerprint)
patch_count u32
  per patch (ascending (node,kind_id,byte_offset)): node u32 | kind_id u16 | byte_offset u32 | target u32 | path_len u16 | path[path_len] u16
```
`writeLevel` = `LEVEL_MAGIC | version | schema_version u32 | tick0 u64 | rng_seed u64 | prefab_count u32 | each writePrefab-body | placement_count u32 | each {prefab_index u32, override_count u32, each {local u32, kind_id u16, cell bytes}} | loose_count u32 | each node-body`. `readLevel` returns an arena-owning Level.

Hostile-hardened decode (modeled exactly on `image.decode`, which reads untrusted bytes):
- magic mismatch → `BadMagic`; version mismatch → `UnsupportedFormat`.
- fingerprint validated against `R`: each `kind_id` registered AND `size == serialize.serializedSizeOf(component)` else `SchemaMismatch`; an unregistered kind → `SchemaMismatch`; `kind_count > 64` → `Corrupt` (mask-rank ceiling, no shift overflow).
- all counts are attacker-controlled → **parse incrementally**, appending to an `ArrayList` only after a full record is read, so a hostile count can never drive a pre-alloc (image.decode lines 119-166). Cell bytes read as `fingerprint[kind].size` via `reader.readSlice` (`Truncated` on short input).
- a patch whose 8-byte `Entity` write would run past the cell width, or whose `node`/`target`/`kind_id` is out of range, or a duplicate `(node, kind_id, byte_offset)`, or a cell kind appearing twice in one node, or `cell_count > kind_count` → `Corrupt`/`BadPatch` **before any write**.
- **GRAFT — decode-time legal-offset validator (purist self-assessment + Judge #1/#2):** at `readPrefab`, every patch's resolved `byte_offset` MUST be a member of the comptime-computed **set of legal `Entity`-typed leaf offsets** for that `kind_id` (the reflection-over-`Entity`-fields walk, used purely as a guard, never for rewrite). A persisted prefab whose component fields were reordered (same total width, different layout) becomes `BadPatch`/`SchemaMismatch` instead of a silent wrong-handle write — the one residual hole the loaded-World-hash pin provably cannot catch.
- **GRAFT — persisted `field_path` (robustness-serialization, open Q #1):** for the **on-disk** format, a patch stores `(kind_id, field_path: []const u16)` and resolves it to `byte_offset` at decode against the **live** registry. This is migration-robust: after a §12 field reorder the path still names the right leaf. The flat `byte_offset` is the **in-memory/runtime-built** form (which cannot go stale); `writePrefab` emits both, `readPrefab` prefers `field_path` when present and cross-checks it against the legal-offset set. This makes the §12 migration story correct rather than silently-miswriting.

**Authoring surface (the §11 thesis — "the AI authors content as data the same way it authors systems as code"):** the **runtime builder is primary** (it must work for proc-gen runtime data, which literals/ZON cannot); a comptime-literal `Prefab(R)` value is also valid. Both are Zig source the compiler checks and git diffs — systems are Zig functions, content is a Zig builder program or literal. **ZON is a declared non-goal for v1** (the builder + canonical bytes already give git-diffable structured data; a ZON front-end is additive convenience on a defined seam, not kernel determinism — it would just drive the same builder).

### 15.7 Proc-gen builder + example

```zig
pub fn Builder(comptime R: type) type {
    return struct {
        const Self = @This();
        arena: std.heap.ArenaAllocator,
        nodes: std.ArrayList(Node) = .empty,
        patches: std.ArrayList(RefPatch) = .empty,
        pub fn init(gpa: Allocator) Self;
        pub fn deinit(self: *Self) void; // frees the arena if not yet build()'d
        pub fn addEntity(self: *Self) Allocator.Error!Local;            // dense local id = nodes.len
        pub fn add(self: *Self, l: Local, comptime C: type, v: C) Allocator.Error!void; // encodes via the codec
        pub fn ref(self: *Self, l: Local, comptime C: type, comptime field: []const u8, target: Local) Allocator.Error!void; // comptime byte_offset + field_path of the named Entity field
        pub fn build(self: *Self) Prefab(R); // sorts cells asc kind_id, patches canonical; transfers arena ownership
    };
}
pub fn LevelBuilder(comptime R: type) type {
    return struct {
        pub fn init(gpa: Allocator, seed: u64) @This();
        pub fn addPrefab(self: *@This(), pf: Prefab(R)) Allocator.Error!u32; // returns prefab_index
        pub fn place(self: *@This(), prefab_index: u32) Allocator.Error!void;
        pub fn override(self: *@This(), prefab_index_placement: usize, l: Local, comptime C: type, v: C) Allocator.Error!void;
        pub fn build(self: *@This()) Level(R);
    };
}
```

Seeded `genLevel` shape — content-code → content-data → deterministic World (RNG is the kernel's counter-based keyed `rng`, integer-only, no host entropy):

```zig
fn genDungeon(comptime R: type, gpa: Allocator, seed: u64) !Level(R) {
    var prng = rng.RngRoot{ .seed = seed };
    var lvl = LevelBuilder(R).init(gpa, seed);
    const n_rooms: u32 = 4 + @as(u32, @intCast(rng.draw(&prng, .{0}) % 5));
    var i: u32 = 0;
    while (i < n_rooms) : (i += 1) {
        var b = Builder(R).init(gpa);
        const room = try b.addEntity();
        const door = try b.addEntity();
        try b.add(room, Position, .{ .x = Fixed.fromInt(@intCast(rng.draw(&prng, .{i}) % 64)), .y = Fixed.ZERO });
        try b.add(door, Door, .{ .owner = localRef(room), .locked = (rng.draw(&prng, .{ i, 1 }) & 1) == 1 });
        try b.ref(door, Door, "owner", room); // door.owner -> the room, resolved at load
        const pi = try lvl.addPrefab(b.build());
        try lvl.place(pi);
    }
    return lvl.build();
}
// genDungeon(gpa, 7) -> a Level VALUE (runtime data); loadLevel instantiates it; its digest is a fixed
// pin for seed 7. Same seed => byte-identical Level bytes => byte-identical loaded World, across modes+arches.
```

The builder is used identically for hand-authored literals and generators: the format works for runtime-built data because there is no literal-only path.

### 15.8 Asset-handle contract (headless-first)

An asset handle is a **game-side newtype around a fixed-width int** — not a kernel type. The kernel sees only the integer leaf; it has no asset table, no resolver, no dereference path.

```zig
// game-side, NOT in the kernel:
pub const AssetHandle = enum(u64) { none = 0, _ }; // serializes as its u64 tag
const Sprite = struct { mesh: AssetHandle, tint: u32, pub const kind_id: u16 = 30; };
```

`enum(u64)` passes `registry.assertSerializable` (its tag is a fixed-width int, not float/pointer), serializes LE via `writeValue`'s `.@"enum"` arm, is cross-arch stable, and is **not** an `Entity` — so the explicit-patch machinery never touches it (no patch names it; with reflection-at-rewrite a u64 handle aliasing `Entity`'s 8-byte shape would be a hazard — here it is structurally impossible). Systems may copy/compare it (`== .none`); the kernel never maps it to memory. That **is** the contract: referenced by handle, not required for the sim to run. Asset **import** (real art → handles) is a §14 seam / §15 non-goal — not built; only the handle-as-data contract is.

### 15.9 Scope boundaries (v1 met / declared seam / §14-§15 non-goal)

**v1 — MET (built, gated):** Prefab + Level types; runtime `Builder` + comptime-literal authoring; canonical `writePrefab/readPrefab/writeLevel/readLevel` with hostile-hardened decode; **world-construction-time** instantiation (`loadLevel` builds a fresh World; `instantiate` places into an existing one — refs resolved immediately); seeded proc-gen producing runtime Level data; asset-handle-as-data + headless run; the full gate set.

**Declared SEAM (genuinely out of §11's remit, named integration point — NOT relabeled-mandated work):** *mid-tick prefab spawning by a system.* §11 requires prefabs be "instantiable many times" and compose initial Worlds — v1 fully meets that at construction time. Mid-tick instantiation is a §4 command-buffer concern: a prefab lowers to a deterministic sequence of `cmdbuf.Command(R)` (spawn × N, then `add` cells, then patch-resolved adds), with local→real resolution deferred to the end-of-tick drain (the map is built as the deferred spawns execute, in `(system_id, seq)` order, then patches applied). v1 does not build the deferred cross-ref fixup because *how a buffer references not-yet-spawned entities* is a command-buffer design question v1 must not pre-judge. The substrate is already shared (cells ARE command payloads), so this is a when-not-what extension.

**§14 SEAM / §15 NON-GOAL (never built):** asset *import* (real art → handles) — §14 "offline, not on a sim path"; §15 "no asset pipelines." Only the handle-as-data contract is in scope. **ZON authoring front-end** — additive convenience over the canonical format; the builder + literals already satisfy "structured, diffable data," so ZON is a non-goal for v1, not deferred-mandated.

### 15.10 Open questions — all resolved

| # | Question | Decision |
|---|---|---|
| 1 | Override expressiveness (replace vs add/remove a cell) | **Replace-only** in v1 (the minimal diffable primitive; whole-cell replace by `(local, kind_id)`). Add/remove changes the node's mask/cell-set; expressible but widens the format — candidate v1.1, not blocking §11. |
| 2 | Does `loadLevel` return per-placement local→real maps / named anchors? | `instantiate` **returns** its map; `loadLevel` returns only the World in v1. A named-anchor table (author-assigned name → handle) reintroduces a string/id table into the determinism-critical core — **deferred to a v1.1 design pass**, not built (avoids bloating the pin). |
| 3 | Nested prefabs (a prefab placement inside a prefab) | **Not in v1.** Levels compose prefabs; prefabs do not nest. Cross-prefab refs would need a level-global local space — a clean recursive extension, flagged, unbuilt. |
| 4 | Fold prefab/level bytes into the World-image stream | **No.** Keep distinct magics (`GKZP`/`GKZL` vs `GKZ1`); no confusion surface. A future "bake a level into a startable World image" path can hand `Cell`s straight to `image.encode` (the alias buys this for free) without merging formats. |
| 5 | Persisted patch staleness across a §12 field reorder | **Resolved by the `field_path` graft (§15.6):** persisted patches carry `(kind_id, field_path)` resolved at decode against the live registry; flat `byte_offset` is in-memory-only. |
| 6 | `field_path` array-element refs (`[4]Entity`) | Supported: a path element indexes an array child by element width; the comptime offset helper recurses structs and indexes arrays (the `ref("links.2", …)` form). |

### 15.11 Determinism-hazards table

| # | Hazard | Eliminating mechanism |
|---|---|---|
| 1 | Spawn-order nondeterminism | Spawn ascending dense local-id within each instance; placements then loose nodes in array order. From a fresh `World.init` the FIFO allocator hands out `index = generation.items.len` at gen 0 as a pure function of spawn count. Map is a flat `[]Entity`, never a hashmap — no map-iteration leak. |
| 2 | Ref-rewrite order | Order-independent by construction: a duplicate `(node, kind_id, byte_offset)` is rejected at build AND decode; each patch overwrites a disjoint 8-byte window over a fully-populated map. Canonical patch sort makes the serialized form unique. |
| 3 | Float / pointer / usize in values | Impossible: cells are produced only by `serialize.writeValue` (`putInt` → `assertFixedWidth` rejects usize/isize at comptime); `registry.assertSerializable` rejected `.float` (D7) / `.pointer` (D8) at registry construction. AssetHandle is `enum(u64)`, explicit. |
| 4 | Untrusted-decode panic / OOB | `readPrefab/readLevel` mirror `image.decode`: validate-before-alloc, incremental count-driven parse, fingerprint width/kind checked (`SchemaMismatch`), patch bounds checked before any write (`BadPatch`), `readValue`'s corrupt-enum guard → `Corrupt`. Instantiate uses `applyAdd(.content)` → `error.Corrupt`, **never** reaches `mutation.zig:83`'s `catch unreachable`. |
| 5 | Cross-arch / endianness | All ints via `serialize.putInt` (explicit LE loop), all values via `writeValue`; no raw struct memory, no usize on the wire. `Local`/offsets/ids are explicit `enum(u32)`/`u16`/`u32`. Loaded-World hash rides `serialize.writeWorld` — the cross gate already proves it. |
| 6 | Instance cross-contamination | Each `instantiate` call gets its own local→real map; patches resolve only within that map. Two instances of one prefab yield disjoint, internally-consistent entity sets (multi-instance ref-isolation gate). |
| 7 | Silent same-width field-reorder miswrite | **Decode-time legal-`Entity`-leaf-offset validator** (graft) → `BadPatch`; persisted `field_path` resolves against the live registry; **comptime Gate #8** (next row) makes the authored-type case a compile failure. The one hazard the hash pin cannot catch, now closed three ways. |
| 8 | Offset-helper vs codec drift | **GRAFT — comptime Gate #8 (reuse-minimal, Judge #1/#2/#3 unanimous):** a comptime assert per component that the ref offset-helper's `byte_offset` for field F equals the position `serialize.writeValue` emits F at. Implemented as **one offset authority** — the helper calls the same recursion `serializedSizeOf` uses, so there is a single traversal, not two that must stay in lockstep. Converts the silent wrong-handle bug into a build failure. |
| 9 | Allocator high-water on `instantiate` into a populated world | `loadLevel` starts from `World.init` (empty free queue), so spawns are pure extension, never recycle. `instantiate` into a populated world continues from its high-water mark deterministically; the returned map captures the actual handles, so the caller never assumes `index == local`. |
| 10 | Missed/unresolved ref | `localRef` sentinel generation `0xFFFF_FFFF` is odd → `isLive` false → a loud dead handle (fail-closed), never a plausible live ref (graft). |

### 15.12 Gate test list (folded into `zig build test` 3-mode + `zig build cross` 4-arch)

All gates live in `content.zig` tests (Debug/ReleaseSafe/ReleaseFast) plus pins added to the root suite the cross matrix re-runs under qemu (aarch64/s390x/arm/mips), mirroring `migrate/gate.zig` and `step_par_gate.zig`. Pin-bearing runs set `has_side_effects = true`.

1. **Pinned loaded-World hash.** A fixed reference `Level` (instances + refs + an `AssetHandle`) → `loadLevel` → `world.digest().hash == 0x<CONST>` and `.crc == 0x<CONST>`. THE determinism pin; re-checked unchanged under all 3 modes and all 4 arches (the s390x/mips big-endian runs are the decisive witnesses).
2. **Round-trip byte-identity.** `writePrefab(pf) → bytes A → readPrefab → writePrefab → bytes B`; `expectEqualSlices(A, B)`. Same for level. Plus `loadLevel(readLevel(writeLevel(lvl))).digest == loadLevel(lvl).digest`. Proves canonical ordering is a fixed point.
3. **Multi-instance ref isolation.** Instantiate the same 2-node prefab (A refs B) twice into one World; assert the two A-handles differ, the two B-handles differ, `inst0.A.ref == inst0.B`, `inst1.A.ref == inst1.B`, `inst0.A.ref != inst1.B`. The semantic test that catches a wrong-handle resolution.
4. **Proc-gen determinism.** `genDungeon(7)` twice → byte-identical Level bytes AND equal loaded digests; `genDungeon(7).digest == pinned const` (cross-mode + cross-arch); `genDungeon(7) != genDungeon(8)` (seed drives content).
5. **Asset-handle headless run.** Load a Level carrying `Sprite{mesh}` with NO asset table; `runScheduled` N ticks; assert it completes and the per-tick hash stream == a pinned sequence. Companion: changing only `mesh` changes the hash (it is hashed state) but not the structural step outcome when no system reads it. The headless-first thesis as an executable gate.
6. **Hostile decode battery (never panics).** truncated → `Truncated`; bad magic → `BadMagic`; bad version → `UnsupportedFormat`; width-mismatched fingerprint → `SchemaMismatch`; `kind_count = 65` → `Corrupt`; patch offset past cell end → `BadPatch`; out-of-range `target`/`node` → `BadPatch`; duplicate `(node,kind,offset)` → `Corrupt`; corrupt enum tag in a cell → `Corrupt`; a patch offset not in the legal-`Entity`-leaf set → `BadPatch`. Each `expectError`; wire into the §9 VOPR corpus as a decode-fuzz target.
7. **GRAFT — OOM-injection sweep (robustness-serialization).** `std.testing.FailingAllocator` over `decode → validate → instantiate`, asserting leak/double-free freedom of the arena `errdefer` path (the arena-owning `readPrefab/readLevel/Builder.build` partial-construction hazard the other gates do not exercise).
8. **Comptime Gate #8.** A comptime/test assert per component that the ref offset-helper agrees with `writeValue`'s emit position for each `Entity` field (single offset authority).
9. **Cross-build + cross-arch.** Pins 1/4/5 + Gate #8 added to the root test module `zig build cross` re-runs on {aarch64, s390x, arm, mips} = the {32,64}×{LE,BE} matrix. A divergent constant on any arch/mode fails loudly.

### 15.13 Ordered implementation checklist

1. **`mutation.zig`:** extract `applyAdd(R, w, gpa, e, kind_id, bytes, comptime trust)` from the `applyCommand` `.add/.set` arm; route `applyCommand` through it with `.kernel`. Re-run the mutation tests (must stay green — pure refactor).
2. **`src/content.zig`:** `Local`, `Cell` (alias `image.KindRecord`), `Node`, `RefPatch`, `Prefab(R)`, `Level(R)`, `Placement`, `Override`, `localRef`, `LOCAL_REF_GEN`, magics, `CONTENT_VERSION`, `Error`.
3. Comptime offset authority: `entityLeafOffsets(comptime C) []const u32` (the legal-`Entity`-leaf set) and `fieldOffset(comptime C, comptime path)` — **both** calling the same `serializedSizeOf` recursion. Gate #8 (comptime assert) sits here.
4. `Builder(R)` / `LevelBuilder(R)`: `addEntity/add/ref/build` (encode via codec, seed `localRef` sentinels, emit canonical patches + `field_path`).
5. `instantiate` + `loadLevel`: spawn-all → overrides → patch → `applyAdd(.content)`; return the flat map.
6. `writePrefab/readPrefab/writeLevel/readLevel`: canonical write (nodes asc local, patches asc `(node,kind,offset)`); hostile-hardened decode with the legal-offset validator + `field_path` resolution.
7. `AssetHandle`/`Sprite` + `genDungeon` example in the test module.
8. Gates 1–8 in `content.zig`; register `content` in `root.zig`.
9. **Recompute pins** (a guarded `dumpPin` run outside `--listen`), freeze the constants into gates 1/4/5.
10. Add pins 1/4/5 + Gate #8 to the root suite; run `zig build test` (3 modes) then `zig build cross` (4 arches) — all green.

### 15.14 Residual risks

- **Anchor addressability (open Q #2).** v1 has no named-anchor table, so a caller wanting "the player" after `loadLevel` must derive it from placement/local arithmetic or use `instantiate` directly and keep the returned map. A v1.1 anchor table is the most likely first feature request; kept out of v1 to protect the pin from a string/id table.
- **Persisted-prefab migration.** The `field_path` form makes a reordered-field reload correct, but a §12 op that *renames* or *retypes* a field (not just reorders) still needs the migration chain; v1 does not run `readPrefab → migrate.apply → instantiate`. Wiring that composition (clean — `Cell` is `image.KindRecord`) is a v1.1 decision, flagged.
- **Mid-tick spawning is a seam, not built.** Construction-time §11 is complete; the deferred-resolution semantics interact with the §4 drain order and are out of §11's remit. If a future system needs runtime prefab spawning, the `cmdbuf` lowering is specified above but unproven.
- **Override granularity.** Whole-cell replace only; a field-level override (reusing the patch machinery for value-not-handle edits) is unbuilt — sufficient for the AI-authoring use case in v1, revisit if proc-gen wants finer diffs.
- **u32 local-id / u16 cell-count caps.** A single prefab is bounded at 4B nodes / 65535 cells per node — far beyond hand-authored or reasonable proc-gen prefabs; a generated mega-world splits into placements (the Level composition handles it). The split point is an ergonomics convention, not enforced.

### 15.15 Phase 10 notes (from the adversarial review — 11 confirmed / 0 refuted; the 2 HIGH + 4 MEDIUM + substantive LOWs fixed; the AS-BUILT record)

This subsection is authoritative where it differs from §15.1–§15.14 (which is the panel's design intent verbatim).

1. **HIGH — `field_path` was never built; demoted to a declared v1.1 non-goal (hard-rule reconciliation).** §15.2/§15.6/§15.10-Q5/Q6/§15.11-#7/§15.13 describe a persisted `field_path` (+ a `Builder.ref(field-path)` method and a `fieldOffset` helper) as built. The code has none: `RefPatch` is `{node, kind_id, byte_offset, target}`, and the builder derives patches by walking a value's `Entity` leaves for the `localRef` **sentinel** (gen `0xFFFFFFFF`). This is honest to satisfy: **SPEC §11 (a)(b)(c) do NOT require `field_path`** — it is a §12-*prefab-migration* robustness graft, and prefab migration is itself a v1.1 item (§15.14 residual #2). The fail-closed safety §15.6/§15.11-#7 attribute partly to `field_path` is delivered in full by the **decode-time legal-offset validator** (`legalEntityOffset`, built) + **comptime Gate #8** (built): a reordered-field persisted prefab is rejected as `BadPatch` (safe), it is simply not auto-repaired. v1.1 may add `field_path` when prefab↔migration composition lands.
2. **HIGH — Builder re-set left stale ref-patches (real bug, fixed).** `insertCell` replaces a re-set cell, but `add` only appended patches and `build` only sorted — so re-setting a component left the prior set's patches, which would clobber the new value (or duplicate a `(node,kind,offset)` that `readPrefab` rejects as `Corrupt`). Fixed: `add` now retain-filters `self.patches`, dropping any `(node==l, kind_id==C.kind_id)` before emitting the current set's patches. Test: "re-setting a component replaces its cell AND drops the stale ref-patch".
3. **MEDIUM — override-vs-ref semantics decided + enforced.** An `Override` now supplies LITERAL final bytes: `instantiate` applies an overridden cell verbatim and SKIPS the ref-patch rewrite for it (an override fully replaces the cell, including any managed ref). Documented; test: "an override is literal — its managed ref is NOT resolved".
4. **MEDIUM — the loose-node path is now reachable + witnessed.** Added `LevelBuilder.addLoose(prefab)` (copies a no-patch prefab's nodes as standalone loose entities; dense local ids). A content.zig test round-trips a level with loose nodes through `writeLevel`/`readLevel` and instantiates it (so the loose write/decode/instantiate path runs in the 3-mode AND cross-arch matrix); the false "+ one loose entity" comment in content_gate was corrected.
5. **MEDIUM — hostile-decode battery expanded.** Added `expectError` cases beyond bad-magic/truncation: corrupt version → `UnsupportedFormat`; corrupt fingerprint width → `SchemaMismatch`; illegal patch `byte_offset` (not an `Entity` leaf) → `BadPatch`; out-of-range `target` → `BadPatch`; duplicate `(node,kind,offset)` → `Corrupt` (via literal Prefabs whose write does not validate).
6. **LOW (fixed):** content sorts now route through the pinned `sort.zig` wrapper (not `std.mem.sort`); `instantiate` re-validates each patch offset via `legalEntityOffset` (so a hand-built — not just decoded — Prefab cannot silently miswrite); the `Level` single-arena invariant (contained prefabs have `arena=null`) is documented on `Level.deinit`; Gate #8 extended to a multi-`Entity` struct + a `[N]Entity` array, plus a "two distinct local refs resolve to distinct correct handles" instantiate test (witnesses the offset-12 / array-element arithmetic — the exact silent-wrong-handle case the design flags).
7. **As-built builder API:** `Builder{addEntity, add, build}` (no `ref()` — the sentinel-walk derives patches); `LevelBuilder{init, addPrefab, place, addLoose, build}`. Overrides are supported as `Placement.overrides` DATA + `instantiate` (tested); a `LevelBuilder.placeWith(overrides)` convenience is a trivial follow-on, not built.
8. **LOW acknowledged, not changed:** the C6 OOM sweep is arena-granular (the arena amortizes decode/instantiate allocations), so it fingerprints arena-ownership leak-freedom rather than per-logical-allocation; arena ownership is the model, so this is sufficient.

Gate target as-built: **+13 content gate tests** folded into the base suite (6→ the content.zig unit/round-trip/ref/hostile/loose battery; the C1–C6 pinned cross-build + cross-arch witnesses in content_gate.zig). Pins `PIN_REF_LEVEL`/`PIN_REF_CRC`/`PIN_GEN7`/`PIN_HEADLESS_STREAM` hold across Debug/ReleaseSafe/ReleaseFast and all four cross arches.
