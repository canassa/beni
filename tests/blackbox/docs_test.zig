//! The doc-example gate for `core/` (docs/design/checker.md Appendix B,
//! frontend.md §7).
//!
//! `core/*.beni` documents itself with worked examples. An audit once
//! found nine that did not COMPILE — `abs -25` parses as `abs - 25`, a
//! `Tuple2` beni never had, a bare `toString` — and the same audit
//! executed 188 of them by hand and found no wrong VALUE. Nothing stopped
//! either kind of rot from coming back, and the nine corrected lines had no
//! fixture. This is that fixture, for every example at once.
//!
//! **The recognised form.** A doc comment line of exactly `--|`, five
//! spaces and a non-space character opens an EXAMPLE; a following `--|`
//! line indented MORE than five spaces continues it, joined with one space;
//! anything else ends it. An example holding a `==` at bracket depth zero,
//! outside string and character literals, is an ASSERTION, and the first
//! such `==` splits it into the two sides. Everything else — `Dict.empty`,
//! a type alias, a two-line `let` — is prose, is counted, and is not
//! checked.
//!
//! **The mechanism.** Every assertion of `core/<M>.beni` is appended to a
//! temp COPY of `<M>.beni` as `pub docExample_<line> : () → Bool` over
//! `(<left>) == (<right>)`, so it is read in the module's OWN scope:
//! unqualified names resolve the way the reader of that doc comment
//! resolves them, and no qualifier is invented. A generated `Main.beni`
//! names every one of them and prints the origin of each that answered
//! `False`, so one `beni build --platform=node --core-root=<temp>` checks
//! that every example COMPILES as a `Bool` equality and one `node
//! out/_main.mjs` checks that every one of them is TRUE. They are
//! `() → Bool` and not `Bool` so that nothing is forced at module load.
//!
//! **The skip list.** An example the mechanism cannot take is named in
//! `skips` with a reason, the whole list is printed on every run, and the
//! gate FAILS when an entry matches no example — so the list cannot outlive
//! the lines it excuses. Fixing the doc is preferred to adding an entry:
//! `isEven`, `animals` and `Cat` were names the docs never defined, and they
//! were rewritten rather than skipped.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const Io = std.Io;
const testing = std.testing;

const core_root = "core";

/// One recognised example. `line` is 1-based in `core/<module>.beni` and is
/// both the identity in a message and the suffix of the generated name.
const Example = struct {
    module: []const u8,
    line: u32,
    text: []const u8,
    /// The two sides of the `==`, or null when the example is prose.
    left: ?[]const u8 = null,
    right: []const u8 = "",
    /// Where the generated declaration landed in the temp module, so a
    /// compiler diagnostic pointing into it can be traced back here.
    temp_start: u32 = 0,
    temp_end: u32 = 0,
    skipped: ?[]const u8 = null,
};

/// Every example the mechanism cannot take, with the reason printed on each
/// run. Matched on the module and the exact example text, never on a line
/// number, so moving a doc comment does not silently drop an entry.
const Skip = struct {
    module: []const u8,
    text: []const u8,
    reason: []const u8,
};

const cycle_reason =
    "a `String`/`List` literal here would make this module IMPORT `String`/`List`, " ++
    "which core's own module graph already has pointing the other way — so no module " ++
    "with this module's scope is allowed to hold the example";

const skips = [_]Skip{
    .{ .module = "Basics", .text = "eq [ 1, 2 ] [ 1, 2 ] == True", .reason = cycle_reason },
    .{ .module = "Basics", .text = "append \"butter\" \"fly\" == \"butterfly\"", .reason = cycle_reason },
    .{ .module = "Basics", .text = "append [ 1, 2 ] [ 3 ] == [ 1, 2, 3 ]", .reason = cycle_reason },
    .{ .module = "Basics", .text = "List.map [ 1, 2, 3 ] (always 0 _) == [ 0, 0, 0 ]", .reason = cycle_reason },
    .{ .module = "List", .text = "indexedMap [ \"a\", \"b\" ] (λi x → ( i, x )) == [ ( 0, \"a\" ), ( 1, \"b\" ) ]", .reason = cycle_reason },
    .{ .module = "List", .text = "intersperse [ \"turtles\", \"turtles\" ] \"on\" == [ \"turtles\", \"on\", \"turtles\" ]", .reason = cycle_reason },
};

/// The first `==` at bracket depth zero and outside a literal. Returns the
/// byte offset, or null when the line is prose.
fn topLevelEq(text: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '"', '\'' => {
                const quote = text[i];
                i += 1;
                while (i < text.len and text[i] != quote) : (i += 1) {
                    if (text[i] == '\\') i += 1;
                }
                i += 1;
            },
            '(', '[', '{' => {
                depth += 1;
                i += 1;
            },
            ')', ']', '}' => {
                depth -= 1;
                i += 1;
            },
            '=' => {
                const before: u8 = if (i == 0) ' ' else text[i - 1];
                const two = i + 1 < text.len and text[i + 1] == '=';
                const three = i + 2 < text.len and text[i + 2] == '=';
                const comparison = two and !three and
                    before != '=' and before != '!' and before != '<' and before != '>' and before != '/';
                if (comparison and depth == 0) return i;
                i += if (two) 2 else 1;
            },
            else => i += 1,
        }
    }
    return null;
}

