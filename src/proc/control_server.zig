//! The live AI control server (SPEC §13, PLAN.md §17.3): the WRITE half of the control plane. `qserver.zig`
//! lets an AI OBSERVE live sims read-only; this owns MUTABLE sims and DRIVES them — step, reload, fork,
//! snapshot, migrate — over a `control_wire` command socket. It is the socket-driven exogenous trigger the
//! §16 `Trigger` seam anticipated: an AI operator reacts to whatever it likes (out-of-band) and emits a
//! command; the server applies it through the EXACT SAME primitives the replay driver uses
//! (`stepDynamic`, `control.applyReload`, `snapshot`, `migrate`), so a live driven session is bit-identical
//! to its captured-then-replayed twin (the proc gate pins this).
//!
//! `R` is comptime-fixed per server (the data↔code boundary, as everywhere in §13). A MIGRATE re-types the
//! World — which a single-R server STRUCTURALLY cannot host past — so, exactly like `control.runWithControl`,
//! the migrate arm SNAPSHOTS the pre-migration World to canonical bytes, replies `migrated{bytes}`, and
//! SURRENDERS that sim. The cross-R continuation is `control.runSession`'s job (the operator feeds the
//! returned bytes to an `R_next` server / driver). This is the documented boundary, not a stub.

const std = @import("std");
const Allocator = std.mem.Allocator;
const serialize = @import("../serialize.zig");
const worldmod = @import("../world.zig");
const reload = @import("../reload.zig");
const control = @import("../control.zig");
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const stepmod = @import("../step.zig");
const snapshotmod = @import("../snapshot.zig");
const recorder = @import("../recorder.zig");
const input = @import("../input.zig");
const wire = @import("../query/wire.zig");
const engine = @import("../query/engine.zig");
const fingerprint = @import("../migrate/fingerprint.zig");
const cw = @import("control_wire.zig");
const net = std.Io.net;

pub const ServerError = control.RunError; // serialize.Error || Allocator.Error || error{ TooManySystems, BadSetId, NonMonotonicSchedule }

/// Canonical bytes of registry `R`'s schema fingerprint (count + each {kind_id u16, size u32}). The
/// `hello` handshake compares these; over a persistent `serveSession` connection a client whose
/// fingerprint does NOT match is refused (`schema_mismatch`) before any sim command, rather than silently
/// fed incompatible bytes. Allocated by the caller (the server owns the result).
pub fn fingerprintBytes(comptime R: type, gpa: Allocator) Allocator.Error![]u8 {
    const fp = fingerprint.currentFingerprint(R);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    serialize.putInt(&sink, u32, @intCast(fp.len)) catch return error.OutOfMemory;
    for (fp) |k| {
        serialize.putInt(&sink, u16, k.kind_id) catch return error.OutOfMemory;
        serialize.putInt(&sink, u32, k.size) catch return error.OutOfMemory;
    }
    return buf.toOwnedSlice(gpa);
}

