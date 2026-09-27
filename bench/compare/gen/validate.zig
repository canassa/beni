//! The oracle (docs/design/compare-bench.md §3.7). It re-checks the finished
//! tree independently of synthesis:
//!
//! 1. every node's recorded type agrees with its children, and every local
//!    it reads is in scope;
//! 2. every `case` is exhaustive and non-redundant, by the usefulness
//!    algorithm over the tree's own patterns;
//! 3. no local name is bound twice in a declaration, and every top-level
//!    name, type name and constructor name is unique (§2.4) and outside
//!    every language's keyword list;
//! 4. every module imports only modules before it, so the graph is a DAG;
//! 5. nothing outside §2.1 occurs (arity ≥ 1, saturated calls, unary pipe
//!    stages, `foldl` over a literal lambda, `Var`s only where bound);
//! 6. the program still type-checks with every annotation removed: a small
//!    Hindley–Milner over each SCC, monomorphic `let` (V3), and each
//!    recorded signature an instance of the inferred one (§6.2).
//!
//! The first failure is written to `diag` and returned as `error.Invalid`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tree = @import("Tree.zig");
const TypeStore = @import("Type.zig");
const Type = TypeStore.Type;
const names = @import("names.zig");
const analyse = @import("analyse.zig");

pub const Error = error{ Invalid, OutOfMemory, WriteFailed };

const V = struct {
    t: *Tree,
    diag: *std.Io.Writer,
    a: Allocator,
    fn_id: u32 = 0,
    in_scope: []bool,
    bound: []bool,

    fn fail(v: *V, comptime fmt: []const u8, args: anytype) Error {
        const f = v.t.fns.items[v.fn_id];
        try v.diag.print("oracle: module {s}, declaration {s}: ", .{ v.t.modules.items[f.module].name, f.name });
        try v.diag.print(fmt ++ "\n", args);
        return error.Invalid;
    }
};

pub fn check(t: *Tree, diag: *std.Io.Writer) Error!void {
    var v: V = .{
        .t = t,
        .diag = diag,
        .a = t.arena,
        .in_scope = try t.arena.alloc(bool, t.locals.items.len),
        .bound = try t.arena.alloc(bool, t.locals.items.len),
    };
    @memset(v.in_scope, false);
    @memset(v.bound, false);
    try checkNames(&v);
    try checkImports(&v);
    for (t.fns.items, 0..) |f, fi| {
        v.fn_id = @intCast(fi);
        if (f.params.len == 0) return v.fail("arity 0 (§2.4: top-level declarations are functions)", .{});
        const names_seen = try t.arena.alloc(bool, 4096);
        @memset(names_seen, false);
        for (f.params) |p| try bind(&v, p, names_seen);
        const got = try checkExpr(&v, f.body, f.nvars, names_seen);
        if (got != f.ret) return v.fail("body type does not match the declared result", .{});
        for (f.params) |p| try checkTypeVars(&v, t.locals.items[p].ty, f.nvars);
        for (f.params) |p| v.in_scope[p] = false;
    }
    try hindleyMilner(&v);
}

fn bind(v: *V, l: u32, seen: []bool) Error!void {
    if (v.bound[l]) return v.fail("local v{d} bound twice", .{v.t.locals.items[l].name});
    v.bound[l] = true;
    const nm = v.t.locals.items[l].name;
    if (nm >= seen.len) return v.fail("too many locals", .{});
    if (seen[nm]) return v.fail("local name v{d} shadows another (§2.4)", .{nm});
    seen[nm] = true;
    v.in_scope[l] = true;
}

fn checkTypeVars(v: *V, ty: Type, nvars: u32) Error!void {
    const s = &v.t.store;
    switch (s.tag(ty)) {
        .int, .float, .string, .bool => {},
        .@"var" => if (s.varIndex(ty) >= nvars) return v.fail("type variable {d} not bound by the declaration", .{s.varIndex(ty)}),
        .pair => {
            try checkTypeVars(v, s.pairParts(ty)[0], nvars);
            try checkTypeVars(v, s.pairParts(ty)[1], nvars);
        },
        .list => try checkTypeVars(v, s.listElem(ty), nvars),
        .func => {
            if (s.funcParams(ty).len == 0) return v.fail("a function type of arity 0", .{});
            for (s.funcParams(ty)) |p| try checkTypeVars(v, p, nvars);
            try checkTypeVars(v, s.funcRet(ty), nvars);
        },
        .named => for (s.namedArgs(ty)) |p| try checkTypeVars(v, p, nvars),
    }
}

