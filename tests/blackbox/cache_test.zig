//! The persistent cache's KEY, black-box (`docs/design/fast-compiler.md` §8's
//! *The persistent cache, and its key*, `plans/m4-1.md` §6.1).
//!
//! **These scenarios land before a byte is ever written to disk**, and that is
//! the point. A cache bug is a wrong answer that depends on history — the
//! worst kind, because it cannot be reproduced from a clean checkout — and the
//! thing that decides whether a module is re-checked is its key and nothing
//! else. So the whole invalidation table is pinned here, against
//! `--cache-keys`, with no cache directory in sight; the counters that follow
//! in M1-f can then only confirm what this file already fixed.
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
    \\pub foreign twice : Int -> Int
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
    try testing.expect(keys.len >= 12);

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

    // **The same tree, spelled every way a person spells it.** Since
    // `0bc5d89` every path is normalised lexically at enumeration, so `.`
    // is a directory like any other and `src`, `./src`, `src/` and
    // `$PWD/src` are one project — which makes this the strong form of the
    // claim rather than the two-spelling version it was written as before
    // that landed. A key carries the DOTTED MODULE NAME and never a path,
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

test "row 1: nothing changed moves no key" {
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

test "row 2: a comment in Leaf moves Leaf, Mid and Top" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // **The row that states M4-1's cost, out loud.** The interface hash does
    // NOT move for a comment — that is what M4-3's cutoff will use — but the
    // KEY does, and an importer's key carries its import's key, so the whole
    // chain is re-checked. `fast-compiler.md` §8 says so twice for exactly
    // this reason, and this fixture is where it stops being a claim.
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
    try expectMoved("a comment in Leaf", base, try baselineKeys(&w, arena), &all_app);
    // …and the interface hash did not, which is the whole difference between
    // this slice and M4-3.
    try expectMoved("a comment in Leaf, by interface hash", iface_before, try ifaceHashes(&w, arena), &.{});
}

test "row 3: the body of an annotated pub in Leaf moves Leaf, Mid and Top" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    const iface_before = try ifaceHashes(&w, arena);
    try w.write("src/Leaf.beni",
        \\pub foreign twice : Int -> Int
        \\
        \\
        \\pub one : Int
        \\one =
        \\    2
        \\
    );

    try expectMoved("an annotated body in Leaf", base, try baselineKeys(&w, arena), &all_app);
    // Report 19 §4: every annotated row measures 0 interface changes,
    // because an annotation is exactly what a dependent sees.
    try expectMoved("an annotated body, by interface hash", iface_before, try ifaceHashes(&w, arena), &.{});
}

test "row 4: a pub signature in Leaf moves Leaf, Mid and Top, and its interface too" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const base = try baselineKeys(&w, arena);
    const iface_before = try ifaceHashes(&w, arena);
    try w.write("src/Leaf.beni",
        \\pub foreign twice : Int -> Int
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

test "row 5: a PRIVATE type added to Leaf moves Leaf, Mid and Top but no interface" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // **The interesting one** (`plans/m4-1.md` §6.1). M4-3's cutoff wants
    // `Mid` to hit here, and may only do so once the declared-type sidecar of
    // `plans/m4-slice-zero.md` §4 is defined and its hash is in `Mid`'s key:
    // `Mid`'s check reads `Leaf`'s settled `equatable`/`comparable` bits and
    // its `declaresPubCompare`, none of which is in the record. In M4-1 the
    // key moves, and this fixture is the "before" that makes M4-3's change
    // visible rather than assumed.
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
    try expectMoved("a private type in Leaf", base, try baselineKeys(&w, arena), &all_app);
    // Slice zero §11.3's E4 row, restated: a private type moves no interface
    // hash at all, not even the edited module's own.
    try expectMoved("a private type, by interface hash", iface_before, try ifaceHashes(&w, arena), &.{});
}

