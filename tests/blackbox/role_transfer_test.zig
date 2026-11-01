//! Anchored owned producer evidence through real checked source and output only.
const std = @import("std");
const world = @import("world.zig");
const roles = @import("entry_roles.zig");
const testing = std.testing;
const World = world.World;

fn prepare(w: *World) !void {
    try w.copyTree("tests/fixtures/entry-discovery/basic", "_expected.");
    try w.write("Main.beni", try std.Io.Dir.cwd().readFileAlloc(w.io, "tests/corpus/entry/role-transfers/Main.beni", w.arena.allocator(), .unlimited));
}
fn inspect(w: *World, extra: []const []const u8) !world.Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(w.arena.allocator(), &.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try argv.appendSlice(w.arena.allocator(), extra);
    const r = try w.run(argv.items);
    if (r.exit_code != 0) std.debug.print("{s}\n", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    _ = try roles.before(r.stdout);
    return r;
}
fn transfer(p: *const roles.Parsed, entry: []const u8) ![]const u8 {
    var result: ?[]const u8 = null;
    for (try p.rows("role-transfer")) |row| {
        if (!std.mem.eql(u8, try roles.field(row, "entry"), entry) or !std.mem.eql(u8, try roles.field(row, "kind"), "callback") or try roles.number(row, "role") != 0) continue;
        try testing.expect(result == null);
        result = row;
    }
    return result orelse error.MissingAnchoredRole;
}
fn capture(p: *const roles.Parsed, t: []const u8) ![]const u8 {
    const range = try roles.range(t, "captures");
    try testing.expectEqual(@as(u32, 1), range.len);
    const c = try p.row("role-capture", range.start);
    try testing.expectEqual(try roles.id(t), try roles.number(c, "transfer"));
    return c;
}
fn staticLeaf(p: *const roles.Parsed, query: u32, expected_name: []const u8, literal_name: ?[]const u8) !void {
    var leaves: usize = 0;
    var literals: usize = 0;
    for (try p.rows("role-fact")) |fact| {
        if (try roles.number(fact, "query") != query) continue;
        const answer = try p.row("role-answer", try roles.number(fact, "answer"));
        if (!std.mem.eql(u8, try roles.field(answer, "kind"), "static_leaf")) continue;
        const origin = try p.row("role-origin", try roles.number(answer, "origin"));
        if (std.mem.eql(u8, try roles.field(origin, "kind"), "function")) {
            try testing.expectEqualStrings(expected_name, try p.sourceName(try roles.number(origin, "site")));
            leaves += 1;
        } else {
            try testing.expectEqualStrings("literal", try roles.field(origin, "kind"));
            try testing.expectEqualStrings(literal_name orelse return error.UnexpectedControlLeaf, try p.sourceName(try roles.number(origin, "site")));
            literals += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), leaves);
    try testing.expectEqual(@as(usize, if (literal_name != null) 1 else 0), literals);
}
fn transportEquations(p: *const roles.Parsed) !void {
    var actuals: usize = 0;
    for (try p.rows("role-transport")) |t| {
        const edge = try p.row("role-edge", try roles.number(t, "edge"));
        try testing.expectEqualStrings("copy", try roles.field(edge, "kind"));
        const source = try p.row("role-query", try roles.number(edge, "source"));
        const target = try p.row("role-query", try roles.number(edge, "target"));
        const input = try p.row("role-input", try roles.number(t, "input"));
        if (std.mem.eql(u8, try roles.field(t, "kind"), "actual")) {
            const via = try p.row("role-edge", try roles.number(t, "via"));
            const formal = try p.row("role-fact", try roles.number(t, "formal"));
            const call = try p.row("role-call", try roles.number(t, "call"));
            try testing.expectEqualStrings("substitute", try roles.field(via, "kind"));
            try testing.expectEqual(try roles.number(t, "call"), try roles.number(via, "call"));
            try testing.expectEqual(try roles.number(formal, "query"), try roles.number(via, "source"));
            try testing.expectEqual(try roles.number(edge, "target"), try roles.number(via, "target"));
            try testing.expectEqual(try roles.number(input, "owner"), try roles.number(call, "target"));
            const range = try roles.range(call, if (std.mem.eql(u8, try roles.field(input, "capture"), "true")) "captures" else "arguments");
            const position = try roles.number(input, "position");
            try testing.expect(position < range.len);
            try testing.expectEqual(p.words[range.start + position], try roles.number(t, "actual"));
            try testing.expectEqual(try roles.number(t, "actual"), try roles.number(source, "port"));
            actuals += 1;
        } else {
            const binding = try p.row("role-binding", try roles.number(t, "binding"));
            const observation = try p.row("role-observation", try roles.number(target, "observation"));
            const mode = try roles.field(observation, "mode");
            try testing.expectEqual(try roles.number(binding, if (std.mem.eql(u8, mode, "W")) "W" else "S"), try roles.number(edge, "source"));
            try testing.expectEqual(try roles.number(binding, "seed"), try roles.number(target, "seed"));
        }
    }
    try testing.expect(actuals > 0);
}
fn oracle(w: *World, text: []const u8, mixed: bool) !void {
    const p = try roles.Parsed.init(w.arena.allocator(), text);
    const foo = try transfer(&p, "app:0/Main/foo");
    const bar = try transfer(&p, "app:0/Main/bar");
    try testing.expect(try roles.number(foo, "anchor") != try roles.number(bar, "anchor"));
    inline for (.{ "constructor", "origin", "template" }) |key| try testing.expectEqual(try roles.number(foo, key), try roles.number(bar, key));
    try testing.expect(try roles.number(foo, "source") != try roles.number(bar, "source"));
    const fc = try capture(&p, foo);
    const bc = try capture(&p, bar);
    try testing.expectEqual(try roles.number(fc, "input"), try roles.number(bc, "input"));
    const input = try p.row("role-input", try roles.number(fc, "input"));
    try testing.expectEqualStrings("true", try roles.field(input, "capture"));
    try testing.expectEqual(try roles.number(foo, "template"), try roles.number(input, "owner"));
    inline for (.{ foo, bar }, .{ fc, bc }) |t, c| {
        const sq = try p.row("role-query", try roles.number(c, "S"));
        const observation = try p.row("role-observation", try roles.number(sq, "observation"));
        try testing.expectEqual(try roles.number(t, "source"), try roles.number(sq, "port"));
        try testing.expectEqual(try roles.number(t, "anchor"), try roles.number(observation, "anchor"));
        try testing.expectEqualStrings("closed", try roles.field(c, "sourceStatus"));
    }
    try staticLeaf(&p, try roles.number(fc, "S"), "Main.first", null);
    try staticLeaf(&p, try roles.number(bc, "S"), "Main.second", if (mixed) "Main.bar" else null);
    try transportEquations(&p);
    try testing.expect(!w.exists("out"));
}

test "anchored role producer preserves same site captures across cache jobs roundtrip and relocation" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const cold = try inspect(&w, &.{"--jobs=1"});
    try oracle(&w, cold.stdout, false);
    const warm = try inspect(&w, &.{"--jobs=8"});
    try testing.expectEqualStrings(cold.stdout, warm.stdout);
    const rt = try inspect(&w, &.{ "--no-cache", "--roundtrip-dispatch", "--roundtrip-interfaces", "--jobs=8" });
    try testing.expectEqualStrings(cold.stdout, rt.stdout);
    var moved = try World.init(testing.allocator, testing.io);
    defer moved.deinit();
    try prepare(&moved);
    try testing.expectEqualStrings(cold.stdout, (try inspect(&moved, &.{"--jobs=8"})).stdout);
}

