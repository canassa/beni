//! A build with no threads writes what the threaded build writes
//! (docs/design/fast-compiler.md §10, *A build with no threads*;
//! docs/design/playground.md §6).
//!
//! Two compilers with no threads, each against the threaded ReleaseSafe
//! compiler, on two copies of one project (`wasm.zig`'s `expectSame`):
//!
//!   - the native one, `zig-out/single/bin/beni`: the same guarded code at
//!     native speed, so every place a guard is — the per-file pool,
//!     resolution, the check DAG, emit, the ownership pass, the dumps — and
//!     a tree as deep as the parser allows run here;
//!   - the WebAssembly one, `zig-out/wasm/bin/beni.wasm`, run by
//!     `tests/wasm/beni.mjs` on the playground's own WASI host. Its
//!     self-hosted build spends about 3 billion instructions on a small
//!     program, so it runs the two smallest scenarios, each a test of its
//!     own with a budget of its own (`wasm_budget_millions`); `zig build
//!     test-playground`, in CI on every pull request, runs the shipped
//!     `.wasm` on the corpus.
//!
//! The threaded compiler runs with `--jobs=8`, and so does the other: a
//! build with no threads takes it as 1 (§10), and the flag must change
//! nothing.
//!
//! Nothing here imports a compiler internal: `std` and the harness.

const std = @import("std");
const world = @import("world.zig");
const wasm = @import("wasm.zig");
const World = world.World;
const testing = std.testing;

/// The native compiler with no threads; every run of this file has one.
fn single(w: *World) ![]const u8 {
    return wasm.singleExePath(w.arena.allocator()) orelse error.NoSingleThreadedCompiler;
}

/// The WebAssembly compiler; every run of this file has one.
fn wasmCompiler(w: *World) ![]const u8 {
    return wasm.wasmPath(w.arena.allocator()) orelse error.NoWasmCompiler;
}

/// The budget of the two tests that run the `.wasm`, in millions of
/// instructions: a grant of their own (CLAUDE.md, *Every test has a
/// budget*), decided by Jayson Reis on 2026-10-15 (dashboard question
/// `wasm-playground-q5`) and granted by Cesar on 2026-10-15 (dashboard
/// question `wasm-playground-q7`). Most of their cost is fixed: Node, V8's compile of
/// the self-hosted build's 18 MB code section, and that build's slow start
/// on the embedded core and platforms. A one-line program costs 92% of
/// what `run/Adt` costs, so no smaller input reduces it, and under the
/// gates' 4 300M the margin was 17%. The limit is 1.63 times the largest
/// count (3 681M, the printing program with its profile, 2026-10-15), so an
/// unrelated growth of a fifth still fits. The grant covers the whole test
/// body: the `.wasm` run, and the native run and the comparison beside it.
/// It can go when the gates' `.wasm` is an LLVM build, about a third of the
/// count. `zig build test-playground`, in CI on every pull request, compares
/// the shipped `.wasm` on the whole corpus.
const wasm_budget_millions = 6_000;

/// Run `body` held to `wasm_budget_millions` instead of the gates' budget
/// (`world.withOwnBudget`).
fn withWasmBudget(comptime body: fn () anyerror!void) !void {
    try world.withOwnBudget("the .wasm tests", wasm_budget_millions, body);
}

/// A project of four clean modules in `app/`, over three directories, so the
/// per-file pool, resolution and the check DAG have work to split; and in
/// `bad/` a finding from each phase: a lexical error, a syntax error, a name
/// that is not in scope, a type error, and a path no module name can come
/// from.
const project = [_]wasm.File{
    .{ .path = "app/Main.beni", .bytes =
    \\import Node exposing (Program)
    \\import Shapes.Area
    \\import Shapes.Kind exposing (Kind, Circle, Square)
    \\import Text.Label
    \\
    \\
    \\main : Program
    \\main =
    \\    Node.printLines
    \\        [ String.fromFloat (Shapes.Area.area (Square 2.0))
    \\        , Text.Label.label (Circle 1.0)
    \\        ]
    \\
    },
    .{ .path = "app/Shapes/Kind.beni", .bytes =
    \\pub type Kind
    \\    = Circle Float
    \\    | Square Float
    \\
    },
    .{ .path = "app/Shapes/Area.beni", .bytes =
    \\import Shapes.Kind exposing (Kind, Circle, Square)
    \\
    \\
    \\pub area : Kind → Float
    \\area kind =
    \\    case kind of
    \\        Circle r →
    \\            3.0 * r * r
    \\
    \\        Square s →
    \\            s * s
    \\
    },
    .{ .path = "app/Text/Label.beni", .bytes =
    \\import Shapes.Kind exposing (Kind, Circle, Square)
    \\
    \\
    \\pub label : Kind → String
    \\label kind =
    \\    case kind of
    \\        Circle _ →
    \\            "circle"
    \\
    \\        Square _ →
    \\            "square"
    \\
    },
    .{ .path = "bad/Lexical.beni", .bytes = "value =\n\t1\n" },
    .{ .path = "bad/Syntax.beni", .bytes = "value =\n    [ 1\n" },
    .{ .path = "bad/Scope.beni", .bytes = "value =\n    missing\n" },
    .{ .path = "bad/Types.beni", .bytes = "value : Int\nvalue =\n    \"one\"\n" },
    .{ .path = "bad/not-a-module.beni", .bytes = "value =\n    1\n" },
};

