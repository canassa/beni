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
        \\pub foreign pure say : String → Program
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
        \\pub run : String → Program
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
        \\  value run : String → Program
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
        \\pub greet : String → Program
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
        "beni: --platform has no effect on --stage=ast; it applies to bir, interface, raw, types, graph, dispatch, writes and ownership\n",
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
    // runs in three waves; `Schema`, `Int32` and `Random.Pcg` are imported
    // by nothing it reaches and are not modules of the build at all.
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
    for ([_][]const u8{ "core:Schema", "core:Int32", "core:Random.Pcg" }) |module| {
        if (std.mem.indexOf(u8, one.stdout, module) != null) {
            std.debug.print("{s} is in the graph:\n{s}", .{ module, one.stdout });
            return error.UnreachedModuleInGraph;
        }
    }
}

// ---------------------------------------------------------------------------
// `Js` is exempt from the module graph (boundary.md §4.2 and
// static-dispatch-spike.md §6.8, amended 2026-10-02)
// ---------------------------------------------------------------------------

/// A core of five modules under `--core-root`, shaped like the real one
/// where it bites: `List` names `Basics`'s `Int` and `String` imports
/// `Lower`, so `Basics` writing a list literal and `Lower` writing a string
/// literal would each close a cycle. `Js` is a few of the real one's
/// declarations, naming no core type. `Lower`'s second argument is the body
/// of its `name` declaration.
fn writeJsCore(w: *World, lower_name: []const u8) !void {
    try w.write("jscore/Js.beni",
        \\pub foreign type Value
        \\
        \\
        \\pub foreign pure from : a → Value
        \\
        \\
        \\pub foreign pure to : Value → a
        \\
        \\
        \\pub foreign impure global : name → Value
        \\
        \\
        \\pub foreign impure get : Value, name → Value
        \\
        \\
        \\pub foreign impure call : Value, name, args → Value
        \\
        \\
        \\pub foreign pure object : fields → Value
        \\
    );
    try w.write("jscore/Basics.beni",
        \\import Js
        \\
        \\
        \\pub foreign type Int
        \\
        \\
        \\pub foreign type Float
        \\
        \\
        \\pub floor : Float → Int
        \\floor x = Js.to (Js.call (Js.global "Math") "floor" [ Js.from x ])
        \\
    );
    try w.write("jscore/List.beni",
        \\pub foreign type List a
        \\
        \\
        \\pub foreign pure length : List a → Int
        \\
    );
    try w.write("jscore/String.beni",
        \\import Lower
        \\
        \\
        \\pub foreign type String
        \\
        \\
        \\pub upper : Lower.Text → Lower.Text
        \\upper t = Lower.upper t
        \\
    );
    var lower: std.ArrayList(u8) = .empty;
    defer lower.deinit(testing.allocator);
    try lower.appendSlice(testing.allocator,
        \\import Js
        \\
        \\
        \\pub type alias Text =
        \\    Js.Value
        \\
        \\
        \\pub upper : Text → Text
        \\upper t = Js.call t "toUpperCase" []
        \\
        \\
        \\pub size : Text → Int
        \\size t = Js.to (Js.get t "length")
        \\
        \\
        \\pub name : Text
        \\name =
        \\
    );
    try lower.appendSlice(testing.allocator, lower_name);
    try w.write("jscore/Lower.beni", lower.items);
}

test "a Js call's property names and argument list mint no edge, so a core module below String and List writes one" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Lower` is below `String` and writes `"toUpperCase"` and `"length"`;
    // `Basics` is below `List` and writes `[ Js.from x ]`. Each is a
    // literal the backend writes in place, so neither mints its type's
    // module, and neither module may then depend on it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeJsCore(&w, "    Js.global \"name\"\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--core-root=jscore", "jscore" });
    const graph = try w.run(&.{ "dump", "--stage=graph", "--core-root=jscore", "jscore/String.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings("", checked.stderr);
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqual(@as(u8, 0), graph.exit_code);
    // `Basics` reaches `Js` and nothing else, and `Lower` reaches `String`
    // not at all; `Js` reaches nothing.
    try testing.expectEqualStrings(
        \\core:Basics -> core:Js
        \\core:List -> core:Basics
        \\core:Lower -> core:Basics
        \\core:Lower -> core:Js
        \\core:String -> core:Lower
        \\
    , graph.stdout);
}

test "Js.object's list, pairs and keys mint no edge, so a core module below String writes one" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Lower` is below `String` and writes `Js.object` with two string keys
    // in a list of pairs: syntax the backend writes as an object literal
    // (boundary.md §4.2), so it mints no `String` — which would close the
    // cycle `String → Lower → String` — and no `List`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeJsCore(&w, "    Js.object [ ( \"length\", Js.global \"name\" ), ( \"$plain\", Js.global \"name\" ) ]\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--core-root=jscore", "jscore" });
    const graph = try w.run(&.{ "dump", "--stage=graph", "--core-root=jscore", "jscore/String.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings("", checked.stderr);
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqual(@as(u8, 0), graph.exit_code);
    // The same edges as a module with no object: none to `List` or
    // `String` from `Lower`.
    try testing.expectEqualStrings(
        \\core:Basics -> core:Js
        \\core:List -> core:Basics
        \\core:Lower -> core:Basics
        \\core:Lower -> core:Js
        \\core:String -> core:Lower
        \\
    , graph.stdout);
}

test "a string a Js call hands to Js.from is a String, and its edge is a cycle below String" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The exemption is the literal the backend writes in place, nothing
    // else: `"name"` handed to `Js.from` is a `String` value the program
    // holds, so `Lower` depends on `String`, which imports it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeJsCore(&w, "    Js.from \"name\"\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "--core-root=jscore", "jscore" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // One cycle, `Lower`'s: `Basics`'s list literal is still exempt.
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.import_cycle, r.diagnostics[0].code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "Lower → String → Lower") != null);
}

test "a platform the binary carries is checked as far as the program reaches it, and a directory platform whole" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `node` names `Node` (its program type) and `html`, which it depends
    // on, names `Html` (its markup vocabulary): those are roots of every
    // build against it. `Io` and `Ssr` are modules a program imports or does
    // not, and this one does not (boundary.md §9.1, amended 2026-10-01). A
    // platform read from a directory is someone's code under development:
    // its modules are all roots, so `Unused`, which nothing imports, is
    // still checked.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProgram(&w);
    try writeUserPlatform(&w);
    try w.write("myplat/Unused.beni", "pub unused : Int\nunused =\n    1\n");
    try w.write("mine/Main.beni",
        \\import Prog exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say "hi"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const embedded = try w.run(&.{ "dump", "--stage=graph", "--platform=node", "Main.beni" });
    const directory = try w.run(&.{ "dump", "--stage=graph", "--platform=./myplat", "mine/Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), embedded.exit_code);
    try testing.expect(std.mem.indexOf(u8, embedded.stdout, "app:Main -> platform:Node\n") != null);
    try testing.expect(std.mem.indexOf(u8, embedded.stdout, "platform:Html -> ") != null);
    for ([_][]const u8{ "platform:Io", "platform:Ssr" }) |module| {
        if (std.mem.indexOf(u8, embedded.stdout, module) != null) {
            std.debug.print("{s} is in the graph:\n{s}", .{ module, embedded.stdout });
            return error.UnreachedModuleInGraph;
        }
    }
    try testing.expectEqual(@as(u8, 0), directory.exit_code);
    try testing.expect(std.mem.indexOf(u8, directory.stdout, "platform:Unused -> core:Basics\n") != null);
}

// ---------------------------------------------------------------------------
// The trusted surface of ownership words (ownership-checker.md §24.6)
// ---------------------------------------------------------------------------

const surface_list = "tests/corpus/ownership/trusted-surface.txt";

/// Every declaration with ownership words that the ownership dump of one
/// package prints — a `summary … (words)` line, or a `crossing … (words)`
/// type — must be listed in `trusted-surface.txt` under that package, with
/// a fixture that exists and names it; and every line listed under the
/// package must be one the dump prints. One test per package, so that each
/// uses one dump per platform.
/// `dump --stage=ownership core` in the repository, which two tests read:
/// run once per process, the same command on the same tree, its exit code
/// and stdout kept for the second (#1577).
const core_dump_args = [_][]const u8{ "dump", "--stage=ownership", "core" };
const Dumped = struct { exit_code: u8, stdout: []const u8 };
var core_dump: ?Dumped = null;

fn coreOwnershipDump(w: *World) !Dumped {
    if (core_dump == null) {
        const r = try w.runWith(&core_dump_args, .{ .raw_diagnostics = true, .cwd = .inherit });
        // Kept for the process: no test allocator owns it.
        core_dump = .{ .exit_code = r.exit_code, .stdout = try std.heap.page_allocator.dupe(u8, r.stdout) };
    }
    return core_dump.?;
}

fn expectSurface(package: []const u8, args: []const []const u8) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const core = args.len == core_dump_args.len and for (args, core_dump_args) |a, b| {
        if (!std.mem.eql(u8, a, b)) break false;
    } else true;
    const r: Dumped = if (core) try coreOwnershipDump(&w) else blk: {
        const run = try w.runWith(args, .{ .raw_diagnostics = true, .cwd = .inherit });
        break :blk .{ .exit_code = run.exit_code, .stdout = run.stdout };
    };
    try testing.expectEqual(@as(u8, 0), r.exit_code);

    // What the dump prints: `Module.name` per worded declaration.
    var printed: std.ArrayList([]const u8) = .empty;
    var module: []const u8 = "";
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "module ")) module = line["module ".len..];
        if (!std.mem.endsWith(u8, line, " (words)")) continue;
        const rest = std.mem.trimStart(u8, line, " ");
        const name = if (std.mem.startsWith(u8, rest, "summary "))
            rest["summary ".len..std.mem.indexOfScalar(u8, rest, ':').?]
        else if (std.mem.startsWith(u8, rest, "crossing "))
            rest["crossing ".len .. rest.len - " (words)".len]
        else if (std.mem.startsWith(u8, rest, "entry "))
            rest["entry ".len .. rest.len - " (words)".len]
        else
            continue;
        try printed.append(arena, try std.fmt.allocPrint(arena, "{s}.{s}", .{ module, name }));
    }

    // What the list says of the package.
    const list = try std.Io.Dir.cwd().readFileAlloc(testing.io, surface_list, arena, .limited(1 << 20));
    var listed: std.ArrayList([]const u8) = .empty;
    var rows = std.mem.splitScalar(u8, list, '\n');
    while (rows.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, row, ' ');
        const pkg = fields.next() orelse continue;
        if (!std.mem.eql(u8, pkg, package)) continue;
        const decl = fields.next() orelse return error.SurfaceRowWithoutDeclaration;
        const fixture = fields.next() orelse return error.SurfaceRowWithoutFixture;
        // The flips are `expectFlips`'s.
        _ = fields.next() orelse return error.SurfaceRowWithoutFlips;
        // The name the fixture must mention: the declaration's, or the one
        // a program reaches it through when it is not `pub`.
        const via = fields.next() orelse decl;
        const path = try std.fmt.allocPrint(arena, "tests/corpus/{s}", .{fixture});
        const text = std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1 << 20)) catch {
            std.debug.print("{s}: the fixture {s} that pins {s} is missing\n", .{ surface_list, path, decl });
            return error.SurfaceFixtureMissing;
        };
        if (std.mem.indexOf(u8, text, via) == null) {
            std.debug.print("{s}: the fixture {s} does not name {s}, which it pins\n", .{ surface_list, path, via });
            return error.SurfaceFixtureUnrelated;
        }
        try listed.append(arena, decl);
    }

    var ok = true;
    for (printed.items) |p| {
        for (listed.items) |l| {
            if (std.mem.eql(u8, p, l)) break;
        } else {
            std.debug.print("{s} carries ownership words and {s} does not list it under `{s}`\n", .{ p, surface_list, package });
            ok = false;
        }
    }
    for (listed.items) |l| {
        for (printed.items) |p| {
            if (std.mem.eql(u8, p, l)) break;
        } else {
            std.debug.print("{s} lists {s} under `{s}`, and its ownership dump prints no words for it\n", .{ surface_list, l, package });
            ok = false;
        }
    }
    if (!ok) return error.TrustedSurfaceNotCatalogued;
}

/// Every row of `trusted-surface.txt` pinned by `fixture` has its words
/// flipped the unsafe way, one flip at a time, and the fixture's report must
/// change under each: the golden would fail if the word were wrong that way
/// (ownership-checker.md §24.6). One process per fixture, which runs the
/// pass once as written and once per flip (`--ownership-flips`).
fn expectFlips(fixture: []const u8, flags: []const []const u8) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const list = try std.Io.Dir.cwd().readFileAlloc(testing.io, surface_list, arena, .limited(1 << 20));
    var flips: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var rows = std.mem.splitScalar(u8, list, '\n');
    while (rows.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, row, ' ');
        _ = fields.next() orelse continue;
        const decl = fields.next() orelse continue;
        const fx = fields.next() orelse continue;
        const spec = fields.next() orelse continue;
        if (!std.mem.eql(u8, fx, fixture) or std.mem.eql(u8, spec, "-")) continue;
        var alts = std.mem.splitScalar(u8, spec, '|');
        while (alts.next()) |alt| {
            if (flips.items.len != 0) try flips.append(arena, '|');
            try flips.print(arena, "{s}:{s}", .{ decl, alt });
            count += 1;
        }
    }
    try testing.expect(count != 0);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "dump", "--stage=ownership" });
    try args.appendSlice(arena, flags);
    try args.append(arena, try std.fmt.allocPrint(arena, "--ownership-flips={s}", .{flips.items}));
    try args.append(arena, try std.fmt.allocPrint(arena, "tests/corpus/{s}", .{fixture}));
    const r = try w.runWith(args.items, .{ .raw_diagnostics = true, .cwd = .inherit });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    var ok = true;
    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        seen += 1;
        if (!std.mem.endsWith(u8, line, ": changes")) {
            std.debug.print("{s}: under {s}, tests/corpus/{s} does not notice — its words are pinned one way only\n", .{ surface_list, line, fixture });
            ok = false;
        }
    }
    try testing.expectEqual(count, seen);
    if (!ok) return error.UnsafeFlipUnnoticed;
}

test "ownership words: a flip that meets no word it takes away is not applicable" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // A declaration that does not exist, and a word the declaration does
    // not carry: neither may pass as a flip the fixture did not notice.
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership-flips=Debug.nothing:1:borrowed>unused|Debug.toString:1:escaped>unused", "tests/corpus/ownership/JsPure.beni" }, .{ .raw_diagnostics = true, .cwd = .inherit });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings(
        "flip Debug.nothing:1:borrowed>unused: not applicable\nflip Debug.toString:1:escaped>unused: not applicable\n",
        r.stdout,
    );
}

test "ownership words: flipping core's Js words is noticed" {
    try expectFlips("ownership/core/JsWords.beni", &.{"--core"});
}

test "ownership words: flipping the Words fixture's words is noticed" {
    try expectFlips("ownership/Words.beni", &.{"--platform=node"});
}

test "ownership words: flipping Debug's words is noticed" {
    try expectFlips("ownership/JsPure.beni", &.{});
}

// `ownership/WordsBrowser.beni` pinned `Hosted.keyOf`'s `aliased` until
// 2026-10-26, when the keys became beni over `Js` (#877) and the word is
// inferred; its remaining rows, `Html.Event` and `Html.Pointer`, are
// `crossing`, the unsafe end already, so they have no flip (`-`). The
// `browser` platform's flips are the entry rows, pinned below by
// `HostedEntry` and `EntryInitProgram`; the entry rows of `browser-tea`,
// `browser-inline` and `Page` have no test that runs them (#1118).

test "ownership words: flipping Task's words is noticed" {
    try expectFlips("ownership/TaskWords.beni", &.{ "--platform=browser-tea", "--ownership-everywhere" });
}

// ---------------------------------------------------------------------------
// The bodies the words describe (ownership-checker.md §24.6, the owner's
// guard of 2026-10-12)
// ---------------------------------------------------------------------------

const bodies_list = "tests/corpus/ownership/word-bodies.txt";

/// The text a declaration's words describe, from its source file: for a
/// `.beni` file the signature and definition (from `pub name :` or `name :`
/// to the last indented line of the definition), for a `.js` sibling the
/// export (`export const name = …` or the `const` an `export { x as name }`
/// names, to its closing `;`), for a `.zig` file the lines between
/// `// ownership pin begin: name` and `// ownership pin end: name` (the
/// code generator's own form of a primitive it inlines, which is the code
/// that runs in place of the sibling). Whitespace runs fold to one space, so a
/// reformatting that changes no token does not move it; a comment inside it
/// does, which is on the safe side.
fn bodyOf(arena: std.mem.Allocator, source: []const u8, file: []const u8, name: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    if (std.mem.endsWith(u8, file, ".beni")) {
        const sig_pub = try std.fmt.allocPrint(arena, "pub {s} :", .{name});
        const sig = try std.fmt.allocPrint(arena, "{s} :", .{name});
        const def = try std.fmt.allocPrint(arena, "{s} ", .{name});
        var in = false;
        while (lines.next()) |line| {
            if (!in) {
                // Compiler-only primitives pin their foreign signature here
                // and their actual implementation separately in the generator.
                const foreign_head = if (std.mem.startsWith(u8, line, "pub foreign ")) line["pub foreign ".len..] else if (std.mem.startsWith(u8, line, "foreign ")) line["foreign ".len..] else "";
                const rung = std.mem.indexOfScalar(u8, foreign_head, ' ');
                const foreign_sig = if (rung) |at| foreign_head[at + 1 ..] else "";
                if (std.mem.startsWith(u8, line, sig_pub) or std.mem.startsWith(u8, line, sig) or std.mem.startsWith(u8, foreign_sig, sig)) in = true else continue;
            } else if (line.len != 0 and line[0] != ' ' and !std.mem.startsWith(u8, line, def)) break;
            try out.appendSlice(arena, line);
            try out.append(arena, '\n');
        }
    } else if (std.mem.endsWith(u8, file, ".zig")) {
        // A span of the code generator that a primitive's words describe,
        // because it writes the primitive in place: between two markers.
        const begin = try std.fmt.allocPrint(arena, "// ownership pin begin: {s}", .{name});
        const end = try std.fmt.allocPrint(arena, "// ownership pin end: {s}", .{name});
        var in = false;
        while (lines.next()) |line| {
            const code = std.mem.trimStart(u8, line, " ");
            if (!in) {
                in = std.mem.startsWith(u8, code, begin);
                continue;
            }
            if (std.mem.startsWith(u8, code, end)) break;
            try out.appendSlice(arena, line);
            try out.append(arena, '\n');
        }
    } else {
        // `export { x as name }` names the `const` that holds it.
        var local = name;
        const alias = try std.fmt.allocPrint(arena, " as {s} }}", .{name});
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |line| if (std.mem.indexOf(u8, line, alias)) |at| {
            const open = std.mem.indexOf(u8, line, "{ ") orelse continue;
            local = line[open + 2 .. at];
        };
        const head_export = try std.fmt.allocPrint(arena, "export const {s} =", .{name});
        const head_local = try std.fmt.allocPrint(arena, "const {s} =", .{local});
        var in = false;
        var depth: i32 = 0;
        while (lines.next()) |line| {
            if (!in) {
                if (std.mem.startsWith(u8, line, head_export) or std.mem.startsWith(u8, line, head_local)) in = true else continue;
            }
            try out.appendSlice(arena, line);
            try out.append(arena, '\n');
            // Brackets are counted with no regard for strings, regular
            // expressions or templates: one unbalanced inside a literal runs the
            // scan on, which over-includes — an unrelated edit below may then
            // trip the pin, never miss one.
            for (line) |c| switch (c) {
                '{', '(' => depth += 1,
                '}', ')' => depth -= 1,
                else => {},
            };
            if (depth == 0 and std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " "), ";")) break;
        }
    }
    if (out.items.len == 0) return null;
    var folded: std.ArrayList(u8) = .empty;
    var space = false;
    for (std.mem.trim(u8, out.items, " \n")) |c| {
        if (c == ' ' or c == '\n' or c == '\t') {
            space = true;
            continue;
        }
        if (space and folded.items.len != 0) try folded.append(arena, ' ');
        space = false;
        try folded.append(arena, c);
    }
    return folded.items;
}

test "ownership words: the bodies they describe have not changed" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const list = try std.Io.Dir.cwd().readFileAlloc(testing.io, bodies_list, arena, .limited(1 << 20));
    var pinned: std.ArrayList([]const u8) = .empty;
    var ok = true;
    var rows = std.mem.splitScalar(u8, list, '\n');
    while (rows.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, row, ' ');
        const file = fields.next() orelse return error.BodyRowWithoutFile;
        const decl = fields.next() orelse return error.BodyRowWithoutDeclaration;
        const hash = fields.next() orelse return error.BodyRowWithoutHash;
        try pinned.append(arena, decl);
        const name = decl[(std.mem.lastIndexOfScalar(u8, decl, '.') orelse return error.BodyRowName) + 1 ..];
        const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, file, arena, .limited(1 << 24));
        const body = (try bodyOf(arena, source, file, name)) orelse {
            std.debug.print("{s}: {s} names {s}, which {s} does not declare\n", .{ bodies_list, decl, name, file });
            ok = false;
            continue;
        };
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        const now = try arena.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
        if (!std.mem.eql(u8, now, hash)) {
            std.debug.print(
                "{s} changed in {s}. Its ownership words were justified by reading that code: read it again, re-justify the words in docs/design/ownership-checker.md §24.8, and set its hash in {s} to {s}.\n",
                .{ decl, file, bodies_list, now },
            );
            ok = false;
        }
    }
    // Every declaration with words is pinned, but a `crossing` type, which
    // has no body.
    const surface = try std.Io.Dir.cwd().readFileAlloc(testing.io, surface_list, arena, .limited(1 << 20));
    var srows = std.mem.splitScalar(u8, surface, '\n');
    while (srows.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, row, ' ');
        _ = fields.next() orelse continue;
        const decl = fields.next() orelse continue;
        const short = decl[(std.mem.lastIndexOfScalar(u8, decl, '.') orelse continue) + 1 ..];
        if (short.len != 0 and std.ascii.isUpper(short[0])) continue;
        for (pinned.items) |p| {
            if (std.mem.eql(u8, p, decl)) break;
        } else {
            std.debug.print("{s} carries ownership words and {s} pins no body for it\n", .{ decl, bodies_list });
            ok = false;
        }
    }
    if (!ok) return error.WordedBodyChanged;
}

/// One declaration of a package's BIR dump, as the pin gate reads it.
const DumpDecl = struct {
    module: []const u8,
    name: []const u8,
    value: bool,
    foreign: bool,
    worded: bool = false,
    /// Words in the v2 column.
    v2: bool = false,
    taken_result: bool = false,
    /// Every declaration this one names in its body, in any form (a call,
    /// a lambda, a partial application, an alias), qualified: the `refs`
    /// lines, `top N (name)` of its own module and `import_value M.name`
    /// of another.
    refs: std.ArrayList([]const u8) = .empty,
    /// The body's instructions, `%N` → what follows `= `, the root and
    /// each `let`'s value by local number: what `yields` follows.
    insts: std.StringHashMapUnmanaged([]const u8) = .empty,
    lets: std.StringHashMapUnmanaged([]const u8) = .empty,
    body: []const u8 = "",

    fn key(d: DumpDecl, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}.{s}", .{ d.module, d.name });
    }
};

