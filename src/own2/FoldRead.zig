//! L3: an arrival's words past an argument's non-regular fold
//! (`docs/design/ownership-v2.md` §2.1, *A step past a fold*). No step
//! names them, and an empty reading tells a caller the object is fresh, so
//! the value at the fold is read whole: a parameter's deep, any other
//! root's as `⊤`, since no slot of its contract says what is below. The
//! reader marks what it reads past (`Value.Leaf.past`).
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");

/// The `var` slot, below a root, that `words` from `t` run past, into `out`:
/// no step of a fold names the rest. False: `words` run past none.
pub fn prefix(e: anytype, t: Ids.PathId, words: []const u32, out: *std.ArrayList(u32)) !bool {
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(e.gpa());
    var n = words.len;
    while (n > 1) {
        n -= 1;
        ps.clearRetainingCapacity();
        try Slots.replay(e.gpa(), e.account(), e.places(), t, words[0..n], &ps);
        for (ps.items) |p| if (e.places().kind(e.places().pathPlace(.from(p))) == .@"var") {
            try out.append(e.gpa(), p);
            return true;
        };
    }
    return false;
}

/// What value `v` holds past the fold on `words`, when an empty read met one.
pub fn read(e: anytype, v: u32, words: []const u32, out: *std.ArrayList(u32)) !void {
    var n = words.len;
    while (n != 0) {
        n -= 1;
        const at = try e.valueAt(v, words[0..n]);
        const x = e.f.val(at);
        if (x.kind != .ref or e.f.pos.items[x.pos].parent == Ids.none_int or e.places().kind(e.places().pathPlace(e.f.pos.items[x.pos].slot)) != .@"var") continue;
        if (e.f.roots.items[x.root].kind == .param) return e.leavesOf(at, 0, out);
        return out.append(e.gpa(), try e.f.leaf(.{ .kind = .top }));
    }
}
