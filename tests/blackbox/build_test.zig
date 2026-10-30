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
    const r = try w.buildAndRun(&.{"Main.beni"}, .{ .stdout = "55\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);

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
        "out/_core/List.mjs",
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
        \\pub double : Int → Int
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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "42\n" });

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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Node warns on stderr, it does not fail — so a stray `.js` would pass
    // an exit-code assertion. Both halves are checked: the tree has no `.js`
    // in it, and running the program says nothing at all.
    try w.expectProgram(world.entry_file, .{ .stdout = "10!\n" });

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
    const r = try w.buildAndRun(&.{"Main.beni"}, .{ .exit_code = 3, .stdout = "could not read the file\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
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
        \\name : Colour → String
        \\name c =
        \\    case c of
        \\        Red →
        \\            "red"
        \\
        \\        Blue →
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

test "a build is byte-identical wherever the project lives" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `fast-compiler.md` §10, as amended 2026-10-02: module order must not
    // depend on where the project is. One project in three places, named
    // from one working directory, so the paths the compiler sees put the
    // project's modules before the embedded `core/…` (`aaa/`), between it
    // and `platforms/…` (`d/e/zzz/`, one level deeper too) and after both
    // (`zzz/`). Module order was path order until then, so the three were
    // three programs to every pass that walks modules in order: a
    // specialiser defect showed on one side of `core` and not the other.
    // Each output lives inside its project, so even a source map's
    // relative `sources` path is the same in all three.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const homes = [_][]const u8{ "aaa/app", "zzz/app", "d/e/zzz/app" };
    for (homes) |home| {
        const arena = w.arena.allocator();
        try w.write(try std.fmt.allocPrint(arena, "{s}/Main.beni", .{home}),
            \\import Bits
            \\import Int32
            \\import List
            \\import Node exposing (Program)
            \\import Text.Pad
            \\
            \\
            \\main : Program
            \\main =
            \\    Node.printLines (List.map (List.range 1 3) (λi → Text.Pad.left (Bits.show (Bits.mix (Int32.fromInt i)))))
            \\
        );
        try w.write(try std.fmt.allocPrint(arena, "{s}/Bits.beni", .{home}),
            \\import Int32 exposing (Int32)
            \\import String
            \\
            \\
            \\pub show : Int32 → String
            \\show n = String.fromInt (Int32.toInt n)
            \\
            \\
            \\pub mix : Int32 → Int32
            \\mix n = Int32.xor (Int32.rotateLeft n 5) (Int32.mul n (Int32.fromInt 0x9e3779b9))
            \\
        );
        try w.write(try std.fmt.allocPrint(arena, "{s}/Text/Pad.beni", .{home}),
            \\import String
            \\
            \\
            \\pub left : String → String
            \\left s = String.padLeft s 12 ' '
            \\
        );
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    for (homes) |home| {
        const arena = w.arena.allocator();
        try expectBuilt(try w.runWith(&.{ "build", "--platform=node", try std.fmt.allocPrint(arena, "--out={s}/out", .{home}), home }, .{ .raw_diagnostics = true }));
        try expectBuilt(try w.runWith(&.{ "build", "--platform=node", "--release", try std.fmt.allocPrint(arena, "--out={s}/rel", .{home}), home }, .{ .raw_diagnostics = true }));
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Every file, the manifest and the source maps included: the manifest
    // lists modules in module order, which is what moved.
    for (homes[1..]) |home| {
        const arena = w.arena.allocator();
        try expectSameTree(&w, "aaa/app/out", try std.fmt.allocPrint(arena, "{s}/out", .{home}));
        try expectSameTree(&w, "aaa/app/rel", try std.fmt.allocPrint(arena, "{s}/rel", .{home}));
    }
    try testing.expect((try w.read("aaa/app/out/_manifest.txt")).len > 0);
    try testing.expect((try w.read("aaa/app/out/Text/Pad.mjs.map")).len > 0);
}

test "a release build writes a constant where it is read whichever module comes first" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §9, *Whole-program specialisation*: one program twice,
    // its constant's module named `Aaa` (numbered before `Main`) and `Zzz`
    // (after it), so the specialiser patches the constant before its
    // reader in one and after it in the other. The constant folds to a
    // literal too long to write at more than one read; the second read
    // folds away with `+ 1`, leaving one. Before, the first order kept
    // `const c=-2147483648` (a refusal by the count before the fold), and
    // the second wrote `c+1` (the reader patched before the constant was a
    // literal, and no round after). Both must write the literal at the
    // read and fold the sum, as the facts at their fixpoint allow.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const names = [_][]const u8{ "Aaa", "Zzz" };
    for (names) |name| {
        const arena = w.arena.allocator();
        try w.write(try std.fmt.allocPrint(arena, "{s}/{s}.beni", .{ name, name }),
            \\pub big : Int
            \\big = 0 - 2147483648
            \\
        );
        try w.write(try std.fmt.allocPrint(arena, "{s}/Main.beni", .{name}), try std.fmt.allocPrint(arena,
            \\import {s}
            \\import Node exposing (Program)
            \\import String
            \\
            \\
            \\twice : Int → Int
            \\twice n = n * 2 + 1
            \\
            \\
            \\main : Program
            \\main =
            \\    Node.printLines
            \\        [ String.fromInt (twice 3)
            \\        , String.fromInt (twice 5)
            \\        , String.fromInt (twice {s}.big)
            \\        , String.fromInt ({s}.big + 1)
            \\        ]
            \\
        , .{ name, name, name }));
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    for (names) |name| {
        const arena = w.arena.allocator();
        try expectBuilt(try w.runWith(&.{ "build", "--platform=node", "--release", try std.fmt.allocPrint(arena, "--out={s}/rel", .{name}), name }, .{ .raw_diagnostics = true }));
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    const first = try w.read("Aaa/rel/_main.mjs");
    try testing.expectEqualStrings(first, try w.read("Zzz/rel/_main.mjs"));
    try testing.expect(std.mem.indexOf(u8, first, "(-2147483648)") != null);
    try testing.expect(std.mem.indexOf(u8, first, "(-2147483647)") != null);
    try testing.expect(std.mem.indexOf(u8, first, "=-2147483648") == null);
}

/// A view module and the program that renders it through the `ssr`
/// lowering: a component in the other module, a `For` compiled in place,
/// a `Show`, and holes and attributes of several kinds — enough roots,
/// hoisted kinds and fresh names across two modules that anything the
/// markup lowering named from completion order would show.
fn writeMarkupProject(w: *World) !void {
    try w.write("View.beni",
        \\import Html exposing (Html)
        \\
        \\
        \\pub type alias Row =
        \\    { id : Int, label : String }
        \\
        \\
        \\pub row : { item : Row, selected : Int } → Html msg
        \\row props =
        \\    <tr class={[ ( "row", True ), ( "danger", props.item.id == props.selected ) ]}><td>{props.item.id}</td><td>{props.item.label}</td></tr>
        \\
    );
    try w.write("Main.beni",
        \\import Html exposing (Html)
        \\import Node exposing (Program)
        \\import Ssr
        \\import View
        \\
        \\
        \\page : List View.Row, Maybe String → Html msg
        \\page rows title =
        \\    <main>
        \\        <Show when={title} keyed fallback={<h1>Untitled</h1>}>{λt → <h1 title={t}>{t} &amp; co</h1>}</Show>
        \\        <table>
        \\            <tbody>
        \\                <For each={rows} keyed={.id}>{λr → <View.row item={r} selected={2} />}</For>
        \\            </tbody>
        \\        </table>
        \\    </main>
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (Ssr.render (page [ { id = 1, label = "a" }, { id = 2, label = "<b>" } ] (Just "T")))
        \\
    );
}

const markup_page = "<main><h1 title=\"T\">T &amp; co</h1><table><tbody><tr class=\"row\"><td>1</td><td>a</td></tr><tr class=\"row danger\"><td>2</td><td>&lt;b></td></tr></tbody></table></main>\n";

test "a markup program builds byte-identical at every --jobs, and runs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `boundary.md` §9.6: a lowering names what it hoists and what it binds
    // from the module's site and a counter of the module's own lowering,
    // never one shared between workers, and start data is sorted — so the
    // markup rule-5 test is the ordinary one with markup in it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeMarkupProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const one = try w.runWith(&.{ "build", "--platform=node", "--out=one", "--jobs=1", "Main.beni", "View.beni" }, .{ .raw_diagnostics = true });
    const many = try w.runWith(&.{ "build", "--platform=node", "--out=many", "--jobs=8", "Main.beni", "View.beni" }, .{ .raw_diagnostics = true });
    const one_r = try w.runWith(&.{ "build", "--platform=node", "--release", "--out=one-rel", "--jobs=1", "Main.beni", "View.beni" }, .{ .raw_diagnostics = true });
    const many_r = try w.runWith(&.{ "build", "--platform=node", "--release", "--out=many-rel", "--jobs=8", "Main.beni", "View.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(one);
    try expectBuilt(many);
    try expectBuilt(one_r);
    try expectBuilt(many_r);
    try w.expectProgram("one/_main.mjs", .{ .stdout = markup_page });
    try w.expectProgram("one-rel/_main.mjs", .{ .stdout = markup_page });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectSameTree(&w, "one", "many");
    try expectSameTree(&w, "one-rel", "many-rel");
    // The markup runtime is copied because a module imports it.
    try testing.expect(w.exists("one/_platform/markup.foreign.mjs"));
}

test "a --fuzz build of a browser-tea page installs the fuzz hook and keeps string tags and unbuilt arms in release" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The platform-independent half of `--fuzz`'s contract (the page
    // fuzzer, `tests/browser/fuzz.mjs`): the hidden flag is accepted with
    // and without `--release`, both builds install the hook the fuzzer
    // sends messages through, and the release build keeps the message
    // type's string tags, which the fuzzer's values are written in, and
    // the arm of `Unbuilt`, which nothing builds but the fuzzer sends. A
    // build without the flag ships none of this.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Html exposing (Html)
        \\import Tea
        \\
        \\
        \\type Msg
        \\    = Inc
        \\    | Unbuilt Int
        \\
        \\
        \\update : Msg, Int → Int
        \\update msg n =
        \\    case msg of
        \\        Inc →
        \\            n + 1
        \\
        \\        Unbuilt k →
        \\            k
        \\
        \\
        \\view : Int → Html Msg
        \\view n = <button onClick={Inc}>{String.fromInt n}</button>
        \\
        \\
        \\main : Tea.Program
        \\main = Tea.sandbox { init = λ⊤ → 0, update = update, view = view }
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const fuzz = try w.runWith(&.{ "build", "--platform=browser-tea", "--fuzz", "--out=fuzz", "Main.beni" }, .{ .raw_diagnostics = true });
    const fuzz_r = try w.runWith(&.{ "build", "--platform=browser-tea", "--fuzz", "--release", "--out=fuzz-rel", "Main.beni" }, .{ .raw_diagnostics = true });
    const plain = try w.runWith(&.{ "build", "--platform=browser-tea", "--out=plain", "Main.beni" }, .{ .raw_diagnostics = true });
    const plain_r = try w.runWith(&.{ "build", "--platform=browser-tea", "--release", "--out=plain-rel", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(fuzz);
    try expectBuilt(fuzz_r);
    try expectBuilt(plain);
    try expectBuilt(plain_r);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(std.mem.indexOf(u8, try w.read("fuzz/Main.mjs"), "fuzzInstall") != null);
    try testing.expect(std.mem.indexOf(u8, try w.read("plain/Main.mjs"), "fuzzInstall") == null);
    const released = try w.read("fuzz-rel/_main.mjs");
    try testing.expect(std.mem.indexOf(u8, released, "__beniFuzz") != null);
    try testing.expect(std.mem.indexOf(u8, released, "\"Inc\"") != null);
    const shipped = try w.read("plain-rel/_main.mjs");
    try testing.expect(std.mem.indexOf(u8, shipped, "__beniFuzz") == null);
    try testing.expect(std.mem.indexOf(u8, shipped, "\"Inc\"") == null);
    // `update` keeps both arms: the test of `Inc` and, after it, the
    // `Unbuilt` arm that returns the payload (`… === "Inc" ? n + 1 : msg.a`).
    const test_at = std.mem.indexOf(u8, released, "===\"Inc\"?") orelse return error.NoIncTest;
    const rest = released[test_at..];
    const arm_end = std.mem.indexOfAny(u8, rest, ",;") orelse rest.len;
    try testing.expect(std.mem.indexOfScalar(u8, rest[0..arm_end], ':') != null);
}

test "a view formatted renders the page the view rendered" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The formatter never changes what a page says (language.md §11.15):
    // whitespace between children keeps its newlines, and text keeps its
    // characters. The view is written unformatted — attributes past the
    // line, spaces the page shows between children on one line, and a run
    // holding a newline, which shows nothing — and must render the same
    // string before and after `fmt`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Html exposing (Html)
        \\import Node exposing (Program)
        \\import Ssr
        \\
        \\
        \\view : String → Html msg
        \\view name =
        \\    <div class="card" id="main-card" title="A title long enough to push these attributes past the line"><p>Hello,   <b>{name}</b> <i>and</i>
        \\          welcome&nbsp;back</p><ul>
        \\    <li>one</li>  <li>two</li></ul></div>
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (Ssr.render (view "you"))
        \\
    );
    const page = "<div class=\"card\" id=\"main-card\" title=\"A title long enough to push these attributes past the line\"><p>Hello, <b>you</b> <i>and</i>welcome\u{a0}back</p><ul><li>one</li> <li>two</li></ul></div>\n";

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const before = try w.runWith(&.{ "build", "--platform=node", "--out=before", "Main.beni" }, .{ .raw_diagnostics = true });
    const formatted = try w.runWith(&.{ "fmt", "--stdout", "Main.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), formatted.exit_code);
    try w.write("Main.beni", formatted.stdout);
    const after = try w.runWith(&.{ "build", "--platform=node", "--out=after", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(before);
    try expectBuilt(after);
    try w.expectProgram("before/_main.mjs", .{ .stdout = page });
    try w.expectProgram("after/_main.mjs", .{ .stdout = page });
}

/// Two output trees must hold the same paths and the same bytes. The WHOLE
/// tree, not a chosen list: the set of paths is itself part of what must not
/// move (CLAUDE.md rule 5).
fn expectSameTree(w: *World, a_dir: []const u8, b_dir: []const u8) !void {
    const arena = w.arena.allocator();
    const written = try treeOf(w, a_dir);
    try testing.expectEqualDeep(written, try treeOf(w, b_dir));
    // Not an empty tree: a module and the entry, or under `--release` the one
    // scope-hoisted file (`backend.md` §9), and the manifest.
    try testing.expect(written.len >= 2);
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
    // dispatch: the arguments a call passes are a function of what
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
        \\pub scale : Metre, Int → Metre
        \\scale m factor =
        \\    case m of
        \\        Metre n →
        \\            Metre (n * factor)
        \\
    );
    try w.write("src/Boxes.beni",
        \\pub type Box a
        \\    = Box a
        \\
        \\
        \\pub scale : Box a, Int → Box a
        \\    where a.scale : a, Int → a
        \\scale b factor =
        \\    case b of
        \\        Box inner →
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
        \\twice : a, Int → a
        \\    where a.scale : a, Int → a
        \\twice x factor =
        \\    (x.scale factor).scale factor
        \\
        \\
        \\grow : Box Metre → Box Metre
        \\grow b =
        \\    twice b 2
        \\
        \\
        \\width : Box Metre → Int
        \\width b =
        \\    case b of
        \\        Boxes.Box m →
        \\            case m of
        \\                Metres.Metre n →
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
    try w.expectProgram("one-rel/_main.mjs", .{ .stdout = "12\n" });
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
    try w.expectProgram("one/_main.mjs", .{ .stdout = "12\n" });
}

test "names several emit workers invent for one type agree, and the build is byte-identical at every --jobs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Modules are lowered and printed on several threads, each inventing
    // names in a pool of its own (`InternPool.Overlay`). Here three modules
    // compare values of one type declared in a fourth, so each of them
    // invents, on its own worker, the name of `Shapes`' derived `eq` and
    // `compare` — the same TEXT under a different symbol in every pool. Under
    // `--release` the import in each module and the export in `Shapes` must
    // still come out with ONE short name, which only holds if the names are
    // merged by text before they are numbered; a program whose names were
    // numbered by symbol would fail to load. And none of it may move with
    // the thread count, so every tree is built twice at each `--jobs`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Shapes.beni",
        \\pub type Point
        \\    = Point Int Int
        \\
        \\
        \\pub type Shape
        \\    = Dot Point
        \\    | Line Point Point
        \\
    );
    const user =
        \\import Shapes exposing (Point, Shape, Dot, Line)
        \\
        \\
        \\pub same : Shape, Shape → Bool
        \\same a b =
        \\    a == b
        \\
        \\
        \\pub before : Shape, Shape → Bool
        \\before a b =
        \\    a < b
        \\
    ;
    for ([_][]const u8{ "src/A.beni", "src/B.beni", "src/C.beni" }) |path| try w.write(path, user);
    try w.write("src/Main.beni",
        \\import A
        \\import B
        \\import C
        \\import Node exposing (Program)
        \\import Shapes exposing (Point, Shape, Dot, Line)
        \\import String
        \\
        \\
        \\flag : Bool → String
        \\flag b =
        \\    if b then
        \\        "y"
        \\
        \\    else
        \\        "n"
        \\
        \\
        \\main : Program
        \\main =
        \\    p =
        \\        Dot (Point 1 2)
        \\
        \\    q =
        \\        Line (Point 1 2) (Point 3 4)
        \\    Node.print (flag (A.same p p) ++ flag (B.same p q) ++ flag (C.before p q) ++ flag (A.before q p))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const Build = struct { out: []const u8, jobs: []const u8, release: bool };
    const builds = [_]Build{
        .{ .out = "dev-1a", .jobs = "--jobs=1", .release = false },
        .{ .out = "dev-8a", .jobs = "--jobs=8", .release = false },
        .{ .out = "dev-1b", .jobs = "--jobs=1", .release = false },
        .{ .out = "dev-8b", .jobs = "--jobs=8", .release = false },
        .{ .out = "rel-1a", .jobs = "--jobs=1", .release = true },
        .{ .out = "rel-8a", .jobs = "--jobs=8", .release = true },
        .{ .out = "rel-1b", .jobs = "--jobs=1", .release = true },
        .{ .out = "rel-8b", .jobs = "--jobs=8", .release = true },
    };
    for (builds) |b| {
        const out = try std.fmt.allocPrint(w.arena.allocator(), "--out={s}", .{b.out});
        const r = if (b.release)
            try w.runWith(&.{ "build", "--platform=node", "--release", "--no-cache", out, b.jobs, "src" }, .{ .raw_diagnostics = true })
        else
            try w.runWith(&.{ "build", "--platform=node", "--no-cache", out, b.jobs, "src" }, .{ .raw_diagnostics = true });
        try expectBuilt(r);
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for (builds[1..4]) |b| try expectSameTree(&w, "dev-1a", b.out);
    for (builds[5..8]) |b| try expectSameTree(&w, "rel-1a", b.out);
    // The derived functions really are named from three importing modules,
    // so a green run means their names were merged rather than that there
    // was nothing to merge.
    for ([_][]const u8{ "dev-1a/A.mjs", "dev-1a/B.mjs", "dev-1a/C.mjs" }) |path| {
        const js = try w.read(path);
        try testing.expect(std.mem.indexOf(u8, js, "Shapes$Shape$$") != null);
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY STATE                            │
    // └─────────────────────────────────────────┘
    try w.expectProgram("dev-8a/_main.mjs", .{ .stdout = "ynyn\n" });
    try w.expectProgram("rel-8a/_main.mjs", .{ .stdout = "ynyn\n" });
}

test "a prerendered page is byte-identical at every --jobs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `prerender.md` §5.4: the page is a function of the program, the shell
    // and the base, so the tree a prerendering build writes, the page among
    // it, does not move with the worker count. Two modules, so the other's
    // view is a piece with a render function of its own, and arms the
    // first model hides, so the page holds their comments.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("beni.json", "{ \"html\": \"shell.html\" }\n");
    try w.write("shell.html", "<!doctype html><script type=\"module\" src=\"{{entry}}\"></script><body>{{view}}</body>\n");
    try w.write("src/Panel.beni",
        \\import Html exposing (Html)
        \\
        \\
        \\pub view : Int → Html msg
        \\view n =
        \\    <section>
        \\        <output>{n}</output>
        \\        {if n > 2 then <strong>many</strong> else <></>}
        \\    </section>
        \\
    );
    try w.write("src/Main.beni",
        \\import Browser
        \\import Html exposing (Html)
        \\import Panel
        \\import Tea
        \\
        \\
        \\type alias Model =
        \\    n : Int
        \\    open : Bool
        \\
        \\
        \\type Msg
        \\    = Grow
        \\
        \\
        \\update : Msg, Model → Model
        \\update msg model =
        \\    case msg of
        \\        Grow →
        \\            { model | n = model.n + 1, open = True }
        \\
        \\
        \\view : Model → Html Msg
        \\view model =
        \\    <main>
        \\        <button onClick={Grow}>{model.n} & more</button>
        \\        {if model.open then <p>open</p> else <></>}
        \\        {Panel.view model.n}
        \\    </main>
        \\
        \\
        \\main : Tea.Program
        \\main =
        \\    Browser.prerender
        \\        (Tea.sandbox { init = λ⊤ → { n = 1, open = False }, update = update, view = view })
        \\        [ "/", "/about", "/blog/" ]
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const Build = struct { out: []const u8, jobs: []const u8, release: bool };
    const builds = [_]Build{
        .{ .out = "dev-1a", .jobs = "--jobs=1", .release = false },
        .{ .out = "dev-8a", .jobs = "--jobs=8", .release = false },
        .{ .out = "dev-1b", .jobs = "--jobs=1", .release = false },
        .{ .out = "dev-8b", .jobs = "--jobs=8", .release = false },
        .{ .out = "rel-1a", .jobs = "--jobs=1", .release = true },
        .{ .out = "rel-8a", .jobs = "--jobs=8", .release = true },
        .{ .out = "rel-1b", .jobs = "--jobs=1", .release = true },
        .{ .out = "rel-8b", .jobs = "--jobs=8", .release = true },
    };
    for (builds) |b| {
        const out = try std.fmt.allocPrint(w.arena.allocator(), "--out={s}", .{b.out});
        const options: world.RunOptions = .{ .raw_diagnostics = true, .path = try w.nodePath() };
        const r = if (b.release)
            try w.runWith(&.{ "build", "--platform=browser-inline", "--release", "--no-cache", out, b.jobs, "src" }, options)
        else
            try w.runWith(&.{ "build", "--platform=browser-inline", "--no-cache", out, b.jobs, "src" }, options);
        try expectBuilt(r);
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for (builds[1..4]) |b| try expectSameTree(&w, "dev-1a", b.out);
    for (builds[5..8]) |b| try expectSameTree(&w, "rel-1a", b.out);
    // Each page is the first render, the same in both modes, with its
    // route (`prerender.md` §7.4), after the capture script of its one
    // listener's kind (§6.5, amended 2026-10-29).
    for ([_][2][]const u8{ .{ "index.html", "/" }, .{ "about.html", "/about" }, .{ "blog/index.html", "/blog/" } }) |pair| {
        const page = try std.fmt.allocPrint(w.arena.allocator(), "<!doctype html><script type=\"module\" src=\"/_main.mjs\"></script><body><script>(()=>{{let d=document,r=[],k=[\"click\"],f=e=>{{let t=e.target;t.closest?.(\"[data-beni]\")&&r.push([e,t.value,t.checked,t.selectedIndex])}};for(let n of k)d.addEventListener(n,f,!0);window.$beni=()=>{{for(let n of k)d.removeEventListener(n,f,!0);return r}};d.currentScript.remove()}})()</script><main data-beni=\"{s}\"><button>1 &amp; more</button><!--0--><section><output>1</output><!--1--></section></main></body>\n", .{pair[1]});
        for ([_][]const u8{ "dev-1a", "rel-1a" }) |out| {
            try testing.expectEqualStrings(page, try w.read(try std.fs.path.join(w.arena.allocator(), &.{ out, pair[0] })));
        }
    }
}

/// A data site under `dir` (`prerender.md` §8), its site `Main.beni` and
/// `Post.beni` at the project root, its data program in `data/`: one that reads
/// `posts/hello.txt`, says `Debug.log`, and gives two routes; a site that
/// shows each page's text.
fn writeDataSite(w: *World, dir: []const u8) !void {
    const a = w.arena.allocator();
    try w.write(try std.fs.path.join(a, &.{ dir, "beni.json" }),
        \\{ "html": "shell.html", "build": { "data": { "paths": ["data", "Post.beni"], "inputs": ["posts"] } } }
        \\
    );
    try w.write(try std.fs.path.join(a, &.{ dir, "shell.html" }), "<!doctype html><script type=\"module\" src=\"{{entry}}\"></script><body>{{view}}</body>\n");
    try w.write(try std.fs.path.join(a, &.{ dir, "posts/hello.txt" }), "Hello");
    try w.write(try std.fs.path.join(a, &.{ dir, "Post.beni" }),
        \\pub schema Post =
        \\    body : String
        \\
    );
    try w.write(try std.fs.path.join(a, &.{ dir, "data/Main.beni" }),
        \\import Io
        \\import Node exposing (Program)
        \\import Post exposing (Post)
        \\import Prerender
        \\
        \\
        \\main : Program
        \\main = Prerender.pages (Post.schema ⊤) λ⊤ →
        \\    case Io.readFile "posts/hello.txt" of
        \\        Ok body →
        \\            Ok [ ( "/", Debug.log "post" { body = body } ), ( "/about", { body = "About" } ) ]
        \\
        \\        Err _ →
        \\            Err "no post"
        \\
    );
    try w.write(try std.fs.path.join(a, &.{ dir, "Main.beni" }),
        \\import Browser
        \\import Html exposing (Html)
        \\import Post exposing (Post)
        \\import Tea
        \\
        \\
        \\view : String → Html String
        \\view text = <p>{text}</p>
        \\
        \\
        \\main : Tea.Program
        \\main = Browser.prerenderData (Post.schema ⊤) λpost →
        \\    Tea.sandbox { init = λ⊤ → post.body, update = λm _ → m, view = view }
        \\
    );
}

test "a data program runs at its project's root, and may say Debug.log under --release" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `prerender.md` §8.3: the data program runs with its working directory
    // at the project root, wherever `beni` was started, so `Io.readFile
    // "posts/hello.txt"` names the project's file; and it is built in
    // development mode in every build, so a `Debug.log` in it does not
    // refuse a `--release` build, which `--allow-debug` is not given.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeDataSite(&w, "site");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=browser-inline", "--release", "--root=site", "--out=site/out", "site/Main.beni", "site/Post.beni" }, .{ .raw_diagnostics = true, .path = try w.nodePath() });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    // What the data program logged is passed on to the build's standard
    // error (§5.1), and nothing else is said.
    try testing.expect(std.mem.indexOf(u8, r.stderr, "post:") != null);
    try testing.expectEqualStrings(
        "<!doctype html><script type=\"module\" src=\"/_main.mjs\"></script><body><script type=\"application/json\" data-beni-data=\"/\">{\"body\":\"Hello\"}</script><p data-beni=\"/\">Hello</p></body>\n",
        try w.read("site/out/index.html"),
    );
    try testing.expect(w.exists("site/out/about.html"));
    try testing.expect(!w.exists("site/.out.data") and !w.exists("site/.out.prerender"));
}

test "a data build leaves a directory of the user's alone, and reads no records an old run left" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `prerender.md` §8.3: the data program is built into `.<out>.data`,
    // which the build removes; a directory of that name beni did not write
    // is the user's, refused and kept, as the prerender tree's is (§5.1).
    // And a records file a killed build left there is not the next run's.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeDataSite(&w, ".");
    try w.write(".out.data/keep.txt", "precious");
    const options: world.RunOptions = .{ .raw_diagnostics = true, .path = try w.nodePath() };

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const kept = try w.runWith(&.{ "build", "--platform=browser-inline", "--out=out", "Main.beni", "Post.beni" }, options);
    const still = try w.read(".out.data/keep.txt");
    try w.tmp.dir.deleteTree(w.io, ".out.data");
    // A tree beni wrote, the data program's built by hand there, whose
    // `main` writes no record, beside a records file an old run left.
    try w.write("data/Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main = Node.print "hello"
        \\
    );
    const by_hand = try w.runWith(&.{ "build", "--platform=node", "--out=.out.data", "--no-source-maps", "data", "Post.beni" }, options);
    try w.write(".out.data/_records.jsonl", "{\"route\":\"/\",\"data\":\"{\\\"body\\\":\\\"stale\\\"}\"}\n{\"end\":1}\n");
    const stale = try w.runWith(&.{ "build", "--platform=browser-inline", "--diagnostics=json", "--out=out", "Main.beni", "Post.beni" }, options);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), kept.exit_code);
    try testing.expect(std.mem.indexOf(u8, kept.stderr, "is not a data program's tree beni wrote") != null);
    try testing.expectEqualStrings("precious", still);
    try testing.expectEqual(@as(u8, 0), by_hand.exit_code);
    try testing.expectEqual(@as(u8, 1), stale.exit_code);
    try testing.expect(std.mem.indexOf(u8, stale.stderr, "\"code\":\"prerender_data_failed\"") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out"));
    try testing.expect(!w.exists(".out.data"));
}

test "a data site's pages are byte-identical at every --jobs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `prerender.md` §8.9: the pages are a function of the site, the shell,
    // the base and the data program's records; nothing depends on `--jobs`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeDataSite(&w, ".");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const outs = [_][]const u8{ "out-1a", "out-8a", "out-1b", "out-8b" };
    for (outs, 0..) |out, i| {
        const jobs = if (i % 2 == 0) "--jobs=1" else "--jobs=8";
        const flag = try std.fmt.allocPrint(w.arena.allocator(), "--out={s}", .{out});
        const r = try w.runWith(&.{ "build", "--platform=browser-inline", "--no-cache", flag, jobs, "Main.beni", "Post.beni" }, .{ .raw_diagnostics = true, .path = try w.nodePath() });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for (outs[1..]) |out| try expectSameTree(&w, "out-1a", out);
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
        \\add : Int, Int → Int
        \\add a b =
        \\    a + b
        \\
        \\
        \\apply : (Int, Int → Int), Int, Int → Int
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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "42\n" });

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
        \\pub areaOf : Shape → Int
        \\areaOf shape =
        \\    case shape of
        \\        Square side →
        \\            abs (side * side)
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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "49\n" });

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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "hello!\n" });
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
        \\pub twice : Int → Int
        \\twice n =
        \\    n * 2
        \\
    );
    try w.write("src/Platform/Node.beni",
        \\pub thrice : Int → Int
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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // 1 + 2 + 3 = 6, thrice 18, twice 36. A `Core.List` that had overwritten
    // core's own `List` could not have produced it.
    try w.expectProgram(world.entry_file, .{ .stdout = "36\n" });

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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try w.expectProgram("out/_start.mjs", .{ .stdout = "hello!\n" });

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
    try w.write("Prim.beni", "pub foreign pure double : Int → Int\n");

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
        .span = .{ .file = "Prim.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 24 } },
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
        \\pub foreign pure say : String → Program
        \\
        \\
        \\pub foreign pure shout : String → Program
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
    try w.write("mycore/List.beni", "pub equatable foreign type List a\n\n\npub foreign pure length : List a → Int\n");
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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "hello on a host!\n" });
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
    try w.write("Extra.beni", "pub foreign pure helper : Int → Int\n");
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
    try w.write("Bad.beni", "pub foreign pure anything : a\n");
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
    try w.write("Tau.beni", "pub foreign pure tau : Float\n");
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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "6.283185307179586!\n" });
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
        \\pub foreign pure say : String → Program
        \\
        \\
        \\pub foreign pure allEq : List a, List a → Bool
        \\    where a.eq : a, a → Bool
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
    // checker-v2.md §12.5, boundary.md §4 check 4 as amended. `isPos :
    // IntPred` spells no arrow, but `IntPred` IS `Int -> Bool`, and every
    // call of it is lowered by `Convention` as `isPos(x)`. Check 4 must not
    // read the annotation's spelling, call it a VALUE, and refuse the one
    // sibling that works, `(x) => …`, as "written as a function"; it asks
    // the same `Convention`: one parameter.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("myplat/Prog.beni",
        \\pub foreign type Program
        \\
        \\
        \\pub type alias IntPred =
        \\    Int → Bool
        \\
        \\
        \\pub foreign pure say : String → Program
        \\
        \\
        \\pub foreign pure isPos : IntPred
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
    try w.expectProgram("out/_main.mjs", .{ .stdout = "same!\n" });

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
        \\pub foreign pure say : String, String → Program
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
    try w.write("Tau.beni", "pub foreign pure tau : Float\n");
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
        \\pub foreign pure say : String → Program
        \\
        \\
        \\pub foreign pure shout : String → Program
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
        \\pub foreign pure say : String → Program
        \\
        \\
        \\pub foreign pure zero : Int
        \\
        \\
        \\pub foreign pure twice : Int → Int
        \\
        \\
        \\pub foreign pure plus : Int, Int → Int
        \\
        \\
        \\pub foreign pure pick : Int → Int
        \\
        \\
        \\pub foreign pure thrice : Int → Int
        \\
        \\
        \\pub foreign pure allEq : List a, List a → Bool
        \\    where a.eq : a, a → Bool
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
        \\  const a = Array.isArray(xs) ? xs : xs.$plain();
        \\  const b = Array.isArray(ys) ? ys : ys.$plain();
        \\  if (a.length !== b.length) return false;
        \\  for (let i = 0; i < a.length; i++) if (!m0(a[i], b[i])) return false;
        \\  return true;
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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // `twice 2` is 4 and `thrice (pick 5)` is 15, so the sum is 19 — which
    // is only reached when `allEq` received its evidence parameter in front
    // and compared elements rather than a function against a list.
    try w.expectProgram(world.entry_file, .{ .stdout = "19!\n" });
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
        \\pub foreign pure say : String → Program
        \\
        \\
        \\pub type Bag a
        \\    = Bag (List a)
        \\
        \\
        \\pub foreign pure eq : Bag a, Bag a → Bool
        \\    where a.eq : a, a → Bool
        \\
        \\
        \\apply : Bag Int, Bag Int, (Bag Int, Bag Int → Bool) → Bool
        \\apply left right f =
        \\    f left right
        \\
        \\
        \\pub asEvidence : List Int, List Int → Bool
        \\asEvidence xs ys =
        \\    (Just (Bag xs)) == (Just (Bag ys))
        \\
        \\
        \\pub asValue : List Int, List Int → Bool
        \\asValue xs ys =
        \\    apply (Bag xs) (Bag ys) eq
        \\
    );
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ text: line });
        \\
        \\export const eq = (m0, left, right) => {
        \\  const a = Array.isArray(left.a) ? left.a : left.a.$plain();
        \\  const b = Array.isArray(right.a) ? right.a : right.a.$plain();
        \\  if (a.length !== b.length) return false;
        \\  for (let i = 0; i < a.length; i++) if (!m0(a[i], b[i])) return false;
        \\  return true;
        \\};
        \\
    );
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\import String
        \\
        \\
        \\yn : Bool → String
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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Both answers both ways round: the defect crashed on the first, and a
    // sibling forgiving enough to survive it would have answered the second
    // wrong, which is the failure mode worth guarding.
    try w.expectProgram(world.entry_file, .{ .stdout = "TFTF!\n" });

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
        \\pub foreign pure say : String → Program
        \\
        \\
        \\pub foreign pure twice : Int → Int
        \\
        \\
        \\pub type Box
        \\    = Box Int
        \\
        \\
        \\pub foreign pure eq : Box, Box → Bool
        \\
        \\
        \\pub doubled : List Int → List Int
        \\doubled xs =
        \\    List.map xs twice
        \\
        \\
        \\pub boxed : Int, Int → Bool
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
        \\yn : Bool → String
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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "12TF!\n" });

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
        \\helper : Int → Int
        \\helper n =
        \\    n + 1
        \\
        \\
        \\pub exported : Int → String
        \\exported n =
        \\    String.fromInt (helper n)
        \\
        \\
        \\private : Int → Int
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