/// Every declaration of the package the dump `args` lowers, from the BIR
/// dump: its module, its name, whether it is a value, whether its words are
/// recorded (v1's column and the v2 one alike), and what it names.
fn dumpDecls(w: *World, args: []const []const u8, in_repo: bool, out: *std.ArrayList(DumpDecl)) !void {
    const arena = w.arena.allocator();
    const r = if (in_repo) try w.runWith(args, .{ .raw_diagnostics = true, .cwd = .inherit }) else try w.runWith(args, .{ .raw_diagnostics = true });
    if (r.exit_code != 0) {
        std.debug.print("{s} failed: {s}\n", .{ args[args.len - 1], r.stderr });
        return error.DumpFailed;
    }
    var module: []const u8 = "";
    var in_refs = false;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "module ")) {
            module = line["module ".len..];
            continue;
        }
        if (std.mem.startsWith(u8, line, "decl ")) {
            const head = if (std.mem.endsWith(u8, line, " (annotated)")) line[0 .. line.len - " (annotated)".len] else line;
            const colon = std.mem.indexOf(u8, head, ": ").? + 2;
            const header = head[colon..];
            const is_value = std.mem.indexOf(u8, header, "value ") != null;
            try out.append(arena, .{
                .module = module,
                .name = head[(std.mem.lastIndexOfScalar(u8, head, ' ') orelse continue) + 1 ..],
                .value = is_value,
                .foreign = std.mem.indexOf(u8, header, "foreign value ") != null,
            });
            in_refs = false;
            continue;
        }
        if (out.items.len == 0) continue;
        const d = &out.items[out.items.len - 1];
        if (std.mem.startsWith(u8, line, "  own ") or std.mem.startsWith(u8, line, "  own2 ")) {
            // A type's own word (`crossing`, slot `type`) words no value.
            if (d.value) d.worded = true;
            if (d.value and std.mem.startsWith(u8, line, "  own2 ")) d.v2 = true;
            if (std.mem.indexOf(u8, line, "res taken") != null) d.taken_result = true;
            continue;
        }
        if (std.mem.eql(u8, line, "  refs")) {
            in_refs = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "  body ")) {
            d.body = line["  body ".len..];
            continue;
        }
        if (std.mem.startsWith(u8, line, "  %")) {
            const eq = std.mem.indexOf(u8, line, " = ") orelse continue;
            const rhs = line[eq + 3 ..];
            try d.insts.put(arena, line[2..eq], rhs);
            if (std.mem.startsWith(u8, rhs, "let_def local ")) {
                const n = rhs["let_def local ".len..];
                const at = std.mem.lastIndexOf(u8, rhs, "= ") orelse continue;
                try d.lets.put(arena, n[0 .. std.mem.indexOfScalar(u8, n, ' ') orelse n.len], rhs[at + 2 ..]);
            }
            continue;
        }
        if (!in_refs) continue;
        if (!std.mem.startsWith(u8, line, "    ")) {
            in_refs = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "    top ")) {
            const open = std.mem.indexOfScalar(u8, line, '(') orelse continue;
            try d.refs.append(arena, try std.fmt.allocPrint(arena, "{s}.{s}", .{ module, line[open + 1 .. line.len - 1] }));
        } else if (std.mem.startsWith(u8, line, "    import_value ")) {
            try d.refs.append(arena, line["    import_value ".len..]);
        }
    }
}

/// The packages that may write ownership words, found on disk: core and
/// every platform under `platforms/` (shipped) and `tests/platforms/` (the
/// tests'), each with the directory its pins' files lie under. A corpus
/// fixture's own platform (`tests/corpus/**/platform`) is left out on
/// purpose: those are trust-boundary fixtures, words a test hands the
/// checker, not code a program runs.
const Package = struct { dir: []const u8, args: []const []const u8 };

fn wordedPackages(w: *World, out: *std.ArrayList(Package)) !void {
    const arena = w.arena.allocator();
    try out.append(arena, .{ .dir = "core", .args = &.{ "dump", "--stage=bir", "--core", "core" } });
    for ([_][]const u8{ "platforms", "tests/platforms" }) |root| {
        var dir = try std.Io.Dir.cwd().openDir(testing.io, root, .{ .iterate = true });
        defer dir.close(testing.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (entry.kind != .directory) continue;
            const manifest = try std.fs.path.join(arena, &.{ root, entry.name, "beni.json" });
            _ = std.Io.Dir.cwd().statFile(testing.io, manifest, .{}) catch continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names.items) |name| {
            const path = try std.fs.path.join(arena, &.{ root, name });
            const platform = if (std.mem.eql(u8, root, "platforms")) name else path;
            try out.append(arena, .{ .dir = path, .args = try arena.dupe([]const u8, &.{ "dump", "--stage=bir", try std.fmt.allocPrint(arena, "--platform={s}", .{platform}), path }) });
        }
    }
}

/// The pins of `word-bodies.txt`: a qualified declaration name to the
/// files whose rows name it. Two packages may have a module of one name
/// (`Tea` in browser-tea and browser-inline), so a pin counts for a package
/// only when its file lies under that package's directory.
const Pins = struct {
    files: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,

    fn parse(arena: std.mem.Allocator, list: []const u8) !Pins {
        var p: Pins = .{};
        var rows = std.mem.splitScalar(u8, list, '\n');
        while (rows.next()) |row| {
            if (row.len == 0 or row[0] == '#') continue;
            var fields = std.mem.tokenizeScalar(u8, row, ' ');
            const file = fields.next() orelse continue;
            const got = try p.files.getOrPut(arena, fields.next() orelse continue);
            if (!got.found_existing) got.value_ptr.* = .empty;
            try got.value_ptr.append(arena, file);
        }
        return p;
    }

    fn has(p: Pins, dir: []const u8, decl: []const u8) bool {
        const files = p.files.get(decl) orelse return false;
        for (files.items) |f| {
            if (f.len > dir.len and std.mem.startsWith(u8, f, dir) and f[dir.len] == '/') return true;
        }
        return false;
    }
};

test "ownership words: a pin counts for the package its file lies under, not for a module of the same name elsewhere" {
    const arena = testing.allocator;
    var state = std.heap.ArenaAllocator.init(arena);
    defer state.deinit();
    const list = try std.Io.Dir.cwd().readFileAlloc(testing.io, bodies_list, state.allocator(), .limited(1 << 20));
    const pins = try Pins.parse(state.allocator(), list);
    try testing.expect(pins.has("platforms/browser-inline", "Tea.sandbox"));
    try testing.expect(pins.has("platforms/browser-tea", "Tea.sandbox"));
    try testing.expect(pins.has("tests/platforms/entry-shape", "Start.launch"));
    // The same list without browser-inline's and entry-shape's rows: the
    // namesakes' rows in browser-tea and entry do not stand in for them.
    var kept: std.ArrayList(u8) = .empty;
    var rows = std.mem.splitScalar(u8, list, '\n');
    while (rows.next()) |row| {
        if (std.mem.startsWith(u8, row, "platforms/browser-inline/Tea.beni") or std.mem.startsWith(u8, row, "tests/platforms/entry-shape/")) continue;
        try kept.appendSlice(state.allocator(), row);
        try kept.append(state.allocator(), '\n');
    }
    const fewer = try Pins.parse(state.allocator(), kept.items);
    try testing.expect(!fewer.has("platforms/browser-inline", "Tea.sandbox"));
    try testing.expect(!fewer.has("platforms/browser-inline", "Tea.element"));
    try testing.expect(fewer.has("platforms/browser-tea", "Tea.sandbox"));
    try testing.expect(!fewer.has("tests/platforms/entry-shape", "Start.launch"));
    try testing.expect(fewer.has("tests/platforms/entry", "Start.launch"));
    // A directory is a whole path segment: browser's rows are not browser-tea's.
    try testing.expect(!fewer.has("platforms/browser", "Tea.sandbox"));
}

/// Whether instruction `inst` of `d`'s body is the result of calling a
/// taken source: through a call of one (named directly, by an alias `let`,
/// or by a lambda that yields), a `let`'s body, a let-bound local, a
/// lambda's result (a partial application is one) or any branch of a case.
fn yields(arena: std.mem.Allocator, d: DumpDecl, inst: []const u8, sources: *const std.StringHashMapUnmanaged(void), depth: u32) std.mem.Allocator.Error!bool {
    if (depth > 256) return true;
    const rhs = d.insts.get(inst) orelse return false;
    if (std.mem.startsWith(u8, rhs, "call ")) {
        const callee = rhs["call ".len..];
        return isSource(arena, d, callee[0 .. std.mem.indexOfScalar(u8, callee, ' ') orelse callee.len], sources, depth + 1);
    }
    if (std.mem.startsWith(u8, rhs, "method_call ")) {
        const dot = std.mem.indexOf(u8, rhs, " .") orelse return false;
        const name = rhs[dot + 2 ..];
        return methodSource(sources, name[0 .. std.mem.indexOfScalar(u8, name, ' ') orelse name.len]);
    }
    if (std.mem.startsWith(u8, rhs, "let ") or std.mem.startsWith(u8, rhs, "lambda ") or std.mem.startsWith(u8, rhs, "branch ")) {
        const arrow = std.mem.lastIndexOf(u8, rhs, if (std.mem.startsWith(u8, rhs, "let ")) " in " else " -> ") orelse return false;
        return yields(arena, d, rhs[arrow + 4 ..], sources, depth + 1);
    }
    if (std.mem.startsWith(u8, rhs, "case ")) {
        const open = std.mem.indexOfScalar(u8, rhs, '[') orelse return false;
        var it = std.mem.tokenizeAny(u8, rhs[open + 1 .. rhs.len - 1], ", ");
        while (it.next()) |b| if (try yields(arena, d, b, sources, depth + 1)) return true;
        return false;
    }
    if (std.mem.startsWith(u8, rhs, "local ")) {
        const n = rhs["local ".len..];
        const value = d.lets.get(n[0 .. std.mem.indexOfScalar(u8, n, ' ') orelse n.len]) orelse return false;
        return yields(arena, d, value, sources, depth + 1);
    }
    return false;
}

/// Whether the function instruction `inst` names a taken source.
fn isSource(arena: std.mem.Allocator, d: DumpDecl, inst: []const u8, sources: *const std.StringHashMapUnmanaged(void), depth: u32) std.mem.Allocator.Error!bool {
    if (depth > 256) return true;
    const rhs = d.insts.get(inst) orelse return false;
    if (std.mem.startsWith(u8, rhs, "top ")) {
        const open = std.mem.indexOfScalar(u8, rhs, '(') orelse return false;
        return sources.contains(try std.fmt.allocPrint(arena, "{s}.{s}", .{ d.module, rhs[open + 1 .. rhs.len - 1] }));
    }
    for ([_][]const u8{ "import_value ", "qualified " }) |head| if (std.mem.startsWith(u8, rhs, head)) return sources.contains(rhs[head.len..]);
    if (std.mem.startsWith(u8, rhs, "local ")) {
        const n = rhs["local ".len..];
        const value = d.lets.get(n[0 .. std.mem.indexOfScalar(u8, n, ' ') orelse n.len]) orelse return false;
        return isSource(arena, d, value, sources, depth + 1);
    }
    if (std.mem.startsWith(u8, rhs, "lambda ")) {
        const arrow = std.mem.lastIndexOf(u8, rhs, " -> ") orelse return false;
        return yields(arena, d, rhs[arrow + 4 ..], sources, depth + 1);
    }
    return false;
}

/// A method call `.name` (static dispatch) is over-approximated by its
/// name: any source of that name, in any module.
fn methodSource(sources: *const std.StringHashMapUnmanaged(void), name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '.') != null) return false;
    var it = sources.keyIterator();
    while (it.next()) |k| if (std.mem.endsWith(u8, k.*, name) and k.len > name.len and k.*[k.len - name.len - 1] == '.') return true;
    return false;
}

/// What a package's declarations must have pinned, and why, into `need`;
/// `sources` carries the taken sources of the packages before it.
fn pinNeeds(arena: std.mem.Allocator, decls: []const DumpDecl, sources: *std.StringHashMapUnmanaged(void), need: *std.StringArrayHashMapUnmanaged([]const u8)) !void {
    // A declaration by qualified name.
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (decls, 0..) |d, i| try index.put(arena, try d.key(arena), i);
    // The taken sources (§2.13.6's index obligation): a declaration with
    // a `taken` result, and every forwarder, a declaration whose result
    // IS one, in any form (`yields`) — a least fixpoint, across the
    // modules of every package dumped so far. A body that names a
    // source reads its result, or forwards it: both are pinned. A
    // caller of `foldl` names no source (`foldlFrom` reads, `foldl`'s
    // row covers its callers), so it is not.
    for (decls) |d| if (d.taken_result) try sources.put(arena, try d.key(arena), {});
    var grew = true;
    while (grew) {
        grew = false;
        for (decls) |d| {
            const key = try d.key(arena);
            if (sources.contains(key) or d.body.len == 0) continue;
            if (!try yields(arena, d, d.body, sources, 0)) continue;
            try sources.put(arena, key, {});
            grew = true;
        }
    }
    for (decls) |d| {
        const key = try d.key(arena);
        if (d.worded) {
            try need.put(arena, key, "carries ownership words");
            continue;
        }
        var names = sources.contains(key);
        for (d.refs.items) |r| names = names or sources.contains(r);
        var it = d.insts.valueIterator();
        while (it.next()) |rhs| {
            if (!std.mem.startsWith(u8, rhs.*, "method_call ")) continue;
            const dot = std.mem.indexOf(u8, rhs.*, " .") orelse continue;
            const name = rhs.*[dot + 2 ..];
            names = names or methodSource(sources, name[0 .. std.mem.indexOfScalar(u8, name, ' ') orelse name.len]);
        }
        if (names) try need.put(arena, key, if (sources.contains(key)) "forwards a `taken` result" else "reads a `taken` result");
    }
    // A worded beni body of a module with v2 rows (the asserted rows of
    // R-5.10.8: List, Ref, Deferred) is justified with the helpers it
    // runs: every declaration of its module it reaches. A v1 row of such
    // a module is justified the same way. A v1 row of a module with no
    // v2 row keeps v1's rule, its own body (a `Task` row reaches the
    // scheduler), and so do `Task`'s v1 rows now that it has v2 ones
    // (`spawn`, `join`): the v2 rows reach `fork` and the parts of the
    // scheduler a fiber runs, and those are pinned; the v1 rows
    // (`timeout`, `firstOf`, …) keep the rule they had.
    const v1_own_body = [_][]const u8{"Task"};
    var v2_modules: std.StringHashMapUnmanaged(void) = .empty;
    for (decls) |d| if (d.v2) try v2_modules.put(arena, d.module, {});
    var stack: std.ArrayList(usize) = .empty;
    for (decls, 0..) |d, i| {
        if (!d.worded or d.foreign or !v2_modules.contains(d.module)) continue;
        const exempt = for (v1_own_body) |m| {
            if (std.mem.eql(u8, m, d.module)) break true;
        } else false;
        if (d.v2 or !exempt) try stack.append(arena, i);
    }
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    while (stack.pop()) |i| {
        if ((try seen.getOrPut(arena, i)).found_existing) continue;
        const d = decls[i];
        for (d.refs.items) |r| {
            const j = index.get(r) orelse continue;
            const target = decls[j];
            if (!target.value or !std.mem.eql(u8, target.module, d.module)) continue;
            if (!need.contains(r)) try need.put(arena, r, try std.fmt.allocPrint(arena, "is run by the worded {s}", .{try d.key(arena)}));
            if (!target.foreign) try stack.append(arena, j);
        }
    }
}

test "ownership words: every worded declaration, the helpers its body runs and every reader of a taken result have pinned bodies" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const list = try std.Io.Dir.cwd().readFileAlloc(testing.io, bodies_list, arena, .limited(1 << 20));
    const pins = try Pins.parse(arena, list);
    var packages: std.ArrayList(Package) = .empty;
    try wordedPackages(&w, &packages);
    var ok = true;
    var sources: std.StringHashMapUnmanaged(void) = .empty;
    for (packages.items) |package| {
        var decls: std.ArrayList(DumpDecl) = .empty;
        try dumpDecls(&w, package.args, true, &decls);
        var need: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        try pinNeeds(arena, decls.items, &sources, &need);
        for (need.keys(), need.values()) |key, why| {
            if (pins.has(package.dir, key)) continue;
            std.debug.print("{s} {s}, and {s} pins no body for it under {s}/\n", .{ key, why, bodies_list, package.dir });
            ok = false;
        }
    }
    if (!ok) return error.WordedBodyUnpinned;
}

test "ownership words: a taken result is followed through every form that forwards it, and a fold's caller owes no pin" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    try w.copyTreeInto("core", "core", null);
    // Forwarders of `traverseAt` in each form, each with a caller that
    // reads its result twice; a caller across modules; a fold's caller.
    const list = try std.Io.Dir.cwd().readFileAlloc(testing.io, "core/List.beni", arena, .limited(1 << 22));
    try w.write("core/List.beni", try std.mem.concat(arena, u8, &.{
        list,
        \\
        \\
        \\lamTake : List a, Int → a
        \\lamTake = λa i → traverseAt a i
        \\
        \\
        \\letTake : List a, Int → a
        \\letTake a i =
        \\    x = traverseAt a i
        \\    x
        \\
        \\
        \\partTake : List a → a
        \\partTake = traverseAt _ 0
        \\
        \\
        \\aliasTake : List a, Int → a
        \\aliasTake a i =
        \\    t = traverseAt
        \\    t a i
        \\
        \\
        \\pub pubTake : List a, Int → a
        \\pubTake a i =
        \\    if i < 0 then traverseAt a 0 else traverseAt a i
        \\
        \\
        \\useLam : List a → a × a
        \\useLam xs =
        \\    ( lamTake xs 0, lamTake xs 0 )
        \\
        \\
        \\useLet : List a → a × a
        \\useLet xs =
        \\    ( letTake xs 0, letTake xs 0 )
        \\
        \\
        \\usePart : List a → a × a
        \\usePart xs =
        \\    ( partTake xs, partTake xs )
        \\
        \\
        \\useAlias : List a → a × a
        \\useAlias xs =
        \\    ( aliasTake xs 0, aliasTake xs 0 )
        \\
    }));
    const dict = try std.Io.Dir.cwd().readFileAlloc(testing.io, "core/Dict.beni", arena, .limited(1 << 22));
    try w.write("core/Dict.beni", try std.mem.concat(arena, u8, &.{
        dict,
        \\
        \\
        \\useCross : List a → a × a
        \\useCross xs =
        \\    ( List.pubTake xs 0, List.pubTake xs 0 )
        \\
        \\
        \\plainFold : List Int → Int
        \\plainFold xs =
        \\    List.foldl xs (λx acc → acc + x) 0
        \\
    }));
    var decls: std.ArrayList(DumpDecl) = .empty;
    try dumpDecls(&w, &.{ "dump", "--stage=bir", "--core", "core" }, false, &decls);
    var sources: std.StringHashMapUnmanaged(void) = .empty;
    var need: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try pinNeeds(arena, decls.items, &sources, &need);
    for ([_][]const u8{ "List.lamTake", "List.letTake", "List.partTake", "List.aliasTake", "List.pubTake" }) |k| {
        try testing.expectEqualStrings("forwards a `taken` result", need.get(k) orelse return error.ForwarderMissed);
    }
    for ([_][]const u8{ "List.useLam", "List.useLet", "List.usePart", "List.useAlias", "Dict.useCross", "List.foldlFrom" }) |k| {
        try testing.expectEqualStrings("reads a `taken` result", need.get(k) orelse return error.ReaderMissed);
    }
    // `foldlFrom` reads; `foldl`'s row covers its callers.
    try testing.expect(!need.contains("Dict.plainFold"));
    try testing.expect(!need.contains("List.foldl"));
}

fn expectCoreSurface() !void {
    try expectSurface("core", &core_dump_args);
}

test "ownership words: core's are catalogued" {
    try expectCoreSurface();
}

test "ownership words: the browser platform's are catalogued" {
    try expectSurface("browser", &.{ "dump", "--stage=ownership", "--platform=browser-tea", "platforms/browser" });
}

test "ownership words: the html platform's are catalogued" {
    try expectSurface("html", &.{ "dump", "--stage=ownership", "--platform=browser-tea", "platforms/html" });
}

test "ownership words: the node platform's are catalogued" {
    try expectSurface("node", &.{ "dump", "--stage=ownership", "--platform=node", "platforms/node" });
}

fn expectBrowserSurfaces() !void {
    try expectSurface("browser-tea", &.{ "dump", "--stage=ownership", "--platform=browser-tea", "platforms/browser-tea" });
    try expectSurface("browser-inline", &.{ "dump", "--stage=ownership", "--platform=browser-inline", "platforms/browser-inline" });
}

test "ownership words: browser-tea and browser-inline are catalogued" {
    try expectBrowserSurfaces();
}

// ---------------------------------------------------------------------------
// `--ownership-everywhere` (ownership-checker.md §30.7, slice O0): the hidden
// flag that enforces on every platform until enforcement is the language's
// ---------------------------------------------------------------------------

test "ownership everywhere: a node program that writes a top-level list is refused only under the flag" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node
        \\
        \\
        \\xs : List Int
        \\xs = [ 1, 2, 3 ]
        \\
        \\
        \\main : Node.Program
        \\main = Node.printLines [ String.fromInt (bump 9) ]
        \\
        \\
        \\bump : Int → Int
        \\bump n = List.length (List.set xs 0 n)
        \\
    );
    const plain = try w.run(&.{ "check", "--platform=node", "--cache-dir=c", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), plain.exit_code);
    const forced = try w.run(&.{ "check", "--platform=node", "--ownership-everywhere", "--cache-dir=c", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), forced.exit_code);
    try testing.expectEqual(@as(usize, 1), forced.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.top_level_list_changed, forced.diagnostics[0].code);
    // `build` enforces with it too.
    const built = try w.run(&.{ "build", "--platform=node", "--ownership-everywhere", "--no-cache", "--out=out", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), built.exit_code);
    try testing.expectEqual(diagnostic.Code.top_level_list_changed, built.diagnostics[0].code);
}

test "ownership everywhere: its cache entries are kept in a subdirectory of their own" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node
        \\
        \\
        \\main : Node.Program
        \\main = Node.printLines [ "ok" ]
        \\
    );
    // A summary block made under the flag's rows must never meet an
    // ordinary run, so its entries are written below `ownership-everywhere/`
    // and nowhere else.
    const forced = try w.run(&.{ "check", "--platform=node", "--ownership-everywhere", "--cache-dir=c", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), forced.exit_code);
    try testing.expect(w.exists("c/ownership-everywhere/v1"));
    try testing.expect(!w.exists("c/v1"));
    const plain = try w.run(&.{ "check", "--platform=node", "--cache-dir=c", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), plain.exit_code);
    try testing.expect(w.exists("c/v1"));
    // A subdirectory that cannot be made is the cache directory's own
    // usage failure: exit 2, the directory named.
    try w.write("d/ownership-everywhere", "a file\n");
    const blocked = try w.runWith(&.{ "check", "--platform=node", "--ownership-everywhere", "--cache-dir=d", "Main.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 2), blocked.exit_code);
    try testing.expect(std.mem.startsWith(u8, blocked.stderr, "beni: cannot write 'd'"));
}

// §31.4 item 6: a list's line reads no record condition. With every record
// condition failing (the hidden `--ownership-records-lost`), the list lines
// are the same. A construction's guard (`condition(fresh2)` at `.0`, #720)
// once counted as a second choice at its path when its record condition
// failed, which made `t.0` approximate: `call` where it is `alias` (#773).
test "ownership records lost: a guard beside a result path does not move a list line" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\w1 x = ( x, x )
        \\
        \\
        \\pub wide : List Int → Int
        \\wide xs =
        \\    t = w1 xs
        \\    ys = [ …t.0, 1 ]
        \\    List.length ys + List.length xs
        \\
    );
    const plain = try w.runWith(&.{ "dump", "--stage=ownership", "Main.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), plain.exit_code);
    const lost = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership-records-lost", "Main.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), lost.exit_code);
    const line = "  7:12 construction t.0: rejected alias: xs holds it and is read at 8:22\n";
    try testing.expect(std.mem.indexOf(u8, plain.stdout, line) != null);
    try testing.expect(std.mem.indexOf(u8, lost.stdout, line) != null);
}

