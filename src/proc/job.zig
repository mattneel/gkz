//! Job + result codecs for the §13 process model (PLAN.md Phase 9). A worker process receives a JOB
//! (GKZJ1) and returns a RESULT (GKZK1) — both are serializable VALUES, never code. The registry `R` is
//! NEVER serialized (it is the systems/oracles/seed_world, fixed comptime per worker build via a shared
//! module); a job carries only DATA + `u16` selector ids into the worker's R-fixed comptime tables.
//!
//! These bytes cross an OS boundary, so the codecs are hostile-input-hardened exactly like
//! `migrate.image.decode`: a 5-byte magic + `u16` version + `u8` arm tag, every variable-length section
//! parsed INCREMENTALLY (a hostile count never drives a pre-allocation), and a malformed image is a
//! returned `serialize.Error` — never a panic. The framing discipline mirrors `query/wire.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const shard = @import("../agent/shard.zig");
const metric = @import("../spec/metric.zig");
const input = @import("../input.zig");
const Command = input.Command;
const Input = input.Input;

pub const JOB_MAGIC = [5]u8{ 'G', 'K', 'Z', 'J', '1' };
pub const RESULT_MAGIC = [5]u8{ 'G', 'K', 'Z', 'K', '1' };
pub const VERSION: u16 = 1;

// --- job ------------------------------------------------------------------------------------------

/// Sweep a contiguous seed range, reducing a metric — the MUST-BUILD job (gated cross-process). All
/// fixed scalars, so decoding it never allocates. `oracle_set_id`/`metric_id` index the worker's R-fixed
/// comptime tables (the data↔code boundary: the worker holds the code, the job names which one).
pub const SweepShard = struct {
    range: shard.ShardRange,
    max_ticks: u64,
    oracle_set_id: u16,
    metric_id: u16,
};

/// Continue a forked World from a snapshot under a diverged input stream (§6). The snapshot is a
/// self-contained, process-portable blob (snapshot.zig). Wired + serialized here; its cross-process
/// EXECUTION is a deferred seam (only `sweep_shard` is pinned in the Phase-9 gate).
pub const Fork = struct {
    snapshot_bytes: []const u8,
    base_tick: u64,
    base_hash: u64,
    diverged_inputs: []const Input,
    tick_budget: u64,
};

pub const Job = union(enum) {
    sweep_shard: SweepShard,
    fork: Fork,
};

/// A decoded job + the arena owning any variable-length payload (fork's snapshot bytes + input stream).
/// `sweep_shard` allocates nothing; the arena is still returned (its `deinit` is then a cheap no-op).
pub const DecodedJob = struct {
    job: Job,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *DecodedJob) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// A length that must fit a u32 wire field (a >4 GiB job section is rejected rather than silently
/// truncating via @intCast — a build-mode-dependent D2 hazard otherwise).
fn u32Len(n: usize) serialize.Error!u32 {
    if (n > std.math.maxInt(u32)) return error.Corrupt;
    return @intCast(n);
}

pub fn writeJob(sink: *serialize.ByteSink, job: Job) (serialize.Error || Allocator.Error)!void {
    try sink.update(&JOB_MAGIC);
    try serialize.putInt(sink, u16, VERSION);
    switch (job) {
        .sweep_shard => |s| {
            try serialize.putInt(sink, u8, 0);
            try serialize.putInt(sink, u64, s.range.lo);
            try serialize.putInt(sink, u64, s.range.hi);
            try serialize.putInt(sink, u64, s.max_ticks);
            try serialize.putInt(sink, u16, s.oracle_set_id);
            try serialize.putInt(sink, u16, s.metric_id);
        },
        .fork => |f| {
            try serialize.putInt(sink, u8, 1);
            try serialize.putInt(sink, u32, try u32Len(f.snapshot_bytes.len));
            try sink.update(f.snapshot_bytes);
            try serialize.putInt(sink, u64, f.base_tick);
            try serialize.putInt(sink, u64, f.base_hash);
            try serialize.putInt(sink, u64, f.tick_budget);
            try serialize.putInt(sink, u32, try u32Len(f.diverged_inputs.len));
            for (f.diverged_inputs) |in| {
                try serialize.putInt(sink, u64, in.tick);
                try serialize.putInt(sink, u32, try u32Len(in.commands.len));
                for (in.commands) |c| try serialize.writeValue(sink, Command, c);
            }
        },
    }
}

