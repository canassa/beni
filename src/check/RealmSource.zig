//! Owned original-source realm events, never effect/type-class equivalence.
//! The same lexical scan constructs fresh rows and verifies installed rows.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("Dispatch.zig");
const Allocator = std.mem.Allocator;
pub const none = std.math.maxInt(u32);
pub const schema_version: u32 = 1;
pub const ScopeId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Range = struct { start: u32 = 0, len: u32 = 0 };
pub const Scope = struct {
    declaration: u32,
    instruction: u32 = none,
    parent: ScopeId = .none,
    body: u32 = none,
    parameters: Range = .{},
    kind: enum(u8) { initializer, function, foreign },
};
pub const Declaration = struct { scope: ScopeId = .none, body: u32 = none, locals_start: u32 = 0, locals_end: u32 = 0 };
pub const Ref = struct {
    kind: enum(u8) { top, external, field, unsupported },
    module: Graph.Index = @fromBackingInt(none),
    value: u32 = none,
};
pub const Role = enum(u8) { expression, pattern, annotation, literal_string, literal_list, object_list, object_pair, object_key, interpolation_chunk };
pub const IntrinsicContext = struct {
    graph: *const Graph,
    interner: *const InternPool.Global,
    interfaces: []const @import("../resolve/Interface.zig"),
};
const JsIntrinsic = @import("../js/JsIntrinsic.zig");
fn literalRoles(gpa: Allocator, bir: *const Bir, context: ?IntrinsicContext) Allocator.Error![]Role {
    const roles = try gpa.alloc(Role, bir.insts.len);
    @memset(roles, .expression);
    for (0..bir.insts.len) |at| {
        const inst: Bir.Inst.Index = @fromBackingInt(@as(u32, @intCast(at)));
        const data = bir.instData(inst);
        if (bir.instTag(inst) == .interp) {
            for (bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)) |part| {
                if (bir.instTag(part) == .chunk) roles[part.int()] = .interpolation_chunk;
            }
        }
        if (bir.instTag(inst) != .call) continue;
        const cx = context orelse continue;
        const callee: Bir.Inst.Index = @fromBackingInt(data.lhs);
        if (callee.int() >= bir.insts.len or bir.instTag(callee) != .ext_value) continue;
        const d = bir.instData(callee);
        const module: Graph.Index = @fromBackingInt(d.lhs);
        if (module.int() >= cx.graph.count() or module.int() >= cx.interfaces.len) continue;
        if (cx.graph.modulePackage(module) != .core or !std.mem.eql(u8, cx.interner.slice(cx.graph.moduleName(module)), "Js")) continue;
        @import("reads.zig").note(.iface, module);
        const iface = &cx.interfaces[module.int()];
        if (d.rhs >= iface.values.len) continue;
        const which = std.meta.stringToEnum(JsIntrinsic.Which, cx.interner.slice(iface.symbols[@backingInt(iface.values[d.rhs].name)])) orelse continue;
        const mask = JsIntrinsic.inPlaceLiterals(which);
        const args = bir.extraSlice(bir.subRange(@fromBackingInt(data.rhs)), Bir.Inst.Index);
        for (args, 0..) |arg, i| {
            if (i >= 8 or mask & (@as(u8, 1) << @intCast(i)) == 0) continue;
            if (which == .object and bir.instTag(arg) == .list) {
                const fields = bir.extraSlice(Bir.inlineRange(bir.instData(arg)), Bir.Inst.Index);
                var valid = true;
                for (fields) |field| {
                    const key = JsIntrinsic.objectKey(bir, field) orelse {
                        valid = false;
                        break;
                    };
                    if (bir.instTag(key) != .string) {
                        valid = false;
                        break;
                    }
                }
                if (valid) {
                    roles[arg.int()] = .object_list;
                    for (fields) |field| {
                        roles[field.int()] = .object_pair;
                        roles[JsIntrinsic.objectKey(bir, field).?.int()] = .object_key;
                    }
                    continue;
                }
            }
            roles[arg.int()] = switch (bir.instTag(arg)) {
                .string => .literal_string,
                .list => .literal_list,
                else => .expression,
            };
        }
    }
    return roles;
}
pub const Node = struct {
    role: Role = .expression,
    declaration: u32 = none,
    scope: ScopeId = .none,
    tag: Bir.Inst.Tag = .unit,
    lhs: u32 = 0,
    rhs: u32 = 0,
    children: Range = .{},
    ref: u32 = none,
    blocked: bool = false,
};
pub const Local = struct { instruction: u32 = none, kind: Bir.Local.Kind = .fresh };
pub const Error = Allocator.Error || error{ InvalidSource, MissingObservation, InvalidFunctionAnchor };
pub const Artifact = struct {
    present: bool = false,
    declarations: std.MultiArrayList(Declaration).Slice = .empty,
    scopes: std.MultiArrayList(Scope).Slice = .empty,
    nodes: std.MultiArrayList(Node).Slice = .empty,
    refs: std.MultiArrayList(Ref).Slice = .empty,
    locals: std.MultiArrayList(Local).Slice = .empty,
    extra: []u32 = &.{},
    symbols: []InternPool.Symbol = &.{},
    pub const empty: Artifact = .{};

    pub fn deinit(a: *Artifact, gpa: Allocator) void {
        inline for (.{ "declarations", "scopes", "nodes", "refs", "locals" }) |f| @field(a, f).deinit(gpa);
        gpa.free(a.extra);
        gpa.free(a.symbols);
        a.* = .empty;
    }
    /// Structural envelope before the common semantic source comparison.
    pub fn verify(a: *const Artifact) bool {
        if (!a.present) return a.declarations.len == 0 and a.scopes.len == 0 and a.nodes.len == 0 and a.refs.len == 0 and a.locals.len == 0 and a.extra.len == 0 and a.symbols.len == 0;
        for (0..a.declarations.len) |i| {
            const d = a.declarations.get(i);
            if (d.scope != .none and @backingInt(d.scope) >= a.scopes.len) return false;
            if (d.body != none and d.body >= a.nodes.len) return false;
            if (d.locals_start > d.locals_end or d.locals_end > a.locals.len) return false;
        }
        for (0..a.scopes.len) |i| {
            const s = a.scopes.get(i);
            if (s.declaration >= a.declarations.len or (s.instruction != none and s.instruction >= a.nodes.len)) return false;
            if (s.parent != .none and @backingInt(s.parent) >= i) return false;
            if (s.body != none and s.body >= a.nodes.len) return false;
            if (!rangeFits(a.extra.len, s.parameters)) return false;
        }
        for (0..a.nodes.len) |i| {
            const n = a.nodes.get(i);
            if (n.declaration != none and n.declaration >= a.declarations.len) return false;
            if (n.scope != .none and @backingInt(n.scope) >= a.scopes.len) return false;
            if (n.ref != none and n.ref >= a.refs.len) return false;
            if (!rangeFits(a.extra.len, n.children)) return false;
        }
        for (a.extra) |i| if (i >= a.nodes.len) return false;
        for (a.locals.items(.instruction)) |i| if (i >= a.nodes.len) return false;
        return true;
    }
    /// Rebuild complete source inventory and classifications, not merely bounds.
    /// A cached unsupported/blocked downgrade cannot hide an admitted call.
    pub fn verifyAgainstBir(a: *const Artifact, gpa: Allocator, bir: *const Bir, table: *const Dispatch) Allocator.Error!bool {
        return a.verifyAgainstBirWithIntrinsics(gpa, bir, table, null);
    }
    pub fn verifyAgainstBirWithIntrinsics(a: *const Artifact, gpa: Allocator, bir: *const Bir, table: *const Dispatch, intrinsics: ?IntrinsicContext) Allocator.Error!bool {
        return a.verifyAgainstBirWithModulesAndIntrinsics(gpa, bir, table, {}, identityModule, intrinsics);
    }
    /// Cached refs and Dispatch.Term.Ext use module_refs ordinals until install;
    /// the frontend BIR has already been resolved to current Graph identities.
    pub fn verifyAgainstBirWithModules(a: *const Artifact, gpa: Allocator, bir: *const Bir, table: *const Dispatch, context: anytype, comptime moduleId: fn (@TypeOf(context), Graph.Index) Graph.Index) Allocator.Error!bool {
        return a.verifyAgainstBirWithModulesAndIntrinsics(gpa, bir, table, context, moduleId, null);
    }
    pub fn verifyAgainstBirWithModulesAndIntrinsics(a: *const Artifact, gpa: Allocator, bir: *const Bir, table: *const Dispatch, context: anytype, comptime moduleId: fn (@TypeOf(context), Graph.Index) Graph.Index, intrinsics: ?IntrinsicContext) Allocator.Error!bool {
        if (!a.verify()) return false;
        if (!a.present) return true;
        var expected = scanWithModulesAndIntrinsics(gpa, bir, table, context, moduleId, intrinsics) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer expected.deinit(gpa);
        inline for (.{ "declarations", "scopes", "nodes", "locals" }) |f| {
            const actual = @field(a, f);
            const wanted = @field(expected, f);
            if (actual.len != wanted.len) return false;
            for (0..actual.len) |i| if (!std.meta.eql(actual.get(i), wanted.get(i))) return false;
        }
        if (a.refs.len != expected.refs.len) return false;
        for (0..a.refs.len) |i| {
            var actual = a.refs.get(i);
            if (actual.kind == .external) actual.module = moduleId(context, actual.module);
            if (!std.meta.eql(actual, expected.refs.get(i))) return false;
        }
        return std.mem.eql(u32, a.extra, expected.extra) and std.mem.eql(InternPool.Symbol, a.symbols, expected.symbols);
    }
};
fn rangeFits(len: usize, range: Range) bool {
    return range.start <= len and range.len <= len - range.start;
}

