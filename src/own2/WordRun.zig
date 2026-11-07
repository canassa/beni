//! L0: two runs of words compared as words (`docs/design/ownership-v2.md` §2.1,
//! *The row of a record*): what `SlotWords` offers a reader that has decided a row
//! changes nothing, and `Slots`, which sits below it, needs.
//!
//! Obligations kept here: none of §2.14's (words only).

const std = @import("std");

/// Whether two slots are the same words: an identity (an entry at its own slot), never a
/// question of what one holds of the other. A row read as another word only says "no".
pub fn same(a: []const u32, b: []const u32) bool {
    return std.mem.eql(u32, a, b);
}

/// Whether `words` go on from `prefix`, word by word. For two slots of one frame, whose
/// places are the same; or where a miss only keeps a fact a hit would leave out. Anything
/// that asks whether one slot reaches another takes `SlotWords.under`.
pub fn startsAt(words: []const u32, prefix: []const u32) bool {
    return std.mem.startsWith(u32, words, prefix);
}

/// Whether `words` end in `tail`, word by word. For a tree's own entry and an arrival of
/// that entry, which say one row by one word.
pub fn endsAt(words: []const u32, tail: []const u32) bool {
    return std.mem.endsWith(u32, words, tail);
}
