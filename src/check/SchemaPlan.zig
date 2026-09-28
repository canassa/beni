//! The resolved, immutable schema plan passed from checking to emission
//! (`docs/design/schema.md` §4/A.6). It contains no `TypeStore` variables and
//! no pointers into checker arenas: every edge is an index into an owned flat
//! table, and conversion target types use the interface term language.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");
const Interface = @import("../resolve/Interface.zig");
const Graph = @import("../resolve/Graph.zig");
const Types = @import("Types.zig");

const SchemaPlan = @This();

pub const Symbol = InternPool.Symbol;

definitions: []const Definition,
nodes: std.MultiArrayList(Node).Slice,
fields: []const Field,
variants: []const Variant,
conversions: []const Conversion,
checks: []const Check,
annotations: []const Annotation,
extra: []const u32,
terms: std.MultiArrayList(Interface.Term).Slice,
type_extra: []const u32,
type_refs: []const Interface.TypeRef,
literal_bytes: []const u8,
literals: []const Literal,
symbols: []const Symbol,
schema_targets: []const SchemaTarget,
ctor_targets: []const CtorTarget,

pub const empty: SchemaPlan = .{
    .definitions = &.{},
    .nodes = .empty,
    .fields = &.{},
    .variants = &.{},
    .conversions = &.{},
    .checks = &.{},
    .annotations = &.{},
    .extra = &.{},
    .terms = .empty,
    .type_extra = &.{},
    .type_refs = &.{},
    .literal_bytes = &.{},
    .literals = &.{},
    .symbols = &.{},
    .schema_targets = &.{},
    .ctor_targets = &.{},
};

pub fn deinit(plan: *SchemaPlan, gpa: Allocator) void {
    gpa.free(plan.definitions);
    plan.nodes.deinit(gpa);
    gpa.free(plan.fields);
    gpa.free(plan.variants);
    gpa.free(plan.conversions);
    gpa.free(plan.checks);
    gpa.free(plan.annotations);
    gpa.free(plan.extra);
    plan.terms.deinit(gpa);
    gpa.free(plan.type_extra);
    gpa.free(plan.type_refs);
    gpa.free(plan.literal_bytes);
    gpa.free(plan.literals);
    gpa.free(plan.symbols);
    gpa.free(plan.schema_targets);
    gpa.free(plan.ctor_targets);
    plan.* = empty;
}

// Kept as distinct enums rather than a generic alias so accidental cross-table
// indexing is a compile error and their optional sentinels stay explicit.
pub const SymbolIndex = Interface.SymbolIndex;
pub const DefinitionIndex = enum(u32) { _ };
pub const NodeIndex = enum(u32) {
    _,
    pub fn toOptional(i: NodeIndex) Optional {
        return @enumFromInt(@intFromEnum(i));
    }
    pub const Optional = enum(u32) {
        none = std.math.maxInt(u32),
        _,
        pub fn unwrap(i: Optional) ?NodeIndex {
            return if (i == .none) null else @enumFromInt(@intFromEnum(i));
        }
    };
};
pub const FieldIndex = enum(u32) { _ };
pub const VariantIndex = enum(u32) { _ };
pub const ConversionIndex = enum(u32) { _ };
pub const CheckIndex = enum(u32) { _ };
pub const AnnotationIndex = enum(u32) { _ };
pub const LiteralIndex = enum(u32) {
    _,
    pub const Optional = enum(u32) { none = std.math.maxInt(u32), _ };
};
pub const SchemaTargetIndex = enum(u32) { _ };
pub const CtorTargetIndex = enum(u32) { _ };
pub const TypeRefIndex = enum(u32) { _ };

pub const Definition = struct {
    name: SymbolIndex,
    decl: Bir.DeclIndex,
    params_start: u32,
    params_end: u32,
    root: NodeIndex,
    type_ref: TypeRefIndex,
    encoded_ref: TypeRefIndex,
    program_term: Interface.TermIndex,
    encoded_term: Interface.TermIndex,
    token: u32,
    program_properties: u8,
    encoded_properties: u8,
};

pub const Node = struct {
    tag: Tag,
    lhs: u32,
    rhs: u32,
    token: u32,

    pub const Tag = enum(u8) {
        parameter,
        primitive,
        reference,
        record,
        list,
        tagged,
        conversion,
        check,
        annotation,
        nullable,
    };
};

pub const Primitive = enum(u8) {
    string,
    bool,
    int,
    float,
    finite_float,
    null,
    value,
};

pub const Field = struct {
    name: SymbolIndex,
    external: LiteralIndex,
    child: NodeIndex,
    optional: bool,
    token: u32,
};

pub const Variant = struct {
    name: SymbolIndex,
    external: LiteralIndex,
    payload: NodeIndex.Optional,
    program_ctor: CtorTargetIndex,
    encoded_ctor: CtorTargetIndex,
    token: u32,
};