/// The example lines of one module's source, in file order.
fn extract(arena: std.mem.Allocator, module: []const u8, source: []const u8, out: *std.ArrayList(Example)) !void {
    var line_no: u32 = 0;
    var open: ?usize = null; // index into `out` of the example still collecting
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        const body = if (std.mem.startsWith(u8, line, "--|")) line[3..] else {
            open = null;
            continue;
        };
        var indent: usize = 0;
        while (indent < body.len and body[indent] == ' ') indent += 1;
        if (indent >= body.len) { // a blank `--|` line
            open = null;
            continue;
        }
        if (indent == 5) {
            try out.append(arena, .{ .module = module, .line = line_no, .text = try arena.dupe(u8, body[5..]) });
            open = out.items.len - 1;
        } else if (indent > 5 and open != null) {
            const e = &out.items[open.?];
            e.text = try std.fmt.allocPrint(arena, "{s} {s}", .{ e.text, body[indent..] });
        } else {
            open = null;
        }
    }
    for (out.items) |*e| {
        const at = topLevelEq(e.text) orelse continue;
        e.left = std.mem.trim(u8, e.text[0..at], " ");
        e.right = std.mem.trim(u8, e.text[at + 2 ..], " ");
    }
}

fn skipFor(e: Example) ?usize {
    for (skips, 0..) |s, i| {
        if (std.mem.eql(u8, s.module, e.module) and std.mem.eql(u8, s.text, e.text)) return i;
    }
    return null;
}

/// The `.beni` modules of `core/`, sorted — the id of everything below.
fn coreModules(arena: std.mem.Allocator) ![]const []const u8 {
    const io = testing.io;
    var dir = try Io.Dir.cwd().openDir(io, core_root, .{ .iterate = true });
    defer dir.close(io);
    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        // `Js` has no examples, and a program may not import it
        // (`js_outside_platform`, research 47).
        if (std.mem.eql(u8, entry.name, "Js.beni")) continue;
        try out.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - ".beni".len]));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return out.items;
}

/// Trace a `tcore/<M>.beni:<line>` in a diagnostic back to the example whose
/// generated declaration occupies that line.
fn originOf(examples: []const Example, text: []const u8) ?Example {
    var rest = text;
    while (std.mem.indexOf(u8, rest, "tcore/")) |at| {
        rest = rest[at + "tcore/".len ..];
        const dot = std.mem.indexOf(u8, rest, ".beni:") orelse continue;
        const module = rest[0..dot];
        var digits = rest[dot + ".beni:".len ..];
        var n: usize = 0;
        while (n < digits.len and std.ascii.isDigit(digits[n])) n += 1;
        const line = std.fmt.parseInt(u32, digits[0..n], 10) catch continue;
        for (examples) |e| {
            if (e.skipped != null or e.left == null) continue;
            if (std.mem.eql(u8, e.module, module) and line >= e.temp_start and line <= e.temp_end) return e;
        }
    }
    return null;
}

