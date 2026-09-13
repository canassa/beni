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

const expected_version = "beni 0.1.0-m1\n";

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
    // `check` resolves against the core package, so core's modules would
    // be files of this run too and every count below would include them.
    // `--core-root` points it at an empty directory instead: these two
    // modules name nothing from core, so they check clean without it and
    // the numbers are exactly the project's. (The directory has to exist,
    // hence the placeholder; the walk only ever picks up `.beni` files.)
    try w.write("nocore/PLACEHOLDER", "");
    const r = try w.run(&.{ "check", "--self-profile=trace.json", "--core-root=nocore", "--jobs=2", "src" });

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

test "--self-profile records every phase of every file and every counter, exactly" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The counters are what the M4 incrementality tests will assert
    // ("dependents were not re-checked"), so they have to be right before
    // there is anything to be incremental about. Three files, small enough
    // that every number can be stated and checked from the outside.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const files = [_]struct { path: []const u8, source: []const u8 }{
        .{ .path = "src/A.beni", .source = "main =\n    1\n" },
        // No operator and no prelude name anywhere in these three: `x * 2`
        // would be a reference to `Basics.mul`, and the point of this
        // scenario is to state the project's numbers with no core package
        // mixed into them (see `--core-root=nocore` below).
        .{ .path = "src/B.beni", .source = "double x =\n    x\n" },
        .{ .path = "src/C.beni", .source = "pub type Color\n    = Red\n    | Green\n" },
    };
    var total_bytes: u64 = 0;
    for (files) |f| {
        try w.write(f.path, f.source);
        total_bytes += f.source.len;
    }

    // The token count is not guessed: it is the number of token lines
    // `dump --stage=tokens` prints, which is the same array the counter
    // sums. Comments come after a `-- comments` heading and are not
    // tokens.
    var total_tokens: u64 = 0;
    for (files) |f| {
        const dump = try w.runWith(&.{ "dump", "--stage=tokens", f.path }, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), dump.exit_code);
        const heading = std.mem.indexOf(u8, dump.stdout, "-- comments\n") orelse return error.NoCommentsHeading;
        total_tokens += std.mem.count(u8, dump.stdout[0..heading], "\n");
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    try w.write("nocore/PLACEHOLDER", "");
    const r = try w.run(&.{ "check", "--self-profile=trace.json", "--core-root=nocore", "--jobs=2", "src" });

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
        cat: ?[]const u8 = null,
        ph: []const u8,
        tid: u32,
        args: struct {
            file: ?[]const u8 = null,
            bytes: ?u64 = null,
            files: ?u64 = null,
            tokens: ?u64 = null,
            nodes: ?u64 = null,
            insts: ?u64 = null,
            diagnostics: ?u64 = null,
            formatted_bytes: ?u64 = null,
            modules: ?u64 = null,
            edges: ?u64 = null,
            interfaces: ?u64 = null,
            dropped_events: ?u64 = null,
        },
    };
    const text = try w.read("trace.json");
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Four phase events per file, each naming its own file and carrying
    // that file's size; three serial steps with no file at all.
    var seen: [files.len][4]bool = @splat(@splat(false));
    var serial: [5]bool = @splat(false);
    const per_file = [_][]const u8{ "read", "lex", "parse", "lower" };
    const serial_names = [_][]const u8{ "enumerate", "merge_interners", "graph", "resolve", "render" };
    var counters: [9]?u64 = @splat(null);
    for (parsed.value.traceEvents) |e| {
        if (std.mem.eql(u8, e.ph, "X")) {
            try testing.expectEqualStrings("phase", e.cat.?);
            try testing.expect(e.tid < 2);
            if (e.args.file) |file| {
                const f = indexOfPath(&files, file) orelse {
                    std.debug.print("phase event for an unexpected file: {s}\n", .{file});
                    return error.UnexpectedPhaseEvent;
                };
                const phase = indexOfName(&per_file, e.name) orelse {
                    std.debug.print("unexpected per-file phase: {s}\n", .{e.name});
                    return error.UnexpectedPhaseEvent;
                };
                try testing.expect(!seen[f][phase]); // exactly one each
                seen[f][phase] = true;
                try testing.expectEqual(@as(?u64, files[f].source.len), e.args.bytes);
            } else {
                serial[indexOfName(&serial_names, e.name) orelse return error.UnexpectedPhaseEvent] = true;
            }
        } else if (std.mem.eql(u8, e.ph, "C")) {
            if (std.mem.eql(u8, e.name, "files")) counters[0] = e.args.files;
            if (std.mem.eql(u8, e.name, "bytes")) counters[1] = e.args.bytes;
            if (std.mem.eql(u8, e.name, "tokens")) counters[2] = e.args.tokens;
            if (std.mem.eql(u8, e.name, "nodes")) counters[3] = e.args.nodes;
            if (std.mem.eql(u8, e.name, "insts")) counters[4] = e.args.insts;
            if (std.mem.eql(u8, e.name, "diagnostics")) counters[5] = e.args.diagnostics;
            if (std.mem.eql(u8, e.name, "modules")) counters[6] = e.args.modules;
            if (std.mem.eql(u8, e.name, "edges")) counters[7] = e.args.edges;
            if (std.mem.eql(u8, e.name, "interfaces")) counters[8] = e.args.interfaces;
        }
    }
    try testing.expectEqual([files.len][4]bool{ @splat(true), @splat(true), @splat(true) }, seen);
    try testing.expectEqual([5]bool{ true, true, true, true, true }, serial);

    // `files`, `bytes` and `tokens` are computed above; `nodes` and
    // `insts` are the AST and BIR sizes of these three modules, which
    // nothing outside the compiler can derive — they are literals, and a
    // change to either IR's shape is meant to show up here as a number to
    // look at rather than as silence.
    // `modules`, `edges` and `interfaces` are the M2a additions: three
    // modules that import nothing, so no edge, and one interface each.
    try testing.expectEqual([9]?u64{ 3, total_bytes, total_tokens, 11, 3, 0, 3, 0, 3 }, counters);
    try testing.expectEqual(@as(u64, 67), total_bytes);
    try testing.expectEqual(@as(u64, 17), total_tokens);
}

