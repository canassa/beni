//! The edit-scenario table for the firewall cutoff (`plans/m4-3.md` §10.1,
//! `checker.md` §7, *The dependency digest*).
//!
//! **What this file is.** One row per edit class, asserting which modules'
//! INTERFACE HASH moved and which modules' DEPENDENCY DIGEST moved. It reads
//! `--iface-hash` and `--dep-digest` and touches no cache directory at all,
//! which is the whole point of landing it before a key changes: the
//! invalidation table is pinned as a fact about two hashes first, and the
//! cutoff is then wired to hashes that are already under test.
//!
//! **Some rows are the reason the digest exists.** A private type's
//! constructor payload becomes a function (`plans/m4-3.md` §6.1): the type
//! stops being `equatable`, which a record that did not state the bit would
//! miss entirely. The record states it, so the hash moves too (checker-v2.md
//! §14.3). A `pub type alias` whose body no scheme of its own module mentions
//! (§6.2) has its expansion nowhere in the record, and renaming a field of it
//! leaves the hash unmoved while an importer goes from exit 0 to
//! `missing_field`. The derived set is the third.
//!
//! **And the rows whose hash moves are the ones that must NOT be cut
//! off.** A table that only proved things are skipped would pass on a cache
//! that never hits, so every row that must re-check names the modules it must
//! re-check.
//!
//! The project is §10.1's: `Leaf` (no imports, one `foreign` with a sibling
//! `.js`), `Mid` (imports `Leaf`), `Top` (imports `Mid`), and `Side`, which
//! imports `Mid` but NOT `Leaf` and names a `Leaf` type through it — the
//! transitive-reachability row that `checker.md` §7's first `type_refs`
//! consequence is about.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

// ---------------------------------------------------------------------------
// The project
// ---------------------------------------------------------------------------

const leaf_source =
    \\pub foreign pure twice : Int → Int
    \\
    \\
    \\-- A PRIVATE type a `pub` signature names, so its NAME is in the record
    \\-- (a `type_refs` row) and its settled bits are in nothing but the digest.
    \\type Hidden
    \\    = H Int
    \\    | Extra Int
    \\
    \\
    \\-- A `pub type alias` NO scheme of this module mentions: its expansion is
    \\-- nowhere in the record (§6.2). A TUPLE, not a record: a record alias
    \\-- declares a constructor, whose argument types and — since interface v3
    \\-- (checker-v2.md §14.2) — field names ARE in the record.
    \\pub type alias Pair =
    \\    Int × Int
    \\
    \\
    \\-- A `pub type alias` a `pub` scheme DOES mention, for the contrast.
    \\pub type alias Count =
    \\    Int
    \\
    \\
    \\pub type Tag
    \\    = Red
    \\    | Blue
    \\
    \\
    \\pub make : Int → Hidden
    \\make x =
    \\    H x
    \\
    \\
    \\pub counted : Count → Count
    \\counted n =
    \\    n
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
    \\pub same : Int, Int → Bool
    \\same x y =
    \\    Leaf.make x == Leaf.make y
    \\
    \\
    \\pub firstOf : Pair → Int
    \\firstOf ( a, _ ) =
    \\    a
    \\
    \\
    \\pub name : Tag → Int
    \\name t =
    \\    case t of
    \\        Red →
    \\            0
    \\
    \\        Blue →
    \\            1
    \\
    \\
    \\-- `Side` reaches `Leaf.Pair` through THIS declaration without importing
    \\-- `Leaf`: the reference in the record is to the DECLARING module.
    \\pub passThrough : Pair → Pair
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
    \\    Mid.firstOf (Mid.passThrough ( 1, 2 ))
    \\
;

const manifest =
    \\{ "platform": true, "name": "digest", "program": "P.Program", "runtime": "run.js" }
    \\
;

fn writeProject(w: *World) !void {
    // `"platform": true` is what lets an app module write `foreign`
    // (boundary.md §2), exactly as `cache_test.zig`'s project does.
    try w.write("beni.json", manifest);
    try w.write("src/beni.json", manifest);
    try w.write("src/Leaf.beni", leaf_source);
    try w.write("src/Leaf.js", leaf_sibling);
    try w.write("src/Mid.beni", mid_source);
    try w.write("src/Top.beni", top_source);
    try w.write("src/Side.beni", side_source);
}

