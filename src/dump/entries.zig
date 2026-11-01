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
    for (inspection.diagnostics) |item| if (item.severity == .@"error") return inspection.diagnostics;
    if (session.options.native_realms) {
        const selected: ?@import("../check/Realms.zig").QualifiedDecl = if (inspection.reach) |reach| .{ .module = reach.entry.?.module, .declaration = reach.entry.?.index } else null;
        var prepared = realmPrepare(a, session, selected, options.library) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const message = try std.fmt.allocPrint(a, "Native realm inspection has unavailable original source/root evidence ({s}). No entry graph was printed.", .{@errorName(err)});
                errdefer a.free(message);
                var item: Emit.Item = .{ .code = .internal, .file = @fromBackingInt(0), .token = 0, .message = message, .at = .{ .path = "<native-realms>" } };
                if (selected) |root| {
                    item.file = session.graph.moduleFile(root.module);
                    item.token = session.artifacts.bir(item.file).decls[root.declaration].name_token;
                    item.at = null;
                }
                const items = try a.alloc(Emit.Item, inspection.diagnostics.len + 1);
                @memcpy(items[0..inspection.diagnostics.len], inspection.diagnostics);
                items[inspection.diagnostics.len] = item;
                a.free(inspection.diagnostics);
                return items;
            },
        };
        prepared.deinit(a);
        session.entry_graph.realm_request = if (options.library) .open_library else if (selected != null) .selected else .selection_missing;
        session.entry_graph.selected_source = if (selected) |root| .{ .module = @fromBackingInt(root.module.int()), .declaration = @fromBackingInt(root.declaration), .instruction = .none } else null;
    }
    return inspection.diagnostics;
}
/// The registry is the only production seed supplier. The small array follows
/// its current indexed one-recipe domain; no source spelling grants authority.
fn realmPrepare(a: std.mem.Allocator, session: *Session, selected: ?@import("../check/Realms.zig").QualifiedDecl, library: bool) RealmInspect.Error!RealmInspect.Prepared {
    const Realms = @import("../check/Realms.zig");
    var seeds: [1]Realms.NativeSeed = undefined;
    var count: usize = 0;
    if (session.native_bindings.text_encoder) |native| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(@import("../native/Source.zig").provenance, &digest, .{});
        seeds[0] = .{ .target = .{ .module = native.module, .declaration = native.checked.declaration }, .allowed = native.candidate.realm_mask, .binding_digest = digest, .contract = .unit_to_native };
        count = 1;
    }
    return RealmInspect.prepare(a, .{ .graph = &session.graph, .interner = &session.interner, .artifacts = &session.artifacts, .interfaces = session.resolution.interfaces, .provenance = session.resolution.provenance, .dispatch = session.checked.dispatch, .plan = &session.entry_plan, .entries = &session.entry_graph, .selected = selected, .library = library, .native_seeds = seeds[0..count], .registry_reads = @intCast(count), .profile = &session.profile });
}
/// The frontend has already flushed. Include actual post-check inspector work
/// on every completed late path; keep the command's existing resource convention.
pub fn flushProfile(session: *Session, stderr: *std.Io.Writer) bool {
    const path = session.options.self_profile orelse return true;
    session.writeProfile(path) catch |err| {
        if (err == error.InputPath) {
            const failure = session.io_failure.?;
            stderr.print("beni: cannot read '{s}': {t}\n", .{ failure.path, failure.err }) catch {};
        } else stderr.print("beni: {t}\n", .{err}) catch {};
        return false;
    };
    return true;
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
pub fn write(w: *std.Io.Writer, session: *Session) (TypedInspect.Error || RealmInspect.Error)!void {
    // Also protect direct callers: the compact prefix must not escape before
    // the typed boundary has accepted every current selected declaration.
    var prepared: ?TypedInspect.Prepared = if (session.entry_plan.validated and session.entry_plan.selected != .none) try TypedInspect.prepare(session.gpa, typedInput(session)) else null;
    defer if (prepared) |*value| value.deinit(session.gpa);
    if (session.options.native_realms and session.entry_graph.realm_request == .unprepared) return error.UnpreparedRealmRequest;
    const selected: ?@import("../check/Realms.zig").QualifiedDecl = if (session.entry_graph.selected_source) |root| .{ .module = @fromBackingInt(@backingInt(root.module)), .declaration = @backingInt(root.declaration) } else null;
    var realm: ?RealmInspect.Prepared = if (session.options.native_realms) try realmPrepare(session.gpa, session, selected, session.entry_graph.realm_request == .open_library) else null;
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

const RealmFixture = struct {
    session: *Session,
    diagnostics: std.Io.Writer.Allocating,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    main_path: []const u8 = &.{},
    rel_start: u32 = 0,
    fn init() !RealmFixture {
        return initProfile(null);
    }
    fn initProfile(profile_path: ?[]const u8) !RealmFixture {
        const a = std.testing.allocator;
        const session = try a.create(Session);
        errdefer a.destroy(session);
        session.* = try Session.init(a, std.testing.io, .{ .jobs = 1, .self_profile = profile_path, .native_realms = true, .diagnostics = .json, .entry_root_requests = &.{.{ .program = "Start.Program" }} });
        return .{ .session = session, .diagnostics = .init(a), .arena = .init(a), .tmp = std.testing.tmpDir(.{}) };
    }
    fn deinit(f: *RealmFixture) void {
        f.session.deinit();
        std.testing.allocator.destroy(f.session);
        f.diagnostics.deinit();
        f.arena.deinit();
        f.tmp.cleanup();
    }
    fn run(f: *RealmFixture, body: [:0]const u8) !u32 {
        const a = std.testing.allocator;
        try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Main.beni", .data = body });
        if (f.session.store.count() == 0) {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const len = try f.tmp.dir.realPath(std.testing.io, &path_buf);
            f.main_path = try std.fs.path.join(f.arena.allocator(), &.{ path_buf[0..len], "Main.beni" });
            f.rel_start = @intCast(len + 1);
            try f.session.store.addPending(a, f.main_path, f.rel_start, .app);
            try f.session.store.addEmbedded(a, "platform/Start.beni", 9, .platform, "pub type Program = Program\n");
            try f.session.store.addEmbedded(a, "platform/Rt.beni", 9, .platform, "import Start exposing (Program)\n\n\npub run : Program → ⊤\nrun _ = ⊤\n");
            try f.session.store.addGenerated(a, "core/Browser/Host/TextEncoder.beni", 5, .core, @import("../native/Source.zig").source, .text_encoder_v1);
        } else {
            // Resident numbered inputs are retained. Refresh its bytes through
            // the ordinary read API; requeueing sources duplicates module IDs.
            try f.session.store.read(a, std.testing.io, f.session.store.find(f.main_path).?);
        }
        f.diagnostics.clearRetainingCapacity();
        return (try f.session.run(&.{}, Session.check_phases, &f.diagnostics.writer)).errors;
    }
    fn options(f: *RealmFixture, library: bool, legacy: bool) !Emit.Options {
        const a = f.arena.allocator();
        const manifest = try @import("../js/Manifest.zig").parse(a,
            \\{"platform":true,"program":"Start.Program","entryKinds":[{"programType":"Start.Program","realm":"window","runtime":"Rt","constructors":[],"launches":[],"parameters":[]}]}
        );
        const kinds = try a.alloc(Emit.EntryKind, if (legacy) 0 else 1);
        if (!legacy) kinds[0] = .{ .definition = manifest.entryKinds[0], .root = "platform", .layer = 0 };
        return .{ .out_dir = &.{}, .embedded = &.{}, .library = library, .platform = .{ .root = "platform", .program = manifest.program, .entry_kinds = kinds } };
    }
    fn query(f: *RealmFixture, library: bool, legacy: bool) !void {
        const items = try inspect(std.testing.allocator, f.arena.allocator(), f.session, try f.options(library, legacy));
        defer {
            for (items) |item| std.testing.allocator.free(item.message);
            std.testing.allocator.free(items);
        }
        if (items.len != 0) for (items) |item| std.debug.print("{t}: {s}\n", .{ item.code, item.message });
        try std.testing.expectEqual(@as(usize, 0), items.len);
    }
    fn build(f: *RealmFixture, a: std.mem.Allocator) !@import("../check/RealmBuild.zig").Output {
        const native = f.session.native_bindings.text_encoder orelse return error.MissingNative;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(@import("../native/Source.zig").provenance, &digest, .{});
        const seeds = [_]@import("../check/Realms.zig").NativeSeed{.{ .target = .{ .module = native.module, .declaration = native.checked.declaration }, .allowed = native.candidate.realm_mask, .binding_digest = digest, .contract = .unit_to_native }};
        return @import("../check/RealmBuild.zig").build(a, .{ .graph = &f.session.graph, .artifacts = &f.session.artifacts, .interfaces = f.session.resolution.interfaces, .provenance = f.session.resolution.provenance, .dispatch = f.session.checked.dispatch, .native_seeds = &seeds });
    }
    fn consumeInput(f: *RealmFixture) @import("../entry/RealmConsume.zig").Input {
        const selected_site = f.session.entry_graph.selected_source;
        return .{ .graph = &f.session.graph, .plan = &f.session.entry_plan, .entries = &f.session.entry_graph, .selected = if (selected_site) |s| .{ .module = @fromBackingInt(@backingInt(s.module)), .declaration = @backingInt(s.declaration) } else null };
    }
};
const realm_good =
    \\import Start
    \\import Browser.Host.TextEncoder as Encoder
    \\
    \\
    \\main : Start.Program
    \\main =
    \\    _ = Encoder.new ⊤
    \\    Start.Program
    \\
;

test "realm consumer actual selected Window refuses a private narrow native mask" {
    const a = std.testing.allocator;
    var f = try RealmFixture.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 0), try f.run(realm_good));
    try f.query(false, false);
    try std.testing.expectEqual(@import("../entry/Plan.zig").Realm.window, f.session.entry_plan.kinds.get(@backingInt(f.session.entry_plan.selected)).realm);
    var built = try f.build(a);
    defer built.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), built.seeds.len);
    // Private TEST evidence only, after the real ordinary/registry producer.
    // Kernel rejects this tagged origin in production binaries.
    built.seeds.items(.origin)[0] = .private_test;
    built.seeds.items(.allowed)[0] = 2;
    var result = try @import("../entry/RealmConsume.zig").consume(a, f.consumeInput(), &built);
    defer result.deinit(a);
    try std.testing.expectEqual(@import("../entry/RealmConsume.zig").Summary.violated, result.state);
    try std.testing.expectEqual(@as(u64, 1), result.work.selected_kind_reads);
    try std.testing.expectEqual(@as(u64, 1), result.work.selected_runtime_reads);
    try std.testing.expectEqual(@import("../entry/RealmConsume.zig").NativeState.unresolved, result.natives.get(0).state);
    try std.testing.expectEqual(@as(u32, 0), result.natives.get(0).checked_invocations);
}

