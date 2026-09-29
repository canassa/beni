//! Compact copies of hand-written JavaScript under `--release`
//! (`backend.md` §9, *Hand-written JavaScript under `--release`*): a
//! platform's runtime, its markup runtime and every `foreign` sibling, which
//! a development build copies byte for byte.
//!
//! Two passes, both over one token list and neither a parser:
//!
//!  1. **Elimination** (`shake`): the file's top-level statements are cut
//!     into units — an `import`, a declaration, a function, an `export`
//!     list — and a unit survives iff it is a root or a surviving unit names
//!     a binding it declares. A root is an `import`, a unit that exports a
//!     name the build imports, and any unit whose evaluation this file
//!     cannot prove free of effects. References are every identifier token
//!     that is not a property name, with no scope analysis: a local that
//!     shadows a top-level name keeps that name alive, which is the safe
//!     direction.
//!  2. **Compaction** (`print`): the surviving tokens, verbatim, with the
//!     gaps between them rewritten to nothing, one space or one newline.
//!     A gap keeps a newline wherever it held a line terminator (a comment
//!     that spans lines included) unless the tokens on either side prove it
//!     cannot be a place automatic semicolon insertion acts
//!     (`newlineIsInert`); it keeps a space wherever the two tokens would
//!     otherwise lex as something else (`needsSpace`).
//!
//! **What this is not allowed to do is change a program**, so every
//! question the token list cannot answer exactly is a refusal, not a guess:
//! `tokenize` returns `error.Unsupported` for a `/` whose reading as a
//! regular expression or a division depends on more than the token before
//! it, for non-ASCII outside a literal or a comment, for an escaped
//! identifier and for anything unbalanced; `shake` returns null for a
//! top-level statement it cannot delimit, for a declaration a newline might
//! end, and for a file that mentions `eval`. A refusal costs bytes and
//! nothing else: the caller copies the file as a development build does.
//! None of the files in `core/` or `platforms/` is refused.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    ident,
    number,
    string,
    /// A template literal with no substitution, `` `abc` ``.
    template,
    /// `` `abc${ ``, `}abc${` and `` }abc` ``: a template literal with
    /// substitutions is these around the substitutions' own tokens.
    template_head,
    template_middle,
    template_tail,
    regex,
    punct,
};

pub const Token = struct {
    kind: Kind,
    start: u32,
    end: u32,
    /// A line terminator in the gap before this token — in whitespace, or
    /// inside a block comment, which ECMAScript counts as one.
    nl: bool,
    /// On a `)`: its `(` opened the head of an `if`, `while`, `for` or
    /// `with`, so a `/` after it begins a regular expression.
    head: bool = false,

    pub fn text(t: Token, source: []const u8) []const u8 {
        return source[t.start..t.end];
    }
};

pub const Error = Allocator.Error || error{Unsupported};

