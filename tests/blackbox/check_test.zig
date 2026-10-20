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
        "beni: --platform has no effect on --stage=ast; it applies to interface, raw, types, graph, dispatch, writes and ownership\n",
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
/// stays within the per-test budget (one dump each).
fn expectSurface(package: []const u8, args: []const []const u8) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const r = try w.runWith(args, .{ .raw_diagnostics = true, .cwd = .inherit });
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

test "ownership words: flipping the browser platforms' words is noticed" {
    try expectFlips("ownership/WordsBrowser.beni", &.{ "--platform=browser-tea", "--ownership-everywhere" });
}

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
/// names, to its closing `;`). Whitespace runs fold to one space, so a
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
                if (std.mem.startsWith(u8, line, sig_pub) or std.mem.startsWith(u8, line, sig)) in = true else continue;
            } else if (line.len != 0 and line[0] != ' ' and !std.mem.startsWith(u8, line, def)) break;
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

/// The budget of *ownership words: core's are catalogued*, in millions of
/// instructions: a grant of its own (CLAUDE.md, *Every test has a budget*),
/// decided by Jayson Reis on 2026-10-20 (dashboard question `node-log-q2`).
/// The test runs the ownership stage on the whole of `core/`, so its count
/// grows with every line of core: 4 270M of the gates' 4 300M on `master`
/// `ffc2fdb84`, and 4 310M once the log context (#358) landed, about 3 050M
/// of it in the ownership stage. The limit is that count plus about 10%. It
/// goes when the test is back under 4 300M: issue #514.
const core_surface_budget_millions = 4_750;

fn expectCoreSurface() !void {
    try expectSurface("core", &.{ "dump", "--stage=ownership", "core" });
}

test "ownership words: core's are catalogued" {
    try world.withOwnBudget("the core surface test", core_surface_budget_millions, expectCoreSurface);
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

test "ownership words: browser-tea and browser-inline carry none" {
    try expectSurface("browser-tea", &.{ "dump", "--stage=ownership", "--platform=browser-tea", "platforms/browser-tea" });
    try expectSurface("browser-inline", &.{ "dump", "--stage=ownership", "--platform=browser-inline", "platforms/browser-inline" });
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

test "ownership everywhere: core holds no rejected or pending line" {
    try expectPlatformClean(&.{ "dump", "--stage=ownership", "--ownership-totals", "--ownership-everywhere", "core" });
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

test "ownership everywhere: the browser-tea platform holds no rejected or pending line" {
    try expectPlatformClean(&.{ "dump", "--stage=ownership", "--ownership-totals", "--ownership-everywhere", "--platform=browser-tea", "platforms/browser-tea" });
}

test "ownership everywhere: Page.sandbox gets the direct entry row" {
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
    const report = try w.runWith(&.{ "dump", "--stage=ownership", page, "--ownership-everywhere", main }, .{ .raw_diagnostics = true, .cwd = .inherit });
    try testing.expect(std.mem.indexOf(u8, report.stdout, "entry Main.update model: accepted entry") != null);
}
