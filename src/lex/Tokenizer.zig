//! The lexer (docs/design/language.md §2, frontend.md §3.1–§3.3).
//!
//! `tokenize` turns one file's bytes into the four artifacts every later
//! phase reads: the `TokenList` (tag, start, line, payload — no length), the
//! comment list, the line-start table and the lexical diagnostics. It is
//! shaped like `std.zig.tokenizer`: `next` is a state machine driven by a
//! labeled switch over the byte at `index`, with one explicit state per
//! construct, and the sentinel on the input means the end of the file is a
//! byte like any other — there is no bounds check anywhere in the loop.
//!
//! What it allocates: appends to the output lists (pre-sized from the byte
//! count by `tokenize`, so a typical file never grows them) and the interner.
//! Nothing per token. Identifier-like tokens are interned WHILE they are
//! scanned: the scanner feeds each byte to an `InternPool.Hasher` and hands
//! the finished hash to `Local.getOrPutHashed`, so no identifier is read
//! twice. The token's `payload` is the resulting `Symbol` (a LOCAL symbol
//! until the session applies the worker's remap table — frontend.md §3.3);
//! `dot_index` carries the index value itself instead.
//!
//! Strings (§2.6) and markup (§11, frontend.md §9.1) are the constructs with
//! state across calls: a small STACK of modes, each with a brace depth,
//! whose top is `mode`/`depth` and whose bottom is always `normal`. Outside
//! markup the stack is that one entry, and every token is lexed exactly as
//! if markup did not exist. Tokens inside `${…}` and inside a markup hole
//! `{…}` are produced by the same `next`, which is what puts their
//! expressions into the flat token array with real offsets. Strings never
//! nest — a `"` or `\\` inside an interpolation is an error (§2.6), and a
//! `<` there is never markup — so a string and its `${…}` take the top
//! without pushing, and the entry below them waits in one slot of its own.
//!
//! Markup's modes (frontend.md §9.1): `tag` between `<` and `>`/`/>`,
//! `children` between an opening tag and its `</`, `close` between `</` and
//! `>` — the three `nextMarkup` lexes, so that `next`'s state machine is the
//! one ordinary code always had — and `hole`, a `{…}` opened in either of
//! the first two, which `next` lexes as ordinary code. A `<` in `normal` or
//! `hole` mode opens markup only when the byte after it is a letter or `>`
//! and the previous token cannot end an operand (§9.3), so every comparison
//! lexes as it always did. A newline followed by a non-space byte at column
//! 1 pops the whole stack back to `normal` from any markup mode, so an
//! unclosed element never swallows the file.
//!
//! Errors never stop the file (fast-compiler.md §5): every lexical error is
//! recorded in `Diagnostics` and produces an `invalid` token — the parser's
//! placeholder — and scanning resumes right after the offending bytes. The
//! one zero-length token is the `invalid` that marks where an unterminated
//! string was cut off by the end of its line. A `str_chunk` is guaranteed
//! well-formed (valid escapes, valid UTF-8, no tab, no bare `\r`): errors
//! split a chunk rather than hide inside it, so lowering can decode chunks
//! without a failure path. Errors inside a comment, a multiline line or a
//! markup text run only add a diagnostic; those tokens stay whole because
//! they are raw by definition (§2.3, §2.7, §11.4).
//!
//! Token length is never stored (frontend.md §3.2). `slice` re-derives it:
//! fixed spellings through `Token.lexeme`, everything else by re-running the
//! same scanner functions (`scanName`, `scanNumber`, `scanChunk`, …) that
//! `next` uses, so the two can never disagree.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const InternPool = @import("../InternPool.zig");
const Token = @import("Token.zig");
const Diagnostics = @import("Diagnostics.zig");

const Tag = Token.Tag;
const Tokenizer = @This();

source: [:0]const u8,
/// Byte offset of the next unread byte.
index: u32 = 0,
/// 0-based line of `index`.
line: u32 = 0,
/// The top of the mode stack.
mode: Mode = .normal,
/// The top entry's brace depth, for `interp` and `hole`: 1 right after the
/// `${` or `{` that pushed it, the entry popped by the `}` that brings it
/// to 0.
depth: u32 = 0,
/// The entries below the top, bottom first; `saved[0]`, when `sp > 0`, is
/// the bottom `normal` entry. Per-file scratch in `tokenize`'s frame, so
/// neither allocated nor copied; its length is the bound less the top.
/// Empty in a tokenizer built without one, whose every push is then at the
/// bound.
saved: []Saved = &.{},
/// How many entries sit below the top.
sp: u32 = 0,
/// How many entries of the stack, the top and the one under a string
/// included, are markup modes (`hole`, `tag`, `children`, `close`).
/// Non-zero exactly when a column-1 byte must end markup.
markup: u32 = 0,
/// Set once `nesting_too_deep` has been reported, so a runaway input gets
/// one diagnostic rather than one per level.
too_deep: bool = false,
/// Offset of the `"` that opened the string being scanned, for the span of
/// an `unterminated_string`.
string_start: u32 = 0,
/// The entry a `string` (or the `interp` inside it) sits on, which its
/// end restores (`openString`).
under_string: Saved = .{ .mode = .normal, .depth = 0 },
/// Set once the `eof` token has been emitted so `next` is idempotent past
/// the end.
done: bool = false,
gpa: Allocator,
interner: *InternPool.Local,
out: *Output,
/// `out.tokens`' columns, for `push`.
cols: Columns = .{},

pub const Mode = enum(u8) {
    /// Ordinary source text.
    normal,
    /// Between the quotes of a string: chunks, escapes, `${`.
    string,
    /// Inside `${…}`: ordinary tokens, with `{`/`}` counted.
    interp,
    /// Inside a markup `{…}`: ordinary tokens, with `{`/`}` counted.
    hole,
    /// Inside a markup tag: its name, attributes, `=`, strings, holes,
    /// comments; left by `>` (to `children`) or `/>`.
    tag,
    /// Between an opening tag and its closing tag: text, holes, child tags.
    children,
    /// Inside a closing tag: its name, then `>`.
    close,

    /// The four modes that only markup enters.
    fn isMarkup(mode: Mode) bool {
        return @intFromEnum(mode) >= @intFromEnum(Mode.hole);
    }

    /// The three modes `nextMarkup` lexes rather than `next`.
    fn hasOwnStates(mode: Mode) bool {
        return @intFromEnum(mode) >= @intFromEnum(Mode.tag);
    }
};

/// The mode stack's bound (frontend.md §9.1): a push past it is
/// `nesting_too_deep`.
pub const max_stack = 4096;

const Saved = struct { mode: Mode, depth: u32 };

/// Everything `tokenize` produces for one file. Owned by the caller; the
/// session moves the pieces into the file's artifact columns.
pub const Output = struct {
    tokens: Token.TokenList = .empty,
    comments: std.ArrayList(Token.Comment) = .empty,
    /// `line_starts[l]` is the byte offset of 0-based line `l`; `[0] == 0`.
    line_starts: std.ArrayList(u32) = .empty,
    diagnostics: Diagnostics = .empty,

    pub const empty: Output = .{};

    pub fn deinit(out: *Output, gpa: Allocator) void {
        out.tokens.deinit(gpa);
        out.comments.deinit(gpa);
        out.line_starts.deinit(gpa);
        out.diagnostics.deinit(gpa);
        out.* = undefined;
    }
};

/// Pre-sizing ratios, so the output lists are allocated once for a typical
/// file. Tokens: measured on the generated 100k-line corpus and on
/// bench/corpus (both land near one token per 6 bytes; `std.zig.Ast` uses
/// 8). Lines: real modules average 30–40 bytes per line, so /24 leaves
/// slack. Comments: one per 128 bytes is above every corpus file measured.
pub fn estimatedTokenCount(bytes: usize) usize {
    return bytes / 6 + 16;
}

pub fn estimatedLineCount(bytes: usize) usize {
    return bytes / 24 + 16;
}

pub fn estimatedCommentCount(bytes: usize) usize {
    return bytes / 128 + 8;
}

/// Lex all of `source` into `out`, which must be empty. `gpa` allocates the
/// output lists and the interner's growth; `interner` is the worker's local
/// pool. Always ends with an `eof` token, whatever the input.
pub fn tokenize(gpa: Allocator, source: [:0]const u8, interner: *InternPool.Local, out: *Output) Allocator.Error!void {
    std.debug.assert(out.tokens.len == 0 and out.line_starts.items.len == 0);
    try out.tokens.ensureTotalCapacity(gpa, estimatedTokenCount(source.len));
    try out.line_starts.ensureTotalCapacity(gpa, estimatedLineCount(source.len));
    try out.comments.ensureTotalCapacity(gpa, estimatedCommentCount(source.len));
    out.line_starts.appendAssumeCapacity(0);
    var saved: [max_stack - 1]Saved = undefined;
    var t: Tokenizer = .{ .source = source, .gpa = gpa, .interner = interner, .out = out, .saved = &saved };
    while (try t.next() != .eof) {}
}

const State = enum {
    start,
    name,
    number,
    dot,
    string,
    str_chunk,
    char,
    multiline,
    comment,
    minus,
    slash,
    pipe,
    lt,
    gt,
    equal,
    colon,
    plus,
    ampersand,
};