pub fn decodeJob(gpa: Allocator, bytes: []const u8) (serialize.Error || Allocator.Error)!DecodedJob {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var r = serialize.ByteReader{ .bytes = bytes };

    if (!std.mem.eql(u8, try r.readSlice(5), &JOB_MAGIC)) return error.BadMagic;
    if (try serialize.getInt(&r, u16) != VERSION) return error.UnsupportedFormat;
    const tag = try serialize.getInt(&r, u8);
    const job: Job = switch (tag) {
        0 => .{ .sweep_shard = .{
            .range = .{ .lo = try serialize.getInt(&r, u64), .hi = try serialize.getInt(&r, u64) },
            .max_ticks = try serialize.getInt(&r, u64),
            .oracle_set_id = try serialize.getInt(&r, u16),
            .metric_id = try serialize.getInt(&r, u16),
        } },
        1 => blk: {
            const snap_len = try serialize.getInt(&r, u32);
            const snap = try a.dupe(u8, try r.readSlice(snap_len)); // readSlice bounds-checks (no over-alloc)
            const base_tick = try serialize.getInt(&r, u64);
            const base_hash = try serialize.getInt(&r, u64);
            const tick_budget = try serialize.getInt(&r, u64);
            const n_in = try serialize.getInt(&r, u32);
            // incremental: a hostile count never drives a pre-alloc — each Input is ≥ 12 bytes, so the
            // list grows only proportionally to bytes actually present (the image.decode discipline).
            var inputs: std.ArrayList(Input) = .empty;
            var i: u32 = 0;
            while (i < n_in) : (i += 1) {
                const tick = try serialize.getInt(&r, u64);
                const n_cmd = try serialize.getInt(&r, u32);
                var cmds: std.ArrayList(Command) = .empty;
                var j: u32 = 0;
                while (j < n_cmd) : (j += 1) try cmds.append(a, try serialize.readValue(Command, &r));
                try inputs.append(a, .{ .tick = tick, .commands = cmds.items });
            }
            break :blk .{ .fork = .{
                .snapshot_bytes = snap,
                .base_tick = base_tick,
                .base_hash = base_hash,
                .diverged_inputs = inputs.items,
                .tick_budget = tick_budget,
            } };
        },
        else => return error.Corrupt,
    };
    if (r.pos != bytes.len) return error.Corrupt; // reject trailing garbage after a valid frame
    return .{ .job = job, .arena = arena };
}

// --- result ---------------------------------------------------------------------------------------

/// What a worker returns. `aggregate` is the gated arm (the metric reduction over the shard, plus an
/// optional harvested defect coordinate); `final` is the fork arm (the resulting snapshot + per-tick
/// stream digest). Generic over the metric's integer type `T` (comptime-fixed per worker).
pub fn Result(comptime T: type) type {
    return union(enum) {
        aggregate: struct { agg: metric.Aggregate(T), defect: ?DefectCoord },
        final: struct { snapshot_bytes: []const u8, stream_digest: u64 },
    };
}

/// The coordinate of a harvested defect — a re-runnable repro anchor (§9), seed+tick+kind.
pub const DefectCoord = struct { seed: u64, tick: u64, kind: u16 };

