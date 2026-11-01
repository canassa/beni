//! Actual checked source -> immutable value origins and execution constraints.
//! docs/design/workers-native-realm-builder.md; no selected-root policy here.
const std = @import("std");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Artifacts = @import("../Artifacts.zig");
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("Dispatch.zig");
const Source = @import("RealmSource.zig");
pub const Realms = @import("Realms.zig");
pub const Values = @import("RealmValues.zig");
const Allocator = std.mem.Allocator;
const none = Realms.none;
pub const ExecId = Realms.ExecId;
pub const PortId = Realms.PortId;
pub const ScopeId = Realms.ScopeId;
pub const SiteId = Realms.SiteId;
pub const QualifiedDecl = Realms.QualifiedDecl;
pub const CallId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Input = struct {
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []const Interface,
    provenance: []const Interface.Provenance,
    dispatch: []const Dispatch,
    native_seeds: []const Realms.NativeSeed = &.{},
};
pub const Range = Values.Range;
pub const Module = struct { scopes: Range, instructions: Range, declarations: Range };
pub const Scope = struct { source: Realms.Source, original: Source.ScopeId, exec: ExecId, result: PortId, capture: PortId = .none };
pub const Declaration = struct { port: PortId, initializer: ExecId = .none };
pub const Port = struct { source: Realms.Source, scope: ScopeId = .none, origin: Values.Origin = .{} };
pub const Call = struct {
    site: SiteId,
    ambient: ExecId,
    callee: PortId,
    result: PortId,
    target: ExecId = .none,
    classification: enum(u8) { direct, residual } = .residual,
};
pub const Residual = struct { site: SiteId, port: PortId = .none, reason: Values.Reason };
pub const NativeValue = struct { target: QualifiedDecl, binding_digest: [32]u8, exec: ExecId, port: PortId, contract: Realms.NativeContract = .unavailable };
/// Value-only ordinary contract witnesses; never erase argument evaluation.
pub const ContractUse = struct { call: CallId, argument: PortId, result: PortId, native_exec: ExecId };
pub const ValueUse = struct {
    kind: enum(u8) { invocation, retention, escape },
    source: Realms.Source,
    scope: ScopeId,
    site: SiteId = .none,
    port: PortId,
    native_exec: ExecId = .none,
    call: CallId = .none,
};
pub const Work = struct {
    modules: u64 = 0,
    scopes: u64 = 0,
    ports: u64 = 0,
    calls: u64 = 0,
    edges: u64 = 0,
    residuals: u64 = 0,
    seed_reads: u64 = 0,
    value: Values.Work = .{},
};
pub const Error = Values.Error || error{ MissingSource, InvalidSource, InvalidModule, InvalidDeclaration, InvalidScope, InvalidSeed, DuplicateSeed };
pub const Output = struct {
    modules: std.MultiArrayList(Module) = .empty,
    scopes: std.MultiArrayList(Scope) = .empty,
    declarations: std.MultiArrayList(Declaration) = .empty,
    ports: std.MultiArrayList(Port) = .empty,
    calls: std.MultiArrayList(Call) = .empty,
    residuals: std.MultiArrayList(Residual) = .empty,
    native_values: std.MultiArrayList(NativeValue) = .empty,
    uses: std.MultiArrayList(ValueUse) = .empty,
    contracts: std.MultiArrayList(ContractUse) = .empty,
    execs: std.MultiArrayList(Realms.Exec) = .empty,
    sites: std.MultiArrayList(Realms.Site) = .empty,
    edges: std.MultiArrayList(Realms.Edge) = .empty,
    seeds: std.MultiArrayList(Realms.Seed) = .empty,
    work: Work = .{},
    pub fn deinit(o: *Output, gpa: Allocator) void {
        inline for (.{ "modules", "scopes", "declarations", "ports", "calls", "residuals", "native_values", "uses", "contracts", "execs", "sites", "edges", "seeds" }) |f| @field(o, f).deinit(gpa);
        o.* = .{};
    }
    pub fn input(o: *const Output) Realms.Input {
        return .{ .scope_count = @intCast(o.scopes.len), .execs = o.execs.slice(), .sites = o.sites.slice(), .edges = o.edges.slice(), .seeds = o.seeds.slice() };
    }
    fn module(o: *const Output, m: Graph.Index) Error!Module {
        if (m.int() >= o.modules.len) return error.InvalidModule;
        return o.modules.get(m.int());
    }
    pub fn declaration(o: *const Output, q: QualifiedDecl) Error!Declaration {
        const m = try o.module(q.module);
        if (q.declaration >= m.declarations.len) return error.InvalidDeclaration;
        return o.declarations.get(m.declarations.start + q.declaration);
    }
    pub fn instruction(o: *const Output, m: Graph.Index, inst: Bir.Inst.Index) Error!PortId {
        const row = try o.module(m);
        if (inst.int() >= row.instructions.len) return error.InvalidPort;
        return @fromBackingInt(row.instructions.start + inst.int());
    }
    pub fn origin(o: *const Output, p: PortId) Error!Values.Origin {
        if (@backingInt(p) >= o.ports.len) return error.InvalidPort;
        return o.ports.get(@backingInt(p)).origin;
    }
    pub fn scopeExec(o: *const Output, m: Graph.Index, s: Source.ScopeId) Error!ExecId {
        const row = try o.module(m);
        if (@backingInt(s) >= row.scopes.len) return error.InvalidScope;
        return o.scopes.get(row.scopes.start + @backingInt(s)).exec;
    }
    pub fn instructionScope(o: *const Output, m: Graph.Index, inst: Bir.Inst.Index) Error!ScopeId {
        return o.ports.get(@backingInt(try o.instruction(m, inst))).scope;
    }
    pub fn callableAt(o: *const Output, q: QualifiedDecl) Error!ExecId {
        const result = try o.origin((try o.declaration(q)).port);
        return if (result.kind == .callable) @fromBackingInt(result.value) else .none;
    }
    pub fn callableAtInstruction(o: *const Output, m: Graph.Index, inst: Bir.Inst.Index) Error!ExecId {
        const result = try o.origin(try o.instruction(m, inst));
        return if (result.kind == .callable) @fromBackingInt(result.value) else .none;
    }
    pub fn initializerOf(o: *const Output, q: QualifiedDecl) Error!ExecId {
        return (try o.declaration(q)).initializer;
    }
};

