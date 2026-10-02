//! The persistent cache's KEY, black-box (`docs/design/fast-compiler.md` §8's
//! *The persistent cache, and its key*, `plans/m4-1.md` §6.1).
//!
//! **These scenarios land before a byte is ever written to disk**, and that is
//! the point. A cache bug is a wrong answer that depends on history — the
//! worst kind, because it cannot be reproduced from a clean checkout — and the
//! thing that decides whether a module is re-checked is its key and nothing
//! else. So the whole invalidation table is pinned here, against
//! `--cache-keys`, with no cache directory in sight; the counters can then
//! only confirm what this file already fixed.
//!
//! **What each scenario asserts is which keys MOVED**, by name, against a
//! baseline of the same project — never "this key equals these 32 digits",
//! which would be a golden that every unrelated edit to the compiler rewrites.
//! The set is exact: a scenario that expected `{Leaf, Mid}` fails both when
//! `Top` moved and when `Mid` did not.
//!
//! **The project** is `plans/m4-1.md` §6.1's: core, plus `Leaf` (no imports,
//! one `foreign` with a sibling `.js`), `Mid` (imports `Leaf`) and `Top`
//! (imports `Mid`). Its `beni.json` says `"platform": true`, which is what
//! makes `foreign` legal in an app module (`boundary.md` §2) — the alternative
//! was `--core` on every run, which would also change what `equatable` means
//! and put a second variable in every row.

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
    \\import Leaf
    \\
    \\
    \\pub two : Int
    \\two =
    \\    Leaf.one
    \\
;

const top_source =
    \\import Mid
    \\
    \\
    \\pub three : Int
    \\three =
    \\    Mid.two
    \\
;

const manifest =
    \\{ "platform": true, "name": "cachekeys", "program": "P.Program", "runtime": "run.js" }
    \\
;

fn writeProject(w: *World) !void {
    // `"platform": true` is what lets an app module write `foreign`
    // (boundary.md §2); nothing else in the manifest is read by `check`.
    //
    // It is written TWICE, and that is not redundancy: `check` reads the
    // manifest from `--root` when there is one and from `.` when there is
    // not (`check/Command.zig`), so a project with only a root manifest
    // would lose its privilege under `--root=src` and the `--root` row below
    // would be measuring that rather than the key.
    try w.write("beni.json", manifest);
    try w.write("src/beni.json", manifest);
    try w.write("src/Leaf.beni", leaf_source);
    try w.write("src/Leaf.js", leaf_sibling);
    try w.write("src/Mid.beni", mid_source);
    try w.write("src/Top.beni", top_source);
}

// ---------------------------------------------------------------------------
// Reading `--cache-keys`
// ---------------------------------------------------------------------------

const Entry = struct { name: []const u8, digits: []const u8 };

/// Every `<package>:<Module> <32 hex digits>` line, in the order printed —
/// which the flag promises is sorted by the key's text, and which `keysOf`
/// asserts rather than assumes.
fn parseKeys(arena: std.mem.Allocator, out: []const u8) ![]const Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var previous: []const u8 = "";
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse {
            std.debug.print("--cache-keys printed a line with no key: '{s}'\n", .{line});
            return error.MalformedKeyLine;
        };
        const name = line[0..space];
        const digits = line[space + 1 ..];
        if (digits.len != 32) {
            std.debug.print("--cache-keys printed {d} digits for {s}, not 32\n", .{ digits.len, name });
            return error.MalformedKeyLine;
        }
        for (digits) |c| {
            if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.MalformedKeyLine;
        }
        if (!std.mem.lessThan(u8, previous, name)) {
            std.debug.print("--cache-keys is not sorted: '{s}' followed '{s}'\n", .{ name, previous });
            return error.KeysNotSorted;
        }
        previous = name;
        try entries.append(arena, .{ .name = name, .digits = digits });
    }
    if (entries.items.len == 0) return error.NoKeysPrinted;
    return entries.items;
}

/// `beni check --cache-keys <flags> <paths>`, parsed. Exits 0 and says
/// nothing on stderr, because every scenario here compiles.
fn keysOf(w: *World, arena: std.mem.Allocator, extra: []const []const u8) ![]const Entry {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "check", "--cache-keys" });
    try argv.appendSlice(arena, extra);
    const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });
    if (r.exit_code != 0) {
        std.debug.print("check {s} exited {d}:\n{s}\n", .{ argv.items[argv.items.len - 1], r.exit_code, r.stderr });
        return error.CheckFailed;
    }
    return parseKeys(arena, r.stdout);
}

/// The default invocation every scenario compares against.
fn baselineKeys(w: *World, arena: std.mem.Allocator) ![]const Entry {
    return keysOf(w, arena, &.{ "--jobs=1", "src" });
}

fn lookup(entries: []const Entry, name: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.digits;
    }
    return null;
}

/// Exactly `expected` modules' keys differ between `before` and `after`. A
/// module present in one list and not the other counts as moved, so a
/// scenario that adds a file has to name it.
fn expectMoved(
    what: []const u8,
    before: []const Entry,
    after: []const Entry,
    expected: []const []const u8,
) !void {
    var moved: std.ArrayList([]const u8) = .empty;
    defer moved.deinit(testing.allocator);
    for (before) |b| {
        const now = lookup(after, b.name) orelse {
            try moved.append(testing.allocator, b.name);
            continue;
        };
        if (!std.mem.eql(u8, b.digits, now)) try moved.append(testing.allocator, b.name);
    }
    for (after) |a| {
        if (lookup(before, a.name) == null) try moved.append(testing.allocator, a.name);
    }
    std.mem.sort([]const u8, moved.items, {}, lessThanText);

    var want: std.ArrayList([]const u8) = .empty;
    defer want.deinit(testing.allocator);
    try want.appendSlice(testing.allocator, expected);
    std.mem.sort([]const u8, want.items, {}, lessThanText);

    if (!sameNames(moved.items, want.items)) {
        std.debug.print("{s}: keys moved for {{", .{what});
        for (moved.items) |m| std.debug.print(" {s}", .{m});
        std.debug.print(" }}, expected {{", .{});
        for (want.items) |m| std.debug.print(" {s}", .{m});
        std.debug.print(" }}\n", .{});
        return error.WrongKeysMoved;
    }
}

fn lessThanText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sameNames(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// The three app modules, which is what most rows of the table expect.
const all_app = [_][]const u8{ "app:Leaf", "app:Mid", "app:Top" };

// ---------------------------------------------------------------------------
// The shape of the output
// ---------------------------------------------------------------------------

test "--cache-keys prints one sorted line per module, core included" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const keys = try baselineKeys(&w, arena);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The key is `(package, name)` and not the name alone, and core's
    // modules are on the list because `core` is an unconditional input of
    // every module's check with no import edge to say so.
    try testing.expect(lookup(keys, "app:Leaf") != null);
    try testing.expect(lookup(keys, "app:Mid") != null);
    try testing.expect(lookup(keys, "app:Top") != null);
    try testing.expect(lookup(keys, "core:Basics") != null);
    try testing.expect(lookup(keys, "core:String") != null);
    try testing.expect(keys.len >= 11); // the app's three, and the eight core modules every check keeps

    // No two modules share a key. A recipe that dropped the module name
    // would give every module of one project the same one, and every
    // scenario below would still pass.
    for (keys, 0..) |a, i| {
        for (keys[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.digits, b.digits)) {
                std.debug.print("{s} and {s} share a key\n", .{ a.name, b.name });
                return error.KeysCollided;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The key is a pure function of its inputs
// ---------------------------------------------------------------------------

test "a key does not depend on --jobs, on argv order, or on the cwd it was run from" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The fixture that fails first if anything session-relative reaches the
    // recipe. A `Graph.Index` depends on which files were named; a `Symbol`
    // depends on which worker interned which file; a PATH depends on the
    // directory the compiler was run from. None of the three may be in a
    // key, or a cache would miss on a build that is identical in every way
    // that matters — and, worse, every table below would pass for the wrong
    // reason.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
    const base = try baselineKeys(&w, arena);
    try expectMoved("--jobs=8", base, try keysOf(&w, arena, &.{ "--jobs=8", "src" }), &.{});
    try expectMoved("--jobs=3", base, try keysOf(&w, arena, &.{ "--jobs=3", "src" }), &.{});
    try expectMoved(
        "argv order",
        base,
        try keysOf(&w, arena, &.{ "--diagnostics=text", "--jobs=1", "src" }),
        &.{},
    );
    // A rendering flag is not in the key, by name: `fast-compiler.md` §8
    // lists each and says why.
    try expectMoved("--diagnostics=json", base, try keysOf(&w, arena, &.{ "--jobs=1", "--diagnostics=json", "src" }), &.{});
    try expectMoved("--explain", base, try keysOf(&w, arena, &.{ "--jobs=1", "--explain", "src" }), &.{});
    // `--iface-hash` is a rendering flag too, but it prints a SECOND sorted
    // block on the same stream, so it cannot be compared in this shape; the
    // rows above it that read `ifaceHashes` run it on its own.
    try expectMoved(
        "--roundtrip-interfaces",
        base,
        try keysOf(&w, arena, &.{ "--jobs=1", "--roundtrip-interfaces", "src" }),
        &.{},
    );

    // `--root` reaches the key through the MODULE NAME and nowhere else, so
    // naming the same root explicitly cannot move a key.
    try expectMoved("--root=src", base, try keysOf(&w, arena, &.{ "--jobs=1", "--root=src", "src" }), &.{});

    // **The same tree, spelled every way a person spells it.** Every path
    // is normalised lexically at enumeration, so `.` is a directory like
    // any other and `src`, `./src`, `src/` and `$PWD/src` are one project —
    // which makes this the strong form of the claim. A key carries the DOTTED MODULE NAME and never a path,
    // so if any spelling reached the recipe, this is the row that says so.
    {
        const absolute = try w.projectSubPath(arena, "src");
        for ([_][]const u8{ "./src", "src/", "./src/" }) |spelling| {
            const keys = try keysOf(&w, arena, &.{ "--jobs=1", spelling });
            expectMoved(spelling, base, keys, &.{}) catch |err| {
                std.debug.print("the spelling '{s}' moved a key\n", .{spelling});
                return err;
            };
        }
        try expectMoved("an absolute path", base, try keysOf(&w, arena, &.{ "--jobs=1", absolute }), &.{});
        // …and with `--root` named explicitly in the same spelling, which is
        // the form a build script writes.
        const root_flag = try std.fmt.allocPrint(arena, "--root={s}", .{absolute});
        try expectMoved(
            "an absolute --root and path",
            base,
            try keysOf(&w, arena, &.{ "--jobs=1", root_flag, absolute }),
            &.{},
        );
    }
}

// ---------------------------------------------------------------------------
// The edit-scenario table (`plans/m4-1.md` §6.1)
// ---------------------------------------------------------------------------

test "nothing changed moves no key" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    // Rewritten with identical bytes: a key that moved here would be a key
    // that read an mtime, which is the documented cause of Elm's cache
    // desync bugs (`fast-compiler.md` §8.1).
    try w.write("src/Leaf.beni", leaf_source);
    try expectMoved("a rewrite with identical bytes", base, try baselineKeys(&w, arena), &.{});
}

test "a comment in Leaf moves LEAF ALONE — the cutoff" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // **The cutoff.** Were an importer's key to carry its import's KEY, a
    // comment would move all three keys. It moves one: an import
    // contributes its `(interface hash, dependency digest)` pair, and a
    // comment moves neither (`fast-compiler.md` §8).
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const base = try baselineKeys(&w, arena);
    const iface_before = try ifaceHashes(&w, arena);
    try w.write("src/Leaf.beni", "-- a comment nobody reads\n" ++ leaf_source);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectMoved("a comment in Leaf", base, try baselineKeys(&w, arena), &.{"app:Leaf"});
    // …and the interface hash did not move at all, which is why `Mid` and
    // `Top` are spared.
    try expectMoved("a comment in Leaf, by interface hash", iface_before, try ifaceHashes(&w, arena), &.{});
}

test "the body of an annotated pub in Leaf moves Leaf, Mid and Top" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    const iface_before = try ifaceHashes(&w, arena);
    try w.write("src/Leaf.beni",
        \\pub foreign pure twice : Int → Int
        \\
        \\
        \\pub one : Int
        \\one =
        \\    2
        \\
    );

    // The cutoff: an ANNOTATED body is invisible to a dependent, so neither
    // the record nor the digest moves and the leaf re-checks alone.
    try expectMoved("an annotated body in Leaf", base, try baselineKeys(&w, arena), &.{"app:Leaf"});
    // Report 19 §4: every annotated row measures 0 interface changes,
    // because an annotation is exactly what a dependent sees.
    try expectMoved("an annotated body, by interface hash", iface_before, try ifaceHashes(&w, arena), &.{});
}

test "a pub signature in Leaf moves Leaf, Mid and Top, and its interface too" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    const iface_before = try ifaceHashes(&w, arena);
    try w.write("src/Leaf.beni",
        \\pub foreign pure twice : Int → Int
        \\
        \\
        \\pub one : Float
        \\one =
        \\    1.0
        \\
    );
    try w.write("src/Mid.beni",
        \\import Leaf
        \\
        \\
        \\pub two : Float
        \\two =
        \\    Leaf.one
        \\
    );
    try w.write("src/Top.beni",
        \\import Mid
        \\
        \\
        \\pub three : Float
        \\three =
        \\    Mid.two
        \\
    );

    try expectMoved("a pub signature in Leaf", base, try baselineKeys(&w, arena), &all_app);
    // Unlike rows 2 and 3, the record moved too — which is the converse
    // assertion without which "the interface did not move" proves nothing.
    try expectMoved(
        "a pub signature, by interface hash",
        iface_before,
        try ifaceHashes(&w, arena),
        &all_app,
    );
}

test "a PRIVATE type added to Leaf moves Leaf, Mid and Top but no interface" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // **The interesting one** (`plans/m4-1.md` §6.1). The cutoff would let
    // `Mid` hit here only once the declared-type sidecar of
    // `plans/m4-slice-zero.md` §4 is defined and its hash is in `Mid`'s key:
    // `Mid`'s check reads `Leaf`'s settled `equatable`/`comparable` bits and
    // its `declaresPubCompare`, none of which is in the record. So the key
    // moves, and this fixture makes any change to that visible rather than
    // assumed.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    const iface_before = try ifaceHashes(&w, arena);
    try w.write("src/Leaf.beni", leaf_source ++
        \\
        \\
        \\type Hidden
        \\    = Hidden Int
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // `plans/m4-1.md` §6.1's private-type row, kept through the cutoff: a `TypeId` is a
    // whole-program dense index and adding a private type renumbers most of
    // the table, and nothing a dependent emits or reports carries one — so
    // the digest, which is keyed by NAME over the set the record names, does
    // not move either and the leaf re-checks alone.
    try expectMoved("a private type in Leaf", base, try baselineKeys(&w, arena), &.{"app:Leaf"});
    // Slice zero §11.3's E4 row, restated: a private type moves no interface
    // hash at all, not even the edited module's own.
    try expectMoved("a private type, by interface hash", iface_before, try ifaceHashes(&w, arena), &.{});
}

test "a new unrelated file moves nothing that already existed" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The row the `TypeId` leak of `plans/m4-plan.md` §2.2 would have failed:
    // a whole-program index in a hashed structure moves every module that
    // sorts after whatever was added.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    // Sorting BEFORE every existing module, and declaring a type, so that
    // anything order-dependent has every chance to show.
    try w.write("src/Aardvark.beni",
        \\pub type Zeta
        \\    = Zeta Int
        \\
        \\
        \\pub zero : Int
        \\zero =
        \\    0
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectMoved("a new unrelated file", base, try baselineKeys(&w, arena), &.{"app:Aardvark"});
}

test "Leaf's sibling .js moves Leaf, Mid and Top, and no interface" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `boundary.md` §7.3: the sibling's content hash is a term of the key,
    // an input hash exactly like the source bytes. It can move no record —
    // foreignness is one bit derived from the `.beni` source and no byte of
    // the JavaScript is in the interface — so this is the one edit that
    // moves a key with nothing whatever to show in the record.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    const iface_before = try ifaceHashes(&w, arena);
    try w.write("src/Leaf.js",
        \\export const twice = (n) => n + n;
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The sibling is in the leaf's own terms and in nothing a dependent can
    // observe, so the cutoff spares the importers.
    try expectMoved("Leaf's sibling .js", base, try baselineKeys(&w, arena), &.{"app:Leaf"});
    try expectMoved("Leaf's sibling .js, by interface hash", iface_before, try ifaceHashes(&w, arena), &.{});
}

test "a sibling .js beside a module with no foreign is not in any key" {
    // The converse of the sibling scenario above, and the fixture that would catch a key hashing
    // every neighbouring `.js` rather than the sibling of a module that
    // actually declares a `foreign`. `Emit.checkSiblings` reads a sibling
    // only for a module with a `foreign_value`, and the key has to agree:
    // otherwise a build would invalidate on a file it never reads.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    try w.write("src/Mid.js", "export const nothing = 1;\n");
    try expectMoved("a sibling beside a module with no foreign", base, try baselineKeys(&w, arena), &.{});
}

test "--platform adds the platform's modules and moves no existing key" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `--platform` is deliberately NOT in the option string: what it changes
    // is what an import resolves to, which the import terms already carry
    // (`fast-compiler.md` §8). No module of this project imports the
    // platform, so core and every app module must hold — and only the
    // platform's own modules appear.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    const with = try keysOf(&w, arena, &.{ "--jobs=1", "--platform=node", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Every key that existed before is unchanged; what is new is the
    // platform's, which the comparison reports as "moved" because it was not
    // there before.
    for (base) |b| {
        const now = lookup(with, b.name) orelse {
            std.debug.print("--platform lost {s}\n", .{b.name});
            return error.ModuleVanished;
        };
        try testing.expectEqualStrings(b.digits, now);
    }
    try testing.expect(with.len > base.len);
    var saw_platform = false;
    for (with) |e| {
        if (std.mem.startsWith(u8, e.name, "platform:")) saw_platform = true;
    }
    try testing.expect(saw_platform);
}

test "--pattern-budget moves every module's key" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // It is in the option string because its exhaustion is an ERROR of the
    // module (`checker.md` §6.6) and because the message the checker renders
    // quotes the budget — so an entry written at one budget would replay the
    // wrong prose at another. That is the one checker diagnostic whose text
    // is invocation-dependent, and this is the term that covers it.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    const changed = try keysOf(&w, arena, &.{ "--jobs=1", "--pattern-budget=12345", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectEveryKeyMoved("--pattern-budget", base, changed);
}

