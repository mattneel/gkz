//! The public §7 query surface: the `Query(R)` request vocabulary + the `Engine(R, systems)` that
//! evaluates it against a borrowed live sim (PLAN.md Phase 5, build-order step 6).
//!
//! `Query(R)` is a serializable tagged union — it IS the wire query language (GKZQ1, wire.zig) AND the
//! in-process API, with no second source of truth. `evaluate` is one exhaustive switch mapping each arm
//! to exactly one canonical producer, so determinism is auditable arm-by-arm. The Engine borrows the sim
//! by `*const` pointer and carries the system set at comptime, so it never mutates state (D1) and a
//! Phase-9 server can point one Engine at any live World/EventLog.
//!
//! `diverge`/`firstTickWhere`/`reach` are the OPERATOR half of §7 (the recursive/predicate shapes): they
//! take live `Run` pointers / a predicate / an exogenous adjacency that are inherently in-process, so
//! they are Engine methods (and a free generic `reach`), not wire-union arms. Phase 9 exposes them by
//! resolving handles against its sim registry; in-process callers pass the real references.

const std = @import("std");
const Allocator = std.mem.Allocator;

const term = @import("term.zig");
const resultmod = @import("result.zig");
const QueryResult = resultmod.QueryResult;
const relations = @import("relations.zig");
const catalog = @import("catalog.zig");
const divergemod = @import("diverge.zig");

const worldmod = @import("../world.zig");
const event_log = @import("../event_log.zig");
const EventLog = event_log.EventLog;
const EventId = @import("../event.zig").EventId;
const schedule = @import("../schedule.zig");
const Sys = schedule.Sys;
const runmod = @import("../vopr/run.zig");

/// The wire-serializable query vocabulary (the four canonical shapes Why/What-affects-X are here as
/// `why`/`what_writes`/`what_reads`; the catalog shapes are `schema`/`columns`). Each arm maps to one
/// canonical producer. Order is wire-stable (the tag is the arm index).
pub fn Query(comptime R: type) type {
    _ = R;
    return union(enum) {
        component: relations.ComponentFilter, // current state, optionally filtered
        event: relations.EventFilter, // the provenance log, optionally filtered
        caused_by_direct: EventId, // direct causal edges of one effect
        why: EventId, // transitive provenance (delegates to causeChain)
        what_writes: u16, // systems that write a kind (structural "what affects X")
        what_reads: u16, // systems that read a kind
        systems_all, // the full system dataflow graph
        schema, // relation_schema/3 (self-describing catalog)
        columns, // relation_column/4
    };
}

/// Borrows a live sim (`*const World`, `*const EventLog`) and carries the system set at comptime.
pub fn Engine(comptime R: type, comptime systems: []const Sys(R)) type {
    return struct {
        const Self = @This();
        world: *const worldmod.World(R),
        log: *const EventLog,

        pub fn init(world: *const worldmod.World(R), log: *const EventLog) Self {
            return .{ .world = world, .log = log };
        }

        /// Evaluate a wire query into a canonical result. Pure observation — no state mutation (D1).
        pub fn evaluate(self: Self, gpa: Allocator, q: Query(R)) Allocator.Error!QueryResult {
            return switch (q) {
                .component => |f| relations.componentRel(R, gpa, self.world, f),
                .event => |f| relations.eventRel(gpa, self.log, f),
                .caused_by_direct => |id| relations.causedByDirect(gpa, self.log, id),
                .why => |id| relations.whyChain(gpa, self.log, id),
                .what_writes => |k| relations.systemRel(R, systems, gpa, .{ .writes_kind = k }),
                .what_reads => |k| relations.systemRel(R, systems, gpa, .{ .reads_kind = k }),
                .systems_all => relations.systemRel(R, systems, gpa, .{}),
                .schema => catalog.schemaRel(gpa),
                .columns => catalog.columnRel(gpa),
            };
        }

        /// diverge/3 operator: first component-level divergence between two runs sharing a base.
        pub fn diverge(self: Self, gpa: Allocator, a: *const runmod.Run(R), b: *const runmod.Run(R)) Allocator.Error!QueryResult {
            _ = self;
            return divergemod.diverge(R, gpa, a, b, systems);
        }

        /// WHERE-DID-IT-BREAK operator: first tick `pred` flips over a run.
        pub fn firstTickWhere(self: Self, gpa: Allocator, run: *const runmod.Run(R), comptime pred: fn (*const worldmod.World(R)) ?@import("../entity.zig").Entity) Allocator.Error!?divergemod.BreakPoint {
            _ = self;
            return divergemod.firstTickWhere(R, gpa, run, systems, pred);
        }
    };
}