/// §30.5, §30.7 (O1): under the flag, the modules of core or of a platform
/// hold no rejected and no pending line — `browser-tea`'s `Tea.application`
/// held two before O1, its taggers forwarded inside a lambda (§30.9).
fn expectPlatformClean(argv: []const []const u8) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const r = try w.runWith(argv, .{ .raw_diagnostics = true, .cwd = .inherit });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    var totals: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "total ")) {
        totals = line;
    };
    const line = totals orelse return error.NoTotals;
    if (!std.mem.endsWith(u8, line, "pending 0, rejected 0")) {
        std.debug.print("{s}\n", .{r.stdout});
        return error.PlatformHasOwnershipErrors;
    }
}

fn expectCoreClean() !void {
    try expectPlatformClean(&.{ "dump", "--stage=ownership", "--ownership-totals", "--ownership-everywhere", "core" });
}

test "ownership everywhere: core holds no rejected or pending line" {
    try expectCoreClean();
}

test "ownership everywhere: the node platform holds no rejected or pending line" {
    try expectPlatformClean(&.{ "dump", "--stage=ownership", "--ownership-totals", "--ownership-everywhere", "--platform=node", "platforms/node" });
}

test "ownership everywhere: the html platform holds no rejected or pending line" {
    try expectPlatformClean(&.{ "dump", "--stage=ownership", "--ownership-totals", "--ownership-everywhere", "--platform=html", "platforms/html" });
}

test "ownership everywhere: the browser platform holds no rejected or pending line" {
    try expectPlatformClean(&.{ "dump", "--stage=ownership", "--ownership-totals", "--ownership-everywhere", "--platform=browser", "platforms/browser" });
}

test "ownership everywhere: the browser-inline platform holds no rejected or pending line" {
    try expectPlatformClean(&.{ "dump", "--stage=ownership", "--ownership-totals", "--ownership-everywhere", "--platform=browser-inline", "platforms/browser-inline" });
}

fn expectTeaClean() !void {
    try expectPlatformClean(&.{ "dump", "--stage=ownership", "--ownership-totals", "--ownership-everywhere", "--platform=browser-tea", "platforms/browser-tea" });
}

test "ownership everywhere: the browser-tea platform holds no rejected or pending line" {
    try expectTeaClean();
}

test "ownership entry: Page.sandbox reports its row without the enforcement flag" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // `update` writes its model in place. With no row that is a function
    // stored in a record, pending (§16.5); the direct row owns the model
    // (§20.3), so the write is accepted at the entry.
    try w.write("Main.beni",
        \\import Page
        \\
        \\
        \\update : ⊤, List Int → List Int
        \\update _ xs = List.push xs 1
        \\
        \\
        \\main : Page.Program
        \\main = Page.sandbox { init = λ⊤ → [], update = update, view = λxs → Page.text (String.fromInt (List.length xs)) }
        \\
    );
    const main = try std.fs.path.join(w.arena.allocator(), &.{ try w.projectPath(), "Main.beni" });
    const page = "--platform=tests/platforms/page";
    const checked = try w.runWith(&.{ "check", page, "--ownership-everywhere", "--no-cache", main }, .{ .cwd = .inherit });
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    const report = try w.runWith(&.{ "dump", "--stage=ownership", page, main }, .{ .raw_diagnostics = true, .cwd = .inherit });
    try testing.expect(std.mem.indexOf(u8, report.stdout, "entry Main.update model: accepted entry") != null);
}

test "ownership v2 everywhere: tuple DAG keeps every path without repeated comparisons" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const checked = try w.runWith(&.{ "check", "--ownership=v2", "--ownership-everywhere", "--no-cache", "tests/corpus/check/good/OwnershipAnnotationDag.beni" }, .{ .cwd = .inherit });
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
}

fn expectRendererIndependentEntry(platform: []const u8, path: []const u8) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const ordinary = try w.runWith(&.{ "dump", "--stage=ownership", platform, path }, .{ .cwd = .inherit, .raw_diagnostics = true });
    const universal = try w.runWith(&.{ "dump", "--stage=ownership", platform, "--ownership-everywhere", path }, .{ .cwd = .inherit, .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), ordinary.exit_code);
    try testing.expectEqual(@as(u8, 0), universal.exit_code);
    try testing.expectEqualStrings("", ordinary.stderr);
    try testing.expectEqualStrings("", universal.stderr);
    try testing.expect(std.mem.indexOf(u8, universal.stdout, "accepted entry") != null);
    try testing.expectEqualStrings(universal.stdout, ordinary.stdout);
}

test "ownership entry: renderer mode does not change Tea's row" {
    try expectRendererIndependentEntry("--platform=browser-tea", "tests/corpus/ownership/EntryPush.beni");
}

test "ownership entry: renderer mode does not change Browser's row" {
    // A fresh init is owned; the top-level init remains refused in both modes.
    try expectRendererIndependentEntry("--platform=browser", "tests/corpus/ownership/EntryInitProgram.beni");
}

test "ownership entry: renderer mode does not change hosted rows" {
    try expectRendererIndependentEntry("--platform=browser", "tests/corpus/ownership/HostedEntry.beni");
}

test "ownership entry: hosted update and settle own their state" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const out = try std.fmt.allocPrint(w.arena.allocator(), "--out={s}/out", .{try w.projectPath()});
    const built = try w.runWith(&.{ "build", "--platform=browser", "--ownership-everywhere", "--no-cache", out, "tests/corpus/ownership/HostedEntry.beni" }, .{ .cwd = .inherit });
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqual(@as(usize, 0), built.diagnostics.len);
}

fn expectHostedRefusal(path: []const u8) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const result = try w.runWith(&.{ "check", "--platform=browser", "--ownership-everywhere", "--no-cache", path }, .{ .cwd = .inherit });
    try testing.expectEqual(@as(u8, 1), result.exit_code);
    try testing.expect(result.diagnostics.len != 0);
    for (result.diagnostics) |d| try testing.expectEqual(.list_may_be_shared, d.code);
}

test "ownership entry: update cannot share a duplicate state path" {
    try expectHostedRefusal("tests/corpus/ownership/HostedEntryDuplicateUpdate.beni");
}

test "ownership entry: settle cannot share a duplicate state path" {
    try expectHostedRefusal("tests/corpus/ownership/HostedEntryDuplicateSettle.beni");
}

test "ownership entry: update cannot write a view handler's state" {
    try expectHostedRefusal("tests/corpus/ownership/HostedEntryViewUpdate.beni");
}

test "ownership entry: settle cannot write a view handler's state" {
    try expectHostedRefusal("tests/corpus/ownership/HostedEntryViewSettle.beni");
}

test "ownership entry: update cannot write state retained by Host" {
    try expectHostedRefusal("tests/corpus/ownership/HostedEntryHostUpdate.beni");
}

test "ownership entry: settle cannot write state retained by Host" {
    try expectHostedRefusal("tests/corpus/ownership/HostedEntryHostSettle.beni");
}

test "ownership entry: the hosted word changes the verdict" {
    try expectFlips("ownership/HostedEntry.beni", &.{ "--platform=browser", "--ownership-everywhere" });
}

test "ownership entry: the program word changes the verdict" {
    try expectFlips("ownership/EntryInitProgram.beni", &.{ "--platform=browser", "--ownership-everywhere" });
}

test "ownership entry: Page's word is catalogued" {
    try expectSurface("page", &.{ "dump", "--stage=ownership", "--platform=tests/platforms/page", "tests/platforms/page" });
}

test "ownership entry: an unsupported settle shape leaves its writer pending" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const r = try w.runWith(&.{ "check", "--diagnostics=json", "--no-cache", "--platform=tests/platforms/entry-shape", "--ownership-everywhere", "tests/corpus/ownership/EntryMalformedSettle.beni" }, .{ .cwd = .inherit });
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expect(r.diagnostics.len != 0);
    for (r.diagnostics) |d| try testing.expectEqual(.list_may_be_shared, d.code);
}

test "ownership everywhere: Tea private key tables have no refused writer" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const r = try w.runWith(&.{ "check", "--platform=browser-tea", "--ownership-everywhere", "--no-cache", "platforms/browser-tea/Tea.beni" }, .{ .cwd = .inherit });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "dict keys: cached opaque facts constrain a fresh importer" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Maps.beni", "import Dict\n\npub opaque type Wrapped k = Wrapped (Dict.Dict k Int)\n");
    try w.write("Main.beni", "import Maps\n\ntype alias Value = Maps.Wrapped Int\n\nmain : Int\nmain = 0\n");
    const good = try w.run(&.{ "check", "--cache-dir=c", "Main.beni", "Maps.beni" });
    try testing.expectEqual(@as(u8, 0), good.exit_code);
    try w.write("Main.beni", "import Maps\n\ntype alias Value = Maps.Wrapped Bool\n\nmain : Int\nmain = 0\n");
    const warm = try w.run(&.{ "check", "--cache-dir=c", "Main.beni", "Maps.beni" });
    try testing.expectEqual(@as(u8, 1), warm.exit_code);
    try testing.expect(warm.diagnostics.len != 0);
    for (warm.diagnostics) |d| try testing.expectEqual(.invalid_dict_key, d.code);
    const cold = try w.run(&.{ "check", "--no-cache", "Main.beni", "Maps.beni" });
    try testing.expectEqual(@as(u8, 1), cold.exit_code);
    try testing.expectEqualStrings(warm.stderr, cold.stderr);
}

test "dict keys: a hidden body change invalidates a cached importer" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Maps.beni", "pub opaque type Wrapped k = Wrapped k\n");
    try w.write("Main.beni", "import Maps\n\ntype alias Value = Maps.Wrapped Bool\n\nmain : Int\nmain = 0\n");
    const before = try w.run(&.{ "check", "--cache-dir=c", "Main.beni", "Maps.beni" });
    try testing.expectEqual(@as(u8, 0), before.exit_code);
    try w.write("Maps.beni", "import Dict\n\npub opaque type Wrapped k = Wrapped (Dict.Dict k Int)\n");
    const after = try w.run(&.{ "check", "--cache-dir=c", "Main.beni", "Maps.beni" });
    try testing.expectEqual(@as(u8, 1), after.exit_code);
    try testing.expect(after.diagnostics.len != 0);
    for (after.diagnostics) |d| try testing.expectEqual(.invalid_dict_key, d.code);
}

test "dict keys: late schema facts survive a cached opaque boundary" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Models.beni",
        \\import Dict
        \\import Schema exposing (Conversion)
        \\
        \\conversion : Conversion a a
        \\conversion = Debug.todo "checker-only conversion"
        \\
        \\pub schema Pass item = item via conversion
        \\
        \\pub opaque type Box k = Box (Dict.Dict (Pass.Type k) Int)
        \\
    );
    try w.write("Main.beni", "import Models\n\ntype alias Value = Models.Box String\n\nmain : Int\nmain = 0\n");
    const good = try w.run(&.{ "check", "--cache-dir=c", "Main.beni", "Models.beni" });
    try testing.expectEqual(@as(u8, 0), good.exit_code);
    try w.write("Main.beni", "import Models\n\ntype alias Value = Models.Box Bool\n\nmain : Int\nmain = 0\n");
    const warm = try w.run(&.{ "check", "--cache-dir=c", "Main.beni", "Models.beni" });
    try testing.expectEqual(@as(u8, 1), warm.exit_code);
    try testing.expect(warm.diagnostics.len != 0);
    for (warm.diagnostics) |d| try testing.expectEqual(.invalid_dict_key, d.code);
    const cold = try w.run(&.{ "check", "--no-cache", "Main.beni", "Models.beni" });
    try testing.expectEqual(@as(u8, 1), cold.exit_code);
    try testing.expectEqualStrings(warm.stderr, cold.stderr);
}

test "full-type casts keep distinct nested nonrecursive constructor places" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Js
        \\
        \\pub nested : Js.Value → List Int
        \\nested value =
        \\    decoded : Maybe (Maybe (List Int))
        \\    decoded = Js.to value
        \\    case decoded of
        \\        Just (Just xs) → List.push xs 1
        \\        _ → []
        \\
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--core", "--platform=node", "Main.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "#Just.0#Just.0") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "accepted param") != null);
}

/// Appendix C.2–C.5 of `ownership-v2.md` (§8 S4): the checker v2's walker
/// derives the contracts of core's loops, `mapHelp`, `List.map`,
/// `foldlFrom`, `List.foldl`, `foldrFrom` and `List.foldr`, from their
/// bodies (no ownership words, so no row a test supplies), and this golden
/// pins each `summary` line whole, a label's origin written `@n`. A change is read against Appendix C
/// before the golden is changed: a mismatch is a finding.
const core_loops = "tests/corpus/ownership/core-loops-v2.txt";

test "the checker v2 derives core's loops from their bodies, as Appendix C.2–C.5 says" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v2", "--core", "core/List.beni" }, .{ .raw_diagnostics = true, .cwd = .inherit });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    var got: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "mapHelp", "map", "foldlFrom", "foldl", "foldrFrom", "foldr" }) |name| {
        const head = try std.fmt.allocPrint(arena, "  summary {s}:", .{name});
        var lines = std.mem.splitScalar(u8, r.stdout, '\n');
        const line = while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, head)) break l;
        } else {
            std.debug.print("{s}: no summary line in the dump\n", .{name});
            return error.SummaryMissing;
        };
        // Words would make it an asserted row, not a derived one.
        try testing.expect(!std.mem.endsWith(u8, line, " (words)"));
        // A label's origin is an instruction's number, which any edit of
        // `core/List.beni` above it moves: written `@n`.
        var i: usize = 2;
        while (i < line.len) : (i += 1) {
            try got.append(arena, line[i]);
            if (line[i] != '@' or i + 1 >= line.len or !std.ascii.isDigit(line[i + 1])) continue;
            try got.append(arena, 'n');
            while (i + 1 < line.len and std.ascii.isDigit(line[i + 1])) i += 1;
        }
        try got.append(arena, '\n');
    }
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, core_loops, arena, .limited(1 << 20));
    var want: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| if (l.len != 0 and l[0] != '#') {
        try want.appendSlice(arena, l);
        try want.append(arena, '\n');
    };
    try testing.expectEqualStrings(want.items, got.items);
}

/// Helpers that hand a list's elements to a callback, written into a copy of
/// core only: a supply is read where it is handed on (§2.10 `reads`, §2.11.3
/// *A supply is read*). A direct caller of `mapHelp` or `foldlFrom`, a
/// callback handed `traverseAt`'s element directly, and one handed it through
/// a callee that supplies its argument (#2297).
const supply_probes =
    \\
    \\
    \\pub probeMap : List a, (a → b) → List b
    \\probeMap xs func = mapHelp xs 0 0 (length xs) func (builder (length xs))
    \\
    \\
    \\pub probeFold : List a, b, (a, b → b) → b
    \\probeFold xs acc func = foldlFrom xs 0 (length xs) acc func
    \\
    \\
    \\applyTo : a, (a → b) → b
    \\applyTo x func = func x
    \\
    \\
    \\pub probePass : List a, (a → b) → b
    \\probePass xs func = applyTo (traverseAt xs 0) func
    \\
    \\
    \\pub probeHand : List a, (a → b) → b
    \\probeHand xs func = func (traverseAt xs 0)
    \\
;

test "the checker v2 reads what a helper supplies its callback, so an element written before the call is refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    try w.copyTreeInto("core", "tcore", "_");
    const list = try std.Io.Dir.cwd().readFileAlloc(testing.io, "core/List.beni", arena, .limited(1 << 22));
    try w.write("tcore/List.beni", try std.mem.concat(arena, u8, &.{ list, supply_probes }));
    const dump = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v2", "--core-root=tcore", "--core", "tcore/List.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    for ([_][]const u8{ "probeMap", "probeFold", "probePass", "probeHand" }) |name| {
        const head = try std.fmt.allocPrint(arena, "  summary {s}:", .{name});
        var lines = std.mem.splitScalar(u8, dump.stdout, '\n');
        const line = while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, head)) break l;
        } else return error.SummaryMissing;
        const reads = std.mem.indexOf(u8, line, "; reads ") orelse return error.NoReads;
        const end = std.mem.indexOfPos(u8, line, reads + 1, ";") orelse line.len;
        if (std.mem.indexOf(u8, line[reads..end], " π1[*]*") == null) {
            std.debug.print("{s} does not read π1's elements:\n{s}\n", .{ name, line });
            return error.SupplyNotRead;
        }
    }
    // The issue's program, through the callee that supplies its argument:
    // `List.map` writes `xs`'s elements in place unless `probePass` reads them.
    try w.write("Main.beni",
        \\import List
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    xs = [ [ 1 ], [ 2 ] ]
        \\    a = List.map xs λl → List.push l 9
        \\    b = List.probePass xs λl → List.length l
        \\    Node.print (String.fromInt (List.length a + b))
        \\
    );
    const r = try w.runWith(&.{ "check", "--platform=node", "--core-root=tcore", "--ownership=v2", "--ownership-everywhere", "--no-cache", "Main.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "later-use: xs is read again at 10:9") != null);
}

test "growing full cast types settle on the composed path" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Js
        \\
        \\pub build : Int, a → Js.Value
        \\build n xs =
        \\    if n == 0 then
        \\        Js.from [ xs ]
        \\    else
        \\        build (n - 1) [ xs ]
        \\
        \\pub record : Int, a → Js.Value
        \\record n value =
        \\    if n == 0 then
        \\        Js.from [ value ]
        \\    else
        \\        record (n - 1) { item = value }
        \\
        \\pub cps : Int, a, (Js.Value → Int) → Int
        \\cps n value k =
        \\    if n == 0 then
        \\        k (Js.from [ value ])
        \\    else
        \\        cps (n - 1) { item = value } k
        \\
        \\flatten : a, List (List a) → List a
        \\flatten _ xs = List.concat xs
        \\
        \\pub provenance : Int, a, Js.Value → Js.Value
        \\provenance n x value =
        \\    if n == 0 then
        \\        Js.from (flatten x (Js.to value))
        \\    else
        \\        provenance (n - 1) [ x ] value
        \\
        \\pub thunk : Int, a → (⊤ → Js.Value)
        \\thunk n xs =
        \\    if n == 0 then
        \\        λ⊤ → Js.from [ xs ]
        \\    else
        \\        thunk (n - 1) [ xs ]
        \\
        \\pub localBuilder : List Int → List (List Int) × List Int
        \\localBuilder xs =
        \\    pack : a → Js.Value
        \\    pack v = Js.from [ v ]
        \\    decoded : List (List Int)
        \\    decoded = Js.to (pack xs)
        \\    ( List.push decoded [], xs )
        \\
        \\pub callbackBuilder : List Int → List (List Int) × List Int
        \\callbackBuilder xs =
        \\    pack : a → Js.Value
        \\    pack v = Js.from [ v ]
        \\    encoded = List.map [ xs ] pack
        \\    case encoded of
        \\        [ value ] →
        \\            decoded : List (List Int)
        \\            decoded = Js.to value
        \\            ( List.push decoded [], xs )
        \\        _ → ( [], xs )
        \\
        \\
        \\applySlot : { f : a → Js.Value }, a → Js.Value
        \\applySlot rec value = rec.f value
        \\
        \\pub slotBuilder : List Int → List (List Int) × List Int
        \\slotBuilder xs =
        \\    pack : a → Js.Value
        \\    pack v = Js.from [ v ]
        \\    decoded : List (List Int)
        \\    decoded = Js.to (applySlot { f = pack } xs)
        \\    ( List.push decoded [], xs )
        \\
    );
    const checked = try w.run(&.{ "check", "--core", "--ownership-everywhere", "--platform=node", "--no-cache", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
}

// A `pub` core function that writes a parameter must be one of `List`'s eight
// writers: `Totality` keys its exemption of core's own callers on those names
// (`writes/Core.zig` `listWriter`), so a new wrapper that edits its argument
// would be total, and browser-inline would run it ahead of its branch.
/// The eight, as `writes/Core.zig` `listWriter` names them; a black-box test does not import the compiler.
fn isListWriter(name: []const u8) bool {
    for ([_][]const u8{ "set", "update", "push", "pop", "swap", "insertAt", "removeAt", "append" }) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

test "ownership: only List's eight writers are pub core functions that write a parameter" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const r = try coreOwnershipDump(&w);
    try testing.expectEqual(@as(u8, 0), r.exit_code);

    var found: usize = 0;
    var module: []const u8 = "";
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "module ")) module = line["module ".len..];
        if (!std.mem.startsWith(u8, line, "  summary ")) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line["  summary ".len..colon];
        // The parameters' words, before any `res`: `π1 RAW[storage]`.
        const words = line[colon..];
        var writes = false;
        var toks = std.mem.tokenizeAny(u8, words, " ,;");
        while (toks.next()) |tok| {
            if (std.mem.eql(u8, tok, "res")) break;
            if (!std.mem.startsWith(u8, tok, "π")) continue;
            const word = toks.next() orelse break;
            if (std.mem.indexOfScalar(u8, word, 'W') != null) writes = true;
        }
        if (!writes) continue;

        const path = try std.fmt.allocPrint(arena, "core/{s}.beni", .{try std.mem.replaceOwned(u8, arena, module, ".", "/")});
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1 << 22));
        var is_pub = false;
        var rows = std.mem.splitScalar(u8, text, '\n');
        while (rows.next()) |row| {
            if (!std.mem.startsWith(u8, row, "pub ")) continue;
            var toks2 = std.mem.tokenizeScalar(u8, row, ' ');
            while (toks2.next()) |t| {
                if (std.mem.eql(u8, t, "foreign") or std.mem.eql(u8, t, "pure") or std.mem.eql(u8, t, "impure") or std.mem.eql(u8, t, "suspends") or std.mem.eql(u8, t, "pub")) continue;
                if (std.mem.eql(u8, t, name) and std.mem.eql(u8, toks2.next() orelse "", ":")) is_pub = true;
                break;
            }
        }
        if (!is_pub) continue;
        found += 1;
        if (!std.mem.eql(u8, module, "List") or !isListWriter(name)) {
            std.debug.print("core's pub {s}.{s} writes a parameter and is not one of List's writers (writes/Core.zig `listWriter`)\n", .{ module, name });
            return error.UnlistedCoreWriter;
        }
    }
    try testing.expectEqual(@as(usize, 8), found);
}

test "explicit standalone ownership enforcement checks list sharing" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const path = "tests/corpus/check/good/StandaloneOwnershipFlag.beni";
    const ordinary = try w.runWith(&.{ "check", "--no-cache", path }, .{ .cwd = .inherit });
    try testing.expectEqual(@as(u8, 0), ordinary.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), ordinary.diagnostics);
    const enforced = try w.runWith(&.{ "check", "--no-cache", "--ownership-everywhere", path }, .{ .cwd = .inherit });
    try testing.expectEqual(@as(u8, 1), enforced.exit_code);
    try testing.expectEqualStrings("", enforced.stdout);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
        .code = .list_still_used,
        .severity = .@"error",
        .span = .{ .file = path, .start = .{ .line = 4, .col = 15 }, .end = .{ .line = 4, .col = 33 } },
        .title = "LIST CHANGED WHILE STILL IN USE",
        .message = "`List.push` changes `values` in place, but `values` is read again afterwards.\n\n4|    changed = List.push values 1\n                ^^^^^^^^^^^^^^^^^^ the list is changed in place here\n5|    ( changed, values )\n                 ^^^^^^ and `values` is read here, after the change\n\nIf the list were changed in place, `values` would see the change when it is read\non line 5.\n\nTo change a copy and leave `values` as it was, copy it there:\n\n4|    changed = List.push (List.copy values) 1\n\nThis is sharing the checker can see: `values` is read on line 5, after the\nchange.",
    }}, enforced.diagnostics);
}

