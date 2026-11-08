//! L5: the arrivals a label's need meets in the code a caller hands
//! (`docs/design/ownership-v2.md` §2.11.3, *a need*), split from `Needs`. A need is
//! sound only on a complete read, so every entry of the result is compared, and a
//! read that cannot be complete says so.
//!
//! Obligations kept here: O14's need half (every arrival at the need is found).

const std = @import("std");
const Ids = @import("Ids.zig");
const Forest = @import("Forest.zig");
const Contract = @import("Contract.zig");
const SlotWords = @import("SlotWords.zig");
const PastPayload = @import("PastPayload.zig");

const Error = Ids.ChargeError;

/// An arrival of a result, with the words below it the need goes on to; `whole`:
/// read all of it, deep, at no words (§2.1, *The exit rule*).
pub const At = struct { a: Contract.Arrival, rest: []const u32, whole: bool = false };

/// The arrivals of a result at `words`, and below them when `deep`: `m`'s draft as it
/// stands (`res`), else contract `c`. Every entry of the result is read and compared by
/// `SlotWords`, as `instAt` and `instBelow` read it, so a row is read at the caller's
/// step (§2.1). Where `words` from `root` stand at or run past a payload, every entry
/// that meets them is read whole (§2.1, *An arrival's level*). None is no proof, as a
/// write with no target is none in the caller (`Resolve`): false, refused (§2.11.3).
pub fn of(e: anytype, res: ?*const Contract.Draft.Res, c: Contract.Id, root: Ids.PlaceId, words: []const u32, deep: bool, out: *std.ArrayList(At)) Error!bool {
    const f = e.fr();
    const whole = PastPayload.reaches(f.places, root, words);
    var es: Forest.Entries = .{};
    defer es.deinit(e.gpa());
    if (res == null) {
        try es.of(&e.contracts.trees, e.gpa(), f.places, e.contracts.head(c).res_root, &.{});
        for (es.items.items) |y| try pick(e, es.wordsOf(y), y.open, y.arrivals, words, deep, whole, out);
        return out.items.len != 0;
    }
    const r = res.?;
    try es.of(&e.contracts.trees, e.gpa(), f.places, r.base, &.{});
    for (es.items.items) |y| try pick(e, es.wordsOf(y), y.open, y.arrivals, words, deep, whole, out);
    for (r.items.items) |it| {
        const sw = f.slots.relWords(it.slot);
        if (it.node == 0) {
            try pick(e, sw, r.isOpen(it), &.{it.a}, words, deep, whole, out);
            continue;
        }
        try es.of(&e.contracts.trees, e.gpa(), f.places, it.node, sw);
        for (es.items.items) |y| try pick(e, es.wordsOf(y), y.open, y.arrivals, words, deep, whole, out);
    }
    return out.items.len != 0;
}

/// The arrivals of one entry at `rw` that a need at `words` meets. At or above them by
/// `SlotWords.under`: an exact or open entry, with the words below it, or a row that
/// holds their next step, which the row step stands for. Below them, when `deep`.
fn pick(e: anytype, rw: []const u32, open: bool, arrs: []const Contract.Arrival, words: []const u32, deep: bool, whole: bool, out: *std.ArrayList(At)) Error!void {
    const f = e.fr();
    const a = e.ev.arena;
    try e.ev.charge(.inspection, 1);
    if (SlotWords.under(f.places, rw, words)) |n| {
        for (arrs) |x| {
            // A row's kid whose level nothing says is read whole, and so deep (§2.1, *An arrival's level*).
            const w = whole or (n < rw.len and SlotWords.endsInRow(rw) and Forest.wholeAtRow(f.slots, x));
            const at = if (n < rw.len) n else if (rw.len == words.len or open or whole) rw.len else continue;
            try out.append(a, .{ .a = x, .rest = if (w) &.{} else try a.dupe(u32, words[at..]), .whole = w });
        }
    } else if ((deep or whole) and SlotWords.startsAt(rw, words)) {
        for (arrs) |x| try out.append(a, .{ .a = x, .rest = &.{}, .whole = whole });
    }
}
