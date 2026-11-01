//! Delta queries over shared symbolic templates. Never inserts actuals into a
//! callee's input cells; call substitutions are source edges, not environments.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Ir = @import("Compact.zig");
const sentinel = std.math.maxInt(u32);
const Solver = @This();
pub const QueryId = enum(u32) { none = sentinel, _ };
pub const ObservationId = enum(u32) { none = sentinel, _ };
pub const AnswerId = enum(u32) { none = sentinel, _ };
pub const FactId = enum(u32) { none = sentinel, _ };
pub const EdgeId = enum(u32) { none = sentinel, _ };
pub const BindingId = enum(u32) { none = sentinel, _ };
pub const SeedId = enum(u32) { none = sentinel, _ };
pub const Mode = enum(u8) { W, S };
pub const Reason = Ir.Reason;
pub const Observation = struct {
    mode: Mode = .W,
    /// S-only materialization control obligation; preserves symbolic inputs.
    control: bool = false,
    prefix: enum(u8) { none, field, role } = .none,
    selector: Ir.SelectorId = .none,
    kind: Ir.KindId = .none,
    role: u32 = sentinel,
    constructor: Ir.OriginId = .none,
    /// none selects U(o); a declaration selects B(d,o).
    anchor: Ir.AnchorId = .none,
    capture: Ir.InputId = .none,
};
pub const Answer = struct {
    tag: enum(u8) { absent, input, origin, static_leaf, production, runtime_external, unknown_materialization, residual },
    input: Ir.InputId = .none,
    observation: ObservationId = .none,
    origin: Ir.OriginId = .none,
    anchor: Ir.AnchorId = .none,
    site: Ir.SiteId = .none,
    reason: Reason = .projection,
};
pub const Query = struct {
    port: Ir.PortId,
    observation: ObservationId,
    seed: SeedId,
    facts: FactId = .none,
    consumers: EdgeId = .none,
    obligations: u32 = sentinel,
    binding_next: QueryId = .none,
};
pub const Fact = struct { query: QueryId, answer: AnswerId, next: FactId };
pub const Edge = struct {
    source: QueryId,
    target: QueryId,
    tag: enum(u8) { copy, substitute, seal },
    call: Ir.CallId = .none,
    seal: Ir.SealId = .none,
    next: EdgeId = .none,
};
pub const Obligation = struct { query: QueryId, needs: QueryId, next: u32 };
pub const DerivationId = enum(u32) { none = sentinel, _ };
/// All alternatives for one fact, without enumerating witness paths.
pub const Derivation = struct { target: FactId, source: FactId = .none, via: EdgeId = .none };
/// Metadata about an EXISTING semantic copy edge; never changes its key.
pub const Transport = struct {
    edge: EdgeId,
    via: EdgeId = .none,
    kind: enum(u8) { actual, binding },
    call: Ir.CallId = .none,
    input: Ir.InputId = .none,
    formal: FactId = .none,
    actual: Ir.PortId = .none,
    binding: u32 = sentinel,
};
const Work = struct { tag: enum(u8) { expand, deliver }, index: u32, fact: FactId = .none };
pub const Seed = struct { template: Ir.TemplateId, entry: Ir.AnchorId, role: u32 };
pub const Binding = struct {
    seed: SeedId,
    input: Ir.InputId,
    W: QueryId = .none,
    S: QueryId = .none,
    runtime: bool = false,
};
pub const Counters = struct {
    queries: u64 = 0,
    facts: u64 = 0,
    subscriptions: u64 = 0,
    expansions: u64 = 0,
    deliveries: u64 = 0,
    peak_queue: u64 = 0,
    field_index_work: u64 = 0,
    field_lookup_work: u64 = 0,
    field_edge_work: u64 = 0,
    projection_walk_work: u64 = 0,
};
const QueryKey = struct { port: Ir.PortId, observation: ObservationId, seed: SeedId };
const EdgeKey = struct { source: QueryId, target: QueryId, tag: @FieldType(Edge, "tag"), call: Ir.CallId, seal: Ir.SealId };
const FactKey = struct { query: QueryId, answer: AnswerId };
const Delivery = struct { edge: EdgeId, fact: FactId };
const ObligationKey = struct { query: QueryId, needs: QueryId };
const FieldKey = struct { allocation: Ir.AllocationId, selector: Ir.SelectorId };
const BindingKey = struct { seed: SeedId, input: Ir.InputId };

ir: *const Ir,
a: Allocator,
observations: std.MultiArrayList(Observation) = .empty,
answers: std.MultiArrayList(Answer) = .empty,
queries: std.MultiArrayList(Query) = .empty,
facts: std.MultiArrayList(Fact) = .empty,
edges: std.MultiArrayList(Edge) = .empty,
obligations: std.MultiArrayList(Obligation) = .empty,
work: std.MultiArrayList(Work) = .empty,
derivations: std.MultiArrayList(Derivation) = .empty,
transports: std.MultiArrayList(Transport) = .empty,
derivation_index: std.AutoHashMapUnmanaged(Derivation, void) = .empty,
transport_index: std.AutoHashMapUnmanaged(Transport, void) = .empty,
seeds: std.MultiArrayList(Seed) = .empty,
bindings: std.MultiArrayList(Binding) = .empty,
observation_index: std.AutoHashMapUnmanaged(Observation, ObservationId) = .empty,
answer_index: std.AutoHashMapUnmanaged(Answer, AnswerId) = .empty,
query_index: std.AutoHashMapUnmanaged(QueryKey, QueryId) = .empty,
fact_index: std.AutoHashMapUnmanaged(FactKey, FactId) = .empty,
edge_index: std.AutoHashMapUnmanaged(EdgeKey, EdgeId) = .empty,
delivery_index: std.AutoHashMapUnmanaged(Delivery, void) = .empty,
obligation_index: std.AutoHashMapUnmanaged(ObligationKey, void) = .empty,
binding_index: std.AutoHashMapUnmanaged(BindingKey, u32) = .empty,
pending_bindings: std.AutoHashMapUnmanaged(BindingKey, QueryId) = .empty,
field_index: std.AutoHashMapUnmanaged(FieldKey, Ir.PortId) = .empty,
field_index_built: bool = false,
local_stack: std.ArrayList(Ir.PortId) = .empty,
local_results: std.ArrayList(Ir.PortId) = .empty,
local_controls: std.ArrayList(Ir.PortId) = .empty,
local_seen: std.ArrayList(u32) = .empty,
local_epoch: u32 = 0,
cursor: usize = 0,
counts: Counters = .{},

pub fn deinit(s: *Solver) void {
    inline for (.{ "derivations", "transports", "derivation_index", "transport_index", "observations", "answers", "queries", "facts", "edges", "obligations", "work", "seeds", "bindings", "observation_index", "answer_index", "query_index", "fact_index", "edge_index", "delivery_index", "obligation_index", "binding_index", "pending_bindings", "field_index", "local_stack", "local_results", "local_controls", "local_seen" }) |name| @field(s, name).deinit(s.a);
}

pub fn observe(s: *Solver, value: Observation) Allocator.Error!ObservationId {
    std.debug.assert(!value.control or value.mode == .S);
    const found = try s.observation_index.getOrPut(s.a, value);
    if (found.found_existing) return found.value_ptr.*;
    const index: ObservationId = @fromBackingInt(@intCast(s.observations.len));
    try s.observations.append(s.a, value);
    found.value_ptr.* = index;
    return index;
}

pub fn ask(s: *Solver, port: Ir.PortId, observation: ObservationId, seed: SeedId) Allocator.Error!QueryId {
    const effective_seed = if (seed != .none and s.seeds.get(@backingInt(seed)).template == s.ir.ports.get(@backingInt(port)).owner) seed else SeedId.none;
    const key: QueryKey = .{ .port = port, .observation = observation, .seed = effective_seed };
    const found = try s.query_index.getOrPut(s.a, key);
    if (found.found_existing) return found.value_ptr.*;
    const index: QueryId = @fromBackingInt(@intCast(s.queries.len));
    try s.queries.append(s.a, .{ .port = port, .observation = observation, .seed = effective_seed });
    found.value_ptr.* = index;
    try s.enqueue(.{ .tag = .expand, .index = @backingInt(index) });
    s.counts.queries += 1;
    return index;
}

fn enqueue(s: *Solver, value: Work) Allocator.Error!void {
    try s.work.append(s.a, value);
    s.counts.peak_queue = @max(s.counts.peak_queue, s.work.len - s.cursor);
}

fn internAnswer(s: *Solver, value: Answer) Allocator.Error!AnswerId {
    const found = try s.answer_index.getOrPut(s.a, value);
    if (found.found_existing) return found.value_ptr.*;
    const index: AnswerId = @fromBackingInt(@intCast(s.answers.len));
    try s.answers.append(s.a, value);
    found.value_ptr.* = index;
    return index;
}

