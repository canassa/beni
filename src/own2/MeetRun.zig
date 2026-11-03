//! L5: the members of a sorted run of slots that a set meets, in one pass
//! (`docs/design/ownership-v2.md` §2.3.1): what `Subtree.meetIn` answers
//! for each member alone, without its anchor-by-anchor prefix test. A
//! member is in a symbol `↓p` when the member or one of its ancestors is an
//! anchor of `p`, looked up in the anchors' sorted run, so a member costs
//! its depth, never the anchors' count. Read by `HoldAt.holdsAt`.
//!
//! Obligations kept here: none of §2.14's directly (each member is kept
//! exactly when `Subtree.meetIn` of it alone is true).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");

const Table = Slots.Table;
const SetId = Slots.SetId;
const PathId = Ids.PathId;
const Error = Slots.Error;

/// The elements of `run` that set `s` meets, appended to `out` in `run`'s
/// order: an explicit slot `s` holds or a symbol of `s` reaches, a symbol
/// of `run` as `Subtree.meetIn` reads it; an exclusion is skipped.
pub fn meetRun(t: *Table, gpa: Allocator, account: *Ids.Account, places: *Place.Table, s: SetId, run: []const u32, out: *std.ArrayList(u32)) Error!void {
    if (s == Slots.empty) return;
    const ex = Subtree.explicit(t, s);
    const excl = t.elems(s)[ex.len .. t.elems(s).len - Subtree.subs(t, s).len];
    var anchors: std.ArrayList(SetId) = .empty;
    defer anchors.deinit(gpa);
    // The shallowest anchor: no ancestor above it can be one.
    var top: u32 = std.math.maxInt(u32);
    for (Subtree.subs(t, s)) |x| {
        const a = try Subtree.anchors(t, gpa, account, places, Slots.pathOf(x));
        try anchors.append(gpa, a);
        for (t.elems(a)) |y| top = @min(top, places.pathDepth(.from(y)));
    }
    for (run) |el| {
        if (Slots.isNot(el)) continue;
        if (Slots.isSub(el)) {
            if (try Subtree.meetIn(t, gpa, account, places, s, try t.internSorted(gpa, account, &.{el}))) try out.append(gpa, el);
            continue;
        }
        try account.reserve(.inspection, 1);
        if (std.sort.binarySearch(u32, ex, el, Table.order) != null) {
            try out.append(gpa, el);
            continue;
        }
        if (anchors.items.len == 0 or std.sort.binarySearch(u32, excl, el | Slots.not_bit, Table.order) != null) continue;
        if (try underAnchor(t, account, places, anchors.items, top, .from(el))) try out.append(gpa, el);
    }
}

/// Whether `q` or an ancestor of it no shallower than `top` is in one of
/// the anchor runs.
fn underAnchor(t: *const Table, account: *Ids.Account, places: *const Place.Table, anchors: []const SetId, top: u32, q: PathId) Error!bool {
    var at = q;
    while (places.pathDepth(at) >= top) {
        try account.reserve(.path, 1);
        for (anchors) |a| if (std.sort.binarySearch(u32, t.elems(a), at.int(), Table.order) != null) return true;
        if (places.pathDepth(at) == 0) return false;
        at = places.pathParent(at);
    }
    return false;
}
