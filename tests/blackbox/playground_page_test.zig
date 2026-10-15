//! The playground page's own modules (docs/design/playground.md §4.2, §4.5),
//! run under Node by `tests/wasm/page_test.mjs`: where a diagnostic of the
//! real compiler lands in the editor's text, the shareable link, and the
//! grammar. The page in a browser is `zig build test-playground-page`'s.
//!
//! Nothing here imports a compiler internal: `std` and the harness.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

/// `node tests/wasm/page_test.mjs <args>` in the world's project; fails the
/// test, with the script's report, unless it exits 0.
fn expectPageTest(w: *World, args: []const []const u8) !void {
    const arena = w.arena.allocator();
    const script = try std.Io.Dir.cwd().realPathFileAlloc(w.io, "tests/wasm/page_test.mjs", arena);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, script);
    try argv.appendSlice(arena, args);
    const r = try w.runNode(argv.items);
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

test "the playground's grammar names comments, strings, keywords, notation and markup" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try expectPageTest(&w, &.{"syntax"});
}