pub fn publish(s: *Solver, target: QueryId, value: Answer) Allocator.Error!void {
    return s.publishFrom(target, value, .none, .none);
}
fn derive(s: *Solver, value: Derivation) Allocator.Error!void {
    const found = try s.derivation_index.getOrPut(s.a, value);
    if (!found.found_existing) try s.derivations.append(s.a, value);
}
fn transport(s: *Solver, value: Transport) Allocator.Error!void {
    const found = try s.transport_index.getOrPut(s.a, value);
    if (!found.found_existing) try s.transports.append(s.a, value);
}
fn copyEdge(s: *const Solver, target: QueryId, source: QueryId) EdgeId {
    return s.edge_index.get(.{ .source = source, .target = target, .tag = .copy, .call = .none, .seal = .none }).?;
}
fn publishFrom(s: *Solver, target: QueryId, value: Answer, source: FactId, via: EdgeId) Allocator.Error!void {
    var normalized = value;
    const request = s.observations.get(@backingInt(s.queries.get(@backingInt(target)).observation));
    if (request.control) switch (value.tag) {
        .runtime_external => normalized = .{ .tag = .residual, .site = value.site, .reason = .materialization_control },
        .input => {
            var requirement = s.observations.get(@backingInt(value.observation));
            requirement.control = true;
            normalized.observation = try s.observe(requirement);
        },
        else => {},
    };
    const answer = try s.internAnswer(normalized);
    const found = try s.fact_index.getOrPut(s.a, .{ .query = target, .answer = answer });
    if (found.found_existing) {
        try s.derive(.{ .target = found.value_ptr.*, .source = source, .via = via });
        return;
    }
    const index: FactId = @fromBackingInt(@intCast(s.facts.len));
    try s.facts.append(s.a, .{ .query = target, .answer = answer, .next = s.queries.items(.facts)[@backingInt(target)] });
    s.queries.items(.facts)[@backingInt(target)] = index;
    found.value_ptr.* = index;
    try s.derive(.{ .target = index, .source = source, .via = via });
    s.counts.facts += 1;
    var edge = s.queries.items(.consumers)[@backingInt(target)];
    while (edge != .none) : (edge = s.edges.items(.next)[@backingInt(edge)]) try s.enqueueDelivery(edge, index);
}

fn enqueueDelivery(s: *Solver, edge: EdgeId, fact: FactId) Allocator.Error!void {
    const found = try s.delivery_index.getOrPut(s.a, .{ .edge = edge, .fact = fact });
    if (found.found_existing) return;
    try s.enqueue(.{ .tag = .deliver, .index = @backingInt(edge), .fact = fact });
}

fn subscribe(s: *Solver, key: EdgeKey) Allocator.Error!void {
    const found = try s.edge_index.getOrPut(s.a, key);
    if (found.found_existing) return;
    const index: EdgeId = @fromBackingInt(@intCast(s.edges.len));
    try s.edges.append(s.a, .{ .source = key.source, .target = key.target, .tag = key.tag, .call = key.call, .seal = key.seal, .next = s.queries.items(.consumers)[@backingInt(key.source)] });
    s.queries.items(.consumers)[@backingInt(key.source)] = index;
    found.value_ptr.* = index;
    s.counts.subscriptions += 1;
    var fact = s.queries.items(.facts)[@backingInt(key.source)];
    while (fact != .none) : (fact = s.facts.items(.next)[@backingInt(fact)]) try s.enqueueDelivery(index, fact);
}

fn require(s: *Solver, target: QueryId, source: QueryId) Allocator.Error!void {
    const found = try s.obligation_index.getOrPut(s.a, .{ .query = target, .needs = source });
    if (found.found_existing) return;
    const index: u32 = @intCast(s.obligations.len);
    try s.obligations.append(s.a, .{ .query = target, .needs = source, .next = s.queries.items(.obligations)[@backingInt(target)] });
    s.queries.items(.obligations)[@backingInt(target)] = index;
}

fn copyFrom(s: *Solver, target: QueryId, source: QueryId) Allocator.Error!void {
    try s.subscribe(.{ .source = source, .target = target, .tag = .copy, .call = .none, .seal = .none });
    if (s.observations.get(@backingInt(s.queries.get(@backingInt(target)).observation)).mode == .S)
        try s.require(target, source);
}

fn follow(s: *Solver, target: QueryId, port: Ir.PortId, observation: Observation, seed: SeedId) Allocator.Error!void {
    const source = try s.ask(port, try s.observe(observation), seed);
    try s.copyFrom(target, source);
}

fn residual(s: *Solver, target: QueryId, site: Ir.SiteId, reason: Reason) Allocator.Error!void {
    try s.publish(target, .{ .tag = .residual, .site = site, .reason = reason });
}

pub fn addSeed(s: *Solver, value: Seed) Allocator.Error!SeedId {
    const index: SeedId = @fromBackingInt(@intCast(s.seeds.len));
    try s.seeds.append(s.a, value);
    return index;
}

/// Bind before asking the seed's template. The source queries themselves remain
/// live subscriptions, so a later Program fact reaches the runtime formal.
pub fn bind(s: *Solver, value: Binding) Allocator.Error!void {
    const key: BindingKey = .{ .seed = value.seed, .input = value.input };
    const found = try s.binding_index.getOrPut(s.a, key);
    if (found.found_existing) {
        std.debug.assert(std.meta.eql(s.bindings.get(found.value_ptr.*), value));
        return;
    }
    const index: u32 = @intCast(s.bindings.len);
    try s.bindings.append(s.a, value);
    found.value_ptr.* = index;
    if (s.pending_bindings.fetchRemove(key)) |pending| {
        var waiter = pending.value;
        while (waiter != .none) {
            const next = s.queries.items(.binding_next)[@backingInt(waiter)];
            s.queries.items(.binding_next)[@backingInt(waiter)] = .none;
            try s.enqueue(.{ .tag = .expand, .index = @backingInt(waiter) });
            waiter = next;
        }
    }
}

/// Exact original binding directory identity, not a reconstructed source name.
pub fn bindingId(s: *const Solver, seed: SeedId, input: Ir.InputId) ?BindingId {
    return if (s.binding_index.get(.{ .seed = seed, .input = input })) |i| @fromBackingInt(i) else null;
}

pub fn drain(s: *Solver) Allocator.Error!void {
    while (s.cursor < s.work.len) {
        const item = s.work.get(s.cursor);
        s.cursor += 1;
        switch (item.tag) {
            .expand => {
                s.counts.expansions += 1;
                try s.expand(@fromBackingInt(item.index));
            },
            .deliver => {
                s.counts.deliveries += 1;
                try s.deliver(@fromBackingInt(item.index), item.fact);
            },
        }
    }
    s.work.clearRetainingCapacity();
    s.cursor = 0;
}

fn deliver(s: *Solver, edge_id: EdgeId, fact_id: FactId) Allocator.Error!void {
    const edge = s.edges.get(@backingInt(edge_id));
    const value = s.answers.get(@backingInt(s.facts.get(@backingInt(fact_id)).answer));
    switch (edge.tag) {
        .copy => try s.publishFrom(edge.target, value, fact_id, edge_id),
        .substitute => {
            if (value.tag != .input) {
                try s.publishFrom(edge.target, value, fact_id, edge_id);
                return;
            }
            const call = s.ir.calls.get(@backingInt(edge.call));
            const input = s.ir.inputs.get(@backingInt(value.input));
            if (input.owner != call.target) {
                try s.residual(edge.target, call.site, .missing_binding);
                return;
            }
            const arguments = s.ir.ids(Ir.PortId, if (input.capture) call.captures else call.arguments);
            if (input.position >= arguments.len) {
                try s.residual(edge.target, call.site, .missing_binding);
                return;
            }
            const target = s.queries.get(@backingInt(edge.target));
            const source = try s.ask(arguments[input.position], value.observation, target.seed);
            try s.copyFrom(edge.target, source);
            try s.transport(.{ .edge = s.copyEdge(edge.target, source), .kind = .actual, .via = edge_id, .call = edge.call, .input = value.input, .formal = fact_id, .actual = arguments[input.position] });
        },
        .seal => {
            var forwarded = value;
            if (value.tag == .origin and value.anchor == .none and value.origin != .none) {
                const origin = s.ir.origins.get(@backingInt(value.origin));
                if (origin.tag == .constructor) {
                    const boundary = s.ir.seals.get(@backingInt(edge.seal));
                    if (s.ir.constructors.get(origin.target).kind == boundary.kind) forwarded.anchor = boundary.anchor;
                }
            }
            try s.publishFrom(edge.target, forwarded, fact_id, edge_id);
        },
    }
}