pub fn ControlServer(comptime R: type, comptime systems: []const Sys(R)) type {
    return struct {
        const Self = @This();
        const World = worldmod.World(R);

        /// A live, MUTABLE sim the server drives. Owns its World, its provenance recorder (whose `.log`
        /// backs the read-only query surface — so a live-stepped sim is fully observable), and its active
        /// system set + exec order + set_id (mutated in place by reload). Every sim holds exactly ONE
        /// `acquireSet(set_id)` reference for its CURRENT set_id (spawn/fork acquire; reload swaps; teardown
        /// /migrate release) — see the refcount below.
        pub const OwnedSim = struct {
            world: World,
            rec: recorder.Recorder,
            set: reload.SystemSet(R),
            exec: []u16,
            set_id: u16,

            // deinit frees only what the sim allocates directly; releasing the set's `acquireSet` reference
            // (which unloads the dlopen handle at the last release) is the SERVER's job — see Self.deinit.
            fn deinit(s: *OwnedSim, gpa: Allocator) void {
                gpa.free(s.exec);
                s.world.deinit(gpa);
                s.rec.deinit();
                s.* = undefined;
            }
        };

        /// One refcounted loaded set. Multiple in-process sims (a parent + its forks, or several spawns of
        /// the same id) SHARE one `reload.SystemSet(R)` — critical for a real `NativeLibSource`, whose `.so`
        /// is a SINGLE handle (a 2nd `load` is `AlreadyLoaded`, and unloading it while a sibling still
        /// references its fn-ptrs is a use-after-unload). The handle is `sets.load`ed at the first acquire
        /// and `sets.unload`ed at the last release. Under `inProcessSource` load/unload are no-ops, so this
        /// is pure bookkeeping (the set is a static slice). `control.applyReload`'s single-sim unload
        /// discipline is the one-process-per-sim (§13) analog; this is its in-process multi-sim generalization.
        const LoadedSet = struct { set: reload.SystemSet(R), rc: u32 };

        gpa: Allocator,
        sets: control.SetTable(R),
        sims: std.AutoHashMapUnmanaged(u32, *OwnedSim) = .empty,
        loaded: std.AutoHashMapUnmanaged(u16, LoadedSet) = .empty,
        fp_bytes: []const u8,
        /// The capability secret a client's `hello.token` must equal before any command is serviced over a
        /// `serveSession` connection. `null` = open (fingerprint-only). Borrowed; the caller owns its bytes.
        auth_token: ?[]const u8 = null,

        pub fn init(gpa: Allocator, sets: control.SetTable(R)) Allocator.Error!Self {
            return .{ .gpa = gpa, .sets = sets, .fp_bytes = try fingerprintBytes(R, gpa) };
        }

        /// True iff the handshake is acceptable: the client's R-fingerprint matches AND (no secret is
        /// configured OR the client's token matches it). A constant-time token compare keeps a wrong-length
        /// or wrong-value token from leaking via early exit.
        fn handshakeOk(self: *const Self, fp: []const u8, token: []const u8) bool {
            if (!std.mem.eql(u8, fp, self.fp_bytes)) return false;
            const secret = self.auth_token orelse return true;
            if (token.len != secret.len) return false;
            var diff: u8 = 0;
            for (token, secret) |a, b| diff |= a ^ b;
            return diff == 0;
        }

        pub fn deinit(self: *Self) void {
            var it = self.sims.valueIterator();
            while (it.next()) |sp| {
                self.releaseSet(sp.*.set_id); // last release of each set_id unloads its handle
                sp.*.deinit(self.gpa);
                self.gpa.destroy(sp.*);
            }
            self.sims.deinit(self.gpa);
            self.loaded.deinit(self.gpa); // every entry should already be at rc 0 + removed by releaseSet
            self.gpa.free(self.fp_bytes);
            self.* = undefined;
        }

        /// Acquire a refcounted reference to `set_id`'s loaded set (loading it on the first acquire). The
        /// returned `SystemSet(R)` is shared — callers must NOT unload it directly; pair with `releaseSet`.
        fn acquireSet(self: *Self, set_id: u16) ServerError!reload.SystemSet(R) {
            if (self.loaded.getPtr(set_id)) |ls| {
                ls.rc += 1;
                return ls.set;
            }
            const set = try self.sets.load(set_id); // BadSetId (or a loader error mapped to it)
            errdefer self.sets.unload(set_id);
            try self.loaded.put(self.gpa, set_id, .{ .set = set, .rc = 1 });
            return set;
        }

        /// Release one reference to `set_id`; the last release unloads the handle (dlopen) and drops the
        /// cache entry. Safe to call for an id the server loaded; a no-op for an unknown id.
        fn releaseSet(self: *Self, set_id: u16) void {
            const ls = self.loaded.getPtr(set_id) orelse return;
            ls.rc -= 1;
            if (ls.rc == 0) {
                self.sets.unload(set_id);
                _ = self.loaded.remove(set_id);
            }
        }

        /// Take ownership of `w0` as a new live sim under `sim_id`, running `start_set_id`. The caller's
        /// World is consumed (its memory is now the sim's). Errors leave `w0` deinitialized.
        pub fn spawn(self: *Self, sim_id: u32, w0: World, start_set_id: u16) ServerError!void {
            var w = w0;
            errdefer w.deinit(self.gpa);
            if (self.sims.contains(sim_id)) return error.BadSetId; // sim_id collision (caller error)
            const set = try self.acquireSet(start_set_id); // refcounted load (BadSetId)
            errdefer self.releaseSet(start_set_id); // pair the acquire on every failure-after-acquire path
            const exec = try schedule.execOrderDynamic(R, self.gpa, set.systems);
            errdefer self.gpa.free(exec);
            const os = try self.gpa.create(OwnedSim);
            errdefer self.gpa.destroy(os);
            os.* = .{ .world = w, .rec = recorder.Recorder.init(self.gpa), .set = set, .exec = exec, .set_id = start_set_id };
            try self.sims.put(self.gpa, sim_id, os);
        }

        /// The multiplexing/dispatch CORE — pure of socket IO (testable everywhere). Decode one command
        /// frame, mutate the addressed sim, write the `ControlResponse` into `out`. A TYPED failure
        /// (unknown sim, bad set/migration id) is written as a `.err` RESPONSE (the AI must observe it) and
        /// returns normally — the server stays up. Only OOM/`serialize.Error` from encoding the reply
        /// escapes as an error.
        pub fn handle(self: *Self, gpa: Allocator, frame: []const u8, out: *serialize.ByteSink) (serialize.Error || Allocator.Error)!void {
            var dec = cw.decodeCommand(gpa, frame) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return cw.writeResponse(out, .{ .err = .bad_command }), // malformed frame → typed err
            };
            defer dec.deinit();
            return self.dispatch(gpa, dec.sim_id, dec.cmd, out);
        }

        /// Dispatch a DECODED command against the addressed sim — the pure dispatch core (`serveSession`
        /// layers the per-connection hello gate on top; direct callers/tests dispatch unauthenticated).
        /// `cmd`'s variable-length slices must outlive this call (they point into the caller's
        /// `DecodedCommand` arena). `hello` is advisory HERE — it REPORTS whether the client's R-fingerprint
        /// matches; ENFORCEMENT (refusing a non-matching client) is `serveSession`'s job.
        fn dispatch(self: *Self, gpa: Allocator, sim_id: u32, cmd: cw.ControlCommand, out: *serialize.ByteSink) (serialize.Error || Allocator.Error)!void {
            // hello carries no sim — it's the R-fingerprint + capability-token handshake.
            if (cmd == .hello) {
                const ok = self.handshakeOk(cmd.hello.fingerprint, cmd.hello.token);
                return cw.writeResponse(out, .{ .hello_ok = .{ .ok = ok } });
            }

            const sim = self.sims.get(sim_id) orelse return cw.writeResponse(out, .{ .err = .unknown_sim });

            switch (cmd) {
                .hello => unreachable, // handled above
                .query => |qbytes| {
                    const eng = engine.Engine(R, systems).init(&sim.world, &sim.rec.log);
                    var qresp: std.ArrayList(u8) = .empty;
                    defer qresp.deinit(gpa);
                    var qsink = serialize.ByteSink{ .list = &qresp, .gpa = gpa };
                    wire.respond(R, systems, gpa, eng, qbytes, &qsink) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return cw.writeResponse(out, .{ .err = .bad_command }), // malformed query bytes
                    };
                    return cw.writeResponse(out, .{ .query_result = qresp.items });
                },
                .step => |s| {
                    self.stepSim(sim, s.n, s.inline_inputs) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return cw.writeResponse(out, .{ .err = .bad_command }),
                    };
                    const d = (sim.world.digest(self.gpa) catch return error.OutOfMemory).hash;
                    return cw.writeResponse(out, .{ .stepped = .{ .tick = sim.world.tick, .digest = d } });
                },
                .reload => |r| {
                    self.reloadSim(sim, r.set_id) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.BadSetId => return cw.writeResponse(out, .{ .err = .bad_set_id }),
                        error.TooManySystems => return cw.writeResponse(out, .{ .err = .bad_set_id }),
                        else => return cw.writeResponse(out, .{ .err = .bad_command }),
                    };
                    return cw.writeResponse(out, .{ .reloaded = .{ .set_id = r.set_id, .tick = sim.world.tick } });
                },
                .fork => |f| {
                    if (self.sims.contains(f.new_sim_id)) return cw.writeResponse(out, .{ .err = .sim_id_in_use });
                    const child = self.forkSim(sim, f.tick_budget, f.diverged_inputs) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return cw.writeResponse(out, .{ .err = .bad_command }),
                    };
                    self.sims.put(self.gpa, f.new_sim_id, child) catch {
                        // forkSim already acquired child.set_id (rc++); release it here (BEFORE deinit, which
                        // sets child.* = undefined) or the refcount orphans and the handle never unloads.
                        self.releaseSet(child.set_id);
                        child.deinit(self.gpa);
                        self.gpa.destroy(child);
                        return error.OutOfMemory;
                    };
                    const d = (child.world.digest(self.gpa) catch return error.OutOfMemory).hash;
                    return cw.writeResponse(out, .{ .forked = .{ .new_sim_id = f.new_sim_id, .tick = child.world.tick, .digest = d } });
                },
                .snapshot => {
                    var snap = snapshotmod.snapshot(R, self.gpa, &sim.world) catch return error.OutOfMemory;
                    defer snap.deinit(self.gpa);
                    return cw.writeResponse(out, .{ .snapshot_bytes = snap.bytes });
                },
                .migrate => |m| {
                    // The R re-typing boundary: snapshot the pre-migration World, reply with the canonical
                    // bytes, and SURRENDER the sim (a single-R server cannot host R_next — runSession does
                    // the cross-R continuation). Identical to control.runWithControl's `.migrate` arm.
                    var snap = snapshotmod.snapshot(R, self.gpa, &sim.world) catch return error.OutOfMemory;
                    defer snap.deinit(self.gpa);
                    const at = sim.world.tick;
                    try cw.writeResponse(out, .{ .migrated = .{ .migration_id = m.migration_id, .at_tick = at, .bytes = snap.bytes } });
                    _ = self.sims.remove(sim_id);
                    self.releaseSet(sim.set_id); // drop this sim's set reference (unloads the handle at the last)
                    sim.deinit(self.gpa);
                    self.gpa.destroy(sim);
                    return;
                },
            }
        }

        /// Advance `sim` by `n` ticks, feeding `inline_inputs[k]` at the k-th tick of this batch (EMPTY past
        /// the end), recording provenance into `sim.rec`. Single-sourced with `stepDynamic` — the live step
        /// is the identical computation to the replay driver's tick. Uses `self.gpa` (the server-owned
        /// allocator that owns every sim's World), NOT the transient per-command allocator.
        fn stepSim(self: *Self, sim: *OwnedSim, n: u64, inline_inputs: []const input.Input) ServerError!void {
            const gpa = self.gpa;
            var k: u64 = 0;
            while (k < n) : (k += 1) {
                const in = if (k < inline_inputs.len) inline_inputs[@intCast(k)] else input.EMPTY;
                const nxt = try stepmod.stepDynamic(R, gpa, sim.world, in, sim.set.systems, sim.exec, &sim.rec);
                sim.world.deinit(gpa);
                sim.world = nxt; // only reassigned after a successful step (an error leaves the prior World intact)
            }
        }

        /// Swap `sim`'s running set to `new_id` IN PLACE (same R) — the refcount-aware analog of
        /// `control.applyReload`, with identical World semantics (`reloadAt` is a documented World no-op +
        /// `execOrderDynamic` recompute), so a live reload and the replay driver's reload reach the same
        /// World. Acquires the new reference BEFORE releasing the old (a reload-to-same keeps the handle
        /// loaded), and computes the new exec BEFORE freeing the old (an error leaves `sim` intact).
        fn reloadSim(self: *Self, sim: *OwnedSim, new_id: u16) ServerError!void {
            const newset = try self.acquireSet(new_id); // refcounted load (BadSetId)
            errdefer self.releaseSet(new_id); // undo the acquire if the exec recompute fails
            const new_exec = try schedule.execOrderDynamic(R, self.gpa, newset.systems); // TooManySystems; old exec intact
            const old_id = sim.set_id;
            self.gpa.free(sim.exec);
            sim.exec = new_exec;
            sim.set = reload.reloadAt(R, sim.set, newset); // BY NAME — the documented World no-op
            sim.set_id = new_id;
            self.releaseSet(old_id); // AFTER the swap (never unload a handle whose fn-ptrs just ran a tick)
        }

        /// §6 fork: branch `parent` into an INDEPENDENT child (via a snapshot round-trip), then advance it
        /// `tick_budget` ticks under `diverged_inputs`. The child coexists with the parent — a divergent
        /// timeline. It ACQUIRES its own refcounted reference to the parent's set_id (sharing one dlopen
        /// handle via the refcount, so no `AlreadyLoaded`, and the handle outlives WHICHEVER sim is torn
        /// down first — fixing the parent-teardown-dangles-fork hazard a raw borrow had).
        ///
        /// Ownership is built into `os` field-by-field so every errdefer targets `os`'s LIVE world — the
        /// advance loop reassigns `os.world`, and `errdefer os.world.deinit(gpa)` always frees exactly the
        /// current one (never a stale value-copy aliasing freed memory). A mid-loop OOM frees the in-flight
        /// world ONCE and leaks nothing. Uses `self.gpa` (the sim-owning allocator) throughout, so the child
        /// the caller registers + later `deinit`s under `self.gpa` is single-allocator-consistent.
        fn forkSim(self: *Self, parent: *OwnedSim, tick_budget: u64, diverged_inputs: []const input.Input) ServerError!*OwnedSim {
            const gpa = self.gpa;
            const os = try gpa.create(OwnedSim);
            errdefer gpa.destroy(os);
            os.rec = recorder.Recorder.init(gpa);
            errdefer os.rec.deinit();
            {
                var snap = try snapshotmod.snapshot(R, gpa, &parent.world);
                defer snap.deinit(gpa);
                var reader = serialize.ByteReader{ .bytes = snap.bytes };
                const parts = try serialize.readWorld(R, gpa, &reader); // restore into an independent World
                os.world = World.fromParts(parts);
            }
            errdefer os.world.deinit(gpa); // from here `os` is the SOLE owner of the in-flight world
            os.set = try self.acquireSet(parent.set_id); // refcounted share of the parent's set (rc++)
            errdefer self.releaseSet(parent.set_id);
            os.set_id = parent.set_id;
            os.exec = try schedule.execOrderDynamic(R, gpa, os.set.systems);
            errdefer gpa.free(os.exec);

            var k: u64 = 0;
            while (k < tick_budget) : (k += 1) {
                const in = if (k < diverged_inputs.len) diverged_inputs[@intCast(k)] else input.EMPTY;
                const nxt = try stepmod.stepDynamic(R, gpa, os.world, in, os.set.systems, os.exec, &os.rec);
                os.world.deinit(gpa);
                os.world = nxt;
            }
            return os;
        }

        /// A control frame larger than this is rejected before allocation — a hostile/buggy peer's `u32`
        /// length (up to ~4 GiB) must NEVER drive a single huge `readAlloc` pre-allocation (the job.zig /
        /// net_worker JOB_CAP discipline, applied to the persistent control socket).
        pub const CMD_CAP: usize = 16 * 1024 * 1024;

        /// PERSISTENT-connection control session: accept ONE connection, then read+apply up to `max_cmds`
        /// length-framed `[u32 len][GKZC2 command]` requests on that SAME stream — replying each
        /// `[u32 len][GKZD1 response]` — until EOF (the client closed) or `max_cmds`. This is what makes it
        /// a real control plane: an AI drives a SEQUENCE of mutations over one connection, the sim evolving
        /// across them. Run alongside the client in an `Io.Group` (the proc gate does exactly this).
        ///
        /// ENFORCES the hello handshake (`unauthorized`): any sim command before a hello that matches BOTH
        /// this server's R-fingerprint AND its capability token (`auth_token`, if set) is refused — so a
        /// wrong-R OR unauthenticated client can never mutate/observe the sim, the contract `dispatch`'s
        /// advisory `hello` only reports. An oversized frame (`> CMD_CAP`) drops the session unallocated.
        pub fn serveSession(self: *Self, io: std.Io, gpa: Allocator, server: *net.Server, max_cmds: usize) !void {
            var stream = try server.accept(io);
            defer stream.close(io);
            var rbuf: [8192]u8 = undefined;
            var sr = stream.reader(io, &rbuf);
            const r = &sr.interface;
            var wbuf: [8192]u8 = undefined;
            var sw = stream.writer(io, &wbuf);
            const w = &sw.interface;

            var authed = false; // set true once a hello matching this server's R-fingerprint arrives
            var i: usize = 0;
            while (i < max_cmds) : (i += 1) {
                const lh = r.takeArray(4) catch |e| switch (e) {
                    error.EndOfStream => break, // client closed cleanly between commands
                    else => return e,
                };
                const len = std.mem.readInt(u32, lh, .little);
                if (len > CMD_CAP) break; // oversized frame → drop the session (no multi-GB pre-alloc)
                const frame = try r.readAlloc(gpa, len);
                defer gpa.free(frame);

                var resp: std.ArrayList(u8) = .empty;
                defer resp.deinit(gpa);
                var osink = serialize.ByteSink{ .list = &resp, .gpa = gpa };
                fill: {
                    var dec = cw.decodeCommand(gpa, frame) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            try cw.writeResponse(&osink, .{ .err = .bad_command });
                            break :fill;
                        },
                    };
                    defer dec.deinit();
                    if (dec.cmd == .hello) {
                        // gate on BOTH the R-fingerprint and the capability token (if a secret is set)
                        authed = self.handshakeOk(dec.cmd.hello.fingerprint, dec.cmd.hello.token);
                        try cw.writeResponse(&osink, .{ .hello_ok = .{ .ok = authed } });
                    } else if (!authed) {
                        try cw.writeResponse(&osink, .{ .err = .unauthorized }); // refuse: no valid (R + token) hello yet
                    } else {
                        try self.dispatch(gpa, dec.sim_id, dec.cmd, &osink);
                    }
                }

                var ol: [4]u8 = undefined;
                std.mem.writeInt(u32, &ol, @intCast(resp.items.len), .little);
                try w.writeAll(&ol);
                try w.writeAll(resp.items);
                try w.flush();
            }
        }
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests — the dispatch CORE (handle()) against an in-process 2-set sim. The REAL socket session +
// the driven-session == replayed-session byte-equality witness are pinned in proc_gate.zig.
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const q = @import("../query.zig");
const simctx = @import("../simctx.zig");

