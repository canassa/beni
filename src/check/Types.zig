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
//! **Two more bits ride that fixpoint.** `comparable` is the same walk
//! asking whether `<` can be answered (static-dispatch-spike.md §3.3, A.54)
//! — false for a `foreign type` whose module declares no `pub compare` of
//! its own, and false for anything holding one. `has_function` is the same
//! walk again, run the other way up: false by default, true along the edges
//! from any type whose body holds a function, because the two gates above
//! fold several causes into one bit and §10.3 needs to know which (A.58).
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
const SourceStore = @import("../SourceStore.zig");
const TypeStore = @import("TypeStore.zig");
const reads = @import("reads.zig");
const InterfaceTerms = @import("InterfaceTerms.zig");

const Types = @This();

pub const Symbol = InternPool.Symbol;
pub const TypeId = TypeStore.TypeId;
pub const Var = TypeStore.Var;

/// One declared type, wherever it lives.
pub const Entry = struct {
    module: Graph.Index,
    decl: Bir.DeclIndex,
    name: Symbol,
    /// The declaring module's identity, `(package, name)` — copied here
    /// rather than reached through the graph because it is what an
    /// `Interface.TypeRef` is made of, and the interface writer must be
    /// able to name a type without holding the module graph
    /// (`Interface.TypeRef`, `fast-compiler.md` §8.1).
    package: SourceStore.Package,
    module_name: Symbol,
    /// Number of type parameters. Types are always fully applied
    /// (checker.md Appendix A), so this is also every use's argument count.
    arity: u16,
    kind: Interface.TypeKind,
    /// May be compared with `==` when every argument can (see the header).
    equatable: bool,
    /// May be ORDERED with `<` — the same fixpoint, one gate further out
    /// (`docs/design/static-dispatch-spike.md` §3.3, A.50, A.54).
    ///
    /// `equatable` does not answer this question. A `foreign type` is
    /// equatable when its declaration says so and there is nothing more to
    /// know; it is COMPARABLE only when §3.2's table answers for it or its
    /// own module declares a `pub compare` whose first parameter is that
    /// type (`declaresPubCompare`), because deriving one would mean writing
    /// a body over a representation the compiler cannot see. So
    /// `type Wraps = Wraps Handle` over a plain `foreign type Handle` is not
    /// comparable however equatable it is, and without this field `a < b` on
    /// it derived a function whose one part was `err`.
    comparable: bool,
    /// A function type is reachable inside this type's body — through
    /// another named type as well, which is what makes it a fixpoint and
    /// not a property of one body (A.58).
    ///
    /// `equatable` folds this together with "a payload that cannot answer
    /// the method", and `comparable` folds it together with "a `foreign
    /// type` whose module declares no `pub compare`". Neither can say WHICH
    /// happened, and §10.3 has a different sentence for each — so the one
    /// question a message needs is asked separately and kept here.
    has_function: bool,
    /// Compiler-generated endpoint identity owned by a schema declaration.
    /// These entries have no ordinary type declaration body for the
    /// equatability walk to inspect.
    schema_endpoint: bool = false,
};

/// Owned. One per declared type, in topological module order.
entries: []Entry,
/// Borrowed session interface slots, used to map schema member references
/// back to their endpoint identity.
interfaces: []const Interface,
/// Owned. `by_decl[module][decl] = TypeId`, `.none` for a value
/// declaration. One flat array with per-module offsets, so nothing is
/// keyed by a name and nothing is a map.
by_decl: []TypeId,
schema_type_by_decl: []TypeId,
schema_encoded_by_decl: []TypeId,
/// Owned, parallel to `by_decl`: the index in its module's interface of
/// the schema a declaration declares, `no_schema` for any other
/// declaration and for a private schema. An alias body read from another
/// module names that module's schema by declaration, and the endpoint's
/// scheme is in the interface (CK-122).
schema_iface_by_decl: []u32,
decl_offsets: []u32,
/// Owned. `by_interface[module][interface type index] = TypeId`.
by_interface: []TypeId,
interface_offsets: []u32,
/// Two ids per interface schema, Type then Encoded.
by_schema: []TypeId,
schema_offsets: []u32,
/// Owned. `entries[entry_offsets[m]..entry_offsets[m+1]]` are module `m`'s
/// declared types, `pub` and private alike — the range `resolveRefs`
/// searches by name.
entry_offsets: []u32,
/// Owned, one slice per module: `ref_ids[m][r]` is the `TypeId` module
/// `m`'s interface `type_refs[r]` names in THIS session.
///
/// **Not part of any interface record**, and deliberately on this side of
/// the boundary: the record says `(package, module name, type name)`
/// because those bytes are a function of the source (`Interface.TypeRef`),
/// and this is the session's one-off translation of them, exactly as
/// `by_interface` is for an interface `TypeIndex`. A reader indexes it, so
/// resolving a type reference stays O(1) however many times a scheme is
/// instantiated.
///
/// Filled per module at the end of that module's check, by the thread that
/// checked it, into its own slot; a dependent cannot run before its
/// dependency has finished (checker.md §4.4), so nothing reads a slot
/// before it is written.
ref_ids: [][]TypeId,
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
    schema: TypeId = .none,
    conversion: TypeId = .none,
    presence: TypeId = .none,
    nullable: TypeId = .none,
    issue: TypeId = .none,
    options: TypeId = .none,
    value: TypeId = .none,
};

