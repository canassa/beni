//! The `browser/` corpus kind's harness (`browser.zig`), through the corpus
//! walker itself: the walker binary (`BENI_CORPUS_TEST_EXE`, installed by
//! `build.zig`) is run against a corpus of the scenario's own, a `browser/`
//! directory in the world's project, and what it did is read from its exit
//! code, its report of the failure, the `.run-hash` records and the counts
//! `BENI_RUN_HASH_REPORT` makes it write.
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
    \\    Page.sandbox { init = 0, update = update, view = view }
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
/// repository root, with `BENI_RUN_HASHES=<mode>` ("" to check), writing
/// its counts into `counts/`.
fn walker(w: *World, mode: []const u8) !world.Result {
    return walkerIn(w, mode, .inherit);
}

/// `walker` from `root` instead of the repository root: where the walker
/// finds the driver, the DOM and the `page` platform.
fn walkerIn(w: *World, mode: []const u8, root: std.process.Child.Cwd) !world.Result {
    const arena = w.arena.allocator();
    const project = try w.projectPath();
    var env = std.process.Environ.Map.init(arena);
    // The walker finds Node on `PATH`, as the build's own runs of it do.
    try env.put("PATH", try testing.environ.getAlloc(arena, "PATH"));
    try env.put("BENI_EXE", w.exe);
    try env.put("BENI_CORPUS_ROOT", try std.fmt.allocPrint(arena, "{s}/corpus", .{project}));
    try env.put("BENI_CORPUS_PART", "browser");
    try env.put("BENI_RUN_HASHES", mode);
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

fn expectCounts(w: *World, skipped: u32, stale: u32, recorded: u32, refused: u32) !void {
    const want = try std.fmt.allocPrint(w.arena.allocator(), "skipped {d}\nstale {d}\nrecorded {d}\nrefused {d}\n", .{ skipped, stale, recorded, refused });
    try testing.expectEqualStrings(want, try w.read("counts/browser.txt"));
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
    const r = try walker(&w, "");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(1, r);
    try expectReported(r, "Button.beni: output differs from ");
    try expectReported(r, "/corpus/browser/Button.expected; set BENI_WRITE_EXPECTED=1 to bless\n--- expected ---\n" ++ stale_golden ++ "\n--- actual ---\n" ++ loaded);
    try expectReported(r, "/corpus/browser/Button.beni: GoldenMismatch\n");
    // The development build's page ran for want of a record, failed, and
    // ended the case.
    try expectCounts(&w, 0, 1, 0, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(stale_golden, try w.read("corpus/browser/Button.expected"));
    try testing.expect(!w.exists("corpus/browser/Button.run-hash"));
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
    const r = try walker(&w, "");

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
    const r = try walker(&w, "");

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
    const r = try walker(&w, "");

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

/// Record `Button`'s run hashes, with `steps` as its script, and return the
/// record.
fn recordButton(w: *World, steps: []const u8) ![]const u8 {
    try w.write("corpus/browser/Button.beni", button);
    try w.write("corpus/browser/Button.steps", steps);
    try w.write("corpus/browser/Button.expected", loaded);
    try expectExit(0, try walker(w, "record"));
    try expectCounts(w, 0, 0, 2, 0);
    return w.read("corpus/browser/Button.run-hash");
}

test "a browser page whose run hash is recorded is not loaded again" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const record = try recordButton(&w, "# Nothing is clicked.\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w, "");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, r);
    // Both builds skipped, neither page loaded.
    try expectCounts(&w, 2, 0, 0, 0);
    // One line per build, naming the DOM the page ran in.
    var lines = std.mem.splitScalar(u8, record, '\n');
    for ([_][]const u8{ "dev", "release" }) |pass| {
        var fields = std.mem.splitScalar(u8, lines.next() orelse return error.RecordTooShort, ' ');
        try testing.expectEqualStrings(pass, fields.next().?);
        _ = fields.next() orelse return error.NoNodeVersion;
        try testing.expectEqualStrings("happy-dom-20.14.5", fields.next() orelse return error.NoDom);
        try testing.expectEqual(64, (fields.next() orelse return error.NoDigest).len);
        try testing.expectEqual(null, fields.next());
    }
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectEqual(null, lines.next());

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Checking never writes a record.
    try testing.expectEqualStrings(record, try w.read("corpus/browser/Button.run-hash"));
}

test "a page recorded in one checkout is not loaded again in a checkout at another path" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The same corpus, recorded from the repository root, then checked
    // from a second checkout: another directory holding the same driver,
    // fuzzer, DOM and `page` platform. The platform is copied, not linked,
    // so its absolute path is the second checkout's. Nothing the page runs
    // differs, so neither may its output tree nor its record.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const record = try recordButton(&w, "# Nothing is clicked.\n");
    var checkout = try World.init(testing.allocator, testing.io);
    defer checkout.deinit();
    const arena = w.arena.allocator();
    for ([_][]const u8{ browser.driver_path, browser.fuzz_path, browser.dom_path }) |path| {
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
    const r = try walkerIn(&w, "", .{ .dir = checkout.tmp.dir });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, r);
    // Both builds skipped: the second checkout built the same bytes.
    try expectCounts(&w, 2, 0, 0, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(record, try w.read("corpus/browser/Button.run-hash"));
}

test "a changed step script loads a recorded page again though its golden still matches" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const record = try recordButton(&w, "# Nothing is clicked.\n");
    // The same page, from another script: only the script changed.
    try w.write("corpus/browser/Button.steps", "# Still nothing is clicked.\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try walker(&w, "");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExit(0, r);
    try expectCounts(&w, 0, 2, 0, 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(record, try w.read("corpus/browser/Button.run-hash"));
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
        \\    Browser.program { init = 0, update = λn _ → n, view = view }
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
