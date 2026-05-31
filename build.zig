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
    }
}
