//! The serialized interface, black-box
//! (`docs/design/checker.md` §7's *The serialized form*,
//! `fast-compiler.md` §8's interface hash,
//! `plans/m4-slice-zero.md` §7).
//!
//! Two hidden flags are the whole surface. `--roundtrip-interfaces`
//! replaces every module's record with serialize → bytes → deserialize of
//! itself the moment its check finishes, so the assertion is that NOTHING
//! downstream can tell: the same diagnostics, the same dumps, the same
//! emitted JavaScript, byte for byte. `--iface-hash` prints one
//! `<package>:<Module> <32 hex digits>` line per module, so the firewall's
//! quantity — "did this module's public face change?" — becomes something a
//! test and a bench can both state.
//!
//! Each claim is made on a small project built to reach it, not by a sweep
//! over the corpus: the columns `dump --stage=raw` does not print, the
//! encodings only a broken module produces, a build whose evidence crosses
//! modules through all three round trips, an importer's diagnostic that
//! prints types read back from a record, and the interner-order claim,
//! which needs two runs over DIFFERENT file sets.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

/// A project whose field, parameter and value names are deliberately in a
/// different order by TEXT than by declaration, over enough modules that
/// the workers interleave, and whose declarations carry the two things
/// `dump --stage=raw` prints but no pretty printer does: quantifier blocks
/// and `where` suffixes.
///
/// The same shape `blackbox_test.zig`'s record-determinism scenario uses,
/// written again here so the two files stay independent — this one is about
/// the FORMAT and that one is about `--jobs`.
fn writeShapes(w: *World) !void {
    for (0..12) |i| {
        var path: [32]u8 = undefined;
        var source: [1024]u8 = undefined;
        const n: u32 = @intCast(i);
        try w.write(
            try std.fmt.bufPrint(&path, "src/M{d}.beni", .{n}),
            try std.fmt.bufPrint(&source,
                \\pub type alias Rec{d} =
                \\    {{ zulu : Int, alpha : String, middle : Int, bravo : Float }}
                \\
                \\
                \\pub type Wrap{d} zeta alpha
                \\    = Pair{d} zeta alpha
                \\    | Empty{d}
                \\
                \\
                \\pub make{d} : Int -> Rec{d}
                \\make{d} n =
                \\    {{ zulu = n, alpha = "x", middle = n, bravo = 1.5 }}
                \\
                \\
                \\pub wrap{d} : zeta, alpha -> Wrap{d} zeta alpha
                \\wrap{d} a b =
                \\    Pair{d} a b
                \\
                \\
                \\pub pick{d} : zeta, zeta, alpha -> zeta
                \\    where alpha.compare : alpha, alpha -> Order
                \\    , zeta.eq : zeta, zeta -> Bool
                \\pick{d} a b tag =
                \\    if a.eq b then a else b
                \\
                \\
                \\pub near{d} a b =
                \\    a.close b 1
                \\
            , .{ n, n, n, n, n, n, n, n, n, n, n, n, n, n }),
        );
    }
}

/// Run `args` plain at `--jobs=1` and with `--roundtrip-interfaces` at
/// `--jobs=8`, and require the two runs to agree on exit code, stdout and
/// stderr. Returns the plain `--jobs=1` result so the caller can go on to
/// assert something about its CONTENT.
fn expectSameThroughTheFormat(w: *World, args: []const []const u8, arena: std.mem.Allocator) !world.Result {
    // One thread without the round trip against eight threads with it: a
    // difference from either shows, and whether a run is deterministic
    // across `--jobs` on its own is the determinism test's question.
    const variants = [2][2][]const u8{
        .{ "--jobs=1", "--jobs=1" },
        .{ "--jobs=8", "--roundtrip-interfaces" },
    };
    var first: ?world.Result = null;
    for (variants) |v| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, args);
        try argv.append(arena, v[0]);
        if (!std.mem.eql(u8, v[1], v[0])) try argv.append(arena, v[1]);
        const r = try w.runWith(argv.items, .{ .raw_diagnostics = true });
        const base = first orelse {
            first = r;
            continue;
        };
        testing.expectEqual(base.exit_code, r.exit_code) catch |err| {
            std.debug.print("exit code moved under {s} {s}\n", .{ v[0], v[1] });
            return err;
        };
        testing.expectEqualStrings(base.stdout, r.stdout) catch |err| {
            std.debug.print("stdout moved under {s} {s}\n", .{ v[0], v[1] });
            return err;
        };
        testing.expectEqualStrings(base.stderr, r.stderr) catch |err| {
            std.debug.print("stderr moved under {s} {s}\n", .{ v[0], v[1] });
            return err;
        };
    }
    return first.?;
}

