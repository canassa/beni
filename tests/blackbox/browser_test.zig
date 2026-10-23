//! The `browser/` corpus kind's harness (`browser.zig`), through the corpus
//! walker itself: the walker binary (`BENI_CORPUS_TEST_EXE`, installed by
//! `build.zig`) is run against a corpus of the scenario's own, a `browser/`
//! directory in the world's project, and what it did is read from its exit
//! code, its report of the failure, the digests in its run-hash cache (the
//! world's `cache/`) and the counts `BENI_RUN_HASH_REPORT` makes it write.
//!
//! The walker runs in the repository root, as every run the build makes
//! does, so it finds the driver, the DOM and the `page` platform where the
//! corpus's own fixtures find them. `BENI_CORPUS_PART=browser` keeps it to
//! the one kind.
//!
//! A passing page is what `tests/corpus/browser/` shows; these are the ways
//! a page fails, each of which must fail the case and say why in terms of
//! the fixture, and the run hash's one input a `run/` build does not have.

const std = @import("std");
const testing = std.testing;
const world = @import("world.zig");
const World = world.World;
const browser = @import("browser.zig");
const Io = std.Io;

/// A button whose message `update` cannot handle: clicking it throws.
const button =
    \\import Page exposing (Node)
    \\
    \\
    \\type Msg
    \\    = Pressed
    \\
    \\
    \\update : Msg, Int → Int
    \\update msg count =
    \\    case msg of
    \\        Pressed →
    \\            Debug.todo "the button broke"
    \\
    \\
    \\view : Int → Node Msg
    \\view count =
    \\    Page.element "button" [ Page.attribute "id" "boom", Page.onClick Pressed ] [ Page.text (String.fromInt count) ]
    \\
    \\
    \\main : Page.Program
    \\main =
    \\    Page.sandbox { init = λ⊤ → 0, update = update, view = view }
    \\
;

/// What `button` shows once loaded.
const loaded =
    \\-- load
    \\<body>
    \\  <button id="boom">"0"</button>
    \\</body>
    \\
;

/// Run the corpus walker over `corpus/` in the world's project, from the
/// repository root, on the project's `cache/`, writing its counts into
/// `counts/`.
fn walker(w: *World) !world.Result {
    return walkerIn(w, .inherit);
}

/// `walker` from `root` instead of the repository root: where the walker
/// finds the driver, the DOM and the `page` platform.
fn walkerIn(w: *World, root: std.process.Child.Cwd) !world.Result {
    const arena = w.arena.allocator();
    const project = try w.projectPath();
    var env = std.process.Environ.Map.init(arena);
    // The walker finds Node on `PATH`, as the build's own runs of it do.
    try env.put("PATH", try testing.environ.getAlloc(arena, "PATH"));
    try env.put("BENI_EXE", w.exe);
    try env.put("BENI_CORPUS_ROOT", try std.fmt.allocPrint(arena, "{s}/corpus", .{project}));
    try env.put("BENI_CORPUS_PART", "browser");
    try env.put("BENI_RUN_HASH_DIR", try std.fmt.allocPrint(arena, "{s}/cache", .{project}));
    try env.put("BENI_RUN_HASH_REPORT", try std.fmt.allocPrint(arena, "{s}/counts", .{project}));
    const argv = try arena.dupe([]const u8, &.{try testing.environ.getAlloc(arena, "BENI_CORPUS_TEST_EXE")});
    return world.spawnAndCaptureIn(arena, w.io, argv, root, world.default_timeout_ms, &env);
}

