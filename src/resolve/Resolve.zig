//! Cross-module name resolution (docs/design/checker.md §4.5): every module
//! in topological order, every reference in it looked up once against the
//! interfaces of the modules it imports, and REWRITTEN IN PLACE to the pair
//! of dense indices it resolved to.
//!
//! Rewriting is the point. Lowering leaves a reference as two symbols —
//! `import_value(Basics, add)` — because one file's text is all it may
//! know. After this pass that instruction is `ext_value(module 3, value 7)`
//! and no later phase ever looks a name up again: the checker indexes an
//! array, the backend indexes an array, and the cache key is a pair of
//! integers rather than a string comparison. A reference to the module's
//! OWN declarations becomes `top`/`ctor`/`type_top`, and one that does not
//! resolve becomes `error`, so the unresolved forms simply do not exist
//! downstream (`Bir.Inst.Tag.isUnresolved`).
//!
//! Four rules decide what a miss means, and they need the target module's
//! Bir as well as its interface — the interface holds what is public, and
//! "is it private or is it absent?" is exactly the difference between
//! `private_name` and `unknown_import_name`:
//!
//!   - in the interface            → resolved
//!   - declared but not `pub`      → `private_name`
//!   - a constructor of a `pub opaque type` → `opaque_constructor`
//!   - not declared at all         → `unknown_import_name`
//!
//! Two checks ride along because they need exactly the same tables:
//!
//!   - **`wrong_type_arity`.** Types are always fully applied (checker.md
//!     Appendix A), so a type reference's argument count must equal the
//!     declared parameter count — 0 for a bare name.
//!   - **`recursive_alias`.** An alias may not mention itself, directly or
//!     through other aliases. The search stays inside one module, and that
//!     is not a shortcut: a chain of aliases that leaves a module and comes
//!     back needs those modules to import each other, which is an
//!     `import_cycle` and is reported there.
//!
//! Poisoned modules — the members of an import cycle — are rewritten but
//! not reported on (checker.md §4.3): one bad edge yields one diagnostic,
//! not one per name in the loop.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Artifacts = @import("../Artifacts.zig");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");
const Tokenizer = @import("../lex/Tokenizer.zig");
const Graph = @import("Graph.zig");
const Profile = @import("../Profile.zig");
const Interface = @import("Interface.zig");
const prelude = @import("../bir/prelude.zig");

const Resolve = @This();

pub const Symbol = InternPool.Symbol;

/// Owned. One per module, indexed by `Graph.Index`; `Interface.empty` for
/// a module that could not be built.
interfaces: []Interface,
/// Owned. One per module, in lockstep with `interfaces`: which `Bir`
/// declaration each interface entry came from. Kept OUT of the interface
/// itself because it is meaningless once the Bir is gone and must never be
/// hashed with the record the cache stores (`Interface.Provenance`).
provenance: []Interface.Provenance,
/// Owned. In the order the modules were resolved, which is topological and
/// therefore stable; the session sorts them with everything else.
diagnostics: []const Item,
/// Constructor names named by `unknown_schema_member` items, back to back.
available_names: []const Symbol,

/// A resolution diagnostic before it is rendered: which module, which
/// token, and the names the prose needs (`Diagnostics.Context`).
pub const Item = struct {
    code: diagnostic.Code,
    module: Graph.Index,
    /// Token index into the module's file.
    token: u32,
    name: Symbol.Optional = .none,
    module_name: Symbol.Optional = .none,
    owner: Symbol.Optional = .none,
    expected: u32 = 0,
    found: u32 = 0,
    available_start: u32 = 0,
    available_end: u32 = 0,
    schema_origin_module: ?Graph.Index = null,
    schema_origin_token: u32 = 0,
    alias_origin_module: ?Graph.Index = null,
    alias_origin_token: u32 = 0,
};

pub const empty: Resolve = .{ .interfaces = &.{}, .provenance = &.{}, .diagnostics = &.{}, .available_names = &.{} };

pub fn deinit(r: *Resolve, gpa: Allocator) void {
    for (r.interfaces) |*iface| iface.deinit(gpa);
    gpa.free(r.interfaces);
    for (r.provenance) |*p| p.deinit(gpa);
    gpa.free(r.provenance);
    gpa.free(r.diagnostics);
    gpa.free(r.available_names);
    r.* = undefined;
}

/// Resolve every module of `graph`, in its topological order. `scratch` is
/// one worker's arena and holds nothing after the call; the interfaces and
/// the diagnostics are `gpa`-owned and belong to the session.
/// Resolve every module in the graph's order. `profile` gets one `resolve`
/// event per MODULE (checker.md §9) — the per-module granularity is what
/// the incrementality tests read, since "this module was not re-resolved"
/// is only visible if the trace has a row per module.
pub fn run(
    gpa: Allocator,
    scratch: Allocator,
    graph: *const Graph,
    store: *const SourceStore,
    artifacts: *Artifacts,
    interner: *const InternPool.Global,
    profile: ?*Profile,
) Allocator.Error!Resolve {
    var r: Resolve = .empty;
    errdefer r.deinit(gpa);
    r.interfaces = try gpa.alloc(Interface, graph.count());
    @memset(r.interfaces, Interface.empty);
    r.provenance = try gpa.alloc(Interface.Provenance, graph.count());
    @memset(r.provenance, Interface.Provenance.empty);

    var diagnostics: std.ArrayList(Item) = .empty;
    errdefer diagnostics.deinit(gpa);
    var available_names: std.ArrayList(Symbol) = .empty;
    errdefer available_names.deinit(gpa);

    var pass: Pass = .{
        .gpa = gpa,
        .scratch = scratch,
        .graph = graph,
        .store = store,
        .artifacts = artifacts,
        .interner = interner,
        .interfaces = r.interfaces,
        .provenance = r.provenance,
        .diagnostics = &diagnostics,
        .available_names = &available_names,
    };
    defer pass.tables.deinit(gpa);
    for (graph.order) |m| {
        const token = if (profile) |p| p.begin() else null;
        try pass.module(m);
        if (profile) |p| p.end(0, token.?, .resolve, graph.moduleFile(m).int(), 0);
    }
    r.diagnostics = try diagnostics.toOwnedSlice(gpa);
    r.available_names = try available_names.toOwnedSlice(gpa);
    return r;
}

/// Name → first index, for one namespace of one module: sorted by name and
/// then by index, so the lower bound of a name is its FIRST declaration —
/// the answer the scan it replaced gave, duplicates included (a duplicate
/// declaration has been reported by lowering and resolves to the first).
const NameTable = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { name: Symbol, index: u32 };

    fn add(t: *NameTable, gpa: Allocator, name: Symbol, index: u32) Allocator.Error!void {
        try t.entries.append(gpa, .{ .name = name, .index = index });
    }

    /// Entries are added in increasing `index`, so a stable sort by name
    /// alone keeps each name's entries in index order.
    fn seal(t: *NameTable) void {
        std.sort.pdq(Entry, t.entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                if (a.name != b.name) return @intFromEnum(a.name) < @intFromEnum(b.name);
                return a.index < b.index;
            }
        }.lessThan);
    }

    fn first(t: *const NameTable, name: Symbol) ?u32 {
        const items = t.entries.items;
        const at = std.sort.partitionPoint(Entry, items, name, struct {
            fn below(target: Symbol, e: Entry) bool {
                return @intFromEnum(e.name) < @intFromEnum(target);
            }
        }.below);
        if (at < items.len and items[at].name == name) return items[at].index;
        return null;
    }
};

/// The current module's own names by namespace, and the schemas its
/// `exposing` lists bring in. Every qualified reference asks
/// whether its root names a schema, and a self-qualified one what it
/// declares; both were a scan of the module's declarations (or of every
/// import's `exposing` list) PER REFERENCE — quadratic in a module's size.
/// Rebuilt per module in O(d log d), the buffers reused.
const Tables = struct {
    values: NameTable = .{},
    types: NameTable = .{},
    ctors: NameTable = .{},
    schemas: NameTable = .{},
    /// `index` of an entry is into `exposed_sources`.
    exposed_schemas: NameTable = .{},
    exposed_sources: std.ArrayList(SchemaSource) = .empty,

    fn clear(t: *Tables) void {
        inline for (.{ &t.values, &t.types, &t.ctors, &t.schemas, &t.exposed_schemas }) |table| table.entries.clearRetainingCapacity();
        t.exposed_sources.clearRetainingCapacity();
    }

    fn deinit(t: *Tables, gpa: Allocator) void {
        inline for (.{ &t.values, &t.types, &t.ctors, &t.schemas, &t.exposed_schemas }) |table| table.entries.deinit(gpa);
        t.exposed_sources.deinit(gpa);
    }
};

