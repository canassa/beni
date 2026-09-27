//! The `Base` module (docs/design/compare-bench.md §7.1): the program's own
//! `Seq`, `Opt` and `Res`, pair helpers and ten generic functions over
//! `Seq`, written by recursion. It is the same in every project, so its cost
//! lands in the intercept. It is hand-built as a tree, so every printer
//! prints it exactly as it prints generated code.

const std = @import("std");
const Tree = @import("Tree.zig");
const TypeStore = @import("Type.zig");
const Type = TypeStore.Type;
const synth = @import("synth.zig");
const Rng = @import("Rng.zig");

pub const Base = struct {
    module: u32,
    seq: u32,
    opt: u32,
    res: u32,
    snil: u32,
    scons: u32,
};

const B = struct {
    g: *synth.Gen,
    t: *Tree,

    fn v(b: B, i: u32) Type {
        return b.t.store.tvar(b.t.arena, i) catch unreachable;
    }
    fn named(b: B, decl: u32, args: []const Type) Type {
        return b.t.store.named(b.t.arena, decl, args) catch unreachable;
    }
    fn func(b: B, ps: []const Type, r: Type) Type {
        return b.t.store.func(b.t.arena, ps, r) catch unreachable;
    }
    fn pairT(b: B, x: Type, y: Type) Type {
        return b.t.store.pair(b.t.arena, x, y) catch unreachable;
    }
    fn local(b: B, l: u32) !u32 {
        return b.g.mkLocal(l);
    }
    fn lit(b: B, n: u32) !u32 {
        return b.g.mk(.{ .tag = .lit_int, .ty = .int, .a = n });
    }
    fn ctor(b: B, c: u32, ty: Type, args: []const u32) !u32 {
        return b.g.mkCtor(c, args, ty);
    }
    /// A call of a Base function at `targs`.
    fn call(b: B, f: u32, targs: []const Type, args: []const u32) !u32 {
        const s = &b.t.store;
        const fd = b.t.fns.items[f];
        const sig = try fd.sigType(b.t, s, b.t.arena);
        const fty = try s.subst(b.t.arena, sig, targs);
        const callee = try b.g.mkGlobal(f, targs, fty);
        return b.g.mkCall(callee, args, s.funcRet(fty));
    }
    fn callLocal(b: B, l: u32, args: []const u32) !u32 {
        const ty = b.t.locals.items[l].ty;
        return b.g.mkCall(try b.local(l), args, b.t.store.funcRet(ty));
    }
    fn bind(b: B, ty: Type) !struct { p: u32, l: u32 } {
        const l = try b.g.freshLocal(ty);
        return .{ .p = try b.t.addPat(.{ .tag = .bind, .ty = ty, .a = l }), .l = l };
    }
    fn wild(b: B, ty: Type) !u32 {
        return b.t.addPat(.{ .tag = .wild, .ty = ty });
    }
    fn pctor(b: B, c: u32, ty: Type, args: []const u32) !u32 {
        return b.t.addPat(.{ .tag = .ctor, .ty = ty, .a = c, .b = try b.g.listExtra(args) });
    }
    fn case(b: B, scrut: u32, ty: Type, rows: []const [2]u32) !u32 {
        var xs: std.ArrayList(u32) = .empty;
        try xs.append(b.t.arena, @intCast(rows.len));
        for (rows) |r| try xs.appendSlice(b.t.arena, &r);
        return b.g.mk(.{ .tag = .case, .ty = ty, .a = scrut, .b = try b.t.addExtra(xs.items) });
    }
    fn ifE(b: B, c: u32, x: u32, y: u32, ty: Type) !u32 {
        return b.g.mk(.{ .tag = .@"if", .ty = ty, .a = c, .b = try b.t.addExtra(&.{ x, y }) });
    }
    fn lambda(b: B, params: []const u32, body: u32) !u32 {
        var ps: [4]Type = undefined;
        for (params, 0..) |p, i| ps[i] = b.t.locals.items[p].ty;
        const ty = b.func(ps[0..params.len], b.t.exprs.items(.ty)[body]);
        return b.g.mk(.{ .tag = .lambda, .ty = ty, .a = try b.g.listExtra(params), .b = body });
    }
    fn binop(b: B, op: Tree.Op, x: u32, y: u32) !u32 {
        return b.g.mk(.{ .tag = .binop, .op = op, .ty = op.result(), .a = x, .b = y });
    }

    /// Declare a function; its parameters become locals v0, v1, ...
    fn declare(b: B, name: []const u8, nvars: u32, ptys: []const Type, ret: Type) !u32 {
        b.g.beginFn(nvars, 1 << 20);
        var ps: [8]u32 = undefined;
        for (ptys, 0..) |p, i| ps[i] = try b.g.freshLocal(p);
        return b.t.addFn(.{
            .module = b.g.module,
            .name = name,
            .nvars = nvars,
            .params = try b.t.arena.dupe(u32, ps[0..ptys.len]),
            .ret = ret,
            .library = true,
        });
    }
    fn finish(b: B, f: u32, body: u32) void {
        b.t.fns.items[f].body = body;
        b.t.fns.items[f].ready = true;
    }
    fn param(b: B, f: u32, i: usize) u32 {
        return b.t.fns.items[f].params[i];
    }
};

