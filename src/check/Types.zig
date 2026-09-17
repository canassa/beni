//! The session-wide type table, and the one place a written type turns into
//! store variables (docs/design/checker.md §5, §6.1).
//!
//! **`TypeId` is dense.** Every `type`, `type alias` and `foreign type` of
//! every module gets an index into one table, filled in the graph's
//! topological order, so "are these the same type?" is one integer compare
//! and never a name lookup (checker.md §5). Two dense side tables map the
//! other way — `by_decl` from a module's `Bir.DeclIndex` and `by_interface`
//! from its `Interface.TypeIndex` — because both halves of the compiler
//! reach a type through a different index and neither may hash a name to
//! find it.
//!
//! **Equatability is computed here, once, for the whole session.** A
//! `foreign type` declares it (checker.md Appendix B); an `adt` or an
//! `alias` is equatable when nothing in its body is a function, and a type
//! PARAMETER is not consulted — `List a` is equatable exactly when `a` is,
//! and the argument is checked at the use site by the obligation walk of
//! §6.4. Recursive types (`type Tree a = Leaf | Node (Tree a) (Tree a)`)
//! make this a fixpoint, so it starts optimistic and shrinks: the property
//! is "contains no function", which only ever becomes false, so iterating
//! until nothing changes terminates and lands on the greatest fixpoint —
//! the answer that lets a recursive type be equatable at all.
//!
//! **`Builder` is the annotation reader.** A written type — an annotation, a
//! constructor's argument, an alias body — is a tree of `Bir` type
//! instructions; this turns one into store variables, with the annotation's
//! type variables resolved through a small scope list (they are scoped to
//! the annotation and cannot shadow, language.md §7, so a linear scan over a
//! handful of entries beats any map). The same code builds RIGID variables,
//! for checking a body against its annotation, and generalised FLEX ones,
//! for the scheme dependents see — the two differ by one field, and building
//! them from the same tree is what guarantees they have the same shape.
//!
//! `number` and `appendable` are recognised by the variable's NAME, as in
//! Elm (`Type.hs`'s `nameToSuper`): a variable called `number`, `number2`, …
//! has kind `number`. They are the closed set of `fast-compiler.md` §3.1 and
//! the only ad-hoc polymorphism in the language.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Artifacts = @import("../Artifacts.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");

const Types = @This();

pub const Symbol = InternPool.Symbol;
pub const TypeId = TypeStore.TypeId;
pub const Var = TypeStore.Var;

/// One declared type, wherever it lives.
pub const Entry = struct {
    module: Graph.Index,
    decl: Bir.DeclIndex,
    name: Symbol,
    /// Number of type parameters. Types are always fully applied
    /// (checker.md Appendix A), so this is also every use's argument count.
    arity: u8,
    kind: Interface.TypeKind,
    /// May be compared with `==` when every argument can (see the header).
    equatable: bool,
};

/// Owned. One per declared type, in topological module order.
entries: []Entry,
/// Owned. `by_decl[module][decl] = TypeId`, `.none` for a value
/// declaration. One flat array with per-module offsets, so nothing is
/// keyed by a name and nothing is a map.
by_decl: []TypeId,
decl_offsets: []u32,
/// Owned. `by_interface[module][interface type index] = TypeId`.
by_interface: []TypeId,
interface_offsets: []u32,
/// The types the checker itself names (`Int` for a literal, `List` for a
/// list, `Result`/`Maybe` for `?`). `.none` when the core package is not
/// part of the run.
well_known: WellKnown,

/// The handful of types the checker has to be able to name on its own,
/// because a literal, a list or a `?` has no written type to read them
/// from. Resolved once against the core package.
pub const WellKnown = struct {
    int: TypeId = .none,
    float: TypeId = .none,
    char: TypeId = .none,
    string: TypeId = .none,
    bool: TypeId = .none,
    list: TypeId = .none,
    maybe: TypeId = .none,
    result: TypeId = .none,
    /// The two the well-known method table of static-dispatch-spike.md §3.2
    /// names and nothing else does: `Order` is what `compare` answers and
    /// `Never` is the empty type. Both stay in `core/Basics.beni` (A.6).
    order: TypeId = .none,
    never: TypeId = .none,
};

