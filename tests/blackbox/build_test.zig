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
        "out/_main.mjs",
        "out/_core/Basics.mjs",
        "out/_core/Basics.foreign.mjs",
        "out/_core/List.mjs",
        "out/_core/List.foreign.mjs",
        "out/_platform/Node.mjs",
        "out/_platform/Node.foreign.mjs",
        "out/_platform/runtime.foreign.mjs",
    }) |path| {
        if (!w.exists(path)) {
            std.debug.print("expected {s} to exist\n", .{path});
            return error.MissingOutput;
        }
    }
    try expectEveryFileIsEsm(&w, "out");
}

test "a module in a subdirectory comes out in a subdirectory of out/" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // backend.md §5, boundary.md §5.2: one `.mjs` per source module,
    // MIRRORING the source tree, because a module's name comes from its
    // path and `Util/Math.beni` is `Util.Math`.
    //
    // The assertion used to ride on core's own `Dict.Int`, which was
    // deleted with the comparator argument
    // (`docs/design/static-dispatch-spike.md` §5.7). The claim is about the
    // emitter and not about core, so the test owns its nested module now —
    // and it also gets a proper subject: an import ACROSS the subdirectory
    // boundary, which the old assertion never had, since nothing in the
    // project imported `Dict.Int`.
    //
    // It is a RELOCATION and not a fail-first pin: no defect of this slice
    // is caught here, and nothing in it failed before the slice — every
    // S6b defect is pinned by a fixture under `tests/corpus/dispatch/` or
    // `tests/corpus/run/` instead.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Util/Math.beni",
        \\pub double : Int -> Int
        \\double n =
        \\    n * 2
        \\
    );
    try w.write("src/Main.beni",
        \\import Node exposing (Program)
        \\import String
        \\import Util.Math
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (Util.Math.double 21))
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
    for ([_][]const u8{ "out/Main.mjs", "out/Util/Math.mjs" }) |path| {
        if (!w.exists(path)) {
            std.debug.print("expected {s} to exist\n", .{path});
            return error.MissingOutput;
        }
    }
    // The importer reaches it down a relative specifier, not a bare one.
    const main_mjs = try w.read("out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, main_mjs, "./Util/Math.mjs") != null);
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
    // The `--release` pair (`backend.md` §9's *Testing*): renaming assigns
    // from a counter in emission order, so a name that came from completion
    // order instead would move here and nowhere else.
    const one_r = try w.runWith(&.{ "build", "--platform=node", "--release", "--out=one-rel", "--jobs=1", "Main.beni" }, .{ .raw_diagnostics = true });
    const many_r = try w.runWith(&.{ "build", "--platform=node", "--release", "--out=many-rel", "--jobs=8", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(one);
    try expectBuilt(many);
    try expectBuilt(one_r);
    try expectBuilt(many_r);
    try expectSameTree(&w, "one-rel", "many-rel");
    // The WHOLE tree, file for file, rather than a hand-written list of
    // four names. Elimination (`backend.md` §9) decides which modules a
    // build writes at all, so a fixed list either names a file that is no
    // longer there — `core/List.mjs` was, until this program stopped
    // reaching it — or quietly stops covering the ones that are. The set of
    // paths is itself part of what must not move with `--jobs`.
    const written = try treeOf(&w, "one");
    try testing.expectEqualDeep(written, try treeOf(&w, "many"));
    try testing.expect(written.len >= 4);
    for (written) |name| {
        const a = try w.read(try std.fmt.allocPrint(w.arena.allocator(), "one/{s}", .{name}));
        const b = try w.read(try std.fmt.allocPrint(w.arena.allocator(), "many/{s}", .{name}));
        try testing.expectEqualStrings(a, b);
    }
}

/// Two output trees must hold the same paths and the same bytes. The WHOLE
/// tree, not a chosen list: the set of paths is itself part of what must not
/// move (CLAUDE.md rule 5).
fn expectSameTree(w: *World, a_dir: []const u8, b_dir: []const u8) !void {
    const arena = w.arena.allocator();
    const written = try treeOf(w, a_dir);
    try testing.expectEqualDeep(written, try treeOf(w, b_dir));
    try testing.expect(written.len >= 4);
    for (written) |name| {
        const a = try w.read(try std.fmt.allocPrint(arena, "{s}/{s}", .{ a_dir, name }));
        const b = try w.read(try std.fmt.allocPrint(arena, "{s}/{s}", .{ b_dir, name }));
        try testing.expectEqualStrings(a, b);
    }
}

/// Every file under one output directory of the world, as sorted paths
/// relative to it.
fn treeOf(w: *World, out_dir: []const u8) ![]const []const u8 {
    const arena = w.arena.allocator();
    var dir = try w.tmp.dir.openDir(testing.io, out_dir, .{ .iterate = true });
    defer dir.close(testing.io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (try walker.next(testing.io)) |entry| {
        if (entry.kind != .file) continue;
        try out.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return out.items;
}

test "a build with cross-module evidence is byte-identical at every --jobs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // CLAUDE.md rule 5 and static-dispatch-spike.md §10, applied to the
    // half S4 adds: the arguments a call passes are now a function of what
    // the CHECKER decided, and the checker runs the module DAG in parallel.
    // A site resolved against a module that happened to finish first, an
    // evidence order taken from variable identity rather than from the
    // scheme record (§7.2), or a `needed` import list built in completion
    // order would all show up here and nowhere else — the emitted bytes
    // would move with `--jobs` while every other test stayed green.
    //
    // Three modules and two edges of evidence: `Main.twice` is constrained,
    // `Boxes.scale` answers it and is constrained ITSELF, and `Metres.scale`
    // answers that — so the call in `grow` passes an eta-expanded closure
    // whose own argument comes from a third module (§8.2, A.25).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Metres.beni",
        \\pub type Metre
        \\    = Metre Int
        \\
        \\
        \\pub scale : Metre, Int -> Metre
        \\scale m factor =
        \\    case m of
        \\        Metre n ->
        \\            Metre (n * factor)
        \\
    );
    try w.write("src/Boxes.beni",
        \\pub type Box a
        \\    = Box a
        \\
        \\
        \\pub scale : Box a, Int -> Box a
        \\    where a.scale : a, Int -> a
        \\scale b factor =
        \\    case b of
        \\        Box inner ->
        \\            Box (inner.scale factor)
        \\
    );
    try w.write("src/Main.beni",
        \\import Boxes exposing (Box)
        \\import Metres exposing (Metre)
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\twice : a, Int -> a
        \\    where a.scale : a, Int -> a
        \\twice x factor =
        \\    (x.scale factor).scale factor
        \\
        \\
        \\grow : Box Metre -> Box Metre
        \\grow b =
        \\    twice b 2
        \\
        \\
        \\width : Box Metre -> Int
        \\width b =
        \\    case b of
        \\        Boxes.Box m ->
        \\            case m of
        \\                Metres.Metre n ->
        \\                    n
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (width (grow (Boxes.Box (Metres.Metre 3)))))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const one = try w.runWith(&.{ "build", "--platform=node", "--out=one", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    const many = try w.runWith(&.{ "build", "--platform=node", "--out=many", "--jobs=8", "src" }, .{ .raw_diagnostics = true });
    // The `--release` pair (`backend.md` §9's *Testing*). This is the
    // scenario that matters most for renaming: the whole-program namespace
    // has to give `Boxes$scale` the same short name in the module that
    // declares it and in the two that import it, whatever order the checker
    // finished those modules in.
    const one_r = try w.runWith(&.{ "build", "--platform=node", "--release", "--out=one-rel", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    const many_r = try w.runWith(&.{ "build", "--platform=node", "--release", "--out=many-rel", "--jobs=8", "src" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(one);
    try expectBuilt(many);
    try expectBuilt(one_r);
    try expectBuilt(many_r);
    try expectSameTree(&w, "one-rel", "many-rel");
    const release_program = try w.node("one-rel/_main.mjs");
    try testing.expectEqual(@as(u8, 0), release_program.exit_code);
    try testing.expectEqualStrings("12\n", release_program.stdout);
    // Every file, not a chosen few: the point is that NOTHING moved, and a
    // list of names is a list of the places somebody thought to look.
    const files = try w.listFiles("one");
    try testing.expect(files.len != 0);
    var saw_evidence = false;
    for (files) |name| {
        const a = try w.read(try std.fmt.allocPrint(w.arena.allocator(), "one/{s}", .{name}));
        const b = try w.read(try std.fmt.allocPrint(w.arena.allocator(), "many/{s}", .{name}));
        const a_hex = digest(a);
        const b_hex = digest(b);
        try testing.expectEqualStrings(&a_hex, &b_hex);
        if (std.mem.indexOf(u8, a, "$m$0") != null) saw_evidence = true;
    }
    // The build really does carry evidence, so a green run means the bytes
    // matched rather than that there was nothing to match.
    try testing.expect(saw_evidence);
    const main_js = try w.read("one/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, main_js, "Main$twice(($p") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY STATE                            │
    // └─────────────────────────────────────────┘
    const program = try w.node("one/_main.mjs");
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("12\n", program.stdout);
}

/// The SHA-256 of `bytes`, hex, in a per-call buffer.
fn digest(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&raw}) catch unreachable;
    return hex;
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
    try testing.expect(std.mem.indexOf(u8, area_mjs, "from \"../_core/Basics.mjs\"") != null);
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

test "a user module may be called `Core.List` or `Platform.Node`, because the reserved directories begin with `_`" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // backend.md §2, rule 1: `_core/` and `_platform/` are names no module
    // path can reach, because every segment of a module name is an upper
    // identifier. They used to be `core/` and `platform/`, which `Core.List`
    // and `Platform.Node` land on exactly — two files on Linux and ONE on
    // macOS, where core's `List` and the app's would overwrite each other.
    // The proof is the program running with BOTH in it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Core/List.beni",
        \\pub twice : Int -> Int
        \\twice n =
        \\    n * 2
        \\
    );
    try w.write("src/Platform/Node.beni",
        \\pub thrice : Int -> Int
        \\thrice n =
        \\    n * 3
        \\
    );
    try w.write("src/Main.beni",
        \\import Core.List
        \\import List
        \\import Node exposing (Program)
        \\import Platform.Node
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (Core.List.twice (Platform.Node.thrice (List.sum (List.range 1 3)))))
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
    // 1 + 2 + 3 = 6, thrice 18, twice 36. A `Core.List` that had overwritten
    // core's own `List` could not have produced it.
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("36\n", program.stdout);
    try testing.expectEqualStrings("", program.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Four distinct files, and they stay distinct when the names are folded
    // — which `world.runWith` has already asserted over the whole tree.
    for ([_][]const u8{
        "out/Core/List.mjs",
        "out/Platform/Node.mjs",
        "out/_core/List.mjs",
        "out/_platform/Node.mjs",
    }) |path| {
        if (!w.exists(path)) {
            std.debug.print("expected {s} to exist\n", .{path});
            return error.MissingOutput;
        }
    }
}

test "a platform may declare the entry file's name, and that is what the build writes" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // boundary.md §5.2: the entry file's NAME is part of the output shape a
    // platform declares, and it was the one part the emitter still
    // hardcoded. `"entry"` finishes the key set — subject to backend.md §2's
    // rule 1, which is the next test.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/beni.json",
        \\{ "platform": true, "name": "mine", "program": "Prog.Program", "runtime": "run.js", "entry": "_start.mjs" }
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
    const program = try w.node("out/_start.mjs");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("hello!\n", program.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The default name is not written as well: a platform declares ONE
    // entry file.
    try testing.expect(!w.exists("out/_main.mjs"));
}

test "a declared entry file name that a module could take is refused" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // boundary.md §5.2: moving the name into the manifest is not on its own
    // the fix, because a platform could declare `main.mjs` and put back the
    // collision with the module `Main` that rule 1 exists to make
    // unreachable. So the declared name is checked, and `Index.mjs` — which
    // has no leading `_` — is refused for the same reason `main.mjs` is.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/beni.json",
        \\{ "platform": true, "name": "mine", "program": "Prog.Program", "runtime": "run.js", "entry": "Index.mjs" }
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
    const built = try w.run(&.{ "build", "--platform=myplat", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), built.exit_code);
    try testing.expectEqual(@as(usize, 1), built.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .invalid_entry_file,
        .severity = .@"error",
        .span = .{ .file = "myplat/beni.json", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
        .title = "INVALID ENTRY FILE NAME",
        .message = "This platform declares its entry file as `Index.mjs`, which is a name a module\n" ++
            "could take.\n" ++
            "\n" ++
            "A module is named by its path and every segment is an upper identifier\n" ++
            "(`docs/design/language.md` §5), so a name beginning with `_` is one no module\n" ++
            "can ever occupy — on macOS and Windows included, where `Index.mjs` and a module\n" ++
            "`Index`'s own file are one and the same. An entry file name is one path segment,\n" ++
            "begins with `_`, ends in `.mjs`, and has ASCII letters, digits, `_` or `-`\n" ++
            "between (`docs/design/boundary.md` §5.2).",
    }, built.diagnostics[0]);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
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
    }
    // **The two arms point at different files** (`boundary.md` §4, check 2,
    // *a diagnostic points at the file whose text is wrong*). A declaration
    // with no export is a promise the `.beni` made and did not keep, so the
    // caret is there; an export nothing declares is the `.js` file's own
    // surplus, so the caret is THERE, under the name. Both used to land on
    // `Prog.beni`, the second of them on whichever `foreign` came first —
    // an arbitrary line with nothing to do with `whisper`.
    var missing = false;
    var extra = false;
    for (r.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "does not export `shout`") != null) {
            missing = true;
            try testing.expectEqualStrings("myplat/Prog.beni", d.span.file);
        }
        if (std.mem.indexOf(u8, d.message, "exports `whisper`") != null) {
            extra = true;
            try testing.expectEqualStrings("myplat/Prog.js", d.span.file);
            // Line 2, column 14: under `whisper` itself.
            try testing.expectEqual(@as(u32, 2), d.span.start.line);
            try testing.expectEqual(@as(u32, 14), d.span.start.col);
        }
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
    // **The caret is in the `.js`** (`boundary.md` §4): line 1, column 46,
    // under `process` itself. It used to be on `Prog.beni`'s first
    // `foreign`, an arbitrary declaration with nothing to do with the fault.
    try testing.expectEqualStrings("myplat/Prog.js", r.diagnostics[0].span.file);
    try testing.expectEqual(@as(u32, 1), r.diagnostics[0].span.start.line);
    try testing.expectEqual(@as(u32, 46), r.diagnostics[0].span.start.col);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "a fault in a PACKAGE sibling names that package's file, with its own excerpt" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `boundary.md` §4's rule is that a diagnostic points at the file whose
    // text is wrong — including a file the user never wrote and the
    // `SourceStore` does not hold. Core's siblings are the case: they are
    // ASSETS, carried in the binary or, as here, read from `--core-root`,
    // and the renderer's excerpt lookup only knows beni sources. A fault in
    // one used to land on a `foreign` declaration in the `.beni` beside it.
    //
    // `--core-root` is what makes this reachable at all: the copy embedded
    // in the compiler is checked clean by `js/Sibling.zig`'s own test over
    // `core_package.assets`, so a broken embedded sibling cannot be built
    // from a test. The only difference between the two is which branch of
    // `Emit.readAsset` produced the bytes; everything after it — the
    // scanner's offsets, the position, the excerpt — is the same code on
    // the same bytes.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("mycore/Basics.beni", "pub equatable foreign type Int\n\n\npub type Bool\n    = True\n    | False\n");
    try w.write("mycore/Basics.js", "export {};\n");
    try w.write("mycore/String.beni", "pub equatable foreign type String\n");
    try w.write("mycore/String.js", "export {};\n");
    try w.write("mycore/List.beni", "pub equatable foreign type List a\n\n\npub foreign length : List a -> Int\n");
    try w.write("mycore/List.js", "export const length = (xs) => xs.length + process.pid;\n");
    try writeUserPlatform(&w);
    try w.write("Main.beni", "pub x : Int\nx =\n    1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(
        &.{ "check", "--core-root=mycore", "--platform=myplat", "Main.beni" },
        .{ .raw_diagnostics = true },
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    // The whole rendering, because the excerpt is the point: the header
    // names the `.js`, and the line under it is that file's own text.
    try testing.expectEqualStrings(
        "-- UNBOUND JAVASCRIPT REFERENCE ---------------------------- mycore/List.js:1:43\n" ++
            "\n" ++
            "This file uses `process`, which it never imports.\n" ++
            "\n" ++
            "A sibling file's references have to be covered by its own `import`\n" ++
            "statements (`docs/design/boundary.md` §4, check 3). That is what keeps dead\n" ++
            "code elimination declaration-granular: the compiler reads the imports to\n" ++
            "learn the file's dependencies, and a name that comes from nowhere is an edge\n" ++
            "it cannot see. Write `import process from \"node:process\";` — or whatever module\n" ++
            "really provides it — at the top of this file.\n" ++
            "\n" ++
            "1|export const length = (xs) => xs.length + process.pid;\n" ++
            "                                            ^^^^^^^\n",
        r.stderr,
    );
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

test "check 4: a constrained foreign whose sibling forgot the evidence parameter" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The defect this check was added for (boundary.md §4 check 4,
    // static-dispatch-spike.md §5.2, A.84). A `pub foreign` with a `where`
    // clause takes its evidence parameters FIRST, and nothing used to count
    // them: this project used to build, exit 0, and then compare the
    // evidence function against a list at run time.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/Prog.beni",
        \\pub foreign type Program
        \\
        \\
        \\pub foreign say : String -> Program
        \\
        \\
        \\pub foreign allEq : List a, List a -> Bool
        \\    where a.eq : a, a -> Bool
        \\
    );
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ text: line });
        \\
        \\export const allEq = (xs, ys) => xs.$ === ys.$;
        \\
    );
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    if Prog.allEq [ 1, 2 ] [ 1, 2 ] then
        \\        Prog.say "same"
        \\
        \\    else
        \\        Prog.say "different"
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
    const d = r.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.foreign_arity_mismatch, d.code);
    try testing.expectEqualStrings("FOREIGN ARITY MISMATCH", d.title);
    // The span is the DECLARATION, not the module: the beni side is where
    // the expected count is written down.
    try testing.expectEqualStrings("myplat/Prog.beni", d.span.file);
    try testing.expect(std.mem.indexOf(u8, d.message, "with 2 parameters, and `allEq` takes 3") != null);
    // The message has to say where the third one came from, because nothing
    // in the sibling shows it.
    try testing.expect(std.mem.indexOf(u8, d.message, "1 for the `where` clause") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "check 4: a foreign typed through an alias counts the alias's parameters, as its calls do" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // R2b's review, S2 (checker-v2.md §12.5, boundary.md §4 check 4 as
    // amended). `isPos : IntPred` spells no arrow, but `IntPred` IS
    // `Int -> Bool`, and every call of it is lowered by `Convention` as
    // `isPos(x)`. Check 4 used to read the annotation's spelling, call it a
    // VALUE, and refuse the one sibling that works, `(x) => …`, as "written
    // as a function". It now asks the same `Convention`: one parameter.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/Prog.beni",
        \\pub foreign type Program
        \\
        \\
        \\pub type alias IntPred =
        \\    Int -> Bool
        \\
        \\
        \\pub foreign say : String -> Program
        \\
        \\
        \\pub foreign isPos : IntPred
        \\
    );
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ text: line });
        \\
        \\export const isPos = (x) => x > 0;
        \\
    );
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    if List.all [ 1, 2 ] Prog.isPos && not (Prog.isPos (0 - 3)) then
        \\        Prog.say "same"
        \\
        \\    else
        \\        Prog.say "different"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.run(&.{ "build", "--platform=myplat", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqual(@as(usize, 0), built.diagnostics.len);
    const ran = try w.node("out/_main.mjs");
    try testing.expectEqual(@as(u8, 0), ran.exit_code);
    try testing.expectEqualStrings("same!\n", ran.stdout);

    // And the count is the alias's: two parameters are one too many.
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ text: line });
        \\
        \\export const isPos = (x, y) => x > 0;
        \\
    );
    const wide = try w.run(&.{ "build", "--platform=myplat", "--out=out2", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), wide.exit_code);
    try testing.expectEqual(@as(usize, 1), wide.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.foreign_arity_mismatch, wide.diagnostics[0].code);
    try testing.expect(std.mem.indexOf(u8, wide.diagnostics[0].message, "with 2 parameters, and `isPos` takes 1") != null);
    try testing.expect(!w.exists("out2"));
}

