//! Schema fingerprint extraction + comparison for §12 migration (PLAN.md Phase 8).
//!
//! The per-Kind fingerprint — the ascending-kind_id list of `{kind_id, serialized_size}` that
//! `serialize.writeWorld` emits and `image.decode` recovers — is the structural identity of a schema.
//! Two fingerprints that compare `eql` describe byte-compatible Worlds; `requireMatch` reuses
//! `serialize.Error.SchemaMismatch` so a fingerprint disagreement reads identically whether it is caught
//! at the wire boundary (readWorld) or at the migration boundary here. `diff` names the per-Kind delta
//! (added / dropped / resized kind_ids), which validateMigration (migrate.zig) checks the declared ops
//! exactly cover. The schema_version is metadata carried alongside the kinds; the STRUCTURAL comparison
//! is over the kinds only (version dispatch is migrate.zig's concern, not the shape's).

const std = @import("std");
const Allocator = std.mem.Allocator;
const image = @import("image.zig");
const KindFp = image.KindFp;
const Image = image.Image;
const serialize = @import("../serialize.zig");

/// A schema's full fingerprint: its version tag plus the structural per-Kind shape.
pub const Fingerprint = struct { schema_version: u32, kinds: []const KindFp };

/// The fingerprint of a decoded image (borrows the image's storage; valid while the image lives).
pub fn of(img: *const Image) Fingerprint {
    return .{ .schema_version = img.schema_version, .kinds = img.fingerprint };
}

/// The comptime target fingerprint of registry `R`: ascending kind_id, with each kind's canonical
/// serialized width. Returned as a slice into static memory (the comptime-frozen array).
pub fn currentFingerprint(comptime R: type) []const KindFp {
    const kinds = comptime blk: {
        var arr: [R.count]KindFp = undefined;
        for (R.sorted, 0..) |ti, i| {
            arr[i] = .{ .kind_id = R.kindId(ti), .size = @intCast(serialize.serializedSizeOf(R.Component(ti))) };
        }
        break :blk arr;
    };
    return &kinds;
}

/// The `{kind_id, size}` entry for `kind_id` in `fp`, or null.
pub fn find(fp: []const KindFp, kind_id: u16) ?KindFp {
    for (fp) |k| {
        if (k.kind_id == kind_id) return k;
    }
    return null;
}

/// Structural equality: same kind set, each with the same serialized width. Order-independent (kind_ids
/// are unique, so equal length + every `a` entry matched in `b` is a bijection).
pub fn eql(a: []const KindFp, b: []const KindFp) bool {
    if (a.len != b.len) return false;
    for (a) |ka| {
        const kb = find(b, ka.kind_id) orelse return false;
        if (kb.size != ka.size) return false;
    }
    return true;
}

/// Return `void` if `a` and `b` are structurally equal, else `serialize.Error.SchemaMismatch` — the same
/// error the wire boundary raises, so a schema disagreement is one error type across the whole kernel.
pub fn requireMatch(a: []const KindFp, b: []const KindFp) serialize.Error!void {
    if (!eql(a, b)) return error.SchemaMismatch;
}

/// The per-Kind delta between two fingerprints, by kind_id. Arena-backed; caller `deinit`s.
pub const DiffReport = struct {
    added: []const u16, // in `new`, not in `old`
    dropped: []const u16, // in `old`, not in `new`
    resized: []const u16, // in both, different size
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *DiffReport) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// True iff the schemas are structurally identical (no added/dropped/resized kinds).
    pub fn isEmpty(self: *const DiffReport) bool {
        return self.added.len == 0 and self.dropped.len == 0 and self.resized.len == 0;
    }
};