test "a round-tripped record's raw dump is byte-identical, quantifiers and where clauses included" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Scheme.quantified_start` and `Quantified.constraints_start` are
    // exactly what `dump --stage=raw` does NOT print (checker.md §7), so no
    // existing golden can see them lost in the format — but the `q`,
    // `param` and `where` lines it DOES print are computed from them, so a
    // record that lost them prints differently. This is that assertion.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeShapes(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const base = try expectSameThroughTheFormat(&w, &.{ "dump", "--stage=raw", "src" }, arena_state.allocator());

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), base.exit_code);
    try testing.expectEqualStrings("", base.stderr);
    // The fixture really does exercise the three columns whose loss the
    // pretty printers hide; without this the equality above would also hold
    // for a record that carried none of them.
    try testing.expect(std.mem.indexOf(u8, base.stdout, "\n  q ") != null);
    try testing.expect(std.mem.indexOf(u8, base.stdout, "\n  param ") != null);
    try testing.expect(std.mem.indexOf(u8, base.stdout, "\n    where ") != null);
    try testing.expect(std.mem.indexOf(u8, base.stdout, "\nctor ") != null);
    try testing.expect(std.mem.indexOf(u8, base.stdout, "kind=alias") != null);
    try testing.expect(std.mem.indexOf(u8, base.stdout, "\ntyperef ") != null);
}

test "a record full of <error> travels through the format unchanged" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Term.Tag.err` and `SchemeIndex.none` are the two encodings nothing
    // else exercises: a clean project has neither. A module that publishes
    // `<error>` for some declarations and real schemes for others has both
    // in one record, and its DEPENDENT's diagnostics are what prove the
    // holes came back in the right places.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Holes.beni",
        \\pub broken : Int
        \\broken =
        \\    noSuchName
        \\
        \\
        \\pub alsoBroken x =
        \\    x + "text"
        \\
        \\
        \\pub fine : Int -> Int
        \\fine n =
        \\    n
        \\
    );
    try w.write("src/Uses.beni",
        \\import Holes
        \\
        \\
        \\pub ok : Int
        \\ok =
        \\    Holes.fine 1
        \\
        \\
        \\pub alsoOk : Int
        \\alsoOk =
        \\    Holes.broken
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
    const raw = try expectSameThroughTheFormat(&w, &.{ "dump", "--stage=raw", "src" }, arena_state.allocator());
    // `Term.Tag.err` really is in there, and so is a scheme built out of it.
    try testing.expect(std.mem.indexOf(u8, raw.stdout, " err 0 0\n") != null);

    const checked = try expectSameThroughTheFormat(
        &w,
        &.{ "check", "--diagnostics=json", "src" },
        arena_state.allocator(),
    );
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expect(checked.stderr.len != 0);
}