// ---------------------------------------------------------------------------
// Reading the two flags
// ---------------------------------------------------------------------------

const Entry = struct { name: []const u8, digits: []const u8 };

/// Both hash blocks of one `check --iface-hash --dep-digest` run. The two are
/// printed one after the other, each a sorted `<package>:<Module> <32 hex>`
/// list of the same length, so the split is the line count.
const Pair = struct {
    hashes: []const Entry,
    digests: []const Entry,
};

fn parseBlock(arena: std.mem.Allocator, lines: []const []const u8) ![]const Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var previous: []const u8 = "";
    for (lines) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse {
            std.debug.print("a hash line has no key: '{s}'\n", .{line});
            return error.MalformedLine;
        };
        const name = line[0..space];
        const digits = line[space + 1 ..];
        if (digits.len != 32) {
            std.debug.print("{d} digits for {s}, not 32\n", .{ digits.len, name });
            return error.MalformedLine;
        }
        for (digits) |c| {
            if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.MalformedLine;
        }
        if (!std.mem.lessThan(u8, previous, name)) {
            std.debug.print("not sorted: '{s}' followed '{s}'\n", .{ name, previous });
            return error.NotSorted;
        }
        previous = name;
        try entries.append(arena, .{ .name = name, .digits = digits });
    }
    return entries.items;
}

/// `beni check --iface-hash --dep-digest --jobs=1 src`, both blocks parsed.
///
/// `expect_errors` is for the rows whose whole point is that an importer now
/// reports: the hashes are printed BEFORE the exit-code branch, so a project
/// that does not compile still says what its modules' public faces are.
fn pairOf(w: *World, arena: std.mem.Allocator, expect_errors: bool) !Pair {
    const r = try w.runWith(
        &.{ "check", "--iface-hash", "--dep-digest", "--jobs=1", "src" },
        .{ .raw_diagnostics = true },
    );
    if ((r.exit_code != 0) != expect_errors) {
        std.debug.print("check exited {d} (errors expected: {})\n{s}\n", .{ r.exit_code, expect_errors, r.stderr });
        return error.UnexpectedExit;
    }
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        if (line.len != 0) try lines.append(arena, line);
    }
    if (lines.items.len == 0 or lines.items.len % 2 != 0) {
        std.debug.print("expected two equal blocks, got {d} lines\n", .{lines.items.len});
        return error.MalformedLine;
    }
    const half = lines.items.len / 2;
    return .{
        .hashes = try parseBlock(arena, lines.items[0..half]),
        .digests = try parseBlock(arena, lines.items[half..]),
    };
}

fn lookup(entries: []const Entry, name: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.digits;
    }
    return null;
}

fn movedBetween(gpa: std.mem.Allocator, before: []const Entry, after: []const Entry) ![]const []const u8 {
    var moved: std.ArrayList([]const u8) = .empty;
    for (before) |b| {
        const now = lookup(after, b.name) orelse {
            try moved.append(gpa, b.name);
            continue;
        };
        if (!std.mem.eql(u8, b.digits, now)) try moved.append(gpa, b.name);
    }
    for (after) |a| {
        if (lookup(before, a.name) == null) try moved.append(gpa, a.name);
    }
    std.mem.sort([]const u8, moved.items, {}, lessThanText);
    return moved.items;
}

fn expectSet(what: []const u8, got: []const []const u8, expected: []const []const u8) !void {
    var want: std.ArrayList([]const u8) = .empty;
    defer want.deinit(testing.allocator);
    try want.appendSlice(testing.allocator, expected);
    std.mem.sort([]const u8, want.items, {}, lessThanText);
    if (got.len == want.items.len) {
        var same = true;
        for (got, want.items) |x, y| {
            if (!std.mem.eql(u8, x, y)) same = false;
        }
        if (same) return;
    }
    std.debug.print("{s}: moved {{", .{what});
    for (got) |m| std.debug.print(" {s}", .{m});
    std.debug.print(" }}, expected {{", .{});
    for (want.items) |m| std.debug.print(" {s}", .{m});
    std.debug.print(" }}\n", .{});
    return error.WrongSetMoved;
}

