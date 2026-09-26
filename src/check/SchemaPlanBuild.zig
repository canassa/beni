//! Deterministic construction of the immutable resolved schema plan.
//!
//! Definitions and every subordinate row are appended by source traversal;
//! no inference or worker completion order assigns an id.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const Schema = @import("Schema.zig");
const SchemaPlan = @import("SchemaPlan.zig");
const Schemes = @import("Schemes.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");

const Symbol = InternPool.Symbol;
const Var = TypeStore.Var;

pub fn build(
    gpa: Allocator,
    module: Graph.Index,
    bir: *const Bir,
    graph: *const Graph,
    interfaces: []const Interface,
    interner: *const InternPool.Global,
    types: *const Types,
    store: *TypeStore,
    schemas: *const Schema.State,
    /// Per declaration, its endpoints' property bytes `(program, encoded)`
    /// as the new checker read them off its derived contexts
    /// (checker-v2.md §11.5 *as built by R8b*), or null: the old checker's
    /// settled session bits.
    properties: ?[]const [2]u8,
) Allocator.Error!SchemaPlan {
    var b: Builder = .{
        .gpa = gpa,
        .module = module,
        .bir = bir,
        .graph = graph,
        .interfaces = interfaces,
        .interner = interner,
        .schemas = schemas,
    };
    defer b.deinit();

    for (bir.decls, 0..) |decl, decl_i| {
        if (decl.kind != .schema) continue;
        const root_inst = decl.schema_body.unwrap() orelse continue;
        const params_start: u32 = @intCast(b.extra.items.len);
        for (bir.declTypeParams(decl)) |param| try b.extra.append(gpa, @intFromEnum(try b.symbolIndex(param)));
        const params_end: u32 = @intCast(b.extra.items.len);
        const root = try b.node(@enumFromInt(decl_i), root_inst);
        try b.definitions.append(gpa, .{
            .name = try b.symbolIndex(bir.symbol(decl.name)),
            .decl = @enumFromInt(decl_i),
            .params_start = params_start,
            .params_end = params_end,
            .root = root,
            .token = decl.name_token,
        });
    }
    if (b.poisoned) return SchemaPlan.empty;

    var writer = Schemes.Writer.init(gpa, store, interner, types, @intCast(b.symbols.items.len));
    defer writer.deinit();
    for (b.conversion_vars.items, 0..) |target, i| b.conversions.items[i].target_term = try writer.addPlanRoot(target);

    var plan = SchemaPlan.empty;
    errdefer plan.deinit(gpa);
    plan.definitions = try gpa.alloc(SchemaPlan.Definition, b.definitions.items.len);
    for (b.definitions.items, @constCast(plan.definitions)) |d, *out| {
        const endpoints = schemas.endpoints[d.decl.int()];
        const program_term = try writer.addPlanRoot(endpoints.program);
        const encoded_term = try writer.addPlanRoot(endpoints.encoded);
        const program = writer.terms.get(program_term.int());
        const encoded = writer.terms.get(encoded_term.int());
        out.* = .{
            .name = d.name,
            .decl = d.decl,
            .params_start = d.params_start,
            .params_end = d.params_end,
            .root = d.root,
            .type_ref = @enumFromInt(program.lhs),
            .encoded_ref = @enumFromInt(encoded.lhs),
            .program_term = program_term,
            .encoded_term = encoded_term,
            .token = d.token,
            .program_properties = if (properties) |p| p[d.decl.int()][0] else types.schemaPropertyBits(types.ofSchemaDecl(module, d.decl, .type)),
            .encoded_properties = if (properties) |p| p[d.decl.int()][1] else types.schemaPropertyBits(types.ofSchemaDecl(module, d.decl, .encoded)),
        };
    }
    const term_tables = try writer.takePlanTerms();
    plan.terms = term_tables.terms;
    plan.type_extra = term_tables.extra;
    plan.type_refs = term_tables.type_refs;
    defer gpa.free(term_tables.symbols);
    plan.symbols = try gpa.alloc(Symbol, b.symbols.items.len + term_tables.symbols.len);
    @memcpy(@constCast(plan.symbols[0..b.symbols.items.len]), b.symbols.items);
    @memcpy(@constCast(plan.symbols[b.symbols.items.len..]), term_tables.symbols);
    plan.nodes = b.nodes.toOwnedSlice();
    plan.fields = try b.fields.toOwnedSlice(gpa);
    plan.variants = try b.variants.toOwnedSlice(gpa);
    plan.conversions = try b.conversions.toOwnedSlice(gpa);
    plan.extra = try b.extra.toOwnedSlice(gpa);
    plan.literal_bytes = try b.literal_bytes.toOwnedSlice(gpa);
    plan.literals = try b.literals.toOwnedSlice(gpa);
    plan.schema_targets = try b.schema_targets.toOwnedSlice(gpa);
    plan.ctor_targets = try b.ctor_targets.toOwnedSlice(gpa);
    return plan;
}

