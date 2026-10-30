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
        "Main.mjs.map",
        "_main.mjs",
        "_manifest.txt",
        "_platform/Top.mjs",
        "_platform/Top.mjs.map",
        "_platform/_layered-base/Base.foreign.mjs",
        "_platform/_layered-base/Base.mjs",
        "_platform/_layered-base/Base.mjs.map",
        "_platform/_layered-base/Hidden.mjs",
        "_platform/_layered-base/Hidden.mjs.map",
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
        "beni: platform 'a' depends on '../nowhere' (\"platforms\"), which is neither a platform that ships with the compiler (browser, browser-inline, browser-tea, cloudflare, html, node) nor a directory holding one\n",
        checked.stderr,
    );
}

/// A chain of `top` over the dependencies `deps`, each `{ dir, manifest
/// name, module }`: every dependency declares one module, which `top`
/// re-exports, and `Main.beni` imports them all, so a library build writes
/// each dependency's output directory.
fn writeChain(w: *World, deps: []const [3][]const u8) !void {
    const a = w.arena.allocator();
    var dirs: std.ArrayList(u8) = .empty;
    var modules: std.ArrayList(u8) = .empty;
    var imports: std.ArrayList(u8) = .empty;
    for (deps, 0..) |d, i| {
        const sep = if (i == 0) "" else ", ";
        try dirs.print(a, "{s}\"../{s}\"", .{ sep, d[0] });
        try modules.print(a, "{s}\"{s}\"", .{ sep, d[2] });
        try imports.print(a, "import {s}\n", .{d[2]});
        const manifest = if (d[1].len == 0)
            "{ \"platform\": true }"
        else
            try std.fmt.allocPrint(a, "{{ \"platform\": true, \"name\": \"{s}\" }}", .{d[1]});
        try w.write(try std.fmt.allocPrint(a, "{s}/beni.json", .{d[0]}), manifest);
        try w.write(try std.fmt.allocPrint(a, "{s}/{s}.beni", .{ d[0], d[2] }), try std.fmt.allocPrint(a, "pub name : String\nname =\n    \"{s}\"\n", .{d[2]}));
    }
    try w.write("top/beni.json", try std.fmt.allocPrint(a, "{{ \"platform\": true, \"name\": \"top\", \"platforms\": [{s}], \"reexports\": [{s}] }}", .{ dirs.items, modules.items }));
    try imports.appendSlice(a, "\n\npub names : List String\nnames =\n    [");
    for (deps, 0..) |d, i| try imports.print(a, "{s} {s}.name", .{ if (i == 0) "" else ",", d[2] });
    try imports.appendSlice(a, " ]\n");
    try w.write("app/Main.beni", imports.items);
}

