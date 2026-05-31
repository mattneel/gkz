//! The dedicated §13 worker executable used by the proc determinism gate (PLAN.md Phase 9). It pins the
//! example registry via `worker_example/shared.zig` (the reload_example/shared.zig pattern) so the gate
//! owns its lifecycle and `getEmittedBin` path injection. Production deployments instead use the `worker`
//! subcommand of the main CLI with their own registry; both route to `gkz.proc.runWorker`.
//!
//! Invocation: `gkz_worker worker <job_file>` → read the GKZJ1 job, run it against the example sim, write
//! `[u32 len][GKZK1]` to stdout. A poison `oracle_set_id` in the job makes it abort/hang (gate crash/hang
//! sub-gates).

const std = @import("std");
const gkz = @import("gkz");
const shared = @import("worker_example/shared.zig");

pub fn main(init: std.process.Init) !void {
    try gkz.proc.runWorker(shared, init);
}
