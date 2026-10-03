//! The eight families (docs/design/compare-bench.md §4). Each owns one part
//! of the type-checking problem; a unit of a family is one module. The
//! numbers in each generator are the initial calibration of §4 and are part
//! of the generator hash.

const std = @import("std");
const Tree = @import("../Tree.zig");
const TypeStore = @import("../Type.zig");
const Type = TypeStore.Type;
const common = @import("common.zig");
const Unit = common.Unit;

pub const Config = common.Config;

/// Generate unit `u.unit` of `u.family` into `u`'s module, then its entry.
/// `units[k]` is the module of unit k+1 of the same family, for k < unit-1.
pub fn generate(u: *Unit, earlier: []const u32) !void {
    switch (u.family) {
        .inference => try inference(u),
        .polymorphism => try polymorphism(u),
        .patterns => try patterns(u),
        .depth => try depthFamily(u),
        .recursion => try recursion(u),
        .data => try data(u),
        .imports => try imports(u, earlier),
        .everyday => try everyday(u, earlier),
    }
    try u.entry();
}

// ---- inference: long unannotated chains, types flowing backwards ----

fn inference(u: *Unit) !void {
    u.g.w = .{ .call = 20, .call_local = 25, .local = 30, .let = 6, .@"if" = 5, .case = 4, .pair = 10, .ctor = 12 };
    u.g.fn_binding_pct = 40;
    for (0..3) |_| {
        // Every function of a chain returns the chain's type, takes a
        // function it must call, and a value.
        const ret = u.g.pick(Type, &.{ .int, .string, u.seqOf(.int), u.pairOf(.int, .string) });
        var prev: ?u32 = null;
        for (0..12) |i| {
            const a = u.g.pick(Type, u.g.pool.items);
            const b = u.g.pick(Type, &.{ .int, .string, .bool, u.seqOf(.int) });
            const x = u.g.pick(Type, u.g.pool.items);
            const f = try u.declFn(0, &.{ u.funcOf(&.{a}, b), x }, ret);
            try u.enter(f, 40);
            var body: u32 = undefined;
            if (i % 4 != 3) if (prev) |p| {
                body = switch (ret) {
                    .int => try u.g.mk(.{ .tag = .binop, .op = .int_add, .ty = .int, .a = try u.g.callFn(p, &.{}, 3), .b = try u.g.synth(.int, 3) }),
                    .string => try u.g.mk(.{ .tag = .binop, .op = .str_append, .ty = .string, .a = try u.g.callFn(p, &.{}, 3), .b = try u.g.synth(.string, 3) }),
                    else => try chainIf(u, p, ret, null),
                };
            } else {
                body = try u.g.synth(ret, 4);
            };
            if (i % 4 == 3) {
                // A block of bindings whose types come from later uses.
                u.g.budget = 45;
                body = try u.g.letExpr(ret, 3, u.rng.range(6, 10));
                // The chain call stays: the block's body is the call site.
                if (prev) |p| {
                    const lt = u.t.expr(body);
                    const inner = switch (ret) {
                        .int => try u.g.mk(.{ .tag = .binop, .op = .int_add, .ty = .int, .a = try u.g.callFn(p, &.{}, 2), .b = lt.b }),
                        .string => try u.g.mk(.{ .tag = .binop, .op = .str_append, .ty = .string, .a = try u.g.callFn(p, &.{}, 2), .b = lt.b }),
                        // The block's body is already built, so it is the
                        // `then` branch only when no condition could narrow a
                        // local it splits: a pair keeps both instead.
                        else => try u.g.mk(.{ .tag = .pair, .ty = u.pairOf(ret, ret), .a = try u.g.callFn(p, &.{}, 2), .b = lt.b }),
                    };
                    if (u.store().tag(ret) != .int and ret != .string) {
                        // `Base.pfst (call, body)`: both are checked, the call first.
                        const pfst = baseFn(u, "pfst");
                        const targs = [_]Type{ ret, ret };
                        const fty = try u.store().subst(u.arena(), try u.t.fns.items[pfst].sigType(u.t, u.store(), u.arena()), &targs);
                        const callee = try u.g.mkGlobal(pfst, &targs, fty);
                        u.t.exprs.items(.b)[body] = try u.g.mkCall(callee, &.{inner}, ret);
                        try u.define(f, body);
                        prev = f;
                        continue;
                    }
                    u.t.exprs.items(.b)[body] = inner;
                }
            }
            try u.define(f, body);
            prev = f;
        }
    }
}

