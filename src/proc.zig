//! §13 process model & control plane (Phase 9) — public umbrella.
//!
//! One OS process per sim: a `Supervisor` shards a sweep across worker processes via an `Executor`
//! (in-process for the determinism floor, or a real subprocess), harvests results index-addressed by
//! shard, restarts crashes (a crash is a harvested repro, §9), and merges in canonical order — so the
//! merged result is bit-identical to a single-process sweep. A `QueryServer` multiplexes the §7
//! relational surface (`query/wire.respond`, unchanged) across live sims. Jobs/results are serializable
//! values (`proc.job`); `R` is comptime-fixed per worker build, never serialized.

pub const job = @import("proc/job.zig");

pub const executor = @import("proc/executor.zig");
pub const Executor = executor.Executor;
pub const Outcome = executor.Outcome;
pub const ChildTerm = executor.ChildTerm;
pub const RunError = executor.RunError;
pub const runJobBytes = executor.runJobBytes;
pub const inProcessExecutor = executor.inProcessExecutor;
pub const subprocessExecutor = executor.subprocessExecutor;
pub const SubprocCtx = executor.SubprocCtx;

const worker_mod = @import("proc/worker.zig");
pub const runWorker = worker_mod.runWorker;
pub const POISON_CRASH = worker_mod.POISON_CRASH;
pub const POISON_HANG = worker_mod.POISON_HANG;
pub const POISON_SLEEP = worker_mod.POISON_SLEEP;
pub const POISON_SLEEP_MS = worker_mod.POISON_SLEEP_MS;

pub const supervisor = @import("proc/supervisor.zig");
pub const Supervisor = supervisor.Supervisor;

pub const qserver = @import("proc/qserver.zig");
pub const QueryServer = qserver.QueryServer;

// §17 control-plane completion: the live control-command surface + the across-machines network transport.
pub const control_wire = @import("proc/control_wire.zig");
pub const ControlCommand = control_wire.ControlCommand;
pub const ControlResponse = control_wire.ControlResponse;
pub const control_server = @import("proc/control_server.zig");
pub const ControlServer = control_server.ControlServer;
pub const net_executor = @import("proc/net_executor.zig");
pub const networkExecutor = net_executor.networkExecutor;
pub const NetCtx = net_executor.NetCtx;
const net_worker_mod = @import("proc/net_worker.zig");
pub const runNetWorker = net_worker_mod.runNetWorker;
pub const listenLoopback = net_worker_mod.listenLoopback;

test {
    _ = job;
    _ = executor;
    _ = worker_mod;
    _ = supervisor;
    _ = qserver;
    _ = control_wire;
    _ = control_server;
    _ = net_executor;
    _ = net_worker_mod;
}
