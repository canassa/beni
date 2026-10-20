//! `beni dump --stage=typekeys` (checker-v2.md §36): the type-key artifact
//! of one module as text — its canonical closed types, the keys it adds to
//! the wild set, each declaration's locals with their keys, and every
//! allocating instruction with its own.
//!
//! ```
//! module Main
//!   key #0 Basics.Int
//!   key #1 { x : #0 }
//!   decl origin
//!     local p #1
//!   inst 4 record #1
//! ```
//!
//! Line-oriented, with no symbol ids and no module indices — a named type is
//! its module's name and its own, a field its text — so `--jobs` cannot move
//! a byte, and a module installed from the cache prints what a fresh check
//! does (the dispatch dump's rule, `dump/dispatch.zig`).

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const TypeKeys = @import("../check/TypeKeys.zig");
const Types = @import("../check/Types.zig");

pub const Error = std.Io.Writer.Error;

pub fn write(
    w: *std.Io.Writer,
    module_name: []const u8,
    bir: *const Bir,
    keys: *const TypeKeys.Artifact,
    types: *const Types,
    interner: *const InternPool.Global,
) Error!void {
    try w.print("module {s}\n", .{module_name});
    // Core, a platform, a module with an error (§36): a keyed module has a
    // key for every local.
    if (keys.locals.len != bir.locals.len) {
        try w.writeAll("  every key wild\n");
        return;
    }
    for (keys.nodes, 0..) |n, i| {
        try w.print("  key #{d} ", .{i});
        const args = keys.args[n.args.start..][0..n.args.len];
        switch (n.kind) {
            .named => {
                if (types.named(@fromBackingInt(@intCast(n.value)))) |named| {
                    try w.print("{s}.{s}", .{ interner.slice(named.module), interner.slice(named.name) });
                } else try w.writeAll("<unknown>");
                for (args) |a| try w.print(" #{d}", .{a.int()});
            },
            .record => {
                if (args.len == 0) {
                    try w.writeAll("{}");
                } else {
                    try w.writeAll("{ ");
                    for (args, keys.labels[n.value..][0..args.len], 0..) |a, label, k| {
                        if (k != 0) try w.writeAll(", ");
                        try w.print("{s} : #{d}", .{ interner.slice(label), a.int() });
                    }
                    try w.writeAll(" }");
                }
            },
            .function => {
                for (args[0 .. args.len - 1], 0..) |a, k| {
                    if (k != 0) try w.writeAll(", ");
                    try w.print("#{d}", .{a.int()});
                }
                if (args.len != 1) try w.writeByte(' ');
                try w.print("→ #{d}", .{args[args.len - 1].int()});
            },
            .tuple => {
                for (args, 0..) |a, k| {
                    if (k != 0) try w.writeAll(" × ");
                    try w.print("#{d}", .{a.int()});
                }
            },
            .unit => try w.writeAll("⊤"),
        }
        try w.writeByte('\n');
    }
    // What the module adds to the wild set.
    for (keys.wild) |k| try w.print("  wild #{d}\n", .{k.int()});
    for (bir.decls) |d| {
        const locals = bir.declLocals(d);
        if (locals.len == 0) continue;
        try w.print("  decl {s}\n", .{interner.slice(bir.symbol(d.name))});
        for (locals, d.locals_start..) |l, li| {
            const name = if (l.name.unwrap()) |s| interner.slice(bir.symbols[s]) else "_";
            try w.print("    local {s} ", .{name});
            try writeKey(w, keys.localKey(@intCast(li)));
            try w.writeByte('\n');
        }
    }
    const tags = bir.insts.items(.tag);
    for (keys.insts) |k| {
        try w.print("  inst {d} {s} ", .{ k.inst.int(), @tagName(tags[k.inst.int()]) });
        try writeKey(w, k.key);
        if (tags[k.inst.int()] == .lambda) {
            try w.writeAll(" result ");
            try writeKey(w, k.result);
        }
        try w.writeByte('\n');
    }
}

fn writeKey(w: *std.Io.Writer, k: TypeKeys.TypeKey) Error!void {
    if (k == .wild) return w.writeAll("wild");
    try w.print("#{d}", .{k.int()});
}
