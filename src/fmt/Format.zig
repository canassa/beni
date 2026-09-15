//! `beni fmt` (docs/design/language.md §9, frontend.md §3.7): the AST plus
//! the token and comment arrays and the line table → canonical text.
//!
//! Two passes, neither of which prints twice. `Measurer` walks the tree once
//! bottom-up and records, per node, the width of its single-line rendering
//! into a side array (`no_fit` when the node has no single-line form — a
//! `let`, a `case`, a multiline string — or when a comment sits inside its
//! token range, since a comment runs to the end of the line), together with
//! the node's first and last token. `Printer` walks the tree once more and,
//! at every point where the style offers a one-line and a vertical form,
//! asks "does this node fit in `max_width` columns from the current cursor"
//! by adding the recorded width to the current column. The three side
//! arrays are plain `[]u32` keyed by node index, allocated from the caller's
//! arena; nothing here allocates per node.
//!
//! Comments are not in the tree (language.md §2.3): each is keyed by the
//! significant token it precedes. The printer therefore never emits a token
//! without first emitting the own-line comments before it, and never
//! finishes a token without emitting the comment that trails it on its
//! source line. Because the two are handled at different moments, sorting
//! the imports moves a comment with the import it belongs to instead of
//! leaving it behind. The forced newline after a trailing comment is the
//! one place the printer deviates from the caller's layout: a comment that
//! trails a token the style would keep mid-line (`case x -- c` / `of`)
//! pushes the rest of the line to a continuation line, which re-parses and
//! re-formats to itself.
//!
//! Decisions §9 leaves open, pinned here and by the `tests/corpus/fmt`
//! goldens (the `AlreadyCanonical*` fixtures are the style's second
//! description; §9 wins where they disagree):
//!
//! - "Fits" means the whole line, from column 1 to the last character, is at
//!   most 100 bytes wide. Bytes, not code points: columns are bytes
//!   everywhere else in the front end (language.md §2.1).
//! - elm-format's rule for every multi-element construct — lists, records,
//!   record updates, tuples, record types, applications, constructor and
//!   type-constructor argument lists, arrow chains, operator chains: it is
//!   printed on one line when it fits AND the source has no line break
//!   between its elements (between the delimiters and the elements, between
//!   consecutive elements, between the head and its arguments, at an
//!   operator or arrow); a construct the author broke stays vertical even
//!   when it would fit; one that does not fit is broken. The measurer
//!   records a written break as "does not fit", and the saturating width
//!   sums carry it to every enclosing construct, so a vertical list inside
//!   a record keeps the record vertical too. `if`, `case` and `let` are
//!   always vertical: elm-format never writes a one-line `if`. Patterns
//!   are exempt (below) and so are lambdas: `\x ->` keeps its body on the
//!   line when the body is a one-line thing that fits.
//! - Binary operator chains flatten only the operators of ONE precedence
//!   level: `a > 0 && b < 1` broken at `&&` keeps `a > 0` on one line
//!   (`AlreadyCanonicalOperators`). elm-format breaks at every operator of
//!   the source's flat list; our AST has already resolved precedence, and
//!   breaking inside a tighter operand would reorder the reader's parse.
//! - A chain of exactly two operands whose second is a `let`, `case`, `if`
//!   or lambda prints the operator at the end of the first line and the
//!   block on the next line (`text <|` / `if …`), elm-format's shape for
//!   the `f <| \x -> …` idiom. Longer chains use the generic form.
//! - An `else if` chain continues on the `else` line, one `else if c then`
//!   per line. A head whose condition or scrutinee does not fit, or has a
//!   comment before `then`/`of`, becomes `if` / condition / `then` (and
//!   `case` / scrutinee / `of`) on three lines; the head itself is joined
//!   when it fits, whatever the source did. Bodies, bindings and branches
//!   sit at the line's indentation plus 4; `then`, `else`, `in` (and a
//!   `let` body) hang off the keyword's column, which only differs for a
//!   block that starts mid-line — `[ if c then` / `else` under `if`,
//!   `, let` / `in` under `let` — as elm-format lays them out.
//! - Grouping parentheses print without inner spaces — `(f x)`, `(a + b)`,
//!   `(Int -> Int)`, `(Just x)` in a pattern — and, when the inside is
//!   vertical, close on their own line at the opening column, as elm-format
//!   does. Tuples keep elm-format's inner spaces: `( a, b )`.
//! - A record field whose value does not fit after `name =` puts the value
//!   on the next line indented 4 from the field; a vertical record update
//!   puts the base on the `{` line and `| field` / `, field` under it,
//!   indented 4 from that line (elm-format), the brace closing at its own
//!   column.
//! - An application, a constructor's argument list and a type application
//!   follow elm-format: the arguments the source keeps on the head's line
//!   stay there when they fit (`div [ class "app" ]` / `[ … ]`,
//!   `Decode.map4 User` / fields), and from the first source break on every
//!   remaining argument gets its own line indented 4; an application with
//!   no source break that does not fit puts the function on its own line
//!   and every argument on a line of its own.
//! - A type annotation is one line or broken at EVERY arrow, the arrows
//!   leading continuation lines at the type's column; a `type alias` always
//!   has its body on the next line, whatever its width; `foreign` values
//!   follow annotations. A constructor's arguments follow the application
//!   rule above, the vertical ones indented 4 under the `|`.
//! - Own-line comments are indented like the token they precede, except
//!   before a keyword that closes a block — `in`, `else`, `then`, `of` on
//!   their own line — where they are indented with the block they close
//!   (`AlreadyCanonicalComments`). A blank line directly before an own-line
//!   comment is kept (at most one) whenever the previous line ends a value
//!   — a name, a literal, a closing bracket, another comment — and dropped
//!   after an opener (`=`, `->`, `let`, `[`, …). No blank line is kept
//!   between a comment and the token after it. Comments before the end of
//!   the file are separated from the last declaration like a declaration.
//! - The module doc block prints its comments in order, `--!` lines with the
//!   space inserted and blank lines inside the block dropped (two blocks
//!   merge, §2.3), then one blank line before whatever follows.
//! - Imports are sorted by module path with `std.mem.order` on the bytes,
//!   stable, one per line, exposing lists as written: `(Dict, string)`.
//! - Multiline strings put every `\\` line at the column of the first one;
//!   their bytes, like every literal's, are copied verbatim, trailing spaces
//!   included. Interpolations are copied verbatim too (`"${ a }"` keeps its
//!   spaces): a string is one literal.
//! - **Patterns are never broken across lines** (language.md §9). A `case`
//!   pattern, a definition's parameter list or a `let` pattern that does
//!   not fit overflows the 100-column guide; it is not wrapped, and a
//!   pattern the author broke is joined. The reason is that there is no
//!   wrapped form a reader could tell from the `->` that follows: the
//!   vertical form this printer used to produce put a lone `) ->` under a
//!   line that was still over the guide, which is worse on both counts. A
//!   pattern long enough to overflow is a signal to introduce a name. The
//!   same holds for the head line of a definition. Both places a pattern
//!   could break — a parenthesised pattern and a tuple or list pattern —
//!   therefore force the one-line form rather than consulting the width.
//! - An empty file formats to an empty file; otherwise the output ends in
//!   exactly one newline.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ast = @import("../parse/Ast.zig");
const Token = @import("../lex/Token.zig");
const Tokenizer = @import("../lex/Tokenizer.zig");
const Node = Ast.Node;
const Index = Node.Index;
const TokenIndex = Ast.TokenIndex;

/// Lines are at most this many bytes wide when a construct has a choice.
pub const max_width: u32 = 100;
/// Indentation of a nested block relative to its parent.
pub const indent_step: u32 = 4;

pub const Error = Allocator.Error || Io.Writer.Error || error{
    /// The tree has an error placeholder (or `errors` is non-empty): a file
    /// with syntax errors has no canonical form and is left untouched.
    SyntaxErrors,
};

const no_fit = std.math.maxInt(u32);

/// Print the canonical form of `tree` to `w`. `scratch` provides the side
/// arrays and the small chain stacks; an arena reset after the call is the
/// intended owner. `tokens`, `comments`, `source` and `line_starts` are the
/// file's lexical artifacts, read only.
pub fn format(
    scratch: Allocator,
    tree: *const Ast,
    tokens: *const Token.TokenList,
    comments: []const Token.Comment,
    source: [:0]const u8,
    line_starts: []const u32,
    w: *Io.Writer,
) Error!void {
    if (tree.errors.len != 0) return error.SyntaxErrors;
    const n = tree.nodes.len;
    const widths = try scratch.alloc(u32, n);
    const firsts = try scratch.alloc(u32, n);
    const lasts = try scratch.alloc(u32, n);
    var m: Measurer = .{
        .tree = tree,
        .tags = tokens.items(.tag),
        .starts = tokens.items(.start),
        .tok_lines = tokens.items(.line),
        .comments = comments,
        .source = source,
        .widths = widths,
        .firsts = firsts,
        .lasts = lasts,
        .scratch = scratch,
    };
    defer m.stack.deinit(scratch);
    try m.measureRoot();

    var p: Printer = .{
        .w = w,
        .source = source,
        .tags = tokens.items(.tag),
        .starts = tokens.items(.start),
        .tok_lines = tokens.items(.line),
        .comments = comments,
        .line_starts = line_starts,
        .tree = tree,
        .widths = widths,
        .firsts = firsts,
        .lasts = lasts,
        .scratch = scratch,
    };
    defer p.stack.deinit(scratch);
    try p.root();
}

// ---------------------------------------------------------------------------
// Operator tables (language.md §6.5)
// ---------------------------------------------------------------------------

fn precedence(tag: Node.Tag) u8 {
    return switch (tag) {
        .pipe_left, .pipe_right => 0,
        .bool_or => 2,
        .bool_and => 3,
        .eq, .neq, .lt, .gt, .lte, .gte => 4,
        .append, .cons => 5,
        .add, .sub => 6,
        .mul, .div, .int_div => 7,
        .pow => 8,
        else => unreachable, // callers check isBinop
    };
}

/// Whether the chain of a right-associative operator extends through the
/// right operand (else through the left; non-associative operators cannot
/// chain at all, so either answer is right for them).
fn rightAssociative(tag: Node.Tag) bool {
    return switch (tag) {
        .pipe_left, .bool_or, .bool_and, .append, .cons, .pow => true,
        else => false,
    };
}

fn isAccess(tag: Node.Tag) bool {
    return switch (tag) {
        .field_access, .tuple_index, .question => true,
        else => false,
    };
}

/// The four expression forms that may end an operator chain without
/// parentheses (language.md §3) and get elm-format's `op` at line end.
fn isBlockForm(tag: Node.Tag) bool {
    return switch (tag) {
        .let, .case, .@"if", .lambda => true,
        else => false,
    };
}

/// After a token of this kind a blank line before an own-line comment is
/// worth keeping: the line ends a value rather than opening a construct.
fn endsValue(tag: Token.Tag) bool {
    return switch (tag) {
        .lower_ident, .upper_ident, .qualified_lower, .qualified_upper, .dot_lower, .dot_index, .int, .float, .str_end, .multiline_line, .char, .r_paren, .r_bracket, .r_brace, .question, .underscore => true,
        else => false,
    };
}