/// The index of `path` in `files`, or null.
fn indexOfPath(files: anytype, path: []const u8) ?usize {
    for (files, 0..) |f, i| if (std.mem.eql(u8, f.path, path)) return i;
    return null;
}

fn indexOfName(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

test "every stream of every command is byte-identical across --jobs=1 and --jobs=8, twice each" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Determinism is a requirement, not an aspiration (fast-compiler.md
    // §10): two runs must agree byte for byte on every stream whatever the
    // worker count. Forty modules across four subdirectories, three
    // quarters of them carrying a diagnostic, and the diagnostics come from
    // three different phases and from the serial module-path check — so
    // what is compared is not just "a list came out sorted" but the merge
    // of four kinds of finding produced on whichever worker happened to
    // take the file.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var name_buf: [64]u8 = undefined;
    var body_buf: [128]u8 = undefined;
    var paths: [40][]const u8 = undefined;
    for (&paths, 0..) |*path, i| {
        // Every fifth module has a path no module name can come from; the
        // rest are ordinary `Sub<n>/Module<i>`.
        const rel = if (i % 5 == 4)
            try std.fmt.bufPrint(&name_buf, "src/Sub{d}/bad-{d}.beni", .{ i % 4, i })
        else
            try std.fmt.bufPrint(&name_buf, "src/Sub{d}/Module{d}.beni", .{ i % 4, i });
        const body = switch (i % 4) {
            0 => try std.fmt.bufPrint(&body_buf, "value{d} =\n    {d}\n", .{ i, i }), // clean
            1 => try std.fmt.bufPrint(&body_buf, "value{d} =\n    missing{d}\n", .{ i, i }), // lowering
            2 => try std.fmt.bufPrint(&body_buf, "value{d} =\n\t{d}\n", .{ i, i }), // lexical
            else => try std.fmt.bufPrint(&body_buf, "value{d} =\n    [ {d}\n", .{ i, i }), // syntax
        };
        try w.write(rel, body);
        path.* = try w.arena.allocator().dupe(u8, rel);
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // One transcript per pass: every command's exit code, stdout and
    // stderr, concatenated with a header naming the command, so a
    // mismatch points at the command that drifted instead of at a byte
    // offset in a wall of output.
    var transcripts: [4][]const u8 = undefined;
    const jobs = [4][]const u8{ "--jobs=1", "--jobs=8", "--jobs=1", "--jobs=8" };
    for (&transcripts, jobs) |*transcript, j| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        // Whole-project commands.
        try record(&w, &out, &.{ "check", "--diagnostics=json", j, "src" });
        try record(&w, &out, &.{ "check", j, "src" });
        try record(&w, &out, &.{ "fmt", "--check", j, "src" });
        // Per-file commands, in the order the enumerator would number
        // them, so the transcript itself has a fixed shape.
        for (paths) |path| {
            try record(&w, &out, &.{ "fmt", "--stdout", j, path });
            try record(&w, &out, &.{ "dump", "--stage=ast", j, path });
            try record(&w, &out, &.{ "dump", "--stage=bir", j, path });
        }
        transcript.* = try w.arena.allocator().dupe(u8, out.items);
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for (transcripts[1..]) |other| try testing.expectEqualStrings(transcripts[0], other);
    // And the transcript is not trivially empty: 3 project commands plus
    // 3 per file, each contributing one header line.
    try testing.expectEqual(@as(usize, 3 + 3 * 40), std.mem.count(u8, transcripts[0], "\n$ beni "));

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Nothing above writes: `fmt --check` and `fmt --stdout` never touch
    // a file, which is also why the four passes see the same project.
    for (paths, 0..) |path, i| {
        const body = switch (i % 4) {
            0 => try std.fmt.bufPrint(&body_buf, "value{d} =\n    {d}\n", .{ i, i }),
            1 => try std.fmt.bufPrint(&body_buf, "value{d} =\n    missing{d}\n", .{ i, i }),
            2 => try std.fmt.bufPrint(&body_buf, "value{d} =\n\t{d}\n", .{ i, i }),
            else => try std.fmt.bufPrint(&body_buf, "value{d} =\n    [ {d}\n", .{ i, i }),
        };
        try testing.expectEqualStrings(body, try w.read(path));
    }
}

/// Append one command's whole observable result to `out`: the argv, the
/// exit code, stdout and stderr. Raw — the point is to compare the bytes
/// the compiler produced, not a parse of them. `--jobs` is left out of the
/// header because it is the variable under test: everything else in the
/// transcript must be the same whatever it was.
fn record(w: *World, out: *std.ArrayList(u8), args: []const []const u8) !void {
    const r = try w.runWith(args, .{ .raw_diagnostics = true });
    try out.appendSlice(testing.allocator, "\n$ beni ");
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "--jobs=")) continue;
        try out.appendSlice(testing.allocator, a);
        try out.append(testing.allocator, ' ');
    }
    var line: [64]u8 = undefined;
    try out.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "\n= {d}\n--- stdout\n", .{r.exit_code}));
    try out.appendSlice(testing.allocator, r.stdout);
    try out.appendSlice(testing.allocator, "--- stderr\n");
    try out.appendSlice(testing.allocator, r.stderr);
}

