//! Exact construction-result provenance, independent of nominal type/exposure.
//! workers-native-receiver-getter.md: only constructor bases and simple aliases.
const std = @import("std");
const Build = @import("../check/RealmBuild.zig");
const Interface = @import("../resolve/Interface.zig");
const Allocator = std.mem.Allocator;
pub const WitnessId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Error = Allocator.Error || error{InvalidReceiverEvidence};
pub const Authority = struct {
    target: Build.QualifiedDecl,
    digest: [32]u8,
    nominal_owner: @import("../resolve/Graph.zig").Index,
    nominal_type: Interface.TypeIndex,
    /// Current exact constructor ABI, never a generic signature capability.
    abi: u8 = 1,
};
pub const Witness = struct {
    call: Build.CallId,
    result: Build.PortId,
    authority: Authority,
};
pub const Work = struct { ports: u64 = 0, contracts: u64 = 0, aliases: u64 = 0, native_rows: u64 = 0, invocation_slots: u64 = 0, invocation_contracts: u64 = 0, invocation_visits: u64 = 0 };
pub const Result = struct {
    witnesses: std.ArrayList(Witness) = .empty,
    /// none means unavailable, not a negative brand test.
    by_port: []WitnessId = &.{},
    work: Work = .{},
    pub fn deinit(r: *Result, a: Allocator) void {
        r.witnesses.deinit(a);
        a.free(r.by_port);
        r.* = .{};
    }
    pub fn at(r: *const Result, port: Build.PortId) Error!?Witness {
        const i = @backingInt(port);
        if (i >= r.by_port.len) return error.InvalidReceiverEvidence;
        const w = r.by_port[i];
        if (w == .none) return null;
        if (@backingInt(w) >= r.witnesses.items.len) return error.InvalidReceiverEvidence;
        return r.witnesses.items[@backingInt(w)];
    }
};

/// Caller passes only the current Registry-attested constructor authority.
/// No ordinary user/physical source can manufacture this via a nominal type.
pub fn solve(a: Allocator, built: *const Build.Output, authority: Authority) Error!Result {
    const n = built.ports.len;
    if (built.receiver_aliases.len != n or authority.abi != 1 or authority.nominal_owner != authority.target.module) return error.InvalidReceiverEvidence;
    var out: Result = .{ .by_port = try a.alloc(WitnessId, n) };
    errdefer out.deinit(a);
    @memset(out.by_port, .none);
    var constructor: Build.ExecId = .none;
    for (0..built.native_values.len) |i| {
        const native = built.native_values.get(i);
        out.work.native_rows += 1;
        if (!std.meta.eql(native.target, authority.target)) continue;
        if (constructor != .none or native.contract != .unit_to_native or !std.mem.eql(u8, &native.binding_digest, &authority.digest)) return error.InvalidReceiverEvidence;
        if (@backingInt(native.exec) >= built.execs.len or @backingInt(native.port) >= n) return error.InvalidReceiverEvidence;
        const ex = built.execs.get(@backingInt(native.exec));
        const origin = built.ports.get(@backingInt(native.port)).origin;
        if (ex.source.module != authority.target.module or ex.source.declaration != authority.target.declaration or ex.coverage != .native_required or origin.kind != .callable or origin.value != @backingInt(native.exec)) return error.InvalidReceiverEvidence;
        const declaration = built.declaration(authority.target) catch return error.InvalidReceiverEvidence;
        if (declaration.port != native.port) return error.InvalidReceiverEvidence;
        constructor = native.exec;
    }
    if (constructor == .none) return error.InvalidReceiverEvidence;
    const states = try a.alloc(enum { unseen, visiting, done }, n);
    defer a.free(states);
    @memset(states, .unseen);
    for (0..built.contracts.len) |i| {
        const contract = built.contracts.get(i);
        out.work.contracts += 1;
        if (contract.native_exec != constructor) continue;
        if (@backingInt(contract.call) >= built.calls.len or @backingInt(contract.result) >= n or @backingInt(contract.argument) >= n) return error.InvalidReceiverEvidence;
        const call = built.calls.get(@backingInt(contract.call));
        if (call.result != contract.result or call.argument != contract.argument or call.target != constructor or call.classification != .direct or out.by_port[@backingInt(contract.result)] != .none) return error.InvalidReceiverEvidence;
        if (@backingInt(call.callee) >= n) return error.InvalidReceiverEvidence;
        const callee = built.ports.get(@backingInt(call.callee)).origin;
        if (callee.kind != .callable or callee.value != @backingInt(constructor)) return error.InvalidReceiverEvidence;
        out.by_port[@backingInt(contract.result)] = @fromBackingInt(@as(u32, @intCast(out.witnesses.items.len)));
        try out.witnesses.append(a, .{ .call = contract.call, .result = contract.result, .authority = authority });
        states[@backingInt(contract.result)] = .done;
    }
    var stack: std.ArrayList(Build.PortId) = .empty;
    defer stack.deinit(a);
    for (0..n) |start| {
        out.work.ports += 1;
        if (states[start] == .done) continue;
        var at: u32 = @intCast(start);
        while (states[at] == .unseen) {
            states[at] = .visiting;
            try stack.append(a, @fromBackingInt(at));
            const next = built.receiver_aliases[at];
            if (next == .none) break;
            if (@backingInt(next) >= n) return error.InvalidReceiverEvidence;
            out.work.aliases += 1;
            at = @backingInt(next);
        }
        // An unfinished cycle has no constructor base. No favorable leaf exists.
        const resolved = if (states[at] == .done) out.by_port[at] else WitnessId.none;
        while (stack.pop()) |port| {
            out.by_port[@backingInt(port)] = resolved;
            states[@backingInt(port)] = .done;
        }
    }
    return out;
}