/// Index of the first comment whose `before_token` is at least `t`.
fn firstCommentFrom(comments: []const Token.Comment, t: TokenIndex) usize {
    var lo: usize = 0;
    var hi: usize = comments.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (comments[mid].before_token < t) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The comments keyed by exactly `t`, in source order.
fn commentsBefore(comments: []const Token.Comment, t: TokenIndex) []const Token.Comment {
    const lo = firstCommentFrom(comments, t);
    var hi = lo;
    while (hi < comments.len and comments[hi].before_token == t) hi += 1;
    return comments[lo..hi];
}

// ---------------------------------------------------------------------------
// Pass 1: widths and token spans
// ---------------------------------------------------------------------------

const Measurer = struct {
    tree: *const Ast,
    tags: []const Token.Tag,
    starts: []const u32,
    tok_lines: []const u32,
    comments: []const Token.Comment,
    source: [:0]const u8,
    widths: []u32,
    firsts: []u32,
    lasts: []u32,
    scratch: Allocator,
    /// Spine nodes of the operator chain being measured (nested chains
    /// stack on top and shrink back).
    stack: std.ArrayList(u32) = .empty,

    /// The first token a declaration occupies: its visibility words in
    /// source order, else `fallback` (the keyword before the name).
    fn headerFirst(_: *const Measurer, h: Ast.DeclHeader, fallback: TokenIndex) TokenIndex {
        return h.pub_token.unwrap() orelse h.opaque_token.unwrap() orelse h.equatable_token.unwrap() orelse fallback;
    }

    fn tokenWidth(m: *const Measurer, t: TokenIndex) u32 {
        return Tokenizer.tokenEnd(m.source, m.tags[t], m.starts[t]) - m.starts[t];
    }

    fn w(m: *const Measurer, n: Index) u32 {
        return m.widths[n.int()];
    }

    fn first(m: *const Measurer, n: Index) u32 {
        return m.firsts[n.int()];
    }

    fn last(m: *const Measurer, n: Index) u32 {
        return m.lasts[n.int()];
    }

    /// Record `n`. A comment keyed by a token inside `(first_tok, last_tok]`
    /// would end the line in the middle of the single-line form, so the
    /// node does not fit then, whatever its width.
    fn set(m: *Measurer, n: Index, width: u32, first_tok: u32, last_tok: u32) void {
        const i = n.int();
        m.widths[i] = if (width != no_fit and m.commentIn(first_tok, last_tok)) no_fit else width;
        m.firsts[i] = first_tok;
        m.lasts[i] = last_tok;
    }

    /// Whether the source breaks a line between consecutive items of the
    /// sequence `prev_tok, elems…, close`: the construct was written
    /// vertically and stays so, whatever its width (elm-format's rule).
    fn brokenBetween(m: *const Measurer, prev_tok: TokenIndex, elems: []const Index, close: ?TokenIndex) bool {
        var prev = prev_tok;
        for (elems) |e| {
            if (m.tok_lines[m.first(e)] != m.tok_lines[prev]) return true;
            prev = m.last(e);
        }
        if (close) |c| return m.tok_lines[c] != m.tok_lines[prev];
        return false;
    }

    fn commentIn(m: *const Measurer, first_tok: u32, last_tok: u32) bool {
        const i = firstCommentFrom(m.comments, first_tok + 1);
        return i < m.comments.len and m.comments[i].before_token <= last_tok;
    }

    fn leaf(m: *Measurer, n: Index) void {
        const t = m.tree.nodeMainToken(n);
        m.set(n, m.tokenWidth(t), t, t);
    }

    /// `( a, b )` / `[ a, b ]` / `{ a = 1 }`: measure the elements and sum
    /// the inner spaces and separators, or `()`-style for none.
    fn collection(m: *Measurer, n: Index, elems: []const Index) Error!void {
        const open = m.tree.nodeMainToken(n);
        if (elems.len == 0) {
            m.set(n, 2, open, open + 1);
            return;
        }
        var sum: u32 = 0;
        for (elems) |e| {
            try m.measure(e);
            sum +|= m.w(e);
        }
        const close = m.last(elems[elems.len - 1]) + 1;
        const width = if (m.brokenBetween(open, elems, close)) no_fit else sum +| (2 * @as(u32, @intCast(elems.len)) + 2);
        m.set(n, width, open, close);
    }

    /// `{ r | a = 1 }`: like a collection with the base and its bar in front.
    fn extension(m: *Measurer, n: Index, base: TokenIndex, fields: []const Index) Error!void {
        const open = m.tree.nodeMainToken(n);
        var sum: u32 = 0;
        for (fields) |f| {
            try m.measure(f);
            sum +|= m.w(f);
        }
        const last_tok = if (fields.len == 0) base + 2 else m.last(fields[fields.len - 1]) + 1;
        const broken = m.tok_lines[base] != m.tok_lines[open] or m.brokenBetween(base, fields, last_tok);
        const width = if (broken) no_fit else m.tokenWidth(base) +| sum +| (2 * @as(u32, @intCast(fields.len)) + 5);
        m.set(n, width, open, last_tok);
    }

    /// `f a b` / `Just a` / `Maybe a`: the head and its arguments separated
    /// by single spaces.
    fn headed(m: *Measurer, n: Index, head_width: u32, first_tok: u32, head_last: u32, args: []const Index, keep_breaks: bool) Error!void {
        var width = head_width;
        var last_tok = head_last;
        for (args) |a| {
            try m.measure(a);
            width +|= 1 +| m.w(a);
            last_tok = m.last(a);
        }
        if (keep_breaks and m.brokenBetween(head_last, args, null)) width = no_fit;
        m.set(n, width, first_tok, last_tok);
    }

    /// `(x)`: two more than the inside, closing at the token after it.
    fn wrapped(m: *Measurer, n: Index, inner: Index) Error!void {
        try m.measure(inner);
        m.set(n, m.w(inner) +| 2, m.tree.nodeMainToken(n), m.last(inner) + 1);
    }

    /// `a -> b`, `x :: xs`: two operands around a fixed-width operator.
    fn pair(m: *Measurer, n: Index, lhs: Index, rhs: Index, op_width: u32) Error!void {
        try m.measure(lhs);
        try m.measure(rhs);
        m.set(n, m.w(lhs) +| op_width +| m.w(rhs), m.first(lhs), m.last(rhs));
    }

    /// The `str_end` of the string opened at `start`. Strings are single-line
    /// and cannot nest, so it is the next one.
    fn stringEnd(m: *const Measurer, start: TokenIndex) TokenIndex {
        var t = start;
        while (m.tags[t] != .str_end and m.tags[t] != .eof) t += 1;
        return t;
    }

    fn measureRoot(m: *Measurer) Error!void {
        for (m.tree.rootItems()) |item| try m.measure(item);
        m.set(.root, no_fit, 0, 0);
    }

    fn measure(m: *Measurer, n: Index) Error!void {
        const tree = m.tree;
        const tag = tree.nodeTag(n);
        const main = tree.nodeMainToken(n);
        if (tag.isError()) return error.SyntaxErrors;
        if (tag.isBinop()) return m.chain(n);
        if (isAccess(tag)) return m.access(n);
        switch (tag) {
            .root => unreachable, // measured by measureRoot
            .import => {
                const i = tree.fullImport(n);
                var last_tok = i.import_token;
                if (i.name) |t| last_tok = t;
                if (i.alias) |t| last_tok = t;
                for (i.exposed) |e| {
                    try m.measure(e);
                    last_tok = m.last(e) + 1; // the `)` after the last name
                }
                m.set(n, no_fit, main, last_tok);
            },
            .type_var => {
                // `equatable a` is two tokens and a space (checker.md
                // Appendix A); an unmarked variable is the bare leaf.
                if (tree.typeVarMarker(n)) |marker| {
                    m.set(n, m.tokenWidth(marker) + 1 + m.tokenWidth(main), marker, main);
                } else m.leaf(n);
            },
            .exposed, .int, .float, .char, .ident, .ctor, .accessor, .pat_var, .pat_int, .pat_char, .chunk => m.leaf(n),
            .annotation => {
                const a = tree.fullAnnotation(n);
                try m.measure(a.type_expr);
                const pub_width: u32 = if (a.header.pub_token != .none) 4 else 0;
                m.set(n, pub_width + m.tokenWidth(a.name) + 3 +| m.w(a.type_expr), a.header.pub_token.unwrap() orelse a.name, m.last(a.type_expr));
            },
            .definition => {
                const d = tree.fullDefinition(n);
                for (d.params) |p| try m.measure(p);
                try m.measure(d.body);
                m.set(n, no_fit, d.header.pub_token.unwrap() orelse d.name, m.last(d.body));
            },
            .type_alias => {
                const a = tree.fullTypeAlias(n);
                try m.measure(a.body);
                m.set(n, no_fit, a.header.pub_token.unwrap() orelse main - 2, m.last(a.body));
            },
            .type_decl => {
                const t = tree.fullTypeDecl(n);
                var last_tok = main;
                for (t.ctors) |c| {
                    try m.measure(c);
                    last_tok = m.last(c);
                }
                const first_tok = t.header.pub_token.unwrap() orelse t.header.opaque_token.unwrap() orelse main - 1;
                m.set(n, no_fit, first_tok, last_tok);
            },
            .constructor => try m.headed(n, m.tokenWidth(main), main, main, tree.children(n), true),
            .foreign_value => {
                const f = tree.fullForeignValue(n);
                try m.measure(f.type_expr);
                const pub_width: u32 = if (f.header.pub_token != .none) 4 else 0;
                m.set(n, pub_width + 8 + m.tokenWidth(f.name) + 3 +| m.w(f.type_expr), m.headerFirst(f.header, main - 1), m.last(f.type_expr));
            },
            .foreign_type => {
                const f = tree.fullForeignType(n);
                const last_tok = if (f.params.len == 0) main else f.params[f.params.len - 1];
                m.set(n, no_fit, m.headerFirst(f.header, main - 2), last_tok);
            },
            .type_con => try m.headed(n, m.tokenWidth(main), main, main, tree.children(n), true),
            .type_fn => {
                const d = tree.nodeData(n);
                try m.pair(n, @enumFromInt(d.lhs), @enumFromInt(d.rhs), 4);
                if (m.tok_lines[m.last(@enumFromInt(d.lhs))] != m.tok_lines[m.first(@enumFromInt(d.rhs))]) m.widths[n.int()] = no_fit;
            },
            .type_unit, .unit, .pat_unit => m.set(n, 2, main, main + 1),
            .placeholder => m.set(n, 1, main, main),
            .type_paren, .paren, .pat_paren => try m.wrapped(n, tree.operand(n)),
            .type_tuple, .type_record, .tuple, .list, .record, .pat_tuple, .pat_list => try m.collection(n, tree.children(n)),
            .type_record_ext => {
                const r = tree.fullTypeRecordExt(n);
                try m.extension(n, r.base, r.fields);
            },
            .record_update => {
                const r = tree.fullRecordUpdate(n);
                try m.extension(n, r.base, r.fields);
            },
            .record_type_field, .field => {
                const value = tree.operand(n);
                try m.measure(value);
                m.set(n, m.tokenWidth(main) + 3 +| m.w(value), main, m.last(value));
            },
            .string, .pat_string => {
                if (tag == .string) for (tree.children(n)) |part| try m.measure(part);
                const end = m.stringEnd(main);
                const width = Tokenizer.tokenEnd(m.source, m.tags[end], m.starts[end]) - m.starts[main];
                m.set(n, width, main, end);
            },
            .interp => {
                // Inside a string, which is copied verbatim; measured only
                // so every node has a span.
                const e = tree.operand(n);
                try m.measure(e);
                m.set(n, no_fit, main, m.last(e) + 1);
            },
            .multiline_string => {
                const s = tree.fullMultilineString(n);
                m.set(n, no_fit, s.first_line, s.last_line);
            },
            .op_fn => m.set(n, m.tokenWidth(main) + 2, main - 1, main + 1),
            .negate => {
                const e = tree.operand(n);
                try m.measure(e);
                m.set(n, 1 +| m.w(e), main, m.last(e));
            },
            .apply => {
                const all = tree.children(n);
                try m.measure(all[0]);
                try m.headed(n, m.w(all[0]), m.first(all[0]), m.last(all[0]), all[1..], true);
            },
            .lambda => {
                const l = tree.fullLambda(n);
                var width: u32 = 1;
                for (l.params, 0..) |p, i| {
                    try m.measure(p);
                    width +|= m.w(p) +| @as(u32, if (i == 0) 0 else 1);
                }
                try m.measure(l.body);
                m.set(n, width +| 4 +| m.w(l.body), main, m.last(l.body));
            },
            .@"if" => {
                const i = tree.fullIf(n);
                try m.measure(i.cond);
                try m.measure(i.then_expr);
                try m.measure(i.else_expr);
                m.set(n, no_fit, main, m.last(i.else_expr));
            },
            .let => {
                const l = tree.fullLet(n);
                for (l.bindings) |b| try m.measure(b);
                try m.measure(l.body);
                m.set(n, no_fit, main, m.last(l.body));
            },
            .let_def => {
                const l = tree.fullLetDef(n);
                for (l.params) |p| try m.measure(p);
                try m.measure(l.body);
                m.set(n, no_fit, main, m.last(l.body));
            },
            .let_annotation => {
                const t = tree.operand(n);
                try m.measure(t);
                m.set(n, m.tokenWidth(main) + 3 +| m.w(t), main, m.last(t));
            },
            .let_pattern => {
                const l = tree.fullLetPattern(n);
                try m.measure(l.pattern);
                try m.measure(l.value);
                m.set(n, no_fit, m.first(l.pattern), m.last(l.value));
            },
            // `x <- f a b` is one line whenever the call is (§9): the
            // binding is never broken before `<-`.
            .let_bind => {
                const l = tree.fullLetPattern(n);
                try m.measure(l.pattern);
                try m.measure(l.value);
                m.set(n, m.w(l.pattern) +| 4 +| m.w(l.value), m.first(l.pattern), m.last(l.value));
            },
            .case => {
                const c = tree.fullCase(n);
                try m.measure(c.scrutinee);
                var last_tok = m.last(c.scrutinee) + 1;
                for (c.branches) |b| {
                    try m.measure(b);
                    last_tok = m.last(b);
                }
                m.set(n, no_fit, main, last_tok);
            },
            .branch => {
                const b = tree.fullBranch(n);
                try m.measure(b.pattern);
                try m.measure(b.body);
                m.set(n, no_fit, m.first(b.pattern), m.last(b.body));
            },
            .pat_wild => m.set(n, 1, main, main),
            .pat_ctor => try m.headed(n, m.tokenWidth(main), main, main, tree.children(n), false),
            .pat_neg_int => m.set(n, 1 + m.tokenWidth(main + 1), main, main + 1),
            .pat_record => {
                const r = tree.fullPatRecord(n);
                var width: u32 = 4;
                for (r.fields, 0..) |f, i| width +|= m.tokenWidth(f) + @as(u32, if (i == 0) 0 else 2);
                const last_tok = if (r.fields.len == 0) main + 1 else r.fields[r.fields.len - 1] + 1;
                m.set(n, if (r.fields.len == 0) 2 else width, main, last_tok);
            },
            .pat_cons => {
                const d = tree.nodeData(n);
                try m.pair(n, @enumFromInt(d.lhs), @enumFromInt(d.rhs), 4);
            },
            .pat_as => {
                const a = tree.fullPatAs(n);
                try m.measure(a.pattern);
                m.set(n, m.w(a.pattern) +| 4 +| m.tokenWidth(a.name), m.first(a.pattern), a.name);
            },
            else => unreachable, // binops, access and errors are dispatched above
        }
    }

    /// An operator chain of one precedence level, measured without
    /// recursing along its spine: `a |> f |> g |> …` nests left-deep as far
    /// as the file is long, and the parser's depth limit does not count
    /// left-associative operators.
    fn chain(m: *Measurer, top: Index) Error!void {
        const mark = m.stack.items.len;
        defer m.stack.shrinkRetainingCapacity(mark);
        const tag = m.tree.nodeTag(top);
        const prec = precedence(tag);
        const right = rightAssociative(tag);
        var node = top;
        try m.stack.append(m.scratch, node.int());
        while (true) {
            const d = m.tree.nodeData(node);
            const next: Index = @enumFromInt(if (right) d.rhs else d.lhs);
            const next_tag = m.tree.nodeTag(next);
            if (!next_tag.isBinop() or precedence(next_tag) != prec) break;
            try m.stack.append(m.scratch, next.int());
            node = next;
        }
        const count = m.stack.items.len - mark;
        // The operand each spine node owns on its off-spine side, then the
        // innermost node's on-spine operand. Nested chains may grow the
        // stack, so every spine entry is re-read through the index.
        for (0..count) |i| {
            const s: Index = @enumFromInt(m.stack.items[mark + i]);
            const d = m.tree.nodeData(s);
            try m.measure(@enumFromInt(if (right) d.lhs else d.rhs));
        }
        {
            const innermost: Index = @enumFromInt(m.stack.items[mark + count - 1]);
            const d = m.tree.nodeData(innermost);
            try m.measure(@enumFromInt(if (right) d.rhs else d.lhs));
        }
        var i = count;
        while (i > 0) {
            i -= 1;
            const s: Index = @enumFromInt(m.stack.items[mark + i]);
            const d = m.tree.nodeData(s);
            const lhs: Index = @enumFromInt(d.lhs);
            const rhs: Index = @enumFromInt(d.rhs);
            const op_tok = m.tree.nodeMainToken(s);
            const op_line = m.tok_lines[op_tok];
            const broken = op_line != m.tok_lines[m.last(lhs)] or op_line != m.tok_lines[m.first(rhs)] or
                m.trailingLambdaBroken(tag, rhs);
            const op_width = m.tokenWidth(op_tok) + 2;
            m.set(s, if (broken) no_fit else m.w(lhs) +| op_width +| m.w(rhs), m.first(lhs), m.last(rhs));
        }
    }

    /// A trailing `<|` lambda whose body the author put on its own line
    /// keeps the chain vertical, exactly as a break at the operator does.
    /// The printer's flat form for this case (§9) puts its own break there
    /// rather than before the operator, so without this the two forms would
    /// swap on every reformat instead of being a fixed point.
    fn trailingLambdaBroken(m: *const Measurer, op: Node.Tag, rhs: Index) bool {
        if (op != .pipe_left or m.tree.nodeTag(rhs) != .lambda) return false;
        const l = m.tree.fullLambda(rhs);
        return m.tok_lines[m.first(l.body)] != m.tok_lines[m.first(rhs)];
    }

    /// `x.a.b?`: the base and then the glued suffix tokens, which are
    /// exactly the tokens after the base's last one up to the top's main
    /// token (language.md §3: no whitespace before `.field` / `.0`).
    fn access(m: *Measurer, top: Index) Error!void {
        var base = top;
        while (isAccess(m.tree.nodeTag(base))) base = m.tree.operand(base);
        try m.measure(base);
        const base_last = m.last(base);
        const top_tok = m.tree.nodeMainToken(top);
        var suffix: u32 = 0;
        var t = base_last + 1;
        while (t <= top_tok) : (t += 1) suffix +|= m.tokenWidth(t);
        var node = top;
        while (isAccess(m.tree.nodeTag(node))) {
            const tok = m.tree.nodeMainToken(node);
            m.set(node, m.w(base) +| suffix, m.first(base), tok);
            suffix -= m.tokenWidth(tok);
            node = m.tree.operand(node);
        }
    }
};

// ---------------------------------------------------------------------------
// Pass 2: printing
// ---------------------------------------------------------------------------

const Printer = struct {
    w: *Io.Writer,
    source: [:0]const u8,
    tags: []const Token.Tag,
    starts: []const u32,
    tok_lines: []const u32,
    comments: []const Token.Comment,
    line_starts: []const u32,
    tree: *const Ast,
    widths: []const u32,
    firsts: []const u32,
    lasts: []const u32,
    scratch: Allocator,
    /// Flattened operator chains and type arrows being printed.
    stack: std.ArrayList(u32) = .empty,

    /// Bytes written on the current line.
    col: u32 = 0,
    /// Newlines owed before the next text; written lazily so a trailing
    /// comment can still land on the line being finished.
    pending: u32 = 0,
    /// A separating space owed before the next text, written lazily for the
    /// same reason: an own-line comment (or anything else) may end the line
    /// first, and §9 forbids trailing whitespace. Dropped, never written, if
    /// the line ends before any text follows it.
    pending_space: bool = false,
    /// Indentation the next line starts with, once `pending` is flushed.
    next_indent: u32 = 0,
    /// Indentation of the current line: the fallback for a continuation
    /// line the caller did not plan (after a trailing comment).
    line_indent: u32 = 0,
    wrote_anything: bool = false,
    /// A token whose leading comments the caller printed itself (at an
    /// indentation or with a blank-line rule of its own).
    leading_done: ?TokenIndex = null,
    /// A token whose trailing comment the caller printed itself (a comma's,
    /// hoisted after the element before it).
    trailing_done: ?TokenIndex = null,
    /// Inside a `<-` binding, which prints on one line and is never broken
    /// (§9): every width test answers "it fits" while this is set, so the
    /// binding overflows the guide the way a pattern does instead of
    /// wrapping. A construct that is vertical whatever its width — `let`,
    /// `if`, `case` — still breaks, and so does anything with a comment
    /// inside it, which cannot be printed on one line at all.
    flat: bool = false,

    const Kind = enum { expr, field, type, type_field, pattern };

    // ---- Low-level text -------------------------------------------------

    /// Where the next character lands.
    fn curCol(p: *const Printer) u32 {
        if (p.pending > 0) return p.next_indent;
        return p.col + @intFromBool(p.pending_space);
    }

    fn flush(p: *Printer) Io.Writer.Error!void {
        if (p.pending == 0) return;
        if (p.wrote_anything) try p.w.splatByteAll('\n', p.pending);
        try p.w.splatByteAll(' ', p.next_indent);
        p.col = p.next_indent;
        p.line_indent = p.next_indent;
        p.pending = 0;
    }

    fn raw(p: *Printer, bytes: []const u8) Io.Writer.Error!void {
        if (p.pending_space) {
            p.pending_space = false;
            // A line break came between the space and this text: the space
            // would have been left at the end of the previous line.
            if (p.pending == 0) {
                try p.w.writeAll(" ");
                p.col += 1;
            }
        }
        try p.flush();
        try p.w.writeAll(bytes);
        p.col += @intCast(bytes.len);
        p.wrote_anything = true;
    }

    fn space(p: *Printer) Io.Writer.Error!void {
        p.pending_space = true;
    }

    /// End the line; the next text starts at `indent`.
    fn newline(p: *Printer, indent: u32) void {
        p.pending = @max(p.pending, 1);
        p.next_indent = indent;
    }

    /// End the line and leave `count` blank lines.
    fn blankLines(p: *Printer, count: u32, indent: u32) void {
        p.pending = @max(p.pending, count + 1);
        p.next_indent = indent;
    }

    fn finish(p: *Printer) Io.Writer.Error!void {
        if (p.wrote_anything) try p.w.writeByte('\n');
    }

    // ---- Fit checks ------------------------------------------------------

    fn fits(p: *const Printer, n: Index) bool {
        return p.fitsAt(n, p.curCol());
    }

    fn fitsAt(p: *const Printer, n: Index, col: u32) bool {
        const width = p.widths[n.int()];
        if (p.flat and !p.commentIn(n)) return true;
        return width != no_fit and col +| width <= max_width;
    }

    /// Whether `n` spans an `if`, `let` or `case` keyword — the three forms
    /// that are vertical whatever their width, so no claim that they fit on
    /// one line can be honoured.
    fn hasBlockKeyword(p: *const Printer, n: Index) bool {
        var t = p.first(n);
        const end = p.last(n);
        while (t <= end) : (t += 1) switch (p.tags[t]) {
            .keyword_if, .keyword_let, .keyword_case => return true,
            else => {},
        };
        return false;
    }

    /// Whether a comment sits inside `n` (its own leading one excluded).
    fn commentIn(p: *const Printer, n: Index) bool {
        const i = firstCommentFrom(p.comments, p.first(n) + 1);
        return i < p.comments.len and p.comments[i].before_token <= p.last(n);
    }

    /// Whether `n` fits at the cursor with `extra` more bytes after it on
    /// the same line and no comment before `until` (the token after it).
    fn fitsWith(p: *const Printer, n: Index, extra: u32, until: TokenIndex) bool {
        const width = p.widths[n.int()];
        if (width == no_fit or p.curCol() +| width +| extra > max_width) return false;
        return commentsBefore(p.comments, until).len == 0;
    }

    fn first(p: *const Printer, n: Index) TokenIndex {
        return p.firsts[n.int()];
    }

    fn last(p: *const Printer, n: Index) TokenIndex {
        return p.lasts[n.int()];
    }

    // ---- Tokens and comments ---------------------------------------------

    fn text(p: *const Printer, t: TokenIndex) []const u8 {
        return Tokenizer.slice(p.source, p.tags[t], p.starts[t]);
    }

    /// The comment's bytes to the end of its line, trailing spaces dropped
    /// (a comment is not a literal; §9 forbids trailing whitespace).
    fn commentText(p: *const Printer, c: Token.Comment) []const u8 {
        const end = Tokenizer.tokenEnd(p.source, .multiline_line, c.start);
        return std.mem.trimEnd(u8, p.source[c.start..end], " ");
    }

    /// 0-based line of a comment, from the line table.
    fn commentLine(p: *const Printer, c: Token.Comment) u32 {
        var lo: usize = 0;
        var hi: usize = p.line_starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (p.line_starts[mid] <= c.start) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo - 1);
    }

    /// Print a comment's text; doc and module-doc markers get the space
    /// §2.3 promises (`--|x` → `--| x`), plain comments print as written.
    fn writeComment(p: *Printer, c: Token.Comment) Io.Writer.Error!void {
        const t = p.commentText(c);
        if (c.kind != .plain and t.len > 3 and t[3] != ' ') {
            try p.raw(t[0..3]);
            try p.space();
            try p.raw(t[3..]);
        } else {
            try p.raw(t);
        }
    }

    /// The own-line comments before `t`, each on its own line at `indent`
    /// (or at the indentation the pending newline planned, or on a forced
    /// continuation line when the cursor is mid-line). A blank line before
    /// a comment is kept when the previous line ends a value.
    fn leading(p: *Printer, t: TokenIndex, indent: ?u32) Io.Writer.Error!void {
        return p.leadingWith(t, indent, true);
    }

    /// `leading`, with the blank line before the first comment kept only
    /// when `blank_ok` (an annotation's definition sits directly under it).
    fn leadingWith(p: *Printer, t: TokenIndex, indent: ?u32, blank_ok: bool) Io.Writer.Error!void {
        if (t == 0) return; // printed by `fileHead`
        if (p.leading_done == t) return;
        p.leading_done = t;
        const cs = commentsBefore(p.comments, t);
        if (cs.len == 0) return;
        var prev_line: u32 = p.tok_lines[t - 1];
        var allow_blank = blank_ok and endsValue(p.tags[t - 1]);
        for (cs) |c| {
            const line = p.commentLine(c);
            if (line == prev_line) continue; // trails the previous token: printed with it
            const blank = allow_blank and line > prev_line + 1;
            const ind = indent orelse if (p.pending > 0) p.next_indent else if (p.col == p.line_indent) p.line_indent else p.line_indent + indent_step;
            p.blankLines(if (blank) 1 else 0, ind);
            try p.writeComment(c);
            p.newline(ind);
            prev_line = line;
            allow_blank = true;
        }
    }

    /// The comment on `t`'s source line after it, if any: appended to the
    /// current line, which then must end.
    fn trailing(p: *Printer, t: TokenIndex) Io.Writer.Error!void {
        if (p.trailing_done == t) return;
        p.trailing_done = t;
        const cs = commentsBefore(p.comments, t + 1);
        for (cs) |c| {
            if (p.commentLine(c) != p.tok_lines[t]) break;
            try p.space();
            try p.writeComment(c);
            p.newline(p.line_indent + indent_step);
        }
    }

    /// Token `t` with its own-line comments before and its trailing comment
    /// after.
    fn tok(p: *Printer, t: TokenIndex) Io.Writer.Error!void {
        try p.leading(t, null);
        try p.tokRaw(t);
    }

    /// Token `t` and its trailing comment; the leading comments were
    /// printed by the caller (at a different indentation).
    fn tokRaw(p: *Printer, t: TokenIndex) Io.Writer.Error!void {
        try p.raw(p.text(t));
        try p.trailing(t);
    }

    /// A token the canonical form drops (a leading `|`): its comments are
    /// kept in place.
    fn skipTok(p: *Printer, t: TokenIndex) Io.Writer.Error!void {
        try p.leading(t, null);
        try p.trailing(t);
    }

    /// The source bytes of tokens `first_tok..last_tok` verbatim: a string
    /// literal with its interpolations.
    fn tokRange(p: *Printer, first_tok: TokenIndex, last_tok: TokenIndex) Io.Writer.Error!void {
        try p.leading(first_tok, null);
        const end = Tokenizer.tokenEnd(p.source, p.tags[last_tok], p.starts[last_tok]);
        try p.raw(p.source[p.starts[first_tok]..end]);
        try p.trailing(last_tok);
    }

    /// Whether a blank line separates token `a` from the token `b` that
    /// follows it (comments in between count as lines, not blanks).
    fn blankBetween(p: *const Printer, a: TokenIndex, b: TokenIndex) bool {
        var prev = p.tok_lines[a];
        for (commentsBefore(p.comments, b)) |c| {
            const line = p.commentLine(c);
            if (line > prev + 1) return true;
            prev = line;
        }
        return p.tok_lines[b] > prev + 1;
    }

    // ---- Module ----------------------------------------------------------

    fn root(p: *Printer) Error!void {
        try p.fileHead();
        const items = p.tree.rootItems();

        // Imports first, sorted by path; the parser keeps them in front of
        // every declaration (or reports the file, which is then not here).
        const mark = p.stack.items.len;
        defer p.stack.shrinkRetainingCapacity(mark);
        var decl_start: usize = items.len;
        for (items, 0..) |item, i| {
            if (p.tree.nodeTag(item) != .import) {
                decl_start = i;
                break;
            }
            try p.stack.append(p.scratch, item.int());
        }
        const imports = p.stack.items[mark..];
        const import_count = imports.len;
        std.mem.sort(u32, imports, p, importLessThan);
        for (imports, 0..) |item, i| {
            if (i > 0) p.newline(0);
            try p.import(@enumFromInt(item));
        }

        var prev: ?Index = null;
        for (items[decl_start..]) |item| {
            if (import_count > 0 or prev != null) {
                if (prev != null and p.tree.nodeTag(prev.?) == .annotation) {
                    p.newline(0);
                    try p.leadingWith(p.first(item), 0, false);
                } else {
                    p.blankLines(2, 0);
                }
            }
            try p.decl(item);
            prev = item;
        }

        // Comments at the end of the file precede `eof`.
        const eof: TokenIndex = @intCast(p.tags.len - 1);
        if (eof != 0 and commentsBefore(p.comments, eof).len != 0) {
            if (p.wrote_anything) p.blankLines(2, 0);
            try p.leading(eof, 0);
        }
        try p.finish();
    }

    fn importLessThan(p: *Printer, a: u32, b: u32) bool {
        const ia = p.tree.fullImport(@enumFromInt(a));
        const ib = p.tree.fullImport(@enumFromInt(b));
        const na = if (ia.name) |t| p.text(t) else "";
        const nb = if (ib.name) |t| p.text(t) else "";
        return std.mem.order(u8, na, nb) == .lt;
    }

    /// Everything before the first token: the module doc block (its lines
    /// in order, blank lines dropped, one blank line after) and any plain
    /// comments around it.
    fn fileHead(p: *Printer) Io.Writer.Error!void {
        const lo = firstCommentFrom(p.comments, 0);
        var hi = lo;
        while (hi < p.comments.len and p.comments[hi].before_token == 0) hi += 1;
        const doc = p.tree.module_doc;
        var prev_line: ?u32 = null;
        for (lo..hi) |i| {
            const c = p.comments[i];
            const line = p.commentLine(c);
            const in_doc = i >= doc.start and i < doc.end;
            const blank = !in_doc and prev_line != null and line > prev_line.? + 1;
            p.blankLines(if (blank) 1 else 0, 0);
            try p.writeComment(c);
            if (in_doc and i + 1 == doc.end) p.blankLines(1, 0) else p.newline(0);
            prev_line = line;
        }
    }

    fn import(p: *Printer, n: Index) Io.Writer.Error!void {
        const i = p.tree.fullImport(n);
        try p.tok(i.import_token);
        if (i.name) |t| {
            try p.space();
            try p.tok(t);
        }
        if (i.alias) |t| {
            try p.space();
            try p.tok(t - 1); // `as`
            try p.space();
            try p.tok(t);
        }
        if (i.exposing_token) |t| {
            try p.space();
            try p.tok(t);
            try p.space();
            try p.tok(t + 1); // `(`
            var close = t + 2;
            for (i.exposed, 0..) |e, k| {
                const name = p.tree.nodeMainToken(e);
                if (k > 0) {
                    try p.tok(name - 1); // `,`
                    try p.space();
                }
                try p.tok(name);
                close = name + 1;
            }
            try p.tok(close);
        }
    }

    // ---- Declarations ----------------------------------------------------

    fn header(p: *Printer, h: Ast.DeclHeader) Io.Writer.Error!void {
        if (h.pub_token.unwrap()) |t| {
            try p.tok(t);
            try p.space();
        }
        if (h.opaque_token.unwrap()) |t| {
            try p.tok(t);
            try p.space();
        }
        if (h.equatable_token.unwrap()) |t| {
            try p.tok(t);
            try p.space();
        }
    }

    fn decl(p: *Printer, n: Index) Error!void {
        const tree = p.tree;
        const main = tree.nodeMainToken(n);
        switch (tree.nodeTag(n)) {
            .annotation => {
                const a = tree.fullAnnotation(n);
                try p.header(a.header);
                try p.tok(a.name);
                try p.space();
                try p.tok(a.name + 1); // `:`
                try p.annotated(a.type_expr, 0);
            },
            .definition => {
                const d = tree.fullDefinition(n);
                try p.header(d.header);
                try p.tok(d.name);
                try p.defBody(d.name, d.params, d.body, 0);
            },
            .type_alias => {
                const a = tree.fullTypeAlias(n);
                try p.header(a.header);
                try p.tok(main - 2); // `type`
                try p.space();
                try p.tok(main - 1); // `alias`
                try p.space();
                try p.tok(a.name);
                var eq = a.name + 1;
                for (a.params) |t| {
                    try p.space();
                    try p.tok(t);
                    eq = t + 1;
                }
                try p.space();
                try p.tok(eq);
                p.newline(indent_step);
                try p.typ(a.body, indent_step);
            },
            .type_decl => {
                const t = tree.fullTypeDecl(n);
                try p.header(t.header);
                try p.tok(main - 1); // `type`
                try p.space();
                try p.tok(t.name);
                var eq = t.name + 1;
                for (t.params) |param| {
                    try p.space();
                    try p.tok(param);
                    eq = param + 1;
                }
                p.newline(indent_step);
                try p.tok(eq);
                if (p.tags[eq + 1] == .pipe) try p.skipTok(eq + 1); // a leading `|` is dropped (§3)
                for (t.ctors, 0..) |c, i| {
                    if (i > 0) {
                        p.newline(indent_step);
                        try p.tok(p.first(c) - 1); // `|`
                    }
                    try p.space();
                    try p.constructor(c, indent_step);
                }
            },
            .foreign_value => {
                const f = tree.fullForeignValue(n);
                try p.header(f.header);
                try p.tok(main - 1); // `foreign`
                try p.space();
                try p.tok(f.name);
                try p.space();
                try p.tok(f.name + 1); // `:`
                try p.annotated(f.type_expr, 0);
            },
            .foreign_type => {
                const f = tree.fullForeignType(n);
                try p.header(f.header);
                try p.tok(main - 2); // `foreign`
                try p.space();
                try p.tok(main - 1); // `type`
                try p.space();
                try p.tok(f.name);
                for (f.params) |t| {
                    try p.space();
                    try p.tok(t);
                }
            },
            else => return error.SyntaxErrors,
        }
    }

    /// `name : Type` on one line when it fits, else `name :` and the type
    /// on the next line, broken at every arrow (§9).
    fn annotated(p: *Printer, t: Index, indent: u32) Error!void {
        if (p.fitsAt(t, p.curCol() + 1)) {
            try p.space();
            try p.typ(t, indent);
        } else {
            p.newline(indent + indent_step);
            if (p.tree.nodeTag(t) == .type_fn) {
                try p.arrows(t, indent + indent_step, true);
            } else {
                try p.typ(t, indent + indent_step);
            }
        }
    }

    /// ` params =` and the body on the next line, for top-level and `let`
    /// definitions alike.
    fn defBody(p: *Printer, name: TokenIndex, params: []const Index, body: Index, indent: u32) Error!void {
        var eq = name + 1;
        for (params) |param| {
            try p.space();
            try p.pat(param, indent);
            eq = p.last(param) + 1;
        }
        try p.space();
        try p.tok(eq);
        p.newline(indent + indent_step);
        try p.expr(body, indent + indent_step);
    }

    fn constructor(p: *Printer, n: Index, indent: u32) Error!void {
        const c = p.tree.fullConstructor(n);
        // Measured BEFORE the name is printed: `widths[n]` spans the whole
        // node, name included, so asking after printing it charges the name
        // twice and breaks a construct that fits (see `.type_con`).
        const one_line = p.fits(n);
        try p.tok(c.name);
        try p.args(c.name, c.args, .type, one_line, indent);
    }

    /// Arguments after a head whose last token is `head_last`. All on the
    /// head's line when `one_line` (the caller checked the width and the
    /// source has no break). Otherwise elm-format's shape: the arguments
    /// the source keeps on the head's line stay there when they fit
    /// (`div [ class "app" ]`, `Decode.map4 User`), and from the first
    /// source break on every remaining argument gets its own line indented
    /// 4; an application with no source break that does not fit puts every
    /// argument on its own line.
    fn args(p: *Printer, head_last: TokenIndex, list: []const Index, comptime kind: Kind, one_line: bool, indent: u32) Error!void {
        var inline_count: usize = 0;
        if (one_line) {
            inline_count = list.len;
        } else {
            var prev = head_last;
            while (inline_count < list.len and p.tok_lines[p.first(list[inline_count])] == p.tok_lines[prev]) : (inline_count += 1) {
                prev = p.last(list[inline_count]);
            }
            if (inline_count == list.len) inline_count = 0; // no source break: it simply did not fit
            var width: u32 = 0;
            for (list[0..inline_count]) |a| width +|= 1 +| p.widths[a.int()];
            if (p.curCol() +| width > max_width) inline_count = 0;
        }
        for (list, 0..) |a, i| {
            if (i < inline_count) {
                try p.space();
                try p.node(a, kind, indent);
            } else {
                p.newline(indent + indent_step);
                try p.node(a, kind, indent + indent_step);
            }
        }
    }

    // ---- Dispatch --------------------------------------------------------

    fn node(p: *Printer, n: Index, comptime kind: Kind, indent: u32) Error!void {
        switch (kind) {
            .expr => try p.expr(n, indent),
            .field => try p.field(n, indent),
            .type => try p.typ(n, indent),
            .type_field => try p.typeField(n, indent),
            .pattern => try p.pat(n, indent),
        }
    }

    /// `( a, b )` on one line, or the vertical form with the delimiters
    /// leading each line at the column of the opening one. Elements start
    /// two past that column; their continuation lines four past it.
    fn collection(p: *Printer, n: Index, elems: []const Index, comptime kind: Kind, indent: u32) Error!void {
        const open = p.tree.nodeMainToken(n);
        const one_line = kind == .pattern or p.fits(n);
        const col = p.curCol();
        try p.tok(open);
        if (elems.len == 0) {
            try p.tok(open + 1);
            return;
        }
        try p.space();
        for (elems, 0..) |e, i| {
            if (i > 0) {
                if (!one_line) p.newline(col);
                try p.tok(p.last(elems[i - 1]) + 1); // `,`
                try p.space();
            }
            try p.node(e, kind, if (one_line) indent else col);
            // A comment trailing the comma in the source stays on the
            // element's line; the comma itself moves to the next one.
            if (i + 1 < elems.len) try p.trailing(p.last(e) + 1);
        }
        if (one_line) try p.space() else p.newline(col);
        try p.tok(p.last(elems[elems.len - 1]) + 1);
    }

    /// `{ r | a = 1 }`, or vertically the base on the brace line and each
    /// field under it after `|` / `,`, indented 4 from the line the brace
    /// is on (elm-format indents from the line, and the corpus is written
    /// that way: `, { cache` / `    | field`), the brace closing at its
    /// own column.
    fn extension(p: *Printer, n: Index, base: TokenIndex, fields: []const Index, comptime kind: Kind) Error!void {
        const open = p.tree.nodeMainToken(n);
        const one_line = p.fits(n);
        const col = p.curCol();
        const inner = p.lineIndent() + indent_step;
        try p.tok(open);
        try p.space();
        try p.tok(base);
        for (fields, 0..) |f, i| {
            if (!one_line) p.newline(inner) else if (i == 0) try p.space();
            try p.tok(if (i == 0) base + 1 else p.last(fields[i - 1]) + 1); // `|` or `,`
            try p.space();
            try p.node(f, kind, if (one_line) col else inner);
            if (i + 1 < fields.len) try p.trailing(p.last(f) + 1); // the comma's comment, hoisted
        }
        if (one_line) try p.space() else p.newline(col);
        try p.tok(if (fields.len == 0) base + 2 else p.last(fields[fields.len - 1]) + 1);
    }

    /// `(x)`, closing on its own line when the inside is vertical.
    fn wrapped(p: *Printer, n: Index, comptime kind: Kind, indent: u32) Error!void {
        const inner = p.tree.operand(n);
        const open = p.tree.nodeMainToken(n);
        const one_line = kind == .pattern or p.fits(n);
        const col = p.curCol();
        try p.tok(open);
        if (one_line) {
            try p.node(inner, kind, indent);
            try p.tok(p.last(inner) + 1);
        } else {
            try p.node(inner, kind, col);
            p.newline(col);
            try p.tok(p.last(inner) + 1);
        }
    }

    // ---- Expressions -----------------------------------------------------

    fn expr(p: *Printer, n: Index, indent: u32) Error!void {
        const tree = p.tree;
        const tag = tree.nodeTag(n);
        const main = tree.nodeMainToken(n);
        if (tag.isBinop()) return p.chain(n, indent);
        if (isAccess(tag)) return p.access(n, indent);
        switch (tag) {
            .int, .float, .char, .ident, .ctor, .accessor, .placeholder => try p.tok(main),
            .op_fn => {
                try p.tok(main - 1);
                try p.tok(main);
                try p.tok(main + 1);
            },
            .unit => {
                try p.tok(main);
                try p.tok(main + 1);
            },
            .string => try p.tokRange(main, p.last(n)),
            .multiline_string => {
                const s = tree.fullMultilineString(n);
                const col = p.curCol();
                var t = s.first_line;
                while (t <= s.last_line) : (t += 1) {
                    if (t != s.first_line) p.newline(col);
                    try p.tok(t);
                }
            },
            .negate => {
                try p.tok(main);
                try p.expr(tree.operand(n), indent);
            },
            .paren => try p.wrapped(n, .expr, indent),
            .tuple, .list => try p.collection(n, tree.children(n), .expr, indent),
            .record => try p.collection(n, tree.children(n), .field, indent),
            .record_update => {
                const r = tree.fullRecordUpdate(n);
                try p.extension(n, r.base, r.fields, .field);
            },
            .apply => {
                const a = tree.fullApply(n);
                const one_line = p.fits(n);
                try p.expr(a.function, indent);
                try p.args(p.last(a.function), a.args, .expr, one_line, indent);
            },
            .lambda => {
                const l = tree.fullLambda(n);
                const one_line = p.fits(n);
                try p.tok(l.backslash);
                var arrow = l.backslash + 1;
                for (l.params, 0..) |param, i| {
                    if (i > 0) try p.space();
                    try p.pat(param, indent);
                    arrow = p.last(param) + 1;
                }
                try p.space();
                try p.tok(arrow);
                if (one_line) {
                    try p.space();
                    try p.expr(l.body, indent);
                } else {
                    p.newline(indent + indent_step);
                    try p.expr(l.body, indent + indent_step);
                }
            },
            .@"if" => try p.ifExpr(n, indent, null),
            .let => try p.letExpr(n, indent),
            .case => try p.caseExpr(n, indent),
            else => return error.SyntaxErrors, // fields, chunks and interps are printed by their parents
        }
    }

    /// One operator level, flattened: `a op b op c` on one line, or the
    /// first operand and then `op operand` lines indented 4 — or, for two
    /// operands ending in a block, `a op` and the block on the next line.
    /// The vertical form is used when the chain does not fit and also when
    /// the source already breaks a line at one of its operators.
    fn chain(p: *Printer, top: Index, indent: u32) Error!void {
        const mark = p.stack.items.len;
        defer p.stack.shrinkRetainingCapacity(mark);
        // Where the chain itself starts, which is not the line's indent
        // when it starts mid-line: a `, ` in a list, an opening paren. A
        // trailing `<|` lambda continues its body from here (see below).
        const start_col = p.curCol();
        const tag = p.tree.nodeTag(top);
        const prec = precedence(tag);
        const right = rightAssociative(tag);
        // Spine, outermost first.
        var node_i = top;
        try p.stack.append(p.scratch, node_i.int());
        while (true) {
            const d = p.tree.nodeData(node_i);
            const next: Index = @enumFromInt(if (right) d.rhs else d.lhs);
            const next_tag = p.tree.nodeTag(next);
            if (!next_tag.isBinop() or precedence(next_tag) != prec) break;
            try p.stack.append(p.scratch, next.int());
            node_i = next;
        }
        const count = p.stack.items.len - mark;
        // Operands in source order, then the operator tokens in source
        // order, appended after the spine.
        if (right) {
            for (0..count) |i| try p.stack.append(p.scratch, p.tree.nodeData(@enumFromInt(p.stack.items[mark + i])).lhs);
            try p.stack.append(p.scratch, p.tree.nodeData(@enumFromInt(p.stack.items[mark + count - 1])).rhs);
            for (0..count) |i| try p.stack.append(p.scratch, p.tree.nodeMainToken(@enumFromInt(p.stack.items[mark + i])));
        } else {
            try p.stack.append(p.scratch, p.tree.nodeData(@enumFromInt(p.stack.items[mark + count - 1])).lhs);
            var i = count;
            while (i > 0) {
                i -= 1;
                try p.stack.append(p.scratch, p.tree.nodeData(@enumFromInt(p.stack.items[mark + i])).rhs);
            }
            i = count;
            while (i > 0) {
                i -= 1;
                try p.stack.append(p.scratch, p.tree.nodeMainToken(@enumFromInt(p.stack.items[mark + i])));
            }
        }
        const operands_at = mark + count;
        const ops_at = operands_at + count + 1;
        const one_line = p.fits(top);
        const block_tail = !one_line and count == 1 and isBlockForm(p.tree.nodeTag(@enumFromInt(p.stack.items[operands_at + 1])));

        try p.expr(@enumFromInt(p.stack.items[operands_at]), indent);
        for (0..count) |i| {
            const op_tok: TokenIndex = p.stack.items[ops_at + i];
            const operand: Index = @enumFromInt(p.stack.items[operands_at + 1 + i]);
            // §9: a trailing `<|` followed by a lambda does not indent. The
            // `\x ->` stays on the operator's line and the body continues at
            // that line's own indentation, so a chain of binds stays flat
            // instead of stepping right once per lambda (research 14/elm
            // §0.2, the rule elm-format never took).
            if (!one_line and i + 1 == count and tag == .pipe_left and p.tree.nodeTag(operand) == .lambda) {
                try p.space();
                try p.tok(op_tok);
                try p.space();
                // "The indentation of the line the `<|` is on" means the
                // column the construct starts in, not the column the line's
                // leading spaces end at: a chain that starts after `, ` or
                // `(` would otherwise put its body left of itself.
                try p.lambdaFlat(operand, @max(start_col, indent));
                continue;
            }
            if (one_line) {
                try p.space();
                try p.tok(op_tok);
                try p.space();
                try p.expr(operand, indent);
            } else if (block_tail) {
                try p.space();
                try p.tok(op_tok);
                p.newline(indent + indent_step);
                try p.expr(operand, indent + indent_step);
            } else {
                p.newline(indent + indent_step);
                try p.tok(op_tok);
                try p.space();
                try p.expr(operand, indent + indent_step);
            }
        }
    }

    /// The indentation of the line being written: what a construct that
    /// continues "at the same level" as the current line starts from.
    fn lineIndent(p: *const Printer) u32 {
        return if (p.pending > 0) p.next_indent else p.line_indent;
    }

    /// `\x ->` on the line it starts, its body on the next one at `indent`
    /// — the trailing-`<|` form of §9.
    fn lambdaFlat(p: *Printer, n: Index, indent: u32) Error!void {
        const l = p.tree.fullLambda(n);
        try p.tok(l.backslash);
        var arrow = l.backslash + 1;
        for (l.params, 0..) |param, i| {
            if (i > 0) try p.space();
            try p.pat(param, indent);
            arrow = p.last(param) + 1;
        }
        try p.space();
        try p.tok(arrow);
        p.newline(indent);
        try p.expr(l.body, indent);
    }

    /// The base, then the glued `.field` / `.0` / `?` tokens.
    fn access(p: *Printer, top: Index, indent: u32) Error!void {
        var base = top;
        while (isAccess(p.tree.nodeTag(base))) base = p.tree.operand(base);
        try p.expr(base, indent);
        var t = p.last(base) + 1;
        const top_tok = p.tree.nodeMainToken(top);
        while (t <= top_tok) : (t += 1) try p.tok(t);
    }

    /// Always vertical: `if c then` / a / `else` / b, an `else if` chain
    /// continuing on the `else` line, and a head whose condition does not
    /// fit (or has a comment before `then`) on three lines. The bodies sit
    /// at the line's indentation plus 4; `then` and `else` hang off the
    /// column of `if` (`keyword_col`, the outer `if`'s for an `else if`),
    /// so an `if` that starts mid-line — `[ if c then` — keeps `else` under
    /// `if`, as elm-format lays it out.
    fn ifExpr(p: *Printer, n: Index, indent: u32, keyword_col: ?u32) Error!void {
        const i = p.tree.fullIf(n);
        const then_tok = p.last(i.cond) + 1;
        const else_tok = p.last(i.then_expr) + 1;
        const else_is_if = p.tree.nodeTag(i.else_expr) == .@"if";
        const kw = keyword_col orelse p.curCol();
        try p.tok(i.if_token);
        if (p.fitsWith(i.cond, 1 + 5, then_tok)) {
            try p.space();
            try p.expr(i.cond, indent);
            try p.space();
            try p.tok(then_tok);
        } else {
            p.newline(indent + indent_step);
            try p.expr(i.cond, indent + indent_step);
            try p.leading(then_tok, indent + indent_step);
            p.newline(kw);
            try p.tokRaw(then_tok);
        }
        p.newline(indent + indent_step);
        try p.expr(i.then_expr, indent + indent_step);
        try p.leading(else_tok, indent + indent_step);
        p.newline(kw);
        try p.tokRaw(else_tok);
        if (else_is_if) {
            try p.space();
            try p.ifExpr(i.else_expr, indent, kw);
        } else {
            p.newline(indent + indent_step);
            try p.expr(i.else_expr, indent + indent_step);
        }
    }

    /// `let` / bindings at the line's indentation plus 4 / `in` and the
    /// body under `let` (a `, let` list element keeps `in` under `let`).
    fn letExpr(p: *Printer, n: Index, indent: u32) Error!void {
        const l = p.tree.fullLet(n);
        const kw = p.curCol();
        const inner = indent + indent_step;
        try p.tok(l.let_token);
        var prev_last: ?TokenIndex = null;
        for (l.bindings) |b| {
            if (prev_last) |pl| {
                p.blankLines(if (p.blankBetween(pl, p.first(b))) 1 else 0, inner);
            } else {
                p.newline(inner);
            }
            try p.binding(b, inner);
            prev_last = p.last(b);
        }
        const in_tok = if (prev_last) |pl| pl + 1 else l.let_token + 1;
        try p.leading(in_tok, inner);
        p.newline(kw);
        try p.tokRaw(in_tok);
        p.newline(kw);
        try p.expr(l.body, kw);
    }

    fn binding(p: *Printer, n: Index, indent: u32) Error!void {
        const tree = p.tree;
        const main = tree.nodeMainToken(n);
        switch (tree.nodeTag(n)) {
            .let_def => {
                const l = tree.fullLetDef(n);
                try p.tok(l.name);
                try p.defBody(l.name, l.params, l.body, indent);
            },
            .let_annotation => {
                try p.tok(main);
                try p.space();
                try p.tok(main + 1); // `:`
                try p.annotated(tree.operand(n), indent);
            },
            .let_pattern => {
                const l = tree.fullLetPattern(n);
                try p.pat(l.pattern, indent);
                try p.space();
                try p.tok(p.last(l.pattern) + 1); // `=`
                p.newline(indent + indent_step);
                try p.expr(l.value, indent + indent_step);
            },
            // `x <- f a b`: single spaces around `<-`, the call on the head
            // line, no alignment with a neighbouring `=` (§9).
            .let_bind => {
                const l = tree.fullLetPattern(n);
                try p.pat(l.pattern, indent);
                try p.space();
                try p.tok(p.last(l.pattern) + 1); // `<-`
                try p.space();
                // `flat` claims every node under the value fits on one
                // line. That is true of applications and collections —
                // collapsing an author-broken one is what §9 wants — but
                // `if`, `let` and `case` have no single-line form and break
                // regardless, so the claim would be a lie every enclosing
                // decision and the threaded indent were made on. Keep the
                // ordinary width logic when the value holds one of them.
                const saved = p.flat;
                p.flat = !p.hasBlockKeyword(l.value);
                defer p.flat = saved;
                try p.expr(l.value, indent);
            },
            else => return error.SyntaxErrors,
        }
    }

    /// `case x of` / branches at the line's indentation plus 4 / bodies at
    /// plus 8; `of` on its own line hangs off the column of `case`.
    fn caseExpr(p: *Printer, n: Index, indent: u32) Error!void {
        const c = p.tree.fullCase(n);
        const kw = p.curCol();
        const inner = indent + indent_step;
        const of_tok = p.last(c.scrutinee) + 1;
        try p.tok(c.case_token);
        if (p.fitsWith(c.scrutinee, 1 + 3, of_tok)) {
            try p.space();
            try p.expr(c.scrutinee, indent);
            try p.space();
            try p.tok(of_tok);
        } else {
            p.newline(inner);
            try p.expr(c.scrutinee, inner);
            try p.leading(of_tok, inner);
            p.newline(kw);
            try p.tokRaw(of_tok);
        }
        var prev_last: ?TokenIndex = null;
        for (c.branches) |b| {
            if (prev_last) |pl| {
                p.blankLines(if (p.blankBetween(pl, p.first(b))) 1 else 0, inner);
            } else {
                p.newline(inner);
            }
            const br = p.tree.fullBranch(b);
            try p.pat(br.pattern, inner);
            try p.space();
            try p.tok(p.last(br.pattern) + 1); // `->`
            p.newline(inner + indent_step);
            try p.expr(br.body, inner + indent_step);
            prev_last = p.last(b);
        }
    }

    /// `name = value` inside a record; a value that does not fit goes on
    /// the next line, indented 4 from the field.
    fn field(p: *Printer, n: Index, indent: u32) Error!void {
        const main = p.tree.nodeMainToken(n);
        const value = p.tree.operand(n);
        try p.tok(main);
        try p.space();
        try p.tok(main + 1); // `=`
        if (p.fitsAt(value, p.curCol() + 1)) {
            try p.space();
            try p.expr(value, indent);
        } else {
            p.newline(indent + indent_step);
            try p.expr(value, indent + indent_step);
        }
    }

    // ---- Types -----------------------------------------------------------

    fn typ(p: *Printer, n: Index, indent: u32) Error!void {
        const tree = p.tree;
        const main = tree.nodeMainToken(n);
        switch (tree.nodeTag(n)) {
            .type_var => {
                if (p.tree.typeVarMarker(n)) |marker| {
                    try p.tok(marker);
                    try p.space();
                }
                try p.tok(main);
            },
            .type_con => {
                const c = tree.fullTypeCon(n);
                // `fits` compares `curCol() + widths[n]` against
                // `max_width`, and `widths[n]` covers the WHOLE node —
                // `Maybe Int` is 9, not 4. Asking after `Maybe` is printed
                // charges those 5 bytes twice, which is why an annotation
                // whose one-line form was 96-100 columns wide had its last
                // type application pushed onto a continuation line while 95
                // stayed put. `.apply` already hoists it; so does this.
                const one_line = p.fits(n);
                try p.tok(c.name);
                try p.args(c.name, c.args, .type, one_line, indent);
            },
            .type_fn => try p.arrows(n, indent, false),
            .type_unit => {
                try p.tok(main);
                try p.tok(main + 1);
            },
            .type_paren => try p.wrapped(n, .type, indent),
            .type_tuple => try p.collection(n, tree.children(n), .type, indent),
            .type_record => try p.collection(n, tree.children(n), .type_field, indent),
            .type_record_ext => {
                const r = tree.fullTypeRecordExt(n);
                try p.extension(n, r.base, r.fields, .type_field);
            },
            else => return error.SyntaxErrors,
        }
    }

    /// `a -> b -> c` on one line, or every arrow leading a line at the
    /// column the type started on. The chain follows the right spine (arrows
    /// associate right) without recursing along it.
    fn arrows(p: *Printer, top: Index, indent: u32, force_vertical: bool) Error!void {
        const mark = p.stack.items.len;
        defer p.stack.shrinkRetainingCapacity(mark);
        var node_i = top;
        while (true) {
            const d = p.tree.nodeData(node_i);
            try p.stack.append(p.scratch, d.lhs);
            try p.stack.append(p.scratch, p.tree.nodeMainToken(node_i));
            const rhs: Index = @enumFromInt(d.rhs);
            if (p.tree.nodeTag(rhs) != .type_fn) {
                try p.stack.append(p.scratch, d.rhs);
                break;
            }
            node_i = rhs;
        }
        const one_line = !force_vertical and p.fits(top);
        const col = p.curCol();
        const count = (p.stack.items.len - mark) / 2;
        try p.typ(@enumFromInt(p.stack.items[mark]), indent);
        for (0..count) |i| {
            const arrow: TokenIndex = p.stack.items[mark + 2 * i + 1];
            const operand: Index = @enumFromInt(p.stack.items[mark + 2 * i + 2]);
            if (one_line) {
                try p.space();
                try p.tok(arrow);
                try p.space();
                try p.typ(operand, indent);
            } else {
                p.newline(col);
                try p.tok(arrow);
                try p.space();
                try p.typ(operand, col);
            }
        }
    }

    /// `name : Type` inside a record type, like a record field.
    fn typeField(p: *Printer, n: Index, indent: u32) Error!void {
        const main = p.tree.nodeMainToken(n);
        const t = p.tree.operand(n);
        try p.tok(main);
        try p.space();
        try p.tok(main + 1); // `:`
        if (p.fitsAt(t, p.curCol() + 1)) {
            try p.space();
            try p.typ(t, indent);
        } else {
            p.newline(indent + indent_step);
            try p.typ(t, indent + indent_step);
        }
    }

    // ---- Patterns --------------------------------------------------------

    fn pat(p: *Printer, n: Index, indent: u32) Error!void {
        const tree = p.tree;
        const main = tree.nodeMainToken(n);
        switch (tree.nodeTag(n)) {
            .pat_wild, .pat_var, .pat_int, .pat_char => try p.tok(main),
            .pat_neg_int => {
                try p.tok(main);
                try p.tokRaw(main + 1);
            },
            .pat_string => try p.tokRange(main, p.last(n)),
            .pat_unit => {
                try p.tok(main);
                try p.tok(main + 1);
            },
            .pat_paren => try p.wrapped(n, .pattern, indent),
            .pat_tuple, .pat_list => try p.collection(n, tree.children(n), .pattern, indent),
            .pat_record => {
                const r = tree.fullPatRecord(n);
                try p.tok(main);
                if (r.fields.len == 0) {
                    try p.tok(main + 1);
                    return;
                }
                try p.space();
                for (r.fields, 0..) |f, i| {
                    if (i > 0) {
                        try p.tok(f - 1); // `,`
                        try p.space();
                    }
                    try p.tok(f);
                }
                try p.space();
                try p.tok(r.fields[r.fields.len - 1] + 1);
            },
            .pat_ctor => {
                const c = tree.fullPatCtor(n);
                try p.tok(c.name);
                for (c.args) |a| {
                    try p.space();
                    try p.pat(a, indent);
                }
            },
            .pat_cons => {
                const d = tree.nodeData(n);
                try p.pat(@enumFromInt(d.lhs), indent);
                try p.space();
                try p.tok(main);
                try p.space();
                try p.pat(@enumFromInt(d.rhs), indent);
            },
            .pat_as => {
                const a = tree.fullPatAs(n);
                try p.pat(a.pattern, indent);
                try p.space();
                try p.tok(a.name - 1); // `as`
                try p.space();
                try p.tok(a.name);
            },
            else => return error.SyntaxErrors,
        }
    }
};

