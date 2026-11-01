//! Session-owned inspection facts. All source IDs expire with the checked store.
//! No phase-arena port, environment or TypeStore variable escapes in a row.
const std = @import("std");
const Ir = @import("Compact.zig");
const Solve = @import("CompactSolve.zig");
const Evidence = @import("CompactEvidence.zig");
const hashes = @import("../resolve/iface_bytes.zig");
const Allocator = std.mem.Allocator;
const Graph = @This();
const sentinel = std.math.maxInt(u32);
pub const NodeId = enum(u32) { _ };
pub const LiveTag = enum(u8) { decl, derived, twin, ctor, schema, lift };
pub const LiveNode = struct { entry: EntryId, module: Ir.ModuleId, tag: LiveTag, index: NodeId };
pub const EntryId = enum(u32) { none = sentinel, _ };
pub const RoleTransferId = enum(u32) { none = sentinel, _ };
pub const ProofState = enum { unproved };
pub const Proofs = struct {
    capability: ProofState = .unproved,
    entry_host: ProofState = .unproved,
    wire: ProofState = .unproved,
    ownership: ProofState = .unproved,
    construction_effects: ProofState = .unproved,
    execution: ProofState = .unproved,
};
pub const Template = struct { site: Ir.SiteId };
pub const Origin = struct { tag: Ir.Origin.Tag, site: Ir.SiteId };
pub const Input = struct { owner: Ir.TemplateId, position: u32, capture: bool, source_local: Ir.LocalId };
pub const Entry = struct { anchor: Ir.AnchorId, kind: Ir.KindId, ordinary: bool, canonical: Ir.Range, digest: hashes.Hash };
pub const Construction = struct { entry: EntryId, origin: Ir.OriginId };
pub const Scope = struct {
    entry: EntryId,
    template: Ir.TemplateId,
    tag: enum(u8) { initializer, callback, runtime, callable, evaluated },
};
pub const Callback = struct { entry: EntryId, constructor: Ir.OriginId, role: u32, origin: Ir.OriginId, status: Solve.StaticStatus };
pub const Capture = struct { binding: Solve.BindingId = .none, transfer: RoleTransferId = .none, W: Solve.QueryId = .none, S: Solve.QueryId = .none, entry: EntryId, constructor: Ir.OriginId, role: u32, closure: Ir.OriginId, input: Ir.InputId, status: Solve.StaticStatus };
pub const RoleTransfer = struct {
    entry: EntryId,
    anchor: Ir.AnchorId,
    constructor: Ir.OriginId,
    role: u32,
    origin: Ir.OriginId,
    template: Ir.TemplateId,
    seed: Solve.SeedId,
    source: Ir.PortId,
    W: Solve.QueryId,
    S: Solve.QueryId = .none,
    captures: Ir.Range = .{},
    kind: enum(u8) { callback, runtime },
    status: Solve.StaticStatus = .unproved,
};
pub const CaptureFact = struct { capture: u32, mode: Solve.Mode, answer: Solve.AnswerId };
pub const Launch = struct { from: EntryId, to: EntryId, site: Ir.SiteId };
pub const Residual = struct { entry: EntryId, site: Ir.SiteId, reason: Solve.Reason };
pub const Failure = struct { entry: EntryId = .none, site: Ir.SiteId, tag: enum(u8) { @"opaque", runtime, unbound, capture, identity_collision } };
pub const Counts = struct {
    templates: u64 = 0,
    source_calls: u64 = 0,
    source_ports: u64 = 0,
    launch_exports: u64 = 0,
    liveness_runs: u64 = 0,
    liveness_nodes: u64 = 0,
    solver: Solve.Counters = .{},
    builder: Ir.BuilderCounters = .{},
};

evidence: Evidence = .{},
role_transfers: std.MultiArrayList(RoleTransfer) = .empty,
live_nodes: std.MultiArrayList(LiveNode) = .empty,
declaration_liveness: enum { absent, conservative } = .absent,
sites: std.MultiArrayList(Ir.Site) = .empty,
templates: std.MultiArrayList(Template) = .empty,
inputs: std.MultiArrayList(Input) = .empty,
origins: std.MultiArrayList(Origin) = .empty,
anchors: std.MultiArrayList(Ir.Anchor) = .empty,
selectors: std.MultiArrayList(Ir.Selector) = .empty,
observations: std.MultiArrayList(Solve.Observation) = .empty,
answers: std.MultiArrayList(Solve.Answer) = .empty,
entries: std.MultiArrayList(Entry) = .empty,
constructions: std.MultiArrayList(Construction) = .empty,
scopes: std.MultiArrayList(Scope) = .empty,
callbacks: std.MultiArrayList(Callback) = .empty,
captures: std.MultiArrayList(Capture) = .empty,
capture_facts: std.MultiArrayList(CaptureFact) = .empty,
launches: std.MultiArrayList(Launch) = .empty,
residuals: std.MultiArrayList(Residual) = .empty,
failures: std.MultiArrayList(Failure) = .empty,
bytes: std.ArrayList(u8) = .empty,
counts: Counts = .{},
proofs: Proofs = .{},
/// One successful hidden realm inspection, invalidated with this checked store.
realm_request: enum { unprepared, selected, selection_missing, open_library } = .unprepared,
selected_source: ?Ir.Site = null,
/// This partial kernel never sets whole-worker discovery complete.
discovery_complete: bool = false,
input_supported: bool = true,