test "a dependency platform's output directory is named for its manifest's name" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `named` has a `"name"`; `plain` has none, and is named by the last
    // segment of the path that reached it, not by the path.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeChain(&w, &.{ .{ "named", "lib-one", "One" }, .{ "plain", "", "Two" } });

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.run(&.{ "build", "--library", "--platform=top", "--out=out", "app/Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqual(@as(usize, 0), built.diagnostics.len);
    try testing.expectEqualDeep(@as([]const []const u8, &.{
        "Main.mjs",
        "Main.mjs.map",
        "_manifest.txt",
        "_platform/_lib-one/One.mjs",
        "_platform/_lib-one/One.mjs.map",
        "_platform/_plain/Two.mjs",
        "_platform/_plain/Two.mjs.map",
    }), try treeOf(&w, "out"));
}

test "a dependency platform whose name is not one directory name is refused before a source is read" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `_platform/_<name>/` with this name would be `out/esc/`, outside
    // `--out=out/app`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeChain(&w, &.{.{ "lib", "x/../../../esc", "Lib" }});
    // A source that does not lex: a run that read it would say so.
    try w.write("app/Main.beni", "\"\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--library", "--platform=top", "--out=out/app", "app/Main.beni" }, .{ .raw_diagnostics = true });
    const checked = try w.runWith(&.{ "check", "--platform=top", "app/Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), built.exit_code);
    try testing.expectEqualStrings(
        "beni: platform 'top' depends on '../lib', whose \"name\" 'x/../../../esc' cannot name its output directory _platform/_<name>/; a platform's name is ASCII letters, digits, '-', '_' and '.', and begins with a letter or a digit\n",
        built.stderr,
    );
    try testing.expectEqual(@as(u8, 2), checked.exit_code);
    try testing.expectEqualStrings(built.stderr, checked.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "two dependency platforms with one name are refused before a source is read" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Both would write `_platform/_lib/`; names that differ only in case
    // would be one directory on APFS and NTFS.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeChain(&w, &.{ .{ "a", "lib", "One" }, .{ "b", "Lib", "Two" } });

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--library", "--platform=top", "--out=out", "app/Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), built.exit_code);
    try testing.expectEqualStrings(
        "beni: platforms 'lib' ('a') and 'Lib' ('b') of one chain would share the output directory _platform/_lib/; give each a \"name\" of its own\n",
        built.stderr,
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "check --platform=html types a view module against the one Html type" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `html` declares no `program`; it is a platform to check against
    // (`boundary.md` §9.1). A view module annotates with its markup type and
    // calls its primitives, which are ordinary values with schemes.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("View.beni",
        \\import Html exposing (Html)
        \\
        \\
        \\pub view : String → Html msg
        \\view s =
        \\    Html.map (Html.text s) identity
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=html", "View.beni" });
    const dumped = try w.runWith(&.{ "dump", "--stage=interface", "--platform=html", "View.beni" }, .{ .raw_diagnostics = true });
    // The same module under `node`, which re-exports `Html`: one vocabulary
    // module and one `Html` type under both.
    const under_node = try w.run(&.{ "check", "--platform=node", "View.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
    try testing.expectEqual(@as(u8, 0), dumped.exit_code);
    try testing.expectEqualStrings("module View\n  value view : String → Html msg\n", dumped.stdout);
    try testing.expectEqual(@as(u8, 0), under_node.exit_code);
    try testing.expectEqual(@as(usize, 0), under_node.diagnostics.len);
}

test "a program build for a platform with no program is refused before a source is read" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // A source that does not lex: a run that read it would say so.
    try w.write("Main.beni", "\"\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=html", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), built.exit_code);
    try testing.expectEqualStrings(
        "beni: 'html' declares no \"program\" and is only depended on: build a library for it with --library, or build the program for a platform that depends on it\n",
        built.stderr,
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "a library for a platform with no program builds, and one that keeps a markup primitive is refused" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Label.beni",
        \\import Html exposing (Html)
        \\
        \\
        \\pub label : String → String
        \\label s =
        \\    "[${s}]"
        \\
        \\
        \\pub placeholder : Html msg → Html msg
        \\placeholder h =
        \\    h
        \\
    );
    try w.write("View.beni",
        \\import Html exposing (Html)
        \\
        \\
        \\pub view : String → Html msg
        \\view s =
        \\    Html.text s
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const library = try w.run(&.{ "build", "--library", "--platform=html", "--out=lib", "Label.beni" });
    const refused = try w.run(&.{ "build", "--library", "--platform=html", "--out=view", "View.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // `html`'s module is not written: nothing the library keeps reaches it.
    try testing.expectEqual(@as(u8, 0), library.exit_code);
    try testing.expectEqual(@as(usize, 0), library.diagnostics.len);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "Label.mjs", "Label.mjs.map", "_manifest.txt" }), try treeOf(&w, "lib"));
    try testing.expectEqual(@as(u8, 1), refused.exit_code);
    try testing.expectEqual(@as(usize, 1), refused.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .unknown_markup_lowering,
        .severity = .@"error",
        .span = .{ .file = "platforms/html/beni.json", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
        .title = "UNKNOWN MARKUP LOWERING",
        .message = "This build uses the markup primitive `Html.text`, but the platform `html` names\n" ++
            "no markup lowering to implement it.\n" ++
            "\n" ++
            "A markup primitive is implemented by the runtime of the build's markup lowering\n" ++
            "(`docs/design/boundary.md` §9.3), which a platform names in its manifest's\n" ++
            "`\"markup\"` `\"lowering\"`, or inherits from a platform it depends on.",
    }, refused.diagnostics[0]);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("view"));
}

test "a markup lowering and a markup runtime from two packages are refused" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The runtime is written for the lowering (`boundary.md` §9.2), so the
    // first of each the chain finds must come from one package.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("top/beni.json",
        \\{ "platform": true, "name": "top", "platforms": ["../base"], "markup": { "lowering": "strings" } }
    );
    try w.write("base/beni.json",
        \\{ "platform": true, "name": "base", "markup": { "runtime": "markup.js" } }
    );
    try w.write("Main.beni", "x : Int\nx =\n    1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.runWith(&.{ "check", "--platform=top", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), checked.exit_code);
    try testing.expectEqualStrings(
        "beni: the markup lowering is declared by 'top' and the markup runtime by 'base'; a \"markup\" \"lowering\" and its \"runtime\" must come from one package\n",
        checked.stderr,
    );
}

