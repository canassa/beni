//! L3: the payload a read runs past (`docs/design/ownership-v2.md` §2.1, *The
//! exit rule*). A base's step has no name below a family's payload, and an
//! empty reading tells a caller the object is fresh, so the value there is
//! read whole, by the payload's slot.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Replay = @import("Replay.zig");

fn payload(pl: *const Place.Table, p: Ids.PlaceId) bool {
    return pl.kind(p) == .@"var" and pl.steps(p).steps.len != 0;
}

/// A `⟲` at `p` names no level of a value: a payload's, or a concrete place on no cycle.
fn noLevel(pl: *const Place.Table, p: Ids.PlaceId) bool {
    return if (pl.kind(p) == .@"var") payload(pl, p) else !pl.onCycle(p);
}

/// Whether `words` from `root` take a `⟲` at a family's payload, or at a place with no
/// cycle, at or past word `at`: a level no concrete structure has (§2.1, *The exit rule*).
pub fn atPayload(pl: *const Place.Table, root: Ids.PlaceId, words: []const u32, at: u32) bool {
    if (root == .none) return false;
    var p = root;
    for (words, 0..) |w, i| {
        const st = Place.Step.fromWord(w);
        if (st.kind == .level and i >= at and noLevel(pl, p)) return true;
        if (st.kind == .level or st.isRow()) continue;
        p = pl.child(p, st) orelse return false;
    }
    return false;
}

/// Whether `words` from `root` stand at or run past a family's payload, or take a `⟲`
/// where no cycle is: an empty read there says nothing of what is there.
pub fn reaches(pl: *const Place.Table, root: Ids.PlaceId, words: []const u32) bool {
    if (root == .none) return false;
    var p = root;
    for (words) |w| {
        const st = Place.Step.fromWord(w);
        if (payload(pl, p) or (st.kind == .level and noLevel(pl, p))) return true;
        if (st.kind == .level or st.isRow()) continue;
        p = pl.child(p, st) orelse return false;
    }
    return payload(pl, p);
}

/// The `var` slot, below a root, that `words` from `t` run past, into `out`:
/// its steps name none of the rest. False: `words` run past none.
pub fn prefix(e: anytype, t: Ids.PathId, words: []const u32, out: *std.ArrayList(u32)) !bool {
    if (@import("Mutate.zig").on(.payload_prefix_off) or @import("Mutate.zig").on(.payload_read_off)) return false;
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(e.gpa());
    var n = words.len;
    while (n > 1) {
        n -= 1;
        ps.clearRetainingCapacity();
        try Replay.replay(e.gpa(), e.account(), e.places(), t, words[0..n], &ps);
        for (ps.items) |p| if (e.places().kind(e.places().pathPlace(.from(p))) == .@"var") {
            try out.append(e.gpa(), p);
            return true;
        };
    }
    return false;
}

/// What value `v` holds at the payload `words` run past, when an empty read met one:
/// a parameter's whole, any other root's `⊤`. An empty read would say fresh.
pub fn read(e: anytype, v: u32, words: []const u32, out: *std.ArrayList(u32)) !void {
    if (@import("Mutate.zig").on(.payload_read_off)) return;
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
