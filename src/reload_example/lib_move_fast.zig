//! Reloadable example shared object "B": the SAME `move` system slot, but with DIFFERENT logic —
//! it integrates at double speed (x += 2*dx). Hot-swapping A->B mid-stream must produce a divergent
//! trajectory that the VOPR's divergence oracle catches (the gate proves this). Exports `gkz_systems`.

const std = @import("std");
const gkz = @import("gkz");
const shared = @import("shared.zig");
const R = shared.R;

fn move(ctx: *gkz.SimCtx(R), q: *gkz.Query(R, .{ gkz.Read(shared.Velocity), gkz.Write(shared.Position) })) std.mem.Allocator.Error!void {
    _ = ctx;
    while (q.next()) |row| row.write(shared.Position).x += 2 * row.read(shared.Velocity).dx;
}

const systems = [_]gkz.Sys(R){gkz.system(R, "move", move)};
const descriptor = shared.Descriptor{ .count = systems.len, .systems = &systems };

export fn gkz_systems() callconv(.c) *const shared.Descriptor {
    return &descriptor;
}
