//! Constraint generation (docs/design/checker.md §6.1): one pass over a
//! binding group's Bir producing a constraint tree, which `Solve.zig` then
//! walks once.
//!
//! This is Elm's `Type/Constrain/*` and, behind it, Pottier & Rémy's HM(X)
//! (research/02 §1). **Nothing here unifies.** Generation only allocates
//! fresh variables and records obligations, which buys three things the
//! design depends on: the solver sees a whole group at once and can batch a
//! `CAnd` list in one linear pass; every rank and generalisation decision
//! lives in ONE place (`Solve.let_`); and generation is a pure function of
//! the Bir, so it is testable and — later — cacheable.
//!
//! **Expected types are pushed down**, as in Elm (`constrain env expr
//! expected`). A sub-expression is handed the variable its context already
//! knows about rather than returning a fresh one to be unified afterwards.
//! That is what makes the missing-argument diagnostic of §8.3 possible at
//! all: when the solver reaches a call it can see both how many arrows the
//! callee has AND whether the result was wanted as a function, because the
//! call's result variable IS the context's variable.
//!
//! **Ranks are assigned here, pools are filled here.** Elm's `CLet` carries
//! lists of variables for the solver to stamp with `nextRank`; beni's
//! generator knows the `let` nesting depth syntactically, so it stamps them
//! itself and hands the solver the list per `let`. The solver still owns
//! generalisation: it pushes a `let`'s variables into the pool of that rank
//! on entry, generalises what did not escape on exit, and clears the pool —
//! which is why the list is per `let` and not one shared pool per depth.
//! Sibling `let`s at the same depth would otherwise generalise each other's
//! variables before they were solved.
//!
//! **Binding groups are SCC-decomposed** (design §7 #5): over the module's
//! `refs` for top-level values, and over each `let`'s own bindings here.
//! Only a genuinely mutually recursive group shares a generalisation, which
//! bounds both generalisation cost and error blast radius. An ANNOTATED
//! binding is not an edge: its scheme is its annotation, so recursion
//! through it is already broken (checker.md §6.1).
//!
//! Regions are Bir instruction indices and nothing else; a position is
//! looked up only when a diagnostic renders (design §7, "good messages off
//! the happy path").

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Artifacts = @import("../Artifacts.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const reads = @import("reads.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Dispatch = @import("Dispatch.zig");
const Parse = @import("../parse/Parse.zig");

const Constrain = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;

/// Index into `Tree.nodes`.
pub const Constraint = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn int(c: Constraint) u32 {
        return @intFromEnum(c);
    }
};

/// What the compiler was looking at when it made an equality. Carried on
/// every node because it costs one byte plus one word and is the difference
/// between "TYPE MISMATCH" and a sentence a person can act on.
pub const Category = struct {
    tag: Tag = .general,
    /// A 1-based position (`call_arg`, `list_entry`, `case_branch`,
    /// `tuple_element`, `ctor_arg`) or a field `Symbol` (`record_field`,
    /// `field_access`, `record_update`), by tag.
    ///
    /// A field tag with `no_field` is about the record as a whole. The
    /// sentinel cannot be 0: `Symbol` 0 is the first `InternPool.WellKnown`
    /// name, which is `main` — so overloading 0 made a record field
    /// actually named `main`, the likeliest field name in an Elm-like
    /// program, render as an empty name.
    index: u32 = 0,
    /// The instruction the sentence is ABOUT, when that is not the one the
    /// span points at: an argument mismatch underlines the argument but has
    /// to name the function, and the function is only reachable from the
    /// call. `.none` means "the region itself".
    owner: Bir.Inst.OptionalIndex = .none,

    /// `index` on a field-carrying tag when the message is about the record
    /// and not one of its fields. `Symbol.Optional`'s own sentinel, so the
    /// two agree.
    pub const no_field: u32 = std.math.maxInt(u32);

    pub const Tag = enum(u8) {
        general,
        /// A declaration's body against its own annotation.
        annotation,
        /// A `let` binding's body against its annotation.
        let_annotation,
        call_arg,
        list_entry,
        case_branch,
        case_pattern,
        record_field,
        field_access,
        record_update,
        interp_part,
        tuple_element,
        try_value,
        pattern,
        ctor_arg,
        /// The value side of a `let pattern = value`.
        destructure,
    };
};

pub const Node = struct {
    tag: Tag,
    category: Category,
    /// The Bir instruction this constraint reports at.
    region: Bir.Inst.Index,
    a: u32,
    b: u32,

    pub const Tag = enum(u8) {
        /// Nothing to do. The identity of `and_`.
        true_,
        /// `a` = start into `extra`, `b` = count, of `Constraint`s solved
        /// left to right.
        and_,
        /// `a` = expected `Var`, `b` = actual `Var`.
        equal,
        /// `a` = `extra` index of a `Let`.
        let_,
        /// `a` = `extra` index of a `Call`. The shape of §8.3.
        call,
        /// Copy the scheme the reference at `region` names into `a`.
        instantiate,
        /// `equatable(a)` (checker.md §6.4).
        equatable,
        /// `interpolatable(a)`.
        interpolatable,
        /// `a` = the value, `b` = `extra` index of a `TupleIndex`.
        tuple_index,
        /// `a` = the scrutinee, `b` = `extra` index of a `Try`.
        try_,
        /// A method call's resolution (static-dispatch-spike.md §6.2 Rule
        /// U0): `a` = the RECEIVER's `Var` — for a `type_dispatch`, the
        /// annotation's rigid variable — and `b` = `extra` index of a
        /// `Method`.
        ///
        /// It is emitted BEFORE the argument constraints and after the
        /// receiver's own, inside one `and_`, which `Solve` walks left to
        /// right: that ordering IS "resolve the method before the
        /// arguments" (A.34). A concrete receiver is discharged inline
        /// here, so a lambda argument's parameters are seeded from the
        /// method's declared type before its body is checked.
        method,
    };
};

/// Payload of `Node.Tag.let_`.
pub const Let = struct {
    /// The rank the header is solved and generalised at.
    rank: u32,
    /// `Var`s the generator allocated at `rank` for this `let`, pushed into
    /// the pool on entry.
    vars_start: u32,
    vars_len: u32,
    /// `Header` records: what to generalise and occurs-check.
    header_start: u32,
    header_len: u32,
    header_con: Constraint,
    body_con: Constraint,
};

/// One binding of a `let`'s header.
pub const Header = struct {
    /// The binding's type variable, generalised when the group is done.
    v: Var,
    /// Where `infinite_type` points.
    region: Bir.Inst.Index,
    /// The bound name, for the diagnostic's prose; `.none` for a pattern
    /// binding that names nothing.
    name: Symbol.Optional,
    /// Which top-level declaration this is, so promotion can find its
    /// annotation, its `pub`-ness and its parameter count
    /// (static-dispatch-spike.md §6.4). `no_decl` for a `let` header.
    decl: u32 = no_decl,

    pub const no_decl: u32 = std.math.maxInt(u32);
};

/// Payload of `Node.Tag.call` — a saturated or partial application, and the
/// one node the arity diagnostics of §8.3 come out of.
pub const Call = struct {
    callee: Var,
    args_start: u32,
    args_len: u32,
    /// The variable the result must have; the CONTEXT's variable, which is
    /// what makes "the result was expected to be a non-function" knowable.
    result: Var,
    /// What the callee is, for the prose.
    flavor: Flavor,

    pub const Flavor = enum(u32) {
        /// `f a b` and every desugared operator.
        call,
        /// `Just x` in a pattern: same shape, different sentence.
        ctor_pattern,
    };
};

/// Payload of `Node.Tag.method` (static-dispatch-spike.md §6.1, §6.2).
pub const Method = struct {
    /// The method's name: what was written after the dot, or `eq` /
    /// `compare` for one of the six operators (§3.1).
    name: Symbol,
    /// `Bir.WellKnown` as an integer: which operator desugared into this
    /// call, or `none` for a hand-written dot-call (§1.3).
    origin: u32,
    /// The method's type AT THIS USE — `receiver, arg₁, …, argₙ -> result`
    /// for a dot-call, `arg₁, …, argₙ -> result` for a `type_dispatch`.
    fn_var: Var,
    /// 0 for a `method_call`, 1 for a `type_dispatch` (§4). The two differ
    /// in whether the receiver is a value and in which diagnostic a
    /// missing constraint gets.
    kind: u32,
    /// `type_dispatch` only: the type variable's name, for §10.8's prose.
    /// `Symbol.Optional` as an integer.
    var_name: u32,
};

/// One `let` binding rule (a) refused to generalise; see `Env.monomorphic`.
pub const Monomorphic = struct { v: Var, method: Symbol };

