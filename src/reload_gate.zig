//! Phase-8 REAL dlopen determinism gate (PLAN.md §12). Built by build.zig as its own test artifact in
//! all three optimize modes; it dlopens the `src/reload_example/*` shared objects (compiled by build.zig
//! with `linkage = .dynamic`) and proves:
//!   (g) a loaded native `.so`'s per-tick hash stream EQUALS the in-tree reference logic's stream — so the
//!       gate genuinely exercises loaded native code, and that code IS the reference (the honesty check);
//!       plus the reference stream digest is pinned, identical across Debug/ReleaseSafe/ReleaseFast.
//!   (h) hot-swapping mid-stream to a DIFFERENT `.so` (move -> move-at-2x) DIVERGES from the reference,
//!       caught by the divergence primitive at/after the swap with an identical pre-swap prefix — so a
//!       reloaded set is never silently substituted, and a bad reload is detectable.
//!   (i) loading the SAME `.so` twice yields a bit-identical stream, and open/close is host-leak-free.
//!
//! The `.so`s are built PER MODE (host-mode == .so-mode — calling cross-mode into loaded code is an ABI
//! mismatch), and all three modes assert the SAME pinned reference digest, so for this example the loaded
//! native code is proven mode-stable. What the gate CANNOT do is FORCE arbitrary author-supplied native
//! code to be deterministic — the kernel's guarantee for opaque reloaded code is DETECTION (the divergence
//! oracle, test (h)), not enforcement (§15 trusts the author of reloaded systems).
//!
//! This gate performs a REAL dlopen (links libc -> std.DynLib uses the OS loader). A hermetic/seccomp
//! runner that forbids dlopen will fail these three tests; that is honest (the mechanism genuinely
//! requires loading code) — the base determinism suite is a SEPARATE build artifact and is unaffected.

const std = @import("std");
const gkz = @import("gkz");
const build_opts = @import("build_opts");
const shared = @import("reload_example/shared.zig");
const R = shared.R;
const testing = std.testing;

const TICKS: usize = 6;
const SWAP: usize = 3;

/// PINNED: streamDigest of the reference (in-tree `move`) run. Identical in all three modes (the
/// determinism witness for the reloaded-systems path). Recompute via the DUMP test below.
const REF_STREAM_DIGEST: u64 = 4806503180971246035;

// The in-tree reference `move` system — MUST match src/reload_example/lib_move.zig's logic (x += dx).
fn moveRef(ctx: *gkz.SimCtx(R), q: *gkz.Query(R, .{ gkz.Read(shared.Velocity), gkz.Write(shared.Position) })) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(shared.Position).x += row.read(shared.Velocity).dx;
}
const ref_systems = [_]gkz.Sys(R){gkz.system(R, "move", moveRef)};

fn streamDigest(hashes: []const u64) u64 {
    var h = std.hash.XxHash64.init(0);
    for (hashes) |x| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, x, .little);
        h.update(&b);
    }
    return h.final();
}

fn firstDivergentTick(a: []const u64, b: []const u64) ?usize {
    const n = @min(a.len, b.len);
    for (0..n) |i| if (a[i] != b[i]) return i;
    return if (a.len != b.len) n else null;
}

fn seedWorld(gpa: std.mem.Allocator) !gkz.World(R) {
    var w = gkz.World(R).init(0x9112);
    errdefer w.deinit(gpa);
    const e0 = try w.spawn(gpa);
    const e1 = try w.spawn(gpa);
    w.add(e0, shared.Position, .{ .x = 0 });
    w.add(e0, shared.Velocity, .{ .dx = 1 });
    w.add(e1, shared.Position, .{ .x = 10 });
    w.add(e1, shared.Velocity, .{ .dx = 3 });
    return w;
}

const Cap = struct { hashes: []u64, final: gkz.World(R) };

/// Run `w0` forward `n` empty-input ticks over a RUNTIME systems slice via the dynamic step path.
fn captureDynamic(gpa: std.mem.Allocator, w0: gkz.World(R), systems: []const gkz.Sys(R), n: usize) !Cap {
    var w = w0;
    errdefer w.deinit(gpa);
    const exec = try gkz.execOrderDynamic(R, gpa, systems);
    defer gpa.free(exec);
    const hashes = try gpa.alloc(u64, n);
    errdefer gpa.free(hashes);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const nx = try gkz.stepDynamic(R, gpa, w, .{ .tick = i + 1, .commands = &.{} }, systems, exec, null);
        w.deinit(gpa);
        w = nx;
        hashes[i] = (try w.digest(gpa)).hash;
    }
    return .{ .hashes = hashes, .final = w };
}