const p_sync_list = "tests/corpus/ownership/p-sync.txt";

/// The top-level declaration of `.beni` file text `text` around `at`.
fn declAround(text: []const u8, at: usize) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text[0..at], '\n');
    var name: ?[]const u8 = null;
    while (lines.next()) |l| {
        const s = if (std.mem.startsWith(u8, l, "pub ")) l[4..] else l;
        const end = std.mem.indexOf(u8, s, " :") orelse continue;
        if (end == 0 or !std.ascii.isLower(s[0])) continue;
        for (s[0..end]) |c| {
            if (!std.ascii.isAlphanumeric(c)) break;
        } else name = s[0..end];
    }
    return name;
}

fn pSyncWalk(arena: std.mem.Allocator, dir: []const u8, list: []const u8, ok: *bool) !void {
    var d = try std.Io.Dir.cwd().openDir(testing.io, dir, .{ .iterate = true });
    defer d.close(testing.io);
    var it = d.iterate();
    while (try it.next(testing.io)) |entry| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, entry.name });
        if (entry.kind == .directory and !std.mem.eql(u8, entry.name, "zig")) try pSyncWalk(arena, path, list, ok);
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1 << 24));
        for ([_][]const u8{ "\"addEventListener\"", "\"addListener\"", "\"prependListener\"", "\"on\"", "\"once\"" }) |word| {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, text, at, word)) |hit| : (at = hit + word.len) {
                const decl = declAround(text, hit) orelse continue;
                var rows = std.mem.splitScalar(u8, list, '\n');
                const listed = while (rows.next()) |row| {
                    var fs = std.mem.tokenizeScalar(u8, row, ' ');
                    _ = fs.next() orelse continue;
                    const file = fs.next() orelse continue;
                    const name = fs.next() orelse continue;
                    if (std.mem.eql(u8, file, path) and std.mem.endsWith(u8, name, decl) and name[name.len - decl.len - 1] == '.') break true;
                } else false;
                if (!listed) {
                    std.debug.print("{s}: `{s}` lets the host into beni and {s} does not list it\n", .{ path, decl, p_sync_list });
                    ok.* = false;
                }
            }
        }
    }
}

test "P-sync: every platform's bodies are listed and pinned, and no listener is added outside them" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const list = try std.Io.Dir.cwd().readFileAlloc(testing.io, p_sync_list, arena, .limited(1 << 20));
    const pins = try Pins.parse(arena, try std.Io.Dir.cwd().readFileAlloc(testing.io, bodies_list, arena, .limited(1 << 20)));
    var ok = true;
    var rows = std.mem.splitScalar(u8, list, '\n');
    while (rows.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        var fs = std.mem.tokenizeScalar(u8, row, ' ');
        const platform = fs.next() orelse return error.PSyncRow;
        const file = fs.next() orelse return error.PSyncRow;
        const decl = fs.next() orelse return error.PSyncRow;
        if (std.mem.eql(u8, file, "none")) continue;
        if (!pins.has(try std.fmt.allocPrint(arena, "platforms/{s}", .{platform}), decl)) {
            std.debug.print("{s}: {s} of {s} has no pinned body in {s}\n", .{ p_sync_list, decl, platform, bodies_list });
            ok = false;
        }
    }
    var d = try std.Io.Dir.cwd().openDir(testing.io, "platforms", .{ .iterate = true });
    defer d.close(testing.io);
    var it = d.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != .directory) continue;
        var named = std.mem.splitScalar(u8, list, '\n');
        const found = while (named.next()) |row| {
            if (std.mem.startsWith(u8, row, entry.name) and row.len > entry.name.len and row[entry.name.len] == ' ') break true;
        } else false;
        if (!found) {
            std.debug.print("platform {s} is not in {s}\n", .{ entry.name, p_sync_list });
            ok = false;
        }
        try pSyncWalk(arena, try std.fmt.allocPrint(arena, "platforms/{s}", .{entry.name}), list, &ok);
    }
    try testing.expect(ok);
}

// ---- the step 0 prototype of research report 110 (`--ownership=v3`, research report 111) ----

const own3_cases =
    \\import List
    \\
    \\
    \\type Tree
    \\    = Leaf
    \\    | Node (List Int) Tree Tree
    \\
    \\
    \\pub one : List Int → List Int
    \\one xs = List.push xs 1
    \\
    \\
    \\pub two : List Int → Int
    \\two xs =
    \\    ys = List.push xs 1
    \\    List.length xs + List.length ys
    \\
    \\
    \\pub three : Int → List Int
    \\three n = List.push [ n ] 2
    \\
    \\
    \\pub keys : List Int → List Int
    \\keys xs = List.foldl xs [] λx acc → List.push acc x
    \\
    \\
    \\pub four : List Int → List Int
    \\four xs = [ …xs, 4 ]
    \\
    \\
    \\pub five : List Int, List Int → List Int
    \\five xs ys = xs ++ ys
    \\
    \\
    \\pub six : List Int → List Int × List Int
    \\six xs = ( List.push xs 1, xs )
    \\
    \\
    \\pub grow : Tree → Tree
    \\grow t =
    \\    case t of
    \\        Leaf →
    \\            Leaf
    \\
    \\        Node items l r →
    \\            Node (List.push items 1) (grow l) r
    \\
    \\
    \\pub twice : List Int → List Int
    \\twice xs = five xs xs
    \\
    \\
    \\pub branch : Bool, List Int → List Int
    \\branch c xs = if c then List.push xs 1 else xs
    \\
;

test "ownership v3 (the step 0 prototype): the write rule on one module" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Cases.beni", own3_cases);
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--ownership-totals", "--platform=node", "Cases.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings(
        \\total 13: accepted 10 (fresh 2, call 0, param 7, callback-param 1, once 0, entry 0; assumed 0), pending 0, rejected 3
        \\cause disjoint 1
        \\cause later-use 2
        \\
    , r.stdout);
    const full = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Cases.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), full.exit_code);
    for ([_][]const u8{
        // A parameter that the body writes: the contract asks the caller for it.
        "  10:10 List.push xs: accepted param\n",
        // The old list is read after the write.
        "  15:10 List.push xs: rejected later-use: it is read again at 16:5 (<call List.length>)\n",
        "  20:11 List.push <literal>: accepted fresh\n",
        // A lambda writes the accumulator that `List.foldl` hands it; the first value is the caller's own.
        "  24:11 call List.foldl <literal>: accepted fresh\n",
        "  24:37 List.push acc: accepted callback-param\n",
        "  28:13 construction xs: accepted param\n",
        "  32:17 ++ xs: accepted param\n",
        // The pair answers the old list beside the new one.
        "  36:12 List.push xs: rejected later-use: it is read again at 36:10 (<tuple>)\n",
        // The root's list and the lists of the deeper nodes are two locations.
        "  46:19 List.push items: accepted param\n",
        "  46:39 call Cases.grow l#Node.0: accepted param\n",
        // One list as the written operand and as the other operand.
        "  50:12 call Cases.five xs: rejected disjoint: another operand of the same operation reaches it\n",
        // The other arm of the `if` answers the old list, and does not run with the write.
        "  54:25 List.push xs: accepted param\n",
        "  summary grow: π1#Node.0 W π1#Node.0 W; res [#Node.0 π1@0] [#Node.0 π1@1]\n",
    }) |line| {
        if (std.mem.indexOf(u8, full.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, full.stdout });
            return error.TestExpectedLine;
        }
    }
}

test "ownership v3 (the step 0 prototype): a refusal is an error under enforcement, and the entry hands `update` its model" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Cases.beni", own3_cases);
    const refused = try w.runWith(&.{ "check", "--ownership=v3", "--ownership-everywhere", "--no-cache", "--platform=node", "Cases.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 1), refused.exit_code);
    try testing.expect(std.mem.indexOf(u8, refused.stderr, "List.push xs is refused: later-use") != null);
    try testing.expect(std.mem.indexOf(u8, refused.stderr, "call Cases.five xs is refused: disjoint") != null);
    // Without the hidden flag the same module is v1's to judge.
    try w.write("Main.beni",
        \\import Page
        \\
        \\
        \\update : ⊤, List Int → List Int
        \\update _ xs = List.push xs 1
        \\
        \\
        \\main : Page.Program
        \\main = Page.sandbox { init = λ⊤ → [], update = update, view = λxs → Page.text (String.fromInt (List.length xs)) }
        \\
    );
    const main = try std.fs.path.join(w.arena.allocator(), &.{ try w.projectPath(), "Main.beni" });
    const page = "--platform=tests/platforms/page";
    const checked = try w.runWith(&.{ "check", page, "--ownership=v3", "--ownership-everywhere", "--no-cache", main }, .{ .cwd = .inherit });
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    const report = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", page, main }, .{ .raw_diagnostics = true, .cwd = .inherit });
    try testing.expect(std.mem.indexOf(u8, report.stdout, "entry Main.update model: accepted entry") != null);
}

// The first full run of the sanitiser corpus under the prototype accepted 19
// programs that it must refuse (research report 111 §4.2). Each has a write
// that changes a list in place while another holder reads it: a plain build
// and a sanitised build print different text, or the sanitised run traps.
// The causes: the answer of a function parameter (what it can hold, and where
// it goes), a function that keeps what it is handed, two parts of one handed
// value, a prepend that answers the spread's array, evidence, and an `entry`
// record of an unknown shape.
test "ownership v3 (the step 0 prototype): the sanitiser fixtures that the first full run accepted are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const dir = "tests/corpus/run/";
    // Each fixture: where its first refusal is, the cause, and how many refusals it has.
    const Want = struct { name: []const u8, at: []const u8, cause: []const u8, count: usize };
    const single = [_]Want{
        .{ .name = "SanitiserAnswerLeft", .at = "36:9", .cause = "escaped", .count = 2 },
        .{ .name = "SanitiserCellStaleLength", .at = "27:11", .cause = "supply", .count = 1 },
        .{ .name = "SanitiserCellStoredCapture", .at = "28:22", .cause = "escaped", .count = 4 },
        .{ .name = "SanitiserFoldAlternativesShared", .at = "51:16", .cause = "disjoint", .count = 8 },
        .{ .name = "SanitiserFoldAnswerFedKept", .at = "30:11", .cause = "supply", .count = 3 },
        .{ .name = "SanitiserFoldHandsLabelKeeps", .at = "32:29", .cause = "supply", .count = 1 },
        .{ .name = "SanitiserFoldKeepsAnswer", .at = "28:10", .cause = "supply", .count = 6 },
        .{ .name = "SanitiserLabelRounds", .at = "26:9", .cause = "later-use", .count = 1 },
        .{ .name = "SanitiserLabelRoundsOrder", .at = "22:9", .cause = "later-use", .count = 1 },
        .{ .name = "SanitiserPairCrossEdgeFold", .at = "24:9", .cause = "later-use", .count = 1 },
        .{ .name = "SanitiserPairCrossEdgeFoldr", .at = "24:9", .cause = "later-use", .count = 1 },
        .{ .name = "SanitiserPairCrossEdgeLoop", .at = "47:9", .cause = "later-use", .count = 1 },
        .{ .name = "SanitiserPairCycleFold", .at = "22:9", .cause = "later-use", .count = 1 },
        .{ .name = "SanitiserPairCycleLoop", .at = "28:9", .cause = "later-use", .count = 1 },
        .{ .name = "SanitiserPairCycleParam", .at = "27:9", .cause = "later-use", .count = 1 },
        .{ .name = "SanitiserPrependFrontHeld", .at = "39:22", .cause = "later-use", .count = 3 },
        .{ .name = "SanitiserRecordCallbackShared", .at = "47:9", .cause = "disjoint", .count = 4 },
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "check", "--ownership=v3", "--ownership-everywhere", "--no-cache", "--platform=node" });
    for (single) |want| try argv.append(a, try std.fmt.allocPrint(a, dir ++ "{s}.beni", .{want.name}));
    const r = try w.runWith(argv.items, .{ .raw_diagnostics = true, .cwd = .inherit });
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    for (single) |want| {
        // The header of a refusal names the file and the position; its text has the cause.
        const file = try std.fmt.allocPrint(a, " " ++ dir ++ "{s}.beni:", .{want.name});
        const header = try std.fmt.allocPrint(a, "{s}{s}\n", .{ file, want.at });
        var ok = false;
        if (std.mem.indexOf(u8, r.stderr, header)) |i| {
            if (std.mem.indexOfPos(u8, r.stderr, i, "refused:")) |j| {
                ok = std.mem.startsWith(u8, std.mem.trimStart(u8, r.stderr[j + "refused:".len ..], " \n"), want.cause);
            }
        }
        if (!ok or std.mem.count(u8, r.stderr, file) != want.count) {
            std.debug.print("{s}: wanted {d} refusals, the first at {s} with the cause {s}; in:\n{s}\n", .{ want.name, want.count, want.at, want.cause, r.stderr });
            return error.TestExpectedRefusal;
        }
    }
    // A method that writes its parameter, handed as `where` evidence at a call.
    const ev = dir ++ "SanitiserEvidenceWriter";
    const evidence = try w.runWith(&.{ "check", "--ownership=v3", "--ownership-everywhere", "--no-cache", "--platform=node", "--root=" ++ ev, ev ++ "/Main.beni", ev ++ "/Stack.beni" }, .{ .raw_diagnostics = true, .cwd = .inherit });
    try testing.expectEqual(@as(u8, 1), evidence.exit_code);
    try testing.expect(std.mem.indexOf(u8, evidence.stderr, "handed as evidence") != null);
    // An `entry` record that fails the shape test of the state protocol.
    const en = dir ++ "SanitiserEntryUnsupported";
    const entry = try w.runWith(&.{ "check", "--ownership=v3", "--ownership-everywhere", "--no-cache", "--platform=" ++ en ++ "/platform", "--root=" ++ en, en ++ "/Main.beni" }, .{ .raw_diagnostics = true, .cwd = .inherit });
    try testing.expectEqual(@as(u8, 1), entry.exit_code);
    try testing.expect(std.mem.indexOf(u8, entry.stderr, "goes where") != null);
}

// A function that writes its parameter, captured by a lambda that goes to
// `List.foldl`. The lambda's contract says what it hands the captured
// function, and the fold's contract says what it hands the lambda: the two
// compose (research report 112 §2.4). So the write is a demand on `q` at the
// call of the fold. It is refused while `q` is read later, and accepted when
// it is not. Report 111's prototype made no demand at first (a trap), and
// then refused both.
test "ownership v3: a function that a lambda captured is judged where the lambda goes" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Captured.beni",
        \\import List
        \\
        \\
        \\pub run : List Int → Int
        \\run q =
        \\    h = λa x → List.push a x
        \\    r = List.foldl [ 1, 2 ] q λx acc → h acc x
        \\    List.length q + List.length r
        \\
        \\
        \\pub runDead : List Int → Int
        \\runDead q =
        \\    h = λa x → List.push a x
        \\    r = List.foldl [ 1, 2 ] q λx acc → h acc x
        \\    List.length r
        \\
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Captured.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        "  7:9 call List.foldl q: rejected later-use: it is read again at 8:5 (<call List.length>)\n",
        "  14:9 call List.foldl q: accepted param\n",
        "total 4: accepted 3 (fresh 0, call 0, param 1, callback-param 2, once 0, entry 0; assumed 0), pending 0, rejected 1\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// The faults of round 2 (research report 112 §3). Each function has a write
// that changes a list in place while another holder reads it, and report
// 111's prototype accepted each one. In each, a known function reached a
// consumer by a way on which the walk dropped its code, and nothing judged
// it. The rule of report 112 has one answer: a function value leaves the
// known state only through `flow`, and a consumer that no contract describes
// is the `top` use.
//
// - `nest`: a nested fold whose callback is a composition (129 programs of
//   `bench/ownership-sweeps/folds-callbacks.mjs`). `cb` is captured by the
//   outer lambda and goes to `comp`, whose contract had no fact for it.
// - `twice`: a closure handed back without a run, then run two times (24
//   programs of `handed-back.mjs`). The closure hands a captured list to a
//   captured function that writes.
// - `joinArg`, `joinCallee`: a function in an arm of a `case`, at a function
//   parameter and as a callee.
// - `later`: a local function that an earlier local function calls.
// - `selfPass`: a local function that hands itself to `List.map`.
// - `capEsc`, `capEsc2`: a closure that puts a captured list into a cell,
//   handed to `List.map` as it is, and answered by a function first.
// - `ansTwice`: one answer of a function parameter at two elements of a list.
//
// The last seven are not in a sweep: the rule predicted them.
test "ownership v3: the faults of round 2 are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Round2.beni",
        \\import List
        \\import Ref exposing (Ref)
        \\
        \\
        \\type Tree
        \\    = Node (List Int) (List Tree)
        \\
        \\
        \\comp : (x, a → b), (x, b → c) → (x, a → c)
        \\comp f g =
        \\    λx a → g x (f x a)
        \\
        \\
        \\pub nest : List Int → Int
        \\nest s =
        \\    cb = λx a → List.push a x
        \\    res =
        \\        List.foldl [ 1, 2 ] s λy a0 →
        \\            List.foldl [ y ] a0 (comp cb λ_ v → v)
        \\    List.length res + List.length s
        \\
        \\
        \\back : (⊤ → List Int) → Maybe (⊤ → List Int)
        \\back f =
        \\    Just f
        \\
        \\
        \\pub twice : Int → Int
        \\twice n =
        \\    k = [ n ]
        \\    p = λl → List.push l 1
        \\    case back (λ⊤ → p k) of
        \\        Just g →
        \\            _ = g ⊤
        \\            List.length (g ⊤)
        \\
        \\        Nothing →
        \\            0
        \\
        \\
        \\pub joinArg : Int → Int
        \\joinArg c =
        \\    xs = [ [ 1 ], [ 2 ] ]
        \\    ys =
        \\        List.map xs
        \\            (case c of
        \\                0 →
        \\                    λl → List.push l 1
        \\
        \\                _ →
        \\                    λl → l
        \\            )
        \\    List.length ys + List.length xs
        \\
        \\
        \\pub joinCallee : Int → Int
        \\joinCallee c =
        \\    q = [ c ]
        \\    r =
        \\        (case c of
        \\            0 →
        \\                λl → List.push l 1
        \\
        \\            _ →
        \\                λl → l
        \\        )
        \\            q
        \\    List.length r + List.length q
        \\
        \\
        \\pub later : Int → Int
        \\later c =
        \\    q = [ c ]
        \\    a n acc = if n == 0 then acc else b (n - 1) acc
        \\    b n acc = a n (List.push acc n)
        \\    r = a 2 q
        \\    List.length r + List.length q
        \\
        \\
        \\sum : Tree → Int
        \\sum t =
        \\    case t of
        \\        Node items kids →
        \\            List.length items + List.foldl kids 0 λk n → n + sum k
        \\
        \\
        \\pub selfPass : Int → Int
        \\selfPass c =
        \\    kid = Node [ 1 ] []
        \\    t = Node [ c ] [ kid ]
        \\    walk u =
        \\        case u of
        \\            Node items kids →
        \\                Node (List.push items 9) (List.map kids walk)
        \\    r = walk t
        \\    sum r + sum kid
        \\
        \\
        \\pub capEsc : Int → Int
        \\capEsc c =
        \\    k = [ c ]
        \\    r = Ref.make []
        \\    _ =
        \\        List.map [ 1 ] λx →
        \\            Ref.set r k
        \\            x
        \\    k2 = List.push k 9
        \\    List.length k2 + List.length (Ref.get r)
        \\
        \\
        \\keepIn : Ref (List Int), List Int → (Int → Int)
        \\keepIn r k =
        \\    λx →
        \\        Ref.set r k
        \\        x
        \\
        \\
        \\pub capEsc2 : Int → Int
        \\capEsc2 c =
        \\    k = [ c ]
        \\    r = Ref.make []
        \\    _ = List.map [ 1 ] (keepIn r k)
        \\    k2 = List.push k 9
        \\    List.length k2 + List.length (Ref.get r)
        \\
        \\
        \\dupTwice : (List Int → List Int), List Int → List (List Int)
        \\dupTwice f xs =
        \\    r = f xs
        \\    [ r, r ]
        \\
        \\
        \\pub ansTwice : Int → Int
        \\ansTwice c =
        \\    v = dupTwice (λl → List.push l 1) [ c ]
        \\    w = List.update v 0 λm → List.push m 9
        \\    List.length w
        \\
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Round2.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        // `nest`: `comp` runs its first function with a value that has no claim.
        "  18:9 value <call List.foldl>: rejected supply: the callee hands the function a value that it does not own\n",
        // `twice`: `back` loses the closure, so each function that it captured is in the default.
        "  32:10 value <call Round2.back>: rejected supply: the function writes a parameter that the callee reads again or does not hand as its own\n",
        // `joinArg`: each arm flows to the parameter of `List.map`, so the write is a demand on `xs`.
        "  45:9 call List.map xs[*]: rejected later-use: it is read again at 53:22 (<call List.length>)\n",
        "  60:9 value <call>: rejected call: a function that writes its parameter goes where the checker does not follow it\n",
        // `later`: `b` was called before it was bound. `a` and `b` call each
        // other, so they are walked as one group: `a` hands `q` to `b`, which
        // writes it, and `q` is read again.
        "  76:9 call a q: rejected later-use: it is read again at 77:21 (<call List.length>)\n",
        // `selfPass`: the lists of the deeper nodes are a demand on `t` too.
        "  95:9 call walk t⟨List⟩: rejected later-use: it is read again at 96:13 (<call Round2.sum>)\n",
        "  107:10 List.push k: rejected escaped: it escaped before the write\n",
        // `capEsc2`: the function that answers the closure lets its parameter escape.
        "  123:10 List.push k: rejected escaped: it escaped before the write\n",
        // `ansTwice`: the two elements are one answer of `f`.
        "  136:9 call List.update v[*]: rejected element: one cell can be at two positions of it\n",
        // Report 111's prototype accepted each of the 14 demands that it made here.
        // The two more are the writes of `later`'s group in its own frames.
        "total 26: accepted 16 (fresh 2, call 1, param 0, callback-param 13, once 0, entry 0; assumed 0), pending 0, rejected 10\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// The faults of a blind test of the prototype (research report 113 §4, §6).
