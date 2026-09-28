//! Structural rules of `src/check/` that its shared store cannot enforce by
//! construction, enforced by reading the sources (R4b's review, S2, S6;
//! restated by R12 when v1 was deleted and `src/check2/` took this name).
//!
//! - **I2: children only through `Walk` (S6).** A type's children — a
//!   range's variables, a record's fields, a variable's constraints — are
//!   read only in `Walk.zig`, and in `Unify.zig` and `Instantiate.zig`, which
//!   pair two structures and copy one. Anyone may read a node's TAG and flags.
//!   The files kept from before the rewrite that own, serialise or print a
//!   type (`shared_child_readers`) are the exception, and a listed one.
//! - **The table's structural bits have listed readers (review S4, R8a,
//!   R8b).** `Types.isEquatable` is read by `Marker.zig`'s structural bit
//!   (§11.4) alone, and a `foreign type`'s DECLARED `equatable` bit by
//!   `Derivable.foreignDerives` and `Publish` alone: §11.2's derived contexts
//!   (`Contexts.zig`) are the one answer to "does this type derive". The
//!   table's other two bits, `comparable` and `has_function`, have no reader
//!   in the checker at all (the cache's digest reads them). Until R12 this
//!   fence also listed v1's capability API — the settle, its per-module bits
//!   and the schema endpoints' settled properties — which R12 deleted.
//! - **No file over §19.1's 1 500 lines** (`checker-v2.md` §19.1): a file
//!   past it is split, as §19.1's notes record each time one was.
//!
//! (The fence that kept v1 deletable, S2 — nothing imports v1's
//! `Constrain.zig` or `Solve.zig`, only the driver its `Check.zig` — held
//! until R12 deleted all three.)
//!
//! The file list is checked against the directory, so a new file cannot slip
//! past any of them.

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
    .{ .path = "Scc.zig", .text = @embedFile("Scc.zig") },
    .{ .path = "Schema.zig", .text = @embedFile("Schema.zig") },
    .{ .path = "SchemaPlan.zig", .text = @embedFile("SchemaPlan.zig") },
    .{ .path = "SchemaPlanBuild.zig", .text = @embedFile("SchemaPlanBuild.zig") },
    .{ .path = "Schemes.zig", .text = @embedFile("Schemes.zig") },
    .{ .path = "Solve.zig", .text = @embedFile("Solve.zig") },
    .{ .path = "TypeStore.zig", .text = @embedFile("TypeStore.zig") },
    .{ .path = "Types.zig", .text = @embedFile("Types.zig") },
    .{ .path = "Unify.zig", .text = @embedFile("Unify.zig") },
    .{ .path = "Unit.zig", .text = @embedFile("Unit.zig") },
    .{ .path = "Walk.zig", .text = @embedFile("Walk.zig") },
    .{ .path = "checker_test.zig", .text = @embedFile("checker_test.zig") },
    .{ .path = "reads.zig", .text = @embedFile("reads.zig") },
    .{ .path = "rules_test.zig", .text = "" },
    .{ .path = "constrain/Decl.zig", .text = @embedFile("constrain/Decl.zig") },
    .{ .path = "constrain/Expr.zig", .text = @embedFile("constrain/Expr.zig") },
    .{ .path = "constrain/Pattern.zig", .text = @embedFile("constrain/Pattern.zig") },
    .{ .path = "constrain/Tree.zig", .text = @embedFile("constrain/Tree.zig") },
};

/// May read children (I2).
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

test "I2: only Walk, Unify and Instantiate read a type's children" {
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

/// The reads the second rule fences, and who may make each.
const Fenced = struct { pattern: []const u8, readers: []const []const u8 };

/// `Types.zig` builds the bits and `Schemes.zig` writes a blank entry for a
/// poisoned id; every other file is held to the list. `e.equatable` and
/// `).equatable` catch the other spellings of the same read (R8b's review,
/// S4); "e.equatable" is also inside "entry.equatable", which is not a second
/// read in a file allowed the first.
const fenced = [_]Fenced{
    .{ .pattern = "isEquatable(", .readers = &.{"Marker.zig"} },
    .{ .pattern = "entry.equatable", .readers = &.{ "Derivable.zig", "Publish.zig" } },
    .{ .pattern = "e.equatable", .readers = &.{} },
    .{ .pattern = ").equatable", .readers = &.{} },
    .{ .pattern = ".comparable", .readers = &.{} },
    .{ .pattern = ".has_function", .readers = &.{} },
};

const table_writers = [_][]const u8{ "Types.zig", "Schemes.zig" };

test "the table's structural bits are read by their listed readers alone" {
    var bad: usize = 0;
    for (files) |f| {
        if (listed(f.path, &table_writers) or std.mem.eql(u8, f.path, "rules_test.zig")) continue;
        var it = codeLines(f.text);
        var n: usize = 0;
        while (it.next()) |line| {
            n += 1;
            if (isComment(line)) continue;
            for (fenced) |rule| {
                if (std.mem.indexOf(u8, line, rule.pattern) == null) continue;
                if (listed(f.path, rule.readers)) continue;
                if (std.mem.eql(u8, rule.pattern, "e.equatable") and std.mem.indexOf(u8, line, "entry.equatable") != null and
                    listed(f.path, fenced[1].readers)) continue;
                std.debug.print("{s}:{d} reads a structural bit of the type table: `{s}`\n", .{ f.path, n, rule.pattern });
                bad += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
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