pub fn DecodedResult(comptime T: type) type {
    return struct {
        result: Result(T),
        arena: std.heap.ArenaAllocator,
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn writeResult(comptime T: type, sink: *serialize.ByteSink, result: Result(T)) (serialize.Error || Allocator.Error)!void {
    try sink.update(&RESULT_MAGIC);
    try serialize.putInt(sink, u16, VERSION);
    switch (result) {
        .aggregate => |x| {
            try serialize.putInt(sink, u8, 0);
            try serialize.putInt(sink, u64, x.agg.count);
            try serialize.writeValue(sink, T, x.agg.min);
            try serialize.writeValue(sink, T, x.agg.max);
            try serialize.putInt(sink, i128, x.agg.sum);
            if (x.defect) |d| {
                try serialize.putInt(sink, u8, 1);
                try serialize.putInt(sink, u64, d.seed);
                try serialize.putInt(sink, u64, d.tick);
                try serialize.putInt(sink, u16, d.kind);
            } else {
                try serialize.putInt(sink, u8, 0);
            }
        },
        .final => |x| {
            try serialize.putInt(sink, u8, 1);
            try serialize.putInt(sink, u32, try u32Len(x.snapshot_bytes.len));
            try sink.update(x.snapshot_bytes);
            try serialize.putInt(sink, u64, x.stream_digest);
        },
    }
}

pub fn decodeResult(comptime T: type, gpa: Allocator, bytes: []const u8) (serialize.Error || Allocator.Error)!DecodedResult(T) {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var r = serialize.ByteReader{ .bytes = bytes };

    if (!std.mem.eql(u8, try r.readSlice(5), &RESULT_MAGIC)) return error.BadMagic;
    if (try serialize.getInt(&r, u16) != VERSION) return error.UnsupportedFormat;
    const tag = try serialize.getInt(&r, u8);
    const result: Result(T) = switch (tag) {
        0 => blk: {
            var agg: metric.Aggregate(T) = .{};
            agg.count = try serialize.getInt(&r, u64);
            agg.min = try serialize.readValue(T, &r);
            agg.max = try serialize.readValue(T, &r);
            agg.sum = try serialize.getInt(&r, i128);
            const has_defect = try serialize.getInt(&r, u8);
            const defect: ?DefectCoord = switch (has_defect) {
                0 => null,
                1 => .{ .seed = try serialize.getInt(&r, u64), .tick = try serialize.getInt(&r, u64), .kind = try serialize.getInt(&r, u16) },
                else => return error.Corrupt,
            };
            break :blk .{ .aggregate = .{ .agg = agg, .defect = defect } };
        },
        1 => blk: {
            const len = try serialize.getInt(&r, u32);
            const snap = try a.dupe(u8, try r.readSlice(len));
            break :blk .{ .final = .{ .snapshot_bytes = snap, .stream_digest = try serialize.getInt(&r, u64) } };
        },
        else => return error.Corrupt,
    };
    if (r.pos != bytes.len) return error.Corrupt; // reject trailing garbage after a valid frame
    return .{ .result = result, .arena = arena };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

fn jobToBytes(gpa: Allocator, job: Job) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try writeJob(&sink, job);
    return buf;
}

test "sweep_shard job round-trips byte-exactly (no allocation on decode)" {
    const gpa = testing.allocator;
    const job = Job{ .sweep_shard = .{ .range = .{ .lo = 3, .hi = 17 }, .max_ticks = 4, .oracle_set_id = 0, .metric_id = 2 } };
    var bytes = try jobToBytes(gpa, job);
    defer bytes.deinit(gpa);
    var dec = try decodeJob(gpa, bytes.items);
    defer dec.deinit();
    const s = dec.job.sweep_shard;
    try testing.expectEqual(@as(u64, 3), s.range.lo);
    try testing.expectEqual(@as(u64, 17), s.range.hi);
    try testing.expectEqual(@as(u64, 4), s.max_ticks);
    try testing.expectEqual(@as(u16, 2), s.metric_id);
    // re-encode is byte-identical
    var bytes2 = try jobToBytes(gpa, dec.job);
    defer bytes2.deinit(gpa);
    try testing.expectEqualSlices(u8, bytes.items, bytes2.items);
}

test "fork job round-trips (snapshot bytes + diverged input stream)" {
    const gpa = testing.allocator;
    const cmds = [_]Command{ .{ .actor = .{ .index = 1, .generation = 0 }, .verb = 7, .a0 = -9 }, .{ .actor = .{ .index = 2, .generation = 3 }, .verb = 1 } };
    const inputs = [_]Input{ .{ .tick = 1, .commands = &cmds }, .{ .tick = 2, .commands = &.{} } };
    const job = Job{ .fork = .{ .snapshot_bytes = &.{ 0xDE, 0xAD, 0xBE, 0xEF }, .base_tick = 5, .base_hash = 0x1234, .diverged_inputs = &inputs, .tick_budget = 10 } };
    var bytes = try jobToBytes(gpa, job);
    defer bytes.deinit(gpa);
    var dec = try decodeJob(gpa, bytes.items);
    defer dec.deinit();
    const f = dec.job.fork;
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, f.snapshot_bytes);
    try testing.expectEqual(@as(u64, 5), f.base_tick);
    try testing.expectEqual(@as(usize, 2), f.diverged_inputs.len);
    try testing.expectEqual(@as(usize, 2), f.diverged_inputs[0].commands.len);
    try testing.expectEqual(@as(i64, -9), f.diverged_inputs[0].commands[0].a0);
    try testing.expectEqual(@as(usize, 0), f.diverged_inputs[1].commands.len);
    var bytes2 = try jobToBytes(gpa, dec.job);
    defer bytes2.deinit(gpa);
    try testing.expectEqualSlices(u8, bytes.items, bytes2.items);
}

test "aggregate result round-trips, with and without a harvested defect" {
    const gpa = testing.allocator;
    inline for (.{ @as(?DefectCoord, null), @as(?DefectCoord, .{ .seed = 4, .tick = 9, .kind = 1 }) }) |dco| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
        const res = Result(u64){ .aggregate = .{ .agg = .{ .count = 3, .min = 2, .max = 4, .sum = 9 }, .defect = dco } };
        try writeResult(u64, &sink, res);
        var dec = try decodeResult(u64, gpa, buf.items);
        defer dec.deinit();
        try testing.expectEqual(@as(u64, 3), dec.result.aggregate.agg.count);
        try testing.expectEqual(@as(i128, 9), dec.result.aggregate.agg.sum);
        try testing.expectEqual(@as(u64, 2), dec.result.aggregate.agg.min);
        if (dco) |d| try testing.expectEqual(d.tick, dec.result.aggregate.defect.?.tick) else try testing.expectEqual(@as(?DefectCoord, null), dec.result.aggregate.defect);
    }
}