test "a build with no threads checks, formats and dumps a project as the threaded build does" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const other: wasm.Other = .{ .native = try single(&w) };
    try wasm.writeProject(&w, &project);
    try wasm.writeRepoFile(&w, "tests/corpus/run/Adt.beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE AND VERIFY                      │
    // └─────────────────────────────────────────┘
    // Every finding, in both renderers: their merge and sort is what a
    // worker count could reorder.
    const checked = try wasm.expectSame(&w, &.{ "check", "--jobs=8", "--platform=node", "app", "bad" }, other);
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    _ = try wasm.expectSame(&w, &.{ "check", "--jobs=8", "--platform=node", "--diagnostics=json", "app", "bad" }, other);
    _ = try wasm.expectSame(&w, &.{ "fmt", "--check", "--jobs=8", "app", "bad" }, other);
    // The dumps `main.zig` runs on a thread of their own, and the ones the
    // playground shows (`--stage=types`, `--stage=ownership`).
    _ = try wasm.expectSame(&w, &.{ "dump", "--stage=ast", "--jobs=8", "Adt.beni" }, other);
    _ = try wasm.expectSame(&w, &.{ "dump", "--stage=bir", "--jobs=8", "Adt.beni" }, other);
    _ = try wasm.expectSame(&w, &.{ "dump", "--stage=types", "--jobs=8", "--platform=node", "Adt.beni" }, other);
    _ = try wasm.expectSame(&w, &.{ "dump", "--stage=dispatch", "--jobs=8", "--platform=node", "Adt.beni" }, other);
    for ([_][]const u8{ "interface", "graph", "ownership", "writes" }) |stage| {
        const flag = try std.fmt.allocPrint(w.arena.allocator(), "--stage={s}", .{stage});
        const dumped = try wasm.expectSame(&w, &.{ "dump", flag, "--jobs=8", "--platform=node", "app" }, other);
        try testing.expectEqual(@as(u8, 0), dumped.exit_code);
    }
}

/// Build each of `builds` with the threaded compiler and with the native one
/// with no threads, on `project`'s clean modules and three programs of the
/// repository: the same bytes, and a clean build.
fn expectBuilds(builds: []const []const []const u8) !void {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const other: wasm.Other = .{ .native = try single(&w) };
    try wasm.writeProject(&w, project[0..4]);
    try wasm.writeRepoFile(&w, "tests/corpus/run/Adt.beni");
    try wasm.writeRepoFile(&w, "tests/corpus/browser/inline/FormLocal.beni");
    try wasm.writeRepoFile(&w, "bench/todomvc/apps/beni/Sandbox.beni");
    for (builds) |args| {
        const built = try wasm.expectSame(&w, args, other);
        try testing.expectEqual(@as(u8, 0), built.exit_code);
    }
}

// A project, a printing program, a `browser-inline` page and TodoMVC, in
// both modes: emit's pool and the writes, and the ownership pass of an
// in-place platform and under `--ownership-everywhere`. Three tests, each
// under the budget.

test "a build with no threads builds a project and a printing program as the threaded build does" {
    try expectBuilds(&.{
        &.{ "build", "--jobs=8", "--platform=node", "--out=project", "app" },
        &.{ "build", "--jobs=8", "--platform=node", "--out=adt", "Adt.beni" },
        &.{ "build", "--jobs=8", "--platform=node", "--release", "--out=adt-release", "Adt.beni" },
    });
}

test "a build with no threads builds browser pages as the threaded build does" {
    try expectBuilds(&.{
        &.{ "build", "--jobs=8", "--platform=browser-inline", "--out=form", "FormLocal.beni" },
        &.{ "build", "--jobs=8", "--platform=browser-tea", "--ownership-everywhere", "--out=todo", "Sandbox.beni" },
    });
}

test "a build with no threads builds TodoMVC with --release as the threaded build does" {
    try expectBuilds(&.{
        &.{ "build", "--jobs=8", "--platform=browser-tea", "--ownership-everywhere", "--release", "--out=todo-release", "Sandbox.beni" },
    });
}

