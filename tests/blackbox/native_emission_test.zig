//! Actual ordinary checked native facade, emission, cache and host behavior.
const std = @import("std");
const world = @import("world.zig");
const Host = @import("native_host_fixture");
const World = world.World;
const testing = std.testing;
fn prepare(w: *World, source: ?[]const u8) !void {
    try w.copyTree("tests/fixtures/native-emission", "_excluded.");
    if (source) |body| try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{ "import Browser.Host.TextEncoder as Encoder\nimport Start\n", body }));
    const observer = try Host.generate(testing.allocator, false);
    defer testing.allocator.free(observer);
    try w.write("observe.mjs", observer);
}
fn clean(r: world.Result) !void {
    if (r.exit_code != 0) std.debug.print("{s}\n", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}
fn build(w: *World, release: bool, extra: []const []const u8) !world.Result {
    var args: std.ArrayList([]const u8) = .empty;
    const a = w.arena.allocator();
    try args.appendSlice(a, &.{ "build", "--platform=platform", "--out=out", "--cache-dir=cache", "Main.beni" });
    if (release) try args.append(a, "--release");
    try args.appendSlice(a, extra);
    return w.run(args.items);
}
fn runtime(w: *World, expected: []const u8) !void {
    const r = try w.runNode(&.{ "--import=./observe.mjs", "out/_main.mjs" });
    try clean(r);
    try testing.expectEqualStrings(expected, r.stdout);
}
test "native emission ordinary direct constructor runs actual host in dev and release" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, null);
    try clean(try w.run(&.{ "check", "--platform=platform", "--cache-dir=cache", "Main.beni" }));
    for ([_]bool{ false, true }) |release| {
        try clean(try build(&w, release, &.{}));
        try runtime(&w, "get\nconstruct\n");
    }
}
test "native emission known returned first class facade preserves effectful Unit exactly once" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w,
        \\factory _ = Encoder.new
        \\argument _ =
        \\    _ = Encoder.new ⊤
        \\    ⊤
        \\main : Start.Program
        \\main =
        \\    _ = (factory ⊤) (argument ⊤)
        \\    Start.Program
        \\
    );
    for ([_]bool{ false, true }) |release| {
        try clean(try build(&w, release, &.{}));
        try runtime(&w, "get\nconstruct\nget\nconstruct\n");
    }
}
test "native emission evaluated global initializer runs once despite repeated reads" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w,
        \\encoded : Encoder.TextEncoder
        \\encoded = Encoder.new ⊤
        \\main : Start.Program
        \\main =
        \\    _ = encoded
        \\    _ = encoded
        \\    Start.Program
        \\
    );
    for ([_]bool{ false, true }) |release| {
        try clean(try build(&w, release, &.{}));
        try runtime(&w, "get\nconstruct\n");
    }
}
test "native emission unexpected host constructor defect remains an actual runtime failure" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, null);
    const observer = try Host.generate(testing.allocator, true);
    defer testing.allocator.free(observer);
    try w.write("observe.mjs", observer);
    try clean(try build(&w, false, &.{}));
    const r = try w.runNode(&.{ "--import=./observe.mjs", "out/_main.mjs" });
    try testing.expect(r.exit_code != 0);
    try testing.expectEqualStrings("get\nconstruct\n", r.stdout);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "native host defect") != null);
}
test "native emission final Reach deferred obligation refuses both check and build with no output" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w,
        \\deferred : ⊤ → Encoder.TextEncoder
        \\deferred _ = Encoder.new ⊤
        \\main : Start.Program
        \\main =
        \\    _ = deferred
        \\    Start.Program
        \\
    );
    const checked = try w.run(&.{ "check", "--platform=platform", "Main.beni" });
    const built = try build(&w, false, &.{});
    for ([_]world.Result{ checked, built }) |r| {
        try testing.expectEqual(@as(u8, 1), r.exit_code);
        try testing.expectEqualStrings("", r.stdout);
        try testing.expect(r.diagnostics.len != 0);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "deferred") != null);
    }
    try testing.expect(!w.exists("out/_main.mjs"));
}

