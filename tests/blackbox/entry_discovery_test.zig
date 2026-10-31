//! Compact entry evidence through ordinary checked source and cached artifacts.
//! These tests never enable public worker emission or infer C from source S.
const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

fn prepare(w: *World) !void {
    try w.copyTree("tests/fixtures/entry-discovery/basic", "_expected.");
}
fn clean(result: world.Result) !void {
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
fn inspect(w: *World) ![]const u8 {
    const result = try w.run(&.{ "dump", "--stage=entries", "--platform=platform", "Main.beni" });
    try clean(result);
    try testing.expect(std.mem.startsWith(u8, result.stdout, "entries schema=1 partial=true discoveryComplete=false"));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "proofs C=unproved EntryHost=unproved Wire=unproved ownership=unproved constructionEffects=unproved execution=unproved\n") != null);
    return result.stdout;
}
fn selected(w: *World, text: []const u8, prefix: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(w.arena.allocator());
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) {
        try out.writer.writeAll(line);
        try out.writer.writeByte('\n');
    };
    return out.written();
}
fn replace(w: *World, needle: []const u8, replacement: []const u8) !void {
    try w.write("Main.beni", try std.mem.replaceOwned(u8, w.arena.allocator(), try w.read("Main.beni"), needle, replacement));
}
fn moduleChecks(w: *World, trace: []const u8) !u64 {
    const Event = struct { args: struct { modules_checked: ?u64 = null } = .{} };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read(trace), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.traceEvents) |event| if (event.args.modules_checked) |count| return count;
    return error.MissingCheckCounter;
}

test "compact entries seal helper constructions before alias reads across cache jobs and relocation" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const dump = try inspect(&w);
    try testing.expectEqualStrings(
        \\entry app:0/Main/bar id=758b51ccfd38b2a564ed49138f79f15c ordinary=false kind=1
        \\entry app:0/Main/foo id=d421f09c85ae151b1ab356f818a659c6 ordinary=false kind=1
        \\entry app:0/Main/main id=992ac255a79e2d2f8a9eac007d1e72ba ordinary=true kind=0
        \\
    , try selected(&w, dump, "entry "));
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
    try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
    try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/foo role=0 S=closed source=Main.first\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/bar role=0 S=closed source=Main.second\n") != null);
    const cold = try w.run(&.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "--self-profile=cold.json", "--jobs=1", "Main.beni" });
    try clean(cold);
    try testing.expectEqualStrings(dump, cold.stdout);
    try testing.expect(try moduleChecks(&w, "cold.json") > 0);
    const warm = try w.run(&.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "--self-profile=warm.json", "--jobs=8", "Main.beni" });
    try clean(warm);
    try testing.expectEqualStrings(cold.stdout, warm.stdout);
    try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "warm.json"));
    var relocated = try World.init(testing.allocator, testing.io);
    defer relocated.deinit();
    try prepare(&relocated);
    try testing.expectEqualStrings(dump, try inspect(&relocated));
    const ordinary = try w.run(&.{ "check", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try clean(ordinary);
    try testing.expectEqualStrings("", ordinary.stdout);
    const combined = try w.run(&.{ "check", "--continuations", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try clean(combined);
    try testing.expect(std.mem.startsWith(u8, combined.stdout, "continuations "));
    try testing.expect(std.mem.endsWith(u8, combined.stdout, dump));
}

const captured =
    \\
    \\
    \\wrap f =
    \\    captured = { payload = f }
    \\    λ_ value →
    \\        _ = captured
    \\        value
    \\
    \\
    \\relay f = wrap f
    \\
;
fn addCaptured(w: *World) !void {
    try replace(w, "foo = make first", "foo = make (relay first)");
    try replace(w, "bar = make second", "bar = make (relay second)");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{ try w.read("Main.beni"), captured }));
}

test "compact captured records retain outer actual correlation at one shared relay site" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try addCaptured(&w);
    const dump = try inspect(&w);
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
    try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
    const foo = try selected(&w, dump, "capture-fact app:0/Main/foo ");
    const bar = try selected(&w, dump, "capture-fact app:0/Main/bar ");
    try testing.expect(std.mem.indexOf(u8, foo, "S=static_leaf source=Main.first\n") != null);
    try testing.expect(std.mem.indexOf(u8, foo, "Main.second") == null);
    try testing.expect(std.mem.indexOf(u8, bar, "S=static_leaf source=Main.second\n") != null);
    try testing.expect(std.mem.indexOf(u8, bar, "Main.first") == null);
    // The source allocation/lambda sites themselves are intentionally shared.
    const a = std.mem.indexOf(u8, foo, "W=origin source=").? + "W=origin source=".len;
    const b = std.mem.indexOf(u8, bar, "W=origin source=").? + "W=origin source=".len;
    try testing.expectEqualStrings(foo[a..][0..std.mem.indexOfScalar(u8, foo[a..], '\n').?], bar[b..][0..std.mem.indexOfScalar(u8, bar[b..], '\n').?]);
}

