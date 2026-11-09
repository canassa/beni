//! L11: a supply's row and open entries, written at a caller by the value's structure
//! (`docs/design/ownership-v2.md` §2.1, *An arrival's level*). A reader appends a caller's
//! steps to what an open entry or a row's kid holds, and an arrival's words do not say whether
//! it stands at that level, so the read-off, which has the value, keeps it there. A row at a
//! wider record is each step of the record: every value, not only a parameter's. Each field
//! goes to its own key (`ByStructure`), and the row's own step stays at the entry's word,
//! so a tree has one row kid (`Trees.rowKid`).
//!
//! Obligations kept here: O3 for a row's fields read through a callback: each object the value
//! holds arrives at a key a caller's words reach. An arrival with no record to walk stays at
//! the entry, and at a row's kid the read-off writes it deep and a reader takes it whole.

const std = @import("std");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Value = @import("Value.zig");
const ByStructure = @import("ByStructure.zig");
const SlotWords = @import("SlotWords.zig");

const Error = Relation.Error;
const Step = @import("Place.zig").Step;

pub const Part = ByStructure.Part;
const Plan = ByStructure.Plan;

/// The parts of arrival `a` of a callee's supply entry at `key`, which is `open`.
pub fn plan(ev: *Relation.Eval, q: u32, key: []const u32, open: bool, a: Contract.Arrival, arena: std.mem.Allocator, out: *std.ArrayList(Part)) Error!void {
    const call = ev.f.calls.items[q];
    const p: Plan = .{ .ev = ev, .call = call, .arena = arena, .out = out };
    // A known code's answer is a value too, each of an `alt`'s: written by its structure where its place names one (#2283).
    if (a.kind == .cb and open) if (ev.alts.codes(&ev.known, q, a.j)) |r| {
        for (r[0]..r[0] + r[1]) |vc| try atValue(p, try ev.f.refRoot(ev.f.calls.items[vc].root), ev.f.slots.relWords(a.slot), key, a, false);
        return;
    };
    if (a.kind != .param or a.j >= call.args.len) return out.append(arena, .{ .key = key, .a = a });
    const aw = ev.f.slots.relWords(a.slot);
    if (SlotWords.endsInRow(key) and SlotWords.endsInRow(aw)) return atValue(p, call.args[a.j], aw[0 .. aw.len - 1], key, a, true);
    if (open) return atValue(p, call.args[a.j], aw, key, a, false);
    return out.append(arena, .{ .key = key, .a = a });
}

/// Arrival `a` at `key`, its value `v` at `words`: a choice's arms one by one.
fn atValue(p: Plan, v: u32, words: []const u32, key: []const u32, a: Contract.Arrival, row: bool) Error!void {
    const f = p.ev.f;
    const x = f.val(v);
    if (x.kind == .alt) {
        const ks = f.kidsOf(x);
        var i: usize = 0;
        while (i < ks.len) : (i += 2) try atValue(p, ks[i + 1], words, key, a, row);
        return;
    }
    if (words.len != 0) return atValue(p, try p.ev.valueAt(v, words[0..1]), words[1..], key, a, row);
    if (row) return rowOf(p, v, key, a);
    return ByStructure.write(p, v, key, a);
}

/// A row of `key`, at value `v`: each step of `v`'s record the row holds.
fn rowOf(p: Plan, v: u32, key: []const u32, a: Contract.Arrival) Error!void {
    const f = p.ev.f;
    const at = ByStructure.placeOf(p.ev, v);
    if (at == .none or f.places.kind(at) != .record) return p.out.append(p.arena, .{ .key = key, .a = a });
    const aw = f.slots.relWords(a.slot);
    const row = Step.fromWord(aw[aw.len - 1]);
    const head = key[0 .. key.len - 1];
    const ah = aw[0 .. aw.len - 1];
    for (f.places.steps(at).steps) |st| {
        if (!f.places.rowHolds(row, st)) continue;
        var b = a;
        b.slot = try f.slots.relOfWords(p.ev.gpa(), p.ev.account(), p.ev.places(), try std.mem.concat(p.arena, u32, &.{ ah, &.{st.word()} }));
        // The row's own step stays at this key's word: `Trees.rowKid` reads one row kid.
        if (st.isRow()) {
            const on = try p.ev.valueAt(v, &.{st.word()});
            if (try ByStructure.direct(p, on, key)) continue;
            try p.out.append(p.arena, .{ .key = key, .a = b });
        } else try ByStructure.write(p, try p.ev.valueAt(v, &.{st.word()}), try std.mem.concat(p.arena, u32, &.{ head, &.{st.word()} }), b);
    }
}