test "a --library --release build keeps every core/Schema value it exports, even one called once" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `core/Schema` exports each core-private value the specialised path
    // calls from other modules (`schema.md` §6) when it survives. Under
    // `--schema-library` no worker calls them, and inside `core/Schema` one
    // of them may be called from one place: a compiled maker's worker calls
    // `belowBackward` once. A release build writes a function called from
    // one place where it is called (`backend.md` §9), and it did that to
    // such a value too, so no declaration was left. A `--library` build,
    // whose modules are files of their own, then exported a name its file
    // never declared, and Node refused to load the module at all.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Lib.beni",
        \\import Schema
        \\
        \\
        \\pub schema Point =
        \\    x : Int
        \\    y : Int
        \\
        \\
        \\pub shown : Point.Type → String
        \\shown p =
        \\    case Point.print p of
        \\        Ok text →
        \\            text
        \\
        \\        Err _ →
        \\            "failed"
        \\
    );
    try w.write("check.mjs",
        \\await import("./out/Lib.mjs");
        \\console.log("loaded");
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "build", "--platform=node", "--library", "--release", "--schema-library", "--out=out", "Lib.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try w.expectProgram("check.mjs", .{ .stdout = "loaded\n" });
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
    // possible proof that nothing lowered it. `?` compiles now, so
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
        \\pub parse : String → Maybe Int
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

// `build --out` must not only ever add to the directory, or a module the
// program stopped using would stay in `out/` beside it. `backend.md` §2, *The output directory holds what the last
// build wrote*: a build removes what the previous one wrote and it did not,
// through `_manifest.txt`, and touches nothing it never wrote.
test "a rebuild into the same --out holds exactly a fresh build's files, and a user's file survives" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Half.beni", "pub half : Int → Int\nhalf n =\n    n // 2\n");
    try w.write("src/Deep/Half.beni", "pub quarter : Int → Int\nquarter n =\n    n // 4\n");
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
    try w.expectProgram("out/_main.mjs", .{ .stdout = "x\n" });

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

test "a file beni wrote and the user then edited, or a record line leaving --out, is never removed" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Half.beni", "pub half : Int → Int\nhalf n =\n    n // 2\n");
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

test "a refused build removes nothing and leaves the record as it was" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Half.beni", "pub half : Int → Int\nhalf n =\n    n // 2\n");
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

// The stale pass must not compare an old record's paths with the new
// build's byte for byte. A build writing `Zz.mjs`, then one writing
// `ZZ.mjs`: on APFS and NTFS those names are ONE file, the second build's
// write lands in it, and a byte-for-byte pass would read the file just
// written, find the first build's hash (a `--release` module of identical
// content has it) and delete it. Linux cannot fold case, so the
// case-folding file system is simulated the way it behaves: `ZZ.mjs` is made
// a second name (a hard link) of `Zz.mjs` before the second build, so the
// write goes into the one file under either name. `--out` is absolute so
// that the harness's own folding check (`world.zig`), which would see the
// two names, leaves this tree to the scenario.
test "a stale path that is the same file as a written one under case folding is not removed" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeCaseRename(&w);
    const out = try std.fmt.allocPrint(w.arena.allocator(), "--out={s}/out", .{try w.projectPath()});
    const first = try w.run(&.{ "build", "--platform=node", "--release", "--library", out, "--root=one", "one" });
    try testing.expectEqual(@as(u8, 0), first.exit_code);
    try w.hardLink("out/Zz.mjs", "out/ZZ.mjs");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const second = try w.run(&.{ "build", "--platform=node", "--release", "--library", out, "--root=two", "two" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), second.exit_code);
    try testing.expectEqualStrings("", second.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The one file keeps both of its names: on APFS, the one name it has.
    try testing.expect(w.exists("out/Zz.mjs"));
    try testing.expectEqual(@as(u64, 2), try w.linkCount("out/ZZ.mjs"));
    const record = try w.read("out/_manifest.txt");
    try testing.expect(std.mem.indexOf(u8, record, " ZZ.mjs\n") != null);
    try testing.expect(std.mem.indexOf(u8, record, " Zz.mjs\n") == null);
}

// The other half: where the two names are two files — Linux, and any
// case-sensitive file system — the older is stale like any other and goes,
// so `--out` is still exactly what a fresh build writes.
test "a stale path equal to a written one under case folding but another file is removed" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeCaseRename(&w);
    const first = try w.run(&.{ "build", "--platform=node", "--release", "--library", "--out=out", "--root=one", "one" });
    try testing.expectEqual(@as(u8, 0), first.exit_code);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const second = try w.run(&.{ "build", "--platform=node", "--release", "--library", "--out=out", "--root=two", "two" });
    const fresh = try w.run(&.{ "build", "--platform=node", "--release", "--library", "--out=fresh", "--root=two", "two" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), second.exit_code);
    try testing.expectEqualStrings("", second.stderr);
    try testing.expectEqual(@as(u8, 0), fresh.exit_code);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    const want = try w.listFiles("fresh");
    const got = try w.listFiles("out");
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| try testing.expectEqualStrings(a, b);
    try testing.expect(!w.exists("out/Zz.mjs"));
}

/// Two projects that differ only by the case of one module's name, `Zz` and
/// `ZZ`, with byte-identical `--release --library` output for it. Both sort
/// after `Main`, so their one export gets the same short name; `Ab` and `AB`
/// do not (`const b` against `const c`), and a hash would then tell them
/// apart where APFS does not. `--library`, because a release APPLICATION is
/// one scope-hoisted file and writes no module file to collide
/// (`backend.md` §9).
fn writeCaseRename(w: *World) !void {
    const lib = "pub one : Int\none =\n    1\n";
    try w.write("one/Zz.beni", lib);
    try w.write("one/Main.beni", "import Node exposing (Program)\nimport Zz\nimport String\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt Zz.one ]\n");
    try w.write("two/ZZ.beni", lib);
    try w.write("two/Main.beni", "import Node exposing (Program)\nimport ZZ\nimport String\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt ZZ.one ]\n");
}

// A `_manifest.txt` in `--out` that beni did not write must not read as an
// empty record and be overwritten. `backend.md` §2: a file of that name that does not parse as
// beni's record refuses the build before anything is written.
test "a _manifest.txt beni did not write refuses the build and nothing is written" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.printLines [ \"x\" ]\n");
    try w.write("out/_manifest.txt", "my own notes\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .unknown_output_record,
        .severity = .@"error",
        .span = .{ .file = "out/_manifest.txt", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
        .title = "UNKNOWN FILE IN THE OUTPUT DIRECTORY",
        .message = "The output directory already holds a `_manifest.txt` that beni did not write.\n" ++
            "\n" ++
            "A build records the files it writes in `out/_manifest.txt` and, on the next\n" ++
            "build, removes the ones that build no longer writes (`docs/design/backend.md`\n" ++
            "§2). This file does not begin with `beni-manifest 1`, or has a line that is not\n" ++
            "a record line, so it is somebody else's, and writing the record would overwrite\n" ++
            "it. Nothing was written. Move the file, or build into another directory with\n" ++
            "`--out`.",
    }, r.diagnostics[0]);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings("my own notes\n", try w.read("out/_manifest.txt"));
    const left = try w.listFiles("out");
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings("_manifest.txt", left[0]);
}

// A `_manifest.txt` in `--out` that cannot be read (mode 000) says nothing
// about whose it is: the build reports the read failure, as it does for a
// source it cannot read, and writes nothing. It was reported as a file
// "that does not begin with `beni-manifest 1`", which nobody could tell.
test "an unreadable _manifest.txt refuses the build as a read failure and nothing is written" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.printLines [ \"x\" ]\n");
    try w.write("out/_manifest.txt", "beni-manifest 1\n");
    if (!try w.makeUnreadable("out/_manifest.txt")) {
        std.debug.print("skipping: chmod 000 did not make the file unreadable (running as root?)\n", .{});
        return;
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=node", "--out=out", "--diagnostics=json", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings("beni: cannot read 'out/_manifest.txt': AccessDenied\n", r.stderr);
    try testing.expectEqualStrings("", r.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    const left = try w.listFiles("out");
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings("_manifest.txt", left[0]);
}

// beni makes no symbolic link in `--out`, so one there is somebody else's,
// and writing its path would write wherever it points. A dangling
// `_manifest.txt` link read as "no record", and the build wrote the record
// through it, creating the link's target outside `--out`. The link is
// refused, named, before anything is written.
test "a _manifest.txt that is a symbolic link refuses the build and nothing is written through it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.printLines [ \"x\" ]\n");
    try w.createDir("elsewhere");
    try w.symlink("../elsewhere/manifest", "out/_manifest.txt");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
        .code = .unknown_output_record,
        .severity = .@"error",
        .span = .{ .file = "out/_manifest.txt", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
        .title = "UNKNOWN FILE IN THE OUTPUT DIRECTORY",
        .message = "`out/_manifest.txt` is a symbolic link, and beni never makes one in the output\n" ++
            "directory, so it is somebody else's.\n" ++
            "\n" ++
            "This build writes that file, and writing through the link would write into\n" ++
            "whatever it points at, which may be outside the output directory altogether.\n" ++
            "Nothing was written. Remove the link, or build into another directory with\n" ++
            "`--out`.",
    }}, r.diagnostics);
    try testing.expectEqualStrings("", r.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("elsewhere/manifest"));
    try testing.expectEqual(@as(usize, 0), (try w.listFiles("elsewhere")).len);
    // The link is left as it was, and nothing else is in `--out`
    // (`listFiles` lists regular files only).
    try testing.expectEqual(std.Io.File.Kind.sym_link, try w.kind("out/_manifest.txt"));
    try testing.expectEqual(@as(usize, 0), (try w.listFiles("out")).len);
}

// The same rule for a directory the build writes into: `out/_platform` a
// link to a directory elsewhere would put the platform's runtime there. The
// link is named, with the file the build would have written through it.
test "an output directory that is a symbolic link refuses the build and nothing is written through it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.printLines [ \"x\" ]\n");
    try w.createDir("elsewhere");
    try w.symlink("../elsewhere", "out/_platform");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
        .code = .unknown_output_record,
        .severity = .@"error",
        .span = .{ .file = "out/_platform", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
        .title = "UNKNOWN FILE IN THE OUTPUT DIRECTORY",
        .message = "`out/_platform` is a symbolic link, and beni never makes one in the output\n" ++
            "directory, so it is somebody else's.\n" ++
            "\n" ++
            "This build writes `out/_platform/Node.mjs` inside it, and writing through the\n" ++
            "link would write into whatever it points at, which may be outside the output\n" ++
            "directory altogether. Nothing was written. Remove the link, or build into\n" ++
            "another directory with `--out`.",
    }}, r.diagnostics);
    try testing.expectEqualStrings("", r.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(usize, 0), (try w.listFiles("elsewhere")).len);
    try testing.expectEqual(std.Io.File.Kind.sym_link, try w.kind("out/_platform"));
    try testing.expect(!w.exists("out/_main.mjs"));
    try testing.expect(!w.exists("out/Main.mjs"));
    try testing.expect(!w.exists("out/_manifest.txt"));
}

// A record that cannot be written is reported by its own path, as every
// other output is: an `--out` whose mode forbids creating files failed as
// "cannot write 'out'", the directory's name, which says nothing of which
// file the build was writing.
test "a _manifest.txt that cannot be written is reported by its own path" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.printLines [ \"x\" ]\n");
    try w.createDir("out");
    defer w.restoreDirMode("out");
    if (!try w.makeDirUnwritable("out")) {
        std.debug.print("skipping: chmod 555 did not make the directory unwritable (running as root?)\n", .{});
        return;
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=node", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings("beni: cannot write 'out/_manifest.txt': AccessDenied\n", r.stderr);
    try testing.expectEqualStrings("", r.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(usize, 0), (try w.listFiles("out")).len);
}