pub const TupleIndex = struct {
    index: u32,
    result: Var,
};

pub const Try = struct {
    /// The enclosing definition's RESULT type (checker.md §6.5).
    enclosing: Var,
    /// The unwrapped value's type.
    value: Var,
};

/// One binding group's constraints. Arena-backed by the module's store, so
/// it is released with it.
pub const Tree = struct {
    nodes: std.MultiArrayList(Node) = .empty,
    extra: std.ArrayList(u32) = .empty,
    root: Constraint = .none,

    pub fn tag(tree: *const Tree, c: Constraint) Node.Tag {
        return tree.nodes.items(.tag)[c.int()];
    }

    pub fn node(tree: *const Tree, c: Constraint) Node {
        return tree.nodes.get(c.int());
    }

    /// Read a record out of `extra` positionally, like `Bir.extraData`.
    pub fn extraData(tree: *const Tree, index: u32, comptime T: type) T {
        var i: usize = index;
        var result: T = undefined;
        inline for (std.meta.fields(T)) |field| {
            @field(result, field.name) = switch (@typeInfo(field.type)) {
                .@"enum" => @enumFromInt(tree.extra.items[i]),
                .int => tree.extra.items[i],
                else => @compileError("unexpected extra field type: " ++ @typeName(field.type)),
            };
            i += 1;
        }
        return result;
    }

    pub fn vars(tree: *const Tree, start: u32, len: u32) []const Var {
        return @ptrCast(tree.extra.items[start..][0..len]);
    }

    pub fn constraints(tree: *const Tree, start: u32, len: u32) []const Constraint {
        return @ptrCast(tree.extra.items[start..][0..len]);
    }

    pub fn headers(tree: *const Tree, start: u32, len: u32) []const Header {
        return @ptrCast(tree.extra.items[start..][0 .. len * 4]);
    }
};

comptime {
    std.debug.assert(@sizeOf(Header) == 16);
}

// ---------------------------------------------------------------------------
// The shared per-module context
// ---------------------------------------------------------------------------

/// Everything one module's check needs. Built once by `Check`, handed to the
/// generator and then to the solver; a module's check reads only its own Bir,
/// the interfaces of its imports and the store it owns, which is the
/// property checker.md §4.4 needs for DAG parallelism later.
pub const Env = struct {
    scratch: Allocator,
    store: *TypeStore,
    types: *const Types,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interner: *const InternPool.Global,
    interfaces: []const Interface,
    module: Graph.Index,
    bir: *const Bir,
    /// Scheme variable per top-level declaration; `.none` for a type or for
    /// a value whose scheme is not built yet.
    decl_scheme: []Var.Optional,
    /// Per local of the declaration being checked. Indices in the Bir are
    /// relative to the declaration, so this is a SLICE of the module's
    /// table and `locals_base` is where it starts — anything that reaches
    /// past this slice into `bir.locals` has to add it.
    local_var: []Var.Optional,
    /// The declaration's `locals_start`.
    locals_base: u32 = 0,
    /// Per instruction of the declaration being checked, relative to
    /// `inst_base`: the RESULT variable of a `let_def`, which `?` needs
    /// (checker.md §6.5). Only `let_def` slots are filled.
    inst_result: []Var.Optional,
    inst_base: u32,
    /// The enclosing declaration's result variable, for a `?` whose target
    /// is the declaration itself.
    decl_result: Var.Optional = .none,
    /// The declaration being checked, and its annotation's rigid type
    /// variables in first-appearance order (static-dispatch-spike.md §2.4,
    /// §4.2). Empty for an unannotated declaration; `decl` is
    /// `Bir.decls.len` when nothing is being checked.
    decl: u32 = 0,
    decl_rigids: []const Types.Builder.Scoped = &.{},
    /// Which evidence parameter answers each `(rigid variable, method)` of
    /// this module's annotated declarations, in the canonical order of
    /// §7.2. Flat across the module: a rigid variable belongs to exactly
    /// one declaration, so the variable alone identifies the entry.
    rigid_evidence: []const Dispatch.RigidEvidence = &.{},
    /// Every variable §6.4 rule (a) held back from a `let` generalisation,
    /// with the constraint that held it.
    ///
    /// It exists for ONE message. The boundary A.30 buys surfaces as an
    /// ordinary `type_mismatch` at the second use, by which time the
    /// constraint has been discharged against the first use's type and
    /// nothing in the store says why the binding was monomorphic. Without
    /// this the hint on that message told the author to check their
    /// arithmetic (M7).
    monomorphic: *std.ArrayList(Monomorphic),
    /// The module's dispatch table as it is built (§7.1). Owned by
    /// `ModuleCheck`; the solver appends to it and `finish` sorts it once.
    dispatch: *Dispatch.Builder,
    /// Emit the informational `warning`s of §10 — today only
    /// `ambiguous_method_receiver` (§10.9), and then only for a module of
    /// the ROOT package. True under `check` and `build` (A.83).
    informational: bool = false,
    /// Written types the reader could not finish (`Types.Builder.max_depth`,
    /// `Schemes.Writer.max_depth`), by the instruction a message points at.
    ///
    /// Collected rather than reported where the guard trips, for two
    /// reasons: the reader crosses modules (an alias body is read in ITS
    /// module, so the instruction it gave up on names no position here),
    /// and the same annotation is read more than once — once generalised
    /// for callers, once rigid for the body. `Check` sorts, deduplicates
    /// and reports this once per module. Empty on every input a person
    /// writes.
    too_deep: *std.ArrayList(Bir.Inst.Index),

    /// Another module's interface record, noted for the covered-read
    /// self-check (`reads.zig`, `plans/m4-3.md` §3.2 rows 17–22 and 25–27).
    ///
    /// **Every cross-module read of `interfaces` on the checking path goes
    /// through this**, which is what makes the `&interfaces[N]` handoff one of
    /// the three channels the enumeration is finite over. Callers keep their
    /// own bounds tests: this is a note, not a guard.
    pub fn iface(env: *const Env, m: Graph.Index) *const Interface {
        reads.note(.iface, m);
        return &env.interfaces[m.int()];
    }

    pub fn localVar(env: *const Env, index: u32) ?Var {
        if (index >= env.local_var.len) return null;
        return env.local_var[index].unwrap();
    }

    pub fn builder(env: *const Env, mode: Types.VarMode, rank: u32) Types.Builder {
        return .init(env.store, env.types, env.graph, env.artifacts, env.module, env.bir, mode, rank, env.scratch, env.interner);
    }

    /// Read `annotation` with `b` and note it when the reader ran out of
    /// depth. Every caller of `Types.Builder.read` goes through this or
    /// through `noteTooDeep`, so no guard in the checker can poison a type
    /// without a message: an `err` unifies with anything, and a
    /// declaration silently turned into one is a hole a caller's mistake
    /// falls through (`fast-compiler.md` §5).
    pub fn readAnnotation(env: *const Env, b: *Types.Builder, annotation: Bir.Inst.Index) Error!Var {
        const v = try b.read(annotation);
        if (b.too_deep) try env.noteTooDeep(annotation);
        return v;
    }

    /// Note that the type at `region` was too deeply nested to read. Not
    /// deduplicated here — `Check` sorts and deduplicates at the end,
    /// because a linear scan per note is quadratic on a generated file
    /// where every declaration trips the guard.
    pub fn noteTooDeep(env: *const Env, region: Bir.Inst.Index) Error!void {
        try env.too_deep.append(env.scratch, region);
    }
};

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

pub const Error = Allocator.Error;

