//! Build-command entry point and pinned-input tests for native binding metadata.
const std = @import("std");
const Native = @import("native_bindings");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: beni-native-bindings <pinned-idl-archive.tgz> <output-directory>\n", .{});
        return 2;
    }
    const archive = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(Native.max_archive_bytes + 1));
    const result = try Native.generate(arena, archive);
    const c = switch (result) {
        .success => |c| c,
        .failure => |d| {
            std.debug.print("{s}: {s}:{d}: {s}\n", .{ @tagName(d.code), d.file orelse args[1], d.offset, d.detail });
            return 1;
        },
    };
    if (!Native.Callable.validate(c)) return error.InvalidCallableCatalogue;
    // Generation and validation finish before any output directory is created.
    const bytes = try std.json.Stringify.valueAlloc(arena, c, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().createDirPath(init.io, args[2]);
    var out = try std.Io.Dir.cwd().openDir(init.io, args[2], .{});
    defer out.close(init.io);
    try out.writeFile(init.io, .{ .sub_path = "native-index.json", .data = bytes });
    try out.createDirPath(init.io, "Browser/Host");
    for (c.native_types) |native| {
        const path = try std.fmt.allocPrint(arena, "Browser/Host/{s}.beni", .{native.name});
        const callable = @import("native_bindings").Callable;
        const text = try callable.source(arena, native.module, native.name);
        try out.writeFile(init.io, .{ .sub_path = path, .data = text });
        const js = try callable.sibling(arena, native.module);
        if (js.len != 0) try out.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(arena, "Browser/Host/{s}.js", .{native.name}), .data = js });
    }
    for ([_][]const u8{ "Timers", "Uint8Array" }) |name| {
        const module = try std.fmt.allocPrint(arena, "Browser.Host.{s}", .{name});
        try out.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(arena, "Browser/Host/{s}.beni", .{name}), .data = try Native.Callable.source(arena, module, if (std.mem.eql(u8, name, "Uint8Array")) name else null) });
        try out.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(arena, "Browser/Host/{s}.js", .{name}), .data = try Native.Callable.sibling(arena, module) });
    }
    return 0;
}

test "pinned full IDL archive produces deterministic native metadata" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const archive = @embedFile("webref_idl");
    const first = try Native.generate(arena.allocator(), archive);
    if (first == .failure) {
        std.debug.print("{any}\n", .{first.failure});
        return error.UnexpectedFailure;
    }
    const c = first.success;
    try std.testing.expectEqual(@as(usize, 346), c.files.len);
    try std.testing.expectEqual(@as(usize, 11621), c.members.len);
    try std.testing.expectEqual(@as(usize, 3676), c.declarations.len);
    try std.testing.expectEqual(@as(usize, 1165), c.native_types.len);
    try std.testing.expectEqual(@as(usize, 631), c.upcasts.len);
    try std.testing.expectEqual(@as(usize, 270), c.includes.len);
    var blocks: usize = 0;
    var dictionary_fields: usize = 0;
    for (c.declarations) |declaration| {
        switch (declaration.kind) {
            .interface, .callback_interface, .mixin, .namespace, .dictionary => blocks += 1,
            else => {},
        }
        if (declaration.kind == .dictionary) dictionary_fields += declaration.members_end - declaration.members_start;
    }
    try std.testing.expectEqual(@as(usize, 2782), blocks);
    // SanitizerElementNamespace's quoted http:// default is a member, not a
    // line comment. The old regex census lost this field's semicolon.
    try std.testing.expectEqual(@as(usize, 3364), dictionary_fields);
    const one = try std.json.Stringify.valueAlloc(arena.allocator(), c, .{});
    const second = try Native.generate(arena.allocator(), archive);
    const two = try std.json.Stringify.valueAlloc(arena.allocator(), second.success, .{});
    try std.testing.expectEqualSlices(u8, one, two);
}

test "wrong source identity is rejected before parsing" {
    const result = try Native.generate(std.testing.allocator, "not the pinned archive");
    try std.testing.expectEqualDeep(Native.Result{ .failure = .{ .code = .source_mismatch } }, result);
}

test {
    _ = Native;
}

test "generator source identity agrees with the shared research receipt" {
    const Receipt = struct { idl: struct { package: []const u8, version: []const u8, url: []const u8, sha256: []const u8 } };
    const receipt = try std.json.parseFromSlice(Receipt, std.testing.allocator, @embedFile("webref_receipt"), .{ .ignore_unknown_fields = true });
    defer receipt.deinit();
    try std.testing.expectEqualStrings(Native.source.package, receipt.value.idl.package);
    try std.testing.expectEqualStrings(Native.source.version, receipt.value.idl.version);
    try std.testing.expectEqualStrings(Native.source.url, receipt.value.idl.url);
    try std.testing.expectEqualStrings(Native.source.sha256, receipt.value.idl.sha256);
}

test "reviewed callable subset resolves against the pinned catalogue" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try Native.generate(arena.allocator(), @embedFile("webref_idl"));
    try std.testing.expect(Native.Callable.validate(result.success));
}

test "shipped native modules are exactly the pinned generator output" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "Window", "Document", "Node", "Element", "TextEncoder", "Uint8Array", "Timers", "WorkerGlobalScope" }) |name| {
        const module = try std.fmt.allocPrint(a, "Browser.Host.{s}", .{name});
        const path = try std.fmt.allocPrint(a, "core/Browser/Host/{s}.beni", .{name});
        const actual = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024));
        try std.testing.expectEqualStrings(try Native.Callable.source(a, module, if (std.mem.eql(u8, name, "Timers")) null else name), actual);
        const js_path = try std.fmt.allocPrint(a, "core/Browser/Host/{s}.js", .{name});
        const js = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, js_path, a, .limited(64 * 1024));
        try std.testing.expectEqualStrings(try Native.Callable.sibling(a, module), js);
    }
}

test "callable member spans match complete IDL identifiers regardless of member order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try Native.generate(a, @embedFile("webref_idl"));
    var catalogue = result.success;
    const reversed = try a.dupe(Native.Member, catalogue.members);
    std.mem.reverse(Native.Member, reversed);
    catalogue.members = reversed;
    const bindings = try Native.Callable.bindings(a, catalogue);
    for (bindings) |binding| {
        if (!std.mem.eql(u8, binding.operation.module, "Browser.Host.TextEncoder") or !std.mem.eql(u8, binding.operation.name, "encode")) continue;
        const member = catalogue.members[binding.member.?];
        try std.testing.expectEqualStrings("[NewObject] Uint8Array encode(optional USVString input = \"\");", member.source_span.text(catalogue.files[member.file].source));
        return;
    }
    return error.MissingEncodeBinding;
}
