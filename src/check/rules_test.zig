//! Structural rules of `src/check/` that its shared store cannot enforce by
//! construction, enforced by reading the sources.
//!
//! - **Children only through `Walk`.** A type's children — a
//!   range's variables, a record's fields, a variable's constraints — are
//!   read only in `Walk.zig`, and in `Unify.zig` and `Instantiate.zig`, which
//!   pair two structures and copy one. Anyone may read a node's TAG and flags.
//!   The files kept from before the rewrite that own, serialise or print a
//!   type (`shared_child_readers`) are the exception, and a listed one.
//! - **The table's structural bits have listed readers.**
//!   `Types.isEquatable` is read by `Marker.zig`'s structural bit
//!   (§11.4) alone, and a `foreign type`'s DECLARED `equatable` bit by
//!   `Derivable.foreignDerives` and `Publish` alone: §11.2's derived contexts
//!   (`Contexts.zig`) are the one answer to "does this type derive". The
//!   table's other two bits, `comparable` and `has_function`, have no reader
//!   in the checker but one: effect inference asks `has_function` which
//!   nominal applications carry a class (transparent-effects-proposal.md
//!   §14.5), and the cache's digest reads both. A read is any
//!   field access of one of the three names whose receiver is not a
//!   variable's flags or an interface quantifier, however the receiver is
//!   spelled, and the rule reads `src/js` and `src/cache` as well.
//! - **No file over §19.1's 1 500 lines** (`checker-v2.md` §19.1): a file
//!   past it is split, as §19.1's notes record each time one was.
//!
//! The file list is checked against the directory, so a new file cannot slip
//! past any of them; the table-bit rule reads its directories at test time.

const std = @import("std");
const testing = std.testing;

const File = struct { path: []const u8, text: []const u8 };

