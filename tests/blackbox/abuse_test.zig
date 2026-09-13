//! Abuse scenarios (docs/design/frontend.md §8 "M1d",
//! .claude/skills/write-tests/SKILL.md "Abuse scenarios are first-class").
//!
//! Hostile and degenerate source is a supported input, not an edge case. A
//! 10 MB literal, 100 000 levels of nesting, every byte value there is, a
//! directory of five thousand modules, a symlink that points at its own
//! parent: each must produce a diagnostic or a clean pass — never a panic,
//! never a hang, never a partial write. Every scenario here therefore
//! asserts four things beyond the diagnostics:
//!
//!   - the exit code, exactly;
//!   - that the child EXITED rather than dying from a signal (`Term`), so
//!     a `SIGSEGV` or a `SIGABRT` from a safety check cannot be mistaken
//!     for a diagnostic-carrying failure;
//!   - that it finished inside the harness timeout — a run that does not
//!     never reaches an assertion, because `World.run` kills it and
//!     returns `error.CompilerTimeout`;
//!   - no partial output: for `check`, stdout is empty; for `fmt`, the
//!     input file is byte-identical afterwards and stdout is empty.
//!
//! The inputs are BUILT HERE, not checked in: a 10 MB fixture in git is a
//! 10 MB fixture in every clone forever, and the bytes are easier to trust
//! when the test says how they were made. What is frozen into
//! `bench/pathological/` is the small, slow subset (see that
//! directory's README); the giant ones are generator cases in
//! `bench/gen.zig` for the same reason.
//!
//! Peak memory is asserted OUTSIDE this file: measuring a child's RSS
//! portably from a test means polling `/proc`, which is a Linux-only race.
//! The numbers in `bench/README.md` come from `getrusage(RUSAGE_CHILDREN)`
//! around each run; here the claim is the one a test can make honestly —
//! it finished, and it finished cleanly.

const std = @import("std");
const diagnostic = @import("diagnostic");
const world = @import("world.zig");
const World = world.World;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ten_megabytes = 10 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Enormous single files
// ---------------------------------------------------------------------------

test "a 10 MB single-line list literal lexes, parses and lowers with no diagnostics" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const source = try listLiteral(testing.allocator, ten_megabytes);
    defer testing.allocator.free(source);
    try w.write("Big.beni", source);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Big.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The whole point of this one: it is VALID. Ten megabytes of list is a
    // program, so every phase must run it to completion and say nothing.
    try expectExited(r, 0);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualSlices(diagnostic.Diagnostic, &.{}, r.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // `fmt --check` formats it too — 3.5 million elements, one per line —
    // and must still write nothing: `--check` only ever lists.
    const f = try w.run(&.{ "fmt", "--check", "Big.beni" });
    try testing.expectEqual(@as(u8, 1), f.exit_code);
    try testing.expectEqualStrings("Big.beni\n", f.stdout);
    try testing.expectEqualStrings("", f.stderr);
    try testing.expectEqualStrings(source, try w.read("Big.beni"));
}

test "a 10 MB single-line string literal is one token and no diagnostic" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const source = try repeatedInside(testing.allocator, "main =\n    \"", 'a', ten_megabytes, "\"\n");
    defer testing.allocator.free(source);
    try w.write("Big.beni", source);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Big.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(r, 0);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A string is copied verbatim (language.md §9), so the canonical form
    // of this file is the file: `fmt --check` finds nothing to say.
    const f = try w.run(&.{ "fmt", "--check", "Big.beni" });
    try expectExited(f, 0);
    try testing.expectEqualStrings("", f.stderr);
    try testing.expectEqualStrings(source, try w.read("Big.beni"));
}

test "a 10 MB file that is one identifier is a definition without `=`" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const source = try repeatedInside(testing.allocator, "", 'a', ten_megabytes, "\n");
    defer testing.allocator.free(source);
    try w.write("Big.beni", source);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Big.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // One 10 MB identifier is one token, and one token at the top level is
    // the start of a definition: the parser wants `=` and hits EOF. The
    // span is the EOF position — the line after the identifier.
    try expectExited(r, 1);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
        .code = .expected_token,
        .severity = .@"error",
        .span = .{ .file = "Big.beni", .start = .{ .line = 2, .col = 1 }, .end = .{ .line = 2, .col = 1 } },
        .title = "EXPECTED TOKEN",
        .message = "I got to the end of the file while parsing a definition. I was expecting `=` next.",
    }}, r.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectFmtRefuses(&w, "Big.beni", 1);
}

