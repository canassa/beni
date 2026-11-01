//! Full ordinary declaration schemes selected for typed entry inspection.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const Types = @import("Types.zig");
const TypeStore = @import("TypeStore.zig");
const Schemes = @import("Schemes.zig");
const ContinuationPlan = @import("ContinuationPlan.zig");
const PrivateTerms = @import("PrivateTerms.zig");
const Selection = @import("../entry/Selection.zig");
const RoleRoots = @import("../entry/RoleRoots.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
pub const schema_version: u32 = 1;
pub const Row = struct { decl: Bir.DeclIndex, scheme: Interface.SchemeIndex };
pub const Artifact = struct {
    present: bool = false,
    roots: std.MultiArrayList(Row).Slice = .empty,
    types: Interface = .empty,
    pub const empty: Artifact = .{};
    pub fn deinit(a: *Artifact, gpa: Allocator) void {
        a.roots.deinit(gpa);
        a.types.deinit(gpa);
        a.* = .empty;
    }
    pub fn find(a: *const Artifact, decl: Bir.DeclIndex) ?Interface.SchemeIndex {
        var lo: usize = 0;
        var hi = a.roots.len;
        const decls = a.roots.items(.decl);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (decls[mid].int() < decl.int()) lo = mid + 1 else hi = mid;
        }
        return if (lo < decls.len and decls[lo] == decl) a.roots.items(.scheme)[lo] else null;
    }
    pub fn verify(a: *const Artifact, gpa: Allocator, interner: *const InternPool.Global) Allocator.Error!bool {
        if (!a.present) return a.roots.len == 0 and a.types.terms.len == 0 and a.types.schemes.len == 0;
        if (a.types.schemes.len != a.roots.len) return false;
        inline for (.{ "values", "types", "ctors", "schemas", "schema_members", "schema_ctors", "hidden_types", "elements", "attributes", "events", "ownership" }) |field| {
            if (@field(a.types, field).len != 0) return false;
        }
        if (!iface_bytes.verify(&a.types, interner)) return false;
        var previous: ?u32 = null;
        for (0..a.roots.len) |i| {
            const row = a.roots.get(i);
            if (@backingInt(row.scheme) != i) return false;
            if (previous) |p| if (row.decl.int() <= p) return false;
            previous = row.decl.int();
        }
        for (a.types.terms.items(.tag), 0..) |tag, i| {
            if (tag == .err) return false;
            if (tag != .record) continue;
            const fields = a.types.range(a.types.terms.items(.lhs)[i]);
            var prior: ?InternPool.Symbol = null;
            var f: usize = 0;
            while (f < fields.len) : (f += 2) {
                const symbol = a.types.symbol(@fromBackingInt(fields[f]));
                if (prior) |p| if (!std.mem.lessThan(u8, interner.slice(p), interner.slice(symbol))) return false;
                prior = symbol;
            }
        }
        return PrivateTerms.verifyTypes(gpa, &a.types);
    }
    /// Heads have ALREADY been resolved from serialized refs into current Types.
    pub fn covers(a: *const Artifact, gpa: Allocator, bir: *const Bir, graph: *const Graph, types: *const Types, heads: []const Types.TypeId, selection: *const Selection) Allocator.Error!bool {
        if (!a.present or heads.len != bir.decls.len) return false;
        const ids = try gpa.alloc(Types.TypeId, a.types.type_refs.len);
        defer gpa.free(ids);
        for (a.types.type_refs, ids) |ref, *id| {
            id.* = types.find(graph, ref.package, a.types.symbol(ref.module), a.types.symbol(ref.name));
            if (id.* == .none) return false;
        }
        for (a.types.terms.items(.tag), 0..) |tag, i| {
            if (tag != .app and tag != .alias) continue;
            const term = a.types.terms.get(i);
            const declared = types.entry(ids[term.lhs]);
            if ((tag == .alias) != (declared.kind == .alias) or a.types.range(term.rhs).len != declared.arity) return false;
        }
        var views = try RoleRoots.init(gpa, &a.types);
        defer views.deinit(gpa);
        for (0..a.roots.len) |i| {
            const row = a.roots.get(i);
            if (row.decl.int() >= bir.decls.len or !bir.decls[row.decl.int()].kind.isValue()) return false;
            const root = try views.head(gpa, row.scheme);
            const view = views.views.get(@backingInt(root));
            const term = a.types.term(view.term);
            if (term.tag != .app or ids[term.lhs] != heads[row.decl.int()]) return false;
        }
        for (heads, 0..) |head, i| {
            if (selection.contains(head) and a.find(@fromBackingInt(@intCast(i))) == null) return false;
        }
        return true;
    }
};
pub const Error = Allocator.Error || error{ MissingEvidence, BadScope };
pub fn build(in: ContinuationPlan.Input, selection: *const Selection) Error!Artifact {
    if (selection.selected.len == 0) return .{ .present = true };
    var selected = false;
    for (in.dispatch.decl_heads) |head| if (selection.contains(head)) {
        selected = true;
        break;
    };
    if (!selected) return .{ .present = true };
    var out: Artifact = .{ .present = true };
    errdefer out.deinit(in.gpa);
    var rows: std.MultiArrayList(Row) = .empty;
    defer rows.deinit(in.gpa);
    var writer: Schemes.Writer = .init(in.gpa, in.store, in.interner, in.types, 0);
    defer writer.deinit();
    var bodies = in.cx.builder(.flex, TypeStore.generalized);
    defer bodies.deinit();
    bodies.shallow = true;
    writer.bodies = &bodies;
    writer.crossing = in.crossing;
    writer.solved_capture = in.solved_capture;
    for (in.bir.decls, 0..) |decl, di| {
        if (!decl.kind.isValue() or !selection.contains(in.dispatch.decl_heads[di])) continue;
        const root = in.decl_scheme[di].unwrap() orelse return error.MissingEvidence;
        const requirements = in.dispatch.declRequirements(@intCast(di));
        const identities = in.dispatch.declIdentities(@intCast(di));
        const quantified = try in.scratch.alloc(u16, identities.len);
        defer in.scratch.free(quantified);
        for (identities, quantified) |identity, *q| {
            if (identity >= requirements.len) return error.MissingEvidence;
            q.* = requirements[identity].quantified;
        }
        writer.identities = quantified;
        writer.effects = .{ .effects = in.effects, .decl = @intCast(di) };
        writer.solved_entry = @intCast(di);
        const scheme = try writer.addPrivate(root);
        try rows.append(in.gpa, .{ .decl = @fromBackingInt(@intCast(di)), .scheme = scheme });
    }
    out.roots = rows.toOwnedSlice();
    try writer.attach(&out.types);
    if (!try out.verify(in.gpa, in.interner)) return error.MissingEvidence;
    return out;
}
const magic = "BENIENT\x00";
const header: usize = 24;
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn get(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
pub fn write(gpa: Allocator, a: *const Artifact, interner: *const InternPool.Global) Allocator.Error![]u8 {
    if (!a.present) return gpa.alloc(u8, 0);
    const record = if (a.roots.len == 0) try gpa.alloc(u8, 0) else try iface_bytes.write(gpa, &a.types, interner);
    defer gpa.free(record);
    const bytes = try gpa.alloc(u8, header + a.roots.len * 8 + record.len);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], magic);
    put(bytes, 8, schema_version);
    put(bytes, 12, @intCast(a.roots.len));
    put(bytes, 16, @intCast(record.len));
    for (0..a.roots.len) |i| {
        const row = a.roots.get(i);
        put(bytes, header + i * 8, row.decl.int());
        put(bytes, header + i * 8 + 4, @backingInt(row.scheme));
    }
    @memcpy(bytes[header + a.roots.len * 8 ..], record);
    return bytes;
}
pub const ReadError = iface_bytes.ReadError || error{BadRoots};
pub fn read(gpa: Allocator, bytes: []const u8, interner: *const InternPool.Global) ReadError!Artifact {
    return decode(gpa, bytes, interner, false);
}
pub fn readGrowing(gpa: Allocator, bytes: []const u8, interner: *InternPool.Global) ReadError!Artifact {
    return decode(gpa, bytes, interner, true);
}
fn decode(gpa: Allocator, bytes: []const u8, interner: anytype, comptime growing: bool) ReadError!Artifact {
    if (bytes.len == 0) return .empty;
    if (bytes.len < header or !std.mem.eql(u8, bytes[0..8], magic) or get(bytes, 8) != schema_version or get(bytes, 20) != 0) return error.BadRoots;
    const count = get(bytes, 12);
    const record = get(bytes, 16);
    const start = @as(u64, header) + @as(u64, count) * 8;
    if (start + record != bytes.len or (count == 0) != (record == 0)) return error.BadRoots;
    var out: Artifact = .{ .present = true };
    errdefer out.deinit(gpa);
    var rows: std.MultiArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    try rows.ensureTotalCapacity(gpa, count);
    for (0..count) |i| rows.appendAssumeCapacity(.{ .decl = @fromBackingInt(get(bytes, header + i * 8)), .scheme = @fromBackingInt(get(bytes, header + i * 8 + 4)) });
    out.roots = rows.toOwnedSlice();
    if (record != 0) out.types = if (growing) try iface_bytes.readGrowing(gpa, bytes[@intCast(start)..], interner) else try iface_bytes.read(gpa, bytes[@intCast(start)..], interner);
    if (!try out.verify(gpa, interner)) return error.BadRoots;
    return out;
}

