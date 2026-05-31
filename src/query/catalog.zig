//! The self-describing relation catalog (PLAN.md Phase 5, build-order step 4).
//!
//! SPEC §7's thesis — "entities, components, events, causal edges, and the system dataflow graph are all
//! just relations" — extends to the SCHEMA ITSELF: the surface describes itself through two more
//! relations, so an AI with no source access bootstraps by querying them, then composes the canonical
//! shapes from what it learned, parsing every result in the same `term.Value` space.
//!   * relation_schema(rel_id, name, arity)            — one row per relation
//!   * relation_column(rel_id, col_index, name, tag)   — one row per column
//!
//! The catalog is built from the SAME `Schema` constants the producers use (relations.zig), so it cannot
//! drift from the real relations; a comptime well-formedness assertion (one entry per RelId variant, in
//! canonical order, arity ≤ MAX_ARITY) is a second structural tripwire, and a runtime test asserts each
//! producer's emitted schema equals its catalog entry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const term = @import("term.zig");
const Schema = term.Schema;
const RelId = term.RelId;
const TermTag = term.TermTag;
const resultmod = @import("result.zig");
const QueryResult = resultmod.QueryResult;
const Builder = resultmod.Builder;
const relations = @import("relations.zig");

pub const RelMeta = struct { rel_id: RelId, name: []const u8, schema: Schema };

// The catalog's own two relations (they describe every relation, including themselves).
pub const RELATION_SCHEMA_SCHEMA = Schema.make(&.{ .{ "rel_id", .u }, .{ "name", .bytes }, .{ "arity", .u } });
pub const RELATION_COLUMN_SCHEMA = Schema.make(&.{ .{ "rel_id", .u }, .{ "col_index", .u }, .{ "col_name", .bytes }, .{ "term_tag", .u } });

/// Every relation the surface exposes, in canonical `RelId` order. Schemas are the producer constants.
pub const CATALOG = [_]RelMeta{
    .{ .rel_id = .component, .name = "component", .schema = relations.COMPONENT_SCHEMA },
    .{ .rel_id = .event, .name = "event", .schema = relations.EVENT_SCHEMA },
    .{ .rel_id = .caused_by, .name = "caused_by", .schema = relations.CAUSED_BY_SCHEMA },
    .{ .rel_id = .system, .name = "system", .schema = relations.SYSTEM_SCHEMA },
    .{ .rel_id = .diverge, .name = "diverge", .schema = relations.DIVERGE_SCHEMA },
    .{ .rel_id = .relation_schema, .name = "relation_schema", .schema = RELATION_SCHEMA_SCHEMA },
    .{ .rel_id = .relation_column, .name = "relation_column", .schema = RELATION_COLUMN_SCHEMA },
};

comptime {
    // Drift/well-formedness tripwire: CATALOG covers every (non-`_`) RelId variant exactly once, in
    // enum order, and no schema exceeds MAX_ARITY. A producer or schema edit that desyncs the catalog
    // (or a missing/duplicated relation) fails to compile here.
    const enum_fields = @typeInfo(RelId).@"enum".fields;
    if (CATALOG.len != enum_fields.len) @compileError("CATALOG must have one entry per RelId variant");
    for (CATALOG, 0..) |m, i| {
        if (@intFromEnum(m.rel_id) != enum_fields[i].value) @compileError("CATALOG entry out of canonical RelId order: " ++ m.name);
        if (m.schema.arity > term.MAX_ARITY) @compileError("relation arity exceeds MAX_ARITY: " ++ m.name);
    }
}

/// relation_schema/3: one row per relation (rel_id, name, arity).
pub fn schemaRel(gpa: Allocator) Allocator.Error!QueryResult {
    var b = Builder.init(gpa, .relation_schema, RELATION_SCHEMA_SCHEMA);
    errdefer b.deinit();
    for (CATALOG) |m| {
        const name_ref = try b.pushBytes(m.name);
        try b.pushRow(.{ .vals = .{ .{ .u = @intFromEnum(m.rel_id) }, .{ .bytes = name_ref }, .{ .u = m.schema.arity }, undefined, undefined, undefined, undefined, undefined } });
    }
    return b.finalize();
}

