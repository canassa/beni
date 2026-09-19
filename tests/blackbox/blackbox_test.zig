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

/// The whole line is `beni <version> <32 hex digits>\n`: the build id follows
/// the version so that a bug report names the compiler that wrote a cache
/// (`fast-compiler.md` §8). The id moves with every edit under `src/`, which
/// is the point of it, so the version half is pinned and the id half is
/// checked for shape.
const expected_version_prefix = "beni 0.1.0-m1 ";

test "version prints the version and the build id on stdout and nothing else" {
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
    try testing.expectEqualStrings("", r.stderr);
    try testing.expect(std.mem.startsWith(u8, r.stdout, expected_version_prefix));
    try testing.expectEqual(expected_version_prefix.len + 33, r.stdout.len);
    const digits = r.stdout[expected_version_prefix.len .. r.stdout.len - 1];
    try testing.expectEqualStrings("\n", r.stdout[r.stdout.len - 1 ..]);
    // Not all zeroes: a build option that defaulted to zero would make every
    // compiler build's cache entries interchangeable, silently.
    var any_nonzero = false;
    for (digits) |c| {
        try testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
        if (c != '0') any_nonzero = true;
    }
    try testing.expect(any_nonzero);

    // And it is stable: two runs of one binary print the same id.
    const again = try w.run(&.{"version"});
    try testing.expectEqualStrings(r.stdout, again.stdout);
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
            "A module name comes from the path: `src/Json/Decode.beni` is `Json.Decode`.\n" ++
            "Every segment of the path after the source root must be an upper identifier — a\n" ++
            "capital letter followed by letters, digits or underscores.",
    }, r.diagnostics[0]);
}

// `.` is how anyone points a compiler at the project they are standing in,
// and until the paths were normalised it was the one spelling that did not
// work: the walk joined the root and the entry into `./Aa.beni`, whose first
// segment `.` is not an upper identifier, so every file in the project came
// back `invalid_module_path` — a fault of the driver's, blamed on the user's
// source. `frontend.md` §1: the module name is the path relative to the
// source root, and for the root `.` that is `Aa.beni`.
test "`.` is a usable path for check, build and fmt, however it is spelled" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "import Node exposing (Program)\nimport Sub.Hello\n\n\nmain : Program\nmain =\n    Node.printLines [ Sub.Hello.hello \"x\" ]\n");
    try w.write("Sub/Hello.beni", "pub hello : String -> String\nhello s =\n    s\n");
    const absolute = try w.projectPath();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // Every one of these names the project directory. `./Sub/..` is there
    // because `..` is NOT resolved lexically — the path is left as written,
    // so it still names this directory and the module below it is still
    // `Main`.
    const spellings = [_][]const u8{ ".", "./", ".//", "./.", "./Sub/..", absolute };
    var results: [spellings.len]world.Result = undefined;
    for (spellings, &results) |spelling, *r| r.* = try w.run(&.{ "check", "--platform=node", spelling });
    const rooted = try w.run(&.{ "check", "--platform=node", "--root=.", "." });
    const formatted = try w.run(&.{ "fmt", "--check", "." });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for (spellings, results) |spelling, r| {
        if (r.exit_code != 0 or r.diagnostics.len != 0) {
            std.debug.print("`check {s}` exited {d}:\n{s}\n", .{ spelling, r.exit_code, r.stderr });
            return error.SpellingRejected;
        }
    }
    try testing.expectEqual(@as(u8, 0), rooted.exit_code);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), rooted.diagnostics);
    try testing.expectEqual(@as(u8, 0), formatted.exit_code);
    try testing.expectEqualStrings("", formatted.stdout);
}

// The other half: what the paths are SPELLED as afterwards. A normalisation
// that turned `.` into an absolute path would fix the exit code and make
// every diagnostic name a file the user never typed, so the rule is lexical
// — `./` and `//` segments are dropped and nothing else moves.
test "a diagnostic under `.` names the file the way the user would" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Sub/bad-name.beni", "x = 1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dot = try w.run(&.{ "check", "." });
    const slash = try w.run(&.{ "check", ".//" });
    const sub = try w.run(&.{ "check", "./Sub" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Under `.` the module path is `Sub/bad-name`, and `bad-name` is what
    // is wrong with it — not the `.`.
    try testing.expectEqual(@as(u8, 1), dot.exit_code);
    try testing.expectEqual(@as(usize, 1), dot.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.invalid_module_path, dot.diagnostics[0].code);
    try testing.expectEqualStrings("Sub/bad-name.beni", dot.diagnostics[0].span.file);
    try testing.expectEqualStrings("Sub/bad-name.beni", slash.diagnostics[0].span.file);
    // With the directory as the root the module path is just the file name.
    try testing.expectEqual(@as(usize, 1), sub.diagnostics.len);
    try testing.expectEqualStrings("Sub/bad-name.beni", sub.diagnostics[0].span.file);
    try testing.expect(std.mem.indexOf(u8, sub.diagnostics[0].message, "`Sub/bad-name.beni`") != null);
}

// Determinism (fast-compiler.md §10): the module index comes from the sorted
// path, so normalising AFTER the sort would make `.` and `$PWD` order the
// files differently. They are normalised at enumeration, before anything is
// numbered, and the emitted program is the proof — two builds of the same
// directory named two ways, byte for byte.
test "`.` and the absolute path of the same directory emit byte-identical output" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "import Node exposing (Program)\nimport Sub.Hello\n\n\nmain : Program\nmain =\n    Node.printLines [ Sub.Hello.hello \"x\" ]\n");
    try w.write("Sub/Hello.beni", "pub hello : String -> String\nhello s =\n    s\n");
    const absolute = try w.projectPath();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const by_dot = try w.runWith(&.{ "build", "--platform=node", "--out=dot", "." }, .{ .raw_diagnostics = true });
    const by_absolute = try w.runWith(&.{ "build", "--platform=node", "--out=abs", absolute }, .{ .raw_diagnostics = true });
    const hash_dot = try w.runWith(&.{ "check", "--platform=node", "--iface-hash", "." }, .{ .raw_diagnostics = true });
    const hash_absolute = try w.runWith(&.{ "check", "--platform=node", "--iface-hash", absolute }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), by_dot.exit_code);
    try testing.expectEqual(@as(u8, 0), by_absolute.exit_code);
    try testing.expectEqualStrings("", by_dot.stderr);
    try testing.expectEqualStrings("", by_absolute.stderr);
    try testing.expectEqualStrings(hash_dot.stdout, hash_absolute.stdout);

    const dot_files = try w.listFiles("dot");
    const absolute_files = try w.listFiles("abs");
    try testing.expect(dot_files.len > 1);
    try testing.expectEqual(dot_files.len, absolute_files.len);
    var dot_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (dot_files, absolute_files) |a, b| {
        try testing.expectEqualStrings(a, b);
        const from_dot = try w.read(try std.fmt.bufPrint(&dot_buffer, "dot/{s}", .{a}));
        const from_absolute = try w.read(try std.fmt.bufPrint(&absolute_buffer, "abs/{s}", .{b}));
        try testing.expectEqualStrings(from_dot, from_absolute);
    }
}

// One argv may name the same file two ways — `.` walks it and the path names
// it again — and a file is one module however many times it is named
// (`SourceStore.finish` dedups by path). That dedup is by the NORMALISED
// path, so `./Main.beni` and the walk's `Main.beni` are one entry and not a
// `duplicate_module`.
test "a mixed argv naming a file the walk already found is still one module" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni", "main = notDefined\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const once = try w.run(&.{ "check", "." });
    const four_ways = try w.run(&.{ "check", ".", "./Main.beni", ".//Main.beni", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), once.exit_code);
    try testing.expectEqual(@as(usize, 1), once.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.unbound_variable, once.diagnostics[0].code);
    try testing.expectEqualDeep(once.diagnostics, four_ways.diagnostics);
    try testing.expectEqual(once.exit_code, four_ways.exit_code);
}

