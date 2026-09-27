//! The oracle rejects hand-built bad trees, one per rule of
//! docs/design/compare-bench.md §3.7, and accepts the good tree they are
//! each one edit away from. The pattern split tree is exhaustive and
//! non-redundant by construction (§3.6).

const std = @import("std");
const Tree = @import("Tree.zig");
const TypeStore = @import("Type.zig");
const Type = TypeStore.Type;
const Rng = @import("Rng.zig");
const synth = @import("synth.zig");
const base_mod = @import("base.zig");
const analyse = @import("analyse.zig");
const validate = @import("validate.zig");

/// Base plus one module `Bad001` with `ok : Int, Bool -> Int`, whose body
/// the test replaces. Returns the pieces a test edits.
const Fixture = struct {
    t: *Tree,
    g: synth.Gen,
    base: base_mod.Base,
    m: u32,
    f: u32,
    x: u32, // the Int parameter
    b: u32, // the Bool parameter

    fn init(a: std.mem.Allocator, rng: *Rng) !Fixture {
        const t = try a.create(Tree);
        t.* = try Tree.init(a);
        const base = try base_mod.build(t, rng);
        const m = try t.addModule(.{ .name = "Bad001", .kind = .unit, .family = .everyday, .unit = 1 });
        var g: synth.Gen = .{ .t = t, .rng = rng, .module = m };
        g.beginFn(0, 100);
        const x = try g.freshDyn(.int);
        const b = try g.freshDyn(.bool);
        const f = try t.addFn(.{ .module = m, .name = "f8001000", .nvars = 0, .params = try a.dupe(u32, &.{ x, b }), .ret = .int, .ready = true });
        return .{ .t = t, .g = g, .base = base, .m = m, .f = f, .x = x, .b = b };
    }

    fn check(fx: *Fixture, body: u32) !void {
        fx.t.fns.items[fx.f].body = body;
        _ = try analyse.analyse(fx.t);
        var sink: std.Io.Writer.Discarding = .init(&.{});
        try validate.check(fx.t, &sink.writer);
    }
};

fn expectInvalid(fx: *Fixture, body: u32) !void {
    try std.testing.expectError(error.Invalid, fx.check(body));
}

test "the oracle accepts a good body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = Rng.init(1);
    var fx = try Fixture.init(arena.allocator(), &rng);
    try fx.check(try fx.g.mk(.{ .tag = .binop, .op = .int_add, .ty = .int, .a = try fx.g.mkLocal(fx.x), .b = try fx.g.mkLit(.int) }));
}

test "rule 1: a node whose recorded type its children do not give" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = Rng.init(1);
    var fx = try Fixture.init(arena.allocator(), &rng);
    try expectInvalid(&fx, try fx.g.mk(.{ .tag = .binop, .op = .int_add, .ty = .int, .a = try fx.g.mkLocal(fx.b), .b = try fx.g.mkLit(.int) }));
}

test "rule 2: a case that is not exhaustive, and one that is redundant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = Rng.init(1);
    var fx = try Fixture.init(arena.allocator(), &rng);
    const t = fx.t;
    const only_true = try t.addPat(.{ .tag = .lit_bool, .ty = .bool, .a = 1 });
    const case1 = try fx.g.mk(.{ .tag = .case, .ty = .int, .a = try fx.g.mkLocal(fx.b), .b = try t.addExtra(&.{ 1, only_true, try fx.g.mkLit(.int) }) });
    try expectInvalid(&fx, case1);

    var fx2 = try Fixture.init(arena.allocator(), &rng);
    const t2 = fx2.t;
    const w1 = try t2.addPat(.{ .tag = .wild, .ty = .bool });
    const tr = try t2.addPat(.{ .tag = .lit_bool, .ty = .bool, .a = 1 });
    const case2 = try fx2.g.mk(.{ .tag = .case, .ty = .int, .a = try fx2.g.mkLocal(fx2.b), .b = try t2.addExtra(&.{ 2, w1, try fx2.g.mkLit(.int), tr, try fx2.g.mkLit(.int) }) });
    try expectInvalid(&fx2, case2);
}

test "rule 3: a shadowed local name, and a duplicate constructor name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = Rng.init(1);
    var fx = try Fixture.init(arena.allocator(), &rng);
    // A lambda parameter named like the function's first parameter.
    const shadow = try fx.t.addLocal(fx.t.locals.items[fx.x].name, .int);
    const lam = try fx.g.mk(.{ .tag = .lambda, .ty = try fx.t.store.func(fx.t.arena, &.{.int}, .int), .a = try fx.g.listExtra(&.{shadow}), .b = try fx.g.mkLocal(shadow) });
    const call = try fx.g.mkCall(lam, &.{try fx.g.mkLocal(fx.x)}, .int);
    try expectInvalid(&fx, call);

    var fx2 = try Fixture.init(arena.allocator(), &rng);
    const d = try fx2.t.addTypeDecl(fx2.m, "T8001000", 0);
    _ = try fx2.t.addCtor(d, "SNil", &.{});
    fx2.t.computeMinDepths();
    try expectInvalid(&fx2, try fx2.g.mkLocal(fx2.x));
}