test "--release writes a map only when asked, and asking changes no byte of the code" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §2, §11.2: `--release` alone writes no map and no
    // comment line, and `--no-source-maps` says so. `--source-maps` writes
    // the same code: each file it maps has one comment line more and a map
    // beside it, and every other file is byte for byte the same. Both
    // layouts: an application is one scope-hoisted file, a library one
    // file per module. The maps do not depend on `--jobs` (rule 5).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Aid.beni",
        \\import String
        \\
        \\
        \\pub label : Int → String
        \\label n =
        \\    doubled =
        \\        n * 2
        \\    "n = " ++ String.fromInt (doubled + doubled)
        \\
    );
    try w.write("Main.beni",
        \\import Aid
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ Aid.label 1, Aid.label 20 ]
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const plain = try w.runWith(&.{ "build", "--platform=node", "--release", "--out=plain", "Main.beni", "Aid.beni" }, .{ .raw_diagnostics = true });
    const stated = try w.runWith(&.{ "build", "--platform=node", "--release", "--no-source-maps", "--out=stated", "Main.beni", "Aid.beni" }, .{ .raw_diagnostics = true });
    const many = try w.runWith(&.{ "build", "--platform=node", "--release", "--source-maps", "--jobs=8", "--out=mapped", "Main.beni", "Aid.beni" }, .{ .raw_diagnostics = true });
    const one = try w.runWith(&.{ "build", "--platform=node", "--release", "--source-maps", "--jobs=1", "--out=one", "Main.beni", "Aid.beni" }, .{ .raw_diagnostics = true });
    const lib = try w.runWith(&.{ "build", "--platform=node", "--release", "--library", "--out=lib", "Aid.beni" }, .{ .raw_diagnostics = true });
    const lib_mapped = try w.runWith(&.{ "build", "--platform=node", "--release", "--library", "--source-maps", "--out=lib-mapped", "Aid.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]world.Result{ plain, stated, many, one, lib, lib_mapped }) |r| try expectBuilt(r);
    try w.expectProgram("plain/_main.mjs", .{ .stdout = "n = 4\nn = 80\n" });
    try w.expectProgram("mapped/_main.mjs", .{ .stdout = "n = 4\nn = 80\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    for ([_][]const u8{ "plain", "lib" }) |dir| for (try w.listFiles(dir)) |path| {
        try testing.expect(!std.mem.endsWith(u8, path, ".map"));
        const bytes = try w.read(try std.fmt.allocPrint(w.arena.allocator(), "{s}/{s}", .{ dir, path }));
        try testing.expect(std.mem.indexOf(u8, bytes, "sourceMappingURL") == null);
    };
    try expectSameTree(&w, "plain", "stated");
    // The application's one map is the hoisted file's; the library's, one
    // per emitted module.
    try testing.expectEqual(@as(usize, 1), try expectMappedTree(&w, "plain", "mapped"));
    try testing.expect(try expectMappedTree(&w, "lib", "lib-mapped") >= 2);
    try expectSameTree(&w, "mapped", "one");
}

/// `mapped_dir` is `plain_dir` built with `--source-maps` (`backend.md`
/// §11.2): the same files, a mapped one with its comment line after its
/// last byte and its map beside it, and nothing else. The manifest, which
/// lists the maps too, is the one file that differs otherwise. Returns how
/// many maps there are.
fn expectMappedTree(w: *World, plain_dir: []const u8, mapped_dir: []const u8) !usize {
    const arena = w.arena.allocator();
    const plain = try treeOf(w, plain_dir);
    const mapped = try treeOf(w, mapped_dir);
    var maps: usize = 0;
    for (mapped) |name| {
        if (!std.mem.endsWith(u8, name, ".map")) continue;
        maps += 1;
        var beside = false;
        for (plain) |p| beside = beside or std.mem.eql(u8, p, name[0 .. name.len - ".map".len]);
        try testing.expect(beside);
    }
    try testing.expectEqual(plain.len + maps, mapped.len);
    for (plain) |name| {
        if (std.mem.eql(u8, name, "_manifest.txt")) continue;
        const a = try w.read(try std.fmt.allocPrint(arena, "{s}/{s}", .{ plain_dir, name }));
        const b = try w.read(try std.fmt.allocPrint(arena, "{s}/{s}", .{ mapped_dir, name }));
        if (!w.exists(try std.fmt.allocPrint(arena, "{s}/{s}.map", .{ mapped_dir, name }))) {
            try testing.expectEqualStrings(a, b);
            continue;
        }
        const comment = try std.fmt.allocPrint(arena, "//# sourceMappingURL={s}.map\n", .{std.fs.path.basenamePosix(name)});
        try testing.expectEqualStrings(try std.mem.concat(arena, u8, &.{ a, comment }), b);
    }
    return maps;
}

test "a release application is one file with no import or export; --library keeps every module and export" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Twice.twice` is `pub` and reachable, and so is `Twice.inc`, which
    // only `twice` calls. In a development build both are exported. Under
    // `--release` an application's output tree is the whole program, and it
    // is ONE scope-hoisted file (`backend.md` §9): no module imports another,
    // so nothing is exported at all, and the runtime's `node:process` is the
    // only `import`. A `--library` build's exports are its public surface
    // (`backend.md` §9's *Roots*) and are all kept, one module to a file.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Twice.beni",
        \\pub inc : Int → Int
        \\inc n =
        \\    n + 1
        \\
        \\
        \\pub twice : Int → Int
        \\twice n =
        \\    inc (inc n)
        \\
    );
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\import String
        \\import Twice
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (Twice.twice 40))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=node", "--release", "--out=out", "Main.beni", "Twice.beni" }, .{ .raw_diagnostics = true });
    const lib = try w.runWith(&.{ "build", "--platform=node", "--release", "--library", "--out=lib", "Main.beni", "Twice.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
    try expectBuilt(lib);
    const tree = try treeOf(&w, "out");
    try testing.expectEqual(@as(usize, 2), tree.len);
    try testing.expectEqualStrings("_main.mjs", tree[0]);
    try testing.expectEqualStrings("_manifest.txt", tree[1]);
    const one = try w.read("out/_main.mjs");
    try testing.expect(std.mem.startsWith(u8, one, "import process from\"node:process\";"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, one, "\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, one, "import"));
    try testing.expect(std.mem.indexOf(u8, one, "export") == null);
    try testing.expect(std.mem.endsWith(u8, try w.read("lib/Twice.mjs"), ";export{e,c};\n"));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "42\n" });
}

/// A platform whose hand-written JavaScript has what a release build must
/// keep exactly — a regular expression with spaces in it, a template literal
/// nesting another, a helper named only inside a substitution — and what
/// it may drop: comments, an export the program never imports and the
/// helper only that export uses (backend.md §9, *Hand-written JavaScript
/// under `--release`*).
fn writeHandPlatform(w: *World) !void {
    try w.write("hand/beni.json",
        \\{ "platform": true, "name": "hand", "program": "Hand.Program", "runtime": "run.js" }
    );
    try w.write("hand/Hand.beni",
        \\pub foreign type Program
        \\
        \\
        \\pub foreign pure say : String → Program
        \\
        \\
        \\pub foreign pure shout : String → Program
        \\
    );
    try w.write("hand/Hand.js", hand_sibling);
    try w.write("hand/run.js", hand_runtime);
    try w.write("Main.beni",
        \\import Hand exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Hand.say "a  b   c"
        \\
    );
}

const hand_sibling =
    \\// The sibling of `Hand.beni`.
    \\
    \\const spaces = / +/g;
    \\
    \\/* Named only inside a substitution below. */
    \\const upper = (s) => s.toUpperCase();
    \\
    \\// Used only by `shout`, which the program never calls.
    \\const exclaim = (s) => `${s}!`;
    \\
    \\export const say = (line) => ({
    \\  text: `[${ upper(line.replace(spaces, " ")) }] ${ `(${ line.length })` }`,
    \\});
    \\
    \\export const shout = (line) => ({ text: exclaim(line) });
    \\
;

const hand_runtime =
    \\import process from "node:process";
    \\
    \\// Writes the program's one line.
    \\export const run = (program) => {
    \\  process.stdout.write(program.text + "\n");
    \\};
    \\
    \\export const unused = () => process.exit(3);
    \\
;

test "a release build compacts hand-written JavaScript and cuts it to what the program imports" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeHandPlatform(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=hand", "--release", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
    // One scope-hoisted file (`backend.md` §9, *One scope-hoisted file
    // under `--release`*), in the order ES would evaluate the multi-file
    // layout: the runtime, which the entry file imports first, then the
    // sibling, then `Main`, then the entry's own call.
    //
    // Names: the emitted modules' first — `say` as `Main` imports it, `a`,
    // and `main`, `b` — then the hand-written files' top-level bindings in
    // file order and source order: the runtime's `run`, `c`, the sibling's
    // `spaces` and `upper`, `d` and `e`. Every other name of a hand-written
    // file is renamed around its file's (research 40's A2).
    //
    // The runtime: `run` is what the entry file calls; `unused` is nobody's.
    // Its `import` of `node:process` goes to the top of the file, and
    // `process`, bound by it, keeps its name. The block loses its last `;`
    // (A3).
    //
    // The sibling: the regular expression and both template literals are
    // as written; `upper` survives because a substitution names it; `shout`,
    // `exclaim` and every comment are gone; `text`, an object key, is not a
    // binding.
    try testing.expectEqualStrings(
        \\import process from"node:process";const c=a=>{process.stdout.write(a.text+"\n")};const d=/ +/g;const e=c=>c.toUpperCase();const a=b=>({text:`[${e(b.replace(d," "))}] ${`(${b.length})`}`,});const b=a("a  b   c");c(b);
        \\
    , try w.read("out/_main.mjs"));
    try testing.expectEqual(@as(usize, 2), (try treeOf(&w, "out")).len);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "[A B C] (8)\n" });
}

test "a sibling whose names cannot move keeps its own module in a release application" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A sibling that mentions `class` is one A2 renames nothing in
    // (research 40 §7), so its top-level names could collide with the one
    // scope's. It is declined: written as the multi-file layout writes it,
    // and imported by the one file. Evaluating it does nothing (every
    // top-level statement is a function), so evaluating it before the rest
    // of the program rather than where it stood is invisible (`backend.md`
    // §9, *One scope-hoisted file under `--release`*).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeHandPlatform(&w);
    try w.write("hand/Hand.js",
        \\export const say = (line) => {
        \\  const Line = class {};
        \\  return Object.assign(new Line(), { text: `<${line}>` });
        \\};
        \\
        \\export const shout = (line) => ({ text: line });
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=hand", "--release", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
    try testing.expectEqualStrings(
        \\import process from"node:process";import{say as a}from"./_platform/Hand.foreign.mjs";const c=a=>{process.stdout.write(a.text+"\n")};const b=a("a  b   c");c(b);
        \\
    , try w.read("out/_main.mjs"));
    try testing.expect(w.exists("out/_platform/Hand.foreign.mjs"));
    try testing.expectEqual(@as(usize, 3), (try treeOf(&w, "out")).len);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "<a  b   c>\n" });
}

test "a sibling that must keep its module and does something when evaluated keeps the multi-file layout" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // As above, but the sibling's `started` calls a function when the
    // sibling is evaluated. A module of its own is evaluated before the
    // whole of the one file, which moves that call; `backend.md` §9 then
    // writes the program as it would without hoisting, one module per file.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeHandPlatform(&w);
    try w.write("hand/Hand.js",
        \\const started = Date.now();
        \\
        \\export const say = (line) => {
        \\  const Line = class {};
        \\  return Object.assign(new Line(), { text: started > 0 ? line : "" });
        \\};
        \\
        \\export const shout = (line) => ({ text: line });
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=hand", "--release", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
    try testing.expect(w.exists("out/Main.mjs"));
    try testing.expect(w.exists("out/_platform/run.foreign.mjs"));
    try testing.expect(std.mem.startsWith(u8, try w.read("out/_main.mjs"), "import{run}from\"./_platform/run.foreign.mjs\";\n"));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "a  b   c\n" });
}

test "a sibling export that is also an object key keeps its name and is aliased in a release application" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `say` stands before `:` as a key, where renaming the name would rename
    // the key, so A2 keeps it as written (research 40 §7). In the one scope
    // it is `say`, and `Main`, which imports it under a short name, reads it
    // through `let <short>=say;` after the sibling (`backend.md` §9) — a
    // copy, sound because nothing assigns `say`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeHandPlatform(&w);
    try w.write("hand/Hand.js",
        \\const table = { say: "!" };
        \\
        \\export const say = (line) => ({ text: line + table.say });
        \\
        \\export const shout = (line) => ({ text: line });
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=hand", "--release", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
    try testing.expectEqualStrings(
        \\import process from"node:process";const c=a=>{process.stdout.write(a.text+"\n")};const d={say:"!"};const say=a=>({text:a+d.say});const a=say;const b=a("a  b   c");c(b);
        \\
    , try w.read("out/_main.mjs"));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "a  b   c!\n" });
}

test "a release page ships the browser runtime's map only when it maps" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Html.map`'s runtime export is cut from a program that never maps
    // (backend.md §9; research 41 §5.4): no other binding of the runtime
    // may share its name, since a lexical pass counts every mention of a
    // name as a use. The page has a keyed list, so the reconciler that
    // once declared a local `map` is kept.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const page =
        \\import Browser
        \\import Html exposing (Html)
        \\
        \\
        \\view : List Int → Html msg
        \\view xs =
        \\    <ul><For each={xs}>{λx → <li>{x}</li>}</For></ul>
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.program { init = λ⊤ → [ 1, 2 ], update = λmsg model → model, view = view }
        \\
    ;
    try w.write("plain/Main.beni", page);
    try w.write("mapped/Main.beni",
        \\import Browser
        \\import Html exposing (Html)
        \\
        \\
        \\view : List Int → Html msg
        \\view xs =
        \\    Html.map (<ul><For each={xs}>{λx → <li>{x}</li>}</For></ul>) λmsg → msg
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.program { init = λ⊤ → [ 1, 2 ], update = λmsg model → model, view = view }
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const plain = try w.runWith(&.{ "build", "--platform=browser", "--release", "--out=plain-out", "plain/Main.beni" }, .{ .raw_diagnostics = true });
    const mapped = try w.runWith(&.{ "build", "--platform=browser", "--release", "--out=mapped-out", "mapped/Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(plain);
    try expectBuilt(mapped);
    // A release application is one scope-hoisted file, so names are gone;
    // `Html.map`'s kind is the one object literal with an `up` key.
    const plain_js = try w.read("plain-out/_main.mjs");
    const mapped_js = try w.read("mapped-out/_main.mjs");
    try testing.expect(std.mem.indexOf(u8, plain_js, "up:") == null);
    try testing.expect(std.mem.indexOf(u8, mapped_js, "up:") != null);
}

test "a release page ships the hosted program's loop only when it mounts one" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The dispatcher, the after-render phase and `flush`'s guards are a
    // hosted program's (`boundary.md` §9.8): a page that mounts only
    // `Browser.program` must not ship them, so the runtime's always-kept
    // loop may not name them (research 40 §8, rule 2). Each of them
    // guards with `try`/`finally`, which nothing else an empty page keeps
    // writes.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("plain/Main.beni",
        \\import Browser
        \\import Html exposing (Html)
        \\
        \\
        \\view : Int → Html msg
        \\view _ =
        \\    <></>
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.program { init = λ⊤ → 0, update = λmsg model → model, view = view }
        \\
    );
    try w.write("hosted/Main.beni",
        \\import Browser
        \\import Html exposing (Html)
        \\
        \\
        \\view : Int → Html msg
        \\view _ =
        \\    <></>
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.hosted { init = λhost → 0, update = λhost msg model → model, settle = λhost model → model, view = view }
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const plain = try w.runWith(&.{ "build", "--platform=browser", "--release", "--out=plain-out", "plain/Main.beni" }, .{ .raw_diagnostics = true });
    const hosted = try w.runWith(&.{ "build", "--platform=browser", "--release", "--out=hosted-out", "hosted/Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(plain);
    try expectBuilt(hosted);
    const plain_js = try w.read("plain-out/_main.mjs");
    const hosted_js = try w.read("hosted-out/_main.mjs");
    // Every page guards `run` and `flush` with a `try … finally` that stops
    // it on a defect (`boundary.md` §9.8.10 (c)); the hosted loop adds its
    // own three latches, the dispatcher's, the render's and the
    // after-render phase's.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, plain_js, "finally"));
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, hosted_js, "finally"));
}

test "a page with no delegated event calls no start and ships no listener" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Start data with no pair is no call (`boundary.md` §9.4.5, amended
    // 2026-10-02): `start({})` did nothing, and kept the delegated
    // listener that `start` names, the one `addEventListener` of an
    // empty page.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const head =
        \\import Browser
        \\import Html exposing (Html)
        \\
        \\
        \\type Msg
        \\    = Clicked
        \\
        \\
        \\view : Int → Html Msg
        \\view _ =
        \\
    ;
    const tail =
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.program { init = λ⊤ → 0, update = λmsg model → model + 1, view = view }
        \\
    ;
    try w.write("quiet/Main.beni", head ++ "    <p>still</p>" ++ tail);
    try w.write("clicks/Main.beni", head ++ "    <button onClick={Clicked}>go</button>" ++ tail);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const quiet = try w.runWith(&.{ "build", "--platform=browser", "--release", "--out=quiet-out", "quiet/Main.beni" }, .{ .raw_diagnostics = true });
    const clicks = try w.runWith(&.{ "build", "--platform=browser", "--release", "--out=clicks-out", "clicks/Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(quiet);
    try expectBuilt(clicks);
    try testing.expect(std.mem.indexOf(u8, try w.read("quiet-out/_main.mjs"), "addEventListener") == null);
    try testing.expect(std.mem.indexOf(u8, try w.read("clicks-out/_main.mjs"), "addEventListener") != null);
}

test "a `via` that is not `pub` ships only when a surviving root names its event" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `checker-v2.md` §25.8, amended 2026-10-21: an extractor that is not
    // `pub` is kept by the vocabulary row's name, so it is exported, and
    // its sibling export kept, only when a root that survives names its
    // event. Two such extractors in one vocabulary; the page names one.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("platform/beni.json",
        \\{
        \\  "platform": true,
        \\  "name": "probe",
        \\  "platforms": ["browser"],
        \\  "reexports": ["Html", "Browser"],
        \\  "markup": { "vocabulary": "Probe", "type": "Html.Html" }
        \\}
        \\
    );
    try w.write("platform/Probe.beni",
        \\import Html exposing (Html)
        \\
        \\
        \\pub foreign type Event
        \\
        \\
        \\pub markup text : String → Html msg
        \\
        \\
        \\pub markup map : Html a, (a → b) → Html b
        \\
        \\
        \\pub element "*"
        \\
        \\
        \\pub attribute "*" : String
        \\
        \\
        \\pub event "onProbe" name "probe" via probe : String
        \\
        \\
        \\pub event "onOther" name "other" via other : String
        \\
        \\
        \\foreign impure probe : Event → String
        \\
        \\
        \\foreign impure other : Event → String
        \\
    );
    try w.write("platform/Probe.js",
        \\export const probe = (e) => `dropped ${e.detail}`;
        \\export const other = (e) => `kept ${e.detail}`;
        \\
    );
    try w.write("Main.beni",
        \\import Browser
        \\import Html exposing (Html)
        \\
        \\
        \\view : String → Html String
        \\view text =
        \\    <button onOther={λvalue → value}>{text}</button>
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.program { init = λ⊤ → "none", update = λnext _ → next, view = view }
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dev = try w.runWith(&.{ "build", "--platform=platform", "--out=dev", "Main.beni" }, .{ .raw_diagnostics = true });
    const release = try w.runWith(&.{ "build", "--platform=platform", "--release", "--out=release", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(dev);
    try expectBuilt(release);
    const vocabulary = try w.read("dev/_platform/Probe.mjs");
    try testing.expect(std.mem.indexOf(u8, vocabulary, "Probe$other") != null);
    try testing.expect(std.mem.indexOf(u8, vocabulary, "Probe$probe") == null);
    const shipped = try w.read("release/_main.mjs");
    try testing.expect(std.mem.indexOf(u8, shipped, "`kept ") != null);
    try testing.expect(std.mem.indexOf(u8, shipped, "`dropped ") == null);
}

/// A page on `Tea.element` whose `update` returns `cmd`, for the two tests
/// below.
fn elementPage(comptime cmd: []const u8) []const u8 {
    return
    \\import Browser
    \\import Cmd
    \\import Html exposing (Html)
    \\import Random
    \\import Sub
    \\import Tea
    \\import Time
    \\
    \\
    \\view : Int → Html msg
    \\view _ =
    \\    <></>
    \\
    \\
    \\main : Browser.Program
    \\main =
    \\    Tea.element { init = λ⊤ → ( 0, Cmd.none ), update = λmsg model → ( model,
    ++ cmd ++
        \\ ), view = view, subscriptions = λ_ → Sub.none }
        \\
    ;
}

test "an element whose commands are all Cmd.none ships no fiber runtime" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Tea.element`'s command table and subscription diff name the fiber
    // runtime only in the arms for `Cmd`'s items and `Sub.Listen`, which a
    // program that never asks for work never builds (`backend.md` §9, *A
    // `case` arm on a constructor nothing builds*). A fiber's record is the
    // one place the runtime writes `interrupted`; the page that performs a
    // command that may wait ships it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("none/Main.beni", elementPage("Cmd.none"));
    try w.write("waits/Main.beni", elementPage("Cmd.do λ⊤ → Time.sleep (Time.millis 1)"));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const none = try w.runWith(&.{ "build", "--platform=browser-tea", "--release", "--out=none-out", "none/Main.beni" }, .{ .raw_diagnostics = true });
    const waits = try w.runWith(&.{ "build", "--platform=browser-tea", "--release", "--out=waits-out", "waits/Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(none);
    try expectBuilt(waits);
    try testing.expect(std.mem.indexOf(u8, try w.read("none-out/_main.mjs"), "interrupted") == null);
    try testing.expect(std.mem.indexOf(u8, try w.read("waits-out/_main.mjs"), "interrupted") != null);
}

test "an element whose commands never wait ships no fiber runtime" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A command whose body never waits runs with no fiber (`boundary.md`
    // §9.8.11): `Cmd.perform` and `Cmd.keyed` build `Now` and `KeyedNow`
    // for it, decided where the command is made, and the arms that start a
    // fiber are on `Perform` and `Keyed`, which these pages never build.
    // `Random.generate` is `Cmd.task` over `Random.value`, which never
    // waits; the keyed body only sends.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("random/Main.beni", elementPage("Random.generate (Random.int 1 6) λn → n"));
    try w.write("keyed/Main.beni", elementPage("Cmd.keyed ⊤ Cmd.Restart λsend → send 1"));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const random = try w.runWith(&.{ "build", "--platform=browser-tea", "--release", "--out=random-out", "random/Main.beni" }, .{ .raw_diagnostics = true });
    const keyed = try w.runWith(&.{ "build", "--platform=browser-tea", "--release", "--out=keyed-out", "keyed/Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(random);
    try expectBuilt(keyed);
    try testing.expect(std.mem.indexOf(u8, try w.read("random-out/_main.mjs"), "interrupted") == null);
    try testing.expect(std.mem.indexOf(u8, try w.read("keyed-out/_main.mjs"), "interrupted") == null);
}

fn taskPage(comptime cmd: []const u8) []const u8 {
    return
    \\import Browser
    \\import Cmd
    \\import Html exposing (Html)
    \\import Sub
    \\import Task
    \\import Tea
    \\import Time
    \\
    \\
    \\view : Int → Html msg
    \\view _ =
    \\    <></>
    \\
    \\
    \\main : Browser.Program
    \\main =
    \\    Tea.element { init = λ⊤ → ( 0, Cmd.none ), update = λmsg model → ( model,
    ++ cmd ++
        \\ ), view = view, subscriptions = λ_ → Sub.none }
        \\
    ;
}

test "a page whose fibers only wait ships no finaliser walk and no children" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The fiber runtime keeps each capability behind a cell only its entry
    // point writes (`core/Task.beni`): a fiber gets children only from
    // `Task.spawn`, and holds finalisers only once something registers one
    // (`bracket`, `scope`). A page whose body only sleeps uses neither, so
    // its release build keeps `finalizers` only as the fiber record's key,
    // and never makes a fiber's set of children; the pages that bracket and
    // that spawn keep each.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("waits/Main.beni", taskPage("Cmd.do λ⊤ → Time.sleep (Time.millis 1)"));
    try w.write("brackets/Main.beni", taskPage("Cmd.do λ⊤ → Task.bracket (λ⊤ → ⊤) (λ_ _ → ⊤) λ_ → Time.sleep (Time.millis 1)"));
    try w.write("spawns/Main.beni", taskPage("Cmd.do λ⊤ → Task.join (Task.spawn λ⊤ → Time.sleep (Time.millis 1))"));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const waits = try w.runWith(&.{ "build", "--platform=browser-tea", "--release", "--out=waits-out", "waits/Main.beni" }, .{ .raw_diagnostics = true });
    const brackets = try w.runWith(&.{ "build", "--platform=browser-tea", "--release", "--out=brackets-out", "brackets/Main.beni" }, .{ .raw_diagnostics = true });
    const spawns = try w.runWith(&.{ "build", "--platform=browser-tea", "--release", "--out=spawns-out", "spawns/Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(waits);
    try expectBuilt(brackets);
    try expectBuilt(spawns);
    const only_waits = try w.read("waits-out/_main.mjs");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, only_waits, "finalizers"));
    try testing.expect(std.mem.indexOf(u8, only_waits, "children=new Set") == null);
    try testing.expect(std.mem.count(u8, try w.read("brackets-out/_main.mjs"), "finalizers") > 1);
    try testing.expect(std.mem.indexOf(u8, try w.read("spawns-out/_main.mjs"), "children=new Set") != null);
}

test "a development build copies hand-written JavaScript byte for byte" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeHandPlatform(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=hand", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
    try testing.expectEqualStrings(hand_sibling, try w.read("out/_platform/Hand.foreign.mjs"));
    try testing.expectEqualStrings(hand_runtime, try w.read("out/_platform/run.foreign.mjs"));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try w.expectProgram(world.entry_file, .{ .stdout = "[A B C] (8)\n" });
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
        \\report : Int → Int
        \\report n =
        \\    Debug.log "report" (n + 1)
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

    try w.expectProgram("dev/_main.mjs", .{ .stdout = "report: 3\n3\n" });
    try w.expectProgram("allow/_main.mjs", .{ .stdout = "report: 3\n3\n" });
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
        \\unused : Int → Int
        \\unused n =
        \\    Debug.log "unused" n
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
    try w.expectProgram(world.entry_file, .{ .stdout = "x\n" });
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
        \\pub exported : Int → String
        \\exported n =
        \\    Debug.toString n
        \\
    );
    try w.write("Quiet.beni",
        \\private : Int → String
        \\private n =
        \\    Debug.toString n
        \\
        \\
        \\pub exported : Int → Int
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
        \\pub help : Int → String
        \\help n =
        \\    Debug.toString (Debug.log "help" n)
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

/// Read a module's source map with a decoder written from the format
/// (ECMA-426) and nothing else, and print where each needle of the module
/// maps to: the segment covering its first occurrence, which is the last
/// on its line at or before it. Then run the program under Node with
/// `--enable-source-maps` and print the `.beni` frames of its crash —
/// Node's own reading of the same map.
///
/// usage: node check-map.mjs <module.mjs> <source.beni> <needle>...
const check_map_script =
    \\import { readFileSync, realpathSync } from "node:fs";
    \\import { spawnSync } from "node:child_process";
    \\import { basename } from "node:path";
    \\import { fileURLToPath, pathToFileURL } from "node:url";
    \\
    \\const [modulePath, sourcePath, ...needles] = process.argv.slice(2);
    \\const code = readFileSync(modulePath, "utf8");
    \\const comment = /\n\/\/# sourceMappingURL=([^\n]+)\n$/.exec(code);
    \\if (!comment) throw new Error("no sourceMappingURL line at the end of " + modulePath);
    \\const mapUrl = new URL(comment[1], pathToFileURL(modulePath));
    \\const map = JSON.parse(readFileSync(mapUrl, "utf8"));
    \\const source = fileURLToPath(new URL(map.sources[0], mapUrl));
    \\console.log(`version ${map.version}, file ${map.file}, sources ${map.sources.join(" ")}`);
    \\console.log(`source is the file: ${realpathSync(source) === realpathSync(sourcePath)}`);
    \\console.log(`sourcesContent is its text: ${map.sourcesContent[0] === readFileSync(sourcePath, "utf8")}`);
    \\
    \\const digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    \\const lines = [];
    \\const state = [0, 0, 0, 0, 0];
    \\for (const line of map.mappings.split(";")) {
    \\  const segments = [];
    \\  state[0] = 0;
    \\  for (const text of line ? line.split(",") : []) {
    \\    const fields = [];
    \\    let value = 0, shift = 0;
    \\    for (const ch of text) {
    \\      const d = digits.indexOf(ch);
    \\      if (d < 0) throw new Error("not a base64 digit: " + ch);
    \\      value += (d & 31) << shift;
    \\      if (d & 32) { shift += 5; continue; }
    \\      fields.push(value & 1 ? -(value >>> 1) : value >>> 1);
    \\      value = 0; shift = 0;
    \\    }
    \\    if (fields.length !== 4 && fields.length !== 5) throw new Error("a segment of " + fields.length + " fields: " + text);
    \\    fields.forEach((delta, i) => { state[i] += delta; });
    \\    segments.push({ column: state[0], source: state[1], line: state[2], sourceColumn: state[3], name: fields.length === 5 ? map.names[state[4]] : null });
    \\  }
    \\  lines.push(segments);
    \\}
    \\
    \\for (const needle of needles) {
    \\  const at = code.indexOf(needle);
    \\  if (at < 0) throw new Error("not in the module: " + needle);
    \\  const before = code.slice(0, at).split("\n");
    \\  const line = before.length - 1, column = before[line].length;
    \\  const hit = (lines[line] ?? []).filter((s) => s.column <= column).pop();
    \\  const where = hit ? `${basename(map.sources[hit.source])}:${hit.line + 1}:${hit.sourceColumn + 1}` : "unmapped";
    \\  console.log(`${needle} -> ${where}${hit?.name ? " " + hit.name : ""}`);
    \\}
    \\
    \\const run = spawnSync(process.execPath, ["--enable-source-maps", "out/_main.mjs"], { encoding: "utf8" });
    \\for (const frame of run.stderr.matchAll(/^\s+at (\S+) \((?:.*\/)?([^\/]+\.beni:\d+:\d+)\)$/gm)) {
    \\  console.log(`frame ${frame[1]} ${frame[2]}`);
    \\}
    \\console.log(`exit ${run.status}`);
    \\
;

test "a development build maps a crash in a case arm back to the beni line and column" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §11: every module of a development build has a map
    // beside it, and a frame of a crash, a call in a `case` arm, an arm's
    // test and a declaration's name each map to the token that wrote them.
    // The source is under `src/` and the output under `out/`, so the map's
    // `sources` climbs out of the output tree to the file itself.
    // `Debug.todo` is beni (`core/Debug.beni`), so the crash's first frame
    // is its `throw`, mapped into core's own source.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\type Step
        \\    = Go Int
        \\    | Stop
        \\
        \\
        \\describe : Step → String
        \\describe step =
        \\    case step of
        \\        Go n →
        \\            String.fromInt (twice n)
        \\
        \\        Stop →
        \\            Debug.todo "stop is not done"
        \\
        \\
        \\twice : Int → Int
        \\twice n =
        \\    n * 2
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ describe (Go 21), describe Stop ]
        \\
    );
    try w.write("check-map.mjs", check_map_script);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=node", "--out=out", "src" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);
    const checked = try w.runNode(&.{
        "check-map.mjs",
        "out/Main.mjs",
        "src/Main.beni",
        "Debug$todo(",
        "String$fromInt(",
        "Main$twice(n",
        "if (step$1",
        "const Main$twice",
        "Main$twice =",
        "(n$1) =>",
        "n$1 * 2",
        "Main$describe(Main$Stop",
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings("", checked.stderr);
    try testing.expectEqualStrings(
        \\version 3, file Main.mjs, sources ../src/Main.beni
        \\source is the file: true
        \\sourcesContent is its text: true
        \\Debug$todo( -> Main.beni:17:13
        \\String$fromInt( -> Main.beni:14:13
        \\Main$twice(n -> Main.beni:14:29
        \\if (step$1 -> Main.beni:13:9
        \\const Main$twice -> Main.beni:21:1
        \\Main$twice = -> Main.beni:21:1 twice
        \\(n$1) => -> Main.beni:22:7 twice
        \\n$1 * 2 -> Main.beni:22:5
        \\Main$describe(Main$Stop -> Main.beni:27:41
        \\frame todo Debug.beni:43:15
        \\frame describe Main.beni:17:13
        \\frame <anonymous> Main.beni:27:41
        \\exit 1
        \\
    , checked.stdout);
    try testing.expectEqual(@as(u8, 0), checked.exit_code);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A map beside every emitted module, core's and the platform's
    // included, whose source is embedded and named `beni:///`; none beside
    // the hand-written siblings, which are what the debugger shows as they
    // are, nor beside the entry file, which no beni line wrote.
    const files = try w.listFiles("out");
    for (files) |path| {
        const is_module = std.mem.endsWith(u8, path, ".mjs") and !std.mem.endsWith(u8, path, ".foreign.mjs") and !std.mem.eql(u8, path, "_main.mjs");
        const map = try std.fmt.allocPrint(w.arena.allocator(), "{s}.map", .{path});
        var has_map = false;
        for (files) |other| has_map = has_map or std.mem.eql(u8, other, map);
        try testing.expectEqual(is_module, has_map);
    }
    const core_map = try w.read("out/_core/String.mjs.map");
    try testing.expect(std.mem.startsWith(u8, core_map, "{\"version\":3,\"file\":\"String.mjs\",\"sources\":[\"beni:///core/String.beni\"],\"sourcesContent\":[\""));
}

/// `check_map_script` for a release map (`backend.md` §11.2): any number
/// of sources, each said to be its file's text or embedded, and one-field
/// segments, which print `unmapped`. A needle is found by its text without
/// its `|` and looked up at the `|`, or at its start when it has none,
/// since a short name alone is rarely unique. A segment that starts before
/// the needle's spot says by how many columns: a name in `names` belongs to
/// a binding only at the binding's own column. Each spot is also looked up
/// with Node's own reader, `node:module`'s `SourceMap`, which is what
/// `--enable-source-maps` uses, and a line says where it disagrees. With
/// `run` as the second argument the module itself runs under
/// `--enable-source-maps`.
///
/// usage: node check-release-map.mjs <module.mjs> run|no <needle>...
const check_release_map_script =
    \\import { readFileSync } from "node:fs";
    \\import { SourceMap } from "node:module";
    \\import { spawnSync } from "node:child_process";
    \\import { basename } from "node:path";
    \\import { fileURLToPath, pathToFileURL } from "node:url";
    \\
    \\const [modulePath, run, ...needles] = process.argv.slice(2);
    \\const code = readFileSync(modulePath, "utf8");
    \\const comment = /\n\/\/# sourceMappingURL=([^\n]+)\n$/.exec(code);
    \\if (!comment) throw new Error("no sourceMappingURL line at the end of " + modulePath);
    \\const mapUrl = new URL(comment[1], pathToFileURL(modulePath));
    \\const map = JSON.parse(readFileSync(mapUrl, "utf8"));
    \\console.log(`version ${map.version}, file ${map.file}`);
    \\map.sources.forEach((s, i) => {
    \\  const url = new URL(s, mapUrl);
    \\  const text = url.protocol === "file:" ? readFileSync(fileURLToPath(url), "utf8") : null;
    \\  console.log(`source ${s}: ${text === null ? "embedded" : text === map.sourcesContent[i] ? "its text" : "not its text"}`);
    \\});
    \\
    \\const digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    \\const lines = [];
    \\const state = [0, 0, 0, 0, 0];
    \\for (const line of map.mappings.split(";")) {
    \\  const segments = [];
    \\  state[0] = 0;
    \\  for (const text of line ? line.split(",") : []) {
    \\    const fields = [];
    \\    let value = 0, shift = 0;
    \\    for (const ch of text) {
    \\      const d = digits.indexOf(ch);
    \\      if (d < 0) throw new Error("not a base64 digit: " + ch);
    \\      value += (d & 31) << shift;
    \\      if (d & 32) { shift += 5; continue; }
    \\      fields.push(value & 1 ? -(value >>> 1) : value >>> 1);
    \\      value = 0; shift = 0;
    \\    }
    \\    if (![1, 4, 5].includes(fields.length)) throw new Error("a segment of " + fields.length + " fields: " + text);
    \\    fields.forEach((delta, i) => { state[i] += delta; });
    \\    const prev = segments[segments.length - 1];
    \\    if (prev && prev.column >= state[0]) throw new Error("segments out of order at column " + state[0]);
    \\    segments.push(fields.length === 1
    \\      ? { column: state[0], source: null }
    \\      : { column: state[0], source: state[1], line: state[2], sourceColumn: state[3], name: fields.length === 5 ? map.names[state[4]] : null });
    \\  }
    \\  lines.push(segments);
    \\}
    \\
    \\const nodeMap = new SourceMap(map);
    \\for (const needle of needles) {
    \\  const bar = needle.indexOf("|");
    \\  const text = needle.replace("|", "");
    \\  const found = code.indexOf(text);
    \\  if (found < 0) throw new Error("not in the module: " + text);
    \\  const before = code.slice(0, found + Math.max(bar, 0)).split("\n");
    \\  const line = before.length - 1, column = before[line].length;
    \\  const hit = (lines[line] ?? []).filter((s) => s.column <= column).pop();
    \\  const where = hit && hit.source !== null ? `${basename(map.sources[hit.source])}:${hit.line + 1}:${hit.sourceColumn + 1}` : "unmapped";
    \\  const early = hit && hit.column < column ? ` (${column - hit.column} before)` : "";
    \\  console.log(`${needle} -> ${where}${hit?.name ? " " + hit.name : ""}${early}`);
    \\  const n = nodeMap.findEntry(line, column);
    \\  const nodeWhere = n.originalSource ? `${basename(n.originalSource)}:${n.originalLine + 1}:${n.originalColumn + 1}` : "unmapped";
    \\  const nodeName = n.originalSource && n.name ? " " + n.name : "";
    \\  if (`${nodeWhere}${nodeName}` !== `${where}${hit?.name && where !== "unmapped" ? " " + hit.name : ""}`) console.log(`  node:module reads ${nodeWhere}${nodeName}`);
    \\}
    \\
    \\if (run === "run") {
    \\  const r = spawnSync(process.execPath, ["--enable-source-maps", modulePath], { encoding: "utf8" });
    \\  for (const frame of r.stderr.matchAll(/^\s+at (\S+) \((?:.*\/)?([^\/]+\.beni:\d+:\d+)\)$/gm)) {
    \\    console.log(`frame ${frame[1]} ${frame[2]}`);
    \\  }
    \\  console.log(`exit ${r.status}`);
    \\}
    \\
;

test "a release build maps the one hoisted file back to each module's beni source" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §11.2: an application's release build is one file, and
    // its one map has a source per module the file holds. Each spot below
    // is one rule of *What the marks survive*: `spread`'s `doubled` is a
    // renamed local, `total`'s `rest` an initialiser the optimiser writes
    // at its one use, every top-level function's first byte carries its beni
    // name, and `Debug.todo` is a body copied from `core/Debug` to its call,
    // so it maps to the call. `report` is written with `countDown` in it, a loop
    // whose variable the printer declares in a `for` head (item 4). The
    // runtime's `process.stdout` is hand-written and the entry's
    // `run(main)` the link step's: both unmapped, under Node's own reader
    // too, for which the map's last segment must end with its line. So is
    // the runtime's `import` at the top, before the first stretch, which is
    // where a file §9 declines to hoist is imported too. A module with no
    // mark (`core/Debug`, whose `todo` is copied to its call) is no source
    // of the map. Under
    // Node's `--enable-source-maps`, the crash names `describe` at the call,
    // as the development build does (§11.1). `--allow-debug` is the hidden
    // flag that lets a release build reach `Debug`, for the crash.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\type Step
        \\    = Go Int
        \\    | Stop
        \\
        \\
        \\describe : Step → String
        \\describe step =
        \\    case step of
        \\        Go n →
        \\            String.fromInt (spread n)
        \\
        \\        Stop →
        \\            Debug.todo "stop is not done"
        \\
        \\
        \\spread : Int → Int
        \\spread n =
        \\    doubled =
        \\        n * 7919
        \\    doubled + doubled * 3
        \\
        \\
        \\total : List Int → Int
        \\total xs =
        \\    case xs of
        \\        [] →
        \\            0
        \\
        \\        [ x, …rest ] →
        \\            x + total rest
        \\
        \\
        \\countDown : Int, Int → Int
        \\countDown i acc =
        \\    if i ≥ 0 then
        \\        countDown (i - 1) (acc + i * 3)
        \\
        \\    else
        \\        acc
        \\
        \\
        \\report : Int → String
        \\report n =
        \\    sum =
        \\        countDown n 0
        \\    String.fromInt sum
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ describe (Go 21), describe (Go 5), String.fromInt (total [ 1, 2, 3 ]), report 4, report 9, describe Stop ]
        \\
    );
    try w.write("check-release-map.mjs", check_release_map_script);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=node", "--release", "--allow-debug", "--source-maps", "--out=out", "src" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);
    const checked = try w.runNode(&.{
        "check-release-map.mjs",
        "out/_main.mjs",
        "run",
        "p=|a=>{",
        "let b=a*7919",
        "let |b=a*7919",
        "b=|a*7919",
        "b+b*3",
        "q=|b=>{if",
        "return a(p(",
        "throw new Error",
        "r=|a=>a.length",
        "r(n(a))",
        "r(|n(a))",
        "s=|b=>{let d=0",
        "for(let c=b",
        "for(let |c=b",
        "let |d=0",
        "import process",
        "process.stdout",
        "u(t)",
    });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings("", checked.stderr);
    try testing.expectEqualStrings(
        \\version 3, file _main.mjs
        \\source beni:///core/String.beni: embedded
        \\source beni:///core/List.beni: embedded
        \\source ../src/Main.beni: its text
        \\p=|a=>{ -> Main.beni:24:13 spread
        \\let b=a*7919 -> Main.beni:22:5
        \\let |b=a*7919 -> Main.beni:22:5 doubled
        \\b=|a*7919 -> Main.beni:23:9
        \\b+b*3 -> Main.beni:24:5
        \\q=|b=>{if -> Main.beni:12:5 describe
        \\return a(p( -> Main.beni:14:13
        \\throw new Error -> Main.beni:17:13
        \\r=|a=>a.length -> Main.beni:29:5 total
        \\r(n(a)) -> Main.beni:34:17
        \\r(|n(a)) -> Main.beni:33:14
        \\s=|b=>{let d=0 -> Main.beni:50:5 report
        \\for(let c=b -> Main.beni:49:9
        \\for(let |c=b -> Main.beni:49:9 i
        \\let |d=0 -> Main.beni:49:9 acc
        \\import process -> unmapped
        \\process.stdout -> unmapped
        \\u(t) -> unmapped
        \\frame describe Main.beni:17:13
        \\frame <anonymous> Main.beni:55:114
        \\exit 1
        \\
    , checked.stdout);
    try testing.expectEqual(@as(u8, 0), checked.exit_code);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // One file and one map: the hoisted file holds every module.
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "_main.mjs", "_main.mjs.map", "_manifest.txt" }), try w.listFiles("out"));
}

test "a branch that specialisation decides maps to the code it keeps" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §11.2, item 6. `crash 500` takes its `then` branch, and
    // whole-program specialisation writes the call it keeps in place of
    // the `if`. That call maps to its own line, 14:9, as the development
    // build's `crash` frame does, and not to the test's `>` at 13:10. The
    // call to `Aid.twice` is a body copied from another module, so it maps
    // to its call, in UTF-16 columns after `é😀`. `Aid` keeps no mark of
    // its own, so it is no source of the map. `and/` is the same for `&&`:
    // `check 500` keeps `Aid.bad n`, which maps to 8:16 and not to the
    // `&&` at 8:13. It is a program of its own because a second
    // `Debug.todo` call would stop `todo` being copied to either call, and
    // only a copy shows the position a fold leaves.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Aid.beni",
        \\pub twice : Int → Int
        \\twice n =
        \\    n * 2
        \\
        \\
        \\pub boom : Int → Int
        \\boom n =
        \\    Debug.todo "boom é😀"
        \\
    );
    try w.write("src/Main.beni",
        \\import Aid
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\label : Int → String
        \\label n =
        \\    "é😀 " ++ String.fromInt (Aid.twice n) ++ " ✓"
        \\
        \\
        \\crash : Int → Int
        \\crash n =
        \\    if n > 100 then
        \\        Aid.boom n
        \\
        \\    else
        \\        n
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ label 1, "😀😀" ++ label 2, String.fromInt (crash 500) ]
        \\
    );
    try w.write("and/Aid.beni",
        \\pub bad : Int → Bool
        \\bad n =
        \\    Debug.todo "bad"
        \\
        \\
        \\pub boom : Int → Int
        \\boom n =
        \\    Debug.todo "boom"
        \\
    );
    try w.write("and/Main.beni",
        \\import Aid
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\check : Int → Bool
        \\check n =
        \\    n > 100 && Aid.bad n
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines
        \\        [ if check 500 then
        \\            "y"
        \\
        \\          else
        \\            "n"
        \\        ]
        \\
    );
    try w.write("check-release-map.mjs", check_release_map_script);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=node", "--release", "--allow-debug", "--source-maps", "--out=out", "src" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);
    const checked = try w.runNode(&.{ "check-release-map.mjs", "out/_main.mjs", "run", "a(|b())", "a(|b*2)" });
    const and_built = try w.runWith(&.{ "build", "--platform=node", "--release", "--allow-debug", "--source-maps", "--out=and-out", "and" }, .{ .raw_diagnostics = true });
    try expectBuilt(and_built);
    const and_checked = try w.runNode(&.{ "check-release-map.mjs", "and-out/_main.mjs", "no", "a()?\"y\"" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings("", checked.stderr);
    try testing.expectEqualStrings(
        \\version 3, file _main.mjs
        \\source beni:///core/String.beni: embedded
        \\source beni:///core/Debug.beni: embedded
        \\source ../src/Main.beni: its text
        \\a(|b()) -> Main.beni:14:9
        \\a(|b*2) -> Main.beni:8:41
        \\frame todo Debug.beni:43:15
        \\frame <anonymous> Main.beni:14:9
        \\exit 1
        \\
    , checked.stdout);
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expectEqualStrings("", and_checked.stderr);
    try testing.expectEqualStrings(
        \\version 3, file _main.mjs
        \\source beni:///core/Debug.beni: embedded
        \\source ../and/Main.beni: its text
        \\a()?"y" -> Main.beni:8:16
        \\
    , and_checked.stdout);
}

test "a release library build writes a map beside every module" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §11.2: a `--library` release build is one file per
    // module (§9), and each module lowered from beni gets its own map, as
    // in development. The platform's runtime is hand-written, compacted
    // and unmapped. In `Lib.mjs`: two exported functions carry their beni
    // names at their first byte, a renamed local its own, and two calls in
    // `label` map to their first tokens. The `export` is covered by the
    // last segment, which has no name: Node's own reader takes the name
    // before it unless the map ends the line (§11.2, *The join*).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Lib.beni",
        \\import String
        \\
        \\
        \\pub spread : Int → Int
        \\spread n =
        \\    doubled =
        \\        n * 7919
        \\    doubled + doubled * 3
        \\
        \\
        \\pub label : List Int → String
        \\label xs =
        \\    String.join (List.map xs (λx → String.fromInt (spread x))) ", "
        \\
    );
    try w.write("check-release-map.mjs", check_release_map_script);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=node", "--release", "--library", "--source-maps", "--out=lib", "Lib.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);
    const checked = try w.runNode(&.{ "check-release-map.mjs", "lib/Lib.mjs", "no", "d=|a=>", "let |b", "b+b*3", "e=|f=>", "a(|c(f", "b(d(f))", "export{" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings("", checked.stderr);
    try testing.expectEqualStrings(
        \\version 3, file Lib.mjs
        \\source ../Lib.beni: its text
        \\d=|a=> -> Lib.beni:8:13 spread
        \\let |b -> Lib.beni:6:5 doubled
        \\b+b*3 -> Lib.beni:8:5
        \\e=|f=> -> Lib.beni:13:5 label
        \\a(|c(f -> Lib.beni:13:18
        \\b(d(f)) -> Lib.beni:13:36
        \\export{ -> Lib.beni:13:59 (6 before)
        \\
    , checked.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A map beside every module lowered from beni, core's included, and
    // none beside the hand-written runtime.
    const files = try w.listFiles("lib");
    var maps: usize = 0;
    for (files) |path| {
        const is_module = std.mem.endsWith(u8, path, ".mjs") and !std.mem.endsWith(u8, path, ".foreign.mjs") and !std.mem.endsWith(u8, path, "_derived.mjs");
        const map = try std.fmt.allocPrint(w.arena.allocator(), "{s}.map", .{path});
        var has_map = false;
        for (files) |other| has_map = has_map or std.mem.eql(u8, other, map);
        try testing.expectEqual(is_module, has_map);
        maps += @intFromBool(has_map);
    }
    try testing.expect(maps >= 2);
    try testing.expect(w.exists("lib/_platform/runtime.foreign.mjs"));
    const core_map = try w.read("lib/_core/List.mjs.map");
    try testing.expect(std.mem.startsWith(u8, core_map, "{\"version\":3,\"file\":\"List.mjs\",\"sources\":[\"beni:///core/List.beni\"],\"sourcesContent\":[\""));
}

test "--no-source-maps writes no map and no comment, and contradicting it is refused" {
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
    const off = try w.runWith(&.{ "build", "--platform=node", "--no-source-maps", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });
    const both = try w.runWith(&.{ "build", "--platform=node", "--no-source-maps", "--source-maps", "--out=both", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(off);
    try testing.expectEqual(@as(u8, 2), both.exit_code);
    try testing.expectEqualStrings("beni: --source-maps and --no-source-maps contradict each other\n", both.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    for (try w.listFiles("out")) |path| try testing.expect(!std.mem.endsWith(u8, path, ".map"));
    try testing.expect(std.mem.indexOf(u8, try w.read("out/Main.mjs"), "sourceMappingURL") == null);
    try testing.expect(!w.exists("both"));
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
        \\unfinished : Int → String
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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The reachable branch never prints: `printLines` needs the whole list
    // before it writes anything, so the throw comes first.
    try w.expectProgram(world.entry_file, .{ .exit_code = 1, .stdout = "", .stderr = .{ .contains = "Error: TODO: the negative case" } });
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

test "a declaration's compiler-made names do not depend on which declarations before it survive" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §4, *A compiler-made name is numbered within its
    // top-level declaration* (Cesar's decision, 2026-10-15): the counter
    // behind `$p$N` restarts at 1 for each top-level declaration. `first`
    // and `second` each destructure a tuple parameter, which makes a `$p`
    // name. One program keeps `first`, the other drops it. With one counter
    // per module, `second`'s parameter was `$p$2` in the first program and
    // `$p$1` in the second.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const module =
        \\import Node exposing (Program)
        \\
        \\
        \\first : Int × Int → Int
        \\first ( a, b ) =
        \\    a + b
        \\
        \\
        \\second : Int × Int → Int
        \\second ( c, d ) =
        \\    c * d
        \\
        \\
        \\main : Program
        \\main =
        \\
    ;
    try w.write("both/Main.beni", module ++ "    Node.print (String.fromInt (first ( 1, 2 ) + second ( 3, 4 )))\n");
    try w.write("one/Main.beni", module ++ "    Node.print (String.fromInt (second ( 3, 4 )))\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try expectBuilt(try w.run(&.{ "build", "--platform=node", "--no-source-maps", "--root=both", "--out=both-out", "both/Main.beni" }));
    try expectBuilt(try w.run(&.{ "build", "--platform=node", "--no-source-maps", "--root=one", "--out=one-out", "one/Main.beni" }));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    const both = try w.read("both-out/Main.mjs");
    const one = try w.read("one-out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, both, "const Main$first = ") != null);
    try testing.expect(std.mem.indexOf(u8, one, "const Main$first = ") == null);
    const second_both = try statementOf(both, "const Main$second = ");
    const second_one = try statementOf(one, "const Main$second = ");
    try testing.expectEqualStrings(second_one, second_both);
    try testing.expect(std.mem.indexOf(u8, second_one, "$p$1") != null);
}

test "a dropped declaration leaves the module's bytes exactly as a build that never wrote it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §9, *The embedded modules' printed text, in the pack*:
    // a module's bytes are its survivor set's statements in the module's
    // order — one concatenation of runs the lowering made, with no
    // separator owned by a neighbour. A declaration the walk drops must
    // leave no trace: no blank line, no renumbered tag, no moved import.
    // `dies` keeps `gone` between two declarations `main` reaches and
    // `plain` never writes it; the two `Main.mjs` files are one file.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("dies/Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\first : Int × Int → Int
        \\first ( a, b ) =
        \\    a + b
        \\
        \\
        \\gone : Int → Int
        \\gone n =
        \\    n * 1000
        \\
        \\
        \\second : Int × Int → Int
        \\second ( c, d ) =
        \\    c * d
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (first ( 1, 2 ) + second ( 3, 4 )))
        \\
    );
    try w.write("plain/Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\first : Int × Int → Int
        \\first ( a, b ) =
        \\    a + b
        \\
        \\
        \\second : Int × Int → Int
        \\second ( c, d ) =
        \\    c * d
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (first ( 1, 2 ) + second ( 3, 4 )))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try expectBuilt(try w.run(&.{ "build", "--platform=node", "--no-source-maps", "--root=dies", "--out=dies-out", "dies/Main.beni" }));
    try expectBuilt(try w.run(&.{ "build", "--platform=node", "--no-source-maps", "--root=plain", "--out=plain-out", "plain/Main.beni" }));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    const dies = try w.read("dies-out/Main.mjs");
    const plain = try w.read("plain-out/Main.mjs");
    // Dropped by name, its neighbours there with their tags, and the whole
    // file — head, order, every byte — the file of a build that never
    // wrote it.
    try testing.expect(std.mem.indexOf(u8, dies, "gone") == null);
    try testing.expect(std.mem.indexOf(u8, dies, "$p$1") != null);
    try testing.expectEqualStrings(plain, dies);
}

/// The top-level statement of `text` that starts with `head`: its first
/// line and every line after it that is indented or closes it.
fn statementOf(text: []const u8, head: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, text, head) orelse return error.NoStatement;
    var end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    while (end + 1 < text.len) {
        const c = text[end + 1];
        if (c != ' ' and c != '}' and c != ')' and c != ']') break;
        end = std.mem.indexOfScalarPos(u8, text, end + 1, '\n') orelse text.len;
    }
    return text[start..end];
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
        // A module's source map (§11) is not loaded as a module either; it
        // is named for the `.mjs` beside it, which must be there.
        if (std.mem.endsWith(u8, path, ".mjs.map")) {
            if (for (files) |other| {
                if (std.mem.eql(u8, other, path[0 .. path.len - ".map".len])) break true;
            } else false) continue;
            std.debug.print("{s}/{s} is a map with no module beside it (backend.md §11)\n", .{ dir, path });
            return error.NotAnEsModule;
        }
        std.debug.print("{s}/{s} is not a .mjs file (backend.md §2)\n", .{ dir, path });
        return error.NotAnEsModule;
    }
}

test "an unannotated pub function constant with a constraint builds and runs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // static-dispatch-spike.md §10.10 as amended. The
    // program of `check/good/ConstrainedPubFunctionConstant/`, built and
    // run: it cannot be a `run/` fixture, because every unannotated
    // constrained `pub` prints the informational `ambiguous_method_receiver`
    // warning and a `run/` build must be silent. None of the three `pub`
    // values may be refused as `constrained_constant`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("M.beni",
        \\maxOf : a, a → a
        \\    where a.compare : a, a → Order
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
        \\    λa b → a == b
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
        \\tf : Bool → String
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
    const r = try w.buildAndRun(&.{ "Main.beni", "M.beni" }, .{ .stdout = "f\nt\nt\n2\n9\nb\n2\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    // Three warnings and no error: the inferred interface carries a `where`.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, r.stderr, "CONSTRAINT IN AN INFERRED INTERFACE"));
    try testing.expect(std.mem.indexOf(u8, r.stderr, "CONSTRAINED CONSTANT") == null);
}

// ─────────────────────────────────────────────────────────────────────────
// `bench/corpus` stays valid (its README; `frontend.md` §9.3).
//
// The corpus is what the throughput numbers of `bench/README.md` and the
// output sizes of `bench/size.mjs` are stated against, and both assume it
// checks and builds. It rotted once — a JSON module imported a library core
// does not have, and a view imported HTML functions no platform declares —
// and every check number over it then timed the error path while the size
// benchmark silently left both modules out. These two scenarios are the
// guard. The corpus is copied, so it runs from its own root exactly as the
// README's commands do and nothing is written into the repository.
// ─────────────────────────────────────────────────────────────────────────

/// Print a failed run's diagnostics, so a red scenario names the file.
fn reportUnclean(what: []const u8, r: world.Result) void {
    if (r.exit_code != 0 or !onlyPrependWarnings(r)) {
        std.debug.print("bench/corpus did not {s} clean:\n{s}\n", .{ what, r.stderr });
    }
}

/// Whether every diagnostic of `r` is a `prepend_in_loop` warning. The
/// corpus keeps its Elm-shaped prepend loops on purpose (the owner,
/// 2026-10-11: benchmark programs stay as they are, so what they measure
/// stays comparable), and since a prepend copies (`language.md` §6.8) the
/// checker warns at each; any other diagnostic is still a failure.
fn onlyPrependWarnings(r: world.Result) bool {
    for (r.diagnostics) |d| {
        if (d.code != .prepend_in_loop or d.severity != .warning) return false;
    }
    return true;
}

test "bench/corpus type-checks with no diagnostic and no platform" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTree("bench/corpus", "_expected.");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "." });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // No diagnostic of any severity but `prepend_in_loop`: a warning is
    // something every reader of the corpus steps past, and the corpus is
    // meant to be idiomatic — except for the prepend loops it keeps as they
    // were (`onlyPrependWarnings`).
    reportUnclean("check", checked);
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
    try testing.expect(onlyPrependWarnings(checked));
}

test "bench/corpus builds as a library for the node platform" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTree("bench/corpus", "_expected.");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // The build `bench/size.mjs` makes of it: the corpus declares no `main`,
    // so it is a library, rooted at every exported name.
    const built = try w.run(&.{ "build", "--platform=node", "--library", "--out=out", "." });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    reportUnclean("build", built);
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expect(onlyPrependWarnings(built));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(w.exists("out/JsonCodecs.mjs"));
    try testing.expect(w.exists("out/NotesApp.mjs"));
}

test "core List's loops read and write their arrays in place" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // backend.md §4, *`List.beni`'s loops read and write in place*: the
    // core-private `at`, `put`, `identical`, `kept` and `half`, and
    // `List.length` anywhere, are the JavaScript they compute and never a
    // call — a call of one shared function from every loop of a program is
    // what made `map2` 3.5× the cons list's. The claim is about the OUTPUT
    // TREE (core's emitted module and the one `--release` file), so it is
    // here and not in `emit/`, whose goldens are of the root package; the
    // program's answer proves the loops still compute what they did.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\import List
        \\import String
        \\
        \\
        \\main : Program
        \\main =
        \\    xs =
        \\        List.range 1 10
        \\
        \\    kept =
        \\        List.map xs λx → x
        \\
        \\    sorted =
        \\        List.sortWith (List.filter xs λx → x > 2) λa b → Basics.compare b a
        \\    Node.print (String.join (List.map (List.map2 kept sorted (+)) String.fromInt) "," ++ " " ++ String.fromInt (List.length xs))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.buildAndRun(&.{"Main.beni"}, .{ .stdout = "11,11,11,11,11,11,11,11 10\n" });
    try expectBuilt(r);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // No call, and — since nothing names one as a value — no import of the
    // sibling's export either, which is what `Reach` keeps a declaration
    // alive by, so `--release` ships none of them.
    const list_mjs = try w.read("out/_core/List.mjs");
    const main_mjs = try w.read("out/Main.mjs");
    const arena = w.arena.allocator();
    for ([_][]const u8{ "List$at", "List$put", "List$identical", "List$kept", "List$half", "List$length" }) |name| {
        inline for (.{ "{s}(", "as {s},", "as {s} }}" }) |shape| {
            const needle = try std.fmt.allocPrint(arena, shape, .{name});
            for ([_][]const u8{ list_mjs, main_mjs }) |text| {
                if (std.mem.indexOf(u8, text, needle) != null) {
                    std.debug.print("expected no `{s}`, found one in:\n{s}\n", .{ needle, text });
                    return error.NotWrittenInPlace;
                }
            }
        }
    }
}

test "a schema program's issues get short fields and integer tags under --release" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `core/Schema` keeps a conversion's two functions in a host pair. Handed
    // over with `Js.from` at their own type, `b -> Result (List Issue) a`,
    // they made `Issue` — and `Direction`, `Endpoint`, `IssueCode` and
    // `PathSegment` with it — types JavaScript can see (`backend.md` §9,
    // *Item 4, taken up*), so every schema program kept their field names
    // and string tags. No JavaScript calls them: the engine reads them back
    // and calls them from beni, so they cross at a type variable, as every
    // other value the engine parks in the host does.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\import Schema
        \\
        \\
        \\positive : Schema.Schema Int Int
        \\positive =
        \\    Schema.converted
        \\        Schema.int
        \\        (Schema.conversion (λn → if n > 0 then Ok n else Err []) λn → Ok n)
        \\
        \\
        \\main : Program
        \\main =
        \\    case Schema.parse positive "0" of
        \\        Ok n →
        \\            Node.print (String.fromInt n)
        \\
        \\        Err issues →
        \\            Node.print (String.join (List.map issues λi → i.message) ",")
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.buildAndRun(&.{ "--release", "Main.beni" }, .{ .stdout = "the conversion failed without an issue\n" });
    try expectBuilt(r);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    const out = try w.read(world.entry_file);
    for ([_][]const u8{ "direction:", "endpoint:", "\"ConversionFailed\"", "\"Decoding\"", "\"Field\"" }) |needle| {
        if (std.mem.indexOf(u8, out, needle) != null) {
            std.debug.print("expected no `{s}` in the release build, found one in:\n{s}\n", .{ needle, out });
            return error.KeptForJavaScript;
        }
    }
}

test "a program that suspends keeps Task.andThen, which core writes in beni" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Reach` added the edge from a body that may suspend to `Task.andThen`
    // only when it was a `foreign` declaration (`backend.md` §4,
    // *`Js.suspending` is its body*): written in beni, it was dropped, and
    // `Main` imported a name the build never wrote. `Main`'s own code
    // suspends, but it calls no kernel function that calls `andThen`:
    // `yieldNow` parks in tail position.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Io
        \\import Node exposing (Program)
        \\import Task
        \\
        \\
        \\main : Program
        \\main = Io.run λ⊤ →
        \\    Task.yieldNow ⊤
        \\    Node.print "yielded"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.buildAndRun(&.{"Main.beni"}, .{ .stdout = "yielded\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
}

test "Io.run writes each log line to standard error as logfmt, in both builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `boundary.md` §9.8.15 (b): `Io.run` installs a sink that writes one
    // `Log.logfmt` line per entry to standard error, so standard output
    // holds only what the `Program` prints. A virtual clock fixes the
    // time (transparent-effects-proposal.md §17.11, *Fixtures*), and
    // `Debug` is below the default minimum. A line carries the fiber's
    // log spans and annotations. `--release` keeps every call.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Clock
        \\import Io
        \\import Log
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main = Io.run λ⊤ →
        \\    Clock.run (Clock.virtual 1760000000000) λ⊤ →
        \\        Log.info "listening"
        \\        Log.debug "not written"
        \\        Log.warn "slow \"disk\""
        \\        Log.annotate "user" "7" λ⊤ →
        \\            Log.span "save" λ⊤ →
        \\                Log.error "failed"
        \\    Node.print "done"
        \\
    );
    const expected: world.Expected = .{
        .stdout = "done\n",
        .stderr = .{ .exact =
        \\timestamp=2025-10-09T08:53:20.000Z level=INFO message=listening
        \\timestamp=2025-10-09T08:53:20.000Z level=WARN message="slow \"disk\""
        \\timestamp=2025-10-09T08:53:20.000Z level=ERROR message=failed save=0ms user=7
        \\
        },
    };

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dev = try w.buildAndRun(&.{"Main.beni"}, expected);
    const release = try w.buildAndRun(&.{ "--release", "Main.beni" }, expected);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(dev);
    try expectBuilt(release);
}

test "a node program without Io.run logs Warn and Error to standard error, through the console" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A program that never calls `Io.run` logs through core's default sink
    // (transparent-effects-proposal.md §17.11): the console method for the
    // level. On Node, `console.info` writes standard output, and
    // `console.warn` and `console.error` write standard error. `Debug` is
    // below the default minimum. `--release` keeps every call.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Log
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Log.debug "not written"
        \\    Log.info "an info line"
        \\    Log.warn "a warning"
        \\    Log.error "an error"
        \\    Node.print "done"
        \\
    );
    const expected: world.Expected = .{
        .stdout = "an info line\ndone\n",
        .stderr = .{ .exact = "a warning\nan error\n" },
    };

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dev = try w.buildAndRun(&.{"Main.beni"}, expected);
    const release = try w.buildAndRun(&.{ "--release", "Main.beni" }, expected);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(dev);
    try expectBuilt(release);
}

test "a log line written just before a defect is on standard error before the defect's report" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The sink `Io.run` installs writes each line at once (`boundary.md`
    // §9.8.15 (b)): a line that a buffer held would be lost when the defect
    // stops the program, and the line that says what went wrong is the one
    // a program writes last.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Clock
        \\import Io
        \\import Log
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main = Io.run λ⊤ →
        \\    Clock.run (Clock.virtual 0) λ⊤ →
        \\        Log.error "about to fail"
        \\        Debug.todo "the defect"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.run(&.{ "build", "--platform=node", "--out=" ++ world.default_out, "Main.beni" });
    try expectBuilt(built);
    const r = try w.nodeWith(world.entry_file, world.default_timeout_ms);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Node's report names the build's own paths and lines, so only the
    // order of the two is asserted.
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    const line = std.mem.indexOf(u8, r.stderr, "timestamp=1970-01-01T00:00:00.000Z level=ERROR message=\"about to fail\"\n") orelse {
        std.debug.print("no log line on standard error:\n{s}\n", .{r.stderr});
        return error.LogLineMissing;
    };
    const report = std.mem.indexOf(u8, r.stderr, "TODO: the defect") orelse {
        std.debug.print("no report of the defect on standard error:\n{s}\n", .{r.stderr});
        return error.DefectReportMissing;
    };
    try testing.expect(line < report);
}

/// A program whose building loop's exit calls `List`'s core-private `close`,
/// one of the values the emitter calls from other modules (`backend.md` §4,
/// *The emitter's imports of the core-private exports*). Since the list
/// runtime moved to beni, the shipped core's `close` has a beni body; while
/// all five were `foreign`, that hid that `Lower` treated a beni-bodied one
/// as a value nobody calls. Its body is an `if`, so `--release` keeps it a
/// function of its own rather than writing it into its one caller.
fn writeCloseProgram(w: *World) !void {
    // A building loop whose exit hands `close` a non-empty rest.
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\import String
        \\
        \\
        \\above : List Int → List Int
        \\above xs =
        \\    case xs of
        \\        [ x, …rest ] →
        \\            if x > 2 then
        \\                [ x, …above rest ]
        \\
        \\            else
        \\                above rest
        \\
        \\        [] →
        \\            [ 99, 100 ]
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.join (List.map (above [ 1, 2, 3, 4 ]) String.fromInt) ",")
        \\
    );
}

test "a core-private List value the emitter calls is exported when it has a beni body" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Main`'s loop calls `List$close`, which `core/List` exported only
    // when it was `foreign`: with a beni body the program failed to load,
    // `… does not provide an export named 'List$close'`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeCloseProgram(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.buildAndRun(&.{"Main.beni"}, .{ .stdout = "3,4,99,100\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
}

test "a core-private List value the emitter calls keeps its result under --release" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `--release` writes a private function whose every caller discards
    // its result without a `return` (§4, *A result nothing reads*). The
    // emitter's calls of `close` are in no BIR, so a beni-bodied `close`
    // looked uncalled and returned `undefined`: `Main` then read
    // `undefined.length`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeCloseProgram(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.buildAndRun(&.{ "--release", "Main.beni" }, .{ .stdout = "3,4,99,100\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
}

test "a --core-root core without a core-private List value the emitter calls is refused where a module needs it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A list pattern's `rest` is `List$view`, which the emitter imports
    // from `core/List` by its printed name (`backend.md` §4, *The
    // emitter's imports of the core-private exports*). A core without it
    // built with no diagnostic and exit 0, and the program then failed to
    // load: `… does not provide an export named 'List$view'`. Here the
    // value is renamed `viewAt`, so `core/List` itself still builds — its
    // own code names it and never binds a `rest` — and lacks only the name
    // the emitter imports.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    try w.copyTreeInto("core", "mycore", "_");
    var beni = try w.read("mycore/List.beni");
    for ([_][]const u8{ "\nview : ", "view xs " }) |old| {
        if (std.mem.count(u8, beni, old) == 0) return error.CoreChanged;
        const new = try std.mem.replaceOwned(u8, arena, old, "view", "viewAt");
        beni = try std.mem.replaceOwned(u8, arena, beni, old, new);
    }
    try w.write("mycore/List.beni", beni);
    // Not a tail call, so `rest` is a list of its own: a view.
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\count : List Int → Int
        \\count xs =
        \\    case xs of
        \\        [] →
        \\            0
        \\
        \\        [ _, …rest ] →
        \\            1 + count rest
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (count [ 1, 2, 3 ]))
        \\
    );
    // The same core builds a program that binds no `rest`.
    try w.write("Other.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (String.fromInt (List.length [ 1, 2, 3 ]))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const refused = try w.run(&.{ "build", "--platform=node", "--core-root=mycore", "--out=refused", "Main.beni" });
    const other = try w.buildAndRun(&.{ "--core-root=mycore", "Other.beni" }, .{ .stdout = "3\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), refused.exit_code);
    try testing.expectEqual(@as(usize, 1), refused.diagnostics.len);
    const d = refused.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.core_contract_violation, d.code);
    try testing.expect(std.mem.endsWith(u8, d.span.file, "Main.beni"));
    try testing.expect(std.mem.indexOf(u8, d.message, "`List.view`") != null);
    try expectBuilt(other);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY STATE                            │
    // └─────────────────────────────────────────┘
    // A refused build writes nothing (backend.md §2).
    try testing.expect(!w.exists("refused/Main.mjs"));
}

test "the release specialiser's list sweeps do not grow with lists they cannot act on" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §9, *Whole-program specialisation*, dated note
    // 2026-10-02: the statement-list sweeps (scalar replacement, constructor
    // folding, `x = x`) walk the whole program after every round, and a
    // list holding nothing they could act on is left uncopied. One program
    // at two sizes of a `case` whose arms hold no candidate — a literal
    // `return` each — must copy the same number of lists: the count is
    // `--self-profile`'s `spec_lists_examined`, which every list the sweeps
    // copied once counted.
    const small = try specListsExamined(64);
    const large = try specListsExamined(1024);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(small, large);
}