/// Which instructions were actually checked as expressions. Patterns and type
/// annotations are retained lexically but are not second type-checker inputs.
pub fn expression(tag: Bir.Inst.Tag) bool {
    return switch (tag) {
        .local,
        .top,
        .ext_value,
        .ctor,
        .ext_ctor,
        .schema_member_top,
        .schema_ctor_top,
        .ext_schema_member,
        .ext_schema_ctor,
        .int,
        .float,
        .char,
        .string,
        .chunk,
        .interp,
        .unit,
        .tuple,
        .list,
        .record,
        .record_update,
        .field_access,
        .tuple_index,
        .call,
        .method_call,
        .type_dispatch,
        .lambda,
        .let,
        .case,
        .@"try",
        .markup,
        => true,
        else => false,
    };
}
pub fn isCall(n: Node, refs: std.MultiArrayList(Ref).Slice) bool {
    return switch (n.tag) {
        .call, .method_call, .type_dispatch => true,
        .field_access => n.ref != none and switch (refs.get(n.ref).kind) {
            .top, .external, .unsupported => true,
            .field => false,
        },
        else => false,
    };
}
const Task = struct { inst: Bir.Inst.Index, declaration: u32, scope: ScopeId, blocked: bool, role: Role = .expression };

/// Visit each original body instruction/operand once; lexical function scopes
/// are independent of ordinary solver visits and of type/effect union-find.
fn identityModule(_: void, module: Graph.Index) Graph.Index {
    return module;
}
pub fn scan(gpa: Allocator, bir: *const Bir, table: *const Dispatch) Error!Artifact {
    return scanWithModules(gpa, bir, table, {}, identityModule);
}
pub fn scanWithModules(gpa: Allocator, bir: *const Bir, table: *const Dispatch, context: anytype, comptime moduleId: fn (@TypeOf(context), Graph.Index) Graph.Index) Error!Artifact {
    return scanWithModulesAndIntrinsics(gpa, bir, table, context, moduleId, null);
}
pub fn scanWithIntrinsics(gpa: Allocator, bir: *const Bir, table: *const Dispatch, intrinsics: ?IntrinsicContext) Error!Artifact {
    return scanWithModulesAndIntrinsics(gpa, bir, table, {}, identityModule, intrinsics);
}
fn scanWithModulesAndIntrinsics(gpa: Allocator, bir: *const Bir, table: *const Dispatch, context: anytype, comptime moduleId: fn (@TypeOf(context), Graph.Index) Graph.Index, intrinsics: ?IntrinsicContext) Error!Artifact {
    const literals = try literalRoles(gpa, bir, intrinsics);
    defer gpa.free(literals);
    var declarations: std.MultiArrayList(Declaration) = .empty;
    errdefer declarations.deinit(gpa);
    var scopes: std.MultiArrayList(Scope) = .empty;
    errdefer scopes.deinit(gpa);
    var nodes: std.MultiArrayList(Node) = .empty;
    errdefer nodes.deinit(gpa);
    var refs: std.MultiArrayList(Ref) = .empty;
    errdefer refs.deinit(gpa);
    var locals: std.MultiArrayList(Local) = .empty;
    errdefer locals.deinit(gpa);
    var extra: std.ArrayList(u32) = .empty;
    errdefer extra.deinit(gpa);
    var stack: std.ArrayList(Task) = .empty;
    defer stack.deinit(gpa);
    var operands: std.ArrayList(Bir.Inst.Index) = .empty;
    defer operands.deinit(gpa);
    try declarations.resize(gpa, bir.decls.len);
    for (0..declarations.len) |i| declarations.set(i, .{ .locals_start = bir.decls[i].locals_start, .locals_end = bir.decls[i].locals_end });
    try nodes.resize(gpa, bir.insts.len);
    for (0..nodes.len) |i| nodes.set(i, .{});
    for (bir.locals) |l| try locals.append(gpa, .{ .instruction = l.inst.int(), .kind = l.kind });
    for (bir.decls, 0..) |decl, di| {
        if (!decl.kind.isValue()) continue;
        const scope: ScopeId = @fromBackingInt(@as(u32, @intCast(scopes.len)));
        const top_params = bir.extraSlice(.{ .start = decl.params_start, .end = decl.params_end }, Bir.Inst.Index);
        const parameters: Range = .{ .start = @intCast(extra.items.len), .len = @intCast(top_params.len) };
        for (top_params) |param| try extra.append(gpa, param.int());
        try scopes.append(gpa, .{ .declaration = @intCast(di), .body = if (decl.body.unwrap()) |b| b.int() else none, .parameters = parameters, .kind = if (decl.body == .none) .foreign else if (decl.params == 0) .initializer else .function });
        declarations.set(di, .{ .scope = scope, .body = if (decl.body.unwrap()) |b| b.int() else none, .locals_start = decl.locals_start, .locals_end = decl.locals_end });
        if (decl.body.unwrap()) |body| try stack.append(gpa, .{ .inst = body, .declaration = @intCast(di), .scope = scope, .blocked = false });
        var param_at = top_params.len;
        while (param_at != 0) {
            param_at -= 1;
            try stack.append(gpa, .{ .inst = top_params[param_at], .declaration = @intCast(di), .scope = scope, .blocked = false, .role = .pattern });
        }
        while (stack.pop()) |task| {
            const at = task.inst.int();
            if (at >= nodes.len) return error.InvalidSource;
            const owner = bir.decls[task.declaration];
            if (at < owner.inst_start.int() or at >= owner.inst_end.int()) return error.InvalidSource;
            const previous = nodes.get(at);
            if (previous.scope != .none) {
                if (previous.scope != task.scope or previous.declaration != task.declaration or previous.blocked != task.blocked or previous.role != task.role) return error.InvalidSource;
                continue;
            }
            const tag = bir.instTag(task.inst);
            const data = bir.instData(task.inst);
            const child_start: u32 = @intCast(extra.items.len);
            operands.clearRetainingCapacity();
            try bir.operands(gpa, task.inst, &operands);
            for (operands.items) |child| try extra.append(gpa, child.int());
            var node: Node = .{ .role = if (task.role == .expression) literals[at] else task.role, .declaration = task.declaration, .scope = task.scope, .tag = tag, .lhs = data.lhs, .rhs = data.rhs, .children = .{ .start = child_start, .len = @intCast(operands.items.len) }, .blocked = task.blocked };
            var ref: ?Ref = switch (tag) {
                .top => .{ .kind = .top, .value = data.lhs },
                .ext_value => .{ .kind = .external, .module = @fromBackingInt(data.lhs), .value = data.rhs },
                .field_access => .{ .kind = .field, .value = data.rhs },
                else => null,
            };
            // Only external VALUE uses currently have a supported cross-module
            // value-port contract. Other namespaces remain explicit unsupported
            // syntax; their module ordinal is irrelevant and never persisted.
            // RHS retains its ORIGINAL namespace (ctor/schema/type), not ValueIndex.
            switch (tag) {
                .ext_value, .ext_ctor, .ext_schema_member, .ext_schema_ctor, .ext_type, .ext_schema_type, .ext_schema_target => node.lhs = 0,
                else => {},
            }
            if (tag == .method_call or tag == .type_dispatch or tag == .field_access) {
                if (table.siteOf(task.inst)) |site| {
                    if (site.callee.unwrap()) |callee| {
                        ref = switch (table.term(callee)) {
                            .top => |t| .{ .kind = .top, .value = t.decl.int() },
                            .ext => |t| .{ .kind = .external, .module = moduleId(context, t.module), .value = @backingInt(t.value) },
                            .field => .{ .kind = .field, .value = if (tag == .field_access) data.rhs else if (tag == .method_call) @backingInt(bir.extraData(@fromBackingInt(data.rhs), Bir.MethodCall).name) else none },
                            else => .{ .kind = .unsupported },
                        };
                    } else if (tag != .field_access) {
                        ref = .{ .kind = .unsupported };
                    }
                } else if (tag != .field_access) {
                    ref = .{ .kind = .unsupported };
                }
                if (ref == null) ref = .{ .kind = .unsupported };
            }
            if (ref) |r| {
                node.ref = @intCast(refs.len);
                try refs.append(gpa, r);
            }
            nodes.set(at, node);
            var child_scope = task.scope;
            var function_body: u32 = none;
            var function_params: []const Bir.Inst.Index = &.{};
            var annotation: u32 = none;
            if (tag == .lambda) {
                function_body = data.rhs;
                function_params = bir.extraSlice(bir.subRange(@fromBackingInt(data.lhs)), Bir.Inst.Index);
            } else if (tag == .let_def) {
                const def = bir.extraData(@fromBackingInt(data.lhs), Bir.LetDef);
                annotation = if (def.annotation.unwrap()) |a| a.int() else none;
                const params = bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Bir.Inst.Index);
                if (params.len != 0) {
                    function_body = data.rhs;
                    function_params = params;
                }
            }
            if (function_body != none) {
                child_scope = @fromBackingInt(@as(u32, @intCast(scopes.len)));
                const params: Range = .{ .start = @intCast(extra.items.len), .len = @intCast(function_params.len) };
                for (function_params) |param| try extra.append(gpa, param.int());
                try scopes.append(gpa, .{ .declaration = task.declaration, .instruction = at, .parent = task.scope, .body = function_body, .parameters = params, .kind = .function });
            }
            const blocked = task.blocked or tag == .case or tag == .@"try" or tag == .markup;
            var i = operands.items.len;
            while (i != 0) {
                i -= 1;
                const child = operands.items[i];
                // Parameters/patterns are lexical metadata; the actual function
                // body alone changes execution ambient. Unknown control-flow
                // branches stay blocked rather than inventing executed edges.
                const in_function = function_body != none and child.int() != annotation;
                const role: Role = if (task.role != .expression) task.role else if (child.int() == annotation) .annotation else if (in_function and child.int() != function_body) .pattern else if ((tag == .let_pattern or tag == .branch) and child.int() == data.lhs) .pattern else .expression;
                try stack.append(gpa, .{ .inst = child, .declaration = task.declaration, .scope = if (in_function) child_scope else task.scope, .blocked = if (in_function) false else blocked, .role = role });
            }
        }
    }
    const symbols = try gpa.dupe(InternPool.Symbol, bir.symbols);
    errdefer gpa.free(symbols);
    const owned_extra = try extra.toOwnedSlice(gpa);
    errdefer gpa.free(owned_extra);
    return .{ .present = true, .declarations = declarations.toOwnedSlice(), .scopes = scopes.toOwnedSlice(), .nodes = nodes.toOwnedSlice(), .refs = refs.toOwnedSlice(), .locals = locals.toOwnedSlice(), .extra = owned_extra, .symbols = symbols };
}

