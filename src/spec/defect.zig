//! The §8↔§4 bridge (PLAN.md Phase 6, build-order step 3): the rich `Finding(R)` violation record that
//! carries the full multi-entity `Witness`, plus conversions to/from the VOPR's `Defect(R)`.
//!
//! `Defect(R)` (vopr/oracle.zig) is the VOPR currency — single-entity detail, rides sweep/minimize/
//! provenance. A `Finding(R)` is the §8 reporting record — it keeps the full canonical `Witness` (so the
//! §7 `violation` relation can show "no two solids overlap … the entities involved", plural). `toDefect`
//! projects to the single primary (canonical-smallest) entity for VOPR flow; `fromDefect` lifts a
//! VOPR-produced Defect (e.g. from `oracle.invariant`) back into a Finding. Both are pure POD maps.

const std = @import("std");
const atom = @import("atom.zig");
const Witness = atom.Witness;
const oraclemod = @import("../vopr/oracle.zig");

/// Convenience re-export so spec modules name `Defect` without reaching across to vopr/.
pub fn Defect(comptime R: type) type {
    return oraclemod.Defect(R);
}

/// A §8 violation with its full canonical witness. Unifies the invariant and temporal pillars.
pub fn Finding(comptime R: type) type {
    return struct {
        const Self = @This();
        kind: oraclemod.Defect(R).Kind, // .invariant or .temporal
        name: []const u8, // the offending invariant/property name
        seed: u64,
        tick: u64, // the first violating tick
        witness: Witness,

        /// Project to the VOPR `Defect` (single primary entity). The detail reuses the existing `.entity`
        /// arm (canonical-smallest witness entity) or `.none` when the witness is empty.
        pub fn toDefect(self: Self) oraclemod.Defect(R) {
            return .{
                .seed = self.seed,
                .tick = self.tick,
                .kind = self.kind,
                .oracle = self.name,
                .detail = if (self.witness.n > 0) .{ .entity = self.witness.ents[0] } else .none,
            };
        }
    };
}

/// Lift a VOPR `Defect` (e.g. from `oracle.invariant`, single-entity detail) into a `Finding`.
pub fn fromDefect(comptime R: type, d: oraclemod.Defect(R)) Finding(R) {
    var wit: Witness = .{};
    if (d.detail == .entity) wit.add(d.detail.entity);
    return .{ .kind = d.kind, .name = d.oracle, .seed = d.seed, .tick = d.tick, .witness = wit };
}

// ---------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Registry = @import("../registry.zig").Registry;
const Entity = @import("../entity.zig").Entity;

const C = struct {
    v: i32,
    pub const kind_id: u16 = 1;
};
const Game = Registry(.{C});

test "Finding.toDefect projects to the primary witness entity with the right kind/tick" {
    var wit: Witness = .{};
    wit.add(.{ .index = 3, .generation = 0 });
    wit.add(.{ .index = 1, .generation = 0 });
    const f = Finding(Game){ .kind = .temporal, .name = "stable(boss)", .seed = 7, .tick = 5, .witness = wit };
    const d = f.toDefect();
    try testing.expectEqual(Defect(Game).Kind.temporal, d.kind);
    try testing.expectEqual(@as(u64, 5), d.tick);
    try testing.expectEqual(@as(u64, 7), d.seed);
    try testing.expectEqualStrings("stable(boss)", d.oracle);
    try testing.expectEqual(@as(u32, 1), d.detail.entity.index); // canonical-smallest of {1,3}
}

test "Finding with empty witness projects to detail.none" {
    const f = Finding(Game){ .kind = .temporal, .name = "monotonic(score)", .seed = 0, .tick = 2, .witness = .{} };
    const d = f.toDefect();
    try testing.expectEqual(Defect(Game).Detail.none, d.detail);
}

test "fromDefect round-trips a single-entity invariant Defect into a Finding" {
    const d = Defect(Game){ .seed = 1, .tick = 4, .kind = .invariant, .oracle = "hp>=0", .detail = .{ .entity = .{ .index = 2, .generation = 1 } } };
    const f = fromDefect(Game, d);
    try testing.expectEqual(Defect(Game).Kind.invariant, f.kind);
    try testing.expectEqual(@as(u64, 4), f.tick);
    try testing.expectEqual(@as(u8, 1), f.witness.n);
    try testing.expectEqual(@as(u32, 2), f.witness.ents[0].index);
    // and it projects back to the same Defect
    const d2 = f.toDefect();
    try testing.expectEqual(d.tick, d2.tick);
    try testing.expectEqual(d.detail.entity.index, d2.detail.entity.index);
}
