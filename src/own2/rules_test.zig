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
//! 4. **Records.** Every `MultiArrayList(T)` in `own2/` has its `T` under
//!    `Ids.assertRecord`, so no table's record can pass 16 words (§4.1).
//! 5. **Obligations.** Every production file's header says which of §2.14's
//!    obligations it keeps (`Obligations kept here:`), or that it keeps
//!    none.

const std = @import("std");
const testing = std.testing;

const Entry = struct { file: []const u8, layer: u8, max_lines: u32 };

/// §5's table. A new file is added here by the slice that adds it.
const layers = [_]Entry{
    // §5 says 600; the lane-charging forms, named limits and charge targets
    // the first review asked for live here and push it past that, so the
    // table is amended to 700 with the slice's design commit.
    .{ .file = "Ids.zig", .layer = 0, .max_lines = 750 },
    // §5 says 1 100 since #1345: the fold targets and levels of a read on a
    // cycle, memoised per path.
    .{ .file = "Place.zig", .layer = 1, .max_lines = 1150 },
    // §5 says 900 since S3a: the containment relation (`below`, `stepsTo`)
    // and a refinement's canonical position (`unrefined`) Demands reads.
    .{ .file = "Cell.zig", .layer = 2, .max_lines = 1110 },
    // §5 says 350 since S3a: the report's text line and its two spellings.
    .{ .file = "Facts.zig", .layer = 2, .max_lines = 350 },
    .{ .file = "Prepass.zig", .layer = 3, .max_lines = 600 },
    // §5 says 3 600 since #1372: map's knot test and the flattening choice
    // join (§2.3); 3 350 since #1350, a view's instantiated place and a
    // join's place.
    .{ .file = "Shape.zig", .layer = 3, .max_lines = 3600 },
    .{ .file = "Regions.zig", .layer = 4, .max_lines = 450 },
    // §5 says 1 805 since #1112: the observable-position frontier every κ
    // reader walks, exact propagation states, the snapshot trie (its
    // links, merges, folds and relabelling) and the one-alternative link.
    // 2 550 since #1128: the path-multiset primitive (arrivals, aggregates by
    // destination class, the fold conditions), which §3.4 puts in Cond.
    // 2 700 since #1199: the read's summaryExcl and the cell set per key.
    // 4 220 since #1335: `foldCondOf` by the cycle walk.
    // §5 says 4 260 since #1372's review: a source with no entry reads
    // `lost` where it shares an image (`Relabel.present`).
    .{ .file = "Cond.zig", .layer = 4, .max_lines = 4260 },
    // §5 says 1 500 since the write-back effects: the normal-form encoder, the
    // κ-owning join, v1's print grammar and the funs' write-backs.
    .{ .file = "Summary.zig", .layer = 5, .max_lines = 1680 },
    // §5 says 750 since #1214: a path's uses grouped for a filter, and a
    // child's range found by its one step.
    .{ .file = "Liveness.zig", .layer = 5, .max_lines = 750 },
    .{ .file = "Exits.zig", .layer = 5, .max_lines = 250 },
    .{ .file = "Rows.zig", .layer = 6, .max_lines = 1200 },
    // §5 says 1 900 since #1214: the holder index, below Demands, which reads
    // it; with the frame types, the naive scan and the fallback hold listing.
    // 2 010 since #1335: the same-path closure by the cycle walk.
    .{ .file = "Holders.zig", .layer = 6, .max_lines = 2010 },
    // §5 says 450 since #1214 (L7 since then): condition 5 left for Holders.
    .{ .file = "Demands.zig", .layer = 7, .max_lines = 450 },
    // §5 says 1 600 since #1350: a view's instantiated place (`Views.instantiate`);
    // 1 630 since #1386: a `sep` side below a constructor.
    .{ .file = "Calls.zig", .layer = 7, .max_lines = 1630 },
    // §5 says 1 810 since #1350: a missing step's fallback; 1 840 since #1383; 1 940 since
    // #1386: two positions of one split beside a write.
    .{ .file = "Transfer.zig", .layer = 8, .max_lines = 1940 },
    // §5 says 1 200 since S4-verifier (#1180): the recursive-proof verifier;
    // S3b's worklist and propagation raise it with their design commit.
    .{ .file = "Fix.zig", .layer = 8, .max_lines = 1200 },
    .{ .file = "Walk.zig", .layer = 9, .max_lines = 1500 },
    // §5 says 1 250 since S3b slice 1: the source and signature adapters, and
    // calls of walked declarations; 1 330 since slice 3: imported classes,
    // and a block's places re-interned onto the adapter's.
    // 1 410 since #1324: a comparison read through the user-written ones its
    // type reaches (`componentClasses`).
    .{ .file = "Groups.zig", .layer = 10, .max_lines = 1410 },
    .{ .file = "Entry.zig", .layer = 10, .max_lines = 900 },
    // §5 says 500 since #1065: exact ranks, the counted refinement grouped
    // by threaded lists, its labelled graph and the reserving meter.
    .{ .file = "Refine.zig", .layer = 10, .max_lines = 500 },
    // §5 says 1 660 since #1073 (1 650 since #1065/#1066): positions with their read κ, closed under the
    // map's entries, and the shared format; the reader is `BlockRead`, the
    // refinement `Refine`; the tiers ranked exactly, every step reserved on
    // the codec's lane, and each class's growth counted alone.
    // 1 770 since #1335: a knot whose cycle no child step closes.
    .{ .file = "Block.zig", .layer = 11, .max_lines = 1770 },
    .{ .file = "Hoists.zig", .layer = 11, .max_lines = 500 },
    .{ .file = "Message.zig", .layer = 11, .max_lines = 900 },
    .{ .file = "Report.zig", .layer = 11, .max_lines = 600 },
    // §5 says 950 since #1073: a snapshot rebuilt from its positions.
    // 1 050 since S3b slice 3: the commit re-interns the block's places.
    // 1 235 since #1335: a knot's members tied raw, set once it is read,
    // a forward name only on a cycle, and the safety check of each reach.
    .{ .file = "BlockRead.zig", .layer = 12, .max_lines = 1235 },
    .{ .file = "Ownership.zig", .layer = 13, .max_lines = 300 },
    // 500 since #1398: the dump checks a module after its imports and reads
    // the blocks it published itself.
    .{ .file = "Enforce.zig", .layer = 14, .max_lines = 500 },
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
const no_name_compare = [_][]const u8{ "Transfer.zig", "Calls.zig", "Demands.zig", "Holders.zig", "Rows.zig" };

/// A `std.mem.eql(u8, …, "literal")` a fenced file is allowed, by file and
/// a text of its line, with why. An entry nothing matches fails too.
const Allowed = struct { file: []const u8, needle: []const u8, why: []const u8 };
const literal_allowlist = [_]Allowed{};

/// R-6.3's causes in print order. `Facts.Cause` must declare exactly these.
const causes = [_][]const u8{
    "unknown",   "escaped",  "top_level", "captured_edit", "disjoint", "held_operand", "later_use",
    "alias",     "captured", "element",   "call",          "supply",   "need",         "limit",
    "exclusive", "once",     "payload",   "read_only",     "level",
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
        if (!std.mem.eql(u8, s.name, "Cell.zig") and std.mem.indexOf(u8, s.text, "fn alias(") != null) {
            fail(&bad, "{s} defines `alias`: only Cell.alias compares cells (§5)", .{s.name});
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
        // Every table's record type is asserted.
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, s.text, from, "MultiArrayList(")) |at| {
            from = at + 1;
            const line_start = if (std.mem.lastIndexOfScalar(u8, s.text[0..at], '\n')) |nl| nl + 1 else 0;
            if (isComment(s.text[line_start..at])) continue;
            const open = at + "MultiArrayList(".len;
            const close = std.mem.indexOfScalarPos(u8, s.text, open, ')') orelse continue;
            const ty = s.text[open..close];
            if (std.mem.indexOfScalar(u8, ty, '.') != null) continue; // another file's record, asserted there
            var needle_buf: [128]u8 = undefined;
            const needle = std.fmt.bufPrint(&needle_buf, "assertRecord({s})", .{ty}) catch continue;
            if (std.mem.indexOf(u8, s.text, needle) == null) fail(&bad, "{s}: `{s}` is a table's record and has no `Ids.assertRecord({s})` (§4.1: at most 16 words)", .{ s.name, ty, ty });
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
    try testing.expectEqual(@as(usize, 28), layers.len);
    try testing.expectEqual(@as(usize, 19), causes.len);
}

test "the import verdict refuses back doors and accepts the base layer" {
    try testing.expect(importVerdict("Cell.zig", "../beni.zig", false) != null);
    try testing.expect(importVerdict("Cell.zig", "../beni.zig", true) != null);
    try testing.expect(importVerdict("Cell.zig", "../own/Ownership.zig", false) != null);
    try testing.expect(importVerdict("Prepass.zig", "../check/TypeKeys.zig", false) != null);
    try testing.expect(importVerdict("Prepass.zig", "../check/Module.zig", false) != null);
    try testing.expect(importVerdict("Cell.zig", "../check/TypeStore.zig", false) != null);
    try testing.expect(importVerdict("Place.zig", "../check/TypeStore.zig", false) == null);
    try testing.expect(importVerdict("Prepass.zig", "../check/Scc.zig", false) == null);
    try testing.expect(importVerdict("Prepass.zig", "../bir/Lower.zig", false) != null);
    try testing.expect(importVerdict("Prepass.zig", "../bir/Lower.zig", true) == null);
    try testing.expect(importVerdict("Cell.zig", "Ids.zig", false) == null);
    try testing.expect(importVerdict("Ids.zig", "Cell.zig", false) != null);
    try testing.expect(importVerdict("Cell.zig", "Facts.zig", false) != null);
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