// ---- polymorphism: generic functions at many instantiations ----

fn polymorphism(u: *Unit) !void {
    u.g.w = .{ .call = 30, .local = 35, .call_local = 25, .ctor = 15, .pair = 10, .@"if" = 4, .case = 5, .let = 4, .binop = 4, .literal = 4 };
    var generics: [8]u32 = undefined;
    for (&generics) |*gf| {
        const nvars = u.rng.range(1, 3);
        var ps: [4]Type = undefined;
        // One parameter of each variable (so a leaf of it exists), then
        // higher-order and structured ones.
        var np: u32 = 0;
        for (0..nvars) |i| {
            ps[np] = u.tv(@intCast(i));
            np += 1;
        }
        const extra = u.rng.range(if (np == 1) 0 else 0, 4 - np);
        for (0..extra) |_| {
            const a = u.tv(u.rng.below(nvars));
            const b = u.tv(u.rng.below(nvars));
            ps[np] = switch (u.rng.below(4)) {
                0 => u.seqOf(a),
                1 => u.funcOf(&.{a}, b),
                2 => u.funcOf(&.{ b, a }, b),
                else => u.pairOf(a, b),
            };
            np += 1;
        }
        const a = u.tv(u.rng.below(nvars));
        const b = u.tv(u.rng.below(nvars));
        const ret = switch (u.rng.below(5)) {
            0 => a,
            1 => u.seqOf(a),
            2 => u.pairOf(a, b),
            3 => u.optOf(b),
            else => u.seqOf(u.pairOf(a, b)),
        };
        gf.* = try u.simpleFn(nvars, ps[0..np], ret, 45, 4);
    }
    // 30 call sites at distinct instantiations, three per use function.
    const insts = [_]Type{
        .int,                                      .string,                .bool,
        .float,                                    u.seqOf(.int),          u.pairOf(.int, u.seqOf(.string)),
        u.seqOf(u.pairOf(.int, u.seqOf(.string))), u.optOf(.string),       u.listOf(.int),
        u.pairOf(.bool, .float),                   u.seqOf(u.optOf(.int)), u.resOf(.string, u.seqOf(.int)),
    };
    var seen: std.AutoHashMapUnmanaged([4]u32, void) = .empty;
    for (0..10) |_| {
        var calls: [3]struct { f: u32, targs: [3]Type, ret: Type } = undefined;
        for (&calls) |*c| {
            while (true) {
                c.f = u.g.pick(u32, &generics);
                const nv = u.t.fns.items[c.f].nvars;
                var key: [4]u32 = @splat(0xffff_ffff);
                key[0] = c.f;
                for (0..nv) |i| {
                    c.targs[i] = u.g.pick(Type, &insts);
                    key[1 + i] = @backingInt(c.targs[i]);
                }
                const gop = try seen.getOrPut(u.arena(), key);
                if (gop.found_existing) continue;
                c.ret = try u.store().subst(u.arena(), u.t.fns.items[c.f].ret, c.targs[0..nv]);
                break;
            }
        }
        const ret = u.pairOf(calls[0].ret, u.pairOf(calls[1].ret, calls[2].ret));
        var ps: [2]Type = undefined;
        const n = u.rng.range(1, 2);
        for (0..n) |i| ps[i] = u.g.pick(Type, u.g.pool.items);
        const f = try u.declFn(0, ps[0..n], ret);
        try u.enter(f, 60);
        var pairs: [7]u32 = undefined;
        pairs[0] = 3;
        var ls: [3]u32 = undefined;
        for (calls, 0..) |c, i| {
            const limit: u32 = @intCast(u.t.locals.items.len);
            const call = try u.g.callFn(c.f, c.targs[0..u.t.fns.items[c.f].nvars], 3);
            ls[i] = try u.g.freshLocal(c.ret);
            u.t.locals.items[ls[i]].dynamic = u.g.refersDynamic(call, limit);
            pairs[1 + 2 * i] = ls[i];
            pairs[2 + 2 * i] = call;
        }
        const inner = try u.g.mk(.{ .tag = .pair, .ty = u.pairOf(calls[1].ret, calls[2].ret), .a = try u.g.mkLocal(ls[1]), .b = try u.g.mkLocal(ls[2]) });
        const out = try u.g.mk(.{ .tag = .pair, .ty = ret, .a = try u.g.mkLocal(ls[0]), .b = inner });
        const body = try u.g.mk(.{ .tag = .let, .ty = ret, .a = try u.t.addExtra(&pairs), .b = out });
        try u.define(f, body);
    }
}