test "realm consumer single Session source failure repair library and preparation failures clear selected authority" {
    const a = std.testing.allocator;
    var f = try RealmFixture.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 0), try f.run(realm_good));
    try f.query(false, false);
    try std.testing.expect(f.session.entry_graph.selected_source != null);
    try std.testing.expectEqual(@as(u32, 1), try f.run("pub broken : ⊤\nbroken = λx → x\n"));
    try std.testing.expect(f.session.entry_graph.selected_source == null);
    try std.testing.expectEqual(.unprepared, f.session.entry_graph.realm_request);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.testing.expectError(error.UnpreparedRealmRequest, write(&out.writer, f.session));
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expectEqual(@as(u32, 0), try f.run(realm_good));
    try f.query(false, false);
    // Real installed source authority removed only for this negative boundary.
    f.session.checked.dispatch[0].realm_sources.deinit(a);
    const bad_items = try inspect(a, f.arena.allocator(), f.session, try f.options(false, false));
    defer {
        for (bad_items) |item| a.free(item.message);
        a.free(bad_items);
    }
    try std.testing.expectEqual(@as(usize, 1), bad_items.len);
    try std.testing.expectEqual(@import("diagnostic").Code.internal, bad_items[0].code);
    try std.testing.expect(f.session.entry_graph.selected_source == null);
    try std.testing.expectEqual(.unprepared, f.session.entry_graph.realm_request);
    try std.testing.expectEqual(@as(u32, 0), try f.run(realm_good));
    try f.query(true, false);
    try std.testing.expectEqual(.open_library, f.session.entry_graph.realm_request);
    try std.testing.expect(f.session.entry_graph.selected_source == null);
    try f.query(false, true);
    try std.testing.expectEqual(.selected, f.session.entry_graph.realm_request);
    try std.testing.expectEqual(@import("../entry/Plan.zig").KindIndex.none, f.session.entry_plan.selected);
}

