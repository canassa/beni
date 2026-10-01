//! Lowering diagnostics as `Lower` records them (docs/design/language.md
//! §5.3, §6.2, §6.6, §7, §10), the third twin of `lex/Diagnostics.zig` and
//! `parse/Diagnostics.zig`.
//!
//! An item is a code and two byte ranges: the offending name (`start..end`)
//! and, for the "already declared / already bound / already imported"
//! codes, the earlier occurrence (`other_start..other_end`) so the message
//! can point at both. Lowering formats nothing while it runs; `message`
//! renders the prose later from `(item, source bytes, line table)`, which
//! keeps the lowering loop free of text work and lets a cached file's
//! errors be re-reported without lowering again.
//!
//! Register: Elm's — what I found, why it is a problem, what to write
//! instead. The excerpt with the caret is the renderer's job.

const std = @import("std");
const diagnostic = @import("diagnostic");

/// One lowering error. `[start, end)` is the name or token reported;
/// `[other_start, other_end)` is the earlier declaration, binding or
/// import for the duplicate/shadowing codes, and empty otherwise.
pub const Item = struct {
    code: diagnostic.Code,
    start: u32,
    end: u32,
    other_start: u32 = 0,
    other_end: u32 = 0,
    /// `let_forward_reference` only: how the reference reaches the binding
    /// that is not ready. The four readings need four messages, and the
    /// ranges cannot tell them apart: `direct` names the later binding
    /// itself, `self` is a value written in terms of itself, and `through`
    /// names a `let` function of the same block whose body reads it —
    /// `self_through` when what it reads is the binding being defined
    /// — which is not "further down" but here.
    forward: Forward = .direct,
    /// `where_variable_unbound` only: which of the two triggers of
    /// static-dispatch-spike.md §10.6 fired. False is (a), the constraint's
    /// own variable; true is (b), the closure rule — a variable that occurs
    /// only INSIDE a constraint's type. The prose differs because the
    /// mistake does, and the fix for (b) is not "delete the clause".
    inside_constraint: bool = false,
    /// Markup's lowering codes (language.md §11.17): which of a code's
    /// readings fired. The second range is the tag's name.
    markup: Markup = .none,
    /// `keyed_false_on_show` and `missing_keyed`: the text inside the braces
    /// of the `Show`'s `when`, of its body's hole and of its `fallback`,
    /// each empty when it is not written in braces — what the message
    /// writes the `case` that says the same thing from.
    when_start: u32 = 0,
    when_end: u32 = 0,
    body_start: u32 = 0,
    body_end: u32 = 0,
    fallback_start: u32 = 0,
    fallback_end: u32 = 0,

    pub fn hasOther(item: Item) bool {
        return item.other_end > item.other_start;
    }

    pub const Forward = enum(u8) { direct, self, through, self_through };

    pub const Markup = enum(u8) {
        none,
        /// `duplicate_attribute`: `children` written as an attribute and
        /// between the tags too.
        children_twice,
        /// `missing_form_attribute`: which one.
        missing_each,
        missing_when,
        missing_keyed,
        /// `invalid_keyed`: `keyed={False}` on `Show`.
        keyed_false_on_show,
        /// `unknown_module_alias`: the module of a component's tag.
        component,
        /// `invalid_attribute_name`: what the quoted name holds.
        name_empty,
        name_space,
        name_quote,
        name_equals,
        name_slash,
        name_gt,
        name_control,
        /// `misplaced_sync`: what the word marks (transparent-effects-proposal.md
        /// §15.2) — a type that is not a function type written out, or a
        /// function the declaration hands back rather than receives; or a
        /// `sync` in a package that may not write `foreign` (amended
        /// 2026-10-02).
        sync_not_function,
        sync_handed_back,
        sync_outside_platform,
    };
};