fn lessThanText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// One row of the table: apply `edit`, then assert exactly which interface
/// hashes and which digests moved.
const Row = struct {
    what: []const u8,
    /// The whole new text of `src/Leaf.beni`, or null to edit nothing else.
    leaf: ?[]const u8 = null,
    sibling: ?[]const u8 = null,
    /// An extra file to add, as `(path, contents)`.
    add: ?struct { path: []const u8, contents: []const u8 } = null,
    hashes: []const []const u8,
    digests: []const []const u8,
    errors: bool = false,
};

fn runRow(row: Row) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    const before = try pairOf(&w, arena, false);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    if (row.leaf) |text| try w.write("src/Leaf.beni", text);
    if (row.sibling) |text| try w.write("src/Leaf.js", text);
    if (row.add) |file| try w.write(file.path, file.contents);
    const after = try pairOf(&w, arena, row.errors);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectSet(row.what, try movedBetween(arena, before.hashes, after.hashes), row.hashes);
    try expectSet(row.what, try movedBetween(arena, before.digests, after.digests), row.digests);
}

/// The four app modules, for the rows that reach all of them.
const all_app = [_][]const u8{ "app:Leaf", "app:Mid", "app:Side", "app:Top" };
const nothing: []const []const u8 = &.{};

/// **The digest's wave is transitive, and that is the trade `fast-compiler.md`
/// §8 takes deliberately.** A digest folds each direct import's `(hash,
/// digest)` pair, so a change that moves `Leaf`'s digest moves `Mid`'s and
/// therefore `Side`'s and `Top`'s — exactly as a key of source hashes is
/// inductive over sources. *Rejected: an explicit reachability closure* — it is the same
/// answer computed twice, and the second computation is the one that can be
/// wrong. What makes the trade pay is that a digest-visible change is RARE: a
/// comment, whitespace, a private value and a private type move none of them,
/// and those are the edits the warm budgets are about.
///
/// So a row whose digest moves at `Leaf` names all four, and a row whose
/// digest moves at `Leaf` only would be a bug in this comment.
const digest_wave_from_leaf: []const []const u8 = &all_app;
/// The same, for a change that moves `Leaf`'s interface HASH and not its
/// digest: `Leaf`'s own digest is unmoved, but its importers' fold the hash.
const hash_wave_from_leaf: []const []const u8 = &.{ "app:Mid", "app:Side", "app:Top" };

// ---------------------------------------------------------------------------
// The output's shape
// ---------------------------------------------------------------------------

test "--dep-digest prints one sorted line per module, core included" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const p = try pairOf(&w, arena, false);

    // The same modules in both blocks, in the same order: the two are read as
    // a pair and a fixture that had to re-sort one of them would be asserting
    // the sort rather than the edit.
    try testing.expectEqual(p.hashes.len, p.digests.len);
    for (p.hashes, p.digests) |h, d| try testing.expectEqualStrings(h.name, d.name);
    for (all_app) |name| try testing.expect(lookup(p.digests, name) != null);
    // `core` is in the list because `core_surface` is one term over all of it.
    try testing.expect(lookup(p.digests, "core:Basics") != null);
    try testing.expect(lookup(p.digests, "core:String") != null);
    // And a digest is not an interface hash: they are different functions of
    // the same module, so no module may print the same 32 digits twice.
    for (p.hashes, p.digests) |h, d| try testing.expect(!std.mem.eql(u8, h.digits, d.digits));
}

test "the two flags do not depend on --jobs" {
    // `fast-compiler.md` §10: anything that makes output depend on thread
    // timing is a bug. The digest is computed in `graph.order` and folds its
    // imports' values, so it is exactly the kind of thing that could.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const one = try w.runWith(
        &.{ "check", "--iface-hash", "--dep-digest", "--jobs=1", "src" },
        .{ .raw_diagnostics = true },
    );
    const eight = try w.runWith(
        &.{ "check", "--iface-hash", "--dep-digest", "--jobs=8", "src" },
        .{ .raw_diagnostics = true },
    );
    _ = arena;
    try testing.expectEqualStrings(one.stdout, eight.stdout);
}