fn plain(value: Observation) Observation {
    return .{ .mode = value.mode, .capture = value.capture, .control = value.control };
}
fn selected(value: Observation, selector: Ir.SelectorId) Observation {
    return .{ .mode = value.mode, .prefix = .field, .selector = selector, .capture = value.capture, .control = value.control };
}
fn absent(s: *Solver, target: QueryId) Allocator.Error!void {
    try s.publish(target, .{ .tag = .absent });
}

fn expand(s: *Solver, query_id: QueryId) Allocator.Error!void {
    const query = s.queries.get(@backingInt(query_id));
    const port = s.ir.ports.get(@backingInt(query.port));
    const observation = s.observations.get(@backingInt(query.observation));
    switch (port.tag) {
        .input => {
            const input_id: Ir.InputId = @fromBackingInt(port.lhs);
            if (query.seed == .none) {
                try s.publish(query_id, .{ .tag = .input, .input = input_id, .observation = query.observation });
                return;
            }
            const binding_id = s.binding_index.get(.{ .seed = query.seed, .input = input_id }) orelse {
                const entry = try s.pending_bindings.getOrPut(s.a, .{ .seed = query.seed, .input = input_id });
                const previous = if (entry.found_existing) entry.value_ptr.* else QueryId.none;
                s.queries.items(.binding_next)[@backingInt(query_id)] = previous;
                entry.value_ptr.* = query_id;
                return;
            };
            const binding = s.bindings.get(binding_id);
            if (observation.prefix != .none or observation.capture != .none) {
                try s.residual(query_id, port.site, .projection);
                return;
            }
            if (binding.runtime) {
                try s.publish(query_id, .{ .tag = .runtime_external, .site = port.site });
                return;
            }
            const source = if (observation.mode == .W) binding.W else binding.S;
            if (source == .none) {
                try s.residual(query_id, port.site, .missing_binding);
                return;
            }
            try s.copyFrom(query_id, source);
            try s.transport(.{ .edge = s.copyEdge(query_id, source), .kind = .binding, .input = input_id, .binding = binding_id });
        },
        .alias => try s.follow(query_id, @fromBackingInt(port.lhs), observation, query.seed),
        .alternatives => {
            for (s.ir.ids(Ir.PortId, port.values)) |alternative| try s.follow(query_id, alternative, observation, query.seed);
            if (observation.mode == .S and port.rhs != sentinel and !(observation.prefix == .role and observation.anchor != .none))
                try s.follow(query_id, @fromBackingInt(port.rhs), .{ .mode = .S, .control = true }, query.seed);
        },
        .function, .literal, .@"opaque", .runtime => {
            const origin: Ir.OriginId = @fromBackingInt(port.lhs);
            if (port.tag == .@"opaque" or port.tag == .runtime) {
                try s.publish(query_id, if (observation.mode == .W)
                    .{ .tag = .origin, .origin = origin }
                else if (port.tag == .runtime)
                    .{ .tag = .runtime_external, .site = port.site }
                else
                    .{ .tag = .unknown_materialization, .site = port.site });
                return;
            }
            if (observation.prefix != .none or observation.capture != .none) {
                try s.absent(query_id);
                return;
            }
            try s.publish(query_id, .{ .tag = if (observation.mode == .W) .origin else .static_leaf, .origin = origin });
        },
        .closure => {
            const origin: Ir.OriginId = @fromBackingInt(port.lhs);
            const lambda: Ir.TemplateId = @fromBackingInt(s.ir.origins.get(@backingInt(origin)).target);
            if (observation.prefix != .none) {
                try s.absent(query_id);
                return;
            }
            if (observation.capture != .none) {
                const capture = s.ir.inputs.get(@backingInt(observation.capture));
                if (capture.owner != lambda or !capture.capture) {
                    try s.absent(query_id);
                    return;
                }
                if (capture.defining == .none) {
                    try s.residual(query_id, port.site, .missing_binding);
                    return;
                }
                try s.follow(query_id, capture.defining, .{ .mode = observation.mode, .control = observation.control }, query.seed);
                return;
            }
            try s.publish(query_id, .{ .tag = if (observation.mode == .W) .origin else .production, .origin = origin });
            if (observation.mode == .S) for (s.ir.ids(Ir.InputId, s.ir.templates.get(@backingInt(lambda)).inputs)) |input_id| {
                const input = s.ir.inputs.get(@backingInt(input_id));
                if (!input.capture) continue;
                if (input.defining == .none) {
                    try s.residual(query_id, port.site, .missing_binding);
                } else try s.follow(query_id, input.defining, .{ .mode = .S, .control = observation.control }, query.seed);
            };
        },
        .allocation => {
            const allocation = s.ir.allocations.get(port.lhs);
            if (observation.prefix == .role or (observation.prefix == .none and observation.capture != .none)) {
                try s.absent(query_id);
                return;
            }
            if (observation.prefix == .field) {
                if (try s.field(@fromBackingInt(port.lhs), observation.selector)) |value| {
                    s.counts.field_edge_work += 1;
                    try s.follow(query_id, value, plain(observation), query.seed);
                    return;
                }
                if (allocation.base != .none) {
                    s.counts.field_edge_work += 1;
                    try s.follow(query_id, allocation.base, observation, query.seed);
                } else try s.absent(query_id);
                return;
            }
            try s.publish(query_id, .{ .tag = if (observation.mode == .W) .origin else .production, .origin = allocation.origin });
            if (observation.mode == .W) return;
            if (allocation.base == .none) {
                for (allocation.fields.start..allocation.fields.start + allocation.fields.len) |fi| {
                    s.counts.field_edge_work += 1;
                    try s.follow(query_id, s.ir.fields.get(fi).value, .{ .mode = .S, .control = observation.control }, query.seed);
                }
                return;
            }
            if (!allocation.shape_complete or allocation.shape.len == 0) {
                try s.residual(query_id, port.site, .shape);
                return;
            }
            for (s.ir.ids(Ir.SelectorId, allocation.shape)) |selector| {
                s.counts.field_edge_work += 1;
                try s.follow(query_id, query.port, .{ .mode = .S, .prefix = .field, .selector = selector, .control = observation.control }, query.seed);
            }
        },
        .project => {
            const base: Ir.PortId = @fromBackingInt(port.lhs);
            const selector: Ir.SelectorId = @fromBackingInt(port.rhs);
            if (observation.prefix == .none) {
                try s.follow(query_id, base, selected(observation, selector), query.seed);
                return;
            }
            // A second unresolved selector is outside the reviewed observation
            // grammar. Consume a known source-local allocation first if possible.
            const observe_control = observation.mode == .S and !(observation.prefix == .role and observation.anchor != .none);
            const complete = try s.localFields(base, selector, observe_control);
            if (!complete) try s.residual(query_id, port.site, .projection);
            for (s.local_results.items) |value| try s.follow(query_id, value, observation, query.seed);
            for (s.local_controls.items) |control| try s.follow(query_id, control, .{ .mode = .S, .control = true }, query.seed);
            if (complete and s.local_results.items.len == 0) try s.absent(query_id);
        },
        .call => {
            const call_id: Ir.CallId = @fromBackingInt(port.lhs);
            const call = s.ir.calls.get(@backingInt(call_id));
            if (call.target == .none) {
                try s.residual(query_id, call.site, call.residual_reason);
                return;
            }
            const body: Ir.PortId = if (port.rhs == sentinel) s.ir.templates.get(@backingInt(call.target)).body else @fromBackingInt(port.rhs);
            if (body == .none) {
                try s.residual(query_id, call.site, .missing_body);
                return;
            }
            const source = try s.ask(body, query.observation, .none);
            try s.subscribe(.{ .source = source, .target = query_id, .tag = .substitute, .call = call_id, .seal = .none });
        },
        .constructor => {
            const constructor = s.ir.constructors.get(port.lhs);
            if (observation.prefix == .role) {
                if (observation.constructor != constructor.origin or observation.anchor != .none or observation.kind != constructor.kind) {
                    try s.absent(query_id);
                    return;
                }
                if (observation.role >= constructor.roles.len) {
                    try s.residual(query_id, port.site, .shape);
                    return;
                }
                const role = s.ir.roles.get(constructor.roles.start + observation.role);
                try s.follow(query_id, constructor.callbacks, selected(observation, role.selector), query.seed);
                return;
            }
            if (observation.prefix != .none or observation.capture != .none) {
                try s.absent(query_id);
                return;
            }
            try s.publish(query_id, .{ .tag = if (observation.mode == .W) .origin else .production, .origin = constructor.origin });
            if (observation.mode == .S) {
                try s.follow(query_id, constructor.callbacks, .{ .mode = .S, .control = observation.control }, query.seed);
                for (s.ir.ids(Ir.PortId, constructor.arguments)) |argument| try s.follow(query_id, argument, .{ .mode = .S, .control = observation.control }, query.seed);
            }
        },
        .seal => {
            const seal_id: Ir.SealId = @fromBackingInt(port.lhs);
            const seal = s.ir.seals.get(@backingInt(seal_id));
            if (observation.prefix == .role) {
                if (observation.anchor == .none) {
                    try s.absent(query_id);
                    return;
                }
                // Existing B(e,o), INCLUDING e=d, is always forwarded unchanged.
                try s.follow(query_id, seal.initializer, observation, query.seed);
                if (observation.anchor == seal.anchor) {
                    var newly_sealed = observation;
                    newly_sealed.anchor = .none;
                    try s.follow(query_id, seal.initializer, newly_sealed, query.seed);
                }
                return;
            }
            if (observation.prefix != .none or observation.capture != .none) {
                try s.absent(query_id);
                return;
            }
            if (observation.mode == .S) {
                try s.follow(query_id, seal.initializer, observation, query.seed);
            } else {
                const source = try s.ask(seal.initializer, query.observation, query.seed);
                try s.subscribe(.{ .source = source, .target = query_id, .tag = .seal, .call = .none, .seal = seal_id });
            }
        },
        .residual => try s.residual(query_id, port.site, @fromBackingInt(@intCast(port.lhs))),
    }
}

