//! L6: a `fed` answer through the known codes a code's labels run
//! (`docs/design/ownership-v2.md` §2.11.3, *a label's answer handed back to
//! it*, *a `fed` answer keeps nothing*; #2395). A composition `comp f g = λx a
//! → g x (f x a)` answers what `g` answers, which is what `f` answers: where
//! both are known codes applied at the composition's labels, its answer holds
//! only its argument `k`'s objects or fresh ones when theirs do, label by
//! label, and its run keeps nothing of `k` when none of the codes it hands `k`
//! to keeps anything of what it is handed. `FedCall.at` asks it. `e` is a
//! `Relation.Eval`.
//!
//! Obligations kept here: none of §2.14's directly (`FedCall.at`'s O14).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Replay = @import("Replay.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Place = @import("Place.zig");

/// How many labels deep a composition is read; deeper is `no`.
const max_depth = 8;

/// Argument `k` of a set of arguments (bit `k`), none past 63.
pub fn bit(k: u32) u64 {
    return if (k < 64) @as(u64, 1) << @intCast(k) else 0;
}

/// Whether label `m` of virtual call `vi` is applied to a known code whose
/// answer holds only objects of `vi`'s arguments `ks` or fresh ones: its code
/// answers only what a supply holds that holds nothing else (no object of
/// another argument, no other label's answer but one that does), or fresh.
pub fn answers(e: anytype, vi: u32, m: u32, ks: u64, depth: u32) Ids.ChargeError!bool {
    if (depth > max_depth) return false;
    const vm = e.known.get(.{ vi, m }) orelse return false;
    const lab = e.contracts.labelsOf(e.contracts.head(e.contractOf(vi) orelse return false).labels)[m];
    var fed: u64 = 0;
    var es: Forest.Entries = .{};
    defer es.deinit(e.gpa());
    for (e.contracts.suppliesOf(lab.supplies)) |su| {
        try es.of(&e.contracts.trees, e.gpa(), e.places(), su.res_root, &.{});
        var other = false;
        for (es.items.items) |rs| for (rs.arrivals) |a| switch (a.kind) {
            .param => if (ks & bit(a.j) == 0 and try objectAt(e, vi, a.j, a.slot)) {
                other = true;
            },
            .fresh => {},
            .cb => if (!try answers(e, vi, a.j, ks, depth + 1)) {
                other = true;
            },
            else => other = true,
        };
        if (!other) fed |= bit(su.k);
    }
    return code(e, vm, fed, depth + 1);
}

/// Whether the answer of virtual call `vi` holds only objects of its arguments `ks` or fresh ones, at every
/// slot that holds an object, whatever slots a later run writes: its answer is in its own type's words, which a
/// later label may reshape. A label's answer, at the root, is read by `answers`.
pub fn code(e: anytype, vi: u32, ks: u64, depth: u32) Ids.ChargeError!bool {
    const kh = e.contracts.head(e.contractOf(vi) orelse return false);
    if (kh.flags.pessimistic) return false;
    // Fresh objects only: none of `ks` nor any other (§7.6 item 6).
    if (e.contracts.trees.only(kh.res_root, 2)) return true;
    const root = e.f.roots.items[e.f.calls.items[vi].root].path;
    var es: Forest.Entries = .{};
    defer es.deinit(e.gpa());
    try es.of(&e.contracts.trees, e.gpa(), e.places(), kh.res_root, &.{});
    for (es.items.items) |rs| {
        if (!try holdsAt(e, root, es.wordsOf(rs))) continue;
        for (rs.arrivals) |a| switch (a.kind) {
            .param => if (ks & bit(a.j) == 0 and try objectAt(e, vi, a.j, a.slot)) return false,
            .fresh => {},
            .cb => if (es.wordsOf(rs).len != 0 or !try answers(e, vi, a.j, ks, depth)) return false,
            else => return false,
        };
    }
    return true;
}

/// Whether the run of virtual call `vi` keeps nothing of its arguments `ks`, at any slot: no store or cell
/// write that may hold an object, no escape of them, no label that lets its answer go, and every label handed
/// anything but another argument (a part of `ks`, a fresh object, another label's answer) applied to a known
/// code that keeps nothing of it in turn.
pub fn keepsNone(e: anytype, vi: u32, ks: u64, depth: u32) Ids.ChargeError!bool {
    if (depth > max_depth) return false;
    const h = e.contracts.head(e.contractOf(vi) orelse return false);
    if (h.flags.pessimistic) return false;
    for (e.contracts.storesOf(h.stores)) |s| if (try objectAt(e, vi, s.j, s.slot)) return false;
    var ws: std.ArrayList(Contract.Effect) = .empty;
    defer ws.deinit(e.gpa());
    try e.contracts.writesFlat(e.gpa(), e.gpa(), e.account(), e.f.slots, e.places(), h.writes, &ws);
    for (ws.items) |x| for (e.f.slots.relWords(x.slot)) |w| if (Place.Step.fromWord(w).kind == .contents) {
        if (try objectAt(e, vi, x.j, x.slot)) return false;
    };
    for (e.contracts.effectsOf(h.escapes)) |x| if (ks & bit(x.j) != 0) return false;
    var es: Forest.Entries = .{};
    defer es.deinit(e.gpa());
    for (e.contracts.labelsOf(h.labels), 0..) |l, m| {
        if (l.answer_left) return false;
        var handed: u64 = 0;
        for (e.contracts.suppliesOf(l.supplies)) |su| {
            if (su.k >= 64) return false;
            try es.of(&e.contracts.trees, e.gpa(), e.places(), su.res_root, &.{});
            for (es.items.items) |rs| for (rs.arrivals) |a| switch (a.kind) {
                .param => if (ks & bit(a.j) != 0) {
                    handed |= bit(su.k);
                },
                .shared => {},
                else => handed |= bit(su.k),
            };
        }
        if (handed == 0) continue;
        const vm = e.known.get(.{ vi, @as(u32, @intCast(m)) }) orelse return false;
        if (!try keepsNone(e, vm, handed, depth + 1)) return false;
    }
    return true;
}

/// Whether argument `j` of virtual call `vi` may hold an object at `slot`.
pub fn objectAt(e: anytype, vi: u32, j: u32, slot: Contract.Rel) !bool {
    const x = if (j < e.f.calls.items[vi].args.len) e.f.val(e.f.calls.items[vi].args[j]) else return true;
    return x.kind != .ref or try holdsAt(e, e.f.pos.items[x.pos].slot, e.f.slots.relWords(slot));
}

/// Whether the place `words` below `root` may hold an object.
pub fn holdsAt(e: anytype, root: Ids.PathId, words: []const u32) !bool {
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(e.gpa());
    try Replay.replay(e.gpa(), e.account(), e.places(), root, words, &ps);
    for (ps.items) |p| if (Slots.holdsAny(e.places(), .from(p))) return true;
    return ps.items.len == 0;
}
