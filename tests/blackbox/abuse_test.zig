//! Abuse scenarios (docs/design/frontend.md §8,
//! .claude/skills/write-tests/SKILL.md "Abuse scenarios are first-class").
//!
//! Hostile and degenerate source is a supported input, not an edge case.
//! Nesting one level past a limit, every byte value there is, a symlink
//! that points at its own parent: each must produce a diagnostic or a clean
//! pass — never a panic, never a hang, never a partial write. Every scenario
//! here therefore asserts four things beyond the diagnostics:
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
//! The inputs are BUILT HERE, not checked in: the bytes are easier to trust
//! when the test says how they were made. What is frozen into
//! `bench/pathological/` is the small, slow subset (see that
//! directory's README); the giant ones are generator cases in
//! `bench/gen.zig`.
//!
//! Each scenario reaches one guard, recovery path or fixed defect that no
//! corpus fixture reaches. A limit the corpus already pins — the parser's
//! nesting guard in `parse/bad/NestingTooDeep`, the checker's in
//! `check/depth/`, deep derived comparisons in `run/DerivedDeep*` — is not
//! repeated here.
//!
//! Peak memory is asserted OUTSIDE this file: measuring a child's RSS
//! portably from a test means polling `/proc`, which is a Linux-only race.
//! The numbers in `bench/README.md` come from `getrusage(RUSAGE_CHILDREN)`
//! around each run; here the claim is the one a test can make honestly —
//! it finished, and it finished cleanly.
//!
//! A scenario over a limit uses the smallest input that reaches it: one
//! level, one link or one entry past the cap, not ten times past it.

const std = @import("std");
const diagnostic = @import("diagnostic");
const world = @import("world.zig");
const World = world.World;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const support = @import("abuse_support.zig");
const expectExited = support.expectExited;
const chain = support.chain;
const nested = support.nested;

// ---------------------------------------------------------------------------
// Deep nesting
// ---------------------------------------------------------------------------

test "a record literal nested to the parser's limit checks and compares, one past it is one nesting_too_deep" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A record literal spends one depth unit per level in the solver
    // (`Solve.solveFields`), not two (the literal and its fields'
    // conjunction), or the solver would say NESTING TOO DEEP at about 2 100
    // levels where the parser accepts 4 095. So the parser's own limit is
    // the one limit: 4 095 levels check, and
    // compare (derivation, unification and resolution all that deep), and
    // 4 096 is the parser's one refusal.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const gpa = testing.allocator;
    for ([_]usize{ 4095, 4096 }) |depth| {
        const record = try nested(gpa, "{ x = ", "1", ", y = 0 }", depth);
        defer gpa.free(record);
        const source = try std.mem.concat(gpa, u8, &.{ record, "\n\nsame =\n    main == main\n" });
        defer gpa.free(source);
        try w.write(if (depth == 4095) "Limit.beni" else "Past.beni", source);
    }

    {
        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const limit = try w.run(&.{ "check", "--no-cache", "Limit.beni" });
        const past = try w.run(&.{ "check", "--no-cache", "Past.beni" });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        try expectExited(limit, 0);
        try testing.expectEqual(@as(usize, 0), limit.diagnostics.len);
        try expectExited(past, 1);
        // The `1` inside the 4 096th `{ x = ` (six bytes each, after `main =`):
        // the first token one level too deep.
        try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{nestingTooDeep("Past.beni", 2, 5 + 4096 * 6, 1)}, past.diagnostics);
    }
}

test "a recursive type of 4 096 parameters compares past the derived depth limit, positional" {
    // 4 096 evidence parameters, positional: a call charges 1 + (2 × 4 096
    // + 4 097) / 32 = 385 units, so the third level is past the limit and
    // continues from the explicit stack, whose steps take the evidence as
    // one array. Without the charge per 32 parameters the frames are so big
    // that Node's `==` overflowed about 13 levels down; 20 levels threw
    // `RangeError` with a charge of one unit a call.
    try wideRecursiveTypeCompares(4096, "20");
}

