//! SPEC §11 — content as data (PLAN.md §15 / "Phase 10"). Prefabs and levels are STRUCTURED, DIFFABLE,
//! mergeable data — NOT opaque binary scenes:
//!   * a `Prefab(R)` is a set of per-local-entity component CELLS (canonical-LE value bytes, == the
//!     migration `image.KindRecord`) plus an explicit local→local ref-patch list (the prefab's dependency
//!     graph, as auditable data — never a reflection guess);
//!   * a `Level(R)` composes prefab instances (+ per-instance overrides) and standalone nodes into one
//!     starting World — the initial state, a proc-gen world, or a fork's injected content.
//!
//! Instantiation spawns in canonical local-id order over the deterministic FIFO entity allocator
//! (entity.zig), sets each cell through the shared `mutation.applyAdd` kind_id→type dispatch, and rewrites
//! refs (local→real handle). Because the allocator is a pure function of the spawn sequence and every
//! byte is canonical-LE, a level's loaded-World digest is a FIXED PIN across build modes AND the
//! cross-arch matrix (`zig build cross`: aarch64/s390x/arm/mips). Decode reads UNTRUSTED bytes (content
//! may come from anywhere), so `readPrefab`/`readLevel` are hostile-hardened exactly like `image.decode`:
//! validate-before-alloc, incremental count-driven parse, never a panic, never a wild write.
//!
//! ENTITY-REF CONTRACT: a component field is a managed cross-entity reference IFF its authored value is
//! the `localRef(target)` sentinel (an `Entity` with the odd generation `LOCAL_REF_GEN`, so a missed
//! rewrite is a loud DEAD handle — fail-closed — never a plausible live ref). The builder walks a value's
//! `Entity` leaves and emits a `RefPatch` for each sentinel; ALL OTHER `Entity` values (a raw id, an
//! "none", an asset handle that happens to be Entity-shaped) are left VERBATIM. This is why ref rewriting
//! is explicit patch data, not a blind reflection rewrite of every Entity-shaped 8-byte window.
//!
//! ASSET HANDLES (headless-first): a rendering asset is referenced by a game-side handle (e.g.
//! `enum(u64)`) stored in a component — a plain fixed-width integer leaf the kernel never dereferences.
//! A world full of asset handles runs/hashes with zero art and no asset table. Asset IMPORT (real art →
//! handles) is a §14 seam / §15 non-goal — not built here.
//!
//! SCOPE: v1 instantiates at WORLD-CONSTRUCTION time (refs resolved immediately). Mid-tick prefab
//! spawning by a system (deferred via the §4 command buffer) is a declared seam; ZON authoring + prefab
//! migration are v1.1 / non-goals (see PLAN §15.9).

const std = @import("std");
const Allocator = std.mem.Allocator;
const entity = @import("entity.zig");
const Entity = entity.Entity;
const serialize = @import("serialize.zig");
const worldmod = @import("world.zig");
const mutation = @import("mutation.zig");
const image = @import("migrate/image.zig");
const sortmod = @import("sort.zig");

// --- data model -----------------------------------------------------------------------------------

/// A reference to an entity WITHIN a prefab/level template — valid only during authoring + instantiation.
/// `enum(u32)` so it serializes as a u32, orders trivially, and is a type DISTINCT from a real `Entity`.
pub const Local = enum(u32) { _ };

/// One authored component cell: kind_id + its canonical-LE value bytes. Aliased from `image.KindRecord`
/// (NOT re-declared) so prefab cells interoperate with `image.findCell`/`maskFor`/`encode` for free.
pub const Cell = image.KindRecord; // = struct { kind_id: u16, bytes: []const u8 }

/// One authored entity in a template: its local id and its component cells (ascending kind_id, canonical).
pub const Node = struct {
    local: Local,
    cells: []const Cell,
};

/// "Rewrite local entity `node`'s component `kind_id`, at canonical byte `byte_offset` (an 8-byte Entity
/// leaf), to the real handle of local entity `target`." Ref-ness is a property of the PATCH (auditable
/// data), not of the field's type.
pub const RefPatch = struct {
    node: Local,
    kind_id: u16,
    byte_offset: u32,
    target: Local,
};

/// The odd generation marking an unresolved local ref. Odd ⇒ `entity.isLive` reports it dead, so a
/// missed/unapplied patch is a loud fail-closed dead handle, never a plausible live ref.
pub const LOCAL_REF_GEN: u32 = 0xFFFF_FFFF;

/// The placeholder value an author stores in an `Entity` component field to mean "a reference to local
/// entity `target`, resolved at instantiation". The builder turns each such leaf into a `RefPatch`.
pub fn localRef(target: Local) Entity {
    return .{ .index = @intFromEnum(target), .generation = LOCAL_REF_GEN };
}

/// Replace one whole cell of a placed prefab instance at instantiate time (v1 override granularity).
pub const Override = struct { local: Local, cell: Cell };

/// A placement of a prefab (by table index) in a level, with optional per-instance cell overrides.
pub const Placement = struct { prefab_index: u32, overrides: []const Override = &.{} };

/// A reusable template of one-or-more entities. NO allocator state, NO generations. Instantiable many
/// times. `arena` is present iff this Prefab owns its slices (builder-built or decoded); a comptime
/// literal leaves it null.
pub fn Prefab(comptime R: type) type {
    return struct {
        const Self = @This();
        pub const Registry = R;
        nodes: []const Node, // ascending local id
        patches: []const RefPatch = &.{}, // ascending (node, kind_id, byte_offset)
        arena: ?std.heap.ArenaAllocator = null,
        pub fn deinit(self: *Self) void {
            if (self.arena) |*a| a.deinit();
            self.* = undefined;
        }
    };
}

