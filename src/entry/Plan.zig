//! Session-owned resolved entry metadata (workers-emission.md). These indices
//! belong to one checked store; reset before replacing that store. No row borrows
//! a manifest arena or a temporary interface-expansion frame.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Types = @import("../check/Types.zig");
const InternPool = @import("../InternPool.zig");
const Plan = @This();

pub const Realm = enum(u8) { window, dedicatedWorker, sharedWorker, serviceWorker, node };
pub const Protocol = enum(u8) { handlers, machine };
pub const RoleKind = enum(u8) { wire, local };
pub const KindIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Range = struct { start: u32 = 0, len: u32 = 0 };
pub const Value = struct { module: Graph.Index, decl: u32, scheme: Interface.SchemeIndex };
pub const Kind = struct {
    program: Types.TypeId,
    module: Graph.Index,
    interface_type: Interface.TypeIndex,
    arity: u16,
    realm: Realm,
    layer: u32,
    runtime: Value,
    constructors: Range,
    launches: Range,
    roles: Range,
};
pub const Constructor = struct { value: Value, parameter: u32, protocol: Protocol };
pub const Launch = struct { value: Value, parameter: u32 };
pub const Role = struct { index: u32, kind: RoleKind, path: Range };

kinds: std.MultiArrayList(Kind) = .empty,
constructors: std.MultiArrayList(Constructor) = .empty,
launches: std.MultiArrayList(Launch) = .empty,
roles: std.MultiArrayList(Role) = .empty,
paths: std.ArrayList(InternPool.Symbol) = .empty,
selected: KindIndex = .none,
validated: bool = false,

/// Retain capacity but publish no previous proof or selected runtime. This is
/// called both on a new Session run and before contract revalidation.
pub fn reset(plan: *Plan) void {
    plan.kinds.clearRetainingCapacity();
    plan.constructors.clearRetainingCapacity();
    plan.launches.clearRetainingCapacity();
    plan.roles.clearRetainingCapacity();
    plan.paths.clearRetainingCapacity();
    plan.selected = .none;
    plan.validated = false;
}

pub fn deinit(plan: *Plan, gpa: Allocator) void {
    plan.kinds.deinit(gpa);
    plan.constructors.deinit(gpa);
    plan.launches.deinit(gpa);
    plan.roles.deinit(gpa);
    plan.paths.deinit(gpa);
    plan.* = .{};
}

/// Only an entirely successful validation publishes the newly resolved rows.
pub fn finish(plan: *Plan) void {
    plan.validated = true;
}

pub fn runtime(plan: *const Plan) ?Value {
    if (!plan.validated or plan.selected == .none) return null;
    const index = @backingInt(plan.selected);
    std.debug.assert(index < plan.kinds.len);
    return plan.kinds.get(index).runtime;
}

pub fn appendKind(plan: *Plan, gpa: Allocator, kind: Kind) Allocator.Error!KindIndex {
    const index: KindIndex = @fromBackingInt(@intCast(plan.kinds.len));
    try plan.kinds.append(gpa, kind);
    return index;
}

pub fn appendRole(plan: *Plan, gpa: Allocator, index: u32, kind: RoleKind, path: []const InternPool.Symbol) Allocator.Error!void {
    const start: u32 = @intCast(plan.paths.items.len);
    try plan.paths.appendSlice(gpa, path);
    try plan.roles.append(gpa, .{ .index = index, .kind = kind, .path = .{ .start = start, .len = @intCast(path.len) } });
}

test "resolved entry plan reset removes every checked-store reference" {
    const gpa = std.testing.allocator;
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    const value: Value = .{ .module = @fromBackingInt(2), .decl = 3, .scheme = @fromBackingInt(4) };
    const program: Types.TypeId = @fromBackingInt(5);
    try plan.constructors.append(gpa, .{ .value = value, .parameter = 0, .protocol = .handlers });
    try plan.launches.append(gpa, .{ .value = value, .parameter = 1 });
    try plan.appendRole(gpa, 2, .wire, &.{@fromBackingInt(6)});
    plan.selected = try plan.appendKind(gpa, .{
        .program = program,
        .module = value.module,
        .interface_type = @fromBackingInt(7),
        .arity = 3,
        .realm = .dedicatedWorker,
        .layer = 0,
        .runtime = value,
        .constructors = .{ .start = 0, .len = 1 },
        .launches = .{ .start = 0, .len = 1 },
        .roles = .{ .start = 0, .len = 1 },
    });
    try std.testing.expectEqual(@as(?Value, null), plan.runtime());
    plan.finish();
    try std.testing.expectEqualDeep(@as(?Value, value), plan.runtime());
    plan.reset();
    try std.testing.expectEqual(@as(usize, 0), plan.kinds.len);
    try std.testing.expectEqual(@as(usize, 0), plan.constructors.len);
    try std.testing.expectEqual(@as(usize, 0), plan.launches.len);
    try std.testing.expectEqual(@as(usize, 0), plan.roles.len);
    try std.testing.expectEqual(@as(usize, 0), plan.paths.items.len);
    try std.testing.expectEqual(KindIndex.none, plan.selected);
    try std.testing.expectEqual(@as(?Value, null), plan.runtime());
    plan.finish(); // A successful legacy recheck has no generic runtime.
    try std.testing.expectEqual(@as(?Value, null), plan.runtime());
}

test "resolved entry plan replacement cannot select an earlier runtime" {
    const gpa = std.testing.allocator;
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    for ([_]u32{ 3, 9 }) |decl| {
        plan.reset();
        const value: Value = .{ .module = @fromBackingInt(2), .decl = decl, .scheme = @fromBackingInt(4) };
        plan.selected = try plan.appendKind(gpa, .{
            .program = @fromBackingInt(5),
            .module = value.module,
            .interface_type = @fromBackingInt(7),
            .arity = 0,
            .realm = .node,
            .layer = 0,
            .runtime = value,
            .constructors = .{},
            .launches = .{},
            .roles = .{},
        });
        plan.finish();
        try std.testing.expectEqual(@as(usize, 1), plan.kinds.len);
        try std.testing.expectEqual(decl, plan.runtime().?.decl);
    }
    plan.reset(); // A rejected validation cannot expose the old successful row.
    try std.testing.expectEqual(@as(?Value, null), plan.runtime());
}
