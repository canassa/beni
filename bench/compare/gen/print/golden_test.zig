//! One small golden per printer (docs/design/compare-bench.md §15): a
//! hand-built module covering every expression and pattern kind, printed in
//! each language. `zig build compare-gen -- --golden` rewrites the files
//! under `print/golden/` from the current printers.

const std = @import("std");
const Tree = @import("../Tree.zig");
const TypeStore = @import("../Type.zig");
const Type = TypeStore.Type;
const Rng = @import("../Rng.zig");
const synth = @import("../synth.zig");
const base_mod = @import("../base.zig");
const analyse = @import("../analyse.zig");
const validate = @import("../validate.zig");
const gen = @import("../gen.zig");
const print = @import("print.zig");

pub const goldens = [_][]const u8{
    @embedFile("golden/beni.txt"),
    @embedFile("golden/elm.txt"),
    @embedFile("golden/gleam.txt"),
    @embedFile("golden/roc.txt"),
    @embedFile("golden/purescript.txt"),
    @embedFile("golden/typescript.txt"),
};

/// The program: Base, and `Gold001` with a two-constructor type and one
/// function per construct.
pub fn program(a: std.mem.Allocator) !gen.Program {
    var rng = Rng.init(7);
    var p: gen.Program = .{ .tree = try Tree.init(a), .base = undefined, .main = 0, .info = undefined, .roc_defaulted = undefined, .ps_typed = undefined };
    const t = &p.tree;
    p.base = try base_mod.build(t, &rng);
    const m = try t.addModule(.{ .name = "Gold001", .kind = .unit, .family = .everyday, .unit = 1 });
    var g: synth.Gen = .{ .t = t, .rng = &rng, .module = m };
    const s = &t.store;
    const d = try t.addTypeDecl(m, "T8001000", 1);
    const va = try s.tvar(a, 0);
    const c0 = try t.addCtor(d, "C8001000x0", &.{ va, .int });
    const c1 = try t.addCtor(d, "C8001000x1", &.{});
    t.computeMinDepths();
    const tint = try s.named(a, d, &.{.int});
    const seq_int = try s.named(a, p.base.seq, &.{.int});
    const list_int = try s.list(a, .int);

    // f8001000 : T Int, Int, Bool -> String — case, if, let, binops, literals.
    g.beginFn(0, 1000);
    const x = try g.freshDyn(tint);
    const n = try g.freshDyn(.int);
    const b = try g.freshDyn(.bool);
    const f0 = try t.addFn(.{ .module = m, .name = "f8001000", .nvars = 0, .params = try a.dupe(u32, &.{ x, n, b }), .ret = .string, .ready = true });
    {
        const k = try g.freshDyn(.int);
        const pk = try t.addPat(.{ .tag = .bind, .ty = .int, .a = k });
        const p0 = try t.addPat(.{ .tag = .ctor, .ty = tint, .a = c0, .b = try g.listExtra(&.{ pk, try t.addPat(.{ .tag = .lit_int, .ty = .int, .a = 3 }) }) });
        const p0b = try t.addPat(.{ .tag = .ctor, .ty = tint, .a = c0, .b = try g.listExtra(&.{ try t.addPat(.{ .tag = .wild, .ty = .int }), try t.addPat(.{ .tag = .wild, .ty = .int }) }) });
        const p1 = try t.addPat(.{ .tag = .ctor, .ty = tint, .a = c1, .b = try g.listExtra(&.{}) });
        const lv = try g.freshLocal(.string);
        const cond = try g.mk(.{ .tag = .binop, .op = .bool_and, .ty = .bool, .a = try g.mkLocal(b), .b = try g.mk(.{ .tag = .binop, .op = .int_lt, .ty = .bool, .a = try g.mkLocal(n), .b = try g.mk(.{ .tag = .lit_int, .ty = .int, .a = 10 }) }) });
        const sum = try g.mk(.{ .tag = .binop, .op = .int_add, .ty = .int, .a = try g.mk(.{ .tag = .binop, .op = .int_add, .ty = .int, .a = try g.mkLocal(k), .b = try g.mkLocal(n) }), .b = try g.mk(.{ .tag = .lit_int, .ty = .int, .a = 1 }) });
        const branch0 = try g.mk(.{ .tag = .@"if", .ty = .string, .a = cond, .b = try t.addExtra(&.{ try g.mk(.{ .tag = .int_to_string, .ty = .string, .a = sum }), try g.mk(.{ .tag = .lit_string, .ty = .string, .a = 1 }) }) });
        const let_body = try g.mk(.{ .tag = .binop, .op = .str_append, .ty = .string, .a = try g.mkLocal(lv), .b = try g.mk(.{ .tag = .lit_string, .ty = .string, .a = 2 }) });
        const branch1 = try g.mk(.{ .tag = .let, .ty = .string, .a = try t.addExtra(&.{ 1, lv, try g.mk(.{ .tag = .lit_string, .ty = .string, .a = 3 }) }), .b = let_body });
        const not_b = try g.mk(.{ .tag = .not, .ty = .bool, .a = try g.mkLocal(b) });
        const branch2 = try g.mk(.{ .tag = .@"if", .ty = .string, .a = not_b, .b = try t.addExtra(&.{ try g.mk(.{ .tag = .lit_string, .ty = .string, .a = 4 }), try g.mk(.{ .tag = .lit_string, .ty = .string, .a = 5 }) }) });
        t.fns.items[f0].body = try g.mk(.{ .tag = .case, .ty = .string, .a = try g.mkLocal(x), .b = try t.addExtra(&.{ 3, p0, branch0, p0b, branch2, p1, branch1 }) });
    }
    // f8001001 : List Int, Seq Int -> ( Int, Seq Int ) — lambdas, list
    // functions, pairs, constructors, calls, pipes, floats.
    g.beginFn(0, 1000);
    const xs = try g.freshDyn(list_int);
    const sq = try g.freshDyn(seq_int);
    const pair_ty = try s.pair(a, .int, seq_int);
    const f1 = try t.addFn(.{ .module = m, .name = "f8001001", .nvars = 0, .params = try a.dupe(u32, &.{ xs, sq }), .ret = pair_ty, .ready = true });
    {
        const e1 = try g.freshDyn(.int);
        const mapped = try g.mk(.{ .tag = .list_map, .ty = list_int, .a = try g.mkLocal(xs), .b = try g.mk(.{ .tag = .lambda, .ty = try s.func(a, &.{.int}, .int), .a = try g.listExtra(&.{e1}), .b = try g.mk(.{ .tag = .binop, .op = .int_mul, .ty = .int, .a = try g.mkLocal(e1), .b = try g.mk(.{ .tag = .lit_int, .ty = .int, .a = 2 }) }) }) });
        const e2 = try g.freshDyn(.int);
        const filtered = try g.mk(.{ .tag = .list_filter, .ty = list_int, .a = mapped, .b = try g.mk(.{ .tag = .lambda, .ty = try s.func(a, &.{.int}, .bool), .a = try g.listExtra(&.{e2}), .b = try g.mk(.{ .tag = .binop, .op = .int_eq, .ty = .bool, .a = try g.mkLocal(e2), .b = try g.mk(.{ .tag = .lit_int, .ty = .int, .a = 4 }) }) }) });
        const el = try g.freshDyn(.int);
        const acc = try g.freshDyn(.int);
        const folded = try g.mk(.{ .tag = .list_foldl, .ty = .int, .a = filtered, .b = try t.addExtra(&.{ try g.mk(.{ .tag = .lit_int, .ty = .int, .a = 0 }), try g.mk(.{ .tag = .lambda, .ty = try s.func(a, &.{ .int, .int }, .int), .a = try g.listExtra(&.{ el, acc }), .b = try g.mk(.{ .tag = .binop, .op = .int_sub, .ty = .int, .a = try g.mkLocal(acc), .b = try g.mkLocal(el) }) }) }) });
        // Base.srev and Base.slen as unary pipe stages.
        var srev: u32 = 0;
        var slen: u32 = 0;
        for (t.modules.items[p.base.module].fns.items) |fi| {
            if (std.mem.eql(u8, t.fns.items[fi].name, "srev")) srev = fi;
            if (std.mem.eql(u8, t.fns.items[fi].name, "slen")) slen = fi;
        }
        const st1 = try g.mkGlobal(srev, &.{.int}, try s.func(a, &.{seq_int}, seq_int));
        const st2 = try g.mkGlobal(slen, &.{.int}, try s.func(a, &.{seq_int}, .int));
        const piped = try g.mk(.{ .tag = .pipe, .ty = .int, .a = try g.mkLocal(sq), .b = try g.listExtra(&.{ st1, st2 }) });
        const tot = try g.mk(.{ .tag = .binop, .op = .int_add, .ty = .int, .a = folded, .b = piped });
        const cons = try g.mkCtor(p.base.scons, &.{ try g.mk(.{ .tag = .lit_int, .ty = .int, .a = 5 }), try g.mkLocal(sq) }, seq_int);
        t.fns.items[f1].body = try g.mk(.{ .tag = .pair, .ty = pair_ty, .a = tot, .b = cons });
    }
    _ = try t.addFn(.{ .module = m, .name = "entry", .nvars = 0, .params = try a.dupe(u32, &.{try t.addLocal(0, .int)}), .ret = .int, .entry = true, .ready = true, .body = blk: {
        g.beginFn(0, 10);
        const fl = try g.mk(.{ .tag = .lit_float, .ty = .float, .a = 1, .b = 5 });
        _ = fl;
        const lst = try g.mk(.{ .tag = .list, .ty = list_int, .a = try g.listExtra(&.{ try g.mk(.{ .tag = .lit_int, .ty = .int, .a = 1 }), try g.mk(.{ .tag = .lit_int, .ty = .int, .a = 2 }) }) });
        const f1ty = try s.func(a, &.{ list_int, seq_int }, pair_ty);
        const call = try g.mkCall(try g.mkGlobal(f1, &.{}, f1ty), &.{ lst, try g.mkCtor(p.base.snil, &.{}, seq_int) }, pair_ty);
        var pfst: u32 = 0;
        for (t.modules.items[p.base.module].fns.items) |fi| if (std.mem.eql(u8, t.fns.items[fi].name, "pfst")) {
            pfst = fi;
        };
        break :blk try g.mkCall(try g.mkGlobal(pfst, &.{ .int, seq_int }, try s.func(a, &.{pair_ty}, .int)), &.{call}, .int);
    } });
    t.fns.items[t.fns.items.len - 1].params = try a.dupe(u32, &.{t.fns.items[t.fns.items.len - 1].params[0]});
    p.info = try analyse.analyse(t);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try validate.check(t, &sink.writer);
    p.roc_defaulted = try validate.rocDefaulted(t);
    p.ps_typed = try validate.psAmbiguous(t);
    return p;
}

pub fn render(a: std.mem.Allocator, prog: *const gen.Program, lang: print.Lang) ![]const u8 {
    const o = try print.module(a, prog, 1, lang, .{});
    return o.text;
}

test "every printer matches its golden" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try program(a);
    for (print.Lang.all, goldens) |lang, want| {
        const got = try render(a, &prog, lang);
        std.testing.expectEqualStrings(want, got) catch |err| {
            std.debug.print("golden for {t} differs; rewrite with `zig build compare-gen -- --golden`\n", .{lang});
            return err;
        };
    }
}