pub const Generator = struct {
    env: *Env,
    tree: *Tree,
    gpa: Allocator,
    /// The rank expressions are generated at right now; a `let` bumps it.
    rank: u32,
    /// Variables allocated at `rank` since the enclosing `let` opened.
    pool: std.ArrayList(Var) = .empty,
    /// Guards against a pathological nesting depth on the C stack. The
    /// parser already refuses more than 4096 levels (language.md §10); this
    /// is the checker's own belt.
    depth: u32 = 0,
    /// The instruction an instantiation's evidence sites belong to while a
    /// CALL's callee is being generated (§7.2). `.none` everywhere else.
    site_owner: Bir.Inst.OptionalIndex = .none,

    /// See `Solve.Solver.max_depth`: the parser bounds a declaration at
    /// `Parse.max_depth` levels and this walk spends one frame per level,
    /// so a file the front end accepted cannot reach this. A file that
    /// could was reported as `nesting_too_deep` before the checker ran, so
    /// dropping the constraint here adds no second message — and there is
    /// no type to poison, because there is no tree left to constrain.
    const max_depth = Parse.max_depth + 104;

    pub fn init(env: *Env, tree: *Tree, gpa: Allocator, rank: u32) Generator {
        return .{ .env = env, .tree = tree, .gpa = gpa, .rank = rank };
    }

    pub fn deinit(g: *Generator) void {
        g.pool.deinit(g.gpa);
    }

    // ---- Tree building ---------------------------------------------------

    fn add(g: *Generator, tag: Node.Tag, region: Bir.Inst.Index, a: u32, b: u32, category: Category) Error!Constraint {
        const index: Constraint = @enumFromInt(g.tree.nodes.len);
        try g.tree.nodes.append(g.gpa, .{ .tag = tag, .category = category, .region = region, .a = a, .b = b });
        return index;
    }

    fn true_(g: *Generator) Error!Constraint {
        return g.add(.true_, @enumFromInt(0), 0, 0, .{});
    }

    /// `expected = actual`, reported at `region` as `category`.
    fn equal(g: *Generator, expected: Var, actual: Var, region: Bir.Inst.Index, category: Category) Error!Constraint {
        return g.add(.equal, region, @intFromEnum(expected), @intFromEnum(actual), category);
    }

    fn conj(g: *Generator, items: []const Constraint) Error!Constraint {
        if (items.len == 0) return g.true_();
        if (items.len == 1) return items[0];
        const start: u32 = @intCast(g.tree.extra.items.len);
        try g.tree.extra.appendSlice(g.gpa, @ptrCast(items));
        return g.add(.and_, @enumFromInt(0), start, @intCast(items.len), .{});
    }

    fn addExtra(g: *Generator, value: anytype) Error!u32 {
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

    // ---- Variables -------------------------------------------------------

    /// A fresh variable at the current rank, remembered so the enclosing
    /// `let` can generalise it.
    fn fresh(g: *Generator, content: TypeStore.Content) Error!Var {
        const v = try g.env.store.fresh(content, g.rank);
        try g.pool.append(g.gpa, v);
        return v;
    }

    fn freshFlex(g: *Generator) Error!Var {
        return g.fresh(.{ .flex = .{} });
    }

    fn freshKind(g: *Generator, kind: TypeStore.Kind) Error!Var {
        return g.fresh(.{ .flex = .{ .kind = kind } });
    }

    /// `T` with no arguments, or a poisoned variable when the core package
    /// is not in the run (a `dump` of one file, say).
    fn primitive(g: *Generator, id: Types.TypeId) Error!Var {
        if (id == .none) return g.fresh(.err);
        return g.fresh(.{ .structure = .{ .app = .{ .type = id, .args = .empty } } });
    }

    fn applied(g: *Generator, id: Types.TypeId, args: []const Var) Error!Var {
        if (id == .none) return g.fresh(.err);
        const range = try g.env.store.addVars(args);
        return g.fresh(.{ .structure = .{ .app = .{ .type = id, .args = range } } });
    }

    /// `p1, …, pn -> result`: ONE n-ary function type, whatever `n` is
    /// (language.md §6.7). There is no chain to build — that is the point
    /// of the change — and the arity is part of the structure, so two
    /// function types unify only when they take the same number of
    /// arguments.
    fn func(g: *Generator, params: []const Var, result: Var) Error!Var {
        const range = try g.env.store.addVars(params);
        return g.fresh(.{ .structure = .{ .func = .{ .params = range, .result = result } } });
    }

    // ---- Expressions -----------------------------------------------------

    /// Constrain `inst` to have type `expected`.
    pub fn expr(g: *Generator, inst: Bir.Inst.Index, expected: Var, category: Category) Error!Constraint {
        g.depth += 1;
        defer g.depth -= 1;
        if (g.depth > max_depth) return g.true_();

        const bir = g.env.bir;
        const tag = bir.instTag(inst);
        const data = bir.instData(inst);
        switch (tag) {
            // A literal integer is `number`: the closed ad-hoc set of
            // fast-compiler.md §3.1, and the whole of it for literals.
            .int => return g.equal(expected, try g.freshKind(.number), inst, category),
            .float => return g.equal(expected, try g.primitive(g.env.types.well_known.float), inst, category),
            .char => return g.equal(expected, try g.primitive(g.env.types.well_known.char), inst, category),
            .string, .chunk => return g.equal(expected, try g.primitive(g.env.types.well_known.string), inst, category),
            .unit => return g.equal(expected, try g.fresh(.{ .structure = .unit }), inst, category),

            .interp => {
                var parts: std.ArrayList(Constraint) = .empty;
                defer parts.deinit(g.env.scratch);
                try parts.append(g.env.scratch, try g.equal(expected, try g.primitive(g.env.types.well_known.string), inst, category));
                for (bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)) |part| {
                    if (bir.instTag(part) == .chunk) continue;
                    const t = try g.freshFlex();
                    try parts.append(g.env.scratch, try g.expr(part, t, .{ .tag = .interp_part }));
                    try parts.append(g.env.scratch, try g.add(.interpolatable, part, @intFromEnum(t), 0, .{ .tag = .interp_part }));
                }
                return g.conj(parts.items);
            },

            .local, .top, .ctor, .ext_value, .ext_ctor => {
                // `b` is the instruction the evidence arguments of this
                // instantiation belong to (static-dispatch-spike.md §7.2):
                // the enclosing CALL when this reference is its callee —
                // which is where `Lower.callExpr` prepends them — and the
                // reference itself for a bare mention, whose lowering is the
                // eta-expansion of §8.2.
                const owner: Bir.Inst.OptionalIndex = if (g.site_owner == .none)
                    inst.toOptional()
                else
                    g.site_owner;
                return g.add(.instantiate, inst, @intFromEnum(expected), @intFromEnum(owner), category);
            },

            .tuple => {
                const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
                const vars = try g.env.scratch.alloc(Var, elements.len);
                defer g.env.scratch.free(vars);
                for (vars) |*v| v.* = try g.freshFlex();
                const range = try g.env.store.addVars(vars);
                var parts: std.ArrayList(Constraint) = .empty;
                defer parts.deinit(g.env.scratch);
                try parts.append(g.env.scratch, try g.equal(expected, try g.fresh(.{ .structure = .{ .tuple = range } }), inst, category));
                for (elements, vars, 0..) |el, v, i| {
                    try parts.append(g.env.scratch, try g.expr(el, v, .{ .tag = .tuple_element, .index = @intCast(i + 1) }));
                }
                return g.conj(parts.items);
            },

            .list => {
                const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
                const element = try g.freshFlex();
                var parts: std.ArrayList(Constraint) = .empty;
                defer parts.deinit(g.env.scratch);
                try parts.append(g.env.scratch, try g.equal(expected, try g.applied(g.env.types.well_known.list, &.{element}), inst, category));
                for (elements, 0..) |el, i| {
                    try parts.append(g.env.scratch, try g.expr(el, element, .{ .tag = .list_entry, .index = @intCast(i + 1) }));
                }
                return g.conj(parts.items);
            },

            .record => {
                const written = bir.extraSlice(Bir.inlineRange(data), Bir.Field);
                const pairs = try g.env.scratch.alloc(TypeStore.Field, written.len);
                defer g.env.scratch.free(pairs);
                for (written, pairs) |f, *p| p.* = .{ .name = bir.symbol(f.name), .value = try g.freshFlex() };
                const range = try g.env.store.addFields(pairs);
                // A record literal is CLOSED: its extension is the empty
                // record, so a field nobody declared is `unknown_field`.
                const closed = try g.fresh(.{ .structure = .empty_record });
                const record_var = try g.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = closed } } });
                var parts: std.ArrayList(Constraint) = .empty;
                defer parts.deinit(g.env.scratch);
                try parts.append(g.env.scratch, try g.equal(expected, record_var, inst, category));
                for (written) |f| {
                    const name = bir.symbol(f.name);
                    const v = findSortedField(g.env.store, range, name) orelse try g.freshFlex();
                    try parts.append(g.env.scratch, try g.expr(f.value, v, .{ .tag = .record_field, .index = @intFromEnum(name) }));
                }
                return g.conj(parts.items);
            },

            .record_update => {
                const written = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Field);
                const base = try g.freshFlex();
                const pairs = try g.env.scratch.alloc(TypeStore.Field, written.len);
                defer g.env.scratch.free(pairs);
                for (written, pairs) |f, *p| p.* = .{ .name = bir.symbol(f.name), .value = try g.freshFlex() };
                const range = try g.env.store.addFields(pairs);
                const ext = try g.freshFlex();
                const required = try g.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } });
                var parts: std.ArrayList(Constraint) = .empty;
                defer parts.deinit(g.env.scratch);
                try parts.append(g.env.scratch, try g.expr(@enumFromInt(data.lhs), base, .{ .tag = .general }));
                // The base must HAVE every updated field; the result is the
                // base's own type, so an update never widens a record.
                try parts.append(g.env.scratch, try g.equal(required, base, inst, .{ .tag = .record_update, .index = Category.no_field }));
                try parts.append(g.env.scratch, try g.equal(expected, base, inst, category));
                for (written) |f| {
                    const name = bir.symbol(f.name);
                    const v = findSortedField(g.env.store, range, name) orelse try g.freshFlex();
                    try parts.append(g.env.scratch, try g.expr(f.value, v, .{ .tag = .record_update, .index = @intFromEnum(name) }));
                }
                return g.conj(parts.items);
            },

            .field_access => {
                const name = bir.symbol(@enumFromInt(data.rhs));
                var pairs = [_]TypeStore.Field{.{ .name = name, .value = expected }};
                const range = try g.env.store.addFields(&pairs);
                const ext = try g.freshFlex();
                // `{ ext | field : t }`: an OPEN record, so any record with
                // the field will do (checker.md §6.1's row rules).
                const required = try g.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } });
                const target = try g.freshFlex();
                return g.conj(&.{
                    try g.expr(@enumFromInt(data.lhs), target, .{ .tag = .general }),
                    try g.equal(required, target, inst, .{ .tag = .field_access, .index = @intFromEnum(name) }),
                });
            },

            .tuple_index => {
                const target = try g.freshFlex();
                const payload = try g.addExtra(TupleIndex{ .index = data.rhs, .result = expected });
                return g.conj(&.{
                    try g.expr(@enumFromInt(data.lhs), target, .{ .tag = .general }),
                    try g.add(.tuple_index, inst, @intFromEnum(target), payload, category),
                });
            },

            .call => return g.call(inst, data, expected, category),
            .method_call => return g.methodCall(inst, data, expected, category),
            .type_dispatch => return g.typeDispatch(inst, data, expected, category),
            .lambda => return g.lambda(inst, data, expected, category),
            .let => return g.letExpr(inst, data, expected, category),
            .case => return g.caseExpr(inst, data, expected, category),

            .@"try" => {
                const scrutinee = try g.freshFlex();
                const enclosing = try g.enclosingResult(data.rhs);
                const payload = try g.addExtra(Try{ .enclosing = enclosing, .value = expected });
                return g.conj(&.{
                    try g.expr(@enumFromInt(data.lhs), scrutinee, .{ .tag = .general }),
                    try g.add(.try_, inst, @intFromEnum(scrutinee), payload, category),
                });
            },

            // A name that did not resolve or a parser placeholder: it has a
            // diagnostic already, so poison and stay quiet.
            else => return g.equal(expected, try g.fresh(.err), inst, category),
        }
    }

    /// The result variable a `?` returns from: the `let_def` named by the
    /// instruction's `rhs`, or the declaration itself.
    fn enclosingResult(g: *Generator, target: u32) Error!Var {
        const opt: Bir.Inst.OptionalIndex = @enumFromInt(target);
        if (opt.unwrap()) |t| {
            const i = t.int();
            if (i >= g.env.inst_base and i - g.env.inst_base < g.env.inst_result.len) {
                if (g.env.inst_result[i - g.env.inst_base].unwrap()) |v| return v;
            }
        }
        // Lowering guarantees a target (language.md §6.6 refuses a `?` with
        // no enclosing definition), so this is the poisoned-input path.
        if (g.env.decl_result.unwrap()) |v| return v;
        return g.fresh(.err);
    }

    /// `x.m a b` (static-dispatch-spike.md §1.1) and the six comparison
    /// operators (§3.1), as one node.
    ///
    /// The ORDER inside the `and_` is Rule U0 (§6.2, A.34) and is the whole
    /// of it: the receiver's own constraints, then the `method` node, then
    /// the arguments. `Solve` walks an `and_` left to right, so by the time
    /// an argument is checked the method has been resolved against a
    /// concrete receiver and the argument's variable is already the
    /// parameter type the method declares — which is what seeds a lambda
    /// argument's parameters before its body is checked.
    fn methodCall(g: *Generator, inst: Bir.Inst.Index, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
        const bir = g.env.bir;
        const m = bir.extraData(@enumFromInt(data.rhs), Bir.MethodCall);
        const args = bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Bir.Inst.Index);
        const receiver: Bir.Inst.Index = @enumFromInt(data.lhs);
        if (m.origin != .none) return g.wellKnownCall(inst, receiver, args, m.origin, expected, category);

        const name = bir.symbol(m.name);
        const recv = try g.freshFlex();
        const arg_vars = try g.env.scratch.alloc(Var, args.len);
        defer g.env.scratch.free(arg_vars);
        for (arg_vars) |*v| v.* = try g.freshFlex();

        // The method's type at this use: the receiver FIRST, because
        // `x.m a b` means `M.m x a b` (§1.2). Nothing constrains its shape
        // beyond that (A.2).
        const params = try g.env.scratch.alloc(Var, args.len + 1);
        defer g.env.scratch.free(params);
        params[0] = recv;
        @memcpy(params[1..], arg_vars);
        const fn_var = try g.funcVar(params, expected);
        const payload = try g.addExtra(Method{
            .name = name,
            .origin = @intFromEnum(m.origin),
            .fn_var = fn_var,
            .kind = 0,
            .var_name = @intFromEnum(Symbol.Optional.none),
        });

        var parts: std.ArrayList(Constraint) = .empty;
        defer parts.deinit(g.env.scratch);
        try parts.append(g.env.scratch, try g.expr(receiver, recv, .{ .tag = .general }));
        try parts.append(g.env.scratch, try g.add(.method, inst, @intFromEnum(recv), payload, category));
        for (args, arg_vars, 0..) |arg, v, i| {
            try parts.append(g.env.scratch, try g.expr(arg, v, .{
                .tag = .call_arg,
                .index = @intCast(i + 1),
                .owner = inst.toOptional(),
            }));
        }
        return g.conj(parts.items);
    }

    /// `a.decode s` (§4): a dispatch on a TYPE, with no receiver value.
    ///
    /// The variable is looked up among the declaration's rigid annotation
    /// variables. When it is not one — the annotation was poisoned, or the
    /// declaration lost its annotation — the expression is poisoned and the
    /// solver's `method` arm reports; lowering has already refused every
    /// case where `v` is not a type variable at all (§4.1).
    fn typeDispatch(g: *Generator, inst: Bir.Inst.Index, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
        const bir = g.env.bir;
        const t = bir.extraData(@enumFromInt(data.rhs), Bir.TypeDispatch);
        const args = bir.extraSlice(.{ .start = t.args_start, .end = t.args_end }, Bir.Inst.Index);
        const name = bir.symbol(t.name);
        const var_symbol = bir.symbols[data.lhs];
        const rigid = g.rigidNamed(var_symbol) orelse try g.fresh(.err);

        const arg_vars = try g.env.scratch.alloc(Var, args.len);
        defer g.env.scratch.free(arg_vars);
        for (arg_vars) |*v| v.* = try g.freshFlex();
        // No receiver: the constraint's type is `arg₁, …, argₙ -> result`
        // (§4.2), which is exactly why A.2 imposes no shape on it.
        const fn_var = try g.funcVar(arg_vars, expected);
        const payload = try g.addExtra(Method{
            .name = name,
            .origin = @intFromEnum(Bir.WellKnown.none),
            .fn_var = fn_var,
            .kind = 1,
            .var_name = @intFromEnum(var_symbol.toOptional()),
        });

        var parts: std.ArrayList(Constraint) = .empty;
        defer parts.deinit(g.env.scratch);
        try parts.append(g.env.scratch, try g.add(.method, inst, @intFromEnum(rigid), payload, category));
        for (args, arg_vars, 0..) |arg, v, i| {
            try parts.append(g.env.scratch, try g.expr(arg, v, .{
                .tag = .call_arg,
                .index = @intCast(i + 1),
                .owner = inst.toOptional(),
            }));
        }
        return g.conj(parts.items);
    }

    /// The rigid variable the declaration's annotation introduced for
    /// `name`, or null.
    fn rigidNamed(g: *const Generator, name: Symbol) ?Var {
        for (g.env.decl_rigids) |scoped| {
            if (scoped.name == name) return scoped.v;
        }
        return null;
    }

    /// `p1, …, pn -> result`, one n-ary function type at the current rank.
    fn funcVar(g: *Generator, params: []const Var, result: Var) Error!Var {
        const range = try g.env.store.addVars(params);
        return g.fresh(.{ .structure = .{ .func = .{ .params = range, .result = result } } });
    }

    /// `a == b` and the four orderings (§3.1).
    ///
    /// **The operator form pins both operands to one type and the result to
    /// `Bool`**, which is deliberately tighter than the constraint a
    /// hand-written `a.eq b` raises (A.33): `t` is ONE variable in the
    /// receiver, the argument and the constraint, so `same a b = a == b` is
    /// `a, a -> Bool where a.eq : a, a -> Bool` and not three quantifiers.
    /// M3 measures interface churn, so a looser lowering here would have
    /// made the spike measure churn caused by its own rule.
    fn wellKnownCall(
        g: *Generator,
        inst: Bir.Inst.Index,
        receiver: Bir.Inst.Index,
        args: []const Bir.Inst.Index,
        origin: Bir.WellKnown,
        expected: Var,
        category: Category,
    ) Error!Constraint {
        const operand = try g.freshFlex();
        const wk = g.env.types.well_known;
        // `eq` answers `Bool`, `compare` answers `Order`; the INSTRUCTION
        // is `Bool` either way, and the backend supplies the test (§3.1,
        // A.3).
        const method_result = switch (origin) {
            .none, .eq, .neq => try g.primitive(wk.bool),
            else => try g.primitive(wk.order),
        };
        const fn_var = try g.funcVar(&.{ operand, operand }, method_result);
        const name = (origin.method() orelse InternPool.WellKnown.eq).symbol();
        const payload = try g.addExtra(Method{
            .name = name,
            .origin = @intFromEnum(origin),
            .fn_var = fn_var,
            .kind = 0,
            .var_name = @intFromEnum(Symbol.Optional.none),
        });

        var parts: std.ArrayList(Constraint) = .empty;
        defer parts.deinit(g.env.scratch);
        try parts.append(g.env.scratch, try g.equal(expected, try g.primitive(wk.bool), inst, category));
        try parts.append(g.env.scratch, try g.expr(receiver, operand, .{
            .tag = .call_arg,
            .index = 1,
            .owner = inst.toOptional(),
        }));
        try parts.append(g.env.scratch, try g.add(.method, inst, @intFromEnum(operand), payload, category));
        for (args, 0..) |arg, i| {
            try parts.append(g.env.scratch, try g.expr(arg, operand, .{
                .tag = .call_arg,
                .index = @intCast(i + 2),
                .owner = inst.toOptional(),
            }));
        }
        return g.conj(parts.items);
    }

    fn call(g: *Generator, inst: Bir.Inst.Index, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
        const bir = g.env.bir;
        const args = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);

        // **S3 SHIM**: a SATURATED operator section — `(==) a b` — is the
        // operator applied to those two arguments, which is what it used to
        // lower to. Reading it as a call of the lambda instead would report
        // every mistake against the lambda's synthesised locals, all of
        // which are stamped with the operator's own token: `(==) inc inc`
        // underlined `(==)` where it should underline `inc`. An unsaturated
        // one keeps the lambda, so its arity mistake still says "The (==)
        // operator expects 2 arguments".
        if (args.len == 2) {
            if (bir.operatorSection(@enumFromInt(data.lhs), g.env.locals_base)) |origin| {
                return g.wellKnownCall(inst, args[0], args[1..], origin, expected, category);
            }
        }

        const callee = try g.freshFlex();
        const arg_vars = try g.env.scratch.alloc(Var, args.len);
        defer g.env.scratch.free(arg_vars);
        for (arg_vars) |*v| v.* = try g.freshFlex();

        const args_start: u32 = @intCast(g.tree.extra.items.len);
        try g.tree.extra.appendSlice(g.gpa, @ptrCast(arg_vars));
        const payload = try g.addExtra(Call{
            .callee = callee,
            .args_start = args_start,
            .args_len = @intCast(args.len),
            .result = expected,
            .flavor = .call,
        });

        var parts: std.ArrayList(Constraint) = .empty;
        defer parts.deinit(g.env.scratch);
        // The callee first, so the solver knows its arrows; then the call
        // itself, so §8.3's rule sees both the arrows and what the result
        // was wanted for; then the arguments, so an argument mismatch is
        // reported against a callee that is already concrete.
        {
            const outer = g.site_owner;
            defer g.site_owner = outer;
            g.site_owner = inst.toOptional();
            try parts.append(g.env.scratch, try g.expr(@enumFromInt(data.lhs), callee, .{ .tag = .general }));
        }
        try parts.append(g.env.scratch, try g.add(.call, inst, payload, 0, category));
        for (args, arg_vars, 0..) |arg, v, i| {
            try parts.append(g.env.scratch, try g.expr(arg, v, .{
                .tag = .call_arg,
                .index = @intCast(i + 1),
                .owner = inst.toOptional(),
            }));
        }
        return g.conj(parts.items);
    }

    fn lambda(g: *Generator, inst: Bir.Inst.Index, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
        const bir = g.env.bir;
        const params = bir.extraSlice(bir.subRange(@enumFromInt(data.lhs)), Bir.Inst.Index);
        const param_vars = try g.env.scratch.alloc(Var, params.len);
        defer g.env.scratch.free(param_vars);
        for (param_vars) |*v| v.* = try g.freshFlex();
        var result = try g.freshFlex();

        // **S3 SHIM**: `(==)` is a lambda over a method call (§3.1, A.22),
        // and its type is known EXACTLY — `a, a -> Bool`, or
        // `number, number -> Bool`. Pinning it here, before the body is
        // descended into, is what makes `List.foldl [ 1 ] 0 (<)` say "this
        // argument is `Int, Int -> Bool` but `foldl` needs
        // `Int, Int -> Int`": with fresh variables the parameter type won
        // the unification first and the mistake surfaced inside the body,
        // as "this is `Bool` but I need `b`".
        if (bir.operatorSection(inst, g.env.locals_base)) |_| {
            const operand = try g.freshFlex();
            for (param_vars) |*v| v.* = operand;
            result = try g.primitive(g.env.types.well_known.bool);
        }

        var parts: std.ArrayList(Constraint) = .empty;
        defer parts.deinit(g.env.scratch);
        try parts.append(g.env.scratch, try g.equal(expected, try g.func(param_vars, result), inst, category));
        for (params, param_vars) |p, v| {
            try parts.append(g.env.scratch, try g.pattern(p, v));
        }
        try parts.append(g.env.scratch, try g.expr(@enumFromInt(data.rhs), result, .{ .tag = .general }));
        return g.conj(parts.items);
    }

    fn caseExpr(g: *Generator, inst: Bir.Inst.Index, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
        _ = inst;
        const bir = g.env.bir;
        const branches = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
        const scrutinee = try g.freshFlex();
        var parts: std.ArrayList(Constraint) = .empty;
        defer parts.deinit(g.env.scratch);
        try parts.append(g.env.scratch, try g.expr(@enumFromInt(data.lhs), scrutinee, .{ .tag = .general }));
        for (branches, 0..) |b, i| {
            const bd = bir.instData(b);
            try parts.append(g.env.scratch, try g.patternAgainst(@enumFromInt(bd.lhs), scrutinee));
            // The FIRST branch is measured against whatever the context
            // wanted — "the body of this definition", "the 2nd argument to
            // `f`" — and every later one against the branches before it.
            // That is Elm's split, and it is what makes the message say
            // which branch disagrees rather than blaming the `case`.
            try parts.append(g.env.scratch, try g.expr(@enumFromInt(bd.rhs), expected, if (i == 0) category else .{
                .tag = .case_branch,
                .index = @intCast(i + 1),
            }));
        }
        return g.conj(parts.items);
    }

    // ---- `let` -----------------------------------------------------------

    fn letExpr(g: *Generator, inst: Bir.Inst.Index, data: Bir.Inst.Data, expected: Var, category: Category) Error!Constraint {
        _ = inst;
        const bir = g.env.bir;
        const defs = bir.extraSlice(bir.subRange(@enumFromInt(data.lhs)), Bir.Inst.Index);
        const groups = try sccOfLet(g.env, defs);
        defer g.env.scratch.free(groups.order);
        defer g.env.scratch.free(groups.starts);

        // Nest the groups outermost-first so a later group sees the earlier
        // ones generalised, and put the `let` body inside the innermost.
        var body = try g.expr(@enumFromInt(data.rhs), expected, category);
        var i = groups.starts.len - 1;
        while (i > 0) {
            i -= 1;
            const members = groups.order[groups.starts[i]..groups.starts[i + 1]];
            body = try g.bindingGroup(members, body);
        }
        return body;
    }

    /// One `let` node for `members`, with `body` inside it.
    fn bindingGroup(g: *Generator, members: []const Bir.Inst.Index, body: Constraint) Error!Constraint {
        const outer_rank = g.rank;
        const outer_pool = g.pool;
        g.rank = outer_rank + 1;
        g.pool = .empty;
        defer {
            g.pool.deinit(g.gpa);
            g.pool = outer_pool;
            g.rank = outer_rank;
        }

        var header: std.ArrayList(Header) = .empty;
        defer header.deinit(g.env.scratch);
        var parts: std.ArrayList(Constraint) = .empty;
        defer parts.deinit(g.env.scratch);

        // Every binding's variable exists before any body is generated, so
        // a mutually recursive group can refer to itself monomorphically.
        // `declareBinding` hands back what the BODY is checked against,
        // which differs from what uses see exactly when the binding is
        // annotated: uses get the annotation's generalised form, the body
        // is held to its rigid one.
        const check_vars = try g.env.scratch.alloc(Var, members.len);
        defer g.env.scratch.free(check_vars);
        for (members, check_vars) |m, *cv| cv.* = try g.declareBinding(m, &header);
        for (members, check_vars) |m, cv| try parts.append(g.env.scratch, try g.defineBinding(m, cv));

        const header_con = try g.conj(parts.items);
        const vars_start: u32 = @intCast(g.tree.extra.items.len);
        try g.tree.extra.appendSlice(g.gpa, @ptrCast(g.pool.items));
        const vars_len: u32 = @intCast(g.pool.items.len);
        const header_start: u32 = @intCast(g.tree.extra.items.len);
        try g.tree.extra.appendSlice(g.gpa, @ptrCast(header.items));
        const payload = try g.addExtra(Let{
            .rank = outer_rank + 1,
            .vars_start = vars_start,
            .vars_len = vars_len,
            .header_start = header_start,
            .header_len = @intCast(header.items.len),
            .header_con = header_con,
            .body_con = body,
        });
        // `add` must run with the OUTER rank restored, which the defer
        // above does only when this function returns — so the node is made
        // here and the rank it records is the one in the payload.
        return g.add(.let_, members[0], payload, 0, .{});
    }

    /// Give a binding its type variable, before any body is generated, and
    /// return the variable its BODY is checked against.
    fn declareBinding(g: *Generator, m: Bir.Inst.Index, header: *std.ArrayList(Header)) Error!Var {
        const bir = g.env.bir;
        const data = bir.instData(m);
        switch (bir.instTag(m)) {
            .let_def => {
                const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
                if (def.annotation.unwrap()) |a| {
                    // An annotated binding is checked against RIGID
                    // variables — an annotation is a promise about ALL
                    // types — and seen by everything else as the annotation
                    // already generalised, which is what breaks recursion
                    // through it.
                    var scheme_builder = g.env.builder(.flex, TypeStore.generalized);
                    defer scheme_builder.deinit();
                    const scheme = try g.env.readAnnotation(&scheme_builder, a);
                    var check_builder = g.env.builder(.rigid, g.rank);
                    defer check_builder.deinit();
                    const check = try g.env.readAnnotation(&check_builder, a);
                    try g.pool.append(g.gpa, check);
                    g.env.local_var[def.local] = scheme.toOptional();
                    try header.append(g.env.scratch, .{ .v = check, .region = m, .name = nameOfLocal(g.env, def.local) });
                    return check;
                }
                const v = try g.freshFlex();
                g.env.local_var[def.local] = v.toOptional();
                try header.append(g.env.scratch, .{
                    .v = v,
                    .region = m,
                    .name = nameOfLocal(g.env, def.local),
                });
                return v;
            },
            .let_pattern => {
                const v = try g.freshFlex();
                try header.append(g.env.scratch, .{ .v = v, .region = m, .name = .none });
                return v;
            },
            else => return g.freshFlex(),
        }
    }

    fn defineBinding(g: *Generator, m: Bir.Inst.Index, check: Var) Error!Constraint {
        const bir = g.env.bir;
        const data = bir.instData(m);
        switch (bir.instTag(m)) {
            .let_def => {
                const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
                const binding = check;
                const params = bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Bir.Inst.Index);
                if (params.len == 0) {
                    g.setInstResult(m, binding);
                    return g.expr(@enumFromInt(data.rhs), binding, .{
                        .tag = if (def.annotation == .none) .general else .let_annotation,
                    });
                }
                const param_vars = try g.env.scratch.alloc(Var, params.len);
                defer g.env.scratch.free(param_vars);
                for (param_vars) |*v| v.* = try g.freshFlex();
                const result = try g.freshFlex();
                g.setInstResult(m, result);
                var parts: std.ArrayList(Constraint) = .empty;
                defer parts.deinit(g.env.scratch);
                try parts.append(g.env.scratch, try g.equal(binding, try g.func(param_vars, result), m, .{
                    .tag = if (def.annotation == .none) .general else .let_annotation,
                }));
                for (params, param_vars) |p, v| try parts.append(g.env.scratch, try g.pattern(p, v));
                try parts.append(g.env.scratch, try g.expr(@enumFromInt(data.rhs), result, .{
                    .tag = if (def.annotation == .none) .general else .let_annotation,
                }));
                return g.conj(parts.items);
            },
            .let_pattern => {
                return g.conj(&.{
                    try g.patternAgainst(@enumFromInt(data.lhs), check),
                    try g.expr(@enumFromInt(data.rhs), check, .{ .tag = .destructure }),
                });
            },
            else => return g.true_(),
        }
    }

    fn setInstResult(g: *Generator, inst: Bir.Inst.Index, v: Var) void {
        const i = inst.int();
        if (i < g.env.inst_base) return;
        const offset = i - g.env.inst_base;
        if (offset >= g.env.inst_result.len) return;
        g.env.inst_result[offset] = v.toOptional();
    }

    // ---- Patterns --------------------------------------------------------

    /// Bind a parameter pattern to `v`.
    pub fn pattern(g: *Generator, inst: Bir.Inst.Index, v: Var) Error!Constraint {
        return g.patternAgainst(inst, v);
    }

    fn patternAgainst(g: *Generator, inst: Bir.Inst.Index, expected: Var) Error!Constraint {
        g.depth += 1;
        defer g.depth -= 1;
        if (g.depth > max_depth) return g.true_();

        const bir = g.env.bir;
        const tag = bir.instTag(inst);
        const data = bir.instData(inst);
        switch (tag) {
            .pat_wild => return g.true_(),
            .pat_var => {
                g.env.local_var[data.lhs] = expected.toOptional();
                return g.true_();
            },
            .pat_as => {
                g.env.local_var[data.rhs] = expected.toOptional();
                return g.patternAgainst(@enumFromInt(data.lhs), expected);
            },
            .pat_int => return g.equal(expected, try g.freshKind(.number), inst, .{ .tag = .case_pattern }),
            .pat_char => return g.equal(expected, try g.primitive(g.env.types.well_known.char), inst, .{ .tag = .case_pattern }),
            .pat_string => return g.equal(expected, try g.primitive(g.env.types.well_known.string), inst, .{ .tag = .case_pattern }),
            .pat_unit => return g.equal(expected, try g.fresh(.{ .structure = .unit }), inst, .{ .tag = .case_pattern }),
            .pat_tuple => {
                const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
                const vars = try g.env.scratch.alloc(Var, elements.len);
                defer g.env.scratch.free(vars);
                for (vars) |*v| v.* = try g.freshFlex();
                const range = try g.env.store.addVars(vars);
                var parts: std.ArrayList(Constraint) = .empty;
                defer parts.deinit(g.env.scratch);
                try parts.append(g.env.scratch, try g.equal(expected, try g.fresh(.{ .structure = .{ .tuple = range } }), inst, .{ .tag = .case_pattern }));
                for (elements, vars) |el, v| try parts.append(g.env.scratch, try g.patternAgainst(el, v));
                return g.conj(parts.items);
            },
            .pat_list => {
                const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
                const element = try g.freshFlex();
                var parts: std.ArrayList(Constraint) = .empty;
                defer parts.deinit(g.env.scratch);
                try parts.append(g.env.scratch, try g.equal(expected, try g.applied(g.env.types.well_known.list, &.{element}), inst, .{ .tag = .case_pattern }));
                for (elements) |el| try parts.append(g.env.scratch, try g.patternAgainst(el, element));
                return g.conj(parts.items);
            },
            .pat_cons => {
                const element = try g.freshFlex();
                const list = try g.applied(g.env.types.well_known.list, &.{element});
                return g.conj(&.{
                    try g.equal(expected, list, inst, .{ .tag = .case_pattern }),
                    try g.patternAgainst(@enumFromInt(data.lhs), element),
                    try g.patternAgainst(@enumFromInt(data.rhs), list),
                });
            },
            .pat_record => {
                const locals = bir.extraSlice(Bir.inlineRange(data), u32);
                const pairs = try g.env.scratch.alloc(TypeStore.Field, locals.len);
                defer g.env.scratch.free(pairs);
                for (locals, pairs) |li, *p| {
                    const v = try g.freshFlex();
                    g.env.local_var[li] = v.toOptional();
                    p.* = .{ .name = nameOfLocal(g.env, li).unwrap() orelse @enumFromInt(0), .value = v };
                }
                const range = try g.env.store.addFields(pairs);
                const ext = try g.freshFlex();
                const required = try g.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } });
                return g.equal(required, expected, inst, .{ .tag = .case_pattern });
            },
            .pat_ctor => {
                const args = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
                const ctor = try g.freshFlex();
                const arg_vars = try g.env.scratch.alloc(Var, args.len);
                defer g.env.scratch.free(arg_vars);
                for (arg_vars) |*v| v.* = try g.freshFlex();
                const args_start: u32 = @intCast(g.tree.extra.items.len);
                try g.tree.extra.appendSlice(g.gpa, @ptrCast(arg_vars));
                const payload = try g.addExtra(Call{
                    .callee = ctor,
                    .args_start = args_start,
                    .args_len = @intCast(args.len),
                    .result = expected,
                    .flavor = .ctor_pattern,
                });
                var parts: std.ArrayList(Constraint) = .empty;
                defer parts.deinit(g.env.scratch);
                const reference: Bir.Inst.Index = @enumFromInt(data.lhs);
                if (bir.instTag(reference) == .@"error") {
                    try parts.append(g.env.scratch, try g.equal(ctor, try g.fresh(.err), inst, .{}));
                } else {
                    try parts.append(g.env.scratch, try g.add(.instantiate, reference, @intFromEnum(ctor), 0, .{}));
                }
                try parts.append(g.env.scratch, try g.add(.call, inst, payload, 0, .{ .tag = .case_pattern }));
                for (args, arg_vars) |arg, v| try parts.append(g.env.scratch, try g.patternAgainst(arg, v));
                return g.conj(parts.items);
            },
            else => return g.equal(expected, try g.fresh(.err), inst, .{}),
        }
    }

    // ---- A whole declaration --------------------------------------------

    /// The body of a value declaration, checked against `target` — its
    /// annotation's rigid form, or the group's fresh variable.
    pub fn decl(g: *Generator, index: Bir.DeclIndex, target: Var) Error!Constraint {
        const bir = g.env.bir;
        const d = bir.decl(index);
        const body = d.body.unwrap() orelse return g.true_();
        const params = bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index);
        const annotated = d.annotation != .none;
        if (params.len == 0) {
            g.env.decl_result = target.toOptional();
            return g.expr(body, target, .{ .tag = if (annotated) .annotation else .general });
        }
        const param_vars = try g.env.scratch.alloc(Var, params.len);
        defer g.env.scratch.free(param_vars);
        for (param_vars) |*v| v.* = try g.freshFlex();
        const result = try g.freshFlex();
        g.env.decl_result = result.toOptional();
        var parts: std.ArrayList(Constraint) = .empty;
        defer parts.deinit(g.env.scratch);
        try parts.append(g.env.scratch, try g.equal(target, try g.func(param_vars, result), body, .{
            .tag = if (annotated) .annotation else .general,
        }));
        for (params, param_vars) |p, v| try parts.append(g.env.scratch, try g.pattern(p, v));
        try parts.append(g.env.scratch, try g.expr(body, result, .{ .tag = if (annotated) .annotation else .general }));
        return g.conj(parts.items);
    }

    /// Everything the generator allocated at the current rank, for the
    /// caller's `let`.
    pub fn poolItems(g: *const Generator) []const Var {
        return g.pool.items;
    }

    /// A fresh variable for a top-level binding, in the current pool.
    pub fn freshForDecl(g: *Generator) Error!Var {
        return g.freshFlex();
    }

    /// Claim every variable the store gained since `mark` that sits at the
    /// current rank. `Types.Builder` makes variables without going through
    /// `fresh`, and the store's descriptor column is append-only, so "what
    /// is new" is a range and needs no bookkeeping of its own.
    pub fn adoptSince(g: *Generator, mark: u32) Error!void {
        var i = mark;
        while (i < g.env.store.count()) : (i += 1) {
            const v: Var = @enumFromInt(i);
            if (g.env.store.rank(v) == g.rank) try g.pool.append(g.gpa, v);
        }
    }

    /// The conjunction of a top-level group's per-declaration constraints.
    pub fn finishGroup(g: *Generator, parts: []const Constraint) Error!Constraint {
        return g.conj(parts);
    }

    /// Where the store stands, for `adoptSince`.
    pub fn storeMark(g: *const Generator) u32 {
        return g.env.store.count();
    }
};