/// A shared sparse source index, never a selector product or caller cache.
fn field(s: *Solver, allocation: Ir.AllocationId, selector: Ir.SelectorId) Allocator.Error!?Ir.PortId {
    if (!s.field_index_built) {
        for (0..s.ir.fields.len) |i| {
            const row = s.ir.fields.get(i);
            s.counts.field_index_work += 1;
            const found = try s.field_index.getOrPut(s.a, .{ .allocation = row.allocation, .selector = row.selector });
            if (!found.found_existing) found.value_ptr.* = row.value;
        }
        s.field_index_built = true;
    }
    s.counts.field_lookup_work += 1;
    return s.field_index.get(.{ .allocation = allocation, .selector = selector });
}

/// Only source-local alias/union/allocation edges are reduced here. A call or
/// formal needs a composed profile, so remains an explicit residual. Traversal
/// is iterative and stamps index dense source IDs directly.
fn localFields(s: *Solver, base: Ir.PortId, selector: Ir.SelectorId, observe_control: bool) Allocator.Error!bool {
    s.local_stack.clearRetainingCapacity();
    s.local_results.clearRetainingCapacity();
    s.local_controls.clearRetainingCapacity();
    if (s.local_seen.items.len != s.ir.ports.len) {
        try s.local_seen.resize(s.a, s.ir.ports.len);
        @memset(s.local_seen.items, 0);
    }
    s.local_epoch +%= 1;
    if (s.local_epoch == 0) {
        @memset(s.local_seen.items, 0);
        s.local_epoch = 1;
    }
    try s.local_stack.append(s.a, base);
    var complete = true;
    while (s.local_stack.pop()) |value| {
        s.counts.projection_walk_work += 1;
        if (s.local_seen.items[@backingInt(value)] == s.local_epoch) continue;
        s.local_seen.items[@backingInt(value)] = s.local_epoch;
        const port = s.ir.ports.get(@backingInt(value));
        switch (port.tag) {
            .alias => try s.local_stack.append(s.a, @fromBackingInt(port.lhs)),
            .alternatives => {
                try s.local_stack.appendSlice(s.a, s.ir.ids(Ir.PortId, port.values));
                // Source-local reduction consumes the record value edge, but
                // its materialization control remains an independent S input.
                if (observe_control and port.rhs != sentinel)
                    try s.local_controls.append(s.a, @fromBackingInt(port.rhs));
            },
            .allocation => {
                const allocation = s.ir.allocations.get(port.lhs);
                if (try s.field(@fromBackingInt(port.lhs), selector)) |field_value| {
                    s.counts.field_edge_work += 1;
                    try s.local_results.append(s.a, field_value);
                } else if (allocation.base != .none) {
                    s.counts.field_edge_work += 1;
                    try s.local_stack.append(s.a, allocation.base);
                }
            },
            .function, .literal, .closure, .constructor => {},
            else => complete = false,
        }
    }
    return complete;
}

// Semantic supplements for the phase-local algebra. Production coverage is the
// checked-source inspector suite, which also observes these structural counters.
const Probe = struct {
    fn template(ir: *Ir, a: Allocator, arity: usize) !Ir.TemplateId {
        const site: Ir.SiteId = @fromBackingInt(@intCast(ir.sites.len));
        try ir.sites.append(a, .{ .module = @fromBackingInt(0), .declaration = @fromBackingInt(@intCast(ir.templates.len)), .instruction = @fromBackingInt(0) });
        const result = try ir.addTemplate(a, .{ .site = site });
        var inputs: std.ArrayList(Ir.InputId) = .empty;
        defer inputs.deinit(a);
        for (0..arity) |position| {
            const port = try ir.addPort(a, .{ .owner = result, .site = site, .tag = .input });
            const input = try ir.addInput(a, .{ .owner = result, .position = @intCast(position), .port = port, .capture = false });
            ir.ports.items(.lhs)[@backingInt(port)] = @backingInt(input);
            try inputs.append(a, input);
        }
        ir.templates.items(.inputs)[@backingInt(result)] = try ir.appendIds(a, inputs.items);
        return result;
    }
    fn parameter(ir: *const Ir, owner: Ir.TemplateId, position: usize) Ir.PortId {
        return ir.inputs.get(@backingInt(ir.ids(Ir.InputId, ir.templates.get(@backingInt(owner)).inputs)[position])).port;
    }
    fn body(ir: *Ir, owner: Ir.TemplateId, value: Ir.PortId) void {
        ir.templates.items(.body)[@backingInt(owner)] = value;
    }
    fn call(ir: *Ir, a: Allocator, owner: Ir.TemplateId, target: Ir.TemplateId, arguments: []const Ir.PortId) !Ir.PortId {
        const site = ir.templates.get(@backingInt(owner)).site;
        const row = try ir.addCall(a, .{ .owner = owner, .site = site, .target = target, .callee = .none, .arguments = try ir.appendIds(a, arguments) });
        return ir.addPort(a, .{ .owner = owner, .site = site, .tag = .call, .lhs = @backingInt(row) });
    }
    fn leaf(ir: *Ir, a: Allocator, owner: Ir.TemplateId, tag: Ir.Port.Tag) !Ir.PortId {
        const site = ir.templates.get(@backingInt(owner)).site;
        const origin = try ir.addOrigin(a, .{ .tag = switch (tag) {
            .function => .function,
            .literal => .literal,
            .runtime => .runtime,
            .@"opaque" => .@"opaque",
            else => unreachable,
        }, .site = site, .target = @backingInt(owner) });
        return ir.addPort(a, .{ .owner = owner, .site = site, .tag = tag, .lhs = @backingInt(origin) });
    }
    fn capture(ir: *Ir, a: Allocator, owner: Ir.TemplateId, defining: Ir.PortId) !Ir.InputId {
        const old = ir.templates.get(@backingInt(owner)).inputs;
        var inputs: std.ArrayList(Ir.InputId) = .empty;
        defer inputs.deinit(a);
        try inputs.appendSlice(a, ir.ids(Ir.InputId, old));
        const site = ir.templates.get(@backingInt(owner)).site;
        const port = try ir.addPort(a, .{ .owner = owner, .site = site, .tag = .input });
        var capture_position: u32 = 0;
        for (inputs.items) |id| if (ir.inputs.get(@backingInt(id)).capture) {
            capture_position += 1;
        };
        const result = try ir.addInput(a, .{ .owner = owner, .position = capture_position, .port = port, .capture = true, .defining = defining });
        ir.ports.items(.lhs)[@backingInt(port)] = @backingInt(result);
        try inputs.append(a, result);
        ir.templates.items(.inputs)[@backingInt(owner)] = try ir.appendIds(a, inputs.items);
        return result;
    }
    fn factory(ir: *Ir, a: Allocator, selector: Ir.SelectorId) !Ir.TemplateId {
        const owner = try template(ir, a, 1);
        const callbacks = try allocation(ir, a, owner, selector, parameter(ir, owner, 0));
        const site = ir.templates.get(@backingInt(owner)).site;
        const origin = try ir.addOrigin(a, .{ .tag = .constructor, .site = site });
        const roles: Ir.Range = .{ .start = @intCast(ir.roles.len), .len = 1 };
        try ir.roles.append(a, .{ .selector = selector, .position = 0 });
        const row = try ir.addConstructor(a, .{ .kind = @fromBackingInt(0), .origin = origin, .callbacks = callbacks, .roles = roles });
        ir.origins.items(.target)[@backingInt(origin)] = @backingInt(row);
        body(ir, owner, try ir.addPort(a, .{ .owner = owner, .site = site, .tag = .constructor, .lhs = @backingInt(row) }));
        return owner;
    }
    fn anchor(ir: *Ir, a: Allocator, owner: Ir.TemplateId) !Ir.AnchorId {
        const site = ir.templates.get(@backingInt(owner)).site;
        const source = ir.sites.get(@backingInt(site));
        return ir.addAnchor(a, .{ .module = source.module, .declaration = source.declaration, .kind = @fromBackingInt(0), .site = site });
    }
    fn seal(ir: *Ir, a: Allocator, owner: Ir.TemplateId, identity: Ir.AnchorId, initializer: Ir.PortId) !Ir.PortId {
        const row = try ir.addSeal(a, .{ .anchor = identity, .kind = @fromBackingInt(0), .initializer = initializer });
        return ir.addPort(a, .{ .owner = owner, .site = ir.templates.get(@backingInt(owner)).site, .tag = .seal, .lhs = @backingInt(row) });
    }
    fn allocation(ir: *Ir, a: Allocator, owner: Ir.TemplateId, selector: Ir.SelectorId, value: Ir.PortId) !Ir.PortId {
        const site = ir.templates.get(@backingInt(owner)).site;
        const origin = try ir.addOrigin(a, .{ .tag = .allocation, .site = site });
        const row = try ir.addAllocation(a, .{ .tag = .record, .origin = origin, .fields = .{ .start = @intCast(ir.fields.len), .len = 1 } });
        ir.origins.items(.target)[@backingInt(origin)] = @backingInt(row);
        try ir.fields.append(a, .{ .allocation = row, .selector = selector, .value = value });
        return ir.addPort(a, .{ .owner = owner, .site = site, .tag = .allocation, .lhs = @backingInt(row) });
    }
};

