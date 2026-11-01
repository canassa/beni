//! Hidden diagnostic-only entry artifact. Source-capture S evidence is not a
//! capability, realm, ownership or transport proof.
const std = @import("std");
const Session = @import("../Session.zig");
const Ir = @import("../entry/Compact.zig");
const Graph = @import("../entry/CompactGraph.zig");
const Discover = @import("../entry/CompactDiscover.zig");
const Emit = @import("../js/Emit.zig");
const hashes = @import("../resolve/iface_bytes.zig");
const RealmInspect = @import("../entry/RealmInspect.zig");
const TypedInspect = @import("../entry/TypedInspect.zig");
const SourceStore = @import("../SourceStore.zig");

pub fn inspect(a: std.mem.Allocator, scratch: std.mem.Allocator, session: *Session, options: Emit.Options) std.mem.Allocator.Error![]const Emit.Item {
    const inspection = try Emit.inspectEntry(a, scratch, session, options);
    errdefer {
        for (inspection.diagnostics) |item| a.free(item.message);
        a.free(inspection.diagnostics);
    }
    if (inspection.reach) |reach| {
        if (session.options.native_realms) {
            var source = RealmInspect.prepare(a, .{ .graph = &session.graph, .interner = &session.interner, .dispatch = session.checked.dispatch }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    const root = reach.entry.?;
                    const file = session.graph.moduleFile(root.module);
                    const token = session.artifacts.bir(file).decls[root.index].name_token;
                    const message = try std.fmt.allocPrint(a, "Native realm inspection has unavailable retained original source events ({s}). No entry graph was printed.", .{@errorName(err)});
                    errdefer a.free(message);
                    const items = try a.alloc(Emit.Item, inspection.diagnostics.len + 1);
                    @memcpy(items[0..inspection.diagnostics.len], inspection.diagnostics);
                    items[inspection.diagnostics.len] = .{ .code = .internal, .file = file, .token = token, .message = message };
                    a.free(inspection.diagnostics);
                    return items;
                },
            };
            source.deinit(a);
        }
        if (session.entry_plan.validated and session.entry_plan.selected != .none) {
            const root = reach.entry.?;
            const file = session.graph.moduleFile(root.module);
            const token = session.artifacts.bir(file).decls[root.index].name_token;
            if (try typedDiagnostic(a, typedInput(session), file, token)) |item| {
                // On failure the original diagnostics are still owned by the
                // errdefer above. The new message has its own failure cleanup.
                errdefer a.free(item.message);
                const items = try a.alloc(Emit.Item, inspection.diagnostics.len + 1);
                @memcpy(items[0..inspection.diagnostics.len], inspection.diagnostics);
                items[inspection.diagnostics.len] = item;
                a.free(inspection.diagnostics);
                return items;
            }
            try Discover.run(a, scratch, .{ .metadata = &session.entry_plan, .reach = reach, .entry = root }, &session.entry_graph);
        } else session.entry_graph.input_supported = false;
    } else session.entry_graph.input_supported = false;
    return inspection.diagnostics;
}
fn typedInput(session: *const Session) TypedInspect.Input {
    return .{
        .graph = &session.graph,
        .artifacts = &session.artifacts,
        .interner = &session.interner,
        .types = &session.checked.types,
        .dispatch = session.checked.dispatch,
        .plan = &session.entry_plan,
    };
}
fn typedDiagnostic(a: std.mem.Allocator, in: TypedInspect.Input, file: SourceStore.Index, token: u32) std.mem.Allocator.Error!?Emit.Item {
    if (!in.plan.validated or in.plan.selected == .none) return null;
    var prepared = TypedInspect.prepare(a, in) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{
            .code = .internal,
            .file = file,
            .token = token,
            .message = try std.fmt.allocPrint(a, "Entry inspection has unavailable retained typed evidence ({s}). This is a compiler bug, not a mistake in this program. No entry graph was printed.", .{@errorName(err)}),
        },
    };
    prepared.deinit(a);
    return null;
}
fn entry(w: *std.Io.Writer, g: *const Graph, id: Graph.EntryId) std.Io.Writer.Error!void {
    if (id == .none) return w.writeAll("<root>");
    return w.writeAll(g.text(g.entries.get(@backingInt(id)).canonical));
}
fn site(w: *std.Io.Writer, session: *const Session, id: Ir.SiteId) std.Io.Writer.Error!void {
    if (id == .none) return w.writeAll("<none>");
    const row = session.entry_graph.sites.get(@backingInt(id));
    const module: @import("../resolve/Graph.zig").Index = @fromBackingInt(@backingInt(row.module));
    const file = session.graph.moduleFile(module);
    const b = session.artifacts.bir(file);
    try w.print("{s}.{s}", .{ session.store.moduleName(file), session.interner.slice(b.symbol(b.decls[@backingInt(row.declaration)].name)) });
    if (row.instruction != .none) try w.print("@{d}", .{@backingInt(row.instruction)});
}
pub fn write(w: *std.Io.Writer, session: *const Session) (TypedInspect.Error || RealmInspect.Error)!void {
    // Also protect direct callers: the compact prefix must not escape before
    // the typed boundary has accepted every current selected declaration.
    var prepared: ?TypedInspect.Prepared = if (session.entry_plan.validated and session.entry_plan.selected != .none) try TypedInspect.prepare(session.gpa, typedInput(session)) else null;
    defer if (prepared) |*value| value.deinit(session.gpa);
    var realm: ?RealmInspect.Prepared = if (session.options.native_realms) try RealmInspect.prepare(session.gpa, .{ .graph = &session.graph, .interner = &session.interner, .dispatch = session.checked.dispatch }) else null;
    defer if (realm) |*value| value.deinit(session.gpa);
    const g = &session.entry_graph;
    try w.print("entries schema=1 partial=true discoveryComplete={} inputSupported={}\n", .{ g.discovery_complete, g.input_supported });
    try w.writeAll("proofs C=unproved EntryHost=unproved Wire=unproved ownership=unproved constructionEffects=unproved execution=unproved\n");
    try w.print("declaration-liveness {t} deferredCuts=false exactCode=false\n", .{g.declaration_liveness});
    try w.print("liveness-counts runs={d} nodes={d}\n", .{ g.counts.liveness_runs, g.counts.liveness_nodes });
    const c = g.counts;
    try w.print("counts templates={d} calls={d} ports={d} launchExports={d} queries={d} facts={d} subscriptions={d} expansions={d} deliveries={d} peakQueue={d}\n", .{ c.templates, c.source_calls, c.source_ports, c.launch_exports, c.solver.queries, c.solver.facts, c.solver.subscriptions, c.solver.expansions, c.solver.deliveries, c.solver.peak_queue });
    try w.print("field-work indexRows={d} lookups={d} edges={d} localWalk={d}\n", .{ c.solver.field_index_work, c.solver.field_lookup_work, c.solver.field_edge_work, c.solver.projection_walk_work });
    try w.print("builder-work shapePorts={d} shapeEdges={d} shapeSelectors={d} metadataRows={d} metadataIndexWork={d} metadataLookups={d} metadataMatches={d}\n", .{ c.builder.shape_port_work, c.builder.shape_edge_work, c.builder.shape_selector_work, c.builder.metadata_rows, c.builder.metadata_index_work, c.builder.metadata_lookup_work, c.builder.metadata_match_work });
    for (0..g.entries.len) |i| {
        const row = g.entries.get(i);
        try w.print("entry {s} id={s} ordinary={} kind={d}\n", .{ g.text(row.canonical), &hashes.hashHex(row.digest), row.ordinary, @backingInt(row.kind) });
    }
    for (0..g.constructions.len) |i| {
        const row = g.constructions.get(i);
        try w.writeAll("construction ");
        try entry(w, g, row.entry);
        try w.writeAll(" source=");
        try site(w, session, g.origins.get(@backingInt(row.origin)).site);
        try w.writeByte('\n');
    }
    for (0..g.callbacks.len) |i| {
        const row = g.callbacks.get(i);
        try w.writeAll("callback ");
        try entry(w, g, row.entry);
        try w.print(" role={d} S={t} source=", .{ row.role, row.status });
        try site(w, session, g.origins.get(@backingInt(row.origin)).site);
        try w.writeByte('\n');
    }
    for (0..g.captures.len) |i| {
        const row = g.captures.get(i);
        const input = g.inputs.get(@backingInt(row.input));
        try w.writeAll("capture ");
        try entry(w, g, row.entry);
        try w.print(" role={d} input={d} S={t} closure=", .{ row.role, input.position, row.status });
        try site(w, session, g.origins.get(@backingInt(row.closure)).site);
        try w.writeByte('\n');
    }
    for (0..g.capture_facts.len) |i| {
        const row = g.capture_facts.get(i);
        const capture = g.captures.get(row.capture);
        const answer = g.answers.get(@backingInt(row.answer));
        try w.writeAll("capture-fact ");
        try entry(w, g, capture.entry);
        try w.print(" role={d} input={d} {t}={t}", .{ capture.role, g.inputs.get(@backingInt(capture.input)).position, row.mode, answer.tag });
        if (answer.origin != .none) {
            try w.writeAll(" source=");
            try site(w, session, g.origins.get(@backingInt(answer.origin)).site);
        }
        if (answer.site != .none) {
            try w.writeAll(" at=");
            try site(w, session, answer.site);
        }
        if (answer.tag == .residual) try w.print(" reason={t}", .{answer.reason});
        try w.writeByte('\n');
    }
    for (0..g.scopes.len) |i| {
        const row = g.scopes.get(i);
        try w.writeAll("execution-root ");
        try entry(w, g, row.entry);
        try w.print(" {t} ", .{row.tag});
        try site(w, session, g.templates.get(@backingInt(row.template)).site);
        try w.writeByte('\n');
    }
    for (0..g.live_nodes.len) |i| {
        const row = g.live_nodes.get(i);
        const module: @import("../resolve/Graph.zig").Index = @fromBackingInt(@backingInt(row.module));
        const file = session.graph.moduleFile(module);
        try w.writeAll("live conservative ");
        try entry(w, g, row.entry);
        try w.print(" {t} {s}.", .{ row.tag, session.store.moduleName(file) });
        if (row.tag == .decl or row.tag == .twin) {
            const b = session.artifacts.bir(file);
            try w.writeAll(session.interner.slice(b.symbol(b.decls[@backingInt(row.index)].name)));
        } else try w.print("#{d}", .{@backingInt(row.index)});
        try w.writeByte('\n');
    }
    for (0..g.launches.len) |i| {
        const row = g.launches.get(i);
        try w.writeAll("launch ");
        try entry(w, g, row.from);
        try w.writeAll(" -> ");
        try entry(w, g, row.to);
        try w.writeAll(" at=");
        try site(w, session, row.site);
        try w.writeByte('\n');
    }
    for (0..g.residuals.len) |i| {
        const row = g.residuals.get(i);
        try w.writeAll("residual ");
        try entry(w, g, row.entry);
        try w.print(" {t} at=", .{row.reason});
        try site(w, session, row.site);
        try w.writeByte('\n');
    }
    for (0..g.failures.len) |i| {
        const row = g.failures.get(i);
        if (row.tag == .identity_collision) try w.writeAll("identity-collision at=") else try w.print("not-static {t} at=", .{row.tag});
        try site(w, session, row.site);
        try w.writeAll(" entry=");
        try entry(w, g, row.entry);
        try w.writeByte('\n');
    }
    if (prepared) |*value| try TypedInspect.writePrepared(session.gpa, w, typedInput(session), value);
    if (realm) |*value| try value.write(w);
}