fn checkExpr(v: *V, i: u32, nvars: u32, seen: []bool) Error!Type {
    const t = v.t;
    const s = &t.store;
    const e = t.expr(i);
    checkTypeVars(v, e.ty, nvars) catch |err| {
        try v.diag.print("  at node {d} ({t})\n", .{ i, e.tag });
        return err;
    };
    const want: Type = switch (e.tag) {
        .lit_int => .int,
        .lit_float => .float,
        .lit_string => .string,
        .lit_bool => .bool,
        .local => blk: {
            if (!v.in_scope[e.a]) return v.fail("local v{d} read out of scope", .{t.locals.items[e.a].name});
            break :blk t.locals.items[e.a].ty;
        },
        .global => blk: {
            const f = t.fns.items[e.a];
            const targs = t.extraList(e.b);
            if (targs.len != f.nvars) return v.fail("{s} instantiated with {d} type arguments", .{ f.name, targs.len });
            if (f.entry and t.modules.items[t.fns.items[v.fn_id].module].kind != .main) return v.fail("entry referenced outside Main", .{});
            const sig = try f.sigType(t, s, v.a);
            break :blk try s.subst(v.a, sig, @ptrCast(targs));
        },
        .call => blk: {
            const fty = try checkExpr(v, e.a, nvars, seen);
            if (s.tag(fty) != .func) return v.fail("call of a non-function", .{});
            const args = t.extraList(e.b);
            const ps = s.funcParams(fty);
            if (args.len != ps.len) return v.fail("unsaturated call: {d} of {d} arguments", .{ args.len, ps.len });
            var ptys: [16]Type = undefined;
            @memcpy(ptys[0..ps.len], ps);
            const ret = s.funcRet(fty);
            for (args, 0..) |x, k| if (try checkExpr(v, x, nvars, seen) != ptys[k]) return v.fail("argument {d} has the wrong type", .{k});
            break :blk ret;
        },
        .lambda => blk: {
            const ps = t.extraList(e.a);
            if (ps.len == 0) return v.fail("lambda of arity 0", .{});
            var ptys: [16]Type = undefined;
            for (ps, 0..) |p, k| {
                try bind(v, p, seen);
                ptys[k] = t.locals.items[p].ty;
            }
            const body = try checkExpr(v, e.b, nvars, seen);
            for (ps) |p| v.in_scope[p] = false;
            break :blk try s.func(v.a, ptys[0..ps.len], body);
        },
        .let => blk: {
            const xs = t.extraPairs(e.a);
            var k: usize = 0;
            while (k < xs.len) : (k += 2) {
                const vt = try checkExpr(v, xs[k + 1], nvars, seen);
                if (vt != t.locals.items[xs[k]].ty) return v.fail("let binding v{d} has the wrong type", .{t.locals.items[xs[k]].name});
                if (s.hasVars(vt) and s.tag(vt) == .func) {
                    // A let-bound function over the declaration's own
                    // variables is still monomorphic here: it is used at
                    // exactly its one type, which HM checks below.
                }
                try bind(v, xs[k], seen);
            }
            const body = try checkExpr(v, e.b, nvars, seen);
            k = 0;
            while (k < xs.len) : (k += 2) v.in_scope[xs[k]] = false;
            break :blk body;
        },
        .@"if" => blk: {
            if (try checkExpr(v, e.a, nvars, seen) != .bool) return v.fail("if condition is not Bool", .{});
            const a = try checkExpr(v, t.extra.items[e.b], nvars, seen);
            const b = try checkExpr(v, t.extra.items[e.b + 1], nvars, seen);
            if (a != b) return v.fail("if branches differ", .{});
            break :blk a;
        },
        .case => blk: {
            const sty = try checkExpr(v, e.a, nvars, seen);
            const sc = t.expr(e.a);
            if (!(sc.tag == .local or (sc.tag == .pair and t.expr(sc.a).tag == .local and t.expr(sc.b).tag == .local)))
                return v.fail("case scrutinee is not an in-scope value", .{});
            const xs = t.extraPairs(e.b);
            if (xs.len == 0) return v.fail("case with no branches", .{});
            var rows: std.ArrayList([]const u32) = .empty;
            var k: usize = 0;
            var first: ?Type = null;
            while (k < xs.len) : (k += 2) {
                try checkPat(v, xs[k], sty, nvars);
                if (try useful(v, rows.items, &.{xs[k]}, &.{sty}) == false) return v.fail("case branch {d} is redundant", .{k / 2});
                try rows.append(v.a, try v.a.dupe(u32, &.{xs[k]}));
                const mark = try bindPat(v, xs[k], seen);
                _ = mark;
                const bt = try checkExpr(v, xs[k + 1], nvars, seen);
                unbindPat(v, xs[k]);
                if (first) |f| {
                    if (f != bt) return v.fail("case branches differ", .{});
                } else first = bt;
            }
            if (try useful(v, rows.items, &.{wild_id}, &.{sty})) return v.fail("case is not exhaustive", .{});
            break :blk first.?;
        },
        .ctor => blk: {
            if (s.tag(e.ty) != .named or s.namedDecl(e.ty) != t.ctors.items[e.a].decl) return v.fail("constructor {s} at a foreign type", .{t.ctors.items[e.a].name});
            var ftys: [16]Type = undefined;
            const fs = try t.ctorFields(e.a, e.ty, &ftys);
            const args = t.extraList(e.b);
            if (args.len != fs.len) return v.fail("constructor {s} given {d} of {d} fields", .{ t.ctors.items[e.a].name, args.len, fs.len });
            for (args, 0..) |x, k| if (try checkExpr(v, x, nvars, seen) != fs[k]) return v.fail("constructor {s} field {d} has the wrong type", .{ t.ctors.items[e.a].name, k });
            break :blk e.ty;
        },
        .pair => try s.pair(v.a, try checkExpr(v, e.a, nvars, seen), try checkExpr(v, e.b, nvars, seen)),
        .list => blk: {
            if (s.tag(e.ty) != .list) return v.fail("list literal of a non-list type", .{});
            for (t.extraList(e.a)) |x| if (try checkExpr(v, x, nvars, seen) != s.listElem(e.ty)) return v.fail("list element has the wrong type", .{});
            break :blk e.ty;
        },
        .binop => blk: {
            const want_op = e.op.operand();
            if (try checkExpr(v, e.a, nvars, seen) != want_op or try checkExpr(v, e.b, nvars, seen) != want_op) return v.fail("operator {t} at the wrong operand type", .{e.op});
            if (e.op == .int_eq or e.op == .int_lt or e.op == .str_eq or e.op == .bool_eq or e.op == .float_lt) {
                if (isLit(t, e.a) and isLit(t, e.b)) return v.fail("a comparison of two literals", .{});
            }
            break :blk e.op.result();
        },
        .not => blk: {
            if (try checkExpr(v, e.a, nvars, seen) != .bool) return v.fail("not of a non-Bool", .{});
            break :blk .bool;
        },
        .int_to_string => blk: {
            if (try checkExpr(v, e.a, nvars, seen) != .int) return v.fail("Int to String of a non-Int", .{});
            break :blk .string;
        },
        .list_map, .list_filter => blk: {
            const xs = try checkExpr(v, e.a, nvars, seen);
            const f = try checkExpr(v, e.b, nvars, seen);
            if (s.tag(xs) != .list or s.tag(f) != .func or s.funcParams(f).len != 1 or s.funcParams(f)[0] != s.listElem(xs)) return v.fail("map/filter at the wrong types", .{});
            if (e.tag == .list_filter) {
                if (s.funcRet(f) != .bool) return v.fail("filter predicate is not Bool", .{});
                break :blk xs;
            }
            break :blk try s.list(v.a, s.funcRet(f));
        },
        .list_foldl => blk: {
            const xs = try checkExpr(v, e.a, nvars, seen);
            const z = try checkExpr(v, t.extra.items[e.b], nvars, seen);
            const lam = t.extra.items[e.b + 1];
            if (t.expr(lam).tag != .lambda) return v.fail("foldl's function is not a lambda (§2.3)", .{});
            const f = try checkExpr(v, lam, nvars, seen);
            if (s.tag(xs) != .list) return v.fail("foldl over a non-list", .{});
            const want_f = try s.func(v.a, &.{ s.listElem(xs), z }, z);
            if (f != want_f) return v.fail("foldl's function has the wrong type", .{});
            break :blk z;
        },
        .pipe => blk: {
            var cur = try checkExpr(v, e.a, nvars, seen);
            for (t.extraList(e.b)) |st| {
                if (t.expr(st).tag != .global) return v.fail("pipe stage is not a top-level function", .{});
                const f = try checkExpr(v, st, nvars, seen);
                if (s.funcParams(f).len != 1 or s.funcParams(f)[0] != cur) return v.fail("pipe stage is not unary at the carried type", .{});
                cur = s.funcRet(f);
            }
            break :blk cur;
        },
    };
    if (want != e.ty) return v.fail("node {d} ({t}) records a type its children do not give", .{ i, e.tag });
    return want;
}