// Code can name a binding of its `let` that is written below it: a later
// local function (a local function is hoisted), or a value that the code
// reads only when it runs. Where the closure was made, that binding had no
// value, and the prototype gave it the value with no claim, which holds no
// cell. So a later run of the closure read a list that nothing counted as
// read, and an edit of that list in place was accepted. Each program below
// traps under `--sanitize-lists` with that prototype.
//
// - `call`: `h` calls `g`, which is bound after it and reads `xs`.
// - `mutual`: `h` and `g` call each other.
// - `argument`: one list at two places of one call, `bumpThen xs h`.
// - `push`: as `call`, with `List.push` and a read of the length.
// - `laterValue`: a local function reads a value that is bound below it.
// - `lambda`: a lambda bound to a local names a later local function.
// - `answer`: a value binding calls a later local function, which answers
//   the list that it captured.
// - `chain`: `h` calls `g`, which calls `k`; both are bound after `h`.
// - `held`, `answered`: a closure goes into a list before the function that
//   it names is bound, in the frame itself and in a local function that
//   answers the list.
//
// Each `…Dead` function is the safe twin: nothing reads the list after the
// edit, and it stays accepted.
test "ownership v3: code that names a later binding holds what it reads" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Early.beni",
        \\import List
        \\import String
        \\
        \\
        \\ints : List Int → String
        \\ints xs = String.join (List.map xs String.fromInt) ","
        \\
        \\
        \\pub call : Int → String
        \\call c =
        \\    xs = [ c, 2, 3 ]
        \\    h n = g n
        \\    g n = ints xs
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${h 1}"
        \\
        \\
        \\pub callDead : Int → String
        \\callDead c =
        \\    xs = [ c, 2, 3 ]
        \\    h n = g n
        \\    g n = ints xs
        \\    ys = List.set xs 0 9
        \\    ints ys
        \\
        \\
        \\pub mutual : Int → String
        \\mutual c =
        \\    xs = [ c, 2, 3 ]
        \\    h n = if n == 0 then "" else g (n - 1)
        \\    g n = if n == 0 then ints xs else h n
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${h 1}"
        \\
        \\
        \\pub mutualDead : Int → String
        \\mutualDead c =
        \\    xs = [ c, 2, 3 ]
        \\    h n = if n == 0 then "" else g (n - 1)
        \\    g n = if n == 0 then ints xs else h n
        \\    s = h 1
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${s}"
        \\
        \\
        \\bumpThen : List Int, (Int → String) → String
        \\bumpThen l k =
        \\    l2 = List.set l 0 9
        \\    "${ints l2} ${k 1}"
        \\
        \\
        \\pub argument : Int → String
        \\argument c =
        \\    xs = [ c, 2, 3 ]
        \\    h n = g n
        \\    g n = ints xs
        \\    bumpThen xs h
        \\
        \\
        \\pub argumentDead : Int → String
        \\argumentDead c =
        \\    xs = [ c, 2, 3 ]
        \\    h n = g n
        \\    g n = ints xs
        \\    bumpThen [ c, 2, 3 ] h
        \\
        \\
        \\pub push : Int → String
        \\push c =
        \\    xs = [ c, 2, 3 ]
        \\    h n = g n
        \\    g n = List.length xs + n
        \\    ys = List.push xs 9
        \\    "${ints ys} ${String.fromInt (h 1)}"
        \\
        \\
        \\pub pushDead : Int → String
        \\pushDead c =
        \\    xs = [ c, 2, 3 ]
        \\    h n = g n
        \\    g n = List.length xs + n
        \\    s = h 1
        \\    ys = List.push xs 9
        \\    "${ints ys} ${String.fromInt s}"
        \\
        \\
        \\pub laterValue : Int → String
        \\laterValue c =
        \\    g n = ints zs
        \\    zs = [ c, 2, 3 ]
        \\    ys = List.set zs 0 9
        \\    "${ints ys} ${g 1}"
        \\
        \\
        \\pub laterValueDead : Int → String
        \\laterValueDead c =
        \\    g n = ints zs
        \\    zs = [ c, 2, 3 ]
        \\    s = g 1
        \\    ys = List.set zs 0 9
        \\    "${ints ys} ${s}"
        \\
        \\
        \\pub lambda : Int → String
        \\lambda c =
        \\    xs = [ c, 2, 3 ]
        \\    h = λn → g n
        \\    g n = ints xs
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${h 1}"
        \\
        \\
        \\pub lambdaDead : Int → String
        \\lambdaDead c =
        \\    xs = [ c, 2, 3 ]
        \\    h = λn → g n
        \\    g n = ints xs
        \\    s = h 1
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${s}"
        \\
        \\
        \\pub answer : Int → String
        \\answer c =
        \\    xs = [ c, 2, 3 ]
        \\    a = g 1
        \\    g n = xs
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${ints a}"
        \\
        \\
        \\pub answerDead : Int → String
        \\answerDead c =
        \\    xs = [ c, 2, 3 ]
        \\    a = g 1
        \\    g n = xs
        \\    s = ints a
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${s}"
        \\
        \\
        \\pub chain : Int → String
        \\chain c =
        \\    xs = [ c, 2, 3 ]
        \\    h n = g n
        \\    g n = k n
        \\    k n = ints xs
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${h 1}"
        \\
        \\
        \\pub chainDead : Int → String
        \\chainDead c =
        \\    xs = [ c, 2, 3 ]
        \\    h n = g n
        \\    g n = k n
        \\    k n = ints xs
        \\    s = h 1
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${s}"
        \\
        \\
        \\first : List (Int → String) → String
        \\first fs =
        \\    case fs of
        \\        [ q, …_ ] →
        \\            q 1
        \\
        \\        _ →
        \\            ""
        \\
        \\
        \\pub held : Int → String
        \\held c =
        \\    xs = [ c, 2, 3 ]
        \\    h n = g n
        \\    fs = [ h ]
        \\    g n = ints xs
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${first fs}"
        \\
        \\
        \\pub answered : Int → String
        \\answered c =
        \\    xs = [ c, 2, 3 ]
        \\    mk u =
        \\        h n = g n
        \\        fs = [ h ]
        \\        g n = ints xs
        \\        fs
        \\    fs2 = mk 0
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${first fs2}"
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Early.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        // `call` and its twin: `h 1` runs `g`, which reads `xs`.
        "  14:10 List.set xs: rejected later-use: it is read again at 15:19 (<call>)\n",
        "  23:10 List.set xs: accepted fresh\n",
        // `mutual`.
        "  32:10 List.set xs: rejected later-use: it is read again at 33:19 (<call>)\n",
        "  42:10 List.set xs: accepted fresh\n",
        // `argument`: `h` holds `xs` through `g`, so the two operands are one list.
        "  48:10 List.set l: accepted param\n",
        "  57:5 call Early.bumpThen xs: rejected disjoint: another operand of the same operation reaches it\n",
        "  65:5 call Early.bumpThen <literal>: accepted fresh\n",
        // `push`.
        "  73:10 List.push xs: rejected later-use: it is read again at 74:35 (<call>)\n",
        "  83:10 List.push xs: accepted fresh\n",
        // `laterValue`: `g` holds `zs` from where `zs` is bound.
        "  91:10 List.set zs: rejected later-use: it is read again at 92:19 (<call>)\n",
        "  100:10 List.set zs: accepted fresh\n",
        // `lambda`.
        "  109:10 List.set xs: rejected later-use: it is read again at 110:19 (<call>)\n",
        "  119:10 List.set xs: accepted fresh\n",
        // `answer`: `g` is made where `a` names it, and its answer is `xs`.
        "  128:10 List.set xs: rejected later-use: it is read again at 129:19 (<call Early.ints>)\n",
        "  138:10 List.set xs: accepted fresh\n",
        // `chain`.
        "  148:10 List.set xs: rejected later-use: it is read again at 149:19 (<call>)\n",
        "  159:10 List.set xs: accepted fresh\n",
        // `held`, `answered`: the list of closures holds `xs`. Their twins with the
        // functions in written order are refused too: the list loses its closure.
        "  179:10 List.set xs: rejected later-use: it is read again at 180:19 (<call Early.first>)\n",
        "  192:10 List.set xs: rejected later-use: it is read again at 193:19 (<call Early.first>)\n",
        "total 19: accepted 9 (fresh 8, call 0, param 1, callback-param 0, once 0, entry 0; assumed 0), pending 0, rejected 10\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// The first fault of a second blind test of the prototype (research report
// 114 §4.1, §7). In `x ▷ e` lowering numbers the instructions of `x` before
// those of `e`, but JavaScript evaluates `e` first when it is not a name:
// a field of a call, an `if`, a `case`, an item of a tuple, the receiver
// of a method. The write rule compared instruction numbers, so a read in
// `x` looked earlier than a write in `e`, and the write was accepted. Now
// the times of the walk order the reads and the writes, and the walk goes
// in the order of the emitted JavaScript.
//
// - `field`, `ifCallee`, `caseCallee`, `tupleCallee`, `receiver`: the
//   callee or the receiver writes `q`, and the operand reads it after.
//   Each `…Dead` twin reads another list, and is accepted.
// - `fieldBefore`, `receiverBefore`: the callee or the receiver reads `q`,
//   and the operand writes it after. Safe, and accepted.
// - `rows`: a `For` reads its list where the page renders, after each
//   hole, so a hole that writes the list runs first. `rowsDead` is the twin,
//   whose `For` reads a literal; it is refused too, since a lowering may
//   evaluate the hole itself where it renders, from the lists the hole reads
//   (`dom`'s inputs, #2505): the markup holds `q`, and the render reads it
//   after the push (research report 120).
test "ownership v3: the walk reads and writes in the order of the program" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Order.beni",
        \\import Html exposing (Html)
        \\import List
        \\import Maybe
        \\import Ssr
        \\import String
        \\
        \\
        \\show : List Int → String
        \\show l = String.join (List.map l String.fromInt) ","
        \\
        \\
        \\mk : List Int → { f : String → String }
        \\mk w = { f = λs → s ++ "/" ++ show w }
        \\
        \\
        \\mkf : List Int → (String → String)
        \\mkf w = λs → s ++ "/" ++ show w
        \\
        \\
        \\mkT : List Int → (String → String) × Int
        \\mkT w = ( λs → s ++ "/" ++ show w, 1 )
        \\
        \\
        \\pub field : Int → String
        \\field n =
        \\    q = [ n, 2 ]
        \\    show q ▷ (mk (List.push q 9)).f
        \\
        \\
        \\pub fieldDead : Int → String
        \\fieldDead n =
        \\    q = [ n, 2 ]
        \\    show [ 4 ] ▷ (mk (List.push q 9)).f
        \\
        \\
        \\pub fieldBefore : Int → String
        \\fieldBefore n =
        \\    q = [ n, 2 ]
        \\    show (List.push q 9) ▷ (mk2 (show q)).f
        \\
        \\
        \\mk2 : String → { f : String → String }
        \\mk2 s = { f = λt → s ++ "/" ++ t }
        \\
        \\
        \\pub ifCallee : Int → String
        \\ifCallee n =
        \\    q = [ n, 2 ]
        \\    show q ▷ (if n == 0 then mkf (List.push q 9) else mkf [])
        \\
        \\
        \\pub ifCalleeDead : Int → String
        \\ifCalleeDead n =
        \\    q = [ n, 2 ]
        \\    show [ 4 ] ▷ (if n == 0 then mkf (List.push q 9) else mkf [])
        \\
        \\
        \\pub caseCallee : Int → String
        \\caseCallee n =
        \\    q = [ n, 2 ]
        \\    show q
        \\        ▷ (case n of
        \\            0 →
        \\                mkf (List.push q 9)
        \\
        \\            _ →
        \\                mkf []
        \\          )
        \\
        \\
        \\pub caseCalleeDead : Int → String
        \\caseCalleeDead n =
        \\    q = [ n, 2 ]
        \\    show [ 4 ]
        \\        ▷ (case n of
        \\            0 →
        \\                mkf (List.push q 9)
        \\
        \\            _ →
        \\                mkf []
        \\          )
        \\
        \\
        \\pub tupleCallee : Int → String
        \\tupleCallee n =
        \\    q = [ n, 2 ]
        \\    show q ▷ (mkT (List.push q 9)).0
        \\
        \\
        \\pub tupleCalleeDead : Int → String
        \\tupleCalleeDead n =
        \\    q = [ n, 2 ]
        \\    show [ 4 ] ▷ (mkT (List.push q 9)).0
        \\
        \\
        \\pub receiver : Int → String
        \\receiver n =
        \\    q = [ n, 2 ]
        \\    show ([ List.length q ] ▷ (List.push q 9).append)
        \\
        \\
        \\pub receiverDead : Int → String
        \\receiverDead n =
        \\    q = [ n, 2 ]
        \\    show ([ List.length [ 4 ] ] ▷ (List.push q 9).append)
        \\
        \\
        \\pub receiverBefore : Int → String
        \\receiverBefore n =
        \\    q = [ n, 2 ]
        \\    show (List.push q 9 ▷ [ List.length q ].append)
        \\
        \\
        \\pub rows : Int → String
        \\rows n =
        \\    q = [ n, 2 ]
        \\    Ssr.render (<div><ul><For each={q}>{λi → <li>{String.fromInt i}</li>}</For></ul>{show (List.push q 9)}</div>)
        \\
        \\
        \\pub rowsDead : Int → String
        \\rowsDead n =
        \\    q = [ n, 2 ]
        \\    Ssr.render (<div><ul><For each={[ 4 ]}>{λi → <li>{String.fromInt i}</li>}</For></ul>{show (List.push q 9)}</div>)
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Order.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        "  27:19 List.push q: rejected later-use: it is read again at 27:5 (<call Order.show>)\n",
        "  33:23 List.push q: accepted fresh\n",
        "  39:11 List.push q: accepted fresh\n",
        "  49:35 List.push q: rejected later-use: it is read again at 49:5 (<call Order.show>)\n",
        "  55:39 List.push q: accepted fresh\n",
        "  64:22 List.push q: rejected later-use: it is read again at 61:5 (<call Order.show>)\n",
        "  77:22 List.push q: accepted fresh\n",
        "  87:20 List.push q: rejected later-use: it is read again at 87:5 (<call Order.show>)\n",
        "  93:24 List.push q: accepted fresh\n",
        "  99:32 List.push q: rejected later-use: it is read again at 99:13 (<call List.length>)\n",
        "  99:46 List.append <call List.push>: accepted call\n",
        "  105:36 List.push q: accepted fresh\n",
        "  105:50 List.append <call List.push>: accepted call\n",
        "  111:11 List.push q: accepted fresh\n",
        "  111:44 List.append <literal>: accepted fresh\n",
        "  117:92 List.push q: rejected later-use: it is read again at 117:17 (<expression>)\n",
        "  123:96 List.push q: rejected later-use: it is read again at 123:5 (<call Ssr.render>)\n",
        "total 17: accepted 10 (fresh 8, call 2, param 0, callback-param 0, once 0, entry 0; assumed 0), pending 0, rejected 7\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// The second fault of report 114 (§4.2, §7). The deep level of a recursive
// type is one summary location. One argument of a constructor can put a
// list at two places of it: its own entry level and its own deep level both
// fold into the deep level of the constructor's value. The test for one
// cell at two places ran only between two arguments, so `f` was called
// with `q` twice in that location, wrote one place and read the other.
//
// - `direct`: the value is built at the call.
// - `built`: a callee builds it. `repeated`: a recursive callee puts its
//   parameter in each node.
// - `wrapped`: a callee puts the value one level down.
// - `tree`: the same through a list of children.
//
// Each `…Apart` twin has two lists, and is accepted. A twin with one list
// at two places that writes one and does not read the other is refused:
// the callee's contract does not say which cells of the location it reads.
test "ownership v3: one list twice in a deep level makes the location shared" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Deep.beni",
        \\import List
        \\import String
        \\
        \\
        \\type Lst
        \\    = Cons (List Int) Lst
        \\    | Nil
        \\
        \\
        \\type Tree
        \\    = Tree (List Int) (List Tree)
        \\
        \\
        \\show : List Int → String
        \\show l = String.join (List.map l String.fromInt) ","
        \\
        \\
        \\f : Lst → String
        \\f t =
        \\    case t of
        \\        Cons _ (Cons a (Cons b _)) →
        \\            w = List.set a 0 9
        \\            show w ++ "/" ++ show b
        \\
        \\        _ →
        \\            "-"
        \\
        \\
        \\pub direct : Int → String
        \\direct n =
        \\    q = [ n, 2 ]
        \\    f (Cons [ 0 ] (Cons q (Cons q Nil)))
        \\
        \\
        \\pub directApart : Int → String
        \\directApart n =
        \\    q = [ n, 2 ]
        \\    f (Cons [ 0 ] (Cons q (Cons [ 5 ] Nil)))
        \\
        \\
        \\lit : List Int → Lst
        \\lit q = Cons [ 0 ] (Cons q (Cons q Nil))
        \\
        \\
        \\pub built : Int → String
        \\built n = f (lit [ n, 2 ])
        \\
        \\
        \\rep : Int, List Int → Lst
        \\rep k x = if k == 0 then Nil else Cons x (rep (k - 1) x)
        \\
        \\
        \\pub repeated : Int → String
        \\repeated n = f (rep 3 [ n, 2 ])
        \\
        \\
        \\wrap : Lst → Lst
        \\wrap t = Cons [ 0 ] t
        \\
        \\
        \\pub wrapped : Int → String
        \\wrapped n =
        \\    q = [ n, 2 ]
        \\    f (wrap (Cons q (Cons q Nil)))
        \\
        \\
        \\pub wrappedApart : Int → String
        \\wrappedApart n =
        \\    q = [ n, 2 ]
        \\    f (wrap (Cons q (Cons [ 5 ] Nil)))
        \\
        \\
        \\g : Tree → String
        \\g t =
        \\    case t of
        \\        Tree _ [ Tree a [ Tree b _ ] ] →
        \\            w = List.set a 0 9
        \\            show w ++ "/" ++ show b
        \\
        \\        _ →
        \\            "-"
        \\
        \\
        \\pub tree : Int → String
        \\tree n =
        \\    q = [ n, 2 ]
        \\    g (Tree [ 0 ] [ Tree q [ Tree q [] ] ])
        \\
        \\
        \\pub treeApart : Int → String
        \\treeApart n =
        \\    q = [ n, 2 ]
        \\    g (Tree [ 0 ] [ Tree q [ Tree [ 5 ] [] ] ])
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Deep.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        "  22:17 List.set a: accepted param\n",
        "  32:5 call Deep.f <constructor …>#Cons.0: rejected element: one cell can be at two positions of it\n",
        "  38:5 call Deep.f <constructor …>#Cons.0: accepted fresh\n",
        "  46:11 call Deep.f <call Deep.lit>#Cons.0: rejected element: one cell can be at two positions of it\n",
        "  54:14 call Deep.f <call Deep.rep>#Cons.0: rejected element: one cell can be at two positions of it\n",
        "  64:5 call Deep.f <call Deep.wrap>#Cons.0: rejected element: one cell can be at two positions of it\n",
        "  70:5 call Deep.f <call Deep.wrap>#Cons.0: accepted call\n",
        "  77:17 List.set a: accepted param\n",
        "  87:5 call Deep.g <constructor …>#Tree.0: rejected element: one cell can be at two positions of it\n",
        "  93:5 call Deep.g <constructor …>#Tree.0: accepted fresh\n",
        "total 10: accepted 5 (fresh 2, call 1, param 2, callback-param 0, once 0, entry 0; assumed 0), pending 0, rejected 5\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// One list at two places of a value keeps its claim (research report 114
// §8). The location of such a list was `shared`, which refuses each write,
// also when nothing reads the other place. Two facts say it now:
//
// - `also`: a callee answers a list that it made at two locations
//   (`make`, and `further` one call away). The caller gives both
//   locations one atom, so a write of one and a read of the other overlap.
// - `twice`: a summary location holds one list at two places (`[ q, q ]`,
//   `makeDeep`). It keeps what it holds, and a part of it is all of it.
//
// Each `…Dead` twin writes one place and does not read the other, and is
// accepted. `deepCallee` hands such a value to a callee that writes one
// place of the location: it is refused, because the callee's contract does
// not say which cells of the location it reads.
test "ownership v3: one list at two places keeps its claim" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Two.beni",
        \\import List
        \\import Maybe
        \\import String
        \\
        \\
        \\type Lst
        \\    = Cons (List Int) Lst
        \\    | Nil
        \\
        \\
        \\show : List Int → String
        \\show l = String.join (List.map l String.fromInt) ","
        \\
        \\
        \\make : Int → List Int × List Int
        \\make n =
        \\    q = [ n, 2 ]
        \\    ( q, q )
        \\
        \\
        \\pub pair : Int → String
        \\pair n =
        \\    r = make n
        \\    w = List.set r.0 0 9
        \\    show w ++ "/" ++ show r.1
        \\
        \\
        \\pub pairDead : Int → String
        \\pairDead n =
        \\    r = make n
        \\    w = List.set r.0 0 9
        \\    show w
        \\
        \\
        \\further : Int → List Int × List Int
        \\further n = make n
        \\
        \\
        \\pub pairFurther : Int → String
        \\pairFurther n =
        \\    r = further n
        \\    w = List.set r.1 0 9
        \\    show w ++ "/" ++ show r.0
        \\
        \\
        \\pub pairFurtherDead : Int → String
        \\pairFurtherDead n =
        \\    r = further n
        \\    w = List.set r.1 0 9
        \\    show w
        \\
        \\
        \\pub elems : Int → String
        \\elems n =
        \\    q = [ n, 2 ]
        \\    case [ q, q ] of
        \\        [ a, b ] →
        \\            w = List.set a 0 9
        \\            show w ++ "/" ++ show b
        \\
        \\        _ →
        \\            "-"
        \\
        \\
        \\pub elemsDead : Int → String
        \\elemsDead n =
        \\    q = [ n, 2 ]
        \\    case [ q, q ] of
        \\        [ a, _ ] →
        \\            w = List.set a 0 9
        \\            show w
        \\
        \\        _ →
        \\            "-"
        \\
        \\
        \\makeDeep : Int → Lst
        \\makeDeep n =
        \\    q = [ n, 2 ]
        \\    Cons [ 0 ] (Cons q (Cons q Nil))
        \\
        \\
        \\pub deep : Int → String
        \\deep n =
        \\    case makeDeep n of
        \\        Cons _ (Cons a (Cons b _)) →
        \\            w = List.set a 0 9
        \\            show w ++ "/" ++ show b
        \\
        \\        _ →
        \\            "-"
        \\
        \\
        \\pub deepDead : Int → String
        \\deepDead n =
        \\    case makeDeep n of
        \\        Cons _ (Cons a (Cons _ _)) →
        \\            w = List.set a 0 9
        \\            show w
        \\
        \\        _ →
        \\            "-"
        \\
        \\
        \\touch : Lst → String
        \\touch t =
        \\    case t of
        \\        Cons _ (Cons a _) →
        \\            show (List.set a 0 9)
        \\
        \\        _ →
        \\            "-"
        \\
        \\
        \\pub deepCallee : Int → String
        \\deepCallee n = touch (makeDeep n)
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Two.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        "  24:9 List.set r.0: rejected later-use: it is read again at 25:22 (<call Two.show>)\n",
        "  31:9 List.set r.0: accepted call\n",
        "  42:9 List.set r.1: rejected later-use: it is read again at 43:22 (<call Two.show>)\n",
        "  49:9 List.set r.1: accepted call\n",
        "  58:17 List.set a: rejected later-use: it is read again at 59:30 (<call Two.show>)\n",
        "  70:17 List.set a: accepted fresh\n",
        "  87:17 List.set a: rejected later-use: it is read again at 88:30 (<call Two.show>)\n",
        "  98:17 List.set a: accepted call\n",
        "  109:19 List.set a: accepted param\n",
        "  116:16 call Two.touch <call Two.makeDeep>#Cons.0: rejected element: one cell can be at two positions of it\n",
        "total 10: accepted 5 (fresh 1, call 3, param 1, callback-param 0, once 0, entry 0; assumed 0), pending 0, rejected 5\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// The faults that the review of the fixes of report 114 found (§9).