test "an unreadable file is named identically across --jobs=1 and --jobs=8, twice each" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The determinism requirement covers the failure path too, and that is
    // where it used to break: each worker recorded only the FIRST file it
    // could not read and then abandoned its queue, and `run` reported the
    // first failing worker in worker-index order — so with two unreadable
    // files, which one got named followed the race for the shared file
    // counter. Two unreadable files, far apart in sorted order, are what
    // makes the difference visible.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var name_buf: [64]u8 = undefined;
    var body_buf: [64]u8 = undefined;
    for (0..41) |i| {
        const rel = try std.fmt.bufPrint(&name_buf, "src/M{d:0>3}.beni", .{i});
        try w.write(rel, try std.fmt.bufPrint(&body_buf, "value{d} =\n    {d}\n", .{ i, i }));
    }
    if (!try w.makeUnreadable("src/M003.beni") or !try w.makeUnreadable("src/M037.beni")) {
        std.debug.print("skipping: chmod 000 did not make the file unreadable (running as root?)\n", .{});
        return;
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const runs = [_]world.Result{
        try w.runWith(&.{ "check", "--jobs=1", "src" }, .{ .raw_diagnostics = true }),
        try w.runWith(&.{ "check", "--jobs=8", "src" }, .{ .raw_diagnostics = true }),
        try w.runWith(&.{ "check", "--jobs=1", "src" }, .{ .raw_diagnostics = true }),
        try w.runWith(&.{ "check", "--jobs=8", "src" }, .{ .raw_diagnostics = true }),
    };

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The LOWEST-numbered unreadable file — sorted path order — is the one
    // named, at every worker count.
    try testing.expectEqualStrings("beni: cannot read 'src/M003.beni': AccessDenied\n", runs[0].stderr);
    for (runs) |r| {
        try testing.expectEqual(@as(u8, 2), r.exit_code);
        try testing.expectEqualStrings(runs[0].stderr, r.stderr);
        try testing.expectEqualStrings("", r.stdout);
    }
}