fn isLit(t: *const Tree, i: u32) bool {
    return switch (t.expr(i).tag) {
        .lit_int, .lit_float, .lit_string, .lit_bool => true,
        else => false,
    };
}

fn checkPat(v: *V, p: u32, ty: Type, nvars: u32) Error!void {
    const t = v.t;
    const s = &t.store;
    const pt = t.pat(p);
    if (pt.ty != ty) return v.fail("pattern of the wrong type", .{});
    try checkTypeVars(v, ty, nvars);
    switch (pt.tag) {
        .wild => {},
        .bind => if (t.locals.items[pt.a].ty != ty) return v.fail("pattern binding of the wrong type", .{}),
        .lit_int => if (ty != .int) return v.fail("Int literal pattern at a non-Int", .{}),
        .lit_string => if (ty != .string) return v.fail("String literal pattern at a non-String", .{}),
        .lit_bool => if (ty != .bool) return v.fail("Bool pattern at a non-Bool", .{}),
        .ctor => {
            if (s.tag(ty) != .named or s.namedDecl(ty) != t.ctors.items[pt.a].decl) return v.fail("constructor pattern at a foreign type", .{});
            var ftys: [16]Type = undefined;
            const fs = try t.ctorFields(pt.a, ty, &ftys);
            const subs = t.extraList(pt.b);
            if (subs.len != fs.len) return v.fail("constructor pattern arity", .{});
            for (subs, 0..) |c, k| try checkPat(v, c, fs[k], nvars);
        },
        .pair => {
            if (s.tag(ty) != .pair) return v.fail("pair pattern at a non-pair", .{});
            const parts = s.pairParts(ty);
            try checkPat(v, pt.a, parts[0], nvars);
            try checkPat(v, pt.b, parts[1], nvars);
        },
    }
}

fn bindPat(v: *V, p: u32, seen: []bool) Error!void {
    const pt = v.t.pat(p);
    switch (pt.tag) {
        .bind => try bind(v, pt.a, seen),
        .ctor => for (v.t.extraList(pt.b)) |c| try bindPat(v, c, seen),
        .pair => {
            try bindPat(v, pt.a, seen);
            try bindPat(v, pt.b, seen);
        },
        else => {},
    }
}

fn unbindPat(v: *V, p: u32) void {
    const pt = v.t.pat(p);
    switch (pt.tag) {
        .bind => v.in_scope[pt.a] = false,
        .ctor => for (v.t.extraList(pt.b)) |c| unbindPat(v, c),
        .pair => {
            unbindPat(v, pt.a);
            unbindPat(v, pt.b);
        },
        else => {},
    }
}

// ---- usefulness (Maranget), for exhaustiveness and redundancy ----

const wild_id: u32 = std.math.maxInt(u32);

fn isWild(t: *const Tree, p: u32) bool {
    if (p == wild_id) return true;
    const tag = t.pat(p).tag;
    return tag == .wild or tag == .bind;
}

/// A head constructor: which constructor or literal a pattern starts with.
const Head = struct { kind: enum { ctor, lit, pair }, val: u32 };

fn headOf(t: *const Tree, p: u32) Head {
    const pt = t.pat(p);
    return switch (pt.tag) {
        .ctor => .{ .kind = .ctor, .val = pt.a },
        .lit_int, .lit_string, .lit_bool => .{ .kind = .lit, .val = pt.a },
        .pair => .{ .kind = .pair, .val = 0 },
        else => unreachable,
    };
}

fn arity(t: *const Tree, h: Head) usize {
    return switch (h.kind) {
        .ctor => t.ctors.items[h.val].fields.len,
        .lit => 0,
        .pair => 2,
    };
}

fn subTypes(v: *V, h: Head, ty: Type, out: []Type) Error![]Type {
    const t = v.t;
    return switch (h.kind) {
        .ctor => try t.ctorFields(h.val, ty, out),
        .lit => out[0..0],
        .pair => blk: {
            out[0] = t.store.pairParts(ty)[0];
            out[1] = t.store.pairParts(ty)[1];
            break :blk out[0..2];
        },
    };
}

/// The row specialised by `h`, or null when the row's head is another
/// constructor.
fn specialise(v: *V, row: []const u32, h: Head) Error!?[]const u32 {
    const t = v.t;
    const n = arity(t, h);
    const out = try v.a.alloc(u32, n + row.len - 1);
    if (isWild(t, row[0])) {
        @memset(out[0..n], wild_id);
    } else {
        const rh = headOf(t, row[0]);
        if (rh.kind != h.kind or rh.val != h.val) return null;
        const pt = t.pat(row[0]);
        switch (pt.tag) {
            .ctor => @memcpy(out[0..n], t.extraList(pt.b)),
            .pair => {
                out[0] = pt.a;
                out[1] = pt.b;
            },
            else => {},
        }
    }
    @memcpy(out[n..], row[1..]);
    return out;
}

fn useful(v: *V, rows: []const []const u32, q: []const u32, tys: []const Type) Error!bool {
    const t = v.t;
    const s = &t.store;
    if (q.len == 0) return rows.len == 0;
    const ty = tys[0];
    if (!isWild(t, q[0])) {
        const h = headOf(t, q[0]);
        return usefulUnder(v, rows, q, tys, h);
    }
    // The heads present in the first column.
    var heads: std.ArrayList(Head) = .empty;
    for (rows) |r| {
        if (isWild(t, r[0])) continue;
        const h = headOf(t, r[0]);
        var dup = false;
        for (heads.items) |x| dup = dup or (x.kind == h.kind and x.val == h.val);
        if (!dup) try heads.append(v.a, h);
    }
    const complete = switch (s.tag(ty)) {
        .named => heads.items.len == t.types.items[s.namedDecl(ty)].ctors.items.len,
        .bool => heads.items.len == 2,
        .pair => heads.items.len == 1,
        else => false,
    };
    if (complete) {
        for (heads.items) |h| if (try usefulUnder(v, rows, q, tys, h)) return true;
        return false;
    }
    // The default matrix: rows whose head is a wildcard.
    var def: std.ArrayList([]const u32) = .empty;
    for (rows) |r| if (isWild(t, r[0])) try def.append(v.a, r[1..]);
    return useful(v, def.items, q[1..], tys[1..]);
}