/// A local's name. `index` is RELATIVE to the declaration being checked,
/// which is how every local index in the Bir is spelled (`Lower` asserts it,
/// `Bir.declLocals` slices with it), so the module-wide table has to be
/// offset by the declaration's `locals_start` before it is indexed.
fn nameOfLocal(env: *const Env, index: u32) Symbol.Optional {
    const bir = env.bir;
    const at = env.locals_base + index;
    if (index >= env.local_var.len or at >= bir.locals.len) return .none;
    const l = bir.locals[at];
    if (l.name.unwrap()) |s| return bir.symbols[s].toOptional();
    return .none;
}

// ---------------------------------------------------------------------------
// SCC over a `let`'s bindings
// ---------------------------------------------------------------------------

/// The variable `addFields` gave `name`, by binary search.
///
/// `addFields` sorts its input by symbol id, so the range is sorted and a
/// scan is not needed. The scan this replaced ran once per written field
/// over the whole range: O(fields²) per record literal, which on 200
/// functions each building an `n`-field record was roughly 128 ms of the
/// 179 ms `constrain` took at n = 800.
fn findSortedField(store: *const TypeStore, range: TypeStore.Range, name: Symbol) ?Var {
    const fields = store.fields(range);
    var lo: usize = 0;
    var hi: usize = fields.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = @intFromEnum(fields[mid].name);
        const want = @intFromEnum(name);
        if (at < want) lo = mid + 1 else if (at > want) hi = mid else return fields[mid].value;
    }
    return null;
}

