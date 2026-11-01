//! Actual ordinary source capture; realm execution certification remains separate.
const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;
fn prepare(w: *World) !void {
    try w.copyTree("tests/fixtures/entry-discovery/basic", "_excluded.");
    try w.copyTree("tests/fixtures/native-realms/source", "_excluded.");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{ "import SourceEvents\n", try w.read("Main.beni") }));
}
fn clean(r: world.Result) !void {
    if (r.exit_code != 0) std.debug.print("{s}\n", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}
fn run(w: *World, trace: []const u8, extra: []const []const u8) !world.Result {
    const a = w.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try argv.appendSlice(a, extra);
    try argv.append(a, try std.fmt.allocPrint(a, "--self-profile={s}", .{trace}));
    const r = try w.run(argv.items);
    try clean(r);
    return r;
}
fn checks(w: *World, trace: []const u8) !u64 {
    const Event = struct { args: struct { modules_checked: ?u64 = null } = .{} };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read(trace), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.traceEvents) |event| if (event.args.modules_checked) |n| return n;
    return error.MissingCounter;
}
fn section(text: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, text, "native-realm-source schema=1 proof=source-records realmProved=false entryComplete=false\n") orelse return error.MissingRealmSource;
    return text[at..];
}
fn moduleId(text: []const u8, name: []const u8) !u32 {
    var lines = std.mem.splitScalar(u8, try section(text), '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  realm-module ")) continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        _ = words.next();
        const id = try std.fmt.parseInt(u32, words.next().?, 10);
        if (std.mem.eql(u8, words.next().?, name)) return id;
    }
    return error.MissingModule;
}
fn literals(w: *World, text: []const u8, name: []const u8) ![]const u8 {
    const prefix = try std.fmt.allocPrint(w.arena.allocator(), "  realm-literal {d}:", .{try moduleId(text, name)});
    var result: std.Io.Writer.Allocating = .init(w.arena.allocator());
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) {
        const role = std.mem.indexOf(u8, line, "role=") orelse return error.MissingRole;
        try result.writer.writeAll(line[role + 5 ..]);
        try result.writer.writeByte('\n');
    };
    return result.written();
}

test "realm source packed capture retains intrinsic literal and interpolation observations across warm jobs roundtrip relocation" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const cold = try run(&w, "cold.json", &.{"--jobs=1"});
    try testing.expect(try checks(&w, "cold.json") > 0);
    try testing.expectEqualStrings("literal_string\nobject_key\nobject_pair\nobject_list\ninterpolation_chunk\n", try literals(&w, cold.stdout, "platform:SourceEvents"));
    try testing.expect((try literals(&w, cold.stdout, "core:Basics")).len > 0);
    const warm = try run(&w, "warm.json", &.{"--jobs=8"});
    try testing.expectEqualStrings(cold.stdout, warm.stdout);
    try testing.expectEqual(@as(u64, 0), try checks(&w, "warm.json"));
    const roundtrip = try run(&w, "roundtrip.json", &.{ "--no-cache", "--roundtrip-dispatch", "--jobs=8" });
    try testing.expectEqualStrings(cold.stdout, roundtrip.stdout);
    var relocated = try World.init(testing.allocator, testing.io);
    defer relocated.deinit();
    try prepare(&relocated);
    try testing.expectEqualStrings(try section(cold.stdout), try section((try run(&relocated, "relocated.json", &.{})).stdout));
}

test "realm source request rechecks ordinary cached modules and same named platform intrinsics stay ordinary" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const ordinary = try w.run(&.{ "check", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try clean(ordinary);
    try testing.expectEqualStrings("", ordinary.stdout);
    const demanded = try run(&w, "demanded.json", &.{});
    try testing.expect(try checks(&w, "demanded.json") > 0);
    try w.write("platform/Js.beni", "pub global value = value\n\n\npub object value = value\n");
    const shadow = try w.run(&.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try clean(shadow);
    try testing.expectEqualStrings("interpolation_chunk\n", try literals(&w, shadow.stdout, "platform:SourceEvents"));
    try testing.expect((try moduleId(shadow.stdout, "platform:Js")) != std.math.maxInt(u32));
    try testing.expect(!std.mem.eql(u8, try section(demanded.stdout), try section(shadow.stdout)));
    try w.write("Js.beni", "pub global value = value\n");
    try w.write("AppEvents.beni", "import Js\n\n\npub literal = Js.global \"Math\"\n\n\nword = \"world\"\n\n\npub text = \"hello ${word}\"\n");
    const app_shadow = try w.run(&.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni", "AppEvents.beni", "Js.beni" });
    try clean(app_shadow);
    try testing.expectEqualStrings("interpolation_chunk\n", try literals(&w, app_shadow.stdout, "app:AppEvents"));
    _ = try moduleId(app_shadow.stdout, "app:Js");
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn entry(w: *World) ![]const u8 {
    const r = try w.run(&.{ "check", "--cache-keys", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try clean(r);
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "platform:SourceEvents ")) {
        const key = line[22..];
        try testing.expectEqual(@as(usize, 32), key.len);
        return std.fmt.allocPrint(w.arena.allocator(), "cache/v1/{s}/{s}.bec", .{ key[0..2], key[2..] });
    };
    return error.MissingKey;
}

test "realm source semantic cache literal role and blocked downgrades repair before install" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const cold = try run(&w, "cold.json", &.{});
    const path = try entry(&w);
    const good = try w.read(path);
    const side: usize = word(good, 40);
    try testing.expectEqual(@as(u32, 21), word(good, side + 8));
    const column = side + 16 + (word(good, side + 12) - 1) * 8;
    const source = side + word(good, column);
    try testing.expectEqualStrings("BENIRLM\x00", good[source..][0..8]);
    try testing.expectEqual(@as(u32, 1), word(good, source + 8));
    const nodes = source + 40 + word(good, source + 12) * 16 + word(good, source + 16) * 28;
    const count = word(good, source + 20);
    var literal: ?usize = null;
    var ordinary: ?usize = null;
    for (0..count) |i| {
        const node = nodes + i * 40;
        if (word(good, node) == 3) literal = node;
        if (word(good, node) == 0 and word(good, node + 8) != std.math.maxInt(u32)) ordinary = node;
    }
    try testing.expect(literal != null and ordinary != null);
    for (0..3) |mutation| {
        const bad = try w.arena.allocator().dupe(u8, good);
        switch (mutation) {
            0 => put(bad, literal.?, 0), // in-place string cannot forge ordinary anchor
            1 => put(bad, ordinary.?, 3), // ordinary expression cannot hide as literal
            2 => put(bad, ordinary.? + 36, 1), // well-shaped blocked downgrade
            else => unreachable,
        }
        try w.write(path, bad);
        try testing.expectEqualStrings(cold.stdout, (try run(&w, "repair.json", &.{})).stdout);
        try testing.expect(try checks(&w, "repair.json") > 0);
        try testing.expectEqualStrings(good, try w.read(path));
        try testing.expectEqualStrings(cold.stdout, (try run(&w, "warm.json", &.{})).stdout);
        try testing.expectEqual(@as(u64, 0), try checks(&w, "warm.json"));
    }
}
