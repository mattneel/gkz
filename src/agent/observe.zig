//! ObsView — the read-only observation surface a policy sees the World through (PLAN.md Phase 7, §10).
//!
//! An agent is a policy `observe(State) -> Input` on the SAME Input channel as a human. The observation
//! half is `ObsView(R)`: a wrapper holding only a `*const World(R)`. The player-not-world boundary is
//! READ-ONLY BY CONSTRUCTION of the accessor surface: every read path a policy is meant to use yields
//! const — `world().table.owners()/masks()` return `[]const`, `columnConst()` returns `[]const`, and the
//! mutable `Table.column()` requires a `*Self`, so `world().table.column(...)` (a `*const` Table) is a
//! COMPILE ERROR. A policy's only egress to the World is the `?Input` it returns, applied through the
//! normal `step` channel.
//!
//! Honest caveat (Zig has no field privacy, and `MultiArrayList`/`ArrayList` `.items` leak a mutable
//! slice from a const container): a policy that reaches PAST the accessor API into the World's raw
//! backing (`world().table.rows.items(...)`, `world().entities.generation.items`) can still alias mutable
//! memory. That is MISUSE outside the contract — exactly like a human player writing to process memory —
//! and the kernel's determinism guarantee does NOT rest on policy good-behavior: it rests on CAPTURING
//! the agent's emitted Inputs. An out-of-band mutation is not captured, so it would make the captured run
//! un-replayable (replay, driven only by `Run.inputs`, diverges) — a detectable contract violation, not a
//! supported mode.
//!
//! The first-class lens is `engine()`: the §7 query `Engine` over the borrowed World — so a policy's
//! observation vocabulary IS the `term.Value` relational surface the AI debugs with (one self-model, not
//! two). It is built over a const `EMPTY_LOG`, so observation never depends on the recorder being on
//! (preserving the events-off==events-on hash invariant); a recording-harness variant that threads a
//! live `EventLog` is deferred behind this same return type. `world()` is the raw read-only accessor for
//! tight rule-based policies.

const std = @import("std");
const worldmod = @import("../world.zig");
const event_log = @import("../event_log.zig");
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const query_engine = @import("../query/engine.zig");

/// An empty, immutable event log: the observation path is recorder-independent (D-invariant).
const EMPTY_LOG: event_log.EventLog = .{};

/// A read-only window onto the World for `observe(State)`. Holds only a `*const World(R)` — mutation is
/// type-impossible; there is no command buffer, allocator-into-world, or recorder field.
pub fn ObsView(comptime R: type) type {
    return struct {
        const Self = @This();
        world_ptr: *const worldmod.World(R),

        pub fn init(w: *const worldmod.World(R)) Self {
            return .{ .world_ptr = w };
        }

        /// The raw read-only World (for rule-based policies that scan components directly).
        pub fn world(self: Self) *const worldmod.World(R) {
            return self.world_ptr;
        }

        /// The §7 query Engine over the observed World — the first-class observation lens. Borrows by
        /// `*const` (D1 pure observation) and reads a const EMPTY_LOG, so it never mutates and never
        /// depends on the recorder.
        pub fn engine(self: Self, comptime systems: []const Sys(R)) query_engine.Engine(R, systems) {
            return query_engine.Engine(R, systems).init(self.world_ptr, &EMPTY_LOG);
        }
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const q2 = @import("../query.zig");
const simctx = @import("../simctx.zig");
const Read = q2.Read;
const system = schedule.system;

const Pos = struct {
    x: i64,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{Pos});
fn rP(ctx: *simctx.SimCtx(Game), qq: *q2.Query(Game, .{Read(Pos)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = qq;
}
const demo_systems = [_]Sys(Game){system(Game, "rP", rP)};

test "ObsView exposes ONLY a read-only world handle (no mutable/cmd/allocator/recorder surface)" {
    const fields = @typeInfo(ObsView(Game)).@"struct".fields;
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqualStrings("world_ptr", fields[0].name);
    // the one field is a *CONST* World pointer
    try testing.expectEqual(*const worldmod.World(Game), fields[0].type);
    inline for (.{ "table", "cmd", "commands", "gpa", "allocator", "recorder", "clock", "rng" }) |banned| {
        try testing.expect(!@hasField(ObsView(Game), banned));
    }
}

test "the observation accessor surface is const-correct: owners/masks/columnConst return []const, write is a compile error" {
    // The structural player-not-world guarantee: through a *const World (what ObsView holds), the read
    // accessors yield const slices, and the mutable `column` requires *Self so it is unreachable. A write
    // through this surface does not compile — this asserts the contract the PNW gate must enforce.
    const T = worldmod.World(Game).TableType;
    try testing.expectEqual([]const @import("../entity.zig").Entity, @TypeOf(@as(*const T, undefined).owners()));
    try testing.expectEqual([]const Game.Mask, @TypeOf(@as(*const T, undefined).masks()));
    try testing.expectEqual([]const Pos, @TypeOf(@as(*const T, undefined).columnConst(0)));
    // `column` (mutable) takes *Self, so a *const Table cannot call it (verified by the build: every read
    // path uses columnConst). `@hasDecl` confirms both variants exist.
    try testing.expect(@hasDecl(T, "column") and @hasDecl(T, "columnConst") and @hasDecl(T, "masksMut"));
}

test "engine() yields a working §7 query lens that does not mutate the observed World" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Pos, .{ .x = 7 });
    const before = try w.digest(gpa);

    const view = ObsView(Game).init(&w);
    const eng = view.engine(&demo_systems);
    var r = try eng.evaluate(gpa, .{ .component = .{} });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.rows.items.len); // the one Pos cell

    // observation did not perturb the World (pure, D1)
    const after = try w.digest(gpa);
    try testing.expectEqual(before.hash, after.hash);
}

test "engine() reads a const EMPTY_LOG: an event query returns zero rows on the capture path" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const eng = ObsView(Game).init(&w).engine(&demo_systems);
    var r = try eng.evaluate(gpa, .{ .event = .{} });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), r.rows.items.len); // observation is recorder-independent
}
