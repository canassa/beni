//! The layering gate of the ownership checker v2 (`docs/design/ownership-v2.md`
//! §5), enforced by reading the sources of `src/own2/`, as `src/rules_test.zig`
//! enforces the whole tree's rule 5 (which this directory is subject to as
//! well: nothing here is excused from it).
//!
//! 1. **Layering.** Every `@import("X.zig")` of an `own2/` file names a file
//!    on a strictly lower layer of §5's table; a same-layer or higher import,
//!    or a file §5 does not list, fails naming both files. Every import
//!    outside `own2/` must be on §5's base-layer list (`base_imports`): the
//!    type modules for `Place` alone, `src/own/` never, `../beni.zig` never.
//!    A file's tests (after `const testing = std.testing;`) may also import
//!    the front end to lower source in-process (`test_imports`). Later
//!    slices cannot introduce a cycle or a back door without editing these
//!    tables, which the design owns.
//! 2. **Sizes.** Each file's production lines — up to its in-source tests —
//!    are within §5's line target.
//! 3. **Fences.** Only `Cell` defines `alias`; `Transfer`, `Calls`,
//!    `Demands` and `Rows` compare no name to a string literal unless the
//!    line is allowlisted with a reason; `Facts.Cause` declares exactly
//!    R-6.3's causes in its order.
//! 4. **Records.** Every table is an `Ids.Columns(T)`, which puts its `T` under
//!    `Ids.assertRecord`, so no table's record can pass 16 words (§4.1), and
//!    reads it through plain column slices: no other `MultiArrayList`, and
//!    no `items(.f)` but on the BIR's instructions.
//! 5. **Obligations.** Every production file's header says which of §2.14's
//!    obligations it keeps (`Obligations kept here:`), or that it keeps
//!    none.

const std = @import("std");
const testing = std.testing;

const Entry = struct { file: []const u8, layer: u8, max_lines: u32 };