// ---- patterns: wide types, deep exhaustive cases ----

fn patterns(u: *Unit) !void {
    u.g.w = .{ .local = 40, .literal = 30, .binop = 10, .call = 5, .ctor = 5, .@"if" = 0, .case = 0, .let = 0, .to_string = 5, .pair = 3, .list = 2 };
    var wide: [2]Type = undefined;
    for (&wide, 0..) |*w, i| {
        const k = u.rng.range(16, 32);
        var fields: [32][]const Type = undefined;
        for (0..k) |c| {
            const nf = u.rng.range(0, 3);
            const fs = try u.arena().alloc(Type, nf);
            for (fs) |*f| {
                const choices = [_]Type{ .int, .string, .bool, u.seqOf(.int), u.optOf(.bool) };
                f.* = if (i == 1 and u.rng.chance(15)) wide[0] else u.g.pick(Type, &choices);
            }
            fields[c] = fs;
        }
        const d = (try u.declType(0, fields[0..k])).?;
        w.* = try u.store().named(u.arena(), d, &.{});
        try u.g.pool.append(u.arena(), w.*);
    }
    const shapes = [_][]const Type{
        &.{ wide[0], wide[1] },
        &.{ wide[1], wide[0] },
        &.{ u.seqOf(wide[0]), .int },
        &.{ .int, .string },
        &.{ wide[1], u.seqOf(.int) },
    };
    for (0..5) |i| {
        const ps = shapes[(i + u.rng.below(2)) % shapes.len];
        const ret = u.g.pick(Type, &.{ .int, .string, .bool });
        const f = try u.declFn(0, ps, ret);
        try u.enter(f, 400);
        const fd = u.t.fns.items[f];
        const a = try u.g.mkLocal(fd.params[0]);
        const b = try u.g.mkLocal(fd.params[1]);
        const scrut = try u.g.mk(.{ .tag = .pair, .ty = u.pairOf(ps[0], ps[1]), .a = a, .b = b });
        const body = try u.g.caseOn(scrut, ret, 2, u.rng.range(3, 4), 64);
        try u.define(f, body);
    }
}

// ---- depth: long operator chains, nested calls, nesting, pipelines ----