fn usefulUnder(v: *V, rows: []const []const u32, q: []const u32, tys: []const Type, h: Head) Error!bool {
    var spec: std.ArrayList([]const u32) = .empty;
    for (rows) |r| if (try specialise(v, r, h)) |x| try spec.append(v.a, x);
    const sq = (try specialise(v, q, h)).?;
    var sub: [16]Type = undefined;
    const st = try subTypes(v, h, tys[0], &sub);
    const ntys = try v.a.alloc(Type, st.len + tys.len - 1);
    @memcpy(ntys[0..st.len], st);
    @memcpy(ntys[st.len..], tys[1..]);
    return useful(v, spec.items, sq, ntys);
}

// ---- names and imports ----

fn checkNames(v: *V) Error!void {
    const t = v.t;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (t.fns.items, 0..) |f, fi| {
        v.fn_id = @intCast(fi);
        if (names.isKeyword(f.name)) return v.fail("name {s} is a keyword", .{f.name});
        if (f.entry) continue;
        const gop = try seen.getOrPut(v.a, f.name);
        if (gop.found_existing) return v.fail("function name {s} is not unique", .{f.name});
    }
    for (t.types.items) |d| {
        const gop = try seen.getOrPut(v.a, d.name);
        if (gop.found_existing) return v.fail("type name {s} is not unique", .{d.name});
    }
    for (t.ctors.items) |c| {
        if (names.isKeyword(c.name)) return v.fail("constructor {s} is a keyword", .{c.name});
        const gop = try seen.getOrPut(v.a, c.name);
        if (gop.found_existing) return v.fail("constructor name {s} is not unique (Roc's tags are global)", .{c.name});
    }
}

fn checkImports(v: *V) Error!void {
    for (v.t.modules.items, 0..) |m, mi| {
        for (m.imports.items) |j| {
            if (j >= mi) {
                try v.diag.print("oracle: module {s} imports {s}, which is not before it: the graph is not a DAG\n", .{ m.name, v.t.modules.items[j].name });
                return error.Invalid;
            }
            const other = v.t.modules.items[j];
            if (m.kind == .unit and other.kind == .unit and other.family != m.family) {
                try v.diag.print("oracle: module {s} imports {s} of another family (§4)\n", .{ m.name, other.name });
                return error.Invalid;
            }
        }
    }
}

// ---- Hindley–Milner with every annotation removed (§6.2) ----

const HTag = enum(u8) { hvar, skolem, int, float, string, bool, pair, list, func, named };

const HNode = struct {
    tag: HTag,
    /// hvar: link (self when unbound); skolem: index; named: decl.
    a: u32 = 0,
    /// Children in `kids`: [start, len]. func: params then ret.
    start: u32 = 0,
    len: u32 = 0,
};

