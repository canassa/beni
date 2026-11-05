//! L9: what a cell callback answers as its caller reads it
//! (`docs/design/ownership-v2.md` §2.13.7, *Ref loans*, *what the callback
//! answers is stored back*): a loan of the cell, or, for `Ref.modify`'s
//! `.0`, the objects themselves when the `.1` it stores keeps none of them
//! (the owning extraction `Ref.modify slot λold → ( old, Nothing )`).
//! `Relation.arrivalLeaves` makes the loans.
//!
//! Obligations kept here: none of §2.14's directly (a loan, written, is
//! unknown, and `Resolve` refuses it; held, it holds what it lends).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Subtree = @import("Subtree.zig");
const Value = @import("Value.zig");
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");
const Relation = @import("Relation.zig");
const LabelChain = @import("LabelChain.zig");
const Cells = @import("Cells.zig");
const Trees = @import("Trees.zig");

const Error = Relation.Error;
const Step = Place.Step;

/// A cell callback's label (`Rows.fromWords`): its supply is a cell's `◆`,
/// `π_j◆`, which it answers; null for another label. Contents that are no
/// object (a `Maybe`) are supplied at the slots of their objects below.
pub fn supply(f: *Value.Frame, contracts: *const Contract.Table, l: Contract.Label) Error!?Contract.Arrival {
    const sus = contracts.suppliesOf(l.supplies);
    if (sus.len != 1 or sus[0].k != 0) return null;
    var path: std.ArrayList(u32) = .empty;
    defer path.deinit(f.gpa);
    const a, const words = (try cellAt(&contracts.trees, f.slots, sus[0].res_root, &path, f.gpa)) orelse return null;
    return .{ .kind = .param, .j = a.j, .slot = try f.slots.relOfWords(f.gpa, f.account, f.places, try f.arena.dupe(u32, words)) };
}

/// A parameter arrival at node `n` of a supply tree, `path` below its root,
/// and the words of the cell's `◆` it is below by `path`.
fn cellAt(t: *const Trees.Table, slots: *const Slots.Table, n: Contract.Node, path: *std.ArrayList(u32), gpa: std.mem.Allocator) Error!?struct { Contract.Arrival, []const u32 } {
    for ([_][]const Contract.Arrival{ t.here(n), t.open(n) }) |run| for (run) |a| if (a.kind == .param) {
        const ws = slots.relWords(a.slot);
        if (ws.len <= path.items.len or !std.mem.endsWith(u32, ws, path.items)) continue;
        if (Step.fromWord(ws[ws.len - path.items.len - 1]).kind == .contents) return .{ a, ws[0 .. ws.len - path.items.len] };
    };
    for (t.kids(n)) |k| {
        try path.append(gpa, k[0]);
        defer _ = path.pop();
        if (try cellAt(t, slots, k[1], path, gpa)) |x| return x;
    }
    return null;
}

/// Call `q`'s cell callback label `li`, supplied `cs` and applied by
/// virtual call `vi`: what it answers is a loan of the cell, but for a
/// `modify` (a worded `cellmodify` whose code's contract is final) whose
/// `.0` the stored `.1` cannot share (`lends`).
pub fn answer(c: LabelChain.Chain, ev: *Relation.Eval, q: u32, li: u32, modify: bool, cs: Contract.Arrival, vi: u32, cell: ?Ids.PlaceId) Error!void {
    const vc = c.f.calls.items[vi];
    if (modify and try oneObject(c.f, cell) and !try lends(c.f, c.f.roots.items[vc.root].path, try LabelChain.entriesOf(c, c.contracts.head(vc.contract).res_root))) return;
    try lend(ev, q, li, cs);
}

/// What call `q`'s label `li` answers is a loan of the cell `cs` names.
pub fn lend(ev: *Relation.Eval, q: u32, li: u32, cs: Contract.Arrival) Error!void {
    try ev.lent.put(ev.f.gpa, .{ q, li }, @intCast(ev.lent_cells.items.len));
    try ev.lent_cells.append(ev.f.gpa, .{ cs.j, cs.slot });
}

/// Whether what a cell callback answers at `.0` may be what the cell keeps
/// at `.1`, read off its contract's answer `es` at path `from`: `.1` holds an object of
/// unknown code, or both hold the contents supplied (parameter 0, or a
/// cell's contents a capture reaches: the callback may have re-entered it), or both
/// what the callback allocated. A capture or a top-level value at `.1` is
/// the cell's then and escapes at the call (`Stored`), so whatever else
/// names it is refused an edit in place. A slot that holds no object
/// (`[*]` of a `List Int`) shares nothing.
pub fn lends(f: *Value.Frame, from: Ids.PathId, es: *const Forest.Entries) Error!bool {
    var at = [2]u8{ 0, 0 };
    for (es.items.items) |rs| {
        const ws = es.wordsOf(rs);
        // The answer's own tuple is neither part. An open entry is both, and
        // so is an answer that is no tuple of the callback's (a shared one).
        if (ws.len == 0 and !rs.open and allFresh(rs.arrivals)) continue;
        if (!try holds(f, from, ws)) continue;
        var bits: u8 = 0;
        for (rs.arrivals) |a| bits |= switch (a.kind) {
            .param => @intFromBool(a.j == 0 or a.deep or Cells.throughContents(f.slots, a.slot)),
            .fresh => 2,
            .shared => if (ws.len == 0) 4 else 0,
            else => 4,
        };
        const st: ?Step = if (ws.len != 0) Step.fromWord(ws[0]) else null;
        for (&at, 0..) |*x, k| if (st == null or st.?.kind != .index or st.?.payload == k) {
            x.* |= bits;
        };
    }
    // A label's answer at `.0` may be whatever `.1` holds.
    return at[1] & 4 != 0 or at[0] & at[1] & 3 != 0 or (at[0] & 4 != 0 and at[1] != 0);
}

fn allFresh(arrivals: []const Contract.Arrival) bool {
    for (arrivals) |a| if (a.kind != .fresh) return false;
    return true;
}

/// Whether what a cell of handle place `cell` holds is at most one object:
/// with no slot state, a stored value may hold one object at two of the
/// contents' slots, and the frame reads two names (`Ref.set r ( n, n )`).
/// A type variable's slot may hold any number.
fn oneObject(f: *Value.Frame, cell: ?Ids.PlaceId) Error!bool {
    const c = (try f.places.extend(f.gpa, f.gc(), try f.places.rootPath(f.gpa, cell orelse return false), Step.contents)) orelse return false;
    var n: u32 = 0;
    for (f.slots.items(try Subtree.belowAll(f.slots, f.gpa, f.account, f.places, c))) |s| {
        const k = f.places.kind(f.places.pathPlace(.from(s)));
        if (k == .@"var" or k == .@"opaque") return false;
        if (Slots.isObject(f.places, .from(s))) n += 1;
    }
    return n <= 1;
}

/// Whether a slot at `words` below `from` may hold an object; one the
/// answer's place cannot name may.
fn holds(f: *Value.Frame, from: Ids.PathId, words: []const u32) Error!bool {
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(f.gpa);
    try Slots.replay(f.gpa, f.account, f.places, from, words, &ps);
    for (ps.items) |p| if (Slots.holdsAny(f.places, .from(p))) return true;
    return ps.items.len == 0;
}