test "compact runtime formal bindings remain subscribed for finite self launch" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("platform/WorkerRt.beni",
        \\import Worker exposing (Program)
        \\
        \\
        \\pub run : Program → ⊤
        \\run program = Worker.open program ⊤
        \\
    );
    const dump = try inspect(&w);
    try testing.expectEqualStrings(
        \\launch app:0/Main/main -> app:0/Main/bar at=Main.begin@62
        \\launch app:0/Main/main -> app:0/Main/foo at=Main.begin@62
        \\launch app:0/Main/foo -> app:0/Main/foo at=WorkerRt.run@5
        \\launch app:0/Main/bar -> app:0/Main/bar at=WorkerRt.run@5
        \\
    , try selected(&w, dump, "launch "));
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
}

fn metric(text: []const u8, name: []const u8) !u64 {
    const at = std.mem.indexOf(u8, text, name) orelse return error.MissingMetric;
    const rest = text[at + name.len ..];
    const end = std.mem.indexOfAny(u8, rest, " \n") orelse return error.MissingMetric;
    return std.fmt.parseInt(u64, rest[0..end], 10);
}
test "compact checked-source diamonds have linear templates edges facts and evaluations" {
    var previous: ?[]const u8 = null;
    var previous_n: u64 = 0;
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const base = try w.read("Main.beni");
    for ([_]u64{ 8, 16, 32, 64 }) |n| {
        var source: std.Io.Writer.Allocating = .init(w.arena.allocator());
        try source.writer.writeAll(try std.mem.replaceOwned(u8, w.arena.allocator(), base, "Worker.open (choose True)", try std.fmt.allocPrint(w.arena.allocator(), "Worker.open (f{d} foo)", .{n})));
        try source.writer.writeAll("\n\nf0 value = value\n");
        for (1..@intCast(n + 1)) |i| try source.writer.print("\n\nf{d} value = if True then f{d} value else f{d} value\n", .{ i, i - 1, i - 1 });
        try w.write("Main.beni", source.written());
        const dump = try inspect(&w);
        const counters = try selected(&w, dump, "counts ");
        if (previous) |old| {
            const delta = n - previous_n;
            const columns = .{ "templates=", "calls=", "ports=", "queries=", "facts=", "subscriptions=", "expansions=", "deliveries=" };
            const slope = [_]u64{ 1, 2, 18, 6, 6, 8, 6, 8 };
            inline for (columns, slope) |column, expected| try testing.expectEqual(delta * expected, try metric(counters, column) - try metric(old, column));
        }
        try testing.expect(try metric(counters, "peakQueue=") <= 32);
        try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
        try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
        previous = counters;
        previous_n = n;
    }
}

fn writeOpaque(w: *World) !void {
    try w.write("platform/Opaque.beni",
        \\pub foreign pure opaqueCallback : ⊤ → (Int, Int → Int)
        \\
        \\
        \\pub foreign impure input : ⊤ → Int
        \\
    );
    try w.write("platform/Opaque.js", @import("entry_fixture_assets").bytes);
    try replace(w, "import Start", "import Opaque\nimport Start");
}

test "compact shared captured record origin does not imply shared static provenance" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try addCaptured(&w);
    try writeOpaque(&w);
    try replace(&w, "relay second", "relay (Opaque.opaqueCallback ⊤)");
    const dump = try inspect(&w);
    const foo = try selected(&w, dump, "capture-fact app:0/Main/foo ");
    const bar = try selected(&w, dump, "capture-fact app:0/Main/bar ");
    try testing.expect(std.mem.indexOf(u8, foo, "S=static_leaf source=Main.first\n") != null);
    try testing.expect(std.mem.indexOf(u8, foo, "unknown_materialization") == null);
    try testing.expect(std.mem.indexOf(u8, bar, "S=unknown_materialization") != null);
    try testing.expect(std.mem.indexOf(u8, bar, "Main.first") == null);
    try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/foo role=0 S=closed") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/bar role=0 S=unproved") != null);
    // Captured native materialization is unproved, not a fabricated runtime
    // input or an identity-wide conversion of every closure to non-static.
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
}

test "compact effective record override ignores replaced opaque field and retains base evaluation" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try writeOpaque(&w);
    try replace(&w, "foo = make first", "foo = Worker.make { base | init = first }");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("Main.beni"),
        \\
        \\
        \\base =
        \\    { init = Opaque.opaqueCallback ⊤
        \\    , start = first
        \\    , handle = λ_ _ value → value
        \\    , stream = λ_ _ _ value → value
        \\    }
        \\
    }));
    const dump = try inspect(&w);
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
    try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/foo role=0 S=closed source=Main.first\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "execution-root app:0/Main/foo evaluated Main.base\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "residual app:0/Main/foo native_flow at=Main.base@") != null);
}

test "compact invocation through formal stays an explicit residual rather than a source refusal" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try replace(&w, "foo = make first", "foo = make (relay first)");
    try replace(&w, "bar = make second", "bar = make (relay second)");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("Main.beni"),
        \\
        \\
        \\invoke f context value = f context value
        \\
        \\
        \\wrap f = λcontext value → invoke f context value
        \\
        \\
        \\relay f = wrap f
        \\
    }));
    const dump = try inspect(&w);
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
    try testing.expect(std.mem.indexOf(u8, dump, "residual app:0/Main/foo higher_order at=Main.invoke@") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "residual app:0/Main/bar higher_order at=Main.invoke@") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/foo role=0 S=closed") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/bar role=0 S=closed") != null);
}

