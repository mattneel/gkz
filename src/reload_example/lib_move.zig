//! Reloadable example shared object "A": a single `move` system that integrates position by velocity
//! (x += dx each tick). Compiled by build.zig with `linkage = .dynamic` and dlopen'd by reload_gate.zig.
//! Exports `gkz_systems` — the symbol the host's `reload.NativeLibSource` resolves.

const std = @import("std");
const gkz = @import("gkz");
const shared = @import("shared.zig");
const R = shared.R;

fn move(ctx: *gkz.SimCtx(R), q: *gkz.Query(R, .{ gkz.Read(shared.Velocity), gkz.Write(shared.Position) })) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(shared.Position).x += row.read(shared.Velocity).dx;
}

const systems = [_]gkz.Sys(R){gkz.system(R, "move", move)};
const descriptor = shared.Descriptor{ .count = systems.len, .systems = &systems };

/// The reload entry point. `reload.NativeLibSource` looks this symbol up and reads the descriptor's
/// systems. The returned pointer is into this `.so`'s static data — valid while the library is open.
export fn gkz_systems() callconv(.c) *const shared.Descriptor {
    return &descriptor;
}
