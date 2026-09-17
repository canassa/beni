//! `beni build` end to end (docs/design/backend.md §2, boundary.md §4–§5).
//!
//! Two boundaries in one file. Most scenarios are boundary 1 — the installed
//! binary against a temp project, asserting diagnostics and what landed on
//! disk — and the first one is boundary 2: compile, run the emitted
//! JavaScript under Node, assert what it printed. The `run/` corpus carries
//! the bulk of boundary 2; what is here is the scenarios that need more than
//! one file, or that assert something about the OUTPUT TREE rather than about
//! a program's answer.
//!
//! Nothing here imports a compiler internal: `std`, the harness and the
//! public diagnostic schema, which the build graph enforces.

const std = @import("std");
const diagnostic = @import("diagnostic");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

/// A platform package written by a user rather than shipped in the box —
/// boundary.md §2's whole point, that privilege is a role anyone may take
/// and not an author list. Written into the project by the scenarios that
/// need one.
fn writeUserPlatform(w: *World) !void {
    try w.write("myplat/beni.json",
        \\{ "platform": true, "name": "mine", "program": "Prog.Program", "runtime": "run.js" }
    );
    try w.write("myplat/Prog.beni",
        \\pub foreign type Program
        \\
        \\
        \\pub foreign say : String -> Program
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

test "a program computes something and prints the right answer" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import List
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (List.sum (List.range 1 10)))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.buildAndRun(&.{"Main.beni"});

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r.build);
    const program = r.program orelse return error.NothingRan;
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("55\n", program.stdout);
    try testing.expectEqualStrings("", program.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // One `.mjs` per source module, mirroring the source tree, packages in
    // directories of their own, plus each sibling next to its module and the
    // platform's runtime (backend.md §5, boundary.md §5.2).
    for ([_][]const u8{
        "out/Main.mjs",
        "out/main.mjs",
        "out/core/Basics.mjs",
        "out/core/Basics.foreign.mjs",
        "out/core/List.mjs",
        "out/core/List.foreign.mjs",
        "out/core/Dict/Int.mjs",
        "out/platform/Node.mjs",
        "out/platform/Node.foreign.mjs",
        "out/platform/runtime.foreign.mjs",
    }) |path| {
        if (!w.exists(path)) {
            std.debug.print("expected {s} to exist\n", .{path});
            return error.MissingOutput;
        }
    }
    try expectEveryFileIsEsm(&w, "out");
}

test "every emitted file is .mjs, the hand-written ones included" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // backend.md §2: "File extension is `.mjs`, so nothing depends on a
    // `package.json` the user owns." A sibling copied out as `.js` is an ES
    // module with no module type declared, so Node reparses it and warns —
    // MODULE_TYPELESS_PACKAGE_JSON, whose own remedy is "add `type: module`
    // to package.json", which is exactly the dependency the rule forbids.
    // The claim is about the WHOLE tree, so the assertion walks it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("Main.beni",
        \\import List
        \\import Prog exposing (Program)
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say (String.fromInt (List.sum (List.range 1 4)))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=myplat", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);
    const program = try w.node(world.entry_file);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Node warns on stderr, it does not fail — so a stray `.js` would pass
    // an exit-code assertion. Both halves are checked: the tree has no `.js`
    // in it, and running the program says nothing at all.
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("10!\n", program.stdout);
    try testing.expectEqualStrings("", program.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectEveryFileIsEsm(&w, "out");
}

test "a non-zero exit code from the platform reaches the process" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The Node platform is "worker-shaped, plus an exit code"
    // (boundary.md §5.3). A program that says it failed has to fail: the
    // `run/` corpus asserts stdout for programs that exit 0, and this is
    // the other half.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.exitWith "could not read the file" 3
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.buildAndRun(&.{"Main.beni"});

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r.build);
    const program = r.program orelse return error.NothingRan;
    try testing.expectEqual(@as(u8, 3), program.exit_code);
    try testing.expectEqualStrings("could not read the file\n", program.stdout);
    try testing.expectEqualStrings("", program.stderr);
}

