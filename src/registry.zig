//! Comptime component registry (SPEC §3, PLAN.md build-order step 2; resolves Q1).
//!
//! The game declares its components as a comptime tuple of struct types, each carrying a stable,
//! author-assigned `pub const kind_id: u16` (Q1: explicit ids, not tuple position, so the on-wire
//! format and §12 migrations survive source reordering). The registry derives everything the rest of
//! the kernel needs from that tuple:
//!   * `Mask` — the per-row component-presence bitset (`std.meta.Int`, Phase-1 ≤64 kinds → ≤u64).
//!   * `Row` — the `std.MultiArrayList` element tuple `(Entity, Mask, C₀, C₁, …)` (no `@Type`; built
//!     with `std.meta.Tuple`, verified to compile on 0.16).
//!   * canonical iteration order (ascending `kind_id`) and the mask **bit = 1 << rank-in-that-order**,
//!     so serialization order and presence bits are a pure function of the registered kind set.
//!
//! Deliberate deviation from the design synthesis: the synthesis required `extern`/`packed` layout to
//! avoid padding in the hash. But the serializer (serialize.zig) walks `@typeInfo` fields in
//! *declaration* order and emits each leaf little-endian — it never touches raw memory, so padding and
//! field memory-layout are irrelevant to determinism, and an `extern` requirement would forbid
//! components carrying `fpz.Fixed` (an auto-layout `struct{raw:i64}`). We instead enforce the property
//! that actually matters: recursive POD-serializability — no pointers (D8), no floats (D7).

const std = @import("std");
const entity = @import("entity.zig");
const Entity = entity.Entity;

/// Build a registry type from a comptime tuple of component struct types. Each component type must
/// declare `pub const kind_id: u16`. Referencing the returned type triggers comptime validation.
pub fn Registry(comptime component_types: anytype) type {
    return struct {
        const Self = @This();

        /// The registered component types, in declaration (tuple) order.
        pub const Components = component_types;
        /// Number of registered component kinds.
        pub const count: usize = component_types.len;
        /// Per-row component-presence bitset. Width = `count` (Phase-1 cap: ≤64 kinds).
        pub const Mask = std.meta.Int(.unsigned, if (count == 0) 1 else count);
        /// The `std.MultiArrayList` element: a tuple `(Entity, Mask, C₀, C₁, …)`. Field "0" is the
        /// owning entity, field "1" is the presence mask, field "i+2" is component-at-tuple-index-i.
        pub const Row = std.meta.Tuple(&(.{ Entity, Mask } ++ component_types));

        comptime {
            // validate() is O(n^2) (pairwise kind_id uniqueness) plus per-field recursion; raise the
            // branch quota so the documented 64-kind cap is actually reachable (the default 1000 dies
            // around ~30 kinds with an opaque error).
            @setEvalBranchQuota(200_000);
            validate();
        }

        /// `kind_id` of each component, indexed by tuple position (runtime-readable).
        pub const kind_ids: [count]u16 = blk: {
            var ids: [count]u16 = undefined;
            for (component_types, 0..) |C, i| ids[i] = C.kind_id;
            break :blk ids;
        };

        /// Tuple positions sorted by ascending `kind_id` — the canonical serialization order. The
        /// position of tuple-index `i` within this array is its mask-bit rank.
        pub const sorted: [count]usize = blk: {
            var order: [count]usize = undefined;
            for (0..count) |i| order[i] = i;
            // insertion sort by kind_id (comptime, stable, dependency-free); kind_ids are unique.
            var i: usize = 1;
            while (i < count) : (i += 1) {
                var j = i;
                while (j > 0 and kind_ids[order[j - 1]] > kind_ids[order[j]]) : (j -= 1) {
                    const tmp = order[j - 1];
                    order[j - 1] = order[j];
                    order[j] = tmp;
                }
            }
            break :blk order;
        };

        /// Component type at tuple index `i`.
        pub fn Component(comptime i: usize) type {
            return component_types[i];
        }

        /// Tuple index of component type `C` (compile error if `C` is not registered).
        pub fn indexOf(comptime C: type) usize {
            inline for (component_types, 0..) |T, i| {
                if (T == C) return i;
            }
            @compileError("not a registered component: " ++ @typeName(C));
        }

        /// `kind_id` of the component at tuple index `i`.
        pub fn kindId(comptime i: usize) u16 {
            return component_types[i].kind_id;
        }

        /// Mask-bit rank of tuple index `i` = its position in `sorted` (ascending kind_id).
        pub fn rank(comptime i: usize) usize {
            inline for (sorted, 0..) |idx, r| {
                if (idx == i) return r;
            }
            unreachable; // sorted is a permutation of [0, count)
        }

        /// Presence-mask bit for the component at tuple index `i`.
        pub fn bit(comptime i: usize) Mask {
            return @as(Mask, 1) << @intCast(rank(i));
        }

        /// Presence-mask bit for component type `C`.
        pub fn bitOf(comptime C: type) Mask {
            return bit(indexOf(C));
        }

        /// Runtime lookup: tuple index for a (possibly attacker-controlled) `kind_id`, or null if no
        /// such kind is registered. Linear scan — `count` ≤ 64.
        pub fn tupleIndexForKindId(kid: u16) ?usize {
            for (kind_ids, 0..) |k, i| {
                if (k == kid) return i;
            }
            return null;
        }

        fn validate() void {
            if (count > 64) @compileError("Phase-1 supports at most 64 component kinds (Mask width)");
            inline for (component_types, 0..) |C, i| {
                const info = @typeInfo(C);
                if (info != .@"struct") {
                    @compileError("component must be a struct: " ++ @typeName(C));
                }
                if (!@hasDecl(C, "kind_id")) {
                    @compileError("component missing `pub const kind_id: u16`: " ++ @typeName(C));
                }
                if (@TypeOf(C.kind_id) != u16 and @typeInfo(@TypeOf(C.kind_id)) != .comptime_int) {
                    @compileError("component kind_id must be u16: " ++ @typeName(C));
                }
                assertSerializable(C);
                // uniqueness of kind_id
                inline for (component_types, 0..) |D, j| {
                    if (i != j and C.kind_id == D.kind_id) {
                        @compileError("duplicate kind_id between " ++ @typeName(C) ++ " and " ++ @typeName(D));
                    }
                }
            }
        }

        /// Recursively assert that a component field type is canonically serializable (Q7): only
        /// integers, bools, enums (serialized as their integer tag), fixed-size arrays, and nested
        /// structs of the same. Floats (D7) and pointers/slices (D8) are rejected with a pointed message.
        fn assertSerializable(comptime T: type) void {
            switch (@typeInfo(T)) {
                .int, .bool => {},
                .@"enum" => |e| assertSerializable(e.tag_type),
                .@"struct" => |s| {
                    // Forbid event-naming types (EventId) in hashed state: their value differs
                    // events-on vs events-off, so storing one would diverge the content hash (Phase 3
                    // iron #2). The storable substitute is CauseToken, which lacks this marker.
                    if (@hasDecl(T, "__no_component_store")) {
                        @compileError(@typeName(T) ++ " may not be stored in a component (it names an event; thread causality with CauseToken instead)");
                    }
                    inline for (s.fields) |f| assertSerializable(f.type);
                },
                .array => |arr| assertSerializable(arr.child),
                .float => @compileError("float in a component is forbidden (D7: no float on the sim path; use fpz.Fixed/Angle): " ++ @typeName(T)),
                .pointer => @compileError("pointer in a component is forbidden (D8: no pointers in state; reference entities with `Entity`): " ++ @typeName(T)),
                else => @compileError("non-serializable component field type: " ++ @typeName(T)),
            }
        }
    };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const fpz = @import("fpz");

// kind_ids intentionally out of declaration order to exercise canonical sorting.
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
    armor: u8,
    pub const kind_id: u16 = 20;
};

