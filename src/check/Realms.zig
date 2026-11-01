//! Source-owned five-bit native realm propagation. No effect/type-class equality.
//! workers-native-realm-component.md. Callers supply attested binding seeds;
//! missing source/native coverage is incomplete, never an all-realms proof.
const std = @import("std");
const Graph = @import("../resolve/Graph.zig");
const Allocator = std.mem.Allocator;
pub const ExecId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const SiteId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const ScopeId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const PortId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const all: u8 = 0x1f;
pub const none = std.math.maxInt(u32);
pub const QualifiedDecl = struct { module: Graph.Index, declaration: u32 };
pub const Source = struct { module: Graph.Index, declaration: u32, instruction: u32 };
pub const Coverage = enum(u8) { source, native_required, unavailable };
pub const Exec = struct { source: Source, scope: ScopeId, coverage: Coverage, residual: SiteId = .none };
pub const Site = struct { source: Source, scope: ScopeId, kind: enum(u8) { call, residual } };
pub const Edge = struct { callee: ExecId, caller: ExecId, site: SiteId };
pub const Seed = struct { target: ExecId, allowed: u8, binding_digest: [32]u8, origin: enum(u8) { attested, private_test } = .attested };
/// Phase1's downward API. Only its completed registry may supply production rows.
pub const NativeSeed = struct { target: QualifiedDecl, allowed: u8, binding_digest: [32]u8 };
pub const Input = struct {
    scope_count: u32,
    execs: std.MultiArrayList(Exec).Slice,
    sites: std.MultiArrayList(Site).Slice,
    edges: std.MultiArrayList(Edge).Slice,
    seeds: std.MultiArrayList(Seed).Slice,
};
pub const Fact = struct { allowed: u8 = all, incomplete: bool = false, seed: u32 = none };
pub const Work = struct { nodes: u64 = 0, edges: u64 = 0, seed_reads: u64 = 0, bit_transitions: u64 = 0, incomplete_transitions: u64 = 0, edge_visits: u64 = 0 };
pub const Result = struct {
    facts: std.MultiArrayList(Fact) = .empty,
    /// Six columns per execution: five removed bits and incomplete. Each is an
    /// original edge index, or none for an original seed/source residual.
    witnesses: []u32 = &.{},
    work: Work = .{},

    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.facts.deinit(gpa);
        gpa.free(r.witnesses);
        r.* = .{};
    }
};
pub const Error = Allocator.Error || error{ InvalidExec, InvalidSite, InvalidScope, InvalidMask, InvalidSeed, DuplicateSeed };

