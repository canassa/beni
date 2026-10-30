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
    \\pub area : Shape → Float
    \\area shape =
    \\    case shape of
    \\        Circle r →
    \\            3.5 * r * r
    \\
    \\        Square s →
    \\            toFloat (s * s)
    \\
    \\
    \\pub member : D.Dict k v, k → Bool
    \\    where k.compare : k, k → Order
    \\member d k =
    \\    d.member k
    \\
    \\
    \\-- A plain comment between declarations.
    \\label : Point, String → String
    \\label p name =
    \\    ( a, b ) =
    \\        ( p.x, p.y )
    \\
    \\    moved =
    \\        { p | x = a + 1 }
    \\
    \\    twice =
    \\        λn → n * 2
    \\    "${name}: ${twice moved.x} \t ${b}"
    \\
    \\
    \\tail =
    \\    [ 1, 2, 3 ] ▷ List.map λn → n + 1
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
            "--roundtrip-frontend changed `{s} {s}`:\nexit {d} → {d}\n--- plain ---\n{s}{s}\n--- round-tripped ---\n{s}{s}\n",
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

const text_import_main =
    \\import "./shader.wgsl" as shader : String
    \\import Node
    \\
    \\
    \\main : Node.Program
    \\main =
    \\    Node.print shader
    \\
;

test "text imports preserve UTF-8 text in development and release through all round trips" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const text = "\xef\xbb\xbf@vertex fn main() {\r\n\t// \"quotes\" \\ 🌍\x00\xe2\x80\xa8\xe2\x80\xa9\r\n}\n";
    try w.write("src/Main.beni", text_import_main);
    try w.write("src/shader.wgsl", text);
    // A different cwd-relative file must never be read.
    try w.write("shader.wgsl", "wrong file");
    for ([_]bool{ false, true }) |release| {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(testing.allocator);
        try args.appendSlice(testing.allocator, &.{ "build", "--platform=node", "--out=out", "--roundtrip-frontend", "--roundtrip-interfaces", "--roundtrip-dispatch", "src/Main.beni" });
        if (release) try args.append(testing.allocator, "--release");
        const built = try w.run(args.items);
        try testing.expectEqual(@as(u8, 0), built.exit_code);
        try testing.expectEqual(@as(usize, 0), built.diagnostics.len);
        try w.expectProgram("out/_main.mjs", .{ .stdout = text ++ "\n" });
    }
}

test "text import warm builds reload edits and reject deletions without writing output" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", text_import_main);
    try w.write("src/shader.wgsl", "first");
    const args = &.{ "build", "--platform=node", "--cache-dir=cache", "--out=out", "src" };
    const cold = try w.run(args);
    try testing.expectEqual(@as(u8, 0), cold.exit_code);
    try w.expectProgram("out/_main.mjs", .{ .stdout = "first\n" });
    try w.write("src/shader.wgsl", "other"); // same byte count
    const warm = try w.run(args);
    try testing.expectEqual(@as(u8, 0), warm.exit_code);
    try w.expectProgram("out/_main.mjs", .{ .stdout = "other\n" });
    try w.tmp.dir.deleteFile(w.io, "src/shader.wgsl");
    const missing = try w.run(args);
    try testing.expectEqual(@as(u8, 1), missing.exit_code);
    try testing.expectEqual(@as(usize, 1), missing.diagnostics.len);
    try testing.expectEqual(.text_import_failed, missing.diagnostics[0].code);
    // A failed rebuild leaves the previous, complete output.
    try w.expectProgram("out/_main.mjs", .{ .stdout = "other\n" });
    try w.write("src/shader.wgsl", "again");
    const repaired = try w.run(args);
    try testing.expectEqual(@as(u8, 0), repaired.exit_code);
    try w.expectProgram("out/_main.mjs", .{ .stdout = "again\n" });
}

