//! Private, owned nominal layouts. Stable refs and ordinary Interface bytes only.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Layouts = @import("../check/NominalLayouts.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
const magic = "BENINOM\x00";
const header: usize = 32;
const owner_width: usize = 24;
const ctor_width: usize = 20;
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn get(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
pub fn write(gpa: Allocator, a: *const Layouts.Artifact, interner: *const InternPool.Global) Allocator.Error![]u8 {
    if (!a.present) return gpa.alloc(u8, 0);
    const record = if (a.owners.len == 0) try gpa.alloc(u8, 0) else try iface_bytes.write(gpa, &a.types, interner);
    defer gpa.free(record);
    const owners_at = header;
    const ctors_at = owners_at + owner_width * a.owners.len;
    const args_at = ctors_at + ctor_width * a.constructors.len;
    const record_at = args_at + 4 * a.arguments.len;
    const out = try gpa.alloc(u8, record_at + record.len);
    @memset(out, 0);
    @memcpy(out[0..8], magic);
    put(out, 8, Layouts.schema_version);
    put(out, 12, @intCast(a.owners.len));
    put(out, 16, @intCast(a.constructors.len));
    put(out, 20, @intCast(a.arguments.len));
    put(out, 24, @intCast(record.len));
    for (0..a.owners.len) |i| {
        const row = a.owners.get(i);
        const at = owners_at + i * owner_width;
        put(out, at, row.type_ref.int());
        put(out, at + 4, row.decl.int());
        put(out, at + 8, @backingInt(row.scheme));
        put(out, at + 12, row.ctor_start);
        put(out, at + 16, row.ctor_len);
        std.mem.writeInt(u16, out[at + 20 ..][0..2], row.arity, .little);
        out[at + 22] = @backingInt(row.kind);
    }
    for (0..a.constructors.len) |i| {
        const row = a.constructors.get(i);
        const at = ctors_at + i * ctor_width;
        put(out, at, @backingInt(row.name));
        put(out, at + 4, row.owner);
        put(out, at + 8, row.ordinal);
        put(out, at + 12, row.arg_start);
        put(out, at + 16, row.arg_len);
    }
    for (a.arguments, 0..) |arg, i| put(out, args_at + i * 4, arg.int());
    @memcpy(out[record_at..], record);
    return out;
}
pub const ReadError = iface_bytes.ReadError || error{BadLayouts};
pub fn read(gpa: Allocator, bytes: []const u8, interner: *const InternPool.Global) ReadError!Layouts.Artifact {
    return decode(gpa, bytes, interner, false);
}
pub fn readGrowing(gpa: Allocator, bytes: []const u8, interner: *InternPool.Global) ReadError!Layouts.Artifact {
    return decode(gpa, bytes, interner, true);
}
fn decode(gpa: Allocator, bytes: []const u8, interner: anytype, comptime growing: bool) ReadError!Layouts.Artifact {
    if (bytes.len == 0) return .empty;
    if (bytes.len < header or !std.mem.eql(u8, bytes[0..8], magic) or get(bytes, 8) != Layouts.schema_version or get(bytes, 28) != 0) return error.BadLayouts;
    const owners = get(bytes, 12);
    const ctors = get(bytes, 16);
    const args = get(bytes, 20);
    const record = get(bytes, 24);
    const ctors_at = @as(u64, header) + @as(u64, owners) * owner_width;
    const args_at = ctors_at + @as(u64, ctors) * ctor_width;
    const record_at = args_at + @as(u64, args) * 4;
    if (record_at + record != bytes.len or (owners == 0) != (record == 0) or (owners == 0 and (ctors != 0 or args != 0))) return error.BadLayouts;
    var out: Layouts.Artifact = .{ .present = true };
    errdefer out.deinit(gpa);
    var os: std.MultiArrayList(Layouts.Owner) = .empty;
    defer os.deinit(gpa);
    try os.ensureTotalCapacity(gpa, owners);
    for (0..owners) |i| {
        const at = header + i * owner_width;
        const kind = bytes[at + 22];
        if (kind > @backingInt(Layouts.Kind.schema_encoded) or bytes[at + 23] != 0) return error.BadLayouts;
        os.appendAssumeCapacity(.{ .type_ref = @fromBackingInt(get(bytes, at)), .decl = @fromBackingInt(get(bytes, at + 4)), .scheme = @fromBackingInt(get(bytes, at + 8)), .ctor_start = get(bytes, at + 12), .ctor_len = get(bytes, at + 16), .arity = std.mem.readInt(u16, bytes[at + 20 ..][0..2], .little), .kind = @fromBackingInt(@intCast(kind)) });
    }
    out.owners = os.toOwnedSlice();
    var cs: std.MultiArrayList(Layouts.Constructor) = .empty;
    defer cs.deinit(gpa);
    try cs.ensureTotalCapacity(gpa, ctors);
    for (0..ctors) |i| {
        const at: usize = @intCast(ctors_at + i * ctor_width);
        cs.appendAssumeCapacity(.{ .name = @fromBackingInt(get(bytes, at)), .owner = get(bytes, at + 4), .ordinal = get(bytes, at + 8), .arg_start = get(bytes, at + 12), .arg_len = get(bytes, at + 16) });
    }
    out.constructors = cs.toOwnedSlice();
    const arguments = try gpa.alloc(Interface.TermIndex, args);
    out.arguments = arguments;
    for (arguments, 0..) |*arg, i| arg.* = @fromBackingInt(get(bytes, @intCast(args_at + i * 4)));
    if (record != 0) out.types = if (growing) try iface_bytes.readGrowing(gpa, bytes[@intCast(record_at)..], interner) else try iface_bytes.read(gpa, bytes[@intCast(record_at)..], interner);
    if (!try out.verify(gpa, interner)) return error.BadLayouts;
    return out;
}

test "nominal layout bytes retain explicit empty and reject every truncated header" {
    const gpa = std.testing.allocator;
    var pool = try InternPool.Global.init(gpa);
    defer pool.deinit(gpa);
    const bytes = try write(gpa, &.{ .present = true }, &pool);
    defer gpa.free(bytes);
    var value = try read(gpa, bytes, &pool);
    defer value.deinit(gpa);
    try std.testing.expect(value.present and value.owners.len == 0);
    for (1..bytes.len) |length| try std.testing.expectError(error.BadLayouts, read(gpa, bytes[0..length], &pool));
    var absent = try read(gpa, &.{}, &pool);
    defer absent.deinit(gpa);
    try std.testing.expect(!absent.present);
}
test "nominal layout byte fuzz never publishes invalid private scope or rows" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) !void {
            var bytes: [4096]u8 = undefined;
            const len = smith.sliceWithHash(&bytes, 0xd86012);
            var pool = try InternPool.Global.init(std.testing.allocator);
            defer pool.deinit(std.testing.allocator);
            var artifact = read(std.testing.allocator, bytes[0..len], &pool) catch return;
            defer artifact.deinit(std.testing.allocator);
            try std.testing.expect(try artifact.verify(std.testing.allocator, &pool));
        }
    }.one, .{});
}