test "compact checked-source capture SCC closes productively and propagates opaque external obligation" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try replace(&w, "foo = make first", "foo = make (cycle first)");
    try replace(&w, "bar = make second", "bar = make (cycle second)");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("Main.beni"),
        \\
        \\
        \\cycle external =
        \\    left context value =
        \\        _ = right
        \\        value
        \\    right context value =
        \\        _ = left
        \\        _ = external
        \\        value
        \\    left
        \\
    }));
    const closed = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, closed, "callback app:0/Main/foo role=0 S=closed") != null);
    try testing.expect(std.mem.indexOf(u8, closed, "callback app:0/Main/bar role=0 S=closed") != null);
    try testing.expectEqualStrings("", try selected(&w, closed, "residual "));
    try writeOpaque(&w);
    try replace(&w, "cycle second", "cycle (Opaque.opaqueCallback ⊤)");
    const unresolved = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, unresolved, "callback app:0/Main/foo role=0 S=closed") != null);
    try testing.expect(std.mem.indexOf(u8, unresolved, "callback app:0/Main/bar role=0 S=unproved") != null);
    const bar = try selected(&w, unresolved, "capture-fact app:0/Main/bar ");
    try testing.expect(std.mem.indexOf(u8, bar, "S=unknown_materialization") != null);
    try testing.expect(std.mem.indexOf(u8, bar, "Main.first") == null);
    try testing.expectEqualStrings("", try selected(&w, unresolved, "not-static "));
}

test "compact checked-source type-growing recursion shares one source template" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try replace(&w, "begin context value =", "begin context value =\n    grow 4 first");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("Main.beni"),
        \\
        \\
        \\grow : Int, a → ⊤
        \\grow depth value =
        \\    if depth == 0 then
        \\        ⊤
        \\    else
        \\        grow (depth - 1) [ value ]
        \\
    }));
    const dump = try inspect(&w);
    try testing.expectEqualStrings("execution-root app:0/Main/main callable Main.grow\n", try selected(&w, dump, "execution-root app:0/Main/main callable Main.grow"));
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
    // The independent checked primitive equality transfer is outside this
    // kernel. It must not mislabel the ordinary recursive call higher-order.
    try testing.expectEqualStrings("residual app:0/Main/main dispatch at=Main.grow@87\n", try selected(&w, dump, "residual "));
}

test "compact mixed bound and unbound origin profiles preserve helper forwarded aliases" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try replace(&w, "bar = make second", "bar = mix False second");
    try replace(&w, "alias2 = alias1", "alias2 = forward alias1");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("Main.beni"),
        \\
        \\
        \\mix flag init = if flag then foo else make init
        \\
        \\
        \\forward program = program
        \\
    }));
    const dump = try inspect(&w);
    try testing.expectEqualStrings(
        \\entry app:0/Main/bar id=758b51ccfd38b2a564ed49138f79f15c ordinary=false kind=1
        \\entry app:0/Main/foo id=d421f09c85ae151b1ab356f818a659c6 ordinary=false kind=1
        \\entry app:0/Main/main id=992ac255a79e2d2f8a9eac007d1e72ba ordinary=true kind=0
        \\
    , try selected(&w, dump, "entry "));
    const foo = try selected(&w, dump, "callback app:0/Main/foo role=0 ");
    const bar = try selected(&w, dump, "callback app:0/Main/bar role=0 ");
    try testing.expectEqualStrings("callback app:0/Main/foo role=0 S=closed source=Main.first\n", foo);
    try testing.expectEqualStrings("callback app:0/Main/bar role=0 S=closed source=Main.second\n", bar);
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
    try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
}

test "compact selected main alias forwards existing canonical Program identity" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try replace(&w, "main : Start.Program\nmain = Start.make (callbacks begin)", "main : Worker.Program\nmain = forward bar");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{ try w.read("Main.beni"), "\n\nforward program = program\n" }));
    const manifest = try std.json.parseFromSlice(std.json.Value, w.arena.allocator(), try w.read("platform/beni.json"), .{});
    var json = manifest.value;
    try json.object.put(w.arena.allocator(), "program", .{ .string = "Worker.Program" });
    var writer: std.Io.Writer.Allocating = .init(w.arena.allocator());
    try std.json.Stringify.value(json, .{}, &writer.writer);
    try w.write("platform/beni.json", writer.written());
    const dump = try inspect(&w);
    try testing.expectEqualStrings("entry app:0/Main/bar id=758b51ccfd38b2a564ed49138f79f15c ordinary=true kind=1\n", try selected(&w, dump, "entry "));
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
    try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
}

