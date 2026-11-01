//! Current selected-source demand over an immutable original realm graph.
//! workers-native-realm-consumer.md; no public entry/native lowering certificate.
const std = @import("std");
const Graph = @import("../resolve/Graph.zig");
const Build = @import("../check/RealmBuild.zig");
const Realms = @import("../check/Realms.zig");
const Plan = @import("Plan.zig");
const Entries = @import("CompactGraph.zig");
const Allocator = std.mem.Allocator;
const none = Realms.none;
pub const Input = struct {
    graph: *const Graph,
    plan: *const Plan,
    entries: *const Entries,
    selected: ?Realms.QualifiedDecl,
    library: bool = false,
    /// Optional current generic-emission witnesses; inspection leaves both empty.
    emission_retained: []const Realms.QualifiedDecl = &.{},
    emission_evaluated: []const Realms.QualifiedDecl = &.{},
};
pub const Mode = enum(u8) { definite, possible };
pub const RootKind = enum(u8) { selected_initializer, selected_runtime, runtime_scope, callback, scope_possible, retained_initializer, emitted_initializer };
pub const State = enum(u8) { covered, violated, unresolved };
pub const Summary = enum(u8) { missing_selection, open_library, unresolved, violated };
pub const Root = struct { source: Realms.Source, exec: Realms.ExecId, kind: RootKind, mode: Mode, state: State = .unresolved };
pub const NativeState = enum(u8) { unused, deferred_retained, invoked_checked, unresolved };
pub const Native = struct {
    target: Realms.QualifiedDecl,
    binding_digest: [32]u8,
    exec: Realms.ExecId,
    state: NativeState = .unused,
    retentions: u32 = 0,
    checked_invocations: u32 = 0,
    deferred_invocations: u32 = 0,
    possible_invocations: u32 = 0,
    unresolved_invocations: u32 = 0,
    escapes: u32 = 0,
};
pub const Use = struct {
    source: Realms.Source,
    port: Realms.PortId,
    call: Build.CallId,
    native: u32 = none,
    kind: @FieldType(Build.ValueUse, "kind"),
    state: enum(u8) { retained, checked, deferred, possible, unresolved, not_native },
};
pub const Work = struct {
    selected_source_reads: u64 = 0,
    selected_kind_reads: u64 = 0,
    selected_runtime_reads: u64 = 0,
    ordinary_entry_rows: u64 = 0,
    roots: u64 = 0,
    root_misses: u64 = 0,
    retained_rows: u64 = 0,
    unsupported_retained_rows: u64 = 0,
    demand_nodes: u64 = 0,
    demand_edges: u64 = 0,
    source_uses: u64 = 0,
    native_rows: u64 = 0,
    unattributed_escapes: u64 = 0,
};
pub const Result = struct {
    realm: ?Plan.Realm = null,
    state: Summary = .missing_selection,
    use_coverage_partial: bool = false,
    roots: std.MultiArrayList(Root) = .empty,
    natives: std.MultiArrayList(Native) = .empty,
    uses: std.MultiArrayList(Use) = .empty,
    definite: []bool = &.{},
    possible: []bool = &.{},
    retained: []bool = &.{},
    facts: Realms.Result = .{},
    work: Work = .{},
    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.roots.deinit(gpa);
        r.natives.deinit(gpa);
        r.uses.deinit(gpa);
        gpa.free(r.definite);
        gpa.free(r.possible);
        gpa.free(r.retained);
        r.facts.deinit(gpa);
        r.* = .{};
    }
};
pub const Error = Build.Error || Realms.Error || error{ InvalidPlan, InvalidEntry, InvalidRoot, InvalidUse };
const Job = struct { exec: Realms.ExecId, mode: Mode };
const Pass = struct {
    gpa: Allocator,
    in: Input,
    built: *const Build.Output,
    out: *Result,
    ordinary: Entries.EntryId = .none,
    queue: std.ArrayList(Job) = .empty,
    offsets: []u32 = &.{},
    outgoing: []u32 = &.{},
    native_index: []u32 = &.{},

    fn deinit(p: *Pass) void {
        p.queue.deinit(p.gpa);
        p.gpa.free(p.offsets);
        p.gpa.free(p.outgoing);
        p.gpa.free(p.native_index);
    }
    fn declarationSlot(p: *const Pass, q: Realms.QualifiedDecl) Error!usize {
        _ = try p.built.declaration(q);
        return p.built.modules.get(q.module.int()).declarations.start + q.declaration;
    }
    fn retain(p: *Pass, q: Realms.QualifiedDecl) Error!void {
        p.out.retained[try p.declarationSlot(q)] = true;
    }
    fn sourceRetained(p: *const Pass, source: Realms.Source) Error!bool {
        if (source.declaration == none) return false;
        return p.out.retained[try p.declarationSlot(.{ .module = source.module, .declaration = source.declaration })];
    }
    fn callable(p: *const Pass, source: Realms.Source) Error!Realms.ExecId {
        if (source.declaration == none) return .none;
        if (source.instruction == none) return p.built.callableAt(.{ .module = source.module, .declaration = source.declaration });
        return p.built.callableAtInstruction(source.module, @fromBackingInt(source.instruction));
    }
    fn demand(p: *Pass, exec: Realms.ExecId, mode: Mode) Error!void {
        if (exec == .none) return;
        const i = @backingInt(exec);
        if (i >= p.built.execs.len) return error.InvalidRoot;
        const seen = if (mode == .definite) p.out.definite else p.out.possible;
        if (seen[i]) return;
        seen[i] = true;
        try p.queue.append(p.gpa, .{ .exec = exec, .mode = mode });
    }
    fn root(p: *Pass, source: Realms.Source, exec: Realms.ExecId, kind: RootKind, mode: Mode) Error!void {
        if (source.module.int() >= p.in.graph.count()) return error.InvalidRoot;
        try p.out.roots.append(p.gpa, .{ .source = source, .exec = exec, .kind = kind, .mode = mode });
        p.out.work.roots += 1;
        if (exec == .none) p.out.work.root_misses += 1;
        try p.demand(exec, mode);
    }
    fn nativeRows(p: *Pass) Error!void {
        p.native_index = try p.gpa.alloc(u32, p.built.execs.len);
        @memset(p.native_index, none);
        for (0..p.built.native_values.len) |i| {
            const n = p.built.native_values.get(i);
            const ei = @backingInt(n.exec);
            if (ei >= p.native_index.len or p.native_index[ei] != none) return error.InvalidSeed;
            const ex = p.built.execs.get(ei);
            if (ex.coverage != .native_required or ex.source.module != n.target.module or ex.source.declaration != n.target.declaration) return error.InvalidSeed;
            const origin = try p.built.origin(n.port);
            if (origin.kind != .callable or origin.value != ei) return error.InvalidSeed;
            p.native_index[ei] = @intCast(i);
            try p.out.natives.append(p.gpa, .{ .target = n.target, .binding_digest = n.binding_digest, .exec = n.exec });
            p.out.work.native_rows += 1;
        }
    }
    fn select(p: *Pass) Error!void {
        if (p.in.library) {
            p.out.state = .open_library;
            return;
        }
        const selected = p.in.selected orelse return;
        p.out.work.selected_source_reads += 1;
        try p.retain(selected);
        const source: Realms.Source = .{ .module = selected.module, .declaration = selected.declaration, .instruction = none };
        try p.root(source, try p.built.initializerOf(selected), .selected_initializer, .definite);
        if (!p.in.plan.validated or p.in.plan.selected == .none) return;
        if (@backingInt(p.in.plan.selected) >= p.in.plan.kinds.len) return error.InvalidPlan;
        const kind = p.in.plan.kinds.get(@backingInt(p.in.plan.selected));
        p.out.work.selected_kind_reads += 1;
        p.out.realm = kind.realm;
        p.out.state = .unresolved; // Compact discovery remains explicitly partial.
        const runtime = p.in.plan.runtime() orelse return error.InvalidPlan;
        p.out.work.selected_runtime_reads += 1;
        try p.retain(.{ .module = runtime.module, .declaration = runtime.decl });
        const rs: Realms.Source = .{ .module = runtime.module, .declaration = runtime.decl, .instruction = none };
        try p.root(rs, try p.callable(rs), .selected_runtime, .definite);
        for (0..p.in.entries.entries.len) |i| {
            const row = p.in.entries.entries.get(i);
            if (!row.ordinary) continue;
            p.out.work.ordinary_entry_rows += 1;
            if (p.ordinary != .none or @backingInt(row.kind) != @backingInt(p.in.plan.selected)) return error.InvalidEntry;
            p.ordinary = @fromBackingInt(@as(u32, @intCast(i)));
        }
        if (p.ordinary == .none) return;
        for (0..p.in.entries.scopes.len) |i| {
            const row = p.in.entries.scopes.get(i);
            if (row.entry != p.ordinary) continue;
            if (@backingInt(row.template) >= p.in.entries.templates.len) return error.InvalidRoot;
            const site_id = p.in.entries.templates.get(@backingInt(row.template)).site;
            if (@backingInt(site_id) >= p.in.entries.sites.len) return error.InvalidRoot;
            const site = p.in.entries.sites.get(@backingInt(site_id));
            const ss: Realms.Source = .{ .module = @fromBackingInt(@backingInt(site.module)), .declaration = @backingInt(site.declaration), .instruction = @backingInt(site.instruction) };
            const definite = row.tag == .callback or row.tag == .runtime;
            var exec: Realms.ExecId = .none;
            if (ss.declaration != none) {
                try p.retain(.{ .module = ss.module, .declaration = ss.declaration });
                exec = if (row.tag == .initializer or row.tag == .evaluated)
                    try p.built.initializerOf(.{ .module = ss.module, .declaration = ss.declaration })
                else
                    try p.callable(ss);
            }
            try p.root(ss, exec, if (row.tag == .runtime) .runtime_scope else if (definite) .callback else .scope_possible, if (definite) .definite else .possible);
        }
        for (0..p.in.entries.live_nodes.len) |i| {
            const row = p.in.entries.live_nodes.get(i);
            if (row.entry != p.ordinary) continue;
            p.out.work.retained_rows += 1;
            if (row.tag != .decl) {
                p.out.work.unsupported_retained_rows += 1;
                continue;
            }
            const q: Realms.QualifiedDecl = .{ .module = @fromBackingInt(@backingInt(row.module)), .declaration = @backingInt(row.index) };
            try p.retain(q);
            const initializer = try p.built.initializerOf(q);
            if (initializer != .none) try p.root(.{ .module = q.module, .declaration = q.declaration, .instruction = none }, initializer, .retained_initializer, .possible);
        }
    }
    fn emission(p: *Pass) Error!void {
        // Evaluation is supplied separately: code retention never promotes it.
        for (p.in.emission_evaluated) |q| {
            try p.retain(q);
            const initializer = try p.built.initializerOf(q);
            if (initializer == .none) return error.InvalidRoot;
            if (!p.out.definite[@backingInt(initializer)]) try p.root(.{ .module = q.module, .declaration = q.declaration, .instruction = none }, initializer, .emitted_initializer, .definite);
        }
        for (p.in.emission_retained) |q| {
            try p.retain(q);
            const initializer = try p.built.initializerOf(q);
            if (initializer != .none and !p.out.definite[@backingInt(initializer)] and !p.out.possible[@backingInt(initializer)]) try p.root(.{ .module = q.module, .declaration = q.declaration, .instruction = none }, initializer, .retained_initializer, .possible);
        }
    }
    fn walk(p: *Pass) Error!void {
        const n = p.built.execs.len;
        p.offsets = try p.gpa.alloc(u32, n + 1);
        @memset(p.offsets, 0);
        for (0..p.built.edges.len) |i| {
            const edge = p.built.edges.get(i);
            if (@backingInt(edge.caller) >= n or @backingInt(edge.callee) >= n) return error.InvalidExec;
            p.offsets[@backingInt(edge.caller) + 1] += 1;
        }
        for (1..p.offsets.len) |i| p.offsets[i] += p.offsets[i - 1];
        p.outgoing = try p.gpa.alloc(u32, p.built.edges.len);
        const cursor = try p.gpa.dupe(u32, p.offsets[0..n]);
        defer p.gpa.free(cursor);
        for (0..p.built.edges.len) |i| {
            const caller = @backingInt(p.built.edges.get(i).caller);
            p.outgoing[cursor[caller]] = @intCast(i);
            cursor[caller] += 1;
        }
        var at: usize = 0;
        while (at < p.queue.items.len) : (at += 1) {
            const job = p.queue.items[at];
            p.out.work.demand_nodes += 1;
            const ei = @backingInt(job.exec);
            for (p.offsets[ei]..p.offsets[ei + 1]) |edge_at| {
                p.out.work.demand_edges += 1;
                try p.demand(p.built.edges.get(p.outgoing[edge_at]).callee, job.mode);
            }
        }
    }
    fn nativeFor(p: *const Pass, exec: Realms.ExecId) Error!u32 {
        if (exec == .none) return none;
        if (@backingInt(exec) >= p.native_index.len) return error.InvalidUse;
        return p.native_index[@backingInt(exec)];
    }
    fn uses(p: *Pass) Error!void {
        for (0..p.built.uses.len) |i| {
            const use = p.built.uses.get(i);
            p.out.work.source_uses += 1;
            if (@backingInt(use.scope) >= p.built.scopes.len) return error.InvalidScope;
            const ambient = p.built.scopes.get(@backingInt(use.scope)).exec;
            if (@backingInt(ambient) >= p.built.execs.len) return error.InvalidExec;
            const definite = p.out.definite[@backingInt(ambient)];
            const possible = p.out.possible[@backingInt(ambient)];
            const retained = try p.sourceRetained(use.source);
            if (!definite and !possible and !retained) continue;
            var ni = try p.nativeFor(use.native_exec);
            var direct = false;
            if (use.call != .none) {
                if (@backingInt(use.call) >= p.built.calls.len) return error.InvalidUse;
                const call = p.built.calls.get(@backingInt(use.call));
                if (call.ambient != ambient or call.site != use.site) return error.InvalidUse;
                direct = call.classification == .direct;
                // An opaque argument is also an unresolved argument contract of
                // an exact native callee, without pretending the argument IS it.
                if (ni == none and use.kind == .escape) ni = try p.nativeFor(call.target);
            } else if (use.kind != .retention) return error.InvalidUse;
            var row: Use = .{ .source = use.source, .port = use.port, .call = use.call, .native = ni, .kind = use.kind, .state = .unresolved };
            if (use.kind == .escape) {
                p.out.use_coverage_partial = true;
                if (ni == none) p.out.work.unattributed_escapes += 1 else p.out.natives.items(.escapes)[ni] += 1;
            } else if (use.kind == .retention) {
                row.state = .retained;
                if (ni != none) p.out.natives.items(.retentions)[ni] += 1;
            } else if (ni == none) {
                if (direct) row.state = .not_native else p.out.use_coverage_partial = true;
            } else {
                if (!direct) {
                    p.out.natives.items(.unresolved_invocations)[ni] += 1;
                    p.out.use_coverage_partial = true;
                } else if (definite) {
                    const fact = p.out.facts.facts.get(@backingInt(use.native_exec));
                    if (p.out.realm) |realm| {
                        if (!fact.incomplete and fact.allowed & realmBit(realm) != 0) {
                            row.state = .checked;
                            p.out.natives.items(.checked_invocations)[ni] += 1;
                        } else p.out.natives.items(.unresolved_invocations)[ni] += 1;
                    } else p.out.natives.items(.unresolved_invocations)[ni] += 1;
                } else if (possible) {
                    row.state = .possible;
                    p.out.natives.items(.possible_invocations)[ni] += 1;
                } else {
                    row.state = .deferred;
                    p.out.natives.items(.deferred_invocations)[ni] += 1;
                }
            }
            try p.out.uses.append(p.gpa, row);
        }
        for (0..p.out.natives.len) |i| {
            var row = p.out.natives.get(i);
            row.state = if (p.out.realm == null or p.in.library) .unresolved else if (row.escapes != 0 or row.unresolved_invocations != 0 or row.possible_invocations != 0) .unresolved else if (row.checked_invocations != 0) .invoked_checked else if (row.retentions != 0 or row.deferred_invocations != 0) .deferred_retained else .unused;
            p.out.natives.set(i, row);
        }
    }
    fn finish(p: *Pass) void {
        for (0..p.out.roots.len) |i| {
            var root_row = p.out.roots.get(i);
            if (root_row.exec != .none and root_row.mode == .definite) if (p.out.realm) |realm| {
                const fact = p.out.facts.facts.get(@backingInt(root_row.exec));
                root_row.state = if (fact.allowed & realmBit(realm) == 0) .violated else if (fact.incomplete) .unresolved else .covered;
                if (root_row.state == .violated) p.out.state = .violated;
            };
            p.out.roots.set(i, root_row);
        }
    }
};
pub fn realmBit(realm: Plan.Realm) u8 {
    return switch (realm) {
        .window => 1,
        .dedicatedWorker => 2,
        .sharedWorker => 4,
        .serviceWorker => 8,
        .node => 16,
    };
}
pub fn consume(gpa: Allocator, in: Input, built: *const Build.Output) Error!Result {
    if (built.modules.len != in.graph.count()) return error.InvalidModule;
    var result: Result = .{};
    errdefer result.deinit(gpa);
    result.facts = try Realms.solve(gpa, built.input());
    result.definite = try gpa.alloc(bool, built.execs.len);
    @memset(result.definite, false);
    result.possible = try gpa.alloc(bool, built.execs.len);
    @memset(result.possible, false);
    result.retained = try gpa.alloc(bool, built.declarations.len);
    @memset(result.retained, false);
    var pass: Pass = .{ .gpa = gpa, .in = in, .built = built, .out = &result };
    defer pass.deinit();
    try pass.nativeRows();
    try pass.select();
    try pass.emission();
    try pass.walk();
    try pass.uses();
    pass.finish();
    return result;
}
