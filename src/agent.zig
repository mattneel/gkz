//! gkz §10 — agent harnesses & evaluation (PLAN.md Phase 7). Umbrella re-export mirroring spec.zig.
//!
//! An agent is a policy `observe(State) -> Input` on the SAME Input channel as a human. THE CONTRACT:
//! a learned/NN/LLM agent is an EXTERNAL NONDETERMINISTIC SOURCE — reproducibility comes from CAPTURING
//! what it emits at the Input boundary (`buildRun` → `Run.inputs`), NEVER from reproducing the agent;
//! replay/VOPR consume the captured stream via `asAgent` (a `.replay` agent over `scriptedGen`) and NEVER
//! re-invoke the source. NN inference is the PLAYER (behind the `ExternalAgent` fn-ptr seam), never the
//! WORLD (the sim path stays integer-deterministic). Mass evaluation has two regimes the eval layer makes
//! explicit via `DeterminismClass`: deterministic policies → bit-reproducible sweeps; `.external` →
//! run-level nondeterminism, captured per run (the `Run` is the revisit record).

const std = @import("std");

pub const observe = @import("agent/observe.zig");
pub const ObsView = observe.ObsView;

pub const core = @import("agent/agent.zig");
pub const Agent = core.Agent;
pub const DeterminismClass = core.DeterminismClass;
pub const isReproducible = core.isReproducible;
pub const asAgent = core.asAgent;
pub const replayGen = core.replayGen;

pub const policy = @import("agent/policy.zig");
pub const Policy = policy.Policy;
pub const policyGen = policy.policyGen;

pub const reference = @import("agent/reference.zig");
pub const scriptedAgent = reference.scriptedAgent;
pub const greedyAgent = reference.greedyAgent;
pub const GreedySpec = reference.GreedySpec;

pub const external = @import("agent/external.zig");
pub const ExternalAgent = external.ExternalAgent;
pub const externalAgent = external.externalAgent;

pub const eval = @import("agent/eval.zig");
pub const aggregateAgent = eval.aggregateAgent;
pub const sweepAgent = eval.sweepAgent;

pub const shard = @import("agent/shard.zig");
pub const ShardRange = shard.ShardRange;
pub const shardRanges = shard.shardRanges;
pub const mergeAggregates = shard.mergeAggregates;

test {
    std.testing.refAllDecls(@This());
    _ = observe;
    _ = core;
    _ = policy;
    _ = reference;
    _ = external;
    _ = eval;
    _ = shard;
    _ = @import("agent/gate.zig");
}
