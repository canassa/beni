//! The type-key artifact as BYTES — the cache entry's `type_keys` section
//! (checker-v2.md §36; `backend.md` §3, *Amended 2026-10-20*).
//!
//! ```
//! header    magic "BENITKY\x00" (8)   format_version: u32   column_count: u32
//! table     column_count × { offset: u32, len: u32 }        offsets from byte 0
//! columns   in table order, each 4-byte aligned, gaps zero-filled
//! ```
//!
//! Columns: `nodes` (16 bytes a node: its kind, three zero bytes, a
//! `type_refs` index for a named node or a record's first label in `labels`,
//! and its range of `args`), `args`, `locals`, `decls` and `wild` (4 bytes a
//! key),
//! `labels` (a string offset each), `insts` (12
//! bytes: the instruction, its key, a lambda's result key), `type_refs` (12
//! bytes: package, declaring module's name, type's name) and `strings`.
//!
//! Version 2 adds `records` (12 bytes: label start, count, open-row bit)
//! and `record_labels` (string offsets), independent of closed type keys.
//!
//! **Nothing session-assigned reaches the bytes**, `dispatch_bytes.zig`'s
//! rule: a `TypeId` becomes its `(package, module, name)` row and a field's
//! `Symbol` its text. Loading is two steps for the same reason as there:
//! `read` re-interns, serially or through `find`; `resolve` turns the rows
//! into this session's `TypeId`s on the DAG, where `Types` exists.
//!
//! **A bad section is a MISS**: every range, child and key is bounded, and
//! every child precedes its owner, so a walker that trusts the artifact
//! ends.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");
const Graph = @import("../resolve/Graph.zig");
const Types = @import("../check/Types.zig");
const TypeKeys = @import("../check/TypeKeys.zig");

const Symbol = InternPool.Symbol;
const TypeKey = TypeKeys.TypeKey;

pub const magic = "BENITKY\x00";
pub const format_version: u32 = 2;

const Column = enum(u32) {
    nodes,
    args,
    labels,
    locals,
    decls,
    insts,
    wild,
    type_refs,
    records,
    record_labels,
    strings,

    const count: u32 = @typeInfo(Column).@"enum".field_names.len;

    fn width(c: Column) u32 {
        return switch (c) {
            .nodes => 16,
            .args, .labels, .locals, .decls, .wild, .record_labels => 4,
            .insts, .type_refs, .records => 12,
            .strings => 1,
        };
    }
};

const header_bytes: u32 = 16;
const body_start: u32 = header_bytes + Column.count * 8;
const no_ref: u32 = std.math.maxInt(u32);

pub const ReadError = error{ BadSection, UnknownSymbol } || Allocator.Error;

pub const TypeRef = struct { package: SourceStore.Package, module: Symbol, name: Symbol };

/// An artifact between `read` and `resolve`: a named node's value is a
/// `type_refs` index.
pub const Loaded = struct {
    artifact: TypeKeys.Artifact = .empty,
    type_refs: []TypeRef = &.{},

    pub const empty: Loaded = .{};

    pub fn deinit(l: *Loaded, gpa: Allocator) void {
        l.artifact.deinit(gpa);
        gpa.free(l.type_refs);
        l.* = .empty;
    }
};

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

