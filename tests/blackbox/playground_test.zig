//! The playground's shipped compiler writes what the native compiler writes
//! (docs/design/playground.md §6): `zig build test-playground`, not a gate.
//!
//! The `.wasm` that `zig build playground` ships (`ReleaseSmall`, LLVM) runs
//! under Node on the playground's own WASI host (`tests/wasm/beni.mjs`), on
//! a hand-picked set of single-file programs (`programs`), each run the way
//! the page runs a program of its kind:
//!
//!   - a printing program: built for `node` as the page builds, with the
//!     cache and source maps, and with `--release`;
//!   - a page: built for `browser-tea` or `browser-inline` the same three
//!     ways;
//!   - a program with errors: checked, for the diagnostics, in both
//!     renderers (the page reads the JSON);
//!   - TodoMVC: built for `browser-tea` as the page builds and with
//!     `--release`, and the two dumps the page shows.
//!
//! Each command runs with the native threaded compiler too, on a copy of the
//! same project, and the two must agree on the exit code, both streams and
//! every output file (`wasm.zig`). A command both refuse is compared like
//! one both accept: the claim is the same bytes, not a clean build.
//!
//! The programs are split over `parts` tests by their index in the list,
//! and `build.zig` runs one process per test. The step is not a gate. A part
//! is a suite, so the hang guard (`tests/hang_guard.zig`) times each program
//! on its own, as the corpus times each case.

const std = @import("std");
const world = @import("world.zig");
const wasm = @import("wasm.zig");
const World = world.World;
const testing = std.testing;

/// How many tests the programs are split over: `build.zig`'s
/// `playground_shards`.
const parts = 8;

/// What the page does with a program of one directory.
const Kind = enum {
    /// Built for `node`, in both modes.
    print,
    /// Built for `browser-tea`, in both modes.
    page_tea,
    /// Built for `browser-inline`, in both modes.
    page_inline,
    /// Checked.
    diagnostics,
    /// Built for `browser-tea` in both modes, and dumped.
    todomvc,
};

/// The programs, hand-picked: each reaches something a wasm32 build by
/// LLVM at `ReleaseSmall` could write differently from the native one —
/// a word size, a number's text, a hash, an order, a deep stack, an
/// optimiser pass. The whole corpus took 14 minutes of CI for every pull
/// request (issue #1573); the gates' `wasm_test.zig` and the corpus hold
/// the rest.
const programs = [_]Program{
    // The page's own samples.
    .{ .path = "playground/samples/browser-tea/Counter.beni", .kind = .page_tea },
    .{ .path = "playground/samples/node/Print.beni", .kind = .print },
    // Numbers, hashes and 32-bit words.
    .{ .path = "tests/corpus/run/NumericEdge.beni", .kind = .print },
    .{ .path = "tests/corpus/run/CoreNumericExtremes.beni", .kind = .print },
    .{ .path = "tests/corpus/run/Int32Hash.beni", .kind = .print },
    // Text by code point, and order.
    .{ .path = "tests/corpus/run/CoreStringUnicode.beni", .kind = .print },
    .{ .path = "tests/corpus/run/Dictionaries.beni", .kind = .print },
    .{ .path = "tests/corpus/run/DerivedDeepPaths.beni", .kind = .print },
    // Deep trees and the release optimiser.
    .{ .path = "tests/corpus/run/ReleaseAliasChain1000.beni", .kind = .print },
    .{ .path = "tests/corpus/run/ReleaseEverything.beni", .kind = .print },
    .{ .path = "tests/corpus/run/SuspendDeepRecursion.beni", .kind = .print },
    // Schemas and markup.
    .{ .path = "tests/corpus/run/JsonDerivedArticle.beni", .kind = .print },
    .{ .path = "tests/corpus/run/SchemaShapeThreshold.beni", .kind = .print },
    .{ .path = "tests/corpus/run/MarkupFor.beni", .kind = .print },
    // Pages, on both browser platforms.
    .{ .path = "tests/corpus/browser/tea/TodoRouting.beni", .kind = .page_tea },
    .{ .path = "tests/corpus/browser/tea/HttpTrack.beni", .kind = .page_tea },
    .{ .path = "tests/corpus/browser/inline/FormLocal.beni", .kind = .page_inline },
    .{ .path = "tests/corpus/browser/inline/SelectedOperators.beni", .kind = .page_inline },
    // Diagnostics, one with a column past non-ASCII text.
    .{ .path = "tests/corpus/check/bad/WideRecordEqFunction.beni", .kind = .diagnostics },
    .{ .path = "tests/corpus/check/bad/LetHelperOverTheCapTwice.beni", .kind = .diagnostics },
    .{ .path = "tests/corpus/check/bad/CallStyleMethodNeedsArgument.beni", .kind = .diagnostics },
    // TodoMVC, with the two dumps the page shows.
    .{ .path = "bench/todomvc/apps/beni/Sandbox.beni", .kind = .todomvc },
};

const Program = struct { path: []const u8, kind: Kind };

