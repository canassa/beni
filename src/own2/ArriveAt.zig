//! L5: an arrival read at a caller slot, split from `Relation` (`Eval.feedAt`,
//! `docs/design/ownership-v2.md` §2.10, *Arrivals by structure*). At a
//! family's payload all of it (§2.1, *The exit rule*); an open parameter's
//! slots below a slot each by its own words, one a cycle folds above the
//! slot too (§2.1, *A level read on a built value*, #2195).
//!
//! Obligations kept here: O3 (a read at a payload loses no object of what
//! arrives) and O6 (a slot folded above is read by its own words).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const SlotWords = @import("SlotWords.zig");
const Subtree = @import("Subtree.zig");

const Error = Ids.ChargeError;
const PathId = Ids.PathId;
const none: u32 = Ids.none_int;

/// Arrival `a` read at caller slot `slot`, `suffix` the slot's words below its
/// entry: by those words, or at a payload whole, since a word there says no depth (§2.1).
pub fn at(e: anytype, call: u32, c: Contract.Id, a: Contract.Arrival, slot: PathId, open: bool, suffix: []const u32, out: *std.ArrayList(u32)) Error!void {
    if (Subtree.wholeAt(e.places(), a, slot)) |w| return e.arrivalLeaves(call, c, w, &.{}, out);
    const r = Subtree.readAt(e.places(), a, slot, open);
    // A type variable's slot stays deep: it holds what the row's field holds, whatever that is.
    try e.arrivalLeaves(call, c, if (e.places().kind(e.places().pathPlace(slot)) == .@"var") r else Subtree.inRow(e.f.slots, r, suffix), suffix, out);
}

/// Parameter arrival `a` of key `ki`'s call, open at caller slot `base` (words
/// `bw`, its entry `n` steps from the root), at each slot below `base`. `own`:
/// `a` is the parameter's own slot, so a slot folded above `base` is that slot
/// by its own words, not a suffix of them.
pub fn below(e: anytype, ki: u32, call: u32, base: PathId, bw: []const u32, n: u32, a: Contract.Arrival, own: bool) Error!void {
    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(e.gpa());
    for (e.f.slots.items(try Subtree.belowAll(e.f.slots, e.gpa(), e.account(), e.places(), base))) |sl| if (sl != base.int()) {
        const sr = try e.f.slots.relOf(e.gpa(), e.account(), e.places(), .from(sl));
        const sw = e.f.slots.relWords(sr);
        var sa = a;
        const pk = e.places().kind(e.places().pathPlace(.from(sl)));
        sa.deep = a.deep or pk == .@"var" or pk == .@"opaque";
        const up = own and !SlotWords.startsAt(sw, bw);
        if (up) sa = .{ .kind = .param, .j = a.j, .slot = sr, .deep = sa.deep };
        got.clearRetainingCapacity();
        try at(e, call, none, sa, .from(sl), false, if (up) &.{} else sw[@min(n, sw.len)..], &got);
        for (got.items) |x| try e.addBelow(ki, x, sl);
    };
}
