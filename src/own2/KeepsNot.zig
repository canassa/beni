//! L6: whether a known code keeps nothing of what a label hands it
//! (`docs/design/ownership-v2.md` §2.11.3, *a need on a supply*). A frame that
//! edits what it handed a label publishes the need; where the label's code is
//! known, this decides it, and a label of that code handed the same object
//! carries it on (`sink`). `RunKeeps` asks the same of a fold's run.
//!
//! Obligations kept here: O14's need half (what a known code keeps of a
//! supply: its stores, its cell writes, its escapes, its labels).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Replay = @import("Replay.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const Place = @import("Place.zig");
const SlotWords = @import("SlotWords.zig");

const Error = Ids.ChargeError;

/// Whether code `c`, run at virtual call `vi`, keeps nothing of its argument `k` at `at` (and below
/// it when `deep`): no store or cell write that may hold an object, no label that lets its answer go,
/// no escape of `k` at or above `at` (or below it, when deep). A label of the code handed `k` there
/// carries the need on (`handed`). `e` is a `Relation.Eval`; `sink.on(cb, k)` takes a need that passes on.
pub fn nothing(e: anytype, c: Contract.Id, vi: u32, k: u32, at: []const u32, deep: bool, sink: anytype) Error!bool {
    const h = e.contracts.head(c);
    if (h.flags.pessimistic or !try cellsHoldNothing(e, vi, h)) return false;
    // An escape at a slot that holds no object at this call (`List Int`'s elements) keeps nothing.
    for (e.contracts.effectsOf(h.escapes)) |x| if (x.j == k and meets(e.places(), e.f.slots.relWords(x.slot), at, deep) and try objectAt(e, vi, k, x.slot)) return false;
    var es: Forest.Entries = .{};
    defer es.deinit(e.gpa());
    for (e.contracts.labelsOf(h.labels), 0..) |l, li| {
        if (l.answer_left) return false;
        for (e.contracts.suppliesOf(l.supplies)) |su| {
            try es.of(&e.contracts.trees, e.gpa(), e.places(), su.res_root, &.{});
            var hit = false;
            for (es.items.items) |rs| for (rs.arrivals) |a| {
                hit = hit or a.kind == .param and a.j == k and meets(e.places(), e.f.slots.relWords(a.slot), at, deep);
            };
            if (hit and !try handed(e, vi, @intCast(li), su.k, sink)) return false;
        }
    }
    return true;
}

/// Label `li` of virtual call `vi` is handed what a need covers as its argument `k`: it passes on to
/// the frame's label (`sink`), or its known code keeps nothing of it; unknown code may keep it.
pub fn handed(e: anytype, vi: u32, li: u32, k: u32, sink: anytype) Error!bool {
    if (e.label_map.get(.{ vi, li })) |cb| {
        try sink.on(cb, k);
        return true;
    }
    const v = e.known.get(.{ vi, li }) orelse return false;
    return nothing(e, e.contractOf(v) orelse return false, v, k, &.{}, true, sink);
}

/// No store and no write of a cell's `◆` that may hold an object.
pub fn cellsHoldNothing(e: anytype, vi: u32, h: Contract.Head) Error!bool {
    for (e.contracts.storesOf(h.stores)) |s| if (try objectAt(e, vi, s.j, s.slot)) return false;
    var ws: std.ArrayList(Contract.Effect) = .empty;
    defer ws.deinit(e.gpa());
    try e.contracts.writesFlat(e.gpa(), e.gpa(), e.account(), e.f.slots, e.places(), h.writes, &ws);
    for (ws.items) |x| for (e.f.slots.relWords(x.slot)) |w| if (Place.Step.fromWord(w).kind == .contents) {
        if (try objectAt(e, vi, x.j, x.slot)) return false;
    };
    return true;
}

/// Whether label `li` of call `call` is handed its own answer back as its argument `k` (a fold's accumulator).
pub fn selfFed(e: anytype, call: u32, li: u32, k: u32) Error!bool {
    const c = e.contractOf(call) orelse return false;
    const labs = e.contracts.labelsOf(e.contracts.head(c).labels);
    if (li >= labs.len) return false;
    var es: Forest.Entries = .{};
    defer es.deinit(e.gpa());
    for (e.contracts.suppliesOf(labs[li].supplies)) |su| if (su.k == k) {
        try es.of(&e.contracts.trees, e.gpa(), e.places(), su.res_root, &.{});
        for (es.items.items) |rs| for (rs.arrivals) |a| if (a.kind == .cb and a.j == li) return true;
    };
    return false;
}

/// Whether a slot `w` of an argument keeps what a need at `at` covers: at or above it, or below it when deep.
pub fn meets(places: *const Place.Table, w: []const u32, at: []const u32, deep: bool) bool {
    return SlotWords.under(places, w, at) != null or (deep and SlotWords.under(places, at, w) != null);
}

/// A sink that takes nothing: the caller publishes the same needs elsewhere.
pub const none_sink: struct {
    pub fn on(_: @This(), _: u32, _: u32) Error!void {}
} = .{};

/// Whether argument `j` of virtual call `vi` may hold an object at `slot`.
fn objectAt(e: anytype, vi: u32, j: u32, slot: Contract.Rel) Error!bool {
    const x = if (j < e.f.calls.items[vi].args.len) e.f.val(e.f.calls.items[vi].args[j]) else return true;
    return x.kind != .ref or try holdsAt(e, e.f.pos.items[x.pos].slot, e.f.slots.relWords(slot));
}

/// Whether the place `words` below `root` may hold an object.
pub fn holdsAt(e: anytype, root: Ids.PathId, words: []const u32) Error!bool {
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(e.gpa());
    try Replay.replay(e.gpa(), e.account(), e.places(), root, words, &ps);
    for (ps.items) |p| if (Slots.holdsAny(e.places(), .from(p))) return true;
    return ps.items.len == 0;
}
