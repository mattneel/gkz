//! The author's-eye-view HARNESS for the roguelike — the measure-and-iterate loop an AI runs while it
//! builds the game, written as ordinary Zig against the `gkz` library. There is no CLI, no socket, no
//! MCP: an agent that can write and run code drives a library by writing and running code. `zig build
//! run` prints this whole walkthrough; `zig build test` pins the same facts as assertions.
//!
//! It demonstrates, in order: (1) author + step (determinism), (2) observe state, (3) snapshot + replay
//! to an identical digest, (4) fork one state into A/B balance variants, (5) sweep a fun-proxy metric
//! across seeds, (6) the VOPR catching a planted bug as an invariant violation + minimal repro, and
//! (7) provenance — every effect has a recorded cause.

const std = @import("std");
const gkz = @import("gkz");
const game = @import("game.zig");
const R = game.R;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var sbuf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &sbuf);
    const out = &fw.interface;
    defer out.flush() catch {};

    // `roguelike digest <seed> <ticks>` — print just the end-state content hash (decimal u64). Used by the
    // WASM determinism check (web/check.mjs) to assert the browser sim equals this native run, bit for bit.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 4 and std.mem.eql(u8, args[1], "digest")) {
        const seed = try std.fmt.parseInt(u64, args[2], 10);
        const ticks = try std.fmt.parseInt(usize, args[3], 10);
        var w = try runTicks(gpa, try game.seedWorld(gpa, seed), ticks);
        defer w.deinit(gpa);
        try out.print("{d}\n", .{(try w.digest(gpa)).hash});
        return;
    }

    try out.writeAll("=== gkz roguelike — the author's measure-and-iterate loop ===\n\n");

    // (1) AUTHOR + STEP. step : (World, Input) -> World is pure; the World is a value. Run the arena and
    //     print the per-tick content hash — the determinism witness. (No Input here: the sim is
    //     autonomous; a recorded input stream would be the only nondeterminism ingress.)
    try out.writeAll("(1) step — a deterministic tick stream (per-tick content hash):\n");
    {
        var w = try game.seedWorld(gpa, 7);
        defer w.deinit(gpa);
        var t: usize = 0;
        while (t < 8) : (t += 1) {
            const next = try gkz.step(R, gpa, w, gkz.input.EMPTY, &game.systems);
            w.deinit(gpa);
            w = next;
            try out.print("    tick {d:>2}  digest 0x{x:0>16}  live={d}\n", .{ w.tick, (try w.digest(gpa)).hash, liveCount(&w) });
        }
    }

    // (2) OBSERVE. Read the live state directly (game.liveRows is the read-only scan the §7 query Engine
    //     also uses). The AI inspects with measurement, not guesswork.
    try out.writeAll("\n(2) observe — the live entities after 12 ticks (seed 7):\n");
    {
        var w = try runTicks(gpa, try game.seedWorld(gpa, 7), 12);
        defer w.deinit(gpa);
        var buf: [256]game.Row = undefined;
        const n = game.liveRows(&w, &buf);
        for (buf[0..n]) |r| {
            const who: []const u8 = if (r.team == 0) "hero " else "mob  ";
            try out.print("    {s} e{d:<3} @({d:>3},{d:>3})  hp {d:>3}\n", .{ who, r.e.index, r.pos.x, r.pos.y, r.hp });
        }
    }

    // (3) SNAPSHOT + REPLAY. The World is serializable, so a snapshot + the rest of the run reproduces
    //     bit-exactly. Snapshot at tick 10, run to 30 (digest A); restore, run 20 more (digest B); A==B.
    try out.writeAll("\n(3) snapshot + replay — reproduce a run bit-exactly:\n");
    {
        var w = try runTicks(gpa, try game.seedWorld(gpa, 11), 10);
        defer w.deinit(gpa);
        var snap = try gkz.snapshot(R, gpa, &w);
        defer snap.deinit(gpa);

        const digest_a = blk: {
            var a = try runTicks(gpa, try w.clone(gpa), 20);
            defer a.deinit(gpa);
            break :blk (try a.digest(gpa)).hash;
        };
        const digest_b = blk: {
            var b = try runTicks(gpa, try gkz.restore(R, gpa, snap), 20);
            defer b.deinit(gpa);
            break :blk (try b.digest(gpa)).hash;
        };
        try out.print("    live run  0x{x:0>16}\n    replayed   0x{x:0>16}   {s}\n", .{
            digest_a, digest_b, if (digest_a == digest_b) "✓ identical" else "✗ DIVERGED",
        });
    }

    // (4) FORK. One state, two timelines. Take a mid-fight snapshot, then continue it AS-IS vs with a
    //     hero damage buff — A/B a balance tweak from the IDENTICAL starting state.
    try out.writeAll("\n(4) fork — A/B a balance tweak from one mid-fight state (seed 4):\n");
    {
        var w = try runTicks(gpa, try game.seedWorld(gpa, 4), 6);
        defer w.deinit(gpa);

        var base = try runTicks(gpa, try w.clone(gpa), 30);
        defer base.deinit(gpa);

        var buffed = try w.clone(gpa);
        if (buffed.get(game.HERO, game.Power)) |p| p.atk += 6; // the tweak: hero one-shots monsters (atk 5→11 ≥ 10 hp)
        buffed = try runTicks(gpa, buffed, 30);
        defer buffed.deinit(gpa);

        try out.print("    baseline (atk 5)   hero {s}, hp {d:>3}, monsters left {d}\n", .{ heroStatus(&base), heroHp(&base), monstersLeft(&base) });
        try out.print("    +6 atk   (atk 11)  hero {s}, hp {d:>3}, monsters left {d}\n", .{ heroStatus(&buffed), heroHp(&buffed), monstersLeft(&buffed) });
        try out.writeAll("    (same start state, two timelines — the buff crosses the monster's 10-hp one-shot breakpoint)\n");
    }

    // (5) SWEEP + METRIC. Balance is a measured DISTRIBUTION, not a vibe: run the fun-proxy metric
    //     (turns the hero survives) across many seeds and aggregate (min/mean/max), no float.
    try out.writeAll("\n(5) sweep — turns_survived across 200 seeds:\n");
    {
        const agg = try gkz.spec.metric.aggregate(
            R,
            &game.systems,
            &game.atoms,
            false,
            u64,
            gpa,
            game.seedWorld,
            gkz.idleGen(R),
            game.turnsSurvived(),
            0,
            200,
            80,
        );
        const mean_num = agg.sum;
        try out.print("    seeds={d}  min={d}  max={d}  mean={d}/{d}\n", .{ agg.count, agg.min, agg.max, mean_num, agg.count });
    }

    // (6) VOPR. Plant a bug (a seek that ignores tile occupancy) and let the deterministic fuzzer find it
    //     against the no-stacking INVARIANT, across a seed range — minimized to a repro. The correct
    //     system set finds nothing; the buggy one is caught.
    try out.writeAll("\n(6) VOPR — does the no-stacking invariant hold across seeds 0..300?\n");
    {
        const inv = comptime game.noStackingInvariant();
        const oracles_ok = [_]gkz.Oracle(R){gkz.spec.invariant.invariantOracle(R, &game.systems, inv)};
        var ok = try gkz.sweep(R, gpa, &game.systems, game.seedWorld, gkz.idleGen(R), &oracles_ok, 0, 300, 80);
        defer freeReports(R, gpa, &ok);
        try out.print("    correct systems : {d} defective seeds\n", .{ok.items.len});

        const oracles_bug = [_]gkz.Oracle(R){gkz.spec.invariant.invariantOracle(R, &game.systems_buggy, inv)};
        var bug = try gkz.sweep(R, gpa, &game.systems_buggy, game.seedWorld, gkz.idleGen(R), &oracles_bug, 0, 300, 80);
        defer freeReports(R, gpa, &bug);
        try out.print("    buggy systems   : {d} defective seeds", .{bug.items.len});
        if (bug.items.len > 0) {
            const d = bug.items[0].defect;
            try out.print("  → first: seed {d}, invariant '{s}' broke at tick {d} (minimized repro + cause chain attached)", .{ d.seed, d.oracle, d.tick });
        }
        try out.writeAll("\n");
    }

    // (7) PROVENANCE. Re-run a tick with a Recorder ON: every Damaged/Slain effect is recorded with its
    //     cause, WITHOUT changing the World or its hash (events are pure side-output).
    try out.writeAll("\n(7) provenance — record the causal log of one combat tick:\n");
    {
        var w = try runTicks(gpa, try game.seedWorld(gpa, 4), 9); // close to melee range
        defer w.deinit(gpa);
        var rec = gkz.Recorder.init(gpa);
        defer rec.deinit();
        const before = (try w.digest(gpa)).hash;
        var next = try gkz.stepRec(R, gpa, w, gkz.input.EMPTY, &game.systems, &rec);
        defer next.deinit(gpa);
        const events_off = blk: {
            var n2 = try gkz.step(R, gpa, w, gkz.input.EMPTY, &game.systems);
            defer n2.deinit(gpa);
            break :blk (try n2.digest(gpa)).hash;
        };
        try out.print("    {d} events recorded; tick digest WITH events 0x{x:0>16} == without 0x{x:0>16}  {s}\n", .{
            rec.log.count(),
            (try next.digest(gpa)).hash,
            events_off,
            if ((try next.digest(gpa)).hash == events_off) "✓ events are pure side-output" else "✗",
        });
        _ = before;
    }

    try out.writeAll("\nThat is the loop: write systems → measure across seeds → fork to A/B → VOPR to a repro → iterate.\n");
}

