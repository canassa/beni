//! Private source-provenance graph. Reference words are supplied by dispatch.
const std = @import("std");
const S = @import("../check/SolvedRepresentations.zig");
const Store = @import("../check/TypeStore.zig");
const Allocator = std.mem.Allocator;
const header: usize = 48;
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn get(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
pub fn write(gpa: Allocator, a: *const S.Artifact, node_refs: []const u32, root_refs: []const u32, labels: []const u32) Allocator.Error![]u8 {
    if (!a.present) return gpa.alloc(u8, 0);
    const out = try gpa.alloc(u8, header + a.nodes.len * 32 + a.edges.len * 12 + a.roots.len * 32 + a.formals.len * 4 + a.descriptor_nodes.len * 4);
    @memset(out, 0);
    @memcpy(out[0..8], "BENISLV\x00");
    put(out, 8, S.schema_version);
    put(out, 12, a.counts.descriptors);
    put(out, 16, a.counts.representatives);
    put(out, 20, a.counts.parent_edges);
    put(out, 24, a.counts.edges);
    put(out, 28, a.counts.fields);
    put(out, 32, @intCast(a.roots.len));
    put(out, 36, @intCast(a.formals.len));
    var at: usize = header;
    for (0..a.nodes.len) |i| {
        const n = a.nodes.get(i);
        for ([_]u32{ @backingInt(n.source), @backingInt(n.tag), n.start, n.len, node_refs[i], n.rank, @backingInt(n.kind), @intFromBool(n.marker_eq) }, 0..) |word, j| put(out, at + j * 4, word);
        at += 32;
    }
    for (0..a.edges.len) |i| {
        const e = a.edges.get(i);
        put(out, at, @backingInt(e.target));
        put(out, at + 4, @backingInt(e.kind));
        put(out, at + 8, labels[i]);
        at += 12;
    }
    for (0..a.roots.len) |i| {
        const r = a.roots.get(i);
        for ([_]u32{ @backingInt(r.kind), r.declaration, root_refs[i], r.anchor, @backingInt(r.node), r.start, r.len, @backingInt(r.origin) }, 0..) |word, j| put(out, at + j * 4, word);
        at += 32;
    }
    for (a.formals) |n| {
        put(out, at, @backingInt(n));
        at += 4;
    }
    for (a.descriptor_nodes) |n| {
        put(out, at, @backingInt(n));
        at += 4;
    }
    return out;
}
pub const Error = Allocator.Error || error{BadRepresentations};
pub fn read(gpa: Allocator, bytes: []const u8) Error!S.Artifact {
    if (bytes.len == 0) return .empty;
    if (bytes.len < header or !std.mem.eql(u8, bytes[0..8], "BENISLV\x00") or get(bytes, 8) != S.schema_version or get(bytes, 40) != 0 or get(bytes, 44) != 0) return error.BadRepresentations;
    const d = get(bytes, 12);
    const t = get(bytes, 16);
    const e = get(bytes, 24);
    const roots = get(bytes, 32);
    const formals = get(bytes, 36);
    const expected = header + @as(u64, t) * 32 + @as(u64, e) * 12 + @as(u64, roots) * 32 + @as(u64, formals) * 4 + @as(u64, d) * 4;
    if (expected != bytes.len) return error.BadRepresentations;
    var out: S.Artifact = .{ .present = true, .counts = .{ .descriptors = d, .representatives = t, .parent_edges = get(bytes, 20), .edges = e, .fields = get(bytes, 28) } };
    errdefer out.deinit(gpa);
    var ns: std.MultiArrayList(S.Node) = .empty;
    defer ns.deinit(gpa);
    var es: std.MultiArrayList(S.Edge) = .empty;
    defer es.deinit(gpa);
    var rs: std.MultiArrayList(S.Root) = .empty;
    defer rs.deinit(gpa);
    var at: usize = header;
    for (0..t) |_| {
        if (get(bytes, at + 4) > @backingInt(S.Tag.alias) or get(bytes, at + 24) > @backingInt(Store.Kind.string_key) or get(bytes, at + 28) > 1) return error.BadRepresentations;
        try ns.append(gpa, .{ .source = @fromBackingInt(get(bytes, at)), .tag = @fromBackingInt(@intCast(get(bytes, at + 4))), .start = get(bytes, at + 8), .len = get(bytes, at + 12), .nominal = @fromBackingInt(get(bytes, at + 16)), .rank = get(bytes, at + 20), .kind = @fromBackingInt(@intCast(get(bytes, at + 24))), .marker_eq = get(bytes, at + 28) == 1 });
        at += 32;
    }
    for (0..e) |_| {
        if (get(bytes, at + 4) > @backingInt(S.EdgeKind.actual)) return error.BadRepresentations;
        try es.append(gpa, .{ .target = @fromBackingInt(get(bytes, at)), .kind = @fromBackingInt(@intCast(get(bytes, at + 4))), .selector = get(bytes, at + 8) });
        at += 12;
    }
    for (0..roots) |_| {
        if (get(bytes, at) > @backingInt(S.RootKind.alias_template) or get(bytes, at + 28) > @backingInt(S.Origin.nominal)) return error.BadRepresentations;
        try rs.append(gpa, .{ .kind = @fromBackingInt(@intCast(get(bytes, at))), .declaration = get(bytes, at + 4), .nominal = @fromBackingInt(get(bytes, at + 8)), .anchor = get(bytes, at + 12), .origin = @fromBackingInt(@intCast(get(bytes, at + 28))), .node = @fromBackingInt(get(bytes, at + 16)), .start = get(bytes, at + 20), .len = get(bytes, at + 24) });
        at += 32;
    }
    out.formals = try gpa.alloc(S.NodeIndex, formals);
    for (out.formals) |*n| {
        n.* = @fromBackingInt(get(bytes, at));
        at += 4;
    }
    out.descriptor_nodes = try gpa.alloc(S.NodeIndex, d);
    for (out.descriptor_nodes) |*n| {
        n.* = @fromBackingInt(get(bytes, at));
        at += 4;
    }
    out.nodes = ns.toOwnedSlice();
    out.edges = es.toOwnedSlice();
    out.roots = rs.toOwnedSlice();
    if (!out.verify()) return error.BadRepresentations;
    return out;
}

test "solved representation codec distinguishes absent and complete empty and validates all header words" {
    const gpa = std.testing.allocator;
    const a: S.Artifact = .{ .present = true };
    const bytes = try write(gpa, &a, &.{}, &.{}, &.{});
    defer gpa.free(bytes);
    var loaded = try read(gpa, bytes);
    defer loaded.deinit(gpa);
    try std.testing.expect(loaded.present and loaded.verify());
    var absent = try read(gpa, &.{});
    defer absent.deinit(gpa);
    try std.testing.expect(!absent.present);
    for (1..bytes.len) |end| try std.testing.expectError(error.BadRepresentations, read(gpa, bytes[0..end]));
    for ([_]usize{ 8, 12, 16, 20, 24, 28, 32, 36, 40, 44 }) |at| {
        const old = get(bytes, at);
        put(bytes, at, old + 1);
        try std.testing.expectError(error.BadRepresentations, read(gpa, bytes));
        put(bytes, at, old);
    }
}
test "solved representation parser fuzz never returns an invalid graph" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) !void {
            var buffer: [4096]u8 = undefined;
            const len = smith.sliceWithHash(&buffer, 0xb67a52);
            var a = read(std.testing.allocator, buffer[0..len]) catch return;
            defer a.deinit(std.testing.allocator);
            try std.testing.expect(a.verify());
        }
    }.one, .{});
}