/// The whole pipeline: `source` compacted, with only the top-level units
/// that `keep`'s exports reach when `keep` is given. Null when the file is
/// refused and must be copied as it is.
pub fn minify(arena: Allocator, source: []const u8, keep: ?[]const []const u8) Allocator.Error!?[]const u8 {
    const tokens = tokenize(arena, source) catch |err| switch (err) {
        error.Unsupported => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const mask = if (keep) |names| try shake(arena, source, tokens, names) else null;
    const out = try print(arena, source, tokens, mask);
    if (std.debug.runtime_safety) try verify(arena, source, tokens, mask, out);
    return out;
}

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

const Open = enum { brace, template, paren, head_paren, bracket };

pub fn tokenize(arena: Allocator, source: []const u8) Error![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    var stack: std.ArrayList(Open) = .empty;
    var i: usize = 0;
    var nl = false;
    while (true) {
        // Trivia: whitespace and comments.
        while (i < source.len) {
            const c = source[i];
            if (c == ' ' or c == '\t' or c == 0x0b or c == 0x0c) {
                i += 1;
            } else if (c == '\n' or c == '\r') {
                nl = true;
                i += 1;
            } else if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                i += 2;
                while (i < source.len and source[i] != '\n' and source[i] != '\r') : (i += 1) {
                    // U+2028/U+2029 end a line comment; the rest of that
                    // line is code this loop would have skipped.
                    if (isLineSeparator(source, i)) return error.Unsupported;
                }
            } else if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
                const close = std.mem.indexOfPos(u8, source, i + 2, "*/") orelse return error.Unsupported;
                for (i + 2..close) |at| {
                    if (source[at] == '\n' or source[at] == '\r' or isLineSeparator(source, at)) nl = true;
                }
                i = close + 2;
            } else break;
        }
        if (i >= source.len) break;

        const start = i;
        const c = source[i];
        var kind: Kind = .punct;
        var head = false;
        if (c >= 0x80 or c == '\\') return error.Unsupported;
        if (c == '#' and i + 1 < source.len and source[i + 1] == '!') return error.Unsupported; // a hashbang
        if (c == '"' or c == '\'') {
            kind = .string;
            i += 1;
            while (true) {
                if (i >= source.len) return error.Unsupported;
                const ch = source[i];
                if (ch == c) {
                    i += 1;
                    break;
                }
                if (ch == '\\') {
                    i += if (i + 2 < source.len and source[i + 1] == '\r' and source[i + 2] == '\n') 3 else 2;
                    continue;
                }
                if (ch == '\n' or ch == '\r') return error.Unsupported;
                i += 1;
            }
        } else if (c == '`') {
            const opens = try scanTemplate(source, &i, start + 1);
            kind = if (opens) .template_head else .template;
            if (opens) try stack.append(arena, .template);
        } else if (c == '}' and stack.items.len != 0 and stack.items[stack.items.len - 1] == .template) {
            _ = stack.pop();
            const opens = try scanTemplate(source, &i, start + 1);
            kind = if (opens) .template_middle else .template_tail;
            if (opens) try stack.append(arena, .template);
        } else if (isDigit(c) or (c == '.' and i + 1 < source.len and isDigit(source[i + 1]))) {
            kind = .number;
            const hex = c == '0' and i + 1 < source.len and (source[i + 1] | 0x20) == 'x';
            i += 1;
            while (i < source.len) {
                const ch = source[i];
                if (isIdentPart(ch) or ch == '.') {
                    i += 1;
                } else if ((ch == '+' or ch == '-') and !hex and (source[i - 1] | 0x20) == 'e') {
                    i += 1;
                } else break;
            }
            if (i < source.len and (source[i] == '\\' or source[i] >= 0x80)) return error.Unsupported;
        } else if (isIdentStart(c) or (c == '#' and i + 1 < source.len and isIdentStart(source[i + 1]))) {
            kind = .ident;
            i += 1;
            while (i < source.len and isIdentPart(source[i])) i += 1;
            if (i < source.len and (source[i] == '\\' or source[i] >= 0x80)) return error.Unsupported;
        } else if (c == '/' and try slashIsRegex(source, tokens.items)) {
            kind = .regex;
            i += 1;
            var in_class = false;
            while (true) {
                if (i >= source.len) return error.Unsupported;
                const ch = source[i];
                if (ch == '\n' or ch == '\r' or isLineSeparator(source, i)) return error.Unsupported;
                if (ch == '\\') {
                    if (i + 1 >= source.len or source[i + 1] == '\n' or source[i + 1] == '\r') return error.Unsupported;
                    i += 2;
                    continue;
                }
                i += 1;
                if (ch == '[') in_class = true;
                if (ch == ']') in_class = false;
                if (ch == '/' and !in_class) break;
            }
            while (i < source.len and isIdentPart(source[i])) i += 1;
        } else {
            const len = punctLen(source[i..]);
            if (len == 0) return error.Unsupported;
            i += len;
            switch (c) {
                '{' => try stack.append(arena, .brace),
                '[' => try stack.append(arena, .bracket),
                '(' => try stack.append(arena, if (opensHead(source, tokens.items)) .head_paren else .paren),
                '}', ']', ')' => {
                    const top = stack.pop() orelse return error.Unsupported;
                    const want: Open = switch (c) {
                        '}' => .brace,
                        ']' => .bracket,
                        else => if (top == .head_paren) .head_paren else .paren,
                    };
                    if (top != want) return error.Unsupported;
                    head = top == .head_paren;
                },
                else => {},
            }
        }
        try tokens.append(arena, .{ .kind = kind, .start = @intCast(start), .end = @intCast(i), .nl = nl, .head = head });
        nl = false;
    }
    if (stack.items.len != 0) return error.Unsupported;
    return tokens.items;
}

/// Scan a template literal's text from `from`, past its closing `` ` `` or
/// the `${` that opens a substitution. True for the second.
fn scanTemplate(source: []const u8, i: *usize, from: usize) error{Unsupported}!bool {
    var at = from;
    while (true) {
        if (at >= source.len) return error.Unsupported;
        switch (source[at]) {
            '\\' => at += 2,
            '`' => {
                i.* = at + 1;
                return false;
            },
            '$' => if (at + 1 < source.len and source[at + 1] == '{') {
                i.* = at + 2;
                return true;
            } else {
                at += 1;
            },
            else => at += 1,
        }
    }
}