/// `spec_lists_examined` of a `--release` build of a `case` of `arms`
/// literal arms beside a `main` that calls it through `List.map`.
fn specListsExamined(arms: usize) !u64 {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    const out = &source.writer;
    try out.writeAll("import Node exposing (Program)\n\n\ng : Int → Int\ng k =\n    case k of\n");
    for (0..arms) |i| try out.print("        {d} →\n            {d}\n\n", .{ i, i + 1 });
    try out.writeAll(
        \\        _ →
        \\            -1
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines (List.map [ 0, 1 ] λk → String.fromInt (g k))
        \\
    );
    try w.write("Main.beni", source.written());
    const r = try w.runWith(&.{ "build", "--platform=node", "--out=out", "--no-cache", "--release", "--self-profile=trace.json", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(r);
    const Event = struct {
        ph: []const u8,
        args: struct { spec_lists_examined: ?u64 = null } = .{},
    };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read("trace.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.traceEvents) |e| {
        if (std.mem.eql(u8, e.ph, "C")) if (e.args.spec_lists_examined) |v| return v;
    }
    return error.NoCounter;
}

test "the release specialiser keeps fact 3 for an analysis after a change fact 3 does not read" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #575 (`backend.md` §9, *As built 2026-10-21 — an analysis keeps fact
    // 3 when nothing it reads changed*): `run/ReleaseReadAcrossWrite`'s
    // `const n = h.cell.v` is kept by lowering for `Js.read`, and released
    // once fact 3 shows `h.cell` is an object of the program
    // (`releaseKeeps`). The facts are asked once more, of a program in
    // which nothing fact 3 reads changed since its last solve: that
    // analysis keeps the state instead of solving again. The ReleaseSafe
    // compiler the tests run solves anyway and compares on a program this
    // small (`Pts.checkKept`), and the corpus runs the program in both
    // builds.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTreeInto("tests/corpus/run/ReleaseReadAcrossWrite", ".", "_");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=./platform", "--out=out", "--no-cache", "--release", "--self-profile=trace.json", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectBuilt(r);
    const Event = struct {
        ph: []const u8,
        args: struct {
            spec_solves: ?u64 = null,
            spec_points_to_runs: ?u64 = null,
            spec_points_to_reused: ?u64 = null,
        } = .{},
    };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read("trace.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var analyses: ?u64 = null;
    var runs: ?u64 = null;
    var reused: ?u64 = null;
    for (parsed.value.traceEvents) |e| {
        if (!std.mem.eql(u8, e.ph, "C")) continue;
        if (e.args.spec_solves) |v| analyses = v;
        if (e.args.spec_points_to_runs) |v| runs = v;
        if (e.args.spec_points_to_reused) |v| reused = v;
    }
    // Since slice 6 (#676) a solve follows only a structural pass, and
    // `releaseKeeps` and the solve after it are gone: a kept binding the
    // facts release is the liveness read-off's, in the same rewrite. The
    // rounds that asked the facts again of a program fact 3 had not seen
    // change are gone with them, so no solve keeps the state here; the
    // pass loop's solves still may (`fact3Kept`). Every solve solved.
    // Since the structural passes run before the first solve (#781), the
    // pass after it finds nothing in this program, and it solves once.
    try testing.expectEqual(@as(?u64, 0), reused);
    try testing.expectEqual(@as(?u64, 1), analyses);
    try testing.expect(runs.? >= analyses.? - reused.?);
}

test "the release specialiser solves a call chain deeper than the sweeps' old cap" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Research 52's E1 (`emit/release/app/SpecDeepChain`): each function
    // passes its parameter to the next, fact 1 runs from caller to callee
    // and the sweeps walked callees first, so each level cost a sweep, and
    // 24 levels hit the cap of 24 sweeps: the first analysis rewrote
    // nothing. The combined solver (`backend.md` §9, *The combined
    // solver*, slice 4) has no sweep to run out of: 22 levels and 24 are
    // alike, and no solve reaches its work budget.
    const shallow = try specCounters(22);
    const deep = try specCounters(24);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]SpecCounters{ shallow, deep }) |c| {
        try testing.expect(c.analyses >= 1);
        try testing.expect(c.constraints > 0);
        try testing.expectEqual(@as(u64, 0), c.budget_hit);
    }
}

