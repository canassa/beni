//! L4: the anchors of a read below a caller slot (`docs/design/ownership-v2.md` §2.1,
//! *One below*): the slot and each fold above it that a walk below it reaches, each read
//! through a key of its own, so no reader of a call's tree at and below a slot reads the
//! slot's words alone.
//!
//! Obligations kept here: O6 (`⟲` covers every level: a read below a slot misses no fold above it).

const std = @import("std");
const Ids = @import("Ids.zig");
const LevelTargets = @import("LevelTargets.zig");

const Error = Ids.ChargeError;
const PathId = Ids.PathId;

/// An anchor of a read below a caller slot: slot `at`, and its key below it (`Relation.Eval.instBelow`).
pub const Anchor = struct { at: PathId, key: u32 };

/// The anchors of slot `q` in frame `f`'s graph, in `arena`: `q` and the folds above it
/// (`LevelTargets.of`), less one below another, which a reader meets through it by the words.
pub fn of(f: anytype, g: std.mem.Allocator, arena: std.mem.Allocator, q: PathId) Error![]const PathId {
    var ps: std.ArrayList(PathId) = .empty;
    try ps.append(arena, q);
    if (LevelTargets.hasMiddle(f.places, f.places.pathPlace(q)) and !@import("Mutate.zig").on(.below_folds_off)) try LevelTargets.of(f, g, arena, q, &ps);
    var out: std.ArrayList(PathId) = .empty;
    for (ps.items) |p| if (!LevelTargets.coveredBy(f.places, ps.items, p)) try out.append(arena, p);
    return out.items;
}

/// Whether `q` has an anchor other than itself: a reader that concludes something of every
/// slot below `q` from `q`'s words alone leaves such a slot to a reader of every anchor.
pub fn foldsAbove(f: anytype, g: std.mem.Allocator, arena: std.mem.Allocator, q: PathId) Error!bool {
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
