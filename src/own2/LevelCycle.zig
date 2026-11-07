//! L2: the place a `⟲` of a path means on a built value
//! (`docs/design/ownership-v2.md` §2.1, *A step past a fold*). A built value's
//! own place can be another instantiation than the slot's: a non-regular type's
//! never repeat, and a literal's place leads to the type's fold. The path's own
//! steps from the value it starts at name the place (#2062).
//!
//! Obligations kept here: none of §2.14's directly.

const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PlaceId = Ids.PlaceId;

/// The place a value of frame `f` stands for: a choice's, its first arm's.
pub fn rootOf(f: anytype, v0: u32) PlaceId {
    var x = f.val(v0);
    while (x.kind == .alt and x.kids.len >= 2) x = f.val(f.kidsOf(x)[1]);
    return x.place;
}

/// The place `words` reach from `root`, a level or a row staying where it is: a row
/// step names the field after it, or the record's other fields (§2.1); `own`, the
/// value's own place, where a step names no place.
pub fn of(pl: *const Place.Table, root: PlaceId, words: []const u32, own: PlaceId) PlaceId {
    if (root == .none) return own;
    var p = root;
    for (words) |w| {
        const st = Place.Step.fromWord(w);
        if (st.kind == .level or st.isRow()) continue;
        p = pl.child(p, st) orelse return own;
    }
    return p;
}