// `frontend.md` §1: formatting "is per file and resolves nothing". A module
// name is a resolution concept — it is what an `import` finds — so `fmt` has
// no business deriving one, and a file whose path names no module is still a
// file the formatter can read, parse and print. `check` on the same file
// still says `invalid_module_path`, because checking it means resolving it.
test "fmt formats a file whose path names no module; check still refuses it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("not-a-module.beni", "x =\n  1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const listed = try w.run(&.{ "fmt", "--check", "." });
    const printed = try w.runWith(&.{ "fmt", "--stdout", "not-a-module.beni" }, .{ .raw_diagnostics = true });
    const written = try w.run(&.{ "fmt", "not-a-module.beni" });
    const checked = try w.run(&.{ "check", "not-a-module.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), listed.exit_code); // it WOULD change
    try testing.expectEqualStrings("not-a-module.beni\n", listed.stdout);
    try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &.{}), listed.diagnostics);
    try testing.expectEqualStrings("x =\n    1\n", printed.stdout);
    try testing.expectEqual(@as(u8, 0), written.exit_code);
    try testing.expectEqualStrings("x =\n    1\n", try w.read("not-a-module.beni"));
    try testing.expectEqual(@as(u8, 1), checked.exit_code);
    try testing.expectEqual(@as(usize, 1), checked.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.invalid_module_path, checked.diagnostics[0].code);
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
            "A module name comes from the path: `src/Json/Decode.beni` is `Json.Decode`.\n" ++
            "Every segment of the path after the source root must be an upper identifier — a\n" ++
            "capital letter followed by letters, digits or underscores.\n" ++
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
    // `--no-cache`, because the subject is EXACTLY which phases a run
    // performs and the cache is on by default since M4-3: a cached run also
    // emits `frontend_load` and `frontend_store` per file, legitimately, and
    // a row that allowed them would stop saying "these and no others". What
    // a cached run's phases are is `cache_test.zig`'s counters.
    const r = try w.run(&.{ "check", "--self-profile=trace.json", "--no-cache", "--core-root=nocore", "--jobs=2", "src" });

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
    // `--no-cache`, because the subject is EXACTLY which phases a run
    // performs and the cache is on by default since M4-3: a cached run also
    // emits `frontend_load` and `frontend_store` per file, legitimately, and
    // a row that allowed them would stop saying "these and no others". What
    // a cached run's phases are is `cache_test.zig`'s counters.
    const r = try w.run(&.{ "check", "--self-profile=trace.json", "--no-cache", "--core-root=nocore", "--jobs=2", "src" });

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
            unifications: ?u64 = null,
            generalisations: ?u64 = null,
            instantiations: ?u64 = null,
            obligations: ?u64 = null,
            dropped_events: ?u64 = null,
        },
    };
    const text = try w.read("trace.json");
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Four phase events per file, each naming its own file and carrying
    // that file's size; three serial steps with no file at all.
    var seen: [files.len][4]bool = @splat(@splat(false));
    // `resolve`, `check` and its three halves are per MODULE, not per file
    // (checker.md §9): they name the module's file but carry no byte count,
    // because what they measure is a graph and a constraint tree, not a
    // span of source. Per module and not per run, because "this module was
    // not re-checked" is what M4's incrementality tests have to see.
    var per_module_seen: [files.len][7]bool = @splat(@splat(false));
    var serial: [6]bool = @splat(false);
    const per_file = [_][]const u8{ "read", "lex", "parse", "lower" };
    // `cache_load` and `dep_digest` are per MODULE from M4-3 on, not serial
    // passes: the key is finished, the entry is loaded and the two published
    // values are computed on the worker that claimed the module, because an
    // import's contribution exists only once that import has been checked
    // (`fast-compiler.md` §8). Both are emitted with or without a cache
    // directory, so that there is one code path rather than two.
    const per_module = [_][]const u8{ "resolve", "check", "constrain", "solve", "exhaustive", "cache_load", "dep_digest" };
    // `types` is serial and once per run (checker.md §5): numbering every
    // declared type and settling equatability. It is in the trace because
    // it can DOMINATE a build — a project of long alias chains spent 1.3 s
    // of a 1.35 s compile there — and `fast-compiler.md` §12 makes the
    // trace the instrument.
    //
    // `cache_key` is serial too, and it is here on EVERY run and not only a
    // cached one (`fast-compiler.md` §8). What it still does serially from
    // M4-3 on is the part of the key that depends on nothing else in the
    // project — reading and hashing every source and every sibling `.js` —
    // with or without a cache directory, so that there is one code path
    // rather than two, and so that what it costs is a row in the trace rather
    // than a number nobody has.
    const serial_names = [_][]const u8{ "enumerate", "merge_interners", "graph", "types", "cache_key", "render" };
    var counters: [13]?u64 = @splat(null);
    for (parsed.value.traceEvents) |e| {
        if (std.mem.eql(u8, e.ph, "X")) {
            try testing.expectEqualStrings("phase", e.cat.?);
            try testing.expect(e.tid < 2);
            if (e.args.file) |file| {
                const f = indexOfPath(&files, file) orelse {
                    std.debug.print("phase event for an unexpected file: {s}\n", .{file});
                    return error.UnexpectedPhaseEvent;
                };
                if (indexOfName(&per_module, e.name)) |half| {
                    try testing.expect(!per_module_seen[f][half]); // exactly one each
                    per_module_seen[f][half] = true;
                    continue;
                }
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
            if (std.mem.eql(u8, e.name, "unifications")) counters[9] = e.args.unifications;
            if (std.mem.eql(u8, e.name, "generalisations")) counters[10] = e.args.generalisations;
            if (std.mem.eql(u8, e.name, "instantiations")) counters[11] = e.args.instantiations;
            if (std.mem.eql(u8, e.name, "obligations")) counters[12] = e.args.obligations;
        }
    }
    try testing.expectEqual([files.len][4]bool{ @splat(true), @splat(true), @splat(true) }, seen);
    try testing.expectEqual([files.len][7]bool{ @splat(true), @splat(true), @splat(true) }, per_module_seen);
    try testing.expectEqual([6]bool{ true, true, true, true, true, true }, serial);

    // `files`, `bytes` and `tokens` are computed above; `nodes` and
    // `insts` are the AST and BIR sizes of these three modules, which
    // nothing outside the compiler can derive — they are literals, and a
    // change to either IR's shape is meant to show up here as a number to
    // look at rather than as silence.
    // `modules`, `edges` and `interfaces` are the M2a additions: three
    // modules that import nothing, so no edge, and one interface each.
    // The four checker counters are M2b's (checker.md §9). `main = 1` is
    // one unification (the literal against the declaration's variable) and
    // one generalisation; `double x = x` is two more unifications (the
    // declaration against `p -> r`, then `r` against `p`), one
    // instantiation (the reference to `x`) and two generalisations (the
    // arrow and the variable under it). `type Color` declares no value and
    // contributes nothing to any of them. No obligation: `==`, `${…}` and
    // `.0` are the only things that make one, and `--core-root=nocore`
    // means there is no core package to name anyway.
    try testing.expectEqual([13]?u64{ 3, total_bytes, total_tokens, 11, 3, 0, 3, 0, 3, 3, 3, 1, 0 }, counters);
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
    try testing.expectEqualStrings("beni: dump needs --stage=tokens|ast|bir|interface|raw|types|graph|dispatch\n", dump_bad.stderr);
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

test "a lexical error does not stop the file: later lines still lex, and dump prints them and exits 1" {
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
    // The dump is the product and it is complete; the exit code is the
    // binary's rule and says an `error` was printed (`frontend.md` §1).
    try testing.expectEqual(@as(u8, 1), r.exit_code);
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
            .message = "I was parsing a parenthesised expression and ran into `g` on column 1 before\n" ++
                "finding the `)` that closes this `(`.\n" ++
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

test "dump --stage=ast on a broken file prints placeholders in the tree, the errors on stderr, and exits 1" {
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
    // The tree — placeholder and all — is still the product; exit 1 is the
    // binary's rule about having printed an `error` (`frontend.md` §1).
    try testing.expectEqual(@as(u8, 1), r.exit_code);
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

// The exit-code rule is the BINARY's — `frontend.md` §1 and `beni help` both
// state it once, for every subcommand, and only a `warning` is exempt. Every
// `dump` stage used to print a full `error` diagnostic on stderr and exit 0,
// so a script, an editor or M5's LSP driving `dump` read a silent success
// over a file the compiler had just refused. The dump is still printed: a
// broken file is exactly the file someone runs `dump` on.
test "every dump stage exits 1 over a file that produced an error, and still prints what it has" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    // An unclosed `(`: every stage from the lexer down has something to say
    // about it, and every stage has something to print anyway.
    try w.write("Min.beni", "f =\n    (\n");
    try w.write("Fine.beni", "f =\n    1\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const stages = [_][]const u8{
        "--stage=tokens",    "--stage=ast",   "--stage=bir",   "--stage=raw",
        "--stage=interface", "--stage=types", "--stage=graph", "--stage=dispatch",
    };
    var broken: [stages.len]world.Result = undefined;
    var fine: [stages.len]world.Result = undefined;
    for (stages, &broken, &fine) |stage, *b, *f| {
        b.* = try w.runWith(&.{ "dump", stage, "Min.beni" }, .{ .raw_diagnostics = true });
        f.* = try w.runWith(&.{ "dump", stage, "Fine.beni" }, .{ .raw_diagnostics = true });
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for (stages, broken, fine) |stage, b, f| {
        if (b.exit_code != 1) {
            std.debug.print("dump {s} over a broken file exited {d}\n--- stderr ---\n{s}\n", .{ stage, b.exit_code, b.stderr });
            return error.DumpDidNotFail;
        }
        // The product is still on stdout, and the diagnostic is still the
        // whole message on stderr — the exit code is all that changed.
        try testing.expect(b.stdout.len != 0);
        try testing.expect(std.mem.indexOf(u8, b.stderr, "UNCLOSED DELIMITER") != null);
        // A clean file is still 0, on every one of the same stages.
        if (f.exit_code != 0) {
            std.debug.print("dump {s} over a clean file exited {d}\n--- stderr ---\n{s}\n", .{ stage, f.exit_code, f.stderr });
            return error.CleanDumpFailed;
        }
        try testing.expectEqualStrings("", f.stderr);
    }
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

// The formatter rewrites the user's files in place, so everything about a
// file that is not its contents is an output of `fmt` too. Write-to-temp +
// `rename` carried the temporary's own mode onto the destination: every
// rewritten file came back `0644`, which made a `0600` source file
// world-readable and cost a `0755` script its `x`.
test "fmt in place keeps the file's mode" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const modes = [_]u32{ 0o600, 0o640, 0o700, 0o755, 0o664 };
    var names: [modes.len][]const u8 = undefined;
    var buffers: [modes.len][32]u8 = undefined;
    for (modes, &names, &buffers) |bits, *name, *buffer| {
        name.* = try std.fmt.bufPrint(buffer, "M{o}.beni", .{bits});
        try w.write(name.*, ugly_module);
        if (!try w.setMode(name.*, bits)) {
            std.debug.print("this filesystem does not carry permissions; nothing to assert\n", .{});
            return;
        }
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "fmt", "." });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    for (modes, names) |bits, name| {
        try testing.expectEqualStrings(canonical_module, try w.read(name));
        try testing.expectEqual(bits, try w.mode(name));
    }
}

// A file the user marked read-only is not the formatter's to rewrite, and
// `rename` does not consult the destination's mode — only the directory's —
// so a `0444` module was silently rewritten. Refusing it is an I/O failure:
// exit 2 (`frontend.md` §1), the file untouched, and the run's other files
// still formatted.
test "fmt refuses a file it cannot write and leaves every byte of it alone" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("ReadOnly.beni", ugly_module);
    try w.write("Writable.beni", ugly_module);
    try w.write("locked/Inside.beni", ugly_module);
    if (!try w.setMode("ReadOnly.beni", 0o444)) {
        std.debug.print("this filesystem does not carry permissions; nothing to assert\n", .{});
        return;
    }
    _ = try w.setMode("locked", 0o555);
    defer _ = w.setMode("locked", 0o755) catch false;

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "fmt", "." }, .{ .raw_diagnostics = true });
    const one = try w.runWith(&.{ "fmt", "ReadOnly.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 2), r.exit_code);
    try testing.expectEqual(@as(u8, 2), one.exit_code);
    try testing.expectEqualStrings("beni: cannot write 'ReadOnly.beni': AccessDenied\n", one.stderr);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "cannot write 'ReadOnly.beni': AccessDenied") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "cannot write 'locked/Inside.beni': AccessDenied") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings(ugly_module, try w.read("ReadOnly.beni"));
    try testing.expectEqual(@as(u32, 0o444), try w.mode("ReadOnly.beni"));
    try testing.expectEqualStrings(ugly_module, try w.read("locked/Inside.beni"));
    // The refusal is per file: everything else in the run was still done.
    try testing.expectEqualStrings(canonical_module, try w.read("Writable.beni"));
}

// `rename` replaces the NAME it is given, so a symlink handed to `fmt` came
// back as a regular file holding the formatted text while the module it
// pointed at kept its old bytes — the link destroyed, the real file
// unformatted, exit 0. The link is now followed to the file it names, which
// is what `gofmt` and `zig fmt` do.
test "fmt writes through a symlink and leaves the link itself alone" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("elsewhere/Target.beni", ugly_module);
    _ = try w.setMode("elsewhere/Target.beni", 0o600);
    try w.symlink("elsewhere/Target.beni", "Link.beni");
    try w.symlink("Nowhere.beni", "Dangling.beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "fmt", "Link.beni" }, .{ .raw_diagnostics = true });
    const again = try w.runWith(&.{ "fmt", "--check", "Link.beni" }, .{ .raw_diagnostics = true });
    const dangling = try w.runWith(&.{ "fmt", "Dangling.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    // The write reached the target, so a second pass has nothing to do.
    try testing.expectEqual(@as(u8, 0), again.exit_code);
    try testing.expectEqualStrings("", again.stdout);
    // A link to nothing is an unreadable path, which is exit 2 and not a
    // regular file created where the link was.
    try testing.expectEqual(@as(u8, 2), dangling.exit_code);
    try testing.expectEqualStrings("beni: cannot read 'Dangling.beni': FileNotFound\n", dangling.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(std.Io.File.Kind.sym_link, try w.kind("Link.beni"));
    try testing.expectEqualStrings("elsewhere/Target.beni", try w.readLink("Link.beni"));
    try testing.expectEqualStrings(canonical_module, try w.read("elsewhere/Target.beni"));
    try testing.expectEqual(@as(u32, 0o600), try w.mode("elsewhere/Target.beni"));
    try testing.expectEqual(std.Io.File.Kind.sym_link, try w.kind("Dangling.beni"));
}

// Two claims about doing nothing. A file that is already canonical is not
// written at all — its mtime is what editors and build tools watch — and a
// rename BREAKS a hard link, which is accepted (atomicity is worth more than
// a link count) and therefore pinned: if that trade is ever reversed, this
// is the test that says so.
test "fmt touches nothing when there is nothing to do, and breaks a hard link when there is" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Fine.beni", canonical_module);
    _ = try w.setMode("Fine.beni", 0o600);
    try w.write("Linked.beni", ugly_module);
    try w.hardLink("Linked.beni", "Second.beni");
    const before = try w.mtime("Fine.beni");
    try testing.expectEqual(@as(u64, 2), try w.linkCount("Linked.beni"));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "fmt", "Fine.beni", "Linked.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(before, try w.mtime("Fine.beni"));
    try testing.expectEqual(@as(u32, 0o600), try w.mode("Fine.beni"));
    try testing.expectEqualStrings(canonical_module, try w.read("Linked.beni"));
    // Accepted and documented (`fmt/Command.zig`): the other name is now a
    // file of its own, holding what it held.
    try testing.expectEqualStrings(ugly_module, try w.read("Second.beni"));
    try testing.expectEqual(@as(u64, 1), try w.linkCount("Linked.beni"));
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

test "dump --stage=bir shows a pipeline as pipe-first saturated calls and an operator as a core call" {
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
        \\  %9 = call %2 [%1, %8]
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
            "Shadowing is not allowed: a binding cannot reuse a name that is in scope,\n" ++
            "whether from an enclosing binding, a top-level declaration, an `exposing` list\n" ++
            "or the prelude. Rename one of them.",
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
        .code = .foreign_outside_platform,
        .severity = .@"error",
        .span = .{ .file = "Prim.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 16 } },
        .title = "FOREIGN OUTSIDE PLATFORM",
        .message = "This `foreign` declaration is outside a platform package.\n" ++
            "\n" ++
            "`foreign` declares a value or type implemented in JavaScript. It is legal in the\n" ++
            "core package and in a package whose manifest says `\"platform\": true`\n" ++
            "(`docs/design/boundary.md` §2), and nowhere else. Write the definition in beni,\n" ++
            "or move it into a platform package of your own.",
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
            "The other one is `a/M.beni`. A module's name comes from its path, so two paths\n" ++
            "that differ only outside the source root collide. Move or rename one of them.",
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
            "stands in front of: `eq : equatable a -> a -> Bool` is a function of two\n" ++
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
        \\  value area : Shape Int -> Int
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
    try testing.expectEqualStrings("module Main\n  value main : Int\nmodule Util\n  value helper : Int -> Int\n", r.stdout);
}

test "--core-root replaces the embedded core package" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A core of one module that has `Int` but not `String`: a project that
    // names `Int` checks, and one that names `String` cannot — which is
    // only true if the flag really replaced the embedded copy rather than
    // adding to it. `String` is declared by the module `String`
    // (static-dispatch-spike.md §5.1), which this core does not have at
    // all, so the prelude row it resolves through names a missing module.
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
        .code = .unknown_module_alias,
        .severity = .@"error",
        .span = .{ .file = "other/Main.beni", .start = .{ .line = 1, .col = 9 }, .end = .{ .line = 1, .col = 15 } },
        .title = "UNKNOWN MODULE",
        .message = "I cannot find a module named `String`.\n" ++
            "\n" ++
            "The qualified name `String.String` needs it. Check the spelling, or add an\n" ++
            "import.",
    }}), missing.diagnostics);
    // The same project against the real core package is clean, so the
    // difference above is the flag and nothing else.
    try testing.expectEqual(@as(u8, 0), embedded.exit_code);
    try testing.expectEqualStrings("", embedded.stderr);
}

