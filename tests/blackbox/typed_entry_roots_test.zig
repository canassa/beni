//! Ordinary typed roots through the actual checked/cache inspector boundary.
const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

fn prepare(w: *World) !void {
    try w.copyTree("tests/fixtures/typed-entry-roots/basic", "_excluded.");
}
fn clean(result: world.Result) !void {
    if (result.exit_code != 0) std.debug.print("{s}\n", .{result.stderr});
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
fn typed(text: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, text, "typed-entry-roots ") orelse return error.MissingTypedInspector;
    const end = std.mem.indexOfPos(u8, text, start, "nominal-module ") orelse text.len;
    return text[start..end];
}
const source_header = "native-realm-source schema=1 proof=source-records realmProved=false entryComplete=false\n";
const execution_header = "native-realm-execution schema=1 proof=source-execution entryComplete=false nativeLowering=false\n";
fn executionMetric(line: []const u8, key: []const u8) !u64 {
    const at = (std.mem.indexOf(u8, line, key) orelse return error.MissingExecutionMetric) + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, at, ' ') orelse line.len;
    return std.fmt.parseInt(u64, line[at..end], 10);
}
/// Preserve every old byte; accept only the two explicitly versioned new
/// sections with their known row grammar and complete declared row counts.
fn beforeSource(full_text: []const u8) ![]const u8 {
    const before_roles = try @import("entry_roles.zig").before(full_text);
    const text = try @import("entry_solved.zig").before(before_roles);
    const at = std.mem.indexOf(u8, text, source_header) orelse return error.MissingRealmSource;
    try testing.expect(at == 0 or text[at - 1] == '\n');
    try testing.expect(std.mem.indexOfPos(u8, text, at + source_header.len, "native-realm-source ") == null);
    const exec_at = std.mem.indexOfPos(u8, text, at + source_header.len, execution_header) orelse return error.MissingRealmExecution;
    try testing.expect(std.mem.indexOfPos(u8, text, exec_at + execution_header.len, "native-realm-execution ") == null);
    try testing.expect(std.mem.endsWith(u8, text, "\n"));
    var modules: usize = 0;
    var source_lines = std.mem.splitScalar(u8, text[at + source_header.len .. exec_at], '\n');
    while (source_lines.next()) |line_| {
        if (line_.len == 0) continue;
        const module = std.mem.startsWith(u8, line_, "  realm-module ");
        try testing.expect(module or std.mem.startsWith(u8, line_, "  realm-scope ") or std.mem.startsWith(u8, line_, "  realm-literal ") or std.mem.startsWith(u8, line_, "  realm-call ") or std.mem.startsWith(u8, line_, "  realm-reference "));
        modules += @intFromBool(module);
    }
    try testing.expect(modules > 0);
    const prefixes = [_][]const u8{ "  realm-selection ", "  realm-consumer ", "  realm-builder ", "  realm-kernel ", "  realm-exec ", "  realm-root ", "  realm-invocation ", "  realm-native ", "  realm-native-use ", "  realm-residual " };
    var counts: [prefixes.len]u64 = @splat(0);
    var expected_exec: u64 = 0;
    var expected_roots: u64 = 0;
    var expected_calls: u64 = 0;
    var expected_native: u64 = 0;
    var expected_residual: u64 = 0;
    var source_uses: u64 = 0;
    var lines = std.mem.splitScalar(u8, text[exec_at + execution_header.len ..], '\n');
    while (lines.next()) |line_| {
        if (line_.len == 0) continue;
        const kind = for (prefixes, 0..) |prefix, i| {
            if (std.mem.startsWith(u8, line_, prefix)) break i;
        } else return error.UnknownRealmExecutionRow;
        counts[kind] += 1;
        if (kind >= 4) {
            const rest = line_[prefixes[kind].len..];
            _ = try std.fmt.parseInt(u64, rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse return error.MissingExecutionIndex], 10);
            try testing.expect(std.mem.indexOf(u8, line_, " source=") != null);
        }
        switch (kind) {
            1 => {
                expected_roots = try executionMetric(line_, "roots=");
                expected_native = try executionMetric(line_, "nativeRows=");
                source_uses = try executionMetric(line_, "sourceUses=");
            },
            2 => {
                expected_calls = try executionMetric(line_, "calls=");
                expected_residual = try executionMetric(line_, "residuals=");
            },
            3 => expected_exec = try executionMetric(line_, "nodes="),
            else => {},
        }
    }
    for (counts[0..4]) |count_| try testing.expectEqual(@as(u64, 1), count_);
    try testing.expectEqual(expected_exec, counts[4]);
    try testing.expectEqual(expected_roots, counts[5]);
    try testing.expectEqual(expected_calls, counts[6]);
    try testing.expectEqual(expected_native, counts[7]);
    try testing.expect(counts[8] <= source_uses);
    try testing.expectEqual(expected_residual, counts[9]);
    return text[0..at];
}