// ---------------------------------------------------------------------------
// Tests. Every input goes through `check`: the exact output, then
// `fmt(fmt(s)) == fmt(s)`, then the AST dump of the output equals the AST
// dump of the input (language.md §9's three properties).
// ---------------------------------------------------------------------------

const testing = std.testing;
const InternPool = @import("../InternPool.zig");
const Parse = @import("../parse/Parse.zig");
const dump_ast = @import("../dump/ast.zig");
const corpus_parse_good = @import("corpus_parse_good");

const Run = struct {
    text: []u8,
    /// `dump --stage=ast` of the INPUT.
    dump: []u8,
};

/// Lex, parse and format `source`, everything from `arena`. Fails when the
/// source does not parse clean: the formatter is only defined on such
/// files, and a test input that does not qualify is a bug in the test.
fn run(arena: Allocator, source: [:0]const u8) !Run {
    return runWith(arena, source, true);
}

/// `run`, optionally without the AST dump (whose recursion is per node,
/// so a 20000-operator chain overflows the test's stack there, not in the
/// formatter).
fn runWith(arena: Allocator, source: [:0]const u8, want_dump: bool) !Run {
    var interner: InternPool.Local = .empty;
    var out: Tokenizer.Output = .empty;
    try Tokenizer.tokenize(arena, source, &interner, &out);
    if (out.diagnostics.items().len != 0) {
        std.debug.print("test input has lexical errors:\n{s}\n", .{source});
        return error.TestInputDoesNotLex;
    }
    const tree = try Parse.parse(arena, arena, source, out.tokens.slice(), out.comments.items, out.line_starts.items, out.diagnostics.items());
    if (tree.errors.len != 0) {
        std.debug.print("test input has syntax errors:\n{s}\n", .{source});
        for (tree.errors) |e| std.debug.print("  {t} at offset {d}\n", .{ e.code, e.start });
        return error.TestInputDoesNotParse;
    }
    var text: Io.Writer.Allocating = .init(arena);
    try format(arena, &tree, &out.tokens, out.comments.items, source, out.line_starts.items, &text.writer);
    var dump: Io.Writer.Allocating = .init(arena);
    if (want_dump) try dump_ast.write(&dump.writer, source, &out.tokens, out.comments.items, out.line_starts.items, &tree, .{});
    return .{ .text = text.written(), .dump = dump.written() };
}

