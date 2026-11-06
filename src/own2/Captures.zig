//! L8: a closure's captures as part of what holds it (`docs/design/ownership-v2.md`
//! §2.10 *Read-off*, #1772). No place below a function type names a capture,
//! so a callee's result arrival at an argument closure (`Task.keepLogContext`
//! answers what it was handed) takes the closure's captures too, deep: a
//! result that is held, or escapes, holds or lets go of what the closure
//! reads. `Eval` adds them to every parameter arrival (`Relation.Eval.routed`).
//!
//! Obligations kept here: O1's closure half (a value that holds a closure
//! holds what the closure can reach).

const std = @import("std");
const SlotWords = @import("SlotWords.zig");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;

/// After an arrival's own leaves at `words` of argument `v` (not `deep`):
/// the captures of each closure built there, each deep.
pub fn add(e: *Relation.Eval, v: u32, words: []const u32, deep: bool, out: *std.ArrayList(u32)) Error!void {
    if (deep) return;
    var found: std.ArrayList(u32) = .empty;
    defer found.deinit(e.gpa());
    try builtClosures(e, v, words, &found);
    for (found.items) |x| for (try e.arena.dupe(u32, e.f.kidsOf(e.f.val(x)))) |c| try e.routed(e, c, &.{}, true, Ids.none_int, out);
}

/// The closures built at `words` below value `v`, followed through built
/// values only (nothing is made): a reference's captures are its caller's.
fn builtClosures(e: *Relation.Eval, v: u32, words: []const u32, out: *std.ArrayList(u32)) Error!void {
    try e.charge(.inspection, 1);
    const f, const x = .{ e.f, e.f.val(v) };
    const ks = f.kidsOf(x);
    if (x.kind == .alt) {
        var n: usize = 1;
        while (n < ks.len) : (n += 2) try builtClosures(e, ks[n], words, out);
        return;
    }
    if (x.kind != .built) return;
    if (words.len == 0) return if (x.form == .closure) out.append(e.gpa(), v);
    const st = Place.Step.fromWord(words[0]);
    const ca = if (st.kind == .ctor_arg) f.places.ctorArgOf(st) else .{ 0, 0 };
    switch (x.form) {
        .tuple => if (st.kind == .index and st.payload < ks.len) try builtClosures(e, ks[st.payload], words[1..], out),
        .ctor => if (st.kind == .ctor_arg and ca[0] == x.head and ca[1] < ks.len) try builtClosures(e, ks[ca[1]], words[1..], out),
        .record => if (SlotWords.overRow(f.places, words)) |rest| try builtClosures(e, v, rest, out) else for (f.wordsOf(x.extra), 0..) |r, n| {
            if (try Value.RecordKid.holds(f, st, r)) try builtClosures(e, ks[n], words[1..], out);
        },
        .list => if (st.kind == .elem) for (ks) |k| try builtClosures(e, k, words[1..], out),
        else => {},
    }
}