pub const Conversion = struct {
    expr: Bir.Inst.Index,
    target_term: Interface.TermIndex,
    token: u32,
    opaque_target: bool,
    opaque_checks: bool,
};

pub const Check = struct {
    endpoint: Endpoint,
    kind: Kind,
    order: u32,
    call: Bir.Inst.OptionalIndex,
    metadata: LiteralIndex.Optional,
    token: u32,

    pub const Kind = enum(u8) { executable, @"opaque" };
};

pub const Annotation = struct {
    side: Side,
    target_kind: TargetKind,
    target: u32,
    key: LiteralIndex.Optional,
    value: LiteralIndex.Optional,
    token: u32,

    pub const Side = enum(u8) { program, encoded, both };
    pub const TargetKind = enum(u8) { node, field };
};

pub const Endpoint = enum(u8) { type, encoded };

pub const Literal = struct { start: u32, len: u32 };

pub const SchemaTarget = struct {
    package: SourceStore.Package,
    module: SymbolIndex,
    schema: SymbolIndex,
};

pub const CtorTarget = struct {
    schema: SchemaTargetIndex,
    variant: SymbolIndex,
    endpoint: Endpoint,
};

pub fn literal(plan: *const SchemaPlan, index: LiteralIndex) ?[]const u8 {
    const i = @intFromEnum(index);
    if (i >= plan.literals.len) return null;
    const l = plan.literals[i];
    const end = @as(u64, l.start) + l.len;
    if (end > plan.literal_bytes.len) return null;
    return plan.literal_bytes[l.start..][0..l.len];
}

/// Validate the source-relative indices that the byte decoder cannot check
/// without this module's front-end artifact. Cache installation runs this
/// before exposing a plan; failure is a miss, never a diagnostic.
pub fn verifyAgainstBir(plan: *const SchemaPlan, bir: *const Bir, token_count: u32) bool {
    var definition_i: usize = 0;
    for (bir.decls, 0..) |declaration, decl_i| {
        if (declaration.kind != .schema) continue;
        if (definition_i >= plan.definitions.len) return false;
        const d = plan.definitions[definition_i];
        definition_i += 1;
        if (@intFromEnum(d.decl) != decl_i) return false;
        if (@intFromEnum(d.decl) >= bir.decls.len or d.token >= token_count) return false;
        if (declaration.kind != .schema or declaration.name_token != d.token) return false;
        if (bir.symbol(declaration.name) != plan.symbols[@intFromEnum(d.name)]) return false;
        if (declaration.params != d.params_end - d.params_start) return false;
    }
    if (definition_i != plan.definitions.len) return false;
    if (plan.nodes.len != 0) for (plan.nodes.items(.token)) |token| {
        if (token >= token_count) return false;
    };
    for (plan.fields) |f| if (f.token >= token_count) return false;
    for (plan.variants) |v| if (v.token >= token_count) return false;
    for (plan.conversions) |c| {
        if (@intFromEnum(c.expr) >= bir.insts.len or c.token >= token_count) return false;
        if (!instInSchemaDecl(bir, c.expr)) return false;
    }
    for (plan.checks) |c| {
        if (c.token >= token_count) return false;
        if (c.call != .none and @intFromEnum(c.call) >= bir.insts.len) return false;
    }
    for (plan.annotations) |a| if (a.token >= token_count) return false;
    return true;
}

fn instInSchemaDecl(bir: *const Bir, inst: Bir.Inst.Index) bool {
    for (bir.decls) |declaration| {
        if (declaration.kind != .schema) continue;
        if (inst.int() >= declaration.inst_start.int() and inst.int() < declaration.inst_end.int()) return true;
    }
    return false;
}

