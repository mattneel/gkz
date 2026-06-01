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
}
