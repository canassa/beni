//! What an alias's expansion does with each of its parameters
//! (checker-v2.md §7.4, *amended 2026-11-06*), and the memo key it
//! gives a read.
//!
//! An alias's expansion is seen only through the end of its chain:
//! `TypeStore.resolved` compresses every chain to its end (§7.1), and
//! `Render` prints an alias by its name and arguments. So the links of
//! the chain, and the arguments that only they hold, are part of no
//! type. Each parameter is one of three things:
//!
//!   * **forwarded** — the chain ends at that argument's chain:
//!     `type alias Id a = a`, `type alias A1 a = A0 (A0 a)` over it. At
//!     most one is, and then no parameter is shown, because the chain
//!     ends at a type the alias did not build;
//!   * **shown** — the argument is part of the type the chain ends at,
//!     an alias's printed argument there included;
//!   * **hidden** — everything else: the argument reaches only links of
//!     the chain, or positions that a nested alias drops.
//!
//! Two applications of one alias whose shown arguments have the same
//! roots are one type, and they print the same expansion, whatever
//! their other arguments are. A read expands the first one, and makes
//! each later one an `alias` variable of its own arguments whose
//! `actual` is its forwarded argument, or the first one's chain end
//! (`Types.Builder.apply`, `InterfaceTerms.Reader.expand`). Without
//! this, `A{i} a = A{i-1} (A{i-1} a)` gives the outer application a
//! new argument root at every level, and `A64 Int` expanded 2^64
//! bodies (#1475).
//!
//! `Injective.settle` settles a declared alias's shape once per session
//! from its Bir; `ofRow` settles an interface row's from its terms.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const stamped = @import("../stamped.zig");
const Var = TypeStore.Var;

const AliasShape = @This();

/// The parameter whose argument the expansion's chain ends at, or `none`.
forward: u16 = none,
/// Bit `j`: parameter `j`'s argument is part of the type the chain ends at.
shown: u64 = 0,
/// The two fields above hold. False — an alias with more than 64
/// parameters, a recursive one, one whose expansion names a schema
/// endpoint, a free type variable or an unresolved type — means the
/// read keys this alias by all its arguments' roots, as before.
known: bool = false,

pub const none: u16 = std.math.maxInt(u16);

/// The most parameters a shape describes: one bit each in `shown`.
pub const max_params = 64;

/// Where a written type sits in the expansion of the alias being settled.
pub const Context = enum {
    /// On the chain: what the expansion's chain ends at, through the
    /// aliases on the way.
    spine,
    /// Inside the type the chain ends at.
    shown,
    /// Anywhere else.
    hidden,

    /// The context of a structure's or a nominal type's children.
    pub fn inside(c: Context) Context {
        return if (c == .hidden) .hidden else .shown;
    }

    /// The context of argument `j` of an alias of shape `nested` written
    /// here. A printed alias shows every argument it has.
    pub fn argument(c: Context, nested: AliasShape, j: usize) Context {
        return switch (c) {
            .spine => if (nested.forward == j) .spine else if (nested.isShown(j)) .shown else .hidden,
            .shown => .shown,
            .hidden => .hidden,
        };
    }
};

pub fn isShown(s: AliasShape, j: usize) bool {
    return j < max_params and s.shown & (@as(u64, 1) << @intCast(j)) != 0;
}

/// Record parameter `j` met in context `c`. False when `j` does not fit.
pub fn note(s: *AliasShape, j: usize, c: Context) bool {
    if (j >= max_params) return false;
    switch (c) {
        .spine => s.forward = @intCast(j),
        .shown => s.shown |= @as(u64, 1) << @intCast(j),
        .hidden => {},
    }
    return true;
}

/// Bit 31 of a key's first word, which a `TypeId` or a row index never
/// sets, tells a shape key from an exact one in the same memo.
pub const tag: u32 = 1 << 31;
/// The word in place of an argument the key leaves out.
const skipped: u32 = std.math.maxInt(u32);

/// The memo key of `head` applied to `args` under shape `s`: `head` with
/// `tag`, then each shown argument's root. Owned by the caller.
pub fn key(s: AliasShape, store: *TypeStore, head: u32, args: []const Var, gpa: Allocator) Allocator.Error![]u32 {
    std.debug.assert(s.known and head & tag == 0);
    const k = try gpa.alloc(u32, args.len + 1);
    k[0] = head | tag;
    for (args, k[1..], 0..) |arg, *word, j| word.* = if (s.isShown(j)) store.find(arg).int() else skipped;
    return k;
}