//
// - `levels`: `mk3` answers a value whose deep level holds one list
//   twice (`twice`). A part of it goes to `h`, which writes its own top
//   level and reads its deep level. Both are that one location of the
//   caller, so the two operands are one list. `levelsApart` is the twin.
// - `helper`: a hole that calls a function of the top level is a helper:
//   the platform calls it where it renders, after the other holes. So it
//   reads `q` after the push of the next hole. `helperDead` and
//   `helperAfter` are the twins, and `attribute` is no helper; the three
//   are refused now, since a lowering may evaluate any hole where it
//   renders, from the lists the hole reads (`dom`'s inputs, #2505), so
//   the markup holds `q`, which the hole that pushes reads (research
//   report 120).
// - `Page.view`: the browser platform keeps the values of a page's holes
//   in the markup's value, and reads them where it renders, after the
//   frame. So `q` is read again at the frame's end, and the push after
//   the markup is refused.
test "ownership v3: the faults of the review of report 114 are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Review.beni",
        \\import Html exposing (Html)
        \\import List
        \\import Ssr
        \\import String
        \\
        \\
        \\type Lst
        \\    = Cons (List Int) Lst
        \\    | Nil
        \\
        \\
        \\show : List Int → String
        \\show l = String.join (List.map l String.fromInt) ","
        \\
        \\
        \\h : Lst → String
        \\h t =
        \\    case t of
        \\        Cons a (Cons b _) →
        \\            show (List.push a 1) ++ "/" ++ show b
        \\
        \\        _ →
        \\            "-"
        \\
        \\
        \\mk3 : Int → Lst
        \\mk3 n =
        \\    q = [ n, 2 ]
        \\    Cons [ 0 ] (Cons q (Cons q Nil))
        \\
        \\
        \\mkApart : Int → Lst
        \\mkApart n =
        \\    q = [ n, 2 ]
        \\    Cons [ 0 ] (Cons q (Cons [ 5 ] Nil))
        \\
        \\
        \\pub levels : Int → String
        \\levels n =
        \\    case mk3 n of
        \\        Cons _ r →
        \\            h r
        \\
        \\        Nil →
        \\            "-"
        \\
        \\
        \\pub levelsApart : Int → String
        \\levelsApart n =
        \\    case mkApart n of
        \\        Cons _ r →
        \\            h r
        \\
        \\        Nil →
        \\            "-"
        \\
        \\
        \\item : List Int → Html msg
        \\item l = <span>{show l}</span>
        \\
        \\
        \\pub helper : Int → String
        \\helper n =
        \\    q = [ n, 2 ]
        \\    Ssr.render (<div>{item q}{show (List.push q 9)}</div>)
        \\
        \\
        \\pub helperDead : Int → String
        \\helperDead n =
        \\    q = [ n, 2 ]
        \\    Ssr.render (<div>{item [ 4 ]}{show (List.push q 9)}</div>)
        \\
        \\
        \\pub helperAfter : Int → String
        \\helperAfter n =
        \\    q = [ n, 2 ]
        \\    Ssr.render (<div>{show (List.push q 9)}{item [ 4 ]}</div>)
        \\
        \\
        \\pub attribute : Int → String
        \\attribute n =
        \\    q = [ n, 2 ]
        \\    Ssr.render (<div title={show q}>{show (List.push q 9)}</div>)
    );
    {
        const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Review.beni" }, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        for ([_][]const u8{
            "  20:19 List.push a: accepted param\n",
            "  42:13 call Review.h r#Cons.0: rejected disjoint: another operand of the same operation reaches it\n",
            "  52:13 call Review.h r#Cons.0: accepted call\n",
            "  65:37 List.push q: rejected later-use: it is read again at 65:17 (<expression>)\n",
            "  71:41 List.push q: rejected later-use: it is read again at 71:5 (<call Ssr.render>)\n",
            "  77:29 List.push q: rejected later-use: it is read again at 77:5 (<call Ssr.render>)\n",
            "  83:44 List.push q: rejected later-use: it is read again at 83:5 (<call Ssr.render>)\n",
            "total 7: accepted 2 (fresh 0, call 1, param 1, callback-param 0, once 0, entry 0; assumed 0), pending 0, rejected 5\n",
        }) |line| {
            if (std.mem.indexOf(u8, r.stdout, line) == null) {
                std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
                return error.TestExpectedLine;
            }
        }
    }
    try w.write("Page.beni",
        \\import Browser
        \\import Html exposing (Html)
        \\import List
        \\import String
        \\
        \\
        \\type Msg
        \\    = Next
        \\
        \\
        \\type alias Model =
        \\    step : Int
        \\
        \\
        \\update : Msg, Model → Model
        \\update msg model = { model | step = model.step + 1 }
        \\
        \\
        \\show : List Int → String
        \\show l = String.join (List.map l String.fromInt) ","
        \\
        \\
        \\pub view : Model → Html Msg
        \\view model =
        \\    q = [ model.step, 2 ]
        \\    v = <ul><For each={q}>{λi → <li>{String.fromInt i}</li>}</For></ul>
        \\    w = List.push q 9
        \\    <div>{v}<p>{show w}</p></div>
        \\
        \\
        \\main : Browser.Program
        \\main = Browser.program { init = λ⊤ → { step = 0 }, update = update, view = view }
    );
    {
        const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=browser", "Page.beni" }, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        for ([_][]const u8{
            "  27:9 List.push q: rejected later-use: it is read again at 28:5 (<expression>)\n",
            "total 1: accepted 0 (fresh 0, call 0, param 0, callback-param 0, once 0, entry 0; assumed 0), pending 0, rejected 1\n",
        }) |line| {
            if (std.mem.indexOf(u8, r.stdout, line) == null) {
                std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
                return error.TestExpectedLine;
            }
        }
    }
}

// The faults that the review of the fix of report 113 found (§6). A value
// that the walk cannot follow was read as holding nothing, or as holding its
// cells with a claim and no word that one cell is at two of its locations.
//
// - `aliasFunction`: a record alias's constructor as a function value. The
//   walk had no row for it and gave no function, so the answer of `List.map`
//   held nothing. `aliasFunctionDead` is the safe twin.
// - `aliasTwice`: a record alias's constructor applied to one list two
//   times. Its value was every cell at every location (`smear`), which says
//   nothing of one cell at two places. `aliasTwiceApart` is the safe twin.
// - `tryTwice`: the same through `?`, whose success was a `smear` of the
//   scrutinee. `tryApart` is the safe twin.
test "ownership v3: a value that the walk cannot follow holds its cells" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Unfollowed.beni",
        \\import List
        \\import String
        \\
        \\
        \\ints : List Int → String
        \\ints xs = String.join (List.map xs String.fromInt) ","
        \\
        \\
        \\type alias R =
        \\    zs : List Int
        \\
        \\
        \\type alias P =
        \\    a : List Int
        \\    b : List Int
        \\
        \\
        \\bump : P → P
        \\bump p = { a = List.push p.a 1, b = List.push p.b 2 }
        \\
        \\
        \\pub aliasFunction : Int → String
        \\aliasFunction c =
        \\    xs = [ c, 2, 3 ]
        \\    bs = List.map [ xs ] R
        \\    ys = List.set xs 0 9
        \\    "${ints ys} ${ints (List.concatMap bs .zs)}"
        \\
        \\
        \\pub aliasFunctionDead : Int → String
        \\aliasFunctionDead c =
        \\    xs = [ c, 2, 3 ]
        \\    bs = List.map [ xs ] R
        \\    ys = List.set xs 0 9
        \\    ints ys
        \\
        \\
        \\pub aliasTwice : Int → String
        \\aliasTwice c =
        \\    xs = [ c, 2, 3 ]
        \\    q = bump (P xs xs)
        \\    "${ints q.a} ${ints q.b}"
        \\
        \\
        \\pub aliasTwiceApart : Int → String
        \\aliasTwiceApart c =
        \\    xs = [ c, 2, 3 ]
        \\    q = bump (P xs [ 4 ])
        \\    "${ints q.a} ${ints q.b}"
        \\
        \\
        \\twiceThrough : List Int → Result String String
        \\twiceThrough xs =
        \\    r = Ok { a = xs, b = xs }
        \\    p = r?
        \\    q = bump p
        \\    Ok "${ints q.a} ${ints q.b}"
        \\
        \\
        \\pub tryTwice : Int → String
        \\tryTwice c = Result.withDefault (twiceThrough [ c, 2, 3 ]) ""
        \\
        \\
        \\apartThrough : List Int → Result String String
        \\apartThrough xs =
        \\    r = Ok { a = xs, b = [ 5 ] }
        \\    p = r?
        \\    q = bump p
        \\    Ok "${ints q.a} ${ints q.b}"
        \\
        \\
        \\pub tryApart : Int → String
        \\tryApart c = Result.withDefault (apartThrough [ c, 2, 3 ]) ""
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Unfollowed.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        // `aliasFunction` and its twin: the elements of `bs` hold `xs`.
        "  26:10 List.set xs: rejected later-use: it is read again at 27:25 (<call List.concatMap>)\n",
        "  34:10 List.set xs: accepted fresh\n",
        // `aliasTwice` and its twin.
        "  41:9 call Unfollowed.bump <constructor …>.a: rejected disjoint: another operand of the same operation reaches it\n",
        "  41:9 call Unfollowed.bump <constructor …>.b: rejected disjoint: another operand of the same operation reaches it\n",
        "  48:9 call Unfollowed.bump <constructor …>.a: accepted fresh\n",
        "  48:9 call Unfollowed.bump <constructor …>.b: accepted fresh\n",
        // `tryTwice` and its twin.
        "  56:9 call Unfollowed.bump p.a: rejected disjoint: another operand of the same operation reaches it\n",
        "  56:9 call Unfollowed.bump p.b: rejected disjoint: another operand of the same operation reaches it\n",
        "  68:9 call Unfollowed.bump p.a: accepted param\n",
        "  68:9 call Unfollowed.bump p.b: accepted fresh\n",
        "total 14: accepted 9 (fresh 6, call 0, param 3, callback-param 0, once 0, entry 0; assumed 0), pending 0, rejected 5\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// The faults that a search by hand found after the convergence test of
// research report 112 (§6.3). The test's family has flat lists only, and no
// result in it has two parts. These are about the match between two readings
// of one type, and about a claim of a contract that the callee cannot know.
//
// - `wider`: `idp : a → a` goes to a parameter of the type `List (List Int)
//   → List (List Int)`. Its one location, the type variable, stands for the
//   outer list and for each inner list. The prototype matched the two types
//   in one direction: the inner lists of the answer had no holder.
//   `widerDead` is the safe twin, and it stays accepted.
// - `below`: the holder's type is the wider one (`a → a`), and the function
//   (`List b → List b`) has a variable one level down. The part of the
//   argument that the variable stands for is each list below that place.
//
// A contract says that two sources of a result are two cells: two locations
// are apart, and one summary location holds each cell once. The caller
// trusted that. It rests on what only the caller knows:
//
// - `answerAndArgument`, `answerTwice`: the function that the callee was
//   handed. It answers its parameter, so the two parts are one list.
// - `nestedAnswer`: the same, one function deeper. The handed function
//   answers the answer of a function that it captured.
// - `argumentTwice`: the arguments. No function value: the callee only
//   rearranges what it takes, and the argument has one list at two places.
// - `oneLocation`, `answerOfTwo`: the same two for one summary location:
//   the elements of the result are two parts of one argument, or two parts
//   of one answer of a function that answers one list two times.
// - `oneAnswerTwoArguments`: both. The elements are two answers of one
//   function, which is handed one list as two arguments. `oneAnswerApart`
//   is the safe twin, and it stays accepted.
// - `oneOfSeveral`: the argument with one list at two places is one of
//   several values (an `if`). A review of the pull request found that the
//   check of the arguments did not look into such a value.
//   `oneOfSeveralApart` is the safe twin, and it stays accepted.
//
// The prototype that passed the first gate accepted each of these demands.
test "ownership v3: the faults that a search by hand found are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Hand.beni",
        \\import List
        \\
        \\
        \\idp : a → a
        \\idp v =
        \\    v
        \\
        \\
        \\run2 : (List (List Int) → List (List Int)), List (List Int) → List (List Int)
        \\run2 f v =
        \\    f v
        \\
        \\
        \\pub wider : Int → Int
        \\wider c =
        \\    inner = [ c ]
        \\    qq = [ inner ]
        \\    r = run2 idp qq
        \\    w = List.update r 0 λm → List.push m 9
        \\    List.length w + List.length inner
        \\
        \\
        \\pub widerDead : Int → Int
        \\widerDead c =
        \\    inner = [ c ]
        \\    qq = [ inner ]
        \\    r = run2 idp qq
        \\    w = List.update r 0 λm → List.push m 9
        \\    List.length w
        \\
        \\
        \\app : (a → a), a → a
        \\app f v =
        \\    f v
        \\
        \\
        \\keepL : List b → List b
        \\keepL ys =
        \\    List.take ys 99
        \\
        \\
        \\pub below : Int → Int
        \\below c =
        \\    inner = [ c ]
        \\    r = app keepL [ [ inner ] ]
        \\    w =
        \\        case r of
        \\            [ [ m, …_ ], …_ ] →
        \\                List.push m 9
        \\
        \\            _ →
        \\                []
        \\    List.length w + List.length inner
        \\
        \\
        \\withBoth : (List Int → List Int), List Int → List Int × List Int
        \\withBoth f xs =
        \\    ( f xs, xs )
        \\
        \\
        \\pub answerAndArgument : Int → Int
        \\answerAndArgument c =
        \\    r = withBoth (λl → l) [ c ]
        \\    v = [ r.0, r.1 ]
        \\    w = List.update v 0 λm → List.push m 9
        \\    List.length w
        \\
        \\
        \\twoCalls : (List Int → List Int), List Int → List Int × List Int
        \\twoCalls f xs =
        \\    a = f xs
        \\    b = f xs
        \\    ( a, b )
        \\
        \\
        \\pub answerTwice : Int → Int
        \\answerTwice c =
        \\    r = twoCalls (λl → l) [ c ]
        \\    v = [ r.0, r.1 ]
        \\    w = List.update v 0 λm → List.push m 9
        \\    List.length w
        \\
        \\
        \\mkv : (x → a), x → a
        \\mkv build q =
        \\    build q
        \\
        \\
        \\pub nestedAnswer : Int → Int
        \\nestedAnswer c =
        \\    g = λl → l
        \\    r = mkv (λq → ( q, g q )) [ c ]
        \\    v = [ r.0, r.1 ]
        \\    w = List.update v 0 λm → List.push m 9
        \\    List.length w
        \\
        \\
        \\keep2 : List Int × List Int → List Int × List Int
        \\keep2 p =
        \\    ( p.0, p.1 )
        \\
        \\
        \\pub argumentTwice : Int → Int
        \\argumentTwice c =
        \\    q = [ c ]
        \\    r = keep2 ( q, q )
        \\    v = [ r.0, r.1 ]
        \\    w = List.update v 0 λm → List.push m 9
        \\    List.length w
        \\
        \\
        \\pack : List Int × List Int → List (List Int)
        \\pack p =
        \\    [ p.0, p.1 ]
        \\
        \\
        \\pub oneLocation : Int → Int
        \\oneLocation c =
        \\    q = [ c ]
        \\    v = pack ( q, q )
        \\    w = List.update v 0 λm → List.push m 9
        \\    List.length w
        \\
        \\
        \\gather : (List Int → List Int × List Int), List Int → List (List Int)
        \\gather f x =
        \\    r = f x
        \\    [ r.0, r.1 ]
        \\
        \\
        \\pub answerOfTwo : Int → Int
        \\answerOfTwo c =
        \\    v = gather (λl → ( l, l )) [ c ]
        \\    w = List.update v 0 λm → List.push m 9
        \\    List.length w
        \\
        \\
        \\each : (List Int → List Int), List Int, List Int → List (List Int)
        \\each f x y =
        \\    [ f x, f y ]
        \\
        \\
        \\pub oneAnswerTwoArguments : Int → Int
        \\oneAnswerTwoArguments c =
        \\    q = [ c ]
        \\    v = each (λl → l) q q
        \\    w = List.update v 0 λm → List.push m 9
        \\    List.length w
        \\
        \\
        \\pub oneAnswerApart : Int → Int
        \\oneAnswerApart c =
        \\    v = each (λl → l) [ c ] [ c ]
        \\    w = List.update v 0 λm → List.push m 9
        \\    List.length w
        \\
        \\
        \\parts : (List Int → List Int), List Int × List Int → List (List Int)
        \\parts f p =
        \\    [ f p.0, f p.1 ]
        \\
        \\
        \\pub oneOfSeveral : Int → Int
        \\oneOfSeveral c =
        \\    q = [ c ]
        \\    x = if c ≥ 0 then ( q, q ) else ( [ 1 ], [ 2 ] )
        \\    v = parts (λl → l) x
        \\    w = List.update v 0 λm → List.push m 9
        \\    List.length w
        \\
        \\
        \\pub oneOfSeveralApart : Int → Int
        \\oneOfSeveralApart c =
        \\    x = if c ≥ 0 then ( [ c ], [ c ] ) else ( [ 1 ], [ 2 ] )
        \\    v = parts (λl → l) x
        \\    w = List.update v 0 λm → List.push m 9
        \\    List.length w
        \\
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Hand.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        "  19:9 call List.update r: accepted call\n",
        "  19:9 call List.update r[*]: rejected later-use: it is read again at 20:21 (<call List.length>)\n",
        "  28:9 call List.update r[*]: accepted call\n",
        "  49:17 List.push m: rejected later-use: it is read again at 53:21 (<call List.length>)\n",
        "  65:9 call List.update v[*]: rejected element: one cell can be at two positions of it\n",
        "  80:9 call List.update v[*]: rejected element: one cell can be at two positions of it\n",
        "  94:9 call List.update v[*]: rejected element: one cell can be at two positions of it\n",
        "  108:9 call List.update v[*]: rejected element: one cell can be at two positions of it\n",
        "  121:9 call List.update v[*]: rejected element: one cell can be at two positions of it\n",
        "  134:9 call List.update v[*]: rejected element: one cell can be at two positions of it\n",
        "  147:9 call List.update v[*]: rejected element: one cell can be at two positions of it\n",
        "  154:9 call List.update v[*]: accepted call\n",
        "  168:9 call List.update v[*]: rejected element: one cell can be at two positions of it\n",
        "  176:9 call List.update v[*]: accepted call\n",
        "total 37: accepted 27 (fresh 4, call 11, param 0, callback-param 12, once 0, entry 0; assumed 0), pending 0, rejected 10\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// The accepted twins of the same fixtures stay accepted: the rules that
// refuse the 19 programs do not refuse the programs beside them, where each
// write is safe.
test "ownership v3 (the step 0 prototype): the accepted twins of the refused fixtures stay accepted" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const twins = [_][]const u8{
        "SanitiserPairCycleFoldApart", "SanitiserPairCycleLoopApart", "SanitiserPairCycleParamApart", "SanitiserPairCrossEdgeFoldApart",
        "SanitiserFoldHandsLabel",     "SanitiserFoldAlternatives",   "SanitiserRecordCallback",      "SanitiserPrependFront",
        "SanitiserFoldAnswerFed",      "SanitiserFoldAccumulator",    "SanitiserCellCapture",
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "check", "--ownership=v3", "--ownership-everywhere", "--no-cache", "--platform=node" });
    for (twins) |name| try argv.append(a, try std.fmt.allocPrint(a, "tests/corpus/run/{s}.beni", .{name}));
    const r = try w.runWith(argv.items, .{ .raw_diagnostics = true, .cwd = .inherit });
    if (r.exit_code != 0) std.debug.print("{s}\n", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
}

// The two faults that the generator of research report 111 found.
//
// `sameList` (seed 144 of the second family): `callBoth` hands `q` to a
// function that could write it, so the result has a new name for the cells
// of `q`. `ident` does not write, so `q` stays in use; a later write of `q`
// must see the result as a holder (report 111 §3.10).
//
// `twice` (the first family's first run): a list at two positions of a
// literal gives a location with no claim. The location still holds the
// list, so a write of the list while the literal is read is refused
// (report 111 §3.5).
test "ownership v3 (the step 0 prototype): the two faults that the generator found are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Gen.beni",
        \\import List
        \\
        \\
        \\ident : List Int → List Int
        \\ident xs = xs
        \\
        \\
        \\callBoth : (List Int → List Int), (List Int → List Int), List Int → List Int × List Int
        \\callBoth f g xs =
        \\    a = f xs
        \\    ( a, g a )
        \\
        \\
        \\pub sameList : List Int, List Int → Int
        \\sameList p q =
        \\    v0 = { a = q, b = p }
        \\    v1 = (callBoth ident ident q).1
        \\    v2 = { v0 | a = List.push v0.a 1 }
        \\    List.length v1 + List.length v2.a
        \\
        \\
        \\pub twice : List Int → Int
        \\twice q =
        \\    v0 = [ q, q ]
        \\    v3 = [ …q, 8 ]
        \\    List.length v3 + List.length v0
        \\
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Gen.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        "  18:21 List.push v0.a: rejected later-use: it is read again at 19:5 (<call List.length>)\n",
        "  25:12 construction q: rejected later-use: it is read again at 26:22 (<call List.length>)\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// The three classes of research report 115, each a state of the holder model
// that meant "unknown" and read as "empty" (report 116 §2), closed by the
// kernel of `docs/design/ownership-v3-kernel.md`:
//
// - `twoOf`, `withG`, `both`: a cell a callee made had no name (`fresh` was a
//   flag), so one answer at two places was two cells, a cell handed to a
//   function and answered was apart from the list, and a cell that escaped
//   into a `Ref` escaped nowhere. Now a fresh cell is named by its allocation
//   site (kernel §4.2): `twoOf`'s and `withG`'s writes are refused where the
//   other place is read, and `both`'s cell is escaped at the call. The safe
//   twins of the first two are accepted; `bothDead` stays refused, because an
//   escaped cell is never written (§5, test 3).
// - `eq` with no annotation: `==` dispatches to it, and the method was read
//   by its name as "only reads". Now a method call is a call of the code the
//   dispatch table names (kernel §6.11): `eq`'s write of its operand is a
//   demand at `==`, refused where `q` is read again, accepted where not.
// - `List.sortWith`'s comparator: the worded row handed it `shared`, which
//   escaped nothing. Now a function parameter the words do not describe is
//   handed every cell of every parameter, not `free` (kernel §6.10): the
//   elements escape, and the later writes are refused.
test "ownership v3: the faults of the third blind test are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Third.beni",
        \\import List
        \\import Ref
        \\
        \\
        \\type Bag
        \\    = Bag (List Int)
        \\
        \\
        \\eq a b =
        \\    case a of
        \\        Bag xs →
        \\            List.length (List.set xs 0 9) == 0
        \\
        \\
        \\twoOf : (⊤ → a) → a × a
        \\twoOf g =
        \\    x = g ⊤
        \\    ( x, x )
        \\
        \\
        \\withG : (List Int → a) → a × List Int
        \\withG g =
        \\    x = [ 1 ]
        \\    ( g x, x )
        \\
        \\
        \\both : (List Int → ⊤) → List Int
        \\both h =
        \\    x = [ 1 ]
        \\    h x
        \\    x
        \\
        \\
        \\pub twoOfLive : Int → Int
        \\twoOfLive n =
        \\    p = twoOf λ_ → [ n ]
        \\    w = List.set p.0 0 9
        \\    List.sum w + List.sum p.1
        \\
        \\
        \\pub twoOfDead : Int → Int
        \\twoOfDead n =
        \\    p = twoOf λ_ → [ n ]
        \\    w = List.set p.0 0 9
        \\    List.sum w
        \\
        \\
        \\pub withGLive : Int → Int
        \\withGLive n =
        \\    p = withG λl → l
        \\    w = List.set p.0 0 n
        \\    List.sum w + List.sum p.1
        \\
        \\
        \\pub withGDead : Int → Int
        \\withGDead n =
        \\    p = withG λl → l
        \\    w = List.set p.0 0 n
        \\    List.sum w
        \\
        \\
        \\pub bothLive : Int → Int
        \\bothLive n =
        \\    cell = Ref.make [ 0 ]
        \\    y = both λl → Ref.set cell l
        \\    w = List.set y 0 n
        \\    List.sum w + List.sum (Ref.get cell)
        \\
        \\
        \\pub bothDead : Int → Int
        \\bothDead n =
        \\    cell = Ref.make [ 0 ]
        \\    y = both λl → Ref.set cell l
        \\    w = List.set y 0 n
        \\    List.sum w
        \\
        \\
        \\pub eqLive : Int → Int
        \\eqLive n =
        \\    q = [ n ]
        \\    t = Bag q == Bag []
        \\    if t then 1 else List.sum q
        \\
        \\
        \\pub eqDead : Int → Int
        \\eqDead n =
        \\    q = [ n ]
        \\    t = Bag q == Bag []
        \\    if t then 1 else 2
        \\
        \\
        \\pub sortKeep : Int → Int
        \\sortKeep n =
        \\    cell = Ref.make [ 0 ]
        \\    xss = [ [ n ], [ 2 ] ]
        \\    s = List.sortWith xss λa _ →
        \\        Ref.set cell a
        \\        EQ
        \\    w = List.update xss 0 λm → List.set m 0 9
        \\    List.length s + List.length w + List.sum (Ref.get cell)
        \\
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Third.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        "  37:9 List.set p.0: rejected later-use: it is read again at 38:18 (<call List.sum>)\n",
        "  44:9 List.set p.0: accepted call\n",
        "  51:9 List.set p.0: rejected later-use: it is read again at 52:18 (<call List.sum>)\n",
        "  58:9 List.set p.0: accepted call\n",
        "  66:9 List.set y: rejected escaped: it escaped before the write\n",
        "  74:9 List.set y: rejected escaped: it escaped before the write\n",
        "  81:15 call Third.eq <constructor …>#Bag.0: rejected later-use: it is read again at 82:22 (<call List.sum>)\n",
        "  88:15 call Third.eq <constructor …>#Bag.0: accepted fresh\n",
        "  99:9 call List.update xss[*]: rejected escaped: it escaped before the write\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// The two traps the adversarial review of the kernel proved (research report
