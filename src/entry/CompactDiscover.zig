//! Diagnostic-only compact discovery. All orchestration roots are finite source
//! entry/role pairs; substitutions remain in CompactSolve source-call edges.
const std = @import("std");
const Ir = @import("Compact.zig");
const Solve = @import("CompactSolve.zig");
const Build = @import("CompactBuild.zig");
const Live = @import("CompactLive.zig");
const Graph = @import("CompactGraph.zig");
const Plan = @import("Plan.zig");
const Reach = @import("../js/Reach.zig");
const Modules = @import("../resolve/Graph.zig");
const hashes = @import("../resolve/iface_bytes.zig");
const Allocator = std.mem.Allocator;
const sentinel = std.math.maxInt(u32);
const WatchId = enum(u32) { none = sentinel, _ };
const Watch = struct {
    query: Solve.QueryId,
    next: WatchId = .none,
    since: u32,
    entry: Graph.EntryId,
    tag: enum(u8) { entry, launch, callback, runtime },
    constructor: Ir.OriginId = .none,
    role: u32 = sentinel,
    site: Ir.SiteId = .none,
    kind: Ir.KindId = .none,
    source: Ir.PortId = .none,
    observation: Solve.ObservationId = .none,
    static_query: Solve.QueryId = .none,
};
const WatchKey = struct {
    query: Solve.QueryId,
    entry: Graph.EntryId,
    tag: @FieldType(Watch, "tag"),
    constructor: Ir.OriginId,
    role: u32,
    site: Ir.SiteId,
    kind: Ir.KindId,
};
const Delivery = struct { watcher: WatchId, answer: Solve.AnswerId };
const Scope = struct { entry: Graph.EntryId, template: Ir.TemplateId };
const RootKey = struct { entry: Graph.EntryId, constructor: Ir.OriginId, role: u32, origin: Ir.OriginId, runtime: bool };
const CallbackQuery = struct { row: u32, query: Solve.QueryId };
const CaptureQuery = struct { row: u32, W: Solve.QueryId, S: Solve.QueryId };
const ConstructionKey = struct { entry: Graph.EntryId, origin: Ir.OriginId };
const LaunchKey = struct { from: Graph.EntryId, to: Graph.EntryId, site: Ir.SiteId };
const ResidualKey = struct { entry: Graph.EntryId, site: Ir.SiteId, reason: Solve.Reason };
pub const Input = struct { metadata: *const Plan, reach: Reach.Input, entry: Reach.Node };

/// A failed contract never calls this function. The caller resets graph before
/// contract revalidation; all published source indices belong to that store.
pub fn run(a: Allocator, scratch: Allocator, in: Input, graph: *Graph) Allocator.Error!void {
    std.debug.assert(in.metadata.validated);
    graph.reset();
    var ir: Ir = .{};
    defer ir.deinit(scratch);
    try Build.build(scratch, .{ .metadata = in.metadata, .reach = in.reach }, &ir);
    var solver: Solve = .{ .ir = &ir, .a = scratch };
    defer solver.deinit();
    var p: Pass = .{ .a = a, .scratch = scratch, .in = in, .ir = &ir, .s = &solver, .g = graph };
    defer p.deinit();
    try p.anchor_entries.appendNTimes(scratch, .none, ir.anchors.len);
    try p.export_heads.appendNTimes(scratch, sentinel, ir.templates.len);
    try p.export_next.appendNTimes(scratch, sentinel, ir.exports.len);
    for (0..ir.exports.len) |i| {
        const owner = @backingInt(ir.exports.get(i).owner);
        p.export_next.items[i] = p.export_heads.items[owner];
        p.export_heads.items[owner] = @intCast(i);
    }
    const declaration = ir.declaration(@fromBackingInt(in.entry.module.int()), @fromBackingInt(in.entry.index));
    if (declaration.exported == .none) return;
    const observation = try solver.observe(.{});
    try p.watch(.{ .query = try solver.ask(declaration.exported, observation, .none), .entry = .none, .tag = .entry, .since = 0, .site = ir.templates.get(@backingInt(declaration.template)).site });
    // New facts and newly subscribed roots are both work. A root-count stable
    // iteration is insufficient: a runtime formal may acquire later facts.
    while (true) {
        try solver.drain();
        try p.deliverNewFacts();
        if (p.cursor == p.deliveries.len) break;
        while (p.cursor < p.deliveries.len) : (p.cursor += 1) try p.deliver(p.deliveries.get(p.cursor));
    }
    const static = try solver.finalizeStatic();
    defer scratch.free(static.status);
    for (0..p.callback_queries.len) |i| {
        const q = p.callback_queries.get(i);
        graph.callbacks.items(.status)[q.row] = static.status[@backingInt(q.query)];
    }
    for (0..p.capture_queries.len) |i| {
        const q = p.capture_queries.get(i);
        graph.captures.items(.status)[q.row] = static.status[@backingInt(q.S)];
        inline for (.{ Solve.Mode.W, Solve.Mode.S }) |mode| {
            var fact = solver.queries.get(@backingInt(if (mode == .W) q.W else q.S)).facts;
            while (fact != .none) {
                const value = solver.facts.get(@backingInt(fact));
                try graph.capture_facts.append(a, .{ .capture = q.row, .mode = mode, .answer = value.answer });
                fact = value.next;
            }
        }
    }
    for (0..graph.role_transfers.len) |i| {
        const q = graph.role_transfers.get(i).S;
        if (q != .none) graph.role_transfers.items(.status)[i] = static.status[@backingInt(q)];
    }
    try graph.snapshot(a, &ir, &solver, static.status);
    try Live.append(a, scratch, in.reach, in.metadata, &ir, graph);
    try graph.finish(a, scratch);
}