test "compact genuine native callback origin remains opaque at its producer" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try writeOpaque(&w);
    try replace(&w, "foo = make first", "foo = make (Opaque.opaqueCallback ⊤)");
    const dump = try inspect(&w);
    const failures = try selected(&w, dump, "not-static ");
    try testing.expect(std.mem.startsWith(u8, failures, "not-static opaque at=Main.foo@"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, failures, "\n"));
    try testing.expectEqualStrings("", try selected(&w, dump, "callback app:0/Main/foo role=0 "));
    try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/bar role=0 S=closed source=Main.second\n") != null);
}

test "compact inspector preserves contract and missing main diagnostics and publishes no stale artifact" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    _ = try inspect(&w);
    try w.write("platform/Rt.beni",
        \\import Start exposing (Program)
        \\
        \\
        \\pub run : Program, Int → ⊤
        \\run _ _ = ⊤
        \\
    );
    const checked = try w.run(&.{ "check", "--platform=platform", "Main.beni" });
    const inspected = try w.run(&.{ "check", "--entries", "--platform=platform", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expectEqual(@as(u8, 1), inspected.exit_code);
    try testing.expectEqualStrings("", checked.stdout);
    try testing.expectEqualStrings("", inspected.stdout);
    try testing.expect(checked.diagnostics.len > 0);
    try testing.expectEqualDeep(checked.diagnostics, inspected.diagnostics);
    // A clean, fresh Emitter finds main after contract validation. The normal
    // build is the diagnostic authority, not a duplicate inspector lookup.
    try prepare(&w);
    try replace(&w, "main : Start.Program\nmain = Start.make (callbacks begin)", "program : Start.Program\nprogram = Start.make (callbacks begin)");
    const built = try w.run(&.{ "build", "--platform=platform", "--out=out", "Main.beni" });
    const missing = try w.run(&.{ "check", "--entries", "--platform=platform", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), built.exit_code);
    try testing.expectEqual(@as(u8, 1), missing.exit_code);
    try testing.expectEqualStrings("", built.stdout);
    try testing.expectEqualStrings("", missing.stdout);
    try testing.expect(built.diagnostics.len > 0);
    try testing.expectEqualDeep(built.diagnostics, missing.diagnostics);
    try testing.expect(!w.exists("out/_main.mjs"));
}

test "compact inspector flags retain usage and uncached dump boundaries" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const cases = [_]struct { args: []const []const u8, stderr: []const u8 }{
        .{ .args = &.{ "check", "--entries", "Main.beni" }, .stderr = "beni: --entries requires --platform\n" },
        .{ .args = &.{ "check", "--continuations", "--entries", "Main.beni" }, .stderr = "beni: --entries requires --platform\n" },
        .{ .args = &.{ "dump", "--stage=entries", "Main.beni" }, .stderr = "beni: --stage=entries requires --platform\n" },
    };
    for (cases) |case| {
        const result = try w.runWith(case.args, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 2), result.exit_code);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expectEqualStrings(case.stderr, result.stderr);
    }
    const old = try w.runWith(&.{ "dump", "--stage=continuations", "--platform=platform", "--cache-dir=cache", "Main.beni" }, .{ .raw_diagnostics = true });
    const current = try w.runWith(&.{ "dump", "--stage=entries", "--platform=platform", "--cache-dir=cache", "Main.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 2), old.exit_code);
    try testing.expectEqual(@as(u8, 2), current.exit_code);
    try testing.expectEqualStrings("", old.stdout);
    try testing.expectEqualStrings("", current.stdout);
    try testing.expectEqualStrings(old.stderr, current.stderr);
    try testing.expect(!w.exists("cache"));
}

test "compact conservative liveness retains materialized function bodies without executing their launches" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try replace(&w, "begin context value =", "begin context value =\n    _ = ordinary");
    try replace(&w, "Worker.open (choose True)", "Worker.open foo");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("Main.beni"),
        \\
        \\
        \\dormant context value =
        \\    Worker.open bar ⊤
        \\    value
        \\
        \\
        \\ordinary = dormant
        \\
    }));
    const dump = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, dump, "declaration-liveness conservative deferredCuts=false exactCode=false\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "live conservative app:0/Main/main decl Main.dormant\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "live conservative app:0/Main/main decl Main.bar\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "live conservative app:0/Main/main decl Main.second\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "execution-root app:0/Main/main evaluated Main.ordinary\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "execution-root app:0/Main/main callable Main.dormant\n") == null);
    try testing.expect(std.mem.indexOf(u8, dump, "launch app:0/Main/main -> app:0/Main/foo ") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "launch app:0/Main/main -> app:0/Main/bar ") == null);
    try testing.expectEqualStrings("", try selected(&w, dump, "entry app:0/Main/bar "));
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
    try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
}

test "compact inspector leaves legacy platforms explicitly unsupported without source refusal" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("platform/beni.json", "{\"platform\":true,\"program\":\"Start.Program\"}");
    const dump = try inspect(&w);
    try testing.expect(std.mem.startsWith(u8, dump, "entries schema=1 partial=true discoveryComplete=false inputSupported=false\n"));
    try testing.expectEqualStrings("", try selected(&w, dump, "entry "));
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
    try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
}