/// Idempotence and structure preservation for `source`, whose first
/// formatting is `first`. `exact_dump` compares the dumps byte for byte;
/// otherwise their lines as a sorted multiset (the formatter sorts
/// imports, which the dump lists in source order).
fn expectStable(arena: Allocator, first: Run, exact_dump: bool) !void {
    const again = try run(arena, try arena.dupeZ(u8, first.text));
    try testing.expectEqualStrings(first.text, again.text);
    if (exact_dump) {
        try testing.expectEqualStrings(first.dump, again.dump);
    } else {
        try testing.expectEqualStrings(try sortedLines(arena, first.dump), try sortedLines(arena, again.dump));
    }
    // Hygiene: no trailing whitespace, LF only, one trailing newline.
    var it = std.mem.splitScalar(u8, first.text, '\n');
    while (it.next()) |line| {
        // A `\\` line is a literal and keeps its trailing spaces (§9).
        const is_multiline = std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "\\\\");
        try testing.expect(is_multiline or !std.mem.endsWith(u8, line, " "));
        try testing.expect(std.mem.indexOfScalar(u8, line, '\r') == null);
    }
    if (first.text.len > 0) {
        try testing.expect(first.text[first.text.len - 1] == '\n');
        try testing.expect(first.text.len == 1 or first.text[first.text.len - 2] != '\n');
    }
}

