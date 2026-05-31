//! gkz §8 — specifications, invariants, properties (PLAN.md Phase 6). Umbrella re-export mirroring
//! query.zig: the spec surface an AI (or a game driver) declares intent against and reads violations from.
//!
//! Three pillars + the fun-oracle boundary:
//!   * State invariants — `Invariant(R)` (the `fn(*const World) ?Entity` shape); `invariantOracle` for the
//!     VOPR, `firstViolation`/`check.checkAll` for on-demand / every-tick (Debug/Safe) checking. Built
//!     from `atom` constructors (rangeI/referencedLive/noOverlap/entityLive).
//!   * Temporal properties — seven closed `Combinator` folds over a `Trace` (`temporal.eval`);
//!     `temporalOracle` makes each a `kind=.temporal` Defect that rides the VOPR.
//!   * Intent-metrics — `Metric(T)` integer measurements + `aggregate`; the engine MEASURES, never judges
//!     ("fun" stays a declared proxy; `metric.metricBound` is the EXOGENOUS promotion to a checkable bound).
//!   * Violations + declared intent surface as the §7 `violation` / `spec` relations (relations.zig).
//!
//! Every-tick checking: a game driver calls `check.checkAll(R, invs, &world)` after each step (a no-op
//! DCE'd in ReleaseFast); the VOPR's `invariantOracle` covers the same checks on demand. The optional
//! in-`step` hook is deliberately NOT wired — keeping the throughput spine untouched (the design risk-valve).

const std = @import("std");

pub const atom = @import("spec/atom.zig");
pub const Atom = atom.Atom;
pub const AtomHit = atom.AtomHit;
pub const Witness = atom.Witness;

pub const defect = @import("spec/defect.zig");
pub const Finding = defect.Finding;

pub const invariant = @import("spec/invariant.zig");
pub const Invariant = invariant.Invariant;
pub const invariantOracle = invariant.invariantOracle;
pub const firstViolation = invariant.firstViolation;

pub const check = @import("spec/check.zig");
pub const checkAll = check.checkAll;

pub const trace = @import("spec/trace.zig");
pub const Trace = trace.Trace;

pub const temporal = @import("spec/temporal.zig");
pub const Combinator = temporal.Combinator;
pub const Property = temporal.Property;
pub const Violation = temporal.Violation;
pub const temporalOracle = temporal.temporalOracle;

pub const metric = @import("spec/metric.zig");
pub const Metric = metric.Metric;
pub const Aggregate = metric.Aggregate;

pub const relations = @import("spec/relations.zig");
pub const DeclaredSpec = relations.DeclaredSpec;
pub const Category = relations.Category;

test {
    std.testing.refAllDecls(@This());
    _ = atom;
    _ = defect;
    _ = invariant;
    _ = check;
    _ = trace;
    _ = temporal;
    _ = metric;
    _ = relations;
    _ = @import("spec/gate.zig");
}