test "--core-root without the operators' functions is reported, not emitted as undefined" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The comparison operators are method calls now
    // (`docs/design/static-dispatch-spike.md` §3.1) and the backend
    // rebuilds the core reference each one needs itself, so the failure
    // that used to come out of name resolution — the lowered `import_value`
    // not resolving — has to come out of the backend instead. Without that
    // report the operator compiled to `undefined(a, b)` and the build
    // exited 0.
    //
    // `<` on `String` is the case S4 leaves: §3.2 gives it `primitive
    // string_compare` and §8.3 emits `String$compare(a, b) === "LT"`,
    // because `<` on JavaScript strings is UTF-16 code-unit order and
    // `String.compare` is Unicode scalar order (A.26). `==` on `Int` is
    // `===` now and needs no core value at all.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("mycore/Basics.beni", "pub equatable foreign type Int\n\n\npub type Bool\n    = True\n    | False\n");
    try w.write("mycore/Basics.js", "export {};\n");
    try w.write("mycore/String.beni", "pub equatable foreign type String\n");
    try w.write("mycore/String.js", "export {};\n");
    // `List` is here because a core root has to have one; nothing below
    // compares a list any more (§5.2 gives `List` its own `pub foreign eq`).
    try w.write("mycore/List.beni", "pub equatable foreign type List a\n");
    try w.write("mycore/List.js", "export {};\n");
    try w.write("myplat/beni.json",
        \\{ "platform": true, "name": "mine", "program": "Prog.Program", "runtime": "run.js" }
    );
    try w.write("myplat/Prog.beni", "pub foreign type Program\n\n\npub foreign say : Int -> Program\n");
    try w.write("myplat/Prog.js", "export const say = (n) => ({ n });\n");
    try w.write("myplat/run.js", "export const run = (program) => {};\n");
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\
        \\
        \\pub before : String, String -> Bool
        \\before a b =
        \\    a < b
        \\
        \\
        \\main : Program
        \\main =
        \\    if before "a" "b" then Prog.say 1 else Prog.say 0
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // `main` CALLS `before`, and that is load-bearing since `backend.md`
    // §9: elimination decides what is written, and a declaration nothing
    // reaches is never lowered, so its lowering diagnostic is never raised
    // (§5). `pub` is not a root in an application build. A version of this
    // fixture whose `main` ignored `before` would exit 0 and prove nothing.
    const r = try w.run(&.{ "build", "--platform=./myplat", "--core-root=mycore", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.internal, r.diagnostics[0].code);
    try testing.expectEqual(@as(u32, 6), r.diagnostics[0].span.start.line);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "`String.compare`") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY STATE                            │
    // └─────────────────────────────────────────┘
    // A refused build writes nothing (backend.md §2).
    try testing.expect(!w.exists("out/Main.mjs"));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE — the other half of the message │
    // └─────────────────────────────────────────┘
    // `String.compare` is one of the two values the diagnostic names;
    // `Basics.eq` is the other, and it is a DIFFERENT path to the same
    // report. After S6b a type compares through its OWN derived body (§9.4)
    // and `List a` has a `pub foreign eq` of its own (§5.2), so the ONE
    // position still answered by `core/Basics.js`'s walk is the one A.66
    // names: a slot no use ever pins. `None == None` never inhabits `Opt`'s
    // parameter, so the part is `err`, and `partEq`'s `err` arm reaches for
    // `Basics.eq` — which a core root without one cannot supply. Without
    // this half the `Basics` branch of `missingCoreValue` is unexercised.
    //
    // (This used to be `xs == ys` on a `List Int` through A.51's bridge.
    // That bridge is gone with S6b: a derived target with no body is now a
    // table bug and says so.)
    //
    // Both declarations name `Basics.eq` and neither names `Basics.neq`:
    // §8.3 makes `a /= b` the NEGATION of the method, `!eq(a, b)`, so the
    // emitter reaches for one function and not two.
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\
        \\
        \\pub type Opt a
        \\    = Some a
        \\    | None
        \\
        \\
        \\pub same : Bool
        \\same =
        \\    None == None
        \\
        \\
        \\pub differ : Bool
        \\differ =
        \\    None /= None
        \\
        \\
        \\main : Program
        \\main =
        \\    if same then Prog.say 1 else if differ then Prog.say 2 else Prog.say 0
        \\
    );
    const eq = try w.run(&.{ "build", "--platform=./myplat", "--core-root=mycore", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), eq.exit_code);
    try testing.expectEqual(@as(usize, 2), eq.diagnostics.len);
    for (eq.diagnostics) |d| try testing.expectEqual(diagnostic.Code.internal, d.code);
    // Sorted by position, so `same` before `differ` — and both name `eq`.
    for (eq.diagnostics) |d| try testing.expect(std.mem.indexOf(u8, d.message, "`Basics.eq`") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY STATE                            │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("out/Main.mjs"));
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

// ---------------------------------------------------------------------------
// M2b — the type checker (checker.md §6, §8)
// ---------------------------------------------------------------------------

test "a type mismatch names the definition, shows both types and hints" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\pub label : Int -> String
        \\label n =
        \\    n
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
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .type_mismatch,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 3, .col = 5 }, .end = .{ .line = 3, .col = 6 } },
        .title = "TYPE MISMATCH",
        .message = "Something is off with the body of this definition:\n" ++
            "\n" ++
            "The body is:\n" ++
            "\n" ++
            "    Int\n" ++
            "\n" ++
            "But the type annotation says it should be:\n" ++
            "\n" ++
            "    String\n" ++
            "\n" ++
            "Hint: want to turn a number into a `String`? Use `String.fromInt` or\n" ++
            "`String.fromFloat`.\n",
    }, r.diagnostics[0]);
}

test "TOO FEW ARGS names the function, its arity, and the missing argument" {
    // checker.md §8.3's load-bearing diagnostic, asserted whole rather than
    // by its code. Nothing is deferred: with saturated calls there is no
    // partial-application reading to argue against.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\pub type alias Model =
        \\    { count : Int }
        \\
        \\
        \\pub update : Int, Model -> Model
        \\update n model =
        \\    { model | count = model.count + n }
        \\
        \\
        \\pub step : Model -> Model
        \\step model =
        \\    update 1
        \\
    );

    const r = try w.run(&.{ "check", "Main.beni" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .too_few_args,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 12, .col = 5 }, .end = .{ .line = 12, .col = 11 } },
        .title = "TOO FEW ARGS",
        .message = "The `update` function expects 2 arguments, but it got only 1.\n" ++
            "\n" ++
            "The missing argument is:\n" ++
            "\n" ++
            "    Model\n" ++
            "\n" ++
            "Hint: every call supplies every argument. To make a function out of this one,\n" ++
            "write the missing argument as `_`: `f a _` is `\\x -> f a x`.\n",
    }, r.diagnostics[0]);
}

test "`==` on functions is a compile error, not a runtime crash" {
    // fast-compiler.md §3.1 point 5: dropping `comparable` turns Elm's last
    // runtime crash into this. On this branch `==` is the `eq` method
    // (static-dispatch-spike.md §3.1) and `dischargeMethod` raises
    // `not_equatable` itself (§6.3, §3.4), at the OPERATOR — which is the
    // region §10.3 asks for.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\pub same : (Int -> Int), (Int -> Int) -> Bool
        \\same f g =
        \\    f == g
        \\
    );

    const r = try w.run(&.{ "check", "Main.beni" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .not_equatable,
        .severity = .@"error",
        .span = .{ .file = "Main.beni", .start = .{ .line = 3, .col = 7 }, .end = .{ .line = 3, .col = 9 } },
        .title = "NOT EQUATABLE",
        .message = "I cannot compare these values with `==`:\n" ++
            "\n" ++
            "    Int -> Int\n" ++
            "\n" ++
            "There is a function in there, and comparing functions is not decidable:\n" ++
            "deciding whether two functions agree on every input is the halting problem.\n" ++
            "\n" ++
            "Hint: compare the values the functions produce, or store something you can\n" ++
            "compare — a name, an id — next to the function.\n",
    }, r.diagnostics[0]);
}

test "a dozen checker diagnostics, each by code and span" {
    // One file per case so the spans are stated exactly, and a single sweep
    // so the catalogue of checker.md §8.1 is covered in one place. The prose
    // of each is asserted whole by its `check/bad` fixture; what this adds
    // is that the CODE and the SPAN are what the schema promises.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    const Case = struct {
        path: []const u8,
        source: []const u8,
        code: diagnostic.Code,
        start: diagnostic.Position,
    };
    const cases = [_]Case{
        .{
            .path = "A.beni",
            .source = "pub wrong : a -> Int\nwrong value =\n    value\n",
            .code = .rigid_mismatch,
            .start = .{ .line = 3, .col = 5 },
        },
        .{
            .path = "B.beni",
            .source = "selfApply f =\n    f f\n",
            .code = .infinite_type,
            .start = .{ .line = 2, .col = 5 },
        },
        .{
            .path = "C.beni",
            .source = "both x =\n    x + x ++ x\n",
            .code = .kind_mismatch,
            .start = .{ .line = 2, .col = 7 },
        },
        .{
            .path = "D.beni",
            .source = "pub best : Int\nbest =\n    max 1 2 3\n",
            .code = .too_many_args,
            .start = .{ .line = 3, .col = 5 },
        },
        .{
            .path = "E.beni",
            .source = "pub limit : Int\nlimit =\n    1\n\n\npub best : Int\nbest =\n    limit 2\n",
            .code = .not_a_function,
            .start = .{ .line = 8, .col = 5 },
        },
        .{
            .path = "F.beni",
            .source = "pub type alias P =\n    { x : Int, y : Int }\n\n\npub p : P\np =\n    { x = 1 }\n",
            .code = .missing_field,
            .start = .{ .line = 7, .col = 5 },
        },
        .{
            .path = "G.beni",
            .source = "pub type alias P =\n    { x : Int }\n\n\npub p : P\np =\n    { x = 1, y = 2 }\n",
            .code = .unknown_field,
            .start = .{ .line = 7, .col = 5 },
        },
        .{
            .path = "H.beni",
            .source = "pub coords : { r | x : Int } -> { r | x : Int }\ncoords point =\n    { x = point.x }\n",
            .code = .record_not_closed,
            .start = .{ .line = 3, .col = 5 },
        },
        .{
            .path = "I.beni",
            .source = "pub show : List Int -> String\nshow xs =\n    \"xs: ${xs}\"\n",
            .code = .not_interpolatable,
            .start = .{ .line = 3, .col = 12 },
        },
        .{
            .path = "J.beni",
            .source = "show value =\n    \"v: ${value}\"\n",
            .code = .ambiguous_interpolation,
            .start = .{ .line = 2, .col = 11 },
        },
        .{
            .path = "K.beni",
            .source = "firstOf t =\n    t.0\n",
            .code = .ambiguous_tuple,
            .start = .{ .line = 2, .col = 6 },
        },
        .{
            .path = "L.beni",
            .source = "pub third : ( Int, Int ) -> Int\nthird t =\n    t.2\n",
            .code = .tuple_index_out_of_range,
            .start = .{ .line = 3, .col = 6 },
        },
        .{
            .path = "M.beni",
            .source = "pub type alias P =\n    { x : Int }\n\n\npub firstOf : P -> Int\nfirstOf p =\n    p.0\n",
            .code = .not_a_tuple,
            .start = .{ .line = 7, .col = 6 },
        },
        .{
            .path = "N.beni",
            .source = "pub step : Int -> Result String Int\nstep n =\n    Ok (n? + 1)\n",
            .code = .try_shape,
            .start = .{ .line = 3, .col = 10 },
        },
    };

    for (cases) |case| {
        try w.write(case.path, case.source);
        const r = try w.run(&.{ "check", case.path });
        if (r.exit_code != 1 or r.diagnostics.len != 1) {
            std.debug.print("{s}: expected exactly one diagnostic, got {d} (exit {d})\n{s}\n", .{ case.path, r.diagnostics.len, r.exit_code, r.stderr });
            return error.WrongDiagnosticCount;
        }
        try testing.expectEqualDeep(diagnostic.Span{
            .file = case.path,
            .start = case.start,
            .end = r.diagnostics[0].span.end,
        }, r.diagnostics[0].span);
        try testing.expectEqual(case.code, r.diagnostics[0].code);
        try testing.expectEqualStrings(diagnostic.title(case.code), r.diagnostics[0].title);
        try testing.expect(r.diagnostics[0].message.len > 0);
    }
}

test "dump --stage=types prints every declaration's scheme and every local's type" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni",
        \\pub type alias Point =
        \\    { x : Int, y : Int }
        \\
        \\
        \\pub shift : Point -> Point
        \\shift p =
        \\    { p | x = p.x + 1 }
        \\
        \\
        \\apply f x =
        \\    f x
        \\
        \\
        \\total xs =
        \\    let
        \\        step a b =
        \\            a + b
        \\    in
        \\    List.foldl xs 0 step
        \\
    );

    const r = try w.runWith(&.{ "dump", "--stage=types", "src/Main.beni" }, .{ .raw_diagnostics = true });

    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    // `step` is let-bound and therefore GENERALISED, so its scheme's
    // variable is not the one `total`'s type ended up with — the use site
    // instantiated a copy. `number2` says exactly that, and it would be a
    // lie to print `number` twice.
    try testing.expectEqualStrings(
        \\module Main
        \\  shift : Point -> Point
        \\    p : Point
        \\  apply : (a -> b), a -> b
        \\    f : a -> b
        \\    x : a
        \\  total : List number -> number
        \\    xs : List number
        \\    step : number2, number2 -> number2
        \\    a : number2
        \\    b : number2
        \\
    , r.stdout);
}

test "a derived compare compiles, and so does List's" {
    // The two ends of §9's `compare`, both closed: S6a emits every derived
    // body and S6b gives `List a` the `pub foreign compare` of §5.2.
    //
    // `List a` is the one type in core with no shape to derive from — no
    // constructors — so it was the last program in the language that `<`
    // refused. It refused in the CHECKER and not in the backend, which is
    // the half worth remembering: a `foreign type` with no `pub compare`
    // fails §3.3's "shape supports it" test (A.50, A.54), so
    // `unknown_method` arrived before a dispatch site was ever written.
    // A `pub foreign compare … where a.compare` answers §3.3 at step 1, so
    // both halves are gone at once.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\shorter : List Int, List Int -> Bool
        \\shorter a b =
        \\    a < b
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines
        \\        [ if shorter [ 1, 2 ] [ 1, 2, 3 ] then
        \\            "True"
        \\
        \\          else
        \\            "False"
        \\        ]
        \\
    );

    const listed = try w.buildAndRun(&.{"Main.beni"});
    try testing.expectEqual(@as(u8, 0), listed.build.exit_code);
    try testing.expectEqual(@as(usize, 0), listed.build.diagnostics.len);
    // A shorter list is `LT` against a longer one with the same prefix
    // (§9.5), which is Elm's order.
    try testing.expectEqualStrings("True\n", listed.program.?.stdout);
    // And the call is `List$compare` with the ELEMENT's comparator as the
    // hidden first argument (§8.1, A.7) — not a structural walk, and not
    // the JavaScript `<`.
    const main_mjs = try w.read("out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, main_mjs, "List$compare(") != null);

    // A DERIVED `compare` — what this test asserted was refused before S6a
    // — compiles and runs the same way. `T`'s own `compare` is written from
    // its shape (§9.4) and `<` is that function's answer tested against
    // "LT" (§8.3).
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\type T
        \\    = T Int
        \\
        \\
        \\before : T, T -> Bool
        \\before a b =
        \\    a < b
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines
        \\        [ if before (T 1) (T 2) then
        \\            "True"
        \\
        \\          else
        \\            "False"
        \\        ]
        \\
    );
    const ok = try w.buildAndRun(&.{"Main.beni"});
    try testing.expectEqual(@as(u8, 0), ok.build.exit_code);
    try testing.expectEqual(@as(usize, 0), ok.build.diagnostics.len);
    try testing.expectEqualStrings("True\n", ok.program.?.stdout);
}