test "diagnostics are sorted by file path whatever the worker count" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
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
    const r = try w.run(&.{ "check", "--jobs=4", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 7), r.diagnostics.len);
    var previous: []const u8 = "";
    for (r.diagnostics) |d| {
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

test "dump without a stage is a usage error and does nothing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "main = 1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dump_bad = try w.runWith(&.{ "dump", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), dump_bad.exit_code);
    try testing.expectEqualStrings("beni: dump needs --stage=tokens|ast|bir|interface\n", dump_bad.stderr);
    try testing.expectEqualStrings("", dump_bad.stdout);

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

// ---------------------------------------------------------------------------
// M1c: the formatter (language.md §9, frontend.md §1)
// ---------------------------------------------------------------------------

const ugly_module =
    "import Set\n" ++
    "import Dict\n" ++
    "x   =   [1,2]\n" ++
    "y = if x then 1 else 2\n";

const canonical_module =
    "import Dict\n" ++
    "import Set\n" ++
    "\n" ++
    "\n" ++
    "x =\n" ++
    "    [ 1, 2 ]\n" ++
    "\n" ++
    "\n" ++
    "y =\n" ++
    "    if x then\n" ++
    "        1\n" ++
    "    else\n" ++
    "        2\n";

test "fmt --stdout prints the canonical form of an ugly module and writes nothing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", ugly_module);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "fmt", "--stdout", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings(canonical_module, r.stdout);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), r.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(ugly_module, try w.read("Main.beni"));
}

test "fmt --check on a canonical file exits 0 with nothing on either stream" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", canonical_module);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "fmt", "--check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(canonical_module, try w.read("src/Main.beni"));
}

test "fmt --check on a non-canonical file exits 1, lists exactly that file, and writes nothing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", ugly_module);
    try w.write("src/Page/Fine.beni", canonical_module);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "fmt", "--check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualStrings("src/Main.beni\n", r.stdout);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(ugly_module, try w.read("src/Main.beni"));
    try testing.expectEqualStrings(canonical_module, try w.read("src/Page/Fine.beni"));
}

test "fmt in place rewrites the file to its canonical form, and a second run changes nothing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", ugly_module);
    try w.write("src/Page/Fine.beni", canonical_module);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const first = try w.run(&.{ "fmt", "src" });
    const after_first = try w.read("src/Main.beni");
    const second = try w.run(&.{ "fmt", "src" });
    const after_second = try w.read("src/Main.beni");
    const check = try w.run(&.{ "fmt", "--check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), first.exit_code);
    try testing.expectEqualStrings("", first.stdout);
    try testing.expectEqualStrings("", first.stderr);
    try testing.expectEqual(@as(u8, 0), second.exit_code);
    try testing.expectEqualStrings("", second.stdout);
    try testing.expectEqualStrings("", second.stderr);
    try testing.expectEqual(@as(u8, 0), check.exit_code);
    try testing.expectEqualStrings("", check.stdout);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(canonical_module, after_first);
    try testing.expectEqualStrings(canonical_module, after_second);
    try testing.expectEqualStrings(canonical_module, try w.read("src/Page/Fine.beni"));
    // The atomic write leaves no temporary file behind: only Main.beni and Page/.
    var count: usize = 0;
    var dir = try w.tmp.dir.openDir(w.io, "src", .{ .iterate = true });
    defer dir.close(w.io);
    var it = dir.iterate();
    while (try it.next(w.io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count);
}

test "fmt on a file with a syntax error reports the whole diagnostic, prints nothing, and leaves every byte alone" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const broken = "x = [ 1, , 2 ]\ny =   2\n";
    try w.write("src/Broken.beni", broken);
    try w.write("src/Main.beni", ugly_module);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const in_place = try w.run(&.{ "fmt", "src" });
    const after_in_place = try w.read("src/Broken.beni");
    const to_stdout = try w.run(&.{ "fmt", "--stdout", "src/Broken.beni" });
    const check = try w.run(&.{ "fmt", "--check", "src/Broken.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    const expected_diagnostic: diagnostic.Diagnostic = .{
        .code = .unexpected_token,
        .severity = .@"error",
        .span = .{ .file = "src/Broken.beni", .start = .{ .line = 1, .col = 10 }, .end = .{ .line = 1, .col = 11 } },
        .title = "UNEXPECTED TOKEN",
        .message = "I was parsing a list and ran into `,`. I was expecting an expression.",
    };
    try testing.expectEqual(@as(u8, 1), in_place.exit_code);
    try testing.expectEqualStrings("", in_place.stdout);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{expected_diagnostic}), in_place.diagnostics);
    try testing.expectEqual(@as(u8, 1), to_stdout.exit_code);
    try testing.expectEqualStrings("", to_stdout.stdout);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{expected_diagnostic}), to_stdout.diagnostics);
    try testing.expectEqual(@as(u8, 1), check.exit_code);
    try testing.expectEqualStrings("", check.stdout);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{expected_diagnostic}), check.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(broken, after_in_place);
    try testing.expectEqualStrings(broken, try w.read("src/Broken.beni"));
    // The healthy sibling was still formatted by the in-place run.
    try testing.expectEqualStrings(canonical_module, try w.read("src/Main.beni"));
}