test "entries writer emits no compact prefix when selected typed roots are unavailable" {
    const a = std.testing.allocator;
    var session = try Session.init(a, std.testing.io, .{ .jobs = 1, .core_package = false });
    defer session.deinit();
    session.entry_plan.selected = try session.entry_plan.appendKind(a, .{
        .program = @fromBackingInt(1),
        .module = @fromBackingInt(0),
        .interface_type = @fromBackingInt(0),
        .arity = 0,
        .realm = .node,
        .layer = 0,
        .runtime = .{ .module = @fromBackingInt(0), .decl = 0, .scheme = .none },
        .constructors = .{},
        .launches = .{},
        .roles = .{},
    });
    session.entry_plan.finish();
    session.checked.dispatch = try a.alloc(@import("../check/Dispatch.zig"), 1);
    session.checked.dispatch[0] = .{ .decl_heads = try a.dupe(@import("../check/Types.zig").TypeId, &.{@fromBackingInt(1)}) };
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try std.testing.expectError(error.MissingEntryRoots, write(&output.writer, &session));
    try std.testing.expectEqualStrings("", output.written());
    const item = (try typedDiagnostic(a, typedInput(&session), @fromBackingInt(3), 17)).?;
    defer a.free(item.message);
    try std.testing.expectEqualDeep(Emit.Item{
        .code = .internal,
        .file = @fromBackingInt(3),
        .token = 17,
        .message = "Entry inspection has unavailable retained typed evidence (MissingEntryRoots). This is a compiler bug, not a mistake in this program. No entry graph was printed.",
    }, item);
}

test "entries writer retains partial output for a validated legacy plan without selected kind" {
    const a = std.testing.allocator;
    var session = try Session.init(a, std.testing.io, .{ .jobs = 1, .core_package = false });
    defer session.deinit();
    session.entry_plan.finish();
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try write(&output.writer, &session);
    try std.testing.expectEqualStrings(
        \\entries schema=1 partial=true discoveryComplete=false inputSupported=true
        \\proofs C=unproved EntryHost=unproved Wire=unproved ownership=unproved constructionEffects=unproved execution=unproved
        \\declaration-liveness absent deferredCuts=false exactCode=false
        \\liveness-counts runs=0 nodes=0
        \\counts templates=0 calls=0 ports=0 launchExports=0 queries=0 facts=0 subscriptions=0 expansions=0 deliveries=0 peakQueue=0
        \\field-work indexRows=0 lookups=0 edges=0 localWalk=0
        \\builder-work shapePorts=0 shapeEdges=0 shapeSelectors=0 metadataRows=0 metadataIndexWork=0 metadataLookups=0 metadataMatches=0
        \\
    , output.written());
    try std.testing.expectEqual(@as(?Emit.Item, null), try typedDiagnostic(a, typedInput(&session), @fromBackingInt(0), 0));
}
