//! Black-box scenarios for the M0 CLI, the M1a lexer and the M1b parser
//! (docs/design/frontend.md §1, §1.2, §8).
//!
//! Every scenario spawns the installed binary through `world.zig` and
//! asserts whole objects: the exact stdout, the exact stderr or the entire
//! parsed diagnostic list, the exit code. Nothing here can see inside the
//! compiler; if a behaviour is unreachable through files and flags, that is
//! a design bug to report, not to work around.

const std = @import("std");
const diagnostic = @import("diagnostic");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

const expected_version = "beni 0.0.0-m0\n";

test "version prints the version on stdout and nothing else" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{"version"});

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings(expected_version, r.stdout);
    try testing.expectEqualStrings("", r.stderr);
}

test "help exits 0 and prints usage on stdout" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{"help"});

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expect(std.mem.startsWith(u8, r.stdout, "usage: beni <command> [options] [<path>...]\n"));
    for ([_][]const u8{ "  check ", "  fmt ", "  dump ", "  version ", "  help ", "--diagnostics=text|json", "--self-profile=<path>", "--jobs=<n>", "--root=<dir>", "--stage=tokens|ast|bir", "--positions" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, r.stdout, needle) != null);
    }
    try testing.expectEqualStrings("", r.stderr);
}

test "check on a directory with two empty modules: exit 0, no diagnostics, no output" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", "");
    try w.write("src/Page/Home.beni", "");
    // Hidden entries and non-.beni files are not modules.
    try w.write("src/.hidden/Bad name.beni", "");
    try w.write("src/notes.txt", "not a module");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), r.diagnostics);
}

test "check on a single file names the module from its own directory" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // `lowercase/Main.beni` would be an invalid module path if the root
    // were the project; for a file argument the root is the file's own
    // directory, so this is just `Main`.
    try w.write("lowercase/Main.beni", "main = 1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "lowercase/Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), r.diagnostics);
}

test "check on a file whose path segment is not an upper identifier: exactly one invalid_module_path" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", "main = 1\n");
    try w.write("src/bad-name.beni", "x = 1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .invalid_module_path,
        .severity = .@"error",
        .span = .{ .file = "src/bad-name.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
        .title = "INVALID MODULE PATH",
        .message = "I cannot turn the path `src/bad-name.beni` into a module name.\n" ++
            "\n" ++
            "A module name comes from the path: `src/Json/Decode.beni` is `Json.Decode`. Every\n" ++
            "segment of the path after the source root must be an upper identifier — a capital\n" ++
            "letter followed by letters, digits or underscores.",
    }, r.diagnostics[0]);
}

test "--root changes which path segments name the module" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("app/src/Main.beni", "main = 1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // With the root at `app`, the module path is `src/Main` and `src` is
    // not an upper identifier; with the root at `app/src` it is `Main`.
    const bad = try w.run(&.{ "check", "--root=app", "app/src" });
    const good = try w.run(&.{ "check", "--root=app/src", "app/src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), bad.exit_code);
    try testing.expectEqual(@as(usize, 1), bad.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.invalid_module_path, bad.diagnostics[0].code);
    try testing.expectEqualStrings("app/src/Main.beni", bad.diagnostics[0].span.file);
    try testing.expectEqual(@as(u8, 0), good.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), good.diagnostics);
}

test "the text renderer lays the diagnostic out Elm-style with an excerpt" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/bad-name.beni", "x = 1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "check", "src" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualStrings(
        "-- INVALID MODULE PATH ----------------------------------- src/bad-name.beni:1:1\n" ++
            "\n" ++
            "I cannot turn the path `src/bad-name.beni` into a module name.\n" ++
            "\n" ++
            "A module name comes from the path: `src/Json/Decode.beni` is `Json.Decode`. Every\n" ++
            "segment of the path after the source root must be an upper identifier — a capital\n" ++
            "letter followed by letters, digits or underscores.\n" ++
            "\n" ++
            "1|x = 1\n" ++
            "  ^\n",
        r.stderr,
    );
}