fn isLineSeparator(source: []const u8, i: usize) bool {
    return i + 2 < source.len and source[i] == 0xe2 and source[i + 1] == 0x80 and (source[i + 2] == 0xa8 or source[i + 2] == 0xa9);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

const puncts = [_][]const u8{
    ">>>=", "===", "!==", "**=", "<<=", ">>=", ">>>", "...", "&&=", "||=", "??=",
    "=>",   "==",  "!=",  "<=",  ">=",  "&&",  "||",  "??",  "?.",  "++",  "--",
    "+=",   "-=",  "*=",  "/=",  "%=",  "&=",  "|=",  "^=",  "**",  "<<",  ">>",
};

/// The length of the punctuator `text` begins with, longest match first as
/// ECMAScript lexes; 0 for a byte that begins none.
fn punctLen(text: []const u8) usize {
    for (puncts) |p| {
        if (!std.mem.startsWith(u8, text, p)) continue;
        // `?.` is optional chaining only when no digit follows: `a?.5:1`
        // is a conditional.
        if (std.mem.eql(u8, p, "?.") and text.len > 2 and isDigit(text[2])) continue;
        return p.len;
    }
    if (text.len == 0) return 0;
    return if (std.mem.indexOfScalar(u8, "{}()[];,<>+-*/%&|^!~?:=.@", text[0]) != null) 1 else 0;
}

fn isWord(t: Token, source: []const u8, word: []const u8) bool {
    return t.kind == .ident and std.mem.eql(u8, t.text(source), word);
}

fn isPunct(t: Token, source: []const u8, p: []const u8) bool {
    return t.kind == .punct and std.mem.eql(u8, t.text(source), p);
}

/// An identifier used as a property name, `a.if`, which is never a keyword.
fn isProperty(tokens: []const Token, source: []const u8, i: usize) bool {
    if (i == 0) return false;
    const before = tokens[i - 1];
    return isPunct(before, source, ".") or isPunct(before, source, "?.");
}

/// Whether a `(` about to be appended opens a statement head.
fn opensHead(source: []const u8, tokens: []const Token) bool {
    if (tokens.len == 0) return false;
    var at = tokens.len - 1;
    // `for await (`
    if (isWord(tokens[at], source, "await") and at > 0 and isWord(tokens[at - 1], source, "for")) at -= 1;
    const t = tokens[at];
    if (t.kind != .ident or isProperty(tokens, source, at)) return false;
    const words = [_][]const u8{ "if", "while", "for", "with" };
    for (words) |w| if (std.mem.eql(u8, t.text(source), w)) return true;
    return false;
}

/// Whether a `/` after `tokens` begins a regular expression. Exact for
/// every token but the few whose answer depends on the grammar around
/// them — a `}` (a block's, or an object literal's?), `++`/`--`, and the
/// contextual keywords — where it refuses.
fn slashIsRegex(source: []const u8, tokens: []const Token) error{Unsupported}!bool {
    if (tokens.len == 0) return true;
    const p = tokens[tokens.len - 1];
    switch (p.kind) {
        .number, .string, .template, .template_tail, .regex => return false,
        .template_head, .template_middle => return true,
        .ident => {
            if (isProperty(tokens, source, tokens.len - 1)) return false;
            const t = p.text(source);
            const regex_after = [_][]const u8{ "return", "typeof", "instanceof", "in", "new", "delete", "void", "throw", "case", "do", "else", "extends", "default" };
            for (regex_after) |w| if (std.mem.eql(u8, t, w)) return true;
            const ambiguous = [_][]const u8{ "of", "yield", "await", "let", "get", "set", "static", "async" };
            for (ambiguous) |w| if (std.mem.eql(u8, t, w)) return error.Unsupported;
            return false;
        },
        .punct => {
            const t = p.text(source);
            if (std.mem.eql(u8, t, ")")) return p.head;
            if (std.mem.eql(u8, t, "]")) return false;
            if (std.mem.eql(u8, t, "}") or std.mem.eql(u8, t, "++") or std.mem.eql(u8, t, "--")) return error.Unsupported;
            return true;
        },
    }
}

// ---------------------------------------------------------------------------
// Gaps
// ---------------------------------------------------------------------------

/// Tokens before which a line terminator never changes the parse: none can
/// begin a statement or a class element, so automatic semicolon insertion
/// cannot act in front of one, and none is the far side of a restricted
/// production. `*` is missing on purpose: it begins a generator method,
/// and a class field `a = 1` followed by a newline and `*g() {}` is two
/// elements only because of that newline.
const inert_before = [_][]const u8{
    ")",   "]",    "}",   ",",  ";",  ".",   "?.",  ":",   "?",  "=",   "==",
    "===", "!=",   "!==", "<",  ">",  "<=",  ">=",  "**",  "%",  "&",   "|",
    "^",   "&&",   "||",  "??", "+=", "-=",  "*=",  "/=",  "%=", "**=", "<<=",
    ">>=", ">>>=", "&=",  "|=", "^=", "&&=", "||=", "??=", "<<", ">>",  ">>>",
    "=>",
};

/// Whether a line terminator between `a` and `b` can be dropped: after a
/// punctuator that cannot end an expression (so the next token continues
/// it, and no restricted production has a left-hand side), or before a
/// token of `inert_before`.
fn newlineIsInert(source: []const u8, a: Token, b: Token) bool {
    switch (a.kind) {
        .template_head, .template_middle => return true,
        .punct => {
            const t = a.text(source);
            const ends = [_][]const u8{ ")", "]", "}", "++", "--" };
            var can_end = false;
            for (ends) |e| can_end = can_end or std.mem.eql(u8, t, e);
            if (!can_end) return true;
        },
        else => {},
    }
    switch (b.kind) {
        .template_middle, .template_tail => return true,
        .punct => {
            for (inert_before) |p| if (std.mem.eql(u8, b.text(source), p)) return true;
            return false;
        },
        else => return false,
    }
}

/// Whether `a` and `b` written with nothing between them would lex as
/// something other than `a` then `b`.
fn needsSpace(source: []const u8, a: Token, b: Token) bool {
    const at = a.text(source);
    const bt = b.text(source);
    const last = at[at.len - 1];
    const first = bt[0];
    if (isIdentPart(last) and (isIdentPart(first) or first == '#')) return true;
    // A regular expression's flags, a number's fraction or exponent, and a
    // number after a `.`, would each take the next token in.
    if (a.kind == .regex and isIdentPart(first)) return true;
    if (a.kind == .number and (isIdentPart(first) or first == '.' or ((last | 0x20) == 'e' and (first == '+' or first == '-')))) return true;
    // `.` then `.5`, and three `.` that would be one `...`.
    if (last == '.' and (isDigit(first) or first == '.')) return true;
    // A comment would open: `a / /re/`, `/re/ / 2`.
    if (last == '/' and (first == '/' or first == '*')) return true;
    // HTML-like comments, which no module has but a stray script might.
    if ((last == '<' and first == '!') or (last == '-' and first == '>')) return true;
    if (a.kind == .punct and b.kind == .punct) {
        var joined: [8]u8 = undefined;
        const n = @min(at.len + bt.len, joined.len);
        @memcpy(joined[0..at.len], at);
        @memcpy(joined[at.len..n], bt[0 .. n - at.len]);
        if (punctLen(joined[0..n]) != at.len) return true;
    }
    return false;
}

fn print(arena: Allocator, source: []const u8, tokens: []const Token, mask: ?[]const bool) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, source.len / 2);
    var prev: ?Token = null;
    var pending_nl = false;
    for (tokens, 0..) |t, i| {
        if (mask) |m| if (!m[i]) {
            pending_nl = pending_nl or t.nl;
            continue;
        };
        const nl = pending_nl or t.nl;
        pending_nl = false;
        if (prev) |a| {
            if (nl and !newlineIsInert(source, a, t)) {
                try out.append(arena, '\n');
            } else if (needsSpace(source, a, t)) {
                try out.append(arena, ' ');
            }
        }
        try out.appendSlice(arena, t.text(source));
        prev = t;
    }
    if (out.items.len != 0) try out.append(arena, '\n');
    return out.items;
}