const TestCapture = struct {
    session: @import("../Session.zig"),
    diagnostics: std.Io.Writer.Allocating,
    fn init() !TestCapture {
        const Session = @import("../Session.zig");
        const gpa = std.testing.allocator;
        var result: TestCapture = .{
            .session = try Session.init(gpa, std.testing.io, .{ .jobs = 1, .native_realms = true, .diagnostics = .json }),
            .diagnostics = .init(gpa),
        };
        errdefer result.deinit();
        try result.session.store.addEmbedded(gpa, "Helper.beni", 0, .app,
            \\pub type Marker = Marker
            \\
            \\
            \\pub work : ⊤ → ⊤
            \\work ⊤ = ⊤
            \\
        );
        try result.session.store.addEmbedded(gpa, "Main.beni", 0, .app,
            \\import Helper as H
            \\
            \\
            \\pub initial : ⊤
            \\initial = H.work ⊤
            \\
            \\
            \\pub deferred : ⊤ → ⊤
            \\deferred = λ⊤ → H.work ⊤
            \\
            \\
            \\pub forward : ⊤ → ⊤
            \\forward = H.work
            \\
        );
        const checked = try result.session.run(&.{}, Session.check_phases, &result.diagnostics.writer);
        try std.testing.expectEqual(@as(u32, 0), checked.errors);
        try std.testing.expectEqualStrings("", result.diagnostics.written());
        return result;
    }
    fn deinit(t: *TestCapture) void {
        t.session.deinit();
        t.diagnostics.deinit();
    }
    fn module(t: *const TestCapture, name: []const u8) Graph.Index {
        return t.session.graph.lookup(.app, t.session.interner.find(name).?).?;
    }
};

