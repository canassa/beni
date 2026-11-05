//! L13: a refused loan's text (`docs/design/ownership-v2.md` §2.13.7,
//! *Copy depth and diagnostics*): the loan, the cell it came from, and a
//! fix as deep as the write. `List.copy` copies one level, so an edit below
//! a list's elements needs each level copied down to the list it changes.
//!
//! Obligations kept here: none (text).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

/// How many list levels the written path `p` steps below its root.
pub fn depth(places: *const Place.Table, p: Ids.PathId) u32 {
    var n: u32 = 0;
    var at = p;
    while (at != .none and places.pathParent(at) != .none) : (at = places.pathParent(at)) {
        if (places.pathStep(at).kind == .elem) n += 1;
    }
    return n;
}

/// The text after `loan: `: `op` read the value out of `cell` ("" when the
/// cell has no name to print, or a call's). `deep`: the write is `deep` list levels below it.
pub fn write(w: *std.Io.Writer, op: []const u8, cell: []const u8, deep: u32) std.Io.Writer.Error!void {
    if (cell.len != 0 and cell[0] != '<') {
        try w.print("`{s}` lent it, and `{s}` still holds it. ", .{ op, cell });
    } else try w.print("`{s}` lent it, and the cell still holds it. ", .{op});
    if (deep == 0) return w.writeAll("Change a copy (`List.copy`)");
    try w.writeAll("`List.copy` copies only the outer list, and the lists inside are still the cell's. Copy each level, down to the list you change");
    if (deep == 1) try w.writeAll(" (`List.map xs List.copy`)");
}
