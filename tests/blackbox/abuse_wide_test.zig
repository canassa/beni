//! Abuse scenarios over WIDE inputs — records of 100 000 fields, nominal
//! payloads of 65 535, operator chains and list literals as wide as the
//! parser admits (wider than engines loaded until R2c) — split out of
//! `abuse_test.zig` on 2026-09-25 only so that the two run as separate
//! processes in parallel: together they were one
//! binary of about 80 s, the longest in `test-blackbox`
//! (`plans/checker-rewrite.md` §2.4, *Parts*). Everything `abuse_test.zig`'s
//! header says about what an abuse scenario asserts holds here.

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
// The equatable walk (CK-17, plans/checker-rewrite.md R1)
// ---------------------------------------------------------------------------

/// `r = { f1 = 1, …, f<n> = 1 }` with field `fn_at` a function (0: none),
/// then `same = <compare>` — `Basics.eq r r` or `r == r`.
fn wideRecord(gpa: std.mem.Allocator, n: usize, fn_at: usize, compare: []const u8) ![]u8 {
    var source: std.Io.Writer.Allocating = .init(gpa);
    errdefer source.deinit();
    const out = &source.writer;
    try out.writeAll("r =\n    { ");
    for (1..n + 1) |i| {
        if (i != 1) try out.writeAll(", ");
        if (i == fn_at) try out.print("f{d} = \\x -> x", .{i}) else try out.print("f{d} = 1", .{i});
    }
    try out.print(" }}\n\n\nsame : Bool\nsame =\n    {s}\n", .{compare});
    return source.toOwnedSlice();
}

test "Basics.eq on a 100 000-field record walks all of it: all Int is equatable, a function at field 99 999 is not" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The `equatable` walk's worklist was a fixed 256 entries, and a full
    // worklist answered "unknown", which `Basics.eq` accepted — so a function
    // in field 257 of a record compared structurally at run time (CK-17).
    // It is growable now, and never answers on width: the all-`Int` record
    // is accepted because every field was walked, and the function at field
    // 99 999 — the far end of the worklist — is found.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const all_int = try wideRecord(testing.allocator, 100_000, 0, "Basics.eq r r");
    defer testing.allocator.free(all_int);
    try w.write("AllInt.beni", all_int);
    const with_fn = try wideRecord(testing.allocator, 100_000, 99_999, "Basics.eq r r");
    defer testing.allocator.free(with_fn);
    try w.write("WithFn.beni", with_fn);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const ok = try w.run(&.{ "check", "--no-cache", "AllInt.beni" });
    const bad = try w.run(&.{ "check", "--no-cache", "WithFn.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(ok, 0);
    try testing.expectEqualSlices(diagnostic.Diagnostic, &.{}, ok.diagnostics);
    try expectExited(bad, 1);
    try testing.expectEqual(@as(usize, 1), bad.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.not_equatable, bad.diagnostics[0].code);
    // At the first argument of `Basics.eq`, on the last line.
    try testing.expectEqual(@as(u32, 7), bad.diagnostics[0].span.start.line);
    try testing.expectEqual(@as(u32, 15), bad.diagnostics[0].span.start.col);
}

/// A program printing `eq` or `ne` for `r == r`, where `r` has `n` fields.
fn wideEqProgram(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var source: std.Io.Writer.Allocating = .init(gpa);
    errdefer source.deinit();
    const out = &source.writer;
    try out.writeAll("import Node exposing (Program)\n\n\nr =\n    { ");
    for (1..n + 1) |i| {
        if (i != 1) try out.writeAll(", ");
        try out.print("f{d} = {d}", .{ i, i });
    }
    try out.writeAll(" }\n\n\nmain : Program\nmain =\n    Node.printLines [ if r == r then \"eq\" else \"ne\" ]\n");
    return source.toOwnedSlice();
}

test "== on a record builds and runs at every width, never a runtime exception" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `==` on a record DERIVES one function with a parameter per field, and a
    // JavaScript call that wide overflows the engine's stack: under Node 24
    // a 60 000- and a 65 530-field `r == r` built and then threw `RangeError`
    // (R1's review). Checker v1 therefore refused a derived record
    // comparison past `max_derived_record_fields`, 4 096, as `not_equatable`
    // (CK-79). The wide form takes the evidence as one array past 4 096
    // positions (`static-dispatch-spike.md` §9.2, CK-81), and checker v2
    // lifts the cap (`checker-v2.md` §11.2's D4 bullet, R8a): since the
    // cut-over (R11) the no-runtime-exception guarantee holds at every width
    // by building and RUNNING — at the old cap, one past it, and at the
    // widths that threw.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();

    for ([_]usize{ 4_096, 4_097, 65_530 }) |n| {
        const source = try wideEqProgram(testing.allocator, n);
        defer testing.allocator.free(source);
        try w.write("Wide.beni", source);

        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const ran = try w.buildAndRun(&.{ "--no-cache", "Wide.beni" });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        try expectExited(ran.build, 0);
        try testing.expectEqualStrings("", ran.build.stderr);
        try testing.expectEqual(@as(u8, 0), ran.program.?.exit_code);
        try testing.expectEqualStrings("eq\n", ran.program.?.stdout);
    }
}