pub const empty: Types = .{
    .entries = &.{},
    .by_decl = &.{},
    .decl_offsets = &.{},
    .by_interface = &.{},
    .interface_offsets = &.{},
    .well_known = .{},
};

pub fn deinit(types: *Types, gpa: Allocator) void {
    gpa.free(types.entries);
    gpa.free(types.by_decl);
    gpa.free(types.decl_offsets);
    gpa.free(types.by_interface);
    gpa.free(types.interface_offsets);
    types.* = empty;
}

/// The declaration behind `id`. `.none` and an out-of-range id both yield a
/// blank entry rather than a trap: every id in a Bir came from `ofDecl` or
/// `ofInterface`, but the checker must not crash on a poisoned one.
pub fn entry(types: *const Types, id: TypeId) Entry {
    if (id == .none or id.int() >= types.entries.len) return .{
        .module = @enumFromInt(0),
        .decl = @enumFromInt(0),
        .name = @enumFromInt(0),
        .arity = 0,
        .kind = .foreign,
        .equatable = true,
    };
    return types.entries[id.int()];
}

pub fn name(types: *const Types, id: TypeId) Symbol {
    return types.entry(id).name;
}

pub fn isEquatable(types: *const Types, id: TypeId) bool {
    if (id == .none) return true; // poisoned: say yes and stay quiet
    return types.entry(id).equatable;
}

/// The type declared by `decl` of `module`, or `.none` when that
/// declaration is a value.
pub fn ofDecl(types: *const Types, module: Graph.Index, decl: Bir.DeclIndex) TypeId {
    if (module.int() + 1 >= types.decl_offsets.len) return .none;
    const base = types.decl_offsets[module.int()];
    const limit = types.decl_offsets[module.int() + 1];
    // `base + decl` before the range test would overflow on a poisoned
    // index, and a `u32` overflow traps before the test could help.
    if (decl.int() >= limit - base) return .none;
    return types.by_decl[base + decl.int()];
}

/// The type at `index` in `module`'s interface.
pub fn ofInterface(types: *const Types, module: Graph.Index, index: Interface.TypeIndex) TypeId {
    if (module.int() + 1 >= types.interface_offsets.len) return .none;
    const base = types.interface_offsets[module.int()];
    const limit = types.interface_offsets[module.int() + 1];
    if (@intFromEnum(index) >= limit - base) return .none;
    return types.by_interface[base + @intFromEnum(index)];
}

// ---------------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------------

