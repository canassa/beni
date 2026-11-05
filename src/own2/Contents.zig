//! L11: a cell's contents are separated (`docs/design/ownership-v2.md`
//! §2.13.7, *The contents relation*): the frame reads one name per slot of
//! a cell's `◆`, so a store that may put one object at two slots makes the
//! cell's contents escape at the store. A store is a contract's (`Ref.set`'s
//! payload, a helper's, published when it hangs on the helper's parameters)
//! or what a cell callback answers.
//!
//! Obligations kept here: none of §2.14's directly (`Resolve` refuses an
//! edit of an escaped object). A verdict read in a group's inference is
//! checked by its validation round (§2.12 step 3), as every escape is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");
const Loans = @import("Loans.zig");
const Cells = @import("Cells.zig");
const Stored = @import("Stored.zig");
const Eval = @import("Eval.zig");

const Error = Relation.Error;
const Evaluation = Eval.Evaluation;
const Cond = Contract.Cond;
const none: u32 = Ids.none_int;

/// Every store of evaluation `e`: where one may hold an object twice, what
/// the cell holds escapes at the store. One that hangs on the frame's own
/// parameters goes in the code's draft `d` for its callers to judge.
pub fn check(e: *Evaluation, arena: Allocator, d: *Contract.Draft) Error!void {
    const f = e.fr();
    var q: u32 = 0;
    while (q < f.calls.items.len) : (q += 1) {
        const call = f.calls.items[q];
        if (call.contract == none) continue;
        const h = e.contracts.head(call.contract);
        for (e.contracts.storesOf(h.stores)) |s| {
            if (s.j >= call.args.len or !try several(e, q, s.j, s.slot)) continue;
            const c = try Distinct.instSel(&e.ev, try e.contracts.cond(e.ev.arena, s.cond), q);
            if (c.isYes()) continue;
            if (try ownCell(e, q, s, c)) |own| {
                try d.addStore(arena, f.account, .{ .j = own[0], .slot = own[1], .cond = c });
            } else try taint(e, q, .{ .kind = .param, .j = s.j, .slot = s.slot }, q);
        }
        for (e.contracts.labelsOf(h.labels), 0..) |l, li| {
            const vi = e.ev.known.get(.{ q, @intCast(li) }) orelse continue;
            const cs = (try Loans.supply(f, e.contracts, l)) orelse continue;
            if (cs.j >= call.args.len or !try several(e, q, cs.j, cs.slot)) continue;
            // Its selections are of what it was supplied, separated by this
            // rule, or of captures, at slots `Stored` escaped.
            if (e.contracts.head(f.calls.items[vi].contract).res_cond.no) try taint(e, q, cs, vi);
        }
    }
}

/// The handle below parameter slot `(j, cs)`'s `◆` of call `q`'s arguments.
fn handle(e: *Evaluation, q: u32, j: u32, cs: Contract.Rel) Error!u32 {
    const f = e.fr();
    const ws = f.slots.relWords(cs);
    return e.ev.valueAt(f.calls.items[q].args[j], ws[0 .. ws.len - 1]);
}

/// Whether the cell at `◆` slot `(j, cs)` of call `q` may hold more than one object.
fn several(e: *Evaluation, q: u32, j: u32, cs: Contract.Rel) Error!bool {
    const f = e.fr();
    const p = f.val(try handle(e, q, j, cs)).place;
    return p == .none or !try Cells.oneObject(f, p);
}

/// The frame's own parameter slot that names the cell of store `s` of call
/// `q`, when its condition `c` asks only such parameters: the caller can judge it.
fn ownCell(e: *Evaluation, q: u32, s: Contract.Store, c: Cond) Error!?[2]u32 {
    const f = e.fr();
    if (c.no) return null;
    const own = e.w.code.params.len;
    for (c.sel) |o| if (Contract.isFed(o) or Contract.occParam(o) >= own) return null;
    const x = f.val(try handle(e, q, s.j, s.slot));
    if (x.kind != .ref or x.family != Slots.empty or f.roots.items[x.root].kind != .param or f.roots.items[x.root].a >= own) return null;
    const rel = try f.slots.relOf(f.gpa, f.account, f.places, f.pos.items[x.pos].slot);
    const words = try std.mem.concat(f.arena, u32, &.{ f.slots.relWords(rel), &.{Place.Step.contents.word()} });
    return .{ f.roots.items[x.root].a, try f.slots.relOfWords(f.gpa, f.account, f.places, words) };
}

fn taint(e: *Evaluation, q: u32, cs: Contract.Arrival, at: u32) Error!void {
    const f = e.fr();
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(e.gpa());
    try Stored.taint(&e.ev, q, cs, &.{}, false, &ls);
    for (ls.items) |lf| try Eval.addEscapeAt(e, lf, f.calls.items[q].point, at);
}