/// relation_column/4: one row per column (rel_id, col_index, col_name, term_tag).
pub fn columnRel(gpa: Allocator) Allocator.Error!QueryResult {
    var b = Builder.init(gpa, .relation_column, RELATION_COLUMN_SCHEMA);
    errdefer b.deinit();
    for (CATALOG) |m| {
        var c: usize = 0;
        while (c < m.schema.arity) : (c += 1) {
            const cname_ref = try b.pushBytes(m.schema.names[c]);
            try b.pushRow(.{ .vals = .{
                .{ .u = @intFromEnum(m.rel_id) },
                .{ .u = @intCast(c) },
                .{ .bytes = cname_ref },
                .{ .u = @intFromEnum(m.schema.cols[c]) },
                undefined,
                undefined,
                undefined,
                undefined,
            } });
        }
    }
    return b.finalize();
}

/// True if two schemas are structurally equal (arity, per-column tag, per-column name). Used by the
/// drift test to assert a producer's emitted schema matches its catalog entry.
pub fn schemaEql(a: Schema, b: Schema) bool {
    if (a.arity != b.arity) return false;
    var i: usize = 0;
    while (i < a.arity) : (i += 1) {
        if (a.cols[i] != b.cols[i]) return false;
        if (!std.mem.eql(u8, a.names[i], b.names[i])) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "relation_schema lists every relation with correct name + arity in canonical RelId order" {
    const gpa = testing.allocator;
    var r = try schemaRel(gpa);
    defer r.deinit(gpa);
    try testing.expectEqual(CATALOG.len, r.rows.items.len);
    // canonical: rel_id ascending -> component(0) first, relation_column(6) last
    try testing.expectEqual(@as(u64, 0), r.rows.items[0].vals[0].u);
    try testing.expectEqualStrings("component", r.bytesOf(r.rows.items[0].vals[1].bytes));
    try testing.expectEqual(@as(u64, 3), r.rows.items[0].vals[2].u); // component arity 3
    const last = r.rows.items[r.rows.items.len - 1];
    try testing.expectEqualStrings("relation_column", r.bytesOf(last.vals[1].bytes));
    try testing.expectEqual(@as(u64, 4), last.vals[2].u); // relation_column arity 4
}

test "relation_column lists every column (rel_id, index, name, tag) in canonical order" {
    const gpa = testing.allocator;
    var r = try columnRel(gpa);
    defer r.deinit(gpa);
    // total columns = sum of arities across the catalog
    var total: usize = 0;
    for (CATALOG) |m| total += m.schema.arity;
    try testing.expectEqual(total, r.rows.items.len);
    // component (rel 0) col 0 is ("entity", .entity)
    try testing.expectEqual(@as(u64, 0), r.rows.items[0].vals[0].u);
    try testing.expectEqual(@as(u64, 0), r.rows.items[0].vals[1].u);
    try testing.expectEqualStrings("entity", r.bytesOf(r.rows.items[0].vals[2].bytes));
    try testing.expectEqual(@as(u64, @intFromEnum(TermTag.entity)), r.rows.items[0].vals[3].u);
}

test "catalog schemas match the producers' emitted schemas (no drift)" {
    const gpa = testing.allocator;
    // the relations whose producers live here / in relations.zig (diverge tested in diverge.zig)
    try testing.expect(schemaEql(CATALOG[0].schema, relations.COMPONENT_SCHEMA));
    try testing.expect(schemaEql(CATALOG[1].schema, relations.EVENT_SCHEMA));
    try testing.expect(schemaEql(CATALOG[2].schema, relations.CAUSED_BY_SCHEMA));
    try testing.expect(schemaEql(CATALOG[3].schema, relations.SYSTEM_SCHEMA));
    // and the catalog's own relations are self-consistent
    var rs = try schemaRel(gpa);
    defer rs.deinit(gpa);
    try testing.expect(schemaEql(rs.schema, RELATION_SCHEMA_SCHEMA));
}

test "catalog relations are uniform QueryResults parseable in the same Value space" {
    const gpa = testing.allocator;
    var r = try schemaRel(gpa);
    defer r.deinit(gpa);
    // a catalog result round-trips through GKZR1 exactly like a data relation
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = @import("../serialize.zig").ByteSink{ .list = &buf, .gpa = gpa };
    try resultmod.writeResult(&sink, &r);
    var reader = @import("../serialize.zig").ByteReader{ .bytes = buf.items };
    var r2 = try resultmod.readResult(gpa, &reader);
    defer r2.deinit(gpa);
    try testing.expectEqual(r.rows.items.len, r2.rows.items.len);
    const d1 = try resultmod.resultDigest(gpa, &r);
    const d2 = try resultmod.resultDigest(gpa, &r2);
    try testing.expectEqual(d1.hash, d2.hash);
}