test "a build is byte-identical at every --jobs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\type Colour
        \\    = Red
        \\    | Blue
        \\
        \\
        \\name : Colour -> String
        \\name c =
        \\    case c of
        \\        Red ->
        \\            "red"
        \\
        \\        Blue ->
        \\            "blue"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (name Red ++ name Blue)
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const one = try w.runWith(&.{ "build", "--platform=node", "--out=one", "--jobs=1", "Main.beni" }, .{ .raw_diagnostics = true });
    const many = try w.runWith(&.{ "build", "--platform=node", "--out=many", "--jobs=8", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(one);
    try expectBuilt(many);
    for ([_][]const u8{ "Main.mjs", "main.mjs", "core/List.mjs", "platform/Node.mjs" }) |name| {
        const a = try w.read(try std.fmt.allocPrint(w.arena.allocator(), "one/{s}", .{name}));
        const b = try w.read(try std.fmt.allocPrint(w.arena.allocator(), "many/{s}", .{name}));
        try testing.expectEqualStrings(a, b);
    }
}

test "a saturated n-ary call emits a direct JavaScript call" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §6: there is no calling convention. A 2-ary beni call
    // emits `f(a, b)` — no adapter, no arity tag, no call-site curry
    // wrapper — and a function used as a VALUE is the binding itself.
    // `tests/corpus/run/SaturatedCalls.beni` is the other half of this
    // assertion: that the emitted program behaves.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\add : Int, Int -> Int
        \\add a b =
        \\    a + b
        \\
        \\
        \\apply : (Int, Int -> Int), Int, Int -> Int
        \\apply f a b =
        \\    f a b
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (apply add 20 22))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=node", "--out=out", "--root=src", "src" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);
    const program = try w.node(world.entry_file);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("42\n", program.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    const main_mjs = try w.read("out/Main.mjs");
    // The 2-ary definition is a 2-ary function expression, the call through
    // a parameter passes both arguments at once, and `add` handed on as a
    // value is the bare name.
    try testing.expect(std.mem.indexOf(u8, main_mjs, "(a$1, b$2) =>") != null);
    try testing.expect(std.mem.indexOf(u8, main_mjs, "f$1(a$2, b$3)") != null);
    try testing.expect(std.mem.indexOf(u8, main_mjs, "Main$apply(Main$add, 20, 22)") != null);
    // Nothing anywhere in the build curries: no `(x) => (y) =>` chain, and
    // no call of a call one argument at a time.
    try testing.expect(std.mem.indexOf(u8, main_mjs, ") => (") == null);
}

test "modules import each other through ESM, and the program runs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Geometry/Area.beni",
        \\pub type Shape
        \\    = Square Int
        \\
        \\
        \\pub areaOf : Shape -> Int
        \\areaOf shape =
        \\    case shape of
        \\        Square side ->
        \\            side * side
        \\
    );
    try w.write("src/Main.beni",
        \\import Geometry.Area as Area exposing (Shape)
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (Area.areaOf (Area.Square 7)))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=node", "--out=out", "--root=src", "src" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);
    const program = try w.node(world.entry_file);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("49\n", program.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The importing module is one directory deep, so its specifier for a
    // sibling module climbs out of it.
    const main_mjs = try w.read("out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, main_mjs, "from \"./Geometry/Area.mjs\"") != null);
    const area_mjs = try w.read("out/Geometry/Area.mjs");
    try testing.expect(std.mem.indexOf(u8, area_mjs, "from \"../core/Basics.mjs\"") != null);
}

test "a platform anyone may publish: a package that declares itself one in its manifest" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // boundary.md §2: privilege is a manifest key and a checked contract,
    // not an author list. Nothing about this platform is in the compiler.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
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
    const built = try w.runWith(&.{ "build", "--platform=myplat", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);
    const program = try w.node(world.entry_file);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("hello!\n", program.stdout);
}

