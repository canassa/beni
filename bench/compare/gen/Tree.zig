//! The typed program tree (docs/design/compare-bench.md §3.4).
//!
//! One `Program` holds every module of a generated project. Declarations,
//! constructors, locals, expressions and patterns are dense arrays indexed
//! by `u32`; variable-length payloads live in the shared `extra` array. Every
//! expression and pattern carries its type. There is no syntax here: the
//! printers own spelling, precedence, layout and naming.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TypeStore = @import("Type.zig");
const Type = TypeStore.Type;

const Tree = @This();

pub const Family = enum(u8) {
    inference = 1,
    polymorphism = 2,
    patterns = 3,
    depth = 4,
    recursion = 5,
    data = 6,
    imports = 7,
    everyday = 8,

    pub const all = [_]Family{ .inference, .polymorphism, .patterns, .depth, .recursion, .data, .imports, .everyday };

    pub fn prefix(f: Family) []const u8 {
        return switch (f) {
            .inference => "Inf",
            .polymorphism => "Poly",
            .patterns => "Pat",
            .depth => "Deep",
            .recursion => "Rec",
            .data => "Data",
            .imports => "Imp",
            .everyday => "Day",
        };
    }

    pub fn parse(s: []const u8) ?Family {
        for (all) |f| if (std.mem.eql(u8, s, @tagName(f))) return f;
        return null;
    }
};

pub const Op = enum(u8) {
    int_add,
    int_sub,
    int_mul,
    float_add,
    float_sub,
    float_mul,
    str_append,
    bool_and,
    bool_or,
    int_eq,
    str_eq,
    bool_eq,
    int_lt,
    float_lt,

    pub fn operand(op: Op) Type {
        return switch (op) {
            .int_add, .int_sub, .int_mul, .int_eq, .int_lt => .int,
            .float_add, .float_sub, .float_mul, .float_lt => .float,
            .str_append, .str_eq => .string,
            .bool_and, .bool_or, .bool_eq => .bool,
        };
    }

    pub fn result(op: Op) Type {
        return switch (op) {
            .int_add, .int_sub, .int_mul => .int,
            .float_add, .float_sub, .float_mul => .float,
            .str_append => .string,
            .bool_and, .bool_or, .int_eq, .str_eq, .bool_eq, .int_lt, .float_lt => .bool,
        };
    }
};

pub const ExprTag = enum(u8) {
    lit_int, // a = value
    lit_float, // a = integer part, b = tenths digit
    lit_string, // a = number, printed "s<a>"
    lit_bool, // a = 0/1
    local, // a = Local
    global, // a = Fn, b = extra: [n, type args...]
    call, // a = callee expr, b = extra: [n, args...]
    lambda, // a = extra: [n, locals...], b = body
    let, // a = extra: [n, (local, expr)...], b = body
    @"if", // a = cond, b = extra: [then, else]
    case, // a = scrutinee, b = extra: [n, (pat, body)...]
    ctor, // a = Ctor, b = extra: [n, args...]; type args are the node type's
    pair, // a, b
    list, // a = extra: [n, elems...]
    binop, // op, a, b
    not, // a
    int_to_string, // a
    list_map, // a = list, b = lambda (1 param)
    list_filter, // a = list, b = lambda (1 param)
    list_foldl, // a = list, b = extra: [init, lambda (elem, acc)]
    pipe, // a = head, b = extra: [n, stages...]; each stage a unary global
};

pub const Expr = struct {
    tag: ExprTag,
    op: Op = .int_add,
    ty: Type,
    a: u32 = 0,
    b: u32 = 0,
};

pub const PatTag = enum(u8) {
    wild,
    bind, // a = Local
    lit_int, // a
    lit_string, // a
    lit_bool, // a
    ctor, // a = Ctor, b = extra: [n, pats...]
    pair, // a, b
};

pub const Pat = struct {
    tag: PatTag,
    ty: Type,
    a: u32 = 0,
    b: u32 = 0,
};

pub const Local = struct {
    /// Printed as `v<name>`; unique within its function.
    name: u32,
    ty: Type,
    /// Its value is known only at run time: a parameter, a lambda
    /// parameter, a pattern variable, or a binding computed from one. Roc
    /// folds everything else at compile time and warns on a condition it
    /// can decide (§19 V2), so conditions and scrutinees read one.
    dynamic: bool = false,
    /// Bound by `let` to a lambda. Roc treats a call of one with arguments
    /// known at compile time as known, whatever the lambda captures (§19
    /// V2), so such a call is dynamic only through its arguments.
    closure: bool = false,
};

