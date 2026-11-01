//! Source record inspection boundary; execution solver integration follows.
//! This section does not claim realm/entry/callable availability certification.
const std = @import("std");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Source = @import("../check/RealmSource.zig");
const Build = @import("../check/RealmBuild.zig");
const Consume = @import("RealmConsume.zig");
const Realms = @import("../check/Realms.zig");
const Artifacts = @import("../Artifacts.zig");
const Interface = @import("../resolve/Interface.zig");
const Plan = @import("Plan.zig");
const Entries = @import("CompactGraph.zig");
const Allocator = std.mem.Allocator;
pub const Input = struct {
    graph: *const Graph,
    interner: *const InternPool.Global,
    artifacts: *const Artifacts,
    interfaces: []const Interface,
    provenance: []const Interface.Provenance,
    dispatch: []const Dispatch,
    plan: *const Plan,
    entries: *const Entries,
    selected: ?Realms.QualifiedDecl,
    library: bool = false,
    native_seeds: []const Realms.NativeSeed = &.{},
    registry_reads: u32 = 0,
    profile: ?*@import("../Profile.zig") = null,
};
pub const Prepared = struct {
    bytes: []u8,
    pub fn deinit(p: *Prepared, gpa: Allocator) void {
        gpa.free(p.bytes);
        p.* = undefined;
    }
    pub fn write(p: *const Prepared, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(p.bytes);
    }
};
pub const Error = Consume.Error || std.Io.Writer.Error || error{ MissingRealmSource, InvalidRealmSource, UnpreparedRealmRequest };
pub fn prepare(gpa: Allocator, in: Input) Error!Prepared {
    if (in.dispatch.len != in.graph.count()) return error.MissingRealmSource;
    var built = try Build.build(gpa, .{ .graph = in.graph, .artifacts = in.artifacts, .interfaces = in.interfaces, .provenance = in.provenance, .dispatch = in.dispatch, .native_seeds = in.native_seeds });
    defer built.deinit(gpa);
    if (in.profile) |profile| {
        profile.addCounter(.realm_builder_runs, 1);
        profile.addCounter(.realm_value_field_steps, built.work.value.field_steps);
    }
    var consumed = try Consume.consume(gpa, .{ .graph = in.graph, .plan = in.plan, .entries = in.entries, .selected = in.selected, .library = in.library }, &built);
    defer consumed.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    w.writeAll("native-realm-source schema=1 proof=source-records realmProved=false entryComplete=false\n") catch return error.OutOfMemory;
    for (in.dispatch, 0..) |*table, mi| {
        const artifact = &table.realm_sources;
        if (!artifact.present) return error.MissingRealmSource;
        if (!artifact.verify()) return error.InvalidRealmSource;
        const module: Graph.Index = @fromBackingInt(@as(u32, @intCast(mi)));
        w.print("  realm-module {d} {t}:{s} scopes={d} nodes={d} refs={d}\n", .{ mi, in.graph.modulePackage(module), in.interner.slice(in.graph.moduleName(module)), artifact.scopes.len, artifact.nodes.len, artifact.refs.len }) catch return error.OutOfMemory;
        for (0..artifact.scopes.len) |i| {
            const scope = artifact.scopes.get(i);
            w.print("  realm-scope {d}:{d} decl={d} source={d} kind={t} parent={d} body={d} params={d}\n", .{ mi, i, scope.declaration, scope.instruction, scope.kind, @backingInt(scope.parent), scope.body, scope.parameters.len }) catch return error.OutOfMemory;
        }
        for (0..artifact.nodes.len) |i| {
            const node = artifact.nodes.get(i);
            if (node.scope == .none) continue;
            if (node.role != .expression and node.role != .pattern and node.role != .annotation) w.print("  realm-literal {d}:{d} decl={d} scope={d} role={t}\n", .{ mi, i, node.declaration, @backingInt(node.scope), node.role }) catch return error.OutOfMemory;
            if (node.role != .expression) continue;
            if (Source.isCall(node, artifact.refs)) w.print("  realm-call {d}:{d} decl={d} scope={d} tag={t} blocked={}\n", .{ mi, i, node.declaration, @backingInt(node.scope), node.tag, node.blocked }) catch return error.OutOfMemory;
            if (node.ref != Source.none) {
                const ref = artifact.refs.get(node.ref);
                w.print("  realm-reference {d}:{d} decl={d} scope={d} kind={t} module={d} value={d}\n", .{ mi, i, node.declaration, @backingInt(node.scope), ref.kind, @backingInt(ref.module), ref.value }) catch return error.OutOfMemory;
            }
        }
    }
    execution(w, in, &built, &consumed) catch return error.OutOfMemory;
    return .{ .bytes = try out.toOwnedSlice() };
}