/// A composition that builds one initial World. `loose` nodes are standalone (no inter-refs — use a
/// prefab for those). `arena` present iff owned (builder-built or decoded).
pub fn Level(comptime R: type) type {
    return struct {
        const Self = @This();
        pub const Registry = R;
        tick0: u64 = 0,
        schema_version: u32 = 1,
        rng_seed: u64,
        prefabs: []const Prefab(R) = &.{},
        placements: []const Placement = &.{},
        loose: []const Node = &.{},
        arena: ?std.heap.ArenaAllocator = null,
        /// INVARIANT: a Level owns a SINGLE arena; every contained `prefabs[i].arena` MUST be null (their
        /// slices live in this Level's arena — `LevelBuilder.addPrefab` and comptime literals both ensure
        /// this). `deinit` therefore frees only `self.arena`.
        pub fn deinit(self: *Self) void {
            if (self.arena) |*a| a.deinit();
            self.* = undefined;
        }
    };
}

pub const PREFAB_MAGIC = [4]u8{ 'G', 'K', 'Z', 'P' };
pub const LEVEL_MAGIC = [4]u8{ 'G', 'K', 'Z', 'L' };
pub const CONTENT_VERSION: u16 = 1;

pub const Error = error{ BadMagic, UnsupportedFormat, SchemaMismatch, Corrupt, BadPatch } || serialize.Error || Allocator.Error;

// --- comptime offset authority (Gate #8: shares serializedSizeOf's recursion) ---------------------

/// The canonical byte offset of every `Entity`-typed leaf within `C`'s serialization, in declaration
/// order. Offsets are computed by summing `serialize.serializedSizeOf` of preceding leaves — the SAME
/// recursion the codec uses — so a patch's `byte_offset` and the codec's emit position can never drift
/// (see the comptime Gate #8 test). Checking `C == Entity` BEFORE recursing keeps an Entity leaf whole
/// (it is itself a 2×u32 struct).
pub fn entityLeafOffsets(comptime C: type) []const u32 {
    const result = comptime blk: {
        if (C == Entity) break :blk &[_]u32{0};
        switch (@typeInfo(C)) {
            .@"struct" => |s| {
                var offs: []const u32 = &.{};
                var base: u32 = 0;
                for (s.fields) |f| {
                    for (entityLeafOffsets(f.type)) |o| offs = offs ++ &[_]u32{base + o};
                    base += @intCast(serialize.serializedSizeOf(f.type));
                }
                break :blk offs;
            },
            .array => |a| {
                var offs: []const u32 = &.{};
                const w: u32 = @intCast(serialize.serializedSizeOf(a.child));
                for (0..a.len) |k| {
                    for (entityLeafOffsets(a.child)) |o| offs = offs ++ &[_]u32{@as(u32, @intCast(k)) * w + o};
                }
                break :blk offs;
            },
            else => break :blk &[_]u32{}, // int / bool / enum: no Entity leaves
        }
    };
    return result;
}

/// Collect every `Entity`-leaf VALUE of `v` into `out` in declaration order — the SAME order as
/// `entityLeafOffsets(C)`, so `out[i]` is the value at `entityLeafOffsets(C)[i]`.
fn collectEntityValues(comptime C: type, v: C, out: []Entity, idx: *usize) void {
    if (C == Entity) {
        out[idx.*] = v;
        idx.* += 1;
        return;
    }
    switch (@typeInfo(C)) {
        .@"struct" => |s| inline for (s.fields) |f| collectEntityValues(f.type, @field(v, f.name), out, idx),
        .array => |a| for (v) |elem| collectEntityValues(a.child, elem, out, idx),
        else => {},
    }
}

// --- builder --------------------------------------------------------------------------------------