fn moduleChecks(w: *World, trace: []const u8) !u64 {
    const Event = struct { args: struct { modules_checked: ?u64 = null } = .{} };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read(trace), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.traceEvents) |event| if (event.args.modules_checked) |count| return count;
    return error.MissingCheckCounter;
}
fn run(w: *World, trace: []const u8, extra: []const []const u8) !world.Result {
    const a = w.arena.allocator();
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try args.appendSlice(a, extra);
    try args.append(a, try std.fmt.allocPrint(a, "--self-profile={s}", .{trace}));
    const result = try w.run(args.items);
    try clean(result);
    return result;
}
fn canonical(w: *World, trace: []const u8, extra: []const []const u8) !u64 {
    const result = try run(w, trace, extra);
    try testing.expectEqualStrings(try typed(try w.read("_expected.typed")), try typed(result.stdout));
    return moduleChecks(w, trace);
}
fn entryFor(w: *World) ![]const u8 {
    const result = try w.run(&.{ "check", "--cache-keys", "--platform=platform", "Main.beni" });
    try clean(result);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "app:Main ")) {
        const digits = line["app:Main ".len..];
        try testing.expectEqual(@as(usize, 32), digits.len);
        return std.fmt.allocPrint(w.arena.allocator(), "cache/v1/{s}/{s}.bec", .{ digits[0..2], digits[2..] });
    };
    return error.MissingMainKey;
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn setWord(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn publicRecord(bytes: []const u8) []const u8 {
    const offset = word(bytes, 32);
    const length = word(bytes, 36);
    return bytes[offset..][0..length];
}

test "typed entry roots retain private generic alias where native and local evidence across cache jobs roundtrip relocation" {
    // PREPARE
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    // EXECUTE / VERIFY OUTPUT: exact compact graph, not expanded source types.
    try testing.expect(try canonical(&w, "cold.json", &.{"--jobs=1"}) > 0);
    try testing.expectEqual(@as(u64, 0), try canonical(&w, "warm.json", &.{"--jobs=8"}));
    try testing.expect(try canonical(&w, "roundtrip.json", &.{ "--cache-dir=roundtrip", "--roundtrip-dispatch", "--roundtrip-interfaces" }) > 0);
    try testing.expectEqual(@as(u64, 0), try canonical(&w, "roundtrip-warm.json", &.{ "--cache-dir=roundtrip", "--roundtrip-dispatch" }));
    // VERIFY SIDE EFFECTS: a new project owns moved cache bytes, no retained stores.
    var moved = try World.init(testing.allocator, testing.io);
    defer moved.deinit();
    try prepare(&moved);
    for (try w.listFiles("cache")) |name| {
        const path = try std.fmt.allocPrint(w.arena.allocator(), "cache/{s}", .{name});
        try moved.write(path, try w.read(path));
    }
    try testing.expectEqual(@as(u64, 0), try canonical(&moved, "moved.json", &.{"--jobs=8"}));
    try testing.expect(!w.exists("out"));
    try testing.expect(!moved.exists("out"));
}

test "typed entry roots recheck missing selector coverage without changing source key or public interface" {
    // PREPARE: first cache selected Start only while Worker declarations exist.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const manifest = try w.read("platform/beni.json");
    const worker = std.mem.indexOf(u8, manifest, ", {\"programType\": \"Worker.Program\"") orelse return error.MissingWorkerRow;
    const restricted = try std.fmt.allocPrint(w.arena.allocator(), "{s}]}}\n", .{manifest[0..worker]});
    try w.write("platform/beni.json", restricted);
    const initial = try run(&w, "restricted.json", &.{});
    try testing.expect(std.mem.indexOf(u8, try typed(initial.stdout), "typed-candidate private") == null);
    try testing.expectEqual(@as(u64, 0), blk: {
        _ = try run(&w, "restricted-warm.json", &.{});
        break :blk try moduleChecks(&w, "restricted-warm.json");
    });
    const key = try entryFor(&w);
    const before = try w.read(key);
    // EXECUTE: selecting Worker requires source publication despite same public interface.
    try w.write("platform/beni.json", manifest);
    try testing.expectEqual(@as(u64, 1), try canonical(&w, "expanded.json", &.{}));
    try testing.expectEqualStrings(key, try entryFor(&w));
    const after = try w.read(key);
    try testing.expectEqualSlices(u8, publicRecord(before), publicRecord(after));
    try testing.expect(!std.mem.eql(u8, before, after));
    try testing.expectEqual(@as(u64, 0), try canonical(&w, "expanded-warm.json", &.{}));
    // VERIFY SIDE EFFECTS: narrowing reuses a validated superset; checked Plan filters it.
    try w.write("platform/beni.json", restricted);
    const narrowed = try run(&w, "narrowed.json", &.{});
    try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "narrowed.json"));
    try testing.expect(std.mem.indexOf(u8, try typed(narrowed.stdout), "typed-candidate private") == null);
    try testing.expectEqualStrings(after, try w.read(key));
}

