//! The generator's type store (docs/design/compare-bench.md §3.3).
//!
//! Types are interned as `Type = enum(u32)` indices, so equality is an
//! integer compare. Each type is a run of words in one shared `words` array:
//! `[tag, payload...]`. `Var(i)` names the i-th type parameter of the
//! declaration it occurs in (a function's generic variables, or a type
//! declaration's parameters); it never escapes that declaration except by
//! substitution.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Type = enum(u32) {
    int = 0,
    float = 1,
    string = 2,
    bool = 3,
    _,
};

pub const Tag = enum(u32) { int, float, string, bool, pair, list, func, named, @"var" };

const Store = @This();

/// `[start, len]` of each type's words.
spans: std.ArrayList([2]u32) = .empty,
words: std.ArrayList(u32) = .empty,
map: std.HashMapUnmanaged(Key, Type, KeyContext, 80) = .empty,

const Key = struct { start: u32, len: u32 };

/// Hashing reads the words through the store, so the context carries it.
const KeyContext = struct {
    store: *const Store,
    pub fn hash(ctx: KeyContext, k: Key) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(ctx.store.words.items[k.start..][0..k.len]));
    }
    pub fn eql(ctx: KeyContext, a: Key, b: Key) bool {
        const w = ctx.store.words.items;
        return std.mem.eql(u32, w[a.start..][0..a.len], w[b.start..][0..b.len]);
    }
};

pub fn init(gpa: Allocator) !Store {
    var s: Store = .{};
    inline for (.{ Tag.int, Tag.float, Tag.string, Tag.bool }) |t| {
        _ = try s.intern(gpa, &.{@intFromEnum(t)});
    }
    return s;
}

pub fn deinit(s: *Store, gpa: Allocator) void {
    s.spans.deinit(gpa);
    s.words.deinit(gpa);
    s.map.deinit(gpa);
}

fn intern(s: *Store, gpa: Allocator, ws: []const u32) !Type {
    const start: u32 = @intCast(s.words.items.len);
    try s.words.appendSlice(gpa, ws);
    const key: Key = .{ .start = start, .len = @intCast(ws.len) };
    const gop = try s.map.getOrPutContext(gpa, key, .{ .store = s });
    if (gop.found_existing) {
        s.words.shrinkRetainingCapacity(start);
        return gop.value_ptr.*;
    }
    const t: Type = @enumFromInt(s.spans.items.len);
    try s.spans.append(gpa, .{ start, key.len });
    gop.value_ptr.* = t;
    return t;
}

fn slice(s: *const Store, t: Type) []const u32 {
    const sp = s.spans.items[@intFromEnum(t)];
    return s.words.items[sp[0]..][0..sp[1]];
}

pub fn tag(s: *const Store, t: Type) Tag {
    return @enumFromInt(s.slice(t)[0]);
}

pub fn pair(s: *Store, gpa: Allocator, a: Type, b: Type) !Type {
    return s.intern(gpa, &.{ @intFromEnum(Tag.pair), @intFromEnum(a), @intFromEnum(b) });
}

pub fn list(s: *Store, gpa: Allocator, a: Type) !Type {
    return s.intern(gpa, &.{ @intFromEnum(Tag.list), @intFromEnum(a) });
}

pub fn func(s: *Store, gpa: Allocator, params: []const Type, ret: Type) !Type {
    var buf: [32]u32 = undefined;
    buf[0] = @intFromEnum(Tag.func);
    buf[1] = @intFromEnum(ret);
    for (params, 0..) |p, i| buf[2 + i] = @intFromEnum(p);
    return s.intern(gpa, buf[0 .. 2 + params.len]);
}

pub fn named(s: *Store, gpa: Allocator, decl: u32, args: []const Type) !Type {
    var buf: [32]u32 = undefined;
    buf[0] = @intFromEnum(Tag.named);
    buf[1] = decl;
    for (args, 0..) |p, i| buf[2 + i] = @intFromEnum(p);
    return s.intern(gpa, buf[0 .. 2 + args.len]);
}

pub fn tvar(s: *Store, gpa: Allocator, i: u32) !Type {
    return s.intern(gpa, &.{ @intFromEnum(Tag.@"var"), i });
}

/// Pair components, list element, or the var index, as `a`/`b`.
pub fn pairParts(s: *const Store, t: Type) [2]Type {
    const w = s.slice(t);
    return .{ @enumFromInt(w[1]), @enumFromInt(w[2]) };
}

pub fn listElem(s: *const Store, t: Type) Type {
    return @enumFromInt(s.slice(t)[1]);
}

pub fn funcRet(s: *const Store, t: Type) Type {
    return @enumFromInt(s.slice(t)[1]);
}

pub fn funcParams(s: *const Store, t: Type) []const Type {
    return @ptrCast(s.slice(t)[2..]);
}

pub fn namedDecl(s: *const Store, t: Type) u32 {
    return s.slice(t)[1];
}

pub fn namedArgs(s: *const Store, t: Type) []const Type {
    return @ptrCast(s.slice(t)[2..]);
}

pub fn varIndex(s: *const Store, t: Type) u32 {
    return s.slice(t)[1];
}

