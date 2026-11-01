//! Pure owned-relation supplements; actual checked-source coverage is the CLI corpus.
const std = @import("std");
const Ir = @import("Compact.zig");
const Solve = @import("CompactSolve.zig");
const Graph = @import("CompactGraph.zig");
const Evidence = @import("CompactEvidence.zig");
const a = std.testing.allocator;
const Fixture = struct {
    ir: Ir = .{},
    solver: Solve = undefined,
    fn port(f: *Fixture, owner: Ir.TemplateId, tag: Ir.Port.Tag, lhs: u32) !Ir.PortId {
        return f.ir.addPort(a, .{ .owner = owner, .site = @fromBackingInt(0), .tag = tag, .lhs = lhs });
    }
    fn input(f: *Fixture, owner: Ir.TemplateId, position: u32) !Ir.InputId {
        const p = try f.port(owner, .input, @intCast(f.ir.inputs.len));
        return f.ir.addInput(a, .{ .owner = owner, .position = position, .port = p, .capture = false });
    }
    fn init(f: *Fixture) !void {
        try f.ir.sites.append(a, .{ .module = @fromBackingInt(0), .declaration = @fromBackingInt(0), .instruction = @fromBackingInt(0) });
        const callee = try f.ir.addTemplate(a, .{ .site = @fromBackingInt(0) });
        const owner = try f.ir.addTemplate(a, .{ .site = @fromBackingInt(0) });
        const x = try f.input(callee, 0);
        const y = try f.input(callee, 1);
        f.ir.templates.items(.inputs)[@backingInt(callee)] = try f.ir.appendIds(a, &[_]Ir.InputId{ x, y });
        const body = try f.ir.addPort(a, .{ .owner = callee, .site = @fromBackingInt(0), .tag = .alternatives, .values = try f.ir.appendIds(a, &[_]Ir.PortId{ f.ir.inputs.get(@backingInt(x)).port, f.ir.inputs.get(@backingInt(y)).port }) });
        f.ir.templates.items(.body)[@backingInt(callee)] = body;
        const local = try f.input(owner, 0);
        f.ir.templates.items(.inputs)[@backingInt(owner)] = try f.ir.appendIds(a, &[_]Ir.InputId{local});
        const leaf = try f.ir.addOrigin(a, .{ .tag = .literal, .site = @fromBackingInt(0) });
        const actual = try f.port(owner, .literal, @backingInt(leaf));
        var results: [4]Ir.PortId = undefined;
        results[0] = f.ir.inputs.get(@backingInt(local)).port;
        for (results[1..3]) |*result| {
            // Same original site/target/actuals deliberately cannot identify a call.
            const call = try f.ir.addCall(a, .{ .owner = owner, .site = @fromBackingInt(0), .target = callee, .callee = .none, .arguments = try f.ir.appendIds(a, &[_]Ir.PortId{ actual, actual }) });
            result.* = try f.port(owner, .call, @backingInt(call));
        }
        const other = try f.ir.addOrigin(a, .{ .tag = .literal, .site = @fromBackingInt(0) });
        results[3] = try f.port(owner, .literal, @backingInt(other));
        const root = try f.ir.addPort(a, .{ .owner = owner, .site = @fromBackingInt(0), .tag = .alternatives, .values = try f.ir.appendIds(a, &results) });
        f.ir.templates.items(.body)[@backingInt(owner)] = root;
        f.solver = .{ .a = a, .ir = &f.ir };
        const W = try f.solver.observe(.{});
        const S = try f.solver.observe(.{ .mode = .S });
        const first = try f.solver.addSeed(.{ .template = owner, .entry = .none, .role = 0 });
        const second = try f.solver.addSeed(.{ .template = owner, .entry = .none, .role = 1 });
        const actual_W = try f.solver.ask(actual, W, .none);
        const actual_S = try f.solver.ask(actual, S, .none);
        try f.solver.bind(.{ .seed = first, .input = local, .W = actual_W, .S = actual_S });
        try f.solver.bind(.{ .seed = second, .input = local, .W = actual_W, .S = actual_S });
        _ = try f.solver.ask(root, W, first);
        try f.solver.drain();
    }
    fn snapshot(f: *Fixture, allocator: std.mem.Allocator) !Graph {
        const status = try f.solver.finalizeStatic();
        defer a.free(status.status);
        var g: Graph = .{};
        errdefer g.deinit(allocator);
        try g.snapshot(allocator, &f.ir, &f.solver, status.status);
        return g;
    }
    fn deinit(f: *Fixture) void {
        f.solver.deinit();
        f.ir.deinit(a);
    }
};
fn transport(g: *const Graph, kind: @FieldType(Solve.Transport, "kind")) !usize {
    for (g.evidence.transports.items(.kind), 0..) |k, i| if (k == kind) return i;
    return error.MissingTransport;
}