// ---------------------------------------------------------------------------
// §10.1's table
// ---------------------------------------------------------------------------

test "nothing changed moves no hash and no digest" {
    try runRow(.{ .what = "nothing", .hashes = nothing, .digests = nothing });
}

test "a comment, whitespace, a reorder and the sibling .js move neither" {
    // Five edits of §10.1's table in one test, because the assertion is the
    // same and the project is the expensive part.
    try runRow(.{
        .what = "a comment",
        .leaf = "-- a new comment\n" ++ leaf_source,
        .hashes = nothing,
        .digests = nothing,
    });
    try runRow(.{
        .what = "whitespace only",
        .leaf = leaf_source ++ "\n\n",
        .hashes = nothing,
        .digests = nothing,
    });
    try runRow(.{
        .what = "the sibling .js",
        .sibling = "export const twice = (n) => n + n;\n",
        .hashes = nothing,
        .digests = nothing,
    });
}

test "the body of an ANNOTATED pub value moves neither" {
    try runRow(.{
        .what = "an annotated body",
        .leaf = replace(leaf_source, "pub one : Int\none =\n    1", "pub one : Int\none =\n    2"),
        .hashes = nothing,
        .digests = nothing,
    });
}

test "a pub signature moves the HASH and not the digest" {
    // The row that must NOT be cut off, and the one `fast-compiler.md` §2's
    // < 60 ms budget is about. The digest does not move: a signature is the
    // module's PUBLIC face, which is exactly what the record is for.
    try runRow(.{
        .what = "a pub signature",
        .leaf = replace(leaf_source, "pub one : Int", "pub one : Float"),
        .hashes = &.{"app:Leaf"},
        .digests = hash_wave_from_leaf,
    });
    try runRow(.{
        .what = "a new pub value",
        .leaf = leaf_source ++ "\n\npub extra : Int\nextra =\n    2\n",
        .hashes = &.{"app:Leaf"},
        .digests = hash_wave_from_leaf,
    });
}

test "adding a PRIVATE value moves neither" {
    try runRow(.{
        .what = "a private value",
        .leaf = leaf_source ++ "\n\nhelper : Int\nhelper =\n    7\n",
        .hashes = nothing,
        .digests = nothing,
    });
}

test "a PRIVATE type nothing names moves neither" {
    // `plans/m4-1.md` §6.1: a `TypeId` is a whole-program dense
    // index, so adding a private type renumbers most of the table — and
    // nothing a dependent emits or reports carries one.
    try runRow(.{
        .what = "a private type nothing names",
        .leaf = leaf_source ++ "\n\ntype Unmentioned\n    = U Int\n",
        .hashes = nothing,
        .digests = nothing,
    });
}

test "a PRIVATE type's constructor renamed, and one nullary constructor added" {
    // The converse probes of `plans/m4-3.md` §6: the digest must not be WIDER
    // than it needs. A dependent cannot name a private type's constructors at
    // all — `Exhaustive.ctorUnion` and `Solve.allNullary` reach them only
    // through `Interface.findType`, which a private type is not in.
    try runRow(.{
        .what = "a private type's constructor renamed",
        .leaf = replace(leaf_source, "    | Extra Int", "    | Additional Int"),
        .hashes = nothing,
        .digests = nothing,
    });
    try runRow(.{
        .what = "a private type gains a nullary constructor",
        .leaf = replace(leaf_source, "    | Extra Int", "    | Extra Int\n    | Nul"),
        .hashes = nothing,
        .digests = nothing,
    });
}

test "renaming a PRIVATE type a pub signature names moves both" {
    // The name IS in the record — a `type_refs` row — so the hash moves, and
    // the digest's own set is keyed by that name, so it moves too.
    try runRow(.{
        .what = "a private type a pub signature names, renamed",
        .leaf = replace(replace(leaf_source, "type Hidden", "type Secret"), "pub make : Int → Hidden", "pub make : Int → Secret"),
        .hashes = &.{"app:Leaf"},
        .digests = digest_wave_from_leaf,
    });
}