test "fmt --stdout needs exactly one file" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/A.beni", canonical_module);
    try w.write("src/B.beni", canonical_module);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "fmt", "--stdout", "src" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqualStrings("beni: fmt --stdout needs exactly one file\n", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(canonical_module, try w.read("src/A.beni"));
    try testing.expectEqualStrings(canonical_module, try w.read("src/B.beni"));
}

// ---------------------------------------------------------------------------
// M1c: lowering (docs/design/language.md §5–§8, frontend.md §1.2, §8).
// ---------------------------------------------------------------------------

test "dump --stage=bir shows a pipeline as saturated calls and an operator as a core call" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\total xs =
        \\    xs |> List.map (\x -> x * 2) |> List.sum
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "dump", "--stage=bir", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings(
        \\decl 0: value total
        \\  %0 = pat_var local 0 (xs)
        \\  %1 = local 0 (xs)
        \\  %2 = qualified List.map
        \\  %3 = pat_var local 1 (x)
        \\  %4 = local 1 (x)
        \\  %5 = int 2
        \\  %6 = import_value Basics.mul
        \\  %7 = call %6 [%4, %5]
        \\  %8 = lambda [%3] -> %7
        \\  %9 = call %2 [%8, %1]
        \\  %10 = qualified List.sum
        \\  %11 = call %10 [%9]
        \\  params [%0]
        \\  body %11
        \\  locals
        \\    0 xs param %0
        \\    1 x param %3
        \\  refs
        \\    import_value List.map
        \\    import_value Basics.mul
        \\    import_value List.sum
        \\
        \\interface
        \\
        \\imports
        \\  prelude Basics
        \\  prelude List
        \\  prelude Maybe
        \\  prelude Result
        \\  prelude String
        \\  prelude Char
        \\  prelude Debug
        \\
    , r.stdout);
    try testing.expectEqualStrings("", r.stderr);
}

test "check reports an unbound variable with the whole diagnostic" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "x =\n    nowhere\n");

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
        .code = .unbound_variable,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 2, .col = 5 }, .end = .{ .line = 2, .col = 12 } },
        .title = "NAMING ERROR",
        .message = "I cannot find a `nowhere` variable.\n" ++
            "\n" ++
            "It is not a local binding, a top-level value of this module, a name from an\n" ++
            "`exposing` list, or a prelude value. Check the spelling, or add it to an import.",
    }}), r.diagnostics);
}

test "check reports a let binding that shadows a parameter" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\f x =
        \\    let
        \\        x =
        \\            1
        \\    in
        \\    x
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
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .shadowing,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 3, .col = 9 }, .end = .{ .line = 3, .col = 10 } },
        .title = "SHADOWING",
        .message = "The name `x` is already bound on line 1.\n" ++
            "\n" ++
            "Shadowing is not allowed: a binding cannot reuse a name that is in scope, whether\n" ++
            "from an enclosing binding, a top-level declaration, an `exposing` list or the\n" ++
            "prelude. Rename one of them.",
    }}), r.diagnostics);
}

test "check --core accepts a foreign declaration that check without it rejects" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // NOT named `Basics`: a module of the app package named like a core
    // module shadows it for the whole project (checker.md §2), and a file
    // called `Basics.beni` would therefore shadow the prelude's own home
    // and make `Int` unresolvable. That rule has its own scenario below.
    try w.write("Prim.beni", "pub foreign add : Int -> Int -> Int\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const core = try w.run(&.{ "check", "--core", "Prim.beni" });
    const user = try w.run(&.{ "check", "Prim.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), core.exit_code);
    try testing.expectEqualStrings("", core.stderr);
    try testing.expectEqual(@as(usize, 0), core.diagnostics.len);
    try testing.expectEqual(@as(u8, 1), user.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .foreign_outside_core,
        .severity = .@"error",
        .span = .{ .file = "Prim.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 16 } },
        .title = "FOREIGN OUTSIDE CORE",
        .message = "This `foreign` declaration is outside the core package.\n" ++
            "\n" ++
            "`foreign` declares a value or type implemented in JavaScript and is legal only in\n" ++
            "core, which is built with `--core`. Write the definition in beni instead.",
    }}), user.diagnostics);
}