/// The commands run on `name`, for a program of `kind`, in `arena`: the
/// argument lists hold `name`, so none may live on this frame. The first
/// build of each kind is the page's own command (`playground/worker.js`):
/// no cache, no source maps, the diagnostics as JSON, into `out/`. The
/// others reach what the page does not: the cache, source maps,
/// `--release`, and the human renderer.
fn commands(arena: std.mem.Allocator, kind: Kind, name: []const u8) ![]const []const []const u8 {
    const lists: []const []const []const u8 = switch (kind) {
        .print => &.{
            &.{ "build", "--platform=node", "--no-cache", "--no-source-maps", "--diagnostics=json" },
            &.{ "build", "--platform=node", "--out=out-maps" },
            &.{ "build", "--platform=node", "--release", "--allow-debug", "--out=out-release" },
        },
        .page_tea => &.{
            &.{ "build", "--platform=browser-tea", "--no-cache", "--no-source-maps", "--diagnostics=json" },
            &.{ "build", "--platform=browser-tea", "--out=out-maps" },
            &.{ "build", "--platform=browser-tea", "--release", "--allow-debug", "--out=out-release" },
        },
        .page_inline => &.{
            &.{ "build", "--platform=browser-inline", "--no-cache", "--no-source-maps", "--diagnostics=json" },
            &.{ "build", "--platform=browser-inline", "--out=out-maps" },
            &.{ "build", "--platform=browser-inline", "--release", "--allow-debug", "--out=out-release" },
        },
        .diagnostics => &.{
            &.{"check"},
            &.{ "check", "--diagnostics=json" },
        },
        .todomvc => &.{
            &.{ "build", "--platform=browser-tea", "--no-cache", "--no-source-maps", "--diagnostics=json" },
            &.{ "build", "--platform=browser-tea", "--release", "--out=out-release" },
            &.{ "dump", "--stage=types", "--platform=browser-tea", "--diagnostics=json" },
            &.{ "dump", "--stage=ownership", "--platform=browser-tea", "--diagnostics=json" },
        },
    };
    const out = try arena.alloc([]const []const u8, lists.len);
    for (lists, out) |flags, *args| args.* = try std.mem.concat(arena, []const u8, &.{ flags, &.{name} });
    return out;
}

/// Every program whose index is `part` modulo `parts`.
fn runPart(part: usize) !void {
    var compared: usize = 0;
    for (programs, 0..) |program, i| {
        if (i % parts != part) continue;
        var guard: @import("root").HangGuard = .{};
        try guard.start(program.path);
        defer guard.finish();
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const other: wasm.Other = .{ .wasm = wasm.wasmPath(w.arena.allocator()) orelse return error.NoWasmCompiler };
        try wasm.writeRepoFile(&w, program.path);
        errdefer std.debug.print("in {s}\n", .{program.path});
        for (try commands(w.arena.allocator(), program.kind, std.fs.path.basename(program.path))) |args| {
            _ = try wasm.expectSame(&w, args, other);
        }
        compared += 1;
    }
    // Every part has programs.
    try testing.expect(compared != 0);
}

test "part 0" {
    try runPart(0);
}
test "part 1" {
    try runPart(1);
}
test "part 2" {
    try runPart(2);
}
test "part 3" {
    try runPart(3);
}
test "part 4" {
    try runPart(4);
}
test "part 5" {
    try runPart(5);
}
test "part 6" {
    try runPart(6);
}
test "part 7" {
    try runPart(7);
}

test "the shipped compiler takes the points-to fixpoint in the native compiler's sweeps" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `--release`'s points-to fixpoint (`src/js/Spec.zig`) evaluates its
    // waiting constraints a word of a bit set at a time, and stops after
    // `max_pts_sweeps` sweeps. The word was a `usize`, so wasm32 took more
    // sweeps than x86-64 on these programs: the same bytes only because no
    // program came near the cap. The word is 64 bits on every target now,
    // and the sweep count is the native one (`fast-compiler.md` §10).
    const swept = [_][]const u8{
        "tests/corpus/browser/tea/KeySubscription.beni",
        "tests/corpus/browser/tea/LinkGuard.beni",
        "tests/corpus/browser/tea/LinkOutsideMount.beni",
        "tests/corpus/browser/tea/ListenerOrder.beni",
        "tests/corpus/browser/tea/NavigateErrors.beni",
        "bench/todomvc/apps/beni/Sandbox.beni",
    };
    for (swept) |path| {
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        const other: wasm.Other = .{ .wasm = wasm.wasmPath(w.arena.allocator()) orelse return error.NoWasmCompiler };
        try wasm.writeRepoFile(&w, path);
        const name = std.fs.path.basename(path);

        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const built = try wasm.expectSameIgnoring(&w, &.{ "build", "--release", "--allow-debug", "--platform=browser-tea", "--no-cache", "--self-profile=profile.json", name }, other, &.{"profile.json"});

        // ┌─────────────────────────────────────┐
        // │ VERIFY SIDE EFFECTS                 │
        // └─────────────────────────────────────┘
        errdefer std.debug.print("in {s}\n", .{path});
        try testing.expectEqual(@as(u8, 0), built.exit_code);
        const native = try wasm.profileCounter(&w, "threaded", "profile.json", "spec_points_to_sweeps");
        try testing.expect(native > 0);
        try testing.expectEqual(native, try wasm.profileCounter(&w, "other", "profile.json", "spec_points_to_sweeps"));
    }
}

test "the ball machine project is byte-identical on native and WebAssembly" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const other: wasm.Other = .{ .wasm = wasm.wasmPath(w.arena.allocator()) orelse return error.NoWasmCompiler };
    const path = "tests/corpus/browser/tea/BallMachine";
    var dir = try std.Io.Dir.cwd().openDir(testing.io, path, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        try wasm.writeRepoFile(&w, try std.fs.path.join(w.arena.allocator(), &.{ path, entry.name }));
    }
    for (try commands(w.arena.allocator(), .page_tea, ".")) |args| {
        const r = try wasm.expectSame(&w, args, other);
        try testing.expectEqual(@as(u8, 0), r.exit_code);
    }
    for ([_][]const u8{ "--stage=types", "--stage=ownership" }) |stage| {
        const r = try wasm.expectSame(&w, &.{ "dump", stage, "--platform=browser-tea", "--diagnostics=json", "." }, other);
        try testing.expectEqual(@as(u8, 0), r.exit_code);
    }
}
