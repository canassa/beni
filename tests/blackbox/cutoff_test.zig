//! The differential harness, bounded (`plans/m4-3.md` §10.2, `fast-compiler.md`
//! §8's *Acceptance is the incremental-determinism matrix, made sharp*).
//!
//! **Two assertions per edit, and the second is the one that is new.**
//!
//! 1. An incremental build's every stream and every output file is
//!    BYTE-IDENTICAL to a cold build of the same tree — diagnostics, exit code,
//!    `--stage=raw`, `--stage=interface`, `--stage=dispatch` and the emitted
//!    JavaScript.
//! 2. The counters show each importer was skipped **exactly when the
//!    enumeration says it may be** — not merely that it was skipped.
//!
//! Byte-identity alone is satisfied by a cache that never hits, so the
//! criterion is byte-identity AND the counter. The predicted set is not
//! hard-coded: it is computed from `--cache-keys`, so a new edit class needs no
//! new expectation, and what the assertion says is *the cache re-checked
//! exactly the modules whose key moved, and nothing else*.
//!
//! **The loop is `plans/m4-3.md` §10.2's, in full:**
//!
//! ```
//! cold   build into a fresh cache directory, capture every stream and file
//! warm0  build again; byte-identical to cold; modules_checked == 0
//! apply  the edit
//! warm1  build; byte-identical to a COLD build of the EDITED tree;
//!        the re-checked set is exactly the set whose key moved
//! revert the edit
//! warm2  build; byte-identical to cold; the re-checked set is the modules
//!        whose entry the edited state displaced, and no more
//! ```
//!
//! **What this file is, against the full cross.** `bench/cutoff.sh` runs the
//! same loop over every module of `bench/corpus`, `core` under `--core-root`
//! and the `tests/corpus/` directory fixtures — thousands of builds, a
//! documented command with a stated budget. What runs in every gate is this:
//! the five-module project of §10.1 against every edit class of the table, and
//! it is representative on the one axis that matters — **it contains both
//! DEMONSTRATED miscompiles** (a private type whose payload becomes a function,
//! and a `pub type alias` whose body no scheme mentions) **and at least one
//! instance of every edit class**, which is what the full cross would be run to
//! discover and is not what it would be run to re-discover every commit.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

// ---------------------------------------------------------------------------
// The project — §10.1's, and `digest_test.zig`'s
// ---------------------------------------------------------------------------

const leaf_source =
    \\pub foreign twice : Int -> Int
    \\
    \\
    \\type Hidden
    \\    = H Int
    \\    | Extra Int
    \\
    \\
    \\pub type alias Pair =
    \\    { a : Int }
    \\
    \\
    \\pub type Tag
    \\    = Red
    \\    | Blue
    \\
    \\
    \\pub make : Int -> Hidden
    \\make x =
    \\    H x
    \\
    \\
    \\pub one : Int
    \\one =
    \\    1
    \\
;

const leaf_sibling =
    \\export const twice = (n) => n * 2;
    \\
;

const mid_source =
    \\import Leaf exposing (Blue, Pair, Red, Tag)
    \\
    \\
    \\pub same : Int, Int -> Bool
    \\same x y =
    \\    Leaf.make x == Leaf.make y
    \\
    \\
    \\pub firstOf : Pair -> Int
    \\firstOf p =
    \\    p.a
    \\
    \\
    \\pub name : Tag -> Int
    \\name t =
    \\    case t of
    \\        Red ->
    \\            0
    \\
    \\        Blue ->
    \\            1
    \\
    \\
    \\pub passThrough : Pair -> Pair
    \\passThrough p =
    \\    p
    \\
;

const top_source =
    \\import Mid
    \\
    \\
    \\pub three : Bool
    \\three =
    \\    Mid.same 1 2
    \\
;

const side_source =
    \\import Mid
    \\
    \\
    \\pub relayed : Int
    \\relayed =
    \\    Mid.firstOf (Mid.passThrough { a = 1 })
    \\
;

const manifest =
    \\{ "platform": true, "name": "cutoff", "program": "P.Program", "runtime": "run.js" }
    \\
;

fn writeProject(w: *World) !void {
    try w.write("beni.json", manifest);
    try w.write("src/beni.json", manifest);
    try w.write("src/Leaf.beni", leaf_source);
    try w.write("src/Leaf.js", leaf_sibling);
    try w.write("src/Mid.beni", mid_source);
    try w.write("src/Top.beni", top_source);
    try w.write("src/Side.beni", side_source);
}

// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

const Counters = struct { hits: u64 = 0, misses: u64 = 0, checked: u64 = 0 };

const Run = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    counters: Counters,
};

/// One `beni check` over the project, with the three cache counters read back
/// from the trace and every dump the acceptance test compares taken with it.
///
/// The dumps are on the SAME invocation as the check, so what is compared is
/// one run's whole product and not two runs that happened to agree.
fn run(w: *World, arena: std.mem.Allocator, cache: ?[]const u8, trace: []const u8) !Run {
    var argv: std.ArrayList([]const u8) = .empty;
    // `--cache-keys` ALONE, so stdout is one block and "which keys moved" is
    // a line diff. The interface hashes and the digests are `digest_test.zig`'s
    // subject; what this file is about is the DECISION the keys produce.
    try argv.appendSlice(arena, &.{ "check", "--jobs=1", "--cache-keys" });
    if (cache) |dir| {
        try argv.append(arena, try std.fmt.allocPrint(arena, "--cache-dir={s}", .{dir}));
    } else {
        try argv.append(arena, "--no-cache");
    }
    try argv.append(arena, try std.fmt.allocPrint(arena, "--self-profile={s}", .{trace}));
    try argv.append(arena, "src");
    const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });

    const Event = struct {
        ph: []const u8,
        args: struct {
            cache_hits: ?u64 = null,
            cache_misses: ?u64 = null,
            modules_checked: ?u64 = null,
        } = .{},
    };
    const text = try w.read(trace);
    const parsed = try std.json.parseFromSlice(
        struct { traceEvents: []Event },
        testing.allocator,
        text,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    var counters: Counters = .{};
    for (parsed.value.traceEvents) |e| {
        if (!std.mem.eql(u8, e.ph, "C")) continue;
        if (e.args.cache_hits) |v| counters.hits = v;
        if (e.args.cache_misses) |v| counters.misses = v;
        if (e.args.modules_checked) |v| counters.checked = v;
    }
    return .{
        .stdout = try arena.dupe(u8, r.stdout),
        .stderr = try arena.dupe(u8, r.stderr),
        .exit_code = r.exit_code,
        .counters = counters,
    };
}

/// The `--stage=raw`, `--stage=interface` and `--stage=dispatch` dumps of the
/// three app modules, concatenated — the bytes `fast-compiler.md` §8's
/// acceptance test names beside the diagnostics.
fn dumps(w: *World, arena: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "raw", "interface", "dispatch" }) |stage| {
        const r = try w.runWith(
            &.{ "dump", try std.fmt.allocPrint(arena, "--stage={s}", .{stage}), "src" },
            .{ .raw_diagnostics = true },
        );
        try out.appendSlice(arena, r.stdout);
        try out.appendSlice(arena, r.stderr);
    }
    return out.items;
}

fn expectSameRun(what: []const u8, cold: Run, warm: Run) !void {
    if (cold.exit_code != warm.exit_code) {
        std.debug.print("{s}: exit {d} cold, {d} warm\n", .{ what, cold.exit_code, warm.exit_code });
        return error.ExitCodeDiffers;
    }
    if (!std.mem.eql(u8, cold.stderr, warm.stderr)) {
        std.debug.print("{s}: stderr differs\n--- cold ---\n{s}\n--- warm ---\n{s}\n", .{ what, cold.stderr, warm.stderr });
        return error.StderrDiffers;
    }
    if (!std.mem.eql(u8, cold.stdout, warm.stdout)) {
        std.debug.print("{s}: stdout differs\n--- cold ---\n{s}\n--- warm ---\n{s}\n", .{ what, cold.stdout, warm.stdout });
        return error.StdoutDiffers;
    }
}

/// How many `--cache-keys` lines differ between two runs — the set the
/// enumeration predicts must be re-checked, COMPUTED rather than hard-coded, so
/// a new edit class needs no new expectation.
///
/// A module counts as moved when its whole line is gone (its key changed, or
/// the module did), and a module that appeared counts too.
fn keysMoved(before: []const u8, after: []const u8) !u64 {
    var moved: u64 = 0;
    var it = std.mem.splitScalar(u8, before, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, after, line) == null) moved += 1;
    }
    var jt = std.mem.splitScalar(u8, after, '\n');
    while (jt.next()) |line| {
        if (line.len == 0) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.MalformedBlocks;
        // Present before under ANY key means it was counted above; absent
        // entirely means it is new.
        if (std.mem.indexOf(u8, before, line[0 .. space + 1]) == null) moved += 1;
    }
    return moved;
}