const files = [_]File{
    .{ .path = "Category.zig", .text = @embedFile("Category.zig") },
    .{ .path = "Check.zig", .text = @embedFile("Check.zig") },
    .{ .path = "ColumnIndex.zig", .text = @embedFile("ColumnIndex.zig") },
    .{ .path = "Command.zig", .text = @embedFile("Command.zig") },
    .{ .path = "Context.zig", .text = @embedFile("Context.zig") },
    .{ .path = "ContextUnits.zig", .text = @embedFile("ContextUnits.zig") },
    .{ .path = "Contexts.zig", .text = @embedFile("Contexts.zig") },
    .{ .path = "Convention.zig", .text = @embedFile("Convention.zig") },
    .{ .path = "Cycles.zig", .text = @embedFile("Cycles.zig") },
    .{ .path = "Decide.zig", .text = @embedFile("Decide.zig") },
    .{ .path = "Derivable.zig", .text = @embedFile("Derivable.zig") },
    .{ .path = "Diagnostics.zig", .text = @embedFile("Diagnostics.zig") },
    .{ .path = "Dispatch.zig", .text = @embedFile("Dispatch.zig") },
    .{ .path = "DispatchTexts.zig", .text = @embedFile("DispatchTexts.zig") },
    .{ .path = "Driver.zig", .text = @embedFile("Driver.zig") },
    .{ .path = "Eager.zig", .text = @embedFile("Eager.zig") },
    .{ .path = "Edges.zig", .text = @embedFile("Edges.zig") },
    .{ .path = "Effects.zig", .text = @embedFile("Effects.zig") },
    .{ .path = "Elaborate.zig", .text = @embedFile("Elaborate.zig") },
    .{ .path = "Env.zig", .text = @embedFile("Env.zig") },
    .{ .path = "Evidence.zig", .text = @embedFile("Evidence.zig") },
    .{ .path = "Exhaustive.zig", .text = @embedFile("Exhaustive.zig") },
    .{ .path = "Generalize.zig", .text = @embedFile("Generalize.zig") },
    .{ .path = "Groups.zig", .text = @embedFile("Groups.zig") },
    .{ .path = "Incremental.zig", .text = @embedFile("Incremental.zig") },
    .{ .path = "Injective.zig", .text = @embedFile("Injective.zig") },
    .{ .path = "Instances.zig", .text = @embedFile("Instances.zig") },
    .{ .path = "Instantiate.zig", .text = @embedFile("Instantiate.zig") },
    .{ .path = "InterfaceTerms.zig", .text = @embedFile("InterfaceTerms.zig") },
    .{ .path = "Marker.zig", .text = @embedFile("Marker.zig") },
    .{ .path = "Markup.zig", .text = @embedFile("Markup.zig") },
    .{ .path = "MarkupDecide.zig", .text = @embedFile("MarkupDecide.zig") },
    .{ .path = "MarkupTexts.zig", .text = @embedFile("MarkupTexts.zig") },
    .{ .path = "Messages.zig", .text = @embedFile("Messages.zig") },
    .{ .path = "Module.zig", .text = @embedFile("Module.zig") },
    .{ .path = "Obligations.zig", .text = @embedFile("Obligations.zig") },
    .{ .path = "PatternStore.zig", .text = @embedFile("PatternStore.zig") },
    .{ .path = "PatternTexts.zig", .text = @embedFile("PatternTexts.zig") },
    .{ .path = "Producers.zig", .text = @embedFile("Producers.zig") },
    .{ .path = "Publish.zig", .text = @embedFile("Publish.zig") },
    .{ .path = "Recursion.zig", .text = @embedFile("Recursion.zig") },
    .{ .path = "Render.zig", .text = @embedFile("Render.zig") },
    .{ .path = "Report.zig", .text = @embedFile("Report.zig") },
    .{ .path = "Resolve.zig", .text = @embedFile("Resolve.zig") },
    .{ .path = "Retained.zig", .text = @embedFile("Retained.zig") },
    .{ .path = "Scc.zig", .text = @embedFile("Scc.zig") },
    .{ .path = "Schema.zig", .text = @embedFile("Schema.zig") },
    .{ .path = "SchemaPlan.zig", .text = @embedFile("SchemaPlan.zig") },
    .{ .path = "SchemaPlanBuild.zig", .text = @embedFile("SchemaPlanBuild.zig") },
    .{ .path = "Schemes.zig", .text = @embedFile("Schemes.zig") },
    .{ .path = "Solve.zig", .text = @embedFile("Solve.zig") },
    .{ .path = "TypeFacts.zig", .text = @embedFile("TypeFacts.zig") },
    .{ .path = "TypeStore.zig", .text = @embedFile("TypeStore.zig") },
    .{ .path = "Types.zig", .text = @embedFile("Types.zig") },
    .{ .path = "Unify.zig", .text = @embedFile("Unify.zig") },
    .{ .path = "Unit.zig", .text = @embedFile("Unit.zig") },
    .{ .path = "Vocab.zig", .text = @embedFile("Vocab.zig") },
    .{ .path = "Walk.zig", .text = @embedFile("Walk.zig") },
    .{ .path = "checker_test.zig", .text = @embedFile("checker_test.zig") },
    .{ .path = "int_hash.zig", .text = @embedFile("int_hash.zig") },
    .{ .path = "reads.zig", .text = @embedFile("reads.zig") },
    .{ .path = "rules_test.zig", .text = "" },
    .{ .path = "constrain/Decl.zig", .text = @embedFile("constrain/Decl.zig") },
    .{ .path = "constrain/Expr.zig", .text = @embedFile("constrain/Expr.zig") },
    .{ .path = "constrain/Markup.zig", .text = @embedFile("constrain/Markup.zig") },
    .{ .path = "constrain/Pattern.zig", .text = @embedFile("constrain/Pattern.zig") },
    .{ .path = "constrain/Tree.zig", .text = @embedFile("constrain/Tree.zig") },
};

/// May read children.
const child_readers = [_][]const u8{ "Walk.zig", "Unify.zig", "Instantiate.zig" };

