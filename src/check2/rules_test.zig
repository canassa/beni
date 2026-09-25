//! Structural rules of `src/check2/` that its shared store cannot enforce by
//! construction, enforced by reading the sources (R4b's review, S2, S6).
//!
//! - **v1 stays deletable (S2).** No file imports v1's `Constrain.zig` or
//!   `Solve.zig`; only `Driver.zig` imports v1's `Check.zig` — the one switch
//!   between the checkers, until R11. Everything else v2 takes from
//!   `src/check/` is on §19's KEPT list (`checker-v2.md` §19.1 *As built*).
//! - **I2: children only through `Walk` (S6).** A type's children — a
//!   range's variables, a record's fields, a variable's constraints — are
//!   read only in `Walk.zig`, and in `Unify.zig` and `Instantiate.zig`, which
//!   pair two structures and copy one. Anyone may read a node's TAG and flags.
//!
//! The file list is checked against the directory, so a new file cannot slip
//! past it.

const std = @import("std");
const testing = std.testing;

const File = struct { path: []const u8, text: []const u8 };

const files = [_]File{
    .{ .path = "Check.zig", .text = @embedFile("Check.zig") },
    .{ .path = "Context.zig", .text = @embedFile("Context.zig") },
    .{ .path = "Decide.zig", .text = @embedFile("Decide.zig") },
    .{ .path = "Driver.zig", .text = @embedFile("Driver.zig") },
    .{ .path = "Generalize.zig", .text = @embedFile("Generalize.zig") },
    .{ .path = "Incremental.zig", .text = @embedFile("Incremental.zig") },
    .{ .path = "Instances.zig", .text = @embedFile("Instances.zig") },
    .{ .path = "Instantiate.zig", .text = @embedFile("Instantiate.zig") },
    .{ .path = "Messages.zig", .text = @embedFile("Messages.zig") },
    .{ .path = "Module.zig", .text = @embedFile("Module.zig") },
    .{ .path = "Obligations.zig", .text = @embedFile("Obligations.zig") },
    .{ .path = "Publish.zig", .text = @embedFile("Publish.zig") },
    .{ .path = "Report.zig", .text = @embedFile("Report.zig") },
    .{ .path = "Solve.zig", .text = @embedFile("Solve.zig") },
    .{ .path = "Subset.zig", .text = @embedFile("Subset.zig") },
    .{ .path = "Unify.zig", .text = @embedFile("Unify.zig") },
    .{ .path = "Walk.zig", .text = @embedFile("Walk.zig") },
    .{ .path = "rules_test.zig", .text = "" },
    .{ .path = "constrain/Decl.zig", .text = @embedFile("constrain/Decl.zig") },
    .{ .path = "constrain/Expr.zig", .text = @embedFile("constrain/Expr.zig") },
    .{ .path = "constrain/Pattern.zig", .text = @embedFile("constrain/Pattern.zig") },
    .{ .path = "constrain/Tree.zig", .text = @embedFile("constrain/Tree.zig") },
};

/// May read children (I2).
const child_readers = [_][]const u8{ "Walk.zig", "Unify.zig", "Instantiate.zig" };

const child_reads = [_][]const u8{
    "store.vars(",       "st.vars(",        "store().vars(", "store.fields(",
    "st.fields(",        "store().fields(", "constraintAt(", "constraintCount(",
    "flags.constraints",
};

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

test "check2 imports neither v1's Constrain nor its Solve, and only the driver imports v1's Check" {
    var bad: usize = 0;
    for (files) |f| {
        var it = codeLines(f.text);
        while (it.next()) |line| {
            if (isComment(line)) continue;
            for ([_][]const u8{ "check/Constrain.zig\"", "check/Solve.zig\"" }) |v1| {
                if (std.mem.indexOf(u8, line, v1) != null) {
                    std.debug.print("{s} imports v1's {s}\n", .{ f.path, v1 });
                    bad += 1;
                }
            }
            if (std.mem.indexOf(u8, line, "check/Check.zig\"") != null and !std.mem.eql(u8, f.path, "Driver.zig")) {
                std.debug.print("{s} imports v1's Check.zig\n", .{f.path});
                bad += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "I2: only Walk, Unify and Instantiate read a type's children" {
    var bad: usize = 0;
    for (files) |f| {
        if (listed(f.path, &child_readers) or std.mem.eql(u8, f.path, "rules_test.zig")) continue;
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

test "the rules read every file of src/check2" {
    const io = testing.io;
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| testing.allocator.free(n);
        names.deinit(testing.allocator);
    }
    for ([_][]const u8{ "src/check2", "src/check2/constrain" }) |dir_path| {
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
        if (!found) std.debug.print("src/check2/{s} is not in rules_test.zig's list\n", .{n});
        try testing.expect(found);
    }
    try testing.expectEqual(files.len, names.items.len);
}