test "an app package may declare itself a platform, and then `foreign` is legal in it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Prim.beni", "pub foreign double : Int -> Int\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const ordinary = try w.run(&.{ "check", "Prim.beni" });
    try w.write("beni.json",
        \\{ "platform": true, "name": "mine" }
    );
    const privileged = try w.run(&.{ "check", "Prim.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), ordinary.exit_code);
    try testing.expectEqual(@as(usize, 1), ordinary.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .foreign_outside_platform,
        .severity = .@"error",
        .span = .{ .file = "Prim.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 19 } },
        .title = "FOREIGN OUTSIDE PLATFORM",
        .message = "This `foreign` declaration is outside a platform package.\n" ++
            "\n" ++
            "`foreign` declares a value or type implemented in JavaScript. It is legal in the\n" ++
            "core package and in a package whose manifest says `\"platform\": true`\n" ++
            "(`docs/design/boundary.md` §2), and nowhere else. Write the definition in beni,\n" ++
            "or move it into a platform package of your own.",
    }, ordinary.diagnostics[0]);
    try testing.expectEqual(@as(u8, 0), privileged.exit_code);
    try testing.expectEqualStrings("", privileged.stderr);
}

test "check 2: the sibling file must export exactly the declared names" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say "hello"
        \\
    );
    // One declared name missing, and one export nobody declared.
    try w.write("myplat/Prog.beni",
        \\pub foreign type Program
        \\
        \\
        \\pub foreign say : String -> Program
        \\
        \\
        \\pub foreign shout : String -> Program
        \\
    );
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ text: line });
        \\export const whisper = (line) => ({ text: line });
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "build", "--platform=myplat", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 2), r.diagnostics.len);
    for (r.diagnostics) |d| {
        try testing.expectEqual(diagnostic.Code.foreign_export_mismatch, d.code);
        try testing.expectEqualStrings("FOREIGN EXPORT MISMATCH", d.title);
        try testing.expectEqualStrings("myplat/Prog.beni", d.span.file);
    }
    // Diagnostics are sorted by position, and the two declarations are on
    // different lines, so the pair is asserted as a set.
    var missing = false;
    var extra = false;
    for (r.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "does not export `shout`") != null) missing = true;
        if (std.mem.indexOf(u8, d.message, "exports `whisper`") != null) extra = true;
    }
    try testing.expect(missing);
    try testing.expect(extra);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "check 3: a sibling file may not reach a name it never imported" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // boundary.md §7.1: one export per foreign value is one graph node per
    // foreign value, and what recovers the DEPENDENCY half is the file's own
    // imports. A name from nowhere is an edge the compiler cannot see.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ text: line + process.pid });
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
    const r = try w.run(&.{ "build", "--platform=myplat", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.foreign_unbound_reference, r.diagnostics[0].code);
    try testing.expectEqualStrings("UNBOUND JAVASCRIPT REFERENCE", r.diagnostics[0].title);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "uses `process`") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "a sibling that imports another file is refused, not silently broken" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A sibling is renamed as it is copied out (backend.md §2 wants every
    // emitted file to be `.mjs`), so `./Other.js` written against the source
    // name would point at nothing once copied. A build that succeeded and
    // produced a program that cannot load is the worst of both.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/Prog.js",
        \\import { helper } from "./helper.js";
        \\
        \\export const say = (line) => ({ text: helper(line) });
        \\
    );
    try w.write("myplat/helper.js", "export const helper = (s) => s;\n");
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
    const r = try w.run(&.{ "build", "--platform=myplat", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.not_implemented, r.diagnostics[0].code);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "\"./helper.js\"") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "a sibling may import a package, because the copy does not touch a bare specifier" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // This is also boundary.md §4's check 3 working as designed: the
    // platform's runtime reaches `process` and says where it comes from.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/Prog.js",
        \\import process from "node:process";
        \\
        \\export const say = (line) => ({ text: `${line} on ${process.platform.length > 0 ? "a host" : "nothing"}` });
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
    const built = try w.runWith(&.{ "build", "--platform=myplat", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);
    const program = try w.node(world.entry_file);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("hello on a host!\n", program.stdout);
    try testing.expectEqualStrings("", program.stderr);
    try expectEveryFileIsEsm(&w, "out");
}

test "the sibling file must exist at all" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("beni.json",
        \\{ "platform": true }
    );
    try w.write("Extra.beni", "pub foreign helper : Int -> Int\n");
    try w.write("Main.beni",
        \\import Extra
        \\import Prog exposing (Program)
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say (String.fromInt (Extra.helper 1))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "build", "--platform=myplat", "--out=out", "Extra.beni", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.foreign_sibling_missing, r.diagnostics[0].code);
    try testing.expectEqualStrings("MISSING JAVASCRIPT FILE", r.diagnostics[0].title);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "Extra.js") != null);
    try testing.expect(!w.exists("out"));
}

test "check 1: a foreign value must be a function or a concrete value" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("beni.json",
        \\{ "platform": true }
    );
    try w.write("Bad.beni", "pub foreign anything : a\n");
    try w.write("Bad.js", "export const anything = null;\n");
    try w.write("Main.beni",
        \\import Bad
        \\import Prog exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say Bad.anything
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "build", "--platform=myplat", "--out=out", "Bad.beni", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.foreign_bad_shape, r.diagnostics[0].code);
    try testing.expectEqualStrings("BAD FOREIGN TYPE", r.diagnostics[0].title);
    try testing.expect(!w.exists("out"));
}

