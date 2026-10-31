//! Finite checked cursor consumer: immediate role payloads plus source templates.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Plan = @import("Plan.zig");
const Cursor = @import("TypeCursor.zig");
const NominalInspect = @import("NominalInspect.zig");
const Inspect = @This();
pub const Input = struct { cursor: Cursor.Input, plan: *const Plan };
pub const Query = struct { module: Graph.Index, declaration: u32, role: u32, local: bool, result: Cursor.ResultIndex = .none, payload: Cursor.PayloadIndex = .none };
cursor: Cursor,
queries: std.MultiArrayList(Query) = .empty,
plan: *const Plan,
rendered: []u8 = &.{},
pub fn deinit(a: *Inspect, gpa: Allocator) void {
    gpa.free(a.rendered);
    a.queries.deinit(gpa);
    a.cursor.deinit(gpa);
}
pub fn prepare(gpa: Allocator, in: Input) Cursor.Error!Inspect {
    var out: Inspect = .{ .cursor = Cursor.init(in.cursor), .plan = in.plan };
    errdefer out.deinit(gpa);
    for (in.cursor.dispatch, 0..) |*dispatch, mi| {
        const module: Graph.Index = @fromBackingInt(@intCast(mi));
        for (0..dispatch.entry_roots.roots.len) |di| {
            const row = dispatch.entry_roots.roots.get(di);
            const kind_index = in.plan.find(dispatch.decl_heads[row.decl.int()]) orelse continue;
            const kind = in.plan.kinds.get(@backingInt(kind_index));
            for (kind.roles.start..@as(usize, kind.roles.start) + kind.roles.len) |ri| {
                const role = in.plan.roles.get(ri);
                var query: Query = .{ .module = module, .declaration = row.decl.int(), .role = @intCast(ri), .local = role.kind == .local };
                if (!query.local) {
                    const root = try out.cursor.root(gpa, module, row.scheme);
                    query.result = try out.cursor.project(gpa, root, role.index, in.plan.paths.items[role.path.start..][0..role.path.len]);
                    query.payload = try out.cursor.openPayload(gpa, query.result);
                }
                try out.queries.append(gpa, query);
            }
        }
    }
    // One structural child step only; do not open these nominal payloads.
    const payload_argument_count = out.cursor.payload_results.items.len;
    for (0..payload_argument_count) |i| {
        const result = out.cursor.payload_results.items[i];
        _ = try out.cursor.childResults(gpa, result);
    }
    try out.cursor.prepareDirectory(gpa);
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    out.render(&buffer.writer) catch return error.OutOfMemory;
    out.rendered = try buffer.toOwnedSlice();
    return out;
}
pub fn write(a: *const Inspect, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.writeAll(a.rendered);
}
fn render(a: *const Inspect, out: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void {
    const c = &a.cursor;
    const in = c.in;
    try out.writeAll("type-cursor schema=1 proof=ordinary-types wire=false hostFree=false symbolicRecursion=true\n");
    for (0..a.queries.len) |i| {
        const q = a.queries.get(i);
        try out.print("  cursor-query {d} {t}:{s} decl={d} role={d}", .{ i, in.graph.modulePackage(q.module), in.interner.slice(in.graph.moduleName(q.module)), q.declaration, q.role });
        if (q.local) {
            try out.writeAll(" local-excluded\n");
            continue;
        }
        const result = c.results.get(@backingInt(q.result));
        const payload = c.payloads.get(@backingInt(q.payload));
        try out.print(" result={d} kind={t} remaining={d} payload={d}:{t}\n", .{ @backingInt(q.result), result.kind, result.remaining.len, @backingInt(q.payload), payload.kind });
    }
    for (0..c.artifacts.len) |i| {
        const artifact = c.artifacts.get(i);
        try out.print("  cursor-artifact {d} {t} {t}:{s} refs={d} terms={d}\n", .{ i, artifact.kind, in.graph.modulePackage(artifact.module), in.interner.slice(in.graph.moduleName(artifact.module)), artifact.refs.len, artifact.projections.len });
    }
    for (0..c.references.len) |i| {
        const ref = c.references.get(i);
        const id = in.types.entry(ref.type);
        try out.print("  cursor-reference artifact={d} ref={d} {t}:{s}.{s} target={d} owner={d}\n", .{ @backingInt(ref.artifact), ref.ref.int(), id.package, in.interner.slice(id.module_name), in.interner.slice(id.name), @backingInt(ref.target), @backingInt(ref.owner) });
    }
    for (0..c.scopes.len) |i| {
        const scope = c.scopes.get(i);
        try out.print("  cursor-scope {d} artifact={d} {t} index={d}\n", .{ i, @backingInt(scope.artifact), scope.kind, scope.index });
    }
    for (0..c.views.len) |i| {
        const view = c.views.get(i);
        try out.print("  cursor-view {d} artifact={d} scope={d} term={d} env={d} head={t}\n", .{ i, @backingInt(view.artifact), @backingInt(view.scope), view.term.int(), @backingInt(view.env), c.interface(view).term(view.term).tag });
    }
    for (0..c.frames.len) |i| {
        const frame = c.frames.get(i);
        try out.print("  cursor-frame {d} scope={d} args=", .{ i, @backingInt(frame.scope) });
        for (c.arguments.items[frame.arguments.start..][0..frame.arguments.len], 0..) |view, vi| {
            if (vi != 0) try out.writeByte(',');
            try out.print("{d}", .{@backingInt(view)});
        }
        try out.writeByte('\n');
    }
    for (0..c.results.len) |i| {
        const result = c.results.get(i);
        try out.print("  cursor-result {d} view={d} identityView={d} origin={d} kind={t} remaining=", .{ i, @backingInt(result.view), @backingInt(result.head_source), @backingInt(result.origin), result.kind });
        for (c.paths.items[result.remaining.start..][0..result.remaining.len]) |symbol| try out.print("{s},", .{in.interner.slice(symbol)});
        try out.writeByte('\n');
    }
    for (0..c.origins.len) |i| {
        const origin = c.origins.get(i);
        try out.print("  cursor-origin {d} parent={d} {t} source={d} target={d} selector=", .{ i, @backingInt(origin.parent), origin.kind, @backingInt(origin.source), @backingInt(origin.target) });
        if (origin.kind == .field) try out.writeAll(in.interner.slice(@fromBackingInt(origin.selector))) else try out.print("{d}", .{origin.selector});
        try out.print(" owner={d} ctor={d}\n", .{ @backingInt(origin.owner), origin.constructor });
    }
    for (0..c.payloads.len) |i| {
        const payload = c.payloads.get(i);
        try out.print("  cursor-payload {d} {t} source={d} artifact={d} owner={d} frame={d} ctors={d}+{d}\n", .{ i, payload.kind, @backingInt(payload.source), @backingInt(payload.artifact), @backingInt(payload.owner), @backingInt(payload.frame), payload.constructors.start, payload.constructors.len });
        for (payload.constructors.start..@as(usize, payload.constructors.start) + payload.constructors.len) |ci| {
            const ctor = c.constructors.get(ci);
            try out.print("    cursor-constructor {s} ordinal={d} args=", .{ in.interner.slice(ctor.name), ctor.ordinal });
            for (c.payload_results.items[ctor.arguments.start..][0..ctor.arguments.len], 0..) |result, ai| {
                if (ai != 0) try out.writeByte(',');
                try out.print("{d}", .{@backingInt(result)});
            }
            try out.writeByte('\n');
        }
    }
    for (0..c.children.len) |i| {
        const edge = c.children.get(i);
        const result = c.results.get(@backingInt(edge.result));
        const view = c.getView(result.view);
        const types = c.interface(view);
        const term = types.term(view.term);
        try out.print("  cursor-child parent={d} {t} selector=", .{ @backingInt(edge.parent), edge.kind });
        if (edge.kind == .record_field) try out.writeAll(in.interner.slice(@fromBackingInt(edge.selector))) else try out.print("{d}", .{edge.selector});
        try out.print(" result={d} head={t}", .{ @backingInt(edge.result), term.tag });
        if (term.tag == .app) {
            const ref = types.type_refs[term.lhs];
            try out.print(" nominal={t}:{s}.{s}", .{ ref.package, in.interner.slice(types.symbol(ref.module)), in.interner.slice(types.symbol(ref.name)) });
        }
        try out.writeByte('\n');
    }
    // Only imported tables absent from the exact old A prefix need printing.
    for (0..c.artifacts.len) |i| {
        const artifact = c.artifacts.get(i);
        if (artifact.kind == .nominal and !NominalInspect.needed(in.graph, artifact.module, in.dispatch, a.plan))
            try NominalInspect.write(out, in.graph, artifact.module, &in.dispatch[artifact.module.int()].nominal_layouts, in.interner);
    }
    const w = c.work;
    try out.print("cursor-work artifacts={d} references={d} projectionNodes={d} normalizeSteps={d} ownerLookups={d} payloadArgs={d} scopes={d} views={d} frames={d} origins={d} results={d}\n", .{ w.artifacts, w.references, w.projection_nodes, w.normalize_steps, w.owner_lookups, w.payload_arguments, c.scopes.len, c.views.len, c.frames.len, c.origins.len, c.results.len });
}

test "cursor inspector emits no typed prefix when only an imported declaring layout is missing" {
    const gpa = std.testing.allocator;
    var pool = try InternPool.Global.init(gpa);
    defer pool.deinit(gpa);
    const main_name = try pool.getOrPut(gpa, "Main");
    const hidden_name = try pool.getOrPut(gpa, "Hidden");
    const program_name = try pool.getOrPut(gpa, "Program");
    var graph: Graph = .empty;
    defer graph.deinit(gpa);
    var modules: std.MultiArrayList(Graph.Module) = .empty;
    try modules.append(gpa, .{ .file = @fromBackingInt(0), .package = .app, .name = main_name, .poisoned = false, .deps_start = 0, .deps_end = 0 });
    try modules.append(gpa, .{ .file = @fromBackingInt(1), .package = .core, .name = hidden_name, .poisoned = false, .deps_start = 0, .deps_end = 0 });
    graph.modules = modules.toOwnedSlice();
    graph.name_rows = try gpa.alloc(u32, @as(usize, @backingInt(hidden_name)) + 1);
    @memset(graph.name_rows, std.math.maxInt(u32));
    graph.name_rows[@backingInt(main_name)] = 0;
    graph.name_rows[@backingInt(hidden_name)] = 1;
    graph.rows = try gpa.alloc(Graph.Row, 2);
    @memset(graph.rows, .{});
    graph.rows[0].exact[@backingInt(Graph.Package.app)] = 0;
    graph.rows[1].exact[@backingInt(Graph.Package.core)] = 1;
    const Types = @import("../check/Types.zig");
    var types: Types = .empty;
    defer types.deinit(gpa);
    types.entries = try gpa.dupe(Types.Entry, &.{
        .{ .module = @fromBackingInt(0), .decl = @fromBackingInt(1), .name = program_name, .package = .app, .module_name = main_name, .arity = 1, .kind = .adt, .equatable = false, .comparable = false, .has_function = false },
        .{ .module = @fromBackingInt(1), .decl = @fromBackingInt(0), .name = hidden_name, .package = .core, .module_name = hidden_name, .arity = 0, .key_start = 1, .kind = .adt, .equatable = false, .comparable = false, .has_function = false },
    });
    types.entry_offsets = try gpa.dupe(u32, &.{ 0, 1, 2 });
    types.key_kinds = try gpa.dupe(@import("../check/TypeStore.zig").Kind, &.{.any});
    types.by_name = try gpa.dupe(Types.TypeId, &.{ @fromBackingInt(0), @fromBackingInt(1) });
    var dispatch: [2]@import("../check/Dispatch.zig") = @splat(.{});
    defer for (&dispatch) |*table| table.deinit(gpa);
    dispatch[0].decl_heads = try gpa.dupe(Types.TypeId, &.{ @fromBackingInt(0), .none });
    dispatch[0].nominal_layouts.present = true;
    const roots = &dispatch[0].entry_roots;
    roots.present = true;
    var root_rows: std.MultiArrayList(@import("../check/EntryRoots.zig").Row) = .empty;
    try root_rows.append(gpa, .{ .decl = @fromBackingInt(0), .scheme = @fromBackingInt(0) });
    roots.roots = root_rows.toOwnedSlice();
    const Interface = @import("../resolve/Interface.zig");
    var terms: std.MultiArrayList(Interface.Term) = .empty;
    try terms.append(gpa, .{ .tag = .app, .lhs = 1, .rhs = 0 });
    try terms.append(gpa, .{ .tag = .app, .lhs = 0, .rhs = 1 });
    roots.types.terms = terms.toOwnedSlice();
    roots.types.extra = try gpa.dupe(u32, &.{ 0, 1, 0 });
    roots.types.schemes = try gpa.dupe(Interface.Scheme, &.{.{ .body = @fromBackingInt(1), .quantified_start = 3, .quantified_count = 0 }});
    roots.types.symbols = try gpa.dupe(InternPool.Symbol, &.{ main_name, hidden_name, program_name });
    roots.types.type_refs = try gpa.dupe(Interface.TypeRef, &.{ .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(2) }, .{ .package = .core, .module = @fromBackingInt(1), .name = @fromBackingInt(1) } });
    // Every own nominal row is valid; only imported Hidden's artifact is absent.
    // This hermetic boundary has no BIR, so it verifies the ordinary artifact
    // predicate rather than pretending to rerun Driver's source coverage gate.
    const own = &dispatch[0].nominal_layouts;
    own.types.symbols = try gpa.dupe(InternPool.Symbol, &.{ main_name, program_name });
    own.types.type_refs = try gpa.dupe(Interface.TypeRef, &.{.{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(1) }});
    var own_terms: std.MultiArrayList(Interface.Term) = .empty;
    defer own_terms.deinit(gpa);
    try own_terms.append(gpa, .{ .tag = .@"var", .lhs = 0, .rhs = 0 });
    try own_terms.append(gpa, .{ .tag = .app, .lhs = 0, .rhs = 0 });
    try own_terms.append(gpa, .{ .tag = .tuple, .lhs = 2, .rhs = 0 });
    own.types.terms = own_terms.toOwnedSlice();
    own.types.extra = try gpa.dupe(u32, &.{ 1, 0, 1, 1, 0, std.math.maxInt(u32), 0, 0 });
    own.types.schemes = try gpa.dupe(Interface.Scheme, &.{.{ .body = @fromBackingInt(2), .quantified_start = 4, .quantified_count = 1 }});
    const Layouts = @import("../check/NominalLayouts.zig");
    var own_owners: std.MultiArrayList(Layouts.Owner) = .empty;
    defer own_owners.deinit(gpa);
    try own_owners.append(gpa, .{ .type_ref = @fromBackingInt(0), .decl = @fromBackingInt(1), .scheme = @fromBackingInt(0), .ctor_start = 0, .ctor_len = 1, .arity = 1, .kind = .adt });
    own.owners = own_owners.toOwnedSlice();
    var own_ctors: std.MultiArrayList(Layouts.Constructor) = .empty;
    defer own_ctors.deinit(gpa);
    try own_ctors.append(gpa, .{ .name = @fromBackingInt(1), .owner = 0, .ordinal = 0, .arg_start = 0, .arg_len = 0 });
    own.constructors = own_ctors.toOwnedSlice();
    try std.testing.expect(try own.verify(gpa, &pool));
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    try plan.appendRole(gpa, 0, .wire, &.{});
    plan.selected = try plan.appendKind(gpa, .{ .program = @fromBackingInt(0), .module = @fromBackingInt(0), .interface_type = @fromBackingInt(0), .arity = 1, .realm = .node, .layer = 0, .runtime = .{ .module = @fromBackingInt(0), .decl = 0, .scheme = .none }, .constructors = .{}, .launches = .{}, .roles = .{ .len = 1 } });
    plan.finish();
    const TypedInspect = @import("TypedInspect.zig");
    const input: TypedInspect.Input = .{ .graph = &graph, .artifacts = &.{}, .types = &types, .dispatch = &dispatch, .interner = &pool, .plan = &plan };
    try TypedInspect.validate(input); // Old A presence checks alone succeed.
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try std.testing.expectError(error.MissingNominalLayouts, TypedInspect.write(gpa, &output.writer, input));
    try std.testing.expectEqualStrings("", output.written());
}
