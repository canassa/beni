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

/// Render every diagnostic, one blank line between them. Writes nothing for
/// an empty slice.
pub fn render(writer: *std.Io.Writer, diagnostics: []const diagnostic.Diagnostic, sources: Sources) std.Io.Writer.Error!void {
    for (diagnostics, 0..) |d, i| {
        if (i != 0) try writer.writeByte('\n');
        try renderOne(writer, d, sources.lookup(sources.context, d.span.file));
    }
}

/// Render one diagnostic. `source` is the file's full text, if available.
pub fn renderOne(writer: *std.Io.Writer, d: diagnostic.Diagnostic, source: ?[]const u8) std.Io.Writer.Error!void {
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
        if (lineAt(text, d.span.start.line)) |line| {
            try writer.writeByte('\n');
            try renderExcerpt(writer, d.span, line);
        }
    }
}

/// The bytes of 1-based `line_number` without its terminator, or null when
/// the file has fewer lines. `\r` before the newline is stripped so a CRLF
/// file does not leave a stray byte in the excerpt.
fn lineAt(text: []const u8, line_number: u32) ?[]const u8 {
    if (line_number == 0) return null;
    var current: u32 = 1;
    var start: usize = 0;
    while (current < line_number) : (current += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null;
        start = nl + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return std.mem.trimEnd(u8, text[start..end], "\r");
}

/// `3|     view = 1` and, under it, a caret run covering the span on its
/// first line. A span that ends on a later line, or an empty one, gets a
/// single caret.
fn renderExcerpt(writer: *std.Io.Writer, span: diagnostic.Span, line: []const u8) std.Io.Writer.Error!void {
    var number_buf: [16]u8 = undefined;
    const number = std.fmt.bufPrint(&number_buf, "{d}", .{span.start.line}) catch unreachable;
    try writer.writeAll(number);
    try writer.writeByte('|');
    try writer.writeAll(line);
    try writer.writeByte('\n');

    const col: usize = @max(span.start.col, 1);
    const width: usize = if (span.end.line == span.start.line and span.end.col > span.start.col)
        span.end.col - span.start.col
    else
        1;
    try writer.splatByteAll(' ', number.len + 1 + (col - 1));
    try writer.splatByteAll('^', width);
    try writer.writeByte('\n');
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