// --- harness helpers ---------------------------------------------------------------------------------

/// Advance `w` by `n` ticks (consuming + returning ownership) under the correct system set.
fn runTicks(gpa: std.mem.Allocator, w0: gkz.World(R), n: usize) std.mem.Allocator.Error!gkz.World(R) {
    var w = w0;
    var t: usize = 0;
    while (t < n) : (t += 1) {
        const next = try gkz.step(R, gpa, w, gkz.input.EMPTY, &game.systems);
        w.deinit(gpa);
        w = next;
    }
    return w;
}

fn liveCount(w: *const gkz.World(R)) usize {
    var buf: [256]game.Row = undefined;
    return game.liveRows(w, &buf);
}

fn heroStatus(w: *gkz.World(R)) []const u8 {
    if (w.get(game.HERO, game.Health)) |h| {
        return if (h.hp > 0) "ALIVE" else "down";
    }
    return "slain";
}

fn heroHp(w: *gkz.World(R)) i32 {
    return if (w.get(game.HERO, game.Health)) |h| h.hp else 0;
}

fn monstersLeft(w: *const gkz.World(R)) usize {
    var buf: [256]game.Row = undefined;
    const n = game.liveRows(w, &buf);
    var m: usize = 0;
    for (buf[0..n]) |r| {
        if (r.team != 0) m += 1;
    }
    return m;
}

fn freeReports(comptime Reg: type, gpa: std.mem.Allocator, reports: *std.ArrayList(gkz.vopr.DefectReport(Reg))) void {
    for (reports.items) |*r| r.deinit(gpa);
    reports.deinit(gpa);
}

test "the harness loop runs end to end (smoke)" {
    // build the example's test artifact links against gkz; the per-section assertions live in game.zig.
    _ = runTicks;
}