/// Scan one significant token, append it to `out.tokens` and return its tag.
/// Comments, newlines and diagnostics met on the way are recorded as side
/// effects. Returns `.eof` at the end of the input, forever after.
pub fn next(t: *Tokenizer) Allocator.Error!Tag {
    if (t.mode.hasOwnStates()) return t.nextMarkup();
    const src = t.source;
    var start = t.index;
    var payload: u32 = 0;
    var hasher: InternPool.Hasher = .init();

    const tag: Tag = state: switch (@as(State, if (t.mode == .string) .string else .start)) {
        .start => switch (src[t.index]) {
            0 => {
                if (t.index != src.len) {
                    // A NUL byte inside the file, not the sentinel.
                    try t.report(.invalid_character, t.index, t.index + 1);
                    break :state t.take(1, .invalid);
                }
                if (t.mode == .interp) break :state try t.unterminated();
                if (t.done) return .eof;
                t.done = true;
                break :state .eof;
            },
            ' ' => {
                // Indentation is runs of spaces; one tight loop beats a
                // dispatch through the switch per space.
                t.index += 1;
                while (src[t.index] == ' ') t.index += 1;
                start = t.index;
                continue :state .start;
            },
            '\n' => {
                if (t.mode == .interp) break :state try t.unterminated();
                t.index += 1;
                try t.newline();
                if (t.markup != 0) t.endMarkupAtColumnOne();
                start = t.index;
                continue :state .start;
            },
            '\r' => {
                if (src[t.index + 1] != '\n') {
                    try t.report(.bare_carriage_return, t.index, t.index + 1);
                    break :state t.take(1, .invalid);
                }
                if (t.mode == .interp) break :state try t.unterminated();
                t.index += 2;
                try t.newline();
                if (t.markup != 0) t.endMarkupAtColumnOne();
                start = t.index;
                continue :state .start;
            },
            '\t' => {
                try t.report(.tab_in_source, t.index, t.index + 1);
                break :state t.take(1, .invalid);
            },
            'a'...'z', 'A'...'Z' => continue :state .name,
            '_' => {
                // `_` alone is the wildcard; `_foo` is a lower identifier (§2.4).
                if (isIdentChar(src[t.index + 1])) continue :state .name;
                break :state t.take(1, .underscore);
            },
            '0'...'9' => continue :state .number,
            '"' => {
                if (t.mode == .interp) {
                    const end = nestedStringEnd(src, t.index);
                    try t.report(.nested_string_in_interpolation, t.index, end);
                    t.index = end;
                    break :state .invalid;
                }
                t.openString();
                break :state t.take(1, .str_start);
            },
            '\'' => continue :state .char,
            '\\' => {
                if (src[t.index + 1] != '\\') break :state t.take(1, .backslash);
                if (t.mode == .interp) {
                    try t.report(.nested_string_in_interpolation, t.index, t.index + 2);
                    break :state t.take(2, .invalid);
                }
                continue :state .multiline;
            },
            '.' => continue :state .dot,
            '-' => continue :state .minus,
            '/' => continue :state .slash,
            '|' => continue :state .pipe,
            '<' => continue :state .lt,
            '>' => continue :state .gt,
            '=' => continue :state .equal,
            ':' => continue :state .colon,
            '+' => continue :state .plus,
            '&' => continue :state .ampersand,
            '(' => break :state t.take(1, .l_paren),
            ')' => break :state t.take(1, .r_paren),
            '[' => break :state t.take(1, .l_bracket),
            ']' => break :state t.take(1, .r_bracket),
            '{' => {
                if (t.mode != .normal) t.depth += 1;
                break :state t.take(1, .l_brace);
            },
            '}' => {
                if (t.mode != .normal) {
                    t.depth -= 1;
                    if (t.depth == 0) {
                        if (t.mode == .interp) {
                            t.mode = .string;
                            break :state t.take(1, .interp_end);
                        }
                        t.popMode();
                    }
                }
                break :state t.take(1, .r_brace);
            },
            ',' => break :state t.take(1, .comma),
            '?' => break :state t.take(1, .question),
            '*' => break :state t.take(1, .op_star),
            '^' => break :state t.take(1, .op_caret),
            0x80...0xff => {
                // Non-ASCII outside a string, char or comment (§2.4); a
                // malformed sequence is the more specific error (§1).
                const seq = utf8Sequence(src, t.index);
                try t.report(if (seq.valid) .invalid_character else .invalid_utf8, t.index, t.index + seq.len);
                break :state t.take(seq.len, .invalid);
            },
            else => {
                // Control characters and punctuation the language has no use for.
                try t.report(.invalid_character, t.index, t.index + 1);
                break :state t.take(1, .invalid);
            },
        },

        .name => {
            const name = scanName(src, t.index, &hasher);
            t.index = name.end;
            if (name.tag == .lower_ident) {
                if (Token.keywords.get(src[start..t.index])) |keyword| break :state keyword;
            }
            payload = try t.intern(hasher.final(), start, t.index);
            break :state name.tag;
        },

        .number => {
            const number = scanNumber(src, t.index);
            if (number.tag == .invalid) try t.report(.invalid_number, start, number.end);
            t.index = number.end;
            break :state number.tag;
        },

        .dot => switch (src[t.index + 1]) {
            // `..` is one token, valid nowhere: it exists so the parser can
            // name Elm's `exposing (T(..))` in one diagnostic instead of the
            // lexer reporting each dot.
            '.' => {
                // A spread (frontend.md §9.1): `...` as the first token of a
                // hole opened in a tag — depth 1, straight after its `{`,
                // whatever whitespace or comments came between. Anywhere
                // else `...` is `..` and a stray `.`, as it always was.
                if (src[t.index + 2] == '.' and t.mode == .hole and t.depth == 1 and
                    t.prevTag() == .l_brace and t.sp != 0 and t.saved[t.sp - 1].mode == .tag)
                {
                    break :state t.take(3, .ellipsis);
                }
                break :state t.take(2, .dot_dot);
            },
            'a'...'z' => {
                t.index += 1;
                // The field name is interned without its dot, so `.name`
                // and `name` share a symbol.
                const name = scanName(src, t.index, &hasher);
                t.index = name.end;
                payload = try t.intern(hasher.final(), start + 1, t.index);
                break :state .dot_lower;
            },
            '0'...'9' => {
                t.index += 1;
                const digits = scanDigits(src, t.index);
                t.index = digits.end;
                payload = digits.value;
                break :state .dot_index;
            },
            else => {
                try t.report(.invalid_character, t.index, t.index + 1);
                break :state t.take(1, .invalid);
            },
        },

        .string => switch (src[t.index]) {
            '"' => {
                t.closeString();
                break :state t.take(1, .str_end);
            },
            '$' => {
                if (src[t.index + 1] != '{') continue :state .str_chunk;
                t.mode = .interp;
                t.depth = 1;
                break :state t.take(2, .interp_start);
            },
            '\n' => break :state try t.unterminated(),
            '\r' => {
                if (src[t.index + 1] == '\n') break :state try t.unterminated();
                try t.report(.bare_carriage_return, t.index, t.index + 1);
                break :state t.take(1, .invalid);
            },
            0 => {
                if (t.index == src.len) break :state try t.unterminated();
                try t.report(.invalid_character, t.index, t.index + 1);
                break :state t.take(1, .invalid);
            },
            '\t' => {
                try t.report(.tab_in_source, t.index, t.index + 1);
                break :state t.take(1, .invalid);
            },
            '\\' => {
                const escape = scanEscape(src, t.index);
                if (escape.ok) continue :state .str_chunk;
                try t.report(.invalid_escape, t.index, escape.end);
                t.index = escape.end;
                break :state .invalid;
            },
            0x80...0xff => {
                const seq = utf8Sequence(src, t.index);
                if (seq.valid) continue :state .str_chunk;
                try t.report(.invalid_utf8, t.index, t.index + seq.len);
                break :state t.take(seq.len, .invalid);
            },
            else => continue :state .str_chunk,
        },

        .str_chunk => {
            // Entered only when the byte at `index` belongs to a chunk, so
            // the chunk is never empty (§2.6).
            t.index = scanChunk(src, t.index);
            break :state .str_chunk;
        },

        .char => {
            const char = scanChar(src, t.index);
            t.index = char.end;
            if (char.code) |code| {
                try t.report(code, char.error_start, char.error_end);
                break :state .invalid;
            }
            break :state .char;
        },

        .multiline => {
            const end = lineEnd(src, t.index);
            try t.validateRaw(t.index + 2, end);
            t.index = end;
            break :state .multiline_line;
        },

        .comment => {
            try t.scanComment();
            start = t.index;
            continue :state .start;
        },

        // Longest match among operators (§2.2); `--` is always a comment.
        .minus => switch (src[t.index + 1]) {
            '-' => continue :state .comment,
            '>' => break :state t.take(2, .arrow),
            else => break :state t.take(1, .op_minus),
        },
        .slash => switch (src[t.index + 1]) {
            '/' => break :state t.take(2, .op_slash_slash),
            '=' => break :state t.take(2, .op_slash_eq),
            else => break :state t.take(1, .op_slash),
        },
        .pipe => switch (src[t.index + 1]) {
            '>' => break :state t.take(2, .op_pipe_right),
            '|' => break :state t.take(2, .op_or_or),
            else => break :state t.take(1, .pipe),
        },
        .lt => switch (src[t.index + 1]) {
            '|' => break :state t.take(2, .op_pipe_left),
            '=' => break :state t.take(2, .op_lte),
            // Longest match (§2.2): `x <-1` is `<-` and `1`, never `<` and
            // `-1`. A comparison with a negative literal needs the space.
            '-' => break :state t.take(2, .arrow_left),
            // Markup starts at an operand's start (frontend.md §9.3): a
            // letter or `>` next, and a previous token that cannot end an
            // operand. Inside `${…}` a `<` is always the operator.
            'a'...'z', 'A'...'Z', '>' => {
                if (t.mode != .interp and !endsOperand(t.prevTag())) {
                    try t.pushMode(.tag, 0);
                    break :state t.take(1, .markup_open);
                }
                break :state t.take(1, .op_lt);
            },
            else => break :state t.take(1, .op_lt),
        },
        .gt => switch (src[t.index + 1]) {
            '=' => break :state t.take(2, .op_gte),
            else => break :state t.take(1, .op_gt),
        },
        .equal => switch (src[t.index + 1]) {
            '=' => break :state t.take(2, .op_eq_eq),
            else => break :state t.take(1, .equal),
        },
        .colon => switch (src[t.index + 1]) {
            ':' => break :state t.take(2, .op_colon_colon),
            else => break :state t.take(1, .colon),
        },
        .plus => switch (src[t.index + 1]) {
            '+' => break :state t.take(2, .op_plus_plus),
            else => break :state t.take(1, .op_plus),
        },
        .ampersand => switch (src[t.index + 1]) {
            '&' => break :state t.take(2, .op_and_and),
            else => {
                try t.report(.invalid_character, t.index, t.index + 1);
                break :state t.take(1, .invalid);
            },
        },
    };

    try t.emit(tag, start, t.line, payload);
    return tag;
}

const MarkupState = enum { tag, close, children, stray };

/// `next` for the three modes with states of their own (frontend.md §9.1):
/// `tag`, `close` and `children`. Kept out of `next` so that the ordinary
/// lexer's state machine is the one it was before markup existed. When the
/// column-1 rule pops back to `normal`, the rest of the token is `next`'s.
fn nextMarkup(t: *Tokenizer) Allocator.Error!Tag {
    const src = t.source;
    var start = t.index;
    var payload: u32 = 0;
    var hasher: InternPool.Hasher = .init();
    // The line the token starts on: where the lexer is now, except for a
    // text run, which may end on a later line.
    var line = t.line;

    const tag: Tag = state: switch (@as(MarkupState, switch (t.mode) {
        .tag => .tag,
        .close => .close,
        else => .children,
    })) {
        // Inside `<…>`: the name right after the `<`, then attributes.
        .tag => switch (src[t.index]) {
            ' ' => {
                t.index += 1;
                while (src[t.index] == ' ') t.index += 1;
                start = t.index;
                continue :state .tag;
            },
            '\n', '\r' => {
                if (!try t.markupNewline()) continue :state .stray;
                if (t.mode == .normal) return t.next();
                start = t.index;
                continue :state .tag;
            },
            0 => {
                if (t.index != src.len) continue :state .stray;
                if (t.done) return .eof;
                t.done = true;
                break :state .eof;
            },
            'a'...'z', 'A'...'Z' => {
                if (t.prevTag() == .markup_open) {
                    t.index = scanTagName(src, t.index, &hasher);
                    payload = try t.intern(hasher.final(), start, t.index);
                    break :state .markup_name;
                }
                t.index = scanAttrName(src, t.index, &hasher);
                payload = try t.intern(hasher.final(), start, t.index);
                break :state .markup_attr;
            },
            '=' => break :state t.take(1, .equal),
            '"' => {
                t.openString();
                break :state t.take(1, .str_start);
            },
            '{' => {
                try t.pushMode(.hole, 1);
                break :state t.take(1, .l_brace);
            },
            '>' => {
                t.replaceMode(.children);
                break :state t.take(1, .markup_gt);
            },
            '/' => {
                if (src[t.index + 1] != '>') continue :state .stray;
                t.popMode();
                break :state t.take(2, .markup_self_close);
            },
            '-' => {
                if (src[t.index + 1] != '-') continue :state .stray;
                try t.scanComment();
                start = t.index;
                continue :state .tag;
            },
            else => continue :state .stray,
        },

        // Between `</` and `>`: the closing name, if any.
        .close => switch (src[t.index]) {
            ' ' => {
                t.index += 1;
                while (src[t.index] == ' ') t.index += 1;
                start = t.index;
                continue :state .close;
            },
            '\n', '\r' => {
                if (!try t.markupNewline()) continue :state .stray;
                if (t.mode == .normal) return t.next();
                start = t.index;
                continue :state .close;
            },
            0 => {
                if (t.index != src.len) continue :state .stray;
                if (t.done) return .eof;
                t.done = true;
                break :state .eof;
            },
            'a'...'z', 'A'...'Z' => {
                t.index = scanTagName(src, t.index, &hasher);
                payload = try t.intern(hasher.final(), start, t.index);
                break :state .markup_name;
            },
            '>' => {
                t.popMode();
                break :state t.take(1, .markup_gt);
            },
            else => continue :state .stray,
        },

        // Between an opening tag and its closing tag.
        .children => {
            if (t.atColumnOneBreak()) {
                t.popAll();
                return t.next();
            }
            switch (src[t.index]) {
                '<' => switch (src[t.index + 1]) {
                    'a'...'z', 'A'...'Z', '>' => {
                        try t.pushMode(.tag, 0);
                        break :state t.take(1, .markup_open);
                    },
                    '/' => {
                        t.replaceMode(.close);
                        break :state t.take(2, .markup_close_open);
                    },
                    // `a < b` in text: the `<` alone is the error, and the
                    // text resumes after it (language.md §11.4).
                    else => {
                        try t.report(.unexpected_token, t.index, t.index + 1);
                        break :state t.take(1, .invalid);
                    },
                },
                '>', '}' => {
                    try t.report(.unexpected_token, t.index, t.index + 1);
                    break :state t.take(1, .invalid);
                },
                '{' => {
                    try t.pushMode(.hole, 1);
                    break :state t.take(1, .l_brace);
                },
                else => {
                    if (src[t.index] == 0 and t.index == src.len) {
                        if (t.done) return .eof;
                        t.done = true;
                        break :state .eof;
                    }
                    const end = scanText(src, t.index);
                    try t.textBytes(t.index, end);
                    t.index = end;
                    break :state .markup_text;
                },
            }
        },

        // A byte a tag cannot hold: one `invalid` token, as long as
        // `invalidEnd` says a token starting with that byte is, and the tag
        // goes on (frontend.md §9.1).
        .stray => {
            const end = invalidEnd(src, t.index);
            const b = src[t.index];
            const code: diagnostic.Code = switch (b) {
                '\t' => .tab_in_source,
                '\r' => .bare_carriage_return,
                0...8, 11...12, 14...0x1f, 0x7f => .invalid_character,
                0x80...0xff => if (utf8Sequence(src, t.index).valid) .invalid_character else .invalid_utf8,
                else => .unexpected_token,
            };
            try t.report(code, t.index, end);
            t.index = end;
            break :state .invalid;
        },
    };

    if (tag != .markup_text) line = t.line;
    try t.emit(tag, start, line, payload);
    return tag;
}

/// Append the token `next` or `nextMarkup` scanned.
inline fn emit(t: *Tokenizer, tag: Tag, start: u32, line: u32, payload: u32) Allocator.Error!void {
    // The cached form is `(tag, start)` alone (frontend.md §3.2, §9.2):
    // every token's end must be re-derivable from them. The unit tests
    // (property, fuzz, stress) hold every token to it.
    if (builtin.is_test) std.debug.assert(tokenEnd(t.source, tag, start) == t.index);
    try t.push(tag, start, line, payload);
}

/// The token columns up to the list's capacity, refreshed when it grows.
const Columns = struct {
    tag: []Tag = &.{},
    start: []u32 = &.{},
    line: []u32 = &.{},
    payload: []u32 = &.{},
};

/// Append a token column by column: `MultiArrayList.append` recomputes
/// every column's address to write one token, which Zig's own backend does
/// not fold away, and it was nearly half of lexing a wide file.
fn push(t: *Tokenizer, tag: Tag, start: u32, line: u32, payload: u32) Allocator.Error!void {
    const list = &t.out.tokens;
    if (list.len == list.capacity or t.cols.tag.len != list.capacity) {
        try list.ensureUnusedCapacity(t.gpa, 1);
        const s = list.slice();
        t.cols = .{
            .tag = s.items(.tag).ptr[0..list.capacity],
            .start = s.items(.start).ptr[0..list.capacity],
            .line = s.items(.line).ptr[0..list.capacity],
            .payload = s.items(.payload).ptr[0..list.capacity],
        };
    }
    const i = list.len;
    list.len = i + 1;
    t.cols.tag[i] = tag;
    t.cols.start[i] = start;
    t.cols.line[i] = line;
    t.cols.payload[i] = payload;
}

/// Advance `n` bytes and return `tag`: the tail of every fixed-length arm.
/// Record the `--` comment at `index` and move to the end of its line
/// (language.md §2.3). Comments are not tokens; `before_token` is the
/// token that will come next.
fn scanComment(t: *Tokenizer) Allocator.Error!void {
    const src = t.source;
    const kind: Token.Comment.Kind = switch (src[t.index + 2]) {
        '|' => .doc,
        '!' => .module_doc,
        else => .plain,
    };
    const end = lineEnd(src, t.index);
    try t.validateRaw(t.index + 2, end);
    try t.out.comments.append(t.gpa, .{ .kind = kind, .start = t.index, .before_token = @intCast(t.out.tokens.len) });
    t.index = end;
}

/// Enter the string whose `"` is at `index`. Strings never nest — one
/// inside `${…}` is an error, and a `<` there is never markup — so the
/// entry below a string needs no stack: it is kept aside and put back.
fn openString(t: *Tokenizer) void {
    t.under_string = .{ .mode = t.mode, .depth = t.depth };
    t.mode = .string;
    t.string_start = t.index;
}

/// Leave the current string (and the interpolation it is in, if any).
fn closeString(t: *Tokenizer) void {
    t.mode = t.under_string.mode;
    t.depth = t.under_string.depth;
}

fn take(t: *Tokenizer, n: u32, tag: Tag) Tag {
    t.index += n;
    return tag;
}