test "row 6: a new unrelated file moves nothing that already existed" {
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

test "row 7: Leaf's sibling .js moves Leaf, Mid and Top, and no interface" {
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
    try expectMoved("Leaf's sibling .js", base, try baselineKeys(&w, arena), &all_app);
    try expectMoved("Leaf's sibling .js, by interface hash", iface_before, try ifaceHashes(&w, arena), &.{});
}

test "row 7b: a sibling .js beside a module with no foreign is not in any key" {
    // The converse of row 7, and the fixture that would catch a key hashing
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

test "row 8: --platform adds the platform's modules and moves no existing key" {
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

test "row 9: --pattern-budget moves every module's key" {
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

test "row 10: --cache-build-id moves every module's key, core included" {
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
    /// M4-2's three (`fast-compiler.md` §8): a phase that did not run is
    /// otherwise indistinguishable from a phase that ran fast.
    lexed: u64 = 0,
    parsed: u64 = 0,
    lowered: u64 = 0,
    files: u64 = 0,
    frontend_hits: u64 = 0,
    frontend_bytes: u64 = 0,
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
    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "plain.json");
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
    // A cold run hits nothing, checks everything, and writes an entry per
    // cacheable module — the app's three and core's, which is what makes
    // even M4-1's narrow win worth having.
    try testing.expectEqual(@as(u64, 0), cached.counters.hits);
    try testing.expectEqual(@as(u64, 0), plain.counters.hits);
    try testing.expect(cached.counters.misses >= 12);
    try testing.expectEqual(cached.counters.misses, plain.counters.misses);
    try testing.expectEqual(cached.counters.checked, plain.counters.checked);
    try testing.expect(cached.counters.bytes > 0);
    // A run with no cache directory writes nothing, whatever it counted.
    try testing.expectEqual(@as(u64, 0), plain.counters.bytes);

    const files = try entriesOnly(arena, try w.listFiles("cache"));
    try testing.expectEqual(@as(usize, @intCast(cached.counters.misses)), files.len);
    for (files) |f| {
        // `v<n>/<kk>/<rest>.bec`, two levels of fan-out over the key's hex.
        try testing.expect(std.mem.startsWith(u8, f, "v1/"));
        try testing.expect(std.mem.endsWith(u8, f, ".bec"));
        try testing.expectEqual(@as(usize, "v1/".len + 2 + 1 + 30 + ".bec".len), f.len);
    }
    // The front-end artifacts share the directory and the fan-out under a
    // SECOND key (M4-2): one `.bef` per FILE, beside one `.bec` per module.
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
    // M2-e's assertion, and the floor the warm one is measured against: a
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
    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "plain.json");
    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "cold.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(plain.result.exit_code, cold.result.exit_code);
    try testing.expectEqualStrings(plain.result.stderr, cold.result.stderr);
    try testing.expectEqualStrings(plain.result.stdout, cold.result.stdout);

    // Every file, on both runs: a cache directory does not change what the
    // front end does on a cold run, it only makes it write.
    for ([_]Run{ plain, cold }) |run| {
        try testing.expect(run.counters.files > 0);
        try testing.expectEqual(run.counters.files, run.counters.lexed);
        try testing.expectEqual(run.counters.files, run.counters.parsed);
        try testing.expectEqual(run.counters.files, run.counters.lowered);
    }
    // A run with no cache directory writes no artifact, whatever it lowered.
    try testing.expectEqual(@as(u64, 0), plain.counters.frontend_bytes);
    try testing.expect(cold.counters.frontend_bytes > 0);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // One `.bef` per FILE — more than the `.bec` count, because a file key
    // is per file and a module key is per module, and core's files are both.
    const artifacts = try artifactsOnly(arena, try w.listFiles("cache"));
    try testing.expectEqual(@as(usize, @intCast(cold.counters.files)), artifacts.len);
}

test "a file whose front end failed is never written, and its neighbours are" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // M4-1's "produced by a clean check" bit, one phase earlier and for the
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
    // Every file but the broken one. The count is the assertion: naming the
    // absent key would need the file key of a file that does not compile,
    // and `--frontend-keys` prints those too — so both halves are checked.
    try testing.expectEqual(@as(usize, @intCast(r.counters.files - 1)), artifacts.len);

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
    try testing.expectEqual(@as(usize, @intCast(fixed.counters.files)), after.len);
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
    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "plain.json");
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
    // Every file hit, and nothing written a second time: the name is the
    // key, so there is nothing to rewrite.
    try testing.expectEqual(warm.counters.files, warm.counters.frontend_hits);
    try testing.expectEqual(@as(u64, 0), warm.counters.frontend_bytes);
    // …and the modules were not re-checked either, which is M4-1 still
    // holding with a loaded `Bir` under it.
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
    // **The row M4-2 exists for.** A module key folds every import's key, so
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
        \\pub foreign twice : Int -> Int
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
    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "plain.json");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), edited.result.exit_code);
    try testing.expectEqualStrings(plain.result.stderr, edited.result.stderr);

    // ONE file re-lexed, re-parsed and re-lowered: the leaf.
    try testing.expectEqual(@as(u64, 1), edited.counters.lexed);
    try testing.expectEqual(@as(u64, 1), edited.counters.parsed);
    try testing.expectEqual(@as(u64, 1), edited.counters.lowered);
    try testing.expectEqual(edited.counters.files - 1, edited.counters.frontend_hits);
    // THREE modules re-checked — `Leaf`, `Mid` and `Top` — because the
    // module key is inductive over imports and the file key is not.
    try testing.expectEqual(@as(u64, 3), edited.counters.checked);

    // And the run after it is fully warm again, which is what says the edited
    // file's artifact was written rather than merely not read.
    const settled = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "settled.json");
    try testing.expectEqual(@as(u64, 0), settled.counters.lowered);
    try testing.expectEqual(@as(u64, 0), settled.counters.checked);
}

