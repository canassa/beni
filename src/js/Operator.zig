//! Core functions the backend writes as JavaScript operators (`backend.md`
//! §4, *Arithmetic is an operator*): a saturated call of `Basics.add` is
//! `a + b`, of `Basics.not` is `!b`, of `Int32.add` is `(a + b) | 0` — each
//! exactly what the function's own definition computes, with no call and no
//! import. `Lower` writes them and `Reach` drops the edge a written-in-place
//! call would otherwise add, so the declaration ships only where it is
//! passed as a value.
//!
//! **Only an exact equivalence is on the list.** `Int` and `Float` are both a
//! JavaScript number (§4), so `Basics.add` over `number` is `+` whichever the
//! call instantiates, and the backend needs no type to write it. `idiv`,
//! `modBy` and `remainderBy` answer 0 for a zero divisor where `/` and `%`
//! would not, and `Int32.div`, `rem`, `mod` likewise, so they stay calls;
//! `Int32.mul` is `Math.imul`, a global the renamer would have to be taught,
//! so it stays one too. `negate` is `0 - n`, not `-n`: the two differ at
//! zero, where `-0` is a different number. `List`'s core-private
//! primitives are here for a reason of their own: each is what its sibling
//! export computes, and written in place each loop of `List.beni` has its
//! own property accesses, where one shared sibling function's go
//! megamorphic across every loop of a program.
//!
//! Keyed on the core package, the module's name and the value's name, never
//! on a user's spelling: a root-package `Basics` is an ordinary module. The
//! reference is an `ext_value` from another module, or a `top` when the
//! module being lowered IS the core module (`Basics.negate` calls `sub`).

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");

const Inst = Bir.Inst;

pub const Which = enum {
    // `Basics`
    add,
    sub,
    mul,
    fdiv,
    pow,
    lt,
    gt,
    le,
    ge,
    not,
    negate,
    /// `&&` and `||`: `Lower.logicalExpr` writes them before this module is
    /// asked (§4, correction 3), and they are here so that `Reach` drops
    /// their edge too.
    @"and",
    @"or",
    // `Int32`
    int32_fromInt,
    int32_toInt,
    int32_toUnsignedInt,
    int32_add,
    int32_sub,
    int32_and,
    int32_or,
    int32_xor,
    int32_shiftLeft,
    int32_shiftRight,
    int32_shiftRightZero,
    // `List`'s core-private primitives, which only `List.beni` can name
    // (`backend.md` §4, *`List.beni`'s loops read and write in place*):
    // `at a i` is `a[i]`, `put b i x` is the statement `b[i] = x;` and then
    // `b`, `identical x y` is `x === y`, `kept s o b` is `s ? o : b`, and
    // `half n` is `n >>> 1`. And the one `pub` one: `List.length xs` is
    // `xs.length`, which every form of a list answers (§4, *What a reader
    // of a list may rely on*).
    list_at,
    list_put,
    list_identical,
    list_kept,
    list_half,
    list_length,

    /// How many arguments a saturated call passes.
    pub fn arity(w: Which) u32 {
        return switch (w) {
            .not, .negate, .int32_fromInt, .int32_toInt, .int32_toUnsignedInt, .list_half, .list_length => 1,
            .list_put, .list_kept => 3,
            else => 2,
        };
    }
};

const basics = [_]struct { []const u8, Which }{
    .{ "add", .add },  .{ "sub", .sub }, .{ "mul", .mul },       .{ "fdiv", .fdiv },
    .{ "pow", .pow },  .{ "lt", .lt },   .{ "gt", .gt },         .{ "le", .le },
    .{ "ge", .ge },    .{ "not", .not }, .{ "negate", .negate }, .{ "and", .@"and" },
    .{ "or", .@"or" },
};

const int32 = [_]struct { []const u8, Which }{
    .{ "fromInt", .int32_fromInt },       .{ "toInt", .int32_toInt },                   .{ "toUnsignedInt", .int32_toUnsignedInt },
    .{ "add", .int32_add },               .{ "sub", .int32_sub },                       .{ "and", .int32_and },
    .{ "or", .int32_or },                 .{ "xor", .int32_xor },                       .{ "shiftLeft", .int32_shiftLeft },
    .{ "shiftRight", .int32_shiftRight }, .{ "shiftRightZero", .int32_shiftRightZero },
};

const list = [_]struct { []const u8, Which }{
    .{ "at", .list_at },     .{ "put", .list_put },   .{ "identical", .list_identical },
    .{ "kept", .list_kept }, .{ "half", .list_half }, .{ "length", .list_length },
};

/// The operator `inst` names, or null. `module` is the module `bir` is;
/// `interner` is anything with `slice(Symbol) []const u8`.
pub fn of(graph: *const Graph, interfaces: []const Interface, bir: *const Bir, module: Graph.Index, inst: Inst.Index, interner: anytype) ?Which {
    const d = bir.instData(inst);
    const owner: Graph.Index, const value: []const u8 = switch (bir.instTag(inst)) {
        .top => blk: {
            if (d.lhs >= bir.decls.len) return null;
            break :blk .{ module, interner.slice(bir.symbol(bir.decls[d.lhs].name)) };
        },
        .ext_value => blk: {
            const m: Graph.Index = @enumFromInt(d.lhs);
            if (m.int() >= interfaces.len) return null;
            const iface = &interfaces[m.int()];
            if (d.rhs >= iface.values.len) return null;
            break :blk .{ m, interner.slice(iface.symbols[@intFromEnum(iface.values[d.rhs].name)]) };
        },
        else => return null,
    };
    if (graph.module(owner).package != .core) return null;
    const name = interner.slice(graph.moduleName(owner));
    const table: []const struct { []const u8, Which } = if (std.mem.eql(u8, name, "Basics"))
        &basics
    else if (std.mem.eql(u8, name, "Int32"))
        &int32
    else if (std.mem.eql(u8, name, "List"))
        &list
    else
        return null;
    for (table) |row| if (std.mem.eql(u8, row[0], value)) return row[1];
    return null;
}