test "a derived eq calls the user's own eq, across a module boundary" {
    // The program A.51's narrow bridge was built for, now compiled the way
    // §9.2 says rather than refused.
    //
    // `core/Basics.js`'s `eq` is one structural walk: it compares every
    // reachable primitive with `===` and knows nothing about a user's `pub
    // eq`. A derived `eq` does know — the checker put that method in the
    // table as a part — so the two functions give DIFFERENT answers here:
    // `Id`'s own `eq` compares only the major number, so `{ k = Id 1 2 } ==
    // { k = Id 1 99 }` is `True` by the table and `False` by the walk.
    //
    // S4 could emit neither and refused (`backend.md` §1). S5 emits the
    // record shape's own function, hands it `Id$eq` as the `k` field's
    // evidence, and the program prints the answer the table always had.
    // The single-module version of the same question is
    // `tests/corpus/run/UserEqInsideRecord.beni`; this one is here because
    // the method and the use are in DIFFERENT modules, so the part is an
    // `ext` target and the import is the one S4 built.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Id.beni",
        \\pub type Id
        \\    = Id Int Int
        \\
        \\
        \\pub eq : Id, Id -> Bool
        \\eq a b =
        \\    case a of
        \\        Id majorA _ ->
        \\            case b of
        \\                Id majorB _ ->
        \\                    majorA == majorB
        \\
    );
    try w.write("src/Main.beni",
        \\import Id exposing (Id)
        \\import Node exposing (Program)
        \\
        \\
        \\show : Bool -> String
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
        \\    Node.printLines
        \\        [ show ({ k = Id.Id 1 2 } == { k = Id.Id 1 99 })
        \\        ]
        \\
    );

    // The table says the record's one field is compared with `Id`'s own
    // `eq`, which is exactly the part the emitted body must call.
    // `dump` takes no `--platform`, so `Node` does not resolve and the
    // command exits 1 — the table is still printed, and it is the table
    // this scenario is about.
    const table = try w.runWith(&.{ "dump", "--stage=dispatch", "src" }, .{ .raw_diagnostics = true });
    try testing.expect(std.mem.indexOf(u8, table.stdout, "part 0 ext Id eq") != null);

    const built = try w.buildAndRun(&.{"src"});
    try testing.expectEqual(@as(u8, 0), built.build.exit_code);
    try testing.expectEqualStrings("True\n", built.program.?.stdout);

    // The emitted body is the record shape's, parameterised by the field's
    // evidence (§9.2, A.46) — one function, and the `Id$eq` that tells it
    // apart from any other `{ k : … }` passed in at the use.
    const js = try w.read("out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, js, "const Main$eq$r$k = ($m$0, $x, $y) => $m$0($x.k, $y.k);") != null);
    try testing.expect(std.mem.indexOf(u8, js, "Main$eq$r$k(Id$eq,") != null);

    // The bridge still carries what it was for: a record of PRIMITIVES has
    // no user method anywhere inside it, and the same program runs.
    try w.write("src/Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\show : Bool -> String
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
        \\    Node.printLines
        \\        [ show ({ k = 1 } == { k = 1 })
        \\        ]
        \\
    );
    const ok = try w.buildAndRun(&.{"src"});
    try testing.expectEqual(@as(u8, 0), ok.build.exit_code);
    try testing.expectEqualStrings("True\n", ok.program.?.stdout);
}

test "a list whose elements have an eq of their own calls it, across a module boundary" {
    // The wall S5 left standing, now down.
    //
    // `List a` is a `foreign type`: it has no constructors, so no module
    // derives a body for it (A.55, A.60) and §5.2's `pub foreign eq` — the
    // one written in JavaScript against the emitter's cons cells (§9.5) —
    // is what answers `xs == ys`. Until it landed the only function that
    // could was `core/Basics.js`'s structural walk, and here that walk is
    // WRONG: `Id`'s own `eq` compares the major number only, so the table
    // says `True` and the walk says `False`. The backend refused the
    // program rather than print the wrong answer (A.51).
    //
    // What makes it work is the evidence: `List$eq` takes the element's own
    // `eq` as the hidden leading argument of §8.1, and `Main` hands it
    // `Id$eq` across the module boundary. `run/ListElementEq.beni` is the
    // single-module half; this is the one that crosses a file.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Id.beni",
        \\pub type Id
        \\    = Id Int Int
        \\
        \\
        \\pub eq : Id, Id -> Bool
        \\eq a b =
        \\    case a of
        \\        Id majorA _ ->
        \\            case b of
        \\                Id majorB _ ->
        \\                    majorA == majorB
        \\
    );
    try w.write("src/Main.beni",
        \\import Id exposing (Id)
        \\import Node exposing (Program)
        \\
        \\
        \\pub sameIds : List Id, List Id -> Bool
        \\sameIds a b =
        \\    a == b
        \\
        \\
        \\show : Bool -> String
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
        \\    Node.printLines
        \\        [ show (sameIds [ Id.Id 1 2 ] [ Id.Id 1 99 ])
        \\        , show (sameIds [ Id.Id 1 2 ] [ Id.Id 7 2 ])
        \\        ]
        \\
    );

    const built = try w.buildAndRun(&.{"src"});
    try testing.expectEqual(@as(u8, 0), built.build.exit_code);
    try testing.expectEqual(@as(usize, 0), built.build.diagnostics.len);
    // `Id 1 2` and `Id 1 99` share a major number, so `Id`'s own `eq` says
    // they are equal and the structural walk would have said they are not.
    try testing.expectEqualStrings("True\nFalse\n", built.program.?.stdout);
    // The evidence crosses the boundary by name: `Main` imports `Id$eq`
    // from `Id.mjs` and hands it to `List$eq`.
    const main_js = try w.read("out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, main_js, "List$eq(Id$eq,") != null);

    // `List Int` needs no user method, and its evidence is the primitive
    // comparator of §9.1 passed by name.
    try w.write("src/Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\show : Bool -> String
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
        \\    Node.printLines
        \\        [ show ([ 1, 2 ] == [ 1, 2 ])
        \\        ]
        \\
    );
    const ok = try w.buildAndRun(&.{"src"});
    try testing.expectEqual(@as(u8, 0), ok.build.exit_code);
    try testing.expectEqualStrings("True\n", ok.program.?.stdout);
}

test "a constrained value in a part position is handed its own evidence" {
    // §7.1's amendment, and the run that proves it (A.64).
    //
    // `Lib.eq` carries a `where` clause, so §8.1 gives it one hidden
    // leading evidence parameter: `Lib$eq` is `($m$0, x, y)`. §7.1's
    // `parts` tree had no range in which to say what that `$m$0` is — a
    // `Target.ext` carried none — so the record shape's derived function
    // was handed the bare name and called it with two arguments. Build
    // exit 0, `TypeError: Cannot read properties of undefined` at run
    // time, which is the one outcome `backend.md` §1 forbids; S5 refused
    // the program instead, which was honest and not enough.
    //
    // A `Target.ext` now carries a `parts` range of its own, filled from
    // the same rule `derived` uses: one target per constrained type
    // parameter, in the canonical order of §7.2. The record's field is
    // `ext Lib eq` with `primitive strict_eq` under it, and the emitted
    // call passes that as `$m$0`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Lib.beni",
        \\pub type Wrap a
        \\    = Wrap a
        \\
        \\
        \\pub eq : Wrap a, Wrap a -> Bool where a.eq : a, a -> Bool
        \\eq x y =
        \\    case x of
        \\        Wrap a ->
        \\            case y of
        \\                Wrap b ->
        \\                    a == b
        \\
    );
    try w.write("src/Main.beni",
        \\import Lib exposing (Wrap)
        \\import Node exposing (Program)
        \\
        \\
        \\show : Bool -> String
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
        \\    Node.printLines
        \\        [ show ({ k = Lib.Wrap 1 } == { k = Lib.Wrap 1 })
        \\        ]
        \\
    );

    // The table names it: the record's one field is `ext Lib eq`, and that
    // `ext` is a value with evidence of its own — printed underneath it.
    const table = try w.runWith(&.{ "dump", "--stage=dispatch", "src" }, .{ .raw_diagnostics = true });
    const at = std.mem.indexOf(u8, table.stdout, "part 0 ext Lib eq");
    try testing.expect(at != null);
    try testing.expect(std.mem.startsWith(u8, table.stdout[at.? + "part 0 ext Lib eq\n".len ..], "      part 0 primitive strict_eq"));

    const built = try w.buildAndRun(&.{"src"});
    try testing.expectEqual(@as(u8, 0), built.build.exit_code);
    try testing.expectEqual(@as(usize, 0), built.build.diagnostics.len);
    try testing.expectEqualStrings("True\n", built.program.?.stdout);
    // And the call passes the evidence: `Lib$eq` is reached through the
    // eta-expansion of §8.2 with its `$m$0` bound, not by bare name.
    const main_js = try w.read("out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, main_js, "Lib$eq(Main$eq$prim,") != null);
}

test "a private eq wins inside its module and still lets every other module derive" {
    // §3.3 step 1 reaches exactly as far as `Interface` does, and the eager
    // pass has to use the same ruler.
    //
    // `Ids.eq` is NOT `pub`. Inside `Ids` it wins — `sameMajor` compares
    // the major number only. Outside it, `Interface.findValue` maps only
    // the `pub` entries, so `Main` cannot reach it at all and derives over
    // `Id`'s shape instead, naming `Ids$Id$$eq` in `Ids` by §8.5.
    //
    // The eager pass excluded the row on ANY declaration of the name,
    // `pub` or not, so `Ids` wrote no such function: the build exited 0 and
    // emitted `import { Ids$Id$$eq } from "./Ids.mjs"` against a module
    // that exported no such name — `SyntaxError` at load, before a line of
    // the program ran. Both answers are printed here, because a fix that
    // wrote the row by making the private value invisible everywhere would
    // pass with only one of them.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Ids.beni",
        \\pub type Id
        \\    = Id Int Int
        \\
        \\
        \\eq : Id, Id -> Bool
        \\eq a b =
        \\    case a of
        \\        Id majorA _ ->
        \\            case b of
        \\                Id majorB _ ->
        \\                    majorA == majorB
        \\
        \\
        \\pub sameMajor : Id, Id -> Bool
        \\sameMajor a b =
        \\    a == b
        \\
    );
    try w.write("src/Main.beni",
        \\import Ids exposing (Id)
        \\import Node exposing (Program)
        \\
        \\
        \\show : Bool -> String
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
        \\    Node.printLines
        \\        [ show (Ids.sameMajor (Ids.Id 3 4) (Ids.Id 3 99))
        \\        , show ({ k = Ids.Id 3 4 } == { k = Ids.Id 3 99 })
        \\        ]
        \\
    );

    const built = try w.buildAndRun(&.{"src"});
    try testing.expectEqual(@as(u8, 0), built.build.exit_code);
    // The private `eq` inside `Ids`; the derived shape outside it.
    try testing.expectEqualStrings("True\nFalse\n", built.program.?.stdout);

    // And the name the importer reaches for is the one the declaring module
    // wrote, which is the half that used to be missing.
    const ids = try w.read("out/Ids.mjs");
    try testing.expect(std.mem.indexOf(u8, ids, "const Ids$Id$$eq = ") != null);
    try testing.expect(std.mem.indexOf(u8, ids, "export { Ids$Id$$eq,") != null);
    // And `Ids$Id$$compare` is NOT there, though derivation wrote it: the
    // program compares an `Id` for equality and never orders one, so
    // `backend.md` §9 drops the row and its export with it. The export list
    // shrinks to exactly the surviving names it used to hold (§5).
    try testing.expect(std.mem.indexOf(u8, ids, "Ids$Id$$compare") == null);
    const main = try w.read("out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, main, "Ids$Id$$eq") != null);
    try testing.expect(std.mem.indexOf(u8, main, "from \"./Ids.mjs\";") != null);
}

test "core/Basics carries the derived rows §3.2's table asks it for" {
    // §3.2's table is consulted BEFORE §1.2's module rule, and `deriveOne`
    // has to consult it in the same order.
    //
    // `core/Basics.beni` declares `Bool`, `Order` and `Never` and also
    // declares a `pub foreign eq` and a `pub compare` of its own — which is
    // exactly why the table exists (§3.2's opening paragraph). Asking
    // §3.3's module rule first let those two values suppress every row the
    // table asks Basics for, so the module printed no `derived` line at all
    // while every other module's `<` on an `Order` named
    // `ext_derived Basics.Order compare` (A.47): a target naming a row that
    // was not there.
    //
    // The real `core/`, not a copy: a copy would drift from the package the
    // binary embeds, and the rows are a claim about that package.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const r = try w.runWith(
        &.{ "dump", "--stage=dispatch", "--core", "core/Basics.beni" },
        .{ .raw_diagnostics = true, .cwd = .inherit },
    );
    try testing.expectEqual(@as(u8, 0), r.exit_code);

    // `Order`'s `compare` — alphabetic tag order is not `LT < EQ < GT`, so
    // this one cannot be `strict_eq`'s partner and has to be derived.
    try testing.expect(std.mem.indexOf(u8, r.stdout, "compare Basics.Order") != null);
    // `Never`'s two, which §3.2 gives no primitive at all.
    try testing.expect(std.mem.indexOf(u8, r.stdout, "eq Basics.Never") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "compare Basics.Never") != null);
    // And NOT `Order`'s `eq`, nor `Bool`'s pair: an all-nullary type is a
    // bare tag string and `Bool` is a JavaScript boolean, so the table
    // answers `primitive` and a primitive is not a function anyone emits
    // (A.18, §3.2).
    try testing.expect(std.mem.indexOf(u8, r.stdout, "eq Basics.Order") == null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Basics.Bool") == null);

    // And the rows are EMITTED, which is the half a table alone cannot
    // show: a target naming a function no module writes is exit 0 and a
    // `ReferenceError` at load. `Order`'s `compare` reads its `$$order`
    // table, so the table has to be there too, and ahead of it (§8.5).
    //
    // **The program has to ORDER two `Order`s for that to be observable**,
    // and since `backend.md` §9 that is a fact about this test and not a
    // detail: an empty `main` used to ship every row core derived, and now
    // ships none of them. `compare 1 2 < compare 3 3` is `LT < EQ`, which
    // is exactly the comparison §9.4's table exists for — alphabetically
    // `EQ < GT < LT`, so a `compare` that did not read the table would
    // answer `False`.
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\show : Bool -> String
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
        \\    Node.printLines [ show (compare 1 2 < compare 3 3) ]
        \\
    );
    const built = try w.buildAndRun(&.{"Main.beni"});
    try testing.expectEqual(@as(u8, 0), built.build.exit_code);
    try testing.expectEqualStrings("True\n", built.program.?.stdout);
    const basics = try w.read("out/core/Basics.mjs");
    const table = std.mem.indexOf(u8, basics, "const Basics$Order$$order = ");
    const compare = std.mem.indexOf(u8, basics, "const Basics$Order$$compare = ");
    try testing.expect(table != null);
    try testing.expect(compare != null);
    try testing.expect(table.? < compare.?);
    // `Order`'s `eq` is `===` at the use, so no module writes a function
    // for it (A.18).
    try testing.expect(std.mem.indexOf(u8, basics, "Basics$Order$$eq") == null);
    // `Never`'s two rows are in the TABLE — the first half of this test
    // reads them straight out of `dump --stage=dispatch` — and no program
    // can ever reach them, because `Never` has no values to compare. So
    // they are the purest case of what §9 removes, and they are not here.
    try testing.expect(std.mem.indexOf(u8, basics, "Basics$Never$$compare") == null);
    try testing.expect(std.mem.indexOf(u8, basics, "Basics$Never$$eq") == null);
}

