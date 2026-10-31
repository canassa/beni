//! Formal annotation binders, captured while both checker readings exist.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Self = @This();

pub const Binding = struct { name: InternPool.Symbol, scheme: TypeStore.Var, body: TypeStore.Var.Optional = .none };
const Owner = struct { annotation: Bir.Inst.OptionalIndex = .none, start: u32 = 0, len: u32 = 0, paired: bool = false };
pub const Range = struct { start: u32, len: u32 };
owners: std.MultiArrayList(Owner) = .empty,
bindings: std.MultiArrayList(Binding) = .empty,

pub fn init(gpa: Allocator, count: usize) Allocator.Error!Self {
    var out: Self = .{};
    errdefer out.deinit(gpa);
    try out.owners.resize(gpa, count);
    for (0..count) |i| out.owners.set(i, .{});
    return out;
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.owners.deinit(gpa);
    self.bindings.deinit(gpa);
    self.* = .{};
}

pub fn scheme(self: *Self, gpa: Allocator, decl: u32, annotation: Bir.Inst.Index, scope: []const Types.Builder.Scoped) Allocator.Error!void {
    if (decl >= self.owners.len) return;
    const start: u32 = @intCast(self.bindings.len);
    for (scope) |parameter| try self.bindings.append(gpa, .{ .name = parameter.name, .scheme = parameter.v });
    self.owners.set(decl, .{ .annotation = annotation.toOptional(), .start = start, .len = @intCast(scope.len) });
}

/// Both scopes come from this exact declaration's annotation/where builder.
/// Allocation ranges and temporary alias/schema variables play no role.
pub fn checked(self: *Self, store: *TypeStore, decl: u32, annotation: Bir.Inst.Index, scope: []const Types.Builder.Scoped) void {
    if (decl >= self.owners.len) return;
    self.owners.items(.paired)[decl] = false;
    const owner = self.owners.get(decl);
    if (owner.annotation != annotation.toOptional() or owner.len != scope.len) return;
    for (scope, 0..) |parameter, i| {
        const source = self.bindings.get(owner.start + i);
        if (source.name != parameter.name) return;
        const fa = switch (store.content(store.find(source.scheme))) {
            .flex, .rigid => |flags| flags,
            else => return,
        };
        const fb = switch (store.content(store.find(parameter.v))) {
            .rigid => |flags| flags,
            else => return,
        };
        if (fa.kind != fb.kind or fa.equatable != fb.equatable or fa.name != fb.name) return;
    }
    for (scope, 0..) |parameter, i| self.bindings.items(.body)[owner.start + i] = parameter.v.toOptional();
    self.owners.items(.paired)[decl] = true;
}

pub fn of(self: *const Self, decl: usize, annotation: Bir.Inst.Index) ?Range {
    if (decl >= self.owners.len) return null;
    const owner = self.owners.get(decl);
    if (!owner.paired or owner.annotation != annotation.toOptional()) return null;
    return .{ .start = owner.start, .len = owner.len };
}

test "continuation plan annotation bindings reject wrong lexical keys and kinds without unification" {
    const gpa = std.testing.allocator;
    var interner: InternPool.Global = try .init(gpa);
    defer interner.deinit(gpa);
    var store: TypeStore = .init(gpa);
    defer store.deinit();
    const name = try interner.getOrPut(gpa, "a");
    const other = try interner.getOrPut(gpa, "other");
    const a = try store.fresh(.{ .flex = .{ .name = name.toOptional() } }, TypeStore.generalized);
    const b = try store.fresh(.{ .rigid = .{ .name = name.toOptional() } }, 1);
    const bad = try store.fresh(.{ .rigid = .{ .name = name.toOptional(), .kind = .number } }, 1);
    var readings: Self = try .init(gpa, 2);
    defer readings.deinit(gpa);
    const annotation: Bir.Inst.Index = @fromBackingInt(0);
    try readings.scheme(gpa, 0, annotation, &.{.{ .name = name, .v = a }});
    try std.testing.expect(readings.of(0, annotation) == null);
    readings.checked(&store, 0, annotation, &.{.{ .name = name, .v = b }});
    const range = readings.of(0, annotation).?;
    try std.testing.expectEqual(@as(u32, 1), range.len);
    const binding = readings.bindings.get(range.start);
    try std.testing.expectEqual(a, binding.scheme);
    try std.testing.expectEqual(b, binding.body.unwrap().?);
    try std.testing.expect(store.find(a) != store.find(b));
    try std.testing.expect(readings.of(1, annotation) == null);
    readings.checked(&store, 0, @fromBackingInt(1), &.{.{ .name = name, .v = b }});
    try std.testing.expect(readings.of(0, annotation) == null);
    readings.checked(&store, 0, annotation, &.{.{ .name = other, .v = b }});
    try std.testing.expect(readings.of(0, annotation) == null);
    readings.checked(&store, 0, annotation, &.{.{ .name = name, .v = bad }});
    try std.testing.expect(readings.of(0, annotation) == null);
    readings.checked(&store, 0, annotation, &.{});
    try std.testing.expect(readings.of(0, annotation) == null);
    try readings.scheme(gpa, 1, annotation, &.{});
    readings.checked(&store, 1, annotation, &.{});
    try std.testing.expectEqual(@as(u32, 0), readings.of(1, annotation).?.len);
    try std.testing.expect(store.find(a) != store.find(b));
}
