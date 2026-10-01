//! `--roundtrip-frontend` as an IDENTITY ORACLE (`fast-compiler.md` §8's
//! *The front-end artifacts, and the file key*).
//!
//! **This is the front-end cache's cut line.** Everything risky about the
//! front-end artifact — the symbol column travelling as text and being
//! re-interned into a worker's own pool, the token columns losing two of
//! four, the `Bir` being reached by raw index by four later passes — is
//! settled here, with no cache directory in sight and no byte written to
//! one. The cache's disk I/O is built on top of a format that is already
//! known to be lossless.
//!
//! The round trip runs where lowering ends, so only a command that lowers
//! reaches it: `dump --stage=bir` prints the record that came off the
//! format, and `check` positions and renders its diagnostics from the token
//! starts and the line-start table the round trip replaced. `dump
//! --stage=tokens|ast` and `fmt` stop before lowering, so they are
//! unchanged by construction and are not oracles for it. Every column of the
//! CONTAINER is `artifact_bytes.zig`'s unit tests'; what is here is the
//! compiler installing what came back, on a few sources chosen so that every
//! section an output can show is non-empty:
//!
//!   * one file with a declaration of every kind, doc comments, strings,
//!     floats, patterns, a `where` clause and an aliased import: every
//!     `Bir` section, and the symbols' re-interning;
//!   * a type error, whose position comes from the token starts and the
//!     line starts;
//!   * a file with lex, parse and lower diagnostics, plus the degenerate
//!     shapes: empty (no symbol to re-intern), comment-only, failed to parse.
//!
//! A build through all three `--roundtrip-*` flags is `iface_test.zig`'s,
//! on a project whose evidence crosses modules.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

/// Every `Bir` section is non-empty for this file: declarations of every
/// kind (type, opaque type, alias, schema, annotated and unannotated
/// values), constructors, locals, refs, an import with an alias and an
/// exposing list, the interface, the extra array, string bytes (a literal,
/// an escape, interpolation) and symbols used more than once, so the string
/// table deduplicates. Formatted, as the formatter writes it.
const every_section =
    \\--! A module doc.
    \\
    \\import Dict as D exposing (Dict)
    \\
    \\
    \\--| A doc comment on a pub type with constructors.
    \\pub type Shape
    \\    = Circle Float
    \\    | Square Int
    \\
    \\
    \\pub opaque type Box a
    \\    = Box a
    \\
    \\
    \\pub type alias Point =
    \\    x : Int
    \\    y : Int
    \\
    \\
    \\schema Pair =
    \\    left : Int
    \\    right : String
    \\
    \\
    \\pub area : Shape -> Float
    \\area shape =
    \\    case shape of
    \\        Circle r ->
    \\            3.5 * r * r
    \\
    \\        Square s ->
    \\            toFloat (s * s)
    \\
    \\
    \\pub member : D.Dict k v, k -> Bool
    \\    where k.compare : k, k -> Order
    \\member d k =
    \\    d.member k
    \\
    \\
    \\-- A plain comment between declarations.
    \\label : Point, String -> String
    \\label p name =
    \\    ( a, b ) =
    \\        ( p.x, p.y )
    \\
    \\    moved =
    \\        { p | x = a + 1 }
    \\
    \\    twice =
    \\        λn -> n * 2
    \\    "${name}: ${twice moved.x} \t ${b}"
    \\
    \\
    \\tail =
    \\    [ 1, 2, 3 ] |> List.map (λn -> n + 1)
    \\
;

test "a file that fills every section of the artifact dumps the same Bir under the flag" {
    // A lossy section, or symbols left as string-table indices, changes the
    // dump; one the reader refuses changes the exit code.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    try w.write("src/Everything.beni", every_section);
    const abs = try w.projectSubPath(arena, "src/Everything.beni");
    // A dump of nothing would pass.
    const plain = try w.runWith(&.{ "dump", "--stage=bir", abs }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), plain.exit_code);
    try expectSameInProject(&w, arena, &.{ "dump", "--stage=bir", abs });
    try expectSameInProject(&w, arena, &.{ "check", "--no-cache", "--diagnostics=json", abs });
}

test "a type error after the round trip is at the same line and column" {
    // The checker positions a diagnostic by its tokens' starts and renders
    // the position through the line-start table, and the round trip
    // replaced both columns; no dump prints either.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    try w.write("src/Mistyped.beni", "pub label : Int\nlabel =\n    \"not an int\"\n");
    const abs = try w.projectSubPath(arena, "src/Mistyped.beni");
    // An oracle over a clean check would pass.
    const plain = try w.runWith(&.{ "check", "--no-cache", "--diagnostics=json", abs }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 1), plain.exit_code);
    try expectSameInProject(&w, arena, &.{ "check", "--no-cache", "--diagnostics=json", abs });
}