fn consumeAllocation(a: std.mem.Allocator, f: *RealmFixture, built: *const @import("../check/RealmBuild.zig").Output) !void {
    var result = try @import("../entry/RealmConsume.zig").consume(a, f.consumeInput(), built);
    defer result.deinit(a);
}
fn prepareAllocation(a: std.mem.Allocator, f: *RealmFixture) !void {
    const q = f.consumeInput().selected;
    var prepared = try realmPrepare(a, f.session, q, false);
    defer prepared.deinit(a);
}
test "realm consumer and prepared inspector release every injected allocation on actual selected source" {
    const a = std.testing.allocator;
    var f = try RealmFixture.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 0), try f.run(realm_good));
    try f.query(false, false);
    var built = try f.build(a);
    defer built.deinit(a);
    try std.testing.checkAllAllocationFailures(a, consumeAllocation, .{ &f, &built });
    try std.testing.checkAllAllocationFailures(a, prepareAllocation, .{&f});
}

test "realm consumer selected Window keeps equal ordinary rung functions independent" {
    const a = std.testing.allocator;
    var f = try RealmFixture.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 0), try f.run(
        \\import Start
        \\import Browser.Host.TextEncoder as Encoder
        \\
        \\
        \\pub left : ⊤ → Encoder.TextEncoder
        \\left x = Encoder.new x
        \\
        \\
        \\pub right : ⊤ → Encoder.TextEncoder
        \\right x = Encoder.new x
        \\
        \\
        \\holder = ( left, right )
        \\
        \\
        \\main : Start.Program
        \\main =
        \\    _ = left ⊤
        \\    _ = holder
        \\    Start.Program
        \\
    ));
    try f.query(false, false);
    const m = f.session.graph.lookup(.app, f.session.interner.find("Main").?).?;
    const iface = &f.session.resolution.interfaces[m.int()];
    var checked: usize = 0;
    for (iface.values) |value| {
        const name = f.session.interner.slice(iface.symbol(value.name));
        if (!std.mem.eql(u8, name, "left") and !std.mem.eql(u8, name, "right")) continue;
        const block = iface.effectBlock(iface.scheme(value.scheme)).?;
        var paths = block.sites();
        var found = false;
        while (paths.next()) |path| if (path.root == 0 and path.steps.len == 0) {
            try std.testing.expectEqual(@as(u2, 1), block.class(path.class).rung);
            found = true;
        };
        try std.testing.expect(found);
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), checked);
    var built = try f.build(a);
    defer built.deinit(a);
    const bir = f.session.artifacts.bir(f.session.graph.moduleFile(m));
    var execs: [2]@import("../check/Realms.zig").ExecId = @splat(.none);
    for (bir.decls, 0..) |decl, di| {
        const name = f.session.interner.slice(bir.symbol(decl.name));
        const index: usize = if (std.mem.eql(u8, name, "left")) 0 else if (std.mem.eql(u8, name, "right")) 1 else continue;
        execs[index] = try built.callableAt(.{ .module = m, .declaration = @intCast(di) });
        try built.seeds.append(a, .{ .target = execs[index], .allowed = @as(u8, 1) << @intCast(index), .binding_digest = @splat(0), .origin = .private_test });
    }
    try std.testing.expect(execs[0] != .none and execs[1] != .none and execs[0] != execs[1]);
    var result = try @import("../entry/RealmConsume.zig").consume(a, f.consumeInput(), &built);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(u8, 1), result.facts.facts.get(@backingInt(execs[0])).allowed);
    try std.testing.expectEqual(@as(u8, 2), result.facts.facts.get(@backingInt(execs[1])).allowed);
    try std.testing.expect(result.definite[@backingInt(execs[0])]);
    try std.testing.expect(!result.definite[@backingInt(execs[1])]);
    try std.testing.expectEqual(@import("../entry/RealmConsume.zig").State.covered, result.roots.get(0).state);
}

