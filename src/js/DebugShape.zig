//! `backend.md` §4, *`Debug.toString` reads the argument's type*: a debug
//! row's type (checker-v2.md §32) as the descriptor the printer in
//! `core/Debug.beni` reads — one JSON text, `[root, defs]`.
//!
//! A type is written as:
//!
//!   - `"i"` an `Int` or `Int32`, `"f"` a `Float`, `"s"` a `String`,
//!     `"c"` a `Char`, `"b"` a `Bool`, `"u"` `()`, `"F"` a function, `"x"`
//!     a `foreign type` the printer cannot look inside, `"?"` unknown — a
//!     type variable, a schema endpoint, or anything this file does not
//!     know — which the printer reads by representation;
//!   - `["t", a, b, …]` a tuple, `["l", a]` a `List`, `["D", k, v]` a
//!     `Dict`, `["S", a]` a `Set`;
//!   - `{"x": a, …}` a record, by field name;
//!   - `["n", k, a, …]` a `type` applied to its arguments, `k` indexing
//!     `defs`;
//!   - a number `k`, inside a definition only: that type's `k`th parameter.
//!
//! `defs[k]` is one `type`'s constructors, `{"Tag": [arg, …], …}`, written
//! once per row in first-use order however often the type recurs, so a
//! recursive type is a finite text. An alias is written as its expansion.
//!
//! The checker sends the row's root; every named type's body is read here
//! from its declaration in `Bir`, as `Fields.close` reads a boundary type's,
//! so a module's cached row does not go stale when the declaring module's
//! private constructors change. Keyed by `TypeId` and written by
//! declaration order and first use, the text depends on nothing a thread
//! can move (CLAUDE.md rule 5).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Types = @import("../check/Types.zig");

const TypeId = Types.TypeId;

/// What reading another module's declarations needs: read-only, so every
/// lowering worker may share one.
pub const Context = struct {
    /// One per module, by `Graph.Index`.
    birs: []const *const Bir,
    types: *const Types,
    interner: *const InternPool.Global,
};

/// How deep a written type (a constructor's argument, an alias body) is
/// read before the rest of it is `"?"`. Source nesting, so a backstop.
const max_depth: u32 = 256;

/// The descriptor of `nodes`, a row's pre-order type, allocated in `arena`.
pub fn text(arena: Allocator, cx: *const Context, nodes: []const Dispatch.DebugNode) Allocator.Error![]const u8 {
    var w: Writer = .{ .arena = arena, .cx = cx };
    try w.out.append(arena, '[');
    try w.root(nodes);
    try w.out.appendSlice(arena, ",[");
    // Each definition may name types not yet defined: the list grows while
    // it is written.
    var k: usize = 0;
    while (k < w.defs.items.len) : (k += 1) {
        if (k != 0) try w.out.append(arena, ',');
        try w.definition(w.defs.items[k]);
    }
    try w.out.appendSlice(arena, "]]");
    return w.out.items;
}

/// What a named type is written as.
const Head = union(enum) {
    code: []const u8,
    /// `["l"`, `["D"`, `["S"`: written with its arguments.
    builtin: []const u8,
    adt: TypeId,
    alias: TypeId,
};