test "--cache-build-id moves every module's key, core included" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // "A compiler change discards the whole cache", written as a fixture
    // rather than as a second compiler (`fast-compiler.md` §8).
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    const pretend = try keysOf(&w, arena, &.{ "--jobs=1", "--cache-build-id=a-different-compiler", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectEveryKeyMoved("--cache-build-id", base, pretend);
    // And it is a function of the string, not a switch: two different
    // substitutes disagree, and the same one twice agrees.
    const other = try keysOf(&w, arena, &.{ "--jobs=1", "--cache-build-id=another-one-again", "src" });
    try expectEveryKeyMoved("a second --cache-build-id", pretend, other);
    const again = try keysOf(&w, arena, &.{ "--jobs=1", "--cache-build-id=a-different-compiler", "src" });
    try expectMoved("the same --cache-build-id twice", pretend, again, &.{});
}

test "--checker is not an option, so it is refused and moves no key" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // There is one checker, so there is no checker id in the compiler
    // identity every key starts with (key version 5): `--checker` is an
    // ordinary unknown option, refused before anything is read or written,
    // and there is one key per module.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const base = try baselineKeys(&w, arena);
    const again = try baselineKeys(&w, arena);
    const r = try w.runWith(&.{ "check", "--cache-keys", "--jobs=1", "--cache-dir=c", "--checker=v1", "src" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectMoved("the default twice", base, again, &.{});
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualStrings("beni: unknown option '--checker'; run 'beni help' for usage\n", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("c"));
}

test "--core moves the app modules' keys and leaves core's alone" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The option string's two permission bits are `Lower.Options`', which are
    // asked PER FILE (`cache/Key.zig`'s `OptionBits`). `--core` makes an app
    // module core for lowering's purposes and changes nothing about a core
    // module, which is core either way — so a per-run option string would
    // invalidate core's entries for every fixture that passes the flag, and
    // a per-module one does not.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    const cored = try keysOf(&w, arena, &.{ "--jobs=1", "--core", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectMoved("--core", base, cored, &all_app);
}

/// Every module in both lists moved. Used for the two rows whose answer is
/// "all of them, core included" — spelling out core's nine module names in
/// the fixture would make it break whenever core gains a module, which is
/// the golden-rot `plans/m4-slice-zero.md` §11.4 warns about.
fn expectEveryKeyMoved(what: []const u8, before: []const Entry, after: []const Entry) !void {
    try testing.expectEqual(before.len, after.len);
    var saw_core = false;
    for (before) |b| {
        const now = lookup(after, b.name) orelse {
            std.debug.print("{s}: {s} vanished\n", .{ what, b.name });
            return error.ModuleVanished;
        };
        if (std.mem.eql(u8, b.digits, now)) {
            std.debug.print("{s}: {s}'s key did not move\n", .{ what, b.name });
            return error.KeyDidNotMove;
        }
        if (std.mem.startsWith(u8, b.name, "core:")) saw_core = true;
    }
    // A row that claimed "every module, core included" over a list with no
    // core module in it would prove nothing.
    try testing.expect(saw_core);
}

// ---------------------------------------------------------------------------
// The DEFAULT (`plans/m4-3.md` §10.3 item 30, §12)
// ---------------------------------------------------------------------------

test "with no flag the cache is on, in .beni-cache beside the invocation" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // **The flip, and it is one line in `Dir.fromCli`.** What has to be true
    // is that the default changes how FAST a build is and nothing else: the
    // second run must say exactly what a `--no-cache` run says, and it must
    // have hit.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const oracle = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--no-cache", "src" }, "oracle.json");
    const first = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "first.json");
    const second = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "second.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(oracle.result.exit_code, second.result.exit_code);
    try testing.expectEqualStrings(oracle.result.stdout, second.result.stdout);
    try testing.expectEqualStrings(oracle.result.stderr, second.result.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(w.exists(".beni-cache"));
    try testing.expectEqual(@as(u64, 0), first.counters.hits);
    try testing.expect(second.counters.hits > 0);
    try testing.expectEqual(@as(u64, 0), second.counters.checked);
    // And the entries are under the same `v<n>/<kk>/` fan-out a named
    // directory uses: the default changes WHERE, never WHAT.
    const files = try w.listFiles(".beni-cache");
    try testing.expect(files.len > 0);
    for (files) |f| try testing.expect(std.mem.startsWith(u8, f, "v1/"));
}

test "--no-cache leaves no directory at all, which is what makes it the oracle" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const r = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--no-cache", "src" }, "r.json");
    try testing.expectEqual(@as(u8, 0), r.result.exit_code);
    try testing.expect(!w.exists(".beni-cache"));
    try testing.expectEqual(@as(u64, 0), r.counters.bytes);
    try testing.expectEqual(@as(u64, 0), r.counters.frontend_bytes);

    // `--no-cache` wins over an explicit `--cache-dir` too, and writes
    // nothing there either.
    const both = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--no-cache", "--cache-dir=cache", "src" }, "both.json");
    try testing.expectEqual(@as(u8, 0), both.result.exit_code);
    try testing.expect(!w.exists("cache"));
}

test "a working directory it cannot write degrades SILENTLY to no cache" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // **The difference between the default and `--cache-dir`, and the whole
    // reason they are not one code path.** A person who NAMES a directory
    // meant it, and a typo that silently produced slow builds would be worse
    // than an error — so that is exit 2 with the path. A person who named
    // nothing asked implicitly, and a read-only checkout, a sandbox or a full
    // disk must not fail their build.
    //
    // And silently: stderr is byte-compared across the whole corpus
    // (`fast-compiler.md` §10), so even a one-line note would be a diagnostic
    // in every golden.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    // The oracle is run the same way the subject is — from `ro/`, with
    // `--root` naming the source directory so the manifest that grants
    // `foreign` is still found — so the only difference between the two runs
    // is the cache.
    try w.createDir("ro");
    const root = try w.projectSubPath(arena, "src");
    const from_ro = try w.projectSubPath(arena, "ro");
    const oracle = try w.runWith(&.{
        "check", "--jobs=1", "--no-cache", try std.fmt.allocPrint(arena, "--root={s}", .{root}), root,
    }, .{ .raw_diagnostics = true, .cwd = .{ .path = from_ro } });
    try testing.expectEqual(@as(u8, 0), oracle.exit_code);

    // `makeDirUnwritable` returns false when the test runs as a user the mode
    // cannot stop (root in a container).
    try w.write("ro/keep", "");
    if (!try w.makeDirUnwritable("ro")) return error.SkipZigTest;
    defer w.restoreDirMode("ro");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{
        "check", "--jobs=1", try std.fmt.allocPrint(arena, "--root={s}", .{root}), root,
    }, .{ .raw_diagnostics = true, .cwd = .{ .path = from_ro } });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(oracle.exit_code, r.exit_code);
    try testing.expectEqualStrings(oracle.stdout, r.stdout);
    try testing.expectEqualStrings(oracle.stderr, r.stderr);
    try testing.expectEqualStrings("", r.stderr);
    // And nothing was created in the directory it could not write.
    try testing.expect(!w.exists("ro/.beni-cache"));
}

test "a NAMED cache directory that cannot be created is still exit 2 with the path" {
    // The other half of the row above: the default degrades, the flag does
    // not. Without this the two would be indistinguishable and the flip would
    // have quietly removed a usage error.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    // A regular FILE cannot be opened as a directory.
    try w.write("notadir", "x");
    const r = try w.runWith(&.{ "check", "--jobs=1", "--cache-dir=notadir", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "notadir") != null);
}

test "fmt and dump make no cache, and two projects in one directory share it safely" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // `fmt` and `dump` take no cache flag at all (`frontend.md` §1), and the
    // flip must not have given them one by the back door: neither reads an
    // interface, so neither has anything a cache could hold.
    _ = try w.runWith(&.{ "fmt", "--check", "src" }, .{ .raw_diagnostics = true });
    try testing.expect(!w.exists(".beni-cache"));
    _ = try w.runWith(&.{ "dump", "--stage=bir", "src/Leaf.beni" }, .{ .raw_diagnostics = true });
    try testing.expect(!w.exists(".beni-cache"));

    // Two projects checked from ONE working directory share one `.beni-cache`
    // and do not fight: the key holds no path, so their entries are named by
    // content and simply coexist. `plans/m4-3.md` §12 calls the duplication
    // "correct, duplicated, and the cheap failure".
    try w.write("other/beni.json", manifest);
    try w.write("other/Solo.beni", "pub solo : Int\nsolo =\n    5\n");
    const a1 = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "a1.json");
    const b1 = try runCounted(&w, arena, &.{ "check", "--jobs=1", "other" }, "b1.json");
    const a2 = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "a2.json");
    const b2 = try runCounted(&w, arena, &.{ "check", "--jobs=1", "other" }, "b2.json");
    try testing.expectEqual(@as(u8, 0), a1.result.exit_code);
    try testing.expectEqual(@as(u8, 0), b1.result.exit_code);
    // Each hits on its second run although the other ran in between, which is
    // what "content-addressed" buys.
    try testing.expectEqual(@as(u64, 0), a2.counters.checked);
    try testing.expectEqual(@as(u64, 0), b2.counters.checked);
}

// ---------------------------------------------------------------------------
// The cache as an environment (`plans/m4-1.md` §6.2, §6.3)
// ---------------------------------------------------------------------------

/// The counters `--self-profile` writes, by name. A cache that is doing
/// nothing says so here and nowhere else (`frontend.md` §1), so every
/// scenario below reads them rather than inferring from a wall clock.
const Counters = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    checked: u64 = 0,
    bytes: u64 = 0,
    /// The front end's three (`fast-compiler.md` §8): a phase that did not run is
    /// otherwise indistinguishable from a phase that ran fast.
    lexed: u64 = 0,
    parsed: u64 = 0,
    lowered: u64 = 0,
    files: u64 = 0,
    frontend_hits: u64 = 0,
    frontend_bytes: u64 = 0,
    /// The checker's derived-context fixpoints (`derived_context_runs`):
    /// 0 when every module was installed from the cache, which is the
    /// witness that a cache hit installs the published answer.
    derived: u64 = 0,
    /// The checked core the binary carries (`fast-compiler.md` §8, *The
    /// checked core, embedded*): core files and modules installed from it,
    /// which a cache directory neither reads nor writes.
    embedded_files: u64 = 0,
    embedded_modules: u64 = 0,
    /// Modules in the graph.
    modules: u64 = 0,
};

const Run = struct {
    result: world.Result,
    counters: Counters,
};

/// `beni <args> --self-profile=<trace>`, with the cache counters read back.
fn runCounted(w: *World, arena: std.mem.Allocator, args: []const []const u8, trace: []const u8) !Run {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, args);
    try argv.append(arena, try std.fmt.allocPrint(arena, "--self-profile={s}", .{trace}));
    const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });

    const Event = struct {
        ph: []const u8,
        name: []const u8 = "",
        args: struct {
            cache_hits: ?u64 = null,
            cache_misses: ?u64 = null,
            modules_checked: ?u64 = null,
            cache_bytes: ?u64 = null,
            files_lexed: ?u64 = null,
            files_parsed: ?u64 = null,
            files_lowered: ?u64 = null,
            files: ?u64 = null,
            frontend_hits: ?u64 = null,
            frontend_bytes: ?u64 = null,
            derived_context_runs: ?u64 = null,
            embedded_files: ?u64 = null,
            embedded_modules: ?u64 = null,
            modules: ?u64 = null,
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
        if (e.args.cache_bytes) |v| counters.bytes = v;
        if (e.args.files_lexed) |v| counters.lexed = v;
        if (e.args.files_parsed) |v| counters.parsed = v;
        if (e.args.files_lowered) |v| counters.lowered = v;
        if (e.args.files) |v| counters.files = v;
        if (e.args.frontend_hits) |v| counters.frontend_hits = v;
        if (e.args.frontend_bytes) |v| counters.frontend_bytes = v;
        if (e.args.derived_context_runs) |v| counters.derived = v;
        if (e.args.embedded_files) |v| counters.embedded_files = v;
        if (e.args.embedded_modules) |v| counters.embedded_modules = v;
        if (e.args.modules) |v| counters.modules = v;
    }
    return .{ .result = r, .counters = counters };
}

test "a cold run with --cache-dir writes entries and does not move one byte of output" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The claim the whole slice rests on, at its weakest point: a cache
    // changes nothing about what a run SAYS. Until the read path lands, the
    // only thing a cache directory can do is make output differ, so this is
    // the assertion that has to hold first.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // `--no-cache` is what "plain" means: with no flag at all the
    // cache is ON, in `.beni-cache/` beside the invocation, so a run meant as
    // the ORACLE has to say so. A `--no-cache` run that wrote anything would
    // stop being one.
    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--no-cache", "src" }, "plain.json");
    const cached = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "cached.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(plain.result.exit_code, cached.result.exit_code);
    try testing.expectEqualStrings(plain.result.stdout, cached.result.stdout);
    try testing.expectEqualStrings(plain.result.stderr, cached.result.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A cold run hits nothing, checks every module of the project, and
    // writes an entry for each of the app's three. The core modules it
    // reaches come from the checked core the binary carries
    // (`fast-compiler.md` §8, *The checked core, embedded*), with or without
    // a cache directory, and the directory is never asked about them.
    try testing.expectEqual(@as(u64, 0), cached.counters.hits);
    try testing.expectEqual(@as(u64, 0), plain.counters.hits);
    try testing.expectEqual(@as(u64, 3), cached.counters.misses);
    try testing.expect(cached.counters.embedded_modules >= 8);
    try testing.expectEqual(cached.counters.embedded_modules, plain.counters.embedded_modules);
    try testing.expectEqual(cached.counters.misses, plain.counters.misses);
    try testing.expectEqual(cached.counters.checked, plain.counters.checked);
    try testing.expect(cached.counters.bytes > 0);
    // A `--no-cache` run writes nothing, whatever it counted — and it leaves
    // no directory behind either, which is what keeps it the oracle every
    // other row compares against.
    try testing.expectEqual(@as(u64, 0), plain.counters.bytes);
    try testing.expect(!w.exists(".beni-cache"));

    const files = try entriesOnly(arena, try w.listFiles("cache"));
    try testing.expectEqual(@as(usize, @intCast(cached.counters.misses)), files.len);
    for (files) |f| {
        // `v<n>/<kk>/<rest>.bec`, two levels of fan-out over the key's hex.
        try testing.expect(std.mem.startsWith(u8, f, "v1/"));
        try testing.expect(std.mem.endsWith(u8, f, ".bec"));
        try testing.expectEqual(@as(usize, "v1/".len + 2 + 1 + 30 + ".bec".len), f.len);
    }
    // The front-end artifacts share the directory and the fan-out under a
    // SECOND key: one `.bef` per FILE, beside one `.bec` per module.
    const artifacts = try artifactsOnly(arena, try w.listFiles("cache"));
    try testing.expect(artifacts.len > 0);
    for (artifacts) |f| {
        try testing.expect(std.mem.startsWith(u8, f, "v1/"));
        try testing.expectEqual(@as(usize, "v1/".len + 2 + 1 + 30 + ".bef".len), f.len);
    }

    // Running again writes the same files and no more: the name is the key,
    // so a second cold run overwrites rather than accumulating.
    _ = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "again.json");
    const again = try w.listFiles("cache");
    try testing.expectEqual(files.len + artifacts.len, again.len);
}

test "a cold run lexes, parses and lowers every file and writes one artifact for each" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The floor the warm assertion is measured against: a
    // COLD run does all the work, and the three counters say so. Without
    // them "the front end did not run" on a warm run would be a timing
    // rather than a fact (`fast-compiler.md` §8, `frontend.md` §6).
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--no-cache", "src" }, "plain.json");
    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "cold.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(plain.result.exit_code, cold.result.exit_code);
    try testing.expectEqualStrings(plain.result.stderr, cold.result.stderr);
    try testing.expectEqualStrings(plain.result.stdout, cold.result.stdout);

    // Every file, on both runs, but the core files the checked core the
    // binary carries already holds (`fast-compiler.md` §8, *The checked
    // core, embedded*): a cache directory does not change what the front end
    // does on a cold run, it only makes it write.
    for ([_]Run{ plain, cold }) |run| {
        try testing.expect(run.counters.files > 0);
        try testing.expect(run.counters.embedded_files > 0);
        const project = run.counters.files - run.counters.embedded_files;
        try testing.expectEqual(project, run.counters.lexed);
        try testing.expectEqual(project, run.counters.parsed);
        try testing.expectEqual(project, run.counters.lowered);
    }
    // A run with no cache directory writes no artifact, whatever it lowered.
    try testing.expectEqual(@as(u64, 0), plain.counters.frontend_bytes);
    try testing.expect(cold.counters.frontend_bytes > 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // One `.bef` per file the run lowered — none for a core file the
    // checked core held, which the directory is never asked about.
    const artifacts = try artifactsOnly(arena, try w.listFiles("cache"));
    try testing.expectEqual(@as(usize, @intCast(cold.counters.lowered)), artifacts.len);
}

test "a file whose front end failed is never written, and its neighbours are" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The module entry's "produced by a clean check" bit, one phase earlier and for the
    // same reason: a file that did not parse has a `Bir` the recovery
    // invented, and a later run that installed it would report the
    // recovery's guesses as facts.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    try w.write("src/Broken.beni", "pub x = = =\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "broken.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.result.exit_code);
    const artifacts = try artifactsOnly(arena, try w.listFiles("cache"));
    // Every file the run lowered but the broken one (a core file the
    // checked core held was not lowered, and is never written). The count
    // is the assertion: naming the absent key would need the file key of a
    // file that does not compile, and `--frontend-keys` prints those too —
    // so both halves are checked.
    try testing.expectEqual(@as(usize, @intCast(r.counters.lowered - 1)), artifacts.len);

    const keys = try fileKeysOfAllowingErrors(&w, arena);
    const broken_digits = lookup(keys, "src/Broken.beni").?;
    var broken_name: [40]u8 = undefined;
    const broken_path = artifactPathFor(&broken_name, broken_digits);
    for (artifacts) |f| {
        if (std.mem.eql(u8, f, broken_path)) {
            std.debug.print("a front-end artifact exists for the file that did not parse\n", .{});
            return error.UnexpectedEntry;
        }
    }
    // …and the file beside it was written, so this is not "nothing was".
    const leaf_digits = lookup(keys, leaf_file).?;
    var leaf_name: [40]u8 = undefined;
    const leaf_path = artifactPathFor(&leaf_name, leaf_digits);
    var found = false;
    for (artifacts) |f| {
        if (std.mem.eql(u8, f, leaf_path)) found = true;
    }
    if (!found) {
        std.debug.print("no front-end artifact for {s}\n", .{leaf_file});
        return error.MissingEntry;
    }

    // After the fix, it is written like any other.
    try w.write("src/Broken.beni", "pub x : Int\nx =\n    1\n");
    const fixed = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "fixed.json");
    try testing.expectEqual(@as(u8, 0), fixed.result.exit_code);
    const after = try artifactsOnly(arena, try w.listFiles("cache"));
    try testing.expectEqual(@as(usize, @intCast(fixed.counters.files - fixed.counters.embedded_files)), after.len);
}

test "a warm run lexes, parses and lowers NOTHING and says exactly the same thing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The whole slice, in one row. Byte equality alone would not say it: a
    // front end that ran and produced the same answer is indistinguishable
    // from one that did not run, except in the counters
    // (`fast-compiler.md` §8, `frontend.md` §6).
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--no-cache", "src" }, "plain.json");
    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "cold.json");
    const warm = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "warm.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(plain.result.exit_code, warm.result.exit_code);
    try testing.expectEqualStrings(plain.result.stderr, warm.result.stderr);
    try testing.expectEqualStrings(plain.result.stdout, warm.result.stdout);

    try testing.expectEqual(@as(u64, 0), warm.counters.lexed);
    try testing.expectEqual(@as(u64, 0), warm.counters.parsed);
    try testing.expectEqual(@as(u64, 0), warm.counters.lowered);
    try testing.expectEqual(warm.counters.files, cold.counters.files);
    // Every file hit — the project's in the directory, core's in the
    // checked core the binary carries — and nothing written a second time:
    // the name is the key, so there is nothing to rewrite.
    try testing.expectEqual(warm.counters.files, warm.counters.frontend_hits + warm.counters.embedded_files);
    try testing.expectEqual(@as(u64, 0), warm.counters.frontend_bytes);
    // …and the modules were not re-checked either, which is the module
    // cache still holding with a loaded `Bir` under it.
    try testing.expectEqual(@as(u64, 0), warm.counters.checked);

    // A cache written at one worker count and read at another is what would
    // catch a `Symbol` reaching the bytes.
    const crossed = try runCounted(&w, arena, &.{ "check", "--jobs=8", "--cache-dir=cache", "src" }, "crossed.json");
    try testing.expectEqualStrings(plain.result.stderr, crossed.result.stderr);
    try testing.expectEqual(@as(u64, 0), crossed.counters.lowered);
}