test "a truncated, corrupt or foreign .bef is a miss and is then overwritten" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `plans/m4-2.md` §9.4 item 23, black-box, and the twin of the `.bec`
    // table above. Each shape must produce byte-identical output to a cold
    // run and the same exit code — never a crash, never a diagnostic, never a
    // wrong answer — and the good artifact must then replace it. With the
    // `rename` dropped (§6 B), the "overwritten" half is a REQUIREMENT and
    // not a nicety: a partial file a crashed process left must not be
    // believed forever.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "plain.json");
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
        .{ .what = "zero length", .bytes = "" },
        .{ .what = "truncated mid-section", .bytes = good[0 .. good.len - 8] },
        .{ .what = "truncated to a stub", .bytes = good[0..9] },
        .{ .what = "a prefix of exactly half", .bytes = good[0 .. good.len / 2] },
        .{ .what = "random bytes", .bytes = "not an artifact at all, just some bytes" },
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

    // A flipped bit that keeps the LENGTH: the case a content-addressed name
    // cannot detect, and the reason the header carries a hash over its body.
    for ([_]usize{ 0, 8, 41 }) |at| {
        const mangled = try arena.dupe(u8, good);
        mangled[at] +%= 1;
        try w.write(victim, mangled);
        const r = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "bit.json");
        try testing.expectEqual(plain.result.exit_code, r.result.exit_code);
        try testing.expectEqualStrings(plain.result.stderr, r.result.stderr);
        try testing.expectEqual(@as(u64, 1), r.counters.lowered);
        try testing.expectEqualStrings(good, try w.read(victim));
    }
    // A bit flipped in the BODY, past the header, where only the hash can
    // see it.
    {
        const mangled = try arena.dupe(u8, good);
        mangled[good.len - 5] ^= 0x40;
        try w.write(victim, mangled);
        const r = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "body.json");
        try testing.expectEqualStrings(plain.result.stderr, r.result.stderr);
        try testing.expectEqual(@as(u64, 1), r.counters.lowered);
        try testing.expectEqualStrings(good, try w.read(victim));
    }

    // Another file's artifact under this one's name: the "wrong build id"
    // case, refused by the header's key and not by luck.
    {
        const other = try std.fs.path.join(arena, &.{ "cache", artifacts[1] });
        try w.write(victim, try w.read(other));
        const r = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "foreign.json");
        try testing.expectEqualStrings(plain.result.stderr, r.result.stderr);
        try testing.expectEqual(@as(u64, 1), r.counters.lowered);
        try testing.expectEqualStrings(good, try w.read(victim));
    }

    // …and after all that, the cache is whole again.
    const restored = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "restored.json");
    try testing.expectEqual(@as(u64, 0), restored.counters.lowered);
    try testing.expectEqual(@as(u64, 0), restored.counters.checked);
}

