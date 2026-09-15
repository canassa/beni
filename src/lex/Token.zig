//! Token and comment records (docs/design/frontend.md §3.2, language.md §2.2).
//!
//! The lexer (M1a, `Tokenizer.zig`) fills a `TokenList`; this file only fixes
//! the shapes. A token is thirteen bytes in four SoA columns: the tag, the
//! byte offset of its first byte, its 0-based line (so the parser can decide
//! layout per token without a binary search — language.md §4) and a payload
//! that carries the interned `Symbol` for identifier-like tokens. There is no
//! length: it is re-derived from `tag` + `start` (fixed-text tags through
//! `lexeme`, everything else by re-running the scanner from `start`).
//!
//! Comments are not tokens (language.md §2.3). They live in a parallel array
//! keyed by the significant token they precede, which is how the formatter
//! re-attaches them.

const std = @import("std");

pub const Token = struct {
    tag: Tag,
    /// Byte offset of the token's first byte.
    start: u32,
    /// 0-based line index; column is `start - line_starts[line] + 1`.
    line: u32,
    /// `@intFromEnum(Symbol)` for the identifier-like tags (`isInterned`:
    /// lower, upper, qualified, and dot_lower, whose field name is interned
    /// without the dot); the index value for `dot_index` (saturated at
    /// `maxInt(u32)`); 0 otherwise. Kept as `u32` rather than `Symbol` so
    /// the record has no dependency on the interner.
    payload: u32,
};

/// Struct-of-arrays token storage (fast-compiler.md §5).
pub const TokenList = std.MultiArrayList(Token);

/// Index into a `TokenList`.
pub const Index = enum(u32) {
    _,

    pub fn toOptional(i: Index) OptionalIndex {
        return @enumFromInt(@intFromEnum(i));
    }
};

pub const OptionalIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(i: OptionalIndex) ?Index {
        return if (i == .none) null else @enumFromInt(@intFromEnum(i));
    }
};

pub const Comment = struct {
    kind: Kind,
    /// Byte offset of the first `-`. Length is to end of line.
    start: u32,
    /// Index of the significant token this comment precedes. The final
    /// `eof` token counts, so a trailing comment precedes `eof`.
    before_token: u32,

    pub const Kind = enum(u8) {
        /// `-- text`
        plain,
        /// `--| text`, documents the following declaration
        doc,
        /// `--! text`, module documentation at the top of the file
        module_doc,
    };
};

/// Every token kind in language.md §2.2, plus `invalid` for bytes the lexer
/// reports and skips (the parser sees them as an error placeholder).
pub const Tag = enum(u8) {
    lower_ident,
    upper_ident,
    qualified_lower,
    qualified_upper,
    dot_lower,
    dot_index,
    int,
    float,
    str_start,
    str_chunk,
    interp_start,
    interp_end,
    str_end,
    multiline_line,
    char,

    keyword_if,
    keyword_then,
    keyword_else,
    keyword_case,
    keyword_of,
    keyword_let,
    keyword_in,
    keyword_type,
    keyword_alias,
    keyword_pub,
    keyword_opaque,
    keyword_import,
    keyword_as,
    keyword_exposing,
    keyword_foreign,

    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    comma,
    colon,
    equal,
    arrow,
    /// `<-`, the rest-of-block bind of a `let` (language.md §6.7). A symbol,
    /// not an operator: it may appear only between a `let` binding's pattern
    /// and its right-hand side.
    arrow_left,
    backslash,
    pipe,
    underscore,
    question,

    op_plus,
    op_minus,
    op_star,
    op_slash,
    op_slash_slash,
    op_caret,
    op_plus_plus,
    op_colon_colon,
    op_eq_eq,
    op_slash_eq,
    op_lt,
    op_gt,
    op_lte,
    op_gte,
    op_and_and,
    op_or_or,
    op_pipe_right,
    op_pipe_left,

    eof,
    invalid,

    /// True for the identifier-like tags whose `payload` is a `Symbol`
    /// (`dot_index` is not one: its payload is the index itself).
    pub fn isInterned(tag: Tag) bool {
        return switch (tag) {
            .lower_ident, .upper_ident, .qualified_lower, .qualified_upper, .dot_lower => true,
            else => false,
        };
    }

    /// True for `keyword_*`.
    pub fn isKeyword(tag: Tag) bool {
        return @intFromEnum(tag) >= @intFromEnum(Tag.keyword_if) and
            @intFromEnum(tag) <= @intFromEnum(Tag.keyword_foreign);
    }

    /// True for the binary operators of language.md §6.5 (`op_*`).
    pub fn isOperator(tag: Tag) bool {
        return @intFromEnum(tag) >= @intFromEnum(Tag.op_plus) and
            @intFromEnum(tag) <= @intFromEnum(Tag.op_pipe_left);
    }
};