fn depthFamily(u: *Unit) !void {
    u.g.w = .{ .local = 50, .literal = 30, .call = 10, .binop = 5, .@"if" = 0, .case = 0, .let = 0, .ctor = 5, .pair = 2, .list = 1, .to_string = 2 };
    // Unary helpers: the stages of the call chains and pipelines.
    var helpers: std.ArrayList(u32) = .empty;
    const hsig = [_][2]Type{ .{ .int, .int }, .{ .int, .int }, .{ .string, .string }, .{ .int, .string }, .{ .string, .int }, .{ u.seqOf(.int), u.seqOf(.int) }, .{ u.seqOf(.int), .int } };
    for (hsig) |sg| try helpers.append(u.arena(), try u.simpleFn(0, &.{sg[0]}, sg[1], 8, 2));

    // Operator chains of 50–200 operands.
    for (0..3) |_| {
        const op: Tree.Op = u.g.pick(Tree.Op, &.{ .int_add, .int_mul, .str_append, .bool_and, .int_sub, .bool_or });
        const ty = op.operand();
        const f = try u.declFn(0, &.{ ty, ty }, ty);
        try u.enter(f, 1000);
        const n = u.rng.range(50, 200);
        // A parameter first, so every prefix of the chain is known only
        // at run time (Roc folds constant prefixes, §19 V2).
        var acc = try u.g.mkLocal(u.t.fns.items[f].params[0]);
        for (1..n) |_| {
            const o: Tree.Op = switch (ty) {
                .int => u.g.pick(Tree.Op, &.{ .int_add, .int_sub, .int_mul }),
                .bool => u.g.pick(Tree.Op, &.{ .bool_and, .bool_or }),
                else => op,
            };
            const rhs = try u.g.leaf(ty);
            acc = try u.g.mk(.{ .tag = .binop, .op = o, .ty = ty, .a = acc, .b = rhs });
        }
        try u.define(f, acc);
    }
    // Nested calls 20–40 deep through the helpers, and pipelines of 20–50
    // unary stages. Both are built outward from a parameter, so no call in
    // them is known at compile time (§19 V2); the result type is where the
    // chain ends.
    for (0..6) |k| {
        const f = try u.declFn(0, &.{ .int, .string }, .int);
        try u.enter(f, 1000);
        const n = if (k < 3) u.rng.range(20, 40) else u.rng.range(20, 50);
        const start = u.rng.below(2);
        var cur: Type = if (start == 0) .int else .string;
        const head = try u.g.mkLocal(u.t.fns.items[f].params[start]);
        var e = head;
        var stages: std.ArrayList(u32) = .empty;
        for (0..n) |_| {
            var cands: [8]u32 = undefined;
            var m: usize = 0;
            for (helpers.items) |h| if (u.t.locals.items[u.t.fns.items[h].params[0]].ty == cur) {
                cands[m] = h;
                m += 1;
            };
            const h = cands[u.rng.below(@intCast(m))];
            const hd = u.t.fns.items[h];
            const callee = try u.g.mkGlobal(h, &.{}, try hd.sigType(u.t, u.store(), u.arena()));
            if (k < 3) e = try u.g.mkCall(callee, &.{e}, hd.ret) else try stages.append(u.arena(), callee);
            cur = hd.ret;
        }
        if (k >= 3) e = try u.g.mk(.{ .tag = .pipe, .ty = cur, .a = head, .b = try u.g.listExtra(stages.items) });
        u.t.fns.items[f].ret = cur;
        try u.define(f, e);
    }
    // Nested if/let/case 10–20 deep, in tail position.
    for (0..3) |_| {
        const f = try u.declFn(0, &.{ .int, .bool, u.optOf(.int) }, .int);
        try u.enter(f, 1000);
        const n = u.rng.range(10, 20);
        const body = try nest(u, n);
        try u.define(f, body);
    }
}

