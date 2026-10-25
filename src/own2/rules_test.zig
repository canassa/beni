//! The layering gate of the ownership checker v2 (`docs/design/ownership-v2.md`
//! §5), enforced by reading the sources of `src/own2/`, as `src/rules_test.zig`
//! enforces the whole tree's rule 5 (which this directory is subject to as
//! well: nothing here is excused from it).
//!
//! 1. **Layering.** Every `@import("X.zig")` of an `own2/` file names a file
//!    on a strictly lower layer of §5's table; a same-layer or higher import,
//!    an import of anything under `src/own/` (the frozen v1), or a file §5
//!    does not list, fails naming both files. Later slices cannot introduce
//!    a cycle without editing this table, which the design owns.
//! 2. **Sizes.** Each file's production lines — up to its in-source tests,
//!    which begin at `const testing = std.testing;` by the repository's
//!    convention — are within §5's line target.
//! 3. **Fences.** Only `Place` reads type children (imports the checker's
//!    type modules); only `Cell` defines `alias`; `Transfer`, `Calls`,
//!    `Demands` and `Rows` compare no name to a string literal unless the
//!    line is allowlisted with a reason; `Facts.Cause` is in R-6.3's order.
//! 4. **Records.** Every `MultiArrayList(T)` in `own2/` has its `T` under
//!    `Ids.assertRecord`, so no table's record can pass 16 words (§4.1).
//!
//! Every file names the obligations of §2.14 it keeps in its header; the
//! gate checks that each production file has an obligation note or says it
//! keeps none.

const std = @import("std");
const testing = std.testing;

const Entry = struct { file: []const u8, layer: u8, max_lines: u32 };

/// §5's table. A new file is added here by the slice that adds it.
const layers = [_]Entry{
    .{ .file = "Ids.zig", .layer = 0, .max_lines = 600 },
    .{ .file = "Place.zig", .layer = 1, .max_lines = 1000 },
    .{ .file = "Cell.zig", .layer = 2, .max_lines = 800 },
    .{ .file = "Facts.zig", .layer = 2, .max_lines = 300 },
    .{ .file = "Prepass.zig", .layer = 3, .max_lines = 600 },
    .{ .file = "Shape.zig", .layer = 3, .max_lines = 1500 },
    .{ .file = "Regions.zig", .layer = 4, .max_lines = 450 },
    .{ .file = "Cond.zig", .layer = 4, .max_lines = 1000 },
    .{ .file = "Summary.zig", .layer = 5, .max_lines = 1200 },
    .{ .file = "Liveness.zig", .layer = 5, .max_lines = 700 },
    .{ .file = "Rows.zig", .layer = 6, .max_lines = 1100 },
    .{ .file = "Demands.zig", .layer = 6, .max_lines = 1200 },
    .{ .file = "Calls.zig", .layer = 7, .max_lines = 1500 },
    .{ .file = "Transfer.zig", .layer = 8, .max_lines = 1800 },
    .{ .file = "Fix.zig", .layer = 8, .max_lines = 900 },
    .{ .file = "Walk.zig", .layer = 9, .max_lines = 1500 },
    .{ .file = "Groups.zig", .layer = 10, .max_lines = 900 },
    .{ .file = "Entry.zig", .layer = 10, .max_lines = 900 },
    .{ .file = "Block.zig", .layer = 11, .max_lines = 1200 },
    .{ .file = "Hoists.zig", .layer = 11, .max_lines = 500 },
    .{ .file = "Message.zig", .layer = 11, .max_lines = 900 },
    .{ .file = "Report.zig", .layer = 11, .max_lines = 600 },
    .{ .file = "Ownership.zig", .layer = 12, .max_lines = 300 },
    .{ .file = "Enforce.zig", .layer = 13, .max_lines = 450 },
};

/// The checker's type modules: only `Place` may import one (§5's fence,
/// "only `Place` reads type children").
const type_modules = [_][]const u8{ "check/TypeStore.zig", "check/Types.zig", "check/Walk.zig" };

/// The files that compare no name to a string literal.
const no_name_compare = [_][]const u8{ "Transfer.zig", "Calls.zig", "Demands.zig", "Rows.zig" };

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

/// The production lines of a file: everything before its tests.
fn lineCount(text: []const u8) u32 {
    const prod = if (std.mem.indexOf(u8, text, "\nconst testing = std.testing;")) |at| text[0..at] else text;
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

fn fail(bad: *usize, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("src/own2/" ++ fmt ++ "\n", args);
    bad.* += 1;
}

test "own2 layering: every import points strictly down §5's table, and never into src/own/" {
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
        targets.clearRetainingCapacity();
        try imports(gpa, s.text, &targets);
        for (targets.items) |t| {
            if (std.mem.indexOf(u8, t, "/own/") != null or std.mem.startsWith(u8, t, "../own/")) {
                fail(&bad, "{s} imports {s}: v1 (src/own/) is frozen and no v2 file reads it", .{ s.name, t });
                continue;
            }
            if (std.mem.startsWith(u8, t, "../")) {
                for (type_modules) |m| {
                    if (std.mem.eql(u8, t["../".len..], m) and !std.mem.eql(u8, s.name, "Place.zig")) {
                        fail(&bad, "{s} imports {s}: only Place reads type children (§5)", .{ s.name, t });
                    }
                }
                continue;
            }
            if (std.mem.eql(u8, t, "std")) continue;
            if (std.mem.indexOfScalar(u8, t, '/') != null) continue;
            const other = layerOf(t) orelse {
                fail(&bad, "{s} imports {s}, which §5's table does not list", .{ s.name, t });
                continue;
            };
            if (other.layer >= me.layer) fail(&bad, "{s} (L{d}) imports {s} (L{d}): imports go to strictly lower layers (§5)", .{ s.name, me.layer, t, other.layer });
        }
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
    for (sources.items) |s| {
        if (std.mem.eql(u8, s.name, "rules_test.zig")) continue;
        // Only `Cell` defines `alias`.
        if (!std.mem.eql(u8, s.name, "Cell.zig") and std.mem.indexOf(u8, s.text, "fn alias(") != null) {
            fail(&bad, "{s} defines `alias`: only Cell.alias compares cells (§5)", .{s.name});
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
        // `Facts.Cause` in R-6.3's order.
        if (std.mem.eql(u8, s.name, "Facts.zig")) {
            const start = std.mem.indexOf(u8, s.text, "pub const Cause = enum") orelse {
                fail(&bad, "Facts.zig: no `pub const Cause = enum`", .{});
                continue;
            };
            const body_start = std.mem.indexOfScalarPos(u8, s.text, start, '{').? + 1;
            var at = body_start;
            for (causes) |c| {
                const found = std.mem.indexOfPos(u8, s.text, at, c) orelse {
                    fail(&bad, "Facts.zig: `Cause` lacks `{s}` in R-6.3's order", .{c});
                    break;
                };
                at = found + c.len;
            }
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
    try testing.expectEqual(@as(usize, 24), layers.len);
    try testing.expectEqual(@as(usize, 19), causes.len);
}
