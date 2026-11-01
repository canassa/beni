//! Native candidate attestation and remaining unresolved projection boundary.
const std = @import("std");
const diagnostic = @import("diagnostic");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

fn prepare(w: *World) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(w.io, "tests/fixtures/native-callable/Main.beni", w.arena.allocator(), .limited(65536));
    try w.write("Main.beni", bytes);
}
fn clean(r: world.Result) !void {
    if (r.exit_code != 0) std.debug.print("{s}\n", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}
fn checked(w: *World, path: []const u8) !u64 {
    const Event = struct { args: struct { modules_checked: ?u64 = null } = .{} };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read(path), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.traceEvents) |event| if (event.args.modules_checked) |count| return count;
    return error.MissingProfileCount;
}

test "native candidate ordinary import uses cache and preserves checked effect through roundtrip" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try clean(try w.run(&.{ "check", "--jobs=1", "--self-profile=cold.json", "Main.beni" }));
    try testing.expectEqual(@as(u64, 2), try checked(&w, "cold.json"));
    try clean(try w.run(&.{ "check", "--jobs=8", "--roundtrip-interfaces", "--self-profile=warm.json", "Main.beni" }));
    try testing.expectEqual(@as(u64, 0), try checked(&w, "warm.json"));
    try testing.expect(!w.exists("out"));
}

test "native candidate identical physical supplier invalidates own and reverse cached authority" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try clean(try w.run(&.{ "check", "Main.beni" }));
    const source = try std.Io.Dir.cwd().readFileAlloc(w.io, "tests/fixtures/native-callable/TextEncoder.beni", w.arena.allocator(), .limited(65536));
    try w.write("core/Browser/Host/TextEncoder.beni", source);
    try clean(try w.run(&.{ "check", "--self-profile=physical.json", "Main.beni", "core/Browser/Host/TextEncoder.beni" }));
    try testing.expectEqual(@as(u64, 2), try checked(&w, "physical.json"));
    try clean(try w.run(&.{ "check", "--self-profile=restored.json", "Main.beni" }));
    try testing.expectEqual(@as(u64, 0), try checked(&w, "restored.json"));
    try testing.expect(!w.exists("out"));
}

test "native unresolved program projection cannot execute through an ordinary sibling" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    // Reuse an unchanged existing sibling. No handwritten JavaScript fixture.
    const sibling = try std.Io.Dir.cwd().readFileAlloc(w.io, "core/Record.js", w.arena.allocator(), .limited(65536));
    for ([_]bool{ false, true }) |with_sibling| {
        if (with_sibling) try w.write("core/Browser/Host/TextEncoder.js", sibling);
        const result = try w.run(&.{ "build", "--library", "--platform=node", "--diagnostics=json", "Main.beni" });
        try testing.expectEqual(@as(u8, 1), result.exit_code);
        try testing.expectEqualStrings("", result.stdout);
        const expected = [_]diagnostic.Diagnostic{.{
            .code = .not_implemented,
            .severity = .@"error",
            .span = .{ .file = "core/Browser/Host/TextEncoder.beni", .start = .{ .line = 4, .col = 20 }, .end = .{ .line = 4, .col = 23 } },
            .title = "NOT IMPLEMENTED YET",
            .message = "Native emission requires a current generic initializer evaluation witness;\nprogram projections remain unresolved. No native callable was emitted.",
        }};
        try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &expected), result.diagnostics);
        try testing.expect(!w.exists("out"));
    }
}

fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn cachedEffectMismatch(replacement: u32) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const keys = try w.run(&.{ "check", "--cache-dir=cache", "--cache-keys", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), keys.exit_code);
    try testing.expectEqualStrings("", keys.stderr);
    var lines = std.mem.splitScalar(u8, keys.stdout, '\n');
    const prefix = "core:Browser.Host.TextEncoder ";
    const path = while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const digits = line[prefix.len..];
        try testing.expectEqual(@as(usize, 32), digits.len);
        break try std.fmt.allocPrint(w.arena.allocator(), "cache/v1/{s}/{s}.bec", .{ digits[0..2], digits[2..] });
    } else return error.MissingNativeKey;
    const original = try w.read(path);
    try testing.expectEqualStrings("BENICAC\x00", original[0..8]);
    const record_at: usize = word(original, 32);
    const record = original[record_at..][0..word(original, 36)];
    try testing.expectEqualStrings("BENIIFC\x00", record[0..8]);
    try testing.expectEqual(@as(u32, 18), word(record, 8));
    // Public IFC18 directory: schemes column3, extra column7, scheme row20B.
    // Locate the root class through its actual scheme's effect-block offset.
    const schemes_at = word(record, 16 + 3 * 8);
    try testing.expectEqual(@as(u32, 1), word(record, 16 + 3 * 8 + 4));
    const extra_at = word(record, 16 + 7 * 8);
    const effect = word(record, schemes_at + 12);
    try testing.expectEqual(@as(u32, 1), word(record, extra_at + effect * 4));
    const rung_at = record_at + extra_at + (effect + 1) * 4;
    try testing.expectEqual(@as(u32, 1), word(original, rung_at));
    const mutated = try w.arena.allocator().dupe(u8, original);
    std.mem.writeInt(u32, mutated[rung_at..][0..4], replacement, .little);
    // Outer key/envelope, other interface words, and EVERY unrelated section
    // remain byte-identical. Both rung2 and rung1+sync are valid class words.
    try testing.expectEqualSlices(u8, original[0..rung_at], mutated[0..rung_at]);
    try testing.expectEqualSlices(u8, original[rung_at + 4 ..], mutated[rung_at + 4 ..]);
    try w.write(path, mutated);
    try clean(try w.run(&.{ "check", "--cache-dir=cache", "--self-profile=repair.json", "Main.beni" }));
    try testing.expectEqual(@as(u64, 1), try checked(&w, "repair.json"));
    try testing.expectEqualSlices(u8, original, try w.read(path));
    try clean(try w.run(&.{ "check", "--cache-dir=cache", "--self-profile=repaired-warm.json", "Main.beni" }));
    try testing.expectEqual(@as(u64, 0), try checked(&w, "repaired-warm.json"));
    try testing.expect(!w.exists("out"));
}

test "native candidate repairs a structurally valid cached effect mismatch before installation" {
    try cachedEffectMismatch(2);
}

test "native candidate repairs cached root sync contract before installation" {
    try cachedEffectMismatch(1 | (1 << 8));
}