test "check 4: a plain arity mismatch is the same defect and the same diagnostic" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // An unconstrained `foreign` is checked too: every emitted call is
    // saturated (backend.md §6), so a parameter that is never filled is the
    // same `undefined` arriving in the same place.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/Prog.beni",
        \\pub foreign type Program
        \\
        \\
        \\pub foreign say : String, String -> Program
        \\
    );
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ text: line });
        \\
    );
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say "hello" "world"
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
    try testing.expectEqual(diagnostic.Code.foreign_arity_mismatch, r.diagnostics[0].code);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "with 1 parameter, and `say` takes 2") != null);
    // No `where` clause, so no evidence paragraph.
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "`where` clause") == null);
    try testing.expect(!w.exists("out"));
}

test "check 4: a foreign that is not a function may not be written as one" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The other direction of the same rule. `foreign pi : Float` binds to a
    // VALUE (`core/Basics.js` writes `Math.PI`); a `() => …` would put a
    // function where the type says a number.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("beni.json",
        \\{ "platform": true }
    );
    try w.write("Tau.beni", "pub foreign tau : Float\n");
    try w.write("Tau.js", "export const tau = () => 6.283185307179586;\n");
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
    const r = try w.run(&.{ "build", "--platform=myplat", "--out=out", "Main.beni", "Tau.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.foreign_arity_mismatch, r.diagnostics[0].code);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "writes `tau` as a function") != null);
    try testing.expect(!w.exists("out"));
}

test "check 4: a parameter list that is not at the export is refused" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The two forms boundary.md §4 refuses rather than guessing at. Both
    // are legal JavaScript and neither is used by `core/` or
    // `platforms/node`: a sibling is privileged code, so the rule is that
    // the parameter list is written where the arity can be counted against
    // the declaration.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
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
        \\const impl = (line) => ({ text: line });
        \\
        \\export const say = impl;
        \\export const shout = (...parts) => ({ text: parts.join("") });
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
    try testing.expectEqual(@as(usize, 2), r.diagnostics.len);
    var aliased = false;
    var spread = false;
    for (r.diagnostics) |d| {
        try testing.expectEqual(diagnostic.Code.foreign_arity_mismatch, d.code);
        if (std.mem.indexOf(u8, d.message, "exports `say` as a value") != null) aliased = true;
        if (std.mem.indexOf(u8, d.message, "writes `shout` with a rest parameter") != null) spread = true;
    }
    try testing.expect(aliased);
    try testing.expect(spread);
    try testing.expect(!w.exists("out"));
}