test "every `--|     expr == value` in core compiles in its own module and is true" {
    const io = testing.io;
    var w = try World.init(testing.allocator, io);
    defer w.deinit();
    const arena = w.arena.allocator();

    const modules = try coreModules(arena);
    var examples: std.ArrayList(Example) = .empty;
    var imports: std.ArrayList(u8) = .empty;
    try imports.appendSlice(arena, "import Node exposing (Program)\n");
    var main: std.ArrayList(u8) = .empty;

    var prose: u32 = 0;
    var checked: u32 = 0;
    var skipped: u32 = 0;

    // Everything in `core/` is copied, including the `.js` siblings that
    // `boundary.md` §4's checks read; only the `.beni` of a module with
    // assertions is rewritten.
    // A module under a directory (`Random/Pcg.beni`) is copied too.
    {
        var dir = try Io.Dir.cwd().openDir(io, core_root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const from = try std.fmt.allocPrint(arena, core_root ++ "/{s}", .{entry.path});
            const to = try std.fmt.allocPrint(arena, "tcore/{s}", .{entry.path});
            try w.write(to, try Io.Dir.cwd().readFileAlloc(io, from, arena, .limited(world.max_stream_bytes)));
        }
    }

    for (modules) |module| {
        const path = try std.fmt.allocPrint(arena, core_root ++ "/{s}.beni", .{module});
        const source = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(world.max_stream_bytes));
        const start = examples.items.len;
        try extract(arena, module, source, &examples);

        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(arena, source);
        if (text.items.len > 0 and text.items[text.items.len - 1] != '\n') try text.append(arena, '\n');
        var appended = false;
        for (examples.items[start..]) |*e| {
            if (e.left == null) {
                prose += 1;
                continue;
            }
            if (skipFor(e.*)) |i| {
                e.skipped = skips[i].reason;
                skipped += 1;
                continue;
            }
            e.temp_start = @intCast(std.mem.count(u8, text.items, "\n") + 2);
            try text.print(arena,
                \\
                \\
                \\pub docExample_{d} : () → Bool
                \\docExample_{d} _ =
                \\    ({s}) == ({s})
                \\
            , .{ e.line, e.line, e.left.?, e.right });
            e.temp_end = @intCast(std.mem.count(u8, text.items, "\n"));
            try main.print(arena, "{s} \"core/{s}.beni:{d}\", {s}.docExample_{d} () )\n", .{
                if (checked == 0) "\n\nentries : List (String × Bool)\nentries =\n    [ (" else "    , (",
                e.module,
                e.line,
                e.module,
                e.line,
            });
            checked += 1;
            appended = true;
        }
        if (appended) try w.write(try std.fmt.allocPrint(arena, "tcore/{s}.beni", .{module}), text.items);
        // `Basics` is a prelude alias already; importing it is not.
        if (!std.mem.eql(u8, module, "Basics")) try imports.print(arena, "import {s}\n", .{module});
    }

    std.debug.print("doc examples: {d} found, {d} assertions checked, {d} prose, {d} skipped\n", .{ examples.items.len, checked, prose, skipped });
    for (examples.items) |e| {
        if (e.skipped) |reason| std.debug.print("  SKIP core/{s}.beni:{d}  {s}\n    reason: {s}\n", .{ e.module, e.line, e.text, reason });
    }

    // A skip that matches nothing is a stale excuse, and an extractor that
    // suddenly finds a handful of examples is a broken extractor. Both are
    // failures rather than a quieter run.
    for (skips) |s| {
        var found = false;
        for (examples.items) |e| {
            if (std.mem.eql(u8, s.module, e.module) and std.mem.eql(u8, s.text, e.text)) found = true;
        }
        if (!found) {
            std.debug.print("stale skip: no example in core/{s}.beni reads `{s}`\n", .{ s.module, s.text });
            return error.StaleSkip;
        }
    }
    try testing.expect(checked > 150);

    try main.appendSlice(arena,
        \\    ]
        \\
        \\
        \\main : Program
        \\main =
        \\    Node.printLines
        \\        (List.filterMap entries λentry →
        \\            case entry of
        \\                ( origin, ok ) →
        \\                    if ok then
        \\                        Nothing
        \\                    else
        \\                        Just origin
        \\        )
        \\
    );
    try w.write("Main.beni", try std.fmt.allocPrint(arena, "{s}{s}", .{ imports.items, main.items }));

    const built = try w.runWith(
        &.{ "build", "--platform=node", "--core-root=tcore", "--out=out", "--jobs=1", "Main.beni" },
        .{ .raw_diagnostics = true },
    );
    if (built.exit_code != 0) {
        var lines = std.mem.splitScalar(u8, built.stderr, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "-- ")) continue;
            if (originOf(examples.items, line)) |e| {
                std.debug.print("DOC EXAMPLE DOES NOT COMPILE: core/{s}.beni:{d}\n    {s}\n  {s}\n", .{ e.module, e.line, e.text, line });
            } else {
                std.debug.print("DOC EXAMPLE GATE, unattributed: {s}\n", .{line});
            }
        }
        std.debug.print("{s}\n", .{built.stderr});
        return error.DocExampleDoesNotCompile;
    }

    // Every example true: the program prints nothing.
    if (try w.checkProgram(world.entry_file, .{ .stdout = "" })) |ran| {
        var lines = std.mem.splitScalar(u8, ran.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            for (examples.items) |e| {
                const origin = try std.fmt.allocPrint(arena, "core/{s}.beni:{d}", .{ e.module, e.line });
                if (std.mem.eql(u8, origin, line)) {
                    std.debug.print("DOC EXAMPLE IS FALSE: {s}\n    {s}\n", .{ origin, e.text });
                }
            }
        }
        if (ran.exit_code != 0) std.debug.print("the doc-example program exited {d}:\n{s}\n", .{ ran.exit_code, ran.stderr });
        return error.DocExampleIsWrong;
    }
    // Zig's build runner echoes the step's stderr — and, after it, `failed
    // command: …` — for ANY step that wrote to stderr, passing or not
    // (`build_runner.zig`: "No matter the result, we want to display
    // error/warning messages"). The skip list above is written there on
    // purpose, so this line says which it was; the exit code is what
    // decides the gate.
    std.debug.print("doc-example gate: OK — everything above is informational.\n", .{});
}