test "an empty record, and a module that never lowered, travel through the format" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `Interface.empty` and a `Ctor.arg_terms` that is still `no_terms` —
    // the sentinel a module that failed to lower leaves behind — are the
    // two shapes a project of working code never produces.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Nothing.beni",
        \\hidden : Int
        \\hidden =
        \\    1
        \\
    );
    try w.write("src/Unlowerable.beni",
        \\pub type Colour
        \\    = Red
        \\    | Green Int
        \\
        \\
        \\pub broken =
        \\    ( ( ( (
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
    const raw = try expectSameThroughTheFormat(&w, &.{ "dump", "--stage=raw", "src" }, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, raw.stdout, "module Nothing\n") != null);
    _ = try expectSameThroughTheFormat(&w, &.{ "check", "--diagnostics=json", "src" }, arena_state.allocator());
}

// ---------------------------------------------------------------------------
// `--iface-hash` (`fast-compiler.md` §8)
// ---------------------------------------------------------------------------

/// The `<32 hex digits>` of the one line whose key is `key`, or an error
/// naming what was there instead. The whole line is not returned on
/// purpose: a test that compared lines would pass on two runs that both
/// printed nothing.
fn hashOf(out: []const u8, key: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse {
            std.debug.print("--iface-hash printed a line with no hash: '{s}'\n", .{line});
            return error.MalformedHashLine;
        };
        if (!std.mem.eql(u8, line[0..space], key)) continue;
        const digits = line[space + 1 ..];
        if (digits.len != 32) {
            std.debug.print("--iface-hash printed {d} digits for {s}, not 32\n", .{ digits.len, key });
            return error.MalformedHashLine;
        }
        for (digits) |c| {
            if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.MalformedHashLine;
        }
        return digits;
    }
    std.debug.print("--iface-hash printed no line for {s}; it printed:\n{s}\n", .{ key, out });
    return error.NoSuchModule;
}

test "--iface-hash prints one sorted line per module, core included" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Zulu.beni",
        \\pub one : Int
        \\one =
        \\    1
        \\
    );
    try w.write("src/Alpha.beni",
        \\pub two : Int
        \\two =
        \\    2
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The key is `(package, name)` and not the name alone, and the package
    // is there because core's modules are on the list: `dump --stage=raw`
    // cannot see them and the firewall has to.
    _ = try hashOf(r.stdout, "app:Alpha");
    _ = try hashOf(r.stdout, "app:Zulu");
    _ = try hashOf(r.stdout, "core:Basics");
    _ = try hashOf(r.stdout, "core:String");

    // Sorted by that key's text, so the output is a function of the sources.
    var previous: []const u8 = "";
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const key = line[0..std.mem.indexOfScalar(u8, line, ' ').?];
        try testing.expect(std.mem.lessThan(u8, previous, key));
        previous = key;
        lines += 1;
    }
    try testing.expect(lines >= 10);
}

test "a module's hash does not depend on which files the interner saw first" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // **The fixture that fails first, and the one `dump --stage=raw` cannot
    // see.** A `Symbol` is an index into the session interner, whose
    // numbering depends on which worker interned which file — so a
    // `symbols` column written as raw ids would give `Zeta` a different
    // record the moment an unrelated module full of identifiers sorted
    // before it. `--stage=raw` is blind to this: it resolves symbol indices
    // to TEXT before printing. The hash is not, because it is taken over
    // the bytes.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Zeta.beni",
        \\pub type Tag
        \\    = Tag String
        \\
        \\
        \\pub label : Tag -> String
        \\label t =
        \\    case t of
        \\        Tag s ->
        \\            s
        \\
        \\
        \\pub pair : a, b -> ( a, b )
        \\pair x y =
        \\    ( x, y )
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const alone_1 = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), alone_1.exit_code);
    const alone_8 = try w.runWith(&.{ "check", "--iface-hash", "--jobs=8", "src" }, .{ .raw_diagnostics = true });
    const before = try hashOf(alone_1.stdout, "app:Zeta");
    try testing.expectEqualStrings(before, try hashOf(alone_8.stdout, "app:Zeta"));

    // An unrelated module, full of identifiers, sorting BEFORE `Zeta`, so
    // every name `Zeta` uses is interned after a few hundred others.
    {
        var source: std.Io.Writer.Allocating = .init(testing.allocator);
        defer source.deinit();
        for (0..200) |i| {
            try source.writer.print(
                \\pub noise{d} : Int -> Int
                \\noise{d} unrelatedParameter{d} =
                \\    unrelatedParameter{d}
                \\
                \\
                \\
            , .{ i, i, i, i });
        }
        try w.write("src/Aardvark.beni", source.written());
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_][]const u8{ "--jobs=1", "--jobs=8" }) |jobs| {
        const r = try w.runWith(&.{ "check", "--iface-hash", jobs, "src" }, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        testing.expectEqualStrings(before, try hashOf(r.stdout, "app:Zeta")) catch |err| {
            std.debug.print("Zeta's hash moved at {s} because another module was added\n", .{jobs});
            return err;
        };
        // Core is in the same session and equally untouched.
        _ = try hashOf(r.stdout, "core:Basics");
    }
}