const SchemaSource = union(enum) {
    local: u32,
    external: struct { module: Graph.Index, schema: Interface.SchemaIndex },
};

const Pass = struct {
    gpa: Allocator,
    scratch: Allocator,
    graph: *const Graph,
    store: *const SourceStore,
    artifacts: *Artifacts,
    interner: *const InternPool.Global,
    interfaces: []Interface,
    provenance: []Interface.Provenance,
    diagnostics: *std.ArrayList(Item),
    available_names: *std.ArrayList(Symbol),

    /// The module being resolved, and the things every helper needs.
    current: Graph.Index = @enumFromInt(0),
    quiet: bool = false,
    /// The current module's names, looked up per reference.
    tables: Tables = .{},

    fn report(p: *Pass, item: Item) Allocator.Error!void {
        if (p.quiet) return;
        try p.diagnostics.append(p.gpa, item);
    }

    fn module(p: *Pass, m: Graph.Index) Allocator.Error!void {
        p.current = m;
        p.quiet = p.graph.isPoisoned(m);
        const file = p.graph.moduleFile(m);
        const bir = p.artifacts.birMut(file);
        try p.buildTables(m, bir);
        try p.checkExposing(m, bir);
        try p.rewriteReferences(m, bir);
        try p.checkTypeArity(bir);
        try p.checkRecursiveAliases(bir);
        const built = try Interface.build(p.gpa, bir, p.interner);
        p.interfaces[m.int()] = built.iface;
        p.provenance[m.int()] = built.provenance;
    }

    // ---- `exposing` lists ------------------------------------------------

    /// Every name in an `exposing` list must be something the named module
    /// exposes (language.md §5.2), whether or not this file goes on to use
    /// it. A reference would catch the used ones; an unused entry that
    /// names nothing is still a lie about the import, and the list is where
    /// a reader looks to see what a module offers.
    ///
    /// An upper name is a type OR a constructor and the file cannot tell
    /// which (§5.2), so either is enough.
    fn checkExposing(p: *Pass, m: Graph.Index, bir: *const Bir) Allocator.Error!void {
        if (p.quiet) return;
        const pkg = p.graph.modulePackage(m);
        for (bir.imports) |imp| {
            if (imp.prelude) continue;
            const module_symbol = bir.symbol(imp.module);
            const target = p.graph.lookup(pkg, module_symbol) orelse continue; // `unknown_module`, already reported
            if (target == m) continue; // `self_import`, already reported
            const iface = &p.interfaces[target.int()];
            for (bir.importExposed(imp)) |e| {
                const name = bir.symbol(e.name);
                if (e.all_ctors_token != 0) try p.exposeAllCtors(m, iface, e, name);
                if (iface.findValue(p.interner, name) != null) continue;
                if (iface.findType(p.interner, name) != null) continue;
                if (iface.findCtor(p.interner, name) != null) continue;
                if (iface.findSchema(p.interner, name) != null) continue;
                // Which namespace the name belongs to is not knowable from
                // the list, so the "why" is asked of each in turn and the
                // most specific answer wins.
                const code = p.whyExposedMissing(target, name);
                var item: Item = .{
                    .code = code,
                    .module = m,
                    .token = e.token,
                    .name = name.toOptional(),
                    .module_name = module_symbol.toOptional(),
                };
                if (code == .opaque_constructor) item.owner = p.owningTypeName(target, name).toOptional();
                try p.report(item);
            }
        }
    }

    /// Elm's `T(..)`: the parser has already
    /// reported `expected_token` at the `(`, without the constructors,
    /// because only this interface lists them. This item carries them, as
    /// `available`, and `Session.reportResolveDiagnostics` rewrites the
    /// parser's message with it rather than add a second diagnostic.
    fn exposeAllCtors(p: *Pass, m: Graph.Index, iface: *const Interface, e: Bir.Exposed, name: Symbol) Allocator.Error!void {
        const available_start: u32 = @intCast(p.available_names.items.len);
        if (iface.findType(p.interner, name)) |t| {
            const start, const end = iface.types[@intFromEnum(t)].ctorRange();
            for (iface.ctors[start..end]) |ctor| try p.available_names.append(p.gpa, iface.symbol(ctor.name));
        }
        try p.report(.{
            .code = .expected_token,
            .module = m,
            .token = e.all_ctors_token,
            .name = name.toOptional(),
            .available_start = available_start,
            .available_end = @intCast(p.available_names.items.len),
        });
    }

    fn whyExposedMissing(p: *Pass, target: Graph.Index, name: Symbol) diagnostic.Code {
        for ([_]Namespace{ .value, .type, .ctor, .schema }) |namespace| {
            const code = p.whyMissing(target, name, namespace);
            if (code != .unknown_import_name) return code;
        }
        return .unknown_import_name;
    }

    // ---- References ------------------------------------------------------

    fn rewriteReferences(p: *Pass, m: Graph.Index, bir: *Bir) Allocator.Error!void {
        const tags = bir.insts.items(.tag);
        const data = bir.insts.items(.data);
        const tokens = bir.insts.items(.main_token);
        for (bir.decls, 0..) |decl, decl_i| {
            for (tags[decl.inst_start.int()..decl.inst_end.int()], data[decl.inst_start.int()..decl.inst_end.int()], tokens[decl.inst_start.int()..decl.inst_end.int()]) |*tag, *d, token| {
                if (!tag.isUnresolved()) continue;
                const resolved = switch (tag.*) {
                    .import_value, .qualified, .import_ctor, .qualified_ctor, .type_import, .type_qualified => blk: {
                        const module_symbol = bir.symbol(@enumFromInt(d.lhs));
                        const name = bir.symbol(@enumFromInt(d.rhs));
                        const namespace: Namespace = switch (tag.*) {
                            .import_value, .qualified => .value,
                            .import_ctor, .qualified_ctor => .ctor,
                            .type_import, .type_qualified => .type,
                            else => unreachable,
                        };
                        break :blk try p.resolveOrdinaryReference(m, bir, module_symbol, name, namespace, token);
                    },
                    .schema_type_ref => try p.resolveSchemaUse(m, bir, @intCast(decl_i), bir.symbol(@enumFromInt(d.lhs)), .type, token),
                    .schema_value_ref => try p.resolveSchemaUse(m, bir, @intCast(decl_i), bir.symbol(@enumFromInt(d.lhs)), .value, token),
                    .schema_ctor_ref => try p.resolveSchemaUse(m, bir, @intCast(decl_i), bir.symbol(@enumFromInt(d.lhs)), .ctor, token),
                    .schema_ref => try p.resolveSchemaOperand(m, bir, @intCast(decl_i), bir.symbol(@enumFromInt(d.lhs)), token),
                    .schema_expr_ref => try p.resolveSchemaExpr(m, bir, bir.symbol(@enumFromInt(d.lhs)), token),
                    else => unreachable,
                };
                tag.* = resolved.tag;
                d.* = .{ .lhs = resolved.lhs, .rhs = resolved.rhs };
            }
        }
    }

    const Namespace = enum { value, ctor, type, schema };

    const Resolved = struct {
        tag: Bir.Inst.Tag,
        lhs: u32,
        rhs: u32,

        fn poison(code: diagnostic.Code) Resolved {
            return .{ .tag = .@"error", .lhs = @intFromEnum(code), .rhs = 0 };
        }
    };

    fn resolveOne(p: *Pass, m: Graph.Index, module_symbol: Symbol, name: Symbol, namespace: Namespace, token: u32) Allocator.Error!Resolved {
        const target = p.graph.lookup(p.graph.modulePackage(m), module_symbol) orelse {
            // Lowering checked that the ALIAS is imported (language.md
            // §6.2); this is the other half — whether the module it names
            // exists at all, which only the graph knows. A prelude module
            // reaching here means the core package is missing.
            try p.report(.{
                .code = .unknown_module_alias,
                .module = m,
                .token = token,
                .name = name.toOptional(),
                .module_name = module_symbol.toOptional(),
            });
            return .poison(.unknown_module_alias);
        };
        // A module's references to itself resolve to its own declarations
        // (checker.md §4.3), public or not: it is not importing anything.
        if (target == m) return p.resolveSelf(m, name, namespace, token, module_symbol);
        return p.resolveImported(m, target, name, namespace, token, module_symbol);
    }

    fn resolveOrdinaryReference(p: *Pass, m: Graph.Index, bir: *const Bir, module_symbol: Symbol, name: Symbol, namespace: Namespace, token: u32) Allocator.Error!Resolved {
        const target = p.graph.lookup(p.graph.modulePackage(m), module_symbol);
        const ordinary_exists = target != null and p.ordinaryExists(target.?, name, namespace);
        if (p.qualifiedRoot(m, token)) |root| {
            if (p.schemaFromRoot(m, bir, root)) |schema| if (p.schemaAccessExists(schema, name, namespace)) {
                var alias_import: ?Bir.Import = null;
                for (bir.imports) |imp| {
                    if (bir.symbol(imp.alias) == root and bir.symbol(imp.module) == module_symbol) {
                        alias_import = imp;
                        break;
                    }
                }
                if (ordinary_exists and alias_import != null) {
                    const imp = alias_import.?;
                    const origin = p.schemaSourceOrigin(m, schema);
                    try p.report(.{
                        .code = .schema_name_collision,
                        .module = m,
                        .token = token,
                        .name = root.toOptional(),
                        .module_name = module_symbol.toOptional(),
                        .owner = p.schemaOrigin(m, schema).toOptional(),
                        .schema_origin_module = origin.module,
                        .schema_origin_token = origin.token,
                        .alias_origin_module = m,
                        .alias_origin_token = imp.name_token,
                    });
                    return .poison(.schema_name_collision);
                }
                if (!ordinary_exists) {
                    const path: SchemaPath = .{ .source = schema, .schema_name = root, .rest = p.interner.slice(name) };
                    return switch (namespace) {
                        .type => p.resolveSchemaTypeMember(m, path, token),
                        .value => p.resolveSchemaValueMember(m, path, token),
                        .ctor => p.resolveSchemaConstructor(m, bir, path, token),
                        .schema => unreachable,
                    };
                }
            };
        }
        return p.resolveOne(m, module_symbol, name, namespace, token);
    }

    fn qualifiedRoot(p: *Pass, m: Graph.Index, token: u32) ?Symbol {
        const file = p.graph.moduleFile(m);
        const tokens = p.artifacts.tokens(file);
        if (token >= tokens.len) return null;
        const text = Tokenizer.slice(p.store.bytes(file), tokens.items(.tag)[token], tokens.items(.start)[token]);
        const dot = std.mem.indexOfScalar(u8, text, '.') orelse return null;
        return p.interner.find(text[0..dot]);
    }

    fn ordinaryExists(p: *Pass, target: Graph.Index, name: Symbol, namespace: Namespace) bool {
        const iface = &p.interfaces[target.int()];
        return switch (namespace) {
            .value => iface.findValue(p.interner, name) != null,
            .type => iface.findType(p.interner, name) != null,
            .ctor => iface.findCtor(p.interner, name) != null,
            .schema => false,
        };
    }

    fn schemaAccessExists(p: *Pass, source: SchemaSource, name: Symbol, namespace: Namespace) bool {
        const text = p.interner.slice(name);
        return switch (namespace) {
            .type => schemaMemberKind(text) == .type or schemaMemberKind(text) == .encoded,
            .value => if (schemaMemberKind(text)) |kind| kind != .type and kind != .encoded else false,
            .ctor => switch (source) {
                .local => |di| localSchemaVariant(p.artifacts.bir(p.graph.moduleFile(p.current)), @enumFromInt(di), name) != null,
                .external => |ext| p.interfaces[ext.module.int()].findSchemaCtor(ext.schema, .type, p.interner, name) != null,
            },
            .schema => false,
        };
    }

    fn resolveSelf(p: *Pass, m: Graph.Index, name: Symbol, namespace: Namespace, token: u32, module_symbol: Symbol) Allocator.Error!Resolved {
        const bir = p.artifacts.bir(p.graph.moduleFile(m));
        // `m` is the module being resolved: a reference resolves against
        // itself only from inside itself.
        std.debug.assert(m == p.current);
        const t = &p.tables;
        switch (namespace) {
            .value => if (t.values.first(name)) |i| return .{ .tag = .top, .lhs = i, .rhs = 0 },
            .type => if (t.types.first(name)) |i| return .{ .tag = .type_top, .lhs = i, .rhs = 0 },
            .ctor => if (t.ctors.first(name)) |i| return .{ .tag = .ctor, .lhs = i, .rhs = 0 },
            .schema => if (t.schemas.first(name)) |i| return .{ .tag = .schema_target_top, .lhs = i, .rhs = 0 },
        }
        if (namespace == .type or namespace == .value or namespace == .ctor) {
            if (p.localSchema(bir, name)) |di| {
                const code: diagnostic.Code = if (namespace == .type) .schema_used_as_type else .schema_used_as_value;
                try p.report(.{ .code = code, .module = m, .token = token, .name = name.toOptional(), .expected = bir.decls[di].params });
                return .poison(code);
            }
        }
        try p.report(.{
            .code = .unknown_import_name,
            .module = m,
            .token = token,
            .name = name.toOptional(),
            .module_name = module_symbol.toOptional(),
        });
        return .poison(.unknown_import_name);
    }

    fn resolveImported(p: *Pass, m: Graph.Index, target: Graph.Index, name: Symbol, namespace: Namespace, token: u32, module_symbol: Symbol) Allocator.Error!Resolved {
        const iface = &p.interfaces[target.int()];
        switch (namespace) {
            .value => if (iface.findValue(p.interner, name)) |v| {
                return .{ .tag = .ext_value, .lhs = target.int(), .rhs = @intFromEnum(v) };
            },
            .type => if (iface.findType(p.interner, name)) |t| {
                return .{ .tag = .ext_type, .lhs = target.int(), .rhs = @intFromEnum(t) };
            },
            .ctor => if (iface.findCtor(p.interner, name)) |c| {
                return .{ .tag = .ext_ctor, .lhs = target.int(), .rhs = @intFromEnum(c) };
            },
            .schema => if (iface.findSchema(p.interner, name)) |s| {
                return .{ .tag = .ext_schema_target, .lhs = target.int(), .rhs = @intFromEnum(s) };
            },
        }
        if (namespace == .type or namespace == .value or namespace == .ctor) {
            if (iface.findSchema(p.interner, name)) |si| {
                const code: diagnostic.Code = if (namespace == .type) .schema_used_as_type else .schema_used_as_value;
                try p.report(.{ .code = code, .module = m, .token = token, .name = name.toOptional(), .expected = iface.schemas[@intFromEnum(si)].params_len });
                return .poison(code);
            }
        }
        const code = p.whyMissing(target, name, namespace);
        var item: Item = .{
            .code = code,
            .module = m,
            .token = token,
            .name = name.toOptional(),
            .module_name = module_symbol.toOptional(),
        };
        if (code == .opaque_constructor) item.owner = p.owningTypeName(target, name).toOptional();
        try p.report(item);
        return .poison(code);
    }

    /// Why `name` is not in `target`'s interface. Answered from the target
    /// module's Bir, which the interface deliberately does not carry: the
    /// interface is what is PUBLIC, and telling "private" from "absent"
    /// needs what is not.
    fn whyMissing(p: *Pass, target: Graph.Index, name: Symbol, namespace: Namespace) diagnostic.Code {
        const bir = p.artifacts.bir(p.graph.moduleFile(target));
        switch (namespace) {
            .value => for (bir.decls) |d| {
                if (d.kind.isValue() and bir.symbol(d.name) == name) return .private_name;
            },
            .type => for (bir.decls) |d| {
                if (!d.kind.isValue() and bir.symbol(d.name) == name) return .private_name;
            },
            .ctor => for (bir.ctors) |c| {
                if (bir.symbol(c.name) != name) continue;
                const owner = bir.decl(c.decl);
                if (!owner.is_pub) return .private_name;
                // `pub opaque type T = A | B` exports `T` and hides `A`
                // and `B` (language.md §5.1).
                return if (owner.is_opaque) .opaque_constructor else .private_name;
            },
            .schema => for (bir.decls) |d| {
                if (d.kind == .schema and bir.symbol(d.name) == name) return .private_name;
            },
        }
        return .unknown_import_name;
    }

    fn owningTypeName(p: *Pass, target: Graph.Index, ctor: Symbol) Symbol {
        const bir = p.artifacts.bir(p.graph.moduleFile(target));
        for (bir.ctors) |c| {
            if (bir.symbol(c.name) == ctor) return bir.symbol(bir.decl(c.decl).name);
        }
        return ctor;
    }

    const SchemaPath = struct {
        source: SchemaSource,
        schema_name: Symbol,
        rest: []const u8,
    };

    fn resolveSchemaUse(
        p: *Pass,
        m: Graph.Index,
        bir: *const Bir,
        _: u32,
        whole: Symbol,
        namespace: Namespace,
        token: u32,
    ) Allocator.Error!Resolved {
        const text = p.interner.slice(whole);
        const first_dot = std.mem.indexOfScalar(u8, text, '.');
        const root_text = text[0 .. first_dot orelse text.len];
        const root = p.interner.find(root_text) orelse whole;
        const root_schema = p.schemaFromRoot(m, bir, root);
        const alias = p.importForQualified(bir, text);

        const root_valid = if (root_schema) |source|
            if (first_dot) |dot| p.schemaPathAccessExists(source, text[dot + 1 ..], namespace) else false
        else
            false;
        const alias_valid = if (alias) |imp| p.qualifiedImportAccessExists(m, imp, text, namespace) else false;

        if (root_valid and alias_valid) {
            const origin = p.schemaSourceOrigin(m, root_schema.?);
            try p.report(.{
                .code = .schema_name_collision,
                .module = m,
                .token = token,
                .name = root.toOptional(),
                .module_name = alias.?.module.toOptional(),
                .owner = p.schemaOrigin(m, root_schema.?).toOptional(),
                .schema_origin_module = origin.module,
                .schema_origin_token = origin.token,
                .alias_origin_module = m,
                .alias_origin_token = alias.?.token,
            });
            return .poison(.schema_name_collision);
        }

        var path: ?SchemaPath = null;
        if (root_schema) |source| {
            if (root_valid or alias == null or !alias_valid) path = .{
                .source = source,
                .schema_name = root,
                .rest = if (first_dot) |dot| text[dot + 1 ..] else "",
            };
        }
        if (path == null) {
            if (alias) |imp| {
                const tail = text[imp.alias_len + 1 ..];
                const dot = std.mem.indexOfScalar(u8, tail, '.') orelse
                    return p.resolveOrdinarySchemaFallback(m, bir, text, namespace, token);
                const schema_text = tail[0..dot];
                const schema_name = p.interner.find(schema_text) orelse
                    return p.resolveOrdinarySchemaFallback(m, bir, text, namespace, token);
                const target = p.graph.lookup(p.graph.modulePackage(m), imp.module) orelse
                    return p.resolveOne(m, imp.module, schema_name, .schema, token);
                if (target == m) {
                    if (p.localSchema(bir, schema_name)) |di| {
                        path = .{ .source = .{ .local = di }, .schema_name = schema_name, .rest = tail[dot + 1 ..] };
                    }
                } else if (p.interfaces[target.int()].findSchema(p.interner, schema_name)) |si| {
                    path = .{ .source = .{ .external = .{ .module = target, .schema = si } }, .schema_name = schema_name, .rest = tail[dot + 1 ..] };
                } else {
                    const code = p.whyMissing(target, schema_name, .schema);
                    try p.report(.{ .code = code, .module = m, .token = token, .name = schema_name.toOptional(), .module_name = imp.module.toOptional() });
                    return .poison(code);
                }
            }
        }

        const found = path orelse return p.resolveOrdinarySchemaFallback(m, bir, text, namespace, token);
        if (found.rest.len == 0) {
            const code: diagnostic.Code = if (namespace == .type) .schema_used_as_type else .schema_used_as_value;
            const arity: u32 = switch (found.source) {
                .local => |di| bir.decls[di].params,
                .external => |ext| p.interfaces[ext.module.int()].schemas[@intFromEnum(ext.schema)].params_len,
            };
            try p.report(.{ .code = code, .module = m, .token = token, .name = found.schema_name.toOptional(), .expected = arity });
            return .poison(code);
        }
        return switch (namespace) {
            .type => p.resolveSchemaTypeMember(m, found, token),
            .value => p.resolveSchemaValueMember(m, found, token),
            .ctor => p.resolveSchemaConstructor(m, bir, found, token),
            .schema => unreachable,
        };
    }

    const QualifiedImport = struct { module: Symbol, alias_len: usize, token: u32 };

    fn importForQualified(p: *const Pass, bir: *const Bir, text: []const u8) ?QualifiedImport {
        var best: ?QualifiedImport = null;
        for (bir.imports) |imp| {
            const alias = p.interner.slice(bir.symbol(imp.alias));
            if (alias.len >= text.len or text[alias.len] != '.' or !std.mem.startsWith(u8, text, alias)) continue;
            if (best == null or alias.len > best.?.alias_len) best = .{ .module = bir.symbol(imp.module), .alias_len = alias.len, .token = imp.name_token };
        }
        return best;
    }

    fn qualifiedImportAccessExists(p: *Pass, m: Graph.Index, imp: QualifiedImport, text: []const u8, namespace: Namespace) bool {
        const target = p.graph.lookup(p.graph.modulePackage(m), imp.module) orelse return false;
        const tail = text[imp.alias_len + 1 ..];
        const dot = std.mem.indexOfScalar(u8, tail, '.');
        if (dot == null) {
            const name = p.interner.find(tail) orelse return false;
            return p.ordinaryExists(target, name, namespace);
        }
        const schema_name = p.interner.find(tail[0..dot.?]) orelse return false;
        const schema = p.interfaces[target.int()].findSchema(p.interner, schema_name) orelse return false;
        return p.schemaPathAccessExists(.{ .external = .{ .module = target, .schema = schema } }, tail[dot.? + 1 ..], namespace);
    }

    fn schemaPathAccessExists(p: *Pass, source: SchemaSource, rest: []const u8, namespace: Namespace) bool {
        return switch (namespace) {
            .type => std.mem.eql(u8, rest, "Type") or std.mem.eql(u8, rest, "Encoded"),
            .value => if (schemaMemberKind(rest)) |kind| kind != .type and kind != .encoded else false,
            .ctor => blk: {
                var endpoint: Interface.SchemaCtor.Endpoint = .type;
                var variant = rest;
                if (std.mem.startsWith(u8, variant, "Encoded.")) {
                    endpoint = .encoded;
                    variant = variant["Encoded.".len..];
                }
                if (variant.len == 0 or std.mem.indexOfScalar(u8, variant, '.') != null) break :blk false;
                const name = p.interner.find(variant) orelse break :blk false;
                break :blk switch (source) {
                    .local => |di| localSchemaVariant(p.artifacts.bir(p.graph.moduleFile(p.current)), @enumFromInt(di), name) != null,
                    .external => |ext| p.interfaces[ext.module.int()].findSchemaCtor(ext.schema, endpoint, p.interner, name) != null,
                };
            },
            .schema => false,
        };
    }

    /// Two table probes (`Tables`): the module's own schema of that name,
    /// else the first `exposing` entry that names a schema of its module.
    fn schemaFromRoot(p: *Pass, m: Graph.Index, bir: *const Bir, name: Symbol) ?SchemaSource {
        std.debug.assert(m == p.current and bir == p.artifacts.bir(p.graph.moduleFile(m)));
        if (p.localSchema(bir, name)) |di| return .{ .local = di };
        const at = p.tables.exposed_schemas.first(name) orelse return null;
        return p.tables.exposed_sources.items[at];
    }

    /// Fill `tables` for module `m`, before any of its references is read.
    fn buildTables(p: *Pass, m: Graph.Index, bir: *const Bir) Allocator.Error!void {
        const t = &p.tables;
        t.clear();
        for (bir.decls, 0..) |d, i| {
            const name = bir.symbol(d.name);
            const index: u32 = @intCast(i);
            if (d.kind.isValue()) try t.values.add(p.gpa, name, index) else try t.types.add(p.gpa, name, index);
            if (d.kind == .schema) try t.schemas.add(p.gpa, name, index);
        }
        for (bir.ctors, 0..) |c, i| try t.ctors.add(p.gpa, bir.symbol(c.name), @intCast(i));
        const package = p.graph.modulePackage(m);
        for (bir.imports) |imp| {
            const exposed = bir.importExposed(imp);
            if (exposed.len == 0) continue;
            const target = p.graph.lookup(package, bir.symbol(imp.module)) orelse continue;
            for (exposed) |e| {
                const name = bir.symbol(e.name);
                const si = p.interfaces[target.int()].findSchema(p.interner, name) orelse continue;
                try t.exposed_schemas.add(p.gpa, name, @intCast(t.exposed_sources.items.len));
                try t.exposed_sources.append(p.gpa, .{ .external = .{ .module = target, .schema = si } });
            }
        }
        inline for (.{ &t.values, &t.types, &t.ctors, &t.schemas, &t.exposed_schemas }) |table| table.seal();
    }

    fn schemaOrigin(p: *const Pass, m: Graph.Index, source: SchemaSource) Symbol {
        return switch (source) {
            .local => p.graph.moduleName(m),
            .external => |ext| p.graph.moduleName(ext.module),
        };
    }

    const SourceOrigin = struct { module: Graph.Index, token: u32 };

    fn schemaSourceOrigin(p: *const Pass, m: Graph.Index, source: SchemaSource) SourceOrigin {
        return switch (source) {
            .local => |di| .{ .module = m, .token = p.artifacts.bir(p.graph.moduleFile(m)).decl(@enumFromInt(di)).name_token },
            .external => |ext| blk: {
                const bir = p.artifacts.bir(p.graph.moduleFile(ext.module));
                const schema_name = p.interfaces[ext.module.int()].schemas[@intFromEnum(ext.schema)].name;
                const name = p.interfaces[ext.module.int()].symbol(schema_name);
                for (bir.decls) |decl| if (decl.kind == .schema and bir.symbol(decl.name) == name)
                    break :blk .{ .module = ext.module, .token = decl.name_token };
                break :blk .{ .module = ext.module, .token = 0 };
            },
        };
    }

    /// The CURRENT module's schema declaration named `name` (`Tables`).
    fn localSchema(p: *Pass, bir: *const Bir, name: Symbol) ?u32 {
        std.debug.assert(bir == p.artifacts.bir(p.graph.moduleFile(p.current)));
        return p.tables.schemas.first(name);
    }

    fn resolveOrdinarySchemaFallback(p: *Pass, m: Graph.Index, bir: *const Bir, text: []const u8, namespace: Namespace, token: u32) Allocator.Error!Resolved {
        if (std.mem.lastIndexOfScalar(u8, text, '.')) |dot| {
            const module_text = text[0..dot];
            const name = p.interner.find(text[dot + 1 ..]) orelse unreachable;
            for (bir.imports) |imp| {
                if (std.mem.eql(u8, p.interner.slice(bir.symbol(imp.alias)), module_text))
                    return p.resolveOne(m, bir.symbol(imp.module), name, namespace, token);
            }
            for (prelude.modules) |well_known| {
                if (std.mem.eql(u8, @tagName(well_known), module_text))
                    return p.resolveOne(m, well_known.symbol(), name, namespace, token);
            }
            const module_name = p.interner.find(module_text);
            try p.report(.{ .code = .unknown_module_alias, .module = m, .token = token, .name = name.toOptional(), .module_name = if (module_name) |n| n.toOptional() else .none });
            return .poison(.unknown_module_alias);
        }
        const name = p.interner.find(text) orelse unreachable;
        for (bir.imports) |imp| for (bir.importExposed(imp)) |e| {
            if (bir.symbol(e.name) == name) return p.resolveOne(m, bir.symbol(imp.module), name, namespace, token);
        };
        return p.resolveSelf(m, name, namespace, token, name);
    }

    fn schemaMemberKind(text: []const u8) ?Interface.SchemaMember.Kind {
        const names = [_][]const u8{ "Type", "Encoded", "schema", "parse", "print", "parseWith", "printWith" };
        inline for (names, 0..) |name, i| if (std.mem.eql(u8, text, name)) return @enumFromInt(i);
        return null;
    }

    fn reportUnknownSchemaMember(p: *Pass, m: Graph.Index, path: SchemaPath, member: []const u8, token: u32, expected_kind: u32) Allocator.Error!Resolved {
        const available_start: u32 = @intCast(p.available_names.items.len);
        if (expected_kind == 3) switch (path.source) {
            .local => |di| {
                const root = p.artifacts.bir(p.graph.moduleFile(m)).decl(@enumFromInt(di)).schema_body.unwrap();
                if (root) |r| if (schemaTaggedInst(p.artifacts.bir(p.graph.moduleFile(m)), r)) |tagged| {
                    const local_bir = p.artifacts.bir(p.graph.moduleFile(m));
                    const variants = local_bir.extraSlice(local_bir.subRange(@enumFromInt(local_bir.instData(tagged).rhs)), Bir.Inst.Index);
                    for (variants) |vi| if (local_bir.instTag(vi) == .schema_variant)
                        try p.available_names.append(p.gpa, local_bir.symbol(@enumFromInt(local_bir.instData(vi).lhs)));
                };
            },
            .external => |ext| {
                const iface = &p.interfaces[ext.module.int()];
                const schema = iface.schemas[@intFromEnum(ext.schema)];
                for (iface.schema_ctors[schema.program_ctors_start..schema.program_ctors_end]) |ctor|
                    try p.available_names.append(p.gpa, iface.symbol(ctor.name));
            },
        };
        try p.report(.{
            .code = .unknown_schema_member,
            .module = m,
            .token = token,
            .name = (p.interner.find(member) orelse path.schema_name).toOptional(),
            .owner = path.schema_name.toOptional(),
            .expected = expected_kind,
            .available_start = available_start,
            .available_end = @intCast(p.available_names.items.len),
        });
        return .poison(.unknown_schema_member);
    }

    fn resolveSchemaTypeMember(p: *Pass, m: Graph.Index, path: SchemaPath, token: u32) Allocator.Error!Resolved {
        const kind = schemaMemberKind(path.rest) orelse return p.reportUnknownSchemaMember(m, path, path.rest, token, 1);
        if (kind != .type and kind != .encoded) return p.reportUnknownSchemaMember(m, path, path.rest, token, 1);
        return switch (path.source) {
            .local => |di| .{ .tag = .schema_type_top, .lhs = di, .rhs = @intFromEnum(kind) },
            .external => |ext| blk: {
                const name = p.interner.find(path.rest) orelse unreachable;
                const member = p.interfaces[ext.module.int()].findSchemaMember(ext.schema, p.interner, name, kind) orelse return p.reportUnknownSchemaMember(m, path, path.rest, token, 1);
                break :blk .{ .tag = .ext_schema_type, .lhs = ext.module.int(), .rhs = @intFromEnum(member) };
            },
        };
    }

    fn resolveSchemaValueMember(p: *Pass, m: Graph.Index, path: SchemaPath, token: u32) Allocator.Error!Resolved {
        const kind = schemaMemberKind(path.rest) orelse return p.reportUnknownSchemaMember(m, path, path.rest, token, 2);
        if (kind == .type or kind == .encoded) return p.reportUnknownSchemaMember(m, path, path.rest, token, 2);
        return switch (path.source) {
            .local => |di| .{ .tag = .schema_member_top, .lhs = di, .rhs = @intFromEnum(kind) },
            .external => |ext| blk: {
                const name = p.interner.find(path.rest) orelse unreachable;
                const member = p.interfaces[ext.module.int()].findSchemaMember(ext.schema, p.interner, name, kind) orelse return p.reportUnknownSchemaMember(m, path, path.rest, token, 2);
                break :blk .{ .tag = .ext_schema_member, .lhs = ext.module.int(), .rhs = @intFromEnum(member) };
            },
        };
    }

    fn resolveSchemaConstructor(p: *Pass, m: Graph.Index, bir: *const Bir, path: SchemaPath, token: u32) Allocator.Error!Resolved {
        var endpoint: Interface.SchemaCtor.Endpoint = .type;
        var variant_text = path.rest;
        if (std.mem.startsWith(u8, variant_text, "Encoded.")) {
            endpoint = .encoded;
            variant_text = variant_text["Encoded.".len..];
        }
        if (variant_text.len == 0 or std.mem.indexOfScalar(u8, variant_text, '.') != null)
            return p.reportUnknownSchemaMember(m, path, variant_text, token, 3);
        const variant_name = p.interner.find(variant_text) orelse return p.reportUnknownSchemaMember(m, path, variant_text, token, 3);
        return switch (path.source) {
            .local => |di| blk: {
                const variant = localSchemaVariant(bir, @enumFromInt(di), variant_name) orelse return p.reportUnknownSchemaMember(m, path, variant_text, token, 3);
                break :blk .{ .tag = .schema_ctor_top, .lhs = di, .rhs = Bir.SchemaCtorRef.pack(.{ .variant = @intCast(variant), .encoded = endpoint == .encoded }) };
            },
            .external => |ext| blk: {
                const ctor = p.interfaces[ext.module.int()].findSchemaCtor(ext.schema, endpoint, p.interner, variant_name) orelse return p.reportUnknownSchemaMember(m, path, variant_text, token, 3);
                break :blk .{ .tag = .ext_schema_ctor, .lhs = ext.module.int(), .rhs = @intFromEnum(ctor) };
            },
        };
    }

    fn localSchemaVariant(bir: *const Bir, decl_index: Bir.DeclIndex, name: Symbol) ?u32 {
        const root = bir.decl(decl_index).schema_body.unwrap() orelse return null;
        var at = root;
        var budget = bir.insts.len + 1;
        while (budget > 0) : (budget -= 1) switch (bir.instTag(at)) {
            .schema_value, .schema_paren => at = @enumFromInt(bir.instData(at).lhs),
            .schema_tagged => {
                const variants = bir.extraSlice(bir.subRange(@enumFromInt(bir.instData(at).rhs)), Bir.Inst.Index);
                for (variants, 0..) |vi, i| if (bir.symbol(@enumFromInt(bir.instData(vi).lhs)) == name) return @intCast(i);
                return null;
            },
            else => return null,
        };
        return null;
    }

    fn schemaTaggedInst(bir: *const Bir, root: Bir.Inst.Index) ?Bir.Inst.Index {
        var at = root;
        var budget = bir.insts.len + 1;
        while (budget > 0) : (budget -= 1) switch (bir.instTag(at)) {
            .schema_value, .schema_paren => at = @enumFromInt(bir.instData(at).lhs),
            .schema_tagged => return at,
            else => return null,
        };
        return null;
    }

    fn resolveSchemaOperand(p: *Pass, m: Graph.Index, bir: *const Bir, decl_i: u32, name: Symbol, token: u32) Allocator.Error!Resolved {
        for (bir.declTypeParams(bir.decls[decl_i]), 0..) |param, i| {
            if (param == name) return .{ .tag = .schema_parameter, .lhs = @intCast(i), .rhs = 0 };
        }
        const text = p.interner.slice(name);
        const primitive: ?Bir.SchemaPrimitive = if (std.mem.eql(u8, text, "String")) .string else if (std.mem.eql(u8, text, "Bool")) .bool else if (std.mem.eql(u8, text, "Int")) .int else if (std.mem.eql(u8, text, "Float")) .float else if (std.mem.eql(u8, text, "FiniteFloat")) .finite_float else if (std.mem.eql(u8, text, "Null")) .null else if (std.mem.eql(u8, text, "Value")) .value else if (std.mem.eql(u8, text, "List")) .list else null;
        if (primitive) |kind| return .{ .tag = .schema_primitive, .lhs = @intFromEnum(kind), .rhs = 0 };
        if (p.schemaFromRoot(m, bir, name)) |source| return switch (source) {
            .local => |di| .{ .tag = .schema_target_top, .lhs = di, .rhs = 0 },
            .external => |ext| .{ .tag = .ext_schema_target, .lhs = ext.module.int(), .rhs = @intFromEnum(ext.schema) },
        };
        if (std.mem.lastIndexOfScalar(u8, text, '.')) |dot| {
            const module_text = text[0..dot];
            const schema_name = p.interner.find(text[dot + 1 ..]) orelse name;
            for (bir.imports) |imp| if (std.mem.eql(u8, p.interner.slice(bir.symbol(imp.alias)), module_text)) {
                const module_symbol = bir.symbol(imp.module);
                if (p.graph.lookup(p.graph.modulePackage(m), module_symbol)) |target| {
                    if (target != m) {
                        const iface = &p.interfaces[target.int()];
                        if (iface.findSchema(p.interner, schema_name) == null and
                            (iface.findType(p.interner, schema_name) != null or iface.findValue(p.interner, schema_name) != null))
                        {
                            try p.report(.{ .code = .expected_schema, .module = m, .token = token, .name = schema_name.toOptional(), .module_name = module_symbol.toOptional(), .found = if (iface.findType(p.interner, schema_name) != null) 1 else 2 });
                            return .poison(.expected_schema);
                        }
                    }
                }
                return p.resolveOne(m, module_symbol, schema_name, .schema, token);
            };
        }
        try p.report(.{ .code = .expected_schema, .module = m, .token = token, .name = name.toOptional(), .found = p.ordinaryNameKind(m, bir, name) });
        return .poison(.expected_schema);
    }

    fn ordinaryNameKind(p: *Pass, m: Graph.Index, bir: *const Bir, name: Symbol) u32 {
        for (bir.decls) |d| {
            if (bir.symbol(d.name) != name or d.kind == .schema) continue;
            return if (d.kind.isValue()) 2 else 1;
        }
        for (bir.imports) |imp| for (bir.importExposed(imp)) |e| {
            if (bir.symbol(e.name) != name) continue;
            const target = p.graph.lookup(p.graph.modulePackage(m), bir.symbol(imp.module)) orelse continue;
            const iface = &p.interfaces[target.int()];
            if (iface.findType(p.interner, name) != null) return 1;
            if (iface.findValue(p.interner, name) != null) return 2;
        };
        return 0;
    }

    fn resolveSchemaExpr(p: *Pass, m: Graph.Index, _: *const Bir, name: Symbol, token: u32) Allocator.Error!Resolved {
        const text = p.interner.slice(name);
        const namespace: Namespace = if (text.len > 0 and std.ascii.isUpper(text[0])) .ctor else .value;
        return p.resolveSelf(m, name, namespace, token, name);
    }

    // ---- Type arity ------------------------------------------------------

    /// Every type reference must supply exactly the parameters its
    /// declaration takes (checker.md Appendix A). Applications are found
    /// first, so a bare reference — one that is nobody's `type_app` head —
    /// is an application of zero arguments.
    fn checkTypeArity(p: *Pass, bir: *const Bir) Allocator.Error!void {
        if (p.quiet or bir.insts.len == 0) return;
        const tags = bir.insts.items(.tag);
        const data = bir.insts.items(.data);
        const tokens = bir.insts.items(.main_token);
        const applied = try p.scratch.alloc(u32, bir.insts.len);
        defer p.scratch.free(applied);
        @memset(applied, 0);
        for (tags, data) |tag, d| {
            if (tag != .type_app) continue;
            applied[d.lhs] = bir.subRange(@enumFromInt(d.rhs)).len();
        }
        for (tags, data, tokens, applied) |tag, d, token, found| {
            const expected: u32, const name: Symbol = switch (tag) {
                .type_top => .{ bir.decl(@enumFromInt(d.lhs)).params, bir.symbol(bir.decl(@enumFromInt(d.lhs)).name) },
                .ext_type => blk: {
                    const iface = &p.interfaces[d.lhs];
                    const t = iface.types[d.rhs];
                    break :blk .{ t.arity, iface.symbol(t.name) };
                },
                .schema_type_top => .{ bir.decl(@enumFromInt(d.lhs)).params, bir.symbol(bir.decl(@enumFromInt(d.lhs)).name) },
                .ext_schema_type => blk: {
                    const iface = &p.interfaces[d.lhs];
                    const member = iface.schema_members[d.rhs];
                    break :blk .{ member.arity, iface.symbol(member.name) };
                },
                else => continue,
            };
            if (expected == found) continue;
            try p.report(.{
                .code = .wrong_type_arity,
                .module = p.current,
                .token = token,
                .name = name.toOptional(),
                .expected = expected,
                .found = found,
            });
        }
    }

    // ---- Recursive aliases ----------------------------------------------

    /// An alias that can reach itself through alias references inside its
    /// body. One report per cycle, on the alias the cycle CLOSES on; the
    /// rest of the cycle is marked done so a loop of three aliases is one
    /// message and not three.
    ///
    /// Blaming the node the back-edge closes on is what makes the message
    /// true. Attributing it to the depth-first ROOT instead reported
    /// `A refers to itself` for `type alias A = B`, `B = C`, `C = B` — `A`
    /// does not refer to itself, `B` and `C` do — and the aliases that
    /// actually were recursive got no message at all, because the walk had
    /// already marked them finished.
    fn checkRecursiveAliases(p: *Pass, bir: *const Bir) Allocator.Error!void {
        if (p.quiet or bir.decls.len == 0) return;
        var any = false;
        for (bir.decls) |d| {
            if (d.kind == .type_alias) any = true;
        }
        if (!any) return;

        const state = try p.scratch.alloc(u8, bir.decls.len);
        defer p.scratch.free(state);
        @memset(state, 0); // 0 unvisited, 1 on the current path, 2 finished
        for (bir.decls, 0..) |d, i| {
            if (d.kind != .type_alias or state[i] != 0) continue;
            const closes_on = try p.aliasReaches(bir, state, @intCast(i)) orelse continue;
            const culprit = bir.decl(@enumFromInt(closes_on));
            try p.report(.{
                .code = .recursive_alias,
                .module = p.current,
                .token = culprit.name_token,
                .name = bir.symbol(culprit.name).toOptional(),
            });
        }
    }

    /// Depth-first over `type_top` references inside alias bodies. Returns
    /// the declaration the first back-edge closed on — a member of the
    /// cycle, and therefore an alias that really does refer to itself —
    /// or null when nothing on the path was reached again.
    ///
    /// The walk continues past the first back-edge rather than returning
    /// there: every node it put on the path has to come back off it, or a
    /// later root would read a stale `1` as "on my path" and invent a cycle.
    ///
    /// Recursion depth is the number of aliases in one module, which the
    /// parser's nesting limit does not bound — so this is iterative. The
    /// cursor per frame is what keeps it linear in the bodies it scans:
    /// restarting each frame's scan at `inst_start` would re-read the body
    /// once per child.
    fn aliasReaches(p: *Pass, bir: *const Bir, state: []u8, start: u32) Allocator.Error!?u32 {
        const tags = bir.insts.items(.tag);
        const data = bir.insts.items(.data);
        const Frame = struct { decl: u32, cursor: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(p.scratch);
        try stack.append(p.scratch, .{ .decl = start, .cursor = bir.decls[start].inst_start.int() });
        state[start] = 1;
        var found: ?u32 = null;
        while (stack.items.len > 0) {
            const frame = &stack.items[stack.items.len - 1];
            const d = bir.decls[frame.decl];
            var descended = false;
            while (frame.cursor < d.inst_end.int()) {
                const i = frame.cursor;
                frame.cursor += 1;
                if (tags[i] != .type_top) continue;
                const target = data[i].lhs;
                if (target >= bir.decls.len) continue;
                if (bir.decls[target].kind != .type_alias) continue;
                if (state[target] == 1) {
                    if (found == null) found = target;
                    continue;
                }
                if (state[target] != 0) continue;
                state[target] = 1;
                try stack.append(p.scratch, .{ .decl = target, .cursor = bir.decls[target].inst_start.int() });
                descended = true;
                break;
            }
            if (descended) continue;
            state[frame.decl] = 2;
            _ = stack.pop();
        }
        return found;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestProject = @import("TestProject.zig");

/// The codes a two-module project produces, `Util` first. `Main` is the
/// importer in every scenario below.
///
/// The sources name nothing from the prelude: `TestProject` runs with the
/// core package switched off, so an `Int` here would be three
/// `unknown_module_alias` items drowning the one code the scenario is
/// about. What core does for real names is the black-box suite's job.
fn expectCodes(expected: []const diagnostic.Code, util: [:0]const u8, main: [:0]const u8) !void {
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "Main.beni", .source = main },
        .{ .path = "Util.beni", .source = util },
    });
    defer p.deinit();
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, expected, codes);
}