test "a derived method of a submodule's namesake type does not collide with its values" {
    // §8.5's printed name is `<module path with dots as $>$<base>`, and the
    // synthesised nominal base has to be a base no module path can spell.
    //
    // Module `Shapes` declares `pub type Box`, so its derived `eq` is a
    // value of `Shapes`. Module `Shapes.Box` declares a `pub eq`, so that
    // is a value of `Shapes.Box`. With the base `Box$eq` both print
    // `Shapes$Box$eq`, and a module importing both emits two `import`s of
    // one name: `SyntaxError: Identifier 'Shapes$Box$eq' has already been
    // declared`, after a build that exited 0.
    //
    // The double separator is what fixes it. `Shapes$Box$$eq` has an empty
    // segment between its two `$`, which no module path has and no beni
    // identifier can contain, so the synthesised namespace and the module
    // namespace cannot meet.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Shapes.beni",
        \\pub type Box
        \\    = Box Int
        \\
    );
    try w.write("src/Shapes/Box.beni",
        \\pub eq : Int, Int -> Bool
        \\eq a b =
        \\    a == b
        \\
    );
    try w.write("src/Main.beni",
        \\import Node exposing (Program)
        \\import Shapes exposing (Box)
        \\import Shapes.Box
        \\
        \\
        \\show : Bool -> String
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
        \\    Node.printLines
        \\        [ show (Shapes.Box 1 == Shapes.Box 1)
        \\        , show (Shapes.Box.eq 1 1)
        \\        ]
        \\
    );

    const built = try w.buildAndRun(&.{"src"});
    try testing.expectEqual(@as(u8, 0), built.build.exit_code);
    try testing.expectEqualStrings("True\nTrue\n", built.program.?.stdout);

    // Two imports, two names, one statement each.
    const main = try w.read("out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, main, "import { Shapes$Box$$eq } from \"./Shapes.mjs\";") != null);
    try testing.expect(std.mem.indexOf(u8, main, "import { Shapes$Box$eq } from \"./Shapes/Box.mjs\";") != null);
}

test "a type that is not pub still exports the method another module derives for it" {
    // A PIN, not a regression: this passes on `c63ae48` too. It is here
    // because `Lower.exports` emits a nominal derived row whether or not
    // the type is `pub`, which reads like a leak until you have this
    // program in front of you.
    //
    // `Wrapped` is private to `Hidden`, so `Main` cannot name it — and
    // still holds one, because `Solve.targetFor` reaches a nominal type
    // through the VALUE's type and never through a written name. `Main`'s
    // `==` therefore derives and names `Hidden$Wrapped$$eq`, a function
    // only `Hidden` may write (§8.5: an opaque type's constructors are not
    // readable anywhere else). Exporting on `is_pub` would emit an import
    // of a name the declaring module kept to itself.
    //
    // What crosses the boundary is the METHOD, not the type: `Main` still
    // cannot write `Wrapped` in an annotation.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Hidden.beni",
        \\type Wrapped
        \\    = Wrapped Int
        \\
        \\
        \\pub wrap : Int -> Wrapped
        \\wrap n =
        \\    Wrapped n
        \\
    );
    try w.write("src/Main.beni",
        \\import Hidden
        \\import Node exposing (Program)
        \\
        \\
        \\show : Bool -> String
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
        \\    Node.printLines
        \\        [ show (Hidden.wrap 1 == Hidden.wrap 1)
        \\        , show (Hidden.wrap 1 == Hidden.wrap 2)
        \\        ]
        \\
    );

    const built = try w.buildAndRun(&.{"src"});
    try testing.expectEqual(@as(u8, 0), built.build.exit_code);
    try testing.expectEqualStrings("True\nFalse\n", built.program.?.stdout);
    const hidden = try w.read("out/Hidden.mjs");
    try testing.expect(std.mem.indexOf(u8, hidden, "export { Hidden$Wrapped$$eq,") != null);
    // `Hidden$Wrapped$$compare` was derived as eagerly as its `eq` and is
    // gone: nothing orders a `Wrapped` (`backend.md` §9). What the pin is
    // about is unchanged — the surviving row is exported although its type
    // is not `pub`.
    try testing.expect(std.mem.indexOf(u8, hidden, "Hidden$Wrapped$$compare") == null);
}

test "a pub foreign with a where clause takes its evidence in front of its own arguments" {
    // static-dispatch-spike.md §5.2 and A.7: a `pub foreign` may carry a `where` clause, and its
    // sibling export's arity is then EVIDENCE COUNT + DECLARED ARITY. That
    // rule is documented and not enforced — `boundary.md` §4's two automated
    // checks are export coverage and import coverage
    // (`src/js/Sibling.zig:1-33`) and neither looks at arity, and adding one
    // needs a JavaScript parser, which is the dependency the wall exists to
    // avoid. A.7's own amendment records that as a widening of the `foreign`
    // surface against CLAUDE.md rule 6.
    //
    // So this scenario is what stands in for the missing check: it pins that
    // the CALLER's half of the convention is real, by writing the sibling to
    // the arity A.7 documents and running it. `Prog.twice` is declared with
    // two beni parameters and one constraint, so its export takes three, and
    // the hidden one comes FIRST (§8.1, §8.2). A backend that passed the
    // evidence last, or not at all, would bind `Main$scale` to `n` and print
    // `NaN` rather than failing — which is exactly why it is run and not
    // merely inspected.
    //
    // It needs a platform of its own because only a platform package may
    // write `foreign` at all (`boundary.md` §2, CLAUDE.md rule 6), and the
    // shipped one has no constrained value to borrow.
    //
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("myplat/beni.json",
        \\{ "platform": true, "name": "mine", "program": "Prog.Program", "runtime": "run.js" }
    );
    try w.write("myplat/Prog.beni",
        \\pub foreign type Program
        \\
        \\
        \\pub foreign say : String -> Program
        \\
        \\
        \\pub foreign twice : a, Int -> a
        \\    where a.scale : a, Int -> a
        \\
    );
    // One export per `foreign` declaration, under the same name
    // (`boundary.md` §4) — and `twice` takes three arguments for the two it
    // declares, which is the whole of A.7.
    try w.write("myplat/Prog.js",
        \\export const say = (line) => ({ out: `${line}\n` });
        \\
        \\export const twice = ($m$0, x, n) => $m$0($m$0(x, n), n);
        \\
    );
    try w.write("myplat/run.js",
        \\import process from "node:process";
        \\
        \\export const run = (program) => {
        \\  process.stdout.write(program.out);
        \\};
        \\
    );
    try w.write("Main.beni",
        \\import Prog exposing (Program)
        \\import String
        \\
        \\
        \\pub type Metre
        \\    = Metre Int
        \\
        \\
        \\pub scale : Metre, Int -> Metre
        \\scale m factor =
        \\    case m of
        \\        Metre n ->
        \\            Metre (n * factor)
        \\
        \\
        \\width : Metre -> Int
        \\width m =
        \\    case m of
        \\        Metre n ->
        \\            n
        \\
        \\
        \\main : Program
        \\main =
        \\    Prog.say (String.fromInt (width (Prog.twice (Metre 1) 3)))
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.runWith(&.{ "build", "--platform=./myplat", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    if (built.exit_code != 0) {
        std.debug.print("build failed\n--- stderr ---\n{s}\n", .{built.stderr});
        return error.BuildFailed;
    }
    const main_js = try w.read("out/Main.mjs");
    try testing.expect(std.mem.indexOf(u8, main_js, "Prog$twice(Main$scale,") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY STATE                            │
    // └─────────────────────────────────────────┘
    // 1 * 3 * 3. `NaN` is what a dropped or misplaced evidence argument
    // prints, and it is the failure this scenario exists to catch.
    const program = try w.node("out/main.mjs");
    try testing.expectEqualStrings("9\n", program.stdout);
}

test "the dispatch table is byte-identical at --jobs=1 and --jobs=8" {
    // static-dispatch-spike.md §7.3: no symbol ids, no positions and no
    // module indices, and `derived` sorted by emitted name text and `sites`
    // by `(inst, evidence_index)` BEFORE anything indexes them (§7.1,
    // A.29). The table is what S4 and S5 lower from, so a byte that moves
    // with `--jobs` is a program that changes with `--jobs`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeRecordShapes(&w);

    const runs = [4][]const u8{ "--jobs=1", "--jobs=8", "--jobs=1", "--jobs=8" };
    var out: [4][]const u8 = undefined;
    for (&out, runs) |*slot, jobs| {
        const r = try w.runWith(&.{ "dump", "--stage=dispatch", jobs, "src" }, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        slot.* = r.stdout;
    }
    for (out[1..]) |other| try testing.expectEqualStrings(out[0], other);

    // The table really does hold what the assertion is about.
    try testing.expect(std.mem.indexOf(u8, out[0], "  site ") != null);
    try testing.expect(std.mem.indexOf(u8, out[0], "  derived ") != null);
    try testing.expect(std.mem.indexOf(u8, out[0], "    evidence 0 ") != null);
}

test "a constraint that rode out on an inferred interface is reported without --explain, and does not fail the build" {
    // static-dispatch-spike.md §10.9 and §6.4: an unannotated `pub`
    // declaration's inferred scheme carries the constraints its body raised,
    // and that scheme IS the module's interface — so a body edit can change
    // what every importer is checked against (report 18 §2.3). The warning
    // exists so plan §7's M3 churn measurement has something to count, and
    // since A.83 it is ON BY DEFAULT, so the author hears about the suffix
    // when they create it rather than only under a flag.
    //
    // Both halves are asserted: the message is a `warning`, and the exit
    // code stays 0. `diagnostic.Severity` gains no third value and a warning
    // cannot change the exit code (frontend.md §1), so this can never turn a
    // passing build into a failing one (A.10, A.83).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\pub bigger a b =
        \\    a < b
        \\
        \\
        \\pub annotated : Int, Int -> Bool
        \\annotated a b =
        \\    a < b
        \\
    );

    const r = try w.run(&.{ "check", "Main.beni" });

    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const d = r.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.ambiguous_method_receiver, d.code);
    try testing.expectEqual(diagnostic.Severity.warning, d.severity);
    try testing.expectEqualStrings("CONSTRAINT IN AN INFERRED INTERFACE", d.title);
    // The whole scheme, `where` clause included, is what the reader has to
    // see: it is the thing that changes.
    try testing.expect(std.mem.indexOf(u8, d.message, "a, a -> Bool where a.compare : a, a -> Order") != null);
    // `annotated` pins its type, so it carries no constraint and is not
    // reported — which is the hint the message gives.
    try testing.expect(std.mem.indexOf(u8, d.message, "annotated") == null);

    // `--explain` is still accepted and now governs nothing: same exit code,
    // same diagnostics, byte for byte. The flag is kept rather than removed
    // so nothing scripted against it starts exiting 2 (A.83).
    const explained = try w.run(&.{ "check", "--explain", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), explained.exit_code);
    try testing.expectEqualStrings(r.stderr, explained.stderr);

    // `dump` is not one of the two subcommands that emit informational
    // diagnostics, so the same file dumps silently — a dump's stderr stays
    // a channel for problems with the input, not advice about it.
    const dumped = try w.run(&.{ "dump", "--stage=interface", "Main.beni" });
    try testing.expectEqual(@as(u8, 0), dumped.exit_code);
    try testing.expectEqual(@as(usize, 0), dumped.diagnostics.len);

    // `build` is the other subcommand that does act on it, and a warning
    // still writes the program: the exit code is 0 and the module is on
    // disk. This is the half of A.10 the decision could have broken.
    try w.write("App.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\pub bigger a b =
        \\    a < b
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.print "ok"
        \\
    );
    const built = try w.run(&.{ "build", "--platform=node", "--out=out", "App.beni" });
    try testing.expectEqual(@as(u8, 0), built.exit_code);
    try testing.expectEqual(@as(usize, 1), built.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.ambiguous_method_receiver, built.diagnostics[0].code);
    try testing.expect(w.exists("out/App.mjs"));
}

test "a build that warns and then fails in the emit phase prints one diagnostics array, not two" {
    // `beni build` produces diagnostics in two waves: the check `run`'s, and
    // the emit phase's, which runs after `run` has returned because it must
    // not run at all when the check failed (`Session.renderLate`). Rendering
    // both would put TWO JSON arrays on one stream, which is not the format
    // (frontend.md §1.1) — so `build` holds the first wave back and renders
    // once, sorted together.
    //
    // Until A.83 the two waves could not overlap: a run that reached the
    // emit phase had produced nothing at all, and `build` asserted exactly
    // that. The first `warning` the compiler emits by default is what makes
    // them overlap, and the assertion was reachable from a program whose
    // only faults are a missing `main` and an unannotated `pub` declaration.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\pub bigger a b =
        \\    a < b
        \\
    );

    // `w.run` parses stderr as ONE array and fails the test if it is not.
    const r = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });

    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 2), r.diagnostics.len);
    // Sorted by the schema's comparator over BOTH waves, so the emit
    // phase's `missing_main` at 1:1 precedes the checker's warning at 1:5.
    try testing.expectEqual(diagnostic.Code.missing_main, r.diagnostics[0].code);
    try testing.expectEqual(diagnostic.Severity.@"error", r.diagnostics[0].severity);
    try testing.expectEqual(diagnostic.Code.ambiguous_method_receiver, r.diagnostics[1].code);
    try testing.expectEqual(diagnostic.Severity.warning, r.diagnostics[1].severity);

    // A failed build writes nothing.
    try testing.expect(!w.exists("out/Main.mjs"));
}