test "typed entry roots reject stale malformed absent and wrong-owner private cache artifacts before use" {
    // PREPARE: actual canonical entry bytes are an external untrusted input.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    _ = try canonical(&w, "cold.json", &.{});
    const key = try entryFor(&w);
    const good = try w.read(key);
    const sidecar = word(good, 40);
    try testing.expectEqual(@as(u32, 22), word(good, sidecar + 8));
    const columns = word(good, sidecar + 12);
    const column = sidecar + 16 + (columns - 5) * 8;
    const roots = sidecar + word(good, column);
    try testing.expectEqualStrings("BENIENT\x00", good[roots..][0..8]);
    try testing.expect(word(good, roots + 12) > 1);
    // EXECUTE / VERIFY OUTPUT: every malformed input is repaired through ordinary check.
    for (0..5) |mutation| {
        const bad = try w.arena.allocator().dupe(u8, good);
        switch (mutation) {
            0 => setWord(bad, roots + 8, 0),
            1 => setWord(bad, roots + 24, std.math.maxInt(u32)),
            2 => setWord(bad, roots + 28, std.math.maxInt(u32)),
            3 => setWord(bad, column + 4, 0), // absent is not complete empty
            4 => setWord(bad, roots + 24, 0), // alias declaration is not a value
            else => unreachable,
        }
        try w.write(key, bad);
        try testing.expectEqual(@as(u64, 1), try canonical(&w, "repair.json", &.{}));
        try testing.expectEqualStrings(good, try w.read(key));
        try testing.expectEqual(@as(u64, 0), try canonical(&w, "repaired-warm.json", &.{}));
    }
    // VERIFY SIDE EFFECTS
    try testing.expect(!w.exists("out"));
}

fn occurrences(text: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, text, needle);
}

test "typed entry roots preserve private depth2048 through cold warm and forced compact graph inspection" {
    // PREPARE: private inferred payload exceeds the public interface reader bound.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    var source: std.Io.Writer.Allocating = .init(w.arena.allocator());
    try source.writer.writeAll(try w.read("Main.beni"));
    try source.writer.writeAll("\n\ndeep = Worker.make { message = ");
    for (0..2048) |_| try source.writer.writeByte('[');
    try source.writer.writeAll("⊤");
    for (0..2048) |_| try source.writer.writeByte(']');
    try source.writer.writeAll(" } ⊤\n");
    try w.write("Main.beni", source.written());
    // EXECUTE / VERIFY OUTPUT: raw DAG is finite, equal after expiry/cache decode.
    const cold = try run(&w, "deep-cold.json", &.{ "--roundtrip-dispatch", "--roundtrip-interfaces" });
    const expected = try typed(cold.stdout);
    try testing.expect(occurrences(expected, "\nterm ") > 2048);
    try testing.expect(expected.len < 300_000);
    try testing.expect(std.mem.indexOf(u8, expected, "  typed-candidate deep ") != null);
    const warm = try run(&w, "deep-warm.json", &.{ "--roundtrip-dispatch", "--jobs=8" });
    try testing.expectEqualStrings(expected, try typed(warm.stdout));
    try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "deep-warm.json"));
    try testing.expect(!w.exists("out"));
}

