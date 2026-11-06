//! L9: a callee's `req` moved onto the frame's parameters
//! (`docs/design/ownership-v2.md` §2.11.2, *The caller's contract*), split from `Graft`.
//!
//! Obligations kept here: the half of O3 a moved selection carries: it names exactly
//! the objects its instantiation names, a callee's row read at the frame's record.

const std = @import("std");
const Place = @import("Place.zig");
const SlotWords = @import("SlotWords.zig");
const Replay = @import("Replay.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Graft = @import("Graft.zig");

const Error = Relation.Error;
const Base = Graft.Base;
const baseOf = Graft.baseOf;

/// Call `call`'s callee's `req` moved onto the frame's parameters (§2.11.2,
/// *The caller's contract*): when every parameter it asks is handed an exact
/// slot of a parameter of the frame, no two of those slots one at or below
/// the other, an instantiation is the occurrences moved there, and the
/// distinct check finds no pair the callee's own selection did not have.
/// Null otherwise.
pub fn of(ev: *Relation.Eval, call: Value.Call, c: Contract.Cond) Error!?Contract.Cond {
    if (c.no or c.sel.len == 0) return null;
    for (c.sel) |o| if (Contract.isFed(o)) return null;
    const g = ev.gpa();
    var js: std.ArrayList(u32) = .empty;
    defer js.deinit(g);
    var bs: std.ArrayList(Base) = .empty;
    defer bs.deinit(g);
    for (c.sel) |o| if (std.mem.indexOfScalar(u32, js.items, Contract.occParam(o)) == null) {
        const b = (try baseOf(ev, call, Contract.occParam(o))) orelse return null;
        for (bs.items) |y| if (y.j == b.j and SlotWords.overlaps(ev.places(), y.words, b.words)) return null;
        try js.append(g, Contract.occParam(o));
        try bs.append(g, b);
    };
    var out: std.ArrayList(u64) = .empty;
    var ws: std.ArrayList(u32) = .empty;
    defer ws.deinit(g);
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(g);
    for (c.sel) |o| {
        const b = bs.items[std.mem.indexOfScalar(u32, js.items, Contract.occParam(o)).?];
        const ow = ev.f.slots.relWords(Contract.occRel(o));
        if (b.words.len != 0) for (ow) |s| if (Place.Step.fromWord(s).kind == .level) return null;
        try ev.charge(.inspection, 1);
        const bits = o & (Contract.apart_bit | Contract.deep_bit);
        // A callee's row is read at the frame's record, which may name more (§2.1).
        if (for (ow) |s| {
            if (Place.Step.fromWord(s).isRow()) break true;
        } else false) {
            ps.clearRetainingCapacity();
            try Replay.replay(g, ev.account(), ev.places(), b.path, ow, &ps);
            const deep = if (SlotWords.endsInRow(ow)) Contract.deep_bit else 0;
            for (ps.items) |p| try out.append(ev.arena, Contract.occ(b.j, try ev.f.slots.relOf(g, ev.account(), ev.places(), .from(p))) | bits | deep);
            continue;
        }
        ws.clearRetainingCapacity();
        try ws.appendSlice(g, b.words);
        try ws.appendSlice(g, ow);
        try out.append(ev.arena, Contract.occ(b.j, try ev.f.slots.relOfWords(g, ev.account(), ev.places(), ws.items)) | bits);
    }
    return try Contract.Cond.of(ev.account(), out.items);
}