test "the inferred-interface warning is not raised about a package the author does not own" {
    // static-dispatch-spike.md §10 preamble, A.83 decision 2. `core/` is
    // compiled into the binary and a platform package is somebody else's
    // dependency (boundary.md §2): nobody can annotate `Dict.foldl` from
    // their own project, so a warning about it is noise they cannot act on.
    // The warning is therefore raised only for a module of the ROOT package.
    //
    // The dependency here is a core package of one module, supplied with
    // `--core-root`, carrying exactly the shape §10.9 is about: an
    // unannotated `pub` declaration whose inferred scheme has a constraint.
    // It must stay silent while the app's own copy of the same shape does
    // not. No literal and no operator appears in either, so the stand-in
    // core needs no `Basics` and the two declarations are the only things
    // in the run that can raise anything.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("dep/Dep.beni",
        \\pub relay x =
        \\    ( x.ping x, x )
        \\
    );
    try w.write("src/Main.beni",
        \\pub mine x =
        \\    ( x.pong x, x )
        \\
    );

    const r = try w.run(&.{ "check", "--core-root=dep", "--jobs=1", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const d = r.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.ambiguous_method_receiver, d.code);
    try testing.expectEqual(diagnostic.Severity.warning, d.severity);
    try testing.expectEqualStrings("src/Main.beni", d.span.file);
    try testing.expect(std.mem.indexOf(u8, d.message, "`mine`") != null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The dependency really was checked and really does carry the shape —
    // otherwise the silence above would be the silence of a module nobody
    // looked at. Its interface shows the promoted `where` suffix.
    const iface = try w.run(&.{ "dump", "--stage=interface", "--core-root=dep", "--jobs=1", "dep/Dep.beni" });
    try testing.expectEqual(@as(u8, 0), iface.exit_code);
    try testing.expect(std.mem.indexOf(u8, iface.stdout, "where a.ping") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "relay") == null);
}

test "dump --stage=interface prints each value's scheme, and <error> for one that failed" {
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni",
        \\pub good : Int -> Int
        \\good n =
        \\    n
        \\
        \\
        \\pub bad =
        \\    "no" + 1
        \\
        \\
        \\pub poly x =
        \\    ( x, x )
        \\
    );

    const r = try w.runWith(&.{ "dump", "--stage=interface", "src/Main.beni" }, .{ .raw_diagnostics = true });

    // The interface is the product and a module with type errors still has
    // one (checker.md §7) — it is printed in full. The exit code says an
    // `error` was printed all the same (`frontend.md` §1).
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqualStrings(
        \\module Main
        \\  value bad : <error>
        \\  value good : Int -> Int
        \\  value poly : a -> ( a, a )
        \\
    , r.stdout);
}

// ---------------------------------------------------------------------------
// M2d — the interface RECORD, not a view of it (checker.md §7,
// fast-compiler.md §8.1)
//
// Every other determinism test in this file compares a printer's output,
// and the two printers that show an interface both re-sort by name text —
// so neither can see whether the BYTES of `terms`, `extra` and the
// quantifier blocks depend on which worker interned which file. §8.1 has M4
// hashing exactly those bytes, so the property has to be assertable about
// them. `dump --stage=raw` exists for this and for nothing else.
// ---------------------------------------------------------------------------

/// A project whose field, parameter and value names are deliberately in a
/// different order by TEXT than by declaration, spread over enough modules
/// that the workers interleave: the record's byte layout used to follow the
/// store's own order, which is by symbol id.
fn writeRecordShapes(w: *World) !void {
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

test "the interface record is byte-identical at --jobs=1 and --jobs=8" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writeRecordShapes(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // Twice each and alternating, because the thing that varies is which
    // worker happened to take which file — a property of one run, not of a
    // flag.
    const runs = [4][]const u8{ "--jobs=1", "--jobs=8", "--jobs=1", "--jobs=8" };
    var raw: [4][]const u8 = undefined;
    for (&raw, runs) |*out, jobs| {
        const r = try w.runWith(&.{ "dump", "--stage=raw", jobs, "src" }, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        try testing.expectEqualStrings("", r.stderr);
        out.* = r.stdout;
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Field by field: the raw dump prints one record field per line, so a
    // difference in term order, in the `extra` words or in the quantifier
    // numbering names itself.
    for (raw[1..]) |other| try testing.expectEqualStrings(raw[0], other);

    // The record really does hold what the assertion is about: record
    // terms with their field names, and quantifier blocks with theirs.
    try testing.expect(std.mem.indexOf(u8, raw[0], "term ") != null);
    try testing.expect(std.mem.indexOf(u8, raw[0], "  field alpha term=") != null);
    try testing.expect(std.mem.indexOf(u8, raw[0], "ctor 0 ") != null);
    // And the `where` blocks of static-dispatch-spike.md §6.5, which are
    // the bytes S3 added to the record M4 will hash. They are written
    // SORTED BY NAME TEXT, never by symbol id, for exactly the reason the
    // record's fields are — so `compare` precedes `eq` here whatever order
    // the workers interned them in, and both an annotated `where` clause
    // (`pick`) and an INFERRED one (`near`) are present.
    try testing.expect(std.mem.indexOf(u8, raw[0], "    where compare term=") != null);
    try testing.expect(std.mem.indexOf(u8, raw[0], "    where eq term=") != null);
    try testing.expect(std.mem.indexOf(u8, raw[0], "    where close term=") != null);
}

test "a record's fields are laid out in the record by name text, not by symbol id" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Declared zulu, alpha, middle, bravo — four orders in one: the source
    // order, the alphabetical one, and (because the module is lexed left to
    // right) the symbol-id one, which equals the source order here.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\pub make : Int -> { zulu : Int, alpha : Int, middle : Int, bravo : Int }
        \\make n =
        \\    { zulu = n, alpha = n, middle = n, bravo = n }
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "dump", "--stage=raw", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    const alpha = std.mem.indexOf(u8, r.stdout, "  field alpha term=").?;
    const bravo = std.mem.indexOf(u8, r.stdout, "  field bravo term=").?;
    const middle = std.mem.indexOf(u8, r.stdout, "  field middle term=").?;
    const zulu = std.mem.indexOf(u8, r.stdout, "  field zulu term=").?;
    try testing.expect(alpha < bravo);
    try testing.expect(bravo < middle);
    try testing.expect(middle < zulu);
}

/// One module's block of a whole-root `dump --stage=raw`: its `module <name>`
/// line up to the next one, or to the end.
fn rawSection(dump: []const u8, module: []const u8) ![]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "module {s}\n", .{module});
    const at = std.mem.indexOf(u8, dump, needle) orelse return error.ModuleNotInDump;
    const rest = dump[at + needle.len ..];
    const end = std.mem.indexOf(u8, rest, "\nmodule ") orelse return dump[at..];
    return dump[at .. at + needle.len + end + 1];
}

/// The three modules of the purity scenario below. `Zeta` is the module
/// under observation: it imports `Mid` and never mentions `Alpha`.
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

test "a type declared elsewhere leaves an untouched module's interface bytes alone" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `fast-compiler.md` §8.1's firewall recompiles a dependent only when
    // its dependency's interface CHANGED, so an interface record must be a
    // pure function of its module's source and its imports' interfaces
    // (checker.md §7). It was not: `Term.app` and `Term.alias` spent `lhs`
    // on a session `TypeStore.TypeId`, a whole-program dense index assigned
    // by walking every module in `Graph.Index` order — so one new type
    // declaration anywhere earlier in sorted-path order rewrote the bytes of
    // a module that did not import it, and the firewall would have fired on
    // approximately every type-introducing edit.
    //
    // The `--jobs` determinism tests cannot see this (it is not a scheduling
    // difference) and `bench/churn.sh` cannot either (every one of its edit
    // classes edits the declaration whose dump it diffs). This is the test
    // that can: four edit classes, none of them in `Zeta`, and `Zeta`'s
    // bytes must not move for any of them.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writePurityProject(&w);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const base = try w.runWith(&.{ "dump", "--stage=raw", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), base.exit_code);
    const before = try rawSection(base.stdout, "Zeta");

    // The edits are cumulative, so every step is also still holding the
    // previous one's change: (a) a `pub` type in an alphabetically earlier
    // module `Zeta` does not import; (b) a PRIVATE type in the same module,
    // which numbering leaked just as loudly as a public one; (c) a whole new
    // file containing a type; (d) a type added to `Mid`, which `Zeta` DOES
    // import but whose new type `Zeta`'s interface never mentions.
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

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for (edits) |e| {
        try w.write(e.path, e.source);
        const r = try w.runWith(&.{ "dump", "--stage=raw", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        const after = rawSection(r.stdout, "Zeta") catch |err| {
            std.debug.print("after '{s}': {t}\n", .{ e.what, err });
            return err;
        };
        testing.expectEqualStrings(before, after) catch |err| {
            std.debug.print("Zeta's interface moved after adding {s}\n", .{e.what});
            return err;
        };
    }

    // The record really does name the types it uses, and it names them by
    // where they are DECLARED rather than by a session index: `Int` from
    // core, `Tag` from the module `Zeta` imports, `Pair` from `Zeta`
    // itself. Without this the assertions above would also pass on a record
    // that had stopped mentioning any type at all.
    try testing.expect(std.mem.indexOf(u8, before, "typeref 0 core Basics.Int\n") != null);
    try testing.expect(std.mem.indexOf(u8, before, " app Mid.Tag\n") != null);
    try testing.expect(std.mem.indexOf(u8, before, " app Zeta.Pair\n") != null);
}

test "a change to a type a module's interface DOES mention moves its bytes" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The converse of the test above, and the reason it is not vacuous: the
    // firewall has to fire when the interface really changed. Three edits
    // that reach `Zeta`'s own record — renaming the type it imports,
    // changing the arity of the type it declares, and adding a constructor
    // to a type whose constructors are exported (which moves the DECLARING
    // module's record).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try writePurityProject(&w);

    const base = try w.runWith(&.{ "dump", "--stage=raw", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), base.exit_code);
    const zeta_before = try rawSection(base.stdout, "Zeta");
    const mid_before = try rawSection(base.stdout, "Mid");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY: the imported type is renamed │
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
    const renamed = try w.runWith(&.{ "dump", "--stage=raw", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), renamed.exit_code);
    try testing.expect(!std.mem.eql(u8, zeta_before, try rawSection(renamed.stdout, "Zeta")));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY: a constructor is added │
    // └─────────────────────────────────────────┘
    try w.write("src/Mid.beni",
        \\pub type Label
        \\    = Tag
        \\    | Second
        \\
        \\
        \\pub type Other
        \\    = Other
        \\
    );
    const ctor = try w.runWith(&.{ "dump", "--stage=raw", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), ctor.exit_code);
    try testing.expect(!std.mem.eql(u8, mid_before, try rawSection(ctor.stdout, "Mid")));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE / VERIFY: the local type's arity │
    // └─────────────────────────────────────────┘
    try w.write("src/Zeta.beni",
        \\import Mid exposing (Label)
        \\
        \\
        \\pub type Pair a b
        \\    = Pair a b
        \\
        \\
        \\pub mk : Int, Label -> Pair Label Label
        \\mk _ t =
        \\    Pair t t
        \\
    );
    const arity = try w.runWith(&.{ "dump", "--stage=raw", "--jobs=1", "src" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), arity.exit_code);
    try testing.expect(!std.mem.eql(u8, zeta_before, try rawSection(arity.stdout, "Zeta")));
}

