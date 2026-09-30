//! Lexical diagnostics as the tokenizer records them (docs/design/frontend.md
//! §1.1, language.md §2, §10).
//!
//! The tokenizer never formats text: an item is a code, a byte range and,
//! for a markup stray byte, the mode it stood in, appended to a list. That
//! keeps the scanning loop free of allocation beyond the append, keeps the
//! record small enough to sit in a file's artifact set for a daemon to
//! re-report without re-lexing, and lets the prose be a pure function of
//! `(code, the offending bytes, where they stood)`, written once in
//! `message`. The session turns an item into a
//! `diagnostic.Diagnostic` by resolving offsets against the file's
//! line-start table (`position`) and rendering `message` into owned memory.
//!
//! Messages are in Elm's register: what I found, why it is a problem, what
//! to write instead — the excerpt with the caret is the renderer's job.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");

const Diagnostics = @This();

list: std.ArrayList(Item) = .empty,

pub const empty: Diagnostics = .{};

/// One lexical error: the code and the byte range it covers (`end`
/// exclusive; `start == end` for an unterminated string reported at the line
/// end). Messages are derived from `code` and `source[start..end]`.
pub const Item = struct {
    code: diagnostic.Code,
    start: u32,
    end: u32,
    /// Where a markup stray byte stood, for a message that fits the place:
    /// the same `}` means one thing between tags and another inside one.
    where: Where = .code,
};

/// The lexer's mode at a stray byte (frontend.md §9.1).
pub const Where = enum(u8) {
    /// Ordinary code, a string, a hole: not a markup stray.
    code,
    /// Inside an opening tag.
    tag,
    /// Inside a closing tag.
    closing_tag,
    /// In the text between tags.
    text,
};

pub fn deinit(d: *Diagnostics, gpa: Allocator) void {
    d.list.deinit(gpa);
    d.* = undefined;
}

pub fn report(d: *Diagnostics, gpa: Allocator, code: diagnostic.Code, start: u32, end: u32) Allocator.Error!void {
    return d.reportAt(gpa, code, start, end, .code);
}

/// `report`, for a markup stray byte, saying where it stood.
pub fn reportAt(d: *Diagnostics, gpa: Allocator, code: diagnostic.Code, start: u32, end: u32, where: Where) Allocator.Error!void {
    std.debug.assert(start <= end);
    try d.list.append(gpa, .{ .code = code, .start = start, .end = end, .where = where });
}

/// Every item so far, in source order.
pub fn items(d: *const Diagnostics) []const Item {
    return d.list.items;
}

/// Hand the items over as a caller-owned slice, leaving `d` empty.
pub fn toOwnedSlice(d: *Diagnostics, gpa: Allocator) Allocator.Error![]Item {
    return d.list.toOwnedSlice(gpa);
}