// 117 §7), and the fact each needed:
//
// - `twiceRead`: `a` is read out of a list the frame made and put at two
//   places of `ys`. The atom of `a` is "the elements of `r`", read through
//   `r` both times, and `r` holds each cell once; so the two reads were taken
//   for two cells. An atom now records the part it was read through, and two
//   reads of one part are one cell (kernel §4.4, `viaApart`).
// - `answerKept`: `keep` hands `x` to `g`, keeps `g`'s answer in a cell, and
//   writes `x`. The answer of a function parameter can hold what the function
//   was handed, so its escape is an escape of `x` (kernel §5, test 3); and the
//   caller judges its writes after every escape of the call (§6.2). Both the
//   callee's write and the caller's are refused.
test "ownership v3: the faults that the review of the kernel proved are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Fourth.beni",
        \\import List
        \\import Ref exposing (Ref)
        \\
        \\
        \\all : List (List Int) → Int
        \\all xss = List.sum (List.map xss List.sum)
        \\
        \\
        \\keep : Ref (List Int), (List Int → List Int), List Int → List Int
        \\keep cell g x =
        \\    y = g x
        \\    Ref.set cell y
        \\    List.set x 0 9
        \\
        \\
        \\pub twiceRead : Int → Int
        \\twiceRead n =
        \\    r = [ [ n ] ]
        \\    ys =
        \\        case r of
        \\            [ a ] →
        \\                [ a, a ]
        \\
        \\            _ →
        \\                []
        \\    w = List.update ys 0 λm → List.set m 0 9
        \\    all w
        \\
        \\
        \\pub answerKept : Int → Int
        \\answerKept n =
        \\    cell = Ref.make [ 0 ]
        \\    w = keep cell (λl → l) [ n, 2 ]
        \\    List.sum w + List.sum (Ref.get cell)
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "Fourth.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        "  13:5 List.set x: rejected escaped: it escaped before the write\n",
        "  26:9 call List.update ys[*]: rejected element: one cell can be at two positions of it\n",
        "  33:9 call Fourth.keep <literal>: rejected escaped: it escaped before the write\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// A list literal typed by a callee's type variable (an argument list of
// `Js.call`, the fields of `Js.object`) has no element location. The walk
// put its elements nowhere, so a list handed to JavaScript inside one did
// not escape, and an object that held it did not hold it: `handed` and
// `held` wrote it in place while JavaScript could read it. It is `unknown`
// over its elements now (kernel §3.2, §6.4). `bound` names the literal
// first, which gave it a list type, and was refused before.
test "ownership v3: a list literal with no element location holds its elements" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("beni.json",
        \\{ "platform": true, "name": "probe" }
    );
    try w.write("Probe.beni",
        \\import Js
        \\import List
        \\
        \\
        \\pub handed : Js.Value, List Int → List Int
        \\handed store xs =
        \\    _ = Js.call store "push" [ Js.from xs ]
        \\    List.set xs 0 9
        \\
        \\
        \\pub held : List Int → Js.Value
        \\held xs =
        \\    o = Js.object [ ( "v", Js.from xs ) ]
        \\    _ = List.set xs 0 9
        \\    o
        \\
        \\
        \\pub bound : Js.Value, List Int → List Int
        \\bound store xs =
        \\    args = [ Js.from xs ]
        \\    _ = Js.call store "push" args
        \\    List.set xs 0 9
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=.", "Probe.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        "  8:5 List.set xs: rejected escaped: it escaped before the write\n",
        "  14:9 List.set xs: rejected later-use: it is read again at 15:5 (o)\n",
        "  22:5 List.set xs: rejected escaped: it escaped before the write\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// `Js.lt` and its kin ran no code by their rows (`unused a, unused a`), but
// JavaScript's `<` runs an object operand's `valueOf`, which can keep it.
// So a list handed to a comparison and then written in place could be read
// by what kept it. The operands carry no word now, and escape (kernel
// §6.10). `same` coerces nothing and keeps its row: `identical` is accepted.
test "ownership v3: a JavaScript comparison can keep its operands" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("beni.json",
        \\{ "platform": true, "name": "probe" }
    );
    try w.write("Probe.beni",
        \\import Js
        \\import List
        \\
        \\
        \\pub compared : Js.Value, List Int → List Int
        \\compared n xs =
        \\    _ = Js.lt (Js.from xs) n
        \\    List.set xs 0 9
        \\
        \\
        \\pub identical : Js.Value, List Int → List Int
        \\identical n xs =
        \\    _ = Js.same (Js.from xs) n
        \\    List.set xs 0 9
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=.", "Probe.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        "  8:5 List.set xs: rejected escaped: it escaped before the write\n",
        "  14:5 List.set xs: accepted param\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// Research report 118, the fourth blind test (reader A): six programs that v3
// accepted and that then read a list after an in-place write, each with a
// twin that is safe at run time. Every live program is refused. Of the twins,
// `derived-method.dead` is accepted: the derived `eq` of a tuple calls the
// writing `Tm.eq` on its parts, and the call is a demand on each operand
// (kernel §6.11), which nothing reads later. The other twins are the same
// programs with the reader removed from a place the checker does not see
// into, and stay refused (research report 120 §3): a `Ref`'s reads (the
// kernel judges cells at a later stage, §0), a model location that no
// function reads (`entry-fresh-twice`), and the number of clicks
// (`entry-message.dead` is the live program with one click fewer).
test "ownership v3: the faults of the fourth blind test, reader A, are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const dir = "bench/ownership-sweeps/blind4a-faults/";
    const Case = struct { name: []const u8, platform: []const u8, files: []const []const u8 = &.{"Main.beni"}, accepted: bool, why: []const u8 = "" };
    const page = "tests/platforms/page";
    const cases = [_]Case{
        .{ .name = "derived-method.live", .platform = "node", .files = &.{ "Main.beni", "Tm.beni" }, .accepted = false, .why = "later-use" },
        .{ .name = "derived-method.dead", .platform = "node", .files = &.{ "Main.beni", "Tm.beni" }, .accepted = true },
        .{ .name = "entry-escaped-fresh.live", .platform = page, .accepted = false, .why = "entry" },
        .{ .name = "entry-escaped-fresh.dead", .platform = page, .accepted = false, .why = "entry" },
        .{ .name = "entry-escaped-param.live", .platform = page, .accepted = false, .why = "entry" },
        .{ .name = "entry-escaped-param.dead", .platform = page, .accepted = false, .why = "entry" },
        .{ .name = "entry-fresh-twice.live", .platform = page, .accepted = false, .why = "entry" },
        .{ .name = "entry-fresh-twice.dead", .platform = page, .accepted = false, .why = "entry" },
        .{ .name = "entry-message.live", .platform = page, .accepted = false, .why = "msg" },
        .{ .name = "entry-message.dead", .platform = page, .accepted = false, .why = "msg" },
        .{ .name = "fold-escaped-answer.live", .platform = "node", .accepted = false, .why = "supply" },
        .{ .name = "fold-escaped-answer.dead", .platform = "node", .accepted = false, .why = "supply" },
    };
    for (cases) |c| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "check", "--ownership=v3", "--ownership-everywhere", "--no-cache" });
        try argv.append(a, try std.fmt.allocPrint(a, "--platform={s}", .{c.platform}));
        try argv.append(a, try std.fmt.allocPrint(a, "--root=" ++ dir ++ "{s}", .{c.name}));
        for (c.files) |file| try argv.append(a, try std.fmt.allocPrint(a, dir ++ "{s}/{s}", .{ c.name, file }));
        const r = try w.runWith(argv.items, .{ .raw_diagnostics = true, .cwd = .inherit });
        const ok = if (c.accepted) r.exit_code == 0 else r.exit_code == 1 and std.mem.indexOf(u8, r.stderr, c.why) != null;
        if (!ok) {
            std.debug.print("{s}: wanted {s} ({s}); exit {d}:\n{s}\n", .{ c.name, if (c.accepted) "accepted" else "refused", c.why, r.exit_code, r.stderr });
            return error.TestUnexpectedVerdict;
        }
    }
}

// The siblings of report 118's faults that the sibling audit of research
// report 120 found, each a negative fact that a rule read without deriving:
//
// - `foldHandsOn`: a fold callback hands a cell it made to a function that
//   keeps it, and answers it (kernel §6.8: the cell is in a supply);
// - `nominal`: `==` on a type of the program whose part's type declares a
//   writing `eq` (the derived row's body, through `Edges.termsEdges`);
// - `sortNominal`: the same derived `compare` handed as evidence.
test "ownership v3: the siblings of the fourth blind test are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Tm.beni",
        \\import List
        \\
        \\
        \\pub type T
        \\    = T (List Int)
        \\
        \\
        \\pub eq : T, T → Bool
        \\eq x y =
        \\    case ( x, y ) of
        \\        ( T a, T b ) →
        \\            List.length (List.push a 0) == List.length b
        \\
        \\
        \\pub compare : T, T → Order
        \\compare x y =
        \\    case ( x, y ) of
        \\        ( T a, T b ) →
        \\            Basics.compare (List.length (List.push a 0)) (List.length b)
        \\
    );
    try w.write("Sib.beni",
        \\import List
        \\import Tm exposing (T)
        \\
        \\
        \\type W
        \\    = W T Int
        \\
        \\
        \\pub foldHandsOn : (List Int → ⊤), Int → Int
        \\foldHandsOn g n =
        \\    out = List.foldl [ 1, 2 ] [ n ] λx acc →
        \\        _ = List.push acc x
        \\        k = [ x ]
        \\        g k
        \\        k
        \\    List.sum out
        \\
        \\
        \\pub nominal : Int → Int
        \\nominal n =
        \\    xs = [ n ]
        \\    b = W (T xs) 1 == W (T [ 5 ]) 1
        \\    if b then List.sum xs else 0
        \\
        \\
        \\pub sortNominal : Int → Int
        \\sortNominal n =
        \\    xs = [ n ]
        \\    s = List.sort [ W (T xs) 1, W (T [ 5 ]) 1 ]
        \\    List.length s + List.sum xs
        \\
    );
    const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "--root=.", "." }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    for ([_][]const u8{
        " value <call List.foldl>: rejected supply: the function answers a cell that it made and let go, and the callee hands it back\n",
        " call <derived method> <constructor …>: rejected later-use: it is read again at ",
        " value <call List.sort>: rejected call: a function that writes its parameter is handed as evidence\n",
    }) |line| {
        if (std.mem.indexOf(u8, r.stdout, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, r.stdout });
            return error.TestExpectedLine;
        }
    }
}

// Research report 119, the fourth blind test (reader B): two compiles that
// never ended. A chain of writes, each on the version the last one answered,
// cost time that doubled with each write; each entry of a version's run is
// now visited once (`Frame.markAtom`, `groundOf`, `atomSrcs`). A type whose
// halves repeat at each level has a location for each of its 2³² paths; past
// `Loc.max_layout_entries` the module is refused with a loud limit (kernel §8).
// `EvidenceDagBuildDepth32` is that type, with `==` on it.
test "ownership v3: a chain of writes and a type of repeated halves finish" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const quick: i64 = 10_000;
    const chain = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "bench/ownership-sweeps/blind4b-faults/version-chain.hang/Main.beni" }, .{ .raw_diagnostics = true, .cwd = .inherit, .timeout_ms = quick });
    try testing.expectEqual(@as(u8, 0), chain.exit_code);
    try testing.expect(std.mem.indexOf(u8, chain.stdout, "List.push v39: accepted call") != null);
    const dag = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=node", "bench/ownership-sweeps/blind4b-faults/dag-type.hang/Main.beni" }, .{ .raw_diagnostics = true, .cwd = .inherit, .timeout_ms = quick });
    try testing.expectEqual(@as(u8, 0), dag.exit_code);
    try testing.expect(std.mem.indexOf(u8, dag.stdout, "a type has more than 4096 locations") != null);
    const corpus = try w.runWith(&.{ "check", "--ownership=v3", "--ownership-everywhere", "--no-cache", "--platform=node", "tests/corpus/run/EvidenceDagBuildDepth32.beni" }, .{ .raw_diagnostics = true, .cwd = .inherit, .timeout_ms = quick });
    try testing.expectEqual(@as(u8, 1), corpus.exit_code);
    try testing.expect(std.mem.indexOf(u8, corpus.stderr, "a type has more than 4096 locations") != null);
}

// The siblings of report 118's entry faults that the sibling audit of research
// report 120 found, and two issues of the markup audit (report 117 §9.6). Each
// is accepted by the old entry rule and traps under `--sanitize-lists`:
//
// - `Message`: `update` answers a list of its message into the model and
//   later pushes onto it; the message holds a top-level list (kernel §6.13:
//   the message is never `own`, so neither is a location answered from it);
// - `Handed`: `view` hands a model list to a function it captured, which
//   keeps it in a `Ref` (a hand-on is a holder, `handsOn`);
// - `Cached`: markup stored in the model holds a model list (#2506: the
//   location of the markup is another place of the answer that holds it);
// - `Inputs`: markup holds the lists its holes read, not only the holes'
//   values: the `dom` lowering evaluates the hole where it renders (#2505).
test "ownership v3: the entry's siblings and markup's inputs are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const page = "--platform=tests/platforms/page";
    const Case = struct { name: []const u8, platform: []const u8, text: []const u8, line: []const u8 };
    const cases = [_]Case{
        .{ .name = "Message", .platform = page, .line = "entry Main.update model.items: rejected", .text =
        \\import List
        \\import Page exposing (Node)
        \\
        \\
        \\type Msg
        \\    = Load (List Int)
        \\    | Add Int
        \\
        \\
        \\type alias Model =
        \\    items : List Int
        \\
        \\
        \\base : List Int
        \\base = [ 5 ]
        \\
        \\
        \\update : Msg, Model → Model
        \\update msg model =
        \\    case msg of
        \\        Load l →
        \\            { model | items = l }
        \\
        \\        Add n →
        \\            { model | items = List.push model.items n }
        \\
        \\
        \\view : Model → Node Msg
        \\view model =
        \\    Page.element "main" []
        \\        [ Page.element "button" [ Page.attribute "id" "load", Page.onClick (Load base) ] [ Page.text (String.fromInt (List.length base)) ]
        \\        , Page.element "button" [ Page.attribute "id" "add", Page.onClick (Add 7) ] [ Page.text (String.fromInt (List.length model.items)) ]
        \\        ]
        \\
        \\
        \\main : Page.Program
        \\main = Page.sandbox { init = λ⊤ → { items = [ 1 ] }, update = update, view = view }
        },
        .{ .name = "Handed", .platform = page, .line = "entry Main.update model.items: rejected", .text =
        \\import List
        \\import Page exposing (Node)
        \\import Ref exposing (Ref)
        \\
        \\
        \\type alias Model =
        \\    items : List Int
        \\
        \\
        \\cell : Ref (List Int)
        \\cell = Ref.make []
        \\
        \\
        \\update : Int, Model → Model
        \\update n model = { model | items = List.push model.items n }
        \\
        \\
        \\mk : (List Int → ⊤) → Page.Program
        \\mk g =
        \\    Page.sandbox
        \\        { init = λ⊤ → { items = [ 1 ] }
        \\        , update = update
        \\        , view =
        \\            λmodel →
        \\                t = String.fromInt (List.length (Ref.get cell))
        \\                g model.items
        \\                Page.element "button" [ Page.attribute "id" "add", Page.onClick 7 ] [ Page.text t ]
        \\        }
        \\
        \\
        \\main : Page.Program
        \\main = mk λl → Ref.set cell l
        },
        .{ .name = "Cached", .platform = "--platform=browser", .line = "entry Main.update model.items: rejected", .text =
        \\import Browser
        \\import Html exposing (Html)
        \\import List
        \\
        \\
        \\type Msg
        \\    = Add
        \\    | Snap
        \\
        \\
        \\type alias Model =
        \\    items : List Int
        \\    cached : Html Msg
        \\    n : Int
        \\
        \\
        \\shown : List Int → Html Msg
        \\shown xs = <p id="c">{List.sum xs}</p>
        \\
        \\
        \\update : Msg, Model → Model
        \\update msg model =
        \\    case msg of
        \\        Add →
        \\            { model | items = List.push model.items model.n, n = model.n + 1 }
        \\
        \\        Snap →
        \\            { model | cached = shown model.items }
        \\
        \\
        \\view : Model → Html Msg
        \\view model =
        \\    <main>
        \\        <button id="add" onClick={Add}>add</button>
        \\        <button id="snap" onClick={Snap}>snap</button>
        \\        {model.cached}
        \\        <p id="n">{List.sum model.items}</p>
        \\    </main>
        \\
        \\
        \\main : Browser.Program
        \\main = Browser.program { init = λ⊤ → { items = [ 1, 2 ], cached = <p>none</p>, n = 3 }, update = update, view = view }
        },
        .{ .name = "Inputs", .platform = "--platform=browser", .line = "List.push xs: rejected later-use", .text =
        \\import Browser
        \\import Html exposing (Html)
        \\import List
        \\
        \\
        \\helper : Int → Html Int
        \\helper n =
        \\    xs = List.repeat n 1
        \\    m = <p id="a">{List.sum xs}</p>
        \\    ys = List.push xs 9
        \\    <div><button id="add" onClick={1}>add</button>{m}<p id="b">{List.length ys}</p></div>
        \\
        \\
        \\main : Browser.Program
        \\main = Browser.program { init = λ⊤ → 3, update = λd n → n + d, view = helper }
        },
    };
    for (cases) |c| {
        const file = try std.fmt.allocPrint(a, "{s}/Main.beni", .{c.name});
        try w.write(file, c.text);
        const main = try std.fs.path.join(a, &.{ try w.projectPath(), file });
        const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", c.platform, main }, .{ .raw_diagnostics = true, .cwd = .inherit });
        if (r.exit_code != 0 or std.mem.indexOf(u8, r.stdout, c.line) == null) {
            std.debug.print("{s}: missing line {s}; exit {d}:\n{s}{s}\n", .{ c.name, c.line, r.exit_code, r.stdout, r.stderr });
            return error.TestExpectedLine;
        }
    }
}

// The two faults that the adversarial review of research report 120 proved
// (§5), each accepted and a trap under `--sanitize-lists` before:
//
// - `Burst`: a handler closure in a markup hole captures the model and is
//   called after `update` ran (three clicks in one task). Every value at an
//   item that no row names as an attribute is kept by the runtime past the
//   render, so it escapes (kernel §6.12).
// - `Listen`: `Hosted.tap` builds `Js.array [ … ]`, a literal whose place
//   is a type variable with no element step, so the subscription body's
//   captures were dropped. A literal whose place names no part for its
//   items is `unknown` over them (kernel §3.2, §6.4).
test "ownership v3: the faults of the review of report 120 are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const Case = struct { name: []const u8, platform: []const u8, text: []const u8, line: []const u8 };
    const cases = [_]Case{
        .{ .name = "Burst", .platform = "--platform=browser", .line = "entry Main.update model: rejected", .text =
        \\import Browser
        \\import Html exposing (Html)
        \\import List
        \\
        \\
        \\type Msg
        \\    = Push
        \\    | Nop
        \\
        \\
        \\update : Msg, List Int → List Int
        \\update msg items =
        \\    case msg of
        \\        Push →
        \\            List.push items 1
        \\
        \\        Nop →
        \\            items
        \\
        \\
        \\view : List Int → Html Msg
        \\view items =
        \\    <main>
        \\        <button id="b" onClick={λ_ → if List.length items < 3 then Push else Nop}>b</button>
        \\        <p id="out">{String.fromInt (List.length items)}</p>
        \\    </main>
        \\
        \\
        \\main : Browser.Program
        \\main = Browser.program { init = λ⊤ → [ 5 ], update = update, view = view }
        },
        .{ .name = "Listen", .platform = "--platform=browser-tea", .line = "entry Main.update model.items: rejected", .text =
        \\import Browser
        \\import Cmd exposing (Cmd)
        \\import Html exposing (Html)
        \\import List
        \\import Sub exposing (Sub)
        \\import Tea
        \\import Time
        \\
        \\
        \\type Msg
        \\    = Push
        \\    | Seen Int
        \\
        \\
        \\type alias Model =
        \\    items : List Int
        \\    seen : Int
        \\
        \\
        \\update : Msg, Model → Model × Cmd Msg
        \\update msg m =
        \\    case msg of
        \\        Push →
        \\            ( { m | items = List.push m.items 1 }, Cmd.none )
        \\
        \\        Seen n →
        \\            ( { m | seen = n }, Cmd.none )
        \\
        \\
        \\subscriptions : Model → Sub Msg
        \\subscriptions m =
        \\    Sub.listen "k" (λsend → body send m.items) Seen
        \\
        \\
        \\body : Browser.Send Int, List Int → ⊤
        \\body send xs =
        \\    Time.sleep (Time.millis 10)
        \\    send (List.length xs)
        \\
        \\
        \\view : Model → Html Msg
        \\view m =
        \\    <main>
        \\        <p id="out">{String.fromInt m.seen}</p>
        \\        <button id="push" onClick={Push}>push</button>
        \\    </main>
        \\
        \\
        \\main : Tea.Program
        \\main =
        \\    Tea.element
        \\        { init = λ⊤ → ( { items = [ 5 ], seen = 0 }, Cmd.none )
        \\        , update = update
        \\        , view = view
        \\        , subscriptions = subscriptions
        \\        }
        },
    };
    for (cases) |c| {
        const file = try std.fmt.allocPrint(a, "{s}/Main.beni", .{c.name});
        try w.write(file, c.text);
        const main = try std.fs.path.join(a, &.{ try w.projectPath(), file });
        const r = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", c.platform, main }, .{ .raw_diagnostics = true, .cwd = .inherit });
        if (r.exit_code != 0 or std.mem.indexOf(u8, r.stdout, c.line) == null) {
            std.debug.print("{s}: missing line {s}; exit {d}:\n{s}{s}\n", .{ c.name, c.line, r.exit_code, r.stdout, r.stderr });
            return error.TestExpectedLine;
        }
    }
}

