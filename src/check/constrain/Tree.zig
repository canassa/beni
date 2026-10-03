//! The constraint tree and the generator's state (checker-v2.md §6).
//!
//! One tree per top-level binding group, generated in one pass and solved
//! left to right (§6.1). The node set is Elm's, plus:
//!
//!   - `instantiate` names the VARIABLE to copy for a local or `top`
//!     reference, resolved while the node is built (§6.2: the solver reads
//!     no generation-time context), or leaves a
//!     reference the solver must type from the Bir or an interface
//!     (constructors, imports, schema members) with `reference`;
//!   - `binders_end` occurs-checks the binders of the lambda or `case`
//!     branch that just ended (§6.3, §8.2);
//!   - `member` says which declaration the constraints that follow belong
//!     to, which is who a failure is attributed to (§15.2) and whose locals
//!     a message names a callee from.
//!
//! The per-form rules are `checker.md` §6.1's, in `Expr.zig`,
//! `Pattern.zig` and `Decl.zig`; this file is the tree, the variables and
//! the three lists every form appends to.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../../bir/Bir.zig");
const InternPool = @import("../../InternPool.zig");
const TypeStore = @import("../TypeStore.zig");
const lists = @import("../../lists.zig");
const Types = @import("../Types.zig");
const CategoryFile = @import("../Category.zig");
const Context = @import("../Context.zig");
const Generalize = @import("../Generalize.zig");
const Evidence = @import("../Evidence.zig");
const Groups = @import("../Groups.zig");
const Effects = @import("../Effects.zig");
const Parse = @import("../../parse/Parse.zig");

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;
/// The category the shared message texts are written against
/// (`checker-v2.md` §15.1).
pub const Category = CategoryFile.Category;
pub const Binder = Generalize.Binder;
pub const Annotated = Generalize.Annotated;

/// Index into `Tree.nodes`.
pub const Constraint = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn int(c: Constraint) u32 {
        return @backingInt(c);
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
        /// generalised (§6.2).
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
        /// A record literal (§6.5): `a` = `extra` index of a
        /// `RecordLiteral`. The solver chooses the order of its two halves.
        record,
        /// `e?` (§8.6): `a` = `extra` index of a `Try`. Decided now when
        /// either side is known, else an obligation on both.
        try_,
        /// A method requirement at `region` (static-dispatch-spike.md §6.2
        /// Rule U0; checker-v2.md §9.1): `a` = `extra` index of a `Method`.
        /// Emitted after the receiver's constraints and before the
        /// arguments', so a receiver already known is resolved inline and
        /// seeds the arguments' types.
        method,
        /// A reference to declaration `b` of a group that was not `done` when
        /// this one was generated (§10.2): `a` = the target. The solver
        /// demands the group — nesting it, or taking the in-flight link — and
        /// then instantiates or shares (`Solve.demanded`).
        demand,
        /// A form the generator must never meet: `internal` at `region`, and
        /// `a` (the expected type) poisoned.
        internal,
        /// A markup obligation (checker-v2.md §25.4): `a` = `extra` index of
        /// a `MarkupObligation`. Decided now when its owner is known, else
        /// an obligation riding on it.
        markup_obligation,
        /// A markup fault found from the syntax and the vocabulary alone
        /// (§25.3): `a` = `extra` index of a `MarkupFault`. Reported when
        /// the solver reaches it, so it is attributed to the declaration
        /// being solved.
        markup_fault,
    };
};

/// Payload of `Node.Tag.markup_obligation`: an `Obligations.Kind`, its
/// variables (`count` of them, deciding first) and the row's `index`.
pub const MarkupObligation = struct {
    kind: u32,
    count: u32,
    v0: Var,
    v1: Var,
    v2: Var,
    index: u32,
};