test "a value, a type and a constructor of another module all resolve" {
    try expectCodes(&.{},
        \\pub type Colour
        \\    = Red
        \\    | Green
        \\
        \\
        \\pub name : Colour -> Colour
        \\name c =
        \\    c
        \\
    ,
        \\import Util exposing (Colour, Red, name)
        \\
        \\
        \\pub mine : Colour
        \\mine =
        \\    name (Util.Green)
        \\
    );
}

test "a name the module does not declare is unknown_import_name, exposed or used" {
    try expectCodes(&.{ .unknown_import_name, .unknown_import_name },
        \\pub present =
        \\    1
        \\
    ,
        \\import Util exposing (absent)
        \\
        \\
        \\pub mine =
        \\    Util.alsoAbsent
        \\
    );
}

test "a name declared without pub is private_name, which is not the same message" {
    try expectCodes(&.{ .private_name, .private_name },
        \\secret =
        \\    1
        \\
    ,
        \\import Util exposing (secret)
        \\
        \\
        \\pub mine =
        \\    Util.secret
        \\
    );
}

test "an opaque type exposes its name and refuses its constructors" {
    try expectCodes(&.{.opaque_constructor},
        \\pub opaque type Token
        \\    = Token
        \\
    ,
        \\import Util exposing (Token)
        \\
        \\
        \\pub mine : Token
        \\mine =
        \\    Util.Token
        \\
    );
}

