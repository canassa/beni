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
        .message = "I got to the end of the file while parsing a definition. I was expecting `=`\nnext.",
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
    // 4094 shadowings (every parameter but the outermost) and the single
    // nesting error that ended the parse: count, then first and last in
    // full, because 4095 whole structs is not an assertion anyone reads.
    // One level fewer fits than before M2c, because the depth guard now
    // charges a pattern ATOM too — a lambda's parameter is one — so that
    // the guard bounds the TREE every consumer walks and not just the
    // source nesting (see the deep-constructor-pattern scenario).
    try expectExited(r, 1);
    try testing.expectEqual(@as(usize, 4095), r.diagnostics.len);
    try testing.expectEqualDeep(diagnostic.Diagnostic{
        .code = .shadowing,
        .severity = .@"error",
        .span = .{ .file = "Lambdas.beni", .start = .{ .line = 2, .col = 12 }, .end = .{ .line = 2, .col = 13 } },
        .title = "SHADOWING",
        .message = "The name `x` is already bound on line 2.\n\nShadowing is not allowed: a binding cannot reuse a name that is in scope,\nwhether from an enclosing binding, a top-level declaration, an `exposing` list\nor the prelude. Rename one of them.",
    }, r.diagnostics[0]);
    try testing.expectEqualDeep(nestingTooDeep("Lambdas.beni", 2, 24576, 1), r.diagnostics[r.diagnostics.len - 1]);
    var shadowings: usize = 0;
    for (r.diagnostics) |d| {
        if (d.code == .shadowing) shadowings += 1;
    }
    try testing.expectEqual(@as(usize, 4094), shadowings);

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
        // They print the tree they have and exit 1 for the error on stderr
        // (`frontend.md` §1) — what matters here is that there IS a tree and
        // the process exited at all.
        for ([_]world.Result{ ast, bir }) |r| {
            if (r.term != .exited) {
                std.debug.print("{s}: dump did not exit normally: {any}\n", .{ case.path, r.term });
                return error.CompilerDiedFromSignal;
            }
            try testing.expectEqual(@as(u8, 1), r.exit_code);
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
                .message = "I was parsing a parenthesised expression and got to the end of the file without\nfinding the `)` that closes this `(`.",
            },
            .{
                .code = .unexpected_token,
                .severity = .@"error",
                .span = .{ .file = "Paren.beni", .start = .{ .line = 1, .col = 9 }, .end = .{ .line = 1, .col = 9 } },
                .title = "UNEXPECTED TOKEN",
                .message = "I got to the end of the file while parsing a parenthesised expression. I was\nexpecting an expression.",
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
                .message = "I got to the end of the file while parsing a list. I was expecting an\nexpression.",
            },
        } },
        .{ .path = "Brace.beni", .source = "main = {", .want = &.{
            .{
                .code = .unclosed_delimiter,
                .severity = .@"error",
                .span = .{ .file = "Brace.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 9 } },
                .title = "UNCLOSED DELIMITER",
                .message = "I was parsing a record and got to the end of the file without finding the `}`\nthat closes this `{`.",
            },
            .{
                .code = .unexpected_token,
                .severity = .@"error",
                .span = .{ .file = "Brace.beni", .start = .{ .line = 1, .col = 9 }, .end = .{ .line = 1, .col = 9 } },
                .title = "UNEXPECTED TOKEN",
                .message = "I got to the end of the file while parsing a record. I was expecting a field\nname.",
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
        .message = "I was parsing the top level of this module and ran into `\\` on column 1, which\ncannot begin a declaration.\n\nA line that starts on column 1 begins a new import or declaration:\n\n    import Json.Decode\n    type alias Point = { x : Int, y : Int }\n    type Shape = Circle Float | Rect Float Float\n    area : Shape -> Float\n    area shape = ...\n\nEverything that belongs to the previous declaration must be indented by at\nleast one space.",
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
    // The bound is raised for this one case, with a number behind it (queue
    // row 59): `--jobs=1` over 5 000 files was measured at 12.05, 24.29,
    // 26.11, 59.16 and 61.16 s for identical deterministic work — the spread
    // is a single thread landing on an efficiency core, not the compiler, and
    // the default 60 s sat inside it. `world.bulk_timeout_ms` is five times
    // the worst of those, so scheduling cannot reach it and a hang still
    // fails. The default-jobs run beside it took 6.00, 6.00 and 6.08 s.
    const bulk: world.RunOptions = .{ .timeout_ms = world.bulk_timeout_ms };
    const one = try w.runWith(&.{ "check", "--jobs=1", "src" }, bulk);
    const many = try w.runWith(&.{ "check", "src" }, bulk);

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
            .message = "I cannot turn the path `src/.hidden.beni` into a module name.\n\nA module name comes from the path: `src/Json/Decode.beni` is `Json.Decode`.\nEvery segment of the path after the source root must be an upper identifier — a\ncapital letter followed by letters, digits or underscores.",
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
/// did not finish inside its run's timeout never reaches here — the
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

// ---------------------------------------------------------------------------
// Pattern usefulness (checker.md §6.6): the algorithm is exponential in the
// worst case, so the inputs that reach for the exponent get their own
// scenarios.
// ---------------------------------------------------------------------------

test "a case with 200 constructors and 200 branches finishes and says one thing" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Maranget's usefulness relation branches once per alternative whenever
    // a column is COMPLETE, so the cost of one `case` grows with
    // constructors × branches × nesting. 200 × 200, each branch a two-deep
    // nest, is far past anything a person writes and is what the work
    // budget of `check/Exhaustive.zig` exists for: past it the `case`
    // reports nothing rather than hanging.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const ctors = 200;
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    const out = &source.writer;
    try out.writeAll("pub type T\n");
    for (0..ctors) |i| try out.print("    {s} C{d} T\n", .{ if (i == 0) "=" else "|", i });
    try out.writeAll("\n\npub f : T -> Int\nf t =\n    case t of\n");
    for (0..ctors) |i| {
        if (i != 0) try out.writeAll("\n");
        try out.print("        C{d} (C{d} rest{d}) ->\n            {d}\n", .{ i, (i + 1) % ctors, i, i });
    }
    try w.write("Wide.beni", source.written());

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "Wide.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // It finished — `World.run` would have returned `error.CompilerTimeout`
    // otherwise — it exited rather than dying from a signal, and it has
    // either exactly one thing to say or nothing at all. Which of the two
    // depends on the budget, and neither is a bug; a second message, a
    // signal or a hang would be.
    if (r.term != .exited) {
        std.debug.print("did not exit normally: {any}\n", .{r.term});
        return error.CompilerDiedFromSignal;
    }
    try testing.expect(r.diagnostics.len <= 1);
    if (r.diagnostics.len == 1) {
        try testing.expectEqual(diagnostic.Code.missing_patterns, r.diagnostics[0].code);
        try testing.expectEqual(@as(u8, 1), r.exit_code);
    } else {
        try testing.expectEqual(@as(u8, 0), r.exit_code);
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expectEqualStrings("", r.stdout);
}

test "a deeply nested constructor pattern is bounded in every consumer of the tree" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The regression, found writing this file: `Just (Just (…))` is TWO
    // tree levels per source level — `pat_ctor` over `pat_paren` — and the
    // parser charged its depth guard once, so a 4096-charge pattern built
    // an 8192-deep tree and segfaulted `check`, both dumps and `fmt`.
    // `parsePatAtom` now charges too, so the guard bounds the tree, and
    // every consumer runs on a thread with room for `max_depth` frames.
    //
    // 2000 levels is a legal tree the whole pipeline must survive; 8000 is
    // past the limit and must be exactly one `nesting_too_deep`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    for ([_]struct { depth: usize, path: []const u8, bounded: bool }{
        .{ .depth = 2000, .path = "Legal.beni", .bounded = false },
        .{ .depth = 8000, .path = "Deep.beni", .bounded = true },
    }) |case| {
        var source: std.Io.Writer.Allocating = .init(testing.allocator);
        defer source.deinit();
        const out = &source.writer;
        try out.writeAll("f m =\n    case m of\n        ");
        for (0..case.depth) |_| try out.writeAll("Just (");
        try out.writeAll("x");
        for (0..case.depth) |_| try out.writeAll(")");
        try out.writeAll(" ->\n            x\n");
        try w.write(case.path, source.written());

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const checked = try w.run(&.{ "check", case.path });
        const ast = try w.runWith(&.{ "dump", "--stage=ast", case.path }, .{ .raw_diagnostics = true });
        const bir = try w.runWith(&.{ "dump", "--stage=bir", case.path }, .{ .raw_diagnostics = true });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        for ([_]world.Result{ ast, bir }) |r| {
            if (r.term != .exited) {
                std.debug.print("{s}: dump did not exit normally: {any}\n", .{ case.path, r.term });
                return error.CompilerDiedFromSignal;
            }
            // A dump prints its tree either way; the exit code follows the
            // diagnostics, so the legal depth is 0 and the bounded one is 1
            // (`frontend.md` §1).
            try testing.expectEqual(@as(u8, if (case.bounded) 1 else 0), r.exit_code);
            try testing.expect(r.stdout.len != 0);
        }
        if (checked.term != .exited) {
            std.debug.print("{s}: check did not exit normally: {any}\n", .{ case.path, checked.term });
            return error.CompilerDiedFromSignal;
        }
        if (case.bounded) {
            // The nesting error, and the consequence of the recovery it
            // did: the truncated pattern never binds `x`, so the branch
            // body cannot find it. Two messages about one mistake, which
            // is what a pattern the parser had to abandon looks like.
            try testing.expectEqual(@as(u8, 1), checked.exit_code);
            try testing.expectEqual(@as(usize, 2), checked.diagnostics.len);
            try testing.expectEqual(diagnostic.Code.nesting_too_deep, checked.diagnostics[0].code);
            try testing.expectEqual(diagnostic.Code.unbound_variable, checked.diagnostics[1].code);
        } else {
            // A legal tree the parser and both dumps survive, and a `case`
            // the CHECKER cannot decide: 2000 levels is past `Exhaustive`'s
            // own depth guard (`checker.md` §6.6), so the analysis stops
            // rather than working for a week.
            //
            // It used to stop in SILENCE, and this line used to assert exit
            // 0 with no diagnostic — which was a hole, not a property. The
            // `case` is genuinely not exhaustive (one branch, `Nothing`
            // unmatched), so `backend.md` §7's default-free decision tree
            // would have answered `x` for a `Nothing` at exit 0. Queue slice
            // 14 made it a refusal, and the message it gets is the depth one:
            // `--pattern-budget` buys work, and this ran out of depth.
            try testing.expectEqual(@as(u8, 1), checked.exit_code);
            try testing.expectEqual(@as(usize, 1), checked.diagnostics.len);
            try testing.expectEqual(diagnostic.Code.pattern_budget_exhausted, checked.diagnostics[0].code);
            try testing.expect(std.mem.indexOf(u8, checked.diagnostics[0].message, "nested deeper than I can analyse") != null);
            try testing.expect(std.mem.indexOf(u8, checked.diagnostics[0].message, "will not help here") != null);
        }

        // ┌─────────────────────────────────────────┐
        // │ VERIFY SIDE EFFECTS                     │
        // └─────────────────────────────────────────┘
        try testing.expectEqualStrings("", checked.stdout);
    }
}

test "a pathologically nested expression is EMITTED without a stack overflow" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The parser accepts `Parse.max_depth` levels (language.md §10), and
    // both halves of codegen — lowering to `JsIr` and printing it — walk
    // that tree by recursion. 4 000 frames do not fit in the 8 MiB a main
    // thread gets, so `beni build` runs the emit phase on a thread with the
    // stack the checker uses. A segfault here would be the one failure mode
    // the house rules do not permit.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    const depth = 4000;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    const gpa = testing.allocator;
    try source.appendSlice(gpa, "import Node exposing (Program)\n\n\nf : Int -> Int\nf x =\n    x\n\n\nbig : Int\nbig =\n    ");
    for (0..depth) |_| try source.appendSlice(gpa, "f (");
    try source.appendSlice(gpa, "1");
    for (0..depth) |_| try source.append(gpa, ')');
    try source.appendSlice(gpa, "\n\n\nmain : Program\nmain =\n    Node.print \"ok\"\n");
    try w.write("Main.beni", source.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.runWith(&.{ "build", "--platform=node", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stderr);
    try testing.expect(w.exists("out/Main.mjs"));
}

test "600 modules check identically at every worker count, twice each" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The DAG-parallel checker (checker.md §4.4) is where determinism can
    // break: modules finish in whatever order the scheduler hands them out,
    // and anything keyed by completion would reorder here. A wide project
    // with a deep spine through it, half of whose modules have an error, is
    // the shape that would show it — 200 leaves that may all run at once,
    // and a 200-long chain that may not.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const leaves = 200;
    const chain_len = 200;
    var buffer: [256]u8 = undefined;
    for (0..leaves) |i| {
        const path = try std.fmt.bufPrint(&buffer, "src/Leaf/M{d}.beni", .{i});
        var body: std.Io.Writer.Allocating = .init(testing.allocator);
        defer body.deinit();
        // Every third module has a type error, so the diagnostic ORDER is
        // observable and not just the exit code.
        if (i % 3 == 0) {
            try body.writer.print("pub v{d} : Int\nv{d} =\n    \"not an int\"\n", .{ i, i });
        } else {
            try body.writer.print("pub v{d} : Int\nv{d} =\n    {d}\n", .{ i, i, i });
        }
        try w.write(path, body.written());
    }
    for (0..chain_len) |i| {
        const path = try std.fmt.bufPrint(&buffer, "src/Chain/C{d}.beni", .{i});
        var body: std.Io.Writer.Allocating = .init(testing.allocator);
        defer body.deinit();
        if (i == 0) {
            try body.writer.writeAll("pub step0 : Int -> Int\nstep0 n =\n    n + 1\n");
        } else {
            try body.writer.print(
                "import Chain.C{d} exposing (step{d})\n\n\npub step{d} : Int -> Int\nstep{d} n =\n    step{d} n\n",
                .{ i - 1, i - 1, i, i, i - 1 },
            );
        }
        try w.write(path, body.written());
    }

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const jobs = [_][]const u8{ "--jobs=1", "--jobs=2", "--jobs=4", "--jobs=8" };
    var first_stderr: ?[]const u8 = null;
    var first_count: usize = 0;

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    for (jobs) |j| {
        for (0..2) |_| {
            const r = try w.runWith(&.{ "check", "--diagnostics=json", j, "src" }, .{ .raw_diagnostics = true });
            if (r.term != .exited) {
                std.debug.print("{s} did not exit normally: {any}\n", .{ j, r.term });
                return error.CompilerDiedFromSignal;
            }
            try testing.expectEqual(@as(u8, 1), r.exit_code);
            try testing.expectEqualStrings("", r.stdout);
            if (first_stderr) |expected| {
                testing.expectEqualStrings(expected, r.stderr) catch |err| {
                    std.debug.print("{s} differs from --jobs=1\n", .{j});
                    return err;
                };
            } else {
                first_stderr = try testing.allocator.dupe(u8, r.stderr);
                first_count = std.mem.count(u8, r.stderr, "\"code\"");
            }
        }
    }
    defer if (first_stderr) |s| testing.allocator.free(s);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Every third leaf, and nothing else: the chain checks clean, so a
    // scheduler that skipped or double-counted a module would show up as a
    // different number here and not merely as a different order.
    try testing.expectEqual(@as(usize, (leaves + 2) / 3), first_count);
}

// ---------------------------------------------------------------------------
// Degenerate constraint accumulation
// ---------------------------------------------------------------------------

/// The static-dispatch counters `--self-profile` writes at exit, for one run
/// (`src/Profile.zig`). They are the only deterministic window the binary
/// gives on the solver's bookkeeping, and a complexity claim needs a counter
/// rather than a clock.
const ChainCounters = struct {
    obligations: u64 = 0,
    constraints_created: u64 = 0,
    constraints_merged: u64 = 0,
    constraints_deferred: u64 = 0,
    constraints_discharged: u64 = 0,
    constraints_promoted: u64 = 0,
};

/// Check a chain of `links` unannotated declarations, each adding one method
/// to the set the one before it inferred, and return the counters.
///
/// `f1 x = ( x.m1 x, x )` and `fk x = ( x.mk x, f(k-1) x )`: no operator, no
/// literal and no import, so `--core-root=nocore` holds and every number
/// below is this file's alone.
fn constraintChainCounters(w: *World, links: usize, trace: []const u8, source_path: []const u8) !ChainCounters {
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    const out = &source.writer;
    for (1..links + 1) |i| {
        if (i != 1) try out.writeAll("\n");
        try out.print("pub f{d} x =\n", .{i});
        if (i == 1) {
            try out.writeAll("    ( x.m1 x, x )\n");
        } else {
            try out.print("    ( x.m{d} x, f{d} x )\n", .{ i, i - 1 });
        }
    }
    try w.write(source_path, source.written());
    try w.write("nocore/PLACEHOLDER", "");

    const flag = try std.fmt.allocPrint(testing.allocator, "--self-profile={s}", .{trace});
    defer testing.allocator.free(flag);
    const r = try w.run(&.{ "check", flag, "--core-root=nocore", "--jobs=1", source_path });
    if (r.term != .exited) {
        std.debug.print("did not exit normally: {any}\n", .{r.term});
        return error.CompilerDiedFromSignal;
    }
    try testing.expectEqual(@as(u8, 0), r.exit_code);
    try testing.expectEqualStrings("", r.stdout);
    // Every link is an unannotated `pub` declaration whose inferred scheme
    // really does carry a `where` suffix, so since A.83 each one warns —
    // one message per link, all of them §10.9's, and nothing else. Asserted
    // rather than allowed: an `error` appearing here would mean the chain
    // stopped being the clean input this measurement is taken on.
    try testing.expectEqual(links, r.diagnostics.len);
    for (r.diagnostics) |d| {
        try testing.expectEqual(diagnostic.Code.ambiguous_method_receiver, d.code);
        try testing.expectEqual(diagnostic.Severity.warning, d.severity);
    }

    const Event = struct {
        name: []const u8,
        ph: []const u8,
        args: struct {
            obligations: ?u64 = null,
            constraints_created: ?u64 = null,
            constraints_merged: ?u64 = null,
            constraints_deferred: ?u64 = null,
            constraints_discharged: ?u64 = null,
            constraints_promoted: ?u64 = null,
        },
    };
    const text = try w.read(trace);
    const parsed = try std.json.parseFromSlice(
        struct { traceEvents: []Event },
        testing.allocator,
        text,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    var counters: ChainCounters = .{};
    for (parsed.value.traceEvents) |e| {
        if (!std.mem.eql(u8, e.ph, "C")) continue;
        inline for (@typeInfo(ChainCounters).@"struct".fields) |f| {
            if (std.mem.eql(u8, e.name, f.name)) @field(counters, f.name) = @field(e.args, f.name).?;
        }
    }
    return counters;
}

test "an unannotated constraint chain costs one merge per link, not one per constraint" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Link k of an unannotated chain accumulates k method constraints, so a
    // chain of n carries n(n+1)/2 of them and that quadratic is the FEATURE
    // (`plans/static-dispatch-spike.md` §7 M2). What is not the feature is a
    // third factor on top of it: folding each deferred constraint back onto
    // its own set rebuilt the whole set, so link k copied k constraints k
    // times and `beni check` went CUBIC in time and memory — 51 ms / 53 MB
    // at n = 100, 3.1 s / 3.3 GB at n = 400, and at n = 1000 a process
    // killed at 29 GiB with no diagnostic (A.81).
    //
    // The counter says it and a clock does not: `constraints_merged` counts
    // set rebuilds, and it is one per link when the fold is a no-op and
    // n(n+1)/2 + n - 1 when it is not. At n = 64 that is 63 against 2 143.
    //
    // 32 and 64, not 64 and 128, since A.83: a chain of 128 links promotes
    // 65 constraints at link 65 and is `too_many_inferred_constraints` from
    // there on (§10.11), which is a different measurement. 64 is the longest
    // chain the cap still accepts whole, so it is still the widest set the
    // fold can be asked to copy, and the growth assertion below is still
    // what the guard has to hold.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const links = 32;

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const one = try constraintChainCounters(&w, links, "one.json", "Chain.beni");
    const two = try constraintChainCounters(&w, 2 * links, "two.json", "Longer.beni");

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // Every counter, because the cheap way to make the merges linear is to
    // stop registering the obligations — and then `beni` would emit calls
    // an evidence argument short (A.57). The obligations, the deferrals and
    // the promotions must stay at n(n+1)/2 exactly while the merges go
    // linear. Nothing is discharged: no receiver is ever a concrete type.
    try testing.expectEqualDeep(ChainCounters{
        .obligations = links * (links + 1) / 2,
        .constraints_created = links,
        .constraints_merged = links - 1,
        .constraints_deferred = links * (links + 1) / 2,
        .constraints_discharged = 0,
        .constraints_promoted = links * (links + 1) / 2,
    }, one);
    try testing.expectEqualDeep(ChainCounters{
        .obligations = 2 * links * (2 * links + 1) / 2,
        .constraints_created = 2 * links,
        .constraints_merged = 2 * links - 1,
        .constraints_deferred = 2 * links * (2 * links + 1) / 2,
        .constraints_discharged = 0,
        .constraints_promoted = 2 * links * (2 * links + 1) / 2,
    }, two);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // Doubling the chain doubles the rebuilds and no more. Stated as a
    // growth as well as a value, because the two literals above could both
    // be re-blessed to whatever the compiler does today while this cannot.
    try testing.expectEqual(one.constraints_merged * 2 + 1, two.constraints_merged);
}

test "a chain past the inferred-constraint cap reports a bounded number of errors and finishes" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // static-dispatch-spike.md §6.4 and §10.11, A.83. The cap is not only a
    // bound on one message: a declaration over it promotes NOTHING, which is
    // what stops the accumulation reaching the next link. Link 65 is
    // reported and promotes nothing, so link 66 starts again from one
    // constraint and the chain costs one error per 65 links instead of the
    // n(n+1)/2 constraints and 3.7 GB report 19 §3 measured at n = 3000.
    //
    // 300 links, so the recovery has to happen four times: the assertion is
    // the EXACT count and the EXACT declarations, because "a bounded number"
    // is only a claim if the bound is written down. Same shape as the A.81
    // scenario above — no operator, no literal, no import, so
    // `--core-root=nocore` holds and every number here is this file's.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const links = 300;
    // 65: the 64 the cap allows, plus the one that is over it.
    const period = 65;

    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    const out = &source.writer;
    for (1..links + 1) |i| {
        if (i != 1) try out.writeAll("\n");
        try out.print("pub f{d} x =\n", .{i});
        if (i == 1) {
            try out.writeAll("    ( x.m1 x, x )\n");
        } else {
            try out.print("    ( x.m{d} x, f{d} x )\n", .{ i, i - 1 });
        }
    }
    try w.write("Chain.beni", source.written());
    try w.write("nocore/PLACEHOLDER", "");

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "--core-root=nocore", "--jobs=1", "Chain.beni" });
    if (r.term != .exited) {
        std.debug.print("did not exit normally: {any}\n", .{r.term});
        return error.CompilerDiedFromSignal;
    }

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 1), r.exit_code);
    // One message per declaration and no more: ⌊300/65⌋ = 4 declarations are
    // over the cap and the other 296 are unannotated `pub` declarations
    // whose interface really did acquire a suffix (§10.9).
    try testing.expectEqual(@as(usize, links), r.diagnostics.len);
    var capped: usize = 0;
    for (r.diagnostics) |d| {
        switch (d.code) {
            .too_many_inferred_constraints => {
                try testing.expectEqual(diagnostic.Severity.@"error", d.severity);
                capped += 1;
                // Declaration k occupies three lines — `pub fk x =`, its
                // body, and the blank separator — so link `period * capped`
                // starts at line `3 * period * capped - 2`.
                try testing.expectEqual(@as(u32, @intCast(3 * period * capped - 2)), d.span.start.line);
                var name: [16]u8 = undefined;
                const decl = try std.fmt.bufPrint(&name, "`f{d}`", .{period * capped});
                try testing.expect(std.mem.indexOf(u8, d.message, decl) != null);
                // The count is the set the link would have promoted, which
                // is one over the cap every time — proof that the previous
                // capped link handed on nothing.
                try testing.expect(std.mem.indexOf(u8, d.message, "needs 65 methods") != null);
            },
            .ambiguous_method_receiver => try testing.expectEqual(diagnostic.Severity.warning, d.severity),
            else => {
                std.debug.print("unexpected code {t}: {s}\n", .{ d.code, d.message });
                return error.UnexpectedDiagnostic;
            },
        }
    }
    try testing.expectEqual(links / period, capped);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    // The bound is the message's, not the renderer's: only the first five
    // method names are named, whatever the count is, because printing all
    // 65 would be the 6.4 kB interface entry report 19 §3.1 reached with a
    // title on it.
    for (r.diagnostics) |d| {
        if (d.code != .too_many_inferred_constraints) continue;
        try testing.expect(std.mem.indexOf(u8, d.message, "The first 5 are ") != null);
        try testing.expect(d.message.len < 700);
    }
    try testing.expectEqualStrings("", r.stdout);
}