test "(g) a dlopen'd native system reproduces the in-tree reference stream (pinned, all 3 modes)" {
    const gpa = testing.allocator;

    // reference: the in-tree move logic
    var ref = try captureDynamic(gpa, try seedWorld(gpa), &ref_systems, TICKS);
    defer ref.final.deinit(gpa);
    defer gpa.free(ref.hashes);
    try testing.expectEqual(REF_STREAM_DIGEST, streamDigest(ref.hashes)); // cross-mode determinism witness

    // loaded: the REAL .so opened via std.DynLib
    var src = gkz.NativeLibSource(R){ .path = build_opts.lib_move_path };
    const source = src.source();
    const set = try source.load();
    defer source.unload();
    try testing.expect(set.systems.len == 1);

    var loaded = try captureDynamic(gpa, try seedWorld(gpa), set.systems, TICKS);
    defer loaded.final.deinit(gpa);
    defer gpa.free(loaded.hashes);

    // the loaded NATIVE code's stream IS the reference logic's stream — bit for bit.
    try testing.expectEqualSlices(u64, ref.hashes, loaded.hashes);
    // pin the LOADED native stream directly (not just transitively via ref==pin): proves the dlopen'd
    // code is mode-stable in its own right across Debug/ReleaseSafe/ReleaseFast.
    try testing.expectEqual(REF_STREAM_DIGEST, streamDigest(loaded.hashes));
}

test "loader contract: a second load() without unload is AlreadyLoaded; unload re-arms it" {
    var src = gkz.NativeLibSource(R){ .path = build_opts.lib_move_path };
    const s = src.source();
    const set = try s.load();
    try testing.expect(set.systems.len == 1);
    try testing.expectError(error.AlreadyLoaded, s.load()); // refuse to orphan the first handle
    s.unload();
    const set2 = try s.load(); // unload re-armed the loader
    try testing.expect(set2.systems.len == 1);
    s.unload();
}

test "(h) hot-swapping to a DIFFERENT .so mid-stream diverges, caught at/after the swap" {
    const gpa = testing.allocator;

    var ref = try captureDynamic(gpa, try seedWorld(gpa), &ref_systems, TICKS);
    defer ref.final.deinit(gpa);
    defer gpa.free(ref.hashes);

    // segment 1: lib_move (x += dx) for [0, SWAP)
    var srcA = gkz.NativeLibSource(R){ .path = build_opts.lib_move_path };
    const sourceA = srcA.source();
    const setA = try sourceA.load();
    const seg1 = try captureDynamic(gpa, try seedWorld(gpa), setA.systems, SWAP);
    defer gpa.free(seg1.hashes);
    sourceA.unload(); // setA.systems no longer used; safe to close A

    // segment 2: RELOAD to lib_move_fast (x += 2*dx) for [SWAP, TICKS) from seg1's final world
    var srcB = gkz.NativeLibSource(R){ .path = build_opts.lib_move_fast_path };
    const sourceB = srcB.source();
    const setB = try sourceB.load();
    defer sourceB.unload();
    var seg2 = try captureDynamic(gpa, seg1.final, setB.systems, TICKS - SWAP);
    defer seg2.final.deinit(gpa);
    defer gpa.free(seg2.hashes);

    var joined = try gpa.alloc(u64, TICKS);
    defer gpa.free(joined);
    @memcpy(joined[0..SWAP], seg1.hashes);
    @memcpy(joined[SWAP..], seg2.hashes);

    const div = firstDivergentTick(ref.hashes, joined);
    try testing.expect(div != null and div.? >= SWAP); // the divergent reload is detected
    try testing.expectEqualSlices(u64, ref.hashes[0..SWAP], joined[0..SWAP]); // identical pre-swap prefix
}

test "(i) reloading the same .so twice is bit-identical; open/close is host-leak-free" {
    const gpa = testing.allocator;

    var src1 = gkz.NativeLibSource(R){ .path = build_opts.lib_move_path };
    const s1 = src1.source();
    const set1 = try s1.load();
    var c1 = try captureDynamic(gpa, try seedWorld(gpa), set1.systems, TICKS);
    defer gpa.free(c1.hashes);
    c1.final.deinit(gpa);
    s1.unload();

    var src2 = gkz.NativeLibSource(R){ .path = build_opts.lib_move_path };
    const s2 = src2.source();
    const set2 = try s2.load();
    var c2 = try captureDynamic(gpa, try seedWorld(gpa), set2.systems, TICKS);
    defer gpa.free(c2.hashes);
    c2.final.deinit(gpa);
    s2.unload();

    try testing.expectEqualSlices(u64, c1.hashes, c2.hashes);
}

// NOT a test — a dev utility that prints REF_STREAM_DIGEST after an intentional change (the pin is already
// verified by gate (g) above). Kept compiled via the comptime ref so it can't bit-rot; to recompute, call
// it from a scratch test and read stderr.
comptime {
    _ = &dumpReloadPin;
}
fn dumpReloadPin(gpa: std.mem.Allocator) !void {
    var ref = try captureDynamic(gpa, try seedWorld(gpa), &ref_systems, TICKS);
    defer ref.final.deinit(gpa);
    defer gpa.free(ref.hashes);
    std.debug.print("\nREF_STREAM_DIGEST = {d};\n", .{streamDigest(ref.hashes)});
}