test "check reports a syntax error and a lowering error from one file in position order" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "x =\n    [ 1, , 2 ]\n\n\ny =\n    nowhere\n");

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
            .code = .unexpected_token,
            .severity = .@"error",
            .span = .{ .file = "Main.beni", .start = .{ .line = 2, .col = 10 }, .end = .{ .line = 2, .col = 11 } },
            .title = "UNEXPECTED TOKEN",
            .message = "I was parsing a list and ran into `,`. I was expecting an expression.",
        },
        .{
            .code = .unbound_variable,
            .severity = .@"error",
            .span = .{ .file = "Main.beni", .start = .{ .line = 6, .col = 5 }, .end = .{ .line = 6, .col = 12 } },
            .title = "NAMING ERROR",
            .message = "I cannot find a `nowhere` variable.\n" ++
                "\n" ++
                "It is not a local binding, a top-level value of this module, a name from an\n" ++
                "`exposing` list, or a prelude value. Check the spelling, or add it to an import.",
        },
    }), r.diagnostics);
}

// ---------------------------------------------------------------------------
// M2a: the module graph, the core package, and cross-module resolution
// (docs/design/checker.md §4).
// ---------------------------------------------------------------------------

test "a two-module project resolves cleanly and writes nothing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Util.beni",
        \\pub double : Int -> Int
        \\double n =
        \\    n * 2
        \\
    );
    try w.write("src/Main.beni",
        \\import Util exposing (double)
        \\
        \\
        \\pub main : Int
        \\main =
        \\    double (Util.double 21)
        \\
    );

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
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // `check` produces no artifact: the sources are exactly as written.
    try testing.expectEqualStrings("pub double : Int -> Int\ndouble n =\n    n * 2\n", try w.read("src/Util.beni"));
}

test "unknown_module names the import that cannot be found" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", "import Json.Decode\n\n\npub x : Int\nx =\n    1\n");

    const r = try w.run(&.{ "check", "src" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .unknown_module,
        .severity = .@"error",
        .span = .{ .file = "src/Main.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 19 } },
        .title = "UNKNOWN MODULE",
        .message = "I cannot find a module named `Json.Decode`.\n" ++
            "\n" ++
            "I looked in this project and in the core package. Check the spelling, or check\n" ++
            "that a file named `Json.Decode.beni` exists under the source root.",
    }}), r.diagnostics);
}

test "import_cycle is one diagnostic on the first module, naming the whole cycle" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/A.beni", "import B exposing (b)\n\n\npub a : Int\na =\n    b\n");
    try w.write("src/B.beni", "import C exposing (c)\n\n\npub b : Int\nb =\n    c\n");
    try w.write("src/C.beni", "import A exposing (a)\n\n\npub c : Int\nc =\n    a\n");

    const r = try w.run(&.{ "check", "src" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .import_cycle,
        .severity = .@"error",
        .span = .{ .file = "src/A.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 9 } },
        .title = "IMPORT CYCLE",
        .message = "These modules import each other in a circle:\n" ++
            "\n" ++
            "    A → B → C → A\n" ++
            "\n" ++
            "Beni compiles modules in dependency order, so a circle has no place to start.\n" ++
            "Move what they share into a module of its own and have both import that.",
    }}), r.diagnostics);
}

test "unknown_import_name and private_name are different messages for different causes" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Util.beni", "secret : Int\nsecret =\n    1\n");
    try w.write("src/Main.beni", "import Util\n\n\npub a : Int\na =\n    Util.secret\n\n\npub b : Int\nb =\n    Util.absent\n");

    const r = try w.run(&.{ "check", "src" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{
        .{
            .code = .private_name,
            .severity = .@"error",
            .span = .{ .file = "src/Main.beni", .start = .{ .line = 6, .col = 5 }, .end = .{ .line = 6, .col = 16 } },
            .title = "PRIVATE NAME",
            .message = "`secret` is not public in `Util`.\n" ++
                "\n" ++
                "It is declared there, but without `pub`, so only that module can use it. Add\n" ++
                "`pub` to its declaration if it is meant to be part of the interface.",
        },
        .{
            .code = .unknown_import_name,
            .severity = .@"error",
            .span = .{ .file = "src/Main.beni", .start = .{ .line = 11, .col = 5 }, .end = .{ .line = 11, .col = 16 } },
            .title = "UNKNOWN IMPORT NAME",
            .message = "`Util` does not expose `absent`.\n" ++
                "\n" ++
                "Check the spelling, or check that the declaration in `Util` is marked `pub`.",
        },
    }), r.diagnostics);
}

