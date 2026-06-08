//! The WASM C-ABI surface for the roguelike — the §14 VIEW SEAM, realized in the browser. A JS host owns
//! the linear memory and the render loop; this module owns the deterministic sim. The host calls `rl_init`
//! once, then `rl_step` per frame, then reads live entities out of `rl_buf` to draw them. Nothing here
//! touches `std.Io`, threads, the clock, or syscalls — so the SAME pure sim core that runs natively
//! compiles to `wasm32`/`wasm64-freestanding` and runs identically in a sandbox (its content digest is
//! bit-identical to a native run; wasm32 is a 32-bit little-endian target, like the gated `arm`).
//!
//! Build: `zig build wasm` (freestanding) → zig-out/web/roguelike.wasm. See web/index.html for the host.

const std = @import("std");
const gkz = @import("gkz");
const game = @import("game.zig");
const R = game.R;

// Freestanding wasm is single-threaded; `wasm_allocator` is a real free-list allocator over the module's
// linear memory (grown on demand), so `step`'s per-tick clone/free reclaims correctly.
const alloc = std.heap.wasm_allocator;

var world: gkz.World(R) = undefined;
var ready: bool = false;

/// (Re)seed the world. Call once at startup, or again to restart with a different seed.
export fn rl_init(seed: u32) void {
    if (ready) world.deinit(alloc);
    ready = false;
    world = game.seedWorld(alloc, seed) catch return;
    ready = true;
}

/// Advance one tick (the pure `step`). No-op if uninitialized or on OOM (a wasm host can grow memory).
export fn rl_step() void {
    if (!ready) return;
    const next = gkz.step(R, alloc, world, gkz.input.EMPTY, &game.systems) catch return;
    world.deinit(alloc);
    world = next;
}

/// The current tick number.
export fn rl_tick() u64 {
    return if (ready) world.tick else 0;
}

/// The per-tick content hash — the determinism witness (a wasm run equals a native run).
export fn rl_digest() u64 {
    if (!ready) return 0;
    const d = world.digest(alloc) catch return 0;
    return d.hash;
}

// A static scratch buffer the host reads: live entities as flat i32 quads [team, x, y, hp]. The host gets
// its address via `rl_buf` and reads `rl_live()*4` ints out of the module's exported `memory`.
const MAX_DRAW = 256;
var scratch: [MAX_DRAW * 4]i32 = undefined;

/// Address of the scratch buffer (for the host to construct an Int32Array view over `memory`).
export fn rl_buf() [*]i32 {
    return &scratch;
}

/// Fill `scratch` with the live entities; return the count (≤ MAX_DRAW). Read-only observation
/// (`world.iterate`/`getConst` under the hood) — cannot perturb the sim.
export fn rl_live() u32 {
    if (!ready) return 0;
    var rows: [MAX_DRAW]game.Row = undefined;
    const n = game.liveRows(&world, &rows);
    var i: usize = 0;
    while (i < n and i < MAX_DRAW) : (i += 1) {
        const r = rows[i];
        scratch[i * 4 + 0] = @intCast(r.team);
        scratch[i * 4 + 1] = r.pos.x;
        scratch[i * 4 + 2] = r.pos.y;
        scratch[i * 4 + 3] = r.hp;
    }
    return @intCast(i);
}

/// The arena half-extent (the grid is [-EXTENT, EXTENT] on each axis) — lets the host size its canvas.
export fn rl_extent() i32 {
    return game.ARENA;
}
