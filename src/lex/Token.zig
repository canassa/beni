//! Token and comment records (docs/design/frontend.md §3.2, language.md §2.2).
//!
//! The lexer (`Tokenizer.zig`) fills a `TokenList`; this file only fixes
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
    /// 0-based line index. The column is the code points from the line's
    /// start (`diagnostic.column`, language.md §12.7).
    line: u32,
    /// `@intFromEnum(Symbol)` for the identifier-like tags (`isInterned`:
    /// lower, upper, qualified, dot_lower, whose field name is interned
    /// without the dot, and the markup tag and attribute names); the index value for `dot_index` (saturated at
    /// `maxInt(u32)`); 0 otherwise. Kept as `u32` rather than `Symbol` so
    /// the record has no dependency on the interner.
    payload: u32,
};

/// Struct-of-arrays token storage (fast-compiler.md §5).
pub const TokenList = std.MultiArrayList(Token);

/// The two token columns that outlive `lower` (frontend.md §3.2): every
/// reader after the front end turns a token index back into bytes through
/// `tag` and `start` alone, and they are all the front-end cache carries.
pub const Span = struct {
    tag: Tag,
    start: u32,
};

/// A file's tokens as a cache hit installs them: five bytes a token, with no
/// `line` or `payload` column to fill.
pub const SpanList = std.MultiArrayList(Span);

