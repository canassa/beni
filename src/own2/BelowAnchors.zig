//! L4: the anchors of a read below a caller slot (`docs/design/ownership-v2.md` §2.1, *One below*, *Every name*): the slot
//! and each fold above it a walk below it reaches, by every name, each through a key of its own, never its words alone.
//!
//! Obligations kept here: O6 (`⟲` covers every level: a read below a slot misses no fold above it).

const std = @import("std");
const Ids = @import("Ids.zig");
const LevelTargets = @import("LevelTargets.zig");

const Error = Ids.ChargeError;
const PathId = Ids.PathId;

/// An anchor of a read below a caller slot: slot `at`, and its key below it (`Relation.Eval.instBelow`).
pub const Anchor = struct { at: PathId, key: u32 };

/// The anchors of slot `q` in `f`'s graph, in `arena`: `q`, the level paths of a join on it (`Slots.joinNames`, as
/// `Subtree.anchors` names them), the folds above each (`LevelTargets.of`) and theirs, less one below another.
pub fn of(f: anytype, g: std.mem.Allocator, arena: std.mem.Allocator, q: PathId) Error![]const PathId {
    var ps: std.ArrayList(PathId) = .empty;
    try ps.append(arena, q);
    if (!@import("Mutate.zig").on(.below_join_one_name)) for (try f.slots.joinNames(g, arena, f.account, f.places, q)) |y| try add(arena, &ps, .from(y));
    const n = ps.items.len; // `q` and its names; `LevelTargets.of` closes over the folds above each
    for (0..n) |i| if (LevelTargets.hasMiddle(f.places, f.places.pathPlace(ps.items[i])) and !@import("Mutate.zig").on(.below_folds_off)) try LevelTargets.of(f, g, arena, ps.items[i], &ps);
    var i = n; // a fold's level paths
    while (i < ps.items.len) : (i += 1) if (!@import("Mutate.zig").on(.below_join_one_name)) for (try f.slots.joinNames(g, arena, f.account, f.places, ps.items[i])) |y| try add(arena, &ps, .from(y));
    var out: std.ArrayList(PathId) = .empty;
    for (ps.items) |p| if (!LevelTargets.coveredBy(f.places, ps.items, p)) try add(arena, &out, p);
    return out.items;
}
fn add(arena: std.mem.Allocator, ps: *std.ArrayList(PathId), p: PathId) std.mem.Allocator.Error!void {
    for (ps.items) |x| if (x == p) return;
    try ps.append(arena, p);
}

/// Whether `q` is a fold on a cycle with a middle: its words name every level below it, so
/// its key is read as a fold's is, all of it at each result slot, never by its steps.
pub fn isFold(f: anytype, q: PathId) bool {
    if (@import("Mutate.zig").on(.below_folds_off) or f.places.pathParent(q) == .none) return false;
    return f.places.pathStep(q).kind == .level and LevelTargets.hasMiddle(f.places, f.places.pathPlace(q));
}

/// Whether `q` is a fold or has an anchor other than itself: a reader that concludes something
/// of every slot below `q` from `q`'s words alone leaves such a slot to a reader of every anchor.
pub fn foldsAbove(f: anytype, g: std.mem.Allocator, arena: std.mem.Allocator, q: PathId) Error!bool {
    if (isFold(f, q)) return true;
    const as = try of(f, g, arena, q);
    return as.len != 1 or as[0] != q;
}

/// Every arrival of call `call`'s callee at and below caller slot `prefix` (`↓p`, §2.3.1):
/// each anchor's key, its items widened, with `tags`.
pub fn whole(e: anytype, call: u32, which: u32, prefix: PathId, tags: u32, out: *std.ArrayList(u32)) Error!void {
    var anchors: std.ArrayList(Anchor) = .empty;
    defer anchors.deinit(e.gpa());
    try e.instBelow(call, prefix, which, e.cur_sub, &anchors);
    for (anchors.items) |an| {
        var i: usize = 0;
        while (i < e.keys.items[an.key].leaves.items.len) : (i += 1) if (try e.f.withTags(try e.widen(e.keys.items[an.key].leaves.items[i], e.keys.items[an.key].at.items[i]), tags)) |y| try out.append(e.gpa(), y);
    }
}
