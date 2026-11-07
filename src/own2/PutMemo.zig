//! L11: the memo of subtrees the read-off describes once per place, split
//! from `Put` (`docs/design/ownership-v2.md` §2.10 *Read-off*, §2.11.2).
//!
//! Obligations kept here: none of §2.14's directly (a subtree met again
//! while it is described adds nothing, and nothing made meanwhile is kept).

const std = @import("std");
const Contract = @import("Contract.zig");
const Eval = @import("Eval.zig");

const Error = Eval.Error;
const Sink = Eval.Sink;
const none = std.math.maxInt(u32);

/// A subtree described before at the same place (`key`, with `q`'s place):
/// its node, `none` while it is described, or null when it is not yet.
pub fn get(s: *Sink, key: [6]u32) ?u32 {
    const v = s.nodes.get(key) orelse return null;
    if (v == none - 2) return null;
    // Met again while it is described (a fold's answer feeding itself):
    // it adds nothing here, and nothing made meanwhile is kept.
    if (v == none) s.cut = 0;
    return v;
}

pub fn put(s: *Sink, key: [6]u32, n: Contract.Node) Error!void {
    const depth = s.building.items.len;
    if (s.cut > depth) {
        try s.nodes.put(s.e.gpa(), key, n);
    } else try s.nodes.put(s.e.gpa(), key, none - 2);
    if (s.cut >= depth) s.cut = std.math.maxInt(usize);
}

/// A failed read of `key`: remembered unless `above`, and no node.
pub fn fail(s: *Sink, key: [6]u32, above: bool) Error!?Contract.Node {
    if (!above) try s.nodes.put(s.e.gpa(), key, none - 1);
    return null;
}