/// Validation and solving read each original row a fixed number of times.
/// A queue entry requires at least one new bit removal/incomplete transition;
/// hence at most six entries per execution, including initial seeds/residuals.
pub fn solve(gpa: Allocator, in: Input) Error!Result {
    const n = in.execs.len;
    var result: Result = .{};
    errdefer result.deinit(gpa);
    try result.facts.resize(gpa, n);
    result.witnesses = try gpa.alloc(u32, std.math.mul(usize, n, 6) catch return error.OutOfMemory);
    @memset(result.witnesses, none);
    const facts = result.facts.slice();
    const allowed = facts.items(.allowed);
    const incomplete = facts.items(.incomplete);
    const seeds = facts.items(.seed);
    @memset(allowed, all);
    @memset(incomplete, false);
    @memset(seeds, none);
    for (in.execs.items(.scope)) |scope| if (@backingInt(scope) >= in.scope_count) return error.InvalidScope;
    for (in.sites.items(.scope)) |scope| if (@backingInt(scope) >= in.scope_count) return error.InvalidScope;
    for (0..n) |i| {
        const exec = in.execs.get(i);
        if (exec.coverage == .unavailable and exec.residual == .none) return error.InvalidSite;
        if (exec.coverage == .source and exec.residual != .none) return error.InvalidSite;
        if (exec.residual != .none) {
            if (@backingInt(exec.residual) >= in.sites.len) return error.InvalidSite;
            const site = in.sites.get(@backingInt(exec.residual));
            if (site.kind != .residual or site.scope != exec.scope or site.source.module != exec.source.module or site.source.declaration != exec.source.declaration) return error.InvalidSite;
        }
    }
    for (0..in.seeds.len) |i| {
        const seed = in.seeds.get(i);
        const target = @backingInt(seed.target);
        if (target >= n) return error.InvalidExec;
        if (seed.allowed & ~all != 0) return error.InvalidMask;
        switch (seed.origin) {
            .attested => if (in.execs.get(target).coverage != .native_required) return error.InvalidSeed,
            .private_test => if (!@import("builtin").is_test) return error.InvalidSeed,
        }
        if (seeds[target] != none) return error.DuplicateSeed;
        seeds[target] = @intCast(i);
        allowed[target] = seed.allowed;
        result.work.seed_reads += 1;
        result.work.bit_transitions += @popCount(all ^ seed.allowed);
    }
    // Count/sort direct callees once. No per-root reachability matrix.
    const offsets = try gpa.alloc(usize, n + 1);
    defer gpa.free(offsets);
    @memset(offsets, 0);
    for (0..in.edges.len) |i| {
        const edge = in.edges.get(i);
        const callee = @backingInt(edge.callee);
        const caller = @backingInt(edge.caller);
        if (callee >= n or caller >= n) return error.InvalidExec;
        if (@backingInt(edge.site) >= in.sites.len) return error.InvalidSite;
        const site = in.sites.get(@backingInt(edge.site));
        const caller_exec = in.execs.get(caller);
        if (site.kind != .call or site.scope != caller_exec.scope or site.source.module != caller_exec.source.module or site.source.declaration != caller_exec.source.declaration) return error.InvalidSite;
        offsets[callee + 1] += 1;
    }
    for (1..offsets.len) |i| offsets[i] += offsets[i - 1];
    const fill = try gpa.dupe(usize, offsets[0..n]);
    defer gpa.free(fill);
    const edges = try gpa.alloc(u32, in.edges.len);
    defer gpa.free(edges);
    for (0..in.edges.len) |i| {
        const callee = @backingInt(in.edges.get(i).callee);
        edges[fill[callee]] = @intCast(i);
        fill[callee] += 1;
    }
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);
    for (0..n) |i| {
        incomplete[i] = switch (in.execs.get(i).coverage) {
            .source => false,
            .native_required => seeds[i] == none,
            .unavailable => true,
        };
        if (incomplete[i]) result.work.incomplete_transitions += 1;
        if (allowed[i] != all or incomplete[i]) try queue.append(gpa, @intCast(i));
    }
    var at: usize = 0;
    while (at < queue.items.len) : (at += 1) {
        const callee = queue.items[at];
        for (edges[offsets[callee]..offsets[callee + 1]]) |edge_index| {
            result.work.edge_visits += 1;
            const caller = @backingInt(in.edges.get(edge_index).caller);
            const removed = allowed[caller] & ~allowed[callee];
            const missing = !incomplete[caller] and incomplete[callee];
            if (removed == 0 and !missing) continue;
            allowed[caller] &= allowed[callee];
            if (missing) {
                incomplete[caller] = true;
                result.witnesses[caller * 6 + 5] = edge_index;
                result.work.incomplete_transitions += 1;
            }
            inline for (0..5) |bit| if (removed & (@as(u8, 1) << bit) != 0) {
                result.witnesses[caller * 6 + bit] = edge_index;
            };
            result.work.bit_transitions += @popCount(removed);
            try queue.append(gpa, caller);
        }
    }
    result.work.nodes = n;
    result.work.edges = in.edges.len;
    return result;
}