test "a platform whose runtime module is its whole runtime writes no runtime file" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `browser` names no `"runtime"`: its runtime module `Rt` supplies
    // `run` and every export of the `dom` lowering (`boundary.md` §5.2,
    // §9.2, amended 2026-10-02), so the entry file hands `main` to `Rt`'s
    // `run` and there is no hand-written file to copy.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Browser
        \\import Html exposing (Html)
        \\
        \\
        \\view : {} → Html {}
        \\view _ =
        \\    <p>hi</p>
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.program { init = λ⊤ → {}, update = λ_ m → m, view = view }
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.run(&.{ "build", "--platform=browser", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqual(@as(usize, 0), built.diagnostics.len);
    try testing.expectEqualDeep(@as([]const []const u8, &.{
        "Main.mjs",
        "Main.mjs.map",
        "_core/Basics.mjs",
        "_core/Basics.mjs.map",
        // `Rt`'s `stop` names `Task.shutdown` behind a test a release
        // build folds (`boundary.md` §9.8.14, the size pass's amendment).
        "_core/Task.mjs",
        "_core/Task.mjs.map",
        "_main.mjs",
        "_manifest.txt",
        "_platform/Browser.mjs",
        "_platform/Browser.mjs.map",
        "_platform/Rt.mjs",
        "_platform/Rt.mjs.map",
        "index.html",
    }), try treeOf(&w, "out"));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(
        \\// Generated by `beni build` (docs/design/boundary.md §5.2): the entry file
        \\// the platform's output shape asks for.
        \\import { Rt$run as run } from "./_platform/Rt.mjs";
        \\import { Main$main } from "./Main.mjs";
        \\
        \\run(Main$main);
        \\export { Rt$flush as flush } from "./_platform/Rt.mjs";
        \\
    , try w.read("out/_main.mjs"));
}

test "a platform with no runtime file whose runtime module has no run is refused" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // With no `"runtime"`, the runtime module is the only place an export can
    // come from, `run` included: each one it does not declare is reported
    // against the manifest that named the module, and nothing is written.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("bare/beni.json",
        \\{ "platform": true, "name": "bare", "program": "Bare.Program", "markup": { "lowering": "dom", "module": "Bare" } }
    );
    try w.write("bare/Bare.beni",
        \\pub type Program
        \\    = Program String
        \\
        \\
        \\pub program : String → Program
        \\program s =
        \\    Program s
        \\
    );
    try w.write("Main.beni",
        \\import Bare
        \\
        \\
        \\main : Bare.Program
        \\main =
        \\    Bare.program "hi"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.run(&.{ "build", "--platform=bare", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), built.exit_code);
    const run_missing: diagnostic.Diagnostic = .{
        .code = .foreign_export_mismatch,
        .severity = .@"error",
        .span = .{ .file = "bare/beni.json", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
        .title = "FOREIGN EXPORT MISMATCH",
        .message = "The runtime module `Bare` declares no `pub` value `run`, which the entry file\n" ++
            "hands `main` to, and this platform names no runtime file to supply it.\n" ++
            "\n" ++
            "A platform whose manifest names no `\"runtime\"` has its runtime module as its\n" ++
            "whole runtime (`docs/design/boundary.md` §5.2, §9.2), so the module must declare\n" ++
            "every export: here `run`, taking 1 parameter.",
    };
    var found = false;
    for (built.diagnostics) |d| {
        try testing.expectEqual(diagnostic.Code.foreign_export_mismatch, d.code);
        try testing.expectEqualStrings("bare/beni.json", d.span.file);
        if (std.mem.indexOf(u8, d.message, "`run`") != null) {
            try testing.expectEqualDeep(run_missing, d);
            found = true;
        }
    }
    try testing.expect(found);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

/// A platform whose one module is its own vocabulary, `Voc`, with the markup
/// type `Voc.Node`.
fn writeVocabularyPlatform(w: *World, voc: []const u8) !void {
    try w.write("vocab/beni.json",
        \\{ "platform": true, "name": "vocab", "markup": { "vocabulary": "Voc", "type": "Voc.Node" } }
    );
    try w.write("vocab/Voc.beni", voc);
    try w.write("Main.beni", "x : Int\nx =\n    1\n");
}

test "the vocabulary module may write markup against its own declarations" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `frontend.md` §9.8: the markup edge is never added from a module to
    // itself, so a vocabulary module that writes markup is no cycle, and
    // its markup is typed against the rows it has already checked, read
    // from its own record (`checker-v2.md` §25.2).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeVocabularyPlatform(&w,
        \\pub foreign type Node msg
        \\
        \\
        \\pub element "p"
        \\
        \\
        \\pub view : Node msg
        \\view =
        \\    <p />
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=vocab", "Main.beni" });
    const dumped = try w.runWith(&.{ "dump", "--stage=dispatch", "--platform=vocab", "vocab/Voc.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
    try testing.expectEqual(@as(u8, 0), dumped.exit_code);
    try testing.expectEqualStrings(
        \\module Voc
        \\  decl view evidence=0 arity=0 convention=plain
        \\  markup 3 element Voc.p
        \\
    , dumped.stdout);
}

test "a foreign that mentions the markup type is legal in the platform that names the build's lowering" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `checker-v2.md` §25.2: a `foreign` whose type mentions the markup type
    // reads one lowering's markup, which is right exactly when its own
    // platform names the build's lowering. `top` names `strings` over
    // `html`'s vocabulary, so its `render` is legal; this binary has no
    // lowering called `strings`, and that is the one diagnostic.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("top/beni.json",
        \\{ "platform": true, "name": "top", "platforms": ["html"], "markup": { "lowering": "strings", "runtime": "markup.js" } }
    );
    try w.write("top/Render.beni",
        \\import Html exposing (Html)
        \\
        \\
        \\pub foreign pure render : Html msg → String
        \\
    );
    try w.write("top/Render.js", "export const render = (html) => String(html);\n");
    try w.write("top/markup.js", "export const text = (s) => s;\nexport const map = (h, f) => h;\n");
    try w.write("Main.beni", "x : Int\nx =\n    1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=top", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expectEqual(@as(usize, 1), checked.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.unknown_markup_lowering, checked.diagnostics[0].code);
}

test "a module the vocabulary module imports that writes markup closes a cycle through the markup edge" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Voc` imports `Card`, and `Card` writes markup, so `Card` depends on
    // `Voc` without importing it (`frontend.md` §9.8): an `import_cycle`,
    // whose message names the markup edge so the circle is legible.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeVocabularyPlatform(&w,
        \\import Card
        \\
        \\
        \\pub foreign type Node msg
        \\
        \\
        \\pub element "p"
        \\
        \\
        \\pub width : Int
        \\width =
        \\    Card.width
        \\
    );
    try w.write("vocab/Card.beni",
        \\pub width : Int
        \\width =
        \\    1
        \\
        \\
        \\view =
        \\    <p />
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=vocab", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expectEqual(@as(usize, 1), checked.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .import_cycle,
        .severity = .@"error",
        .span = .{ .file = "vocab/Card.beni", .start = .{ .line = 7, .col = 5 }, .end = .{ .line = 7, .col = 6 } },
        .title = "IMPORT CYCLE",
        .message = "These modules import each other in a circle:\n" ++
            "\n" ++
            "    Card → Voc → Card\n" ++
            "\n" ++
            "`Card` uses markup, so depends on the vocabulary module `Voc` without importing\n" ++
            "it (`docs/design/frontend.md` §9.8).\n" ++
            "\n" ++
            "Beni compiles modules in dependency order, so a circle has no place to start.\n" ++
            "Move what they share into a module of its own and have both import that.",
    }, checked.diagnostics[0]);
}

test "a vocabulary that names no module of the chain leaves markup with no vocabulary" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("vocab/beni.json",
        \\{ "platform": true, "name": "vocab", "markup": { "vocabulary": "Missing", "type": "Missing.Node" } }
    );
    try w.write("vocab/Voc.beni", "pub x : Int\nx =\n    1\n");
    try w.write("Main.beni", "view =\n    <p />\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=vocab", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expectEqual(@as(usize, 1), checked.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .no_markup_vocabulary,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 2, .col = 5 }, .end = .{ .line = 2, .col = 6 } },
        .title = "NO MARKUP VOCABULARY",
        .message = "This module writes markup, but there is no markup vocabulary to check it\n" ++
            "against.\n" ++
            "\n" ++
            "Which elements, attributes and events exist is declared by a platform package\n" ++
            "(`pub element`, `pub attribute`, `pub event`), and a module's markup is typed\n" ++
            "against the vocabulary of the platform its build names with `--platform=<name>`.\n" ++
            "The `\"markup\"` `\"vocabulary\"` of this build's platform names no module of the\n" ++
            "platform or the platforms it depends on (`docs/design/boundary.md` §9.2).",
    }, checked.diagnostics[0]);
}

