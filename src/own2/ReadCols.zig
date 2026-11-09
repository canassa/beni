//! L11: the columns of the read-off, split from `ReadOff` (`docs/design/ownership-v2.md`
//! §2.10 *Read-off*): for a read of a value below `from` at result slot `q`, the
//! result slots each slot the read meets reaches (`Dests`).
//!
//! Obligations kept here: none of §2.14's directly (`ReadOff` reads these).

const std = @import("std");
const Ids = @import("Ids.zig");
const Dests = @import("Dests.zig");
const Eval = @import("Eval.zig");

const Error = Eval.Error;
const PathId = Ids.PathId;
const Sink = Eval.Sink;

/// The slots of `domain` entered in the column `d` of the read `(from, q)`,
/// in their order: a path's id is above its parent's, so a slot's ancestors
/// in the domain are entered before it (`Dests.addPath`).
pub fn fill(s: *Sink, from: PathId, q: PathId, domain: []const u32, d: u32) Error!void {
    const gpa = s.e.gpa();
    const xs = try gpa.dupe(u32, domain);
    defer gpa.free(xs);
    std.mem.sort(u32, xs, {}, std.sort.asc(u32));
    for (xs) |x| try add(s, from, q, d, x);
}

fn env(s: *Sink) Dests.Env {
    const f = s.e.fr();
    return .{ .gpa = s.e.gpa(), .account = f.account, .places = f.places, .slots = f.slots };
}

/// `slot`'s entry in the column of the read `(from, q)` (`Dests.addPath`).
pub fn add(s: *Sink, from: PathId, q: PathId, d: u32, slot: u32) Error!void {
    try Dests.addPath(env(s), &s.reads.cols.items[d], from, q, slot);
}

/// The column of the read of a value below `from` at result slot `q`
/// (§2.10 *Read-off*): an entry per slot the read meets, added as it meets
/// it (a leaf's slots, a key's items, one delivered later).
pub fn read(s: *Sink, from: PathId, q: PathId) Error!u32 {
    return s.reads.col(s.e.gpa(), .{ from.int(), q.int() });
}

/// The result slots below `q` that the steps from `from` down to `slot`
/// reach (`Slots.replay`; from `q` itself where `slot` is not below
/// `from`), appended to `out`: from the read's column `col` where it has
/// the slot, else replayed.
pub fn dests(s: *Sink, col: u32, from: PathId, slot: PathId, q: PathId, out: *std.ArrayList(u32)) Error!void {
    if (s.reads.cols.items[col].at(slot.int())) |ds| return out.appendSlice(s.e.gpa(), ds);
    try Dests.replay(env(s), from, slot, q, out);
}