/// `sccGroups`'s answer over plain indices: `order[starts[i]..starts[i + 1]]`
/// is group `i`, and the groups are in dependency order.
pub const IndexGroups = struct {
    order: []u32,
    starts: []u32,
};

/// The bindings of one `let`, grouped into minimal mutually recursive sets
/// and ordered dependencies-first (design §7 #5).
pub const Groups = struct {
    /// The bindings, group by group.
    order: []Bir.Inst.Index,
    /// `order[starts[i]..starts[i + 1]]` is group `i`; `starts.len` is
    /// `groups + 1`.
    starts: []u32,
};

/// Minimal mutually recursive groups over an arbitrary index graph,
/// dependencies first. `edges[edge_start[i]..edge_start[i + 1]]` are `i`'s
/// targets. Shared by the `let` decomposition here and the top-level one in
/// `Check`, which are the same problem over different edges.
pub fn sccGroups(scratch: Allocator, n: usize, edges: []const u32, edge_start: []const u32) Error!IndexGroups {
    var t: LetTarjan = try .init(scratch, n, edges, edge_start);
    defer t.deinit(scratch);
    try t.run(scratch);
    // Tarjan closes a component only once everything it points AT is done,
    // and the edges here point dependent → dependency — so component 0 is
    // the deepest dependency and ASCENDING id order is dependencies first.
    // Both callers need that: `Check.run` checks group 0 first, and
    // `letExpr` makes group 0 the outermost `let`, which is the one
    // generalised first. Emitting them the other way round left every
    // unannotated callee's scheme unset at the point its caller was
    // checked, so the call was silently poisoned instead of checked.
    //
    // Grouped by a COUNTING SORT rather than a scan per component. The
    // normal shape of real code is mostly independent top-level
    // declarations, so components ≈ n and "for each component, scan every
    // member" was quadratic in the module's declaration count: 8 000
    // declarations took 44 ms, 16 000 took 139 ms and 32 000 took 506 ms,
    // while the same 32 000 in ONE component took 73 ms.
    const order = try scratch.alloc(u32, n);
    const starts = try scratch.alloc(u32, t.component_count + 1);
    @memset(starts, 0);
    for (t.component) |c| starts[c + 1] += 1;
    for (1..t.component_count + 1) |c| starts[c] += starts[c - 1];
    const cursor = try scratch.alloc(u32, t.component_count);
    defer scratch.free(cursor);
    @memcpy(cursor, starts[0..t.component_count]);
    for (t.component, 0..) |c, i| {
        order[cursor[c]] = @intCast(i);
        cursor[c] += 1;
    }
    return .{ .order = order, .starts = starts };
}