/// Number every type of every module, then settle equatability.
pub fn build(
    gpa: Allocator,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []const Interface,
    provenance: []const Interface.Provenance,
    interner: *const InternPool.Global,
) Allocator.Error!Types {
    var types: Types = .empty;
    errdefer types.deinit(gpa);
    const modules = graph.count();

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    var by_decl: std.ArrayList(TypeId) = .empty;
    errdefer by_decl.deinit(gpa);
    var by_interface: std.ArrayList(TypeId) = .empty;
    errdefer by_interface.deinit(gpa);
    const decl_offsets = try gpa.alloc(u32, modules + 1);
    errdefer gpa.free(decl_offsets);
    const interface_offsets = try gpa.alloc(u32, modules + 1);
    errdefer gpa.free(interface_offsets);

    // Topological order, so a type is numbered before anything that can
    // mention it. Nothing depends on that today — the ids are dense
    // whatever the order — but it keeps the table readable in a dump and
    // makes a future single-pass build possible.
    const ordered = try gpa.alloc(Graph.Index, modules);
    defer gpa.free(ordered);
    @memcpy(ordered, graph.order);

    // First pass: number the declarations, module by module in INDEX order
    // so the offset arrays can be filled in one sweep.
    for (0..modules) |i| {
        const m: Graph.Index = @enumFromInt(i);
        decl_offsets[i] = @intCast(by_decl.items.len);
        interface_offsets[i] = @intCast(by_interface.items.len);
        const bir = artifacts.bir(graph.moduleFile(m));
        for (bir.decls, 0..) |d, di| {
            if (d.kind.isValue()) {
                try by_decl.append(gpa, .none);
                continue;
            }
            const id: TypeId = @enumFromInt(entries.items.len);
            try entries.append(gpa, .{
                .module = m,
                .decl = @enumFromInt(@as(u32, @intCast(di))),
                .name = bir.symbol(d.name),
                .arity = std.math.cast(u8, d.params) orelse std.math.maxInt(u8),
                .kind = switch (d.kind) {
                    .type => .adt,
                    .type_alias => .alias,
                    else => .foreign,
                },
                .equatable = true, // settled below
            });
            try by_decl.append(gpa, id);
        }
        // The interface's types are the `pub` subset, sorted by name. The
        // declaration behind each one was recorded when the interface was
        // built (`Interface.Provenance`), so this is an array lookup: the
        // scan by name it replaced was O(interface types × declarations)
        // and was the name lookup checker.md §4.5 forbids.
        const iface = &interfaces[i];
        const prov = if (i < provenance.len) &provenance[i] else &Interface.Provenance.empty;
        for (0..iface.types.len) |ti| {
            const decl = prov.typeDecl(ti) orelse {
                try by_interface.append(gpa, .none);
                continue;
            };
            const at = decl_offsets[i] + decl.int();
            try by_interface.append(gpa, if (at < by_decl.items.len) by_decl.items[at] else .none);
        }
    }
    decl_offsets[modules] = @intCast(by_decl.items.len);
    interface_offsets[modules] = @intCast(by_interface.items.len);

    types.entries = try entries.toOwnedSlice(gpa);
    types.by_decl = try by_decl.toOwnedSlice(gpa);
    types.by_interface = try by_interface.toOwnedSlice(gpa);
    types.decl_offsets = decl_offsets;
    types.interface_offsets = interface_offsets;

    try types.settleEquatable(gpa, graph, artifacts);
    types.findWellKnown(graph, interfaces, interner);
    return types;
}