test "check 4: every export form a sibling may use, at the right arity, builds and runs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The accepted set of boundary.md §4 check 4, each one at the arity its
    // declaration promises: an arrow, a bare-parameter arrow, a `function`
    // declaration, a `function` expression, a renamed `export { … }`, and a
    // constant for a `foreign` that is not a function. The evidence-carrying
    // one is last and is the reason the check exists.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/Prog.beni",
        \\pub foreign type Program
        \\
        \\
        \\pub foreign say : String -> Program
        \\
        \\
        \\pub foreign zero : Int
        \\
        \\
        \\pub foreign twice : Int -> Int
        \\
        \\
        \\pub foreign plus : Int, Int -> Int
        \\
        \\
        \\pub foreign pick : Int -> Int
        \\
        \\
        \\pub foreign thrice : Int -> Int
        \\
        \\
        \\pub foreign allEq : List a, List a -> Bool
        \\    where a.eq : a, a -> Bool
        \\
    );
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ text: line });
        \\export const zero = 0;
        \\export function twice(n) {
        \\  return n + n;
        \\}
        \\export const plus = function (a, b) {
        \\  return a + b;
        \\};
        \\export const pick = n => n;
        \\
        \\const triple = (n) => n * 3;
        \\export { triple as thrice };
        \\
        \\export const allEq = (m0, xs, ys) => {
        \\  let a = xs;
        \\  let b = ys;
        \\  while (a.$ === 1 && b.$ === 1) {
        \\    if (!m0(a.a, b.a)) return false;
        \\    a = a.b;
        \\    b = b.b;
        \\  }
        \\  return a.$ === b.$;
        \\};
        \\
    );
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    if Prog.allEq [ 1, 2 ] [ 1, 2 ] then
        \\        Prog.say (String.fromInt (Prog.plus (Prog.twice 2) (Prog.thrice (Prog.pick 5))))
        \\
        \\    else
        \\        Prog.say (String.fromInt Prog.zero)
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
    // `twice 2` is 4 and `thrice (pick 5)` is 15, so the sum is 19 — which
    // is only reached when `allEq` received its evidence parameter in front
    // and compared elements rather than a function against a list.
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("19!\n", program.stdout);
    try testing.expectEqualStrings("", program.stderr);
}

