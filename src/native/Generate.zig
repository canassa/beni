//! Native type catalogue generation. This stage deliberately exposes no host
//! operation until its exact error adapter and lowering recipe are checked.
const std = @import("std");
const Idl = @import("Idl.zig");
pub const CallableSource = @import("Source.zig");
const Allocator = std.mem.Allocator;
pub const source = .{
    .package = "@webref/idl",
    .version = "3.86.0",
    .url = "https://registry.npmjs.org/@webref/idl/-/idl-3.86.0.tgz",
    .sha256 = "f820cd04584ca7f815b8cee1381d76e27363090cd62e0cb88962d8188bc7c90a",
};
pub const max_archive_bytes = 1024 * 1024;
pub const max_expanded_bytes = 16 * 1024 * 1024;
pub const max_files = 1024;

pub const File = struct { path: []const u8, source: []const u8 };
pub const Declaration = struct {
    file: u32,
    kind: Idl.Kind,
    partial: bool,
    name: []const u8,
    parent: ?[]const u8,
    source_span: Idl.Span,
    attributes_span: Idl.Span,
    members_start: u32,
    members_end: u32,
};
pub const Member = struct { file: u32, owner: u32, source_span: Idl.Span, status: enum { adapter_required } = .adapter_required };
pub const NativeType = struct {
    idl_name: []const u8,
    name: []const u8,
    module: []const u8,
    declaration: u32,
    declarations: []const u32,
    exposed: []const []const u8,
    globals: []const []const u8,
    parent: ?u32 = null,
    /// Only pinned generation may publish a candidate ordinary callable.
    callable: CallableSource.Origin = .none,
};
pub const Upcast = struct { from: u32, to: u32, lowering: enum { identity } = .identity };
pub const Include = struct { target: u32, mixin_declaration: u32 };
pub const NameMap = struct { idl: []const u8, beni: []const u8 };
pub const name_map = [_]NameMap{.{ .idl = "console", .beni = "Console" }};
pub const Catalogue = struct {
    name_map: []const NameMap = &name_map,
    format_version: u32 = 1,
    source: @TypeOf(source) = source,
    files: []const File,
    declarations: []const Declaration,
    members: []const Member,
    native_types: []NativeType,
    upcasts: []const Upcast,
    includes: []const Include,
    /// Candidates are not lowerable before ordinary validation and realm proof.
    callable_candidates: []const CallableSource.Row = &.{},
};
pub const Code = enum { source_mismatch, invalid_archive, invalid_idl, duplicate_identity, unresolved_reference, incompatible_partial, inheritance_cycle, unsupported_beni_name };
pub const Diagnostic = struct { code: Code, file: ?[]const u8 = null, offset: u32 = 0, detail: []const u8 = "" };
pub const Error = Allocator.Error || error{InvalidInput};
pub const Result = union(enum) { success: Catalogue, failure: Diagnostic };

pub fn generate(arena: Allocator, archive: []const u8) Allocator.Error!Result {
    if (archive.len > max_archive_bytes) return .{ .failure = .{ .code = .source_mismatch } };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, source.sha256) catch unreachable;
    if (!std.mem.eql(u8, &digest, &expected)) return .{ .failure = .{ .code = .source_mismatch } };
    const files = readArchive(arena, archive) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidInput => return .{ .failure = .{ .code = .invalid_archive } },
    };
    var result = try index(arena, files);
    if (result == .failure) return result;
    const c = &result.success;
    for (c.native_types) |*native| {
        if (!std.mem.eql(u8, native.idl_name, "TextEncoder")) continue;
        const decl = c.declarations[native.declaration];
        const file = c.files[decl.file];
        if (!std.mem.eql(u8, file.path, "encoding.idl")) return .{ .failure = .{ .code = .unresolved_reference, .detail = "TextEncoder source identity" } };
        for (c.members[decl.members_start..decl.members_end]) |member| {
            if (!std.mem.eql(u8, member.source_span.text(file.source), "constructor();")) continue;
            const rows = try arena.alloc(CallableSource.Row, 1);
            rows[0] = CallableSource.row(decl.file, member.source_span.start, member.source_span.end);
            c.callable_candidates = rows;
            native.callable = .text_encoder_v1;
            return result;
        }
        return .{ .failure = .{ .code = .unresolved_reference, .detail = "TextEncoder constructor signature" } };
    }
    return .{ .failure = .{ .code = .unresolved_reference, .detail = "TextEncoder identity" } };
}

