//! L11: the stack of subtrees the read-off describes once per place, with their
//! memo, split from `Put` (`docs/design/ownership-v2.md` §2.10 *Read-off*).
//!
//! Obligations kept here: none of §2.14's directly (a subtree holds everything said in it).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Eval = @import("Eval.zig");

const Error = Eval.Error;
const PathId = Ids.PathId;
const Sink = Eval.Sink;
const none = std.math.maxInt(u32);

pub fn begin(s: *Sink, q: PathId) Error!void {
    s.serial += 1;
    try s.building.append(s.e.gpa(), .{ .q = q, .depth = s.serial });
}

/// What `described` keys a leaf at slot `q` of list `out` by: inside a
/// subtree being described, that subtree.s own (a subtree kept for its
/// place must hold everything said in it, whatever was said before).
pub fn describedKey(s: *Sink, x: u32, q: PathId, out: anytype) Error![4]u32 {
    if (s.building.items.len == 0) return .{ x, q.int(), out.label, out.k };
    return .{ x, q.int(), s.building.items[s.building.items.len - 1].depth, Relation.open_bit };
}

/// The innermost subtree, made: its arrivals and subtrees in one node,
/// its labels the draft's.
pub fn end(s: *Sink) Error!Contract.Node {
    var b = s.building.pop().?;
    const same = try s.arena.alloc(u32, s.d.labels.items.len);
    for (same, 0..) |*x, i| x.* = @intCast(i);
    return s.e.contracts.putRes(s.e.gpa(), s.e.fr().slots, &b.res, same);
}

/// A subtree described before at the same place (`key`, with `q`'s place):
/// its node, `none` while it is described, or null when it is not yet.
pub fn memoGet(s: *Sink, key: [6]u32) ?u32 {
    const v = s.nodes.get(key) orelse return null;
    if (v == none - 2) return null;
    // Met again while it is described (a fold's answer feeding itself):
    // it adds nothing here, and nothing made meanwhile is kept.
    if (v == none) s.cut = 0;
    return v;
}

pub fn memoPut(s: *Sink, key: [6]u32, n: Contract.Node) Error!void {
    const depth = s.building.items.len;
    if (s.cut > depth) {
        try s.nodes.put(s.e.gpa(), key, n);
    } else try s.nodes.put(s.e.gpa(), key, none - 2);
    if (s.cut >= depth) s.cut = std.math.maxInt(usize);
}
