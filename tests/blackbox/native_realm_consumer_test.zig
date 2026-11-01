//! Actual packaged checker -> source builder -> selected realm consumer.
const std = @import("std");
const world = @import("world.zig");
const diagnostic = @import("diagnostic");
const World = world.World;
const testing = std.testing;
const direct = "first _ value =\n    _ = Encoder.new ⊤\n    _ = Evidence.retained\n    value";
fn prepare(w: *World, body: []const u8, extra: []const u8) !void {
    try w.copyTree("tests/fixtures/entry-discovery/basic", "_excluded.");
    try w.copyTree("tests/fixtures/native-realm-consumer", "_excluded.");
    const source = try std.mem.replaceOwned(u8, w.arena.allocator(), try w.read("Main.beni"), "first _ value = value", body);
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{ "import Browser.Host.TextEncoder as Encoder\nimport Evidence\n", source, "\n\n", extra }));
}
fn clean(r: world.Result) !void {
    if (r.exit_code != 0) std.debug.print("{s}\n", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}
fn run(w: *World, trace: []const u8, extra: []const []const u8) !world.Result {
    const a = w.arena.allocator();
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni", "Evidence.beni" });
    try args.appendSlice(a, extra);
    try args.append(a, try std.fmt.allocPrint(a, "--self-profile={s}", .{trace}));
    const r = try w.run(args.items);
    try clean(r);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "native-realm-execution schema=1 proof=source-execution entryComplete=false nativeLowering=false\n") != null);
    return r;
}
fn line(text: []const u8, prefix: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |l| if (std.mem.startsWith(u8, l, prefix)) {
        try testing.expect(found == null);
        found = l;
    };
    return found orelse error.MissingRow;
}
fn word(text: []const u8, key: []const u8) ![]const u8 {
    const at = (std.mem.indexOf(u8, text, key) orelse return error.MissingWord) + key.len;
    const end = std.mem.indexOfScalarPos(u8, text, at, ' ') orelse text.len;
    return text[at..end];
}
fn number(text: []const u8, key: []const u8) !u64 {
    return std.fmt.parseInt(u64, try word(text, key), 10);
}
fn profile(w: *World, trace: []const u8, key: []const u8) !u64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, try w.read(trace), .{});
    defer parsed.deinit();
    for (parsed.value.object.get("traceEvents").?.array.items) |e| {
        const args = e.object.get("args") orelse continue;
        if (args.object.get(key)) |v| return @intCast(v.integer);
    }
    return error.MissingProfileCounter;
}
fn native(text: []const u8, state: []const u8) ![]const u8 {
    const row = try line(text, "  realm-native 0 ");
    try testing.expectEqualStrings(state, try word(row, "state="));
    try testing.expectEqual(@as(u64, 1), try number(row, "decl=")); // Named export new is IFC value1, independently BIR foreign declaration1.
    try testing.expectEqual(@as(u64, 31), try number(row, "allowed="));
    try testing.expectEqualStrings("false", try word(row, "incomplete="));
    try testing.expectEqual(@as(usize, 64), (try word(row, "digest=")).len);
    return row;
}
fn expected(w: *World, r: world.Result, name: []const u8) !void {
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    const data = try std.json.parseFromSlice([]diagnostic.Diagnostic, testing.allocator, try w.read(name), .{});
    defer data.deinit();
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, data.value), r.diagnostics);
    try testing.expect(!w.exists("out"));
}