fn counter(w: *World, file: []const u8, key: []const u8) !u64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, try w.read(file), .{});
    defer parsed.deinit();
    for (parsed.value.object.get("traceEvents").?.array.items) |e| {
        const args = e.object.get("args") orelse continue;
        if (args.object.get(key)) |v| return @intCast(v.integer);
    }
    return error.MissingProfileCounter;
}
test "native emission first class alias and checked formal Unit preserve exact constructor identity" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w,
        \\forwarding = Encoder.new
        \\make argument = forwarding argument
        \\main : Start.Program
        \\main =
        \\    _ = make ⊤
        \\    Start.Program
        \\
    );
    for ([_]bool{ false, true }) |release| {
        try clean(try build(&w, release, &.{}));
        try runtime(&w, "get\nconstruct\n");
    }
}
test "native emission warm jobs roundtrip relocation revalidate authority before reuse" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, null);
    try clean(try build(&w, false, &.{ "--jobs=1", "--self-profile=cold.json" }));
    const files = try w.listFiles("out");
    const a = w.arena.allocator();
    const bytes = try a.alloc([]const u8, files.len);
    for (files, bytes) |name, *saved| saved.* = try w.read(try std.fmt.allocPrint(a, "out/{s}", .{name}));
    try clean(try build(&w, false, &.{ "--jobs=8", "--self-profile=warm.json" }));
    try testing.expectEqual(@as(u64, 0), try counter(&w, "warm.json", "modules_checked"));
    try testing.expect(try counter(&w, "warm.json", "realm_builder_runs") > 0);
    try testing.expect(try counter(&w, "warm.json", "native_exposure_nodes") > 0);
    for (files, bytes) |name, saved| try testing.expectEqualStrings(saved, try w.read(try std.fmt.allocPrint(a, "out/{s}", .{name})));
    try runtime(&w, "get\nconstruct\n");
    try clean(try build(&w, false, &.{ "--cache-dir=roundtrip", "--roundtrip-interfaces", "--roundtrip-dispatch", "--jobs=8" }));
    for (files, bytes) |name, saved| try testing.expectEqualStrings(saved, try w.read(try std.fmt.allocPrint(a, "out/{s}", .{name})));
    var moved = try World.init(testing.allocator, testing.io);
    defer moved.deinit();
    try prepare(&moved, null);
    for (try w.listFiles("cache")) |name| {
        const path = try std.fmt.allocPrint(a, "cache/{s}", .{name});
        try moved.write(path, try w.read(path));
    }
    try clean(try build(&moved, false, &.{ "--jobs=8", "--self-profile=moved.json" }));
    try testing.expectEqual(@as(u64, 0), try counter(&moved, "moved.json", "modules_checked"));
    try testing.expect(try counter(&moved, "moved.json", "realm_builder_runs") > 0);
    for (files, bytes) |name, saved| try testing.expectEqualStrings(saved, try moved.read(try std.fmt.allocPrint(a, "out/{s}", .{name})));
    try runtime(&moved, "get\nconstruct\n");
}
test "native emission cached valid tree cannot authorize new deferred escape or write output" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, null);
    try clean(try build(&w, false, &.{}));
    const files = try w.listFiles("out");
    const a = w.arena.allocator();
    const bytes = try a.alloc([]const u8, files.len);
    for (files, bytes) |name, *saved| saved.* = try w.read(try std.fmt.allocPrint(a, "out/{s}", .{name}));
    try w.write("Main.beni",
        \\import Browser.Host.TextEncoder as Encoder
        \\import Start
        \\deferred : ⊤ → Encoder.TextEncoder
        \\deferred _ = Encoder.new ⊤
        \\main : Start.Program
        \\main =
        \\    _ = deferred
        \\    Start.Program
        \\
    );
    const refused = try build(&w, false, &.{"--self-profile=refused.json"});
    try testing.expectEqual(@as(u8, 1), refused.exit_code);
    try testing.expectEqualStrings("", refused.stdout);
    try testing.expect(std.mem.indexOf(u8, refused.stderr, "deferred") != null);
    try testing.expectEqual(@as(u64, 0), try counter(&w, "refused.json", "modules_lowered"));
    try testing.expectEqual(@as(u64, 0), try counter(&w, "refused.json", "emit_units_embedded"));
    for (files, bytes) |name, saved| try testing.expectEqualStrings(saved, try w.read(try std.fmt.allocPrint(a, "out/{s}", .{name})));
    try testing.expectEqual(files.len, (try w.listFiles("out")).len);
}

