//! L5: a selection in its one spelling of a subtree
//! (`docs/design/ownership-v2.md` §2.9.1, *One spelling of a subtree*). A
//! deep occurrence `(j, p)*` and the occurrences at every slot of `below(p)`
//! written out ask the same objects; a contract's selection spells a
//! subtree of at most `Slots.below_min` slots written out, so a round that
//! reads it through the symbol `↓p` (§2.3.1) and one that reads it slot by
//! slot give one word run, and the first changes nothing (§2.12).
//!
//! Obligations kept here: none of §2.14's directly (a rewrite between two
//! spellings of one set of slots asks neither more nor less).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Conds = @import("Conds.zig");

const Cond = Conds.Cond;
const PathId = Ids.PathId;
const Error = Slots.Error;

/// What a selection is read against: the module's tables and each
/// parameter's root path (`.none` where a parameter has none).
pub const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    account: *Ids.Account,
    slots: *Slots.Table,
    places: *Place.Table,
    roots: []const PathId,
};

/// `c` with each deep occurrence `(j, p)*` whose `below(p)` has at most
/// `Slots.below_min` slots written out: an occurrence at each slot, deep
/// where no step below it can be named (a type variable's or an opaque
/// place), of the deep one's apartness. A deep occurrence at such a slot,
/// at steps that name no single path, or past the bound stays.
pub fn canonical(x: Ctx, c: Cond) Error!Cond {
    if (c.no) return c;
    const g = x.gpa;
    var run: std.ArrayList(u64) = .empty;
    var paths: std.ArrayList(u32) = .empty;
    defer paths.deinit(g);
    var changed = false;
    for (c.sel) |o| {
        const j = Conds.occParam(o);
        if (!Conds.isDeep(o) or j >= x.roots.len or x.roots[j] == .none) {
            try run.append(x.arena, o);
            continue;
        }
        const w = x.slots.relWords(Conds.occRel(o));
        try x.account.reserve(.cond, @intCast(1 + w.len));
        paths.clearRetainingCapacity();
        try Slots.replay(g, x.account, x.places, x.roots[j], w, &paths);
        if (paths.items.len != 1 or wild(x, .from(paths.items[0])) or
            try Subtree.moreBelow(x.slots, g, x.account, x.places, .from(paths.items[0]), Slots.below_min))
        {
            try run.append(x.arena, o);
            continue;
        }
        const all = x.slots.items(try Subtree.belowAll(x.slots, g, x.account, x.places, .from(paths.items[0])));
        try x.account.reserve(.cond, @intCast(1 + all.len));
        const ap = o & Conds.apart_bit;
        for (all) |s| {
            const q = Conds.occ(j, try x.slots.relOf(g, x.account, x.places, .from(s)));
            try run.append(x.arena, (if (wild(x, .from(s))) Conds.occDeep(q) else q) | ap);
        }
        changed = true;
    }
    if (!changed) return c;
    return Cond.of(x.account, run.items);
}

/// A slot no step below can name: a type variable's or an opaque place.
fn wild(x: Ctx, p: PathId) bool {
    const k = x.places.kind(x.places.pathPlace(p));
    return k == .@"var" or k == .@"opaque";
}