/// Shrink the optimistic "everything is equatable" assumption to a fixpoint
/// (see the header). A `foreign type` is fixed by its declaration and never
/// moves; everything else is false as soon as a function is reachable in
/// its body.
///
/// **One pass, then a worklist.** The property only ever goes true → false,
/// so it needs no re-scanning: walk each body ONCE, recording whether it
/// mentions a function and which other types it names, then propagate
/// `false` backwards along those edges. The re-scanning version this
/// replaced was O(types² × body size) whenever the dependency chain ran
/// against declaration order — 250 aliases took 38 ms and 2 000 took
/// 1 353 ms, a clean 4× per doubling — and it is serial, before the DAG,
/// so it was on the critical path of every build.
fn settleEquatable(
    types: *Types,
    gpa: Allocator,
    graph: *const Graph,
    artifacts: *const Artifacts,
) Allocator.Error!void {
    const n = types.entries.len;
    if (n == 0) return;

    // Edges `dependency → dependent`, flattened: `deps` is collected per
    // entry first, then counting-sorted into one array with per-dependency
    // offsets. No map, no per-node allocation.
    var edge_from: std.ArrayList(u32) = .empty;
    defer edge_from.deinit(gpa);
    var edge_to: std.ArrayList(u32) = .empty;
    defer edge_to.deinit(gpa);
    var deps: std.ArrayList(TypeId) = .empty;
    defer deps.deinit(gpa);

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);

    var walk: BodyWalk = .{ .gpa = gpa, .graph = graph, .artifacts = artifacts };
    defer walk.deinit();

    for (types.entries, 0..) |*e, i| {
        const bir = artifacts.bir(graph.moduleFile(e.module));
        const d = bir.decl(e.decl);
        if (e.kind == .foreign) {
            // Declared, never computed (checker.md Appendix B).
            e.equatable = d.is_equatable;
            if (!e.equatable) try queue.append(gpa, @intCast(i));
            continue;
        }
        deps.clearRetainingCapacity();
        var has_function = false;
        switch (e.kind) {
            .alias => if (d.annotation.unwrap()) |body| {
                has_function = try walk.run(types, e.module, bir, body, &deps);
            },
            .adt => for (bir.declCtors(d)) |c| {
                for (bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Bir.Inst.Index)) |arg| {
                    if (try walk.run(types, e.module, bir, arg, &deps)) has_function = true;
                }
            },
            .foreign => unreachable, // handled above
        }
        if (has_function) {
            e.equatable = false;
            try queue.append(gpa, @intCast(i));
            // A type already false needs no incoming edges: nothing can
            // make it false a second time.
            continue;
        }
        for (deps.items) |dep| {
            if (dep == .none or dep.int() >= n) continue;
            try edge_from.append(gpa, dep.int());
            try edge_to.append(gpa, @intCast(i));
        }
    }

    // Counting sort the edges by their source, so propagation is one scan
    // of a contiguous range per popped type.
    const starts = try gpa.alloc(u32, n + 1);
    defer gpa.free(starts);
    @memset(starts, 0);
    for (edge_from.items) |from| starts[from + 1] += 1;
    for (1..n + 1) |i| starts[i] += starts[i - 1];
    const dependents = try gpa.alloc(u32, edge_to.items.len);
    defer gpa.free(dependents);
    const cursor = try gpa.alloc(u32, n);
    defer gpa.free(cursor);
    @memcpy(cursor, starts[0..n]);
    for (edge_from.items, edge_to.items) |from, to| {
        dependents[cursor[from]] = to;
        cursor[from] += 1;
    }

    // Propagate. Each type is pushed at most once — it is pushed only on
    // the transition true → false — so this is O(types + edges).
    while (queue.pop()) |id| {
        for (dependents[starts[id]..starts[id + 1]]) |dependent| {
            if (!types.entries[dependent].equatable) continue;
            types.entries[dependent].equatable = false;
            try queue.append(gpa, dependent);
        }
    }
}

/// Walks a written type once: does it mention a function, and which other
/// declared types does it name? The two questions together are what
/// `settleEquatable` needs, and asking them in one walk is what turns its
/// fixpoint into a worklist.
///
/// Type PARAMETERS are not consulted — `List a` is equatable exactly when
/// `a` is, and the argument is checked at the use site by the obligation
/// walk of checker.md §6.4.
const BodyWalk = struct {
    gpa: Allocator,
    graph: *const Graph,
    artifacts: *const Artifacts,
    /// Reused across every body of the session; an annotation is as deep as
    /// the parser's nesting limit allows (4096), which does not belong on
    /// the C stack.
    stack: std.ArrayList(Frame) = .empty,

    const Frame = struct { module: Graph.Index, bir: *const Bir, inst: Bir.Inst.Index };

    fn deinit(w: *BodyWalk) void {
        w.stack.deinit(w.gpa);
    }

    /// True when a function is reachable. Every named type met on the way
    /// is appended to `out`, whether or not it is equatable today: the
    /// caller turns them into edges and propagates along them.
    ///
    /// The walk grows its worklist instead of truncating at a fixed size.
    /// A fixed one would have to answer "equatable" for a type too wide to
    /// finish, which is a silent yes to `==` on a function — the failure
    /// mode this whole milestone is about.
    fn run(
        w: *BodyWalk,
        types: *const Types,
        module: Graph.Index,
        bir: *const Bir,
        root: Bir.Inst.Index,
        out: *std.ArrayList(TypeId),
    ) Allocator.Error!bool {
        w.stack.clearRetainingCapacity();
        try w.stack.append(w.gpa, .{ .module = module, .bir = bir, .inst = root });
        // A well-formed Bir type is a TREE, so this terminates in the size
        // of the body; the budget only exists so a poisoned one cannot spin
        // forever, and it is stated in terms of the input rather than as a
        // constant so it cannot become the real limit.
        var budget: usize = @as(usize, bir.insts.len) + 16;
        while (w.stack.pop()) |frame| {
            if (budget == 0) return true; // see above: not a limit, a backstop
            budget -= 1;
            const b = frame.bir;
            const tag = b.instTag(frame.inst);
            const data = b.instData(frame.inst);
            switch (tag) {
                .type_fn => return true,
                .type_var, .type_unit, .@"error" => {},
                .type_top, .ext_type => try out.append(w.gpa, types.headId(frame.module, tag, data)),
                .type_app => {
                    const head_tag = b.instTag(@enumFromInt(data.lhs));
                    const head_data = b.instData(@enumFromInt(data.lhs));
                    try out.append(w.gpa, types.headId(frame.module, head_tag, head_data));
                    for (b.extraSlice(b.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index)) |arg| {
                        try w.stack.append(w.gpa, .{ .module = frame.module, .bir = b, .inst = arg });
                    }
                },
                .type_tuple => for (b.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)) |el| {
                    try w.stack.append(w.gpa, .{ .module = frame.module, .bir = b, .inst = el });
                },
                .type_record => for (b.extraSlice(Bir.inlineRange(data), Bir.Field)) |f| {
                    try w.stack.append(w.gpa, .{ .module = frame.module, .bir = b, .inst = f.value });
                },
                .type_record_ext => for (b.extraSlice(b.subRange(@enumFromInt(data.rhs)), Bir.Field)) |f| {
                    try w.stack.append(w.gpa, .{ .module = frame.module, .bir = b, .inst = f.value });
                },
                else => {},
            }
        }
        return false;
    }
};