test "a constrained `foreign` in value position inside its own module keeps its declared arity" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // static-dispatch-spike.md §8.2: a target that takes evidence, used as
    // a VALUE, is `(a, b) => name(evidence…, a, b)` over the target's own
    // beni arity. A `foreign` had no arity to expand over — `bir/Lower`
    // took `params` from a DEFINITION's parameter list and a `foreign` has
    // none — so `js/Lower.targetArity` said 0 and the evidence slot was
    // handed `() => Prog$eq(Prog$eq$prim)`, a nullary closure where a
    // binary method was promised. The build exited 0 and the program
    // crashed; the same expression in any module that did not DECLARE the
    // `foreign` compiled correctly, which is why `core/List.beni`'s own doc
    // examples were the only thing that caught it.
    //
    // Both ways a value position is reached, in one module:
    //
    //   1. `asEvidence` — the derived `eq` of `Maybe` is handed this
    //      module's `eq` for its element (§9.4);
    //   2. `asValue` — a bare reference passed as an ordinary function
    //      argument (§8.2's "a constrained value used as a value is its
    //      eta-expansion").
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/Prog.beni",
        \\import List
        \\import Maybe exposing (Maybe)
        \\
        \\
        \\pub foreign type Program
        \\
        \\
        \\pub foreign say : String -> Program
        \\
        \\
        \\pub type Bag a
        \\    = Bag (List a)
        \\
        \\
        \\pub foreign eq : Bag a, Bag a -> Bool
        \\    where a.eq : a, a -> Bool
        \\
        \\
        \\apply : Bag Int, Bag Int, (Bag Int, Bag Int -> Bool) -> Bool
        \\apply left right f =
        \\    f left right
        \\
        \\
        \\pub asEvidence : List Int, List Int -> Bool
        \\asEvidence xs ys =
        \\    (Just (Bag xs)) == (Just (Bag ys))
        \\
        \\
        \\pub asValue : List Int, List Int -> Bool
        \\asValue xs ys =
        \\    apply (Bag xs) (Bag ys) eq
        \\
    );
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ text: line });
        \\
        \\export const eq = (m0, left, right) => {
        \\  let a = left.a;
        \\  let b = right.a;
        \\  while (a.$ === 1 && b.$ === 1) {
        \\    if (!m0(a.a, b.a)) return false;
        \\    a = a.b;
        \\    b = b.b;
        \\  }
        \\  return a.$ === b.$;
        \\};
        \\
    );
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\import String
        \\
        \\
        \\yn : Bool -> String
        \\yn b =
        \\    if b then
        \\        "T"
        \\
        \\    else
        \\        "F"
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say
        \\        (String.concat
        \\            [ yn (Prog.asEvidence [ 1, 2 ] [ 1, 2 ])
        \\            , yn (Prog.asEvidence [ 1, 2 ] [ 1, 3 ])
        \\            , yn (Prog.asValue [ 1, 2 ] [ 1, 2 ])
        \\            , yn (Prog.asValue [ 1, 2 ] [ 9 ])
        \\            ]
        \\        )
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
    // Both answers both ways round: the defect crashed on the first, and a
    // sibling forgiving enough to survive it would have answered the second
    // wrong, which is the failure mode worth guarding.
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("TFTF!\n", program.stdout);
    try testing.expectEqualStrings("", program.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The shape claim the run can only prove by crashing: no evidence slot
    // in the module holds a nullary closure over a binary method. Narrow on
    // purpose — the parameter names are `$p$N` counters and goldening the
    // whole arrow would churn on any change to them.
    const prog_mjs = try w.read("out/_platform/Prog.mjs");
    try testing.expect(std.mem.indexOf(u8, prog_mjs, "() => Prog$eq(") == null);
}

test "an unconstrained `foreign` in value position inside its own module is the bare name" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The other half of §8.2's rule, and the guard on the fix above: a
    // target that takes NO evidence is the bare name, eta-expanding it
    // would be wrong, and a `foreign` now carries a `params` that says how
    // wide the expansion WOULD be. Both positions, so the guard covers the
    // one that reaches `targetValue`:
    //
    //   1. `doubled` — an ordinary function argument;
    //   2. `boxed` — an evidence slot, where `Box`'s `eq` is this module's
    //      own unconstrained `foreign` and §8.2's table says bare name.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/Prog.beni",
        \\import List
        \\import Maybe exposing (Maybe)
        \\
        \\
        \\pub foreign type Program
        \\
        \\
        \\pub foreign say : String -> Program
        \\
        \\
        \\pub foreign twice : Int -> Int
        \\
        \\
        \\pub type Box
        \\    = Box Int
        \\
        \\
        \\pub foreign eq : Box, Box -> Bool
        \\
        \\
        \\pub doubled : List Int -> List Int
        \\doubled xs =
        \\    List.map xs twice
        \\
        \\
        \\pub boxed : Int, Int -> Bool
        \\boxed left right =
        \\    (Just (Box left)) == (Just (Box right))
        \\
    );
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ text: line });
        \\export const twice = (n) => n + n;
        \\export const eq = (left, right) => left.a === right.a;
        \\
    );
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\import List
        \\import String
        \\
        \\
        \\yn : Bool -> String
        \\yn b =
        \\    if b then
        \\        "T"
        \\
        \\    else
        \\        "F"
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say
        \\        (String.concat
        \\            [ String.fromInt (List.sum (Prog.doubled [ 1, 2, 3 ]))
        \\            , yn (Prog.boxed 1 1)
        \\            , yn (Prog.boxed 1 2)
        \\            ]
        \\        )
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
    try testing.expectEqualStrings("12TF!\n", program.stdout);
    try testing.expectEqualStrings("", program.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Both uses name the import directly; neither is wrapped.
    const prog_mjs = try w.read("out/_platform/Prog.mjs");
    try testing.expect(std.mem.indexOf(u8, prog_mjs, "List$map(xs$1, Prog$twice)") != null);
    try testing.expect(std.mem.indexOf(u8, prog_mjs, "Maybe$Maybe$$eq(Prog$eq,") != null);
}

test "--library needs no main, writes no entry file, and roots at the exported surface" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §2 and §9's third root bullet. A library has no `main`
    // and its callers are not in the build, so its public surface is its
    // root set — and `--library` is not in `--release`'s and
    // `--source-maps`' company: it lands with §9 and does something the day
    // it lands.
    //
    // Three claims in one build, and each of them is a thing an
    // application build does differently:
    //
    //   1. `missing_main` does not fire, though nothing here declares one;
    //   2. no `out/_main.mjs` is written — it is the entry file and there is
    //      no entry;
    //   3. `exported` survives although nothing in the build calls it,
    //      while `private`, which is not exported and which nothing
    //      reaches, does not. `helper` is the control in the other
    //      direction: not exported either, but reached FROM `exported`, so
    //      it stays.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Lib.beni",
        \\import String
        \\
        \\
        \\helper : Int -> Int
        \\helper n =
        \\    n + 1
        \\
        \\
        \\pub exported : Int -> String
        \\exported n =
        \\    String.fromInt (helper n)
        \\
        \\
        \\private : Int -> Int
        \\private n =
        \\    n * 2
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "build", "--platform=node", "--library", "--out=out", "Lib.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists(world.entry_file));
    const js = try w.read("out/Lib.mjs");
    try testing.expect(std.mem.indexOf(u8, js, "Lib$exported") != null);
    try testing.expect(std.mem.indexOf(u8, js, "Lib$helper") != null);
    try testing.expect(std.mem.indexOf(u8, js, "Lib$private") == null);
    // The same program built as an APPLICATION is the contrast, and it is
    // the whole reason the flag exists: with no `main` there is nothing to
    // root at, so the build refuses rather than emitting an empty tree.
    const app = try w.run(&.{ "build", "--platform=node", "--out=app", "Lib.beni" });
    try testing.expectEqual(@as(u8, 1), app.exit_code);
    try testing.expectEqual(diagnostic.Code.missing_main, app.diagnostics[0].code);
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
    // An absence has no token (`boundary.md` §5): the whole-file 1:1 of the
    // first app module by path, and no excerpt. It used to underline the
    // file's FIRST TOKEN, which in the corpus golden is an `import`.
    try testing.expectEqualStrings("Main.beni", absent.diagnostics[0].span.file);
    try testing.expectEqual(@as(u32, 1), absent.diagnostics[0].span.start.line);
    try testing.expectEqual(@as(u32, 1), absent.diagnostics[0].span.start.col);

    try testing.expectEqual(@as(u8, 1), wrong.exit_code);
    try testing.expectEqual(@as(usize, 1), wrong.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.main_not_program, wrong.diagnostics[0].code);
    // **The type is named as the author could write it** (`checker.md`
    // §8.2): the user wrote `Int`, so the message says `Int`. It used to
    // print the resolver's `Basics.Int`, which is a name no beni source may
    // contain. `Node.Program` keeps its qualifier, because this module has
    // no import that would let `Program` be read bare.
    try testing.expect(std.mem.indexOf(u8, wrong.diagnostics[0].message, "annotated `Int`") != null);
    try testing.expect(std.mem.indexOf(u8, wrong.diagnostics[0].message, "Basics.Int") == null);
    try testing.expect(std.mem.indexOf(u8, wrong.diagnostics[0].message, "`Node.Program`") != null);

    try testing.expectEqual(@as(u8, 1), unannotated.exit_code);
    try testing.expectEqual(@as(usize, 1), unannotated.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.main_not_program, unannotated.diagnostics[0].code);
    try testing.expect(std.mem.indexOf(u8, unannotated.diagnostics[0].message, "needs a type annotation") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
}

