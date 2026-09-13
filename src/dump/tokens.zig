//! `beni dump --stage=tokens` (docs/design/frontend.md §1.2): the token
//! stream as text, so the lexer has an OUTPUT the black-box suite can assert
//! without importing it.
//!
//! ```
//! 1:1 lower_ident main
//! 1:6 equal =
//! 2:1 eof
//! -- comments
//! 1:10 plain -- hi
//! ```
//!
//! One token per line as `<line>:<col> <tag> <text>`, 1-based, the column in
//! bytes; the text is what `Tokenizer.slice` recovers, so a zero-length
//! token (`eof`, the unterminated-string marker) has no trailing text. Then
//! the `-- comments` heading and every comment as `<line>:<col> <kind>
//! <text>`, the text running to the end of its line (`\r` excluded).
//! Positions are always printed here — unlike the AST and BIR dumps they are
//! what this stage is about — so `--positions` changes nothing.

const std = @import("std");
const diagnostic = @import("diagnostic");
const Token = @import("../lex/Token.zig");
const Tokenizer = @import("../lex/Tokenizer.zig");

pub fn write(
    w: *std.Io.Writer,
    source: [:0]const u8,
    tokens: *const Token.TokenList,
    comments: []const Token.Comment,
    line_starts: []const u32,
) std.Io.Writer.Error!void {
    const s = tokens.slice();
    for (s.items(.tag), s.items(.start), s.items(.line)) |tag, start, line| {
        const col = start - line_starts[line] + 1;
        const text = Tokenizer.slice(source, tag, start);
        try w.print("{d}:{d} {t}", .{ line + 1, col, tag });
        if (text.len != 0) {
            try w.writeByte(' ');
            try w.writeAll(text);
        }
        try w.writeByte('\n');
    }
    try w.writeAll("-- comments\n");
    for (comments) |comment| {
        const pos = diagnostic.position(line_starts, comment.start);
        const end = Tokenizer.tokenEnd(source, .multiline_line, comment.start); // to end of line, like a raw line
        try w.print("{d}:{d} {t} {s}\n", .{ pos.line, pos.col, comment.kind, source[comment.start..end] });
    }
}

test "write prints every token with its position and the comments after a heading" {
    const source: [:0]const u8 = "--! doc\nmain = \"a${x}\" -- hi\n";
    var interner: @import("../InternPool.zig").Local = .empty;
    defer interner.deinit(std.testing.allocator);
    var out: Tokenizer.Output = .empty;
    defer out.deinit(std.testing.allocator);
    try Tokenizer.tokenize(std.testing.allocator, source, &interner, &out);

    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try write(&text.writer, source, &out.tokens, out.comments.items, out.line_starts.items);
    try std.testing.expectEqualStrings(
        \\2:1 lower_ident main
        \\2:6 equal =
        \\2:8 str_start "
        \\2:9 str_chunk a
        \\2:10 interp_start ${
        \\2:12 lower_ident x
        \\2:13 interp_end }
        \\2:14 str_end "
        \\3:1 eof
        \\-- comments
        \\1:1 module_doc --! doc
        \\2:16 plain -- hi
        \\
    , text.written());
}