/// The purity project of `blackbox_test.zig`'s `--stage=raw` scenarios,
/// restated here so the hash can be asked the same question the dump was.
fn writePurityProject(w: *World) !void {
    try w.write("src/Alpha.beni",
        \\pub type Solo
        \\    = Solo
        \\
    );
    try w.write("src/Mid.beni",
        \\pub type Tag
        \\    = Tag
        \\
        \\
        \\pub type Other
        \\    = Other
        \\
    );
    try w.write("src/Zeta.beni",
        \\import Mid exposing (Tag)
        \\
        \\
        \\pub type Pair a
        \\    = Pair a a
        \\
        \\
        \\pub mk : Int, Tag -> Pair Tag
        \\mk _ t =
        \\    Pair t t
        \\
    );
}

test "the firewall by hash: an edit elsewhere does not move a module's line" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // checker.md §7's purity rule, stated as the quantity the firewall
    // actually uses. The same four cumulative edits `--stage=raw` is asked
    // about, now asked of the hash — which is what `bench/churn.sh` reports
    // and what a cache key will compare.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writePurityProject(&w);
    const base = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), base.exit_code);
    const before = try hashOf(base.stdout, "app:Zeta");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY                        │
    // └─────────────────────────────────────────┘
    const edits = [_]struct { what: []const u8, path: []const u8, source: []const u8 }{
        .{ .what = "a pub type in a module Zeta does not import", .path = "src/Alpha.beni", .source =
        \\pub type Solo
        \\    = Solo
        \\
        \\
        \\pub type Extra
        \\    = Extra
        \\
        },
        .{ .what = "a PRIVATE type in a module Zeta does not import", .path = "src/Alpha.beni", .source =
        \\pub type Solo
        \\    = Solo
        \\
        \\
        \\pub type Extra
        \\    = Extra
        \\
        \\
        \\type Hidden
        \\    = Hidden
        \\
        },
        .{ .what = "a new file containing a type", .path = "src/Beta.beni", .source =
        \\pub type Thing
        \\    = Thing
        \\
        },
        .{ .what = "a type added to a module Zeta imports but does not name", .path = "src/Mid.beni", .source =
        \\pub type Tag
        \\    = Tag
        \\
        \\
        \\pub type Other
        \\    = Other
        \\
        \\
        \\pub type Added
        \\    = Added
        \\
        },
    };
    for (edits) |e| {
        try w.write(e.path, e.source);
        const r = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        testing.expectEqualStrings(before, try hashOf(r.stdout, "app:Zeta")) catch |err| {
            std.debug.print("Zeta's hash moved after adding {s}\n", .{e.what});
            return err;
        };
    }
}