/// Authoring builder for a `Prefab(R)`. Used identically by hand-authored content and by seeded
/// procedural generation (the format works for runtime-built data; there is no literal-only path). All
/// slices are arena-backed; `build()` transfers arena ownership to the returned Prefab.
pub fn Builder(comptime R: type) type {
    return struct {
        const Self = @This();
        arena: std.heap.ArenaAllocator,
        nodes: std.ArrayList(Node) = .empty,
        patches: std.ArrayList(RefPatch) = .empty,
        built: bool = false,

        pub fn init(gpa: Allocator) Self {
            return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        }
        /// Free the arena if `build()` was never called (build transfers ownership).
        pub fn deinit(self: *Self) void {
            if (!self.built) self.arena.deinit();
            self.* = undefined;
        }

        /// Append a fresh template entity; returns its dense local id (= prior node count).
        pub fn addEntity(self: *Self) Allocator.Error!Local {
            const a = self.arena.allocator();
            const l: Local = @enumFromInt(@as(u32, @intCast(self.nodes.items.len)));
            try self.nodes.append(a, .{ .local = l, .cells = &.{} });
            return l;
        }

        /// Set component `C` on local entity `l` to `v`. Encodes `v` via the canonical codec, and walks
        /// its `Entity` leaves: each leaf holding a `localRef` sentinel becomes a `RefPatch`. Any other
        /// `Entity` value is stored verbatim. Re-setting the same kind on the same node replaces the cell.
        pub fn add(self: *Self, l: Local, comptime C: type, v: C) Allocator.Error!void {
            const a = self.arena.allocator();
            const li: usize = @intFromEnum(l);
            std.debug.assert(li < self.nodes.items.len);

            // encode v into arena bytes (length must equal the canonical size)
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(a);
            var sink = serialize.ByteSink{ .list = &buf, .gpa = a };
            try serialize.writeValue(&sink, C, v);
            std.debug.assert(buf.items.len == comptime serialize.serializedSizeOf(C));
            const bytes = try buf.toOwnedSlice(a);

            // append/replace the cell, kept ascending by kind_id
            try self.insertCell(l, .{ .kind_id = C.kind_id, .bytes = bytes });

            // a re-set REPLACES the cell, so first drop any ref-patches the PRIOR set of this (node, kind)
            // emitted — otherwise a stale patch would clobber the new value (or duplicate a (node,kind,
            // offset), which readPrefab rejects as Corrupt). The patch set always reflects the current cell.
            {
                var w: usize = 0;
                for (self.patches.items) |p| {
                    if (@intFromEnum(p.node) == li and p.kind_id == C.kind_id) continue;
                    self.patches.items[w] = p;
                    w += 1;
                }
                self.patches.shrinkRetainingCapacity(w);
            }

            // sentinel-walk: emit a RefPatch for each Entity leaf holding a localRef sentinel
            const offsets = comptime entityLeafOffsets(C);
            if (offsets.len > 0) {
                var vals: [offsets.len]Entity = undefined;
                var idx: usize = 0;
                collectEntityValues(C, v, &vals, &idx);
                inline for (offsets, 0..) |off, i| {
                    if (vals[i].generation == LOCAL_REF_GEN) {
                        try self.patches.append(a, .{ .node = l, .kind_id = C.kind_id, .byte_offset = off, .target = @enumFromInt(vals[i].index) });
                    }
                }
            }
        }

        fn insertCell(self: *Self, l: Local, cell: Cell) Allocator.Error!void {
            const a = self.arena.allocator();
            const node = &self.nodes.items[@intFromEnum(l)];
            var cells: std.ArrayList(Cell) = .empty;
            try cells.appendSlice(a, node.cells);
            // replace if present, else append, then keep ascending by kind_id
            var replaced = false;
            for (cells.items) |*c| {
                if (c.kind_id == cell.kind_id) {
                    c.* = cell;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try cells.append(a, cell);
            const owned = try cells.toOwnedSlice(a);
            sortmod.sort(Cell, owned, {}, ltCell);
            node.cells = owned;
        }

        /// Finalize: canonically sort patches and transfer arena ownership to the returned Prefab.
        pub fn build(self: *Self) Prefab(R) {
            sortmod.sort(RefPatch, self.patches.items, {}, ltPatch);
            self.built = true;
            return .{ .nodes = self.nodes.items, .patches = self.patches.items, .arena = self.arena };
        }
    };
}

fn ltCell(_: void, a: Cell, b: Cell) bool {
    return a.kind_id < b.kind_id;
}
fn ltPatch(_: void, a: RefPatch, b: RefPatch) bool {
    if (@intFromEnum(a.node) != @intFromEnum(b.node)) return @intFromEnum(a.node) < @intFromEnum(b.node);
    if (a.kind_id != b.kind_id) return a.kind_id < b.kind_id;
    return a.byte_offset < b.byte_offset;
}

/// Accumulating builder for a `Level(R)` — all content (prefabs, placements, loose nodes) lives in ONE
/// arena, so `Level.deinit` frees everything and the contained prefabs need no own arena.
pub fn LevelBuilder(comptime R: type) type {
    return struct {
        const Self = @This();
        arena: std.heap.ArenaAllocator,
        seed: u64,
        tick0: u64 = 0,
        schema_version: u32 = 1,
        prefabs: std.ArrayList(Prefab(R)) = .empty,
        placements: std.ArrayList(Placement) = .empty,
        loose: std.ArrayList(Node) = .empty,
        built: bool = false,

        pub fn init(gpa: Allocator, seed: u64) Self {
            return .{ .arena = std.heap.ArenaAllocator.init(gpa), .seed = seed };
        }
        pub fn deinit(self: *Self) void {
            if (!self.built) self.arena.deinit();
            self.* = undefined;
        }

        /// Copy a built prefab's nodes+patches into the level arena; returns its prefab table index. The
        /// caller may `deinit` the source prefab afterward (its bytes are duplicated here).
        pub fn addPrefab(self: *Self, pf: *const Prefab(R)) Allocator.Error!u32 {
            const a = self.arena.allocator();
            const nodes = try a.alloc(Node, pf.nodes.len);
            for (pf.nodes, nodes) |src, *dst| {
                const cells = try a.alloc(Cell, src.cells.len);
                for (src.cells, cells) |sc, *dc| dc.* = .{ .kind_id = sc.kind_id, .bytes = try a.dupe(u8, sc.bytes) };
                dst.* = .{ .local = src.local, .cells = cells };
            }
            const patches = try a.dupe(RefPatch, pf.patches);
            const idx: u32 = @intCast(self.prefabs.items.len);
            try self.prefabs.append(a, .{ .nodes = nodes, .patches = patches, .arena = null });
            return idx;
        }
        pub fn place(self: *Self, prefab_index: u32) Allocator.Error!void {
            try self.placements.append(self.arena.allocator(), .{ .prefab_index = prefab_index });
        }
        /// Add a built prefab's nodes as standalone LOOSE entities (spawned after all placements). Loose
        /// nodes carry NO refs in v1 (asserted), so the source prefab must have no patches — use `place`
        /// for entities that reference each other. Bytes are copied into the level arena; loose local ids
        /// are assigned densely across calls.
        pub fn addLoose(self: *Self, pf: *const Prefab(R)) Allocator.Error!void {
            std.debug.assert(pf.patches.len == 0); // loose nodes cannot carry managed refs in v1
            const a = self.arena.allocator();
            const base: u32 = @intCast(self.loose.items.len);
            for (pf.nodes, 0..) |src, k| {
                const cells = try a.alloc(Cell, src.cells.len);
                for (src.cells, cells) |sc, *dc| dc.* = .{ .kind_id = sc.kind_id, .bytes = try a.dupe(u8, sc.bytes) };
                try self.loose.append(a, .{ .local = @enumFromInt(base + @as(u32, @intCast(k))), .cells = cells });
            }
        }
        pub fn build(self: *Self) Level(R) {
            self.built = true;
            return .{
                .tick0 = self.tick0,
                .schema_version = self.schema_version,
                .rng_seed = self.seed,
                .prefabs = self.prefabs.items,
                .placements = self.placements.items,
                .loose = self.loose.items,
                .arena = self.arena,
            };
        }
    };
}

// --- instantiate / loadLevel ----------------------------------------------------------------------

/// Instantiate one prefab into an EXISTING world; returns the caller-owned `local→real` handle map
/// (`map[local] == the real Entity`). Spawns nodes in ascending-local order, applies optional `overrides`
/// (whole-cell replace), rewrites ref-patches, then sets every cell via `applyAdd(.content)` — so
/// untrusted content can never reach the command-buffer's `catch unreachable`. Deterministic given the
/// world's current allocator state.
pub fn instantiate(comptime R: type, w: *worldmod.World(R), gpa: Allocator, pf: *const Prefab(R), overrides: []const Override) Error![]Entity {
    const map = try gpa.alloc(Entity, pf.nodes.len);
    errdefer gpa.free(map);

    // pass 1: spawn all nodes (ascending local) so forward refs resolve.
    for (pf.nodes, 0..) |node, i| {
        std.debug.assert(@intFromEnum(node.local) == i); // builder/decoder guarantee dense, ordered
        map[i] = try w.spawn(gpa);
    }

    // validate patch ranges against this prefab before any write.
    for (pf.patches) |p| {
        if (@intFromEnum(p.node) >= pf.nodes.len or @intFromEnum(p.target) >= pf.nodes.len) return error.BadPatch;
    }

    // pass 2: per node — set each cell. An OVERRIDE supplies literal final bytes (a wholesale cell
    // replacement: its managed refs, if any, are NOT resolved — overrides are literal); a prefab's own
    // cell has its ref-patches rewritten into a mutable copy first.
    for (pf.nodes, 0..) |node, i| {
        for (node.cells) |cell| {
            if (overrideFor(node.local, cell.kind_id, overrides)) |ov| {
                try mutation.applyAdd(R, w, map[i], ov.kind_id, ov.bytes, .content); // literal, no patching
                continue;
            }
            const scratch = try gpa.dupe(u8, cell.bytes);
            defer gpa.free(scratch);
            // rewrite every ref-patch targeting (this node, this kind) into scratch.
            for (pf.patches) |p| {
                if (@intFromEnum(p.node) == i and p.kind_id == cell.kind_id) {
                    // re-validate the offset is a real Entity leaf (holds even for a hand-built Prefab
                    // literal, not just decoded ones) — never a silent in-bounds-but-wrong-field write.
                    if (!legalEntityOffset(R, cell.kind_id, p.byte_offset) or @as(u64, p.byte_offset) + 8 > scratch.len) return error.BadPatch;
                    const h = map[@intFromEnum(p.target)];
                    std.mem.writeInt(u32, scratch[p.byte_offset..][0..4], h.index, .little);
                    std.mem.writeInt(u32, scratch[p.byte_offset + 4 ..][0..4], h.generation, .little);
                }
            }
            try mutation.applyAdd(R, w, map[i], cell.kind_id, scratch, .content);
        }
    }
    return map;
}

fn overrideFor(local: Local, kind_id: u16, overrides: []const Override) ?Cell {
    for (overrides) |o| {
        if (@intFromEnum(o.local) == @intFromEnum(local) and o.cell.kind_id == kind_id) return o.cell;
    }
    return null;
}

/// Build a FRESH World from a Level — the §11 "initial World / proc-gen world / fork-injected content".
/// Deterministic: a given Level always yields the same World digest (the pin), across build modes AND
/// architectures.
pub fn loadLevel(comptime R: type, gpa: Allocator, lvl: *const Level(R)) Error!worldmod.World(R) {
    var w = worldmod.World(R).init(lvl.rng_seed);
    errdefer w.deinit(gpa);
    w.tick = lvl.tick0;
    w.schema_version = lvl.schema_version;

    for (lvl.placements) |pl| {
        if (pl.prefab_index >= lvl.prefabs.len) return error.Corrupt;
        const map = try instantiate(R, &w, gpa, &lvl.prefabs[pl.prefab_index], pl.overrides);
        gpa.free(map);
    }
    // loose standalone nodes (no inter-refs in v1)
    for (lvl.loose) |node| {
        const e = try w.spawn(gpa);
        for (node.cells) |cell| try mutation.applyAdd(R, &w, e, cell.kind_id, cell.bytes, .content);
    }
    return w;
}

// --- canonical serialization (hostile-hardened decode) --------------------------------------------

/// Per-Kind fingerprint write/validate, shared by prefab + level. Mirrors serialize.writeWorld's header.
fn writeFingerprint(comptime R: type, sink: anytype) !void {
    try serialize.putInt(sink, u16, @intCast(R.count));
    inline for (R.Components) |C| {
        try serialize.putInt(sink, u16, C.kind_id);
        try serialize.putInt(sink, u32, @intCast(serialize.serializedSizeOf(C)));
    }
}

/// Read + validate the fingerprint against the LIVE registry R: every kind registered with the exact
/// canonical width, count ≤ 64. Returns nothing (R is the source of truth) — a mismatch is SchemaMismatch.
fn readFingerprint(comptime R: type, reader: *serialize.ByteReader) Error!void {
    const kind_count = try serialize.getInt(reader, u16);
    if (kind_count > 64) return error.Corrupt;
    if (kind_count != R.count) return error.SchemaMismatch;
    inline for (R.Components) |C| {
        const kid = try serialize.getInt(reader, u16);
        const size = try serialize.getInt(reader, u32);
        if (kid != C.kind_id or size != @as(u32, @intCast(serialize.serializedSizeOf(C)))) return error.SchemaMismatch;
    }
}

/// Width of component `kind_id` in R, or null if unregistered.
fn widthOf(comptime R: type, kind_id: u16) ?u32 {
    inline for (R.Components) |C| {
        if (C.kind_id == kind_id) return @intCast(serialize.serializedSizeOf(C));
    }
    return null;
}

/// Is `byte_offset` a legal `Entity`-leaf offset for component `kind_id` in R? (the comptime
/// entityLeafOffsets set, used purely as a decode guard — a stale/forged offset is BadPatch, never a
/// silent wrong-handle write).
fn legalEntityOffset(comptime R: type, kind_id: u16, byte_offset: u32) bool {
    inline for (R.Components) |C| {
        if (C.kind_id == kind_id) {
            for (comptime entityLeafOffsets(C)) |o| if (o == byte_offset) return true;
            return false;
        }
    }
    return false;
}

/// Write a prefab body (no magic/version — shared by writePrefab and writeLevel). Nodes ascending local,
/// patches ascending (node, kind, offset). Cell bytes follow each node's cell-id list.
fn writePrefabBody(comptime R: type, sink: anytype, pf: *const Prefab(R)) !void {
    try serialize.putInt(sink, u32, @intCast(pf.nodes.len));
    for (pf.nodes) |node| {
        try serialize.putInt(sink, u32, @intFromEnum(node.local));
        try serialize.putInt(sink, u16, @intCast(node.cells.len));
        for (node.cells) |c| try serialize.putInt(sink, u16, c.kind_id);
        for (node.cells) |c| try sink.update(c.bytes);
    }
    try serialize.putInt(sink, u32, @intCast(pf.patches.len));
    for (pf.patches) |p| {
        try serialize.putInt(sink, u32, @intFromEnum(p.node));
        try serialize.putInt(sink, u16, p.kind_id);
        try serialize.putInt(sink, u32, p.byte_offset);
        try serialize.putInt(sink, u32, @intFromEnum(p.target));
    }
}

pub fn writePrefab(comptime R: type, sink: anytype, pf: *const Prefab(R)) !void {
    try sink.update(&PREFAB_MAGIC);
    try serialize.putInt(sink, u16, CONTENT_VERSION);
    try writeFingerprint(R, sink);
    try writePrefabBody(R, sink, pf);
}

/// Read a prefab body into `arena`. UNTRUSTED: validate-before-alloc, incremental parse, never panic.
fn readPrefabBody(comptime R: type, arena: Allocator, reader: *serialize.ByteReader) Error!Prefab(R) {
    const node_count = try serialize.getInt(reader, u32);
    var nodes: std.ArrayList(Node) = .empty; // incremental — a hostile count never drives a pre-alloc
    var expect_local: u32 = 0;
    while (nodes.items.len < node_count) : (expect_local += 1) {
        const local = try serialize.getInt(reader, u32);
        if (local != expect_local) return error.Corrupt; // dense, ascending
        const cell_count = try serialize.getInt(reader, u16);
        if (cell_count > 64) return error.Corrupt;
        var kinds: std.ArrayList(u16) = .empty;
        var prev_kid: i32 = -1;
        while (kinds.items.len < cell_count) {
            const kid = try serialize.getInt(reader, u16);
            if (@as(i32, kid) <= prev_kid) return error.Corrupt; // strictly ascending ⇒ no dup
            if (widthOf(R, kid) == null) return error.SchemaMismatch;
            prev_kid = kid;
            try kinds.append(arena, kid);
        }
        var cells: std.ArrayList(Cell) = .empty;
        for (kinds.items) |kid| {
            const w = widthOf(R, kid).?;
            const bytes = try reader.readSlice(w); // Truncated on short input
            try cells.append(arena, .{ .kind_id = kid, .bytes = try arena.dupe(u8, bytes) });
        }
        try nodes.append(arena, .{ .local = @enumFromInt(local), .cells = try cells.toOwnedSlice(arena) });
    }

    const patch_count = try serialize.getInt(reader, u32);
    var patches: std.ArrayList(RefPatch) = .empty;
    while (patches.items.len < patch_count) {
        const node = try serialize.getInt(reader, u32);
        const kind_id = try serialize.getInt(reader, u16);
        const byte_offset = try serialize.getInt(reader, u32);
        const target = try serialize.getInt(reader, u32);
        if (node >= node_count or target >= node_count) return error.BadPatch;
        if (!legalEntityOffset(R, kind_id, byte_offset)) return error.BadPatch; // stale/forged ⇒ reject
        const p: RefPatch = .{ .node = @enumFromInt(node), .kind_id = kind_id, .byte_offset = byte_offset, .target = @enumFromInt(target) };
        // reject a duplicate (node, kind, offset) so application is order-independent
        for (patches.items) |q| {
            if (@intFromEnum(q.node) == node and q.kind_id == kind_id and q.byte_offset == byte_offset) return error.Corrupt;
        }
        try patches.append(arena, p);
    }
    return .{ .nodes = try nodes.toOwnedSlice(arena), .patches = try patches.toOwnedSlice(arena), .arena = null };
}

pub fn readPrefab(comptime R: type, gpa: Allocator, reader: *serialize.ByteReader) Error!Prefab(R) {
    const magic = try reader.readSlice(4);
    if (!std.mem.eql(u8, magic, &PREFAB_MAGIC)) return error.BadMagic;
    if (try serialize.getInt(reader, u16) != CONTENT_VERSION) return error.UnsupportedFormat;
    try readFingerprint(R, reader);
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var pf = try readPrefabBody(R, arena.allocator(), reader);
    pf.arena = arena;
    return pf;
}

pub fn writeLevel(comptime R: type, sink: anytype, lvl: *const Level(R)) !void {
    try sink.update(&LEVEL_MAGIC);
    try serialize.putInt(sink, u16, CONTENT_VERSION);
    try serialize.putInt(sink, u32, lvl.schema_version);
    try serialize.putInt(sink, u64, lvl.tick0);
    try serialize.putInt(sink, u64, lvl.rng_seed);
    try writeFingerprint(R, sink);
    try serialize.putInt(sink, u32, @intCast(lvl.prefabs.len));
    for (lvl.prefabs) |pf| try writePrefabBody(R, sink, &pf);
    try serialize.putInt(sink, u32, @intCast(lvl.placements.len));
    for (lvl.placements) |pl| {
        try serialize.putInt(sink, u32, pl.prefab_index);
        try serialize.putInt(sink, u32, @intCast(pl.overrides.len));
        for (pl.overrides) |o| {
            try serialize.putInt(sink, u32, @intFromEnum(o.local));
            try serialize.putInt(sink, u16, o.cell.kind_id);
            try sink.update(o.cell.bytes);
        }
    }
    try serialize.putInt(sink, u32, @intCast(lvl.loose.len));
    for (lvl.loose) |node| {
        try serialize.putInt(sink, u32, @intFromEnum(node.local));
        try serialize.putInt(sink, u16, @intCast(node.cells.len));
        for (node.cells) |c| try serialize.putInt(sink, u16, c.kind_id);
        for (node.cells) |c| try sink.update(c.bytes);
    }
}

pub fn readLevel(comptime R: type, gpa: Allocator, reader: *serialize.ByteReader) Error!Level(R) {
    const magic = try reader.readSlice(4);
    if (!std.mem.eql(u8, magic, &LEVEL_MAGIC)) return error.BadMagic;
    if (try serialize.getInt(reader, u16) != CONTENT_VERSION) return error.UnsupportedFormat;
    const schema_version = try serialize.getInt(reader, u32);
    const tick0 = try serialize.getInt(reader, u64);
    const rng_seed = try serialize.getInt(reader, u64);
    try readFingerprint(R, reader);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const prefab_count = try serialize.getInt(reader, u32);
    var prefabs: std.ArrayList(Prefab(R)) = .empty;
    while (prefabs.items.len < prefab_count) try prefabs.append(a, try readPrefabBody(R, a, reader));

    const placement_count = try serialize.getInt(reader, u32);
    var placements: std.ArrayList(Placement) = .empty;
    while (placements.items.len < placement_count) {
        const prefab_index = try serialize.getInt(reader, u32);
        if (prefab_index >= prefab_count) return error.Corrupt;
        const override_count = try serialize.getInt(reader, u32);
        var ovs: std.ArrayList(Override) = .empty;
        while (ovs.items.len < override_count) {
            const local = try serialize.getInt(reader, u32);
            const kid = try serialize.getInt(reader, u16);
            const w = widthOf(R, kid) orelse return error.SchemaMismatch;
            const bytes = try reader.readSlice(w);
            try ovs.append(a, .{ .local = @enumFromInt(local), .cell = .{ .kind_id = kid, .bytes = try a.dupe(u8, bytes) } });
        }
        try placements.append(a, .{ .prefab_index = prefab_index, .overrides = try ovs.toOwnedSlice(a) });
    }

    const loose_count = try serialize.getInt(reader, u32);
    var loose: std.ArrayList(Node) = .empty;
    var expect_local: u32 = 0;
    while (loose.items.len < loose_count) : (expect_local += 1) {
        const local = try serialize.getInt(reader, u32);
        if (local != expect_local) return error.Corrupt;
        const cell_count = try serialize.getInt(reader, u16);
        if (cell_count > 64) return error.Corrupt;
        var kinds: std.ArrayList(u16) = .empty;
        var prev_kid: i32 = -1;
        while (kinds.items.len < cell_count) {
            const kid = try serialize.getInt(reader, u16);
            if (@as(i32, kid) <= prev_kid) return error.Corrupt;
            if (widthOf(R, kid) == null) return error.SchemaMismatch;
            prev_kid = kid;
            try kinds.append(a, kid);
        }
        var cells: std.ArrayList(Cell) = .empty;
        for (kinds.items) |kid| {
            const bytes = try reader.readSlice(widthOf(R, kid).?);
            try cells.append(a, .{ .kind_id = kid, .bytes = try a.dupe(u8, bytes) });
        }
        try loose.append(a, .{ .local = @enumFromInt(local), .cells = try cells.toOwnedSlice(a) });
    }

    return .{
        .tick0 = tick0,
        .schema_version = schema_version,
        .rng_seed = rng_seed,
        .prefabs = try prefabs.toOwnedSlice(a),
        .placements = try placements.toOwnedSlice(a),
        .loose = try loose.toOwnedSlice(a),
        .arena = arena,
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests (unit-level; the pinned cross-build/cross-arch gates live in content_gate.zig)
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");
const Registry = @import("registry.zig").Registry;

const Position = struct {
    x: i32,
    y: i32,
    pub const kind_id: u16 = 1;
};
const Follows = struct {
    target: Entity,
    pub const kind_id: u16 = 2;
};
const Demo = Registry(.{ Position, Follows });

test "entityLeafOffsets locates Entity leaves at their canonical byte offsets" {
    try testing.expectEqual(@as(usize, 0), entityLeafOffsets(Position).len); // no Entity leaf
    const fo = comptime entityLeafOffsets(Follows);
    try testing.expectEqual(@as(usize, 1), fo.len);
    try testing.expectEqual(@as(u32, 0), fo[0]); // Follows.target is the first (only) field

    const Pair = struct { a: Position, link: Entity }; // link after a 8-byte Position
    const po = comptime entityLeafOffsets(Pair);
    try testing.expectEqual(@as(usize, 1), po.len);
    try testing.expectEqual(@as(u32, 8), po[0]); // 2×i32 then the Entity
}

// Gate #8 (comptime offset authority): the Entity-leaf offset equals where writeValue emits it.
test "Gate#8: ref offset-helper agrees with the codec's emit position" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    const v = Follows{ .target = .{ .index = 0xAABBCCDD, .generation = 0x11223344 } };
    try serialize.writeValue(&sink, Follows, v);
    const off = comptime entityLeafOffsets(Follows)[0];
    // the 8-byte window at `off` decodes back to the same Entity the codec wrote
    var rd = serialize.ByteReader{ .bytes = buf.items[off..][0..8] };
    const got = try serialize.readValue(Entity, &rd);
    try testing.expectEqual(v.target, got);
}

fn buildChaser(gpa: Allocator) !Prefab(Demo) {
    var b = Builder(Demo).init(gpa);
    errdefer b.deinit();
    const leader = try b.addEntity(); // local 0
    const chaser = try b.addEntity(); // local 1
    try b.add(leader, Position, .{ .x = 1, .y = 2 });
    try b.add(chaser, Position, .{ .x = 3, .y = 4 });
    try b.add(chaser, Follows, .{ .target = localRef(leader) }); // chaser follows leader
    return b.build();
}

test "instantiate resolves a local ref to the real handle; multi-instance isolation" {
    const gpa = testing.allocator;
    var pf = try buildChaser(gpa);
    defer pf.deinit();

    var w = worldmod.World(Demo).init(0);
    defer w.deinit(gpa);

    const m0 = try instantiate(Demo, &w, gpa, &pf, &.{});
    defer gpa.free(m0);
    const m1 = try instantiate(Demo, &w, gpa, &pf, &.{});
    defer gpa.free(m1);

    // instance 0: chaser.target == leader-of-0
    try testing.expectEqual(m0[0], w.get(m0[1], Follows).?.target);
    // instance 1: chaser.target == leader-of-1 (NOT leader-of-0)
    try testing.expectEqual(m1[0], w.get(m1[1], Follows).?.target);
    try testing.expect(!std.meta.eql(m0[0], m1[0])); // distinct instances
    try testing.expect(w.isLive(w.get(m0[1], Follows).?.target)); // a resolved ref is LIVE (not the sentinel)
}

test "loadLevel is deterministic: same level → identical World digest" {
    const gpa = testing.allocator;
    const Runner = struct {
        fn run(g: Allocator) !u64 {
            var pf = try buildChaser(g);
            defer pf.deinit();
            var lb = LevelBuilder(Demo).init(g, 0xC0FFEE);
            errdefer lb.deinit();
            const pi = try lb.addPrefab(&pf);
            try lb.place(pi);
            try lb.place(pi);
            var lvl = lb.build();
            defer lvl.deinit();
            var w = try loadLevel(Demo, g, &lvl);
            defer w.deinit(g);
            return (try w.digest(g)).hash;
        }
    };
    try testing.expectEqual(try Runner.run(gpa), try Runner.run(gpa));
}

test "prefab round-trips byte-identically and re-instantiates to the same digest" {
    const gpa = testing.allocator;
    var pf = try buildChaser(gpa);
    defer pf.deinit();

    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var sa = serialize.ByteSink{ .list = &a, .gpa = gpa };
    try writePrefab(Demo, &sa, &pf);

    var rd = serialize.ByteReader{ .bytes = a.items };
    var pf2 = try readPrefab(Demo, gpa, &rd);
    defer pf2.deinit();

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    var sb = serialize.ByteSink{ .list = &b, .gpa = gpa };
    try writePrefab(Demo, &sb, &pf2);
    try testing.expectEqualSlices(u8, a.items, b.items); // canonical fixed point

    // both instantiate to the same world
    var w1 = worldmod.World(Demo).init(0);
    defer w1.deinit(gpa);
    gpa.free(try instantiate(Demo, &w1, gpa, &pf, &.{}));
    var w2 = worldmod.World(Demo).init(0);
    defer w2.deinit(gpa);
    gpa.free(try instantiate(Demo, &w2, gpa, &pf2, &.{}));
    try testing.expectEqual((try w1.digest(gpa)).hash, (try w2.digest(gpa)).hash);
}

test "hostile decode never panics: bad magic / version / truncation" {
    const gpa = testing.allocator;
    var bad = serialize.ByteReader{ .bytes = "XXXX\x01\x00" };
    try testing.expectError(error.BadMagic, readPrefab(Demo, gpa, &bad));

    var pf = try buildChaser(gpa);
    defer pf.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try writePrefab(Demo, &sink, &pf);

    var trunc = serialize.ByteReader{ .bytes = buf.items[0 .. buf.items.len - 1] };
    try testing.expectError(error.Truncated, readPrefab(Demo, gpa, &trunc));

    // corrupt the version u16 (bytes 4..6, just after the 4-byte magic) → UnsupportedFormat
    const vbad = try gpa.dupe(u8, buf.items);
    defer gpa.free(vbad);
    vbad[4] = 0xEE;
    var rv = serialize.ByteReader{ .bytes = vbad };
    try testing.expectError(error.UnsupportedFormat, readPrefab(Demo, gpa, &rv));

    // corrupt a fingerprint width (Position's size, bytes 10..14) → SchemaMismatch
    const sbad = try gpa.dupe(u8, buf.items);
    defer gpa.free(sbad);
    sbad[10] = 0x07; // size 8 → 7
    var rs = serialize.ByteReader{ .bytes = sbad };
    try testing.expectError(error.SchemaMismatch, readPrefab(Demo, gpa, &rs));
}

// A literal Prefab with a deliberately malformed patch list (write never validates; read must).
fn writeLiteral(gpa: std.mem.Allocator, pf: *const Prefab(Demo), out: *std.ArrayList(u8)) !void {
    var sink = serialize.ByteSink{ .list = out, .gpa = gpa };
    try writePrefab(Demo, &sink, pf);
}
fn expectPrefabError(gpa: std.mem.Allocator, pf: *const Prefab(Demo), want: anyerror) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try writeLiteral(gpa, pf, &buf);
    var rd = serialize.ByteReader{ .bytes = buf.items };
    try testing.expectError(want, readPrefab(Demo, gpa, &rd));
}

test "hostile decode battery: illegal patch offset / out-of-range target / duplicate patch" {
    const gpa = testing.allocator;
    const one_node = [_]Node{.{ .local = @enumFromInt(0), .cells = &.{} }};
    // Follows (kind 2) has exactly one legal Entity-leaf offset: 0. Offset 1 is illegal → BadPatch.
    try expectPrefabError(gpa, &.{ .nodes = &one_node, .patches = &.{.{ .node = @enumFromInt(0), .kind_id = 2, .byte_offset = 1, .target = @enumFromInt(0) }} }, error.BadPatch);
    // target out of range (only 1 node) → BadPatch.
    try expectPrefabError(gpa, &.{ .nodes = &one_node, .patches = &.{.{ .node = @enumFromInt(0), .kind_id = 2, .byte_offset = 0, .target = @enumFromInt(5) }} }, error.BadPatch);
    // duplicate (node, kind, offset) → Corrupt.
    try expectPrefabError(gpa, &.{ .nodes = &one_node, .patches = &.{
        .{ .node = @enumFromInt(0), .kind_id = 2, .byte_offset = 0, .target = @enumFromInt(0) },
        .{ .node = @enumFromInt(0), .kind_id = 2, .byte_offset = 0, .target = @enumFromInt(0) },
    } }, error.Corrupt);
}

// --- multi-leaf / array offset arithmetic (the silent-wrong-handle case the design flags) ----------

const Link2 = struct {
    a: Entity,
    n: u32,
    b: Entity,
    pub const kind_id: u16 = 10;
};
const Squad = struct {
    members: [3]Entity,
    pub const kind_id: u16 = 11;
};
const Multi = Registry(.{ Position, Link2, Squad });

test "entityLeafOffsets is correct for multi-leaf structs and arrays (Gate#8 extended)" {
    // Link2: a@0 (8) | n@8 (4) | b@12 (8)
    const lo = comptime entityLeafOffsets(Link2);
    try testing.expectEqualSlices(u32, &.{ 0, 12 }, lo);
    // Squad: [3]Entity at 0, 8, 16
    const so = comptime entityLeafOffsets(Squad);
    try testing.expectEqualSlices(u32, &.{ 0, 8, 16 }, so);

    // and the offsets agree with where the codec actually emits each Entity leaf.
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    const v = Link2{ .a = .{ .index = 1, .generation = 2 }, .n = 9, .b = .{ .index = 3, .generation = 4 } };
    try serialize.writeValue(&sink, Link2, v);
    var ra = serialize.ByteReader{ .bytes = buf.items[lo[0]..][0..8] };
    var rb = serialize.ByteReader{ .bytes = buf.items[lo[1]..][0..8] };
    try testing.expectEqual(v.a, try serialize.readValue(Entity, &ra));
    try testing.expectEqual(v.b, try serialize.readValue(Entity, &rb));
}

test "two distinct local refs in one component resolve to distinct correct handles" {
    const gpa = testing.allocator;
    var b = Builder(Multi).init(gpa);
    errdefer b.deinit();
    const p = try b.addEntity(); // 0
    const q = try b.addEntity(); // 1
    const x = try b.addEntity(); // 2
    try b.add(p, Position, .{ .x = 0, .y = 0 });
    try b.add(q, Position, .{ .x = 1, .y = 1 });
    try b.add(x, Link2, .{ .a = localRef(p), .n = 7, .b = localRef(q) });
    var pf = b.build();
    defer pf.deinit();
    try testing.expectEqual(@as(usize, 2), pf.patches.len); // two refs → two patches

    var w = worldmod.World(Multi).init(0);
    defer w.deinit(gpa);
    const m = try instantiate(Multi, &w, gpa, &pf, &.{});
    defer gpa.free(m);
    const link = w.get(m[2], Link2).?;
    try testing.expectEqual(m[0], link.a); // a → p
    try testing.expectEqual(m[1], link.b); // b → q (offset-12 leaf resolved correctly)
    try testing.expect(!std.meta.eql(link.a, link.b));
    try testing.expectEqual(@as(u32, 7), link.n); // the non-ref field is untouched
}

test "re-setting a component replaces its cell AND drops the stale ref-patch (review #2)" {
    const gpa = testing.allocator;
    var b = Builder(Demo).init(gpa);
    errdefer b.deinit();
    const e0 = try b.addEntity();
    const e1 = try b.addEntity();
    try b.add(e0, Position, .{ .x = 0, .y = 0 });
    try b.add(e1, Position, .{ .x = 0, .y = 0 });
    // first set Follows to a local ref, then RE-SET it to a literal (non-sentinel) Entity.
    try b.add(e1, Follows, .{ .target = localRef(e0) });
    const literal = Entity{ .index = 9, .generation = 0 };
    try b.add(e1, Follows, .{ .target = literal });
    var pf = b.build();
    defer pf.deinit();
    try testing.expectEqual(@as(usize, 0), pf.patches.len); // the stale ref-patch was dropped

    var w = worldmod.World(Demo).init(0);
    defer w.deinit(gpa);
    const m = try instantiate(Demo, &w, gpa, &pf, &.{});
    defer gpa.free(m);
    try testing.expectEqual(literal, w.get(m[1], Follows).?.target); // the literal survived (not clobbered)
}

test "loose nodes (LevelBuilder.addLoose) round-trip and instantiate as standalone entities" {
    const gpa = testing.allocator;
    var lpf = blk: {
        var lb2 = Builder(Demo).init(gpa);
        errdefer lb2.deinit();
        const s = try lb2.addEntity();
        try lb2.add(s, Position, .{ .x = 5, .y = 6 }); // a standalone entity, no refs
        break :blk lb2.build();
    };
    defer lpf.deinit();

    var lb = LevelBuilder(Demo).init(gpa, 42);
    errdefer lb.deinit();
    try lb.addLoose(&lpf);
    var lvl = lb.build();
    defer lvl.deinit();

    // round-trip the level (exercises the writeLevel/readLevel LOOSE path) ...
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sink = serialize.ByteSink{ .list = &buf, .gpa = gpa };
    try writeLevel(Demo, &sink, &lvl);
    var rd = serialize.ByteReader{ .bytes = buf.items };
    var lvl2 = try readLevel(Demo, gpa, &rd);
    defer lvl2.deinit();

    // ... and both load to the same World with the loose entity present.
    var w1 = try loadLevel(Demo, gpa, &lvl);
    defer w1.deinit(gpa);
    var w2 = try loadLevel(Demo, gpa, &lvl2);
    defer w2.deinit(gpa);
    try testing.expectEqual((try w1.digest(gpa)).hash, (try w2.digest(gpa)).hash);
    try testing.expectEqual(@as(usize, 1), w1.table.rowCount());
    try testing.expectEqual(@as(i32, 5), w1.get(.{ .index = 0, .generation = 0 }, Position).?.x);
}

test "an override is literal — its managed ref is NOT resolved (review #3)" {
    const gpa = testing.allocator;
    var pf = try buildChaser(gpa); // chaser(local 1).Follows = localRef(leader)
    defer pf.deinit();

    // override the chaser's Follows cell with a literal Entity{7,0} (8 canonical bytes)
    var ob: [8]u8 = undefined;
    std.mem.writeInt(u32, ob[0..4], 7, .little);
    std.mem.writeInt(u32, ob[4..8], 0, .little);
    const ovs = [_]Override{.{ .local = @enumFromInt(1), .cell = .{ .kind_id = Follows.kind_id, .bytes = &ob } }};

    var w = worldmod.World(Demo).init(0);
    defer w.deinit(gpa);
    const m = try instantiate(Demo, &w, gpa, &pf, &ovs);
    defer gpa.free(m);
    // the override is literal: target is {7,0}, NOT the resolved leader handle.
    try testing.expectEqual(Entity{ .index = 7, .generation = 0 }, w.get(m[1], Follows).?.target);
}