test "typed entry roots retain compact alias diamond identities without exponential inspection expansion" {
    // PREPARE / EXECUTE: finite source examples; the encoded32/64 kernel
    // separately proves cursor work independently of the baseline annotation reader.
    for ([_]u32{ 8, 16 }) |depth| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try prepare(&w);
        var source: std.Io.Writer.Allocating = .init(w.arena.allocator());
        try source.writer.writeAll(try w.read("Main.beni"));
        try source.writer.writeAll("\n\ntype alias A0 a =\n    a\n");
        for (1..depth + 1) |level| try source.writer.print("\n\ntype alias A{d} a =\n    A{d} (A{d} a)\n", .{ level, level - 1, level - 1 });
        try source.writer.print("\n\ndiamond : Worker.Program {{ message : A{d} Int }} ⊤\ndiamond = Worker.make {{ message = 1 }} ⊤\n", .{depth});
        try w.write("Main.beni", source.written());
        const cold = try run(&w, "diamond-cold.json", &.{ "--roundtrip-dispatch", "--roundtrip-interfaces" });
        const expected = try typed(cold.stdout);
        try testing.expect(std.mem.indexOf(u8, expected, "  typed-candidate diamond ") != null);
        // VERIFY OUTPUT: aliases retain their names/body links, with bounded rows.
        try testing.expectEqual(@as(usize, depth) + 1, occurrences(expected, " app Main.A"));
        try testing.expect(occurrences(expected, "\nterm ") < @as(usize, depth) * 8 + 200);
        const warm = try run(&w, "diamond-warm.json", &.{"--jobs=8"});
        try testing.expectEqualStrings(expected, try typed(warm.stdout));
        try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "diamond-warm.json"));
        try testing.expect(!w.exists("out"));
    }
}

test "typed entry roots revalidate overridden role paths while retaining cached ordinary schemes" {
    // PREPARE: source/public metadata is cached before changing a path only.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    _ = try canonical(&w, "initial.json", &.{});
    const key = try entryFor(&w);
    const bytes = try w.read(key);
    const manifest = try w.read("platform/beni.json");
    const changed = try std.mem.replaceOwned(u8, w.arena.allocator(), manifest, "\"path\": [\"message\"]", "\"path\": [\"missing\\nfield\"]");
    try testing.expect(!std.mem.eql(u8, manifest, changed));
    try w.write("platform/beni.json", changed);
    // EXECUTE / VERIFY OUTPUT: new Plan role, old immutable type artifact.
    const result = try run(&w, "override.json", &.{});
    const graph = try typed(result.stdout);
    try testing.expect(std.mem.indexOf(u8, graph, "path=\"missing\\nfield\" shape_mismatch") != null);
    try testing.expect(std.mem.indexOf(u8, graph, "path=\"message\"") == null);
    try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "override.json"));
    // VERIFY SIDE EFFECTS: no source recheck/artifact rewrite for a role-only change.
    try testing.expectEqualStrings(bytes, try w.read(key));
    try w.write("platform/beni.json", manifest);
    try testing.expectEqual(@as(u64, 0), try canonical(&w, "restored-role.json", &.{}));
}

const expected_type_message =
    \\Something is off with the body of this definition:
    \\
    \\The body is:
    \\
    \\    String
    \\
    \\But the type annotation says it should be:
    \\
    \\    Int
    \\
    \\Hint: to read a number out of text, use `String.toInt` or `String.toFloat`.
    \\
;