test "a concrete foreign constant is allowed, because core's own `pi` is one" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // boundary.md §4 says all 65 of core's foreign values are shape (a), "a
    // total pure function". `Basics.e` and `Basics.pi` are not functions, so
    // the rule as written rejects core. What the compiler enforces is the
    // property it can actually check: no type variables.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("beni.json",
        \\{ "platform": true }
    );
    try w.write("Tau.beni", "pub foreign tau : Float\n");
    try w.write("Tau.js", "export const tau = 6.283185307179586;\n");
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\import String
        \\import Tau
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say (String.fromFloat Tau.tau)
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=myplat", "--out=out", "Main.beni", "Tau.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);
    const program = try w.node(world.entry_file);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("6.283185307179586!\n", program.stdout);
}

test "`main` is resolved per platform: it must exist and have the platform's Program type" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try w.write("Main.beni", "pub x : Int\nx =\n    1\n");
    const absent = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    try w.write("Main.beni", "main : Int\nmain =\n    1\n");
    const wrong = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    try w.write("Main.beni", "import Node\n\n\nmain =\n    Node.print \"x\"\n");
    const unannotated = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), absent.exit_code);
    try testing.expectEqual(@as(usize, 1), absent.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.missing_main, absent.diagnostics[0].code);
    try testing.expect(std.mem.indexOf(u8, absent.diagnostics[0].message, "Node.Program") != null);

    try testing.expectEqual(@as(u8, 1), wrong.exit_code);
    try testing.expectEqual(@as(usize, 1), wrong.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.main_not_program, wrong.diagnostics[0].code);
    try testing.expect(std.mem.indexOf(u8, wrong.diagnostics[0].message, "Basics.Int") != null);

    try testing.expectEqual(@as(u8, 1), unannotated.exit_code);
    try testing.expectEqual(@as(usize, 1), unannotated.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.main_not_program, unannotated.diagnostics[0].code);
    try testing.expect(std.mem.indexOf(u8, unannotated.diagnostics[0].message, "needs a type annotation") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "`?` says it is not implemented rather than emitting the wrong program" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\parse : String -> Maybe Int
        \\parse text =
        \\    Just (String.toInt text? + 1)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print "x"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.not_implemented, r.diagnostics[0].code);
    try testing.expectEqualStrings("NOT IMPLEMENTED YET", r.diagnostics[0].title);
    try testing.expectEqualStrings("Main.beni", r.diagnostics[0].span.file);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The whole project checked clean, so core and the platform lowered
    // fine and only THIS module did not. Nothing is written even so: a
    // build that emitted the modules it could would leave an `out/` that
    // looks fresh and is missing the one thing the program needs.
    try testing.expect(!w.exists("out"));
}

test "a project that does not check writes nothing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
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
    const r = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.kind_mismatch, r.diagnostics[0].code);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Nothing is emitted until the whole project checks clean: a stale
    // `out/` that looks fresh is what a watch process would serve.
    try testing.expect(!w.exists("out"));
    try testing.expectEqualStrings("", r.stdout);
}

test "--release is refused rather than silently producing development output" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print "x"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=node", "--release", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings(
        "beni: --release is not implemented until M3c; this build would be development output\n",
        r.stderr,
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "--source-maps is accepted and changes nothing yet" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print "x"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const plain = try w.runWith(&.{ "build", "--platform=node", "--out=plain", "Main.beni" }, .{ .raw_diagnostics = true });
    const mapped = try w.runWith(&.{ "build", "--platform=node", "--out=mapped", "--source-maps", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(plain);
    try expectBuilt(mapped);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Positions ride in the IR from M3a (§9.6); the encoder is later, and
    // saying so is better than writing an empty `.map`.
    try testing.expectEqualStrings(try w.read("plain/Main.mjs"), try w.read("mapped/Main.mjs"));
    try testing.expect(!w.exists("mapped/Main.mjs.map"));
}

test "an unknown platform is a usage failure that names the ones that ship" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "pub x : Int\nx =\n    1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=zx-spectrum", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "unknown platform 'zx-spectrum'") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "node") != null);
    try testing.expect(!w.exists("out"));
}

