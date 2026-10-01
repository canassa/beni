//! Compact copies of hand-written JavaScript under `--release`
//! (`backend.md` §9, *Hand-written JavaScript under `--release`*): a
//! platform's runtime, its markup runtime and every `foreign` sibling, which
//! a development build copies byte for byte.
//!
//! Four passes, all over one token list and none a parser:
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
//!  2. **Rewriting** (`rewrite`, research 40's A3): three token rewrites,
//!     each exact — `const` is `let` in a file that never assigns a `const`
//!     binding, `(x) =>` is `x =>`, and a `;` in front of a `}` goes unless
//!     it is an empty statement.
//!  3. **Renaming** (`rename`, research 40's A2): every name the file binds
//!     is renamed, everywhere at once, to a short name no other identifier
//!     of the file spells — unless it is exported or imported, a global, or
//!     ever stands where a property name can. It needs no scopes because it
//!     is an injective renaming of all of a name's occurrences together:
//!     what each use referred to, it still refers to.
//!  4. **Compaction** (`print`): the surviving tokens, as spelled, with the
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
//! None of the files in `core/` or `platforms/` is refused. The two passes
//! research 40 added refuse the same way, one name or one file at a time:
//! `rename` renames nothing in a file with `eval`, `with` or `class`, and
//! `rewrite` keeps every `const` in a file where it cannot show that no
//! `const` binding is assigned.
//!
//! **A release application's one scope** (`backend.md` §9, *One
//! scope-hoisted file under `--release`*) reads a file through `hoistable`
//! — its top-level bindings, exports and imports, the names it keeps as
//! written and the names it may read unbound — and prints it through
//! `printHoisted`, with its top-level bindings spelled as the linker in
//! `Emit` numbered them and its module syntax gone. The same four passes,
//! the same refusals, and one more: `Hoisted.declines` names what keeps a
//! file in a module of its own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Print = @import("Print.zig");
const Rename = @import("Rename.zig");
const Sibling = @import("Sibling.zig");

/// Which of research 40's passes run. `minify` always eliminates and
/// compacts; the two below are what a release build adds.
pub const Options = struct {
    /// A3: `const` → `let`, `(x) =>` → `x =>`, `;}` → `}`.
    rewrite: bool = false,
    /// A2: every name the file binds, renamed short.
    rename: bool = false,
};

