//! The playground's shipped compiler writes what the native compiler writes
//! (docs/design/playground.md §6): `zig build test-playground`, not a gate.
//!
//! The `.wasm` that `zig build playground` ships (`ReleaseSmall`, LLVM) runs
//! under Node on the playground's own WASI host (`tests/wasm/beni.mjs`), on
//! every single-file program the page can be given:
//!
//!   - the page's own samples, `playground/samples/<platform>/*.beni`;
//!   - `tests/corpus/run/*.beni`: built for `node` as the page builds, with
//!     the cache and source maps, and with `--release` (the printing sample);
//!   - `tests/corpus/browser/direct/*.beni`: built for `browser-direct` the
//!     same three ways (the platform of the page, `playground.md` §1);
//!   - `tests/corpus/check/bad/*.beni`: checked, for the diagnostics, in
//!     both renderers (the page reads the JSON);
//!   - `bench/todomvc/apps/beni/*.beni`: built for `browser-direct` as the
//!     page builds and with `--release`, and the two dumps the page shows.
//!
//! Each command runs with the native threaded compiler too, on a copy of the
//! same project, and the two must agree on the exit code, both streams and
//! every output file (`wasm.zig`). A command both refuse is compared like
//! one both accept: the claim is the same bytes, not a clean build.
//!
//! The programs are split over `parts` tests by their index in sorted order,
//! and `build.zig` runs one process per test. No budget: the step is not a
//! gate, and one program costs about a billion instructions in Node.

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
    /// Built for `browser-direct`, in both modes.
    page,
    /// Checked.
    diagnostics,
    /// Built for `browser-direct` in both modes, and dumped.
    todomvc,
};

const directories = [_]struct { path: []const u8, kind: Kind }{
    .{ .path = "playground/samples/browser-direct", .kind = .page },
    .{ .path = "playground/samples/node", .kind = .print },
    .{ .path = "tests/corpus/run", .kind = .print },
    .{ .path = "tests/corpus/browser/direct", .kind = .page },
    .{ .path = "tests/corpus/check/bad", .kind = .diagnostics },
    .{ .path = "bench/todomvc/apps/beni", .kind = .todomvc },
};

const Program = struct { path: []const u8, kind: Kind };

/// Every `.beni` file directly in each directory, in sorted order within
/// each directory.
fn programs(arena: std.mem.Allocator) ![]const Program {
    var out: std.ArrayList(Program) = .empty;
    for (directories) |d| {
        var dir = try std.Io.Dir.cwd().openDir(testing.io, d.path, .{ .iterate = true });
        defer dir.close(testing.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        for (names.items) |name| try out.append(arena, .{ .path = try std.fs.path.join(arena, &.{ d.path, name }), .kind = d.kind });
    }
    return out.items;
}

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
        .page => &.{
            &.{ "build", "--platform=browser-direct", "--no-cache", "--no-source-maps", "--diagnostics=json" },
            &.{ "build", "--platform=browser-direct", "--out=out-maps" },
            &.{ "build", "--platform=browser-direct", "--release", "--allow-debug", "--out=out-release" },
        },
        .diagnostics => &.{
            &.{"check"},
            &.{ "check", "--diagnostics=json" },
        },
        .todomvc => &.{
            &.{ "build", "--platform=browser-direct", "--no-cache", "--no-source-maps", "--diagnostics=json" },
            &.{ "build", "--platform=browser-direct", "--release", "--out=out-release" },
            &.{ "dump", "--stage=types", "--platform=browser-direct", "--diagnostics=json" },
            &.{ "dump", "--stage=ownership", "--platform=browser-direct", "--diagnostics=json" },
        },
    };
    const out = try arena.alloc([]const []const u8, lists.len);
    for (lists, out) |flags, *args| args.* = try std.mem.concat(arena, []const u8, &.{ flags, &.{name} });
    return out;
}

/// Every program whose index is `part` modulo `parts`.
fn runPart(part: usize) !void {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const all = try programs(scratch.allocator());
    var compared: usize = 0;
    for (all, 0..) |program, i| {
        if (i % parts != part) continue;
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
    // Every part has programs: an empty one means the directories moved.
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
        "tests/corpus/browser/direct/KeySubscription.beni",
        "tests/corpus/browser/direct/LinkGuard.beni",
        "tests/corpus/browser/direct/LinkOutsideMount.beni",
        "tests/corpus/browser/direct/ListenerOrder.beni",
        "tests/corpus/browser/direct/NavigateErrors.beni",
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
        const built = try wasm.expectSameIgnoring(&w, &.{ "build", "--release", "--allow-debug", "--platform=browser-direct", "--no-cache", "--self-profile=profile.json", name }, other, &.{"profile.json"});

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