// CK-79 (promoted from `tests/pending/`'s `scenario/CK-79` at the cut-over,
// R11): `==` and `<` on a record of 40 000 fields. The old checker capped a
// derived record `eq`/`compare` at `max_derived_record_fields` = 4 096
// (`not_equatable` and `no_methods_on_shape` past it, R1), because a derived
// function took one JavaScript parameter per field and V8 threw between
// 40 000 and 60 000. The wide form (`static-dispatch-spike.md` §9.2, CK-81)
// takes the evidence as one array past 4 096 positions, so R8a's checker
// lifts the cap (checker-v2.md §11.2's D4 bullet): the program builds, runs
// and prints its three answers; a refusal is the finding.
test "CK-79: `==` and `<` on a 40 000-field record build and run" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const n = 40_000;
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    const out = &text.writer;
    try out.writeAll("import Node exposing (Program)\n\n\nr =\n    { ");
    for (1..n + 1) |i| try out.print("{s}f{d} = {d}", .{ if (i == 1) "" else ", ", i, i });
    try out.print(" }}\n\n\nmain : Program\nmain =\n    Node.printLines [ if r == r then \"eq\" else \"ne\", if r == {{ r | f{d} = 0 }} then \"eq\" else \"ne\", if {{ r | f1 = 0 }} < r then \"lt\" else \"ge\" ]\n", .{n});
    try w.write("Main.beni", text.written());

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const ran = try w.buildAndRun(&.{ "--no-cache", "--jobs=1", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(ran.build, 0);
    try testing.expectEqualStrings("", ran.build.stderr);
    try testing.expectEqual(@as(u8, 0), ran.program.?.exit_code);
    try testing.expectEqualStrings("eq\nne\nlt\n", ran.program.?.stdout);
}

// CK-82 (promoted from `tests/pending/`'s `scenario/CK-82` at the cut-over,
// R11): a nominal payload record of 65 537 fields. The eager pass probed
// `T`'s derived `eq`, and v1's `Solve.derivedUse` cast the field count into
// the `u16` evidence count: a panic in Debug, whether or not anything
// compares `T`. 65 535 builds and runs (CK-81, below). 65 537 and not
// 65 536 since R8a's review: the record's structural row has one entry per
// field, so its last entry's index `k` is 65 536, one past what a `u16`
// `Dispatch.Param.k` holds (CK-109). On the Debug binary, whose safety
// checks are part of the claim. What is required is the program built and
// run, printing its two answers, or a refusal by name — exit 1 with
// diagnostics and not one of them `internal`; never a crash.
test "CK-82: a nominal payload of 65 537 fields checks, and builds and runs or is refused by name" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const n = 65_537;
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    const out = &text.writer;
    try out.writeAll("import Node exposing (Program)\n\n\ntype T =\n    T { ");
    for (1..n + 1) |i| try out.print("{s}f{d} : Int", .{ if (i == 1) "" else ", ", i });
    try out.writeAll(" }\n\n\nr =\n    { ");
    for (1..n + 1) |i| try out.print("{s}f{d} = {d}", .{ if (i == 1) "" else ", ", i, i });
    try out.print(" }}\n\n\nmain : Program\nmain =\n    Node.printLines [ if T r == T r then \"eq\" else \"ne\", if T r == T {{ r | f{d} = 0 }} then \"eq\" else \"ne\" ]\n", .{n});
    try w.write("Main.beni", text.written());

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.run(&.{ "build", "--no-cache", "--jobs=1", "--platform=node", "--out=out", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try testing.expect(built.term == .exited);
    if (built.exit_code == 0) {
        try testing.expectEqual(@as(usize, 0), built.diagnostics.len);
        const program = try w.node(world.entry_file);
        try testing.expectEqual(@as(u8, 0), program.exit_code);
        try testing.expectEqualStrings("eq\nne\n", program.stdout);
    } else {
        try expectExited(built, 1);
        try testing.expect(built.diagnostics.len != 0);
        for (built.diagnostics) |d| try testing.expect(d.code != .internal);
        // ┌─────────────────────────────────────┐
        // │ VERIFY SIDE EFFECTS                 │
        // └─────────────────────────────────────┘
        try testing.expect(!w.exists("out"));
    }
}

// ---------------------------------------------------------------------------
// Chains as long as their input is wide (CK-81)
// ---------------------------------------------------------------------------

/// `type T = T { f1 : Int, …, f<n> : Int }`, `r` a record of that shape, `s`
/// the same with field `f<n>` set to 0, and a `main` printing `T r == T r`,
/// `T r == T s`, `T s < T r`, `T r < T s` and `[ T r ] == [ T r ]`.
fn wideNominalProgram(gpa: Allocator, n: usize) ![]u8 {
    var source: std.Io.Writer.Allocating = .init(gpa);
    errdefer source.deinit();
    const out = &source.writer;
    try out.writeAll("import Node exposing (Program)\n\n\ntype T =\n    T { ");
    for (1..n + 1) |i| try out.print("{s}f{d} : Int", .{ if (i == 1) "" else ", ", i });
    try out.writeAll(" }\n\n\nr : { ");
    for (1..n + 1) |i| try out.print("{s}f{d} : Int", .{ if (i == 1) "" else ", ", i });
    try out.writeAll(" }\nr =\n    { ");
    for (1..n + 1) |i| try out.print("{s}f{d} = {d}", .{ if (i == 1) "" else ", ", i, i });
    try out.writeAll(" }\n\n\ns : { ");
    for (1..n + 1) |i| try out.print("{s}f{d} : Int", .{ if (i == 1) "" else ", ", i });
    try out.print(" }}\ns =\n    {{ r | f{d} = 0 }}\n\n\n", .{n});
    try out.writeAll(
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
        \\    Node.printLines [ show (T r == T r), show (T r == T s), show (T s < T r), show (T r < T s), show ([ T r ] == [ T r ]) ]
        \\
    );
    return source.toOwnedSlice();
}

test "derived eq and compare over a 60 000- and a 65 535-field nominal payload build and run, in both builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // CK-81. The eager pass derives `T`'s `eq` and `compare` through its
    // payload's record, whose derived body compares every field inline: one
    // left-nested `&&` 60 000 deep, and 60 000 statements for `compare`. The
    // printer recursed once per `&&` and segfaulted the compiler; so would
    // `--release`'s two walks. It iterates now (`JsIr.pushOperands`, the
    // printer's work stack). And the function took one evidence parameter
    // per field, so the build that no longer crashed threw `RangeError` in
    // Node at 60 000 — a 60 002-argument call from inside `T`'s `eq`
    // overflows the default stack — and at 65 535 V8 refuses the function
    // (65 537 parameters). Past 4 096 the evidence is one array now
    // (static-dispatch §9.2's wide form), so both run. 65 535 is the widest
    // the checker takes today (CK-82). The record `==` of CK-79's cap is not
    // involved: `T r == T r` compares a nominal type.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const expected = "True\nFalse\nTrue\nFalse\nTrue\n";

    for ([_]usize{ 60_000, 65_535 }) |n| {
        const source = try wideNominalProgram(testing.allocator, n);
        defer testing.allocator.free(source);
        try w.write("Main.beni", source);

        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const dev = try w.buildAndRun(&.{ "--no-cache", "Main.beni" });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        try expectExited(dev.build, 0);
        try testing.expectEqualStrings("", dev.build.stderr);
        try testing.expectEqualStrings(expected, dev.program.?.stdout);
        try testing.expectEqual(@as(u8, 0), dev.program.?.exit_code);
    }

    // The widest once more under `--release`: `Opt`'s and `Rename`'s walks
    // over the same chain, and `Rename`'s safety check, which was quadratic
    // in a declaration's locals (46 s here on a Debug build).
    const release = try w.buildAndRun(&.{ "--no-cache", "--release", "Main.beni" });
    try expectExited(release.build, 0);
    try testing.expectEqualStrings(expected, release.program.?.stdout);
    try testing.expectEqual(@as(u8, 0), release.program.?.exit_code);
}

test "a 200 000-element list literal is EMITTED without a stack overflow and RUNS, in both builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A list literal lowered to one `{ $: 1, a: x, b: … }` per element, each
    // inside the last, and the parser does not charge its depth for the
    // elements. The printer recursed per level and segfaulted the build
    // (CK-81); then the module it wrote threw `RangeError` in Node's parser
    // from about 1 550 elements (CK-83). Past 32 elements a literal is one
    // flat array now, built into cells by `reduceRight` (`backend.md` §4),
    // so the build finishes and the program runs.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("import Node exposing (Program)\n\n\nxs : List Int\nxs =\n    [ 1");
    for (1..200_000) |i| try source.writer.print(", {d}", .{i + 1});
    try source.writer.writeAll(" ]\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt (List.length xs), String.fromInt (List.sum xs), String.join (List.map (List.take xs 3) String.fromInt) \",\" ]\n");
    try w.write("Main.beni", source.written());

    for ([_][]const u8{ "--no-cache", "--release" }) |flag| {
        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const r = try w.buildAndRun(&.{ flag, "Main.beni" });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        try expectExited(r.build, 0);
        try testing.expectEqualStrings("", r.build.stderr);
        try testing.expectEqualStrings("200000\n20000100000\n1,2,3\n", r.program.?.stdout);
        try testing.expectEqual(@as(u8, 0), r.program.?.exit_code);
    }
}

