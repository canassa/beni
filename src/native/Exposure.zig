//! Source-finite callable exposure for one attested native recipe.
//! workers-native-emission-authority.md §8: no aggregate/environment expansion.
const std = @import("std");
const Build = @import("../check/RealmBuild.zig");
const Bir = @import("../bir/Bir.zig");
const Interface = @import("../resolve/Interface.zig");
const Allocator = std.mem.Allocator;
pub const native: u8 = 1;
pub const unresolved: u8 = 2;
pub const Error = Allocator.Error || error{InvalidExposure};
pub const Work = struct { nodes: u64 = 0, edges: u64 = 0, transitions: u64 = 0, deliveries: u64 = 0 };
pub const Result = struct {
    bits: []u8 = &.{},
    port_count: u32 = 0,
    work: Work = .{},
    pub fn deinit(r: *Result, a: Allocator) void {
        a.free(r.bits);
        r.* = .{};
    }
    pub fn port(r: *const Result, id: Build.PortId) Error!u8 {
        const at = @backingInt(id);
        if (at >= r.port_count) return error.InvalidExposure;
        return r.bits[at];
    }
    pub fn exec(r: *const Result, id: Build.ExecId) Error!u8 {
        const at = @as(usize, r.port_count) + @backingInt(id);
        if (at >= r.bits.len) return error.InvalidExposure;
        return r.bits[at];
    }
};
const Edge = struct { source: u32, target: u32 };
const Job = struct { node: u32, bit: u8 };
const Pass = struct {
    a: Allocator,
    out: *Result,
    edges: std.MultiArrayList(Edge) = .empty,
    queue: std.ArrayList(Job) = .empty,
    fn deinit(p: *Pass) void {
        p.edges.deinit(p.a);
        p.queue.deinit(p.a);
    }
    fn raise(p: *Pass, node: u32, bit: u8) Error!void {
        if (node >= p.out.bits.len) return error.InvalidExposure;
        if (p.out.bits[node] & bit != 0) return;
        try p.queue.append(p.a, .{ .node = node, .bit = bit });
        p.out.bits[node] |= bit;
        p.out.work.transitions += 1;
    }
    fn edge(p: *Pass, source: usize, target: usize) Error!void {
        if (source >= p.out.bits.len or target >= p.out.bits.len) return error.InvalidExposure;
        try p.edges.append(p.a, .{ .source = @intCast(source), .target = @intCast(target) });
    }
    fn run(p: *Pass) Error!void {
        const offsets = try p.a.alloc(u32, p.out.bits.len + 1);
        defer p.a.free(offsets);
        @memset(offsets, 0);
        for (p.edges.items(.source)) |source| offsets[source + 1] += 1;
        for (1..offsets.len) |i| offsets[i] += offsets[i - 1];
        const cursor = try p.a.dupe(u32, offsets[0..p.out.bits.len]);
        defer p.a.free(cursor);
        const targets = try p.a.alloc(u32, p.edges.len);
        defer p.a.free(targets);
        for (p.edges.items(.source), p.edges.items(.target)) |source, target| {
            targets[cursor[source]] = target;
            cursor[source] += 1;
        }
        var at: usize = 0;
        while (at < p.queue.items.len) : (at += 1) {
            const job = p.queue.items[at];
            for (targets[offsets[job.node]..offsets[job.node + 1]]) |target| {
                p.out.work.deliveries += 1;
                try p.raise(target, job.bit);
            }
        }
        p.out.work.edges = p.edges.len;
    }
};
fn nullary(built: *const Build.Output, at: usize, birs: []const *const Bir, interfaces: []const Interface) bool {
    const source = built.ports.get(at).source;
    if (source.module.int() >= birs.len or source.instruction == Build.Realms.none) return false;
    const bir = birs[source.module.int()];
    if (source.instruction >= bir.insts.len) return false;
    const inst: Bir.Inst.Index = @fromBackingInt(source.instruction);
    const data = bir.instData(inst);
    return switch (bir.instTag(inst)) {
        .ctor => data.lhs < bir.ctors.len and bir.ctors[data.lhs].args_start == bir.ctors[data.lhs].args_end,
        .ext_ctor => data.lhs < interfaces.len and data.rhs < interfaces[data.lhs].ctors.len and interfaces[data.lhs].ctors[data.rhs].arity == 0,
        else => false,
    };
}
pub fn solve(a: Allocator, built: *const Build.Output, birs: []const *const Bir, interfaces: []const Interface) Error!Result {
    const ports = built.ports.len;
    const count = std.math.add(usize, ports, built.execs.len) catch return error.InvalidExposure;
    if (count > std.math.maxInt(u32)) return error.InvalidExposure;
    var out: Result = .{ .bits = try a.alloc(u8, count), .port_count = @intCast(ports), .work = .{ .nodes = count } };
    errdefer out.deinit(a);
    @memset(out.bits, 0);
    var pass: Pass = .{ .a = a, .out = &out };
    defer pass.deinit();
    const native_results = try a.alloc(bool, ports);
    defer a.free(native_results);
    @memset(native_results, false);
    for (0..built.contracts.len) |i| {
        const c = built.contracts.get(i);
        if (@backingInt(c.call) >= built.calls.len or @backingInt(c.result) >= ports or @backingInt(c.argument) >= ports) return error.InvalidExposure;
        const call = built.calls.get(@backingInt(c.call));
        if (call.result != c.result or call.target != c.native_exec or call.classification != .direct) return error.InvalidExposure;
        native_results[@backingInt(c.result)] = true;
    }
    for (0..ports) |i| {
        const origin = built.ports.get(i).origin;
        switch (origin.kind) {
            .scalar => {},
            .callable => {
                if (origin.value >= built.execs.len) return error.InvalidExposure;
                try pass.edge(ports + origin.value, i);
            },
            .record, .tuple => try pass.raise(@intCast(i), unresolved),
            .residual => {
                const witness = @backingInt(origin.witness);
                if (native_results[i] or (witness < ports and native_results[witness]) or nullary(built, i, birs, interfaces) or (witness < ports and nullary(built, witness, birs, interfaces))) continue;
                try pass.raise(@intCast(i), unresolved);
            },
        }
    }
    for (0..built.execs.len) |i| {
        const ex = built.execs.get(i);
        if (@backingInt(ex.scope) >= built.scopes.len) return error.InvalidExposure;
        const scope = built.scopes.get(@backingInt(ex.scope));
        if (scope.exec != @as(Build.ExecId, @fromBackingInt(@as(u32, @intCast(i))))) return error.InvalidExposure;
        const node: u32 = @intCast(ports + i);
        if (ex.coverage == .native_required) {
            try pass.raise(node, native);
            continue;
        }
        if (ex.coverage == .unavailable or scope.capture != .none) try pass.raise(node, unresolved);
        if (scope.result != .none) try pass.edge(@backingInt(scope.result), node) else try pass.raise(node, unresolved);
    }
    for (0..built.edges.len) |i| {
        const edge = built.edges.get(i);
        if (@backingInt(edge.caller) >= built.execs.len or @backingInt(edge.callee) >= built.execs.len) return error.InvalidExposure;
        try pass.edge(ports + @backingInt(edge.callee), ports + @backingInt(edge.caller));
    }
    try pass.run();
    return out;
}

test "native emission helpers stay within the existing per-file line bound" {
    inline for (.{ @embedFile("Exposure.zig"), @embedFile("Emission.zig"), @embedFile("HostFixture.zig") }) |source| {
        try std.testing.expect(std.mem.count(u8, source, "\n") <= 1500);
    }
}