const Fixture = struct {
    execs: std.MultiArrayList(Exec) = .empty,
    sites: std.MultiArrayList(Site) = .empty,
    edges: std.MultiArrayList(Edge) = .empty,
    seeds: std.MultiArrayList(Seed) = .empty,
    fn deinit(f: *Fixture, gpa: Allocator) void {
        f.execs.deinit(gpa);
        f.sites.deinit(gpa);
        f.edges.deinit(gpa);
        f.seeds.deinit(gpa);
    }
    fn add(f: *Fixture, gpa: Allocator, coverage: Coverage) !ExecId {
        const id: u32 = @intCast(f.execs.len);
        const source: Source = .{ .module = @fromBackingInt(0), .declaration = id, .instruction = id };
        var residual: SiteId = .none;
        if (coverage == .unavailable) {
            residual = @fromBackingInt(@as(u32, @intCast(f.sites.len)));
            try f.sites.append(gpa, .{ .source = source, .scope = @fromBackingInt(id), .kind = .residual });
        }
        try f.execs.append(gpa, .{ .source = source, .scope = @fromBackingInt(id), .coverage = coverage, .residual = residual });
        return @fromBackingInt(id);
    }
    fn call(f: *Fixture, gpa: Allocator, callee: ExecId, caller: ExecId) !void {
        const site: SiteId = @fromBackingInt(@as(u32, @intCast(f.sites.len)));
        try f.sites.append(gpa, .{ .source = f.execs.get(@backingInt(caller)).source, .scope = @fromBackingInt(@backingInt(caller)), .kind = .call });
        try f.edges.append(gpa, .{ .callee = callee, .caller = caller, .site = site });
    }
    fn input(f: *const Fixture) Input {
        return .{ .scope_count = @intCast(f.execs.len), .execs = f.execs.slice(), .sites = f.sites.slice(), .edges = f.edges.slice(), .seeds = f.seeds.slice() };
    }
};

test "native realms keep independent equal-rung functions separate and solve execution cycles" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(gpa);
    const window = try fixture.add(gpa, .source);
    const worker = try fixture.add(gpa, .source);
    const root = try fixture.add(gpa, .source);
    const recursive = try fixture.add(gpa, .source);
    try fixture.seeds.append(gpa, .{ .target = window, .allowed = 1, .binding_digest = @splat(1), .origin = .private_test });
    try fixture.seeds.append(gpa, .{ .target = worker, .allowed = 2, .binding_digest = @splat(2), .origin = .private_test });
    try fixture.call(gpa, window, root);
    try fixture.call(gpa, root, recursive);
    try fixture.call(gpa, recursive, root);
    var result = try solve(gpa, fixture.input());
    defer result.deinit(gpa);
    try std.testing.expectEqualDeep(Fact{ .allowed = 1 }, result.facts.get(@backingInt(root)));
    try std.testing.expectEqualDeep(Fact{ .allowed = 2, .seed = 1 }, result.facts.get(@backingInt(worker)));
    try std.testing.expectEqualDeep(Fact{ .allowed = 1 }, result.facts.get(@backingInt(recursive)));
    try std.testing.expect(result.work.edge_visits <= 6 * fixture.edges.len);
    try std.testing.expectEqual(@as(u64, 2), result.work.seed_reads);
}

test "native realms require native coverage even for the full exposure mask" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(gpa);
    const native = try fixture.add(gpa, .native_required);
    const root = try fixture.add(gpa, .source);
    try fixture.call(gpa, native, root);
    var absent = try solve(gpa, fixture.input());
    defer absent.deinit(gpa);
    try std.testing.expectEqualDeep(Fact{ .incomplete = true }, absent.facts.get(@backingInt(root)));
    try fixture.seeds.append(gpa, .{ .target = native, .allowed = all, .binding_digest = @splat(3) });
    var present = try solve(gpa, fixture.input());
    defer present.deinit(gpa);
    try std.testing.expectEqualDeep(Fact{}, present.facts.get(@backingInt(root)));
    try std.testing.expectEqual(@as(u64, 1), present.work.seed_reads);
}