const Counter = struct {
    n: i64,
    pub const kind_id: u16 = 1;
};
const TR = Registry(.{Counter});
fn incA(ctx: *simctx.SimCtx(TR), qq: *q.Query(TR, .{q.Write(Counter)})) Allocator.Error!void {
    _ = ctx;
    while (qq.next()) |row| row.write(Counter).n += 1;
}
fn incB(ctx: *simctx.SimCtx(TR), qq: *q.Query(TR, .{q.Write(Counter)})) Allocator.Error!void {
    _ = ctx;
    while (qq.next()) |row| row.write(Counter).n += 10; // a DIFFERENT set: the reload changes behaviour
}
const set_a = [_]Sys(TR){schedule.system(TR, "incA", incA)};
const set_b = [_]Sys(TR){schedule.system(TR, "incB", incB)};
const srcs = [_]reload.SystemSource(TR){ reload.inProcessSource(TR, &set_a), reload.inProcessSource(TR, &set_b) };
const test_sets = control.SetTable(TR){ .sources = &srcs };

// A COUNTING source double — proves the dlopen-handle refcount (inProcessSource's load/unload are no-ops,
// so they cannot witness it). Each set_id maps to its own counter; the server must load a shared set_id
// exactly ONCE across N sims and unload it exactly ONCE at the last release.
const LoadCount = struct { loads: u32 = 0, unloads: u32 = 0 };
var count0: LoadCount = .{};
var count1: LoadCount = .{};
fn cLoad0(ctx: *anyopaque) anyerror!reload.SystemSet(TR) {
    @as(*LoadCount, @ptrCast(@alignCast(ctx))).loads += 1;
    return .{ .systems = &set_a };
}
fn cLoad1(ctx: *anyopaque) anyerror!reload.SystemSet(TR) {
    @as(*LoadCount, @ptrCast(@alignCast(ctx))).loads += 1;
    return .{ .systems = &set_b };
}
fn cUnload0(ctx: *anyopaque) void {
    @as(*LoadCount, @ptrCast(@alignCast(ctx))).unloads += 1;
}
fn cUnload1(ctx: *anyopaque) void {
    @as(*LoadCount, @ptrCast(@alignCast(ctx))).unloads += 1;
}
const counting_srcs = [_]reload.SystemSource(TR){
    .{ .ctx = &count0, .loadFn = cLoad0, .unloadFn = cUnload0 },
    .{ .ctx = &count1, .loadFn = cLoad1, .unloadFn = cUnload1 },
};
const counting_sets = control.SetTable(TR){ .sources = &counting_srcs };