fn nest(u: *Unit, n: u32) !u32 {
    if (n == 0) return u.g.synth(.int, 2);
    var free: [3]u32 = undefined;
    var nfree: usize = 0;
    for (u.g.scope.items[0..3]) |l| if (std.mem.indexOfScalar(u32, u.g.known.items, l) == null) {
        free[nfree] = l;
        nfree += 1;
    };
    var choice = u.rng.below(3);
    if (choice == 2 and nfree == 0) choice = 0;
    // With every parameter already narrowed there is no condition left.
    const cond: ?u32 = if (choice == 0) try u.g.condition(2) else null;
    if (choice == 0 and cond == null) choice = 1;
    switch (choice) {
        0 => {
            const c = cond.?;
            const kmark = u.g.known.items.len;
            defer u.g.known.shrinkRetainingCapacity(kmark);
            try u.g.markCond(c);
            const inner = try nest(u, n - 1);
            const other = try u.g.synth(.int, 1);
            return u.g.mk(.{ .tag = .@"if", .ty = .int, .a = c, .b = try u.t.addExtra(&.{ other, inner }) });
        },
        1 => {
            const ty = u.g.pick(Type, &.{ .int, .string, .bool });
            const limit: u32 = @intCast(u.t.locals.items.len);
            const v = try u.g.synth(ty, 2);
            const l = try u.g.freshLocal(ty);
            u.t.locals.items[l].dynamic = u.g.refersDynamic(v, limit);
            const mark = u.g.scope.items.len;
            try u.g.push(l);
            const kmark = u.g.known.items.len;
            defer u.g.known.shrinkRetainingCapacity(kmark);
            switch (u.t.expr(v).tag) {
                .ctor, .lit_int, .lit_string, .lit_bool, .local, .let => try u.g.known.append(u.arena(), l),
                else => {},
            }
            const inner = try nest(u, n - 1);
            u.g.scope.shrinkRetainingCapacity(mark);
            return u.g.mk(.{ .tag = .let, .ty = .int, .a = try u.t.addExtra(&.{ 1, l, v }), .b = inner });
        },
        else => {
            // A case whose last branch continues the nest.
            const scrut_l = free[u.rng.below(@intCast(nfree))];
            const kmark = u.g.known.items.len;
            defer u.g.known.shrinkRetainingCapacity(kmark);
            try u.g.known.append(u.arena(), scrut_l);
            const scrut = try u.g.mkLocal(scrut_l);
            const sty = u.t.locals.items[scrut_l].ty;
            var sk = try u.g.skeleton(sty, 1, 4, true);
            var rows: std.ArrayList(u32) = .empty;
            try u.g.enumerate(&sk, sty, &rows);
            var pairs: std.ArrayList(u32) = .empty;
            try pairs.append(u.arena(), @intCast(rows.items.len));
            for (rows.items, 0..) |p, i| {
                const mark = u.g.scope.items.len;
                try u.g.pushBinds(p);
                const body = if (i + 1 == rows.items.len) try nest(u, n - 1) else try u.g.synth(.int, 1);
                u.g.scope.shrinkRetainingCapacity(mark);
                try pairs.appendSlice(u.arena(), &.{ p, body });
            }
            return u.g.mk(.{ .tag = .case, .ty = .int, .a = scrut, .b = try u.t.addExtra(pairs.items) });
        },
    }
}

// ---- recursion: one large mutually recursive group, two small ones ----

fn recursion(u: *Unit) !void {
    u.g.w = .{ .local = 40, .literal = 15, .call = 10, .binop = 10, .ctor = 10, .@"if" = 3, .case = 2, .let = 2, .pair = 3 };
    try scc(u, u.rng.range(24, 48), 1);
    try scc(u, u.rng.range(3, 4), 0);
    try scc(u, u.rng.range(3, 4), 0);
}