/// Write the Elm-style prose for `item`. `source` is the whole file; the
/// item's bytes are quoted where that helps. No trailing newline.
pub fn message(item: Item, source: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const text = source[item.start..item.end];
    switch (item.code) {
        .tab_in_source => try w.writeAll(
            \\I found a tab character. Beni does not allow tabs anywhere in a file.
            \\
            \\Use spaces for indentation. Inside a string, write \t.
        ),
        .bare_carriage_return => try w.writeAll(
            \\I found a carriage return (\r) that is not followed by a newline.
            \\
            \\Line endings must be \n or \r\n. A lone \r is neither, so convert the file's
            \\line endings to one of those.
        ),
        .invalid_character => {
            if (text.len == 0) {
                try w.writeAll("I found a byte that cannot appear here.");
            } else if (text[0] == '.') {
                try w.writeAll(
                    \\I found a `.` that does not start a field access.
                    \\
                    \\A `.` must be followed directly by a field name (`.name`) or a tuple index
                    \\(`.0`); `Module.name` is written without spaces.
                );
            } else if (text[0] < 0x20 or text[0] == 0x7f) {
                try w.print(
                    \\I found a control character (0x{X:0>2}) that cannot appear here.
                    \\
                    \\Only spaces and newlines separate tokens. Control characters are allowed
                    \\inside comments and multiline strings, and as escapes inside ordinary strings.
                , .{text[0]});
            } else if (text[0] >= 0x80) {
                try w.print(
                    \\I found the character `{s}`, which cannot be used outside a string, a
                    \\character literal or a comment.
                    \\
                    \\Identifiers are ASCII: a letter followed by letters, digits and underscores.
                , .{text});
            } else {
                try w.print(
                    \\I found `{s}`, which is not part of the language's syntax.
                    \\
                    \\The symbols are ( ) [ ] {{ }} , : = -> \ | _ ? ... and the operators are
                    \\+ - * / // ^ ++ == /= < > <= >= && || |> <|.
                , .{text});
            }
        },
        .invalid_number => try w.print(
            \\I ran into `{s}` while reading a number.
            \\
            \\A number is decimal digits (`42`), a hex literal (`0x1F`), or a float with a
            \\fraction and/or an exponent (`1.5`, `1e10`, `1.5e-3`). Letters and underscores
            \\cannot follow a number directly; put a space between the number and the name.
        , .{text}),
        .unterminated_string => {
            const where: []const u8 = if (item.end == source.len) "file" else "line";
            try w.print(
                \\I got to the end of the {s} without seeing the closing `"` of this string.
                \\
                \\Strings are single-line. For text that spans several lines, use a multiline
                \\string, one `\\` per line:
                \\
                \\    \\first line
                \\    \\second line
            , .{where});
        },
        .invalid_escape => {
            if (std.mem.startsWith(u8, text, "\\u")) {
                try w.print(
                    \\I found the escape `{s}`, which is not a valid Unicode escape.
                    \\
                    \\A Unicode escape is `\u{{…}}` with one to six hex digits inside the braces,
                    \\like `\u{{41}}` or `\u{{1F600}}`, naming a Unicode scalar value (at most
                    \\10FFFF, and not a surrogate in D800–DFFF).
                , .{text});
            } else {
                try w.print(
                    \\I found the escape `{s}`, which is not valid.
                    \\
                    \\The escapes are \n \r \t \\ \" \$ \' and \u{{…}}. To write a backslash,
                    \\use `\\`.
                , .{text});
            }
        },
        .nested_string_in_interpolation => {
            const what: []const u8 = if (std.mem.startsWith(u8, text, "\\\\")) "multiline string marker `\\\\`" else "string literal";
            try w.print(
                \\I found a {s} inside a `${{…}}` interpolation.
                \\
                \\An interpolation cannot contain another string. Bind the inner string to a
                \\name first, then interpolate the name:
                \\
                \\    let
                \\        inner = "…"
                \\    in
                \\    "${{inner}}"
            , .{what});
        },
        .invalid_char_literal => {
            if (std.mem.eql(u8, text, "''")) {
                try w.writeAll(
                    \\I found an empty character literal `''`.
                    \\
                    \\A character literal holds exactly one character: `'a'`, `'\n'`, `'\u{1F600}'`.
                );
            } else if (text.len < 2 or text[text.len - 1] != '\'') {
                try w.writeAll(
                    \\I got to the end of the line without seeing the closing `'` of this
                    \\character literal.
                    \\
                    \\A character literal holds exactly one character: `'a'`, `'\n'`, `'\u{1F600}'`.
                );
            } else {
                try w.print(
                    \\I found the character literal `{s}`, which holds more than one character.
                    \\
                    \\A character literal holds exactly one character: `'a'`, `'\n'`, `'\u{{1F600}}'`.
                    \\For text, use a string: `"…"`.
                , .{text});
            }
        },
        .invalid_utf8 => {
            try w.writeAll("I found bytes that are not valid UTF-8:");
            for (text) |b| try w.print(" 0x{X:0>2}", .{b});
            try w.writeAll(
                \\
                \\
                \\Beni source files must be encoded as UTF-8. Check the file's encoding, or look
                \\for a multi-byte character that was cut short.
            );
        },
        // Markup's stray bytes (frontend.md §9.1), each told where it stood:
        // the three that cannot stand in text say which hole writes them,
        // and a byte a tag cannot hold names the tag's parts.
        .unexpected_token => switch (item.where) {
            .tag => {
                if (std.mem.eql(u8, text, "<")) {
                    try w.writeAll(
                        \\I found a `<` inside a tag, where no tag can begin: a tag ends with `>`, or
                        \\`/>` when it has no children, before the next one starts.
                    );
                } else if (std.mem.eql(u8, text, "}")) {
                    try w.writeAll("I found a `}` inside a tag that closes no `{`.");
                } else {
                    try w.print("I found `{s}` inside a tag, where it cannot stand.", .{text});
                }
                try w.writeAll(
                    \\
                    \\
                    \\A tag holds its name and its attributes — `name`, `name="…"`, `name={…}` —
                    \\and ends with `>`, or `/>` when it has no children.
                );
            },
            .closing_tag => try w.print(
                \\I found `{s}` inside a closing tag, where it cannot stand.
                \\
                \\A closing tag holds the name of the element it closes and nothing else:
                \\`</div>`, or `</>` for a fragment.
            , .{text}),
            .text, .code => switch (if (text.len == 1) text[0] else 0) {
                '<' => try w.writeAll(
                    \\I found a `<` that does not start a tag. A tag's `<` is followed directly by
                    \\its name, by `/` in a closing tag, or by `>` in a fragment.
                    \\
                    \\In the text between tags, write the character as a hole holding a string:
                    \\`{"<"}`.
                ),
                '>' => try w.writeAll(
                    \\I found a `>` in the text between tags, where it cannot stand.
                    \\
                    \\Write the character as a hole holding a string: `{">"}`.
                ),
                '}' => try w.writeAll(
                    \\I found a `}` that closes no `{`.
                    \\
                    \\In the text between tags, write the character as a hole holding a string:
                    \\`{"}"}`.
                ),
                else => try w.print("I found `{s}` here, where it cannot stand.", .{text}),
            },
        },
        // The tokenizer produces only the codes above; anything else means a
        // caller reused this accumulator for a non-lexical code.
        else => try w.writeAll(diagnostic.title(item.code)),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectMessage(expected: []const u8, code: diagnostic.Code, source: []const u8, start: u32, end: u32) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try message(.{ .code = code, .start = start, .end = end }, source, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "message: every lexical code renders Elm-style prose from the bytes" {
    try expectMessage(
        "I found a tab character. Beni does not allow tabs anywhere in a file.\n\nUse spaces for indentation. Inside a string, write \\t.",
        .tab_in_source,
        "x =\n\t1\n",
        4,
        5,
    );
    try expectMessage(
        "I found a carriage return (\\r) that is not followed by a newline.\n\nLine endings must be \\n or \\r\\n. A lone \\r is neither, so convert the file's\nline endings to one of those.",
        .bare_carriage_return,
        "x =\r1",
        3,
        4,
    );
    try expectMessage(
        "I ran into `12abc` while reading a number.\n\nA number is decimal digits (`42`), a hex literal (`0x1F`), or a float with a\nfraction and/or an exponent (`1.5`, `1e10`, `1.5e-3`). Letters and underscores\ncannot follow a number directly; put a space between the number and the name.",
        .invalid_number,
        "x = 12abc\n",
        4,
        9,
    );
    try expectMessage(
        "I found the escape `\\q`, which is not valid.\n\nThe escapes are \\n \\r \\t \\\\ \\\" \\$ \\' and \\u{…}. To write a backslash,\nuse `\\\\`.",
        .invalid_escape,
        "\"a\\qb\"",
        2,
        4,
    );
    try expectMessage(
        "I found the escape `\\u{110000}`, which is not a valid Unicode escape.\n\nA Unicode escape is `\\u{…}` with one to six hex digits inside the braces,\nlike `\\u{41}` or `\\u{1F600}`, naming a Unicode scalar value (at most\n10FFFF, and not a surrogate in D800–DFFF).",
        .invalid_escape,
        "\"\\u{110000}\"",
        1,
        11,
    );
    try expectMessage(
        "I found bytes that are not valid UTF-8: 0xFF\n\nBeni source files must be encoded as UTF-8. Check the file's encoding, or look\nfor a multi-byte character that was cut short.",
        .invalid_utf8,
        "\"a\xffb\"",
        2,
        3,
    );
    try expectMessage(
        "I found an empty character literal `''`.\n\nA character literal holds exactly one character: `'a'`, `'\\n'`, `'\\u{1F600}'`.",
        .invalid_char_literal,
        "''",
        0,
        2,
    );
    try expectMessage(
        "I found the character literal `'ab'`, which holds more than one character.\n\nA character literal holds exactly one character: `'a'`, `'\\n'`, `'\\u{1F600}'`.\nFor text, use a string: `\"…\"`.",
        .invalid_char_literal,
        "'ab'",
        0,
        4,
    );
    try expectMessage(
        "I got to the end of the line without seeing the closing `'` of this\ncharacter literal.\n\nA character literal holds exactly one character: `'a'`, `'\\n'`, `'\\u{1F600}'`.",
        .invalid_char_literal,
        "'a\n",
        0,
        2,
    );
}

test "message: invalid_character distinguishes control bytes, non-ASCII, a stray dot and other punctuation" {
    try expectMessage(
        "I found a control character (0x01) that cannot appear here.\n\nOnly spaces and newlines separate tokens. Control characters are allowed\ninside comments and multiline strings, and as escapes inside ordinary strings.",
        .invalid_character,
        "x = \x01 1",
        4,
        5,
    );
    try expectMessage(
        "I found the character `é`, which cannot be used outside a string, a\ncharacter literal or a comment.\n\nIdentifiers are ASCII: a letter followed by letters, digits and underscores.",
        .invalid_character,
        "x = é",
        4,
        6,
    );
    try expectMessage(
        "I found a `.` that does not start a field access.\n\nA `.` must be followed directly by a field name (`.name`) or a tuple index\n(`.0`); `Module.name` is written without spaces.",
        .invalid_character,
        "x = . y",
        4,
        5,
    );
    try expectMessage(
        "I found `@`, which is not part of the language's syntax.\n\nThe symbols are ( ) [ ] { } , : = -> \\ | _ ? ... and the operators are\n+ - * / // ^ ++ == /= < > <= >= && || |> <|.",
        .invalid_character,
        "x = @",
        4,
        5,
    );
}

test "message: markup's stray bytes name the hole that writes them; a byte in a tag names the tag's parts" {
    try expectMessage(
        "I found a `<` that does not start a tag. A tag's `<` is followed directly by\nits name, by `/` in a closing tag, or by `>` in a fragment.\n\nIn the text between tags, write the character as a hole holding a string:\n`{\"<\"}`.",
        .unexpected_token,
        "<p>a < b</p>",
        5,
        6,
    );
    try expectMessage(
        "I found a `>` in the text between tags, where it cannot stand.\n\nWrite the character as a hole holding a string: `{\">\"}`.",
        .unexpected_token,
        "<p>a > b</p>",
        5,
        6,
    );
    try expectMessage(
        "I found a `}` that closes no `{`.\n\nIn the text between tags, write the character as a hole holding a string:\n`{\"}\"}`.",
        .unexpected_token,
        "<p>a } b</p>",
        5,
        6,
    );
    try expectMessageAt(
        "I found `12` inside a tag, where it cannot stand.\n\nA tag holds its name and its attributes — `name`, `name=\"…\"`, `name={…}` —\nand ends with `>`, or `/>` when it has no children.",
        "<p 12>",
        3,
        5,
        .tag,
    );
}

test "message: a `<` or `}` inside a tag, and a byte in a closing tag, say where they stood" {
    try expectMessageAt(
        "I found a `<` inside a tag, where no tag can begin: a tag ends with `>`, or\n`/>` when it has no children, before the next one starts.\n\nA tag holds its name and its attributes — `name`, `name=\"…\"`, `name={…}` —\nand ends with `>`, or `/>` when it has no children.",
        "<div <b>",
        5,
        6,
        .tag,
    );
    try expectMessageAt(
        "I found a `}` inside a tag that closes no `{`.\n\nA tag holds its name and its attributes — `name`, `name=\"…\"`, `name={…}` —\nand ends with `>`, or `/>` when it has no children.",
        "<div }>",
        5,
        6,
        .tag,
    );
    try expectMessageAt(
        "I found `.` inside a closing tag, where it cannot stand.\n\nA closing tag holds the name of the element it closes and nothing else:\n`</div>`, or `</>` for a fragment.",
        "<p>x</p .>",
        8,
        9,
        .closing_tag,
    );
}

fn expectMessageAt(expected: []const u8, source: []const u8, start: u32, end: u32, where: Where) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try message(.{ .code = .unexpected_token, .start = start, .end = end, .where = where }, source, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "message: strings and interpolation" {
    try expectMessage(
        "I got to the end of the line without seeing the closing `\"` of this string.\n\nStrings are single-line. For text that spans several lines, use a multiline\nstring, one `\\\\` per line:\n\n    \\\\first line\n    \\\\second line",
        .unterminated_string,
        "x = \"abc\ny = 1\n",
        4,
        8,
    );
    try expectMessage(
        "I got to the end of the file without seeing the closing `\"` of this string.\n\nStrings are single-line. For text that spans several lines, use a multiline\nstring, one `\\\\` per line:\n\n    \\\\first line\n    \\\\second line",
        .unterminated_string,
        "x = \"abc",
        4,
        8,
    );
    try expectMessage(
        "I found a string literal inside a `${…}` interpolation.\n\nAn interpolation cannot contain another string. Bind the inner string to a\nname first, then interpolate the name:\n\n    let\n        inner = \"…\"\n    in\n    \"${inner}\"",
        .nested_string_in_interpolation,
        "\"${ f \"a\" }\"",
        6,
        9,
    );
    try expectMessage(
        "I found a multiline string marker `\\\\` inside a `${…}` interpolation.\n\nAn interpolation cannot contain another string. Bind the inner string to a\nname first, then interpolate the name:\n\n    let\n        inner = \"…\"\n    in\n    \"${inner}\"",
        .nested_string_in_interpolation,
        "\"${ \\\\raw }\"",
        4,
        6,
    );
}