fn seedCounter(gpa: Allocator) Allocator.Error!worldmod.World(TR) {
    var w = worldmod.World(TR).init(0);
    errdefer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Counter, .{ .n = 0 });
    return w;
}

const CS = ControlServer(TR, &set_a);

fn sendCmd(srv: *CS, gpa: Allocator, sim_id: u32, cmd: cw.ControlCommand) !cw.DecodedResponse {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);
    var fsink = serialize.ByteSink{ .list = &frame, .gpa = gpa };
    try cw.writeCommand(&fsink, sim_id, cmd);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var osink = serialize.ByteSink{ .list = &out, .gpa = gpa };
    try srv.handle(gpa, frame.items, &osink);
    return cw.decodeResponse(gpa, out.items);
}

test "step advances the live sim; the digest matches an independent stepDynamic run" {
    const gpa = testing.allocator;
    var srv = try CS.init(gpa, test_sets);
    defer srv.deinit();
    try srv.spawn(1, try seedCounter(gpa), 0);

    var r1 = try sendCmd(&srv, gpa, 1, .{ .step = .{ .n = 3, .inline_inputs = &.{} } });
    defer r1.deinit();
    try testing.expectEqual(@as(u64, 3), r1.resp.stepped.tick);

    // independent: 3 stepDynamic ticks over set_a → same digest (the live step IS stepDynamic)
    var w = try seedCounter(gpa);
    defer w.deinit(gpa);
    const exec = try schedule.execOrderDynamic(TR, gpa, &set_a);
    defer gpa.free(exec);
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        const nxt = try stepmod.stepDynamic(TR, gpa, w, input.EMPTY, &set_a, exec, null);
        w.deinit(gpa);
        w = nxt;
    }
    try testing.expectEqual((try w.digest(gpa)).hash, r1.resp.stepped.digest);
    // counter advanced by +1/tick (set_a) → n == 3
    try testing.expectEqual(@as(i64, 3), w.get(.{ .index = 0, .generation = 0 }, Counter).?.n);
}

