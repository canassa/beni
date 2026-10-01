//! `beni check --platform=<name>` end to end (docs/design/frontend.md §1,
//! boundary.md §5.3, §4).
//!
//! Boundary 1 throughout: the installed binary against a temp project,
//! asserting diagnostics, exit codes and what did NOT land on disk. The
//! scenarios exist because without `--platform` on `check`, the one command
//! whose job is "just type-check it" could not be pointed at any program
//! that imports its platform for `Program` — which is every program, and
//! what an editor, a pre-commit hook, CI, the daemon and the LSP all run.
//!
//! The load-bearing claim of the file is that `check --platform=X` and
//! `build --platform=X` AGREE: the same diagnostics, byte for byte, up to the
//! point where one of them writes files. Anything less and a green `check` is
//! not evidence about the build behind it.
//!
//! Nothing here imports a compiler internal: `std`, the harness and the
//! public diagnostic schema, which the build graph enforces.

const std = @import("std");
const diagnostic = @import("diagnostic");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

/// A program that imports its platform for `Program`, which is the shape of
/// every program (`boundary.md` §5) and the shape `check` could not load.
fn writeProgram(w: *World) !void {
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print "hi"
        \\
    );
}

/// The user-written platform of `build_test.zig`, copied here rather than
/// shared because each blackbox file is its own module: a package that
/// declares itself a platform in its manifest (`boundary.md` §2).
fn writeUserPlatform(w: *World) !void {
    try w.write("myplat/beni.json",
        \\{ "platform": true, "name": "mine", "program": "Prog.Program", "runtime": "run.js" }
    );
    try w.write("myplat/Prog.beni",
        \\pub foreign type Program
        \\
        \\
        \\pub foreign pure say : String -> Program
        \\
    );
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ text: line });
        \\
    );
    try w.write("myplat/run.js",
        \\import process from "node:process";
        \\
        \\export const run = (program) => {
        \\  process.stdout.write(program.text + "!\n");
        \\};
        \\
    );
}

test "a program that imports its platform type-checks with --platform, and cannot without it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProgram(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=node", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
    try testing.expectEqualStrings("", checked.stderr);
    // `check` prints nothing on stdout, platform or no platform
    // (`frontend.md` §1).
    try testing.expectEqualStrings("", checked.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Checking is not building: no output directory, whatever `build` would
    // have written.
    try testing.expect(!w.exists("out"));
    try testing.expect(!w.exists("_main.mjs"));
}

test "check and build report the same type error, byte for byte" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The whole point of the flag: a `check` that passes where the `build`
    // behind it fails is not evidence. So the two streams are compared as
    // bytes rather than field by field.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print 7
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=node", "Main.beni" });
    const built = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expectEqual(@as(u8, 1), built.exit_code);
    try testing.expectEqualStrings(built.stderr, checked.stderr);
    try testing.expectEqual(@as(usize, 1), checked.diagnostics.len);
    const d = checked.diagnostics[0];
    // `7` against `String` is the number obligation failing, which is
    // `kind_mismatch` under a TYPE MISMATCH title (checker.md §8).
    try testing.expectEqual(diagnostic.Code.kind_mismatch, d.code);
    try testing.expectEqual(diagnostic.Severity.@"error", d.severity);
    try testing.expectEqualStrings("TYPE MISMATCH", d.title);
    try testing.expectEqualStrings("Main.beni", d.span.file);
    try testing.expectEqual(@as(u32, 6), d.span.start.line);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "without --platform, the unknown module names the flag that would supply it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProgram(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The old behaviour, kept: a program that does not name its platform
    // still fails, because the module really is not there. What is new is
    // the closing paragraph, and it is a fact about THIS binary — `Node` is
    // a module of a platform embedded in it.
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 3), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .unknown_module,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 12 } },
        .title = "UNKNOWN MODULE",
        .message =
        \\I cannot find a module named `Node`.
        \\
        \\I looked in this project and in the core package. Check the spelling, or check
        \\that a file named `Node.beni` exists under the source root.
        \\
        \\`Node` is a module of the `node` platform, which ships with the compiler, and a
        \\platform's modules are in scope only when the platform is named. Add
        \\`--platform=node`.
        ,
    }, r.diagnostics[0]);
    // The qualified uses that follow the failed import carry it too: the fix
    // is the same flag wherever the reader's eye lands.
    try testing.expectEqual(diagnostic.Code.unknown_module_alias, r.diagnostics[1].code);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[1].message, "`--platform=node`") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT: the hint stays honest    │
    // └─────────────────────────────────────────┘
    // A module that is not a platform's gets today's message and no guess.
    try w.write("Other.beni",
        \\import Graphics
        \\
        \\
        \\pub value : Int
        \\value =
        \\    1
        \\
    );
    const other = try w.run(&.{ "check", "Other.beni" });
    try testing.expectEqual(@as(u8, 1), other.exit_code);
    try testing.expectEqual(@as(usize, 1), other.diagnostics.len);
    try testing.expectEqualStrings(
        \\I cannot find a module named `Graphics`.
        \\
        \\I looked in this project and in the core package. Check the spelling, or check
        \\that a file named `Graphics.beni` exists under the source root.
    , other.diagnostics[0].message);

    // And with the platform named, the hint has nothing to say: the module
    // is there.
    const with = try w.run(&.{ "check", "--platform=node", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), with.exit_code);
}