test "native emission authority uses actual selected ordinary Program and Registry" {
    const a = std.testing.allocator;
    const Emission = @import("../native/Emission.zig");
    var f = try RealmFixture.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 0), try f.run(realm_good));
    try f.query(false, false);
    const session = f.session;
    const inspection = try Emit.inspectEntry(a, f.arena.allocator(), session, try f.options(false, false));
    defer {
        for (inspection.diagnostics) |item| a.free(item.message);
        a.free(inspection.diagnostics);
    }
    try std.testing.expectEqual(@as(usize, 0), inspection.diagnostics.len);
    var reach_input = inspection.reach.?;
    const runtime = session.entry_plan.runtime().?;
    reach_input.extra_roots = &.{.{ .module = runtime.module, .kind = .decl, .index = runtime.decl }};
    const live = try @import("../js/Reach.zig").run(f.arena.allocator(), reach_input);
    try f.query(false, false);
    const input: Emission.Input = .{
        .registry = &session.native_bindings,
        .source = .{ .graph = &session.graph, .artifacts = &session.artifacts, .interfaces = session.resolution.interfaces, .provenance = session.resolution.provenance, .dispatch = session.checked.dispatch },
        .selection = f.consumeInput(),
        .live = &live,
    };
    var authority = try Emission.prepare(a, input);
    defer authority.deinit(a);
    if (authority.recipe.?.disposition != .ready) std.debug.print("native refusal: {t}\n", .{authority.recipe.?.reason});
    try std.testing.expectEqual(.ready, authority.recipe.?.disposition);
    try std.testing.expectEqual(.window, authority.realm.?);
    const installed = session.native_bindings.text_encoder.?;
    try std.testing.expect(authority.ready(.{ .module = installed.module, .declaration = installed.checked.declaration }));
    try std.testing.expectEqual(installed.checked.type_index, authority.recipe.?.native_type);
    try std.testing.expectEqual(installed.checked.scheme, authority.recipe.?.scheme);
    var abi_authority = try Emission.prepare(a, input);
    defer abi_authority.deinit(a);
    const actual_recipe = abi_authority.recipe.?;
    try std.testing.expect(abi_authority.recipeMatches(actual_recipe.target, @backingInt(actual_recipe.abi)));
    try std.testing.expect(!abi_authority.recipeMatches(actual_recipe.target, 0));
    try std.testing.expect(!abi_authority.recipeMatches(actual_recipe.target, 2));
    try std.testing.expect(!abi_authority.recipeMatches(.{ .module = actual_recipe.target.module, .declaration = actual_recipe.target.declaration + 1 }, @backingInt(actual_recipe.abi)));
    for ([_]u8{ 0, 1, 2 }) |abi| for ([_]bool{ false, true }) |answer| {
        const fact: @import("../js/EmitPack.zig").Fact = .{ .question = .native_recipe, .where = abi, .index = actual_recipe.target.declaration, .answer = answer };
        try std.testing.expectEqual(abi == @backingInt(actual_recipe.abi) and answer, Emission.matchesRecipeFact(&abi_authority, actual_recipe.target, fact));
        try std.testing.expect(!Emission.matchesRecipeFact(null, actual_recipe.target, fact));
    };
    var incompatible = session.native_bindings;
    incompatible.text_encoder.?.candidate.adapter_revision += 1;
    var wrong_abi = input;
    wrong_abi.registry = &incompatible;
    try std.testing.expectError(error.InvalidNativeAuthority, Emission.prepare(a, wrong_abi));
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator, in: Emission.Input) !void {
            var result = try Emission.prepare(allocator, in);
            defer result.deinit(allocator);
            try std.testing.expectEqual(.ready, result.recipe.?.disposition);
        }
    }.run, .{input});
}