test "typed entry roots never reuse clean metadata on source error and restore the old valid cache afterward" {
    // PREPARE
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    _ = try canonical(&w, "valid.json", &.{});
    const original_source = try w.read("Main.beni");
    const key = try entryFor(&w);
    const original_entry = try w.read(key);
    try w.write("Main.beni", "pub broken : Int\nbroken = \"wrong\"\n");
    const diagnostic = @import("diagnostic");
    const expected = [_]diagnostic.Diagnostic{.{
        .code = .type_mismatch,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 2, .col = 10 }, .end = .{ .line = 2, .col = 17 } },
        .title = "TYPE MISMATCH",
        .message = expected_type_message,
    }};
    // EXECUTE / VERIFY OUTPUT: source failure prints no stale/usable-empty role proof.
    for (0..2) |_| {
        const result = try w.run(&.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "--self-profile=error.json", "Main.beni" });
        try testing.expectEqual(@as(u8, 1), result.exit_code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &expected), result.diagnostics);
        try testing.expectEqual(@as(u64, 1), try moduleChecks(&w, "error.json"));
        try testing.expectEqualStrings(original_entry, try w.read(key));
    }
    // VERIFY SIDE EFFECTS: restoring source may reuse its previous valid cached evidence.
    try w.write("Main.beni", original_source);
    try testing.expectEqual(@as(u64, 0), try canonical(&w, "restored.json", &.{}));
    try testing.expect(!w.exists("out"));
}

test "typed entry roots distinguish complete empty cached selection from absent metadata before expanding kinds" {
    // PREPARE: no entryKinds publication request, but all source heads exist.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const manifest = try w.read("platform/beni.json");
    const start = std.mem.indexOf(u8, manifest, "\"entryKinds\":") orelse return error.MissingKinds;
    try w.write("platform/beni.json", try std.fmt.allocPrint(w.arena.allocator(), "{s}\"entryKinds\": []}}\n", .{manifest[0..start]}));
    const empty = try w.run(&.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "--self-profile=empty.json", "Main.beni" });
    try clean(empty);
    _ = try beforeSource(empty.stdout);
    const key = try entryFor(&w);
    const before = try w.read(key);
    const sidecar = word(before, 40);
    const columns = word(before, sidecar + 12);
    const column = sidecar + 16 + (columns - 5) * 8;
    const roots = sidecar + word(before, column);
    // VERIFY OUTPUT: an explicit complete-empty header was installed, not 0 bytes.
    try testing.expectEqual(@as(u32, 24), word(before, column + 4));
    try testing.expectEqualStrings("BENIENT\x00", before[roots..][0..8]);
    try testing.expectEqual(@as(u32, 1), word(before, roots + 8));
    try testing.expectEqual(@as(u32, 0), word(before, roots + 12));
    try testing.expectEqual(@as(u32, 0), word(before, roots + 16));
    try testing.expectEqual(@as(u32, 0), word(before, roots + 20));
    // EXECUTE: this formerly complete empty proof is insufficient for new selectors.
    try w.write("platform/beni.json", manifest);
    try testing.expectEqual(@as(u64, 1), try canonical(&w, "empty-expanded.json", &.{}));
    try testing.expectEqual(@as(u64, 0), try canonical(&w, "empty-expanded-warm.json", &.{}));
    // VERIFY SIDE EFFECTS
    try testing.expectEqualSlices(u8, publicRecord(before), publicRecord(try w.read(key)));
    try testing.expect(!w.exists("out"));
}

test "typed entry roots distinguish same-spelled nominal heads in another ordinary module" {
    // PREPARE: identical short name Program, different actual defining identity.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const source = try w.read("Main.beni");
    try w.write("Twin.beni", "pub type Program\n    = Program\n");
    try w.write("Main.beni", try std.fmt.allocPrint(w.arena.allocator(), "import Twin\n{s}\n\nshadow = Twin.Program\n", .{source}));
    // EXECUTE / VERIFY OUTPUT: every existing root is byte-identical; no shadow candidate.
    try testing.expect(try canonical(&w, "shadow-cold.json", &.{"Twin.beni"}) > 0);
    try testing.expectEqual(@as(u64, 0), try canonical(&w, "shadow-warm.json", &.{ "Twin.beni", "--jobs=8" }));
    // VERIFY SIDE EFFECTS
    try testing.expect(!w.exists("out"));
}