/// Write the Elm-style prose for `item`. No trailing newline.
pub fn message(item: Item, source: []const u8, line_starts: []const u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const text = source[item.start..item.end];
    const other_line = diagnostic.position(line_starts, item.other_start).line;
    // The second range as TEXT: the annotated type a `where` clause is
    // about (§10.6). Empty for every other code.
    const other = source[item.other_start..item.other_end];
    switch (item.code) {
        .duplicate_import => try w.print(
            \\The module `{s}` is imported twice; the first import is on line {d}.
            \\
            \\A module is imported once per file. Merge the two imports into one, keeping the
            \\alias and the `exposing` list you want.
        , .{ text, other_line }),
        .duplicate_import_alias => try w.print(
            \\The alias `{s}` is already used by the import on line {d}.
            \\
            \\Two imports cannot share an alias, because `{s}.name` would be ambiguous. Give one
            \\of them a different name with `as`.
        , .{ text, other_line, text }),
        .duplicate_exposed_name => try w.print(
            \\`{s}` is already exposed by the import on line {d}.
            \\
            \\A name can be exposed once per file, or `{s}` would be ambiguous. Remove one of
            \\the two, or qualify the name where it is used instead.
        , .{ text, other_line, text }),
        .self_import => try w.print(
            \\This module imports itself: it is `{s}`.
            \\
            \\A module's own declarations are already in scope, so remove the import.
        , .{text}),
        .duplicate_declaration => try w.print(
            \\`{s}` is declared twice in this module; the first declaration is on line {d}.
            \\
            \\Each top-level name is declared once. Rename one of them, or delete the one you
            \\do not need.
        , .{ text, other_line }),
        .duplicate_type => try w.print(
            \\The type `{s}` is declared twice in this module; the first is on line {d}.
            \\
            \\Custom types and type aliases share one namespace, so each type name is declared
            \\once. Rename one of them.
        , .{ text, other_line }),
        .duplicate_constructor => try w.print(
            \\The constructor `{s}` is declared twice in this module; the first is on line {d}.
            \\
            \\All constructors of a module share one namespace, whatever type they belong to,
            \\so `{s}` in an expression would be ambiguous. Rename one of them.
        , .{ text, other_line, text }),
        .shadows_import => try w.print(
            \\`{s}` is declared here, but it is also exposed by the import on line {d}.
            \\
            \\A declaration cannot reuse a name from an `exposing` list. Either rename the
            \\declaration, or drop `{s}` from the import and qualify it where it is used.
        , .{ text, other_line, text }),
        .duplicate_field => try w.print(
            \\The field `{s}` appears twice in this record.
            \\
            \\Each field of a record is set once. Remove one of the two.
        , .{text}),
        .misplaced_sync => if (item.markup == .sync_outside_platform) try w.writeAll(
            \\Only a platform package may write `sync`.
            \\
            \\`sync` marks a function that a platform calls synchronously, so that it must
            \\never suspend. It is legal in the core package and in a package whose manifest
            \\says `"platform": true`. A function of yours gets the same guarantee by being
            \\handed to a platform function that marks its parameter `sync`. Remove the
            \\`sync`; the signature means the same without it.
        ) else if (item.markup == .sync_handed_back) try w.writeAll(
            \\This `sync` marks a function the platform hands back to beni, not one it receives.
            \\
            \\`sync` says that the platform calls a function synchronously, so the function
            \\must never suspend. That is a promise about a function the platform is GIVEN:
            \\a parameter of the declaration, or something inside one. A function it returns,
            \\or passes to a callback of its own, is the platform's, and its declared rung
            \\already says what calling it may do. Remove the `sync`.
        ) else try w.writeAll(
            \\`sync` marks a function type, and this is not one written out.
            \\
            \\Write the function type itself inside the parentheses, as in
            \\`sync (String -> msg)`: the mark belongs to that one arrow. An alias of a
            \\function type is not enough, because the mark must be where the arrow is.
        ),
        .foreign_outside_platform => try w.writeAll(
            \\This `foreign` declaration is outside a platform package.
            \\
            \\`foreign` declares a value or type implemented in JavaScript. It is legal in the
            \\core package and in a package whose manifest says `"platform": true`
            \\(`docs/design/boundary.md` §2), and nowhere else. Write the definition in beni,
            \\or move it into a platform package of your own.
        ),
        .equatable_outside_core => try w.writeAll(
            \\The `equatable` marker is core's alone.
            \\
            \\It says that a type may be compared with `==`, and only the core package
            \\states that by hand; your own annotations get the mark by inference. Delete
            \\it — `a` on its own means the same thing here.
        ),
        .equatable_not_first_occurrence => try w.writeAll(
            \\This type variable is already marked `equatable`.
            \\
            \\The prefix marks the VARIABLE, at its first occurrence, not the argument it
            \\stands in front of: `eq : equatable a -> a -> Bool` is a function of two
            \\arguments whose type is one marked `a`. Write the marker once.
        ),
        .unbound_variable => try w.print(
            \\I cannot find a `{s}` variable.
            \\
            \\It is not a local binding, a top-level value of this module, a name from an
            \\`exposing` list, or a prelude value. Check the spelling, or add it to an import.
        , .{text}),
        .unbound_constructor => try w.print(
            \\I cannot find a `{s}` constructor.
            \\
            \\It is not declared by a `type` in this module, listed in an `exposing` list, or
            \\part of the prelude. Check the spelling, or expose it from an import.
        , .{text}),
        .unbound_type => try w.print(
            \\I cannot find a `{s}` type.
            \\
            \\It is not declared in this module, listed in an `exposing` list, or part of the
            \\prelude. Check the spelling, or expose it from an import.
        , .{text}),
        .unknown_module_alias => if (item.markup == .component) {
            // A component's tag (language.md §11.8): `Card` and `Ui.Card`
            // name a module, `Card.header` a module then a value.
            const dot = std.mem.lastIndexOfScalar(u8, text, '.');
            const member = if (dot) |d| d + 1 < text.len and std.ascii.isLower(text[d + 1]) else false;
            const module = if (member) text[0..dot.?] else text;
            try w.print(
                \\I cannot find a module named `{s}` for the component `<{s}>`.
                \\
                \\A capitalised tag is a component: `<TodoItem …/>` calls the `view` of the module
                \\imported as `TodoItem`, and `<Card.header …/>` the value `header` of the module
                \\imported as `Card`. Import the module under that name, as in
                \\`import Ui.TodoItem as TodoItem`.
            , .{ module, text });
        } else {
            const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse text.len;
            try w.print(
                \\I cannot find a module named `{s}` for `{s}`.
                \\
                \\A qualified name starts with an import's alias (`import Json.Decode as D` makes
                \\`D`, and `import Json.Decode` alone makes `Json.Decode`) or with one of the
                \\prelude modules: Basics, List, Maybe, Result, String, Char, Debug, Int, Float.
            , .{ text[0..dot], text });
        },
        .annotation_without_definition => try w.print(
            \\This type annotation for `{s}` is not followed by a definition of `{s}`.
            \\
            \\The next binding is a `<-`, and a bind is not a definition: it takes no
            \\annotation, because the type it would name belongs to the callee. Remove the
            \\annotation, or write `{s} = ...` instead of `{s} <- ...`.
        , .{ text, text, text, text }),
        .bind_rhs_forward_reference => try w.print(
            \\`{s}` is bound after this `<-`, so the call cannot see it.
            \\
            \\`let x <- f a` passes everything after it to `f a` as a callback, which means
            \\the bindings below the `<-` do not exist yet where the call is made. Move the
            \\binding of `{s}` above the `<-`.
        , .{ text, text }),
        .let_forward_reference => switch (item.forward) {
            .direct => try w.print(
                \\`{s}` is bound further down this `let`, on line {d}.
                \\
                \\A `let` evaluates its value bindings in the order they are written, so `{s}` has no
                \\value yet where it is used here. Move the binding of `{s}` above this one. A `let`
                \\FUNCTION is different — it is hoisted, so it can be used before it is written.
            , .{ text, other_line, text, text }),
            .self => try w.print(
                \\`{s}` is defined in terms of itself.
                \\
                \\A `let` evaluates its value bindings in the order they are written, so `{s}` has no
                \\value yet inside its own right-hand side. Only a FUNCTION can be recursive: give
                \\`{s}` a parameter, or compute it from a different binding.
            , .{ text, text, text }),
            .self_through => try w.print(
                \\`{s}` is defined in terms of itself, through `{s}`: naming `{s}` here may call
                \\`{s}`, and `{s}` reads `{s}`.
                \\
                \\A `let` evaluates its value bindings in the order they are written, so `{s}` has no
                \\value yet inside its own right-hand side. Only a FUNCTION can be recursive: give
                \\`{s}` a parameter, or compute it without `{s}`.
            , .{ other, text, text, text, text, other, other, other, text }),
            .through => try w.print(
                \\Naming `{s}` here reads `{s}`, which is bound further down this `let`, on line {d}.
                \\
                \\A `let` evaluates its value bindings in the order they are written, so this binding
                \\runs before `{s}` has a value — and naming `{s}` may call it, which reads `{s}`.
                \\Move the binding of `{s}` above this one.
            , .{ text, other, other_line, other, text, other, other }),
        },
        .question_in_lambda => try w.writeAll(
            \\This `?` is inside a lambda.
            \\
            \\`?` returns early from the nearest enclosing definition that has parameters, and
            \\a lambda in between would have to return instead. Move the `?` out of the lambda,
            \\or turn the lambda into a named `let` function.
        ),
        .question_outside_function => try w.writeAll(
            \\This `?` is not inside a function.
            \\
            \\`?` returns early from the nearest enclosing definition that has parameters, and
            \\there is none here: a constant has nothing to return from. Use `case` on the
            \\value, or give the definition a parameter.
        ),
        .shadowing => {
            if (item.hasOther()) {
                try w.print("The name `{s}` is already bound on line {d}.", .{ text, other_line });
            } else {
                try w.print("The name `{s}` is already bound: it is a prelude value.", .{text});
            }
            try w.writeAll(
                \\
                \\
                \\Shadowing is not allowed: a binding cannot reuse a name that is in scope, whether
                \\from an enclosing binding, a top-level declaration, an `exposing` list or the
                \\prelude. Rename one of them.
            );
        },
        .duplicate_pattern_variable => try w.print(
            \\The pattern variable `{s}` is bound twice in this pattern.
            \\
            \\Each variable can appear once in a pattern. Rename the second `{s}`, or use `_` if
            \\you do not need it.
        , .{ text, text }),
        .duplicate_type_parameter => try w.print(
            \\The type parameter `{s}` is declared twice.
            \\
            \\Each type parameter is declared once. Remove the duplicate.
        , .{text}),
        .too_many_type_parameters => try w.print(
            \\This type has more than 65 535 type parameters, the most a type may declare.
            \\`{s}` is the first one past that.
            \\
            \\A type's number of parameters is a 16-bit count in the interface other modules
            \\read it through, so it cannot be recorded exactly. Group the parameters into
            \\records or into types of their own.
        , .{text}),
        .unbound_type_variable => try w.print(
            \\The type variable `{s}` is not a parameter of this type.
            \\
            \\Every type variable used in a `type` or `type alias` body must be declared as a
            \\parameter: `type alias Wrapper {s} = ...`.
        , .{ text, text }),
        // The two well-formedness rules of a `where` clause
        // (static-dispatch-spike.md §2.4, §10.6, §10.7). Both are decided
        // in lowering, so both are lowering diagnostics.
        .where_variable_unbound => if (item.inside_constraint) {
            try w.print(
                \\`{s}` appears in a constraint but not in the type.
                \\
                \\This constraint mentions `{s}`, but `{s}` is not a variable of
                \\
                \\    {s}
                \\
                \\A constraint may only mention variables the annotation quantifies, because
                \\those are the ones a caller gets to choose.
                \\
                \\Hint: give the declaration a parameter or a result that mentions `{s}`.
            , .{ text, text, text, other, text });
        } else {
            try w.print(
                \\`{s}` is not a type variable of this annotation.
                \\
                \\A `where` clause constrains a variable of the type above it, and `{s}` does not
                \\appear in
                \\
                \\    {s}
            , .{ text, text, other });
        },
        .duplicate_where_constraint => try w.print(
            \\`{s}` is constrained twice; the first constraint is on line {d}.
            \\
            \\One variable carries one constraint per method name. Merge the two, or constrain
            \\a different method.
        , .{ text, other_line }),
        .duplicate_schema_modifier => try w.print(
            \\This field already has the `{s}` modifier on line {d}.
            \\
            \\Each field applies `as`, `via`, `optional` and `nullable` at most once.
            \\Compose conversions explicitly when two transformations are needed.
        , .{ text, other_line }),
        // Markup (language.md §11.17, frontend.md §9.7). The second range
        // is the tag's name, except for `duplicate_attribute`'s ordinary
        // reading, where it is the first occurrence.
        .duplicate_attribute => if (item.markup == .children_twice) {
            try w.print(
                \\`<{s}>` is given `children` twice: as an attribute here, and between its tags.
                \\
                \\What is written between the tags IS the `children` field, so the second would
                \\silently win. Keep one of the two.
            , .{other});
        } else {
            try w.print("The attribute `{s}` is written twice; the first is on line {d}.", .{ text, other_line });
            // Spelled differently: an element's names are one to HTML,
            // which folds their case.
            if (!std.mem.eql(u8, std.mem.trim(u8, text, "\""), std.mem.trim(u8, other, "\""))) try w.print(
                \\ HTML reads an
                \\element's attribute names without regard to case, so `{s}` and `{s}` are one
                \\name.
            , .{ other, text });
            try w.writeAll(
                \\
                \\
                \\Each attribute is written once, or the second would silently win. Remove one of
                \\the two.
            );
        },
        .spread_on_element => try w.print(
            \\`<{s}>` cannot take a spread: a spread `{{...record}}` is the first attribute of a
            \\component, whose record it extends.
            \\
            \\A spread of attributes onto an element is not supported yet. Write the attributes
            \\it would set one by one.
        , .{other}),
        .spread_not_first => try w.print(
            \\This spread is not the first attribute of `<{s}>`.
            \\
            \\A component's spread is the record its other attributes update, so it comes first
            \\and there is one: `<{s} {{...defaults}} title="x" />`. Move it to the front.
        , .{ other, other }),
        .invalid_form_children => try w.print(
            \\`<{s}>` takes exactly one child: a hole holding the function that renders {s}.
            \\
            \\    {s}
        , .{
            other,
            if (std.mem.eql(u8, other, "For")) @as([]const u8, "each item") else "the value",
            if (std.mem.eql(u8, other, "For"))
                @as([]const u8, "<For each={items}>{λitem -> <li>{item.label}</li>}</For>")
            else
                "<Show when={model.user} keyed>{λuser -> <UserEditor user={user} />}</Show>",
        }),
        .unknown_form_attribute => {
            const is_for = std.mem.eql(u8, other, "For");
            const names: []const []const u8 = if (is_for) &.{ "each", "keyed", "fallback" } else &.{ "when", "keyed", "fallback" };
            try w.print("`{s}` is not an attribute of `<{s}>`, which takes `{s}`, `{s}` and `{s}`.", .{ text, other, names[0], names[1], names[2] });
            if (nearest(text, names)) |near| try w.print("\n\nHint: did you mean `{s}`?", .{near});
        },
        .missing_form_attribute => switch (item.markup) {
            .missing_each => try w.writeAll(
                \\This `<For>` has no `each`: the list it renders.
                \\
                \\    <For each={items} keyed={.id}>{λitem -> <li>{item.label}</li>}</For>
            ),
            .missing_when => try w.writeAll(
                \\This `<Show>` has no `when`: the `Maybe` whose value it shows.
                \\
                \\    <Show when={model.user} keyed>{λuser -> <UserEditor user={user} />}</Show>
            ),
            else => {
                try w.writeAll(
                    \\This `<Show>` has no `keyed`, so it would not say when to rebuild what it shows.
                    \\
                    \\A `<Show>` remounts its body when its value changes: `keyed` for a new value by
                    \\identity, `keyed={.id}` for a new key. To patch the body in place instead, write
                    \\the `case` it would be:
                    \\
                    \\
                );
                try writeShowCase(w, source, item);
            },
        },
        .invalid_keyed => if (item.markup == .keyed_false_on_show) {
            try w.writeAll(
                \\`keyed={False}` would make a `<Show>` that never remounts, which is a `case`.
                \\
                \\Write `keyed`, or `keyed={.id}` for a key, or the `case` itself:
                \\
                \\
            );
            try writeShowCase(w, source, item);
        } else {
            try w.print(
                \\`{s}` is not a keying mode of `<{s}>`.
                \\
                \\`keyed` takes a key function, `keyed={{.id}}`, or a mode: bare `keyed` or
                \\`keyed={{True}}` keeps a row by its item's identity, and `keyed={{False}}` (on `<For>`)
                \\by its position.
            , .{ text, other });
        },
        .invalid_attribute_name => {
            try w.print("`{s}` cannot be an attribute's name: it {s}.", .{ text, switch (item.markup) {
                .name_empty => "is empty",
                .name_space => "holds whitespace",
                .name_quote => "holds a quote",
                .name_equals => "holds `=`",
                .name_slash => "holds `/`",
                .name_gt => "holds `>`",
                else => "holds a control character",
            } });
            try w.writeAll(
                \\
                \\
                \\A page ends an attribute's name at whitespace, a quote, `=`, `/` or `>`, and
                \\what follows begins another attribute, which the vocabulary never sees:
                \\`"x onclick"` would write an event handler. A quoted name may hold any other
                \\character but a control character.
            );
        },
        .vocabulary_outside_platform => try w.writeAll(
            \\This vocabulary declaration is outside a platform package.
            \\
            \\`pub element`, `pub attribute`, `pub event` and `pub markup` declare the markup a
            \\platform offers (`docs/design/language.md` §11.14). Like `foreign`, they are legal
            \\in a package whose manifest says `"platform": true`, and nowhere else.
        ),
        // Only the codes above are lowering errors; anything else means a
        // caller reused this record for another phase's code.
        else => try w.writeAll(diagnostic.title(item.code)),
    }
}

