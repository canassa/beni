//! `--diagnostics=text` renderer: Elm's layout (docs/design/frontend.md §1.1).
//!
//! ```
//! -- TAB CHARACTER ----------------------------------------- src/Main.beni:3:5
//!
//! I found a tab character. Beni does not allow tabs anywhere in a file.
//!
//! 3|     view = 1
//!        ^
//! ```
//!
//! The excerpt is cut from the file's bytes, which the caller supplies through
//! a lookup: this module never touches the filesystem, so it can be tested on
//! a string and reused by a daemon that holds sources in memory. A diagnostic
//! whose file is not available (or whose line is out of range) is rendered
//! without an excerpt rather than dropped. Input must already be in emission
//! order (`diagnostic.sort`).

const std = @import("std");
const diagnostic = @import("diagnostic");

/// Where the excerpt bytes come from. `lookup` returns the whole file, or
/// null when the renderer should skip the excerpt.
pub const Sources = struct {
    context: *const anyopaque,
    lookup: *const fn (context: *const anyopaque, file: []const u8) ?[]const u8,

    /// A source set with no files at all: every excerpt is skipped.
    pub const none: Sources = .{ .context = undefined, .lookup = lookupNone };

    fn lookupNone(_: *const anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }
};

/// Elm pads its header rule to this width.
const header_width = 80;

/// Most bytes of an excerpt line kept around the span. A minified file, a
/// generated one, or a one-megabyte comment is one line; printing it whole
/// put 1.49 MB on stderr for a single diagnostic, and a span at column
/// 900 000 would have added 900 KB of caret padding under it. Elm windows;
/// so do we, marking each cut end with `…`.
const max_excerpt_bytes = 120;

/// Where the last excerpt was cut from, so the next one can resume.
/// Diagnostics arrive sorted by file and then by position
/// (`diagnostic.sort`), so within a file the line numbers only go up.
/// Without this, `lineAt` counted newlines from byte 0 for every
/// diagnostic and text rendering was quadratic in their number: 16 000
/// errors in a 400 KB file took 38 s, against 0.43 s for the same run
/// rendered as JSON.
const Cursor = struct {
    /// The file `line`/`offset` refer to; empty before the first excerpt.
    /// Compared by bytes, not by pointer: `Sources` may hand out any
    /// string it likes.
    file: []const u8 = &.{},
    /// 1-based number of the line beginning at `offset`.
    line: u32 = 1,
    offset: usize = 0,
};

/// Render every diagnostic, one blank line between them. Writes nothing for
/// an empty slice.
pub fn render(writer: *std.Io.Writer, diagnostics: []const diagnostic.Diagnostic, sources: Sources) std.Io.Writer.Error!void {
    var cursor: Cursor = .{};
    for (diagnostics, 0..) |d, i| {
        if (i != 0) try writer.writeByte('\n');
        try renderOneAt(writer, d, sources.lookup(sources.context, d.span.file), &cursor);
    }
}

/// Render one diagnostic on its own, rescanning for its line. `render` is
/// the entry point that keeps a cursor; this one exists for callers with a
/// single diagnostic and for the tests.
pub fn renderOne(writer: *std.Io.Writer, d: diagnostic.Diagnostic, source: ?[]const u8) std.Io.Writer.Error!void {
    var cursor: Cursor = .{};
    return renderOneAt(writer, d, source, &cursor);
}

fn renderOneAt(writer: *std.Io.Writer, d: diagnostic.Diagnostic, source: ?[]const u8, cursor: *Cursor) std.Io.Writer.Error!void {
    // -- TITLE ------ file:line:col
    try writer.writeAll("-- ");
    try writer.writeAll(d.title);
    try writer.writeByte(' ');
    var location_buf: [64]u8 = undefined;
    const location = std.fmt.bufPrint(&location_buf, ":{d}:{d}", .{ d.span.start.line, d.span.start.col }) catch unreachable;
    const used = 3 + d.title.len + 1 + 1 + d.span.file.len + location.len;
    const dashes = if (used < header_width) header_width - used else 1;
    try writer.splatByteAll('-', dashes);
    try writer.writeByte(' ');
    try writer.writeAll(d.span.file);
    try writer.writeAll(location);
    try writer.writeAll("\n\n");

    try writer.writeAll(d.message);
    try writer.writeByte('\n');

    if (source) |text| {
        if (lineAt(text, d.span.file, d.span.start.line, cursor)) |line| {
            try writer.writeByte('\n');
            try renderExcerpt(writer, d.span, line);
        }
    }
}