// ---------------------------------------------------------------------------
// Deep nesting
// ---------------------------------------------------------------------------

test "100 000 nested parentheses stop at exactly one nesting_too_deep" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const source = try nested(testing.allocator, "(", "1", ")", 100_000);
    defer testing.allocator.free(source);
    try w.write("Deep.beni", source);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Deep.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The parser's depth limit is what keeps recursion off the stack; it
    // fires once, at the first level past the limit, and the rest of the
    // file is not turned into 96 000 more copies of the same complaint.
    try expectExited(r, 1);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{nestingTooDeep("Deep.beni", 2, 4101, 1)}, r.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectFmtRefuses(&w, "Deep.beni", 1);
}

test "100 000 nested lists stop at exactly one nesting_too_deep" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const source = try nested(testing.allocator, "[", "", "]", 100_000);
    defer testing.allocator.free(source);
    try w.write("Deep.beni", source);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Deep.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(r, 1);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{nestingTooDeep("Deep.beni", 2, 4101, 1)}, r.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectFmtRefuses(&w, "Deep.beni", 1);
}

test "100 000 nested lambdas report every shadowed parameter, then stop nesting" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `\x -> \x -> …`: every parameter but the first shadows the one
    // outside it, so this is the input that asks whether the diagnostic
    // list needs a cap. It does not — the nesting limit caps it first, at
    // 4096 — which is why there is no `--max-errors` flag to test.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const source = try nested(testing.allocator, "\\x -> ", "1", "", 100_000);
    defer testing.allocator.free(source);
    try w.write("Lambdas.beni", source);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Lambdas.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // 4095 shadowings (every parameter but the outermost) and the single
    // nesting error that ended the parse: count, then first and last in
    // full, because 4096 whole structs is not an assertion anyone reads.
    try expectExited(r, 1);
    try testing.expectEqual(@as(usize, 4096), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .shadowing,
        .severity = .@"error",
        .span = .{ .file = "Lambdas.beni", .start = .{ .line = 2, .col = 12 }, .end = .{ .line = 2, .col = 13 } },
        .title = "SHADOWING",
        .message = "The name `x` is already bound on line 2.\n\nShadowing is not allowed: a binding cannot reuse a name that is in scope, whether\nfrom an enclosing binding, a top-level declaration, an `exposing` list or the\nprelude. Rename one of them.",
    }, r.diagnostics[0]);
    try testing.expectEqualDeep(nestingTooDeep("Lambdas.beni", 2, 24581, 1), r.diagnostics[r.diagnostics.len - 1]);
    var shadowings: usize = 0;
    for (r.diagnostics) |d| {
        if (d.code == .shadowing) shadowings += 1;
    }
    try testing.expectEqual(@as(usize, 4095), shadowings);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectFmtRefuses(&w, "Lambdas.beni", 1);
}