test "the release specialiser counts fact 3's sets, edges and load cells, and names its largest set" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `plans/type-directed-points-to.md` slice 0: what fact 3's sets cost
    // is four `--self-profile` counters — the most sites one var held, the
    // site words the sets allocated, the copy edges and the load cells —
    // and the hidden `--points-to-largest` names the var that held the
    // most, so that a merge that is still there can be found in the
    // source. Points through a record update, a member read and a
    // `List.map`: a spread, a load cell and a copy each.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\type alias Point =
        \\    { x : Int, y : Int }
        \\
        \\
        \\move : Point, Int → Point
        \\move p d =
        \\    { p | x = p.x + d }
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines (List.map [ { x = 1, y = 2 }, { x = 3, y = 4 } ] λp → String.fromInt (move p 5).x)
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const plain = try w.runWith(&.{ "build", "--platform=node", "--out=plain", "--no-cache", "--release", "--self-profile=trace.json", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(plain);
    const counters = try ptsCounters(&w);
    const traced = try w.runWith(&.{ "build", "--platform=node", "--out=traced", "--no-cache", "--release", "--points-to-largest", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expect(counters.max_set >= 1);
    // Every set of `max_set` sites was allocated, and more besides.
    try testing.expect(counters.set_words >= counters.max_set);
    try testing.expect(counters.edges >= 1);
    try testing.expect(counters.load_cells >= 1);
    // On stderr: a line that names the largest set by its size and a
    // place in the program, then a line per file its sites were made in.
    try testing.expectEqual(@as(u8, 0), traced.exit_code);
    try testing.expectEqualStrings("", traced.stdout);
    const head = try std.fmt.allocPrint(w.arena.allocator(), "beni: points-to: the largest set holds {d} sites: ", .{counters.max_set});
    try testing.expect(std.mem.startsWith(u8, traced.stderr, head));
    try testing.expect(std.mem.endsWith(u8, traced.stderr, "\n"));
    var lines = std.mem.splitScalar(u8, traced.stderr[0 .. traced.stderr.len - 1], '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) try testing.expect(std.mem.startsWith(u8, line, "beni: points-to: "));
    try testing.expect(count >= 2);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The instrument changes no byte.
    try expectSameTree(&w, "plain", "traced");
}

const PtsCounters = struct { max_set: u64 = 0, set_words: u64 = 0, edges: u64 = 0, load_cells: u64 = 0 };

/// Fact 3's counters from the `--self-profile` trace a build wrote to
/// `trace.json`: all four must be there.
fn ptsCounters(w: *World) !PtsCounters {
    const Event = struct {
        ph: []const u8,
        args: struct {
            spec_pts_max_set: ?u64 = null,
            spec_pts_set_words: ?u64 = null,
            spec_pts_edges: ?u64 = null,
            spec_pts_load_cells: ?u64 = null,
        } = .{},
    };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read("trace.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var counters: PtsCounters = .{};
    var seen: u32 = 0;
    for (parsed.value.traceEvents) |e| {
        if (!std.mem.eql(u8, e.ph, "C")) continue;
        if (e.args.spec_pts_max_set) |v| {
            counters.max_set = v;
            seen += 1;
        }
        if (e.args.spec_pts_set_words) |v| {
            counters.set_words = v;
            seen += 1;
        }
        if (e.args.spec_pts_edges) |v| {
            counters.edges = v;
            seen += 1;
        }
        if (e.args.spec_pts_load_cells) |v| {
            counters.load_cells = v;
            seen += 1;
        }
    }
    if (seen != 4) return error.NoCounter;
    return counters;
}

test "a page build makes each module's edge lists once and lowers and prints each module once" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A `browser-tea` page has a runtime module, so its build walks the
    // declaration graph two times and lowers the modules that are not core
    // or the runtime module before the second walk (`backend.md` §15.1,
    // *The runtime module*, amended 2026-10-15 and 2026-10-21). The second
    // walk reads the edge lists the first made, and the second lowering
    // takes each module of the first whose answers the second walk left
    // alone (#608): here every one, so each module is lowered once and
    // printed once. Before #94, `edge_lists` was two times the modules of
    // the graph and every module the first lowering took was printed two
    // times; before #608, it was lowered two times.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Html exposing (Html)
        \\import Tea
        \\
        \\
        \\type Msg
        \\    = Inc
        \\
        \\
        \\view : Int → Html Msg
        \\view count =
        \\    <button onClick={Inc}>{String.fromInt count}</button>
        \\
        \\
        \\main : Tea.Program
        \\main = Tea.sandbox { init = λ⊤ → 0, update = λ_ n → n + 1, view = view }
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=browser-tea", "--out=out", "--no-cache", "--self-profile=trace.json", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(r);
    const counters = try emitCounters(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Every module of the graph is checked here or installed from the
    // embedded core. Each module the binary carries reads its edge lists
    // from the checked core, and each other module has its lists made
    // once (`fast-compiler.md` §8, *The checked core, embedded*, amended
    // 2026-10-15).
    // A development build writes a source map beside every module it
    // printed, and nothing else ends in `.mjs.map`.
    var maps: u64 = 0;
    for (try w.listFiles("out")) |path| {
        if (std.mem.endsWith(u8, path, ".mjs.map")) maps += 1;
    }
    try testing.expect(maps != 0);
    try testing.expectEqualDeep(EmitCounters{
        .embedded_modules = counters.embedded_modules,
        .modules_checked = counters.modules_checked,
        .edge_lists = counters.modules_checked,
        .edge_lists_embedded = counters.embedded_modules,
        .reach_walks = 2,
        .modules_lowered = maps,
        .modules_printed = maps,
        .emit_units_embedded = counters.emit_units_embedded,
        .emit_units_lowered = counters.emit_units_lowered,
    }, counters);
}

test "a release page build lowers each module once" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The same page under `--release`, which keeps every lowering for
    // whole-program specialisation (`backend.md` §9) and prints the modules
    // of its one file. The first lowering takes the page's own module and
    // the platform modules that are not the runtime module; the walk from
    // the narrower roots changes no answer any of them read, so the second
    // lowering lowers only core and the runtime module (#608). Before, it
    // lowered every module again: 9 lowerings of 6 modules.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Html exposing (Html)
        \\import Tea
        \\
        \\
        \\type Msg
        \\    = Inc
        \\
        \\
        \\view : Int → Html Msg
        \\view count =
        \\    <button onClick={Inc}>{String.fromInt count}</button>
        \\
        \\
        \\main : Tea.Program
        \\main = Tea.sandbox { init = λ⊤ → 0, update = λ_ n → n + 1, view = view }
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=browser-tea", "--release", "--out=out", "--no-cache", "--self-profile=trace.json", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(r);
    const counters = try emitCounters(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // One file, and each module in it lowered once: none is lowered two
    // times, and none is lowered that the file does not hold.
    var files: u64 = 0;
    for (try w.listFiles("out")) |path| {
        if (std.mem.endsWith(u8, path, ".mjs")) files += 1;
    }
    try testing.expectEqual(1, files);
    try testing.expectEqual(2, counters.reach_walks);
    try testing.expect(counters.modules_printed > 1);
    try testing.expectEqual(counters.modules_printed, counters.modules_lowered);
}

test "a program builds the same with the edge lists the binary carries as with lists it builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A build reads the edge lists of the modules the binary carries from
    // the checked core, keyed by the module key and `--release` and
    // `--schema-library` (`fast-compiler.md` §8, *The checked core,
    // embedded*, amended 2026-10-15). A core read through `--core-root`
    // installs nothing from it, so the same program then builds every
    // module's lists. The two trees must be the same, in development and
    // under `--release`: a row that differs from the list a build would
    // make is an input its key does not cover. `run/ReleaseEverything`
    // reaches `Dict`, `List` and `String` and their patterns and derived
    // comparisons. Source maps name the core's path, which `--core-root`
    // moves, so neither build writes them.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTreeInto("core", "mycore", "_");
    try copyFixture(&w, "tests/corpus/run/ReleaseEverything.beni", "Main.beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    _ = try expectSameWithBuiltEdges(&w, "--platform=node", "dev", &.{"Main.beni"}, false);
    _ = try expectSameWithBuiltEdges(&w, "--platform=node", "release", &.{ "--release", "Main.beni" }, false);
}

test "a development build's cached units write the same source maps as a core built here" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The join splices a cached unit's text and its marks, and numbers the
    // row's name identities into this module's one source map. A map that
    // differs from the one the same module lowers to is the finding: the
    // names array's order is first-occurrence order, so a dead canonical
    // unit must not put a name behind a live one. `--core-root=mycore`
    // changes only how a map spells the core's path; the helper normalizes
    // that spelling.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTreeInto("core", "mycore", "_");
    try copyFixture(&w, "tests/corpus/run/Arithmetic.beni", "Main.beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    _ = try expectSameWithBuiltEdges(&w, "--platform=node", "maps", &.{"Main.beni"}, true);
}

test "a program that suspends builds the same with the edge lists the binary carries as with lists it builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The previous test for a suspendable body, a node of its own in an
    // edge list: `run/SuspendLoopClosure` sleeps in a loop, so it reaches
    // `Task` and the bodies of `core` that may suspend.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTreeInto("core", "mycore", "_");
    try copyFixture(&w, "tests/corpus/run/SuspendLoopClosure.beni", "Main.beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    _ = try expectSameWithBuiltEdges(&w, "--platform=node", "dev", &.{"Main.beni"}, false);
}

test "a page builds the same with the edge lists the binary carries as with lists it builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The previous test for the platform modules: a `browser-tea` page
    // reaches `browser`'s runtime module, `Http`, the markup vocabulary
    // and core's `Schema`, whose rows are keyed by a chain with markup.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTreeInto("core", "mycore", "_");
    try copyFixture(&w, "tests/corpus/browser/tea/ApiItems.beni", "Main.beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    const counters = try expectSameWithBuiltEdges(&w, "--platform=browser-tea", "page", &.{"Main.beni"}, false);
    // §9's other side: this page's build lowers 41 units it cannot take — a
    // platform unit falls back — and the trees above still match.
    try testing.expect(counters.emit_units_lowered > 0);
}

test "a program over the schema-shape threshold builds the same with the edge lists the binary carries as with lists it builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `schema.md` §6's fork gives a program over `SchemaValid.shape_threshold`
    // validator runs the shapes side, and `run/SchemaShapeThreshold` has
    // thirty. The answer is a fact a row must carry (`backend.md` §9, issue
    // #432): the rows the binary carries were made under the canonical
    // answer, and a build's own modules are on the other side of the
    // threshold only as far as their own bytes can see it. The two trees
    // must agree, at the default answer and at `--schema-shapes=never` —
    // and the two defaults must differ, or the fixture stopped crossing the
    // threshold and neither comparison says anything about the fork.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTreeInto("core", "mycore", "_");
    try copyFixture(&w, "tests/corpus/run/SchemaShapeThreshold.beni", "Main.beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    _ = try expectSameWithBuiltEdges(&w, "--platform=node", "shapes", &.{"Main.beni"}, false);
    _ = try expectSameWithBuiltEdges(&w, "--platform=node", "shapes-never", &.{ "--schema-shapes=never", "Main.beni" }, false);
    try expectDifferentTrees(&w, "shapes-embedded", "shapes-never-embedded");
}

test "a page builds the same under --release with the edge lists the binary carries as with lists it builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The `--release` rows of the platform modules, which drop the other
    // arm of each `if Js.development`: `browser/tea/SettlesManyFibers`
    // runs keyed commands as fibers, so it reaches `Tea`, `core/Task` and
    // their suspendable bodies.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTreeInto("core", "mycore", "_");
    try copyFixture(&w, "tests/corpus/browser/tea/SettlesManyFibers.beni", "Main.beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    _ = try expectSameWithBuiltEdges(&w, "--platform=browser-tea", "page", &.{ "--release", "Main.beni" }, false);
}

test "a browser-inline page builds the same with the edge lists the binary carries as with lists it builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The rows of the `browser-inline` chain, whose lowering compiles each
    // program whole with no task kernel: `browser/inline/FormLocal` reaches
    // its runtime module, `Inline` and the platform's `Tea`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTreeInto("core", "mycore", "_");
    try copyFixture(&w, "tests/corpus/browser/inline/FormLocal.beni", "Main.beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    _ = try expectSameWithBuiltEdges(&w, "--platform=browser-inline", "page", &.{"Main.beni"}, false);
}

/// One fixture of the corpus, copied into the project at `to`.
fn copyFixture(w: *World, from: []const u8, to: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(w.io, from, w.arena.allocator(), .limited(1 << 20));
    try w.write(to, bytes);
}

/// Build `args` for `platform` three times and expect three builds that
/// succeed with the same diagnostics and the same tree: into
/// `<out>-embedded` with the edge lists read from the checked core, into
/// `<out>-jobs1` the same on one thread, and into `<out>-built` with the
/// project's copy of core under `--core-root`, which reads no row and
/// builds every module's lists. The one-thread build holds the rows and the
/// walk to CLAUDE.md rule 5: workers read rows in whatever order they take
/// modules, and the tree must not show it.
fn expectSameWithBuiltEdges(w: *World, platform: []const u8, out: []const u8, args: []const []const u8, mapped: bool) !EmitCounters {
    const arena = w.arena.allocator();
    const hows = [_][]const u8{ "embedded", "jobs1", "built" };
    var dirs: [hows.len][]const u8 = undefined;
    var stderrs: [hows.len][]const u8 = undefined;
    var embedded_counters: EmitCounters = .{};
    for (hows, &dirs, &stderrs) |how, *dir, *stderr| {
        dir.* = try std.fmt.allocPrint(arena, "{s}-{s}", .{ out, how });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "build", platform, "--no-cache", "--self-profile=trace.json" });
        if (!mapped) try argv.append(arena, "--no-source-maps");
        try argv.append(arena, try std.fmt.allocPrint(arena, "--out={s}", .{dir.*}));
        if (std.mem.eql(u8, how, "jobs1")) try argv.append(arena, "--jobs=1");
        if (std.mem.eql(u8, how, "built")) try argv.append(arena, "--core-root=mycore");
        try argv.appendSlice(arena, args);
        const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        try testing.expectEqualStrings("", r.stdout);
        stderr.* = r.stderr;
        const counters = try emitCounters(w);
        if (std.mem.eql(u8, how, "embedded")) embedded_counters = counters;
        const release = blk: {
            for (args) |a| if (std.mem.eql(u8, a, "--release")) break :blk true;
            break :blk false;
        };
        if (std.mem.eql(u8, how, "built")) {
            try testing.expectEqual(@as(u64, 0), counters.edge_lists_embedded);
            try testing.expectEqual(@as(u64, 0), counters.emit_units_embedded);
        } else {
            try testing.expect(counters.edge_lists_embedded != 0);
            // A development build prints the units of the rows it reads; a
            // release build's bytes come from the release optimiser, so it
            // reads none (`backend.md` §9, *The join*).
            if (release) {
                try testing.expectEqual(@as(u64, 0), counters.emit_units_embedded);
            } else {
                try testing.expect(counters.emit_units_embedded != 0);
            }
        }
    }
    const want = try w.listFiles(dirs[0]);
    try testing.expect(want.len > 1);
    for (dirs[1..], stderrs[1..]) |dir, stderr| {
        try testing.expectEqualStrings(stderrs[0], stderr);
        const got = try w.listFiles(dir);
        try testing.expectEqual(want.len, got.len);
        for (want, got) |a, b| {
            try testing.expectEqualStrings(a, b);
            const want_bytes = try w.read(try std.fs.path.join(arena, &.{ dirs[0], a }));
            const got_bytes = try w.read(try std.fs.path.join(arena, &.{ dir, b }));
            // A source map names the core's path, and the two builds spell
            // it differently: the embedded core is `beni:///core/…`, a core
            // read through `--core-root=mycore` is the relative path from
            // the map to the file. That spelling is the only expected
            // difference; the rest — every generated position, every mapping
            // and the whole `names` array — must be byte-identical, cached
            // units included. The manifest hashes those maps, so its map
            // lines are masked; the map bytes themselves are compared here.
            const want_cmp = if (mapped and std.mem.endsWith(u8, a, ".mjs.map"))
                try comparableMapSources(arena, want_bytes)
            else if (mapped and std.mem.eql(u8, a, "_manifest.txt"))
                try comparableManifestHashes(arena, want_bytes)
            else
                want_bytes;
            const got_cmp = if (mapped and std.mem.endsWith(u8, b, ".mjs.map"))
                try comparableMapSources(arena, got_bytes)
            else if (mapped and std.mem.eql(u8, b, "_manifest.txt"))
                try comparableManifestHashes(arena, got_bytes)
            else
                got_bytes;
            testing.expectEqualStrings(want_cmp, got_cmp) catch |err| {
                std.debug.print("{s} differs between {s} and {s}\n", .{ a, dirs[0], dir });
                return err;
            };
        }
    }
    return embedded_counters;
}

/// A map's `sources` names the core two ways: `beni:///core/…` when the
/// binary carries it, the relative path from the map's directory to
/// `mycore/…` when `--core-root` reads it. Both become `core/…`, so the
/// comparison is about the map's positions rather than where its source
/// came from. The same two substitutions run on both trees, whose sources
/// are the same inputs; a source that contained either spelling would be
/// rewritten on both sides, so the rewrite cannot make two different
/// sources equal.
fn comparableMapSources(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const embedded = try std.mem.replaceOwned(u8, arena, bytes, "beni:///core/", "core/");
    return std.mem.replaceOwned(u8, arena, embedded, "../../mycore/", "core/");
}

/// A manifest hashes every file, its maps included, and a core map's hash
/// covers the source spelling `comparableMapSources` normalizes. Zero those
/// hashes on both sides: the maps themselves are compared, so the manifest
/// still holds every other file's bytes and every path. A line is the hash
/// and the path, with no size column that the two spellings could move.
fn comparableManifestHashes(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = bytes;
    var first = true;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..end];
        if (!first) try out.append(arena, '\n');
        first = false;
        if (std.mem.endsWith(u8, line, ".mjs.map")) {
            if (std.mem.indexOfScalar(u8, line, ' ')) |space| {
                try out.appendSlice(arena, "0000000000000000");
                try out.appendSlice(arena, line[space..]);
            } else try out.appendSlice(arena, line);
        } else try out.appendSlice(arena, line);
        rest = if (end < rest.len) rest[end + 1 ..] else rest[rest.len..];
    }
    return out.toOwnedSlice(arena);
}

/// Expect two output trees of the same project under different flags to
/// differ somewhere. Used to prove a fixture still sits on one side of a
/// threshold: if the two builds agreed, a comparison across the threshold
/// would say nothing about it.
fn expectDifferentTrees(w: *World, a: []const u8, b: []const u8) !void {
    const arena = w.arena.allocator();
    const left = try w.listFiles(a);
    const right = try w.listFiles(b);
    // A file one build writes and the other does not is already a
    // difference; the shape-run and worker sides of the threshold reach
    // different core modules, so their trees may hold different files.
    if (left.len != right.len) return;
    for (left, right) |fa, fb| {
        if (!std.mem.eql(u8, fa, fb)) return;
        const x = try w.read(try std.fs.path.join(arena, &.{ a, fa }));
        const y = try w.read(try std.fs.path.join(arena, &.{ b, fb }));
        if (!std.mem.eql(u8, x, y)) return;
    }
    return error.ExpectedDifference;
}

const EmitCounters = struct {
    embedded_modules: u64 = 0,
    modules_checked: u64 = 0,
    edge_lists: u64 = 0,
    edge_lists_embedded: u64 = 0,
    reach_walks: u64 = 0,
    modules_lowered: u64 = 0,
    modules_printed: u64 = 0,
    emit_units_embedded: u64 = 0,
    emit_units_lowered: u64 = 0,
};

/// Reachability's and lowering's counters (`backend.md` §9, §15.1) from
/// the `--self-profile` trace a build wrote to `trace.json`, and what they
/// are compared with.
fn emitCounters(w: *World) !EmitCounters {
    const Event = struct {
        ph: []const u8,
        args: struct {
            embedded_modules: ?u64 = null,
            modules_checked: ?u64 = null,
            edge_lists: ?u64 = null,
            edge_lists_embedded: ?u64 = null,
            reach_walks: ?u64 = null,
            modules_lowered: ?u64 = null,
            modules_printed: ?u64 = null,
            emit_units_embedded: ?u64 = null,
            emit_units_lowered: ?u64 = null,
        } = .{},
    };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read("trace.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var counters: EmitCounters = .{};
    var seen: u32 = 0;
    for (parsed.value.traceEvents) |e| {
        if (!std.mem.eql(u8, e.ph, "C")) continue;
        inline for (@typeInfo(EmitCounters).@"struct".field_names) |name| {
            if (@field(e.args, name)) |v| {
                @field(counters, name) = v;
                seen += 1;
            }
        }
    }
    if (seen != @typeInfo(EmitCounters).@"struct".field_names.len) return error.NoCounter;
    return counters;
}

const SpecCounters = struct {
    analyses: u64 = 0,
    constraints: u64 = 0,
    budget_hit: u64 = 0,
};

/// The specialiser's counters of a `--release` build of research 52's E1
/// chain of `levels` functions.
fn specCounters(levels: usize) !SpecCounters {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    const out = &source.writer;
    try out.writeAll("import Node exposing (Program)\n\n\n");
    for (1..levels + 1) |k| {
        try out.print("f{d} : Int → Int\nf{d} x =\n    if x * 3 > 1000 then\n        x\n    else\n", .{ k, k });
        if (k < levels) {
            try out.print("        f{d} x * 2 + f{d} x\n\n\n", .{ k + 1, k + 1 });
        } else try out.writeAll("        x + 1\n\n\n");
    }
    try out.writeAll("main : Program\nmain =\n    Node.print (String.fromInt (f1 7))\n");
    try w.write("Main.beni", source.written());
    const r = try w.runWith(&.{ "build", "--platform=node", "--out=out", "--no-cache", "--release", "--self-profile=trace.json", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(r);
    const Event = struct {
        ph: []const u8,
        args: struct {
            spec_solves: ?u64 = null,
            spec_solve_constraints: ?u64 = null,
            spec_solve_budget_hit: ?u64 = null,
        } = .{},
    };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read("trace.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var counters: SpecCounters = .{};
    var seen: u32 = 0;
    for (parsed.value.traceEvents) |e| {
        if (!std.mem.eql(u8, e.ph, "C")) continue;
        if (e.args.spec_solves) |v| {
            counters.analyses = v;
            seen += 1;
        }
        if (e.args.spec_solve_constraints) |v| {
            counters.constraints = v;
            seen += 1;
        }
        if (e.args.spec_solve_budget_hit) |v| {
            counters.budget_hit = v;
            seen += 1;
        }
    }
    if (seen != 3) return error.NoCounter;
    return counters;
}

test "the release specialiser writes every independent function called once in one count of the program" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §9, *A function called once is written where it is
    // called*, *As built — one count writes every independent candidate*
    // (#576): 260 `pub` functions of another module, each called once from
    // its own binding. Each is a candidate no write touches, so the first
    // count writes all of them and the second finds none: one structural
    // pass. Before, the pass wrote 256 and stopped at its cap
    // (`spec_inline_capped` 1), and a second pass, with its analysis, wrote
    // the rest.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const n = 260;
    var lib: std.Io.Writer.Allocating = .init(testing.allocator);
    defer lib.deinit();
    for (1..n + 1) |i| try lib.writer.print(
        "pub f{d} : Int → Int\nf{d} x =\n    y = x * {d}\n    z = y + x\n    case z of\n        0 →\n            1\n\n        _ →\n            z * y + {d}\n\n\n",
        .{ i, i, i, i },
    );
    try w.write("Lib.beni", lib.written());
    var main: std.Io.Writer.Allocating = .init(testing.allocator);
    defer main.deinit();
    try main.writer.writeAll("import Lib\nimport Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.printLines (List.map [ 1, 2, 3 ] λn → String.fromInt (total n))\n\n\ntotal : Int → Int\ntotal n =\n");
    for (1..n + 1) |i| try main.writer.print("    a{d} = Lib.f{d} n\n", .{ i, i });
    try main.writer.writeAll("    a1");
    for (2..n + 1) |i| try main.writer.print(" + a{d}", .{i});
    try main.writer.writeAll("\n");
    try w.write("Main.beni", main.written());

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const c = try inlineCounters(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // And `total`, called once, and since slice 6 (#676) core `List`'s
    // length setter, written into the loop that calls it once the liveness
    // read-off has left that loop's body small.
    try testing.expectEqual(@as(u64, n + 2), c.spec_inlined);
    try testing.expectEqual(@as(u64, 0), c.spec_inline_capped);
    try testing.expectEqual(@as(u64, 0), c.spec_inline_waits);
    // Since #781 the 260 are written before the first solve. The length
    // setter waits for the liveness read-off, so it takes the pass after
    // that solve, with a solve of its own and its two counts; then the
    // count of the pass that found nothing to do.
    try testing.expectEqual(@as(u64, 1), c.spec_passes);
    try testing.expectEqual(@as(u64, 2), c.spec_solves);
    try testing.expectEqual(@as(u64, 5), c.spec_inline_scans);
}

test "the release specialiser leaves a function whose call a write just copied for the next pass" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §9, *As built — one count writes every independent
    // candidate* (#576): `k` calls `g` once and `g` calls `Zed.h` once, so
    // both `g` and `h` are called from inside another candidate and are
    // taken first, in order of whole-program id — `g` before `h`, whose
    // module comes later. Writing `g` into `k` copies `g`'s body, `h`'s
    // call with it: `h` is now called twice (from the copy, and from
    // `g`'s declaration, which `prune` drops only after the pass), so the
    // count leaves it (`spec_inline_waits`) and the next pass writes it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Zed.beni",
        \\pub h : Int → Int
        \\h x =
        \\    c = x * 5
        \\    case c of
        \\        0 →
        \\            3
        \\
        \\        _ →
        \\            c + x
        \\
    );
    try w.write("Lib.beni",
        \\import Zed
        \\
        \\
        \\pub k : Int → Int
        \\k x =
        \\    a = g x
        \\    case a of
        \\        0 →
        \\            1
        \\
        \\        _ →
        \\            a * 2
        \\
        \\
        \\pub g : Int → Int
        \\g x =
        \\    b = Zed.h x
        \\    case b of
        \\        0 →
        \\            2
        \\
        \\        _ →
        \\            b * 3
        \\
    );
    try w.write("Main.beni",
        \\import Lib
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines (List.map [ 1, 2, 3 ] λn → String.fromInt (twice n))
        \\
        \\
        \\twice : Int → Int
        \\twice n =
        \\    a = Lib.k n
        \\    a * 2
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const c = try inlineCounters(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u64, 1), c.spec_inline_waits);
    // Since #781 the first pass runs before the first solve, so `h`'s
    // pass is the one pass after it.
    try testing.expectEqual(@as(u64, 1), c.spec_passes);
    // `g`, `k`, `twice` and, a pass later, `h`: every one of them; and since
    // slice 6 (#676) core `List`'s length setter, written into the loop
    // that calls it (647 → 631 bytes).
    try testing.expectEqual(@as(u64, 5), c.spec_inlined);
}

test "the release specialiser does not ask a declined call again while neither module changed" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §9, *As built — one count writes every independent
    // candidate* (#576): `R.r` is called once, in an expression, and its
    // body is statements, so `inlineAt` declines it; `Lib.f`, written into
    // `Main` in the same count, makes the pass count the program again.
    // Neither `R` nor anything else `r`'s refusal read changed, so the
    // second count does not ask it again.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("R.beni",
        \\pub r : Int → Int
        \\r x =
        \\    y = x * 3
        \\    case y of
        \\        0 →
        \\            1
        \\
        \\        _ →
        \\            y * y
        \\
        \\
        \\pub useR : Int → Int
        \\useR x =
        \\    1 + r x
        \\
    );
    try w.write("Lib.beni",
        \\pub f : Int → Int
        \\f x =
        \\    y = x * 5
        \\    case y of
        \\        0 →
        \\            3
        \\
        \\        _ →
        \\            y + x
        \\
    );
    try w.write("Main.beni",
        \\import Lib
        \\import Node exposing (Program)
        \\import R
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines (List.map [ 1, 2, 3 ] λn → String.fromInt (total n))
        \\
        \\
        \\total : Int → Int
        \\total n =
        \\    a = Lib.f n
        \\    b = R.useR n
        \\    c = R.useR (n + 1)
        \\    a + b + c
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const c = try inlineCounters(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expect(c.spec_inlined >= 1);
    try testing.expect(c.spec_inline_scans >= 2);
    try testing.expect(c.spec_inline_refusals_kept >= 1);
}

test "the release specialiser folds a run of bindings before a return in one structural pass" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §9, *Slice 9*, *As built — a fold steps back* (#589):
    // `step`'s five bindings are each read once, in order, by the record it
    // returns. Folding the last into the `return` makes the one before it
    // a binding before a `return` that reads it once and first, and the
    // fold takes it in the same walk of the list. Before, the walk went on
    // forward, so each structural pass took one binding, with an analysis
    // after each, and `max_passes` stopped the third with two left
    // (`spec_passes` 3, `spec_passes_capped` 1, `spec_solves` 4).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\type alias Box =
        \\    a : Int
        \\    b : Int
        \\    c : Int
        \\    d : Int
        \\    e : Int
        \\
        \\
        \\bump : Int → Int
        \\bump n = n * 3 + 1
        \\
        \\
        \\step : Box → Box
        \\step box =
        \\    va = bump box.a
        \\    vb = bump box.b
        \\    vc = bump box.c
        \\    vd = bump box.d
        \\    ve = bump box.e
        \\    { a = va, b = vb, c = vc, d = vd, e = ve }
        \\
        \\
        \\main : Program
        \\main =
        \\    s = step (step { a = 1, b = 2, c = 3, d = 4, e = 5 })
        \\    Node.printLines [ String.fromInt s.a, String.fromInt s.e ]
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const c = try inlineCounters(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Since #781 the structural passes run before the first solve, and
    // take all five there: the pass after the solve finds nothing.
    try testing.expectEqual(@as(u64, 0), c.spec_passes);
    try testing.expectEqual(@as(u64, 0), c.spec_passes_capped);
    try testing.expectEqual(@as(u64, 1), c.spec_solves);
}

test "the release specialiser still folds in a second pass what the first pass's scalar replacement made" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `backend.md` §9, *As built — a fold steps back* (#589): stepping
    // back takes only what the walk could already see. `use`'s record is
    // read only by its fields, so the first pass's scalar replacement,
    // which runs after constructor folding, makes it one binding per field
    // — and the second pass folds `p.y`'s binding into the `return` that
    // reads it first. The third finds nothing: no cap.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\type alias Pt =
        \\    x : Int
        \\    y : Int
        \\
        \\
        \\pair : Int → Pt
        \\pair n = { x = n + 1, y = n * 2 }
        \\
        \\
        \\use : Int → Int
        \\use n =
        \\    p = pair n
        \\    p.y * p.x
        \\
        \\
        \\main : Program
        \\main = Node.printLines [ String.fromInt (use 1), String.fromInt (use 5) ]
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const c = try inlineCounters(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Since #781 the first pass runs before the first solve: the fold is
    // the one pass after it.
    try testing.expectEqual(@as(u64, 1), c.spec_passes);
    try testing.expectEqual(@as(u64, 0), c.spec_passes_capped);
    try testing.expectEqual(@as(u64, 2), c.spec_solves);
    const js = try w.read("out/_main.mjs");
    try testing.expect(std.mem.indexOf(u8, js, "return a*2*b") != null);
}

/// Slice 5's counters and the structural loop's, from a `--release`
/// build of the project in `w`.
const InlineCounters = struct {
    spec_passes: u64 = 0,
    spec_passes_capped: u64 = 0,
    spec_solves: u64 = 0,
    spec_inline_capped: u64 = 0,
    spec_inline_scans: u64 = 0,
    spec_inlined: u64 = 0,
    spec_inline_waits: u64 = 0,
    spec_inline_refusals_kept: u64 = 0,
};

fn inlineCounters(w: *World) !InlineCounters {
    const r = try w.runWith(&.{ "build", "--platform=node", "--out=out", "--no-cache", "--release", "--self-profile=trace.json", "." }, .{ .raw_diagnostics = true });
    try expectBuilt(r);
    const Event = struct {
        ph: []const u8,
        args: struct {
            spec_passes: ?u64 = null,
            spec_passes_capped: ?u64 = null,
            spec_solves: ?u64 = null,
            spec_inline_capped: ?u64 = null,
            spec_inline_scans: ?u64 = null,
            spec_inlined: ?u64 = null,
            spec_inline_waits: ?u64 = null,
            spec_inline_refusals_kept: ?u64 = null,
        } = .{},
    };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read("trace.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var counters: InlineCounters = .{};
    var seen: u32 = 0;
    for (parsed.value.traceEvents) |e| {
        if (!std.mem.eql(u8, e.ph, "C")) continue;
        inline for (@typeInfo(InlineCounters).@"struct".field_names) |name| {
            if (@field(e.args, name)) |v| {
                @field(counters, name) = v;
                seen += 1;
            }
        }
    }
    if (seen != @typeInfo(InlineCounters).@"struct".field_names.len) return error.NoCounter;
    return counters;
}

/// A platform whose manifest declares `"exports": "program"` (boundary.md
/// §5.2, amended 2026-10-20; §9.12 (c)): its `run` returns what the entry
/// file exports, and prints each call so the program's output pins the
/// order.
fn writeExportingPlatform(w: *World) !void {
    try w.write("xplat/beni.json",
        \\{ "platform": true, "name": "exporting", "program": "Prog.Program", "runtime": "run.js", "exports": "program" }
    );
    try w.write("xplat/Prog.beni",
        \\pub foreign type Program
        \\
        \\
        \\pub foreign pure say : String → Program
        \\
    );
    try w.write("xplat/Prog.js",
        \\export const say = (line) => ({ text: line });
        \\
    );
    try w.write("xplat/run.js",
        \\import process from "node:process";
        \\
        \\export const run = (program) => {
        \\  process.stdout.write(`run: ${program.text}\n`);
        \\  return {
        \\    default: { text: program.text },
        \\    exports: (name) => {
        \\      process.stdout.write(`export ${name}\n`);
        \\      return { name };
        \\    },
        \\  };
        \\};
        \\
    );
}

test "a platform that declares exports gets an entry file that exports what run returns, in both builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // boundary.md §9.12 (c): the entry holds `run(main)`'s result as
    // `$beniProgram`, exports its `default`, and exports each name the
    // app's beni.json lists as `export { $beniExport<N> as Name }`, in the
    // list's order. Both builds export the same names, and a Node import of
    // either sees `Arena`, `Lobby` and `default`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeExportingPlatform(&w);
    try w.write("beni.json",
        \\{ "name": "arena", "exports": ["Arena", "Lobby", "$beniProgram"] }
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
    // `$beniProgram` is the entry's own binding: an export name is a
    // namespace of its own, so the listed name is legal and loads.
    try w.write("check.mjs",
        \\import * as dev from "./out/_main.mjs";
        \\import * as rel from "./rel/_main.mjs";
        \\process.stdout.write(`${Object.keys(dev).sort().join(",")} ${dev.default.text} ${dev.Arena.name}\n`);
        \\process.stdout.write(`${Object.keys(rel).sort().join(",")} ${rel.default.text} ${rel.Lobby.name} ${rel.$beniProgram.name}\n`);
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dev = try w.runWith(&.{ "build", "--platform=xplat", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(dev);
    const rel = try w.runWith(&.{ "build", "--platform=xplat", "--release", "--out=rel", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(rel);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(
        \\// Generated by `beni build` (docs/design/boundary.md §5.2): the entry file
        \\// the platform's output shape asks for.
        \\import { run as $run } from "./_platform/run.foreign.mjs";
        \\import { Main$main as $main } from "./Main.mjs";
        \\
        \\const $beniProgram = $run($main);
        \\export default $beniProgram.default;
        \\const $beniExport0 = $beniProgram.exports("Arena");
        \\export { $beniExport0 as Arena };
        \\const $beniExport1 = $beniProgram.exports("Lobby");
        \\export { $beniExport1 as Lobby };
        \\const $beniExport2 = $beniProgram.exports("$beniProgram");
        \\export { $beniExport2 as $beniProgram };
        \\
    , try w.read("out/_main.mjs"));
    // The hoisted release file ends in the same exports, compact.
    const hoisted = try w.read("rel/_main.mjs");
    try testing.expect(std.mem.indexOf(u8, hoisted, "export default $beniProgram.default;") != null);
    try testing.expect(std.mem.indexOf(u8, hoisted, "export{$beniExport0 as Arena};") != null);
    try testing.expect(std.mem.indexOf(u8, hoisted, "export{$beniExport1 as Lobby};") != null);
    try testing.expect(std.mem.indexOf(u8, hoisted, "export{$beniExport2 as $beniProgram};") != null);
    try w.expectProgram("out/_main.mjs", .{ .stdout = "run: hello\nexport Arena\nexport Lobby\nexport $beniProgram\n" });
    try w.expectProgram("rel/_main.mjs", .{ .stdout = "run: hello\nexport Arena\nexport Lobby\nexport $beniProgram\n" });
    try w.expectProgram("check.mjs", .{
        .stdout = "run: hello\nexport Arena\nexport Lobby\nexport $beniProgram\nrun: hello\nexport Arena\nexport Lobby\nexport $beniProgram\n$beniProgram,Arena,Lobby,default hello Arena\n$beniProgram,Arena,Lobby,default hello Lobby $beniProgram\n",
    });
}

test "a chain whose runtime is a module may not declare exports: check and a release build refuse it as the development build does" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // boundary.md §9.12 (c): `unknown_exports_mode` is known from the chain
    // alone (a lowering plus a markup module), so `checkEntryExports` runs
    // it for `check` and for both builds before anything is written. The
    // corpus's `build/bad/` kind runs a development build only
    // (`build/bad/ExportsWithRuntimeModule`), so the other two paths are
    // pinned here: at `ef6b6bb46` both exited 0, and the release build
    // wrote `_main.mjs`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("page/beni.json",
        \\{ "platform": true, "name": "page", "platforms": ["browser"], "reexports": ["Browser", "Html"], "exports": "program" }
    );
    try w.write("Main.beni",
        \\import Browser
        \\import Html exposing (Html)
        \\
        \\
        \\type Msg
        \\    = Inc
        \\
        \\
        \\view : Int → Html Msg
        \\view count = <p id="count">{String.fromInt count}</p>
        \\
        \\
        \\main : Browser.Program
        \\main = Browser.program { init = λ⊤ → 0, update = λInc count → count + 1, view = view }
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--platform=page", "Main.beni" });
    const rel = try w.run(&.{ "build", "--platform=page", "--release", "--out=rel", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]world.Result{ checked, rel }) |r| {
        try testing.expectEqual(@as(u8, 1), r.exit_code);
        try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
        try testing.expectEqual(diagnostic.Code.unknown_exports_mode, r.diagnostics[0].code);
        try testing.expectEqualStrings("page/beni.json", r.diagnostics[0].span.file);
    }
    try testing.expect(!w.exists("rel"));
}

test "a platform that declares exports and a project that lists none exports only default" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeExportingPlatform(&w);
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say "alone"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=xplat", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(built);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    const entry = try w.read("out/_main.mjs");
    try testing.expect(std.mem.endsWith(u8, entry, "const $beniProgram = $run($main);\nexport default $beniProgram.default;\n"));
    try w.expectProgram("out/_main.mjs", .{ .stdout = "run: alone\n" });
}

test "a project that lists exports for a platform without the key gets a warning and a build" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // boundary.md §5.2 (amended 2026-10-20): a list that does nothing is
    // almost always a mistake, so it is `exports_ignored`, a warning
    // (CLAUDE.md rule 7). The build goes on and exits 0.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeUserPlatform(&w);
    try w.write("beni.json",
        \\{ "name": "arena", "exports": ["Arena"] }
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
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqual(@as(usize, 1), built.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.exports_ignored, built.diagnostics[0].code);
    try testing.expectEqual(diagnostic.Severity.warning, built.diagnostics[0].severity);
    try testing.expectEqualStrings("beni.json", built.diagnostics[0].span.file);
    try w.expectProgram("out/_main.mjs", .{ .stdout = "hello!\n" });
}

test "a project's exports list that is a string is the manifest's exit-2 failure" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // frontend.md §10.1: a key of the wrong JSON type is an exit-2 line
    // before any source is read, as every other app-manifest fault is.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeExportingPlatform(&w);
    try w.write("beni.json",
        \\{ "name": "arena", "exports": "Arena" }
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
    const built = try w.runWith(&.{ "build", "--platform=xplat", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), built.exit_code);
    try testing.expectEqualStrings("beni: beni.json's \"exports\" must be a list of names, not a string\n", built.stderr);
    try testing.expect(!w.exists("out"));
}

test "the hidden --test-hooks flag: an if on Js.testHooks keeps the hooks' arm with the flag and drops it without, in both builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // backend.md §4, *`Js.testHooks` is the build's test hooks*: the flag
    // the corpus passes to every `workers/` build (boundary.md §9.12 (k)).
    // A test platform's module reads it; the arm the build does not take is
    // not written, so its text is absent from the output.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("hooked/beni.json",
        \\{ "platform": true, "name": "hooked", "platforms": ["node"], "reexports": ["Node"] }
    );
    try w.write("hooked/Hooks.beni",
        \\import Js
        \\
        \\
        \\--| What the build holds of the test hooks.
        \\pub probe : ⊤ → String
        \\probe ⊤ = if Js.testHooks ⊤ then "the hooks are compiled in" else "no hooks in this build"
        \\
    );
    try w.write("Main.beni",
        \\import Hooks
        \\import Node exposing (Program)
        \\
        \\
        \\main : Program
        \\main = Node.print (Hooks.probe ⊤)
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const plain = try w.run(&.{ "build", "--platform=hooked", "--out=plain", "Main.beni" });
    const hooked = try w.run(&.{ "build", "--platform=hooked", "--test-hooks", "--out=hooked", "Main.beni" });
    const release = try w.run(&.{ "build", "--platform=hooked", "--test-hooks", "--release", "--out=rel", "Main.beni" });
    const plain_release = try w.run(&.{ "build", "--platform=hooked", "--release", "--out=plain-rel", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]world.Result{ plain, hooked, release, plain_release }) |r| try testing.expectEqual(@as(u8, 0), r.exit_code);
    try w.expectProgram("plain/_main.mjs", .{ .stdout = "no hooks in this build\n" });
    try w.expectProgram("hooked/_main.mjs", .{ .stdout = "the hooks are compiled in\n" });
    try w.expectProgram("rel/_main.mjs", .{ .stdout = "the hooks are compiled in\n" });
    try w.expectProgram("plain-rel/_main.mjs", .{ .stdout = "no hooks in this build\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The dropped arm's text is in no file of the build that dropped it.
    const plain_module = try w.read("plain/_platform/Hooks.mjs");
    try testing.expect(std.mem.indexOf(u8, plain_module, "the hooks are compiled in") == null);
    try testing.expect(std.mem.indexOf(u8, plain_module, "no hooks in this build") != null);
    const hooked_module = try w.read("hooked/_platform/Hooks.mjs");
    try testing.expect(std.mem.indexOf(u8, hooked_module, "no hooks in this build") == null);
    const hoisted = try w.read("rel/_main.mjs");
    try testing.expect(std.mem.indexOf(u8, hoisted, "no hooks in this build") == null);
    const plain_hoisted = try w.read("plain-rel/_main.mjs");
    try testing.expect(std.mem.indexOf(u8, plain_hoisted, "the hooks are compiled in") == null);
}

test "a Worker built without --test-hooks holds no hook text, in both builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // boundary.md §9.12 (k): the Worker's test hooks — `/__beni/mark/<n>`
    // and `/__beni/schedulers` — are in a `--test-hooks` build only; the
    // test on `Js.testHooks` is nested, not joined with `&&`, so the hook
    // code is dropped from a build without the flag (backend.md §4).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Worker exposing (Context, Request, Response)
        \\
        \\
        \\main : Worker.Program
        \\main = Worker.program { fetch = route, objects = [] }
        \\
        \\
        \\route : Context, Request → Response
        \\route _ request = Worker.text 200 (Worker.path request)
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const plain = try w.run(&.{ "build", "--platform=cloudflare", "--out=plain", "Main.beni" });
    const hooked = try w.run(&.{ "build", "--platform=cloudflare", "--test-hooks", "--out=hooked", "Main.beni" });
    const release = try w.run(&.{ "build", "--platform=cloudflare", "--release", "--out=rel", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]world.Result{ plain, hooked, release }) |r| try testing.expectEqual(@as(u8, 0), r.exit_code);
    const plain_worker = try w.read("plain/_platform/Worker.mjs");
    try testing.expect(std.mem.indexOf(u8, plain_worker, "beni:mark") == null);
    try testing.expect(std.mem.indexOf(u8, plain_worker, "/__beni/") == null);
    const plain_task = try w.read("plain/_core/Task.mjs");
    try testing.expect(std.mem.indexOf(u8, plain_task, "schedulersListed") == null);
    const hooked_worker = try w.read("hooked/_platform/Worker.mjs");
    try testing.expect(std.mem.indexOf(u8, hooked_worker, "beni:mark") != null);
    const hoisted = try w.read("rel/_worker.mjs");
    try testing.expect(std.mem.indexOf(u8, hoisted, "beni:mark") == null);
    try testing.expect(std.mem.indexOf(u8, hoisted, "/__beni/") == null);
}
test "Tea keyed tables do not reach core Dict" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Cmd
        \\import Html
        \\import Sub
        \\import Tea
        \\
        \\main : Tea.Program
        \\main = Tea.element
        \\    { init = λ⊤ → ( 0, Cmd.keyed "job" Cmd.Restart (λsend → send 1) )
        \\    , update = λmsg _ → ( msg, Cmd.cancelAll )
        \\    , view = λn → <p>{n}</p>
        \\    , subscriptions = λ_ → Sub.listen "subscription" (λsend → send 2) identity
        \\    }
    );
    const r = try w.runWith(&.{ "build", "--platform=browser-tea", "Main.beni" }, .{ .raw_diagnostics = true });
    try expectBuilt(r);
    try testing.expect(!w.exists("out/_core/Dict.mjs"));
}

// ---- Root closures and the caches (`browser-inline.md` §8.4, amended
// 2026-10-22, *Incremental lowering and the emit cache*) --------------------

const roots_w1_base =
    \\import Html exposing (Html)
    \\
    \\
    \\pub type alias Model =
    \\    cups : Int
    \\    label : String
    \\
    \\
    \\pub init : ⊤ → Model
    \\init ⊤ = { cups = -1, label = "cups" }
    \\
    \\
    \\pub type Msg
    \\    = MakeFour
    \\
    \\
    \\pub update : Msg, Model → Model
    \\update msg model =
    \\    case msg of
    \\        MakeFour →
    \\            { model | cups = 4 }
    \\
    \\
    \\pub view : Model → Html Msg
    \\view model =
    \\    <section data-role="w1">
    \\        <button data-role="four" onClick={MakeFour}>Make it 4</button>
    \\        <p>{model.cups}</p>
    \\    </section>
    \\
;

const roots_w2_base =
    \\import Html exposing (Html)
    \\import W1
    \\
    \\
    \\pub type alias Model =
    \\    venue : String
    \\
    \\
    \\pub init : ⊤ → Model
    \\init ⊤ = { venue = "" }
    \\
    \\
    \\pub type Msg
    \\    = Write String
    \\
    \\
    \\pub update : Msg, Model → Model
    \\update msg model =
    \\    case msg of
    \\        Write typed →
    \\            { model | venue = typed }
    \\
    \\
    \\pub view : Model, W1.Model → Html Msg
    \\view model first =
    \\    <section data-role="w2">
    \\        <input data-role="venue" value={model.venue} onInput={Write} />
    \\        <output>{first.cups}</output>
    \\    </section>
    \\
;

const roots_main_base =
    \\import Browser
    \\import Html exposing (Html)
    \\import Tea
    \\import W1
    \\import W2
    \\
    \\
    \\main : Tea.Program
    \\main =
    \\    Browser.mountAt
    \\        (Tea.sandbox { init = λ⊤ → { w1 = W1.init ⊤, w2 = W2.init ⊤ }, update = update, view = view })
    \\        "root"
    \\
    \\
    \\type alias Model =
    \\    w1 : W1.Model
    \\    w2 : W2.Model
    \\
    \\
    \\type Msg
    \\    = W1Msg W1.Msg
    \\    | W2Msg W2.Msg
    \\
    \\
    \\update : Msg, Model → Model
    \\update msg model =
    \\    case msg of
    \\        W1Msg sub →
    \\            { model | w1 = W1.update sub model.w1 }
    \\
    \\        W2Msg sub →
    \\            { model | w2 = W2.update sub model.w2 }
    \\
    \\
    \\view : Model → Html Msg
    \\view model =
    \\    <div data-role="app">
    \\        {Html.map (W1.view model.w1) W1Msg}
    \\        {Html.map (W2.view model.w2 model.w1) W2Msg}
    \\    </div>
    \\
;

test "root closures: warm, cold and cache-less builds agree after each owner, reader and program edit, at every --jobs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `browser-inline.md` §8.4, amended 2026-10-22: a root's factory is
    // written by its own module from the program's root plan, and the plan
    // moves with edits the interface does not see — the writer's markup and
    // buckets, a reader's read path, the program's forwarding arm, and
    // whether a slice keeps its object. Each stage below changes one of them
    // and keeps every interface: a build that reuses the cache of the stage
    // before must write what a cold build and a build with no cache write,
    // at one job and at eight, in development and release.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const Stage = struct { w1: []const u8, w2: []const u8, main: []const u8 };
    // The writer's markup and its buckets: a second hole, of `label`.
    const w1_html = try std.mem.replaceOwned(u8, arena, roots_w1_base, "<p>{model.cups}</p>", "<p>{model.cups}</p>\n        <small>{model.label}</small>");
    // A reader's read path: `W2` reads `first.label`, not `first.cups`.
    const w2_path = try std.mem.replaceOwned(u8, arena, roots_w2_base, "{first.cups}", "{first.label}");
    // The program's forwarding arm: no longer a pure forward, so the key's
    // handler leaves `W1`'s root for the program.
    const main_arm = try std.mem.replaceOwned(u8, arena, roots_main_base, "{ model | w1 = W1.update sub model.w1 }", "{ model | w1 = W1.update sub model.w1, w2 = model.w2 }");
    // Whether the slice keeps its object: the arm rebuilds `W1`'s record.
    const w1_fresh = try std.mem.replaceOwned(u8, arena, w1_html, "{ model | cups = 4 }", "{ cups = 4, label = model.label }");
    const stages = [_]Stage{
        .{ .w1 = roots_w1_base, .w2 = roots_w2_base, .main = roots_main_base },
        .{ .w1 = w1_html, .w2 = roots_w2_base, .main = roots_main_base },
        .{ .w1 = w1_html, .w2 = w2_path, .main = roots_main_base },
        .{ .w1 = w1_html, .w2 = w2_path, .main = main_arm },
        .{ .w1 = w1_fresh, .w2 = w2_path, .main = main_arm },
    };

    for (stages, 0..) |stage, si| {
        try w.write("W1.beni", stage.w1);
        try w.write("W2.beni", stage.w2);
        try w.write("Main.beni", stage.main);
        for ([_][]const u8{ "dev", "rel" }) |mode| for ([_][]const u8{ "1", "8" }) |jobs| {
            const release = std.mem.eql(u8, mode, "rel");
            const jobs_arg = try std.fmt.allocPrint(arena, "--jobs={s}", .{jobs});
            // ┌─────────────────────────────────────────┐
            // │ EXECUTE                                 │
            // └─────────────────────────────────────────┘
            var outs: [3][]const u8 = undefined;
            for ([_][]const u8{ "warm", "cold", "none" }, &outs) |kind, *out| {
                out.* = try std.fmt.allocPrint(arena, "{s}-{d}-{s}-{s}", .{ kind, si, mode, jobs });
                var args: std.ArrayList([]const u8) = .empty;
                try args.appendSlice(arena, &.{ "build", "--platform=browser-inline", jobs_arg, try std.fmt.allocPrint(arena, "--out={s}", .{out.*}) });
                if (release) try args.append(arena, "--release");
                if (std.mem.eql(u8, kind, "warm")) {
                    // One cache directory per mode and job count, kept across
                    // the stages.
                    try args.append(arena, try std.fmt.allocPrint(arena, "--cache-dir=cache-warm-{s}-{s}", .{ mode, jobs }));
                } else if (std.mem.eql(u8, kind, "cold")) {
                    try args.append(arena, try std.fmt.allocPrint(arena, "--cache-dir=cache-cold-{d}-{s}-{s}", .{ si, mode, jobs }));
                } else try args.append(arena, "--no-cache");
                try args.appendSlice(arena, &.{ "Main.beni", "W1.beni", "W2.beni" });
                try expectBuilt(try w.runWith(args.items, .{ .raw_diagnostics = true }));
            }
            // ┌─────────────────────────────────────────┐
            // │ VERIFY OUTPUT                           │
            // └─────────────────────────────────────────┘
            try expectSameTree(&w, outs[0], outs[1]);
            try expectSameTree(&w, outs[0], outs[2]);
        };
        // ┌─────────────────────────────────────────┐
        // │ VERIFY SIDE EFFECTS                     │
        // └─────────────────────────────────────────┘
        // One job and eight write the same tree.
        try expectSameTree(&w, try std.fmt.allocPrint(arena, "none-{d}-dev-1", .{si}), try std.fmt.allocPrint(arena, "none-{d}-dev-8", .{si}));
        try expectSameTree(&w, try std.fmt.allocPrint(arena, "none-{d}-rel-1", .{si}), try std.fmt.allocPrint(arena, "none-{d}-rel-8", .{si}));
    }
    // The stages moved the output: the first stage's handler is `W1`'s own,
    // the fourth's the program's, and the last one's root reads its slice
    // through the model.
    const first = try w.read("none-0-dev-1/W1.mjs");
    try testing.expect(std.mem.indexOf(u8, first, "W1$update$$arm$0($model$") != null);
    const fourth = try w.read("none-3-dev-1/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, fourth, "W1$update$$arm$0(") != null);
}

test "the list sanitiser runs only where ownership is enforced, and writes its runtime only there" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §7.3: the sanitiser judges the writes the checker
    // accepted. A build that does not enforce accepts nothing, so the flag
    // there would pass every program and check none: it is refused. Where
    // the build enforces, the program prints what the plain build prints.
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
        \\    Node.print (String.fromInt (List.length (List.push [ 1, 2 ] 3)))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const raw: world.RunOptions = .{ .raw_diagnostics = true };
    const refused = try w.runWith(&.{ "build", "--platform=node", "--sanitize-lists", "--out=refused", "Main.beni" }, raw);
    const plain = try w.run(&.{ "build", "--platform=node", "--ownership-everywhere", "--out=plain", "Main.beni" });
    const sanitised = try w.run(&.{ "build", "--platform=node", "--ownership-everywhere", "--sanitize-lists", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), refused.exit_code);
    try testing.expectEqualStrings("beni: --sanitize-lists needs a build that enforces ownership: an in-place platform, --ownership-everywhere or --records-in-place\n", refused.stderr);
    try testing.expectEqual(@as(u8, 0), plain.exit_code);
    try testing.expectEqual(@as(u8, 0), sanitised.exit_code);
    try w.expectProgram("out/_main.mjs", .{ .stdout = "3\n" });
    // ┌─────────────────────────────────────────┐
    // │ VERIFY FILES                            │
    // └─────────────────────────────────────────┘
    try testing.expect(std.mem.indexOf(u8, try w.read("out/Main.mjs"), "_core/_sanitize.mjs") != null);
    try testing.expect(std.mem.indexOf(u8, try w.read("plain/Main.mjs"), "_sanitize") == null);
    _ = try w.read("out/_core/_sanitize.mjs");
    for (try w.listFiles("plain")) |rel| try testing.expect(std.mem.indexOf(u8, rel, "_sanitize") == null);
}

test "the ownership checker v2 runs behind --ownership=v2 in check, build and dump" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §8, S3a: v2 is built behind the hidden
    // `--ownership=v2`. `held` reads `xs` after `List.push` writes it: on a
    // chain that enforces, v2 refuses it as v1 does, with v1's code; where
    // nothing enforces, the build is made and runs.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\held : List Int → List Int × List Int
        \\held xs = ( xs, List.push xs 1 )
        \\
        \\
        \\main : Program
        \\main =
        \\    case held [ 1 ] of
        \\        ( a, b ) →
        \\            Node.print (String.fromInt (List.length a + List.length b))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const raw: world.RunOptions = .{ .raw_diagnostics = true };
    const check = try w.runWith(&.{ "check", "--ownership=v2", "--ownership-everywhere", "--platform=node", "Main.beni" }, raw);
    const v1 = try w.runWith(&.{ "check", "--ownership=v1", "--ownership-everywhere", "--platform=node", "Main.beni" }, raw);
    const build = try w.run(&.{ "build", "--ownership=v2", "--platform=node", "Main.beni" });
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--platform=node", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), check.exit_code);
    try testing.expect(std.mem.indexOf(u8, check.stderr, "LIST CHANGED WHILE STILL IN USE") != null);
    try testing.expect(std.mem.indexOf(u8, check.stderr, "Main.beni:5:17") != null);
    try testing.expectEqual(@as(u8, 1), v1.exit_code);
    try testing.expect(std.mem.indexOf(u8, v1.stderr, "LIST CHANGED WHILE STILL IN USE") != null);
    try testing.expectEqual(@as(u8, 0), build.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  5:17 List.push xs: rejected later-use: xs is read again at 5:11\n") != null);
}

test "dump --ownership-both prints v1's report, a marker line, then v2's, from one check" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §7.2: the corpus harness's parity dumps a program
    // under both checkers in one process. The two halves are exactly the
    // reports the two separate dumps print.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\held : List Int → List Int × List Int
        \\held xs = ( xs, List.push xs 1 )
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const both = try w.run(&.{ "dump", "--stage=ownership", "--ownership-both", "--ownership-everywhere", "--platform=node", "Main.beni" });
    const v1 = try w.run(&.{ "dump", "--stage=ownership", "--ownership-everywhere", "--platform=node", "Main.beni" });
    const v2 = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--ownership-everywhere", "--platform=node", "Main.beni" });
    const refused = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership-both", "--ownership=v2", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), both.exit_code);
    const want = try std.mem.concat(w.arena.allocator(), u8, &.{ v1.stdout, "== ownership v2\n", v2.stdout });
    try testing.expectEqualStrings(want, both.stdout);
    try testing.expect(std.mem.indexOf(u8, v1.stdout, "List.push xs: rejected") != null);
    try testing.expectEqual(@as(u8, 2), refused.exit_code);
}

test "an ownership dump stops when its verdicts are not the module check's" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The report is computed again after the module check; under runtime
    // safety the two must agree site by site (`checkVerdicts`), whether or
    // not core is read from the checked core (#1106). The hidden
    // `--ownership-skew-sites` forgets what the check observed.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\held : List Int → List Int × List Int
        \\held xs = ( xs, List.push xs 1 )
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const raw: world.RunOptions = .{ .raw_diagnostics = true };
    const plain = try w.runWith(&.{ "dump", "--stage=ownership", "Main.beni" }, raw);
    const skewed = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership-skew-sites", "Main.beni" }, raw);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), plain.exit_code);
    try testing.expect(skewed.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, skewed.stderr, "serial and DAG verdicts differ") != null);
}

test "an ownership dump checks only the program and reads core's facts from the checked core" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1106: `dump --stage=ownership` checked all of core from source in
    // every process (0.2 to 0.3 s a program). It now reads core's
    // ownership blocks as `check` does: one module is checked, core's are
    // installed, under both checkers.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\held : List Int → List Int
        \\held xs = List.push (List.map xs (λx → x + 1)) 1
        \\
    );
    const arena = w.arena.allocator();
    for ([_][]const u8{ "--ownership=v1", "--ownership=v2" }) |side| {
        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const r = try w.run(&.{ "dump", "--stage=ownership", side, "--self-profile=profile.json", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, try w.read("profile.json"), .{});
        var checked: ?i64 = null;
        var embedded: ?i64 = null;
        for (root.object.get("traceEvents").?.array.items) |event| {
            const args = event.object.get("args") orelse continue;
            if (args != .object) continue;
            if (args.object.get("modules_checked")) |v| checked = v.integer;
            if (args.object.get("embedded_modules")) |v| embedded = v.integer;
        }
        try testing.expectEqual(@as(?i64, 1), checked);
        try testing.expect((embedded orelse 0) > 0);
    }
}

test "under --ownership=v2 a storage word on a value of no storage kind is misplaced_ownership_word" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.13.6 (#1056 item 4): lowering checks where a word
    // stands; whether the type there IS a sequence or a cell needs the
    // types, so the checker v2's signature adapter checks it. `bump`'s
    // `written` stands on an `Int`; `grow`'s on a `List`, which is right.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("platform/beni.json",
        \\{ "platform": true, "name": "words-test", "program": "Prog.Program", "runtime": "runtime.js" }
        \\
    );
    try w.write("platform/runtime.js",
        \\export function initialize(main) {}
        \\
    );
    try w.write("platform/Prog.beni",
        \\pub type Program
        \\    = Program
        \\
        \\
        \\pub bump : written Int → Int
        \\bump n = n + 1
        \\
        \\
        \\pub grow : written List Int → List Int
        \\grow xs = xs
        \\
    );
    try w.write("Main.beni",
        \\import Prog
        \\
        \\
        \\main : Prog.Program
        \\main = Prog.Program
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const raw: world.RunOptions = .{ .raw_diagnostics = true };
    const v2 = try w.runWith(&.{ "check", "--ownership=v2", "--platform=platform", "Main.beni" }, raw);
    const v1 = try w.runWith(&.{ "check", "--platform=platform", "Main.beni" }, raw);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), v2.exit_code);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, v2.stderr, "MISPLACED OWNERSHIP WORD"));
    try testing.expect(std.mem.indexOf(u8, v2.stderr, "`written` reads a list, a cell or a dictionary that parameter 1 of `bump` is") != null);
    try testing.expectEqual(@as(u8, 0), v1.exit_code);
}