/// A strongly connected group: member i calls member i+1 (mod n) and
/// sometimes another, always at the members' own variables (§6.2).
fn scc(u: *Unit, n: u32, nvars: u32) !void {
    const a: Type = if (nvars == 1) u.tv(0) else .int;
    const seq_a = u.seqOf(a);
    const rets = [_]Type{ .int, seq_a, a, .bool, .string };
    var members: [48]u32 = undefined;
    // One result type per group: every member returns what the next one
    // returns, combined with more of the same.
    const ret = u.g.pick(Type, &rets);
    for (0..n) |i| {
        const ps: []const Type = switch (u.rng.below(3)) {
            0 => &.{ seq_a, a },
            1 => &.{ seq_a, a, .int },
            else => &.{ .int, seq_a, a },
        };
        members[i] = try u.declFn(nvars, ps, ret);
    }
    const targs: []const Type = if (nvars == 1) &.{u.tv(0)} else &.{};
    for (0..n) |i| {
        const f = members[i];
        try u.enter(f, 26);
        const fd = u.t.fns.items[f];
        const s_param = for (fd.params) |p| {
            if (u.t.locals.items[p].ty == seq_a) break p;
        } else unreachable;
        try u.g.known.append(u.arena(), s_param);
        // case s of SNil -> leaf; SCons h t -> combine(call next, ...)
        const h = try u.g.freshDyn(a);
        const tl = try u.g.freshDyn(seq_a);
        const nil_p = try u.t.addPat(.{ .tag = .ctor, .ty = seq_a, .a = u.base.snil, .b = try u.g.listExtra(&.{}) });
        const hp = try u.t.addPat(.{ .tag = .bind, .ty = a, .a = h });
        const tp = try u.t.addPat(.{ .tag = .bind, .ty = seq_a, .a = tl });
        const cons_p = try u.t.addPat(.{ .tag = .ctor, .ty = seq_a, .a = u.base.scons, .b = try u.g.listExtra(&.{ hp, tp }) });
        const nil_body = try u.g.synth(fd.ret, 2);
        try u.g.push(h);
        try u.g.push(tl);
        // For a result of the group's variable the two calls meet in an
        // `if`, whose condition comes first (§19 V8).
        var cond: ?u32 = null;
        if (u.store().tag(fd.ret) == .@"var") {
            cond = try u.g.condition(1);
            if (cond) |c| try u.g.markCond(c);
        }
        const next = members[(i + 1) % n];
        var call = try u.g.callFn(next, targs, 2);
        if (u.rng.chance(40)) {
            // A second edge into the group, back or across.
            // Never itself: Gleam calls a parameter that is only passed
            // back to its own function unused (§19 V2).
            const other = members[(i + 1 + u.rng.below(n - 1)) % n];
            const c2 = try u.g.callFn(other, targs, 2);
            call = try combine(u, fd.ret, call, c2, cond);
        } else {
            call = try combine(u, fd.ret, call, try u.g.synth(fd.ret, 2), cond);
        }
        const body = try u.g.mk(.{ .tag = .case, .ty = fd.ret, .a = try u.g.mkLocal(s_param), .b = try u.t.addExtra(&.{ 2, nil_p, nil_body, cons_p, call }) });
        const fdp = &u.t.fns.items[f];
        fdp.body = body;
        fdp.annotated = u.rng.below(100) < u.cfg.annotate;
    }
    // Callable from the rest of the module only once the group is whole,
    // and, when generic, at one instantiation (§19 V9).
    const mono = try u.arena().dupe(Type, if (nvars == 1) &.{Type.int} else &.{});
    for (members[0..n]) |f| {
        u.t.fns.items[f].ready = true;
        u.t.fns.items[f].mono_targs = mono;
        try u.g.visible_fns.append(u.arena(), f);
    }
}

fn combine(u: *Unit, ty: Type, x: u32, y: u32, cond: ?u32) !u32 {
    const s = u.store();
    return switch (s.tag(ty)) {
        .int => u.g.mk(.{ .tag = .binop, .op = .int_add, .ty = ty, .a = x, .b = y }),
        .bool => u.g.mk(.{ .tag = .binop, .op = .bool_or, .ty = ty, .a = x, .b = y }),
        .string => u.g.mk(.{ .tag = .binop, .op = .str_append, .ty = ty, .a = x, .b = y }),
        .named => blk: {
            // Seq a: sappend-free, so build SCons (head of y) x.
            const elem = s.namedArgs(ty)[0];
            const hd = try u.g.leaf(elem);
            break :blk u.g.mkCtor(u.base.scons, &.{ hd, x }, ty);
        },
        else => if (cond) |c|
            u.g.mk(.{ .tag = .@"if", .ty = ty, .a = c, .b = try u.t.addExtra(&.{ x, y }) })
        else
            x,
    };
}

// ---- data: many types and fields, construction and access ----