test "a recursive type of 4 097 parameters compares past the derived depth limit, wide" {
    // 4 097 parameters take the evidence as one array, and a call charges
    // 1 + 4 098 / 32 = 129 units for the positions: the fifth level is the
    // first past the limit of 400, so 5 levels reach the explicit stack in
    // the array form and 4 do not.
    try wideRecursiveTypeCompares(4097, "5");
}

/// A recursive type of `n` parameters, `levels` deep, compared.
fn wideRecursiveTypeCompares(n: usize, levels: []const u8) !void {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The two evidence forms of static-dispatch-spike.md §9.2: 4 096
    // parameters is the widest POSITIONAL derived function, 4 097 the
    // narrowest that takes them as one array. Every parameter is a
    // position. The recursive position is the FIRST, so the comparison
    // recurses into it: in the last position it would be a tail self-call,
    // which loops and never grows the depth (`backend.md` §4, *Derived
    // comparisons do not grow the native stack*).
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const gpa = testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    try source.appendSlice(gpa, "import Node exposing (Program)\n\n\ntype W");
    try params(gpa, &source, n, " p{d}");
    try source.appendSlice(gpa, "\n    = Cell (W");
    try params(gpa, &source, n, " p{d}");
    try source.appendSlice(gpa, ")");
    try params(gpa, &source, n, " p{d}");
    try source.appendSlice(gpa, "\n    | End\n\n\ncell : Int, W");
    try params(gpa, &source, n, " Int");
    try source.appendSlice(gpa, " -> W");
    try params(gpa, &source, n, " Int");
    try source.appendSlice(gpa, "\ncell k rest =\n    Cell rest k");
    try params(gpa, &source, n - 1, " 0");
    try source.appendSlice(gpa, "\n\n\nbuild : Int, Int, W");
    try params(gpa, &source, n, " Int");
    try source.appendSlice(gpa, " -> W");
    try params(gpa, &source, n, " Int");
    const tail = try std.mem.replaceOwned(u8, gpa,
        \\
        \\build n last acc =
        \\    if n == 0 then
        \\        acc
        \\
        \\    else
        \\        build (n - 1) last (cell (if n == 1000 then last else n) acc)
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
        \\        [ show (build 1000 1 End == build 1000 1 End)
        \\        , show (build 1000 1 End == build 1000 2 End)
        \\        , show (build 1000 1 End < build 1000 2 End)
        \\        ]
        \\
    , "1000", levels);
    defer gpa.free(tail);
    try source.appendSlice(gpa, tail);
    try w.write("Main.beni", source.items);

    {
        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const r = try w.buildAndRun(&.{ "--no-cache", "Main.beni" });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        // The cell that differs is the innermost one (`n == levels` is
        // built first), so every comparison walks every level.
        try testing.expectEqual(@as(u8, 0), r.build.exit_code);
        try testing.expectEqualStrings("", r.build.stderr);
        try testing.expectEqualStrings("True\nFalse\nTrue\n", r.program.?.stdout);
        try testing.expectEqualStrings("", r.program.?.stderr);
        try testing.expectEqual(@as(u8, 0), r.program.?.exit_code);
    }
}

/// `count` copies of `pattern`, whose one `{d}` is the copy's 1-based index.
fn params(gpa: Allocator, out: *std.ArrayList(u8), count: usize, comptime pattern: []const u8) !void {
    for (1..count + 1) |i| {
        if (comptime std.mem.indexOf(u8, pattern, "{d}") != null) {
            try out.print(gpa, pattern, .{i});
        } else {
            try out.appendSlice(gpa, pattern);
        }
    }
}