/// Record the line that starts at `index` (called right after its newline
/// was consumed).
fn newline(t: *Tokenizer) Allocator.Error!void {
    t.line += 1;
    try t.out.line_starts.append(t.gpa, t.index);
}

// ---------------------------------------------------------------------------
// The mode stack (frontend.md §9.1)
// ---------------------------------------------------------------------------

/// The tag of the previous significant token, or `eof` at the start of the
/// file (comments are not tokens, so they are invisible here).
fn prevTag(t: *const Tokenizer) Tag {
    const len = t.out.tokens.len;
    return if (len == 0) .eof else t.cols.tag[len - 1];
}

/// The tags that can end an operand (frontend.md §9.3): after one of them a
/// `<` is the operator. `invalid` is among them, conservatively — it might
/// have been an operand, and reading the `<` as markup would cascade.
const operand_enders = blk: {
    var table: [256]bool = @splat(false);
    for ([_]Tag{
        .lower_ident,    .upper_ident,       .qualified_lower, .qualified_upper, .dot_lower,
        .dot_index,      .int,               .float,           .char,            .str_end,
        .multiline_line, .r_paren,           .r_bracket,       .r_brace,         .underscore,
        .question,       .markup_self_close,
        // In `normal` or `hole` mode a `markup_gt` is always a closing tag's:
        // an opening tag's `>` leads into `children`.
        .markup_gt,       .invalid,
    }) |tag| table[@intFromEnum(tag)] = true;
    break :blk table;
};

fn endsOperand(tag: Tag) bool {
    return operand_enders[@intFromEnum(tag)];
}

/// Push `mode` with brace depth `depth` over the current top. At the bound
/// the stack does not grow: `nesting_too_deep` is reported (once per file)
/// at the byte that asked, and the new mode replaces the top, so the
/// construct still lexes as that mode and every token stays well-formed.
fn pushMode(t: *Tokenizer, mode: Mode, depth: u32) Allocator.Error!void {
    if (t.sp == t.saved.len) {
        @branchHint(.cold);
        if (!t.too_deep) {
            t.too_deep = true;
            try t.report(.nesting_too_deep, t.index, t.index + 1);
        }
        t.replaceMode(mode);
        t.depth = depth;
        return;
    }
    t.saved[t.sp] = .{ .mode = t.mode, .depth = t.depth };
    t.sp += 1;
    t.mode = mode;
    t.depth = depth;
    t.markup += @intFromBool(mode.isMarkup());
}

/// Pop the top entry. Popping the bottom leaves it in place: after the
/// bound replaced an entry, a construct's end can outnumber its starts.
fn popMode(t: *Tokenizer) void {
    t.markup -= @intFromBool(t.mode.isMarkup());
    if (t.sp == 0) {
        t.mode = .normal;
        t.depth = 0;
        return;
    }
    t.sp -= 1;
    t.mode = t.saved[t.sp].mode;
    t.depth = t.saved[t.sp].depth;
}

/// Replace the top entry's mode, as a tag's `>` turns it into children.
fn replaceMode(t: *Tokenizer, mode: Mode) void {
    t.markup -= @intFromBool(t.mode.isMarkup());
    t.markup += @intFromBool(mode.isMarkup());
    t.mode = mode;
}

/// Back to the bottom `normal` entry.
fn popAll(t: *Tokenizer) void {
    t.sp = 0;
    t.mode = .normal;
    t.depth = 0;
    t.markup = 0;
}

/// A byte that ends markup when it stands at column 1: anything but a
/// space, a line terminator or the end of the file.
fn isColumnOneBreak(src: [:0]const u8, i: u32) bool {
    return switch (src[i]) {
        ' ', '\n', '\r' => false,
        0 => i != src.len,
        else => true,
    };
}

/// True when `index` is at column 1 of a line after the first and its byte
/// ends markup.
fn atColumnOneBreak(t: *const Tokenizer) bool {
    return t.index != 0 and t.source[t.index - 1] == '\n' and isColumnOneBreak(t.source, t.index);
}

/// Called right after a newline was consumed while some markup mode is on
/// the stack: a non-space byte at column 1 pops back to `normal`, and is
/// lexed as the start of a declaration (frontend.md §9.1).
fn endMarkupAtColumnOne(t: *Tokenizer) void {
    if (isColumnOneBreak(t.source, t.index)) t.popAll();
}

/// A line terminator in `tag` or `close` mode: consume `\n` or `\r\n` and
/// apply the column-1 rule. False for a bare `\r`, which is not one.
fn markupNewline(t: *Tokenizer) Allocator.Error!bool {
    const src = t.source;
    if (src[t.index] == '\r') {
        if (src[t.index + 1] != '\n') return false;
        t.index += 1;
    }
    t.index += 1;
    try t.newline();
    t.endMarkupAtColumnOne();
    return true;
}

/// Record the newlines of the text run `[from, to)` and report the bytes
/// that are errors everywhere (language.md §11.4): a tab, a bare `\r`,
/// another control character, malformed UTF-8. The run stays one token,
/// like a comment: it is raw text, and lowering reads it.
fn textBytes(t: *Tokenizer, from: u32, to: u32) Allocator.Error!void {
    const src = t.source;
    var i = from;
    while (i < to) {
        switch (src[i]) {
            '\n' => {
                i += 1;
                t.index = i;
                try t.newline();
            },
            '\t' => {
                try t.report(.tab_in_source, i, i + 1);
                i += 1;
            },
            '\r' => {
                if (src[i + 1] != '\n') try t.report(.bare_carriage_return, i, i + 1);
                i += 1;
            },
            0...8, 11...12, 14...0x1f, 0x7f => {
                try t.report(.invalid_character, i, i + 1);
                i += 1;
            },
            0x80...0xff => {
                const seq = utf8Sequence(src, i);
                if (!seq.valid) try t.report(.invalid_utf8, i, i + seq.len);
                i += seq.len;
            },
            else => i += 1,
        }
    }
}

fn report(t: *Tokenizer, code: diagnostic.Code, start: u32, end: u32) Allocator.Error!void {
    try t.out.diagnostics.report(t.gpa, code, start, end);
}

fn intern(t: *Tokenizer, hash: u64, from: u32, to: u32) Allocator.Error!u32 {
    const symbol = try t.interner.getOrPutHashed(t.gpa, hash, t.source[from..to]);
    return @intFromEnum(symbol);
}

/// The string being scanned hit the end of its line or the file: report it
/// from its opening quote to here, leave the string (and the interpolation
/// inside it, if that is where the line ended), and hand back the
/// zero-length `invalid` that stands in for the missing `str_end`. The line
/// terminator itself is not consumed, so the ordinary path counts it.
fn unterminated(t: *Tokenizer) Allocator.Error!Tag {
    try t.report(.unterminated_string, t.string_start, t.index);
    t.closeString();
    return .invalid;
}

/// Diagnostics for the raw bytes of a comment or multiline line: tabs, bare
/// carriage returns and malformed UTF-8 are errors even there (§2.1, §1),
/// but the token is left whole.
fn validateRaw(t: *Tokenizer, from: u32, to: u32) Allocator.Error!void {
    const src = t.source;
    var i = from;
    while (i < to) {
        switch (src[i]) {
            '\t' => {
                try t.report(.tab_in_source, i, i + 1);
                i += 1;
            },
            '\r' => {
                // `lineEnd` stopped before a `\r\n`, so any `\r` here is bare.
                try t.report(.bare_carriage_return, i, i + 1);
                i += 1;
            },
            0x80...0xff => {
                const seq = utf8Sequence(src, i);
                if (!seq.valid) try t.report(.invalid_utf8, i, i + seq.len);
                i += seq.len;
            },
            else => i += 1,
        }
    }
}

// ---------------------------------------------------------------------------
// Scanners shared by `next` and `slice`
// ---------------------------------------------------------------------------

fn isIdentChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

