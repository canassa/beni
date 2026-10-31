//! Owned immutable views into ordinary private schemes; not Wire proofs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const PrivateTerms = @import("../check/PrivateTerms.zig");
const Kernel = @import("ViewKernel.zig");
const RoleRoots = @This();
pub const ResultIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Range = struct { start: u32 = 0, len: u32 = 0 };
pub const ViewIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const FrameIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const View = struct { scheme: Interface.SchemeIndex, term: Interface.TermIndex, env: FrameIndex = .none };
pub const Frame = struct { start: u32, len: u32 };
pub const Kind = enum(u8) { root, obligation, shape_mismatch };
pub const Result = struct { view: ViewIndex, kind: Kind, remaining: u32, path: Range = .{} };
/// Artifact identity is this result owner's borrowed, immutable Interface.
/// Destroy this owner before replacing that artifact or resetting Session.
types: *const Interface,
views: std.MultiArrayList(View) = .empty,
frames: std.MultiArrayList(Frame) = .empty,
extra: std.ArrayList(u32) = .empty,
results: std.MultiArrayList(Result) = .empty,
projections: []u32 = &.{},
pub fn deinit(a: *RoleRoots, gpa: Allocator) void {
    a.views.deinit(gpa);
    a.frames.deinit(gpa);
    a.extra.deinit(gpa);
    a.results.deinit(gpa);
    gpa.free(a.projections);
}
/// Validated private DAG only. One projection summary per encoded term.
pub const Error = Allocator.Error;
pub fn init(gpa: Allocator, types: *const Interface) Allocator.Error!RoleRoots {
    return .{ .types = types, .projections = try Kernel.projections(gpa, types) };
}
pub fn noteStep(_: *RoleRoots) void {}
pub fn getView(a: *const RoleRoots, index: ViewIndex) View {
    return a.views.get(@backingInt(index));
}
pub fn interface(a: *const RoleRoots, _: View) *const Interface {
    return a.types;
}
pub fn actual(a: *const RoleRoots, view: View, parameter: u32) Error!?View {
    if (view.env == .none) return null;
    const frame = a.frames.get(@backingInt(view.env));
    return a.views.get(a.extra.items[frame.start + parameter]);
}
pub fn projection(a: *const RoleRoots, _: View, body: Interface.TermIndex) ?u32 {
    const index = a.projections[body.int()];
    return if (index == PrivateTerms.no_projection) null else index;
}
pub fn alias(a: *RoleRoots, gpa: Allocator, original: View, term: Interface.Term) Error!View {
    var view = original;
    const args = a.types.range(term.rhs);
    const start: u32 = @intCast(a.extra.items.len);
    for (args) |arg| {
        const child_view = try a.add(gpa, .{ .scheme = view.scheme, .term = @fromBackingInt(arg), .env = view.env });
        try a.extra.append(gpa, @backingInt(child_view));
    }
    const frame: FrameIndex = @fromBackingInt(@intCast(a.frames.len));
    try a.frames.append(gpa, .{ .start = start, .len = @intCast(args.len) });
    view.term = a.types.type_refs[term.lhs].body;
    view.env = frame;
    return view;
}
pub fn add(a: *RoleRoots, gpa: Allocator, view: View) Allocator.Error!ViewIndex {
    const index: ViewIndex = @fromBackingInt(@intCast(a.views.len));
    try a.views.append(gpa, view);
    return index;
}
pub fn normalize(a: *RoleRoots, gpa: Allocator, original: ViewIndex) Allocator.Error!ViewIndex {
    return Kernel.normalize(RoleRoots, a, gpa, original, false);
}
pub fn head(a: *RoleRoots, gpa: Allocator, scheme: Interface.SchemeIndex) Allocator.Error!ViewIndex {
    return a.normalize(gpa, try a.add(gpa, .{ .scheme = scheme, .term = a.types.scheme(scheme).body }));
}
/// Local roles must be excluded by the caller before invoking this query.
pub fn project(a: *RoleRoots, gpa: Allocator, scheme: Interface.SchemeIndex, parameter: u32, path: []const InternPool.Symbol) Allocator.Error!ResultIndex {
    var at = try a.head(gpa, scheme);
    var view = a.views.get(@backingInt(at));
    const program = a.types.term(view.term);
    if (program.tag != .app or parameter >= a.types.range(program.rhs).len)
        return a.finish(gpa, at, .shape_mismatch, 0, path);
    view.term = @fromBackingInt(a.types.range(program.rhs)[parameter]);
    at = try a.add(gpa, view);
    for (path, 0..) |field, step| {
        at = try a.normalize(gpa, at);
        while (true) {
            view = a.views.get(@backingInt(at));
            switch (Kernel.field(a.types, view.term, field)) {
                .generic => return a.finish(gpa, at, .obligation, @intCast(step), path),
                .mismatch => return a.finish(gpa, at, .shape_mismatch, @intCast(step), path),
                .child => |child| {
                    view.term = child;
                    at = try a.add(gpa, view);
                    break;
                },
                .extension => |extension| {
                    view.term = extension;
                    at = try a.normalize(gpa, try a.add(gpa, view));
                },
            }
        }
    }
    at = try a.normalize(gpa, at);
    return a.finish(gpa, at, .root, @intCast(path.len), path);
}
fn finish(a: *RoleRoots, gpa: Allocator, view: ViewIndex, kind: Kind, remaining: u32, path: []const InternPool.Symbol) Allocator.Error!ResultIndex {
    const owned: Range = .{ .start = @intCast(a.extra.items.len), .len = @intCast(path.len - remaining) };
    for (path[remaining..]) |symbol| try a.extra.append(gpa, @backingInt(symbol));
    const index: ResultIndex = @fromBackingInt(@intCast(a.results.len));
    try a.results.append(gpa, .{ .view = view, .kind = kind, .remaining = remaining, .path = owned });
    return index;
}

