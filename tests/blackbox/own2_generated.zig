//! The generated modules of `ownership-v2.md` §7 item 6 that the checker
//! v2 walks at the default allowance. `build_test.zig` checks what their
//! dumps say (the verdicts, `unchecked`, `growth`, the totals);
//! `perf_test.zig` checks the item's time bound on the same modules, on the
//! ReleaseFast compiler `zig build test-perf` installs (#2272).

const std = @import("std");

/// One generated module of §7 item 6.
pub const Module = union(enum) {
    /// CallbackWrapperDag, the spec's tuple form: `w0 f = ( f ⊤, f ⊤ )`,
    /// `wk f = ( w(k-1) f, w(k-1) f )`, k up to `depth`.
    wrapper_tuples: u32,
    /// CallbackWrapperDag's list form: `wk f = w(k-1) f ++ w(k-1) f`.
    wrapper_lists: u32,
    /// Appendix B's ClosureTower, `w0` to `w<depth>`.
    closure_tower: u32,
    /// A direct `n`-field `h f = { a0 = f ⊤, … }` over `Int` answers.
    scalar_wrapper: u32,
    /// WideCallbackResult (`wideSource`).
    wide: struct { n: u32, m: u32, leaf: WideLeaf },
    /// CallbackUnionComposition with N = M = the payload.
    union_composition: u32,
    /// `ping` and `pong` handing each other a carried lambda.
    mutual_lambdas,
    /// A chain of `n` folds, each feeding the next.
    fold_chain: u32,
};

/// Every module `build_test.zig` dumps at the default allowance and
/// `perf_test.zig` times: §7 item 6's "each default-limit generated module
/// above".
pub const timed = [_]Module{
    .{ .wrapper_tuples = 10 },
    .{ .wrapper_lists = 24 },
    .{ .closure_tower = 24 },
    .{ .scalar_wrapper = 64 },
    .{ .scalar_wrapper = 512 },
    .{ .wide = .{ .n = 16, .m = 16, .leaf = .supplied } },
    .{ .wide = .{ .n = 32, .m = 32, .leaf = .supplied } },
    .{ .union_composition = 16 },
    .{ .union_composition = 64 },
    .{ .union_composition = 256 },
    .mutual_lambdas,
    .{ .fold_chain = 40 },
    .{ .fold_chain = 80 },
};