/// The bytes of 1-based `line_number` without its terminator, or null when
/// the file has fewer lines. `\r` before the newline is stripped so a CRLF
/// file does not leave a stray byte in the excerpt. `cursor` is advanced to
/// the line found, and resumed from when the next call asks for the same
/// file at the same line or later.
fn lineAt(text: []const u8, file: []const u8, line_number: u32, cursor: *Cursor) ?[]const u8 {
    if (line_number == 0) return null;
    if (!std.mem.eql(u8, cursor.file, file) or cursor.line > line_number or cursor.offset > text.len) {
        cursor.* = .{ .file = file, .line = 1, .offset = 0 };
    }
    var current = cursor.line;
    var start = cursor.offset;
    var found = true;
    while (current < line_number) : (current += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse {
            found = false;
            break;
        };
        start = nl + 1;
    }
    cursor.line = current;
    cursor.offset = start;
    if (!found) return null;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return std.mem.trimEnd(u8, text[start..end], "\r");
}

/// `3|     view = 1` and, under it, a caret run covering the span on its
/// first line. A span that ends on a later line, or an empty one, gets a
/// single caret.
fn renderExcerpt(writer: *std.Io.Writer, span: diagnostic.Span, line: []const u8) std.Io.Writer.Error!void {
    var number_buf: [16]u8 = undefined;
    const number = std.fmt.bufPrint(&number_buf, "{d}", .{span.start.line}) catch unreachable;
    const col: usize = @max(span.start.col, 1);
    const width: usize = if (span.end.line == span.start.line and span.end.col > span.start.col)
        span.end.col - span.start.col
    else
        1;
    const w = window(line, col, width);

    try writer.writeAll(number);
    try writer.writeByte('|');
    if (w.cut_left) try writer.writeAll(ellipsis);
    try writer.writeAll(w.text);
    if (w.cut_right) try writer.writeAll(ellipsis);
    try writer.writeByte('\n');

    const left_pad = number.len + 1 + (if (w.cut_left) ellipsis.len else 0) + w.caret_col - 1;
    try writer.splatByteAll(' ', left_pad);
    try writer.splatByteAll('^', @min(width, w.text.len - (w.caret_col - 1) + 1));
    try writer.writeByte('\n');
}

const ellipsis = "…";

const Window = struct {
    text: []const u8,
    /// 1-based column of the span's start WITHIN `text`.
    caret_col: usize,
    cut_left: bool,
    cut_right: bool,
};

/// At most `max_excerpt_bytes` of `line` around the span at `col` (1-based,
/// `width` bytes). Whole lines shorter than the limit are returned as they
/// are, so ordinary code is unaffected; a long line is cut on either side
/// and the cut end marked.
fn window(line: []const u8, col: usize, width: usize) Window {
    if (line.len <= max_excerpt_bytes) return .{ .text = line, .caret_col = col, .cut_left = false, .cut_right = false };
    // Keep the span, and as much context around it as the budget allows.
    const span_start = @min(col - 1, line.len);
    const span_end = @min(span_start + width, line.len);
    const context = (max_excerpt_bytes -| (span_end - span_start)) / 2;
    const start = span_start -| context;
    const end = @min(line.len, @max(span_end + context, start + max_excerpt_bytes));
    return .{
        .text = line[start..end],
        .caret_col = span_start - start + 1,
        .cut_left = start > 0,
        .cut_right = end < line.len,
    };
}