const R = Registry(.{ Position, Velocity, Health });

test "count and Mask width" {
    try testing.expectEqual(@as(usize, 3), R.count);
    try testing.expectEqual(@as(u16, 3), @bitSizeOf(R.Mask));
}

test "kind_ids indexed by tuple position" {
    try testing.expectEqual(@as(u16, 10), R.kind_ids[0]);
    try testing.expectEqual(@as(u16, 5), R.kind_ids[1]);
    try testing.expectEqual(@as(u16, 20), R.kind_ids[2]);
}

test "canonical sort orders tuple indices by ascending kind_id" {
    // kind_ids 5,10,20 -> tuple indices 1 (Velocity), 0 (Position), 2 (Health)
    try testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, &R.sorted);
}

test "mask bit = 1 << rank-in-canonical-order, independent of tuple position" {
    try testing.expectEqual(@as(R.Mask, 0b001), R.bitOf(Velocity)); // rank 0 (smallest kind_id)
    try testing.expectEqual(@as(R.Mask, 0b010), R.bitOf(Position)); // rank 1
    try testing.expectEqual(@as(R.Mask, 0b100), R.bitOf(Health)); // rank 2
}

test "indexOf and kindId round-trip" {
    try testing.expectEqual(@as(usize, 0), R.indexOf(Position));
    try testing.expectEqual(@as(usize, 1), R.indexOf(Velocity));
    try testing.expectEqual(@as(u16, 10), R.kindId(R.indexOf(Position)));
}

test "tupleIndexForKindId resolves registered ids and rejects unknown" {
    try testing.expectEqual(@as(?usize, 0), R.tupleIndexForKindId(10));
    try testing.expectEqual(@as(?usize, 1), R.tupleIndexForKindId(5));
    try testing.expectEqual(@as(?usize, 2), R.tupleIndexForKindId(20));
    try testing.expectEqual(@as(?usize, null), R.tupleIndexForKindId(99));
}

test "Row tuple has count+2 fields (owner, mask, components)" {
    try testing.expectEqual(@as(usize, R.count + 2), @typeInfo(R.Row).@"struct".fields.len);
    // field 0 is Entity, field 1 is Mask
    try testing.expectEqual(Entity, @typeInfo(R.Row).@"struct".fields[0].type);
    try testing.expectEqual(R.Mask, @typeInfo(R.Row).@"struct".fields[1].type);
}

test "MultiArrayList accepts the registry Row" {
    const gpa = testing.allocator;
    var rows: std.MultiArrayList(R.Row) = .empty;
    defer rows.deinit(gpa);
    var row: R.Row = undefined;
    row[0] = .{ .index = 3, .generation = 0 };
    row[1] = 0b010;
    row[2] = .{ .x = fpz.Fixed.fromInt(1), .y = fpz.Fixed.fromInt(2) };
    row[3] = .{ .dx = fpz.Fixed.ZERO };
    row[4] = .{ .hp = 100, .armor = 5 };
    try rows.append(gpa, row);
    try testing.expectEqual(@as(u32, 3), rows.items(.@"0")[0].index);
    try testing.expectEqual(@as(i32, 100), rows.items(.@"4")[0].hp);
}
