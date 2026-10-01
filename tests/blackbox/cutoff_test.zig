//! The differential harness, bounded (`plans/m4-3.md` §10.2, `fast-compiler.md`
//! §8's *Acceptance is the incremental-determinism matrix, made sharp*).
//!
//! **Two assertions per edit, and the second is the one that is new.**
//!
//! 1. An incremental check's every stream is BYTE-IDENTICAL to a cold check
//!    of the same tree — diagnostics, exit code and the keys it prints.
//!    (`--stage=raw`, `--stage=interface` and `--stage=dispatch` read no
//!    cache, so comparing them here would compare two cold runs; the emitted
//!    JavaScript of a warm build is `cache_test.zig`'s.)
//! 2. The counters show each importer was skipped **exactly when the
//!    enumeration says it may be** — not merely that it was skipped.
//!
//! Byte-identity alone is satisfied by a cache that never hits, so the
//! criterion is byte-identity AND the counter. The predicted set is not
//! hard-coded: it is computed from `--cache-keys`, so a new edit class needs no
//! new expectation, and what the assertion says is *the cache re-checked
//! exactly the modules whose key moved, and nothing else*.
//!
//! **The loop is `plans/m4-3.md` §10.2's, less the warm run of the
//! unchanged tree, which `cache_test.zig` asserts on its own:**
//!
//! ```
//! cold   check into a fresh cache directory, capture every stream
//! apply  the edit
//! warm1  check; byte-identical to a COLD check of the EDITED tree;
//!        the re-checked set is exactly the set whose key moved
//! revert the edit
//! warm2  check; byte-identical to cold; every key is back to its cold
//!        value, so nothing is re-checked
//! ```
//!
//! **What this file is, against the full cross.** `bench/cutoff.sh` runs the
//! same loop over every module of `bench/corpus`, `core` under `--core-root`
//! and the `tests/corpus/` directory fixtures — thousands of builds, a
//! documented command with a stated budget. What runs in every gate is one
//! edit per branch of the cut-off decision (`cache/Key.zig`: a module's key
//! is its own terms plus, per import, that import's interface hash and
//! dependency digest):
//!
//!   * its own source moves and no import's pair does: the edited module is
//!     re-checked and its importers are cut off;
//!   * an import's interface hash moves: its importers are re-checked, and
//!     theirs through their digests;
//!   * an import's digest moves and its hash does not: its importers are
//!     re-checked all the same — the demonstrated miscompile of a `pub type
//!     alias` no scheme names, which a warm build accepted and a cold one
//!     refuses.
//!
//! WHICH edits move a hash or a digest is `digest_test.zig`'s subject, row by
//! row; what is here is the decision those moves drive.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

// ---------------------------------------------------------------------------
// The project — §10.1's, and `digest_test.zig`'s
// ---------------------------------------------------------------------------

const leaf_source =
    \\pub foreign pure twice : Int -> Int
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
    \\pub type alias Coord =
    \\    ( Int, Int )
    \\
    \\
    \\pub type Tag
    \\    = Red
    \\    | Blue
    \\
    \\
    \\type alias Inner =
    \\    { n : Int }
    \\
    \\
    \\pub type alias Outer =
    \\    { inner : Inner }
    \\
    \\
    \\pub keep : Outer -> Outer
    \\keep o =
    \\    o
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
    \\import Leaf exposing (Blue, Coord, Pair, Red, Tag)
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
    \\
    \\pub column : Coord -> Int
    \\column ( x, y ) =
    \\    x
    \\
    \\
    \\pub kept : Int
    \\kept =
    \\    (Leaf.keep { inner = { n = 1 } }).inner.n
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
/// from the trace.
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
    /// The skip decision, pinned: modules re-checked by the warm build
    /// after the edit, and modules cut off. `--cache-keys` already predicts
    /// the first; pinning it too makes the number of re-checked modules a
    /// fact the test states rather than a consequence of the key. The cut-off
    /// count includes the core modules the check reaches — here the eight
    /// it always keeps (the prelude and `Task`) and `Js`, which `String`
    /// imports, since the project imports no other (checker.md §4.1,
    /// amended 2026-10-01).
    rechecked: u64,
    cut_off: u64,
    /// The warm build's exit code after the edit, for an edit meant to
    /// change the answer and not only the keys.
    exit_code: ?u8 = null,
};

// ---------------------------------------------------------------------------
// One edit per branch of the decision
// ---------------------------------------------------------------------------

test "a comment in Leaf re-checks Leaf alone: no import's pair moved, so its importers are cut off" {
    try differential(.{ .what = "comment only", .rechecked = 1, .cut_off = 12, .source = "-- a new comment\n" ++ leaf_source });
}