/// What `--release` runs.
pub const release: Options = .{ .rewrite = true, .rename = true };

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
pub fn minify(arena: Allocator, source: []const u8, keep: ?[]const []const u8, options: Options) Allocator.Error!?[]const u8 {
    const tokens = tokenize(arena, source) catch |err| switch (err) {
        error.Unsupported => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const mask = if (keep) |names| try shake(arena, source, tokens, names) else null;
    const shown = try arena.alloc(bool, tokens.len);
    if (mask) |m| @memcpy(shown, m) else @memset(shown, true);
    const spell = try arena.alloc(?[]const u8, tokens.len);
    @memset(spell, null);
    var block_ends: ?[]const bool = null;
    if (options.rewrite or options.rename) {
        const s: Structure = try .init(arena, source, tokens);
        // Renaming first: it reads which tokens elimination kept, before
        // the rewrites hide a `;` or a parameter's brackets.
        if (options.rename) try rename(arena, &s, shown, spell);
        if (options.rewrite) {
            try rewrite(arena, &s, shown, spell);
            block_ends = try statementBlocks(arena, &s);
        }
    }
    const plan: Plan = .{ .shown = shown, .spell = spell, .block_ends = block_ends };
    const out = try print(arena, source, tokens, plan);
    if (std.debug.runtime_safety) try verify(arena, source, tokens, plan, out);
    return out;
}

/// What `print` writes: which tokens, and each one's spelling when a pass
/// changed it.
const Plan = struct {
    shown: []const bool,
    spell: []const ?[]const u8,
    /// Per token, under the release rewrites: a `}` that closes a block
    /// STATEMENT (`statementBlocks`), after which a line terminator is never
    /// automatic semicolon insertion's. Null keeps every such newline.
    block_ends: ?[]const bool = null,

    fn text(p: Plan, source: []const u8, tokens: []const Token, i: usize) []const u8 {
        return p.spell[i] orelse tokens[i].text(source);
    }

    /// Whether a line terminator between shown tokens `a` and `b` may go.
    fn inert(p: Plan, source: []const u8, tokens: []const Token, a: usize, b: usize) bool {
        if (newlineIsInert(source, tokens[a], tokens[b])) return true;
        const ends = p.block_ends orelse return false;
        return ends[a];
    }
};

/// Per token, whether it is a `}` closing a block statement — the body of
/// an `if`/`for`/`while`/`with` head, of `else`, `try`, `catch (…)`,
/// `finally` or `do`, of a `switch (…)`, or of a function DECLARATION at
/// the start of a statement. Such a `}` ends its statement whatever
/// follows, so the newline after it is never where automatic semicolon
/// insertion acts (`backend.md` §9, *Hand-written JavaScript under
/// `--release`*, amended 2026-10-02). An arrow's or a function
/// expression's body is not one: `f=()=>{}` then a newline then `g()` is
/// two statements only because of that newline.
fn statementBlocks(arena: Allocator, s: *const Structure) Allocator.Error![]const bool {
    const tokens = s.tokens;
    const ends = try arena.alloc(bool, tokens.len);
    @memset(ends, false);
    for (tokens, 0..) |t, i| {
        if (!isPunct(t, s.source, "{") or i == 0) continue;
        const close = s.close[i];
        if (close == i) continue;
        const before = i - 1;
        const statement = if (s.punct(before, ")")) blk: {
            if (tokens[before].head) break :blk true;
            const open = s.close[before];
            if (open == 0) break :blk false;
            if (s.word(open - 1, "catch") or s.word(open - 1, "switch")) break :blk true;
            // `function name(…) {` where `function` begins a statement.
            if (open < 2 or !s.name(open - 1) or !s.word(open - 2, "function")) break :blk false;
            break :blk statementStart(s, ends, open - 2);
        } else s.word(before, "else") or s.word(before, "try") or s.word(before, "finally") or s.word(before, "do");
        if (statement) ends[close] = true;
    }
    return ends;
}

/// Whether token `k` begins a statement: the first token, or one after a
/// `;`, after a block statement's `}` (`ends`, filled left to right), or
/// after `export`.
fn statementStart(s: *const Structure, ends: []const bool, k: usize) bool {
    if (k == 0) return true;
    return s.punct(k - 1, ";") or ends[k - 1] or s.word(k - 1, "export");
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

/// Whether `a` and `b`, spelled `at` and `bt`, written with nothing between
/// them would lex as something other than `a` then `b`.
fn needsSpace(a: Token, at: []const u8, b: Token, bt: []const u8) bool {
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

fn print(arena: Allocator, source: []const u8, tokens: []const Token, plan: Plan) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, source.len / 2);
    var prev: ?usize = null;
    var pending_nl = false;
    for (tokens, 0..) |t, i| {
        if (!plan.shown[i]) {
            pending_nl = pending_nl or t.nl;
            continue;
        }
        const nl = pending_nl or t.nl;
        pending_nl = false;
        const text = plan.text(source, tokens, i);
        if (prev) |a| {
            if (nl and !plan.inert(source, tokens, a, i)) {
                try out.append(arena, '\n');
            } else if (needsSpace(tokens[a], plan.text(source, tokens, a), t, text)) {
                try out.append(arena, ' ');
            }
        }
        try out.appendSlice(arena, text);
        prev = i;
    }
    if (out.items.len != 0) try out.append(arena, '\n');
    return out.items;
}

/// The safety build's proof of `print`: the output lexes to the shown
/// tokens, each spelled as the plan says, with a line terminator before
/// every one that `print` could not show to be inert.
fn verify(arena: Allocator, source: []const u8, tokens: []const Token, plan: Plan, out: []const u8) Allocator.Error!void {
    const again = tokenize(arena, out) catch std.debug.panic("Minify: the compacted file does not lex", .{});
    var at: usize = 0;
    var prev: ?usize = null;
    var pending_nl = false;
    for (tokens, 0..) |t, i| {
        if (!plan.shown[i]) {
            pending_nl = pending_nl or t.nl;
            continue;
        }
        if (at >= again.len) std.debug.panic("Minify: the compacted file lost a token", .{});
        const got = again[at];
        const want = plan.text(source, tokens, i);
        if (got.kind != t.kind or !std.mem.eql(u8, got.text(out), want)) {
            std.debug.panic("Minify: `{s}` became `{s}`", .{ want, got.text(out) });
        }
        if (prev) |a| if ((pending_nl or t.nl) and !plan.inert(source, tokens, a, i) and !got.nl) {
            std.debug.panic("Minify: the line break before `{s}` was lost", .{t.text(source)});
        };
        pending_nl = false;
        prev = i;
        at += 1;
    }
    if (at != again.len) std.debug.panic("Minify: the compacted file gained a token", .{});
}

// ---------------------------------------------------------------------------
// Elimination
// ---------------------------------------------------------------------------

pub const Unit = struct {
    kind: Unit.UnitKind,
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
    /// A declaration with a destructuring pattern, whose names `binds` does
    /// not list.
    pattern: bool = false,

    pub const UnitKind = enum { import, declaration, function, export_list };
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
            try s.units.append(s.arena, .{ .kind = .import, .start = @intCast(i), .end = @intCast(semi + 1), .root = true, .binds = &.{}, .exports = &.{} });
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
            try s.units.append(s.arena, .{ .kind = .export_list, .start = @intCast(i), .end = @intCast(close + 2), .root = false, .binds = &.{}, .exports = names.items });
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
        try s.units.append(s.arena, .{ .kind = .function, .start = @intCast(i), .end = @intCast(end), .root = false, .binds = names, .exports = if (exported) names else &.{} });
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
        var pattern = false;
        var d = at + 1;
        while (d < semi) {
            const comma = s.find(d, semi, ",") orelse semi;
            if (s.tokens[d].kind == .ident) {
                try names.append(s.arena, s.text(d));
                try s.bound.put(s.arena, s.text(d), {});
            } else {
                root = true; // a destructuring pattern
                pattern = true;
            }
            d = comma + 1;
        }
        try s.units.append(s.arena, .{
            .kind = .declaration,
            .start = @intCast(i),
            .end = @intCast(semi + 1),
            .root = root,
            .binds = names.items,
            .exports = if (exported) names.items else &.{},
            .declaration = true,
            .pattern = pattern,
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
    const c = try cut(arena, source, tokens, keep) orelse return null;
    return c.mask;
}

/// What `shake` decides, with the units it decided it over: the file's
/// top-level statements, and which of them survive.
pub const Cut = struct {
    mask: []bool,
    units: []const Unit,
    live: []const bool,
};

/// `shake`, keeping the units: a scope-hoisted build reads a file's
/// top-level bindings, exports and imports from them.
pub fn cut(arena: Allocator, source: []const u8, tokens: []const Token, keep: []const []const u8) Allocator.Error!?Cut {
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
    return .{ .mask = mask, .units = units, .live = live };
}

// ---------------------------------------------------------------------------
// Research 40's passes: rewriting (A3) and renaming (A2)
// ---------------------------------------------------------------------------

/// What both passes read of the token list besides the tokens.
const Structure = struct {
    source: []const u8,
    tokens: []const Token,
    /// For an opening token — `(`, `[`, `{`, a template head — the index of
    /// the token that closes it; for a closing one, the index of its
    /// opener; for every other token, its own index.
    close: []u32,
    /// The innermost opening token around each token, or `none`.
    outer: []u32,
    /// For a `{`: whether it provably opens a statement list — after `)`,
    /// `=>`, `;`, `}`, `else`, `try`, `finally`, `do`, at the start of the
    /// file, or directly inside another block. Anything else — an object
    /// literal, a pattern, a class body, a `case x: {` — is treated as a
    /// place where a name may be a property key.
    block: []bool,

    const none = std.math.maxInt(u32);

    fn init(arena: Allocator, source: []const u8, tokens: []const Token) Allocator.Error!Structure {
        const close = try arena.alloc(u32, tokens.len);
        const outer = try arena.alloc(u32, tokens.len);
        const block = try arena.alloc(bool, tokens.len);
        @memset(block, false);
        var stack: std.ArrayList(u32) = .empty;
        for (tokens, 0..) |t, i| {
            close[i] = @intCast(i);
            const is_open = t.kind == .template_head or (t.kind == .punct and (isPunct(t, source, "(") or isPunct(t, source, "[") or isPunct(t, source, "{")));
            const is_close = t.kind == .template_tail or (t.kind == .punct and (isPunct(t, source, ")") or isPunct(t, source, "]") or isPunct(t, source, "}")));
            if (is_close) {
                // `tokenize` balanced every one of them already.
                const open = stack.pop().?;
                close[open] = @intCast(i);
                close[i] = open;
            }
            outer[i] = if (stack.items.len == 0) none else stack.items[stack.items.len - 1];
            if (is_open) {
                if (isPunct(t, source, "{")) block[i] = opensBlock(source, tokens, block, outer[i], i);
                try stack.append(arena, @intCast(i));
            }
        }
        return .{ .source = source, .tokens = tokens, .close = close, .outer = outer, .block = block };
    }

    fn opensBlock(source: []const u8, tokens: []const Token, block: []const bool, outer: u32, i: usize) bool {
        if (i == 0) return true;
        const p = tokens[i - 1];
        if (p.kind == .punct) {
            for ([_][]const u8{ ")", "=>", ";", "}" }) |w| if (isPunct(p, source, w)) return true;
            return isPunct(p, source, "{") and outer != none and block[outer];
        }
        if (p.kind != .ident or isProperty(tokens, source, i - 1)) return false;
        for ([_][]const u8{ "else", "try", "finally", "do" }) |w| if (isWord(p, source, w)) return true;
        return false;
    }

    fn text(s: *const Structure, i: usize) []const u8 {
        return s.tokens[i].text(s.source);
    }

    fn word(s: *const Structure, i: usize, w: []const u8) bool {
        return i < s.tokens.len and isWord(s.tokens[i], s.source, w) and !isProperty(s.tokens, s.source, i);
    }

    fn punct(s: *const Structure, i: usize, p: []const u8) bool {
        return i < s.tokens.len and isPunct(s.tokens[i], s.source, p);
    }

    /// An identifier that names something rather than a property.
    fn name(s: *const Structure, i: usize) bool {
        return s.tokens[i].kind == .ident and !isProperty(s.tokens, s.source, i);
    }

    fn opens(s: *const Structure, i: usize) bool {
        return s.close[i] > i;
    }

    fn next(s: *const Structure, i: usize) usize {
        return if (s.opens(i)) s.close[i] + 1 else i + 1;
    }

    /// The declarators of the `let`, `const` or `var` at `k`: each simple
    /// one's identifier and each pattern's opening token, appended to
    /// `out`. Null when a line terminator at the declaration's own level
    /// might end it by automatic semicolon insertion, or when an `in` or
    /// `of` there is not a `for` head's — either makes the list a guess.
    fn declarators(s: *const Structure, arena: Allocator, k: usize, out: *std.ArrayList(u32)) Allocator.Error!?void {
        const in_head = s.outer[k] != none and s.tokens[s.close[s.outer[k]]].head;
        const end: usize = if (s.outer[k] != none) s.close[s.outer[k]] else s.tokens.len;
        var j = k + 1;
        var prev = k;
        var at_declarator = true;
        while (j < end) {
            const t = s.tokens[j];
            if (t.nl and !newlineIsInert(s.source, s.tokens[prev], t)) return null;
            if (s.punct(j, ";")) break;
            if (s.word(j, "of") or s.word(j, "in")) {
                if (in_head and !at_declarator) break;
                return null;
            }
            if (at_declarator) {
                if (!(s.name(j) or s.punct(j, "[") or s.punct(j, "{"))) return null;
                try out.append(arena, @intCast(j));
                at_declarator = false;
            } else if (s.punct(j, ",")) at_declarator = true;
            prev = if (s.opens(j)) s.close[j] else j;
            j = s.next(j);
        }
        return {};
    }
};

/// Assignment operators: a `const` binding written before one of these, or
/// beside `++`/`--`, is being assigned.
const assigners = [_][]const u8{ "=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=", "|=", "^=", "&&=", "||=", "??=", "++", "--" };

fn assigns(s: *const Structure, i: usize) bool {
    for (assigners) |a| if (s.punct(i, a)) return true;
    return false;
}

/// A3: three rewrites, each exact at the token level.
fn rewrite(arena: Allocator, s: *const Structure, shown: []bool, spell: []?[]const u8) Allocator.Error!void {
    const tokens = s.tokens;
    for (tokens, 0..) |t, i| {
        if (!shown[i]) continue;
        // `;` before `}`: the brace ends the statement anyway, unless the
        // `;` IS the statement — an empty one after a statement head, `else`,
        // `do` or a label (or a `case`), or one alone in a block.
        if (isPunct(t, s.source, ";") and i > 0 and i + 1 < tokens.len and shown[i + 1] and s.punct(i + 1, "}")) {
            const p = tokens[i - 1];
            const empty = (isPunct(p, s.source, ")") and p.head) or s.punct(i - 1, ":") or s.punct(i - 1, "{") or
                s.punct(i - 1, ";") or s.word(i - 1, "else") or s.word(i - 1, "do");
            if (!empty) shown[i] = false;
            continue;
        }
        // `(x) =>` is `x =>` when the list is one plain identifier.
        if (isPunct(t, s.source, "(") and s.close[i] == i + 2 and s.name(i + 1) and s.punct(i + 3, "=>") and shown[i + 2] and !Print.isReservedWord(s.text(i + 1))) {
            shown[i] = false;
            shown[i + 2] = false;
        }
    }
    try constToLet(arena, s, shown, spell);
}

/// `const` is `let` throughout a file none of whose `const` declarations
/// names anything the file assigns: the one difference, the `TypeError` an
/// assignment to the binding would throw, cannot happen, because an
/// assignment to the binding is an assignment to its name and there is none.
/// Names, not scopes: a `let i` assigned in one function keeps a
/// `const i` in another, and with it every `const` of the file.
///
/// Decided over the tokens that are written (*amended 2026-10-02*,
/// `backend.md` §9, *Hand-written JavaScript under `--release`*): a unit
/// elimination cut is never evaluated, so its `i = …` assigns nothing, and
/// it used to keep every `const` of the units that stay.
///
/// *Amended 2026-10-03*: a `const` at the file's top level is never
/// rewritten. V8 folds a module-level `const` into the code that calls it,
/// and loads and checks a `let` on every call, which made a loop over a
/// top-level function 2.5× slower in isolation; the emitted code's
/// top-level declarations are `const` too (`Print.topConstRun`), so the one
/// bundle still spells each place one way.
fn constToLet(arena: Allocator, s: *const Structure, shown: []const bool, spell: []?[]const u8) Allocator.Error!void {
    const tokens = s.tokens;
    const assigned = try assignedNames(arena, s, shown) orelse return;
    var list: std.ArrayList(u32) = .empty;

    // All of the file's `const`s or none: a file that mixes the two
    // keywords compresses worse than one that keeps `const` throughout
    // (research 41 measured +9 brotli bytes on the browser runtime, where
    // a partial rewrite was possible), so a partial rewrite is not made.
    var consts: std.ArrayList(u32) = .empty;
    for (tokens, 0..) |_, k| {
        if (!shown[k] or !s.word(k, "const")) continue;
        list.clearRetainingCapacity();
        (try s.declarators(arena, k, &list)) orelse return;
        for (list.items) |d| {
            // A pattern's every name, keys included: more than it binds.
            for (d..s.close[d] + 1) |at| if (s.name(at) and assigned.contains(s.text(at))) return;
        }
        try consts.append(arena, @intCast(k));
    }
    for (consts.items) |k| {
        if (s.outer[k] != Structure.none) spell[k] = "let";
    }
}

/// Every name the file assigns anywhere, by name and not by scope — or null
/// when a string `eval` runs or a `with` object can assign a name no token
/// spells. With `shown`, only the tokens that are written: a unit
/// elimination cut is never evaluated.
fn assignedNames(arena: Allocator, s: *const Structure, shown: ?[]const bool) Allocator.Error!?Set {
    const tokens = s.tokens;
    for (tokens, 0..) |_, i| if (s.word(i, "eval") or s.word(i, "with")) return null;

    // Where a declaration names its bindings, so that `let x = 1` is not
    // read as an assignment to `x`: each simple declarator, and a
    // pattern's closing bracket, which may stand before `=`. A pattern's
    // own names are not marked, so `const { a = 1 } = o` reads as an
    // assignment to `a` — too many assignments only keeps a `const`.
    const declarator = try arena.alloc(bool, tokens.len);
    @memset(declarator, false);
    var list: std.ArrayList(u32) = .empty;
    for (tokens, 0..) |_, k| {
        if (!(s.word(k, "const") or s.word(k, "let") or s.word(k, "var"))) continue;
        list.clearRetainingCapacity();
        (try s.declarators(arena, k, &list)) orelse continue;
        for (list.items) |d| declarator[s.close[d]] = true;
    }

    // Every name something assigns.
    var assigned: std.StringHashMapUnmanaged(void) = .empty;
    for (tokens, 0..) |t, i| {
        if (shown) |mask| if (!mask[i]) continue;
        if (s.name(i) and !declarator[i]) {
            const written = assigns(s, i + 1) or (i > 0 and (s.punct(i - 1, "++") or s.punct(i - 1, "--"))) or
                (i >= 2 and s.punct(i - 1, "(") and s.word(i - 2, "for")); // `for (x of …)`
            if (written) try assigned.put(arena, s.text(i), {});
        }
        // A destructuring assignment — `[a, b] = …`, `({ a } = …)`,
        // `for ([a, b] of …)` — assigns every name inside it.
        const pattern_end: ?usize = if (!declarator[i] and s.punct(i + 1, "=") and (isPunct(t, s.source, "]") or isPunct(t, s.source, "}")) and !isMember(s, s.close[i]))
            i
        else if (i >= 1 and s.word(i - 1, "for") and s.punct(i, "(") and (s.punct(i + 1, "[") or s.punct(i + 1, "{")))
            s.close[i + 1]
        else
            null;
        if (pattern_end) |e| for (s.close[e]..e) |at| if (s.name(at)) try assigned.put(arena, s.text(at), {});
    }
    return assigned;
}

/// Whether the `[` at `open` reads a member (`a[i]`) rather than opening
/// an array literal or pattern.
fn isMember(s: *const Structure, open: usize) bool {
    if (!s.punct(open, "[") or open == 0) return false;
    const p = s.tokens[open - 1];
    return (p.kind == .ident and !Print.isReservedWord(p.text(s.source))) or
        p.kind == .string or p.kind == .template or p.kind == .template_tail or
        isPunct(p, s.source, ")") or isPunct(p, s.source, "]");
}

/// Words a renaming never takes and never gives: every reserved and
/// contextual word, the literals a name can spell, and every global a file
/// may read without binding it — `Sibling.isStandardGlobal`'s, and the hosts'
/// (`boundary.md` §5.1), which check 3 cannot see when the same name is also
/// bound somewhere in the file.
fn fixedName(text: []const u8) bool {
    if (text.len == 0 or text[0] == '#') return true;
    if (Print.isReservedWord(text) or Sibling.isStandardGlobal(text)) return true;
    const words = [_][]const u8{
        "of",                  "as",               "from",             "get",                   "set",
        "async",               "target",           "meta",             "undefined",             "NaN",
        "Infinity",            "window",           "self",             "document",              "navigator",
        "location",            "history",          "name",             "top",                   "parent",
        "frames",              "opener",           "origin",           "event",                 "process",
        "require",             "module",           "exports",          "global",                "__dirname",
        "__filename",          "Buffer",           "Deno",             "Bun",                   "Node",
        "Element",             "HTMLElement",      "Text",             "Comment",               "DocumentFragment",
        "Event",               "CustomEvent",      "MutationObserver", "requestAnimationFrame", "cancelAnimationFrame",
        "requestIdleCallback", "localStorage",     "sessionStorage",   "alert",                 "confirm",
        "prompt",              "getComputedStyle", "matchMedia",       "WebSocket",             "Worker",
        "Blob",                "File",             "FormData",         "Headers",               "Request",
        "Response",            "ReadableStream",   "WritableStream",   "MessageChannel",        "BroadcastChannel",
        "setImmediate",        "clearImmediate",
    };
    for (words) |w| if (std.mem.eql(u8, w, text)) return true;
    return false;
}

const Set = std.StringHashMapUnmanaged(void);

/// What A2 reads of a file before it renames anything: the names the file
/// binds, and the three reasons a name may not move.
const Facts = struct {
    /// Every name the file binds — a declaration's, a function's, a
    /// parameter's, a `catch`'s — exported or not.
    bound: Set = .empty,
    /// Names that somewhere stand where a property name can (research 40
    /// §7): renaming one there would rename a key.
    keyed: Set = .empty,
    /// Every name an `import` statement spells.
    imported: Set = .empty,
    /// Every name an `export` spells: an exported declaration's, and each
    /// of an `export { … }` list's.
    exported: Set = .empty,

    /// Whether `text` may be renamed. `hoisted` is a scope-hoisted file
    /// (`backend.md` §9, *One scope-hoisted file under `--release`*), whose
    /// exports are not a boundary any more: nothing imports them by name.
    fn renamable(f: *const Facts, text: []const u8, hoisted: bool) bool {
        return f.bound.contains(text) and !f.keyed.contains(text) and !f.imported.contains(text) and
            (hoisted or !f.exported.contains(text)) and !fixedName(text);
    }
};

/// A2's reading of the file, or null when it mentions `eval`, `with` or
/// `class` — or exports a declaration whose names it cannot list — and so
/// no name in it is renamed.
fn facts(arena: Allocator, s: *const Structure, shown: []const bool) Allocator.Error!?Facts {
    return factsIgnoring(arena, s, shown, null);
}

/// `facts`, reading nothing of the tokens `ignore` marks: a scope-hoisted
/// markup runtime's imports of its runtime module (`hoistableWith`), whose
/// braces are no object literal and whose names are no import's.
fn factsIgnoring(arena: Allocator, s: *const Structure, shown: []const bool, ignore: ?[]const bool) Allocator.Error!?Facts {
    const tokens = s.tokens;
    for (tokens, 0..) |_, i| {
        if (s.word(i, "eval") or s.word(i, "with") or s.word(i, "class")) return null;
    }

    var f: Facts = .{};
    var list: std.ArrayList(u32) = .empty;
    for (tokens, 0..) |_, i| {
        if (ignore) |skip| if (skip[i]) continue;
        // An `import`'s every name, and an `export { … }` list's.
        if (s.word(i, "import") and !s.punct(i + 1, "(") and !s.punct(i + 1, ".")) {
            var j = i + 1;
            while (j < tokens.len and tokens[j].kind != .string and !s.punct(j, ";")) : (j += 1) {
                if (tokens[j].kind == .ident) try f.imported.put(arena, s.text(j), {});
            }
            continue;
        }
        if (s.word(i, "export") and s.punct(i + 1, "{")) {
            for (i + 2..s.close[i + 1]) |j| if (tokens[j].kind == .ident) try f.exported.put(arena, s.text(j), {});
            continue;
        }
        if (!shown[i]) continue;
        const exported = i > 0 and s.word(i - 1, "export");
        if (s.word(i, "const") or s.word(i, "let") or s.word(i, "var")) {
            list.clearRetainingCapacity();
            const certain = (try s.declarators(arena, i, &list)) != null;
            // An exported declaration whose names this cannot list keeps
            // every name in the file.
            if (exported and !certain) return null;
            for (list.items) |d| {
                if (!s.name(d)) continue;
                try f.bound.put(arena, s.text(d), {});
                if (exported) try f.exported.put(arena, s.text(d), {});
            }
            continue;
        }
        if (s.word(i, "function")) {
            var j = i + 1;
            if (s.punct(j, "*")) j += 1;
            if (j < tokens.len and s.name(j)) {
                const fn_exported = exported or (i > 1 and s.word(i - 1, "async") and s.word(i - 2, "export"));
                try f.bound.put(arena, s.text(j), {});
                if (fn_exported) try f.exported.put(arena, s.text(j), {});
                j += 1;
            }
            if (s.punct(j, "(")) try bindParams(arena, s, j, &f.bound);
            continue;
        }
        if (s.word(i, "catch") and s.punct(i + 1, "(")) {
            try bindParams(arena, s, i + 1, &f.bound);
            continue;
        }
        if (s.punct(i, "(") and s.punct(s.close[i] + 1, "=>")) {
            try bindParams(arena, s, i, &f.bound);
            continue;
        }
        if (s.name(i) and s.punct(i + 1, "=>")) try f.bound.put(arena, s.text(i), {});
    }

    // Where a name may be a property key, over every token, shown or not.
    for (tokens, 0..) |_, i| {
        if (ignore) |skip| if (skip[i]) continue;
        if (!s.name(i)) continue;
        const t = s.text(i);
        if (s.punct(i + 1, ":")) {
            // `c ? x : y` and `case x:` read `x`; anything else may be a key
            // or a label.
            if (!(i > 0 and (s.punct(i - 1, "?") or s.word(i - 1, "case")))) try f.keyed.put(arena, t, {});
            continue;
        }
        const o = s.outer[i];
        if (o == Structure.none or !s.punct(o, "{") or s.block[o] or i == 0) continue;
        const before = s.punct(i - 1, "{") or s.punct(i - 1, ",") or s.punct(i - 1, ";") or s.punct(i - 1, "}") or s.punct(i - 1, "*") or
            s.word(i - 1, "get") or s.word(i - 1, "set") or s.word(i - 1, "static") or s.word(i - 1, "async");
        const after = s.punct(i + 1, ",") or s.punct(i + 1, "}") or s.punct(i + 1, "=") or s.punct(i + 1, "(") or s.punct(i + 1, ";");
        if (before and after) try f.keyed.put(arena, t, {});
    }
    return f;
}

/// A2: every name the file binds, renamed at once to a short name that no
/// other identifier of the file spells — the most used first, ties by first
/// occurrence (rule 5). A name keeps its spelling when it is exported or
/// imported (the boundary with emitted code, which `boundary.md` §4 fixes),
/// when it is a global, and when it ever stands where a property name can:
/// before `:` (a key or a label), or in an object literal, pattern or class
/// body where a shorthand, a method or a field would put it. Research 40
/// §7 is the argument: the renaming is injective onto names nothing else
/// uses, so every use still refers to what it referred to.
fn rename(arena: Allocator, s: *const Structure, shown: []const bool, spell: []?[]const u8) Allocator.Error!void {
    const f = try facts(arena, s, shown) orelse return;
    try assign(arena, s, shown, spell, &f, null);
}

/// The spellings a scope-hoisted file's top-level bindings are given from
/// outside the file, by the name each is written with.
pub const Forced = std.StringHashMapUnmanaged([]const u8);

/// A2's assignment. With `forced`, the file is scope-hoisted: its exports
/// are ordinary bindings, a name `forced` lists takes that spelling, and
/// every other renamed name avoids those spellings as well as the file's
/// own kept ones, so no inner binding can capture a top-level one.
fn assign(arena: Allocator, s: *const Structure, shown: []const bool, spell: []?[]const u8, f: *const Facts, forced: ?*const Forced) Allocator.Error!void {
    const tokens = s.tokens;
    const hoisted = forced != null;
    // The candidates, with how often the shown tokens use each.
    const Candidate = struct { text: []const u8, count: u32, first: u32 };
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    var candidates: std.ArrayList(Candidate) = .empty;
    var taken: Set = .empty;
    for (tokens, 0..) |_, i| {
        if (!s.name(i)) continue;
        const t = s.text(i);
        if (!f.renamable(t, hoisted)) {
            try taken.put(arena, t, {});
            continue;
        }
        if (forced) |fixed| if (fixed.contains(t)) continue;
        const slot = try index.getOrPut(arena, t);
        if (!slot.found_existing) {
            slot.value_ptr.* = @intCast(candidates.items.len);
            try candidates.append(arena, .{ .text = t, .count = 0, .first = @intCast(i) });
        }
        if (shown[i]) candidates.items[slot.value_ptr.*].count += 1;
    }
    if (forced) |fixed| {
        var it = fixed.valueIterator();
        while (it.next()) |v| try taken.put(arena, v.*, {});
    }
    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.count != b.count) return a.count > b.count;
            return a.first < b.first;
        }
    }.lessThan);

    var fresh: std.StringHashMapUnmanaged([]const u8) = .empty;
    var ordinal: u32 = 0;
    for (candidates.items) |c| {
        const new = while (true) {
            var buf: [8]u8 = undefined;
            const spelled = Rename.spell(ordinal, &buf);
            ordinal += 1;
            if (taken.contains(spelled) or fixedName(spelled)) continue;
            break try arena.dupe(u8, spelled);
        };
        try fresh.put(arena, c.text, new);
    }
    for (tokens, 0..) |_, i| {
        if (!s.name(i)) continue;
        const t = s.text(i);
        if (forced) |fixed| if (f.renamable(t, true)) if (fixed.get(t)) |new| {
            spell[i] = new;
            continue;
        };
        if (fresh.get(t)) |new| spell[i] = new;
    }
}