const Probe = struct {
    const authority: Authority = .{ .target = .{ .module = @fromBackingInt(0), .declaration = 2 }, .digest = @splat(7), .nominal_owner = @fromBackingInt(0), .nominal_type = @fromBackingInt(0) };
    fn make(a: Allocator) !Build.Output {
        var out: Build.Output = .{};
        errdefer out.deinit(a);
        const source: Build.Realms.Source = .{ .module = @fromBackingInt(0), .declaration = 0, .instruction = 0 };
        for (0..7) |_| try out.ports.append(a, .{ .source = source });
        out.receiver_aliases = try a.dupe(Build.PortId, &.{ .none, @fromBackingInt(0), @fromBackingInt(1), .none, @fromBackingInt(3), @fromBackingInt(6), @fromBackingInt(5) });
        out.ports.items(.origin)[3] = .{ .kind = .callable, .value = 0 };
        try out.modules.append(a, .{ .scopes = .{}, .instructions = .{}, .declarations = .{ .start = 0, .len = 3 } });
        for (0..3) |_| try out.declarations.append(a, .{ .port = @fromBackingInt(3) });
        try out.execs.append(a, .{ .source = .{ .module = @fromBackingInt(0), .declaration = 2, .instruction = 0 }, .scope = .none, .coverage = .native_required });
        try out.native_values.append(a, .{ .target = authority.target, .binding_digest = authority.digest, .exec = @fromBackingInt(0), .port = @fromBackingInt(3), .contract = .unit_to_native });
        try out.calls.append(a, .{ .site = .none, .ambient = @fromBackingInt(1), .callee = @fromBackingInt(3), .result = @fromBackingInt(0), .target = @fromBackingInt(0), .argument = @fromBackingInt(4), .classification = .direct });
        try out.contracts.append(a, .{ .call = @fromBackingInt(0), .argument = @fromBackingInt(4), .result = @fromBackingInt(0), .native_exec = @fromBackingInt(0) });
        return out;
    }
};
test "native receiver exact constructor aliases retain witness while opaque and cycles refuse" {
    const a = std.testing.allocator;
    var built = try Probe.make(a);
    defer built.deinit(a);
    var result = try solve(a, &built, Probe.authority);
    defer result.deinit(a);
    for (0..3) |i| {
        const witness = (try result.at(@fromBackingInt(@as(u32, @intCast(i))))).?;
        try std.testing.expectEqual(@as(Build.CallId, @fromBackingInt(0)), witness.call);
        try std.testing.expectEqual(@as(Build.PortId, @fromBackingInt(0)), witness.result);
    }
    for (3..7) |i| try std.testing.expectEqual(null, try result.at(@fromBackingInt(@as(u32, @intCast(i)))));
    try std.testing.expectEqual(@as(u64, @intCast(built.ports.len)), result.work.ports);
    try std.testing.expect(result.work.aliases <= built.ports.len);
}
test "native receiver rejects changed attestation and call result identity" {
    const a = std.testing.allocator;
    var built = try Probe.make(a);
    defer built.deinit(a);
    var wrong = Probe.authority;
    wrong.digest[0] ^= 1;
    try std.testing.expectError(error.InvalidReceiverEvidence, solve(a, &built, wrong));
    built.contracts.items(.result)[0] = @fromBackingInt(1);
    try std.testing.expectError(error.InvalidReceiverEvidence, solve(a, &built, Probe.authority));
}
test "native receiver owned result allocation failure cleanup" {
    const a = std.testing.allocator;
    var built = try Probe.make(a);
    defer built.deinit(a);
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(gpa: Allocator, input: *const Build.Output) !void {
            var out = try solve(gpa, input, Probe.authority);
            defer out.deinit(gpa);
            try std.testing.expect((try out.at(@fromBackingInt(2))) != null);
        }
    }.run, .{&built});
}

test "native receiver rejects valid index callee source and contract joins" {
    const a = std.testing.allocator;
    var built = try Probe.make(a);
    defer built.deinit(a);
    const original = built.calls.get(0);
    built.calls.items(.callee)[0] = @fromBackingInt(4);
    try std.testing.expectError(error.InvalidReceiverEvidence, solve(a, &built, Probe.authority));
    built.calls.set(0, original);
    built.execs.items(.source)[0].declaration = 1;
    try std.testing.expectError(error.InvalidReceiverEvidence, solve(a, &built, Probe.authority));
    built.execs.items(.source)[0].declaration = 2;
    try built.execs.append(a, built.execs.get(0));
    built.native_values.items(.exec)[0] = @fromBackingInt(1);
    try std.testing.expectError(error.InvalidReceiverEvidence, solve(a, &built, Probe.authority));
    built.native_values.items(.exec)[0] = @fromBackingInt(0);
    built.contracts.items(.argument)[0] = @fromBackingInt(3);
    try std.testing.expectError(error.InvalidReceiverEvidence, solve(a, &built, Probe.authority));
    built.contracts.items(.argument)[0] = @fromBackingInt(4);
    var second = original;
    second.result = @fromBackingInt(4);
    try built.calls.append(a, second);
    built.contracts.items(.call)[0] = @fromBackingInt(1);
    try std.testing.expectError(error.InvalidReceiverEvidence, solve(a, &built, Probe.authority));
    built.contracts.items(.call)[0] = @fromBackingInt(0);
    var result = try solve(a, &built, Probe.authority);
    defer result.deinit(a);
    result.by_port[0] = @fromBackingInt(@as(u32, @intCast(result.witnesses.items.len)));
    try std.testing.expectError(error.InvalidReceiverEvidence, result.at(@fromBackingInt(0)));
}