// Research reports 121 and 122, the fifth blind test (readers C and D): ten
// programs that v3 accepted and that then read a list after an in-place
// write, each with a safe twin. Every live program is refused, and every twin
// is accepted:
//
// - `entry-unknown-view`, `entry-unknown-settle`, `view-no-code`,
//   `settle-no-code`: a function of the entry's record is one of two
//   functions (`if … then a else b`). Each value it can be is applied as a
//   function of the record (kernel §6.13); one with no known code is the
//   default, and then no model location is `own`.
// - `entry-tuple-pair`, `pair-model`: the model is a tuple and `update`
//   answers `model × Cmd msg`. Where an answer has the model is read off the
//   entry's declared type (`Mod.entryShape`), not guessed from locations.
// - `hole-closure`: a closure made in a hole holds what it captured, and the
//   markup holds the closure (kernel §6.12).
// - `row-parameter`, `for-row-message`, `for-row-keeps`: the runtime calls a
//   `For` row with each item of `each`; the row is applied to them as at a
//   call site, so what it keeps of its item escapes (kernel §6.12).
test "ownership v3: the faults of the fifth blind test are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const Case = struct { name: []const u8, platform: []const u8, accepted: bool, why: []const u8 = "" };
    const tea = "platforms/browser-tea";
    const page = "platforms/browser";
    const cases = [_]Case{
        .{ .name = "blind5c-faults/entry-tuple-pair.live", .platform = tea, .accepted = false, .why = "entry Main.update model.0" },
        .{ .name = "blind5c-faults/entry-tuple-pair.dead", .platform = tea, .accepted = true },
        .{ .name = "blind5c-faults/entry-unknown-settle.live", .platform = page, .accepted = false, .why = "entry Main.update model.items" },
        .{ .name = "blind5c-faults/entry-unknown-settle.dead", .platform = page, .accepted = true },
        .{ .name = "blind5c-faults/entry-unknown-view.live", .platform = page, .accepted = false, .why = "entry Main.update model.items" },
        .{ .name = "blind5c-faults/entry-unknown-view.dead", .platform = page, .accepted = true },
        .{ .name = "blind5c-faults/hole-closure.live", .platform = page, .accepted = false, .why = "later-use" },
        .{ .name = "blind5c-faults/hole-closure.dead", .platform = page, .accepted = true },
        .{ .name = "blind5c-faults/row-parameter.live", .platform = page, .accepted = false, .why = "entry Main.update model.rows[*]" },
        .{ .name = "blind5c-faults/row-parameter.dead", .platform = page, .accepted = true },
        .{ .name = "blind5d-faults/for-row-keeps.live", .platform = "node", .accepted = false, .why = "escaped" },
        .{ .name = "blind5d-faults/for-row-keeps.dead", .platform = "node", .accepted = true },
        .{ .name = "blind5d-faults/for-row-message.live", .platform = page, .accepted = false, .why = "entry Main.update model.rows[*]" },
        .{ .name = "blind5d-faults/for-row-message.dead", .platform = page, .accepted = true },
        .{ .name = "blind5d-faults/pair-model.live", .platform = tea, .accepted = false, .why = "entry Main.update model.0" },
        .{ .name = "blind5d-faults/pair-model.dead", .platform = tea, .accepted = true },
        .{ .name = "blind5d-faults/settle-no-code.live", .platform = page, .accepted = false, .why = "entry Main.update model.items" },
        .{ .name = "blind5d-faults/settle-no-code.dead", .platform = page, .accepted = true },
        .{ .name = "blind5d-faults/view-no-code.live", .platform = page, .accepted = false, .why = "entry Main.update model.items" },
        .{ .name = "blind5d-faults/view-no-code.dead", .platform = page, .accepted = true },
    };
    for (cases) |c| {
        const r = try w.runWith(&.{
            "check",
            "--ownership=v3",
            "--ownership-everywhere",
            "--no-cache",
            try std.fmt.allocPrint(a, "--platform={s}", .{c.platform}),
            try std.fmt.allocPrint(a, "--root=bench/ownership-sweeps/{s}", .{c.name}),
            try std.fmt.allocPrint(a, "bench/ownership-sweeps/{s}/Main.beni", .{c.name}),
        }, .{ .raw_diagnostics = true, .cwd = .inherit });
        const ok = if (c.accepted) r.exit_code == 0 else r.exit_code == 1 and std.mem.indexOf(u8, r.stderr, c.why) != null;
        if (!ok) {
            std.debug.print("{s}: wanted {s} ({s}); exit {d}:\n{s}\n", .{ c.name, if (c.accepted) "accepted" else "refused", c.why, r.exit_code, r.stderr });
            return error.TestUnexpectedVerdict;
        }
    }
}

// The siblings of the fifth blind test's faults that the audit of research
// report 123 found. Each is accepted before and is refused now:
//
// - `ShowBody`: a `Show`'s body keeps the value in `when` in an event's
//   message; the runtime calls the body with it (kernel §6.12).
// - `ForKey`: a `For`'s key function keeps its item in a `Ref`; the runtime
//   calls the key function with each item.
// - `TopField`: `view` is a field of a top-level record, a value with no
//   known code: the default, so no model location is `own` (kernel §6.13).
// - `Children`: a component's children are a value that its code is handed
//   whole, markup that holds what its holes read: the component keeps them
//   in a message here, and `update` keeps that in the model.
test "ownership v3: the siblings of the fifth blind test are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const Case = struct { name: []const u8, text: []const u8, line: []const u8, card: bool = false };
    const cases = [_]Case{
        .{ .name = "ShowBody", .line = "entry Main.update model.pick#Just.0: rejected", .text =
        \\import Browser
        \\import Html exposing (Html)
        \\import List
        \\
        \\
        \\type Msg
        \\    = Add
        \\    | Report (List Int)
        \\
        \\
        \\type alias Model =
        \\    pick : Maybe (List Int)
        \\    seen : Int
        \\
        \\
        \\update : Msg, Model → Model
        \\update msg model =
        \\    case msg of
        \\        Add →
        \\            { model | pick = Maybe.map model.pick λl → List.push l 9 }
        \\
        \\        Report l →
        \\            { model | seen = List.length l }
        \\
        \\
        \\view : Model → Html Msg
        \\view model =
        \\    <main>
        \\        <Show when={model.pick} keyed={λl → List.length l}>
        \\            {λl →
        \\                <div class="outer" onClick={Report l}>
        \\                    <button class="add" onClick={Add}>add</button>
        \\                </div>
        \\            }
        \\        </Show>
        \\        <p id="seen">{model.seen}</p>
        \\    </main>
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.program
        \\        { init = λ⊤ → { pick = Just (List.copy [ 1, 2 ]), seen = 0 }
        \\        , update = update
        \\        , view = view
        \\        }
        },
        .{ .name = "ForKey", .line = "entry Main.update model.rows[*]: rejected", .text =
        \\import Browser
        \\import Html exposing (Html)
        \\import List
        \\import Ref exposing (Ref)
        \\
        \\
        \\type Msg
        \\    = Add
        \\
        \\
        \\type alias Model =
        \\    rows : List (List Int)
        \\    cell : Ref (List Int)
        \\
        \\
        \\update : Msg, Model → Model
        \\update msg model =
        \\    case msg of
        \\        Add →
        \\            { model | rows = List.update model.rows 0 λr → List.push r 9 }
        \\
        \\
        \\key : Ref (List Int), List Int → Int
        \\key cell r =
        \\    Ref.set cell r
        \\    List.length r
        \\
        \\
        \\view : Model → Html Msg
        \\view model =
        \\    <main>
        \\        <p id="kept">{List.length (Ref.get model.cell)}</p>
        \\        <button class="add" onClick={Add}>add</button>
        \\        <For each={model.rows} keyed={key model.cell _}>{λr → <p>{List.length r}</p>}</For>
        \\    </main>
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.program
        \\        { init = λ⊤ → { rows = [ List.copy [ 1, 2 ] ], cell = Ref.make [] }
        \\        , update = update
        \\        , view = view
        \\        }
        },
        .{ .name = "TopField", .line = "entry Main.update model.items: rejected", .text =
        \\import Browser
        \\import Html exposing (Html)
        \\import List
        \\
        \\
        \\type Msg
        \\    = Add
        \\    | Snap (List Int)
        \\
        \\
        \\type alias Model =
        \\    items : List Int
        \\    saved : List Int
        \\
        \\
        \\update : Msg, Model → Model
        \\update msg model =
        \\    case msg of
        \\        Add →
        \\            { model | items = List.push model.items 3 }
        \\
        \\        Snap xs →
        \\            { model | saved = xs }
        \\
        \\
        \\view : Model → Html Msg
        \\view model =
        \\    <main>
        \\        <button id="add" onClick={Add}>add</button>
        \\        <p>{List.length model.saved}</p>
        \\    </main>
        \\
        \\
        \\views : { main : Model → Html Msg }
        \\views =
        \\    { main = view }
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.program
        \\        { init = λ⊤ → { items = List.copy [ 1, 2 ], saved = [] }
        \\        , update = update
        \\        , view = views.main
        \\        }
        },
        .{ .name = "Children", .card = true, .line = "entry Main.update model.items: rejected", .text =
        \\import Browser
        \\import Card
        \\import Html exposing (Html)
        \\import List
        \\
        \\
        \\type Msg
        \\    = Add
        \\    | Keep (Html Msg)
        \\
        \\
        \\type alias Model =
        \\    items : List Int
        \\    saved : Maybe (Html Msg)
        \\
        \\
        \\update : Msg, Model → Model
        \\update msg model =
        \\    case msg of
        \\        Add →
        \\            { model | items = List.push model.items 3 }
        \\
        \\        Keep h →
        \\            { model | saved = Just h }
        \\
        \\
        \\view : Model → Html Msg
        \\view model =
        \\    <main>
        \\        <button id="add" onClick={Add}>add</button>
        \\        <Card.wrap keep={Keep}><p>{List.length model.items}</p></Card.wrap>
        \\        {Maybe.withDefault model.saved (<p>none</p>)}
        \\    </main>
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.program
        \\        { init = λ⊤ → { items = List.copy [ 1, 2 ], saved = Nothing }
        \\        , update = update
        \\        , view = view
        \\        }
        },
    };
    for (cases) |c| {
        const file = try std.fmt.allocPrint(a, "{s}/Main.beni", .{c.name});
        try w.write(file, c.text);
        const main = try std.fs.path.join(a, &.{ try w.projectPath(), file });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "dump", "--stage=ownership", "--ownership=v3", "--ownership-everywhere", "--platform=browser", main });
        if (c.card) {
            const card = try std.fmt.allocPrint(a, "{s}/Card.beni", .{c.name});
            try w.write(card,
                \\import Html exposing (Html)
                \\
                \\
                \\pub wrap : { children : Html msg, keep : Html msg → msg } → Html msg
                \\wrap { children, keep } =
                \\    <div id="w" onClick={keep children}>{children}</div>
                \\
            );
            const dir = try std.fs.path.join(a, &.{ try w.projectPath(), c.name });
            argv.items[argv.items.len - 1] = dir;
            try argv.append(a, try std.fmt.allocPrint(a, "--root={s}", .{dir}));
        }
        const r = try w.runWith(argv.items, .{ .raw_diagnostics = true, .cwd = .inherit });
        if (r.exit_code != 0 or std.mem.indexOf(u8, r.stdout, c.line) == null) {
            std.debug.print("{s}: missing line {s}; exit {d}:\n{s}{s}\n", .{ c.name, c.line, r.exit_code, r.stdout, r.stderr });
            return error.TestExpectedLine;
        }
    }
}

// Research report 124, reader E: two faults, each a missing fact read as
// "nothing" (kernel §1), each shown by two programs in
// `bench/ownership-sweeps/blind6e-faults/` that the prototype accepted and
// that then trapped.
//
// - `entry-row-*`: a function of the program's record takes the model as
//   `{ r | n : Int }` and keeps it. The entry matched model locations with
//   the contract's by label path, and the row's location is no prefix of a
//   field's, so the function kept nothing. Every comparison now goes
//   through the call map (kernel §6.13).
// - `top-rewrite*`: a function hands a list to its function parameter,
//   writes it, and goes where the checker does not follow it. The code that
//   runs it hands a function that keeps what it is handed (kernel §6.8).
//
// Each `.live` twin is refused and each `.dead` twin is accepted.
test "ownership v3: the faults of the sixth blind test are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const Case = struct { name: []const u8, platform: []const u8, accepted: bool, why: []const u8 = "" };
    const tea = "platforms/browser-tea";
    const page = "platforms/browser";
    const cases = [_]Case{
        .{ .name = "entry-row-view", .platform = page, .accepted = false, .why = "entry Main.update model.items is refused" },
        .{ .name = "entry-row-view.live", .platform = page, .accepted = false, .why = "entry Main.update model.items is refused" },
        .{ .name = "entry-row-view.dead", .platform = page, .accepted = true },
        .{ .name = "entry-row-update", .platform = page, .accepted = false, .why = "entry Main.settle model.items is refused" },
        .{ .name = "entry-row-update.live", .platform = page, .accepted = false, .why = "entry Main.settle model.items is refused" },
        .{ .name = "entry-row-update.dead", .platform = page, .accepted = true },
        .{ .name = "top-rewrite", .platform = "node", .accepted = false, .why = "value Main.body is refused: supply: the function changes a value" },
        .{ .name = "top-rewrite.live", .platform = "node", .accepted = false, .why = "value <call Main.body> is refused: supply: the function keeps a value" },
        .{ .name = "top-rewrite.dead", .platform = "node", .accepted = true },
        .{ .name = "top-rewrite-send", .platform = tea, .accepted = false, .why = "value <call Cmd.perform> is refused: supply: the function changes a value" },
        .{ .name = "top-rewrite-send.live", .platform = tea, .accepted = false, .why = "send <constructor" },
        .{ .name = "top-rewrite-send.dead", .platform = tea, .accepted = true },
    };
    // Every case is run, so a run before the fix names each one it gets wrong.
    var bad = false;
    for (cases) |c| {
        const r = try w.runWith(&.{
            "check",
            "--ownership=v3",
            "--ownership-everywhere",
            "--no-cache",
            try std.fmt.allocPrint(a, "--platform={s}", .{c.platform}),
            try std.fmt.allocPrint(a, "--root=bench/ownership-sweeps/blind6e-faults/{s}", .{c.name}),
            try std.fmt.allocPrint(a, "bench/ownership-sweeps/blind6e-faults/{s}/Main.beni", .{c.name}),
        }, .{ .raw_diagnostics = true, .cwd = .inherit });
        const ok = if (c.accepted) r.exit_code == 0 else r.exit_code == 1 and std.mem.indexOf(u8, r.stderr, c.why) != null;
        if (!ok) {
            std.debug.print("{s}: wanted {s} ({s}); exit {d}:\n{s}\n", .{ c.name, if (c.accepted) "accepted" else "refused", c.why, r.exit_code, r.stderr });
            bad = true;
        }
    }
    if (bad) return error.TestUnexpectedVerdict;
}

// The siblings of the sixth blind test's faults that the audit of research
// report 125 found. Each is accepted before and traps; each is refused now,
// and its twin that writes a copy is accepted:
//
// - `HolderRewrite`: a known function runs `body`, and what it hands
//   `body`'s function parameter is a function in the default state, which
//   keeps what it is handed: `body` writes a list after it handed it there
//   (kernel §6.8, `defaultParams`).
// - `HolderAnswer`: the same holder, and `body` answers the list it handed
//   its function parameter: the list escaped there, and the caller writes
//   the answer.
// - `AnswerRow`: a function over `{ r | n : Int }` in a location whose type
//   is `Model`: its answer's row holds the model's `items`, which the
//   composition read as "no object" by label path (`answersAt`, `anyMeets`).
// - `SupplyRow`: the same function keeps its parameter in a fiber: what the
//   holder hands its row is the model's `items` (`slotsOf`).
// - `EvidenceRewrite`: a method handed as evidence writes a list after it
//   handed it to its function parameter; the code that runs evidence hands
//   it the default (kernel §6.11, `Contract.Effect.rewrites`).
test "ownership v3: the siblings of the sixth blind test are refused" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const Case = struct { name: []const u8, why: []const u8, text: []const u8, write: []const u8 };
    const cases = [_]Case{
        .{ .name = "HolderRewrite", .why = "value <call Main.runWith> is refused: supply: the function changes a value", .write = "ys = List.push xs 2", .text =
        \\import Io
        \\import List
        \\import Node exposing (Program)
        \\import Ref exposing (Ref)
        \\
        \\
        \\body : (List Int → ⊤) → ⊤
        \\body send =
        \\    xs = [ 1 ]
        \\    send xs
        \\    ys = List.push xs 2
        \\    send ys
        \\
        \\
        \\runWith : ((List Int → ⊤) → ⊤), Ref (List (List Int)) → ⊤
        \\runWith b r = b λl → Ref.set r (List.concat [ Ref.get r, [ l ] ])
        \\
        \\
        \\main : Program
        \\main = Io.run λ⊤ →
        \\    r = Ref.make []
        \\    runWith body r
        \\    Debug.log (Debug.toString (Ref.get r)) ⊤
        \\    Node.done
        \\
        },
        .{ .name = "HolderAnswer", .why = "List.push ys is refused: escaped", .write = "zs = List.push ys 2", .text =
        \\import Io
        \\import List
        \\import Node exposing (Program)
        \\import Ref exposing (Ref)
        \\
        \\
        \\body : (List Int → ⊤) → List Int
        \\body send =
        \\    xs = [ 1 ]
        \\    send xs
        \\    xs
        \\
        \\
        \\runWith : ((List Int → ⊤) → List Int), Ref (List (List Int)) → List Int
        \\runWith b r = b λl → Ref.set r [ l ]
        \\
        \\
        \\main : Program
        \\main = Io.run λ⊤ →
        \\    r = Ref.make []
        \\    ys = runWith body r
        \\    zs = List.push ys 2
        \\    Debug.log (Debug.toString (Ref.get r)) ⊤
        \\    Debug.log (Debug.toString zs) ⊤
        \\    Node.done
        \\
        },
        .{ .name = "AnswerRow", .why = "List.push m0.items is refused: later-use", .write = "ys = List.push m0.items 2", .text =
        \\import Io
        \\import List
        \\import Node exposing (Program)
        \\
        \\
        \\type alias Model =
        \\    items : List Int
        \\    n : Int
        \\
        \\
        \\bump : { r | n : Int } → { r | n : Int }
        \\bump m = { m | n = m.n + 1 }
        \\
        \\
        \\apply : (Model → Model), Model → Model
        \\apply g m = g m
        \\
        \\
        \\main : Program
        \\main = Io.run λ⊤ →
        \\    m0 = { items = [ 1 ], n = 0 }
        \\    m1 = apply bump m0
        \\    ys = List.push m0.items 2
        \\    Debug.log (Debug.toString m1.items) ⊤
        \\    Debug.log (Debug.toString ys) ⊤
        \\    Node.done
        \\
        },
        .{ .name = "EvidenceRewrite", .why = "value <call Main.walk> is refused: call: a function that changes a value", .write = "ys = List.push xs 2", .text =
        \\import Io
        \\import List
        \\import Node exposing (Program)
        \\import Ref exposing (Ref)
        \\
        \\
        \\type Box
        \\    = Box Int
        \\
        \\
        \\pub each : Box, (List Int → ⊤) → ⊤
        \\each _ f =
        \\    xs = [ 1 ]
        \\    f xs
        \\    ys = List.push xs 2
        \\    f ys
        \\
        \\
        \\walk : a, (List Int → ⊤) → ⊤ where a.each : a, (List Int → ⊤) → ⊤
        \\walk x f = x.each f
        \\
        \\
        \\main : Program
        \\main = Io.run λ⊤ →
        \\    r = Ref.make []
        \\    walk (Box 1) λl → Ref.set r (List.concat [ Ref.get r, [ l ] ])
        \\    Debug.log (Debug.toString (Ref.get r)) ⊤
        \\    Node.done
        \\
        },
        .{ .name = "SupplyRow", .why = "List.push m0.items is refused: escaped", .write = "ys = List.push m0.items 2", .text =
        \\import Io
        \\import List
        \\import Node exposing (Program)
        \\import Task
        \\
        \\
        \\type alias Model =
        \\    items : List Int
        \\    n : Int
        \\
        \\
        \\keep : { r | n : Int } → ⊤
        \\keep m =
        \\    _ = Task.spawn λ⊤ →
        \\        Io.sleep 5
        \\        Debug.log (Debug.toString m) ⊤
        \\    ⊤
        \\
        \\
        \\apply : (Model → ⊤), Model → ⊤
        \\apply g m = g m
        \\
        \\
        \\main : Program
        \\main = Io.run λ⊤ →
        \\    m0 = { items = [ 1 ], n = 0 }
        \\    apply keep m0
        \\    ys = List.push m0.items 2
        \\    Debug.log (Debug.toString ys) ⊤
        \\    Io.sleep 20
        \\    Node.done
        \\
        },
    };
    // Every case is run, so a run before the fix names each one it gets wrong.
    var bad = false;
    for (cases) |c| {
        // The program, then its twin that writes a copy: refused, then accepted.
        for ([_]bool{ false, true }) |dead| {
            const dir = try std.fmt.allocPrint(a, "{s}{s}", .{ c.name, if (dead) ".dead" else "" });
            const file = try std.fmt.allocPrint(a, "{s}/Main.beni", .{dir});
            var text = c.text;
            if (dead) {
                const at = std.mem.indexOf(u8, text, c.write).?;
                const eq = std.mem.indexOf(u8, c.write, "List.push ").? + "List.push ".len;
                const arg_end = std.mem.lastIndexOfScalar(u8, c.write, ' ').?;
                text = try std.fmt.allocPrint(a, "{s}{s}(List.copy {s}){s}{s}", .{ text[0..at], c.write[0..eq], c.write[eq..arg_end], c.write[arg_end..], text[at + c.write.len ..] });
            }
            try w.write(file, text);
            const root = try std.fs.path.join(a, &.{ try w.projectPath(), dir });
            const main = try std.fs.path.join(a, &.{ try w.projectPath(), file });
            const r = try w.runWith(&.{ "check", "--ownership=v3", "--ownership-everywhere", "--no-cache", "--platform=node", try std.fmt.allocPrint(a, "--root={s}", .{root}), main }, .{ .raw_diagnostics = true, .cwd = .inherit });
            const ok = if (dead) r.exit_code == 0 else r.exit_code == 1 and std.mem.indexOf(u8, r.stderr, c.why) != null;
            if (!ok) {
                std.debug.print("{s}: wanted {s} ({s}); exit {d}:\n{s}\n", .{ dir, if (dead) "accepted" else "refused", c.why, r.exit_code, r.stderr });
                bad = true;
            }
        }
    }
    if (bad) return error.TestUnexpectedVerdict;
}