test "compact checked-source wide records query every outer and inner field with linear indexed work" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const base = try w.read("Main.beni");
    var previous: ?[]const u8 = null;
    var previous_n: u64 = 0;
    var prior_step: [4]u64 = @splat(0);
    var prior_width: u64 = 0;
    for ([_]u64{ 8, 16, 32, 64 }) |n| {
        var source: std.Io.Writer.Allocating = .init(w.arena.allocator());
        try source.writer.writeAll(try std.mem.replaceOwned(u8, w.arena.allocator(), base, "main = Start.make (callbacks begin)", "main = Start.make (callbacks (select ⊤))"));
        try source.writer.writeAll("\n\nwide =\n    { ");
        for (0..@intCast(n)) |i| {
            if (i != 0) try source.writer.writeAll("    , ");
            try source.writer.print("f{d} = {{ payload = first }}\n", .{i});
        }
        try source.writer.writeAll("    }\n\n\nselect ⊤ =\n");
        for (0..@intCast(n)) |i| try source.writer.print("    a{d} = wide.f{d}.payload\n", .{ i, i });
        try source.writer.writeAll("    λ_ value →\n");
        for (0..@intCast(n)) |i| try source.writer.print("        _ = a{d}\n", .{i});
        try source.writer.writeAll("        value\n");
        try w.write("Main.beni", source.written());
        const dump = try inspect(&w);
        try testing.expectEqual(@as(usize, @intCast(n)), std.mem.count(u8, try selected(&w, dump, "capture app:0/Main/main role=0 "), "\n"));
        try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
        try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
        const counters = try selected(&w, dump, "field-work ");
        try testing.expect(try metric(counters, "lookups=") >= 2 * n);
        try testing.expect(try metric(counters, "lookups=") <= 20 * n + 200);
        const names = .{ "indexRows=", "lookups=", "edges=", "localWalk=" };
        if (previous) |old| {
            const width = n - previous_n;
            var step: [4]u64 = undefined;
            inline for (names, 0..) |name, i| {
                step[i] = try metric(counters, name) - try metric(old, name);
                if (prior_width != 0) try testing.expectEqual(prior_step[i] * width, step[i] * prior_width);
            }
            try testing.expectEqual(2 * width, step[0]);
            prior_step = step;
            prior_width = width;
        }
        previous = counters;
        previous_n = n;
        // Width does not create more Program roots; this measures actual field
        // transfer work rather than an unrelated entry-by-source product.
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, try selected(&w, dump, "entry "), "\n"));
    }
}

test "compact Program reads retain originating initializer launches before descriptor deferral" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try replace(&w, "foo = make first", "foo =\n    Worker.open bar ⊤\n    make first");
    const dump = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, dump, "execution-root app:0/Main/main evaluated Main.foo\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "launch app:0/Main/main -> app:0/Main/bar at=Main.foo@") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "constructionEffects=unproved execution=unproved") != null);
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
}

test "compact indexed launch metadata preserves both Program parameters of one function" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("platform/Worker.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("platform/Worker.beni"),
        \\
        \\
        \\pub openBoth : Program, Program, ⊤ → ⊤
        \\openBoth _ _ _ = ⊤
        \\
    }));
    const parsed = try std.json.parseFromSlice(std.json.Value, w.arena.allocator(), try w.read("platform/beni.json"), .{});
    var manifest = parsed.value;
    const launches = &manifest.object.getPtr("entryKinds").?.array.items[1].object.getPtr("launches").?.array;
    for ([_]u64{ 0, 1 }) |parameter| {
        var value: std.json.ObjectMap = .{};
        try value.put(w.arena.allocator(), "name", .{ .string = "Worker.openBoth" });
        try value.put(w.arena.allocator(), "parameter", .{ .integer = @intCast(parameter) });
        try launches.append(.{ .object = value });
    }
    var output: std.Io.Writer.Allocating = .init(w.arena.allocator());
    try std.json.Stringify.value(manifest, .{}, &output.writer);
    try w.write("platform/beni.json", output.written());
    try replace(&w, "Worker.open (choose True) ⊤", "Worker.openBoth foo bar ⊤");
    const dump = try inspect(&w);
    const edges = try selected(&w, dump, "launch ");
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, edges, "\n"));
    try testing.expect(std.mem.indexOf(u8, edges, "launch app:0/Main/main -> app:0/Main/foo at=Main.begin@") != null);
    try testing.expect(std.mem.indexOf(u8, edges, "launch app:0/Main/main -> app:0/Main/bar at=Main.begin@") != null);
    try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
}

