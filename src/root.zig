//! gkz — a deterministic, fully observable, forkable simulation kernel.
//!
//! See SPEC.md for the design contract and PLAN.md for the implementation plan. The primary user is
//! an AI. The spine: `step : (State, Input) -> State` is a pure function and `State` (the World) is a
//! value — serializable, content-hashable, diffable — so record/replay, time-travel, forks, and
//! divergence detection are corollaries, not separate features.

const std = @import("std");

pub const entity = @import("entity.zig");
pub const Entity = entity.Entity;
pub const EntityAllocator = entity.EntityAllocator;

pub const registry = @import("registry.zig");
pub const Registry = registry.Registry;

pub const sort = @import("sort.zig");

pub const storage = @import("storage.zig");
pub const Table = storage.Table;

pub const rng = @import("rng.zig");
pub const RngRoot = rng.RngRoot;

pub const serialize = @import("serialize.zig");

pub const hash = @import("hash.zig");
pub const hashWorld = hash.hashWorld;

pub const world = @import("world.zig");
pub const World = world.World;

pub const input = @import("input.zig");
pub const Command = input.Command;
pub const Input = input.Input;

pub const mutation = @import("mutation.zig");

pub const step_mod = @import("step.zig");
pub const step = step_mod.step;
pub const System = step_mod.System;

pub const snapshot_mod = @import("snapshot.zig");
pub const Snapshot = snapshot_mod.Snapshot;
pub const snapshot = snapshot_mod.snapshot;
pub const restore = snapshot_mod.restore;

pub const replay_mod = @import("replay.zig");
pub const replay = replay_mod.replay;

/// Bring-up placeholder so the scaffold `main.zig` keeps compiling during Phase 1. Replaced by a real
/// kernel demo once `step`/`snapshot`/`replay` land.
pub fn printAnotherMessage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("gkz kernel — run `zig build test`.\n", .{});
}

test {
    std.testing.refAllDecls(@This());
    _ = entity;
    _ = registry;
    _ = sort;
    _ = storage;
    _ = rng;
    _ = serialize;
    _ = hash;
    _ = world;
    _ = input;
    _ = mutation;
    _ = step_mod;
    _ = snapshot_mod;
    _ = replay_mod;
}