fn sortedLines(arena: Allocator, text: []const u8) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(arena, line);
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    for (lines.items) |line| {
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.items;
}

fn check(input: [:0]const u8, expected: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try run(arena, input);
    try testing.expectEqualStrings(expected, first.text);
    try expectStable(arena, first, true);
}

/// `check` for an input whose imports are reordered.
fn checkReordered(input: [:0]const u8, expected: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try run(arena, input);
    try testing.expectEqualStrings(expected, first.text);
    try expectStable(arena, first, false);
}

/// The round trip alone, for inputs whose exact output is not the point.
fn checkRoundTrip(arena: Allocator, input: [:0]const u8) !void {
    const first = try run(arena, input);
    try expectStable(arena, first, false);
}

// ---- Module layout -----------------------------------------------------------

test "empty file formats to nothing; a file without a trailing newline gets one" {
    try check("", "");
    try check("x = 1", "x =\n    1\n");
}

test "module doc, blank line, imports sorted by path, two blank lines, declarations two blank lines apart" {
    try checkReordered(
        \\--!Board module.
        \\import Set
        \\import Dict exposing (Dict,  get)
        \\import Html.Attributes as A exposing (class)
        \\import Html
        \\
        \\
        \\
        \\x = 1
        \\y = 2
        \\
    ,
        \\--! Board module.
        \\
        \\import Dict exposing (Dict, get)
        \\import Html
        \\import Html.Attributes as A exposing (class)
        \\import Set
        \\
        \\
        \\x =
        \\    1
        \\
        \\
        \\y =
        \\    2
        \\
    );
}

