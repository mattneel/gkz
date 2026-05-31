//! §12 schema migration & hot-reload (Phase 8) — public umbrella.
//!
//! Migration reshapes a serialized World across schema versions WITHOUT instantiating the old registry:
//! `image.decode` lifts any serialize image into a schema-agnostic record `Image` (driven by the image's
//! own per-Kind fingerprint), declared `Op`s reconcile it, and `image.encode(R_target)` re-emits bytes
//! byte-identical to `serialize.writeWorld` — canonical by construction. The public entry points are
//! `migrateBytes` / `migrateWorld` / `migrateSnapshot`; `validateMigration` proves a migration complete
//! before any byte moves. Hot-reload (reload.zig) is a separate concern: a comptime system-set swap.

pub const image = @import("migrate/image.zig");
pub const Image = image.Image;
pub const KindFp = image.KindFp;
pub const KindRecord = image.KindRecord;
pub const RowRecord = image.RowRecord;

pub const fingerprint = @import("migrate/fingerprint.zig");
pub const Fingerprint = fingerprint.Fingerprint;
pub const currentFingerprint = fingerprint.currentFingerprint;

pub const ops = @import("migrate/ops.zig");
pub const Op = ops.Op;
pub const FieldBuilder = ops.FieldBuilder;
pub const FieldReader = ops.FieldReader;

const migrate_impl = @import("migrate/migrate.zig");
pub const Migration = migrate_impl.Migration;
pub const Chain = migrate_impl.Chain;
pub const MigrateError = migrate_impl.MigrateError;
pub const ValidateError = migrate_impl.ValidateError;
pub const validateMigration = migrate_impl.validateMigration;
pub const apply = migrate_impl.apply;
pub const applyChain = migrate_impl.applyChain;
pub const migrateBytes = migrate_impl.migrateBytes;
pub const migrateWorld = migrate_impl.migrateWorld;
pub const migrateSnapshot = migrate_impl.migrateSnapshot;

pub const gate = @import("migrate/gate.zig");

test {
    _ = image;
    _ = fingerprint;
    _ = ops;
    _ = migrate_impl;
    _ = gate;
}