test "the three left-deep spines the parser builds in a loop are depth-bounded too" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `1 + 1 + …`, `r.a.a.a…` and `r????…` are assembled by LOOPS in the
    // parser, not by recursion, so they cost it no stack — but they are
    // real tree depth, and every consumer that walks the tree recurses
    // along them. Before `Parse.max_depth` counted them, a 24 KB file of
    // `1 + 1 + …` segfaulted `beni check` and an 8 KB file of `r.a.a.a…`
    // segfaulted both `check` and `dump --stage=ast`. 8000 links each,
    // which is comfortably past the 4096 limit and was comfortably past
    // the stack.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const cases = [_]struct { path: []const u8, head: []const u8, piece: []const u8, col: u32, width: u32 }{
        .{ .path = "Plus.beni", .head = "x =\n    1", .piece = " + 1", .col = 16385, .width = 1 },
        .{ .path = "Access.beni", .head = "f r =\n    r", .piece = ".a", .col = 8196, .width = 2 },
        .{ .path = "Question.beni", .head = "f r =\n    r", .piece = "?", .col = 4101, .width = 1 },
    };

    for (cases) |case| {
        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const source = try chain(testing.allocator, case.head, case.piece, 8000);
        defer testing.allocator.free(source);
        try w.write(case.path, source);
        const checked = try w.run(&.{ "check", case.path });
        const ast = try w.runWith(&.{ "dump", "--stage=ast", case.path }, .{ .raw_diagnostics = true });
        const bir = try w.runWith(&.{ "dump", "--stage=bir", case.path }, .{ .raw_diagnostics = true });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        // One diagnostic, at the first link past the limit, and nothing
        // died from a signal — which is what a stack overflow looks like
        // from out here.
        try expectExited(checked, 1);
        testing.expectEqualDeep(
            &[_]diagnostic.Diagnostic{nestingTooDeep(case.path, 2, case.col, case.width)},
            checked.diagnostics,
        ) catch |err| {
            std.debug.print("case {s}\n", .{case.path});
            return err;
        };
        // The dumps recurse per node; they are the consumers that crashed.
        // They exit 0 with the tree they have and the error on stderr.
        for ([_]world.Result{ ast, bir }) |r| {
            if (r.term != .exited) {
                std.debug.print("{s}: dump did not exit normally: {any}\n", .{ case.path, r.term });
                return error.CompilerDiedFromSignal;
            }
            try testing.expectEqual(@as(u8, 0), r.exit_code);
            try testing.expect(r.stdout.len != 0);
        }

        // ┌─────────────────────────────────────────┐
        // │ VERIFY SIDE EFFECTS                     │
        // └─────────────────────────────────────────┘
        try expectFmtRefuses(&w, case.path, 1);
    }
}

test "a pattern with `as` and no name is a syntax error, not a panic" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The parser's recovery used to build a `pat_as` whose name token was
    // the `as` KEYWORD. Lowering reads that token with `tokenSymbol`,
    // which asserts the tag is an interned one — so this panicked in
    // Debug, and in ReleaseFast, where the assert is compiled out, bound a
    // variable named `main`: a keyword's payload is 0, and symbol 0 is
    // `main`. Both are worse than the diagnostic.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("As.beni",
        \\f =
        \\    let
        \\        (x as) = 1
        \\    in
        \\    x
        \\
    );

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "As.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(r, 1);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
        .code = .expected_token,
        .severity = .@"error",
        .span = .{ .file = "As.beni", .start = .{ .line = 3, .col = 14 }, .end = .{ .line = 3, .col = 15 } },
        .title = "EXPECTED TOKEN",
        .message = "I was parsing a pattern and ran into `)`, but I was expecting `a name` here.",
    }}, r.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectFmtRefuses(&w, "As.beni", 1);
}

// ---------------------------------------------------------------------------
// Degenerate bytes
// ---------------------------------------------------------------------------

test "200 000 blank lines are a valid empty module" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const source = try testing.allocator.alloc(u8, 200_000);
    defer testing.allocator.free(source);
    @memset(source, '\n');
    try w.write("Blank.beni", source);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Blank.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(r, 0);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A module with no declarations formats to nothing at all, so `fmt`
    // DOES rewrite this one: 200 000 blank lines become zero bytes.
    const f = try w.run(&.{ "fmt", "Blank.beni" });
    try expectExited(f, 0);
    try testing.expectEqualStrings("", f.stderr);
    try testing.expectEqualStrings("", try w.read("Blank.beni"));
}

