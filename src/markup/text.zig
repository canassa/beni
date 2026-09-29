//! A markup text run as the page shows it (docs/design/language.md §11.4):
//! whitespace collapsed first, then character references decoded, in that
//! order, exactly as Solid 2's compiler reads JSX text
//! (`references/dom-expressions/packages/compiler/src/shared/utils.rs`,
//! `trim_jsx_text` then `decode_html_entities`).
//!
//! *Whitespace* is every character with the Unicode `White_Space` property —
//! Rust's `char::is_whitespace`, which Solid's port of Babel's rule uses —
//! and only `\n` splits lines. Like that port, a `\r` is dropped before
//! anything else, so a file with CRLF line ends reads as one with LF.

const std = @import("std");
const Allocator = std.mem.Allocator;
const entities = @import("entities.zig");

/// Append the text `raw` shows to `out`: collapsed, then decoded. Appends
/// nothing when the run collapses to nothing, which is a run that
/// contributes no child.
pub fn read(gpa: Allocator, scratch: Allocator, out: *std.ArrayList(u8), raw: []const u8) Allocator.Error!void {
    var collapsed: std.ArrayList(u8) = .empty;
    defer collapsed.deinit(scratch);
    try collapse(scratch, &collapsed, raw);
    try entities.decode(gpa, out, collapsed.items);
}

/// §11.4's first step, `trim_jsx_text`: drop every `\r`; when the run holds
/// a `\n`, split it into lines, strip the leading whitespace of every line
/// but the first, drop each line that is then empty or all whitespace, and
/// join what is left with one space; then replace every run of whitespace
/// with one space.
pub fn collapse(gpa: Allocator, out: *std.ArrayList(u8), raw: []const u8) Allocator.Error!void {
    const multiline = std.mem.indexOfScalar(u8, raw, '\n') != null;
    var in_whitespace = false;
    var wrote_line = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var index: usize = 0;
    while (lines.next()) |line_raw| : (index += 1) {
        var line = line_raw;
        if (multiline) {
            if (index > 0) line = line[leadingWhitespace(line)..];
            if (allWhitespace(line)) continue;
            // The joining space, which the collapse below merges with any
            // whitespace on either side of it.
            if (wrote_line) {
                if (!in_whitespace) try out.append(gpa, ' ');
                in_whitespace = true;
            }
            wrote_line = true;
        }
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == '\r') {
                i += 1;
                continue;
            }
            const n = whitespaceAt(line, i);
            if (n > 0) {
                if (!in_whitespace) try out.append(gpa, ' ');
                in_whitespace = true;
                i += n;
                continue;
            }
            const len = charLen(line, i);
            try out.appendSlice(gpa, line[i..][0..len]);
            in_whitespace = false;
            i += len;
        }
    }
}

/// Bytes of leading whitespace (`\r` included) in `line`.
fn leadingWhitespace(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\r') {
            i += 1;
            continue;
        }
        const n = whitespaceAt(line, i);
        if (n == 0) break;
        i += n;
    }
    return i;
}

fn allWhitespace(line: []const u8) bool {
    return leadingWhitespace(line) == line.len;
}

/// The length of the whitespace character at `text[i]`, or 0 when the
/// character there is not whitespace (`White_Space`, Unicode 16).
pub fn whitespaceAt(text: []const u8, i: usize) usize {
    const c = text[i];
    if (c < 0x80) return switch (c) {
        '\t', '\n', 0x0B, 0x0C, '\r', ' ' => 1,
        else => 0,
    };
    const len = std.unicode.utf8ByteSequenceLength(c) catch return 0;
    if (i + len > text.len) return 0;
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return 0;
    return switch (cp) {
        0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => len,
        else => 0,
    };
}

/// The length of the character at `text[i]`: a whole UTF-8 sequence, or
/// one byte of a malformed one (which the lexer has reported).
fn charLen(text: []const u8, i: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return 1;
    if (i + len > text.len) return 1;
    _ = std.unicode.utf8Decode(text[i..][0..len]) catch return 1;
    return len;
}

// ---------------------------------------------------------------------------
// Tests: Babel's `cleanJSXElementLiteralChild` cases as Solid's port reads
// them, and §11.4's own examples.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectRead(raw: []const u8, expected: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try read(testing.allocator, testing.allocator, &out, raw);
    try testing.expectEqualStrings(expected, out.items);
}

test "a run with no newline keeps its edges and collapses inside" {
    try expectRead(" ", " ");
    try expectRead("Hello, ", "Hello, ");
    try expectRead("  two  spaces  ", " two spaces ");
    try expectRead("a\tb", "a b");
}

test "a run with newlines drops blank lines and indentation and joins with one space" {
    try expectRead("\n    ", "");
    try expectRead("\n    done\n", "done");
    try expectRead("\n        Hello\n        world\n    ", "Hello world");
    try expectRead("first  \n   second", "first second");
    try expectRead("  lead\n", " lead");
    try expectRead("\n\n  a\n\n  b  \n", "a b ");
}

test "a CR is dropped before the lines are read" {
    try expectRead("a\r\n", "a");
    try expectRead("a\r\n  b\r\n", "a b");
}

test "whitespace is Unicode's, and a typed no-break space collapses while &nbsp; survives" {
    try expectRead("a\u{00A0}\u{00A0}b", "a b");
    try expectRead("a\u{3000}b\u{2028}c", "a b c");
    try expectRead("\n  \u{00A0}  \n", "");
    try expectRead("a&nbsp;&nbsp;b", "a\u{00A0}\u{00A0}b");
    try expectRead("a &nbsp; b", "a \u{00A0} b");
}

test "decoding follows collapsing, so a decoded space is never collapsed" {
    try expectRead("Fish &amp; chips", "Fish & chips");
    try expectRead("a&#32;&#32;b", "a  b");
    try expectRead("a\xffb", "a\xffb");
}
