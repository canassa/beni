//! Syntax diagnostics as the parser records them (docs/design/language.md
//! §10, frontend.md §1.1), the parse-side twin of `lex/Diagnostics.zig`.
//!
//! An item is a code, a byte range and a small payload — the token that was
//! expected, the construct that was needed, the column a layout rule
//! demanded and the offset of the token that set it — so the message can be
//! rendered later from `(item, source bytes, line table)` without the parser
//! formatting anything while it runs. That keeps the parse loop free of text
//! work, lets a daemon re-report a cached file's errors, and puts
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
    where_clause,
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
    constraint,
    /// Not a construct that was missing but one that is not allowed: a
    /// float literal in a pattern, which has its own message.
    float_pattern,
    /// Elm's `T(..)` in an `exposing` list: the head
    /// range is `T`. When the program is resolved, the constructors are
    /// named in its text (`Session.rewriteMessage`).
    expose_all,
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
        .where_clause => "a `where` clause",
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
        .constraint => "a `where` constraint like `k.compare : k, k -> Order`",
        .float_pattern => "a pattern",
        .expose_all => "a name to expose",
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
    const col = diagnostic.position(line_starts, item.start).col;
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
            if (item.construct == .expose_all) {
                // Without the imported module's interface — `fmt` and the
                // dumps — the constructors cannot be named;
                // `resolve/Diagnostics.zig` names them when checking.
                try w.print(
                    \\`{s}(..)` is how Elm exposes every constructor of `{s}`, and beni has no
                    \\wildcard: list the constructors you use by name, beside the type.
                    \\
                    \\    exposing ({s}, …)
                , .{ head, head, head });
            } else if (at_eof) {
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
            } else if (item.construct == .float_pattern) {
                try w.print(
                    \\`{s}` is a float, and a pattern cannot match a float.
                    \\
                    \\Float arithmetic rounds, so a value you expect to be exactly this one can be
                    \\off by a tiny amount and miss the branch. Compare instead, with a tolerance if
                    \\you need one:
                    \\
                    \\    if x == {s} then ... else ...
                , .{ text, text });
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
                const head_col = diagnostic.position(line_starts, item.head_start).col;
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
                const head_col = diagnostic.position(line_starts, item.head_start).col;
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
        .placeholder_outside_argument => try w.writeAll(
            \\I found a `_` where an expression should be.
            \\
            \\`_` is the placeholder for an argument a call does not supply: `f a _ c` is
            \\`\x -> f a x c`. It is an argument and nothing else, so it cannot stand on its own,
            \\be an operand, or sit in parentheses. For a value you do not care about, name it.
        ),
        .multiple_placeholders => try w.writeAll(
            \\I found a second `_` in the same call.
            \\
            \\A call may leave one argument open: `f a _ c` is `\x -> f a x c`. Two open
            \\arguments have no shorter form than the lambda they stand for, so write `f _ b _`
            \\out in full: `\x y -> f x b y`.
        ),
        .operator_not_a_function => try w.print(
            \\I found `({s})`, but `{s}` is not a function.
            \\
            \\`(+)`, `(::)` and the rest name the 2-ary function the operator desugars to. `|>`
            \\and `<|` desugar to nothing: they rearrange the call they are written in — `x |> f a`
            \\is `f x a` and `f <| x` is `f x` — so there is no function to pass around. Write the
            \\lambda you meant, or name the argument.
        , .{ text, text }),
        .pipe_rhs_not_application => try w.print(
            \\I was expecting a call after this `|>`, but I ran into `{s}`.
            \\
            \\`x |> f a` is `f x a`: the value on the left becomes the FIRST argument of the call
            \\on the right, so the right of `|>` must be that call — a function, or a call it is
            \\one argument short of. A `let`, `if`, `case` or lambda has no argument list to
            \\insert into. Parentheses do not hand it over as a value either — they are looked
            \\through, so `5 |> (\y -> y + 1)` CALLS the lambda on `5` and is `6`. Write that if
            \\it is what you meant. When the block is the argument rather than the function, it
            \\belongs on the right of `<|`, which does carry one: `f a <| case x of ...`.
        , .{text}),
        .bind_rhs_not_application => try w.print(
            \\I was expecting a call after this `<-`, but I ran into `{s}`.
            \\
            \\`let x <- f a` passes the rest of the block to `f a` as its last argument, so the
            \\right of `<-` must be the call that receives it — a function, or a call missing
            \\exactly its final argument. Wrap what you meant in parentheses, or use `=`.
        , .{text}),
        .arrow_in_tuple_element => try w.writeAll(
            \\I read the `->` in these parentheses as a function type's arrow, and then found a
            \\comma after it.
            \\
            \\The comma in a type separates PARAMETERS, so inside parentheses the token after
            \\the items decides what they were: `->` makes them a parameter list and `)` makes
            \\them a tuple. A tuple element therefore cannot contain a bare `->`, because the
            \\arrow is read as the parameter list's:
            \\
            \\    ((Int, Int) -> Int, String)
            \\
            \\is not a pair whose first element is a function. Parenthesise the element:
            \\
            \\    (((Int, Int) -> Int), String)
        ),
        .refutable_let_pattern => try w.print(
            \\I found `{s}` in a `let` pattern, but a `let` pattern must always match.
            \\
            \\A literal, a list and a `::` each match some values of their type and not others,
            \\whatever that type turns out to be, so none of them can be bound in a `let`. A
            \\CONSTRUCTOR can, when its type has only that one — `let (Box n) = b` is fine and
            \\`let (Just n) = m` is not, and I say which after I have checked the types. To
            \\match on more than one shape, use `case`.
        , .{text}),
        .refutable_parameter_pattern => try w.print(
            \\I found `{s}` in a parameter, but a parameter must always match.
            \\
            \\A literal, a list and a `::` each match some arguments and not others, whatever
            \\their type turns out to be, and there is nowhere for the rest to go. (A
            \\CONSTRUCTOR is allowed here when its type has only that one; I say which after I
            \\have checked the types.) Take the argument whole and `case` on it:
            \\
            \\    un m =
            \\        case m of
            \\            Just n ->
            \\                n
            \\
            \\            Nothing ->
            \\                0
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
        // Markup is lexed (frontend.md §9.1–§9.3) but not yet parsed: the
        // whole expression is skipped as one error at its `<`.
        .not_implemented => try w.writeAll(
            \\I found markup here, which this version of beni can read but not yet compile.
            \\
            \\Markup expressions are not supported yet; build this view with function calls
            \\instead.
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

test "message: the placeholder and the bind (language.md §6.7)" {
    try expectMessage(
        "I found a `_` where an expression should be.\n\n`_` is the placeholder for an argument a call does not supply: `f a _ c` is\n`\\x -> f a x c`. It is an argument and nothing else, so it cannot stand on its own,\nbe an operand, or sit in parentheses. For a value you do not care about, name it.",
        .{ .code = .placeholder_outside_argument, .start = 4, .end = 5, .context = .expression },
        "y = _ + 1",
    );
    try expectMessage(
        "I found a second `_` in the same call.\n\nA call may leave one argument open: `f a _ c` is `\\x -> f a x c`. Two open\narguments have no shorter form than the lambda they stand for, so write `f _ b _`\nout in full: `\\x y -> f x b y`.",
        .{ .code = .multiple_placeholders, .start = 10, .end = 11, .context = .expression },
        "y = f _ b _",
    );
    try expectMessage(
        "I was expecting a call after this `<-`, but I ran into `+`.\n\n`let x <- f a` passes the rest of the block to `f a` as its last argument, so the\nright of `<-` must be the call that receives it — a function, or a call missing\nexactly its final argument. Wrap what you meant in parentheses, or use `=`.",
        .{ .code = .bind_rhs_not_application, .start = 7, .end = 8, .context = .let_bindings },
        "x <- a + b",
    );
}
