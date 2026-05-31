const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- the kernel module + CLI (built in the command-line-selected optimize mode) ---
    const fpz_dep = b.dependency("fpz", .{ .target = target, .optimize = optimize });
    const mod = b.addModule("gkz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("fpz", fpz_dep.module("fpz"));

    const exe = b.addExecutable(.{
        .name = "gkz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "gkz", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // --- `zig build test`: the determinism gate ---
    //
    // Run the WHOLE suite under Debug, ReleaseSafe, and ReleaseFast. The suite contains a pinned
    // end-to-end content hash (replay.zig); all three modes asserting against that single constant
    // proves the per-tick state hash is bit-identical across build modes (SPEC §2.2, PLAN.md D2) —
    // including under integer overflow, which ReleaseFast does not panic on. fpz is built in the
    // matching mode in each row (its own contract guarantees the three agree, so this also exercises
    // that). A big-endian (qemu) row is left as future work (PLAN.md §7 risk #7).
    //
    // Phase 8 adds, per mode, a REAL dlopen reload gate: two systems compiled to actual shared objects
    // (linkage=.dynamic) that reload_gate.zig opens via std.DynLib, proving a loaded .so's per-tick stream
    // equals the in-tree reference logic and that a divergent .so is caught. The .so's are built in the
    // SAME mode as the gate that loads them (host-mode == .so-mode — a cross-mode call into the loaded
    // code is an ABI mismatch). link_libc => a normal dynamically-linked ELF the OS loader can relocate
    // (a self-relocating static-pie's internal pointers read as garbage under dlopen).
    const test_step = b.step("test", "Run the kernel suite under Debug/ReleaseSafe/ReleaseFast (determinism gate)");
    const modes = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe, .ReleaseFast };
    for (modes) |mode| {
        const fpz_mode = b.dependency("fpz", .{ .target = target, .optimize = mode });
        const tmod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = mode,
        });
        tmod.addImport("fpz", fpz_mode.module("fpz"));
        const t = b.addTest(.{ .name = b.fmt("test-{s}", .{@tagName(mode)}), .root_module = tmod });
        const run = b.addRunArtifact(t);
        run.has_side_effects = true; // never cache-skip the determinism gate
        test_step.dependOn(&run.step);

        // per-mode reloadable example shared objects + the gate that dlopens them. Guarded to ELF/Linux:
        // the `pie = false` dynamic-.so recipe and the dlopen relocation behavior are Linux-validated, and
        // the pinned digests are exercised there. On other hosts the loader wiring is portable via
        // getEmittedBin() but is left as a documented seam — the base 3-mode determinism gate above runs
        // everywhere regardless.
        if (target.result.os.tag == .linux) {
            const gkz_lib_mod = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = mode });
            gkz_lib_mod.addImport("fpz", fpz_mode.module("fpz"));
            const lib_move = b.addLibrary(.{ .name = b.fmt("gkz_move_{s}", .{@tagName(mode)}), .linkage = .dynamic, .root_module = b.createModule(.{
                .root_source_file = b.path("src/reload_example/lib_move.zig"),
                .target = target,
                .optimize = mode,
                .link_libc = true,
                .imports = &.{.{ .name = "gkz", .module = gkz_lib_mod }},
            }) });
            lib_move.pie = false;
            const lib_move_fast = b.addLibrary(.{ .name = b.fmt("gkz_move_fast_{s}", .{@tagName(mode)}), .linkage = .dynamic, .root_module = b.createModule(.{
                .root_source_file = b.path("src/reload_example/lib_move_fast.zig"),
                .target = target,
                .optimize = mode,
                .link_libc = true,
                .imports = &.{.{ .name = "gkz", .module = gkz_lib_mod }},
            }) });
            lib_move_fast.pie = false;
            // inject the emitted .so paths as comptime []const u8 strings; addOptionPath auto-adds the
            // build-graph dependency so the gate is built only after the .so's exist on disk.
            const reload_opts = b.addOptions();
            reload_opts.addOptionPath("lib_move_path", lib_move.getEmittedBin());
            reload_opts.addOptionPath("lib_move_fast_path", lib_move_fast.getEmittedBin());

            const gkz_gate_mod = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = mode });
            gkz_gate_mod.addImport("fpz", fpz_mode.module("fpz"));
            const gate_mod = b.createModule(.{
                .root_source_file = b.path("src/reload_gate.zig"),
                .target = target,
                .optimize = mode,
                .link_libc = true, // use the OS dynamic loader (dlopen) so the .so is properly relocated
                .imports = &.{
                    .{ .name = "gkz", .module = gkz_gate_mod },
                    .{ .name = "build_opts", .module = reload_opts.createModule() },
                },
            });
            const gate_t = b.addTest(.{ .name = b.fmt("reload-gate-{s}", .{@tagName(mode)}), .root_module = gate_mod });
            const gate_run = b.addRunArtifact(gate_t);
            gate_run.has_side_effects = true;
            test_step.dependOn(&gate_run.step);
        }
    }
}