test "--self-profile writes a Chrome trace with a read event per file and the counters" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", "main = 1\n"); // 9 bytes
    try w.write("src/Util.beni", "helper x = x\n"); // 13 bytes

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "--self-profile=trace.json", "--jobs=2", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    const Event = struct {
        name: []const u8,
        ph: []const u8,
        tid: u32,
        args: struct { file: ?[]const u8 = null, bytes: ?u64 = null, files: ?u64 = null, diagnostics: ?u64 = null },
    };
    const text = try w.read("trace.json");
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const events = parsed.value.traceEvents;

    // One `read` X event per file, carrying the file's path and size.
    var read_main = false;
    var read_util = false;
    var saw_enumerate = false;
    var saw_merge = false;
    var saw_render = false;
    var counter_files: ?u64 = null;
    var counter_bytes: ?u64 = null;
    var counter_diagnostics: ?u64 = null;
    for (events) |e| {
        if (std.mem.eql(u8, e.ph, "X")) {
            if (std.mem.eql(u8, e.name, "read")) {
                if (std.mem.eql(u8, e.args.file.?, "src/Main.beni")) {
                    try testing.expectEqual(@as(?u64, 9), e.args.bytes);
                    read_main = true;
                } else if (std.mem.eql(u8, e.args.file.?, "src/Util.beni")) {
                    try testing.expectEqual(@as(?u64, 13), e.args.bytes);
                    read_util = true;
                } else return error.UnexpectedReadEvent;
                try testing.expect(e.tid < 2);
            } else if (std.mem.eql(u8, e.name, "enumerate")) {
                saw_enumerate = true;
            } else if (std.mem.eql(u8, e.name, "merge_interners")) {
                saw_merge = true;
            } else if (std.mem.eql(u8, e.name, "render")) {
                saw_render = true;
            }
        } else if (std.mem.eql(u8, e.ph, "C")) {
            if (std.mem.eql(u8, e.name, "files")) counter_files = e.args.files;
            if (std.mem.eql(u8, e.name, "bytes")) counter_bytes = e.args.bytes;
            if (std.mem.eql(u8, e.name, "diagnostics")) counter_diagnostics = e.args.diagnostics;
        }
    }
    try testing.expect(read_main and read_util and saw_enumerate and saw_merge and saw_render);
    try testing.expectEqual(@as(?u64, 2), counter_files);
    try testing.expectEqual(@as(?u64, 22), counter_bytes);
    try testing.expectEqual(@as(?u64, 0), counter_diagnostics);
}

test "output is byte-identical across --jobs=1 and --jobs=4, twice each" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // Twenty files; a third have invalid module paths so stderr carries
    // several diagnostics whose ORDER is what parallelism could disturb.
    var name_buf: [64]u8 = undefined;
    var body_buf: [64]u8 = undefined;
    for (0..20) |i| {
        const name = if (i % 3 == 0)
            try std.fmt.bufPrint(&name_buf, "src/Sub{d}/bad-{d}.beni", .{ i % 4, i })
        else
            try std.fmt.bufPrint(&name_buf, "src/Sub{d}/Module{d}.beni", .{ i % 4, i });
        try w.write(name, try std.fmt.bufPrint(&body_buf, "value{d} = {d}\n", .{ i, i }));
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const runs = [_]world.Result{
        try w.run(&.{ "check", "--jobs=1", "src" }),
        try w.run(&.{ "check", "--jobs=4", "src" }),
        try w.run(&.{ "check", "--jobs=1", "src" }),
        try w.run(&.{ "check", "--jobs=4", "src" }),
    };

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), runs[0].exit_code);
    try testing.expectEqual(@as(usize, 7), runs[0].diagnostics.len);
    for (runs[1..]) |r| {
        try testing.expectEqual(runs[0].exit_code, r.exit_code);
        try testing.expectEqualStrings(runs[0].stdout, r.stdout);
        try testing.expectEqualStrings(runs[0].stderr, r.stderr);
    }
    // And the order is the documented one: by file path.
    var previous: []const u8 = "";
    for (runs[0].diagnostics) |d| {
        try testing.expect(std.mem.order(u8, previous, d.span.file) == .lt);
        previous = d.span.file;
    }
}

test "unknown subcommand exits 2 with the exact message" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{"frobnicate"});

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualStrings("beni: unknown subcommand 'frobnicate'; run 'beni help' for usage\n", r.stderr);
}

test "unknown flag exits 2 with the exact message and does nothing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", "main = 1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "check", "--frob", "--self-profile=trace.json", "src" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualStrings("beni: unknown option '--frob'; run 'beni help' for usage\n", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("trace.json"));
}

test "check on a missing path exits 2" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "check", "nope" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualStrings("beni: cannot read 'nope': FileNotFound\n", r.stderr);
}

test "check on a file without the .beni extension exits 2" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("notes.txt", "x");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "check", "notes.txt" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings("beni: cannot read 'notes.txt': NotABeniFile\n", r.stderr);
}