fn isHexDigit(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

fn hexValue(c: u8) u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// Consume `[A-Za-z0-9_]*` from `start`, feeding each byte to `hasher`
/// (`*InternPool.Hasher`, or `{}` to only measure).
fn scanIdentTail(src: [:0]const u8, start: u32, hasher: anytype) u32 {
    var i = start;
    while (isIdentChar(src[i])) : (i += 1) {
        if (@TypeOf(hasher) != void) hasher.updateByte(src[i]);
    }
    return i;
}

const Name = struct { end: u32, tag: Tag };

/// An identifier or qualified name starting at `start` (§2.4). After an
/// upper segment, `.` followed by a letter continues the token: another
/// upper segment keeps going, a lower segment ends it as `qualified_lower`.
/// `hasher` sees every byte including the dots.
fn scanName(src: [:0]const u8, start: u32, hasher: anytype) Name {
    if (!std.ascii.isUpper(src[start])) {
        return .{ .end = scanIdentTail(src, start, hasher), .tag = .lower_ident };
    }
    var tag: Tag = .upper_ident;
    var i = start;
    while (true) {
        i = scanIdentTail(src, i, hasher);
        if (src[i] != '.') return .{ .end = i, .tag = tag };
        switch (src[i + 1]) {
            'A'...'Z' => {
                if (@TypeOf(hasher) != void) hasher.updateByte('.');
                i += 1;
                tag = .qualified_upper;
            },
            'a'...'z' => {
                if (@TypeOf(hasher) != void) hasher.updateByte('.');
                return .{ .end = scanIdentTail(src, i + 1, hasher), .tag = .qualified_lower };
            },
            else => return .{ .end = i, .tag = tag },
        }
    }
}

/// A markup tag name from the letter at `start` (frontend.md §9.2): an
/// element's `[a-z][A-Za-z0-9-]*`, or a component's `Upper(.Upper)*(.lower)?`,
/// which is exactly what `scanName` reads from a capital. `hasher` sees
/// every byte.
fn scanTagName(src: [:0]const u8, start: u32, hasher: anytype) u32 {
    if (std.ascii.isUpper(src[start])) return scanName(src, start, hasher).end;
    var i = start;
    while (true) : (i += 1) {
        switch (src[i]) {
            'a'...'z', 'A'...'Z', '0'...'9', '-' => if (@TypeOf(hasher) != void) hasher.updateByte(src[i]),
            else => return i,
        }
    }
}

/// A markup attribute name from the letter at `start` (frontend.md §9.2):
/// `[A-Za-z][A-Za-z0-9_-]*` with `:` allowed after the first byte.
fn scanAttrName(src: [:0]const u8, start: u32, hasher: anytype) u32 {
    var i = start;
    while (true) : (i += 1) {
        switch (src[i]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', ':' => if (@TypeOf(hasher) != void) hasher.updateByte(src[i]),
            else => return i,
        }
    }
}

/// A run of markup text from `start` (frontend.md §9.1): up to the next
/// `<`, `{`, `>` or `}`, the end of the file, or a newline whose next byte
/// ends markup at column 1 — that newline is the run's last byte. The
/// caller has seen that `src[start]` is none of those, so the run is never
/// empty. Every other byte is the run's, errors included (`textBytes`).
fn scanText(src: [:0]const u8, start: u32) u32 {
    var i = start;
    while (true) {
        switch (src[i]) {
            '<', '{', '>', '}' => return i,
            0 => if (i == src.len) return i else {
                i += 1;
            },
            '\n' => {
                i += 1;
                if (isColumnOneBreak(src, i)) return i;
            },
            else => i += 1,
        }
    }
}

const Number = struct { end: u32, tag: Tag };

/// A numeric literal starting at a digit (§2.5): `int`, `float`, or
/// `invalid` when an identifier character follows the number directly or an
/// exponent has no digits. The invalid token extends over the trailing
/// identifier characters so scanning resumes at a clean boundary.
fn scanNumber(src: [:0]const u8, start: u32) Number {
    var i = start;
    var tag: Tag = .int;
    if (src[i] == '0' and src[i + 1] == 'x') {
        i += 2;
        if (!isHexDigit(src[i])) tag = .invalid;
        while (isHexDigit(src[i])) i += 1;
    } else {
        while (std.ascii.isDigit(src[i])) i += 1;
        // Into a float only if a digit follows the dot: `1.e5` is `1` `.e5`.
        if (src[i] == '.' and std.ascii.isDigit(src[i + 1])) {
            i += 1;
            while (std.ascii.isDigit(src[i])) i += 1;
            tag = .float;
        }
        if (src[i] == 'e' or src[i] == 'E') {
            var j = i + 1;
            if (src[j] == '+' or src[j] == '-') j += 1;
            if (std.ascii.isDigit(src[j])) {
                i = j;
                while (std.ascii.isDigit(src[i])) i += 1;
                tag = .float;
            } else {
                i = j;
                tag = .invalid;
            }
        }
    }
    if (isIdentChar(src[i])) {
        tag = .invalid;
        i = scanIdentTail(src, i, {});
    }
    return .{ .end = i, .tag = tag };
}

const Digits = struct { end: u32, value: u32 };

/// `[0-9]+` from `start` with its decimal value, saturated at `maxInt(u32)`
/// (the parser re-reads the text when it must judge the index; §6.4).
fn scanDigits(src: [:0]const u8, start: u32) Digits {
    var i = start;
    var value: u32 = 0;
    while (std.ascii.isDigit(src[i])) : (i += 1) {
        value = value *| 10 +| (src[i] - '0');
    }
    return .{ .end = i, .value = value };
}

const Utf8 = struct { len: u32, valid: bool };

/// The UTF-8 sequence starting at the non-ASCII byte `src[i]`: its length
/// and whether it is well formed. For a malformed sequence `len` is the
/// lead byte plus the continuation bytes that did match (at least 1), which
/// is where lexing resumes (§1, "the next valid boundary"). Reads stop at
/// the first byte that is not a continuation byte, so the sentinel is never
/// passed.
fn utf8Sequence(src: [:0]const u8, i: u32) Utf8 {
    const n: u32 = std.unicode.utf8ByteSequenceLength(src[i]) catch return .{ .len = 1, .valid = false };
    var k: u32 = 1;
    while (k < n) : (k += 1) {
        if (src[i + k] & 0xC0 != 0x80) return .{ .len = k, .valid = false };
    }
    const ok = switch (n) {
        2 => if (std.unicode.utf8Decode2(src[i..][0..2].*)) |_| true else |_| false,
        3 => if (std.unicode.utf8Decode3(src[i..][0..3].*)) |_| true else |_| false,
        4 => if (std.unicode.utf8Decode4(src[i..][0..4].*)) |_| true else |_| false,
        else => true,
    };
    return .{ .len = n, .valid = ok };
}

const Escape = struct { end: u32, ok: bool };

/// The escape starting at the `\` at `src[i]` (§2.6). `end` is where the
/// escape stops whether or not it is valid: for a bad `\u{…}` that is the
/// first byte that broke it (or past the `}` when the value is not a scalar
/// value), so the diagnostic quotes exactly what was written.
fn scanEscape(src: [:0]const u8, i: u32) Escape {
    switch (src[i + 1]) {
        'n', 'r', 't', '\\', '"', '$', '\'' => return .{ .end = i + 2, .ok = true },
        'u' => {
            if (src[i + 2] != '{') return .{ .end = i + 2, .ok = false };
            var j = i + 3;
            var digits: u32 = 0;
            var value: u32 = 0;
            while (isHexDigit(src[j])) : (j += 1) {
                digits += 1;
                if (digits <= 6) value = value * 16 + hexValue(src[j]);
            }
            if (src[j] != '}') return .{ .end = j, .ok = false };
            const scalar = digits >= 1 and digits <= 6 and value <= 0x10FFFF and !(value >= 0xD800 and value <= 0xDFFF);
            return .{ .end = j + 1, .ok = scalar };
        },
        0, '\n', '\r', '\t' => return .{ .end = i + 1, .ok = false },
        0x80...0xff => {
            // Quote the whole character, not its first byte.
            const seq = utf8Sequence(src, i + 1);
            return .{ .end = i + 1 + seq.len, .ok = false };
        },
        else => return .{ .end = i + 2, .ok = false },
    }
}

/// A maximal well-formed run of string text from `start` (§2.6): stops at
/// `"`, `${`, a line end, the sentinel, a tab, a bare `\r`, an invalid
/// escape or malformed UTF-8 — everything the `string` state handles.
fn scanChunk(src: [:0]const u8, start: u32) u32 {
    var i = start;
    while (true) {
        switch (src[i]) {
            '"', '\n', '\r', '\t', 0 => return i,
            '$' => {
                if (src[i + 1] == '{') return i;
                i += 1;
            },
            '\\' => {
                const escape = scanEscape(src, i);
                if (!escape.ok) return i;
                i = escape.end;
            },
            0x80...0xff => {
                const seq = utf8Sequence(src, i);
                if (!seq.valid) return i;
                i += seq.len;
            },
            else => i += 1,
        }
    }
}

const Char = struct {
    end: u32,
    /// The first problem found, if any; `error_start..error_end` is its span.
    code: ?diagnostic.Code = null,
    error_start: u32 = 0,
    error_end: u32 = 0,

    fn problem(c: *Char, code: diagnostic.Code, s: u32, e: u32) void {
        if (c.code != null) return;
        c.code = code;
        c.error_start = s;
        c.error_end = e;
    }
};

/// A character literal starting at the `'` at `src[start]` (§2.8). It runs
/// to the closing `'` on the same line, or to the line end. Exactly one
/// unit — an escape or one UTF-8 character — must sit between the quotes;
/// the first problem met wins, so `'\z'` is an `invalid_escape`, not also an
/// `invalid_char_literal`.
fn scanChar(src: [:0]const u8, start: u32) Char {
    var c: Char = .{ .end = undefined };
    var i = start + 1;
    var units: u32 = 0;
    var closed = false;
    while (true) {
        switch (src[i]) {
            '\'' => {
                i += 1;
                closed = true;
                break;
            },
            '\n' => break,
            '\r' => {
                if (src[i + 1] == '\n') break;
                c.problem(.bare_carriage_return, i, i + 1);
                i += 1;
                units += 1;
            },
            0 => {
                if (i == src.len) break;
                c.problem(.invalid_character, i, i + 1);
                i += 1;
                units += 1;
            },
            '\t' => {
                c.problem(.tab_in_source, i, i + 1);
                i += 1;
                units += 1;
            },
            '\\' => {
                const escape = scanEscape(src, i);
                if (!escape.ok) c.problem(.invalid_escape, i, escape.end);
                i = escape.end;
                units += 1;
            },
            0x80...0xff => {
                const seq = utf8Sequence(src, i);
                if (!seq.valid) c.problem(.invalid_utf8, i, i + seq.len);
                i += seq.len;
                units += 1;
            },
            else => {
                i += 1;
                units += 1;
            },
        }
    }
    c.end = i;
    if (!closed or units != 1) c.problem(.invalid_char_literal, start, i);
    return c;
}

/// The string literal at `src[i] == '"'` met inside an interpolation: up to
/// and including its closing `"` on the same line (escapes skipped), or the
/// line end. It becomes one `invalid` token so the rest of the interpolation
/// still lexes.
fn nestedStringEnd(src: [:0]const u8, i: u32) u32 {
    var j = i + 1;
    while (true) {
        switch (src[j]) {
            '"' => return j + 1,
            '\n', '\r' => return j,
            0 => if (j == src.len) return j else {
                j += 1;
            },
            '\\' => switch (src[j + 1]) {
                0, '\n', '\r' => return j + 1,
                else => j += 2,
            },
            else => j += 1,
        }
    }
}

/// Offset of the end of the line containing `i`: the `\n`, the `\r` of a
/// `\r\n`, or the end of the file. Vectorised by `indexOfScalarPos`.
fn lineEnd(src: [:0]const u8, i: u32) u32 {
    const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse return @intCast(src.len);
    if (nl > i and src[nl - 1] == '\r') return @intCast(nl - 1);
    return @intCast(nl);
}

// ---------------------------------------------------------------------------
// Text recovery
// ---------------------------------------------------------------------------

/// The source text of the token `(tag, start)`. Fixed spellings come from
/// `Token.lexeme`; everything else is re-scanned from `start` with the same
/// functions `next` used, so the result is exactly the bytes `next` consumed
/// for that token.
pub fn slice(source: [:0]const u8, tag: Tag, start: u32) []const u8 {
    return source[start..tokenEnd(source, tag, start)];
}

/// The end offset of the token `(tag, start)`; see `slice`.
pub fn tokenEnd(source: [:0]const u8, tag: Tag, start: u32) u32 {
    return switch (tag) {
        .lower_ident, .upper_ident, .qualified_lower, .qualified_upper => scanName(source, start, {}).end,
        .dot_lower => scanName(source, start + 1, {}).end,
        .dot_index => scanDigits(source, start + 1).end,
        .int, .float => scanNumber(source, start).end,
        .str_start, .str_end, .interp_end => start + 1,
        .interp_start => start + 2,
        .str_chunk => scanChunk(source, start),
        .multiline_line => lineEnd(source, start),
        .char => scanChar(source, start).end,
        .eof => start,
        .invalid => invalidEnd(source, start),
        .markup_name => scanTagName(source, start, {}),
        .markup_attr => scanAttrName(source, start, {}),
        .markup_text => scanText(source, start),
        // Keywords, symbols and operators: their spelling is fixed.
        else => if (Token.lexeme(tag)) |text| start + @as(u32, @intCast(text.len)) else start,
    };
}

/// Where an `invalid` token ends, decided by its first byte — the same
/// decision the state that produced it made. Ambiguity between the string
/// states and the normal state is resolved by the fact that in normal mode
/// `"`, `\` and a line terminator never produce `invalid`. Markup's stray
/// bytes — a byte a tag cannot hold, and `<`, `>` or `}` in text — take
/// their length from this function, so they agree with it by construction.
fn invalidEnd(source: [:0]const u8, start: u32) u32 {
    switch (source[start]) {
        // The zero-length marker of an unterminated string.
        '\n' => return start,
        0 => return if (start == source.len) start else start + 1,
        '\r' => return if (source[start + 1] == '\n') start else start + 1,
        // Nested string / multiline marker inside an interpolation.
        '"' => return nestedStringEnd(source, start),
        '\\' => return if (source[start + 1] == '\\') start + 2 else scanEscape(source, start).end,
        '\'' => return scanChar(source, start).end,
        '0'...'9' => return scanNumber(source, start).end,
        0x80...0xff => return start + utf8Sequence(source, start).len,
        // Tab, control byte, stray punctuation, lone `.` or `&`.
        else => return start + 1,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const fuzzing = @import("../fuzzing.zig");

/// One expected token: what the dump shows, plus the interned text for
/// identifier-like tags (checked against the interner) or the index value
/// for `dot_index`.
const Tok = struct {
    tag: Tag,
    start: u32,
    line: u32 = 0,
    text: []const u8,
};

const Expected = struct {
    tokens: []const Tok,
    comments: []const Token.Comment = &.{},
    diagnostics: []const Diagnostics.Item = &.{},
    /// Defaults to a single line.
    line_starts: []const u32 = &.{0},
};

/// Lex `source` and compare the WHOLE result: every token (tag, start, line,
/// text, and the interned symbol's text where there is one), every comment,
/// every diagnostic and the line table.
fn expectLex(source: [:0]const u8, expected: Expected) !void {
    var interner: InternPool.Local = .empty;
    defer interner.deinit(testing.allocator);
    var out: Output = .empty;
    defer out.deinit(testing.allocator);
    try tokenize(testing.allocator, source, &interner, &out);

    var actual: std.ArrayList(Tok) = .empty;
    defer actual.deinit(testing.allocator);
    const s = out.tokens.slice();
    for (s.items(.tag), s.items(.start), s.items(.line), s.items(.payload)) |tag, start, line, payload| {
        const text = slice(source, tag, start);
        try actual.append(testing.allocator, .{ .tag = tag, .start = start, .line = line, .text = text });
        if (tag.isInterned()) {
            const interned = interner.slice(@enumFromInt(payload));
            try testing.expectEqualStrings(if (tag == .dot_lower) text[1..] else text, interned);
        } else if (tag == .dot_index) {
            try testing.expectEqual(std.fmt.parseInt(u32, text[1..], 10) catch std.math.maxInt(u32), payload);
        } else {
            try testing.expectEqual(@as(u32, 0), payload);
        }
    }
    try testing.expectEqualDeep(expected.tokens, actual.items);
    try testing.expectEqualSlices(Token.Comment, expected.comments, out.comments.items);
    try testing.expectEqualSlices(Diagnostics.Item, expected.diagnostics, out.diagnostics.items());
    try testing.expectEqualSlices(u32, expected.line_starts, out.line_starts.items);
}

test "empty file is a lone eof" {
    try expectLex("", .{ .tokens = &.{.{ .tag = .eof, .start = 0, .text = "" }} });
    try expectLex("\n\n", .{
        .tokens = &.{.{ .tag = .eof, .start = 2, .line = 2, .text = "" }},
        .line_starts = &.{ 0, 1, 2 },
    });
}

test "lower and upper identifiers, with digits and underscores" {
    try expectLex("foo fooBar foo_1 Foo Maybe x1_Y", .{ .tokens = &.{
        .{ .tag = .lower_ident, .start = 0, .text = "foo" },
        .{ .tag = .lower_ident, .start = 4, .text = "fooBar" },
        .{ .tag = .lower_ident, .start = 11, .text = "foo_1" },
        .{ .tag = .upper_ident, .start = 17, .text = "Foo" },
        .{ .tag = .upper_ident, .start = 21, .text = "Maybe" },
        .{ .tag = .lower_ident, .start = 27, .text = "x1_Y" },
        .{ .tag = .eof, .start = 31, .text = "" },
    } });
}

test "equal identifiers share one symbol; different ones do not" {
    var interner: InternPool.Local = .empty;
    defer interner.deinit(testing.allocator);
    var out: Output = .empty;
    defer out.deinit(testing.allocator);
    try tokenize(testing.allocator, "view model view Model .view", &interner, &out);
    const payloads = out.tokens.items(.payload);
    try testing.expectEqual(payloads[0], payloads[2]);
    try testing.expectEqual(payloads[0], payloads[4]); // `.view` interns `view`
    try testing.expect(payloads[0] != payloads[1]);
    try testing.expect(payloads[0] != payloads[3]); // case matters
    try testing.expectEqual(@as(u32, 3), interner.count());
}

test "keywords versus identifiers: iffy, _foo, foreign, every keyword" {
    try expectLex("if iffy _foo foreign _ __ x_", .{ .tokens = &.{
        .{ .tag = .keyword_if, .start = 0, .text = "if" },
        .{ .tag = .lower_ident, .start = 3, .text = "iffy" },
        .{ .tag = .lower_ident, .start = 8, .text = "_foo" },
        .{ .tag = .keyword_foreign, .start = 13, .text = "foreign" },
        .{ .tag = .underscore, .start = 21, .text = "_" },
        .{ .tag = .lower_ident, .start = 23, .text = "__" },
        .{ .tag = .lower_ident, .start = 26, .text = "x_" },
        .{ .tag = .eof, .start = 28, .text = "" },
    } });
    try expectLex("if then else case of let in type alias pub opaque import as exposing foreign", .{ .tokens = &.{
        .{ .tag = .keyword_if, .start = 0, .text = "if" },
        .{ .tag = .keyword_then, .start = 3, .text = "then" },
        .{ .tag = .keyword_else, .start = 8, .text = "else" },
        .{ .tag = .keyword_case, .start = 13, .text = "case" },
        .{ .tag = .keyword_of, .start = 18, .text = "of" },
        .{ .tag = .keyword_let, .start = 21, .text = "let" },
        .{ .tag = .keyword_in, .start = 25, .text = "in" },
        .{ .tag = .keyword_type, .start = 28, .text = "type" },
        .{ .tag = .keyword_alias, .start = 33, .text = "alias" },
        .{ .tag = .keyword_pub, .start = 39, .text = "pub" },
        .{ .tag = .keyword_opaque, .start = 43, .text = "opaque" },
        .{ .tag = .keyword_import, .start = 50, .text = "import" },
        .{ .tag = .keyword_as, .start = 57, .text = "as" },
        .{ .tag = .keyword_exposing, .start = 60, .text = "exposing" },
        .{ .tag = .keyword_foreign, .start = 69, .text = "foreign" },
        .{ .tag = .eof, .start = 76, .text = "" },
    } });
    // `True`, `Just` etc. are constructors, not keywords.
    try expectLex("True Just", .{ .tokens = &.{
        .{ .tag = .upper_ident, .start = 0, .text = "True" },
        .{ .tag = .upper_ident, .start = 5, .text = "Just" },
        .{ .tag = .eof, .start = 9, .text = "" },
    } });
}

test "qualified names: A.B.c, A.B, A.b.c, a.b, A .b, A.if" {
    try expectLex("A.B.c A.B A.b.c a.b A .b A.if Json.Decode.string", .{ .tokens = &.{
        .{ .tag = .qualified_lower, .start = 0, .text = "A.B.c" },
        .{ .tag = .qualified_upper, .start = 6, .text = "A.B" },
        .{ .tag = .qualified_lower, .start = 10, .text = "A.b" },
        .{ .tag = .dot_lower, .start = 13, .text = ".c" },
        .{ .tag = .lower_ident, .start = 16, .text = "a" },
        .{ .tag = .dot_lower, .start = 17, .text = ".b" },
        .{ .tag = .upper_ident, .start = 20, .text = "A" },
        .{ .tag = .dot_lower, .start = 22, .text = ".b" },
        .{ .tag = .qualified_lower, .start = 25, .text = "A.if" },
        .{ .tag = .qualified_lower, .start = 30, .text = "Json.Decode.string" },
        .{ .tag = .eof, .start = 48, .text = "" },
    } });
}

test "dot_index: t.0.1, .12, a dot before digits after an upper name, saturation" {
    try expectLex("t.0.1 x.12 A.0 t.99999999999", .{ .tokens = &.{
        .{ .tag = .lower_ident, .start = 0, .text = "t" },
        .{ .tag = .dot_index, .start = 1, .text = ".0" },
        .{ .tag = .dot_index, .start = 3, .text = ".1" },
        .{ .tag = .lower_ident, .start = 6, .text = "x" },
        .{ .tag = .dot_index, .start = 7, .text = ".12" },
        .{ .tag = .upper_ident, .start = 11, .text = "A" },
        .{ .tag = .dot_index, .start = 12, .text = ".0" },
        .{ .tag = .lower_ident, .start = 15, .text = "t" },
        .{ .tag = .dot_index, .start = 16, .text = ".99999999999" },
        .{ .tag = .eof, .start = 28, .text = "" },
    } });
}

test "a dot that starts nothing is invalid_character" {
    try expectLex("a . b .Foo ._x", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 0, .text = "a" },
            .{ .tag = .invalid, .start = 2, .text = "." },
            .{ .tag = .lower_ident, .start = 4, .text = "b" },
            .{ .tag = .invalid, .start = 6, .text = "." },
            .{ .tag = .upper_ident, .start = 7, .text = "Foo" },
            .{ .tag = .invalid, .start = 11, .text = "." },
            .{ .tag = .lower_ident, .start = 12, .text = "_x" },
            .{ .tag = .eof, .start = 14, .text = "" },
        },
        .diagnostics = &.{
            .{ .code = .invalid_character, .start = 2, .end = 3 },
            .{ .code = .invalid_character, .start = 6, .end = 7 },
            .{ .code = .invalid_character, .start = 11, .end = 12 },
        },
    });
}