test "a type constructor must be fully applied, in both directions" {
    try expectCodes(&.{ .wrong_type_arity, .wrong_type_arity },
        \\pub type Box a
        \\    = Box a
        \\
        \\
        \\pub type Plain
        \\    = Plain
        \\
    ,
        \\import Util exposing (Box, Plain)
        \\
        \\
        \\pub tooFew : Box
        \\tooFew =
        \\    tooFew
        \\
        \\
        \\pub tooMany : Plain Plain
        \\tooMany =
        \\    tooMany
        \\
    );
}

test "an alias that reaches itself is one recursive_alias per cycle" {
    // Three aliases in one ring plus one that names itself: two cycles,
    // two diagnostics — not four, and not one per edge.
    var p = try TestProject.init(testing.allocator, &.{.{
        .path = "M.beni",
        .source =
        \\pub type alias Self =
        \\    Self
        \\
        \\
        \\pub type alias A =
        \\    B
        \\
        \\
        \\pub type alias B =
        \\    C
        \\
        \\
        \\pub type alias C =
        \\    A
        \\
        \\
        \\pub type alias Fine =
        \\    Self
        \\
        ,
    }});
    defer p.deinit();
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, &.{ .recursive_alias, .recursive_alias }, codes);
    try testing.expectEqual(@as(u32, 1), p.session.diagnostics.items[0].span.start.line);
    try testing.expectEqual(@as(u32, 5), p.session.diagnostics.items[1].span.start.line);
}

