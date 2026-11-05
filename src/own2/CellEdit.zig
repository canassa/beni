//! L8: a write through a cell's contents at an element of a list it holds
//! (`docs/design/ownership-v2.md` §2.11.3, *a taken supply*; §2.13.7).
//!
//! Obligations kept here: none of §2.14's directly (`Outward` refuses).

const std = @import("std");
const Slots = @import("Slots.zig");
const Place = @import("Place.zig");
const Forest = @import("Forest.zig");

const Step = Place.Step;

/// Whether a supply's write at `words` is of a list's element: a parameter's
/// arrival at a `[*]` (a fold's accumulator is not one).
pub fn ofElement(es: *const Forest.Entries, slots: *const Slots.Table, words: []const u32) bool {
    for (es.items.items) |rs| if (std.mem.startsWith(u32, words, es.wordsOf(rs))) for (rs.arrivals) |a| {
        const ws = slots.relWords(a.slot);
        if (a.kind == .param and ws.len != 0 and Step.fromWord(ws[ws.len - 1]).kind == .elem) return true;
    };
    return false;
}

/// Whether a supply's write at `words` lands at an element of a list a cell
/// holds: an arrival through its `◆`, then a `[*]`. v2 keeps no slot state,
/// so nothing it can read says those elements are apart (#1986).
pub fn elementEdit(es: *const Forest.Entries, slots: *const Slots.Table, words: []const u32) bool {
    for (es.items.items) |rs| {
        if (!std.mem.startsWith(u32, words, es.wordsOf(rs))) continue;
        for (rs.arrivals) |a| {
            if (a.kind != .param) continue;
            var seen = false;
            for (slots.relWords(a.slot)) |w| {
                if (seen and Step.fromWord(w).kind == .elem) return true;
                if (Step.fromWord(w).kind == .contents) seen = true;
            }
            if (!seen) continue;
            for (words[rs.len..]) |w| if (Step.fromWord(w).kind == .elem) return true;
        }
    }
    return false;
}