pub const TypeDecl = struct {
    module: u32,
    name: []const u8,
    nparams: u32,
    ctors: std.ArrayList(u32) = .empty,
    /// Fewest nested constructor applications that build a value (§3.3).
    min_depth: u32 = std.math.maxInt(u32),
    /// The constructor that achieves `min_depth`.
    min_ctor: u32 = 0,
};

pub const Ctor = struct {
    decl: u32,
    name: []const u8,
    /// In terms of the type's parameters, `Var(i)`.
    fields: []const Type,
};

pub const Fn = struct {
    module: u32,
    name: []const u8,
    nvars: u32,
    params: []const u32, // Locals
    ret: Type,
    body: u32 = 0,
    annotated: bool = true,
    /// A member of a recursive SCC (it reaches itself). Set by `analyse`.
    recursive: bool = false,
    /// `entry : Int -> Int`, annotated in every mode (§7.2).
    entry: bool = false,
    /// Base's functions are hand-written library code, annotated always.
    library: bool = false,
    /// Set once its body is complete; synthesis only calls finished
    /// functions, or members of the SCC being built (the recursion family).
    ready: bool = false,
    /// The one instantiation this function may be used at outside its SCC.
    /// Set on the generic members of a mutually recursive group: Elm does
    /// not generalise such a group without annotations (§6.2, §19 V9).
    mono_targs: []const Type = &.{},

    pub fn sigType(f: Fn, t: *const Tree, store: *TypeStore, gpa: Allocator) !Type {
        var buf: [30]Type = undefined;
        for (f.params, 0..) |p, i| buf[i] = t.locals.items[p].ty;
        return store.func(gpa, buf[0..f.params.len], f.ret);
    }
};

pub const ModuleKind = enum { base, unit, main };

pub const Module = struct {
    name: []const u8,
    kind: ModuleKind,
    family: Family = .inference,
    unit: u32 = 0,
    types: std.ArrayList(u32) = .empty,
    fns: std.ArrayList(u32) = .empty,
    /// Modules this one references, sorted; computed by `analyse`.
    imports: std.ArrayList(u32) = .empty,
};

arena: Allocator,
store: TypeStore,
modules: std.ArrayList(Module) = .empty,
types: std.ArrayList(TypeDecl) = .empty,
ctors: std.ArrayList(Ctor) = .empty,
fns: std.ArrayList(Fn) = .empty,
locals: std.ArrayList(Local) = .empty,
exprs: std.MultiArrayList(Expr) = .empty,
pats: std.MultiArrayList(Pat) = .empty,
extra: std.ArrayList(u32) = .empty,

/// Everything is allocated from `arena`; the program is freed with it.
pub fn init(arena: Allocator) !Tree {
    return .{ .arena = arena, .store = try TypeStore.init(arena) };
}

pub fn addExpr(t: *Tree, e: Expr) !u32 {
    const i: u32 = @intCast(t.exprs.len);
    try t.exprs.append(t.arena, e);
    return i;
}

pub fn addPat(t: *Tree, p: Pat) !u32 {
    const i: u32 = @intCast(t.pats.len);
    try t.pats.append(t.arena, p);
    return i;
}

pub fn addExtra(t: *Tree, words: []const u32) !u32 {
    const i: u32 = @intCast(t.extra.items.len);
    try t.extra.appendSlice(t.arena, words);
    return i;
}

/// `[n, (a, b)...]` at `at`: the `2n` words of a `let`'s bindings or a
/// `case`'s rows.
pub fn extraPairs(t: *const Tree, at: u32) []const u32 {
    const n = t.extra.items[at];
    return t.extra.items[at + 1 ..][0 .. 2 * n];
}

/// `[n, items...]` at `at`.
pub fn extraList(t: *const Tree, at: u32) []const u32 {
    const n = t.extra.items[at];
    return t.extra.items[at + 1 ..][0..n];
}

pub fn expr(t: *const Tree, i: u32) Expr {
    return t.exprs.get(i);
}

pub fn pat(t: *const Tree, i: u32) Pat {
    return t.pats.get(i);
}

pub fn addLocal(t: *Tree, name: u32, ty: Type) !u32 {
    const i: u32 = @intCast(t.locals.items.len);
    try t.locals.append(t.arena, .{ .name = name, .ty = ty });
    return i;
}