const containers = .{ "role_transfers", "live_nodes", "sites", "templates", "inputs", "origins", "anchors", "selectors", "observations", "answers", "entries", "constructions", "scopes", "callbacks", "captures", "capture_facts", "launches", "residuals", "failures", "bytes" };
pub fn reset(g: *Graph) void {
    g.evidence.reset();
    inline for (containers) |name| @field(g, name).clearRetainingCapacity();
    g.declaration_liveness = .absent;
    g.counts = .{};
    g.proofs = .{};
    g.realm_request = .unprepared;
    g.selected_source = null;
    g.discovery_complete = false;
    g.input_supported = true;
}
pub fn deinit(g: *Graph, a: Allocator) void {
    g.evidence.deinit(a);
    inline for (containers) |name| @field(g, name).deinit(a);
    g.* = .{};
}
pub fn text(g: *const Graph, range: Ir.Range) []const u8 {
    return g.bytes.items[range.start..][0..range.len];
}

/// Copy index-addressed source/proof descriptors before discarding phase arenas.
/// The separate evidence owner also retains original value/capture/substitution
/// directories; legacy inspection rows preserve their original compact layout.
pub fn snapshot(g: *Graph, a: Allocator, ir: *const Ir, solver: *const Solve, statuses: []const Solve.StaticStatus) !void {
    for (0..ir.sites.len) |i| try g.sites.append(a, ir.sites.get(i));
    for (0..ir.templates.len) |i| try g.templates.append(a, .{ .site = ir.templates.get(i).site });
    for (0..ir.inputs.len) |i| {
        const row = ir.inputs.get(i);
        try g.inputs.append(a, .{ .owner = row.owner, .position = row.position, .capture = row.capture, .source_local = row.source_local });
    }
    for (0..ir.origins.len) |i| {
        const row = ir.origins.get(i);
        try g.origins.append(a, .{ .tag = row.tag, .site = row.site });
    }
    for (0..ir.anchors.len) |i| try g.anchors.append(a, ir.anchors.get(i));
    for (0..ir.selectors.len) |i| try g.selectors.append(a, ir.selectors.get(i));
    for (0..solver.observations.len) |i| try g.observations.append(a, solver.observations.get(i));
    for (0..solver.answers.len) |i| try g.answers.append(a, solver.answers.get(i));
    const evidence = try Evidence.init(a, ir, solver, statuses);
    g.evidence.deinit(a);
    g.evidence = evidence;
    g.counts = .{ .templates = ir.templates.len, .source_calls = ir.calls.len, .source_ports = ir.ports.len, .launch_exports = ir.exports.len, .solver = solver.counts, .builder = ir.counts };
}

pub fn finish(g: *Graph, a: Allocator, scratch: Allocator) !void {
    const order = try scratch.alloc(u32, g.entries.len);
    const remap = try scratch.alloc(EntryId, order.len);
    for (order, 0..) |*value, i| value.* = @intCast(i);
    std.mem.sort(u32, order, g, struct {
        fn less(graph: *const Graph, left: u32, right: u32) bool {
            return std.mem.lessThan(u8, graph.text(graph.entries.get(left).canonical), graph.text(graph.entries.get(right).canonical));
        }
    }.less);
    var sorted: std.MultiArrayList(Entry) = .empty;
    errdefer sorted.deinit(a);
    try sorted.ensureTotalCapacity(a, order.len);
    for (order, 0..) |old, new| {
        remap[old] = @fromBackingInt(@intCast(new));
        sorted.appendAssumeCapacity(g.entries.get(old));
    }
    g.entries.deinit(a);
    g.entries = sorted;
    inline for (.{ "role_transfers", "live_nodes", "constructions", "scopes", "callbacks", "captures", "residuals", "failures" }) |name|
        for (@field(g, name).items(.entry)) |*entry| {
            if (entry.* != .none) entry.* = remap[@backingInt(entry.*)];
        };
    for (g.launches.items(.from)) |*entry| {
        if (entry.* != .none) entry.* = remap[@backingInt(entry.*)];
    }
    for (g.launches.items(.to)) |*entry| {
        if (entry.* != .none) entry.* = remap[@backingInt(entry.*)];
    }
}