pub fn write(gpa: Allocator, a: *const TypeKeys.Artifact, types: *const Types, interner: *const InternPool.Global) Allocator.Error![]u8 {
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(gpa);
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    defer seen.deinit(gpa);
    var refs: std.ArrayList([3]u32) = .empty;
    defer refs.deinit(gpa);
    var ref_index: std.AutoHashMapUnmanaged([3]u32, u32) = .empty;
    defer ref_index.deinit(gpa);
    const S = struct {
        fn string(g: Allocator, out: *std.ArrayList(u8), map: *std.StringHashMapUnmanaged(u32), text: []const u8) Allocator.Error!u32 {
            const gop = try map.getOrPut(g, text);
            if (gop.found_existing) return gop.value_ptr.*;
            const at: u32 = @intCast(out.items.len);
            gop.value_ptr.* = at;
            var len: [4]u8 = undefined;
            std.mem.writeInt(u32, &len, @intCast(text.len), .little);
            try out.appendSlice(g, &len);
            try out.appendSlice(g, text);
            try out.appendNTimes(g, 0, pad4(text.len));
            return at;
        }
    };

    const nodes = try gpa.alloc(u8, a.nodes.len * 16);
    defer gpa.free(nodes);
    @memset(nodes, 0);
    for (a.nodes, 0..) |n, i| {
        const row = nodes[i * 16 ..][0..16];
        row[0] = @backingInt(n.kind);
        const value: u32 = switch (n.kind) {
            .named => blk: {
                const named = types.named(@fromBackingInt(@intCast(n.value))) orelse break :blk no_ref;
                const key: [3]u32 = .{
                    @backingInt(named.package),
                    try S.string(gpa, &strings, &seen, interner.slice(named.module)),
                    try S.string(gpa, &strings, &seen, interner.slice(named.name)),
                };
                const gop = try ref_index.getOrPut(gpa, key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(refs.items.len);
                    try refs.append(gpa, key);
                }
                break :blk gop.value_ptr.*;
            },
            .record => n.value,
            else => 0,
        };
        std.mem.writeInt(u32, row[4..8], value, .little);
        std.mem.writeInt(u32, row[8..12], n.args.start, .little);
        std.mem.writeInt(u32, row[12..16], n.args.len, .little);
    }
    const args = try keyColumn(gpa, a.args);
    defer gpa.free(args);
    const labels = try gpa.alloc(u8, a.labels.len * 4);
    defer gpa.free(labels);
    for (a.labels, 0..) |l, i| std.mem.writeInt(u32, labels[i * 4 ..][0..4], try S.string(gpa, &strings, &seen, interner.slice(l)), .little);
    const locals = try keyColumn(gpa, a.locals);
    defer gpa.free(locals);
    const decls = try keyColumn(gpa, a.decls);
    defer gpa.free(decls);
    const wild = try keyColumn(gpa, a.wild);
    defer gpa.free(wild);
    const insts = try gpa.alloc(u8, a.insts.len * 12);
    defer gpa.free(insts);
    for (a.insts, 0..) |k, i| {
        const row = insts[i * 12 ..][0..12];
        std.mem.writeInt(u32, row[0..4], @backingInt(k.inst), .little);
        std.mem.writeInt(u32, row[4..8], k.key.int(), .little);
        std.mem.writeInt(u32, row[8..12], k.result.int(), .little);
    }
    const type_refs = try gpa.alloc(u8, refs.items.len * 12);
    defer gpa.free(type_refs);
    @memset(type_refs, 0);
    for (refs.items, 0..) |r, i| {
        const row = type_refs[i * 12 ..][0..12];
        row[0] = @intCast(r[0]);
        std.mem.writeInt(u32, row[4..8], r[1], .little);
        std.mem.writeInt(u32, row[8..12], r[2], .little);
    }

    const record_labels = try gpa.alloc(u8, a.record_labels.len * 4);
    defer gpa.free(record_labels);
    for (a.record_labels, 0..) |l, i| std.mem.writeInt(u32, record_labels[i * 4 ..][0..4], try S.string(gpa, &strings, &seen, interner.slice(l)), .little);
    const records = try gpa.alloc(u8, a.records.len * 12);
    defer gpa.free(records);
    for (a.records, 0..) |r, i| {
        const row = records[i * 12 ..][0..12];
        std.mem.writeInt(u32, row[0..4], r.fields.start, .little);
        std.mem.writeInt(u32, row[4..8], r.fields.len, .little);
        std.mem.writeInt(u32, row[8..12], @intFromBool(r.open), .little);
    }
    const columns = [Column.count][]const u8{ nodes, args, labels, locals, decls, insts, wild, type_refs, records, record_labels, strings.items };

    const lengths = [Column.count]u32{
        @intCast(a.nodes.len),
        @intCast(a.args.len),
        @intCast(a.labels.len),
        @intCast(a.locals.len),
        @intCast(a.decls.len),
        @intCast(a.insts.len),
        @intCast(a.wild.len),
        @intCast(refs.items.len),
        @intCast(a.records.len),
        @intCast(a.record_labels.len),
        @intCast(strings.items.len),
    };
    var offsets: [Column.count]u32 = undefined;
    var at: u32 = body_start;
    for (0..Column.count) |i| {
        offsets[i] = at;
        at += @intCast(columns[i].len);
        at += @intCast(pad4(at));
    }
    const out = try gpa.alloc(u8, at);
    errdefer gpa.free(out);
    @memset(out, 0);
    @memcpy(out[0..8], magic);
    std.mem.writeInt(u32, out[8..12], format_version, .little);
    std.mem.writeInt(u32, out[12..16], Column.count, .little);
    for (0..Column.count) |i| {
        const row = out[header_bytes + i * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], offsets[i], .little);
        std.mem.writeInt(u32, row[4..8], lengths[i], .little);
        @memcpy(out[offsets[i]..][0..columns[i].len], columns[i]);
    }
    return out;
}