const Writer = struct {
    arena: Allocator,
    cx: *const Context,
    out: std.ArrayList(u8) = .empty,
    defs: std.ArrayList(TypeId) = .empty,

    fn head(w: *Writer, id: TypeId) Head {
        const types = w.cx.types;
        const wk = types.well_known;
        if (id == .none or id.int() >= types.entries.len) return .{ .code = "\"?\"" };
        if (id == wk.int) return .{ .code = "\"i\"" };
        if (id == wk.float) return .{ .code = "\"f\"" };
        if (id == wk.string) return .{ .code = "\"s\"" };
        if (id == wk.char) return .{ .code = "\"c\"" };
        if (id == wk.bool) return .{ .code = "\"b\"" };
        if (id == wk.list) return .{ .builtin = "[\"l\"" };
        const e = types.entries[id.int()];
        if (e.schema_endpoint) return .{ .code = "\"?\"" };
        if (e.package == .core) {
            const module = w.cx.interner.slice(e.module_name);
            const name = w.cx.interner.slice(e.name);
            if (std.mem.eql(u8, module, "Dict") and std.mem.eql(u8, name, "Dict")) return .{ .builtin = "[\"D\"" };
            if (std.mem.eql(u8, module, "Set") and std.mem.eql(u8, name, "Set")) return .{ .builtin = "[\"S\"" };
            // A number with no box (`backend.md` §4's `Int32` row).
            if (std.mem.eql(u8, module, "Int32") and std.mem.eql(u8, name, "Int32")) return .{ .code = "\"i\"" };
        }
        return switch (e.kind) {
            .adt => .{ .adt = id },
            .alias => .{ .alias = id },
            .foreign => .{ .code = "\"x\"" },
        };
    }

    /// `id`'s index in `defs`, queued for writing the first time. A scan:
    /// a row names the handful of types its value holds, and a column of
    /// every type in the build per row would cost more.
    fn def(w: *Writer, id: TypeId) Allocator.Error!u32 {
        for (w.defs.items, 0..) |known, k| {
            if (known == id) return @intCast(k);
        }
        try w.defs.append(w.arena, id);
        return @intCast(w.defs.items.len - 1);
    }

    fn print(w: *Writer, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try w.out.print(w.arena, fmt, args);
    }

    // ---- The root: the checker's nodes ------------------------------------

    /// Written without recursion: a row holds thousands of nodes, nested
    /// as deep. A frame is an open container and how many children it
    /// still owes; a named type written as a code skips its children.
    fn root(w: *Writer, nodes: []const Dispatch.DebugNode) Allocator.Error!void {
        const Frame = struct { close: []const u8, left: u32, first: bool, comma_first: bool, skip: bool };
        var frames: std.ArrayList(Frame) = .empty;
        var skipping: u32 = 0;
        for (nodes) |n| {
            if (frames.items.len != 0 and skipping == 0) {
                const top = &frames.items[frames.items.len - 1];
                if (!top.first or top.comma_first) try w.out.append(w.arena, ',');
                top.first = false;
            }
            var frame: ?Frame = null;
            if (skipping == 0) switch (n.kind) {
                .unknown => try w.out.appendSlice(w.arena, "\"?\""),
                .function => try w.out.appendSlice(w.arena, "\"F\""),
                .unit => try w.out.appendSlice(w.arena, "\"u\""),
                .tuple => {
                    try w.out.appendSlice(w.arena, "[\"t\"");
                    frame = .{ .close = "]", .left = n.count, .first = true, .comma_first = true, .skip = false };
                },
                .record => {
                    try w.out.append(w.arena, '{');
                    frame = .{ .close = "}", .left = n.count, .first = true, .comma_first = false, .skip = false };
                },
                .field => {
                    try w.print("\"{s}\":", .{w.cx.interner.slice(@enumFromInt(n.value))});
                    frame = .{ .close = "", .left = n.count, .first = true, .comma_first = false, .skip = false };
                },
                .named => switch (w.head(@enumFromInt(n.value))) {
                    .code => |code| {
                        try w.out.appendSlice(w.arena, code);
                        frame = .{ .close = "", .left = n.count, .first = true, .comma_first = false, .skip = true };
                    },
                    .builtin => |open| {
                        try w.out.appendSlice(w.arena, open);
                        frame = .{ .close = "]", .left = n.count, .first = true, .comma_first = true, .skip = false };
                    },
                    .adt => |id| {
                        try w.print("[\"n\",{d}", .{try w.def(id)});
                        frame = .{ .close = "]", .left = n.count, .first = true, .comma_first = true, .skip = false };
                    },
                    // The checker reads through every alias; one here is a
                    // row this file cannot read.
                    .alias => {
                        try w.out.appendSlice(w.arena, "\"?\"");
                        frame = .{ .close = "", .left = n.count, .first = true, .comma_first = false, .skip = true };
                    },
                },
            } else if (n.count != 0) {
                frame = .{ .close = "", .left = n.count, .first = true, .comma_first = false, .skip = true };
            }
            if (frame) |f| {
                if (f.left != 0) {
                    try frames.append(w.arena, f);
                    if (f.skip) skipping += 1;
                    continue;
                }
                if (skipping == 0) try w.out.appendSlice(w.arena, f.close);
            }
            // A complete node: close every container it completes.
            while (frames.items.len != 0) {
                const top = &frames.items[frames.items.len - 1];
                top.left -= 1;
                if (top.left != 0) break;
                if (top.skip) skipping -= 1;
                if (skipping == 0 and !top.skip) try w.out.appendSlice(w.arena, top.close);
                _ = frames.pop();
            }
        }
    }

    // ---- Definitions: a `type`'s constructors, from its declaration -------

    fn definition(w: *Writer, id: TypeId) Allocator.Error!void {
        const e = w.cx.types.entries[id.int()];
        if (e.module.int() >= w.cx.birs.len) return w.out.appendSlice(w.arena, "{}");
        const bir = w.cx.birs[e.module.int()];
        try w.out.append(w.arena, '{');
        for (bir.declCtors(bir.decl(e.decl)), 0..) |c, i| {
            if (i != 0) try w.out.append(w.arena, ',');
            try w.print("\"{s}\":[", .{w.cx.interner.slice(bir.symbol(c.name))});
            for (bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Bir.Inst.Index), 0..) |arg, j| {
                if (j != 0) try w.out.append(w.arena, ',');
                try w.written(e.module, bir, arg, null, 0);
            }
            try w.out.append(w.arena, ']');
        }
        try w.out.append(w.arena, '}');
    }

    /// A written type of module `m`. A type variable is its declaration's
    /// parameter: a number in a definition (`env` null), or the text an
    /// alias was applied to.
    fn written(w: *Writer, m: Graph.Index, bir: *const Bir, inst: Bir.Inst.Index, env: ?[]const []const u8, depth: u32) Allocator.Error!void {
        if (depth > max_depth or inst.int() >= bir.insts.len) return w.out.appendSlice(w.arena, "\"?\"");
        const tag = bir.instTag(inst);
        const data = bir.instData(inst);
        switch (tag) {
            .type_var => {
                const param = Bir.TypeVarInfo.unpack(data.rhs).param;
                if (param == Bir.TypeVarInfo.param_none) return w.out.appendSlice(w.arena, "\"?\"");
                if (env) |args| {
                    if (param >= args.len) return w.out.appendSlice(w.arena, "\"?\"");
                    return w.out.appendSlice(w.arena, args[param]);
                }
                return w.print("{d}", .{param});
            },
            .type_unit => try w.out.appendSlice(w.arena, "\"u\""),
            .type_fn => try w.out.appendSlice(w.arena, "\"F\""),
            .type_tuple => {
                try w.out.appendSlice(w.arena, "[\"t\"");
                for (bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)) |el| {
                    try w.out.append(w.arena, ',');
                    try w.written(m, bir, el, env, depth + 1);
                }
                try w.out.append(w.arena, ']');
            },
            .type_record => try w.fields(m, bir, bir.extraSlice(Bir.inlineRange(data), Bir.Field), env, depth),
            .type_record_ext => try w.fields(m, bir, bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Field), env, depth),
            .type_top, .ext_type, .schema_type_top, .ext_schema_type => try w.applied(m, bir, w.cx.types.headId(m, tag, data), &.{}, env, depth),
            .type_app => {
                const h: Bir.Inst.Index = @enumFromInt(data.lhs);
                const args = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
                try w.applied(m, bir, w.cx.types.headId(m, bir.instTag(h), bir.instData(h)), args, env, depth);
            },
            else => try w.out.appendSlice(w.arena, "\"?\""),
        }
    }

    fn fields(w: *Writer, m: Graph.Index, bir: *const Bir, list: []const Bir.Field, env: ?[]const []const u8, depth: u32) Allocator.Error!void {
        try w.out.append(w.arena, '{');
        for (list, 0..) |f, i| {
            if (i != 0) try w.out.append(w.arena, ',');
            try w.print("\"{s}\":", .{w.cx.interner.slice(bir.symbol(f.name))});
            try w.written(m, bir, f.value, env, depth + 1);
        }
        try w.out.append(w.arena, '}');
    }

    /// A named type of module `m` applied to `args`, written types of `m`.
    fn applied(w: *Writer, m: Graph.Index, bir: *const Bir, id: TypeId, args: []const Bir.Inst.Index, env: ?[]const []const u8, depth: u32) Allocator.Error!void {
        switch (w.head(id)) {
            .code => |code| try w.out.appendSlice(w.arena, code),
            .builtin => |open| {
                try w.out.appendSlice(w.arena, open);
                for (args) |a| {
                    try w.out.append(w.arena, ',');
                    try w.written(m, bir, a, env, depth + 1);
                }
                try w.out.append(w.arena, ']');
            },
            .adt => |adt| {
                try w.print("[\"n\",{d}", .{try w.def(adt)});
                for (args) |a| {
                    try w.out.append(w.arena, ',');
                    try w.written(m, bir, a, env, depth + 1);
                }
                try w.out.append(w.arena, ']');
            },
            .alias => |alias| {
                // The body, its parameters read as the arguments' texts.
                const e = w.cx.types.entries[alias.int()];
                if (e.module.int() >= w.cx.birs.len) return w.out.appendSlice(w.arena, "\"?\"");
                const owner = w.cx.birs[e.module.int()];
                const body = owner.decl(e.decl).annotation.unwrap() orelse return w.out.appendSlice(w.arena, "\"?\"");
                const texts = try w.arena.alloc([]const u8, args.len);
                for (args, texts) |a, *t| {
                    const mark = w.out.items.len;
                    try w.written(m, bir, a, env, depth + 1);
                    t.* = try w.arena.dupe(u8, w.out.items[mark..]);
                    w.out.shrinkRetainingCapacity(mark);
                }
                try w.written(e.module, owner, body, texts, depth + 1);
            },
        }
    }
};