fn readArchive(arena: Allocator, archive: []const u8) Error![]const File {
    var compressed: std.Io.Reader = .fixed(archive);
    var decompressed: std.compress.flate.Decompress = .init(&compressed, .gzip, &.{});
    const expanded = decompressed.reader.allocRemaining(arena, .limited(max_expanded_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInput,
    };
    var input: std.Io.Reader = .fixed(expanded);
    var path_buffer: [4096]u8 = undefined;
    var link_buffer: [4096]u8 = undefined;
    var archive_reader: std.tar.Iterator = .init(&input, .{ .file_name_buffer = &path_buffer, .link_name_buffer = &link_buffer });
    var files: std.ArrayList(File) = .empty;
    while (archive_reader.next() catch return error.InvalidInput) |file| {
        if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".idl")) continue;
        if (!std.mem.startsWith(u8, file.name, "package/") or std.mem.find(u8, file.name, "..") != null or file.size > Idl.max_source_bytes or files.items.len == max_files) return error.InvalidInput;
        const bytes = input.readAllocAll(arena, @intCast(file.size)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidInput,
        };
        // The bytes were read directly from the iterator's reader.
        archive_reader.unread_file_bytes = 0;
        try files.append(arena, .{ .path = try arena.dupe(u8, file.name["package/".len..]), .source = bytes });
    }
    std.mem.sort(File, files.items, {}, struct {
        fn less(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    for (files.items, 0..) |file, i| if (i > 0 and std.mem.eql(u8, file.path, files.items[i - 1].path)) return error.InvalidInput;
    return files.toOwnedSlice(arena);
}

pub fn index(arena: Allocator, files: []const File) Allocator.Error!Result {
    var table: Idl.Table = .{};
    defer table.deinit(arena);
    for (files, 0..) |file, i| table.append(arena, @intCast(i), file.source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidIdl => {
            const d = table.diagnostic.?;
            return .{ .failure = .{ .code = .invalid_idl, .file = file.path, .offset = d.offset, .detail = @tagName(d.code) } };
        },
    };
    const declarations = try arena.alloc(Declaration, table.declarations.len);
    for (declarations, 0..) |*out, i| {
        const d = table.declarations.get(i);
        const bytes = files[d.file].source;
        out.* = .{ .file = d.file, .kind = d.kind, .partial = d.partial, .name = d.name.text(bytes), .parent = if (d.parent.start != d.parent.end) d.parent.text(bytes) else null, .source_span = d.source, .attributes_span = d.attributes, .members_start = d.members_start, .members_end = d.members_end };
    }
    const members = try arena.alloc(Member, table.members.len);
    for (members, 0..) |*out, i| {
        const m = table.members.get(i);
        out.* = .{ .file = m.file, .owner = m.owner, .source_span = m.source };
    }
    var primary: std.StringHashMapUnmanaged(u32) = .empty;
    for (declarations, 0..) |d, i| {
        if (d.partial or d.kind == .includes) continue;
        const gop = try primary.getOrPut(arena, d.name);
        if (gop.found_existing) return failure(.duplicate_identity, files[d.file], d, d.name);
        gop.value_ptr.* = @intCast(i);
    }
    for (declarations) |d| {
        if (d.partial) {
            const first = primary.get(d.name) orelse return failure(.unresolved_reference, files[d.file], d, d.name);
            if (declarations[first].kind != d.kind) return failure(.incompatible_partial, files[d.file], d, d.name);
        }
        if (d.parent) |name| {
            const parent = primary.get(name) orelse return failure(.unresolved_reference, files[d.file], d, name);
            const expected_kind: Idl.Kind = if (d.kind == .includes) .mixin else d.kind;
            if (declarations[parent].kind != expected_kind) return failure(.unresolved_reference, files[d.file], d, name);
        }
        if (d.kind == .includes) {
            const target = primary.get(d.name) orelse return failure(.unresolved_reference, files[d.file], d, d.name);
            if (declarations[target].kind != .interface) return failure(.unresolved_reference, files[d.file], d, d.name);
        }
    }
    // Dense declaration ids index parent/color arrays. Each primary is
    // visited at most twice, including dictionary inheritance: O(V + E).
    const parents = try arena.alloc(?u32, declarations.len);
    const colors = try arena.alloc(u8, declarations.len);
    @memset(parents, null);
    @memset(colors, 0);
    for (declarations, 0..) |d, i| {
        if (!d.partial and d.kind != .includes) if (d.parent) |name| {
            parents[i] = primary.get(name).?;
        };
    }
    for (declarations, 0..) |d, i| {
        if (d.partial or d.kind == .includes or colors[i] != 0) continue;
        var at: ?u32 = @intCast(i);
        while (at) |id| {
            if (colors[id] != 0) break;
            colors[id] = 1;
            at = parents[id];
        }
        if (at) |id| if (colors[id] == 1) return failure(.inheritance_cycle, files[d.file], d, d.name);
        at = @intCast(i);
        while (at) |id| {
            if (colors[id] != 1) break;
            colors[id] = 2;
            at = parents[id];
        }
    }
    var types: std.ArrayList(NativeType) = .empty;
    for (declarations, 0..) |d, i| {
        if (d.partial or (d.kind != .interface and d.kind != .callback_interface and d.kind != .namespace)) continue;
        const name = beniName(d.name) orelse return failure(.unsupported_beni_name, files[d.file], d, d.name);
        var blocks: std.ArrayList(u32) = .empty;
        for (declarations, 0..) |block, block_id| {
            if (block.kind == d.kind and std.mem.eql(u8, block.name, d.name)) try blocks.append(arena, @intCast(block_id));
        }
        const attrs = d.attributes_span.text(files[d.file].source);
        const exposed = Idl.attributeNames(arena, attrs, "Exposed") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidIdl => return failure(.invalid_idl, files[d.file], d, "invalid Exposed attribute"),
        };
        const globals = Idl.attributeNames(arena, attrs, "Global") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidIdl => return failure(.invalid_idl, files[d.file], d, "invalid Global attribute"),
        };
        try types.append(arena, .{ .idl_name = d.name, .name = name, .module = try std.fmt.allocPrint(arena, "Browser.Host.{s}", .{name}), .declaration = @intCast(i), .declarations = try blocks.toOwnedSlice(arena), .exposed = exposed, .globals = globals });
    }
    std.mem.sort(NativeType, types.items, {}, struct {
        fn less(_: void, a: NativeType, b: NativeType) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    for (types.items, 0..) |t, i| if (i > 0 and std.mem.eql(u8, t.name, types.items[i - 1].name)) {
        const d = declarations[t.declaration];
        return failure(.duplicate_identity, files[d.file], d, t.name);
    };
    const type_of_decl = try arena.alloc(?u32, declarations.len);
    @memset(type_of_decl, null);
    for (types.items, 0..) |t, i| type_of_decl[t.declaration] = @intCast(i);
    var upcasts: std.ArrayList(Upcast) = .empty;
    for (types.items, 0..) |*t, i| {
        const d = declarations[t.declaration];
        if (d.parent) |name| {
            const target = type_of_decl[primary.get(name).?] orelse return failure(.unresolved_reference, files[d.file], d, name);
            t.parent = target;
            try upcasts.append(arena, .{ .from = @intCast(i), .to = target });
        }
    }
    var includes: std.ArrayList(Include) = .empty;
    var included: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (declarations) |d| if (d.kind == .includes) {
        const target = type_of_decl[primary.get(d.name).?].?;
        const mixin = primary.get(d.parent.?).?;
        const key = (@as(u64, target) << 32) | mixin;
        const edge = try included.getOrPut(arena, key);
        if (edge.found_existing) return failure(.duplicate_identity, files[d.file], d, d.parent.?);
        try includes.append(arena, .{ .target = target, .mixin_declaration = mixin });
    };
    return .{ .success = .{ .files = files, .declarations = declarations, .members = members, .native_types = try types.toOwnedSlice(arena), .upcasts = try upcasts.toOwnedSlice(arena), .includes = try includes.toOwnedSlice(arena) } };
}

fn failure(code: Code, file: File, d: Declaration, detail: []const u8) Result {
    return .{ .failure = .{ .code = code, .file = file.path, .offset = d.source_span.start, .detail = detail } };
}
fn beniName(name: []const u8) ?[]const u8 {
    // IDL console is a namespace with a lowercase name. This explicit mapping
    // is format-v1 data, not an implicit capitalization heuristic.
    for (name_map) |mapping| if (std.mem.eql(u8, name, mapping.idl)) return mapping.beni;
    if (name.len == 0 or !std.ascii.isUpper(name[0])) return null;
    for (name[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    return name;
}

pub fn moduleSource(arena: Allocator, native: NativeType) Allocator.Error![]const u8 {
    if (native.callable == .text_encoder_v1) return arena.dupe(u8, CallableSource.source);
    return std.fmt.allocPrint(arena, "-- Generated from @webref/idl 3.86.0. Native identity; no public acquisition yet.\npub foreign type {s}\n", .{native.name});
}

test "native index joins includes and generates explicit inheritance upcasts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try index(arena.allocator(), &.{.{ .path = "dom.idl", .source = "[Exposed=Window] interface Node {}; [Exposed=Window] interface Element : Node {}; interface mixin ParentNode { undefined f(); }; Element includes ParentNode; partial interface Element { readonly attribute long x; };" }});
    const c = result.success;
    try std.testing.expectEqual(@as(usize, 2), c.native_types.len);
    try std.testing.expectEqualStrings("Element", c.native_types[0].name);
    try std.testing.expectEqualDeep(&[_]Upcast{.{ .from = 0, .to = 1 }}, c.upcasts);
    try std.testing.expectEqualDeep(&[_]Include{.{ .target = 0, .mixin_declaration = 2 }}, c.includes);
    try std.testing.expectEqualStrings("Window", c.native_types[0].exposed[0]);
    try std.testing.expectEqualStrings("-- Generated from @webref/idl 3.86.0. Native identity; no public acquisition yet.\npub foreign type Element\n", try moduleSource(arena.allocator(), c.native_types[0]));
}

test "native index refuses unresolved inheritance and cycles" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const missing = try index(arena.allocator(), &.{.{ .path = "x.idl", .source = "interface Child : Missing {};" }});
    try std.testing.expectEqualDeep(Diagnostic{ .code = .unresolved_reference, .file = "x.idl", .offset = 0, .detail = "Missing" }, missing.failure);
    const cycle = try index(arena.allocator(), &.{.{ .path = "x.idl", .source = "interface A : B {}; interface B : A {};" }});
    try std.testing.expectEqualDeep(Diagnostic{ .code = .inheritance_cycle, .file = "x.idl", .offset = 0, .detail = "A" }, cycle.failure);
}

test {
    _ = Idl;
}

test "native index rejects duplicate identities, incompatible partials and mapped-name collisions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { source_text: []const u8, expected: Diagnostic }{
        .{ .source_text = "interface X {}; dictionary X {};", .expected = .{ .code = .duplicate_identity, .file = "x.idl", .offset = 16, .detail = "X" } },
        .{ .source_text = "interface X {}; partial dictionary X {};", .expected = .{ .code = .incompatible_partial, .file = "x.idl", .offset = 16, .detail = "X" } },
        .{ .source_text = "namespace console {}; interface Console {};", .expected = .{ .code = .duplicate_identity, .file = "x.idl", .offset = 22, .detail = "Console" } },
        .{ .source_text = "dictionary A : B {}; dictionary B : A {};", .expected = .{ .code = .inheritance_cycle, .file = "x.idl", .offset = 0, .detail = "A" } },
    };
    for (cases) |case| {
        const result = try index(arena.allocator(), &.{.{ .path = "x.idl", .source = case.source_text }});
        try std.testing.expectEqualDeep(case.expected, result.failure);
    }
}

test "native index retains every partial block and the explicit console map" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try index(arena.allocator(), &.{.{ .path = "x.idl", .source = "namespace console {}; partial namespace console { undefined log(); };" }});
    const c = result.success;
    try std.testing.expectEqualDeep(&[_]u32{ 0, 1 }, c.native_types[0].declarations);
    try std.testing.expectEqualStrings("console", c.native_types[0].idl_name);
    try std.testing.expectEqualStrings("Console", c.native_types[0].name);
    try std.testing.expectEqualStrings("Browser.Host.Console", c.native_types[0].module);
    try std.testing.expectEqualDeep(&[_]NameMap{.{ .idl = "console", .beni = "Console" }}, c.name_map);
    try std.testing.expectEqual(@as(usize, 1), c.members.len);
    try std.testing.expectEqual(.adapter_required, c.members[0].status);
}

test "native index rejects repeated includes instead of applying a mixin twice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try index(arena.allocator(), &.{.{ .path = "x.idl", .source = "interface X {}; interface mixin M {}; X includes M; X includes M;" }});
    try std.testing.expectEqualDeep(Diagnostic{ .code = .duplicate_identity, .file = "x.idl", .offset = 52, .detail = "M" }, result.failure);
}
