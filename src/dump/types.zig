//! `beni dump --stage=types` (docs/design/checker.md §2, §8.2): every
//! top-level declaration of a module with its inferred scheme, and every
//! local binding with its type.
//!
//! ```
//! module Main
//!   greet : String -> String
//!     name : String
//!   total : List number -> number
//!     xs : List number
//!     step : number -> number -> number
//! ```
//!
//! It exists so the checker has an OUTPUT the black-box suite can assert
//! without importing it, and because the types it prints come out of
//! `check/Render.zig` — the same renderer every diagnostic uses — so a
//! golden here is a test of the prose in every message as well.
//!
//! Declarations are in source order, locals in binding order within their
//! declaration, and a local the compiler made for a desugaring prints as
//! `_`. There are no positions and no symbol ids, so reformatting the input
//! leaves a golden untouched and `--jobs` cannot move a byte.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Check = @import("../check/Check.zig");
const Render = @import("../check/Render.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");

pub const Error = std.Io.Writer.Error || Allocator.Error;

pub fn write(
    w: *std.Io.Writer,
    gpa: Allocator,
    module_name: []const u8,
    bir: *const Bir,
    module: *Check.Module,
    types: *const Types,
    interner: *const InternPool.Global,
) Error!void {
    try w.print("module {s}\n", .{module_name});
    const cx: Render.Context = .{ .store = &module.store, .types = types, .interner = interner };
    for (bir.decls, 0..) |d, i| {
        if (!d.kind.isValue()) continue;
        // One namer per declaration, so `a` means the same variable in a
        // scheme and in the locals under it, and a different one in the
        // next declaration — exactly the per-diagnostic rule of §8.2.
        var namer: Render.Namer = .init(gpa);
        defer namer.deinit();
        try w.print("  {s} : ", .{interner.slice(bir.symbol(d.name))});
        if (module.decl_display[i].unwrap()) |v| {
            try Render.writeScheme(w, cx, &namer, v);
        } else {
            try w.writeAll("<error>");
        }
        try w.writeByte('\n');
        for (bir.declLocals(d), d.locals_start..) |l, li| {
            const name = if (l.name.unwrap()) |s| interner.slice(bir.symbols[s]) else "_";
            try w.print("    {s} : ", .{name});
            if (module.local_type[li].unwrap()) |v| {
                try Render.writeVar(w, cx, &namer, v, .top);
            } else {
                try w.writeAll("<error>");
            }
            try w.writeByte('\n');
        }
    }
}