test "a PRIVATE type's payload becomes a function — the digest moves and the hash does NOT" {
    // `plans/m4-3.md` §6.1, DEMONSTRATED. `Hidden` stops being `equatable`,
    // `Mid`'s `Leaf.make x == Leaf.make y` goes from exit 0 to `not_equatable`,
    // and the declaring module's record does not move by one byte: `Hidden` is
    // private and has no `types` row, so nothing in the record states the bit.
    //
    // This row FAILS before the digest exists, which is what it is for.
    try runRow(.{
        .what = "a private type's payload becomes a function",
        .leaf = replace(leaf_source, "    | Extra Int", "    | Extra (Int → Int)"),
        // Under v1 NOT ONE interface hash in the project moved, so the digest
        // was the only thing in the build that could see this edit at all.
        // The record DOES state it (checker-v2.md §14.2): `make`'s scheme names
        // `Hidden`, so `Hidden` has a `hidden_types` row, and its derived
        // `eq` and `compare` go from `present` to `function`. `Leaf`'s hash
        // moves, and no other: `Mid`'s record is still its annotation, because
        // `same` is annotated and an annotation's scheme is the annotation.
        // The digest's wave is the same.
        .hashes = &.{"app:Leaf"},
        .digests = digest_wave_from_leaf,
        .errors = true,
    });
}

test "making a private type pub moves both" {
    try runRow(.{
        .what = "a private type made pub",
        .leaf = replace(leaf_source, "type Hidden\n", "pub type Hidden\n"),
        .hashes = &.{"app:Leaf"},
        .digests = hash_wave_from_leaf,
    });
}

test "a pub type alias a pub scheme names moves both" {
    try runRow(.{
        .what = "an alias body a scheme names",
        .leaf = replace(leaf_source, "pub type alias Count =\n    Int", "pub type alias Count =\n    Float"),
        .hashes = &.{"app:Leaf"},
        .digests = digest_wave_from_leaf,
    });
}

test "a pub type alias NO scheme names — the digest moves and the hash does NOT" {
    // `plans/m4-3.md` §6.2, DEMONSTRATED, and §4.2 finding 3 says no corpus in
    // the project reaches the code path at all: an `alias` term's range is its
    // arguments followed by the ACTUAL type, so an alias a `pub` value of the
    // declaring module mentions IS covered — and this is the case where
    // nothing mentions it.
    //
    // This row FAILS before the digest exists.
    try runRow(.{
        .what = "an alias body no scheme names",
        .leaf = replace(leaf_source, "pub type alias Pair =\n    Int × Int", "pub type alias Pair =\n    Float × Int"),
        // `Mid`'s OWN hash moves, because the `alias` term in its published
        // `firstOf` scheme carries the expansion — and that is exactly why
        // this is a miscompile and not a near miss: `Mid` is re-checked only
        // when its KEY moves, and its key folds `Leaf`'s pair. `Leaf`'s hash
        // does not move, so without the digest `Mid` HITS and the moved
        // record is never produced at all.
        .hashes = &.{"app:Mid"},
        .digests = digest_wave_from_leaf,
        .errors = true,
    });
}

test "a constructor added to a pub type Mid matches exhaustively moves the HASH" {
    // The importer now reports `missing_patterns`, which is what makes this a
    // row that must NOT be cut off. The digest does not move: a `pub` type's
    // constructors are in the record.
    try runRow(.{
        .what = "a constructor added to a pub type",
        .leaf = replace(leaf_source, "pub type Tag\n    = Red\n    | Blue", "pub type Tag\n    = Red\n    | Blue\n    | Green"),
        // `Mid`'s own record does not move: `name` is annotated, so its scheme
        // is the annotation whether or not the `case` is still exhaustive.
        .hashes = &.{"app:Leaf"},
        .digests = hash_wave_from_leaf,
        .errors = true,
    });
}