test "numbers: ints, hex, floats with fractions and exponents" {
    try expectLex("0 42 0x1F 0xff 1.5 1e5 1E10 1.5e-3 2.0E+5 6e0", .{ .tokens = &.{
        .{ .tag = .int, .start = 0, .text = "0" },
        .{ .tag = .int, .start = 2, .text = "42" },
        .{ .tag = .int, .start = 5, .text = "0x1F" },
        .{ .tag = .int, .start = 10, .text = "0xff" },
        .{ .tag = .float, .start = 15, .text = "1.5" },
        .{ .tag = .float, .start = 19, .text = "1e5" },
        .{ .tag = .float, .start = 23, .text = "1E10" },
        .{ .tag = .float, .start = 28, .text = "1.5e-3" },
        .{ .tag = .float, .start = 35, .text = "2.0E+5" },
        .{ .tag = .float, .start = 42, .text = "6e0" },
        .{ .tag = .eof, .start = 45, .text = "" },
    } });
}

test "numbers: `1.` and `1.e5` stay int; the dot is then a field access" {
    try expectLex("1.e5 1.x 1.0.1 1..", .{
        .tokens = &.{
            .{ .tag = .int, .start = 0, .text = "1" },
            .{ .tag = .dot_lower, .start = 1, .text = ".e5" },
            .{ .tag = .int, .start = 5, .text = "1" },
            .{ .tag = .dot_lower, .start = 6, .text = ".x" },
            .{ .tag = .float, .start = 9, .text = "1.0" },
            .{ .tag = .dot_index, .start = 12, .text = ".1" },
            .{ .tag = .int, .start = 15, .text = "1" },
            // `..` is one token, reported by the parser wherever it
            // stands, and never by the lexer.
            .{ .tag = .dot_dot, .start = 16, .text = ".." },
            .{ .tag = .eof, .start = 18, .text = "" },
        },
    });
}

test "invalid_number: identifier characters after a number, bad hex, bare exponent, underscore" {
    try expectLex("12abc 0x1G 0x 1e 1e+ 1_000 1.5x", .{
        .tokens = &.{
            .{ .tag = .invalid, .start = 0, .text = "12abc" },
            .{ .tag = .invalid, .start = 6, .text = "0x1G" },
            .{ .tag = .invalid, .start = 11, .text = "0x" },
            .{ .tag = .invalid, .start = 14, .text = "1e" },
            .{ .tag = .invalid, .start = 17, .text = "1e+" },
            .{ .tag = .invalid, .start = 21, .text = "1_000" },
            .{ .tag = .invalid, .start = 27, .text = "1.5x" },
            .{ .tag = .eof, .start = 31, .text = "" },
        },
        .diagnostics = &.{
            .{ .code = .invalid_number, .start = 0, .end = 5 },
            .{ .code = .invalid_number, .start = 6, .end = 10 },
            .{ .code = .invalid_number, .start = 11, .end = 13 },
            .{ .code = .invalid_number, .start = 14, .end = 16 },
            .{ .code = .invalid_number, .start = 17, .end = 20 },
            .{ .code = .invalid_number, .start = 21, .end = 26 },
            .{ .code = .invalid_number, .start = 27, .end = 31 },
        },
    });
}

test "every symbol" {
    try expectLex("( ) [ ] { } , : = -> \\ | _ ?", .{ .tokens = &.{
        .{ .tag = .l_paren, .start = 0, .text = "(" },
        .{ .tag = .r_paren, .start = 2, .text = ")" },
        .{ .tag = .l_bracket, .start = 4, .text = "[" },
        .{ .tag = .r_bracket, .start = 6, .text = "]" },
        .{ .tag = .l_brace, .start = 8, .text = "{" },
        .{ .tag = .r_brace, .start = 10, .text = "}" },
        .{ .tag = .comma, .start = 12, .text = "," },
        .{ .tag = .colon, .start = 14, .text = ":" },
        .{ .tag = .equal, .start = 16, .text = "=" },
        .{ .tag = .arrow, .start = 18, .text = "->" },
        .{ .tag = .backslash, .start = 21, .text = "\\" },
        .{ .tag = .pipe, .start = 23, .text = "|" },
        .{ .tag = .underscore, .start = 25, .text = "_" },
        .{ .tag = .question, .start = 27, .text = "?" },
        .{ .tag = .eof, .start = 28, .text = "" },
    } });
}

test "every operator" {
    try expectLex("+ - * / // ^ ++ :: == /= < > <= >= && || |> <| <-", .{ .tokens = &.{
        .{ .tag = .op_plus, .start = 0, .text = "+" },
        .{ .tag = .op_minus, .start = 2, .text = "-" },
        .{ .tag = .op_star, .start = 4, .text = "*" },
        .{ .tag = .op_slash, .start = 6, .text = "/" },
        .{ .tag = .op_slash_slash, .start = 8, .text = "//" },
        .{ .tag = .op_caret, .start = 11, .text = "^" },
        .{ .tag = .op_plus_plus, .start = 13, .text = "++" },
        .{ .tag = .op_colon_colon, .start = 16, .text = "::" },
        .{ .tag = .op_eq_eq, .start = 19, .text = "==" },
        .{ .tag = .op_slash_eq, .start = 22, .text = "/=" },
        .{ .tag = .op_lt, .start = 25, .text = "<" },
        .{ .tag = .op_gt, .start = 27, .text = ">" },
        .{ .tag = .op_lte, .start = 29, .text = "<=" },
        .{ .tag = .op_gte, .start = 32, .text = ">=" },
        .{ .tag = .op_and_and, .start = 35, .text = "&&" },
        .{ .tag = .op_or_or, .start = 38, .text = "||" },
        .{ .tag = .op_pipe_right, .start = 41, .text = "|>" },
        .{ .tag = .op_pipe_left, .start = 44, .text = "<|" },
        .{ .tag = .arrow_left, .start = 47, .text = "<-" },
        .{ .tag = .eof, .start = 49, .text = "" },
    } });
}

test "longest match: |> vs | >, // vs / /, -> vs - >, <| vs < |, and -- after an operator" {
    try expectLex("a|>b a| >b a//b a/ /b a->b a- >b a<|b a< |b a+--c\nb", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 0, .text = "a" },
            .{ .tag = .op_pipe_right, .start = 1, .text = "|>" },
            .{ .tag = .lower_ident, .start = 3, .text = "b" },
            .{ .tag = .lower_ident, .start = 5, .text = "a" },
            .{ .tag = .pipe, .start = 6, .text = "|" },
            .{ .tag = .op_gt, .start = 8, .text = ">" },
            .{ .tag = .lower_ident, .start = 9, .text = "b" },
            .{ .tag = .lower_ident, .start = 11, .text = "a" },
            .{ .tag = .op_slash_slash, .start = 12, .text = "//" },
            .{ .tag = .lower_ident, .start = 14, .text = "b" },
            .{ .tag = .lower_ident, .start = 16, .text = "a" },
            .{ .tag = .op_slash, .start = 17, .text = "/" },
            .{ .tag = .op_slash, .start = 19, .text = "/" },
            .{ .tag = .lower_ident, .start = 20, .text = "b" },
            .{ .tag = .lower_ident, .start = 22, .text = "a" },
            .{ .tag = .arrow, .start = 23, .text = "->" },
            .{ .tag = .lower_ident, .start = 25, .text = "b" },
            .{ .tag = .lower_ident, .start = 27, .text = "a" },
            .{ .tag = .op_minus, .start = 28, .text = "-" },
            .{ .tag = .op_gt, .start = 30, .text = ">" },
            .{ .tag = .lower_ident, .start = 31, .text = "b" },
            .{ .tag = .lower_ident, .start = 33, .text = "a" },
            .{ .tag = .op_pipe_left, .start = 34, .text = "<|" },
            .{ .tag = .lower_ident, .start = 36, .text = "b" },
            .{ .tag = .lower_ident, .start = 38, .text = "a" },
            .{ .tag = .op_lt, .start = 39, .text = "<" },
            .{ .tag = .pipe, .start = 41, .text = "|" },
            .{ .tag = .lower_ident, .start = 42, .text = "b" },
            .{ .tag = .lower_ident, .start = 44, .text = "a" },
            .{ .tag = .op_plus, .start = 45, .text = "+" },
            .{ .tag = .lower_ident, .start = 50, .line = 1, .text = "b" },
            .{ .tag = .eof, .start = 51, .line = 1, .text = "" },
        },
        .comments = &.{.{ .kind = .plain, .start = 46, .before_token = 30 }},
        .line_starts = &.{ 0, 50 },
    });
}

test "longest match: <- wins over < and -, so `x <-1` is a bind arrow (language.md §2.2)" {
    try expectLex("x <-1 y < -1", .{ .tokens = &.{
        .{ .tag = .lower_ident, .start = 0, .text = "x" },
        .{ .tag = .arrow_left, .start = 2, .text = "<-" },
        .{ .tag = .int, .start = 4, .text = "1" },
        .{ .tag = .lower_ident, .start = 6, .text = "y" },
        .{ .tag = .op_lt, .start = 8, .text = "<" },
        .{ .tag = .op_minus, .start = 10, .text = "-" },
        .{ .tag = .int, .start = 11, .text = "1" },
        .{ .tag = .eof, .start = 12, .text = "" },
    } });
}

test "a lone & is invalid_character; && is an operator" {
    try expectLex("a & b && c", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 0, .text = "a" },
            .{ .tag = .invalid, .start = 2, .text = "&" },
            .{ .tag = .lower_ident, .start = 4, .text = "b" },
            .{ .tag = .op_and_and, .start = 6, .text = "&&" },
            .{ .tag = .lower_ident, .start = 9, .text = "c" },
            .{ .tag = .eof, .start = 10, .text = "" },
        },
        .diagnostics = &.{.{ .code = .invalid_character, .start = 2, .end = 3 }},
    });
}

test "strings: every escape in one chunk" {
    try expectLex("\"\\n\\r\\t\\\\\\\"\\$\\'\\u{41}\\u{1F600}\"", .{ .tokens = &.{
        .{ .tag = .str_start, .start = 0, .text = "\"" },
        .{ .tag = .str_chunk, .start = 1, .text = "\\n\\r\\t\\\\\\\"\\$\\'\\u{41}\\u{1F600}" },
        .{ .tag = .str_end, .start = 30, .text = "\"" },
        .{ .tag = .eof, .start = 31, .text = "" },
    } });
}

test "strings: the empty string, a literal dollar, braces without a dollar" {
    try expectLex("\"\" \"cost: $5\" \"{ a }\"", .{ .tokens = &.{
        .{ .tag = .str_start, .start = 0, .text = "\"" },
        .{ .tag = .str_end, .start = 1, .text = "\"" },
        .{ .tag = .str_start, .start = 3, .text = "\"" },
        .{ .tag = .str_chunk, .start = 4, .text = "cost: $5" },
        .{ .tag = .str_end, .start = 12, .text = "\"" },
        .{ .tag = .str_start, .start = 14, .text = "\"" },
        .{ .tag = .str_chunk, .start = 15, .text = "{ a }" },
        .{ .tag = .str_end, .start = 20, .text = "\"" },
        .{ .tag = .eof, .start = 21, .text = "" },
    } });
}

test "strings: interpolation with chunks on both sides" {
    try expectLex("\"hello ${name}!\"", .{ .tokens = &.{
        .{ .tag = .str_start, .start = 0, .text = "\"" },
        .{ .tag = .str_chunk, .start = 1, .text = "hello " },
        .{ .tag = .interp_start, .start = 7, .text = "${" },
        .{ .tag = .lower_ident, .start = 9, .text = "name" },
        .{ .tag = .interp_end, .start = 13, .text = "}" },
        .{ .tag = .str_chunk, .start = 14, .text = "!" },
        .{ .tag = .str_end, .start = 15, .text = "\"" },
        .{ .tag = .eof, .start = 16, .text = "" },
    } });
}