test "compact deep checked record-update chains share exact shapes with linear builder work" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const base = try w.read("Main.beni");
    var previous: ?[]const u8 = null;
    var previous_n: u64 = 0;
    var previous_step: [3]u64 = @splat(0);
    var previous_width: u64 = 0;
    for ([_]u64{ 32, 64, 128, 256 }) |n| {
        var source: std.Io.Writer.Allocating = .init(w.arena.allocator());
        try source.writer.writeAll(try std.mem.replaceOwned(u8, w.arena.allocator(), base, "main = Start.make (callbacks begin)", try std.fmt.allocPrint(w.arena.allocator(), "main = Start.make (callbacks (capture r{d}))", .{n})));
        try source.writer.writeAll("\n\nr0 = { payload = first }\n");
        for (1..@intCast(n + 1)) |i| try source.writer.print("\n\nr{d} = {{ r{d} | payload = second }}\n", .{ i, i - 1 });
        try source.writer.writeAll(
            \\
            \\
            \\capture record = λ_ value →
            \\    _ = record
            \\    value
            \\
        );
        try w.write("Main.beni", source.written());
        const dump = try inspect(&w);
        try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/main role=0 S=closed") != null);
        try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
        try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
        const counters = try selected(&w, dump, "builder-work ");
        if (previous) |old| {
            const width = n - previous_n;
            var step: [3]u64 = undefined;
            const names = .{ "shapePorts=", "shapeEdges=", "shapeSelectors=" };
            inline for (names, 0..) |name, i| {
                step[i] = try metric(counters, name) - try metric(old, name);
                if (previous_width != 0) try testing.expectEqual(previous_step[i] * width, step[i] * previous_width);
            }
            // Replacing an existing field adds no selector-set copy or sort.
            try testing.expectEqual(@as(u64, 0), step[2]);
            previous_step = step;
            previous_width = width;
        }
        previous = counters;
        previous_n = n;
    }
}

test "compact metadata lookup work stays independent of unrelated constructor rows" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const worker = try w.read("platform/Worker.beni");
    const main = try w.read("Main.beni");
    const manifest_bytes = try w.read("platform/beni.json");
    var lookup_work: ?u64 = null;
    var match_work: ?u64 = null;
    var previous_rows: u64 = 0;
    for ([_]u64{ 8, 16, 32, 64 }) |n| {
        const parsed = try std.json.parseFromSlice(std.json.Value, w.arena.allocator(), manifest_bytes, .{});
        var manifest = parsed.value;
        const constructors = &manifest.object.getPtr("entryKinds").?.array.items[1].object.getPtr("constructors").?.array;
        var source: std.Io.Writer.Allocating = .init(w.arena.allocator());
        try source.writer.writeAll(worker);
        for (0..@intCast(n)) |i| {
            const name = try std.fmt.allocPrint(w.arena.allocator(), "Worker.proxy{d}", .{i});
            var row: std.json.ObjectMap = .{};
            try row.put(w.arena.allocator(), "name", .{ .string = name });
            try row.put(w.arena.allocator(), "parameter", .{ .integer = 0 });
            try row.put(w.arena.allocator(), "callbackProtocol", .{ .string = "handlers" });
            try constructors.append(.{ .object = row });
            try source.writer.print("\n\npub proxy{d} : {{ init : (Int, Int → Int), start : (Int, Int → Int), handle : (Int, Int, Int → Int), stream : (Int, Int, Int, Int → Int) }} → Program\nproxy{d} callbacks = Program callbacks\n", .{ i, i });
        }
        try w.write("platform/Worker.beni", source.written());
        var json: std.Io.Writer.Allocating = .init(w.arena.allocator());
        try std.json.Stringify.value(manifest, .{}, &json.writer);
        try w.write("platform/beni.json", json.written());
        var calls: std.Io.Writer.Allocating = .init(w.arena.allocator());
        try calls.writer.writeAll("begin context value =\n");
        for (0..32) |i| try calls.writer.print("    _ = touch {d}\n", .{i});
        try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{ try std.mem.replaceOwned(u8, w.arena.allocator(), main, "begin context value =\n", calls.written()), "\n\ntouch value = value\n" }));
        const dump = try inspect(&w);
        try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
        const counters = try selected(&w, dump, "builder-work ");
        const lookups = try metric(counters, "metadataLookups=");
        const matches = try metric(counters, "metadataMatches=");
        if (lookup_work) |expected| try testing.expectEqual(expected, lookups) else lookup_work = lookups;
        if (match_work) |expected| try testing.expectEqual(expected, matches) else match_work = matches;
        const rows = try metric(counters, "metadataRows=");
        try testing.expectEqual(n + 3, rows);
        try testing.expectEqual(3 * rows, try metric(counters, "metadataIndexWork="));
        try testing.expect(rows > previous_rows);
        previous_rows = rows;
    }
}

test "compact case materialization retains opaque control while static substitution stays closed" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try writeOpaque(&w);
    try replace(&w, "foo = make first", "foo = make (select 0)");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("Main.beni"),
        \\
        \\
        \\select input =
        \\    selected =
        \\        case input of
        \\            0 → 10
        \\            _ → 20
        \\    λ_ value →
        \\        _ = selected
        \\        value
        \\
    }));
    const closed = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, closed, "callback app:0/Main/foo role=0 S=closed") != null);
    try replace(&w, "select 0", "select (Opaque.input ⊤)");
    const controlled = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, controlled, "callback app:0/Main/foo role=0 S=unproved") != null);
    try testing.expect(std.mem.indexOf(u8, controlled, "callback app:0/Main/foo role=0 S=non_static") == null);
    try testing.expectEqualStrings("", try selected(&w, controlled, "not-static "));
    const facts = try selected(&w, controlled, "capture-fact app:0/Main/foo ");
    try testing.expect(std.mem.indexOf(u8, facts, "S=residual") != null);
    try testing.expect(std.mem.indexOf(u8, facts, "reason=native_flow") != null);
    // Equal branch data does not justify a fabricated runtime-free proof, nor
    // does unresolved control itself prove the data NonStatic.
    try replace(&w, "_ → 20", "_ → 10");
    const identical = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, identical, "callback app:0/Main/foo role=0 S=unproved") != null);
    try testing.expect(std.mem.indexOf(u8, identical, "callback app:0/Main/foo role=0 S=non_static") == null);
    try testing.expectEqualStrings("", try selected(&w, identical, "not-static "));
}