test "a build with no threads walks a tree as deep as the parser allows on its main stack" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The trees of `abuse_test.zig` that a threaded build walks on a thread
    // with `Check.stack_size`: a call nested 4 000 levels deep, which emit
    // lowers and prints by recursion, and a record literal nested 4 095
    // levels deep, which the checker solves and unifies by recursion. With
    // no threads they run on the main stack, which is that size plus 1 MiB
    // (`build.zig`'s `no_threads_stack_size`). Measured on the ReleaseSafe
    // compiler, the build needs 42 MiB of it and the check 35 MiB; with
    // Zig's default of 16 MiB the compiler with no threads crashes here,
    // started as a login shell starts it (`wasm.zig`'s `shell_stack`).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const other: wasm.Other = .{ .native = try single(&w) };
    const gpa = testing.allocator;
    var calls: std.ArrayList(u8) = .empty;
    defer calls.deinit(gpa);
    try calls.appendSlice(gpa, "import Node exposing (Program)\n\n\nf : Int → Int\nf x =\n    x + 1\n\n\nbig : Int\nbig =\n    ");
    for (0..4000) |_| try calls.appendSlice(gpa, "f (");
    try calls.appendSlice(gpa, "1");
    for (0..4000) |_| try calls.append(gpa, ')');
    try calls.appendSlice(gpa, "\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt big ]\n");
    var record: std.ArrayList(u8) = .empty;
    defer record.deinit(gpa);
    try record.appendSlice(gpa, "main =\n    ");
    for (0..4095) |_| try record.appendSlice(gpa, "{ x = ");
    try record.appendSlice(gpa, "1");
    for (0..4095) |_| try record.appendSlice(gpa, ", y = 0 }");
    try record.appendSlice(gpa, "\n");
    try wasm.writeProject(&w, &.{
        .{ .path = "Calls.beni", .bytes = calls.items },
        .{ .path = "Record.beni", .bytes = record.items },
    });

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE AND VERIFY                      │
    // └─────────────────────────────────────────┘
    const built = try wasm.expectSame(&w, &.{ "build", "--no-cache", "--platform=node", "Calls.beni" }, other);
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    const checked = try wasm.expectSame(&w, &.{ "check", "--no-cache", "Record.beni" }, other);
    try testing.expectEqual(@as(u8, 0), checked.exit_code);
}

test "the WebAssembly compiler builds a printing program as the native compiler does" {
    try withWasmBudget(buildsPrintingProgram);
}

fn buildsPrintingProgram() !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // wasm32 has a 32-bit `usize`, and its I/O goes through the
    // playground's WASI host (`playground/wasi.js`): the output tree, its
    // source maps and the streams must still be the native compiler's.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const other: wasm.Other = .{ .wasm = try wasmCompiler(&w) };
    try wasm.writeRepoFile(&w, "tests/corpus/run/Adt.beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE AND VERIFY                      │
    // └─────────────────────────────────────────┘
    const built = try wasm.expectSameIgnoring(&w, &.{ "build", "--jobs=8", "--platform=node", "--self-profile=profile.json", "Adt.beni" }, other, &.{"profile.json"});
    try testing.expectEqual(@as(u8, 0), built.exit_code);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The `.wasm` loads the checked core it embeds, as the native compiler
    // does (`playground.md` §2.1). A pack it refused would cost a check of
    // every core module it reaches and change no output byte, so only the
    // profile's counters can show it.
    const embedded = try wasm.profileCounter(&w, "other", "profile.json", "embedded_modules");
    try testing.expect(embedded > 0);
    try testing.expectEqual(try wasm.profileCounter(&w, "threaded", "profile.json", "embedded_modules"), embedded);
    // One module, `Adt`, on purpose: with a refused pack the `.wasm` would
    // check the core modules it reaches as well.
    try testing.expectEqual(@as(i64, 1), try wasm.profileCounter(&w, "other", "profile.json", "modules_checked"));
}

test "the WebAssembly compiler reports diagnostics as the native compiler does" {
    try withWasmBudget(reportsDiagnostics);
}

fn reportsDiagnostics() !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // What the playground shows when a program is wrong: a lexical, a
    // syntax, a scope and a type error, in the JSON the page positions in
    // its editor (`playground.md` §4.2).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const other: wasm.Other = .{ .wasm = try wasmCompiler(&w) };
    try wasm.writeProject(&w, project[4..]);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE AND VERIFY                      │
    // └─────────────────────────────────────────┘
    const checked = try wasm.expectSame(&w, &.{ "check", "--jobs=8", "--diagnostics=json", "bad" }, other);
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expect(std.mem.indexOf(u8, checked.stderr, "\"type_mismatch\"") != null);
}

test "a build with no threads refuses serve, which answers requests while it builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `serve` builds on one thread and answers HTTP on another; with no
    // threads it says so before it opens a port (fast-compiler.md §10).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const exe = try single(&w);
    try w.write("Main.beni", project[0].bytes);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "serve", "--platform=node", "--port=0", "Main.beni" }, .{ .raw_diagnostics = true, .exe = exe });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings("beni: serve needs threads, and this beni is built with none\n", r.stderr);
    try testing.expectEqualStrings("", r.stdout);
}