test "@ownership_summary_size raises the checker v2's growth allowance, the declaration's over the module's" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §4.4: the attribute reaches the walk. The dump's
    // `account` lines (v2's own, R-7.15) name each owner's allowance R_f.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\@ownership_summary_size(module, 131072)
        \\
        \\
        \\@ownership_summary_size(262144)
        \\large : ⊤ → List Int
        \\large ⊤ = [ 1, 2 ]
        \\
        \\
        \\plain : ⊤ → List Int
        \\plain ⊤ = [ 3 ]
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  account large: ") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, " of 262144, total ") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, " of 131072, total ") != null);
}

/// The `total` of `account <owner>:` in a v2 dump.
fn accountTotal(dump: []const u8, owner: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, dump, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " ");
        if (!std.mem.startsWith(u8, t, "account ")) continue;
        if (!std.mem.startsWith(u8, t["account ".len..], owner) or t["account ".len + owner.len] != ':') continue;
        const at = std.mem.lastIndexOf(u8, t, "total ") orelse return error.NoTotal;
        const digits = t[at + "total ".len ..];
        const end = std.mem.indexOfNone(u8, digits, "0123456789") orelse digits.len;
        return std.fmt.parseInt(u64, digits[0..end], 10);
    }
    return error.NoAccount;
}

test "the checker v2's work grows linearly with a declaration's statements and its live holders" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §4.1, §2.8: a chain of k writes, each the next's
    // base, and k live lists each written once while all the others are
    // still held. Holders come from the live inverted index, never a scan
    // of the scope, so twice the statements costs about twice the records
    // (counted by the owner's account, N_f), not four times.
    var counts: [2]u64 = undefined;
    var lives: [2]u64 = undefined;
    for ([_]u32{ 100, 200 }, 0..) |n, run| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(testing.allocator);
        const a = testing.allocator;
        try src.appendSlice(a, "pub chain : ⊤ → Int\nchain ⊤ =\n    x0 = [ 0 ]\n");
        for (1..n + 1) |i| try src.print(a, "    x{d} = List.push x{d} {d}\n", .{ i, i - 1, i });
        try src.print(a, "    List.length x{d}\n\n\npub live : ⊤ → Int\nlive ⊤ =\n", .{n});
        for (1..n + 1) |i| try src.print(a, "    a{d} = [ {d} ]\n", .{ i, i });
        for (1..n + 1) |i| try src.print(a, "    b{d} = List.push a{d} 0\n", .{ i, i });
        try src.appendSlice(a, "    0");
        for (1..n + 1) |i| try src.print(a, " + List.length b{d}", .{i});
        try src.appendSlice(a, "\n");
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        counts[run] = try accountTotal(dump.stdout, "chain");
        lives[run] = try accountTotal(dump.stdout, "live");
        try testing.expect(std.mem.indexOf(u8, dump.stdout, try std.fmt.allocPrint(w.arena.allocator(), "total {d}: accepted {d} (fresh {d},", .{ 2 * n, 2 * n, 2 * n })) != null);
    }
    try testing.expect(counts[1] * 10 <= counts[0] * 25);
    try testing.expect(lives[1] * 10 <= lives[0] * 25);
}

test "the checker v2's published blocks are the same bytes at one job and at eight" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §3.8 and rule 5: a block's bytes never depend on
    // thread timing or on a session id. The dump names each module's block
    // by its size and a hash of its bytes; three modules checked in
    // parallel, records with fields interned in different orders, and a
    // shared value one module reads from another.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("A.beni",
        \\pub type alias Row =
        \\    { zeta : List Int, alpha : List Int }
        \\
        \\
        \\pub table : List Int
        \\table =
        \\    [ 1, 2 ]
        \\
        \\
        \\pub grow : Row → Row
        \\grow r =
        \\    { zeta = List.push r.zeta 1, alpha = r.alpha }
        \\
    );
    try w.write("B.beni",
        \\import A
        \\
        \\
        \\pub pick : List (List Int) → List Int
        \\pick xss =
        \\    case xss of
        \\        [ a, …_ ] →
        \\            List.push a 1
        \\
        \\        _ →
        \\            A.table
        \\
    );
    try w.write("Main.beni",
        \\import A
        \\import B
        \\
        \\
        \\pub both : List (List Int) → List Int × A.Row
        \\both xss =
        \\    ( B.pick xss, { alpha = [], zeta = [ 2 ] } )
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    var dumps: [4][]const u8 = undefined;
    for (&dumps, [_][]const u8{ "--jobs=1", "--jobs=8", "--jobs=1", "--jobs=8" }) |*d, jobs| {
        const r = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", jobs, "." });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        d.* = r.stdout;
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, dumps[0], "  block: "));
    for (dumps[1..]) |d| try testing.expectEqualStrings(dumps[0], d);
}

test "the checker v2 reads a pattern element's write off at its canonical position, and a sibling's condition into xreq" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.2, §2.10: `elem(π1·ι)` is `π1[*]`, so a write to
    // a pattern's element marks `π1[*]` written, not the outer list `π1`
    // (a caller that holds an element must see it). Another position the
    // body still reads rests on the elements being exclusive: `xreq`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\pub first : List (List Int) → List Int
        \\first xss =
        \\    case xss of
        \\        [ a, …_ ] →
        \\            List.push a 1
        \\
        \\        _ →
        \\            []
        \\
        \\
        \\pub siblings : List (List Int) → List Int × List Int
        \\siblings xss =
        \\    case xss of
        \\        [ p, q ] →
        \\            ( List.push p 9, q )
        \\
        \\        _ →
        \\            ( [], [] )
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary first: π1 R, π1[*] RAW, π1[*][*] A;") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary siblings: π1 R, π1[*] RAW, π1[*][*] A;") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "; xreq excl π1[*]\n") != null);
}

test "the checker v2's dump names a shared value, a method call, and gives lists' == and < their derived class" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.13.13, R-7.15: `writeTop`'s class names the
    // top-level value it returns, `helper`; `xs.push 1` is `List.push`; a
    // list's `==` and `<` dispatch to `List.eq`/`List.compare`, written in
    // JavaScript with no words, over derived element evidence: the derived
    // class, read-only, never the pessimistic one.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\pub other : List Int
        \\other =
        \\    [ 9 ]
        \\
        \\
        \\helper : List Int
        \\helper =
        \\    [ 1 ]
        \\
        \\
        \\pub writeTop : ⊤ → List Int
        \\writeTop ⊤ =
        \\    List.push helper 3
        \\
        \\
        \\pub method : List Int → List Int × List Int
        \\method xs =
        \\    ys = xs.push 1
        \\    ( ys, xs )
        \\
        \\
        \\pub same : List Int, List Int → Bool
        \\same a b =
        \\    a == b
        \\
        \\
        \\pub less : List Int, List Int → Bool
        \\less a b =
        \\    a < b
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "shared(helper)") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "shared(other)") == null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, " List.push xs: rejected later-use: xs is read again at ") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary same: π1 R, π2 R\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary less: π1 R, π2 R\n") != null);
}

/// A family of the holder index's (`ownership-v2.md` §2.8 *The holder
/// index*, §4.1), `n` wide: its source and the declaration it measures.
fn holderFamily(a: std.mem.Allocator, family: []const u8, n: u32) !struct { []const u8, []const u8 } {
    var src: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, family, "sites")) {
        // One value spread at n sites, every site's result read at the end.
        try src.appendSlice(a, "pub spread : List Int → List (List (List Int))\nspread ys =\n    v = [ [ 0 ] ]\n");
        for (1..n + 1) |i| try src.print(a, "    a{d} = [ …v, ys ]\n", .{i});
        try src.appendSlice(a, "    [ ");
        for (1..n + 1) |i| try src.print(a, "{s}a{d}", .{ if (i == 1) "" else ", ", i });
        try src.appendSlice(a, " ]\n");
        return .{ src.items, "spread" };
    }
    if (std.mem.eql(u8, family, "pending")) {
        // n pending operands of one literal, each a spread of one value.
        try src.appendSlice(a, "pub ops : List Int → List (List Int)\nops xs =\n    [ ");
        for (1..n + 1) |i| try src.print(a, "{s}[ …xs, {d} ]", .{ if (i == 1) "" else ", ", i });
        try src.appendSlice(a, " ]\n");
        return .{ src.items, "ops" };
    }
    // A helper reading one field, called after an edit of each of n others.
    try src.appendSlice(a, "type alias R =\n    tag : Int\n");
    for (1..n + 1) |i| try src.print(a, "    f{d} : List Int\n", .{i});
    try src.appendSlice(a, "\n\ntagOf : R → Int\ntagOf r =\n    r.tag\n\n\npub edits : R → Int\nedits r =\n");
    for (1..n + 1) |i| try src.print(a, "    p{d} = List.push r.f{d} {d}\n", .{ i, i, i });
    try src.appendSlice(a, "    0");
    for (1..n + 1) |i| try src.print(a, " + tagOf r + List.length p{d}", .{i});
    try src.appendSlice(a, "\n");
    return .{ src.items, "edits" };
}

test "the checker v2's holder index answers a frame's demands in records linear in its holders and uses" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.8 *The holder index*, §4.1 (#1214): one value
    // spread at n sites, n pending operands of one literal, and a helper
    // that reads one field called after an edit of each of n others. The
    // live index read every holder (and every rejected `call` use) per
    // demand: n × n, a lane past its ceiling for the helper at 100. The
    // sweep's records for Demands grow with n, at most 4.4 times from 25
    // to 100.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    for ([_][]const u8{ "sites", "pending", "fields" }) |family| {
        var cost: [2]u64 = undefined;
        for ([_]u32{ 25, 100 }, 0..) |n, run| {
            const f = try holderFamily(a, family, n);
            try w.write("Main.beni", f[0]);

            // ┌─────────────────────────────────────────┐
            // │ EXECUTE                                 │
            // └─────────────────────────────────────────┘
            const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

            // ┌─────────────────────────────────────────┐
            // │ VERIFY OUTPUT                           │
            // └─────────────────────────────────────────┘
            try testing.expectEqual(@as(u8, 0), dump.exit_code);
            try testing.expect(std.mem.indexOf(u8, dump.stdout, "limit ") == null);
            try testing.expectEqual(@as(u64, 0), try accountField(dump.stdout, f[1], "growth"));
            cost[run] = try accountField(dump.stdout, f[1], "demands");
        }
        if (cost[1] * 10 > cost[0] * 44) {
            std.debug.print("{s}: {d} records at 25, {d} at 100\n", .{ family, cost[0], cost[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "the checker v2 pairs k opaque holders with k edits in records linear in k" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.8's inversion (#1214): k `Js.Value`s built from
    // lists, then k pushes, every value read again. A `⊤` holder is paired
    // only through a cell it holds that may be the base; the live index
    // asked every opaque holder at every push (k²). From 25 to 100 the
    // sweep's records grow at most 4.4 times. `core/TopHoldersMany` pins the
    // verdicts.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    var cost: [2]u64 = undefined;
    for ([_]u32{ 25, 100 }, 0..) |k, run| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "import Js\n\n\nmany zs xs =\n");
        for (1..k + 1) |i| try src.print(a, "    o{d} = Js.array [ Js.from (List.push zs {d}) ]\n", .{ i, i });
        for (1..k + 1) |i| try src.print(a, "    y{d} = List.push xs {d}\n", .{ i, i });
        try src.appendSlice(a, "    Js.array [ ");
        for (1..k + 1) |i| try src.print(a, "{s}o{d}, Js.from y{d}", .{ if (i == 1) "" else ", ", i, i });
        try src.appendSlice(a, " ]\n");
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--core", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "limit ") == null);
        cost[run] = try accountField(dump.stdout, "many", "demands");
    }
    if (cost[1] * 10 > cost[0] * 44) {
        std.debug.print("opaque holders: {d} records at 25, {d} at 100\n", .{ cost[0], cost[1] });
        return error.TestUnexpectedResult;
    }
}

test "the checker v2 charges a deep witness path a record a step, and nothing else grows" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.8 step 3, §4.1 (#1214): `mk = ( lk, mk-1 )` to n,
    // then a push of every `lk` while `mn` is read: `mn` holds `lk` at a path
    // of n - k steps, so the n witnesses are n²/2 steps, inherent and each a
    // record. The work of a step is constant: a child's uses are found inside
    // its parent's range by its one step, and no step allocates (a review
    // measured 8.4 s at n = 400 where master took 3.2 s, the same records).
    // From 40 to 80 the records grow at most 4.4 times.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    var cost: [2]u64 = undefined;
    for ([_]u32{ 40, 80 }, 0..) |n, run| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "pub deep u =\n");
        for (1..n + 1) |k| try src.print(a, "    l{d} = [ {d} ]\n", .{ k, k });
        try src.appendSlice(a, "    m0 = ( [], 0 )\n");
        for (1..n + 1) |k| try src.print(a, "    m{d} = ( l{d}, m{d} )\n", .{ k, k, k - 1 });
        for (1..n + 1) |k| try src.print(a, "    p{d} = List.push l{d} 9\n", .{ k, k });
        try src.print(a, "    String.length (Debug.toString m{d})", .{n});
        for (1..n + 1) |k| try src.print(a, " + List.length p{d}", .{k});
        try src.appendSlice(a, "\n");
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "limit ") == null);
        try testing.expectEqual(@as(u64, 0), try accountField(dump.stdout, "deep", "growth"));
        cost[run] = try accountField(dump.stdout, "deep", "demands");
    }
    if (cost[1] * 10 > cost[0] * 44) {
        std.debug.print("deep witnesses: {d} records at 40, {d} at 80\n", .{ cost[0], cost[1] });
        return error.TestUnexpectedResult;
    }
}

test "the checker v2 finds the best hold of a doubling DAG of depth 12 without listing its paths" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.8 step 3 (#1214): `t0 = ( xs, xs )`,
    // `tk = ( tk-1, tk-1 )` to depth d, 2^d paths to `xs`, then a push of
    // `xs` while `td` is read. Listing the hold paths reached
    // `ownership_summary_size` at 12; the best-hold descent names the least
    // path a step a level: from depth 8 to 12 its records grow at most by
    // half, and no cover falls back to listing (a stale read of a child
    // once did, silently, and grew 16 times). v1 cannot check it, so it is
    // no corpus fixture.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    var cost: [2]u64 = undefined;
    for ([_]u32{ 8, 12 }, 0..) |depth, run| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "pub doubling : List Int → Int\ndoubling xs =\n    t0 = ( xs, xs )\n");
        for (1..depth + 1) |k| try src.print(a, "    t{d} = ( t{d}, t{d} )\n", .{ k, k - 1, k - 1 });
        try src.print(a, "    ys = List.push xs 1\n    List.length ys + String.length (Debug.toString t{d})\n", .{depth});
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "limit ") == null);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "hold listings") == null);
        if (depth == 12) try testing.expect(std.mem.indexOf(u8, dump.stdout, " List.push xs: rejected alias: t12.0.0.0.0.0.0.0.0.0.0.0.0.0 holds it and is read at ") != null);
        try testing.expectEqual(@as(u64, 0), try accountField(dump.stdout, "doubling", "growth"));
        cost[run] = try accountField(dump.stdout, "doubling", "demands");
    }
    if (cost[1] * 2 > cost[0] * 3) {
        std.debug.print("doubling DAG: {d} records at depth 8, {d} at 12\n", .{ cost[0], cost[1] });
        return error.TestUnexpectedResult;
    }
}

test "the checker v2's work over live sibling positions is flat per position" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.8, §4.1: `[ p1 … pn ]` taken from one list, every
    // `pi` pushed inside one literal. Each position's siblings answer
    // `under` one split, read once from the refinement chain's group for
    // that split, and the literal's `apart` decides one split's run by one
    // pair: the owner's records grow with n, not n².
    var per: [4]u64 = undefined;
    for ([_]u32{ 10, 20, 40, 80 }, 0..) |n, run| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const a = testing.allocator;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "pub f : List (List Int) → List (List Int)\nf xs =\n    case xs of\n        [ ");
        for (1..n + 1) |i| try src.print(a, "{s}p{d}", .{ if (i == 1) "" else ", ", i });
        try src.appendSlice(a, " ] →\n            [ ");
        for (1..n + 1) |i| try src.print(a, "{s}List.push p{d} 1", .{ if (i == 1) "" else ", ", i });
        try src.appendSlice(a, " ]\n\n        _ →\n            []\n");
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "limit ") == null);
        per[run] = try accountTotal(dump.stdout, "f") / n;
    }
    // Flat per position: the largest within a quarter of the smallest (a
    // pairwise scan grows it by half from 10 to 80).
    try testing.expect(4 * std.mem.max(u64, &per) <= 5 * std.mem.min(u64, &per));
}

/// The number after `field ` on `owner`'s `account` line.
fn accountField(dump: []const u8, owner: []const u8, field: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, dump, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " ");
        if (!std.mem.startsWith(u8, t, "account ")) continue;
        if (!std.mem.startsWith(u8, t["account ".len..], owner) or t["account ".len + owner.len] != ':') continue;
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, " {s} ", .{field});
        const at = std.mem.indexOf(u8, t, key) orelse return error.NoField;
        const digits = t[at + key.len ..];
        const end = std.mem.indexOfNone(u8, digits, "0123456789") orelse digits.len;
        return std.fmt.parseInt(u64, digits[0..end], 10);
    }
    return error.NoAccount;
}

test "the checker v2's cold run applies no class the warm run stopped at a limit" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1261's review: `w_k x = w_{k-1} (w_{k-1} x)` over `w1 x = ( x, x )`.
    // The warm run stops `w12` at its limit, so `w13` and `main` are not
    // built at their calls. The dump's cold run walked the callees again
    // with no limit and applied `w12`'s class: `w13`'s and `main`'s cold
    // accounts spent the whole allowance. They are walked as the warm run
    // walks them.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "w1 x = ( x, x )\n");
    for (2..14) |k| try src.print(a, "\n\nw{d} x = w{d} (w{d} x)\n", .{ k, k - 1, k - 1 });
    try src.appendSlice(a, "\n\npub main : List Int → Int\nmain xs =\n    t = w13 xs\n    List.length xs\n");
    try w.write("Main.beni", src.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "limit w12: ownership_summary_size") != null);
    try testing.expectEqual(@as(u64, 0), try accountField(dump.stdout, "w13", "growth"));
    try testing.expectEqual(@as(u64, 0), try accountField(dump.stdout, "main", "growth"));
}

test "the checker v2 leaves unchecked a caller of an imported eq whose walk a limit stopped" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.13.13: `Lib.eq` is written in beni, so `==` on
    // `Key` is not a derived, read-only comparison. `eq` calls `w12`, whose
    // walk the allowance stops, so the block says an importer may not apply
    // it: `bad` is unchecked, never accepted with `xs` kept beside `==`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "pub type Key =\n    Key (List Int)\n\n\nw1 x = ( x, x )\n");
    for (2..13) |k| try src.print(a, "\n\nw{d} x = w{d} (w{d} x)\n", .{ k, k - 1, k - 1 });
    try src.appendSlice(a, "\n\npub eq : Key, Key → Bool\neq a b =\n    case a of\n        Key l →\n            t = w12 (w12 l)\n            List.length l > 0\n");
    try w.write("Lib.beni", src.items);
    try w.write("Main.beni", "import Lib\n\n\npub bad : List Int → Bool × List Int\nbad xs = ( Lib.Key xs == Lib.Key [], xs )\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--root=.", "." });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "limit w12: ownership_summary_size") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  unchecked bad: lines 4-5 (not built: method_call)\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary bad: π1 RA") == null);
}

/// The continuation `owner`'s walk spent, from `dump`, for a source of `n`
/// statements: the cost-per-call guards below compare it at n and 4n.
fn continuationFor(w: *World, src: []const u8, owner: []const u8) !u64 {
    try w.write("Main.beni", src);
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expectEqual(@as(u64, 0), try accountField(dump.stdout, owner, "growth"));
    return accountField(dump.stdout, owner, "continuation");
}

test "the checker v2's call costs are flat per call through chains of calls and linear in a result's depth" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.11 *Representation of a view*, the review's
    // points 3–4, pinned before calls answer views so slice 2b keeps them:
    // `y_k = id y_{k-1}` (an identity tower) and a push through a depth-d
    // path. At n and 4n calls the caller's continuation is at most 4n's share
    // plus a tenth; at depths d and 2d at most twice d's plus a tenth. Point
    // 2, the chain of joins `y_k = pick c y_{k-1} (List.push z k)`, is flat
    // too since #1214's holder index: each holder's join chain is walked once
    // for the frame, its `apply`, read-off and publish share flat
    // (`CallChainShare`).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var cost: [2][3]u64 = undefined;
    for ([_]u32{ 50, 200 }, 0..) |n, run| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "pick : Bool, List Int, List Int → List Int\npick c a b =\n    if c then a else b\n\n\npub chain : Bool, List Int → Int\nchain c z =\n    y0 = [ 0 ]\n");
        for (1..n + 1) |k| try src.print(a, "    y{d} = pick c y{d} (List.push z {d})\n", .{ k, k - 1, k });
        try src.print(a, "    List.length y{d}\n", .{n});
        cost[run][0] = try continuationFor(&w, src.items, "chain");
        src.clearRetainingCapacity();
        try src.appendSlice(a, "id : List Int → List Int\nid x = x\n\n\npub tower : List Int → List Int\ntower y0 =\n");
        for (1..n + 1) |k| try src.print(a, "    y{d} = id y{d}\n", .{ k, k - 1 });
        try src.print(a, "    List.push y{d} 1\n", .{n});
        cost[run][1] = try continuationFor(&w, src.items, "tower");
    }
    for ([_]u32{ 32, 64 }, 0..) |d, run| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.print(a, "type alias R{d} =\n    x : List Int\n", .{d});
        var k = d - 1;
        while (k >= 1) : (k -= 1) try src.print(a, "\n\ntype alias R{d} =\n    a : R{d}\n", .{ k, k + 1 });
        try src.appendSlice(a, "\n\ndeepPush : R1 → List Int\ndeepPush r = List.push r");
        for (1..d) |_| try src.appendSlice(a, ".a");
        try src.appendSlice(a, ".x 1\n\n\npub caller : R1 → List Int\ncaller r = deepPush r\n");
        cost[run][2] = try continuationFor(&w, src.items, "caller");
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for (0..3) |i| {
        if (cost[1][i] * 10 > cost[0][i] * 44) {
            std.debug.print("guard {d}: {d} at the first size, {d} at the second\n", .{ i, cost[0][i], cost[1][i] });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(cost[1][2] * 10 <= cost[0][2] * 22);
}

/// The `total` of `owner`'s account in a v2 dump of `src` as `Main.beni`,
/// growth 0 and no declaration past a limit.
fn ownTotalFor(w: *World, src: []const u8, owner: []const u8) !u64 {
    try w.write("Main.beni", src);
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    // No declaration past a limit: a limit leaves a small, unbuilt class.
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "\n  limit ") == null);
    try testing.expectEqual(@as(u64, 0), try accountField(dump.stdout, owner, "growth"));
    return accountTotal(dump.stdout, owner);
}

test "the checker v2's read-off of a call's reads is linear in a chain of field wrappers" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.7, §2.10's read-off (#1325): `f_i g = f_{i-1}
    // g.x` reads `π1.x`, `π1.x.x`, … below its argument, i paths. The
    // callee's use is grafted once, never rebuilt from the root per path, so
    // the last wrapper's records grow with its use's width: at 100 wrappers
    // at most 11 times those at 10, not 100 times.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var totals: [2]u64 = undefined;
    for ([_]u32{ 10, 100 }, 0..) |n, run| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "f1 g = List.length g.x\n");
        for (2..n + 1) |i| try src.print(a, "\n\nf{d} g = f{d} g.x\n", .{ i, i - 1 });
        var owner: [8]u8 = undefined;
        totals[run] = try ownTotalFor(&w, src.items, try std.fmt.bufPrint(&owner, "f{d}", .{n}));
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (totals[1] > totals[0] * 11) {
        std.debug.print("f10: {d} records, f100: {d}\n", .{ totals[0], totals[1] });
        return error.TestUnexpectedResult;
    }
}