fn expectExit(want: u8, r: world.Result) !void {
    if (r.exit_code != want) std.debug.print("--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ r.stdout, r.stderr });
    try testing.expectEqual(want, r.exit_code);
}

/// Assert that the walker's report holds `text`.
fn expectReported(r: world.Result, text: []const u8) !void {
    if (std.mem.indexOf(u8, r.stderr, text) == null) {
        std.debug.print("the walker's report lacks:\n{s}\n--- stderr ---\n{s}\n", .{ text, r.stderr });
        return error.NotReported;
    }
}

fn expectCounts(w: *World, skipped: u32, stale: u32) !void {
    const want = try std.fmt.allocPrint(w.arena.allocator(), "skipped {d}\nstale {d}\n", .{ skipped, stale });
    try testing.expectEqualStrings(want, try w.read("counts/browser.txt"));
}

/// The cache's entries, sorted: each an empty file named by a SHA-256 in
/// lower-case hex.
fn digests(w: *World) ![]const []const u8 {
    const files = try w.listFiles("cache");
    for (files) |name| {
        try testing.expectEqual(64, name.len);
        for (name) |ch| try testing.expect(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'));
        try testing.expectEqualStrings("", try w.read(try std.fmt.allocPrint(w.arena.allocator(), "cache/{s}", .{name})));
    }
    return files;
}

test "a page that no longer shows its golden fails the case with both transcripts" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/browser/Button.beni", button);
    const stale_golden =
        \\-- load
        \\<body>
        \\  <button id="boom">"1"</button>
        \\</body>
        \\
    ;
    try w.write("corpus/browser/Button.expected", stale_golden);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try expectReported(r, "Button.beni: output differs from ");
    try expectReported(r, "/corpus/browser/Button.expected; set BENI_WRITE_EXPECTED=1 to bless\n--- expected ---\n" ++ stale_golden ++ "\n--- actual ---\n" ++ loaded);
    try expectReported(r, "/corpus/browser/Button.beni: GoldenMismatch\n");
    // The development build's page ran for want of a verified digest,
    // failed, and ended the case.
    try expectCounts(&w, 0, 1);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(stale_golden, try w.read("corpus/browser/Button.expected"));
    // A failed page writes no digest.
    try testing.expectEqual(0, (try digests(&w)).len);
}

test "an exception the page throws fails the case with its message and the step that threw it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/browser/Button.beni", button);
    try w.write("corpus/browser/Button.steps", "click #boom\n");
    try w.write("corpus/browser/Button.expected", loaded);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    // The step, the exception and where it was thrown, then the page as it
    // was before the step.
    try expectReported(r,
        \\Button.beni [dev]: the page failed in happy-dom-20.14.5
        \\click #boom: the page threw an uncaught exception:
        \\Error: TODO: the button broke
        \\at Debug$todo (file:///
    );
    try expectReported(r, "/out/_core/Debug.mjs:");
    try expectReported(r, "--- the page until then ---\n" ++ loaded ++ "-- click #boom\n");
    try expectReported(r, "/corpus/browser/Button.beni: PageFailed\n");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(loaded, try w.read("corpus/browser/Button.expected"));
}

test "a step whose selector matches nothing fails the case with the step's line" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/browser/Button.beni", button);
    try w.write("corpus/browser/Button.steps", "# The button is #boom.\nclick #bang\n");
    try w.write("corpus/browser/Button.expected", loaded);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try expectReported(r,
        \\Button.beni [dev]: the page failed in happy-dom-20.14.5
        \\Button.steps:2: click #bang: no element matches `#bang`
        \\--- the page until then ---
        \\
    ++ loaded ++ "-- click #bang\n");
    try expectReported(r, "/corpus/browser/Button.beni: PageFailed\n");
}

// A `browser-tea` page whose one socket offers the protocol `v1`
// (`boundary.md` §9.11 (b)).
const offering =
    \\import Cmd exposing (Cmd)
    \\import Html exposing (Html)
    \\import Tea
    \\import WebSocket
    \\
    \\
    \\type Msg
    \\    = Socket WebSocket.Event
    \\
    \\
    \\update : Msg, Int → Int × Cmd Msg
    \\update _ n = ( n + 1, Cmd.none )
    \\
    \\
    \\view : Int → Html Msg
    \\view n = <p>{String.fromInt n}</p>
    \\
    \\
    \\main : Tea.Program
    \\main =
    \\    Tea.element
    \\        { init = λ⊤ → ( 0, Cmd.none )
    \\        , update = update
    \\        , view = view
    \\        , subscriptions = λ_ → WebSocket.listen "/chat" [ "v1" ] Socket
    \\        }
    \\
;

test "a socket opened with a protocol the page did not offer fails the case" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A host fails the handshake when the server picks a protocol the page
    // did not offer (RFC 6455 §4.1), so no golden may show that page.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/browser/tea/Offer.beni", offering);
    try w.write("corpus/browser/tea/Offer.steps", "socket 1 open \"v9\"\n");
    try w.write("corpus/browser/tea/Offer.expected", "");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try expectReported(r, "Offer.steps:1: socket 1 open \"v9\": socket 1 offered [\"v1\"], not \"v9\": a host fails that handshake\n");
    try expectReported(r, "/corpus/browser/tea/Offer.beni: PageFailed\n");
}