test "an imported constructor is instantiated from the interface, argument types and all" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The firewall of fast-compiler.md §8.1: a dependent may read its
    // dependency's INTERFACE and nothing else, so a constructor's argument
    // types have to be in the record (checker.md §7's `arg_terms`).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Shapes.beni",
        \\pub type Box a b
        \\    = Box a b
        \\    | Empty
        \\
    );
    try w.write("src/Main.beni",
        \\import Shapes exposing (Box)
        \\
        \\
        \\pub wrong : Box Int String
        \\wrong =
        \\    Shapes.Box "not an Int" 1
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.type_mismatch, r.diagnostics[0].code);
    try testing.expectEqual(@as(u32, 6), r.diagnostics[0].span.start.line);

    // The record itself carries the argument terms and the owning type's
    // parameters; without them the solver would have had to open the
    // dependency's Bir and find the constructor by name.
    const raw = try w.runWith(&.{ "dump", "--stage=raw", "src/Shapes.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), raw.exit_code);
    try testing.expect(std.mem.indexOf(u8, raw.stdout, "ctor 0 Box type=0 arity=2 arg_terms=") != null);
    try testing.expect(std.mem.indexOf(u8, raw.stdout, "  arg 0 term=") != null);
    try testing.expect(std.mem.indexOf(u8, raw.stdout, "  arg 1 term=") != null);
    try testing.expect(std.mem.indexOf(u8, raw.stdout, "  param 0 kind=0 equatable=false name=a") != null);
    try testing.expect(std.mem.indexOf(u8, raw.stdout, "  param 1 kind=0 equatable=false name=b") != null);
}

test "a type nested past the checker's reading limit is reported, never silently poisoned" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The parser accepts eight times the nesting the checker reads, so
    // there is a whole band of files the front end takes happily. A type in
    // that band used to become `<error>` with no message at all — and an
    // `err` unifies with anything, so the caller below compiled clean.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "pub f : ");
    for (0..600) |_| try source.appendSlice(testing.allocator, "( ");
    try source.appendSlice(testing.allocator, "Int");
    for (0..600) |_| try source.appendSlice(testing.allocator, ", Int )");
    try source.appendSlice(testing.allocator, " -> Int\nf _ =\n    1\n");
    try w.write("src/Deep.beni", source.items);
    try w.write("src/Main.beni",
        \\import Deep
        \\
        \\
        \\pub main : Int
        \\main =
        \\    Deep.f "not a tuple"
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.nesting_too_deep, r.diagnostics[0].code);
    try testing.expectEqualStrings("NESTING TOO DEEP", r.diagnostics[0].title);
    try testing.expectEqualStrings("src/Deep.beni", r.diagnostics[0].span.file);
    try testing.expectEqualStrings(
        "This type is nested more than 512 levels deep, which is more than I can\n" ++
            "read.\n" ++
            "\n" ++
            "I gave up part way down, so I cannot check this declaration or anything\n" ++
            "that uses it. Give the inner part a `type alias` of its own and write\n" ++
            "that name here instead.\n",
        r.diagnostics[0].message,
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // One mistake, one message: the caller's argument is checked against a
    // poisoned type and stays quiet, which is the cascade rule — but the
    // poison now arrives with a message rather than instead of one.
    const raw = try w.runWith(&.{ "dump", "--stage=raw", "src/Deep.beni" }, .{ .raw_diagnostics = true });
    // The record is printed; the exit code repeats the diagnostic above.
    try testing.expectEqual(@as(u8, 1), raw.exit_code);
    try testing.expect(std.mem.indexOf(u8, raw.stdout, "value 0 f foreign=false scheme=0") != null);
    try testing.expect(std.mem.indexOf(u8, raw.stdout, "term 0 err 0 0") != null);
}

test "one level under the reading limit checks clean and publishes a real scheme" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "pub f : ");
    for (0..400) |_| try source.appendSlice(testing.allocator, "( ");
    try source.appendSlice(testing.allocator, "Int");
    for (0..400) |_| try source.appendSlice(testing.allocator, ", Int )");
    try source.appendSlice(testing.allocator, " -> Int\nf _ =\n    1\n");
    try w.write("Deep.beni", source.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Deep.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    const raw = try w.runWith(&.{ "dump", "--stage=raw", "Deep.beni" }, .{ .raw_diagnostics = true });
    try testing.expectEqual(@as(u8, 0), raw.exit_code);
    try testing.expect(std.mem.indexOf(u8, raw.stdout, "term 0 app ") != null);
}

// ---------------------------------------------------------------------------
// The pattern-usefulness budget is the last guard that gave up in SILENCE
// (`checker.md` §6.6, `backend.md` §7, queue slice 14)
//
// Deciding a `case` can cost exponentially much, so the analysis spends a
// bounded amount of work on it. It used to report nothing when that ran out,
// which was harmless while the backend's `case` still had a fallback — and a
// miscompile the moment decision trees landed, because a tree carries **no
// default arm** on the strength of "the checker proved exhaustiveness". A
// `case` nobody proved anything about took the tree's last edge and printed
// the wrong answer at exit 0, with no diagnostic anywhere.
//
// `--pattern-budget=<n>` is what makes that assertable with a four-line
// module instead of the ~440-literal-branch `case` it takes to reach the
// default. The scenarios below are the pair: too little budget is a refusal,
// enough budget is the real answer, and a refused `case` writes no
// JavaScript at all.
// ---------------------------------------------------------------------------

/// Not exhaustive: nothing matches `Nothing`. Small enough that ANY budget
/// above a handful of steps decides it, so the two scenarios below differ
/// only in the flag.
const undecidable_case =
    \\pub f : Maybe Int -> Int
    \\f m =
    \\    case m of
    \\        Just n ->
    \\            n
    \\
;

test "a `case` the usefulness budget cannot decide is refused, not passed over" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("M.beni", undecidable_case);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "--pattern-budget=1", "M.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The budget is a session-wide knob, so a value this small also refuses
    // every `case` in the embedded core package. Only `M.beni`'s is this
    // scenario's, and there is exactly one of those.
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    var mine: ?diagnostic.Diagnostic = null;
    for (r.diagnostics) |candidate| {
        if (!std.mem.eql(u8, candidate.span.file, "M.beni")) continue;
        try testing.expect(mine == null);
        mine = candidate;
    }
    // The whole diagnostic, because the message is the deliverable: it has
    // to name the budget that was in force and both ways past it, or the
    // author is told "too big" and nothing else.
    const d = mine orelse return error.NoDiagnosticForTheModule;
    try testing.expectEqual(diagnostic.Code.pattern_budget_exhausted, d.code);
    try testing.expectEqual(diagnostic.Severity.@"error", d.severity);
    try testing.expectEqualStrings("CASE TOO BIG TO CHECK", d.title);
    try testing.expectEqualStrings("M.beni", d.span.file);
    try testing.expectEqual(@as(u32, 3), d.span.start.line);
    try testing.expectEqual(@as(u32, 5), d.span.start.col);
    try testing.expectEqualStrings(
        "This `case` is too big for me to prove anything about:\n" ++
            "\n" ++
            "Deciding whether a `case` covers every possibility can cost exponentially\n" ++
            "much, so I spend at most a fixed amount of work on it — 1 steps here — and\n" ++
            "this one ran out. I do not know whether a possibility is missing or a branch\n" ++
            "is unreachable, and I will not compile a `case` I could not check: the\n" ++
            "JavaScript I generate has no fallback branch to land in.\n" ++
            "\n" ++
            "Splitting the match makes it cheap, because the cost is in the COMBINATIONS:\n" ++
            "a helper function per group of constructors, or one `case` per column instead\n" ++
            "of one `case` over all of them at once.\n" ++
            "\n" ++
            "Hint: `--pattern-budget=<n>` raises the limit if the `case` really is meant\n" ++
            "to be this big.\n",
        d.message,
    );

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The refusal REPLACES the answer rather than arriving beside a
    // half-searched one. Nothing in the whole run — this module or the core
    // package, which a budget this small starves too — claims a pattern is
    // missing or redundant, because no matrix was searched far enough to
    // know either.
    for (r.diagnostics) |candidate| {
        try testing.expect(candidate.code != .missing_patterns);
        try testing.expect(candidate.code != .redundant_pattern);
    }
}

test "the same `case` with budget to spare gets the real answer instead of the refusal" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The refusal is about the BUDGET and never about the program, so the
    // same source at the default budget must say what is actually wrong —
    // and an exhaustive version of it must say nothing at all.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("M.beni", undecidable_case);
    try w.write("Ok.beni",
        \\pub f : Maybe Int -> Int
        \\f m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
        \\        Nothing ->
        \\            0
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const bad = try w.run(&.{ "check", "M.beni" });
    const good = try w.run(&.{ "check", "--pattern-budget=1000000", "Ok.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), bad.exit_code);
    try testing.expectEqual(@as(usize, 1), bad.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.missing_patterns, bad.diagnostics[0].code);

    try testing.expectEqual(@as(u8, 0), good.exit_code);
    try testing.expectEqualStrings("", good.stderr);
}

test "a `case` the checker could not decide never reaches the default-free decision tree" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The miscompile itself, at the second boundary. `name 999` matches no
    // branch; `backend.md` §7's tree has no default arm, so before this
    // slice the build exited 0 and the program printed `"seven"` — the last
    // edge's answer — for an input no branch covers.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\name : Int -> String
        \\name k =
        \\    case k of
        \\        0 ->
        \\            "zero"
        \\
        \\        7 ->
        \\            "seven"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ name 0, name 999 ]
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const starved = try w.run(&.{ "build", "--platform=node", "--out=out", "--pattern-budget=1", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), starved.exit_code);
    var refused = false;
    for (starved.diagnostics) |d| {
        if (!std.mem.eql(u8, d.span.file, "Main.beni")) continue;
        try testing.expectEqual(diagnostic.Code.pattern_budget_exhausted, d.code);
        refused = true;
    }
    try testing.expect(refused);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Nothing was written. A refused `case` is not a program that throws at
    // runtime; it is not a program at all.
    try testing.expect(!w.exists(world.entry_file));

    // And with room to think, the compiler says what is really wrong — the
    // same refusal to emit, for the honest reason.
    const decided = try w.run(&.{ "build", "--platform=node", "--out=out", "Main.beni" });
    try testing.expectEqual(@as(u8, 1), decided.exit_code);
    try testing.expectEqual(@as(usize, 1), decided.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.missing_patterns, decided.diagnostics[0].code);
    try testing.expect(!w.exists(world.entry_file));

    // The fixed program builds and runs, so the refusal is about the hole
    // and not about the shape of the `case`.
    try w.write("Main.beni",
        \\import Node exposing (Program)
        \\
        \\
        \\name : Int -> String
        \\name k =
        \\    case k of
        \\        0 ->
        \\            "zero"
        \\
        \\        7 ->
        \\            "seven"
        \\
        \\        _ ->
        \\            "other"
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines [ name 0, name 999 ]
        \\
    );
    const fixed = try w.buildAndRun(&.{"Main.beni"});
    try testing.expectEqual(@as(u8, 0), fixed.build.exit_code);
    const program = fixed.program orelse return error.BuildFailed;
    try testing.expectEqualStrings("zero\nother\n", program.stdout);
}

// ---------------------------------------------------------------------------
// A FLAT lookup table is linear, not quadratic (`checker.md` §6.6, queue
// slice 22)
//
// The budget above was measured and found to refuse ordinary code: `isUseful`
// ran every branch against the matrix of the branches above it, so a `case`
// of n literal branches cost ~1.05·n² with no nesting at all — about 214 000
// steps for 460 branches, against a default of 200 000. A lookup table is not
// an adversarial input; it is what a table-driven program looks like.
//
// `Exhaustive.Flat` makes a column of literals or nullary constructors a
// set-membership question instead of a matrix specialisation (Maranget §4),
// which is 2 steps per branch. The scenarios below assert that as a BUDGET
// the old code could not have met, and — because a fast path that is merely
// fast is a fast path that is wrong — that it still finds the redundant row
// and the missing constructors, at the right places.
// ---------------------------------------------------------------------------

/// A `case` of `count` `Int` literal branches plus a trailing wildcard.
/// `dup` repeats an earlier literal at that branch, for the redundancy half.
fn flatLiteralTable(arena: std.mem.Allocator, count: u32, dup: ?u32) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("pub name : Int -> Int\nname n =\n    case n of\n");
    for (0..count) |i| {
        const key: u32 = if (dup != null and dup.? == i) 0 else @intCast(i);
        try w.print("        {d} ->\n            {d}\n\n", .{ key, i });
    }
    try w.writeAll("        _ ->\n            0\n");
    return out.written();
}

/// A type of `count` nullary constructors and a `case` with one branch each,
/// minus the last `missing` of them.
fn flatCtorTable(arena: std.mem.Allocator, count: u32, missing: u32) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("pub type T\n    = C0\n");
    for (1..count) |i| try w.print("    | C{d}\n", .{i});
    try w.writeAll("\n\npub f : T -> Int\nf t =\n    case t of\n");
    for (0..count - missing) |i| try w.print("        C{d} ->\n            {d}\n\n", .{ i, i });
    return out.written();
}

test "a flat lookup table costs two steps a branch, not the square of the branch count" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 460 is the number the old note named as the threshold, and 2 000 is
    // there so that passing cannot be a bigger constant: 2 000 branches cost
    // 4 014 008 steps before and 4 002 now, so a budget of 6 000 decides the
    // second only if the cost is LINEAR.
    try w.write("Small.beni", try flatLiteralTable(a, 460, null));
    try w.write("Big.beni", try flatLiteralTable(a, 2000, null));
    try w.write("Ctors.beni", try flatCtorTable(a, 320, 0));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // Well under the ~214 000, ~4 000 000 and ~207 000 these used to need,
    // and enough for 2·n + the handful `simplify` spends.
    const small = try w.run(&.{ "check", "--pattern-budget=1000", "Small.beni" });
    const big = try w.run(&.{ "check", "--pattern-budget=6000", "Big.beni" });
    const ctors = try w.run(&.{ "check", "--pattern-budget=1000", "Ctors.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]world.Result{ small, big, ctors }) |r| {
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        try testing.expectEqualStrings("", r.stderr);
    }
}

test "the flat path still names the redundant branch and the missing constructors" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A fast path that is only fast is a wrong answer arriving sooner. Both
    // halves of §6.6 are asserted inside a table too big for the old code to
    // have decided at all, so the assertions are about the new path.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Branch 300 (1-based: the 301st) repeats the literal of branch 0.
    try w.write("Dup.beni", try flatLiteralTable(a, 460, 300));
    // 320 constructors, three of them with no branch.
    try w.write("Holes.beni", try flatCtorTable(a, 320, 3));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dup = try w.run(&.{ "check", "--pattern-budget=1000", "Dup.beni" });
    // A little more than the exhaustive table above: the "some alternatives
    // are missing" answer is DELEGATED to `isExhaustive`, which walks the
    // column twice to build the witnesses. 1 271 steps, against the 207 000
    // the 320 branches alone used to cost.
    const holes = try w.run(&.{ "check", "--pattern-budget=2000", "Holes.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), dup.exit_code);
    try testing.expectEqual(@as(usize, 1), dup.diagnostics.len);
    const d = dup.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.redundant_pattern, d.code);
    // The caret is under the PATTERN of the repeated branch, and the message
    // counts branches from one: three lines per branch after the three-line
    // head, so branch 301 starts at line 4 + 300·3.
    try testing.expectEqual(@as(u32, 4 + 300 * 3), d.span.start.line);
    try testing.expectEqual(@as(u32, 9), d.span.start.col);
    try testing.expect(std.mem.indexOf(u8, d.message, "The 301st pattern is redundant") != null);

    try testing.expectEqual(@as(u8, 1), holes.exit_code);
    try testing.expectEqual(@as(usize, 1), holes.diagnostics.len);
    const m = holes.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.missing_patterns, m.code);
    // The three constructors with no branch, by name and in declaration
    // order — the same witnesses the general relation builds, because the
    // fast path delegates every answer that is not "exhaustive" to it.
    try testing.expect(std.mem.indexOf(u8, m.message, "    C317\n    C318\n    C319\n") != null);
}