test "fmt and the bir dump parse their arguments but are not implemented yet" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "main = 1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const fmt = try w.runWith(&.{ "fmt", "--check", "Main.beni" }, .{ .raw_diagnostics = true });
    const dump = try w.runWith(&.{ "dump", "--stage=bir", "Main.beni" }, .{ .raw_diagnostics = true });
    const dump_bad = try w.runWith(&.{ "dump", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), fmt.exit_code);
    try testing.expectEqualStrings("beni: fmt is not implemented yet\n", fmt.stderr);
    try testing.expectEqual(@as(u8, 2), dump.exit_code);
    try testing.expectEqualStrings("beni: dump --stage=bir is not implemented yet\n", dump.stderr);
    // Argument validation runs first: a usage error, not "not implemented".
    try testing.expectEqual(@as(u8, 2), dump_bad.exit_code);
    try testing.expectEqualStrings("beni: dump needs --stage=tokens|ast|bir\n", dump_bad.stderr);
    try testing.expectEqualStrings("", fmt.stdout);
    try testing.expectEqualStrings("", dump.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings("main = 1\n", try w.read("Main.beni"));
}

test "dump --stage=tokens prints every token with its position, then the comments" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\--! Doc
        \\main =
        \\    "a${ x.0 }" -- hi
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "dump", "--stage=tokens", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings(
        \\2:1 lower_ident main
        \\2:6 equal =
        \\3:5 str_start "
        \\3:6 str_chunk a
        \\3:7 interp_start ${
        \\3:10 lower_ident x
        \\3:11 dot_index .0
        \\3:14 interp_end }
        \\3:15 str_end "
        \\4:1 eof
        \\-- comments
        \\1:1 module_doc --! Doc
        \\3:17 plain -- hi
        \\
    , r.stdout);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), r.diagnostics);
}

test "check on a file with a tab yields exactly one tab_in_source diagnostic" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", "x =\n\t1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .tab_in_source,
        .severity = .@"error",
        .span = .{ .file = "src/Main.beni", .start = .{ .line = 2, .col = 1 }, .end = .{ .line = 2, .col = 2 } },
        .title = "TAB CHARACTER",
        .message = "I found a tab character. Beni does not allow tabs anywhere in a file.\n" ++
            "\n" ++
            "Use spaces for indentation. Inside a string, write \\t.",
    }}), r.diagnostics);
}

test "three lexical errors in one file yield exactly three diagnostics in position order" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "x = 12abc\ny = 'ab'\nz = @\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{
        .{
            .code = .invalid_number,
            .severity = .@"error",
            .span = .{ .file = "Main.beni", .start = .{ .line = 1, .col = 5 }, .end = .{ .line = 1, .col = 10 } },
            .title = "INVALID NUMBER",
            .message = "I ran into `12abc` while reading a number.\n" ++
                "\n" ++
                "A number is decimal digits (`42`), a hex literal (`0x1F`), or a float with a\n" ++
                "fraction and/or an exponent (`1.5`, `1e10`, `1.5e-3`). Letters and underscores\n" ++
                "cannot follow a number directly; put a space between the number and the name.",
        },
        .{
            .code = .invalid_char_literal,
            .severity = .@"error",
            .span = .{ .file = "Main.beni", .start = .{ .line = 2, .col = 5 }, .end = .{ .line = 2, .col = 9 } },
            .title = "INVALID CHAR LITERAL",
            .message = "I found the character literal `'ab'`, which holds more than one character.\n" ++
                "\n" ++
                "A character literal holds exactly one character: `'a'`, `'\\n'`, `'\\u{1F600}'`.\n" ++
                "For text, use a string: `\"…\"`.",
        },
        .{
            .code = .invalid_character,
            .severity = .@"error",
            .span = .{ .file = "Main.beni", .start = .{ .line = 3, .col = 5 }, .end = .{ .line = 3, .col = 6 } },
            .title = "INVALID CHARACTER",
            .message = "I found `@`, which is not part of the language's syntax.\n" ++
                "\n" ++
                "The symbols are ( ) [ ] { } , : = -> \\ | _ ? and the operators are\n" ++
                "+ - * / // ^ ++ :: == /= < > <= >= && || |> <| << >>.",
        },
    }), r.diagnostics);
}

test "a lexical error does not stop the file: later lines still lex, and dump exits 0 with the diagnostic on stderr" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "x = \"open\ny = 1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "dump", "--stage=tokens", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings(
        \\1:1 lower_ident x
        \\1:3 equal =
        \\1:5 str_start "
        \\1:6 str_chunk open
        \\1:10 invalid
        \\2:1 lower_ident y
        \\2:3 equal =
        \\2:5 int 1
        \\3:1 eof
        \\-- comments
        \\
    , r.stdout);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .unterminated_string,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 1, .col = 5 }, .end = .{ .line = 1, .col = 10 } },
        .title = "UNTERMINATED STRING",
        .message = "I got to the end of the line without seeing the closing `\"` of this string.\n" ++
            "\n" ++
            "Strings are single-line. For text that spans several lines, use a multiline\n" ++
            "string, one `\\\\` per line:\n" ++
            "\n" ++
            "    \\\\first line\n" ++
            "    \\\\second line",
    }}), r.diagnostics);
}