test "a socket opened with no protocol when the page offered some fails the case" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A host fails the handshake when the page offered protocols and the
    // server picked none (the Fetch standard's "establish a WebSocket
    // connection").
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/browser/tea/Offer.beni", offering);
    try w.write("corpus/browser/tea/Offer.steps", "socket 1 open\n");
    try w.write("corpus/browser/tea/Offer.expected", "");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try expectReported(r, "Offer.steps:1: socket 1 open: socket 1 offered [\"v1\"]: `open` names the one the server picked, since a host fails a handshake that picks none\n");
    try expectReported(r, "/corpus/browser/tea/Offer.beni: PageFailed\n");
}

test "a malformed step fails the case before the page loads" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("corpus/browser/Button.beni", button);
    // `input` takes a JSON string, and this one is bare.
    try w.write("corpus/browser/Button.steps", "input #boom Ada\n");
    try w.write("corpus/browser/Button.expected", loaded);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    // Nothing was shown: the script was refused before the load.
    try expectReported(r,
        \\Button.beni [dev]: the driver refused to run the page
        \\driver: Button.steps:1: `input` takes a selector and a JSON string
        \\usage: node driver.mjs
    );
    try expectReported(r, "/corpus/browser/Button.beni: PageFailed\n");
}

/// Verify `Button`'s two pages, with `steps` as its script, on an empty
/// cache, and return the two digests they left.
fn verifyButton(w: *World, steps: []const u8) ![]const []const u8 {
    try w.write("corpus/browser/Button.beni", button);
    try w.write("corpus/browser/Button.steps", steps);
    try w.write("corpus/browser/Button.expected", loaded);
    try expectExit(0, try walker(w));
    // Both pages ran for want of a verified digest.
    try expectCounts(w, 0, 2);
    const found = try digests(w);
    // One digest per build.
    try testing.expectEqual(2, found.len);
    return found;
}

test "a browser page whose run hash is verified is not loaded again" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const verified = try verifyButton(&w, "# Nothing is clicked.\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, r);
    // Both builds skipped, neither page loaded.
    try expectCounts(&w, 2, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A skipped page writes nothing.
    try testing.expectEqualDeep(verified, try digests(&w));
}

test "a page verified in one checkout is not loaded again in a checkout at another path" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The same corpus, verified from the repository root, then checked
    // from a second checkout: another directory holding the same driver,
    // fuzzer, DOM and `page` platform. The platform is copied, not linked,
    // so its absolute path is the second checkout's. Nothing the page runs
    // differs, so neither may its output tree nor its digest.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const verified = try verifyButton(&w, "# Nothing is clicked.\n");
    var checkout = try World.init(testing.allocator, testing.io);
    defer checkout.deinit();
    const arena = w.arena.allocator();
    for ([_][]const u8{ browser.driver_path, browser.fuzz_path, browser.dom_path, browser.parser_path }) |path| {
        try checkout.symlink(try Io.Dir.cwd().realPathFileAlloc(testing.io, path, arena), path);
    }
    var platform = try Io.Dir.cwd().openDir(testing.io, browser.platform_path, .{ .iterate = true });
    defer platform.close(testing.io);
    var files = platform.iterate();
    while (try files.next(testing.io)) |entry| {
        const from = try std.fs.path.join(arena, &.{ browser.platform_path, entry.name });
        try checkout.write(from, try Io.Dir.cwd().readFileAlloc(testing.io, from, arena, .limited(world.max_stream_bytes)));
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walkerIn(&w, .{ .dir = checkout.tmp.dir });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, r);
    // Both builds skipped: the second checkout built the same bytes.
    try expectCounts(&w, 2, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualDeep(verified, try digests(&w));
}

test "a changed step script loads a verified page again though its golden still matches" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const verified = try verifyButton(&w, "# Nothing is clicked.\n");
    // The same page, from another script: only the script changed.
    try w.write("corpus/browser/Button.steps", "# Still nothing is clicked.\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, r);
    try expectCounts(&w, 0, 2);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Two new digests beside the two the first script left.
    const now = try digests(&w);
    try testing.expectEqual(4, now.len);
    for (verified) |d| {
        var found = false;
        for (now) |n| found = found or std.mem.eql(u8, n, d);
        try testing.expect(found);
    }
}

test "a library build's page delivers the events its markup delegates, with no program start" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A `--library` build writes no entry file, so nothing calls the
    // runtime's `start` with the events to listen for: each kind registers
    // the names it delegates when it mounts (backend.md §15.3). The page's
    // own entry mounts the exported program, with the `run` the platform's
    // runtime module supplies (backend.md §15.1, *The runtime module*).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Browser
        \\import Html exposing (Html)
        \\
        \\
        \\view : Int → Html Int
        \\view count =
        \\    <button id="inc" onClick={count + 1}>{count}</button>
        \\
        \\
        \\main : Browser.Program
        \\main =
        \\    Browser.program { init = λ⊤ → 0, update = λn _ → n, view = view }
        \\
    );
    try w.write("page.steps", "click #inc\nclick #inc\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.run(&.{ "build", "--platform=browser", "--library", "--out=out", "Main.beni" });
    try expectExit(0, built);
    try w.write("out/page.mjs",
        \\import { Rt$run as run } from "./_platform/Rt.mjs";
        \\import { Main$main } from "./Main.mjs";
        \\
        \\run(Main$main);
        \\
    );
    const h = try browser.harness(testing.io);
    const shown = try browser.drive(&w, h, null, "out/page.mjs", "page.steps", world.default_timeout_ms);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, shown);
    try testing.expectEqualStrings(
        \\-- load
        \\<body>
        \\  <button id="inc">"0"</button>
        \\</body>
        \\-- click #inc
        \\<body>
        \\  <button id="inc">"1"</button>
        \\</body>
        \\-- click #inc
        \\<body>
        \\  <button id="inc">"2"</button>
        \\</body>
        \\
    , shown.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out/_main.mjs"));
}