fn answerLess(_: void, left: Answer, right: Answer) bool {
    const l = [_]u32{ @backingInt(left.tag), @backingInt(left.input), @backingInt(left.observation), @backingInt(left.origin), @backingInt(left.anchor), @backingInt(left.site), @backingInt(left.reason) };
    const r = [_]u32{ @backingInt(right.tag), @backingInt(right.input), @backingInt(right.observation), @backingInt(right.origin), @backingInt(right.anchor), @backingInt(right.site), @backingInt(right.reason) };
    for (l, r) |a, b| if (a != b) return a < b;
    return false;
}
fn expectAnswers(s: *const Solver, query: QueryId, expected: []const Answer) !void {
    const a = std.testing.allocator;
    var actual: std.ArrayList(Answer) = .empty;
    defer actual.deinit(a);
    var at = s.queries.get(@backingInt(query)).facts;
    while (at != .none) : (at = s.facts.items(.next)[@backingInt(at)]) {
        const value = s.answers.get(@backingInt(s.facts.get(@backingInt(at)).answer));
        if (value.tag != .absent) try actual.append(a, value);
    }
    const wanted = try a.dupe(Answer, expected);
    defer a.free(wanted);
    std.mem.sort(Answer, actual.items, {}, answerLess);
    std.mem.sort(Answer, wanted, {}, answerLess);
    try std.testing.expectEqualDeep(wanted, actual.items);
}

test "compact symbolic forwarding diamonds have exact linear fact and delivery counts" {
    for ([_]usize{ 8, 16, 32, 64 }) |levels| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var ir: Ir = .{};
        defer ir.deinit(a);
        var previous = try Probe.template(&ir, a, 1);
        Probe.body(&ir, previous, Probe.parameter(&ir, previous, 0));
        for (0..levels) |_| {
            const current = try Probe.template(&ir, a, 1);
            const input = Probe.parameter(&ir, current, 0);
            const left = try Probe.call(&ir, a, current, previous, &.{input});
            const right = try Probe.call(&ir, a, current, previous, &.{input});
            const joined = try ir.addPort(a, .{ .owner = current, .site = ir.templates.get(@backingInt(current)).site, .tag = .alternatives, .values = try ir.appendIds(a, &[_]Ir.PortId{ left, right }) });
            Probe.body(&ir, current, joined);
            previous = current;
        }
        var s: Solver = .{ .ir = &ir, .a = a };
        defer s.deinit();
        const whole = try s.observe(.{});
        const result = try s.ask(ir.templates.get(@backingInt(previous)).body, whole, .none);
        try s.drain();
        const input_id = ir.ids(Ir.InputId, ir.templates.get(@backingInt(previous)).inputs)[0];
        try expectAnswers(&s, result, &.{.{ .tag = .input, .input = input_id, .observation = whole }});
        try std.testing.expectEqual(levels + 1, ir.templates.len);
        try std.testing.expectEqual(2 * levels, ir.calls.len);
        try std.testing.expectEqualDeep(Counters{
            .queries = 4 * levels + 1,
            .facts = 4 * levels + 1,
            .subscriptions = 6 * levels,
            .expansions = 4 * levels + 1,
            .deliveries = 6 * levels,
            .peak_queue = s.counts.peak_queue,
        }, s.counts);
        try std.testing.expect(s.counts.peak_queue <= 6);
    }
}

test "compact shared relay preserves paired provenance of a captured record" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ir: Ir = .{};
    defer ir.deinit(a);
    var b: Ir.Builder = .{ .ir = &ir, .a = a };
    defer b.deinit();
    const payload = try b.selector(.{ .tag = .field, .value = 42 });
    const wrap = try Probe.template(&ir, a, 1);
    const record = try Probe.allocation(&ir, a, wrap, payload, Probe.parameter(&ir, wrap, 0));
    const lambda = try Probe.template(&ir, a, 0);
    const capture = try Probe.capture(&ir, a, lambda, record);
    const origin = try ir.addOrigin(a, .{ .tag = .closure, .site = ir.templates.get(@backingInt(lambda)).site, .target = @backingInt(lambda) });
    const closure = try ir.addPort(a, .{ .owner = wrap, .site = ir.templates.get(@backingInt(wrap)).site, .tag = .closure, .lhs = @backingInt(origin) });
    Probe.body(&ir, wrap, closure);
    const relay = try Probe.template(&ir, a, 1);
    Probe.body(&ir, relay, try Probe.call(&ir, a, relay, wrap, &.{Probe.parameter(&ir, relay, 0)}));
    const foo = try Probe.template(&ir, a, 0);
    const first = try Probe.leaf(&ir, a, foo, .function);
    const foo_value = try Probe.call(&ir, a, foo, relay, &.{first});
    const bar = try Probe.template(&ir, a, 0);
    const runtime = try Probe.leaf(&ir, a, bar, .runtime);
    const bar_value = try Probe.call(&ir, a, bar, relay, &.{runtime});
    var s: Solver = .{ .ir = &ir, .a = a };
    defer s.deinit();
    const W = try s.observe(.{ .capture = capture });
    const S = try s.observe(.{ .capture = capture, .mode = .S });
    const plain_S = try s.observe(.{ .mode = .S });
    const foo_W = try s.ask(foo_value, W, .none);
    const foo_S = try s.ask(foo_value, S, .none);
    const bar_W = try s.ask(bar_value, W, .none);
    const bar_S = try s.ask(bar_value, S, .none);
    const relay_S = try s.ask(ir.templates.get(@backingInt(relay)).body, S, .none);
    try s.drain();
    const record_origin = ir.allocations.get(ir.ports.get(@backingInt(record)).lhs).origin;
    try expectAnswers(&s, foo_W, &.{.{ .tag = .origin, .origin = record_origin }});
    try expectAnswers(&s, bar_W, &.{.{ .tag = .origin, .origin = record_origin }});
    try expectAnswers(&s, foo_S, &.{ .{ .tag = .production, .origin = record_origin }, .{ .tag = .static_leaf, .origin = @fromBackingInt(ir.ports.get(@backingInt(first)).lhs) } });
    try expectAnswers(&s, bar_S, &.{ .{ .tag = .production, .origin = record_origin }, .{ .tag = .runtime_external, .site = ir.ports.get(@backingInt(runtime)).site } });
    try expectAnswers(&s, relay_S, &.{ .{ .tag = .production, .origin = record_origin }, .{ .tag = .input, .input = ir.ids(Ir.InputId, ir.templates.get(@backingInt(relay)).inputs)[0], .observation = plain_S } });
    const finalized = try s.finalizeStatic();
    defer a.free(finalized.status);
    try std.testing.expectEqual(StaticStatus.closed, finalized.status[@backingInt(foo_S)]);
    try std.testing.expectEqual(StaticStatus.non_static, finalized.status[@backingInt(bar_S)]);
    try std.testing.expectEqual(StaticStatus.symbolic, finalized.status[@backingInt(relay_S)]);
}