/// The source text of a tag whose spelling is fixed — keywords, symbols and
/// operators — or null for tags whose text is only known from the source
/// (identifiers, literals, `eof`, `invalid`). The lexer derives token length
/// from this; the formatter prints from it.
pub fn lexeme(tag: Tag) ?[]const u8 {
    return switch (tag) {
        .keyword_if => "if",
        .keyword_then => "then",
        .keyword_else => "else",
        .keyword_case => "case",
        .keyword_of => "of",
        .keyword_let => "let",
        .keyword_in => "in",
        .keyword_type => "type",
        .keyword_alias => "alias",
        .keyword_pub => "pub",
        .keyword_opaque => "opaque",
        .keyword_import => "import",
        .keyword_as => "as",
        .keyword_exposing => "exposing",
        .keyword_foreign => "foreign",

        .l_paren => "(",
        .r_paren => ")",
        .l_bracket => "[",
        .r_bracket => "]",
        .l_brace => "{",
        .r_brace => "}",
        .comma => ",",
        .colon => ":",
        .equal => "=",
        .arrow => "->",
        .arrow_left => "<-",
        .backslash => "\\",
        .pipe => "|",
        .underscore => "_",
        .question => "?",

        .op_plus => "+",
        .op_minus => "-",
        .op_star => "*",
        .op_slash => "/",
        .op_slash_slash => "//",
        .op_caret => "^",
        .op_plus_plus => "++",
        .op_colon_colon => "::",
        .op_eq_eq => "==",
        .op_slash_eq => "/=",
        .op_lt => "<",
        .op_gt => ">",
        .op_lte => "<=",
        .op_gte => ">=",
        .op_and_and => "&&",
        .op_or_or => "||",
        .op_pipe_right => "|>",
        .op_pipe_left => "<|",

        .lower_ident,
        .upper_ident,
        .qualified_lower,
        .qualified_upper,
        .dot_lower,
        .dot_index,
        .int,
        .float,
        .str_start,
        .str_chunk,
        .interp_start,
        .interp_end,
        .str_end,
        .multiline_line,
        .char,
        .eof,
        .invalid,
        => null,
    };
}

/// Keyword spelling → tag (language.md §2.4). Built at comptime; the lexer
/// consults it once per lower identifier.
pub const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "if", .keyword_if },
    .{ "then", .keyword_then },
    .{ "else", .keyword_else },
    .{ "case", .keyword_case },
    .{ "of", .keyword_of },
    .{ "let", .keyword_let },
    .{ "in", .keyword_in },
    .{ "type", .keyword_type },
    .{ "alias", .keyword_alias },
    .{ "pub", .keyword_pub },
    .{ "opaque", .keyword_opaque },
    .{ "import", .keyword_import },
    .{ "as", .keyword_as },
    .{ "exposing", .keyword_exposing },
    .{ "foreign", .keyword_foreign },
});

// The token record is the size the design budgets for (frontend.md §3.2).
comptime {
    std.debug.assert(@sizeOf(Tag) == 1);
    std.debug.assert(@sizeOf(Token) == 16); // 13 bytes of payload, padded when AoS; SoA stores 13
}

test "keyword table and lexeme agree for every keyword" {
    inline for (@typeInfo(Tag).@"enum".fields) |field| {
        const tag: Tag = @enumFromInt(field.value);
        if (tag.isKeyword()) {
            const text = lexeme(tag).?;
            try std.testing.expectEqual(tag, keywords.get(text).?);
        }
    }
    try std.testing.expectEqual(@as(usize, 15), keywords.kvs.len);
    try std.testing.expectEqual(@as(?Tag, null), keywords.get("main"));
}

test "every operator and symbol has a lexeme; no variable-text tag does" {
    inline for (@typeInfo(Tag).@"enum".fields) |field| {
        const tag: Tag = @enumFromInt(field.value);
        const fixed = tag.isKeyword() or tag.isOperator() or
            (@intFromEnum(tag) >= @intFromEnum(Tag.l_paren) and @intFromEnum(tag) <= @intFromEnum(Tag.question));
        try std.testing.expectEqual(fixed, lexeme(tag) != null);
    }
}

test "optional index round trip" {
    const i: Index = @enumFromInt(7);
    try std.testing.expectEqual(i, i.toOptional().unwrap().?);
    try std.testing.expectEqual(@as(?Index, null), OptionalIndex.none.unwrap());
}

test "TokenList is a struct of arrays" {
    var list: TokenList = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, .{ .tag = .lower_ident, .start = 0, .line = 0, .payload = 3 });
    try list.append(std.testing.allocator, .{ .tag = .eof, .start = 4, .line = 0, .payload = 0 });
    try std.testing.expectEqualSlices(Tag, &.{ .lower_ident, .eof }, list.items(.tag));
    try std.testing.expectEqualSlices(u32, &.{ 0, 4 }, list.items(.start));
}