/// The bytes of `out/_main.mjs` of a release build of `args` in `w`.
fn releaseMain(w: *World, args: []const []const u8) ![]const u8 {
    const arena = w.arena.allocator();
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(arena, &.{ "build", "--release", "--no-source-maps", "--out=out" });
    try all.appendSlice(arena, args);
    const built = try w.run(all.items);
    try testing.expectEqual(@as(usize, 0), built.diagnostics.len);
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    return w.read("out/_main.mjs");
}

/// A shipped platform's directory in this checkout, absolute.
fn shippedDir(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const rel = try std.fmt.allocPrint(arena, "platforms/{s}", .{name});
    return std.Io.Dir.cwd().realPathFileAlloc(testing.io, rel, arena);
}

test "a shipped platform named by its directory builds a program as it does by its name" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // browser-inline.md §8.3, amended 2026-10-19 (the review of #390): the
    // write-set pass reads as the program's own code only the layers above
    // the platform, decided by layer role and not by where a layer is read
    // from, so the platform read from a directory keeps its programs.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const src = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/corpus/browser/inline/CounterLocal.beni", arena, .limited(1 << 20));
    try w.write("Main.beni", src);
    const dir = try shippedDir(arena, "browser-inline");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const by_name = try arena.dupe(u8, try releaseMain(&w, &.{ "--platform=browser-inline", "Main.beni" }));
    const by_dir = try releaseMain(&w, &.{ try std.fmt.allocPrint(arena, "--platform={s}", .{dir}), "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(by_name, by_dir);
}

test "a project layer over a shipped platform named by its directory builds as over the shipped one" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The layer is the program's own code either way; the base below it is
    // the platform either way (browser-inline.md §8.3, amended 2026-10-19).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    try w.copyTree("tests/corpus/browser/inline/PlatformRecord", "_expected.");
    const dir = try shippedDir(arena, "browser-inline");
    const manifest = try w.read("platform/beni.json");
    const named = try std.mem.replaceOwned(u8, arena, manifest, "\"browser-inline\"", try std.fmt.allocPrint(arena, "\"{s}\"", .{dir}));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const over_shipped = try arena.dupe(u8, try releaseMain(&w, &.{ "--platform=platform", "Main.beni" }));
    try w.write("platform/beni.json", named);
    const over_dir = try releaseMain(&w, &.{ "--platform=platform", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expect(!std.mem.eql(u8, manifest, named));
    try testing.expectEqualStrings(over_shipped, over_dir);
}

test "browser-inline named by its directory keeps a program's keys apart" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The review of #390: with every platform module read from disk taken
    // for the program's own code, `browser-direct` by directory found no
    // program, and the keys' handlers merged. That was red on
    // `browser-direct` alone: on `browser-inline` the platform by directory
    // already built the same page (the test above), and this one only
    // keeps the claim for a program of several keys (`FormLocal`'s six).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const src = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/corpus/browser/inline/FormLocal.beni", arena, .limited(1 << 20));
    try w.write("Main.beni", src);
    const dir = try shippedDir(arena, "browser-inline");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const by_name = try arena.dupe(u8, try releaseMain(&w, &.{ "--platform=browser-inline", "Main.beni" }));
    const by_dir = try releaseMain(&w, &.{ try std.fmt.allocPrint(arena, "--platform={s}", .{dir}), "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(by_name, by_dir);
}

/// A generic beni entry runtime, with no markup lowering or JavaScript file.
fn writeGenericRuntime(w: *World, runtime: []const u8) !void {
    try w.write("platform/beni.json",
        \\{"platform":true,"name":"generic","program":"Start.Program","entryKinds":[{"programType":"Start.Program","realm":"node","runtime":"Rt","constructors":[],"launches":[],"parameters":[]}]}
    );
    try w.write("platform/Start.beni",
        \\pub type Program = Program String
        \\
        \\pub make : String → Program
        \\make value = Program value
        \\
        \\pub text : Program → String
        \\text (Program value) = value
        \\
    );
    try w.write("platform/Rt.beni", runtime);
    try w.write("Main.beni",
        \\import Start
        \\
        \\main : Start.Program
        \\main = Start.make "generic runtime"
        \\
    );
}

test "generic entry runtime runs without markup in development and release" {
    // PREPARE: the app never imports Rt, whose run is a metadata root.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeGenericRuntime(&w,
        \\import Js
        \\import Start exposing (Program)
        \\
        \\pub type alias App = Program
        \\
        \\pub run : App → ⊤
        \\run program =
        \\    _ = Js.call (Js.global "console") "log" [ Js.from (Start.text program) ]
        \\    ⊤
        \\
    );

    // EXECUTE and VERIFY OUTPUT: both modes execute the real emitted entry.
    for ([_][]const []const u8{
        &.{ "build", "--platform=platform", "--out=out", "Main.beni" },
        &.{ "build", "--platform=platform", "--release", "--out=out", "Main.beni" },
    }) |args| {
        const built = try w.run(args);
        try testing.expectEqual(@as(u8, 0), built.exit_code);
        try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), built.diagnostics);
        try w.expectProgram("out/_main.mjs", .{ .stdout = "generic runtime\n", .exit_code = 0 });
        try testing.expect(!w.exists("out/_platform/runtime.foreign.mjs"));
    }
}