test "recursion THROUGH a hand-written parametric method still grows the native stack, the stated exclusion" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The one cycle the explicit stack does not cover (backend.md §4, *Derived comparisons
    // do not grow the native stack*, "What it does not cover"). `Box.eq`
    // is written by hand and takes `a.eq` as evidence; `T` recurses through
    // it, so every level is `T$$eq → Box$eq → T$$eq`. A hand-written method
    // cannot hand back steps, so `T` is emitted as a leaf, with no depth,
    // and 100 000 levels throw. This pins TODAY's behaviour so that a change
    // to it is seen: when the exclusion is lifted, this scenario flips and
    // the spec changes with it. 100 levels are fine.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try w.write("Box.beni",
        \\pub type Box a
        \\    = Box a
        \\
        \\
        \\pub eq : Box a, Box a -> Bool
        \\    where a.eq : a, a -> Bool
        \\eq left right =
        \\    case left of
        \\        Box x ->
        \\            case right of
        \\                Box y ->
        \\                    x == y
        \\
    );
    for ([_][]const u8{ "100", "100000" }) |depth| {
        const gpa = testing.allocator;
        const source = try std.mem.concat(gpa, u8, &.{
            \\import Box exposing (Box)
            \\import Node exposing (Program)
            \\
            \\
            \\type T
            \\    = T (Box T)
            \\    | E
            \\
            \\
            \\build : Int, T -> T
            \\build n acc =
            \\    if n == 0 then
            \\        acc
            \\
            \\    else
            \\        build (n - 1) (T (Box acc))
            \\
            \\
            \\main : Program
            \\main =
            \\    Node.printLines
            \\        [ if build
            ,
            " ",
            depth,
            " E == build ",
            depth,
            " E then\n",
            \\            "True"
            \\
            \\          else
            \\            "False"
            \\        ]
            \\
        });
        defer gpa.free(source);
        try w.write("Main.beni", source);

        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const r = try w.buildAndRun(&.{ "--no-cache", "Box.beni", "Main.beni" });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        try testing.expectEqual(@as(u8, 0), r.build.exit_code);
        try testing.expectEqualStrings("", r.build.stderr);
        const program = r.program.?;
        if (std.mem.eql(u8, depth, "100")) {
            try testing.expectEqualStrings("True\n", program.stdout);
            try testing.expectEqual(@as(u8, 0), program.exit_code);
        } else {
            // The stack trace's frames and paths vary; the error does not.
            try testing.expectEqualStrings("", program.stdout);
            try testing.expectEqual(@as(u8, 1), program.exit_code);
            try testing.expect(std.mem.indexOf(u8, program.stderr, "RangeError: Maximum call stack size exceeded") != null);
        }
    }
}

