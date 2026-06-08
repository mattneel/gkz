const std = @import("std");

// The canonical gkz example: a headless grid-roguelike combat sim, built as its OWN Zig project that
// depends on the `gkz` kernel by PATH (../..) — i.e. exactly how a downstream game links the library.
//
//   zig build run     — run the measure-and-iterate harness (prints the author's-eye-view loop)
//   zig build test    — the determinism / invariant / fork / sweep / VOPR assertions
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The gkz kernel, consumed as a path dependency. `.module("gkz")` is the kernel's public front door
    // (src/root.zig), with its own `fpz` fixed-point dependency already wired in.
    const gkz_dep = b.dependency("gkz", .{ .target = target, .optimize = optimize });
    const gkz = gkz_dep.module("gkz");

    // The game lives in `src/game.zig` (the Spec: registry + systems + content + specs) and `src/main.zig`
    // (the harness). Both import the kernel as `gkz`.
    const exe = b.addExecutable(.{
        .name = "roguelike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "gkz", .module = gkz }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the roguelike measure-and-iterate harness");
    run_step.dependOn(&run_cmd.step);

    // Tests: the game's determinism / invariant / fork / sweep / VOPR assertions (src/game.zig + main.zig).
    const test_step = b.step("test", "Run the roguelike example's assertions");
    for ([_][]const u8{ "src/game.zig", "src/main.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "gkz", .module = gkz }},
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // --- WASM: the deterministic sim core in the browser (the §14 view seam) ---
    // `src/wasm.zig` exports a C-ABI surface (rl_init/rl_step/rl_live/...) and touches no std.Io / thread /
    // clock / syscall, so the SAME sim core compiles to a freestanding sandbox. The gkz module is built
    // for the wasm target; lazy analysis keeps the proc/control-plane (std.Io) layer out of the wasm binary.
    const wasm_step = b.step("wasm", "Build the WASM modules into zig-out/web/ (freestanding wasm32 + wasm64)");
    const WasmTgt = struct { name: []const u8, arch: std.Target.Cpu.Arch };
    for ([_]WasmTgt{
        .{ .name = "roguelike", .arch = .wasm32 },
        .{ .name = "roguelike64", .arch = .wasm64 },
    }) |wt| {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = wt.arch, .os_tag = .freestanding });
        const gkz_wasm = b.dependency("gkz", .{ .target = wasm_target, .optimize = .ReleaseSmall }).module("gkz");
        const wasm = b.addExecutable(.{
            .name = wt.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wasm.zig"),
                .target = wasm_target,
                .optimize = .ReleaseSmall,
                .imports = &.{.{ .name = "gkz", .module = gkz_wasm }},
            }),
        });
        wasm.entry = .disabled; // a "reactor" module: no _start, just the exported functions + memory
        wasm.rdynamic = true; // export the `export fn`s (and the linear memory)
        wasm_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    }
    // Copy the page into zig-out/web/ next to the .wasm, so the install dir is self-contained and servable:
    //   zig build wasm && (cd zig-out/web && python3 -m http.server) → open http://localhost:8000
    wasm_step.dependOn(&b.addInstallFile(b.path("web/index.html"), "web/index.html").step);

    // --- WASM via Emscripten: a batteries-included .js + .wasm pair (needs emcc on PATH) ---
    // Emscripten provides a libc/JS glue layer; useful if a demo wants console/fs/SDL on top of the sim.
    // The sim core itself needs none of that — this target exists so the support is complete.
    // --- WASM determinism gate: assert the in-browser sim digest == the native run (needs node) ---
    // wasm32 is a 32-bit LE target like the gated `arm`; the content hash must match native bit-for-bit.
    const node_path = b.findProgram(&.{ "node", "bun" }, &.{}) catch null;
    const wasm_check = b.step("wasm-check", "Build wasm + assert its content digest equals the native run (needs node/bun)");
    if (node_path) |node| {
        const check = b.addSystemCommand(&.{ node, "web/check.mjs" });
        check.step.dependOn(wasm_step); // the wasm modules
        check.step.dependOn(b.getInstallStep()); // the native exe (the self-verifying reference)
        check.has_side_effects = true;
        wasm_check.dependOn(&check.step);
    }

    const emcc_path = b.findProgram(&.{"emcc"}, &.{}) catch null;
    const em_step = b.step("wasm-emcc", "Build the Emscripten module zig-out/web/roguelike-emcc.* (needs emcc)");
    if (emcc_path) |emcc| {
        const em_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .emscripten });
        const gkz_em = b.dependency("gkz", .{ .target = em_target, .optimize = .ReleaseSmall }).module("gkz");
        // compile the sim core to a static lib for the emscripten target, then let emcc link the JS glue.
        const lib = b.addLibrary(.{ .name = "roguelike-emcc", .linkage = .static, .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = em_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "gkz", .module = gkz_em }},
        }) });
        const link = b.addSystemCommand(&.{emcc});
        link.addArtifactArg(lib);
        link.addArgs(&.{ "-o", "zig-out/web/roguelike-emcc.js", "-sEXPORTED_FUNCTIONS=_rl_init,_rl_step,_rl_tick,_rl_digest,_rl_live,_rl_buf,_rl_extent", "-sEXPORTED_RUNTIME_METHODS=ccall,cwrap", "-sALLOW_MEMORY_GROWTH=1", "-sMODULARIZE=1", "-sEXPORT_ES6=1", "--no-entry" });
        em_step.dependOn(&link.step);
    }
}