const Pass = struct {
    a: Allocator,
    scratch: Allocator,
    in: Input,
    ir: *const Ir,
    s: *Solve,
    g: *Graph,
    watchers: std.MultiArrayList(Watch) = .empty,
    heads: std.ArrayList(WatchId) = .empty,
    watcher_index: std.AutoHashMapUnmanaged(WatchKey, WatchId) = .empty,
    deliveries: std.MultiArrayList(Delivery) = .empty,
    delivery_index: std.AutoHashMapUnmanaged(Delivery, void) = .empty,
    anchor_entries: std.ArrayList(Graph.EntryId) = .empty,
    digests: std.AutoHashMapUnmanaged(hashes.Hash, Ir.AnchorId) = .empty,
    constructions: std.AutoHashMapUnmanaged(ConstructionKey, void) = .empty,
    launches: std.AutoHashMapUnmanaged(LaunchKey, void) = .empty,
    residuals: std.AutoHashMapUnmanaged(ResidualKey, void) = .empty,
    failures: std.AutoHashMapUnmanaged(Graph.Failure, void) = .empty,
    roots: std.AutoHashMapUnmanaged(RootKey, void) = .empty,
    scopes: std.AutoHashMapUnmanaged(Scope, void) = .empty,
    scope_rows: std.AutoHashMapUnmanaged(Graph.Scope, void) = .empty,
    export_heads: std.ArrayList(u32) = .empty,
    export_next: std.ArrayList(u32) = .empty,
    execution_heads: std.ArrayList(u32) = .empty,
    execution_next: std.ArrayList(u32) = .empty,
    execution_jobs: std.MultiArrayList(Scope) = .empty,
    callback_queries: std.MultiArrayList(CallbackQuery) = .empty,
    capture_queries: std.MultiArrayList(CaptureQuery) = .empty,
    cursor: usize = 0,
    fact_cursor: usize = 0,

    fn deinit(p: *Pass) void {
        inline for (.{ "watchers", "heads", "watcher_index", "deliveries", "delivery_index", "anchor_entries", "digests", "constructions", "launches", "residuals", "failures", "roots", "scopes", "scope_rows", "export_heads", "export_next", "execution_heads", "execution_next", "execution_jobs", "callback_queries", "capture_queries" }) |name| @field(p, name).deinit(p.scratch);
    }
    fn enqueue(p: *Pass, watcher: WatchId, answer: Solve.AnswerId) !void {
        const value: Delivery = .{ .watcher = watcher, .answer = answer };
        const found = try p.delivery_index.getOrPut(p.scratch, value);
        if (!found.found_existing) try p.deliveries.append(p.scratch, value);
    }
    fn watch(p: *Pass, value: Watch) !void {
        const key: WatchKey = .{ .query = value.query, .entry = value.entry, .tag = value.tag, .constructor = value.constructor, .role = value.role, .site = value.site, .kind = value.kind };
        const found = try p.watcher_index.getOrPut(p.scratch, key);
        if (found.found_existing) return;
        const index: WatchId = @fromBackingInt(@intCast(p.watchers.len));
        found.value_ptr.* = index;
        if (@backingInt(value.query) >= p.heads.items.len) try p.heads.appendNTimes(p.scratch, .none, @backingInt(value.query) + 1 - p.heads.items.len);
        var row = value;
        row.next = p.heads.items[@backingInt(value.query)];
        row.since = @intCast(p.s.facts.len);
        try p.watchers.append(p.scratch, row);
        p.heads.items[@backingInt(value.query)] = index;
        var fact = p.s.queries.get(@backingInt(value.query)).facts;
        while (fact != .none) {
            const f = p.s.facts.get(@backingInt(fact));
            try p.enqueue(index, f.answer);
            fact = f.next;
        }
    }
    fn deliverNewFacts(p: *Pass) !void {
        while (p.fact_cursor < p.s.facts.len) : (p.fact_cursor += 1) {
            const fact = p.s.facts.get(p.fact_cursor);
            if (@backingInt(fact.query) >= p.heads.items.len) continue;
            var watcher = p.heads.items[@backingInt(fact.query)];
            while (watcher != .none) {
                const row = p.watchers.get(@backingInt(watcher));
                if (p.fact_cursor >= row.since) try p.enqueue(watcher, fact.answer);
                watcher = row.next;
            }
        }
    }
    fn residual(p: *Pass, entry_id: Graph.EntryId, site: Ir.SiteId, reason: Solve.Reason) !void {
        p.g.input_supported = false;
        const found = try p.residuals.getOrPut(p.scratch, .{ .entry = entry_id, .site = site, .reason = reason });
        if (!found.found_existing) try p.g.residuals.append(p.a, .{ .entry = entry_id, .site = site, .reason = reason });
    }
    fn failure(p: *Pass, value: Graph.Failure) !void {
        const found = try p.failures.getOrPut(p.scratch, value);
        if (!found.found_existing) try p.g.failures.append(p.a, value);
    }
    fn programPort(p: *Pass, anchor: Ir.AnchorId) Ir.PortId {
        const source = p.ir.anchors.get(@backingInt(anchor));
        return p.ir.declaration(source.module, source.declaration).exported;
    }
    fn entry(p: *Pass, anchor: Ir.AnchorId, ordinary: bool) !Graph.EntryId {
        const old = p.anchor_entries.items[@backingInt(anchor)];
        if (old != .none) {
            if (ordinary) p.g.entries.items(.ordinary)[@backingInt(old)] = true;
            return old;
        }
        const source = p.ir.anchors.get(@backingInt(anchor));
        const module: Modules.Index = @fromBackingInt(@backingInt(source.module));
        const md = p.in.reach.graph.module(module);
        const b = p.in.reach.birOf(module);
        const pool = p.in.reach.interner.?;
        const canonical = try std.fmt.allocPrint(p.scratch, "{s}:{d}/{s}/{s}", .{ @tagName(md.package), md.layer, pool.slice(md.name), pool.slice(b.symbol(b.decls[@backingInt(source.declaration)].name)) });
        defer p.scratch.free(canonical);
        const digest = hashes.hash(canonical);
        const collision = try p.digests.getOrPut(p.scratch, digest);
        if (collision.found_existing) {
            // A collision never merges identities. Retain an explicit compiler
            // residual; canonical bytes remain the definitive entry identity.
            const previous = p.anchor_entries.items[@backingInt(collision.value_ptr.*)];
            std.debug.assert(previous != .none);
            const previous_text = p.g.text(p.g.entries.get(@backingInt(previous)).canonical);
            if (!std.mem.eql(u8, previous_text, canonical)) {
                p.g.input_supported = false;
                try p.failure(.{ .site = source.site, .tag = .identity_collision });
            }
        } else collision.value_ptr.* = anchor;
        const index: Graph.EntryId = @fromBackingInt(@intCast(p.g.entries.len));
        const bytes: Ir.Range = .{ .start = @intCast(p.g.bytes.items.len), .len = @intCast(canonical.len) };
        try p.g.bytes.appendSlice(p.a, canonical);
        try p.g.entries.append(p.a, .{ .anchor = anchor, .kind = source.kind, .ordinary = ordinary, .canonical = bytes, .digest = digest });
        p.anchor_entries.items[@backingInt(anchor)] = index;
        const declaration = p.ir.declaration(source.module, source.declaration);
        const W = try p.s.observe(.{});
        try p.watch(.{ .query = try p.s.ask(declaration.exported, W, .none), .entry = index, .tag = .entry, .site = source.site, .since = 0 });
        try p.root(index, declaration.template, .none, .initializer);
        const kind = p.in.metadata.kinds.get(@backingInt(source.kind));
        const rt = p.ir.declaration(@fromBackingInt(kind.runtime.module.int()), @fromBackingInt(kind.runtime.decl));
        if (rt.exported != .none) try p.watch(.{ .query = try p.s.ask(rt.exported, W, .none), .entry = index, .tag = .runtime, .source = rt.exported, .observation = W, .since = 0 });
        return index;
    }
    fn deliver(p: *Pass, delivery: Delivery) !void {
        const w = p.watchers.get(@backingInt(delivery.watcher));
        const answer = p.s.answers.get(@backingInt(delivery.answer));
        switch (w.tag) {
            .entry, .launch => {
                switch (answer.tag) {
                    .absent => {},
                    .residual => try p.residual(w.entry, answer.site, answer.reason),
                    .input => try p.residual(w.entry, w.site, .missing_binding),
                    .runtime_external => try p.failure(.{ .entry = w.entry, .site = w.site, .tag = .runtime }),
                    .origin => {
                        const origin = p.ir.origins.get(@backingInt(answer.origin));
                        if (origin.tag == .constructor and answer.anchor != .none) {
                            const anchor = p.ir.anchors.get(@backingInt(answer.anchor));
                            if (w.tag == .launch and anchor.kind != w.kind) {
                                try p.residual(w.entry, w.site, .shape);
                                return;
                            }
                            const target = try p.entry(answer.anchor, w.tag == .entry and w.entry == .none);
                            if (w.tag == .launch) {
                                const edge: LaunchKey = .{ .from = w.entry, .to = target, .site = w.site };
                                const found = try p.launches.getOrPut(p.scratch, edge);
                                if (!found.found_existing) try p.g.launches.append(p.a, .{ .from = edge.from, .to = edge.to, .site = edge.site });
                            }
                            try p.construction(target, answer.origin);
                        } else switch (origin.tag) {
                            .@"opaque", .runtime, .constructor => try p.failure(.{ .entry = w.entry, .site = w.site, .tag = switch (origin.tag) {
                                .@"opaque" => .@"opaque",
                                .runtime => .runtime,
                                else => .unbound,
                            } }),
                            else => try p.residual(w.entry, w.site, .shape),
                        }
                    },
                    else => try p.residual(w.entry, w.site, .projection),
                }
            },
            .callback, .runtime => {
                if (answer.tag == .absent) return;
                if (answer.tag == .residual) return p.residual(w.entry, answer.site, answer.reason);
                if (answer.tag == .runtime_external) return p.failure(.{ .entry = w.entry, .site = if (answer.site == .none) w.site else answer.site, .tag = .runtime });
                if (answer.tag != .origin) return p.residual(w.entry, w.site, .missing_binding);
                const origin = p.ir.origins.get(@backingInt(answer.origin));
                if (origin.tag == .@"opaque" or origin.tag == .runtime) {
                    try p.failure(.{ .entry = w.entry, .site = origin.site, .tag = if (origin.tag == .runtime) .runtime else .@"opaque" });
                    return;
                }
                if (origin.tag != .function and origin.tag != .closure) return p.residual(w.entry, origin.site, .shape);
                try p.callable(w, answer.origin);
            },
        }
    }
    fn construction(p: *Pass, entry_id: Graph.EntryId, origin_id: Ir.OriginId) !void {
        const key: ConstructionKey = .{ .entry = entry_id, .origin = origin_id };
        const found = try p.constructions.getOrPut(p.scratch, key);
        if (found.found_existing) return;
        try p.g.constructions.append(p.a, .{ .entry = entry_id, .origin = origin_id });
        const origin = p.ir.origins.get(@backingInt(origin_id));
        const constructor = p.ir.constructors.get(origin.target);
        const anchor = p.g.entries.get(@backingInt(entry_id)).anchor;
        const source = p.programPort(anchor);
        for (constructor.roles.start..constructor.roles.start + constructor.roles.len) |ri| {
            const role = p.ir.roles.get(ri);
            const observation: Solve.Observation = .{ .prefix = .role, .kind = constructor.kind, .role = role.position, .constructor = origin_id, .anchor = anchor };
            const W = try p.s.observe(observation);
            var stat = observation;
            stat.mode = .S;
            const S = try p.s.observe(stat);
            try p.watch(.{ .query = try p.s.ask(source, W, .none), .entry = entry_id, .tag = .callback, .constructor = origin_id, .role = role.position, .site = origin.site, .source = source, .observation = W, .static_query = try p.s.ask(source, S, .none), .since = 0 });
        }
    }
    fn callable(p: *Pass, watch_row: Watch, origin_id: Ir.OriginId) !void {
        const runtime = watch_row.tag == .runtime;
        const root_key: RootKey = .{ .entry = watch_row.entry, .constructor = watch_row.constructor, .role = watch_row.role, .origin = origin_id, .runtime = runtime };
        const found = try p.roots.getOrPut(p.scratch, root_key);
        if (found.found_existing) return;
        const origin = p.ir.origins.get(@backingInt(origin_id));
        const template: Ir.TemplateId = @fromBackingInt(origin.target);
        const anchor = p.g.entries.get(@backingInt(watch_row.entry)).anchor;
        const seed = try p.s.addSeed(.{ .template = template, .entry = anchor, .role = watch_row.role });
        const transfer: Graph.RoleTransferId = @fromBackingInt(@intCast(p.g.role_transfers.len));
        const capture_start: u32 = @intCast(p.g.captures.len);
        try p.g.role_transfers.append(p.a, .{
            .entry = watch_row.entry,
            .anchor = anchor,
            .constructor = watch_row.constructor,
            .role = watch_row.role,
            .origin = origin_id,
            .template = template,
            .seed = seed,
            .source = watch_row.source,
            .W = watch_row.query,
            .S = watch_row.static_query,
            .kind = if (runtime) .runtime else .callback,
        });
        if (!runtime) {
            const row: u32 = @intCast(p.g.callbacks.len);
            try p.g.callbacks.append(p.a, .{ .entry = watch_row.entry, .constructor = watch_row.constructor, .role = watch_row.role, .origin = origin_id, .status = .unproved });
            try p.callback_queries.append(p.scratch, .{ .row = row, .query = watch_row.static_query });
        }
        for (p.ir.ids(Ir.InputId, p.ir.templates.get(@backingInt(template)).inputs)) |input_id| {
            const input = p.ir.inputs.get(@backingInt(input_id));
            if (input.capture) {
                var observation = p.s.observations.get(@backingInt(watch_row.observation));
                observation.capture = input_id;
                observation.mode = .W;
                const W = try p.s.ask(watch_row.source, try p.s.observe(observation), .none);
                observation.mode = .S;
                const S = try p.s.ask(watch_row.source, try p.s.observe(observation), .none);
                try p.s.bind(.{ .seed = seed, .input = input_id, .W = W, .S = S });
                const row: u32 = @intCast(p.g.captures.len);
                try p.g.captures.append(p.a, .{ .binding = p.s.bindingId(seed, input_id).?, .transfer = transfer, .W = W, .S = S, .entry = watch_row.entry, .constructor = watch_row.constructor, .role = watch_row.role, .closure = origin_id, .input = input_id, .status = .unproved });
                try p.capture_queries.append(p.scratch, .{ .row = row, .W = W, .S = S });
            } else if (runtime and input.position == 0) {
                const source = p.programPort(anchor);
                const W = try p.s.ask(source, try p.s.observe(.{}), .none);
                const S = try p.s.ask(source, try p.s.observe(.{ .mode = .S }), .none);
                try p.s.bind(.{ .seed = seed, .input = input_id, .W = W, .S = S });
            } else try p.s.bind(.{ .seed = seed, .input = input_id, .runtime = true });
        }
        p.g.role_transfers.items(.captures)[@backingInt(transfer)] = .{ .start = capture_start, .len = @as(u32, @intCast(p.g.captures.len)) - capture_start };
        try p.root(watch_row.entry, template, seed, if (runtime) .runtime else .callback);
    }
    fn recordScope(p: *Pass, value: Graph.Scope) !void {
        const found = try p.scope_rows.getOrPut(p.scratch, value);
        if (!found.found_existing) try p.g.scopes.append(p.a, value);
    }
    fn root(p: *Pass, entry_id: Graph.EntryId, template: Ir.TemplateId, seed: Solve.SeedId, tag: @FieldType(Graph.Scope, "tag")) !void {
        try p.recordScope(.{ .entry = entry_id, .template = template, .tag = tag });
        // Launch results are source-call exports. Querying helpers separately
        // with unbound formals would discard the root's actual substitution.
        var export_index = p.export_heads.items[@backingInt(template)];
        while (export_index != sentinel) : (export_index = p.export_next.items[export_index]) {
            const export_row = p.ir.exports.get(export_index);
            const launch = p.ir.execution.get(export_row.launch);
            try p.watch(.{ .query = try p.s.ask(export_row.port, try p.s.observe(.{}), seed), .entry = entry_id, .tag = .launch, .site = launch.site, .kind = @fromBackingInt(launch.target), .since = 0 });
        }
        if (p.execution_heads.items.len == 0) {
            try p.execution_heads.appendNTimes(p.scratch, sentinel, p.ir.templates.len);
            try p.execution_next.appendNTimes(p.scratch, sentinel, p.ir.execution.len);
            for (0..p.ir.execution.len) |i| {
                const owner = @backingInt(p.ir.execution.get(i).owner);
                p.execution_next.items[i] = p.execution_heads.items[owner];
                p.execution_heads.items[owner] = @intCast(i);
            }
        }
        try p.execution_jobs.append(p.scratch, .{ .entry = entry_id, .template = template });
        while (p.execution_jobs.len != 0) {
            const job = p.execution_jobs.get(p.execution_jobs.len - 1);
            p.execution_jobs.len -= 1;
            const visited = try p.scopes.getOrPut(p.scratch, job);
            if (visited.found_existing) continue;
            var index = p.execution_heads.items[@backingInt(job.template)];
            while (index != sentinel) {
                const execution = p.ir.execution.get(index);
                switch (execution.tag) {
                    .known_call => {
                        const target = p.ir.calls.get(execution.target).target;
                        if (target == .none) try p.residual(entry_id, execution.site, .higher_order) else {
                            try p.recordScope(.{ .entry = entry_id, .template = target, .tag = .callable });
                            try p.execution_jobs.append(p.scratch, .{ .entry = entry_id, .template = target });
                        }
                    },
                    .evaluate => {
                        const target: Ir.TemplateId = @fromBackingInt(execution.target);
                        // Global initializer values are source-static, not
                        // parameterized by the root callback's invocation.
                        var initializer_export = p.export_heads.items[@backingInt(target)];
                        while (initializer_export != sentinel) : (initializer_export = p.export_next.items[initializer_export]) {
                            const export_row = p.ir.exports.get(initializer_export);
                            const launch = p.ir.execution.get(export_row.launch);
                            try p.watch(.{ .query = try p.s.ask(export_row.port, try p.s.observe(.{}), .none), .entry = entry_id, .tag = .launch, .site = launch.site, .kind = @fromBackingInt(launch.target), .since = 0 });
                        }
                        try p.recordScope(.{ .entry = entry_id, .template = target, .tag = .evaluated });
                        try p.execution_jobs.append(p.scratch, .{ .entry = entry_id, .template = target });
                    },
                    .residual => try p.residual(entry_id, execution.site, @fromBackingInt(@intCast(execution.target))),
                    .descriptor, .launch => {},
                }
                index = p.execution_next.items[index];
            }
        }
    }
};
