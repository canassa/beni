//! L7: a call's subtree whose callee says only atoms there, read as the
//! callee's own node (`docs/design/ownership-v2.md` §2.10 *Read-off*,
//! *A call's subtree of atoms*; #1714). Where every arrival of the callee's
//! result at and below a slot, and open above it, is fresh, `⊤` or a
//! shared value, the slot-by-slot read gives each caller slot below the
//! destination those atoms at the callee's slot of the same steps; grafting
//! the callee's node says the same, once, where the steps below the
//! destination are named as the callee names them.
//!
//! Obligations kept here: none of §2.14's directly (`ReadOff` calls these;
//! what they say is what the slot-by-slot read says).

const std = @import("std");
const Ids = @import("Ids.zig");
const Trees = @import("Trees.zig");
const Forest = @import("Forest.zig");
const Value = @import("Value.zig");

const Error = Value.Error;
const Node = Trees.Node;

/// The node of tree `root` at slot `words` (0 for none), with the hits
/// that reach the slot in `hits`, when every arrival there, below it and
/// open above it is an atom; null otherwise. The node's own bit says what
/// is below it (`Trees.Table.atomsOnly`); at the root nothing is walked, a
/// record a node on the way to a deeper slot.
pub fn atomsAt(f: *Value.Frame, t: *const Trees.Table, root: Node, words: []const u32, hits: *std.ArrayList(Trees.Hit)) Error!?Node {
    if (words.len == 0 and !t.atomsOnly(root)) return null;
    try f.charge(.inspection, try Forest.atSlot(t, f.gpa, root, words, hits));
    for (hits.items) |h| for (h.arrivals) |a| if (a.kind == .param or a.kind == .cb) return null;
    const n = Forest.at(t, root, words) orelse return 0;
    return if (t.atomsOnly(n)) n else null;
}

/// Whether no place on `dest`'s path above it is reachable from `dest`'s
/// place: then no cycle spans `dest`, and every slot below it is `dest`'s
/// steps followed by the names its subtree gives from its own root
/// (`Place.extend` folds a return onto the path's last places on its
/// cycle). A record a place reached.
pub fn offCycles(f: *Value.Frame, dest: Ids.PathId) Error!bool {
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(f.gpa);
    var stack: std.ArrayList(Ids.PlaceId) = .empty;
    defer stack.deinit(f.gpa);
    try stack.append(f.gpa, f.places.pathPlace(dest));
    while (stack.pop()) |p| {
        if ((try seen.getOrPut(f.gpa, .{p.int()})).found_existing) continue;
        try f.charge(.inspection, 1);
        try stack.appendSlice(f.gpa, f.places.steps(p).children);
    }
    var at = f.places.pathParent(dest);
    while (at != .none) : (at = f.places.pathParent(at)) {
        try f.charge(.inspection, 1);
        if (seen.get(.{f.places.pathPlace(at).int()}) != null) return false;
    }
    return true;
}
