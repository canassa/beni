//! Owned original-source rows, not a solved realm certificate.
const std = @import("std");
const Source = @import("../check/RealmSource.zig");
const InternPool = @import("../InternPool.zig");
const Allocator = std.mem.Allocator;
const fields = .{ "declarations", "scopes", "nodes", "refs", "locals" };
const magic = "BENIRLM\x00";
const header = 40;
pub const ReadError = Allocator.Error || error{ BadSource, UnknownSymbol };
fn words(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"struct" => blk: {
            var n: usize = 0;
            inline for (@typeInfo(T).@"struct".field_types) |F| n += words(F);
            break :blk n;
        },
        .int, .@"enum", .bool => 1,
        else => @compileError("source schema contains a non-integer field"),
    };
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn get(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn padding(n: usize) usize {
    return (4 - n % 4) % 4;
}
fn encode(bytes: []u8, at: *usize, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => inline for (@typeInfo(T).@"struct".field_names) |name| encode(bytes, at, @field(value, name)),
        else => {
            put(bytes, at.*, switch (@typeInfo(T)) {
                .@"enum" => @intCast(@backingInt(value)),
                .bool => @intFromBool(value),
                .int => @intCast(value),
                else => unreachable,
            });
            at.* += 4;
        },
    }
}
fn decode(comptime T: type, bytes: []const u8, at: *usize) ReadError!T {
    if (@typeInfo(T) == .@"struct") {
        var result: T = undefined;
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, F| @field(result, name) = try decode(F, bytes, at);
        return result;
    }
    if (at.* > bytes.len or bytes.len - at.* < 4) return error.BadSource;
    const v = get(bytes, at.*);
    at.* += 4;
    return switch (@typeInfo(T)) {
        .int => std.math.cast(T, v) orelse error.BadSource,
        .bool => switch (v) {
            0 => false,
            1 => true,
            else => error.BadSource,
        },
        .@"enum" => if (@typeInfo(T).@"enum".mode == .exhaustive) (std.enums.fromInt(T, v) orelse error.BadSource) else @fromBackingInt(v),
        else => unreachable,
    };
}
/// module_refs parallels refs and contains ordinary Writer.moduleRef indices.
pub fn write(gpa: Allocator, a: *const Source.Artifact, interner: *const InternPool.Global, module_refs: []const u32) Allocator.Error![]u8 {
    if (!a.present) return gpa.alloc(u8, 0);
    std.debug.assert(module_refs.len == a.refs.len);
    var size: usize = header;
    inline for (fields) |f| {
        const rows = @field(a, f);
        size += rows.len * words(@TypeOf(rows.get(0))) * 4;
    }
    size += a.extra.len * 4;
    for (a.symbols) |s| {
        const n = interner.slice(s).len;
        size += 4 + n + padding(n);
    }
    const out = try gpa.alloc(u8, size);
    @memset(out, 0);
    @memcpy(out[0..8], magic);
    put(out, 8, Source.schema_version);
    inline for (fields, 0..) |f, i| put(out, 12 + i * 4, @intCast(@field(a, f).len));
    put(out, 32, @intCast(a.extra.len));
    put(out, 36, @intCast(a.symbols.len));
    var at: usize = header;
    inline for (fields) |f| {
        const rows = @field(a, f);
        for (0..rows.len) |i| {
            var row = rows.get(i);
            if (comptime std.mem.eql(u8, f, "refs")) row.module = @fromBackingInt(module_refs[i]);
            encode(out, &at, row);
        }
    }
    for (a.extra) |v| encode(out, &at, v);
    for (a.symbols) |s| {
        const text = interner.slice(s);
        put(out, at, @intCast(text.len));
        at += 4;
        @memcpy(out[at..][0..text.len], text);
        at += text.len + padding(text.len);
    }
    std.debug.assert(at == out.len);
    return out;
}
pub fn read(gpa: Allocator, bytes: []const u8, pool: *const InternPool.Global) ReadError!Source.Artifact {
    return readImpl(gpa, bytes, pool, false);
}
pub fn readGrowing(gpa: Allocator, bytes: []const u8, pool: *InternPool.Global) ReadError!Source.Artifact {
    return readImpl(gpa, bytes, pool, true);
}
fn readImpl(gpa: Allocator, bytes: []const u8, pool: anytype, comptime grow: bool) ReadError!Source.Artifact {
    if (bytes.len == 0) return .empty;
    if (bytes.len < header or !std.mem.eql(u8, bytes[0..8], magic) or get(bytes, 8) != Source.schema_version) return error.BadSource;
    var a: Source.Artifact = .{ .present = true };
    errdefer a.deinit(gpa);
    var minimum: u64 = header;
    inline for (fields, 0..) |f, i| minimum += @as(u64, get(bytes, 12 + i * 4)) * words(@TypeOf(@field(a, f).get(0))) * 4;
    minimum += @as(u64, get(bytes, 32)) * 4 + @as(u64, get(bytes, 36)) * 4;
    if (minimum > bytes.len) return error.BadSource;
    var at: usize = header;
    inline for (fields, 0..) |f, i| {
        const Row = @TypeOf(@field(a, f).get(0));
        var rows: std.MultiArrayList(Row) = .empty;
        defer rows.deinit(gpa);
        for (0..get(bytes, 12 + i * 4)) |_| try rows.append(gpa, try decode(Row, bytes, &at));
        @field(a, f) = rows.toOwnedSlice();
    }
    a.extra = try gpa.alloc(u32, get(bytes, 32));
    for (a.extra) |*v| v.* = try decode(u32, bytes, &at);
    a.symbols = try gpa.alloc(InternPool.Symbol, get(bytes, 36));
    for (a.symbols) |*s| {
        const n = try decode(u32, bytes, &at);
        if (at > bytes.len or n > bytes.len - at) return error.BadSource;
        const text = bytes[at..][0..n];
        at += n;
        const pad = padding(n);
        if (pad > bytes.len - at) return error.BadSource;
        for (bytes[at..][0..pad]) |b| if (b != 0) return error.BadSource;
        at += pad;
        s.* = if (grow) try pool.getOrPut(gpa, text) else pool.find(text) orelse return error.UnknownSymbol;
    }
    if (at != bytes.len or !a.verify()) return error.BadSource;
    for (0..a.refs.len) |i| {
        const r = a.refs.get(i);
        if (r.kind != .external and r.module.int() != Source.none) return error.BadSource;
        if (r.kind == .field and r.value >= a.symbols.len) return error.BadSource;
        if (r.kind == .top and r.value >= a.declarations.len) return error.BadSource;
    }
    return a;
}

