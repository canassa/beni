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
//!   a record keeps the record vertical too. `case` and `let` are always
//!   vertical; an `if` is vertical unless the author wrote it on one line
//!   and it fits there (language.md §12.5), an `else if` tail going with
//!   its chain. Patterns are exempt (below) and so are lambdas: `\x ->`
//!   keeps its body on the line when the body is a one-line thing that fits.
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
//!   and every argument on a line of its own. The exception is an
//!   application whose last argument is a list, record, record update or
//!   markup (language.md §12.5): when it must break and its head fits on
//!   one line, the head goes there whatever breaks the source had, and the
//!   last argument hangs on the next line indented 4 (`Printer.hangs`).
//! - A type annotation is one line or broken at EVERY arrow, the arrows
//!   leading continuation lines at the type's column, the first parameter
//!   2 further in, under the others after their `, ` (language.md §12.5);
//!   a `type alias` always has its body on the next line, whatever its
//!   width; `foreign` values follow annotations. A constructor's arguments follow the application
//!   rule above, the vertical ones indented 4 under the `|`.
//! - A definition's body — top-level, `let`, `let` pattern — sits on the
//!   `=` line when it has a one-line form that fits there and no comment
//!   comes between `=` and it; otherwise on the next line indented 4
//!   (language.md §9, amended 2026-10-02). The break after `=` is not a
//!   break between elements, so a source that wrote the body below does
//!   not keep it there (`Printer.rhs`).
//! - Own-line comments are indented like the token they precede, except
//!   before a keyword that closes a block — `in`, `else`, `then`, `of` on
//!   their own line — where they are indented with the block they close
//!   (`AlreadyCanonicalComments`). A blank line directly before an own-line
//!   comment is kept (at most one) whenever the previous line ends a value
//!   — a name, a literal, a closing bracket, another comment — and dropped
//!   after an opener (`=`, `->`, `let`, `[`, …). A blank line between a
//!   plain own-line comment and the token after it is kept (at most one)
//!   so a comment that labels a section stays apart from it (language.md
//!   §12.5), except before `then`, `else`, `in`, `of`, a closing bracket or
//!   the end of the file, and between an annotation and its definition;
//!   a doc comment always sits on what it documents. Comments before the
//!   end of the file are separated from the last declaration like a
//!   declaration.
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
const Parse = @import("../parse/Parse.zig");
const InternPool = @import("../InternPool.zig");
const diagnostic = @import("diagnostic");
const markup_text = @import("../markup/text.zig");
const prelude = @import("../bir/prelude.zig");
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

/// `beni fmt --migrate-cons`: `source` with every outermost `::` chain
/// written in the list syntax (language.md §6.8), and nothing else touched
/// — not a canonical formatting, an edit, so a file keeps its own layout.
/// `a :: b :: rest` is `[ a, b, ...rest ]`, a chain ending in a literal
/// takes its items (`x :: []` is `[ x ]`), a pattern chain ending in `_` is
/// `..._`, a chain in parentheses loses them (the brackets group it), and
/// `(::)` is `List.cons`. Operands are copied byte for byte from the
/// source; a chain nested inside an operand is left for the next run, which
/// the caller repeats until nothing changes. A chain it cannot write — a
/// pattern tail that is not a name, `_` or a list, a comment between its
/// items — is left alone and counted in `skipped`. A file whose only syntax
/// errors are `cons_removed` is what it is for; any other error leaves the
/// file alone, as `format` does.
pub fn migrateCons(
    scratch: Allocator,
    tree: *const Ast,
    tokens: *const Token.TokenList,
    comments: []const Token.Comment,
    source: [:0]const u8,
    w: *Io.Writer,
    skipped: *u32,
) Error!void {
    if (!onlyConsRemoved(tree)) return error.SyntaxErrors;
    const n = tree.nodes.len;
    var m: Measurer = .{
        .tree = tree,
        .tags = tokens.items(.tag),
        .starts = tokens.items(.start),
        .tok_lines = tokens.items(.line),
        .comments = comments,
        .source = source,
        .widths = try scratch.alloc(u32, n),
        .firsts = try scratch.alloc(u32, n),
        .lasts = try scratch.alloc(u32, n),
        .scratch = scratch,
    };
    defer m.stack.deinit(scratch);
    try m.measureRoot();
    const tags = tokens.items(.tag);

    // Every `::` node with its byte span; an outermost one is inside no
    // other's.
    const Chain = struct { node: Index, start: u32, end: u32 };
    var chains: std.ArrayList(Chain) = .empty;
    for (0..n) |i| {
        const node: Index = @enumFromInt(@as(u32, @intCast(i)));
        const tag = tree.nodeTag(node);
        const is_cons = tag == .cons or tag == .pat_cons or
            (tag == .op_fn and tags[tree.nodeMainToken(node)] == .op_colon_colon);
        if (!is_cons) continue;
        var first = m.first(node);
        var last = m.last(node);
        // A chain the parentheses only group: the brackets will.
        if (tag != .op_fn and first > 0 and tags[first - 1] == .l_paren and last + 1 < tags.len and tags[last + 1] == .r_paren) {
            first -= 1;
            last += 1;
        }
        try chains.append(scratch, .{ .node = node, .start = m.starts[first], .end = Tokenizer.tokenEnd(source, tags[last], m.starts[last]) });
    }
    std.mem.sort(Chain, chains.items, {}, struct {
        fn lessThan(_: void, a: Chain, b: Chain) bool {
            return a.start < b.start or (a.start == b.start and a.end > b.end);
        }
    }.lessThan);

    var at: u32 = 0;
    for (chains.items) |c| {
        if (c.start < at) continue; // inside a chain already written
        var text: std.ArrayList(u8) = .empty;
        if (!try m.bracketForm(c.node, c.start, c.end, &text)) {
            skipped.* += 1;
            continue;
        }
        try w.writeAll(source[at..c.start]);
        try w.writeAll(text.items);
        at = c.end;
    }
    try w.writeAll(source[at..]);
}

/// `beni fmt --migrate-let-blanks`: `source` with the blank lines between
/// consecutive one-line `let` bindings deleted, and nothing else touched —
/// an edit, like `migrateCons`, not a formatting. It is a one-time cleanup
/// of the old style's blank line between every binding, which reads oddly
/// once a short body sits on its `=` line (language.md §9); the
/// formatter's own rule, "at most one, kept if present", is unchanged.
///
/// A binding is one line when its source span holds no line break (a
/// trailing comment on its last line does not count). The gap between two
/// such neighbours loses its blank lines only when it holds nothing else:
/// a comment line anywhere in it keeps the whole gap as written. A blank
/// line next to a multi-line binding separates a block and stays. Every
/// `let` is visited, nested ones included; the edits are disjoint, so one
/// run reaches the fixed point. A file with any syntax error is left alone.
pub fn migrateLetBlanks(
    scratch: Allocator,
    tree: *const Ast,
    tokens: *const Token.TokenList,
    comments: []const Token.Comment,
    source: [:0]const u8,
    w: *Io.Writer,
) Error!void {
    if (tree.errors.len != 0) return error.SyntaxErrors;
    const n = tree.nodes.len;
    var m: Measurer = .{
        .tree = tree,
        .tags = tokens.items(.tag),
        .starts = tokens.items(.start),
        .tok_lines = tokens.items(.line),
        .comments = comments,
        .source = source,
        .widths = try scratch.alloc(u32, n),
        .firsts = try scratch.alloc(u32, n),
        .lasts = try scratch.alloc(u32, n),
        .scratch = scratch,
    };
    defer m.stack.deinit(scratch);
    try m.measureRoot();

    // Byte ranges to delete; disjoint, because each lies between two
    // sibling bindings and holds no token.
    const Cut = struct { start: u32, end: u32 };
    var cuts: std.ArrayList(Cut) = .empty;
    for (0..n) |i| {
        const node: Index = @enumFromInt(@as(u32, @intCast(i)));
        if (tree.nodeTag(node) != .let) continue;
        const bindings = tree.fullLet(node).bindings;
        if (bindings.len < 2) continue;
        for (bindings[0 .. bindings.len - 1], bindings[1..]) |a, b| {
            const a_end = m.endOf(m.last(a));
            const b_start = m.starts[m.first(b)];
            if (std.mem.indexOfScalar(u8, source[m.starts[m.first(a)]..a_end], '\n') != null) continue;
            if (std.mem.indexOfScalar(u8, source[b_start..m.endOf(m.last(b))], '\n') != null) continue;
            // From the line after `a` (past any trailing comment) to the
            // start of `b`'s line: blank lines only, or it stays.
            const a_eol = std.mem.indexOfScalarPos(u8, source, a_end, '\n') orelse continue;
            const b_line = (std.mem.lastIndexOfScalar(u8, source[0..b_start], '\n') orelse continue) + 1;
            if (b_line <= a_eol + 1) continue;
            const gap = source[a_eol + 1 .. b_line];
            if (std.mem.indexOfNone(u8, gap, " \t\r\n") != null) continue;
            try cuts.append(scratch, .{ .start = @intCast(a_eol + 1), .end = @intCast(b_line) });
        }
    }
    std.mem.sort(Cut, cuts.items, {}, struct {
        fn lessThan(_: void, x: Cut, y: Cut) bool {
            return x.start < y.start;
        }
    }.lessThan);

    var at: u32 = 0;
    for (cuts.items) |c| {
        try w.writeAll(source[at..c.start]);
        at = c.end;
    }
    try w.writeAll(source[at..]);
}

/// Why `migrateLambda` left a file alone: its rewrite does not parse
/// cleanly. `code` is the re-parse's first diagnostic and `start` its
/// offset in the ORIGINAL source (the rewrite moves no line, so the line is
/// the same).
pub const LambdaProblem = struct {
    code: diagnostic.Code,
    start: u32,
};

/// `beni fmt --migrate-lambda` (frontend.md §11.4): `source` with the `\`
/// that begins every lambda written `λ`, and nothing else touched — an
/// edit, like `migrateCons`, not a formatting. Only the head token of a
/// `lambda` node is rewritten, so a multiline string's `\\` and a string's
/// or a character's escapes, which are not that token, are never touched.
///
/// `λ` is two bytes where `\` was one, so every later token on its line
/// moves one column right. Layout compares the columns of tokens that begin
/// a line, which the rewrite never moves, except for a `case` whose first
/// branch shares the `of` line (language.md §12.1, *columns*): the output
/// is therefore lexed and parsed again, and when it does not parse cleanly
/// the file is written unchanged and the problem returned for the caller to
/// name. A file with any syntax error but `backslash_lambda_removed` is left
/// alone. One run reaches the fixed point.
pub fn migrateLambda(
    scratch: Allocator,
    tree: *const Ast,
    tokens: *const Token.TokenList,
    source: [:0]const u8,
    w: *Io.Writer,
) Error!?LambdaProblem {
    if (!onlyBackslashLambdas(tree)) return error.SyntaxErrors;
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    var heads: std.ArrayList(u32) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Index = @enumFromInt(@as(u32, @intCast(i)));
        if (tree.nodeTag(node) != .lambda) continue;
        const head = tree.nodeMainToken(node);
        if (tags[head] == .backslash) try heads.append(scratch, starts[head]);
    }
    if (heads.items.len == 0) {
        try w.writeAll(source);
        return null;
    }
    std.mem.sort(u32, heads.items, {}, std.sort.asc(u32));

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(scratch, source.len + heads.items.len + 1);
    var at: u32 = 0;
    for (heads.items) |start| {
        out.appendSliceAssumeCapacity(source[at..start]);
        out.appendSliceAssumeCapacity(Token.lexeme(.lambda).?);
        at = start + 1;
    }
    out.appendSliceAssumeCapacity(source[at..]);
    const text = out.items;

    if (try reparseProblem(scratch, try scratch.dupeZ(u8, text))) |offset_and_code| {
        // Map the offset back: each rewrite before it added one byte.
        var shift: u32 = 0;
        for (heads.items) |start| {
            if (start + shift >= offset_and_code.start) break;
            shift += 1;
        }
        try w.writeAll(source);
        return .{ .code = offset_and_code.code, .start = offset_and_code.start - shift };
    }
    try w.writeAll(text);
    return null;
}

/// What `migrateNames` could not rewrite, at `start` in the source. A
/// `shadowed` or `alias_taken` note leaves the whole file alone; a
/// `method_shape` note names one use for a hand edit and the rest of the
/// file is still rewritten.
pub const NamesNote = struct {
    start: u32,
    kind: Kind,
    /// The removed name, or the alias, the note is about.
    name: []const u8,

    pub const Kind = enum {
        /// The file declares, binds or imports from another module a value
        /// with a removed name, so an unqualified use may not be
        /// `Basics`'s.
        shadowed,
        /// `Int` or `Float` is the alias of another module's import here,
        /// so `Int.mod` would not name core's module.
        alias_taken,
        /// `x.modBy` that is not a call with one argument.
        method_shape,
    };

    pub fn fatal(n: NamesNote) bool {
        return n.kind != .method_shape;
    }
};