test "a directory that is not a platform package says so" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/beni.json",
        \\{ "name": "mine", "program": "Prog.Program", "runtime": "run.js" }
    );
    try w.write("Main.beni", "pub x : Int\nx =\n    1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=myplat", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "is not a platform package") != null);
    try testing.expect(!w.exists("out"));
}

/// A build that succeeded: exit 0 and NOTHING on either stream.
///
/// `frontend.md` §1 gives stdout to the product and stderr to diagnostics
/// and nothing else. A build's product is the files it wrote, so there is no
/// stream left for a summary line — `check` sets the same precedent, and
/// what was written is a `--self-profile` counter instead.
fn expectBuilt(r: world.Result) !void {
    if (r.exit_code != 0) {
        std.debug.print("build failed ({d})\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ r.exit_code, r.stdout, r.stderr });
        return error.BuildFailed;
    }
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualStrings("", r.stderr);
}

/// Every file under `dir` is an ES module by extension. The whole tree, not
/// a list a test happens to name: the rule is about what a build may write
/// at all, so a new kind of output file has to satisfy it too.
fn expectEveryFileIsEsm(w: *World, dir: []const u8) !void {
    const files = try w.listFiles(dir);
    if (files.len == 0) {
        std.debug.print("{s} is empty, so the rule was checked against nothing\n", .{dir});
        return error.NoOutput;
    }
    for (files) |path| {
        if (std.mem.endsWith(u8, path, ".mjs")) continue;
        std.debug.print("{s}/{s} is not a .mjs file (backend.md §2)\n", .{ dir, path });
        return error.NotAnEsModule;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// The measurement harness (plans/static-dispatch-spike.md §7, §10).
//
// `bench/size.mjs`, `bench/runtime.mjs` and `bench/churn.sh` are instruments,
// and §10 asks that each be run on one tiny program here so the JSON and the
// table cannot rot unnoticed. These scenarios assert SHAPE — the keys are
// there, the numbers are numbers, the table has its rows — and never a
// value, because a byte count and a millisecond are properties of the
// machine, not of the compiler.
//
// Unlike every scenario above, these children keep the test process's
// environment: `churn.sh` is a POSIX shell script and cannot find `awk`
// without a `PATH`. `std.process.run` inherits it when no `environ_map` is
// given, and resolves `argv[0]` on it, which is also how `sh` is found.
// ─────────────────────────────────────────────────────────────────────────

const HarnessRun = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// Run one of the `bench/` scripts with the repository as the working
/// directory, which is where the build step leaves this process.
fn runHarness(w: *World, argv: []const []const u8) !HarnessRun {
    const arena = w.arena.allocator();
    const r = try std.process.run(w.gpa, w.io, .{
        .argv = argv,
        .cwd = .inherit,
        .stdout_limit = .limited(world.max_stream_bytes),
        .stderr_limit = .limited(world.max_stream_bytes),
    });
    defer w.gpa.free(r.stdout);
    defer w.gpa.free(r.stderr);
    return .{
        .exit_code = switch (r.term) {
            .exited => |code| code,
            else => 255,
        },
        .stdout = try arena.dupe(u8, r.stdout),
        .stderr = try arena.dupe(u8, r.stderr),
    };
}

/// The absolute path of the world's project directory. The harness scripts
/// take a corpus root as a flag and run from the repository, so a path
/// relative to the temporary project is no use to them.
fn projectPath(w: *World) ![]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try w.tmp.dir.realPath(w.io, &buffer);
    return w.arena.allocator().dupe(u8, buffer[0..len]);
}

/// The last non-empty line of `text`.
fn lastLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var last: []const u8 = "";
    while (it.next()) |line| {
        if (line.len != 0) last = line;
    }
    return last;
}

fn harnessFailed(name: []const u8, r: HarnessRun) error{HarnessFailed} {
    std.debug.print("{s} exited {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ name, r.exit_code, r.stdout, r.stderr });
    return error.HarnessFailed;
}

test "bench/size.mjs reports raw, gzip and brotli bytes per program, net of a floor, and a total" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Tiny.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt 7)
        \\
    );
    const node_exe = w.node_exe orelse return error.NodeNotOnPath;
    const arena = w.arena.allocator();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runHarness(&w, &.{
        node_exe,
        "bench/size.mjs",
        try std.fmt.allocPrint(arena, "--beni={s}", .{w.exe}),
        try std.fmt.allocPrint(arena, "--corpus={s}", .{try projectPath(&w)}),
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) return harnessFailed("bench/size.mjs", r);

    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\n"), '\n');
    const floor = try parseJson(SizeFloor, arena, it.next() orelse return error.NoOutput);
    // The floor is core plus the platform reached by a `main` that does
    // nothing: a real build, so every one of these is positive.
    try testing.expect(floor.floor);
    try testing.expect(floor.files > 0);
    try testing.expect(floor.raw_bytes > 0);
    try testing.expect(floor.gzip_bytes > 0);
    try testing.expect(floor.brotli_bytes > 0);

    const program = try parseJson(SizeProgram, arena, it.next() orelse return error.NoProgramLine);
    try testing.expect(std.mem.endsWith(u8, program.program, "Tiny.beni"));
    try testing.expect(program.files > 0);
    try testing.expect(program.gzip_bytes <= program.raw_bytes);
    try testing.expect(program.brotli_bytes <= program.raw_bytes);
    // Net is the subtraction the totals are built from, so it has to be
    // exactly that and not a second compression.
    try testing.expectEqual(program.raw_bytes - floor.raw_bytes, program.net_raw_bytes);
    try testing.expectEqual(program.gzip_bytes - floor.gzip_bytes, program.net_gzip_bytes);
    try testing.expectEqual(program.brotli_bytes - floor.brotli_bytes, program.net_brotli_bytes);
    // A program that prints one number adds bytes to the floor and does not
    // remove any: without DCE the floor is contained in every build.
    try testing.expect(program.net_raw_bytes > 0);
    // Nothing derives anything until the spike does (§7 M4).
    try testing.expectEqual(@as(u64, 0), program.derived_bytes);
    try testing.expectEqual(@as(u32, 0), program.derived_functions);

    const total = try parseJson(SizeTotal, arena, lastLine(r.stdout));
    try testing.expect(total.total);
    try testing.expectEqual(@as(u32, 1), total.programs);
    // The shared tree counted ONCE plus what the program adds, and the gross
    // sum kept beside it.
    try testing.expectEqual(floor.raw_bytes + program.net_raw_bytes, total.raw_bytes);
    try testing.expectEqual(floor.gzip_bytes + program.net_gzip_bytes, total.gzip_bytes);
    try testing.expectEqual(floor.brotli_bytes + program.net_brotli_bytes, total.brotli_bytes);
    try testing.expectEqual(program.raw_bytes, total.gross_raw_bytes);
    try testing.expectEqual(floor.raw_bytes, total.floor_raw_bytes);
}

