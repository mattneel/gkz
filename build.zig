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
    // that). The CROSS-ARCHITECTURE axis (SPEC §2 "every architecture", incl. big-endian) is the
    // separate `zig build cross` gate below — formerly PLAN §7 risk #7, now closed.
    //
    // Phase 8 adds, per mode, a REAL dlopen reload gate: two systems compiled to actual shared objects
    // (linkage=.dynamic) that reload_gate.zig opens via std.DynLib, proving a loaded .so's per-tick stream
    // equals the in-tree reference logic and that a divergent .so is caught. The .so's are built in the
    // SAME mode as the gate that loads them (host-mode == .so-mode — a cross-mode call into the loaded
    // code is an ABI mismatch). link_libc => a normal dynamically-linked ELF the OS loader can relocate
    // (a self-relocating static-pie's internal pointers read as garbage under dlopen).
    const test_step = b.step("test", "Run the kernel suite under Debug/ReleaseSafe/ReleaseFast (determinism gate)");
    const modes = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe, .ReleaseFast };

    // §17 cross-ENDIAN "across machines" witness: a BIG-ENDIAN (s390x) build of the TCP worker daemon. The
    // proc gate spawns it under qemu-s390x and drives it from this little-endian x86_64 client over a REAL
    // TCP socket — proving two DIFFERENT-ARCH peers transact byte-identically over a LIVE socket (stronger
    // than `zig build cross`, which proves the codec is endian-stable in isolation, not that two arches agree
    // over a socket). Built once (Debug — the witness is the transport/codec, not the optimize mode); a
    // static ELF qemu-user runs directly. Linux-only (the gate spawns qemu); built unconditionally (a
    // cross-compile is host-OS-independent) but only injected into the Linux-guarded proc gate below.
    const net_worker_s390x = blk: {
        const s390x_target = b.resolveTargetQuery(.{ .cpu_arch = .s390x, .os_tag = .linux });
        const fpz_s390x = b.dependency("fpz", .{ .target = s390x_target, .optimize = .Debug });
        const gkz_s390x = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = s390x_target, .optimize = .Debug });
        gkz_s390x.addImport("fpz", fpz_s390x.module("fpz"));
        break :blk b.addExecutable(.{ .name = "gkz_net_worker_s390x", .root_module = b.createModule(.{
            .root_source_file = b.path("src/proc/net_worker_main.zig"),
            .target = s390x_target,
            .optimize = .Debug,
            .imports = &.{.{ .name = "gkz", .module = gkz_s390x }},
        }) });
    };

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

            // --- Phase 9: the real §13 process-model gate ---
            // A dedicated per-mode worker EXE (R pinned via worker_example/shared.zig) the gate spawns;
            // unlike the dlopen .so this is pure-Zig process spawning, so NO link_libc / pie=false needed.
            const gkz_worker_mod = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = mode });
            gkz_worker_mod.addImport("fpz", fpz_mode.module("fpz"));
            const worker = b.addExecutable(.{ .name = b.fmt("gkz_worker_{s}", .{@tagName(mode)}), .root_module = b.createModule(.{
                .root_source_file = b.path("src/proc/worker_main.zig"),
                .target = target,
                .optimize = mode,
                .imports = &.{.{ .name = "gkz", .module = gkz_worker_mod }},
            }) });
            // §17: a second per-mode daemon EXE — the TCP network worker the proc gate spawns to prove the
            // networkExecutor transport across a REAL process boundary (the multi-machine seam, now closed).
            const net_worker = b.addExecutable(.{ .name = b.fmt("gkz_net_worker_{s}", .{@tagName(mode)}), .root_module = b.createModule(.{
                .root_source_file = b.path("src/proc/net_worker_main.zig"),
                .target = target,
                .optimize = mode,
                .imports = &.{.{ .name = "gkz", .module = gkz_worker_mod }},
            }) });

            const proc_opts = b.addOptions();
            proc_opts.addOptionPath("worker_exe_path", worker.getEmittedBin()); // injects path + build-graph dep
            proc_opts.addOptionPath("net_worker_exe_path", net_worker.getEmittedBin()); // §17 TCP daemon path + dep
            proc_opts.addOptionPath("net_worker_s390x_path", net_worker_s390x.getEmittedBin()); // §17 cross-endian daemon
            proc_opts.addOption([]const u8, "qemu_s390x", "qemu-s390x"); // qemu-user wrapper for the s390x daemon

            const gkz_pgate_mod = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = mode });
            gkz_pgate_mod.addImport("fpz", fpz_mode.module("fpz"));
            const pgate_mod = b.createModule(.{
                .root_source_file = b.path("src/proc/proc_gate.zig"),
                .target = target,
                .optimize = mode,
                .imports = &.{
                    .{ .name = "gkz", .module = gkz_pgate_mod },
                    .{ .name = "build_opts", .module = proc_opts.createModule() },
                },
            });
            const pgate_t = b.addTest(.{ .name = b.fmt("proc-gate-{s}", .{@tagName(mode)}), .root_module = pgate_mod });
            const pgate_run = b.addRunArtifact(pgate_t);
            pgate_run.has_side_effects = true; // never cache-skip a spawn gate
            test_step.dependOn(&pgate_run.step);
        }
    }

    // --- `zig build cross`: the CROSS-ARCHITECTURE determinism gate (SPEC §2 "every architecture") ---
    //
    // The base `test` gate proves Debug==ReleaseSafe==ReleaseFast on the host (x86-64, little-endian).
    // SPEC §2 claims the per-tick state hash (and every frozen pin) is bit-identical on EVERY architecture.
    // This step proves it: cross-compile the WHOLE root suite and re-check every pin under qemu-user on two
    // foreign targets that span the two axes that could break it —
    //   * aarch64-linux — a different ISA / codegen / alignment, still little-endian.
    //   * s390x-linux   — BIG-ENDIAN: the decisive witness that the canonical little-endian serialize/hash
    //                     path is actually honored. Any native-byte-order leak diverges a pin here.
    // The root test module links no libc, so each foreign test binary is a STATIC ELF qemu-user runs
    // directly (no glibc runtime path needed). We invoke it with NO `--listen` (addSystemCommand, not
    // addRunArtifact), so the default test runner self-runs and its exit code gates the build. The
    // root-reachable tests touch no fixed socket/temp path (the §13 socket/subprocess gates are SEPARATE
    // artifacts, not pulled in here), so the cross runs are safe to execute concurrently.
    //
    // Requires `qemu-<arch>` on PATH (Debian/Ubuntu: `apt install qemu-user`). Kept a SEPARATE step (not
    // folded into `zig build test`) because qemu emulation is ~10-20x slower; run it before a release / in
    // CI. Absent qemu, the step fails loudly when invoked (never a vacuous pass).
    // enable_qemu lets `addRunArtifact` execute a FOREIGN test binary by wrapping it with `qemu-<arch>`,
    // using the build system's binary test-IPC protocol (not 306 lines of stdout through a captured pipe,
    // which proved flaky under emulation). Foreign-execute failure (qemu missing) is a hard error here, so
    // the gate never passes vacuously. Harmless globally: the host-targeted `test`/reload/proc artifacts
    // are not foreign, so this changes nothing for `zig build test`.
    b.enable_qemu = true;
    const cross_step = b.step("cross", "Cross-arch determinism gate: re-check every pin on 4 foreign arches (the {32,64}-bit × {LE,BE} matrix) under qemu, all 3 modes");
    // The four quadrants of {word size} × {endianness}, so every frozen pin is re-checked against a
    // different ISA, both byte orders, AND both pointer widths (x86-64 = the native 64-bit LE baseline):
    //   aarch64 = 64-bit LE · s390x = 64-bit BE · arm = 32-bit LE · mips = 32-bit BE.
    // s390x/mips are the canonical-LE-serialization witnesses; arm/mips are the fixed-width (no-usize-leak)
    // witnesses. qemu binary names (qemu-aarch64/s390x/arm/mips) are derived from the arch by Zig.
    const cross_arches = [_]std.Target.Cpu.Arch{ .aarch64, .s390x, .arm, .mips };
    // The cross-compiles run in parallel; the qemu RUNS are CHAINED to run one at a time so the emulated
    // thread spawns of the step_par tests (forced-overlap + the 16× repeated run) don't oversubscribe the
    // host across six concurrent suites. Cheap (~30s total) insurance for a reliable gate.
    var prev_cross_run: ?*std.Build.Step = null;
    for (cross_arches) |arch| {
        const ctq = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux });
        for (modes) |mode| {
            const xfpz = b.dependency("fpz", .{ .target = ctq, .optimize = mode });
            const xmod = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = ctq,
                .optimize = mode,
            });
            xmod.addImport("fpz", xfpz.module("fpz"));
            const xt = b.addTest(.{ .name = b.fmt("cross-{s}-{s}", .{ @tagName(arch), @tagName(mode) }), .root_module = xmod });
            const xrun = b.addRunArtifact(xt); // foreign → auto-wrapped with qemu-<arch> (enable_qemu); test IPC
            // The wall-clock overlap proofs (step_par_gate T6/T9) self-skip on the foreign targets (they're
            // a native-host property; see `timing_reliable` there). This gate proves cross-arch DETERMINISM
            // — every frozen pin + threaded determinism — which is robust under emulation.
            xrun.has_side_effects = true; // never cache-skip the cross-arch determinism gate
            if (prev_cross_run) |p| xrun.step.dependOn(p); // serialize the qemu runs (see above)
            prev_cross_run = &xrun.step;
            cross_step.dependOn(&xrun.step);
        }
    }
}
