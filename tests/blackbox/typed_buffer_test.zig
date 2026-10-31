//! Typed runtime buffers through the compiler boundary. Generated siblings
//! obey the same physical override, export and cache rules as disk siblings.
const std = @import("std");
const diagnostic = @import("diagnostic");
const world = @import("world.zig");
const testing = std.testing;
const World = world.World;

fn expectClean(result: world.Result) !void {
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "an application Js.Buffer module has no privileged core identity" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Js.Buffer as Local
        \\import Node
        \\
        \\main : Node.Program
        \\main = Node.print (String.fromInt (Local.answer ⊤))
        \\
    );
    try w.write("Js/Buffer.beni",
        \\pub answer : ⊤ → Int
        \\answer ⊤ = 42
        \\
    );
    const built = try w.run(&.{ "build", "--platform=node", "--root=.", "--out=out", "." });
    try expectClean(built);
    try w.expectProgram("out/_main.mjs", .{ .stdout = "42\n" });
}

test "generated buffer sibling participates in core overrides and physical export validation" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTree("tests/corpus/run/TypedBuffer", "_expected.");
    try w.copyTreeInto("core", "core", "_expected.");
    const built = try w.run(&.{ "build", "--platform=platform", "--core-root=core", "--cache-dir=cache", "--out=generated", "Main.beni" });
    try expectClean(built);
    try w.expectProgram("generated/_main.mjs", .{ .stdout = "(2,18);(2,\"ab\");(3,6);1;(0,1,2)\n" });
    // An actual asset is authoritative, even when it provides no exports.
    // No generated fallback may mask it or reuse the previous cache key.
    try w.write("core/Js/Buffer.js", "");
    const warm = try w.run(&.{ "build", "--platform=platform", "--core-root=core", "--cache-dir=cache", "--out=invalid", "Main.beni" });
    const cold = try w.run(&.{ "build", "--platform=platform", "--core-root=core", "--no-cache", "--out=invalid-cold", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), warm.exit_code);
    try testing.expectEqual(@as(u8, 1), cold.exit_code);
    try testing.expectEqualStrings("", warm.stdout);
    try testing.expectEqualStrings("", cold.stdout);
    try testing.expectEqualDeep(cold.diagnostics, warm.diagnostics);
    const rows = [_]struct { name: []const u8, line: u32, col: u32 }{
        .{ .name = "make", .line = 10, .col = 20 },
        .{ .name = "push", .line = 14, .col = 20 },
        .{ .name = "length", .line = 18, .col = 20 },
        .{ .name = "forEach", .line = 23, .col = 20 },
        .{ .name = "forEachWhile", .line = 27, .col = 20 },
    };
    try testing.expectEqual(rows.len, warm.diagnostics.len);
    for (rows, warm.diagnostics) |row, got| {
        const message = try std.fmt.allocPrint(
            w.arena.allocator(),
            "`core/Js/Buffer.js` does not export `{s}`.\n\n" ++
                "A sibling JavaScript file exports exactly the `foreign` values its module\n" ++
                "declares — no more, no fewer (`docs/design/boundary.md` §4, check 2). Add\n" ++
                "`export const {s} = …;` to it, or delete the `foreign` declaration.",
            .{ row.name, row.name },
        );
        try testing.expectEqualDeep(diagnostic.Diagnostic{
            .code = .foreign_export_mismatch,
            .severity = .@"error",
            .span = .{ .file = "core/Js/Buffer.beni", .start = .{ .line = row.line, .col = row.col }, .end = .{ .line = row.line, .col = row.col + @as(u32, @intCast(row.name.len)) } },
            .title = "FOREIGN EXPORT MISMATCH",
            .message = message,
        }, got);
    }
    try testing.expect(!w.exists("invalid/_main.mjs"));
    try testing.expect(!w.exists("invalid-cold/_main.mjs"));
}

test "dangling physical core sibling suppresses generated fallback with warm and cold cache" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTree("tests/corpus/run/TypedBuffer", "_expected.");
    try w.copyTreeInto("core", "core", "_expected.");
    const built = try w.run(&.{ "build", "--platform=platform", "--core-root=core", "--cache-dir=cache", "--out=generated", "Main.beni" });
    try expectClean(built);
    try w.symlink("missing-sibling.js", "core/Js/Buffer.js");
    const warm = try w.run(&.{ "build", "--platform=platform", "--core-root=core", "--cache-dir=cache", "--out=dangling", "Main.beni" });
    const cold = try w.run(&.{ "build", "--platform=platform", "--core-root=core", "--no-cache", "--out=dangling-cold", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), warm.exit_code);
    try testing.expectEqual(@as(u8, 1), cold.exit_code);
    try testing.expectEqualStrings("", warm.stdout);
    try testing.expectEqualStrings("", cold.stdout);
    try testing.expectEqualDeep(cold.diagnostics, warm.diagnostics);
    try testing.expectEqual(@as(usize, 1), warm.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .foreign_sibling_missing,
        .severity = .@"error",
        .span = .{ .file = "core/Js/Buffer.beni", .start = .{ .line = 10, .col = 20 }, .end = .{ .line = 10, .col = 24 } },
        .title = "MISSING JAVASCRIPT FILE",
        .message = "I cannot find `core/Js/Buffer.js`.\n\n" ++
            "A module with `foreign` declarations binds them to a sibling JavaScript file\n" ++
            "of the same name, one export per foreign value\n" ++
            "(`docs/design/boundary.md` §4). Write that file next to `core/Js/Buffer.beni`.",
    }, warm.diagnostics[0]);
    try testing.expect(!w.exists("dangling/_main.mjs"));
    try testing.expect(!w.exists("dangling-cold/_main.mjs"));
}

test "ordinary custom Core Js functions do not become Buffer intrinsics" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTreeInto("core", "core", "_expected.");
    const js = try w.read("core/Js.beni");
    try w.write("core/Js.beni", try std.fmt.allocPrint(
        w.arena.allocator(),
        "{s}\n\npub makeBuffer : a → a\nmakeBuffer value = value\n",
        .{js},
    ));
    try w.write("Main.beni",
        \\import Node
        \\import Probe
        \\
        \\main : Node.Program
        \\main = Node.print (String.fromInt (Probe.answer ⊤))
        \\
    );
    try w.write("platform/beni.json",
        \\{ "platform": true, "name": "probe", "platforms": ["node"], "reexports": ["Node"] }
    );
    try w.write("platform/Probe.beni",
        \\import Js
        \\
        \\pub answer : ⊤ → Int
        \\answer ⊤ = Js.makeBuffer 42
        \\
    );
    for ([_][]const []const u8{
        &.{ "build", "--platform=platform", "--core-root=core", "--out=out", "Main.beni" },
        &.{ "build", "--release", "--platform=platform", "--core-root=core", "--out=out", "Main.beni" },
    }) |args| {
        const result = try w.run(args);
        try expectClean(result);
        try w.expectProgram("out/_main.mjs", .{ .stdout = "42\n" });
    }
}
