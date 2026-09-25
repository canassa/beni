//! Abuse scenarios over WIDE inputs — records of 100 000 fields, nominal
//! payloads of 65 535, operator chains and list literals at the widths Node
//! stops loading — split out of `abuse_test.zig` on 2026-09-25 only so that
//! the two run as separate processes in parallel: together they were one
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

test "== on a record runs up to the derived-field cap and is refused past it, never a runtime exception" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // `==` on a record DERIVES one function with a parameter per field, and a
    // JavaScript call that wide overflows the engine's stack: under Node 24
    // a 60 000- and a 65 530-field `r == r` built and then threw `RangeError`
    // (R1's review). So a derived record comparison is refused at check time
    // past `max_derived_record_fields`, 4 096 (`check/Diagnostics.zig`,
    // CK-79), and the no-runtime-exception guarantee holds at every width:
    // at the cap it builds and RUNS, one past it and at the widths that threw
    // it is `not_equatable` before anything is written.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const at_cap = try wideEqProgram(testing.allocator, 4_096);
    defer testing.allocator.free(at_cap);
    try w.write("AtCap.beni", at_cap);

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘
    const ran = try w.buildAndRun(&.{"AtCap.beni"});

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘
    try expectExited(ran.build, 0);
    try testing.expectEqualStrings("eq\n", ran.program.?.stdout);
    try testing.expectEqual(@as(u8, 0), ran.program.?.exit_code);

    for ([_]usize{ 4_097, 40_000, 60_000, 65_530 }) |n| {
        const source = try wideEqProgram(testing.allocator, n);
        defer testing.allocator.free(source);
        try w.write("Wide.beni", source);
        const r = try w.run(&.{ "build", "--no-cache", "--platform=node", "--out=wide", "Wide.beni" });
        try expectExited(r, 1);
        try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
        try testing.expectEqual(diagnostic.Code.not_equatable, r.diagnostics[0].code);
        try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "4096") != null);
        // ┌─────────────────────────────────────┐
        // │ VERIFY SIDE EFFECTS                 │
        // └─────────────────────────────────────┘
        // A refused build writes nothing.
        try testing.expect(!w.exists("wide"));
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

test "a 200 000-element list literal is EMITTED without a stack overflow, in both builds" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // A list literal lowers to one `{ $: 1, a: x, b: … }` per element, each
    // inside the last, and the parser does not charge its depth for the
    // elements. The printer recursed per level and segfaulted the build
    // (CK-81). What Node then makes of an object literal nested 200 000 deep
    // is CK-83's — it throws `RangeError` at load from about 1 700 — so this
    // asserts the compiler's half: the build finishes and writes the module.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("import Node exposing (Program)\n\n\nxs : List Int\nxs =\n    [ 1");
    for (1..200_000) |_| try source.writer.writeAll(", 1");
    try source.writer.writeAll(" ]\n\n\nmain : Program\nmain =\n    Node.printLines [ String.fromInt (List.length xs) ]\n");
    try w.write("Main.beni", source.written());

    for ([_][]const u8{ "--no-cache", "--release" }) |flag| {
        // ┌─────────────────────────────────────┐
        // │ EXECUTE                             │
        // └─────────────────────────────────────┘
        const r = try w.runWith(&.{ "build", "--no-cache", flag, "--platform=node", "--out=out", "Main.beni" }, .{ .raw_diagnostics = true });

        // ┌─────────────────────────────────────┐
        // │ VERIFY OUTPUT                       │
        // └─────────────────────────────────────┘
        try expectExited(r, 0);
        try testing.expectEqualStrings("", r.stderr);
        try testing.expect(w.exists("out/Main.mjs"));
    }
}

test "a written operator chain runs at the widest Node loads, and 100 000 terms are one nesting_too_deep" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘
    // The user's half of CK-81: an operator chain a person writes. The
    // parser charges every operator to `Parse.max_depth`, so a chain is
    // bounded before the backend sees it: `&&` over `x == 3` reaches the
    // budget at 1 366 terms (three charges each), and 100 000 terms of any
    // operator is exactly one `nesting_too_deep`. Under it the chain goes
    // through check, both walks and the printer and runs. `+` and `++` are
    // run at 1 500, not at the parser's 4 095: Node refuses the nesting they
    // lower to from about 1 700 (`Basics$add(Basics$add(…))`, `a && (b &&
    // …)`), which is CK-83 and not asserted here.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const Case = struct { head: []const u8, term: []const u8, op: []const u8, width: usize, tail: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .head = "x : Int\nx =\n    3\n\n\nb : Bool\nb =\n    ", .term = "x == 3", .op = " && ", .width = 1_365, .tail = "Node.printLines [ if b then \"yes\" else \"no\" ]", .expected = "yes\n" },
        .{ .head = "x : Int\nx =\n    1\n\n\nb : Int\nb =\n    ", .term = "x", .op = " + ", .width = 1_500, .tail = "Node.printLines [ String.fromInt b ]", .expected = "1500\n" },
        .{ .head = "x : String\nx =\n    \"a\"\n\n\nb : String\nb =\n    ", .term = "x", .op = " ++ ", .width = 1_500, .tail = "Node.printLines [ String.fromInt (String.length b) ]", .expected = "1500\n" },
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