/// Resolve every stable cross-module schema/constructor target against the
/// installed graph and interfaces. The plan keeps names on disk; a cache hit
/// accepts them only when they still denote the exact namespace family.
pub fn verifyTargets(
    plan: *const SchemaPlan,
    current: Graph.Index,
    bir: *const Bir,
    graph: *const Graph,
    interfaces: []const Interface,
    interner: *const InternPool.Global,
    types: *const Types,
) bool {
    const current_module = graph.moduleName(current);
    const current_package = graph.modulePackage(current);
    for (plan.definitions) |definition| {
        const declaration = bir.decl(definition.decl);
        const root = declaration.schema_body.unwrap() orelse return false;
        const tagged = findTagged(bir, root) != null;
        if (!definitionHasStableIdentity(
            plan,
            definition,
            current_package,
            current_module,
            bir.symbol(declaration.name),
            tagged,
            interner,
        )) return false;
        if (types.find(graph, current_package, current_module, plan.symbols[@intFromEnum(plan.type_refs[@intFromEnum(definition.type_ref)].name)]) !=
            types.ofSchemaDecl(current, definition.decl, .type)) return false;
        if (types.find(graph, current_package, current_module, plan.symbols[@intFromEnum(plan.type_refs[@intFromEnum(definition.encoded_ref)].name)]) !=
            types.ofSchemaDecl(current, definition.decl, .encoded)) return false;
    }
    // Conversion target terms may name ordinary private types as well as
    // schema endpoints. They are stable names on disk, but a resolved plan
    // may not carry a name which this session cannot resolve.
    if (!allTypeRefsResolve(plan, TypeRefResolver{ .graph = graph, .types = types }, TypeRefResolver.exists)) return false;
    for (plan.schema_targets) |target| {
        const module_name = plan.symbols[@intFromEnum(target.module)];
        const schema_name = plan.symbols[@intFromEnum(target.schema)];
        const module = graph.find(target.package, module_name) orelse return false;
        if (module.int() >= interfaces.len) return false;
        if (module == current) {
            if (findLocalDefinition(plan, bir, schema_name) == null) return false;
        } else if (interfaces[module.int()].findSchema(interner, schema_name) == null) return false;
    }
    for (plan.ctor_targets) |target| {
        const schema_target = plan.schema_targets[@intFromEnum(target.schema)];
        const module_name = plan.symbols[@intFromEnum(schema_target.module)];
        const schema_name = plan.symbols[@intFromEnum(schema_target.schema)];
        const variant_name = plan.symbols[@intFromEnum(target.variant)];
        const module = graph.find(schema_target.package, module_name) orelse return false;
        if (module.int() >= interfaces.len) return false;
        if (module == current) {
            const definition = findLocalDefinition(plan, bir, schema_name) orelse return false;
            if (!localDefinitionHasVariant(bir, definition.decl, variant_name)) return false;
            continue;
        }
        const iface = &interfaces[module.int()];
        const schema = iface.findSchema(interner, schema_name) orelse return false;
        const endpoint: Interface.SchemaCtor.Endpoint = @enumFromInt(@intFromEnum(target.endpoint));
        if (iface.findSchemaCtor(schema, endpoint, interner, variant_name) == null) return false;
    }
    return true;
}

fn definitionHasStableIdentity(
    plan: *const SchemaPlan,
    definition: Definition,
    package: SourceStore.Package,
    module: Symbol,
    declaration_name: Symbol,
    tagged: bool,
    interner: *const InternPool.Global,
) bool {
    const program_ref = plan.type_refs[@intFromEnum(definition.type_ref)];
    const encoded_ref = plan.type_refs[@intFromEnum(definition.encoded_ref)];
    if (program_ref.package != package or encoded_ref.package != package) return false;
    if (plan.symbols[@intFromEnum(program_ref.module)] != module or
        plan.symbols[@intFromEnum(encoded_ref.module)] != module) return false;
    const base = interner.slice(declaration_name);
    if (!endpointSpelling(base, interner.slice(plan.symbols[@intFromEnum(program_ref.name)]), "Type")) return false;
    if (!endpointSpelling(base, interner.slice(plan.symbols[@intFromEnum(encoded_ref.name)]), "Encoded")) return false;
    const expected: Interface.Term.Tag = if (tagged) .app else .alias;
    return plan.terms.get(definition.program_term.int()).tag == expected and
        plan.terms.get(definition.encoded_term.int()).tag == expected;
}

fn endpointSpelling(base: []const u8, candidate: []const u8, suffix: []const u8) bool {
    if (candidate.len != base.len + 1 + suffix.len) return false;
    return std.mem.eql(u8, candidate[0..base.len], base) and
        candidate[base.len] == '.' and
        std.mem.eql(u8, candidate[base.len + 1 ..], suffix);
}

const TypeRefResolver = struct {
    graph: *const Graph,
    types: *const Types,

    fn exists(r: TypeRefResolver, package: SourceStore.Package, module: Symbol, name: Symbol) bool {
        return r.types.find(r.graph, package, module, name) != .none;
    }
};

fn allTypeRefsResolve(plan: *const SchemaPlan, context: anytype, comptime exists: anytype) bool {
    for (plan.type_refs) |ref| {
        const module = plan.symbols[@intFromEnum(ref.module)];
        const name = plan.symbols[@intFromEnum(ref.name)];
        if (!exists(context, ref.package, module, name)) return false;
    }
    return true;
}

fn findTagged(bir: *const Bir, root: Bir.Inst.Index) ?Bir.Inst.Index {
    var at = root;
    var budget = bir.insts.len + 1;
    while (budget > 0 and at.int() < bir.insts.len) : (budget -= 1) switch (bir.instTag(at)) {
        .schema_tagged => return at,
        .schema_value, .schema_paren => at = @enumFromInt(bir.instData(at).lhs),
        else => return null,
    };
    return null;
}