/// Structural owner/incidence checks only, never a semantic proof receipt.
pub fn validateTransfers(g: *const Graph) Evidence.Error!void {
    try g.evidence.validate(&g.observations, &g.answers);
    const ir = &g.evidence.source;
    var capture_cursor: usize = 0;
    for (0..g.role_transfers.len) |i| {
        const row = g.role_transfers.get(i);
        if (@backingInt(row.entry) >= g.entries.len or @backingInt(row.anchor) >= ir.anchors.len or @backingInt(row.origin) >= ir.origins.len or @backingInt(row.template) >= ir.templates.len or @backingInt(row.seed) >= g.evidence.seeds.len or @backingInt(row.W) >= g.evidence.queries.len) return error.InvalidEvidence;
        const callable = ir.origins.get(@backingInt(row.origin));
        if ((callable.tag != .function and callable.tag != .closure) or g.entries.get(@backingInt(row.entry)).anchor != row.anchor or callable.target != @backingInt(row.template)) return error.InvalidEvidence;
        const seed = g.evidence.seeds.get(@backingInt(row.seed));
        if (seed.template != row.template or seed.entry != row.anchor or seed.role != row.role) return error.InvalidEvidence;
        const W = g.evidence.queries.get(@backingInt(row.W));
        const W_observation = g.observations.get(@backingInt(W.observation));
        if (W.port != row.source or W.seed != .none or W_observation.mode != .W) return error.InvalidEvidence;
        if (row.S == .none) {
            if (row.kind != .runtime or row.status != .unproved) return error.InvalidEvidence;
        } else {
            if (@backingInt(row.S) >= g.evidence.queries.len) return error.InvalidEvidence;
            const S = g.evidence.queries.get(@backingInt(row.S));
            var expected = W_observation;
            expected.mode = .S;
            if (S.port != row.source or S.seed != .none or !std.meta.eql(expected, g.observations.get(@backingInt(S.observation))) or g.evidence.statuses.items[@backingInt(row.S)] != row.status) return error.InvalidEvidence;
        }
        if (row.kind == .callback) {
            if (@backingInt(row.constructor) >= ir.origins.len) return error.InvalidEvidence;
            const constructor_origin = ir.origins.get(@backingInt(row.constructor));
            if (constructor_origin.tag != .constructor or constructor_origin.target >= ir.constructors.len) return error.InvalidEvidence;
            const constructor = ir.constructors.get(constructor_origin.target);
            if (constructor.origin != row.constructor or constructor.kind != ir.anchors.get(@backingInt(row.anchor)).kind or constructor.kind != g.entries.get(@backingInt(row.entry)).kind or constructor.roles.start > ir.roles.len or constructor.roles.len > ir.roles.len - constructor.roles.start or row.role >= constructor.roles.len or ir.roles.get(constructor.roles.start + row.role).position != row.role) return error.InvalidEvidence;
            const observation = g.observations.get(@backingInt(W.observation));
            if (observation.kind != constructor.kind or observation.prefix != .role or observation.anchor != row.anchor or observation.constructor != row.constructor or observation.role != row.role) return error.InvalidEvidence;
        }
        if (row.captures.start != capture_cursor or row.captures.len > g.captures.len - capture_cursor) return error.InvalidEvidence;
        for (capture_cursor..capture_cursor + row.captures.len) |ci| {
            const capture = g.captures.get(ci);
            if (@backingInt(capture.transfer) != i or capture.entry != row.entry or capture.constructor != row.constructor or capture.role != row.role or capture.closure != row.origin or @backingInt(capture.input) >= ir.inputs.len) return error.InvalidEvidence;
            const input = ir.inputs.get(@backingInt(capture.input));
            if (!input.capture or input.owner != row.template or @backingInt(capture.W) >= g.evidence.queries.len or @backingInt(capture.S) >= g.evidence.queries.len) return error.InvalidEvidence;
            const CW = g.evidence.queries.get(@backingInt(capture.W));
            const CS = g.evidence.queries.get(@backingInt(capture.S));
            var expected_W = W_observation;
            expected_W.capture = capture.input;
            var expected_S = expected_W;
            expected_S.mode = .S;
            if (CW.port != row.source or CS.port != row.source or CW.seed != .none or CS.seed != .none or !std.meta.eql(expected_W, g.observations.get(@backingInt(CW.observation))) or !std.meta.eql(expected_S, g.observations.get(@backingInt(CS.observation))) or capture.status != g.evidence.statuses.items[@backingInt(capture.S)]) return error.InvalidEvidence;
            if (@backingInt(capture.binding) >= g.evidence.bindings.len) return error.InvalidEvidence;
            const binding = g.evidence.bindings.get(@backingInt(capture.binding));
            if (binding.runtime or binding.seed != row.seed or binding.input != capture.input or binding.W != capture.W or binding.S != capture.S) return error.InvalidEvidence;
        }
        capture_cursor += row.captures.len;
    }
    if (capture_cursor != g.captures.len) return error.InvalidEvidence;
}
