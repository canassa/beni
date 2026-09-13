//! `beni dump --stage=interface` (docs/design/checker.md §2, §7): a module's
//! interface as text, so the record the whole firewall rests on has an
//! OUTPUT the black-box suite and the corpus goldens can assert without
//! importing it.
//!
//! ```
//! module Tree
//!   type Node a (2 ctors)
//!     Leaf
//!     Branch/2
//!   opaque type Handle
//!   foreign type Int (equatable)
//!   alias Pair a
//!   value map
//!   foreign value length
//! ```
//!
//! Types first, then values, each already in name order in the record
//! itself — the dump prints the tables as they are, which is what makes a
//! golden here a statement about the record and not about the printer. A
//! constructor's arity follows its name as `/n` and is omitted for a
//! nullary one. M2b adds ` : scheme` after each value and after each
//! constructor's arguments; the layout leaves room for it deliberately.
//!
//! Everything is a name or a small integer: there are no positions and no
//! symbol ids, so the output depends on the source alone and not on
//! `--jobs`.

const std = @import("std");
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");

pub fn write(
    w: *std.Io.Writer,
    module_name: []const u8,
    iface: *const Interface,
    interner: *const InternPool.Global,
) std.Io.Writer.Error!void {
    try w.print("module {s}\n", .{module_name});
    for (iface.types) |t| {
        try w.writeAll("  ");
        if (t.is_opaque) try w.writeAll("opaque ");
        switch (t.kind) {
            .adt => try w.writeAll("type"),
            .alias => try w.writeAll("alias"),
            .foreign => try w.writeAll("foreign type"),
        }
        try w.print(" {s}", .{interner.slice(iface.symbol(t.name))});
        for (0..t.arity) |i| try w.print(" {s}", .{parameterName(i)});
        if (t.is_equatable) try w.writeAll(" (equatable)");
        try w.writeByte('\n');
        for (iface.ctors[t.ctors_start..t.ctors_end]) |c| {
            try w.print("    {s}", .{interner.slice(iface.symbol(c.name))});
            if (c.arity != 0) try w.print("/{d}", .{c.arity});
            try w.writeByte('\n');
        }
    }
    for (iface.values) |v| {
        try w.writeAll("  ");
        if (v.is_foreign) try w.writeAll("foreign ");
        try w.print("value {s}\n", .{interner.slice(iface.symbol(v.name))});
    }
}

/// `a`, `b`, … `z`, then `a1`, `b1`, … — the same naming the type renderer
/// will use (checker.md §8.2), so the two dumps read alike. The interface
/// records an ARITY, not the parameter names the source wrote: a type's
/// identity does not depend on what its parameters were called, and M4
/// hashes this record.
fn parameterName(i: usize) []const u8 {
    const letters = "abcdefghijklmnopqrstuvwxyz";
    // One static row per letter, so this needs no buffer from the caller.
    const names = comptime blk: {
        var out: [letters.len][1]u8 = undefined;
        for (letters, 0..) |c, k| out[k] = .{c};
        break :blk out;
    };
    return &names[i % letters.len];
}
