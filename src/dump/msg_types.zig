//! `beni dump --stage=writes --msg-types` (browser-direct.md §8.3, amended
//! 2026-10-09): every program's **message type, as the checker records
//! it**, for the page fuzzer (`tests/browser/fuzz.mjs`) to generate values
//! of. Hidden and test-only, as `--writes-work` is.
//!
//! One JSON object per program, one per line, in the order `--stage=writes`
//! prints the programs:
//!
//! ```
//! {"program":"Main.main","index":null,"kind":"Tea.sandbox","msg":[["n",0],[{"Inc":[],"Add":["i"]}]]}
//! ```
//!
//! `msg` is the type `Debug.toString` would be handed for a value of it
//! (backend.md §4, *`Debug.toString` reads the argument's type*): the same
//! descriptor, `[root, defs]`, written by the same code from the checker's
//! type of `update`'s first parameter — a declaration's scheme, or a
//! lambda's parameter — so a constructor is generated whatever the
//! write-set pass's key tree made of it. `kind` is null, and `msg` too, for
//! a program the pass does not recognise; `msg` is also null when `update`
//! is neither a top-level declaration nor a lambda whose first parameter is
//! a name. The fuzzer then sends that program no value messages.
//!
//! What the fuzzer shares with the lowering is the program's recognition
//! (which field is `update`) and the session's type table; neither is the
//! key tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writes = @import("../writes/Writes.zig");
const Check = @import("../check/Check.zig");
const CheckShape = @import("../check/DebugShape.zig");
const JsShape = @import("../js/DebugShape.zig");
const Walk = @import("../check/Walk.zig");

pub const Error = std.Io.Writer.Error || Allocator.Error;

/// What reading the named types' declarations needs (`js/DebugShape.zig`).
pub const Context = JsShape.Context;

pub fn write(
    w: *std.Io.Writer,
    gpa: Allocator,
    a: *const Writes,
    run: Writes.Run,
    modules: []Check.Module,
    cx: *const JsShape.Context,
) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (run.programs) |*prog| {
        try w.print("{{\"program\":\"{s}.{s}\",\"index\":", .{ a.moduleName(prog.module), a.declNameOf(prog.module, prog.decl) });
        if (prog.index) |i| try w.print("{d}", .{i}) else try w.writeAll("null");
        try w.writeAll(",\"kind\":");
        if (prog.recognised) try w.print("\"{s}\"", .{Writes.programKindName(prog.kind)}) else try w.writeAll("null");
        try w.writeAll(",\"msg\":");
        const text = try messageType(arena, gpa, prog, modules, cx);
        try w.writeAll(text orelse "null");
        try w.writeAll("}\n");
    }
}

/// The descriptor of `prog`'s `update`'s first parameter, or null.
fn messageType(arena: Allocator, gpa: Allocator, prog: *const Writes.Program, modules: []Check.Module, cx: *const JsShape.Context) Allocator.Error!?[]const u8 {
    if (!prog.recognised or prog.update_module == Writes.none) return null;
    if (prog.update_module >= modules.len) return null;
    const module = &modules[prog.update_module];
    // A lambda's first parameter's type, or a declaration's scheme's.
    const msg = if (prog.update_param_local != Writes.none) blk: {
        if (prog.update_param_local >= module.local_type.len) return null;
        break :blk module.local_type[prog.update_param_local].unwrap() orelse return null;
    } else blk: {
        if (prog.update_decl >= module.decl_scheme.len) return null;
        const scheme = module.decl_scheme[prog.update_decl].unwrap() orelse return null;
        const func = Walk.function(&module.store, scheme) orelse return null;
        if (func.params.len == 0) return null;
        break :blk func.params[0];
    };
    const nodes = try CheckShape.shape(gpa, &module.store, cx.interner, msg);
    defer gpa.free(nodes);
    return try JsShape.text(arena, cx, nodes);
}
