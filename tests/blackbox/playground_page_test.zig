//! The playground page's own modules (docs/design/playground.md §4.2, §4.5,
//! §4.6), run under Node by `tests/wasm/page_test.mjs`: where a diagnostic of
//! the real compiler lands in the editor's text, the shareable link, the
//! grammar, the output frame's document and the samples' files. The page in
//! a browser is `zig build test-playground-page`'s.
//!
//! Nothing here imports a compiler internal: `std` and the harness.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

/// `node tests/wasm/page_test.mjs <args>` in the world's project; fails the
/// test, with the script's report, unless it exits 0.
fn expectPageTest(w: *World, args: []const []const u8) !void {
    return expectPageTestIn(w, .{ .dir = w.tmp.dir }, args);
}

/// `expectPageTest` with the working directory `cwd`: `.inherit` is the
/// repository root, where the test runs.
fn expectPageTestIn(w: *World, cwd: std.process.Child.Cwd, args: []const []const u8) !void {
    const arena = w.arena.allocator();
    const script = try std.Io.Dir.cwd().realPathFileAlloc(w.io, "tests/wasm/page_test.mjs", arena);
    const node = w.node_exe orelse return error.NodeNotOnPath;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ node, script });
    try argv.appendSlice(arena, args);
    const r = try world.spawnAndCapture(arena, w.gpa, w.io, argv.items, cwd, world.default_timeout_ms);
    if (r.exit_code != 0 or r.term != .exited) {
        std.debug.print("page_test.mjs {s} exited {d}\n--- stderr ---\n{s}\n", .{ args[0], r.exit_code, r.stderr });
        return error.PageTestFailed;
    }
}

test "the playground marks a diagnostic on the text it names, past Unicode notation and an astral character" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A column counts code points (language.md §12.7–§12.9) and the editor
    // counts UTF-16 units: `→` is one of each, `😀` one column and two
    // units. A mark one unit off would cover " missin".
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "-- 😀 → ⊤\nvalue : String\nvalue =\n    \"😀→\" ++ missing\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expectEqual(@as(usize, 1), checked.diagnostics.len);
    try w.write("diagnostics.json", checked.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectPageTest(&w, &.{ "positions", "Main.beni", "diagnostics.json", "missing" });
}

test "the playground's link gives back the source and the platform it was made from" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try expectPageTest(&w, &.{"share"});
}

test "the playground's output frame gets the CSS pane's text unchanged, and nothing when the pane is empty" {
    // An empty pane gives the frame's document of before the pane, byte for
    // byte (`playground.md` §4.6); a CSS with `</style>` and `</script>` in
    // it reaches the frame as JSON and ends no element early.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try expectPageTest(&w, &.{"srcdoc"});
}

test "each playground sample's CSS is next to its source, and TodoMVC's is todomvc-app-css with its notice" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `playground.md` §4.6: TodoMVC.css holds todomvc-app-css 2.4.3's
    // `index.css` unmodified between two markers (CC-BY-4.0 asks for a note
    // of the changes, which follow the markers), and the site ships the
    // credit and the licence in `samples/LICENSES.txt`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE AND VERIFY                      │
    // └─────────────────────────────────────────┘
    try expectPageTestIn(&w, .inherit, &.{"samples"});
}

test "every tab of the playground page controls a panel the page has" {
    // `page.js`'s `select()` shows the panel a tab's `aria-controls` names;
    // a renamed panel id would make it throw. The Chrome test clicks every
    // tab; this checks the ids in the gates.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try expectPageTestIn(&w, .inherit, &.{"tabs"});
}

test "the playground's grammar names comments, strings, keywords, notation and markup" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try expectPageTest(&w, &.{"syntax"});
}

test "the editor's vendored modules are the bytes their checksums name, and the page loads them from the site" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The CodeMirror modules are files of the site, not a CDN's
    // (`playground.md` §4.2): the page runs in an origin every Pages site of
    // its owner shares. `playground/vendor.sh` fetches them; this checks what
    // is checked in.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE AND VERIFY                      │
    // └─────────────────────────────────────────┘
    try expectPageTestIn(&w, .inherit, &.{"vendor"});
}