// ---------------------------------------------------------------------------
// A PAIR-keyed lookup table is linear too (`checker.md` §6.6, queue slice 25)
//
// Slice 22 above read one literal COLUMN and no more, so `case ( a, b ) of
// ( 1, 2 ) -> …` — a state machine's table, the most ordinary two-column code
// there is — went straight back to `isUseful`, which specialises the matrix
// above every row twice over: 2n². That met the default budget at about
// 1 580 rows, which is still a table a person writes.
//
// The key path now unwraps every single-alternative constructor (a tuple is
// one) and hashes the whole row, so the cost is one probe a branch whatever
// the key's width. The scenarios below assert that as a budget the old code
// could not have met, and — because a fast path that is merely fast is a fast
// path that is wrong — that the ANSWERS are still exact: the redundant row at
// its exact position, the missing combinations by name and in order, and a
// partial-wildcard row (the CUT, which the key path refuses to decide)
// falling back to the general relation rather than guessing.
// ---------------------------------------------------------------------------

/// A `case` on `( a, b )` of `rows` `Int` literal pairs laid out as a
/// `width`-wide grid, plus a trailing wildcard. `dup` repeats row 0's key at
/// that row, for the redundancy half; `open` writes `_` in the second column
/// at that row, for the fallback half.
fn pairLiteralTable(arena: std.mem.Allocator, rows: u32, width: u32, dup: ?u32, open: ?u32) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("pub f : Int, Int -> Int\nf a b =\n    case ( a, b ) of\n");
    for (0..rows) |i| {
        const at: u32 = @intCast(i);
        const repeat = dup != null and dup.? == at;
        const row = if (repeat) 0 else at / width;
        if (open != null and open.? == at) {
            try w.print("        ( {d}, _ ) ->\n            {d}\n\n", .{ row, i });
        } else {
            try w.print("        ( {d}, {d} ) ->\n            {d}\n\n", .{ row, if (repeat) 0 else at % width, i });
        }
    }
    try w.writeAll("        _ ->\n            0\n");
    return out.written();
}

/// Two enums of `count` constructors each, and a `case` with one branch per
/// combination in declaration order, minus the last `missing` of them.
fn pairCtorTable(arena: std.mem.Allocator, count: u32, missing: u32) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("pub type P\n    = P0\n");
    for (1..count) |i| try w.print("    | P{d}\n", .{i});
    try w.writeAll("\n\npub type Q\n    = Q0\n");
    for (1..count) |i| try w.print("    | Q{d}\n", .{i});
    try w.writeAll("\n\npub f : P, Q -> Int\nf a b =\n    case ( a, b ) of\n");
    var i: u32 = 0;
    while (i < count * count - missing) : (i += 1) {
        try w.print("        ( P{d}, Q{d} ) ->\n            {d}\n\n", .{ i / count, i % count, i });
    }
    return out.written();
}

test "a pair-keyed lookup table costs one probe a branch, not the square of the branch count" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 1 800 is the size of `check/good/PairLookupTable.beni`, chosen to sit a
    // third OVER the default budget under the old cost; 500 is there so that
    // passing cannot be a bigger constant, since the two budgets below are in
    // the same ratio as the row counts and not as their squares.
    try w.write("Small.beni", try pairLiteralTable(a, 500, 45, null, null));
    try w.write("Big.beni", try pairLiteralTable(a, 1800, 45, null, null));
    // The same key over two 40-constructor enums, every combination of them
    // and no wildcard at all: 1 580 rows of this cost 5 343 192 steps before.
    // Exhaustiveness here is the PRODUCT test — 1 600 distinct keys fill a
    // key space with 1 600 points — and it is the answer the key path is
    // allowed to give on its own, so nothing is delegated.
    try w.write("Enums.beni", try pairCtorTable(a, 40, 0));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // Against the ~0.5 M, ~6.6 M and ~5.2 M these used to need. Six steps a
    // branch: three to simplify `( 1, 2 )` and three to walk and hash it.
    const small = try w.run(&.{ "check", "--pattern-budget=4000", "Small.beni" });
    const big = try w.run(&.{ "check", "--pattern-budget=12000", "Big.beni" });
    const enums = try w.run(&.{ "check", "--pattern-budget=12000", "Enums.beni" });
    // The path is not free, which is what keeps the refusal of queue slice 14
    // reachable: one branch of one `case` still costs more than one step.
    const nothing = try w.run(&.{ "check", "--pattern-budget=1", "Small.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for ([_]world.Result{ small, big, enums }) |r| {
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        try testing.expectEqualStrings("", r.stderr);
    }
    try testing.expectEqual(@as(u8, 1), nothing.exit_code);
    // `--pattern-budget` is session-wide, so core refuses too; this module's
    // own `case` is the one being asserted.
    var refused = false;
    for (nothing.diagnostics) |d| {
        if (!std.mem.eql(u8, d.span.file, "Small.beni")) continue;
        try testing.expectEqual(diagnostic.Code.pattern_budget_exhausted, d.code);
        refused = true;
    }
    try testing.expect(refused);
}

test "the key path still names the redundant pair and the missing combinations" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Branch 700 (1-based: the 701st) repeats the key of branch 0.
    try w.write("Dup.beni", try pairLiteralTable(a, 1800, 45, 700, null));
    // Every combination of two 20-constructor enums but the last three.
    try w.write("Holes.beni", try pairCtorTable(a, 20, 3));
    // A complete finite product with a default under it: the default is
    // dead, because 400 distinct keys fill a key space with 400 points.
    try w.write("Full.beni", blk: {
        var out: std.Io.Writer.Allocating = .init(a);
        try out.writer.writeAll(try pairCtorTable(a, 20, 0));
        try out.writer.writeAll("        _ ->\n            0\n");
        break :blk out.written();
    });

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const dup = try w.run(&.{ "check", "--pattern-budget=12000", "Dup.beni" });
    // The "some combinations are missing" answer is DELEGATED to
    // `isExhaustive`, which is why this one needs the general relation's
    // budget and the two above do not.
    const holes = try w.run(&.{ "check", "--pattern-budget=5000000", "Holes.beni" });
    const full = try w.run(&.{ "check", "--pattern-budget=4000", "Full.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), dup.exit_code);
    try testing.expectEqual(@as(usize, 1), dup.diagnostics.len);
    const d = dup.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.redundant_pattern, d.code);
    // The caret is on the PATTERN of the repeated branch, and the message
    // counts branches from one: three lines per branch after the three-line
    // head, so branch 701 starts at line 4 + 700·3. The column is the one a
    // tuple pattern has always reported (its last element, at `( 0, 0 )`'s
    // second zero), which this slice does not move.
    try testing.expectEqual(@as(u32, 4 + 700 * 3), d.span.start.line);
    try testing.expectEqual(@as(u32, 14), d.span.start.col);
    try testing.expect(std.mem.indexOf(u8, d.message, "The 701st pattern is redundant") != null);

    try testing.expectEqual(@as(u8, 1), holes.exit_code);
    try testing.expectEqual(@as(usize, 1), holes.diagnostics.len);
    const m = holes.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.missing_patterns, m.code);
    // The three combinations with no branch, named as PAIRS, in declaration
    // order — the same witnesses the general relation builds, because the key
    // path delegates every answer that is not "exhaustive" to it.
    try testing.expect(std.mem.indexOf(
        u8,
        m.message,
        "    ( P19, Q17 )\n    ( P19, Q18 )\n    ( P19, Q19 )\n",
    ) != null);

    try testing.expectEqual(@as(u8, 1), full.exit_code);
    try testing.expectEqual(@as(usize, 1), full.diagnostics.len);
    const f = full.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.redundant_pattern, f.code);
    try testing.expect(std.mem.indexOf(u8, f.message, "The 401st pattern is redundant") != null);
}

test "a pair row with a wildcard column falls back to the general relation" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // THE CUT. `( 2, _ )` covers a SLICE of the key space, and membership of
    // a point cannot decide a slice — so the key path answers nothing for it
    // and hands that row and every row after it to `isUseful`, which shadows
    // `( 2, 11 )` correctly. The wrong answer here would be exit 0 on a
    // `case` with a branch that never runs.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Row 100 is `( 2, _ )`; row 101 is `( 2, 11 )`, which it shadows.
    try w.write("Open.beni", try pairLiteralTable(a, 200, 45, null, 100));

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // The general relation's budget, not the key path's: falling back is the
    // point, and it is quadratic again from row 100 down.
    const open = try w.run(&.{ "check", "--pattern-budget=100000", "Open.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), open.exit_code);
    try testing.expectEqual(@as(usize, 1), open.diagnostics.len);
    const d = open.diagnostics[0];
    try testing.expectEqual(diagnostic.Code.redundant_pattern, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, "The 102nd pattern is redundant") != null);
    try testing.expectEqual(@as(u32, 4 + 101 * 3), d.span.start.line);
}

// ---------------------------------------------------------------------------
// S3 — the module graph carries TYPE edges, and they are deterministic
// (`static-dispatch-spike.md` §6.8, `fast-compiler.md` §10, CLAUDE.md rule 5)
//
// A method call resolves in the module that DECLARES the receiver's type
// (§1.2), so that module's interface has to be complete before the call is
// checked. Under `--jobs>1` the only thing that guarantees it is the graph:
// a module starts once every dependency has finished, and those once theirs
// had. `dump --stage=graph` is what makes the edge set assertable, and the
// fixture it is pointed at is a corpus project, so the same four modules
// are also checked and interface-goldened by `corpus_test.zig`.
// ---------------------------------------------------------------------------

const type_owner_edges = "tests/corpus/check/good/TypeOwnerEdges";

test "dump --stage=graph prints the type edges, identically at --jobs=1 and --jobs=8" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    // Twice each and alternating: what varies between runs is which worker
    // took which file, which is a property of a run and not of the flag.
    const runs = [4][]const u8{ "--jobs=1", "--jobs=8", "--jobs=1", "--jobs=8" };
    var dumps: [4][]const u8 = undefined;
    for (&dumps, runs) |*out, jobs| {
        const r = try w.runWith(
            &.{ "dump", "--stage=graph", jobs, type_owner_edges },
            .{ .raw_diagnostics = true, .cwd = .inherit },
        );
        try testing.expectEqual(@as(u8, 0), r.exit_code);
        try testing.expectEqualStrings("", r.stderr);
        out.* = r.stdout;
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for (dumps[1..]) |other| try testing.expectEqualStrings(dumps[0], other);

    // The claims the fixture exists to make, named so that re-blessing the
    // golden cannot quietly drop one:
    //
    //   - a type reached through another module's interface: `User` never
    //     writes `Owner`, and `Owner` is its ancestor through `Middle`;
    //   - a type the checker MINTS: `Literals` imports nothing and names
    //     nothing, and `a < b` lowers to a `method_call` that records no
    //     `refs` edge of its own (§1.4). Before §6.8 that module had no
    //     dependency at all and ran beside the core modules it reads.
    for ([_][]const u8{
        "app:User -> app:Middle\n",
        "app:Middle -> app:Owner\n",
        "app:Literals -> core:Basics\n",
        "app:Literals -> core:Char\n",
        "app:Literals -> core:List\n",
        "app:Literals -> core:String\n",
    }) |edge| {
        if (std.mem.indexOf(u8, dumps[0], edge) == null) {
            std.debug.print("missing edge {s}--- graph ---\n{s}", .{ edge, dumps[0] });
            return error.MissingEdge;
        }
    }
    // `User -> Owner` is NOT an edge: §6.8 buys an ancestor, not a direct
    // dependency, and claiming the stronger thing would be a false golden.
    try testing.expect(std.mem.indexOf(u8, dumps[0], "app:User -> app:Owner\n") == null);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The whole edge set, core included, against the golden next to the
    // fixture. Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`.
    try expectGolden(type_owner_edges ++ "/_expected.graph", dumps[0]);
}

/// Compare `actual` against a golden file relative to the repo root — or
/// write it when `BENI_WRITE_EXPECTED` is set, the same switch
/// `corpus_test.zig` blesses with.
fn expectGolden(path: []const u8, actual: []const u8) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    const bless = blk: {
        const value = testing.environ.getAlloc(gpa, "BENI_WRITE_EXPECTED") catch break :blk false;
        defer gpa.free(value);
        break :blk value.len != 0 and !std.mem.eql(u8, value, "0");
    };
    if (bless) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = actual });
        return;
    }
    const expected = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(world.max_stream_bytes)) catch |err| {
        std.debug.print("{s}: {t} (bless with BENI_WRITE_EXPECTED=1 zig build test-blackbox)\n", .{ path, err });
        return err;
    };
    defer gpa.free(expected);
    try testing.expectEqualStrings(expected, actual);
}

test "a minted type's edge is to core, even when an app module shadows the name" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `List` here is the user's own module, and it shadows core's for every
    // NAME in the project (`Graph.lookup`). It does not shadow the TYPE a
    // list literal has: `check/Types.findWellKnown` resolves `List` against
    // package `core` and nothing else. `Uses` writes a list and names
    // nobody, so the edge §6.8 adds has to go where the checker will look.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/List.beni", "pub mine : Int\nmine =\n    1\n");
    try w.write("src/Uses.beni", "pub sizes =\n    [ 1, 2 ]\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "dump", "--stage=graph", "src" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "app:Uses -> core:List\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "app:Uses -> app:List\n") == null);
    // And the shadowing module itself is still a module of the project,
    // with its own edge for its own literal.
    try testing.expect(std.mem.indexOf(u8, r.stdout, "app:List -> core:Basics\n") != null);
}