// CK-83, promoted from `tests/pending` by R2c (`plans/checker-rewrite.md`
// §2.6): programs the compiler accepted, lowered to JavaScript nested deeper
// than Node 24's parser loads — it threw `RangeError` from about 1 550
// levels. A 2 000-element list literal (uncharged by the parser's budget),
// and 2 000-term `+` and `++` chains (under it). Every one builds and runs,
// printing its length. The three cases are three files of ONE project, built
// in turn to the same `--out=out`: `build` compiles only the named entry's
// import graph, and each build rewrites `out/_main.mjs` for its own entry
// before it is run, so no case reads another's output.
test "CK-83: a 2 000-element list and 2 000-term + and ++ chains build and run" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    const n = 2_000;
    const Case = struct { head: []const u8, term: []const u8, op: []const u8, tail: []const u8, close: []const u8 };
    const cases = [_]Case{
        .{ .head = "xs : List Int\nxs =\n    [ ", .term = "1", .op = ", ", .tail = " ]", .close = "String.fromInt (List.length xs)" },
        .{ .head = "xs : Int\nxs =\n    ", .term = "one", .op = " + ", .tail = "", .close = "String.fromInt xs" },
        .{ .head = "xs : String\nxs =\n    ", .term = "a", .op = " ++ ", .tail = "", .close = "String.fromInt (String.length xs)" },
    };
    for (cases, 0..) |case, k| {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, "import Node exposing (Program)\n\n\none : Int\none =\n    1\n\n\na : String\na =\n    \"a\"\n\n\n");
        try text.appendSlice(a, case.head);
        for (0..n) |i| try text.print(a, "{s}{s}", .{ if (i == 0) "" else case.op, case.term });
        try text.print(a, "{s}\n\n\nmain : Program\nmain =\n    Node.printLines [ {s} ]\n", .{ case.tail, case.close });
        const file = try std.fmt.allocPrint(a, "Case{d}.beni", .{k});
        try w.write(file, text.items);

        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const r = try w.buildAndRun(&.{ "--no-cache", file });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        try expectExited(r.build, 0);
        try testing.expectEqualStrings("", r.build.stderr);
        try testing.expectEqualStrings("2000\n", r.program.?.stdout);
        try testing.expectEqual(@as(u8, 0), r.program.?.exit_code);
    }
}