test "a long line is windowed around the span instead of dumped whole" {
    // One diagnostic used to put the whole line on stderr — 1.49 MB for
    // `tests/corpus/parse/bad/OneMegabyteLine.beni` — plus `col - 1`
    // spaces of caret padding under it.
    const gpa = std.testing.allocator;
    const line = try gpa.alloc(u8, 100_000);
    defer gpa.free(line);
    @memset(line, 'x');
    line[50_000] = '@';
    const source = try std.fmt.allocPrint(gpa, "{s}\n", .{line});
    defer gpa.free(source);

    const d = diagnostic.Diagnostic{
        .code = .invalid_character,
        .severity = .@"error",
        .span = .{ .file = "Big.beni", .start = .{ .line = 1, .col = 50_001 }, .end = .{ .line = 1, .col = 50_002 } },
        .title = diagnostic.title(.invalid_character),
        .message = "I found a character that cannot appear here.",
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderOne(&out.writer, d, source);

    // The excerpt is bounded, cut on both sides, and the caret is under
    // the offending byte.
    try std.testing.expect(out.written().len < 512);
    const excerpt_start = std.mem.indexOf(u8, out.written(), "\n1|").? + 3;
    const excerpt_end = std.mem.indexOfScalarPos(u8, out.written(), excerpt_start, '\n').?;
    const excerpt = out.written()[excerpt_start..excerpt_end];
    try std.testing.expect(std.mem.startsWith(u8, excerpt, ellipsis));
    try std.testing.expect(std.mem.endsWith(u8, excerpt, ellipsis));
    const caret_line = out.written()[excerpt_end + 1 ..];
    const caret = std.mem.indexOfScalar(u8, caret_line, '^').?;
    try std.testing.expectEqual(@as(u8, '@'), out.written()[excerpt_start + caret - 2]);
}

test "excerpts for many diagnostics in one file are found by resuming, not rescanning" {
    // `lineAt` used to count newlines from byte 0 for every diagnostic,
    // which made text rendering quadratic: 16 000 errors in a 400 KB file
    // took 38 seconds against 0.43 for the same run as JSON. The cursor
    // relies on `diagnostic.sort` having put them in file-then-line order.
    const gpa = std.testing.allocator;
    const lines = 2000;
    var source: std.Io.Writer.Allocating = .init(gpa);
    defer source.deinit();
    for (0..lines) |i| try source.writer.print("x{d} = @\n", .{i});

    var diagnostics: std.ArrayList(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(gpa);
    for (0..lines) |i| try diagnostics.append(gpa, .{
        .code = .invalid_character,
        .severity = .@"error",
        .span = .{ .file = "M.beni", .start = .{ .line = @intCast(i + 1), .col = 1 }, .end = .{ .line = @intCast(i + 1), .col = 2 } },
        .title = diagnostic.title(.invalid_character),
        .message = "bad",
    });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const text: []const u8 = source.written();
    try render(&out.writer, diagnostics.items, .{ .context = @ptrCast(&text), .lookup = lookupOnly });

    // Every excerpt is the right line: a cursor that resumed from the
    // wrong place would print a neighbour's text, not fail to print.
    var found: usize = 0;
    var needle: [32]u8 = undefined;
    for (0..lines) |i| {
        const want = try std.fmt.bufPrint(&needle, "\n{d}|x{d} = @\n", .{ i + 1, i });
        if (std.mem.indexOf(u8, out.written(), want) != null) found += 1;
    }
    try std.testing.expectEqual(lines, found);
}

fn lookupOnly(context: *const anyopaque, _: []const u8) ?[]const u8 {
    const text: *const []const u8 = @ptrCast(@alignCast(context));
    return text.*;
}

test "lineAt resumes within a file and restarts for another" {
    const text = "one\ntwo\nthree\nfour\n";
    var cursor: Cursor = .{};
    try std.testing.expectEqualStrings("two", lineAt(text, "A", 2, &cursor).?);
    try std.testing.expectEqual(@as(u32, 2), cursor.line);
    try std.testing.expectEqualStrings("four", lineAt(text, "A", 4, &cursor).?);
    // Backwards in the same file, and a different file, both restart.
    try std.testing.expectEqualStrings("one", lineAt(text, "A", 1, &cursor).?);
    try std.testing.expectEqualStrings("three", lineAt(text, "B", 3, &cursor).?);
    // Out of range answers null and leaves the cursor usable.
    try std.testing.expectEqual(@as(?[]const u8, null), lineAt(text, "B", 99, &cursor));
    try std.testing.expectEqualStrings("one", lineAt(text, "B", 1, &cursor).?);
    try std.testing.expectEqual(@as(?[]const u8, null), lineAt(text, "B", 0, &cursor));
}

test "renderOne lays out header, message and excerpt like Elm" {
    const d = diagnostic.Diagnostic{
        .code = .tab_in_source,
        .severity = .@"error",
        .span = .{ .file = "src/Main.beni", .start = .{ .line = 3, .col = 5 }, .end = .{ .line = 3, .col = 6 } },
        .title = diagnostic.title(.tab_in_source),
        .message = "I found a tab character. Beni does not allow tabs anywhere in a file.\n\nUse spaces for indentation. Inside a string, write \\t.",
    };
    const source = "view : Int\nview =\n    \tview = 1\nend\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderOne(&out.writer, d, source);
    try std.testing.expectEqualStrings(
        "-- TAB CHARACTER --------------------------------------------- src/Main.beni:3:5\n" ++
            "\n" ++
            "I found a tab character. Beni does not allow tabs anywhere in a file.\n" ++
            "\n" ++
            "Use spaces for indentation. Inside a string, write \\t.\n" ++
            "\n" ++
            "3|    \tview = 1\n" ++
            "      ^\n",
        out.written(),
    );
}

test "renderOne without a source skips the excerpt; multi-line spans get one caret" {
    const d = diagnostic.Diagnostic{
        .code = .unclosed_delimiter,
        .severity = .@"error",
        .span = .{ .file = "A.beni", .start = .{ .line = 1, .col = 3 }, .end = .{ .line = 2, .col = 1 } },
        .title = diagnostic.title(.unclosed_delimiter),
        .message = "msg",
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderOne(&out.writer, d, null);
    try std.testing.expectEqualStrings(
        "-- UNCLOSED DELIMITER ----------------------------------------------- A.beni:1:3\n\nmsg\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try renderOne(&out.writer, d, "x (y\n");
    try std.testing.expectEqualStrings(
        "-- UNCLOSED DELIMITER ----------------------------------------------- A.beni:1:3\n\nmsg\n\n1|x (y\n    ^\n",
        out.written(),
    );
}

test "render separates diagnostics with a blank line and writes nothing for none" {
    const Ctx = struct {
        fn lookup(_: *const anyopaque, file: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, file, "A.beni")) "a\n" else null;
        }
    };
    const sources: Sources = .{ .context = undefined, .lookup = Ctx.lookup };
    const diags = [_]diagnostic.Diagnostic{
        .{ .code = .internal, .severity = .@"error", .span = .{ .file = "A.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 2 } }, .title = "INTERNAL ERROR", .message = "one" },
        .{ .code = .internal, .severity = .@"error", .span = .{ .file = "B.beni", .start = .{ .line = 9, .col = 1 }, .end = .{ .line = 9, .col = 1 } }, .title = "INTERNAL ERROR", .message = "two" },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&out.writer, &diags, sources);
    try std.testing.expectEqualStrings(
        "-- INTERNAL ERROR --------------------------------------------------- A.beni:1:1\n\none\n\n1|a\n  ^\n" ++
            "\n" ++
            "-- INTERNAL ERROR --------------------------------------------------- B.beni:9:1\n\ntwo\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try render(&out.writer, &.{}, .none);
    try std.testing.expectEqualStrings("", out.written());
}