test "bench/size.mjs counts a derived-shaped name and not core's hand-written one" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `derived_bytes` is the whole point of M4's "grows per type x method"
    // row, and it is 0 on every real corpus today, so a scenario that only
    // ever saw 0 would pass with the matcher deleted. A `pub eq` in a module
    // called `Foo` is emitted as `Foo$eq` — exactly the printed shape §8.5
    // gives a derived `eq` — and core's own `Basics$compare` is in the same
    // output tree and must NOT be counted.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Foo.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\pub eq : Int, Int -> Bool
        \\eq x y =
        \\    x == y
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt 7)
        \\
    );
    const node_exe = w.node_exe orelse return error.NodeNotOnPath;
    const arena = w.arena.allocator();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runHarness(&w, &.{
        node_exe,
        "bench/size.mjs",
        try std.fmt.allocPrint(arena, "--beni={s}", .{w.exe}),
        try std.fmt.allocPrint(arena, "--corpus={s}", .{try projectPath(&w)}),
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) return harnessFailed("bench/size.mjs", r);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\n"), '\n');
    _ = it.next(); // the floor
    const program = try parseJson(SizeProgram, arena, it.next() orelse return error.NoProgramLine);
    // Exactly one: `Foo$eq`. Two would mean `Basics$compare` was counted as
    // well, and zero would mean the matcher never fires.
    try testing.expectEqual(@as(u32, 1), program.derived_functions);
    try testing.expect(program.derived_bytes > 0);
    try testing.expect(program.derived_bytes < program.raw_bytes);
}