test "the converse, by hash: a change the record DOES describe moves its line" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Without this the test above would also pass on a hash that never
    // moved at all, which is the failure mode a firewall measurement has:
    // a cutoff rate of 100% is either perfect or broken and the number
    // cannot tell you which.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writePurityProject(&w);
    const base = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), base.exit_code);
    const zeta_before = try hashOf(base.stdout, "app:Zeta");
    const mid_before = try hashOf(base.stdout, "app:Mid");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY: the type Zeta names is renamed │
    // └─────────────────────────────────────────┘
    try w.write("src/Mid.beni",
        \\pub type Label
        \\    = Tag
        \\
        \\
        \\pub type Other
        \\    = Other
        \\
    );
    try w.write("src/Zeta.beni",
        \\import Mid exposing (Label)
        \\
        \\
        \\pub type Pair a
        \\    = Pair a a
        \\
        \\
        \\pub mk : Int, Label -> Pair Label
        \\mk _ t =
        \\    Pair t t
        \\
    );
    {
        const r = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        try testing.expect(!std.mem.eql(u8, zeta_before, try hashOf(r.stdout, "app:Zeta")));
        try testing.expect(!std.mem.eql(u8, mid_before, try hashOf(r.stdout, "app:Mid")));
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY: a constructor is added to an exported type │
    // └─────────────────────────────────────────┘
    try writePurityProject(&w);
    const restored = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqualStrings(mid_before, try hashOf(restored.stdout, "app:Mid"));
    try w.write("src/Mid.beni",
        \\pub type Tag
        \\    = Tag
        \\    | Extra
        \\
        \\
        \\pub type Other
        \\    = Other
        \\
    );
    {
        const r = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        try testing.expect(!std.mem.eql(u8, mid_before, try hashOf(r.stdout, "app:Mid")));
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY: a local arity changes │
    // └─────────────────────────────────────────┘
    try writePurityProject(&w);
    try w.write("src/Zeta.beni",
        \\import Mid exposing (Tag)
        \\
        \\
        \\pub type Pair a
        \\    = Pair a a a
        \\
        \\
        \\pub mk : Int, Tag -> Pair Tag
        \\mk _ t =
        \\    Pair t t t
        \\
    );
    {
        const r = try w.runWith(&.{ "check", "--iface-hash", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        try testing.expect(!std.mem.eql(u8, zeta_before, try hashOf(r.stdout, "app:Zeta")));
    }
}

test "a build's emitted JavaScript is byte-identical under --roundtrip-interfaces" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The point of doing the round trip inside `fillInterface` rather than
    // in a test harness: everything DOWNSTREAM of the record is built from
    // the loaded one. The dispatch table, reachability and the emitter all
    // read interfaces, so the strongest single assertion available is that
    // the whole output tree comes out the same.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Shapes.beni",
        \\pub type Shape
        \\    = Circle Float
        \\    | Rect Float Float
        \\
        \\
        \\pub area : Shape -> Float
        \\area s =
        \\    case s of
        \\        Circle r ->
        \\            r * r
        \\
        \\        Rect x y ->
        \\            x * y
        \\
    );
    try w.write("src/Main.beni",
        \\import Node
        \\import Shapes exposing (Shape)
        \\
        \\
        \\pub main : Node.Program
        \\main =
        \\    Node.print (String.fromFloat (Shapes.area (Shapes.Circle 2.0)))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const plain = try w.runWith(
        &.{ "build", "--platform=node", "--out=plain", "--jobs=1", "src" },
        .{ .raw_diagnostics = true },
    );
    try testing.expectEqual(@as(u8, 0), plain.exit_code);
    const files = try w.listFiles("plain");
    try testing.expect(files.len > 1);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_][]const u8{ "--jobs=1", "--jobs=8" }) |jobs| {
        const out_dir = if (std.mem.eql(u8, jobs, "--jobs=1")) "rt1" else "rt8";
        const out_flag = if (std.mem.eql(u8, jobs, "--jobs=1")) "--out=rt1" else "--out=rt8";
        const r = try w.runWith(
            &.{ "build", "--platform=node", out_flag, jobs, "--roundtrip-interfaces", "src" },
            .{ .raw_diagnostics = true },
        );
        try testing.expectEqual(plain.exit_code, r.exit_code);
        try testing.expectEqualStrings(plain.stdout, r.stdout);
        try testing.expectEqualStrings(plain.stderr, r.stderr);

        const rt_files = try w.listFiles(out_dir);
        try testing.expectEqual(files.len, rt_files.len);
        for (files, rt_files) |a, b| {
            try testing.expectEqualStrings(a, b);
            var plain_path: [256]u8 = undefined;
            var rt_path: [256]u8 = undefined;
            const want = try w.read(try std.fmt.bufPrint(&plain_path, "plain/{s}", .{a}));
            const got = try w.read(try std.fmt.bufPrint(&rt_path, "{s}/{s}", .{ out_dir, b }));
            testing.expectEqualStrings(want, got) catch |err| {
                std.debug.print("{s} differs between a cold build and a round-tripped one\n", .{a});
                return err;
            };
        }
    }
}