fn keyColumn(gpa: Allocator, keys: []const TypeKey) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, keys.len * 4);
    for (keys, 0..) |k, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], k.int(), .little);
    return out;
}

fn pad4(n: usize) usize {
    return (4 - (n % 4)) % 4;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// Re-interned through the non-mutating `find`: a string the session never
/// interned is `UnknownSymbol`, which the cache treats as a miss.
pub fn read(gpa: Allocator, bytes: []const u8, interner: *const InternPool.Global) ReadError!Loaded {
    var in: Interning = .{ .find = interner };
    return decode(gpa, bytes, &in);
}

/// `read` through `getOrPut`, for the serial cross-process load.
pub fn readGrowing(gpa: Allocator, bytes: []const u8, interner: *InternPool.Global) ReadError!Loaded {
    var in: Interning = .{ .get_or_put = .{ .pool = interner, .gpa = gpa } };
    return decode(gpa, bytes, &in);
}

const Interning = union(enum) {
    find: *const InternPool.Global,
    get_or_put: struct { pool: *InternPool.Global, gpa: Allocator },

    fn symbol(i: *Interning, text: []const u8) ReadError!Symbol {
        return switch (i.*) {
            .find => |pool| pool.find(text) orelse error.UnknownSymbol,
            .get_or_put => |g| g.pool.getOrPut(g.gpa, text),
        };
    }
};

fn decode(gpa: Allocator, bytes: []const u8, in: *Interning) ReadError!Loaded {
    if (bytes.len < body_start) return error.BadSection;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.BadSection;
    if (std.mem.readInt(u32, bytes[8..12], .little) != format_version) return error.BadSection;
    if (std.mem.readInt(u32, bytes[12..16], .little) != Column.count) return error.BadSection;
    var offsets: [Column.count]u32 = undefined;
    var lengths: [Column.count]u32 = undefined;
    for (0..Column.count) |i| {
        const c: Column = @fromBackingInt(@intCast(i));
        const row = bytes[header_bytes + i * 8 ..][0..8];
        const offset = std.mem.readInt(u32, row[0..4], .little);
        const len = std.mem.readInt(u32, row[4..8], .little);
        if (offset % 4 != 0 or offset < body_start) return error.BadSection;
        if (@as(u64, offset) + @as(u64, len) * c.width() > bytes.len) return error.BadSection;
        offsets[i] = offset;
        lengths[i] = len;
    }
    const col = struct {
        fn at(b: []const u8, o: [Column.count]u32, c: Column) []const u8 {
            return b[o[@backingInt(c)]..];
        }
    }.at;
    const blob = col(bytes, offsets, .strings)[0..lengths[@backingInt(Column.strings)]];

    var out: Loaded = .empty;
    errdefer out.deinit(gpa);
    {
        const in_bytes = col(bytes, offsets, .type_refs);
        const refs = try gpa.alloc(TypeRef, lengths[@backingInt(Column.type_refs)]);
        out.type_refs = refs;
        for (refs, 0..) |*r, i| {
            const row = in_bytes[i * 12 ..][0..12];
            if (row[1] != 0 or row[2] != 0 or row[3] != 0) return error.BadSection;
            r.* = .{
                .package = std.enums.fromInt(SourceStore.Package, row[0]) orelse return error.BadSection,
                .module = try symbolAt(blob, std.mem.readInt(u32, row[4..8], .little), in) orelse return error.BadSection,
                .name = try symbolAt(blob, std.mem.readInt(u32, row[8..12], .little), in) orelse return error.BadSection,
            };
        }
    }
    {
        const in_bytes = col(bytes, offsets, .nodes);
        const nodes = try gpa.alloc(TypeKeys.KeyNode, lengths[@backingInt(Column.nodes)]);
        out.artifact.nodes = nodes;
        for (nodes, 0..) |*n, i| {
            const row = in_bytes[i * 16 ..][0..16];
            const kind = std.enums.fromInt(TypeKeys.KeyNode.Kind, row[0]) orelse return error.BadSection;
            if (row[1] != 0 or row[2] != 0 or row[3] != 0) return error.BadSection;
            const raw = std.mem.readInt(u32, row[4..8], .little);
            n.* = .{
                .kind = kind,
                .value = switch (kind) {
                    .record => raw,
                    .named => if (raw != no_ref and raw >= out.type_refs.len) return error.BadSection else raw,
                    else => if (raw != 0) return error.BadSection else 0,
                },
                .args = .{ .start = std.mem.readInt(u32, row[8..12], .little), .len = std.mem.readInt(u32, row[12..16], .little) },
            };
        }
    }
    out.artifact.args = try readKeys(gpa, col(bytes, offsets, .args), lengths[@backingInt(Column.args)]);
    {
        const in_bytes = col(bytes, offsets, .labels);
        const labels = try gpa.alloc(Symbol, lengths[@backingInt(Column.labels)]);
        out.artifact.labels = labels;
        for (labels, 0..) |*l, i| l.* = try symbolAt(blob, std.mem.readInt(u32, in_bytes[i * 4 ..][0..4], .little), in) orelse return error.BadSection;
    }
    out.artifact.locals = try readKeys(gpa, col(bytes, offsets, .locals), lengths[@backingInt(Column.locals)]);
    out.artifact.decls = try readKeys(gpa, col(bytes, offsets, .decls), lengths[@backingInt(Column.decls)]);
    out.artifact.wild = try readKeys(gpa, col(bytes, offsets, .wild), lengths[@backingInt(Column.wild)]);
    {
        const in_bytes = col(bytes, offsets, .insts);
        const rows = try gpa.alloc(TypeKeys.InstKey, lengths[@backingInt(Column.insts)]);
        out.artifact.insts = rows;
        for (rows, 0..) |*k, i| {
            const row = in_bytes[i * 12 ..][0..12];
            k.* = .{
                .inst = @fromBackingInt(@intCast(std.mem.readInt(u32, row[0..4], .little))),
                .key = @fromBackingInt(std.mem.readInt(u32, row[4..8], .little)),
                .result = @fromBackingInt(std.mem.readInt(u32, row[8..12], .little)),
            };
        }
    }
    {
        const label_bytes = col(bytes, offsets, .record_labels);
        const labels = try gpa.alloc(Symbol, lengths[@backingInt(Column.record_labels)]);
        out.artifact.record_labels = labels;
        for (labels, 0..) |*l, i| l.* = try symbolAt(blob, std.mem.readInt(u32, label_bytes[i * 4 ..][0..4], .little), in) orelse return error.BadSection;
        const record_bytes = col(bytes, offsets, .records);
        const records = try gpa.alloc(TypeKeys.Record, lengths[@backingInt(Column.records)]);
        out.artifact.records = records;
        for (records, 0..) |*r, i| {
            const row = record_bytes[i * 12 ..][0..12];
            const open = std.mem.readInt(u32, row[8..12], .little);
            if (open > 1) return error.BadSection;
            r.* = .{ .fields = .{ .start = std.mem.readInt(u32, row[0..4], .little), .len = std.mem.readInt(u32, row[4..8], .little) }, .open = open == 1 };
        }
    }
    if (!verify(&out.artifact)) return error.BadSection;

    return out;
}

fn readKeys(gpa: Allocator, in_bytes: []const u8, len: u32) Allocator.Error![]TypeKey {
    const keys = try gpa.alloc(TypeKey, len);
    for (keys, 0..) |*k, i| k.* = @fromBackingInt(std.mem.readInt(u32, in_bytes[i * 4 ..][0..4], .little));
    return keys;
}

fn symbolAt(blob: []const u8, at: u32, in: *Interning) ReadError!?Symbol {
    if (@as(u64, at) + 4 > blob.len) return null;
    const len = std.mem.readInt(u32, blob[at..][0..4], .little);
    if (@as(u64, at) + 4 + @as(u64, len) > blob.len) return null;
    return try in.symbol(blob[at + 4 ..][0..len]);
}

/// Every range fits, every child is an earlier node and never `wild`, a
/// record's labels fit `labels`, `⊤` has no child, every key named is a node or `wild`,
/// and the instruction rows and the wild set ascend.
pub fn verify(a: *const TypeKeys.Artifact) bool {
    for (a.records) |r| if (@as(u64, r.fields.start) + r.fields.len > a.record_labels.len) return false;
    for (a.nodes, 0..) |n, i| {
        if (@as(u64, n.args.start) + n.args.len > a.args.len) return false;
        for (a.args[n.args.start..][0..n.args.len]) |child| {
            if (child.int() >= i) return false;
        }
        switch (n.kind) {
            .record => if (@as(u64, n.value) + n.args.len > a.labels.len) return false,
            .unit => if (n.args.len != 0) return false,
            .function => if (n.args.len == 0) return false,
            else => {},
        }
    }
    for (a.locals) |k| if (!keyOk(a, k)) return false;
    for (a.decls) |k| if (!keyOk(a, k)) return false;
    for (a.insts, 0..) |k, i| {
        if (i != 0 and a.insts[i - 1].inst.int() >= k.inst.int()) return false;
        if (!keyOk(a, k.key) or !keyOk(a, k.result)) return false;
    }
    for (a.wild, 0..) |k, i| {
        if (k == .wild or k.int() >= a.nodes.len) return false;
        if (i != 0 and a.wild[i - 1].int() >= k.int()) return false;
    }
    return true;
}

fn keyOk(a: *const TypeKeys.Artifact, k: TypeKey) bool {
    return k == .wild or k.int() < a.nodes.len;
}

// ---------------------------------------------------------------------------
// Resolving
// ---------------------------------------------------------------------------

/// Every named node's `type_refs` index becomes this session's `TypeId`, in
/// place; one that names no type of this build is `.none`.
pub fn resolve(l: *Loaded, graph: *const Graph, types: *const Types) void {
    for (@constCast(l.artifact.nodes)) |*n| {
        if (n.kind != .named) continue;
        n.value = if (n.value >= l.type_refs.len) Types.TypeId.none.int() else blk: {
            const r = l.type_refs[n.value];
            break :blk types.find(graph, r.package, r.module, r.name).int();
        };
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an empty artifact round-trips, and a child that is not earlier is a miss" {
    var pool = try InternPool.Global.init(testing.allocator);
    defer pool.deinit(testing.allocator);
    const empty: TypeKeys.Artifact = .empty;
    const types: Types = .empty;
    const bytes = try write(testing.allocator, &empty, &types, &pool);
    defer testing.allocator.free(bytes);
    var loaded = try read(testing.allocator, bytes, &pool);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.artifact.nodes.len);

    const labels = [_]Symbol{try pool.getOrPut(testing.allocator, "cups")};
    const records = [_]TypeKeys.Record{.{ .fields = .{ .len = 1 }, .open = true }};
    const rows: TypeKeys.Artifact = .{ .records = &records, .record_labels = &labels };
    const row_bytes = try write(testing.allocator, &rows, &types, &pool);
    defer testing.allocator.free(row_bytes);
    var row_loaded = try read(testing.allocator, row_bytes, &pool);
    defer row_loaded.deinit(testing.allocator);
    try testing.expectEqualDeep(@as([]const TypeKeys.Record, &records), row_loaded.artifact.records);
    try testing.expectEqualSlices(Symbol, &labels, row_loaded.artifact.record_labels);
    const bad_rows = [_]TypeKeys.Record{.{ .fields = .{ .len = 2 }, .open = false }};
    try testing.expect(!verify(&.{ .records = &bad_rows, .record_labels = &labels }));

    const nodes = [_]TypeKeys.KeyNode{ .{ .kind = .unit }, .{ .kind = .tuple, .args = .{ .start = 0, .len = 2 } } };
    const args = [_]TypeKey{ @fromBackingInt(0), @fromBackingInt(1) };
    const bad: TypeKeys.Artifact = .{ .nodes = &nodes, .args = &args };
    try testing.expect(!verify(&bad));
    const good_args = [_]TypeKey{ @fromBackingInt(0), @fromBackingInt(0) };
    const good: TypeKeys.Artifact = .{ .nodes = &nodes, .args = &good_args, .wild = &.{@fromBackingInt(1)} };
    try testing.expect(verify(&good));
    const twice: TypeKeys.Artifact = .{ .nodes = &nodes, .args = &good_args, .wild = &.{ @fromBackingInt(1), @fromBackingInt(1) } };
    try testing.expect(!verify(&twice));
}