test "reload swaps behaviour mid-run (set_a +1 → set_b +10)" {
    const gpa = testing.allocator;
    var srv = try CS.init(gpa, test_sets);
    defer srv.deinit();
    try srv.spawn(1, try seedCounter(gpa), 0);

    var r1 = try sendCmd(&srv, gpa, 1, .{ .step = .{ .n = 2, .inline_inputs = &.{} } }); // +1,+1 → 2
    defer r1.deinit();
    var r2 = try sendCmd(&srv, gpa, 1, .{ .reload = .{ .set_id = 1 } });
    defer r2.deinit();
    try testing.expectEqual(@as(u16, 1), r2.resp.reloaded.set_id);
    var r3 = try sendCmd(&srv, gpa, 1, .{ .step = .{ .n = 1, .inline_inputs = &.{} } }); // +10 → 12
    defer r3.deinit();

    const sim = srv.sims.get(1).?;
    try testing.expectEqual(@as(i64, 12), sim.world.get(.{ .index = 0, .generation = 0 }, Counter).?.n);
}

test "fork branches an independent timeline coexisting with the parent" {
    const gpa = testing.allocator;
    var srv = try CS.init(gpa, test_sets);
    defer srv.deinit();
    try srv.spawn(1, try seedCounter(gpa), 0);
    var r1 = try sendCmd(&srv, gpa, 1, .{ .step = .{ .n = 2, .inline_inputs = &.{} } }); // parent n=2
    defer r1.deinit();

    // fork sim 2 from sim 1 @ n=2, advance the child 3 more ticks → child n=5; parent stays n=2
    var r2 = try sendCmd(&srv, gpa, 1, .{ .fork = .{ .new_sim_id = 2, .diverged_inputs = &.{}, .tick_budget = 3 } });
    defer r2.deinit();
    try testing.expectEqual(@as(u32, 2), r2.resp.forked.new_sim_id);
    try testing.expectEqual(@as(u64, 5), r2.resp.forked.tick);

    try testing.expectEqual(@as(i64, 2), srv.sims.get(1).?.world.get(.{ .index = 0, .generation = 0 }, Counter).?.n);
    try testing.expectEqual(@as(i64, 5), srv.sims.get(2).?.world.get(.{ .index = 0, .generation = 0 }, Counter).?.n);
}