test "compact runtime choice of existing Program refs remains finite including identical alternatives" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try replace(&w, "Worker.open (choose True)", "Worker.open (runtimeChoice context)");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("Main.beni"),
        \\
        \\
        \\runtimeChoice input =
        \\    case input of
        \\        0 → foo
        \\        _ → bar
        \\
    }));
    const finite = try inspect(&w);
    const launches = try selected(&w, finite, "launch ");
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, launches, "\n"));
    try testing.expect(std.mem.indexOf(u8, launches, " -> app:0/Main/foo ") != null);
    try testing.expect(std.mem.indexOf(u8, launches, " -> app:0/Main/bar ") != null);
    try testing.expectEqualStrings("", try selected(&w, finite, "not-static "));
    try replace(&w, "_ → bar", "_ → foo");
    const identical = try inspect(&w);
    const edges = try selected(&w, identical, "launch ");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, edges, "\n"));
    try testing.expect(std.mem.indexOf(u8, edges, " -> app:0/Main/foo ") != null);
    try testing.expectEqualStrings("", try selected(&w, identical, "entry app:0/Main/bar "));
    try testing.expectEqualStrings("", try selected(&w, identical, "not-static "));
}

test "compact seeded runtime Program context is runtime evidence rather than an unsupported projection" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("platform/Start.beni",
        \\import Worker
        \\
        \\
        \\pub type Program = Program { init : (Worker.Program, Int → Int), start : (Worker.Program, Int → Int), handle : (Worker.Program, Int, Int → Int), stream : (Worker.Program, Int, Int, Int → Int) }
        \\
        \\
        \\pub make : { init : (Worker.Program, Int → Int), start : (Worker.Program, Int → Int), handle : (Worker.Program, Int, Int → Int), stream : (Worker.Program, Int, Int, Int → Int) } → Program
        \\make callbacks = Program callbacks
        \\
    );
    try replace(&w, "Worker.open (choose True)", "Worker.open context");
    try replace(&w, "main = Start.make (callbacks begin)",
        \\main =
        \\    Start.make
        \\        { init = begin
        \\        , start = λ_ value → value
        \\        , handle = λ_ _ value → value
        \\        , stream = λ_ _ _ value → value
        \\        }
    );
    const dump = try inspect(&w);
    const failures = try selected(&w, dump, "not-static ");
    try testing.expect(std.mem.startsWith(u8, failures, "not-static runtime at=Main.begin@"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, failures, "\n"));
    try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, try selected(&w, dump, "entry "), "\n"));
}

test "compact controlled construction at one factory site retains capture control obligations" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try writeOpaque(&w);
    try replace(&w, "foo = make first", "foo = chooseCapture (Opaque.input ⊤)");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("Main.beni"),
        \\
        \\
        \\makeCapture payload =
        \\    make (λ_ value →
        \\        _ = payload
        \\        value
        \\    )
        \\
        \\
        \\chooseCapture input =
        \\    case input of
        \\        0 → makeCapture 10
        \\        _ → makeCapture 20
        \\
    }));
    const dump = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/foo role=0 S=unproved") != null);
    const captures = try selected(&w, dump, "capture app:0/Main/foo ");
    try testing.expect(std.mem.indexOf(u8, captures, "S=unproved") != null);
    try testing.expect(std.mem.indexOf(u8, captures, "S=closed") == null);
    const facts = try selected(&w, dump, "capture-fact app:0/Main/foo ");
    try testing.expect(std.mem.indexOf(u8, facts, "reason=native_flow") != null);
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
}

test "compact selected field provenance retains the source case control dependency" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try writeOpaque(&w);
    try replace(&w, "foo = make first", "foo =\n    record = recordChoice (Opaque.input ⊤)\n    make (select record.payload)");
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("Main.beni"),
        \\
        \\
        \\recordChoice input =
        \\    case input of
        \\        0 → { payload = 10 }
        \\        _ → { payload = 20 }
        \\
        \\
        \\select payload = λ_ value →
        \\    _ = payload
        \\    value
        \\
    }));
    const dump = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/foo role=0 S=unproved") != null);
    const facts = try selected(&w, dump, "capture-fact app:0/Main/foo ");
    try testing.expect(std.mem.indexOf(u8, facts, "S=residual") != null);
    try testing.expect(std.mem.indexOf(u8, facts, "reason=native_flow") != null);
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
}

