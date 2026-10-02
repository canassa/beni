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
    block,
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
    markup_tag,
    markup_children,
    markup_hole,
    vocabulary,
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
    /// `<-div>`: `<-` is one token, so no tag can begin there.
    dash_tag,
    /// `-<b />`: negation takes a number.
    negated_markup,
    /// A quoted attribute name holding an interpolation.
    attribute_name,
    /// Neither a string nor `{` after an attribute's `=`.
    attribute_value,
    /// An attribute of a component that is not a field name (§11.8); the
    /// head range is the component's name.
    component_prop,
    /// For `unclosed_element`: the element ended at the closing tag of an
    /// element further out, which the head range quotes.
    outer_closer,
    /// For `unclosed_delimiter`: a hole's `}` is inside the comment that
    /// follows its `{`, which the head range quotes (§9.5).
    comment_swallowed_brace,
    /// A vocabulary declaration's name holding an interpolation.
    vocabulary_name,
    /// A word that is no fact of `pub element`, `pub attribute` or `pub
    /// event` (language.md §11.14).
    element_fact,
    attribute_fact,
    event_fact,
    /// For `nesting_too_deep`: the level that did not fit is an element or
    /// a hole in markup.
    markup,
    /// A second element right after markup that has ended, `<p>a</p><p>`:
    /// two roots where an expression is one.
    adjacent_markup,
    /// A closing tag after markup that has ended: no element is open.
    stray_closing_tag,
    /// For `unclosed_delimiter`: the hole's element closed before its `}`,
    /// whose closing tag the head range quotes.
    closing_tag_in_hole,
    /// A `...` where no list's brackets surround it (language.md §6.8).
    stray_spread,
    /// A pattern spread whose operand is not a name or `_`.
    spread_operand,
    /// A block item that reads as an expression up to a `=` or `<-`: a
    /// binding whose head was broken across lines (language.md §12.2).
    binding_head,
    /// A `,` after a parenthesised block's items (language.md §12.2, B6).
    block_in_tuple,
    /// An argument after a lambda written without parentheses, which is
    /// always the last argument of its call (language.md §12.3).
    argument_after_lambda,
    /// `×` in an expression: a type token only (language.md §12.7).
    times_in_expression,
    /// `*` between two types, where a tuple type's `×` goes (language.md
    /// §12.7, *Lookalikes*).
    star_in_type,
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
        .block => "this block",
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
        .markup_tag => "an opening tag",
        .markup_children => "the children of an element",
        .markup_hole => "a `{…}` in markup",
        .vocabulary => "a vocabulary declaration",
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
        .binding => "a binding",
        .field_name => "a field name",
        .branch => "a branch",
        .constraint => "a `where` constraint like `k.compare : k, k → Order`",
        .float_pattern => "a pattern",
        .expose_all => "a name to expose",
        .dash_tag, .negated_markup => "an expression",
        .attribute_name, .vocabulary_name => "a name",
        .attribute_value => "a string or `{`",
        .component_prop => "a field name",
        .outer_closer, .comment_swallowed_brace, .markup, .closing_tag_in_hole => "something else",
        .adjacent_markup, .stray_closing_tag => "an expression",
        .element_fact => "a fact of `pub element`: `void`, `svg` or `mathml`",
        .attribute_fact => "a fact of `pub attribute`: `on`, `property`, `stateful`, `url`, `raw`, `classes` or `styles`",
        .event_fact => "a fact of `pub event`: `on`, `name`, `delegated`, `preventDefault`, `stopPropagation` or `via`",
        .stray_spread => "an expression",
        .spread_operand => "a name or `_`",
        .binding_head, .block_in_tuple, .argument_after_lambda => "something else",
        .times_in_expression => "an operator",
        .star_in_type => "`×`",
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
        .str_start => "a string",
        .markup_gt => ">",
        .markup_self_close => "/>",
        .markup_close_open => "</",
        else => @tagName(tag),
    };
}

/// `<div>` and `</div>` for the text `<div` (or `</div`), `<>` and `</>`
/// for a fragment's.
fn tagName(text: []const u8) []const u8 {
    var t = text;
    if (t.len > 0 and t[0] == '<') t = t[1..];
    if (t.len > 0 and t[0] == '/') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '>') t = t[0 .. t.len - 1];
    return t;
}