test "the left-deep access and `?` spines the parser builds in a loop are depth-bounded too" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `r.a.a.a…` and `r????…` are assembled by LOOPS in the parser
    // (`parsePostfix`, `parseAccessChain`), not by recursion, so they cost
    // it no stack — but they are real tree depth, and every consumer that
    // walks the tree recurses along them. Before `Parse.max_depth` counted
    // them, an 8 KB file of `r.a.a.a…` segfaulted both `check` and `dump
    // --stage=ast`. 4 097 links each, one past the 4096 limit. The third
    // such loop, an operator chain, is `abuse_wide_test.zig`'s.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const cases = [_]struct { path: []const u8, head: []const u8, piece: []const u8, col: u32, width: u32 }{
        .{ .path = "Access.beni", .head = "f r =\n    r", .piece = ".a", .col = 8196, .width = 2 },
        .{ .path = "Question.beni", .head = "f r =\n    r", .piece = "?", .col = 4101, .width = 1 },
    };

    for (cases) |case| {
        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const source = try chain(testing.allocator, case.head, case.piece, 4_097);
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

test "an unterminated char, and an empty paren and brace, at EOF" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // Three ways to end a file in the middle of something that no
    // `parse/bad` fixture ends in: the lexer's char literal cut off by the
    // end of the file, and the parser meeting the end where an expression
    // or a field name must come. An unterminated string, an interpolation
    // and a delimiter closed by nothing after its content are
    // `parse/bad/*AtEof`. Each is its own project so the spans name a file
    // of its own, and each is checked for the whole diagnostic list AND for
    // `fmt` leaving its bytes alone.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    const cases = [_]struct { path: []const u8, source: []const u8, want: []const diagnostic.Diagnostic }{
        .{ .path = "Char.beni", .source = "main = 'a", .want = &.{.{
            .code = .invalid_char_literal,
            .severity = .@"error",
            .span = .{ .file = "Char.beni", .start = .{ .line = 1, .col = 8 }, .end = .{ .line = 1, .col = 10 } },
            .title = "INVALID CHAR LITERAL",
            .message = "I got to the end of the line without seeing the closing `'` of this\ncharacter literal.\n\nA character literal holds exactly one character: `'a'`, `'\\n'`, `'\\u{1F600}'`.",
        }} },
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

// ---------------------------------------------------------------------------
// Patterns and emitted code nested to the limits
// ---------------------------------------------------------------------------

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
    // 2 100 levels charge 4 200, past the parser's limit, and must be
    // exactly one `nesting_too_deep`; charged once a level they would pass.
    // A legal pattern past the checker's own depth guard is
    // `check/depth/PatternNestDeep`.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    const out = &source.writer;
    try out.writeAll("f m =\n    case m of\n        ");
    for (0..2_100) |_| try out.writeAll("Just (");
    try out.writeAll("x");
    for (0..2_100) |_| try out.writeAll(")");
    try out.writeAll(" ->\n            x\n");
    try w.write("Deep.beni", source.written());

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "Deep.beni" });
    const ast = try w.runWith(&.{ "dump", "--stage=ast", "Deep.beni" }, .{ .raw_diagnostics = true });
    const bir = try w.runWith(&.{ "dump", "--stage=bir", "Deep.beni" }, .{ .raw_diagnostics = true });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    // A dump prints the tree it has and exits 1 for the error on stderr
    // (`frontend.md` §1).
    for ([_]world.Result{ ast, bir }) |r| {
        if (r.term != .exited) {
            std.debug.print("dump did not exit normally: {any}\n", .{r.term});
            return error.CompilerDiedFromSignal;
        }
        try testing.expectEqual(@as(u8, 1), r.exit_code);
        try testing.expect(r.stdout.len != 0);
    }
    // The nesting error, and the consequence of the recovery it did: the
    // truncated pattern never binds `x`, so the branch body cannot find it.
    // Two messages about one mistake, which is what a pattern the parser had
    // to abandon looks like.
    try expectExited(checked, 1);
    try testing.expectEqual(@as(usize, 2), checked.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.nesting_too_deep, checked.diagnostics[0].code);
    try testing.expectEqual(diagnostic.Code.unbound_variable, checked.diagnostics[1].code);
}