const PendingDefinition = struct {
    name: SchemaPlan.SymbolIndex,
    decl: Bir.DeclIndex,
    params_start: u32,
    params_end: u32,
    root: SchemaPlan.NodeIndex,
    token: u32,
};

const Builder = struct {
    gpa: Allocator,
    module: Graph.Index,
    bir: *const Bir,
    graph: *const Graph,
    interfaces: []const Interface,
    interner: *const InternPool.Global,
    schemas: *const Schema.State,
    definitions: std.ArrayList(PendingDefinition) = .empty,
    nodes: std.MultiArrayList(SchemaPlan.Node) = .empty,
    fields: std.ArrayList(SchemaPlan.Field) = .empty,
    variants: std.ArrayList(SchemaPlan.Variant) = .empty,
    conversions: std.ArrayList(SchemaPlan.Conversion) = .empty,
    conversion_vars: std.ArrayList(Var) = .empty,
    extra: std.ArrayList(u32) = .empty,
    literal_bytes: std.ArrayList(u8) = .empty,
    literals: std.ArrayList(SchemaPlan.Literal) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    schema_targets: std.ArrayList(SchemaPlan.SchemaTarget) = .empty,
    ctor_targets: std.ArrayList(SchemaPlan.CtorTarget) = .empty,
    poisoned: bool = false,

    fn deinit(b: *Builder) void {
        b.definitions.deinit(b.gpa);
        b.nodes.deinit(b.gpa);
        b.fields.deinit(b.gpa);
        b.variants.deinit(b.gpa);
        b.conversions.deinit(b.gpa);
        b.conversion_vars.deinit(b.gpa);
        b.extra.deinit(b.gpa);
        b.literal_bytes.deinit(b.gpa);
        b.literals.deinit(b.gpa);
        b.symbols.deinit(b.gpa);
        b.schema_targets.deinit(b.gpa);
        b.ctor_targets.deinit(b.gpa);
    }

    fn symbolIndex(b: *Builder, symbol: Symbol) Allocator.Error!SchemaPlan.SymbolIndex {
        for (b.symbols.items, 0..) |seen, i| if (seen == symbol) return @enumFromInt(i);
        const index: SchemaPlan.SymbolIndex = @enumFromInt(b.symbols.items.len);
        try b.symbols.append(b.gpa, symbol);
        return index;
    }

    fn literal(b: *Builder, bytes: []const u8) Allocator.Error!SchemaPlan.LiteralIndex {
        const index: SchemaPlan.LiteralIndex = @enumFromInt(b.literals.items.len);
        const start: u32 = @intCast(b.literal_bytes.items.len);
        try b.literal_bytes.appendSlice(b.gpa, bytes);
        try b.literals.append(b.gpa, .{ .start = start, .len = @intCast(bytes.len) });
        return index;
    }

    fn token(b: *const Builder, inst: Bir.Inst.Index) u32 {
        return b.bir.insts.items(.main_token)[inst.int()];
    }

    fn appendNode(b: *Builder, entry: SchemaPlan.Node) Allocator.Error!SchemaPlan.NodeIndex {
        const index: SchemaPlan.NodeIndex = @enumFromInt(b.nodes.len);
        try b.nodes.append(b.gpa, entry);
        return index;
    }

    fn range(b: *Builder, words: []const u32) Allocator.Error!u32 {
        const start: u32 = @intCast(b.extra.items.len);
        try b.extra.append(b.gpa, @intCast(words.len));
        try b.extra.appendSlice(b.gpa, words);
        return start;
    }

    fn node(b: *Builder, owner: Bir.DeclIndex, inst: Bir.Inst.Index) Allocator.Error!SchemaPlan.NodeIndex {
        const data = b.bir.instData(inst);
        const at = b.token(inst);
        return switch (b.bir.instTag(inst)) {
            .schema_paren => b.node(owner, @enumFromInt(data.lhs)),
            .schema_value => b.value(owner, @enumFromInt(data.lhs), b.bir.extraSlice(b.bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index)),
            .schema_parameter => b.appendNode(.{ .tag = .parameter, .lhs = data.lhs, .rhs = 0, .token = at }),
            .schema_primitive => b.appendNode(.{ .tag = .primitive, .lhs = data.lhs, .rhs = 0, .token = at }),
            .schema_target_top, .ext_schema_target => b.reference(inst, &.{}),
            .schema_app => blk: {
                const args_i = b.bir.extraSlice(b.bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
                const args = try b.gpa.alloc(u32, args_i.len);
                defer b.gpa.free(args);
                for (args_i, args) |arg, *out| out.* = @intFromEnum(try b.node(owner, arg));
                const head: Bir.Inst.Index = @enumFromInt(data.lhs);
                if (b.bir.instTag(head) == .schema_primitive and std.enums.fromInt(Bir.SchemaPrimitive, b.bir.instData(head).lhs) == .list and args.len == 1)
                    break :blk b.appendNode(.{ .tag = .list, .lhs = args[0], .rhs = 0, .token = at });
                break :blk switch (b.bir.instTag(head)) {
                    .schema_target_top, .ext_schema_target => b.reference(head, args),
                    else => {
                        b.poisoned = true;
                        break :blk b.appendNode(.{ .tag = .primitive, .lhs = @intFromEnum(SchemaPlan.Primitive.value), .rhs = 0, .token = at });
                    },
                };
            },
            .schema_record => b.record(owner, b.bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index), at),
            .schema_tagged => b.tagged(owner, inst),
            else => blk: {
                b.poisoned = true;
                break :blk b.appendNode(.{ .tag = .primitive, .lhs = @intFromEnum(SchemaPlan.Primitive.value), .rhs = 0, .token = at });
            },
        };
    }

    fn value(b: *Builder, owner: Bir.DeclIndex, operand: Bir.Inst.Index, modifiers: []const Bir.Inst.Index) Allocator.Error!SchemaPlan.NodeIndex {
        var child = try b.node(owner, operand);
        for (modifiers) |modifier| switch (b.bir.instTag(modifier)) {
            .schema_nullable => child = try b.appendNode(.{ .tag = .nullable, .lhs = @intFromEnum(child), .rhs = 0, .token = b.token(modifier) }),
            .schema_via => child = try b.conversion(owner, child, modifier),
            else => {},
        };
        return child;
    }

    fn record(b: *Builder, owner: Bir.DeclIndex, fields: []const Bir.Inst.Index, source_token: u32) Allocator.Error!SchemaPlan.NodeIndex {
        var pending: std.ArrayList(SchemaPlan.Field) = .empty;
        defer pending.deinit(b.gpa);
        try pending.ensureTotalCapacity(b.gpa, fields.len);
        for (fields) |field_inst| {
            const data = b.bir.instData(field_inst);
            const field = b.bir.extraData(@enumFromInt(data.rhs), Bir.SchemaField);
            var child = try b.node(owner, field.operand);
            var external = try b.literal(b.interner.slice(b.bir.symbol(@enumFromInt(data.lhs))));
            var optional = false;
            for (b.bir.extraSlice(.{ .start = field.modifiers_start, .end = field.modifiers_end }, Bir.Inst.Index)) |modifier| switch (b.bir.instTag(modifier)) {
                .schema_as => external = try b.literal(b.bir.bytes(@enumFromInt(b.bir.instData(modifier).lhs))),
                .schema_optional => optional = true,
                .schema_nullable => child = try b.appendNode(.{ .tag = .nullable, .lhs = @intFromEnum(child), .rhs = 0, .token = b.token(modifier) }),
                .schema_via => child = try b.conversion(owner, child, modifier),
                else => {},
            };
            pending.appendAssumeCapacity(.{
                .name = try b.symbolIndex(b.bir.symbol(@enumFromInt(data.lhs))),
                .external = external,
                .child = child,
                .optional = optional,
                .token = b.token(field_inst),
            });
        }
        const start: u32 = @intCast(b.fields.items.len);
        try b.fields.appendSlice(b.gpa, pending.items);
        return b.appendNode(.{ .tag = .record, .lhs = start, .rhs = @intCast(b.fields.items.len), .token = source_token });
    }

    fn conversion(b: *Builder, owner: Bir.DeclIndex, child: SchemaPlan.NodeIndex, modifier: Bir.Inst.Index) Allocator.Error!SchemaPlan.NodeIndex {
        var expr: Bir.Inst.Index = @enumFromInt(b.bir.instData(modifier).lhs);
        var target: Var = b.schemas.endpoints[owner.int()].program;
        for (b.schemas.vias.items) |via| if (via.owner == owner and via.region == modifier) {
            expr = via.expr;
            target = via.target;
            break;
        };
        const conversion_index: u32 = @intCast(b.conversions.items.len);
        try b.conversions.append(b.gpa, .{
            .expr = expr,
            .target_term = .none,
            .token = b.token(modifier),
            .opaque_target = true,
            .opaque_checks = true,
        });
        try b.conversion_vars.append(b.gpa, target);
        return b.appendNode(.{ .tag = .conversion, .lhs = @intFromEnum(child), .rhs = conversion_index, .token = b.token(modifier) });
    }

    fn reference(b: *Builder, head: Bir.Inst.Index, args: []const u32) Allocator.Error!SchemaPlan.NodeIndex {
        const target = (try b.schemaTarget(head)) orelse {
            b.poisoned = true;
            return b.appendNode(.{ .tag = .primitive, .lhs = @intFromEnum(SchemaPlan.Primitive.value), .rhs = 0, .token = b.token(head) });
        };
        return b.appendNode(.{ .tag = .reference, .lhs = @intFromEnum(target), .rhs = try b.range(args), .token = b.token(head) });
    }

    fn schemaTarget(b: *Builder, head: Bir.Inst.Index) Allocator.Error!?SchemaPlan.SchemaTargetIndex {
        const data = b.bir.instData(head);
        const target: SchemaPlan.SchemaTarget = switch (b.bir.instTag(head)) {
            .schema_target_top => .{
                .package = b.graph.module(b.module).package,
                .module = try b.symbolIndex(b.graph.moduleName(b.module)),
                .schema = try b.symbolIndex(b.bir.symbol(b.bir.decl(@enumFromInt(data.lhs)).name)),
            },
            .ext_schema_target => blk: {
                const module: Graph.Index = @enumFromInt(data.lhs);
                const iface = &b.interfaces[module.int()];
                break :blk .{
                    .package = b.graph.module(module).package,
                    .module = try b.symbolIndex(b.graph.moduleName(module)),
                    .schema = try b.symbolIndex(iface.symbol(iface.schemas[data.rhs].name)),
                };
            },
            else => return null,
        };
        for (b.schema_targets.items, 0..) |seen, i| {
            if (seen.package == target.package and seen.module == target.module and seen.schema == target.schema) return @enumFromInt(i);
        }
        const index: SchemaPlan.SchemaTargetIndex = @enumFromInt(b.schema_targets.items.len);
        try b.schema_targets.append(b.gpa, target);
        return index;
    }

    fn tagged(b: *Builder, owner: Bir.DeclIndex, inst: Bir.Inst.Index) Allocator.Error!SchemaPlan.NodeIndex {
        const data = b.bir.instData(inst);
        const discriminator = try b.literal(b.bir.bytes(@enumFromInt(data.lhs)));
        const variants_i = b.bir.extraSlice(b.bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
        const words = try b.gpa.alloc(u32, variants_i.len);
        defer b.gpa.free(words);
        const local_target = try b.localSchemaTarget(owner);
        for (variants_i, words) |variant_inst, *word| {
            const vd = b.bir.instData(variant_inst);
            const source = b.bir.symbol(@enumFromInt(vd.lhs));
            const variant = b.bir.extraData(@enumFromInt(vd.rhs), Bir.SchemaVariant);
            const payload: SchemaPlan.NodeIndex.Optional = if (variant.payload.unwrap()) |p|
                (try b.node(owner, p)).toOptional()
            else
                .none;
            const external = if (variant.rename.unwrap()) |rename|
                try b.literal(b.bir.bytes(rename))
            else
                try b.literal(b.interner.slice(source));
            const program_ctor = try b.ctorTarget(local_target, source, .type);
            const encoded_ctor = try b.ctorTarget(local_target, source, .encoded);
            word.* = @intCast(b.variants.items.len);
            try b.variants.append(b.gpa, .{
                .name = try b.symbolIndex(source),
                .external = external,
                .payload = payload,
                .program_ctor = program_ctor,
                .encoded_ctor = encoded_ctor,
                .token = b.token(variant_inst),
            });
        }
        return b.appendNode(.{ .tag = .tagged, .lhs = @intFromEnum(discriminator), .rhs = try b.range(words), .token = b.token(inst) });
    }

    fn localSchemaTarget(b: *Builder, owner: Bir.DeclIndex) Allocator.Error!SchemaPlan.SchemaTargetIndex {
        const target: SchemaPlan.SchemaTarget = .{
            .package = b.graph.module(b.module).package,
            .module = try b.symbolIndex(b.graph.moduleName(b.module)),
            .schema = try b.symbolIndex(b.bir.symbol(b.bir.decl(owner).name)),
        };
        for (b.schema_targets.items, 0..) |seen, i| if (seen.package == target.package and seen.module == target.module and seen.schema == target.schema) return @enumFromInt(i);
        const index: SchemaPlan.SchemaTargetIndex = @enumFromInt(b.schema_targets.items.len);
        try b.schema_targets.append(b.gpa, target);
        return index;
    }

    fn ctorTarget(b: *Builder, schema: SchemaPlan.SchemaTargetIndex, variant: Symbol, endpoint: SchemaPlan.Endpoint) Allocator.Error!SchemaPlan.CtorTargetIndex {
        const name = try b.symbolIndex(variant);
        const index: SchemaPlan.CtorTargetIndex = @enumFromInt(b.ctor_targets.items.len);
        try b.ctor_targets.append(b.gpa, .{ .schema = schema, .variant = name, .endpoint = endpoint });
        return index;
    }
};