test "the checker v2's read-off of a call's reads keeps a use shape that is a DAG a DAG" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.7, §2.10's read-off (#1325): `d_i ( a, b ) =
    // d_{i-1} a + d_{i-1} b` reads both halves the same way, so its use
    // shape is a DAG of depth i with 2^i paths. The graft is memoised per
    // node pair and a call walks a read-only use per node, so depth 12 costs
    // at most twice depth 6, never 64 times.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var totals: [2]u64 = undefined;
    for ([_]u32{ 6, 12 }, 0..) |n, run| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "d1 ( a, b ) = List.length a + List.length b\n");
        for (2..n + 1) |i| try src.print(a, "\n\nd{d} ( a, b ) = d{d} a + d{d} b\n", .{ i, i - 1, i - 1 });
        var owner: [8]u8 = undefined;
        totals[run] = try ownTotalFor(&w, src.items, try std.fmt.bufPrint(&owner, "d{d}", .{n}));
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (totals[1] > totals[0] * 2) {
        std.debug.print("d6: {d} records, d12: {d}\n", .{ totals[0], totals[1] });
        return error.TestUnexpectedResult;
    }
}

test "the checker v2's read-off of a call's reads costs a wrapper of a wide record what a narrow one costs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.7, §2.10's read-off (#1325): `w1 g = w0 g.x`,
    // where `w0` reads every field of a record. A read-only use at the
    // argument's own place is taken over whole, its children shared, so a
    // record of 160 fields costs the wrapper at most twice one of 10.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var totals: [2]u64 = undefined;
    for ([_]u32{ 10, 160 }, 0..) |n, run| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "type alias W =\n");
        for (1..n + 1) |i| try src.print(a, "    f{d:0>3} : List Int\n", .{i});
        try src.appendSlice(a, "\n\nw0 : W → Int\nw0 r =\n    0");
        for (1..n + 1) |i| try src.print(a, " + List.length r.f{d:0>3}", .{i});
        try src.appendSlice(a, "\n\n\nw1 : { x : W } → Int\nw1 g = w0 g.x\n");
        totals[run] = try ownTotalFor(&w, src.items, "w1");
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (totals[1] > totals[0] * 2) {
        std.debug.print("10 fields: {d} records, 160: {d}\n", .{ totals[0], totals[1] });
        return error.TestUnexpectedResult;
    }
}

/// A v2 dump of `src` as `Main.beni` with no declaration past a limit;
/// growth allowed.
fn ownDumpNoLimit(w: *World, src: []const u8) ![]const u8 {
    try w.write("Main.beni", src);
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    if (std.mem.indexOf(u8, dump.stdout, "\n  limit ")) |at| {
        const end = std.mem.indexOfScalarPos(u8, dump.stdout, at + 1, '\n') orelse dump.stdout.len;
        std.debug.print("{s}\n", .{dump.stdout[at + 1 .. end]});
        return error.TestUnexpectedResult;
    }
    return dump.stdout;
}

test "the checker v2's write beside many read paths of its parameter costs its caller what one read costs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.11 item 3, §4.1 *call view and direct obligation*
    // (#1325's review): `top` writes `π1.l` and, through `rall`, reads every
    // field of `π1.w.w`. At `caller`'s call each read path is beside the
    // write; they are one operand, walked by node in growth, so 256 fields
    // cost the caller what 64 do, and no lane passes its ceiling (it was
    // `ownership_accounting_invariant` at 64).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var totals: [2]u64 = undefined;
    for ([_]u32{ 64, 256 }, 0..) |n, run| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "type alias W =\n");
        for (1..n + 1) |i| try src.print(a, "    f{d:0>3} : List Int\n", .{i});
        try src.appendSlice(a, "\n\nrall : W → Int\nrall r =\n    0");
        for (1..n + 1) |i| try src.print(a, " + List.length r.f{d:0>3}", .{i});
        try src.appendSlice(a, "\n\n\ntop : { w : { w : W, z : Int }, l : List Int } → Int\ntop r = rall r.w.w + List.length (List.push r.l 1)\n\n\npub caller w =\n    l = [ 1 ]\n    top { w = w, l = l }\n");
        totals[run] = try accountTotal(try ownDumpNoLimit(&w, src.items), "caller");
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (totals[1] > totals[0] * 2) {
        std.debug.print("64 fields: {d} records, 256: {d}\n", .{ totals[0], totals[1] });
        return error.TestUnexpectedResult;
    }
}

test "the checker v2's write beside a doubling DAG of read paths costs its caller the DAG's nodes" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.11 item 3, §4.1 (#1325's review): `top` writes
    // `π1.l` beside `d_n`'s reads of `π1.d`, 2^n paths over n distinct
    // nodes. Depth 10 costs the caller at most twice depth 5, with no limit
    // (depth 5 was `ownership_accounting_invariant`).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var totals: [2]u64 = undefined;
    for ([_]u32{ 5, 10 }, 0..) |n, run| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "d1 ( a, b ) = List.length a + List.length b\n");
        for (2..n + 1) |i| try src.print(a, "\n\nd{d} ( a, b ) = d{d} a + d{d} b\n", .{ i, i - 1, i - 1 });
        try src.print(a, "\n\ntop r = d{d} r.d + List.length (List.push r.l 1)\n\n\npub caller d =\n    l = [ 1 ]\n    top {{ d = d, l = l }}\n", .{n});
        totals[run] = try accountTotal(try ownDumpNoLimit(&w, src.items), "caller");
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (totals[1] > totals[0] * 2) {
        std.debug.print("depth 5: {d} records, depth 10: {d}\n", .{ totals[0], totals[1] });
        return error.TestUnexpectedResult;
    }
}

test "the checker v2's write deep below a chain of field wrappers is linear in its depth" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §4.1 *call view and direct obligation* (#1325's
    // review): `f0 r = List.push r.b 1`, `f_i g = f_{i-1} g.x`. `f_i`'s call
    // writes `i` steps below its argument; that walk is value-sized, growth
    // chosen before it, never the call's lane (it was
    // `ownership_accounting_invariant` at `f74`). One module of 80: `f80`
    // costs at most 2.2 times `f40`, with no limit. 80, not 100: the module
    // of 100 takes 1.3 s (0.7 s of it checking, as on master; the rest the
    // dump's printing), past a black-box test's 1 s.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "f0 r = List.push r.b 1\n");
    for (1..81) |i| try src.print(a, "\n\nf{d} g = f{d} g.x\n", .{ i, i - 1 });
    const dump = try ownDumpNoLimit(&w, src.items);
    const deep = try accountTotal(dump, "f80");
    const half = try accountTotal(dump, "f40");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (deep * 10 > half * 22) {
        std.debug.print("f40: {d} records, f80: {d}\n", .{ half, deep });
        return error.TestUnexpectedResult;
    }
}

/// The crossing's counts from a dump: reads crossed, redone at `C`, and
/// `base_epoch`'s moves (`ownership-v2.md` §2.11 *κ across a call*).
fn crossingOf(dump: []const u8) ![3]u64 {
    const at = std.mem.indexOf(u8, dump, "crossing: reads ") orelse return error.NoCrossing;
    var it = std.mem.tokenizeAny(u8, dump[at + "crossing: reads ".len ..], " ,\n");
    const reads = try std.fmt.parseInt(u64, it.next().?, 10);
    _ = it.next(); // redone
    const redone = try std.fmt.parseInt(u64, it.next().?, 10);
    _ = it.next(); // base
    _ = it.next(); // moves
    const moves = try std.fmt.parseInt(u64, it.next().?, 10);
    return .{ reads, redone, moves };
}

/// A chain of `n` calls of one family of §2.11's counted tests, its last
/// value's element read (a push on it) or, for `push`, published.
fn shareProgram(a: std.mem.Allocator, family: []const u8, n: u32) ![]const u8 {
    var src: std.ArrayList(u8) = .empty;
    const read = "    case {s}{d} of\n        [ a, …_ ] →\n            List.length (List.push a 0)\n\n        _ →\n            0\n";
    if (std.mem.eql(u8, family, "step") or std.mem.eql(u8, family, "shared")) {
        const shared = family[1] == 'h';
        try src.appendSlice(a, "step : List (List Int), List Int → List (List Int)\nstep x v =\n    List.push x v\n\n\npub chain : ⊤ → Int\nchain ⊤ =\n");
        if (shared) try src.appendSlice(a, "    l = [ 1 ]\n");
        try src.appendSlice(a, "    x0 = [ [ 0 ] ]\n");
        for (1..n + 1) |k| if (shared) try src.print(a, "    x{d} = step x{d} l\n", .{ k, k - 1 }) else try src.print(a, "    x{d} = step x{d} [ {d} ]\n", .{ k, k - 1, k });
        try src.print(a, read, .{ "x", n });
    } else if (std.mem.eql(u8, family, "pick")) {
        try src.appendSlice(a, "pick : Bool, List (List Int), List (List Int) → List (List Int)\npick c a b =\n    if c then a else b\n\n\npub chain : Bool → Int\nchain c =\n    z = [ [ 0 ] ]\n    y0 = [ [ 0 ] ]\n");
        for (1..n + 1) |k| try src.print(a, "    y{d} = pick c y{d} (List.push z [ {d} ])\n", .{ k, k - 1, k });
        try src.print(a, read, .{ "y", n });
    } else if (std.mem.eql(u8, family, "push")) {
        try src.appendSlice(a, "pub chain : ⊤ → List Int\nchain ⊤ =\n    x0 = [ 0 ]\n");
        for (1..n + 1) |k| try src.print(a, "    x{d} = List.push x{d} {d}\n", .{ k, k - 1, k });
        try src.print(a, "    x{d}\n", .{n});
    } else {
        // `merge`: `x_k = merge x_{k-1} y_k`, `y_k` grown from `y_{k-1}` and
        // held below `x_{k-1}`; `indep`: `m_k = merge a_k b_k`, two chains.
        try src.appendSlice(a, "merge : List (List Int), List (List Int) → List (List Int)\nmerge a b =\n    a ++ b\n\n\npub chain : ⊤ → Int\nchain ⊤ =\n");
        if (family[0] == 'm') {
            try src.appendSlice(a, "    x0 = [ [ 0 ] ]\n    y0 = [ [ 0 ] ]\n");
            for (1..n + 1) |k| try src.print(a, "    y{d} = List.push y{d} [ {d} ]\n    x{d} = merge x{d} y{d}\n", .{ k, k - 1, k, k, k - 1, k });
            try src.print(a, read, .{ "x", n });
        } else {
            try src.appendSlice(a, "    a0 = [ [ 0 ] ]\n    b0 = [ [ 0 ] ]\n");
            for (1..n + 1) |k| try src.print(a, "    a{d} = List.push a{d} [ {d} ]\n    b{d} = List.push b{d} [ {d} ]\n    m{d} = merge a{d} b{d}\n", .{ k, k - 1, k, k, k - 1, k, k, k, k });
            try src.print(a, read, .{ "m", n });
        }
    }
    return src.toOwnedSlice(a);
}

/// §2.11's counted test for one family: the share of `chain`'s records that
/// is not Demands' resolve (#1214's), per call, at 10 and 40 calls, flat
/// (at most a quarter more, a log factor's room); and the crossing's redos
/// and `base_epoch` moves not per call.
fn callChainShare(family: []const u8) !void {
    return callChainShareIn(family, false);
}

/// `callChainShare` with the callee in another module, `Lib`, so each call
/// applies the class `Lib`'s block publishes (§8 S3b slice 3), read once.
fn callChainShareIn(family: []const u8, imported: bool) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    var per: [2]u64 = undefined;
    var counts: [2][3]u64 = undefined;
    for ([_]u32{ 10, 40 }, 0..) |n, run| {
        const program = try shareProgram(a, family, n);
        if (imported) {
            const at = std.mem.indexOf(u8, program, "pub chain").?;
            try w.write("Lib.beni", try std.mem.concat(a, u8, &.{ "pub ", program[0..at] }));
            try w.write("Main.beni", try std.mem.concat(a, u8, &.{ "import Lib\n\n\n", try std.mem.replaceOwned(u8, a, program[at..], " = step ", " = Lib.step ") }));
        } else try w.write("Main.beni", program);
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", if (imported) "." else "Main.beni" });
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        const main = dump.stdout[std.mem.indexOf(u8, dump.stdout, "module Main").?..];
        // Every call checked: the callee's class applied, never unbuilt.
        try testing.expect(std.mem.indexOf(u8, main, "unchecked") == null);
        try testing.expectEqual(@as(u64, 0), try accountField(main, "chain", "growth"));
        const total = try accountField(main, "chain", "total");
        per[run] = (total - try accountField(main, "chain", "demands")) / n;
        counts[run] = try crossingOf(main);
    }
    if (per[1] * 4 > per[0] * 5) {
        std.debug.print("{s}: {d} records a call at 10, {d} at 40\n", .{ family, per[0], per[1] });
        return error.TestUnexpectedResult;
    }
    try testing.expect(counts[1][1] <= counts[0][1] + 2);
    try testing.expect(counts[1][2] <= counts[0][2] + 2);
}

test "the checker v2's call share is flat per call: a step chain read at its element (CallChainShare)" {
    // `ownership-v2.md` §2.11 *κ across a call*, *Counted tests*: `x_k =
    // step x_{k-1} [ k ]`. Each call's read below its argument crosses into
    // the argument's own snapshot and meets the reads the earlier call made.
    try callChainShare("step");
}

test "the checker v2's call share is flat per call: an imported step chain (CallChainShare)" {
    // The same chain with `step` in `Lib` (§8 S3b slice 3): an imported
    // call is a same-module one, so the share stays flat; the block is read
    // once, at the first call.
    try callChainShareIn("step", true);
}

test "the checker v2's call share is flat per call: an imported shared actual (CallChainShare)" {
    try callChainShareIn("shared", true);
}

test "the checker v2's call share is flat per call: a push chain, published (CallChainShare)" {
    try callChainShare("push");
}

test "the checker v2's call share is flat per call: one shared actual at every call (CallChainShare)" {
    // `x_k = step x_{k-1} l`: `l`'s node is held below `x_{k-1}` with the same
    // entry in both snapshots, so the crossing holds.
    try callChainShare("shared");
}

test "the checker v2's call share is flat per call: a chain of joins (CallChainShare)" {
    // The 2a guard's chain of joins: its share is flat, and so is its whole
    // continuation since #1214 (the call-cost guard above).
    try callChainShare("pick");
}

test "the checker v2's call share is flat per call: merge with a shared actual that grows (CallChainShare)" {
    try callChainShare("merge");
}

test "the checker v2's call share is flat per call: merge over two independent chains (CallChainShare)" {
    // Both sides of the callee's `apart` grow: merged along their tries,
    // memoised per node pair, never the smaller side's size.
    try callChainShare("indep");
}

test "the checker v2's dump of push chains with an early read is the same at --jobs=1 and --jobs=8" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §3.8, §2.11 *Representation of a view*: eight
    // chains `x_k = List.push x_{k-1} k`, each with a later read of an
    // intermediate `x_5`, through a helper call so the chains' groups and
    // their calls' answers are walked in parallel at `--jobs=8`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "step : List Int, Int → List Int\nstep x k = List.push x k\n");
    for (1..9) |c| {
        try src.print(a, "\n\npub chain{d} : List Int → Int\nchain{d} x0 =\n", .{ c, c });
        for (1..41) |k| try src.print(a, "    x{d} = step x{d} {d}\n", .{ k, k - 1, k });
        try src.appendSlice(a, "    List.length x5 + List.length x40\n");
    }
    try w.write("Main.beni", src.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const one = try w.run(&.{ "dump", "--stage=ownership", "--ownership-both", "--jobs=1", "Main.beni" });
    const many = try w.run(&.{ "dump", "--stage=ownership", "--ownership-both", "--jobs=8", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), one.exit_code);
    try testing.expect(std.mem.indexOf(u8, one.stdout, "== ownership v2") != null);
    try testing.expectEqualStrings(one.stdout, many.stdout);
    try testing.expectEqualStrings(one.stderr, many.stderr);
}

test "the checker v2 charges an instruction's records to its source lanes" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §4.1: an instruction's transfer, a call's view, a
    // written demand's query and a holder's registration are kernels of
    // their source atoms, baseline, never growth. What growth remains per
    // statement of `x_k = List.push x_{k-1} k` is the graft of the
    // callee's class at each call, named growth until S3b's call view by
    // reference (#1097): it stays constant per statement, and twice the
    // statements is twice the growth. Since the κ trie (#1073) the graft
    // also relabels the class's snapshot and links the argument's at its
    // path, about 35 records a call where it was 19 (until #1097 removes
    // the graft's copy altogether).
    var growth: [2]u64 = undefined;
    for ([_]u32{ 100, 200 }, 0..) |n, run| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const a = testing.allocator;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "pub chain : ⊤ → Int\nchain ⊤ =\n    x0 = [ 0 ]\n");
        for (1..n + 1) |i| try src.print(a, "    x{d} = List.push x{d} {d}\n", .{ i, i - 1, i });
        try src.print(a, "    List.length x{d}\n", .{n});
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        growth[run] = try accountField(dump.stdout, "chain", "growth");
        const baseline = try accountField(dump.stdout, "chain", "baseline");
        // Since #1201 a demand's walk of its holder's value is growth too,
        // about 4 records a statement.
        try testing.expect(growth[run] <= 48 * n);
        // The graft's growth (#1097) is now about a third of the baseline.
        try testing.expect(baseline >= 2 * growth[run]);
    }
    try testing.expect(growth[1] <= 2 * growth[0] + 40);
}

test "the checker v2's summaries read each position of a value on its own (#1073): two corpus summaries pinned" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The κ trie keys a condition by its position, so a child's root
    // certificate is no longer read at the summary class under `[*]`, and a
    // level-1 split's entry no longer leaks into level 2 through the one
    // canonical `π1⟲` leaf. These summaries print stronger κ than before
    // (`{lost}` became `{excl π1[*]}`, and `fresh1{lost}` became `fresh1`),
    // as their non-recursive twins already did; no verdict moves.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const inherit: world.RunOptions = .{ .cwd = .inherit };

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const held = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v2", "tests/corpus/ownership/HeldElementWrites.beni" }, inherit);
    const rose = try w.runWith(&.{ "dump", "--stage=ownership", "--ownership=v2", "tests/corpus/ownership/RoseAlias.beni" }, inherit);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), held.exit_code);
    try testing.expect(std.mem.indexOf(u8, held.stdout, "  summary basic: π1 RAW, π1[*] RAW, π1[*][*] A; res .0 fresh1 π1[*], .0 fresh2, .0[*] π1[*][*]{excl π1[*][*]}, .1 fresh3, .1 π1, .1[*] fresh1 π1[*]{excl π1[*]}\n") != null);
    try testing.expectEqual(@as(u8, 0), rose.exit_code);
    try testing.expect(std.mem.indexOf(u8, rose.stdout, "  summary writeBelow: π1 R, π1#Rose.0 RA, π1⟲ RA, π1⟲#Rose.0 RAW; res .0 fresh2, .0 π1⟲#Rose.0, .0[*] π1⟲{excl π1⟲}, .0[*]#Rose.0 fresh1, .1 π1#Rose.0\n") != null);
}

test "the checker v2's growth is linear in a recursive tower's height: a one-member literal is its member's snapshot" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1112: `r_k = Rose [ r_{k-1} ]` walked the whole tower below each
    // literal, so its growth was quadratic and 100 levels hit the default
    // allowance. A one-member literal is a link to its member's snapshot
    // (§2.9), so each level costs a constant. The allowance is raised so
    // the tallest tower is measured, not refused; what remains per level
    // is read-off's and the holders', growth until #1098 lanes them.
    var growth: [3]u64 = undefined;
    for ([_]u32{ 10, 100, 1000 }, 0..) |n, run| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const a = testing.allocator;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "@ownership_summary_size(module, 262144)\n\n\ntype Rose =\n    Rose (List Rose)\n\n\npub tower : ⊤ → Rose\ntower ⊤ =\n    r0 = Rose []\n");
        for (1..n + 1) |i| try src.print(a, "    r{d} = Rose [ r{d} ]\n", .{ i, i - 1 });
        try src.print(a, "    r{d}\n", .{n});
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "unchecked tower") == null);
        growth[run] = try accountField(dump.stdout, "tower", "growth");
    }
    // A constant per level, up to the persistent sets' depth (n log n,
    // §4.1): ten times the levels, at most 14 times the growth. The old
    // walk was quadratic: 100 times.
    try testing.expect(growth[1] <= 14 * growth[0] + 200);
    try testing.expect(growth[2] <= 14 * growth[1] + 200);
}

const WideRun = enum { literal, spreads, fronts, appends };

/// A list of `n` items in one of four shapes, written into `src` as `g`.
fn wideRunSource(a: std.mem.Allocator, src: *std.ArrayList(u8), shape: WideRun, n: u32) !void {
    switch (shape) {
        .literal => try src.appendSlice(a, "pub g : ⊤ → List (List Int)\ng ⊤ =\n    [ "),
        .spreads, .fronts => try src.appendSlice(a, "pub g : List (List Int) → List (List Int)\ng xs =\n    [ "),
        .appends => try src.appendSlice(a, "pub g : List (List Int) → List (List Int)\ng xs =\n    xs"),
    }
    for (0..n) |i| switch (shape) {
        .literal => try src.print(a, "{s}[ {d} ]", .{ if (i == 0) "" else ", ", i }),
        .spreads => try src.print(a, "{s}…xs", .{if (i == 0) "" else ", "}),
        .fronts => try src.print(a, "[ {d} ], ", .{i}),
        .appends => try src.print(a, " ++ [ [ {d} ] ]", .{i}),
    };
    switch (shape) {
        .fronts => try src.appendSlice(a, "…xs ]\n"),
        .appends => try src.appendSlice(a, "\n"),
        else => try src.appendSlice(a, " ]\n"),
    }
}

/// The run's work in `g` at the default allowance: the growth and the
/// source continuation it spent (§4.1). The run is never refused.
fn wideRunWork(shape: WideRun, n: u32) !struct { growth: u64, continuation: u64 } {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try wideRunSource(testing.allocator, &src, shape, n);
    try w.write("Main.beni", src.items);
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "limit g") == null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "unchecked g") == null);
    return .{ .growth = try accountField(dump.stdout, "g", "growth"), .continuation = try accountField(dump.stdout, "g", "continuation") };
}

/// #1139, #1188: a wide run's items each take a constant share of a lane of
/// their own (§4.1): the positions node made before them. What is as large as
/// an item's value is reserved in a growth context before the work, and it
/// spends the declaration's source continuation, never the allowance: the
/// run's growth is 0, and its work is bounded per item. `per_item` is about
/// 1.5 times the work per item measured at 600.
fn expectWideRunPerItem(shape: WideRun, per_item: u64) !void {
    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const small = try wideRunWork(shape, 100);
    const wide = try wideRunWork(shape, 600);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u64, 0), small.growth);
    try testing.expectEqual(@as(u64, 0), wide.growth);
    try testing.expect(small.continuation <= per_item * 100);
    try testing.expect(wide.continuation <= per_item * 600);
}

test "the checker v2 checks 600 spreads of one list in no growth and work bounded per item" {
    // Measured: 11 records per item.
    try expectWideRunPerItem(.spreads, 20);
}

test "the checker v2 checks 600 items before a spread in no growth and work bounded per item" {
    // Measured: 46 records per item.
    try expectWideRunPerItem(.fronts, 80);
}

test "the checker v2 checks a literal of 600 lists in no growth and work bounded per item" {
    // #1188: a literal of 580 to 630 small lists was refused at the default
    // allowance. Measured: 115 records per item.
    try expectWideRunPerItem(.literal, 200);
}

test "the checker v2 checks an append chain of 600 lists in no growth and work bounded per item" {
    // Measured: 95 records per item.
    try expectWideRunPerItem(.appends, 160);
}

/// `g` at the default allowance, as `dump --ownership-totals` reports it:
/// no `limits` line means no declaration was refused.
fn expectNoLimit(src: []const u8) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", src);
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--ownership-totals", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "limits ") == null);
}

/// The check's `scratch_slots` and `g`'s account total, from a dump of
/// `src` with `--self-profile`.
fn scratchAndRecords(src: []const u8) !struct { slots: u64, records: u64 } {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", src);
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--self-profile=trace.json", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    const Event = struct { ph: []const u8, args: struct { scratch_slots: ?u64 = null } = .{} };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read("trace.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var slots: ?u64 = null;
    for (parsed.value.traceEvents) |e| if (e.args.scratch_slots) |n| {
        slots = n;
    };
    return .{ .slots = slots orelse return error.NoCounter, .records = try accountField(dump.stdout, "g", "total") };
}

test "the checker v2's scratch columns make slots in proportion to its records on a wide literal" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1191: a walk made a fresh `stamped.Column` per call, and a column
    // makes a slot per id up to the highest it is given: calls × the node
    // table, quadratic in the literal's width, while the records count only
    // the nodes visited. The walks take their columns from a pool and empty
    // them by generation, so the slots stay a small multiple of the records.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for ([_]u32{300}) |n| {
        src.clearRetainingCapacity();
        try wideRunSource(testing.allocator, &src, .literal, n);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const got = try scratchAndRecords(src.items);

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expect(got.slots <= 4 * got.records);
    }
}

test "the checker v2 checks a literal of 1 500 lists at the default allowance" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1188 (§4.1, *the source continuation*): a literal's length spends no
    // allowance. 1 500 is the widest inside the 1 s test budget: v2's time per
    // record grows with the width (#1191), and the dump runs v2 twice (#1193).
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try wideRunSource(testing.allocator, &src, .literal, 1500);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    try expectNoLimit(src.items);
}

test "the checker v2 checks an append chain of 1 000 lists at the default allowance" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1188 (§4.1): an append chain's length spends no allowance. The parser
    // admits a chain of at most about 2 000 terms (`nesting_too_deep`, the
    // widest `++` chain `abuse_wide_test` pins), and 1 000 is the widest inside
    // the 1 s test budget (#1191, #1193).
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try wideRunSource(testing.allocator, &src, .appends, 1000);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    try expectNoLimit(src.items);
}

/// `c` chosen from `arms` arms of `[ [ i ] ]` (and `[]`), for `g y k`.
fn writeArms(a: std.mem.Allocator, src: *std.ArrayList(u8), arms: u32) !void {
    try src.appendSlice(a, "    c =\n        case k of\n");
    for (0..arms) |i| try src.print(a, "            {d} →\n                [ [ {d} ] ]\n\n", .{ i, i });
    try src.appendSlice(a, "            _ →\n                []\n");
}

test "the checker v2 checks a 300-arm choice spread after an item at the default allowance" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1188: a wide choice costs O(1) records per arm (§4.1, the join memo),
    // so its width spends no allowance; at 300 arms it was refused.
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "pub g : List Int, Int → List (List Int)\ng y k =\n");
    try writeArms(a, &src, 300);
    try src.appendSlice(a, "    [ y, …c ]\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    try expectNoLimit(src.items);
}

test "the checker v2 checks a 30-arm choice spread or appended at 14 roots at the default allowance" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1187's review: the choice re-read at a fixed count of roots (14) is
    // O(1) per source atom (§4.1); it was refused after #1187 moved the roots'
    // work off their lanes. Measured: 222 164 of 269 312 continuation records.
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "pub g : List Int, Int → List (List (List Int))\ng y k =\n");
    try writeArms(a, &src, 30);
    const forms = [_][]const u8{ "[ y, …c ]", "[ …c, y ]", "c ++ [ y ]", "[ …c, …c ]" };
    for (0..14) |i| try src.print(a, "    a{d} = {s}\n", .{ i, forms[i % forms.len] });
    try src.appendSlice(a, "    [ a0");
    for (1..14) |i| try src.print(a, ", a{d}", .{i});
    try src.appendSlice(a, " ]\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY OUTPUT                 │
    // └─────────────────────────────────────────┘
    try expectNoLimit(src.items);
}

test "the checker v2 still refuses a genuine product past the source continuation" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // §4.1: a value whose type's positions are not the declaration's source,
    // re-read at a count that grows, is uses × positions: past K·I_f it is
    // growth, and past the allowance the loud `ownership_summary_size`.
    const a = testing.allocator;
    var w = try World.init(a, testing.io);
    defer w.deinit();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "type alias S =\n    { s0 : List Int");
    for (1..10) |i| try src.print(a, "\n    , s{d} : List Int", .{i});
    try src.appendSlice(a, "\n    }\n\n\ntype alias R =\n    { r0 : S");
    for (1..200) |i| try src.print(a, "\n    , r{d} : S", .{i});
    try src.appendSlice(a, "\n    }\n\n\npub g : List Int → List R\ng xs =\n    s = { s0 = xs");
    for (1..10) |i| try src.print(a, ", s{d} = xs", .{i});
    try src.appendSlice(a, " }\n    r = { r0 = s");
    for (1..200) |i| try src.print(a, ", r{d} = s", .{i});
    try src.appendSlice(a, " }\n    [ r");
    for (1..16) |_| try src.appendSlice(a, ", r");
    try src.appendSlice(a, " ]\n");
    try w.write("Main.beni", src.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "limit g: ownership_summary_size") != null);
}

/// `e` escapes of `xs` (`Js.ref xs`) and a chain of `w` pushes on it, in
/// one branch (`together`, the escaped twin) or in the two arms of an
/// `if` (the mutually exclusive one): the dump's account line of `f` and
/// its total line: the growth its source continuation paid (§4.1). The
/// allowance is raised, so the frame is measured.
fn escapesWrites(e: u32, w_count: u32, together: bool) !struct { growth: u64, total: []const u8 } {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "@ownership_summary_size(module, 4194304)\n\nimport Js\n\n\npub f flag xs =\n    if flag then\n");
    for (0..e) |_| try src.appendSlice(a, "        _ = Js.ref xs\n");
    if (!together) try src.appendSlice(a, "        xs\n    else\n");
    for (0..w_count) |i| {
        if (i == 0) try src.appendSlice(a, "        a0 = List.push xs 1\n") else try src.print(a, "        a{d} = List.push a{d} 1\n", .{ i, i - 1 });
    }
    try src.print(a, "        a{d}\n", .{w_count - 1});
    if (together) try src.appendSlice(a, "    else\n        xs\n");
    try w.write("Main.beni", src.items);
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--core", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "unchecked f") == null);
    const at = std.mem.indexOf(u8, dump.stdout, "\ntotal ") orelse return error.NoTotal;
    const end = std.mem.indexOfScalarPos(u8, dump.stdout, at + 1, '\n') orelse dump.stdout.len;
    return .{ .growth = try accountField(dump.stdout, "f", "continuation"), .total = try std.testing.allocator.dupe(u8, dump.stdout[at + 1 .. end]) };
}

test "the checker v2's escape queries are charged and indexed, never an uncharged escapes × writes product" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1226 (§4.1): every write asked every escape point of its cell
    // whether it came before, compatibly, with no charge: e × w tests at
    // growth 0. The points of a cell are indexed by the second order, so a
    // query is one binary search, charged as growth. The mixed difference over
    // independent escape and write counts of the growth the frame's
    // continuation paid is the product term; it stays
    // within w · (log₂ e + 1) (measured: 132 at 4 and 48), where the
    // product would be e × w (1 936).
    const counts = [_]u32{ 4, 48 };
    var ins: [2][2]u64 = undefined;
    for (counts, 0..) |e, i| for (counts, 0..) |w_count, j| {
        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const r = try escapesWrites(e, w_count, false);
        defer testing.allocator.free(r.total);
        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        // The arms exclude each other: every push is accepted.
        const want = try std.fmt.allocPrint(testing.allocator, "total {d}: accepted {d} ", .{ w_count, w_count });
        defer testing.allocator.free(want);
        try testing.expect(std.mem.startsWith(u8, r.total, want));
        ins[i][j] = r.growth;
    };
    const mixed = (ins[1][1] + ins[0][0]) -| (ins[1][0] + ins[0][1]);
    // Charged: each extra write's query costs more when it has more
    // escape points to search, so the term is never 0 (it was, uncharged).
    try testing.expect(mixed >= 48 - 4);
    try testing.expect(mixed <= 8 * 48);
    try testing.expect(mixed < 48 * 48 / 4);
}

/// `g`'s `n` bound lists `xᵢ = [ i ]` and the list of them, the dump's
/// `total` of `g`'s account line: every record the checker v2 charged.
fn boundListsTotal(n: u32) !u64 {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "pub g : ⊤ → List (List Int)\ng ⊤ =\n");
    for (0..n) |i| try src.print(a, "    x{d} = [ {d} ]\n", .{ i, i });
    try src.appendSlice(a, "    [ ");
    for (0..n) |i| try src.print(a, "{s}x{d}", .{ if (i == 0) "" else ", ", i });
    try src.appendSlice(a, " ]\n");
    try w.write("Main.beni", src.items);
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "unchecked g") == null);
    return accountField(dump.stdout, "g", "total");
}

test "the checker v2 walks a list of bound lists in time linear in their count" {
    // #1273 (§4.1): the list's element is a recast of each bound list, all
    // at one place. The join walked one entry per inner, each projecting
    // every member through every member's own inners: n² projections, 3.6×
    // the work at twice the lists. One run per place, each inner's node kept.
    const t100 = try boundListsTotal(100);
    const t200 = try boundListsTotal(200);
    // Linear, with headroom: at most 2.3× (measured 2.1× once fixed).
    try testing.expect(t200 * 10 <= t100 * 23);
}

test "the checker v2 stores a joined position's κ under each inner's own node" {
    // #1273 (§4.1): one run per place below a recast's inners, but the κ
    // each inner's child carries stays under that child's node, the id a
    // read through `Shape.proj` looks up; under one joined node the block
    // lost two `shared` entries (1 756 → 1 624 bytes). Pinned byte for byte.
    // One `[*][*]` entry reads `lost`, not `excl π1[*]`: a stepped recast
    // that keeps its whole inner reads the inner's reach approximately
    // (#1261), because the shallow read before it was unsound (#1132's
    // fixtures `WideResult` and `core/FullCast`). A cast-aware rule that
    // keeps the inner's own cells exact outside a region fold is #1291.
    // That recast is marked whole and interned apart from the plain recast
    // of the same inner, so its cells are always the reach (`~fresh3` too)
    // and the block writes the mark (1 756 → 1 776 bytes, #1310, #1311). The
    // directory names `w2` and whether an importer may apply its class
    // (1 776 → 1 796 bytes, #1316).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\pub w2 : List (List Int) → List (List (List Int))
        \\w2 xss =
        \\    a = [ [ 1 ] ]
        \\    x0 = [ …a, …xss ]
        \\    x1 = [ …xss, …a ]
        \\    x2 = [ …a, …a ]
        \\    [ x0, x1, x2 ]
        \\
    );
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  block: 1796 bytes, hash 037eaff68cf4041f\n") != null);
}