test "native emission same byte physical sibling and generated supplier transitions never reuse authority" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, null);
    const source = try std.Io.Dir.cwd().readFileAlloc(w.io, "tests/fixtures/native-callable/TextEncoder.beni", w.arena.allocator(), .limited(65536));
    const sibling = try Host.completeSibling(testing.allocator);
    defer testing.allocator.free(sibling);
    const physical = "core/Browser/Host/TextEncoder.beni";
    const js = "core/Browser/Host/TextEncoder.js";
    try w.write(physical, source);
    try w.write(js, sibling);
    try clean(try build(&w, false, &.{ physical, "--self-profile=physical.json" }));
    try runtime(&w, "sibling\nget\nconstruct\n");
    try w.tmp.dir.deleteFile(w.io, physical);
    try w.tmp.dir.deleteFile(w.io, js);
    try clean(try build(&w, false, &.{"--self-profile=generated.json"}));
    try testing.expect(try counter(&w, "generated.json", "modules_checked") > 0);
    try testing.expect(try counter(&w, "generated.json", "realm_builder_runs") > 0);
    try runtime(&w, "get\nconstruct\n");
    try w.write(physical, source);
    try w.write(js, sibling);
    try clean(try build(&w, false, &.{ physical, "--self-profile=physical-again.json" }));
    try testing.expectEqual(@as(u64, 0), try counter(&w, "physical-again.json", "realm_builder_runs"));
    try runtime(&w, "sibling\nget\nconstruct\n");
}

test "native getter direct and simple aliases execute real encoding access in dev and release" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w,
        \\main : Start.Program
        \\main =
        \\    encoder = Encoder.new ⊤
        \\    copy = encoder
        \\    getter = Encoder.encoding
        \\    _ = getter copy
        \\    Start.Program
        \\
    );
    const getter = try Host.getterObservation(testing.allocator);
    defer testing.allocator.free(getter);
    const constructor = try Host.generate(testing.allocator, false);
    defer testing.allocator.free(constructor);
    // Install real prototype getter observation before observing global lookup.
    try w.write("observe.mjs", try std.mem.concat(w.arena.allocator(), u8, &.{ getter, constructor }));
    for ([_]bool{ false, true }) |release| {
        try clean(try build(&w, release, &.{}));
        try runtime(&w, "get\nconstruct\nutf-8\n");
    }
}
test "native getter rejects ordinary checked Js to laundering before emission" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w,
        \\import Forged
        \\main : Start.Program
        \\main =
        \\    _ = Encoder.new ⊤
        \\    _ = Encoder.encoding Forged.bad
        \\    Start.Program
        \\
    );
    try w.write("platform/Forged.beni",
        \\import Js
        \\import Browser.Host.TextEncoder as Encoder
        \\pub bad : Encoder.TextEncoder
        \\bad = Js.to Js.null
        \\
    );
    // The privileged platform cast is ordinarily checked, not rejected by the
    // APP Js fence. Inspection performs that check without granting emission.
    try clean(try w.run(&.{ "check", "--platform=platform", "--entries", "--cache-dir=cache", "Main.beni" }));
    for (0..3) |mode| {
        const result = try build(&w, mode == 2, if (mode == 0) &.{"--no-cache"} else &.{});
        try testing.expectEqual(@as(u8, 1), result.exit_code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expect(result.diagnostics.len != 0);
        for (result.diagnostics) |item| {
            try testing.expectEqual(.not_implemented, item.code);
            try testing.expect(std.mem.indexOf(u8, item.message, "(receiver)") != null);
        }
        try testing.expect(!w.exists("out"));
    }
}

test "native getter unknown returns formal forwarding and aggregate projections remain refused" {
    for ([_][]const u8{
        "make _ = Encoder.new ⊤\nmain : Start.Program\nmain =\n    _ = Encoder.encoding (make ⊤)\n    Start.Program\n",
        "identity x = x\nmain : Start.Program\nmain =\n    _ = Encoder.encoding (identity (Encoder.new ⊤))\n    Start.Program\n",
        "main : Start.Program\nmain =\n    pair = { encoder = Encoder.new ⊤ }\n    _ = Encoder.encoding pair.encoder\n    Start.Program\n",
    }) |body| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try prepare(&w, body);
        try clean(try w.run(&.{ "check", "--platform=platform", "--entries", "Main.beni" }));
        const result = try build(&w, false, &.{});
        try testing.expectEqual(@as(u8, 1), result.exit_code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expect(!w.exists("out"));
        try testing.expect(result.diagnostics.len != 0);
        for (result.diagnostics) |item| try testing.expectEqual(.not_implemented, item.code);
    }
}
test "native getter previously valid output cannot authorize a forged receiver" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w, "main : Start.Program\nmain =\n    _ = Encoder.encoding (Encoder.new ⊤)\n    Start.Program\n");
    try clean(try build(&w, false, &.{}));
    const files = try w.listFiles("out");
    const a = w.arena.allocator();
    const saved = try a.alloc([]const u8, files.len);
    for (files, saved) |name, *bytes| bytes.* = try w.read(try std.fmt.allocPrint(a, "out/{s}", .{name}));
    try w.write("platform/Forged.beni", "import Js\nimport Browser.Host.TextEncoder as Encoder\npub bad : Encoder.TextEncoder\nbad = Js.to Js.null\n");
    try w.write("Main.beni", "import Browser.Host.TextEncoder as Encoder\nimport Start\nimport Forged\nmain : Start.Program\nmain =\n    _ = Encoder.encoding Forged.bad\n    Start.Program\n");
    try clean(try w.run(&.{ "check", "--platform=platform", "--entries", "Main.beni" }));
    const result = try build(&w, false, &.{"--self-profile=refused.json"});
    try testing.expectEqual(@as(u8, 1), result.exit_code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqual(@as(u64, 0), try counter(&w, "refused.json", "emit_units_embedded"));
    try testing.expectEqual(@as(u64, 0), try counter(&w, "refused.json", "modules_lowered"));
    for (files, saved) |name, bytes| try testing.expectEqualStrings(bytes, try w.read(try std.fmt.allocPrint(a, "out/{s}", .{name})));
    try testing.expectEqual(files.len, (try w.listFiles("out")).len);
}