fn data(u: *Unit) !void {
    u.g.w = .{ .local = 35, .literal = 25, .ctor = 30, .call = 10, .binop = 5, .@"if" = 0, .case = 0, .let = 0, .pair = 3 };
    var decls: [10]u32 = undefined;
    var tys: [10]Type = undefined;
    for (0..10) |i| {
        const k = u.rng.range(1, 4);
        var fields: [4][]const Type = undefined;
        for (0..k) |c| {
            const nf = u.rng.range(2, if (k == 1) 12 else 6);
            const fs = try u.arena().alloc(Type, nf);
            for (fs) |*f| {
                f.* = if (i > 0 and u.rng.chance(20)) tys[u.rng.below(@intCast(i))] else u.g.pick(Type, &.{ .int, .string, .bool, .float, u.seqOf(.int), u.pairOf(.int, .string) });
            }
            fields[c] = fs;
        }
        decls[i] = (try u.declType(0, fields[0..k])).?;
        tys[i] = try u.store().named(u.arena(), decls[i], &.{});
        try u.g.pool.append(u.arena(), tys[i]);
    }
    for (decls, tys) |d, ty| {
        const ctors = u.t.types.items[d].ctors.items;
        // Accessors: one branch per constructor, the field or a leaf.
        for (0..2) |_| {
            const c0 = u.g.pick(u32, ctors);
            const fields = u.t.ctors.items[c0].fields;
            const k = u.rng.below(@intCast(fields.len));
            const fty = fields[k];
            const f = try u.declFn(0, &.{ty}, fty);
            try u.enter(f, 40);
            const scrut = try u.g.mkLocal(u.t.fns.items[f].params[0]);
            var rows: std.ArrayList(u32) = .empty;
            try rows.append(u.arena(), @intCast(ctors.len));
            for (ctors) |c| {
                var ps: [12]u32 = undefined;
                var got: ?u32 = null;
                for (u.t.ctors.items[c].fields, 0..) |ft, j| {
                    if (c == c0 and j == k) {
                        const l = try u.g.freshDyn(ft);
                        got = l;
                        ps[j] = try u.t.addPat(.{ .tag = .bind, .ty = ft, .a = l });
                    } else ps[j] = try u.t.addPat(.{ .tag = .wild, .ty = ft });
                }
                const p = try u.t.addPat(.{ .tag = .ctor, .ty = ty, .a = c, .b = try u.g.listExtra(ps[0..u.t.ctors.items[c].fields.len]) });
                const body = if (got) |l| try u.g.mkLocal(l) else try u.g.leaf(fty);
                try rows.appendSlice(u.arena(), &.{ p, body });
            }
            try u.define(f, try u.g.mk(.{ .tag = .case, .ty = fty, .a = scrut, .b = try u.t.addExtra(rows.items) }));
        }
        // An update: case and rebuild with one field replaced.
        {
            const c0 = u.g.pick(u32, ctors);
            const fields = u.t.ctors.items[c0].fields;
            const k = u.rng.below(@intCast(fields.len));
            const f = try u.declFn(0, &.{ ty, fields[k] }, ty);
            try u.enter(f, 60);
            const fd = u.t.fns.items[f];
            const scrut = try u.g.mkLocal(fd.params[0]);
            var rows: std.ArrayList(u32) = .empty;
            try rows.append(u.arena(), @intCast(ctors.len));
            for (ctors) |c| {
                const cf = u.t.ctors.items[c].fields;
                var ps: [12]u32 = undefined;
                var ls: [12]u32 = undefined;
                for (cf, 0..) |ft, j| {
                    if (c == c0 and j != k) {
                        ls[j] = try u.g.freshDyn(ft);
                        ps[j] = try u.t.addPat(.{ .tag = .bind, .ty = ft, .a = ls[j] });
                    } else ps[j] = try u.t.addPat(.{ .tag = .wild, .ty = ft });
                }
                const p = try u.t.addPat(.{ .tag = .ctor, .ty = ty, .a = c, .b = try u.g.listExtra(ps[0..cf.len]) });
                const body = if (c == c0) blk: {
                    var args: [12]u32 = undefined;
                    for (0..cf.len) |j| args[j] = if (j == k) try u.g.mkLocal(fd.params[1]) else try u.g.mkLocal(ls[j]);
                    break :blk try u.g.mkCtor(c, args[0..cf.len], ty);
                } else try u.g.mkLocal(fd.params[0]);
                try rows.appendSlice(u.arena(), &.{ p, body });
            }
            try u.define(f, try u.g.mk(.{ .tag = .case, .ty = ty, .a = scrut, .b = try u.t.addExtra(rows.items) }));
        }
        // A builder that nests constructors.
        {
            var ps: [3]Type = undefined;
            const sig = u.randomSig(1, 3, &ps);
            _ = try u.simpleFn(0, sig[0], ty, 40, 3);
        }
    }
}

// ---- imports: a wide and deep graph of qualified references ----

