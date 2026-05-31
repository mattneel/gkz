//! The §8 → §7 surface (PLAN.md Phase 6, build-order step 8): two relations in the closed `term.Value`
//! space so an AI both DISCOVERS declared intent and reads caught violations the same way it bootstraps
//! the schema catalog.
//!   * spec/3      (spec_id, category, name)            — one row per declared invariant/property/metric
//!   * violation/6 (kind, seed, tick, oracle, entity, witness) — one row per caught Finding
//!
//! Both schemas live in query/catalog.zig (so the comptime catalog tripwire — one CATALOG entry per
//! RelId — is satisfied and the relations are self-describing via relation_schema). Rows are built with
//! the §7 `Builder` (canonical sort + dedup) and serialize via the existing GKZR1 codec unchanged, so
//! Phase 9 serves them with no new wire work.

const std = @import("std");
const Allocator = std.mem.Allocator;
const qterm = @import("../query/term.zig");
const Value = qterm.Value;
const Row = qterm.Row;
const resultmod = @import("../query/result.zig");
const QueryResult = resultmod.QueryResult;
const Builder = resultmod.Builder;
const catalog = @import("../query/catalog.zig");
const defectmod = @import("defect.zig");
const Entity = @import("../entity.zig").Entity;

/// Declared-intent category (the `category` column of the spec relation).
pub const Category = enum(u8) { invariant, temporal, metric };

/// A declaration the game makes: an invariant / temporal property / metric, by name + category. The game
/// passes its `[]const DeclaredSpec` so an AI can enumerate exactly what is checkable/measured.
pub const DeclaredSpec = struct { category: Category, name: []const u8 };

/// Sentinel "no entity" for a witness column with fewer entities than the schema's two slots.
const NONE: Entity = .{ .index = std.math.maxInt(u32), .generation = std.math.maxInt(u32) };

/// spec/3: one row per declared spec, in canonical order (by spec_id == declaration index).
pub fn specRel(gpa: Allocator, declared: []const DeclaredSpec) Allocator.Error!QueryResult {
    var b = Builder.init(gpa, .spec, catalog.SPEC_SCHEMA);
    errdefer b.deinit();
    for (declared, 0..) |d, i| {
        const name_ref = try b.pushBytes(d.name);
        try b.pushRow(.{ .vals = .{ .{ .u = @intCast(i) }, .{ .u = @intFromEnum(d.category) }, .{ .bytes = name_ref }, undefined, undefined, undefined, undefined, undefined } });
    }
    return b.finalize();
}

/// violation/6: one row per Finding (kind, seed, tick, oracle, entity, witness). `entity` is the primary
/// (canonical-smallest) witness; `witness` is the second implicated entity (e.g. the other overlapping
/// solid) or the primary when only one. Missing entities use the NONE sentinel.
pub fn violationRel(comptime R: type, gpa: Allocator, findings: []const defectmod.Finding(R)) Allocator.Error!QueryResult {
    var b = Builder.init(gpa, .violation, catalog.VIOLATION_SCHEMA);
    errdefer b.deinit();
    for (findings) |f| {
        const oracle_ref = try b.pushBytes(f.name);
        const e0: Entity = if (f.witness.n > 0) f.witness.ents[0] else NONE;
        const e1: Entity = if (f.witness.n > 1) f.witness.ents[1] else e0;
        try b.pushRow(.{ .vals = .{
            .{ .u = @intFromEnum(f.kind) },
            .{ .u = f.seed },
            .{ .tick = f.tick },
            .{ .bytes = oracle_ref },
            .{ .entity = e0 },
            .{ .entity = e1 },
            undefined,
            undefined,
        } });
    }
    return b.finalize();
}

/// Build the violation relation directly from VOPR-produced Defects (each lifted to a single-entity
/// Finding) — the sweep path.
pub fn violationRelFromDefects(comptime R: type, gpa: Allocator, defects: []const defectmod.Defect(R)) Allocator.Error!QueryResult {
    var findings = try gpa.alloc(defectmod.Finding(R), defects.len);
    defer gpa.free(findings);
    for (defects, 0..) |d, i| findings[i] = defectmod.fromDefect(R, d);
    return violationRel(R, gpa, findings);
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const atom = @import("atom.zig");

const C = struct {
    v: i32,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{C});

const demo_declared = [_]DeclaredSpec{
    .{ .category = .invariant, .name = "hp>=0" },
    .{ .category = .temporal, .name = "boss_stays_dead" },
    .{ .category = .metric, .name = "time_to_clear" },
};

test "specRel lists declared intent with category + name in canonical order" {
    const gpa = testing.allocator;
    var r = try specRel(gpa, &demo_declared);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), r.rows.items.len);
    try testing.expectEqual(@as(u64, 0), r.rows.items[0].vals[0].u); // spec_id 0
    try testing.expectEqual(@as(u64, @intFromEnum(Category.invariant)), r.rows.items[0].vals[1].u);
    try testing.expectEqualStrings("hp>=0", r.bytesOf(r.rows.items[0].vals[2].bytes));
    try testing.expectEqualStrings("time_to_clear", r.bytesOf(r.rows.items[2].vals[2].bytes));
}

test "violationRel emits canonical rows; a two-entity witness fills both entity columns" {
    const gpa = testing.allocator;
    var w2: atom.Witness = .{};
    w2.add(.{ .index = 4, .generation = 0 });
    w2.add(.{ .index = 1, .generation = 0 });
    const findings = [_]defectmod.Finding(Game){
        .{ .kind = .temporal, .name = "boss", .seed = 0, .tick = 5, .witness = atom.Witness.single(.{ .index = 2, .generation = 0 }) },
        .{ .kind = .invariant, .name = "overlap", .seed = 0, .tick = 3, .witness = w2 },
    };
    var r = try violationRel(Game, gpa, &findings);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), r.rows.items.len);
    // canonical order: invariant(kind=0) row sorts before temporal(kind=3) (col 0 = kind)
    const inv = r.rows.items[0];
    try testing.expectEqual(@as(u64, @intFromEnum(defectmod.Defect(Game).Kind.invariant)), inv.vals[0].u);
    try testing.expectEqual(@as(u32, 1), inv.vals[4].entity.index); // primary = canonical-smallest of {1,4}
    try testing.expectEqual(@as(u32, 4), inv.vals[5].entity.index); // witness = the other overlapping solid
    // single-entity finding: witness column mirrors the entity column
    const tmp = r.rows.items[1];
    try testing.expectEqual(@as(u32, 2), tmp.vals[4].entity.index);
    try testing.expectEqual(@as(u32, 2), tmp.vals[5].entity.index);
}

test "violation + spec relations round-trip through GKZR1 with a stable digest" {
    const gpa = testing.allocator;
    var r = try specRel(gpa, &demo_declared);
    defer r.deinit(gpa);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = @import("../serialize.zig").ByteSink{ .list = &buf, .gpa = gpa };
    try resultmod.writeResult(&sink, &r);
    var reader = @import("../serialize.zig").ByteReader{ .bytes = buf.items };
    var r2 = try resultmod.readResult(gpa, &reader);
    defer r2.deinit(gpa);
    try testing.expectEqual(qterm.RelId.spec, r2.rel);
    try testing.expectEqual((try resultmod.resultDigest(gpa, &r)).hash, (try resultmod.resultDigest(gpa, &r2)).hash);
}