pub const empty: Types = .{
    .entries = &.{},
    .interfaces = &.{},
    .by_decl = &.{},
    .schema_type_by_decl = &.{},
    .schema_encoded_by_decl = &.{},
    .schema_iface_by_decl = &.{},
    .decl_offsets = &.{},
    .by_interface = &.{},
    .interface_offsets = &.{},
    .by_schema = &.{},
    .schema_offsets = &.{},
    .entry_offsets = &.{},
    .ref_ids = &.{},
    .well_known = .{},
};

pub fn deinit(types: *Types, gpa: Allocator) void {
    gpa.free(types.entries);
    gpa.free(types.by_decl);
    gpa.free(types.schema_type_by_decl);
    gpa.free(types.schema_encoded_by_decl);
    gpa.free(types.schema_iface_by_decl);
    gpa.free(types.decl_offsets);
    gpa.free(types.by_interface);
    gpa.free(types.interface_offsets);
    gpa.free(types.by_schema);
    gpa.free(types.schema_offsets);
    for (types.ref_ids) |ids| gpa.free(ids);
    gpa.free(types.ref_ids);
    gpa.free(types.entry_offsets);
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
        .package = .app,
        .module_name = @enumFromInt(0),
        .arity = 0,
        .kind = .foreign,
        .equatable = true,
        .comparable = true,
        .has_function = false,
        .schema_endpoint = false,
    };
    const e = types.entries[id.int()];
    // The funnel every `Types.Entry` field goes through — `name`,
    // `isEquatable`, `isComparable`, `hasFunction`, `named` and the `arity`
    // and `kind` `Builder.apply` reads — so one note covers §3.2 rows 2–6 and
    // 14 (`reads.zig`).
    reads.note(.types_entry, e.module);
    return e;
}

pub fn name(types: *const Types, id: TypeId) Symbol {
    return types.entry(id).name;
}

pub fn isEquatable(types: *const Types, id: TypeId) bool {
    if (id == .none) return true; // poisoned: say yes and stay quiet
    return types.entry(id).equatable;
}

pub fn count(types: *const Types) usize {
    return types.entries.len;
}

/// The type declared by `decl` of `module`, or `.none` when that
/// declaration is a value.
pub fn ofDecl(types: *const Types, module: Graph.Index, decl: Bir.DeclIndex) TypeId {
    reads.note(.types_of_decl, module);
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
    reads.note(.types_of_interface, module);
    if (module.int() + 1 >= types.interface_offsets.len) return .none;
    const base = types.interface_offsets[module.int()];
    const limit = types.interface_offsets[module.int() + 1];
    if (@intFromEnum(index) >= limit - base) return .none;
    return types.by_interface[base + @intFromEnum(index)];
}

pub fn ofSchema(types: *const Types, module: Graph.Index, index: Interface.SchemaIndex, endpoint: Interface.SchemaCtor.Endpoint) TypeId {
    if (module.int() + 1 >= types.schema_offsets.len) return .none;
    const base = types.schema_offsets[module.int()];
    const limit = types.schema_offsets[module.int() + 1];
    const at = @as(u64, @intFromEnum(index)) * 2 + @intFromEnum(endpoint);
    if (at >= limit - base) return .none;
    return types.by_schema[base + @as(u32, @intCast(at))];
}