/// The `TypeId` a resolved type reference names.
fn headId(types: *const Types, module: Graph.Index, tag: Bir.Inst.Tag, data: Bir.Inst.Data) TypeId {
    return switch (tag) {
        .type_top => types.ofDecl(module, @enumFromInt(data.lhs)),
        .ext_type => types.ofInterface(@enumFromInt(data.lhs), @enumFromInt(data.rhs)),
        else => .none,
    };
}

/// Resolve the types the checker names itself, against the core package.
fn findWellKnown(types: *Types, graph: *const Graph, interfaces: []const Interface, interner: *const InternPool.Global) void {
    const Pair = struct { module: InternPool.WellKnown, type_name: InternPool.WellKnown, slot: *TypeId };
    const pairs = [_]Pair{
        .{ .module = .Basics, .type_name = .Int, .slot = &types.well_known.int },
        .{ .module = .Basics, .type_name = .Float, .slot = &types.well_known.float },
        // `Char` and `String` are declared by their own modules
        // (static-dispatch-spike.md §5.1), not by `Basics`.
        .{ .module = .Char, .type_name = .Char, .slot = &types.well_known.char },
        .{ .module = .String, .type_name = .String, .slot = &types.well_known.string },
        .{ .module = .Basics, .type_name = .Bool, .slot = &types.well_known.bool },
        .{ .module = .List, .type_name = .List, .slot = &types.well_known.list },
        .{ .module = .Maybe, .type_name = .Maybe, .slot = &types.well_known.maybe },
        .{ .module = .Result, .type_name = .Result, .slot = &types.well_known.result },
        .{ .module = .Basics, .type_name = .Order, .slot = &types.well_known.order },
        .{ .module = .Basics, .type_name = .Never, .slot = &types.well_known.never },
    };
    for (pairs) |p| {
        // The prelude always targets package `core` (checker.md §4.3), so a
        // user module called `Basics` cannot move `Int` out from under the
        // checker.
        const m = graph.lookup(.core, p.module.symbol()) orelse continue;
        const iface = &interfaces[m.int()];
        const index = iface.findType(interner, p.type_name.symbol()) orelse continue;
        p.slot.* = types.ofInterface(m, index);
    }
}

// ---------------------------------------------------------------------------
// Reading a written type into the store
// ---------------------------------------------------------------------------