test "two `main`s are TWO MAINS, naming both modules and both locations" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A build is a pair of ONE entry point and ONE platform
    // (`boundary.md` §5.3), so a project with two `main`s is two builds. It
    // used to be reported under `missing_main`, whose title — MISSING MAIN —
    // says the opposite of the message printed underneath it, and whose code
    // told a tool routing on it that the project had no entry point when it
    // had two.
    //
    // This cannot be a corpus fixture: the corpus walker passes no
    // `--platform`, and a build that must FAIL has no kind (`plans/
    // coverage-audit.md` Part A).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print "main"
        \\
    );
    try w.write("Other.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print "other"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni", "Other.beni" });
    // The same project with the two paths the other way round. Module index
    // comes from the SORTED path and never from argument or completion order
    // (CLAUDE.md rule 5), so which of the two is "the first" must not move.
    const swapped = try w.run(&.{ "build", "--platform=node", "--out=out", "Other.beni", "Main.beni" });
    // `--library` turns off the requirement for a `main`, and a second one
    // with it (`backend.md` §2): both are exported and neither is an entry
    // point.
    const library = try w.run(&.{ "build", "--platform=node", "--library", "--out=lib", "Main.beni", "Other.beni" });
    // `check --platform` is handed paths rather than a build pair, so it
    // does not look for an entry point at all (`boundary.md` §5.3).
    const checked = try w.run(&.{ "check", "--platform=node", "Main.beni", "Other.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .duplicate_main,
        .severity = .@"error",
        .span = .{
            .file = "Other.beni",
            .start = .{ .line = 5, .col = 1 },
            .end = .{ .line = 5, .col = 5 },
        },
        .title = "TWO MAINS",
        .message =
        \\This project has more than one `main`.
        \\
        \\`Main` declares one at `Main.beni:5:1` and `Other` another at
        \\`Other.beni:5:1`. A build is a pair of ONE entry point and ONE platform
        \\(`docs/design/boundary.md` §5.3), so two entry points are two builds: give
        \\each its own, or pass `--library` if this project is not a program.
        ,
    }, r.diagnostics[0]);
    try testing.expectEqualStrings(r.stderr, swapped.stderr);

    try testing.expectEqual(@as(u8, 0), library.exit_code);
    try testing.expectEqualStrings("", library.stderr);
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqualStrings("", checked.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
    try testing.expect(w.exists("lib/Main.mjs"));
    try testing.expect(w.exists("lib/Other.mjs"));
    try testing.expect(!w.exists("lib/_main.mjs"));
}

test "a `?` nothing reaches is not lowered, so nothing it needs is emitted" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §5: elimination decides what is WRITTEN, never what is
    // CHECKED, and a declaration nobody reaches is never lowered at all.
    //
    // This scenario was written when `?` was the construct that made that
    // observable — it raised a LOWERING diagnostic, and an unreachable
    // declaration containing one still built clean, which is the sharpest
    // possible proof that nothing lowered it. `?` compiles as of M3b, so
    // what is left to observe is the emitted file: `parse` is the only
    // thing in this module that imports `String.toInt`, and neither the
    // declaration, nor its `?`, nor the import survives. The claim is
    // unchanged and one of its two witnesses is gone.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\pub parse : String -> Maybe Int
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
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // And `pub` bought `parse` nothing: §9 roots an application build at
    // `main` alone, because `pub` is a MODULE boundary and not a PROGRAM
    // one, and rooting at it would pin all of core forever.
    const js = try w.read("out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, js, "parse") == null);
    // Nothing the `?` would have emitted is there either: no import of the
    // value it calls, and no early return of a `Nothing` (`backend.md` §4).
    try testing.expect(std.mem.indexOf(u8, js, "toInt") == null);
    try testing.expect(std.mem.indexOf(u8, js, "Nothing") == null);
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

// CK-163 (`scenario/CK-163`, promoted by R15-fix-F): `build --out` only ever
// added to the directory, so a module the program stopped using stayed in
// `out/` beside it. `backend.md` §2, *The output directory holds what the last
// build wrote*: a build removes what the previous one wrote and it did not,
// through `_manifest.txt`, and touches nothing it never wrote.
test "a rebuild into the same --out holds exactly a fresh build's files, and a user's file survives (CK-163)" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Half.beni", "pub half : Int -> Int\nhalf n =\n    n // 2\n");
    try w.write("src/Deep/Half.beni", "pub quarter : Int -> Int\nquarter n =\n    n // 4\n");
    try w.write("src/Main.beni", "import Node exposing (Program)\nimport Dict\nimport Half\nimport Deep.Half\nimport String\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt (Deep.Half.quarter (Half.half (Dict.size (Dict.singleton 1 2)))) ]\n");
    const first = try w.run(&.{ "build", "--platform=node", "--out=out", "--root=src", "src" });
    try testing.expectEqual(@as(u8, 0), first.exit_code);
    try testing.expect(w.exists("out/Half.mjs"));
    try testing.expect(w.exists("out/Deep/Half.mjs"));
    try testing.expect(w.exists("out/_core/Dict.mjs"));
    // Files beni never wrote: one beside its output, one inside a directory
    // it writes into.
    try w.write("out/README.txt", "mine\n");
    try w.write("out/_core/notes.txt", "also mine\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try w.write("src/Main.beni", "import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.printLines [ \"x\" ]\n");
    const second = try w.run(&.{ "build", "--platform=node", "--out=out", "--root=src", "src/Main.beni" });
    const fresh = try w.run(&.{ "build", "--platform=node", "--out=fresh", "--root=src", "src/Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), second.exit_code);
    try testing.expectEqualStrings("", second.stderr);
    try testing.expectEqual(@as(u8, 0), fresh.exit_code);
    const ran = try w.node("out/_main.mjs");
    try testing.expectEqualStrings("x\n", ran.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // `out/` is `fresh/` plus the two files beni never wrote, and the
    // directory `Deep/` its removal emptied is gone too.
    const want = try w.listFiles("fresh");
    var expected: std.ArrayList([]const u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, want);
    try expected.appendSlice(testing.allocator, &.{ "README.txt", "_core/notes.txt" });
    std.mem.sort([]const u8, expected.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    const got = try w.listFiles("out");
    try testing.expectEqual(expected.items.len, got.len);
    for (expected.items, got) |e, g| try testing.expectEqualStrings(e, g);
    try testing.expect(!w.exists("out/Deep"));
    try testing.expectEqualStrings("mine\n", try w.read("out/README.txt"));
    try testing.expectEqualStrings("also mine\n", try w.read("out/_core/notes.txt"));
    // The record lists what this build wrote, and only that.
    try testing.expectEqualStrings(try w.read("fresh/_manifest.txt"), try w.read("out/_manifest.txt"));
}

test "a file beni wrote and the user then edited, or a record line leaving --out, is never removed (CK-163)" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Half.beni", "pub half : Int -> Int\nhalf n =\n    n // 2\n");
    try w.write("Main.beni", "import Node exposing (Program)\nimport Half\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt (Half.half 4) ]\n");
    const first = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni", "Half.beni" });
    try testing.expectEqual(@as(u8, 0), first.exit_code);
    // The user edits a file beni wrote, and someone appends a line to the
    // record naming a file outside `--out`.
    try w.write("out/Half.mjs", "// edited by hand\n");
    try w.write("victim.txt", "outside\n");
    const record = try w.read("out/_manifest.txt");
    try w.write("out/_manifest.txt", try std.mem.concat(w.arena.allocator(), u8, &.{ record, "0000000000000000 ../victim.txt\n" }));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try w.write("Main.beni", "import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.printLines [ \"x\" ]\n");
    const second = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), second.exit_code);
    try testing.expectEqualStrings("", second.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings("// edited by hand\n", try w.read("out/Half.mjs"));
    try testing.expectEqualStrings("outside\n", try w.read("victim.txt"));
    try testing.expect(std.mem.indexOf(u8, try w.read("out/_manifest.txt"), "Half.mjs") == null);
}

test "a refused build removes nothing and leaves the record as it was (CK-163)" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Half.beni", "pub half : Int -> Int\nhalf n =\n    n // 2\n");
    try w.write("Main.beni", "import Node exposing (Program)\nimport Half\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt (Half.half 4) ]\n");
    const first = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni", "Half.beni" });
    try testing.expectEqual(@as(u8, 0), first.exit_code);
    const before = try w.listFiles("out");
    const record = try w.read("out/_manifest.txt");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try w.write("Main.beni", "import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.print 7\n");
    const r = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(diagnostic.Code.kind_mismatch, r.diagnostics[0].code);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    const after = try w.listFiles("out");
    try testing.expectEqual(before.len, after.len);
    for (before, after) |b, a| try testing.expectEqualStrings(b, a);
    try testing.expectEqualStrings(record, try w.read("out/_manifest.txt"));
}

test "--release builds and runs, and --release --source-maps still exits 2 on the source-map line" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §2: the refusal goes with M3c's first slice, and
    // `--source-maps` keeps its own — in a `--release` build too, so the
    // pair exits 2 on the source-map line and writes nothing.
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
    const both = try w.runWith(
        &.{ "build", "--platform=node", "--release", "--source-maps", "--out=maps", "Main.beni" },
        .{ .raw_diagnostics = true },
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
    const program = try w.node(world.entry_file);
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("x\n", program.stdout);

    try testing.expectEqual(@as(u8, 2), both.exit_code);
    try testing.expectEqualStrings(
        "beni: --source-maps is not implemented until M5; this build would write no .map file\n",
        both.stderr,
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("maps"));
}

test "--release refuses a build that reaches Debug; the same program builds and logs without the flag" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §9's *`Debug` is refused, not pinned* (the owner's
    // decision, 2026-09-19, which is Elm's `--optimize` rule). Three builds
    // of ONE program, which is what makes this a claim about the flag:
    // development builds and logs, `--release` is refused, and the hidden
    // `--allow-debug` builds and logs again.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\report : Int -> Int
        \\report n =
        \\    Debug.log (n + 1) "report"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ String.fromInt (report 2) ]
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dev = try w.run(&.{ "build", "--platform=node", "--out=dev", "Main.beni" });
    const rel = try w.run(&.{ "build", "--platform=node", "--release", "--out=rel", "Main.beni" });
    const allowed = try w.run(&.{ "build", "--platform=node", "--release", "--allow-debug", "--out=allow", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dev.exit_code);
    try testing.expectEqual(@as(usize, 0), dev.diagnostics.len);

    try testing.expectEqual(@as(u8, 1), rel.exit_code);
    try testing.expectEqual(@as(usize, 1), rel.diagnostics.len);
    // The whole diagnostic: the region is the REFERENCE and not the
    // declaration, and the message names the module, the declaration and
    // which `Debug` value was used.
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .debug_in_release,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 7, .col = 5 }, .end = .{ .line = 7, .col = 14 } },
        .title = "DEBUG IN A RELEASE BUILD",
        .message =
        \\This `--release` build reaches `Debug`.
        \\
        \\- `Main.beni:7:5` — `Main.report` uses `Debug.log`
        \\
        \\`Debug` is for developing: `toString` reads a value's runtime representation,
        \\which a release build is free to change; a `Debug.log` in a binding nothing
        \\reads is dropped along with the binding; and `todo` crashes. A release build
        \\must behave exactly as the development build does, so it may not reach `Debug`
        \\at all. Remove the call, or build without `--release`.
        ,
    }, rel.diagnostics[0]);

    try testing.expectEqual(@as(u8, 0), allowed.exit_code);
    try testing.expectEqual(@as(usize, 0), allowed.diagnostics.len);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A refused build writes nothing at all — the refusal runs before
    // lowering, so there is not even a half-written tree to clean up.
    try testing.expect(!w.exists("rel"));

    const dev_run = try w.node("dev/_main.mjs");
    try testing.expectEqual(@as(u8, 0), dev_run.exit_code);
    try testing.expectEqualStrings("report: 3\n3\n", dev_run.stdout);
    const allowed_run = try w.node("allow/_main.mjs");
    try testing.expectEqual(@as(u8, 0), allowed_run.exit_code);
    try testing.expectEqualStrings("report: 3\n3\n", allowed_run.stdout);
}