test "a file of every byte value 0-255 reports its lexical errors and never panics" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var source: [256]u8 = undefined;
    for (&source, 0..) |*b, i| b.* = @intCast(i);
    try w.write("Bytes.beni", &source);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Bytes.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // 128 invalid UTF-8 bytes (0x80-0xFF, each its own error), 30 control
    // characters, and one each of tab, bare CR, unterminated string and
    // invalid escape. The counts per code are the assertion: which byte
    // lands in which bucket is the lexer's contract, and a change to it
    // should show up here as a number, not as a silent reclassification.
    try expectExited(r, 1);
    try testing.expectEqual(@as(usize, 162), r.diagnostics.len);
    var counts: std.enums.EnumArray(diagnostic.Code, usize) = .initFill(0);
    for (r.diagnostics) |d| counts.set(d.code, counts.get(d.code) + 1);
    try testing.expectEqual(@as(usize, 128), counts.get(.invalid_utf8));
    try testing.expectEqual(@as(usize, 30), counts.get(.invalid_character));
    try testing.expectEqual(@as(usize, 1), counts.get(.tab_in_source));
    try testing.expectEqual(@as(usize, 1), counts.get(.bare_carriage_return));
    try testing.expectEqual(@as(usize, 1), counts.get(.unterminated_string));
    try testing.expectEqual(@as(usize, 1), counts.get(.invalid_escape));
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .invalid_character,
        .severity = .@"error",
        .span = .{ .file = "Bytes.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 2 } },
        .title = "INVALID CHARACTER",
        .message = "I found a control character (0x00) that cannot appear here.\n\nOnly spaces and newlines separate tokens. Control characters are allowed\ninside comments and multiline strings, and as escapes inside ordinary strings.",
    }, r.diagnostics[0]);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .invalid_utf8,
        .severity = .@"error",
        .span = .{ .file = "Bytes.beni", .start = .{ .line = 2, .col = 245 }, .end = .{ .line = 2, .col = 246 } },
        .title = "INVALID UTF-8",
        .message = "I found bytes that are not valid UTF-8: 0xFF\n\nBeni source files must be encoded as UTF-8. Check the file's encoding, or look\nfor a multi-byte character that was cut short.",
    }, r.diagnostics[r.diagnostics.len - 1]);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectFmtRefuses(&w, "Bytes.beni", 1);
}

test "mixed CRLF, LF and a bare CR: the lone CR is the only line-ending error" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const source = "a = 1\r\nb = 2\nc = 3\rd = 4\n";
    try w.write("Endings.beni", source);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Endings.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // `\r\n` and `\n` are both line endings; a lone `\r` is neither, so it
    // is an error AND it does not end the line — which is why `d = 4` is
    // read as a continuation of `c`'s declaration and produces two more
    // diagnostics on line 3. Reporting all three is the point: the lexer
    // does not stop at the first bad byte.
    try expectExited(r, 1);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{
        .{
            .code = .bare_carriage_return,
            .severity = .@"error",
            .span = .{ .file = "Endings.beni", .start = .{ .line = 3, .col = 6 }, .end = .{ .line = 3, .col = 7 } },
            .title = "BARE CARRIAGE RETURN",
            .message = "I found a carriage return (\\r) that is not followed by a newline.\n\nLine endings must be \\n or \\r\\n. A lone \\r is neither, so convert the file's\nline endings to one of those.",
        },
        .{
            .code = .unbound_variable,
            .severity = .@"error",
            .span = .{ .file = "Endings.beni", .start = .{ .line = 3, .col = 7 }, .end = .{ .line = 3, .col = 8 } },
            .title = "NAMING ERROR",
            .message = "I cannot find a `d` variable.\n\nIt is not a local binding, a top-level value of this module, a name from an\n`exposing` list, or a prelude value. Check the spelling, or add it to an import.",
        },
        .{
            .code = .unexpected_token,
            .severity = .@"error",
            .span = .{ .file = "Endings.beni", .start = .{ .line = 3, .col = 9 }, .end = .{ .line = 3, .col = 10 } },
            .title = "UNEXPECTED TOKEN",
            .message = "I was parsing the declaration of `c` and ran into `=`, which cannot continue it.\n\nEither it is part of the expression before it (then check what comes just\nbefore it), or it should start a new declaration on column 1.",
        },
    }, r.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectFmtRefuses(&w, "Endings.beni", 1);
}