test "a qualified name whose module does not exist is unknown_module_alias" {
    // Lowering accepts `Char.toUpper` because `Char` is a prelude module
    // alias (language.md Appendix A) — whether that module EXISTS is the
    // graph's to know, and here the core package is switched off.
    var p = try TestProject.init(testing.allocator, &.{.{
        .path = "M.beni",
        .source = "pub shout : String -> String\nshout s =\n    Char.toUpper s\n",
    }});
    defer p.deinit();
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    // `String` is a prelude type from `Basics`, which is equally missing.
    try testing.expectEqualSlices(diagnostic.Code, &.{
        .unknown_module_alias,
        .unknown_module_alias,
        .unknown_module_alias,
    }, codes);
}

test "a poisoned module reports its cycle and nothing else" {
    // `Main` is in a cycle AND names something `Util` does not have. The
    // cycle is the cause; the rest is noise, and §4.3 says a cycle member
    // produces no further diagnostics.
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "Main.beni", .source = "import Util exposing (absent)\n\n\npub mine =\n    1\n" },
        .{ .path = "Util.beni", .source = "import Main exposing (mine)\n\n\npub present =\n    mine\n" },
    });
    defer p.deinit();
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, &.{.import_cycle}, codes);
}

test "every reference is rewritten: no unresolved form survives the pass" {
    // The whole point of §4.5. After resolution the four `(module symbol,
    // name symbol)` tags must not appear anywhere, in ANY module — a name
    // is looked up once and never again.
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "Main.beni", .source = "import Util exposing (Colour, Red)\n\n\npub mine : Colour\nmine =\n    Util.Red\n" },
        .{ .path = "Util.beni", .source = "pub type Colour\n    = Red\n" },
    });
    defer p.deinit();
    for (0..p.session.store.count()) |i| {
        const bir = p.session.artifacts.bir(@enumFromInt(i));
        for (bir.insts.items(.tag)) |tag| try testing.expect(!tag.isUnresolved());
    }
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, &.{}, codes);
}