/// The safety build's proof of `print`: the output lexes to the kept
/// tokens, each spelled as before, with a line terminator before every one
/// that `print` could not show to be inert.
fn verify(arena: Allocator, source: []const u8, tokens: []const Token, mask: ?[]const bool, out: []const u8) Allocator.Error!void {
    const again = tokenize(arena, out) catch std.debug.panic("Minify: the compacted file does not lex", .{});
    var at: usize = 0;
    var prev: ?Token = null;
    var pending_nl = false;
    for (tokens, 0..) |t, i| {
        if (mask) |m| if (!m[i]) {
            pending_nl = pending_nl or t.nl;
            continue;
        };
        if (at >= again.len) std.debug.panic("Minify: the compacted file lost a token", .{});
        const got = again[at];
        if (got.kind != t.kind or !std.mem.eql(u8, got.text(out), t.text(source))) {
            std.debug.panic("Minify: `{s}` became `{s}`", .{ t.text(source), got.text(out) });
        }
        if (prev) |a| if ((pending_nl or t.nl) and !newlineIsInert(source, a, t) and !got.nl) {
            std.debug.panic("Minify: the line break before `{s}` was lost", .{t.text(source)});
        };
        pending_nl = false;
        prev = t;
        at += 1;
    }
    if (at != again.len) std.debug.panic("Minify: the compacted file gained a token", .{});
}

// ---------------------------------------------------------------------------
// Elimination
// ---------------------------------------------------------------------------

const Unit = struct {
    start: u32,
    end: u32,
    /// Kept whatever references it: an `import`, or a unit whose
    /// evaluation may do something.
    root: bool,
    /// Names the unit declares at the top level.
    binds: []const []const u8,
    /// Names the unit exports.
    exports: []const []const u8,
    /// A `const`, `let` or `var`, whose initialisers decide `root`.
    declaration: bool = false,
};