test "opaque_constructor: the type resolves and its constructor does not" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Tree.beni", "pub opaque type Tree\n    = Leaf\n");
    try w.write("src/Main.beni", "import Tree exposing (Tree)\n\n\npub mine : Tree\nmine =\n    Tree.Leaf\n");

    const r = try w.run(&.{ "check", "src" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .opaque_constructor,
        .severity = .@"error",
        .span = .{ .file = "src/Main.beni", .start = .{ .line = 6, .col = 5 }, .end = .{ .line = 6, .col = 14 } },
        .title = "OPAQUE CONSTRUCTOR",
        .message = "`Leaf` is a constructor of `Tree.Tree`, which is opaque.\n" ++
            "\n" ++
            "`pub opaque type` exposes the type's NAME and hides how it is built, so only\n" ++
            "`Tree` may write its constructors. Use the functions it exposes instead.",
    }}), r.diagnostics);
}

test "wrong_type_arity counts the arguments a type constructor was given" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", "pub x : Maybe\nx =\n    Nothing\n");

    const r = try w.run(&.{ "check", "src" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .wrong_type_arity,
        .severity = .@"error",
        .span = .{ .file = "src/Main.beni", .start = .{ .line = 1, .col = 9 }, .end = .{ .line = 1, .col = 14 } },
        .title = "WRONG TYPE ARITY",
        .message = "`Maybe` takes 1 type argument, but here it has 0.\n" ++
            "\n" ++
            "Every type constructor is fully applied — beni has no higher-kinded types — so\n" ++
            "the number has to match the declaration exactly.",
    }}), r.diagnostics);
}

test "recursive_alias points at the alias that starts the cycle" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", "pub type alias Ping =\n    Pong\n\n\npub type alias Pong =\n    Ping\n");

    const r = try w.run(&.{ "check", "src" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .recursive_alias,
        .severity = .@"error",
        .span = .{ .file = "src/Main.beni", .start = .{ .line = 1, .col = 16 }, .end = .{ .line = 1, .col = 20 } },
        .title = "RECURSIVE ALIAS",
        .message = "The type alias `Ping` refers to itself.\n" ++
            "\n" ++
            "An alias is a spelling for the type it names, so one that mentions itself —\n" ++
            "directly, or through other aliases — has no expansion. Make it a `type` with a\n" ++
            "constructor instead; that is what gives recursion somewhere to stop.",
    }}), r.diagnostics);
}

test "duplicate_module: two roots, one module name, reported on the second path" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("a/M.beni", "pub x : Int\nx =\n    1\n");
    try w.write("b/M.beni", "pub y : Int\ny =\n    2\n");

    const r = try w.run(&.{ "check", "a", "b" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .duplicate_module,
        .severity = .@"error",
        .span = .{ .file = "b/M.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 4 } },
        .title = "DUPLICATE MODULE",
        .message = "Two files claim the module name `M`.\n" ++
            "\n" ++
            "The other one is `a/M.beni`. A module's name comes from its path, so two paths that\n" ++
            "differ only outside the source root collide. Move or rename one of them.",
    }}), r.diagnostics);
}

test "equatable is core's alone: the marker and the modifier outside core" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", "pub eq : equatable a -> a -> Bool\neq x y =\n    True\n");

    const r = try w.run(&.{ "check", "src" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .equatable_outside_core,
        .severity = .@"error",
        .span = .{ .file = "src/Main.beni", .start = .{ .line = 1, .col = 10 }, .end = .{ .line = 1, .col = 19 } },
        .title = "EQUATABLE OUTSIDE CORE",
        .message = "The `equatable` marker is core's alone.\n" ++
            "\n" ++
            "It says that a type may be compared with `==`, and only the core package\n" ++
            "states that by hand; your own annotations get the mark by inference. Delete\n" ++
            "it — `a` on its own means the same thing here.",
    }}), r.diagnostics);
}

test "equatable_not_first_occurrence: the prefix marks the variable, once" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // Not `Basics.beni`: a module of the app package named like a core
    // module shadows it (checker.md §2), and `Bool` would then be
    // unresolvable. The declared `Verdict` keeps this about the marker.
    try w.write("Eq.beni", "pub type Verdict\n    = Yes\n\n\npub foreign eq : equatable a -> equatable a -> Verdict\n");

    const r = try w.run(&.{ "check", "--core", "Eq.beni" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .equatable_not_first_occurrence,
        .severity = .@"error",
        .span = .{ .file = "Eq.beni", .start = .{ .line = 5, .col = 33 }, .end = .{ .line = 5, .col = 42 } },
        .title = "EQUATABLE MARKER REPEATED",
        .message = "This type variable is already marked `equatable`.\n" ++
            "\n" ++
            "The prefix marks the VARIABLE, at its first occurrence, not the argument it\n" ++
            "stands in front of: `eq : equatable a -> a -> a -> Bool` is a function of two\n" ++
            "arguments whose type is one marked `a`. Write the marker once.",
    }, r.diagnostics[0]);
}