test "entry roots codec distinguishes complete empty from absence and rejects every header truncation" {
    const gpa = std.testing.allocator;
    var interner = try InternPool.Global.init(gpa);
    defer interner.deinit(gpa);
    const bytes = try write(gpa, &.{ .present = true }, &interner);
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(usize, 24), bytes.len);
    var decoded = try read(gpa, bytes, &interner);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualDeep(Artifact{ .present = true }, decoded);
    var absent = try read(gpa, &.{}, &interner);
    defer absent.deinit(gpa);
    try std.testing.expectEqualDeep(Artifact.empty, absent);
    for (1..bytes.len) |length| try std.testing.expectError(error.BadRoots, read(gpa, bytes[0..length], &interner));
    const broken = try gpa.dupe(u8, bytes);
    defer gpa.free(broken);
    for ([_]usize{ 0, 8, 12, 16, 20 }) |at| {
        broken[at] ^= 1;
        try std.testing.expectError(error.BadRoots, read(gpa, broken, &interner));
        broken[at] ^= 1;
    }
}
test "entry roots decoder fuzz never publishes malformed bytes" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            var storage: [4096]u8 = undefined;
            const length = smith.sliceWithHash(&storage, 0xaeb60d);
            var interner = try InternPool.Global.init(std.testing.allocator);
            defer interner.deinit(std.testing.allocator);
            var artifact = read(std.testing.allocator, storage[0..length], &interner) catch return;
            defer artifact.deinit(std.testing.allocator);
            try std.testing.expect(try artifact.verify(std.testing.allocator, &interner));
        }
    }.testOne, .{});
}