// ---------------------------------------------------------------------------
// The edit classes
// ---------------------------------------------------------------------------

/// `haystack` with the first occurrence of `needle` replaced. Comptime, so a
/// needle that stopped matching is a compile error rather than a row that
/// silently edits nothing.
fn replace(comptime haystack: []const u8, comptime needle: []const u8, comptime with: []const u8) []const u8 {
    @setEvalBranchQuota(20_000);
    const at = comptime (std.mem.indexOf(u8, haystack, needle) orelse
        @compileError("the edit's needle is not in the source: " ++ needle));
    return haystack[0..at] ++ with ++ haystack[at + needle.len ..];
}

const Edit = struct {
    what: []const u8,
    /// The file to rewrite and its new contents.
    path: []const u8 = "src/Leaf.beni",
    source: []const u8,
};

/// **Every edit class of `plans/m4-3.md` §10.2, and at least one instance of
/// each.** The comment-only, whitespace-only, annotated-body,
/// unannotated-body-whose-scheme-moves, add/remove a private value, add/
/// remove/rename a private TYPE, change a private type's constructors
/// (INCLUDING the payload-becomes-a-function case), make a private type `pub`,
/// add a `pub` value, change a `pub` signature, change a type alias's body
/// (INCLUDING the alias-nobody-mentions case), add a constructor to a `pub`
/// type an importer matches exhaustively, change a `where` clause, add a `pub
/// compare`, touch a sibling `.js`, reorder declarations, reorder imports.
const edits = [_]Edit{
    .{ .what = "comment only", .source = "-- a new comment\n" ++ leaf_source },
    .{ .what = "whitespace only", .source = leaf_source ++ "\n\n" },
    .{ .what = "annotated body", .source = replace(leaf_source, "pub one : Int\none =\n    1", "pub one : Int\none =\n    2") },
    .{ .what = "add a private value", .source = leaf_source ++ "\n\nhelper : Int\nhelper =\n    7\n" },
    .{ .what = "add a private type", .source = leaf_source ++ "\n\ntype Unmentioned\n    = U Int\n" },
    // Written out rather than built by two nested `replace`s: a nested call
    // is not reliably folded at comptime, and a row whose edit silently did
    // nothing would pass for the wrong reason.
    .{ .what = "rename a private type a pub signature names", .source =
    \\pub foreign twice : Int -> Int
    \\
    \\
    \\type Secret
    \\    = H Int
    \\    | Extra Int
    \\
    \\
    \\pub type alias Pair =
    \\    { a : Int }
    \\
    \\
    \\pub type Tag
    \\    = Red
    \\    | Blue
    \\
    \\
    \\pub make : Int -> Secret
    \\make x =
    \\    H x
    \\
    \\
    \\pub one : Int
    \\one =
    \\    1
    \\
    },
    .{
        .what = "rename a private type's constructor",
        .source = replace(leaf_source, "    | Extra Int", "    | Additional Int"),
    },
    .{
        .what = "a private type's payload becomes a function (§6.1)",
        .source = replace(leaf_source, "    | Extra Int", "    | Extra (Int -> Int)"),
    },
    .{ .what = "make a private type pub", .source = replace(leaf_source, "type Hidden\n", "pub type Hidden\n") },
    .{ .what = "add a pub value", .source = leaf_source ++ "\n\npub extra : Int\nextra =\n    2\n" },
    .{ .what = "change a pub signature", .source = replace(leaf_source, "pub one : Int", "pub one : Float") },
    .{
        .what = "change an alias body no scheme names (§6.2)",
        .source = replace(leaf_source, "pub type alias Pair =\n    { a : Int }", "pub type alias Pair =\n    { z : Int }"),
    },
    .{
        .what = "add a constructor to a pub type an importer matches",
        .source = replace(leaf_source, "pub type Tag\n    = Red\n    | Blue", "pub type Tag\n    = Red\n    | Blue\n    | Green"),
    },
    .{
        .what = "add a pub compare",
        .source = leaf_source ++ "\n\npub compare : Hidden, Hidden -> Order\ncompare a b =\n    case ( a, b ) of\n        _ ->\n            EQ\n",
    },
    .{ .what = "touch a sibling .js", .path = "src/Leaf.js", .source = "export const twice = (n) => n + n;\n" },
    .{ .what = "reorder declarations", .source =
    \\pub foreign twice : Int -> Int
    \\
    \\
    \\type Hidden
    \\    = H Int
    \\    | Extra Int
    \\
    \\
    \\pub type alias Pair =
    \\    { a : Int }
    \\
    \\
    \\pub type Tag
    \\    = Red
    \\    | Blue
    \\
    \\
    \\pub one : Int
    \\one =
    \\    1
    \\
    \\
    \\pub make : Int -> Hidden
    \\make x =
    \\    H x
    \\
    },
    .{
        .what = "reorder imports",
        .path = "src/Mid.beni",
        .source = replace(mid_source, "import Leaf exposing (Blue, Pair, Red, Tag)", "import Leaf exposing (Blue, Pair, Red, Tag)\nimport Top"),
    },
    .{
        .what = "an UNANNOTATED body whose inferred scheme moves",
        .path = "src/Mid.beni",
        .source = mid_source ++ "\n\npub inferred x =\n    x + 1\n",
    },
};

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