test "realm source actual typed capture keeps initializer deferred and imported value identities" {
    var captured = try TestCapture.init();
    defer captured.deinit();
    const main = captured.module("Main");
    const helper = captured.module("Helper");
    const table = &captured.session.checked.dispatch[main.int()];
    const artifact = &table.realm_sources;
    try std.testing.expect(artifact.present);
    const initial = artifact.declarations.get(0).scope;
    const deferred = artifact.declarations.get(1).scope;
    try std.testing.expect(initial != deferred);
    try std.testing.expect(artifact.scopes.get(@backingInt(initial)).kind == .initializer);
    var initial_calls: usize = 0;
    var deferred_calls: usize = 0;
    var function_calls: usize = 0;
    var imported: usize = 0;
    for (0..artifact.nodes.len) |i| {
        const node = artifact.nodes.get(i);
        if (node.scope == .none) continue;
        if (isCall(node, artifact.refs)) {
            if (node.scope == initial) initial_calls += 1;
            if (node.scope == deferred) deferred_calls += 1;
            if (artifact.scopes.get(@backingInt(node.scope)).kind == .function) function_calls += 1;
        }
        if (node.ref != none) {
            const ref = artifact.refs.get(node.ref);
            if (ref.kind == .external) {
                try std.testing.expectEqual(helper, ref.module);
                try std.testing.expectEqual(@as(u32, 0), ref.value);
                const declaration = captured.session.resolution.provenance[helper.int()].valueDecl(ref.value).?;
                try std.testing.expectEqual(@as(u32, 1), declaration.int());
                imported += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), initial_calls);
    try std.testing.expectEqual(@as(usize, 0), deferred_calls);
    try std.testing.expectEqual(@as(usize, 1), function_calls);
    try std.testing.expectEqual(@as(usize, 3), imported);
    const bir = captured.session.artifacts.bir(captured.session.graph.moduleFile(main));
    try std.testing.expect(try artifact.verifyAgainstBir(std.testing.allocator, bir, table));
}

test "realm source scan releases every injected allocation failure on actual typed source" {
    var captured = try TestCapture.init();
    defer captured.deinit();
    const main = captured.module("Main");
    const bir = captured.session.artifacts.bir(captured.session.graph.moduleFile(main));
    const table = &captured.session.checked.dispatch[main.int()];
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(gpa: Allocator, b: *const Bir, d: *const Dispatch) !void {
            var artifact = try scan(gpa, b, d);
            defer artifact.deinit(gpa);
            try std.testing.expect(try artifact.verifyAgainstBir(gpa, b, d));
        }
    }.check, .{ bir, table });
}