/// How a `type_var` in the tree being read becomes a store variable.
pub const VarMode = enum {
    /// An annotation being checked against a body: its variables are
    /// promises about ALL types, so they unify only with themselves
    /// (`rigid_mismatch`).
    rigid,
    /// An ordinary variable. Read at `TypeStore.generalized` this is the
    /// scheme dependents instantiate; read at the solver's current rank it
    /// is one fresh use of a constructor's type, which needs no
    /// instantiation because the variables were never shared.
    flex,
};

/// Turns written types into store variables. Holds the scope of an
/// annotation's type variables, which is why it is a value and not a
/// function: `a` in one annotation and `a` in the next are different
/// variables, and the scope is exactly this object's lifetime.
pub const Builder = struct {
    store: *TypeStore,
    types: *const Types,
    graph: *const Graph,
    artifacts: *const Artifacts,
    /// Where the tree being read lives; a cross-module alias body is read
    /// from ITS module, so this moves as the walk crosses a boundary.
    module: Graph.Index,
    bir: *const Bir,
    mode: VarMode,
    /// The rank every variable this builder makes is created at;
    /// `TypeStore.generalized` when the result is a scheme.
    rank: u32,
    scratch: Allocator,
    /// The pool every `Symbol` above comes from; needed to read a type
    /// variable's NAME, which is what decides its kind (see the header).
    interner: *const InternPool.Global,
    /// The annotation's type variables, in first-appearance order. A
    /// handful per annotation; a linear scan beats a map and keeps the
    /// order stable.
    scope: std.ArrayList(Scoped) = .empty,
    /// Bounds alias expansion; `recursive_alias` has refused the cyclic
    /// ones already, so this only catches a poisoned tree.
    depth: u32 = 0,
    /// Set when `max_depth` stopped the walk, so the caller can REPORT
    /// before it uses the poisoned result. "Errors never stop the build"
    /// (`fast-compiler.md` §5) means a poisoned variable after a message,
    /// never instead of one: an `err` unifies with anything, so a
    /// declaration truncated here would become a hole and a caller's
    /// mistake would compile clean. The flag rather than a report on the
    /// spot because this walk crosses modules — an alias body is read in
    /// ITS module — and the only instruction that names a position in the
    /// module being checked is the one the caller asked about.
    too_deep: bool = false,

    pub const Scoped = struct { name: Symbol, v: Var };

    pub const Error = Allocator.Error;

    /// How deep a written type may nest. Well under the parser's own
    /// `Parse.max_depth`, because an annotation is one tree among many and
    /// this walk also spends a level per alias expansion; past it the
    /// result is poisoned AND `too_deep` is set, so the caller reports.
    pub const max_depth: u32 = 512;

    pub fn init(
        store: *TypeStore,
        types: *const Types,
        graph: *const Graph,
        artifacts: *const Artifacts,
        module: Graph.Index,
        bir: *const Bir,
        mode: VarMode,
        rank: u32,
        scratch: Allocator,
        interner: *const InternPool.Global,
    ) Builder {
        return .{
            .store = store,
            .types = types,
            .graph = graph,
            .artifacts = artifacts,
            .module = module,
            .bir = bir,
            .mode = mode,
            .rank = rank,
            .scratch = scratch,
            .interner = interner,
        };
    }

    fn varRank(b: *const Builder) u32 {
        return b.rank;
    }

    /// Pre-bind `name` to `v`, for an alias body read with its parameters
    /// already chosen, or a constructor read under its type's parameters.
    pub fn bind(b: *Builder, name_symbol: Symbol, v: Var) Error!void {
        try b.scope.append(b.scratch, .{ .name = name_symbol, .v = v });
    }

    /// Read one written type. `inst` must be a type instruction of `b.bir`.
    pub fn read(b: *Builder, inst: Bir.Inst.Index) Error!Var {
        b.depth += 1;
        defer b.depth -= 1;
        if (b.depth > max_depth) {
            b.too_deep = true;
            return b.store.freshErr(b.varRank());
        }
        const bir = b.bir;
        const tag = bir.instTag(inst);
        const data = bir.instData(inst);
        switch (tag) {
            .type_var => return b.typeVar(bir.symbol(@enumFromInt(data.lhs)), Bir.TypeVarInfo.unpack(data.rhs)),
            .type_unit => return b.store.fresh(.{ .structure = .unit }, b.varRank()),
            .type_fn => {
                const params = bir.extraSlice(bir.subRange(@enumFromInt(data.lhs)), Bir.Inst.Index);
                const vars = try b.scratch.alloc(Var, params.len);
                defer b.scratch.free(vars);
                for (params, vars) |param, *v| v.* = try b.read(param);
                const range = try b.store.addVars(vars);
                const result = try b.read(@enumFromInt(data.rhs));
                return b.store.fresh(.{ .structure = .{ .func = .{ .params = range, .result = result } } }, b.varRank());
            },
            .type_tuple => {
                const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
                const vars = try b.scratch.alloc(Var, elements.len);
                defer b.scratch.free(vars);
                for (elements, vars) |el, *v| v.* = try b.read(el);
                const range = try b.store.addVars(vars);
                return b.store.fresh(.{ .structure = .{ .tuple = range } }, b.varRank());
            },
            .type_record => return b.record(bir.extraSlice(Bir.inlineRange(data), Bir.Field), null),
            .type_record_ext => return b.record(
                bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Field),
                @as(Bir.Inst.Index, @enumFromInt(data.lhs)),
            ),
            .type_top, .ext_type => return b.named(tag, data, &.{}),
            .type_app => {
                const args = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
                const vars = try b.scratch.alloc(Var, args.len);
                defer b.scratch.free(vars);
                for (args, vars) |arg, *v| v.* = try b.read(arg);
                const head: Bir.Inst.Index = @enumFromInt(data.lhs);
                return b.named(bir.instTag(head), bir.instData(head), vars);
            },
            // A type that did not resolve, or a parser placeholder. Poison
            // it: it has a diagnostic already and must not grow another.
            else => return b.store.freshErr(b.varRank()),
        }
    }

    fn typeVar(b: *Builder, name_symbol: Symbol, info: Bir.TypeVarInfo) Error!Var {
        for (b.scope.items) |s| {
            if (s.name == name_symbol) return s.v;
        }
        const text = b.interner.slice(name_symbol);
        const flags: TypeStore.Flags = .{
            .name = name_symbol.toOptional(),
            .kind = kindOfName(text),
            .equatable = info.equatable,
        };
        const v = try b.store.fresh(switch (b.mode) {
            .rigid => TypeStore.Content{ .rigid = flags },
            .flex => TypeStore.Content{ .flex = flags },
        }, b.varRank());
        try b.scope.append(b.scratch, .{ .name = name_symbol, .v = v });
        return v;
    }

    fn record(b: *Builder, fields: []const Bir.Field, ext: ?Bir.Inst.Index) Error!Var {
        const pairs = try b.scratch.alloc(TypeStore.Field, fields.len);
        defer b.scratch.free(pairs);
        for (fields, pairs) |f, *p| {
            p.* = .{ .name = b.bir.symbol(f.name), .value = try b.read(f.value) };
        }
        const range = try b.store.addFields(pairs);
        const ext_var = if (ext) |e|
            try b.read(e)
        else
            try b.store.fresh(.{ .structure = .empty_record }, b.varRank());
        return b.store.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext_var } } }, b.varRank());
    }

    /// A named type applied to `args`: an `app` for an ADT or a foreign
    /// type, an interned `alias` for an alias (checker.md §5 — never
    /// expanded away, only looked THROUGH).
    fn named(b: *Builder, tag: Bir.Inst.Tag, data: Bir.Inst.Data, args: []const Var) Error!Var {
        const id: TypeId = switch (tag) {
            .type_top => b.types.ofDecl(b.module, @enumFromInt(data.lhs)),
            .ext_type => b.types.ofInterface(@enumFromInt(data.lhs), @enumFromInt(data.rhs)),
            else => .none,
        };
        if (id == .none) return b.store.freshErr(b.varRank());
        return b.apply(id, args);
    }

    /// Build `id args`, expanding an alias's body ONCE under its
    /// parameters.
    pub fn apply(b: *Builder, id: TypeId, args: []const Var) Error!Var {
        const e = b.types.entry(id);
        const range = try b.store.addVars(args);
        if (e.kind != .alias) {
            return b.store.fresh(.{ .structure = .{ .app = .{ .type = id, .args = range } } }, b.varRank());
        }
        const actual = try b.aliasBody(e, args);
        return b.store.fresh(.{ .alias = .{ .type = id, .args = range, .actual = actual } }, b.varRank());
    }

    /// Expand an alias's body once, under its parameters.
    ///
    /// **This reads the DECLARING module's Bir, and for a cross-module
    /// alias that is a hole in the §8.1 firewall** — one of exactly two
    /// left after M2d, the other being `Types.build` itself. It is not
    /// reachable today (every module's Bir is in memory for the whole run)
    /// and it is not what the checker.md §4.5 rule is about: no name is
    /// looked up, the module and declaration are dense indices resolution
    /// produced. But M4 wants a dependency's Bir to be absent, and this
    /// would have nothing to read.
    ///
    /// Closing it is checker.md §7's `alias_body: TermIndex?`, written the
    /// way `Ctor.arg_terms` now is: the expansion as terms quantified over
    /// the alias's parameters, instantiated from the interface here. That
    /// is deliberately NOT done yet, because it would close one of two
    /// holes and leave the larger one — `Types.build` walks every module's
    /// declarations to number the types and settle equatability, so M4
    /// needs a story for the whole type table, not for alias bodies alone.
    /// The comment is here so nothing claims a firewall that does not exist.
    fn aliasBody(b: *Builder, e: Entry, args: []const Var) Error!Var {
        const bir = b.artifacts.bir(b.graph.moduleFile(e.module));
        const d = bir.decl(e.decl);
        const body = d.annotation.unwrap() orelse return b.store.freshErr(b.varRank());
        // The alias's body is read in ITS module with ITS parameters bound,
        // in a scope of its own: the caller's type variables are not in
        // scope inside it and must not leak into it.
        var inner: Builder = .init(b.store, b.types, b.graph, b.artifacts, e.module, bir, b.mode, b.rank, b.scratch, b.interner);
        inner.depth = b.depth;
        defer {
            // The inner builder is a different object reading a different
            // module's tree; its verdict is part of THIS read's answer.
            b.too_deep = b.too_deep or inner.too_deep;
            inner.deinit();
        }
        const params = bir.declTypeParams(d);
        for (params, 0..) |p, i| {
            try inner.bind(p, if (i < args.len) args[i] else try b.store.freshErr(b.varRank()));
        }
        return inner.read(body);
    }

    pub fn deinit(b: *Builder) void {
        b.scope.deinit(b.scratch);
    }
};

/// Elm's `nameToSuper` (`Type.hs`): a type variable spelled `number`,
/// `number2`, … carries the `number` kind, and likewise `appendable`. The
/// set is closed by `fast-compiler.md` §3.1 and `comparable` is deliberately
/// not in it.
pub fn kindOfName(text: []const u8) TypeStore.Kind {
    if (std.mem.startsWith(u8, text, "number")) return .number;
    if (std.mem.startsWith(u8, text, "appendable")) return .appendable;
    return .any;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "kindOfName recognises Elm's numbered super-variables and nothing else" {
    try testing.expectEqual(TypeStore.Kind.number, kindOfName("number"));
    try testing.expectEqual(TypeStore.Kind.number, kindOfName("number2"));
    try testing.expectEqual(TypeStore.Kind.appendable, kindOfName("appendable"));
    try testing.expectEqual(TypeStore.Kind.appendable, kindOfName("appendable9"));
    try testing.expectEqual(TypeStore.Kind.any, kindOfName("a"));
    try testing.expectEqual(TypeStore.Kind.any, kindOfName("num"));
    // `comparable` was dropped by fast-compiler.md §3.1 and must not come
    // back through a name.
    try testing.expectEqual(TypeStore.Kind.any, kindOfName("comparable"));
}