/// The name of `names` nearest `text` by edit distance, if any is within
/// half its length, or two edits: the "did you mean" of a form's attribute.
/// The `case` a `Show` would be, four spaces in, from the program's own
/// `when`, body and `fallback` (`Item.when_start` and the rest): `Just`
/// with the body's parameter and what it returns, `Nothing` with the
/// fallback, or an empty fragment when there is none. An example stands in
/// when the `when` or the body is not one the message can take apart.
fn writeShowCase(w: *std.Io.Writer, source: []const u8, item: Item) std.Io.Writer.Error!void {
    const blank = " \t\r\n";
    const when = std.mem.trim(u8, source[item.when_start..item.when_end], blank);
    const body = std.mem.trim(u8, source[item.body_start..item.body_end], blank);
    const fallback = std.mem.trim(u8, source[item.fallback_start..item.fallback_end], blank);
    if (when.len == 0 or body.len == 0 or std.mem.indexOfScalar(u8, when, '\n') != null) return w.writeAll(
        \\    case model.user of
        \\        Just user ->
        \\            <UserEditor user={user} />
        \\
        \\        Nothing ->
        \\            <p>Pick a user</p>
    );
    try w.print("    case {s} of\n", .{when});
    // A lambda's head is `λ` (two bytes) or the old `\` (language.md §12.1).
    const head: usize = if (std.mem.startsWith(u8, body, "λ")) "λ".len else if (body[0] == '\\') 1 else 0;
    const arrow = if (head != 0) std.mem.indexOf(u8, body, "->") else null;
    if (arrow) |at| {
        try w.print("        Just {s} ->\n", .{std.mem.trim(u8, body[head..at], blank)});
        try writeBlock(w, source, std.mem.trim(u8, body[at + 2 ..], blank), "            ");
    } else if (std.mem.indexOfAny(u8, body, blank) == null) {
        try w.print("        Just value ->\n            {s} value", .{body});
    } else if (std.mem.indexOfScalar(u8, body, '\n') == null) {
        try w.print("        Just value ->\n            ({s}) value", .{body});
    } else {
        try w.writeAll("        Just value ->\n");
        try writeBlock(w, source, body, "            ");
    }
    try w.writeAll("\n\n        Nothing ->\n");
    if (fallback.len == 0) return w.writeAll("            <></>");
    try writeBlock(w, source, fallback, "            ");
}