test "generic entry runtime signature failures agree in check and build" {
    const bad = [_]struct { runtime: []const u8, name: []const u8 }{
        .{ .runtime = "pub run = ⊤\n", .name = "not a function" },
        .{ .runtime = "pub run : Int\nrun = 1\n", .name = "integer value" },
        .{ .runtime = "import Start exposing (Program)\npub run : Program, Int → ⊤\nrun _ _ = ⊤\n", .name = "wrong arity" },
        .{ .runtime = "pub run : Int → ⊤\nrun _ = ⊤\n", .name = "wrong Program" },
        .{ .runtime = "import Start exposing (Program)\npub run : Program → Int\nrun _ = 1\n", .name = "wrong result" },
    };
    for (bad) |scenario| {
        _ = scenario.name;
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try writeGenericRuntime(&w, scenario.runtime);
        for ([_][]const []const u8{
            &.{ "check", "--platform=platform", "Main.beni" },
            &.{ "build", "--platform=platform", "--out=out", "Main.beni" },
        }) |args| {
            const result = try w.run(args);
            try testing.expectEqual(@as(u8, 1), result.exit_code);
            try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
            // Diagnostics underline the definition name. Wrong Program has
            // no import and therefore starts on the preceding line.
            const line: u32 = if (std.mem.eql(u8, scenario.name, "not a function")) 1 else if (std.mem.eql(u8, scenario.name, "wrong Program") or std.mem.eql(u8, scenario.name, "integer value")) 2 else 3;
            try testing.expectEqualDeep(diagnostic.Diagnostic{
                .code = .invalid_entry_kind,
                .severity = .@"error",
                .span = .{ .file = "platform/Rt.beni", .start = .{ .line = line, .col = if (line == 1) 5 else 1 }, .end = .{ .line = line, .col = if (line == 1) 8 else 4 } },
                .title = "INVALID ENTRY KIND",
                .message = "`Rt.run` must take exactly one `Start.Program` and return `⊤`, with no evidence\nparameters or specialized type arguments.",
            }, result.diagnostics[0]);
            try testing.expect(!w.exists("out"));
        }
    }
}

test "generic entry runtime cannot suspend through a helper" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeGenericRuntime(&w,
        \\import Duration
        \\import Start exposing (Program)
        \\import Task
        \\
        \\pause : ⊤ → ⊤
        \\pause ⊤ = Task.sleep (Duration.millis 1)
        \\
        \\pub run : Program → ⊤
        \\run _ = pause ⊤
        \\
    );
    for ([_][]const []const u8{
        &.{ "check", "--platform=platform", "Main.beni" },
        &.{ "build", "--platform=platform", "--out=out", "Main.beni" },
    }) |args| {
        const result = try w.run(args);
        try testing.expectEqual(@as(u8, 1), result.exit_code);
        try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
        try testing.expectEqualDeep(diagnostic.Diagnostic{
            .code = .entry_runtime_suspends,
            .severity = .@"error",
            .span = .{ .file = "platform/Rt.beni", .start = .{ .line = 9, .col = 1 }, .end = .{ .line = 9, .col = 4 } },
            .title = "ENTRY RUNTIME SUSPENDS",
            .message = "`Rt.run` may suspend, but the generated entry calls it synchronously. Install\nlisteners, start an owned root fiber, then return; initialization may suspend\ninside that fiber.",
        }, result.diagnostics[0]);
        try testing.expect(!w.exists("out"));
    }
}