test "bench/size.mjs builds a root that declares no main behind a synthesised entry" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `bench/corpus` is a library, not a program: no module in it declares
    // `main : Program`, so `beni build` refuses it and the script has to
    // write an entry point of its own. That path is most of what M4 measures
    // on that corpus, and nothing else exercises it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Alpha.beni",
        \\pub double : Int -> Int
        \\double n =
        \\    n * 2
        \\
    );
    const node_exe = w.node_exe orelse return error.NodeNotOnPath;
    const arena = w.arena.allocator();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runHarness(&w, &.{
        node_exe,
        "bench/size.mjs",
        try std.fmt.allocPrint(arena, "--beni={s}", .{w.exe}),
        try std.fmt.allocPrint(arena, "--corpus={s}", .{try projectPath(&w)}),
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) return harnessFailed("bench/size.mjs", r);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\n"), '\n');
    _ = it.next(); // the floor
    const program = try parseJson(SizeSynthesised, arena, it.next() orelse return error.NoProgramLine);
    try testing.expectEqualStrings("BenchMain (synthesised)", program.entry);
    try testing.expectEqual(@as(u32, 1), program.modules_measured);
    try testing.expectEqual(@as(usize, 0), program.modules_excluded.len);
    // The module really is in the output, not merely imported and dropped:
    // there is no DCE, so an import is enough (§11).
    try testing.expect(program.net_raw_bytes > 0);
}

test "bench/runtime.mjs times a program against a beni floor, checks its answer and reports ns/op" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // The `-- ops:` header is what `ns_per_op` is divided by; a program
    // without one is an error, so the smoke test carries one.
    try w.write("c0/Tiny.beni",
        \\-- ops: 10
        \\import List
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (List.sum (List.range 1 10)))
        \\
    );
    const node_exe = w.node_exe orelse return error.NodeNotOnPath;
    const arena = w.arena.allocator();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runHarness(&w, &.{
        node_exe,
        "bench/runtime.mjs",
        try std.fmt.allocPrint(arena, "--beni={s}", .{w.exe}),
        try std.fmt.allocPrint(arena, "--dir={s}", .{try projectPath(&w)}),
        "--variant=c0",
        "--runs=2",
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) return harnessFailed("bench/runtime.mjs", r);
    const line = try parseJson(RuntimeLine, arena, lastLine(r.stdout));
    try testing.expectEqualStrings("Tiny", line.program);
    try testing.expectEqualStrings("c0", line.variant);
    try testing.expectEqual(@as(u32, 2), line.runs);
    try testing.expectEqual(@as(u64, 10), line.ops);
    try testing.expect(line.best_ms > 0);
    try testing.expect(line.median_ms >= line.best_ms);
    // The floor is a null beni PROGRAM, so it pays for the ESM load of core
    // and the platform as well as for starting Node. That is several
    // milliseconds, and it is what makes the subtraction meaningful.
    try testing.expect(line.floor_ms > 0);
    // `ns_per_op` is the printed pair divided by the printed op count, to a
    // tenth: the line is self-checking, and a floor that stopped being
    // subtracted would fail here rather than quietly inflate every number.
    const expected = @max(line.best_ms - line.floor_ms, 0) * 1e6 / @as(f64, @floatFromInt(line.ops));
    try testing.expectApproxEqAbs(@round(expected * 10) / 10, line.ns_per_op, 0.05);
    // The checksum is the program's own answer, which is how a run that got
    // faster by getting the wrong result fails instead of scoring.
    try testing.expectEqualStrings("55", line.checksum);
}

