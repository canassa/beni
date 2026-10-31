//! Owned cross-artifact ordinary views. No Wire, HostFree or callback judgment.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Types = @import("../check/Types.zig");
const Dispatch = @import("../check/Dispatch.zig");
const InternPool = @import("../InternPool.zig");
const PrivateTerms = @import("../check/PrivateTerms.zig");
const Kernel = @import("ViewKernel.zig");
const Cursor = @This();
pub const ArtifactIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const ScopeIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const ViewIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const FrameIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const ResultIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const OriginIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const OwnerIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const PayloadIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Range = struct { start: u32 = 0, len: u32 = 0 };
pub const ArtifactKind = enum(u8) { entry, nominal };
pub const ScopeKind = enum(u8) { scheme, alias_formals };
pub const Artifact = struct { module: Graph.Index, kind: ArtifactKind, refs: Range, projections: Range, owners: Range, scopes: Range };
pub const Scope = struct { artifact: ArtifactIndex, kind: ScopeKind, index: u32 };
pub const View = struct { artifact: ArtifactIndex, term: Interface.TermIndex, scope: ScopeIndex, env: FrameIndex = .none };
pub const Frame = struct { scope: ScopeIndex, arguments: Range };
pub const OriginKind = enum(u8) { root, normalize, parameter, field, extension, payload, payload_head, type_argument, function_argument, function_result, tuple_field, record_extension };
pub const Origin = struct { parent: OriginIndex = .none, kind: OriginKind, source: ViewIndex, target: ViewIndex, selector: u32 = 0, owner: OwnerIndex = .none, constructor: u32 = std.math.maxInt(u32) };
pub const ResultKind = enum(u8) { complete, obligation, shape_mismatch };
pub const Result = struct { view: ViewIndex, head_source: ViewIndex, origin: OriginIndex, kind: ResultKind = .complete, remaining: Range = .{} };
pub const PayloadKind = enum(u8) { not_nominal, obligation, adt, native_contract_unavailable, schema_type_contract_unavailable, schema_encoded_contract_unavailable };
pub const Payload = struct { kind: PayloadKind, source: ResultIndex, artifact: ArtifactIndex = .none, owner: OwnerIndex = .none, frame: FrameIndex = .none, constructors: Range = .{} };
pub const Constructor = struct { name: InternPool.Symbol, ordinal: u32, arguments: Range };
pub const Reference = struct { artifact: ArtifactIndex, ref: Interface.TypeRefIndex, type: Types.TypeId, target: ArtifactIndex = .none, owner: OwnerIndex = .none };
pub const ChildKind = enum(u8) { argument, function_result, tuple_field, record_field, record_extension };
pub const Child = struct { parent: ResultIndex, kind: ChildKind, selector: u32, result: ResultIndex };
pub const Work = struct { artifacts: u64 = 0, references: u64 = 0, projection_nodes: u64 = 0, normalize_steps: u64 = 0, owner_lookups: u64 = 0, payload_arguments: u64 = 0 };
pub const Input = struct { graph: *const Graph, types: *const Types, dispatch: []const Dispatch, interner: *const InternPool.Global };
pub const Error = Allocator.Error || error{ MissingEntryRoots, MissingNominalLayouts, MissingIdentity, InvalidScope, InvalidOwner };
in: Input,
slots: []ArtifactIndex,
artifacts: std.MultiArrayList(Artifact) = .empty,
scopes: std.MultiArrayList(Scope) = .empty,
views: std.MultiArrayList(View) = .empty,
frames: std.MultiArrayList(Frame) = .empty,
results: std.MultiArrayList(Result) = .empty,
origins: std.MultiArrayList(Origin) = .empty,
payloads: std.MultiArrayList(Payload) = .empty,
constructors: std.MultiArrayList(Constructor) = .empty,
references: std.MultiArrayList(Reference) = .empty,
children: std.MultiArrayList(Child) = .empty,
ref_ids: std.ArrayList(Types.TypeId) = .empty,
projection_nodes: std.ArrayList(u32) = .empty,
owner_indices: std.ArrayList(OwnerIndex) = .empty,
scope_indices: std.ArrayList(ScopeIndex) = .empty,
arguments: std.ArrayList(ViewIndex) = .empty,
payload_results: std.ArrayList(ResultIndex) = .empty,
paths: std.ArrayList(InternPool.Symbol) = .empty,
work: Work = .{},
directory_next: u32 = 0,
pub fn init(in: Input) Cursor {
    return .{ .in = in, .slots = &.{} };
}
pub fn noteStep(c: *Cursor) void {
    c.work.normalize_steps += 1;
}
pub fn deinit(c: *Cursor, gpa: Allocator) void {
    gpa.free(c.slots);
    inline for (.{ "artifacts", "scopes", "views", "frames", "results", "origins", "payloads", "constructors", "references", "children", "ref_ids", "projection_nodes", "owner_indices", "scope_indices", "arguments", "payload_results", "paths" }) |field| @field(c, field).deinit(gpa);
    c.slots = &.{};
}
pub fn artifactTypes(c: *const Cursor, index: ArtifactIndex) *const Interface {
    const a = c.artifacts.get(@backingInt(index));
    const table = &c.in.dispatch[a.module.int()];
    return switch (a.kind) {
        .entry => &table.entry_roots.types,
        .nominal => &table.nominal_layouts.types,
    };
}
pub fn interface(c: *const Cursor, view: View) *const Interface {
    return c.artifactTypes(view.artifact);
}
pub fn register(c: *Cursor, gpa: Allocator, module: Graph.Index, kind: ArtifactKind) Error!ArtifactIndex {
    if (c.slots.len == 0) {
        c.slots = try gpa.alloc(ArtifactIndex, c.in.dispatch.len * 2);
        @memset(c.slots, .none);
    }
    const slot = @as(usize, module.int()) * 2 + @as(usize, @backingInt(kind));
    if (slot >= c.slots.len) return error.MissingIdentity;
    if (c.slots[slot] != .none) return c.slots[slot];
    const table = &c.in.dispatch[module.int()];
    const types = switch (kind) {
        .entry => if (table.entry_roots.present) &table.entry_roots.types else return error.MissingEntryRoots,
        .nominal => if (table.nominal_layouts.present) &table.nominal_layouts.types else return error.MissingNominalLayouts,
    };
    const refs: Range = .{ .start = @intCast(c.ref_ids.items.len), .len = @intCast(types.type_refs.len) };
    for (types.type_refs) |ref| {
        const id = c.in.types.find(c.in.graph, ref.package, types.symbol(ref.module), types.symbol(ref.name));
        if (id == .none) return error.MissingIdentity;
        try c.ref_ids.append(gpa, id);
        c.work.references += 1;
    }
    const heads = try Kernel.projections(gpa, types);
    defer gpa.free(heads);
    const projections: Range = .{ .start = @intCast(c.projection_nodes.items.len), .len = @intCast(heads.len) };
    try c.projection_nodes.appendSlice(gpa, heads);
    c.work.projection_nodes += heads.len;
    const scopes: Range = .{ .start = @intCast(c.scope_indices.items.len), .len = @intCast(types.schemes.len + types.type_refs.len) };
    try c.scope_indices.appendNTimes(gpa, .none, scopes.len);
    var owners: Range = .{};
    if (kind == .nominal) {
        const first = c.in.types.entry_offsets[module.int()];
        const last = c.in.types.entry_offsets[module.int() + 1];
        owners = .{ .start = @intCast(c.owner_indices.items.len), .len = last - first };
        try c.owner_indices.appendNTimes(gpa, .none, owners.len);
        for (0..table.nominal_layouts.owners.len) |oi| {
            const layout_owner = table.nominal_layouts.owners.get(oi);
            const id = c.ref_ids.items[refs.start + layout_owner.type_ref.int()];
            if (id.int() < first or id.int() >= last or c.in.types.entry(id).module != module) return error.InvalidOwner;
            c.owner_indices.items[owners.start + id.int() - first] = @fromBackingInt(@intCast(oi));
        }
    }
    const index: ArtifactIndex = @fromBackingInt(@intCast(c.artifacts.len));
    try c.artifacts.append(gpa, .{ .module = module, .kind = kind, .refs = refs, .projections = projections, .owners = owners, .scopes = scopes });
    c.slots[slot] = index;
    c.work.artifacts += 1;
    return index;
}
fn scope(c: *Cursor, gpa: Allocator, artifact: ArtifactIndex, kind: ScopeKind, index: u32) Error!ScopeIndex {
    const types = c.artifactTypes(artifact);
    const a = c.artifacts.get(@backingInt(artifact));
    switch (kind) {
        .scheme => if (index >= types.schemes.len) return error.InvalidScope,
        .alias_formals => if (index >= types.type_refs.len or types.type_refs[index].body == .none) return error.InvalidScope,
    }
    const at = a.scopes.start + index + (if (kind == .alias_formals) @as(u32, @intCast(types.schemes.len)) else 0);
    if (at >= a.scopes.start + a.scopes.len) return error.InvalidScope;
    if (c.scope_indices.items[at] != .none) return c.scope_indices.items[at];
    const result: ScopeIndex = @fromBackingInt(@intCast(c.scopes.len));
    try c.scopes.append(gpa, .{ .artifact = artifact, .kind = kind, .index = index });
    c.scope_indices.items[at] = result;
    return result;
}
pub fn getView(c: *const Cursor, index: ViewIndex) View {
    return c.views.get(@backingInt(index));
}
pub fn add(c: *Cursor, gpa: Allocator, view: View) Error!ViewIndex {
    const index: ViewIndex = @fromBackingInt(@intCast(c.views.len));
    try c.views.append(gpa, view);
    return index;
}
pub fn actual(c: *const Cursor, view: View, parameter: u32) Error!?View {
    if (view.env == .none) {
        if (c.scopes.get(@backingInt(view.scope)).kind != .scheme) return error.InvalidScope;
        return null;
    }
    const frame = c.frames.get(@backingInt(view.env));
    if (frame.scope != view.scope or parameter >= frame.arguments.len) return error.InvalidScope;
    return c.getView(c.arguments.items[frame.arguments.start + parameter]);
}
pub fn projection(c: *const Cursor, view: View, body: Interface.TermIndex) ?u32 {
    const a = c.artifacts.get(@backingInt(view.artifact));
    const parameter = c.projection_nodes.items[a.projections.start + body.int()];
    return if (parameter == PrivateTerms.no_projection) null else parameter;
}
pub fn alias(c: *Cursor, gpa: Allocator, original: View, term: Interface.Term) Error!View {
    const types = c.interface(original);
    const target = try c.scope(gpa, original.artifact, .alias_formals, term.lhs);
    const arguments: Range = .{ .start = @intCast(c.arguments.items.len), .len = @intCast(types.range(term.rhs).len) };
    for (types.range(term.rhs)) |arg| {
        var argument_view = original;
        argument_view.term = @fromBackingInt(arg);
        const index = try c.add(gpa, argument_view);
        try c.arguments.append(gpa, index);
    }
    const frame: FrameIndex = @fromBackingInt(@intCast(c.frames.len));
    try c.frames.append(gpa, .{ .scope = target, .arguments = arguments });
    return .{ .artifact = original.artifact, .scope = target, .term = types.type_refs[term.lhs].body, .env = frame };
}
fn finish(c: *Cursor, gpa: Allocator, view: ViewIndex, parent: OriginIndex, kind: OriginKind, source: ViewIndex, selector: u32, owner_index: OwnerIndex) Error!ResultIndex {
    const origin: OriginIndex = @fromBackingInt(@intCast(c.origins.len));
    try c.origins.append(gpa, .{ .parent = parent, .kind = kind, .source = source, .target = view, .selector = selector, .owner = owner_index });
    const result: ResultIndex = @fromBackingInt(@intCast(c.results.len));
    try c.results.append(gpa, .{ .view = view, .head_source = view, .origin = origin });
    return result;
}
pub fn root(c: *Cursor, gpa: Allocator, module: Graph.Index, scheme: Interface.SchemeIndex) Error!ResultIndex {
    const artifact = try c.register(gpa, module, .entry);
    const types = c.artifactTypes(artifact);
    const lexical = try c.scope(gpa, artifact, .scheme, @backingInt(scheme));
    const view = try c.add(gpa, .{ .artifact = artifact, .term = types.scheme(scheme).body, .scope = lexical });
    return c.finish(gpa, view, .none, .root, view, @backingInt(scheme), .none);
}
pub fn normalize(c: *Cursor, gpa: Allocator, result: ResultIndex) Error!ResultIndex {
    const original = c.results.get(@backingInt(result));
    const view = try Kernel.normalize(Cursor, c, gpa, original.view, false);
    const next = try c.finish(gpa, view, original.origin, .normalize, original.view, 0, .none);
    c.results.items(.head_source)[@backingInt(next)] = original.head_source;
    c.results.items(.kind)[@backingInt(next)] = original.kind;
    c.results.items(.remaining)[@backingInt(next)] = original.remaining;
    return next;
}
fn child(c: *Cursor, gpa: Allocator, parent: ResultIndex, term: Interface.TermIndex, kind: OriginKind, selector: u32) Error!ResultIndex {
    const result = c.results.get(@backingInt(parent));
    var view = c.getView(result.view);
    view.term = term;
    return c.finish(gpa, try c.add(gpa, view), result.origin, kind, result.view, selector, .none);
}
pub fn project(c: *Cursor, gpa: Allocator, root_result: ResultIndex, parameter: u32, path: []const InternPool.Symbol) Error!ResultIndex {
    var result = try c.normalize(gpa, root_result);
    const view = c.getView(c.results.get(@backingInt(result)).view);
    const types = c.interface(view);
    const head = types.term(view.term);
    if (head.tag != .app or parameter >= types.range(head.rhs).len) return c.remaining(gpa, result, .shape_mismatch, path);
    result = try c.child(gpa, result, @fromBackingInt(types.range(head.rhs)[parameter]), .parameter, parameter);
    return c.projectFields(gpa, result, path);
}
pub fn projectFields(c: *Cursor, gpa: Allocator, original: ResultIndex, path: []const InternPool.Symbol) Error!ResultIndex {
    var result = original;
    var view: View = undefined;
    for (path, 0..) |symbol, path_step| {
        result = try c.normalize(gpa, result);
        while (true) {
            view = c.getView(c.results.get(@backingInt(result)).view);
            switch (Kernel.field(c.interface(view), view.term, symbol)) {
                .generic => return c.remaining(gpa, result, .obligation, path[path_step..]),
                .mismatch => return c.remaining(gpa, result, .shape_mismatch, path[path_step..]),
                .child => |term| {
                    result = try c.child(gpa, result, term, .field, @backingInt(symbol));
                    break;
                },
                .extension => |term| result = try c.normalize(gpa, try c.child(gpa, result, term, .extension, 0)),
            }
        }
    }
    return c.normalize(gpa, result);
}
pub fn childResults(c: *Cursor, gpa: Allocator, original: ResultIndex) Error!Range {
    const result = try c.normalize(gpa, original);
    const view = c.getView(c.results.get(@backingInt(result)).view);
    const types = c.interface(view);
    const term = types.term(view.term);
    const start: u32 = @intCast(c.children.len);
    switch (term.tag) {
        .app, .tuple, .func => {
            const args = types.range(if (term.tag == .app) term.rhs else term.lhs);
            for (args, 0..) |arg, i| try c.appendChild(gpa, result, @fromBackingInt(arg), if (term.tag == .tuple) .tuple_field else .argument, @intCast(i));
            if (term.tag == .func) try c.appendChild(gpa, result, @fromBackingInt(term.rhs), .function_result, 0);
        },
        .record => {
            const fields = types.range(term.lhs);
            var i: usize = 0;
            while (i < fields.len) : (i += 2) try c.appendChild(gpa, result, @fromBackingInt(fields[i + 1]), .record_field, @backingInt(types.symbol(@fromBackingInt(fields[i]))));
            try c.appendChild(gpa, result, @fromBackingInt(term.rhs), .record_extension, 0);
        },
        else => {},
    }
    return .{ .start = start, .len = @as(u32, @intCast(c.children.len)) - start };
}
fn appendChild(c: *Cursor, gpa: Allocator, parent: ResultIndex, term: Interface.TermIndex, kind: ChildKind, selector: u32) Error!void {
    const parent_view = c.getView(c.results.get(@backingInt(parent)).view);
    const origin_kind: OriginKind = switch (kind) {
        .argument => if (c.interface(parent_view).term(parent_view.term).tag == .func) .function_argument else .type_argument,
        .function_result => .function_result,
        .tuple_field => .tuple_field,
        .record_field => .field,
        .record_extension => .record_extension,
    };
    const result = try c.normalize(gpa, try c.child(gpa, parent, term, origin_kind, selector));
    try c.children.append(gpa, .{ .parent = parent, .kind = kind, .selector = selector, .result = result });
}
fn remaining(c: *Cursor, gpa: Allocator, result: ResultIndex, kind: ResultKind, path: []const InternPool.Symbol) Error!ResultIndex {
    var copy = c.results.get(@backingInt(result));
    copy.kind = kind;
    copy.remaining = .{ .start = @intCast(c.paths.items.len), .len = @intCast(path.len) };
    try c.paths.appendSlice(gpa, path);
    const index: ResultIndex = @fromBackingInt(@intCast(c.results.len));
    try c.results.append(gpa, copy);
    return index;
}
fn owner(c: *Cursor, gpa: Allocator, id: Types.TypeId) Error!struct { artifact: ArtifactIndex, index: OwnerIndex } {
    c.work.owner_lookups += 1;
    const entry = c.in.types.entry(id);
    const artifact = try c.register(gpa, entry.module, .nominal);
    const a = c.artifacts.get(@backingInt(artifact));
    const offset = id.int() - c.in.types.entry_offsets[entry.module.int()];
    if (offset >= a.owners.len) return error.InvalidOwner;
    const index = c.owner_indices.items[a.owners.start + offset];
    if (index == .none) return error.InvalidOwner;
    return .{ .artifact = artifact, .index = index };
}
pub fn boundary(c: *const Cursor, view: View, term: Interface.Term) bool {
    const a = c.artifacts.get(@backingInt(view.artifact));
    return c.in.types.entry(c.ref_ids.items[a.refs.start + term.lhs]).schema_endpoint;
}
pub fn openPayload(c: *Cursor, gpa: Allocator, original: ResultIndex) Error!PayloadIndex {
    const before = c.results.get(@backingInt(original));
    const head = try Kernel.normalize(Cursor, c, gpa, before.head_source, true);
    const result = try c.finish(gpa, head, before.origin, .payload_head, before.head_source, 0, .none);
    c.results.items(.head_source)[@backingInt(result)] = before.head_source;
    c.results.items(.kind)[@backingInt(result)] = before.kind;
    c.results.items(.remaining)[@backingInt(result)] = before.remaining;
    const normalized = c.results.get(@backingInt(result));
    const view = c.getView(normalized.view);
    const types = c.interface(view);
    const term = types.term(view.term);
    var payload: Payload = .{ .kind = if (term.tag == .@"var") .obligation else .not_nominal, .source = result };
    if (normalized.kind == .shape_mismatch) payload.kind = .not_nominal;
    if ((term.tag == .app or term.tag == .alias) and normalized.kind != .shape_mismatch) {
        const a = c.artifacts.get(@backingInt(view.artifact));
        const resolved = try c.owner(gpa, c.ref_ids.items[a.refs.start + term.lhs]);
        const artifact = c.artifacts.get(@backingInt(resolved.artifact));
        const layout = &c.in.dispatch[artifact.module.int()].nominal_layouts;
        const row = layout.owners.get(@backingInt(resolved.index));
        payload.artifact = resolved.artifact;
        payload.owner = resolved.index;
        payload.kind = switch (row.kind) {
            .adt => .adt,
            .native_opaque => .native_contract_unavailable,
            .schema_type => .schema_type_contract_unavailable,
            .schema_encoded => .schema_encoded_contract_unavailable,
        };
        if (row.kind == .adt) {
            const actuals = types.range(term.rhs);
            if (actuals.len != row.arity) return error.InvalidOwner;
            const target = try c.scope(gpa, resolved.artifact, .scheme, @backingInt(row.scheme));
            const range: Range = .{ .start = @intCast(c.arguments.items.len), .len = @intCast(actuals.len) };
            for (actuals) |arg| {
                var actual_view = view;
                actual_view.term = @fromBackingInt(arg);
                const index = try c.add(gpa, actual_view);
                try c.arguments.append(gpa, index);
            }
            payload.frame = @fromBackingInt(@intCast(c.frames.len));
            try c.frames.append(gpa, .{ .scope = target, .arguments = range });
            payload.constructors = .{ .start = @intCast(c.constructors.len), .len = row.ctor_len };
            for (row.ctor_start..@as(usize, row.ctor_start) + row.ctor_len) |ci| {
                const ctor = layout.constructors.get(ci);
                const args: Range = .{ .start = @intCast(c.payload_results.items.len), .len = ctor.arg_len };
                for (layout.arguments[ctor.arg_start..][0..ctor.arg_len], 0..) |arg, ai| {
                    const target_view = try c.add(gpa, .{ .artifact = resolved.artifact, .scope = target, .term = arg, .env = payload.frame });
                    const argument = try c.finish(gpa, target_view, normalized.origin, .payload, normalized.view, @intCast(ai), resolved.index);
                    c.origins.items(.constructor)[@backingInt(c.results.get(@backingInt(argument)).origin)] = @intCast(ci);
                    const head_result = try c.normalize(gpa, argument);
                    try c.payload_results.append(gpa, head_result);
                    c.work.payload_arguments += 1;
                }
                try c.constructors.append(gpa, .{ .name = layout.types.symbol(ctor.name), .ordinal = ctor.ordinal, .arguments = args });
            }
        }
    }
    const index: PayloadIndex = @fromBackingInt(@intCast(c.payloads.len));
    try c.payloads.append(gpa, payload);
    return index;
}
/// Source-finite directory: each artifact's refs once, never instantiated tuples.
pub fn prepareDirectory(c: *Cursor, gpa: Allocator) Error!void {
    while (c.directory_next < c.artifacts.len) : (c.directory_next += 1) {
        const ai = c.directory_next;
        const a = c.artifacts.get(ai);
        for (0..a.refs.len) |ri| {
            const id = c.ref_ids.items[a.refs.start + ri];
            var ref: Reference = .{ .artifact = @fromBackingInt(@intCast(ai)), .ref = @fromBackingInt(@intCast(ri)), .type = id };
            if (c.in.types.entry(id).kind != .alias or c.in.types.entry(id).schema_endpoint) {
                const resolved = try c.owner(gpa, id);
                ref.target = resolved.artifact;
                ref.owner = resolved.index;
            }
            try c.references.append(gpa, ref);
        }
    }
}