/// Payload of `Node.Tag.markup_fault`.
pub const MarkupFault = struct {
    kind: Kind,
    /// The token the message underlines.
    token: u32,
    /// The name the message is about: the tag, the attribute, the escape.
    name: Symbol,
    /// The element the item was written on, for its suggestions.
    tag: Symbol,
    /// `quoted_value`, `bare_value`: the row's type, as `Var`.
    type: u32,

    pub const Kind = enum(u32) {
        unknown_element,
        unknown_attribute,
        /// `name` is the element; `token` its first child.
        void_children,
        raw_attribute,
        /// A quoted attribute name beginning with `on`.
        event_escape,
        /// A quoted `srcdoc`, in any case: a document the page runs.
        srcdoc_escape,
        /// A quoted value for a row whose type no quoted value is.
        quoted_value,
        /// A bare attribute for a row that is not `Bool`.
        bare_value,
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

/// Payload of `Node.Tag.call`.
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

/// Payload of `Node.Tag.method`: the wanted a method call raises
/// (checker-v2.md §4.2). `receiver` is the value's variable, or the
/// annotation's rigid for a `type_dispatch`; `method_type` is the method's
/// type at this use.
pub const Method = struct {
    name: Symbol,
    receiver: Var,
    method_type: Var,
    /// `Evidence.Kind` as an integer.
    kind: u32,
    /// `type_dispatch` only: the type variable's name (`Symbol.Optional`).
    var_name: u32,
};

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
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| {
            @field(result, field_name) = switch (@typeInfo(field_type)) {
                .@"enum" => @fromBackingInt(@intCast(t.extra.items[i])),
                .int => t.extra.items[i],
                else => @compileError("unexpected extra field type: " ++ @typeName(field_type)),
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
    /// Variables made at `rank` since the current frame opened, above the
    /// enclosing frames': a `let` group pushes its own and pops them
    /// (`Decl.bindingGroup`).
    pool: std.ArrayList(Var) = .empty,
    /// Indices into `tree.binders` registered in the current frame, stacked
    /// the same way.
    frame_binders: std.ArrayList(u32) = .empty,
    /// `tree.annotated` indices of the current frame's annotated bindings,
    /// stacked the same way.
    frame_annotated: std.ArrayList(u32) = .empty,
    /// Per local of the module (absolute index), the variable its binder
    /// made: written by patterns and `let` declarations, read by `.local`
    /// references. Generation order guarantees the write comes first
    /// (§6.2). Also what `dump --stage=types` prints.
    local_type: []Var.Optional,
    /// The module's evidence tables: an annotated declaration's rigid
    /// reading registers its `where` clause's givens here (§4.2).
    evidence: *Evidence,
    /// Per declaration: its published scheme, or — for an unannotated
    /// member of the group being generated — its monomorphic variable.
    decl_scheme: []Var.Optional,
    /// The declaration being generated.
    decl: Bir.DeclIndex = @fromBackingInt(@intCast(0)),
    locals_base: u32 = 0,
    /// The generator's recursion guard: the parser bounds a
    /// declaration at `Parse.max_depth` levels, so a file it accepted
    /// reaches this only through markup, whose holes the parser counts once
    /// and this counts twice, as a node and as the expression it holds.
    depth: u32 = 0,
    /// How many markup roots enclose the node being generated: what a
    /// `nesting_too_deep` from the guard above is worded for.
    markup_roots: u32 = 0,
    /// The result variable of the declaration being generated, when it has
    /// parameters: the target of a `?` whose instruction names none (§8.6).
    decl_result: ?Var = null,
    /// The rigid variables the declaration being generated's annotation
    /// introduced, for a `type_dispatch` to name (static-dispatch-spike.md
    /// §4.2). Empty for an unannotated one.
    decl_rigids: []const Types.Builder.Scoped = &.{},
    /// The binding groups (§4.4), and the group being generated: a use of
    /// a group not yet `done` becomes a `demand` node (§10.2).
    groups: ?*Groups = null,
    group: u32 = 0,
    /// The `let` definitions with parameters being generated, innermost
    /// last, and their result variables: what a `?` inside one returns from.
    targets: std.ArrayList(Target) = .empty,
    /// The class a call made here joins (transparent-effects-proposal.md
    /// §14.3 rule 1): the arrow of the function whose body is being
    /// generated, or a top-level value's evaluation class. Null where
    /// nothing calls (a schema's conversions are typed, never run here).
    ambient: ?Var = null,
    /// The lambda or `let` definition whose arrow `ambient` is, or
    /// `Effects.none` for the declaration's own: what the `sync` chain names
    /// a call's caller by (transparent-effects-proposal.md §15.4).
    ambient_site: u32 = Effects.none,

    pub const Target = struct { inst: Bir.Inst.Index, result: Var };

    /// Record `callee ⊑ ambient` for a call generated now (§14.3 rule 1),
    /// made by instruction `site`.
    pub fn called(g: *Generator, callee: Var, site: Bir.Inst.Index) Error!void {
        const ambient = g.ambient orelse return;
        const effects = g.cx.effects orelse return;
        try effects.call(callee, ambient, .{ .call = @backingInt(site), .ambient = g.ambient_site });
    }

    pub const max_depth = Parse.max_depth + 104;

    // ---- Tree building ---------------------------------------------------

    pub fn add(g: *Generator, tag: Node.Tag, region: Bir.Inst.Index, a: u32, b: u32, category: Category) Error!Constraint {
        const index: Constraint = @fromBackingInt(@intCast(g.tree.nodes.len));
        try g.tree.nodes.append(g.gpa, .{ .tag = tag, .category = category, .region = region, .a = a, .b = b });
        return index;
    }

    pub fn true_(g: *Generator) Error!Constraint {
        return g.add(.true_, @fromBackingInt(@intCast(0)), 0, 0, .{});
    }

    pub fn equal(g: *Generator, expected: Var, actual: Var, region: Bir.Inst.Index, category: Category) Error!Constraint {
        return g.add(.equal, region, @backingInt(expected), @backingInt(actual), category);
    }

    pub fn conj(g: *Generator, items: []const Constraint) Error!Constraint {
        if (items.len == 0) return g.true_();
        if (items.len == 1) return items[0];
        const start: u32 = @intCast(g.tree.extra.items.len);
        try g.tree.extra.appendSlice(g.gpa, @ptrCast(items));
        return g.add(.and_, @fromBackingInt(@intCast(0)), start, @intCast(items.len), .{});
    }

    pub fn addExtra(g: *Generator, value: anytype) Error!u32 {
        const T = @TypeOf(value);
        const start: u32 = @intCast(g.tree.extra.items.len);
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| {
            const word: u32 = switch (@typeInfo(field_type)) {
                .@"enum" => @backingInt(@field(value, field_name)),
                .int => @field(value, field_name),
                else => @compileError("unexpected extra field type: " ++ @typeName(field_type)),
            };
            try g.tree.extra.append(g.gpa, word);
        }
        return start;
    }

    /// Copy `v`'s scheme into `target` at the use.
    pub fn instantiate(g: *Generator, target: Var, v: Var, region: Bir.Inst.Index, category: Category) Error!Constraint {
        return g.add(.instantiate, region, @backingInt(target), @backingInt(v), category);
    }

    // ---- Variables -------------------------------------------------------

    pub fn fresh(g: *Generator, content: TypeStore.Content) Error!Var {
        const v = try g.cx.store.fresh(content, g.rank);
        try lists.push(Var, &g.pool, g.gpa, v);
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
            const v: Var = @fromBackingInt(@intCast(i));
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
        const index = try g.binderOf(.header, v, region, name);
        g.tree.binders.items[index].header = true;
        return index;
    }

    fn binderOf(g: *Generator, kind: Binder.Kind, v: Var, region: Bir.Inst.Index, name: Symbol.Optional) Error!u32 {
        const index: u32 = @intCast(g.tree.binders.items.len);
        try g.tree.binders.append(g.gpa, .{ .v = v, .region = region, .name = name, .kind = kind, .decl = @backingInt(g.decl) });
        try g.frame_binders.append(g.gpa, index);
        return index;
    }

    /// Occurs-check the binders registered since `start`, now.
    pub fn bindersEnd(g: *Generator, start: u32) Error!?Constraint {
        const end: u32 = @intCast(g.tree.binders.items.len);
        if (end == start) return null;
        for (g.tree.binders.items[start..end]) |*b| b.kind = .ended;
        return try g.add(.binders_end, @fromBackingInt(@intCast(0)), start, end - start, .{});
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

    /// Whether a use of declaration `decl` is a `demand` node (§10.2).
    pub fn demands(g: *const Generator, decl: u32) bool {
        const gs = g.groups orelse return false;
        return gs.demands(decl, g.group);
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