test "strings: a string that is only an interpolation, and adjacent interpolations" {
    try expectLex("\"${a}\" \"${a}${b}\"", .{ .tokens = &.{
        .{ .tag = .str_start, .start = 0, .text = "\"" },
        .{ .tag = .interp_start, .start = 1, .text = "${" },
        .{ .tag = .lower_ident, .start = 3, .text = "a" },
        .{ .tag = .interp_end, .start = 4, .text = "}" },
        .{ .tag = .str_end, .start = 5, .text = "\"" },
        .{ .tag = .str_start, .start = 7, .text = "\"" },
        .{ .tag = .interp_start, .start = 8, .text = "${" },
        .{ .tag = .lower_ident, .start = 10, .text = "a" },
        .{ .tag = .interp_end, .start = 11, .text = "}" },
        .{ .tag = .interp_start, .start = 12, .text = "${" },
        .{ .tag = .lower_ident, .start = 14, .text = "b" },
        .{ .tag = .interp_end, .start = 15, .text = "}" },
        .{ .tag = .str_end, .start = 16, .text = "\"" },
        .{ .tag = .eof, .start = 17, .text = "" },
    } });
}

test "strings: braces nest inside an interpolation and \\$ is a literal dollar" {
    try expectLex("\"${ { a = 1 }.a }\" \"\\${x}\"", .{ .tokens = &.{
        .{ .tag = .str_start, .start = 0, .text = "\"" },
        .{ .tag = .interp_start, .start = 1, .text = "${" },
        .{ .tag = .l_brace, .start = 4, .text = "{" },
        .{ .tag = .lower_ident, .start = 6, .text = "a" },
        .{ .tag = .equal, .start = 8, .text = "=" },
        .{ .tag = .int, .start = 10, .text = "1" },
        .{ .tag = .r_brace, .start = 12, .text = "}" },
        .{ .tag = .dot_lower, .start = 13, .text = ".a" },
        .{ .tag = .interp_end, .start = 16, .text = "}" },
        .{ .tag = .str_end, .start = 17, .text = "\"" },
        .{ .tag = .str_start, .start = 19, .text = "\"" },
        .{ .tag = .str_chunk, .start = 20, .text = "\\${x}" },
        .{ .tag = .str_end, .start = 25, .text = "\"" },
        .{ .tag = .eof, .start = 26, .text = "" },
    } });
}

test "strings: a string inside an interpolation is nested_string_in_interpolation, and lexing resumes" {
    try expectLex("\"len: ${ String.length \"abc\" }\"", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .str_chunk, .start = 1, .text = "len: " },
            .{ .tag = .interp_start, .start = 6, .text = "${" },
            .{ .tag = .qualified_lower, .start = 9, .text = "String.length" },
            .{ .tag = .invalid, .start = 23, .text = "\"abc\"" },
            .{ .tag = .interp_end, .start = 29, .text = "}" },
            .{ .tag = .str_end, .start = 30, .text = "\"" },
            .{ .tag = .eof, .start = 31, .text = "" },
        },
        .diagnostics = &.{.{ .code = .nested_string_in_interpolation, .start = 23, .end = 28 }},
    });
    // A multiline marker inside an interpolation is the same error, two bytes.
    try expectLex("\"${ \\\\raw }\"", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .interp_start, .start = 1, .text = "${" },
            .{ .tag = .invalid, .start = 4, .text = "\\\\" },
            .{ .tag = .lower_ident, .start = 6, .text = "raw" },
            .{ .tag = .interp_end, .start = 10, .text = "}" },
            .{ .tag = .str_end, .start = 11, .text = "\"" },
            .{ .tag = .eof, .start = 12, .text = "" },
        },
        .diagnostics = &.{.{ .code = .nested_string_in_interpolation, .start = 4, .end = 6 }},
    });
}

test "strings: unterminated at a newline, at EOF, and inside an interpolation" {
    try expectLex("\"abc\nx", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .str_chunk, .start = 1, .text = "abc" },
            .{ .tag = .invalid, .start = 4, .text = "" },
            .{ .tag = .lower_ident, .start = 5, .line = 1, .text = "x" },
            .{ .tag = .eof, .start = 6, .line = 1, .text = "" },
        },
        .diagnostics = &.{.{ .code = .unterminated_string, .start = 0, .end = 4 }},
        .line_starts = &.{ 0, 5 },
    });
    try expectLex("\"abc", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .str_chunk, .start = 1, .text = "abc" },
            .{ .tag = .invalid, .start = 4, .text = "" },
            .{ .tag = .eof, .start = 4, .text = "" },
        },
        .diagnostics = &.{.{ .code = .unterminated_string, .start = 0, .end = 4 }},
    });
    try expectLex("\"a ${ b\r\ny", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .str_chunk, .start = 1, .text = "a " },
            .{ .tag = .interp_start, .start = 3, .text = "${" },
            .{ .tag = .lower_ident, .start = 6, .text = "b" },
            .{ .tag = .invalid, .start = 7, .text = "" },
            .{ .tag = .lower_ident, .start = 9, .line = 1, .text = "y" },
            .{ .tag = .eof, .start = 10, .line = 1, .text = "" },
        },
        .diagnostics = &.{.{ .code = .unterminated_string, .start = 0, .end = 7 }},
        .line_starts = &.{ 0, 9 },
    });
    try expectLex("\"a ${ b", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .str_chunk, .start = 1, .text = "a " },
            .{ .tag = .interp_start, .start = 3, .text = "${" },
            .{ .tag = .lower_ident, .start = 6, .text = "b" },
            .{ .tag = .invalid, .start = 7, .text = "" },
            .{ .tag = .eof, .start = 7, .text = "" },
        },
        .diagnostics = &.{.{ .code = .unterminated_string, .start = 0, .end = 7 }},
    });
    // A `"` alone (the OnlyDoubleQuote fixture).
    try expectLex("\"\n", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .invalid, .start = 1, .text = "" },
            .{ .tag = .eof, .start = 2, .line = 1, .text = "" },
        },
        .diagnostics = &.{.{ .code = .unterminated_string, .start = 0, .end = 1 }},
        .line_starts = &.{ 0, 2 },
    });
}

test "strings: invalid escapes split the chunk and are reported with their exact text" {
    try expectLex("\"a\\qb\" \"ab\\uA\" \"\\u{}\" \"\\u{110000}\" \"\\u{D800}\" \"\\u{1234567}\" \"x\\", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .str_chunk, .start = 1, .text = "a" },
            .{ .tag = .invalid, .start = 2, .text = "\\q" },
            .{ .tag = .str_chunk, .start = 4, .text = "b" },
            .{ .tag = .str_end, .start = 5, .text = "\"" },
            .{ .tag = .str_start, .start = 7, .text = "\"" },
            .{ .tag = .str_chunk, .start = 8, .text = "ab" },
            .{ .tag = .invalid, .start = 10, .text = "\\u" },
            .{ .tag = .str_chunk, .start = 12, .text = "A" },
            .{ .tag = .str_end, .start = 13, .text = "\"" },
            .{ .tag = .str_start, .start = 15, .text = "\"" },
            .{ .tag = .invalid, .start = 16, .text = "\\u{}" },
            .{ .tag = .str_end, .start = 20, .text = "\"" },
            .{ .tag = .str_start, .start = 22, .text = "\"" },
            .{ .tag = .invalid, .start = 23, .text = "\\u{110000}" },
            .{ .tag = .str_end, .start = 33, .text = "\"" },
            .{ .tag = .str_start, .start = 35, .text = "\"" },
            .{ .tag = .invalid, .start = 36, .text = "\\u{D800}" },
            .{ .tag = .str_end, .start = 44, .text = "\"" },
            .{ .tag = .str_start, .start = 46, .text = "\"" },
            .{ .tag = .invalid, .start = 47, .text = "\\u{1234567}" },
            .{ .tag = .str_end, .start = 58, .text = "\"" },
            .{ .tag = .str_start, .start = 60, .text = "\"" },
            .{ .tag = .str_chunk, .start = 61, .text = "x" },
            .{ .tag = .invalid, .start = 62, .text = "\\" },
            .{ .tag = .invalid, .start = 63, .text = "" },
            .{ .tag = .eof, .start = 63, .text = "" },
        },
        .diagnostics = &.{
            .{ .code = .invalid_escape, .start = 2, .end = 4 },
            .{ .code = .invalid_escape, .start = 10, .end = 12 },
            .{ .code = .invalid_escape, .start = 16, .end = 20 },
            .{ .code = .invalid_escape, .start = 23, .end = 33 },
            .{ .code = .invalid_escape, .start = 36, .end = 44 },
            .{ .code = .invalid_escape, .start = 47, .end = 58 },
            .{ .code = .invalid_escape, .start = 62, .end = 63 },
            .{ .code = .unterminated_string, .start = 60, .end = 63 },
        },
    });
}

test "strings: a tab or bare carriage return inside splits the chunk; the string goes on" {
    try expectLex("\"ab\tcd\" \"x\ry\"", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .str_chunk, .start = 1, .text = "ab" },
            .{ .tag = .invalid, .start = 3, .text = "\t" },
            .{ .tag = .str_chunk, .start = 4, .text = "cd" },
            .{ .tag = .str_end, .start = 6, .text = "\"" },
            .{ .tag = .str_start, .start = 8, .text = "\"" },
            .{ .tag = .str_chunk, .start = 9, .text = "x" },
            .{ .tag = .invalid, .start = 10, .text = "\r" },
            .{ .tag = .str_chunk, .start = 11, .text = "y" },
            .{ .tag = .str_end, .start = 12, .text = "\"" },
            .{ .tag = .eof, .start = 13, .text = "" },
        },
        .diagnostics = &.{
            .{ .code = .tab_in_source, .start = 3, .end = 4 },
            .{ .code = .bare_carriage_return, .start = 10, .end = 11 },
        },
    });
}

test "multiline strings: one line, several, a blank line between, `${` and `\\` inside, trailing spaces" {
    try expectLex("x =\n    \\\\one\n    \\\\two ${a} \\n\n\n    \\\\three  \n", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 0, .text = "x" },
            .{ .tag = .equal, .start = 2, .text = "=" },
            .{ .tag = .multiline_line, .start = 8, .line = 1, .text = "\\\\one" },
            .{ .tag = .multiline_line, .start = 18, .line = 2, .text = "\\\\two ${a} \\n" },
            .{ .tag = .multiline_line, .start = 37, .line = 4, .text = "\\\\three  " },
            .{ .tag = .eof, .start = 47, .line = 5, .text = "" },
        },
        .line_starts = &.{ 0, 4, 14, 32, 33, 47 },
    });
    // A bare marker is an empty line of the literal; a marker at EOF with no newline.
    try expectLex("\\\\\n\\\\end", .{
        .tokens = &.{
            .{ .tag = .multiline_line, .start = 0, .text = "\\\\" },
            .{ .tag = .multiline_line, .start = 3, .line = 1, .text = "\\\\end" },
            .{ .tag = .eof, .start = 8, .line = 1, .text = "" },
        },
        .line_starts = &.{ 0, 3 },
    });
    // With CRLF the `\r` is not part of the line.
    try expectLex("\\\\a\r\n\\\\b\r\n", .{
        .tokens = &.{
            .{ .tag = .multiline_line, .start = 0, .text = "\\\\a" },
            .{ .tag = .multiline_line, .start = 5, .line = 1, .text = "\\\\b" },
            .{ .tag = .eof, .start = 10, .line = 2, .text = "" },
        },
        .line_starts = &.{ 0, 5, 10 },
    });
}

test "multiline strings: a tab inside is reported but the line stays one token" {
    try expectLex("\\\\a\tb\n", .{
        .tokens = &.{
            .{ .tag = .multiline_line, .start = 0, .text = "\\\\a\tb" },
            .{ .tag = .eof, .start = 6, .line = 1, .text = "" },
        },
        .diagnostics = &.{.{ .code = .tab_in_source, .start = 3, .end = 4 }},
        .line_starts = &.{ 0, 6 },
    });
}

test "chars: plain, escaped, unicode, both quotes, non-ASCII" {
    try expectLex("'a' '\\n' '\\u{1F600}' '\\'' '\"' 'é' ' ' '$'", .{ .tokens = &.{
        .{ .tag = .char, .start = 0, .text = "'a'" },
        .{ .tag = .char, .start = 4, .text = "'\\n'" },
        .{ .tag = .char, .start = 9, .text = "'\\u{1F600}'" },
        .{ .tag = .char, .start = 21, .text = "'\\''" },
        .{ .tag = .char, .start = 26, .text = "'\"'" },
        .{ .tag = .char, .start = 30, .text = "'é'" },
        .{ .tag = .char, .start = 35, .text = "' '" },
        .{ .tag = .char, .start = 39, .text = "'$'" },
        .{ .tag = .eof, .start = 42, .text = "" },
    } });
}

test "chars: '' and 'ab' are invalid_char_literal; '\\z' is invalid_escape; unterminated" {
    try expectLex("'' 'ab' '\\z' 'x\ny", .{
        .tokens = &.{
            .{ .tag = .invalid, .start = 0, .text = "''" },
            .{ .tag = .invalid, .start = 3, .text = "'ab'" },
            .{ .tag = .invalid, .start = 8, .text = "'\\z'" },
            .{ .tag = .invalid, .start = 13, .text = "'x" },
            .{ .tag = .lower_ident, .start = 16, .line = 1, .text = "y" },
            .{ .tag = .eof, .start = 17, .line = 1, .text = "" },
        },
        .diagnostics = &.{
            .{ .code = .invalid_char_literal, .start = 0, .end = 2 },
            .{ .code = .invalid_char_literal, .start = 3, .end = 7 },
            .{ .code = .invalid_escape, .start = 9, .end = 11 },
            .{ .code = .invalid_char_literal, .start = 13, .end = 15 },
        },
        .line_starts = &.{ 0, 16 },
    });
}

