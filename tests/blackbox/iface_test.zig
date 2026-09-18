//! M4 slice zero: the serialized interface, black-box
//! (`docs/design/checker.md` §7's *The serialized form*,
//! `fast-compiler.md` §8's *The interface hash, and slice zero*,
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
//! The corpus-wide version of the first assertion lives in
//! `corpus_test.zig`, which runs every checker-driven fixture through the
//! whole {plain, round-tripped} × {`--jobs=1`, `--jobs=8`} cross. What is
//! here is what the corpus cannot say: the claims about the columns
//! `dump --stage=raw` does not print, and the interner-order claim, which
//! needs two runs over DIFFERENT file sets rather than one run of one
//! fixture.

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

/// Run `args` plain and with `--roundtrip-interfaces`, at `--jobs=1` and
/// `--jobs=8`, and require all four runs to agree on exit code, stdout and
/// stderr. Returns the plain `--jobs=1` result so the caller can go on to
/// assert something about its CONTENT.
fn expectSameThroughTheFormat(w: *World, args: []const []const u8, arena: std.mem.Allocator) !world.Result {
    const variants = [4][2][]const u8{
        .{ "--jobs=1", "--jobs=1" },
        .{ "--jobs=8", "--jobs=8" },
        .{ "--jobs=1", "--roundtrip-interfaces" },
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
