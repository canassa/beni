//! L3: what a `⊤` lies inside (`docs/design/ownership-v2.md` §2.3.4): a leaf's
//! origin, the value at the place that could not name the step.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");

/// What `⊤` leaf `l` lies inside: its origin's deep leaves, under its tags.
pub fn leaves(e: anytype, l: anytype, out: *std.ArrayList(u32)) !void {
    if (@import("Mutate.zig").on(.origin_leaves_off)) return;
    const saved = e.pass;
    e.pass = 0;
    defer e.pass = saved;
    try e.leavesOf(l.root, l.tags, out);
}