/// REACHABILITY operator: deterministic transitive closure over an exogenous adjacency (generic in the
/// node type, so independent of any registry). Re-exported from diverge.zig.
pub const reach = divergemod.reach;
pub const BreakPoint = divergemod.BreakPoint;

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const q2 = @import("../query.zig");
const simctx = @import("../simctx.zig");
const Read = q2.Read;
const Write = q2.Write;
const system = schedule.system;

const Position = struct {
    x: i64,
    pub const kind_id: u16 = 10;
};
const Velocity = struct {
    dx: i64,
    pub const kind_id: u16 = 5;
};
const Game = Registry(.{ Position, Velocity });
fn rP(ctx: *simctx.SimCtx(Game), qq: *q2.Query(Game, .{Read(Position)})) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = qq;
}
fn wPV(ctx: *simctx.SimCtx(Game), qq: *q2.Query(Game, .{ Write(Position), Write(Velocity) })) std.mem.Allocator.Error!void {
    _ = ctx;
    _ = qq;
}
const demo_systems = [_]Sys(Game){ system(Game, "rP", rP), system(Game, "wPV", wPV) };

test "evaluate dispatches each arm to the expected relation" {
    const gpa = testing.allocator;
    var w = worldmod.World(Game).init(0);
    defer w.deinit(gpa);
    const e = try w.spawn(gpa);
    w.add(e, Position, .{ .x = 7 });
    var log: EventLog = .{};
    defer log.deinit(gpa);
    try log.append(gpa, .{ .tick = 1, .emitter = 0, .seq = 0 }, 100, 0, .{ .index = 0, .generation = 0 }, &.{0x01}, &.{});

    const Eng = Engine(Game, &demo_systems);
    const eng = Eng.init(&w, &log);

    inline for (.{
        .{ Query(Game){ .component = .{} }, term.RelId.component, @as(usize, 1) },
        .{ Query(Game){ .event = .{} }, term.RelId.event, @as(usize, 1) },
        .{ Query(Game){ .systems_all = {} }, term.RelId.system, @as(usize, 2) },
        .{ Query(Game){ .what_writes = 10 }, term.RelId.system, @as(usize, 1) }, // wPV writes Position
        .{ Query(Game){ .schema = {} }, term.RelId.relation_schema, @as(usize, 9) }, // 7 §7 + spec + violation
    }) |case| {
        var r = try eng.evaluate(gpa, case[0]);
        defer r.deinit(gpa);
        try testing.expectEqual(case[1], r.rel);
        try testing.expectEqual(case[2], r.rows.items.len);
    }
}

test "engine operators: firstTickWhere and reach are reachable through the Engine surface" {
    const gpa = testing.allocator;
    // reach is registry-independent
    const G = struct {
        fn nb(_: *const @This(), n: u32, out: *std.ArrayList(u32), a: Allocator) Allocator.Error!void {
            if (n == 0) {
                try out.append(a, 1);
                try out.append(a, 2);
            }
        }
        fn less(_: void, x: u32, y: u32) bool {
            return x < y;
        }
    };
    var g = G{};
    const rr = try reach(u32, gpa, &.{0}, &g, G.nb, G.less);
    defer gpa.free(rr);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, rr);
}