fn spawnStepFork(gpa: Allocator) !void {
    var srv = try CS.init(gpa, test_sets);
    defer srv.deinit();
    try srv.spawn(1, try seedCounter(gpa), 0);
    var r1 = try sendCmd(&srv, gpa, 1, .{ .step = .{ .n = 1, .inline_inputs = &.{} } });
    r1.deinit();
    var r2 = try sendCmd(&srv, gpa, 1, .{ .fork = .{ .new_sim_id = 2, .diverged_inputs = &.{}, .tick_budget = 3 } });
    r2.deinit();
}

test "fork survives allocation failure at every point — no leak, no double-free (the forkSim cleanup witness)" {
    // checkAllAllocationFailures injects OOM at each allocation index in turn; the run must either succeed
    // or return error.OutOfMemory with the testing allocator reporting NO leak and NO double-free. This is
    // the regression witness for the forkSim mid-advance-loop error path (a stale value-copy errdefer would
    // double-free here; a missing errdefer would leak the in-flight World).
    try std.testing.checkAllAllocationFailures(testing.allocator, spawnStepFork, .{});
}

test "unknown sim / bad set / sim_id collision are TYPED err responses (never a panic)" {
    const gpa = testing.allocator;
    var srv = try CS.init(gpa, test_sets);
    defer srv.deinit();
    try srv.spawn(1, try seedCounter(gpa), 0);

    var r1 = try sendCmd(&srv, gpa, 999, .{ .step = .{ .n = 1, .inline_inputs = &.{} } });
    defer r1.deinit();
    try testing.expectEqual(cw.ControlErr.unknown_sim, r1.resp.err);

    var r2 = try sendCmd(&srv, gpa, 1, .{ .reload = .{ .set_id = 7 } }); // only 0,1 exist
    defer r2.deinit();
    try testing.expectEqual(cw.ControlErr.bad_set_id, r2.resp.err);

    var r3 = try sendCmd(&srv, gpa, 1, .{ .fork = .{ .new_sim_id = 1, .diverged_inputs = &.{}, .tick_budget = 0 } }); // 1 in use
    defer r3.deinit();
    try testing.expectEqual(cw.ControlErr.sim_id_in_use, r3.resp.err);
}

