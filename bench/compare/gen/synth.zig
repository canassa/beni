//! Type-directed expression and pattern synthesis
//! (docs/design/compare-bench.md §3.5, §3.6).
//!
//! `synth(want, depth)` picks the target type first and then builds an
//! expression only from productions that yield it, so every expression is
//! well-typed by construction. Two budgets bound it: `depth` falls with
//! nesting, and `budget` (nodes left in the current declaration) falls with
//! every node made. When either is spent only leaves are built: a local, a
//! literal, `[]`, a lambda over a leaf, or the minimum-depth constructor
//! path (§3.3), which makes synthesis terminate.
//!
//! Inside a generic declaration a value of type `Var(i)` is only ever a
//! local: every generic declaration has a parameter of each of its
//! variables, so a leaf of `Var(i)` always exists.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tree = @import("Tree.zig");
const TypeStore = @import("Type.zig");
const Type = TypeStore.Type;
const Rng = @import("Rng.zig");
const analyse = @import("analyse.zig");

/// Relative weights of the productions (§3.5); each family sets its own.
pub const Weights = struct {
    local: u32 = 30,
    call: u32 = 25,
    call_local: u32 = 10,
    ctor: u32 = 15,
    literal: u32 = 10,
    pair: u32 = 8,
    list: u32 = 6,
    binop: u32 = 12,
    cmp: u32 = 6,
    not: u32 = 2,
    to_string: u32 = 4,
    @"if": u32 = 6,
    case: u32 = 6,
    let: u32 = 5,
    fn_ref: u32 = 3,
    list_map: u32 = 0,
    list_filter: u32 = 0,
    list_foldl: u32 = 0,
    pipe: u32 = 0,
};

const Prod = enum { local, call, call_local, ctor, literal, pair, list, binop, cmp, not, to_string, @"if", case, let, fn_ref, list_map, list_filter, list_foldl, pipe };

