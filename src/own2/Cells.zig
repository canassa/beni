//! L8: a cell's `◆` (`docs/design/ownership-v2.md` §2.13.7) as an evaluation
//! reads it: whether a write is a cell operation, a cell operation's
//! targets behind the barrier, and the slots of the contents that what a
//! cell callback answers may share.
//!
//! Obligations kept here: none of §2.14's directly (the barrier's half of
//! O1 is `Eval`'s and `Resolve`'s, which call these).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Forest = @import("Forest.zig");

const Error = Relation.Error;
const Step = Place.Step;

/// Whether `rel` ends in a cell's `◆`.
pub fn endsInContents(slots: *const Slots.Table, rel: Slots.Rel) bool {
    const words = slots.relWords(rel);
    return words.len != 0 and Step.fromWord(words[words.len - 1]).kind == .contents;
}

/// Whether `rel` steps through a cell's `◆`.
pub fn throughContents(slots: *const Slots.Table, rel: Slots.Rel) bool {
    for (slots.relWords(rel)) |w| if (Step.fromWord(w).kind == .contents) return true;
    return false;
}

/// Whether write `x` is a cell operation: a shallow write of a `◆` slot,
/// `Ref.set`/`update`/`modify`. Rewriting the cell stales no reader, so it
/// never makes a closure `once` (§2.11.4). An edit in place of what the
/// cell holds is deep there, so it is never one.
pub fn cellWrite(slots: *const Slots.Table, x: Contract.Effect) bool {
    return !x.deep and endsInContents(slots, x.slot);
}

/// Whether path `p` passes through a cell's `◆`: what it names is behind
/// the barrier, held by the cell and reached only through its worded
/// operations, whose results are holders of their own.
pub fn behindCell(places: *const Place.Table, p: Ids.PathId) bool {
    var at = p;
    while (at != .none and places.pathParent(at) != .none) : (at = places.pathParent(at)) {
        if (places.pathStep(at).kind == .contents) return true;
    }
    return false;
}

/// A cell's `◆`, `words` ending in it, below value `arg`: the contents
/// position of each cell the argument names, whatever its contents' type,
/// appended to `out`. A parameter's projection may name its cells by slots
/// below its position (`m.world` of a captured record): each named slot's
/// `◆` as a position of its own. Either way the target is behind the
/// barrier (`Distinct.overlap`): a cell operation replaces what the cell
/// holds without reading it, whatever a callback escaped of it.
pub fn targets(ev: *Relation.Eval, arg: u32, words: []const u32, out: *std.ArrayList(u32)) Error!void {
    const f = ev.f;
    const gpa = f.gpa;
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(gpa);
    try ev.project(arg, words[0 .. words.len - 1], false, 0, 0, &ps);
    each: for (ps.items) |p| {
        const l = f.leafAt(p.leaf);
        if (l.kind == .ref) if (try f.child(l.pos, .plain, Step.contents.word(), 0)) |cp| {
            try out.append(gpa, try atPos(f, l, cp));
            continue;
        };
        if (l.kind == .ref and !l.at_pos and l.slots != Slots.empty) {
            var cs: std.ArrayList(u32) = .empty;
            defer cs.deinit(gpa);
            for (f.slots.elems(l.slots)) |el| {
                if (Slots.isNot(el)) continue;
                if (Slots.isSub(el)) break;
                // The cell at every route to the slot (§2.1, *Every name*); one
                // a position cannot name is the whole leaf.
                const rels = try f.slots.relsBelow(gpa, f.account, f.places, f.pos.items[l.pos].slot, Slots.pathOf(el), f.arena);
                if (rels.len == 0) break;
                const named = for (rels) |below| {
                    const cp = (blk: {
                        var at = l.pos;
                        for (f.slots.relWords(below)) |wd| at = (try f.child(at, .plain, wd, 0)) orelse break :blk null;
                        break :blk try f.child(at, .plain, Step.contents.word(), 0);
                    }) orelse break false;
                    try cs.append(gpa, cp);
                } else true;
                if (!named) break;
            } else if (cs.items.len != 0) {
                for (cs.items) |cp| try out.append(gpa, try atPos(f, l, cp));
                continue :each;
            }
        }
        try out.append(gpa, p.leaf);
    }
}

fn atPos(f: *Value.Frame, l: Value.Leaf, cp: u32) Error!u32 {
    const set = try f.slots.internSorted(f.gpa, f.account, &.{f.pos.items[cp].slot.int()});
    return f.leaf(.{ .kind = .ref, .root = l.root, .pos = cp, .slots = set, .tags = l.tags, .at_pos = true });
}

/// Whether what a cell of handle place `cell` holds is at most one object:
/// with no slot state, a stored value may hold one object at two of the
/// contents' slots, and the frame reads two names (`Ref.set r ( n, n )`).
/// A type variable's slot may hold any number.
pub fn oneObject(f: *Value.Frame, cell: ?Ids.PlaceId) Error!bool {
    const c = (try f.places.extend(f.gpa, f.gc(), try f.places.rootPath(f.gpa, cell orelse return false), Step.contents)) orelse return false;
    var n: u32 = 0;
    for (f.slots.items(try Subtree.belowAll(f.slots, f.gpa, f.account, f.places, c))) |s| {
        const k = f.places.kind(f.places.pathPlace(.from(s)));
        if (k == .@"var" or k == .@"opaque") return false;
        if (Slots.isObject(f.places, .from(s))) n += 1;
    }
    return n <= 1;
}

/// A slot of the contents, below the cell's `◆`: the result slot `rel`
/// of the callback, less its first step for `Ref.modify`'s `.1`.
pub const Shared = struct { words: []const u32, drop: bool };

/// The slots of the contents that a callback contract's answer may share
/// once stored back (`Ref.update`'s whole answer, `Ref.modify`'s `.1`,
/// `modify`), appended to `out`: each slot where an object stored is
/// neither one the callback was supplied (parameter 0) nor one it allocated.
pub fn shared(es: *const Forest.Entries, modify: bool, out: *std.ArrayList(Shared), gpa: std.mem.Allocator) Error!void {
    for (es.items.items) |rs| {
        const ws = es.wordsOf(rs);
        if (modify) {
            if (ws.len == 0 and !rs.open) continue;
            if (ws.len != 0) {
                const st = Step.fromWord(ws[0]);
                if (st.kind != .index or st.payload != 1) continue;
            }
        }
        for (rs.arrivals) |a| {
            const own = a.kind == .fresh or (a.kind == .param and a.j == 0);
            if (own) continue;
            try out.append(gpa, .{ .words = ws, .drop = modify and ws.len != 0 });
            break;
        }
    }
}