fn source(w: *std.Io.Writer, in: Input, at: Realms.Source) std.Io.Writer.Error!void {
    if (at.module.int() >= in.graph.count()) return w.writeAll("<missing-module>");
    try w.print("{t}:{s}/", .{ in.graph.modulePackage(at.module), in.interner.slice(in.graph.moduleName(at.module)) });
    const b = in.artifacts.bir(in.graph.moduleFile(at.module));
    if (at.declaration < b.decls.len) try w.writeAll(in.interner.slice(b.symbol(b.decls[at.declaration].name))) else try w.writeAll("<synthetic>");
    try w.print("@{d}", .{at.instruction});
}
fn execution(w: *std.Io.Writer, in: Input, built: *const Build.Output, result: *const Consume.Result) std.Io.Writer.Error!void {
    try w.writeAll("native-realm-execution schema=1 proof=source-execution entryComplete=false nativeLowering=false\n");
    try w.print("  realm-selection state={t} realm=", .{result.state});
    if (result.realm) |realm| try w.print("{t}", .{realm}) else try w.writeAll("unavailable");
    try w.print(" discoveryComplete=false useCoverage={s}\n", .{if (result.use_coverage_partial) "partial" else "represented"});
    const c = result.work;
    try w.print("  realm-consumer sourceReads={d} kindReads={d} runtimeReads={d} ordinaryRows={d} registryReads={d} nativeRows={d} roots={d} rootMisses={d} retainedRows={d} unsupportedRetained={d} demandNodes={d} demandEdges={d} sourceUses={d} unattributedEscapes={d}\n", .{ c.selected_source_reads, c.selected_kind_reads, c.selected_runtime_reads, c.ordinary_entry_rows, in.registry_reads, c.native_rows, c.roots, c.root_misses, c.retained_rows, c.unsupported_retained_rows, c.demand_nodes, c.demand_edges, c.source_uses, c.unattributed_escapes });
    const b = built.work;
    try w.print("  realm-builder modules={d} scopes={d} ports={d} calls={d} edges={d} residuals={d} seedReads={d} valuePorts={d} dependencies={d} fields={d} fieldQueries={d} fieldStepsBound={d}\n", .{ b.modules, b.scopes, b.ports, b.calls, b.edges, b.residuals, b.seed_reads, b.value.ports, b.value.dependencies, b.value.fields, b.value.field_queries, 64 * b.value.fields + 33 * b.value.field_queries });
    const k = result.facts.work;
    try w.print("  realm-kernel nodes={d} edges={d} seedReads={d} bitTransitions={d} incompleteTransitions={d} edgeVisits={d}\n", .{ k.nodes, k.edges, k.seed_reads, k.bit_transitions, k.incomplete_transitions, k.edge_visits });
    for (0..built.execs.len) |i| {
        const ex = built.execs.get(i);
        const fact = result.facts.facts.get(i);
        try w.print("  realm-exec {d} scope={d} coverage={t} allowed={d} incomplete={} seed={d} definite={} possible={} source=", .{ i, @backingInt(ex.scope), ex.coverage, fact.allowed, fact.incomplete, fact.seed, result.definite[i], result.possible[i] });
        try source(w, in, ex.source);
        try w.writeByte('\n');
    }
    for (0..result.roots.len) |i| {
        const row = result.roots.get(i);
        try w.print("  realm-root {d} exec={d} kind={t} mode={t} state={t} source=", .{ i, @backingInt(row.exec), row.kind, row.mode, row.state });
        try source(w, in, row.source);
        try w.writeByte('\n');
    }
    for (0..built.calls.len) |i| {
        const row = built.calls.get(i);
        try w.print("  realm-invocation {d} ambient={d} callee={d} target={d} class={t} source=", .{ i, @backingInt(row.ambient), @backingInt(row.callee), @backingInt(row.target), row.classification });
        try source(w, in, built.sites.get(@backingInt(row.site)).source);
        try w.writeByte('\n');
    }
    for (0..result.natives.len) |i| {
        const row = result.natives.get(i);
        const fact = result.facts.facts.get(@backingInt(row.exec));
        const digest = std.fmt.bytesToHex(row.binding_digest, .lower);
        try w.print("  realm-native {d} module={d} decl={d} exec={d} allowed={d} incomplete={} seed={d} state={t} retained={d} checked={d} deferred={d} possible={d} unresolved={d} escapes={d} digest={s} source=", .{ i, row.target.module.int(), row.target.declaration, @backingInt(row.exec), fact.allowed, fact.incomplete, fact.seed, row.state, row.retentions, row.checked_invocations, row.deferred_invocations, row.possible_invocations, row.unresolved_invocations, row.escapes, digest });
        try source(w, in, .{ .module = row.target.module, .declaration = row.target.declaration, .instruction = Realms.none });
        try w.writeByte('\n');
    }
    for (0..result.uses.len) |i| {
        const row = result.uses.get(i);
        if (row.native == Realms.none and row.kind != .escape) continue;
        try w.print("  realm-native-use {d} native={d} port={d} call={d} kind={t} state={t} source=", .{ i, row.native, @backingInt(row.port), @backingInt(row.call), row.kind, row.state });
        try source(w, in, row.source);
        try w.writeByte('\n');
    }
    for (0..built.residuals.len) |i| {
        const row = built.residuals.get(i);
        const site = built.sites.get(@backingInt(row.site));
        try w.print("  realm-residual {d} scope={d} reason={t} port={d} source=", .{ i, @backingInt(site.scope), row.reason, @backingInt(row.port) });
        try source(w, in, site.source);
        try w.writeByte('\n');
    }
}
