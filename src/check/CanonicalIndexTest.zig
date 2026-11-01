//! Semantic index boundary; independent accepted inventory is the oracle.
const std = @import("std");
const Store = @import("TypeStore.zig");
const Index = @import("CanonicalIndex.zig");
const S = @import("SolvedRepresentations.zig");
const Build = @import("SolvedRepresentationBuild.zig");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
// Coercion adapters let the SAME regressions execute against the original
// non-error-returning cursor API and the checked corrected API.
fn nodeNext(cursor: *Index.Nodes) Index.CursorError!?Index.Node {
    return cursor.next();
}
fn childNext(cursor: *Index.Children) Index.CursorError!?Index.Child {
    return cursor.next();
}

fn oracle(store: *Store) !void {
    const index = store.canonical.?;
    var capture: S.Capture = .{};
    defer capture.deinit(std.testing.allocator);
    var ordinary = try Build.build(std.testing.allocator, store, &capture);
    defer ordinary.deinit(std.testing.allocator);
    try index.compare(&ordinary);
}

test "canonical index follows real union survivor and cyclic replacement without changing source IDs" {
    var store: Store = .init(std.testing.allocator);
    defer store.deinit();
    try store.enableCanonical();
    const a = try store.freshFlex(1);
    const b = try store.freshFlex(1);
    const pair = try store.fresh(.{ .structure = .{ .tuple = try store.addVars(&.{ a, b, a }) } }, 1);
    try oracle(&store);
    const keep = store.merge(a, b, .{ .structure = .unit });
    try equal(a, keep);
    try equal(a, store.get(b).parent);
    try oracle(&store);
    // A genuine cycle; no graph unfolding or fixed-depth fallback.
    store.setContent(keep, .{ .structure = .{ .tuple = try store.addVars(&.{ pair, keep }) } });
    try oracle(&store);
    _ = store.merge(keep, keep, .{ .structure = .{ .tuple = try store.addVars(&.{pair}) } });
    try oracle(&store);
    const large = try store.freshFlex(1);
    const small = try store.freshFlex(1);
    _ = store.merge(large, small, .{ .structure = .unit });
    // Second argument is the actual heavier ordinary root.
    try equal(large, store.merge(pair, large, .{ .structure = .unit }));
    try oracle(&store);
    try expect((try store.canonical.?.statistics()).canonical_redirect > 0);
}

test "canonical index alias expansion retains actual outgoing and reuses retired edge slots" {
    var store: Store = .init(std.testing.allocator);
    defer store.deinit();
    try store.enableCanonical();
    const leaf = try store.fresh(.{ .structure = .unit }, 1);
    const actual = try store.fresh(.{ .structure = .{ .tuple = try store.addVars(&.{leaf}) } }, 1);
    const alias = try store.fresh(.{ .alias = .{ .type = @fromBackingInt(0), .args = try store.addVars(&.{ leaf, actual }), .actual = actual } }, 1);
    const outer = try store.fresh(.{ .structure = .{ .tuple = try store.addVars(&.{ alias, actual, alias }) } }, 1);
    try oracle(&store);
    _ = store.expandAlias(alias, actual);
    try oracle(&store);
    for (0..64) |_| {
        store.setContent(outer, .{ .structure = .unit });
        store.setContent(outer, .{ .structure = .{ .tuple = try store.addVars(&.{ leaf, actual, outer }) } });
    }
    try oracle(&store);
    const work = try store.canonical.?.statistics();
    try equal(@as(u64, 1), work.canonical_alias);
    try expect(work.canonical_remove > 192);
}

test "canonical index export visits only live graph despite descriptor history and repeated positional fields" {
    var store: Store = .init(std.testing.allocator);
    defer store.deinit();
    try store.enableCanonical();
    const root = try store.freshFlex(1);
    for (0..4096) |_| {
        const dead = try store.freshFlex(1);
        _ = store.merge(root, dead, .{ .structure = .unit });
    }
    const fields = try std.testing.allocator.alloc(Store.Var, 1024);
    defer std.testing.allocator.free(fields);
    @memset(fields, root);
    _ = try store.fresh(.{ .structure = .{ .tuple = try store.addVars(fields) } }, 1);
    try oracle(&store);
    const before = try store.canonical.?.statistics();
    var nodes = try store.canonical.?.nodes();
    var n: u32 = 0;
    var e: u32 = 0;
    while (try nodeNext(&nodes)) |node| {
        n += 1;
        var children = try store.canonical.?.children(node);
        while (try childNext(&children)) |child| {
            try expect(child.position < 2);
            try equal(root, child.source);
            e += 1;
        }
    }
    const after = try store.canonical.?.statistics();
    try equal(@as(u32, 2), n);
    try equal(@as(u32, 1024), e);
    try equal(@as(u64, 2), after.canonical_export_nodes - before.canonical_export_nodes);
    try equal(@as(u64, 1024), after.canonical_export_edges - before.canonical_export_edges);
    try equal(before.canonical_parent_steps, after.canonical_parent_steps);
    try equal(@as(u32, 4098), store.count());
}