const HM = struct {
    v: *V,
    nodes: std.ArrayList(HNode) = .empty,
    kids: std.ArrayList(u32) = .empty,
    env: []u32, // local -> node
    /// Per function: its generalised scheme (a node; quantified = all
    /// unbound vars reachable from it, since the environment is closed).
    scheme: []u32,
    scc_of: []u32,
    current_scc: u32 = std.math.maxInt(u32),
    /// Roc's numeric literals (§19 V2): a literal is a fresh variable, and
    /// an arithmetic operator unifies its operands instead of fixing their
    /// type. `literals` records each literal node with its variable.
    roc: bool = false,
    /// PureScript's type classes (§19 V10): operators do not fix their
    /// operand type but constrain it; `classes` records each constrained var.
    classy: bool = false,
    classes: std.ArrayList(u32) = .empty,
    /// Per function: a member of a mutually recursive group of two or more.
    multi: []bool = &.{},
    literals: std.ArrayList([2]u32) = .empty,
    pat_literals: std.ArrayList([2]u32) = .empty,
    early: std.ArrayList(u32) = .empty,

    fn fresh(h: *HM) !u32 {
        const i: u32 = @intCast(h.nodes.items.len);
        try h.nodes.append(h.v.a, .{ .tag = .hvar, .a = i });
        return i;
    }

    fn con(h: *HM, tag: HTag, a: u32, ks: []const u32) !u32 {
        const i: u32 = @intCast(h.nodes.items.len);
        const start: u32 = @intCast(h.kids.items.len);
        try h.kids.appendSlice(h.v.a, ks);
        try h.nodes.append(h.v.a, .{ .tag = tag, .a = a, .start = start, .len = @intCast(ks.len) });
        return i;
    }

    fn kidsOf(h: *HM, n: u32) []const u32 {
        const x = h.nodes.items[n];
        return h.kids.items[x.start..][0..x.len];
    }

    fn find(h: *HM, n0: u32) u32 {
        var n = n0;
        while (h.nodes.items[n].tag == .hvar and h.nodes.items[n].a != n) n = h.nodes.items[n].a;
        // Path compression.
        var m = n0;
        while (h.nodes.items[m].tag == .hvar and h.nodes.items[m].a != m) {
            const next = h.nodes.items[m].a;
            h.nodes.items[m].a = n;
            m = next;
        }
        return n;
    }

    fn occurs(h: *HM, x: u32, n0: u32) bool {
        const n = h.find(n0);
        if (n == x) return true;
        const node = h.nodes.items[n];
        if (node.tag == .hvar) return false;
        var k: u32 = 0;
        while (k < node.len) : (k += 1) if (h.occurs(x, h.kids.items[node.start + k])) return true;
        return false;
    }

    fn unify(h: *HM, a0: u32, b0: u32) bool {
        const a = h.find(a0);
        const b = h.find(b0);
        if (a == b) return true;
        const na = h.nodes.items[a];
        const nb = h.nodes.items[b];
        if (na.tag == .hvar) {
            if (h.occurs(a, b)) return false;
            h.nodes.items[a].a = b;
            return true;
        }
        if (nb.tag == .hvar) return h.unify(b, a);
        if (na.tag != nb.tag or na.a != nb.a or na.len != nb.len) return false;
        var k: u32 = 0;
        while (k < na.len) : (k += 1) {
            if (!h.unify(h.kids.items[na.start + k], h.kids.items[nb.start + k])) return false;
        }
        return true;
    }

    /// A store type as an HM node; `Var(i)` is `vars[i]`.
    fn fromType(h: *HM, ty: Type, vars: []const u32) Error!u32 {
        const s = &h.v.t.store;
        return switch (s.tag(ty)) {
            .int => h.con(.int, 0, &.{}),
            .float => h.con(.float, 0, &.{}),
            .string => h.con(.string, 0, &.{}),
            .bool => h.con(.bool, 0, &.{}),
            .@"var" => vars[s.varIndex(ty)],
            .pair => blk: {
                const p = s.pairParts(ty);
                const x = try h.fromType(p[0], vars);
                const y = try h.fromType(p[1], vars);
                break :blk h.con(.pair, 0, &.{ x, y });
            },
            .list => blk: {
                const x = try h.fromType(s.listElem(ty), vars);
                break :blk h.con(.list, 0, &.{x});
            },
            .func => blk: {
                var src: [17]Type = undefined;
                const ps = s.funcParams(ty);
                @memcpy(src[0..ps.len], ps);
                src[ps.len] = s.funcRet(ty);
                var ks: [17]u32 = undefined;
                for (src[0 .. ps.len + 1], 0..) |p, k| ks[k] = try h.fromType(p, vars);
                break :blk h.con(.func, 0, ks[0 .. ps.len + 1]);
            },
            .named => blk: {
                var src: [8]Type = undefined;
                const as = s.namedArgs(ty);
                @memcpy(src[0..as.len], as);
                var ks: [8]u32 = undefined;
                for (src[0..as.len], 0..) |p, k| ks[k] = try h.fromType(p, vars);
                break :blk h.con(.named, s.namedDecl(ty), ks[0..as.len]);
            },
        };
    }

    /// A fresh copy of a generalised type: every unbound var is quantified.
    fn instantiate(h: *HM, n: u32, map: *std.AutoHashMapUnmanaged(u32, u32)) Error!u32 {
        const r = h.find(n);
        const node = h.nodes.items[r];
        if (node.tag == .hvar) {
            const gop = try map.getOrPut(h.v.a, r);
            if (!gop.found_existing) gop.value_ptr.* = try h.fresh();
            return gop.value_ptr.*;
        }
        if (node.len == 0) return r;
        var ks: [17]u32 = undefined;
        var k: u32 = 0;
        while (k < node.len) : (k += 1) ks[k] = try h.instantiate(h.kids.items[h.nodes.items[r].start + k], map);
        return h.con(node.tag, node.a, ks[0..node.len]);
    }

    fn ctorScheme(h: *HM, c: u32) Error!struct { fields: [16]u32, n: usize, result: u32 } {
        const t = h.v.t;
        const d = t.types.items[t.ctors.items[c].decl];
        var vars: [8]u32 = undefined;
        for (0..d.nparams) |k| vars[k] = try h.fresh();
        var out: [16]u32 = undefined;
        const fs = t.ctors.items[c].fields;
        for (fs, 0..) |f, k| out[k] = try h.fromType(f, vars[0..d.nparams]);
        const result = try h.con(.named, t.ctors.items[c].decl, vars[0..d.nparams]);
        return .{ .fields = out, .n = fs.len, .result = result };
    }

    fn infer(h: *HM, i: u32) Error!u32 {
        const t = h.v.t;
        const e = t.expr(i);
        switch (e.tag) {
            .lit_int, .lit_float => {
                if (h.roc) {
                    const x = try h.fresh();
                    try h.literals.append(h.v.a, .{ i, x });
                    return x;
                }
                return h.con(if (e.tag == .lit_int) .int else .float, 0, &.{});
            },
            .lit_string => return h.con(.string, 0, &.{}),
            .lit_bool => return h.con(.bool, 0, &.{}),
            .local => return h.env[e.a],
            .global => {
                if (h.scc_of[e.a] == h.current_scc) return h.scheme[e.a];
                // Elm does not generalise an unannotated mutually recursive
                // group (§19 V9): every use outside it shares one type.
                if (!h.roc and h.multi[e.a]) return h.scheme[e.a];
                var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
                return h.instantiate(h.scheme[e.a], &map);
            },
            .call => {
                const f = try h.infer(e.a);
                var ks: [17]u32 = undefined;
                const args = t.extraList(e.b);
                for (args, 0..) |x, k| ks[k] = try h.infer(x);
                const r = try h.fresh();
                ks[args.len] = r;
                const want = try h.con(.func, 0, ks[0 .. args.len + 1]);
                if (!h.unify(f, want)) return h.v.fail("inferred: call does not unify", .{});
                return r;
            },
            .lambda => {
                const ps = t.extraList(e.a);
                var ks: [17]u32 = undefined;
                for (ps, 0..) |p, k| {
                    ks[k] = try h.fresh();
                    h.env[p] = ks[k];
                }
                ks[ps.len] = try h.infer(e.b);
                return h.con(.func, 0, ks[0 .. ps.len + 1]);
            },
            .let => {
                const xs = t.extraPairs(e.a);
                var k: usize = 0;
                while (k < xs.len) : (k += 2) {
                    const lit0 = h.literals.items.len;
                    h.env[xs[k]] = try h.infer(xs[k + 1]); // monomorphic (V3)
                    // Roc defaults a literal at the end of the `let` it is in
                    // when nothing so far fixes it, before any later use does.
                    if (h.roc) for (h.literals.items[lit0..]) |lv| {
                        if (h.nodes.items[h.find(lv[1])].tag == .hvar) try h.early.append(h.v.a, lv[0]);
                    };
                }
                return h.infer(e.b);
            },
            .@"if" => {
                const c = try h.infer(e.a);
                if (!h.unify(c, try h.con(.bool, 0, &.{}))) return h.v.fail("inferred: if condition", .{});
                const a = try h.infer(t.extra.items[e.b]);
                const b = try h.infer(t.extra.items[e.b + 1]);
                if (!h.unify(a, b)) return h.v.fail("inferred: if branches", .{});
                return a;
            },
            .case => {
                const s = try h.infer(e.a);
                const xs = t.extraPairs(e.b);
                const r = try h.fresh();
                var k: usize = 0;
                while (k < xs.len) : (k += 2) {
                    const p = try h.inferPat(xs[k]);
                    if (!h.unify(p, s)) return h.v.fail("inferred: pattern {d}", .{k / 2});
                    if (!h.unify(r, try h.infer(xs[k + 1]))) return h.v.fail("inferred: case branch {d}", .{k / 2});
                }
                return r;
            },
            .ctor => {
                const sc = try h.ctorScheme(e.a);
                for (t.extraList(e.b), 0..) |x, k| if (!h.unify(sc.fields[k], try h.infer(x))) return h.v.fail("inferred: constructor field {d}", .{k});
                return sc.result;
            },
            .pair => {
                const a = try h.infer(e.a);
                const b = try h.infer(e.b);
                return h.con(.pair, 0, &.{ a, b });
            },
            .list => {
                const el = try h.fresh();
                for (t.extraList(e.a)) |x| if (!h.unify(el, try h.infer(x))) return h.v.fail("inferred: list element", .{});
                return h.con(.list, 0, &.{el});
            },
            .binop => {
                if (h.classy) {
                    const a = try h.infer(e.a);
                    if (!h.unify(a, try h.infer(e.b))) return h.v.fail("inferred (classes): operator {t}", .{e.op});
                    try h.classes.append(h.v.a, a);
                    return if (e.op.result() == .bool and e.op.operand() != .bool) h.con(.bool, 0, &.{}) else a;
                }
                if (h.roc and e.op.operand() != .string and e.op.operand() != .bool) {
                    // The left operand is the method's receiver: Roc dispatches
                    // on its type as it meets it, so a literal receiver is
                    // defaulted unless it is already fixed. Always suffix it.
                    var recv = e.a;
                    while (h.v.t.expr(recv).tag == .binop and h.v.t.expr(recv).op.operand() == e.op.operand()) recv = h.v.t.expr(recv).a;
                    const rt = h.v.t.expr(recv).tag;
                    if (rt == .lit_int or rt == .lit_float) try h.early.append(h.v.a, recv);
                    const a = try h.infer(e.a);
                    if (!h.unify(a, try h.infer(e.b))) return h.v.fail("inferred (Roc): operator {t}", .{e.op});
                    return if (e.op.result() == .bool) h.con(.bool, 0, &.{}) else a;
                }
                const opd = try h.fromType(e.op.operand(), &.{});
                if (!h.unify(opd, try h.infer(e.a)) or !h.unify(opd, try h.infer(e.b))) return h.v.fail("inferred: operator {t}", .{e.op});
                return h.fromType(e.op.result(), &.{});
            },
            .not => {
                if (h.classy) {
                    const a = try h.infer(e.a);
                    try h.classes.append(h.v.a, a);
                    return a;
                }
                if (!h.unify(try h.infer(e.a), try h.con(.bool, 0, &.{}))) return h.v.fail("inferred: not", .{});
                return h.con(.bool, 0, &.{});
            },
            .int_to_string => {
                if (h.classy) {
                    try h.classes.append(h.v.a, try h.infer(e.a));
                    return h.con(.string, 0, &.{});
                }
                if (!h.unify(try h.infer(e.a), try h.con(.int, 0, &.{}))) return h.v.fail("inferred: Int to String", .{});
                return h.con(.string, 0, &.{});
            },
            .list_map, .list_filter => {
                const xs = try h.infer(e.a);
                const f = try h.infer(e.b);
                const a = try h.fresh();
                const b = if (e.tag == .list_map) try h.fresh() else try h.con(.bool, 0, &.{});
                if (!h.unify(xs, try h.con(.list, 0, &.{a}))) return h.v.fail("inferred: map/filter list", .{});
                if (!h.unify(f, try h.con(.func, 0, &.{ a, b }))) return h.v.fail("inferred: map/filter function", .{});
                return if (e.tag == .list_map) h.con(.list, 0, &.{b}) else xs;
            },
            .list_foldl => {
                const xs = try h.infer(e.a);
                const z = try h.infer(t.extra.items[e.b]);
                const f = try h.infer(t.extra.items[e.b + 1]);
                const a = try h.fresh();
                if (!h.unify(xs, try h.con(.list, 0, &.{a}))) return h.v.fail("inferred: foldl list", .{});
                if (!h.unify(f, try h.con(.func, 0, &.{ a, z, z }))) return h.v.fail("inferred: foldl function", .{});
                return z;
            },
            .pipe => {
                var cur = try h.infer(e.a);
                for (t.extraList(e.b)) |st| {
                    const f = try h.infer(st);
                    const r = try h.fresh();
                    if (!h.unify(f, try h.con(.func, 0, &.{ cur, r }))) return h.v.fail("inferred: pipe stage", .{});
                    cur = r;
                }
                return cur;
            },
        }
    }

    fn inferPat(h: *HM, p: u32) Error!u32 {
        const t = h.v.t;
        const pt = t.pat(p);
        switch (pt.tag) {
            .wild => return h.fresh(),
            .bind => {
                const x = try h.fresh();
                h.env[pt.a] = x;
                return x;
            },
            .lit_int => {
                if (h.roc) {
                    const x = try h.fresh();
                    try h.pat_literals.append(h.v.a, .{ p, x });
                    return x;
                }
                return h.con(.int, 0, &.{});
            },
            .lit_string => return h.con(.string, 0, &.{}),
            .lit_bool => return h.con(.bool, 0, &.{}),
            .ctor => {
                const sc = try h.ctorScheme(pt.a);
                for (t.extraList(pt.b), 0..) |c, k| if (!h.unify(sc.fields[k], try h.inferPat(c))) return h.v.fail("inferred: constructor pattern", .{});
                return sc.result;
            },
            .pair => {
                const a = try h.inferPat(pt.a);
                const b = try h.inferPat(pt.b);
                return h.con(.pair, 0, &.{ a, b });
            },
        }
    }
};

