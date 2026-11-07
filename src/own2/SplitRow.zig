//! L11: a row in a callee's supply, written at a caller that names more
//! (`docs/design/ownership-v2.md` §2.1, *A row's arrival at a wider argument*). A
//! callee's `…` passed on is, at a parameter's record, each step of the row. Each goes to
//! the supply's own kid as an arrival by structure, so a later caller's `.b` and what is
//! below it find `.b` of the argument and no other field's. An arrival this does not
//! write stays at the row and is read whole.
//!
//! Obligations kept here: none of §2.14's directly: this only narrows what
//! `Forest.wholeAtRow` would read.

const std = @import("std");
const Place = @import("Place.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Slots = @import("Slots.zig");
const Value = @import("Value.zig");
const SlotWords = @import("SlotWords.zig");

const Error = Relation.Error;
const Step = Place.Step;

/// Writes arrival `a`, at supply slot `words`, into `res` step by step, when both end in a row and
/// the value is a parameter's record. Whether it did.
pub fn write(ev: *Relation.Eval, call: Value.Call, words: []const u32, a: Contract.Arrival, res: anytype, arena: std.mem.Allocator) Error!bool {
    if (a.kind != .param or a.j >= call.args.len or !SlotWords.endsInRow(words)) return false;
    const f = ev.f;
    const aw = f.slots.relWords(a.slot);
    if (!SlotWords.endsInRow(aw)) return false;
    const x = f.val(try ev.valueAt(call.args[a.j], aw[0 .. aw.len - 1]));
    if (x.kind != .ref or x.family != Slots.empty or f.roots.items[x.root].kind != .param) return false;
    const at = f.pos.items[x.pos].slot;
    const p = f.places.pathPlace(at);
    if (f.places.kind(p) != .record) return false;
    const row = Step.fromWord(aw[aw.len - 1]);
    const head = words[0 .. words.len - 1];
    for (f.places.steps(p).steps) |st| {
        if (!f.places.rowHolds(row, st)) continue;
        const r = try f.slots.relOfWords(ev.gpa(), ev.account(), ev.places(), try std.mem.concat(ev.arena, u32, &.{ head, &.{st.word()} }));
        const c = (try f.places.extend(ev.gpa(), f.gc(), at, st)) orelse continue;
        const k = f.places.kind(f.places.pathPlace(c));
        _ = try Contract.Draft.addArrival(res, arena, r, .{ .kind = .param, .j = f.roots.items[x.root].a, .slot = try f.slots.relOf(ev.gpa(), ev.account(), ev.places(), c), .deep = k == .@"var" or k == .@"opaque" });
        try Contract.Draft.markOpen(res, arena, r);
    }
    return true;
}
