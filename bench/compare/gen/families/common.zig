//! What every family generator shares (docs/design/compare-bench.md §4):
//! naming (§2.4), declaring functions and types, and the unit's `entry`.

const std = @import("std");
const Tree = @import("../Tree.zig");
const TypeStore = @import("../Type.zig");
const Type = TypeStore.Type;
const synth = @import("../synth.zig");
const Rng = @import("../Rng.zig");
const base_mod = @import("../base.zig");

pub const Config = struct {
    seed: u64,
    /// The percentage of generated top-level functions that are annotated
    /// (§6.1). Drawn after each body, so it never changes the tree.
    annotate: u32,
};

pub const Unit = struct {
    g: synth.Gen,
    t: *Tree,
    rng: *Rng,
    cfg: Config,
    base: base_mod.Base,
    family: Tree.Family,
    unit: u32,
    module: u32,
    fn_count: u32 = 0,
    type_count: u32 = 0,

    pub fn init(u: *Unit, t: *Tree, rng: *Rng, cfg: Config, base: base_mod.Base, family: Tree.Family, unit: u32) !void {
        const name = try std.fmt.allocPrint(t.arena, "{s}{d:0>3}", .{ family.prefix(), unit });
        const m = try t.addModule(.{ .name = name, .kind = .unit, .family = family, .unit = unit });
        u.* = .{ .g = .{ .t = t, .rng = rng, .module = m }, .t = t, .rng = rng, .cfg = cfg, .base = base, .family = family, .unit = unit, .module = m };
        for (t.modules.items[base.module].fns.items) |f| try u.g.visible_fns.append(t.arena, f);
        try u.defaultPool();
    }

    pub fn arena(u: *Unit) std.mem.Allocator {
        return u.t.arena;
    }

    pub fn store(u: *Unit) *TypeStore {
        return &u.t.store;
    }

    pub fn seqOf(u: *Unit, a: Type) Type {
        return u.store().named(u.arena(), u.base.seq, &.{a}) catch unreachable;
    }
    pub fn optOf(u: *Unit, a: Type) Type {
        return u.store().named(u.arena(), u.base.opt, &.{a}) catch unreachable;
    }
    pub fn resOf(u: *Unit, e: Type, a: Type) Type {
        return u.store().named(u.arena(), u.base.res, &.{ e, a }) catch unreachable;
    }
    pub fn pairOf(u: *Unit, a: Type, b: Type) Type {
        return u.store().pair(u.arena(), a, b) catch unreachable;
    }
    pub fn listOf(u: *Unit, a: Type) Type {
        return u.store().list(u.arena(), a) catch unreachable;
    }
    pub fn funcOf(u: *Unit, ps: []const Type, r: Type) Type {
        return u.store().func(u.arena(), ps, r) catch unreachable;
    }
    pub fn tv(u: *Unit, i: u32) Type {
        return u.store().tvar(u.arena(), i) catch unreachable;
    }

    fn defaultPool(u: *Unit) !void {
        const p = &u.g.pool;
        const a = u.arena();
        try p.appendSlice(a, &.{ .int, .int, .int, .string, .string, .bool, .float });
        try p.appendSlice(a, &.{ u.seqOf(.int), u.seqOf(.string), u.optOf(.int), u.pairOf(.int, .string), u.resOf(.string, .int), u.listOf(.int) });
    }

    /// Make every function of `m` (another unit) callable from here.
    pub fn see(u: *Unit, m: u32) !void {
        for (u.t.modules.items[m].fns.items) |f| try u.g.visible_fns.append(u.arena(), f);
        for (u.t.modules.items[m].types.items) |d| try u.g.visible_types.append(u.arena(), d);
    }

    // ---- names (§2.4) ----

    pub fn fnName(u: *Unit) ![]const u8 {
        defer u.fn_count += 1;
        return std.fmt.allocPrint(u.arena(), "f{d}{d:0>3}{d:0>2}", .{ @backingInt(u.family), u.unit, u.fn_count });
    }

    pub fn typeName(u: *Unit) ![]const u8 {
        return std.fmt.allocPrint(u.arena(), "T{d}{d:0>3}{d:0>2}", .{ @backingInt(u.family), u.unit, u.type_count });
    }

    pub fn ctorName(u: *Unit, k: u32) ![]const u8 {
        return std.fmt.allocPrint(u.arena(), "C{d}{d:0>3}{d:0>2}x{d}", .{ @backingInt(u.family), u.unit, u.type_count, k });
    }

    // ---- declarations ----

    /// A type with the given constructors' field lists (in `Var` terms of
    /// its `nparams` parameters). Refused (null) unless inhabited (§3.3).
    pub fn declType(u: *Unit, nparams: u32, ctor_fields: []const []const Type) !?u32 {
        const name = try u.typeName();
        const d = try u.t.addTypeDecl(u.module, name, nparams);
        for (ctor_fields, 0..) |fs, k| _ = try u.t.addCtor(d, try u.ctorName(@intCast(k)), fs);
        u.type_count += 1;
        u.t.computeMinDepths();
        if (u.t.types.items[d].min_depth == std.math.maxInt(u32)) return null;
        try u.g.visible_types.append(u.arena(), d);
        return d;
    }

    /// Declare a function; its parameters become the locals v0, v1, ...
    /// The body is set by `define`.
    pub fn declFn(u: *Unit, nvars: u32, params: []const Type, ret: Type) !u32 {
        const name = try u.fnName();
        u.g.beginFn(nvars, 0);
        var ps: [16]u32 = undefined;
        for (params, 0..) |p, i| ps[i] = try u.g.freshDyn(p);
        const f = try u.t.addFn(.{
            .module = u.module,
            .name = name,
            .nvars = nvars,
            .params = try u.arena().dupe(u32, ps[0..params.len]),
            .ret = ret,
        });
        return f;
    }

    /// Enter `f`'s body: its parameters in scope, locals numbered after
    /// them, `budget` nodes to spend.
    pub fn enter(u: *Unit, f: u32, budget: i64) !void {
        const fd = u.t.fns.items[f];
        u.g.beginFn(fd.nvars, budget);
        u.g.next_name = @intCast(fd.params.len);
        for (fd.params) |p| try u.g.push(p);
    }

    /// Set `f`'s body, make it callable, and draw whether it is annotated
    /// (§6.1: after the body, so the draw never changes the tree).
    pub fn define(u: *Unit, f: u32, body: u32) !void {
        const fd = &u.t.fns.items[f];
        fd.body = body;
        fd.ready = true;
        fd.annotated = u.rng.below(100) < u.cfg.annotate;
        try u.g.visible_fns.append(u.arena(), f);
    }

    /// Declare and synthesise a function in one go.
    pub fn simpleFn(u: *Unit, nvars: u32, params: []const Type, ret: Type, budget: i64, depth: u32) !u32 {
        const f = try u.declFn(nvars, params, ret);
        try u.enter(f, budget);
        const body = try u.g.synth(ret, depth);
        try u.define(f, body);
        return f;
    }

    /// A random non-generic signature over the pool.
    pub fn randomSig(u: *Unit, min_params: u32, max_params: u32, params: []Type) struct { []Type, Type } {
        const n = u.rng.range(min_params, max_params);
        for (0..n) |i| params[i] = if (u.rng.chance(12)) u.funcOf(&.{u.g.pick(Type, u.g.pool.items)}, u.g.pick(Type, u.g.pool.items)) else u.g.pick(Type, u.g.pool.items);
        return .{ params[0..n], u.g.pick(Type, u.g.pool.items) };
    }

    /// `entry : Int -> Int` (§7.2), which calls this module's own functions.
    pub fn entry(u: *Unit) !void {
        const f = try u.declFn(0, &.{.int}, .int);
        u.t.fns.items[f].name = "entry";
        u.fn_count -= 1;
        u.t.fns.items[f].entry = true;
        // Only this module's functions, and calls strongly preferred.
        const saved = u.g.visible_fns;
        const saved_w = u.g.w;
        defer {
            u.g.visible_fns = saved;
            u.g.w = saved_w;
        }
        u.g.visible_fns = .empty;
        for (u.t.modules.items[u.module].fns.items) |g| if (g != f and u.t.fns.items[g].nvars == 0) try u.g.visible_fns.append(u.arena(), g);
        u.g.w = .{ .call = 90, .local = 20, .literal = 5, .binop = 30, .@"if" = 0, .case = 0, .let = 0, .ctor = 10, .pair = 5, .list = 3, .to_string = 3, .cmp = 3, .fn_ref = 0 };
        try u.enter(f, 30);
        const call_a = try u.g.binop(.int_add, 3);
        const fd = &u.t.fns.items[f];
        fd.body = call_a;
        fd.ready = true;
        fd.annotated = true;
    }
};