fn hindleyMilner(v: *V) Error!void {
    const t = v.t;
    const nf = t.fns.items.len;
    var h: HM = .{
        .v = v,
        .env = try v.a.alloc(u32, t.locals.items.len),
        .scheme = try v.a.alloc(u32, nf),
        .scc_of = try v.a.alloc(u32, nf),
    };
    // SCCs per module, callees first (Tarjan's emission order).
    const order = try sccOrder(v);
    h.multi = try v.a.alloc(bool, nf);
    @memset(h.multi, false);
    {
        var i: usize = 0;
        while (i < order.len) {
            var j = i;
            while (j < order.len and order[j].scc == order[i].scc) j += 1;
            if (j - i > 1) for (order[i..j]) |m| {
                h.multi[m.f] = true;
            };
            i = j;
        }
    }
    var scc_id: u32 = 0;
    var k: usize = 0;
    while (k < order.len) {
        var end = k;
        while (end < order.len and order[end].scc == order[k].scc) end += 1;
        const members = order[k..end];
        h.current_scc = scc_id;
        for (members) |m| {
            h.scc_of[m.f] = scc_id;
            h.scheme[m.f] = try h.fresh();
        }
        for (members) |m| {
            v.fn_id = m.f;
            const f = t.fns.items[m.f];
            var ks: [17]u32 = undefined;
            for (f.params, 0..) |p, j| {
                ks[j] = try h.fresh();
                h.env[p] = ks[j];
            }
            ks[f.params.len] = try h.infer(f.body);
            const ty = try h.con(.func, 0, ks[0 .. f.params.len + 1]);
            if (!h.unify(h.scheme[m.f], ty)) return v.fail("inferred: the group does not unify", .{});
        }
        // Each recorded signature must be an instance of the inferred
        // (generalised) type: its variables are rigid.
        for (members) |m| {
            v.fn_id = m.f;
            const f = t.fns.items[m.f];
            var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
            const inst = try h.instantiate(h.scheme[m.f], &map);
            var sk: [8]u32 = undefined;
            for (0..f.nvars) |j| sk[j] = try h.con(.skolem, @intCast(j), &.{});
            const sig = try h.fromType(try f.sigType(t, &t.store, v.a), sk[0..f.nvars]);
            if (!h.unify(inst, sig)) return v.fail("without annotations the declaration infers a type its signature is not an instance of (§6.2)", .{});
        }
        scc_id += 1;
        k = end;
    }
}