/// The module's source.
pub fn source(a: std.mem.Allocator, module: Module) ![]const u8 {
    var src: std.ArrayList(u8) = .empty;
    switch (module) {
        .wrapper_tuples => |depth| {
            try src.appendSlice(a, "w0 f = ( f ⊤, f ⊤ )\n");
            for (1..depth + 1) |k| try src.print(a, "\n\nw{d} f = ( w{d} f, w{d} f )\n", .{ k, k - 1, k - 1 });
        },
        .wrapper_lists => |depth| {
            try src.appendSlice(a, "w0 f = f ⊤ ++ f ⊤\n");
            for (1..depth + 1) |k| try src.print(a, "\n\nw{d} f = w{d} f ++ w{d} f\n", .{ k, k - 1, k - 1 });
        },
        .closure_tower => |depth| {
            try src.appendSlice(a, "w0 : ⊤ → (Bool → List Int)\nw0 ⊤ =\n    xs = [ 0 ]\n    λ_ → xs\n");
            for (1..depth + 1) |k| try src.print(a, "\n\nw{d} : ⊤ → (Bool → List Int)\nw{d} ⊤ =\n    a = w{d} ⊤\n    b = w{d} ⊤\n    λflag → if flag then a flag else b flag\n", .{ k, k, k - 1, k - 1 });
        },
        .scalar_wrapper => |n| {
            try src.appendSlice(a, "type alias H = { ");
            for (0..n) |k| try src.print(a, "{s}a{d} : Int", .{ if (k == 0) "" else ", ", k });
            try src.appendSlice(a, " }\n\n\npub h : (⊤ → Int) → H\nh f = { ");
            for (0..n) |k| try src.print(a, "{s}a{d} = f ⊤", .{ if (k == 0) "" else ", ", k });
            try src.appendSlice(a, " }\n");
        },
        .wide => |wide| try wideSource(a, &src, wide.n, wide.m, wide.leaf),
        .union_composition => |n| {
            for ([_][]const u8{ "pickN", "pickM" }) |name| {
                try src.print(a, "{s} : Int, (⊤ → List Int) → List Int\n{s} k f =\n    case k of\n", .{ name, name });
                for (0..n - 1) |k| try src.print(a, "        {d} → f ⊤\n\n", .{k});
                try src.appendSlice(a, "        _ → f ⊤\n\n\n");
            }
            try src.appendSlice(a, "pub both : Int, Int, (⊤ → List Int) → List Int × List Int\nboth i j f = ( pickN i f, pickM j f )\n\n\n");
            try src.appendSlice(a, "pub fresh : Int, Int → List Int × List Int\nfresh i j =\n    ( p, q ) = both i j λ⊤ → [ 1 ]\n    ( List.push p 1, q )\n\n\n");
            try src.appendSlice(a, "pub shared : Int, Int, List Int → List Int × List Int\nshared i j x =\n    ( p, q ) = both i j λ⊤ → x\n    ( List.push p 1, q )\n");
        },
        .mutual_lambdas => try src.appendSlice(a,
            \\ping : Int, (⊤ → List Int) → List Int
            \\ping n f =
            \\    if n == 0 then
            \\        f ⊤
            \\
            \\    else
            \\        pong (n - 1) λ⊤ → f ⊤
            \\
            \\
            \\pong : Int, (⊤ → List Int) → List Int
            \\pong n f =
            \\    if n == 0 then
            \\        f ⊤
            \\
            \\    else
            \\        ping (n - 1) λ⊤ → f ⊤
            \\
            \\
            \\pub fresh : Int → List Int
            \\fresh n = List.push (ping n λ⊤ → [ 1 ]) 2
            \\
            \\
            \\pub shared : Int, List Int → List Int × List Int
            \\shared n x = ( List.push (ping n λ⊤ → x) 2, x )
            \\
        ),
        .fold_chain => |n| {
            try src.appendSlice(a, "pub chain : List Int → List Int\nchain xs =\n    r0 = List.foldl xs [] λx acc → List.push acc x\n");
            for (1..n + 1) |k| try src.print(a, "    r{d} = List.foldl r{d} [] λx acc → List.push acc x\n", .{ k, k - 1 });
            try src.print(a, "    r{d}\n", .{n});
        },
    }
    return src.toOwnedSlice(a);
}

pub const WideLeaf = enum { scalar, fresh, supplied };

/// §7.6 item 6's WideCallbackResult: `h f` builds an `n`-field record of
/// `f ⊤`; each answer is an `m`-field record of lists (or of `Int`s for
/// `.scalar`, which has `h` alone). `use` hands `h` a lambda answering `[]`
/// in every field (`.fresh`) or the parameter `x` (`.supplied`). `demo`
/// writes one list of the answer while a list of another field is read.
pub fn wideSource(a: std.mem.Allocator, src: *std.ArrayList(u8), n: u32, m: u32, leaf: WideLeaf) !void {
    const field = if (leaf == .scalar) "Int" else "List Int";
    try src.appendSlice(a, "type alias R = { ");
    for (0..m) |j| try src.print(a, "{s}b{d} : {s}", .{ if (j == 0) "" else ", ", j, field });
    try src.appendSlice(a, " }\n\n\ntype alias H = { ");
    for (0..n) |i| try src.print(a, "{s}a{d} : R", .{ if (i == 0) "" else ", ", i });
    try src.appendSlice(a, " }\n\n\npub h : (⊤ → R) → H\nh f = { ");
    for (0..n) |i| try src.print(a, "{s}a{d} = f ⊤", .{ if (i == 0) "" else ", ", i });
    try src.appendSlice(a, " }\n");
    if (leaf == .scalar) return;
    try src.appendSlice(a, "\n\npub use : List Int → H\nuse x =\n    h λ⊤ → { ");
    for (0..m) |j| try src.print(a, "{s}b{d} = {s}", .{ if (j == 0) "" else ", ", j, if (leaf == .fresh) "[]" else "x" });
    try src.appendSlice(a, " }\n\n\npub demo : List Int → List Int × List Int\ndemo x =\n    r = use x\n    ( List.push r.a0.b0 1, r.a1.b1 )\n");
}