const Shaker = struct {
    arena: Allocator,
    source: []const u8,
    tokens: []const Token,
    /// For an opening token (`(`, `[`, `{`, a template head), the index of
    /// the token that closes it.
    close: []u32,
    units: std.ArrayList(Unit) = .empty,
    /// Every name a top-level unit binds, for the purity of a read.
    bound: std.StringHashMapUnmanaged(void) = .empty,

    fn text(s: *const Shaker, i: usize) []const u8 {
        return s.tokens[i].text(s.source);
    }

    fn word(s: *const Shaker, i: usize, w: []const u8) bool {
        return i < s.tokens.len and isWord(s.tokens[i], s.source, w);
    }

    fn punct(s: *const Shaker, i: usize, p: []const u8) bool {
        return i < s.tokens.len and isPunct(s.tokens[i], s.source, p);
    }

    fn opens(s: *const Shaker, i: usize) bool {
        const t = s.tokens[i];
        return t.kind == .template_head or (t.kind == .punct and (isPunct(t, s.source, "(") or isPunct(t, s.source, "[") or isPunct(t, s.source, "{")));
    }

    /// The token after the one at `i`, stepping over what `i` opens.
    fn next(s: *const Shaker, i: usize) usize {
        return if (s.opens(i)) s.close[i] + 1 else i + 1;
    }

    /// The first `p` at this nesting level at or after `from`, before `end`.
    fn find(s: *const Shaker, from: usize, end: usize, p: []const u8) ?usize {
        var i = from;
        while (i < end) : (i = s.next(i)) if (s.punct(i, p)) return i;
        return null;
    }

    /// One top-level statement from `i`; the index after it, or null when
    /// it is one this pass cannot delimit.
    fn statement(s: *Shaker, i: usize) Allocator.Error!?usize {
        if (s.punct(i, ";")) return i + 1;
        if (s.word(i, "import")) {
            if (s.punct(i + 1, "(") or s.punct(i + 1, ".")) return null;
            const semi = s.find(i, s.tokens.len, ";") orelse return null;
            // Every name an import binds, conservatively: the identifiers
            // in it. None of them may be taken for a global's read.
            for (i..semi) |at| if (s.tokens[at].kind == .ident) try s.bound.put(s.arena, s.text(at), {});
            try s.units.append(s.arena, .{ .start = @intCast(i), .end = @intCast(semi + 1), .root = true, .binds = &.{}, .exports = &.{} });
            return semi + 1;
        }
        const exported = s.word(i, "export");
        const at = if (exported) i + 1 else i;
        if (s.word(at, "const") or s.word(at, "let") or s.word(at, "var")) return s.declaration(i, at, exported);
        if (s.word(at, "function") or (s.word(at, "async") and s.word(at + 1, "function"))) return s.function(i, at, exported);
        if (exported and s.punct(at, "{")) {
            const close = s.close[at];
            // A re-export evaluates another module: nothing here decides it.
            if (s.word(close + 1, "from") or !s.punct(close + 1, ";")) return null;
            var names: std.ArrayList([]const u8) = .empty;
            var k = at + 1;
            while (k < close) : (k += 1) {
                if (s.tokens[k].kind != .ident) continue;
                // `a as b` exports `b`; `a` alone exports `a`.
                if (s.word(k + 1, "as")) continue;
                if (s.word(k, "as") and k > at + 1 and s.tokens[k - 1].kind == .ident and !s.word(k - 1, "as")) continue;
                try names.append(s.arena, s.text(k));
            }
            try s.units.append(s.arena, .{ .start = @intCast(i), .end = @intCast(close + 2), .root = false, .binds = &.{}, .exports = names.items });
            return close + 2;
        }
        return null;
    }

    fn function(s: *Shaker, i: usize, at: usize, exported: bool) Allocator.Error!?usize {
        var k = if (s.word(at, "async")) at + 2 else at + 1;
        if (s.punct(k, "*")) k += 1;
        if (k >= s.tokens.len or s.tokens[k].kind != .ident) return null;
        const name = s.text(k);
        if (!s.punct(k + 1, "(")) return null;
        const body = s.close[k + 1] + 1;
        if (!s.punct(body, "{")) return null;
        const end = s.close[body] + 1;
        const names = try s.arena.dupe([]const u8, &.{name});
        try s.bound.put(s.arena, name, {});
        try s.units.append(s.arena, .{ .start = @intCast(i), .end = @intCast(end), .root = false, .binds = names, .exports = if (exported) names else &.{} });
        return end;
    }

    /// `const`/`let`/`var` to its `;`. Purity is decided later, once every
    /// top-level name is known.
    fn declaration(s: *Shaker, i: usize, at: usize, exported: bool) Allocator.Error!?usize {
        const semi = s.find(at + 1, s.tokens.len, ";") orelse return null;
        // A newline at this level that might be where the declaration
        // really ends, by automatic semicolon insertion, makes `semi` a
        // guess.
        var k = at + 1;
        var prev = at;
        while (k <= semi) : (k = s.next(k)) {
            if (s.tokens[k].nl and !newlineIsInert(s.source, s.tokens[prev], s.tokens[k])) return null;
            prev = if (s.opens(k)) s.close[k] else k;
        }
        var names: std.ArrayList([]const u8) = .empty;
        var root = false;
        var d = at + 1;
        while (d < semi) {
            const comma = s.find(d, semi, ",") orelse semi;
            if (s.tokens[d].kind == .ident) {
                try names.append(s.arena, s.text(d));
                try s.bound.put(s.arena, s.text(d), {});
            } else root = true; // a destructuring pattern
            d = comma + 1;
        }
        try s.units.append(s.arena, .{
            .start = @intCast(i),
            .end = @intCast(semi + 1),
            .root = root,
            .binds = names.items,
            .exports = if (exported) names.items else &.{},
            .declaration = true,
        });
        return semi + 1;
    }

    /// Whether every initialiser of the declaration unit `u` is free of
    /// effects.
    fn declarationIsPure(s: *const Shaker, u: Unit) bool {
        const at: usize = if (s.word(u.start, "export")) u.start + 1 else u.start;
        const semi: usize = u.end - 1;
        var d = at + 1;
        while (d < semi) {
            const comma = s.find(d, semi, ",") orelse semi;
            if (s.punct(d + 1, "=") and !s.pure(d + 2, comma)) return false;
            d = comma + 1;
        }
        return true;
    }

    /// Whether evaluating the expression `[from, to)` can do nothing but
    /// produce a value: a literal, a read of a name this file binds, a
    /// function, or an object or array literal of those. The `Set`, `Map`,
    /// `WeakMap` and `WeakSet` constructors over such a literal, and
    /// `Math`'s constants, are the only calls and reads of a global.
    fn pure(s: *const Shaker, from: usize, to: usize) bool {
        if (from >= to) return false;
        const t = s.tokens[from];
        if (to - from == 1) switch (t.kind) {
            .number, .string, .template, .regex => return true,
            .ident => {
                const words = [_][]const u8{ "null", "true", "false", "undefined", "NaN", "Infinity" };
                for (words) |w| if (std.mem.eql(u8, s.text(from), w)) return true;
                return s.bound.contains(s.text(from));
            },
            else => return false,
        };
        if (s.punct(from, "-") and to - from == 2 and s.tokens[from + 1].kind == .number) return true;
        // An arrow: nothing past `=>` runs until it is called, and its body
        // runs to the end of the declarator.
        var arrow = from;
        if (s.word(arrow, "async")) arrow += 1;
        if (arrow < to and s.tokens[arrow].kind == .ident and s.punct(arrow + 1, "=>")) return true;
        if (s.punct(arrow, "(") and s.punct(s.close[arrow] + 1, "=>")) return true;
        // A function expression.
        var f = from;
        if (s.word(f, "async")) f += 1;
        if (s.word(f, "function")) {
            f += 1;
            if (s.punct(f, "*")) f += 1;
            if (f < to and s.tokens[f].kind == .ident) f += 1;
            if (!s.punct(f, "(")) return false;
            const body = s.close[f] + 1;
            return s.punct(body, "{") and s.close[body] == to - 1;
        }
        if (s.punct(from, "{") and s.close[from] == to - 1) return s.pureObject(from + 1, to - 1);
        if (s.punct(from, "[") and s.close[from] == to - 1) return s.pureElements(from + 1, to - 1);
        if (s.word(from, "new") and to - from >= 4) {
            const constructors = [_][]const u8{ "Set", "Map", "WeakMap", "WeakSet" };
            var known = false;
            for (constructors) |c| known = known or s.word(from + 1, c);
            if (!known or s.bound.contains(s.text(from + 1))) return false;
            if (!s.punct(from + 2, "(") or s.close[from + 2] != to - 1) return false;
            return to - from == 4 or (s.punct(from + 3, "[") and s.close[from + 3] == to - 2 and s.pureElements(from + 4, to - 2));
        }
        if (to - from == 3 and s.word(from, "Math") and !s.bound.contains("Math") and s.punct(from + 1, ".") and s.tokens[from + 2].kind == .ident) return true;
        return false;
    }

    fn pureElements(s: *const Shaker, from: usize, to: usize) bool {
        var e = from;
        while (e < to) {
            const comma = s.find(e, to, ",") orelse to;
            if (comma != e and !s.pure(e, comma)) return false;
            e = comma + 1;
        }
        return true;
    }

    fn pureObject(s: *const Shaker, from: usize, to: usize) bool {
        var p = from;
        while (p < to) {
            const comma = s.find(p, to, ",") orelse to;
            if (comma != p and !s.pureProperty(p, comma)) return false;
            p = comma + 1;
        }
        return true;
    }

    fn pureProperty(s: *const Shaker, from: usize, to: usize) bool {
        const t = s.tokens[from];
        // A spread reads getters; a computed key evaluates an expression.
        if (t.kind != .ident and t.kind != .string and t.kind != .number) return s.punct(from, "*") and s.method(from + 1, to);
        if (to - from == 1) return t.kind == .ident and s.pure(from, to);
        if (s.punct(from + 1, ":")) return s.pure(from + 2, to);
        if (s.method(from, to)) return true;
        // `get x() {}`, `async *x() {}`
        var k = from;
        while (k < to and (s.word(k, "get") or s.word(k, "set") or s.word(k, "async") or s.punct(k, "*"))) k += 1;
        return k != from and s.method(k, to);
    }

    /// `name(…) { … }` filling `[from, to)`.
    fn method(s: *const Shaker, from: usize, to: usize) bool {
        if (from + 1 >= to) return false;
        const t = s.tokens[from];
        if (t.kind != .ident and t.kind != .string and t.kind != .number) return false;
        if (!s.punct(from + 1, "(")) return false;
        const body = s.close[from + 1] + 1;
        return s.punct(body, "{") and s.close[body] == to - 1;
    }
};