test "a Debug call that reachability drops does not refuse the release build" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The other half of the rule (`backend.md` §9): **reachability is the
    // definition of "this build uses it"**, and nothing softer is. `unused`
    // holds a `Debug.log` and nothing reaches it, so §9's walk drops the
    // whole declaration and the build ships no `Debug` — which is exactly
    // what the refusal is about. A source-text test would refuse this
    // program, and would be wrong to.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\unused : Int -> Int
        \\unused n =
        \\    Debug.log n "unused"
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
    const r = try w.run(&.{ "build", "--platform=node", "--release", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    const program = try w.node(world.entry_file);
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("x\n", program.stdout);
    // And the proof that it really was dropped rather than merely quiet:
    // core's `Debug` module is not in the output tree at all.
    try testing.expect(!w.exists("out/_core/Debug.mjs"));
}

test "--release --library refuses Debug reachable from the exported surface, and not below it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §9: the rule is the same rule with the same root set as
    // everything else `--library` changes — every name the root package's
    // modules export is a root, so a `Debug` reached from `exported`
    // refuses the build while one under a `private` nothing exports does
    // not. Two libraries, one flag pair, so the difference is the roots and
    // nothing else.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Lib.beni",
        \\pub exported : Int -> String
        \\exported n =
        \\    Debug.toString n
        \\
    );
    try w.write("Quiet.beni",
        \\private : Int -> String
        \\private n =
        \\    Debug.toString n
        \\
        \\
        \\pub exported : Int -> Int
        \\exported n =
        \\    n + 1
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const reached = try w.run(&.{ "build", "--platform=node", "--release", "--library", "--out=lib", "Lib.beni" });
    const quiet = try w.run(&.{ "build", "--platform=node", "--release", "--library", "--out=quiet", "Quiet.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), reached.exit_code);
    try testing.expectEqual(@as(usize, 1), reached.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .debug_in_release,
        .severity = .@"error",
        .span = .{ .file = "Lib.beni", .start = .{ .line = 3, .col = 5 }, .end = .{ .line = 3, .col = 19 } },
        .title = "DEBUG IN A RELEASE BUILD",
        .message =
        \\This `--release` build reaches `Debug`.
        \\
        \\- `Lib.beni:3:5` — `Lib.exported` uses `Debug.toString`
        \\
        \\`Debug` is for developing: `toString` reads a value's runtime representation,
        \\which a release build is free to change; a `Debug.log` in a binding nothing
        \\reads is dropped along with the binding; and `todo` crashes. A release build
        \\must behave exactly as the development build does, so it may not reach `Debug`
        \\at all. Remove the call, or build without `--release`.
        ,
    }, reached.diagnostics[0]);

    try testing.expectEqual(@as(u8, 0), quiet.exit_code);
    try testing.expectEqual(@as(usize, 0), quiet.diagnostics.len);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("lib"));
    try testing.expect(w.exists("quiet/Quiet.mjs"));
}

test "the debug_in_release site list does not depend on thread count or argument order" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // CLAUDE.md rule 5, applied to a diagnostic that walks EVERY module of
    // the build and lists what it found. The order is modules by
    // `Graph.Index` — sorted path — then source order, so `Aid.beni`'s
    // sites precede `Main.beni`'s whichever way the arguments are written
    // and however many workers ran.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Aid.beni",
        \\pub help : Int -> String
        \\help n =
        \\    Debug.toString (Debug.log n "help")
        \\
    );
    try w.write("Main.beni",
        \\import Aid
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (Aid.help 1)
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const one = try w.runWith(
        &.{ "build", "--platform=node", "--release", "--jobs=1", "--out=a", "Aid.beni", "Main.beni" },
        .{ .raw_diagnostics = true },
    );
    const many = try w.runWith(
        &.{ "build", "--platform=node", "--release", "--jobs=8", "--out=b", "Aid.beni", "Main.beni" },
        .{ .raw_diagnostics = true },
    );
    const reversed = try w.runWith(
        &.{ "build", "--platform=node", "--release", "--jobs=8", "--out=c", "Main.beni", "Aid.beni" },
        .{ .raw_diagnostics = true },
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), one.exit_code);
    try testing.expectEqual(@as(u8, 1), many.exit_code);
    try testing.expectEqual(@as(u8, 1), reversed.exit_code);
    // Byte for byte, all three: the rendered text, list and caret included.
    try testing.expectEqualStrings(one.stderr, many.stderr);
    try testing.expectEqualStrings(one.stderr, reversed.stderr);
    // And the list really is in sorted-path order, `toString` before the
    // `log` it is applied to, which is instruction order inside one
    // declaration.
    try testing.expect(std.mem.indexOf(u8, one.stderr, "- `Aid.beni:3:5` — `Aid.help` uses `Debug.toString`\n- `Aid.beni:3:21` — `Aid.help` uses `Debug.log`\n") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("a"));
    try testing.expect(!w.exists("b"));
    try testing.expect(!w.exists("c"));
}