test "a pub signature in Leaf moves its interface hash and re-checks every module downstream" {
    // `Mid` sees `Leaf`'s hash move; `Top` and `Side` see `Mid`'s digest
    // move, because a digest carries its imports' pairs.
    try differential(.{ .what = "change a pub signature", .rechecked = 4, .cut_off = 9, .source = replace(leaf_source, "pub one : Int", "pub one : Float") });
}

test "an alias body no scheme names moves only Leaf's digest, and Mid is re-checked and refuses" {
    // `Coord` is named by no scheme of `Leaf`, so `Leaf`'s record, and
    // with it its hash, does not move; `Mid`'s `column` expands it and now
    // returns a `Float` its annotation calls `Int`. Were the key to fold
    // the hash alone, `Mid` would hit, and the warm build would exit 0
    // where a cold one reports the mismatch.
    try differential(.{
        .what = "change an alias body no scheme names",
        .rechecked = 4,
        .cut_off = 9,
        .source = replace(leaf_source, "pub type alias Coord =\n    ( Int, Int )", "pub type alias Coord =\n    ( Float, Int )"),
        .exit_code = 1,
    });
}

test "a private alias inside a scheme's alias moves Leaf's record, and Mid reads the new body" {
    // `keep : Outer -> Outer` names `Outer`, whose body names the private
    // `Inner`: the record carries both bodies, once each, on their
    // `type_refs` rows (checker-v2.md §14.2). `Inner`'s field becoming a
    // `Float` moves Leaf's record and hash, so every module downstream is
    // re-checked, and `Mid.kept` — which reads `Inner` only through
    // `keep`'s scheme — now returns a `Float` its annotation calls `Int`.
    try differential(.{
        .what = "change a private alias a pub scheme reaches",
        .rechecked = 4,
        .cut_off = 9,
        .source = replace(leaf_source, "type alias Inner =\n    { n : Int }", "type alias Inner =\n    { n : Float }"),
        .exit_code = 1,
    });
}

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

/// `plans/m4-3.md` §10.2's loop over one edit: cold, the edit and warm1
/// against a cold check of the edited tree, the revert and warm2.
fn differential(edit: Edit) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ cold                                    │
    // └─────────────────────────────────────────┘
    const cold = try run(&w, arena, "cache", "cold.json");
    try testing.expectEqual(@as(u64, 0), cold.counters.hits);
    try testing.expectEqual(@as(u8, 0), cold.exit_code);

    // ┌─────────────────────────────────────────┐
    // │ apply, warm1 against a COLD of the same │
    // └─────────────────────────────────────────┘
    const original = try arena.dupe(u8, try w.read(edit.path));
    try w.write(edit.path, edit.source);
    const warm1 = try run(&w, arena, "cache", "warm1.json");
    const cold1 = try run(&w, arena, null, "cold1.json");
    try expectSameRun(edit.what, cold1, warm1);
    if (edit.exit_code) |want| try testing.expectEqual(want, warm1.exit_code);

    // **The assertion that matters.** The cache re-checked exactly the
    // modules whose key moved — computed from `--cache-keys`. An importer
    // skipped when its key moved would be a stale answer; one re-checked
    // when it did not would be a cache doing nothing.
    const predicted = try keysMoved(cold.stdout, warm1.stdout);
    if (warm1.counters.checked != predicted) {
        std.debug.print(
            "{s}: {d} modules re-checked, {d} keys moved\n",
            .{ edit.what, warm1.counters.checked, predicted },
        );
        return error.WrongModulesReChecked;
    }
    const total = warm1.counters.hits + warm1.counters.misses;
    if (warm1.counters.checked != edit.rechecked or total - warm1.counters.checked != edit.cut_off) {
        std.debug.print(
            "{s}: re-checked {d}, cut off {d}; the test says {d} and {d}\n",
            .{ edit.what, warm1.counters.checked, total - warm1.counters.checked, edit.rechecked, edit.cut_off },
        );
        return error.SkipDecisionMoved;
    }

    // ┌─────────────────────────────────────────┐
    // │ revert, warm2 back to cold              │
    // └─────────────────────────────────────────┘
    try w.write(edit.path, original);
    // The edited state wrote entries beside the cold ones and displaced
    // none: every module's key is back to its cold value, and each finds the
    // entry the cold run wrote.
    const warm2 = try run(&w, arena, "cache", "warm2.json");
    try expectSameRun("warm2", cold, warm2);
    try testing.expectEqual(@as(u64, 0), warm2.counters.checked);
}