test "anchored role producer preserves mixed sealed aliases in both declaration orders" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    var text = try w.read("Main.beni");
    text = try std.mem.replaceOwned(u8, w.arena.allocator(), text, "bar = make (relay second)", "bar = mix False second");
    text = try std.mem.replaceOwned(u8, w.arena.allocator(), text, "alias2 = alias1", "alias2 = forward alias1");
    text = try std.mem.concat(w.arena.allocator(), u8, &.{ text, "\n\nforward program = program\n\n\nmix flag callback = if flag then alias2 else make (relay callback)\n" });
    try w.write("Main.beni", text);
    try oracle(&w, (try inspect(&w, &.{"--jobs=1"})).stdout, true);
    text = try std.mem.replaceOwned(u8, w.arena.allocator(), text, "foo = make (relay first)\n\n\nbar = mix False second", "bar = mix False second\n\n\nfoo = make (relay first)");
    try w.write("Main.beni", text);
    try oracle(&w, (try inspect(&w, &.{"--jobs=8"})).stdout, true);
}

test "anchored role producer source failure emits no old directory and repairs warm bytes" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try prepare(&w);
    const good = try w.read("Main.beni");
    const initial = try inspect(&w, &.{});
    try w.write("Main.beni", try std.mem.concat(w.arena.allocator(), u8, &.{ good, "\n\nbroken : ⊤\nbroken = λx → x\n" }));
    const bad = try w.run(&.{ "check", "--entries", "--platform=platform", "--cache-dir=cache", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), bad.exit_code);
    try testing.expectEqualStrings("", bad.stdout);
    try testing.expectEqual(@as(usize, 1), bad.diagnostics.len);
    const expected = try std.Io.Dir.cwd().readFileAlloc(w.io, "tests/corpus/entry/role-transfers/error.expected.json", w.arena.allocator(), .unlimited);
    try testing.expectEqualStrings(expected, bad.stderr);
    try w.write("Main.beni", good);
    try testing.expectEqualStrings(initial.stdout, (try inspect(&w, &.{"--jobs=8"})).stdout);
}