const Ordered = struct { f: u32, scc: u32 };

fn sccOrder(v: *V) Error![]Ordered {
    const t = v.t;
    const a = v.a;
    const n = t.fns.items.len;
    const adj = try a.alloc([]const u32, n);
    for (0..n) |f| {
        var out: std.ArrayList(u32) = .empty;
        const Ctx = struct { t: *const Tree, out: *std.ArrayList(u32), a: Allocator, m: u32 };
        analyse.walk(t, t.fns.items[f].body, Ctx{ .t = t, .out = &out, .a = a, .m = t.fns.items[f].module }, struct {
            fn visit(c: Ctx, i: u32) void {
                const e = c.t.expr(i);
                if (e.tag == .global and c.t.fns.items[e.a].module == c.m) c.out.append(c.a, e.a) catch @panic("oom");
            }
        }.visit);
        adj[f] = out.items;
    }
    const index = try a.alloc(i64, n);
    const low = try a.alloc(i64, n);
    const on = try a.alloc(bool, n);
    @memset(index, -1);
    @memset(on, false);
    var stack: std.ArrayList(u32) = .empty;
    var result: std.ArrayList(Ordered) = .empty;
    var counter: i64 = 0;
    var scc: u32 = 0;
    const S = struct {
        fn strong(al: Allocator, w0: u32, ix: []i64, lo: []i64, onst: []bool, st: *std.ArrayList(u32), ctr: *i64, ad: []const []const u32, res: *std.ArrayList(Ordered), sc: *u32) Error!void {
            ix[w0] = ctr.*;
            lo[w0] = ctr.*;
            ctr.* += 1;
            try st.append(al, w0);
            onst[w0] = true;
            for (ad[w0]) |w| {
                if (ix[w] == -1) {
                    try strong(al, w, ix, lo, onst, st, ctr, ad, res, sc);
                    lo[w0] = @min(lo[w0], lo[w]);
                } else if (onst[w]) lo[w0] = @min(lo[w0], ix[w]);
            }
            if (lo[w0] == ix[w0]) {
                while (true) {
                    const w = st.pop().?;
                    onst[w] = false;
                    try res.append(al, .{ .f = w, .scc = sc.* });
                    if (w == w0) break;
                }
                sc.* += 1;
            }
        }
    };
    // Modules in order (each only references earlier ones), and within a
    // module Tarjan's order, which emits callees before callers.
    for (t.modules.items) |m| for (m.fns.items) |f| if (index[f] == -1) try S.strong(a, f, index, low, on, &stack, &counter, adj, &result, &scc);
    return result.items;
}

/// Which numeric literals Roc would give its default type (`Dec`) because
/// nothing in their definition determines one, which is a warning there
/// (§19 V2). The Roc printer writes a type suffix on exactly these. Signatures
/// count only where they are printed (the tree's `annotated`), so the answer
/// depends on the mode. `exprs[i]` and `pats[i]` are set for literal nodes.
pub const Defaulted = struct { exprs: []bool, pats: []bool };