/// A tab (lex), an unterminated declaration (parse) and a duplicate
/// definition (lower), in one file, so all three waves are in one stream
/// and their relative order is asserted with them; then the degenerate
/// shapes: empty (no symbol to re-intern), comment-only, failed to parse.
/// The tab is written as an escape because a Zig multiline literal may not
/// hold one — which is the same reason `tab_in_source` exists.
fn writeDegenerateFiles(w: *World) !void {
    try w.write("src/Bad.beni", "pub one : Int\none =\n\t1\n\n\npub one : Int\none =\n    2\n");
    try w.write("src/Empty.beni", "");
    try w.write("src/Comment.beni", "-- nothing but a comment\n");
    try w.write("src/Unparsed.beni", "pub x = = =\n");
}

test "lex, parse and lower diagnostics of several files replay byte for byte" {
    // The front end's diagnostics travel as the PROSE the phase rendered,
    // with positions rather than offsets, so a replay has to reproduce the
    // message, the severity, the span and the ORDER — and a run with the
    // flag renders from the replayed rows and not from the ones the phase
    // made. The whole project in one check puts every file's replayed rows
    // into one sorted stream, the degenerate files' included.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeDegenerateFiles(&w);

    // An oracle over a clean check would pass.
    const plain = try w.runWith(&.{ "check", "--no-cache", "--diagnostics=json", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 1), plain.exit_code);
    try expectSameInProject(&w, arena, &.{ "check", "--no-cache", "--diagnostics=json", "src" });
}

test "a file with diagnostics, an empty one, a comment-only one and an unparsed one dump the same Bir" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeDegenerateFiles(&w);

    for ([_][]const u8{ "src/Bad.beni", "src/Empty.beni", "src/Comment.beni", "src/Unparsed.beni" }) |path| {
        try expectSameInProject(&w, arena, &.{ "dump", "--stage=bir", try w.projectSubPath(arena, path) });
    }
}

test "a file of markup replays its diagnostics and dumps the same Bir under the flag" {
    // The markup token kinds are the newest tags in the token column, so
    // a reader that bounds the column by the old tag set refuses the
    // artifact and changes the exit code; a stray `<` in text (the lexer's
    // diagnostic) and the markup itself (the parser's) are positioned
    // from the token starts the round trip replaced.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    try w.write("src/View.beni", "view name =\n    <p class=\"a\">Hi {name}, a < b</p>\n\n\nafter a b =\n    a <b\n");
    const abs = try w.projectSubPath(arena, "src/View.beni");
    // An oracle over a clean check would pass.
    const plain = try w.runWith(&.{ "check", "--no-cache", "--diagnostics=json", abs }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 1), plain.exit_code);
    try expectSameInProject(&w, arena, &.{ "check", "--no-cache", "--diagnostics=json", abs });
    try expectSameInProject(&w, arena, &.{ "dump", "--stage=bir", abs });
}

/// One command with and without the flag, with cwd = the world's project
/// directory: same exit code, same stdout, same stderr, to the byte. A
/// `check` passes `--no-cache`: with a cache, the flagged run would load the
/// plain run's front-end artifact instead of round-tripping its own.
fn expectSameInProject(w: *World, arena: std.mem.Allocator, args: []const []const u8) !void {
    var with: std.ArrayList([]const u8) = .empty;
    try with.appendSlice(arena, args);
    try with.append(arena, "--roundtrip-frontend");
    const plain = try w.runWith(args, .{ .raw_diagnostics = true });
    const flagged = try w.runWith(with.items, .{ .raw_diagnostics = true });
    if (plain.exit_code != flagged.exit_code or
        !std.mem.eql(u8, plain.stdout, flagged.stdout) or
        !std.mem.eql(u8, plain.stderr, flagged.stderr))
    {
        std.debug.print(
            "--roundtrip-frontend changed `{s} {s}`:\nexit {d} -> {d}\n--- plain ---\n{s}{s}\n--- round-tripped ---\n{s}{s}\n",
            .{ args[0], args[args.len - 1], plain.exit_code, flagged.exit_code, plain.stdout, plain.stderr, flagged.stdout, flagged.stderr },
        );
        return error.RoundTripDiffers;
    }
}

test "--roundtrip-frontend is hidden, and is accepted by every subcommand" {
    // Hidden for `--roundtrip-interfaces`' reasons: it is diagnostic surface
    // rather than product surface. Accepted everywhere because it is on
    // `Common`, which is what lets `dump` take it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    const help = try w.runWith(&.{"--help"}, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), help.exit_code);
    try testing.expect(std.mem.indexOf(u8, help.stdout, "--roundtrip-frontend") == null);

    try w.write("src/M.beni", "pub x : Int\nx =\n    1\n");
    for ([_][]const u8{ "check", "fmt", "dump" }) |command| {
        const r = if (std.mem.eql(u8, command, "dump"))
            try w.runWith(&.{ "dump", "--stage=bir", "--roundtrip-frontend", "src/M.beni" }, .{ .raw_diagnostics = true })
        else
            try w.runWith(&.{ command, "--roundtrip-frontend", "src" }, .{ .raw_diagnostics = true });
        if (r.exit_code == 2) {
            std.debug.print("`beni {s} --roundtrip-frontend` exited 2:\n{s}\n", .{ command, r.stderr });
            return error.FlagRefused;
        }
    }
    // It takes no value, like its two siblings.
    const valued = try w.runWith(&.{ "check", "--roundtrip-frontend=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 2), valued.exit_code);
}
