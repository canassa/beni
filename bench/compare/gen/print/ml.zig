//! The printer of the five ML-family languages (docs/design/compare-bench.md
//! §3.8): beni, Elm, Gleam, Roc (the Zig compiler) and PureScript. They
//! share one layout engine, because their layout rules agree on what
//! matters: a block (a `case`, `let` or `if`) prints on its own lines,
//! every continuation line sits right of the enclosing block, and a block
//! used as an operand or argument is wrapped in parentheses (braces in
//! Gleam). The spelling differences of §2.2 are the `switch`es below.
//!
//! Parentheses come from the tree's shape, never from a source: a binary
//! operator's operand is parenthesised unless it is the same operator on
//! the left, so a long left-nested chain prints flat and nothing depends on
//! a precedence table.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Tree = @import("../Tree.zig");
const TypeStore = @import("../Type.zig");
const Type = TypeStore.Type;
const common = @import("common.zig");
const E = error{ OutOfMemory, WriteFailed };
const Lang = common.Lang;
const Defaulted = @import("../validate.zig").Defaulted;

pub const P = struct {
    lang: Lang,
    t: *const Tree,
    uses: []const u32,
    module: u32,
    w: *Writer,
    a: Allocator,
    /// Modules named in the printed text; the header imports exactly these.
    refs: []bool,
    /// Library imports the text needed (Gleam's `gleam/list` and
    /// `gleam/int`; PureScript's `Data.List`, `Data.Tuple`, `Data.Foldable`
    /// and whether anything from `Prelude` was used).
    lib: common.LibUse = .{},
    annotations: u64 = 0,
    /// Every local printed so far is named `v<n>`; unused parameters `_`.
    col: usize = 0,
    /// The `foldl` lambda whose parameters print swapped (§2.3).
    swaps: std.ArrayList(u32) = .empty,
    /// Roc only: literals to write with a type suffix (`validate.rocDefaulted`).
    roc_defaulted: ?Defaulted = null,
    /// PureScript only: binders to write a type on (`validate.psAmbiguous`).
    ps_typed: ?@import("../validate.zig").PsTyped = null,

    fn out(p: *P, s: []const u8) !void {
        try p.w.writeAll(s);
        p.col += s.len;
    }

    fn print(p: *P, comptime fmt: []const u8, args: anytype) !void {
        const before = p.w.end;
        try p.w.print(fmt, args);
        p.col += p.w.end - before;
    }

    fn nl(p: *P, ind: usize) !void {
        try p.w.writeByte('\n');
        try p.w.splatByteAll(' ', ind);
        p.col = ind;
    }

    fn store(p: *P) *const TypeStore {
        return &p.t.store;
    }

    // ---- names ----

    fn modName(p: *P, m: u32) []const u8 {
        return p.t.modules.items[m].name;
    }

    /// The qualifier of module `m` as the language spells it.
    fn qual(p: *P, m: u32) !void {
        p.refs[m] = true;
        if (p.lang == .gleam) {
            try p.print("{s}.", .{common.gleamModule(p.a, p.modName(m))});
        } else try p.print("{s}.", .{p.modName(m)});
    }

    fn fnRef(p: *P, f: u32) !void {
        const fd = p.t.fns.items[f];
        if (fd.module != p.module) try p.qual(fd.module);
        try p.out(fd.name);
    }

    fn typeRef(p: *P, d: u32) !void {
        const td = p.t.types.items[d];
        if (td.module != p.module) try p.qual(td.module);
        try p.out(td.name);
    }

    fn ctorRef(p: *P, c: u32) !void {
        const cd = p.t.ctors.items[c];
        const d = cd.decl;
        const td = p.t.types.items[d];
        switch (p.lang) {
            .roc => {
                // Qualified through the nominal type (§2.5, §19 V1).
                if (td.module != p.module) try p.qual(td.module);
                try p.print("{s}.", .{td.name});
            },
            else => if (td.module != p.module) try p.qual(td.module),
        }
        try p.out(cd.name);
    }

    fn local(p: *P, l: u32) !void {
        try p.print("v{d}", .{p.t.locals.items[l].name});
    }

    fn binder(p: *P, l: u32) !void {
        if (p.uses[l] == 0) return p.out("_");
        try p.local(l);
    }

    fn psTyped(p: *P, l: u32) bool {
        const d = p.ps_typed orelse return false;
        return d.binders[l];
    }

    fn suffix(p: *P, e: u32, s: []const u8) []const u8 {
        const d = p.roc_defaulted orelse return "";
        return if (d.exprs[e]) s else "";
    }

    fn tvarName(i: u32) u8 {
        return "abcdefgh"[i];
    }

    // ---- types ----

    /// `atomic`: the type sits where an application or function type
    /// would need parentheses (an argument of a type application, or a
    /// function type's parameter in the curried languages).
    pub fn ty(p: *P, t: Type, parens: bool) E!void {
        const s = p.store();
        const w = p.w;
        _ = w;
        switch (s.tag(t)) {
            .int => try p.out(switch (p.lang) {
                .roc => "I64",
                else => "Int",
            }),
            .float => try p.out(switch (p.lang) {
                .roc => "F64",
                .purescript => "Number",
                else => "Float",
            }),
            .string => try p.out(switch (p.lang) {
                .roc => "Str",
                else => "String",
            }),
            .bool => try p.out(switch (p.lang) {
                .purescript => "Boolean",
                else => "Bool",
            }),
            .@"var" => try p.print("{c}", .{tvarName(s.varIndex(t))}),
            .pair => {
                const parts = s.pairParts(t);
                switch (p.lang) {
                    .beni, .elm => {
                        try p.out("( ");
                        try p.ty(parts[0], false);
                        try p.out(", ");
                        try p.ty(parts[1], false);
                        try p.out(" )");
                    },
                    .gleam => {
                        try p.out("#(");
                        try p.ty(parts[0], false);
                        try p.out(", ");
                        try p.ty(parts[1], false);
                        try p.out(")");
                    },
                    .roc => {
                        try p.out("(");
                        try p.ty(parts[0], false);
                        try p.out(", ");
                        try p.ty(parts[1], false);
                        try p.out(")");
                    },
                    .purescript => {
                        p.lib.tuple_type = true;
                        if (parens) try p.out("(");
                        try p.out("Tuple ");
                        try p.ty(parts[0], true);
                        try p.out(" ");
                        try p.ty(parts[1], true);
                        if (parens) try p.out(")");
                    },
                    .typescript => unreachable,
                }
            },
            .list => {
                const el = s.listElem(t);
                switch (p.lang) {
                    .gleam, .roc => {
                        try p.out("List(");
                        try p.ty(el, false);
                        try p.out(")");
                    },
                    else => {
                        if (p.lang == .purescript) p.lib.list_type = true;
                        if (parens) try p.out("(");
                        try p.out("List ");
                        try p.ty(el, true);
                        if (parens) try p.out(")");
                    },
                }
            },
            .func => {
                var ps: [16]Type = undefined;
                const n = s.funcParams(t).len;
                @memcpy(ps[0..n], s.funcParams(t));
                const ret = s.funcRet(t);
                switch (p.lang) {
                    .gleam => {
                        try p.out("fn(");
                        for (ps[0..n], 0..) |x, i| {
                            if (i > 0) try p.out(", ");
                            try p.ty(x, false);
                        }
                        try p.out(") -> ");
                        try p.ty(ret, false);
                    },
                    .beni, .roc => {
                        // n-ary: `A, B -> C`; parenthesised as a parameter
                        // or result of another function type.
                        if (parens) try p.out("(");
                        for (ps[0..n], 0..) |x, i| {
                            if (i > 0) try p.out(", ");
                            try p.ty(x, true);
                        }
                        try p.out(" -> ");
                        try p.ty(ret, true);
                        if (parens) try p.out(")");
                    },
                    .elm, .purescript => {
                        // Curried: `A -> B -> C`.
                        if (parens) try p.out("(");
                        for (ps[0..n]) |x| {
                            try p.ty(x, true);
                            try p.out(" -> ");
                        }
                        try p.ty(ret, true);
                        if (parens) try p.out(")");
                    },
                    .typescript => unreachable,
                }
            },
            .named => {
                const d = s.namedDecl(t);
                var args: [8]Type = undefined;
                const n = s.namedArgs(t).len;
                @memcpy(args[0..n], s.namedArgs(t));
                switch (p.lang) {
                    .gleam, .roc => {
                        try p.typeRef(d);
                        if (n > 0) {
                            try p.out("(");
                            for (args[0..n], 0..) |x, i| {
                                if (i > 0) try p.out(", ");
                                try p.ty(x, false);
                            }
                            try p.out(")");
                        }
                    },
                    else => {
                        if (n > 0 and parens) try p.out("(");
                        try p.typeRef(d);
                        for (args[0..n]) |x| {
                            try p.out(" ");
                            try p.ty(x, true);
                        }
                        if (n > 0 and parens) try p.out(")");
                    },
                }
            },
        }
    }

    // ---- shape queries ----

    /// Whether `e` prints on more than one line: it contains a block.
    fn multi(p: *P, e: u32) bool {
        const t = p.t;
        const x = t.expr(e);
        return switch (x.tag) {
            .let, .case, .@"if" => true,
            .lit_int, .lit_float, .lit_string, .lit_bool, .local, .global => false,
            .call => blk: {
                if (p.multi(x.a)) break :blk true;
                for (t.extraList(x.b)) |c| if (p.multi(c)) break :blk true;
                break :blk false;
            },
            .lambda, .not, .int_to_string => p.multi(if (x.tag == .lambda) x.b else x.a),
            .ctor => blk: {
                for (t.extraList(x.b)) |c| if (p.multi(c)) break :blk true;
                break :blk false;
            },
            .list => blk: {
                for (t.extraList(x.a)) |c| if (p.multi(c)) break :blk true;
                break :blk false;
            },
            .pair, .binop, .list_map, .list_filter => p.multi(x.a) or p.multi(x.b),
            .list_foldl => p.multi(x.a) or p.multi(t.extra.items[x.b]) or p.multi(t.extra.items[x.b + 1]),
            .pipe => blk: {
                if (p.multi(x.a)) break :blk true;
                break :blk false;
            },
        };
    }

    /// Whether `e` needs no parentheses as an argument of juxtaposition.
    fn atomic(p: *P, e: u32) bool {
        const x = p.t.expr(e);
        return switch (x.tag) {
            .lit_int, .lit_float, .lit_string, .lit_bool, .local, .global => true,
            .ctor => p.t.extraList(x.b).len == 0,
            .pair => p.lang != .purescript,
            .list => p.lang != .purescript or p.t.extraList(x.a).len == 0,
            else => false,
        };
    }

    // ---- expressions ----

    /// Print `e` at the cursor; its continuation lines are at `ind` or
    /// right of it.
    pub fn expr(p: *P, e: u32, ind: usize) E!void {
        const t = p.t;
        const x = t.expr(e);
        switch (x.tag) {
            .lit_int => try p.print("{d}{s}", .{ x.a, p.suffix(e, ".I64") }),
            .lit_float => try p.print("{d}.{d}{s}", .{ x.a, x.b, p.suffix(e, ".F64") }),
            .lit_string => try p.print("\"s{d}\"", .{x.a}),
            .lit_bool => try p.out(switch (p.lang) {
                .purescript => if (x.a == 1) "true" else "false",
                else => if (x.a == 1) "True" else "False",
            }),
            .local => try p.local(x.a),
            .global => try p.fnRef(x.a),
            .call => try p.call(x.a, t.extraList(x.b), ind),
            .ctor => try p.ctorApp(x.a, t.extraList(x.b), ind),
            .lambda => try p.lambda(e, ind),
            .let => try p.letExpr(e, ind),
            .@"if" => try p.ifExpr(e, ind),
            .case => try p.caseExpr(e, ind),
            .pair => try p.pairExpr(x.a, x.b, ind),
            .list => try p.listExpr(t.extraList(x.a), ind),
            .binop => try p.binop(e, ind),
            .not => switch (p.lang) {
                .gleam, .roc => {
                    try p.out("!");
                    try p.group(x.a, ind + 1);
                },
                else => {
                    if (p.lang == .purescript) p.lib.prelude = true;
                    try p.applyNamed("not", &.{x.a}, ind);
                },
            },
            .int_to_string => switch (p.lang) {
                .beni, .elm => try p.applyNamed("String.fromInt", &.{x.a}, ind),
                .purescript => {
                    p.lib.prelude = true;
                    try p.applyNamed("show", &.{x.a}, ind);
                },
                .gleam => {
                    p.lib.gleam_int = true;
                    try p.callNamed("int.to_string", &.{x.a}, ind);
                },
                .roc => try p.callNamed("I64.to_str", &.{x.a}, ind),
                .typescript => unreachable,
            },
            .list_map => switch (p.lang) {
                .beni => try p.applyNamed("List.map", &.{ x.a, x.b }, ind),
                .elm => try p.applyNamed("List.map", &.{ x.b, x.a }, ind),
                .purescript => {
                    p.lib.prelude = true;
                    try p.applyNamed("map", &.{ x.b, x.a }, ind);
                },
                .gleam => {
                    p.lib.gleam_list = true;
                    try p.callNamed("list.map", &.{ x.a, x.b }, ind);
                },
                .roc => try p.callNamed("List.map", &.{ x.a, x.b }, ind),
                .typescript => unreachable,
            },
            .list_filter => switch (p.lang) {
                .beni => try p.applyNamed("List.filter", &.{ x.a, x.b }, ind),
                .elm => try p.applyNamed("List.filter", &.{ x.b, x.a }, ind),
                .purescript => {
                    p.lib.list_filter = true;
                    try p.applyNamed("filter", &.{ x.b, x.a }, ind);
                },
                .gleam => {
                    p.lib.gleam_list = true;
                    try p.callNamed("list.filter", &.{ x.a, x.b }, ind);
                },
                .roc => try p.callNamed("List.keep_if", &.{ x.a, x.b }, ind),
                .typescript => unreachable,
            },
            .list_foldl => {
                const z = t.extra.items[x.b];
                const f = t.extra.items[x.b + 1];
                // The tree's lambda is (elem, acc); Gleam, Roc and
                // PureScript fold with (acc, elem), so their printers swap
                // the parameters (§2.3).
                switch (p.lang) {
                    .beni => try p.applyNamed("List.foldl", &.{ x.a, z, f }, ind),
                    .elm => try p.applyNamed("List.foldl", &.{ f, z, x.a }, ind),
                    .purescript => {
                        p.lib.foldable = true;
                        try p.swaps.append(p.a, f);
                        try p.applyNamed("foldl", &.{ f, z, x.a }, ind);
                    },
                    .gleam => {
                        p.lib.gleam_list = true;
                        try p.swaps.append(p.a, f);
                        try p.callNamed("list.fold", &.{ x.a, z, f }, ind);
                    },
                    .roc => {
                        try p.swaps.append(p.a, f);
                        try p.callNamed("List.fold", &.{ x.a, z, f }, ind);
                    },
                    .typescript => unreachable,
                }
            },
            .pipe => {
                const op = if (p.lang == .purescript) " # " else " |> ";
                try p.group(x.a, ind);
                for (t.extraList(x.b)) |st| {
                    try p.out(op);
                    try p.expr(st, ind + 8);
                }
            },
        }
    }

    /// `e` where an operand or argument goes: parenthesised (braced in
    /// Gleam) unless it cannot be misread.
    fn group(p: *P, e: u32, ind: usize) !void {
        const x = p.t.expr(e);
        const bare = switch (p.lang) {
            .gleam, .roc => switch (x.tag) {
                .binop, .@"if", .case, .let, .pipe, .lambda, .not => false,
                else => true,
            },
            else => p.atomic(e),
        };
        if (bare) return p.expr(e, ind);
        const open: []const u8 = if (p.lang == .gleam) "{ " else "(";
        const close: []const u8 = if (p.lang == .gleam) "}" else ")";
        try p.out(open);
        try p.expr(e, ind + 1);
        if (p.multi(e)) try p.nl(ind);
        if (p.lang == .gleam and !p.multi(e)) try p.out(" ");
        try p.out(close);
    }

    /// `f a b` in beni, Elm and PureScript; `f(a, b)` in Gleam and Roc.
    fn call(p: *P, callee: u32, args: []const u32, ind: usize) !void {
        switch (p.lang) {
            .gleam, .roc => {
                try p.group(callee, ind);
                try p.argList(args, ind);
            },
            else => {
                try p.group(callee, ind);
                try p.juxtapose(args, ind);
            },
        }
    }

    fn juxtapose(p: *P, args: []const u32, ind: usize) !void {
        var vertical = false;
        for (args) |a| vertical = vertical or p.multi(a);
        for (args) |a| {
            if (vertical) try p.nl(ind + 4) else try p.out(" ");
            try p.group(a, if (vertical) ind + 4 else ind);
        }
    }

    fn argList(p: *P, args: []const u32, ind: usize) !void {
        var vertical = false;
        for (args) |a| vertical = vertical or p.multi(a);
        try p.out("(");
        for (args, 0..) |a, i| {
            if (vertical) try p.nl(ind + 4) else if (i > 0) try p.out(" ");
            try p.expr(a, ind + 4);
            if (i + 1 < args.len or vertical) try p.out(",");
        }
        if (vertical) try p.nl(ind);
        try p.out(")");
    }

    fn applyNamed(p: *P, name: []const u8, args: []const u32, ind: usize) !void {
        try p.out(name);
        try p.juxtapose(args, ind);
    }

    fn callNamed(p: *P, name: []const u8, args: []const u32, ind: usize) !void {
        try p.out(name);
        try p.argList(args, ind);
    }

    fn ctorApp(p: *P, c: u32, args: []const u32, ind: usize) !void {
        try p.ctorRef(c);
        if (args.len == 0) return;
        switch (p.lang) {
            .gleam, .roc => try p.argList(args, ind),
            else => try p.juxtapose(args, ind),
        }
    }

    fn lambda(p: *P, e: u32, ind: usize) !void {
        const t = p.t;
        const x = t.expr(e);
        var ps: [16]u32 = undefined;
        const src = t.extraList(x.a);
        @memcpy(ps[0..src.len], src);
        const n = src.len;
        if (std.mem.indexOfScalar(u32, p.swaps.items, e)) |k| {
            std.mem.swap(u32, &ps[0], &ps[1]);
            _ = p.swaps.swapRemove(k);
        }
        const multi_body = p.multi(x.b);
        switch (p.lang) {
            .beni, .elm, .purescript => {
                try p.out("\\");
                for (ps[0..n], 0..) |l, i| {
                    if (i > 0) try p.out(" ");
                    if (p.psTyped(l)) {
                        // An ambiguous class constraint otherwise (§19 V10).
                        try p.out("(");
                        try p.binder(l);
                        try p.out(" :: ");
                        try p.ty(p.t.locals.items[l].ty, false);
                        try p.out(")");
                        p.annotations += 1;
                    } else try p.binder(l);
                }
                try p.out(" ->");
            },
            .gleam => {
                try p.out("fn(");
                for (ps[0..n], 0..) |l, i| {
                    if (i > 0) try p.out(", ");
                    try p.binder(l);
                }
                try p.out(") {");
            },
            .roc => {
                try p.out("|");
                for (ps[0..n], 0..) |l, i| {
                    if (i > 0) try p.out(", ");
                    try p.binder(l);
                }
                try p.out("|");
            },
            .typescript => unreachable,
        }
        if (multi_body) {
            try p.nl(ind + 4);
            try p.expr(x.b, ind + 4);
            if (p.lang == .gleam) {
                try p.nl(ind);
                try p.out("}");
            }
        } else {
            try p.out(" ");
            try p.expr(x.b, ind + 4);
            if (p.lang == .gleam) try p.out(" }");
        }
    }

    fn letExpr(p: *P, e: u32, ind: usize) !void {
        const t = p.t;
        const x = t.expr(e);
        const xs = t.extraPairs(x.a);
        switch (p.lang) {
            .beni, .elm, .purescript => {
                try p.out("let");
                var k: usize = 0;
                while (k < xs.len) : (k += 2) {
                    try p.nl(ind + 4);
                    try p.local(xs[k]);
                    try p.out(" =");
                    if (p.multi(xs[k + 1])) {
                        try p.nl(ind + 8);
                    } else try p.out(" ");
                    if (p.psTyped(xs[k])) {
                        try p.out("(");
                        try p.expr(xs[k + 1], ind + 9);
                        try p.out(" :: ");
                        try p.ty(p.t.locals.items[xs[k]].ty, false);
                        try p.out(")");
                        p.annotations += 1;
                    } else try p.expr(xs[k + 1], ind + 8);
                }
                try p.nl(ind);
                try p.out("in");
                try p.nl(ind);
                try p.expr(x.b, ind);
            },
            .gleam, .roc => {
                try p.out("{");
                var k: usize = 0;
                while (k < xs.len) : (k += 2) {
                    try p.nl(ind + 4);
                    if (p.lang == .gleam) try p.out("let ");
                    try p.local(xs[k]);
                    try p.out(" = ");
                    try p.expr(xs[k + 1], ind + 8);
                }
                try p.nl(ind + 4);
                try p.expr(x.b, ind + 4);
                try p.nl(ind);
                try p.out("}");
            },
            .typescript => unreachable,
        }
    }

    fn ifExpr(p: *P, e: u32, ind: usize) !void {
        const t = p.t;
        const x = t.expr(e);
        const a = t.extra.items[x.b];
        const b = t.extra.items[x.b + 1];
        switch (p.lang) {
            .beni, .elm, .purescript => {
                try p.out("if ");
                try p.expr(x.a, ind + 4);
                if (p.multi(x.a)) try p.nl(ind);
                try p.out(if (p.multi(x.a)) "then" else " then");
                try p.nl(ind + 4);
                try p.expr(a, ind + 4);
                try p.nl(ind);
                try p.out("else");
                try p.nl(ind + 4);
                try p.expr(b, ind + 4);
            },
            .gleam => {
                try p.out("case ");
                try p.expr(x.a, ind + 4);
                try p.out(" {");
                try p.nl(ind + 4);
                try p.out("True ->");
                try p.branchBody(a, ind + 4);
                try p.nl(ind + 4);
                try p.out("False ->");
                try p.branchBody(b, ind + 4);
                try p.nl(ind);
                try p.out("}");
            },
            .roc => {
                try p.out("if ");
                try p.group(x.a, ind + 4);
                try p.out(" {");
                try p.nl(ind + 4);
                try p.expr(a, ind + 4);
                try p.nl(ind);
                try p.out("} else {");
                try p.nl(ind + 4);
                try p.expr(b, ind + 4);
                try p.nl(ind);
                try p.out("}");
            },
            .typescript => unreachable,
        }
    }

    fn branchBody(p: *P, body: u32, ind: usize) !void {
        if (p.multi(body)) {
            try p.nl(ind + 4);
            try p.expr(body, ind + 4);
        } else {
            try p.out(" ");
            try p.expr(body, ind + 4);
        }
    }

    fn caseExpr(p: *P, e: u32, ind: usize) !void {
        const t = p.t;
        const x = t.expr(e);
        const xs = t.extraPairs(x.b);
        switch (p.lang) {
            .beni, .elm, .purescript => {
                try p.out("case ");
                try p.expr(x.a, ind + 4);
                try p.out(" of");
            },
            .gleam => {
                // A tuple built only to be matched is a warning in Gleam
                // ("redundant tuple"): two subjects instead (§19 V2).
                try p.out("case ");
                const sc = t.expr(x.a);
                if (sc.tag == .pair) {
                    try p.expr(sc.a, ind + 4);
                    try p.out(", ");
                    try p.expr(sc.b, ind + 4);
                } else try p.expr(x.a, ind + 4);
                try p.out(" {");
            },
            .roc => {
                try p.out("match ");
                try p.expr(x.a, ind + 4);
                try p.out(" {");
            },
            .typescript => unreachable,
        }
        var k: usize = 0;
        while (k < xs.len) : (k += 2) {
            try p.nl(ind + 4);
            const pt = t.pat(xs[k]);
            if (p.lang == .gleam and t.expr(x.a).tag == .pair and pt.tag == .pair) {
                try p.pat(pt.a, false);
                try p.out(", ");
                try p.pat(pt.b, false);
            } else if (p.lang == .gleam and t.expr(x.a).tag == .pair) {
                try p.out("_, _");
            } else try p.pat(xs[k], false);
            try p.out(if (p.lang == .roc) " =>" else " ->");
            try p.branchBody(xs[k + 1], ind + 4);
        }
        if (p.lang == .gleam or p.lang == .roc) {
            try p.nl(ind);
            try p.out("}");
        }
    }

    fn pairExpr(p: *P, a: u32, b: u32, ind: usize) !void {
        switch (p.lang) {
            .purescript => {
                p.lib.tuple_ctor = true;
                try p.out("Tuple");
                try p.juxtapose(&.{ a, b }, ind);
            },
            .gleam, .roc => {
                try p.out(if (p.lang == .gleam) "#" else "");
                try p.argList(&.{ a, b }, ind);
            },
            else => {
                if (p.multi(a) or p.multi(b)) {
                    try p.out("( ");
                    try p.expr(a, ind + 2);
                    try p.nl(ind);
                    try p.out(", ");
                    try p.expr(b, ind + 2);
                    try p.nl(ind);
                    try p.out(")");
                } else {
                    try p.out("( ");
                    try p.expr(a, ind + 2);
                    try p.out(", ");
                    try p.expr(b, ind + 2);
                    try p.out(" )");
                }
            },
        }
    }

    fn listExpr(p: *P, items: []const u32, ind: usize) !void {
        switch (p.lang) {
            .purescript => {
                p.lib.list_type = true;
                if (items.len == 0) {
                    p.lib.list_nil = true;
                    return p.out("Nil");
                }
                p.lib.list_cons = true;
                p.lib.list_nil = true;
                for (items) |it| {
                    try p.group(it, ind + 4);
                    try p.out(" : ");
                }
                try p.out("Nil");
            },
            .gleam, .roc => {
                var vertical = false;
                for (items) |a| vertical = vertical or p.multi(a);
                try p.out("[");
                for (items, 0..) |a, i| {
                    if (vertical) try p.nl(ind + 4) else if (i > 0) try p.out(" ");
                    try p.expr(a, ind + 4);
                    if (i + 1 < items.len or vertical) try p.out(",");
                }
                if (vertical) try p.nl(ind);
                try p.out("]");
            },
            else => {
                if (items.len == 0) return p.out("[]");
                var vertical = false;
                for (items) |a| vertical = vertical or p.multi(a);
                try p.out("[ ");
                for (items, 0..) |a, i| {
                    if (i > 0) {
                        if (vertical) try p.nl(ind);
                        try p.out(", ");
                    }
                    try p.expr(a, ind + 2);
                }
                if (vertical) try p.nl(ind) else try p.out(" ");
                try p.out("]");
            },
        }
    }

    fn opText(p: *P, op: Tree.Op) []const u8 {
        return switch (op) {
            .int_add => "+",
            .int_sub => "-",
            .int_mul => "*",
            .float_add => if (p.lang == .gleam) "+." else "+",
            .float_sub => if (p.lang == .gleam) "-." else "-",
            .float_mul => if (p.lang == .gleam) "*." else "*",
            .str_append => switch (p.lang) {
                .gleam, .purescript => "<>",
                else => "++",
            },
            .bool_and => if (p.lang == .roc) "and" else "&&",
            .bool_or => if (p.lang == .roc) "or" else "||",
            .int_eq, .str_eq, .bool_eq => "==",
            .int_lt => "<",
            .float_lt => if (p.lang == .gleam) "<." else "<",
        };
    }

    fn binop(p: *P, e: u32, ind: usize) !void {
        const t = p.t;
        const x = t.expr(e);
        if (p.lang == .purescript) p.lib.prelude = true;
        if (p.lang == .roc and x.op == .str_append) {
            // Roc has no `++` (§2.2).
            return p.callNamed("Str.concat", &.{ x.a, x.b }, ind);
        }
        // Flatten the left spine of the same operator.
        var spine: [512]u32 = undefined;
        var n: usize = 0;
        var cur = e;
        while (true) {
            const c = t.expr(cur);
            if (c.tag != .binop or c.op != x.op or n == spine.len - 1 or (p.lang == .roc and c.op == .str_append)) break;
            spine[n] = c.b;
            n += 1;
            cur = c.a;
        }
        // `cur` is the leftmost operand; spine holds the right operands,
        // innermost last.
        var vertical = p.multi(cur);
        for (spine[0..n]) |r| vertical = vertical or p.multi(r);
        try p.operand(cur, ind);
        var i: usize = n;
        const txt = p.opText(x.op);
        while (i > 0) {
            i -= 1;
            if (vertical) try p.nl(ind + 4) else try p.out(" ");
            try p.out(txt);
            try p.out(" ");
            try p.operand(spine[i], if (vertical) ind + 8 else ind);
        }
    }

    fn operand(p: *P, e: u32, ind: usize) !void {
        const x = p.t.expr(e);
        const bare = switch (x.tag) {
            .lit_int, .lit_float, .lit_string, .lit_bool, .local, .global, .pair, .list => !(p.lang == .purescript and (x.tag == .pair or (x.tag == .list and p.t.extraList(x.a).len > 0))),
            .call, .ctor, .int_to_string, .list_map, .list_filter, .list_foldl => true,
            .not => p.lang != .gleam and p.lang != .roc,
            else => false,
        };
        if (bare and !(x.tag == .ctor and p.lang == .purescript and false)) return p.expr(e, ind);
        const open: []const u8 = if (p.lang == .gleam) "{ " else "(";
        const close: []const u8 = if (p.lang == .gleam) " }" else ")";
        try p.out(open);
        try p.expr(e, ind + 1);
        if (p.multi(e)) {
            try p.nl(ind);
            try p.out(close[close.len - 1 ..]);
        } else try p.out(close);
    }

    // ---- patterns ----

    fn pat(p: *P, i: u32, nested: bool) E!void {
        const t = p.t;
        const pt = t.pat(i);
        switch (pt.tag) {
            .wild => try p.out("_"),
            .bind => try p.local(pt.a),
            .lit_int => try p.print("{d}{s}", .{ pt.a, if (p.roc_defaulted) |d| (if (d.pats[i]) ".I64" else "") else "" }),
            .lit_string => try p.print("\"s{d}\"", .{pt.a}),
            .lit_bool => try p.out(switch (p.lang) {
                .purescript => if (pt.a == 1) "true" else "false",
                else => if (pt.a == 1) "True" else "False",
            }),
            .pair => switch (p.lang) {
                .purescript => {
                    p.lib.tuple_ctor = true;
                    if (nested) try p.out("(");
                    try p.out("Tuple ");
                    try p.pat(pt.a, true);
                    try p.out(" ");
                    try p.pat(pt.b, true);
                    if (nested) try p.out(")");
                },
                .gleam, .roc => {
                    try p.out(if (p.lang == .gleam) "#(" else "(");
                    try p.pat(pt.a, false);
                    try p.out(", ");
                    try p.pat(pt.b, false);
                    try p.out(")");
                },
                else => {
                    try p.out("( ");
                    try p.pat(pt.a, false);
                    try p.out(", ");
                    try p.pat(pt.b, false);
                    try p.out(" )");
                },
            },
            .ctor => {
                const subs = t.extraList(pt.b);
                switch (p.lang) {
                    .gleam, .roc => {
                        try p.ctorRef(pt.a);
                        if (subs.len > 0) {
                            try p.out("(");
                            for (subs, 0..) |s, k| {
                                if (k > 0) try p.out(", ");
                                try p.pat(s, false);
                            }
                            try p.out(")");
                        }
                    },
                    else => {
                        if (subs.len > 0 and nested) try p.out("(");
                        try p.ctorRef(pt.a);
                        for (subs) |s| {
                            try p.out(" ");
                            try p.pat(s, true);
                        }
                        if (subs.len > 0 and nested) try p.out(")");
                    },
                }
            },
        }
    }

    // ---- declarations ----

    pub fn typeDecl(p: *P, d: u32) !void {
        const t = p.t;
        const td = t.types.items[d];
        const ctors = td.ctors.items;
        switch (p.lang) {
            .beni, .elm => {
                if (p.lang == .beni) try p.out("pub ");
                try p.print("type {s}", .{td.name});
                for (0..td.nparams) |i| try p.print(" {c}", .{tvarName(@intCast(i))});
                for (ctors, 0..) |c, i| {
                    try p.nl(4);
                    try p.out(if (i == 0) "= " else "| ");
                    try p.ctorDecl(c);
                }
                try p.out("\n\n\n");
                p.col = 0;
            },
            .purescript => {
                try p.print("data {s}", .{td.name});
                for (0..td.nparams) |i| try p.print(" {c}", .{tvarName(@intCast(i))});
                for (ctors, 0..) |c, i| {
                    try p.nl(2);
                    try p.out(if (i == 0) "= " else "| ");
                    try p.ctorDecl(c);
                }
                try p.out("\n\n");
                p.col = 0;
            },
            .gleam => {
                try p.print("pub type {s}", .{td.name});
                if (td.nparams > 0) {
                    try p.out("(");
                    for (0..td.nparams) |i| try p.print("{s}{c}", .{ if (i > 0) ", " else "", tvarName(@intCast(i)) });
                    try p.out(")");
                }
                try p.out(" {");
                for (ctors) |c| {
                    try p.nl(2);
                    try p.ctorDecl(c);
                }
                try p.out("\n}\n\n");
                p.col = 0;
            },
            .roc => {
                try p.nl(4);
                try p.print("{s}", .{td.name});
                if (td.nparams > 0) {
                    try p.out("(");
                    for (0..td.nparams) |i| try p.print("{s}{c}", .{ if (i > 0) ", " else "", tvarName(@intCast(i)) });
                    try p.out(")");
                }
                try p.out(" := [");
                for (ctors, 0..) |c, i| {
                    try p.nl(8);
                    try p.ctorDecl(c);
                    if (i + 1 < ctors.len or true) try p.out(",");
                }
                try p.nl(4);
                try p.out("]\n");
                p.col = 0;
            },
            .typescript => unreachable,
        }
    }

    fn ctorDecl(p: *P, c: u32) !void {
        const cd = p.t.ctors.items[c];
        try p.out(cd.name);
        switch (p.lang) {
            .gleam, .roc => if (cd.fields.len > 0) {
                try p.out("(");
                for (cd.fields, 0..) |f, i| {
                    if (i > 0) try p.out(", ");
                    try p.ty(f, false);
                }
                try p.out(")");
            },
            else => for (cd.fields) |f| {
                try p.out(" ");
                try p.ty(f, true);
            },
        }
    }

    fn annotated(p: *P, fi: u32) bool {
        const f = p.t.fns.items[fi];
        if (p.ps_typed) |d| if (d.sigs[fi]) return true;
        return f.annotated or f.entry or f.library;
    }

    pub fn fnDecl(p: *P, fi: u32) !void {
        const t = p.t;
        const f = t.fns.items[fi];
        const ann = p.annotated(fi);
        if (ann) p.annotations += 1;
        switch (p.lang) {
            .beni, .elm, .purescript => {
                if (ann) {
                    if (p.lang == .beni) try p.out("pub ");
                    try p.out(f.name);
                    try p.out(if (p.lang == .purescript) " :: " else " : ");
                    if (p.lang == .purescript and f.nvars > 0) {
                        try p.out("forall");
                        for (0..f.nvars) |i| try p.print(" {c}", .{tvarName(@intCast(i))});
                        try p.out(". ");
                    }
                    try p.sig(f);
                    try p.nl(0);
                } else if (p.lang == .beni) try p.out("pub ");
                try p.out(f.name);
                for (f.params) |l| {
                    try p.out(" ");
                    try p.binder(l);
                }
                try p.out(" =");
                try p.nl(4);
                try p.expr(f.body, 4);
                try p.out(if (p.lang == .purescript) "\n\n" else "\n\n\n");
                p.col = 0;
            },
            .gleam => {
                try p.print("pub fn {s}(", .{f.name});
                for (f.params, 0..) |l, i| {
                    if (i > 0) try p.out(", ");
                    try p.binder(l);
                    if (ann) {
                        try p.out(": ");
                        try p.ty(t.locals.items[l].ty, false);
                    }
                }
                try p.out(")");
                if (ann) {
                    try p.out(" -> ");
                    try p.ty(f.ret, false);
                }
                try p.out(" {");
                try p.nl(2);
                try p.expr(f.body, 2);
                try p.out("\n}\n\n");
                p.col = 0;
            },
            .roc => {
                try p.nl(4);
                if (ann) {
                    try p.print("{s} : ", .{f.name});
                    try p.sig(f);
                    try p.nl(4);
                }
                try p.print("{s} = |", .{f.name});
                for (f.params, 0..) |l, i| {
                    if (i > 0) try p.out(", ");
                    try p.binder(l);
                }
                try p.out("|");
                try p.nl(8);
                try p.expr(f.body, 8);
                try p.out("\n");
                p.col = 0;
            },
            .typescript => unreachable,
        }
    }

    fn sig(p: *P, f: Tree.Fn) !void {
        const t = p.t;
        switch (p.lang) {
            .beni, .roc => {
                for (f.params, 0..) |l, i| {
                    if (i > 0) try p.out(", ");
                    try p.ty(t.locals.items[l].ty, true);
                }
                try p.out(" -> ");
                try p.ty(f.ret, p.store().tag(f.ret) == .func);
            },
            else => {
                for (f.params) |l| {
                    try p.ty(t.locals.items[l].ty, true);
                    try p.out(" -> ");
                }
                try p.ty(f.ret, true);
            },
        }
    }
};