/// A read-only view of `tag` and `start`, over whichever list holds them.
pub const Spans = struct {
    tags: []const Tag,
    starts: []const u32,

    pub const empty: Spans = .{ .tags = &.{}, .starts = &.{} };

    pub fn ofTokens(list: *const TokenList) Spans {
        return .{ .tags = list.items(.tag), .starts = list.items(.start) };
    }

    pub fn ofSpans(list: *const SpanList) Spans {
        return .{ .tags = list.items(.tag), .starts = list.items(.start) };
    }

    pub fn len(s: Spans) usize {
        return s.tags.len;
    }
};

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
/// reports and skips (the parser sees them as an error placeholder), plus
/// the nine markup kinds of frontend.md §9.2.
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
    /// `→` (U+2192), the arrow of a function type, a `case` branch and a
    /// lambda (language.md §12.7).
    arrow,
    /// `->`, the old spelling of `arrow`: the parser reads it as `arrow`
    /// (`canonical`) until the enforce step refuses it.
    ascii_arrow,
    /// `←` (U+2190), the rest-of-block bind (language.md §6.7, §12.7). A
    /// symbol, not an operator: it may appear only between a binding's
    /// pattern and its right-hand side.
    arrow_left,
    /// `<-`, the old spelling of `arrow_left`.
    ascii_arrow_left,
    /// `×` (U+00D7), which joins the element types of a tuple type
    /// (language.md §12.8). A type token only.
    times,
    /// `\`, the old spelling of a lambda's head (language.md §12.1).
    backslash,
    /// `λ` (U+03BB, the two bytes `CE BB`), which begins a lambda
    /// (language.md §12.1).
    lambda,
    pipe,
    underscore,
    /// `..`, which no construct uses: it is lexed as one token only so
    /// that Elm's `exposing (T(..))` gets one diagnostic (language.md §2.2,
    /// §5.2).
    dot_dot,
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
    /// `≠` (U+2260), and `/=`, its old spelling (language.md §12.7). Each
    /// `ascii_*` operator sits beside its symbol, inside the operator range.
    op_ne,
    ascii_ne,
    op_lt,
    op_gt,
    /// `≤` (U+2264) and `<=`.
    op_le,
    ascii_le,
    /// `≥` (U+2265) and `>=`.
    op_ge,
    ascii_ge,
    op_and_and,
    op_or_or,
    /// `▷` (U+25B7) and `|>`.
    op_pipe_right,
    ascii_pipe_right,
    /// `◁` (U+25C1) and `<|`.
    op_pipe_left,
    ascii_pipe_left,

    eof,
    invalid,
    /// A character a reader cannot tell from one of the symbols, or that a
    /// habit from another notation produces (`⇒`, `−`, `!=` …, language.md
    /// §12.7 *Lookalikes*). The lexer reports it as `invalid_character`, and
    /// its payload is the tag of the token it stands for, which the parser
    /// reads in its place so the parse goes on. Its length is re-derived from
    /// its bytes (`Tokenizer.lookalikeAt`).
    lookalike,

    // Markup (frontend.md §9.2). Each one is re-derived from its tag and
    // start alone, so the cached two-column form needs no mode column.

    /// The `<` that opens a tag or a fragment.
    markup_open,
    /// `</`, which opens a closing tag.
    markup_close_open,
    /// The `>` that ends an opening or a closing tag, or `<>`'s `>`.
    markup_gt,
    /// `/>`, which ends a self-closing tag.
    markup_self_close,
    /// A tag name: `[a-z][A-Za-z0-9-]*`, or `Upper(.Upper)*(.lower)?`.
    markup_name,
    /// An attribute name: `[A-Za-z][A-Za-z0-9_-]*`, with `:` allowed after
    /// the first byte. Keywords are not recognised inside a tag.
    markup_attr,
    /// A run of text between tags, raw: whitespace, newlines and character
    /// references are kept for lowering to judge.
    markup_text,
    /// `…` (U+2026), the spread of a list and of a component's attributes
    /// (language.md §6.8, §12.7).
    ellipsis,
    /// `...`, the old spelling of `ellipsis`.
    ascii_ellipsis,
    /// A byte an opening or closing tag cannot hold, reported by the lexer.
    /// It runs as the `invalid` its first byte would start, but stops before
    /// the first `>`, `/`, `{`, `}`, `"`, `=` or whitespace after that byte,
    /// so it never swallows the tag's own syntax.
    markup_stray,

    /// True for the identifier-like tags whose `payload` is a `Symbol`
    /// (`dot_index` is not one: its payload is the index itself).
    pub fn isInterned(tag: Tag) bool {
        return switch (tag) {
            .lower_ident, .upper_ident, .qualified_lower, .qualified_upper, .dot_lower, .markup_name, .markup_attr => true,
            else => false,
        };
    }

    /// True for `keyword_*`.
    pub fn isKeyword(tag: Tag) bool {
        return @intFromEnum(tag) >= @intFromEnum(Tag.keyword_if) and
            @intFromEnum(tag) <= @intFromEnum(Tag.keyword_foreign);
    }

    /// True for the binary operators of language.md §6.5 (`op_*`), in
    /// either spelling.
    pub fn isOperator(tag: Tag) bool {
        return @intFromEnum(tag) >= @intFromEnum(Tag.op_plus) and
            @intFromEnum(tag) <= @intFromEnum(Tag.ascii_pipe_left);
    }

    /// The symbol an old ASCII spelling stands for (language.md §12.7):
    /// `ascii_arrow` is `arrow` and so on; every other tag is itself. The
    /// two tags of a pair are one token to everything but the lexer, the
    /// formatter, which prints the spelling it read, and the enforce step's
    /// report.
    pub fn canonical(tag: Tag) Tag {
        return switch (tag) {
            .ascii_arrow => .arrow,
            .ascii_arrow_left => .arrow_left,
            .ascii_ne => .op_ne,
            .ascii_le => .op_le,
            .ascii_ge => .op_ge,
            .ascii_pipe_right => .op_pipe_right,
            .ascii_pipe_left => .op_pipe_left,
            .ascii_ellipsis => .ellipsis,
            else => tag,
        };
    }

    /// The old ASCII spelling of a symbol's tag, or null for every other
    /// tag: `canonical`'s inverse.
    pub fn ascii(tag: Tag) ?Tag {
        return switch (tag) {
            .arrow => .ascii_arrow,
            .arrow_left => .ascii_arrow_left,
            .op_ne => .ascii_ne,
            .op_le => .ascii_le,
            .op_ge => .ascii_ge,
            .op_pipe_right => .ascii_pipe_right,
            .op_pipe_left => .ascii_pipe_left,
            .ellipsis => .ascii_ellipsis,
            else => null,
        };
    }

    /// True for an old ASCII spelling (`ascii_*`).
    pub fn isAscii(tag: Tag) bool {
        return tag.canonical() != tag;
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
        .arrow => "→",
        .ascii_arrow => "->",
        .arrow_left => "←",
        .ascii_arrow_left => "<-",
        .times => "×",
        .backslash => "\\",
        .lambda => "λ",
        .pipe => "|",
        .underscore => "_",
        .question => "?",
        .dot_dot => "..",

        .op_plus => "+",
        .op_minus => "-",
        .op_star => "*",
        .op_slash => "/",
        .op_slash_slash => "//",
        .op_caret => "^",
        .op_plus_plus => "++",
        .op_colon_colon => "::",
        .op_eq_eq => "==",
        .op_ne => "≠",
        .ascii_ne => "/=",
        .op_lt => "<",
        .op_gt => ">",
        .op_le => "≤",
        .ascii_le => "<=",
        .op_ge => "≥",
        .ascii_ge => ">=",
        .op_and_and => "&&",
        .op_or_or => "||",
        .op_pipe_right => "▷",
        .ascii_pipe_right => "|>",
        .op_pipe_left => "◁",
        .ascii_pipe_left => "<|",

        .markup_open => "<",
        .markup_close_open => "</",
        .markup_gt => ">",
        .markup_self_close => "/>",
        .ellipsis => "…",
        .ascii_ellipsis => "...",

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
        .lookalike,
        .markup_name,
        .markup_attr,
        .markup_text,
        .markup_stray,
        => null,
    };
}