pub const StaticStatus = enum(u8) { closed, absent, symbolic, non_static, unproved };
pub const StaticResult = struct {
    /// Dense query index; W-only queries have unproved, not an S proof.
    status: []StaticStatus,
    components: u32,
    new_obstructions: u32,
};
const StaticComponent = struct {
    runtime: bool = false,
    unproved: bool = false,
    symbolic: bool = false,
    production: bool = false,
    absent: bool = false,
    edges: u32 = sentinel,
};
const StaticEdge = struct { target: u32, next: u32 };
const StaticFrame = struct { query: QueryId, edge: u32 };

/// Called only after entry/root/edge discovery has reached global quiescence.
/// An unproductive source cycle becomes a residual fact and is propagated by
/// the SAME delta queue before statuses are returned to the caller.
pub fn finalizeStatic(s: *Solver) Allocator.Error!StaticResult {
    while (true) {
        try s.drain();
        const result = try s.staticComponents();
        if (result.new_obstructions == 0) return result;
        s.a.free(result.status);
    }
}

fn staticComponents(s: *Solver) Allocator.Error!StaticResult {
    const count = s.queries.len;
    const number = try s.a.alloc(u32, count);
    defer s.a.free(number);
    const low = try s.a.alloc(u32, count);
    defer s.a.free(low);
    const component = try s.a.alloc(u32, count);
    defer s.a.free(component);
    const on_stack = try s.a.alloc(bool, count);
    defer s.a.free(on_stack);
    @memset(number, sentinel);
    @memset(low, sentinel);
    @memset(component, sentinel);
    @memset(on_stack, false);
    var frames: std.MultiArrayList(StaticFrame) = .empty;
    defer frames.deinit(s.a);
    var stack: std.ArrayList(QueryId) = .empty;
    defer stack.deinit(s.a);
    var groups: std.MultiArrayList(StaticComponent) = .empty;
    defer groups.deinit(s.a);
    var next_number: u32 = 0;
    // Tarjan with explicit indexed frames: neither source depth nor a capture
    // cycle consumes the native call stack.
    for (0..count) |start| {
        if (number[start] != sentinel or s.observations.get(@backingInt(s.queries.get(start).observation)).mode != .S) continue;
        const root: QueryId = @fromBackingInt(@intCast(start));
        number[start] = next_number;
        low[start] = next_number;
        next_number += 1;
        on_stack[start] = true;
        try stack.append(s.a, root);
        try frames.append(s.a, .{ .query = root, .edge = s.queries.get(start).obligations });
        while (frames.len != 0) {
            const last = frames.len - 1;
            const frame = frames.get(last);
            const node = @backingInt(frame.query);
            if (frame.edge != sentinel) {
                const edge = s.obligations.get(frame.edge);
                frames.items(.edge)[last] = edge.next;
                const target = @backingInt(edge.needs);
                if (number[target] == sentinel) {
                    number[target] = next_number;
                    low[target] = next_number;
                    next_number += 1;
                    on_stack[target] = true;
                    try stack.append(s.a, edge.needs);
                    try frames.append(s.a, .{ .query = edge.needs, .edge = s.queries.get(target).obligations });
                } else if (on_stack[target]) low[node] = @min(low[node], number[target]);
                continue;
            }
            frames.len -= 1;
            if (number[node] == low[node]) {
                const index: u32 = @intCast(groups.len);
                var group: StaticComponent = .{};
                while (stack.pop()) |member| {
                    const mi = @backingInt(member);
                    on_stack[mi] = false;
                    component[mi] = index;
                    var fact = s.queries.get(mi).facts;
                    while (fact != .none) : (fact = s.facts.items(.next)[@backingInt(fact)]) {
                        const answer = s.answers.get(@backingInt(s.facts.get(@backingInt(fact)).answer));
                        switch (answer.tag) {
                            .absent => group.absent = true,
                            .input => group.symbolic = true,
                            .static_leaf, .production => group.production = true,
                            .runtime_external => group.runtime = true,
                            .unknown_materialization, .residual => group.unproved = true,
                            .origin => group.unproved = true, // W is not S evidence.
                        }
                    }
                    if (member == frame.query) break;
                }
                try groups.append(s.a, group);
            }
            if (frames.len != 0) {
                const parent = @backingInt(frames.get(frames.len - 1).query);
                low[parent] = @min(low[parent], low[node]);
            }
        }
    }
    var out: std.MultiArrayList(StaticEdge) = .empty;
    defer out.deinit(s.a);
    const ComponentPair = struct { from: u32, to: u32 };
    var seen: std.AutoHashMapUnmanaged(ComponentPair, void) = .empty;
    defer seen.deinit(s.a);
    for (0..s.obligations.len) |i| {
        const edge = s.obligations.get(i);
        const from = component[@backingInt(edge.query)];
        const to = component[@backingInt(edge.needs)];
        if (from == sentinel or to == sentinel or from == to) continue;
        const entry = try seen.getOrPut(s.a, .{ .from = from, .to = to });
        if (entry.found_existing) continue;
        std.debug.assert(to < from); // Tarjan emits the condensation sink first.
        const index: u32 = @intCast(out.len);
        try out.append(s.a, .{ .target = to, .next = groups.items(.edges)[from] });
        groups.items(.edges)[from] = index;
    }
    const states = try s.a.alloc(StaticStatus, groups.len);
    defer s.a.free(states);
    for (0..groups.len) |i| {
        var group = groups.get(i);
        var edge = group.edges;
        while (edge != sentinel) : (edge = out.items(.next)[edge]) switch (states[out.get(edge).target]) {
            .non_static => group.runtime = true,
            .unproved => group.unproved = true,
            .symbolic => group.symbolic = true,
            .closed => group.production = true,
            .absent => {},
        };
        states[i] = if (group.runtime) .non_static else if (group.unproved) .unproved else if (group.symbolic) .symbolic else if (group.production) .closed else if (group.absent) .absent else .unproved;
    }
    const statuses = try s.a.alloc(StaticStatus, count);
    errdefer s.a.free(statuses);
    @memset(statuses, .unproved);
    var new_obstructions: u32 = 0;
    for (0..count) |qi| {
        if (component[qi] == sentinel) continue;
        statuses[qi] = states[component[qi]];
        if (s.queries.get(qi).facts != .none) continue;
        // A stable empty source cycle is not a productive materialization.
        // Formal inputs have symbolic facts; proven absent channels have their
        // own neutral fact. Neither is misclassified here.
        const query: QueryId = @fromBackingInt(@intCast(qi));
        const port = s.ir.ports.get(@backingInt(s.queries.get(qi).port));
        try s.residual(query, port.site, if (port.tag == .input and s.queries.get(qi).seed != .none) .missing_binding else .unproductive);
        new_obstructions += 1;
    }
    return .{ .status = statuses, .components = @intCast(groups.len), .new_obstructions = new_obstructions };
}