test "native realms reject malformed source call and seed index domains before solving" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(gpa);
    const root = try fixture.add(gpa, .source);
    try fixture.seeds.append(gpa, .{ .target = root, .allowed = 0x80, .binding_digest = @splat(0) });
    try std.testing.expectError(error.InvalidMask, solve(gpa, fixture.input()));
    fixture.seeds.set(0, .{ .target = @fromBackingInt(1), .allowed = all, .binding_digest = @splat(0) });
    try std.testing.expectError(error.InvalidExec, solve(gpa, fixture.input()));
}

test "native realms propagate restricted mask and incomplete fan-in through a cycle with linear work" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(gpa);
    const native = try fixture.add(gpa, .native_required);
    const unknown = try fixture.add(gpa, .unavailable);
    const root = try fixture.add(gpa, .source);
    const recursive = try fixture.add(gpa, .source);
    try fixture.seeds.append(gpa, .{ .target = native, .allowed = 1, .binding_digest = @splat(4) });
    try fixture.call(gpa, native, root);
    try fixture.call(gpa, unknown, root);
    try fixture.call(gpa, root, recursive);
    try fixture.call(gpa, recursive, root);
    var result = try solve(gpa, fixture.input());
    defer result.deinit(gpa);
    const expected: Fact = .{ .allowed = 1, .incomplete = true };
    try std.testing.expectEqualDeep(expected, result.facts.get(@backingInt(root)));
    try std.testing.expectEqualDeep(expected, result.facts.get(@backingInt(recursive)));
    try std.testing.expectEqual(@as(u64, 4), result.work.edges);
    try std.testing.expect(result.work.bit_transitions <= 5 * result.work.nodes);
    try std.testing.expect(result.work.incomplete_transitions <= result.work.nodes);
    try std.testing.expect(result.work.edge_visits <= 6 * result.work.edges);
    try std.testing.expect(result.witnesses[@as(usize, @backingInt(root)) * 6 + 1] != none);
    try std.testing.expect(result.witnesses[@as(usize, @backingInt(root)) * 6 + 5] != none);
}

test "native realms reject a production seed on an ordinary source execution and a foreign residual scope" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(gpa);
    const ordinary = try fixture.add(gpa, .source);
    const unknown = try fixture.add(gpa, .unavailable);
    try fixture.seeds.append(gpa, .{ .target = ordinary, .allowed = all, .binding_digest = @splat(5) });
    try std.testing.expectError(error.InvalidSeed, solve(gpa, fixture.input()));
    fixture.seeds.clearRetainingCapacity();
    const site_index = @backingInt(fixture.execs.get(@backingInt(unknown)).residual);
    var site = fixture.sites.get(site_index);
    site.scope = @fromBackingInt(@backingInt(ordinary));
    fixture.sites.set(site_index, site);
    try std.testing.expectError(error.InvalidSite, solve(gpa, fixture.input()));
}

test "native realms release every injected allocation failure in cyclic mask and residual solving" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(gpa);
    const native = try fixture.add(gpa, .native_required);
    const unknown = try fixture.add(gpa, .unavailable);
    const root = try fixture.add(gpa, .source);
    const recursive = try fixture.add(gpa, .source);
    try fixture.seeds.append(gpa, .{ .target = native, .allowed = 1, .binding_digest = @splat(6) });
    try fixture.call(gpa, native, root);
    try fixture.call(gpa, unknown, root);
    try fixture.call(gpa, root, recursive);
    try fixture.call(gpa, recursive, root);
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn check(allocator: Allocator, input: Input, root_index: ExecId) !void {
            var result = try solve(allocator, input);
            defer result.deinit(allocator);
            try std.testing.expectEqualDeep(Fact{ .allowed = 1, .incomplete = true }, result.facts.get(@backingInt(root_index)));
        }
    }.check, .{ fixture.input(), root });
}