const imported_source =
    \\import Worker
    \\
    \\
    \\type alias Hidden a =
    \\    { message : List a }
    \\
    \\
    \\pub value : Worker.Program (Hidden a) ⊤
    \\value = Worker.make { message = [] } ⊤
    \\
;

test "typed entry roots retain private dependency alias arguments and refresh them when public scheme bodies change" {
    // PREPARE: the root must preserve a private alias obtained through an interface.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("Lib.beni", imported_source);
    try w.write("Main.beni", try std.fmt.allocPrint(w.arena.allocator(), "import Lib\n{s}\n\nimported = Lib.value\n", .{try w.read("Main.beni")}));
    const initial = try run(&w, "import-cold.json", &.{ "Lib.beni", "--roundtrip-dispatch", "--roundtrip-interfaces" });
    const graph = try typed(initial.stdout);
    try testing.expectEqual(@as(usize, 2), occurrences(graph, " app Lib.Hidden body="));
    try testing.expectEqual(@as(usize, 1), occurrences(graph, "  typed-candidate value decl=1 scheme=0\n"));
    try testing.expectEqual(@as(usize, 1), occurrences(graph, "  typed-candidate imported decl=16 scheme=11\n"));
    const warm = try run(&w, "import-warm.json", &.{ "Lib.beni", "--jobs=8" });
    try testing.expectEqualStrings(graph, try typed(warm.stdout));
    try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "import-warm.json"));
    // EXECUTE: the dependency's canonical alias body changes, retaining its nominal identity.
    const body = try std.mem.replaceOwned(u8, w.arena.allocator(), imported_source, "message : List a", "message : List a × List a");
    const changed = try std.mem.replaceOwned(u8, w.arena.allocator(), body, "message = []", "message = ( [], [] )");
    try w.write("Lib.beni", changed);
    const updated = try run(&w, "import-updated.json", &.{"Lib.beni"});
    const next = try typed(updated.stdout);
    try testing.expectEqual(@as(u64, 2), try moduleChecks(&w, "import-updated.json"));
    try testing.expectEqual(@as(usize, 2), occurrences(next, " app Lib.Hidden body="));
    try testing.expectEqual(occurrences(graph, " tuple ") + 2, occurrences(next, " tuple "));
    const updated_warm = try run(&w, "import-updated-warm.json", &.{"Lib.beni"});
    try testing.expectEqualStrings(next, try typed(updated_warm.stdout));
    try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "import-updated-warm.json"));
    // VERIFY SIDE EFFECTS: returning to the earlier valid dependency reuses its cache.
    try w.write("Lib.beni", imported_source);
    const restored = try run(&w, "import-restored.json", &.{"Lib.beni"});
    try testing.expectEqualStrings(graph, try typed(restored.stdout));
    try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "import-restored.json"));
    try testing.expect(!w.exists("out"));
}

test "typed entry roots mirror the existing checked bare module type spelling before selecting publication" {
    // PREPARE: existing validator resolves Program as Program.Program.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("platform/Program.beni", "pub type Program\n    = Program\n\n\npub make : ⊤ → Program\nmake _ = Program\n");
    try w.write("platform/ProgramRt.beni", "import Program\n\n\npub run : Program.Program → ⊤\nrun _ = ⊤\n");
    try w.write("Main.beni", try std.fmt.allocPrint(w.arena.allocator(), "import Program\n{s}\n\nshort = Program.make ⊤\n", .{try w.read("Main.beni")}));
    const manifest = try w.read("platform/beni.json");
    const close = std.mem.lastIndexOf(u8, manifest, "]}") orelse return error.MissingKindsEnd;
    try w.write("platform/beni.json", try std.fmt.allocPrint(w.arena.allocator(), "{s}, {{\"programType\":\"Program\",\"realm\":\"node\",\"runtime\":\"ProgramRt\",\"constructors\":[],\"launches\":[],\"parameters\":[]}}]}}\n", .{manifest[0..close]}));
    // EXECUTE / VERIFY OUTPUT: full contract succeeds and real ordinary root exists.
    const cold = try run(&w, "bare-cold.json", &.{});
    const graph = try typed(cold.stdout);
    try testing.expectEqual(@as(usize, 1), occurrences(graph, "  typed-candidate short decl=16 scheme=11\n"));
    try testing.expectEqual(@as(usize, 1), occurrences(graph, " platform Program.Program\n"));
    const warm = try run(&w, "bare-warm.json", &.{"--jobs=8"});
    try testing.expectEqualStrings(graph, try typed(warm.stdout));
    try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "bare-warm.json"));
    // VERIFY SIDE EFFECTS
    try testing.expect(!w.exists("out"));
}