test "a written operator chain runs at the widest the parser admits, and 100 000 terms are one nesting_too_deep" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The user's half of CK-81: an operator chain a person writes. The
    // parser charges every operator to `Parse.max_depth`, so a chain is
    // bounded before the backend sees it: `&&` over `x == 3` reaches the
    // budget at 1 366 terms (three charges each), `++` at 2 049 (two) and
    // `+` at 4 096 (one), and 100 000 terms of any operator is exactly one
    // `nesting_too_deep`. Under it the chain goes through check, both walks
    // and the printer — and, since R2c (CK-83), RUNS at the widest the
    // parser admits: `&&` prints as one flat run and `+`/`++` are bound to a
    // `const` every `nesting.spill` units (`backend.md` §4), where they
    // nested one call per term and Node refused them from about 1 550.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const Case = struct { head: []const u8, term: []const u8, op: []const u8, width: usize, tail: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .head = "x : Int\nx =\n    3\n\n\nb : Bool\nb =\n    ", .term = "x == 3", .op = " && ", .width = 1_365, .tail = "Node.printLines [ if b then \"yes\" else \"no\" ]", .expected = "yes\n" },
        .{ .head = "x : Int\nx =\n    1\n\n\nb : Int\nb =\n    ", .term = "x", .op = " + ", .width = 4_095, .tail = "Node.printLines [ String.fromInt b ]", .expected = "4095\n" },
        .{ .head = "x : String\nx =\n    \"a\"\n\n\nb : String\nb =\n    ", .term = "x", .op = " ++ ", .width = 2_048, .tail = "Node.printLines [ String.fromInt (String.length b) ]", .expected = "2048\n" },
    };
    for (cases) |case| {
        for ([_]usize{ case.width, 100_000 }) |n| {
            var source: std.Io.Writer.Allocating = .init(testing.allocator);
            defer source.deinit();
            try source.writer.print("import Node exposing (Program)\n\n\n{s}", .{case.head});
            for (0..n) |i| try source.writer.print("{s}{s}", .{ if (i == 0) "" else case.op, case.term });
            try source.writer.print("\n\n\nmain : Program\nmain =\n    {s}\n", .{case.tail});
            try w.write("Main.beni", source.written());

            // ┌─────────────────────────────────┐
            // │ EXECUTE                         │
            // └─────────────────────────────────┘
            if (n == case.width) {
                const ran = try w.buildAndRun(&.{ "--no-cache", "Main.beni" });
                const released = try w.buildAndRun(&.{ "--no-cache", "--release", "Main.beni" });

                // ┌─────────────────────────────┐
                // │ VERIFY OUTPUT               │
                // └─────────────────────────────┘
                for ([_]World.BuildAndRun{ ran, released }) |r| {
                    try expectExited(r.build, 0);
                    try testing.expectEqualStrings(case.expected, r.program.?.stdout);
                    try testing.expectEqual(@as(u8, 0), r.program.?.exit_code);
                }
                continue;
            }
            const refused = try w.run(&.{ "build", "--no-cache", "--platform=node", "--out=wide", "Main.beni" });
            try expectExited(refused, 1);
            try testing.expectEqual(@as(usize, 1), refused.diagnostics.len);
            try testing.expectEqual(diagnostic.Code.nesting_too_deep, refused.diagnostics[0].code);
            try testing.expect(!w.exists("wide"));
        }
    }
}