const Builder = struct {
    gpa: Allocator,
    in: Input,
    out: Output = .{},
    ops: std.MultiArrayList(Values.Op) = .empty,
    results: std.ArrayList(PortId) = .empty,
    tuple_ranges: std.ArrayList(Range) = .empty,
    tuple_ports: std.ArrayList(PortId) = .empty,
    fields: Values.Fields = .{},
    /// Exact per-instruction lexical function identity (never a type class).
    function_execs: []ExecId = &.{},
    native_index: []u32 = &.{},
    fn deinit(b: *Builder) void {
        b.out.deinit(b.gpa);
        b.ops.deinit(b.gpa);
        b.results.deinit(b.gpa);
        b.tuple_ranges.deinit(b.gpa);
        b.tuple_ports.deinit(b.gpa);
        b.fields.deinit(b.gpa);
        b.gpa.free(b.function_execs);
        b.gpa.free(b.native_index);
    }
    fn bir(b: *const Builder, m: Graph.Index) *const Bir {
        return b.in.artifacts.bir(b.in.graph.moduleFile(m));
    }
    fn port(b: *const Builder, m: Graph.Index, inst: u32) Error!PortId {
        return b.out.instruction(m, @fromBackingInt(inst));
    }
    fn set(b: *Builder, p: PortId, op: Values.Op) void {
        b.ops.set(@backingInt(p), op);
    }
    fn refPort(b: *const Builder, m: Graph.Index, ref: Source.Ref) Error!PortId {
        const q: QualifiedDecl = switch (ref.kind) {
            .top => .{ .module = m, .declaration = ref.value },
            .external => blk: {
                if (ref.module.int() >= b.in.interfaces.len) return error.InvalidModule;
                if (ref.value >= b.in.interfaces[ref.module.int()].values.len) return error.InvalidDeclaration;
                const decl = b.in.provenance[ref.module.int()].valueDecl(ref.value) orelse return error.InvalidDeclaration;
                break :blk .{ .module = ref.module, .declaration = decl.int() };
            },
            else => return .none,
        };
        return (try b.out.declaration(q)).port;
    }
    fn site(b: *Builder, source: Realms.Source, scope: ScopeId, kind: @FieldType(Realms.Site, "kind")) Error!SiteId {
        const id: SiteId = @fromBackingInt(@as(u32, @intCast(b.out.sites.len)));
        try b.out.sites.append(b.gpa, .{ .source = source, .scope = scope, .kind = kind });
        return id;
    }
    fn incomplete(b: *Builder, exec: ExecId, source: Realms.Source, p: PortId, reason: Values.Reason) Error!void {
        var row = b.out.execs.get(@backingInt(exec));
        const id = try b.site(source, row.scope, .residual);
        try b.out.residuals.append(b.gpa, .{ .site = id, .port = p, .reason = reason });
        if (row.coverage != .unavailable) {
            row.coverage = .unavailable;
            row.residual = id;
            b.out.execs.set(@backingInt(exec), row);
        }
    }
    fn allocate(b: *Builder) Error!void {
        const count = b.in.graph.count();
        if (b.in.interfaces.len != count or b.in.provenance.len != count or b.in.dispatch.len != count) return error.InvalidModule;
        for (0..count) |mi| {
            const m: Graph.Index = @fromBackingInt(@as(u32, @intCast(mi)));
            const source = &b.in.dispatch[mi].realm_sources;
            const original = b.bir(m);
            if (!source.present) return error.MissingSource;
            if (!source.verify() or source.declarations.len != original.decls.len or source.nodes.len != original.insts.len or source.locals.len != original.locals.len) return error.InvalidSource;
            const scopes: Range = .{ .start = @intCast(b.out.scopes.len), .len = @intCast(source.scopes.len) };
            const instructions: Range = .{ .start = @intCast(b.out.ports.len), .len = @intCast(source.nodes.len) };
            const declarations: Range = .{ .start = @intCast(b.out.declarations.len), .len = @intCast(source.declarations.len) };
            try b.out.modules.append(b.gpa, .{ .scopes = scopes, .instructions = instructions, .declarations = declarations });
            for (0..source.nodes.len) |ii| {
                const n = source.nodes.get(ii);
                try b.out.ports.append(b.gpa, .{ .source = .{ .module = m, .declaration = n.declaration, .instruction = @intCast(ii) }, .scope = if (n.scope == .none) .none else @fromBackingInt(scopes.start + @backingInt(n.scope)) });
            }
            for (0..source.declarations.len) |di| {
                const d = source.declarations.get(di);
                const p: PortId = @fromBackingInt(@as(u32, @intCast(b.out.ports.len)));
                try b.out.ports.append(b.gpa, .{ .source = .{ .module = m, .declaration = @intCast(di), .instruction = none }, .scope = if (d.scope == .none) .none else @fromBackingInt(scopes.start + @backingInt(d.scope)) });
                try b.out.declarations.append(b.gpa, .{ .port = p });
            }
            for (0..source.scopes.len) |si| {
                const s = source.scopes.get(si);
                const exec: ExecId = @fromBackingInt(@as(u32, @intCast(b.out.execs.len)));
                const location: Realms.Source = .{ .module = m, .declaration = s.declaration, .instruction = s.instruction };
                const result = if (s.body == none) PortId.none else try b.port(m, s.body);
                try b.out.scopes.append(b.gpa, .{ .source = location, .original = @fromBackingInt(@as(u32, @intCast(si))), .exec = exec, .result = result });
                try b.out.execs.append(b.gpa, .{ .source = location, .scope = @fromBackingInt(scopes.start + @as(u32, @intCast(si))), .coverage = .source });
                try b.results.append(b.gpa, result);
            }
        }
        try b.ops.resize(b.gpa, b.out.ports.len);
        for (0..b.ops.len) |i| b.ops.set(i, .{ .reason = .metadata });
        try b.tuple_ranges.resize(b.gpa, b.out.ports.len);
        @memset(b.tuple_ranges.items, .{});
        b.fields = try .init(b.gpa, b.out.ports.len);
        b.function_execs = try b.gpa.alloc(ExecId, b.out.ports.len);
        @memset(b.function_execs, .none);
        b.native_index = try b.gpa.alloc(u32, b.out.execs.len);
        @memset(b.native_index, none);
        for (0..b.out.scopes.len) |i| {
            const s = b.out.scopes.get(i);
            if (s.source.instruction != none) b.function_execs[@backingInt(try b.port(s.source.module, s.source.instruction))] = s.exec;
        }
    }
    fn seed(b: *Builder) Error!void {
        for (b.in.native_seeds) |s| {
            if (s.allowed & ~Realms.all != 0) return error.InvalidSeed;
            const d = try b.out.declaration(s.target);
            const module = try b.out.module(s.target.module);
            const original = &b.in.dispatch[s.target.module.int()].realm_sources;
            const scope = original.declarations.get(s.target.declaration).scope;
            if (scope == .none or original.scopes.get(@backingInt(scope)).kind != .foreign or b.bir(s.target.module).decls[s.target.declaration].kind != .foreign_value) return error.InvalidSeed;
            const exec = b.out.scopes.get(module.scopes.start + @backingInt(scope)).exec;
            if (b.native_index[@backingInt(exec)] != none) return error.DuplicateSeed;
            b.native_index[@backingInt(exec)] = @intCast(b.out.native_values.len);
            try b.out.native_values.append(b.gpa, .{ .target = s.target, .binding_digest = s.binding_digest, .exec = exec, .port = d.port, .contract = s.contract });
            try b.out.seeds.append(b.gpa, .{ .target = exec, .allowed = s.allowed, .binding_digest = s.binding_digest });
            var row = b.out.execs.get(@backingInt(exec));
            row.coverage = .native_required;
            b.out.execs.set(@backingInt(exec), row);
            b.out.work.seed_reads += 1;
        }
    }
    fn descriptors(b: *Builder) Error!void {
        for (0..b.in.graph.count()) |mi| {
            const m: Graph.Index = @fromBackingInt(@as(u32, @intCast(mi)));
            const source = &b.in.dispatch[mi].realm_sources;
            const original = b.bir(m);
            const module = try b.out.module(m);
            for (0..source.declarations.len) |di| {
                const d = source.declarations.get(di);
                if (d.scope == .none) continue;
                const s = source.scopes.get(@backingInt(d.scope));
                const exec = try b.out.scopeExec(m, d.scope);
                const decl_index = module.declarations.start + di;
                var decl = b.out.declarations.get(decl_index);
                switch (s.kind) {
                    .initializer => {
                        decl.initializer = exec;
                        b.out.declarations.set(decl_index, decl);
                        b.set(decl.port, .{ .kind = .forward, .a = @backingInt(try b.port(m, d.body)) });
                    },
                    .function, .foreign => {
                        b.set(decl.port, .{ .kind = .callable, .a = @backingInt(exec) });
                        if (s.kind == .foreign and b.native_index[@backingInt(exec)] == none)
                            try b.incomplete(exec, b.out.execs.get(@backingInt(exec)).source, decl.port, .foreign);
                    },
                }
            }
            for (0..source.nodes.len) |ii| {
                const n = source.nodes.get(ii);
                const p = try b.port(m, @intCast(ii));
                if (n.scope == .none or n.role == .pattern or n.role == .annotation) continue;
                if (n.role != .expression) {
                    b.set(p, .{ .kind = .scalar });
                    continue;
                }
                const data = original.instData(@fromBackingInt(@as(u32, @intCast(ii))));
                const op: Values.Op = switch (n.tag) {
                    .unit, .int, .float, .char, .string, .chunk => .{ .kind = .scalar },
                    .lambda => .{ .kind = .callable, .a = @backingInt(b.function_execs[@backingInt(p)]) },
                    .let_def => if (b.function_execs[@backingInt(p)] != .none)
                        .{ .kind = .callable, .a = @backingInt(b.function_execs[@backingInt(p)]) }
                    else
                        .{ .kind = .forward, .a = @backingInt(try b.port(m, data.rhs)) },
                    .let => .{ .kind = .forward, .a = @backingInt(try b.port(m, data.rhs)) },
                    .local => blk: {
                        const owner = source.declarations.get(n.declaration);
                        if (data.lhs >= owner.locals_end - owner.locals_start) return error.InvalidSource;
                        const local = source.locals.get(owner.locals_start + data.lhs);
                        const defined = source.nodes.get(local.instruction).scope;
                        if (defined != n.scope) {
                            const scope_index = module.scopes.start + @backingInt(n.scope);
                            var captured = b.out.scopes.get(scope_index);
                            if (captured.capture == .none) captured.capture = p;
                            b.out.scopes.set(scope_index, captured);
                        }
                        break :blk if (local.kind == .let)
                            .{ .kind = .forward, .a = @backingInt(try b.port(m, local.instruction)) }
                        else
                            .{ .reason = if (local.kind == .pattern) .pattern else .formal };
                    },
                    .top, .ext_value => blk: {
                        if (n.ref == none) return error.InvalidSource;
                        const target = try b.refPort(m, source.refs.get(n.ref));
                        break :blk if (target == .none) .{ .reason = .opaque_value } else .{ .kind = .forward, .a = @backingInt(target) };
                    },
                    .tuple => blk: {
                        const children = original.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
                        b.tuple_ranges.items[@backingInt(p)] = .{ .start = @intCast(b.tuple_ports.items.len), .len = @intCast(children.len) };
                        for (children) |child| try b.tuple_ports.append(b.gpa, try b.port(m, child.int()));
                        break :blk .{ .kind = .tuple };
                    },
                    .record => blk: {
                        const fields = original.extraSlice(Bir.inlineRange(data), Bir.Field);
                        if (fields.len != n.children.len) return error.InvalidSource;
                        for (fields, 0..) |field, fi| {
                            if (source.extra[n.children.start + fi] != field.value.int() or @backingInt(field.name) >= source.symbols.len) return error.InvalidSource;
                            try b.fields.put(b.gpa, p, @backingInt(source.symbols[@backingInt(field.name)]), try b.port(m, field.value.int()));
                        }
                        break :blk .{ .kind = .record };
                    },
                    .tuple_index => .{ .kind = .tuple_index, .a = @backingInt(try b.port(m, data.lhs)), .b = data.rhs },
                    .field_access => if (Source.isCall(n, source.refs)) try b.callOp(m, n, data) else blk: {
                        if (data.rhs >= source.symbols.len) return error.InvalidSource;
                        break :blk .{ .kind = .field, .a = @backingInt(try b.port(m, data.lhs)), .b = @backingInt(source.symbols[data.rhs]) };
                    },
                    .call, .method_call, .type_dispatch => try b.callOp(m, n, data),
                    .case, .@"try", .markup => .{ .reason = .unsupported_control },
                    else => .{ .reason = .opaque_value },
                };
                b.set(p, op);
                // These constructs have execution semantics outside this initial
                // source domain. Preserve their calls below, but never discharge.
                if (n.tag == .case or n.tag == .@"try" or n.tag == .markup or n.tag == .interp)
                    try b.incomplete(try b.out.scopeExec(m, n.scope), b.out.ports.get(@backingInt(p)).source, p, .unsupported_control);
            }
        }
    }
    fn callOp(b: *Builder, m: Graph.Index, n: Source.Node, data: Bir.Inst.Data) Error!Values.Op {
        if (n.blocked) return .{ .reason = .unsupported_control };
        if (n.tag == .call) return .{ .kind = .call_result, .a = @backingInt(try b.port(m, data.lhs)) };
        if (n.ref == none) return .{ .reason = .unresolved_call };
        const ref = b.in.dispatch[m.int()].realm_sources.refs.get(n.ref);
        if (ref.kind == .field and n.tag == .method_call) {
            const source = &b.in.dispatch[m.int()].realm_sources;
            if (ref.value >= source.symbols.len) return error.InvalidSource;
            return .{ .kind = .field_call_result, .a = @backingInt(try b.port(m, data.lhs)), .b = @backingInt(source.symbols[ref.value]) };
        }
        const target = try b.refPort(m, ref);
        return if (target == .none) .{ .reason = .unresolved_call } else .{ .kind = .call_result, .a = @backingInt(target) };
    }
    fn callee(b: *Builder, m: Graph.Index, n: Source.Node, data: Bir.Inst.Data) Error!PortId {
        if (n.tag == .call) return b.port(m, data.lhs);
        if (n.ref == none) return .none;
        const source = &b.in.dispatch[m.int()].realm_sources;
        const ref = source.refs.get(n.ref);
        if (ref.kind == .field and n.tag == .method_call) {
            const receiver = try b.out.origin(try b.port(m, data.lhs));
            if (receiver.kind != .record) return .none;
            if (ref.value >= source.symbols.len) return error.InvalidSource;
            return b.fields.get(@fromBackingInt(receiver.value), @backingInt(source.symbols[ref.value]));
        }
        return b.refPort(m, ref);
    }
    fn native(b: *const Builder, p: PortId) ExecId {
        if (p == .none) return .none;
        const o = b.out.ports.get(@backingInt(p)).origin;
        return if (o.kind == .callable and b.native_index[o.value] != none) @fromBackingInt(o.value) else .none;
    }
    fn callArgs(b: *const Builder, original: *const Bir, n: Source.Node, data: Bir.Inst.Data) []const Bir.Inst.Index {
        _ = b;
        return switch (n.tag) {
            .call => original.extraSlice(original.subRange(@fromBackingInt(data.rhs)), Bir.Inst.Index),
            .method_call => blk: {
                const d = original.extraData(@fromBackingInt(data.rhs), Bir.MethodCall);
                break :blk original.extraSlice(.{ .start = d.args_start, .end = d.args_end }, Bir.Inst.Index);
            },
            .type_dispatch => blk: {
                const d = original.extraData(@fromBackingInt(data.rhs), Bir.TypeDispatch);
                break :blk original.extraSlice(.{ .start = d.args_start, .end = d.args_end }, Bir.Inst.Index);
            },
            else => &.{},
        };
    }
    fn escape(b: *Builder, site_id: SiteId, call_id: CallId, p: PortId) Error!void {
        const o = try b.out.origin(p);
        if (o.kind == .scalar) return;
        const site_row = b.out.sites.get(@backingInt(site_id));
        try b.out.uses.append(b.gpa, .{ .kind = .escape, .source = site_row.source, .scope = site_row.scope, .site = site_id, .port = p, .native_exec = b.native(p), .call = call_id });
    }
    fn executions(b: *Builder) Error!void {
        for (0..b.in.graph.count()) |mi| {
            const m: Graph.Index = @fromBackingInt(@as(u32, @intCast(mi)));
            const source = &b.in.dispatch[mi].realm_sources;
            const original = b.bir(m);
            for (0..source.nodes.len) |ii| {
                const n = source.nodes.get(ii);
                if (n.scope == .none or n.role != .expression) continue;
                const p = try b.port(m, @intCast(ii));
                const row = b.out.ports.get(@backingInt(p));
                if (b.native(p) != .none) {
                    try b.out.uses.append(b.gpa, .{ .kind = .retention, .source = row.source, .scope = row.scope, .port = p, .native_exec = b.native(p) });
                }
                if (!Source.isCall(n, source.refs)) continue;
                const data = original.instData(@fromBackingInt(@as(u32, @intCast(ii))));
                const ambient = try b.out.scopeExec(m, n.scope);
                const id = try b.site(row.source, row.scope, .call);
                const cp = try b.callee(m, n, data);
                const origin: Values.Origin = if (cp == .none) .{} else try b.out.origin(cp);
                const target: ExecId = if (origin.kind == .callable) @fromBackingInt(origin.value) else .none;
                const direct = !n.blocked and target != .none;
                const ci: CallId = @fromBackingInt(@as(u32, @intCast(b.out.calls.len)));
                try b.out.calls.append(b.gpa, .{ .site = id, .ambient = ambient, .callee = cp, .result = p, .target = target, .classification = if (direct) .direct else .residual });
                if (direct) {
                    try b.out.edges.append(b.gpa, .{ .callee = target, .caller = ambient, .site = id });
                } else {
                    try b.incomplete(ambient, row.source, cp, if (n.blocked) .unsupported_control else .unresolved_call);
                }
                try b.out.uses.append(b.gpa, .{ .kind = .invocation, .source = row.source, .scope = row.scope, .site = id, .port = cp, .native_exec = b.native(cp), .call = ci });
                // No formal-use/substitution contract is established here.
                // Retain each original non-scalar argument obligation regardless
                // of callee coverage or declaration processing order. Never
                // expand aggregate/closure contents into per-native use sets.
                const args = b.callArgs(original, n, data);
                const native_exec = b.native(cp);
                const contract = if (native_exec == .none) Realms.NativeContract.unavailable else b.out.native_values.get(b.native_index[@backingInt(native_exec)]).contract;
                if (direct and n.tag == .call and args.len == 1 and contract == .unit_to_native) {
                    try b.out.contracts.append(b.gpa, .{ .call = ci, .argument = try b.port(m, args[0].int()), .result = p, .native_exec = native_exec });
                } else for (args) |arg| try b.escape(id, ci, try b.port(m, arg.int()));
                if (n.tag == .method_call or n.tag == .field_access) try b.escape(id, ci, try b.port(m, data.lhs));
            }
        }
    }
};

pub fn build(gpa: Allocator, in: Input) Error!Output {
    var b: Builder = .{ .gpa = gpa, .in = in };
    defer b.deinit();
    try b.allocate();
    try b.seed();
    try b.descriptors();
    var values = try Values.solve(gpa, .{ .ops = b.ops.slice(), .results = b.results.items, .tuple_ranges = b.tuple_ranges.items, .tuple_ports = b.tuple_ports.items, .fields = &b.fields });
    defer values.deinit(gpa);
    for (0..b.out.ports.len) |i| {
        var p = b.out.ports.get(i);
        p.origin = values.origins.get(i);
        b.out.ports.set(i, p);
    }
    try b.executions();
    b.out.work.modules = in.graph.count();
    b.out.work.scopes = b.out.scopes.len;
    b.out.work.ports = b.out.ports.len;
    b.out.work.calls = b.out.calls.len;
    b.out.work.edges = b.out.edges.len;
    b.out.work.residuals = b.out.residuals.len;
    b.out.work.value = values.work;
    b.out.work.value.fields = b.fields.work.fields;
    b.out.work.value.field_steps = b.fields.work.field_steps;
    b.out.work.value.field_queries = b.fields.work.field_queries;
    const result = b.out;
    b.out = .{};
    return result;
}