test "compact declaration seals preserve aliases mixed origins and already-bound self profiles" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ir: Ir = .{};
    defer ir.deinit(a);
    var b: Ir.Builder = .{ .ir = &ir, .a = a };
    defer b.deinit();
    const start = try b.selector(.{ .tag = .field, .value = 1 });
    const make = try Probe.factory(&ir, a, start);
    const ctor_port = ir.templates.get(@backingInt(make)).body;
    const ctor = ir.constructors.get(ir.ports.get(@backingInt(ctor_port)).lhs);
    const foo = try Probe.template(&ir, a, 0);
    const foo_id = try Probe.anchor(&ir, a, foo);
    const first = try Probe.leaf(&ir, a, foo, .function);
    const foo_export = try Probe.seal(&ir, a, foo, foo_id, try Probe.call(&ir, a, foo, make, &.{first}));
    Probe.body(&ir, foo, foo_export);
    var alias_export = foo_export;
    for (0..3) |_| {
        const alias = try Probe.template(&ir, a, 0);
        const named_read = try ir.addPort(a, .{ .owner = alias, .site = ir.templates.get(@backingInt(alias)).site, .tag = .alias, .lhs = @backingInt(alias_export) });
        alias_export = try Probe.seal(&ir, a, alias, try Probe.anchor(&ir, a, alias), named_read);
        Probe.body(&ir, alias, alias_export);
    }
    const mixed = try Probe.template(&ir, a, 0);
    const mixed_id = try Probe.anchor(&ir, a, mixed);
    const second = try Probe.leaf(&ir, a, mixed, .function);
    const new_value = try Probe.call(&ir, a, mixed, make, &.{second});
    const mixture = try ir.addPort(a, .{ .owner = mixed, .site = ir.templates.get(@backingInt(mixed)).site, .tag = .alternatives, .values = try ir.appendIds(a, &[_]Ir.PortId{ alias_export, new_value }) });
    const mixed_export = try Probe.seal(&ir, a, mixed, mixed_id, mixture);
    // Algebra supplement: existing B(d,o) and new U(o) coexist at a seal.
    // This does not permit an eager checked-source value cycle.
    const already_self = try Probe.seal(&ir, a, mixed, mixed_id, try Probe.call(&ir, a, mixed, make, &.{first}));
    const self_mix = try ir.addPort(a, .{ .owner = mixed, .site = ir.templates.get(@backingInt(mixed)).site, .tag = .alternatives, .values = try ir.appendIds(a, &[_]Ir.PortId{ already_self, new_value }) });
    const self_export = try Probe.seal(&ir, a, mixed, mixed_id, self_mix);
    var s: Solver = .{ .ir = &ir, .a = a };
    defer s.deinit();
    const whole = try s.observe(.{});
    const mixed_role = try s.observe(.{ .prefix = .role, .kind = ctor.kind, .role = 0, .constructor = ctor.origin, .anchor = mixed_id });
    var foo_role_value = s.observations.get(@backingInt(mixed_role));
    foo_role_value.anchor = foo_id;
    const foo_role = try s.observe(foo_role_value);
    // Ask the alias/mixed reads BEFORE the defining initializer.
    const aliases = try s.ask(alias_export, whole, .none);
    const identities = try s.ask(mixed_export, whole, .none);
    const own_profile = try s.ask(mixed_export, mixed_role, .none);
    const old_profile = try s.ask(mixed_export, foo_role, .none);
    const self_profile = try s.ask(self_export, mixed_role, .none);
    try s.drain();
    try expectAnswers(&s, aliases, &.{.{ .tag = .origin, .origin = ctor.origin, .anchor = foo_id }});
    try expectAnswers(&s, identities, &.{ .{ .tag = .origin, .origin = ctor.origin, .anchor = foo_id }, .{ .tag = .origin, .origin = ctor.origin, .anchor = mixed_id } });
    const first_origin: Ir.OriginId = @fromBackingInt(ir.ports.get(@backingInt(first)).lhs);
    const second_origin: Ir.OriginId = @fromBackingInt(ir.ports.get(@backingInt(second)).lhs);
    try expectAnswers(&s, own_profile, &.{.{ .tag = .origin, .origin = second_origin }});
    try expectAnswers(&s, old_profile, &.{.{ .tag = .origin, .origin = first_origin }});
    try expectAnswers(&s, self_profile, &.{ .{ .tag = .origin, .origin = first_origin }, .{ .tag = .origin, .origin = second_origin } });
}

test "compact effective record update keeps opaque base fields out of callback obligations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ir: Ir = .{};
    defer ir.deinit(a);
    var b: Ir.Builder = .{ .ir = &ir, .a = a };
    defer b.deinit();
    const init = try b.selector(.{ .tag = .field, .value = 1 });
    const start = try b.selector(.{ .tag = .field, .value = 2 });
    const owner = try Probe.template(&ir, a, 0);
    const site = ir.templates.get(@backingInt(owner)).site;
    const opaque_value = try Probe.leaf(&ir, a, owner, .@"opaque");
    const first = try Probe.leaf(&ir, a, owner, .function);
    const other = try Probe.leaf(&ir, a, owner, .function);
    const base = try Probe.allocation(&ir, a, owner, init, opaque_value);
    const base_id = ir.ports.get(@backingInt(base)).lhs;
    try ir.fields.append(a, .{ .allocation = @fromBackingInt(base_id), .selector = start, .value = other });
    ir.allocations.items(.fields)[base_id].len += 1;
    const update = try Probe.allocation(&ir, a, owner, init, first);
    const update_id = ir.ports.get(@backingInt(update)).lhs;
    ir.allocations.items(.base)[update_id] = base;
    ir.allocations.items(.shape)[update_id] = try ir.appendIds(a, &[_]Ir.SelectorId{ init, start });
    // Evaluation is an independent source edge, retained even though init is
    // overwritten. The checked-source fixture will observe that actual edge.
    try ir.execution.append(a, .{ .owner = owner, .site = site, .tag = .evaluate, .target = @backingInt(base), .argument = base });
    var s: Solver = .{ .ir = &ir, .a = a };
    defer s.deinit();
    const static = try s.observe(.{ .mode = .S });
    const base_q = try s.ask(base, static, .none);
    const update_q = try s.ask(update, static, .none);
    const init_q = try s.ask(update, try s.observe(.{ .prefix = .field, .selector = init }), .none);
    try s.drain();
    try expectAnswers(&s, update_q, &.{
        .{ .tag = .production, .origin = ir.allocations.get(update_id).origin },
        .{ .tag = .static_leaf, .origin = @fromBackingInt(ir.ports.get(@backingInt(first)).lhs) },
        .{ .tag = .static_leaf, .origin = @fromBackingInt(ir.ports.get(@backingInt(other)).lhs) },
    });
    try expectAnswers(&s, init_q, &.{.{ .tag = .origin, .origin = @fromBackingInt(ir.ports.get(@backingInt(first)).lhs) }});
    const finalized = try s.finalizeStatic();
    defer a.free(finalized.status);
    try std.testing.expectEqual(StaticStatus.closed, finalized.status[@backingInt(update_q)]);
    try std.testing.expectEqual(StaticStatus.unproved, finalized.status[@backingInt(base_q)]);
    try std.testing.expectEqualDeep(Ir.Execution{ .owner = owner, .site = site, .tag = .evaluate, .target = @backingInt(base), .argument = base }, ir.execution.get(0));
}

test "compact runtime seed binding subscribes to later Program facts and backfills earlier ones" {
    for ([_]bool{ false, true }) |facts_first| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var ir: Ir = .{};
        defer ir.deinit(a);
        var b: Ir.Builder = .{ .ir = &ir, .a = a };
        defer b.deinit();
        const role = try b.selector(.{ .tag = .field, .value = 1 });
        const make = try Probe.factory(&ir, a, role);
        const foo = try Probe.template(&ir, a, 0);
        const foo_id = try Probe.anchor(&ir, a, foo);
        const first = try Probe.leaf(&ir, a, foo, .function);
        const exported = try Probe.seal(&ir, a, foo, foo_id, try Probe.call(&ir, a, foo, make, &.{first}));
        const runtime = try Probe.template(&ir, a, 1);
        const formal = Probe.parameter(&ir, runtime, 0);
        const input = ir.ids(Ir.InputId, ir.templates.get(@backingInt(runtime)).inputs)[0];
        var s: Solver = .{ .ir = &ir, .a = a };
        defer s.deinit();
        const whole = try s.observe(.{});
        const static = try s.observe(.{ .mode = .S });
        const seed = try s.addSeed(.{ .template = runtime, .entry = foo_id, .role = sentinel });
        const result = try s.ask(formal, whole, seed);
        if (!facts_first) {
            try s.drain();
            try expectAnswers(&s, result, &.{});
        }
        const source_W = try s.ask(exported, whole, .none);
        const source_S = try s.ask(exported, static, .none);
        if (facts_first) try s.drain();
        try s.bind(.{ .seed = seed, .input = input, .W = source_W, .S = source_S });
        try s.drain();
        const constructor = ir.constructors.get(ir.ports.get(@backingInt(ir.templates.get(@backingInt(make)).body)).lhs);
        try expectAnswers(&s, result, &.{.{ .tag = .origin, .origin = constructor.origin, .anchor = foo_id }});
    }
}

