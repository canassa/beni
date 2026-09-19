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