test "bench/churn.sh reports every edit class against both variants, counts a rejection, and restores the tree" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Two declarations, chosen so each column of the table has something in
    // it. `bump` takes every edit: an integer literal for E1, `n + 1` on a
    // parameter for E2, a parameter no `==` mentions for E3. `applyTwice`
    // takes a FUNCTION, so E3's `f == f` is `not_equatable` — a rejection,
    // which is the outcome `beni dump`'s exit code cannot see and which the
    // script therefore has to read out of the JSON diagnostics.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Tiny.beni",
        \\pub bump : Int -> Int
        \\bump n =
        \\    n + 1
        \\
        \\
        \\pub applyTwice : (Int -> Int), Int -> Int
        \\applyTwice f n =
        \\    f (f n)
        \\
    );
    const arena = w.arena.allocator();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runHarness(&w, &.{
        "sh",
        "bench/churn.sh",
        try std.fmt.allocPrint(arena, "--beni={s}", .{w.exe}),
        try std.fmt.allocPrint(arena, "--corpus={s}", .{try projectPath(&w)}),
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) return harnessFailed("bench/churn.sh", r);
    // The tree it churned is a copy; saying so is half the contract.
    try testing.expect(std.mem.indexOf(u8, r.stdout, "tree restored: yes") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "changed/accepted") != null);

    // Every class against both variants, and every row over both
    // declarations.
    for ([_][]const u8{ "E1", "E2", "E3", "E3poly" }) |klass| {
        for ([_][]const u8{ "annotated", "unannotated" }) |variant| {
            const row = try churnRow(r.stdout, klass, variant);
            try testing.expectEqual(@as(u32, 2), row.decls);
            try testing.expectEqual(row.applied + row.skipped, row.decls);
        }
    }

    // `f == f` on a function: refused by the checker, and counted as such.
    // Before the JSON classification this scored as a successful,
    // interface-preserving edit.
    const e3 = try churnRow(r.stdout, "E3", "annotated");
    try testing.expectEqual(@as(u32, 1), e3.rejected);
    try testing.expectEqual(@as(u32, 2), e3.applied);
    // Neither parameter is annotated with a bare type variable, so the
    // polymorphic row has nothing to say about this module.
    const poly = try churnRow(r.stdout, "E3poly", "annotated");
    try testing.expectEqual(@as(u32, 2), poly.skipped);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The corpus it was pointed at is byte-identical afterwards.
    try testing.expect(std.mem.indexOf(u8, try w.read("Tiny.beni"), "    n + 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, try w.read("Tiny.beni"), "always") == null);
}

const SizeFloor = struct {
    floor: bool,
    files: u32,
    raw_bytes: i64,
    gzip_bytes: i64,
    brotli_bytes: i64,
};

const SizeProgram = struct {
    program: []const u8,
    files: u32,
    raw_bytes: i64,
    gzip_bytes: i64,
    brotli_bytes: i64,
    net_raw_bytes: i64,
    net_gzip_bytes: i64,
    net_brotli_bytes: i64,
    derived_bytes: u64,
    derived_functions: u32,
};

const SizeSynthesised = struct {
    program: []const u8,
    entry: []const u8,
    modules_measured: u32,
    modules_excluded: []const []const u8,
    net_raw_bytes: i64,
};

const SizeTotal = struct {
    total: bool,
    programs: u32,
    raw_bytes: i64,
    gzip_bytes: i64,
    brotli_bytes: i64,
    floor_raw_bytes: i64,
    gross_raw_bytes: i64,
};

const RuntimeLine = struct {
    program: []const u8,
    variant: []const u8,
    runs: u32,
    ops: u64,
    floor_ms: f64,
    best_ms: f64,
    median_ms: f64,
    ns_per_op: f64,
    checksum: []const u8,
};

fn parseJson(comptime T: type, arena: std.mem.Allocator, line: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, line, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("not a {s} line ({t}): {s}\n", .{ @typeName(T), err, line });
        return error.NotJson;
    };
}

/// One row of `churn.sh`'s table:
///
///     E3poly  unannotated               4/4        7       96         3    103
const ChurnRow = struct { changed: u32, accepted: u32, applied: u32, skipped: u32, rejected: u32, decls: u32 };

fn churnRow(stdout: []const u8, klass: []const u8, variant: []const u8) !ChurnRow {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const first = fields.next() orelse continue;
        if (!std.mem.eql(u8, first, klass)) continue;
        const second = fields.next() orelse continue;
        if (!std.mem.eql(u8, second, variant)) continue;

        const fraction = fields.next() orelse return error.MalformedRow;
        const slash = std.mem.indexOfScalar(u8, fraction, '/') orelse return error.MalformedRow;
        return .{
            .changed = try std.fmt.parseInt(u32, fraction[0..slash], 10),
            .accepted = try std.fmt.parseInt(u32, fraction[slash + 1 ..], 10),
            .applied = try std.fmt.parseInt(u32, fields.next() orelse return error.MalformedRow, 10),
            .skipped = try std.fmt.parseInt(u32, fields.next() orelse return error.MalformedRow, 10),
            .rejected = try std.fmt.parseInt(u32, fields.next() orelse return error.MalformedRow, 10),
            .decls = try std.fmt.parseInt(u32, fields.next() orelse return error.MalformedRow, 10),
        };
    }
    std.debug.print("no `{s} {s}` row in:\n{s}\n", .{ klass, variant, stdout });
    return error.MissingRow;
}