test "realm source codec preserves absent versus present empty and rejects every truncation" {
    const gpa = std.testing.allocator;
    var pool = try InternPool.Global.init(gpa);
    defer pool.deinit(gpa);
    const absent = try write(gpa, &.empty, &pool, &.{});
    defer gpa.free(absent);
    var a = try read(gpa, absent, &pool);
    defer a.deinit(gpa);
    try std.testing.expect(!a.present);
    const bytes = try write(gpa, &.{ .present = true }, &pool, &.{});
    defer gpa.free(bytes);
    var present = try read(gpa, bytes, &pool);
    defer present.deinit(gpa);
    try std.testing.expect(present.present);
    for (1..bytes.len) |n| try std.testing.expectError(error.BadSource, read(gpa, bytes[0..n], &pool));
}
test "realm source codec rewrites module references and reinterns source symbols" {
    const gpa = std.testing.allocator;
    var pool = try InternPool.Global.init(gpa);
    defer pool.deinit(gpa);
    var target = try InternPool.Global.init(gpa);
    defer target.deinit(gpa);
    const symbol = try pool.getOrPut(gpa, "uniqueRealmSourceSymbol");
    var rows: std.MultiArrayList(Source.Ref) = .empty;
    defer rows.deinit(gpa);
    try rows.append(gpa, .{ .kind = .external, .module = @fromBackingInt(45), .value = 3 });
    var source: Source.Artifact = .{ .present = true, .refs = rows.toOwnedSlice() };
    defer source.deinit(gpa);
    source.symbols = try gpa.dupe(InternPool.Symbol, &.{symbol});
    const bytes = try write(gpa, &source, &pool, &.{7});
    defer gpa.free(bytes);
    try std.testing.expectError(error.UnknownSymbol, read(gpa, bytes, &target));
    var restored = try readGrowing(gpa, bytes, &target);
    defer restored.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 7), restored.refs.get(0).module.int());
    try std.testing.expectEqual(@as(u32, 3), restored.refs.get(0).value);
    try std.testing.expectEqualStrings("uniqueRealmSourceSymbol", target.slice(restored.symbols[0]));
    const damaged = try gpa.dupe(u8, bytes);
    defer gpa.free(damaged);
    put(damaged, header, 99); // Invalid exhaustive Ref.kind.
    try std.testing.expectError(error.BadSource, read(gpa, damaged, &pool));
    @memcpy(damaged, bytes);
    damaged[damaged.len - 1] = 1; // Original symbol has nonempty zero padding.
    try std.testing.expectError(error.BadSource, read(gpa, damaged, &pool));
}
test "fuzz realm source codec never publishes malformed structural evidence" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var storage: [4096]u8 = undefined;
            const n = smith.sliceWithHash(&storage, 0x7ea1);
            var pool = try InternPool.Global.init(std.testing.allocator);
            defer pool.deinit(std.testing.allocator);
            if (readGrowing(std.testing.allocator, storage[0..n], &pool)) |value| {
                var artifact = value;
                defer artifact.deinit(std.testing.allocator);
                try std.testing.expect(artifact.verify());
            } else |_| {}
        }
    }.one, .{});
}