/// §5's table. A new file is added here by the slice that adds it.
const layers = [_]Entry{
    // The slot domain (#1685) replaced the shape files; the targets are
    // the files' production lines with headroom, set with the replacement.
    // An account's first reads of the module tables (§4.1, #1714).
    .{ .file = "Ids.zig", .layer = 0, .max_lines = 1260 },
    .{ .file = "Counters.zig", .layer = 0, .max_lines = 580 },
    .{ .file = "Place.zig", .layer = 1, .max_lines = 1340 },
    .{ .file = "Runs.zig", .layer = 1, .max_lines = 90 },
    // The tags and routes of a leaf set (#1714), split from `Leaves`.
    .{ .file = "Routes.zig", .layer = 1, .max_lines = 680 },
    .{ .file = "Facts.zig", .layer = 2, .max_lines = 350 },
    // Holds read by their tags (#1714).
    .{ .file = "TagTree.zig", .layer = 2, .max_lines = 250 },
    // What a place graph says below a path, split from `Subtree` (#1714).
    .{ .file = "PlaceBelow.zig", .layer = 2, .max_lines = 70 },
    .{ .file = "Slots.zig", .layer = 2, .max_lines = 440 },
    // A contract's result trees, hash-consed by node (#1714, §2.10).
    .{ .file = "Trees.zig", .layer = 2, .max_lines = 200 },
    // The readers and the union of result trees, below the contracts (#1714).
    .{ .file = "Forest.zig", .layer = 3, .max_lines = 380 },
    // Conditions, split from `Contract` (#1714).
    .{ .file = "Conds.zig", .layer = 3, .max_lines = 200 },
    .{ .file = "Contract.zig", .layer = 4, .max_lines = 800 },
    // A whole subtree held as a symbol (#1706): its readers, above `Slots`.
    .{ .file = "Subtree.zig", .layer = 4, .max_lines = 350 },
    .{ .file = "Prepass.zig", .layer = 4, .max_lines = 630 },
    .{ .file = "Rows.zig", .layer = 5, .max_lines = 320 },
    .{ .file = "Regions.zig", .layer = 5, .max_lines = 530 },
    .{ .file = "ContractText.zig", .layer = 5, .max_lines = 160 },
    // A value's leaf set (#1714): made with the value, read by `Relation`.
    .{ .file = "Leaves.zig", .layer = 5, .max_lines = 600 },
    // Worded contracts by declaration and places, one footprint a callee (#1714).
    .{ .file = "Worded.zig", .layer = 5, .max_lines = 60 },
    .{ .file = "Value.zig", .layer = 6, .max_lines = 480 },
    .{ .file = "Liveness.zig", .layer = 6, .max_lines = 1190 },
    .{ .file = "Relation.zig", .layer = 7, .max_lines = 1300 },
    // The distinct check's entries and rounds' state, split from `Distinct` (#1714).
    .{ .file = "Entries.zig", .layer = 7, .max_lines = 400 },
    // The atoms a result holds open already, for the read-off (#1716).
    .{ .file = "Held.zig", .layer = 7, .max_lines = 70 },
    // One walk of a value along several paths, below `Distinct` (#1714).
    .{ .file = "Paths.zig", .layer = 8, .max_lines = 140 },
    // Split from `Relation` and `Eval` (#1685): the walk reads leaves of
    // values, the distinct check reads a call's instantiation.
    // A cell's `◆` as an evaluation reads it, from `Eval` (#1729).
    .{ .file = "Cells.zig", .layer = 8, .max_lines = 150 },
    // A demand says whether it is a cell operation (#1727).
    .{ .file = "Walk.zig", .layer = 9, .max_lines = 1240 },
    // One entry of many objects; an answer apart from nothing (#1710,
    // #1711); what an answer may hold (§2.9.2 step 7).
    .{ .file = "Distinct.zig", .layer = 9, .max_lines = 750 },
    // The subtree symbol's read-off beside the passed-on labels (§2.3.1).
    // A closure's cell operations on its captures, at its creation (#1727).
    .{ .file = "Eval.zig", .layer = 10, .max_lines = 640 },
    // What resolution reads of the leaves: base keys, the escape index (#1714).
    .{ .file = "Holders.zig", .layer = 10, .max_lines = 700 },
    // The holder index and its sweep, split from `Holders` (#1714): holds
    // listed once a holder, buckets by next use, the aggregated holders.
    // A holder's later uses, split from `Resolve` for the best-hold descent (#1714).
    .{ .file = "Later.zig", .layer = 10, .max_lines = 180 },
    .{ .file = "Sweep.zig", .layer = 10, .max_lines = 720 },
    // The pending operands by clock and key, split from the walk's copies (#1714).
    .{ .file = "Stack.zig", .layer = 10, .max_lines = 380 },
    // Resolve grew by the passed-on labels' supply judgement (§2.11.3).
    // A supply part judged by its known objects too (#1712).
    // The read-off, split from `Eval` (#1714).
    .{ .file = "ReadOff.zig", .layer = 11, .max_lines = 1160 },
    // The best-hold descent over a holder DAG, below Resolve (#1714).
    .{ .file = "Descent.zig", .layer = 11, .max_lines = 330 },
    .{ .file = "Deliver.zig", .layer = 11, .max_lines = 300 },
    // A callee's hand-back is an escape too (#1709).
    .{ .file = "Closures.zig", .layer = 11, .max_lines = 140 },
    .{ .file = "Resolve.zig", .layer = 12, .max_lines = 680 },
    // Evidence terms as function values (#1708).
    .{ .file = "Groups.zig", .layer = 13, .max_lines = 1900 },
    .{ .file = "Block.zig", .layer = 14, .max_lines = 380 },
    .{ .file = "Message.zig", .layer = 14, .max_lines = 280 },
    .{ .file = "Report.zig", .layer = 14, .max_lines = 150 },
    .{ .file = "Hoists.zig", .layer = 14, .max_lines = 170 },
    .{ .file = "Ownership.zig", .layer = 15, .max_lines = 340 },
    .{ .file = "Enforce.zig", .layer = 16, .max_lines = 510 },
};