test "a body edit re-lowers ONLY the leaf while its importers re-check" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // **Why a file key exists.** A module key folds every import's key, so
    // `Mid` and `Top` are re-CHECKED; a file key does not, so their front
    // ends are not re-run. `files_lowered = 1` is the whole claim, and the
    // module counters beside it are what say the two invalidations really
    // are different.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    _ = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "cold.json");
    try w.write(leaf_file,
        \\pub foreign pure twice : Int → Int
        \\
        \\
        \\pub one : Int
        \\one =
        \\    2
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const edited = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "edited.json");
    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--no-cache", "src" }, "plain.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), edited.result.exit_code);
    try testing.expectEqualStrings(plain.result.stderr, edited.result.stderr);

    // ONE file re-lexed, re-parsed and re-lowered: the leaf.
    try testing.expectEqual(@as(u64, 1), edited.counters.lexed);
    try testing.expectEqual(@as(u64, 1), edited.counters.parsed);
    try testing.expectEqual(@as(u64, 1), edited.counters.lowered);
    try testing.expectEqual(edited.counters.files - 1, edited.counters.frontend_hits + edited.counters.embedded_files);
    // ONE module re-checked — the leaf alone. Were the module key to fold
    // its imports' KEYS it would be 3, since a body edit moves the leaf's;
    // it folds their `(interface hash, dependency digest)` pairs, and an
    // ANNOTATED body edit moves neither.
    // The counters are what make "the two invalidations are different" a
    // fact: one file re-lowered, one module re-checked, and the importers
    // touched by neither.
    try testing.expectEqual(@as(u64, 1), edited.counters.checked);

    // And the run after it is fully warm again, which is what says the edited
    // file's artifact was written rather than merely not read.
    const settled = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "settled.json");
    try testing.expectEqual(@as(u64, 0), settled.counters.lowered);
    try testing.expectEqual(@as(u64, 0), settled.counters.checked);
}

// ---------------------------------------------------------------------------
// A schema across the interface firewall
// ---------------------------------------------------------------------------

/// `Models` with a private conversion whose body is `body`, a record schema
/// `User` with the field `field` through it, and a public parametric schema
/// `Page` whose parameter is `param`.
fn schemaModels(comptime body: []const u8, comptime field: []const u8, comptime param: []const u8) []const u8 {
    return "import Schema exposing (Conversion)\n\n\nconversion : Conversion Int String\nconversion =\n    Debug.todo \"" ++
        body ++ "\"\n\n\npub schema User =\n    " ++ field ++ " : Int via conversion\n\n\npub schema Page " ++
        param ++ " =\n    value : " ++ param ++ "\n";
}

const schema_consumer =
    \\import Models
    \\
    \\
    \\pub keep : Models.User.Type → Models.User.Type
    \\keep value =
    \\    value
    \\
;

/// `before` checked cold into a cache; then `after` checked warm over it and
/// cold with `--no-cache`. The two agree on every stream, the warm run
/// re-checked `checked` modules, and `Models`'s interface hash moved exactly
/// when `hash_moves`, and no hash moved when it does not.
fn expectSchemaEdit(before: []const u8, after: []const u8, checked: u64, hash_moves: bool) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Models.beni", before);
    try w.write("src/Consumer.beni", schema_consumer);
    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--iface-hash", "--cache-dir=cache", "src" }, "schema-cold.json");
    try testing.expectEqual(@as(u8, 0), cold.result.exit_code);
    const hashes_before = try parseKeys(arena, cold.result.stdout);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try w.write("src/Models.beni", after);
    const warm = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--iface-hash", "--cache-dir=cache", "src" }, "schema-warm.json");
    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--iface-hash", "--no-cache", "src" }, "schema-plain.json");
    const hashes_after = try parseKeys(arena, warm.result.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    try testing.expectEqual(plain.result.exit_code, warm.result.exit_code);
    try testing.expectEqualStrings(plain.result.stdout, warm.result.stdout);
    try testing.expectEqualStrings(plain.result.stderr, warm.result.stderr);
    try testing.expectEqual(checked, warm.counters.checked);
    if (hash_moves) {
        try testing.expect(!std.mem.eql(u8, lookup(hashes_before, "app:Models").?, lookup(hashes_after, "app:Models").?));
    } else {
        try expectMoved("a schema edit", hashes_before, hashes_after, &.{});
    }
}

// ---------------------------------------------------------------------------
// An effect bit across the interface firewall
// ---------------------------------------------------------------------------

test "a body edit that flips an effect bit crosses the firewall, and the warm importer reads the new bit" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // An ANNOTATED body edit moves no type, so without effects `Lib`'s record
    // would stay put and `App` would be a hit (the leaf scenario above). A
    // log added to `step`'s body flips its `impure` bit, which the record's
    // effect block carries (transparent-effects-proposal.md §14.6): `Lib`'s
    // interface hash moves, `App` is re-checked, and `App`'s own hash moves
    // with the bit it now inherits. The warm run must say exactly what a
    // cold one says, hashes included, or a cached importer kept a stale bit.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Lib.beni",
        \\pub step : Int → Int
        \\step n =
        \\    n + 1
        \\
    );
    try w.write("src/App.beni",
        \\import Lib
        \\
        \\
        \\pub run : Int → Int
        \\run n =
        \\    Lib.step (Lib.step n)
        \\
    );
    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--iface-hash", "--cache-dir=cache", "src" }, "bit-cold.json");
    try testing.expectEqual(@as(u8, 0), cold.result.exit_code);
    const hashes_before = try parseKeys(arena, cold.result.stdout);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try w.write("src/Lib.beni",
        \\pub step : Int → Int
        \\step n =
        \\    Debug.log "step" (n + 1)
        \\
    );
    const warm = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--iface-hash", "--cache-dir=cache", "src" }, "bit-warm.json");
    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--iface-hash", "--no-cache", "src" }, "bit-plain.json");
    const hashes_after = try parseKeys(arena, warm.result.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    try testing.expectEqualStrings(plain.result.stdout, warm.result.stdout);
    try testing.expectEqualStrings(plain.result.stderr, warm.result.stderr);
    // Both re-checked: the edited module and the importer its record moved.
    try testing.expectEqual(@as(u64, 2), warm.counters.checked);
    try expectMoved("a flipped effect bit", hashes_before, hashes_after, &.{ "app:App", "app:Lib" });
}

test "a dependency that comes to suspend makes its importer's sync error appear warm, and go again" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `App` hands `Lib.name` to a `sync` parameter (transparent-effects-
    // proposal.md §15.2 item 1). An annotated body edit makes `name` call
    // the primitive that suspends, so only `Lib`'s effect block moves
    // (§15.5): `App` must be re-checked from its cache and refused there,
    // exactly as a cold run refuses it; and the edit undone, accepted again.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Plat.beni",
        \\pub foreign suspends get : Int → String
        \\
        \\
        \\pub foreign pure onEvent : sync (Int → String) → Int
        \\
    );
    const pure_lib =
        \\pub name : Int → String
        \\name n =
        \\    String.fromInt n
        \\
    ;
    try w.write("src/Lib.beni", pure_lib);
    try w.write("src/App.beni",
        \\import Lib
        \\import Plat
        \\
        \\
        \\pub wired : Int
        \\wired =
        \\    Plat.onEvent Lib.name
        \\
    );
    const args = [_][]const u8{ "check", "--core", "--jobs=1", "--diagnostics=json", "--cache-dir=cache", "src" };
    const cold = try runCounted(&w, arena, &args, "sync-cold.json");
    try testing.expectEqual(@as(u8, 0), cold.result.exit_code);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try w.write("src/Lib.beni",
        \\import Plat
        \\
        \\
        \\pub name : Int → String
        \\name n =
        \\    Plat.get n
        \\
    );
    const warm = try runCounted(&w, arena, &args, "sync-warm.json");
    const plain = try runCounted(&w, arena, &.{ "check", "--core", "--jobs=1", "--diagnostics=json", "--no-cache", "src" }, "sync-plain.json");
    try w.write("src/Lib.beni", pure_lib);
    const back = try runCounted(&w, arena, &args, "sync-back.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), warm.result.exit_code);
    try testing.expectEqualStrings(plain.result.stderr, warm.result.stderr);
    try testing.expect(std.mem.indexOf(u8, warm.result.stderr, "\"code\":\"sync_boundary\"") != null);
    try testing.expect(std.mem.indexOf(u8, warm.result.stderr, "`Lib.name` suspends.") != null);
    // Both re-checked: the edited module and the importer its record moved.
    try testing.expectEqual(@as(u64, 2), warm.counters.checked);
    try testing.expectEqual(@as(u8, 0), back.result.exit_code);
    try testing.expect(std.mem.indexOf(u8, back.result.stderr, "sync_boundary") == null);
}

test "a private schema conversion body stops at the interface firewall" {
    // The conversion is private, so its body is in no record: `Models` is
    // re-checked and `Consumer` is not.
    try expectSchemaEdit(
        schemaModels("first private body", "id", "item"),
        schemaModels("second private body", "id", "item"),
        1,
        false,
    );
}

test "a public schema's parameter renamed stops at the interface firewall" {
    // An alpha rename: the record states the parameter by position, not by
    // name.
    try expectSchemaEdit(
        schemaModels("second private body", "id", "item"),
        schemaModels("second private body", "id", "element"),
        1,
        false,
    );
}

test "a public schema's field renamed crosses the interface firewall" {
    // The field is `User.Type`'s, which `Consumer` names: `Models`'s hash
    // moves and both modules are re-checked.
    try expectSchemaEdit(
        schemaModels("second private body", "id", "element"),
        schemaModels("second private body", "name", "element"),
        2,
        true,
    );
}

// ---------------------------------------------------------------------------
// A custom equality across the interface firewall
// ---------------------------------------------------------------------------
//
// `Inner` contains a function, but its inferred public `eq` is the equality
// boundary `Outer` derives through. A private body edit must stop at
// `Inner`'s unchanged interface — `Outer` is a hit, so the capability is
// restored from its cached entry — while removing `pub` must invalidate and
// reject `Outer`.

const method_inner =
    \\pub type Inner
    \\    = Inner String (Int → Int)
    \\
    \\
    \\pub eq left right =
    \\    case left of
    \\        Inner labelLeft _ →
    \\            case right of
    \\                Inner labelRight _ →
    \\                    labelLeft == labelRight
    \\
;

const method_outer =
    \\import Inner
    \\import Node exposing (Program)
    \\
    \\
    \\pub type Outer
    \\    = Outer Inner.Inner
    \\
    \\
    \\plusOne value =
    \\    value + 1
    \\
    \\
    \\minusOne value =
    \\    value - 1
    \\
    \\
    \\show value =
    \\    if value then
    \\        "True"
    \\    else
    \\        "False"
    \\
    \\
    \\main : Program
    \\main =
    \\    Node.printLines
    \\        [ show
    \\            (Outer (Inner.Inner "same" plusOne)
    \\                == Outer (Inner.Inner "same" minusOne)
    \\            )
    \\        , show
    \\            (Outer (Inner.Inner "same" plusOne)
    \\                == Outer (Inner.Inner "different" plusOne)
    \\            )
    \\        ]
    \\
;

/// The two modules built cold into a cache, then `Inner` rewritten to
/// `edited` and built warm over it and cold with `--no-cache`, which must
/// agree on every stream. Returns the warm run.
fn methodEdit(w: *World, arena: std.mem.Allocator, edited: []const u8) !Run {
    try w.write("src/Inner.beni", method_inner);
    try w.write("src/Outer.beni", method_outer);
    const cold = try runCounted(
        w,
        arena,
        &.{ "build", "--platform=node", "--diagnostics=json", "--out=cold", "--jobs=1", "--cache-dir=cache", "src" },
        "method-cold.json",
    );
    try testing.expectEqual(@as(u8, 0), cold.result.exit_code);
    try w.write("src/Inner.beni", edited);
    const warm = try runCounted(
        w,
        arena,
        &.{ "build", "--platform=node", "--diagnostics=json", "--out=warm", "--jobs=1", "--cache-dir=cache", "src" },
        "method-warm.json",
    );
    const oracle = try runCounted(
        w,
        arena,
        &.{ "build", "--platform=node", "--diagnostics=json", "--out=oracle", "--jobs=1", "--no-cache", "src" },
        "method-oracle.json",
    );
    try testing.expectEqual(oracle.result.exit_code, warm.result.exit_code);
    try testing.expectEqualStrings(oracle.result.stdout, warm.result.stdout);
    try testing.expectEqualStrings(oracle.result.stderr, warm.result.stderr);
    return warm;
}

/// `Models` declares `Age`, whose `via` is a private conversion that adds
/// `bump`; `Main`'s own schema `Person` names `Age`, so `Person`'s
/// specialised worker calls `Models`'s (`schema.md` §6).
fn schemaBump(comptime bump: []const u8) []const u8 {
    return
    \\import Schema exposing (Conversion)
    \\
    \\
    \\bumped : Conversion Int Int
    \\bumped =
    \\    Schema.conversion (λn → Ok (n +
    ++ " " ++ bump ++
        \\)) λn → Ok n
        \\
        \\
        \\pub schema Age =
        \\    Int via bumped
        \\
    ;
}

const schema_person =
    \\import Models exposing (Age)
    \\import Node
    \\
    \\
    \\schema Person =
    \\    age : Age
    \\
    \\
    \\main : Node.Program
    \\main =
    \\    Node.printLines
    \\        [ case Person.parse "{\"age\":1}" of
    \\            Ok p →
    \\                String.fromInt p.age
    \\
    \\            Err _ →
    \\                "failed"
    \\        ]
    \\
;

test "a private conversion's body edit behind an imported schema stops at the firewall, and the cached importer's worker runs the new body" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Models.beni", schemaBump("1"));
    try w.write("src/Main.beni", schema_person);
    const cold = try runCounted(&w, arena, &.{ "build", "--platform=node", "--out=cold", "--jobs=1", "--cache-dir=cache", "src" }, "bump-cold.json");
    try testing.expectEqual(@as(u8, 0), cold.result.exit_code);
    try w.expectProgram("cold/_main.mjs", .{ .stdout = "2\n" });

    try w.write("src/Models.beni", schemaBump("10"));
    const warm = try runCounted(&w, arena, &.{ "build", "--platform=node", "--out=warm", "--jobs=1", "--cache-dir=cache", "src" }, "bump-warm.json");
    const oracle = try runCounted(&w, arena, &.{ "build", "--platform=node", "--out=oracle", "--jobs=1", "--no-cache", "src" }, "bump-oracle.json");

    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    // Only `Models` is re-checked: the body is in no record (A.6).
    try testing.expectEqual(@as(u64, 1), warm.counters.checked);
    try expectSameTree(&w, arena, "oracle", "warm");
    try testing.expectEqual(@as(u8, 0), oracle.result.exit_code);
    try w.expectProgram("warm/_main.mjs", .{ .stdout = "11\n" });
}

test "a custom eq's private body edit stops at the firewall, and the cached importer uses the new body" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    const edited = try std.mem.replaceOwned(u8, arena, method_inner, "labelLeft == labelRight", "labelLeft ≠ labelRight");
    const warm = try methodEdit(&w, arena, edited);
    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    try testing.expectEqual(@as(u64, 1), warm.counters.checked);
    try expectSameTree(&w, arena, "oracle", "warm");
    // The original prints "True\nFalse\n"; the edited eq, reached through
    // `Outer`'s cached derived eq, flips both.
    try w.expectProgram("warm/_main.mjs", .{ .stdout = "False\nTrue\n" });
}

test "a custom eq made private invalidates and rejects the importer that derives through it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    const hidden = try methodEdit(&w, arena, try std.mem.replaceOwned(u8, arena, method_inner, "pub eq", "eq"));
    try testing.expectEqual(@as(u8, 1), hidden.result.exit_code);
    try testing.expectEqual(@as(u64, 2), hidden.counters.checked);
    // The two comparisons are `private_method` (checker-v2.md §11.3:
    // private methods answer dispatch only inside their module): `Inner`'s
    // `eq` is private, so `Outer`'s derived `eq` cannot use it. The warm build
    // says exactly what the cold one says (`methodEdit`).
    const expected_hidden =
        \\[{"code":"private_method","severity":"error","span":{"file":"src/Outer.beni","start":{"line":29,"col":17},"end":{"line":29,"col":19}},"title":"PRIVATE METHOD","message":"`Inner.eq` is not `pub`.\n\nThis needs the `eq` of `Inner`, declared in `Inner`, which is inside:\n\n    Outer\n\n`Inner` declares `eq` without `pub`, and it is the `eq` of every type `Inner`\ndeclares, so it is private to that module: it cannot be used from here,\ndirectly or inside another value.\n\nHint: add `pub` to `eq` in `Inner`.\n"},{"code":"private_method","severity":"error","span":{"file":"src/Outer.beni","start":{"line":33,"col":17},"end":{"line":33,"col":19}},"title":"PRIVATE METHOD","message":"`Inner.eq` is not `pub`.\n\nThis needs the `eq` of `Inner`, declared in `Inner`, which is inside:\n\n    Outer\n\n`Inner` declares `eq` without `pub`, and it is the `eq` of every type `Inner`\ndeclares, so it is private to that module: it cannot be used from here,\ndirectly or inside another value.\n\nHint: add `pub` to `eq` in `Inner`.\n"}]
        \\
    ;
    try testing.expectEqualStrings(expected_hidden, hidden.result.stderr);
    try testing.expect(!w.exists("warm"));
    try testing.expect(!w.exists("oracle"));
}

// ---------------------------------------------------------------------------
// A constrained function constant across warm rebuilds
// ---------------------------------------------------------------------------
//
// checker-v2.md §12.5. `Leaf.h` takes evidence and has no parameters but a
// function TYPE, so it is defined over its type's arity and called flat;
// `Top` calls it, passes it to a fold, and defines its own point-free
// `mine = Leaf.h`. Each edit rewrites `h` in another shape — a function of
// two parameters, a lambda, a `let` whose body is `maxOf` again — which
// changes no interface, so `Top` is NOT re-checked: its cached table (the
// `convention` column included) and its reading of `Leaf`'s interface must
// still agree with the definition `Leaf` now emits. The warm tree is
// byte-compared with a `--no-cache` build and RUN.

const convention_leaf =
    \\pub maxOf : a, a → a
    \\    where a.compare : a, a → Order
    \\maxOf a b =
    \\    if a < b then
    \\        b
    \\
    \\    else
    \\        a
    \\
    \\
    \\pub h : a, a → a
    \\    where a.compare : a, a → Order
    \\h =
    \\    maxOf
    \\
    \\
    \\pub blank : List a
    \\    where a.eq : a, a → Bool
    \\blank =
    \\    []
    \\
;

const convention_top =
    \\import Leaf
    \\import Node exposing (Program)
    \\
    \\
    \\mine : a, a → a
    \\    where a.compare : a, a → Order
    \\mine =
    \\    Leaf.h
    \\
    \\
    \\main : Program
    \\main =
    \\    Node.printLines
    \\        [ String.fromInt (Leaf.h 1 2)
    \\        , Leaf.h "a" "b"
    \\        , String.fromInt (List.foldl [ 1, 5, 2 ] 0 Leaf.h)
    \\        , String.fromInt (mine 7 3)
    \\        , String.fromInt (List.foldl [ 4, 9 ] 0 mine)
    \\        , String.fromInt (List.length (Leaf.blank ++ [ 1 ]))
    \\        ]
    \\
;

/// Build cold into a cache, rewrite `h`'s definition as `body`, and build
/// warm over the cache and cold without one: `Leaf` alone is re-checked and
/// the two trees are byte-identical, and the warm one runs.
fn expectConventionEdit(body: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Leaf.beni", convention_leaf);
    try w.write("src/Top.beni", convention_top);

    const cold = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--diagnostics=json", "--out=cold", "--jobs=1", "--cache-dir=cache", "src" },
        "convention-cold.json",
    );
    try testing.expectEqual(@as(u8, 0), cold.result.exit_code);

    try w.write("src/Leaf.beni", try std.mem.replaceOwned(u8, arena, convention_leaf, "h =\n    maxOf\n", body));
    const warm = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--diagnostics=json", "--out=warm", "--jobs=1", "--cache-dir=cache", "src" },
        "convention-warm.json",
    );
    const oracle = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--diagnostics=json", "--out=oracle", "--jobs=1", "--no-cache", "src" },
        "convention-oracle.json",
    );
    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    try testing.expectEqual(@as(u8, 0), oracle.result.exit_code);
    // `Leaf` alone: its interface did not move, so `Top` is a hit.
    try testing.expectEqual(@as(u64, 1), warm.counters.checked);
    try expectSameTree(&w, arena, "oracle", "warm");
    try w.expectProgram("warm/_main.mjs", .{ .stdout = "2\nb\n5\n7\n9\n1\n" });
}

test "a constrained function constant rewritten with parameters keeps its importer's cached calling convention" {
    try expectConventionEdit("h a b =\n    maxOf a b\n");
}

test "a constrained function constant rewritten as a lambda keeps its importer's cached calling convention" {
    try expectConventionEdit("h =\n    λa b → maxOf a b\n");
}