fn imports(u: *Unit, earlier: []const u32) !void {
    u.g.w = .{ .call = 60, .ctor = 30, .local = 25, .literal = 8, .binop = 6, .@"if" = 3, .case = 3, .let = 2, .pair = 4 };
    // Up to 8 earlier units, at growing distances: depth grows with k,
    // fan-in stays constant.
    const offsets = [_]u32{ 1, 2, 3, 5, 8, 13, 21, 34 };
    for (offsets) |o| {
        if (o > earlier.len) break;
        const m = earlier[earlier.len - o];
        try u.see(m);
        for (u.t.modules.items[m].types.items) |d| {
            if (u.t.types.items[d].nparams == 0) try u.g.pool.append(u.arena(), try u.store().named(u.arena(), d, &.{}));
        }
    }
    for (0..6) |_| {
        const k = u.rng.range(1, 3);
        var fields: [3][]const Type = undefined;
        for (0..k) |c| {
            const nf = u.rng.range(0, 2);
            const fs = try u.arena().alloc(Type, nf);
            for (fs) |*f| f.* = u.g.pick(Type, u.g.pool.items);
            fields[c] = fs;
        }
        const d = (try u.declType(0, fields[0..k])) orelse continue;
        try u.g.pool.append(u.arena(), try u.store().named(u.arena(), d, &.{}));
    }
    for (0..18) |_| {
        var ps: [3]Type = undefined;
        const sig = u.randomSig(1, 3, &ps);
        _ = try u.simpleFn(0, sig[0], sig[1], 120, 6);
    }
}

// ---- everyday: a realistic mix ----

fn everyday(u: *Unit, earlier: []const u32) !void {
    u.g.w = .{ .local = 30, .call = 25, .call_local = 8, .ctor = 12, .literal = 12, .pair = 5, .list = 6, .binop = 12, .cmp = 6, .not = 2, .to_string = 6, .@"if" = 6, .case = 7, .let = 6, .fn_ref = 2, .list_map = 6, .list_filter = 5, .list_foldl = 5 };
    u.g.max_leaves = 6;
    for ([_]u32{ 1, 2 }) |o| if (o <= earlier.len) try u.see(earlier[earlier.len - o]);
    for (0..3) |_| {
        const k = u.rng.range(3, 8);
        var fields: [8][]const Type = undefined;
        for (0..k) |c| {
            const nf = u.rng.range(0, 3);
            const fs = try u.arena().alloc(Type, nf);
            for (fs) |*f| f.* = u.g.pick(Type, &.{ .int, .string, .bool, .float, u.listOf(.string), u.optOf(.int) });
            fields[c] = fs;
        }
        const d = (try u.declType(0, fields[0..k])).?;
        const ty = try u.store().named(u.arena(), d, &.{});
        try u.g.pool.append(u.arena(), ty);
        try u.g.pool.append(u.arena(), u.listOf(ty));
    }
    for (0..15) |_| {
        var ps: [4]Type = undefined;
        const sig = u.randomSig(1, 3, &ps);
        _ = try u.simpleFn(0, sig[0], sig[1], u.rng.range(30, 160), 6);
    }
}

/// `if c then pred(…) else …` with the condition built first, so what it
/// narrows is known to both branches (§19 V2, V8). Just the call when the
/// scope has nothing to build a condition from.
fn chainIf(u: *Unit, p: u32, ret: Type, _: ?u32) !u32 {
    const c = (try u.g.condition(2)) orelse return u.g.callFn(p, &.{}, 3);
    const kmark = u.g.known.items.len;
    defer u.g.known.shrinkRetainingCapacity(kmark);
    try u.g.markCond(c);
    const call = try u.g.callFn(p, &.{}, 3);
    const other = try u.g.synth(ret, 3);
    return u.g.mk(.{ .tag = .@"if", .ty = ret, .a = c, .b = try u.t.addExtra(&.{ call, other }) });
}

fn baseFn(u: *Unit, name: []const u8) u32 {
    for (u.t.modules.items[u.base.module].fns.items) |f| {
        if (std.mem.eql(u8, u.t.fns.items[f].name, name)) return f;
    }
    unreachable;
}