pub const Gen = struct {
    t: *Tree,
    rng: *Rng,
    module: u32,
    w: Weights = .{},
    /// Functions a body may call: Base, the imported units, and this
    /// module's finished functions.
    visible_fns: std.ArrayList(u32) = .empty,
    /// Types whose constructors a body may use.
    visible_types: std.ArrayList(u32) = .empty,
    /// Concrete types to draw from when a type must be chosen.
    pool: std.ArrayList(Type) = .empty,
    /// Cap on a `case`'s leaves (§3.6) and its split depth.
    max_leaves: u32 = 12,
    split_depth: u32 = 2,
    /// Bindings in a synthesised `let`.
    let_min: u32 = 1,
    let_max: u32 = 2,
    /// Percentage of `let` bindings that bind a lambda, whose parameter
    /// types are then fixed only by later uses (the inference family).
    fn_binding_pct: u32 = 0,

    // Per declaration.
    nvars: u32 = 0,
    scope: std.ArrayList(u32) = .empty,
    /// Locals whose constructor or value the enclosing code already fixed:
    /// the scrutinee of an enclosing `case`, the condition of an enclosing
    /// `if`, a `let` of a constructor or literal. Gleam infers their variant
    /// and warns on a `case` over them (§19 V2), so none is split again.
    known: std.ArrayList(u32) = .empty,
    next_name: u32 = 0,
    budget: i64 = 0,

    pub fn gpa(g: *Gen) Allocator {
        return g.t.arena;
    }

    pub fn store(g: *Gen) *TypeStore {
        return &g.t.store;
    }

    /// Start a declaration with `nvars` generic variables.
    pub fn beginFn(g: *Gen, nvars: u32, budget: i64) void {
        g.nvars = nvars;
        g.scope.clearRetainingCapacity();
        g.known.clearRetainingCapacity();
        g.next_name = 0;
        g.budget = budget;
    }

    pub fn freshLocal(g: *Gen, ty: Type) !u32 {
        const l = try g.t.addLocal(g.next_name, ty);
        g.next_name += 1;
        return l;
    }

    /// A local whose value is known only at run time (`Tree.Local.dynamic`).
    pub fn freshDyn(g: *Gen, ty: Type) !u32 {
        const l = try g.freshLocal(ty);
        g.t.locals.items[l].dynamic = true;
        return l;
    }

    /// Whether `e` reads a local known only at run time. A `let` binding's
    /// value does not count: analysis drops the binding if nothing uses it.
    pub fn refersDynamic(g: *Gen, e: u32, limit: u32) bool {
        const t = g.t;
        const x = t.expr(e);
        return switch (x.tag) {
            .local => x.a < limit and t.locals.items[x.a].dynamic,
            .lit_int, .lit_float, .lit_string, .lit_bool, .global => false,
            .let => g.refersDynamic(x.b, limit),
            .lambda => g.refersDynamic(x.b, limit),
            .case => blk: {
                if (g.refersDynamic(x.a, limit)) break :blk true;
                const xs = t.extraPairs(x.b);
                var k: usize = 1;
                while (k < xs.len) : (k += 2) if (g.refersDynamic(xs[k], limit)) break :blk true;
                break :blk false;
            },
            .@"if" => g.refersDynamic(x.a, limit) or g.refersDynamic(t.extra.items[x.b], limit) or g.refersDynamic(t.extra.items[x.b + 1], limit),
            .call => blk: {
                const callee = t.expr(x.a);
                const closure = callee.tag == .local and t.locals.items[callee.a].closure;
                if (!closure and g.refersDynamic(x.a, limit)) break :blk true;
                for (t.extraList(x.b)) |c| if (g.refersDynamic(c, limit)) break :blk true;
                break :blk false;
            },
            .ctor, .list => blk: {
                for (t.extraList(if (x.tag == .ctor) x.b else x.a)) |c| if (g.refersDynamic(c, limit)) break :blk true;
                break :blk false;
            },
            .pair, .binop, .list_map, .list_filter => g.refersDynamic(x.a, limit) or g.refersDynamic(x.b, limit),
            .not, .int_to_string => g.refersDynamic(x.a, limit),
            .list_foldl => g.refersDynamic(x.a, limit) or g.refersDynamic(t.extra.items[x.b], limit) or g.refersDynamic(t.extra.items[x.b + 1], limit),
            .pipe => g.refersDynamic(x.a, limit),
        };
    }

    pub fn push(g: *Gen, l: u32) !void {
        try g.scope.append(g.gpa(), l);
    }

    fn spend(g: *Gen) void {
        g.budget -= 1;
    }

    // ---- node makers ----

    pub fn mk(g: *Gen, e: Tree.Expr) !u32 {
        g.spend();
        switch (e.tag) {
            .not, .int_to_string, .pair, .binop, .case, .@"if", .call, .list_map, .list_filter, .list_foldl, .pipe => std.debug.assert(e.a != 0 or g.module == 0),
            else => {},
        }
        return g.t.addExpr(e);
    }

    pub fn mkLocal(g: *Gen, l: u32) !u32 {
        return g.mk(.{ .tag = .local, .ty = g.t.locals.items[l].ty, .a = l });
    }

    pub fn mkGlobal(g: *Gen, f: u32, targs: []const Type, ty: Type) !u32 {
        var buf: [9]u32 = undefined;
        buf[0] = @intCast(targs.len);
        for (targs, 0..) |a, i| buf[1 + i] = @backingInt(a);
        const x = try g.t.addExtra(buf[0 .. 1 + targs.len]);
        return g.mk(.{ .tag = .global, .ty = ty, .a = f, .b = x });
    }

    pub fn mkCall(g: *Gen, callee: u32, args: []const u32, ty: Type) !u32 {
        const x = try g.listExtra(args);
        return g.mk(.{ .tag = .call, .ty = ty, .a = callee, .b = x });
    }

    pub fn listExtra(g: *Gen, items: []const u32) !u32 {
        const x = try g.t.addExtra(&.{@intCast(items.len)});
        _ = try g.t.addExtra(items);
        return x;
    }

    pub fn mkCtor(g: *Gen, ctor: u32, args: []const u32, ty: Type) !u32 {
        return g.mk(.{ .tag = .ctor, .ty = ty, .a = ctor, .b = try g.listExtra(args) });
    }

    pub fn mkLit(g: *Gen, ty: Type) !u32 {
        return switch (ty) {
            .int => g.mk(.{ .tag = .lit_int, .ty = .int, .a = g.rng.range(1, 99) }),
            .float => g.mk(.{ .tag = .lit_float, .ty = .float, .a = g.rng.range(0, 99), .b = g.rng.range(1, 9) }),
            .string => g.mk(.{ .tag = .lit_string, .ty = .string, .a = g.rng.range(0, 999) }),
            .bool => g.mk(.{ .tag = .lit_bool, .ty = .bool, .a = g.rng.below(2) }),
            else => unreachable,
        };
    }

    /// A call of `f` at the given instantiation, arguments synthesised.
    pub fn callFn(g: *Gen, f: u32, targs: []const Type, depth: u32) !u32 {
        const s = g.store();
        const fd = g.t.fns.items[f];
        var ptys: [16]Type = undefined;
        for (fd.params, 0..) |p, i| ptys[i] = try s.subst(g.gpa(), g.t.locals.items[p].ty, targs);
        const ret = try s.subst(g.gpa(), fd.ret, targs);
        const fty = try s.func(g.gpa(), ptys[0..fd.params.len], ret);
        const callee = try g.mkGlobal(f, targs, fty);
        const limit: u32 = @intCast(g.t.locals.items.len);
        var args: [16]u32 = undefined;
        const n = fd.params.len;
        for (0..n) |i| {
            // A parameter the callee ignores leaves its argument's type to the
            // argument alone. With an operator in it that type is constrained
            // and undetermined: ambiguous in PureScript, defaulted to `Dec`
            // in Roc (§19 V10). Such an argument is a leaf.
            args[i] = if (fd.ready and !g.paramUsed(f, i)) try g.leaf(ptys[i]) else try g.synth(ptys[i], depth -| 1);
        }
        if (!fd.library and !g.anyDynamic(args[0..n], limit)) {
            // Roc evaluates a call whose arguments are all known at compile
            // time, and a generated function evaluated so can overflow or
            // fail to terminate (§19 V2). Pass a run-time value instead.
            if (!try g.forceDynamic(ptys[0..n], args[0..n], depth)) return g.leaf(ret);
        }
        return g.mkCall(callee, args[0..n], ret);
    }

    /// Whether `f`'s body reads its `i`-th parameter.
    pub fn paramUsed(g: *Gen, f: u32, i: usize) bool {
        const fd = g.t.fns.items[f];
        const p = fd.params[i];
        const Ctx = struct { t: *const Tree, p: u32, found: *bool };
        var found = false;
        analyse.walk(g.t, fd.body, Ctx{ .t = g.t, .p = p, .found = &found }, struct {
            fn visit(c: Ctx, e: u32) void {
                const x = c.t.expr(e);
                if (x.tag == .local and x.a == c.p) c.found.* = true;
            }
        }.visit);
        return found;
    }

    fn anyDynamic(g: *Gen, args: []const u32, limit: u32) bool {
        for (args) |a| if (g.refersDynamic(a, limit)) return true;
        return false;
    }

    /// Replace one argument by a run-time local of its type, or by a lambda
    /// returning one. False when the scope has neither.
    fn forceDynamic(g: *Gen, ptys: []const Type, args: []u32, depth: u32) !bool {
        _ = depth;
        const s = g.store();
        for (ptys, 0..) |pty, i| if (g.dynLocalOf(pty)) |l| {
            args[i] = try g.mkLocal(l);
            return true;
        };
        for (ptys, 0..) |pty, i| {
            if (s.tag(pty) != .func) continue;
            const l = g.dynLocalOf(s.funcRet(pty)) orelse continue;
            var ps: [16]u32 = undefined;
            const np = s.funcParams(pty).len;
            var pt: [16]Type = undefined;
            @memcpy(pt[0..np], s.funcParams(pty));
            for (0..np) |k| ps[k] = try g.freshDyn(pt[k]);
            const body = try g.mkLocal(l);
            args[i] = try g.mk(.{ .tag = .lambda, .ty = pty, .a = try g.listExtra(ps[0..np]), .b = body });
            return true;
        }
        return false;
    }

    fn dynLocalOf(g: *Gen, want: Type) ?u32 {
        var i = g.scope.items.len;
        while (i > 0) {
            i -= 1;
            const l = g.scope.items[i];
            if (g.t.locals.items[l].dynamic and g.t.locals.items[l].ty == want) return l;
        }
        return null;
    }

    // ---- choosing types ----

    pub fn pick(g: *Gen, comptime T: type, items: []const T) T {
        return items[g.rng.below(@intCast(items.len))];
    }

    /// A type for a binding or an unconstrained instantiation: often the
    /// type of something already in scope, so the body can use it.
    pub fn chooseType(g: *Gen) Type {
        if (g.scope.items.len > 0 and g.rng.chance(45)) {
            const l = g.pick(u32, g.scope.items);
            const ty = g.t.locals.items[l].ty;
            if (g.store().tag(ty) != .func) return ty;
        }
        if (g.nvars > 0 and g.rng.chance(30)) return g.store().tvar(g.gpa(), g.rng.below(g.nvars)) catch unreachable;
        return g.pick(Type, g.pool.items);
    }

    /// Bind the callee's variables by matching `pattern` (callee terms)
    /// against `target` (caller terms, whose `Var`s are rigid). Returns
    /// false when they cannot match.
    pub fn match(g: *Gen, pattern: Type, target: Type, binds: []?Type) bool {
        const s = g.store();
        const pt = s.tag(pattern);
        if (pt == .@"var") {
            const i = s.varIndex(pattern);
            if (binds[i]) |b| return b == target;
            binds[i] = target;
            return true;
        }
        if (pt != s.tag(target)) return false;
        return switch (pt) {
            .int, .float, .string, .bool => true,
            .@"var" => unreachable,
            .pair => g.match(s.pairParts(pattern)[0], s.pairParts(target)[0], binds) and
                g.match(s.pairParts(pattern)[1], s.pairParts(target)[1], binds),
            .list => g.match(s.listElem(pattern), s.listElem(target), binds),
            .func => blk: {
                const pp = s.funcParams(pattern);
                const tp = s.funcParams(target);
                if (pp.len != tp.len) break :blk false;
                for (pp, tp) |a, b| if (!g.match(a, b, binds)) break :blk false;
                break :blk g.match(s.funcRet(pattern), s.funcRet(target), binds);
            },
            .named => blk: {
                if (s.namedDecl(pattern) != s.namedDecl(target)) break :blk false;
                for (s.namedArgs(pattern), s.namedArgs(target)) |a, b| if (!g.match(a, b, binds)) break :blk false;
                break :blk true;
            },
        };
    }

    fn fillUnbound(g: *Gen, binds: []?Type, out: []Type) void {
        for (binds, 0..) |b, i| out[i] = b orelse g.chooseType();
    }

    // ---- synthesis ----

    pub fn synth(g: *Gen, want: Type, depth: u32) Allocator.Error!u32 {
        if (depth == 0 or g.budget <= 0) return g.leaf(want);
        const s = g.store();
        switch (s.tag(want)) {
            .@"var" => return g.leaf(want),
            .func => {
                if (g.rng.chance(g.w.fn_ref)) if (try g.tryFnRef(want)) |e| return e;
                if (g.rng.chance(15)) if (g.localOf(want)) |l| return g.mkLocal(l);
                return g.lambda(want, depth);
            },
            else => {},
        }
        var weights: [@typeInfo(Prod).@"enum".field_names.len]u32 = undefined;
        inline for (@typeInfo(Prod).@"enum".field_names, 0..) |field_name, i| weights[i] = @field(g.w, field_name);
        g.gate(want, &weights);
        var tries: u32 = 0;
        while (tries < 8) : (tries += 1) {
            var any = false;
            for (weights) |x| any = any or x > 0;
            if (!any) break;
            const p: Prod = @fromBackingInt(@intCast(g.rng.weighted(&weights)));
            if (try g.produce(p, want, depth)) |e| return e;
            weights[@backingInt(p)] = 0;
        }
        return g.leaf(want);
    }

    /// Zero the weights of productions that cannot yield `want`.
    fn gate(g: *Gen, want: Type, weights: []u32) void {
        const s = g.store();
        const tag = s.tag(want);
        const W = struct {
            fn off(ws: []u32, p: Prod) void {
                ws[@backingInt(p)] = 0;
            }
        };
        if (tag != .named) W.off(weights, .ctor);
        if (!(tag == .int or tag == .float or tag == .string or tag == .bool)) W.off(weights, .literal);
        if (tag != .pair) W.off(weights, .pair);
        if (tag != .list) {
            W.off(weights, .list);
            W.off(weights, .list_map);
            W.off(weights, .list_filter);
        }
        if (!(tag == .int or tag == .float or tag == .string or tag == .bool)) W.off(weights, .binop);
        if (tag != .bool) {
            W.off(weights, .cmp);
            W.off(weights, .not);
        }
        if (tag != .string) W.off(weights, .to_string);
        W.off(weights, .fn_ref);
        // Wrapping forms multiply the tree; only while budget remains.
        if (g.budget < 12) {
            W.off(weights, .@"if");
            W.off(weights, .case);
            W.off(weights, .let);
            W.off(weights, .list_foldl);
            W.off(weights, .pipe);
        }
    }

    fn produce(g: *Gen, p: Prod, want: Type, depth: u32) !?u32 {
        const s = g.store();
        switch (p) {
            .local => {
                const l = g.localOf(want) orelse return null;
                return try g.mkLocal(l);
            },
            .call => return g.tryCall(want, depth),
            .call_local => return g.tryCallLocal(want, depth),
            .ctor => {
                const decl = s.namedDecl(want);
                const d = g.t.types.items[decl];
                const c = if (depth <= 1) d.min_ctor else g.pick(u32, d.ctors.items);
                return try g.ctorAt(c, want, depth);
            },
            .literal => return try g.mkLit(want),
            .pair => {
                const parts = s.pairParts(want);
                const a = try g.synth(parts[0], depth -| 1);
                const b = try g.synth(parts[1], depth -| 1);
                return try g.mk(.{ .tag = .pair, .ty = want, .a = a, .b = b });
            },
            .list => {
                const n = g.rng.range(0, 3);
                var items: [3]u32 = undefined;
                for (0..n) |i| items[i] = try g.synth(s.listElem(want), depth -| 1);
                return try g.mk(.{ .tag = .list, .ty = want, .a = try g.listExtra(items[0..n]) });
            },
            .binop => {
                const op: Tree.Op = switch (want) {
                    .int => g.pick(Tree.Op, &.{ .int_add, .int_sub, .int_mul }),
                    .float => g.pick(Tree.Op, &.{ .float_add, .float_sub, .float_mul }),
                    .string => .str_append,
                    .bool => g.pick(Tree.Op, &.{ .bool_and, .bool_or }),
                    else => unreachable,
                };
                return try g.binop(op, depth);
            },
            .cmp => return g.tryCmp(depth),
            .not => {
                const a = try g.synth(.bool, depth -| 1);
                return try g.mk(.{ .tag = .not, .ty = .bool, .a = a });
            },
            .to_string => {
                const a = try g.synth(.int, depth -| 1);
                return try g.mk(.{ .tag = .int_to_string, .ty = .string, .a = a });
            },
            .@"if" => return g.ifExpr(want, depth),
            .case => return g.tryCase(want, depth),
            .let => return try g.letExpr(want, depth, g.rng.range(g.let_min, g.let_max)),
            .fn_ref => return null,
            .list_map => {
                const a = g.chooseListElem();
                const b = s.listElem(want);
                const xs = try g.synth(try s.list(g.gpa(), a), depth -| 1);
                const f = try g.lambda(try s.func(g.gpa(), &.{a}, b), depth -| 1);
                return try g.mk(.{ .tag = .list_map, .ty = want, .a = xs, .b = f });
            },
            .list_filter => {
                const xs = try g.synth(want, depth -| 1);
                const f = try g.lambda(try s.func(g.gpa(), &.{s.listElem(want)}, .bool), depth -| 1);
                return try g.mk(.{ .tag = .list_filter, .ty = want, .a = xs, .b = f });
            },
            .list_foldl => {
                if (s.hasFunc(want)) return null;
                const a = g.chooseListElem();
                const xs = try g.synth(try s.list(g.gpa(), a), depth -| 1);
                const z = try g.synth(want, depth -| 1);
                const f = try g.lambda(try s.func(g.gpa(), &.{ a, want }, want), depth -| 1);
                return try g.mk(.{ .tag = .list_foldl, .ty = want, .a = xs, .b = try g.t.addExtra(&.{ z, f }) });
            },
            .pipe => return g.tryPipe(want, depth, g.rng.range(2, 4)),
        }
    }

    fn chooseListElem(g: *Gen) Type {
        // Lists of functions are legal but print badly in no language's
        // favour; keep list elements first-order.
        var tries: u32 = 0;
        while (tries < 8) : (tries += 1) {
            const t = g.chooseType();
            if (!g.store().hasFunc(t)) return t;
        }
        return .int;
    }

    pub fn binop(g: *Gen, op0: Tree.Op, depth: u32) !u32 {
        const limit: u32 = @intCast(g.t.locals.items.len);
        const a = try g.synth(op0.operand(), depth -| 1);
        // Only a product with a run-time factor: Roc folds constants at
        // compile time, and a folded product can overflow `I64` (§19 V2).
        const op: Tree.Op = if (op0 == .int_mul and !g.refersDynamic(a, limit)) .int_add else op0;
        // TypeScript narrows what `a` compares with `===` inside `b`.
        const kmark = g.known.items.len;
        defer g.known.shrinkRetainingCapacity(kmark);
        if (op == .bool_and or op == .bool_or) try g.markCond(a);
        const b = try g.synth(op.operand(), depth -| 1);
        if (op == .bool_and or op == .bool_or) {
            // No literal operand: `false && e` makes `e` unreachable to
            // TypeScript, and a condition Roc can decide (§19 V2, V8).
            const la = g.t.expr(a).tag == .lit_bool;
            const lb = g.t.expr(b).tag == .lit_bool;
            if (la) return b;
            if (lb) return a;
        }
        return g.mk(.{ .tag = .binop, .op = op, .ty = op.result(), .a = a, .b = b });
    }

    /// `x == e` or `x < e` with `x` a local, never two literals (§2.6: a
    /// literal compared with a literal is a TypeScript error).
    fn tryCmp(g: *Gen, depth: u32) !?u32 {
        var cands: [64]u32 = undefined;
        var n: usize = 0;
        for (g.scope.items) |l| {
            const ty = g.t.locals.items[l].ty;
            if (std.mem.indexOfScalar(u32, g.known.items, l) != null) continue;
            // Not `Bool`: `b == True` is no code anyone writes, and TypeScript
            // narrows a boolean through aliases, where `===` then errors.
            if ((ty == .int or ty == .string or ty == .float) and n < cands.len) {
                cands[n] = l;
                n += 1;
            }
        }
        if (n == 0) return null;
        const l = cands[g.rng.below(@intCast(n))];
        const ty = g.t.locals.items[l].ty;
        const op: Tree.Op = switch (ty) {
            .int => g.pick(Tree.Op, &.{ .int_eq, .int_lt }),
            .float => .float_lt,
            .string => .str_eq,
            .bool => .bool_eq,
            else => unreachable,
        };
        const a = try g.mkLocal(l);
        var b = try g.synth(ty, depth -| 1);
        // `x == x` is a warning in Gleam ("redundant comparison").
        // A `let` may collapse to its body in analysis, so none here.
        if ((g.t.expr(b).tag == .local and g.t.expr(b).a == l) or g.t.expr(b).tag == .let) b = try g.mkLit(ty);
        return try g.mk(.{ .tag = .binop, .op = op, .ty = .bool, .a = a, .b = b });
    }

    /// A condition that is not a literal: Gleam prints `if` as a `case`,
    /// and a `case` on a literal is a warning there (§19 V2).
    /// It also reads a value known only at run time: Roc folds anything else
    /// and warns that the condition is known at compile time (§19 V2). Null
    /// when the scope has nothing to build one from.
    pub fn condition(g: *Gen, depth: u32) !?u32 {
        var tries: u32 = 0;
        while (tries < 6) : (tries += 1) {
            const limit: u32 = @intCast(g.t.locals.items.len);
            const c = try g.synth(.bool, depth);
            const ce = g.t.expr(c);
            switch (ce.tag) {
                // A `let` may lose every binding in analysis and become its
                // body, which may be a literal.
                // Nor a bare local: Gleam would then know its value in each
                // branch, and a later `case` on it would be unreachable.
                .lit_bool, .let, .case, .@"if", .local => continue,
                else => {},
            }
            if (!g.refersDynamic(c, limit)) continue;
            return c;
        }
        // A comparison of a run-time local with a literal.
        for (g.scope.items) |l| {
            const ty = g.t.locals.items[l].ty;
            if (!g.t.locals.items[l].dynamic) continue;
            if (std.mem.indexOfScalar(u32, g.known.items, l) != null) continue;
            const op: Tree.Op = switch (ty) {
                .int => .int_lt,
                .float => .float_lt,
                .string => .str_eq,
                else => continue,
            };
            const a = try g.mkLocal(l);
            const b = try g.mkLit(ty);
            return try g.mk(.{ .tag = .binop, .op = op, .ty = .bool, .a = a, .b = b });
        }
        return null;
    }

    /// Mark the locals a condition compares with `==`: TypeScript narrows
    /// them to the literal in the branch, and a later `switch` or `===` on
    /// them with another literal is an error there (§19 V8).
    pub fn markCond(g: *Gen, c: u32) !void {
        const x = g.t.expr(c);
        switch (x.tag) {
            .binop => switch (x.op) {
                .int_eq, .str_eq, .bool_eq => if (g.t.expr(x.a).tag == .local) try g.known.append(g.gpa(), g.t.expr(x.a).a),
                .bool_and, .bool_or => {
                    try g.markCond(x.a);
                    try g.markCond(x.b);
                },
                else => {},
            },
            .not => try g.markCond(x.a),
            // A `Bool` operand of `&&`, `||` or `not` is narrowed to
            // `true` or `false` in the branches as well.
            .local => try g.known.append(g.gpa(), x.a),
            else => {},
        }
    }

    pub fn ifExpr(g: *Gen, want: Type, depth: u32) !?u32 {
        const c = (try g.condition(depth -| 1)) orelse return null;
        const mark = g.known.items.len;
        defer g.known.shrinkRetainingCapacity(mark);
        try g.markCond(c);
        const a = try g.synth(want, depth -| 1);
        const b = try g.synth(want, depth -| 1);
        return try g.mk(.{ .tag = .@"if", .ty = want, .a = c, .b = try g.t.addExtra(&.{ a, b }) });
    }

    pub fn letExpr(g: *Gen, want: Type, depth: u32, n: u32) !u32 {
        const mark = g.scope.items.len;
        defer g.scope.shrinkRetainingCapacity(mark);
        const kmark = g.known.items.len;
        defer g.known.shrinkRetainingCapacity(kmark);
        var pairs: std.ArrayList(u32) = .empty;
        try pairs.append(g.gpa(), n);
        for (0..n) |_| {
            const ty = if (g.rng.chance(g.fn_binding_pct))
                try g.store().func(g.gpa(), &.{g.pick(Type, g.pool.items)}, g.pick(Type, g.pool.items))
            else
                g.chooseType();
            const limit: u32 = @intCast(g.t.locals.items.len);
            const v = try g.synth(ty, depth -| 1);
            const l = try g.freshLocal(ty);
            g.t.locals.items[l].dynamic = g.refersDynamic(v, limit);
            g.t.locals.items[l].closure = g.t.expr(v).tag == .lambda;
            try pairs.appendSlice(g.gpa(), &.{ l, v });
            try g.push(l);
            switch (g.t.expr(v).tag) {
                .ctor, .lit_int, .lit_string, .lit_bool, .lit_float, .local, .let => try g.known.append(g.gpa(), l),
                else => {},
            }
        }
        const body = try g.synth(want, depth -| 1);
        return g.mk(.{ .tag = .let, .ty = want, .a = try g.t.addExtra(pairs.items), .b = body });
    }

    pub fn lambda(g: *Gen, fty: Type, depth: u32) !u32 {
        const s = g.store();
        const mark = g.scope.items.len;
        defer g.scope.shrinkRetainingCapacity(mark);
        var ps: [16]u32 = undefined;
        const params = s.funcParams(fty);
        const n = params.len;
        var ptys: [16]Type = undefined;
        @memcpy(ptys[0..n], params);
        const ret = s.funcRet(fty);
        for (0..n) |i| {
            ps[i] = try g.freshDyn(ptys[i]);
            try g.push(ps[i]);
        }
        const body = try g.synth(ret, depth -| 1);
        return g.mk(.{ .tag = .lambda, .ty = fty, .a = try g.listExtra(ps[0..n]), .b = body });
    }

    pub fn localOf(g: *Gen, want: Type) ?u32 {
        var cands: [64]u32 = undefined;
        var n: usize = 0;
        for (g.scope.items) |l| if (g.t.locals.items[l].ty == want and n < cands.len) {
            cands[n] = l;
            n += 1;
        };
        if (n == 0) return null;
        return cands[g.rng.below(@intCast(n))];
    }

    pub fn ctorAt(g: *Gen, c: u32, want: Type, depth: u32) !u32 {
        var ftys: [16]Type = undefined;
        const fs = try g.t.ctorFields(c, want, &ftys);
        var args: [16]u32 = undefined;
        for (fs, 0..) |f, i| args[i] = try g.synth(f, depth -| 1);
        return g.mkCtor(c, args[0..fs.len], want);
    }

    fn tryCall(g: *Gen, want: Type, depth: u32) !?u32 {
        const Cand = struct { f: u32, targs: [8]Type };
        var cands: std.ArrayList(Cand) = .empty;
        defer cands.deinit(g.gpa());
        for (g.visible_fns.items) |f| {
            const fd = g.t.fns.items[f];
            if (!fd.ready or fd.entry) continue;
            // A function returning a bare variable (`pfst`, `sfold`) fits
            // every type; keep it from crowding out the rest.
            if (g.store().tag(fd.ret) == .@"var" and !g.rng.chance(20)) continue;
            var binds: [8]?Type = @splat(null);
            for (fd.mono_targs, 0..) |x, bi| binds[bi] = x;
            if (!g.match(fd.ret, want, binds[0..fd.nvars])) continue;
            var c: Cand = .{ .f = f, .targs = undefined };
            g.fillUnbound(binds[0..fd.nvars], c.targs[0..fd.nvars]);
            try cands.append(g.gpa(), c);
        }
        if (cands.items.len == 0) return null;
        const c = cands.items[g.rng.below(@intCast(cands.items.len))];
        return try g.callFn(c.f, c.targs[0..g.t.fns.items[c.f].nvars], depth);
    }

    fn tryCallLocal(g: *Gen, want: Type, depth: u32) !?u32 {
        const s = g.store();
        var cands: [32]u32 = undefined;
        var n: usize = 0;
        for (g.scope.items) |l| {
            const ty = g.t.locals.items[l].ty;
            if (s.tag(ty) == .func and s.funcRet(ty) == want and n < cands.len) {
                cands[n] = l;
                n += 1;
            }
        }
        if (n == 0) return null;
        const l = cands[g.rng.below(@intCast(n))];
        const fty = g.t.locals.items[l].ty;
        const callee = try g.mkLocal(l);
        var ptys: [16]Type = undefined;
        const np = s.funcParams(fty).len;
        @memcpy(ptys[0..np], s.funcParams(fty));
        var args: [16]u32 = undefined;
        for (0..np) |i| args[i] = try g.synth(ptys[i], depth -| 1);
        return try g.mkCall(callee, args[0..np], want);
    }

    /// A top-level function used as a value, when its instantiated type is
    /// exactly `want`.
    fn tryFnRef(g: *Gen, want: Type) !?u32 {
        var cands: [64]u32 = undefined;
        var targs: [64][8]Type = undefined;
        var n: usize = 0;
        for (g.visible_fns.items) |f| {
            const fd = g.t.fns.items[f];
            if (!fd.ready or fd.entry or n == cands.len) continue;
            const sig = try fd.sigType(g.t, g.store(), g.gpa());
            var binds: [8]?Type = @splat(null);
            for (fd.mono_targs, 0..) |x, bi| binds[bi] = x;
            if (!g.match(sig, want, binds[0..fd.nvars])) continue;
            var complete = true;
            for (binds[0..fd.nvars], 0..) |b, i| {
                if (b) |x| targs[n][i] = x else complete = false;
            }
            if (!complete) continue;
            cands[n] = f;
            n += 1;
        }
        if (n == 0) return null;
        const k = g.rng.below(@intCast(n));
        return try g.mkGlobal(cands[k], targs[k][0..g.t.fns.items[cands[k]].nvars], want);
    }

    /// `head |> s1 |> … |> sk`, each stage a unary top-level function whose
    /// instance is fixed by the stage after it (§2.2: unary stages only).
    pub fn tryPipe(g: *Gen, want: Type, depth: u32, stages: u32) !?u32 {
        const s = g.store();
        var chain: [64]u32 = undefined;
        var target = want;
        var k: u32 = 0;
        while (k < stages) : (k += 1) {
            var cands: [64]u32 = undefined;
            var ctargs: [64][8]Type = undefined;
            var n: usize = 0;
            for (g.visible_fns.items) |f| {
                const fd = g.t.fns.items[f];
                if (!fd.ready or fd.entry or fd.params.len != 1 or n == cands.len) continue;
                var binds: [8]?Type = @splat(null);
                for (fd.mono_targs, 0..) |x, bi| binds[bi] = x;
                if (!g.match(fd.ret, target, binds[0..fd.nvars])) continue;
                var complete = true;
                for (binds[0..fd.nvars], 0..) |b, i| {
                    if (b) |x| ctargs[n][i] = x else complete = false;
                }
                if (!complete) continue;
                cands[n] = f;
                n += 1;
            }
            if (n == 0) break;
            const j = g.rng.below(@intCast(n));
            const f = cands[j];
            const fd = g.t.fns.items[f];
            const targs = ctargs[j][0..fd.nvars];
            const pty = try s.subst(g.gpa(), g.t.locals.items[fd.params[0]].ty, targs);
            const ret = try s.subst(g.gpa(), fd.ret, targs);
            chain[stages - 1 - k] = try g.mkGlobal(f, targs, try s.func(g.gpa(), &.{pty}, ret));
            target = pty;
        }
        if (k < 2) return null;
        const head = try g.synth(target, depth -| 1);
        const first = stages - k;
        return try g.mk(.{ .tag = .pipe, .ty = want, .a = head, .b = try g.listExtra(chain[first..stages]) });
    }

    // ---- leaves ----

    pub fn leaf(g: *Gen, want: Type) Allocator.Error!u32 {
        const s = g.store();
        if (g.localOf(want)) |l| if (s.tag(want) == .@"var" or g.rng.chance(70)) return g.mkLocal(l);
        return switch (s.tag(want)) {
            .int, .float, .string, .bool => g.mkLit(want),
            .@"var" => unreachable, // every generic declaration binds each variable
            .pair => {
                const p = s.pairParts(want);
                const a = try g.leaf(p[0]);
                const b = try g.leaf(p[1]);
                return g.mk(.{ .tag = .pair, .ty = want, .a = a, .b = b });
            },
            .list => g.mk(.{ .tag = .list, .ty = want, .a = try g.listExtra(&.{}) }),
            .func => g.lambda(want, 0),
            .named => {
                const d = g.t.types.items[s.namedDecl(want)];
                return g.ctorAt(d.min_ctor, want, 0);
            },
        };
    }

    // ---- case and patterns (§3.6) ----

    /// A scrutinee type a `case` may split on.
    pub fn splittable(g: *Gen, ty: Type) bool {
        const s = g.store();
        return switch (s.tag(ty)) {
            .named, .bool, .int, .string => true,
            .pair => g.splittable(s.pairParts(ty)[0]) or g.splittable(s.pairParts(ty)[1]),
            else => false,
        };
    }

    fn tryCase(g: *Gen, want: Type, depth: u32) !?u32 {
        var cands: [64]u32 = undefined;
        var n: usize = 0;
        for (g.scope.items) |l| {
            if (std.mem.indexOfScalar(u32, g.known.items, l) != null) continue;
            if (!g.t.locals.items[l].dynamic) continue;
            if (g.splittable(g.t.locals.items[l].ty) and n < cands.len) {
                cands[n] = l;
                n += 1;
            }
        }
        if (n == 0) return null;
        const l = cands[g.rng.below(@intCast(n))];
        // A case that would not split at the top is not generated: a
        // single wildcard branch checks nothing.
        const lty = g.t.locals.items[l].ty;
        if (g.store().tag(lty) == .named and g.t.types.items[g.store().namedDecl(lty)].ctors.items.len > g.max_leaves) return null;
        const scrut = try g.mkLocal(l);
        return try g.caseOn(scrut, want, depth, g.split_depth, g.max_leaves);
    }

    /// A split tree over the scrutinee's type, flattened to rows; each row's
    /// body is synthesised with that row's bindings in scope.
    pub fn caseOn(g: *Gen, scrut: u32, want: Type, depth: u32, split_depth: u32, max_leaves: u32) !u32 {
        const sty = g.t.expr(scrut).ty;
        var sk = try g.skeleton(sty, split_depth, max_leaves, true);
        var rows: std.ArrayList(u32) = .empty; // pattern ids
        try g.enumerate(&sk, sty, &rows);
        var pairs: std.ArrayList(u32) = .empty;
        try pairs.append(g.gpa(), @intCast(rows.items.len));
        const kmark = g.known.items.len;
        defer g.known.shrinkRetainingCapacity(kmark);
        const se = g.t.expr(scrut);
        if (se.tag == .local) try g.known.append(g.gpa(), se.a);
        if (se.tag == .pair) try g.known.appendSlice(g.gpa(), &.{ g.t.expr(se.a).a, g.t.expr(se.b).a });
        for (rows.items) |p| {
            const mark = g.scope.items.len;
            try g.pushBinds(p);
            const body = try g.synth(want, depth -| 1);
            g.scope.shrinkRetainingCapacity(mark);
            try pairs.appendSlice(g.gpa(), &.{ p, body });
        }
        return g.mk(.{ .tag = .case, .ty = want, .a = scrut, .b = try g.t.addExtra(pairs.items) });
    }

    pub fn pushBinds(g: *Gen, p: u32) !void {
        const pt = g.t.pat(p);
        switch (pt.tag) {
            .bind => try g.push(pt.a),
            .ctor => for (g.t.extraList(pt.b)) |c| try g.pushBinds(c),
            .pair => {
                try g.pushBinds(pt.a);
                try g.pushBinds(pt.b);
            },
            else => {},
        }
    }

    pub const Skel = union(enum) {
        bind,
        /// One child list per constructor, in declaration order.
        split: []const []Skel,
        bools,
        lits: u32,
        product: []Skel,

        pub fn leaves(sk: Skel) u32 {
            return switch (sk) {
                .bind => 1,
                .bools => 2,
                .lits => |k| k + 1,
                .product => |cs| blk: {
                    var n: u32 = 1;
                    for (cs) |c| n *= c.leaves();
                    break :blk n;
                },
                .split => |per| blk: {
                    var n: u32 = 0;
                    for (per) |cs| {
                        var m: u32 = 1;
                        for (cs) |c| m *= c.leaves();
                        n += m;
                    }
                    break :blk n;
                },
            };
        }
    };

    /// A split tree for `ty` with at most `cap` leaves. `force` splits the
    /// top even when the draw would not.
    pub fn skeleton(g: *Gen, ty: Type, depth: u32, cap: u32, force: bool) Allocator.Error!Skel {
        const s = g.store();
        if (cap < 2 or (!force and (depth == 0 or g.rng.chance(40)))) return .bind;
        switch (s.tag(ty)) {
            .bool => return .bools,
            .int, .string => return .{ .lits = g.rng.range(1, @min(3, cap - 1)) },
            .pair => {
                const p = s.pairParts(ty);
                var cs = try g.gpa().alloc(Skel, 2);
                cs[0] = try g.skeleton(p[0], depth, cap, force and !g.splittable(p[1]));
                cs[1] = try g.skeleton(p[1], depth, cap / cs[0].leaves(), force and cs[0] == .bind);
                return .{ .product = cs };
            },
            .named => {
                const d = g.t.types.items[s.namedDecl(ty)];
                const k: u32 = @intCast(d.ctors.items.len);
                if (k > cap) return .bind;
                var spare = cap - k;
                const per = try g.gpa().alloc([]Skel, k);
                for (d.ctors.items, 0..) |c, i| {
                    var ftys: [16]Type = undefined;
                    const fs = try g.t.ctorFields(c, ty, &ftys);
                    per[i] = try g.gpa().alloc(Skel, fs.len);
                    // A share of the spare leaves for this constructor's fields.
                    var budget: u32 = 1 + if (spare > 0 and depth > 1) g.rng.below(spare + 1) else 0;
                    var used: u32 = 1;
                    for (fs, 0..) |f, j| {
                        const sub = try g.skeleton(f, depth - 1, budget, false);
                        per[i][j] = sub;
                        used *= sub.leaves();
                        budget = @max(1, budget / sub.leaves());
                    }
                    spare -= used - 1;
                }
                return .{ .split = per };
            },
            else => return .bind,
        }
    }

    /// Every leaf of the skeleton as a pattern, in order.
    pub fn enumerate(g: *Gen, sk: *const Skel, ty: Type, out: *std.ArrayList(u32)) Allocator.Error!void {
        const s = g.store();
        switch (sk.*) {
            .bind => try out.append(g.gpa(), try g.t.addPat(.{ .tag = .bind, .ty = ty, .a = try g.freshDyn(ty) })),
            .bools => for ([_]u32{ 1, 0 }) |v| try out.append(g.gpa(), try g.t.addPat(.{ .tag = .lit_bool, .ty = .bool, .a = v })),
            .lits => |k| {
                var seen: [4]u32 = undefined;
                var i: u32 = 0;
                while (i < k) {
                    const v = g.rng.range(0, 40);
                    if (std.mem.indexOfScalar(u32, seen[0..i], v) != null) continue;
                    seen[i] = v;
                    i += 1;
                    const tag: Tree.PatTag = if (ty == .int) .lit_int else .lit_string;
                    try out.append(g.gpa(), try g.t.addPat(.{ .tag = tag, .ty = ty, .a = v }));
                }
                try out.append(g.gpa(), try g.t.addPat(.{ .tag = .bind, .ty = ty, .a = try g.freshDyn(ty) }));
            },
            .product => |cs| {
                const p = s.pairParts(ty);
                var left: std.ArrayList(u32) = .empty;
                try g.enumerate(&cs[0], p[0], &left);
                for (left.items, 0..) |l, i| {
                    var right: std.ArrayList(u32) = .empty;
                    try g.enumerate(&cs[1], p[1], &right);
                    // The left pattern's bindings must not be shared between
                    // rows: rebuild it for every row after the first.
                    const lp = if (i == 0) l else l;
                    for (right.items, 0..) |r, j| {
                        const lpat = if (j == 0) lp else try g.clonePat(lp);
                        try out.append(g.gpa(), try g.t.addPat(.{ .tag = .pair, .ty = ty, .a = lpat, .b = r }));
                    }
                }
            },
            .split => |per| {
                const d = g.t.types.items[s.namedDecl(ty)];
                for (d.ctors.items, 0..) |c, i| {
                    var ftys: [16]Type = undefined;
                    const fs = try g.t.ctorFields(c, ty, &ftys);
                    var rows: std.ArrayList([]u32) = .empty;
                    try g.productRows(per[i], fs, &rows);
                    for (rows.items) |args| {
                        try out.append(g.gpa(), try g.t.addPat(.{ .tag = .ctor, .ty = ty, .a = c, .b = try g.listExtraPat(args) }));
                    }
                }
            },
        }
    }

    fn listExtraPat(g: *Gen, items: []const u32) !u32 {
        return g.listExtra(items);
    }

    /// The cartesian product of the fields' enumerations, lexicographic.
    fn productRows(g: *Gen, sks: []const Skel, tys: []const Type, out: *std.ArrayList([]u32)) Allocator.Error!void {
        if (sks.len == 0) {
            try out.append(g.gpa(), &.{});
            return;
        }
        var head: std.ArrayList(u32) = .empty;
        try g.enumerate(&sks[0], tys[0], &head);
        for (head.items, 0..) |h, i| {
            var tails: std.ArrayList([]u32) = .empty;
            try g.productRows(sks[1..], tys[1..], &tails);
            for (tails.items, 0..) |tail, j| {
                const hp = if (j == 0) h else try g.clonePat(h);
                _ = i;
                const row = try g.gpa().alloc(u32, 1 + tail.len);
                row[0] = hp;
                @memcpy(row[1..], tail);
                try out.append(g.gpa(), row);
            }
        }
    }

    /// A copy of a pattern with fresh locals for its bindings.
    fn clonePat(g: *Gen, p: u32) Allocator.Error!u32 {
        const pt = g.t.pat(p);
        switch (pt.tag) {
            .bind => return g.t.addPat(.{ .tag = .bind, .ty = pt.ty, .a = try g.freshDyn(pt.ty) }),
            .ctor => {
                const src = g.t.extraList(pt.b);
                var buf: [16]u32 = undefined;
                const n = src.len;
                @memcpy(buf[0..n], src);
                for (buf[0..n]) |*c| c.* = try g.clonePat(c.*);
                return g.t.addPat(.{ .tag = .ctor, .ty = pt.ty, .a = pt.a, .b = try g.listExtra(buf[0..n]) });
            },
            .pair => {
                const a = try g.clonePat(pt.a);
                const b = try g.clonePat(pt.b);
                return g.t.addPat(.{ .tag = .pair, .ty = pt.ty, .a = a, .b = b });
            },
            else => return g.t.addPat(pt),
        }
    }
};
