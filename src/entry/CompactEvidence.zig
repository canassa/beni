//! Owned original source and shared solver witnesses, never caller environments.
const std = @import("std");
const Ir = @import("Compact.zig");
const Solve = @import("CompactSolve.zig");
const Allocator = std.mem.Allocator;
const Evidence = @This();
pub const Error = error{InvalidEvidence};
/// This owner validates incidence/transport only; never a proof receipt.
pub const semantic_validation: enum { unavailable } = .unavailable;
pub const Counts = struct { source_rows: u64 = 0, source_words: u64 = 0, solver_rows: u64 = 0, derivations: u64 = 0, transports: u64 = 0 };

source: Ir = .{},
queries: std.MultiArrayList(Solve.Query) = .empty,
facts: std.MultiArrayList(Solve.Fact) = .empty,
edges: std.MultiArrayList(Solve.Edge) = .empty,
seeds: std.MultiArrayList(Solve.Seed) = .empty,
bindings: std.MultiArrayList(Solve.Binding) = .empty,
obligations: std.MultiArrayList(Solve.Obligation) = .empty,
derivations: std.MultiArrayList(Solve.Derivation) = .empty,
transports: std.MultiArrayList(Solve.Transport) = .empty,
statuses: std.ArrayList(Solve.StaticStatus) = .empty,
counts: Counts = .{},
const directories = .{ "queries", "facts", "edges", "seeds", "bindings", "obligations", "derivations", "transports", "statuses" };

pub fn reset(e: *Evidence) void {
    inline for (comptime std.meta.fieldNames(Ir)) |name| {
        if (comptime !std.mem.eql(u8, name, "counts")) @field(e.source, name).clearRetainingCapacity();
    }
    e.source.counts = .{};
    inline for (directories) |name| @field(e, name).clearRetainingCapacity();
    e.counts = .{};
}
pub fn deinit(e: *Evidence, a: Allocator) void {
    e.source.deinit(a);
    inline for (directories) |name| @field(e, name).deinit(a);
    e.* = .{};
}
fn copyRows(a: Allocator, target: anytype, source: anytype) Allocator.Error!void {
    try target.ensureTotalCapacity(a, source.len);
    for (0..source.len) |i| target.appendAssumeCapacity(source.get(i));
}
/// Transactionally copy before any phase allocator is released.
pub fn init(a: Allocator, ir: *const Ir, solver: *const Solve, status: []const Solve.StaticStatus) Allocator.Error!Evidence {
    var e: Evidence = .{};
    errdefer e.deinit(a);
    e.source.counts = ir.counts;
    inline for (comptime std.meta.fieldNames(Ir)) |name| {
        if (comptime std.mem.eql(u8, name, "counts")) continue;
        if (comptime std.mem.eql(u8, name, "extra")) {
            try e.source.extra.appendSlice(a, ir.extra.items);
            e.counts.source_words = ir.extra.items.len;
        } else {
            try copyRows(a, &@field(e.source, name), @field(ir, name));
            e.counts.source_rows += @field(ir, name).len;
        }
    }
    inline for (directories) |name| {
        if (comptime std.mem.eql(u8, name, "statuses")) continue;
        try copyRows(a, &@field(e, name), @field(solver, name));
        e.counts.solver_rows += @field(solver, name).len;
    }
    try e.statuses.appendSlice(a, status);
    e.counts.solver_rows += status.len;
    e.counts.derivations = e.derivations.len;
    e.counts.transports = e.transports.len;
    return e;
}
fn index(id: anytype, len: usize) Error!usize {
    const i = @backingInt(id);
    if (i >= len) return error.InvalidEvidence;
    return i;
}
fn rangeValid(range: Ir.Range, len: usize) bool {
    return range.start <= len and range.len <= len - range.start;
}
/// Check the exact original substitution/binding relation, not type equality.
pub fn validateTransport(e: *const Evidence, id: usize, observations: *const std.MultiArrayList(Solve.Observation), answers: *const std.MultiArrayList(Solve.Answer)) Error!void {
    if (id >= e.transports.len) return error.InvalidEvidence;
    const t = e.transports.get(id);
    const edge = e.edges.get(try index(t.edge, e.edges.len));
    if (edge.tag != .copy) return error.InvalidEvidence;
    const source = e.queries.get(try index(edge.source, e.queries.len));
    const target = e.queries.get(try index(edge.target, e.queries.len));
    const input = e.source.inputs.get(try index(t.input, e.source.inputs.len));
    switch (t.kind) {
        .actual => {
            const call = e.source.calls.get(try index(t.call, e.source.calls.len));
            const formal = e.facts.get(try index(t.formal, e.facts.len));
            const original = e.edges.get(try index(t.via, e.edges.len));
            if (original.tag != .substitute or original.call != t.call or original.source != formal.query or original.target != edge.target) return error.InvalidEvidence;
            const actual_port = e.source.ports.get(try index(source.port, e.source.ports.len));
            const expected_seed = if (target.seed != .none and e.seeds.get(try index(target.seed, e.seeds.len)).template == actual_port.owner) target.seed else Solve.SeedId.none;
            if (source.seed != expected_seed) return error.InvalidEvidence;
            const answer = answers.get(try index(formal.answer, answers.len));
            if (answer.tag != .input or answer.input != t.input or answer.observation != source.observation or input.owner != call.target) return error.InvalidEvidence;
            const actuals = if (input.capture) call.captures else call.arguments;
            if (!rangeValid(actuals, e.source.extra.items.len) or input.position >= actuals.len) return error.InvalidEvidence;
            const actual = e.source.ids(Ir.PortId, actuals)[input.position];
            if (actual != t.actual or source.port != actual) return error.InvalidEvidence;
        },
        .binding => {
            if (t.binding >= e.bindings.len) return error.InvalidEvidence;
            const binding = e.bindings.get(t.binding);
            const observation = observations.get(try index(target.observation, observations.len));
            if (observation.prefix != .none or observation.capture != .none or binding.runtime or binding.seed != target.seed or binding.input != t.input or target.port != input.port) return error.InvalidEvidence;
            if ((if (observation.mode == .W) binding.W else binding.S) != edge.source) return error.InvalidEvidence;
        },
    }
}
/// Structural incidence only: local answer equations are NOT certified.
/// Every alternative is retained; future proof consumers must refuse unavailable
/// semantic_validation until a separately reviewed authority is implemented.
pub fn validate(e: *const Evidence, observations: *const std.MultiArrayList(Solve.Observation), answers: *const std.MultiArrayList(Solve.Answer)) Error!void {
    if (e.statuses.items.len != e.queries.len) return error.InvalidEvidence;
    for (0..e.queries.len) |i| {
        const q = e.queries.get(i);
        _ = try index(q.port, e.source.ports.len);
        _ = try index(q.observation, observations.len);
        if (q.seed != .none) _ = try index(q.seed, e.seeds.len);
    }
    for (0..e.facts.len) |i| {
        const f = e.facts.get(i);
        _ = try index(f.query, e.queries.len);
        _ = try index(f.answer, answers.len);
    }
    for (0..e.derivations.len) |i| {
        const d = e.derivations.get(i);
        const target = e.facts.get(try index(d.target, e.facts.len));
        if (d.via == .none) {
            if (d.source != .none) return error.InvalidEvidence;
        } else {
            const edge = e.edges.get(try index(d.via, e.edges.len));
            const source = e.facts.get(try index(d.source, e.facts.len));
            if (edge.target != target.query or edge.source != source.query) return error.InvalidEvidence;
        }
    }
    for (0..e.transports.len) |i| try e.validateTransport(i, observations, answers);
}