test "unterminated string, char, interpolation, paren, bracket and brace at EOF" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Six ways to end a file in the middle of something. Each is its own
    // project so the spans name a file of its own, and each is checked for
    // the whole diagnostic list AND for `fmt` leaving its bytes alone.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    const cases = [_]struct { path: []const u8, source: []const u8, want: []const diagnostic.Diagnostic }{
        .{ .path = "String.beni", .source = "main = \"abc", .want = &.{.{
            .code = .unterminated_string,
            .severity = .@"error",
            .span = .{ .file = "String.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 12 } },
            .title = "UNTERMINATED STRING",
            .message = "I got to the end of the file without seeing the closing `\"` of this string.\n\nStrings are single-line. For text that spans several lines, use a multiline\nstring, one `\\\\` per line:\n\n    \\\\first line\n    \\\\second line",
        }} },
        .{ .path = "Char.beni", .source = "main = 'a", .want = &.{.{
            .code = .invalid_char_literal,
            .severity = .@"error",
            .span = .{ .file = "Char.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 10 } },
            .title = "INVALID CHAR LITERAL",
            .message = "I got to the end of the line without seeing the closing `'` of this\ncharacter literal.\n\nA character literal holds exactly one character: `'a'`, `'\\n'`, `'\\u{1F600}'`.",
        }} },
        .{ .path = "Interp.beni", .source = "main = \"x ${y", .want = &.{
            .{
                .code = .unterminated_string,
                .severity = .@"error",
                .span = .{ .file = "Interp.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 14 } },
                .title = "UNTERMINATED STRING",
                .message = "I got to the end of the file without seeing the closing `\"` of this string.\n\nStrings are single-line. For text that spans several lines, use a multiline\nstring, one `\\\\` per line:\n\n    \\\\first line\n    \\\\second line",
            },
            .{
                .code = .unbound_variable,
                .severity = .@"error",
                .span = .{ .file = "Interp.beni", .start = .{ .line = 1, .col = 13 }, .end = .{ .line = 1, .col = 14 } },
                .title = "NAMING ERROR",
                .message = "I cannot find a `y` variable.\n\nIt is not a local binding, a top-level value of this module, a name from an\n`exposing` list, or a prelude value. Check the spelling, or add it to an import.",
            },
        } },
        .{ .path = "Paren.beni", .source = "main = (", .want = &.{
            .{
                .code = .unclosed_delimiter,
                .severity = .@"error",
                .span = .{ .file = "Paren.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 9 } },
                .title = "UNCLOSED DELIMITER",
                .message = "I was parsing a parenthesised expression and got to the end of the file without finding the `)` that\ncloses this `(`.",
            },
            .{
                .code = .unexpected_token,
                .severity = .@"error",
                .span = .{ .file = "Paren.beni", .start = .{ .line = 1, .col = 9 }, .end = .{ .line = 1, .col = 9 } },
                .title = "UNEXPECTED TOKEN",
                .message = "I got to the end of the file while parsing a parenthesised expression. I was expecting an expression.",
            },
        } },
        .{ .path = "Bracket.beni", .source = "main = [", .want = &.{
            .{
                .code = .unclosed_delimiter,
                .severity = .@"error",
                .span = .{ .file = "Bracket.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 9 } },
                .title = "UNCLOSED DELIMITER",
                .message = "I was parsing a list and got to the end of the file without finding the `]` that\ncloses this `[`.",
            },
            .{
                .code = .unexpected_token,
                .severity = .@"error",
                .span = .{ .file = "Bracket.beni", .start = .{ .line = 1, .col = 9 }, .end = .{ .line = 1, .col = 9 } },
                .title = "UNEXPECTED TOKEN",
                .message = "I got to the end of the file while parsing a list. I was expecting an expression.",
            },
        } },
        .{ .path = "Brace.beni", .source = "main = {", .want = &.{
            .{
                .code = .unclosed_delimiter,
                .severity = .@"error",
                .span = .{ .file = "Brace.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 9 } },
                .title = "UNCLOSED DELIMITER",
                .message = "I was parsing a record and got to the end of the file without finding the `}` that\ncloses this `{`.",
            },
            .{
                .code = .unexpected_token,
                .severity = .@"error",
                .span = .{ .file = "Brace.beni", .start = .{ .line = 1, .col = 9 }, .end = .{ .line = 1, .col = 9 } },
                .title = "UNEXPECTED TOKEN",
                .message = "I got to the end of the file while parsing a record. I was expecting a field name.",
            },
        } },
    };

    for (cases) |case| {
        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        try w.write(case.path, case.source);
        const r = try w.run(&.{ "check", case.path });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try expectExited(r, 1);
        testing.expectEqualDeep(case.want, r.diagnostics) catch |err| {
            std.debug.print("case {s}\n", .{case.path});
            return err;
        };

        // ┌─────────────────────────────────────────┐
        // │ VERIFY SIDE EFFECTS                     │
        // └─────────────────────────────────────────┘
        try expectFmtRefuses(&w, case.path, 1);
    }
}

test "a file that is only `--|` is an unattached doc comment" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Doc.beni", "--|");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Doc.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(r, 1);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
        .code = .doc_comment_unattached,
        .severity = .@"error",
        .span = .{ .file = "Doc.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 4 } },
        .title = "UNATTACHED DOC COMMENT",
        .message = "This `--|` doc comment is not attached to a declaration.\n\nA `--|` block documents the declaration that starts on the next non-blank line\n(`pub` included). It cannot come before an import, an ordinary `--` comment, a\n`let` binding, or the end of the file. For a comment that is not documentation,\nuse `--`.",
    }}, r.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectFmtRefuses(&w, "Doc.beni", 1);
}

test "a file that is only a backslash cannot begin a declaration" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Lambda.beni", "\\");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Lambda.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // A lone `\` is a lambda that never starts. It is reported as a
    // declaration problem, not a lexical one: `\` IS a token.
    try expectExited(r, 1);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
        .code = .expected_declaration,
        .severity = .@"error",
        .span = .{ .file = "Lambda.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 2 } },
        .title = "EXPECTED DECLARATION",
        .message = "I was parsing the top level of this module and ran into `\\` on column 1, which cannot begin a declaration.\n\nA line that starts on column 1 begins a new import or declaration:\n\n    import Json.Decode\n    type alias Point = { x : Int, y : Int }\n    type Shape = Circle Float | Rect Float Float\n    area : Shape -> Float\n    area shape = ...\n\nEverything that belongs to the previous declaration must be indented by at\nleast one space.",
    }}, r.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try expectFmtRefuses(&w, "Lambda.beni", 1);
}