test "text imports diagnose invalid UTF-8 and unreadable files at the literal" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", text_import_main);
    for ([_][]const u8{ "\xff", "\xc0\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80" }) |invalid| {
        try w.write("src/shader.wgsl", invalid);
        const bad = try w.run(&.{ "build", "--platform=node", "--out=out", "src" });
        try testing.expectEqual(@as(u8, 1), bad.exit_code);
        try testing.expectEqualDeep(&[_]@import("diagnostic").Diagnostic{.{
            .code = .text_import_failed,
            .severity = .@"error",
            .span = .{ .file = "src/Main.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 9 } },
            .title = "CANNOT IMPORT TEXT",
            .message = "This text import is not valid UTF-8. Save the file as UTF-8; no replacement\ncharacters or newline conversions are applied.",
        }}, bad.diagnostics);
        try testing.expect(!w.exists("out"));
    }
    try w.tmp.dir.deleteFile(w.io, "src/shader.wgsl");
    try w.tmp.dir.createDir(w.io, "src/shader.wgsl", .default_dir);
    const directory = try w.run(&.{ "build", "--platform=node", "--out=out", "src" });
    try testing.expectEqual(@as(u8, 1), directory.exit_code);
    try testing.expectEqual(@as(usize, 1), directory.diagnostics.len);
    try testing.expectEqual(.text_import_failed, directory.diagnostics[0].code);
}

test "text import values use ordinary type resolution and name collisions" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/shader.wgsl", "text");
    for ([_][]const u8{
        "import \"./shader.wgsl\" as shader : Int\n",
        "import \"./shader.wgsl\" as shader : a\n",
        "import \"./shader.wgsl\" as shader : String\nshader = 1\n",
        "import \"./shader.wgsl\" as shader : String\ntype String = Other\n",
    }) |source| {
        try w.write("src/M.beni", source);
        const bad = try w.run(&.{ "check", "src" });
        try testing.expectEqual(@as(u8, 1), bad.exit_code);
        try testing.expect(bad.diagnostics.len > 0);
    }
    try w.write("src/M.beni", "import \"./shader.wgsl\" as shader : Text\ntype alias Text = String\npub value = shader\n");
    const alias = try w.run(&.{ "check", "src" });
    try testing.expectEqual(@as(u8, 0), alias.exit_code);
}

test "text import formatter is idempotent and unreachable text is eliminated" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Lib.beni", "import \"./dead.txt\" as unused : String\nimport \"./empty.txt\" as empty : String\npub answer = 42\n");
    try w.write("src/dead.txt", "UNREACHABLE_TEXT_SENTINEL");
    try w.write("src/empty.txt", "");
    const fmt = try w.run(&.{ "fmt", "src" });
    try testing.expectEqual(@as(u8, 0), fmt.exit_code);
    const formatted = try w.read("src/Lib.beni");
    try testing.expect(std.mem.indexOf(u8, formatted, "as unused : String\n") != null);
    const again = try w.run(&.{ "fmt", "--check", "src" });
    try testing.expectEqual(@as(u8, 0), again.exit_code);
    for ([_][]const u8{ "--no-source-maps", "--release" }) |flag| {
        const built = try w.run(&.{ "build", "--platform=node", "--library", flag, "--out=out", "src" });
        try testing.expectEqual(@as(u8, 0), built.exit_code);
        const js = try w.read("out/Lib.mjs");
        try testing.expect(std.mem.indexOf(u8, js, "UNREACHABLE_TEXT_SENTINEL") == null);
        try testing.expect(std.mem.indexOf(u8, js, "dead.txt") == null);
    }
}

test "malformed text imports recover without reading interpolated paths" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    for ([_][]const u8{
        "import \"./x.txt\" as source\n",
        "import \"./x.txt\" : String\n",
        "import \"./x.txt\" as Upper : String\n",
        "import \"./x.txt\" as source : String exposing (x)\n",
        "import \"./{name}.txt\" as source : String\n",
        "import \"\" as source : String\n",
        "import \"./x\\u{0000}.txt\" as source : String\n",
    }) |source| {
        try w.write("src/M.beni", source);
        const bad = try w.run(&.{ "check", "--roundtrip-frontend", "src" });
        try testing.expectEqual(@as(u8, 1), bad.exit_code);
        try testing.expect(bad.diagnostics.len > 0);
    }
}
