//! `beni dump --stage=ast` (docs/design/frontend.md §1.2): the tree as an
//! S-expression, so the parser has an OUTPUT the black-box suite and the
//! corpus goldens can assert without importing it.
//!
//! ```
//! (module
//!   (module_doc "Kanban board.")
//!   (import Json.Decode as D
//!     (exposed Decoder))
//!   (definition greet
//!     (doc "Says hi.")
//!     (pat_var name)
//!     (string
//!       (chunk "hi ")
//!       (interp
//!         (ident name)))))
//! ```
//!
//! One node per line, two-space indentation, the closing parenthesis on the
//! last child's line, tags spelled as in `Ast.Node.Tag`. What is inline
//! after the tag is the node's own tokens — identifiers and literals as
//! their source text, `pub`/`opaque`/`equatable`, `as X`, type parameters — never a
//! child node. Children follow one per line: a declaration's `(doc "…")`
//! lines first, then its parts in source order (a definition's parameters,
//! then its body; an application's function, then its arguments). Error
//! placeholders print as `(error <code>)`. Doc and comment text is the bytes
//! after the marker, one leading space dropped, quoted raw. Positions are
//! omitted unless asked for (`--positions`: `(tag@line:col …)`), so a
//! reformatted input leaves a golden untouched.

const std = @import("std");
const diagnostic = @import("diagnostic");
const Ast = @import("../parse/Ast.zig");
const Token = @import("../lex/Token.zig");
const Tokenizer = @import("../lex/Tokenizer.zig");
const Node = Ast.Node;
const Index = Node.Index;

pub const Options = struct {
    positions: bool = false,
};

