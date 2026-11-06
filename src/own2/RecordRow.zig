//! L3: a record's row in values (`docs/design/ownership-v2.md` §2.1, *The row
//! of a record*): a step of a built record, a row step of a reference, and a
//! row's arrivals fed to a key whose prefix runs past the row.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Place = @import("Place.zig");
const Trees = @import("Trees.zig");

const Step = Place.Step;
const Node = Trees.Node;

/// Step `st` of a built record `v`: the field's kid, read from the row's
/// kid when none names it. A row step that is not the record's own is the kids its names do
/// not hold, a view with no storage of its own (§2.1, *The row of a record*).
pub fn kid(f: anytype, v: u32, st: Step) !u32 {
    const x = f.val(v);
    const ks = f.kidsOf(x);
    const rs = f.wordsOf(x.extra);
    if (!st.inRow()) return f.scalar();
    if (st.isRow()) {
        for (rs, ks) |r, k| if (r == st.kidWord()) return k;
        var kids: std.ArrayList(u32) = .empty;
        defer kids.deinit(f.gpa);
        var ranks: std.ArrayList(u32) = .empty;
        defer ranks.deinit(f.gpa);
        for (rs, ks) |r, k| if (!f.places.rowHolds(st, try Step.ofRank(f.account, r))) continue else {
            try kids.append(f.gpa, k);
            try ranks.append(f.gpa, r);
        };
        if (kids.items.len == 0) return f.scalar();
        return f.mk(.{ .kind = .built, .form = .record, .kids = try f.mkKids(kids.items), .extra = try f.mkWords(ranks.items) });
    }
    for (rs, ks) |r, k| if (r == st.kidWord()) return k;
    if (rs.len != 0 and rs[rs.len - 1] & Place.row_rank != 0) return f.mk(.{ .kind = .top, .site = v });
    return f.scalar();
}

/// Row step `st` of `v`, a reference: the position's own row where its place has this
/// step, else a view of the positions the row reads there (§2.1).
pub fn ofRef(f: anytype, v: u32, st: Step) !u32 {
    const x = f.val(v);
    const place = f.places.pathPlace(f.pos.items[x.pos].slot);
    if (f.places.kind(place) != .record) return f.mk(.{ .kind = .top, .site = v });
    var kids: std.ArrayList(u32) = .empty;
    defer kids.deinit(f.gpa);
    var ranks: std.ArrayList(u32) = .empty;
    defer ranks.deinit(f.gpa);
    const steps = f.places.steps(place).steps;
    if (steps.len == f.places.rowNames(st).len + 1 and steps[steps.len - 1].eql(st)) {
        const p = (try f.child(x.pos, .plain, st.word(), 0)).?;
        return f.mk(.{ .kind = .ref, .root = x.root, .pos = p });
    }
    for (steps) |s| {
        if (!f.places.rowHolds(st, s)) continue;
        const p = (try f.child(x.pos, .plain, s.word(), 0)) orelse continue;
        try kids.append(f.gpa, try f.mk(.{ .kind = .ref, .root = x.root, .pos = p }));
        try ranks.append(f.gpa, s.kidWord());
    }
    if (kids.items.len == 0) return f.scalar();
    return f.mk(.{ .kind = .built, .form = .record, .kids = try f.mkKids(kids.items), .extra = try f.mkWords(ranks.items) });
}

/// Row node `r`'s arrivals, its parent `up` steps from the root and a key's prefix past it (§2.1).
pub fn feed(e: anytype, ki: u32, r: Node, up: []const u32) !void {
    const rel = e.f.slots.rels.find(up) orelse try e.f.slots.relOfWords(e.gpa(), e.account(), e.places(), up);
    const here = try e.gpa().dupe(Trees.Arrival, e.contracts.trees.here(r));
    defer e.gpa().free(here);
    const opens = try e.gpa().dupe(Trees.Arrival, e.contracts.trees.open(r));
    defer e.gpa().free(opens);
    for (here) |a| try e.feedBelow(ki, rel, true, a);
    for (opens) |a| try e.feedBelow(ki, rel, true, a);
}
