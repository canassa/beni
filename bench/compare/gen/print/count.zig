//! The shared token and line counter (docs/design/compare-bench.md §5.3).
//! A token is a string literal, a word, a number, a run of operator
//! characters, or one bracket or comma. The printers emit no comments, so
//! none are skipped. Lines are the non-blank lines.

const std = @import("std");

pub const Counts = struct { tokens: u64 = 0, lines: u64 = 0 };

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isOp(c: u8) bool {
    return std.mem.indexOfScalar(u8, "!#$%&*+./<=>?@\\^|~:-", c) != null;
}

pub fn count(text: []const u8) Counts {
    var c: Counts = .{};
    var i: usize = 0;
    var line_has = false;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '\n') {
            if (line_has) c.lines += 1;
            line_has = false;
            i += 1;
            continue;
        }
        if (ch == ' ' or ch == '\t' or ch == '\r') {
            i += 1;
            continue;
        }
        line_has = true;
        c.tokens += 1;
        if (ch == '"') {
            i += 1;
            while (i < text.len and text[i] != '"') i += if (text[i] == '\\') 2 else 1;
            i += 1;
        } else if (isWord(ch)) {
            while (i < text.len and isWord(text[i])) i += 1;
        } else if (isOp(ch)) {
            while (i < text.len and isOp(text[i])) i += 1;
        } else {
            // One character, however many bytes: `λ` is one token.
            i += 1;
            while (i < text.len and text[i] & 0xC0 == 0x80) i += 1;
        }
    }
    if (line_has) c.lines += 1;
    return c;
}

test "tokens" {
    const c = count("f x =\n    x + \"a b\" ++ [ 1, 2 ]\n\n");
    try std.testing.expectEqual(@as(u64, 12), c.tokens);
    try std.testing.expectEqual(@as(u64, 2), c.lines);
}