test "a constrained function constant rewritten as a block keeps its importer's cached calling convention" {
    try expectConventionEdit("h =\n    f = maxOf\n    f\n");
}

test "a truncated or foreign .bef is a miss and is then overwritten" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `plans/m4-2.md` §9.4 item 23, black-box, and the twin of the `.bec`
    // test above. Which byte shapes the reader refuses — zero length, a
    // stub, a wrong magic or version, a flipped bit only the body hash sees
    // — is `frontend/artifact_bytes.zig`'s corrupt-artifact table; what only
    // a real run can show is that a refused artifact is re-lowered with
    // byte-identical output to a cold run and the same exit code, and that
    // the good artifact then replaces it. With the `rename` dropped (§6 B),
    // the "overwritten" half is a REQUIREMENT and not a nicety: a partial
    // file a crashed process left must not be believed forever. Two shapes
    // reach that: a truncated file, and another file's artifact under this
    // one's name, which only the session's own key comparison can refuse.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--no-cache", "src" }, "plain.json");
    _ = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "cold.json");
    const artifacts = try artifactsOnly(arena, try w.listFiles("cache"));
    try testing.expect(artifacts.len > 1);
    const victim = try std.fs.path.join(arena, &.{ "cache", artifacts[0] });
    const good = try w.read(victim);
    try testing.expect(good.len > 128);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
    const Shape = struct { what: []const u8, bytes: []const u8 };
    const shapes = [_]Shape{
        .{ .what = "truncated mid-section", .bytes = good[0 .. good.len - 8] },
        .{ .what = "another file's", .bytes = try w.read(try std.fs.path.join(arena, &.{ "cache", artifacts[1] })) },
    };
    for (shapes) |shape| {
        try w.write(victim, shape.bytes);
        const r = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "bad.json");
        testing.expectEqual(plain.result.exit_code, r.result.exit_code) catch |err| {
            std.debug.print("a {s} artifact changed the exit code\n", .{shape.what});
            return err;
        };
        testing.expectEqualStrings(plain.result.stderr, r.result.stderr) catch |err| {
            std.debug.print("a {s} artifact changed stderr\n", .{shape.what});
            return err;
        };
        // Exactly one file missed — the one whose artifact was ruined — and
        // the run then wrote it back, byte for byte.
        try testing.expectEqual(@as(u64, 1), r.counters.lowered);
        try testing.expectEqualStrings(good, try w.read(victim));
    }
}

test "the interner-order fixture: a cache written over P is read over P plus a module sorting first" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `plans/m4-slice-zero.md` §7.1's shape, aimed at the front-end cache's own hazard. A worker's local
    // symbol numbering depends on which files it took and in what order, so
    // an artifact that stored raw `Symbol` ids would be read against a
    // different numbering the moment a file is ADDED — and `Aardvark`, full
    // of identifiers and sorting before everything, is the file that changes
    // every later numbering. Writing `symbols` as raw ids and watching this
    // go red is what it is for.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    try w.write("src/Zeta.beni",
        \\pub zeta : Int
        \\zeta =
        \\    alpha =
        \\        1
        \\
        \\    beta =
        \\        2
        \\    alpha + beta
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // Written at `--jobs=8` over P.
    _ = try runCounted(&w, arena, &.{ "check", "--jobs=8", "--cache-dir=cache", "src" }, "p.json");
    // Then a module full of unrelated identifiers, sorting first, is added,
    // and the cache is read at `--jobs=1`.
    try w.write("src/Aardvark.beni",
        \\pub aardvark : Int
        \\aardvark =
        \\    gamma =
        \\        1
        \\
        \\    delta =
        \\        2
        \\
        \\    epsilon =
        \\        3
        \\
        \\    zeta2 =
        \\        4
        \\    gamma + delta + epsilon + zeta2
        \\
    );
    const grown = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "p2.json");
    const cold_hashes = try ifaceHashes(&w, arena);
    const warm_hashes = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "--cache-dir=cache", "src" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The project is clean, so a run that believed a shifted numbering would
    // say something where a cold run says nothing.
    try testing.expectEqual(@as(u8, 0), grown.result.exit_code);
    try testing.expectEqualStrings("", grown.result.stderr);
    // Only the new file was lowered; everything the first run wrote was read
    // back under a numbering that had shifted.
    try testing.expectEqual(@as(u64, 1), grown.counters.lowered);
    // And every module's interface record is byte-for-byte the cold one's,
    // which is the assertion a shifted `Symbol` would break.
    try expectMoved("the interner-order fixture", cold_hashes, try parseKeys(arena, warm_hashes.stdout), &.{});
}

/// `v1/<kk>/<rest>.bef`, the artifact path a file key names.
fn artifactPathFor(buffer: *[40]u8, digits: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "v1/{s}/{s}.bef", .{ digits[0..2], digits[2..] }) catch unreachable;
}

fn fileKeysOfAllowingErrors(w: *World, arena: std.mem.Allocator) ![]const Entry {
    const r = try w.runWith(&.{ "check", "--frontend-keys", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    return parseKeys(arena, r.stdout);
}

/// The `.bec` entries of a cache listing — the checker's, one per MODULE.
fn entriesOnly(arena: std.mem.Allocator, files: []const []const u8) ![]const []const u8 {
    return withExtension(arena, files, ".bec");
}

/// The `.bef` front-end artifacts — one per FILE, under a different
/// key in the same fan-out.
fn artifactsOnly(arena: std.mem.Allocator, files: []const []const u8) ![]const []const u8 {
    return withExtension(arena, files, ".bef");
}

fn withExtension(arena: std.mem.Allocator, files: []const []const u8, ext: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        if (std.mem.endsWith(u8, f, ext)) try out.append(arena, f);
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// The checked core the binary carries (`fast-compiler.md` §8, *The checked
// core, embedded*)
// ---------------------------------------------------------------------------

/// A program that reaches core well beyond the modules every check keeps.
const reaches_core =
    \\import Dict exposing (Dict)
    \\import Schema
    \\
    \\
    \\pub sizes : Dict String Int
    \\sizes =
    \\    Dict.fromList [ ( "a", 1 ), ( "b", 2 ) ]
    \\
    \\
    \\pub parsed : Result (List Schema.Issue) Int
    \\parsed =
    \\    Schema.parse Schema.int "3"
    \\
;

test "a check on the embedded core lexes, parses, lowers and checks no core module" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The owner's decision of 2026-10-02: core is checked once, when beni
    // is built, and no build checks an embedded core module again — not
    // with `--no-cache`, not on a first run. The counters are the claim: a
    // core module that was checked and a core module that was installed
    // produce the same output, and only these say which one happened.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Uses.beni", reaches_core);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try runCounted(&w, arena, &.{ "check", "--no-cache", "src" }, "trace.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.result.exit_code);
    try testing.expectEqualStrings("", r.result.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // One module of the project, checked; every other module of the graph
    // — the prelude, `Task`, `Dict`, `Schema` and what they import — is
    // core, and was installed.
    try testing.expectEqual(@as(u64, 1), r.counters.checked);
    try testing.expect(r.counters.embedded_modules >= 10);
    try testing.expectEqual(r.counters.modules, r.counters.checked + r.counters.embedded_modules);
    // One file through the front end; every core file installed whole.
    try testing.expectEqual(@as(u64, 1), r.counters.lexed);
    try testing.expectEqual(@as(u64, 1), r.counters.lowered);
    try testing.expectEqual(r.counters.files, r.counters.lowered + r.counters.embedded_files);
    // `--no-cache` means no cache, and the checked core is not one.
    try testing.expectEqual(@as(u64, 0), r.counters.hits);
    try testing.expect(!w.exists(".beni-cache"));
}

test "a core read with --core-root is checked by the build, as before there was a checked core" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A core read from disk is somebody's core under development, and the
    // checked core the binary carries says nothing about it — even a copy
    // whose bytes are the embedded ones. It is lowered and checked, and it
    // is cached per module in the directory like any other package.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.copyTreeInto("core", "mycore", "_");
    try w.write("src/Uses.beni", reaches_core);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const embedded = try runCounted(&w, arena, &.{ "check", "--no-cache", "src" }, "embedded.json");
    const cold = try runCounted(&w, arena, &.{ "check", "--cache-dir=cache", "--core-root=mycore", "src" }, "cold.json");
    const warm = try runCounted(&w, arena, &.{ "check", "--cache-dir=cache", "--core-root=mycore", "src" }, "warm.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]Run{ embedded, cold, warm }) |r| {
        try testing.expectEqual(@as(u8, 0), r.result.exit_code);
        try testing.expectEqualStrings("", r.result.stderr);
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The same graph, every module of it checked and every file lowered…
    try testing.expectEqual(embedded.counters.modules, cold.counters.modules);
    try testing.expectEqual(cold.counters.modules, cold.counters.checked);
    try testing.expectEqual(@as(u64, 0), cold.counters.embedded_modules);
    try testing.expectEqual(@as(u64, 0), cold.counters.embedded_files);
    try testing.expectEqual(cold.counters.files, cold.counters.lowered);
    // …and cached in the directory, so the second run checks none of it.
    try testing.expectEqual(cold.counters.modules, warm.counters.hits);
    try testing.expectEqual(@as(u64, 0), warm.counters.checked);
}

test "--no-cache beside --cache-dir reads nothing and writes nothing" {
    // The flag exists before there is a default so a script written today
    // keeps working the day one arrives (`frontend.md` §1) — which is worth
    // nothing unless it really does suppress the directory beside it.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const r = try runCounted(
        &w,
        arena,
        &.{ "check", "--jobs=1", "--cache-dir=cache", "--no-cache", "src" },
        "trace.json",
    );
    try testing.expectEqual(@as(u8, 0), r.result.exit_code);
    try testing.expectEqualStrings("", r.result.stderr);
    try testing.expectEqual(@as(u64, 0), r.counters.hits);
    try testing.expectEqual(@as(u64, 0), r.counters.bytes);
    // The directory is not even created: `--no-cache` is "no cache", not
    // "a cache that is ignored".
    try testing.expectEqual(@as(usize, 0), (try w.listFiles("cache")).len);
    try testing.expect(!w.exists("cache"));
}

test "a cache directory naming an existing file is exit 2 with the path named" {
    // `frontend.md` §1: the directory is created if it is missing and a
    // failure to create it is 2 with the path named, like `--out`'s. This is
    // the ONE failure a cache is allowed to have — a person who named a
    // cache directory meant it, and silently ignoring a typo would make
    // every later build mysteriously slow for no stated reason.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    try w.write("notadir", "I am a regular file.\n");

    const r = try w.runWith(&.{ "check", "--jobs=1", "--cache-dir=notadir", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "notadir") != null);
    try testing.expect(std.mem.startsWith(u8, r.stderr, "beni: cannot write '"));
}

test "a cache directory with spaces and non-ASCII in its name works" {
    // A path is a sequence of bytes and the compiler must not assume
    // otherwise; a cache directory is the first path a user chooses freely
    // rather than one derived from a module name.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const r = try runCounted(
        &w,
        arena,
        &.{ "check", "--jobs=1", "--cache-dir=a cache dír/nested", "src" },
        "trace.json",
    );
    try testing.expectEqual(@as(u8, 0), r.result.exit_code);
    try testing.expectEqualStrings("", r.result.stderr);
    try testing.expect(r.counters.bytes > 0);
    try testing.expect((try w.listFiles("a cache dír/nested")).len > 0);
}

test "a read-only cache directory is an ordinary run that writes nothing" {
    // `plans/m4-1.md` §6.3 row 16. The directory EXISTS, so it is not the
    // exit-2 case; what fails is creating `v1/` inside it, and every
    // per-entry failure is silent by contract — the run produces
    // byte-identical output to one with no cache at all, on both streams.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    try w.createDir("locked");
    if (!try w.makeDirUnwritable("locked")) return; // root, or a filesystem with no permissions
    defer w.restoreDirMode("locked");

    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--no-cache", "src" }, "plain.json");
    const locked = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=locked", "src" }, "locked.json");

    try testing.expectEqual(plain.result.exit_code, locked.result.exit_code);
    try testing.expectEqualStrings(plain.result.stdout, locked.result.stdout);
    try testing.expectEqualStrings(plain.result.stderr, locked.result.stderr);
    try testing.expectEqual(@as(u64, 0), locked.counters.hits);
    try testing.expectEqual(@as(u64, 0), locked.counters.bytes);
}

test "a module with a type error is never written, and its importers are not either" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `plans/m4-1.md` §6.2 row 11, and the rule is a refusal to WRITE rather
    // than a bit to read: an `<error>` scheme is a hole every importer checks
    // clean against, and the one failure mode a compiler may not have is
    // `beni check` exiting 0 over it. Fails before the clean-bit rule with an
    // exit 0 and an `<error>` hole.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    try w.write("src/Leaf.beni",
        \\pub foreign pure twice : Int → Int
        \\
        \\
        \\pub one : Int
        \\one =
        \\    "not an Int"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const first = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "first.json");
    const second = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "second.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), first.result.exit_code);
    try testing.expectEqual(@as(u8, 1), second.result.exit_code);
    // Identical both times: a broken module may not be cached into silence.
    try testing.expectEqualStrings(first.result.stderr, second.result.stderr);
    try testing.expect(first.result.stderr.len != 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Every file's front-end artifact is still written, so this is not
    // "nothing was written"; what is absent is exactly the broken module's
    // entry. Core has none either way: it comes from the checked core the
    // binary carries (`fast-compiler.md` §8, *The checked core, embedded*),
    // which no cache directory holds.
    const files = try w.listFiles("cache");
    try testing.expect(files.len > 0);
    const keys = try baselineKeysAllowingErrors(&w, arena);
    try expectNoEntry(&w, files, lookup(keys, "app:Leaf").?);
    try expectNoEntry(&w, files, lookup(keys, "core:Basics").?);

    // And after the fix, the module compiles and is written.
    try w.write("src/Leaf.beni", leaf_source);
    const fixed = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "fixed.json");
    try testing.expectEqual(@as(u8, 0), fixed.result.exit_code);
    const after = try w.listFiles("cache");
    const fixed_keys = try baselineKeys(&w, arena);
    try expectEntry(&w, after, lookup(fixed_keys, "app:Leaf").?);
}

test "the members of an import cycle are never written, and the rest of the project still is" {
    // `plans/m4-1.md` §6.2 row 13. A poisoned module's declarations are
    // error types and it reports nothing further (`checker.md` §4.3), so its
    // silence says nothing about its correctness — which is exactly why
    // uncacheability has to be a bit of its own rather than "produced no
    // diagnostic".
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    try w.write("src/Ping.beni",
        \\import Pong
        \\
        \\
        \\pub ping : Int
        \\ping =
        \\    Pong.pong
        \\
    );
    try w.write("src/Pong.beni",
        \\import Ping
        \\
        \\
        \\pub pong : Int
        \\pong =
        \\    Ping.ping
        \\
    );

    const first = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "first.json");
    const second = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "second.json");
    try testing.expectEqual(@as(u8, 1), first.result.exit_code);
    try testing.expectEqualStrings(first.result.stderr, second.result.stderr);

    const files = try w.listFiles("cache");
    const keys = try baselineKeysAllowingErrors(&w, arena);
    try expectNoEntry(&w, files, lookup(keys, "app:Ping").?);
    try expectNoEntry(&w, files, lookup(keys, "app:Pong").?);
    // The modules outside the cycle are untouched by it.
    try expectEntry(&w, files, lookup(keys, "app:Leaf").?);
    try expectEntry(&w, files, lookup(keys, "app:Mid").?);
}

// ---------------------------------------------------------------------------
// The hit path: warm ≡ cold, in every configuration
// ---------------------------------------------------------------------------

/// Build the project once into `cache` and once more against it, and require
/// the two runs to agree on everything a run can say. The second run's
/// counters are returned so a scenario can assert what it hit.
fn coldThenWarm(
    w: *World,
    arena: std.mem.Allocator,
    cold_args: []const []const u8,
    warm_args: []const []const u8,
) !Run {
    const cold = try runCounted(w, arena, cold_args, "cold.json");
    const warm = try runCounted(w, arena, warm_args, "warm.json");
    try testing.expectEqual(cold.result.exit_code, warm.result.exit_code);
    try testing.expectEqualStrings(cold.result.stdout, warm.result.stdout);
    try testing.expectEqualStrings(cold.result.stderr, warm.result.stderr);
    try testing.expectEqual(@as(u64, 0), cold.counters.hits);
    return warm;
}

test "a second check of an unchanged tree re-checks nothing and says exactly the same thing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The module cache's plainest win: an unchanged tree, plus the core
    // modules and the platform, which are unchanged in every build anyone
    // will ever run.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
    const warm = try coldThenWarm(
        &w,
        arena,
        &.{ "check", "--jobs=1", "--cache-dir=cache", "src" },
        &.{ "check", "--jobs=1", "--cache-dir=cache", "src" },
    );
    try testing.expectEqual(@as(u64, 0), warm.counters.misses);
    try testing.expectEqual(@as(u64, 0), warm.counters.checked);
    // The app's three from the directory; the core modules from the checked
    // core the binary carries, on this run as on the cold one.
    try testing.expectEqual(@as(u64, 3), warm.counters.hits);
    try testing.expect(warm.counters.embedded_modules >= 8);
    // Nothing new was written: every entry was already there under its key.
    try testing.expectEqual(@as(u64, 0), warm.counters.bytes);
}

test "a comment re-checks ONE module — the counters' half of the cutoff" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // **The counters' half of the cutoff.** Were an importer's key to carry
    // its import's KEY, a comment in `Leaf` would re-check `Mid` and `Top`
    // too. An import
    // contributes its `(interface hash, dependency digest)` pair, a comment
    // moves neither, and the importers are HITS.
    //
    // Byte-identity alone would pass a cache that never hits, which is why
    // the counter is asserted and not only the output.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "cold.json");
    try testing.expectEqual(@as(u64, 0), cold.counters.hits);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try w.write("src/Leaf.beni", "-- a comment nobody reads\n" ++ leaf_source);
    const after = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "after.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), after.result.exit_code);
    try testing.expectEqualStrings("", after.result.stderr);
    // Exactly ONE module missed — the edited leaf — and everything else,
    // core and the two importers alike, hit.
    try testing.expectEqual(@as(u64, 1), after.counters.misses);
    try testing.expectEqual(@as(u64, 1), after.counters.checked);
    try testing.expectEqual(cold.counters.misses - 1, after.counters.hits);

    // A new unrelated file costs one miss and nothing else.
    try w.write("src/Aardvark.beni", "pub zero : Int\nzero =\n    0\n");
    const added = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "added.json");
    try testing.expectEqual(@as(u64, 1), added.counters.misses);
    try testing.expectEqual(@as(u64, 1), added.counters.checked);
}

test "a warm build emits byte-identical JavaScript, and it runs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The assertion the dispatch sidecar exists for. `check` can be wrong
    // about the table and say nothing; a BUILD turns the same wrongness into
    // a different program. The emitted tree is compared byte for byte and
    // then executed, which is the second boundary.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Shapes.beni",
        \\pub type Shape
        \\    = Circle Int
        \\    | Rect Int Int
        \\
        \\
        \\pub area : Shape → Int
        \\area s =
        \\    case s of
        \\        Circle r →
        \\            r * r
        \\
        \\        Rect x y →
        \\            x * y
        \\
        \\
        \\pub same : Shape, Shape → Bool
        \\same a b =
        \\    a == b
        \\
        \\
        \\pub bigger : a, a → a
        \\    where a.compare : a, a → Order
        \\bigger a b =
        \\    if a < b then b else a
        \\
    );
    try w.write("src/Main.beni",
        \\import Node
        \\import Shapes exposing (Shape)
        \\
        \\
        \\pub main : Node.Program
        \\main =
        \\    Node.print
        \\        (String.fromInt
        \\            (Shapes.area (Shapes.bigger (Shapes.Circle 2) (Shapes.Rect 3 4)))
        \\        )
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const cold = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--out=cold", "--jobs=1", "--cache-dir=cache", "src" },
        "cold.json",
    );
    try testing.expectEqual(@as(u8, 0), cold.result.exit_code);
    const warm = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--out=warm", "--jobs=8", "--cache-dir=cache", "src" },
        "warm.json",
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(cold.result.exit_code, warm.result.exit_code);
    try testing.expectEqualStrings(cold.result.stdout, warm.result.stdout);
    try testing.expectEqualStrings(cold.result.stderr, warm.result.stderr);
    try testing.expectEqual(@as(u64, 0), warm.counters.checked);
    try testing.expect(warm.counters.hits > 0);

    try expectSameTree(&w, arena, "cold", "warm");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // And the program the warm build wrote actually runs, which is the only
    // assertion that can catch a table that survived the format and means
    // something else. `Rect 3 4` is the bigger of the two — a derived
    // `compare` orders by constructor first — so the area is 12.
    try w.expectProgram("warm/_main.mjs", .{ .stdout = "12\n" });
}