test "the interner-order fixture: a cache written over P is read over P plus a module sorting first" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Slice zero §7.1's shape, aimed at M4-2's own hazard. A worker's local
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
        \\    let
        \\        alpha =
        \\            1
        \\
        \\        beta =
        \\            2
        \\    in
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
        \\    let
        \\        gamma =
        \\            1
        \\
        \\        delta =
        \\            2
        \\
        \\        epsilon =
        \\            3
        \\
        \\        zeta2 =
        \\            4
        \\    in
        \\    gamma + delta + epsilon + zeta2
        \\
    );
    const grown = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "p2.json");
    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "cold.json");
    const cold_hashes = try ifaceHashes(&w, arena);
    const warm_hashes = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "--cache-dir=cache", "src" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(cold.result.exit_code, grown.result.exit_code);
    try testing.expectEqualStrings(cold.result.stderr, grown.result.stderr);
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

/// The `.bec` entries of a cache listing — M4-1's, one per MODULE.
fn entriesOnly(arena: std.mem.Allocator, files: []const []const u8) ![]const []const u8 {
    return withExtension(arena, files, ".bec");
}

/// The `.bef` front-end artifacts — M4-2's, one per FILE, under a different
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

    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "plain.json");
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
        \\pub foreign twice : Int -> Int
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
    // Core is clean and still cached, so this is not "nothing was written";
    // what is absent is exactly the broken module's entry.
    const files = try w.listFiles("cache");
    try testing.expect(files.len > 0);
    const keys = try baselineKeysAllowingErrors(&w, arena);
    try expectNoEntry(&w, files, lookup(keys, "app:Leaf").?);
    try expectEntry(&w, files, lookup(keys, "core:Basics").?);

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
    try expectEntry(&w, files, lookup(keys, "core:Basics").?);
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
    // M4-1's whole demonstrable win: an unchanged tree, plus the nine core
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
    try testing.expect(warm.counters.hits >= 12);
    // Nothing new was written: every entry was already there under its key.
    try testing.expectEqual(@as(u64, 0), warm.counters.bytes);
}

test "an edit re-checks its module and its importers and nothing else" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The counters' half of the edit-scenario table, and M4-1's cost made
    // visible: a comment in `Leaf` re-checks `Mid` and `Top` as well,
    // because an importer's key carries its import's key. **That is the
    // number M4-3 exists to fix**, and it is asserted rather than lamented
    // so that the day it changes, this fixture says so.
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
    // Exactly the three app modules missed; core hit.
    try testing.expectEqual(@as(u64, 3), after.counters.misses);
    try testing.expectEqual(@as(u64, 3), after.counters.checked);
    try testing.expectEqual(cold.counters.misses - 3, after.counters.hits);

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
        \\pub area : Shape -> Int
        \\area s =
        \\    case s of
        \\        Circle r ->
        \\            r * r
        \\
        \\        Rect x y ->
        \\            x * y
        \\
        \\
        \\pub same : Shape, Shape -> Bool
        \\same a b =
        \\    a == b
        \\
        \\
        \\pub bigger : a, a -> a
        \\    where a.compare : a, a -> Order
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
    // something else.
    const ran = try w.node("warm/main.mjs");
    try testing.expectEqual(@as(u8, 0), ran.exit_code);
    // `Rect 3 4` is the bigger of the two — a derived `compare` orders by
    // constructor first — so the area is 12.
    try testing.expectEqualStrings("12\n", ran.stdout);
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