/// Write the Elm-style prose for `item`. No trailing newline.
pub fn message(item: Item, source: []const u8, line_starts: []const u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const text = source[item.start..item.end];
    const at_eof = item.start >= source.len or item.end == item.start and item.code != .doc_comment_unattached and item.code != .module_doc_not_at_top;
    const col = diagnostic.position(line_starts, source, item.start).col;
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
                    \\    area : Shape → Float
                    \\    area shape = …
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
            } else if (item.expected == .arrow and std.mem.eql(u8, text, "=") and item.end < source.len and source[item.end] == '>') {
                // `=>`, another notation's arrow (language.md §12.7).
                try w.print(
                    \\I was parsing {s} and ran into `=>`, but I was expecting `{s}` here.
                    \\
                    \\A `case` branch and a lambda take the arrow `{s}`, as a function type does:
                    \\`Just x {s} x`, `λx {s} x + 1`.
                , .{ contextText(item.context), tokenText(item.expected), tokenText(item.expected), tokenText(item.expected), tokenText(item.expected) });
            } else {
                try w.print("I was parsing {s} and ran into `{s}`, but I was expecting `{s}` here.", .{ contextText(item.context), text, tokenText(item.expected) });
            }
        },
        .unexpected_token => {
            if (at_eof) {
                try w.print("I got to the end of the file while parsing {s}. I was expecting {s}.", .{ contextText(item.context), constructText(item.construct) });
            } else if (item.construct == .dash_tag) {
                try w.writeAll(
                    \\I ran into `<-` where an expression should start. `<-` is one token, the arrow
                    \\of a bind (`x <- f a`), so this is no tag: a tag's name cannot begin with
                    \\`-`.
                    \\
                    \\A tag's name starts with a letter: `<div>`, `<my-widget>`, `<Card>`.
                );
            } else if (item.construct == .adjacent_markup) {
                const name = tagName(text);
                try w.print(
                    \\`<{s}` starts a second element right after `{s}`, where the markup before it
                    \\ended, so I read this `<` as a comparison.
                    \\
                    \\An expression holds one element. To write elements side by side, put them in
                    \\a fragment, `<>…</>`, or in an element around them.
                , .{ name, head });
            } else if (item.construct == .stray_closing_tag) {
                try w.print(
                    \\I found the closing tag `{s}`, but no element is open here: the markup
                    \\before it has already ended.
                    \\
                    \\Remove it, or check that the element it should close starts before it.
                , .{text});
            } else if (item.construct == .negated_markup) {
                try w.writeAll(
                    \\I found markup after a `-`. Negation takes a number, and markup is not one.
                    \\
                    \\Remove the `-`, or negate the number you meant: `-x`, `-(a + b)`.
                );
            } else if (item.construct == .attribute_name or item.construct == .vocabulary_name) {
                try w.writeAll(
                    \\This name holds a `${…}`, but a name is fixed text. Write it without the
                    \\interpolation.
                );
            } else if (item.construct == .attribute_value) {
                try w.print(
                    \\I was parsing {s} and ran into `{s}` after an attribute's `=`.
                    \\
                    \\An attribute's value is a string, `title="Hello"`, or an expression in braces,
                    \\`title={{greeting}}`.
                , .{ contextText(item.context), text });
            } else if (item.construct == .component_prop) {
                try w.print(
                    \\`{s}` cannot be an attribute of `<{s}>`.
                    \\
                    \\A component's attributes are the fields of the one record it takes, so each is a
                    \\field name: a lower-case letter, then letters, digits and `_`. Give the
                    \\component a field of that shape and pass the value there.
                , .{ text, head });
            } else if (item.construct == .element_fact or item.construct == .attribute_fact or item.construct == .event_fact) {
                try w.print("`{s}` is not {s}.", .{ text, constructText(item.construct) });
            } else if (item.construct == .stray_spread) {
                try w.writeAll(
                    \\I found a spread, `…`, outside a list.
                    \\
                    \\A spread puts the elements of one list into another, so it belongs inside the
                    \\brackets of a list: `[ 0, …xs ]` as an expression, `[ x, …rest ]` as a
                    \\pattern. A component's attributes take one too, as `{…props}` first in its tag.
                );
            } else if (item.construct == .binding_head) {
                try w.print(
                    \\I was parsing this block and ran into `{s}`, after a line that does not look
                    \\like the start of a binding.
                    \\
                    \\A binding's head — its pattern, or its name and parameters — goes on one line,
                    \\with its `=` or `←`, so that the line says what it is:
                    \\
                    \\    ( a, b ) = pair
                , .{text});
            } else if (item.construct == .argument_after_lambda) {
                try w.print(
                    \\I was parsing {s} and ran into `{s}`, an argument after a lambda that has
                    \\no parentheses.
                    \\
                    \\A lambda written without parentheses is the last argument of its call: its
                    \\body takes the rest of its line, or the block below it, so nothing can follow
                    \\it as another argument. To pass more after a lambda, put it in parentheses:
                    \\
                    \\    Task.bracket (λ() → open url) close λconn → use conn
                , .{ contextText(item.context), text });
            } else if (item.construct == .times_in_expression) {
                try w.print(
                    \\I found `{s}` in an expression, but `×` only writes a tuple type, as in
                    \\`Int × String`.
                    \\
                    \\Multiplication is `*`, and a tuple value is written `( a, b )`.
                , .{text});
            } else if (item.construct == .star_in_type) {
                try w.writeAll(
                    \\I found `*` between two types. A tuple type joins its element types with `×`
                    \\(U+00D7 MULTIPLICATION SIGN): `Int × String` is the type of `( 1, "a" )`.
                    \\
                    \\Write `×` instead. I read this one as `×` and went on.
                );
            } else if (item.construct == .block_in_tuple) {
                try w.writeAll(
                    \\I found a `,` after a block in parentheses. A block is not a tuple element:
                    \\its last line is its value, and nothing follows it inside the parentheses.
                    \\
                    \\To put a block's value in a tuple, bind it first and write the tuple with the
                    \\name.
                );
            } else if (item.construct == .spread_operand) {
                try w.print(
                    \\I was parsing a list pattern and ran into `{s}` after its `…`.
                    \\
                    \\A spread in a pattern names the elements it covers, or ignores them: `…rest`
                    \\or `…_`. The items around the spread match single elements, so a pattern for
                    \\them goes there: `[ x, y, …rest ]` rather than `[ x, …[ y, …_ ] ]`.
                , .{text});
            } else if (item.construct == .float_pattern) {
                try w.print(
                    \\`{s}` is a float, and a pattern cannot match a float.
                    \\
                    \\Float arithmetic rounds, so a value you expect to be exactly this one can be
                    \\off by a tiny amount and miss the branch. Compare instead, with a tolerance if
                    \\you need one:
                    \\
                    \\    if x == {s} then … else …
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
                    \\An `if` or `case` may end an expression, but as an argument it must be
                    \\wrapped in parentheses: `f (if c then a else b)`. A lambda alone may be the
                    \\last argument without them: `f a λx → x`.
                , .{ contextText(item.context), text });
            } else {
                try w.print("I was parsing {s} and ran into `{s}`. I was expecting {s}.", .{ contextText(item.context), text, constructText(item.construct) });
            }
        },
        .nesting_too_deep => if (item.construct == .markup) try w.print(
            \\This markup is nested more than {d} levels deep, counting its elements and
            \\holes, which is more than I can follow.
            \\
            \\Split the markup into smaller pieces, bound in a block or written as functions.
        , .{max_depth}) else try w.print(
            \\This expression is nested more than {d} levels deep, which is more than I can
            \\handle.
            \\
            \\Split it into smaller pieces bound in a block, or remove some of the nesting.
        , .{max_depth}),
        .unclosed_delimiter => if (item.construct == .comment_swallowed_brace) {
            try w.print(
                \\This `{{` is never closed: the comment after it, `{s}`, runs to the end of
                \\the line, and the `}}` on that line is part of the comment.
                \\
                \\A comment inside markup ends where its line ends, so a `{{…}}` that holds only a
                \\comment closes on the next line:
                \\
                \\    {{-- note
                \\    }}
            , .{std.mem.trimEnd(u8, head, " ")});
        } else if (item.construct == .closing_tag_in_hole) {
            try w.print(
                \\This `{{` is never closed: I ran into the closing tag `{s}` before the `}}`
                \\that ends it.
                \\
                \\A hole closes before the element around it: `<p>{{name}}</p>`.
            , .{head});
        } else {
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
                const head_col = diagnostic.position(line_starts, source, item.head_start).col;
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
            \\    {s} : …
            \\    {s} =
            \\        …
        , .{ text, text, text, text }),
        .pub_on_definition => try w.print(
            \\`pub` is on the definition of `{s}`, but `{s}` also has a type annotation.
            \\
            \\When a definition has an annotation, `pub` goes on the annotation line, like
            \\`pub {s} : …`. Remove it from the definition.
        , .{ head, head, head }),
        .foreign_effect_missing => try w.print(
            \\This `foreign` declaration does not say what calling `{s}` may do.
            \\
            \\A `foreign` value has no body to infer that from, so it states it between
            \\`foreign` and its name, as one of three words:
            \\
            \\    foreign pure {s} : …        -- total, never throws, no side effect
            \\    foreign impure {s} : …      -- a side effect, but never waits
            \\    foreign suspends {s} : …    -- may wait: a timer, the network
        , .{ text, text, text, text }),
        .unknown_foreign_effect => try w.print(
            \\`{s}` is not something a `foreign` declaration can say about itself.
            \\
            \\Between `foreign` and the name goes one of three words: `pure` (total, never
            \\throws, no side effect), `impure` (a side effect, but never waits) or `suspends`
            \\(may wait: a timer, the network).
        , .{text}),
        .opaque_not_on_type => try w.writeAll(
            \\`opaque` can only go on a custom type: `pub opaque type T = …`.
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
                    \\        Just n →
                    \\            n
                );
            } else {
                const head_col = diagnostic.position(line_starts, source, item.head_start).col;
                try w.print(
                    \\I was parsing the branches of this `case` and ran into `{s}`, which is indented to
                    \\column {d}. Branches must be indented more than the block the `case` is in, whose
                    \\column is {d}.
                    \\
                    \\A `case` needs at least one branch:
                    \\
                    \\    case x of
                    \\        Just n →
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
            if (isPipe(text)) {
                try w.writeAll(
                    \\I found `◁` and `▷` mixed in one chain.
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
            \\`λx → f a x c`. It is an argument and nothing else, so it cannot stand on its own,
            \\be an operand, or sit in parentheses. For a value you do not care about, name it.
        ),
        .multiple_placeholders => try w.writeAll(
            \\I found a second `_` in the same call.
            \\
            \\A call may leave one argument open: `f a _ c` is `λx → f a x c`. Two open
            \\arguments have no shorter form than the lambda they stand for, so write `f _ b _`
            \\out in full: `λx y → f x b y`.
        ),
        .operator_not_a_function => try w.print(
            \\I found `({s})`, but `{s}` is not a function.
            \\
            \\`(+)`, `(++)` and the rest name the 2-ary function the operator desugars to. `▷`
            \\and `◁` desugar to nothing: they rearrange the call they are written in — `x ▷ f a`
            \\is `f x a` and `f ◁ x` is `f x` — so there is no function to pass around. Write the
            \\lambda you meant, or name the argument.
        , .{ text, text }),
        .pipe_rhs_not_application => try w.print(
            \\I was expecting a call after this `▷`, but I ran into `{s}`.
            \\
            \\`x ▷ f a` is `f x a`: the value on the left becomes the FIRST argument of the call
            \\on the right, so the right of `▷` must be that call — a function, or a call it is
            \\one argument short of. An `if`, `case` or lambda has no argument list to
            \\insert into. Parentheses do not hand it over as a value either — they are looked
            \\through, so `5 ▷ (λy → y + 1)` CALLS the lambda on `5` and is `6`. Write that if
            \\it is what you meant. When the block is the argument rather than the function, it
            \\belongs on the right of `◁`, which does carry one: `f a ◁ case x of …`.
        , .{text}),
        .bind_rhs_not_application => try w.print(
            \\I was expecting a call after this `←`, but I ran into `{s}`.
            \\
            \\`x ← f a` passes the rest of the block to `f a` as its last argument, so the
            \\right of `←` must be the call that receives it — a function, or a call missing
            \\exactly its final argument. Wrap what you meant in parentheses, or use `=`.
        , .{text}),
        .arrow_in_tuple_element => try w.writeAll(
            \\I read the `→` in these parentheses as a function type's arrow, and then found a
            \\comma after it.
            \\
            \\The comma in a type separates PARAMETERS, so inside parentheses the token after
            \\the items decides what they were: `→` makes them a parameter list and `)` makes
            \\them a tuple. A tuple type is written with `×` now, and an element that is a
            \\function type takes parentheses, because `→` binds looser than `×`:
            \\
            \\    (Int × Int → Int) × String
        ),
        .refutable_let_pattern => try w.print(
            \\I found `{s}` in a pattern binding, but a block's pattern binding must always match.
            \\
            \\A literal and a list, with a spread or without, each match some values of their
            \\type and not others, whatever that type turns out to be, so neither can be bound
            \\in a block. A
            \\CONSTRUCTOR can, when its type has only that one — `(Box n) = b` is fine and
            \\`(Just n) = m` is not, and I say which after I have checked the types. To
            \\match on more than one shape, use `case`.
        , .{text}),
        .refutable_parameter_pattern => try w.print(
            \\I found `{s}` in a parameter, but a parameter must always match.
            \\
            \\A literal and a list, with a spread or without, each match some arguments and not
            \\others, whatever their type turns out to be, and there is nowhere for the rest to
            \\go. (A
            \\CONSTRUCTOR is allowed here when its type has only that one; I say which after I
            \\have checked the types.) Take the argument whole and `case` on it:
            \\
            \\    un m =
            \\        case m of
            \\            Just n →
            \\                n
            \\
            \\            Nothing →
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
            \\binding of a block, or the end of the file. For a comment that is not documentation,
            \\use `--`.
        ),
        .module_doc_not_at_top => try w.writeAll(
            \\This `--!` module doc is not at the top of the file.
            \\
            \\Module documentation must come before the first import or declaration. Move it to
            \\the top, or use `--|` to document a declaration, or `--` for an ordinary comment.
        ),
        // Markup (language.md §11.17, frontend.md §9.5). The span of an
        // `unclosed_element` is the `<` and the name, so `text` is `<div` or
        // `<>`; the head range quotes the token it ended at.
        .unclosed_element => {
            const name = tagName(text);
            if (item.construct == .outer_closer) {
                try w.print(
                    \\I found `{s}`, which closes an element further out, before the `</{s}>` that
                    \\closes this `<{s}>`.
                    \\
                    \\Every element is closed before the element around it: `<{s}>…</{s}>`.
                , .{ head, name, name, name, name });
            } else if (item.head_end == item.head_start) {
                try w.print(
                    \\I was parsing the children of this `<{s}>` and got to the end of the file without
                    \\finding the `</{s}>` that closes it.
                , .{ name, name });
            } else {
                const head_col = diagnostic.position(line_starts, source, item.head_start).col;
                try w.print(
                    \\I was parsing the children of this `<{s}>` and ran into `{s}` on column {d} before
                    \\finding the `</{s}>` that closes it.
                    \\
                    \\Everything inside the element must be indented more than column {d}, the column
                    \\of the block it is in. `{s}` is not, so the element ended there and its closing
                    \\tag is missing.
                , .{ name, head, head_col, name, item.required_col, head });
            }
        },
        .mismatched_closing_tag => {
            const name = tagName(head);
            const closer = tagName(text);
            try w.print(
                \\The closing tag `</{s}>` does not match the `<{s}>` it closes.
                \\
                \\A closing tag repeats its opening tag's name exactly: `<{s}>…</{s}>`. I read
                \\`</{s}>` as the end of `<{s}>` and went on.
            , .{ closer, name, name, name, closer, name });
        },
        .element_as_argument => {
            const name = tagName(text);
            try w.print(
                \\This `<` is a comparison, not the start of markup: it comes right after `{s}`,
                \\which ends an operand, so `<{s}` compares `{s}` with `{s}`, and what follows can
                \\only be markup.
                \\
                \\Markup is an operand, never a bare argument. Parenthesise it, or pass it with
                \\`◁`:
                \\
                \\    f (<{s} … />)
                \\    f ◁ <{s} … />
            , .{ head, name, head, name, name, name });
        },
        .two_spreads_in_pattern => try w.writeAll(
            \\This list pattern has a second spread.
            \\
            \\A list pattern may have one spread: the items before it match the first elements
            \\and the items after it the last ones, so with two there would be more than one
            \\way to split the list between them. Keep one, and match the rest with items:
            \\
            \\    [ first, …middle, last ]
        ),
        .cons_removed => if (item.head_end > item.head_start) {
            try w.writeAll(
                \\`::` is no longer part of beni: a list is built and matched with brackets and a
                \\spread. Write this as:
                \\
                \\
            );
            try w.writeAll("    ");
            try writeBracketForm(w, head);
            try w.writeAll(
                \\
                \\
                \\`[ x, …xs ]` is `x` followed by the elements of `xs`, and as a pattern it
                \\matches a list of at least one element, binding its first element and the rest.
                \\`beni fmt --migrate-cons <file>` writes every `::` of a file this way.
            );
        } else try w.writeAll(
            \\`(::)` is no longer part of beni, with the `::` operator it named. The function is
            \\`List.cons`:
            \\
            \\    List.cons x xs
            \\
            \\and `[ x, …xs ]` is the same list written in brackets.
        ),
        .backslash_lambda_removed => if (item.head_end > item.head_start) {
            try w.writeAll(
                \\A lambda begins with `λ` now, not `\`. Write this one as:
                \\
                \\    λ
            );
            // The head from its first parameter to its `->`, on one line.
            var space = false;
            for (std.mem.trim(u8, head, " \t\r\n")) |c| {
                if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                    space = true;
                    continue;
                }
                if (space) try w.writeByte(' ');
                space = false;
                try w.writeByte(c);
            }
            try w.writeAll(
                \\
                \\
                \\`beni fmt --migrate-lambda <file>` writes every lambda of a file this way.
            );
        } else try w.writeAll(
            \\A lambda begins with `λ` now, not `\`: write `λ` where the `\` is.
        ),
        .ascii_symbol_removed => {
            const symbol = Token.lexeme(item.expected).?;
            try w.print(
                \\`{s}` is written `{s}` now ({s}).
                \\
                \\`beni fmt --migrate-unicode <file>` writes every one of a file this way, and an
                \\editor with beni support turns `{s}` into `{s}` as it is typed.
            , .{ text, symbol, Token.symbolName(item.expected), text, symbol });
            if (item.expected == .arrow_left) try w.writeAll(
                \\
                \\
                \\If you meant less than a negative number, write `x < -1`, with a space.
            );
        },
        .tuple_type_removed => {
            try w.writeAll(
                \\A tuple type is written with `×` now (U+00D7 MULTIPLICATION SIGN). Write this
                \\one as:
                \\
                \\
            );
            try w.writeAll("    ");
            try writeProduct(w, text, item.construct == .type_expr);
            try w.writeAll(
                \\
                \\
                \\`beni fmt --migrate-unicode <file>` writes every one of a file this way.
            );
        },
        .let_removed => if (item.required_col > item.head_start and item.required_col < item.head_end) {
            try w.writeAll(
                \\`let … in` is gone: a body is a block now, its bindings one per line and its
                \\value on the last. Write this one as:
                \\
                \\
            );
            // The bindings, then the body after `in`, each moved to the
            // column of the block's first line and indented 4.
            try writeBlockLines(w, source, line_starts, item.head_start, item.required_col);
            try writeBlockLines(w, source, line_starts, item.required_col + 2, item.head_end);
            try w.writeAll(
                \\
                \\`beni fmt --migrate-let <file>` writes every `let` of a file this way.
            );
        } else try w.writeAll(
            \\`let … in` is gone: a body is a block now, its bindings one per line and its
            \\value on the last, with no `let` and no `in`.
        ),
        .block_ends_in_binding => try w.writeAll(
            \\This block ends with a binding, but a block ends with the expression it
            \\stands for: its last line is its value.
            \\
            \\Add the value as the last line, under the bindings, at their column:
            \\
            \\    total =
            \\        tax = price * rate
            \\        price + tax
        ),
        // Only the codes above are syntax errors; anything else means a
        // caller reused this record for another phase's code.
        else => try w.writeAll(diagnostic.title(item.code)),
    }
}

/// `let_removed`'s fix-it: the lines of `source[from..to]`, its leading and
/// trailing blank space dropped, each moved left by the column its first
/// text sits at (less where a line has fewer spaces) and indented 4: the
/// bindings, or the body, as lines of the block a `let` becomes.
fn writeBlockLines(w: *std.Io.Writer, source: []const u8, line_starts: []const u32, from: u32, to: u32) std.Io.Writer.Error!void {
    if (from >= to or to > source.len) return;
    const text = std.mem.trim(u8, source[from..to], " \t\r\n");
    if (text.len == 0) return;
    const start: u32 = @intCast(@intFromPtr(text.ptr) - @intFromPtr(source.ptr));
    const shift = diagnostic.position(line_starts, source, start).col - 1;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, " \t\r");
        if (!first) {
            var n: usize = 0;
            while (n < shift and n < line.len and line[n] == ' ') n += 1;
            line = line[n..];
        }
        first = false;
        if (line.len != 0) try w.writeAll("    ");
        try w.writeAll(line);
        try w.writeByte('\n');
    }
}

/// `cons_removed`'s fix-it (language.md §6.8): `chain`, the source text of
/// an `a :: b :: rest` chain, written in the bracket spelling. The chain is
/// split at every `::` outside brackets, strings and characters; runs of
/// whitespace, newlines included, become one space. The last part decides
/// the end: `[]` adds nothing, a list literal `[ … ]` adds its items, `_`
/// is `..._`, a parenthesised chain is opened up, and anything else is
/// spread.
fn writeBracketForm(w: *std.Io.Writer, chain: []const u8) std.Io.Writer.Error!void {
    var parts: [64][]const u8 = undefined;
    var count = splitCons(chain, &parts);
    // A parenthesised chain in tail position, `a :: (b :: rest)`, is opened
    // up; past `parts`' length the rest stays in the last part.
    while (count >= 2 and count < parts.len) {
        const last = parts[count - 1];
        if (last.len < 2 or last[0] != '(' or closerOf(last, 0) != last.len - 1) break;
        const inner = std.mem.trim(u8, last[1 .. last.len - 1], " \n\r");
        if (!hasTopCons(inner)) break;
        count -= 1;
        count += splitCons(inner, parts[count..]);
    }
    try w.writeAll("[ ");
    for (parts[0 .. count - 1], 0..) |part, i| {
        if (i != 0) try w.writeAll(", ");
        try writeSpaced(w, part);
    }
    const last = parts[count - 1];
    if (std.mem.eql(u8, last, "[]")) {
        // Nothing to add.
    } else if (last.len >= 2 and last[0] == '[' and closerOf(last, 0) == last.len - 1) {
        const inner = std.mem.trim(u8, last[1 .. last.len - 1], " \n\r");
        if (inner.len != 0) {
            try w.writeAll(", ");
            try writeSpaced(w, inner);
        }
    } else {
        try w.writeAll(", …");
        try writeSpaced(w, last);
    }
    try w.writeAll(" ]");
}

/// Split `text` at its top-level `::`s into `out`, each part trimmed.
/// Returns the count (at least 1); parts past `out`'s length stay in the
/// last one.
fn splitCons(text: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    var depth: u32 = 0;
    while (i < text.len) {
        switch (text[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            '"', '\'' => {
                i = skipQuoted(text, i);
                continue;
            },
            ':' => if (depth == 0 and i + 1 < text.len and text[i + 1] == ':' and count + 1 < out.len) {
                out[count] = std.mem.trim(u8, text[start..i], " \n\r");
                count += 1;
                i += 2;
                start = i;
                continue;
            },
            else => {},
        }
        i += 1;
    }
    out[count] = std.mem.trim(u8, text[start..], " \n\r");
    return count + 1;
}

fn hasTopCons(text: []const u8) bool {
    var parts: [2][]const u8 = undefined;
    return splitCons(text, &parts) > 1;
}

/// The index just past the quoted literal starting at `at`, escapes
/// included; the end of `text` when it is not closed.
fn skipQuoted(text: []const u8, at: usize) usize {
    const quote = text[at];
    var i = at + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
        } else if (text[i] == quote) return i + 1;
    }
    return text.len;
}

/// The index of the bracket closing the one at `open`, or `text.len`.
fn closerOf(text: []const u8, open: usize) usize {
    var depth: u32 = 0;
    var i = open;
    while (i < text.len) {
        switch (text[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -|= 1;
                if (depth == 0) return i;
            },
            '"', '\'' => {
                i = skipQuoted(text, i);
                continue;
            },
            else => {},
        }
        i += 1;
    }
    return text.len;
}

/// `text` with every run of whitespace written as one space.
fn writeSpaced(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var space = false;
    for (text) |c| {
        if (c == ' ' or c == '\n' or c == '\r') {
            space = true;
            continue;
        }
        if (space) try w.writeByte(' ');
        space = false;
        try w.writeByte(c);
    }
}

/// `text`, the source of a tuple type written `( a, b )`, written as the
/// product that replaces it (language.md §12.8): its elements joined by
/// ` × `, an element that is itself a product or a function type in
/// parentheses, and the whole in parentheses when `wrap` — where it stands
/// as a type argument. Whitespace runs, line breaks included, are one space.
fn writeProduct(w: *std.Io.Writer, text: []const u8, wrap: bool) std.Io.Writer.Error!void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '(' or trimmed[trimmed.len - 1] != ')') return writeCollapsed(w, trimmed);
    const inner = trimmed[1 .. trimmed.len - 1];
    if (wrap) try w.writeByte('(');
    var depth: usize = 0;
    var from: usize = 0;
    var first = true;
    for (inner, 0..) |c, i| {
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            ',' => if (depth == 0) {
                try writeElement(w, inner[from..i], first);
                first = false;
                from = i + 1;
            },
            else => {},
        }
    }
    try writeElement(w, inner[from..], first);
    if (wrap) try w.writeByte(')');
}

fn writeElement(w: *std.Io.Writer, raw: []const u8, first: bool) std.Io.Writer.Error!void {
    const element = std.mem.trim(u8, raw, " \t\r\n");
    if (!first) try w.writeAll(" × ");
    if (topLevelComma(element)) return writeProduct(w, element, true);
    const operand = loosest(element);
    if (operand) try w.writeByte('(');
    try writeTypeText(w, element);
    if (operand) try w.writeByte(')');
}

/// `text`, a type's source, with every tuple type inside it written as a
/// product in parentheses: a parenthesised group with a comma at its own
/// level and no arrow there is a tuple; one with an arrow is a function's
/// parameter list, and keeps its commas.
fn writeTypeText(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    var space = false;
    while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            space = true;
            i += 1;
            continue;
        }
        if (space) try w.writeByte(' ');
        space = false;
        if (c != '(') {
            try w.writeByte(c);
            i += 1;
            continue;
        }
        var depth: usize = 0;
        var close = i;
        while (close < text.len) : (close += 1) switch (text[close]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -|= 1;
                if (depth == 0) break;
            },
            else => {},
        };
        if (close >= text.len) {
            try writeCollapsed(w, text[i..]);
            return;
        }
        const group = text[i .. close + 1];
        if (topLevelComma(group) and !loosest(group[1 .. group.len - 1])) {
            try writeProduct(w, group, true);
        } else {
            try w.writeByte('(');
            try writeTypeText(w, group[1 .. group.len - 1]);
            try w.writeByte(')');
        }
        i = close + 1;
    }
}

/// Whether `text` holds an arrow or a `×` outside every bracket: a type that
/// binds looser than a product's operand may.
fn loosest(text: []const u8) bool {
    var depth: usize = 0;
    for (text, 0..) |c, i| switch (c) {
        '(', '[', '{' => depth += 1,
        ')', ']', '}' => depth -|= 1,
        else => if (depth == 0) {
            const rest = text[i..];
            if (std.mem.startsWith(u8, rest, "->") or std.mem.startsWith(u8, rest, "→") or std.mem.startsWith(u8, rest, "×")) return true;
        },
    };
    return false;
}

/// Whether `text` is a parenthesised list with a comma at its own level.
fn topLevelComma(text: []const u8) bool {
    if (text.len < 2 or text[0] != '(' or text[text.len - 1] != ')') return false;
    var depth: usize = 0;
    for (text[1 .. text.len - 1]) |c| switch (c) {
        '(', '[', '{' => depth += 1,
        ')', ']', '}' => depth -|= 1,
        ',' => if (depth == 0) return true,
        else => {},
    };
    return false;
}

fn writeCollapsed(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var space = false;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            space = true;
            continue;
        }
        if (space) try w.writeByte(' ');
        space = false;
        try w.writeByte(c);
    }
}

/// Whether `text` is a pipe in any spelling the parser reads as one: `▷`,
/// `◁`, the old `|>` and `<|`, or a lookalike of either (language.md §12.7).
fn isPipe(text: []const u8) bool {
    for ([_]Token.Tag{ .op_pipe_right, .op_pipe_left }) |tag| {
        if (std.mem.eql(u8, text, Token.lexeme(tag).?) or std.mem.eql(u8, text, Token.lexeme(tag.ascii().?).?)) return true;
    }
    const look = Token.lookalikeAt(text, 0) orelse return false;
    return look.bytes.len == text.len and (look.tag == .op_pipe_right or look.tag == .op_pipe_left);
}

fn isBlockStart(text: []const u8) bool {
    return std.mem.eql(u8, text, "let") or std.mem.eql(u8, text, "if") or std.mem.eql(u8, text, "case");
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
        "I was parsing the branches of this `case` and ran into `else`, which is indented to\ncolumn 10. Branches must be indented more than the block the `case` is in, whose\ncolumn is 5.\n\nA `case` needs at least one branch:\n\n    case x of\n        Just n →\n            n",
        .{ .code = .case_without_branches, .start = 0, .end = 4, .context = .case_branches, .required_col = 5, .head_start = 9, .head_end = 13 },
        "case of  else",
    );
    try expectMessage(
        "I was parsing the bindings of this `let` and ran into `y` on column 3.\n\nEvery binding must start on the same column as the first one, `x` on column 5,\nand `in` ends the list.",
        .{ .code = .unexpected_token, .start = 2, .end = 3, .context = .let_bindings, .construct = .binding, .required_col = 5, .head_start = 4, .head_end = 5 },
        "  y x",
    );
}

/// `cons_removed`'s fix-it for the chain `source` holds whole.
fn expectBracketForm(source: []const u8, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeBracketForm(&out.writer, source);
    try testing.expectEqualStrings(expected, out.written());
}

test "message: `cons_removed` writes the chain in brackets" {
    try expectBracketForm("x :: xs", "[ x, …xs ]");
    try expectBracketForm("a :: b :: rest", "[ a, b, …rest ]");
    try expectBracketForm("f x :: go rest", "[ f x, …go rest ]");
    try expectBracketForm("x :: []", "[ x ]");
    try expectBracketForm("x :: [ y, 2 ]", "[ x, y, 2 ]");
    try expectBracketForm("a :: (b :: [])", "[ a, b ]");
    try expectBracketForm("( a, b ) :: _", "[ ( a, b ), …_ ]");
    // A `::` inside brackets or a string is not the chain's.
    try expectBracketForm("[ \"a::b\", c ] :: g (x :: y)", "[ [ \"a::b\", c ], …g (x :: y) ]");
    // Line breaks inside the chain become spaces.
    try expectBracketForm("x\n        :: xs", "[ x, …xs ]");
    try expectMessage(
        "`(::)` is no longer part of beni, with the `::` operator it named. The function is\n`List.cons`:\n\n    List.cons x xs\n\nand `[ x, …xs ]` is the same list written in brackets.",
        .{ .code = .cons_removed, .start = 1, .end = 3, .context = .parens },
        "(::)",
    );
}

test "message: the soft errors" {
    try expectMessage(
        "This type annotation for `f` is not followed by a definition of `f`.\n\nAn annotation must be immediately followed by the definition it describes\n(blank lines and comments in between are fine):\n\n    f : …\n    f =\n        …",
        .{ .code = .annotation_without_definition, .start = 0, .end = 1, .context = .annotation },
        "f : Int",
    );
    try expectMessage(
        "I found `◁` and `▷` mixed in one chain.\n\nThe two pipe operators cannot be combined without parentheses, because it is not\nclear which side applies first. Add parentheses around one of the sides.",
        .{ .code = .non_associative_chain, .start = 8, .end = 11, .context = .expression },
        "x ▷ g ◁ y",
    );
    try expectMessage(
        "`.00` is not a valid tuple index.\n\nA tuple index is a decimal integer with no leading zeros: `.0`, `.1`, `.12`.",
        .{ .code = .invalid_tuple_index, .start = 1, .end = 4, .context = .expression },
        "t.00",
    );
}

test "message: the placeholder and the bind (language.md §6.7)" {
    try expectMessage(
        "I found a `_` where an expression should be.\n\n`_` is the placeholder for an argument a call does not supply: `f a _ c` is\n`λx → f a x c`. It is an argument and nothing else, so it cannot stand on its own,\nbe an operand, or sit in parentheses. For a value you do not care about, name it.",
        .{ .code = .placeholder_outside_argument, .start = 4, .end = 5, .context = .expression },
        "y = _ + 1",
    );
    try expectMessage(
        "I found a second `_` in the same call.\n\nA call may leave one argument open: `f a _ c` is `λx → f a x c`. Two open\narguments have no shorter form than the lambda they stand for, so write `f _ b _`\nout in full: `λx y → f x b y`.",
        .{ .code = .multiple_placeholders, .start = 10, .end = 11, .context = .expression },
        "y = f _ b _",
    );
    try expectMessage(
        "I was expecting a call after this `←`, but I ran into `+`.\n\n`x ← f a` passes the rest of the block to `f a` as its last argument, so the\nright of `←` must be the call that receives it — a function, or a call missing\nexactly its final argument. Wrap what you meant in parentheses, or use `=`.",
        .{ .code = .bind_rhs_not_application, .start = 8, .end = 9, .context = .let_bindings },
        "x ← a + b",
    );
}