test "a monomorphic let helper used at `a` and `List a` is an infinite type within seconds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Queue row 76. A constrained `let` helper is monomorphic
    // (static-dispatch-spike.md §11), so `inner x y` and then
    // `inner [ x ] [ y ]` make `x ~ List x`. The occurs check waits for
    // generalisation (design §7 #3), and until then the method obligation on
    // that cyclic receiver asked for the element's method forever: 875f623
    // panicked after 2^20 rounds (about 10 s), and the row 72 tree grew a
    // million dispatch sites and never finished. The drain now asks whether
    // the receiver is cyclic every `Solver.cycle_check_depth` generations.
    // The limit is the assertion: the old panic took 10 s, a hang forever.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const bodies = [_][]const u8{
        "a == b",
        "[ a ] == [ b ]",
        "{ v = a } == { v = b }",
        "( a, 1 ) < ( b, 1 )",
    };
    for (bodies) |body| {
        var source: std.Io.Writer.Allocating = .init(testing.allocator);
        defer source.deinit();
        try source.writer.print(
            \\pairEq x y =
            \\    let
            \\        inner a b =
            \\            {s}
            \\    in
            \\    inner x y && inner [ x ] [ y ]
            \\
        , .{body});
        try w.write("Main.beni", source.written());

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const r = try w.runWith(&.{ "check", "Main.beni" }, .{ .timeout_ms = 8_000 });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        if (r.term != .exited) {
            std.debug.print("[{s}] did not exit normally: {any}\n", .{ body, r.term });
            return error.CompilerDiedFromSignal;
        }
        try testing.expectEqual(@as(u8, 1), r.exit_code);
        try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
        try testing.expectEqual(diagnostic.Code.infinite_type, r.diagnostics[0].code);
    }
}