test "a cache written in one configuration and read in another: jobs, cwd, and check versus build" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `plans/m4-1.md` §6.3 row 14 and the cross `fast-compiler.md` §8 calls
    // deliberate. A cache written at one worker count and read at another is
    // what would catch a `Symbol` reaching the bytes; one written by `check`
    // and read by `build` is what would catch an entry that depended on
    // which command wrote it.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
    // `--jobs=8` writes, `--jobs=1` reads.
    {
        const warm = try coldThenWarm(
            &w,
            arena,
            &.{ "check", "--jobs=8", "--cache-dir=eight", "src" },
            &.{ "check", "--jobs=1", "--cache-dir=eight", "src" },
        );
        try testing.expectEqual(@as(u64, 0), warm.counters.checked);
    }
    // …and the reverse.
    {
        const warm = try coldThenWarm(
            &w,
            arena,
            &.{ "check", "--jobs=1", "--cache-dir=one", "src" },
            &.{ "check", "--jobs=8", "--cache-dir=one", "src" },
        );
        try testing.expectEqual(@as(u64, 0), warm.counters.checked);
    }
    // **One cache, every spelling of the same tree.** Nothing in the key or
    // in the entry is a path, and since `0bc5d89` every path is normalised
    // lexically at enumeration, so `src`, `./src`, `src/` and `$PWD/src` are
    // one project — which means an entry written under any one of them must
    // be HIT by all the others. That is the strong form of "a cache does not
    // depend on the directory the compiler was run from": the keys-are-equal
    // half is asserted above, and this is the half that reads the files.
    {
        const absolute = try w.projectSubPath(arena, "src");
        try w.createDir("cwdcache");
        const cache = try w.projectSubPath(arena, "cwdcache");
        const root_flag = try std.fmt.allocPrint(arena, "--root={s}", .{absolute});
        const dir_flag = try std.fmt.allocPrint(arena, "--cache-dir={s}", .{cache});
        // Written by the absolute spelling, with an absolute `--root`…
        const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", dir_flag, root_flag, absolute }, "abs.json");
        try testing.expectEqual(@as(u64, 0), cold.counters.hits);
        // …and read by every other spelling, each of which must check none.
        for ([_][]const u8{ "src", "./src", "src/", "./src/" }) |spelling| {
            const warm = try runCounted(&w, arena, &.{ "check", "--jobs=1", dir_flag, spelling }, "rel.json");
            testing.expectEqual(@as(u64, 0), warm.counters.checked) catch |err| {
                std.debug.print("the spelling '{s}' missed a cache written as an absolute path\n", .{spelling});
                return err;
            };
            try testing.expectEqual(cold.counters.misses, warm.counters.hits);
        }
        // And the absolute spelling with a RELATIVE cache directory reads
        // the relative runs' own entries too, which is the same claim from
        // the other side.
        const back = try runCounted(&w, arena, &.{ "check", "--jobs=1", dir_flag, absolute }, "abs2.json");
        try testing.expectEqual(@as(u64, 0), back.counters.checked);
    }
    // `check` writes, `build` reads — and the reverse. The entry holds the
    // check's result and no emitted byte, so the two commands share it.
    {
        const checked = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=shared", "src" }, "c.json");
        try testing.expectEqual(@as(u64, 0), checked.counters.hits);
        const built = try runCounted(
            &w,
            arena,
            &.{ "build", "--platform=node", "--library", "--out=out", "--jobs=1", "--cache-dir=shared", "src" },
            "b.json",
        );
        try testing.expectEqual(@as(u8, 0), built.result.exit_code);
        // The app's three modules and core hit; the platform's own modules
        // are new to this cache, because `check` never enumerated them.
        try testing.expect(built.counters.hits >= checked.counters.misses);
        const after = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=shared", "src" }, "c2.json");
        try testing.expectEqual(@as(u64, 0), after.counters.checked);
    }
}