test "typed entry roots recover an insufficient embedded pack from repaired directory metadata on warm checks" {
    // PREPARE: shipped Node has no entryKinds, so its packed root artifact is empty.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("platform/NodeRt.beni", "import Node\n\n\npub run : Node.Program → ⊤\nrun _ = ⊤\n");
    try w.write("Main.beni", try std.fmt.allocPrint(w.arena.allocator(), "import Node\n{s}\n\npacked = Node.done\n", .{try w.read("Main.beni")}));
    const manifest = try w.read("platform/beni.json");
    const close = std.mem.lastIndexOf(u8, manifest, "]}") orelse return error.MissingKindsEnd;
    try w.write("platform/beni.json", try std.fmt.allocPrint(w.arena.allocator(), "{s}, {{\"programType\":\"Node.Program\",\"realm\":\"node\",\"runtime\":\"NodeRt\",\"constructors\":[],\"launches\":[],\"parameters\":[]}}],\"platforms\":[\"node\"],\"reexports\":[\"Node\"]}}\n", .{manifest[0..close]}));
    const cold = try run(&w, "pack-cold.json", &.{});
    const graph = try typed(cold.stdout);
    try testing.expect(std.mem.indexOf(u8, graph, "typed-module platform:Node schema=1 present=true\n") != null);
    try testing.expect(try moduleChecks(&w, "pack-cold.json") > 1);
    // EXECUTE / VERIFY OUTPUT: reject the old pack, install eligible directory entry.
    const warm = try run(&w, "pack-warm.json", &.{"--jobs=8"});
    try testing.expectEqualStrings(graph, try typed(warm.stdout));
    try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "pack-warm.json"));
    const again = try run(&w, "pack-again.json", &.{});
    try testing.expectEqualStrings(graph, try typed(again.stdout));
    try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "pack-again.json"));
    // VERIFY SIDE EFFECTS
    try testing.expect(!w.exists("out"));
}

const PackWitness = struct { key: [16]u8, roots: []const u8 };
fn packWitness(bytes: []const u8) !PackWitness {
    try testing.expectEqualStrings("BENIPACK", bytes[0..8]);
    const count = word(bytes, 12);
    var found: ?PackWitness = null;
    for (0..count) |i| {
        const at = 16 + i * 28;
        if (bytes[at] != 0) continue; // public pack kind entry=0
        const entry = bytes[word(bytes, at + 20)..][0..word(bytes, at + 24)];
        try testing.expectEqualStrings("BENICAC\x00", entry[0..8]);
        const sidecar = word(entry, 40);
        try testing.expectEqual(@as(u32, 22), word(entry, sidecar + 8));
        const columns = word(entry, sidecar + 12);
        const column = sidecar + 16 + (columns - 5) * 8;
        const root_bytes = entry[sidecar + word(entry, column) ..][0..word(entry, column + 4)];
        try testing.expectEqualStrings("BENIENT\x00", root_bytes[0..8]);
        if (word(root_bytes, 12) == 0) continue;
        // Only Base.seed has the selected nominal head; all core is independent.
        try testing.expect(found == null);
        try testing.expectEqual(@as(u32, 1), word(root_bytes, 8));
        try testing.expectEqual(@as(u32, 1), word(root_bytes, 12));
        try testing.expect(word(root_bytes, 16) > 0);
        try testing.expectEqual(@as(u32, 0), word(root_bytes, 20));
        try testing.expectEqual(@as(u32, 1), word(root_bytes, 24));
        try testing.expectEqual(@as(u32, 0), word(root_bytes, 28));
        found = .{ .key = entry[16..32].*, .roots = root_bytes };
    }
    return found orelse error.MissingSelectedPackedRoot;
}