test "generic entry runtime metadata is checked rather than silently ignored" {
    const scenarios = [_]struct { kinds: []const u8, message: []const u8 }{
        .{
            .kinds = "[{\"programType\":\"Missing.Program\",\"realm\":\"node\",\"runtime\":\"Rt\",\"constructors\":[],\"launches\":[],\"parameters\":[]}]",
            .message = "I cannot find the entry kind's Program module `Missing`.",
        },
        .{
            .kinds = "[{\"programType\":\"Start.Program\",\"realm\":\"space\",\"runtime\":\"Rt\",\"constructors\":[],\"launches\":[],\"parameters\":[]}]",
            .message = "The entry kind `Start.Program` names unknown realm `space`.",
        },
        .{
            .kinds = "[{\"programType\":\"Start.Program\",\"realm\":\"node\",\"runtime\":\"Missing\",\"constructors\":[],\"launches\":[],\"parameters\":[]}]",
            .message = "The entry kind `Start.Program` needs runtime module `Missing` with a public beni\n`run` value.",
        },
        .{
            .kinds = "[{\"programType\":\"Start.Program\",\"realm\":\"node\",\"runtime\":\"Rt\",\"constructors\":[],\"launches\":[],\"parameters\":[]},{\"programType\":\"Start.Program\",\"realm\":\"node\",\"runtime\":\"Rt\",\"constructors\":[],\"launches\":[],\"parameters\":[]}]",
            .message = "The entry kind `Start.Program` is declared more than once. A Program type\nidentifies one entry kind.",
        },
        .{
            .kinds = "[{\"programType\":\"Start.Program\",\"realm\":\"node\",\"runtime\":\"Rt\",\"constructors\":[{\"name\":\"Start.make\",\"parameter\":0,\"callbackProtocol\":\"handlers\"}],\"launches\":[],\"parameters\":[]}]",
            .message = "The entry constructor `Start.make` needs a closed `handlers` callback record\nwith the protocol's field arities.",
        },
        .{
            .kinds = "[{\"programType\":\"Start.Program\",\"realm\":\"node\",\"runtime\":\"Rt\",\"launches\":[{\"name\":\"Start.text\",\"parameter\":1}],\"constructors\":[],\"parameters\":[]}]",
            .message = "The entry launch `Start.text` has an invalid Program parameter index or type.",
        },
        .{
            .kinds = "[{\"programType\":\"Start.Program\",\"realm\":\"node\",\"runtime\":\"Rt\",\"parameters\":[{\"index\":0,\"role\":\"local\"}],\"constructors\":[],\"launches\":[]}]",
            .message = "The entry kind `Start.Program` has an invalid type-parameter role at index 0.",
        },
    };
    for (scenarios) |scenario| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try writeGenericRuntime(&w,
            \\import Start exposing (Program)
            \\pub run : Program → ⊤
            \\run _ = ⊤
            \\
        );
        try w.write("platform/beni.json", try std.fmt.allocPrint(w.arena.allocator(), "{{\"platform\":true,\"program\":\"Start.Program\",\"entryKinds\":{s}}}", .{scenario.kinds}));
        for ([_][]const []const u8{
            &.{ "check", "--platform=platform", "Main.beni" },
            &.{ "build", "--platform=platform", "--out=out", "Main.beni" },
        }) |args| {
            const result = try w.run(args);
            try testing.expectEqual(@as(u8, 1), result.exit_code);
            try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
            try testing.expectEqualDeep(diagnostic.Diagnostic{
                .code = .invalid_entry_kind,
                .severity = .@"error",
                .span = .{ .file = "platform/beni.json", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
                .title = "INVALID ENTRY KIND",
                .message = scenario.message,
            }, result.diagnostics[0]);
            try testing.expect(!w.exists("out"));
        }
    }
}

test "generic entry runtime preserves polymorphic Program arguments" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeGenericRuntime(&w,
        \\import Start
        \\
        \\type alias App a = Start.Program a
        \\
        \\pub run : App a → ⊤
        \\run _ = ⊤
        \\
    );
    try w.write("platform/beni.json",
        \\{"platform":true,"program":"Start.Program","entryKinds":[{"programType":"Start.Program","realm":"node","runtime":"Rt","parameters":[{"index":0,"role":"local"}],"constructors":[],"launches":[]}]}
    );
    try w.write("platform/Start.beni",
        \\pub type Program a = Program a
        \\
        \\pub make : a → Program a
        \\make value = Program value
        \\
    );
    try w.write("Main.beni",
        \\import Start
        \\
        \\main : Start.Program String
        \\main = Start.make "generic runtime"
        \\
    );
    const built = try w.run(&.{ "build", "--platform=platform", "--out=out", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), built.diagnostics);
    try w.expectProgram("out/_main.mjs", .{ .stdout = "", .exit_code = 0 });

    // The same generic contract cannot choose Int, number or evidence for a.
    for ([_][]const u8{
        "import Start\npub run : Start.Program Int → ⊤\nrun _ = ⊤\n",
        "import Start\npub run : Start.Program number → ⊤\nrun _ = ⊤\n",
        "import Start\npub run : Start.Program a → ⊤ where a.eq : a, a → Bool\nrun _ = ⊤\n",
    }) |bad_runtime| {
        try w.write("platform/Rt.beni", bad_runtime);
        const refused = try w.run(&.{ "build", "--platform=platform", "--out=bad", "Main.beni" });
        try testing.expectEqual(@as(u8, 1), refused.exit_code);
        try testing.expectEqual(@as(usize, 1), refused.diagnostics.len);
        try testing.expectEqualDeep(diagnostic.Diagnostic{
            .code = .invalid_entry_kind,
            .severity = .@"error",
            .span = .{ .file = "platform/Rt.beni", .start = .{ .line = 3, .col = 1 }, .end = .{ .line = 3, .col = 4 } },
            .title = "INVALID ENTRY KIND",
            .message = "`Rt.run` must take exactly one `Start.Program` and return `⊤`, with no evidence\nparameters or specialized type arguments.",
        }, refused.diagnostics[0]);
        try testing.expect(!w.exists("bad"));
    }
}

