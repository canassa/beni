//! One generated program (docs/design/compare-bench.md §3, §5, §7): `Base`,
//! k units of every selected family, and `Main`. Each unit is a pure
//! function of `(seed, family, unit)`, so the program at size k is a prefix
//! of the program at size 2k, and a family-only program holds exactly the
//! modules the total program holds for that family (§3.2).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tree = @import("Tree.zig");
const Rng = @import("Rng.zig");
const base_mod = @import("base.zig");
const families = @import("families/families.zig");
const common = @import("families/common.zig");
const analyse_mod = @import("analyse.zig");
const validate = @import("validate.zig");

pub const default_seed: u64 = 0xBE11C0DE;

pub const Options = struct {
    seed: u64 = default_seed,
    size: u32 = 1,
    families: []const Tree.Family = &Tree.Family.all,
    /// §6.1: 100 is the annotated mode, 0 the inferred mode.
    annotate: u32 = 100,
};

pub const Program = struct {
    tree: Tree,
    base: base_mod.Base,
    main: u32,
    info: analyse_mod.Result,
    /// The numeric literals the Roc printer writes with a type suffix.
    roc_defaulted: validate.Defaulted,
    /// The binders the PureScript printer writes a type on.
    ps_typed: validate.PsTyped,
};

/// Generate, analyse and validate. `arena` owns everything; a validation
/// failure is returned as `error.Invalid` with the report in `diag`.
pub fn generate(arena: Allocator, opts: Options, diag: *std.Io.Writer) !Program {
    var p: Program = .{ .tree = try Tree.init(arena), .base = undefined, .main = undefined, .info = undefined, .roc_defaulted = undefined, .ps_typed = undefined };
    const t = &p.tree;
    var base_rng = Rng.forUnit(opts.seed, 0, 0);
    p.base = try base_mod.build(t, &base_rng);
    const cfg: common.Config = .{ .seed = opts.seed, .annotate = opts.annotate };
    // Families in their fixed order, whatever order they were asked in.
    for (Tree.Family.all) |fam| {
        if (std.mem.indexOfScalar(Tree.Family, opts.families, fam) == null) continue;
        var earlier: std.ArrayList(u32) = .empty;
        for (1..opts.size + 1) |k| {
            var rng = Rng.forUnit(opts.seed, @backingInt(fam), @intCast(k));
            var u: common.Unit = undefined;
            try u.init(t, &rng, cfg, p.base, fam, @intCast(k));
            try families.generate(&u, earlier.items);
            try earlier.append(arena, u.module);
        }
    }
    p.main = try buildMain(t);
    p.info = try analyse_mod.analyse(t);
    try validate.check(t, diag);
    p.roc_defaulted = try validate.rocDefaulted(t);
    p.ps_typed = try validate.psAmbiguous(t);
    return p;
}

/// `Main.total : Int -> Int` sums every unit's `entry` (§7.2), so every
/// module is reachable from `Main`.
fn buildMain(t: *Tree) !u32 {
    const m = try t.addModule(.{ .name = "Main", .kind = .main });
    const n = try t.addLocal(0, .int);
    var acc: ?u32 = null;
    for (t.fns.items, 0..) |f, fi| {
        if (!f.entry) continue;
        const fty = try t.store.func(t.arena, &.{.int}, .int);
        const callee = try t.addExpr(.{ .tag = .global, .ty = fty, .a = @intCast(fi), .b = try t.addExtra(&.{0}) });
        const arg = try t.addExpr(.{ .tag = .local, .ty = .int, .a = n });
        const x = try t.addExtra(&.{ 1, arg });
        const call = try t.addExpr(.{ .tag = .call, .ty = .int, .a = callee, .b = x });
        acc = if (acc) |a| try t.addExpr(.{ .tag = .binop, .op = .int_add, .ty = .int, .a = a, .b = call }) else call;
    }
    const body = acc orelse try t.addExpr(.{ .tag = .local, .ty = .int, .a = n });
    _ = try t.addFn(.{ .module = m, .name = "total", .nvars = 0, .params = try t.arena.dupe(u32, &.{n}), .ret = .int, .body = body, .annotated = true, .entry = true, .ready = true });
    return m;
}

test "the same seed gives the same program, and size k is a prefix of 2k" {
    const print = @import("print/print.zig");
    var a1 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a1.deinit();
    var a2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a2.deinit();
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const p1 = try generate(a1.allocator(), .{ .seed = 7, .size = 2 }, &sink.writer);
    const p2 = try generate(a2.allocator(), .{ .seed = 7, .size = 4 }, &sink.writer);
    for (print.Lang.all) |lang| {
        for (p1.tree.modules.items, 0..) |m, mi| {
            if (m.kind != .unit) continue;
            const mj = for (p2.tree.modules.items, 0..) |m2, j| {
                if (std.mem.eql(u8, m2.name, m.name)) break j;
            } else unreachable;
            const x = try print.module(a1.allocator(), &p1, @intCast(mi), lang, .{});
            const y = try print.module(a2.allocator(), &p2, @intCast(mj), lang, .{});
            try std.testing.expectEqualStrings(x.text, y.text);
        }
    }
}

test "the oracle accepts every family at sizes 1-4 over 16 seeds" {
    var seed: u64 = 1;
    while (seed <= 16) : (seed += 1) {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        _ = generate(a.allocator(), .{ .seed = seed, .size = @intCast(1 + seed % 4), .annotate = if (seed % 2 == 0) 0 else 100 }, &w) catch |err| {
            std.debug.print("seed {d}: {s}\n", .{ seed, w.buffered() });
            return err;
        };
    }
}