test "native realm consumer reads actual packaged roots registry seed and original whole core fixture" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, direct, "");
    const r = try run(&w, "cold.json", &.{"--jobs=1"});
    const n = try native(r.stdout, "invoked_checked");
    try testing.expectEqual(@as(u64, 1), try number(n, "checked="));
    try testing.expectEqual(@as(u64, 0), try number(n, "unresolved="));
    const c = try line(r.stdout, "  realm-consumer ");
    for ([_][]const u8{ "sourceReads=", "kindReads=", "runtimeReads=", "ordinaryRows=", "registryReads=", "nativeRows=" }) |key| try testing.expectEqual(@as(u64, 1), try number(c, key));
    const b = try line(r.stdout, "  realm-builder ");
    try testing.expect(try number(b, "modules=") > 10);
    try testing.expect(try number(b, "scopes=") > 100);
    try testing.expectEqual(@as(u64, 1), try number(b, "seedReads="));
    try testing.expectEqual(@as(u64, 1), try number(try line(r.stdout, "  realm-kernel "), "seedReads="));
    const reference = try std.fmt.allocPrint(w.arena.allocator(), "kind=external module={d} value=1", .{try number(n, "module=")});
    try testing.expect(std.mem.indexOf(u8, r.stdout, reference) != null);
    var blocked: usize = 0;
    var rows = std.mem.splitScalar(u8, r.stdout, '\n');
    while (rows.next()) |l| if (std.mem.startsWith(u8, l, "  realm-invocation ") and std.mem.indexOf(u8, l, "source=app:Evidence/blocked@") != null) {
        try testing.expectEqualStrings("residual", try word(l, "class="));
        try testing.expectEqual(try number(n, "exec="), try number(l, "target="));
        blocked += 1;
    };
    try testing.expectEqual(@as(usize, 2), blocked);
    try testing.expectEqual(@as(u64, 2), try profile(&w, "cold.json", "realm_builder_runs"));
    const actual = try profile(&w, "cold.json", "realm_value_field_steps");
    try testing.expect(actual > 0 and actual <= 2 * try number(b, "fieldStepsBound="));
    try testing.expect(std.mem.indexOf(u8, b, "fieldSteps=") == null);
    try testing.expect(!w.exists("out"));
}

test "native realm consumer preserves exact bytes across cold warm jobs roundtrip relocation with actual work profiles" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, direct, "");
    const cold = try run(&w, "cold.json", &.{"--jobs=1"});
    const warm = try run(&w, "warm.json", &.{"--jobs=8"});
    try testing.expectEqualStrings(cold.stdout, warm.stdout);
    try testing.expectEqual(@as(u64, 0), try profile(&w, "warm.json", "modules_checked"));
    const trip = try run(&w, "trip.json", &.{ "--cache-dir=roundtrip", "--roundtrip-interfaces", "--roundtrip-dispatch", "--jobs=8" });
    try testing.expectEqualStrings(cold.stdout, trip.stdout);
    for ([_][]const u8{ "cold.json", "warm.json", "trip.json" }) |trace| {
        try testing.expectEqual(@as(u64, 2), try profile(&w, trace, "realm_builder_runs"));
        const actual = try profile(&w, trace, "realm_value_field_steps");
        try testing.expect(actual > 0 and actual <= 2 * try number(try line(cold.stdout, "  realm-builder "), "fieldStepsBound="));
    }
    const dumped = try w.run(&.{ "dump", "--stage=entries", "--platform=platform", "--self-profile=dump.json", "." });
    try clean(dumped);
    try testing.expectEqualStrings(cold.stdout, dumped.stdout);
    try testing.expectEqual(@as(u64, 2), try profile(&w, "dump.json", "realm_builder_runs"));
    try testing.expect(try profile(&w, "dump.json", "realm_value_field_steps") > 0);
    var moved = try World.init(testing.allocator, testing.io);
    defer moved.deinit();
    try prepare(&moved, direct, "");
    for (try w.listFiles("cache")) |name| {
        const path = try std.fmt.allocPrint(w.arena.allocator(), "cache/{s}", .{name});
        try moved.write(path, try w.read(path));
    }
    try testing.expectEqualStrings(cold.stdout, (try run(&moved, "moved.json", &.{"--jobs=8"})).stdout);
    try testing.expectEqual(@as(u64, 0), try profile(&moved, "moved.json", "modules_checked"));
}

