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
    // Generation and validation finish before any output directory is created.
    const bytes = try std.json.Stringify.valueAlloc(arena, c, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().createDirPath(init.io, args[2]);
    var out = try std.Io.Dir.cwd().openDir(init.io, args[2], .{});
    defer out.close(init.io);
    try out.writeFile(init.io, .{ .sub_path = "native-index.json", .data = bytes });
    var row_text: std.Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(c.callable_candidates[0], .{}, &row_text.writer);
    try row_text.writer.writeByte('\n');
    try out.writeFile(init.io, .{ .sub_path = "TextEncoder.binding.zon", .data = row_text.written() });
    try out.createDirPath(init.io, "Browser/Host");
    for (c.native_types) |native| {
        const path = try std.fmt.allocPrint(arena, "Browser/Host/{s}.beni", .{native.name});
        try out.writeFile(init.io, .{ .sub_path = path, .data = try Native.moduleSource(arena, native) });
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

test "pinned constructor candidate retains source identity and cannot yet lower" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try Native.generate(arena.allocator(), @embedFile("webref_idl"));
    const c = result.success;
    try std.testing.expectEqual(@as(usize, 1), c.callable_candidates.len);
    const candidate = c.callable_candidates[0];
    try std.testing.expectEqualDeep(Native.CallableSource.candidate, candidate);
    try std.testing.expectEqualDeep(Native.CallableSource.row(candidate.file, candidate.member_start, candidate.member_end), candidate);
    try std.testing.expectEqualStrings("encoding.idl", c.files[candidate.file].path);
    try std.testing.expectEqualStrings("constructor();", c.files[candidate.file].source[candidate.member_start..candidate.member_end]);
    var selected: usize = 0;
    for (c.native_types) |native| {
        if (native.callable == .none) continue;
        selected += 1;
        try std.testing.expectEqualStrings("TextEncoder", native.idl_name);
        try std.testing.expectEqualStrings(Native.CallableSource.module_name, native.module);
        try std.testing.expectEqualStrings(Native.CallableSource.source, try Native.moduleSource(arena.allocator(), native));
    }
    try std.testing.expectEqual(@as(usize, 1), selected);
    // Retaining a candidate does not approve any original member's adapter.
    for (c.members) |member| try std.testing.expectEqual(.adapter_required, member.status);
}