test "a 1 MB comment line is a valid empty module" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const source = try repeatedInside(testing.allocator, "-- ", 'x', 1024 * 1024, "\n");
    defer testing.allocator.free(source);
    try w.write("Comment.beni", source);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Comment.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(r, 0);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // A comment is copied verbatim, so this file is already canonical.
    const f = try w.run(&.{ "fmt", "--check", "Comment.beni" });
    try expectExited(f, 0);
    try testing.expectEqualStrings(source, try w.read("Comment.beni"));
}

// ---------------------------------------------------------------------------
// Degenerate project shapes
// ---------------------------------------------------------------------------

test "an empty directory is zero files and zero diagnostics" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.createDir("src");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "src" });
    const f = try w.run(&.{ "fmt", "--check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Nothing to compile is not an error: an empty source tree is a
    // perfectly good starting point for a project.
    try expectExited(r, 0);
    try testing.expectEqualStrings("", r.stderr);
    try expectExited(f, 0);
    try testing.expectEqualStrings("", f.stderr);
}

test "5 000 empty modules produce identical output at --jobs=1 and the machine default" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Five thousand files is the shape where the driver's per-file costs
    // dominate everything the phases do, and the shape most likely to make
    // a worker pool behave differently from a single thread.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var name: [32]u8 = undefined;
    for (0..5_000) |i| try w.write(try std.fmt.bufPrint(&name, "src/M{d:0>4}.beni", .{i}), "");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const one = try w.run(&.{ "check", "--jobs=1", "src" });
    const many = try w.run(&.{ "check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(one, 0);
    try expectExited(many, 0);
    try testing.expectEqualStrings("", one.stderr);
    try testing.expectEqualStrings(one.stderr, many.stderr);
    try testing.expectEqualStrings(one.stdout, many.stdout);
}

test "the same file twice on the command line is one set of diagnostics" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Twice.beni", "main = \"abc");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Twice.beni", "Twice.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Enumeration deduplicates by path before numbering, so the file is
    // one file with one index — not two files that happen to be equal, and
    // certainly not a doubled diagnostic list.
    try expectExited(r, 1);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
        .code = .unterminated_string,
        .severity = .@"error",
        .span = .{ .file = "Twice.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 12 } },
        .title = "UNTERMINATED STRING",
        .message = "I got to the end of the file without seeing the closing `\"` of this string.\n\nStrings are single-line. For text that spans several lines, use a multiline\nstring, one `\\\\` per line:\n\n    \\\\first line\n    \\\\second line",
    }}, r.diagnostics);
}