test "native emission authority refuses a retained uninvoked native helper from final Reach" {
    const a = std.testing.allocator;
    const Emission = @import("../native/Emission.zig");
    var f = try RealmFixture.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 0), try f.run(
        \\import Start
        \\import Browser.Host.TextEncoder as Encoder
        \\
        \\
        \\deferred : ⊤ → Encoder.TextEncoder
        \\deferred _ = Encoder.new ⊤
        \\
        \\
        \\main : Start.Program
        \\main =
        \\    _ = deferred
        \\    Start.Program
        \\
    ));
    try f.query(false, false);
    const session = f.session;
    const inspection = try Emit.inspectEntry(a, f.arena.allocator(), session, try f.options(false, false));
    defer {
        for (inspection.diagnostics) |item| a.free(item.message);
        a.free(inspection.diagnostics);
    }
    try std.testing.expectEqual(@as(usize, 0), inspection.diagnostics.len);
    var reach_input = inspection.reach.?;
    const runtime = session.entry_plan.runtime().?;
    reach_input.extra_roots = &.{.{ .module = runtime.module, .kind = .decl, .index = runtime.decl }};
    const live = try @import("../js/Reach.zig").run(f.arena.allocator(), reach_input);
    try f.query(false, false);
    const input: Emission.Input = .{
        .registry = &session.native_bindings,
        .source = .{ .graph = &session.graph, .artifacts = &session.artifacts, .interfaces = session.resolution.interfaces, .provenance = session.resolution.provenance, .dispatch = session.checked.dispatch },
        .selection = f.consumeInput(),
        .live = &live,
    };
    var authority = try Emission.prepare(a, input);
    defer authority.deinit(a);
    try std.testing.expectEqual(.refused, authority.recipe.?.disposition);
    try std.testing.expectEqual(.deferred_use, authority.recipe.?.reason);
    const installed = session.native_bindings.text_encoder.?;
    try std.testing.expect(live.decl(installed.module, installed.checked.declaration));
    try std.testing.expect(!authority.ready(.{ .module = installed.module, .declaration = installed.checked.declaration }));
    try std.testing.expectEqual(@as(usize, 0), session.entry_graph.entries.len);
}