test "native realm consumer retains first class constructor and unused deferred callback without invocation" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    for ([_][]const u8{ "later = Encoder.new\n", "later = λ⊤ → Encoder.new ⊤\n" }, 0..) |extra, i| {
        try prepare(&w, "first _ value =\n    _ = later\n    value", extra);
        const r = try run(&w, try std.fmt.allocPrint(w.arena.allocator(), "deferred-{d}.json", .{i}), &.{});
        const n = try native(r.stdout, "deferred_retained");
        try testing.expectEqual(@as(u64, 0), try number(n, "checked="));
        try testing.expectEqual(@as(u64, 0), try number(n, "possible="));
        try testing.expect(try number(n, "retained=") > 0);
        try testing.expectEqual(@as(u64, @intCast(i)), try number(n, "deferred="));
    }
}

fn withOrder(w: *World, body: []const u8, defs: []const u8, before: bool) !void {
    try prepare(w, body, if (before) "" else defs);
    if (before) {
        const source = try w.read("Main.beni");
        const at = std.mem.indexOf(u8, source, "first :") orelse return error.MissingFirst;
        try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{ source[0..at], defs, "\n\n", source[at..] }));
    }
}

test "native realm consumer possible retained initializer cannot hide behind checked invocation in either declaration order" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const defs = "initialized = Encoder.new ⊤\n\n\nlater = λ⊤ → initialized\n";
    for ([_]bool{ false, true }, 0..) |before, i| {
        try withOrder(&w, "first _ value =\n    _ = Encoder.new ⊤\n    _ = later\n    value", defs, before);
        const r = try run(&w, try std.fmt.allocPrint(w.arena.allocator(), "possible-{d}.json", .{i}), &.{});
        const n = try native(r.stdout, "unresolved");
        try testing.expectEqual(@as(u64, 1), try number(n, "checked="));
        try testing.expectEqual(@as(u64, 1), try number(n, "possible="));
        try testing.expect(std.mem.indexOf(u8, r.stdout, "kind=retained_initializer mode=possible state=unresolved source=app:Main/initialized@") != null);
    }
}

test "native realm consumer unknown callback escape dominates same native checked use in either source order" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const defs = "invoke callback =\n    _ = callback ⊤\n    ⊤\n";
    for ([_]bool{ false, true }, 0..) |before, i| {
        try withOrder(&w, "first _ value =\n    _ = Encoder.new ⊤\n    invoke Encoder.new\n    value", defs, before);
        const r = try run(&w, try std.fmt.allocPrint(w.arena.allocator(), "escape-{d}.json", .{i}), &.{});
        const n = try native(r.stdout, "unresolved");
        try testing.expectEqual(@as(u64, 1), try number(n, "checked="));
        try testing.expect(try number(n, "escapes=") > 0);
        try testing.expect(std.mem.indexOf(u8, r.stdout, "kind=escape state=unresolved") != null);
    }
}

test "native realm consumer known native targets under reached case remain residual instead of checked" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, "first _ value =\n    _ = blocked Yes\n    value", "type Flag = Yes | No\n\n\nblocked flag =\n    case flag of\n        Yes → Encoder.new ⊤\n        No → Encoder.new ⊤\n");
    const r = try run(&w, "blocked.json", &.{});
    const n = try native(r.stdout, "unresolved");
    try testing.expectEqual(@as(u64, 0), try number(n, "checked="));
    try testing.expectEqual(@as(u64, 2), try number(n, "unresolved="));
}

test "native realm consumer keeps opaque aggregate escape partial alongside checked native invocation" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, "first _ value =\n    _ = Encoder.new ⊤\n    consume { callback = Encoder.new }\n    value", "consume box =\n    _ = (box.callback) ⊤\n    ⊤\n");
    const r = try run(&w, "aggregate.json", &.{});
    const n = try native(r.stdout, "invoked_checked");
    try testing.expectEqual(@as(u64, 1), try number(n, "checked="));
    try testing.expect(std.mem.indexOf(u8, r.stdout, "useCoverage=partial") != null);
    try testing.expect(try number(try line(r.stdout, "  realm-consumer "), "unattributedEscapes=") > 0);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "native=4294967295") != null);
}