test "a pathologically nested expression is EMITTED without a stack overflow, and RUNS" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The parser accepts `Parse.max_depth` levels (language.md §10), and
    // both halves of codegen — lowering to `JsIr` and printing it — walk
    // that tree by recursion. 4 000 frames do not fit in the 8 MiB a main
    // thread gets, so `beni build` runs the emit phase on a thread with the
    // stack the checker uses. A segfault here would be the one failure mode
    // the house rules do not permit.
    //
    // And the module has to LOAD: 4 000 nested calls printed as
    // written are past every engine's parser — node throws `RangeError`
    // from about 1 550 — so `Lower` binds the chain to a `const` every
    // `nesting.spill` units (`backend.md` §4) and the program runs. The
    // development build is enough: `--release` runs on the same spilled
    // `JsIr`, and inlines only atoms and member chains, so it never folds a
    // spilled call back into its user.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    const depth = 4000;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    const gpa = testing.allocator;
    try source.appendSlice(gpa, "import Node exposing (Program)\n\n\nf : Int -> Int\nf x =\n    x + 1\n\n\nbig : Int\nbig =\n    ");
    for (0..depth) |_| try source.appendSlice(gpa, "f (");
    try source.appendSlice(gpa, "1");
    for (0..depth) |_| try source.append(gpa, ')');
    try source.appendSlice(gpa, "\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt big ]\n");
    try w.write("Main.beni", source.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.buildAndRun(&.{ "--no-cache", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expectEqual(@as(u8, 0), r.build.exit_code);
    try testing.expectEqualStrings("", r.build.stderr);
    try testing.expectEqualStrings("4001\n", r.program.?.stdout);
    try testing.expectEqualStrings("", r.program.?.stderr);
    try testing.expectEqual(@as(u8, 0), r.program.?.exit_code);
}

test "functions nested past what Firefox parses are one nesting_too_deep from build, and 119 run" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `(\x0 -> (\x1 -> … 1) 1) 1`: a function per level, which JavaScript
    // can only nest — there is no flat form short of closure conversion
    // (`backend.md` §4, *Emitted JavaScript nests only as deep as the
    // source*). SpiderMonkey refuses a 252nd nested scope whatever the
    // stack, and 171 functions with declaring bodies in a module. So the
    // emitter writes at most 128 nested scopes. Every dozen
    // levels or so a lambda whose body has grown tall is bound to a `const`
    // (`lambda_spill`), and that body then declares something — one more
    // scope — so 119 functions build and run, and 120 are refused by name,
    // with nothing written, rather than building a module that throws
    // `InternalError` at load in Firefox.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    for ([_]usize{ 119, 120 }) |depth| {
        var source: std.ArrayList(u8) = .empty;
        try source.appendSlice(a, "import Node exposing (Program)\n\n\nxs : Int\nxs =\n    ");
        for (0..depth) |i| try source.print(a, "(\\x{d} -> ", .{i});
        try source.appendSlice(a, "1");
        for (0..depth) |_| try source.appendSlice(a, ") 1");
        try source.appendSlice(a, "\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt xs ]\n");
        try w.write("Main.beni", source.items);

        if (depth == 119) {
            // ┌─────────────────────────────────┐
            // │ EXECUTE                         │
            // └─────────────────────────────────┘
            const ran = try w.buildAndRun(&.{ "--no-cache", "Main.beni" });

            // ┌─────────────────────────────────┐
            // │ VERIFY OUTPUT                   │
            // └─────────────────────────────────┘
            try testing.expectEqual(@as(u8, 0), ran.build.exit_code);
            try testing.expectEqualStrings("", ran.build.stderr);
            try testing.expectEqualStrings("1\n", ran.program.?.stdout);
            continue;
        }

        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const r = try w.run(&.{ "build", "--no-cache", "--platform=node", "--out=deep", "Main.beni" });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        try expectExited(r, 1);
        try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
            .code = .nesting_too_deep,
            .severity = .@"error",
            .span = .{ .file = "Main.beni", .start = .{ .line = 6, .col = 5 }, .end = .{ .line = 6, .col = 6 } },
            .title = "NESTING TOO DEEP",
            .message = "`xs` nests too deeply to run in a browser.\n\nIts JavaScript would nest about 353 levels and 131 scopes deep. Browser engines\nparse nested code by recursion and give up not far past that — Chrome at 1 290\nnested calls, 644 nested `if` blocks and 553 nested functions, Firefox at 251\nnested scopes — so I write at most 512 levels and 128 scopes\n(`docs/design/backend.md` §4).\n\nLong lists, operator chains, pipelines and `else if` chains come out flat\nhowever long they are. What cannot is nesting the program writes itself,\nhundreds deep: functions inside functions, or `case`s and `if`s inside one\nanother through the arguments of calls. Moving the inner parts into\ntop-level declarations of their own fixes it.",
        }}, r.diagnostics);

        // ┌─────────────────────────────────────┐
        // │ VERIFY SIDE EFFECTS                 │
        // └─────────────────────────────────────┘
        try testing.expect(!w.exists("deep"));
    }
}