test "native emission internal pipeline emits strict facade without sibling fallback" {
    const a = std.testing.allocator;
    var f = try RealmFixture.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 0), try f.run(realm_good));
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var options = try f.options(false, false);
    options.out_dir = ".zig-cache/tmp/" ++ temporary.sub_path;
    var io_failure: ?Session.IoFailure = null;
    var result = try Emit.run(a, f.arena.allocator(), f.session, options, &io_failure);
    defer result.deinit(a);
    for (result.diagnostics) |item| std.debug.print("{t}: {s}\n", .{ item.code, item.message });
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(result.files_written != 0);
    const facade = try temporary.dir.readFileAlloc(std.testing.io, "_core/Browser/Host/TextEncoder.mjs", a, .limited(16384));
    defer a.free(facade);
    try std.testing.expect(std.mem.indexOf(u8, facade, "new globalThis.TextEncoder()") != null);
    try std.testing.expect(std.mem.indexOf(u8, facade, "$nativeUnit") != null);
    try std.testing.expect(std.mem.indexOf(u8, facade, ".foreign.mjs") == null);
    const checked = try Emit.checkContract(a, f.arena.allocator(), f.session, options);
    defer {
        for (checked) |item| a.free(item.message);
        a.free(checked);
    }
    try std.testing.expectEqual(@as(usize, 0), checked.len);
}

test "native emission authority requires evaluated initializer evidence separately from retention" {
    const a = std.testing.allocator;
    const Emission = @import("../native/Emission.zig");
    var f = try RealmFixture.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 0), try f.run(
        \\import Start
        \\import Browser.Host.TextEncoder as Encoder
        \\
        \\
        \\encoded : Encoder.TextEncoder
        \\encoded = Encoder.new ⊤
        \\
        \\
        \\main : Start.Program
        \\main =
        \\    _ = encoded
        \\    Start.Program
        \\
    ));
    try f.query(false, false);
    const session = f.session;
    const inspection = try Emit.inspectEntry(a, f.arena.allocator(), session, try f.options(false, false));
    defer {
        for (inspection.diagnostics) |item| a.free(item.message);
        a.free(inspection.diagnostics);
    }
    try std.testing.expectEqual(@as(usize, 0), inspection.diagnostics.len);
    var reach_input = inspection.reach.?;
    const runtime = session.entry_plan.runtime().?;
    reach_input.extra_roots = &.{.{ .module = runtime.module, .kind = .decl, .index = runtime.decl }};
    const live = try @import("../js/Reach.zig").run(f.arena.allocator(), reach_input);
    try f.query(false, false);
    var input: Emission.Input = .{
        .registry = &session.native_bindings,
        .source = .{ .graph = &session.graph, .artifacts = &session.artifacts, .interfaces = session.resolution.interfaces, .provenance = session.resolution.provenance, .dispatch = session.checked.dispatch },
        .selection = f.consumeInput(),
        .live = &live,
    };
    var possible = try Emission.prepare(a, input);
    defer possible.deinit(a);
    try std.testing.expectEqual(.refused, possible.recipe.?.disposition);
    try std.testing.expectEqual(.deferred_use, possible.recipe.?.reason);
    var evaluated: std.ArrayList(@import("../check/Realms.zig").QualifiedDecl) = .empty;
    defer evaluated.deinit(a);
    for (0..session.graph.count()) |mi| {
        const module: @import("../resolve/Graph.zig").Index = @fromBackingInt(@intCast(mi));
        const bir = session.artifacts.bir(session.graph.moduleFile(module));
        for (bir.decls, 0..) |decl, di| {
            if (!live.decl(module, di) or decl.kind != .value) continue;
            if (@import("../check/Convention.zig").definitionOf(&session.checked.dispatch[mi], bir, @intCast(di)) == .constant) try evaluated.append(a, .{ .module = module, .declaration = @intCast(di) });
        }
    }
    try std.testing.expect(evaluated.items.len >= 2);
    input.evaluated = evaluated.items;
    var eager = try Emission.prepare(a, input);
    defer eager.deinit(a);
    if (eager.recipe.?.disposition != .ready) std.debug.print("eager refusal: {t}\n", .{eager.recipe.?.reason});
    try std.testing.expectEqual(.ready, eager.recipe.?.disposition);
}

