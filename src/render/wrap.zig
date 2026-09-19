//! The 80-column rule for a diagnostic's prose (`checker.md` §8.4).
//!
//! Every message in the compiler is a `std.fmt` format string wrapped BY
//! HAND in the source, with `{s}` holes in it. A hole is filled after the
//! wrapping, so the width of what goes into it is not the width the author
//! measured: `main_not_program`'s second paragraph was written to fit and
//! then spliced a type name into its first line, which came out at 85
//! columns. Nothing about that is specific to that message — any
//! interpolated name, path, module or type can do it — so the fix is here
//! and not in the prose.
//!
//! **Re-wrap after interpolation, and only what overran.** A paragraph is
//! left exactly as its author wrote it unless one of its lines is wider
//! than `columns`; then the whole paragraph is re-filled greedily, which is
//! what makes the result read like a paragraph rather than like one long
//! line with a stub under it. Already-conforming text is untouched, so this
//! is idempotent and a golden moves only when the rule was broken.
//!
//! **A backticked span is never broken.** `` `import x from "node:x";` ``
//! is one unit however many spaces are inside it, because a line break in
//! the middle of code the reader is meant to copy is worse than an overrun.
//! A span wider than `columns` therefore still overruns — that is the one
//! honest exception, and it is bounded by what the author wrote in ticks.
//!
//! **A paragraph with structure is left alone.** An indented block is a
//! code sample and its line breaks are the sample's (`    main : Program`);
//! a line starting with `-`, `|`, `#`, `>` or a digit is a list, a table or
//! a quotation. Those keep their own shape, which is also why the three
//! `check/depth/` goldens — a 625-column record rendered by `Render.zig`
//! into an indented block — are not touched by this and must not be:
//! `checker.md` §8.2's truncation, not this file's wrap, is what bounds a
//! type's width.
//!
//! **Columns are code points, not bytes.** The messages are full of `§`,
//! `—` and `…`; all three are one column wide and two or three bytes long,
//! and the hand-wrapped prose this rule has to agree with was measured by
//! eye.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Elm's width, and the width `render/text.zig` pads its header rule to.
pub const columns: usize = 80;

/// `message` with every over-wide paragraph re-filled, owned by `gpa`.
/// Always a fresh allocation, even when nothing moved, so the caller has
/// one ownership rule.
pub fn reflow(gpa: Allocator, message: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // An `Allocating` writer fails only when the allocation does.
    write(&out.writer, message) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(w: *std.Io.Writer, message: []const u8) std.Io.Writer.Error!void {
    // The message is lines joined by `\n`, and so is the answer: `separate`
    // says whether the next output line needs one in front of it, which is
    // what keeps a trailing newline and a run of blank lines exactly as
    // they came in.
    var separate = false;
    var paragraph: ?struct { start: usize, end: usize } = null;
    var at: usize = 0;
    while (true) {
        const newline = std.mem.indexOfScalarPos(u8, message, at, '\n');
        const line_end = newline orelse message.len;
        if (line_end == at) {
            if (paragraph) |p| {
                try writeParagraph(w, message[p.start..p.end], &separate);
                paragraph = null;
            }
            if (separate) try w.writeByte('\n');
            separate = true;
        } else if (paragraph) |*p| {
            p.end = line_end;
        } else {
            paragraph = .{ .start = at, .end = line_end };
        }
        if (newline == null) break;
        at = line_end + 1;
    }
    if (paragraph) |p| try writeParagraph(w, message[p.start..p.end], &separate);
}

/// One paragraph — a run of lines with no blank one in it — re-filled if it
/// has to be, copied through if it does not. `text` carries no trailing
/// newline.
fn writeParagraph(w: *std.Io.Writer, text: []const u8, separate: *bool) std.Io.Writer.Error!void {
    if (!needsRefill(text)) {
        if (separate.*) try w.writeByte('\n');
        separate.* = true;
        return w.writeAll(text);
    }

    var used: usize = columns + 1; // Forces the first unit onto a new line.
    var it: Units = .{ .text = text };
    while (it.next()) |unit| {
        const width = countColumns(unit);
        if (used + 1 + width <= columns) {
            try w.writeByte(' ');
            used += 1;
        } else {
            if (separate.*) try w.writeByte('\n');
            separate.* = true;
            used = 0;
        }
        try w.writeAll(unit);
        used += width;
    }
}

/// Whether this paragraph is prose that overran. Both halves matter: prose
/// that fits keeps the author's line breaks, and a paragraph that is not
/// prose keeps them however wide it is.
fn needsRefill(text: []const u8) bool {
    if (text.len == 0) return false;
    var over = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (isStructural(line[0])) return false;
        if (countColumns(line) > columns) over = true;
    }
    return over;
}