/// Kept from before the rewrite (`checker-v2.md` §19's KEPT list), and they
/// read children because that is what they are for: the store itself, its
/// interface writer and reader, the printer and the texts that print with it,
/// and the schema endpoints' builder. Nothing the solver runs is here.
const shared_child_readers = [_][]const u8{ "TypeStore.zig", "Schemes.zig", "Render.zig", "Diagnostics.zig", "Schema.zig" };

const child_reads = [_][]const u8{
    "store.vars(",       "st.vars(",        "store().vars(", "store.fields(",
    "st.fields(",        "store().fields(", "constraintAt(", "constraintCount(",
    "flags.constraints",
};

/// §19.1's figure: no file over about 1 500 lines.
const max_lines = 1500;

fn listed(path: []const u8, list: []const []const u8) bool {
    for (list) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

fn codeLines(text: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, text, '\n');
}

fn isComment(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " ");
    return std.mem.startsWith(u8, t, "//");
}

test "only Walk, Unify and Instantiate read a type's children" {
    var bad: usize = 0;
    for (files) |f| {
        if (listed(f.path, &child_readers) or listed(f.path, &shared_child_readers)) continue;
        if (std.mem.eql(u8, f.path, "rules_test.zig")) continue;
        var it = codeLines(f.text);
        var n: usize = 0;
        while (it.next()) |line| {
            n += 1;
            if (isComment(line)) continue;
            for (child_reads) |pattern| {
                if (std.mem.indexOf(u8, line, pattern) == null) continue;
                std.debug.print("{s}:{d} reads children outside Walk: `{s}`\n", .{ f.path, n, pattern });
                bad += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

/// The table's structural bits, and who may read each besides the
/// files that build the table (`table_writers`).
const Bit = struct { name: []const u8, readers: []const []const u8 };

const bits = [_]Bit{
    .{ .name = "equatable", .readers = &.{ "check/Derivable.zig", "check/Publish.zig", "cache/Digest.zig" } },
    .{ .name = "comparable", .readers = &.{"cache/Digest.zig"} },
    .{ .name = "has_function", .readers = &.{ "check/Effects.zig", "cache/Digest.zig" } },
    .{ .name = "holds_markup", .readers = &.{ "check/Vocab.zig", "cache/Digest.zig" } },
};

/// `Types.zig` and `TypeFacts.zig` build the bits and `Schemes.zig` writes a blank entry for a
/// poisoned id.
const table_writers = [_][]const u8{ "check/Types.zig", "check/TypeFacts.zig", "check/Schemes.zig" };

/// The receivers whose `.equatable` is a type variable's marker or an
/// interface quantifier's, never the table's: a `TypeStore.Flags`
/// (`flags`, `fa`, `fb`, `joined`, `flagged`, `f`) or an
/// `Interface.Quantified` (`q`, `info`). Any other receiver of one of the
/// three names is a read of the table.
const flag_receivers = [_][]const u8{ "flags", "fa", "fb", "joined", "flagged", "f", "q", "info" };

/// The directories the rule reads, at test time, so a file added to any of
/// them is read without being listed.
const fenced_dirs = [_][]const u8{ "check", "check/constrain", "js", "cache" };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The table-bit reads on `line`: every `<receiver>.<bit>` that is a field
/// read — the receiver ends in a name, `]` or `)`, and no `(` follows, which
/// would make it a method call — whose receiver is not in `flag_receivers`.
fn tableReads(line: []const u8, bit: []const u8) usize {
    var found: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, bit)) |at| {
        from = at + bit.len;
        if (at < 2 or line[at - 1] != '.') continue;
        if (from < line.len and (isIdent(line[from]) or line[from] == '(')) continue;
        const before = line[at - 2];
        if (!isIdent(before) and before != ']' and before != ')') continue;
        if (isIdent(before)) {
            var start = at - 1;
            while (start > 0 and isIdent(line[start - 1])) start -= 1;
            if (listed(line[start .. at - 1], &flag_receivers)) continue;
        }
        found += 1;
    }
    return found;
}

test "the table's structural bits are read by their listed readers alone" {
    const io = testing.io;
    const gpa = testing.allocator;
    var bad: usize = 0;
    var read: usize = 0;
    for (fenced_dirs) |sub| {
        const dir_path = try std.fs.path.join(gpa, &.{ "src", sub });
        defer gpa.free(dir_path);
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            if (std.mem.eql(u8, entry.name, "rules_test.zig")) continue;
            const path = try std.fs.path.join(gpa, &.{ sub, entry.name });
            defer gpa.free(path);
            if (listed(path, &table_writers)) continue;
            const text = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 24));
            defer gpa.free(text);
            read += 1;
            var lines = codeLines(text);
            var n: usize = 0;
            while (lines.next()) |line| {
                n += 1;
                if (isComment(line)) continue;
                if (std.mem.indexOf(u8, line, "isEquatable(") != null and !std.mem.eql(u8, path, "check/Marker.zig")) {
                    std.debug.print("src/{s}:{d} reads a structural bit of the type table: `isEquatable`\n", .{ path, n });
                    bad += 1;
                }
                for (bits) |b| {
                    if (tableReads(line, b.name) == 0 or listed(path, b.readers)) continue;
                    std.debug.print("src/{s}:{d} reads a structural bit of the type table: `{s}`\n", .{ path, n, b.name });
                    bad += 1;
                }
            }
        }
    }
    try testing.expect(read > 0);
    try testing.expectEqual(@as(usize, 0), bad);
}