test "--source-maps is refused rather than silently writing no .map file" {
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
    const r = try w.runWith(&.{ "build", "--platform=node", "--source-maps", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Positions ride in the IR from M3a (backend.md §9.6) but the VLQ
    // encoder is M5 (§11), so the flag has nothing to do. Accepting it in
    // silence is how a user believes they asked for a `.map` and got one;
    // `--release` is refused for the same reason.
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings(
        "beni: --source-maps is not implemented until M5; this build would write no .map file\n",
        r.stderr,
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
    try testing.expectEqualStrings("", r.stdout);
}

test "Debug.todo compiles as anything and crashes with its message when reached" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `core/Debug.beni`: "It type-checks as anything at all, so the rest of
    // the module still compiles, and it crashes with the message if it is
    // ever reached." Both halves had no test anywhere — `todo` was the one
    // `pub` value in `core/` that no corpus fixture executed, and it cannot
    // become one: a `run/` fixture asserts stdout at exit 0 and this ends
    // the process at exit 1.
    //
    // The type claim is the half worth pinning. `unfinished : Int -> String`
    // returns a `Debug.todo` in one branch and a `String` in the other, so
    // if `todo`'s `a` ever stopped being fully polymorphic the build would
    // fail here rather than at some user's keyboard.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\unfinished : Int -> String
        \\unfinished n =
        \\    if n > 0 then
        \\        String.fromInt n
        \\    else
        \\        Debug.todo "the negative case"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ unfinished 1, unfinished (negate 1) ]
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=node", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);
    const program = try w.node(world.entry_file);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The reachable branch never prints: `printLines` needs the whole list
    // before it writes anything, so the throw comes first.
    try testing.expectEqual(@as(u8, 1), program.exit_code);
    try testing.expectEqualStrings("", program.stdout);
    if (std.mem.indexOf(u8, program.stderr, "Error: TODO: the negative case") == null) {
        std.debug.print("expected the todo message on stderr, got:\n{s}\n", .{program.stderr});
        return error.MissingTodoMessage;
    }
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

test "a platform whose manifest names a runtime file that is not there is refused" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `boundary.md` §5.2: the manifest's `"runtime"` is the file the entry
    // point hands `main` to, and `copyAssets` is the only place that reads
    // it. That is the SECOND site of `foreign_sibling_missing`
    // (`src/js/Emit.zig:906`) and it had no test at all — every other
    // scenario for that code exercises a module's own missing `.js`
    // sibling, which is a different branch a hundred lines earlier.
    //
    // It is build-only: `check --platform` runs §4's sibling checks but
    // writes nothing, so it never asks for the runtime.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/beni.json",
        \\{ "platform": true, "name": "mine", "program": "Prog.Program", "runtime": "gone.js" }
    );
    try w.write("Main.beni",
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
    const r = try w.run(&.{ "build", "--platform=myplat", "--out=out", "Main.beni" });
    const checked = try w.run(&.{ "check", "--platform=myplat", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The span names the MANIFEST. The fault is in the platform package's
    // `beni.json` and in no source file, and it used to land on file 0,
    // token 0 — the first token of the user's own `Main.beni`, inviting the
    // reader to think their `import` was wrong. A manifest has no tokens, so
    // the position is the whole-file 1:1 that `invalid_module_path` already
    // uses for a fault that is about a file rather than a place in one, and
    // nothing renders an excerpt because the manifest is not in the source
    // store.
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .foreign_sibling_missing,
        .severity = .@"error",
        .span = .{
            .file = "myplat/beni.json",
            .start = .{ .line = 1, .col = 1 },
            .end = .{ .line = 1, .col = 1 },
        },
        .title = "MISSING JAVASCRIPT FILE",
        .message =
        \\I cannot find the platform's runtime file `myplat/gone.js`.
        \\
        \\A platform declares its output shape in its manifest (`"runtime"`), and that
        \\file is what the entry point hands `main` to
        \\(`docs/design/boundary.md` §5.2).
        ,
    }, r.diagnostics[0]);
    // And nothing points into the user's source.
    try testing.expect(std.mem.indexOf(u8, r.stderr, "Main.beni") == null);

    // `check` does not copy assets, so the missing runtime is invisible to
    // it and the module's own siblings are all present: it passes.
    try testing.expectEqual(@as(u8, 0), checked.exit_code);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
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
        // The build's record of what it wrote is the one file that is not a
        // module and is never loaded (§2, *The output directory holds what
        // the last build wrote*).
        if (std.mem.eql(u8, path, "_manifest.txt")) continue;
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
    // remove any: the floor is the MINIMUM a program can ship
    // (`backend.md` §9), so nothing can come in under it.
    try testing.expect(program.net_raw_bytes > 0);
    // **§9's acceptance, first half: `derived_bytes` is 0 on the floor and
    // on any program that uses no `==` and no `compare`.** Derivation is
    // still EAGER (§8.5, A.23) — core declares a nominal `eq` and `compare`
    // for every type it has, whether or not anything calls them — and
    // reachability elimination is what keeps them out of a build that does
    // not. Before §9 this same line asserted the opposite, `> 0` and at
    // least four functions, and that was the cost the pass exists to
    // remove.
    try testing.expectEqual(@as(u64, 0), floor.derived_bytes);
    try testing.expectEqual(@as(u32, 0), floor.derived_functions);
    try testing.expectEqual(@as(u64, 0), program.derived_bytes);
    try testing.expectEqual(@as(u32, 0), program.derived_functions);
    // And the floor really is ~2 kB rather than ~70 kB: the number §9
    // predicted by hand before the pass was written. Generous bounds, so
    // that an unrelated core edit does not move the test, but tight enough
    // that a build which stopped eliminating fails here.
    try testing.expect(floor.raw_bytes < 8 * 1024);
    try testing.expect(floor.files <= 8);

    const total = try parseJson(SizeTotal, arena, lastLine(r.stdout));
    try testing.expect(total.total);
    try testing.expectEqual(@as(u32, 1), total.programs);
    // The shared tree counted ONCE plus what the program adds, and the gross
    // sum kept beside it. Each field says which of the two it is, so that
    // the release column can be divided by the right one.
    try testing.expectEqual(floor.raw_bytes + program.net_raw_bytes, total.floor_once_raw_bytes);
    try testing.expectEqual(floor.gzip_bytes + program.net_gzip_bytes, total.floor_once_gzip_bytes);
    try testing.expectEqual(floor.brotli_bytes + program.net_brotli_bytes, total.floor_once_brotli_bytes);
    try testing.expectEqual(program.raw_bytes, total.gross_raw_bytes);
    try testing.expectEqual(floor.raw_bytes, total.floor_raw_bytes);
    // **The pair that may be compared.** `release_gross_*` is summed exactly
    // as `gross_*` is — whole trees, floor included, once per program — so
    // the ratio of the two is a fact about the optimiser. With one program
    // in this corpus the sum IS that program's release tree, and it is
    // smaller than the dev one, which the old netted `raw_bytes` next to a
    // gross `release_raw_bytes` said the opposite of.
    try testing.expect(total.release_gross_raw_bytes > 0);
    try testing.expect(total.release_gross_raw_bytes < total.gross_raw_bytes);
}

test "bench/size.mjs counts §8.5's derived names and not a user's own `eq`" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `derived_bytes` is the whole point of M4's "grows per type x method"
    // row, and it is worth something only if it counts DERIVED code and
    // nothing else. Two programs in one corpus root, and the pair is the
    // assertion:
    //
    //   - `DerivesCompare` orders a three-constructor type, so §8.5 emits
    //     `DerivesCompare$Colour$$compare` and its §9.4 `$$order` table —
    //     and NOT `Colour$$eq`, which is derived eagerly and then
    //     eliminated, nothing having compared a `Colour` for equality
    //     (`backend.md` §9).
    //   - `UserWrittenEq` writes `pub eq` by hand. It is emitted as
    //     `UserWrittenEq$eq`, which is the shape the old matcher —
    //     `$(eq|compare|order)($|end)` — charged to derivation, and which
    //     §8.5 cannot produce: a derived nominal name takes a DOUBLE
    //     separator (`Colour$$eq`) and a structural one an enumerated
    //     suffix (`eq$r$…`, `eq$t2`, `eq$unit`, `eq$prim`). So the answer
    //     is zero, where it used to be one.
    //
    // The same exactness retires the list of nine hand-written core values
    // (`Basics$compare`, `String$compare`, `List$eq`, …) the matcher needed
    // in order to stop claiming those as well: none of them matches now.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("DerivesCompare.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\pub type Colour
        \\    = Red
        \\    | Green
        \\    | Blue
        \\
        \\
        \\pub rank : Colour, Colour -> Bool
        \\rank a b =
        \\    a < b
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (if rank Red Blue then 1 else 0))
        \\
    );
    try w.write("UserWrittenEq.beni",
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
        \\    Node.print (String.fromInt (if eq 1 1 then 1 else 0))
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
    // Sorted by path, so `DerivesCompare` comes first.
    const derives = try parseJson(SizeProgram, arena, it.next() orelse return error.NoProgramLine);
    try testing.expect(std.mem.endsWith(u8, derives.program, "DerivesCompare.beni"));
    try testing.expectEqualStrings("main", derives.roots);
    // Exactly two, and the list is the assertion:
    //
    //     DerivesCompare$Colour$$compare
    //     DerivesCompare$Colour$$order
    //
    // Three would mean `Colour$$eq` survived an elimination nothing reaches
    // it through — derivation is eager and the type is never compared for
    // equality. One would mean the `$$order` table stopped being charged to
    // derivation. Twenty-something would mean core's own eager rows were
    // shipped again, which is the whole cost §9 exists to remove. And a
    // number that moves when core changes would mean the matcher had gone
    // back to guessing from a name's family resemblance.
    try testing.expectEqual(@as(u32, 2), derives.derived_functions);
    try testing.expectEqual(@as(u32, 0), derives.eq_functions);
    try testing.expectEqual(@as(u32, 1), derives.compare_functions);
    try testing.expectEqual(@as(u32, 1), derives.order_tables);
    // `Colour`'s `compare` reads a table and calls nothing, so it passes no
    // depth and needs no `derived$deep` (backend.md §4, R8d).
    try testing.expectEqual(@as(u32, 0), derives.engines);
    try testing.expect(derives.derived_bytes > 0);
    try testing.expect(derives.derived_bytes < derives.raw_bytes);
    // The split is a partition of the same walk, so it adds up on both
    // axes — that is what makes it safe to report the three separately
    // (§11, A.38).
    try testing.expectEqual(
        derives.derived_functions,
        derives.eq_functions + derives.compare_functions + derives.order_tables + derives.engines,
    );
    try testing.expectEqual(
        derives.derived_bytes,
        derives.eq_bytes + derives.compare_bytes + derives.order_bytes + derives.engine_bytes,
    );
    try testing.expect(derives.compare_bytes > 0);
    try testing.expect(derives.order_bytes > 0);

    const user = try parseJson(SizeProgram, arena, it.next() orelse return error.NoProgramLine);
    try testing.expect(std.mem.endsWith(u8, user.program, "UserWrittenEq.beni"));
    // The claim. `UserWrittenEq$eq` IS in the output — it is what `main`
    // calls — and it is not derived code, so none of it is counted.
    try testing.expectEqual(@as(u32, 0), user.derived_functions);
    try testing.expectEqual(@as(u64, 0), user.derived_bytes);
    try testing.expectEqual(@as(u32, 0), user.eq_functions);
    try testing.expectEqual(@as(u32, 0), user.compare_functions);
    try testing.expectEqual(@as(u32, 0), user.order_tables);
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

test "bench/churn.sh fails loudly when the compiler does not run at all" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The script's error count is read out of `dump.err`, and an empty
    // `dump.err` reads as zero errors. So a `beni` that never STARTED — a
    // crash, a kill, an `ETXTBSY` against a binary something else still has
    // open for writing — scored every edit as a clean, interface-preserving
    // measurement: a full plausible table, exit 0, and `rejected` zero in
    // every row. That is the flake the suite saw, and the reason it looked
    // like a flake is that the only assertion it broke was
    // `E3 annotated rejected == 1`.
    //
    // A compiler that exits non-zero without printing a diagnostic is that
    // failure, deterministically: `beni dump` exits 0 whatever it FOUND, so
    // a non-zero status is never a diagnostic and always the process
    // itself.
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
    try w.write("fake-beni",
        \\#!/bin/sh
        \\exit 1
        \\
    );
    const arena = w.arena.allocator();
    try w.makeExecutable("fake-beni");
    const fake = try std.fmt.allocPrint(arena, "{s}/fake-beni", .{try projectPath(&w)});

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runHarness(&w, &.{
        "sh",
        "bench/churn.sh",
        try std.fmt.allocPrint(arena, "--beni={s}", .{fake}),
        try std.fmt.allocPrint(arena, "--corpus={s}", .{try projectPath(&w)}),
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expect(r.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "exited 1") != null);
    // And NO table: numbers counted out of an empty diagnostics stream are
    // indistinguishable from a corpus that churns nothing, so printing them
    // is worse than printing none.
    try testing.expect(std.mem.indexOf(u8, r.stdout, "changed/accepted") == null);
}

const SizeFloor = struct {
    floor: bool,
    files: u32,
    raw_bytes: i64,
    gzip_bytes: i64,
    brotli_bytes: i64,
    /// §9's acceptance number, and the reason the floor line carries the
    /// split at all: a program that compares nothing ships no derived code.
    derived_bytes: u64,
    derived_functions: u32,
};

const SizeProgram = struct {
    program: []const u8,
    /// Which §9 root rule built this line: `main` or `library`.
    roots: []const u8 = "",
    files: u32,
    raw_bytes: i64,
    gzip_bytes: i64,
    brotli_bytes: i64,
    net_raw_bytes: i64,
    net_gzip_bytes: i64,
    net_brotli_bytes: i64,
    derived_bytes: u64,
    derived_functions: u32,
    // The per-method split M4 reports as three numbers and never as a sum
    // (§11, A.38).
    eq_functions: u32,
    eq_bytes: u64,
    compare_functions: u32,
    compare_bytes: u64,
    order_tables: u32,
    order_bytes: u64,
    // `derived$deep`, the explicit-stack engine of backend.md §4 (R8d).
    engines: u32,
    engine_bytes: u64,
};

const SizeSynthesised = struct {
    program: []const u8,
    entry: []const u8,
    modules_measured: u32,
    modules_excluded: []const []const u8,
    net_raw_bytes: i64,
};

/// The `{"total":…}` line. Every figure names its ARITHMETIC: `floor_once_*`
/// counts the floor once and adds each program's net, `gross_*` sums whole
/// trees, and `release_gross_*` sums whole release trees. They were
/// `raw_bytes` and `release_raw_bytes` for one milestone, one netted and one
/// gross, and the obvious comparison of the two said `--release` made
/// programs bigger.
const SizeTotal = struct {
    total: bool,
    programs: u32,
    floor_once_raw_bytes: i64,
    floor_once_gzip_bytes: i64,
    floor_once_brotli_bytes: i64,
    floor_raw_bytes: i64,
    gross_raw_bytes: i64,
    release_gross_raw_bytes: i64 = 0,
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

test "an unannotated pub function constant with a constraint builds and runs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // R2b's review, S3 (static-dispatch-spike.md §10.10 as amended). The
    // program of `check/good/ConstrainedPubFunctionConstant/`, built and
    // run: it cannot be a `run/` fixture, because every unannotated
    // constrained `pub` prints the informational `ambiguous_method_receiver`
    // warning and a `run/` build must be silent. On 84e3cb1 all three `pub`
    // values are `constrained_constant`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("M.beni",
        \\maxOf : a, a -> a
        \\    where a.compare : a, a -> Order
        \\maxOf a b =
        \\    if a < b then
        \\        b
        \\
        \\    else
        \\        a
        \\
        \\
        \\pub equals =
        \\    (==)
        \\
        \\
        \\pub eqs =
        \\    \a b -> a == b
        \\
        \\
        \\pub bigger =
        \\    maxOf
        \\
    );
    try w.write("Main.beni",
        \\import M
        \\import Node exposing (Program)
        \\
        \\
        \\tf : Bool -> String
        \\tf b =
        \\    if b then
        \\        "t"
        \\
        \\    else
        \\        "f"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines
        \\        [ tf (M.equals 1 2)
        \\        , tf (M.eqs "a" "a")
        \\        , tf (List.all [ 3, 3 ] (M.equals 3 _))
        \\        , String.fromInt (List.length (List.filter [ 1, 2, 1 ] (M.eqs 1 _)))
        \\        , String.fromInt (List.foldl [ 4, 9, 2 ] 0 M.bigger)
        \\        , M.bigger "a" "b"
        \\        , String.fromInt (M.bigger 1 2)
        \\        ]
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.buildAndRun(&.{ "Main.beni", "M.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.build.exit_code);
    // Three warnings and no error: the inferred interface carries a `where`.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, r.build.stderr, "CONSTRAINT IN AN INFERRED INTERFACE"));
    try testing.expect(std.mem.indexOf(u8, r.build.stderr, "CONSTRAINED CONSTANT") == null);
    const program = r.program.?;
    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expectEqualStrings("f\nt\nt\n2\n9\nb\n2\n", program.stdout);
}