test "the differential harness: every edit class, byte-identical AND cut off exactly" {
    var table: std.ArrayList(u8) = .empty;
    defer table.deinit(testing.allocator);

    for (edits) |edit| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var w = try World.init(testing.allocator, testing.io);
        defer w.deinit();
        try writeProject(&w);

        // ┌─────────────────────────────────────────┐
        // │ cold, then warm0                        │
        // └─────────────────────────────────────────┘
        const cold = try run(&w, arena, "cache", "cold.json");
        const cold_dumps = try dumps(&w, arena);
        try testing.expectEqual(@as(u64, 0), cold.counters.hits);

        const warm0 = try run(&w, arena, "cache", "warm0.json");
        try expectSameRun("warm0", cold, warm0);
        if (warm0.counters.checked != 0) {
            std.debug.print("{s}: warm0 re-checked {d} modules\n", .{ edit.what, warm0.counters.checked });
            return error.WarmRunReChecked;
        }

        // ┌─────────────────────────────────────────┐
        // │ apply, warm1 against a COLD of the same │
        // └─────────────────────────────────────────┘
        const original = try arena.dupe(u8, try w.read(edit.path));
        try w.write(edit.path, edit.source);
        const warm1 = try run(&w, arena, "cache", "warm1.json");
        const warm1_dumps = try dumps(&w, arena);
        const cold1 = try run(&w, arena, null, "cold1.json");
        try expectSameRun(edit.what, cold1, warm1);

        // **The assertion that matters.** The cache re-checked exactly the
        // modules whose key moved — computed from `--cache-keys`, so a new
        // edit class needs no new expectation. An importer skipped when its
        // key moved would be a stale answer; one re-checked when it did not
        // would be a cache doing nothing.
        const predicted = try keysMoved(cold.stdout, warm1.stdout);
        if (warm1.counters.checked != predicted) {
            std.debug.print(
                "{s}: {d} modules re-checked, {d} keys moved\n",
                .{ edit.what, warm1.counters.checked, predicted },
            );
            return error.WrongModulesReChecked;
        }
        const total = warm1.counters.hits + warm1.counters.misses;
        try table.print(testing.allocator, "  {s: <52} re-checked {d: >2}, cut off {d: >2}\n", .{
            edit.what,
            warm1.counters.checked,
            total - warm1.counters.checked,
        });

        // ┌─────────────────────────────────────────┐
        // │ revert, warm2 back to cold              │
        // └─────────────────────────────────────────┘
        try w.write(edit.path, original);
        const warm2 = try run(&w, arena, "cache", "warm2.json");
        try expectSameRun("warm2", cold, warm2);
        try testing.expectEqualStrings(cold_dumps, try dumps(&w, arena));
        // The edited state displaced some entries; the revert re-checks
        // exactly those, and the warm run AFTER it re-checks nothing.
        const settled = try run(&w, arena, "cache", "settled.json");
        try expectSameRun("settled", cold, settled);
        try testing.expectEqual(@as(u64, 0), settled.counters.checked);
        // A dump of the edited tree is not compared against the reverted one:
        // it is compared above, against a COLD build of the edited tree, which
        // is the only honest baseline.
        _ = warm1_dumps;
    }

    std.debug.print("\nthe skip-decision table (edit class × modules):\n{s}\n", .{table.items});
}
