//! Syntax diagnostics as the parser records them (docs/design/language.md
//! §10, frontend.md §1.1), the parse-side twin of `lex/Diagnostics.zig`.
//!
//! An item is a code, a byte range and a small payload — the token that was
//! expected, the construct that was needed, the column a layout rule
//! demanded and the offset of the token that set it — so the message can be
//! rendered later from `(item, source bytes, line table)` without the parser
//! formatting anything while it runs. That keeps the parse loop free of text
//! work, lets the daemon (M4) re-report a cached file's errors, and puts
//! every sentence in one place, `message`, where it can be read as prose.
//!
//! The register is Elm's (language.md §10, last paragraph): what the parser
//! was in the middle of (`context`), what it saw (the bytes at `start`),
//! what it expected (`expected`/`construct`), and for layout errors the
//! columns involved — e.g. *I was parsing the branches of this `case` and
//! ran into `else`, which is indented to column 9. Branches must be
//! indented more than the `case` on column 5.*

const std = @import("std");
const diagnostic = @import("diagnostic");
const max_depth = @import("Parse.zig").max_depth;
const Token = @import("../lex/Token.zig");
const LexDiagnostics = @import("../lex/Diagnostics.zig");

/// One syntax error. `[start, end)` is the byte range reported — the
/// offending token, or the opening bracket for `unclosed_delimiter`, or the
/// whole comment for the doc-comment codes.
pub const Item = struct {
    code: diagnostic.Code,
    start: u32,
    end: u32,
    /// What the parser was parsing when it stopped.
    context: Context,
    /// For `expected_token`: the one token that could have come next.
    expected: Token.Tag = .invalid,
    /// For `unexpected_token` / `expected_declaration`: the construct whose
    /// start was needed.
    construct: Construct = .none,
    /// For layout errors: the column the offending token needed to be
    /// right of (or exactly on, for `let` bindings and `case` branches),
    /// and the byte range of the token that set that column (the block's
    /// head), so the message can quote it. `required_col == 0` means the
    /// error is not about layout.
    required_col: u32 = 0,
    head_start: u32 = 0,
    head_end: u32 = 0,
    /// True when the offending token sits outside the current block (its
    /// column is too small) rather than inside it — the message then
    /// explains the layout rule instead of listing alternatives.
    layout: bool = false,
};

/// What the parser was in the middle of. Rendered by `contextText`.
pub const Context = enum {
    module,
    import,
    exposing,
    declaration,
    annotation,
    definition,
    type_alias,
    type_decl,
    foreign,
    type_expr,
    expression,
    pattern,
    let_bindings,
    let_body,
    case_head,
    case_branches,
    branch_body,
    if_expr,
    lambda,
    parens,
    list,
    record,
    record_update,
    string,
    interpolation,
};

/// A construct whose start was required and not found.
pub const Construct = enum {
    none,
    declaration,
    module_name,
    exposed_name,
    constructor,
    type_expr,
    expression,
    pattern,
    binding,
    field_name,
    branch,
};

fn contextText(c: Context) []const u8 {
    return switch (c) {
        .module => "the top level of this module",
        .import => "an `import`",
        .exposing => "the `exposing` list of an import",
        .declaration => "a declaration",
        .annotation => "a type annotation",
        .definition => "a definition",
        .type_alias => "a `type alias`",
        .type_decl => "a `type` declaration",
        .foreign => "a `foreign` declaration",
        .type_expr => "a type",
        .expression => "an expression",
        .pattern => "a pattern",
        .let_bindings => "the bindings of this `let`",
        .let_body => "the body of this `let`",
        .case_head => "the expression of this `case`",
        .case_branches => "the branches of this `case`",
        .branch_body => "the body of this branch",
        .if_expr => "this `if`",
        .lambda => "this lambda",
        .parens => "a parenthesised expression",
        .list => "a list",
        .record => "a record",
        .record_update => "a record update",
        .string => "a string",
        .interpolation => "the `${…}` inside this string",
    };
}

fn constructText(c: Construct) []const u8 {
    return switch (c) {
        .none => "something else",
        .declaration => "a declaration",
        .module_name => "a module name like `Json.Decode`",
        .exposed_name => "a name to expose",
        .constructor => "a constructor, which starts with a capital letter",
        .type_expr => "a type",
        .expression => "an expression",
        .pattern => "a pattern",
        .binding => "a `let` binding",
        .field_name => "a field name",
        .branch => "a branch",
    };
}

/// The spelling of an expected token, for prose.
fn tokenText(tag: Token.Tag) []const u8 {
    return Token.lexeme(tag) orelse switch (tag) {
        .lower_ident => "a name",
        .upper_ident => "a capitalised name",
        .int => "an integer",
        .interp_end => "}",
        .str_end => "\"",
        else => @tagName(tag),
    };
}