test "dump --stage=interface --platform=node prints the interface of a program" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `dump` takes the flag for the stages that RESOLVE imports
    // (`frontend.md` §1); `--stage=interface` is the one a `check/good`
    // corpus golden is made of, and it was as unreachable for a program as
    // `check` was.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\pub run : String -> Program
        \\run line =
        \\    Node.print line
        \\
        \\
        \\main : Program
        \\main =
        \\    run "hi"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "dump", "--stage=interface", "--platform=node", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The interface of a module whose exported type comes from the platform:
    // unreachable without `--platform`, because the import does not resolve.
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualStrings(
        \\module Main
        \\  value run : String -> Program
        \\
    , r.stdout);

    // Without it the dump cannot resolve the import and says so, exactly as
    // `check` does — the dump's product is still printed, because `dump`
    // exits 0 with diagnostics on stderr (`frontend.md` §1).
    const without = try w.run(&.{ "dump", "--stage=interface", "Main.beni" });
    try testing.expect(std.mem.indexOf(u8, without.stderr, "`--platform=node`") != null);
}

test "check --platform runs boundary.md §4's sibling checks, and writes nothing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A `foreign_arity_mismatch` is exactly what a pre-commit check exists
    // to catch: the sibling built cleanly and failed at run time
    // (`boundary.md` §4, check 4). The checks read `.js` files and need no
    // output directory, so `check` can run all four.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/Prog.js",
        \\export const say = (line, extra) => ({ text: line });
        \\
    );
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say "hello"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=myplat", "Main.beni" });
    const built = try w.run(&.{ "build", "--platform=myplat", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expectEqual(@as(usize, 1), checked.diagnostics.len);
    const d = checked.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.foreign_arity_mismatch, d.code);
    try testing.expectEqual(diagnostic.Severity.@"error", d.severity);
    try testing.expectEqualStrings("myplat/Prog.beni", d.span.file);
    // The same defect, the same message, from either command.
    try testing.expectEqualStrings(built.stderr, checked.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "check --platform does not require a main, and does not mind two" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The entry point is half of a BUILD pair (`boundary.md` §5.3), and
    // `check` is handed paths: one module of a project, or a repository with
    // a client and a server. So `missing_main` and the two-`main` refusal
    // stay `build`'s, and naming a platform never conscripts a library into
    // being a program.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Lib.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\pub greet : String -> Program
        \\greet name =
        \\    Node.print name
        \\
    );
    try w.write("Client.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print "client"
        \\
    );
    try w.write("Server.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print "server"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const library = try w.run(&.{ "check", "--platform=node", "Lib.beni" });
    const both = try w.run(&.{ "check", "--platform=node", "Client.beni", "Server.beni" });
    const built = try w.run(&.{ "build", "--platform=node", "--out=out", "Client.beni", "Server.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), library.exit_code);
    try testing.expectEqualStrings("", library.stderr);
    try testing.expectEqual(@as(u8, 0), both.exit_code);
    try testing.expectEqualStrings("", both.stderr);
    // And `build`, given the same pair, still refuses: that half is the
    // build's and has not moved.
    try testing.expectEqual(@as(u8, 1), built.exit_code);
    try testing.expectEqual(@as(usize, 1), built.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.duplicate_main, built.diagnostics[0].code);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "check --platform keeps its warnings and its exit code" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The measurement `check --platform` unblocks: counting
    // `ambiguous_method_receiver` over programs
    // (`static-dispatch-spike.md` §10.9, A.83) needed `build`, because
    // `check` could not load a program at all. A warning does not change an
    // exit code (`frontend.md` §1), so the run is still green.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\pub bigger a b =
        \\    a < b
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print "ok"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=node", "Main.beni" });
    const built = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqual(@as(usize, 1), checked.diagnostics.len);
    const d = checked.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.ambiguous_method_receiver, d.code);
    try testing.expectEqual(diagnostic.Severity.warning, d.severity);
    try testing.expectEqualStrings("CONSTRAINT IN AN INFERRED INTERFACE", d.title);
    // One array on the stream and the same one `build` prints.
    try testing.expectEqualStrings(built.stderr, checked.stderr);
}

test "an unknown platform is the same usage failure for check as for build" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProgram(&w);
    // A directory that is a package and not a PLATFORM package: it declares
    // nothing about itself, so nothing may be assumed about it
    // (`boundary.md` §5.3, §2).
    try w.write("notaplat/Prog.beni", "pub x : Int\nx =\n    1\n");
    // Checked with a module that needs no platform, so the manifest failure
    // is what the run reports rather than the unresolved import: the
    // platform's own manifest is read AFTER the check phases, in both
    // commands, and a project that does not check has nothing to say about
    // its platform yet.
    try w.write("Plain.beni", "pub x : Int\nx =\n    1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.runWith(&.{ "check", "--platform=nope", "Main.beni" }, .{ .raw_diagnostics = true });
    const built = try w.runWith(&.{ "build", "--platform=nope", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });
    const directory = try w.runWith(&.{ "check", "--platform=notaplat", "Plain.beni" }, .{ .raw_diagnostics = true });
    const built_directory = try w.runWith(&.{ "build", "--platform=notaplat", "--out=out", "Plain.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Exit 2 and one line on stderr: a usage failure, not a diagnostic
    // (`frontend.md` §1).
    try testing.expectEqual(@as(u8, 2), checked.exit_code);
    try testing.expectEqual(@as(u8, 2), built.exit_code);
    try testing.expectEqualStrings(built.stderr, checked.stderr);
    try testing.expect(std.mem.indexOf(u8, checked.stderr, "unknown platform 'nope'") != null);
    try testing.expect(std.mem.indexOf(u8, checked.stderr, "node") != null);
    // A directory with no `beni.json` is refused by the same rule and with
    // the same message the build gives: `check` reads the platform's own
    // manifest for no other purpose than this, so that "what is a platform"
    // cannot mean two things (`boundary.md` §5.3).
    try testing.expectEqual(@as(u8, 2), directory.exit_code);
    try testing.expectEqualStrings(built_directory.stderr, directory.stderr);
    try testing.expect(std.mem.indexOf(u8, directory.stderr, "has no beni.json") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "--platform is refused where it would do nothing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The rule `--source-maps` set (`backend.md` §2): a flag that is
    // accepted while doing nothing makes a user believe they asked for
    // something. `fmt` resolves no import, and neither do the per-file dump
    // stages, so both say so rather than loading a platform nobody can
    // observe.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProgram(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const formatted = try w.runWith(&.{ "fmt", "--platform=node", "--stdout", "Main.beni" }, .{ .raw_diagnostics = true });
    const dumped = try w.runWith(&.{ "dump", "--stage=ast", "--platform=node", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), formatted.exit_code);
    try testing.expectEqualStrings(
        "beni: unknown option '--platform'; run 'beni help' for usage\n",
        formatted.stderr,
    );
    try testing.expectEqual(@as(u8, 2), dumped.exit_code);
    try testing.expectEqualStrings(
        "beni: --platform has no effect on --stage=ast; it applies to interface, raw, types, graph and dispatch\n",
        dumped.stderr,
    );
}

// ---------------------------------------------------------------------------
// Core is checked as far as a program reaches it (checker.md §4.1, amended
// 2026-10-01)
// ---------------------------------------------------------------------------

/// A core of four modules under `--core-root`: `Basics`, which the prelude
/// names and every check keeps; `Outer`, which imports `Broken`; `Broken`,
/// which does not parse; and `Lone`, which nothing imports.
fn writeReachCore(w: *World) !void {
    try w.write("mycore/Basics.beni", "pub foreign type Int\n");
    try w.write("mycore/Outer.beni",
        \\import Broken
        \\
        \\
        \\pub z : Int
        \\z =
        \\    Broken.x
        \\
    );
    try w.write("mycore/Broken.beni", "pub x : Int\nx =\n    (1\n");
    try w.write("mycore/Lone.beni", "pub y : Int\ny =\n    1\n");
}

test "a core module no import reaches is neither read nor checked, and one an import chain reaches is" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Broken` is a syntax error. A program that imports nothing from core
    // never lowers it, so the error is not the program's to hear about; a
    // program that imports `Outer` reaches it two imports deep — the third
    // wave of the front end — and hears it exactly as it always did; and
    // naming the core directory on the command line makes every module of it
    // a root, which is how core itself is checked.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeReachCore(&w);
    try w.write("src/Main.beni", "pub x : Int\nx =\n    1\n");
    try w.write("other/Main.beni", "import Outer\n\n\npub x : Int\nx =\n    Outer.z\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const unreached = try w.run(&.{ "check", "--core-root=mycore", "--frontend-keys", "src" });
    const reached = try w.run(&.{ "check", "--core-root=mycore", "other" });
    const named = try w.run(&.{ "check", "--core-root=mycore", "mycore" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), unreached.exit_code);
    try testing.expectEqualStrings("", unreached.stderr);
    // Only what was lowered has a front-end key: `Basics` and the program.
    try testing.expect(std.mem.indexOf(u8, unreached.stdout, "mycore/Basics.beni ") != null);
    try testing.expect(std.mem.indexOf(u8, unreached.stdout, "src/Main.beni ") != null);
    for ([_][]const u8{ "mycore/Broken.beni", "mycore/Outer.beni", "mycore/Lone.beni" }) |path| {
        if (std.mem.indexOf(u8, unreached.stdout, path) != null) {
            std.debug.print("{s} was lowered:\n{s}", .{ path, unreached.stdout });
            return error.UnreachedModuleLowered;
        }
    }

    for ([_]world.Result{ reached, named }) |r| {
        try testing.expectEqual(@as(u8, 1), r.exit_code);
        try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
        try testing.expectEqualStrings("mycore/Broken.beni", r.diagnostics[0].span.file);
    }
}

test "the core modules a build reaches are the same at every --jobs, and nothing else of core is in its graph" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The embedded core. `Set` imports `Dict`, so this program's front end
    // runs in three waves; `Schema`, `Int32` and `Js` are imported by
    // nothing it reaches and are not modules of the build at all.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Set
        \\
        \\
        \\pub size : Int
        \\size =
        \\    Set.size (Set.fromList [ 1, 2 ])
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const one = try w.run(&.{ "dump", "--stage=graph", "--jobs=1", "Main.beni" });
    const eight = try w.run(&.{ "dump", "--stage=graph", "--jobs=8", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), one.exit_code);
    try testing.expectEqualStrings(one.stdout, eight.stdout);
    for ([_][]const u8{ "app:Main -> core:Set\n", "core:Set -> core:Dict\n", "core:Dict -> core:List\n" }) |edge| {
        if (std.mem.indexOf(u8, one.stdout, edge) == null) {
            std.debug.print("missing {s}--- graph ---\n{s}", .{ edge, one.stdout });
            return error.MissingEdge;
        }
    }
    for ([_][]const u8{ "core:Schema", "core:Int32", "core:Js" }) |module| {
        if (std.mem.indexOf(u8, one.stdout, module) != null) {
            std.debug.print("{s} is in the graph:\n{s}", .{ module, one.stdout });
            return error.UnreachedModuleInGraph;
        }
    }
}
