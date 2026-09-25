//! v2's constraint tree and the generator's state (checker-v2.md §6).
//!
//! One tree per top-level binding group, generated in one pass and solved
//! left to right (§6.1). The node set is v1's minus what v2 does not have
//! yet (`method`, R6a's) or at all (the dead `equatable` marker node, CK-18),
//! plus:
//!
//!   - `instantiate` names the VARIABLE to copy for a local or `top`
//!     reference, resolved while the node is built (I11, §6.2), or leaves a
//!     reference the solver must type from the Bir or an interface
//!     (constructors, imports, schema members) with `reference`;
//!   - `binders_end` occurs-checks the binders of the lambda or `case`
//!     branch that just ended (§6.3, §8.2);
//!   - `member` says which declaration the constraints that follow belong
//!     to, which is who a failure is attributed to (§15.2) and whose locals
//!     a message names a callee from.
//!
//! The per-form rules are v1's (`checker.md` §6.1), in `Expr.zig`,
//! `Pattern.zig` and `Decl.zig`; this file is the tree, the variables and
//! the three lists every form appends to.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../../bir/Bir.zig");
const InternPool = @import("../../InternPool.zig");
const TypeStore = @import("../../check/TypeStore.zig");
const Types = @import("../../check/Types.zig");
const CategoryFile = @import("../../check/Category.zig");
const Context = @import("../Context.zig");
const Generalize = @import("../Generalize.zig");
const Parse = @import("../../parse/Parse.zig");

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;
/// v1's category, kept: it is what the shared message texts are written
/// against (`checker-v2.md` §15.1, *As built by R4b*).
pub const Category = CategoryFile.Category;
pub const Binder = Generalize.Binder;
pub const Annotated = Generalize.Annotated;

/// Index into `Tree.nodes`.
pub const Constraint = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn int(c: Constraint) u32 {
        return @intFromEnum(c);
    }
};

pub const Node = struct {
    tag: Tag,
    category: Category,
    region: Bir.Inst.Index,
    a: u32,
    b: u32,

    pub const Tag = enum(u8) {
        true_,
        /// `a` = start into `extra`, `b` = count of `Constraint`s.
        and_,
        /// `a` = expected, `b` = actual.
        equal,
        /// `a` = `extra` index of a `Call` (checker.md §8.3's shape).
        call,
        /// `a` = the target; `b` = the variable to copy (`Var` as an
        /// integer). The copy is the identity on a node that is not
        /// generalised (§6.2, *As built by R4b*).
        instantiate,
        /// `a` = the target; the type is the one the reference at `region`
        /// names (`Instantiate.reference`), copied.
        reference,
        /// `a` = `extra` index of a `Let`.
        let_,
        /// `a` = start, `b` = count into `Tree.binders`: occurs-check them now.
        binders_end,
        /// `a` = a declaration index: what follows belongs to it.
        member,
        /// `e.i` (§4.5): `a` = the tuple's variable, `b` = `extra` index of
        /// a `TupleIndex`. Decided now when the tuple is known, else an
        /// obligation on it.
        tuple_index,
        /// A `${e}` part (§4.5): `a` = the part's variable.
        interpolatable,
        /// A record literal (§6.5, CK-59): `a` = `extra` index of a
        /// `RecordLiteral`. The solver chooses the order of its two halves.
        record,
        /// `e?` (§8.6): `a` = `extra` index of a `Try`. Decided now when
        /// either side is known, else an obligation on both.
        try_,
        /// A form the generator must never meet in R4b's subset: `internal`
        /// at `region`, and `a` (the expected type) poisoned (review S1).
        internal,
    };
};

/// Payload of `Node.Tag.let_`: one `let` group's frame (§8.1).
pub const Let = struct {
    rank: u32,
    /// The variables the generator made at `rank` for this group: the
    /// frame's young pool when it is pushed.
    vars_start: u32,
    vars_len: u32,
    /// Indices into `Tree.binders`: what the boundary occurs-checks.
    binders_start: u32,
    binders_len: u32,
    /// `Annotated` records in `Tree.annotated`.
    annotated_start: u32,
    annotated_len: u32,
    header_con: Constraint,
    body_con: Constraint,
};

