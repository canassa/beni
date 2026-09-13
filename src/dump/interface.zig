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
//! nullary one.
//!
//! M2b fills in ` : scheme` after each value, rendered by `check/Render.zig`
//! — the same renderer every diagnostic uses, so these goldens test the
//! type text of every message too (checker.md §8.2). A scheme is printed by
//! instantiating it into a throwaway store: the interface stores terms
//! precisely so it can outlive the store it came from, and the renderer
//! reads store variables, so one of the two has to give. A run that
//! resolved names but did not check (the hermetic tests of `Interface`)
//! has no schemes and prints the names alone, which is M2a's output
//! unchanged. A declaration that failed to check prints `<error>`.
//!
//! Everything is a name or a small integer: there are no positions and no
//! symbol ids, so the output depends on the source alone and not on
//! `--jobs`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");
const Render = @import("../check/Render.zig");
const Schemes = @import("../check/Schemes.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");

pub const Error = std.Io.Writer.Error || Allocator.Error;

pub fn write(
    w: *std.Io.Writer,
    gpa: Allocator,
    module_name: []const u8,
    iface: *const Interface,
    types: *const Types,
    interner: *const InternPool.Global,
) Error!void {
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
    for (iface.values, 0..) |v, i| {
        try w.writeAll("  ");
        if (v.is_foreign) try w.writeAll("foreign ");
        try w.print("value {s}", .{interner.slice(iface.symbol(v.name))});
        if (v.scheme != .none) {
            try w.writeAll(" : ");
            try writeScheme(w, gpa, iface, @enumFromInt(i), types, interner);
        }
        try w.writeByte('\n');
    }
}

/// One value's scheme. The throwaway store and arena are per value: a
/// scheme is a handful of nodes, this runs once per `pub` name, and a
/// store per call is what keeps the two instantiations of `a -> a` in two
/// different values from sharing a variable and printing as one.
fn writeScheme(
    w: *std.Io.Writer,
    gpa: Allocator,
    iface: *const Interface,
    value: Interface.ValueIndex,
    types: *const Types,
    interner: *const InternPool.Global,
) Error!void {
    const scheme = iface.valueScheme(value) orelse return w.writeAll("<error>");
    if (iface.term(scheme.body).tag == .err) return w.writeAll("<error>");
    var store: TypeStore = .init(gpa);
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try Schemes.instantiate(
        iface,
        &store,
        @intFromEnum(iface.values[@intFromEnum(value)].scheme),
        TypeStore.generalized,
        arena.allocator(),
    );
    var namer: Render.Namer = .init(gpa);
    defer namer.deinit();
    try Render.writeScheme(w, .{ .store = &store, .types = types, .interner = interner }, &namer, v);
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