pub fn rocDefaulted(t: *Tree) Error!Defaulted {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var v: V = .{ .t = t, .diag = &sink.writer, .a = t.arena, .in_scope = &.{}, .bound = &.{} };
    const nf = t.fns.items.len;
    var h: HM = .{
        .v = &v,
        .env = try v.a.alloc(u32, t.locals.items.len),
        .scheme = try v.a.alloc(u32, nf),
        .scc_of = try v.a.alloc(u32, nf),
        .roc = true,
    };
    const out: Defaulted = .{ .exprs = try v.a.alloc(bool, t.exprs.len), .pats = try v.a.alloc(bool, t.pats.len) };
    @memset(out.exprs, false);
    @memset(out.pats, false);
    const order = try sccOrder(&v);
    var scc_id: u32 = 0;
    var k: usize = 0;
    while (k < order.len) {
        var end = k;
        while (end < order.len and order[end].scc == order[k].scc) end += 1;
        const members = order[k..end];
        h.current_scc = scc_id;
        const lit0 = h.literals.items.len;
        const pat0 = h.pat_literals.items.len;
        for (members) |m| {
            h.scc_of[m.f] = scc_id;
            h.scheme[m.f] = try h.fresh();
            const f = t.fns.items[m.f];
            if (f.annotated or f.entry or f.library) {
                var fv: [8]u32 = undefined;
                for (0..f.nvars) |j| fv[j] = try h.fresh();
                const sig = try h.fromType(try f.sigType(t, &t.store, v.a), fv[0..f.nvars]);
                _ = h.unify(h.scheme[m.f], sig);
            }
        }
        for (members) |m| {
            v.fn_id = m.f;
            const f = t.fns.items[m.f];
            var ks: [17]u32 = undefined;
            for (f.params, 0..) |p, j| {
                ks[j] = try h.fresh();
                h.env[p] = ks[j];
            }
            ks[f.params.len] = try h.infer(f.body);
            const ty = try h.con(.func, 0, ks[0 .. f.params.len + 1]);
            if (!h.unify(h.scheme[m.f], ty)) return v.fail("inferred (Roc): the group does not unify", .{});
        }
        // A literal whose type is still open after its group may be
        // defaulted, depending on how Roc generalises the group and on
        // every caller; the rule is conservative and suffixes them all.
        // A suffix always agrees with the tree, so over-marking is safe.
        // In a mutually recursive group Roc solves one member before the
        // next, so a literal fixed only through a later member is defaulted
        // first: every literal of such a group is suffixed.
        const group = members.len > 1;
        for (h.literals.items[lit0..]) |lv| {
            if (group or h.nodes.items[h.find(lv[1])].tag == .hvar) out.exprs[lv[0]] = true;
        }
        for (h.pat_literals.items[pat0..]) |lv| {
            if (group or h.nodes.items[h.find(lv[1])].tag == .hvar) out.pats[lv[0]] = true;
        }
        for (h.early.items) |e| out.exprs[e] = true;
        h.early.clearRetainingCapacity();
        scc_id += 1;
        k = end;
    }
    return out;
}

/// Which `let` and lambda binders PureScript needs a type on (§19 V10). With
/// type classes an operator constrains its operand type instead of fixing
/// it, so a constrained type that nothing determines and that is not part of
/// its declaration's type is ambiguous there: a lambda passed to a
/// parameter its callee ignores, `\v -> v && v`. The PureScript printer
/// writes the type of each binder marked here. `[i]` is per local.
pub const PsTyped = struct {
    /// Per local: a lambda or `let` binder that needs a type.
    binders: []bool,
    /// Per function: needs its signature even in the inferred mode.
    sigs: []bool,
};

pub fn psAmbiguous(t: *Tree) Error!PsTyped {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var v: V = .{ .t = t, .diag = &sink.writer, .a = t.arena, .in_scope = &.{}, .bound = &.{} };
    const nf = t.fns.items.len;
    var h: HM = .{
        .v = &v,
        .env = try v.a.alloc(u32, t.locals.items.len),
        .scheme = try v.a.alloc(u32, nf),
        .scc_of = try v.a.alloc(u32, nf),
        .classy = true,
    };
    @memset(h.env, std.math.maxInt(u32));
    h.multi = try v.a.alloc(bool, nf);
    @memset(h.multi, false);
    const out = try v.a.alloc(bool, t.locals.items.len);
    @memset(out, false);
    const sigs = try v.a.alloc(bool, nf);
    @memset(sigs, false);
    const order = try sccOrder(&v);
    var scc_id: u32 = 0;
    var k: usize = 0;
    while (k < order.len) {
        var end = k;
        while (end < order.len and order[end].scc == order[k].scc) end += 1;
        const members = order[k..end];
        h.current_scc = scc_id;
        const cls0 = h.classes.items.len;
        const loc0: u32 = @intCast(t.locals.items.len);
        _ = loc0;
        for (members) |m| {
            h.scc_of[m.f] = scc_id;
            h.scheme[m.f] = try h.fresh();
            const f = t.fns.items[m.f];
            if (f.annotated or f.entry or f.library) {
                var fv: [8]u32 = undefined;
                for (0..f.nvars) |j| fv[j] = try h.fresh();
                const sig = try h.fromType(try f.sigType(t, &t.store, v.a), fv[0..f.nvars]);
                _ = h.unify(h.scheme[m.f], sig);
            }
        }
        for (members) |m| {
            v.fn_id = m.f;
            const f = t.fns.items[m.f];
            var ks: [17]u32 = undefined;
            for (f.params, 0..) |p, j| {
                ks[j] = try h.fresh();
                h.env[p] = ks[j];
            }
            ks[f.params.len] = try h.infer(f.body);
            const ty = try h.con(.func, 0, ks[0 .. f.params.len + 1]);
            if (!h.unify(h.scheme[m.f], ty)) return v.fail("inferred (classes): the group does not unify", .{});
        }
        for (h.classes.items[cls0..]) |cv| {
            const r = h.find(cv);
            if (h.nodes.items[r].tag != .hvar) continue;
            var generic = false;
            for (members) |m| generic = generic or h.occurs(r, h.scheme[m.f]);
            if (generic) {
                // PureScript cannot generalise a constrained type in a
                // recursive group (CannotGeneralizeRecursiveFunction):
                // such a group keeps its signatures.
                if (members.len > 1 or t.fns.items[members[0].f].recursive) for (members) |m| {
                    sigs[m.f] = true;
                };
                continue;
            }
            // Ambiguous: type every lambda or `let` binder of the group
            // whose type holds it.
            for (members) |m| {
                const Ctx = struct { h: *HM, r: u32, out: []bool };
                analyse.walk(t, t.fns.items[m.f].body, Ctx{ .h = &h, .r = r, .out = out }, struct {
                    fn visit(c: Ctx, i: u32) void {
                        const tt = c.h.v.t;
                        const x = tt.expr(i);
                        const binders: []const u32 = switch (x.tag) {
                            .lambda => tt.extraList(x.a),
                            else => &.{},
                        };
                        for (binders) |l| if (c.h.env[l] != std.math.maxInt(u32) and c.h.occurs(c.r, c.h.env[l])) {
                            c.out[l] = true;
                        };
                        if (x.tag == .let) {
                            const xs = tt.extraPairs(x.a);
                            var q: usize = 0;
                            while (q < xs.len) : (q += 2) {
                                const l = xs[q];
                                if (c.h.env[l] != std.math.maxInt(u32) and c.h.occurs(c.r, c.h.env[l])) c.out[l] = true;
                            }
                        }
                    }
                }.visit);
            }
        }
        scc_id += 1;
        k = end;
    }
    return .{ .binders = out, .sigs = sigs };
}