/// Write the Elm-style prose for `item`. No trailing newline.
pub fn message(item: Item, source: []const u8, line_starts: []const u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const text = source[item.start..item.end];
    const at_eof = item.start >= source.len or item.end == item.start and item.code != .doc_comment_unattached and item.code != .module_doc_not_at_top;
    const col = LexDiagnostics.position(line_starts, item.start).col;
    const head = source[item.head_start..item.head_end];
    switch (item.code) {
        .expected_declaration => {
            if (at_eof) {
                try w.writeAll("I got to the end of the file while looking for a declaration.");
            } else {
                try w.print(
                    \\I was parsing {s} and ran into `{s}` on column 1, which cannot begin a declaration.
                    \\
                    \\A line that starts on column 1 begins a new import or declaration:
                    \\
                    \\    import Json.Decode
                    \\    type alias Point = {{ x : Int, y : Int }}
                    \\    type Shape = Circle Float | Rect Float Float
                    \\    area : Shape -> Float
                    \\    area shape = ...
                    \\
                    \\Everything that belongs to the previous declaration must be indented by at
                    \\least one space.
                , .{ contextText(item.context), text });
            }
        },
        .expected_token => {
            if (at_eof) {
                try w.print("I got to the end of the file while parsing {s}. I was expecting `{s}` next.", .{ contextText(item.context), tokenText(item.expected) });
            } else if (item.layout) {
                try w.print(
                    \\I was parsing {s} and ran into `{s}` on column {d}, but I was expecting `{s}`.
                    \\
                    \\`{s}` is not indented enough to be part of it: everything in {s} must be right
                    \\of `{s}` on column {d}. So it ended there, without the `{s}`.
                , .{ contextText(item.context), text, col, tokenText(item.expected), text, contextText(item.context), head, item.required_col, tokenText(item.expected) });
            } else {
                try w.print("I was parsing {s} and ran into `{s}`, but I was expecting `{s}` here.", .{ contextText(item.context), text, tokenText(item.expected) });
            }
        },
        .unexpected_token => {
            if (at_eof) {
                try w.print("I got to the end of the file while parsing {s}. I was expecting {s}.", .{ contextText(item.context), constructText(item.construct) });
            } else if (item.construct == .declaration and item.context == .module) {
                try w.print(
                    \\I ran into `{s}` on column {d}, which does not belong to the declaration before
                    \\it and cannot start a new one.
                    \\
                    \\A new declaration starts on column 1; everything else must be part of the
                    \\declaration above it.
                , .{ text, col });
            } else if (item.construct == .none and item.context == .declaration) {
                if (item.head_end > item.head_start) {
                    try w.print(
                        \\I was parsing the declaration of `{s}` and ran into `{s}`, which cannot continue it.
                        \\
                        \\Either it is part of the expression before it (then check what comes just
                        \\before it), or it should start a new declaration on column 1.
                    , .{ head, text });
                } else {
                    try w.print("I was parsing a declaration and ran into `{s}`, which cannot continue it.", .{text});
                }
            } else if (item.required_col != 0 and (item.context == .let_bindings or item.context == .case_branches)) {
                const what: []const u8 = if (item.context == .let_bindings) "binding" else "branch";
                const ending: []const u8 = if (item.context == .let_bindings) "and `in` ends the list" else "and the branches end at the first token left of that column";
                try w.print(
                    \\I was parsing {s} and ran into `{s}` on column {d}.
                    \\
                    \\Every {s} must start on the same column as the first one, `{s}` on column {d},
                    \\{s}.
                , .{ contextText(item.context), text, col, what, head, item.required_col, ending });
            } else if (item.layout) {
                try w.print(
                    \\I was parsing {s} and ran into `{s}` on column {d}, which is not indented enough
                    \\to be part of it. I was expecting {s}.
                    \\
                    \\Everything in {s} must be right of `{s}` on column {d}.
                , .{ contextText(item.context), text, col, constructText(item.construct), contextText(item.context), head, item.required_col });
            } else if (item.construct == .expression and isBlockStart(text)) {
                try w.print(
                    \\I was parsing {s} and ran into `{s}`, which cannot be an argument on its own.
                    \\
                    \\A `let`, `if`, `case` or lambda may end an expression, but as an argument it must
                    \\be wrapped in parentheses: `f (\x -> x)`.
                , .{ contextText(item.context), text });
            } else {
                try w.print("I was parsing {s} and ran into `{s}`. I was expecting {s}.", .{ contextText(item.context), text, constructText(item.construct) });
            }
        },
        .nesting_too_deep => try w.print(
            \\This expression is nested more than {d} levels deep, which is more than I can
            \\handle.
            \\
            \\Split it into smaller pieces with `let`, or remove some of the nesting.
        , .{max_depth}),
        .unclosed_delimiter => {
            const closer: []const u8 = if (text.len > 0) switch (text[0]) {
                '(' => ")",
                '[' => "]",
                '{' => "}",
                else => "}",
            } else ")";
            if (item.head_end == item.head_start) {
                try w.print(
                    \\I was parsing {s} and got to the end of the file without finding the `{s}` that
                    \\closes this `{s}`.
                , .{ contextText(item.context), closer, text });
            } else {
                const head_col = LexDiagnostics.position(line_starts, item.head_start).col;
                try w.print(
                    \\I was parsing {s} and ran into `{s}` on column {d} before finding the `{s}` that
                    \\closes this `{s}`.
                    \\
                    \\Everything inside the brackets must be indented more than column {d}, the column
                    \\of the block they are in. `{s}` is not, so the block ended there and the `{s}` is
                    \\missing.
                , .{ contextText(item.context), head, head_col, closer, text, item.required_col, head, closer });
            }
        },
        .annotation_without_definition => try w.print(
            \\This type annotation for `{s}` is not followed by a definition of `{s}`.
            \\
            \\An annotation must be immediately followed by the definition it describes
            \\(blank lines and comments in between are fine):
            \\
            \\    {s} : ...
            \\    {s} =
            \\        ...
        , .{ text, text, text, text }),
        .pub_on_definition => try w.print(
            \\`pub` is on the definition of `{s}`, but `{s}` also has a type annotation.
            \\
            \\When a definition has an annotation, `pub` goes on the annotation line, like
            \\`pub {s} : ...`. Remove it from the definition.
        , .{ head, head, head }),
        .opaque_not_on_type => try w.writeAll(
            \\`opaque` can only go on a custom type: `pub opaque type T = ...`.
            \\
            \\It hides the constructors of a type from other modules. A type alias or a value
            \\has no constructors to hide, so `opaque` means nothing there.
        ),
        .case_without_branches => {
            if (item.head_end == item.head_start) {
                try w.writeAll(
                    \\This `case` has no branches: the file ends right after `of`.
                    \\
                    \\A `case` needs at least one branch, indented more than the block it is in:
                    \\
                    \\    case x of
                    \\        Just n ->
                    \\            n
                );
            } else {
                const head_col = LexDiagnostics.position(line_starts, item.head_start).col;
                try w.print(
                    \\I was parsing the branches of this `case` and ran into `{s}`, which is indented to
                    \\column {d}. Branches must be indented more than the block the `case` is in, whose
                    \\column is {d}.
                    \\
                    \\A `case` needs at least one branch:
                    \\
                    \\    case x of
                    \\        Just n ->
                    \\            n
                , .{ head, head_col, item.required_col });
            }
        },
        .args_after_question => try w.print(
            \\I found the argument `{s}` after a `?`.
            \\
            \\After `?` no further arguments may follow: `f a? b` reads as `(f a)? b`, which is
            \\not an application. To pass `a?` as one argument among others, write `f (a?) b`.
        , .{text}),
        .non_associative_chain => {
            if (std.mem.eql(u8, text, "<|") or std.mem.eql(u8, text, "|>")) {
                try w.writeAll(
                    \\I found `<|` and `|>` mixed in one chain.
                    \\
                    \\The two pipe operators cannot be combined without parentheses, because it is not
                    \\clear which side applies first. Add parentheses around one of the sides.
                );
            } else if (std.mem.eql(u8, text, "<<") or std.mem.eql(u8, text, ">>")) {
                try w.writeAll(
                    \\I found `<<` and `>>` mixed in one chain.
                    \\
                    \\The two composition operators cannot be combined without parentheses, because
                    \\it is not clear which side applies first. Add parentheses around one of the sides.
                );
            } else {
                try w.print(
                    \\I found a second comparison operator, `{s}`, in the same chain.
                    \\
                    \\Comparison operators cannot be chained: `a == b == c` is not `(a == b) == c`
                    \\and not `a == (b == c)`, so write the one you mean with parentheses.
                , .{text});
            }
        },
        .negation_with_space => try w.writeAll(
            \\I found a `-` followed by a space where an expression should start.
            \\
            \\Negation is written without a space: `-x`, `-(a + b)`, `-1`. With a space, `-`
            \\is the binary minus and needs something on its left.
        ),
        .invalid_tuple_index => try w.print(
            \\`{s}` is not a valid tuple index.
            \\
            \\A tuple index is a decimal integer with no leading zeros: `.0`, `.1`, `.12`.
        , .{text}),
        .refutable_let_pattern => try w.print(
            \\I found `{s}` in a `let` pattern, but a `let` pattern must always match.
            \\
            \\Only a name, `_`, `()`, and tuples or records of those can be bound in a `let`. To
            \\match a constructor, a literal or a list, use `case`.
        , .{text}),
        .import_after_declaration => try w.writeAll(
            \\This `import` comes after a declaration.
            \\
            \\All imports must come before the first declaration. Move it to the top of the file.
        ),
        .doc_comment_unattached => try w.writeAll(
            \\This `--|` doc comment is not attached to a declaration.
            \\
            \\A `--|` block documents the declaration that starts on the next non-blank line
            \\(`pub` included). It cannot come before an import, an ordinary `--` comment, a
            \\`let` binding, or the end of the file. For a comment that is not documentation,
            \\use `--`.
        ),
        .module_doc_not_at_top => try w.writeAll(
            \\This `--!` module doc is not at the top of the file.
            \\
            \\Module documentation must come before the first import or declaration. Move it to
            \\the top, or use `--|` to document a declaration, or `--` for an ordinary comment.
        ),
        // Only the codes above are syntax errors; anything else means a
        // caller reused this record for another phase's code.
        else => try w.writeAll(diagnostic.title(item.code)),
    }
}