test "a table-bit read is told from a variable's marker by its receiver" {
    try testing.expectEqual(@as(usize, 1), tableReads("if (entry.equatable) x", "equatable"));
    try testing.expectEqual(@as(usize, 1), tableReads("t.equatable and", "equatable"));
    try testing.expectEqual(@as(usize, 1), tableReads("entries[i].equatable", "equatable"));
    try testing.expectEqual(@as(usize, 1), tableReads("types.entry(id).comparable", "comparable"));
    try testing.expectEqual(@as(usize, 1), tableReads("s.types.entry(id).has_function", "has_function"));
    try testing.expectEqual(@as(usize, 0), tableReads("if (flags.equatable) x", "equatable"));
    try testing.expectEqual(@as(usize, 0), tableReads("kind == .equatable", "equatable"));
    try testing.expectEqual(@as(usize, 0), tableReads("s.marker.equatable(v)", "equatable"));
    try testing.expectEqual(@as(usize, 0), tableReads(".equatable = true,", "equatable"));
    try testing.expectEqual(@as(usize, 0), tableReads("header.equatable_token", "equatable"));
}

test "no file of src/check is over 1 500 lines" {
    var bad: usize = 0;
    for (files) |f| {
        if (std.mem.eql(u8, f.path, "rules_test.zig")) continue;
        const lines = std.mem.count(u8, f.text, "\n");
        if (lines <= max_lines) continue;
        std.debug.print("src/check/{s} is {d} lines, past checker-v2.md §19.1's {d}: split it\n", .{ f.path, lines, max_lines });
        bad += 1;
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "the rules read every file of src/check" {
    const io = testing.io;
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| testing.allocator.free(n);
        names.deinit(testing.allocator);
    }
    for ([_][]const u8{ "src/check", "src/check/constrain" }) |dir_path| {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            const prefix = if (std.mem.endsWith(u8, dir_path, "constrain")) "constrain/" else "";
            try names.append(testing.allocator, try std.mem.concat(testing.allocator, u8, &.{ prefix, entry.name }));
        }
    }
    for (names.items) |n| {
        var found = false;
        for (files) |f| {
            if (std.mem.eql(u8, f.path, n)) found = true;
        }
        if (!found) std.debug.print("src/check/{s} is not in rules_test.zig's list\n", .{n});
        try testing.expect(found);
    }
    try testing.expectEqual(files.len, names.items.len);
}