test "typed entry roots pack maker preserves a base declaration selected only by a later registered chain" {
    // PREPARE: ordinary build-tool CLI, never compiler internals in this test.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const maker = try testing.environ.getAlloc(a, "BENI_CORE_PACK_EXE");
    if (maker.len == 0) return error.MissingCorePackTool;
    try w.write("base/beni.json", "{\"platform\":true,\"name\":\"base\"}\n");
    try w.write("base/Base.beni", "pub type Program config state\n    = Program\n\n\npub seed : Program a b\nseed = Program\n");
    try w.write("derived/beni.json", "{\"platform\":true,\"name\":\"derived\",\"platforms\":[\"base\"],\"reexports\":[\"Base\"],\"program\":\"Base.Program\",\"entryKinds\":[{\"programType\":\"Base.Program\",\"realm\":\"node\",\"runtime\":\"DerivedRt\",\"constructors\":[],\"launches\":[],\"parameters\":[{\"index\":0,\"role\":\"wire\",\"path\":[]},{\"index\":1,\"role\":\"local\",\"path\":[]}]}]}\n");
    try w.write("derived/DerivedRt.beni", "import Base\n\n\npub run : Base.Program a b → ⊤\nrun _ = ⊤\n");
    const project = try w.projectPath();
    const base = try std.fs.path.join(a, &.{ project, "base" });
    const derived = try std.fs.path.join(a, &.{ project, "derived" });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPath(testing.io, &buffer);
    const core = try std.fs.path.join(a, &.{ buffer[0..cwd_len], "core" });
    const build_id = "11111111111111111111111111111111";
    // EXECUTE: both registration orders must retain exactly the same selected root.
    const forward = try w.runWith(&.{ core, build_id, "forward.pack", "base", "_platform/base", base, "derived", "_platform/derived", derived }, .{ .exe = maker, .raw_diagnostics = true });
    try clean(forward);
    try testing.expectEqualStrings("", forward.stdout);
    const first = try packWitness(try w.read("forward.pack"));
    const reverse = try w.runWith(&.{ core, build_id, "reverse.pack", "derived", "_platform/derived", derived, "base", "_platform/base", base }, .{ .exe = maker, .raw_diagnostics = true });
    try clean(reverse);
    try testing.expectEqualStrings("", reverse.stdout);
    const second = try packWitness(try w.read("reverse.pack"));
    // VERIFY OUTPUT: full canonical private evidence is invariant, not only row counts.
    try testing.expectEqualSlices(u8, &first.key, &second.key);
    try testing.expectEqualSlices(u8, first.roots, second.roots);
    // VERIFY SIDE EFFECTS
    try testing.expect(!w.exists("out"));
}

test "typed entry consumer keeps validated legacy plans without typed graph or internal diagnostic" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("platform/beni.json", "{\"platform\":true,\"program\":\"Start.Program\"}");
    const dump = try w.run(&.{ "dump", "--stage=entries", "--platform=platform", "Main.beni" });
    try clean(dump);
    const checked = try w.run(&.{ "check", "--entries", "--platform=platform", "Main.beni" });
    try clean(checked);
    try testing.expectEqualStrings(dump.stdout, checked.stdout);
    try testing.expectEqualStrings(
        \\entries schema=1 partial=true discoveryComplete=false inputSupported=false
        \\proofs C=unproved EntryHost=unproved Wire=unproved ownership=unproved constructionEffects=unproved execution=unproved
        \\declaration-liveness absent deferredCuts=false exactCode=false
        \\liveness-counts runs=0 nodes=0
        \\counts templates=0 calls=0 ports=0 launchExports=0 queries=0 facts=0 subscriptions=0 expansions=0 deliveries=0 peakQueue=0
        \\field-work indexRows=0 lookups=0 edges=0 localWalk=0
        \\builder-work shapePorts=0 shapeEdges=0 shapeSelectors=0 metadataRows=0 metadataIndexWork=0 metadataLookups=0 metadataMatches=0
        \\
    , try beforeSource(dump.stdout));
    try testing.expect(!w.exists("out"));
}
