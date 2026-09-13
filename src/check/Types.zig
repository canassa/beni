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
        // The interface's types are the `pub` subset, sorted by name, so
        // the mapping is a lookup of each by its declaration.
        const iface = &interfaces[i];
        for (iface.types) |t| {
            const target = iface.symbol(t.name);
            var found: TypeId = .none;
            for (bir.decls, 0..) |d, di| {
                if (d.kind.isValue() or bir.symbol(d.name) != target) continue;
                found = by_decl.items[decl_offsets[i] + di];
                break;
            }
            try by_interface.append(gpa, found);
        }
    }
    decl_offsets[modules] = @intCast(by_decl.items.len);
    interface_offsets[modules] = @intCast(by_interface.items.len);

    types.entries = try entries.toOwnedSlice(gpa);
    types.by_decl = try by_decl.toOwnedSlice(gpa);
    types.by_interface = try by_interface.toOwnedSlice(gpa);
    types.decl_offsets = decl_offsets;
    types.interface_offsets = interface_offsets;

    types.settleEquatable(graph, artifacts);
    types.findWellKnown(graph, interfaces, interner);
    return types;
}

/// Shrink the optimistic "everything is equatable" assumption to a fixpoint
/// (see the header). A `foreign type` is fixed by its declaration and never
/// moves; everything else is false as soon as a function is reachable in
/// its body.
fn settleEquatable(types: *Types, graph: *const Graph, artifacts: *const Artifacts) void {
    for (types.entries) |*e| {
        if (e.kind != .foreign) continue;
        const bir = artifacts.bir(graph.moduleFile(e.module));
        e.equatable = bir.decl(e.decl).is_equatable;
    }
    var changed = true;
    // Bounded so a malformed table cannot spin: each round either clears at
    // least one flag or stops, and there are only so many flags.
    var rounds: usize = 0;
    while (changed and rounds <= types.entries.len) : (rounds += 1) {
        changed = false;
        for (types.entries, 0..) |*e, i| {
            if (!e.equatable or e.kind == .foreign) continue;
            const bir = artifacts.bir(graph.moduleFile(e.module));
            const d = bir.decl(e.decl);
            const ok = switch (e.kind) {
                .alias => if (d.annotation.unwrap()) |body| types.bodyEquatable(e.module, bir, body) else true,
                .adt => blk: {
                    for (bir.declCtors(d)) |c| {
                        for (bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Bir.Inst.Index)) |arg| {
                            if (!types.bodyEquatable(e.module, bir, arg)) break :blk false;
                        }
                    }
                    break :blk true;
                },
                // Filtered out above; a `foreign` type's flag is
                // declared, never computed.
                .foreign => true,
            };
            if (!ok) {
                types.entries[i].equatable = false;
                changed = true;
            }
        }
    }
}

/// Whether a written type mentions no function, treating type VARIABLES as
/// equatable (their arguments are checked at the use site).
fn bodyEquatable(
    types: *const Types,
    module: Graph.Index,
    bir: *const Bir,
    root: Bir.Inst.Index,
) bool {
    // An iterative walk: an annotation is as deep as the parser's nesting
    // limit allows, which is 4096, and that does not belong on the C stack.
    var stack: [256]struct { module: Graph.Index, bir: *const Bir, inst: Bir.Inst.Index } = undefined;
    var len: usize = 1;
    stack[0] = .{ .module = module, .bir = bir, .inst = root };
    var budget: usize = 1 << 16;
    while (len > 0) {
        if (budget == 0) return true; // pathological input: stay quiet
        budget -= 1;
        len -= 1;
        const frame = stack[len];
        const b = frame.bir;
        const tag = b.instTag(frame.inst);
        const data = b.instData(frame.inst);
        const push = struct {
            fn f(s: anytype, l: *usize, m: Graph.Index, bb: *const Bir, i: Bir.Inst.Index) bool {
                if (l.* >= s.len) return false;
                s[l.*] = .{ .module = m, .bir = bb, .inst = i };
                l.* += 1;
                return true;
            }
        }.f;
        switch (tag) {
            .type_fn => return false,
            .type_var, .type_unit, .@"error" => {},
            .type_top, .ext_type => {
                const id = types.headId(frame.module, tag, data);
                if (!types.isEquatable(id)) return false;
            },
            .type_app => {
                const head_tag = b.instTag(@enumFromInt(data.lhs));
                const head_data = b.instData(@enumFromInt(data.lhs));
                const id = types.headId(frame.module, head_tag, head_data);
                if (!types.isEquatable(id)) return false;
                for (b.extraSlice(b.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index)) |arg| {
                    if (!push(&stack, &len, frame.module, b, arg)) return true;
                }
            },
            .type_tuple => for (b.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)) |el| {
                if (!push(&stack, &len, frame.module, b, el)) return true;
            },
            .type_record => for (b.extraSlice(Bir.inlineRange(data), Bir.Field)) |f| {
                if (!push(&stack, &len, frame.module, b, f.value)) return true;
            },
            .type_record_ext => for (b.extraSlice(b.subRange(@enumFromInt(data.rhs)), Bir.Field)) |f| {
                if (!push(&stack, &len, frame.module, b, f.value)) return true;
            },
            else => {},
        }
    }
    return true;
}

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
        .{ .module = .Basics, .type_name = .Char, .slot = &types.well_known.char },
        .{ .module = .Basics, .type_name = .String, .slot = &types.well_known.string },
        .{ .module = .Basics, .type_name = .Bool, .slot = &types.well_known.bool },
        .{ .module = .List, .type_name = .List, .slot = &types.well_known.list },
        .{ .module = .Maybe, .type_name = .Maybe, .slot = &types.well_known.maybe },
        .{ .module = .Result, .type_name = .Result, .slot = &types.well_known.result },
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

    pub const Scoped = struct { name: Symbol, v: Var };

    pub const Error = Allocator.Error;

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
        if (b.depth > 512) return b.store.freshErr(b.varRank());
        const bir = b.bir;
        const tag = bir.instTag(inst);
        const data = bir.instData(inst);
        switch (tag) {
            .type_var => return b.typeVar(bir.symbol(@enumFromInt(data.lhs)), Bir.TypeVarInfo.unpack(data.rhs)),
            .type_unit => return b.store.fresh(.{ .structure = .unit }, b.varRank()),
            .type_fn => {
                const param = try b.read(@enumFromInt(data.lhs));
                const result = try b.read(@enumFromInt(data.rhs));
                return b.store.fresh(.{ .structure = .{ .func = .{ .param = param, .result = result } } }, b.varRank());
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

    fn aliasBody(b: *Builder, e: Entry, args: []const Var) Error!Var {
        const bir = b.artifacts.bir(b.graph.moduleFile(e.module));
        const d = bir.decl(e.decl);
        const body = d.annotation.unwrap() orelse return b.store.freshErr(b.varRank());
        // The alias's body is read in ITS module with ITS parameters bound,
        // in a scope of its own: the caller's type variables are not in
        // scope inside it and must not leak into it.
        var inner: Builder = .init(b.store, b.types, b.graph, b.artifacts, e.module, bir, b.mode, b.rank, b.scratch, b.interner);
        inner.depth = b.depth;
        defer inner.deinit();
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
