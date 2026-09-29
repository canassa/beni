//! Platforms layered on platforms (docs/design/boundary.md §9.1–§9.2): the
//! chain a `--platform` selects, what a program and a platform module may
//! import from it, where each package's output goes, and the exit-2 failures
//! of a chain that cannot be read.
//!
//! Boundary 1 throughout — the installed binary against a temp project — and
//! boundary 2 once, for the program a two-layer platform builds.
//! `tests/platforms/layered/` is the two-layer platform: `top/` declares no
//! output key and inherits `base/`'s.
//!
//! Nothing here imports a compiler internal: `std`, the harness and the
//! public diagnostic schema, which the build graph enforces.

const std = @import("std");
const diagnostic = @import("diagnostic");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

/// The program every layered scenario builds: it imports the top platform's
/// module and the base's, which the top re-exports.
fn writeLayeredProgram(w: *World) !void {
    // Every file of the platform: the prefix skips nothing that is there.
    try w.copyTree("tests/platforms/layered", "_expected.");
    try w.write("Main.beni",
        \\import Base
        \\import Top
        \\
        \\
        \\main : Base.Program
        \\main =
        \\    Top.shout "hi"
        \\
    );
}

/// Every file under one output directory, as sorted paths relative to it.
fn treeOf(w: *World, out_dir: []const u8) ![]const []const u8 {
    const arena = w.arena.allocator();
    var dir = try w.tmp.dir.openDir(testing.io, out_dir, .{ .iterate = true });
    defer dir.close(testing.io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(testing.io)) |entry| {
        if (entry.kind != .file) continue;
        try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return paths.items;
}

test "a platform layered on another builds a program with its base's program and runtime" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeLayeredProgram(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.run(&.{ "build", "--platform=top", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqual(@as(usize, 0), built.diagnostics.len);
    // The top platform's modules go where a one-platform build's always
    // went; the base's, runtime included, under `_platform/_<name>/`, a
    // directory no module name can reach.
    try testing.expectEqualDeep(@as([]const []const u8, &.{
        "Main.mjs",
        "_main.mjs",
        "_manifest.txt",
        "_platform/Top.mjs",
        "_platform/_layered-base/Base.foreign.mjs",
        "_platform/_layered-base/Base.mjs",
        "_platform/_layered-base/Hidden.mjs",
        "_platform/_layered-base/run.foreign.mjs",
    }), try treeOf(&w, "out"));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The entry file hands `main` to the base's runtime, which it inherited.
    try w.expectProgram(world.entry_file, .{ .stdout = "hi!\n" });
}

test "a program imports a dependency's module only when a platform re-exports it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeLayeredProgram(&w);
    try w.write("app/Other.beni",
        \\import Hidden
        \\
        \\
        \\x : String
        \\x =
        \\    Hidden.loud "a"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=top", "app/Other.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // `Top` imports `Hidden` and checks; the program may not, and the
    // message names the platform that has the module and the key that
    // would expose it.
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expectEqual(@as(usize, 2), checked.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .unknown_module,
        .severity = .@"error",
        .span = .{ .file = "app/Other.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 14 } },
        .title = "UNKNOWN MODULE",
        .message = "`Hidden` is a module of the platform `layered-base`, which this build's platform\n" ++
            "depends on, but no platform above it lists `Hidden` in `\"reexports\"`, so a\n" ++
            "program cannot import it.\n" ++
            "\n" ++
            "A program may import the modules of the platform it is built for, and a module\n" ++
            "of a platform below it only when a platform on the way lists that module in its\n" ++
            "manifest's `\"reexports\"` (`docs/design/boundary.md` §9.1).",
    }, checked.diagnostics[0]);
    try testing.expectEqual(diagnostic.Code.unknown_module_alias, checked.diagnostics[1].code);
}

test "a dependency platform's module cannot import the platform that depends on it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeLayeredProgram(&w);
    try w.write("base/Up.beni",
        \\import Top
        \\
        \\
        \\pub x : Int
        \\x =
        \\    1
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=top", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expectEqual(@as(usize, 1), checked.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .unknown_module,
        .severity = .@"error",
        .span = .{ .file = "base/Up.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 11 } },
        .title = "UNKNOWN MODULE",
        .message = "`Top` is a module of the platform `layered-top`, which `layered-base` does not\n" ++
            "depend on.\n" ++
            "\n" ++
            "A platform's modules may import the modules of the platforms it lists in its\n" ++
            "manifest's `\"platforms\"`, directly or through them, and no others\n" ++
            "(`docs/design/boundary.md` §9.1).",
    }, checked.diagnostics[0]);
}

test "platforms that depend on each other in a circle are refused before a source is read" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("a/beni.json",
        \\{ "platform": true, "name": "a", "platforms": ["../b"] }
    );
    try w.write("b/beni.json",
        \\{ "platform": true, "name": "b", "platforms": ["../a"] }
    );
    // A source that does not lex: a run that read it would say so.
    try w.write("Main.beni", "\"\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.runWith(&.{ "check", "--platform=a", "Main.beni" }, .{ .raw_diagnostics = true });
    const built = try w.runWith(&.{ "build", "--platform=a", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), checked.exit_code);
    try testing.expectEqualStrings(
        "beni: these platforms depend on each other in a circle (\"platforms\"): a → b → a; a platform may depend only on platforms that do not depend on it\n",
        checked.stderr,
    );
    try testing.expectEqual(@as(u8, 2), built.exit_code);
    try testing.expectEqualStrings(checked.stderr, built.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "a platform that depends on nothing that exists is refused" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("a/beni.json",
        \\{ "platform": true, "name": "a", "platforms": ["../nowhere"] }
    );
    try w.write("Main.beni", "x : Int\nx =\n    1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.runWith(&.{ "check", "--platform=a", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), checked.exit_code);
    try testing.expectEqualStrings(
        "beni: platform 'a' depends on '../nowhere' (\"platforms\"), which is neither a platform that ships with the compiler (node) nor a directory holding one\n",
        checked.stderr,
    );
}