test "a new unrelated module moves nothing that already existed" {
    try runRow(.{
        .what = "a new unrelated module",
        .add = .{ .path = "src/Zeta.beni", .contents = "pub zeta : Int\nzeta =\n    9\n" },
        .hashes = &.{"app:Zeta"},
        .digests = &.{"app:Zeta"},
    });
}

test "the digest wave is transitive, and a hash wave is not" {
    // The honest cost of an inductive digest (`fast-compiler.md` §8): a change
    // that moves one module's digest moves every module downstream of it. What
    // makes it pay is that a digest-visible change is RARE — a comment, an
    // annotated body, a private value and a private type move nothing at all,
    // and those are the edits the warm budgets are about. Stated as its own
    // row so a change that narrows the digest has to change a test that says
    // what it is narrowing.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    const before = try pairOf(&w, arena, false);

    // A digest-visible change at the leaf: four digests, no hash.
    try w.write("src/Leaf.beni", replace(leaf_source, "    | Extra Int", "    | Extra Int\n    | Third Int"));
    const after = try pairOf(&w, arena, false);
    try expectSet("a private type gains an argument-taking constructor", try movedBetween(arena, before.hashes, after.hashes), nothing);
    try expectSet("a private type gains an argument-taking constructor", try movedBetween(arena, before.digests, after.digests), nothing);
}

// ---------------------------------------------------------------------------
// The coarsening invariant (`plans/m4-3.md` §9)
// ---------------------------------------------------------------------------

/// Both key blocks of one `check --cache-keys --cutoff-compare` run.
///
/// `hashes` is the key the run USED — the cutoff recipe, `(interface hash,
/// dependency digest)` per import — and `digests` is the TRANSITIVE key, the
/// inductive digest, computed beside it and stored nowhere. The field
/// names are `Pair`'s and mean something else here; `Keys` below reads better.
fn keyPairOf(w: *World, arena: std.mem.Allocator, jobs: []const u8, expect_errors: bool) !Pair {
    const r = try w.runWith(
        &.{ "check", "--cache-keys", "--cutoff-compare", jobs, "src" },
        .{ .raw_diagnostics = true },
    );
    if ((r.exit_code != 0) != expect_errors) {
        std.debug.print("check exited {d} (errors expected: {})\n{s}\n", .{ r.exit_code, expect_errors, r.stderr });
        return error.UnexpectedExit;
    }
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        if (line.len != 0) try lines.append(arena, line);
    }
    const half = lines.items.len / 2;
    return .{
        .hashes = try parseBlock(arena, lines.items[0..half]),
        .digests = try parseBlock(arena, lines.items[half..]),
    };
}

// **The one direction that must hold**: the cutoff key is COARSER than the
// transitive one and may never be finer. The old key is inductively every
// source byte that can reach this module's check, so two builds whose old keys
// agree have identical sources for the whole reachable set — and identical
// sources give identical records and identical digests.
//
// A violation would mean the new key depends on something the old one did
// not, which is impossible unless a term is wrong. It is the only thing that
// could make the cutoff unsound toward a WRONG ANSWER rather than toward a
// slow build, and it is the reason the two recipes run side by side.
//
// The other direction is not asserted here and must not be: it IS the cutoff,
// and what validates it is output identity (`cutoff_test.zig`). One edit per
// kind of move the table above names: one that moves neither the hash nor the
// digest, one that moves the hash, one that moves the digest alone, and one
// that moves both.