/// Compute the per-Kind delta from `old` to `new`.
pub fn diff(gpa: Allocator, old: []const KindFp, new: []const KindFp) Allocator.Error!DiffReport {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var added: std.ArrayList(u16) = .empty;
    var dropped: std.ArrayList(u16) = .empty;
    var resized: std.ArrayList(u16) = .empty;

    for (new) |kn| {
        if (find(old, kn.kind_id)) |ko| {
            if (ko.size != kn.size) try resized.append(a, kn.kind_id);
        } else {
            try added.append(a, kn.kind_id);
        }
    }
    for (old) |ko| {
        if (find(new, ko.kind_id) == null) try dropped.append(a, ko.kind_id);
    }

    return .{ .added = added.items, .dropped = dropped.items, .resized = resized.items, .arena = arena };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("../registry.zig").Registry;
const storage = @import("../storage.zig");
const entity = @import("../entity.zig");
const EntityAllocator = entity.EntityAllocator;

const Position = struct {
    x: fpz.Fixed,
    y: fpz.Fixed,
    pub const kind_id: u16 = 10;
};
const Velocity = struct {
    dx: fpz.Fixed,
    pub const kind_id: u16 = 5;
};
const Health = struct {
    hp: i32,
    pub const kind_id: u16 = 20;
};
const HealthWide = struct {
    hp: i64, // same kind_id 20, wider
    pub const kind_id: u16 = 20;
};
const Reg = Registry(.{ Position, Velocity, Health });
const RegWide = Registry(.{ Position, Velocity, HealthWide }); // Health resized
const RegDrop = Registry(.{ Position, Velocity }); // Health dropped

fn imageOf(gpa: Allocator, comptime R: type) !Image {
    var entities: EntityAllocator = .{};
    errdefer entities.deinit(gpa);
    const e = try entities.alloc(gpa);
    var table: storage.Table(R) = .{};
    errdefer table.deinit(gpa);
    _ = try table.spawnRow(gpa, e);
    var parts = serialize.Parts(R){ .tick = 0, .schema_version = 1, .rng_root = .{ .seed = 0 }, .entities = entities, .table = table };
    defer parts.deinit(gpa);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try serialize.writeWorld(R, gpa, &sink, &parts);
    return image.decode(gpa, buf.items);
}

test "of(image) equals currentFingerprint(R) for an image produced by writeWorld(R)" {
    const gpa = testing.allocator;
    var img = try imageOf(gpa, Reg);
    defer img.deinit();
    try testing.expect(eql(of(&img).kinds, currentFingerprint(Reg)));
    try testing.expectEqual(@as(u32, 1), of(&img).schema_version);
}

test "eql is true for identical fingerprints, false on a differing size or kind_id" {
    try testing.expect(eql(currentFingerprint(Reg), currentFingerprint(Reg)));
    try testing.expect(!eql(currentFingerprint(Reg), currentFingerprint(RegWide))); // Health size differs
    try testing.expect(!eql(currentFingerprint(Reg), currentFingerprint(RegDrop))); // count differs
}

test "requireMatch is void on match, SchemaMismatch on disagreement" {
    try requireMatch(currentFingerprint(Reg), currentFingerprint(Reg));
    try testing.expectError(error.SchemaMismatch, requireMatch(currentFingerprint(Reg), currentFingerprint(RegWide)));
}

test "diff names exactly the added/dropped/resized kind_ids" {
    const gpa = testing.allocator;

    // resized: Reg -> RegWide changes Health (20) size only
    var d1 = try diff(gpa, currentFingerprint(Reg), currentFingerprint(RegWide));
    defer d1.deinit();
    try testing.expectEqual(@as(usize, 0), d1.added.len);
    try testing.expectEqual(@as(usize, 0), d1.dropped.len);
    try testing.expectEqualSlices(u16, &.{20}, d1.resized);

    // dropped: Reg -> RegDrop drops Health (20)
    var d2 = try diff(gpa, currentFingerprint(Reg), currentFingerprint(RegDrop));
    defer d2.deinit();
    try testing.expectEqual(@as(usize, 0), d2.added.len);
    try testing.expectEqualSlices(u16, &.{20}, d2.dropped);
    try testing.expectEqual(@as(usize, 0), d2.resized.len);

    // added: RegDrop -> Reg adds Health (20)
    var d3 = try diff(gpa, currentFingerprint(RegDrop), currentFingerprint(Reg));
    defer d3.deinit();
    try testing.expectEqualSlices(u16, &.{20}, d3.added);
    try testing.expectEqual(@as(usize, 0), d3.dropped.len);
    try testing.expectEqual(@as(usize, 0), d3.resized.len);

    // identity: no delta
    var d4 = try diff(gpa, currentFingerprint(Reg), currentFingerprint(Reg));
    defer d4.deinit();
    try testing.expect(d4.isEmpty());
}