pub fn ofSchemaDecl(types: *const Types, module: Graph.Index, decl: Bir.DeclIndex, endpoint: Interface.SchemaCtor.Endpoint) TypeId {
    if (module.int() + 1 >= types.decl_offsets.len) return .none;
    const base = types.decl_offsets[module.int()];
    const limit = types.decl_offsets[module.int() + 1];
    if (decl.int() >= limit - base) return .none;
    return switch (endpoint) {
        .type => types.schema_type_by_decl[base + decl.int()],
        .encoded => types.schema_encoded_by_decl[base + decl.int()],
    };
}

pub const no_schema: u32 = std.math.maxInt(u32);

/// The interface member for `endpoint` of the schema `module` declares at
/// `decl`, or null when that schema is not in the interface.
pub fn schemaMemberOfDecl(types: *const Types, module: Graph.Index, decl: Bir.DeclIndex, endpoint: Interface.SchemaCtor.Endpoint) ?u32 {
    if (module.int() + 1 >= types.decl_offsets.len or module.int() >= types.interfaces.len) return null;
    const base = types.decl_offsets[module.int()];
    const limit = types.decl_offsets[module.int() + 1];
    if (decl.int() >= limit - base) return null;
    const si = types.schema_iface_by_decl[base + decl.int()];
    const iface = &types.interfaces[module.int()];
    if (si >= iface.schemas.len) return null;
    const schema = iface.schemas[si];
    const want: Interface.SchemaMember.Kind = if (endpoint == .type) .type else .encoded;
    var m = schema.members_start;
    while (m < schema.members_end and m < iface.schema_members.len) : (m += 1) {
        if (iface.schema_members[m].kind == want) return m;
    }
    return null;
}

fn typesFromLists(base: u32, decl: Bir.DeclIndex, endpoint: Interface.SchemaCtor.Endpoint, type_ids: []const TypeId, encoded_ids: []const TypeId) TypeId {
    const at = @as(u64, base) + decl.int();
    const ids = if (endpoint == .type) type_ids else encoded_ids;
    if (at >= ids.len) return .none;
    return ids[@intCast(at)];
}

/// How `id` is written into an interface record: the declaring module's
/// package and name, and the type's own name (`Interface.TypeRef`).
/// Null for `.none` and for an id no entry describes, which the writer
/// turns into `TypeRefIndex.none`.
pub const Named = struct {
    package: SourceStore.Package,
    module: Symbol,
    name: Symbol,
};

pub fn named(types: *const Types, id: TypeId) ?Named {
    if (id == .none or id.int() >= types.entries.len) return null;
    const e = types.entries[id.int()];
    return .{ .package = e.package, .module = e.module_name, .name = e.name };
}

/// This session's translation of module `m`'s interface type references.
/// Empty until `m` has been checked, which is also when its terms exist.
pub fn refIds(types: *const Types, m: Graph.Index) []const TypeId {
    reads.note(.types_ref_ids, m);
    if (m.int() >= types.ref_ids.len) return &.{};
    return types.ref_ids[m.int()];
}

/// Translate every `Interface.TypeRef` of `iface` into this session's
/// `TypeId`, once, so that reading a term is an array index.
///
/// A reference is resolved by NAME against the declaring module's whole
/// declaration list rather than against its interface, because a `pub`
/// signature may name a PRIVATE type (`pub make : Hidden`) and that type is
/// in no interface. The scan is linear in one module's declared types and
/// runs once per module per build, not once per use; the `checker.md` §4.5
/// rule is about the per-use path, which `ref_ids` keeps free of names.
///
/// A reference that names no module or no type of it yields `.none` — the
/// same poisoned id the term carried before, so a record M4 mapped from
/// disk that does not describe itself cannot trap.
pub fn resolveRefs(
    types: *const Types,
    gpa: Allocator,
    iface: *const Interface,
    graph: *const Graph,
) Allocator.Error![]TypeId {
    const out = try gpa.alloc(TypeId, iface.type_refs.len);
    errdefer gpa.free(out);
    for (iface.type_refs, out) |ref, *slot| {
        slot.* = types.find(graph, ref.package, iface.symbol(ref.module), iface.symbol(ref.name));
    }
    return out;
}