test "a wide project with a chain of imports checks identically at one worker and at eight, twice each" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The DAG-parallel checker (checker.md §4.4) is where determinism can
    // break: modules finish in whatever order the scheduler hands them out,
    // and anything keyed by completion would reorder here. The other
    // `--jobs` determinism scenarios check modules that import nothing, or
    // one or two that do. A wide project with a spine of imports through
    // it, a third of whose leaves have an error, is the shape that would
    // show it — 24 leaves, three times the workers, that may all run at
    // once, and a 24-long chain that may not.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const leaves = 24;
    const chain_len = 24;
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
    const jobs = [_][]const u8{ "--jobs=1", "--jobs=8" };
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

// The checker records obligations as rows on their variables
// (`checker-v2.md` §4.5), and `perf_test.zig`'s obligation-row scenarios
// hold those linear.

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
    // 131 links, just past two periods, so the recovery has to happen once
    // and the cap is met again after it: the assertion is the EXACT count
    // and the EXACT declarations, because "a bounded number" is only a claim
    // if the bound is written down. No operator, no literal, no import, so
    // `--core-root=nocore` holds and every number here is this file's.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const links = 131;
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
    // One message per declaration and no more: ⌊131/65⌋ = 2 declarations are
    // over the cap and the other 129 are unannotated `pub` declarations
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

test "a recursive alias used in an annotation is one RECURSIVE ALIAS, not an expansion" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // An annotation must not expand `A = ( A, A )` once resolution has
    // refused it: the expansion would double per level up to the builder's
    // depth bound of 512. The builder refuses an alias met inside its own
    // expansion (`Types.Builder.expanding`), and an alias already expanded
    // in a read is one variable wherever the read meets it again
    // (`Types.Builder.aliases`) — either alone keeps it linear, and without
    // both the check does not finish. So every form is one message at
    // once: the alias met directly inside itself, and met again through a
    // second alias further out. The 3 s limit is the assertion that nothing
    // grew: the check takes milliseconds.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const sources = [_][]const u8{
        "type alias A =\n    ( A, A )\n\n\nf : A -> Int\nf p =\n    0\n",
        "type alias A =\n    ( B, B )\n\n\ntype alias B =\n    { p : A }\n\n\nf : A -> Int\nf p =\n    0\n",
    };
    for (sources) |source| {
        try w.write("Main.beni", source);

        // ┌─────────────────────────────────────────┐
        // │ EXECUTE                                 │
        // └─────────────────────────────────────────┘
        const r = try w.runWith(&.{ "check", "--no-cache", "--jobs=1", "Main.beni" }, .{ .timeout_ms = 3_000 });

        // ┌─────────────────────────────────────────┐
        // │ VERIFY OUTPUT                           │
        // └─────────────────────────────────────────┘
        try expectExited(r, 1);
        try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
        try testing.expectEqualDeep(diagnostic.Diagnostic{
            .code = .recursive_alias,
            .severity = .@"error",
            .span = .{ .file = "Main.beni", .start = .{ .line = 1, .col = 12 }, .end = .{ .line = 1, .col = 13 } },
            .title = "RECURSIVE ALIAS",
            .message = "The type alias `A` refers to itself.\n\nAn alias is a spelling for the type it names, so one that mentions itself —\n" ++
                "directly, or through other aliases — has no expansion. Make it a `type` with a\n" ++
                "constructor instead; that is what gives recursion somewhere to stop.",
        }, r.diagnostics[0]);
    }
}

