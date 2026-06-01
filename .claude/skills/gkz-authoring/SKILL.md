---
name: gkz-authoring
description: How to AUTHOR a gkz simulation in Zig — define a Registry + components, write systems (SimCtx + Query), emit events, declare specs (invariants + metrics), build a seed→World, and the determinism rules you must respect. Use when writing or editing the simulation core of a gkz game. Anchored on examples/roguelike/src/game.zig.
---

# Authoring a gkz sim

You write the deterministic core as Zig against `@import("gkz")`. Read `examples/roguelike/src/game.zig`
alongside this — it is the complete worked reference. Read `gkz-overview` first for the determinism rules.

## 1. Components + Registry

Components are plain structs with a unique `kind_id`. **Integers only** (no float on the sim path).

```zig
const gkz = @import("gkz");
pub const Position = struct { x: i32, y: i32, pub const kind_id: u16 = 1; };
pub const Health   = struct { hp: i32,        pub const kind_id: u16 = 2; };
pub const Team     = struct { id: u8,         pub const kind_id: u16 = 3; };

pub const R = gkz.Registry(.{ Position, Health, Team }); // the registry IS the schema
```

`R` is comptime CODE — it never crosses a wire; it parameterizes everything (`World(R)`, `Sys(R)`, …).

## 2. Systems — the rules

A system is `fn(ctx: *gkz.SimCtx(R), q: *gkz.Query(R, .{markers})) std.mem.Allocator.Error!void`. The
`Query` markers declare access: `gkz.Read(C)`, `gkz.Write(C)`, `gkz.With(C)`, `gkz.Without(C)`. The
declared access drives the conflict DAG (and what the system may touch).

```zig
fn drain(ctx: *gkz.SimCtx(R), q: *gkz.Query(R, .{ gkz.Write(Health) })) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(Health).hp -= 1;   // row.read(C) / row.write(C) / row.entity()
}
pub const systems = [_]gkz.Sys(R){ gkz.system(R, "drain", drain) };
```

Inside a system, `ctx` gives you **only** (the §4 restriction — no World, no allocator, no clock):
- `ctx.rng(entity_id, stream_id)` / `ctx.rngFixed(...)` — keyed, cursor-free pure RNG.
- `ctx.cmd.spawn/.despawn/.add/.set/.remove` — the command buffer: **deferred** structural / cross-entity
  edits, drained in canonical order AFTER all systems. Prefer this over direct `Write` for anything
  cross-entity, so every system reads one consistent start-of-tick snapshot and the result is
  order-independent.
- `ctx.emit(E, subject, value, causes)` / `ctx.emitS(E, subject, value)` — provenance events.

**Cross-entity logic** (e.g. "monsters seek the hero") can't reach other entities through a `Query` row.
Collect what you need into a bounded stack buffer in one pass, compute, then enqueue `ctx.cmd` edits —
systems get no allocator (see `seek`/`melee` in the example).

## 3. Events (provenance, §5) — pure side-output

Event types are structs with a `kind_id`. Emitting records to a side log **without changing the World or
its hash** (events are recorded only when a `Recorder` is attached; the hash is identical with/without).

```zig
pub const Damaged = struct { amount: i32, by: u32, pub const kind_id: u16 = 100; };
// in a system: _ = try ctx.emitS(Damaged, victim, .{ .amount = dmg, .by = attacker.index });
```

## 4. Specs — define "correct" and "fun" (§8)

- **Invariant** = correctness. Build from a built-in atom (`gkz.spec.atom.rangeI/fieldLE/...`) via
  `gkz.spec.invariant.fromAtom`, or write a custom atom (`gkz.spec.atom.Atom(R){ .name, .eval }`) — its
  `eval(*const World)` scans columns read-only and returns a witness. The example's `no_stacking`
  invariant (no two live entities on one tile) is a custom atom.
- **Metric** = a fun/balance proxy, integer-valued. `gkz.spec.metric.timeToCondition(atom_id)` measures
  the first tick an atom holds (e.g. "turns the hero survives" over a "hero is dead" atom).

```zig
pub const atoms = [_]gkz.spec.atom.Atom(R){ gkz.spec.atom.fieldLE(R, Health, "hp", HERO, 0) };
pub fn turnsSurvived() gkz.spec.metric.Metric(u64) { return gkz.spec.metric.timeToCondition(0); }
```

## 5. seed → World

The only nondeterminism ingress is `(seed, inputs)`. Provide a builder `fn(Allocator, u64) !World(R)` that
constructs the starting world deterministically from `seed` (the sweep/VOPR drivers call it per seed).
Spawn the hero/player FIRST so it is entity `{index 0, generation 0}` if your specs reference a fixed handle.

```zig
pub fn seedWorld(gpa: std.mem.Allocator, seed: u64) std.mem.Allocator.Error!gkz.World(R) {
    var w = gkz.World(R).init(seed);
    errdefer w.deinit(gpa);
    const hero = try w.spawn(gpa);            // {0,0}
    w.add(hero, Position, .{ .x = 0, .y = 0 });
    w.add(hero, Health, .{ .hp = 30 });
    // … seed-scattered monsters (place on DISTINCT tiles — or let the no_stacking invariant catch you) …
    return w;
}
```

## 6. Content as data (§11, optional)

Author entities/levels as diffable DATA, not code, with `gkz.content` (`Prefab`/`Level`/`Builder`/
`instantiate`/`loadLevel`). Procedural generation is then content-code emitting content-data.

## Common gotchas

- Pass the allocator explicitly; `errdefer w.deinit(gpa)` after `init`/`spawn` in your builders.
- `w.get(e, C)` returns `?*C` (needs `*World`); to observe read-only use `w.getConst` / `w.iterate(C)`.
- Don't move/`set` an entity the same tick it's despawned — gate movers on `hp > 0` (see `seek`).
- Anything that goes negative *transiently* (e.g. hp before the death system runs) is NOT a good
  invariant — pick properties true at every tick boundary.