/// Tarjan over the local references between a `let`'s bindings. An
/// ANNOTATED binding is never a target: its scheme is its annotation, so
/// recursion through it is already broken (checker.md §6.1).
pub fn sccOfLet(env: *Env, defs: []const Bir.Inst.Index) Error!Groups {
    const n = defs.len;
    const scratch = env.scratch;
    // `local_of[i]` is the local each binding introduces, or `none`.
    const local_of = try scratch.alloc(u32, n);
    defer scratch.free(local_of);
    const annotated = try scratch.alloc(bool, n);
    defer scratch.free(annotated);
    const none = std.math.maxInt(u32);
    for (defs, local_of, annotated) |d, *l, *a| {
        l.* = none;
        a.* = false;
        if (env.bir.instTag(d) != .let_def) continue;
        const def = env.bir.extraData(@enumFromInt(env.bir.instData(d).lhs), Bir.LetDef);
        l.* = def.local;
        a.* = def.annotation != .none;
    }

    var edges: std.ArrayList(u32) = .empty;
    defer edges.deinit(scratch);
    const edge_start = try scratch.alloc(u32, n + 1);
    defer scratch.free(edge_start);
    var referenced: std.ArrayList(u32) = .empty;
    defer referenced.deinit(scratch);
    for (defs, 0..) |d, i| {
        edge_start[i] = @intCast(edges.items.len);
        referenced.clearRetainingCapacity();
        try collectLocalRefs(env, env.bir.instData(d).rhs, &referenced);
        for (referenced.items) |local| {
            for (local_of, annotated, 0..) |l, a, j| {
                if (l != local or a or i == j) continue;
                if (std.mem.indexOfScalar(u32, edges.items[edge_start[i]..], @intCast(j)) != null) continue;
                try edges.append(scratch, @intCast(j));
            }
        }
    }
    edge_start[n] = @intCast(edges.items.len);

    const groups = try sccGroups(scratch, n, edges.items, edge_start);
    const order = try scratch.alloc(Bir.Inst.Index, n);
    for (groups.order, order) |i, *o| o.* = defs[i];
    scratch.free(groups.order);
    return .{ .order = order, .starts = groups.starts };
}