/// `text`, a slice of `source`, with each line after `indent`: its first
/// line where it starts, the rest kept where they stand relative to it.
fn writeBlock(w: *std.Io.Writer, source: []const u8, text: []const u8, indent: []const u8) std.Io.Writer.Error!void {
    const start = @intFromPtr(text.ptr) - @intFromPtr(source.ptr);
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..start], '\n')) |n| n + 1 else 0;
    const first_column = start - line_start;
    var base = first_column;
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        const content = std.mem.trimEnd(u8, line, " \t\r");
        if (content.len == 0) continue;
        base = @min(base, content.len - std.mem.trimStart(u8, content, " ").len);
    }
    lines.reset();
    var first = true;
    while (lines.next()) |line| {
        const content = std.mem.trimEnd(u8, line, " \t\r");
        if (first) {
            try w.writeAll(indent);
            try w.splatByteAll(' ', first_column - base);
            try w.writeAll(content);
            first = false;
            continue;
        }
        try w.writeByte('\n');
        if (content.len == 0) continue;
        try w.writeAll(indent);
        try w.writeAll(content[@min(base, content.len)..]);
    }
}

fn nearest(text: []const u8, names: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (names) |n| {
        const d = editDistance(text, n);
        if (d < best_distance) {
            best = n;
            best_distance = d;
        }
    }
    if (best_distance == 0 or best_distance > @max(text.len / 2, 2)) return null;
    return best;
}