/// Fills `cache/v1` with `argv[3]` entries, `argv[4]` seconds old, prunes it
/// as the driver does, and prints how many entries are left.
const prune_script =
    \\import { mkdirSync, readdirSync, utimesSync, writeFileSync } from "node:fs";
    \\import { pathToFileURL } from "node:url";
    \\const { pruneCompileCache } = await import(pathToFileURL(process.argv[2]).href);
    \\const count = Number(process.argv[3]);
    \\const when = new Date(Date.now() - Number(process.argv[4]) * 1000);
    \\mkdirSync("cache/v1", { recursive: true });
    \\for (let i = 0; i < count; i++) {
    \\  const path = `cache/v1/${i.toString(16).padStart(8, "0")}`;
    \\  writeFileSync(path, "");
    \\  utimesSync(path, when, when);
    \\}
    \\pruneCompileCache("cache");
    \\console.log(readdirSync("cache/v1").length);
    \\
;

/// How many of `count` entries `age` seconds old a prune leaves.
fn entriesLeft(w: *World, count: u32, age: u32) !u32 {
    const arena = w.arena.allocator();
    try w.write("prune.mjs", prune_script);
    const module = try Io.Dir.cwd().realPathFileAlloc(testing.io, "tests/browser/compile-cache.mjs", arena);
    const r = try w.runNode(&.{
        "prune.mjs",
        module,
        try std.fmt.allocPrint(arena, "{d}", .{count}),
        try std.fmt.allocPrint(arena, "{d}", .{age}),
    });
    try expectExit(0, r);
    return std.fmt.parseInt(u32, std.mem.trim(u8, r.stdout, "\n"), 10);
}

test "the driver's cache pruning is bounded however many entries a fuzz sweep left" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Just over the 1 024-entry cap plus the 128-entry examination budget:
    // an unbounded prune to the cap would remove at least 129 entries.
    // This reaches the same branch without creating thousands of files.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const count = 1024 + 128 + 1;
    const left = try entriesLeft(&w, count, 2 * 3600);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Some old entries went, but only the few a run looks at.
    try testing.expect(left < count);
    try testing.expect(left >= count - 128);
}

test "the driver's cache pruning leaves a cache of 1 024 entries or fewer alone" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try testing.expectEqual(@as(u32, 1024), try entriesLeft(&w, 1024, 2 * 3600));
}

test "the driver's cache pruning keeps the entries of the last hour" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try testing.expectEqual(@as(u32, 1025), try entriesLeft(&w, 1025, 60));
}