/// The first byte of a line that means "this line's break is mine, not the
/// wrapper's": indentation (a code sample), a bullet, a table row, a
/// heading, a quotation, or a numbered item.
fn isStructural(c: u8) bool {
    return switch (c) {
        ' ', '\t', '-', '*', '|', '#', '>', '0'...'9' => true,
        else => false,
    };
}

/// The paragraph split into the pieces a line break may fall between: runs
/// of non-space bytes, except that a space inside a backticked span does
/// not separate two of them. Newlines in the input are separators like
/// spaces — that is what re-filling a paragraph means.
const Units = struct {
    text: []const u8,
    at: usize = 0,

    fn next(it: *Units) ?[]const u8 {
        while (it.at < it.text.len and isSpace(it.text[it.at])) it.at += 1;
        if (it.at >= it.text.len) return null;
        const start = it.at;
        var in_ticks = false;
        while (it.at < it.text.len) : (it.at += 1) {
            const c = it.text[it.at];
            if (c == '`') {
                // An opening tick only opens when it closes: an odd tick in
                // prose is a byte, not the start of a span that swallows
                // the rest of the paragraph.
                in_ticks = if (in_ticks) false else std.mem.indexOfScalarPos(u8, it.text, it.at + 1, '`') != null;
                continue;
            }
            if (isSpace(c) and !in_ticks) break;
        }
        return it.text[start..it.at];
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\n' or c == '\t';
    }
};

/// How many columns `text` occupies. Every non-ASCII character the messages
/// use — `§`, `—`, `…`, `·` — is one column and more than one byte, so this
/// counts UTF-8 sequence starts rather than bytes. A malformed byte counts
/// as one column, because this is a layout rule and not a validator.
pub fn countColumns(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectReflow(expected: []const u8, input: []const u8) !void {
    const got = try reflow(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "a paragraph that fits keeps the breaks its author wrote" {
    const message = "Short.\n\nOne line.\nAnd another that is shorter than eighty columns.\n\nDone.";
    try expectReflow(message, message);
}

test "only the paragraph that overran is re-filled" {
    // First paragraph 84 columns, second well inside: the second must come
    // out byte for byte, or every golden in the corpus would move.
    const input =
        "This one is annotated `Basics.Int`. The platform owns the type of the entry point and\nhands out the only values of it.\n\nA\nB\n";
    const want =
        "This one is annotated `Basics.Int`. The platform owns the type of the entry\npoint and hands out the only values of it.\n\nA\nB\n";
    try expectReflow(want, input);
}

test "a backticked span is one unit, spaces and all" {
    const input = "Write `import process from \"node:process\";` — or whatever module really provides it — at the top.";
    const got = try reflow(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "`import process from \"node:process\";`") != null);
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |line| try testing.expect(countColumns(line) <= columns);
}

test "an indented block and a list keep their shape however wide" {
    const wide = "    " ++ "x" ** 100;
    const input = "Write:\n\n" ++ wide ++ "\n\n- a bullet that is very long indeed and runs past the eightieth column by a mile\n";
    try expectReflow(input, input);
}

test "columns are code points: § and — are one each" {
    try testing.expectEqual(@as(usize, 1), countColumns("§"));
    try testing.expectEqual(@as(usize, 1), countColumns("—"));
    try testing.expectEqual(@as(usize, 3), countColumns("a—b"));
    // 80 columns of prose with three `§` in it is 83 bytes and must not move.
    const line = "§§§" ++ "a" ** 77;
    try testing.expectEqual(@as(usize, 80), countColumns(line));
    try expectReflow(line, line);
}

test "reflow is idempotent" {
    const input = "`platform/Prog.js` exports `whisper`, which is not a `foreign` value of this module.\n\nAnd a second paragraph that is fine.";
    const once = try reflow(testing.allocator, input);
    defer testing.allocator.free(once);
    const twice = try reflow(testing.allocator, once);
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(once, twice);
}

test "an unmatched backtick does not swallow the paragraph" {
    const input = "A line with one ` tick in it that is quite long and runs past the eightieth column here.";
    const got = try reflow(testing.allocator, input);
    defer testing.allocator.free(got);
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |line| try testing.expect(countColumns(line) <= columns);
}

test "an empty message and a trailing blank line survive" {
    try expectReflow("", "");
    try expectReflow("a\n\n", "a\n\n");
}