// ---------------------------------------------------------------------------
// Scope hoisting (`backend.md` §9, *One scope-hoisted file under `--release`*)
// ---------------------------------------------------------------------------

/// `import { a, b } from "<specifier>";` in a markup runtime, where the
/// specifier names the build's runtime module (`boundary.md` §9.2, *A
/// runtime module*): the statement's tokens and bytes, and the names it
/// imports. The file's own names ARE the module's: no `as`.
pub const ProgramImport = struct {
    /// Token range `[start, end)` of the statement.
    start: u32,
    end: u32,
    /// Its byte range.
    bytes_start: u32,
    bytes_end: u32,
    names: []const Named,
    /// Where an `as` is written in the braces, which is refused.
    renamed: ?u32 = null,

    pub const Named = struct { name: []const u8, offset: u32 };
};

/// Every `import { … } from "<specifier>"` statement of `source`, in order.
/// Null when the tokenizer refuses the file. A statement of another form
/// that names the specifier is not listed, and check 3 then finds its names
/// unbound or the build finds nothing to rewrite.
pub fn programImports(arena: Allocator, source: []const u8, tokens: []const Token, specifier: []const u8) Allocator.Error![]const ProgramImport {
    var out: std.ArrayList(ProgramImport) = .empty;
    var i: usize = 0;
    while (i + 4 < tokens.len) : (i += 1) {
        if (!isWord(tokens[i], source, "import") or !isPunct(tokens[i + 1], source, "{")) continue;
        if (i > 0 and !(isPunct(tokens[i - 1], source, ";") or isPunct(tokens[i - 1], source, "}"))) continue;
        var names: std.ArrayList(ProgramImport.Named) = .empty;
        var renamed: ?u32 = null;
        var j = i + 2;
        while (j < tokens.len and !isPunct(tokens[j], source, "}")) : (j += 1) {
            if (tokens[j].kind != .ident) continue;
            if (isWord(tokens[j], source, "as")) {
                renamed = renamed orelse tokens[j].start;
                continue;
            }
            try names.append(arena, .{ .name = tokens[j].text(source), .offset = tokens[j].start });
        }
        if (j + 2 >= tokens.len or !isWord(tokens[j + 1], source, "from") or tokens[j + 2].kind != .string) continue;
        const quoted = tokens[j + 2].text(source);
        if (!std.mem.eql(u8, quoted[1 .. quoted.len - 1], specifier)) continue;
        var end = j + 3;
        if (end < tokens.len and isPunct(tokens[end], source, ";")) end += 1;
        try out.append(arena, .{
            .start = @intCast(i),
            .end = @intCast(end),
            .bytes_start = tokens[i].start,
            .bytes_end = tokens[end - 1].end,
            .names = names.items,
            .renamed = renamed,
        });
        i = end - 1;
    }
    return out.items;
}