test "role roots retain owned alias environments across cursor reuse and never traverse local state" {
    const gpa = std.testing.allocator;
    var interner = try InternPool.Global.init(gpa);
    defer interner.deinit(gpa);
    const item = try interner.getOrPut(gpa, "item");
    const missing = try interner.getOrPut(gpa, "missing");
    var types: Interface = .empty;
    defer types.deinit(gpa);
    var terms: std.MultiArrayList(Interface.Term) = .empty;
    defer terms.deinit(gpa);
    try terms.append(gpa, .{ .tag = .@"var", .lhs = 0, .rhs = 0 });
    try terms.append(gpa, .{ .tag = .@"var", .lhs = 1, .rhs = 0 });
    try terms.append(gpa, .{ .tag = .app, .lhs = 0, .rhs = 0 });
    try terms.append(gpa, .{ .tag = .alias, .lhs = 1, .rhs = 3 });
    try terms.append(gpa, .{ .tag = .record, .lhs = 5, .rhs = 5 });
    try terms.append(gpa, .{ .tag = .empty_record, .lhs = 0, .rhs = 0 });
    // Program(Box q1, fn(q0)->q0): callable local state is kept but not queried.
    try terms.append(gpa, .{ .tag = .func, .lhs = 8, .rhs = 0 });
    types.terms = terms.toOwnedSlice();
    types.extra = try gpa.dupe(u32, &.{ 2, 3, 6, 1, 1, 2, 0, 0, 1, 0 });
    types.symbols = try gpa.dupe(InternPool.Symbol, &.{item});
    types.type_refs = try gpa.dupe(Interface.TypeRef, &.{
        .{ .package = .platform, .module = @fromBackingInt(0), .name = @fromBackingInt(0) },
        .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(0), .body = @fromBackingInt(4) },
    });
    types.schemes = try gpa.dupe(Interface.Scheme, &.{.{ .body = @fromBackingInt(2), .quantified_start = 10, .quantified_count = 2 }});
    var owner = try RoleRoots.init(gpa, &types);
    defer owner.deinit(gpa);
    const first = try owner.project(gpa, @fromBackingInt(0), 0, &.{});
    const record_result = owner.results.get(@backingInt(first));
    try std.testing.expectEqualDeep(Result{ .view = record_result.view, .kind = .root, .remaining = 0, .path = .{ .start = 1, .len = 0 } }, record_result);
    const record_view = owner.views.get(@backingInt(record_result.view));
    try std.testing.expectEqualDeep(View{ .scheme = @fromBackingInt(0), .term = @fromBackingInt(4), .env = @fromBackingInt(0) }, record_view);
    for (0..128) |_| _ = try owner.project(gpa, @fromBackingInt(0), 0, &.{item});
    // The old result still owns its argument environment after all reallocations.
    try std.testing.expectEqualDeep(record_view, owner.views.get(@backingInt(record_result.view)));
    const frame = owner.frames.get(@backingInt(record_view.env));
    try std.testing.expectEqualDeep(View{ .scheme = @fromBackingInt(0), .term = @fromBackingInt(1) }, owner.views.get(owner.extra.items[frame.start]));
    const projected_index = try owner.project(gpa, @fromBackingInt(0), 0, &.{item});
    const projected = owner.results.get(@backingInt(projected_index));
    try std.testing.expectEqualDeep(View{ .scheme = @fromBackingInt(0), .term = @fromBackingInt(1) }, owner.views.get(@backingInt(projected.view)));
    const obligation_index = try owner.project(gpa, @fromBackingInt(0), 0, &.{ item, missing });
    const obligation = owner.results.get(@backingInt(obligation_index));
    try std.testing.expectEqualDeep(Result{ .view = obligation.view, .kind = .obligation, .remaining = 1, .path = .{ .start = 131, .len = 1 } }, obligation);
    const mismatch_index = try owner.project(gpa, @fromBackingInt(0), 0, &.{missing});
    const mismatch = owner.results.get(@backingInt(mismatch_index));
    try std.testing.expectEqualDeep(Result{ .view = mismatch.view, .kind = .shape_mismatch, .remaining = 0, .path = .{ .start = 133, .len = 1 } }, mismatch);
    var requested = [_]InternPool.Symbol{ item, missing };
    const owned_index = try owner.project(gpa, @fromBackingInt(0), 0, &requested);
    requested[1] = item;
    const owned = owner.results.get(@backingInt(owned_index));
    try std.testing.expectEqual(@as(u32, 1), owned.path.len);
    try std.testing.expectEqual(@backingInt(missing), owner.extra.items[owned.path.start]);
}