test "nominal layout codec retains an owned phantom scope and rejects owner argument and scope mutations" {
    const gpa = std.testing.allocator;
    var pool = try InternPool.Global.init(gpa);
    defer pool.deinit(gpa);
    const module = try pool.getOrPut(gpa, "Library");
    const name = try pool.getOrPut(gpa, "Box");
    const a_name = try pool.getOrPut(gpa, "a");
    var a: Layouts.Artifact = .{ .present = true };
    defer a.deinit(gpa);
    a.types.symbols = try gpa.dupe(InternPool.Symbol, &.{ module, name, a_name });
    a.types.type_refs = try gpa.dupe(Interface.TypeRef, &.{.{ .package = .app, .module = @fromBackingInt(0), .name = @fromBackingInt(1) }});
    var terms: std.MultiArrayList(Interface.Term) = .empty;
    defer terms.deinit(gpa);
    for ([_]Interface.Term{ .{ .tag = .@"var", .lhs = 0, .rhs = 0 }, .{ .tag = .@"var", .lhs = 1, .rhs = 0 }, .{ .tag = .app, .lhs = 0, .rhs = 0 }, .{ .tag = .tuple, .lhs = 3, .rhs = 0 } }) |term| try terms.append(gpa, term);
    a.types.terms = terms.toOwnedSlice();
    a.types.extra = try gpa.dupe(u32, &.{ 2, 0, 1, 2, 2, 0, 0, 2, 0, 0, 0, std.math.maxInt(u32), 0, 0 });
    a.types.schemes = try gpa.dupe(Interface.Scheme, &.{.{ .body = @fromBackingInt(3), .quantified_start = 6, .quantified_count = 2 }});
    var owners: std.MultiArrayList(Layouts.Owner) = .empty;
    defer owners.deinit(gpa);
    try owners.append(gpa, .{ .type_ref = @fromBackingInt(0), .decl = @fromBackingInt(7), .scheme = @fromBackingInt(0), .ctor_start = 0, .ctor_len = 1, .arity = 2, .kind = .adt });
    a.owners = owners.toOwnedSlice();
    var ctors: std.MultiArrayList(Layouts.Constructor) = .empty;
    defer ctors.deinit(gpa);
    try ctors.append(gpa, .{ .name = @fromBackingInt(1), .owner = 0, .ordinal = 0, .arg_start = 0, .arg_len = 1 });
    a.constructors = ctors.toOwnedSlice();
    a.arguments = try gpa.dupe(Interface.TermIndex, &.{@fromBackingInt(0)});
    try std.testing.expect(try a.verify(gpa, &pool));
    const bytes = try write(gpa, &a, &pool);
    defer gpa.free(bytes);
    var b = try read(gpa, bytes, &pool);
    defer b.deinit(gpa);
    const same = try write(gpa, &b, &pool);
    defer gpa.free(same);
    try std.testing.expectEqualSlices(u8, bytes, same);
    const broken = try gpa.dupe(u8, bytes);
    defer gpa.free(broken);
    for ([_]usize{ header, header + 8, header + 16, header + 20, header + owner_width + 4, header + owner_width + 8, header + owner_width + 12, header + owner_width + 16, header + owner_width + ctor_width }) |at| {
        broken[at] ^= 1;
        try std.testing.expectError(error.BadLayouts, read(gpa, broken, &pool));
        broken[at] ^= 1;
    }
    const extended = try gpa.alloc(u32, a.types.extra.len + 4);
    @memcpy(extended[0..a.types.extra.len], a.types.extra);
    @memcpy(extended[a.types.extra.len..], &[_]u32{ 0, std.math.maxInt(u32), 0, 0 });
    gpa.free(a.types.extra);
    a.types.extra = extended;
    @constCast(a.types.schemes)[0].quantified_count = 3;
    try std.testing.expect(!try a.verify(gpa, &pool)); // no extra temporary binder
    @constCast(a.types.schemes)[0].quantified_count = 2;
    @constCast(a.types.extra)[6] = 0xff; // invalid quantified kind, not a source fallback
    try std.testing.expect(!try a.verify(gpa, &pool));
}