test "native emission internal pipeline keeps known returned facade and effectful Unit argument" {
    const a = std.testing.allocator;
    var f = try RealmFixture.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 0), try f.run(
        \\import Start
        \\import Browser.Host.TextEncoder as Encoder
        \\
        \\
        \\factory : ⊤ → (⊤ → Encoder.TextEncoder)
        \\factory _ = Encoder.new
        \\
        \\
        \\argument : ⊤ → ⊤
        \\argument _ =
        \\    _ = Encoder.new ⊤
        \\    ⊤
        \\
        \\
        \\main : Start.Program
        \\main =
        \\    _ = (factory ⊤) (argument ⊤)
        \\    Start.Program
        \\
    ));
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var options = try f.options(false, false);
    options.out_dir = ".zig-cache/tmp/" ++ temporary.sub_path;
    var io_failure: ?Session.IoFailure = null;
    var result = try Emit.run(a, f.arena.allocator(), f.session, options, &io_failure);
    defer result.deinit(a);
    for (result.diagnostics) |item| std.debug.print("{t}: {s}\n", .{ item.code, item.message });
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(result.files_written != 0);
    const facade = try temporary.dir.readFileAlloc(std.testing.io, "_core/Browser/Host/TextEncoder.mjs", a, .limited(16384));
    defer a.free(facade);
    try std.testing.expect(std.mem.indexOf(u8, facade, "new globalThis.TextEncoder()") != null);
    try std.testing.expect(std.mem.indexOf(u8, facade, "$nativeUnit") != null);
    try std.testing.expect(std.mem.indexOf(u8, facade, ".foreign.mjs") == null);
    const main = try temporary.dir.readFileAlloc(std.testing.io, "Main.mjs", a, .limited(16384));
    defer a.free(main);
    try std.testing.expect(std.mem.indexOf(u8, main, "argument") != null);
    try std.testing.expect(std.mem.indexOf(u8, main, "factory") != null);
    const checked = try Emit.checkContract(a, f.arena.allocator(), f.session, options);
    defer {
        for (checked) |item| a.free(item.message);
        a.free(checked);
    }
    try std.testing.expectEqual(@as(usize, 0), checked.len);
}

test "native emission internal pipeline does not emit an unreachable native declaration" {
    const a = std.testing.allocator;
    var f = try RealmFixture.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 0), try f.run(
        \\import Start
        \\import Browser.Host.TextEncoder as Encoder
        \\
        \\
        \\unused : ⊤ → Encoder.TextEncoder
        \\unused _ = Encoder.new ⊤
        \\
        \\
        \\main : Start.Program
        \\main = Start.Program
        \\
    ));
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var options = try f.options(false, false);
    options.out_dir = ".zig-cache/tmp/" ++ temporary.sub_path;
    var io_failure: ?Session.IoFailure = null;
    var result = try Emit.run(a, f.arena.allocator(), f.session, options, &io_failure);
    defer result.deinit(a);
    for (result.diagnostics) |item| std.debug.print("{t}: {s}\n", .{ item.code, item.message });
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(result.files_written != 0);
    const native_file: ?[]u8 = temporary.dir.readFileAlloc(std.testing.io, "_core/Browser/Host/TextEncoder.mjs", a, .limited(16384)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (native_file) |bytes| a.free(bytes);
    try std.testing.expect(native_file == null);
    const checked = try Emit.checkContract(a, f.arena.allocator(), f.session, options);
    defer {
        for (checked) |item| a.free(item.message);
        a.free(checked);
    }
    try std.testing.expectEqual(@as(usize, 0), checked.len);
}