test "role roots normalize compact identity alias diamonds without expanded frames" {
    const gpa = std.testing.allocator;
    for ([_]u32{ 32, 64 }) |depth| {
        var global = try InternPool.Global.init(gpa);
        defer global.deinit(gpa);
        var symbols: std.ArrayList(InternPool.Symbol) = .empty;
        defer symbols.deinit(gpa);
        try symbols.append(gpa, try global.getOrPut(gpa, "Model"));
        try symbols.append(gpa, try global.getOrPut(gpa, "Program"));
        try symbols.append(gpa, try global.getOrPut(gpa, "A0"));
        var types: Interface = .empty;
        defer types.deinit(gpa);
        var terms: std.MultiArrayList(Interface.Term) = .empty;
        defer terms.deinit(gpa);
        var extra: std.ArrayList(u32) = .empty;
        defer extra.deinit(gpa);
        var refs: std.ArrayList(Interface.TypeRef) = .empty;
        defer refs.deinit(gpa);
        try terms.append(gpa, .{ .tag = .@"var", .lhs = 0, .rhs = 0 });
        try terms.append(gpa, .{ .tag = .@"var", .lhs = 1, .rhs = 0 });
        try refs.append(gpa, .{ .package = .platform, .module = @fromBackingInt(0), .name = @fromBackingInt(1) });
        try refs.append(gpa, .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(2), .body = @fromBackingInt(0) });
        for (0..depth) |level| {
            const inner: u32 = @intCast(terms.len);
            const inner_args: u32 = @intCast(extra.items.len);
            try extra.appendSlice(gpa, &.{ 1, 0 });
            try terms.append(gpa, .{ .tag = .alias, .lhs = @intCast(level + 1), .rhs = inner_args });
            const outer: u32 = @intCast(terms.len);
            const outer_args: u32 = @intCast(extra.items.len);
            try extra.appendSlice(gpa, &.{ 1, inner });
            try terms.append(gpa, .{ .tag = .alias, .lhs = @intCast(level + 1), .rhs = outer_args });
            var buffer: [24]u8 = undefined;
            const name = try std.fmt.bufPrint(&buffer, "A{d}", .{level + 1});
            const symbol_index: u32 = @intCast(symbols.items.len);
            try symbols.append(gpa, try global.getOrPut(gpa, name));
            try refs.append(gpa, .{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(symbol_index), .body = @fromBackingInt(outer) });
        }
        const applied: u32 = @intCast(terms.len);
        const applied_args: u32 = @intCast(extra.items.len);
        try extra.appendSlice(gpa, &.{ 1, 1 });
        try terms.append(gpa, .{ .tag = .alias, .lhs = depth + 1, .rhs = applied_args });
        const program: u32 = @intCast(terms.len);
        const program_args: u32 = @intCast(extra.items.len);
        try extra.appendSlice(gpa, &.{ 1, applied });
        try terms.append(gpa, .{ .tag = .app, .lhs = 0, .rhs = program_args });
        const quantified_start: u32 = @intCast(extra.items.len);
        try extra.appendSlice(gpa, &.{ 0, std.math.maxInt(u32), 0, 0, 0, std.math.maxInt(u32), 0, 0 });
        types.symbols = try symbols.toOwnedSlice(gpa);
        types.terms = terms.toOwnedSlice();
        types.extra = try extra.toOwnedSlice(gpa);
        types.type_refs = try refs.toOwnedSlice(gpa);
        types.schemes = try gpa.dupe(Interface.Scheme, &.{.{ .body = @fromBackingInt(program), .quantified_start = quantified_start, .quantified_count = 2 }});
        var owner = try RoleRoots.init(gpa, &types);
        defer owner.deinit(gpa);
        const index = try owner.project(gpa, @fromBackingInt(0), 0, &.{});
        const result = owner.results.get(@backingInt(index));
        try std.testing.expectEqualDeep(Result{ .view = result.view, .kind = .root, .remaining = 0 }, result);
        try std.testing.expectEqualDeep(View{ .scheme = @fromBackingInt(0), .term = @fromBackingInt(1) }, owner.views.get(@backingInt(result.view)));
        try std.testing.expectEqual(@as(usize, 0), owner.frames.len);
        try std.testing.expectEqual(@as(usize, 4), owner.views.len);
        try std.testing.expectEqual(@as(usize, depth) * 2 + 4, owner.projections.len);
        var output: std.Io.Writer.Allocating = .init(gpa);
        defer output.deinit();
        try @import("../dump/interface.zig").writeRaw(&output.writer, "Model", &types, &global);
        try std.testing.expectEqual(types.terms.len, std.mem.count(u8, output.written(), "\nterm "));
        try std.testing.expectEqual(types.type_refs.len, std.mem.count(u8, output.written(), "\ntyperef "));
        try std.testing.expect(output.written().len < @as(usize, depth) * 300 + 1500);
    }
}