test "two module-doc blocks merge, the space after the marker is inserted, plain comments keep their place" {
    try check(
        \\-- license
        \\--!one
        \\--!   two
        \\
        \\--! three
        \\-- trivia after the doc
        \\--| Doc on x.
        \\x = 1
        \\
    ,
        \\-- license
        \\--! one
        \\--!   two
        \\--! three
        \\
        \\-- trivia after the doc
        \\--| Doc on x.
        \\x =
        \\    1
        \\
    );
    // Only a module doc, nothing else: no blank line is added after it.
    try check("--! Only a doc.\n\n\n", "--! Only a doc.\n");
}

test "annotation directly above its definition with pub on the annotation line" {
    try check(
        \\pub   f:Int->Int
        \\
        \\-- between
        \\
        \\f x = x
        \\g : Int
        \\g = 2
        \\
    ,
        \\pub f : Int -> Int
        \\-- between
        \\f x =
        \\    x
        \\
        \\
        \\g : Int
        \\g =
        \\    2
        \\
    );
}

test "every declaration kind: alias, type, foreign, with docs, pub and opaque" {
    try check(
        \\--|The message.
        \\pub type Msg = | Inc | Dec | Set Int | Batch (List Msg)
        \\pub opaque type Id = Id Int
        \\type   alias   Point   =   { x : Float, y : Float }
        \\pub type alias Handler model msg = msg -> model -> ( model, List msg )
        \\--|Add.
        \\pub   foreign   add : number ->
        \\    number -> number
        \\foreign   type   Table   k   v
        \\
    ,
        \\--| The message.
        \\pub type Msg
        \\    = Inc
        \\    | Dec
        \\    | Set Int
        \\    | Batch (List Msg)
        \\
        \\
        \\pub opaque type Id
        \\    = Id Int
        \\
        \\
        \\type alias Point =
        \\    { x : Float, y : Float }
        \\
        \\
        \\pub type alias Handler model msg =
        \\    msg -> model -> ( model, List msg )
        \\
        \\
        \\--| Add.
        \\pub foreign add :
        \\    number
        \\    -> number
        \\    -> number
        \\
        \\
        \\foreign type Table k v
        \\
    );
}

// ---- Expressions -------------------------------------------------------------

test "let: bindings indented 4, in aligned with let, body aligned with let, blank lines kept or dropped" {
    try check(
        \\total xs =
        \\  let
        \\      count : Int
        \\      count = List.length xs
        \\      ( low, high ) = ( 1, 2 )
        \\
        \\
        \\      spread = let factor = 2 in high * factor
        \\    in
        \\     count + spread
        \\
    ,
        \\total xs =
        \\    let
        \\        count : Int
        \\        count =
        \\            List.length xs
        \\        ( low, high ) =
        \\            ( 1, 2 )
        \\
        \\        spread =
        \\            let
        \\                factor =
        \\                    2
        \\            in
        \\            high * factor
        \\    in
        \\    count + spread
        \\
    );
}

test "case: head on its own line, branches indented 4, arrow at line end, bodies indented 4 more" {
    try check(
        \\describe x = case x of 0 -> "zero"
        \\                       1
        \\                         -> "one"
        \\
        \\
        \\                       _ -> case x of
        \\                                  2 -> "two"
        \\                                  _ -> "many"
        \\
    ,
        \\describe x =
        \\    case x of
        \\        0 ->
        \\            "zero"
        \\        1 ->
        \\            "one"
        \\
        \\        _ ->
        \\            case x of
        \\                2 ->
        \\                    "two"
        \\                _ ->
        \\                    "many"
        \\
    );
}

test "if is always vertical; else-if chains continue on the else line; a mid-line if hangs off its keyword" {
    try check(
        \\tiny b = if b
        \\  then 1
        \\    else 0
        \\grade s = if s >= 90 then "A" else if s >= 80 then "B" else "F"
        \\nested a b = if a then if b then 2 else 1 else 0
        \\inList flag = [ if flag then 1 else 0, let one = 1 in one, case flag of
        \\    True -> 1
        \\    False -> 0 ]
        \\
    ,
        \\tiny b =
        \\    if b then
        \\        1
        \\    else
        \\        0
        \\
        \\
        \\grade s =
        \\    if s >= 90 then
        \\        "A"
        \\    else if s >= 80 then
        \\        "B"
        \\    else
        \\        "F"
        \\
        \\
        \\nested a b =
        \\    if a then
        \\        if b then
        \\            2
        \\        else
        \\            1
        \\    else
        \\        0
        \\
        \\
        \\inList flag =
        \\    [ if flag then
        \\        1
        \\      else
        \\        0
        \\    , let
        \\        one =
        \\            1
        \\      in
        \\      one
        \\    , case flag of
        \\        True ->
        \\            1
        \\        False ->
        \\            0
        \\    ]
        \\
    );
}

test "a condition or scrutinee that does not fit goes on its own line between the keywords" {
    try check(
        \\f = if aVeryLongConditionName && anotherVeryLongConditionName && yetAnotherVeryLongConditionName1 then 1 else 2
        \\g = case aVeryLongScrutineeName + anotherVeryLongScrutineeName + yetAnotherVeryLongScrutineeName12 of
        \\  _ -> 1
        \\h = if aVeryLongConditionName && anotherVeryLongConditionName && yetAnotherVeryLongConditionName1 && more then 1 else 2
        \\
    ,
        \\f =
        \\    if
        \\        aVeryLongConditionName && anotherVeryLongConditionName && yetAnotherVeryLongConditionName1
        \\    then
        \\        1
        \\    else
        \\        2
        \\
        \\
        \\g =
        \\    case
        \\        aVeryLongScrutineeName + anotherVeryLongScrutineeName + yetAnotherVeryLongScrutineeName12
        \\    of
        \\        _ ->
        \\            1
        \\
        \\
        \\h =
        \\    if
        \\        aVeryLongConditionName
        \\            && anotherVeryLongConditionName
        \\            && yetAnotherVeryLongConditionName1
        \\            && more
        \\    then
        \\        1
        \\    else
        \\        2
        \\
    );
}