test "an importer re-checked against cached records reads their aliases as a cold build does" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Geo` declares the aliases; `Wrap` publishes inferred schemes that name
    // them, so its record carries their bodies on its `type_refs` rows
    // (checker-v2.md §14.2); `Main` imports `Wrap` alone. After an edit to
    // `Main` only, the warm build re-checks `Main` against `Wrap`'s record
    // as the cache stored it — the bodies read back from bytes, `Pred`'s
    // arity through its body included — and must write what a cold build
    // of the same tree writes.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Geo.beni",
        \\type alias Inner a =
        \\    { v : a, w : Int }
        \\
        \\
        \\pub type alias Box a =
        \\    { inner : Inner a, tag : String }
        \\
        \\
        \\pub type alias Pred a =
        \\    a → Bool
        \\
        \\
        \\pub box : a → Box a
        \\box x =
        \\    { inner = { v = x, w = 1 }, tag = "box" }
        \\
        \\
        \\pub positive : Pred Int
        \\positive n =
        \\    n > 0
        \\
    );
    try w.write("src/Wrap.beni",
        \\import Geo
        \\
        \\
        \\pub twice x =
        \\    Geo.box (Geo.box x)
        \\
        \\
        \\pub check =
        \\    Geo.positive
        \\
    );
    const main_source =
        \\import Node
        \\import Wrap
        \\
        \\
        \\pub main : Node.Program
        \\main =
        \\    b =
        \\        Wrap.twice 5
        \\    Node.printLines
        \\        [ String.fromInt b.inner.v.inner.v
        \\        , b.inner.v.tag
        \\        , if Wrap.check 3 then "positive" else "not"
        \\        ]
        \\
    ;
    try w.write("src/Main.beni", main_source);
    const cold = try runCounted(&w, arena, &.{ "build", "--platform=node", "--out=first", "--jobs=1", "--cache-dir=cache", "src" }, "first.json");
    try testing.expectEqual(@as(u8, 0), cold.result.exit_code);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try w.write("src/Main.beni", "-- edited\n" ++ main_source);
    const warm = try runCounted(&w, arena, &.{ "build", "--platform=node", "--out=warm", "--jobs=1", "--cache-dir=cache", "src" }, "warm.json");
    const fresh = try runCounted(&w, arena, &.{ "build", "--platform=node", "--out=cold", "--jobs=1", "--no-cache", "src" }, "cold.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    try testing.expectEqualStrings(fresh.result.stdout, warm.result.stdout);
    try testing.expectEqualStrings(fresh.result.stderr, warm.result.stderr);
    // `Main` alone was re-checked; `Wrap` and `Geo` were installed.
    try testing.expectEqual(@as(u64, 1), warm.counters.checked);
    try expectSameTree(&w, arena, "cold", "warm");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try w.expectProgram("warm/_main.mjs", .{ .stdout = "5\nbox\npositive\n" });
}

/// Every file under `want` is under `got`, with the same name and the same
/// bytes, and there is nothing extra. Not "the files a test thought to name":
/// a module that appears or vanishes on a warm build is exactly the sort of
/// difference the cache exists not to make.
fn expectSameTree(w: *World, arena: std.mem.Allocator, want_dir: []const u8, got_dir: []const u8) !void {
    const want = try w.listFiles(want_dir);
    const got = try w.listFiles(got_dir);
    try testing.expectEqual(want.len, got.len);
    try testing.expect(want.len > 1);
    for (want, got) |a, b| {
        try testing.expectEqualStrings(a, b);
        const want_bytes = try w.read(try std.fs.path.join(arena, &.{ want_dir, a }));
        const got_bytes = try w.read(try std.fs.path.join(arena, &.{ got_dir, b }));
        testing.expectEqualStrings(want_bytes, got_bytes) catch |err| {
            std.debug.print("{s} differs between a cold build and a warm one\n", .{a});
            return err;
        };
    }
}

// `plans/m4-1.md` §6.3 row 14 and the cross `fast-compiler.md` §8 calls
// deliberate: a cache written in one configuration and read in another. The
// keys agreeing is asserted above against `--cache-keys`; these are the half
// that reads the files.

test "a cache written at --jobs=8 is read at --jobs=1" {
    // A cache written at one worker count and read at another is what would
    // catch a `Symbol` — which depends on which worker interned which file —
    // reaching the bytes.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const warm = try coldThenWarm(
        &w,
        arena,
        &.{ "check", "--jobs=8", "--cache-dir=eight", "src" },
        &.{ "check", "--jobs=1", "--cache-dir=eight", "src" },
    );
    try testing.expectEqual(@as(u64, 0), warm.counters.checked);
}

test "a cache written under an absolute path and root is hit through a relative spelling" {
    // Nothing in the key or in the entry is a path, and every path is
    // normalised lexically at enumeration, so `src`, `./src/` and `$PWD/src`
    // are one project — which means an entry written under one spelling
    // must be HIT by another: the strong form of "a cache does not depend on
    // the directory the compiler was run from". `./src/` carries both a
    // leading `./` and a trailing `/`.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const absolute = try w.projectSubPath(arena, "src");
    try w.createDir("cwdcache");
    const cache = try w.projectSubPath(arena, "cwdcache");
    const root_flag = try std.fmt.allocPrint(arena, "--root={s}", .{absolute});
    const dir_flag = try std.fmt.allocPrint(arena, "--cache-dir={s}", .{cache});
    // Written by the absolute spelling, with an absolute `--root`…
    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", dir_flag, root_flag, absolute }, "abs.json");
    try testing.expectEqual(@as(u64, 0), cold.counters.hits);
    // …and read by a relative one, which must check none.
    const warm = try runCounted(&w, arena, &.{ "check", "--jobs=1", dir_flag, "./src/" }, "rel.json");
    try testing.expectEqual(@as(u64, 0), warm.counters.checked);
    try testing.expectEqual(cold.counters.misses, warm.counters.hits);
}

test "a cache written by check is read by build" {
    // The entry holds the check's result and no emitted byte, so the two
    // commands share it; one that depended on which command wrote it would
    // miss here.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const checked = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=shared", "src" }, "c.json");
    try testing.expectEqual(@as(u64, 0), checked.counters.hits);
    const built = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--library", "--out=out", "--jobs=1", "--cache-dir=shared", "src" },
        "b.json",
    );
    try testing.expectEqual(@as(u8, 0), built.result.exit_code);
    // The app's three modules and core hit; the platform's own modules are
    // new to this cache, because `check` never enumerated them.
    try testing.expect(built.counters.hits >= checked.counters.misses);
}

test "a truncated or foreign entry is a miss and is then overwritten" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `plans/m4-1.md` §6.4, black-box. Which byte shapes the reader refuses
    // — zero length, a stub, a wrong magic, a bumped version, a section past
    // the end — is `cache/entry_bytes.zig`'s table, one unit test per shape;
    // what only a real run can show is what a refused entry BECOMES: a miss,
    // byte-identical output to a cold run and the same exit code — never a
    // crash, a diagnostic or a wrong answer — and the good entry written
    // back over it. Two shapes reach that: a truncated file (a torn write)
    // and a whole entry written for another key, which only the session's
    // own key comparison can refuse.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--no-cache", "src" }, "plain.json");
    _ = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "cold.json");
    // The `.bec` entries only: a ruined `.bef` is a FRONT-END miss and does
    // not move `cache_misses`, so the row below would be measuring the wrong
    // counter. `plans/m4-2.md` §9.4's own table for `.bef` is the twin test.
    const files = try entriesOnly(arena, try w.listFiles("cache"));
    try testing.expect(files.len > 1);
    const victim = try std.fs.path.join(arena, &.{ "cache", files[0] });
    const good = try w.read(victim);
    try testing.expect(good.len > 64);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
    // Truncated mid-section, and an entry written for ANOTHER key planted
    // under this key's name: the "wrong build id" case, and the one the
    // header's key field exists to catch without trusting the directory.
    const Shape = struct { what: []const u8, bytes: []const u8 };
    const shapes = [_]Shape{
        .{ .what = "truncated mid-section", .bytes = good[0 .. good.len - 8] },
        .{ .what = "another key's", .bytes = try w.read(try std.fs.path.join(arena, &.{ "cache", files[1] })) },
    };
    for (shapes) |shape| {
        try w.write(victim, shape.bytes);
        const r = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "bad.json");
        testing.expectEqual(plain.result.exit_code, r.result.exit_code) catch |err| {
            std.debug.print("a {s} entry changed the exit code\n", .{shape.what});
            return err;
        };
        testing.expectEqualStrings(plain.result.stderr, r.result.stderr) catch |err| {
            std.debug.print("a {s} entry changed stderr\n", .{shape.what});
            return err;
        };
        // Exactly one module missed — the one whose entry was ruined — and
        // the run then wrote it back.
        try testing.expectEqual(@as(u64, 1), r.counters.misses);
        try testing.expect(r.counters.bytes > 0);
        try testing.expectEqualStrings(good, try w.read(victim));
    }
}

test "a schema plan whose endpoint terms disagree with its declaration is a miss" {
    // The schema-plan reader can accept a byte stream that is internally
    // well-formed while its meaning disagrees with the BIR and Types tables
    // rebuilt from this source. In particular, `app` and `alias` carry the
    // same in-bounds operands. A cache hit must validate that a record
    // schema's two endpoint terms are aliases, rather than trusting the tag
    // merely because the plan can decode it.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Models.beni",
        \\pub schema User =
        \\    id : Int
        \\
        \\
        \\pub near a b =
        \\    a.close b 1
        \\
    );

    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "schema-plan-cold.json");
    try testing.expect(std.mem.indexOf(u8, cold.result.stderr, "CONSTRAINT IN AN INFERRED INTERFACE") != null);

    const keys = try keysOf(&w, arena, &.{ "--jobs=1", "src" });
    const models_key = lookup(keys, "app:Models") orelse return error.MissingKey;
    const relative = entryPathFor(models_key);
    const victim = try std.fs.path.join(arena, &.{ "cache", &relative });
    const good = try w.read(victim);
    const mangled = try arena.dupe(u8, good);

    // `entry_bytes`: header(32), then four { offset, len } rows. The schema
    // plan is section 2. `schema_plan_bytes`: header(16), then 22 column
    // rows. Definitions are column 0 and term tags are column 11. Change
    // both endpoint tags from alias(7) to app(2), leaving every operand and
    // every index in bounds so a shallow structural check still accepts it.
    try testing.expect(mangled.len >= 56);
    const plan_base: usize = std.mem.readInt(u32, mangled[48..52], .little);
    try testing.expect(plan_base + 16 + 12 * 8 <= mangled.len);
    const definition_base = plan_base + std.mem.readInt(u32, mangled[plan_base + 16 ..][0..4], .little);
    try testing.expect(definition_base + 44 <= mangled.len);
    const program_term: usize = std.mem.readInt(u32, mangled[definition_base + 28 ..][0..4], .little);
    const encoded_term: usize = std.mem.readInt(u32, mangled[definition_base + 32 ..][0..4], .little);
    const tags_base = plan_base + std.mem.readInt(u32, mangled[plan_base + 16 + 11 * 8 ..][0..4], .little);
    try testing.expect(tags_base + program_term < mangled.len);
    try testing.expect(tags_base + encoded_term < mangled.len);
    try testing.expectEqual(@as(u8, 7), mangled[tags_base + program_term]);
    try testing.expectEqual(@as(u8, 7), mangled[tags_base + encoded_term]);
    mangled[tags_base + program_term] = 2;
    mangled[tags_base + encoded_term] = 2;
    try w.write(victim, mangled);

    // The mangled plan is refused on the hit: `Models` misses and is checked
    // again, says what the cold run said, and its entry is written back.
    const repaired = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "schema-plan-repaired.json");
    try testing.expectEqual(cold.result.exit_code, repaired.result.exit_code);
    try testing.expectEqualStrings(cold.result.stdout, repaired.result.stdout);
    try testing.expectEqualStrings(cold.result.stderr, repaired.result.stderr);
    try testing.expectEqual(@as(u64, 1), repaired.counters.misses);
    try testing.expectEqual(@as(u64, 1), repaired.counters.checked);
    try testing.expect(repaired.counters.bytes > 0);
    try testing.expectEqualStrings(good, try w.read(victim));
}

test "a pre-warmed cache directory made read-only still hits everything" {
    // `plans/m4-1.md` §6.3 row 16, second half. Reading needs no write
    // permission, and a cache on a read-only mount — which is how a CI
    // image would ship one — has to work.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "cold.json");
    if (!try w.makeDirUnwritable("cache")) return;
    defer w.restoreDirMode("cache");
    const warm = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "warm.json");
    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    try testing.expectEqualStrings("", warm.result.stderr);
    try testing.expectEqual(cold.counters.misses, warm.counters.hits);
    try testing.expectEqual(@as(u64, 0), warm.counters.checked);
}

test "processes racing on an empty cache directory agree and never accept a torn file" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // There are no locks and no `rename`: two processes that compute the
    // same key write identical bytes, and what makes a partial file safe is
    // that the header carries the file's total length and the reader checks
    // it FIRST, so every prefix is a miss. That check is the unit tests'
    // (`cache/entry_bytes.zig`, `frontend/artifact_bytes.zig`: every prefix
    // of a real file is refused); this is the same claim with real
    // processes.
    //
    // Four processes at once on one initially EMPTY directory, each both a
    // reader and a writer, because a `check` reads what is there and writes
    // what is not. Every one must exit 0 and print exactly what a
    // `--no-cache` run prints — a torn file that was believed would show up
    // as a different diagnostic, a different exit code or a crash, and one
    // that was merely tolerated shows up in the settled run at the end.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    const alone = try w.runWith(&.{ "check", "--jobs=1", "--no-cache", "src" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const racers = 4;
    var results: [racers]world.Result = undefined;
    var threads: [racers]std.Thread = undefined;
    const Racer = struct {
        w: *World,
        args: []const []const u8,
        out: *world.Result,
        err: ?anyerror = null,
        fn go(r: *@This()) void {
            r.out.* = r.w.runWith(r.args, .{ .raw_diagnostics = true }) catch |e| {
                r.err = e;
                return;
            };
        }
    };
    // Different `--jobs` on purpose: the processes then reach any one key at
    // different moments, which is what makes the overlap real rather than
    // nominal.
    var list: [racers]Racer = undefined;
    for (&list, 0..) |*slot, i| {
        const jobs = try std.fmt.allocPrint(arena, "--jobs={d}", .{i + 1});
        slot.* = .{
            .w = &w,
            .args = try arena.dupe([]const u8, &.{ "check", jobs, "--cache-dir=torn", "src" }),
            .out = &results[i],
        };
    }
    for (&threads, &list) |*t, *r| t.* = try std.Thread.spawn(.{}, Racer.go, .{r});
    for (threads) |t| t.join();

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for (list) |r| {
        if (r.err) |e| return e;
    }
    for (results) |r| {
        try testing.expectEqual(alone.exit_code, r.exit_code);
        try testing.expectEqualStrings(alone.stderr, r.stderr);
        try testing.expectEqualStrings(alone.stdout, r.stdout);
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A settled run over the directory the race left behind hits EVERY file
    // and every module: no half-written file survived it, and none was left
    // in a state that is refused forever.
    const settled = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=torn", "src" }, "settled.json");
    try testing.expectEqual(@as(u64, 0), settled.counters.lowered);
    try testing.expectEqual(@as(u64, 0), settled.counters.checked);
    try testing.expectEqual(@as(u64, 0), settled.counters.misses);
}

test "a module with a warning is cached and replays it byte for byte" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `plans/m4-1.md` §6.2 row 12. `ambiguous_method_receiver` is on by
    // default for the root package, so "a module with any diagnostic is
    // never cached" would exempt most real projects — which is why warnings
    // are cached and replayed rather than refused.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    // An unannotated `pub` whose body constrains its parameter: §10.9's
    // warning, emitted by default for a module of the root package.
    try w.write("src/Vague.beni",
        \\pub near a b =
        \\    a.close b 1
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "cold.json");
    const warm = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "warm.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The fixture really does warn, or the replay below proves nothing.
    try testing.expect(cold.result.stderr.len != 0);
    try testing.expect(
        std.mem.indexOf(u8, cold.result.stderr, "CONSTRAINT IN AN INFERRED INTERFACE") != null,
    );
    // A warning does not change the exit code, so the module was clean and
    // was cached.
    try testing.expectEqual(@as(u8, 0), cold.result.exit_code);
    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    try testing.expectEqualStrings(cold.result.stderr, warm.result.stderr);
    try testing.expectEqual(@as(u64, 0), warm.counters.checked);
}

// ---------------------------------------------------------------------------
// Every flag is classified, and the classification is falsifiable
// ---------------------------------------------------------------------------

// `fast-compiler.md` §8 lists every flag on `Cli.Common`, `Cli.Check` and
// `Cli.Build` and says, for each, why it is IN the key or OUT of it. The rows
// above falsify the "in" half — change it and the key moves. These are the
// "out" half, and the one a key that was too WIDE would fail: a flag that is
// out of the key must not reach a cached byte either, or two builds that
// differ only in it would write two different entries under one name and the
// later one would win by accident. One flag per test, each a pair of runs
// into two cache directories whose every entry must agree.
//
// The backend's are the interesting ones. They are out of the key because no
// emitted byte is cached, and nothing but these says so out loud.
// `--allow-debug` is the fourth and it gets its own scenario below, because
// saying anything about it needs a project that reaches `Debug` — on this one
// the flag lifts a refusal that never fires.

/// Run the project once with `a` and once with `b`, each into a cache of its
/// own, and require the two caches to be identical.
fn expectFlagOutOfKey(what: []const u8, is_build: bool, a: []const []const u8, b: []const []const u8) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
    try runFlagged(&w, arena, is_build, a, "ca");
    try runFlagged(&w, arena, is_build, b, "cb");
    expectSameCache(&w, arena, "ca", "cb") catch |err| {
        std.debug.print("{s} reached a cached byte and must not\n", .{what});
        return err;
    };
}

test "--jobs is not in the key and cannot change one byte of one entry" {
    // Output is identical for every `n`, and keying on it would hide the
    // very bug the determinism rule forbids.
    try expectFlagOutOfKey("--jobs", false, &.{"--jobs=1"}, &.{"--jobs=8"});
}

test "--diagnostics is not in the key and cannot change one byte of one entry" {
    // A rendering flag: it selects how a message is printed.
    try expectFlagOutOfKey("--diagnostics", false, &.{ "--jobs=1", "--diagnostics=text" }, &.{ "--jobs=1", "--diagnostics=json" });
}

test "--explain is not in the key and cannot change one byte of one entry" {
    try expectFlagOutOfKey("--explain", false, &.{"--jobs=1"}, &.{ "--jobs=1", "--explain" });
}

test "--roundtrip-interfaces is not in the key and cannot change one byte of one entry" {
    // A round trip must produce the same record, and exempting it would
    // excuse it from the round-trip tests.
    try expectFlagOutOfKey("--roundtrip-interfaces", false, &.{"--jobs=1"}, &.{ "--jobs=1", "--roundtrip-interfaces" });
}

test "--roundtrip-dispatch is not in the key and cannot change one byte of one entry" {
    try expectFlagOutOfKey("--roundtrip-dispatch", false, &.{"--jobs=1"}, &.{ "--jobs=1", "--roundtrip-dispatch" });
}

test "--root naming the root a module already has cannot change one byte of one entry" {
    // `--root` reaches the key through the module name and nowhere else.
    try expectFlagOutOfKey("--root", false, &.{"--jobs=1"}, &.{ "--jobs=1", "--root=src" });
}

test "--out is not in the key and cannot change one byte of one entry" {
    try expectFlagOutOfKey("--out", true, &.{ "--jobs=1", "--out=outa" }, &.{ "--jobs=1", "--out=outb" });
}

test "--release is not in the key and cannot change one byte of one entry" {
    try expectFlagOutOfKey("--release", true, &.{ "--jobs=1", "--out=oute" }, &.{ "--jobs=1", "--out=outf", "--release" });
}

test "--allow-debug lifts a refusal raised after the cache was written" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The fourth backend flag, and the one whose classification is sharpest.
    // `backend.md` §9 refuses a `--release` build that still reaches
    // `Debug`; `--allow-debug` lifts that refusal. It cannot touch a cached
    // byte, and not merely because no emitted byte is cached: the refusal is
    // raised in `Emit.run`, after `eliminate` and long after `Session.run`
    // returned, and `Session.run` is where the entries are written. By the
    // time the flag is consulted the cache is already on disk.
    //
    // So the two runs differ in EXIT CODE — 1 against 0 — and agree on every
    // entry, which is a stronger statement than the table's rows can make.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    try w.write("src/Noisy.beni",
        \\pub shout : Int → Int
        \\shout n =
        \\    Debug.log "shouting" n
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const refused = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--library", "--release", "--jobs=1", "--out=refused", "--cache-dir=ra", "src" },
        "refused.json",
    );
    const allowed = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--library", "--release", "--jobs=1", "--allow-debug", "--out=allowed", "--cache-dir=rb", "src" },
        "allowed.json",
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The fixture really does divide the two, or the rest proves nothing.
    try testing.expectEqual(@as(u8, 1), refused.result.exit_code);
    try testing.expectEqual(@as(u8, 0), allowed.result.exit_code);
    try testing.expect(std.mem.indexOf(u8, refused.result.stderr, "debug_in_release") != null or
        std.mem.indexOf(u8, refused.result.stderr, "DEBUG") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The refused build wrote its entries all the same, and they are the
    // allowed build's entries byte for byte.
    try testing.expect(refused.counters.bytes > 0);
    try expectSameCache(&w, arena, "ra", "rb");

    // …and the refused build's own cache is warm for the next run of either
    // spelling, which is what "the cache was already on disk" means.
    const again = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--library", "--release", "--jobs=1", "--allow-debug", "--out=again", "--cache-dir=ra", "src" },
        "again.json",
    );
    try testing.expectEqual(@as(u8, 0), again.result.exit_code);
    try testing.expectEqual(@as(u64, 0), again.counters.checked);
}

/// `Wide.beni`: `pub type T a0 … a<n-1> = Mk a0 … a<n-1>`. And `Main.beni`:
/// `x` and `y` of it, all fields `1 … n` except `y`'s last, which is 0, and
/// a `main` printing `x == x`, `x == y`, `y < x` and `x < y` — then
/// `extra`, so a second version of `Main` can differ from the first.
fn wideImportProject(w: *World, gpa: std.mem.Allocator, n: usize, extra: []const u8) !void {
    var wide: std.Io.Writer.Allocating = .init(gpa);
    defer wide.deinit();
    try wide.writer.writeAll("pub type T");
    for (0..n) |i| try wide.writer.print(" a{d}", .{i});
    try wide.writer.writeAll("\n    = Mk");
    for (0..n) |i| try wide.writer.print(" a{d}", .{i});
    try wide.writer.writeAll("\n");
    try w.write("Wide.beni", wide.written());

    var main: std.Io.Writer.Allocating = .init(gpa);
    defer main.deinit();
    const out = &main.writer;
    try out.writeAll("import Node exposing (Program)\nimport Wide\n\n\nx =\n    Wide.Mk");
    for (1..n + 1) |i| try out.print(" {d}", .{i});
    try out.writeAll("\n\n\ny =\n    Wide.Mk");
    for (1..n + 1) |i| try out.print(" {d}", .{if (i == n) 0 else i});
    try out.print(
        \\
        \\
        \\
        \\show : Bool → String
        \\show b =
        \\    if b then
        \\        "True"
        \\
        \\    else
        \\        "False"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ show (x == x), show (x == y), show (y < x), show (x < y){s} ]
        \\
    , .{extra});
    try w.write("Main.beni", main.written());
}

// `static-dispatch-spike.md` §9.2's wide form (A.87) across a module
// boundary, which needs interface v3's `u16` arity: past 4 096 evidence
// entries a derived function takes ONE array `$m`, and every caller packs
// the same count. `T` has 4 097 parameters, the narrowest count that takes
// the array, so `Wide` emits `T`'s `eq` and `compare` in the wide form, and
// `Main` — which counts the entries from what it imported — must pack 4 097.
// An importer that read the count through a `u8`, or fell back to
// positional evidence, would call `Wide$T$$eq` with 4 097 arguments: exit 0,
// then `TypeError: $m[0] is not a function` at run time.
//
// The count an importer uses on a warm build is the one a cached RECORD
// states, and there are two such records, so two tests, each a build over
// a cache directory a `check` filled:
//   - warm: nothing is checked, and `Main`'s cached dispatch table states
//     the count;
//   - `Main` edited: `Wide` comes from the cache and `Main` is checked
//     against `Wide`'s loaded interface, which states it.
// A cold build would take the count from the interface in memory, which no
// cached record states, so the cache is filled by a `check` of both modules
// instead; the switch itself, in one module, is `abuse_wide_test.zig`'s.
// Both builds are development builds: `--release` renames the same lowered
// calls and has no branch of its own at the switch. Which module an edit
// re-checks is `cutoff_test.zig`'s, and each build here costs a whole build
// of a type 4 097 wide — which is why the two are two tests (the budget).
const WidePass = struct {
    what: []const u8,
    edit: ?[]const u8,
    checked: u64,
    hits_at_least: u64,
    expected: []const u8,
};

fn wideImportPass(pass: WidePass) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const n = 4_097;
    try wideImportProject(&w, arena, n, "");
    const cold = try runCounted(&w, arena, &.{ "check", "--platform=node", "--cache-dir=cache", "--jobs=1", "Main.beni", "Wide.beni" }, "cold.json");
    try testing.expectEqual(@as(u8, 0), cold.result.exit_code);
    try testing.expectEqual(@as(u64, 0), cold.counters.hits);
    if (pass.edit) |extra| try wideImportProject(&w, arena, n, extra);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--out=out", "--cache-dir=cache", "--jobs=1", "Main.beni", "Wide.beni" },
        "pass.json",
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (built.result.exit_code != 0) std.debug.print("{s}: {s}\n", .{ pass.what, built.result.stderr });
    try testing.expectEqual(@as(u8, 0), built.result.exit_code);
    try testing.expectEqualStrings("", built.result.stderr);
    try w.expectProgram(world.entry_file, .{ .stdout = pass.expected });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Which modules the build checked and which it took from the cache: the
    // reason for two tests, not a detail of them.
    if (built.counters.checked != pass.checked or built.counters.hits < pass.hits_at_least) {
        std.debug.print("{s}: checked {d}, hits {d}\n", .{ pass.what, built.counters.checked, built.counters.hits });
        return error.UnexpectedCacheUse;
    }

    // The importer really does pack the array: one `$m` of 4 097 entries per
    // call, never 4 097 arguments.
    const main_js = try w.read("out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, main_js, "Wide$T$$eq([") != null);
    try testing.expect(std.mem.indexOf(u8, main_js, "Wide$T$$compare([") != null);
}

const wide_expected = "True\nFalse\nTrue\nFalse\n";

test "an imported type of 4 097 parameters compares in the wide form from a warm cache" {
    try wideImportPass(.{ .what = "warm", .edit = null, .checked = 0, .hits_at_least = 2, .expected = wide_expected });
}

test "an imported type of 4 097 parameters compares in the wide form with only the importer edited" {
    try wideImportPass(.{ .what = "Main edited", .edit = ", show (y == y)", .checked = 1, .hits_at_least = 1, .expected = wide_expected ++ "True\n" });
}

fn runFlagged(
    w: *World,
    arena: std.mem.Allocator,
    is_build: bool,
    flags: []const []const u8,
    dir: []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    if (is_build) {
        try argv.appendSlice(arena, &.{ "build", "--platform=node", "--library" });
    } else {
        try argv.append(arena, "check");
    }
    try argv.appendSlice(arena, flags);
    try argv.append(arena, try std.fmt.allocPrint(arena, "--cache-dir={s}", .{dir}));
    try argv.append(arena, "src");
    const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });
    if (r.exit_code != 0) {
        std.debug.print("a flag-classification run exited {d}:\n{s}\n", .{ r.exit_code, r.stderr });
        return error.CheckFailed;
    }
}

/// Two cache directories hold the same entries under the same names, with
/// the same bytes. Not "the entries a test thought to name": an entry that
/// appears under one configuration and not the other is exactly the
/// difference this asserts the absence of.
fn expectSameCache(w: *World, arena: std.mem.Allocator, a: []const u8, b: []const u8) !void {
    const left = try w.listFiles(a);
    const right = try w.listFiles(b);
    try testing.expect(left.len > 0);
    try testing.expectEqual(left.len, right.len);
    for (left, right) |x, y| {
        try testing.expectEqualStrings(x, y);
        const xb = try w.read(try std.fs.path.join(arena, &.{ a, x }));
        const yb = try w.read(try std.fs.path.join(arena, &.{ b, y }));
        try testing.expectEqualStrings(xb, yb);
    }
}

/// `--cache-keys` for a project that does not compile. The keys exist all
/// the same — the firewall's question is about inputs, not about success —
/// and a scenario that asserts "this module has no entry" needs its key.
fn baselineKeysAllowingErrors(w: *World, arena: std.mem.Allocator) ![]const Entry {
    const r = try w.runWith(&.{ "check", "--cache-keys", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    return parseKeys(arena, r.stdout);
}

/// `v<n>/<kk>/<rest>.bec` for a key's 32 hex digits, as `listFiles` spells it.
fn entryPathFor(digits: []const u8) [40]u8 {
    var out: [40]u8 = undefined;
    @memcpy(out[0..3], "v1/");
    @memcpy(out[3..5], digits[0..2]);
    out[5] = '/';
    @memcpy(out[6..36], digits[2..]);
    @memcpy(out[36..40], ".bec");
    return out;
}

fn expectEntry(w: *World, files: []const []const u8, digits: []const u8) !void {
    _ = w;
    const want = entryPathFor(digits);
    for (files) |f| {
        if (std.mem.eql(u8, f, &want)) return;
    }
    std.debug.print("no cache entry for {s} (expected {s})\n", .{ digits, &want });
    return error.MissingEntry;
}

fn expectNoEntry(w: *World, files: []const []const u8, digits: []const u8) !void {
    _ = w;
    const unwanted = entryPathFor(digits);
    for (files) |f| {
        if (std.mem.eql(u8, f, &unwanted)) {
            std.debug.print("a cache entry exists for {s} and must not\n", .{digits});
            return error.UnexpectedEntry;
        }
    }
}

/// `--iface-hash`'s lines, in `--cache-keys`' shape, so the two can be
/// compared by the same helper. Several rows above turn on the difference
/// between the two quantities, and stating it in the fixture is what keeps
/// the module key's cost honest.
fn ifaceHashes(w: *World, arena: std.mem.Allocator) ![]const Entry {
    const r = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    if (r.exit_code != 0) {
        std.debug.print("check --iface-hash exited {d}:\n{s}\n", .{ r.exit_code, r.stderr });
        return error.CheckFailed;
    }
    return parseKeys(arena, r.stdout);
}

// ---------------------------------------------------------------------------
// The FILE key, and its edit-scenario table (`plans/m4-2.md` §9.1)
// ---------------------------------------------------------------------------
//
// **The point of every row below is the DIVERGENCE between the two key
// columns**, which is why the front end needs a second key at all. A module key folds
// every import's key, so a body edit in a leaf moves three of them; a file
// key holds one file's lowering inputs and nothing else, so the same edit
// moves one. The leaf re-lowers; its importers re-check WITHOUT re-lowering.
//
// Asserted against `--frontend-keys` here, before a byte reaches disk, in
// exactly the way `--cache-keys` pins the module table above. The counters
// can then only confirm what this file already fixed.

/// `beni check --frontend-keys <flags> <paths>`, parsed. One
/// `<path> <32 hex digits>` line per FILE, sorted by path.
fn fileKeysOf(w: *World, arena: std.mem.Allocator, extra: []const []const u8) ![]const Entry {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "check", "--frontend-keys" });
    try argv.appendSlice(arena, extra);
    const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });
    if (r.exit_code != 0) {
        std.debug.print("check --frontend-keys exited {d}:\n{s}\n", .{ r.exit_code, r.stderr });
        return error.CheckFailed;
    }
    return parseKeys(arena, r.stdout);
}

fn baselineFileKeys(w: *World, arena: std.mem.Allocator) ![]const Entry {
    return fileKeysOf(w, arena, &.{ "--jobs=1", "src" });
}

const leaf_file = "src/Leaf.beni";
const mid_file = "src/Mid.beni";
const top_file = "src/Top.beni";
const app_files = [_][]const u8{ leaf_file, mid_file, top_file };

test "--frontend-keys prints one sorted line per FILE, core included, and no two agree" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const keys = try baselineFileKeys(&w, arena);
    try testing.expect(lookup(keys, leaf_file) != null);
    try testing.expect(lookup(keys, mid_file) != null);
    try testing.expect(lookup(keys, top_file) != null);
    try testing.expect(lookup(keys, "core/Basics.beni") != null);
    // The app's three and the eight core modules a check always lowers;
    // a core module nothing imports has no front end and no key.
    try testing.expect(keys.len >= 11);
    try testing.expect(lookup(keys, "core/Dict.beni") == null);

    // A recipe that dropped the module name would give every file of one
    // project the same key, and every row below would still pass.
    for (keys, 0..) |a, i| {
        for (keys[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.digits, b.digits)) {
                std.debug.print("{s} and {s} share a file key\n", .{ a.name, b.name });
                return error.KeysCollided;
            }
        }
    }

    // It does not depend on `--jobs`: the key is computed on whichever
    // worker took the file, and which worker that is must be unobservable.
    try expectMoved("--jobs=8", keys, try fileKeysOf(&w, arena, &.{ "--jobs=8", "src" }), &.{});
    // …and it is hidden, like every flag of its family.
    const help = try w.runWith(&.{"--help"}, .{ .raw_diagnostics = true });
    try testing.expect(std.mem.indexOf(u8, help.stdout, "--frontend-keys") == null);
    // `build` does not take it, for `--cache-keys`' reason: stdout is the
    // product, and a build's product is the files it wrote.
    const on_build = try w.runWith(&.{ "build", "--platform=node", "--frontend-keys", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 2), on_build.exit_code);
}

test "file-key rows 1-5: an edit in Leaf moves LEAF's file key and no other" {
    // Rows 1 to 5 of `plans/m4-2.md` §9.1 in one fixture, because they are
    // one claim with five kinds of edit: whatever was done to `Leaf`, only
    // `Leaf`'s front end is thrown away — while the module table above shows
    // all three modules re-checking for the same edits.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base_files = try baselineFileKeys(&w, arena);
    const base_modules = try baselineKeys(&w, arena);

    // Nothing changed. Rewritten with identical bytes, so a key that moved
    // here would be one that read an mtime.
    try w.write(leaf_file, leaf_source);
    try expectMoved("nothing changed, file keys", base_files, try baselineFileKeys(&w, arena), &.{});

    // `modules` is where the CUTOFF shows: a file-key move is a re-lowering
    // and a module-key move is a re-check, and the second is far
    // rarer than the first. Only the row that moves the interface hash
    // reaches the importers at all.
    const Row = struct { what: []const u8, source: []const u8, modules: []const []const u8 = &.{"app:Leaf"} };
    const rows = [_]Row{
        // A body edit.
        .{ .what = "a body edit", .source =
        \\pub foreign pure twice : Int → Int
        \\
        \\
        \\pub one : Int
        \\one =
        \\    2
        \\
        },
        // A comment only. A comment is a token and `Bir` carries
        // `doc_start`/`doc_end`, so the file key MUST move — and this row
        // pins that it moves for `Leaf` ALONE. What it costs is one file's
        // lex, parse and lower; doing better needs a form-insensitive key.
        .{ .what = "a comment only", .source = "-- a comment nobody reads\n" ++ leaf_source },
        // Whitespace only — every token `start` after it moves.
        .{ .what = "whitespace only", .source = "\n" ++ leaf_source },
        // A `pub` signature — one ADDED, so `Mid` still compiles and
        // the row measures the key rather than a type error.
        .{ .what = "a pub signature", .modules = &all_app, .source = leaf_source ++
            \\
            \\pub extra : Int
            \\extra =
            \\    3
            \\
        },
    };
    for (rows) |row| {
        try w.write(leaf_file, leaf_source);
        const before_files = try baselineFileKeys(&w, arena);
        const before_modules = try baselineKeys(&w, arena);
        try w.write(leaf_file, row.source);
        try expectMoved(row.what, before_files, try baselineFileKeys(&w, arena), &.{leaf_file});
        // The divergence, stated on the same edit — and it runs the other
        // way for three rows of four: one file key moves and no
        // module key but the leaf's own.
        try expectMoved(row.what, before_modules, try baselineKeys(&w, arena), row.modules);
    }
    try w.write(leaf_file, leaf_source);
    try expectMoved("restored", base_files, try baselineFileKeys(&w, arena), &.{});
    try expectMoved("restored", base_modules, try baselineKeys(&w, arena), &.{});
}

test "file-key rows 6 and 7: the name is an input and the path is not" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    const base = try baselineFileKeys(&w, arena);
    const leaf_key = lookup(base, leaf_file).?;

    // Row 7: `Leaf` MOVED to another directory, same module name and the
    // same bytes. Its key does not move — the proof that the recipe holds no
    // path, and what makes `beni check src` and
    // `cd .. && beni check proj/src` share one artifact.
    try w.write("src2/Leaf.beni", leaf_source);
    try w.write("src2/beni.json", manifest);
    const moved = try fileKeysOf(&w, arena, &.{ "--jobs=1", "--root=src2", "src2/Leaf.beni" });
    try testing.expectEqualStrings(leaf_key, lookup(moved, "src2/Leaf.beni").?);

    // Row 6: renamed to `Sprout`, bytes IDENTICAL. `Lower.Options.module_name`
    // is an input to lowering — `self_import` reads it — so identical bytes
    // under a new name are a new artifact.
    try w.write("src2/Sprout.beni", leaf_source);
    const renamed = try fileKeysOf(&w, arena, &.{ "--jobs=1", "--root=src2", "src2/Sprout.beni" });
    const sprout_key = lookup(renamed, "src2/Sprout.beni").?;
    if (std.mem.eql(u8, leaf_key, sprout_key)) {
        std.debug.print("`Sprout` and `Leaf` share a file key though their module names differ\n", .{});
        return error.KeysCollided;
    }

    // And the claim the whole slice's safety rests on: **two DIFFERENT
    // modules with byte-identical sources do not share an artifact**,
    // because the key holds the module name.
    try w.write("src/Twin.beni", leaf_source);
    const with_twin = try fileKeysOf(&w, arena, &.{ "--jobs=1", "src" });
    if (std.mem.eql(u8, lookup(with_twin, "src/Twin.beni").?, lookup(with_twin, leaf_file).?)) {
        std.debug.print("`Twin` and `Leaf` share a file key though their module names differ\n", .{});
        return error.KeysCollided;
    }
    // …and adding it moved nothing that already existed.
    try expectMoved("a new unrelated file", base, with_twin, &.{"src/Twin.beni"});
}

test "file-key rows 11 to 15: which flags reach lowering and which do not" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);
    const base = try baselineFileKeys(&w, arena);
    const base_modules = try baselineKeys(&w, arena);

    // Row 11: `--pattern-budget` does not reach lowering, so no file key
    // moves — while every MODULE key does, because exhausting the budget is
    // an error of that module. This row is why the file key is a second
    // recipe and not a subset computed from the first.
    try expectMoved(
        "--pattern-budget, file keys",
        base,
        try fileKeysOf(&w, arena, &.{ "--jobs=1", "--pattern-budget=5000", "src" }),
        &.{},
    );
    try expectEveryKeyMoved(
        "--pattern-budget, module keys",
        base_modules,
        try keysOf(&w, arena, &.{ "--jobs=1", "--pattern-budget=5000", "src" }),
    );

    // A sibling `.js` is not a lowering input, so editing one moves
    // no file key at all — and only the declaring module's own
    // key: the sibling hash is one of that module's OWN terms and no importer
    // can observe it through the record or the digest.
    try w.write("src/Leaf.js", "export const twice = (n) => n + n;\n");
    try expectMoved("an edited sibling .js", base, try baselineFileKeys(&w, arena), &.{});
    try expectMoved("an edited sibling .js", base_modules, try baselineKeys(&w, arena), &.{"app:Leaf"});
    try w.write("src/Leaf.js", leaf_sibling);

    // Row 12: a different compiler build id discards everything, file keys
    // included — the mechanism that makes "a format change is a version bump
    // and a cache discard" true for this file too.
    try expectEveryFileKeyMoved(
        "--cache-build-id",
        base,
        try fileKeysOf(&w, arena, &.{ "--jobs=1", "--cache-build-id=other", "src" }),
    );

    // Row 13: `--core` changes `Lower.Options.core` for every APP file, so
    // every app file's key moves — and core's own does not, because a core
    // module is core either way.
    {
        const with_core = try fileKeysOf(&w, arena, &.{ "--jobs=1", "--core", "src" });
        var moved: std.ArrayList([]const u8) = .empty;
        defer moved.deinit(testing.allocator);
        for (base) |b| {
            const now = lookup(with_core, b.name) orelse continue;
            if (!std.mem.eql(u8, b.digits, now)) try moved.append(testing.allocator, b.name);
        }
        std.mem.sort([]const u8, moved.items, {}, lessThanText);
        var want: std.ArrayList([]const u8) = .empty;
        defer want.deinit(testing.allocator);
        try want.appendSlice(testing.allocator, &app_files);
        std.mem.sort([]const u8, want.items, {}, lessThanText);
        if (!sameNames(moved.items, want.items)) {
            std.debug.print("--core moved {d} file keys, expected the three app files\n", .{moved.items.len});
            for (moved.items) |m| std.debug.print("  {s}\n", .{m});
            return error.WrongKeysMoved;
        }
    }
}

fn expectEveryFileKeyMoved(what: []const u8, before: []const Entry, after: []const Entry) !void {
    try testing.expectEqual(before.len, after.len);
    var saw_core = false;
    for (before) |b| {
        const now = lookup(after, b.name) orelse {
            std.debug.print("{s}: {s} vanished\n", .{ what, b.name });
            return error.ModuleVanished;
        };
        if (std.mem.eql(u8, b.digits, now)) {
            std.debug.print("{s}: {s}'s file key did not move\n", .{ what, b.name });
            return error.KeyDidNotMove;
        }
        if (std.mem.startsWith(u8, b.name, "core/")) saw_core = true;
    }
    try testing.expect(saw_core);
}

// checker-v2.md §11.2, §14.2: a derived function's context is inferred
// (one entry per parameter that holds a value) and PUBLISHED, and a cache hit
// installs the record without recomputing it. So an edit to the module that
// declares a payload's method moves what a dependent's derived function
// takes; the warm build must re-derive it and write exactly what a cold build
// of the edited project writes, and an edit that moves no interface must be
// cut off with the same output.
fn writeDerivedProject(w: *World, holder: []const u8) !void {
    try w.write("src/H.beni", holder);
    try w.write("src/Keyed.beni",
        \\pub type Keyed
        \\    = Keyed Int String
        \\
        \\
        \\pub key : Keyed, () → Int
        \\key k u =
        \\    case k of
        \\        Keyed n _ →
        \\            n
        \\
    );
    // `Outer`'s context is `(0, key)` with the first `H`, `(0, eq)` with the
    // second; `Hidden` is private and reached only through `make`.
    try w.write("src/Outer.beni",
        \\import H
        \\
        \\
        \\pub type Outer a
        \\    = Outer (H.Holder a)
        \\
        \\
        \\type Hidden a
        \\    = Hidden (Outer a)
        \\
        \\
        \\pub make : a → Hidden a
        \\make x =
        \\    Hidden (Outer (H.Holder x))
        \\
    );
    try w.write("src/Main.beni",
        \\import H
        \\import Keyed
        \\import Node exposing (Program)
        \\import Outer
        \\
        \\
        \\show : Bool → String
        \\show value =
        \\    if value then
        \\        "True"
        \\
        \\    else
        \\        "False"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines
        \\        [ show (Outer.Outer (H.Holder (Keyed.Keyed 1 "a")) == Outer.Outer (H.Holder (Keyed.Keyed 1 "b")))
        \\        , show (Outer.make (Keyed.Keyed 2 "a") == Outer.make (Keyed.Keyed 2 "b"))
        \\        ]
        \\
    );
}

const holder_by_key =
    \\pub type Holder a
    \\    = Holder a
    \\
    \\
    \\pub eq : Holder a, Holder a → Bool
    \\    where a.key : a, () → Int
    \\eq (Holder x) (Holder y) =
    \\    x.key () == y.key ()
    \\
;

const holder_by_eq =
    \\pub type Holder a
    \\    = Holder a
    \\
    \\
    \\pub eq : Holder a, Holder a → Bool
    \\    where a.eq : a, a → Bool
    \\eq (Holder x) (Holder y) =
    \\    x == y
    \\
;

test "a warm build after an edit that moves a derived context writes what a cold build writes" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeDerivedProject(&w, holder_by_key);
    const build = [_][]const u8{ "build", "--platform=node", "--jobs=1", "--diagnostics=json" };

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // Cold, then the payload's method edited, warm over the same cache; the
    // same edited project cold without one.
    const first = try runCounted(&w, arena, &(build ++ [_][]const u8{ "--cache-dir=c", "--out=first", "src" }), "first.json");
    try w.write("src/H.beni", holder_by_eq);
    const warm = try runCounted(&w, arena, &(build ++ [_][]const u8{ "--cache-dir=c", "--out=warm", "src" }), "warm.json");
    const cold = try runCounted(&w, arena, &(build ++ [_][]const u8{ "--no-cache", "--out=cold", "src" }), "cold.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]Run{ first, warm, cold }) |r| {
        try testing.expectEqual(@as(u8, 0), r.result.exit_code);
        try testing.expectEqualStrings("", r.result.stderr);
    }
    // By `key` both pairs agree; by structural `eq`, neither does.
    try w.expectProgram("first/_main.mjs", .{ .stdout = "True\nTrue\n" });
    try w.expectProgram("warm/_main.mjs", .{ .stdout = "False\nFalse\n" });
    // `H`, and `Outer` and `Main` behind its moved interface, re-checked;
    // `Keyed` and core were hits.
    try testing.expectEqual(@as(u64, 3), warm.counters.misses);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectSameTree(&w, arena, "cold", "warm");
}

test "a comment in the module that declares a payload's method is cut off and writes what a cold build writes" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // An edit that moves no interface: `H` is re-checked alone, and the
    // dependents' cached evidence — derived through `H`'s method — is used
    // as it was.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeDerivedProject(&w, holder_by_eq);
    // Without maps: a comment moves every line below it, which is what a
    // source map is for (`backend.md` §11), and this is a claim about the
    // JavaScript.
    const build = [_][]const u8{ "build", "--platform=node", "--jobs=1", "--diagnostics=json", "--no-source-maps" };

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const cold = try runCounted(&w, arena, &(build ++ [_][]const u8{ "--cache-dir=c", "--out=cold", "src" }), "cold.json");
    try w.write("src/H.beni", "-- a comment moves no interface\n" ++ holder_by_eq);
    const comment = try runCounted(&w, arena, &(build ++ [_][]const u8{ "--cache-dir=c", "--out=comment", "src" }), "comment.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]Run{ cold, comment }) |r| {
        try testing.expectEqual(@as(u8, 0), r.result.exit_code);
        try testing.expectEqualStrings("", r.result.stderr);
    }
    try testing.expectEqual(@as(u64, 1), comment.counters.misses);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A comment changes no emitted byte, so the cold tree of the uncommented
    // source is the cold tree of the commented one.
    try expectSameTree(&w, arena, "cold", "comment");
}

// ┌─────────────────────────────────────────────────────────────────────────┐
// │ A warm rebuild after every edit of a dependency is a cold build         │
// └─────────────────────────────────────────────────────────────────────────┘
//
// Three modules — `M`, `N` importing it, and
// `Main` importing both (none for a `check`-only case) — and a sequence of
// versions of `M`. One test per edit: the version before it is built cold
// into a cache, then the version after it is built WARM over that cache and
// cold with `--no-cache`, and the two must agree on the exit code, stdout,
// stderr and every byte written. What each version must do is pinned too, so
// a case cannot pass by failing the same way twice. One more test goes back
// to the first version over a cache that has seen the second: it re-checks
// nothing and runs no derived-context fixpoint, because a cache hit installs
// the published answer.

const EditCase = struct {
    name: []const u8,
    n: []const u8,
    /// Null for a case only `check` can run (a schema: `build` refuses one
    /// before emit, schema.md).
    main: ?[]const u8 = null,
    /// `M`'s versions, the first built cold.
    states: []const State,

    const State = struct { m: []const u8, expect: Expect };
    const Expect = union(enum) {
        /// The build succeeds and the program prints this.
        prints: []const u8,
        /// The command fails (exits 0 when empty) with these codes, in order.
        codes: []const []const u8,
    };
};

fn editArgs(arena: std.mem.Allocator, case: EditCase, cache: ?[]const u8, jobs: []const u8, out: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, if (case.main != null) "build" else "check");
    if (case.main != null) {
        try argv.append(arena, "--platform=node");
        try argv.append(arena, try std.fmt.allocPrint(arena, "--out={s}", .{out}));
    }
    try argv.append(arena, jobs);
    try argv.append(arena, "--diagnostics=json");
    try argv.append(arena, if (cache) |dir| try std.fmt.allocPrint(arena, "--cache-dir={s}", .{dir}) else "--no-cache");
    try argv.append(arena, "src");
    return argv.items;
}

/// The codes of a `--diagnostics=json` stderr, in order.
fn codesOf(arena: std.mem.Allocator, stderr: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, stderr, " \r\n");
    if (trimmed.len == 0) return &.{};
    const Row = struct { code: []const u8 };
    const rows = try std.json.parseFromSliceLeaky([]Row, arena, trimmed, .{ .ignore_unknown_fields = true });
    const out = try arena.alloc([]const u8, rows.len);
    for (rows, out) |r, *o| o.* = r.code;
    return out;
}

fn expectOutcome(w: *World, arena: std.mem.Allocator, case: EditCase, state: usize, r: Run, out: []const u8) !void {
    errdefer std.debug.print("{s}: version {d} of M\n", .{ case.name, state });
    switch (case.states[state].expect) {
        .prints => |text| {
            try testing.expectEqual(@as(u8, 0), r.result.exit_code);
            try w.expectProgram(try std.fmt.allocPrint(arena, "{s}/_main.mjs", .{out}), .{ .stdout = text });
        },
        .codes => |codes| {
            try testing.expectEqual(@as(u8, if (codes.len == 0) 0 else 1), r.result.exit_code);
            const got = try codesOf(arena, r.result.stderr);
            try testing.expectEqual(codes.len, got.len);
            for (codes, got) |want, have| try testing.expectEqualStrings(want, have);
            if (case.main != null) try testing.expect(!w.exists(out));
        },
    }
}

/// Version `from` of `M` built cold into a cache; then version `to` built
/// warm over it and cold with `--no-cache`, which must agree on every stream
/// and every byte written, and do what version `to` must.
fn runEditStep(case: EditCase, from: usize, to: usize) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/N.beni", case.n);
    if (case.main) |text| try w.write("src/Main.beni", text);
    try w.write("src/M.beni", case.states[from].m);
    const first = try runCounted(&w, arena, try editArgs(arena, case, "cache", "--jobs=1", "first"), "first.json");
    // The first version is pinned here; every later one by the test of the
    // edit that leads to it.
    if (from == 0) try expectOutcome(&w, arena, case, from, first, "first");
    try testing.expectEqual(@as(u64, 0), first.counters.hits);
    // The check of `M` and `N` ran: that is what a hit must not do again.
    // (Core's derived contexts come from the checked core the binary
    // carries, so `derived` counts the project's own, which may be none.)
    try testing.expect(first.counters.checked >= 2);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    errdefer std.debug.print("{s}: version {d} of M after version {d}\n", .{ case.name, to, from });
    try w.write("src/M.beni", case.states[to].m);
    const warm = try runCounted(&w, arena, try editArgs(arena, case, "cache", "--jobs=1", "warm"), "warm.json");
    const cold = try runCounted(&w, arena, try editArgs(arena, case, null, "--jobs=1", "cold"), "cold.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(cold.result.exit_code, warm.result.exit_code);
    try testing.expectEqualStrings(cold.result.stdout, warm.result.stdout);
    try testing.expectEqualStrings(cold.result.stderr, warm.result.stderr);
    // A version not built before re-checks at least `M`, and something is
    // always installed rather than checked (core, from the checked core).
    try testing.expect(warm.counters.checked >= 1);
    try testing.expect(warm.counters.hits + warm.counters.embedded_modules > 0);
    try expectOutcome(&w, arena, case, to, warm, "warm");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    if (case.main != null and warm.result.exit_code == 0) try expectSameTree(&w, arena, "cold", "warm");
}

test "a warm build of a markup program after a view's markup is edited writes what a cold build writes" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The markup a lowering compiles is read from the checked record's
    // markup section and the vocabulary's interface rows
    // (`checker-v2.md` §25.7–§25.8), both of which a warm build loads from
    // the cache: a warm build that lowered markup from anything the cache
    // does not carry would write another page than a cold one. The edit is
    // to `View`'s markup alone, so `Main` — which calls the component — is a
    // hit and only `View` is checked again.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const view =
        \\import Html exposing (Html)
        \\
        \\
        \\pub card : { title : String, items : List String } → Html msg
        \\card props =
        \\    <section class={[ ( "card", True ), ( "empty", props.items == [] ) ]}>
        \\        <h2>{props.title}</h2>
        \\        <ul><For each={props.items}>{λitem → <li>{item}</li>}</For></ul>
        \\    </section>
        \\
    ;
    try w.write("View.beni", view);
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\import Ssr
        \\import View
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print (Ssr.render (<View.card title="Hi" items={[ "a", "b" ]} />))
        \\
    );
    const first = try runCounted(&w, arena, &.{ "build", "--platform=node", "--out=first", "--cache-dir=cache", "--jobs=1", "Main.beni", "View.beni" }, "first.json");
    try testing.expectEqual(@as(u8, 0), first.result.exit_code);
    try w.expectProgram("first/_main.mjs", .{ .stdout = "<section class=\"card\"><h2>Hi</h2><ul><li>a</li><li>b</li></ul></section>\n" });
    try w.write("View.beni", try std.mem.replaceOwned(u8, arena, view, "<li>{item}</li>", "<li class=\"item\">{item}!</li>"));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const warm = try runCounted(&w, arena, &.{ "build", "--platform=node", "--out=warm", "--cache-dir=cache", "--jobs=1", "Main.beni", "View.beni" }, "warm.json");
    const cold = try w.runWith(&.{ "build", "--platform=node", "--out=cold", "--no-cache", "--jobs=1", "Main.beni", "View.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    try testing.expectEqual(@as(u8, 0), cold.exit_code);
    try testing.expectEqualStrings(cold.stderr, warm.result.stderr);
    // Only `View` is checked again: editing markup moves no interface.
    try testing.expectEqual(@as(u64, 1), warm.counters.checked);
    try testing.expect(warm.counters.hits > 0);
    try w.expectProgram("warm/_main.mjs", .{ .stdout = "<section class=\"card\"><h2>Hi</h2><ul><li class=\"item\">a!</li><li class=\"item\">b!</li></ul></section>\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectSameTree(&w, arena, "cold", "warm");
}

test "a warm rebuild back to a version the cache has seen checks nothing, derives nothing, and writes what it wrote" {
    // Version 0 of `M` cold, version 1 warm, then version 0 again over the
    // same cache: every entry version 0 wrote is still there, so nothing is
    // re-checked and no derived-context fixpoint runs.
    const case = k_cases[0];
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/N.beni", case.n);
    try w.write("src/Main.beni", case.main.?);
    try w.write("src/M.beni", case.states[0].m);
    const first = try runCounted(&w, arena, try editArgs(arena, case, "cache", "--jobs=1", "first"), "first.json");
    try testing.expectEqual(@as(u8, 0), first.result.exit_code);
    try w.write("src/M.beni", case.states[1].m);
    const edited = try runCounted(&w, arena, try editArgs(arena, case, "cache", "--jobs=1", "edited"), "edited.json");
    try testing.expectEqual(@as(u8, 0), edited.result.exit_code);
    try w.write("src/M.beni", case.states[0].m);
    const settled = try runCounted(&w, arena, try editArgs(arena, case, "cache", "--jobs=1", "settled"), "settled.json");
    try testing.expectEqualStrings(first.result.stderr, settled.result.stderr);
    try testing.expectEqual(@as(u64, 0), settled.counters.checked);
    try testing.expectEqual(@as(u64, 0), settled.counters.derived);
    try expectSameTree(&w, arena, "first", "settled");
}

test "a warm rebuild is a cold build: a custom eq and compare added to a dependency" {
    try runEditStep(k_cases[0], 0, 1);
}

test "a warm rebuild is a cold build: the custom eq and compare removed again" {
    try runEditStep(k_cases[1], 0, 1);
}

test "a warm rebuild is a cold build: a dependency's function becomes constrained" {
    try runEditStep(k_cases[2], 0, 1);
}

test "a warm rebuild is a cold build: constructors reordered, which reorders the derived compare" {
    try runEditStep(k_cases[3], 0, 1);
}

test "a warm rebuild is a cold build: a function payload makes the type non-equatable" {
    try runEditStep(k_cases[4], 0, 1);
}

test "a warm rebuild is a cold build: a field added to a record alias" {
    try runEditStep(k_cases[5], 0, 1);
}

test "a warm rebuild is a cold build: an alias's expansion changed" {
    try runEditStep(k_cases[6], 0, 1);
}

test "a warm rebuild is a cold build: an error in a dependency fixed" {
    try runEditStep(k_cases[7], 0, 1);
}

// A dependency whose derived context changes must invalidate its dependents'
// EVIDENCE — the dispatch tables and the JavaScript they emit — not only their
// types. Four ways to move one: a function payload (the context goes
// `absent`, then `present` with no entry, then absent through the parameter);
// a payload's own `eq` changing its `where` clause (the entry's method moves)
// and dropping it; the payload's method made private (`private_method`,
// §11.3), removed, and a private `compare`; and a schema whose `via` target —
// a type in no record — gains a function and then a private `eq` (§11.5, the
// endpoint's `no_function` and derived rows). The warm check of the last edit
// of the schema case must refuse the program as a cold one does.

test "a moved derived context rebuilds evidence as a cold build: a function payload added" {
    try runEditStep(evidence_cases[0], 0, 1);
}

test "a moved derived context rebuilds evidence as a cold build: a parameter dropped from every payload" {
    try runEditStep(evidence_cases[0], 1, 2);
}

test "a moved derived context rebuilds evidence as a cold build: a function over the parameter" {
    try runEditStep(evidence_cases[0], 2, 3);
}

test "a moved derived context rebuilds evidence as a cold build: a payload's eq changes its where clause" {
    try runEditStep(evidence_cases[1], 0, 1);
}

test "a moved derived context rebuilds evidence as a cold build: a payload's eq drops its where clause" {
    try runEditStep(evidence_cases[1], 1, 2);
}

test "a moved derived context rebuilds evidence as a cold build: a payload's eq made private" {
    try runEditStep(evidence_cases[2], 0, 1);
}

test "a moved derived context rebuilds evidence as a cold build: a payload's private eq removed" {
    try runEditStep(evidence_cases[2], 1, 2);
}

test "a moved derived context rebuilds evidence as a cold build: a payload's private compare" {
    try runEditStep(evidence_cases[2], 2, 3);
}

test "a moved derived context rebuilds evidence as a cold build: a schema's via target gains a function" {
    try runEditStep(evidence_cases[3], 0, 1);
}

test "a moved derived context rebuilds evidence as a cold build: a schema's via target gains a private eq" {
    try runEditStep(evidence_cases[3], 1, 2);
}

test "a cache hit installs the published derived contexts and runs no fixpoint" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // checker-v2.md §11.1: "a cache hit installs the published answer" — the
    // derived rows are read off the record, never recomputed. The witness is
    // `derived_context_runs`, the fixpoints the checker ran: every module that
    // declares a type runs at least one when it is checked, none when it is
    // installed. `Main` declares no type and compares `Outer`s, whose
    // context runs through `H` and `Keyed`: re-checking it alone must read
    // every one of those rows and derive nothing.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeDerivedProject(&w, holder_by_key);
    const build = [_][]const u8{ "build", "--platform=node", "--diagnostics=json" };

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const cold = try runCounted(&w, arena, &(build ++ [_][]const u8{ "--jobs=1", "--cache-dir=c", "--out=cold", "src" }), "cold.json");
    const warm = try runCounted(&w, arena, &(build ++ [_][]const u8{ "--jobs=8", "--cache-dir=c", "--out=warm", "src" }), "warm.json");
    const main_source = try arena.dupe(u8, try w.read("src/Main.beni"));
    try w.write("src/Main.beni", try std.mem.replaceOwned(u8, arena, main_source, "Keyed.Keyed 2 \"b\"", "Keyed.Keyed 3 \"b\""));
    const body = try runCounted(&w, arena, &(build ++ [_][]const u8{ "--jobs=1", "--cache-dir=c", "--out=body", "src" }), "body.json");
    const oracle = try runCounted(&w, arena, &(build ++ [_][]const u8{ "--jobs=1", "--no-cache", "--out=oracle", "src" }), "oracle.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]Run{ cold, warm, body, oracle }) |r| {
        try testing.expectEqual(@as(u8, 0), r.result.exit_code);
        try testing.expectEqualStrings("", r.result.stderr);
    }
    // Cold: `H`, `Keyed`, `Outer` and core's types were derived here.
    try testing.expect(cold.counters.derived > 0);
    try testing.expectEqual(@as(u64, 0), cold.counters.hits);
    // Warm: every module installed, nothing derived.
    try testing.expectEqual(@as(u64, 0), warm.counters.checked);
    try testing.expectEqual(@as(u64, 0), warm.counters.derived);
    // `Main` alone re-checked: its comparisons resolved against the rows
    // the three installed records carry, and no fixpoint ran for them.
    try testing.expectEqual(@as(u64, 1), body.counters.checked);
    try testing.expectEqual(@as(u64, 0), body.counters.derived);
    // A cold build derives them all again (the counter counts).
    try testing.expectEqual(cold.counters.derived, oracle.counters.derived);
    try w.expectProgram("body/_main.mjs", .{ .stdout = "True\nFalse\n" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectSameTree(&w, arena, "cold", "warm");
    try expectSameTree(&w, arena, "oracle", "body");
}

const k_cases = [_]EditCase{
    .{
        .name = "a custom eq and compare added to a dependency",
        .n =
        \\import M exposing (T)
        \\
        \\pub type W = W T
        \\
        \\pub same : T, T → Bool
        \\same a b = W a == W b
        \\
        ,
        .main =
        \\import Node exposing (Program)
        \\import M exposing (T)
        \\import N exposing (W)
        \\
        \\show : Bool → String
        \\show b =
        \\    if b then "T" else "F"
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ show (M.T 1 == M.T 11), show (M.T 1 < M.T 11), show ([ N.W (M.T 2) ] == [ N.W (M.T 12) ]), show (N.same (M.T 3) (M.T 13)) ]
        \\
        ,
        .states = &.{
            .{
                .m =
                \\pub type T = T Int
                \\
                ,
                .expect = .{ .prints = "F\nT\nF\nF\n" },
            },
            .{
                .m =
                \\pub type T = T Int
                \\
                \\pub eq : T, T → Bool
                \\eq a b =
                \\    case ( a, b ) of
                \\        ( T x, T y ) → Int.mod x 10 == Int.mod y 10
                \\
                \\pub compare : T, T → Order
                \\compare a b = EQ
                \\
                ,
                .expect = .{ .prints = "T\nF\nT\nT\n" },
            },
        },
    },
    .{
        .name = "the custom eq and compare removed again",
        .n =
        \\import M exposing (T)
        \\
        \\pub type W = W T
        \\
        \\pub same : T, T → Bool
        \\same a b = W a == W b
        \\
        ,
        .main =
        \\import Node exposing (Program)
        \\import M exposing (T)
        \\import N exposing (W)
        \\
        \\show : Bool → String
        \\show b =
        \\    if b then "T" else "F"
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ show (M.T 1 == M.T 11), show (M.T 1 < M.T 11), show ([ N.W (M.T 2) ] == [ N.W (M.T 12) ]), show (N.same (M.T 3) (M.T 13)) ]
        \\
        ,
        .states = &.{
            .{
                .m =
                \\pub type T = T Int
                \\
                \\pub eq : T, T → Bool
                \\eq a b =
                \\    case ( a, b ) of
                \\        ( T x, T y ) → Int.mod x 10 == Int.mod y 10
                \\
                \\pub compare : T, T → Order
                \\compare a b = EQ
                \\
                ,
                .expect = .{ .prints = "T\nF\nT\nT\n" },
            },
            .{
                .m =
                \\pub type T = T Int
                \\
                ,
                .expect = .{ .prints = "F\nT\nF\nF\n" },
            },
        },
    },
    .{
        .name = "a dependency's function becomes constrained",
        .n =
        \\import M
        \\
        \\pub go x y = M.pick x y
        \\
        ,
        .main =
        \\import Node exposing (Program)
        \\import N
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ String.fromInt (N.go 3 9), N.go "b" "a" ]
        \\
        ,
        .states = &.{
            .{
                .m =
                \\pub pick x y = x
                \\
                ,
                .expect = .{ .prints = "3\nb\n" },
            },
            .{
                .m =
                \\pub pick x y =
                \\    if x < y then y else x
                \\
                ,
                .expect = .{ .prints = "9\nb\n" },
            },
        },
    },
    .{
        .name = "constructors reordered, which reorders the derived compare",
        .n =
        \\import M exposing (C, Red, Blue)
        \\
        \\pub cmp : String
        \\cmp =
        \\    if Red < Blue then "red<blue" else "red≥blue"
        \\
        ,
        .main =
        \\import Node exposing (Program)
        \\import N
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ N.cmp ]
        \\
        ,
        .states = &.{
            .{
                .m =
                \\pub type C = Red | Blue
                \\
                ,
                .expect = .{ .prints = "red<blue\n" },
            },
            .{
                .m =
                \\pub type C = Blue | Red
                \\
                ,
                .expect = .{ .prints = "red≥blue\n" },
            },
        },
    },
    .{
        .name = "a function payload makes the type non-equatable",
        .n =
        \\import M exposing (C)
        \\
        \\pub cmp : String
        \\cmp =
        \\    if M.C 1 == M.C 1 then "eq" else "ne"
        \\
        ,
        .main =
        \\import Node exposing (Program)
        \\import N
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ N.cmp ]
        \\
        ,
        .states = &.{
            .{
                .m =
                \\pub type C = C Int
                \\
                ,
                .expect = .{ .prints = "eq\n" },
            },
            .{
                .m =
                \\pub type C = C Int | F (Int → Int)
                \\
                ,
                .expect = .{ .codes = &.{"not_equatable"} },
            },
        },
    },
    .{
        .name = "a field added to a record alias",
        .n =
        \\import M
        \\
        \\pub go : String
        \\go =
        \\    M.describe { name = "z", n = 3 }
        \\
        ,
        .main =
        \\import Node exposing (Program)
        \\import N
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ N.go ]
        \\
        ,
        .states = &.{
            .{
                .m =
                \\pub type alias R = { name : String, n : Int }
                \\
                \\pub describe : R → String
                \\describe r = r.name
                \\
                ,
                .expect = .{ .prints = "z\n" },
            },
            .{
                .m =
                \\pub type alias R = { name : String, n : Int, extra : Bool }
                \\
                \\pub describe : R → String
                \\describe r = if r.extra then r.name else "no"
                \\
                ,
                .expect = .{ .codes = &.{"missing_field"} },
            },
        },
    },
    .{
        .name = "an alias's expansion changed",
        .n =
        \\import M exposing (Key)
        \\
        \\pub go : String
        \\go =
        \\    if M.k1 < M.k2 then "lt" else "ge"
        \\
        ,
        .main =
        \\import Node exposing (Program)
        \\import N
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ N.go ]
        \\
        ,
        .states = &.{
            .{
                .m =
                \\pub type alias Key = Int
                \\
                \\pub k1 : Key
                \\k1 = 10
                \\
                \\pub k2 : Key
                \\k2 = 9
                \\
                ,
                .expect = .{ .prints = "ge\n" },
            },
            .{
                .m =
                \\pub type alias Key = String
                \\
                \\pub k1 : Key
                \\k1 = "10"
                \\
                \\pub k2 : Key
                \\k2 = "9"
                \\
                ,
                .expect = .{ .prints = "lt\n" },
            },
        },
    },
    .{
        .name = "an error in a dependency fixed",
        .n =
        \\import M
        \\
        \\pub go : String
        \\go =
        \\    M.label 3
        \\
        ,
        .main =
        \\import Node exposing (Program)
        \\import N
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ N.go ]
        \\
        ,
        .states = &.{
            .{
                .m =
                \\pub label : String → String
                \\label s = s
                \\
                ,
                .expect = .{ .codes = &.{"kind_mismatch"} },
            },
            .{
                .m =
                \\pub label : Int → String
                \\label s = String.fromInt s
                \\
                ,
                .expect = .{ .prints = "3\n" },
            },
        },
    },
};

const evidence_cases = [_]EditCase{
    .{
        .name = "a function payload added; a parameter dropped from every payload; a function over the parameter",
        .n =
        \\import M
        \\
        \\
        \\pub type W a
        \\    = W (M.Box a)
        \\
        \\
        \\pub same : W Int, W Int → Bool
        \\same x y =
        \\    x == y
        \\
        ,
        .main =
        \\import Node exposing (Program)
        \\import M
        \\import N
        \\
        \\
        \\show : Bool → String
        \\show b =
        \\    if b then "T" else "F"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ show (N.same (N.W (M.Box 1)) (N.W (M.Box 2))), show (M.Box 3 == M.Box 3), show ([ N.W (M.Box 4) ] == [ N.W (M.Box 4) ]) ]
        \\
        ,
        .states = &.{
            .{
                .m =
                \\pub type Box a
                \\    = Box a
                \\
                ,
                .expect = .{ .prints = "F\nT\nT\n" },
            },
            .{
                .m =
                \\pub type Box a
                \\    = Box a
                \\    | Fn (Int → Int)
                \\
                ,
                .expect = .{ .codes = &.{ "not_equatable", "not_equatable", "not_equatable" } },
            },
            .{
                .m =
                \\pub type Box a
                \\    = Box Int
                \\
                ,
                .expect = .{ .prints = "F\nT\nT\n" },
            },
            .{
                .m =
                \\pub type Box a
                \\    = Box a
                \\    | Fn (a → Int)
                \\
                ,
                .expect = .{ .codes = &.{ "not_equatable", "not_equatable", "not_equatable" } },
            },
        },
    },
    .{
        .name = "a payload's eq changes its where clause, then drops it",
        .n =
        \\import M
        \\
        \\
        \\pub type W a
        \\    = W (M.Holder a)
        \\
        ,
        .main =
        \\import Node exposing (Program)
        \\import M
        \\import N
        \\
        \\
        \\show : Bool → String
        \\show b =
        \\    if b then "T" else "F"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ show (N.W (M.Holder 1) == N.W (M.Holder 2)), show (N.W (M.Holder 5) == N.W (M.Holder 5)) ]
        \\
        ,
        .states = &.{
            .{
                .m =
                \\pub type Holder a
                \\    = Holder a
                \\
                \\
                \\pub eq : Holder a, Holder a → Bool
                \\    where a.eq : a, a → Bool
                \\eq (Holder x) (Holder y) =
                \\    x == y
                \\
                ,
                .expect = .{ .prints = "F\nT\n" },
            },
            .{
                .m =
                \\pub type Holder a
                \\    = Holder a
                \\
                \\
                \\pub eq : Holder a, Holder a → Bool
                \\    where a.compare : a, a → Order
                \\eq (Holder x) (Holder y) =
                \\    x < y
                \\
                ,
                .expect = .{ .prints = "T\nF\n" },
            },
            .{
                .m =
                \\pub type Holder a
                \\    = Holder a
                \\
                \\
                \\pub eq : Holder a, Holder a → Bool
                \\eq x y =
                \\    True
                \\
                ,
                .expect = .{ .prints = "T\nT\n" },
            },
        },
    },
    .{
        .name = "a payload's eq flipped pub to private; removed; a private compare",
        .n =
        \\import M
        \\
        \\
        \\pub type W
        \\    = W M.T
        \\
        ,
        .main =
        \\import Node exposing (Program)
        \\import M
        \\import N
        \\
        \\
        \\show : Bool → String
        \\show b =
        \\    if b then "T" else "F"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ show (N.W (M.T 1) == N.W (M.T 11)), show (N.W (M.T 1) < N.W (M.T 11)) ]
        \\
        ,
        .states = &.{
            .{
                .m =
                \\pub type T
                \\    = T Int
                \\
                \\
                \\pub eq : T, T → Bool
                \\eq a b =
                \\    case ( a, b ) of
                \\        ( T x, T y ) →
                \\            Int.mod 10 x == Int.mod 10 y
                \\
                ,
                .expect = .{ .prints = "F\nT\n" },
            },
            .{
                .m =
                \\pub type T
                \\    = T Int
                \\
                \\
                \\eq : T, T → Bool
                \\eq a b =
                \\    case ( a, b ) of
                \\        ( T x, T y ) →
                \\            Int.mod 10 x == Int.mod 10 y
                \\
                ,
                .expect = .{ .codes = &.{"private_method"} },
            },
            .{
                .m =
                \\pub type T
                \\    = T Int
                \\
                ,
                .expect = .{ .prints = "F\nT\n" },
            },
            .{
                .m =
                \\pub type T
                \\    = T Int
                \\
                \\
                \\compare : T, T → Order
                \\compare a b =
                \\    EQ
                \\
                ,
                .expect = .{ .codes = &.{"private_method"} },
            },
        },
    },
    .{
        .name = "a schema's via target gains a function; then a private eq",
        .n =
        \\import M
        \\
        \\
        \\pub same : M.S.Type, M.S.Type → Bool
        \\same a b =
        \\    a == b
        \\
        ,
        .states = &.{
            .{
                .m =
                \\import Schema exposing (Conversion)
                \\
                \\
                \\conv : Conversion Int Target
                \\conv =
                \\    Debug.todo "c"
                \\
                \\
                \\type Target
                \\    = Target Int
                \\
                \\
                \\pub schema S tagged "kind" of
                \\    V as "v"
                \\        payload : Int via conv
                \\
                ,
                .expect = .{ .codes = &.{} },
            },
            .{
                .m =
                \\import Schema exposing (Conversion)
                \\
                \\
                \\conv : Conversion Int Target
                \\conv =
                \\    Debug.todo "c"
                \\
                \\
                \\type Target
                \\    = Target Int
                \\    | Fn (Int → Int)
                \\
                \\
                \\pub schema S tagged "kind" of
                \\    V as "v"
                \\        payload : Int via conv
                \\
                ,
                .expect = .{ .codes = &.{"not_equatable"} },
            },
            .{
                .m =
                \\import Schema exposing (Conversion)
                \\
                \\
                \\conv : Conversion Int Target
                \\conv =
                \\    Debug.todo "c"
                \\
                \\
                \\type Target
                \\    = Target Int
                \\
                \\
                \\eq : Target, Target → Bool
                \\eq a b =
                \\    True
                \\
                \\
                \\pub schema S tagged "kind" of
                \\    V as "v"
                \\        payload : Int via conv
                \\
                ,
                .expect = .{ .codes = &.{"private_method"} },
            },
        },
    },
};

test "a view module re-checked against the cached vocabulary module reads it as a cold check does" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `html`'s `Html` is a vocabulary module: its record carries the element,
    // attribute and event tables and flags its markup primitives
    // (checker-v2.md §25.8). After an edit to `View` alone, the warm check
    // installs `Html` from the cache and checks `View` against that record,
    // and must print what a check without a cache prints — the interface
    // hash of every module included, `Html`'s computed over the record read
    // back from bytes.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("View.beni",
        \\import Html exposing (Html)
        \\
        \\
        \\pub view : String → Html msg
        \\view s =
        \\    Html.text s
        \\
    );
    const args = [_][]const u8{ "check", "--jobs=1", "--platform=html", "--iface-hash", "--cache-dir=cache", "View.beni" };
    _ = try runCounted(&w, arena, &args, "cold.json");
    try w.write("View.beni",
        \\import Html exposing (Html)
        \\
        \\
        \\pub view : String → Html msg
        \\view s =
        \\    Html.map (Html.text s) identity
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const warm = try runCounted(&w, arena, &args, "warm.json");
    const oracle = try w.runWith(&.{ "check", "--jobs=1", "--platform=html", "--iface-hash", "--no-cache", "View.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    try testing.expectEqualStrings(oracle.stderr, warm.result.stderr);
    try testing.expectEqualStrings(oracle.stdout, warm.result.stdout);
    try testing.expect(std.mem.indexOf(u8, warm.result.stdout, "platform:Html ") != null);
    // `View` alone was checked; `Html` and core came from the cache.
    try testing.expectEqual(@as(u64, 1), warm.counters.checked);
    try testing.expectEqual(@as(u64, 1), warm.counters.misses);
}

/// A two-module markup project for the cache scenarios: `Card` is a
/// component, and `View` writes markup that calls it, with a `For` over
/// records that says nothing about its keying — the `unkeyed_for` warning a
/// cached entry must replay.
fn writeMarkupProject(w: *World, card_class: []const u8) !void {
    var buffer: [512]u8 = undefined;
    try w.write("Card.beni", try std.fmt.bufPrint(&buffer,
        \\import Html exposing (Html)
        \\
        \\
        \\pub view : {{ title : String }} → Html msg
        \\view props =
        \\    <h2 class="{s}">{{props.title}}</h2>
        \\
    , .{card_class}));
    try w.write("View.beni",
        \\import Card
        \\import Html exposing (Html)
        \\
        \\
        \\type Msg
        \\    = Picked Int
        \\
        \\
        \\pub view : List { id : Int, label : String } → Html Msg
        \\view rows =
        \\    <ul>
        \\        <Card title="Rows" />
        \\        <For each={rows}>{λr → <li onClick={Picked r.id}>{r.label}</li>}</For>
        \\    </ul>
        \\
    );
}

test "a markup module installed from the cache replays its warning, and an edit to markup alone re-checks no importer" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `View`'s entry carries its `unkeyed_for` warning and its dispatch
    // table, markup section included (checker-v2.md §25.7). Editing only
    // `Card`'s markup moves no interface hash (§25.8), so the warm run checks
    // `Card` alone, installs `View` from the cache, and must print what a run
    // without a cache prints.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeMarkupProject(&w, "card");
    const args = [_][]const u8{ "check", "--jobs=1", "--platform=html", "--iface-hash", "--cache-dir=cache", "." };
    const cold = try runCounted(&w, arena, &args, "cold.json");
    try writeMarkupProject(&w, "card title");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const warm = try runCounted(&w, arena, &args, "warm.json");
    const oracle = try w.runWith(&.{ "check", "--jobs=1", "--platform=html", "--iface-hash", "--no-cache", "." }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    try testing.expectEqualStrings(oracle.stderr, warm.result.stderr);
    try testing.expectEqualStrings(oracle.stdout, warm.result.stdout);
    try testing.expect(std.mem.indexOf(u8, warm.result.stderr, "UNKEYED FOR") != null);
    // Every interface hash is the cold run's: the edit changed no type.
    try testing.expectEqualStrings(cold.result.stdout, warm.result.stdout);
    try testing.expectEqual(@as(u64, 1), warm.counters.checked);
    try testing.expectEqual(@as(u64, 1), warm.counters.misses);
}
