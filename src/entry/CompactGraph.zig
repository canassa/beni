//! Session-owned inspection facts. All source IDs expire with the checked store.
//! No phase-arena port, environment or TypeStore variable escapes in a row.
const std = @import("std");
const Ir = @import("Compact.zig");
const Solve = @import("CompactSolve.zig");
const hashes = @import("../resolve/iface_bytes.zig");
const Allocator = std.mem.Allocator;
const Graph = @This();
const sentinel = std.math.maxInt(u32);
pub const NodeId = enum(u32) { _ };
pub const LiveTag = enum(u8) { decl, derived, twin, ctor, schema, lift };
pub const LiveNode = struct { entry: EntryId, module: Ir.ModuleId, tag: LiveTag, index: NodeId };
pub const EntryId = enum(u32) { none = sentinel, _ };
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
pub const Capture = struct { entry: EntryId, constructor: Ir.OriginId, role: u32, closure: Ir.OriginId, input: Ir.InputId, status: Solve.StaticStatus };
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
/// This partial kernel never sets whole-worker discovery complete.
discovery_complete: bool = false,
input_supported: bool = true,

const containers = .{ "live_nodes", "sites", "templates", "inputs", "origins", "anchors", "selectors", "observations", "answers", "entries", "constructions", "scopes", "callbacks", "captures", "capture_facts", "launches", "residuals", "failures", "bytes" };
pub fn reset(g: *Graph) void {
    inline for (containers) |name| @field(g, name).clearRetainingCapacity();
    g.declaration_liveness = .absent;
    g.counts = .{};
    g.proofs = .{};
    g.discovery_complete = false;
    g.input_supported = true;
}
pub fn deinit(g: *Graph, a: Allocator) void {
    inline for (containers) |name| @field(g, name).deinit(a);
    g.* = .{};
}
pub fn text(g: *const Graph, range: Ir.Range) []const u8 {
    return g.bytes.items[range.start..][0..range.len];
}

/// Copy index-addressed source/proof descriptors before discarding phase arenas.
/// Allocations/calls/ports are intentionally NOT retained: none is referenced by
/// an inspection row. Origins retain only stable checked-source sites.
pub fn snapshot(g: *Graph, a: Allocator, ir: *const Ir, solver: *const Solve) !void {
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
    inline for (.{ "live_nodes", "constructions", "scopes", "callbacks", "captures", "residuals", "failures" }) |name|
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