test "snapshot reflects live state; migrate surrenders the sim with canonical bytes" {
    const gpa = testing.allocator;
    var srv = try CS.init(gpa, test_sets);
    defer srv.deinit();
    try srv.spawn(1, try seedCounter(gpa), 0);
    var r0 = try sendCmd(&srv, gpa, 1, .{ .step = .{ .n = 4, .inline_inputs = &.{} } });
    defer r0.deinit();

    var rs = try sendCmd(&srv, gpa, 1, .{ .snapshot = {} });
    defer rs.deinit();
    // the snapshot restores to a World whose counter == 4
    var reader = serialize.ByteReader{ .bytes = rs.resp.snapshot_bytes };
    const parts = try serialize.readWorld(TR, gpa, &reader);
    var wsnap = worldmod.World(TR).fromParts(parts);
    defer wsnap.deinit(gpa);
    try testing.expectEqual(@as(i64, 4), wsnap.get(.{ .index = 0, .generation = 0 }, Counter).?.n);

    var rm = try sendCmd(&srv, gpa, 1, .{ .migrate = .{ .migration_id = 0 } });
    defer rm.deinit();
    try testing.expectEqual(@as(u64, 4), rm.resp.migrated.at_tick);
    try testing.expect(rm.resp.migrated.bytes.len > 0);
    try testing.expect(srv.sims.get(1) == null); // surrendered

    // a hello with the right fingerprint succeeds; a wrong one is refused (token-less server)
    var rh = try sendCmd(&srv, gpa, 0, .{ .hello = .{ .fingerprint = srv.fp_bytes, .token = "" } });
    defer rh.deinit();
    try testing.expect(rh.resp.hello_ok.ok);
    var rh2 = try sendCmd(&srv, gpa, 0, .{ .hello = .{ .fingerprint = "wrong", .token = "" } });
    defer rh2.deinit();
    try testing.expect(!rh2.resp.hello_ok.ok);
}