test "the checker v2 refuses every write after the escapes in the same branch" {
    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // The escaped twin of the test above: the escapes come first, in the
    // same branch, so every push is refused `escaped` (#1226).
    const twin = try escapesWrites(48, 8, true);
    defer testing.allocator.free(twin.total);
    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expect(std.mem.startsWith(u8, twin.total, "total 8: accepted 0 "));
    try testing.expect(std.mem.indexOf(u8, twin.total, "rejected 8") != null);
}

test "the checker v2's growth in a tower of joins of one value at two depths is at most quadratic" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1119: `r_k = if c then Rose [ r_{k-1} ] else r_{k-1}` re-walked the
    // whole tower at every level (cubic: 18 364 / 114 123 at N = 10 / 20).
    // The join memo (§2.9) walks each state once across calls, so the
    // states are linear, and the merge memo merges each pair of positions
    // once. What remains quadratic is the reads over a position's cells
    // and a union's sides, which grow with the level (#1121); this bound
    // then tightens to linear.
    var growth: [3]u64 = undefined;
    for ([_]u32{ 10, 20, 40 }, 0..) |n, run| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const a = testing.allocator;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "@ownership_summary_size(module, 262144)\n\n\ntype Rose =\n    Rose (List Rose)\n\n\npub tower : Bool → Rose\ntower c =\n    r0 = Rose []\n");
        for (1..n + 1) |i| try src.print(a, "    r{d} = if c then Rose [ r{d} ] else r{d}\n", .{ i, i - 1, i - 1 });
        try src.print(a, "    r{d}\n", .{n});
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "unchecked tower") == null);
        growth[run] = try accountField(dump.stdout, "tower", "growth");
    }
    // Twice the levels, at most 3.4 times the growth. The counts are
    // deterministic: with both memos 7 071 / 21 117 / 68 275 (2.99×, 3.23×);
    // without the join memo 3.59×, 3.76×; without the merge memo 3.30×,
    // 3.55× and 86 428 at N = 40; the re-walk of union DAGs was about 6×.
    try testing.expect(growth[1] * 5 <= 17 * growth[0]);
    try testing.expect(growth[2] * 5 <= 17 * growth[1]);
    try testing.expect(growth[2] <= 73_000);
}

test "the checker v2's block is linear in a tower of two-element literals, whose widen opens the collection" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1120: `r_k = Rose [ r_{k-1}, Rose [] ]`. Widen kept each level's
    // `[*]` (a positions node) beside the knot, so the published summary
    // grew as about n^2.4 (537 656 bytes at N = 30), every entry `lost`.
    // Opened on the cycle (§2.3), the block is linear and reads what the
    // unwidened value reads. A literal's root reads its elements' reach
    // aggregates, each extended from its parts' (#1121), so the growth is
    // n log n at most.
    var block: [3]u64 = undefined;
    var growth: [3]u64 = undefined;
    for ([_]u32{ 10, 100, 300 }, 0..) |n, run| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const a = testing.allocator;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "@ownership_summary_size(module, 4194304)\n\n\ntype Rose =\n    Rose (List Rose)\n\n\npub tower : ⊤ → Rose\ntower ⊤ =\n    r0 = Rose []\n");
        for (1..n + 1) |i| try src.print(a, "    r{d} = Rose [ r{d}, Rose [] ]\n", .{ i, i - 1 });
        try src.print(a, "    r{d}\n", .{n});
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "unchecked tower") == null);
        // No entry reads `lost`: each list is a fresh object of its own.
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "{lost}") == null);
        growth[run] = try accountField(dump.stdout, "tower", "growth");
        const at = std.mem.indexOf(u8, dump.stdout, "  block: ").? + "  block: ".len;
        const end = std.mem.indexOfScalarPos(u8, dump.stdout, at, ' ').?;
        block[run] = try std.fmt.parseInt(u64, dump.stdout[at..end], 10);
    }
    // 1 008 / 6 048 / 17 248 bytes: a constant per level.
    try testing.expect(block[1] <= 7 * block[0]);
    try testing.expect(block[2] <= 4 * block[1]);
    // 3 625 / 41 178 / 129 122: 101, 62 and 52 records per n·log₂(n + 2).
    // Before #1121 3 180 / 52 237 / 279 347, quadratic.
    try expectNLogN(&.{ 10, 100, 300 }, &growth);
}

/// Growth `g[i]` at `n[i]` levels is n log n at most: its records per
/// n·log₂(n + 2) never rise by more than a tenth from one size to the next
/// (#1121's counted towers; a quadratic rises tenfold over ten times the levels).
fn expectNLogN(n: []const u32, g: []const u64) !void {
    var last: f64 = std.math.inf(f64);
    for (n, g) |ni, gi| {
        const x: f64 = @floatFromInt(ni);
        const per = @as(f64, @floatFromInt(gi)) / (x * std.math.log2(x + 2));
        try testing.expect(per <= last * 1.1);
        last = per;
    }
}

test "the checker v2's read-off numbers an apart group's fresh cells the same in either declaration order" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1150's review: read-off images a group extended from its
    // predecessor's image, and imaging numbers sites `fresh k` on first
    // sight. The cells it images first are numbered in the group's own set
    // order, never in the order a module's earlier declaration first built
    // that group, so swapping two declarations prints the same summaries.
    const first =
        \\pub g : ⊤ → List (List Int)
        \\g ⊤ =
        \\    xs = [ [ 1 ], [ 2 ] ]
        \\    ys = [ [ 3 ], [ 4 ] ]
        \\    case ( xs, ys ) of
        \\        ( [ a, b ], [ c, d ] ) →
        \\            [ d, b, c, a ]
        \\
        \\        _ →
        \\            []
        \\
    ;
    const other =
        \\pub h : ⊤ → List (List Int)
        \\h ⊤ =
        \\    zs = [ [ 5 ], [ 6 ] ]
        \\    case zs of
        \\        [ p, q ] →
        \\            [ q, p ]
        \\
        \\        _ →
        \\            []
        \\
    ;
    var lines: [2][2][]const u8 = @splat(@splat(""));
    defer for (lines) |run| for (run) |l| testing.allocator.free(l);
    for (0..2) |run| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const src = try std.mem.concat(w.arena.allocator(), u8, if (run == 0) &.{ first, "\n\n", other } else &.{ other, "\n\n", first });
        try w.write("Main.beni", src);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        for ([_][]const u8{ "  summary g:", "  summary h:" }, 0..) |prefix, i| {
            const at = std.mem.indexOf(u8, dump.stdout, prefix) orelse return error.NoLine;
            const end = std.mem.indexOfScalarPos(u8, dump.stdout, at, '\n') orelse dump.stdout.len;
            lines[run][i] = try testing.allocator.dupe(u8, dump.stdout[at..end]);
        }
    }
    for (0..2) |i| try testing.expectEqualStrings(lines[0][i], lines[1][i]);
}

test "the checker v2's growth over a tower of one-element literals with a new parameter per level is n log n" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1121: `r_k = T a_k [ r_{k-1} ]`, a different parameter at each level.
    // The literal's one element compares everything its reach holds, and
    // rebuilt the arrivals' apart group from nothing at each level
    // (1 449 549 at N = 1 000 after the read-off's groups were shared,
    // 125 357 at N = 100 before). The group is now the element's reach
    // aggregate, one insertion more than its predecessor, and read-off maps
    // each group from its predecessor's image.
    var growth: [3]u64 = undefined;
    for ([_]u32{ 10, 100, 300 }, 0..) |n, run| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const a = testing.allocator;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "@ownership_summary_size(module, 4194304)\n\n\ntype T =\n    T (List Int) (List T)\n\n\npub tower : ");
        for (0..n) |_| try src.appendSlice(a, "List Int, ");
        try src.appendSlice(a, "⊤ → T\ntower ");
        for (1..n + 1) |i| try src.print(a, "a{d} ", .{i});
        try src.appendSlice(a, "⊤ =\n    r0 = T [] []\n");
        for (1..n + 1) |i| try src.print(a, "    r{d} = T a{d} [ r{d} ]\n", .{ i, i, i - 1 });
        try src.print(a, "    r{d}\n", .{n});
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "unchecked tower") == null);
        growth[run] = try accountField(dump.stdout, "tower", "growth");
    }
    // 2 976 / 38 482 / 126 600: 83, 58 and 51 records per n·log₂(n + 2).
    try expectNLogN(&.{ 10, 100, 300 }, &growth);
}

test "the checker v2 counts a branch's arms once at a fold, and coexisting occurrences twice" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1128 (§2.3's `choice`, §2.9's path-multiset primitive): a branch
    // join is a `choice`, whose arms one execution takes one of, so at a
    // fold the maximum over them counts; a node's parts and a positions
    // node's sides coexist and add. JoinFoldChoice reads `x` once; before
    // `choice`, its opened union counted `x` in both arms and read `lost`.
    // `Rose [ r, r ]` and an element beside a choice holding it repeat; K's
    // tower keeps every kids read `yes` at every height.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a,
        \\type Rose =
        \\    Rose (List Rose)
        \\
        \\
        \\pub joinFold : Bool → Rose
        \\joinFold c =
        \\    x = Rose []
        \\    k = if c then Rose [ x ] else Rose [ x ]
        \\    Rose [ Rose [ k ] ]
        \\
        \\
        \\pub twice : ⊤ → Rose
        \\twice ⊤ =
        \\    r0 = Rose []
        \\    r1 = Rose [ r0, r0 ]
        \\    r2 = Rose [ r1, r1 ]
        \\    r2
        \\
        \\
        \\pub besides : Bool, List Int, List Int → List (List Int)
        \\besides c x y =
        \\    [ if c then x else y, x ]
        \\
        \\
        \\pub kTower : Bool → Rose
        \\kTower c =
        \\    r0 = Rose []
        \\
    );
    for (1..21) |i| try src.print(a, "    r{d} = if c then Rose [ r{d} ] else r{d}\n", .{ i, i - 1, i - 1 });
    try src.appendSlice(a, "    r20\n");
    try w.write("Main.beni", src.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    const line = struct {
        fn of(out: []const u8, name: []const u8) ![]const u8 {
            var buf: [64]u8 = undefined;
            const head = try std.fmt.bufPrint(&buf, "  summary {s}:", .{name});
            const at = std.mem.indexOf(u8, out, head) orelse return error.NoSummary;
            return out[at..std.mem.indexOfScalarPos(u8, out, at, '\n').?];
        }
    }.of;
    const fails = struct {
        fn in(l: []const u8) bool {
            return std.mem.indexOf(u8, l, "{lost}") != null or std.mem.indexOf(u8, l, "{shared}") != null;
        }
    }.in;
    try testing.expect(!fails(try line(dump.stdout, "joinFold")));
    try testing.expect(fails(try line(dump.stdout, "twice")));
    try testing.expect(std.mem.indexOf(u8, try line(dump.stdout, "besides"), "{shared}") != null);
    try testing.expect(!fails(try line(dump.stdout, "kTower")));
}

test "a kids list at two depths of a widened tree reads as a repeat; distinct kids read yes" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1125's review: widen opens each level's `[*]` into one class, so `k`
    // at depth 1 and at depth 2 is two positions of the folded kids class.
    // No path of the unwidened value held `k` twice, so only the class's
    // multiset sees the repeat (§2.3): `#Rose.0` must not read `yes`, or a
    // traversal pushing into every kids list would push into `k` twice.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\type Rose =
        \\    Rose (List Rose)
        \\
        \\
        \\pub minimal : ⊤ → Rose
        \\minimal ⊤ =
        \\    k = [ Rose [] ]
        \\    b = Rose [ Rose k, Rose [] ]
        \\    Rose [ …[ b ], Rose k ]
        \\
        \\
        \\pub kidsPush : ⊤ → Rose
        \\kidsPush ⊤ =
        \\    k = [ Rose [] ]
        \\    a = Rose k
        \\    b = Rose [ a, Rose [] ]
        \\    c = Rose [ b, Rose [] ]
        \\    Rose (List.push [ c ] (Rose k))
        \\
        \\
        \\pub kidsSpread : ⊤ → Rose
        \\kidsSpread ⊤ =
        \\    k = [ Rose [] ]
        \\    a = Rose k
        \\    b = Rose [ a, Rose [] ]
        \\    c = Rose [ b, Rose [] ]
        \\    Rose [ …[ c ], Rose k ]
        \\
        \\
        \\pub onePush : ⊤ → Rose
        \\onePush ⊤ =
        \\    k = [ Rose [] ]
        \\    a = Rose k
        \\    b = Rose [ a ]
        \\    c = Rose [ b ]
        \\    Rose (List.push [ c ] (Rose k))
        \\
        \\
        \\pub plainPush : ⊤ → Rose
        \\plainPush ⊤ =
        \\    a = Rose [ Rose [] ]
        \\    b = Rose [ a, Rose [] ]
        \\    c = Rose [ b, Rose [] ]
        \\    Rose (List.push [ c ] (Rose [ Rose [] ]))
        \\
        \\
        \\type M =
        \\    M (List Int) (Maybe M)
        \\
        \\
        \\pub mTree : ⊤ → M
        \\mTree ⊤ =
        \\    k = [ 1 ]
        \\    M k (Just (M k Nothing))
        \\
        \\
        \\pub mPlain : ⊤ → M
        \\mPlain ⊤ =
        \\    M [ 1 ] (Just (M [ 2 ] Nothing))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    // No opened collection: `k` at two depths of a Maybe tree folds as well,
    // and every fold reads its repeats (#1125's verification).
    for ([_][]const u8{ "minimal", "kidsPush", "kidsSpread", "onePush", "plainPush", "mTree", "mPlain" }) |name| {
        var buf: [64]u8 = undefined;
        const field = if (name[0] == 'm' and name[1] != 'i') "#M.0" else "#Rose.0";
        const head = try std.fmt.bufPrint(&buf, "  summary {s}: res {s} ", .{ name, field });
        const at = std.mem.indexOf(u8, dump.stdout, head) orelse return error.TestUnexpectedResult;
        const line = dump.stdout[at..std.mem.indexOfScalarPos(u8, dump.stdout, at, '\n').?];
        const repeat = std.mem.indexOf(u8, line, "{lost}") != null or std.mem.indexOf(u8, line, "{shared}") != null;
        try testing.expectEqual(!std.mem.eql(u8, name, "plainPush") and !std.mem.eql(u8, name, "mPlain"), repeat);
    }
}

test "a one-element literal's [*] compares the objects its element holds at every path" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1115's review: the link of a one-element literal keeps the entry at
    // its `[*]` that compares everything the element holds below (`apart`
    // over its arrivals): `( a, b )`'s two parameters, and `( xs, x )` with
    // `x` one of `xs`'s elements, one object at two paths.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\pub p10 : List Int, List Int → List (List Int × List Int)
        \\p10 a b =
        \\    [ ( a, b ) ]
        \\
        \\
        \\pub p11 : List (List Int) → List (List (List Int) × List Int)
        \\p11 xs =
        \\    case xs of
        \\        [ x, …_ ] →
        \\            [ ( xs, x ) ]
        \\
        \\        _ →
        \\            []
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary p10: π1 RA, π2 RA; res [*] {apart [π1] [π2]}, [*].0 π1, [*].1 π2, fresh1\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary p11: π1 RA, π1[*] RA; res [*] {lost}, [*].0 π1, [*].1 π1[*]{excl π1[*]}, fresh1 fresh2\n") != null);
}

test "the checker v2's summary prints a cell at every path it is reached at, a shared value by reference" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1122 (§2.9, I-κ): sharing between explicit paths lives in their
    // cells, so a class keeps every route to a cell. The printer kept each
    // `(node, position)` once and left out `pair`'s `.1.0 π1` and `twice`'s
    // `.1`; a built node met again is printed as a reference to its first
    // route, so a DAG is never flattened.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\pub pair : List Int, List Int → List Int × (List Int × List Int)
        \\pair a b =
        \\    ( a, ( a, b ) )
        \\
        \\
        \\pub twice : List Int, List Int → (List Int × List Int) × (List Int × List Int)
        \\twice a b =
        \\    p = ( a, b )
        \\    ( p, p )
        \\
        \\
        \\pub choose : List Int, List Int, Bool → List Int × (List Int × List Int)
        \\choose a b c =
        \\    ( a, if c then ( a, b ) else ( a, a ) )
        \\
        \\
        \\pub both : List Int, List Int → (List Int × List Int) × List (List Int × List Int)
        \\both a b =
        \\    p = ( a, b )
        \\    ( p, [ p, p ] )
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary pair: π1 RA, π2 RA; res .0 π1, .1.0 π1, .1.1 π2\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary twice: π1 RA, π2 RA; res .0.0 π1, .0.1 π2, .1 = .0\n") != null);
    // A union's two sides holding one leaf print it once at a route,
    // however the leaf was first met (#1151's review); a built node below
    // `[*]` is no reference to one above it.
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary choose: π1 RA, π2 RA; res .0 π1, .1.0 π1, .1.1 π1, .1.1 π2\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary both: π1 RA, π2 RA; res .0.0 π1, .0.1 π2, .1 fresh1, .1[*] {shared}, .1[*].0 π1, .1[*].1 π2\n") != null);
}

test "the checker v2 gives each demand of one call its own query lane" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §4.1, *direct demand query*: ≤ 512 records per
    // written demand. `Ref.set` writes its cell and stores its value: two
    // demands at one call, two lanes, never one shared by the call point.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Ref exposing (Ref)
        \\
        \\
        \\pub put : Ref (List Int), List Int → ⊤
        \\put r xs =
        \\    Ref.set r xs
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, dump.stdout, ": accepted param\n"));
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "direct_demand_query lanes 2,") != null);
}

test "the checker v2's dump does not depend on where a declaration sits in its module" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §4.4 and the declaration-order guarantee: the dump
    // prints each declaration's cold account (checked alone, in fresh
    // tables, #1104), so swapping two declarations leaves every account and
    // summary line the same, records, lanes and categories included.
    const first =
        \\pub g : List (List Int) → List Int
        \\g xss =
        \\    case xss of
        \\        [ a, …_ ] →
        \\            if List.length a > 1 then List.push a 1 else a
        \\
        \\        _ →
        \\            []
        \\
    ;
    const other =
        \\pub h : List Int → List Int
        \\h xs =
        \\    List.push xs 2
        \\
    ;
    var lines: [2][4][]const u8 = @splat(@splat(""));
    defer for (lines) |run| for (run) |l| testing.allocator.free(l);
    for (0..2) |run| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const src = try std.mem.concat(w.arena.allocator(), u8, if (run == 0) &.{ first, "\n\n", other } else &.{ other, "\n\n", first });
        try w.write("Main.beni", src);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        for ([_][]const u8{ "  account g:", "  account h:", "  summary g:", "  summary h:" }, 0..) |prefix, i| {
            const at = std.mem.indexOf(u8, dump.stdout, prefix) orelse return error.NoLine;
            const end = std.mem.indexOfScalarPos(u8, dump.stdout, at, '\n') orelse dump.stdout.len;
            lines[run][i] = try testing.allocator.dupe(u8, dump.stdout[at..end]);
        }
        if (run == 1) for (0..4) |i| try testing.expectEqualStrings(lines[0][i], lines[1][i]);
    }
}

test "the checker v2 decides a base of 700 alternatives is several before reading its cells" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1225: a demand whose base has several cells is a product, growth;
    // the query read every cell on its own lane first, and a choice of 700
    // lists passed the lane's ceiling. It decides from the set before the
    // work now. Raised allowance: the product is measured, not refused.
    const a = testing.allocator;
    var w = try World.init(a, testing.io);
    defer w.deinit();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "@ownership_summary_size(module, 4194304)\n\n\npub g : Int → List Int\ng k =\n    c =\n        case k of\n");
    for (0..700) |i| try src.print(a, "            {d} →\n                [ {d} ]\n\n", .{ i, i });
    try src.appendSlice(a, "            _ →\n                []\n    List.push c 1\n");
    try w.write("Main.beni", src.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--ownership-totals", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "limits ") == null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "total 1: accepted 1") != null);
}

test "the checker v2 sweeps one holder of a value at many paths without passing a lane's ceiling" {
    // #1212's review (#1201): one holder holding the demanded cell at k
    // paths (a record whose k fields are one list) gave the demand's lane a
    // `laterUse` per path, and from k = 48 the lane passed its ceiling. The
    // lane keeps one path (§4.1's *direct demand query*); the rest is growth.
    // Its verdict is v1's: rejected, a holder read later. (Which path the
    // line names differs from v1's: #1222.)
    for ([_]u32{ 48, 1000 }) |k| {
        // ┌─────────────────────────────────────────┐
        // │ PREPARE                                 │
        // └─────────────────────────────────────────┘
        const a = testing.allocator;
        var w = try World.init(a, testing.io);
        defer w.deinit();
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "type alias Big =\n    { f0 : List (List Int)");
        for (1..k) |i| try src.print(a, "\n    , f{d} : List (List Int)", .{i});
        try src.appendSlice(a, "\n    }\n\n\npub g : List Int → Big × List (List Int)\ng ys =\n    v = [ [ 0 ] ]\n    big = { f0 = v");
        for (1..k) |i| try src.print(a, ", f{d} = v", .{i});
        try src.appendSlice(a, " }\n    x = [ …v, ys ]\n    ( big, x )\n");
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--ownership-totals", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "limits ") == null);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "total 1: accepted 0") != null);
    }
}

test "the checker v2 prints a summary of shared positions once per node, not once per route" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1182: `bᵢ = [ …bᵢ₋₁, …bᵢ₋₁ ]` is a DAG whose positions reach `b₀` along
    // 2ⁱ routes. The summary print expanded each route and gathered each
    // route's cells: 2¹⁰ copies of `π1[*]` at ten bindings, and 101.8 s and
    // 6.8 GB at 25. It expands a shared node once per prefix now, and a
    // position's cells are a set.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "pub g : List (List Int) → List (List Int)\ng xs =\n    b0 = [ …xs, [ 0 ] ]\n");
    for (1..11) |i| try src.print(a, "    b{d} = [ …b{d}, …b{d} ]\n", .{ i, i - 1, i - 1 });
    try src.appendSlice(a, "    b10\n");
    try w.write("Main.beni", src.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary g: π1 RAW, π1[*] A; res [*] fresh1 π1[*]{shared}, π1\n") != null);
}

test "the checker v2 says why a summary is not printed" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1182: the summary print reads the class on the declaration's account,
    // so it can pass the allowance the walk stayed under. The dump dropped
    // that error, and the `summary` line was simply missing. A 190-field
    // record of 10-field records re-read 16 times checks at growth 65 357 (re-sized for 2b's crossing records),
    // and its print passes 65 536: the dump says so.
    const a = testing.allocator;
    var w = try World.init(a, testing.io);
    defer w.deinit();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "type alias S =\n    { s0 : List Int");
    for (1..10) |i| try src.print(a, "\n    , s{d} : List Int", .{i});
    try src.appendSlice(a, "\n    }\n\n\ntype alias R =\n    { r0 : S");
    for (1..190) |i| try src.print(a, "\n    , r{d} : S", .{i});
    try src.appendSlice(a, "\n    }\n\n\npub h : List Int → List R\nh xs =\n    s = { s0 = xs");
    for (1..10) |i| try src.print(a, ", s{d} = xs", .{i});
    try src.appendSlice(a, " }\n    r = { r0 = s");
    for (1..190) |i| try src.print(a, ", r{d} = s", .{i});
    try src.appendSlice(a, " }\n    [ r");
    for (1..16) |_| try src.appendSlice(a, ", r");
    try src.appendSlice(a, " ]\n");
    try w.write("Main.beni", src.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "limit h") == null);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "  summary h: not printed: ownership_summary_size\n") != null);
}

/// A declaration a few hundredths below the default summary-size limit (`h`, its
/// cold growth about 62 200 of 65 536), after another (`g`) or before it:
/// its dump in that order (#1104). Its growth is a genuine product, a
/// 210-field record of records (re-sized for 2b's crossing records) re-read at 15 positions: source-shaped work
/// spends the source continuation, never the allowance (§4.1, #1188).
fn nearLimitDump(w: *World, h_first: bool) !world.Result {
    const a = testing.allocator;
    var h: std.ArrayList(u8) = .empty;
    defer h.deinit(a);
    try h.appendSlice(a, "type alias S =\n    { s0 : List Int");
    for (1..10) |i| try h.print(a, "\n    , s{d} : List Int", .{i});
    try h.appendSlice(a, "\n    }\n\n\ntype alias R =\n    { r0 : S");
    for (1..210) |i| try h.print(a, "\n    , r{d} : S", .{i});
    try h.appendSlice(a, "\n    }\n\n\npub h : List Int → List R\nh xs =\n    s = { s0 = xs");
    for (1..10) |i| try h.print(a, ", s{d} = xs", .{i});
    try h.appendSlice(a, " }\n    r = { r0 = s");
    for (1..210) |i| try h.print(a, ", r{d} = s", .{i});
    try h.appendSlice(a, " }\n    [ r");
    for (1..15) |_| try h.appendSlice(a, ", r");
    try h.appendSlice(a, " ]\n");
    const g = "pub g : List Int → List Int\ng ys =\n    List.push ys 0\n";
    const src = try std.mem.concat(w.arena.allocator(), u8, if (h_first) &.{ h.items, "\n\n", g } else &.{ g, "\n\n", h.items });
    try w.write("Main.beni", src);
    return w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });
}

fn expectNearLimitAccepted(h_first: bool) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try nearLimitDump(&w, h_first);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "limit h:") == null);
    const growth = try accountField(dump.stdout, "h", "growth");
    try testing.expect(growth > 60_000 and growth <= 65_536);
}

test "dump --stage=ownership --ownership=v2 walks each module once" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1193: the dump ran the checker v2 again after the session's check
    // had run it, doubling every ownership dump. It prints the check's own
    // reports now: one `ownership2_module` walk of `Main.beni`, with or
    // without the summaries.
    for ([_]bool{ false, true }) |totals| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try w.write("Main.beni", "pub g : List Int → List Int\ng xs =\n    List.push xs 1\n");

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = if (totals)
            try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--ownership-totals", "--self-profile=trace.json", "Main.beni" })
        else
            try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--self-profile=trace.json", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "total 1: accepted 1") != null);
        const Event = struct { name: []const u8, args: struct { file: ?[]const u8 = null } = .{} };
        const text = try w.read("trace.json");
        const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, text, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        var walks: u32 = 0;
        for (parsed.value.traceEvents) |e| {
            if (!std.mem.eql(u8, e.name, "ownership2_module")) continue;
            if (std.mem.endsWith(u8, e.args.file orelse "", "Main.beni")) walks += 1;
        }
        try testing.expectEqual(@as(u32, 1), walks);
    }
}

test "the checker v2 accepts a declaration near the summary-size limit after another" {
    try expectNearLimitAccepted(false);
}

test "the checker v2 accepts a declaration near the summary-size limit before another" {
    try expectNearLimitAccepted(true);
}

/// `ownership-v2.md` §4.1: a wide run supplies its own written atoms, and a
/// product is growth chosen before the work, so no kernel's width is an
/// `ownership_accounting_invariant`. `kind` 0 a record pattern, 1 a list
/// literal, 2 a call's literal argument, 3 a record update; width 1 000.
fn expectWideKernel(kind: u32) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    const a = testing.allocator;
    const n = 1000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    switch (kind) {
        0, 3 => {
            try src.appendSlice(a, "type alias R =\n");
            for (1..n + 1) |i| try src.print(a, "    f{d} : List Int\n", .{i});
            if (kind == 0) {
                try src.appendSlice(a, "\n\npub g : R → List Int\ng {");
                for (1..n + 1) |i| try src.print(a, "{s} f{d}", .{ if (i == 1) "" else ",", i });
                try src.appendSlice(a, " } =\n    List.push f1 1\n");
            } else {
                try src.appendSlice(a, "\n\npub g : R → R\ng r =\n    { r");
                for (1..n + 1) |i| try src.print(a, "{s} f{d} = List.push r.f{d} 1", .{ if (i == 1) " |" else ",", i, i });
                try src.appendSlice(a, " }\n");
            }
        },
        1 => {
            try src.appendSlice(a, "pub g : ⊤ → List (List Int)\ng ⊤ =\n    [ ");
            for (1..n + 1) |i| try src.print(a, "{s}[ {d} ]", .{ if (i == 1) "" else ", ", i });
            try src.appendSlice(a, " ]\n");
        },
        else => {
            try src.appendSlice(a, "pub g : List (List Int) → List (List Int)\ng xss =\n    List.push xss [ ");
            for (1..n + 1) |i| try src.print(a, "{s}{d}", .{ if (i == 1) "" else ", ", i });
            try src.appendSlice(a, " ]\n");
        },
    }
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", src.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "ownership_accounting_invariant") == null);
}

test "the checker v2 never reaches a lane's ceiling on a 1 000-field record pattern" {
    try expectWideKernel(0);
}

test "the checker v2 never reaches a lane's ceiling on a 1 000-item literal" {
    try expectWideKernel(1);
}

test "the checker v2 never reaches a lane's ceiling on a call with a 1 000-item argument" {
    try expectWideKernel(2);
}

test "the checker v2 never reaches a lane's ceiling on a 1 000-field record update" {
    try expectWideKernel(3);
}

test "the checker v2's growth over a tower of Js.from literals is n log n" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1140: `r_k = Js.from [ r_{k-1}, Js.from zs ]`, a structured literal
    // under a cast. A recast has no finite rank, so its literal's reach
    // aggregate was rebuilt from the whole reach at every level (1 983 /
    // 31 491 / 1 237 392 at N = 10 / 100 / 1 000); only a cycle reads a whole
    // reach now.
    var growth: [3]u64 = undefined;
    for ([_]u32{ 10, 100, 300 }, 0..) |n, run| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const a = testing.allocator;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "@ownership_summary_size(module, 4194304)\n\n\nimport Js\n\n\npub tower : List Int → Js.Value\ntower zs =\n    r0 = Js.from zs\n");
        for (1..n + 1) |i| try src.print(a, "    r{d} = Js.from [ r{d}, Js.from zs ]\n", .{ i, i - 1 });
        try src.print(a, "    r{d}\n", .{n});
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--core", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "unchecked tower") == null);
        growth[run] = try accountField(dump.stdout, "tower", "growth");
    }
    // 2 208 / 25 928 / 83 020: 62, 39 and 35 records per n·log₂(n + 2).
    try expectNLogN(&.{ 10, 100, 300 }, &growth);
}

test "the checker v2's growth over a tower of Js.array values is n log n, and a wide one stays in its lanes" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // #1132's review: `Js.array`'s literal sits at a type variable, so it is
    // an opaque value of what its items reach. Built by unions over each
    // level, it rebuilt the level below (about 29·n²); one item's work is its
    // own lane's, so a 1 000-item literal is no accounting defect.
    var growth: [3]u64 = undefined;
    for ([_]u32{ 10, 100, 1000 }, 0..) |n, run| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const a = testing.allocator;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "@ownership_summary_size(module, 262144)\n\n\nimport Js\n\n\npub tower : List Int → Js.Value\ntower zs =\n    a0 = Js.array [ Js.from zs ]\n");
        for (1..n + 1) |i| try src.print(a, "    a{d} = Js.array [ a{d}, Js.from zs ]\n", .{ i, i - 1 });
        try src.print(a, "    a{d}\n", .{n});
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--core", "Main.beni" });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "unchecked tower") == null);
        growth[run] = try accountField(dump.stdout, "tower", "growth");
    }
    // 832 / 9 788 / 121 708: ten times the levels, at most 14 times the
    // growth.
    try testing.expect(growth[1] <= 14 * growth[0]);
    try testing.expect(growth[2] <= 14 * growth[1]);

    // A literal of 1 000 items: each item's share on its own lane.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "import Js\n\n\npub wide : List Int → Js.Value\nwide zs =\n    Js.array [ Js.from zs");
    for (1..1000) |_| try src.appendSlice(a, ", Js.from zs");
    try src.appendSlice(a, " ]\n");
    try w.write("Main.beni", src.items);
    const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--core", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), dump.exit_code);
    try testing.expect(std.mem.indexOf(u8, dump.stdout, "unchecked wide") == null);
}

test "the checker v2 treats core read with --core-root as core, not as user code" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.13.13: a comparison written in beni composes its
    // components' classes in core. A copy of core under `--core-root` is
    // core as well: `f` is checked with either, never unchecked for one.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTreeInto("core", "mycore", "_");
    try w.write("Main.beni", "pub f : List Int → Bool × List Int\nf xs = ( xs == [ 1 ], List.push xs 2 )\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const embedded = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });
    const copied = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "--core-root=mycore", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), embedded.exit_code);
    try testing.expectEqual(@as(u8, 0), copied.exit_code);
    try testing.expect(std.mem.indexOf(u8, embedded.stdout, "unchecked f:") == null);
    try testing.expect(std.mem.indexOf(u8, copied.stdout, "unchecked f:") == null);
}

/// The sum of every `account f<k>:` line's `total` in a v2 dump.
fn sumFunctionTotals(dump: []const u8) !u64 {
    var sum: u64 = 0;
    var lines = std.mem.splitScalar(u8, dump, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " ");
        if (!std.mem.startsWith(u8, t, "account f")) continue;
        const key = ", total ";
        const at = std.mem.indexOf(u8, t, key) orelse return error.NoField;
        const digits = t[at + key.len ..];
        const end = std.mem.indexOfNone(u8, digits, "0123456789") orelse digits.len;
        sum += try std.fmt.parseInt(u64, digits[0..end], 10);
    }
    return sum;
}

test "the checker v2 reads 300 derived comparisons of one module in linear records" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `ownership-v2.md` §2.13.13: a derived `==` is read through the
    // user-written comparisons its type reaches. The module's `eq` is found
    // once and remembered (`cmp_decl`), not by scanning its declarations at
    // every use. The scan itself is a plain loop and no account charges it, so
    // records cannot catch its return; what they pin is that the work every
    // use is charged stays a constant per use: four times the uses, at most
    // four times the records.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = testing.allocator;
    var totals: [2]u64 = undefined;
    for ([2]usize{ 75, 300 }, 0..) |n, run| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        for (0..n) |i| try src.print(a, "type T{d}\n    = T{d} (List Int)\n\n\npub f{d} : List Int → Bool × List Int\nf{d} xs = ( T{d} xs == T{d} [], xs )\n\n\n", .{ i, i, i, i, i, i });
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const dump = try w.run(&.{ "dump", "--stage=ownership", "--ownership=v2", "Main.beni" });
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        try testing.expect(std.mem.indexOf(u8, dump.stdout, "unchecked f") == null);
        totals[run] = try sumFunctionTotals(dump.stdout);
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expect(totals[0] > 0);
    try testing.expect(totals[1] <= totals[0] * 4 + totals[0] / 4);
}