/// A character the lexer refuses as a lookalike of a symbol or an operator
/// (language.md §12.7, *Lookalikes*), and the tag it is read as.
pub const Lookalike = struct {
    bytes: []const u8,
    code_point: u21,
    name: []const u8,
    tag: Tag,
};

/// language.md §12.7's lookalike table, but `!=`, which the `!` state
/// handles, and the fullwidth block, which is not read as anything.
pub const lookalikes = [_]Lookalike{
    .{ .bytes = "−", .code_point = 0x2212, .name = "MINUS SIGN", .tag = .op_minus },
    .{ .bytes = "－", .code_point = 0xFF0D, .name = "FULLWIDTH HYPHEN-MINUS", .tag = .op_minus },
    .{ .bytes = "⇒", .code_point = 0x21D2, .name = "RIGHTWARDS DOUBLE ARROW", .tag = .arrow },
    .{ .bytes = "⟶", .code_point = 0x27F6, .name = "LONG RIGHTWARDS ARROW", .tag = .arrow },
    .{ .bytes = "⟹", .code_point = 0x27F9, .name = "LONG RIGHTWARDS DOUBLE ARROW", .tag = .arrow },
    .{ .bytes = "➝", .code_point = 0x279D, .name = "TRIANGLE-HEADED RIGHTWARDS ARROW", .tag = .arrow },
    .{ .bytes = "➔", .code_point = 0x2794, .name = "HEAVY WIDE-HEADED RIGHTWARDS ARROW", .tag = .arrow },
    .{ .bytes = "↦", .code_point = 0x21A6, .name = "RIGHTWARDS ARROW FROM BAR", .tag = .arrow },
    .{ .bytes = "⟵", .code_point = 0x27F5, .name = "LONG LEFTWARDS ARROW", .tag = .arrow_left },
    .{ .bytes = "⇐", .code_point = 0x21D0, .name = "LEFTWARDS DOUBLE ARROW", .tag = .arrow_left },
    .{ .bytes = "≦", .code_point = 0x2266, .name = "LESS-THAN OVER EQUAL TO", .tag = .op_le },
    .{ .bytes = "⩽", .code_point = 0x2A7D, .name = "LESS-THAN OR SLANTED EQUAL TO", .tag = .op_le },
    .{ .bytes = "≧", .code_point = 0x2267, .name = "GREATER-THAN OVER EQUAL TO", .tag = .op_ge },
    .{ .bytes = "⩾", .code_point = 0x2A7E, .name = "GREATER-THAN OR SLANTED EQUAL TO", .tag = .op_ge },
    .{ .bytes = "▶", .code_point = 0x25B6, .name = "BLACK RIGHT-POINTING TRIANGLE", .tag = .op_pipe_right },
    .{ .bytes = "▹", .code_point = 0x25B9, .name = "WHITE RIGHT-POINTING SMALL TRIANGLE", .tag = .op_pipe_right },
    .{ .bytes = "▸", .code_point = 0x25B8, .name = "BLACK RIGHT-POINTING SMALL TRIANGLE", .tag = .op_pipe_right },
    .{ .bytes = "▻", .code_point = 0x25BB, .name = "WHITE RIGHT-POINTING POINTER", .tag = .op_pipe_right },
    .{ .bytes = "⊳", .code_point = 0x22B3, .name = "CONTAINS AS NORMAL SUBGROUP", .tag = .op_pipe_right },
    .{ .bytes = "◀", .code_point = 0x25C0, .name = "BLACK LEFT-POINTING TRIANGLE", .tag = .op_pipe_left },
    .{ .bytes = "◃", .code_point = 0x25C3, .name = "WHITE LEFT-POINTING SMALL TRIANGLE", .tag = .op_pipe_left },
    .{ .bytes = "◂", .code_point = 0x25C2, .name = "BLACK LEFT-POINTING SMALL TRIANGLE", .tag = .op_pipe_left },
    .{ .bytes = "◅", .code_point = 0x25C5, .name = "WHITE LEFT-POINTING POINTER", .tag = .op_pipe_left },
    .{ .bytes = "⊲", .code_point = 0x22B2, .name = "NORMAL SUBGROUP OF", .tag = .op_pipe_left },
    .{ .bytes = "⋯", .code_point = 0x22EF, .name = "MIDLINE HORIZONTAL ELLIPSIS", .tag = .ellipsis },
    .{ .bytes = "‥", .code_point = 0x2025, .name = "TWO DOT LEADER", .tag = .ellipsis },
    .{ .bytes = "⨯", .code_point = 0x2A2F, .name = "VECTOR OR CROSS PRODUCT", .tag = .times },
    .{ .bytes = "✕", .code_point = 0x2715, .name = "MULTIPLICATION X", .tag = .times },
};