// ---------------------------------------------------------------------------
// Type arity (CK-38, interface v3: `checker-v2.md` §14.2)
// ---------------------------------------------------------------------------

/// `pub type Wide a0 … a<n-1> = Wide a0`.
fn wideParams(gpa: Allocator, n: usize) ![]u8 {
    var source: std.Io.Writer.Allocating = .init(gpa);
    errdefer source.deinit();
    try source.writer.writeAll("pub type Wide");
    for (0..n) |i| try source.writer.print(" a{d}", .{i});
    try source.writer.writeAll("\n    = Wide a0\n");
    return source.toOwnedSlice();
}

test "a type of 65 535 parameters checks, and the 65 536th is one too_many_type_parameters" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // An arity is a `u16` in interface v3 (CK-38): as a `u8` it saturated
    // at 255 and a 256-parameter type was imported at the wrong width
    // (`check/good/WideTypeArity/`). §14.2's "a saturating cast becomes an
    // error at 65 535" is this: lowering refuses the 65 536th parameter,
    // once, at that parameter, so nothing downstream can saturate. On
    // 3487c12 the 65 536-parameter declaration spent 35 s of a Debug build in
    // lowering's pairwise duplicate-parameter scan and then panicked the
    // checker (`@intCast` in `deriveOneParts`); the scan is a sort now.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const widest = try wideParams(testing.allocator, 65_535);
    defer testing.allocator.free(widest);
    const past = try wideParams(testing.allocator, 65_536);
    defer testing.allocator.free(past);
    try w.write("Widest.beni", widest);
    try w.write("Past.beni", past);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const ok = try w.run(&.{ "check", "--no-cache", "Widest.beni" });
    const refused = try w.run(&.{ "build", "--no-cache", "--library", "--platform=node", "--out=past", "Past.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(ok, 0);
    try testing.expectEqual(@as(usize, 0), ok.diagnostics.len);
    try expectExited(refused, 1);
    // The 65 536th parameter is `a65535`, one past the space before it.
    const at: u32 = @intCast(std.mem.indexOf(u8, past, " a65535\n").? + 2);
    try testing.expectEqualDeep(&[_]diagnostic.Diagnostic{.{
        .code = .too_many_type_parameters,
        .severity = .@"error",
        .span = .{ .file = "Past.beni", .start = .{ .line = 1, .col = at }, .end = .{ .line = 1, .col = at + 6 } },
        .title = "TOO MANY TYPE PARAMETERS",
        .message = "This type has more than 65 535 type parameters, the most a type may declare.\n" ++
            "`a65535` is the first one past that.\n\n" ++
            "A type's number of parameters is a 16-bit count in the interface other modules\n" ++
            "read it through, so it cannot be recorded exactly. Group the parameters into\n" ++
            "records or into types of their own.",
    }}, refused.diagnostics);

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
    try testing.expect(!w.exists("past"));
}

// ---------------------------------------------------------------------------
// A derived row past 65 535 context entries (CK-109, R8a's review)
// ---------------------------------------------------------------------------

/// `H.beni`: `pub type Holder a = Holder a` and its own `eq`, which asks `a`
/// for `m0` … `m<methods - 1>`, or for `compare` when `methods` is 0.
fn holderModule(gpa: Allocator, methods: usize) ![]u8 {
    var source: std.Io.Writer.Allocating = .init(gpa);
    errdefer source.deinit();
    const out = &source.writer;
    try out.writeAll("pub type Holder a\n    = Holder a\n\n\npub eq : Holder a, Holder a -> Bool\n    where ");
    if (methods == 0) {
        try out.writeAll("a.compare : a, a -> Order\neq (Holder x) (Holder y) =\n    x.compare y == EQ\n");
        return source.toOwnedSlice();
    }
    for (0..methods) |j| try out.print("{s}a.m{d} : a, () -> Int", .{ if (j == 0) "" else ", ", j });
    try out.writeAll("\neq (Holder x) (Holder y) =\n    ");
    for (0..methods) |j| try out.print("{s}x.m{d} () == y.m{d} ()", .{ if (j == 0) "" else " && ", j, j });
    try out.writeAll("\n");
    return source.toOwnedSlice();
}

/// `pub type W p0 … p<n-1> = W [p0] (H.Holder p0) … [p<n-1>] (H.Holder p<n-1>)`,
/// each `p<i>` itself a position too when `bare`.
fn holderRow(gpa: Allocator, n: usize, bare: bool) ![]u8 {
    var source: std.Io.Writer.Allocating = .init(gpa);
    errdefer source.deinit();
    const out = &source.writer;
    try out.writeAll("import H\nimport Node exposing (Program)\n\n\npub type W");
    for (0..n) |i| try out.print(" p{d}", .{i});
    try out.writeAll("\n    = W");
    for (0..n) |i| {
        if (bare) try out.print(" p{d}", .{i});
        try out.print(" (H.Holder p{d})", .{i});
    }
    try out.writeAll("\n\n\nmain : Program\nmain =\n    Node.printLines [ \"ok\" ]\n");
    return source.toOwnedSlice();
}

test "CK-109: a derived row of more than 65 535 context entries checks, and builds and runs, under v2" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // D4 gives a derived row one evidence parameter per context entry, and
    // an entry per (parameter, method), so entries outrun parameters: 656
    // parameters whose payload's `eq` asks 100 methods of each are 65 600.
    // R8a's first draft kept the entry index `Dispatch.Param.k` a `u16` and
    // panicked in `Eager.marker`'s `@intCast` (Debug; wrapped silently to
    // the wrong evidence in ReleaseFast); its lookup there was also
    // quadratic in the entries (74 s and 3.1 GB of a Debug build). The
    // second shape reaches 65 538 entries with no user method at all: 32 769
    // parameters, each a bare position (`(i, eq)`) and a `Holder` whose `eq`
    // asks `compare` (`(i, compare)`). Only v2: v1 builds the first in
    // 9 s and checks the second in six minutes (CK-112), and neither was
    // ever its defect.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const methods = try holderModule(testing.allocator, 100);
    defer testing.allocator.free(methods);
    const wide = try holderRow(testing.allocator, 656, false);
    defer testing.allocator.free(wide);
    try w.write("H.beni", methods);
    try w.write("Main.beni", wide);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const built = try w.buildAndRun(&.{ "--no-cache", "--checker=v2", "H.beni", "Main.beni" });

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(built.build, 0);
    try testing.expectEqualStrings("", built.build.stderr);
    try testing.expectEqualStrings("ok\n", built.program.?.stdout);

    // The second shape, checked: the crash was the checker's.
    const compare = try holderModule(testing.allocator, 0);
    defer testing.allocator.free(compare);
    const params = try holderRow(testing.allocator, 32_769, true);
    defer testing.allocator.free(params);
    try w.write("H.beni", compare);
    try w.write("Main.beni", params);
    const checked = try w.run(&.{ "check", "--no-cache", "--checker=v2", "--platform=node", "H.beni", "Main.beni" });
    try expectExited(checked, 0);
    try testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
}