/// The `actual` of a later application with `args`: the forwarded
/// argument, or the first application's chain end, `end`.
pub fn actualOf(s: AliasShape, args: []const Var, end: Var) Var {
    return if (s.forward != none and s.forward < args.len) args[s.forward] else end;
}

/// What the memo keeps for the first application's `actual`: its chain
/// end, which is all a later one reads. A forwarding alias's later
/// applications read their own argument instead, so its chain is left
/// as it is.
pub fn endOf(s: AliasShape, store: *TypeStore, actual: Var) Var {
    if (s.forward != none) return actual;
    const end, _ = store.resolved(actual);
    return end;
}

/// The shapes of an interface's alias rows, settled from their terms on
/// first use, in a column by row index. One per reader, so nothing is
/// shared across threads, and a reader that applies no alias to arguments
/// makes no slot.
pub const Rows = struct {
    map: stamped.Column(u32, AliasShape) = .{},

    pub fn deinit(rows: *Rows, gpa: Allocator) void {
        rows.map.deinit(gpa);
    }

    /// The shape of row `ref`. `depth` bounds the rows nested on the way,
    /// as `InterfaceTerms.max_depth` bounds a read.
    pub fn of(rows: *Rows, iface: *const Interface, ref: u32, gpa: Allocator, max_depth: u32) Allocator.Error!AliasShape {
        return rows.settle(iface, ref, gpa, 0, max_depth);
    }

    fn settle(rows: *Rows, iface: *const Interface, ref: u32, gpa: Allocator, depth: u32, max_depth: u32) Allocator.Error!AliasShape {
        if (rows.map.get(ref)) |s| return s;
        // A row met inside its own settling is a cycle, which a writer
        // never makes: it stays unknown.
        try rows.map.put(gpa, ref, .{});
        if (depth >= max_depth) return .{};
        const body = iface.aliasBody(ref);
        if (body == .none) return .{};
        const Item = struct { at: Interface.TermIndex, c: Context };
        var work: std.ArrayList(Item) = .empty;
        defer work.deinit(gpa);
        try work.append(gpa, .{ .at = body, .c = .spine });
        var s: AliasShape = .{ .known = true };
        while (work.pop()) |item| {
            if (item.at == .none or item.at.int() >= iface.terms.len) return .{};
            const t = iface.term(item.at);
            switch (t.tag) {
                .err => return .{},
                .@"var" => if (!s.note(t.lhs, item.c)) return .{},
                .unit, .empty_record => {},
                .func => {
                    for (iface.range(t.lhs)) |w| try work.append(gpa, .{ .at = @fromBackingInt(w), .c = item.c.inside() });
                    try work.append(gpa, .{ .at = @fromBackingInt(t.rhs), .c = item.c.inside() });
                },
                .tuple => for (iface.range(t.lhs)) |w| try work.append(gpa, .{ .at = @fromBackingInt(w), .c = item.c.inside() }),
                .app => for (iface.range(t.rhs)) |w| try work.append(gpa, .{ .at = @fromBackingInt(w), .c = item.c.inside() }),
                .record => {
                    const words = iface.range(t.lhs);
                    var i: usize = 1;
                    while (i < words.len) : (i += 2) try work.append(gpa, .{ .at = @fromBackingInt(words[i]), .c = item.c.inside() });
                    try work.append(gpa, .{ .at = @fromBackingInt(t.rhs), .c = item.c.inside() });
                },
                .alias => {
                    const nested = try rows.settle(iface, t.lhs, gpa, depth + 1, max_depth);
                    if (!nested.known) return .{};
                    for (iface.range(t.rhs), 0..) |w, j| try work.append(gpa, .{ .at = @fromBackingInt(w), .c = item.c.argument(nested, j) });
                },
            }
        }
        try rows.map.put(gpa, ref, s);
        return s;
    }
};

const testing = std.testing;

test "a context maps an alias's arguments by its shape" {
    const id: AliasShape = .{ .forward = 0, .known = true };
    const pair: AliasShape = .{ .shown = 0b01, .known = true };
    try testing.expectEqual(Context.spine, Context.spine.argument(id, 0));
    try testing.expectEqual(Context.shown, Context.spine.argument(pair, 0));
    try testing.expectEqual(Context.hidden, Context.spine.argument(pair, 1));
    try testing.expectEqual(Context.shown, Context.shown.argument(pair, 1));
    try testing.expectEqual(Context.hidden, Context.hidden.argument(id, 0));
    try testing.expectEqual(Context.shown, Context.spine.inside());
    try testing.expectEqual(Context.hidden, Context.hidden.inside());
}