/// The lookalike whose bytes begin at `src[i]`, or null. `!=` is not
/// among them: the `!` state lexes it.
pub fn lookalikeAt(src: []const u8, i: u32) ?*const Lookalike {
    for (&lookalikes) |*look| {
        if (std.mem.startsWith(u8, src[i..], look.bytes)) return look;
    }
    return null;
}

/// How a message names a symbol's character: its code point and Unicode
/// name (language.md §12.7), or the ASCII it is for `op_minus`.
pub fn symbolName(tag: Tag) []const u8 {
    return switch (tag) {
        .arrow => "U+2192 RIGHTWARDS ARROW",
        .arrow_left => "U+2190 LEFTWARDS ARROW",
        .op_ne => "U+2260 NOT EQUAL TO",
        .op_le => "U+2264 LESS-THAN OR EQUAL TO",
        .op_ge => "U+2265 GREATER-THAN OR EQUAL TO",
        .op_pipe_right => "U+25B7 WHITE RIGHT-POINTING TRIANGLE",
        .op_pipe_left => "U+25C1 WHITE LEFT-POINTING TRIANGLE",
        .ellipsis => "U+2026 HORIZONTAL ELLIPSIS",
        .times => "U+00D7 MULTIPLICATION SIGN",
        .op_minus => "the ASCII hyphen-minus",
        else => @tagName(tag),
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
            (@intFromEnum(tag) >= @intFromEnum(Tag.l_paren) and @intFromEnum(tag) <= @intFromEnum(Tag.question)) or
            (@intFromEnum(tag) >= @intFromEnum(Tag.markup_open) and @intFromEnum(tag) <= @intFromEnum(Tag.markup_self_close)) or
            tag == .ellipsis or tag == .ascii_ellipsis;
        try std.testing.expectEqual(fixed, lexeme(tag) != null);
    }
}

test "canonical and ascii pair every old spelling with its symbol" {
    var pairs: usize = 0;
    inline for (@typeInfo(Tag).@"enum".fields) |field| {
        const tag: Tag = @enumFromInt(field.value);
        if (tag.ascii()) |old| {
            pairs += 1;
            try std.testing.expectEqual(tag, old.canonical());
            try std.testing.expect(old.isAscii());
            try std.testing.expect(!tag.isAscii());
            try std.testing.expectEqual(tag.isOperator(), old.isOperator());
            // The symbol is one code point; the old spelling is ASCII.
            try std.testing.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(lexeme(tag).?));
            for (lexeme(old).?) |b| try std.testing.expect(b < 0x80);
        }
    }
    try std.testing.expectEqual(@as(usize, 8), pairs);
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
