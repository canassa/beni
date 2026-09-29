//! The differential oracle for the `dom` lowering (docs/design/backend.md
//! §15.10): dom-expressions' sixteen client fixtures, written in beni under
//! `tests/oracle/dom/<fixture>/`, are built for a vocabulary layered on
//! `browser` (`tests/platforms/oracle`), and the template strings and walks
//! the build emits are compared by `tests/oracle/extract.mjs` with the ones
//! dom-expressions' own compiler emitted, extracted once into
//! `expected.txt`. A difference is either listed in `differences.txt` with
//! its reason, or the case fails — and so does a listed difference that no
//! longer occurs.
//!
//! The gates read no submodule: `expected.txt` is checked in. The one test
//! that looks at `references/dom-expressions` asks whether its fixtures are
//! still the ones extracted, and passes when it is not checked out.

const std = @import("std");
const testing = std.testing;
const world = @import("world.zig");
const World = world.World;
const Io = std.Io;

const oracle_dir = "tests/oracle/dom";
const extractor = "tests/oracle/extract.mjs";
const platform_dir = "tests/platforms/oracle";
const fixtures_dir = "references/dom-expressions/packages/babel-plugin-jsx/test/__dom_fixtures__";

fn realPath(arena: std.mem.Allocator, rel: []const u8) ![]const u8 {
    return Io.Dir.cwd().realPathFileAlloc(testing.io, rel, arena);
}

fn node(w: *World, args: []const []const u8) !world.Result {
    const arena = w.arena.allocator();
    const exe = w.node_exe orelse return error.NodeNotOnPath;
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{exe}, args });
    return world.spawnAndCapture(arena, w.gpa, w.io, argv, .{ .dir = w.tmp.dir }, world.default_timeout_ms);
}

/// Build one fixture's modules and compare what the build emitted with
/// dom-expressions' output. A fixture none of whose roots beni can write has
/// no `Main.beni`, and is compared as no entries.
fn check(fixture: []const u8) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    const dir = try std.fs.path.join(arena, &.{ oracle_dir, fixture });
    try w.copyTree(dir, "_");
    var sources: std.ArrayList([]const u8) = .empty;
    var it = (try Io.Dir.cwd().openDir(testing.io, dir, .{ .iterate = true })).iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".beni")) try sources.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    var module: []const u8 = "-";
    if (sources.items.len != 0) {
        const platform = try std.fmt.allocPrint(arena, "--platform={s}", .{try realPath(arena, platform_dir)});
        const args = try std.mem.concat(arena, []const u8, &.{ &.{ "build", "--library", platform, "--out=out" }, sources.items });
        const built = try w.run(args);
        if (built.exit_code != 0) std.debug.print("{s}: the build failed\n{s}\n", .{ fixture, built.stderr });
        try testing.expectEqual(@as(u8, 0), built.exit_code);
        module = "out/Main.mjs";
    }
    const compared = try node(&w, &.{ try realPath(arena, extractor), "check", try realPath(arena, dir), module });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (compared.exit_code != 0) std.debug.print("{s}", .{compared.stderr});
    try testing.expectEqual(@as(u8, 0), compared.exit_code);
    try testing.expectEqualStrings("", compared.stderr);
}

test "adjacentSlots: beni's templates and walks against dom-expressions'" {
    try check("adjacentSlots");
}

test "attributeExpressions: beni's templates and walks against dom-expressions'" {
    try check("attributeExpressions");
}

test "components: beni's templates and walks against dom-expressions'" {
    try check("components");
}

test "conditionalExpressions: beni's templates and walks against dom-expressions'" {
    try check("conditionalExpressions");
}

test "customElements: beni's templates and walks against dom-expressions'" {
    try check("customElements");
}

test "eventExpressions: beni's templates and walks against dom-expressions'" {
    try check("eventExpressions");
}

test "fragments: beni's templates and walks against dom-expressions'" {
    try check("fragments");
}

test "insertChildren: beni's templates and walks against dom-expressions'" {
    try check("insertChildren");
}

test "jsxAttributeValues: beni's templates and walks against dom-expressions'" {
    try check("jsxAttributeValues");
}

test "keyedElements: beni's templates and walks against dom-expressions'" {
    try check("keyedElements");
}

test "multipleClassAttributes: beni's templates and walks against dom-expressions'" {
    try check("multipleClassAttributes");
}

test "namespaceElements: beni's templates and walks against dom-expressions'" {
    try check("namespaceElements");
}

test "simpleElements: beni's templates and walks against dom-expressions'" {
    try check("simpleElements");
}

test "SVG: beni's templates and walks against dom-expressions'" {
    try check("SVG");
}

test "SVGComponentPartial: beni's templates and walks against dom-expressions'" {
    try check("SVGComponentPartial");
}

test "textInterpolation: beni's templates and walks against dom-expressions'" {
    try check("textInterpolation");
}

test "the extracted expectations are dom-expressions' current fixtures, when they are checked out" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const arena = w.arena.allocator();
    // A path that need not exist: the submodule may not be checked out.
    const cwd = try realPath(arena, ".");
    const fixtures = try std.fs.path.join(arena, &.{ cwd, fixtures_dir });

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try node(&w, &.{ try realPath(arena, extractor), "stale", fixtures, try realPath(arena, oracle_dir) });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (r.exit_code != 0) std.debug.print("{s}", .{r.stderr});
    try testing.expectEqual(@as(u8, 0), r.exit_code);
}