/// `t` with every `Var(i)` replaced by `args[i]`.
pub fn subst(s: *Store, gpa: Allocator, t: Type, args: []const Type) Allocator.Error!Type {
    switch (s.tag(t)) {
        .int, .float, .string, .bool => return t,
        .@"var" => return args[s.varIndex(t)],
        .pair => {
            const p = s.pairParts(t);
            return s.pair(gpa, try s.subst(gpa, p[0], args), try s.subst(gpa, p[1], args));
        },
        .list => return s.list(gpa, try s.subst(gpa, s.listElem(t), args)),
        .func => {
            // Copied first: interning below may move `words`.
            var src: [30]Type = undefined;
            const n = s.funcParams(t).len;
            @memcpy(src[0..n], s.funcParams(t));
            const ret = s.funcRet(t);
            var buf: [30]Type = undefined;
            for (src[0..n], 0..) |p, i| buf[i] = try s.subst(gpa, p, args);
            return s.func(gpa, buf[0..n], try s.subst(gpa, ret, args));
        },
        .named => {
            var src: [30]Type = undefined;
            const n = s.namedArgs(t).len;
            @memcpy(src[0..n], s.namedArgs(t));
            const decl = s.namedDecl(t);
            var buf: [30]Type = undefined;
            for (src[0..n], 0..) |p, i| buf[i] = try s.subst(gpa, p, args);
            return s.named(gpa, decl, buf[0..n]);
        },
    }
}

/// Whether `Var(i)` occurs anywhere in `t`.
pub fn mentionsVar(s: *const Store, t: Type, i: u32) bool {
    return switch (s.tag(t)) {
        .int, .float, .string, .bool => false,
        .@"var" => s.varIndex(t) == i,
        .pair => s.mentionsVar(s.pairParts(t)[0], i) or s.mentionsVar(s.pairParts(t)[1], i),
        .list => s.mentionsVar(s.listElem(t), i),
        .func => {
            for (s.funcParams(t)) |p| if (s.mentionsVar(p, i)) return true;
            return s.mentionsVar(s.funcRet(t), i);
        },
        .named => {
            for (s.namedArgs(t)) |p| if (s.mentionsVar(p, i)) return true;
            return false;
        },
    };
}

/// Whether any `Var` occurs in `t`.
pub fn hasVars(s: *const Store, t: Type) bool {
    return switch (s.tag(t)) {
        .int, .float, .string, .bool => false,
        .@"var" => true,
        .pair => s.hasVars(s.pairParts(t)[0]) or s.hasVars(s.pairParts(t)[1]),
        .list => s.hasVars(s.listElem(t)),
        .func => {
            for (s.funcParams(t)) |p| if (s.hasVars(p)) return true;
            return s.hasVars(s.funcRet(t));
        },
        .named => {
            for (s.namedArgs(t)) |p| if (s.hasVars(p)) return true;
            return false;
        },
    };
}

/// Whether a function type occurs anywhere in `t`.
pub fn hasFunc(s: *const Store, t: Type) bool {
    return switch (s.tag(t)) {
        .int, .float, .string, .bool, .@"var" => false,
        .func => true,
        .pair => s.hasFunc(s.pairParts(t)[0]) or s.hasFunc(s.pairParts(t)[1]),
        .list => s.hasFunc(s.listElem(t)),
        .named => {
            for (s.namedArgs(t)) |p| if (s.hasFunc(p)) return true;
            return false;
        },
    };
}

/// The number of type-expression nodes `t` prints as (§5.3).
pub fn size(s: *const Store, t: Type) u32 {
    return switch (s.tag(t)) {
        .int, .float, .string, .bool, .@"var" => 1,
        .pair => 1 + s.size(s.pairParts(t)[0]) + s.size(s.pairParts(t)[1]),
        .list => 1 + s.size(s.listElem(t)),
        .func => {
            var n: u32 = 1 + s.size(s.funcRet(t));
            for (s.funcParams(t)) |p| n += s.size(p);
            return n;
        },
        .named => {
            var n: u32 = 1;
            for (s.namedArgs(t)) |p| n += s.size(p);
            return n;
        },
    };
}

/// The nesting depth of `t`, for bounding what synthesis builds.
pub fn depth(s: *const Store, t: Type) u32 {
    return switch (s.tag(t)) {
        .int, .float, .string, .bool, .@"var" => 0,
        .pair => 1 + @max(s.depth(s.pairParts(t)[0]), s.depth(s.pairParts(t)[1])),
        .list => 1 + s.depth(s.listElem(t)),
        .func => {
            var n: u32 = s.depth(s.funcRet(t));
            for (s.funcParams(t)) |p| n = @max(n, s.depth(p));
            return n + 1;
        },
        .named => {
            var n: u32 = 0;
            for (s.namedArgs(t)) |p| n = @max(n, s.depth(p));
            return n + 1;
        },
    };
}

test "interning makes equal types identical" {
    const gpa = std.testing.allocator;
    var s = try Store.init(gpa);
    defer s.deinit(gpa);
    const a = try s.list(gpa, .int);
    const b = try s.list(gpa, .int);
    try std.testing.expectEqual(a, b);
    const v = try s.tvar(gpa, 0);
    const f = try s.func(gpa, &.{ v, .string }, try s.pair(gpa, v, .bool));
    const g = try s.subst(gpa, f, &.{.int});
    try std.testing.expectEqual(Tag.func, s.tag(g));
    try std.testing.expectEqual(Type.int, s.funcParams(g)[0]);
    try std.testing.expect(s.mentionsVar(f, 0));
    try std.testing.expect(!s.hasVars(g));
}