/// `beni fmt --migrate-names` (frontend.md §11.4): `source` with every use
/// of `Basics.modBy`, `remainderBy` and `logBase` written as `Int.mod`,
/// `Int.rem` and `Float.log` (`prelude.removed`), and nothing else touched
/// — an edit, like `migrateLambda`. A use is found by the file's own names,
/// which is all lowering's resolution of it reads (language.md §6.2):
///
/// - an unqualified name, when nothing in the file declares or binds that
///   name and no other import exposes it — otherwise the file is left
///   alone, with a `shadowed` note, since the use may not be `Basics`'s;
/// - a qualified name whose alias is `Basics`'s (`Basics.modBy`, or
///   `B.modBy` under `import Basics as B`);
/// - an entry of `import Basics exposing (…)`, dropped, and the `exposing`
///   with it when nothing is left;
/// - a method `x.modBy k`, written `Int.mod x k` (the types stay in
///   `Basics`, so there is no `x.mod k`); one that is not called with one
///   argument is left and noted.
///
/// A file where `Int` or `Float` is the alias of another module's import is
/// left alone (`alias_taken`). The output is parsed again, as
/// `migrateLambda`'s is; a file with any syntax error is not touched. A
/// rewrite never writes a removed name, so running the flag again changes
/// nothing — except a method call whose receiver holds another use, whose
/// inner use the second run takes.
pub fn migrateNames(
    scratch: Allocator,
    tree: *const Ast,
    tokens: *const Token.TokenList,
    comments: []const Token.Comment,
    source: [:0]const u8,
    w: *Io.Writer,
    notes: *std.ArrayList(NamesNote),
) Error!?LambdaProblem {
    if (tree.errors.len != 0) return error.SyntaxErrors;
    const n = tree.nodes.len;
    var m: Measurer = .{
        .tree = tree,
        .tags = tokens.items(.tag),
        .starts = tokens.items(.start),
        .tok_lines = tokens.items(.line),
        .comments = comments,
        .source = source,
        .widths = try scratch.alloc(u32, n),
        .firsts = try scratch.alloc(u32, n),
        .lasts = try scratch.alloc(u32, n),
        .scratch = scratch,
    };
    defer m.stack.deinit(scratch);
    try m.measureRoot();
    const tags = m.tags;
    const starts = m.starts;

    // What each token is, for the tokens that matter: the main token of an
    // `ident` or a `field_access` (with the node), or an `exposed` entry of
    // an import of `Basics` or of another module.
    const Role = enum(u8) { none, ident, exposed_basics, exposed_other, method };
    const roles = try scratch.alloc(Role, tags.len);
    @memset(roles, .none);
    const role_node = try scratch.alloc(u32, tags.len);
    // Per node: its argument count when it is the function of an `apply`.
    const applied = try scratch.alloc(u32, n);
    @memset(applied, std.math.maxInt(u32));
    for (0..n) |i| {
        const node: Index = @enumFromInt(@as(u32, @intCast(i)));
        switch (tree.nodeTag(node)) {
            .ident, .field_access => |tag| {
                const t = tree.nodeMainToken(node);
                roles[t] = if (tag == .ident) .ident else .method;
                role_node[t] = @intCast(i);
            },
            .apply => {
                const a = tree.fullApply(node);
                applied[a.function.int()] = @intCast(a.args.len);
            },
            else => {},
        }
    }

    const Edit = struct { start: u32, end: u32, text: []const u8 };
    var edits: std.ArrayList(Edit) = .empty;
    var basics_aliases: std.ArrayList([]const u8) = .empty;
    var basics_shadowed = false;
    var fatal = false;

    // The imports: which aliases are `Basics`'s, which exposed entries are
    // its, and whether `Int` or `Float` names some other module here.
    const BasicsImport = struct { alias_end: u32, exposed: []const Index, removed: u32 };
    var basics_imports: std.ArrayList(BasicsImport) = .empty;
    for (tree.rootItems()) |item| {
        if (tree.nodeTag(item) != .import) continue;
        const imp = tree.fullImport(item);
        const name_token = imp.name orelse continue;
        const module = m.tokenText(name_token);
        const alias_token = imp.alias orelse name_token;
        const alias = m.tokenText(alias_token);
        const is_basics = std.mem.eql(u8, module, "Basics");
        for (imp.exposed) |e| roles[tree.nodeMainToken(e)] = if (is_basics) .exposed_basics else .exposed_other;
        if (is_basics) {
            try basics_aliases.append(scratch, alias);
            var removed: u32 = 0;
            for (imp.exposed) |e| {
                if (prelude.removedName(m.tokenText(tree.nodeMainToken(e))) != null) removed += 1;
            }
            if (removed != 0) try basics_imports.append(scratch, .{
                .alias_end = m.endOf(alias_token),
                .exposed = imp.exposed,
                .removed = removed,
            });
        } else if (std.mem.eql(u8, alias, "Basics")) {
            basics_shadowed = true;
        }
        if ((std.mem.eql(u8, alias, "Int") or std.mem.eql(u8, alias, "Float")) and !std.mem.eql(u8, module, alias)) {
            try notes.append(scratch, .{ .start = starts[alias_token], .kind = .alias_taken, .name = alias });
            fatal = true;
        }
    }
    if (!basics_shadowed) try basics_aliases.append(scratch, "Basics");

    for (tags, 0..) |tag, ti| {
        const t: u32 = @intCast(ti);
        switch (tag) {
            .lower_ident => {
                const r = prelude.removedName(m.tokenText(t)) orelse continue;
                switch (roles[t]) {
                    .ident => try edits.append(scratch, .{
                        .start = starts[t],
                        .end = m.endOf(t),
                        .text = try std.fmt.allocPrint(scratch, "{s}.{s}", .{ r.module, r.name }),
                    }),
                    // Dropped with its list, below.
                    .exposed_basics => {},
                    .exposed_other, .none, .method => {
                        try notes.append(scratch, .{ .start = starts[t], .kind = .shadowed, .name = r.old });
                        fatal = true;
                    },
                }
            },
            .qualified_lower => {
                const full = m.tokenText(t);
                const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse continue;
                const r = prelude.removedName(full[dot + 1 ..]) orelse continue;
                for (basics_aliases.items) |b| {
                    if (!std.mem.eql(u8, b, full[0..dot])) continue;
                    try edits.append(scratch, .{
                        .start = starts[t],
                        .end = m.endOf(t),
                        .text = try std.fmt.allocPrint(scratch, "{s}.{s}", .{ r.module, r.name }),
                    });
                    break;
                }
            },
            .dot_lower => {
                if (roles[t] != .method) continue;
                const r = prelude.removedName(m.tokenText(t)[1..]) orelse continue;
                const access = role_node[t];
                if (applied[access] != 1) {
                    try notes.append(scratch, .{ .start = starts[t], .kind = .method_shape, .name = r.old });
                    continue;
                }
                const target: Index = @enumFromInt(tree.nodeData(@enumFromInt(access)).lhs);
                const target_start = starts[m.first(target)];
                try edits.append(scratch, .{
                    .start = target_start,
                    .end = m.endOf(t),
                    .text = try std.fmt.allocPrint(scratch, "{s}.{s} {s}", .{ r.module, r.name, source[target_start..starts[t]] }),
                });
            },
            else => {},
        }
    }
    if (fatal) {
        try w.writeAll(source);
        return null;
    }

    // An `exposing` list that named a removed value: the list without it,
    // or no `exposing` at all when nothing is left.
    for (basics_imports.items) |b| {
        var close = tree.nodeMainToken(b.exposed[b.exposed.len - 1]);
        while (close < tags.len and tags[close] != .r_paren) close += 1;
        if (close == tags.len) continue;
        if (b.removed == b.exposed.len) {
            try edits.append(scratch, .{ .start = b.alias_end, .end = m.endOf(close), .text = "" });
            continue;
        }
        var open = tree.nodeMainToken(b.exposed[0]);
        while (open > 0 and tags[open] != .l_paren) open -= 1;
        var list: std.ArrayList(u8) = .empty;
        try list.append(scratch, '(');
        var any = false;
        for (b.exposed) |e| {
            const entry = m.tokenText(tree.nodeMainToken(e));
            if (prelude.removedName(entry) != null) continue;
            if (any) try list.appendSlice(scratch, ", ");
            try list.appendSlice(scratch, entry);
            any = true;
        }
        try list.append(scratch, ')');
        try edits.append(scratch, .{ .start = starts[open], .end = m.endOf(close), .text = list.items });
    }

    if (edits.items.len == 0) {
        try w.writeAll(source);
        return null;
    }
    std.mem.sort(Edit, edits.items, {}, struct {
        fn lessThan(_: void, a: Edit, b: Edit) bool {
            return a.start < b.start;
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    var at: u32 = 0;
    for (edits.items) |e| {
        // An edit inside a method call's receiver, which the outer edit
        // copied as written: the next run takes it.
        if (e.start < at) continue;
        try out.appendSlice(scratch, source[at..e.start]);
        try out.appendSlice(scratch, e.text);
        at = e.end;
    }
    try out.appendSlice(scratch, source[at..]);
    if (try reparseProblem(scratch, try scratch.dupeZ(u8, out.items))) |problem| {
        try w.writeAll(source);
        // Offsets move with the rewrite; the line of the first edit is
        // where to look.
        return .{ .code = problem.code, .start = edits.items[0].start };
    }
    try w.writeAll(out.items);
    return null;
}

/// The first lexical or syntax diagnostic of `text`, if any.
fn reparseProblem(scratch: Allocator, text: [:0]const u8) Allocator.Error!?LambdaProblem {
    var interner: InternPool.Local = .empty;
    var lexed: Tokenizer.Output = .empty;
    try Tokenizer.tokenize(scratch, text, &interner, &lexed);
    const lex_items = lexed.diagnostics.items();
    if (lex_items.len != 0) return .{ .code = lex_items[0].code, .start = lex_items[0].start };
    const tree = try Parse.parse(scratch, scratch, text, lexed.tokens.slice(), lexed.comments.items, lexed.line_starts.items, lex_items);
    if (tree.errors.len != 0) return .{ .code = tree.errors[0].code, .start = tree.errors[0].start };
    return null;
}

/// Whether every syntax error of `tree` is a lambda written with `\`
/// (`migrateLambda`'s input).
pub fn onlyBackslashLambdas(tree: *const Ast) bool {
    for (tree.errors) |e| {
        if (e.code != .backslash_lambda_removed) return false;
    }
    return true;
}

/// Whether every syntax error of `tree` is a `::` (`migrateCons`' input).
pub fn onlyConsRemoved(tree: *const Ast) bool {
    for (tree.errors) |e| {
        if (e.code != .cons_removed) return false;
    }
    return true;
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

fn isSchema(tag: Node.Tag) bool {
    return switch (tag) {
        .schema_decl,
        .schema_operand,
        .schema_paren,
        .schema_record,
        .schema_field,
        .schema_value,
        .schema_tagged,
        .schema_variant,
        .schema_as,
        .schema_via,
        .schema_optional,
        .schema_nullable,
        => true,
        else => false,
    };
}

/// Markup and the vocabulary declarations (language.md §11.15), measured
/// and printed apart for `isSchema`'s reason: the recursive frames of the
/// expression printer stay the size they were.
fn isMarkup(tag: Node.Tag) bool {
    return switch (tag) {
        .markup_element,
        .markup_fragment,
        .markup_for,
        .markup_show,
        .markup_attr,
        .markup_attr_escape,
        .markup_spread,
        .markup_text,
        .markup_hole,
        .markup_empty_hole,
        .vocab_element,
        .vocab_attribute,
        .vocab_event,
        .vocab_markup,
        => true,
        else => false,
    };
}

/// Whitespace in the sense of language.md §11.4: the Unicode set.
fn isBlank(line: []const u8) bool {
    return markupWhitespaceEnd(line, 0) == line.len;
}

/// The end of the whitespace (§11.4's Unicode set, `\r` included) that
/// starts at `from`.
fn markupWhitespaceEnd(line: []const u8, from: usize) usize {
    var i = from;
    while (i < line.len) {
        const n = markup_text.whitespaceAt(line, i);
        if (n == 0) break;
        i += n;
    }
    return i;
}

/// `line` without its trailing whitespace (§11.4's set).
fn trimMarkupEnd(line: []const u8) []const u8 {
    var end: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const n = markup_text.whitespaceAt(line, i);
        if (n == 0) {
            i += 1;
            end = i;
        } else i += n;
    }
    return line[0..end];
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

    fn tokenText(m: *const Measurer, t: TokenIndex) []const u8 {
        return m.source[m.starts[t]..m.endOf(t)];
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

    /// The source text of `n`, byte for byte.
    fn sourceOf(m: *const Measurer, n: Index) []const u8 {
        const last_tok = m.last(n);
        return m.source[m.starts[m.first(n)]..Tokenizer.tokenEnd(m.source, m.tags[last_tok], m.starts[last_tok])];
    }

    /// `migrateCons`' rewrite of the `::` chain `n`, spanning source bytes
    /// `[start, end)`, into `out`; false when it cannot be written.
    fn bracketForm(m: *const Measurer, n: Index, start: u32, end: u32, out: *std.ArrayList(u8)) Error!bool {
        const tree = m.tree;
        if (tree.nodeTag(n) == .op_fn) {
            try out.appendSlice(m.scratch, "List.cons");
            return true;
        }
        var items: std.ArrayList(Index) = .empty;
        var tail = n;
        while (true) {
            const tag = tree.nodeTag(tail);
            if (tag == .cons or tag == .pat_cons) {
                const d = tree.nodeData(tail);
                try items.append(m.scratch, @enumFromInt(d.lhs));
                tail = @enumFromInt(d.rhs);
            } else if ((tag == .paren or tag == .pat_paren) and
                (tree.nodeTag(tree.operand(tail)) == .cons or tree.nodeTag(tree.operand(tail)) == .pat_cons))
            {
                tail = tree.operand(tail);
            } else break;
        }
        // A comment between the items would be lost with the operators.
        var covered: u32 = 0;
        for (m.comments) |cm| {
            if (cm.start >= start and cm.start < end) covered += 1;
        }
        var inside: u32 = 0;
        for (items.items) |item| inside += m.commentsWithin(item);
        inside += m.commentsWithin(tail);
        if (covered != inside) return false;

        try out.appendSlice(m.scratch, "[ ");
        for (items.items, 0..) |item, i| {
            if (i != 0) try out.appendSlice(m.scratch, ", ");
            try out.appendSlice(m.scratch, m.sourceOf(item));
        }
        var bare = tail;
        while (tree.nodeTag(bare) == .paren or tree.nodeTag(bare) == .pat_paren) bare = tree.operand(bare);
        switch (tree.nodeTag(bare)) {
            .list, .pat_list => for (tree.children(bare)) |item| {
                try out.appendSlice(m.scratch, ", ");
                try out.appendSlice(m.scratch, m.sourceOf(item));
            },
            .pat_var, .pat_wild => {
                try out.appendSlice(m.scratch, ", ...");
                try out.appendSlice(m.scratch, m.sourceOf(bare));
            },
            else => {
                // A pattern spread's operand is a name or `_` (§6.8).
                if (tree.nodeTag(n) == .pat_cons) return false;
                try out.appendSlice(m.scratch, ", ...");
                try out.appendSlice(m.scratch, m.sourceOf(tail));
            },
        }
        try out.appendSlice(m.scratch, " ]");
        return true;
    }

    /// How many comments start inside `n`'s span.
    fn commentsWithin(m: *const Measurer, n: Index) u32 {
        const start = m.starts[m.first(n)];
        const last_tok = m.last(n);
        const end = Tokenizer.tokenEnd(m.source, m.tags[last_tok], m.starts[last_tok]);
        var count: u32 = 0;
        for (m.comments) |cm| {
            if (cm.start >= start and cm.start < end) count += 1;
        }
        return count;
    }

    fn last(m: *const Measurer, n: Index) u32 {
        return m.lasts[n.int()];
    }

    /// The byte after token `t`.
    fn endOf(m: *const Measurer, t: u32) u32 {
        return Tokenizer.tokenEnd(m.source, m.tags[t], m.starts[t]);
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

    /// Measure a header's `where` constraints and return the declaration's
    /// last token: the clause's, when there is one (static-dispatch-spike.md
    /// §2.5). The constraints must be measured — the printer reads their
    /// `firsts` to find the `where` and the commas — and the declaration's
    /// span must cover them, or a comment inside the clause is attributed
    /// to the declaration after it.
    fn whereClause(m: *Measurer, header: Ast.DeclHeader, type_last: u32) Error!u32 {
        const constraints = m.tree.whereConstraints(header);
        var last_tok = type_last;
        for (constraints) |c| {
            try m.measure(c);
            last_tok = m.last(c);
        }
        return last_tok;
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
        if (isSchema(tag)) return m.measureSchema(n);
        if (isMarkup(tag)) return m.measureMarkup(n);
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
            .where_constraint => {
                // `k.compare : k, k -> Order` — the variable and the method
                // abut, then ` : ` and the type (§2.1).
                const c = tree.fullWhereConstraint(n);
                try m.measure(c.type_expr);
                m.set(n, m.tokenWidth(c.variable) +| m.tokenWidth(c.method) +| 3 +| m.w(c.type_expr), c.variable, m.last(c.type_expr));
            },
            .annotation => {
                const a = tree.fullAnnotation(n);
                try m.measure(a.type_expr);
                const pub_width: u32 = if (a.header.pub_token != .none) 4 else 0;
                const width = pub_width + m.tokenWidth(a.name) + 3 +| m.w(a.type_expr);
                m.set(n, width, a.header.pub_token.unwrap() orelse a.name, try m.whereClause(a.header, m.last(a.type_expr)));
                // A `where` clause is always vertical (§2.5), so the
                // annotation has no single-line form once it has one.
                if (a.header.where_end != a.header.where_start) m.widths[n.int()] = no_fit;
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
                // `foreign ` and, when present, the rung and its space.
                const has_rung = m.tags[main - 1] == .lower_ident;
                const rung_width: u32 = if (has_rung) m.tokenWidth(main - 1) + 1 else 0;
                const width = pub_width + 8 + rung_width + m.tokenWidth(f.name) + 3 +| m.w(f.type_expr);
                m.set(n, width, m.headerFirst(f.header, if (has_rung) main - 2 else main - 1), try m.whereClause(f.header, m.last(f.type_expr)));
                if (f.header.where_end != f.header.where_start) m.widths[n.int()] = no_fit;
            },
            .foreign_type => {
                const f = tree.fullForeignType(n);
                const last_tok = if (f.params.len == 0) main else f.params[f.params.len - 1];
                m.set(n, no_fit, m.headerFirst(f.header, main - 2), last_tok);
            },
            .schema_decl, .schema_operand, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable => unreachable,
            .type_con => try m.headed(n, m.tokenWidth(main), main, main, tree.children(n), true),
            .type_fn => {
                // `A, B -> C` (§9, function types): the parameter list is a
                // multi-element construct like any other, so a source break
                // anywhere along it — between two parameters, or before the
                // `->` — keeps the whole type vertical.
                const f = tree.fullTypeFn(n);
                var width: u32 = 0;
                for (f.params, 0..) |param, i| {
                    try m.measure(param);
                    width +|= (if (i == 0) @as(u32, 0) else 2) +| m.w(param);
                }
                try m.measure(f.result);
                width +|= 4 +| m.w(f.result);
                const last_param = f.params[f.params.len - 1];
                if (m.brokenBetween(m.first(f.params[0]), f.params[1..], null) or
                    m.tok_lines[m.last(last_param)] != m.tok_lines[m.first(f.result)]) width = no_fit;
                m.set(n, width, m.first(f.params[0]), m.last(f.result));
            },
            .type_unit, .unit, .pat_unit => m.set(n, 2, main, main + 1),
            .placeholder => m.set(n, 1, main, main),
            .type_paren, .paren, .pat_paren => try m.wrapped(n, tree.operand(n)),
            // `sync ` and the parenthesised type (transparent-effects-proposal.md §15.2).
            .type_sync => {
                const inner = tree.operand(n);
                try m.measure(inner);
                m.set(n, m.w(inner) +| 5, main, m.last(inner));
            },
            .type_tuple, .tuple, .list, .record, .pat_tuple, .pat_list => try m.collection(n, tree.children(n)),
            .type_record => {
                if (m.tags[main] == .l_brace) {
                    try m.collection(n, tree.children(n));
                } else {
                    try m.fieldBlock(n, tree.children(n));
                }
            },
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
            // `...xs` and `...rest`: the `...` against its operand
            // (language.md §6.8, §9).
            .spread, .pat_spread => {
                const e = tree.operand(n);
                try m.measure(e);
                m.set(n, 3 +| m.w(e), main, m.last(e));
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
            // `if c then a else b` (language.md §12.5): the sum of its parts
            // when the author wrote it on one line and each part has a
            // one-line form, else `no_fit`. An `else if` chain is one `if`:
            // its tail is measured the same way and carried by the sum.
            .@"if" => {
                const i = tree.fullIf(n);
                try m.measure(i.cond);
                try m.measure(i.then_expr);
                try m.measure(i.else_expr);
                const last_tok = m.last(i.else_expr);
                const width = if (m.tok_lines[main] != m.tok_lines[last_tok])
                    no_fit
                else
                    3 +| m.w(i.cond) +| 6 +| m.w(i.then_expr) +| 6 +| m.w(i.else_expr);
                m.set(n, width, main, last_tok);
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

    /// Markup (language.md §11.15), kept out of `measure` for
    /// `measureSchema`'s reason. An element's width is its one-line
    /// rendering, `<div />` for one with no children; a line break anywhere
    /// in it — between attributes, in a text run, in a child — makes it
    /// `no_fit`, which is what keeps an element the author broke vertical.
    fn measureMarkup(m: *Measurer, n: Index) Error!void {
        const tree = m.tree;
        const tag = tree.nodeTag(n);
        const main = tree.nodeMainToken(n);
        switch (tag) {
            .markup_element, .markup_fragment, .markup_for, .markup_show => {
                const mk = tree.fullMarkup(n);
                const name_width: u32 = if (mk.name) |t| m.tokenWidth(t) else 0;
                var width: u32 = 1 + name_width;
                var prev: TokenIndex = mk.name orelse mk.open;
                var broken = false;
                for (mk.attrs) |a| {
                    try m.measure(a);
                    width +|= 1 +| m.w(a);
                    if (m.tok_lines[m.first(a)] != m.tok_lines[prev]) broken = true;
                    prev = m.last(a);
                }
                const open_end = mk.open_end orelse return error.SyntaxErrors;
                if (m.tok_lines[open_end] != m.tok_lines[prev]) broken = true;
                var last_tok = open_end;
                if (mk.children.len == 0 and mk.name != null) {
                    width +|= 3; // ` />`
                } else {
                    width +|= 1;
                    for (mk.children) |c| {
                        try m.measure(c);
                        width +|= m.w(c);
                    }
                    width +|= 3 +| name_width;
                }
                if (mk.close) |c| last_tok = c + @as(u32, if (mk.name != null) 2 else 1);
                m.set(n, if (broken) no_fit else width, mk.open, last_tok);
            },
            .markup_text => {
                const text = Tokenizer.slice(m.source, .markup_text, m.starts[main]);
                const width = if (std.mem.indexOfScalar(u8, text, '\n') == null) m.tokenWidth(main) else no_fit;
                m.set(n, width, main, main);
            },
            .markup_hole => {
                const e = tree.operand(n);
                try m.measure(e);
                m.set(n, 2 +| m.w(e), main, m.last(e) + 1);
            },
            .markup_empty_hole => m.set(n, 2, main, main + 1),
            .markup_spread => {
                const e = tree.operand(n);
                try m.measure(e);
                // Braces without the `...`, on an element, are lowering's
                // error, and are printed as written.
                const dots: u32 = if (m.tags[main + 1] == .ellipsis) 3 else 0;
                m.set(n, 2 +| dots +| m.w(e), main, m.last(e) + 1);
            },
            .markup_attr => {
                const a = tree.fullMarkupAttr(n);
                const value = a.value orelse return m.leaf(n);
                try m.measure(value);
                if (a.brace != null) {
                    m.set(n, m.tokenWidth(main) + 3 +| m.w(value), main, m.last(value) + 1);
                } else {
                    m.set(n, m.tokenWidth(main) + 1 +| m.w(value), main, m.last(value));
                }
            },
            .markup_attr_escape => {
                const a = tree.fullMarkupAttr(n);
                const name = a.name_string.?;
                try m.measure(name);
                const value = a.value orelse return m.set(n, m.w(name), main, m.last(name));
                try m.measure(value);
                const braced = a.brace != null;
                const extra: u32 = if (braced) 3 else 1;
                m.set(n, m.w(name) +| extra +| m.w(value), main, m.last(value) + @intFromBool(braced));
            },
            .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => {
                const v = tree.fullVocab(n);
                if (v.name_string) |s| try m.measure(s);
                var last_tok: TokenIndex = if (v.name_string) |s| m.last(s) else v.name;
                if (v.facts_end > v.facts_start) last_tok = v.facts_end - 1;
                if (v.type_expr) |t| {
                    try m.measure(t);
                    last_tok = m.last(t);
                }
                m.set(n, no_fit, v.header.pub_token.unwrap() orelse v.word, last_tok);
            },
            else => unreachable,
        }
    }

    /// Kept out of `measure` so adding the schema grammar does not enlarge
    /// every recursive expression/type formatter frame. The parser permits
    /// 4,096 nested ordinary nodes and the formatter's depth corpus spends
    /// that stack budget deliberately.
    fn measureSchema(m: *Measurer, n: Index) Error!void {
        const tree = m.tree;
        const tag = tree.nodeTag(n);
        const main = tree.nodeMainToken(n);
        switch (tag) {
            .schema_decl => {
                const s = tree.fullSchemaDecl(n);
                try m.measure(s.body);
                m.set(n, no_fit, s.header.pub_token.unwrap() orelse main - 1, m.last(s.body));
            },
            .schema_operand => try m.headed(n, m.tokenWidth(main), main, main, tree.children(n), true),
            .schema_paren => try m.wrapped(n, tree.operand(n)),
            .schema_record => {
                if (m.tags[main] == .l_brace) {
                    try m.collection(n, tree.children(n));
                } else {
                    try m.fieldBlock(n, tree.children(n));
                }
            },
            .schema_field, .schema_value => {
                const f = tree.fullSchemaField(n);
                try m.measure(f.operand);
                var width = m.tokenWidth(f.name) +| 3 +| m.w(f.operand);
                var last_tok = m.last(f.operand);
                for (f.modifiers) |modifier| {
                    try m.measure(modifier);
                    width +|= 1 +| m.w(modifier);
                    last_tok = m.last(modifier);
                }
                m.set(n, width, f.name, last_tok);
            },
            .schema_tagged => {
                const t = tree.fullSchemaTagged(n);
                try m.measure(t.discriminator);
                var last_tok = m.last(t.discriminator) + 1; // `of`
                for (t.variants) |variant| {
                    try m.measure(variant);
                    last_tok = m.last(variant);
                }
                m.set(n, no_fit, main, last_tok);
            },
            .schema_variant => {
                const v = tree.fullSchemaVariant(n);
                var width = m.tokenWidth(v.name);
                var last_tok = v.name;
                if (v.payload) |payload| {
                    try m.measure(payload);
                    width +|= 1 +| m.w(payload);
                    last_tok = m.last(payload);
                }
                if (v.rename) |rename| {
                    try m.measure(rename);
                    width +|= 1 +| m.w(rename);
                    last_tok = @max(last_tok, m.last(rename));
                }
                m.set(n, width, v.name, last_tok);
            },
            .schema_as, .schema_via => {
                const value = tree.operand(n);
                try m.measure(value);
                m.set(n, m.tokenWidth(main) +| 1 +| m.w(value), main, m.last(value));
            },
            .schema_optional, .schema_nullable => m.leaf(n),
            else => unreachable,
        }
    }

    /// A layout field block has the same record node and children as its
    /// brace spelling, but no delimiter tokens. It is always vertical and
    /// spans exactly its fields.
    fn fieldBlock(m: *Measurer, n: Index, fields: []const Index) Error!void {
        std.debug.assert(fields.len != 0);
        for (fields) |field| try m.measure(field);
        m.set(n, no_fit, m.first(fields[0]), m.last(fields[fields.len - 1]));
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

    /// Whether `n` holds no comment and prints on one line whatever its
    /// width — a literal, a name, an access chain on one, markup written on
    /// one line (which after a `{` is on its line, `markupAt`), or a hole
    /// around one — so a line break around it could not shorten any line.
    fn unbreakable(p: *const Printer, n: Index) bool {
        if (p.widths[n.int()] == no_fit) return false;
        var x = n;
        while (true) switch (p.tree.nodeTag(x)) {
            .field_access, .tuple_index, .question, .negate, .markup_hole, .markup_spread => x = p.tree.operand(x),
            .int, .float, .char, .ident, .ctor, .accessor, .placeholder, .unit, .op_fn, .string, .markup_empty_hole => return true,
            .markup_element, .markup_fragment, .markup_for, .markup_show => return true,
            else => return false,
        };
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
        for (cs, 0..) |c, k| {
            const line = p.commentLine(c);
            if (line == prev_line) continue; // trails the previous token: printed with it
            const blank = allow_blank and line > prev_line + 1;
            const ind = indent orelse if (p.pending > 0) p.next_indent else if (p.col == p.line_indent) p.line_indent else p.line_indent + indent_step;
            p.blankLines(if (blank) 1 else 0, ind);
            try p.writeComment(c);
            const blank_after = blank_ok and k + 1 == cs.len and p.blankAfterComment(c, t);
            p.blankLines(if (blank_after) 1 else 0, ind);
            prev_line = line;
            allow_blank = true;
        }
    }

    /// Whether the canonical form keeps a blank line between the standalone
    /// comment `c` and the token `t` right after it (language.md §12.5, *a
    /// blank line after a comment*): the source has one, `c` is a plain
    /// comment (a doc comment sits on what it documents), and `t` opens
    /// something a comment may label — not `then`, `else`, `in` or `of`,
    /// which §9 never puts a blank line before, nor a closing bracket or
    /// the end of the file, which have nothing to label.
    fn blankAfterComment(p: *const Printer, c: Token.Comment, t: TokenIndex) bool {
        if (c.kind != .plain) return false;
        switch (p.tags[t]) {
            .keyword_then, .keyword_else, .keyword_in, .keyword_of => return false,
            .r_paren, .r_bracket, .r_brace, .interp_end, .eof => return false,
            .markup_gt, .markup_self_close, .markup_close_open => return false,
            else => {},
        }
        return p.tok_lines[t] > p.commentLine(c) + 1;
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
            const blank_after = (in_doc and i + 1 == doc.end) or (i + 1 == hi and p.blankAfterComment(c, 0));
            p.blankLines(if (blank_after) 1 else 0, 0);
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
                try p.whereClause(a.header);
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
                if (tree.nodeTag(a.body) == .type_record and tree.children(a.body).len != 0) {
                    try p.typeFieldBlock(a.body, indent_step);
                } else {
                    try p.typ(a.body, indent_step);
                }
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
                // `foreign`, then the rung when the parser found one
                // (transparent-effects-proposal.md §14.1).
                if (p.tags[main - 1] == .lower_ident) {
                    try p.tok(main - 2);
                    try p.space();
                    try p.tok(main - 1);
                } else {
                    try p.tok(main - 1);
                }
                try p.space();
                try p.tok(f.name);
                try p.space();
                try p.tok(f.name + 1); // `:`
                try p.annotated(f.type_expr, 0);
                try p.whereClause(f.header);
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
            .schema_decl => {
                const s = tree.fullSchemaDecl(n);
                try p.header(s.header);
                try p.tok(s.name - 1); // contextual `schema`
                try p.space();
                try p.tok(s.name);
                var body_marker = s.name + 1;
                for (s.params) |param| {
                    try p.space();
                    try p.tok(param);
                    body_marker = param + 1;
                }
                if (tree.nodeTag(s.body) == .schema_tagged) {
                    try p.space();
                    try p.schemaTagged(s.body, 0);
                } else {
                    try p.space();
                    try p.tok(body_marker); // `=`
                    p.newline(indent_step);
                    try p.schemaBody(s.body, indent_step);
                }
            },
            .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => try p.vocab(n),
            else => return error.SyntaxErrors,
        }
    }

    /// The right-hand side after `schema X =`. A declaration-level
    /// modifier list uses `schema_value` as a compact AST carrier; it has
    /// no source field name or colon, so print only its operand and
    /// modifiers here.
    fn schemaBody(p: *Printer, n: Index, indent: u32) Error!void {
        if (p.tree.nodeTag(n) == .schema_record and p.tree.children(n).len != 0) {
            return p.schemaFieldBlock(n, indent);
        }
        if (p.tree.nodeTag(n) != .schema_value) return p.schemaNode(n, indent);
        const body = p.tree.fullSchemaField(n);
        try p.schemaNode(body.operand, indent);
        try p.schemaModifiers(body.modifiers, indent);
    }

    fn schemaNode(p: *Printer, n: Index, indent: u32) Error!void {
        const tree = p.tree;
        const main = tree.nodeMainToken(n);
        switch (tree.nodeTag(n)) {
            .schema_operand => {
                const operands = tree.children(n);
                const one_line = p.fits(n);
                try p.tok(main);
                try p.schemaArgs(main, operands, one_line, indent);
            },
            .schema_paren => {
                const inner = tree.operand(n);
                const one_line = p.fits(n);
                const col = p.curCol();
                try p.tok(main);
                if (one_line) {
                    try p.schemaNode(inner, indent);
                    try p.tok(p.last(inner) + 1);
                } else {
                    try p.schemaNode(inner, col);
                    p.newline(col);
                    try p.tok(p.last(inner) + 1);
                }
            },
            .schema_record => try p.schemaRecord(n, indent),
            else => return error.SyntaxErrors,
        }
    }

    fn schemaArgs(p: *Printer, head: TokenIndex, operands: []const Index, one_line: bool, indent: u32) Error!void {
        var inline_count: usize = 0;
        if (one_line) {
            inline_count = operands.len;
        } else {
            var prev = head;
            while (inline_count < operands.len and p.tok_lines[p.first(operands[inline_count])] == p.tok_lines[prev]) : (inline_count += 1) {
                prev = p.last(operands[inline_count]);
            }
            if (inline_count == operands.len) inline_count = 0;
        }
        for (operands, 0..) |arg, i| {
            if (i < inline_count) {
                try p.space();
                try p.schemaNode(arg, indent);
            } else {
                p.newline(indent + indent_step);
                try p.schemaNode(arg, indent + indent_step);
            }
        }
    }

    fn schemaRecord(p: *Printer, n: Index, indent: u32) Error!void {
        const fields = p.tree.children(n);
        const open = p.tree.nodeMainToken(n);
        const one_line = p.fits(n);
        const col = p.curCol();
        if (fields.len == 0) {
            try p.tok(open);
            try p.tok(open + 1);
            return;
        }
        for (fields, 0..) |field_node, i| {
            const delimiter = if (i == 0) open else p.last(fields[i - 1]) + 1;
            if (i > 0) {
                if (!one_line) p.newline(col);
            }
            const doc_moved = try p.schemaFieldDelimiter(delimiter, p.first(field_node), col + 2);
            if (!doc_moved) try p.space();
            try p.schemaField(field_node, if (one_line) indent else col);
        }
        if (one_line) try p.space() else p.newline(col);
        try p.tok(p.last(fields[fields.len - 1]) + 1);
    }

    /// A declaration schema record, or a nested whole-field record, in its
    /// canonical delimiter-free layout spelling. Brace input reaches the
    /// same AST node; drop its delimiters while retaining their comments.
    fn schemaFieldBlock(p: *Printer, n: Index, indent: u32) Error!void {
        return p.schemaFieldBlockWith(n, indent, false);
    }

    fn schemaFieldBlockWith(p: *Printer, n: Index, indent: u32, suppress_close_trailing: bool) Error!void {
        const fields = p.tree.children(n);
        std.debug.assert(fields.len != 0);
        const open = p.tree.nodeMainToken(n);
        const braced = p.tags[open] == .l_brace;
        for (fields, 0..) |field_node, i| {
            if (i != 0) p.newline(indent);
            if (braced) {
                const delimiter = if (i == 0) open else p.last(fields[i - 1]) + 1;
                try p.dropLayoutDelimiter(delimiter, p.first(field_node), indent);
            }
            try p.schemaField(field_node, indent);
        }
        if (braced) {
            const close = p.last(fields[fields.len - 1]) + 1;
            if (suppress_close_trailing) {
                try p.leading(close, indent);
                p.trailing_done = close;
            } else {
                try p.skipTok(close);
            }
        }
    }

    /// Drop a brace, comma or bar whose layout spelling has no token, and
    /// move every comment between it and the following item to that item's
    /// column. This is the delimiter-free counterpart of
    /// `schemaFieldDelimiter`.
    fn dropLayoutDelimiter(p: *Printer, delimiter: TokenIndex, item_token: TokenIndex, indent: u32) Io.Writer.Error!void {
        try p.leading(delimiter, indent);
        p.trailing_done = delimiter;
        p.leading_done = item_token;

        var prev_line = p.tok_lines[delimiter];
        const cs = commentsBefore(p.comments, item_token);
        for (cs, 0..) |c, k| {
            const line = p.commentLine(c);
            p.blankLines(if (line > prev_line + 1) 1 else 0, indent);
            try p.writeComment(c);
            p.blankLines(if (k + 1 == cs.len and p.blankAfterComment(c, item_token)) 1 else 0, indent);
            prev_line = line;
        }
    }

    /// Print the `{` or leading `,` before a schema field. A field doc written
    /// after that delimiter belongs to the field, so canonicalise it onto its
    /// own line at the column an undocumented field would occupy. Plain
    /// trailing comments retain the generic token layout.
    fn schemaFieldDelimiter(p: *Printer, delimiter: TokenIndex, field_token: TokenIndex, indent: u32) Io.Writer.Error!bool {
        const cs = commentsBefore(p.comments, field_token);
        var has_doc = false;
        for (cs) |c| {
            if (c.kind == .doc) {
                has_doc = true;
                break;
            }
        }
        if (!has_doc) {
            try p.tok(delimiter);
            return false;
        }

        try p.leading(delimiter, null);
        try p.raw(p.text(delimiter));
        p.trailing_done = delimiter;
        p.leading_done = field_token;

        var prev_line = p.tok_lines[delimiter];
        // The last comment is the field's doc comment (a plain one cannot
        // come between a doc comment and its field), so no blank line
        // follows it (language.md §12.5).
        for (cs) |c| {
            const line = p.commentLine(c);
            if (line == p.tok_lines[delimiter] and c.kind == .plain) {
                try p.space();
            } else {
                p.blankLines(if (line > prev_line + 1) 1 else 0, indent);
            }
            try p.writeComment(c);
            p.newline(indent);
            prev_line = line;
        }
        return true;
    }

    fn schemaField(p: *Printer, n: Index, indent: u32) Error!void {
        const schema_field = p.tree.fullSchemaField(n);
        try p.tok(schema_field.name);
        try p.space();
        try p.tok(schema_field.name + 1); // `:`
        if (p.tree.nodeTag(schema_field.operand) == .schema_record and
            p.tree.children(schema_field.operand).len != 0 and
            schema_field.modifiers.len == 0)
        {
            p.newline(indent + indent_step);
            return p.schemaFieldBlock(schema_field.operand, indent + indent_step);
        }
        try p.space();
        try p.schemaNode(schema_field.operand, indent);
        try p.schemaModifiers(schema_field.modifiers, indent);
    }

    fn schemaModifiers(p: *Printer, modifiers: []const Index, indent: u32) Error!void {
        for (modifiers) |modifier| {
            try p.space();
            const main = p.tree.nodeMainToken(modifier);
            switch (p.tree.nodeTag(modifier)) {
                .schema_optional, .schema_nullable => try p.tok(main),
                .schema_as => {
                    try p.tok(main);
                    try p.space();
                    const value = p.tree.operand(modifier);
                    try p.expr(value, indent);
                },
                .schema_via => {
                    try p.tok(main);
                    try p.space();
                    try p.expr(p.tree.operand(modifier), indent);
                },
                else => return error.SyntaxErrors,
            }
        }
    }

    fn schemaTagged(p: *Printer, n: Index, indent: u32) Error!void {
        const tagged = p.tree.fullSchemaTagged(n);
        const main = p.tree.nodeMainToken(n);
        try p.tok(main); // contextual `tagged`
        try p.space();
        try p.expr(tagged.discriminator, indent);
        try p.space();
        try p.tok(p.last(tagged.discriminator) + 1); // `of`
        for (tagged.variants, 0..) |variant, i| {
            p.newline(indent + indent_step);
            if (p.first(variant) > 0 and p.tags[p.first(variant) - 1] == .pipe) {
                try p.dropLayoutDelimiter(p.first(variant) - 1, p.first(variant), indent + indent_step);
            }
            const comment_indent = if (i + 1 < tagged.variants.len) indent + indent_step else indent;
            try p.schemaLayoutVariant(variant, indent + indent_step, comment_indent);
        }
    }

    fn schemaLayoutVariant(p: *Printer, n: Index, indent: u32, deferred_comment_indent: u32) Error!void {
        const variant = p.tree.fullSchemaVariant(n);
        const reordered = if (variant.payload) |payload|
            if (variant.rename) |rename| p.first(rename) > p.last(payload) else false
        else
            false;
        // The old brace spelling stores payload before rename. Its comments
        // must stay after the payload even though the canonical head moves
        // `as "tag"` in front of it. They are emitted below, at the next
        // variant/declaration column, which is also their fixed-point home.
        try p.tok(variant.name);
        if (variant.rename) |rename| {
            try p.space();
            if (reordered) {
                // The old brace spelling stores payload before rename. The
                // canonical layout head reverses those source token ranges,
                // so copy the literal without revisiting its moved comments.
                try p.raw(p.text(p.first(rename) - 1)); // `as`
                try p.space();
                const last_token = p.last(rename);
                const end = Tokenizer.tokenEnd(p.source, p.tags[last_token], p.starts[last_token]);
                try p.raw(p.source[p.starts[p.first(rename)]..end]);
                p.trailing_done = last_token;
            } else {
                try p.tok(p.first(rename) - 1); // `as`
                try p.space();
                try p.expr(rename, indent);
            }
        }
        if (variant.payload) |payload| {
            if (p.tree.children(payload).len == 0) {
                try p.space();
                if (reordered) {
                    const open = p.tree.nodeMainToken(payload);
                    try p.tok(open);
                    try p.leading(open + 1, indent);
                    try p.raw(p.text(open + 1));
                    p.trailing_done = open + 1;
                } else {
                    try p.schemaRecord(payload, indent);
                }
            } else {
                p.newline(indent + indent_step);
                try p.schemaFieldBlockWith(payload, indent + indent_step, reordered);
            }
        }
        if (reordered) {
            const payload = variant.payload.?;
            const rename = variant.rename.?;
            var prev_line = p.tok_lines[p.last(payload)];
            try p.writeMovedCommentsBefore(p.first(rename) - 1, deferred_comment_indent, &prev_line);
            try p.writeMovedCommentsBefore(p.first(rename), deferred_comment_indent, &prev_line);
            const after_rename = p.last(rename) + 1;
            for (commentsBefore(p.comments, after_rename)) |c| {
                const line = p.commentLine(c);
                if (line != p.tok_lines[p.last(rename)]) break;
                p.blankLines(if (line > prev_line + 1) 1 else 0, deferred_comment_indent);
                try p.writeComment(c);
                p.newline(deferred_comment_indent);
                prev_line = line;
            }
        }
    }

    fn writeMovedCommentsBefore(p: *Printer, token: TokenIndex, indent: u32, prev_line: *u32) Io.Writer.Error!void {
        for (commentsBefore(p.comments, token)) |c| {
            const line = p.commentLine(c);
            p.blankLines(if (line > prev_line.* + 1) 1 else 0, indent);
            try p.writeComment(c);
            p.newline(indent);
            prev_line.* = line;
        }
    }

    /// The `where` clause of a top-level annotation or `foreign` value
    /// (static-dispatch-spike.md §2.5): never joined to the annotation's
    /// own line, never reordered. One constraint shares the `where` line;
    /// two or more put `where` alone and one constraint per line indented
    /// 8, with a leading comma from the second on — the vertical form a
    /// list takes. The `where` token is the one before the first
    /// constraint and each comma the one before the constraint it leads,
    /// exactly as `|` is found in a `type` declaration.
    fn whereClause(p: *Printer, h: Ast.DeclHeader) Error!void {
        const constraints = p.tree.whereConstraints(h);
        if (constraints.len == 0) return;
        p.newline(indent_step);
        try p.tok(p.first(constraints[0]) - 1); // `where`
        if (constraints.len == 1) {
            try p.space();
            try p.constraint(constraints[0], indent_step);
            return;
        }
        for (constraints, 0..) |c, i| {
            p.newline(2 * indent_step);
            if (i != 0) {
                try p.tok(p.first(c) - 1); // `,`
                try p.space();
            }
            try p.constraint(c, 2 * indent_step);
        }
    }

    /// `k.compare : k, k -> Order`. The type is printed FLAT: like a
    /// pattern it overflows the guide rather than breaking (§2.5).
    fn constraint(p: *Printer, n: Index, indent: u32) Error!void {
        const c = p.tree.fullWhereConstraint(n);
        try p.tok(c.variable);
        try p.tok(c.method); // `.m`, abutting its variable (§2.1)
        try p.space();
        try p.tok(c.method + 1); // `:`
        try p.space();
        const saved = p.flat;
        p.flat = true;
        defer p.flat = saved;
        try p.typ(c.type_expr, indent);
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

    /// ` params =` and the body, for top-level and `let` definitions alike.
    fn defBody(p: *Printer, name: TokenIndex, params: []const Index, body: Index, indent: u32) Error!void {
        var eq = name + 1;
        for (params) |param| {
            try p.space();
            try p.pat(param, indent);
            eq = p.last(param) + 1;
        }
        try p.space();
        try p.tok(eq);
        try p.rhs(body, indent);
    }

    /// A definition's body after its `=` (language.md §9, amended
    /// 2026-10-02): on the `=` line when it has a one-line form that fits
    /// there and no comment sits between `=` and it, otherwise on the next
    /// line indented 4. A break directly after `=` is not a break between
    /// elements, so it never pins the vertical form: the body's own width,
    /// which already records every break the author wrote inside it (and
    /// is `no_fit` for `if`, `case`, `let`, a multiline string and a
    /// comment inside), is the whole test.
    fn rhs(p: *Printer, body: Index, indent: u32) Error!void {
        if (p.fitsAt(body, p.curCol() + 1) and commentsBefore(p.comments, p.first(body)).len == 0) {
            try p.space();
            try p.expr(body, indent);
        } else {
            p.newline(indent + indent_step);
            try p.expr(body, indent + indent_step);
        }
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

    /// Whether an application that must break hangs its last argument
    /// (language.md §12.5, *hanging the last argument*): the last argument
    /// is a list, a record, a record update or markup, and the callee with
    /// every other argument fits on one line from the cursor with no comment
    /// between them. The source breaks between those are not consulted —
    /// the one place the never-join rule does not hold — so the head line a
    /// first run writes is the head line every later run keeps.
    ///
    /// A lambda is the other kind §12.5 hangs, and the only one that joins
    /// the `=` line; it is not here because no lambda can be a last argument
    /// without parentheses until trailing lambdas parse (§12.3), and a
    /// parenthesised one is a `paren`, which breaks as before.
    fn hangs(p: *const Printer, a: Ast.full.Apply) bool {
        const last_arg = a.args[a.args.len - 1];
        switch (p.tree.nodeTag(last_arg)) {
            .list, .record, .record_update, .markup_element, .markup_fragment, .markup_for, .markup_show => {},
            else => return false,
        }
        var width = p.widths[a.function.int()];
        for (a.args[0 .. a.args.len - 1]) |arg| {
            if (commentsBefore(p.comments, p.first(arg)).len != 0) return false;
            width +|= 1 +| p.widths[arg.int()];
        }
        return width != no_fit and p.curCol() +| width <= max_width;
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
            .negate, .spread => {
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
                if (!one_line and p.hangs(a)) {
                    // `f a b` / `[ … ]` (language.md §12.5): the head on one
                    // line, the last argument below it in its own form.
                    try p.expr(a.function, indent);
                    for (a.args[0 .. a.args.len - 1]) |arg| {
                        try p.space();
                        try p.expr(arg, indent);
                    }
                    p.newline(indent + indent_step);
                    return p.expr(a.args[a.args.len - 1], indent + indent_step);
                }
                try p.expr(a.function, indent);
                try p.args(p.last(a.function), a.args, .expr, one_line, indent);
            },
            .lambda => {
                const l = tree.fullLambda(n);
                const one_line = p.fits(n);
                try p.tok(l.head);
                var arrow = l.head + 1;
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
            .markup_element, .markup_fragment, .markup_for, .markup_show => try p.markup(n),
            else => return error.SyntaxErrors, // fields, chunks and interps are printed by their parents
        }
    }

    // ---- Markup (language.md §11.15) ---------------------------------------
    //
    // The governing rule is that formatting never changes what a page says.
    // So the whitespace between two children keeps what it was: none, a
    // space on the line (which the page shows), or a line break (which it
    // does not); only the indentation after a break and the number of blank
    // lines change. The edges, between the opening tag and the first child
    // and between the last child and the closing tag, may gain a line break
    // where they had nothing, which the page does not show either.

    fn markup(p: *Printer, n: Index) Error!void {
        return p.markupAt(n, p.curCol());
    }

    /// An element, fragment or form whose broken parts — attributes one per
    /// line, children, the closing tag — hang off column `col`: its own
    /// column, or, for a child that follows a sibling on its line, the
    /// column of the children's lines, so a run of such siblings does not
    /// drift right.
    fn markupAt(p: *Printer, n: Index, col: u32) Error!void {
        const tree = p.tree;
        const mk = tree.fullMarkup(n);
        // An element the author wrote on one line stays there when it
        // follows something on its line — a sibling it may not be parted
        // from, `\x ->`, an attribute's `=` — whatever its width; breaking
        // it there would only move its own edges. It is printed flat, every
        // hole and child in it on the line too: a break anywhere inside
        // would make it an element the author broke the next time round.
        const at = p.curCol();
        const fit = p.fitsAt(n, at);
        const one_line = fit or (p.widths[n.int()] != no_fit and p.pending == 0 and p.col > p.line_indent);
        const saved_flat = p.flat;
        defer p.flat = saved_flat;
        if (one_line and !fit) p.flat = true;
        try p.tok(mk.open);
        if (mk.name) |t| try p.tok(t);
        const open_end = mk.open_end orelse return error.SyntaxErrors;
        // With no attributes there is nothing to put on lines of its own.
        const attrs_one_line = one_line or p.openTagFits(mk, at) or
            (mk.attrs.len == 0 and !p.commentInTag(mk));
        for (mk.attrs) |a| {
            if (attrs_one_line) try p.space() else p.newline(col + indent_step);
            try p.markupAttr(a, if (attrs_one_line) col else col + indent_step);
        }
        if (!attrs_one_line) {
            try p.leading(open_end, col + indent_step);
            p.newline(col);
        }
        // `<div />`, and `<div></div>` written so (§11.15).
        if (mk.children.len == 0 and mk.name != null) {
            if (attrs_one_line) try p.space();
            try p.leading(open_end, null);
            try p.raw("/>");
            const last_tok = if (mk.close) |c| c + 2 else open_end;
            try p.trailing(last_tok);
            return;
        }
        try p.tok(open_end);
        const close = mk.close orelse return error.SyntaxErrors;
        if (one_line) {
            for (mk.children) |c| try p.markupChild(c, col);
        } else {
            const inner = col + indent_step;
            for (mk.children, 0..) |c, k| {
                if (tree.nodeTag(c) == .markup_text) {
                    try p.markupText(tree.nodeMainToken(c), k == 0, inner);
                } else {
                    if (k == 0) p.newline(inner);
                    try p.markupChild(c, inner);
                }
            }
            // The trailing edge: a space the page shows stays on the line;
            // anything else ends it.
            const last_child = mk.children[mk.children.len - 1];
            if (tree.nodeTag(last_child) != .markup_text or !p.endsWithSpaceOnLine(tree.nodeMainToken(last_child))) p.newline(col);
        }
        try p.tok(close);
        if (mk.name != null) try p.tok(close + 1);
        try p.tok(if (mk.name != null) close + 2 else close + 1);
    }

    /// Whether the opening tag of `mk`, started at `col`, goes on one line:
    /// it fits, the author broke no line inside it, and no comment is in it.
    fn openTagFits(p: *const Printer, mk: Ast.full.Markup, col: u32) bool {
        const open_end = mk.open_end.?;
        var width: u32 = 1 + (if (mk.name) |t| @as(u32, @intCast(p.text(t).len)) else 0);
        var prev: TokenIndex = mk.name orelse mk.open;
        for (mk.attrs) |a| {
            const w = p.widths[a.int()];
            if (w == no_fit or p.tok_lines[p.first(a)] != p.tok_lines[prev]) return false;
            width +|= 1 +| w;
            prev = p.last(a);
        }
        if (p.tok_lines[open_end] != p.tok_lines[prev]) return false;
        if (p.commentInTag(mk)) return false;
        width +|= if (mk.children.len == 0 and mk.name != null) 3 else 1;
        return col +| width <= max_width;
    }

    /// Whether a comment sits inside the opening tag of `mk`.
    fn commentInTag(p: *const Printer, mk: Ast.full.Markup) bool {
        const i = firstCommentFrom(p.comments, mk.open + 1);
        return i < p.comments.len and p.comments[i].before_token <= mk.open_end.?;
    }

    /// A text run that ends in whitespace on its last line — a space the
    /// page shows before the closing tag.
    fn endsWithSpaceOnLine(p: *const Printer, t: TokenIndex) bool {
        const seg = p.text(t);
        const line_start = if (std.mem.lastIndexOfScalar(u8, seg, '\n')) |nl| nl + 1 else 0;
        const line = seg[line_start..];
        if (line_start != 0 and isBlank(line)) return false; // a break, not a space
        return line.len > 0 and trimMarkupEnd(line).len < line.len;
    }

    /// A child printed where the cursor is: an element, a hole, or a text
    /// run with no line break in it.
    fn markupChild(p: *Printer, n: Index, indent: u32) Error!void {
        switch (p.tree.nodeTag(n)) {
            .markup_text => try p.tok(p.tree.nodeMainToken(n)),
            .markup_hole, .markup_empty_hole => try p.markupHole(n, indent),
            else => try p.markupAt(n, indent),
        }
    }

    /// A text run in a vertical element (§11.15): its first line where the
    /// cursor is (after a line break when it is the first child and begins
    /// with a character, which the page does not show), each later line at
    /// `inner` without its indentation, at most one blank line kept. A line's
    /// trailing whitespace is dropped where a later line of the run shows —
    /// the page joins the two with one space either way — and kept on the
    /// run's last line of text, where the page shows it as a space.
    fn markupText(p: *Printer, t: TokenIndex, first_child: bool, inner: u32) Error!void {
        const seg = p.text(t);
        if (std.mem.indexOfScalar(u8, seg, '\n') == null) {
            if (first_child and seg.len > 0 and markup_text.whitespaceAt(seg, 0) == 0) p.newline(inner);
            return p.raw(seg);
        }
        var last_shown: usize = 0;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, seg, '\n');
        while (it.next()) |line| : (count += 1) {
            if (!isBlank(line)) last_shown = count;
        }
        var blanks: u32 = 0;
        var i: usize = 0;
        it = std.mem.splitScalar(u8, seg, '\n');
        while (it.next()) |line_crlf| : (i += 1) {
            const last_line = i + 1 == count;
            // A `\r` stands only before a `\n` (the lexer refuses a bare
            // one), and it goes with the line break, which is printed as a
            // `\n`: the run reads as its LF twin, as lowering reads it.
            const line_raw = if (!last_line and std.mem.endsWith(u8, line_crlf, "\r")) line_crlf[0 .. line_crlf.len - 1] else line_crlf;
            const line = if (i == 0) line_raw else line_raw[markupWhitespaceEnd(line_raw, 0)..];
            if (isBlank(line)) {
                if (i != 0) blanks += 1;
                if (last_line) p.blankLines(@min(blanks -| 1, 1), inner);
                continue;
            }
            if (i == 0) {
                if (first_child and markup_text.whitespaceAt(line, 0) == 0) p.newline(inner);
            } else {
                p.blankLines(@min(blanks, 1), inner);
            }
            blanks = 0;
            try p.raw(if (!last_line and i < last_shown) trimMarkupEnd(line) else line);
        }
    }

    /// `{e}`, `{}` or `{...e}`: on one line when it fits; otherwise the
    /// expression continues 4 right of the `{` and the `}` closes on a line
    /// of its own under the `{`, as does a hole that holds only a comment.
    fn markupHole(p: *Printer, n: Index, indent: u32) Error!void {
        const open = p.tree.nodeMainToken(n);
        const col = p.curCol();
        const one_line = p.fits(n) or p.unbreakable(n);
        try p.tok(open);
        if (p.tree.nodeTag(n) == .markup_empty_hole) {
            if (!one_line) {
                try p.leading(open + 1, col + indent_step);
                p.newline(col);
            }
            return p.tok(open + 1);
        }
        if (p.tree.nodeTag(n) == .markup_spread and p.tags[open + 1] == .ellipsis) try p.tok(open + 1);
        const e = p.tree.operand(n);
        try p.expr(e, if (one_line) indent else col);
        if (!one_line) p.newline(col);
        try p.tok(p.last(e) + 1);
    }

    /// One attribute: `name`, `name="…"`, `name={e}`, `"name"=…` or
    /// `{...e}`. A string is printed as written, as every literal is.
    fn markupAttr(p: *Printer, n: Index, indent: u32) Error!void {
        const tree = p.tree;
        switch (tree.nodeTag(n)) {
            .markup_attr => {
                const a = tree.fullMarkupAttr(n);
                try p.tok(a.name);
                const value = a.value orelse return;
                try p.tok(a.name + 1); // `=`
                try p.attrValue(value, a.brace, indent);
            },
            .markup_attr_escape => {
                const a = tree.fullMarkupAttr(n);
                const name = a.name_string.?;
                try p.expr(name, indent);
                // A tree with syntax errors is never printed, so an escape
                // here has its `=` and its value.
                const value = a.value orelse return error.SyntaxErrors;
                try p.tok(p.last(name) + 1); // `=`
                try p.attrValue(value, a.brace, indent);
            },
            .markup_spread => try p.markupHole(n, indent),
            else => return error.SyntaxErrors,
        }
    }

    fn attrValue(p: *Printer, value: Index, brace: ?TokenIndex, indent: u32) Error!void {
        const open = brace orelse return p.expr(value, indent);
        const col = p.curCol();
        const one_line = commentsBefore(p.comments, p.last(value) + 1).len == 0 and
            (p.fitsAt(value, col + 1) or p.unbreakable(value));
        try p.tok(open);
        try p.expr(value, if (one_line) indent else col);
        if (!one_line) p.newline(col);
        try p.tok(p.last(value) + 1);
    }

    /// A vocabulary declaration (language.md §11.14): one line, its facts
    /// in source order, then the type as an annotation's.
    fn vocab(p: *Printer, n: Index) Error!void {
        const v = p.tree.fullVocab(n);
        try p.header(v.header);
        try p.tok(v.word);
        try p.space();
        if (v.name_string) |s| try p.expr(s, 0) else try p.tok(v.name);
        var t = v.facts_start;
        while (t < v.facts_end) {
            try p.space();
            if (p.tags[t] == .str_start) {
                var end = t;
                while (p.tags[end] != .str_end and p.tags[end] != .eof) end += 1;
                try p.tokRange(t, end);
                t = end + 1;
            } else {
                try p.tok(t);
                t += 1;
            }
        }
        const te = v.type_expr orelse return;
        try p.space();
        try p.tok(v.facts_end); // `:`
        try p.annotated(te, 0);
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
        try p.tok(l.head);
        var arrow = l.head + 1;
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
        // Written on one line, with one-line parts, and it fits
        // (language.md §12.5): it stays there, an `else if` tail with it.
        // The tail of a chain printed vertically is vertical too.
        if (keyword_col == null and p.widths[n.int()] != no_fit and p.fits(n)) {
            try p.tok(i.if_token);
            try p.space();
            try p.expr(i.cond, indent);
            try p.space();
            try p.tok(then_tok);
            try p.space();
            try p.expr(i.then_expr, indent);
            try p.space();
            try p.tok(else_tok);
            try p.space();
            return p.expr(i.else_expr, indent);
        }
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
                try p.rhs(l.value, indent);
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
            .type_sync => {
                try p.tok(main);
                try p.space();
                try p.node(tree.operand(n), .type, indent);
            },
            .type_tuple => try p.collection(n, tree.children(n), .type, indent),
            .type_record => try p.collection(n, tree.children(n), .type_field, indent),
            .type_record_ext => {
                const r = tree.fullTypeRecordExt(n);
                try p.extension(n, r.base, r.fields, .type_field);
            },
            else => return error.SyntaxErrors,
        }
    }

    /// `A, B -> C` on one line, or — when it does not fit, or the author
    /// broke it — the parameters one per line with the comma leading each
    /// continuation as a list does, and every `->` leading a line, all at
    /// the column the type started on (§9, function types).
    ///
    /// The chain follows the right spine (an arrow associates right in its
    /// RESULT) without recursing along it, so `a, b -> c -> d` is one
    /// vertical run and not a nested indent.
    fn arrows(p: *Printer, top: Index, indent: u32, force_vertical: bool) Error!void {
        const one_line = !force_vertical and p.fits(top);
        const col = p.curCol();
        const inner = if (one_line) indent else col;
        // A broken type that starts a line indents its first parameter 2
        // more, into the column of every parameter after a leading `, `
        // (language.md §12.5, *aligned parameters*).
        if (!one_line and p.pending > 0) p.next_indent = col + 2;
        var node_i = top;
        while (true) {
            const f = p.tree.fullTypeFn(node_i);
            for (f.params, 0..) |param, i| {
                if (i != 0) {
                    if (!one_line) p.newline(col);
                    try p.tok(p.last(f.params[i - 1]) + 1); // `,`
                    try p.space();
                }
                try p.typ(param, inner);
            }
            if (one_line) try p.space() else p.newline(col);
            try p.tok(f.arrow);
            try p.space();
            if (p.tree.nodeTag(f.result) != .type_fn) {
                try p.typ(f.result, inner);
                return;
            }
            node_i = f.result;
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

    /// A declaration record type in its canonical delimiter-free layout
    /// spelling. Nested nonempty closed records are field blocks too; empty
    /// and extensible records continue through `typ` and retain braces.
    fn typeFieldBlock(p: *Printer, n: Index, indent: u32) Error!void {
        const fields = p.tree.children(n);
        std.debug.assert(fields.len != 0);
        const open = p.tree.nodeMainToken(n);
        const braced = p.tags[open] == .l_brace;
        for (fields, 0..) |field_node, i| {
            if (i != 0) p.newline(indent);
            if (braced) {
                const delimiter = if (i == 0) open else p.last(fields[i - 1]) + 1;
                try p.dropLayoutDelimiter(delimiter, p.first(field_node), indent);
            }
            try p.layoutTypeField(field_node, indent);
        }
        if (braced) try p.skipTok(p.last(fields[fields.len - 1]) + 1);
    }

    fn layoutTypeField(p: *Printer, n: Index, indent: u32) Error!void {
        const main = p.tree.nodeMainToken(n);
        const field_type = p.tree.operand(n);
        try p.tok(main);
        try p.space();
        try p.tok(main + 1); // `:`
        if (p.tree.nodeTag(field_type) == .type_record and p.tree.children(field_type).len != 0) {
            p.newline(indent + indent_step);
            try p.typeFieldBlock(field_type, indent + indent_step);
        } else if (p.fitsAt(field_type, p.curCol() + 1)) {
            try p.space();
            try p.typ(field_type, indent);
        } else {
            p.newline(indent + indent_step);
            try p.typ(field_type, indent + indent_step);
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
            .pat_spread => {
                try p.tok(main);
                try p.pat(tree.operand(n), indent);
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
const small_stack = @import("../small_stack.zig");
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
    // A text run's bytes move under formatting while what it says does
    // not (language.md §11.15); the black-box `fmt/` corpus compares what
    // it says, through the lowered file.
    const before = try withoutMarkupText(arena, first.dump);
    const after = try withoutMarkupText(arena, again.dump);
    if (exact_dump) {
        try testing.expectEqualStrings(before, after);
    } else {
        try testing.expectEqualStrings(try sortedLines(arena, before), try sortedLines(arena, after));
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

/// An AST dump with every `(markup_text "…")` child cut out, with the line
/// break and indentation before it.
fn withoutMarkupText(arena: Allocator, dump: []const u8) ![]const u8 {
    const marker = "(markup_text \"";
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, dump, pos, marker)) |at| {
        var cut = at;
        while (cut > pos and dump[cut - 1] == ' ') cut -= 1;
        if (cut > pos and dump[cut - 1] == '\n') cut -= 1;
        try out.appendSlice(arena, dump[pos..cut]);
        var i = at + marker.len;
        while (i < dump.len and dump[i] != '"') : (i += 1) {
            if (dump[i] == '\\') i += 1;
        }
        pos = @min(i + 2, dump.len);
    }
    try out.appendSlice(arena, dump[pos..]);
    return out.items;
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
    try check("x = 1", "x = 1\n");
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
        \\x = 1
        \\
        \\
        \\y = 2
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
        \\x = 1
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
        \\f x = x
        \\
        \\
        \\g : Int
        \\g = 2
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
        \\pub   foreign   pure   add : number ->
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
        \\    x : Float
        \\    y : Float
        \\
        \\
        \\pub type alias Handler model msg =
        \\    msg -> model -> ( model, List msg )
        \\
        \\
        \\--| Add.
        \\pub foreign pure add :
        \\      number
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
        \\        count = List.length xs
        \\        ( low, high ) = ( 1, 2 )
        \\
        \\        spread =
        \\            let
        \\                factor = 2
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

test "an if written across lines is vertical; else-if chains continue on the else line; a mid-line if hangs off its keyword" {
    try check(
        \\tiny b = if b
        \\  then 1
        \\    else 0
        \\grade s = if s >= 90 then "A"
        \\  else if s >= 80 then "B" else "F"
        \\nested a b = if a then if b then 2
        \\  else 1 else 0
        \\inList flag = [ if flag then 1
        \\  else 0, let one = 1 in one, case flag of
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
        \\        one = 1
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

test "an if written on one line stays there when it fits; a chain's tail follows the chain; one that does not fit breaks" {
    try check(
        \\pick t id = if t.id == id then { t | done = not t.done } else t
        \\chain s = if s > 1 then "A" else if s > 0 then "B" else "C"
        \\tail s = if s > 1 then "A"
        \\    else if s > 0 then "B" else "C"
        \\arg flag = max (if flag then 1 else 2) 3
        \\exact = if aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa then bbbbbbbbbbbbbbbbbbbbbbbbbbb else ccccccccccccccccc
        \\over = if aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa then bbbbbbbbbbbbbbbbbbbbbbbbbbb else ccccccccccccccccc
        \\
    ,
        \\pick t id = if t.id == id then { t | done = not t.done } else t
        \\
        \\
        \\chain s = if s > 1 then "A" else if s > 0 then "B" else "C"
        \\
        \\
        \\tail s =
        \\    if s > 1 then
        \\        "A"
        \\    else if s > 0 then
        \\        "B"
        \\    else
        \\        "C"
        \\
        \\
        \\arg flag = max (if flag then 1 else 2) 3
        \\
        \\
        \\exact =
        \\    if aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa then bbbbbbbbbbbbbbbbbbbbbbbbbbb else ccccccccccccccccc
        \\
        \\
        \\over =
        \\    if aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa then
        \\        bbbbbbbbbbbbbbbbbbbbbbbbbbb
        \\    else
        \\        ccccccccccccccccc
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
        \\xs = [ 1, 2, 3 ]
        \\
        \\
        \\r = { a = 1, b = 2 }
        \\
        \\
        \\p = ( 1, ( 2, 3 ) )
        \\
        \\
        \\e = ( [], {}, () )
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
        \\view model = { title = "Board", body = [ model.items |> List.filter (λi -> i.done) |> List.map (λi -> viewItem model i) |> List.reverse, footer model ] }
        \\
    ,
        \\view model =
        \\    { title = "Board"
        \\    , body =
        \\        [ model.items
        \\            |> List.filter (λi -> i.done)
        \\            |> List.map (λi -> viewItem model i)
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
        \\    List.map (λx -> x * 2) |>
        \\    List.sum
        \\negated x y = -x - -y
        \\
    ,
        \\area w h = w * h
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
        \\        |> List.map (λx -> x * 2)
        \\        |> List.sum
        \\
        \\
        \\negated x y = -x - -y
        \\
    );
}

test "a chain of two operands ending in a block keeps the operator at the end of the first line" {
    try check(
        \\f = text <| if a then b
        \\    else c
        \\g = decode <|
        \\      λx -> x + 1
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
        \\    decode <| λx ->
        \\    x + 1
        \\
        \\
        \\h =
        \\    foo <|
        \\        let
        \\            a = 1
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
        \\    conn   <-   Task.bracket (λ() -> Db.open r.url) Db.close
        \\    a = 1
        \\    h <- Result.andThen (readHeader r)
        \\  in
        \\  render scope conn a h
        \\
    ,
        \\partial xs = List.map (add 1 _) xs
        \\
        \\
        \\pipeline r =
        \\    let
        \\        scope <- Task.scope
        \\        conn <- Task.bracket (λ() -> Db.open r.url) Db.close
        \\        a = 1
        \\        h <- Result.andThen (readHeader r)
        \\    in
        \\    render scope conn a h
        \\
    );
}

test "a trailing `<|` lambda keeps its body at the indentation of the `<|` line (§9)" {
    try check(
        \\chain url = Task.attempt (Http.get url) <| λresponse -> Task.attempt (Json.decode response) <| λvalue -> renderTheDecodedValue value withSomeContext andAnotherArgument
        \\
    ,
        \\chain url =
        \\    Task.attempt (Http.get url) <| λresponse ->
        \\    Task.attempt (Json.decode response) <| λvalue ->
        \\    renderTheDecodedValue value withSomeContext andAnotherArgument
        \\
    );
}

test "lambdas: `λx y ->` with the body inline when it fits, else on the next line indented 4" {
    try check(
        \\f=λx->x+1
        \\h = λ(a,b) {c} _->
        \\  a+b+c
        \\describe = λx -> case x of
        \\  0 -> "zero"
        \\  _ -> "other"
        \\
    ,
        \\f = λx -> x + 1
        \\
        \\
        \\h = λ( a, b ) { c } _ -> a + b + c
        \\
        \\
        \\describe =
        \\    λx ->
        \\        case x of
        \\            0 ->
        \\                "zero"
        \\            _ ->
        \\                "other"
        \\
    );
}

test "application: one line when it fits and was written so; a last list, record or update hangs below the head; otherwise head-line arguments stay, the rest go one per line" {
    try check(
        \\short =
        \\  max
        \\      1
        \\   2
        \\long = List.foldl (λitem acc -> acc + String.length item) 0 [ "a very long string literal", "another very long string literal", "and one more" ]
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
        \\    List.foldl (λitem acc -> acc + String.length item) 0
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

test "a comment between head arguments keeps an application from hanging; one before the hung argument does not" {
    try check(
        \\commented = Html.ul [ class "list" ] -- the attributes
        \\    [ viewItem "first", viewItem "second", viewItem "third", viewItem "fourth", viewItem "x" ]
        \\between = Html.ul -- the callee
        \\    [ class "list" ] [ viewItem "first", viewItem "second", viewItem "third", viewItem "fourth", viewItem "x" ]
        \\
    ,
        \\commented =
        \\    Html.ul [ class "list" ] -- the attributes
        \\        [ viewItem "first", viewItem "second", viewItem "third", viewItem "fourth", viewItem "x" ]
        \\
        \\
        \\between =
        \\    Html.ul -- the callee
        \\        [ class "list" ]
        \\        [ viewItem "first", viewItem "second", viewItem "third", viewItem "fourth", viewItem "x" ]
        \\
    );
}

test "the blank line after a standalone comment survives a dropped record brace and comma" {
    try check(
        \\type alias Config = {
        \\    -- the host
        \\
        \\    host : String
        \\    , -- the port
        \\
        \\    port : Int }
        \\
    ,
        \\type alias Config =
        \\    -- the host
        \\
        \\    host : String
        \\    -- the port
        \\
        \\    port : Int
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
        \\run k = (λk2 ->
        \\   case k2 of
        \\     0 -> 1
        \\     _ -> k2) k
        \\
    ,
        \\a x = (x)
        \\
        \\
        \\b x y = -(x + y)
        \\
        \\
        \\d x = (x + 1) * 2
        \\
        \\
        \\e2 fn x = fn (-x)
        \\
        \\
        \\g x = [ (x) ]
        \\
        \\
        \\run k =
        \\    (λk2 ->
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
        \\append = (++)
        \\
    ,
        \\f r t = Ok (r.a.b + t.0.1 + List.length (List.map .name []))
        \\
        \\
        \\g s = Ok (parse s? + parse s?.field?)
        \\
        \\
        \\plus = (+)
        \\
        \\
        \\append = (++)
        \\
    );
}

/// `migrateCons` over `source`, which may hold `::` and nothing else wrong.
fn expectMigrated(source: [:0]const u8, expected: []const u8, expected_skipped: u32) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var interner: InternPool.Local = .empty;
    var out: Tokenizer.Output = .empty;
    try Tokenizer.tokenize(arena, source, &interner, &out);
    const tree = try Parse.parse(arena, arena, source, out.tokens.slice(), out.comments.items, out.line_starts.items, out.diagnostics.items());
    var text: Io.Writer.Allocating = .init(arena);
    var skipped: u32 = 0;
    try migrateCons(arena, &tree, &out.tokens, out.comments.items, source, &text.writer, &skipped);
    try testing.expectEqualStrings(expected, text.written());
    try testing.expectEqual(expected_skipped, skipped);
}

test "migrating `::` writes each chain in brackets and touches nothing else" {
    // Layout, spacing and the other operators are the author's: this is an
    // edit, not a formatting (language.md §6.8).
    try expectMigrated(
        \\f x xs = x::xs
        \\g a b rest = (a :: b :: rest) ++ [ 0 ]
        \\h x y =  x :: [ y ]  -- one literal
        \\k x = case x of
        \\  a :: (b :: _) -> [ a, b ]
        \\  y :: [] -> [ y ]
        \\  _ -> List.foldr x [] (::)
        \\m xs = case xs of
        \\  x :: (rest as r) -> r
        \\  _ -> xs
        \\
    ,
        \\f x xs = [ x, ...xs ]
        \\g a b rest = [ a, b, ...rest ] ++ [ 0 ]
        \\h x y =  [ x, y ]  -- one literal
        \\k x = case x of
        \\  [ a, b, ..._ ] -> [ a, b ]
        \\  [ y ] -> [ y ]
        \\  _ -> List.foldr x [] List.cons
        \\m xs = case xs of
        \\  x :: (rest as r) -> r
        \\  _ -> xs
        \\
    , 1);
}

/// `migrateLetBlanks` over `source`, then again over its own output, which
/// must not move (one run reaches the fixed point).
fn expectLetBlanks(source: [:0]const u8, expected: [:0]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings(expected, try letBlanksOnce(a, source));
    try testing.expectEqualStrings(expected, try letBlanksOnce(a, expected));
}

fn letBlanksOnce(a: Allocator, source: [:0]const u8) ![]const u8 {
    var interner: InternPool.Local = .empty;
    var out: Tokenizer.Output = .empty;
    try Tokenizer.tokenize(a, source, &interner, &out);
    const tree = try Parse.parse(a, a, source, out.tokens.slice(), out.comments.items, out.line_starts.items, out.diagnostics.items());
    var text: Io.Writer.Allocating = .init(a);
    try migrateLetBlanks(a, &tree, &out.tokens, out.comments.items, source, &text.writer);
    return text.written();
}

test "migrating let blanks joins one-line bindings and touches nothing else" {
    // Odd spacing, the one blank line between top-level declarations and
    // a trailing comment on a binding's line are the author's.
    try expectLetBlanks(
        \\f x =
        \\    let
        \\        a  =  1
        \\
        \\        b = 2 -- two
        \\
        \\
        \\        ( c, d ) = ( a, b )
        \\
        \\        e : Int
        \\
        \\        e = c
        \\
        \\        y <- Task.andThen x
        \\    in
        \\    a + b
        \\
        \\g = 1
        \\
    ,
        \\f x =
        \\    let
        \\        a  =  1
        \\        b = 2 -- two
        \\        ( c, d ) = ( a, b )
        \\        e : Int
        \\        e = c
        \\        y <- Task.andThen x
        \\    in
        \\    a + b
        \\
        \\g = 1
        \\
    );
}

test "migrating let blanks keeps a blank line next to a multi-line binding" {
    try expectLetBlanks(
        \\f =
        \\    let
        \\        a = 1
        \\
        \\        b =
        \\            2
        \\
        \\        c = 3
        \\
        \\        d = 4
        \\
        \\        s =
        \\            \\one
        \\            \\two
        \\
        \\        t = 5
        \\    in
        \\    a
        \\
    ,
        \\f =
        \\    let
        \\        a = 1
        \\
        \\        b =
        \\            2
        \\
        \\        c = 3
        \\        d = 4
        \\
        \\        s =
        \\            \\one
        \\            \\two
        \\
        \\        t = 5
        \\    in
        \\    a
        \\
    );
}

test "migrating let blanks keeps a gap that holds a comment line" {
    const source =
        \\f =
        \\    let
        \\        a = 1
        \\
        \\        -- why b
        \\        b = 2
        \\        -- why c
        \\
        \\        c = 3
        \\        -- why d
        \\        d = 4
        \\    in
        \\    a
        \\
    ;
    try expectLetBlanks(source, source);
}

test "migrating let blanks reaches nested lets" {
    try expectLetBlanks(
        \\f =
        \\    let
        \\        a = 1
        \\
        \\        b =
        \\            let
        \\                c = 2
        \\
        \\                d = 3
        \\            in
        \\            c
        \\    in
        \\    let
        \\        e = 1
        \\
        \\        g = 2
        \\    in
        \\    e
        \\
    ,
        \\f =
        \\    let
        \\        a = 1
        \\
        \\        b =
        \\            let
        \\                c = 2
        \\                d = 3
        \\            in
        \\            c
        \\    in
        \\    let
        \\        e = 1
        \\        g = 2
        \\    in
        \\    e
        \\
    );
}

test "migrating let blanks keeps CRLF line ends" {
    try expectLetBlanks(
        "f =\r\n    let\r\n        a = 1\r\n\r\n        b = 2\r\n    in\r\n    a\r\n",
        "f =\r\n    let\r\n        a = 1\r\n        b = 2\r\n    in\r\n    a\r\n",
    );
}

test "migrating let blanks leaves a file with a syntax error alone" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const source = "f =\n    let\n        a = 1\n\n        b =\n    in\n    a\n";
    var interner: InternPool.Local = .empty;
    var out: Tokenizer.Output = .empty;
    try Tokenizer.tokenize(a, source, &interner, &out);
    const tree = try Parse.parse(a, a, source, out.tokens.slice(), out.comments.items, out.line_starts.items, out.diagnostics.items());
    var text: Io.Writer.Allocating = .init(a);
    try testing.expectError(error.SyntaxErrors, migrateLetBlanks(a, &tree, &out.tokens, out.comments.items, source, &text.writer));
}

/// `migrateLambda` over `source`: its output and the problem it reports.
fn lambdaOnce(a: Allocator, source: [:0]const u8) !struct { text: []const u8, problem: ?LambdaProblem } {
    var interner: InternPool.Local = .empty;
    var out: Tokenizer.Output = .empty;
    try Tokenizer.tokenize(a, source, &interner, &out);
    const tree = try Parse.parse(a, a, source, out.tokens.slice(), out.comments.items, out.line_starts.items, out.diagnostics.items());
    var text: Io.Writer.Allocating = .init(a);
    const problem = try migrateLambda(a, &tree, &out.tokens, source, &text.writer);
    return .{ .text = text.written(), .problem = problem };
}

/// `migrateLambda` over `source` gives `expected`, which it then leaves
/// alone (one run reaches the fixed point).
fn expectLambdaMigrated(source: [:0]const u8, expected: [:0]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const first = try lambdaOnce(a, source);
    try testing.expectEqual(@as(?LambdaProblem, null), first.problem);
    try testing.expectEqualStrings(expected, first.text);
    const again = try lambdaOnce(a, expected);
    try testing.expectEqual(@as(?LambdaProblem, null), again.problem);
    try testing.expectEqualStrings(expected, again.text);
}

test "migrating lambdas writes each head `λ` and touches nothing else" {
    // An edit, not a formatting (frontend.md §11.4): the spacing, the
    // layout and a `λ` already written are the author's.
    try expectLambdaMigrated(
        \\f=\x->x+1
        \\g = List.map [ 1 ] (\ a ->
        \\      a*2)  -- \x
        \\h = λa -> \b -> \() -> a + b
        \\
    ,
        \\f=λx->x+1
        \\g = List.map [ 1 ] (λ a ->
        \\      a*2)  -- \x
        \\h = λa -> λb -> λ() -> a + b
        \\
    );
}

test "migrating lambdas never touches a multiline string's `\\\\`, an escape or a character" {
    // The hazards §12.1 names: a `\\` line is a `multiline_line` and a
    // backslash in a string or a character literal is an escape, never the
    // token a lambda begins with — even when the text after it reads like
    // one.
    try expectLambdaMigrated(
        \\a = \x ->
        \\    \\raw \x -> x
        \\    \\\y
        \\b = "\\x -> \n" ++ "${ f (\y -> y) }"
        \\c = '\\'
        \\d = [ '\'', '\n' ]
        \\
    ,
        \\a = λx ->
        \\    \\raw \x -> x
        \\    \\\y
        \\b = "\\x -> \n" ++ "${ f (λy -> y) }"
        \\c = '\\'
        \\d = [ '\'', '\n' ]
        \\
    );
}

test "migrating lambdas reaches markup holes and attribute values" {
    try expectLambdaMigrated(
        \\v xs = <ul>{List.map xs (\i -> <li onClick={\_ -> i}>{i}</li>)}</ul>
        \\
    ,
        \\v xs = <ul>{List.map xs (λi -> <li onClick={λ_ -> i}>{i}</li>)}</ul>
        \\
    );
}

test "migrating lambdas leaves a file alone when the rewrite moves a `case` branch off its column" {
    // language.md §12.1, *columns*: `λ` is a byte wider than `\`, so a first
    // branch on the `of` line after a lambda moves right of the branches
    // aligned under it. The re-parse catches it, the file is written as it
    // was, and the problem points at the misaligned branch's line.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const source =
        \\f m =
        \\    case g (\x -> x) of Just y -> y
        \\                        Nothing -> 0
        \\
    ;
    const result = try lambdaOnce(a, source);
    try testing.expectEqualStrings(source, result.text);
    const problem = result.problem orelse return error.TestExpectedProblem;
    try testing.expectEqual(diagnostic.Code.unexpected_token, problem.code);
    try testing.expectEqual(std.mem.indexOf(u8, source, "Nothing").?, problem.start);
}

test "migrating lambdas leaves a file with a syntax error alone" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.SyntaxErrors, lambdaOnce(arena_state.allocator(), "f = \\x ->\n"));
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
        "    , 2 ]\n", "a = \"tab\\there \\u{0041} \\$ \\' \\\"q\\\"\"\n" ++
        "\n\n" ++
        "b = '\\u{00041}'\n" ++
        "\n\n" ++
        "c = 0xDeadBEEF\n" ++
        "\n\n" ++
        "d = 1.50e+03\n" ++
        "\n\n" ++
        "e2 = \"${ a }${b} and ${ f (g x) }\"\n" ++
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
        \\  [(a,b),...rest] -> a
        \\  [x,y] -> x
        \\  [({c} as r) , ... _] -> c
        \\  [...init,Just(Just(z))] -> z
        \\  Maybe.Just 'c' -> 1
        \\  ( -1 ) -> 2
        \\  "s" -> 3
        \\  () -> 4
        \\  _ -> 0
        \\g p = let (a,b)=p in a
        \\h = λ(a,b)->a
        \\k (Just x) { a } ( b, c ) = -x
        \\
    ,
        \\f v =
        \\    case v of
        \\        [ ( a, b ), ...rest ] ->
        \\            a
        \\        [ x, y ] ->
        \\            x
        \\        [ ({ c } as r), ..._ ] ->
        \\            c
        \\        [ ...init, Just (Just (z)) ] ->
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
        \\        ( a, b ) = p
        \\    in
        \\    a
        \\
        \\
        \\h = λ( a, b ) -> a
        \\
        \\
        \\k (Just x) { a } ( b, c ) = -x
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
        \\h fn xs = List.map fn xs
        \\
        \\
        \\ext : { r | x : Int, y : Int } -> () -> ( a, Maybe.Maybe b ) -> {}
        \\ext _ _ _ = {}
        \\
        \\
        \\pub update :
        \\      Msg
        \\    -> { host : String, port : Int, retries : Int, onError : String -> Msg }
        \\    -> ( Model, List String )
        \\update msg config = ( config, [] )
        \\
        \\
        \\type alias Config =
        \\    host : String
        \\    port : Int
        \\    user : String
        \\    password : String
        \\    timeout : Int
        \\    verbose : Bool
        \\    more : Int
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
        \\        y = 1 -- after body
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
        \\x = 1
        \\
        \\
        \\--|   spaced doc
        \\y = 2
        \\
        \\
        \\--comment without a space
        \\--- dashes
        \\z = 3
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
        \\x = 1
        \\
    );
}

// ---- Whitespace ----------------------------------------------------------------

test "CRLF, trailing whitespace, missing trailing newline and extra blank lines are normalised" {
    try check("x =   \r\n    1  \r\n\r\n\r\ny = 2", "x = 1\n\n\ny = 2\n");
}

test "the 100-column boundary: a line of exactly 100 fits, 101 does not" {
    // `xs = [ ` + 91 + ` ]` = 100 columns: the body stays on the `=` line.
    const item_91 = "\"" ++ "a" ** 89 ++ "\"";
    try check("xs =\n    [ " ++ item_91 ++ " ]\n", "xs = [ " ++ item_91 ++ " ]\n");
    // One more is 101 there, so the body goes below, where
    // `    [ ` + 92 + ` ]` = 100 columns still fits on one line.
    const item_92 = "\"" ++ "a" ** 90 ++ "\"";
    try check("xs = [ " ++ item_92 ++ " ]\n", "xs =\n    [ " ++ item_92 ++ " ]\n");
    const item_93 = "\"" ++ "a" ** 91 ++ "\"";
    try check("xs = [ " ++ item_93 ++ " ]\n", "xs =\n    [ " ++ item_93 ++ "\n    ]\n");
    // The same width measured at the deeper indentation of a binding:
    // `        x = [ ` + 84 + ` ]` is exactly 100, and one more breaks the
    // list, as `            [ ` + 85 + ` ]` is 101 on the line below.
    const wide_84 = "\"" ++ "b" ** 82 ++ "\"";
    try check("f =\n  let\n   x = [ " ++ wide_84 ++ " ]\n  in x\n", "f =\n    let\n        x = [ " ++ wide_84 ++ " ]\n    in\n    x\n");
    const wide_85 = "\"" ++ "b" ** 83 ++ "\"";
    try check("f =\n  let\n   x = [ " ++ wide_85 ++ " ]\n  in x\n", "f =\n    let\n        x =\n            [ " ++ wide_85 ++ "\n            ]\n    in\n    x\n");
}

// ---- Robustness ----------------------------------------------------------------

test "4 000 nested parentheses, as deep as the parser admits, format without exhausting the stack" {
    // Nesting the source writes is walked by recursion, bounded by the
    // parser's 4 096 levels (`Parse.max_depth`): this is the budget, on the
    // test runner's stack, not a loop.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const depth = 4000;
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena, "x = ");
    try src.appendNTimes(arena, '(', depth);
    try src.append(arena, '1');
    try src.appendNTimes(arena, ')', depth);
    try src.append(arena, '\n');
    // Idempotence alone: the AST dump indents each level, so at this depth
    // it is quadratic text, and the structure check is the corpus's job.
    const first = try runWith(arena, try arena.dupeZ(u8, src.items), false);
    const again = try runWith(arena, try arena.dupeZ(u8, first.text), false);
    try testing.expectEqualStrings(first.text, again.text);
}

/// Twice the length the formatter fails at when it measures a chain by
/// recursion, on `small_stack.size`: a `Measurer` that recursed into each
/// operator's operands, or into each access's base, formatted 100 links on
/// the Debug test binary and overflowed at 250.
const long_chain = 500;

test "chains longer than a recursive formatter survives format in a loop" {
    // A left-associative chain, an access chain and a question chain: the
    // three spines the parser assembles in a loop, and the formatter
    // measures and prints in a loop too (`Measurer.chain`,
    // `Measurer.access`), on `small_stack`'s few pages. The AST dump
    // recurses per node, so it is skipped and idempotence alone is
    // asserted.
    try small_stack.run(formatLongChains, .{});
}

fn formatLongChains() !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    inline for (.{ " + a", ".a", "?" }) |piece| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(arena, "x = a");
        for (0..long_chain) |_| try src.appendSlice(arena, piece);
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
    "foreign pure h{d} : Int -> Int\n",
    "foreign type Ft{d} a b\n",
    "c{d} m =\n    case m of\n        Just n ->\n            n\n\n        Nothing ->\n            0\n",
    "c2{d} m = case m of\n  Just n -> n\n  Nothing -> 0\n",
    "l{d} =\n    let\n        a = 1\n\n        b : Int\n        b = 2\n        ( p, q ) = ( a, b )\n    in\n    a + b + p + q\n",
    "i{d} x = if x then 1 else if not x then 2 else 3\n",
    "i2{d} x = if aVeryLongConditionNameNumberOne x && aVeryLongConditionNameNumberTwo x then aVeryLongThenBranch x else 0\n",
    "col{d} = ( [ 1, 2, 3 ], { a = 1, b = \"${x} and ${ y }\" }, ( 1, 2 ), [], {}, () )\n",
    "long{d} = [ \"alpha\", \"bravo\", \"charlie\", \"delta\", \"echo\", \"foxtrot\", \"golf\", \"hotel\", \"india\", \"juliet\", \"kilo\" ]\n",
    "s{d} = λa b -> a\n",
    "s2{d} = λ( a, b ) { c } _ -> a + b + c\n",
    "t{d} = f <| g <| h x\n",
    "t2{d} = text <| if a then b else c\n",
    "pipe{d} xs = xs\n    |> List.map (λx -> x * 2)\n    |> List.filter (λx -> x > 10)\n    |> List.sum\n",
    "q{d} s = parse s? |> f\n",
    "acc{d} r t = r.a.b + t.0.1 + (f r).x + List.map .name []\n",
    "m{d} =\n    \\\\a\n    \\\\b   \n",
    "p{d} (Just x) { a } ( b, c ) = -x\n",
    "u{d} m = { m | count = m.count + 1, aVeryLongFieldNameToMakeItWide = m.aVeryLongFieldNameToMakeItWide + 1 }\n",
    "op{d} = ( + ) 1 2 + (++) [ 1 ] [ ...[], 2 ] + ( ^ ) 1 2\n",
    "app{d} = List.foldl (λitem acc -> acc + String.length item * 2) 0 [ \"some\", \"long\", \"list\", \"of\", \"strings\", \"here\" ]\n",
    "ann{d} : { host : String, port : Int, user : String, password : String, timeout : Int } -> Result String { host : String, port : Int } -> Bool\nann{d} _ _ = True\n",
    "chain{d} r = String.length r.name > 0 && String.length r.name < 100 && r.age >= 0 && r.age < 150 && not (String.isEmpty r.email)\n",
    "cmt{d} x = -- after equals\n    let\n        -- before binding\n        y = 1 -- after body\n        -- before in\n    in\n    -- before body\n    if x then -- after then\n        y\n        -- before else\n    else\n        -- in else\n        case x of -- after of\n            -- before branch\n            True -> 1 -- after branch\n            -- between branches\n            False -> [ 1 -- in list\n                     , 2\n                     -- before close\n                     ]\n",
    "str{d} = \"tab\\there \\u{0041} \\$ \\' \\\"q\\\"\" ++ \"${a}\"\n",
    "num{d} = ( 0xDeadBEEF, 1.50e+03, '\\u{00041}', -1 )\n",
    "par{d} = ( ( x ) )\n",
    "nest{d} m flag =\n  case m of\n     Just n ->\n       if flag then\n           let\n             doubled = n * 2\n           in\n               doubled\n       else (λk ->\n              case k of\n                   0 -> 1\n                   _ -> k\n             ) n\n     Nothing ->\n              0\n",
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
// Opt-in (`zig build fuzz`, `fuzzing.zig`); the gates run the one module
// below that holds every construct with every kind of trivia.
// `BENI_STRESS_ITERATIONS` raises the count for a long run.
test "stress: random modules of every construct round-trip" {
    try @import("../fuzzing.zig").skipUnlessFuzzing();
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

test "one module of every stress construct, each behind every kind of trivia, round-trips" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena, "--!Module doc.\n--! More.\n\n-- a plain comment at the top\n");
    for (stress_imports) |import_line| try src.appendSlice(arena, import_line);
    for (stress_decls, 0..) |template, k| {
        try src.appendNTimes(arena, '\n', k % 4);
        try src.appendSlice(arena, "-- a comment before the declaration\n--|Doc.\n--| More doc.\n");
        var rest = template;
        while (std.mem.indexOf(u8, rest, "{d}")) |at| {
            try src.appendSlice(arena, rest[0..at]);
            try src.print(arena, "{d}", .{k});
            rest = rest[at + 3 ..];
        }
        try src.appendSlice(arena, rest);
        if (k % 2 == 0) {
            // A trailing comment on the declaration's last line.
            src.items.len -= 1;
            try src.appendSlice(arena, " -- trailing\n");
        }
    }
    try src.appendSlice(arena, "\n-- at the end\n");
    try checkRoundTrip(arena, try arena.dupeZ(u8, src.items));
}