test "cross artifact payload results retain actual binder scope after owner frame growth and path mutation" {
    const gpa = std.testing.allocator;
    var pool = try InternPool.Global.init(gpa);
    defer pool.deinit(gpa);
    const name = try pool.getOrPut(gpa, "a");
    const missing = try pool.getOrPut(gpa, "missing");
    const changed = try pool.getOrPut(gpa, "changed");
    var dispatch: [2]Dispatch = @splat(.{});
    defer for (&dispatch) |*table| table.deinit(gpa);
    const helper = struct {
        fn terms(allocator: Allocator, fields: []const Interface.Term) !std.MultiArrayList(Interface.Term).Slice {
            var rows: std.MultiArrayList(Interface.Term) = .empty;
            errdefer rows.deinit(allocator);
            for (fields) |row| try rows.append(allocator, row);
            return rows.toOwnedSlice();
        }
    };
    const root_types = &dispatch[0].entry_roots.types;
    root_types.terms = try helper.terms(gpa, &.{ .{ .tag = .@"var", .lhs = 0, .rhs = 0 }, .{ .tag = .app, .lhs = 0, .rhs = 1 }, .{ .tag = .app, .lhs = 1, .rhs = 3 } });
    root_types.extra = try gpa.dupe(u32, &.{ 0, 1, 0, 1, 1, 0, 0, 0, 0 });
    root_types.schemes = try gpa.dupe(Interface.Scheme, &.{.{ .body = @fromBackingInt(2), .quantified_start = 5, .quantified_count = 1 }});
    root_types.symbols = try gpa.dupe(InternPool.Symbol, &.{name});
    root_types.type_refs = try gpa.dupe(Interface.TypeRef, &.{ .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(0) }, .{ .package = .platform, .module = @fromBackingInt(0), .name = @fromBackingInt(0) } });
    dispatch[0].entry_roots.present = true;
    const layout = &dispatch[1].nominal_layouts;
    layout.present = true;
    layout.types.terms = try helper.terms(gpa, &.{ .{ .tag = .@"var", .lhs = 0, .rhs = 0 }, .{ .tag = .app, .lhs = 0, .rhs = 1 }, .{ .tag = .tuple, .lhs = 3, .rhs = 0 } });
    layout.types.extra = try gpa.dupe(u32, &.{ 0, 1, 0, 2, 1, 0, 0, 0, 0, 0 });
    layout.types.schemes = try gpa.dupe(Interface.Scheme, &.{.{ .body = @fromBackingInt(2), .quantified_start = 6, .quantified_count = 1 }});
    layout.types.symbols = try gpa.dupe(InternPool.Symbol, &.{name});
    layout.types.type_refs = try gpa.dupe(Interface.TypeRef, &.{.{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(0) }});
    var owners: std.MultiArrayList(@import("../check/NominalLayouts.zig").Owner) = .empty;
    try owners.append(gpa, .{ .type_ref = @fromBackingInt(0), .decl = @fromBackingInt(0), .scheme = @fromBackingInt(0), .ctor_start = 0, .ctor_len = 1, .arity = 1, .kind = .adt });
    layout.owners = owners.toOwnedSlice();
    var ctors: std.MultiArrayList(@import("../check/NominalLayouts.zig").Constructor) = .empty;
    try ctors.append(gpa, .{ .name = @fromBackingInt(0), .owner = 0, .ordinal = 0, .arg_start = 0, .arg_len = 1 });
    layout.constructors = ctors.toOwnedSlice();
    layout.arguments = try gpa.dupe(Interface.TermIndex, &.{@fromBackingInt(0)});
    var entries = [_]Types.Entry{ .{ .module = @fromBackingInt(0), .decl = @fromBackingInt(0), .name = name, .package = .platform, .module_name = name, .arity = 1, .kind = .adt, .equatable = false, .comparable = false, .has_function = false }, .{ .module = @fromBackingInt(1), .decl = @fromBackingInt(0), .name = name, .package = .app, .module_name = name, .arity = 1, .kind = .adt, .equatable = false, .comparable = false, .has_function = false } };
    var offsets = [_]u32{ 0, 1, 2 };
    var types: Types = .empty;
    types.entries = &entries;
    types.entry_offsets = &offsets;
    var cursor: Cursor = .init(.{ .graph = &Graph.empty, .types = &types, .dispatch = &dispatch, .interner = &pool });
    defer cursor.deinit(gpa);
    // Seed a checked, immutable registry: production registration resolves these
    // identities through Types.find; this pure boundary starts after that step.
    cursor.slots = try gpa.dupe(ArtifactIndex, &.{ @fromBackingInt(0), .none, .none, @fromBackingInt(1) });
    try cursor.artifacts.append(gpa, .{ .module = @fromBackingInt(0), .kind = .entry, .refs = .{ .len = 2 }, .projections = .{ .len = 3 }, .owners = .{}, .scopes = .{ .len = 3 } });
    try cursor.artifacts.append(gpa, .{ .module = @fromBackingInt(1), .kind = .nominal, .refs = .{ .start = 2, .len = 1 }, .projections = .{ .start = 3, .len = 3 }, .owners = .{ .len = 1 }, .scopes = .{ .start = 3, .len = 2 } });
    try cursor.ref_ids.appendSlice(gpa, &.{ @fromBackingInt(1), @fromBackingInt(0), @fromBackingInt(1) });
    try cursor.projection_nodes.appendSlice(gpa, &.{ 0, PrivateTerms.no_projection, PrivateTerms.no_projection, 0, PrivateTerms.no_projection, PrivateTerms.no_projection });
    try cursor.owner_indices.append(gpa, @fromBackingInt(0));
    try cursor.scope_indices.appendNTimes(gpa, .none, 5);
    try std.testing.expectError(error.InvalidScope, cursor.root(gpa, @fromBackingInt(0), @fromBackingInt(1)));
    try std.testing.expectError(error.InvalidScope, cursor.scope(gpa, @fromBackingInt(0), .alias_formals, 2));
    try std.testing.expectError(error.InvalidScope, cursor.scope(gpa, @fromBackingInt(0), .alias_formals, 0));
    const root_result = try cursor.root(gpa, @fromBackingInt(0), @fromBackingInt(0));
    const selected = try cursor.project(gpa, root_result, 0, &.{});
    const first = try cursor.openPayload(gpa, selected);
    const payload = cursor.payloads.get(@backingInt(first));
    const ctor = cursor.constructors.get(payload.constructors.start);
    const wrong_scope: View = .{ .artifact = @fromBackingInt(0), .scope = @fromBackingInt(0), .term = @fromBackingInt(0), .env = payload.frame };
    try std.testing.expectError(error.InvalidScope, cursor.actual(wrong_scope, 0));
    const returned = cursor.payload_results.items[ctor.arguments.start];
    const snapshot = cursor.results.get(@backingInt(returned));
    const expected: View = .{ .artifact = @fromBackingInt(0), .scope = @fromBackingInt(0), .term = @fromBackingInt(0) };
    try std.testing.expectEqualDeep(expected, cursor.getView(snapshot.view));
    var requested = [_]InternPool.Symbol{missing};
    const obligation = try cursor.projectFields(gpa, returned, &requested);
    requested[0] = changed;
    for (0..128) |_| _ = try cursor.openPayload(gpa, selected);
    try std.testing.expectEqualDeep(snapshot, cursor.results.get(@backingInt(returned)));
    const again = try cursor.normalize(gpa, returned);
    try std.testing.expectEqualDeep(expected, cursor.getView(cursor.results.get(@backingInt(again)).view));
    const kept = cursor.results.get(@backingInt(obligation));
    try std.testing.expectEqual(ResultKind.obligation, kept.kind);
    try std.testing.expectEqualSlices(InternPool.Symbol, &.{missing}, cursor.paths.items[kept.remaining.start..][0..kept.remaining.len]);
    // The payload origin still links to its declaring scheme, independently of
    // the normalized actual view which belongs to the entry's quantifier scope.
    const normalization = cursor.origins.get(@backingInt(snapshot.origin));
    const origin = cursor.origins.get(@backingInt(normalization.parent));
    try std.testing.expectEqual(OriginKind.payload, origin.kind);
    const owner_view = cursor.getView(origin.target);
    try std.testing.expectEqual(@as(u32, 1), @backingInt(owner_view.artifact));
    try std.testing.expect(owner_view.scope != expected.scope);
    try std.testing.expectEqual(@as(u32, 0), origin.constructor);
}