test "lists, records and tuples: one line when they fit and were written so, empties bare, else vertical with leading delimiters" {
    try check(
        \\xs=[1,2,3]
        \\r={a=1,b=2}
        \\p=(1,(2,3))
        \\e=([ ],{  },(  ))
        \\u m = {m|count=m.count+1,
        \\  name=""}
        \\names = [ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo" ]
        \\config = { host = "localhost", port = 8080, user = "admin", password = "secret", timeout = 30, retries = 5, ok = True }
        \\pair = ( "a very long first element of a tuple that does not fit", "a very long second element of a tuple that does not fit" )
        \\update m = { m | aVeryLongFieldName = m.aVeryLongFieldName + 1, anotherVeryLongFieldName = m.anotherVeryLongFieldName }
        \\
    ,
        \\xs =
        \\    [ 1, 2, 3 ]
        \\
        \\
        \\r =
        \\    { a = 1, b = 2 }
        \\
        \\
        \\p =
        \\    ( 1, ( 2, 3 ) )
        \\
        \\
        \\e =
        \\    ( [], {}, () )
        \\
        \\
        \\u m =
        \\    { m
        \\        | count = m.count + 1
        \\        , name = ""
        \\    }
        \\
        \\
        \\names =
        \\    [ "alpha"
        \\    , "bravo"
        \\    , "charlie"
        \\    , "delta"
        \\    , "echo"
        \\    , "foxtrot"
        \\    , "golf"
        \\    , "hotel"
        \\    , "india"
        \\    , "juliet"
        \\    , "kilo"
        \\    ]
        \\
        \\
        \\config =
        \\    { host = "localhost"
        \\    , port = 8080
        \\    , user = "admin"
        \\    , password = "secret"
        \\    , timeout = 30
        \\    , retries = 5
        \\    , ok = True
        \\    }
        \\
        \\
        \\pair =
        \\    ( "a very long first element of a tuple that does not fit"
        \\    , "a very long second element of a tuple that does not fit"
        \\    )
        \\
        \\
        \\update m =
        \\    { m
        \\        | aVeryLongFieldName = m.aVeryLongFieldName + 1
        \\        , anotherVeryLongFieldName = m.anotherVeryLongFieldName
        \\    }
        \\
    );
}

test "nested breaking: a pipeline inside a list inside a record, and a field value on its own line" {
    try check(
        \\view model = { title = "Board", body = [ model.items |> List.filter (\i -> i.done) |> List.map (\i -> viewItem model i) |> List.reverse, footer model ] }
        \\
    ,
        \\view model =
        \\    { title = "Board"
        \\    , body =
        \\        [ model.items
        \\            |> List.filter (\i -> i.done)
        \\            |> List.map (\i -> viewItem model i)
        \\            |> List.reverse
        \\        , footer model
        \\        ]
        \\    }
        \\
    );
}

test "operator chains: one line when they fit and were written so, else broken before the operator at one precedence level" {
    try check(
        \\area w h = w   *   h
        \\valid r = String.length r.name > 0 && String.length r.name < 100 && r.age >= 0 && r.age < 150 && not (String.isEmpty r.email)
        \\sum r = r.width * r.height + r.padding * 2 * (r.width + r.height) + r.margin * 2 * (r.width + r.height + r.padding * 4)
        \\process xs = xs |>
        \\    List.map (\x -> x * 2) |>
        \\    List.sum
        \\negated x y = -x - -y
        \\
    ,
        \\area w h =
        \\    w * h
        \\
        \\
        \\valid r =
        \\    String.length r.name > 0
        \\        && String.length r.name < 100
        \\        && r.age >= 0
        \\        && r.age < 150
        \\        && not (String.isEmpty r.email)
        \\
        \\
        \\sum r =
        \\    r.width * r.height
        \\        + r.padding * 2 * (r.width + r.height)
        \\        + r.margin * 2 * (r.width + r.height + r.padding * 4)
        \\
        \\
        \\process xs =
        \\    xs
        \\        |> List.map (\x -> x * 2)
        \\        |> List.sum
        \\
        \\
        \\negated x y =
        \\    -x - -y
        \\
    );
}

test "a chain of two operands ending in a block keeps the operator at the end of the first line" {
    try check(
        \\f = text <| if a then b else c
        \\g = decode <|
        \\      \x -> x + 1
        \\h = foo <| let
        \\     a = 1 in a
        \\
    ,
        \\f =
        \\    text <|
        \\        if a then
        \\            b
        \\        else
        \\            c
        \\
        \\
        \\g =
        \\    decode <| \x ->
        \\    x + 1
        \\
        \\
        \\h =
        \\    foo <|
        \\        let
        \\            a =
        \\                1
        \\        in
        \\        a
        \\
    );
}

test "`_` is an ordinary argument, and `<-` bindings print on one line and are never aligned (§9)" {
    try check(
        \\partial xs = List.map (add    1    _) xs
        \\pipeline r = let
        \\    scope <- Task.scope
        \\    conn   <-   Task.bracket (\() -> Db.open r.url) Db.close
        \\    a = 1
        \\    h <- Result.andThen (readHeader r)
        \\  in
        \\  render scope conn a h
        \\
    ,
        \\partial xs =
        \\    List.map (add 1 _) xs
        \\
        \\
        \\pipeline r =
        \\    let
        \\        scope <- Task.scope
        \\        conn <- Task.bracket (\() -> Db.open r.url) Db.close
        \\        a =
        \\            1
        \\        h <- Result.andThen (readHeader r)
        \\    in
        \\    render scope conn a h
        \\
    );
}

test "a trailing `<|` lambda keeps its body at the indentation of the `<|` line (§9)" {
    try check(
        \\chain url = Task.attempt (Http.get url) <| \response -> Task.attempt (Json.decode response) <| \value -> renderTheDecodedValue value withSomeContext andAnotherArgument
        \\
    ,
        \\chain url =
        \\    Task.attempt (Http.get url) <| \response ->
        \\    Task.attempt (Json.decode response) <| \value ->
        \\    renderTheDecodedValue value withSomeContext andAnotherArgument
        \\
    );
}

test "lambdas: `\\x y ->` with the body inline when it fits, else on the next line indented 4" {
    try check(
        \\f=\x->x+1
        \\h = \(a,b) {c} _->
        \\  a+b+c
        \\describe = \x -> case x of
        \\  0 -> "zero"
        \\  _ -> "other"
        \\
    ,
        \\f =
        \\    \x -> x + 1
        \\
        \\
        \\h =
        \\    \( a, b ) { c } _ -> a + b + c
        \\
        \\
        \\describe =
        \\    \x ->
        \\        case x of
        \\            0 ->
        \\                "zero"
        \\            _ ->
        \\                "other"
        \\
    );
}

test "application: one line when it fits and was written so; head-line arguments stay, the rest go one per line" {
    try check(
        \\short =
        \\  max
        \\      1
        \\   2
        \\long = List.foldl (\item acc -> acc + String.length item) 0 [ "a very long string literal", "another very long string literal", "and one more" ]
        \\nestedCall = f (g (h 1
        \\  2) 3)
        \\
    ,
        \\short =
        \\    max
        \\        1
        \\        2
        \\
        \\
        \\long =
        \\    List.foldl
        \\        (\item acc -> acc + String.length item)
        \\        0
        \\        [ "a very long string literal", "another very long string literal", "and one more" ]
        \\
        \\
        \\nestedCall =
        \\    f
        \\        (g
        \\            (h 1
        \\                2
        \\            )
        \\            3
        \\        )
        \\
    );
}

test "grouping parentheses are kept as written, without inner spaces, and close on their own line when vertical" {
    try check(
        \\a x = ( x )
        \\b x y = -( x + y )
        \\d x = ( x + 1 ) * 2
        \\e2 fn x = fn ( -x )
        \\g x = [ ( x ) ]
        \\run k = (\k2 ->
        \\   case k2 of
        \\     0 -> 1
        \\     _ -> k2) k
        \\
    ,
        \\a x =
        \\    (x)
        \\
        \\
        \\b x y =
        \\    -(x + y)
        \\
        \\
        \\d x =
        \\    (x + 1) * 2
        \\
        \\
        \\e2 fn x =
        \\    fn (-x)
        \\
        \\
        \\g x =
        \\    [ (x) ]
        \\
        \\
        \\run k =
        \\    (\k2 ->
        \\        case k2 of
        \\            0 ->
        \\                1
        \\            _ ->
        \\                k2
        \\    )
        \\        k
        \\
    );
}

test "access chains, question marks, accessor functions and operator functions" {
    try check(
        \\f r t = Ok ( r.a.b + t.0.1 + List.length ( List.map .name [] ) )
        \\g s = Ok ( parse s? + parse s?.field?  )
        \\plus = ( + )
        \\cons = (::)
        \\
    ,
        \\f r t =
        \\    Ok (r.a.b + t.0.1 + List.length (List.map .name []))
        \\
        \\
        \\g s =
        \\    Ok (parse s? + parse s?.field?)
        \\
        \\
        \\plus =
        \\    (+)
        \\
        \\
        \\cons =
        \\    (::)
        \\
    );
}

test "strings, chars, numbers, interpolations and multiline strings are printed byte for byte" {
    try check("a = \"tab\\there \\u{0041} \\$ \\' \\\"q\\\"\"\n" ++
        "b = '\\u{00041}'\n" ++
        "c = 0xDeadBEEF\n" ++
        "d = 1.50e+03\n" ++
        "e2 = \"${ a }${b} and ${ f (g x) }\"\n" ++
        "f =\n" ++
        "  \\\\raw \\n ${x}   \n" ++
        "  \\\\second\n" ++
        "g = [ \\\\one\n" ++
        "    , 2 ]\n", "a =\n" ++
        "    \"tab\\there \\u{0041} \\$ \\' \\\"q\\\"\"\n" ++
        "\n\n" ++
        "b =\n" ++
        "    '\\u{00041}'\n" ++
        "\n\n" ++
        "c =\n" ++
        "    0xDeadBEEF\n" ++
        "\n\n" ++
        "d =\n" ++
        "    1.50e+03\n" ++
        "\n\n" ++
        "e2 =\n" ++
        "    \"${ a }${b} and ${ f (g x) }\"\n" ++
        "\n\n" ++
        "f =\n" ++
        "    \\\\raw \\n ${x}   \n" ++
        "    \\\\second\n" ++
        "\n\n" ++
        "g =\n" ++
        "    [ \\\\one\n" ++
        "    , 2\n" ++
        "    ]\n");
}

test "every pattern form with canonical spacing" {
    try check(
        \\f v = case v of
        \\  (a,b)::rest -> a
        \\  [x,y] -> x
        \\  ({c} as r)::_ -> c
        \\  Just(Just(z)) :: [] -> z
        \\  Maybe.Just 'c' -> 1
        \\  ( -1 ) -> 2
        \\  "s" -> 3
        \\  () -> 4
        \\  _ -> 0
        \\g p = let (a,b)=p in a
        \\h = \(a,b)->a
        \\k (Just x) { a } ( b, c ) = -x
        \\
    ,
        \\f v =
        \\    case v of
        \\        ( a, b ) :: rest ->
        \\            a
        \\        [ x, y ] ->
        \\            x
        \\        ({ c } as r) :: _ ->
        \\            c
        \\        Just (Just (z)) :: [] ->
        \\            z
        \\        Maybe.Just 'c' ->
        \\            1
        \\        (-1) ->
        \\            2
        \\        "s" ->
        \\            3
        \\        () ->
        \\            4
        \\        _ ->
        \\            0
        \\
        \\
        \\g p =
        \\    let
        \\        ( a, b ) =
        \\            p
        \\    in
        \\    a
        \\
        \\
        \\h =
        \\    \( a, b ) -> a
        \\
        \\
        \\k (Just x) { a } ( b, c ) =
        \\    -x
        \\
    );
}

test "a pattern that does not fit overflows the guide instead of wrapping" {
    // language.md §9: patterns are never broken across lines. Before that
    // rule the parenthesised pattern below came out as a 106-column line
    // followed by a lone `) ->` — over the guide AND unreadable, because
    // nothing tells the reader where the pattern ends and the branch
    // begins. All three of these are over 100 columns and all three stay
    // on one line.
    try check(
        \\f x = case x of
        \\  Other (Wrapped aLongFieldName anotherLongFieldName aThirdLongFieldName moreStuffHere extraLongName) -> 2
        \\  ( aLongFieldName, anotherLongFieldName, aThirdLongFieldName, moreStuffHere, extraLongNameHere ) -> 3
        \\  [ aLongFieldName
        \\      , anotherLongFieldName
        \\      , aThirdLongFieldName
        \\      , moreStuffHere
        \\      , extraLongNameHere
        \\      ] -> 4
        \\  _ -> 5
        \\
    ,
        \\f x =
        \\    case x of
        \\        Other (Wrapped aLongFieldName anotherLongFieldName aThirdLongFieldName moreStuffHere extraLongName) ->
        \\            2
        \\        ( aLongFieldName, anotherLongFieldName, aThirdLongFieldName, moreStuffHere, extraLongNameHere ) ->
        \\            3
        \\        [ aLongFieldName, anotherLongFieldName, aThirdLongFieldName, moreStuffHere, extraLongNameHere ] ->
        \\            4
        \\        _ ->
        \\            5
        \\
    );
}

test "an annotation whose one-line form is 96 to 100 columns wide stays on one line" {
    // `fits(n)` compares `curCol() + widths[n]` with `max_width`, and
    // `widths[n]` spans the WHOLE node — `Maybe Int` is 9 bytes, not 4.
    // Asking it after the head token is printed charged `Maybe` twice, so
    // an annotation 96..100 columns wide had its last type application
    // pushed onto a continuation line (`… -> Maybe` / `    Int`), a shape
    // §9 does not describe. 95 and below were one byte short of the
    // doubled head mattering; 101 and above break at the arrows, which is
    // correct. Every width in the band is checked, because a boundary bug
    // is exactly the kind that one example misses.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const head = "f : ";
    const tail = " -> Int -> Maybe Int";
    for (90..105) |target| {
        const padding = try arena.alloc(u8, target - head.len - tail.len);
        @memset(padding, 'T');
        const line = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ head, padding, tail });
        try testing.expectEqual(target, line.len);
        const input = try std.fmt.allocPrintSentinel(arena, "{s}\nf x y =\n    Nothing\n", .{line}, 0);
        const out = try run(arena, input);
        const first_line = out.text[0..std.mem.indexOfScalar(u8, out.text, '\n').?];
        const want: []const u8 = if (target <= max_width) line else "f :";
        testing.expectEqualStrings(want, first_line) catch |err| {
            std.debug.print("at width {d}\n", .{target});
            return err;
        };
    }
}

// ---- Types -------------------------------------------------------------------

test "every type form; annotations broken at every arrow when they do not fit; record types like records" {
    try check(
        \\h : (Int->Int)->List Int->List Int
        \\h fn xs = List.map fn xs
        \\ext : { r | x : Int, y : Int } -> ( ) -> ( a, Maybe.Maybe b ) -> {}
        \\ext _ _ _ = {}
        \\pub update : Msg -> { host : String, port : Int, retries : Int, onError : String -> Msg } -> ( Model, List String )
        \\update msg config = ( config, [] )
        \\type alias Config = { host : String, port : Int, user : String, password : String, timeout : Int, verbose : Bool, more : Int }
        \\type Event = Click Int
        \\       Int | Resize { width : Int,
        \\   height : Int }
        \\
    ,
        \\h : (Int -> Int) -> List Int -> List Int
        \\h fn xs =
        \\    List.map fn xs
        \\
        \\
        \\ext : { r | x : Int, y : Int } -> () -> ( a, Maybe.Maybe b ) -> {}
        \\ext _ _ _ =
        \\    {}
        \\
        \\
        \\pub update :
        \\    Msg
        \\    -> { host : String, port : Int, retries : Int, onError : String -> Msg }
        \\    -> ( Model, List String )
        \\update msg config =
        \\    ( config, [] )
        \\
        \\
        \\type alias Config =
        \\    { host : String
        \\    , port : Int
        \\    , user : String
        \\    , password : String
        \\    , timeout : Int
        \\    , verbose : Bool
        \\    , more : Int
        \\    }
        \\
        \\
        \\type Event
        \\    = Click Int
        \\        Int
        \\    | Resize
        \\        { width : Int
        \\        , height : Int
        \\        }
        \\
    );
}