pub fn addModule(t: *Tree, m: Module) !u32 {
    const i: u32 = @intCast(t.modules.items.len);
    try t.modules.append(t.arena, m);
    return i;
}

pub fn addTypeDecl(t: *Tree, module: u32, name: []const u8, nparams: u32) !u32 {
    const i: u32 = @intCast(t.types.items.len);
    try t.types.append(t.arena, .{ .module = module, .name = name, .nparams = nparams });
    try t.modules.items[module].types.append(t.arena, i);
    return i;
}

pub fn addCtor(t: *Tree, decl: u32, name: []const u8, fields: []const Type) !u32 {
    const i: u32 = @intCast(t.ctors.items.len);
    try t.ctors.append(t.arena, .{ .decl = decl, .name = name, .fields = try t.arena.dupe(Type, fields) });
    try t.types.items[decl].ctors.append(t.arena, i);
    return i;
}

pub fn addFn(t: *Tree, f: Fn) !u32 {
    const i: u32 = @intCast(t.fns.items.len);
    try t.fns.append(t.arena, f);
    try t.modules.items[f.module].fns.append(t.arena, i);
    return i;
}

/// The declared type `decl` applied to its own parameters, `T a b`.
pub fn selfType(t: *Tree, decl: u32) !Type {
    var buf: [8]Type = undefined;
    const n = t.types.items[decl].nparams;
    for (0..n) |i| buf[i] = try t.store.tvar(t.arena, @intCast(i));
    return t.store.named(t.arena, decl, buf[0..n]);
}

/// A constructor's field types at the instance `ty` of its declaration.
pub fn ctorFields(t: *Tree, ctor: u32, ty: Type, out: []Type) ![]Type {
    const c = t.ctors.items[ctor];
    var args: [8]Type = undefined;
    const as = t.store.namedArgs(ty);
    @memcpy(args[0..as.len], as);
    for (c.fields, 0..) |f, i| out[i] = try t.store.subst(t.arena, f, args[0..as.len]);
    return out[0..c.fields.len];
}

/// Recompute minimum constructible depths for every type declared so far
/// (§3.3), to a fixed point. A field of a parameter type counts as depth 0:
/// every instance used by the generator is itself constructible.
pub fn computeMinDepths(t: *Tree) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (t.types.items) |*d| {
            for (d.ctors.items) |ci| {
                var worst: u32 = 0;
                for (t.ctors.items[ci].fields) |f| {
                    const fd = t.minDepthOf(f);
                    if (fd == std.math.maxInt(u32)) {
                        worst = fd;
                        break;
                    }
                    worst = @max(worst, fd);
                }
                if (worst == std.math.maxInt(u32)) continue;
                if (worst + 1 < d.min_depth) {
                    d.min_depth = worst + 1;
                    d.min_ctor = ci;
                    changed = true;
                }
            }
        }
    }
}

pub fn minDepthOf(t: *const Tree, ty: Type) u32 {
    const s = &t.store;
    return switch (s.tag(ty)) {
        .int, .float, .string, .bool, .@"var" => 0,
        .list, .func => 0, // `[]`, and a lambda over a leaf
        .pair => blk: {
            const p = s.pairParts(ty);
            const a = t.minDepthOf(p[0]);
            const b = t.minDepthOf(p[1]);
            if (a == std.math.maxInt(u32) or b == std.math.maxInt(u32)) break :blk std.math.maxInt(u32);
            break :blk @max(a, b);
        },
        .named => t.types.items[s.namedDecl(ty)].min_depth,
    };
}

/// Printed function-local name number of a local.
pub fn localName(t: *const Tree, l: u32) u32 {
    return t.locals.items[l].name;
}

test "min depths make every declared type inhabited" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var t = try Tree.init(arena_state.allocator());
    const m = try t.addModule(.{ .name = "Base", .kind = .base });
    const seq = try t.addTypeDecl(m, "Seq", 1);
    const a = try t.store.tvar(t.arena, 0);
    _ = try t.addCtor(seq, "SNil", &.{});
    _ = try t.addCtor(seq, "SCons", &.{ a, try t.selfType(seq) });
    const loop = try t.addTypeDecl(m, "Loop", 0);
    _ = try t.addCtor(loop, "L", &.{try t.store.named(t.arena, loop, &.{})});
    t.computeMinDepths();
    try std.testing.expectEqual(@as(u32, 1), t.types.items[seq].min_depth);
    try std.testing.expectEqual(std.math.maxInt(u32), t.types.items[loop].min_depth);
}