/// §5's base layer, the only files outside `own2/` a production line may
/// import: `bir/Bir`, `check/{TypeStore,Types,Walk,Dispatch,SchemaPlan,
/// EffectPlan,Scc}`, `resolve/{Interface,Graph}`, `parse/Ast`, `InternPool`,
/// `stamped`, plus the build's option modules. `only` names the files
/// allowed to import it (the type modules: "only `Place` reads type
/// children").
const BaseImport = struct { path: []const u8, only: ?[]const []const u8 = null };
const base_imports = [_]BaseImport{
    .{ .path = "../bir/Bir.zig" },
    // The type modules: `Place` and the `Groups` source and signature
    // adapters read type children (§5); `Enforce` builds their inputs.
    .{ .path = "../check/TypeStore.zig", .only = &.{ "Place.zig", "Groups.zig" } },
    .{ .path = "../check/Types.zig", .only = &.{ "Place.zig", "Groups.zig", "Enforce.zig" } },
    .{ .path = "../check/Walk.zig", .only = &.{"Place.zig"} },
    // The hook's session, driver and diagnostics: `Enforce` alone (§3.7).
    .{ .path = "../Session.zig", .only = &.{"Enforce.zig"} },
    .{ .path = "../check/Driver.zig", .only = &.{"Enforce.zig"} },
    .{ .path = "../check/Check.zig", .only = &.{"Enforce.zig"} },
    .{ .path = "../check/Diagnostics.zig", .only = &.{"Enforce.zig"} },
    .{ .path = "../check/Dispatch.zig" },
    .{ .path = "../check/Edges.zig" },
    .{ .path = "../check/SchemaPlan.zig" },
    .{ .path = "../check/EffectPlan.zig" },
    .{ .path = "../check/Scc.zig" },
    .{ .path = "../resolve/Interface.zig" },
    .{ .path = "../resolve/Graph.zig" },
    .{ .path = "../parse/Ast.zig" },
    .{ .path = "../InternPool.zig" },
    .{ .path = "../stamped.zig" },
    .{ .path = "std" },
    .{ .path = "ownership_options" },
    .{ .path = "diagnostic" },
};

/// What a file's TESTS may import besides the above: the front end, to
/// lower a source text to BIR in-process.
const test_imports = [_][]const u8{ "../lex/Tokenizer.zig", "../parse/Parse.zig", "../bir/Lower.zig" };

/// The files that compare no name to a string literal.
const no_name_compare = [_][]const u8{ "Eval.zig", "Relation.zig", "Resolve.zig", "Rows.zig" };

/// A `std.mem.eql(u8, …, "literal")` a fenced file is allowed, by file and
/// a text of its line, with why. An entry nothing matches fails too.
const Allowed = struct { file: []const u8, needle: []const u8, why: []const u8 };
const literal_allowlist = [_]Allowed{};

/// R-6.3's causes in print order. `Facts.Cause` must declare exactly these.
const causes = [_][]const u8{
    "unknown",   "escaped",  "top_level", "captured_edit", "disjoint", "held_operand", "later_use",
    "alias",     "captured", "element",   "call",          "supply",   "need",         "limit",
    "exclusive", "once",     "payload",   "read_only",     "level",    "comparison",
};

const test_marker = "\nconst testing = std.testing;";

const Source = struct { name: []const u8, text: []const u8 };

fn layerOf(name: []const u8) ?Entry {
    for (layers) |e| if (std.mem.eql(u8, e.file, name)) return e;
    return null;
}

fn readSources(gpa: std.mem.Allocator, io: std.Io, out: *std.ArrayList(Source)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, "src/own2", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const text = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 22));
        errdefer gpa.free(text);
        try out.append(gpa, .{ .name = try gpa.dupe(u8, entry.name), .text = text });
    }
    std.mem.sort(Source, out.items, {}, struct {
        fn lessThan(_: void, a: Source, b: Source) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

/// The production part of a file: everything before its tests.
fn production(text: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, text, test_marker)) |at| text[0..at] else text;
}