test "rule 4: an import of a later module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = Rng.init(1);
    var fx = try Fixture.init(arena.allocator(), &rng);
    // Bad001 calls a function of Bad002, a module created after it.
    const later = try fx.t.addModule(.{ .name = "Bad002", .kind = .unit, .family = .everyday, .unit = 2 });
    fx.g.module = later;
    fx.g.beginFn(0, 100);
    const y = try fx.g.freshDyn(.int);
    const f2 = try fx.t.addFn(.{ .module = later, .name = "f8002000", .nvars = 0, .params = try fx.t.arena.dupe(u32, &.{y}), .ret = .int, .ready = true, .body = try fx.g.mkLocal(y) });
    const fty = try fx.t.store.func(fx.t.arena, &.{.int}, .int);
    const callee = try fx.g.mkGlobal(f2, &.{}, fty);
    try expectInvalid(&fx, try fx.g.mkCall(callee, &.{try fx.g.mkLocal(fx.x)}, .int));
}

test "rule 5: an unsaturated call, and foldl over a non-lambda" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = Rng.init(1);
    var fx = try Fixture.init(arena.allocator(), &rng);
    const fty = try fx.t.store.func(fx.t.arena, &.{ .int, .bool }, .int);
    const self = try fx.g.mkGlobal(fx.f, &.{}, fty);
    try expectInvalid(&fx, try fx.g.mkCall(self, &.{try fx.g.mkLocal(fx.x)}, .int));

    var fx2 = try Fixture.init(arena.allocator(), &rng);
    const s = &fx2.t.store;
    const a = fx2.t.arena;
    const add_ty = try s.func(a, &.{ .int, .int }, .int);
    const xs = try fx2.g.mk(.{ .tag = .list, .ty = try s.list(a, .int), .a = try fx2.g.listExtra(&.{}) });
    // A local of function type where the lambda must be.
    const fl = try fx2.t.addLocal(99, add_ty);
    const let_v = try fx2.g.mk(.{ .tag = .lambda, .ty = add_ty, .a = try fx2.g.listExtra(&.{ try fx2.g.freshDyn(.int), try fx2.g.freshDyn(.int) }), .b = try fx2.g.mkLit(.int) });
    const fold = try fx2.g.mk(.{ .tag = .list_foldl, .ty = .int, .a = xs, .b = try fx2.t.addExtra(&.{ try fx2.g.mkLocal(fx2.x), try fx2.g.mkLocal(fl) }) });
    const body = try fx2.g.mk(.{ .tag = .let, .ty = .int, .a = try fx2.t.addExtra(&.{ 1, fl, let_v }), .b = fold });
    try expectInvalid(&fx2, body);
}

test "rule 6: polymorphic recursion does not survive removing annotations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = Rng.init(1);
    var fx = try Fixture.init(arena.allocator(), &rng);
    const t = fx.t;
    const s = &t.store;
    const a = t.arena;
    // g : a -> Int calls itself at Bool: fine with its signature, not
    // without it.
    fx.g.beginFn(1, 100);
    const va = try s.tvar(a, 0);
    const p = try fx.g.freshDyn(va);
    const g = try t.addFn(.{ .module = fx.m, .name = "f8001001", .nvars = 1, .params = try a.dupe(u32, &.{p}), .ret = .int, .ready = true });
    const at_bool = try fx.g.mkGlobal(g, &.{.bool}, try s.func(a, &.{.bool}, .int));
    t.fns.items[g].body = try fx.g.mkCall(at_bool, &.{try fx.g.mkLit(.bool)}, .int);
    try expectInvalid(&fx, try fx.g.mkLocal(fx.x));
}

test "the split tree is exhaustive and non-redundant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var seed: u64 = 1;
    while (seed <= 32) : (seed += 1) {
        var rng = Rng.init(seed);
        var fx = try Fixture.init(arena.allocator(), &rng);
        const s = &fx.t.store;
        const a = fx.t.arena;
        const seq = try s.named(a, fx.base.seq, &.{.int});
        const pty = try s.pair(a, seq, try s.pair(a, .bool, .string));
        const l = try fx.g.freshDyn(pty);
        fx.t.fns.items[fx.f].params = try a.dupe(u32, &.{ fx.x, fx.b, l });
        try fx.g.pool.appendSlice(a, &.{ .int, .string, .bool });
        fx.g.beginFn(0, 200);
        try fx.g.push(fx.x);
        try fx.g.push(fx.b);
        try fx.g.push(l);
        fx.g.next_name = 3;
        const body = try fx.g.caseOn(try fx.g.mkLocal(l), .int, 2, 4, 64);
        try fx.check(body);
    }
}