test "a partial primitive helper argument is bound only in its selected arm" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    // Expose the real primitive in this isolated core only. Public List.get
    // is an ordinary call and would not exercise the safety-predicate split.
    try w.copyTreeInto("core", "mycore", "_");
    const list = try w.read("mycore/List.beni");
    const private = "foreign pure at :";
    if (std.mem.count(u8, list, private) != 1) return error.CoreChanged;
    try w.write("mycore/List.beni", try std.mem.replaceOwned(u8, arena, list, private, "pub foreign pure at :"));
    try w.write("Main.beni",
        \\import Browser
        \\import Html exposing (Html)
        \\import Tea
        \\
        \\type alias Model = { values : List { n : Int }, shown : Bool, picked : Int }
        \\type Msg = Fill | Toggle | Pick Int
        \\
        \\update : Msg, Model → Model
        \\update msg model =
        \\    case msg of
        \\        Fill → { model | values = [ { n = 7 } ] }
        \\        Toggle → { model | shown = not model.shown }
        \\        Pick n → { model | picked = n }
        \\
        \\helper : Int → Html Msg
        \\helper n = <button id="pick" onClick={Pick n}>{n}</button>
        \\
        \\view : Model → Html Msg
        \\view model =
        \\    <main>
        \\        {if model.shown then
        \\            <section>{helper (List.at model.values 0).n}</section>
        \\         else
        \\            <></>
        \\        }
        \\        <p>{model.picked}</p>
        \\        <button id="fill" onClick={Fill}>Fill</button>
        \\        <button id="toggle" onClick={Toggle}>Toggle</button>
        \\    </main>
        \\
        \\main : Tea.Program
        \\main = Browser.mountAt (Tea.sandbox { init = λ⊤ → { values = [], shown = False, picked = 0 }, update = update, view = view }) "root"
        \\
    );
    try w.write("page.steps", "element \"root\"\nclick #fill\nclick #toggle\nclick #pick\n");
    const h = try browser.harness(testing.io);
    // The empty list would throw on its field read if evaluated while hidden.
    // A reveal must bind the newly filled list, and dispatch must use that 7.
    const built = try w.run(&.{ "build", "--core-root=mycore", "--platform=browser-inline", "--no-cache", "--out=out", "Main.beni" });
    try expectExit(0, built);
    const shown = try browser.drive(&w, h, null, "out/_main.mjs", "page.steps", world.default_timeout_ms);
    try expectExit(0, shown);
    try testing.expect(std.mem.indexOf(u8, shown.stdout, "<button id=\"pick\">\"7\"</button>") != null);
    try testing.expect(std.mem.indexOf(u8, shown.stdout, "<p>\"7\"</p>") != null);
}

test "a public library markup helper receives the markup-value diagnostic" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Html exposing (Html)
        \\import Tea
        \\
        \\
        \\pub helper : Int → Html msg
        \\helper n = <p>{n}</p>
        \\
        \\
        \\view : Int → Html Int
        \\view n = <div>{helper n}</div>
        \\
        \\
        \\main : Tea.Program
        \\main = Tea.sandbox { init = λ⊤ → 0, update = λn _ → n, view = view }
        \\
    );
    // Warm the same module cache as an application first. Public roots
    // must change the recorded consumed decision for the library build.
    const app = try w.run(&.{ "build", "--platform=browser-inline", "--out=appout", "Main.beni" });
    try expectExit(0, app);
    try testing.expectEqualStrings("", app.stdout);
    try testing.expectEqualStrings("", app.stderr);
    const r = try w.run(&.{ "build", "--library", "--platform=browser-inline", "--out=out", "Main.beni" });
    try expectExit(1, r);
    const diagnostic = @import("diagnostic");
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .not_implemented,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 6, .col = 12 }, .end = .{ .line = 6, .col = 13 } },
        .title = "NOT IMPLEMENTED YET",
        .message = "A limit of the compiler: `browser-inline` has no markup value yet; it compiles\nmarkup only as a program's `view`, written in place\n(`docs/design/browser-inline.md` §5, class 1). Write markup held, passed or\nreturned by a helper in place in the `view`, or build this program with\n`--platform=browser-tea`.",
    }}), r.diagnostics);
    try testing.expect(!w.exists("out"));
}