test "compact owned evidence rejects valid sibling call formal fact seed and binding mutations" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var g = try f.snapshot(a);
    defer g.deinit(a);
    try g.validateTransfers();
    try std.testing.expect(g.evidence.derivations.len > g.evidence.facts.len);
    const id = try transport(&g, .actual);
    const old = g.evidence.transports.get(id);
    g.evidence.transports.items(.call)[id] = @fromBackingInt(1 - @backingInt(old.call));
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.evidence.transports.set(id, old);
    const formal = g.evidence.facts.get(@backingInt(old.formal));
    var sibling: ?Solve.FactId = null;
    for (0..g.evidence.facts.len) |i| {
        const row = g.evidence.facts.get(i);
        if (row.query == formal.query and row.answer != formal.answer) {
            sibling = @fromBackingInt(@as(u32, @intCast(i)));
            break;
        }
    }
    try std.testing.expect(sibling != null);
    g.evidence.transports.items(.formal)[id] = sibling.?;
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.evidence.transports.set(id, old);
    const edge = g.evidence.edges.get(@backingInt(old.edge));
    const old_seed = g.evidence.queries.items(.seed)[@backingInt(edge.source)];
    g.evidence.queries.items(.seed)[@backingInt(edge.source)] = @fromBackingInt(1);
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.evidence.queries.items(.seed)[@backingInt(edge.source)] = old_seed;
    const bi = try transport(&g, .binding);
    const binding = g.evidence.transports.get(bi);
    g.evidence.transports.items(.binding)[bi] = 1;
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.evidence.transports.set(bi, binding);
    try g.validateTransfers();
}

test "compact owned evidence survives original directory growth and destruction" {
    var f: Fixture = .{};
    try f.init();
    var g = try f.snapshot(a);
    defer g.deinit(a);
    const words = try a.dupe(u32, g.evidence.source.extra.items);
    defer a.free(words);
    try f.ir.extra.appendNTimes(a, 99, 4096);
    f.ir.extra.items[0] = 999;
    f.deinit();
    try std.testing.expectEqualSlices(u32, words, g.evidence.source.extra.items);
    try g.validateTransfers();
    g.reset();
    try std.testing.expectEqual(@as(usize, 0), g.evidence.source.ports.len);
    try std.testing.expectEqual(@as(usize, 0), g.evidence.derivations.len);
}

fn allocationSnapshot(allocator: std.mem.Allocator, fixture: *Fixture) !void {
    var g = try fixture.snapshot(allocator);
    defer g.deinit(allocator);
    try g.validateTransfers();
}
test "compact owned evidence frees every injected snapshot allocation" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationSnapshot, .{&f});
}

test "compact structural evidence explicitly does not certify same query answer replacement" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var g = try f.snapshot(a);
    defer g.deinit(a);
    var changed = false;
    outer: for (0..g.evidence.facts.len) |i| {
        const row = g.evidence.facts.get(i);
        for (i + 1..g.evidence.facts.len) |j| {
            const other = g.evidence.facts.get(j);
            if (row.query == other.query and row.answer != other.answer and g.answers.get(@backingInt(row.answer)).tag == .origin and g.answers.get(@backingInt(other.answer)).tag == .origin) {
                g.evidence.facts.items(.answer)[i] = other.answer;
                changed = true;
                break :outer;
            }
        }
    }
    try std.testing.expect(changed);
    try g.validateTransfers();
    // Structural incidence can accept this; it is NEVER a semantic certificate.
    // No local transfer-equation verifier or proof-like consumer exists here.
    try std.testing.expectEqual(.unavailable, Evidence.semantic_validation);
}

test "compact owned evidence row accounting includes the complete status directory" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var g = try f.snapshot(a);
    defer g.deinit(a);
    const e = &g.evidence;
    const expected = e.queries.len + e.facts.len + e.edges.len + e.seeds.len + e.bindings.len + e.obligations.len + e.derivations.len + e.transports.len + e.statuses.items.len;
    try std.testing.expectEqual(@as(u64, @intCast(expected)), e.counts.solver_rows);
}