/// Two modules whose evidence crosses the boundary: `Shapes` declares a
/// type with a derived `eq` and `compare`, a record alias with a parameter
/// and a constrained generic, and `Main` compares `Shape`s with `==` and
/// `<`, through `bigger`'s `where` clause and inside a `List`. The importer
/// reads every one of those from the record, the dispatch sidecar and the
/// front-end artifact, which are what the round-trip flags replace with
/// copies read back from their bytes.
fn writeDispatching(w: *World) !void {
    try w.write("src/Shapes.beni",
        \\pub type Shape
        \\    = Circle Int
        \\    | Rect Int Int
        \\
        \\
        \\pub type alias Named a =
        \\    { name : String, value : a }
        \\
        \\
        \\pub bigger : a, a -> a
        \\    where a.compare : a, a -> Order
        \\bigger a b =
        \\    if a < b then b else a
        \\
        \\
        \\pub named : String, a -> Named a
        \\named name value =
        \\    { name = name, value = value }
        \\
    );
    try w.write("src/Main.beni",
        \\import Node
        \\import Shapes exposing (Named, Shape, Circle, Rect)
        \\
        \\
        \\largest : Named Shape
        \\largest =
        \\    Shapes.named "largest" (Shapes.bigger (Circle 2) (Rect 3 4))
        \\
        \\
        \\pub main : Node.Program
        \\main =
        \\    Node.printLines
        \\        [ largest.name
        \\        , if largest.value == Rect 3 4 then "rect" else "circle"
        \\        , if [ Circle 1, Rect 1 1 ] == [ Circle 1, Rect 1 1 ] then "same" else "different"
        \\        ]
        \\
    );
}

test "a build whose evidence crosses modules is byte-identical through all three round trips, and runs" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The dispatch sidecar is the round trip whose loss shows up as a wrong
    // PROGRAM rather than a wrong message, and the front-end artifact is the
    // one whose loss would depend on history. So the claim is made on a
    // build, over the whole output tree, and the round-tripped program is
    // then run. `--jobs=8` against a `--jobs=1` baseline, so a byte moved
    // by the worker count fails here too.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeDispatching(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const plain = try w.runWith(
        &.{ "build", "--platform=node", "--out=plain", "--jobs=1", "--no-cache", "src" },
        .{ .raw_diagnostics = true },
    );
    const tripped = try w.runWith(&.{
        "build",                  "--platform=node",      "--out=tripped",        "--jobs=8", "--no-cache",
        "--roundtrip-interfaces", "--roundtrip-dispatch", "--roundtrip-frontend", "src",
    }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), plain.exit_code);
    try testing.expectEqualStrings("", plain.stderr);
    try testing.expectEqual(plain.exit_code, tripped.exit_code);
    try testing.expectEqualStrings(plain.stdout, tripped.stdout);
    try testing.expectEqualStrings(plain.stderr, tripped.stderr);

    const want = try w.listFiles("plain");
    const got = try w.listFiles("tripped");
    try testing.expect(want.len > 1);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| {
        try testing.expectEqualStrings(a, b);
        const want_bytes = try w.read(try std.fs.path.join(arena, &.{ "plain", a }));
        const got_bytes = try w.read(try std.fs.path.join(arena, &.{ "tripped", b }));
        testing.expectEqualStrings(want_bytes, got_bytes) catch |err| {
            std.debug.print("{s} differs between a plain build and a round-tripped one\n", .{a});
            return err;
        };
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // `Rect 3 4` is the bigger of the two — a derived `compare` orders by
    // constructor first — and two equal lists compare equal element-wise.
    try w.expectProgram("tripped/_main.mjs", .{ .stdout = "largest\nrect\nsame\n" });
}

test "an importer's type error names the imported types identically through the round trip" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A diagnostic in an importer prints types it read from the exporter's
    // record — here a parameterised alias and a custom type, both declared
    // in `Shapes` — so a record that came back from its bytes subtly
    // different would print a different message or blame a different span,
    // where a clean project would still check.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeDispatching(&w);
    try w.write("src/Wrong.beni",
        \\import Shapes exposing (Named, Shape, Circle, Rect)
        \\
        \\
        \\wrong : Shape
        \\wrong =
        \\    Shapes.named "wrong" (Circle 7)
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try expectSameThroughTheFormat(
        &w,
        &.{ "check", "--platform=node", "--diagnostics=json", "src" },
        arena_state.allocator(),
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expectEqualStrings("", checked.stdout);
    // Captured from a run. Both types in the message are `Shapes`' own.
    try testing.expectEqualStrings(
        \\[{"code":"type_mismatch","severity":"error","span":{"file":"src/Wrong.beni","start":{"line":6,"col":5},"end":{"line":6,"col":17}},"title":"TYPE MISMATCH","message":"Something is off with the body of this definition:\n\nThe body is:\n\n    Named a\n\nBut the type annotation says it should be:\n\n    Shape\n"}]
        \\
    , checked.stderr);
}