test "comments: all three kinds, before_token, --- and --|x, trailing at EOF" {
    try expectLex("--! module\n--|doc\nx = 1 -- trailing\n--- dashes\n--|x\ny\n-- at eof", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 18, .line = 2, .text = "x" },
            .{ .tag = .equal, .start = 20, .line = 2, .text = "=" },
            .{ .tag = .int, .start = 22, .line = 2, .text = "1" },
            .{ .tag = .lower_ident, .start = 52, .line = 5, .text = "y" },
            .{ .tag = .eof, .start = 63, .line = 6, .text = "" },
        },
        .comments = &.{
            .{ .kind = .module_doc, .start = 0, .before_token = 0 },
            .{ .kind = .doc, .start = 11, .before_token = 0 },
            .{ .kind = .plain, .start = 24, .before_token = 3 },
            .{ .kind = .plain, .start = 36, .before_token = 3 },
            .{ .kind = .doc, .start = 47, .before_token = 3 },
            .{ .kind = .plain, .start = 54, .before_token = 4 },
        },
        .line_starts = &.{ 0, 11, 18, 36, 47, 52, 54 },
    });
    // `--` right at EOF and a comment inside an interpolation swallowing the line.
    try expectLex("x --", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 0, .text = "x" },
            .{ .tag = .eof, .start = 4, .text = "" },
        },
        .comments = &.{.{ .kind = .plain, .start = 2, .before_token = 1 }},
    });
}

test "CRLF: one newline per pair, no bare-CR error, the line table skips the pair" {
    try expectLex("a\r\n  b\r\n\r\nc", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 0, .text = "a" },
            .{ .tag = .lower_ident, .start = 5, .line = 1, .text = "b" },
            .{ .tag = .lower_ident, .start = 10, .line = 3, .text = "c" },
            .{ .tag = .eof, .start = 11, .line = 3, .text = "" },
        },
        .line_starts = &.{ 0, 3, 8, 10 },
    });
    // A comment on a CRLF line ends before the `\r`.
    try expectLex("-- c\r\nx", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 6, .line = 1, .text = "x" },
            .{ .tag = .eof, .start = 7, .line = 1, .text = "" },
        },
        .comments = &.{.{ .kind = .plain, .start = 0, .before_token = 0 }},
        .line_starts = &.{ 0, 6 },
    });
}

test "bare carriage return: outside a string, inside a comment, at EOF" {
    try expectLex("x =\r1\n-- a\rb\n\r", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 0, .text = "x" },
            .{ .tag = .equal, .start = 2, .text = "=" },
            .{ .tag = .invalid, .start = 3, .text = "\r" },
            .{ .tag = .int, .start = 4, .text = "1" },
            .{ .tag = .invalid, .start = 13, .line = 2, .text = "\r" },
            .{ .tag = .eof, .start = 14, .line = 2, .text = "" },
        },
        .comments = &.{.{ .kind = .plain, .start = 6, .before_token = 4 }},
        .diagnostics = &.{
            .{ .code = .bare_carriage_return, .start = 3, .end = 4 },
            .{ .code = .bare_carriage_return, .start = 10, .end = 11 },
            .{ .code = .bare_carriage_return, .start = 13, .end = 14 },
        },
        .line_starts = &.{ 0, 6, 13 },
    });
}

test "tab: as indentation, between tokens, inside a comment" {
    try expectLex("x =\n\t1 +\t2 --\tc", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 0, .text = "x" },
            .{ .tag = .equal, .start = 2, .text = "=" },
            .{ .tag = .invalid, .start = 4, .line = 1, .text = "\t" },
            .{ .tag = .int, .start = 5, .line = 1, .text = "1" },
            .{ .tag = .op_plus, .start = 7, .line = 1, .text = "+" },
            .{ .tag = .invalid, .start = 8, .line = 1, .text = "\t" },
            .{ .tag = .int, .start = 9, .line = 1, .text = "2" },
            .{ .tag = .eof, .start = 15, .line = 1, .text = "" },
        },
        .comments = &.{.{ .kind = .plain, .start = 11, .before_token = 7 }},
        .diagnostics = &.{
            .{ .code = .tab_in_source, .start = 4, .end = 5 },
            .{ .code = .tab_in_source, .start = 8, .end = 9 },
            .{ .code = .tab_in_source, .start = 13, .end = 14 },
        },
        .line_starts = &.{ 0, 4 },
    });
}

test "non-ASCII outside a string is invalid_character covering the whole character; control bytes too" {
    try expectLex("x = é + \x01 + \x7f", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 0, .text = "x" },
            .{ .tag = .equal, .start = 2, .text = "=" },
            .{ .tag = .invalid, .start = 4, .text = "é" },
            .{ .tag = .op_plus, .start = 7, .text = "+" },
            .{ .tag = .invalid, .start = 9, .text = "\x01" },
            .{ .tag = .op_plus, .start = 11, .text = "+" },
            .{ .tag = .invalid, .start = 13, .text = "\x7f" },
            .{ .tag = .eof, .start = 14, .text = "" },
        },
        .diagnostics = &.{
            .{ .code = .invalid_character, .start = 4, .end = 6 },
            .{ .code = .invalid_character, .start = 9, .end = 10 },
            .{ .code = .invalid_character, .start = 13, .end = 14 },
        },
    });
}

test "valid multi-byte UTF-8 inside a string, a char and a comment is fine" {
    try expectLex("\"café — naïve 😀\" '—' -- ∀x", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .str_chunk, .start = 1, .text = "café — naïve 😀" },
            .{ .tag = .str_end, .start = 22, .text = "\"" },
            .{ .tag = .char, .start = 24, .text = "'—'" },
            .{ .tag = .eof, .start = 37, .text = "" },
        },
        .comments = &.{.{ .kind = .plain, .start = 30, .before_token = 4 }},
    });
}

test "invalid UTF-8: inside a string (split), in a comment (reported), outside (invalid_utf8), truncated at EOF" {
    try expectLex("\"ab\xffcd\" -- \xc3 x\n\xe2\x82 y \xc3", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .str_chunk, .start = 1, .text = "ab" },
            .{ .tag = .invalid, .start = 3, .text = "\xff" },
            .{ .tag = .str_chunk, .start = 4, .text = "cd" },
            .{ .tag = .str_end, .start = 6, .text = "\"" },
            .{ .tag = .invalid, .start = 15, .line = 1, .text = "\xe2\x82" },
            .{ .tag = .lower_ident, .start = 18, .line = 1, .text = "y" },
            .{ .tag = .invalid, .start = 20, .line = 1, .text = "\xc3" },
            .{ .tag = .eof, .start = 21, .line = 1, .text = "" },
        },
        .comments = &.{.{ .kind = .plain, .start = 8, .before_token = 5 }},
        .diagnostics = &.{
            .{ .code = .invalid_utf8, .start = 3, .end = 4 },
            .{ .code = .invalid_utf8, .start = 11, .end = 12 },
            .{ .code = .invalid_utf8, .start = 15, .end = 17 },
            .{ .code = .invalid_utf8, .start = 20, .end = 21 },
        },
        .line_starts = &.{ 0, 15 },
    });
    // Overlong and surrogate encodings are invalid even when structurally complete.
    try expectLex("\"\xc0\x80\" \"\xed\xa0\x80\"", .{
        .tokens = &.{
            .{ .tag = .str_start, .start = 0, .text = "\"" },
            .{ .tag = .invalid, .start = 1, .text = "\xc0\x80" },
            .{ .tag = .str_end, .start = 3, .text = "\"" },
            .{ .tag = .str_start, .start = 5, .text = "\"" },
            .{ .tag = .invalid, .start = 6, .text = "\xed\xa0\x80" },
            .{ .tag = .str_end, .start = 9, .text = "\"" },
            .{ .tag = .eof, .start = 10, .text = "" },
        },
        .diagnostics = &.{
            .{ .code = .invalid_utf8, .start = 1, .end = 3 },
            .{ .code = .invalid_utf8, .start = 6, .end = 9 },
        },
    });
}

test "a NUL byte inside the file is invalid_character, not the end" {
    try expectLex("a\x00b \"c\x00d\"", .{
        .tokens = &.{
            .{ .tag = .lower_ident, .start = 0, .text = "a" },
            .{ .tag = .invalid, .start = 1, .text = "\x00" },
            .{ .tag = .lower_ident, .start = 2, .text = "b" },
            .{ .tag = .str_start, .start = 4, .text = "\"" },
            .{ .tag = .str_chunk, .start = 5, .text = "c" },
            .{ .tag = .invalid, .start = 6, .text = "\x00" },
            .{ .tag = .str_chunk, .start = 7, .text = "d" },
            .{ .tag = .str_end, .start = 8, .text = "\"" },
            .{ .tag = .eof, .start = 9, .text = "" },
        },
        .diagnostics = &.{
            .{ .code = .invalid_character, .start = 1, .end = 2 },
            .{ .code = .invalid_character, .start = 6, .end = 7 },
        },
    });
}

test "the line column and the line table across many lines, with blank lines and comments" {
    const source =
        \\import Dict
        \\
        \\
        \\view model =
        \\    -- pick
        \\    case model of
        \\        Home ->
        \\            1
    ;
    try expectLex(source, .{
        .tokens = &.{
            .{ .tag = .keyword_import, .start = 0, .line = 0, .text = "import" },
            .{ .tag = .upper_ident, .start = 7, .line = 0, .text = "Dict" },
            .{ .tag = .lower_ident, .start = 14, .line = 3, .text = "view" },
            .{ .tag = .lower_ident, .start = 19, .line = 3, .text = "model" },
            .{ .tag = .equal, .start = 25, .line = 3, .text = "=" },
            .{ .tag = .keyword_case, .start = 43, .line = 5, .text = "case" },
            .{ .tag = .lower_ident, .start = 48, .line = 5, .text = "model" },
            .{ .tag = .keyword_of, .start = 54, .line = 5, .text = "of" },
            .{ .tag = .upper_ident, .start = 65, .line = 6, .text = "Home" },
            .{ .tag = .arrow, .start = 70, .line = 6, .text = "->" },
            .{ .tag = .int, .start = 85, .line = 7, .text = "1" },
            .{ .tag = .eof, .start = 86, .line = 7, .text = "" },
        },
        .comments = &.{.{ .kind = .plain, .start = 31, .before_token = 5 }},
        .line_starts = &.{ 0, 12, 13, 14, 27, 39, 57, 73 },
    });
}

test "next is idempotent past the end and the eof token is appended once" {
    var interner: InternPool.Local = .empty;
    defer interner.deinit(testing.allocator);
    var out: Output = .empty;
    defer out.deinit(testing.allocator);
    try out.line_starts.append(testing.allocator, 0);
    var t: Tokenizer = .{ .source = "x", .gpa = testing.allocator, .interner = &interner, .out = &out };
    try testing.expectEqual(Tag.lower_ident, try t.next());
    try testing.expectEqual(Tag.eof, try t.next());
    try testing.expectEqual(Tag.eof, try t.next());
    try testing.expectEqual(@as(usize, 2), out.tokens.len);
}

test "markup: `<` at the start of the file opens markup; `<` then a digit or space never does" {
    try expectLex("<b/>", .{ .tokens = &.{
        .{ .tag = .markup_open, .start = 0, .text = "<" },
        .{ .tag = .markup_name, .start = 1, .text = "b" },
        .{ .tag = .markup_self_close, .start = 2, .text = "/>" },
        .{ .tag = .eof, .start = 4, .text = "" },
    } });
    try expectLex("= <1 = < b", .{ .tokens = &.{
        .{ .tag = .equal, .start = 0, .text = "=" },
        .{ .tag = .op_lt, .start = 2, .text = "<" },
        .{ .tag = .int, .start = 3, .text = "1" },
        .{ .tag = .equal, .start = 5, .text = "=" },
        .{ .tag = .op_lt, .start = 7, .text = "<" },
        .{ .tag = .lower_ident, .start = 9, .text = "b" },
        .{ .tag = .eof, .start = 10, .text = "" },
    } });
}

test "markup: a comparison after an invalid token stays a comparison" {
    // Conservatively: the `invalid` might have been an operand (§9.3).
    try expectLex("@ <b", .{
        .tokens = &.{
            .{ .tag = .invalid, .start = 0, .text = "@" },
            .{ .tag = .op_lt, .start = 2, .text = "<" },
            .{ .tag = .lower_ident, .start = 3, .text = "b" },
            .{ .tag = .eof, .start = 4, .text = "" },
        },
        .diagnostics = &.{.{ .code = .invalid_character, .start = 0, .end = 1 }},
    });
}

test "markup: CRLF inside a tag and inside text, and a text run's line is its first" {
    try expectLex("=<a\r\n b>x\r\n y</a>", .{
        .tokens = &.{
            .{ .tag = .equal, .start = 0, .text = "=" },
            .{ .tag = .markup_open, .start = 1, .text = "<" },
            .{ .tag = .markup_name, .start = 2, .text = "a" },
            .{ .tag = .markup_attr, .start = 6, .line = 1, .text = "b" },
            .{ .tag = .markup_gt, .start = 7, .line = 1, .text = ">" },
            .{ .tag = .markup_text, .start = 8, .line = 1, .text = "x\r\n y" },
            .{ .tag = .markup_close_open, .start = 13, .line = 2, .text = "</" },
            .{ .tag = .markup_name, .start = 15, .line = 2, .text = "a" },
            .{ .tag = .markup_gt, .start = 16, .line = 2, .text = ">" },
            .{ .tag = .eof, .start = 17, .line = 2, .text = "" },
        },
        .line_starts = &.{ 0, 5, 11 },
    });
}

test "markup: errors inside text are reported and the run stays one token" {
    // A tab, a control byte, malformed UTF-8 and a bare `\r` (§11.4); a
    // `<` at the end of the file is the stray `<`.
    try expectLex("=<p>a\tb\x01c\xffd\re<", .{
        .tokens = &.{
            .{ .tag = .equal, .start = 0, .text = "=" },
            .{ .tag = .markup_open, .start = 1, .text = "<" },
            .{ .tag = .markup_name, .start = 2, .text = "p" },
            .{ .tag = .markup_gt, .start = 3, .text = ">" },
            .{ .tag = .markup_text, .start = 4, .text = "a\tb\x01c\xffd\re" },
            .{ .tag = .invalid, .start = 13, .text = "<" },
            .{ .tag = .eof, .start = 14, .text = "" },
        },
        .diagnostics = &.{
            .{ .code = .tab_in_source, .start = 5, .end = 6 },
            .{ .code = .invalid_character, .start = 7, .end = 8 },
            .{ .code = .invalid_utf8, .start = 9, .end = 10 },
            .{ .code = .bare_carriage_return, .start = 11, .end = 12 },
            .{ .code = .unexpected_token, .start = 13, .end = 14 },
        },
    });
}