test "dump --stage=interface prints a module's public face, exactly" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Shapes.beni",
        \\pub type alias Point =
        \\    { x : Int, y : Int }
        \\
        \\
        \\pub opaque type Handle
        \\    = Handle Int
        \\
        \\
        \\pub type Shape a
        \\    = Circle a
        \\    | Rect a a
        \\    | Empty
        \\
        \\
        \\pub area : Shape Int -> Int
        \\area shape =
        \\    0
        \\
        \\
        \\hidden : Int
        \\hidden =
        \\    1
        \\
    );

    const r = try w.runWith(&.{ "dump", "--stage=interface", "src/Shapes.beni" }, .{ .raw_diagnostics = true });

    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualStrings(
        \\module Shapes
        \\  opaque type Handle
        \\  alias Point
        \\    Point/2
        \\  type Shape a
        \\    Circle/1
        \\    Rect/2
        \\    Empty
        \\  value area
        \\
    , r.stdout);
}

test "dump --stage=interface on a directory prints every module in path order" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Util.beni", "pub helper : Int -> Int\nhelper n =\n    n\n");
    try w.write("src/Main.beni", "import Util exposing (helper)\n\n\npub main : Int\nmain =\n    helper 1\n");

    const r = try w.runWith(&.{ "dump", "--stage=interface", "src" }, .{ .raw_diagnostics = true });

    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualStrings("module Main\n  value main\nmodule Util\n  value helper\n", r.stdout);
}

test "--core-root replaces the embedded core package" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A core of one module that has `Int` but not `String`: a project that
    // names `Int` checks, and one that names `String` cannot — which is
    // only true if the flag really replaced the embedded copy rather than
    // adding to it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("mycore/Basics.beni", "pub foreign type Int\n");
    try w.write("src/Main.beni", "pub x : Int\nx =\n    1\n");
    try w.write("other/Main.beni", "pub s : String\ns =\n    \"hi\"\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const ok = try w.run(&.{ "check", "--core-root=mycore", "src" });
    const missing = try w.run(&.{ "check", "--core-root=mycore", "other" });
    const embedded = try w.run(&.{ "check", "other" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), ok.exit_code);
    try testing.expectEqualStrings("", ok.stderr);
    try testing.expectEqual(@as(u8, 1), missing.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{.{
        .code = .unknown_import_name,
        .severity = .@"error",
        .span = .{ .file = "other/Main.beni", .start = .{ .line = 1, .col = 9 }, .end = .{ .line = 1, .col = 15 } },
        .title = "UNKNOWN IMPORT NAME",
        .message = "`Basics` does not expose `String`.\n" ++
            "\n" ++
            "Check the spelling, or check that the declaration in `Basics` is marked `pub`.",
    }}), missing.diagnostics);
    // The same project against the real core package is clean, so the
    // difference above is the flag and nothing else.
    try testing.expectEqual(@as(u8, 0), embedded.exit_code);
    try testing.expectEqualStrings("", embedded.stderr);
}

test "a file under --core-root may use foreign without --core" {
    // `--core` says "the files I named are core sources"; the PACKAGE says
    // the same thing for everything the core root holds, which is why
    // `beni check core` needs no flag (checker.md §3).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("mycore/Basics.beni", "pub foreign type Int\n\n\npub equatable foreign type Float\n");
    try w.write("src/Main.beni", "pub x : Int\nx =\n    1\n");

    const r = try w.run(&.{ "check", "--core-root=mycore", "src" });

    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "resolution is identical at --jobs=1 and --jobs=8, on both streams" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Util.beni", "pub helper : Int -> Int\nhelper n =\n    n\n");
    try w.write("src/Broken.beni", "import Nope\n\n\npub x : Int\nx =\n    Util.absent\n");
    try w.write("src/Main.beni", "import Util exposing (helper)\n\n\npub main : Int\nmain =\n    helper 1\n");

    const one = try w.run(&.{ "check", "--jobs=1", "src" });
    const eight = try w.run(&.{ "check", "--jobs=8", "src" });

    try testing.expectEqual(one.exit_code, eight.exit_code);
    try testing.expectEqualStrings(one.stdout, eight.stdout);
    try testing.expectEqualStrings(one.stderr, eight.stderr);
    try testing.expectEqual(@as(usize, 2), one.diagnostics.len);
}