test "auth: with a secret set, the right fingerprint + WRONG token is refused; the right token is accepted" {
    const gpa = testing.allocator;
    var srv = try CS.init(gpa, test_sets);
    srv.auth_token = "s3cr3t"; // the capability secret the AI operator must present
    defer srv.deinit();
    try srv.spawn(1, try seedCounter(gpa), 0);

    // right R, NO token → handshake fails (a token IS required now)
    var r0 = try sendCmd(&srv, gpa, 0, .{ .hello = .{ .fingerprint = srv.fp_bytes, .token = "" } });
    defer r0.deinit();
    try testing.expect(!r0.resp.hello_ok.ok);
    // right R, WRONG token → fails
    var r1 = try sendCmd(&srv, gpa, 0, .{ .hello = .{ .fingerprint = srv.fp_bytes, .token = "guess" } });
    defer r1.deinit();
    try testing.expect(!r1.resp.hello_ok.ok);
    // right R, RIGHT token → succeeds
    var r2 = try sendCmd(&srv, gpa, 0, .{ .hello = .{ .fingerprint = srv.fp_bytes, .token = "s3cr3t" } });
    defer r2.deinit();
    try testing.expect(r2.resp.hello_ok.ok);
    // right token but WRONG R → still refused (both must match)
    var r3 = try sendCmd(&srv, gpa, 0, .{ .hello = .{ .fingerprint = "nope", .token = "s3cr3t" } });
    defer r3.deinit();
    try testing.expect(!r3.resp.hello_ok.ok);
}

test "the dlopen set refcount: N sims share ONE load of a set_id; unload only at the last release" {
    const gpa = testing.allocator;
    count0 = .{};
    count1 = .{};
    {
        var srv = try ControlServer(TR, &set_a).init(gpa, counting_sets);
        defer srv.deinit();

        try srv.spawn(1, try seedCounter(gpa), 0); // set 0: load #1
        var rf = try sendCmd(&srv, gpa, 1, .{ .fork = .{ .new_sim_id = 2, .diverged_inputs = &.{}, .tick_budget = 1 } });
        rf.deinit(); // fork shares set 0 (rc 1→2) — must NOT trigger a 2nd load (a real .so would AlreadyLoaded)
        try testing.expectEqual(@as(u32, 1), count0.loads);
        try testing.expectEqual(@as(u32, 0), count0.unloads);

        // reload sim 1 to set 1 (load #1 of set 1, rc set0 2→1 — still held by the fork, so NOT unloaded yet)
        var rr = try sendCmd(&srv, gpa, 1, .{ .reload = .{ .set_id = 1 } });
        rr.deinit();
        try testing.expectEqual(@as(u32, 1), count1.loads);
        try testing.expectEqual(@as(u32, 0), count0.unloads); // fork (sim 2) still references set 0
    } // srv.deinit releases sim1's set1 (last → unload) and sim2's set0 (last → unload)
    try testing.expectEqual(@as(u32, 1), count0.unloads); // exactly once, despite a parent+fork sharing it
    try testing.expectEqual(@as(u32, 1), count1.unloads);
}

test "fork is refcount-balanced under allocation failure at EVERY point (no orphaned set acquire)" {
    // For every allocation-failure index in spawn+fork, after teardown the set's loads MUST equal its
    // unloads — i.e. no acquireSet is ever orphaned, including the .fork put-failure path (the regression:
    // a child that forkSim acquired but `self.sims.put` failed to register must still be released). A
    // LOCAL counting source per iteration keeps the balance check per-run; an imbalance = a leaked handle.
    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var counts: LoadCount = .{};
        const local_srcs = [_]reload.SystemSource(TR){
            .{ .ctx = &counts, .loadFn = cLoad0, .unloadFn = cUnload0 },
            .{ .ctx = &counts, .loadFn = cLoad1, .unloadFn = cUnload1 },
        };
        const local_sets = control.SetTable(TR){ .sources = &local_srcs };
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = fa.allocator();
        {
            var srv = ControlServer(TR, &set_a).init(gpa, local_sets) catch {
                // OOM building the server before any set was acquired → nothing to balance
                try testing.expectEqual(counts.loads, counts.unloads);
                continue;
            };
            defer srv.deinit(); // releases every surviving sim's set on teardown
            const w0 = seedCounter(gpa) catch {
                continue;
            };
            srv.spawn(1, w0, 0) catch {
                continue;
            }; // spawn's own errdefer releases on a mid-spawn OOM
            var rf = sendCmd(&srv, gpa, 1, .{ .fork = .{ .new_sim_id = 2, .diverged_inputs = &.{}, .tick_budget = 0 } }) catch {
                continue; // fork OOM (incl. the put-failure path) must NOT orphan the acquire — checked post-deinit
            };
            rf.deinit();
        }
        // INVARIANT (the bug's witness): every load is paired by an unload, no matter where OOM struck.
        try testing.expectEqual(counts.loads, counts.unloads);
    }
}