/// Which tokens survive when the file's exports are cut to `keep`, or null
/// when the file cannot be cut soundly.
pub fn shake(arena: Allocator, source: []const u8, tokens: []const Token, keep: []const []const u8) Allocator.Error!?[]const bool {
    // A direct `eval` can name any binding in a string.
    for (tokens, 0..) |t, i| if (isWord(t, source, "eval") and !isProperty(tokens, source, i)) return null;

    const close = try arena.alloc(u32, tokens.len);
    var stack: std.ArrayList(u32) = .empty;
    for (tokens, 0..) |t, i| {
        close[i] = @intCast(i);
        const is_open = t.kind == .template_head or (t.kind == .punct and (isPunct(t, source, "(") or isPunct(t, source, "[") or isPunct(t, source, "{")));
        const is_close = t.kind == .template_tail or (t.kind == .punct and (isPunct(t, source, ")") or isPunct(t, source, "]") or isPunct(t, source, "}")));
        if (is_close) {
            // `tokenize` balanced every one of them already.
            const open = stack.pop().?;
            close[open] = @intCast(i);
        }
        if (is_open) try stack.append(arena, @intCast(i));
    }

    var s: Shaker = .{ .arena = arena, .source = source, .tokens = tokens, .close = close };
    var i: usize = 0;
    while (i < tokens.len) i = try s.statement(i) orelse return null;

    const units = s.units.items;
    for (units) |*u| {
        if (u.declaration and !u.root and !s.declarationIsPure(u.*)) u.root = true;
    }

    var binders: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    for (units, 0..) |u, index| for (u.binds) |name| {
        const entry = try binders.getOrPut(arena, name);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, @intCast(index));
    };
    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    for (keep) |name| try wanted.put(arena, name, {});

    const live = try arena.alloc(bool, units.len);
    @memset(live, false);
    var work: std.ArrayList(u32) = .empty;
    for (units, 0..) |u, index| {
        var root = u.root;
        for (u.exports) |name| root = root or wanted.contains(name);
        if (root) {
            live[index] = true;
            try work.append(arena, @intCast(index));
        }
    }
    while (work.pop()) |index| {
        const u = units[index];
        for (u.start..u.end) |at| {
            if (tokens[at].kind != .ident or isProperty(tokens, source, at)) continue;
            const list = binders.get(tokens[at].text(source)) orelse continue;
            for (list.items) |other| if (!live[other]) {
                live[other] = true;
                try work.append(arena, other);
            };
        }
    }

    const mask = try arena.alloc(bool, tokens.len);
    @memset(mask, false);
    for (units, 0..) |u, index| if (live[index]) @memset(mask[u.start..u.end], true);
    return mask;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const fuzzing = @import("../fuzzing.zig");