test "markup: a blank line and an indented line do not end markup; column 1 does, from a tag" {
    try expectLex("=<p>\n\n x</p>", .{
        .tokens = &.{
            .{ .tag = .equal, .start = 0, .text = "=" },
            .{ .tag = .markup_open, .start = 1, .text = "<" },
            .{ .tag = .markup_name, .start = 2, .text = "p" },
            .{ .tag = .markup_gt, .start = 3, .text = ">" },
            .{ .tag = .markup_text, .start = 4, .text = "\n\n x" },
            .{ .tag = .markup_close_open, .start = 8, .line = 2, .text = "</" },
            .{ .tag = .markup_name, .start = 10, .line = 2, .text = "p" },
            .{ .tag = .markup_gt, .start = 11, .line = 2, .text = ">" },
            .{ .tag = .eof, .start = 12, .line = 2, .text = "" },
        },
        .line_starts = &.{ 0, 5, 6 },
    });
    // An opening tag cut off by a column-1 declaration: `x` is an ordinary
    // name again, and its `<b` a comparison.
    try expectLex("=<a\nx <b", .{
        .tokens = &.{
            .{ .tag = .equal, .start = 0, .text = "=" },
            .{ .tag = .markup_open, .start = 1, .text = "<" },
            .{ .tag = .markup_name, .start = 2, .text = "a" },
            .{ .tag = .lower_ident, .start = 4, .line = 1, .text = "x" },
            .{ .tag = .op_lt, .start = 6, .line = 1, .text = "<" },
            .{ .tag = .lower_ident, .start = 7, .line = 1, .text = "b" },
            .{ .tag = .eof, .start = 8, .line = 1, .text = "" },
        },
        .line_starts = &.{ 0, 4 },
    });
}

/// `=` then `n` opening tags, one after another: the stack then holds the
/// bottom entry and one `children` per tag, and the `n`th tag's `<` asks
/// for entry `n + 1`.
fn nestedTags(n: usize) ![:0]u8 {
    const text = try testing.allocator.allocSentinel(u8, 1 + 3 * n, 0);
    text[0] = '=';
    for (0..n) |i| @memcpy(text[1 + 3 * i ..][0..3], "<a>");
    return text;
}

test "markup: the mode stack holds 4096 entries, and one more is nesting_too_deep once" {
    var interner: InternPool.Local = .empty;
    defer interner.deinit(testing.allocator);

    // 4095 tags: the stack is exactly full, and nothing is reported.
    const full = try nestedTags(max_stack - 1);
    defer testing.allocator.free(full);
    var out: Output = .empty;
    defer out.deinit(testing.allocator);
    try tokenize(testing.allocator, full, &interner, &out);
    try testing.expectEqual(@as(usize, 0), out.diagnostics.items().len);

    // Two past it: one report, at the first `<` that did not fit, and every
    // tag still lexed as a tag.
    const over = try nestedTags(max_stack + 1);
    defer testing.allocator.free(over);
    var out_over: Output = .empty;
    defer out_over.deinit(testing.allocator);
    try tokenize(testing.allocator, over, &interner, &out_over);
    const at: u32 = 1 + 3 * (max_stack - 1);
    try testing.expectEqualSlices(Diagnostics.Item, &.{.{ .code = .nesting_too_deep, .start = at, .end = at + 1 }}, out_over.diagnostics.items());
    try testing.expectEqual(@as(usize, 1 + 3 * (max_stack + 1) + 1), out_over.tokens.len);
    try testing.expectEqual(Tag.markup_open, out_over.tokens.items(.tag)[out_over.tokens.len - 4]);
}

test "markup: closing more than was opened past the bound never underflows the stack" {
    // Past the bound the top was replaced rather than pushed, so the
    // closers below outnumber what the stack holds; each pops at most to
    // the bottom `normal` entry, and the rest is ordinary code.
    const over = try nestedTags(max_stack + 1);
    defer testing.allocator.free(over);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, over);
    for (0..max_stack + 2) |_| try source.appendSlice(testing.allocator, "</a>");
    try source.appendSlice(testing.allocator, " x <b");
    try source.append(testing.allocator, 0);
    try checkArbitrary(source.items[0 .. source.items.len - 1 :0]);
}

test "slice agrees with lexeme for every fixed-spelling tag" {
    inline for (@typeInfo(Tag).@"enum".fields) |field| {
        const tag: Tag = @enumFromInt(field.value);
        if (Token.lexeme(tag)) |text| {
            var buf: [32:0]u8 = undefined;
            const padded = try std.fmt.bufPrintZ(&buf, "  {s} rest", .{text});
            try testing.expectEqualStrings(text, slice(padded, tag, 2));
        }
    }
}

/// The alphabet of the property test: pieces that are each a well-formed
/// token, comment or whitespace, so the whole input is valid and the
/// invariants below must hold exactly.
const pieces = [_][]const u8{
    "foo",       "fooBar",               "_x",           "Foo",     "Json.Decode.string", "Maybe.Just",
    ".field",    ".0",                   ".12",          "42",      "0x1F",               "1.5",
    "1e10",      "1.5e-3",               "\"\"",         "\"a b\"", "\"${x}\"",           "\"a ${ { r | a = 1 }.a } b\"",
    "'a'",       "'\\n'",                "'\\u{1F600}'", "if",      "then",               "else",
    "case",      "of",                   "let",          "in",      "type",               "alias",
    "pub",       "(",                    ")",            "[",       "]",                  "{",
    "}",         ",",                    ":",            "=",       "->",                 "\\",
    "|",         "_",                    "?",            "+",       "-",                  "*",
    "/",         "//",                   "^",            "++",      "::",                 "==",
    "/=",        "<",                    ">",            "<=",      ">=",                 "&&",
    "||",        "|>",                   "<|",           "<-",      "x <-1",              " ",
    "  ",        "\n",                   "\r\n",         "\n\n",    "-- comment\n",       "--| doc\n",
    "--! mod\n", "\\\\raw ${ \\ line\n",
    "\"é\"",
    "'é'",
    "-- ∀\n",
};

test "property: on valid input, tokens are ordered, non-empty, on non-decreasing lines, and cover the source with comments and whitespace" {
    var prng: std.Random.DefaultPrng = .init(0x1e8);
    const random = prng.random();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    var covered: std.ArrayList(u8) = .empty;
    defer covered.deinit(testing.allocator);

    for (0..300) |_| {
        source.clearRetainingCapacity();
        const count = random.intRangeAtMost(usize, 0, 40);
        for (0..count) |_| {
            try source.appendSlice(testing.allocator, pieces[random.uintLessThan(usize, pieces.len)]);
            // Separate pieces so identifiers and numbers do not fuse.
            try source.append(testing.allocator, ' ');
        }
        try source.append(testing.allocator, 0);
        const text: [:0]const u8 = source.items[0 .. source.items.len - 1 :0];

        var interner: InternPool.Local = .empty;
        defer interner.deinit(testing.allocator);
        var out: Output = .empty;
        defer out.deinit(testing.allocator);
        try tokenize(testing.allocator, text, &interner, &out);
        try testing.expectEqual(@as(usize, 0), out.diagnostics.items().len);

        covered.clearRetainingCapacity();
        try covered.appendNTimes(testing.allocator, 0, text.len);
        const s = out.tokens.slice();
        var previous_start: u32 = 0;
        var previous_line: u32 = 0;
        for (s.items(.tag), s.items(.start), s.items(.line), 0..) |tag, start, line, i| {
            if (i != 0) try testing.expect(start > previous_start or (tag == .eof and start == previous_start));
            try testing.expect(line >= previous_line);
            try testing.expect(start <= text.len);
            // `line` is the line `start` is on: at or after its start, before the next.
            try testing.expect(start >= out.line_starts.items[line]);
            try testing.expect(line + 1 == out.line_starts.items.len or out.line_starts.items[line + 1] > start);
            const bytes = slice(text, tag, start);
            if (tag == .eof) {
                try testing.expectEqual(@as(usize, 0), bytes.len);
            } else {
                try testing.expect(bytes.len > 0);
            }
            for (covered.items[start .. start + bytes.len]) |*c| {
                try testing.expectEqual(@as(u8, 0), c.*); // no overlap
                c.* = 1;
            }
            previous_start = start;
            previous_line = line;
        }
        try testing.expectEqual(Tag.eof, s.items(.tag)[s.len - 1]);
        for (out.comments.items) |comment| {
            try testing.expect(comment.before_token < out.tokens.len);
            const end = lineEnd(text, comment.start);
            for (covered.items[comment.start..end]) |*c| {
                try testing.expectEqual(@as(u8, 0), c.*);
                c.* = 1;
            }
        }
        for (covered.items, text) |c, byte| {
            if (c == 0) try testing.expect(byte == ' ' or byte == '\n' or byte == '\r');
        }
        // The line table is exactly the newlines.
        var expected_lines: usize = 1;
        for (text) |byte| {
            if (byte == '\n') expected_lines += 1;
        }
        try testing.expectEqual(expected_lines, out.line_starts.items.len);
    }
}

/// The contract every input must meet, whatever its bytes: no panic, one
/// `eof` at the end, every token and diagnostic inside the source, every
/// comment before a real token. Shared by the fuzz and stress tests.
fn checkArbitrary(source: [:0]const u8) !void {
    var interner: InternPool.Local = .empty;
    defer interner.deinit(testing.allocator);
    var out: Output = .empty;
    defer out.deinit(testing.allocator);
    try tokenize(testing.allocator, source, &interner, &out);

    const s = out.tokens.slice();
    try testing.expect(s.len > 0);
    try testing.expectEqual(Tag.eof, s.items(.tag)[s.len - 1]);
    var previous_end: u32 = 0;
    for (s.items(.tag), s.items(.start), s.items(.line)) |tag, start, line| {
        try testing.expect(start <= source.len);
        try testing.expect(line < out.line_starts.items.len);
        // `line` is the line the token starts on.
        try testing.expect(start >= out.line_starts.items[line]);
        const end = tokenEnd(source, tag, start);
        try testing.expect(end >= start and end <= source.len);
        // Re-derived ends never overlap the next token.
        try testing.expect(start >= previous_end);
        previous_end = end;
    }
    for (out.diagnostics.items()) |d| {
        try testing.expect(d.start <= d.end and d.end <= source.len);
    }
    for (out.comments.items) |c| {
        try testing.expect(c.start < source.len and c.before_token < s.len);
    }
}

test "fuzz: arbitrary bytes never panic, always end in eof, and every token slice stays inside the source" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.sliceWithHash(buf[0 .. buf.len - 1], 0xB3A17);
            buf[len] = 0;
            try checkArbitrary(buf[0..len :0]);
        }
    }.testOne, .{ .corpus = &.{
        "x = \"a ${ b\n",
        "'\\u{",
        "\"\\u{FFFFFFF}",
        "\\\\\r",
        "0x",
        "\"${ \"${ } \" }\"",
        "-- \xff\xfe\n\xc3",
        "a.\x00.b",
        "=<a b=\"${ x }\" {...c}>t < {<i/>}</a >",
        "=<a -- c }\n\t<",
        "=<>{\"\n",
        "=<a>\n}",
    } });
}

test "every scan that could run past the end of the file stops at it" {
    // One input per check that stops a scan at the sentinel, each ending
    // where that scan is: a string, and the chunk inside it; a string
    // nested in an interpolation, bare and after a backslash; a character
    // literal; an escape, and a `\u{` with no `}`; and a UTF-8 lead byte
    // whose continuation bytes are missing. Without its check, each reads
    // past the source or ends a token beyond it.
    for ([_][:0]const u8{
        "\"abc",
        "\"${ \"",
        "\"${ \"\\",
        "'a",
        "\"\\",
        "\"\\u{",
        "\xf0",
    }) |source| try checkArbitrary(source);
}

/// Pieces that drive the markup modes: openers, closers, names, attributes,
/// holes, a spread, text, and the column-1 break. Not in `pieces`, whose
/// mixes must lex clean; text and tags mixed at random need not.
const markup_pieces = [_][]const u8{
    "= <",  "(<",  "<a",   "<Ui.Card", "<>",    "</",  "</a>", ">",     "/>", " a-b:c",
    "=",    "\"",  "{",    "}",        "{...x", "...", "text", "a < b", "\n", "\nx",
    "-- c", "<-a", "${ <", "'x'",      "12",
};

/// Bytes that steer the state machine: string and interpolation delimiters,
/// escapes, dots, dashes, line terminators, a tab, NUL, and UTF-8 lead and
/// continuation bytes.
const steering_bytes = "\"\\$${}'-.0123456789eExu+-/|<>=:&_ \n\r\t\x00\x7f\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80\xff\xc0\xed\xa0";

// The toolchain's fuzz mode is not available on 0.16.0 (its test runner
// does not compile with `-ffuzz`), so this is the stand-in: PRNG-driven
// inputs mixing valid pieces, steering bytes and noise. Opt-in (`zig build
// fuzz`, `fuzzing.zig`); the gates run the corpus above, one input per
// check. `BENI_STRESS_ITERATIONS` raises the count for a long run.
test "stress: random mixes of valid pieces, steering bytes and noise never panic" {
    try fuzzing.skipUnlessFuzzing();
    var iterations: usize = 3000;
    if (testing.environ.getAlloc(testing.allocator, "BENI_STRESS_ITERATIONS")) |value| {
        defer testing.allocator.free(value);
        iterations = std.fmt.parseInt(usize, value, 10) catch iterations;
    } else |_| {}

    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var buf: [1025]u8 = undefined;
    for (0..iterations) |_| {
        const len = random.intRangeAtMost(usize, 0, buf.len - 1);
        var i: usize = 0;
        while (i < len) {
            switch (random.uintLessThan(u8, 4)) {
                0 => {
                    const piece = if (random.boolean())
                        pieces[random.uintLessThan(usize, pieces.len)]
                    else
                        markup_pieces[random.uintLessThan(usize, markup_pieces.len)];
                    const n = @min(piece.len, len - i);
                    @memcpy(buf[i..][0..n], piece[0..n]);
                    i += n;
                },
                1, 2 => {
                    buf[i] = steering_bytes[random.uintLessThan(usize, steering_bytes.len)];
                    i += 1;
                },
                else => {
                    buf[i] = random.int(u8);
                    i += 1;
                },
            }
        }
        buf[len] = 0;
        try checkArbitrary(buf[0..len :0]);
    }
}
