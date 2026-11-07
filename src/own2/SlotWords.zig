//! L2: the one comparison of two slots' words (`docs/design/ownership-v2.md` §2.1,
//! *The row of a record*), split from `Replay`. A slot is relative steps, and a callee's
//! slot is read at a caller whose record may name more, so `…` and `.b` are unequal
//! words and may be one object. `rules_test` refuses a plain compare of `u32` runs
//! anywhere else in `src/own2/`, so a new reader of two slots cannot fall past a row:
//! it takes `under` or `overlaps`, or says why words will do (`same`, `startsAt`).
//!
//! Obligations kept here: none of §2.14's directly; the row's reading is what
//! §2.1's argument for a row rests on.

const std = @import("std");
const Place = @import("Place.zig");
const StepWord = @import("StepWord.zig");
const WordRun = @import("WordRun.zig");

const Step = Place.Step;

pub const same = WordRun.same;
pub const startsAt = WordRun.startsAt;
pub const endsAt = WordRun.endsAt;
pub const rowThen = StepWord.rowThen;

/// `words` past a leading row step that the next step stands for; the words themselves
/// when no such step leads; null when the row excludes the next step, a true nothing.
pub fn collapse(places: *const Place.Table, words: []const u32) ?[]const u32 {
    if (!rowThen(words)) return words;
    return if (places.rowHolds(Step.fromWord(words[0]), Step.fromWord(words[1]))) words[1..] else null;
}

/// `words` to go on from when a leading row step collapses (empty words for an excluded
/// field, which name nothing); null when no row step collapses here.
pub fn overRow(places: *const Place.Table, words: []const u32) ?[]const u32 {
    return if (rowThen(words)) collapse(places, words) orelse words[words.len..] else null;
}

/// Whether `words` read a field out of a row that excludes it: a true nothing, no fold.
pub fn excluded(places: *const Place.Table, words: []const u32) bool {
    for (0..words.len) |i| if (collapse(places, words[i..]) == null) return true;
    return false;
}

/// Whether a row step is among `words`.
pub fn hasRow(words: []const u32) bool {
    for (words) |w| if (Step.fromWord(w).isRow()) return true;
    return false;
}

/// Whether `words` end at a row step: every object below it is read (§2.1).
pub fn endsInRow(words: []const u32) bool {
    return words.len != 0 and Step.fromWord(words[words.len - 1]).isRow();
}

/// Where two slots' walks stop. `a` or `b` ended (`at_a`, `at_b`), so that one is at or
/// above the other; a row of one holds the other's next step (`row_a`, `row_b`); they part
/// (`apart`). `j` is how far `b` went.
const Meet = struct { how: enum { apart, at_a, at_b, row_a, row_b }, j: usize };

fn meet(places: *const Place.Table, a: []const u32, b: []const u32) Meet {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        const ra = collapse(places, a[i..]) orelse return .{ .how = .apart, .j = j };
        const rb = collapse(places, b[j..]) orelse return .{ .how = .apart, .j = j };
        i = a.len - ra.len;
        j = b.len - rb.len;
        if (i == a.len) return .{ .how = .at_a, .j = j };
        if (j == b.len) return .{ .how = .at_b, .j = j };
        if (a[i] != b[j]) {
            const x, const y = .{ Step.fromWord(a[i]), Step.fromWord(b[j]) };
            if (x.isRow() and places.rowHolds(x, y)) return .{ .how = .row_a, .j = j };
            if (y.isRow() and places.rowHolds(y, x)) return .{ .how = .row_b, .j = j };
            return .{ .how = .apart, .j = j };
        }
        i += 1;
        j += 1;
    }
}

/// How many of a caller's `words` the entry `rw` covers: all of `rw`'s when `words` go on
/// from it; `rw`'s parent's when `rw` is a row that holds their next step, which the row
/// step then stands for (§2.1). Null when `rw` is no entry of them.
pub fn under(places: *const Place.Table, rw: []const u32, words: []const u32) ?usize {
    if (WordRun.startsAt(words, rw)) return rw.len;
    const m = meet(places, rw, words);
    return switch (m.how) {
        .at_a, .row_a => m.j,
        else => null,
    };
}

/// Whether one of two slots is at or below the other, a row read at the other's steps.
pub fn overlaps(places: *const Place.Table, a: []const u32, b: []const u32) bool {
    return meet(places, a, b).how != .apart;
}

/// Whether one of `keys`, each a parameter then a slot's words, is of parameter `j` and
/// overlaps `ws`: a reader's hash of words, read where a row is among them.
pub fn meetsKey(places: *const Place.Table, keys: []const []const u32, j: u32, ws: []const u32) bool {
    for (keys) |k| if (k[0] == j and overlaps(places, k[1..], ws)) return true;
    return false;
}