const callbackType = "{ init : (Int, Int → Int), start : (Int, Int → Int), handle : (Int, Int, Int → Int), stream : (Int, Int, Int, Int → Int) }";
fn addMetadata(w: *World, constructor_parameters: []const u32, launch_parameters: []const u32, name: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, w.arena.allocator(), try w.read("platform/beni.json"), .{});
    var manifest = parsed.value;
    const kind = &manifest.object.getPtr("entryKinds").?.array.items[1].object;
    for (constructor_parameters) |parameter| {
        var row: std.json.ObjectMap = .{};
        try row.put(w.arena.allocator(), "name", .{ .string = name });
        try row.put(w.arena.allocator(), "parameter", .{ .integer = parameter });
        try row.put(w.arena.allocator(), "callbackProtocol", .{ .string = "handlers" });
        try kind.getPtr("constructors").?.array.append(.{ .object = row });
    }
    for (launch_parameters) |parameter| {
        var row: std.json.ObjectMap = .{};
        try row.put(w.arena.allocator(), "name", .{ .string = name });
        try row.put(w.arena.allocator(), "parameter", .{ .integer = parameter });
        try kind.getPtr("launches").?.array.append(.{ .object = row });
    }
    var output: std.Io.Writer.Allocating = .init(w.arena.allocator());
    try std.json.Stringify.value(manifest, .{}, &output.writer);
    try w.write("platform/beni.json", output.written());
}

test "compact one checked function preserves constructor and launch metadata plus source body" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("platform/Worker.beni", try std.fmt.allocPrint(w.arena.allocator(), "{s}\n\npub makeAndOpen : {s}, Program, ⊤ → Program\nmakeAndOpen callbacks other unit =\n    open other unit\n    Program callbacks\n", .{ try w.read("platform/Worker.beni"), callbackType }));
    try addMetadata(&w, &.{0}, &.{1}, "Worker.makeAndOpen");
    try replace(&w, "foo = make first", "foo = Worker.makeAndOpen (callbacks first) bar ⊤");
    const dump = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, dump, "callback app:0/Main/foo role=0 S=closed source=Main.first\n") != null);
    // The call's declared launch row must not disappear behind constructor
    // result modeling, and ordinary constructor body effects stay visible.
    try testing.expect(std.mem.indexOf(u8, dump, "launch app:0/Main/main -> app:0/Main/bar at=Main.foo@") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "launch app:0/Main/main -> app:0/Main/bar at=Worker.makeAndOpen@") != null);
    try testing.expectEqualStrings("", try selected(&w, dump, "residual "));
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
}

test "compact distinct constructor callback views remain an explicit gap rather than first match or language refusal" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try w.write("platform/Worker.beni", try std.fmt.allocPrint(w.arena.allocator(), "{s}\n\npub dual : {s}, {s} → Program\ndual left _ = Program left\n", .{ try w.read("platform/Worker.beni"), callbackType, callbackType }));
    try addMetadata(&w, &.{ 0, 1 }, &.{}, "Worker.dual");
    try replace(&w, "foo = make first", "foo = Worker.dual (callbacks first) (callbacks second)");
    const checked = try w.run(&.{ "check", "--platform=platform", "Main.beni" });
    try clean(checked);
    try testing.expectEqualStrings("", checked.stdout);
    const dump = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, dump, "residual app:0/Main/main metadata at=Main.foo@") != null);
    try testing.expectEqualStrings("", try selected(&w, dump, "not-static "));
    try testing.expectEqualStrings("", try selected(&w, dump, "entry app:0/Main/foo "));
}

test "compact nested selected field retains materialization control" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    try writeOpaque(&w);
    try replace(&w, "foo = make first",
        \\foo =
        \\    record =
        \\        case Opaque.input ⊤ of
        \\            0 → { outer = { payload = 10 } }
        \\            _ → { outer = { payload = 20 } }
        \\    make (select record.outer.payload)
    );
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{
        try w.read("Main.beni"),
        \\
        \\
        \\select payload = λ_ value →
        \\    _ = payload
        \\    value
        \\
    }));
    const controlled = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, controlled, "callback app:0/Main/foo role=0 S=unproved") != null);
    try testing.expect(std.mem.indexOf(u8, controlled, "capture app:0/Main/foo role=0 input=0 S=unproved") != null);
    const opaque_facts = try selected(&w, controlled, "capture-fact app:0/Main/foo ");
    try testing.expect(std.mem.indexOf(u8, opaque_facts, "S=residual") != null);
    try testing.expect(std.mem.indexOf(u8, opaque_facts, "reason=native_flow") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, opaque_facts, "W=origin"));
    try testing.expectEqualStrings("", try selected(&w, controlled, "not-static "));
    try replace(&w, "case Opaque.input ⊤ of", "case 0 of");
    const closed = try inspect(&w);
    try testing.expect(std.mem.indexOf(u8, closed, "callback app:0/Main/foo role=0 S=closed") != null);
    try testing.expect(std.mem.indexOf(u8, closed, "capture app:0/Main/foo role=0 input=0 S=closed") != null);
    const closed_facts = try selected(&w, closed, "capture-fact app:0/Main/foo ");
    try testing.expect(std.mem.indexOf(u8, closed_facts, "S=residual") == null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, closed_facts, "W=origin"));
}