test "a truncated, corrupt or foreign entry is a miss and is then overwritten" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `plans/m4-1.md` §6.4, black-box: the six shapes a fixture can plant on
    // disk. Each must produce byte-identical output to a cold run and the
    // same exit code — never a crash, never a diagnostic, never a wrong
    // answer — and the good entry must then replace it.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const plain = try runCounted(&w, arena, &.{ "check", "--jobs=1", "src" }, "plain.json");
    const cold = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "cold.json");
    // The `.bec` entries only: a ruined `.bef` is a FRONT-END miss and does
    // not move `cache_misses`, so the row below would be measuring the wrong
    // counter. `plans/m4-2.md` §9.4's own table for `.bef` is the twin test.
    const files = try entriesOnly(arena, try w.listFiles("cache"));
    try testing.expect(files.len > 1);
    const victim = try std.fs.path.join(arena, &.{ "cache", files[0] });
    const good = try w.read(victim);
    try testing.expect(good.len > 64);

    const Shape = struct { what: []const u8, bytes: []const u8 };
    const shapes = [_]Shape{
        .{ .what = "zero length", .bytes = "" },
        .{ .what = "truncated mid-section", .bytes = good[0 .. good.len - 8] },
        .{ .what = "truncated to a stub", .bytes = good[0..9] },
        .{ .what = "random bytes", .bytes = "not an entry at all, just some bytes" },
    };

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
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
        const rewritten = try w.read(victim);
        try testing.expectEqualStrings(good, rewritten);
    }

    // A wrong magic and a bumped version, which are the two shapes an older
    // compiler's file has.
    for ([_]usize{ 0, 8 }) |at| {
        const mangled = try arena.dupe(u8, good);
        mangled[at] +%= 1;
        try w.write(victim, mangled);
        const r = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "bad.json");
        try testing.expectEqual(plain.result.exit_code, r.result.exit_code);
        try testing.expectEqualStrings(plain.result.stderr, r.result.stderr);
        try testing.expectEqual(@as(u64, 1), r.counters.misses);
        try testing.expectEqualStrings(good, try w.read(victim));
    }

    // An entry written for ANOTHER key, planted under this key's name: the
    // "wrong build id" case, and the one the header's key field exists to
    // catch without trusting the directory.
    {
        const other = try std.fs.path.join(arena, &.{ "cache", files[1] });
        try w.write(victim, try w.read(other));
        const r = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "bad.json");
        try testing.expectEqual(plain.result.exit_code, r.result.exit_code);
        try testing.expectEqualStrings(plain.result.stderr, r.result.stderr);
        try testing.expectEqual(@as(u64, 1), r.counters.misses);
        try testing.expectEqualStrings(good, try w.read(victim));
    }

    // …and after all that, the cache is whole again.
    const restored = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "restored.json");
    try testing.expectEqual(@as(u64, 0), restored.counters.checked);
    try testing.expectEqual(cold.counters.misses, restored.counters.hits);
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
    const warm = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=cache", "src" }, "warm.json");
    try testing.expectEqual(@as(u8, 0), warm.result.exit_code);
    try testing.expectEqualStrings("", warm.result.stderr);
    try testing.expectEqual(cold.counters.misses, warm.counters.hits);
    try testing.expectEqual(@as(u64, 0), warm.counters.checked);
}

