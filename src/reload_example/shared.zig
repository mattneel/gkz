//! The registry shared between the reloadable example shared objects and the reload determinism gate
//! (PLAN.md Phase 8, §12). Compiled SEPARATELY into each `.so` module and into the gate module — the type
//! IDENTITY differs per compilation, but because every compilation uses this same definition (same Zig,
//! same target), the in-memory LAYOUT of `R`, `Sys(R)`, `Table(R)`, `SimCtx(R)` is byte-identical on both
//! sides of the dlopen boundary. That layout match is what makes the host safely read a `.so`'s
//! `Descriptor` and call its system function pointers.

const gkz = @import("gkz");

pub const Position = struct {
    x: i64,
    pub const kind_id: u16 = 1;
};
pub const Velocity = struct {
    dx: i64,
    pub const kind_id: u16 = 2;
};

pub const R = gkz.Registry(.{ Position, Velocity });
pub const Descriptor = gkz.reload.Descriptor(R);