test "a flat let past what a summed budget allows is accepted: its bindings are siblings" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A `let` of 5 000 bindings `x{i} = x{i-1} + 1` once got 907 NESTING TOO
    // DEEP messages, each "nested more than 4096 levels deep" about a block
    // two deep: the parser's per-declaration budget summed the chain links of
    // every binding, one a binding. A `let`'s bindings and body, and a
    // `case`'s branches, are siblings (`Parse.Siblings`) and charge the
    // deepest of them. 4 200 bindings, so a budget summed over them would be
    // spent. Past the parser nothing is deep: a `let` lowers to ONE node
    // holding its bindings, so `check` is the whole claim.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "foo : Int -> Int\nfoo x0 =\n    let\n");
    for (1..4_201) |i| try src.print(gpa, "        x{d} =\n            x{d} + 1\n\n", .{ i, i - 1 });
    try src.appendSlice(gpa, "    in\n    x4200\n");
    try w.write("Main.beni", src.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const checked = try w.run(&.{ "check", "--no-cache", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(checked, 0);
    try testing.expectEqualSlices(diagnostic.Diagnostic, &.{}, checked.diagnostics);
}

test "a flat let past the budget in ONE binding is still one nesting_too_deep" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The other half: siblings do not reset what a single binding spends.
    // One binding of 4 097 `+` links is past `Parse.max_depth` and
    // is refused once, exactly as a top-level body would be.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "foo : Int -> Int\nfoo x0 =\n    let\n        a =\n            1\n\n        b =\n            x0");
    for (0..4_097) |_| try src.appendSlice(gpa, " + 1");
    try src.appendSlice(gpa, "\n    in\n    b\n");
    try w.write("Main.beni", src.items);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const r = try w.run(&.{ "check", "--no-cache", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(r, 1);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.nesting_too_deep, r.diagnostics[0].code);
}

test "a case over every constructor of a 2 000-constructor type checks, and the other answers are linear too" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `C{i} x -> x` for every constructor of `type T = C0 Int | … | C1999
    // Int` must not be CASE TOO BIG TO CHECK: were a constructor with
    // arguments not a key of the lookup table, the general relation would
    // specialise the whole matrix per branch and per alternative, n²
    // against a budget sized for exponential matrices. `C x` with wildcard
    // arguments is a key, and `ColumnIndex` answers "which rows share this
    // head" in one pass. The same width must also answer a MISSING
    // constructor, a REDUNDANT branch and branches the table cannot take
    // (`C{i} 0`) in linear time.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const gpa = testing.allocator;
    const n = 2_000;
    const Variant = enum { every, missing_last, redundant, literals_then_default };
    for ([_]Variant{ .every, .missing_last, .redundant, .literals_then_default }) |variant| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "type T\n    = C0 Int\n");
        for (1..n) |i| try src.print(gpa, "    | C{d} Int\n", .{i});
        try src.appendSlice(gpa, "\n\nf : T -> Int\nf t =\n    case t of\n");
        const listed: usize = if (variant == .missing_last) n - 1 else n;
        for (0..listed) |i| switch (variant) {
            .literals_then_default => try src.print(gpa, "        C{d} 0 ->\n            0\n\n", .{i}),
            else => try src.print(gpa, "        C{d} x ->\n            x\n\n", .{i}),
        };
        switch (variant) {
            .redundant => try src.appendSlice(gpa, "        C7 y ->\n            y\n"),
            .literals_then_default => try src.appendSlice(gpa, "        _ ->\n            1\n"),
            .every, .missing_last => {},
        }
        try w.write("Main.beni", src.items);

        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const r = try w.runWith(&.{ "check", "--no-cache", "--jobs=1", "Main.beni" }, .{ .timeout_ms = 20_000 });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        const case_line = n + 6;
        switch (variant) {
            .every, .literals_then_default => {
                try expectExited(r, 0);
                try testing.expectEqualSlices(diagnostic.Diagnostic, &.{}, r.diagnostics);
            },
            .missing_last => {
                try expectExited(r, 1);
                try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
                const d = r.diagnostics[0];
                try testing.expectEqual(diagnostic.Code.missing_patterns, d.code);
                try testing.expectEqual(@as(u32, case_line), d.span.start.line);
                try testing.expect(std.mem.indexOf(u8, d.message, "\n    C1999 _\n") != null);
            },
            .redundant => {
                try expectExited(r, 1);
                try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
                const d = r.diagnostics[0];
                try testing.expectEqual(diagnostic.Code.redundant_pattern, d.code);
                try testing.expectEqual(@as(u32, case_line + 1 + 3 * n), d.span.start.line);
                try testing.expect(std.mem.startsWith(u8, d.message, "The 2001st pattern is redundant:"));
            },
        }
    }
}
