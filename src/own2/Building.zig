//! L11: the stack of subtrees the read-off describes once per place, split
//! from `Put` (`docs/design/ownership-v2.md` §2.10 *Read-off*); their memo is `PutMemo`.
//!
//! Obligations kept here: none of §2.14's directly (a subtree holds everything said in it).

const Ids = @import("Ids.zig");
const SupplyKey = @import("SupplyKey.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Eval = @import("Eval.zig");

const Error = Eval.Error;
const PathId = Ids.PathId;
const Sink = Eval.Sink;

pub fn begin(s: *Sink, q: PathId) Error!void {
    s.serial += 1;
    try s.building.append(s.e.gpa(), .{ .q = q, .depth = s.serial });
}

/// What `described` keys a leaf at slot `q` of list `out` by: inside a
/// subtree being described, that subtree.s own (a subtree kept for its
/// place must hold everything said in it, whatever was said before).
pub fn describedKey(s: *Sink, x: u32, q: PathId, out: anytype) Error![5]u32 {
    if (s.building.items.len == 0) return [2]u32{ x, q.int() } ++ SupplyKey.ofList(out.label, out.k, out.key);
    return .{ x, q.int(), s.building.items[s.building.items.len - 1].depth, Relation.open_bit, SupplyKey.none };
}

/// The innermost subtree, made: its arrivals and subtrees in one node,
/// its labels the draft's.
pub fn end(s: *Sink) Error!Contract.Node {
    var b = s.building.pop().?;
    const same = try s.arena.alloc(u32, s.d.labels.items.len);
    for (same, 0..) |*x, i| x.* = @intCast(i);
    return s.e.contracts.putRes(s.e.gpa(), s.e.fr().slots, &b.res, same);
}