/// Payload of `Node.Tag.call`: v1's, verbatim.
pub const Call = struct {
    callee: Var,
    args_start: u32,
    args_len: u32,
    result: Var,
    flavor: Flavor,

    pub const Flavor = enum(u32) { call, ctor_pattern };
};

/// Payload of `Node.Tag.tuple_index`.
pub const TupleIndex = struct { index: u32, result: Var };

/// Payload of `Node.Tag.try_`: the subject, the result variable of the
/// `?`'s target (the declaration or `let` definition it returns from), and
/// the instruction's own value (§8.6).
pub const Try = struct { subject: Var, target: Var, value: Var };

/// Payload of `Node.Tag.record`: the literal meets `expected` as `record`,
/// and `fields` constrains its fields.
pub const RecordLiteral = struct { expected: Var, record: Var, fields: Constraint };

/// One binding group's constraints.
pub const Tree = struct {
    nodes: std.MultiArrayList(Node) = .empty,
    extra: std.ArrayList(u32) = .empty,
    binders: std.ArrayList(Binder) = .empty,
    annotated: std.ArrayList(Annotated) = .empty,
    root: Constraint = .none,

    pub fn deinit(t: *Tree, gpa: Allocator) void {
        t.nodes.deinit(gpa);
        t.extra.deinit(gpa);
        t.binders.deinit(gpa);
        t.annotated.deinit(gpa);
    }

    pub fn node(t: *const Tree, c: Constraint) Node {
        return t.nodes.get(c.int());
    }

    pub fn extraData(t: *const Tree, index: u32, comptime T: type) T {
        var i: usize = index;
        var result: T = undefined;
        inline for (std.meta.fields(T)) |field| {
            @field(result, field.name) = switch (@typeInfo(field.type)) {
                .@"enum" => @enumFromInt(t.extra.items[i]),
                .int => t.extra.items[i],
                else => @compileError("unexpected extra field type: " ++ @typeName(field.type)),
            };
            i += 1;
        }
        return result;
    }

    pub fn vars(t: *const Tree, start: u32, len: u32) []const Var {
        return @ptrCast(t.extra.items[start..][0..len]);
    }

    pub fn words(t: *const Tree, start: u32, len: u32) []const u32 {
        return t.extra.items[start..][0..len];
    }

    pub fn constraints(t: *const Tree, start: u32, len: u32) []const Constraint {
        return @ptrCast(t.extra.items[start..][0..len]);
    }
};