/// Levenshtein distance for short names; a name longer than 32 bytes is
/// never near.
fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 32 or b.len > 32) return std.math.maxInt(usize) / 4;
    var prev: [33]usize = undefined;
    var cur: [33]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

// ---------------------------------------------------------------------------
// Tests: `Lower.zig` pins codes and positions; here the prose of each
// payload shape is checked once from a hand-built item.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectMessage(expected: []const u8, item: Item, source: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(testing.allocator);
    try starts.append(testing.allocator, 0);
    for (source, 0..) |c, i| if (c == '\n') try starts.append(testing.allocator, @intCast(i + 1));
    try message(item, source, starts.items, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "message: a name with an earlier occurrence quotes its line" {
    try expectMessage(
        "`x` is declared twice in this module; the first declaration is on line 1.\n\nEach top-level name is declared once. Rename one of them, or delete the one you\ndo not need.",
        .{ .code = .duplicate_declaration, .start = 6, .end = 7, .other_start = 0, .other_end = 1 },
        "x = 1\nx = 2\n",
    );
    try expectMessage(
        "The name `k` is already bound on line 1.\n\nShadowing is not allowed: a binding cannot reuse a name that is in scope, whether\nfrom an enclosing binding, a top-level declaration, an `exposing` list or the\nprelude. Rename one of them.",
        .{ .code = .shadowing, .start = 8, .end = 9, .other_start = 2, .other_end = 3 },
        "f k = λk -> k\n",
    );
}

test "message: duplicate exposed name points at the earlier import" {
    try expectMessage(
        "`empty` is already exposed by the import on line 1.\n\nA name can be exposed once per file, or `empty` would be ambiguous. Remove one of\nthe two, or qualify the name where it is used instead.",
        .{ .code = .duplicate_exposed_name, .start = 50, .end = 55, .other_start = 22, .other_end = 27 },
        "import Dict exposing (empty)\nimport Set exposing (empty)\n",
    );
}

test "message: unknown module alias splits the alias from the name" {
    try expectMessage(
        "I cannot find a module named `Dict` for `Dict.empty`.\n\nA qualified name starts with an import's alias (`import Json.Decode as D` makes\n`D`, and `import Json.Decode` alone makes `Json.Decode`) or with one of the\nprelude modules: Basics, List, Maybe, Result, String, Char, Debug, Int, Float.",
        .{ .code = .unknown_module_alias, .start = 4, .end = 14 },
        "x = Dict.empty\n",
    );
}

test "message: the payload-free codes" {
    try expectMessage(
        "This `?` is inside a lambda.\n\n`?` returns early from the nearest enclosing definition that has parameters, and\na lambda in between would have to return instead. Move the `?` out of the lambda,\nor turn the lambda into a named `let` function.",
        .{ .code = .question_in_lambda, .start = 0, .end = 1 },
        "?",
    );
    try expectMessage(
        "This `foreign` declaration is outside a platform package.\n\n`foreign` declares a value or type implemented in JavaScript. It is legal in the\ncore package and in a package whose manifest says `\"platform\": true`\n(`docs/design/boundary.md` §2), and nowhere else. Write the definition in beni,\nor move it into a platform package of your own.",
        .{ .code = .foreign_outside_platform, .start = 0, .end = 7 },
        "foreign",
    );
    try expectMessage(
        "The `equatable` marker is core's alone.\n\nIt says that a type may be compared with `==`, and only the core package\nstates that by hand; your own annotations get the mark by inference. Delete\nit — `a` on its own means the same thing here.",
        .{ .code = .equatable_outside_core, .start = 0, .end = 9 },
        "equatable",
    );
    try expectMessage(
        "This type variable is already marked `equatable`.\n\nThe prefix marks the VARIABLE, at its first occurrence, not the argument it\nstands in front of: `eq : equatable a -> a -> Bool` is a function of two\narguments whose type is one marked `a`. Write the marker once.",
        .{ .code = .equatable_not_first_occurrence, .start = 0, .end = 9 },
        "equatable",
    );
}