test "a module's own names resolve to its own declarations, not through an interface" {
    // `Basics` refers to `Basics.add` through the `+` desugaring and to
    // `Basics.Int` through the prelude. Both are itself, so both become
    // `top`/`type_top` — and a PRIVATE one resolves too, because the
    // module is not importing anything from itself.
    var p = try TestProject.init(testing.allocator, &.{.{
        .path = "Basics.beni",
        .package = .core,
        .source =
        \\pub foreign type Int
        \\
        \\
        \\foreign add : Int -> Int -> Int
        \\
        \\
        \\pub twice : Int -> Int
        \\twice n =
        \\    n + n
        \\
        ,
    }});
    defer p.deinit();
    const codes = try p.codes(testing.allocator);
    defer testing.allocator.free(codes);
    try testing.expectEqualSlices(diagnostic.Code, &.{}, codes);

    const bir = p.session.artifacts.bir(@enumFromInt(0));
    var tops: u32 = 0;
    for (bir.insts.items(.tag)) |tag| {
        if (tag == .top or tag == .type_top) tops += 1;
        try testing.expect(tag != .ext_value and tag != .ext_type and tag != .ext_ctor);
    }
    try testing.expect(tops > 0);
}

// ---- Stress and fuzz --------------------------------------------------------

/// Run the graph and the resolver over an arbitrary pair of modules, and
/// assert the ONE invariant that must hold whatever the input: no
/// unresolved reference survives, and every rewritten pair is in bounds of
/// the tables it names. A panic or an out-of-bounds index here is a bug
/// reachable from user source, which the house rules forbid.
fn checkArbitrary(a: [:0]const u8, b: [:0]const u8) !void {
    var p = try TestProject.init(testing.allocator, &.{
        .{ .path = "A.beni", .source = a },
        .{ .path = "B.beni", .source = b },
    });
    defer p.deinit();
    for (0..p.session.store.count()) |i| {
        const file: SourceStore.Index = @enumFromInt(i);
        const bir = p.session.artifacts.bir(file);
        for (bir.insts.items(.tag), bir.insts.items(.data)) |tag, d| {
            try testing.expect(!tag.isUnresolved());
            switch (tag) {
                .ext_value => {
                    try testing.expect(d.lhs < p.session.resolution.interfaces.len);
                    try testing.expect(d.rhs < p.session.resolution.interfaces[d.lhs].values.len);
                },
                .ext_type => {
                    try testing.expect(d.lhs < p.session.resolution.interfaces.len);
                    try testing.expect(d.rhs < p.session.resolution.interfaces[d.lhs].types.len);
                },
                .ext_ctor => {
                    try testing.expect(d.lhs < p.session.resolution.interfaces.len);
                    try testing.expect(d.rhs < p.session.resolution.interfaces[d.lhs].ctors.len);
                },
                .ext_schema_member, .ext_schema_type => {
                    try testing.expect(d.lhs < p.session.resolution.interfaces.len);
                    try testing.expect(d.rhs < p.session.resolution.interfaces[d.lhs].schema_members.len);
                },
                .ext_schema_ctor => {
                    try testing.expect(d.lhs < p.session.resolution.interfaces.len);
                    try testing.expect(d.rhs < p.session.resolution.interfaces[d.lhs].schema_ctors.len);
                },
                .ext_schema_target => {
                    try testing.expect(d.lhs < p.session.resolution.interfaces.len);
                    try testing.expect(d.rhs < p.session.resolution.interfaces[d.lhs].schemas.len);
                },
                .top, .type_top, .schema_member_top, .schema_type_top, .schema_ctor_top, .schema_target_top => try testing.expect(d.lhs < bir.decls.len),
                .ctor => try testing.expect(d.lhs < bir.ctors.len),
                else => {},
            }
        }
    }
}

