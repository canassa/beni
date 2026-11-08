//! L5: which declarations a comparison's walk covers (§2.13.6), split from
//! `Groups` (#2116).
//!
//! Obligations kept here: none.

const std = @import("std");
const Prepass = @import("Prepass.zig");

/// Per declaration of the module, whether its walk is a comparison's: a
/// type's `eq` or `compare`, or the declaration of this module a
/// comparison names through aliases (`compare = helper`: `helper`'s
/// writes are the comparison's, refused at the write). A comparison
/// that names another module's function is walked itself, and stays
/// unbuilt at the name (`isWalked`).
pub fn of(in: anytype, isComparison: *const fn (@TypeOf(in), u32) bool) std.mem.Allocator.Error![]bool {
    const out = try in.gpa.alloc(bool, in.bir.decls.len);
    @memset(out, false);
    for (0..in.bir.decls.len) |di| {
        if (!isComparison(in, @intCast(di))) continue;
        const t = Prepass.aliasTarget(in.birs, in.provenance, .{ in.module, @intCast(di) });
        if (t[0] == in.module) out[t[1]] = true;
    }
    return out;
}