fn isBlockStart(text: []const u8) bool {
    return std.mem.eql(u8, text, "let") or std.mem.eql(u8, text, "if") or std.mem.eql(u8, text, "case") or std.mem.eql(u8, text, "\\");
}

// ---------------------------------------------------------------------------
// Tests: the parser's tests pin every message through the CLI path; here
// the rendering of each code is checked once from a hand-built item.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectMessage(expected: []const u8, item: Item, source: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const starts = [_]u32{0};
    try message(item, source, &starts, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "message: expected_token in and out of layout, and at end of file" {
    try expectMessage(
        "I was parsing this `if` and ran into `else`, but I was expecting `then` here.",
        .{ .code = .expected_token, .start = 9, .end = 13, .context = .if_expr, .expected = .keyword_then },
        "if x 1 2 else 2",
    );
    try expectMessage(
        "I got to the end of the file while parsing this `if`. I was expecting `then` next.",
        .{ .code = .expected_token, .start = 6, .end = 6, .context = .if_expr, .expected = .keyword_then },
        "if x 1",
    );
    try expectMessage(
        "I was parsing the bindings of this `let` and ran into `y` on column 1, but I was expecting `in`.\n\n`y` is not indented enough to be part of it: everything in the bindings of this `let` must be right\nof `let` on column 4. So it ended there, without the `in`.",
        .{ .code = .expected_token, .start = 0, .end = 1, .context = .let_bindings, .expected = .keyword_in, .layout = true, .required_col = 4, .head_start = 2, .head_end = 5 },
        "y let",
    );
}

test "message: layout errors quote both columns" {
    try expectMessage(
        "I was parsing the branches of this `case` and ran into `else`, which is indented to\ncolumn 10. Branches must be indented more than the block the `case` is in, whose\ncolumn is 5.\n\nA `case` needs at least one branch:\n\n    case x of\n        Just n ->\n            n",
        .{ .code = .case_without_branches, .start = 0, .end = 4, .context = .case_branches, .required_col = 5, .head_start = 9, .head_end = 13 },
        "case of  else",
    );
    try expectMessage(
        "I was parsing the bindings of this `let` and ran into `y` on column 3.\n\nEvery binding must start on the same column as the first one, `x` on column 5,\nand `in` ends the list.",
        .{ .code = .unexpected_token, .start = 2, .end = 3, .context = .let_bindings, .construct = .binding, .required_col = 5, .head_start = 4, .head_end = 5 },
        "  y x",
    );
}

test "message: the soft errors" {
    try expectMessage(
        "This type annotation for `f` is not followed by a definition of `f`.\n\nAn annotation must be immediately followed by the definition it describes\n(blank lines and comments in between are fine):\n\n    f : ...\n    f =\n        ...",
        .{ .code = .annotation_without_definition, .start = 0, .end = 1, .context = .annotation },
        "f : Int",
    );
    try expectMessage(
        "I found `<|` and `|>` mixed in one chain.\n\nThe two pipe operators cannot be combined without parentheses, because it is not\nclear which side applies first. Add parentheses around one of the sides.",
        .{ .code = .non_associative_chain, .start = 7, .end = 9, .context = .expression },
        "x |> g <| y",
    );
    try expectMessage(
        "`.00` is not a valid tuple index.\n\nA tuple index is a decimal integer with no leading zeros: `.0`, `.1`, `.12`.",
        .{ .code = .invalid_tuple_index, .start = 1, .end = 4, .context = .expression },
        "t.00",
    );
}