test "typed root inspector requires checked contract and emits nothing on missing authority" {
    const gpa = std.testing.allocator;
    var interner = try InternPool.Global.init(gpa);
    defer interner.deinit(gpa);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try std.testing.expectError(error.UnvalidatedPlan, @import("../entry/TypedInspect.zig").write(gpa, &output.writer, .{
        .graph = &Graph.empty,
        .artifacts = &.{},
        .interner = &interner,
        .types = &Types.empty,
        .dispatch = &.{},
        .plan = &.{},
    }));
    try std.testing.expectEqualStrings("", output.written());
}

test "entry roots codec retains nonempty ordinary scheme graph and validates its private scope" {
    const gpa = std.testing.allocator;
    var interner = try InternPool.Global.init(gpa);
    defer interner.deinit(gpa);
    var artifact: Artifact = .{ .present = true };
    defer artifact.deinit(gpa);
    var terms: std.MultiArrayList(Interface.Term) = .empty;
    defer terms.deinit(gpa);
    try terms.append(gpa, .{ .tag = .unit, .lhs = 0, .rhs = 0 });
    artifact.types.terms = terms.toOwnedSlice();
    artifact.types.schemes = try gpa.dupe(Interface.Scheme, &.{.{ .body = @fromBackingInt(0), .quantified_start = 0, .quantified_count = 0, .total = true }});
    var rows: std.MultiArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    try rows.append(gpa, .{ .decl = @fromBackingInt(7), .scheme = @fromBackingInt(0) });
    artifact.roots = rows.toOwnedSlice();
    try std.testing.expect(try artifact.verify(gpa, &interner));
    const bytes = try write(gpa, &artifact, &interner);
    defer gpa.free(bytes);
    var decoded = try read(gpa, bytes, &interner);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualDeep(artifact.roots.get(0), decoded.roots.get(0));
    try std.testing.expectEqualDeep(artifact.types.schemes, decoded.types.schemes);
    const again = try write(gpa, &decoded, &interner);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
    const broken = try gpa.dupe(u8, bytes);
    defer gpa.free(broken);
    put(broken, header + 4, 1);
    try std.testing.expectError(error.BadRoots, read(gpa, broken, &interner));
    artifact.types.terms.items(.tag)[0] = .@"var";
    try std.testing.expect(!try artifact.verify(gpa, &interner));
}

test "typed root inspector emits nothing when checked nominal metadata is unavailable" {
    const gpa = std.testing.allocator;
    var interner = try InternPool.Global.init(gpa);
    defer interner.deinit(gpa);
    const Plan = @import("../entry/Plan.zig");
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    plan.selected = try plan.appendKind(gpa, .{
        .program = @fromBackingInt(1),
        .module = @fromBackingInt(0),
        .interface_type = @fromBackingInt(0),
        .arity = 0,
        .realm = .node,
        .layer = 0,
        .runtime = .{ .module = @fromBackingInt(0), .decl = 0, .scheme = .none },
        .constructors = .{},
        .launches = .{},
        .roles = .{},
    });
    plan.finish();
    const tables = [_]@import("Dispatch.zig"){.{ .decl_heads = &.{@fromBackingInt(1)} }};
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try std.testing.expectError(error.MissingEntryRoots, @import("../entry/TypedInspect.zig").write(gpa, &output.writer, .{
        .graph = &Graph.empty,
        .artifacts = &.{},
        .interner = &interner,
        .types = &Types.empty,
        .dispatch = &tables,
        .plan = &plan,
    }));
    try std.testing.expectEqualStrings("", output.written());
}
