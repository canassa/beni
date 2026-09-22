//! Schema endpoint elaboration (docs/design/schema.md §4).
//!
//! Endpoints are predeclared before bodies are walked. Tagged recursion
//! therefore closes through nominal TypeIds while records remain aliases.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Artifacts = @import("../Artifacts.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const InterfaceTerms = @import("InterfaceTerms.zig");

pub const Var = TypeStore.Var;
pub const Pair = struct { encoded: Var, program: Var };
pub const Via = struct { owner: Bir.DeclIndex, field: InternPool.Symbol, expr: Bir.Inst.Index, expected: Var, target: Var, region: Bir.Inst.Index };
pub const SchemaError = struct { code: @import("diagnostic").Code, region: Bir.Inst.Index, message: []const u8 };

pub const State = struct {
    allocator: Allocator,
    store: *TypeStore,
    types: *const Types,
    module: Graph.Index,
    bir: *const Bir,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []const Interface,
    interner: *const InternPool.Global,
    endpoints: []Pair,
    members: []Var.Optional,
    params_start: []u32,
    params_len: []u32,
    params: []Pair,
    status: []Status,
    variant_payloads: []Pair,
    variant_built: []bool,
    vias: std.ArrayList(Via) = .empty,
    recursive_aliases: std.ArrayList(Bir.Inst.Index) = .empty,
    errors: std.ArrayList(SchemaError) = .empty,

    const Status = enum(u8) { absent, pending, building, done, poisoned };

    pub fn init(a: Allocator, store: *TypeStore, types: *const Types, graph: *const Graph, artifacts: *const Artifacts, interfaces: []const Interface, interner: *const InternPool.Global, module: Graph.Index, bir: *const Bir) Allocator.Error!State {
        const n = bir.decls.len;
        var s: State = .{ .allocator = a, .store = store, .types = types, .graph = graph, .artifacts = artifacts, .interfaces = interfaces, .interner = interner, .module = module, .bir = bir, .endpoints = try a.alloc(Pair, n), .members = try a.alloc(Var.Optional, n * 7), .params_start = try a.alloc(u32, n), .params_len = try a.alloc(u32, n), .params = &.{}, .status = try a.alloc(Status, n), .variant_payloads = try a.alloc(Pair, bir.insts.len), .variant_built = try a.alloc(bool, bir.insts.len) };
        errdefer s.deinit();
        @memset(s.members, .none);
        @memset(s.params_start, 0);
        @memset(s.params_len, 0);
        @memset(s.status, .absent);
        @memset(s.variant_built, false);
        var count: usize = 0;
        for (bir.decls) |d| if (d.kind == .schema) {
            count += d.params;
        };
        s.params = try a.alloc(Pair, count);
        var cursor: u32 = 0;
        for (bir.decls, 0..) |d, i| {
            s.endpoints[i] = try s.errPair();
            if (d.kind != .schema) continue;
            s.status[i] = .pending;
            s.params_start[i] = cursor;
            s.params_len[i] = d.params;
            var j: u32 = 0;
            while (j < d.params) : (j += 1) {
                s.params[cursor] = .{ .encoded = try store.freshFlex(TypeStore.generalized), .program = try store.freshFlex(TypeStore.generalized) };
                cursor += 1;
            }
            s.endpoints[i] = .{ .encoded = try store.freshFlex(TypeStore.generalized), .program = try store.freshFlex(TypeStore.generalized) };
        }
        return s;
    }

    pub fn deinit(s: *State) void {
        s.allocator.free(s.endpoints);
        s.allocator.free(s.members);
        s.allocator.free(s.params_start);
        s.allocator.free(s.params_len);
        s.allocator.free(s.params);
        s.allocator.free(s.status);
        s.allocator.free(s.variant_payloads);
        s.allocator.free(s.variant_built);
        s.vias.deinit(s.allocator);
        s.recursive_aliases.deinit(s.allocator);
        s.errors.deinit(s.allocator);
        s.* = undefined;
    }

    pub fn buildAll(s: *State) Allocator.Error!void {
        // Nominal endpoints cut structural recursion. Build them first so a
        // record ↔ tagged cycle always reaches an already-declared nominal
        // root, independent of declaration order.
        for (s.bir.decls, 0..) |d, i| {
            if (d.kind != .schema) continue;
            const root = d.schema_body.unwrap() orelse continue;
            if (s.findTagged(root) != null) try s.buildDecl(@enumFromInt(i));
        }
        for (s.bir.decls, 0..) |d, i| {
            if (d.kind != .schema) continue;
            const root = d.schema_body.unwrap() orelse continue;
            if (s.findTagged(root) == null) try s.buildDecl(@enumFromInt(i));
        }
    }

    pub fn settleProperties(s: *State, types: *Types, gpa: Allocator) Allocator.Error!void {
        const n = types.count();
        if (n == 0) return;

        var edge_from: std.ArrayList(u32) = .empty;
        defer edge_from.deinit(gpa);
        var edge_to: std.ArrayList(u32) = .empty;
        defer edge_to.deinit(gpa);
        var deps: std.ArrayList(Types.TypeId) = .empty;
        defer deps.deinit(gpa);

        for (s.bir.decls, 0..) |decl, di| {
            if (decl.kind != .schema) continue;
            const root = decl.schema_body.unwrap() orelse continue;
            const tagged = s.findTagged(root);
            inline for ([_]Interface.SchemaCtor.Endpoint{ .type, .encoded }) |endpoint| {
                const id = types.ofSchemaDecl(s.module, @enumFromInt(di), endpoint);
                var properties: Types.SchemaProperties = .{ .equatable = true, .comparable = true, .has_function = false };
                deps.clearRetainingCapacity();
                const endpoint_root = if (endpoint == .type) s.endpoints[di].program else s.endpoints[di].encoded;
                const own = try types.schemaPropertiesWithDeps(gpa, s.store, id, endpoint_root, &deps);
                properties.equatable = properties.equatable and own.equatable;
                properties.comparable = properties.comparable and own.comparable;
                properties.has_function = properties.has_function or own.has_function;
                if (tagged) |tagged_inst| {
                    const variants = s.bir.extraSlice(s.bir.subRange(@enumFromInt(s.bir.instData(tagged_inst).rhs)), Bir.Inst.Index);
                    for (variants) |vi| {
                        if (!s.variant_built[vi.int()]) continue;
                        const pair = s.variant_payloads[vi.int()];
                        const payload = if (endpoint == .type) pair.program else pair.encoded;
                        const p = try types.schemaPropertiesWithDeps(gpa, s.store, id, payload, &deps);
                        properties.equatable = properties.equatable and p.equatable;
                        properties.comparable = properties.comparable and p.comparable;
                        properties.has_function = properties.has_function or p.has_function;
                    }
                }
                if (types.declaresPubMethod(s.module, s.bir, id, InternPool.WellKnown.eq.symbol())) properties.equatable = true;
                if (types.declaresPubMethod(s.module, s.bir, id, InternPool.WellKnown.compare.symbol())) properties.comparable = true;
                const bits = @as(u8, @intFromBool(properties.equatable)) |
                    (@as(u8, @intFromBool(properties.comparable)) << 1) |
                    (@as(u8, @intFromBool(properties.has_function)) << 2);
                types.restoreSchemaPropertyBits(id, bits);
                for (deps.items) |dependency| {
                    if (dependency == .none or dependency.int() >= n) continue;
                    try edge_from.append(gpa, dependency.int());
                    try edge_to.append(gpa, id.int());
                }
            }
        }

        const starts = try gpa.alloc(u32, n + 1);
        defer gpa.free(starts);
        @memset(starts, 0);
        for (edge_from.items) |from| starts[from + 1] += 1;
        for (1..n + 1) |i| starts[i] += starts[i - 1];
        const dependents = try gpa.alloc(u32, edge_to.items.len);
        defer gpa.free(dependents);
        const cursor = try gpa.dupe(u32, starts[0..n]);
        defer gpa.free(cursor);
        for (edge_from.items, edge_to.items) |from, to| {
            dependents[cursor[from]] = to;
            cursor[from] += 1;
        }

        var equality_queue: std.ArrayList(u32) = .empty;
        defer equality_queue.deinit(gpa);
        var order_queue: std.ArrayList(u32) = .empty;
        defer order_queue.deinit(gpa);
        var function_queue: std.ArrayList(u32) = .empty;
        defer function_queue.deinit(gpa);
        const equality_seen = try gpa.alloc(bool, n);
        defer gpa.free(equality_seen);
        const order_seen = try gpa.alloc(bool, n);
        defer gpa.free(order_seen);
        const function_seen = try gpa.alloc(bool, n);
        defer gpa.free(function_seen);
        @memset(equality_seen, false);
        @memset(order_seen, false);
        @memset(function_seen, false);
        for (edge_from.items) |from| {
            const id: Types.TypeId = @enumFromInt(from);
            if (!types.isEquatable(id) and !equality_seen[from]) {
                equality_seen[from] = true;
                try equality_queue.append(gpa, from);
            }
            if (!types.isComparable(id) and !order_seen[from]) {
                order_seen[from] = true;
                try order_queue.append(gpa, from);
            }
            if (types.hasFunction(id) and !function_seen[from]) {
                function_seen[from] = true;
                try function_queue.append(gpa, from);
            }
        }
        while (equality_queue.pop()) |id| for (dependents[starts[id]..starts[id + 1]]) |dependent| {
            const target: Types.TypeId = @enumFromInt(dependent);
            if (!types.isEquatable(target)) continue;
            types.restoreSchemaPropertyBits(target, types.schemaPropertyBits(target) & ~@as(u8, 1));
            try equality_queue.append(gpa, dependent);
        };
        while (order_queue.pop()) |id| for (dependents[starts[id]..starts[id + 1]]) |dependent| {
            const target: Types.TypeId = @enumFromInt(dependent);
            if (!types.isComparable(target)) continue;
            types.restoreSchemaPropertyBits(target, types.schemaPropertyBits(target) & ~@as(u8, 2));
            try order_queue.append(gpa, dependent);
        };
        while (function_queue.pop()) |id| for (dependents[starts[id]..starts[id + 1]]) |dependent| {
            const target: Types.TypeId = @enumFromInt(dependent);
            if (types.hasFunction(target)) continue;
            types.restoreSchemaPropertyBits(target, types.schemaPropertyBits(target) | 4);
            try function_queue.append(gpa, dependent);
        };
    }

    pub fn member(s: *const State, decl: u32, kind: Interface.SchemaMember.Kind) ?Var {
        const at = @as(usize, decl) * 7 + @intFromEnum(kind);
        return if (at < s.members.len) s.members[at].unwrap() else null;
    }

    pub fn lookupOpaque(ctx: *anyopaque, decl: u32, encoded: bool, args: []const Var) Allocator.Error!?Var {
        const s: *State = @ptrCast(@alignCast(ctx));
        if (decl >= s.endpoints.len) return null;
        const root = if (encoded) s.endpoints[decl].encoded else s.endpoints[decl].program;
        if (args.len == 0) return root;
        if (args.len != s.params_len[decl]) return null;
        const old = try s.allocator.alloc(Var, args.len);
        defer s.allocator.free(old);
        for (old, 0..) |*v, i| {
            const p = s.params[s.params_start[decl] + i];
            v.* = if (encoded) p.encoded else p.program;
        }
        return try s.copyEndpoint(root, old, args);
    }

    pub fn constructor(s: *State, decl: Bir.DeclIndex, endpoint: Interface.SchemaCtor.Endpoint, ordinal: u32) Allocator.Error!?Var {
        const root = s.bir.decl(decl).schema_body.unwrap() orelse return null;
        const tagged = s.findTagged(root) orelse return null;
        const range = s.bir.extraSlice(s.bir.subRange(@enumFromInt(s.bir.instData(tagged).rhs)), Bir.Inst.Index);
        if (ordinal >= range.len) return null;
        const vi = range[ordinal];
        if (s.bir.instTag(vi) != .schema_variant) return null;
        const variant = s.bir.extraData(@enumFromInt(s.bir.instData(vi).rhs), Bir.SchemaVariant);
        const result = if (endpoint == .type) s.endpoints[decl.int()].program else s.endpoints[decl.int()].encoded;
        const payload_i = variant.payload.unwrap() orelse return result;
        const payload = if (vi.int() < s.variant_built.len and s.variant_built[vi.int()]) s.variant_payloads[vi.int()] else try s.node(decl, payload_i);
        const ctor = try s.func(&.{if (endpoint == .type) payload.program else payload.encoded}, result);
        return @as(?Var, ctor);
    }

    fn buildDecl(s: *State, di: Bir.DeclIndex) Allocator.Error!void {
        const i = di.int();
        if (i >= s.status.len or s.status[i] == .done or s.status[i] == .poisoned or s.status[i] == .building) return;
        s.status[i] = .building;
        const d = s.bir.decl(di);
        const root = d.schema_body.unwrap() orelse {
            s.status[i] = .poisoned;
            return;
        };
        const pair = try s.node(di, root);
        const tagged = s.findTagged(root) != null;
        if (s.findTagged(root)) |tagged_inst| {
            try s.validateTagged(tagged_inst);
            try s.buildTaggedPayloads(di, tagged_inst);
        }
        inline for ([_]Interface.SchemaCtor.Endpoint{ .type, .encoded }) |ep| {
            const placeholder = if (ep == .type) s.endpoints[i].program else s.endpoints[i].encoded;
            const actual = if (ep == .type) pair.program else pair.encoded;
            const id = s.types.ofSchemaDecl(s.module, di, ep);
            const args = try s.endpointParams(di, ep);
            defer s.allocator.free(args);
            const range = try s.store.addVars(args);
            s.store.setContent(placeholder, if (tagged)
                .{ .structure = .{ .app = .{ .type = id, .args = range } } }
            else
                .{ .alias = .{ .type = id, .args = range, .actual = actual } });
        }
        try s.buildMembers(di);
        s.status[i] = .done;
    }

    fn endpointParams(s: *State, di: Bir.DeclIndex, ep: Interface.SchemaCtor.Endpoint) Allocator.Error![]Var {
        const out = try s.allocator.alloc(Var, s.params_len[di.int()]);
        for (out, 0..) |*v, j| {
            const p = s.params[s.params_start[di.int()] + j];
            v.* = if (ep == .type) p.program else p.encoded;
        }
        return out;
    }

    fn buildMembers(s: *State, di: Bir.DeclIndex) Allocator.Error!void {
        const pair = s.endpoints[di.int()];
        const n = s.params_len[di.int()];
        const schema_args = try s.allocator.alloc(Var, n);
        defer s.allocator.free(schema_args);
        for (schema_args, 0..) |*v, j| {
            const p = s.params[s.params_start[di.int()] + j];
            v.* = try s.applied(s.types.well_known.schema, &.{ p.encoded, p.program });
        }
        const result_schema = try s.applied(s.types.well_known.schema, &.{ pair.encoded, pair.program });
        const unit = try s.store.fresh(.{ .structure = .unit }, TypeStore.generalized);
        const base = di.int() * 7;
        s.members[base + @intFromEnum(Interface.SchemaMember.Kind.type)] = pair.program.toOptional();
        s.members[base + @intFromEnum(Interface.SchemaMember.Kind.encoded)] = pair.encoded.toOptional();
        s.members[base + @intFromEnum(Interface.SchemaMember.Kind.schema)] = (try s.func(if (n == 0) &.{unit} else schema_args, result_schema)).toOptional();
        const string = try s.applied(s.types.well_known.string, &.{});
        const issue = try s.applied(s.types.well_known.issue, &.{});
        const issues = try s.applied(s.types.well_known.list, &.{issue});
        const parse_result = try s.applied(s.types.well_known.result, &.{ issues, pair.program });
        const print_result = try s.applied(s.types.well_known.result, &.{ issues, string });
        const options = try s.applied(s.types.well_known.options, &.{});
        const parse_p = try s.join(schema_args, &.{string});
        defer s.allocator.free(parse_p);
        const print_p = try s.join(schema_args, &.{pair.program});
        defer s.allocator.free(print_p);
        const parse_w = try s.join(schema_args, &.{ options, string });
        defer s.allocator.free(parse_w);
        const print_w = try s.join(schema_args, &.{ options, pair.program });
        defer s.allocator.free(print_w);
        s.members[base + @intFromEnum(Interface.SchemaMember.Kind.parse)] = (try s.func(parse_p, parse_result)).toOptional();
        s.members[base + @intFromEnum(Interface.SchemaMember.Kind.print)] = (try s.func(print_p, print_result)).toOptional();
        s.members[base + @intFromEnum(Interface.SchemaMember.Kind.parse_with)] = (try s.func(parse_w, parse_result)).toOptional();
        s.members[base + @intFromEnum(Interface.SchemaMember.Kind.print_with)] = (try s.func(print_w, print_result)).toOptional();
    }

    fn node(s: *State, owner: Bir.DeclIndex, inst: Bir.Inst.Index) Allocator.Error!Pair {
        if (inst.int() >= s.bir.insts.len) return s.errPair();
        const d = s.bir.instData(inst);
        return switch (s.bir.instTag(inst)) {
            .schema_paren => s.node(owner, @enumFromInt(d.lhs)),
            .schema_value => s.value(owner, @enumFromInt(d.lhs), s.bir.extraSlice(s.bir.subRange(@enumFromInt(d.rhs)), Bir.Inst.Index)),
            .schema_parameter => if (d.lhs < s.params_len[owner.int()]) s.params[s.params_start[owner.int()] + d.lhs] else s.errPair(),
            .schema_primitive => s.primitive(d.lhs, inst),
            .schema_target_top => s.localTarget(@enumFromInt(d.lhs), &.{}, inst),
            .ext_schema_target => s.externalTarget(@enumFromInt(d.lhs), @enumFromInt(d.rhs), &.{}, inst),
            .schema_app => blk: {
                const args_i = s.bir.extraSlice(s.bir.subRange(@enumFromInt(d.rhs)), Bir.Inst.Index);
                const args = try s.allocator.alloc(Pair, args_i.len);
                defer s.allocator.free(args);
                for (args_i, args) |arg, *p| p.* = try s.node(owner, arg);
                const head: Bir.Inst.Index = @enumFromInt(d.lhs);
                const hd = s.bir.instData(head);
                break :blk switch (s.bir.instTag(head)) {
                    .schema_target_top => s.localTarget(@enumFromInt(hd.lhs), args, head),
                    .ext_schema_target => s.externalTarget(@enumFromInt(hd.lhs), @enumFromInt(hd.rhs), args, head),
                    .schema_primitive => s.primitiveApp(hd.lhs, args, head),
                    else => s.errPair(),
                };
            },
            .schema_record => s.record(owner, s.bir.extraSlice(Bir.inlineRange(d), Bir.Inst.Index)),
            .schema_tagged => s.endpoints[owner.int()],
            else => s.errPair(),
        };
    }

    fn value(s: *State, owner: Bir.DeclIndex, operand: Bir.Inst.Index, modifiers: []const Bir.Inst.Index) Allocator.Error!Pair {
        var pair = try s.node(owner, operand);
        var nullable = false;
        const field_name = s.bir.symbol(s.bir.decl(owner).name);
        for (modifiers) |mi| switch (s.bir.instTag(mi)) {
            .schema_nullable => nullable = true,
            .schema_via => {
                const a = try s.store.freshFlex(TypeStore.generalized);
                const expected = try s.applied(s.types.well_known.conversion, &.{ pair.program, a });
                try s.vias.append(s.allocator, .{ .owner = owner, .field = field_name, .expr = @enumFromInt(s.bir.instData(mi).lhs), .expected = expected, .target = a, .region = mi });
                pair.program = a;
            },
            else => {},
        };
        if (nullable) pair = try s.wrap(s.types.well_known.nullable, pair);
        return pair;
    }

    fn localTarget(s: *State, target: Bir.DeclIndex, args: []const Pair, region: Bir.Inst.Index) Allocator.Error!Pair {
        if (target.int() >= s.bir.decls.len or s.bir.decl(target).kind != .schema) return s.errPair();
        if (s.status[target.int()] == .building) {
            const root = s.bir.decl(target).schema_body.unwrap() orelse return s.errPair();
            if (s.findTagged(root) == null) {
                try s.recursive_aliases.append(s.allocator, region);
                return s.errPair();
            }
            if (args.len != s.params_len[target.int()]) {
                try s.arityError(region, s.interner.slice(s.bir.symbol(s.bir.decl(target).name)), s.params_len[target.int()], args.len);
                return s.errPair();
            }
            const encoded_args = try s.allocator.alloc(Var, args.len);
            defer s.allocator.free(encoded_args);
            const program_args = try s.allocator.alloc(Var, args.len);
            defer s.allocator.free(program_args);
            for (args, encoded_args, program_args) |arg, *encoded, *program| {
                encoded.* = arg.encoded;
                program.* = arg.program;
            }
            return .{
                .encoded = try s.store.fresh(.{ .structure = .{ .app = .{ .type = s.types.ofSchemaDecl(s.module, target, .encoded), .args = try s.store.addVars(encoded_args) } } }, TypeStore.generalized),
                .program = try s.store.fresh(.{ .structure = .{ .app = .{ .type = s.types.ofSchemaDecl(s.module, target, .type), .args = try s.store.addVars(program_args) } } }, TypeStore.generalized),
            };
        }
        try s.buildDecl(target);
        if (args.len != s.params_len[target.int()]) {
            try s.arityError(region, s.interner.slice(s.bir.symbol(s.bir.decl(target).name)), s.params_len[target.int()], args.len);
            return s.errPair();
        }
        if (args.len == 0) return s.endpoints[target.int()];
        const param_start = s.params_start[target.int()];
        const old = s.params[param_start..][0..args.len];
        const old_e = try s.allocator.alloc(Var, args.len);
        defer s.allocator.free(old_e);
        const old_p = try s.allocator.alloc(Var, args.len);
        defer s.allocator.free(old_p);
        const new_e = try s.allocator.alloc(Var, args.len);
        defer s.allocator.free(new_e);
        const new_p = try s.allocator.alloc(Var, args.len);
        defer s.allocator.free(new_p);
        for (old, args, old_e, old_p, new_e, new_p) |o, a, *oe, *op, *ne, *np| {
            oe.* = o.encoded;
            op.* = o.program;
            ne.* = a.encoded;
            np.* = a.program;
        }
        return .{ .encoded = try s.copyEndpoint(s.endpoints[target.int()].encoded, old_e, new_e), .program = try s.copyEndpoint(s.endpoints[target.int()].program, old_p, new_p) };
    }

    fn externalTarget(s: *State, module: Graph.Index, schema_i: Interface.SchemaIndex, args: []const Pair, region: Bir.Inst.Index) Allocator.Error!Pair {
        if (module.int() >= s.interfaces.len) return s.errPair();
        const iface = &s.interfaces[module.int()];
        if (@intFromEnum(schema_i) >= iface.schemas.len) return s.errPair();
        const schema = iface.schemas[@intFromEnum(schema_i)];
        if (args.len != schema.params_len) {
            try s.arityError(region, s.interner.slice(iface.symbol(schema.name)), schema.params_len, args.len);
            return s.errPair();
        }
        const encoded_args = try s.allocator.alloc(Var, args.len);
        defer s.allocator.free(encoded_args);
        const program_args = try s.allocator.alloc(Var, args.len);
        defer s.allocator.free(program_args);
        for (args, encoded_args, program_args) |arg, *encoded, *program| {
            encoded.* = arg.encoded;
            program.* = arg.program;
        }
        const type_member = iface.schema_members[schema.members_start + @intFromEnum(Interface.SchemaMember.Kind.type)];
        const encoded_member = iface.schema_members[schema.members_start + @intFromEnum(Interface.SchemaMember.Kind.encoded)];
        if (type_member.scheme == .none or encoded_member.scheme == .none) return s.errPair();
        return .{
            .encoded = try InterfaceTerms.instantiateRoot(iface, s.types.refIds(module), s.store, iface.scheme(encoded_member.scheme).body, encoded_args, TypeStore.generalized, s.allocator),
            .program = try InterfaceTerms.instantiateRoot(iface, s.types.refIds(module), s.store, iface.scheme(type_member.scheme).body, program_args, TypeStore.generalized, s.allocator),
        };
    }

    fn arityError(s: *State, region: Bir.Inst.Index, name: []const u8, expected: u32, given: usize) Allocator.Error!void {
        try s.errors.append(s.allocator, .{
            .code = .wrong_type_arity,
            .region = region,
            .message = try std.fmt.allocPrint(s.allocator, "The schema `{s}` expects {d} argument{s}, but it was given {d}.\n", .{ name, expected, if (expected == 1) "" else "s", given }),
        });
    }

    fn copyEndpoint(s: *State, root: Var, old: []const Var, new: []const Var) Allocator.Error!Var {
        const memo = try s.allocator.alloc(Var.Optional, s.store.count());
        defer s.allocator.free(memo);
        @memset(memo, .none);
        return s.copyHelp(root, old, new, memo, 0);
    }

    fn copyHelp(s: *State, raw: Var, old: []const Var, new: []const Var, memo: []Var.Optional, depth: u32) Allocator.Error!Var {
        const root = s.store.find(raw);
        for (old, new) |o, n| if (s.store.find(o) == root) return n;
        if (root.int() >= memo.len or depth > 512) return s.store.freshErr(TypeStore.generalized);
        if (memo[root.int()].unwrap()) |v| return v;
        const content = s.store.content(root);
        const out = try s.store.fresh(content, TypeStore.generalized);
        memo[root.int()] = out.toOptional();
        switch (content) {
            .err, .flex, .rigid => {},
            .structure => |shape| s.store.setContent(out, .{ .structure = switch (shape) {
                .unit, .empty_record => shape,
                .func => |f| .{ .func = .{ .params = try s.copyRange(s.store.vars(f.params), old, new, memo, depth + 1), .result = try s.copyHelp(f.result, old, new, memo, depth + 1) } },
                .app => |a| .{ .app = .{ .type = a.type, .args = try s.copyRange(s.store.vars(a.args), old, new, memo, depth + 1) } },
                .tuple => |r| .{ .tuple = try s.copyRange(s.store.vars(r), old, new, memo, depth + 1) },
                .record => |r| blk: {
                    const fields = try s.allocator.dupe(TypeStore.Field, s.store.fields(r.fields));
                    defer s.allocator.free(fields);
                    for (fields) |*f| f.value = try s.copyHelp(f.value, old, new, memo, depth + 1);
                    break :blk .{ .record = .{ .fields = try s.store.addFields(fields), .ext = try s.copyHelp(r.ext, old, new, memo, depth + 1) } };
                },
            } }),
            .alias => |a| s.store.setContent(out, .{ .alias = .{ .type = a.type, .args = try s.copyRange(s.store.vars(a.args), old, new, memo, depth + 1), .actual = try s.copyHelp(a.actual, old, new, memo, depth + 1) } }),
        }
        return out;
    }

    fn copyRange(s: *State, vars: []const Var, old: []const Var, new: []const Var, memo: []Var.Optional, depth: u32) Allocator.Error!TypeStore.Range {
        const copied = try s.allocator.alloc(Var, vars.len);
        defer s.allocator.free(copied);
        for (vars, copied) |v, *c| c.* = try s.copyHelp(v, old, new, memo, depth);
        return s.store.addVars(copied);
    }

    fn primitive(s: *State, raw: u32, region: Bir.Inst.Index) Allocator.Error!Pair {
        const tag = std.enums.fromInt(Bir.SchemaPrimitive, raw) orelse return s.errPair();
        const id = switch (tag) {
            .string => s.types.well_known.string,
            .bool => s.types.well_known.bool,
            .int => s.types.well_known.int,
            .float, .finite_float => s.types.well_known.float,
            .value => s.types.well_known.value,
            .null => {
                const never = try s.applied(s.types.well_known.never, &.{});
                const nullable = try s.applied(s.types.well_known.nullable, &.{never});
                return .{ .encoded = nullable, .program = nullable };
            },
            .list => {
                try s.arityError(region, "List", 1, 0);
                return s.errPair();
            },
        };
        const v = try s.applied(id, &.{});
        return .{ .encoded = v, .program = v };
    }

    fn primitiveApp(s: *State, raw: u32, args: []const Pair, region: Bir.Inst.Index) Allocator.Error!Pair {
        const tag = std.enums.fromInt(Bir.SchemaPrimitive, raw) orelse return s.errPair();
        if (tag != .list) {
            try s.arityError(region, primitiveName(tag), 0, args.len);
            return s.errPair();
        }
        if (args.len != 1) {
            try s.arityError(region, "List", 1, args.len);
            return s.errPair();
        }
        return .{ .encoded = try s.applied(s.types.well_known.list, &.{args[0].encoded}), .program = try s.applied(s.types.well_known.list, &.{args[0].program}) };
    }

    fn record(s: *State, owner: Bir.DeclIndex, fields: []const Bir.Inst.Index) Allocator.Error!Pair {
        const ef = try s.allocator.alloc(TypeStore.Field, fields.len);
        defer s.allocator.free(ef);
        const pf = try s.allocator.alloc(TypeStore.Field, fields.len);
        defer s.allocator.free(pf);
        var used: usize = 0;
        for (fields) |fi| {
            if (s.bir.instTag(fi) != .schema_field) continue;
            const external = s.fieldExternal(fi);
            for (fields[0..used]) |earlier| if (s.bir.instTag(earlier) == .schema_field and std.mem.eql(u8, external, s.fieldExternal(earlier))) {
                try s.errors.append(s.allocator, .{ .code = .duplicate_schema_key, .region = fi, .message = try std.fmt.allocPrint(s.allocator, "Both `{s}` and `{s}` read and write the external key `{s}`.\n", .{ s.fieldName(earlier), s.fieldName(fi), external }) });
                break;
            };
            const d = s.bir.instData(fi);
            const f = s.bir.extraData(@enumFromInt(d.rhs), Bir.SchemaField);
            const name = s.bir.symbol(@enumFromInt(d.lhs));
            var pair = try s.node(owner, f.operand);
            const modifiers = s.bir.extraSlice(.{ .start = f.modifiers_start, .end = f.modifiers_end }, Bir.Inst.Index);
            var optional = false;
            var nullable = false;
            for (modifiers) |mi| switch (s.bir.instTag(mi)) {
                .schema_optional => optional = true,
                .schema_nullable => nullable = true,
                .schema_via => {
                    const a = try s.store.freshFlex(TypeStore.generalized);
                    const expected = try s.applied(s.types.well_known.conversion, &.{ pair.program, a });
                    try s.vias.append(s.allocator, .{ .owner = owner, .field = name, .expr = @enumFromInt(s.bir.instData(mi).lhs), .expected = expected, .target = a, .region = mi });
                    pair.program = a;
                },
                else => {},
            };
            if (nullable) pair = try s.wrap(s.types.well_known.nullable, pair);
            if (optional) pair = try s.wrap(s.types.well_known.presence, pair);
            ef[used] = .{ .name = name, .value = pair.encoded };
            pf[used] = .{ .name = name, .value = pair.program };
            used += 1;
        }
        const empty_e = try s.store.fresh(.{ .structure = .empty_record }, TypeStore.generalized);
        const empty_p = try s.store.fresh(.{ .structure = .empty_record }, TypeStore.generalized);
        return .{ .encoded = try s.store.fresh(.{ .structure = .{ .record = .{ .fields = try s.store.addFields(ef[0..used]), .ext = empty_e } } }, TypeStore.generalized), .program = try s.store.fresh(.{ .structure = .{ .record = .{ .fields = try s.store.addFields(pf[0..used]), .ext = empty_p } } }, TypeStore.generalized) };
    }

    fn validateTagged(s: *State, tagged: Bir.Inst.Index) Allocator.Error!void {
        const data = s.bir.instData(tagged);
        const discriminator = s.literal(@enumFromInt(data.lhs));
        const variants = s.bir.extraSlice(s.bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
        for (variants, 0..) |vi, i| {
            const tag = s.variantExternal(vi);
            for (variants[0..i]) |earlier| if (std.mem.eql(u8, tag, s.variantExternal(earlier))) {
                try s.errors.append(s.allocator, .{ .code = .duplicate_schema_tag, .region = vi, .message = try std.fmt.allocPrint(s.allocator, "Both `{s}` and `{s}` use the tag `{s}` under discriminator `{s}`.\n", .{ s.variantName(earlier), s.variantName(vi), tag, discriminator }) });
                break;
            };
            const variant = s.bir.extraData(@enumFromInt(s.bir.instData(vi).rhs), Bir.SchemaVariant);
            const payload = variant.payload.unwrap() orelse continue;
            if (s.bir.instTag(payload) != .schema_record) continue;
            const fields = s.bir.extraSlice(Bir.inlineRange(s.bir.instData(payload)), Bir.Inst.Index);
            for (fields, 0..) |fi, field_i| {
                if (s.bir.instTag(fi) != .schema_field) continue;
                for (fields[0..field_i]) |earlier| if (s.bir.instTag(earlier) == .schema_field and std.mem.eql(u8, s.fieldExternal(fi), s.fieldExternal(earlier))) {
                    try s.errors.append(s.allocator, .{ .code = .duplicate_schema_key, .region = fi, .message = try std.fmt.allocPrint(s.allocator, "Both `{s}` and `{s}` read and write the external key `{s}`.\n", .{ s.fieldName(earlier), s.fieldName(fi), s.fieldExternal(fi) }) });
                    break;
                };
                if (s.bir.instTag(fi) == .schema_field and std.mem.eql(u8, discriminator, s.fieldExternal(fi))) {
                    try s.errors.append(s.allocator, .{ .code = .duplicate_schema_key, .region = fi, .message = try std.fmt.allocPrint(s.allocator, "The field `{s}` and tagged discriminator both read and write the external key `{s}`.\n", .{ s.fieldName(fi), discriminator }) });
                }
            }
        }
    }

    fn buildTaggedPayloads(s: *State, owner: Bir.DeclIndex, tagged: Bir.Inst.Index) Allocator.Error!void {
        const variants = s.bir.extraSlice(s.bir.subRange(@enumFromInt(s.bir.instData(tagged).rhs)), Bir.Inst.Index);
        for (variants) |vi| {
            const variant = s.bir.extraData(@enumFromInt(s.bir.instData(vi).rhs), Bir.SchemaVariant);
            const payload = variant.payload.unwrap() orelse continue;
            s.variant_payloads[vi.int()] = try s.node(owner, payload);
            s.variant_built[vi.int()] = true;
        }
    }

    fn fieldExternal(s: *const State, fi: Bir.Inst.Index) []const u8 {
        const data = s.bir.instData(fi);
        const field = s.bir.extraData(@enumFromInt(data.rhs), Bir.SchemaField);
        for (s.bir.extraSlice(.{ .start = field.modifiers_start, .end = field.modifiers_end }, Bir.Inst.Index)) |mi| {
            if (s.bir.instTag(mi) == .schema_as) return s.literal(@enumFromInt(s.bir.instData(mi).lhs));
        }
        return s.interner.slice(s.bir.symbol(@enumFromInt(data.lhs)));
    }

    fn fieldName(s: *const State, fi: Bir.Inst.Index) []const u8 {
        return s.interner.slice(s.bir.symbol(@enumFromInt(s.bir.instData(fi).lhs)));
    }
    fn variantName(s: *const State, vi: Bir.Inst.Index) []const u8 {
        return s.interner.slice(s.bir.symbol(@enumFromInt(s.bir.instData(vi).lhs)));
    }

    fn variantExternal(s: *const State, vi: Bir.Inst.Index) []const u8 {
        const data = s.bir.instData(vi);
        const variant = s.bir.extraData(@enumFromInt(data.rhs), Bir.SchemaVariant);
        if (variant.rename.unwrap()) |rename| return s.literal(rename);
        return s.interner.slice(s.bir.symbol(@enumFromInt(data.lhs)));
    }

    fn literal(s: *const State, inst: Bir.Inst.Index) []const u8 {
        if (inst.int() >= s.bir.insts.len or s.bir.instTag(inst) != .string) return "";
        const data = s.bir.instData(inst);
        if (data.lhs > s.bir.string_bytes.len or data.rhs > s.bir.string_bytes.len - data.lhs) return "";
        return s.bir.string_bytes[data.lhs..][0..data.rhs];
    }

    fn wrap(s: *State, id: Types.TypeId, p: Pair) Allocator.Error!Pair {
        return .{ .encoded = try s.applied(id, &.{p.encoded}), .program = try s.applied(id, &.{p.program}) };
    }
    fn applied(s: *State, id: Types.TypeId, args: []const Var) Allocator.Error!Var {
        if (id == .none) return s.store.freshErr(TypeStore.generalized);
        var b: Types.Builder = .init(s.store, s.types, s.graph, s.artifacts, s.module, s.bir, .flex, TypeStore.generalized, s.allocator, s.interner);
        defer b.deinit();
        return b.apply(id, args);
    }
    fn func(s: *State, args: []const Var, result: Var) Allocator.Error!Var {
        return s.store.fresh(.{ .structure = .{ .func = .{ .params = try s.store.addVars(args), .result = result } } }, TypeStore.generalized);
    }
    fn join(s: *State, a: []const Var, b: []const Var) Allocator.Error![]Var {
        const out = try s.allocator.alloc(Var, a.len + b.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        return out;
    }
    fn errPair(s: *State) Allocator.Error!Pair {
        return .{ .encoded = try s.store.freshErr(TypeStore.generalized), .program = try s.store.freshErr(TypeStore.generalized) };
    }
    fn primitiveName(tag: Bir.SchemaPrimitive) []const u8 {
        return switch (tag) {
            .string => "String",
            .bool => "Bool",
            .int => "Int",
            .float => "Float",
            .finite_float => "FiniteFloat",
            .value => "Value",
            .null => "Null",
            .list => "List",
        };
    }
    fn findTagged(s: *const State, root: Bir.Inst.Index) ?Bir.Inst.Index {
        var at = root;
        var budget = s.bir.insts.len + 1;
        while (budget > 0 and at.int() < s.bir.insts.len) : (budget -= 1) switch (s.bir.instTag(at)) {
            .schema_tagged => return at,
            .schema_value, .schema_paren => at = @enumFromInt(s.bir.instData(at).lhs),
            else => return null,
        };
        return null;
    }
};