/// The type named `name` declared by the module `(package, module)`, or
/// `.none`. The only name lookup on the type table, and it is a one-off:
/// see `resolveRefs`.
pub fn find(types: *const Types, graph: *const Graph, package: SourceStore.Package, module: Symbol, type_name: Symbol) TypeId {
    const m = graph.find(package, module) orelse return .none;
    // The one place a check can reach a module it has no import edge to
    // (`checker.md` §7's first `type_refs` consequence): a record names the
    // DECLARING module, and this resolves that name. §3.2 row 11.
    reads.note(.types_find, m);
    if (m.int() + 1 >= types.entry_offsets.len) return .none;
    const from = types.entry_offsets[m.int()];
    const to = types.entry_offsets[m.int() + 1];
    for (types.entries[from..to], from..) |e, i| {
        if (e.name == type_name) return @enumFromInt(i);
    }
    return .none;
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
    types.interfaces = interfaces;
    errdefer types.deinit(gpa);
    const modules = graph.count();

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    var by_decl: std.ArrayList(TypeId) = .empty;
    errdefer by_decl.deinit(gpa);
    var schema_type_by_decl: std.ArrayList(TypeId) = .empty;
    errdefer schema_type_by_decl.deinit(gpa);
    var schema_encoded_by_decl: std.ArrayList(TypeId) = .empty;
    errdefer schema_encoded_by_decl.deinit(gpa);
    var schema_iface_by_decl: std.ArrayList(u32) = .empty;
    errdefer schema_iface_by_decl.deinit(gpa);
    var by_interface: std.ArrayList(TypeId) = .empty;
    errdefer by_interface.deinit(gpa);
    var by_schema: std.ArrayList(TypeId) = .empty;
    errdefer by_schema.deinit(gpa);
    const decl_offsets = try gpa.alloc(u32, modules + 1);
    errdefer gpa.free(decl_offsets);
    const interface_offsets = try gpa.alloc(u32, modules + 1);
    errdefer gpa.free(interface_offsets);
    const schema_offsets = try gpa.alloc(u32, modules + 1);
    errdefer gpa.free(schema_offsets);
    const entry_offsets = try gpa.alloc(u32, modules + 1);
    errdefer gpa.free(entry_offsets);
    // One empty slot per module; each is filled by the thread that checks
    // that module, once its terms exist (see `ref_ids`).
    const ref_ids = try gpa.alloc([]TypeId, modules);
    errdefer gpa.free(ref_ids);
    @memset(ref_ids, &.{});

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
        schema_offsets[i] = @intCast(by_schema.items.len);
        entry_offsets[i] = @intCast(entries.items.len);
        const bir = artifacts.bir(graph.moduleFile(m));
        const package = graph.modules.items(.package)[i];
        const module_name = graph.moduleName(m);
        try schema_iface_by_decl.appendNTimes(gpa, no_schema, bir.decls.len);
        for (bir.decls, 0..) |d, di| {
            if (d.kind == .schema) {
                try by_decl.append(gpa, .none);
                const tagged = if (d.schema_body.unwrap()) |root| schemaTagged(bir, root) else false;
                inline for ([_]Interface.SchemaCtor.Endpoint{ .type, .encoded }) |endpoint| {
                    const suffix = if (endpoint == .type) "Type" else "Encoded";
                    const full = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ interner.slice(bir.symbol(d.name)), suffix });
                    defer gpa.free(full);
                    const endpoint_name = interner.find(full) orelse unreachable;
                    const id: TypeId = @enumFromInt(entries.items.len);
                    try entries.append(gpa, .{
                        .module = m,
                        .decl = @enumFromInt(di),
                        .name = endpoint_name,
                        .package = package,
                        .module_name = module_name,
                        .arity = std.math.cast(u16, d.params) orelse std.math.maxInt(u16),
                        .kind = if (tagged) .adt else .alias,
                        .equatable = true,
                        .comparable = true,
                        .has_function = false,
                        .schema_endpoint = true,
                    });
                    if (endpoint == .type) try schema_type_by_decl.append(gpa, id) else try schema_encoded_by_decl.append(gpa, id);
                }
                continue;
            }
            try schema_type_by_decl.append(gpa, .none);
            try schema_encoded_by_decl.append(gpa, .none);
            if (d.kind.isValue()) {
                try by_decl.append(gpa, .none);
                continue;
            }
            const id: TypeId = @enumFromInt(entries.items.len);
            try entries.append(gpa, .{
                .module = m,
                .decl = @enumFromInt(@as(u32, @intCast(di))),
                .name = bir.symbol(d.name),
                .package = package,
                .module_name = module_name,
                .arity = std.math.cast(u16, d.params) orelse std.math.maxInt(u16),
                .kind = switch (d.kind) {
                    .type => .adt,
                    .type_alias => .alias,
                    else => .foreign,
                },
                .equatable = true, // settled below
                .comparable = true, // settled below
                .has_function = false, // settled below
                .schema_endpoint = false,
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
        for (iface.schemas, 0..) |_, si| {
            const decl = prov.schemaDecl(si) orelse {
                try by_schema.appendSlice(gpa, &.{ .none, .none });
                continue;
            };
            if (decl.int() < bir.decls.len) schema_iface_by_decl.items[decl_offsets[i] + decl.int()] = @intCast(si);
            inline for ([_]Interface.SchemaCtor.Endpoint{ .type, .encoded }) |endpoint| {
                try by_schema.append(gpa, typesFromLists(decl_offsets[i], decl, endpoint, schema_type_by_decl.items, schema_encoded_by_decl.items));
            }
        }
    }
    decl_offsets[modules] = @intCast(by_decl.items.len);
    interface_offsets[modules] = @intCast(by_interface.items.len);
    schema_offsets[modules] = @intCast(by_schema.items.len);
    entry_offsets[modules] = @intCast(entries.items.len);

    types.entries = try entries.toOwnedSlice(gpa);
    types.by_decl = try by_decl.toOwnedSlice(gpa);
    types.schema_type_by_decl = try schema_type_by_decl.toOwnedSlice(gpa);
    types.schema_encoded_by_decl = try schema_encoded_by_decl.toOwnedSlice(gpa);
    types.schema_iface_by_decl = try schema_iface_by_decl.toOwnedSlice(gpa);
    types.by_interface = try by_interface.toOwnedSlice(gpa);
    types.by_schema = try by_schema.toOwnedSlice(gpa);
    types.decl_offsets = decl_offsets;
    types.interface_offsets = interface_offsets;
    types.schema_offsets = schema_offsets;
    types.entry_offsets = entry_offsets;
    types.ref_ids = ref_ids;

    // The table of §3.2 FIRST: `settleEquatable` settles `comparable`
    // alongside `equatable`, and a `Char` is comparable because the table
    // says so and not because `core/Char.beni` declares anything.
    types.findWellKnown(graph, interfaces, interner);
    try types.settleEquatable(gpa, graph, artifacts);
    return types;
}

