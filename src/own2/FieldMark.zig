//! L3: the mark of a field read in an effect tree
//! (`docs/design/ownership-v2.md` §2.10, *Effects as trees*, *a read's
//! fields*; §2.8, *Dead, by field*). A read node at a record's slot holds,
//! in its plain run, either the one mark (`Forest.mark`: the record whole)
//! or a mark for each field read.
//!
//! Obligations kept here: none of §2.14's directly (`FieldReads`' O7).

const std = @import("std");
const Place = @import("Place.zig");
const Trees = @import("Trees.zig");

const Arrival = Trees.Arrival;
const Node = Trees.Node;

/// The mark of a read of one field of the record at an effect node (§2.10, *Effects as trees*): `field` is
/// that field's one-step slot. It names no parameter and no place, so a node grafted at another slot keeps it.
pub fn of(field: u32) Arrival {
    return .{ .kind = .param, .slot = field };
}

/// Whether read tree `n0` reads, of the record at `words` below its root, a field of `fields` (ranks, sorted;
/// none: every field): a deep read at or above the record, a read of it whole (the plain mark), the mark of
/// such a field, or a read below such a field's step. A step that is no field's (a row) reads any of them.
pub fn reads(t: *const Trees.Table, places: *const Place.Table, slots: anytype, n0: Node, words: []const u32, fields: []const u32) bool {
    var n = n0;
    for (words) |w| {
        if (t.open(n).len != 0) return true;
        n = t.kidAt(n, w) orelse return t.rowReaches(places, n, w);
    }
    if (t.open(n).len != 0) return true;
    for (t.here(n)) |a| if (a.kind != .param or among(fields, Place.Step.fromWord(slots.relWords(a.slot)[0]))) return true;
    for (t.kids(n)) |k| if (t.count(k[1]) != 0 and among(fields, Place.Step.fromWord(k[0]))) return true;
    return false;
}

fn among(fields: []const u32, st: Place.Step) bool {
    return st.kind != .field or fields.len == 0 or std.mem.indexOfScalar(u32, fields, st.payload) != null;
}

/// The fields that write tree `n0` names at the record `words` below its root: the marks' ranks, in `arena`.
/// None, which is every field: the plain mark is there, no mark is, or the walk leaves the tree.
pub fn written(t: *const Trees.Table, slots: anytype, arena: std.mem.Allocator, n0: Node, words: []const u32) std.mem.Allocator.Error![]const u32 {
    var n = n0;
    for (words) |w| n = t.kidAt(n, w) orelse return &.{};
    const run = t.here(n);
    for (run) |a| if (a.kind != .param) return &.{};
    const out = try arena.alloc(u32, run.len);
    for (run, out) |a, *r| r.* = Place.Step.fromWord(slots.relWords(a.slot)[0]).payload;
    std.mem.sort(u32, out, {}, std.sort.asc(u32));
    return out;
}