test "native realm inspection keeps actual build public contract physical shadow and unrelated foreign refusal" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, direct, "");
    _ = try run(&w, "positive.json", &.{});
    try expected(&w, try w.run(&.{ "build", "--platform=platform", "--out=out", "Main.beni", "Evidence.beni" }), "pending-native.json");
    try expected(&w, try w.run(&.{ "check", "--platform=platform", "Main.beni", "Evidence.beni" }), "pending-native.json");
    try w.write("core/Browser/Host/TextEncoder.beni", try std.Io.Dir.cwd().readFileAlloc(w.io, "tests/fixtures/native-callable/TextEncoder.beni", w.arena.allocator(), .limited(65536)));
    try expected(&w, try w.run(&.{ "check", "--entries", "--platform=platform", "Main.beni", "Evidence.beni", "core/Browser/Host/TextEncoder.beni" }), "physical-sibling.json");
    try w.write("platform/Unrelated.beni", "pub foreign impure absent : ⊤ → ⊤\n");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{ "import Unrelated\n", try w.read("Main.beni") }));
    try expected(&w, try w.run(&.{ "check", "--entries", "--platform=platform", "Main.beni", "Evidence.beni" }), "unrelated-sibling.json");
}

test "native realm consumer legacy selection and source error repair never reuse a complete entry" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, direct, "");
    const manifest = try w.read("platform/beni.json");
    try w.write("platform/beni.json", "{\"platform\":true,\"program\":\"Start.Program\"}");
    const legacy = try run(&w, "legacy.json", &.{});
    try testing.expect(std.mem.indexOf(u8, legacy.stdout, "realm-selection state=missing_selection realm=unavailable") != null);
    try w.write("platform/beni.json", manifest);
    const good = try run(&w, "good.json", &.{});
    const source = try w.read("Main.beni");
    try w.write("Main.beni", "pub broken : ⊤\nbroken = λx → x\n");
    const bad = try w.run(&.{ "check", "--entries", "--platform=platform", "Main.beni", "Evidence.beni" });
    try testing.expectEqual(@as(u8, 1), bad.exit_code);
    try testing.expectEqualStrings("", bad.stdout);
    try testing.expectEqual(@as(usize, 1), bad.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.type_mismatch, bad.diagnostics[0].code);
    try w.write("Main.beni", source);
    const repaired = try run(&w, "repaired.json", &.{});
    try testing.expectEqualStrings(good.stdout, repaired.stdout);
    try testing.expectEqual(@as(u64, 0), try profile(&w, "repaired.json", "modules_checked"));
}

test "native getter external value index stays distinct from original foreign declaration" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, "first _ value =\n    encoder = Encoder.new ⊤\n    _ = Encoder.encoding encoder\n    value", "");
    const r = try run(&w, "getter-index.json", &.{"--jobs=1"});
    const module = try number(try line(r.stdout, "  realm-native 0 "), "module=");
    // Actual named Interface assertions live in Session.checkedNativeCandidate:
    // encoding is value0, scheme1, and BIR foreign declaration2. These namespaces
    // must not be confused even though new now happens to be value1/decl1.
    const value_index: u32 = 0;
    const declaration: u32 = 2;
    try testing.expect(value_index != declaration);
    const reference = try std.fmt.allocPrint(w.arena.allocator(), "kind=external module={d} value={d}", .{ module, value_index });
    const scope = try std.fmt.allocPrint(w.arena.allocator(), "  realm-scope {d}:1 decl={d} source=4294967295 kind=foreign", .{ module, declaration });
    try testing.expect(std.mem.indexOf(u8, r.stdout, reference) != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, scope) != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "source=core:Browser.Host.TextEncoder/encoding@4294967295") != null);
    try testing.expect(!w.exists("out"));
}