test "compact static SCCs require productions and reject external or unresolved captures" {
    for ([_]enum { closed, runtime, opaque_value }{ .closed, .runtime, .opaque_value }) |variant| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var ir: Ir = .{};
        defer ir.deinit(a);
        const owner = try Probe.template(&ir, a, 0);
        const left_template = try Probe.template(&ir, a, 0);
        const right_template = try Probe.template(&ir, a, 0);
        const site = ir.templates.get(@backingInt(owner)).site;
        const left_origin = try ir.addOrigin(a, .{ .tag = .closure, .site = site, .target = @backingInt(left_template) });
        const right_origin = try ir.addOrigin(a, .{ .tag = .closure, .site = site, .target = @backingInt(right_template) });
        const left = try ir.addPort(a, .{ .owner = owner, .site = site, .tag = .closure, .lhs = @backingInt(left_origin) });
        const right = try ir.addPort(a, .{ .owner = owner, .site = site, .tag = .closure, .lhs = @backingInt(right_origin) });
        _ = try Probe.capture(&ir, a, left_template, right);
        _ = try Probe.capture(&ir, a, right_template, left);
        if (variant != .closed) {
            const external = try Probe.leaf(&ir, a, owner, if (variant == .runtime) .runtime else .@"opaque");
            _ = try Probe.capture(&ir, a, right_template, external);
        }
        var s: Solver = .{ .ir = &ir, .a = a };
        defer s.deinit();
        const observation = try s.observe(.{ .mode = .S });
        const root = try s.ask(left, observation, .none);
        const result = try s.finalizeStatic();
        defer a.free(result.status);
        try std.testing.expectEqual(switch (variant) {
            .closed => StaticStatus.closed,
            .runtime => StaticStatus.non_static,
            .opaque_value => StaticStatus.unproved,
        }, result.status[@backingInt(root)]);
        try std.testing.expectEqual(@as(u32, if (variant == .closed) 1 else 2), result.components);
        try std.testing.expectEqual(@as(u32, 0), result.new_obstructions);
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ir: Ir = .{};
    defer ir.deinit(a);
    const owner = try Probe.template(&ir, a, 0);
    const site = ir.templates.get(@backingInt(owner)).site;
    const left = try ir.addPort(a, .{ .owner = owner, .site = site, .tag = .alias });
    const right = try ir.addPort(a, .{ .owner = owner, .site = site, .tag = .alias, .lhs = @backingInt(left) });
    ir.ports.items(.lhs)[@backingInt(left)] = @backingInt(right);
    var s: Solver = .{ .ir = &ir, .a = a };
    defer s.deinit();
    const root = try s.ask(left, try s.observe(.{ .mode = .S }), .none);
    const result = try s.finalizeStatic();
    defer a.free(result.status);
    try std.testing.expectEqual(StaticStatus.unproved, result.status[@backingInt(root)]);
    try expectAnswers(&s, root, &.{.{ .tag = .residual, .site = site, .reason = .unproductive }});
}

test "compact deep source aliases and static obligations use a 64 KiB native stack" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ir: Ir = .{};
    defer ir.deinit(a);
    const owner = try Probe.template(&ir, a, 0);
    const leaf = try Probe.leaf(&ir, a, owner, .literal);
    var value = leaf;
    for (0..5000) |_| value = try ir.addPort(a, .{ .owner = owner, .site = ir.templates.get(@backingInt(owner)).site, .tag = .alias, .lhs = @backingInt(value) });
    const Worker = struct {
        ir: *const Ir,
        port: Ir.PortId,
        status: StaticStatus = .unproved,
        counts: Counters = .{},
        failure: ?anyerror = null,
        fn run(worker: *@This()) void {
            worker.check() catch |err| {
                worker.failure = err;
            };
        }
        fn check(worker: *@This()) !void {
            var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer scratch.deinit();
            var s: Solver = .{ .ir = worker.ir, .a = scratch.allocator() };
            defer s.deinit();
            const root = try s.ask(worker.port, try s.observe(.{ .mode = .S }), .none);
            const result = try s.finalizeStatic();
            worker.status = result.status[@backingInt(root)];
            worker.counts = s.counts;
        }
    };
    var worker: Worker = .{ .ir = &ir, .port = value };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
    try std.testing.expectEqual(StaticStatus.closed, worker.status);
    try std.testing.expectEqualDeep(Counters{
        .queries = 5001,
        .facts = 5001,
        .subscriptions = 5000,
        .expansions = 5001,
        .deliveries = 5000,
        .peak_queue = worker.counts.peak_queue,
    }, worker.counts);
    try std.testing.expect(worker.counts.peak_queue <= 2);
}

test "compact Unit-returning launch helpers expose runtime-forwarded self launches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ir: Ir = .{};
    defer ir.deinit(a);
    var b: Ir.Builder = .{ .ir = &ir, .a = a };
    defer b.deinit();
    const role = try b.selector(.{ .tag = .field, .value = 1 });
    const make = try Probe.factory(&ir, a, role);
    const foo = try Probe.template(&ir, a, 0);
    const foo_id = try Probe.anchor(&ir, a, foo);
    const first = try Probe.leaf(&ir, a, foo, .function);
    const exported = try Probe.seal(&ir, a, foo, foo_id, try Probe.call(&ir, a, foo, make, &.{first}));
    const helper = try Probe.template(&ir, a, 1);
    Probe.body(&ir, helper, try Probe.leaf(&ir, a, helper, .literal));
    const launch_site: u32 = @intCast(ir.execution.len);
    try ir.execution.append(a, .{ .owner = helper, .site = ir.templates.get(@backingInt(helper)).site, .tag = .launch, .target = 0, .argument = Probe.parameter(&ir, helper, 0) });
    const runtime = try Probe.template(&ir, a, 1);
    Probe.body(&ir, runtime, try Probe.call(&ir, a, runtime, helper, &.{Probe.parameter(&ir, runtime, 0)}));
    try @import("CompactExports.zig").build(&ir, a);
    try std.testing.expectEqual(@as(usize, 2), ir.exports.len);
    var s: Solver = .{ .ir = &ir, .a = a };
    defer s.deinit();
    const whole = try s.observe(.{});
    const static = try s.observe(.{ .mode = .S });
    const source_W = try s.ask(exported, whole, .none);
    const source_S = try s.ask(exported, static, .none);
    const seed = try s.addSeed(.{ .template = runtime, .entry = foo_id, .role = sentinel });
    try s.bind(.{ .seed = seed, .input = ir.ids(Ir.InputId, ir.templates.get(@backingInt(runtime)).inputs)[0], .W = source_W, .S = source_S });
    var result: QueryId = .none;
    for (0..ir.exports.len) |i| {
        const export_row = ir.exports.get(i);
        if (export_row.owner == runtime and export_row.launch == launch_site) result = try s.ask(export_row.port, whole, seed);
    }
    try std.testing.expect(result != .none);
    try s.drain();
    const constructor = ir.constructors.get(ir.ports.get(@backingInt(ir.templates.get(@backingInt(make)).body)).lhs);
    try expectAnswers(&s, result, &.{.{ .tag = .origin, .origin = constructor.origin, .anchor = foo_id }});
}

test "compact control provenance substitutes static inputs and leaves runtime identical choices unproved" {
    const a = std.testing.allocator;
    var ir: Ir = .{};
    defer ir.deinit(a);
    const helper = try Probe.template(&ir, a, 1);
    const root = try Probe.template(&ir, a, 0);
    const value = try Probe.leaf(&ir, a, helper, .literal);
    const alternatives = try ir.appendIds(a, &[_]Ir.PortId{ value, value });
    const body = try ir.addPort(a, .{ .owner = helper, .site = ir.templates.get(@backingInt(helper)).site, .tag = .alternatives, .values = alternatives, .rhs = @backingInt(Probe.parameter(&ir, helper, 0)) });
    Probe.body(&ir, helper, body);
    const literal = try Probe.leaf(&ir, a, root, .literal);
    const runtime = try Probe.leaf(&ir, a, root, .runtime);
    const opaque_value = try Probe.leaf(&ir, a, root, .@"opaque");
    const static_call = try Probe.call(&ir, a, root, helper, &.{literal});
    const runtime_call = try Probe.call(&ir, a, root, helper, &.{runtime});
    const opaque_call = try Probe.call(&ir, a, root, helper, &.{opaque_value});
    var s: Solver = .{ .ir = &ir, .a = a };
    defer s.deinit();
    const S = try s.observe(.{ .mode = .S });
    const W = try s.observe(.{});
    const static_q = try s.ask(static_call, S, .none);
    const runtime_q = try s.ask(runtime_call, S, .none);
    const opaque_q = try s.ask(opaque_call, S, .none);
    const data_q = try s.ask(runtime, S, .none);
    const origins = try s.ask(runtime_call, W, .none);
    const seed = try s.addSeed(.{ .template = helper, .entry = .none, .role = 0 });
    try s.bind(.{ .seed = seed, .input = ir.ids(Ir.InputId, ir.templates.get(@backingInt(helper)).inputs)[0], .runtime = true });
    const seeded = try s.ask(body, S, seed);
    const result = try s.finalizeStatic();
    defer a.free(result.status);
    try std.testing.expectEqual(StaticStatus.closed, result.status[@backingInt(static_q)]);
    try std.testing.expectEqual(StaticStatus.unproved, result.status[@backingInt(runtime_q)]);
    try std.testing.expectEqual(StaticStatus.unproved, result.status[@backingInt(opaque_q)]);
    try std.testing.expectEqual(StaticStatus.unproved, result.status[@backingInt(seeded)]);
    try std.testing.expectEqual(StaticStatus.non_static, result.status[@backingInt(data_q)]);
    var count: usize = 0;
    var fact = s.queries.get(@backingInt(origins)).facts;
    while (fact != .none) {
        const row = s.facts.get(@backingInt(fact));
        try std.testing.expectEqual(Answer{ .tag = .origin, .origin = @fromBackingInt(ir.ports.get(@backingInt(value)).lhs) }, s.answers.get(@backingInt(row.answer)));
        count += 1;
        fact = row.next;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}