// ---- Comments ----------------------------------------------------------------

test "comments in every position stay attached, own-line at their block's indentation, trailing at line end" {
    try check(
        \\   -- before imports
        \\import Set -- after an import
        \\--| doc for T
        \\type T = A -- after A
        \\   -- between ctors
        \\  | B
        \\-- before f
        \\f x = -- after equals
        \\  let
        \\        -- before binding
        \\     y = 1 -- after body
        \\
        \\        -- before in
        \\  in
        \\        -- before in-expression
        \\  if x then -- after then
        \\      y
        \\         -- before else
        \\  else
        \\      -- in else
        \\      case x of -- after of
        \\             -- before branch
        \\          True -> 1 -- after branch
        \\                -- between branches
        \\          False -> { a = [ 1 -- in list
        \\                   , 2
        \\
        \\                   -- before an element
        \\                   , 3
        \\                   -- before close
        \\                   ] -- after the list
        \\                   -- before a field
        \\                   , b = 2 }
        \\-- at the end of the file
        \\
        \\-- and one more
        \\
    ,
        \\-- before imports
        \\import Set -- after an import
        \\
        \\
        \\--| doc for T
        \\type T
        \\    = A -- after A
        \\    -- between ctors
        \\    | B
        \\
        \\
        \\-- before f
        \\f x = -- after equals
        \\    let
        \\        -- before binding
        \\        y =
        \\            1 -- after body
        \\
        \\        -- before in
        \\    in
        \\    -- before in-expression
        \\    if x then -- after then
        \\        y
        \\        -- before else
        \\    else
        \\        -- in else
        \\        case x of -- after of
        \\            -- before branch
        \\            True ->
        \\                1 -- after branch
        \\            -- between branches
        \\            False ->
        \\                { a =
        \\                    [ 1 -- in list
        \\                    , 2
        \\
        \\                    -- before an element
        \\                    , 3
        \\                    -- before close
        \\                    ] -- after the list
        \\                -- before a field
        \\                , b = 2
        \\                }
        \\
        \\
        \\-- at the end of the file
        \\
        \\-- and one more
        \\
    );
}

test "a trailing comment before `of` or a comma is kept, and the rest of the line moves, stably" {
    try check(
        \\f x = case x -- after the scrutinee
        \\  of
        \\   _ -> 1
        \\
    ,
        \\f x =
        \\    case
        \\        x -- after the scrutinee
        \\    of
        \\        _ ->
        \\            1
        \\
    );
    try check(
        \\g = [ 1, -- after a comma
        \\  2 ]
        \\
    ,
        \\g =
        \\    [ 1 -- after a comma
        \\    , 2
        \\    ]
        \\
    );
}

test "doc comments: the space is inserted, existing spacing is kept, `---` and `--x` are plain" {
    try check(
        \\--|Doc for x.
        \\x = 1
        \\--|   spaced doc
        \\y = 2
        \\--comment without a space
        \\--- dashes
        \\z = 3
        \\
    ,
        \\--| Doc for x.
        \\x =
        \\    1
        \\
        \\
        \\--|   spaced doc
        \\y =
        \\    2
        \\
        \\
        \\--comment without a space
        \\--- dashes
        \\z =
        \\    3
        \\
    );
}

test "a comment moves with the import it precedes when imports are sorted" {
    try checkReordered(
        \\import Set -- trailing on Set
        \\-- before Dict
        \\import Dict
        \\x = 1
        \\
    ,
        \\-- before Dict
        \\import Dict
        \\import Set -- trailing on Set
        \\
        \\
        \\x =
        \\    1
        \\
    );
}

// ---- Whitespace ----------------------------------------------------------------

test "CRLF, trailing whitespace, missing trailing newline and extra blank lines are normalised" {
    try check("x =   \r\n    1  \r\n\r\n\r\ny = 2", "x =\n    1\n\n\ny =\n    2\n");
}

test "the 100-column boundary: a line of exactly 100 fits, 101 does not" {
    // `    [ ` + 92 + ` ]` = 100 columns.
    const item_92 = "\"" ++ "a" ** 90 ++ "\"";
    try check("xs = [ " ++ item_92 ++ " ]\n", "xs =\n    [ " ++ item_92 ++ " ]\n");
    const item_93 = "\"" ++ "a" ** 91 ++ "\"";
    try check("xs = [ " ++ item_93 ++ " ]\n", "xs =\n    [ " ++ item_93 ++ "\n    ]\n");
    // The same width measured at the deeper indentation of a binding body
    // (12): `[ ` + 84 + ` ]` is exactly 100 there, one more is not.
    const wide_84 = "\"" ++ "b" ** 82 ++ "\"";
    try check("f =\n  let\n   x = [ " ++ wide_84 ++ " ]\n  in x\n", "f =\n    let\n        x =\n            [ " ++ wide_84 ++ " ]\n    in\n    x\n");
    const wide_85 = "\"" ++ "b" ** 83 ++ "\"";
    try check("f =\n  let\n   x = [ " ++ wide_85 ++ " ]\n  in x\n", "f =\n    let\n        x =\n            [ " ++ wide_85 ++ "\n            ]\n    in\n    x\n");
}

// ---- Robustness ----------------------------------------------------------------

test "deep nesting and very long chains format without exhausting the stack" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 4000 nested parentheses (under the parser's 4096 limit).
    {
        const depth = 4000;
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(arena, "x = ");
        try src.appendNTimes(arena, '(', depth);
        try src.append(arena, '1');
        try src.appendNTimes(arena, ')', depth);
        try src.append(arena, '\n');
        try checkRoundTrip(arena, try arena.dupeZ(u8, src.items));
    }
    // A left-associative chain, an access chain and a question chain, each
    // as long as the parser will build one. These are the three spines the
    // parser assembles in a loop; the printer flattens them in a loop too
    // (`Measurer.chain`, `Measurer.access`), which is why it survives what
    // the AST dumper cannot. The dump is therefore skipped and idempotence
    // alone is asserted.
    //
    // 4000, not 20000: `Parse.max_depth` now bounds these spines as well
    // (they are real tree depth, and every other consumer recurses along
    // them), so a 20000-link chain is `nesting_too_deep` and would not
    // reach the formatter at all. Each `x = a` costs one level before the
    // chain starts, hence 4000 rather than 4096.
    inline for (.{ " + a", ".a", "?" }) |piece| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(arena, "x = a");
        for (0..4000) |_| try src.appendSlice(arena, piece);
        try src.append(arena, '\n');
        const first = try runWith(arena, try arena.dupeZ(u8, src.items), false);
        const again = try runWith(arena, try arena.dupeZ(u8, first.text), false);
        try testing.expectEqualStrings(first.text, again.text);
    }
}

test "the parse/good corpus round-trips: idempotent and structure-preserving" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for (corpus_parse_good.fixtures) |file| {
        _ = arena_state.reset(.retain_capacity);
        checkRoundTrip(arena_state.allocator(), file.source) catch |err| {
            std.debug.print("corpus file {s}: {t}\n", .{ file.name, err });
            return err;
        };
    }
}

/// Declarations in valid but unkempt layouts, every construct represented.
/// `{d}` is replaced by a counter so names stay distinct.
const stress_decls = [_][]const u8{
    "v{d} = 1\n",
    "f{d} a b = a + b * 2 - -a\n",
    "g{d} : Int -> List Int -> Maybe.Maybe (Result String Int)\ng{d} _ xs = List.head xs |> Maybe.map Ok\n",
    "type T{d} a = A{d} | B{d} a (List a) | C{d} { x : Int, y : a }\n",
    "type alias P{d} = { x : Int, y : Int, name : String }\n",
    "pub opaque type Q{d} = Q{d} Int\n",
    "foreign h{d} : Int -> Int\n",
    "foreign type Ft{d} a b\n",
    "c{d} m =\n    case m of\n        Just n ->\n            n\n\n        Nothing ->\n            0\n",
    "c2{d} m = case m of\n  Just n -> n\n  Nothing -> 0\n",
    "l{d} =\n    let\n        a = 1\n\n        b : Int\n        b = 2\n        ( p, q ) = ( a, b )\n    in\n    a + b + p + q\n",
    "i{d} x = if x then 1 else if not x then 2 else 3\n",
    "i2{d} x = if aVeryLongConditionNameNumberOne x && aVeryLongConditionNameNumberTwo x then aVeryLongThenBranch x else 0\n",
    "col{d} = ( [ 1, 2, 3 ], { a = 1, b = \"${x} and ${ y }\" }, ( 1, 2 ), [], {}, () )\n",
    "long{d} = [ \"alpha\", \"bravo\", \"charlie\", \"delta\", \"echo\", \"foxtrot\", \"golf\", \"hotel\", \"india\", \"juliet\", \"kilo\" ]\n",
    "s{d} = \\a b -> a\n",
    "s2{d} = \\( a, b ) { c } _ -> a + b + c\n",
    "t{d} = f <| g <| h x\n",
    "t2{d} = text <| if a then b else c\n",
    "pipe{d} xs = xs\n    |> List.map (\\x -> x * 2)\n    |> List.filter (\\x -> x > 10)\n    |> List.sum\n",
    "q{d} s = parse s? |> f\n",
    "acc{d} r t = r.a.b + t.0.1 + (f r).x + List.map .name []\n",
    "m{d} =\n    \\\\a\n    \\\\b   \n",
    "p{d} (Just x) { a } ( b, c ) = -x\n",
    "u{d} m = { m | count = m.count + 1, aVeryLongFieldNameToMakeItWide = m.aVeryLongFieldNameToMakeItWide + 1 }\n",
    "op{d} = ( + ) 1 2 + (::) 1 [] + ( |> ) 1 identity\n",
    "app{d} = List.foldl (\\item acc -> acc + String.length item * 2) 0 [ \"some\", \"long\", \"list\", \"of\", \"strings\", \"here\" ]\n",
    "ann{d} : { host : String, port : Int, user : String, password : String, timeout : Int } -> Result String { host : String, port : Int } -> Bool\nann{d} _ _ = True\n",
    "chain{d} r = String.length r.name > 0 && String.length r.name < 100 && r.age >= 0 && r.age < 150 && not (String.isEmpty r.email)\n",
    "cmt{d} x = -- after equals\n    let\n        -- before binding\n        y = 1 -- after body\n        -- before in\n    in\n    -- before body\n    if x then -- after then\n        y\n        -- before else\n    else\n        -- in else\n        case x of -- after of\n            -- before branch\n            True -> 1 -- after branch\n            -- between branches\n            False -> [ 1 -- in list\n                     , 2\n                     -- before close\n                     ]\n",
    "str{d} = \"tab\\there \\u{0041} \\$ \\' \\\"q\\\"\" ++ \"${a}\"\n",
    "num{d} = ( 0xDeadBEEF, 1.50e+03, '\\u{00041}', -1 )\n",
    "par{d} = ( ( x ) )\n",
    "nest{d} m flag =\n  case m of\n     Just n ->\n       if flag then\n           let\n             doubled = n * 2\n           in\n               doubled\n       else (\\k ->\n              case k of\n                   0 -> 1\n                   _ -> k\n             ) n\n     Nothing ->\n              0\n",
};

const stress_imports = [_][]const u8{
    "import Set\n",
    "import Dict exposing (Dict, get)\n",
    "import Html.Attributes as A exposing (class)\n",
    "import Json.Decode as D\n",
};

// Random modules assembled from `stress_decls` in random order with
// random trivia — blank lines, plain and doc comments, a module doc,
// imports — between them. Every module parses clean by construction, so
// the formatter must round-trip it (PRNG-driven, like the parser's
// stress test: the toolchain's fuzz mode does not build on 0.16.0).
// `BENI_STRESS_ITERATIONS` raises the count for a long run.
test "stress: random modules of every construct round-trip" {
    var iterations: usize = 300;
    if (testing.environ.getAlloc(testing.allocator, "BENI_STRESS_ITERATIONS")) |value| {
        defer testing.allocator.free(value);
        iterations = std.fmt.parseInt(usize, value, 10) catch iterations;
    } else |_| {}

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var prng: std.Random.DefaultPrng = .init(0xF0F0);
    const random = prng.random();

    for (0..iterations) |iteration| {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var src: std.ArrayList(u8) = .empty;
        if (random.boolean()) try src.appendSlice(arena, "--!Module doc.\n--! More.\n\n");
        if (random.boolean()) try src.appendSlice(arena, "-- a plain comment at the top\n");
        for (stress_imports) |import_line| {
            if (random.boolean()) try src.appendSlice(arena, import_line);
        }
        const count = random.intRangeAtMost(usize, 1, 12);
        for (0..count) |k| {
            // Trivia: blank lines, plain comments, then maybe a doc block.
            try src.appendNTimes(arena, '\n', random.intRangeAtMost(usize, 0, 3));
            if (random.uintLessThan(u8, 3) == 0) try src.appendSlice(arena, "-- a comment before the declaration\n");
            if (random.uintLessThan(u8, 3) == 0) try src.appendSlice(arena, "--|Doc.\n--| More doc.\n");
            const template = stress_decls[random.uintLessThan(usize, stress_decls.len)];
            // Substitute `{d}` with a unique suffix.
            var rest = template;
            while (std.mem.indexOf(u8, rest, "{d}")) |at| {
                try src.appendSlice(arena, rest[0..at]);
                try src.print(arena, "{d}_{d}", .{ iteration, k });
                rest = rest[at + 3 ..];
            }
            try src.appendSlice(arena, rest);
            if (random.uintLessThan(u8, 4) == 0) {
                // A trailing comment on the declaration's last line.
                src.items.len -= 1;
                try src.appendSlice(arena, " -- trailing\n");
            }
        }
        if (random.boolean()) try src.appendSlice(arena, "\n-- at the end\n");
        checkRoundTrip(arena, try arena.dupeZ(u8, src.items)) catch |err| {
            std.debug.print("stress iteration {d} failed ({t}):\n{s}\n", .{ iteration, err, src.items });
            return err;
        };
    }
}