test "canonical index is absent by default and a recreated store has fresh authority" {
    var store: Store = .init(std.testing.allocator);
    const a = try store.freshFlex(1);
    const b = try store.freshFlex(1);
    _ = store.merge(a, b, .{ .structure = .unit });
    try expect(store.canonical == null);
    store.deinit();
    store = .init(std.testing.allocator);
    defer store.deinit();
    try store.enableCanonical();
    _ = try store.fresh(.{ .structure = .unit }, 0);
    try oracle(&store);
    try equal(@as(u64, 1), (try store.canonical.?.statistics()).canonical_fresh);
}

fn faultSequence(gpa: Allocator) !void {
    var store: Store = .init(std.testing.allocator);
    defer store.deinit();
    var index: Index = .{};
    defer index.deinit(gpa);
    errdefer {
        std.debug.assert(index.failed);
        std.debug.assert(index.check() == error.OutOfMemory);
        std.debug.assert(index.statistics() == error.OutOfMemory);
        std.debug.assert(index.nodes() == error.OutOfMemory);
    }
    // Independent ordinary store mutations finish even when an index allocation fails.
    const a = try store.freshFlex(1);
    try index.fresh(gpa, &store, a);
    const b = try store.freshFlex(1);
    try index.fresh(gpa, &store, b);
    const args = try std.testing.allocator.alloc(Store.Var, 257);
    defer std.testing.allocator.free(args);
    @memset(args, a);
    const tuple = try store.fresh(.{ .structure = .{ .tuple = try store.addVars(args[0..9]) } }, 1);
    try index.fresh(gpa, &store, tuple);
    store.setContent(tuple, .{ .structure = .{ .tuple = try store.addVars(args[0..65]) } });
    try index.replace(gpa, &store, tuple);
    // An allocation-requiring survivor overwrite, beyond the released edge slots.
    const survivor: Store.Content = .{ .structure = .{ .tuple = try store.addVars(args) } };
    const keep = store.merge(a, b, survivor);
    try index.merge(gpa, &store, a, b, keep);
    const alias = try store.fresh(.{ .alias = .{ .type = @fromBackingInt(0), .args = .empty, .actual = tuple } }, 1);
    try index.fresh(gpa, &store, alias);
    _ = store.expandAlias(alias, tuple);
    index.expandAlias(alias, tuple); // Deliberately allocation-free.
    var capture: S.Capture = .{};
    defer capture.deinit(std.testing.allocator);
    var ordinary = try Build.build(std.testing.allocator, &store, &capture);
    defer ordinary.deinit(std.testing.allocator);
    try index.compare(&ordinary);
}
test "canonical index allocation failures invalidate all authority including partial replacements and merges" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, faultSequence, .{});
}

test "canonical index invalidates existing node and child cursors on ordinary mutation" {
    var store: Store = .init(std.testing.allocator);
    defer store.deinit();
    try store.enableCanonical();
    const a = try store.freshFlex(1);
    const b = try store.fresh(.{ .structure = .{ .tuple = try store.addVars(&.{a}) } }, 1);
    _ = try store.fresh(.{ .structure = .unit }, 1);
    var nodes = try store.canonical.?.nodes();
    _ = try nodeNext(&nodes);
    const node = (try nodeNext(&nodes)).?;
    var children = try store.canonical.?.children(node);
    _ = store.merge(a, b, .{ .structure = .unit });
    try std.testing.expectError(error.InvalidatedCanonicalCursor, nodeNext(&nodes));
    try std.testing.expectError(error.InvalidatedCanonicalCursor, childNext(&children));
    try std.testing.expectError(error.InvalidatedCanonicalCursor, store.canonical.?.children(node));
    try oracle(&store);
}

test "canonical index sticky OOM invalidates cursors obtained before failed fresh and replacement" {
    for ([_]bool{ false, true }) |creating| {
        var store: Store = .init(std.testing.allocator);
        defer store.deinit();
        var index: Index = .{};
        defer index.deinit(std.testing.allocator);
        const a = try store.freshFlex(1);
        try index.fresh(std.testing.allocator, &store, a);
        var nodes = try index.nodes();
        const node = (try nodeNext(&nodes)).?;
        var children = try index.children(node);
        const args = try std.testing.allocator.alloc(Store.Var, 1024);
        defer std.testing.allocator.free(args);
        @memset(args, a);
        const content: Store.Content = .{ .structure = .{ .tuple = try store.addVars(args) } };
        var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        const target = if (creating) try store.fresh(content, 1) else blk: {
            store.setContent(a, content);
            break :blk a;
        };
        if (creating) {
            try std.testing.expectError(error.OutOfMemory, index.fresh(failure.allocator(), &store, target));
        } else {
            try std.testing.expectError(error.OutOfMemory, index.replace(failure.allocator(), &store, a));
        }
        try std.testing.expectError(error.OutOfMemory, nodeNext(&nodes));
        try std.testing.expectError(error.OutOfMemory, childNext(&children));
        try std.testing.expectError(error.OutOfMemory, index.children(node));
        try std.testing.expectError(error.OutOfMemory, index.statistics());
        try equal(@as(u32, 1024), store.content(target).structure.tuple.len);
    }
}