test "native getter effectful receiver block evaluates once before member access" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w,
        \\main : Start.Program
        \\main =
        \\    receiver =
        \\        _ = Encoder.new ⊤
        \\        Encoder.new ⊤
        \\    getter = Encoder.encoding
        \\    _ = getter receiver
        \\    Start.Program
        \\
    );
    const getter = try Host.getterObservation(testing.allocator);
    defer testing.allocator.free(getter);
    const constructor = try Host.generate(testing.allocator, false);
    defer testing.allocator.free(constructor);
    try w.write("observe.mjs", try std.mem.concat(w.arena.allocator(), u8, &.{ getter, constructor }));
    for ([_]bool{ false, true }) |release| {
        try clean(try build(&w, release, &.{}));
        try runtime(&w, "get\nconstruct\nget\nconstruct\nutf-8\n");
    }
}

test "native getter implicit dispatch cannot omit receiver evidence in cold warm or release builds" {
    for ([_][]const u8{
        "main : Start.Program\nmain =\n    holder = { read = Encoder.encoding }\n    _ = holder.read (Encoder.new ⊤)\n    Start.Program\n",
        "make _ = Encoder.new ⊤\nmain : Start.Program\nmain =\n    _ = (make ⊤).encoding\n    Start.Program\n",
        "main : Start.Program\nmain =\n    pair = { encoder = Encoder.new ⊤ }\n    _ = pair.encoder.encoding\n    Start.Program\n",
        "import Forged\nmain : Start.Program\nmain =\n    _ = Forged.bad.encoding\n    Start.Program\n",
    }) |body| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try prepare(&w, body);
        try w.write("platform/Forged.beni", "import Js\nimport Browser.Host.TextEncoder as Encoder\npub bad : Encoder.TextEncoder\nbad = Js.to Js.null\n");
        try clean(try w.run(&.{ "check", "--platform=platform", "--entries", "Main.beni" }));
        for (0..3) |mode| {
            const r = try build(&w, mode == 2, if (mode == 0) &.{"--no-cache"} else &.{});
            try testing.expectEqual(@as(u8, 1), r.exit_code);
            try testing.expectEqualStrings("", r.stdout);
            try testing.expect(!w.exists("out"));
            var receiver_refusal = false;
            for (r.diagnostics) |item| {
                if (item.code == .not_implemented and std.mem.indexOf(u8, item.message, "(receiver)") != null) receiver_refusal = true;
            }
            try testing.expect(receiver_refusal);
        }
    }
}

test "native getter implicit direct and alias receivers use the same construction witness" {
    for ([_][]const u8{
        "main : Start.Program\nmain =\n    _ = (Encoder.new ⊤).encoding\n    Start.Program\n",
        "main : Start.Program\nmain =\n    receiver = Encoder.new ⊤\n    copy = receiver\n    _ = copy.encoding\n    Start.Program\n",
    }) |body| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try prepare(&w, body);
        const getter = try Host.getterObservation(testing.allocator);
        defer testing.allocator.free(getter);
        const constructor = try Host.generate(testing.allocator, false);
        defer testing.allocator.free(constructor);
        try w.write("observe.mjs", try std.mem.concat(w.arena.allocator(), u8, &.{ getter, constructor }));
        for ([_]bool{ false, true }) |release| {
            try clean(try build(&w, release, &.{}));
            try runtime(&w, "get\nconstruct\nutf-8\n");
        }
    }
}