/// Every local a subtree references, deduplicated. Iterative: an expression
/// may be 4096 levels deep (language.md §10) and that does not belong on
/// the C stack.
fn collectLocalRefs(env: *Env, root: u32, out: *std.ArrayList(u32)) Error!void {
    const bir = env.bir;
    var stack: std.ArrayList(Bir.Inst.Index) = .empty;
    defer stack.deinit(env.scratch);
    try stack.append(env.scratch, @enumFromInt(root));
    while (stack.pop()) |inst| {
        if (bir.instTag(inst) == .local) {
            const index = bir.instData(inst).lhs;
            if (std.mem.indexOfScalar(u32, out.items, index) == null) try out.append(env.scratch, index);
            continue;
        }
        try pushChildren(env, inst, &stack);
    }
}

/// Push every operand instruction of `inst`. One place that knows the
/// operand layout of every tag, so a new Bir form is a compile error here
/// and not a silent miss.
fn pushChildren(env: *Env, inst: Bir.Inst.Index, stack: *std.ArrayList(Bir.Inst.Index)) Error!void {
    const bir = env.bir;
    const scratch = env.scratch;
    const data = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .interp, .tuple, .list, .pat_tuple, .pat_list, .type_tuple => {
            try stack.appendSlice(scratch, bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index));
        },
        .record, .type_record => {
            for (bir.extraSlice(Bir.inlineRange(data), Bir.Field)) |f| try stack.append(scratch, f.value);
        },
        .record_update, .type_record_ext => {
            try stack.append(scratch, @enumFromInt(data.lhs));
            for (bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Field)) |f| try stack.append(scratch, f.value);
        },
        .field_access, .tuple_index, .@"try" => try stack.append(scratch, @enumFromInt(data.lhs)),
        .method_call => {
            const m = bir.extraData(@enumFromInt(data.rhs), Bir.MethodCall);
            try stack.append(scratch, @enumFromInt(data.lhs));
            try stack.appendSlice(scratch, bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Bir.Inst.Index));
        },
        .type_dispatch => {
            const t = bir.extraData(@enumFromInt(data.rhs), Bir.TypeDispatch);
            try stack.appendSlice(scratch, bir.extraSlice(.{ .start = t.args_start, .end = t.args_end }, Bir.Inst.Index));
        },
        .call, .pat_ctor, .case, .type_app => {
            try stack.append(scratch, @enumFromInt(data.lhs));
            try stack.appendSlice(scratch, bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index));
        },
        .lambda, .let => {
            try stack.appendSlice(scratch, bir.extraSlice(bir.subRange(@enumFromInt(data.lhs)), Bir.Inst.Index));
            try stack.append(scratch, @enumFromInt(data.rhs));
        },
        .let_def => {
            const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
            try stack.appendSlice(scratch, bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Bir.Inst.Index));
            try stack.append(scratch, @enumFromInt(data.rhs));
        },
        .let_pattern, .branch, .pat_cons, .type_fn => {
            try stack.append(scratch, @enumFromInt(data.lhs));
            try stack.append(scratch, @enumFromInt(data.rhs));
        },
        .pat_as => try stack.append(scratch, @enumFromInt(data.lhs)),
        .local,
        .top,
        .ctor,
        .import_value,
        .import_ctor,
        .qualified,
        .qualified_ctor,
        .ext_value,
        .ext_ctor,
        .type_var,
        .type_top,
        .type_import,
        .type_qualified,
        .ext_type,
        .type_unit,
        .int,
        .float,
        .char,
        .string,
        .chunk,
        .unit,
        .pat_wild,
        .pat_var,
        .pat_int,
        .pat_char,
        .pat_string,
        .pat_unit,
        .pat_record,
        .@"error",
        => {},
    }
}