fn isSchemaTag(tag: Node.Tag) bool {
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

pub fn write(
    w: *std.Io.Writer,
    source: [:0]const u8,
    tokens: *const Token.TokenList,
    comments: []const Token.Comment,
    line_starts: []const u32,
    tree: *const Ast,
    options: Options,
) std.Io.Writer.Error!void {
    var d: Dumper = .{
        .w = w,
        .source = source,
        .tags = tokens.items(.tag),
        .starts = tokens.items(.start),
        .comments = comments,
        .line_starts = line_starts,
        .tree = tree,
        .positions = options.positions,
    };
    try d.node(.root, 0);
    try w.writeByte('\n');
}

const Dumper = struct {
    w: *std.Io.Writer,
    source: [:0]const u8,
    tags: []const Token.Tag,
    starts: []const u32,
    comments: []const Token.Comment,
    line_starts: []const u32,
    tree: *const Ast,
    positions: bool,

    fn text(d: *const Dumper, token: Ast.TokenIndex) []const u8 {
        return Tokenizer.slice(d.source, d.tags[token], d.starts[token]);
    }

    /// `(tag` with the optional position, at `indent` (no newline before).
    fn open(d: *Dumper, comptime tag_name: []const u8, token: Ast.TokenIndex) !void {
        try d.w.writeAll("(" ++ tag_name);
        try d.position(token);
    }

    fn openTag(d: *Dumper, tag: Node.Tag, token: Ast.TokenIndex) !void {
        try d.w.print("({t}", .{tag});
        try d.position(token);
    }

    fn position(d: *Dumper, token: Ast.TokenIndex) !void {
        if (!d.positions) return;
        const pos = diagnostic.position(d.line_starts, d.source, d.starts[token]);
        try d.w.print("@{d}:{d}", .{ pos.line, pos.col });
    }

    fn child(d: *Dumper, node_index: Index, indent: usize) !void {
        try d.w.writeByte('\n');
        try d.w.splatByteAll(' ', indent);
        try d.node(node_index, indent);
    }

    fn children(d: *Dumper, nodes: []const Index, indent: usize) !void {
        for (nodes) |n| try d.child(n, indent);
    }

    /// A comment's text after its two-character marker plus the kind byte,
    /// one leading space dropped, quoted raw.
    fn commentLine(d: *Dumper, comptime label: []const u8, comment: Token.Comment, indent: usize) !void {
        const end = Tokenizer.tokenEnd(d.source, .multiline_line, comment.start);
        var body = d.source[comment.start + 3 .. end];
        if (body.len > 0 and body[0] == ' ') body = body[1..];
        try d.w.writeByte('\n');
        try d.w.splatByteAll(' ', indent);
        try d.w.print("(" ++ label ++ " \"{s}\")", .{body});
    }

    fn docs(d: *Dumper, header: Ast.DeclHeader, indent: usize) !void {
        for (d.comments[header.doc_start..header.doc_end]) |c| {
            if (c.kind == .doc) try d.commentLine("doc", c, indent);
        }
    }

    fn visibility(d: *Dumper, header: Ast.DeclHeader) !void {
        if (header.pub_token != .none) try d.w.writeAll(" pub");
        if (header.opaque_token != .none) try d.w.writeAll(" opaque");
        if (header.equatable_token != .none) try d.w.writeAll(" equatable");
    }

    fn tokenList(d: *Dumper, tokens: []const Ast.TokenIndex) !void {
        for (tokens) |t| {
            try d.w.writeByte(' ');
            try d.w.writeAll(d.text(t));
        }
    }

    fn node(d: *Dumper, n: Index, indent: usize) std.Io.Writer.Error!void {
        const tree = d.tree;
        const tag = tree.nodeTag(n);
        const main = tree.nodeMainToken(n);
        const inner = indent + 2;
        if (tag.isError()) {
            const e = tree.fullError(n);
            try d.open("error", main);
            try d.w.print(" {t})", .{e.code});
            return;
        }
        if (isSchemaTag(tag)) {
            try d.schemaNode(n, indent);
            try d.w.writeByte(')');
            return;
        }
        if (isMarkupTag(tag)) {
            try d.markupNode(n, indent);
            try d.w.writeByte(')');
            return;
        }
        switch (tag) {
            .root => {
                try d.open("module", main);
                for (d.comments[tree.module_doc.start..tree.module_doc.end]) |c| {
                    if (c.kind == .module_doc) try d.commentLine("module_doc", c, inner);
                }
                try d.children(tree.rootItems(), inner);
            },
            .import => {
                const i = tree.fullImport(n);
                try d.openTag(tag, main);
                if (i.name) |name| try d.w.print(" {s}", .{d.text(name)});
                if (i.alias) |alias| try d.w.print(" as {s}", .{d.text(alias)});
                if (i.exposing_token != null) try d.w.writeAll(" exposing");
                try d.children(i.exposed, inner);
            },
            .type_var => {
                try d.openTag(tag, main);
                if (tree.typeVarMarker(n) != null) try d.w.writeAll(" equatable");
                try d.w.print(" {s}", .{d.text(main)});
            },
            // An operator is named by its symbol whichever spelling was read
            // (language.md §12.7), so the two spellings dump alike.
            .op_fn => {
                try d.openTag(tag, main);
                try d.w.print(" {s}", .{Token.lexeme(d.tags[main].canonical()) orelse d.text(main)});
            },
            .exposed, .int, .float, .char, .ident, .ctor, .accessor, .pat_var, .pat_int, .pat_char => {
                try d.openTag(tag, main);
                try d.w.print(" {s}", .{d.text(main)});
            },
            .unit, .type_unit, .pat_unit, .pat_wild, .placeholder => try d.openTag(tag, main),
            .annotation => {
                const a = tree.fullAnnotation(n);
                try d.openTag(tag, main);
                try d.visibility(a.header);
                try d.w.print(" {s}", .{d.text(a.name)});
                try d.docs(a.header, inner);
                try d.child(a.type_expr, inner);
                try d.children(tree.whereConstraints(a.header), inner);
            },
            .definition => {
                const def = tree.fullDefinition(n);
                try d.openTag(tag, main);
                try d.visibility(def.header);
                try d.w.print(" {s}", .{d.text(def.name)});
                try d.docs(def.header, inner);
                try d.children(def.params, inner);
                try d.child(def.body, inner);
            },
            .type_alias => {
                const a = tree.fullTypeAlias(n);
                try d.openTag(tag, main);
                try d.visibility(a.header);
                try d.w.print(" {s}", .{d.text(a.name)});
                try d.tokenList(a.params);
                try d.docs(a.header, inner);
                try d.child(a.body, inner);
            },
            .type_decl => {
                const t = tree.fullTypeDecl(n);
                try d.openTag(tag, main);
                try d.visibility(t.header);
                try d.w.print(" {s}", .{d.text(t.name)});
                try d.tokenList(t.params);
                try d.docs(t.header, inner);
                try d.children(t.ctors, inner);
            },
            .foreign_value => {
                const f = tree.fullForeignValue(n);
                try d.openTag(tag, main);
                try d.visibility(f.header);
                // The rung, the lower identifier before the name when the
                // parser found one (transparent-effects-proposal.md §14.1).
                if (d.tags[f.name - 1] == .lower_ident) try d.w.print(" {s}", .{d.text(f.name - 1)});
                try d.w.print(" {s}", .{d.text(f.name)});
                try d.docs(f.header, inner);
                try d.child(f.type_expr, inner);
                try d.children(tree.whereConstraints(f.header), inner);
            },
            .foreign_type => {
                const f = tree.fullForeignType(n);
                try d.openTag(tag, main);
                try d.visibility(f.header);
                try d.w.print(" {s}", .{d.text(f.name)});
                try d.tokenList(f.params);
                try d.docs(f.header, inner);
            },
            .schema_decl, .schema_operand, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable => unreachable,
            .constructor, .type_con, .pat_ctor => {
                try d.openTag(tag, main);
                try d.w.print(" {s}", .{d.text(main)});
                try d.children(tree.children(n), inner);
            },
            .type_tuple, .type_record, .string, .tuple, .list, .record, .apply, .pat_tuple, .pat_list => {
                try d.openTag(tag, main);
                try d.children(tree.children(n), inner);
            },
            .type_record_ext => {
                const r = tree.fullTypeRecordExt(n);
                try d.openTag(tag, main);
                try d.w.print(" {s}", .{d.text(r.base)});
                try d.children(r.fields, inner);
            },
            .record_update => {
                const r = tree.fullRecordUpdate(n);
                try d.openTag(tag, main);
                try d.w.print(" {s}", .{d.text(r.base)});
                try d.children(r.fields, inner);
            },
            .where_constraint => {
                // `(where_constraint k .compare <type>)`: the constrained
                // variable and the method name, then the method's type
                // (static-dispatch-spike.md §2.1).
                const c = tree.fullWhereConstraint(n);
                try d.openTag(tag, main);
                try d.w.print(" {s} {s}", .{ d.text(c.variable), d.text(c.method) });
                try d.child(c.type_expr, inner);
            },
            .record_type_field, .field, .field_access, .tuple_index, .let_annotation => {
                try d.openTag(tag, main);
                try d.w.print(" {s}", .{d.text(main)});
                try d.child(tree.operand(n), inner);
            },
            .type_paren, .type_sync, .interp, .negate, .spread, .paren, .question, .stmt, .pat_paren, .pat_spread => {
                try d.openTag(tag, main);
                try d.child(tree.operand(n), inner);
            },
            .type_fn => {
                const f = tree.fullTypeFn(n);
                try d.openTag(tag, main);
                for (f.params) |param| try d.child(param, inner);
                try d.child(f.result, inner);
            },
            .pat_cons => {
                const data = tree.nodeData(n);
                try d.openTag(tag, main);
                try d.child(@enumFromInt(data.lhs), inner);
                try d.child(@enumFromInt(data.rhs), inner);
            },
            .chunk => {
                try d.openTag(tag, main);
                try d.w.print(" \"{s}\"", .{d.text(main)});
            },
            .multiline_string => {
                const m = tree.fullMultilineString(n);
                try d.openTag(tag, main);
                var t = m.first_line;
                while (t <= m.last_line) : (t += 1) {
                    try d.w.print(" \"{s}\"", .{d.text(t)[2..]});
                }
            },
            .pat_string => {
                try d.openTag(tag, main);
                try d.w.writeByte(' ');
                var t = main;
                while (true) : (t += 1) {
                    try d.w.writeAll(d.text(t));
                    if (d.tags[t] == .str_end or d.tags[t] == .invalid or d.tags[t] == .eof) break;
                }
            },
            .pat_neg_int => {
                try d.openTag(tag, main);
                try d.w.print(" -{s}", .{d.text(main + 1)});
            },
            .pat_record => {
                const r = tree.fullPatRecord(n);
                try d.openTag(tag, main);
                try d.tokenList(r.fields);
            },
            .pat_as => {
                const a = tree.fullPatAs(n);
                try d.openTag(tag, main);
                if (d.tags[a.name] == .lower_ident) try d.w.print(" {s}", .{d.text(a.name)});
                try d.child(a.pattern, inner);
            },
            .lambda => {
                const l = tree.fullLambda(n);
                try d.openTag(tag, main);
                try d.children(l.params, inner);
                try d.child(l.body, inner);
            },
            .@"if" => {
                const i = tree.fullIf(n);
                try d.openTag(tag, main);
                try d.child(i.cond, inner);
                try d.child(i.then_expr, inner);
                try d.child(i.else_expr, inner);
            },
            .let, .block => {
                const l = tree.fullLet(n);
                try d.openTag(tag, main);
                try d.children(l.bindings, inner);
                try d.child(l.body, inner);
            },
            .let_def => {
                const l = tree.fullLetDef(n);
                try d.openTag(tag, main);
                try d.w.print(" {s}", .{d.text(l.name)});
                try d.children(l.params, inner);
                try d.child(l.body, inner);
            },
            .let_pattern, .let_bind => {
                const l = tree.fullLetPattern(n);
                try d.openTag(tag, main);
                try d.child(l.pattern, inner);
                try d.child(l.value, inner);
            },
            .case => {
                const c = tree.fullCase(n);
                try d.openTag(tag, main);
                try d.child(c.scrutinee, inner);
                try d.children(c.branches, inner);
            },
            .branch => {
                const b = tree.fullBranch(n);
                try d.openTag(tag, main);
                try d.child(b.pattern, inner);
                try d.child(b.body, inner);
            },
            else => {
                std.debug.assert(tag.isBinop());
                const b = tree.fullBinop(n);
                try d.openTag(tag, main);
                try d.child(b.lhs, inner);
                try d.child(b.rhs, inner);
            },
        }
        try d.w.writeByte(')');
    }

    /// Kept out of `node` so schema syntax does not enlarge every recursive
    /// ordinary AST-dump frame. The depth corpus deliberately reaches the
    /// parser's 4,096-node bound on the dumper's fixed large-stack thread.
    fn schemaNode(d: *Dumper, n: Index, indent: usize) std.Io.Writer.Error!void {
        const tree = d.tree;
        const tag = tree.nodeTag(n);
        const main = tree.nodeMainToken(n);
        const inner = indent + 2;
        switch (tag) {
            .schema_decl => {
                const s = tree.fullSchemaDecl(n);
                try d.openTag(tag, main);
                try d.visibility(s.header);
                try d.w.print(" {s}", .{d.text(s.name)});
                try d.tokenList(s.params);
                try d.docs(s.header, inner);
                if (tree.nodeTag(s.body) == .schema_value) {
                    // A declaration-level modifier list uses the field
                    // payload as a compact carrier, but it is not a source
                    // field and therefore has no field name in this dump.
                    const body = tree.fullSchemaField(s.body);
                    try d.child(body.operand, inner);
                    try d.children(body.modifiers, inner);
                } else {
                    try d.child(s.body, inner);
                }
            },
            .schema_field => {
                const f = tree.fullSchemaField(n);
                try d.openTag(tag, main);
                try d.w.print(" {s}", .{d.text(f.name)});
                try d.docs(f.header, inner);
                try d.child(f.operand, inner);
                try d.children(f.modifiers, inner);
            },
            .schema_value => {
                const value = tree.fullSchemaField(n);
                try d.openTag(tag, main);
                try d.child(value.operand, inner);
                try d.children(value.modifiers, inner);
            },
            .schema_tagged => {
                const t = tree.fullSchemaTagged(n);
                try d.openTag(tag, main);
                try d.child(t.discriminator, inner);
                try d.children(t.variants, inner);
            },
            .schema_variant => {
                const v = tree.fullSchemaVariant(n);
                try d.openTag(tag, main);
                try d.w.print(" {s}", .{d.text(v.name)});
                if (v.payload) |payload| try d.child(payload, inner);
                if (v.rename) |rename| {
                    try d.w.writeAll(" as");
                    try d.child(rename, inner);
                }
            },
            .schema_operand => {
                try d.openTag(tag, main);
                try d.w.print(" {s}", .{d.text(main)});
                try d.children(tree.children(n), inner);
            },
            .schema_record => {
                try d.openTag(tag, main);
                try d.children(tree.children(n), inner);
            },
            .schema_paren, .schema_as, .schema_via => {
                try d.openTag(tag, main);
                try d.child(tree.operand(n), inner);
            },
            .schema_optional, .schema_nullable => try d.openTag(tag, main),
            else => unreachable,
        }
    }

    /// Markup and the vocabulary declarations (language.md §11), kept out of
    /// `node` for `schemaNode`'s reason. A tag prints its name inline; a
    /// self-closing tag and one closed at once print alike, because they are
    /// the same tree (§11.3). Text prints as written, before lowering trims
    /// and decodes it (frontend.md §9.4); a braced attribute value is marked
    /// `braced`, so `a={"x"}` and `a="x"` stay apart.
    fn markupNode(d: *Dumper, n: Index, indent: usize) std.Io.Writer.Error!void {
        const tree = d.tree;
        const tag = tree.nodeTag(n);
        const main = tree.nodeMainToken(n);
        const inner = indent + 2;
        switch (tag) {
            .markup_element, .markup_fragment, .markup_for, .markup_show => {
                const m = tree.fullMarkup(n);
                try d.openTag(tag, main);
                if (m.name) |name| try d.w.print(" {s}", .{d.text(name)});
                try d.children(m.attrs, inner);
                try d.children(m.children, inner);
            },
            .markup_attr => {
                const a = tree.fullMarkupAttr(n);
                try d.openTag(tag, main);
                try d.w.print(" {s}", .{d.text(a.name)});
                if (a.brace != null) try d.w.writeAll(" braced");
                if (a.value) |v| try d.child(v, inner);
            },
            .markup_attr_escape => {
                const a = tree.fullMarkupAttr(n);
                try d.openTag(tag, main);
                try d.w.writeByte(' ');
                try d.stringSource(main);
                if (a.brace != null) try d.w.writeAll(" braced");
                if (a.value) |v| try d.child(v, inner);
            },
            .markup_spread, .markup_hole => {
                try d.openTag(tag, main);
                try d.child(tree.operand(n), inner);
            },
            .markup_empty_hole => try d.openTag(tag, main),
            .markup_text => {
                try d.openTag(tag, main);
                try d.w.writeByte(' ');
                try @import("tokens.zig").writeQuoted(d.w, d.text(main));
            },
            .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => {
                const v = tree.fullVocab(n);
                try d.openTag(tag, main);
                try d.visibility(v.header);
                try d.w.writeByte(' ');
                if (v.name_string != null) try d.stringSource(v.name) else try d.w.writeAll(d.text(v.name));
                var t = v.facts_start;
                while (t < v.facts_end) : (t += 1) {
                    try d.w.writeByte(' ');
                    if (d.tags[t] == .str_start) {
                        try d.stringSource(t);
                        while (d.tags[t] != .str_end and t + 1 < v.facts_end) t += 1;
                    } else try d.w.writeAll(d.text(t));
                }
                try d.docs(v.header, inner);
                if (v.type_expr) |te| try d.child(te, inner);
            },
            else => unreachable,
        }
    }

    /// A one-line string's source, from its `str_start` to its `str_end`.
    fn stringSource(d: *Dumper, start: Ast.TokenIndex) !void {
        var t = start;
        while (d.tags[t] != .str_end and d.tags[t] != .eof and d.tags[t] != .invalid) t += 1;
        const end = Tokenizer.tokenEnd(d.source, d.tags[t], d.starts[t]);
        try d.w.writeAll(d.source[d.starts[start]..end]);
    }
};

fn isMarkupTag(tag: Node.Tag) bool {
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