test "readers racing writers on an empty cache directory never accept a torn file" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // **The fixture the dropped `rename` is conditional on** (`plans/m4-2.md`
    // §6 B, condition 3). With write-to-temp-plus-rename a reader could never
    // see a partial file; with a plain create it can, and what makes that
    // safe is that the header carries the file's total length and the reader
    // checks it FIRST, so every prefix is a miss.
    //
    // Six processes at once on one initially EMPTY directory, several
    // rounds: each is both a reader and a writer, because a `check` reads
    // what is there and writes what is not. Every one of them must exit 0
    // and print exactly what a `--no-cache` run prints — a torn file that
    // was believed would show up as a different diagnostic, a different exit
    // code or a crash, and a torn file that was merely tolerated shows up in
    // the settled run at the end.
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
    const racers = 6;
    for (0..6) |round| {
        const dir = try std.fmt.allocPrint(arena, "--cache-dir=torn{d}", .{round});
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
        // Different `--jobs` on purpose: the processes then reach any one
        // key at different moments, which is what makes the overlap real
        // rather than nominal.
        var list: [racers]Racer = undefined;
        for (&list, 0..) |*slot, i| {
            const jobs = try std.fmt.allocPrint(arena, "--jobs={d}", .{@as(u32, @intCast(1 + (i % 4)))});
            slot.* = .{
                .w = &w,
                .args = try arena.dupe([]const u8, &.{ "check", jobs, dir, "src" }),
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
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A settled run over the directory the race left behind hits EVERY file
    // and every module: no half-written file survived it, and none was left
    // in a state that is refused forever.
    const settled = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=torn0", "src" }, "settled.json");
    try testing.expectEqual(@as(u64, 0), settled.counters.lowered);
    try testing.expectEqual(@as(u64, 0), settled.counters.checked);
    try testing.expectEqual(@as(u64, 0), settled.counters.misses);
}

test "two processes racing on one empty cache directory both exit 0 and agree" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `plans/m4-1.md` §6.3 row 15. There are no locks by design: two
    // processes that compute the same key write identical bytes and the
    // later `rename` is harmless. What must never happen is a partial file
    // being read — which is what write-to-temp-then-rename buys, and what
    // this asserts by running the race twenty times and then requiring a
    // third run to hit everything.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    for (0..10) |round| {
        const dir = try std.fmt.allocPrint(arena, "--cache-dir=race{d}", .{round});
        var results: [2]world.Result = undefined;
        var threads: [2]std.Thread = undefined;
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
        const args = try arena.dupe([]const u8, &.{ "check", "--jobs=2", dir, "src" });
        var racers: [2]Racer = .{
            .{ .w = &w, .args = args, .out = &results[0] },
            .{ .w = &w, .args = args, .out = &results[1] },
        };
        for (&threads, &racers) |*t, *r| t.* = try std.Thread.spawn(.{}, Racer.go, .{r});
        for (threads) |t| t.join();

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        for (racers) |r| {
            if (r.err) |e| return e;
        }
        for (results) |r| {
            try testing.expectEqual(@as(u8, 0), r.exit_code);
            try testing.expectEqualStrings("", r.stderr);
        }
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A third run over the directory the race left behind hits everything,
    // which is the assertion that no half-written file survived it.
    const after = try runCounted(&w, arena, &.{ "check", "--jobs=1", "--cache-dir=race0", "src" }, "after.json");
    try testing.expectEqual(@as(u64, 0), after.counters.checked);
    try testing.expectEqual(@as(u64, 0), after.counters.misses);
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

test "a flag that is not in the key cannot change one byte of one entry" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `fast-compiler.md` §8 lists every flag on `Cli.Common`, `Cli.Check`
    // and `Cli.Build` and says, for each, why it is IN the key or OUT of it.
    // The rows above falsify the "in" half — change it and the key moves.
    // This is the "out" half, and it is the one a key that was too WIDE
    // would fail: a flag that is out of the key must not reach a cached
    // byte either, or two builds that differ only in it would write two
    // different entries under one name and the later one would win by
    // accident.
    //
    // The backend's three are the interesting ones. They are out of the key
    // because no emitted byte is cached in M4-1, and nothing but this says
    // so out loud.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeProject(&w);

    const Pair = struct {
        what: []const u8,
        a: []const []const u8,
        b: []const []const u8,
        build: bool = false,
    };
    const pairs = [_]Pair{
        // Output is identical for every `n`, and keying on it would hide
        // the very bug the determinism rule forbids.
        .{ .what = "--jobs", .a = &.{"--jobs=1"}, .b = &.{"--jobs=8"} },
        // Rendering flags: they select how a message is printed.
        .{ .what = "--diagnostics", .a = &.{"--diagnostics=text"}, .b = &.{"--diagnostics=json"} },
        .{ .what = "--explain", .a = &.{}, .b = &.{"--explain"} },
        // A round trip must produce the same record, and exempting it would
        // excuse it from the acceptance matrix.
        .{ .what = "--roundtrip-interfaces", .a = &.{}, .b = &.{"--roundtrip-interfaces"} },
        .{ .what = "--roundtrip-dispatch", .a = &.{}, .b = &.{"--roundtrip-dispatch"} },
        // `--root` reaches the key through the module name and nowhere
        // else, so naming the root a module already has cannot move a byte.
        .{ .what = "--root", .a = &.{}, .b = &.{"--root=src"} },
        // The backend's, all four: no emitted byte is cached in M4-1.
        .{ .what = "--out", .a = &.{"--out=outa"}, .b = &.{"--out=outb"}, .build = true },
        .{ .what = "--library", .a = &.{"--out=outc"}, .b = &.{ "--out=outd", "--library" }, .build = true },
        .{ .what = "--release", .a = &.{"--out=oute"}, .b = &.{ "--out=outf", "--release" }, .build = true },
        // `--allow-debug` is the fourth and it gets its own scenario below,
        // because saying anything about it needs a project that reaches
        // `Debug` — on this one the flag lifts a refusal that never fires.
    };

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
    for (pairs, 0..) |pair, i| {
        const dir_a = try std.fmt.allocPrint(arena, "ca{d}", .{i});
        const dir_b = try std.fmt.allocPrint(arena, "cb{d}", .{i});
        try runFlagged(&w, arena, pair.build, pair.a, dir_a);
        try runFlagged(&w, arena, pair.build, pair.b, dir_b);
        expectSameCache(&w, arena, dir_a, dir_b) catch |err| {
            std.debug.print("{s} reached a cached byte and must not\n", .{pair.what});
            return err;
        };
    }
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
        \\pub shout : Int -> Int
        \\shout n =
        \\    Debug.log n "shouting"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const refused = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--library", "--release", "--out=refused", "--cache-dir=ra", "src" },
        "refused.json",
    );
    const allowed = try runCounted(
        &w,
        arena,
        &.{ "build", "--platform=node", "--library", "--release", "--allow-debug", "--out=allowed", "--cache-dir=rb", "src" },
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
        &.{ "build", "--platform=node", "--library", "--release", "--allow-debug", "--out=again", "--cache-dir=ra", "src" },
        "again.json",
    );
    try testing.expectEqual(@as(u8, 0), again.result.exit_code);
    try testing.expectEqual(@as(u64, 0), again.counters.checked);
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
/// M4-1's cost honest.
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
// columns**, which is why M4-2 needs a second key at all. A module key folds
// every import's key, so a body edit in a leaf moves three of them; a file
// key holds one file's lowering inputs and nothing else, so the same edit
// moves one. The leaf re-lowers; its importers re-check WITHOUT re-lowering.
//
// Asserted against `--frontend-keys` here, before a byte reaches disk, in
// exactly the way `--cache-keys` pins the module table above. The counters
// that follow in M2-f can then only confirm what this file already fixed.

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
    try testing.expect(keys.len >= 12);

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

    // Row 1: nothing. Rewritten with identical bytes, so a key that moved
    // here would be one that read an mtime.
    try w.write(leaf_file, leaf_source);
    try expectMoved("row 1, file keys", base_files, try baselineFileKeys(&w, arena), &.{});

    const Row = struct { what: []const u8, source: []const u8 };
    const rows = [_]Row{
        // Row 2: a body edit.
        .{ .what = "a body edit", .source =
        \\pub foreign twice : Int -> Int
        \\
        \\
        \\pub one : Int
        \\one =
        \\    2
        \\
        },
        // Row 3: a comment only. A comment is a token and `Bir` carries
        // `doc_start`/`doc_end`, so the file key MUST move — and this row
        // pins that it moves for `Leaf` ALONE. What it costs is one file's
        // lex, parse and lower; doing better needs a form-insensitive key,
        // which is M4-3's question and not this slice's.
        .{ .what = "a comment only", .source = "-- a comment nobody reads\n" ++ leaf_source },
        // Row 4: whitespace only — every token `start` after it moves.
        .{ .what = "whitespace only", .source = "\n" ++ leaf_source },
        // Row 5: a `pub` signature — one ADDED, so `Mid` still compiles and
        // the row measures the key rather than a type error.
        .{ .what = "a pub signature", .source = leaf_source ++
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
        // The divergence, stated on the same edit: three module keys move
        // where one file key did.
        try expectMoved(row.what, before_modules, try baselineKeys(&w, arena), &all_app);
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
    // …and adding it moved nothing that already existed (row 14).
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

    // Row 15: a sibling `.js` is not a lowering input, so editing one moves
    // no file key at all — and all three module keys.
    try w.write("src/Leaf.js", "export const twice = (n) => n + n;\n");
    try expectMoved("an edited sibling .js", base, try baselineFileKeys(&w, arena), &.{});
    try expectMoved("an edited sibling .js", base_modules, try baselineKeys(&w, arena), &all_app);
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