test "every corpus fixture resolves, against itself and against another, without a panic" {
    const corpus = @import("corpus_bir");
    for (corpus.fixtures, 0..) |fixture, i| {
        const other = corpus.fixtures[(i + 1) % corpus.fixtures.len];
        checkArbitrary(fixture.source, other.source) catch |err| {
            std.debug.print("fixtures {s} + {s}: {t}\n", .{ fixture.name, other.name, err });
            return err;
        };
    }
}

test "fuzz: arbitrary bytes as two modules never panic and always resolve in bounds" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.sliceWithHash(buf[0 .. buf.len - 1], 0x2E501);
            buf[len] = 0;
            const source = buf[0..len :0];
            try checkArbitrary(source, source);
        }
    }.testOne, .{ .corpus = &.{
        "import B exposing (b)\nx = b\n",
        "import A\ny = A.x\n",
        "pub type alias T = T\n",
        "pub opaque type O = O\nx = O\n",
        "pub type P a = P a\nq : P\n",
    } });
}

// PRNG-driven stand-in for the fuzzer (the toolchain's fuzz mode does not
// build on 0.16.0), mirroring `Lower`'s: corpus fixtures with lines
// dropped, duplicated and swapped, PAIRED so cross-module resolution —
// imports, cycles, interfaces — is what gets the mutated input.
// Opt-in (`zig build fuzz`, `fuzzing.zig`); the gates resolve every
// fixture as written, above. `BENI_STRESS_ITERATIONS` raises the count.
test "stress: mutated corpus fixtures resolve in pairs without a panic" {
    try @import("../fuzzing.zig").skipUnlessFuzzing();
    var iterations: usize = 200;
    if (testing.environ.getAlloc(testing.allocator, "BENI_STRESS_ITERATIONS")) |value| {
        defer testing.allocator.free(value);
        iterations = std.fmt.parseInt(usize, value, 10) catch iterations;
    } else |_| {}

    const corpus = @import("corpus_bir");
    var prng: std.Random.DefaultPrng = .init(0x2E501);
    const random = prng.random();
    var sources: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&sources) |*s| s.deinit(testing.allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(testing.allocator);

    for (0..iterations) |_| {
        for (&sources) |*out| {
            const fixture = corpus.fixtures[random.uintLessThan(usize, corpus.fixtures.len)];
            lines.clearRetainingCapacity();
            // Half the time, prepend an import of the other module, so the
            // pair really is a graph and not two islands.
            if (random.boolean()) try lines.append(testing.allocator, "import A exposing (x)");
            if (random.boolean()) try lines.append(testing.allocator, "import B");
            var it = std.mem.splitScalar(u8, fixture.source, '\n');
            while (it.next()) |line| try lines.append(testing.allocator, line);
            for (0..1 + random.uintLessThan(usize, 4)) |_| {
                if (lines.items.len < 2) break;
                const i = random.uintLessThan(usize, lines.items.len);
                switch (random.uintLessThan(u8, 3)) {
                    0 => _ = lines.orderedRemove(i),
                    1 => try lines.insert(testing.allocator, i, lines.items[random.uintLessThan(usize, lines.items.len)]),
                    else => {
                        const j = random.uintLessThan(usize, lines.items.len);
                        std.mem.swap([]const u8, &lines.items[i], &lines.items[j]);
                    },
                }
            }
            out.clearRetainingCapacity();
            for (lines.items) |line| {
                try out.appendSlice(testing.allocator, line);
                try out.append(testing.allocator, '\n');
            }
            try out.append(testing.allocator, 0);
        }
        const a = sources[0].items[0 .. sources[0].items.len - 1 :0];
        const b = sources[1].items[0 .. sources[1].items.len - 1 :0];
        checkArbitrary(a, b) catch |err| {
            std.debug.print("mutated pair failed ({t}):\n--- A ---\n{s}\n--- B ---\n{s}\n", .{ err, a, b });
            return err;
        };
    }
}