pub fn build(t: *Tree, rng: *Rng) !Base {
    const m = try t.addModule(.{ .name = "Base", .kind = .base });
    var g: synth.Gen = .{ .t = t, .rng = rng, .module = m };
    const b: B = .{ .g = &g, .t = t };
    const a = b.v(0);
    const bb = b.v(1);

    const seq = try t.addTypeDecl(m, "Seq", 1);
    const seq_a = try t.selfType(seq);
    const snil = try t.addCtor(seq, "SNil", &.{});
    const scons = try t.addCtor(seq, "SCons", &.{ a, seq_a });
    const opt = try t.addTypeDecl(m, "Opt", 1);
    const onone = try t.addCtor(opt, "ONone", &.{});
    const osome = try t.addCtor(opt, "OSome", &.{a});
    const res = try t.addTypeDecl(m, "Res", 2);
    _ = try t.addCtor(res, "RErr", &.{a});
    const rok = try t.addCtor(res, "ROk", &.{bb});
    t.computeMinDepths();

    const seq_b = b.named(seq, &.{bb});
    const opt_a = b.named(opt, &.{a});
    const opt_b = b.named(opt, &.{bb});

    // slen : Seq a -> Int
    {
        const f = try b.declare("slen", 1, &.{seq_a}, .int);
        const r = try b.bind(seq_a);
        const body = try b.case(try b.local(b.param(f, 0)), .int, &.{
            .{ try b.pctor(snil, seq_a, &.{}), try b.lit(0) },
            .{ try b.pctor(scons, seq_a, &.{ try b.wild(a), r.p }), try b.binop(.int_add, try b.lit(1), try b.call(f, &.{a}, &.{try b.local(r.l)})) },
        });
        b.finish(f, body);
    }
    // smap : Seq a, (a -> b) -> Seq b
    {
        const f = try b.declare("smap", 2, &.{ seq_a, b.func(&.{a}, bb) }, seq_b);
        const x = try b.bind(a);
        const r = try b.bind(seq_a);
        const body = try b.case(try b.local(b.param(f, 0)), seq_b, &.{
            .{ try b.pctor(snil, seq_a, &.{}), try b.ctor(snil, seq_b, &.{}) },
            .{ try b.pctor(scons, seq_a, &.{ x.p, r.p }), try b.ctor(scons, seq_b, &.{
                try b.callLocal(b.param(f, 1), &.{try b.local(x.l)}),
                try b.call(f, &.{ a, bb }, &.{ try b.local(r.l), try b.local(b.param(f, 1)) }),
            }) },
        });
        b.finish(f, body);
    }
    // sfilter : Seq a, (a -> Bool) -> Seq a
    {
        const f = try b.declare("sfilter", 1, &.{ seq_a, b.func(&.{a}, .bool) }, seq_a);
        const x = try b.bind(a);
        const r = try b.bind(seq_a);
        const rest = try b.call(f, &.{a}, &.{ try b.local(r.l), try b.local(b.param(f, 1)) });
        const rest2 = try b.call(f, &.{a}, &.{ try b.local(r.l), try b.local(b.param(f, 1)) });
        const body = try b.case(try b.local(b.param(f, 0)), seq_a, &.{
            .{ try b.pctor(snil, seq_a, &.{}), try b.ctor(snil, seq_a, &.{}) },
            .{ try b.pctor(scons, seq_a, &.{ x.p, r.p }), try b.ifE(
                try b.callLocal(b.param(f, 1), &.{try b.local(x.l)}),
                try b.ctor(scons, seq_a, &.{ try b.local(x.l), rest }),
                rest2,
                seq_a,
            ) },
        });
        b.finish(f, body);
    }
    // sfold : Seq a, b, (b, a -> b) -> b
    const sfold = blk: {
        const f = try b.declare("sfold", 2, &.{ seq_a, bb, b.func(&.{ bb, a }, bb) }, bb);
        const x = try b.bind(a);
        const r = try b.bind(seq_a);
        const body = try b.case(try b.local(b.param(f, 0)), bb, &.{
            .{ try b.pctor(snil, seq_a, &.{}), try b.local(b.param(f, 1)) },
            .{ try b.pctor(scons, seq_a, &.{ x.p, r.p }), try b.call(f, &.{ a, bb }, &.{
                try b.local(r.l),
                try b.callLocal(b.param(f, 2), &.{ try b.local(b.param(f, 1)), try b.local(x.l) }),
                try b.local(b.param(f, 2)),
            }) },
        });
        b.finish(f, body);
        break :blk f;
    };
    // sappend : Seq a, Seq a -> Seq a
    {
        const f = try b.declare("sappend", 1, &.{ seq_a, seq_a }, seq_a);
        const x = try b.bind(a);
        const r = try b.bind(seq_a);
        const body = try b.case(try b.local(b.param(f, 0)), seq_a, &.{
            .{ try b.pctor(snil, seq_a, &.{}), try b.local(b.param(f, 1)) },
            .{ try b.pctor(scons, seq_a, &.{ x.p, r.p }), try b.ctor(scons, seq_a, &.{
                try b.local(x.l),
                try b.call(f, &.{a}, &.{ try b.local(r.l), try b.local(b.param(f, 1)) }),
            }) },
        });
        b.finish(f, body);
    }
    // srev : Seq a -> Seq a
    {
        const f = try b.declare("srev", 1, &.{seq_a}, seq_a);
        const acc = try g.freshLocal(seq_a);
        const x = try g.freshLocal(a);
        const lam = try b.lambda(&.{ acc, x }, try b.ctor(scons, seq_a, &.{ try b.local(x), try b.local(acc) }));
        const body = try b.call(sfold, &.{ a, seq_a }, &.{ try b.local(b.param(f, 0)), try b.ctor(snil, seq_a, &.{}), lam });
        b.finish(f, body);
    }
    // stake : Seq a, Int -> Seq a
    {
        const f = try b.declare("stake", 1, &.{ seq_a, .int }, seq_a);
        const x = try b.bind(a);
        const r = try b.bind(seq_a);
        const body = try b.case(try b.local(b.param(f, 0)), seq_a, &.{
            .{ try b.pctor(snil, seq_a, &.{}), try b.ctor(snil, seq_a, &.{}) },
            .{ try b.pctor(scons, seq_a, &.{ x.p, r.p }), try b.ifE(
                try b.binop(.int_lt, try b.local(b.param(f, 1)), try b.lit(1)),
                try b.ctor(snil, seq_a, &.{}),
                try b.ctor(scons, seq_a, &.{
                    try b.local(x.l),
                    try b.call(f, &.{a}, &.{ try b.local(r.l), try b.binop(.int_sub, try b.local(b.param(f, 1)), try b.lit(1)) }),
                }),
                seq_a,
            ) },
        });
        b.finish(f, body);
    }
    // sany : Seq a, (a -> Bool) -> Bool
    {
        const f = try b.declare("sany", 1, &.{ seq_a, b.func(&.{a}, .bool) }, .bool);
        const x = try b.bind(a);
        const r = try b.bind(seq_a);
        const body = try b.case(try b.local(b.param(f, 0)), .bool, &.{
            .{ try b.pctor(snil, seq_a, &.{}), try g.mk(.{ .tag = .lit_bool, .ty = .bool, .a = 0 }) },
            .{ try b.pctor(scons, seq_a, &.{ x.p, r.p }), try b.binop(
                .bool_or,
                try b.callLocal(b.param(f, 1), &.{try b.local(x.l)}),
                try b.call(f, &.{a}, &.{ try b.local(r.l), try b.local(b.param(f, 1)) }),
            ) },
        });
        b.finish(f, body);
    }
    // shead : Seq a -> Opt a
    {
        const f = try b.declare("shead", 1, &.{seq_a}, opt_a);
        const x = try b.bind(a);
        const body = try b.case(try b.local(b.param(f, 0)), opt_a, &.{
            .{ try b.pctor(snil, seq_a, &.{}), try b.ctor(onone, opt_a, &.{}) },
            .{ try b.pctor(scons, seq_a, &.{ x.p, try b.wild(seq_a) }), try b.ctor(osome, opt_a, &.{try b.local(x.l)}) },
        });
        b.finish(f, body);
    }
    // ssingle : a -> Seq a
    {
        const f = try b.declare("ssingle", 1, &.{a}, seq_a);
        b.finish(f, try b.ctor(scons, seq_a, &.{ try b.local(b.param(f, 0)), try b.ctor(snil, seq_a, &.{}) }));
    }
    // omap : Opt a, (a -> b) -> Opt b
    {
        const f = try b.declare("omap", 2, &.{ opt_a, b.func(&.{a}, bb) }, opt_b);
        const x = try b.bind(a);
        const body = try b.case(try b.local(b.param(f, 0)), opt_b, &.{
            .{ try b.pctor(onone, opt_a, &.{}), try b.ctor(onone, opt_b, &.{}) },
            .{ try b.pctor(osome, opt_a, &.{x.p}), try b.ctor(osome, opt_b, &.{try b.callLocal(b.param(f, 1), &.{try b.local(x.l)})}) },
        });
        b.finish(f, body);
    }
    // rmap : Res a b, (b -> c) -> Res a c   (the error type first)
    {
        const c = b.v(2);
        const res_ab = b.named(res, &.{ a, bb });
        const res_ac = b.named(res, &.{ a, c });
        const f = try b.declare("rmap", 3, &.{ res_ab, b.func(&.{bb}, c) }, res_ac);
        const e = try b.bind(a);
        const x = try b.bind(bb);
        const rerr = t.types.items[res].ctors.items[0];
        const body = try b.case(try b.local(b.param(f, 0)), res_ac, &.{
            .{ try b.pctor(rerr, res_ab, &.{e.p}), try b.ctor(rerr, res_ac, &.{try b.local(e.l)}) },
            .{ try b.pctor(rok, res_ab, &.{x.p}), try b.ctor(rok, res_ac, &.{try b.callLocal(b.param(f, 1), &.{try b.local(x.l)})}) },
        });
        b.finish(f, body);
    }
    // pfst, psnd : Pair a b -> a / b; pswap : Pair a b -> Pair b a
    {
        const pab = b.pairT(a, bb);
        inline for (.{ "pfst", "psnd" }, 0..) |name, which| {
            const f = try b.declare(name, 2, &.{pab}, if (which == 0) a else bb);
            const x = try b.bind(if (which == 0) a else bb);
            const pp = if (which == 0)
                try t.addPat(.{ .tag = .pair, .ty = pab, .a = x.p, .b = try b.wild(bb) })
            else
                try t.addPat(.{ .tag = .pair, .ty = pab, .a = try b.wild(a), .b = x.p });
            b.finish(f, try b.case(try b.local(b.param(f, 0)), if (which == 0) a else bb, &.{.{ pp, try b.local(x.l) }}));
        }
        const f = try b.declare("pswap", 2, &.{pab}, b.pairT(bb, a));
        const x = try b.bind(a);
        const y = try b.bind(bb);
        const pp = try t.addPat(.{ .tag = .pair, .ty = pab, .a = x.p, .b = y.p });
        const out = try g.mk(.{ .tag = .pair, .ty = b.pairT(bb, a), .a = try b.local(y.l), .b = try b.local(x.l) });
        b.finish(f, try b.case(try b.local(b.param(f, 0)), b.pairT(bb, a), &.{.{ pp, out }}));
    }

    return .{ .module = m, .seq = seq, .opt = opt, .res = res, .snil = snil, .scons = scons };
}