/// Tarjan over a `let`'s bindings; iterative for the same reason
/// `resolve/Graph.zig`'s is.
const LetTarjan = struct {
    index: []u32,
    low: []u32,
    on_stack: []bool,
    component: []u32,
    stack: std.ArrayList(u32) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    edges: []const u32,
    edge_start: []const u32,
    next_index: u32 = 0,
    component_count: u32 = 0,

    const unvisited = std.math.maxInt(u32);
    const Frame = struct { node: u32, cursor: u32 };

    fn init(scratch: Allocator, n: usize, edges: []const u32, edge_start: []const u32) Error!LetTarjan {
        const t: LetTarjan = .{
            .index = try scratch.alloc(u32, n),
            .low = try scratch.alloc(u32, n),
            .on_stack = try scratch.alloc(bool, n),
            .component = try scratch.alloc(u32, n),
            .edges = edges,
            .edge_start = edge_start,
        };
        @memset(t.index, unvisited);
        @memset(t.on_stack, false);
        @memset(t.component, 0);
        return t;
    }

    fn deinit(t: *LetTarjan, scratch: Allocator) void {
        scratch.free(t.index);
        scratch.free(t.low);
        scratch.free(t.on_stack);
        t.stack.deinit(scratch);
        t.frames.deinit(scratch);
    }

    fn run(t: *LetTarjan, scratch: Allocator) Error!void {
        for (0..t.index.len) |root| {
            if (t.index[root] != unvisited) continue;
            try t.frames.append(scratch, .{ .node = @intCast(root), .cursor = 0 });
            while (t.frames.items.len > 0) {
                const frame = &t.frames.items[t.frames.items.len - 1];
                const v = frame.node;
                if (frame.cursor == 0) {
                    t.index[v] = t.next_index;
                    t.low[v] = t.next_index;
                    t.next_index += 1;
                    try t.stack.append(scratch, v);
                    t.on_stack[v] = true;
                }
                const edges = t.edges[t.edge_start[v]..t.edge_start[v + 1]];
                if (frame.cursor < edges.len) {
                    const w = edges[frame.cursor];
                    frame.cursor += 1;
                    if (t.index[w] == unvisited) {
                        try t.frames.append(scratch, .{ .node = w, .cursor = 0 });
                    } else if (t.on_stack[w]) {
                        t.low[v] = @min(t.low[v], t.index[w]);
                    }
                    continue;
                }
                if (t.low[v] == t.index[v]) {
                    while (true) {
                        const w = t.stack.pop().?;
                        t.on_stack[w] = false;
                        t.component[w] = t.component_count;
                        if (w == v) break;
                    }
                    t.component_count += 1;
                }
                _ = t.frames.pop();
                if (t.frames.items.len > 0) {
                    const parent = t.frames.items[t.frames.items.len - 1].node;
                    t.low[parent] = @min(t.low[parent], t.low[v]);
                }
            }
        }
    }
};