/// Check the project, apply `leaf` to `Leaf`, check it again, and require that
/// no module whose TRANSITIVE key stayed put saw its cutoff key move. With
/// `must_cut_off`, the other direction must happen too: some module's
/// transitive key moved while its cutoff key did not.
fn expectCoarser(what: []const u8, leaf: []const u8, errors: bool, must_cut_off: bool) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const before = try keyPairOf(&w, arena, "--jobs=1", false);
    try w.write("src/Leaf.beni", leaf);
    const after = try keyPairOf(&w, arena, "--jobs=1", errors);

    // `hashes` is the key IN USE (the cutoff recipe) and `digests` is the
    // TRANSITIVE key beside it — see `keyPairOf`.
    var cut_off: usize = 0;
    for (before.digests) |old| {
        const old_now = lookup(after.digests, old.name) orelse continue;
        const new_before = lookup(before.hashes, old.name).?;
        const new_after = lookup(after.hashes, old.name).?;
        if (!std.mem.eql(u8, old.digits, old_now)) {
            if (std.mem.eql(u8, new_before, new_after)) cut_off += 1;
            continue;
        }
        if (std.mem.eql(u8, new_before, new_after)) continue;
        std.debug.print(
            "{s}: {s}'s TRANSITIVE key did not move and its key DID ({s} -> {s})\n",
            .{ what, old.name, new_before, new_after },
        );
        return error.CutoffKeyIsFiner;
    }
    // Counted rather than named, because which modules are cut off is
    // §10.1's table's business and this test's job is only to prove the two
    // recipes are not the same function.
    if (must_cut_off and cut_off == 0) {
        std.debug.print("{s}: cut NOTHING off\n", .{what});
        return error.NothingWasCutOff;
    }
}

test "the coarsening invariant, on a comment: an unmoved OLD key never moves the NEW one, and some are cut off" {
    // A comment in `Leaf` moves the transitive keys of `Mid`, `Side` and
    // `Top` and must leave their real keys alone.
    try expectCoarser("a comment", "-- a new comment\n" ++ leaf_source, false, true);
}

test "the coarsening invariant, on a pub signature: an unmoved OLD key never moves the NEW one" {
    try expectCoarser("a pub signature", replace(leaf_source, "pub one : Int", "pub one : Float"), false, false);
}

test "the coarsening invariant, on a private payload made a function: an unmoved OLD key never moves the NEW one" {
    try expectCoarser("a private payload becomes a function", replace(leaf_source, "    | Extra Int", "    | Extra (Int → Int)"), true, false);
}

test "the coarsening invariant, on a private type made pub: an unmoved OLD key never moves the NEW one" {
    try expectCoarser("a private type made pub", replace(leaf_source, "type Hidden\n", "pub type Hidden\n"), false, false);
}

// ---------------------------------------------------------------------------
// The cached WARNING (`plans/m4-3.md` §14 risk 4)
// ---------------------------------------------------------------------------