/// The names the program imports of `source` that the part of it `keep`'s
/// exports reach mentions, or every one of them when `keep` is null (a file
/// copied whole). Null when the file cannot be cut, which keeps it whole.
pub fn programUses(arena: Allocator, source: []const u8, specifier: []const u8, keep: ?[]const []const u8) Allocator.Error!?[]const []const u8 {
    const tokens = tokenize(arena, source) catch |err| switch (err) {
        error.Unsupported => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const imports = try programImports(arena, source, tokens, specifier);
    var names: std.StringArrayHashMapUnmanaged(bool) = .empty;
    for (imports) |imp| for (imp.names) |n| try names.put(arena, n.name, keep == null);
    if (keep) |wanted| {
        const c = try cut(arena, source, tokens, wanted) orelse return null;
        const inside = try arena.alloc(bool, tokens.len);
        @memset(inside, false);
        for (imports) |imp| @memset(inside[imp.start..imp.end], true);
        for (tokens, 0..) |t, at| {
            if (!c.mask[at] or inside[at] or t.kind != .ident or isProperty(tokens, source, at)) continue;
            if (names.getPtr(t.text(source))) |used| used.* = true;
        }
    }
    var out: std.ArrayList([]const u8) = .empty;
    var it = names.iterator();
    while (it.next()) |entry| if (entry.value_ptr.*) try out.append(arena, entry.key_ptr.*);
    return out.items;
}

/// A hand-written file read for a scope-hoisted build: cut to the exports
/// the build imports, with what the linker needs to put it in one module
/// scope with every other file of the program. `hoistable` returns null
/// where it cannot read the file exactly; `Hoisted.declines` says why a
/// file it read must still keep a module of its own.
pub const Hoisted = struct {
    source: []const u8,
    tokens: []const Token,
    structure: Structure,
    cut: Cut,
    /// A2's reading; null when the file mentions `eval`, `with` or `class`.
    facts: ?Facts,
    /// The surviving top-level bindings, in source order, which the linker
    /// numbers them in.
    tops: []const Top,
    /// Every export a surviving unit makes, with the binding it names.
    exports: []const Export,
    /// The surviving `import` statements, in order.
    imports: []const Import,
    /// Spellings the file writes and keeps: a top-level binding renamed into
    /// it would be captured wherever one of them is a binding.
    taken: Set,
    /// Names the file may read without binding them: nothing else in the
    /// one scope may be spelled like one.
    free: Set,
    /// Names the file assigns anywhere, or null when it cannot tell.
    assigned: ?Set,
    /// Every surviving unit but an `import` is inert (`shake`'s roots), so
    /// the file can be evaluated at any point without anyone seeing when.
    inert: bool,
    /// A surviving declaration destructures a pattern, whose names are
    /// top-level bindings the units do not list.
    patterned: bool,
    /// It mentions `import` outside a top-level `import` statement —
    /// `import.meta`, `import()` — whose meaning depends on the file it is in.
    located: bool,
    /// Its `import`s of the runtime module (`hoistableWith`): not imports
    /// of the one file, and printed as nothing.
    program: []const ProgramImport = &.{},

    pub const Top = struct {
        name: []const u8,
        /// A2 may give it another spelling. One it may not keeps its own,
        /// which the linker must then keep unique in the one scope.
        renamable: bool,
    };

    pub const Export = struct { name: []const u8, binding: []const u8 };

    pub const Import = struct {
        unit: Unit,
        /// The specifier, without its quotes.
        specifier: []const u8,
        /// Every identifier the statement spells but its keywords: more than
        /// it binds, never less.
        names: []const []const u8,
    };

    /// The binding an export names, or null.
    pub fn exportBinding(h: *const Hoisted, name: []const u8) ?[]const u8 {
        for (h.exports) |x| if (std.mem.eql(u8, x.name, name)) return x.binding;
        return null;
    }

    /// Why the file must keep a module of its own, or null when it can join
    /// the one scope.
    pub fn declines(h: *const Hoisted) ?[]const u8 {
        if (h.facts == null) return "it mentions `eval`, `with` or `class`, so no name in it can move";
        if (h.patterned) return "a top-level declaration destructures a pattern";
        if (h.located) return "it reads where it is, through `import.meta` or `import()`";
        for (h.imports) |imp| {
            if (!std.mem.startsWith(u8, imp.specifier, "node:")) return "it imports a module other than a `node:` built-in";
        }
        return null;
    }
};

/// Read `source` for a scope-hoisted build, cut to the exports `keep` names.
/// Null when the tokenizer or elimination refuses it, as `minify` does.
pub fn hoistable(arena: Allocator, source: []const u8, keep: []const []const u8) Allocator.Error!?Hoisted {
    return hoistableWith(arena, source, keep, null);
}

/// `hoistable`, for the markup runtime of a build with a runtime module
/// (`boundary.md` §9.2): an `import { … } from "<program>"` is no import
/// the one file keeps but names of the program's own scope, which the file
/// binds as the linker spells them (`Hoisted.program`, `backend.md` §15.1).
pub fn hoistableWith(arena: Allocator, source: []const u8, keep: []const []const u8, program: ?[]const u8) Allocator.Error!?Hoisted {
    const tokens = tokenize(arena, source) catch |err| switch (err) {
        error.Unsupported => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const c = try cut(arena, source, tokens, keep) orelse return null;
    const s: Structure = try .init(arena, source, tokens);
    const program_imports: []const ProgramImport = if (program) |spec| try programImports(arena, source, tokens, spec) else &.{};
    const ignore = try arena.alloc(bool, tokens.len);
    @memset(ignore, false);
    for (program_imports) |imp| @memset(ignore[imp.start..imp.end], true);
    var f = try factsIgnoring(arena, &s, c.mask, ignore);
    for (program_imports) |imp| {
        if (imp.renamed != null) return null;
        // Bound by the file as far as renaming goes: the linker gives each
        // the spelling of the declaration it names.
        if (f) |*ff| for (imp.names) |n| try ff.bound.put(arena, n.name, {});
    }

    var tops: std.ArrayList(Hoisted.Top) = .empty;
    var exports: std.ArrayList(Hoisted.Export) = .empty;
    var imports: std.ArrayList(Hoisted.Import) = .empty;
    var inert = true;
    var patterned = false;
    // Where a unit that is not the body's — an `import`, an `export { … }`
    // list — sits, so its names are neither read nor bound by the body.
    const outside = try arena.alloc(bool, tokens.len);
    @memset(outside, false);
    for (c.units, c.live) |u, live| {
        if (!live) continue;
        switch (u.kind) {
            .import => {
                @memset(outside[u.start..u.end], true);
                const of_program = for (program_imports) |imp| {
                    if (imp.start == u.start) break true;
                } else false;
                if (of_program) continue;
                var names: std.ArrayList([]const u8) = .empty;
                var specifier: []const u8 = "";
                for (u.start..u.end) |i| {
                    const t = tokens[i];
                    if (t.kind == .string) specifier = t.text(source)[1 .. t.text(source).len - 1];
                    if (t.kind != .ident) continue;
                    const w = t.text(source);
                    if (std.mem.eql(u8, w, "import") or std.mem.eql(u8, w, "from") or std.mem.eql(u8, w, "as")) continue;
                    try names.append(arena, w);
                }
                try imports.append(arena, .{ .unit = u, .specifier = specifier, .names = names.items });
            },
            .export_list => {
                @memset(outside[u.start..u.end], true);
                // `a as b` exports `b` and names `a`; `a` alone, both.
                var k: usize = u.start + 2;
                while (k < u.end) : (k += 1) {
                    if (tokens[k].kind != .ident) continue;
                    const local = tokens[k].text(source);
                    if (k + 2 < u.end and isWord(tokens[k + 1], source, "as")) {
                        try exports.append(arena, .{ .name = tokens[k + 2].text(source), .binding = local });
                        k += 2;
                    } else try exports.append(arena, .{ .name = local, .binding = local });
                }
            },
            .declaration, .function => {
                if (u.root) inert = false;
                if (u.pattern) patterned = true;
                for (u.binds) |name| try tops.append(arena, .{
                    .name = name,
                    .renamable = if (f) |ff| ff.renamable(name, true) else false,
                });
                for (u.exports) |name| try exports.append(arena, .{ .name = name, .binding = name });
            },
        }
    }

    // What the file keeps as written, and what it may read unbound.
    var taken: Set = .empty;
    var free: Set = .empty;
    var located = false;
    for (tokens, 0..) |_, i| {
        if (!s.name(i)) continue;
        const t = s.text(i);
        const moves = if (f) |ff| ff.renamable(t, true) else false;
        if (!moves) try taken.put(arena, t, {});
        if (c.mask[i] and !outside[i] and std.mem.eql(u8, t, "import")) located = true;
        if (!c.mask[i] or outside[i] or Print.isReservedWord(t)) continue;
        // `{ a: …` and `, a: …` are a key or a label: never a read.
        if (s.punct(i + 1, ":") and i > 0 and (s.punct(i - 1, "{") or s.punct(i - 1, ","))) continue;
        // A name the file imports is the import's wherever the file reads
        // it; one it only declares may still be read as a host's global
        // somewhere its declaration does not reach, which check 3 cannot
        // see, so a host's name is free even then.
        const imported = if (f) |ff| ff.imported.contains(t) else false;
        const binds = if (f) |ff| ff.bound.contains(t) else false;
        if (!imported and (!binds or fixedName(t))) try free.put(arena, t, {});
    }

    return .{
        .source = source,
        .tokens = tokens,
        .structure = s,
        .cut = c,
        .facts = f,
        .tops = tops.items,
        .exports = exports.items,
        .imports = imports.items,
        .taken = taken,
        .free = free,
        .assigned = try assignedNames(arena, &s, null),
        .inert = inert,
        .patterned = patterned,
        .located = located,
        .program = program_imports,
    };
}

/// A hoisted file's text: its body, and its `import` statements apart, for
/// the top of the one file.
pub const Printed = struct {
    body: []const u8,
    imports: []const []const u8,
};

/// Print a file `Hoisted.declines` accepted, with its top-level bindings
/// spelled as `forced` says and every other name renamed by A2 around them:
/// no `import`, no `export` keyword and no `export { … }` list in the body,
/// the `import` statements apart. Research 40's rewrites run as in `minify`.
pub fn printHoisted(arena: Allocator, h: *const Hoisted, forced: *const Forced) Allocator.Error!Printed {
    const tokens = h.tokens;
    const shown = try arena.dupe(bool, h.cut.mask);
    const spell = try arena.alloc(?[]const u8, tokens.len);
    @memset(spell, null);
    try assign(arena, &h.structure, shown, spell, &h.facts.?, forced);
    var imports: std.ArrayList([]const u8) = .empty;
    const alone = try arena.alloc(bool, tokens.len);
    for (h.cut.units, h.cut.live) |u, live| {
        if (!live) continue;
        switch (u.kind) {
            .import => {
                const of_program = for (h.program) |imp| {
                    if (imp.start == u.start) break true;
                } else false;
                if (of_program) {
                    @memset(shown[u.start..u.end], false);
                    continue;
                }
                @memset(alone, false);
                @memset(alone[u.start..u.end], true);
                const plan: Plan = .{ .shown = alone, .spell = spell };
                const text = try print(arena, h.source, tokens, plan);
                if (std.debug.runtime_safety) try verify(arena, h.source, tokens, plan, text);
                try imports.append(arena, text);
                @memset(shown[u.start..u.end], false);
            },
            .export_list => @memset(shown[u.start..u.end], false),
            .declaration, .function => if (isWord(tokens[u.start], h.source, "export")) {
                shown[u.start] = false;
            },
        }
    }
    try rewrite(arena, &h.structure, shown, spell);
    const plan: Plan = .{ .shown = shown, .spell = spell, .block_ends = try statementBlocks(arena, &h.structure) };
    const body = try print(arena, h.source, tokens, plan);
    if (std.debug.runtime_safety) try verify(arena, h.source, tokens, plan, body);
    return .{ .body = body, .imports = imports.items };
}

/// The names a parameter list at `open` binds: each element's identifier,
/// after an optional `...`, and an array pattern's own, one level down. An
/// object pattern's names are keys as well as bindings, and a default is an
/// expression; neither is listed.
fn bindParams(arena: Allocator, s: *const Structure, open: usize, bound: *std.StringHashMapUnmanaged(void)) Allocator.Error!void {
    var j = open + 1;
    var at_element = true;
    const end = s.close[open];
    while (j < end) {
        if (at_element) {
            var e = j;
            if (s.punct(e, "...")) e += 1;
            if (e < end and s.name(e)) try bound.put(arena, s.text(e), {});
            if (e < end and s.punct(e, "[")) try bindParams(arena, s, e, bound);
            at_element = false;
        }
        if (s.punct(j, ",")) at_element = true;
        j = s.next(j);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const fuzzing = @import("../fuzzing.zig");

fn expectMinified(source: []const u8, keep: ?[]const []const u8, want: ?[]const u8) !void {
    try expectWith(.{}, source, keep, want);
}

/// With research 40's two passes, as `--release` runs them.
fn expectReleased(source: []const u8, keep: ?[]const []const u8, want: ?[]const u8) !void {
    try expectWith(release, source, keep, want);
}

fn expectWith(options: Options, source: []const u8, keep: ?[]const []const u8, want: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const got = try minify(arena_state.allocator(), source, keep, options);
    if (want) |w| {
        if (got == null) return error.Refused;
        try testing.expectEqualStrings(w, got.?);
    } else try testing.expect(got == null);
}

test "A3: a semicolon before a closing brace goes unless it is an empty statement" {
    try expectReleased("function f() { g(); return 1; }\n", null, "function a(){g();return 1}\n");
    // After a statement head, `else`, `do` and a label the `;` is the
    // statement, and after `{` it is the block's only one.
    try expectReleased("function f(x) { if (x) ; }\n", null, "function b(a){if(a);}\n");
    try expectReleased("function f(x) { if (x) g(); else ; }\n", null, "function b(a){if(a)g();else;}\n");
    try expectReleased("function f() { L: ; }\n", null, "function a(){L:;}\n");
    try expectReleased("function f() { ; }\n", null, "function a(){;}\n");
    // A do-while's `while (…)` is a head too, so its `;` stays.
    try expectReleased("function f() { do g(); while (h()); }\n", null, "function a(){do g();while(h());}\n");
}

test "A3: a lone parameter loses its brackets, and const is let when nothing assigns one" {
    try expectReleased("export const f = (x) => x + 1;\n", null, "export const f=a=>a+1;\n");
    // A `const` inside a function is `let`; one at the top level stays,
    // because V8 folds a module-level `const` and not a `let`.
    try expectReleased("const k = 2;\nexport const f = (x) => { const y = x * k; return y; };\n", null, "const a=2;export const f=b=>{let c=b*a;return c};\n");
    // Two parameters, a default or a pattern keep theirs.
    try expectReleased("export const g = (x, y) => x;\nexport const h = (x = 1) => x;\n", null, "export const g=(a,b)=>a;export const h=(a=1)=>a;\n");
    // An assigned `const`, however it is assigned, keeps every `const` of
    // the file: the `TypeError` is the program's behaviour.
    try expectReleased("const a = 1;\nexport const f = () => { a = 2; };\n", null, "const a=1;export const f=()=>{a=2};\n");
    try expectReleased("const a = 1;\nexport const f = () => a++;\n", null, "const a=1;export const f=()=>a++;\n");
    try expectReleased("const a = [1];\nexport const f = (b) => { [a] = b; };\n", null, "const a=[1];export const f=b=>{[a]=b};\n");
    try expectReleased("const a = 1;\nexport const f = (o) => { for (a of o); };\n", null, "const a=1;export const f=b=>{for(a of b);};\n");
    // An element assignment is not one, and a `let` may be assigned. A name
    // is all this reads, so a `let` assigned anywhere keeps a `const` of the
    // same name elsewhere — and then every `const`.
    try expectReleased("export const f = () => { const i = 1; return i; };\nexport const g = () => { let i = 0; i = 1; return i; };\n", null, "export const f=()=>{const a=1;return a};export const g=()=>{let a=0;a=1;return a};\n");
    try expectReleased("const a = [1];\nlet n = 0;\nexport const f = () => { a[0] = 2; n += 1; };\n", null, "const a=[1];let b=0;export const f=()=>{a[0]=2;b+=1};\n");
}

test "A3: const is let when only a unit elimination cut assigns the name" {
    // `g`, which assigns `i`, is cut: nothing it does can happen, so `f`'s
    // `const i` may be a `let`. Kept, it keeps every `const`.
    const source = "export const f = () => { const i = 1; return i; };\nexport const g = () => { let i = 0; i = 1; return i; };\n";
    try expectReleased(source, &.{"f"}, "export const f=()=>{let a=1;return a};\n");
    try expectReleased(source, &.{ "f", "g" }, "export const f=()=>{const a=1;return a};export const g=()=>{let a=0;a=1;return a};\n");
}

test "a newline after the brace of a block statement goes, and after an arrow's body stays" {
    // An `if`, `else`, loop, `try`/`catch`/`finally`, `switch` and function
    // declaration body ends its statement; an arrow's does not.
    try expectReleased("export function f(a) {\n  if (a) { g(); }\n  return a;\n}\n", null, "export function f(a){if(a){g()}return a}\n");
    try expectReleased("export function f(a) {\n  for (;;) { g(); }\n  h();\n}\n", null, "export function f(a){for(;;){g()}h()}\n");
    try expectReleased("export function f(a) {\n  try { g(); } catch (e) { h(); }\n  finally { k(); }\n  return;\n}\n", null, "export function f(a){try{g()}catch(b){h()}finally{k()}return}\n");
    try expectReleased("export function f(a) {\n  switch (a) { case 1: g(); }\n  h();\n}\n", null, "export function f(a){switch(a){case 1:g()}h()}\n");
    try expectReleased("function g() {}\nfunction h() {}\nexport const f = () => g(h());\n", null, "function a(){}function b(){}export const f=()=>a(b());\n");
    try expectReleased("export const f = () => {}\nf()\n", null, "export const f=()=>{}\nf()\n");
    try expectReleased("export let f = function () {}\nf()\n", null, "export let f=function(){}\nf()\n");
}

test "A2: bound names are renamed most-used first; exports, imports, keys and globals keep theirs" {
    try expectReleased(
        \\import process from "node:process";
        \\const helper = (value) => value + value;
        \\export const run = (program) => {
        \\  const document = helper(program.size);
        \\  return { helper: document, program, [program.key]: Math.max(document, 1) };
        \\};
    ,
        null,
        // `value` is `a`. `program` is also a shorthand property and
        // `helper` a key, so both keep their names; `document` is a host
        // global, which a local may not take from the reads of the real one.
        "import process from\"node:process\";const helper=a=>a+a;export const run=program=>{let document=helper(program.size);return{helper:document,program,[program.key]:Math.max(document,1)}};\n",
    );
    try expectReleased("const long = 1;\nexport const f = (x) => long + x + long;\n", null, "const a=1;export const f=b=>a+b+a;\n");
    // A name the file spells anywhere as a non-binding is never handed out:
    // `a` and `b` are keys here.
    try expectReleased("const k = 1;\nexport const f = () => ({ a: k, b: k });\n", null, "const c=1;export const f=()=>({a:c,b:c});\n");
    // A ternary's consequent and a `case` read the name; a label keeps it.
    try expectReleased("export const f = (x, y) => x ? y : x;\n", null, "export const f=(a,b)=>a?b:a;\n");
}

test "A2: a file with eval, with or a class keeps every name, and with eval every const" {
    try expectReleased("const long = 1;\nexport const f = () => eval(\"long\");\n", null, "const long=1;export const f=()=>eval(\"long\");\n");
    try expectReleased("const long = 1;\nexport class A { m(long) { return long; } }\n", null, "const long=1;export class A{m(long){return long}}\n");
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

test "hoisting: top-level names take the linker's spellings, and the file's module syntax leaves its body" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const h = (try hoistable(arena,
        \\import process from "node:process";
        \\const helper = (value) => value + 1;
        \\export const run = (a) => process.exit(helper(a));
        \\const unused = () => 2;
        \\export { helper as step };
        \\
    , &.{ "run", "step" })).?;
    try testing.expect(h.declines() == null);
    try testing.expect(h.inert);
    try testing.expectEqual(@as(usize, 2), h.tops.len);
    try testing.expectEqualStrings("helper", h.exportBinding("step").?);
    try testing.expectEqualStrings("node:process", h.imports[0].specifier);
    // `process` is read as the import binds it; `exit` is a property.
    try testing.expect(h.taken.contains("process"));
    try testing.expect(!h.free.contains("process"));
    try testing.expect(!h.free.contains("exit"));

    var forced: Forced = .empty;
    try forced.put(arena, "helper", "a");
    try forced.put(arena, "run", "b");
    const printed = try printHoisted(arena, &h, &forced);
    try testing.expectEqualStrings("import process from\"node:process\";\n", printed.imports[0]);
    // The locals avoid `a` and `b`, which a local would capture.
    try testing.expectEqualStrings("const a=c=>c+1;const b=d=>process.exit(a(d));\n", printed.body);
}

test "hoisting: a name read unbound is free, and a key after { or , is not" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const h = (try hoistable(arena, "export const f = (x) => ({ a: x, b: document.title, c: x ? y : z });\n", &.{"f"})).?;
    try testing.expect(h.free.contains("document"));
    try testing.expect(h.free.contains("y"));
    try testing.expect(h.free.contains("z"));
    try testing.expect(!h.free.contains("a"));
    try testing.expect(!h.free.contains("b"));
    try testing.expect(!h.free.contains("title"));
    try testing.expect(!h.free.contains("x"));
}

test "hoisting: what cannot join one scope says why" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][]const u8{
        // A2 renames nothing in a file with a class.
        "export const f = () => new (class {})();\n",
        // `import.meta` means the file it is in.
        "export const f = () => import.meta.url;\n",
        // A pattern binds names the units do not list.
        "export const { f } = { f: 1 };\n",
        // A package might do anything when it is evaluated.
        "import x from \"pkg\";\nexport const f = () => x;\n",
    };
    for (cases) |source| {
        const h = (try hoistable(arena, source, &.{"f"})) orelse return error.Refused;
        try testing.expect(h.declines() != null);
    }
    // A top-level call is a unit this pass cannot delimit: not read at all.
    try testing.expect(try hoistable(arena, "f();\nexport const g = 1;\n", &.{"g"}) == null);
}

/// One file that ships in the box: it must be neither refused by the
/// tokenizer nor left uncut by elimination, or a release build would copy
/// it whole without saying so.
fn expectCompacted(path: []const u8, source: []const u8, program: ?[]const u8) !void {
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
    const got = (try minify(arena, source, null, release)).?;
    try testing.expect(got.len < source.len);
    // And it joins a release application's one scope rather than keeping a
    // module of its own (`backend.md` §9, *One scope-hoisted file under
    // `--release`*).
    const h = (try hoistableWith(arena, source, &.{}, program)).?;
    if (h.declines()) |why| {
        std.debug.print("{s} cannot be scope-hoisted: {s}\n", .{ path, why });
        return error.Refused;
    }
}

/// `beni:<Module>` for a manifest whose `"markup"` names a runtime module,
/// else null: the manifest's one `"module"` key, read as the embedded
/// manifests write it.
fn manifestModule(gpa: Allocator, manifest: []const u8) !?[]const u8 {
    const key = "\"module\"";
    const at = std.mem.indexOf(u8, manifest, key) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, manifest, at + key.len, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, manifest, open + 1, '"') orelse return null;
    return try std.fmt.allocPrint(gpa, "beni:{s}", .{manifest[open + 1 .. close]});
}