test "dump --stage=ast prints the tree as an S-expression with docs, imports and every part" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\--! A tiny module.
        \\import Json.Decode as D exposing (Decoder)
        \\
        \\
        \\--| Greets.
        \\pub greet : String -> String
        \\greet name =
        \\    "hi ${name}" -- trailing
        \\
        \\
        \\sign n =
        \\    case n of
        \\        0 ->
        \\            -1
        \\
        \\        _ ->
        \\            n |> abs
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "dump", "--stage=ast", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings(
        \\(module
        \\  (module_doc "A tiny module.")
        \\  (import Json.Decode as D exposing
        \\    (exposed Decoder))
        \\  (annotation pub greet
        \\    (doc "Greets.")
        \\    (type_fn
        \\      (type_con String)
        \\      (type_con String)))
        \\  (definition greet
        \\    (pat_var name)
        \\    (string
        \\      (chunk "hi ")
        \\      (interp
        \\        (ident name))))
        \\  (definition sign
        \\    (pat_var n)
        \\    (case
        \\      (ident n)
        \\      (branch
        \\        (pat_int 0)
        \\        (negate
        \\          (int 1)))
        \\      (branch
        \\        (pat_wild)
        \\        (pipe_right
        \\          (ident n)
        \\          (ident abs))))))
        \\
    , r.stdout);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), r.diagnostics);
}

test "check with one syntax error reports the whole Elm-style diagnostic" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "f x =\n    if x 1 else 2\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .expected_token,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 2, .col = 12 }, .end = .{ .line = 2, .col = 16 } },
        .title = "EXPECTED TOKEN",
        .message = "I was parsing this `if` and ran into `else`, but I was expecting `then` here.",
    }}), r.diagnostics);
}

test "check with two syntax errors in different declarations reports both, in order" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\x =
        \\    ( 1 + 2
        \\
        \\
        \\g =
        \\    3
        \\
        \\
        \\h =
        \\    [ 1, , 2 ]
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{
        .{
            .code = .unclosed_delimiter,
            .severity = .@"error",
            .span = .{ .file = "Main.beni", .start = .{ .line = 2, .col = 5 }, .end = .{ .line = 2, .col = 6 } },
            .title = "UNCLOSED DELIMITER",
            .message = "I was parsing a parenthesised expression and ran into `g` on column 1 before finding the `)` that\n" ++
                "closes this `(`.\n" ++
                "\n" ++
                "Everything inside the brackets must be indented more than column 1, the column\n" ++
                "of the block they are in. `g` is not, so the block ended there and the `)` is\n" ++
                "missing.",
        },
        .{
            .code = .unexpected_token,
            .severity = .@"error",
            .span = .{ .file = "Main.beni", .start = .{ .line = 10, .col = 10 }, .end = .{ .line = 10, .col = 11 } },
            .title = "UNEXPECTED TOKEN",
            .message = "I was parsing a list and ran into `,`. I was expecting an expression.",
        },
    }), r.diagnostics);
}

test "a layout error quotes both columns, and the text renderer shows the excerpt" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\x =
        \\    let
        \\        a = 1
        \\      b = 2
        \\    in
        \\    a + b
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const json = try w.run(&.{ "check", "Main.beni" });
    const text = try w.runWith(&.{ "check", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), json.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .unexpected_token,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 4, .col = 7 }, .end = .{ .line = 4, .col = 8 } },
        .title = "UNEXPECTED TOKEN",
        .message = "I was parsing the bindings of this `let` and ran into `b` on column 7.\n" ++
            "\n" ++
            "Every binding must start on the same column as the first one, `a` on column 9,\n" ++
            "and `in` ends the list.",
    }}), json.diagnostics);
    try testing.expectEqual(@as(u8, 1), text.exit_code);
    try testing.expectEqualStrings(
        "-- UNEXPECTED TOKEN ---------------------------------------------- Main.beni:4:7\n" ++
            "\n" ++
            "I was parsing the bindings of this `let` and ran into `b` on column 7.\n" ++
            "\n" ++
            "Every binding must start on the same column as the first one, `a` on column 9,\n" ++
            "and `in` ends the list.\n" ++
            "\n" ++
            "4|      b = 2\n" ++
            "        ^\n",
        text.stderr,
    );
}

test "dump --stage=ast on a broken file exits 0 with placeholders in the tree and the errors on stderr" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "x = [ 1, , 2 ]\ny = 2\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "dump", "--stage=ast", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings(
        \\(module
        \\  (definition x
        \\    (list
        \\      (int 1)
        \\      (error unexpected_token)
        \\      (int 2)))
        \\  (definition y
        \\    (int 2)))
        \\
    , r.stdout);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.unexpected_token, r.diagnostics[0].code);
}
