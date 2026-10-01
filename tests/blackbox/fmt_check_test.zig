//! `zig build beni-fmt-check`'s tool (`tests/fmt_check.zig`), driven on a
//! world of its own (`docs/design/frontend.md` §11.6): a file `beni fmt`
//! would change fails it, a file that does not parse fails it, and so does
//! every stale exemption — an entry naming a file that does not exist, one
//! naming a file that is already canonical, and a glob that matches
//! nothing. `BENI_FMT_CHECK_EXE` comes from `build.zig`.

const std = @import("std");
const testing = std.testing;
const world = @import("world.zig");
const World = world.World;

const canonical = "x = 1\n";
const not_canonical = "x =\n    1\n";
const broken = "x = (\n";

/// Run the tool in `w`'s project directory with the beni under test.
fn runCheck(w: *World) !world.Result {
    const arena = w.arena.allocator();
    const argv = [_][]const u8{
        try testing.environ.getAlloc(arena, "BENI_FMT_CHECK_EXE"),
        world.exePath(arena),
    };
    var env = std.process.Environ.Map.init(arena);
    return world.spawnAndCaptureIn(arena, testing.io, &argv, .{ .path = try w.projectPath() }, world.default_timeout_ms, &env);
}

test "canonical files and live exemptions pass" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("core/A.beni", canonical);
    try w.write("tests/corpus/run/B.beni", canonical);
    try w.write("tests/corpus/fmt/Ugly.beni", not_canonical);
    try w.write("tests/corpus/parse/good/Pinned.beni", not_canonical);
    try w.write("bench/Broken.beni", broken);
    // Outside the roots, and under a skipped tree: never looked at.
    try w.write("src/Elsewhere.beni", broken);
    try w.write("bench/compare/work/Generated.beni", broken);
    try w.write("tests/fmt-exempt.txt",
        \\-- a comment line
        \\tests/corpus/fmt/** -- formatter inputs
        \\tests/corpus/parse/good/Pinned.beni -- pins a layout
        \\bench/Broken.beni -- does not parse
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runCheck(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) std.debug.print("--- stderr ---\n{s}\n", .{r.stderr});
    try testing.expectEqual(0, r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
}

test "a file beni fmt would change, a file that does not parse, and every stale exemption fail it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("core/A.beni", canonical);
    try w.write("platforms/p/Ugly.beni", not_canonical);
    try w.write("tests/platforms/q/Broken.beni", broken);
    try w.write("tests/corpus/check/good/Canonical.beni", canonical);
    try w.write("tests/fmt-exempt.txt",
        \\tests/corpus/check/good/Canonical.beni -- no longer needed
        \\tests/corpus/check/good/Gone.beni -- deleted
        \\tests/corpus/nothing/** -- matches nothing
        \\core/A.beni
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runCheck(&w);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(1, r.exit_code);
    try testing.expectEqualStrings(
        \\tests/fmt-exempt.txt:4: an exemption needs ` -- ` and a reason
        \\tests/fmt-exempt.txt:2: `tests/corpus/check/good/Gone.beni` does not exist; delete the entry
        \\tests/fmt-exempt.txt:3: `tests/corpus/nothing/**` matches no file; delete the entry
        \\platforms/p/Ugly.beni: not what `beni fmt` writes; run `beni fmt platforms/p/Ugly.beni`, or exempt it in tests/fmt-exempt.txt with a reason
        \\tests/platforms/q/Broken.beni: does not parse; fix it, or exempt it in tests/fmt-exempt.txt with a reason
        \\tests/fmt-exempt.txt:1: `tests/corpus/check/good/Canonical.beni` is already canonical; delete the entry
        \\beni-fmt-check: 6 problems (language.md §12.5)
        \\
    , r.stderr);
}