test "generic entry runtime rejects an unresolved callback effect dependency" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeGenericRuntime(&w,
        \\import Start exposing (Program)
        \\pub run : Program → ⊤
        \\run program = Start.invoke program
        \\
    );
    try w.write("platform/Start.beni",
        \\pub type Program = Program (⊤ → ⊤)
        \\
        \\pub make : (⊤ → ⊤) → Program
        \\make body = Program body
        \\
        \\pub invoke : Program → ⊤
        \\invoke (Program body) = body ⊤
        \\
    );
    try w.write("Main.beni",
        \\import Start
        \\
        \\main : Start.Program
        \\main = Start.make (λ⊤ → ⊤)
        \\
    );
    const refused = try w.run(&.{ "check", "--platform=platform", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), refused.exit_code);
    try testing.expectEqual(@as(usize, 1), refused.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .entry_runtime_suspends,
        .severity = .@"error",
        .span = .{ .file = "platform/Rt.beni", .start = .{ .line = 3, .col = 1 }, .end = .{ .line = 3, .col = 4 } },
        .title = "ENTRY RUNTIME SUSPENDS",
        .message = "`Rt.run` may suspend, but the generated entry calls it synchronously. Install\nlisteners, start an owned root fiber, then return; initialization may suspend\ninside that fiber.",
    }, refused.diagnostics[0]);
    try testing.expect(!w.exists("out"));
}

test "generic entry runtime unit result cannot supply exports program" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeGenericRuntime(&w,
        \\import Start exposing (Program)
        \\pub run : Program → ⊤
        \\run _ = ⊤
        \\
    );
    try w.write("platform/beni.json",
        \\{"platform":true,"program":"Start.Program","exports":"program","entryKinds":[{"programType":"Start.Program","realm":"node","runtime":"Rt","constructors":[],"launches":[],"parameters":[]}]}
    );
    for ([_][]const []const u8{
        &.{ "check", "--platform=platform", "Main.beni" },
        &.{ "build", "--platform=platform", "--out=out", "Main.beni" },
    }) |args| {
        const refused = try w.run(args);
        try testing.expectEqual(@as(u8, 1), refused.exit_code);
        try testing.expectEqual(@as(usize, 1), refused.diagnostics.len);
        try testing.expectEqualDeep(diagnostic.Diagnostic{
            .code = .invalid_entry_kind,
            .severity = .@"error",
            .span = .{ .file = "platform/beni.json", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
            .title = "INVALID ENTRY KIND",
            .message = "The generic entry runtime for `Start.Program` returns `⊤`, so it cannot also\nsupply the result required by exports program.",
        }, refused.diagnostics[0]);
        try testing.expect(!w.exists("out"));
    }
}

test "generic entry runtime rejects a shadowed application Program" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeGenericRuntime(&w,
        \\import Start exposing (Program)
        \\pub run : Program → ⊤
        \\run _ = ⊤
        \\
    );
    try w.write("Start.beni",
        \\pub type Program = Program String
        \\pub make : String → Program
        \\make text = Program text
        \\
    );
    // check validates modules without demanding an entry; build checks main.
    {
        const result = try w.run(&.{ "build", "--platform=platform", "--out=out", "Main.beni", "Start.beni" });
        try testing.expectEqual(@as(u8, 1), result.exit_code);
        try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
            .code = .main_not_program,
            .severity = .@"error",
            .span = .{ .file = "Main.beni", .start = .{ .line = 4, .col = 1 }, .end = .{ .line = 4, .col = 5 } },
            .title = "MAIN IS NOT A PROGRAM",
            .message = "`main` must use the platform's `Start.Program`.\n\nThis annotation names `Start.Program` from a different package. Matching names\nare not the same nominal type. Rename the local module so it does not shadow\nthe platform module.",
        }}, result.diagnostics);
        try testing.expect(!w.exists("out"));
    }
}