fn lineCount(text: []const u8) u32 {
    const prod = production(text);
    return @intCast(std.mem.count(u8, prod, "\n") + @intFromBool(prod.len > 0 and prod[prod.len - 1] != '\n'));
}

fn isComment(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "//");
}

/// Every `@import("…")` target of `text`, in order.
fn imports(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "@import(\"")) |at| {
        const start = at + "@import(\"".len;
        const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse break;
        from = end;
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
        if (isComment(text[line_start..at])) continue;
        try out.append(gpa, text[start..end]);
    }
}

/// Why `file` may not import `target` (from its production lines, or its
/// tests when `in_tests`), or null when it may.
fn importVerdict(file: []const u8, target: []const u8, in_tests: bool) ?[]const u8 {
    const me = layerOf(file) orelse return "not in §5's table";
    if (std.mem.indexOf(u8, target, "own/") != null) return "v1 (src/own/) is frozen and no v2 file reads it";
    if (std.mem.indexOfScalar(u8, target, '/') == null and std.mem.endsWith(u8, target, ".zig")) {
        if (std.mem.eql(u8, target, "Counters.zig")) return null;
        const other = layerOf(target) orelse return "not in §5's table";
        if (other.layer >= me.layer) return "imports go to strictly lower layers (§5)";
        return null;
    }
    for (base_imports) |b| {
        if (!std.mem.eql(u8, b.path, target)) continue;
        if (b.only) |only| {
            for (only) |o| if (std.mem.eql(u8, o, file)) return null;
            return "only Place and the Groups adapters read type children; only Enforce reads the session (§5)";
        }
        return null;
    }
    if (in_tests) {
        for (test_imports) |t| if (std.mem.eql(u8, t, target)) return null;
    }
    return "not on §5's base layer (own2/rules_test.zig `base_imports`)";
}

/// The identifiers declared by an `enum` body, in order.
fn enumMembers(gpa: std.mem.Allocator, text: []const u8, decl: []const u8, out: *std.ArrayList([]const u8)) !bool {
    const start = std.mem.indexOf(u8, text, decl) orelse return false;
    const open = std.mem.indexOfScalarPos(u8, text, start, '{') orelse return false;
    const close = std.mem.indexOfPos(u8, text, open, "\n};") orelse return false;
    var lines = std.mem.splitScalar(u8, text[open + 1 .. close], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " ");
        if (line.len == 0 or isComment(line) or std.mem.startsWith(u8, line, "pub ") or std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "const ")) continue;
        if (!std.mem.endsWith(u8, line, ",")) continue;
        const name = line[0 .. line.len - 1];
        for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
        try out.append(gpa, name);
    }
    return true;
}

fn fail(bad: *usize, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("src/own2/" ++ fmt ++ "\n", args);
    bad.* += 1;
}