test "decode rejects bad magic, bad version, unknown arm, and truncation" {
    const gpa = testing.allocator;
    const job = Job{ .sweep_shard = .{ .range = .{ .lo = 0, .hi = 1 }, .max_ticks = 1, .oracle_set_id = 0, .metric_id = 0 } };
    var bytes = try jobToBytes(gpa, job);
    defer bytes.deinit(gpa);

    var bad = try bytes.clone(gpa);
    defer bad.deinit(gpa);
    bad.items[0] = 'X';
    try testing.expectError(error.BadMagic, decodeJob(gpa, bad.items));

    var badv = try bytes.clone(gpa);
    defer badv.deinit(gpa);
    badv.items[5] = 0xFF; // version low byte
    try testing.expectError(error.UnsupportedFormat, decodeJob(gpa, badv.items));

    var badtag = try bytes.clone(gpa);
    defer badtag.deinit(gpa);
    badtag.items[7] = 9; // arm tag (after magic[5]+version[2])
    try testing.expectError(error.Corrupt, decodeJob(gpa, badtag.items));

    try testing.expectError(error.Truncated, decodeJob(gpa, bytes.items[0..6]));
}

test "decode of a fork with a hostile input count fails Truncated, not a huge pre-alloc" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try sink.update(&JOB_MAGIC);
    try serialize.putInt(&sink, u16, VERSION);
    try serialize.putInt(&sink, u8, 1); // fork
    try serialize.putInt(&sink, u32, 0); // snapshot len 0
    try serialize.putInt(&sink, u64, 0); // base_tick
    try serialize.putInt(&sink, u64, 0); // base_hash
    try serialize.putInt(&sink, u64, 0); // tick_budget
    try serialize.putInt(&sink, u32, 0xFFFF_FFFF); // hostile diverged_inputs count, but no bytes follow
    try testing.expectError(error.Truncated, decodeJob(gpa, buf.items));
}