test "every hand-written file that ships in the box is compacted and cut" {
    const core_package = @import("core_package");
    const platform_packages = @import("platform_packages");
    var seen: u32 = 0;
    for (core_package.assets) |asset| {
        if (!std.mem.endsWith(u8, asset.path, ".js")) continue;
        try expectCompacted(asset.path, asset.bytes, null);
        seen += 1;
    }
    for (platform_packages.platforms) |platform| {
        // A platform whose markup runtime has a runtime module (`"module"`,
        // `boundary.md` §9.2): the file's import of it is the program's own
        // scope, not a module the one file keeps.
        const program = try manifestModule(testing.allocator, platform.manifest);
        defer if (program) |p| testing.allocator.free(p);
        for (platform.assets) |asset| {
            if (!std.mem.endsWith(u8, asset.path, ".js")) continue;
            try expectCompacted(asset.path, asset.bytes, program);
            seen += 1;
        }
    }
    // A zero would mean the embedding broke and this looked at nothing.
    try testing.expect(seen >= 10);
    // The derived-comparison engine a release build writes (`Emit`), which
    // is hand-written JavaScript too, minified already.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const engine = (try hoistable(arena_state.allocator(), @embedFile("derived_runtime.min.mjs"), &.{ "deep", "listEq", "listCompare" })).?;
    try testing.expect(engine.declines() == null);
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
        _ = try minify(a.allocator(), buf.items, null, .{});
        _ = try minify(a.allocator(), buf.items, &.{"a"}, .{});
        // Research 40's passes: `verify` holds the output to the plan's
        // spellings, so a rename that broke a token, or a dropped `;` or
        // bracket that changed how the rest lexes, panics here.
        _ = try minify(a.allocator(), buf.items, null, release);
        _ = try minify(a.allocator(), buf.items, &.{"a"}, release);
        // A scope-hoisted file: its top-level bindings forced to names no
        // piece spells, and `verify` holding the body to the plan.
        if (try hoistable(a.allocator(), buf.items, &.{"a"})) |h| if (h.declines() == null) {
            var forced: Forced = .empty;
            for (h.tops, 0..) |top, i| if (top.renamable) {
                try forced.put(a.allocator(), top.name, try std.fmt.allocPrint(a.allocator(), "Q{d}", .{i}));
            };
            _ = try printHoisted(a.allocator(), &h, &forced);
        };
    }
}