test "own2 layering: every import points strictly down §5's table or onto its base layer" {
    const gpa = testing.allocator;
    var sources: std.ArrayList(Source) = .empty;
    defer {
        for (sources.items) |s| {
            gpa.free(s.name);
            gpa.free(s.text);
        }
        sources.deinit(gpa);
    }
    try readSources(gpa, testing.io, &sources);
    try testing.expect(sources.items.len >= 3);
    var bad: usize = 0;
    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(gpa);
    for (sources.items) |s| {
        if (std.mem.eql(u8, s.name, "rules_test.zig")) continue;
        const me = layerOf(s.name) orelse {
            fail(&bad, "{s}: not in §5's table (own2/rules_test.zig `layers`): a new file is added there by its slice", .{s.name});
            continue;
        };
        if (lineCount(s.text) > me.max_lines) fail(&bad, "{s}: {d} lines, over §5's target of {d}", .{ s.name, lineCount(s.text), me.max_lines });
        const prod = production(s.text);
        targets.clearRetainingCapacity();
        try imports(gpa, prod, &targets);
        for (targets.items) |t| if (importVerdict(s.name, t, false)) |why| fail(&bad, "{s} imports {s}: {s}", .{ s.name, t, why });
        targets.clearRetainingCapacity();
        try imports(gpa, s.text[prod.len..], &targets);
        for (targets.items) |t| if (importVerdict(s.name, t, true)) |why| fail(&bad, "{s} (tests) imports {s}: {s}", .{ s.name, t, why });
        if (std.mem.indexOf(u8, prod, "Obligations kept here:") == null) fail(&bad, "{s}: the header names no §2.14 obligation (`Obligations kept here:` …, or `none`)", .{s.name});
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "own2 fences: alias, name comparisons, Cause order, records asserted" {
    const gpa = testing.allocator;
    var sources: std.ArrayList(Source) = .empty;
    defer {
        for (sources.items) |s| {
            gpa.free(s.name);
            gpa.free(s.text);
        }
        sources.deinit(gpa);
    }
    try readSources(gpa, testing.io, &sources);
    var bad: usize = 0;
    var used: [literal_allowlist.len]bool = @splat(false);
    var members: std.ArrayList([]const u8) = .empty;
    defer members.deinit(gpa);
    for (sources.items) |s| {
        if (std.mem.eql(u8, s.name, "rules_test.zig")) continue;
        // Only `Cell` defines `alias`.
        if (!std.mem.eql(u8, s.name, "Distinct.zig") and std.mem.indexOf(u8, s.text, "fn overlap(") != null) {
            fail(&bad, "{s} defines `overlap`: only Distinct.overlap relates leaves (§2.9.2)", .{s.name});
        }
        // The normal form's words are build-local (§3.5: this module's
        // place ids, union sides in id order): only `Summary` makes them
        // and only `Block` may spell them for a hash or a file.
        if (!std.mem.eql(u8, s.name, "Summary.zig") and !std.mem.eql(u8, s.name, "Block.zig") and std.mem.indexOf(u8, production(s.text), "normalize(") != null) {
            fail(&bad, "{s} calls `normalize`: the normal-form words are build-local and only Block may hash or publish them (§3.5)", .{s.name});
        }
        // Name comparisons in the fenced files.
        for (no_name_compare) |f| {
            if (!std.mem.eql(u8, s.name, f)) continue;
            var lines = std.mem.splitScalar(u8, s.text, '\n');
            var n: u32 = 0;
            while (lines.next()) |line| {
                n += 1;
                if (isComment(line)) continue;
                const at = std.mem.indexOf(u8, line, "std.mem.eql(u8") orelse continue;
                if (std.mem.indexOfScalarPos(u8, line, at, '"') == null) continue;
                var allowed = false;
                for (literal_allowlist, 0..) |a, i| {
                    if (std.mem.eql(u8, a.file, s.name) and std.mem.indexOf(u8, line, a.needle) != null) {
                        allowed = true;
                        used[i] = true;
                    }
                }
                if (!allowed) fail(&bad, "{s}:{d}: a name compared to a string literal in a fenced file (§5)", .{ s.name, n });
            }
        }
        // `Facts.Cause` is exactly R-6.3's list, in its order.
        if (std.mem.eql(u8, s.name, "Facts.zig")) {
            members.clearRetainingCapacity();
            if (!try enumMembers(gpa, s.text, "pub const Cause = enum", &members)) {
                fail(&bad, "Facts.zig: `pub const Cause = enum` not found or not a plain member list", .{});
            } else if (members.items.len != causes.len) {
                fail(&bad, "Facts.zig: `Cause` has {d} members, R-6.3 has {d}", .{ members.items.len, causes.len });
            } else for (members.items, causes) |m, c| if (!std.mem.eql(u8, m, c)) {
                fail(&bad, "Facts.zig: `Cause` has `{s}` where R-6.3's order has `{s}`", .{ m, c });
            };
        }
        // Every table is an `Ids.Columns`, which asserts its record (§4.1: at
        // most 16 words) and keeps its columns as plain slices in step with
        // every growth: `MultiArrayList`'s `items(.f)` and `get(i)` recompute
        // every column's address per call, a third of the checker's cycles
        // under Zig's own backend. Only `Ids.Columns` holds one.
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, s.text, from, "MultiArrayList(")) |at| {
            from = at + 1;
            const line_start = if (std.mem.lastIndexOfScalar(u8, s.text[0..at], '\n')) |nl| nl + 1 else 0;
            if (isComment(s.text[line_start..at])) continue;
            if (std.mem.eql(u8, s.name, "Ids.zig") and std.mem.startsWith(u8, s.text[at..], "MultiArrayList(T)")) continue;
            fail(&bad, "{s}: a `MultiArrayList` table: make it an `Ids.Columns` and read it through `col`", .{s.name});
        }
        // Only the BIR's instructions, another module's list, are read
        // through `items`; and only `Ids.Columns` touches its own `list`,
        // which a write past `col` would leave out of step.
        var lines = std.mem.splitScalar(u8, production(s.text), '\n');
        var n: u32 = 0;
        while (lines.next()) |line| {
            n += 1;
            if (isComment(line)) continue;
            if (!std.mem.eql(u8, s.name, "Ids.zig") and std.mem.indexOf(u8, line, ".list.") != null) {
                fail(&bad, "{s}:{d}: an `Ids.Columns`' `list` reached from outside `Ids.zig`: use its methods and `col`", .{ s.name, n });
            }
            if (std.mem.indexOf(u8, line, ".items(.") == null) continue;
            if (std.mem.indexOf(u8, line, "bir.insts.items(.") != null) continue;
            fail(&bad, "{s}:{d}: a column read through `items`: read the table's `col`", .{ s.name, n });
        }
    }
    for (literal_allowlist, used) |a, u| {
        if (!u) fail(&bad, "rules_test.zig: the allowlist entry for {s} (`{s}`) matches nothing: remove it", .{ a.file, a.needle });
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "the layering table has each file once and every layer below the next" {
    for (layers, 0..) |a, i| {
        for (layers[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.file, b.file));
        if (i > 0) try testing.expect(layers[i - 1].layer <= a.layer);
    }
    try testing.expectEqual(@as(usize, 46), layers.len);
    try testing.expectEqual(@as(usize, 20), causes.len);
}

test "the import verdict refuses back doors and accepts the base layer" {
    try testing.expect(importVerdict("Slots.zig", "../beni.zig", false) != null);
    try testing.expect(importVerdict("Slots.zig", "../beni.zig", true) != null);
    try testing.expect(importVerdict("Slots.zig", "../own/Ownership.zig", false) != null);
    try testing.expect(importVerdict("Prepass.zig", "../check/TypeKeys.zig", false) != null);
    try testing.expect(importVerdict("Prepass.zig", "../check/Module.zig", false) != null);
    try testing.expect(importVerdict("Slots.zig", "../check/TypeStore.zig", false) != null);
    try testing.expect(importVerdict("Place.zig", "../check/TypeStore.zig", false) == null);
    try testing.expect(importVerdict("Prepass.zig", "../check/Scc.zig", false) == null);
    try testing.expect(importVerdict("Prepass.zig", "../bir/Lower.zig", false) != null);
    try testing.expect(importVerdict("Prepass.zig", "../bir/Lower.zig", true) == null);
    try testing.expect(importVerdict("Slots.zig", "Ids.zig", false) == null);
    try testing.expect(importVerdict("Ids.zig", "Slots.zig", false) != null);
    try testing.expect(importVerdict("Slots.zig", "Facts.zig", false) != null);
    try testing.expect(importVerdict("Shape.zig", "Nowhere.zig", false) != null);
}

test "the enum member reader is exact: extras, order and words inside words fail" {
    const gpa = testing.allocator;
    var members: std.ArrayList([]const u8) = .empty;
    defer members.deinit(gpa);
    const text =
        \\pub const Cause = enum(u8) {
        \\    unknown,
        \\    // a comment
        \\    escaped,
        \\    pub fn x() void {}
        \\    unknown_extra,
        \\};
        \\const other = 1;
    ;
    try testing.expect(try enumMembers(gpa, text, "pub const Cause = enum", &members));
    try testing.expectEqual(@as(usize, 3), members.items.len);
    try testing.expectEqualStrings("unknown_extra", members.items[2]);
}