fn schemaTagged(bir: *const Bir, root: Bir.Inst.Index) bool {
    var at = root;
    var budget: usize = bir.insts.len + 1;
    while (budget > 0 and at.int() < bir.insts.len) : (budget -= 1) switch (bir.instTag(at)) {
        .schema_tagged => return true,
        .schema_value, .schema_paren => at = @enumFromInt(bir.instData(at).lhs),
        else => return false,
    };
    return false;
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
    // `comparable` is the SAME fixpoint over the SAME edges, so it rides
    // along: one body walk, two properties, two queues (A.54).
    var order_queue: std.ArrayList(u32) = .empty;
    defer order_queue.deinit(gpa);
    // And `has_function` is the same fixpoint run the other way up (A.58):
    // it starts FALSE and spreads TRUE along the same edges, because a type
    // holds a function exactly when one of the types it holds does. It is
    // what lets §10.3 tell "there is a function inside it" from "something
    // it holds has no ordering", which the two folded gates above cannot.
    var function_queue: std.ArrayList(u32) = .empty;
    defer function_queue.deinit(gpa);

    var walk: BodyWalk = .{ .gpa = gpa, .graph = graph, .artifacts = artifacts };
    defer walk.deinit();

    for (types.entries, 0..) |*e, i| {
        if (e.schema_endpoint) continue;
        const bir = artifacts.bir(graph.moduleFile(e.module));
        const d = bir.decl(e.decl);
        if (e.kind == .foreign) {
            // Declared, never computed (checker.md Appendix B).
            e.equatable = d.is_equatable;
            if (!e.equatable) try queue.append(gpa, @intCast(i));
            // A `foreign type` has no body to derive `compare` over, so it
            // answers `<` only through §3.2's table or through a `pub
            // compare` of its own module (A.50). `List` has neither until
            // §5.2 lands in S6, which is what makes `xs < ys` an honest
            // `unknown_method` today.
            e.comparable = types.inWellKnownTable(@enumFromInt(i)) or
                types.declaresPubCompare(e.module, bir, @enumFromInt(i));
            if (!e.comparable) try order_queue.append(gpa, @intCast(i));
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
            e.comparable = false;
            e.has_function = true;
            try queue.append(gpa, @intCast(i));
            try order_queue.append(gpa, @intCast(i));
            try function_queue.append(gpa, @intCast(i));
            // A type already false needs no incoming edges for `equatable`
            // or `comparable`: nothing can make it false a second time. It
            // still needs its OUTGOING edges, because `has_function` runs
            // the other way — this type is how a function reaches the ones
            // that hold it.
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
    while (order_queue.pop()) |id| {
        for (dependents[starts[id]..starts[id + 1]]) |dependent| {
            if (!types.entries[dependent].comparable) continue;
            types.entries[dependent].comparable = false;
            try order_queue.append(gpa, dependent);
        }
    }
    while (function_queue.pop()) |id| {
        for (dependents[starts[id]..starts[id + 1]]) |dependent| {
            if (types.entries[dependent].has_function) continue;
            types.entries[dependent].has_function = true;
            try function_queue.append(gpa, dependent);
        }
    }
}

/// Whether §3.2's table answers `eq` and `compare` for `id`. The five types
/// that stay in `core/Basics.beni` plus `String` and `Char`: the table
/// exists precisely because the module rule cannot serve them, so the
/// fixpoint must not ask it to either.
fn inWellKnownTable(types: *const Types, id: TypeId) bool {
    const wk = types.well_known;
    return id != .none and (id == wk.int or id == wk.float or id == wk.char or
        id == wk.string or id == wk.bool or id == wk.order or id == wk.never);
}

/// Whether the module that declares the `foreign type` `id` supplies the
/// `pub compare` that A.50 says is the only way to order one — asked of the
/// module rule exactly as a USE would ask it (§1.2).
///
/// Two halves, and the property needs both. **`pub`**, because this answer
/// is one bit on a session-wide table read from every module, and a private
/// `compare` is invisible to all but one of them: a gate that said yes
/// would make `type Wraps = Wraps Handle` derive a `compare` whose one part
/// is `err` everywhere else. **The first parameter**, because a module's
/// `pub` values are one namespace (§11) — `pub compare : Tag, Tag -> Order`
/// beside an unrelated `pub foreign type Handle` is `Tag`'s method and not
/// `Handle`'s, and taking it for `Handle`'s emitted a call to it with a
/// `Handle` in hand.
fn declaresPubCompare(types: *const Types, module: Graph.Index, bir: *const Bir, id: TypeId) bool {
    return types.declaresPubMethod(module, bir, id, InternPool.WellKnown.compare.symbol());
}

fn declaresPubMethod(types: *const Types, module: Graph.Index, bir: *const Bir, id: TypeId, method_name: Symbol) bool {
    for (bir.decls) |d| {
        if (!d.kind.isValue() or !d.is_pub) continue;
        if (bir.symbol(d.name) != method_name) continue;
        const annotation = d.annotation.unwrap() orelse continue;
        if (bir.instTag(annotation) != .type_fn) continue;
        const params = bir.extraSlice(bir.subRange(@enumFromInt(bir.instData(annotation).lhs)), Bir.Inst.Index);
        if (params.len == 0) continue;
        if (types.writtenHead(module, bir, params[0]) == id) return true;
    }
    return false;
}

/// The `TypeId` a written type's HEAD names: `Handle`, `List a` and a bare
/// `Handle` alike. `.none` for anything else — a variable, a tuple, a
/// record, a function.
fn writtenHead(types: *const Types, module: Graph.Index, bir: *const Bir, inst: Bir.Inst.Index) TypeId {
    const tag = bir.instTag(inst);
    if (tag == .type_app) {
        const head: Bir.Inst.Index = @enumFromInt(bir.instData(inst).lhs);
        return types.headId(module, bir.instTag(head), bir.instData(head));
    }
    return types.headId(module, tag, bir.instData(inst));
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
                .type_top, .ext_type, .schema_type_top, .ext_schema_type => try out.append(w.gpa, types.headId(frame.module, tag, data)),
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
        .schema_type_top => types.ofSchemaDecl(module, @enumFromInt(data.lhs), if (data.rhs == 0) .type else .encoded),
        .ext_schema_type => blk: {
            const owner: Graph.Index = @enumFromInt(data.lhs);
            if (owner.int() >= types.interfaces.len) break :blk .none;
            const iface = &types.interfaces[owner.int()];
            for (iface.schemas, 0..) |schema, i| {
                if (data.rhs < schema.members_start or data.rhs >= schema.members_end) continue;
                const endpoint: Interface.SchemaCtor.Endpoint = switch (iface.schema_members[data.rhs].kind) {
                    .type => .type,
                    .encoded => .encoded,
                    else => break :blk .none,
                };
                break :blk types.ofSchema(owner, @enumFromInt(i), endpoint);
            }
            break :blk .none;
        },
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
        .{ .module = .Schema, .type_name = .Schema, .slot = &types.well_known.schema },
        .{ .module = .Schema, .type_name = .Conversion, .slot = &types.well_known.conversion },
        .{ .module = .Schema, .type_name = .Presence, .slot = &types.well_known.presence },
        .{ .module = .Schema, .type_name = .Nullable, .slot = &types.well_known.nullable },
        .{ .module = .Schema, .type_name = .Issue, .slot = &types.well_known.issue },
        .{ .module = .Schema, .type_name = .Options, .slot = &types.well_known.options },
        .{ .module = .Schema, .type_name = .Value, .slot = &types.well_known.value },
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
    schema_context: ?*anyopaque = null,
    schema_lookup: ?*const fn (*anyopaque, u32, bool, []const Var) Allocator.Error!?Var = null,
    interfaces: []const Interface = &.{},
    /// The annotation's type variables, in first-appearance order. A
    /// handful per annotation; a linear scan beats a map and keeps the
    /// order stable.
    scope: std.ArrayList(Scoped) = .empty,
    /// Bounds alias expansion; `recursive_alias` has refused the cyclic
    /// ones already, so this only catches a poisoned tree.
    depth: u32 = 0,
    /// The aliases whose bodies are being expanded around this read,
    /// innermost first (`aliasBody`). An alias met inside its own
    /// expansion is `err`: it is recursive, which resolution reported
    /// (`recursive_alias`; a cycle across modules is an `import_cycle`).
    /// The depth bound alone did not stop it — `type alias A = ( A, A )`
    /// doubles per level, 2^512 reads before the bound (CK-140).
    expanding: ?*const Expansion = null,
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

    /// One alias being expanded, and the expansion around it.
    pub const Expansion = struct { id: TypeId, outer: ?*const Expansion };

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
            .type_top, .ext_type, .schema_type_top, .ext_schema_type => return b.named(tag, data, &.{}),
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
        // A declaration's parameter carries its index (`TypeVarInfo.param`),
        // and every reader binds a declaration's parameters first and in
        // order (`bind`), so the slot is checked, not searched: a scan per
        // variable was O(n²) in the parameter count (CK-112). Anything else
        // falls back to the scan.
        if (info.param != Bir.TypeVarInfo.param_none and info.param < b.scope.items.len) {
            const s = b.scope.items[info.param];
            if (s.name == name_symbol) return s.v;
        }
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
        if (tag == .ext_schema_type) return b.schemaMember(@enumFromInt(data.lhs), data.rhs, args);
        const id: TypeId = switch (tag) {
            .type_top => b.types.ofDecl(b.module, @enumFromInt(data.lhs)),
            .ext_type => b.types.ofInterface(@enumFromInt(data.lhs), @enumFromInt(data.rhs)),
            .schema_type_top => blk: {
                if (b.schema_context) |ctx| if (b.schema_lookup) |lookup| if (try lookup(ctx, data.lhs, data.rhs != 0, args)) |root| return root;
                // An alias body read from the module that declares it
                // (`aliasBody`), when that is not the module being
                // checked: the endpoint's scheme is in that module's
                // interface (CK-122).
                if (b.schema_context == null) {
                    const endpoint: Interface.SchemaCtor.Endpoint = if (data.rhs == 0) .type else .encoded;
                    if (b.types.schemaMemberOfDecl(b.module, @enumFromInt(data.lhs), endpoint)) |member| {
                        return b.schemaMember(b.module, member, args);
                    }
                    // A private schema is in no interface. Its tagged
                    // endpoint is a nominal type, whole in its `TypeId`;
                    // a record endpoint's shape is not (CK-126).
                    const id = b.types.ofSchemaDecl(b.module, @enumFromInt(data.lhs), endpoint);
                    if (id != .none and b.types.entry(id).kind == .adt) break :blk id;
                }
                break :blk .none;
            },
            .ext_schema_type => unreachable,
            else => .none,
        };
        if (id == .none) return b.store.freshErr(b.varRank());
        return b.apply(id, args);
    }

    /// A schema endpoint of another module, from its interface's scheme.
    fn schemaMember(b: *Builder, module: Graph.Index, member: u32, args: []const Var) Error!Var {
        if (module.int() >= b.interfaces.len) return b.store.freshErr(b.varRank());
        const iface = &b.interfaces[module.int()];
        if (member >= iface.schema_members.len) return b.store.freshErr(b.varRank());
        const scheme_i = iface.schema_members[member].scheme;
        if (scheme_i == .none) return b.store.freshErr(b.varRank());
        const scheme = iface.scheme(scheme_i);
        return InterfaceTerms.instantiateRoot(iface, b.types.refIds(module), b.store, scheme.body, args, b.rank, b.scratch);
    }

    /// Build `id args`, expanding an alias's body ONCE under its
    /// parameters.
    ///
    /// A count that is not the type's arity is `err` (CK-139): resolution
    /// reported it (`wrong_type_arity`, `resolve/Resolve.zig`), and a
    /// partial application must never reach the store, where every reader
    /// of an `app` — derivation's context entries first — indexes its
    /// arguments by the declaration's parameters.
    pub fn apply(b: *Builder, id: TypeId, args: []const Var) Error!Var {
        const e = b.types.entry(id);
        if (args.len != e.arity) return b.store.freshErr(b.varRank());
        const range = try b.store.addVars(args);
        if (e.kind != .alias) {
            return b.store.fresh(.{ .structure = .{ .app = .{ .type = id, .args = range } } }, b.varRank());
        }
        // Inside its own expansion: recursive, and reported (`expanding`).
        var at = b.expanding;
        while (at) |x| : (at = x.outer) {
            if (x.id == id) return b.store.freshErr(b.varRank());
        }
        const actual = try b.aliasBody(e, id, args);
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
    fn aliasBody(b: *Builder, e: Entry, id: TypeId, args: []const Var) Error!Var {
        // §3.2 row 12, and one of the two demonstrated miscompiles
        // (`plans/m4-3.md` §6.2): the expansion is in no record, so the digest
        // is what makes it visible.
        reads.note(.types_alias_body, e.module);
        const bir = b.artifacts.bir(b.graph.moduleFile(e.module));
        const d = bir.decl(e.decl);
        const body = d.annotation.unwrap() orelse return b.store.freshErr(b.varRank());
        // The alias's body is read in ITS module with ITS parameters bound,
        // in a scope of its own: the caller's type variables are not in
        // scope inside it and must not leak into it.
        var inner: Builder = .init(b.store, b.types, b.graph, b.artifacts, e.module, bir, b.mode, b.rank, b.scratch, b.interner);
        inner.depth = b.depth;
        const here: Expansion = .{ .id = id, .outer = b.expanding };
        inner.expanding = &here;
        // A schema endpoint in the body is read as the caller would read
        // it written directly (CK-122): through the caller's schema lookup
        // when the alias is the checked module's own, and through the
        // declaring module's interface otherwise (`named`). Without them
        // the body was a silent `err`, and a comparison of the alias an
        // `internal`.
        inner.interfaces = b.interfaces;
        if (e.module == b.module) {
            inner.schema_context = b.schema_context;
            inner.schema_lookup = b.schema_lookup;
        }
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