/// The generator's state: the tree it writes, the rank and pool of the
/// frame being generated, and the module-wide local table it resolves
/// `.local` references against.
pub const Generator = struct {
    cx: *const Context,
    tree: *Tree,
    gpa: Allocator,
    /// The rank expressions are generated at; a `let` group bumps it.
    rank: u32,
    /// Variables made at `rank` since the current frame opened.
    pool: std.ArrayList(Var) = .empty,
    /// Indices into `tree.binders` registered in the current frame.
    frame_binders: std.ArrayList(u32) = .empty,
    /// `tree.annotated` indices of the current frame's annotated bindings.
    frame_annotated: std.ArrayList(u32) = .empty,
    /// Per local of the module (absolute index), the variable its binder
    /// made: written by patterns and `let` declarations, read by `.local`
    /// references. Generation order guarantees the write comes first
    /// (§6.2, *As built by R4b*). Also what `dump --stage=types` prints.
    local_type: []Var.Optional,
    /// Per declaration: its published scheme, or — for an unannotated
    /// member of the group being generated — its monomorphic variable.
    decl_scheme: []Var.Optional,
    /// The declaration being generated.
    decl: Bir.DeclIndex = @enumFromInt(0),
    locals_base: u32 = 0,
    /// The recursion guard of v1's generator: the parser bounds a
    /// declaration at `Parse.max_depth` levels, so a file it accepted never
    /// reaches this, and one that could was already reported.
    depth: u32 = 0,
    /// The result variable of the declaration being generated, when it has
    /// parameters: the target of a `?` whose instruction names none (§8.6).
    decl_result: ?Var = null,
    /// The `let` definitions with parameters being generated, innermost
    /// last, and their result variables: what a `?` inside one returns from.
    targets: std.ArrayList(Target) = .empty,

    pub const Target = struct { inst: Bir.Inst.Index, result: Var };

    pub const max_depth = Parse.max_depth + 104;

    pub fn deinit(g: *Generator) void {
        g.pool.deinit(g.gpa);
        g.frame_binders.deinit(g.gpa);
        g.frame_annotated.deinit(g.gpa);
        g.targets.deinit(g.gpa);
    }

    // ---- Tree building ---------------------------------------------------

    pub fn add(g: *Generator, tag: Node.Tag, region: Bir.Inst.Index, a: u32, b: u32, category: Category) Error!Constraint {
        const index: Constraint = @enumFromInt(g.tree.nodes.len);
        try g.tree.nodes.append(g.gpa, .{ .tag = tag, .category = category, .region = region, .a = a, .b = b });
        return index;
    }

    pub fn true_(g: *Generator) Error!Constraint {
        return g.add(.true_, @enumFromInt(0), 0, 0, .{});
    }

    pub fn equal(g: *Generator, expected: Var, actual: Var, region: Bir.Inst.Index, category: Category) Error!Constraint {
        return g.add(.equal, region, @intFromEnum(expected), @intFromEnum(actual), category);
    }

    pub fn conj(g: *Generator, items: []const Constraint) Error!Constraint {
        if (items.len == 0) return g.true_();
        if (items.len == 1) return items[0];
        const start: u32 = @intCast(g.tree.extra.items.len);
        try g.tree.extra.appendSlice(g.gpa, @ptrCast(items));
        return g.add(.and_, @enumFromInt(0), start, @intCast(items.len), .{});
    }

    pub fn addExtra(g: *Generator, value: anytype) Error!u32 {
        const T = @TypeOf(value);
        const start: u32 = @intCast(g.tree.extra.items.len);
        inline for (std.meta.fields(T)) |field| {
            const word: u32 = switch (@typeInfo(field.type)) {
                .@"enum" => @intFromEnum(@field(value, field.name)),
                .int => @field(value, field.name),
                else => @compileError("unexpected extra field type: " ++ @typeName(field.type)),
            };
            try g.tree.extra.append(g.gpa, word);
        }
        return start;
    }

    /// Copy `v`'s scheme into `target` at the use.
    pub fn instantiate(g: *Generator, target: Var, v: Var, region: Bir.Inst.Index, category: Category) Error!Constraint {
        return g.add(.instantiate, region, @intFromEnum(target), @intFromEnum(v), category);
    }

    // ---- Variables -------------------------------------------------------

    pub fn fresh(g: *Generator, content: TypeStore.Content) Error!Var {
        const v = try g.cx.store.fresh(content, g.rank);
        try g.pool.append(g.gpa, v);
        return v;
    }

    pub fn freshFlex(g: *Generator) Error!Var {
        return g.fresh(.{ .flex = .{} });
    }

    pub fn freshKind(g: *Generator, kind: TypeStore.Kind) Error!Var {
        return g.fresh(.{ .flex = .{ .kind = kind } });
    }

    /// `T` with no arguments, or a poisoned variable when core is absent.
    pub fn primitive(g: *Generator, id: Types.TypeId) Error!Var {
        if (id == .none) return g.fresh(.err);
        return g.fresh(.{ .structure = .{ .app = .{ .type = id, .args = .empty } } });
    }

    pub fn applied(g: *Generator, id: Types.TypeId, args: []const Var) Error!Var {
        if (id == .none) return g.fresh(.err);
        const range = try g.cx.store.addVars(args);
        return g.fresh(.{ .structure = .{ .app = .{ .type = id, .args = range } } });
    }

    /// `p1, …, pn -> result`: one n-ary function type.
    pub fn func(g: *Generator, params: []const Var, result: Var) Error!Var {
        const range = try g.cx.store.addVars(params);
        return g.fresh(.{ .structure = .{ .func = .{ .params = range, .result = result } } });
    }

    /// Where the store stands, for `adoptSince`.
    pub fn storeMark(g: *const Generator) u32 {
        return g.cx.store.count();
    }

    /// Pool every variable the store gained since `mark` at the current
    /// rank: `Types.Builder` makes variables without `fresh`.
    pub fn adoptSince(g: *Generator, mark: u32) Error!void {
        var i = mark;
        while (i < g.cx.store.count()) : (i += 1) {
            const v: Var = @enumFromInt(i);
            if (g.cx.store.rank(v) == g.rank) try g.pool.append(g.gpa, v);
        }
    }

    // ---- Binders (§6.3) ----------------------------------------------------

    /// Register a binder with the current frame; returns its index in
    /// `tree.binders`, which `binders_end` ranges over.
    pub fn binder(g: *Generator, v: Var, region: Bir.Inst.Index, name: Symbol.Optional) Error!u32 {
        return g.binderOf(.pattern, v, region, name);
    }

    /// A `let` or top-level header (§6.3).
    pub fn header(g: *Generator, v: Var, region: Bir.Inst.Index, name: Symbol.Optional) Error!u32 {
        return g.binderOf(.header, v, region, name);
    }

    fn binderOf(g: *Generator, kind: Binder.Kind, v: Var, region: Bir.Inst.Index, name: Symbol.Optional) Error!u32 {
        const index: u32 = @intCast(g.tree.binders.items.len);
        try g.tree.binders.append(g.gpa, .{ .v = v, .region = region, .name = name, .kind = kind, .decl = @intFromEnum(g.decl) });
        try g.frame_binders.append(g.gpa, index);
        return index;
    }

    /// Occurs-check the binders registered since `start`, now.
    pub fn bindersEnd(g: *Generator, start: u32) Error!?Constraint {
        const end: u32 = @intCast(g.tree.binders.items.len);
        if (end == start) return null;
        for (g.tree.binders.items[start..end]) |*b| b.kind = .ended;
        return try g.add(.binders_end, @enumFromInt(0), start, end - start, .{});
    }

    /// A local's name. `index` is relative to the declaration.
    pub fn nameOfLocal(g: *const Generator, index: u32) Symbol.Optional {
        const bir = g.cx.bir;
        const at = g.locals_base + index;
        if (at >= bir.locals.len) return .none;
        const l = bir.locals[at];
        if (l.name.unwrap()) |s| return bir.symbols[s].toOptional();
        return .none;
    }

    /// Bind local `index` (relative) to `v`.
    pub fn setLocal(g: *Generator, index: u32, v: Var) void {
        const at = g.locals_base + index;
        if (at < g.local_type.len) g.local_type[at] = v.toOptional();
    }

    /// The variable of local `index` (relative), or null when its binder
    /// was never generated (a poisoned tree).
    pub fn localVar(g: *const Generator, index: u32) ?Var {
        const at = g.locals_base + index;
        if (at >= g.local_type.len) return null;
        return g.local_type[at].unwrap();
    }

    /// The result variable a `?` returns from (§8.6): the `let` definition
    /// its instruction names, or the declaration when it names none. Null
    /// only on a poisoned tree (lowering always gives a `?` a target, or
    /// reports it: `language.md` §6.6).
    pub fn targetResult(g: *const Generator, target: Bir.Inst.OptionalIndex) ?Var {
        const inst = target.unwrap() orelse return g.decl_result;
        var i = g.targets.items.len;
        while (i > 0) {
            i -= 1;
            if (g.targets.items[i].inst == inst) return g.targets.items[i].result;
        }
        return null;
    }
};