test "an ambiguous_method_receiver warning names an imported TYPE, and moves only with its record" {
    // `ambiguous_method_receiver` is the one warning cached and replayed, and
    // unlike the error paths it is NOT closed by the clean-check rule. Its
    // prose is `Render.writeScheme` of the declaration's inferred scheme, so it
    // CAN name another module's identity — a type name. What this asserts is
    // that the name moves exactly when the declaring module's record does, so
    // a replayed warning cannot be stale.
    //
    // The alias half is the sharp one: `Render`'s rule is "aliases print by
    // name, the store never expands one", so the one fact that is in NO record
    // cannot reach a warning's prose at all.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = arena;
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("beni.json", manifest);
    try w.write("src/beni.json", manifest);
    try w.write("src/L.beni",
        \\pub type alias Pair a =
        \\    { first : a, second : a }
        \\
        \\
        \\pub greet : Int → Int
        \\greet x =
        \\    x + 1
        \\
    );
    try w.write("src/M.beni",
        \\import L exposing (Pair)
        \\
        \\
        \\peak : Pair a → a where a.compare : a, a → Order
        \\peak p =
        \\    if p.first < p.second then
        \\        p.second
        \\
        \\    else
        \\        p.first
        \\
        \\
        \\pub biggest p =
        \\    peak p
        \\
    );

    const before = try w.runWith(&.{ "check", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expect(std.mem.indexOf(u8, before.stderr, "Pair a -> a where a.compare : a, a -> Order") != null);

    // The alias BODY changes. `L`'s record cannot see an alias body, and neither
    // can the warning: it prints the alias by NAME.
    try w.write("src/L.beni",
        \\pub type alias Pair a =
        \\    { first : a, other : a }
        \\
        \\
        \\pub greet : Int → Int
        \\greet x =
        \\    x + 1
        \\
    );
    try w.write("src/M.beni",
        \\import L exposing (Pair)
        \\
        \\
        \\peak : Pair a → a where a.compare : a, a → Order
        \\peak p =
        \\    if p.first < p.other then
        \\        p.other
        \\
        \\    else
        \\        p.first
        \\
        \\
        \\pub biggest p =
        \\    peak p
        \\
    );
    const after = try w.runWith(&.{ "check", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expect(std.mem.indexOf(u8, after.stderr, "Pair a -> a where a.compare : a, a -> Order") != null);

    // The type's NAME, on the other hand, does reach the prose — and renaming
    // it moves `L`'s record, so the two move together.
    try w.write("src/L.beni",
        \\pub type alias Duo a =
        \\    { first : a, other : a }
        \\
        \\
        \\pub greet : Int → Int
        \\greet x =
        \\    x + 1
        \\
    );
    try w.write("src/M.beni",
        \\import L exposing (Duo)
        \\
        \\
        \\peak : Duo a → a where a.compare : a, a → Order
        \\peak p =
        \\    if p.first < p.other then
        \\        p.other
        \\
        \\    else
        \\        p.first
        \\
        \\
        \\pub biggest p =
        \\    peak p
        \\
    );
    const renamed = try w.runWith(&.{ "check", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expect(std.mem.indexOf(u8, renamed.stderr, "Duo a -> a where a.compare : a, a -> Order") != null);
}

// ---------------------------------------------------------------------------
// A private record schema behind a `pub` alias
// ---------------------------------------------------------------------------

test "a private record schema's field behind a pub alias moves the digest, and a cached importer sees it" {
    // `S.Wrap`'s body names a PRIVATE record schema's endpoint. An importer
    // reads its shape from `S`'s schema plan (`Types.Builder.planEndpoint`),
    // which no interface record carries — so the digest is the one place the
    // shape can move, as for a private alias. An alias body that digested the
    // endpoint as `err`, with a closure that never reached the schema, would
    // move nothing when the field is edited, and a warm check of `U` would
    // replay its clean verdict against a shape that no longer exists.

    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("beni.json", manifest);
    try w.write("src/beni.json", manifest);
    const schema_before =
        \\schema Hidden =
        \\    z : Int
        \\
        \\
        \\pub type alias Wrap =
        \\    Hidden.Type
        \\
    ;
    try w.write("src/S.beni", schema_before);
    try w.write("src/U.beni",
        \\import S
        \\
        \\
        \\field : S.Wrap → Int
        \\field r =
        \\    r.z
        \\
    );
    const before = try pairOf(&w, arena, false);
    const cold = try w.runWith(&.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), cold.exit_code);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try w.write("src/S.beni", comptime replace(schema_before, "    z : Int", "    z : String"));
    const after = try pairOf(&w, arena, true);
    const warm = try w.runWith(&.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, .{ .raw_diagnostics = true });
    const fresh = try w.runWith(&.{ "check", "--jobs=1", "--no-cache", "src" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // `S`'s record is unmoved (the schema is private, the alias row has no
    // body); its digest moves, and `U`'s folds it.
    try expectSet("a private schema's field", try movedBetween(arena, before.hashes, after.hashes), nothing);
    try expectSet("a private schema's field", try movedBetween(arena, before.digests, after.digests), &.{ "app:S", "app:U" });
    // The warm run re-checks `U` and says what a cold run says: `r.z` is
    // now a `String` where `field` promises an `Int`.
    try testing.expectEqual(@as(u8, 1), fresh.exit_code);
    try testing.expect(std.mem.indexOf(u8, fresh.stderr, "TYPE MISMATCH") != null);
    try testing.expectEqual(fresh.exit_code, warm.exit_code);
    try testing.expectEqualStrings(fresh.stderr, warm.stderr);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// `haystack` with the first occurrence of `needle` replaced. Comptime, so a
/// row's edit is a literal in the test and a needle that stopped matching is a
/// compile error rather than a row that silently edits nothing.
fn replace(comptime haystack: []const u8, comptime needle: []const u8, comptime with: []const u8) []const u8 {
    const at = comptime (std.mem.indexOf(u8, haystack, needle) orelse
        @compileError("the edit's needle is not in the source: " ++ needle));
    return haystack[0..at] ++ with ++ haystack[at + needle.len ..];
}