test "generic entry runtime requires a closed callback record" {
    for ([_]bool{ false, true }) |open| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try writeGenericRuntime(&w,
            \\import Start exposing (Program)
            \\pub run : Program → ⊤
            \\run _ = ⊤
            \\
        );
        const start = try w.read("platform/Start.beni");
        try w.write("platform/Start.beni", try std.fmt.allocPrint(
            w.arena.allocator(),
            "{s}\npub construct : {{ {s}init : (Int, Int → Int), start : (Int, Int → Int), handle : (Int, Int, Int → Int), stream : (Int, Int, Int, Int → Int) }} → Program\nconstruct _ = Program \"callback\"\n",
            .{ start, if (open) "r | " else "" },
        ));
        try w.write("platform/beni.json",
            \\{"platform":true,"program":"Start.Program","entryKinds":[{"programType":"Start.Program","realm":"node","runtime":"Rt","constructors":[{"name":"Start.construct","parameter":0,"callbackProtocol":"handlers"}],"launches":[],"parameters":[]}]}
        );
        for ([_][]const []const u8{
            &.{ "check", "--platform=platform", "Main.beni" },
            &.{ "build", "--platform=platform", "--out=out", "Main.beni" },
        }) |args| {
            const result = try w.run(args);
            if (!open) {
                try testing.expectEqual(@as(u8, 0), result.exit_code);
                try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
            } else {
                try testing.expectEqual(@as(u8, 1), result.exit_code);
                try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
                    .code = .invalid_entry_kind,
                    .severity = .@"error",
                    .span = .{ .file = "platform/beni.json", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
                    .title = "INVALID ENTRY KIND",
                    .message = "The entry constructor `Start.construct` needs a closed `handlers` callback\nrecord with the protocol's field arities.",
                }}, result.diagnostics);
                try testing.expect(!w.exists("out"));
            }
        }
    }
}

test "generic entry runtime metadata recheck replaces the selected runtime" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeGenericRuntime(&w,
        \\import Start exposing (Program)
        \\pub run : Program → ⊤
        \\run _ = ⊤
        \\
    );
    const first = try w.run(&.{ "build", "--platform=platform", "--out=first", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), first.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), first.diagnostics);
    try w.expectProgram("first/_main.mjs", .{ .stdout = "", .exit_code = 0 });

    // The checked interfaces can be cached, but the new manifest selects Other.
    try w.write("platform/Other.beni",
        \\import Js
        \\import Start exposing (Program)
        \\pub run : Program → ⊤
        \\run _ =
        \\    _ = Js.call (Js.global "console") "log" [ Js.from "replacement runtime" ]
        \\    ⊤
        \\
    );
    try w.write("platform/beni.json",
        \\{"platform":true,"program":"Start.Program","entryKinds":[{"programType":"Start.Program","realm":"node","runtime":"Other","constructors":[],"launches":[],"parameters":[]}]}
    );
    const checked = try w.run(&.{ "check", "--platform=platform", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), checked.diagnostics);
    const replacement = try w.run(&.{ "build", "--platform=platform", "--out=second", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), replacement.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), replacement.diagnostics);
    try w.expectProgram("second/_main.mjs", .{ .stdout = "replacement runtime\n", .exit_code = 0 });

    // A rejected recheck cannot retain either previously accepted runner.
    try w.write("platform/Other.beni",
        \\import Start exposing (Program)
        \\pub run : Program → Int
        \\run _ = 1
        \\
    );
    for ([_][]const []const u8{
        &.{ "check", "--platform=platform", "Main.beni" },
        &.{ "build", "--platform=platform", "--out=rejected", "Main.beni" },
    }) |args| {
        const refused = try w.run(args);
        try testing.expectEqual(@as(u8, 1), refused.exit_code);
        try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
            .code = .invalid_entry_kind,
            .severity = .@"error",
            .span = .{ .file = "platform/Other.beni", .start = .{ .line = 3, .col = 1 }, .end = .{ .line = 3, .col = 4 } },
            .title = "INVALID ENTRY KIND",
            .message = "`Other.run` must take exactly one `Start.Program` and return `⊤`, with no\nevidence parameters or specialized type arguments.",
        }}, refused.diagnostics);
        try testing.expect(!w.exists("rejected"));
    }
}

test "generic entry runtime requires every manifest table" {
    const tables = [_][]const u8{ "constructors", "launches", "parameters" };
    for (tables, 0..) |_, omitted| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try writeGenericRuntime(&w,
            \\import Start exposing (Program)
            \\pub run : Program → ⊤
            \\run _ = ⊤
            \\
        );
        var manifest: std.Io.Writer.Allocating = .init(w.arena.allocator());
        try manifest.writer.writeAll("{\"platform\":true,\"program\":\"Start.Program\",\"entryKinds\":[{\"programType\":\"Start.Program\",\"realm\":\"node\",\"runtime\":\"Rt\"");
        for (tables, 0..) |table, index| if (index != omitted) {
            try manifest.writer.print(",\"{s}\":[]", .{table});
        };
        try manifest.writer.writeAll("}]}");
        try w.write("platform/beni.json", manifest.written());
        for ([_][]const []const u8{
            &.{ "check", "--platform=platform", "Main.beni" },
            &.{ "build", "--platform=platform", "--out=out", "Main.beni" },
        }) |args| {
            const result = try w.runWith(args, .{ .raw_diagnostics = true });
            try testing.expectEqual(@as(u8, 2), result.exit_code);
            try testing.expectEqualStrings("", result.stdout);
            try testing.expectEqualStrings("beni: cannot read 'platform/beni.json': it is not a JSON object\n", result.stderr);
            try testing.expect(!w.exists("out"));
        }
    }
}
