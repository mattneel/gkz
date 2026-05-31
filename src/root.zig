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

// --- Phase 2: systems, queries, scheduling, command buffers (SPEC §4) ---
pub const query = @import("query.zig");
pub const Query = query.Query;
pub const Read = query.Read;
pub const Write = query.Write;
pub const With = query.With;
pub const Without = query.Without;

pub const command_buffer = @import("command_buffer.zig");
pub const Command2 = command_buffer.Command;
pub const CommandBuffer = command_buffer.CommandBuffer;

pub const simctx = @import("simctx.zig");
pub const SimCtx = simctx.SimCtx;

pub const schedule = @import("schedule.zig");
pub const Sys = schedule.Sys;
pub const system = schedule.system;
pub const Schedule = schedule.Schedule;

pub const step_mod = @import("step.zig");
pub const step = step_mod.step;
pub const stepRec = step_mod.stepRec;
pub const runScheduled = step_mod.runScheduled;

// --- Phase 3: events & causality / provenance (SPEC §5) ---
pub const event = @import("event.zig");
pub const EventId = event.EventId;
pub const CauseToken = event.CauseToken;
pub const Event = event.Event;

pub const event_log = @import("event_log.zig");
pub const EventLog = event_log.EventLog;

pub const recorder_mod = @import("recorder.zig");
pub const Recorder = recorder_mod.Recorder;

pub const EventEmitter = simctx.EventEmitter;

// --- Phase 4: the VOPR — deterministic simulator / fuzzer-debugger (SPEC §9) ---
pub const vopr = @import("vopr/vopr.zig");
pub const Oracle = @import("vopr/oracle.zig").Oracle;
pub const Defect = @import("vopr/oracle.zig").Defect;
pub const Generator = @import("vopr/generator.zig").Generator;
pub const sweep = vopr.sweep;

pub const snapshot_mod = @import("snapshot.zig");
pub const Snapshot = snapshot_mod.Snapshot;
pub const snapshot = snapshot_mod.snapshot;
pub const restore = snapshot_mod.restore;

pub const replay_mod = @import("replay.zig");
pub const replay = replay_mod.replay;

// --- Phase 5: introspection & relational query surface (SPEC §7) ---
pub const query_term = @import("query/term.zig");
pub const Value = query_term.Value;
pub const RelId = query_term.RelId;
pub const query_result = @import("query/result.zig");
pub const QueryResult = query_result.QueryResult;
pub const query_relations = @import("query/relations.zig");
pub const query_catalog = @import("query/catalog.zig");
pub const query_diverge = @import("query/diverge.zig");
pub const query_engine = @import("query/engine.zig");
pub const QueryEngine = query_engine.Engine;
pub const QuerySurface = query_engine.Query; // the wire-serializable request vocabulary
pub const reach = query_engine.reach;
pub const query_wire = @import("query/wire.zig");
pub const query_gate = @import("query/gate.zig");

// --- Phase 6: specifications, invariants & properties (SPEC §8) ---
pub const spec = @import("spec.zig");
pub const Invariant = spec.Invariant;
pub const Property = spec.Property;
pub const Metric = spec.Metric;
pub const Trace = spec.Trace;

// --- Phase 7: agent harnesses & evaluation (SPEC §10) ---
pub const agent = @import("agent.zig");
pub const Agent = agent.Agent;
pub const DeterminismClass = agent.DeterminismClass;
pub const ObsView = agent.ObsView;
pub const ExternalAgent = agent.ExternalAgent;

// --- Phase 8: schema migration & hot-reload (SPEC §12) ---
pub const migrate = @import("migrate.zig");
pub const Migration = migrate.Migration;
pub const Chain = migrate.Chain;
pub const migrateBytes = migrate.migrateBytes;
pub const migrateWorld = migrate.migrateWorld;
pub const migrateSnapshot = migrate.migrateSnapshot;
pub const validateMigration = migrate.validateMigration;

pub const reload = @import("reload.zig");
pub const SystemSet = reload.SystemSet;
pub const SystemSource = reload.SystemSource;
pub const reloadAt = reload.reloadAt;
pub const NativeLibSource = reload.NativeLibSource; // real std.DynLib loader for reloadable .so systems

// the runtime-systems path (drives dlopen'd or otherwise runtime-known system sets; the comptime
// `step`/`Schedule` twins)
pub const stepDynamic = step_mod.stepDynamic;
pub const runScheduledDynamic = step_mod.runScheduledDynamic;
pub const execOrderDynamic = schedule.execOrderDynamic;

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
    _ = query;
    _ = command_buffer;
    _ = simctx;
    _ = schedule;
    _ = step_mod;
    _ = snapshot_mod;
    _ = replay_mod;
    _ = event;
    _ = event_log;
    _ = recorder_mod;
    _ = @import("vopr/run.zig");
    _ = @import("vopr/generator.zig");
    _ = @import("vopr/inject.zig");
    _ = @import("vopr/oracle.zig");
    _ = @import("vopr/minimize.zig");
    _ = vopr;
    _ = query_term;
    _ = query_result;
    _ = query_relations;
    _ = query_catalog;
    _ = query_diverge;
    _ = query_engine;
    _ = query_wire;
    _ = query_gate;
    _ = spec;
    _ = agent;
    _ = migrate;
    _ = reload;
}