test "native emission actual packed facade adopts only behind fresh readiness" {
    const a = std.testing.allocator;
    const Emission = @import("../native/Emission.zig");
    const Fixture = @import("../native/PackFixture.zig");
    const Pack = @import("../cache/Pack.zig");
    const EmitPack = @import("../js/EmitPack.zig");
    var source = try RealmFixture.init();
    defer source.deinit();
    try std.testing.expectEqual(@as(u32, 0), try source.run(realm_good));
    const session = source.session;
    const inspection = try Emit.inspectEntry(a, source.arena.allocator(), session, try source.options(false, false));
    defer {
        for (inspection.diagnostics) |item| a.free(item.message);
        a.free(inspection.diagnostics);
    }
    try std.testing.expectEqual(@as(usize, 0), inspection.diagnostics.len);
    var reach_input = inspection.reach.?;
    const runtime = session.entry_plan.runtime().?;
    reach_input.extra_roots = &.{.{ .module = runtime.module, .kind = .decl, .index = runtime.decl }};
    const live = try @import("../js/Reach.zig").run(source.arena.allocator(), reach_input);
    try source.query(false, false);
    var authority = try Emission.prepare(a, .{
        .registry = &session.native_bindings,
        .source = .{ .graph = &session.graph, .artifacts = &session.artifacts, .interfaces = session.resolution.interfaces, .provenance = session.resolution.provenance, .dispatch = session.checked.dispatch },
        .selection = source.consumeInput(),
        .live = &live,
    });
    defer authority.deinit(a);
    try std.testing.expectEqual(.ready, authority.recipe.?.disposition);
    for ([_]Fixture.Fault{ .none, .old_false, .unknown_true }) |fault| {
        const snapshot = try Fixture.make(a, source.arena.allocator(), session, &live, &authority, fault);
        defer a.free(snapshot.bytes);
        for ([_]bool{ false, true }) |deferred| {
            var output = std.testing.tmpDir(.{});
            defer output.cleanup();
            const path = ".zig-cache/tmp/" ++ output.sub_path;
            const profile = try std.fs.path.join(a, &.{ path, "profile.json" });
            defer a.free(profile);
            var current = try RealmFixture.initProfile(profile);
            defer current.deinit();
            const program = if (deferred)
                \\import Start
                \\import Browser.Host.TextEncoder as Encoder
                \\deferred : ⊤ → Encoder.TextEncoder
                \\deferred _ = Encoder.new ⊤
                \\main : Start.Program
                \\main =
                \\    _ = deferred
                \\    Start.Program
                \\
            else
                realm_good;
            try std.testing.expectEqual(@as(u32, 0), try current.run(program));
            const installed = current.session.native_bindings.text_encoder.?;
            try std.testing.expectEqualSlices(u8, &snapshot.key, &current.session.keys.of(installed.module));
            current.session.pack = Pack.Pack.init(snapshot.bytes);
            const row = current.session.pack.find(.emit, EmitPack.key(current.session.keys.of(installed.module), .{ .schema_library = false }));
            try std.testing.expect(row != null);
            try std.testing.expect(current.session.packCovers(current.session.graph.moduleFile(installed.module)));
            var options = try current.options(false, false);
            options.out_dir = path;
            var io_failure: ?Session.IoFailure = null;
            var result = try Emit.run(a, current.arena.allocator(), current.session, options, &io_failure);
            defer result.deinit(a);
            const embedded = current.session.profile.counter(.emit_units_embedded);
            if (deferred) {
                try std.testing.expect(result.diagnostics.len != 0);
                try std.testing.expectEqual(@as(u32, 0), result.files_written);
                try std.testing.expectEqual(@as(u64, 0), embedded);
                try std.testing.expectEqual(@as(u64, 0), current.session.profile.counter(.modules_lowered));
            } else {
                for (result.diagnostics) |item| std.debug.print("{t}: {s}\n", .{ item.code, item.message });
                try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
                try std.testing.expect(result.files_written != 0);
                if (fault == .none) try std.testing.expect(embedded > 0) else try std.testing.expectEqual(@as(u64, 0), embedded);
                const facade = try output.dir.readFileAlloc(std.testing.io, "_core/Browser/Host/TextEncoder.mjs", a, .limited(16384));
                defer a.free(facade);
                try std.testing.expect(std.mem.indexOf(u8, facade, "new globalThis.TextEncoder()") != null);
            }
        }
    }
}