fn findLocalDefinition(plan: *const SchemaPlan, bir: *const Bir, name: Symbol) ?Definition {
    for (plan.definitions) |definition| {
        if (plan.symbols[@intFromEnum(definition.name)] != name) continue;
        const declaration = bir.decl(definition.decl);
        if (declaration.kind == .schema and bir.symbol(declaration.name) == name) return definition;
    }
    return null;
}

fn localDefinitionHasVariant(bir: *const Bir, decl_index: Bir.DeclIndex, name: Symbol) bool {
    const declaration = bir.decl(decl_index);
    var i = declaration.inst_start.int();
    while (i < declaration.inst_end.int()) : (i += 1) {
        const inst: Bir.Inst.Index = @enumFromInt(i);
        if (bir.instTag(inst) != .schema_variant) continue;
        if (bir.symbol(@enumFromInt(bir.instData(inst).lhs)) == name) return true;
    }
    return false;
}

test "a plan definition owns the exact endpoint identities and kind" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var pool = try InternPool.Global.init(gpa);
    defer pool.deinit(gpa);
    const module = try pool.getOrPut(gpa, "Models");
    const user = try pool.getOrPut(gpa, "User");
    const user_type = try pool.getOrPut(gpa, "User.Type");
    const user_encoded = try pool.getOrPut(gpa, "User.Encoded");
    const symbols = [_]Symbol{ module, user, user_type, user_encoded };
    const refs = [_]Interface.TypeRef{
        .{ .package = .app, .module = @enumFromInt(0), .name = @enumFromInt(2) },
        .{ .package = .app, .module = @enumFromInt(0), .name = @enumFromInt(3) },
    };
    var terms: std.MultiArrayList(Interface.Term) = .empty;
    defer terms.deinit(gpa);
    try terms.append(gpa, .{ .tag = .alias, .lhs = 0, .rhs = 0 });
    try terms.append(gpa, .{ .tag = .alias, .lhs = 1, .rhs = 0 });
    var plan = empty;
    plan.symbols = &symbols;
    plan.type_refs = &refs;
    plan.terms = terms.slice();
    var definition: Definition = .{
        .name = @enumFromInt(1),
        .decl = @enumFromInt(0),
        .params_start = 0,
        .params_end = 0,
        .root = @enumFromInt(0),
        .type_ref = @enumFromInt(0),
        .encoded_ref = @enumFromInt(1),
        .program_term = @enumFromInt(0),
        .encoded_term = @enumFromInt(1),
        .token = 0,
        .program_properties = 0,
        .encoded_properties = 0,
    };
    try testing.expect(definitionHasStableIdentity(&plan, definition, .app, module, user, false, &pool));

    // An in-bounds ref to the other endpoint used to pass the byte-level
    // verifier as long as the canonical term's lhs was changed with it.
    definition.encoded_ref = @enumFromInt(0);
    try testing.expect(!definitionHasStableIdentity(&plan, definition, .app, module, user, false, &pool));
    definition.encoded_ref = @enumFromInt(1);

    // Both tags are legal serialized terms, but only aliases belong to a
    // record schema and only nominal applications belong to a tagged one.
    try testing.expect(!definitionHasStableIdentity(&plan, definition, .app, module, user, true, &pool));
    terms.items(.tag)[0] = .app;
    terms.items(.tag)[1] = .app;
    try testing.expect(definitionHasStableIdentity(&plan, definition, .app, module, user, true, &pool));
}

test "a plan rejects a dangling stable type reference" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var pool = try InternPool.Global.init(gpa);
    defer pool.deinit(gpa);
    const module = try pool.getOrPut(gpa, "Models");
    const present = try pool.getOrPut(gpa, "Present");
    const missing = try pool.getOrPut(gpa, "Missing");
    const symbols = [_]Symbol{ module, present, missing };
    const refs = [_]Interface.TypeRef{
        .{ .package = .app, .module = @enumFromInt(0), .name = @enumFromInt(1) },
        .{ .package = .app, .module = @enumFromInt(0), .name = @enumFromInt(2) },
    };
    var plan = empty;
    plan.symbols = &symbols;
    plan.type_refs = &refs;
    const Resolver = struct {
        present: Symbol,
        fn exists(r: @This(), _: SourceStore.Package, _: Symbol, name: Symbol) bool {
            return name == r.present;
        }
    };
    try testing.expect(!allTypeRefsResolve(&plan, Resolver{ .present = present }, Resolver.exists));
    plan.type_refs = refs[0..1];
    try testing.expect(allTypeRefsResolve(&plan, Resolver{ .present = present }, Resolver.exists));
}