test "solved representation codec preserves actual nonempty scopes and unwinds every allocation failure" {
    const gpa = std.testing.allocator;
    var store: Store = .init(gpa);
    defer store.deinit();
    const formal = try store.fresh(.{ .flex = .{ .kind = .number } }, 0);
    const tuple = try store.fresh(.{ .structure = .{ .tuple = try store.addVars(&.{ formal, formal }) } }, 0);
    var capture: S.Capture = .{};
    defer capture.deinit(gpa);
    try capture.add(gpa, .entry, .entry, 3, .none, 0, tuple, &.{formal});
    var a = try @import("../check/SolvedRepresentationBuild.zig").build(gpa, &store, &capture);
    defer a.deinit(gpa);
    const refs = try gpa.alloc(u32, a.nodes.len);
    defer gpa.free(refs);
    @memset(refs, S.none);
    const labels = try gpa.alloc(u32, a.edges.len);
    defer gpa.free(labels);
    for (labels, 0..) |*label, i| label.* = a.edges.get(i).selector;
    const bytes = try write(gpa, &a, refs, &.{S.none}, labels);
    defer gpa.free(bytes);
    var loaded = try read(gpa, bytes);
    defer loaded.deinit(gpa);
    try std.testing.expectEqualDeep(a.counts, loaded.counts);
    try std.testing.expectEqualSlices(S.NodeIndex, a.formals, loaded.formals);
    try std.testing.expectEqualDeep(a.roots.get(0), loaded.roots.get(0));
    for (0..a.nodes.len) |i| try std.testing.expectEqualDeep(a.nodes.get(i), loaded.nodes.get(i));
    // Unknown tags, incorrect source self-map, field kinds and formal-node
    // identity are rejected without relying on an enclosing BEC parser.
    const edge_at = header + a.nodes.len * 32;
    const root_at = edge_at + a.edges.len * 12;
    const formal_at = root_at + a.roots.len * 32;
    for ([_]struct { at: usize, value: u32 }{
        .{ .at = header, .value = a.counts.descriptors },
        .{ .at = header + 4, .value = 999 },
        .{ .at = edge_at, .value = a.counts.representatives },
        .{ .at = edge_at + 4, .value = 999 },
        .{ .at = root_at + 16, .value = S.none },
        .{ .at = formal_at, .value = @backingInt(a.descriptor_nodes[tuple.int()]) },
    }) |mutation| {
        const old = get(bytes, mutation.at);
        put(bytes, mutation.at, mutation.value);
        try std.testing.expectError(error.BadRepresentations, read(gpa, bytes));
        put(bytes, mutation.at, old);
    }
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: Allocator, input: []const u8) !void {
            var value = try read(allocator, input);
            defer value.deinit(allocator);
        }
    }.run, .{bytes});
}
