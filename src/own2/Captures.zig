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
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;

/// After an arrival's own leaves at `words` of argument `v` (not `deep`):
/// the captures of a closure built there, each deep.
pub fn add(e: *Relation.Eval, v: u32, words: []const u32, deep: bool, out: *std.ArrayList(u32)) Error!void {
    if (deep) return;
    const x = builtClosureAt(e.f, v, words) orelse return;
    const caps = try e.arena.dupe(u32, e.f.kidsOf(x));
    for (caps) |c| try e.routed(e, c, &.{}, true, Ids.none_int, out);
}

/// The closure built at `words` below value `v0`, followed through built
/// values only (nothing is made): a reference's captures are its caller's.
fn builtClosureAt(f: *Value.Frame, v0: u32, words: []const u32) ?Value.Val {
    var x = f.val(v0);
    for (words) |wd| {
        if (x.kind != .built) return null;
        const st = Place.Step.fromWord(wd);
        const ks = f.kidsOf(x);
        const ca = if (st.kind == .ctor_arg) f.places.ctorArgOf(st) else .{ 0, 0 };
        const next: ?u32 = switch (x.form) {
            .tuple => if (st.kind == .index and st.payload < ks.len) ks[st.payload] else null,
            .ctor => if (st.kind == .ctor_arg and ca[0] == x.head and ca[1] < ks.len) ks[ca[1]] else null,
            .record => for (f.wordsOf(x.extra), 0..) |r, n| {
                if (st.kind == .field and r == st.payload) break ks[n];
            } else null,
            .list => if (st.kind == .elem and ks.len == 1) ks[0] else null,
            else => null,
        };
        x = f.val(next orelse return null);
    }
    return if (x.kind == .built and x.form == .closure) x else null;
}
