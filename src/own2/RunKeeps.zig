//! L7: whether a known code's run keeps nothing a later run writes
//! (`docs/design/ownership-v2.md` §2.11.3, *a `fed` answer keeps nothing*):
//! a fold's callback is handed an earlier run's answer, so what a run keeps
//! of it a later run may edit in place. `FedCall.at` asks it.
//!
//! Obligations kept here: none of §2.14's directly (`FedCall.at`'s O14).

const std = @import("std");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Place = @import("Place.zig");
const SlotWords = @import("SlotWords.zig");
const FedThrough = @import("FedThrough.zig");

/// Whether the code of virtual call `vi` keeps nothing of its argument `k` a later run writes: no store or cell
/// write that may hold an object, no label that lets its answer go (a label's code may keep what it is handed),
/// no escape of `k` or label handed `k` that `reaches` a write, and no label handed an object not a parameter's
/// where the answer holds one at a written slot. `e` is a `Relation.Eval`.
pub fn nothing(e: anytype, vi: u32, k: u32) !bool {
    if (@import("Mutate.zig").on(.self_fed_keeps_ok)) return true;
    const h = e.contracts.head(e.contractOf(vi) orelse return false);
    for (e.contracts.storesOf(h.stores)) |s| if (try objectAt(e, vi, s.j, s.slot)) return false;
    var ws: std.ArrayList(Contract.Effect) = .empty;
    defer ws.deinit(e.gpa());
    try e.contracts.writesFlat(e.gpa(), e.gpa(), e.account(), e.f.slots, e.places(), h.writes, &ws);
    for (ws.items) |x| for (e.f.slots.relWords(x.slot)) |w| if (Place.Step.fromWord(w).kind == .contents) {
        if (try objectAt(e, vi, x.j, x.slot)) return false;
    };
    for (e.contracts.effectsOf(h.escapes)) |x| if (x.j == k and reaches(e, ws.items, k, e.f.slots.relWords(x.slot))) return false;
    var es: Forest.Entries = .{};
    defer es.deinit(e.gpa());
    try es.of(&e.contracts.trees, e.gpa(), e.places(), h.res_root, &.{});
    var other = false;
    for (es.items.items) |rs| for (rs.arrivals) |a| if (a.kind != .param and a.kind != .shared and reaches(e, ws.items, k, es.wordsOf(rs))) {
        other = true;
    };
    for (e.contracts.labelsOf(h.labels)) |l| {
        if (l.answer_left) return false;
        for (e.contracts.suppliesOf(l.supplies)) |su| {
            try es.of(&e.contracts.trees, e.gpa(), e.places(), su.res_root, &.{});
            for (es.items.items) |rs| for (rs.arrivals) |a| switch (a.kind) {
                .param => if (a.j == k and reaches(e, ws.items, k, e.f.slots.relWords(a.slot))) return false,
                .shared => {},
                else => if (other) return false,
            };
        }
    }
    return true;
}

/// Whether `k` at `at` is at or above a slot of `k` written, or below one written open.
fn reaches(e: anytype, ws: []const Contract.Effect, k: u32, at: []const u32) bool {
    for (ws) |w| if (w.j == k) {
        const ww = e.f.slots.relWords(w.slot);
        if (SlotWords.under(e.places(), at, ww) != null or w.deep and SlotWords.under(e.places(), ww, at) != null) return true;
    };
    return false;
}

const objectAt = FedThrough.objectAt;
/// Whether the place `words` below `root` may hold an object.
pub const holdsAt = FedThrough.holdsAt;