fn expectMinified(source: []const u8, keep: ?[]const []const u8, want: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const got = try minify(arena_state.allocator(), source, keep);
    if (want) |w| {
        if (got == null) return error.Refused;
        try testing.expectEqualStrings(w, got.?);
    } else try testing.expect(got == null);
}

test "comments and whitespace go, and a string or template keeps what looks like them" {
    try expectMinified(
        \\// a header
        \\export const a = (x, y) => {
        \\  /* a note */
        \\  return x + "  // not a comment " + `  /* nor */ ${ y }  `;
        \\};
    , null,
        \\export const a=(x,y)=>{return x+"  // not a comment "+`  /* nor */ ${y}  `;};
        \\
    );
}

test "a slash after an expression divides and after an operator opens a regular expression" {
    try expectMinified("const q = a / b / c;\nconst r = x.split( / +/g );\nconst s = (a + b) / 2;\nconst t = [1][0] / 2;\n", null,
        \\const q=a/b/c;const r=x.split(/ +/g);const s=(a+b)/2;const t=[1][0]/2;
        \\
    );
    // After a statement head's `)`, and after a keyword, it is a regular
    // expression, and its spaces are its own.
    try expectMinified("if (ok) / a b /.test(s);\nfunction f() { return / c d /; }\n", null,
        \\if(ok)/ a b /.test(s);function f(){return/ c d /;}
        \\
    );
    // A property named like a keyword is not one.
    try expectMinified("const d = x.return / 2 / y;\n", null, "const d=x.return/2/y;\n");
    // Division then a regular expression, and a regular expression then a
    // division: `//` must not appear.
    try expectMinified("const e = a / /b/.source.length;\nconst f = /b/g / 1;\n", null, "const e=a/ /b/.source.length;const f=/b/g/1;\n");
}

test "a slash whose reading the tokens before it do not settle is refused" {
    try expectMinified("const f = function () {}\n/ 2 /g;\n", null, null);
    try expectMinified("for (const x of /a/g.exec(s)) f(x);\n", null, null);
    try expectMinified("a\n++/b/.lastIndex;\n", null, null);
}

test "template literals nest, braces inside a substitution included" {
    try expectMinified("const t = `a${ { b: `c${ d }e` }.b }f${ g }h`;\n", null, "const t=`a${{b:`c${d}e`}.b}f${g}h`;\n");
    try expectMinified("const u = `${ `${ `x` }` }`;\n", null, "const u=`${`${`x`}`}`;\n");
}

test "a newline stays wherever automatic semicolon insertion might act on it" {
    // `return` on its own line returns undefined.
    try expectMinified("function f() {\n  return\n  1;\n}\n", null, "function f(){return\n1;}\n");
    // A comment holding a line terminator is one.
    try expectMinified("function g() { return /*\n*/ 2; }\n", null, "function g(){return\n2;}\n");
    // `a` then `++b`, not `a++` then `b`.
    try expectMinified("a\n++b\n", null, "a\n++b\n");
    // A statement that ends at a `}` and a newline.
    try expectMinified("const f = () => {}\nf()\n", null, "const f=()=>{}\nf()\n");
    // A class field and a generator method.
    try expectMinified("class A {\n  a = 1\n  *g() {}\n}\n", null, "class A{a=1\n*g(){}}\n");
    // Inert newlines go: after an operator, before a `.` or a `)`.
    try expectMinified("const x = a +\n  b\n  .c(\n    d\n  );\n", null, "const x=a+b.c(d);\n");
}

test "tokens that would run together keep a space" {
    try expectMinified("const a = b + +c - -d;\nconst n = 1 .toString();\nconst k = typeof x in y;\n", null,
        \\const a=b+ +c- -d;const n=1 .toString();const k=typeof x in y;
        \\
    );
    try expectMinified("const c = a ? .5 : 1;\n", null, "const c=a?.5:1;\n");
    // Flags would swallow `in`.
    try expectMinified("const d = /a/ in b;\n", null, "const d=/a/ in b;\n");
}

test "what the tokenizer cannot read exactly is refused" {
    try expectMinified("const \\u0061 = 1;\n", null, null);
    try expectMinified("const caf\xc3\xa9 = 1;\n", null, null);
    try expectMinified("const s = \"unterminated;\n", null, null);
    try expectMinified("const t = `unterminated;\n", null, null);
    try expectMinified("f(;\n", null, null);
    // Non-ASCII in a comment or a string is fine.
    try expectMinified("// caf\xc3\xa9\nconst s = \"caf\xc3\xa9\";\n", null, "const s=\"caf\xc3\xa9\";\n");
}