test "a directory path with a trailing slash walks the directory" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", "main = nope\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "src/" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The trailing slash is trimmed before the path becomes the module
    // root, so the module is `Main` and not `.Main`; the diagnostic names
    // the file by the path the walk built, without a doubled separator.
    try expectExited(r, 1);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
        .code = .unbound_variable,
        .severity = .@"error",
        .span = .{ .file = "src/Main.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 12 } },
        .title = "NAMING ERROR",
        .message = "I cannot find a `nope` variable.\n\nIt is not a local binding, a top-level value of this module, a name from an\n`exposing` list, or a prelude value. Check the spelling, or add it to an import.",
    }}, r.diagnostics);
}

test "a hidden .beni file is skipped by the walk and invalid_module_path when named" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/.hidden.beni", "main = nope\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const walked = try w.run(&.{ "check", "src" });
    const named = try w.run(&.{ "check", "src/.hidden.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Walking skips it silently — an editor swap file is not a module.
    try expectExited(walked, 0);
    try testing.expectEqualStrings("", walked.stderr);
    // Naming it explicitly is a different request, and gets a different
    // answer: `.hidden` is not an upper identifier, so there is no module
    // name to give it. The file is still compiled — a bad module name does
    // not stop the phases — so its own error is reported too, after the
    // path's, because diagnostics sort by position within a file.
    try expectExited(named, 1);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{
        .{
            .code = .invalid_module_path,
            .severity = .@"error",
            .span = .{ .file = "src/.hidden.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
            .title = "INVALID MODULE PATH",
            .message = "I cannot turn the path `src/.hidden.beni` into a module name.\n\nA module name comes from the path: `src/Json/Decode.beni` is `Json.Decode`. Every\nsegment of the path after the source root must be an upper identifier — a capital\nletter followed by letters, digits or underscores.",
        },
        .{
            .code = .unbound_variable,
            .severity = .@"error",
            .span = .{ .file = "src/.hidden.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 12 } },
            .title = "NAMING ERROR",
            .message = "I cannot find a `nope` variable.\n\nIt is not a local binding, a top-level value of this module, a name from an\n`exposing` list, or a prelude value. Check the spelling, or add it to an import.",
        },
    }, named.diagnostics);
}

test "a non-.beni file and a nested hidden directory are both skipped" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Main.beni", "main = 1\n");
    try w.write("src/notes.txt", "main = nope\n");
    try w.write("src/README.md", "not beni\n");
    try w.write("src/.cache/Stale.beni", "main = nope\n");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Only `.beni` files under non-hidden directories are modules. If
    // either rule slipped, `nope` would be reported.
    try expectExited(r, 0);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // And `fmt` does not rewrite what the walk did not enumerate.
    const f = try w.run(&.{ "fmt", "src" });
    try expectExited(f, 0);
    try testing.expectEqualStrings("main = nope\n", try w.read("src/notes.txt"));
    try testing.expectEqualStrings("main = nope\n", try w.read("src/.cache/Stale.beni"));
}

test "a symlink loop in the tree terminates the walk instead of following it" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `src/Inner/loop -> ..` makes the tree infinite. Before the walk
    // stopped following symlinks it recursed until the OS answered
    // `SymLinkLoop`, and the whole run died with exit 2 — one link
    // anywhere in a project failed every build in it.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("src/Inner/Main.beni", "main = 1\n");
    try w.symlink("..", "src/Inner/loop");
    try w.symlink("Main.beni", "src/Inner/Link.beni");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "src" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // The walk terminates and compiles the one real module. Exit 0, not
    // exit 2: a symlink is not an I/O failure, it is something to skip.
    try expectExited(r, 0);
    try testing.expectEqualStrings("", r.stderr);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The symlinked FILE is skipped by the same rule, so it is enumerated
    // exactly zero times — naming it on the command line is the way to
    // compile it, and that still works because an argument path IS
    // followed.
    const named = try w.run(&.{ "check", "src/Inner/Link.beni" });
    try expectExited(named, 0);
    try testing.expectEqualStrings("", named.stderr);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// The invariants every scenario shares: the child EXITED with `code`
/// rather than dying from a signal, and wrote nothing to stdout. A run that
/// did not finish inside `world.timeout_ms` never reaches here — the
/// harness kills it and returns `error.CompilerTimeout`.
///
/// stdout is checked here because no command in this file has stdout as its
/// product: `check` never writes there, and neither does `fmt` in place.
/// The two scenarios that use `fmt --check` (whose product IS a list of
/// paths on stdout) assert it themselves.
fn expectExited(r: world.Result, code: u8) !void {
    if (r.term != .exited) {
        std.debug.print("compiler did not exit normally: {any}\n--- stderr ---\n{s}\n", .{ r.term, r.stderr });
        return error.CompilerDiedFromSignal;
    }
    if (r.exit_code != code) {
        std.debug.print("expected exit {d}, got {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ code, r.exit_code, r.stdout, r.stderr });
        return error.UnexpectedExitCode;
    }
    try testing.expectEqualStrings("", r.stdout);
}

/// `fmt` in place over a file the formatter must refuse: the bytes are
/// unchanged afterwards and nothing was printed. A formatter that
/// half-wrote a hostile file would be worse than one that refused it, so
/// "no partial output" is asserted as "no output at all".
fn expectFmtRefuses(w: *World, path: []const u8, code: u8) !void {
    const before = try w.read(path);
    const r = try w.run(&.{ "fmt", path });
    try expectExited(r, code);
    const after = try w.read(path);
    if (!std.mem.eql(u8, before, after)) {
        std.debug.print("fmt rewrote {s}: {d} bytes became {d}\n", .{ path, before.len, after.len });
        return error.FileWasRewritten;
    }
}

/// The `nesting_too_deep` the parser emits over the `width` bytes at
/// `line:col`. Its wording is the same wherever it fires, so it is written
/// once; the span is the token that would have been one level too deep,
/// which is two bytes for a `.field` and one for everything else here.
fn nestingTooDeep(file: []const u8, line: u32, col: u32, width: u32) diagnostic.Diagnostic {
    return .{
        .code = .nesting_too_deep,
        .severity = .@"error",
        .span = .{ .file = file, .start = .{ .line = line, .col = col }, .end = .{ .line = line, .col = col + width } },
        .title = "NESTING TOO DEEP",
        .message = "This expression is nested more than 4096 levels deep, which is more than I can\nhandle.\n\nSplit it into smaller pieces with `let`, or remove some of the nesting.",
    };
}

/// `main =\n    [ 1, 1, … ]` on one line, at least `bytes` long.
fn listLiteral(gpa: Allocator, bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes + 64);
    out.appendSliceAssumeCapacity("main =\n    [ 1");
    while (out.items.len + 3 < bytes) out.appendSliceAssumeCapacity(", 1");
    out.appendSliceAssumeCapacity(" ]\n");
    return out.toOwnedSlice(gpa);
}

/// `prefix` then `filler` repeated until the whole thing is `bytes` long,
/// then `suffix`.
fn repeatedInside(gpa: Allocator, prefix: []const u8, filler: u8, bytes: usize, suffix: []const u8) ![]u8 {
    std.debug.assert(bytes > prefix.len + suffix.len);
    const out = try gpa.alloc(u8, bytes);
    errdefer gpa.free(out);
    @memcpy(out[0..prefix.len], prefix);
    @memset(out[prefix.len .. bytes - suffix.len], filler);
    @memcpy(out[bytes - suffix.len ..], suffix);
    return out;
}

/// `head` followed by `piece` repeated `links` times, all on one line.
fn chain(gpa: Allocator, head: []const u8, piece: []const u8, links: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, head.len + links * piece.len + 2);
    out.appendSliceAssumeCapacity(head);
    for (0..links) |_| out.appendSliceAssumeCapacity(piece);
    out.appendSliceAssumeCapacity("\n");
    return out.toOwnedSlice(gpa);
}

/// `main =\n    ` then `open` repeated `depth` times, `middle`, and `close`
/// repeated `depth` times — all on one line.
fn nested(gpa: Allocator, open: []const u8, middle: []const u8, close: []const u8, depth: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, 16 + depth * (open.len + close.len) + middle.len);
    out.appendSliceAssumeCapacity("main =\n    ");
    for (0..depth) |_| out.appendSliceAssumeCapacity(open);
    out.appendSliceAssumeCapacity(middle);
    for (0..depth) |_| out.appendSliceAssumeCapacity(close);
    out.appendSliceAssumeCapacity("\n");
    return out.toOwnedSlice(gpa);
}