test "an export nothing imports goes, with the helpers only it used" {
    try expectMinified(
        \\const helper = (x) => x + 1;
        \\const other = (x) => x * 2;
        \\const table = { m: (v) => other(v), n: 1 };
        \\export const used = (x) => helper(x);
        \\export const unused = (x) => table.m(x);
        \\export function alsoUnused() { return other(1); }
    , &.{"used"},
        \\const helper=(x)=>x+1;export const used=(x)=>helper(x);
        \\
    );
}

test "a helper named only inside a template substitution is kept" {
    try expectMinified("const h = () => 1;\nexport const f = () => `a${ h() }b`;\n", &.{"f"}, "const h=()=>1;export const f=()=>`a${h()}b`;\n");
}

test "a declaration whose initialiser might do something is kept" {
    try expectMinified("const s = start();\nconst k = new Set();\nconst m = new Set([\"a\"]);\nexport const f = () => 1;\n", &.{},
        \\const s=start();
        \\
    );
    // An object literal with a spread, a computed key or a call is not
    // known to be inert.
    try expectMinified("const a = { ...b };\nconst c = { [d]: 1 };\nconst e = { f: g() };\n", &.{}, "const a={...b};const c={[d]:1};const e={f:g()};\n");
    // An import is always kept: it evaluates its module.
    try expectMinified("import process from \"node:process\";\nconst f = () => process;\n", &.{}, "import process from\"node:process\";\n");
}

test "an export list keeps what it names" {
    try expectMinified("const a = () => 1;\nconst b = () => 2;\nexport { a as x, b };\n", &.{"x"}, "const a=()=>1;const b=()=>2;export{a as x,b};\n");
    try expectMinified("const a = () => 1;\nexport { a as x };\n", &.{}, "");
}

test "a file elimination cannot delimit is only compacted" {
    // `eval` can reach any binding by name.
    try expectMinified("const a = 1;\nexport const f = () => eval(\"a\");\n", &.{}, "const a=1;export const f=()=>eval(\"a\");\n");
    // A top-level statement that is not a declaration.
    try expectMinified("const a = 1;\nf();\n", &.{}, "const a=1;f();\n");
    // A declaration a newline might end.
    try expectMinified("const a = b\nconst c = 1;\n", &.{}, "const a=b\nconst c=1;\n");
}

/// One file that ships in the box: it must be neither refused by the
/// tokenizer nor left uncut by elimination, or a release build would copy
/// it whole without saying so.
fn expectCompacted(path: []const u8, source: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tokens = tokenize(arena, source) catch {
        std.debug.print("{s} is refused by the tokenizer\n", .{path});
        return error.Refused;
    };
    if (try shake(arena, source, tokens, &.{}) == null) {
        std.debug.print("{s} cannot be cut to its imported exports\n", .{path});
        return error.Refused;
    }
    const got = (try minify(arena, source, null)).?;
    try testing.expect(got.len < source.len);
}

test "every hand-written file that ships in the box is compacted and cut" {
    const core_package = @import("core_package");
    const platform_packages = @import("platform_packages");
    var seen: u32 = 0;
    for (core_package.assets) |asset| {
        if (!std.mem.endsWith(u8, asset.path, ".js")) continue;
        try expectCompacted(asset.path, asset.bytes);
        seen += 1;
    }
    for (platform_packages.platforms) |platform| for (platform.assets) |asset| {
        if (!std.mem.endsWith(u8, asset.path, ".js")) continue;
        try expectCompacted(asset.path, asset.bytes);
        seen += 1;
    };
    // A zero would mean the embedding broke and this looked at nothing.
    try testing.expect(seen >= 10);
}

test "fuzz: compaction never panics, and what it prints lexes to what it kept" {
    // `verify` runs inside `minify` in a safety build and panics on any
    // difference, so the sweep's oracle is the pass's own proof. Pieces of
    // JavaScript rather than bytes, so most inputs get past the tokenizer.
    try fuzzing.skipUnlessFuzzing();
    var iterations: usize = 3000;
    if (testing.environ.getAlloc(testing.allocator, "BENI_STRESS_ITERATIONS")) |value| {
        defer testing.allocator.free(value);
        iterations = std.fmt.parseInt(usize, value, 10) catch iterations;
    } else |_| {}
    const pieces = [_][]const u8{
        "const ", "export ", "let ", "function ", "return", "if",    "in",  "of",    "new ",   "a",    "b",  "e",
        "1",      ".5",      "0x1e", "=",         "=>",     "(",     ")",   "{",     "}",      "[",    "]",  "/",
        "/r e/g", "`",       "${",   "+",         "-",      "++",    "--",  ".",     "?",      ":",    ";",  ",",
        "*",      "!",       "<",    ">",         "&&",     "\"s\"", "'t'", "//c\n", "/*\n*/", "/**/", "\n", " ",
        "#p",     "...",     "eval", "Math",      "Set",
    };
    var prng: std.Random.DefaultPrng = .init(0x3a1f7);
    const random = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..iterations) |_| {
        buf.clearRetainingCapacity();
        const count = random.uintLessThan(usize, 40);
        for (0..count) |_| try buf.appendSlice(testing.allocator, pieces[random.uintLessThan(usize, pieces.len)]);
        var a: std.heap.ArenaAllocator = .init(testing.allocator);
        defer a.deinit();
        _ = try minify(a.allocator(), buf.items, null);
        _ = try minify(a.allocator(), buf.items, &.{"a"});
    }
}
