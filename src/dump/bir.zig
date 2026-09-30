//! `beni dump --stage=bir` (docs/design/frontend.md §1.2): the lowered
//! file as text, so lowering has an OUTPUT the black-box suite and the
//! corpus goldens can assert without importing it. Every desugaring of
//! language.md §8.2 is visible: an operator is a `call` of its core
//! function, a pipeline is a saturated `call`, a composition is a `lambda`,
//! an `if` is a `case` on `True`/`False`, a `?` is a `try`, an accessor is a
//! `lambda` around a `field_access`.
//!
//! ```
//! decl 0: pub value greet (annotated)
//!   doc "Says hi."
//!   %0 = type_import Basics.String
//!   %1 = pat_var local 0 (name)
//!   %2 = chunk "hi "
//!   %3 = local 0 (name)
//!   %4 = interp [%2, %3]
//!   annotation %0
//!   params [%1]
//!   body %4
//!   locals
//!     0 name param %1
//!   refs
//!     import_value Basics.max
//!   interface value greet (annotated)
//!
//! interface
//!   value greet (annotated)
//!
//! imports
//!   import Json.Decode as D exposing (Decoder, string)
//!   prelude Basics
//! ```
//!
//! One declaration per block: a header, its instructions one per line
//! numbered `%n` FROM ZERO WITHIN THE DECLARATION (every operand of a
//! declaration's instruction lies in its own range, and per-declaration
//! numbering keeps a golden stable when an earlier declaration changes),
//! then its parts, locals, refs and interface entry. A final `interface`
//! section lists every `pub` entry and `imports` lists the table, prelude
//! rows included. Symbols print as their text through `Names`; the dump
//! runs after the interner merge, so that is the global text. There are no
//! positions, so a reformatted input leaves a golden untouched.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Token = @import("../lex/Token.zig");
const Tokenizer = @import("../lex/Tokenizer.zig");
const markup_text = @import("../markup/text.zig");
const Inst = Bir.Inst;
const Index = Inst.Index;

/// How the dump turns a symbol into text: the global pool after a session
/// run, or a worker's local pool in a hermetic test.
pub const Names = struct {
    context: *const anyopaque,
    lookup: *const fn (context: *const anyopaque, symbol: InternPool.Symbol) []const u8,

    pub fn fromGlobal(global: *const InternPool.Global) Names {
        return .{ .context = global, .lookup = struct {
            fn f(context: *const anyopaque, symbol: InternPool.Symbol) []const u8 {
                const g: *const InternPool.Global = @ptrCast(@alignCast(context));
                return g.slice(symbol);
            }
        }.f };
    }

    pub fn fromLocal(local: *const InternPool.Local) Names {
        return .{ .context = local, .lookup = struct {
            fn f(context: *const anyopaque, symbol: InternPool.Symbol) []const u8 {
                const l: *const InternPool.Local = @ptrCast(@alignCast(context));
                return l.slice(symbol);
            }
        }.f };
    }

    fn text(names: Names, symbol: InternPool.Symbol) []const u8 {
        return names.lookup(names.context, symbol);
    }
};

pub fn write(
    w: *std.Io.Writer,
    source: [:0]const u8,
    comments: []const Token.Comment,
    bir: *const Bir,
    names: Names,
) std.Io.Writer.Error!void {
    var d: Dumper = .{ .w = w, .source = source, .comments = comments, .bir = bir, .names = names };
    for (bir.decls, 0..) |decl, i| {
        try d.decl(decl, @intCast(i));
        try w.writeByte('\n');
    }
    try d.interface();
    try w.writeByte('\n');
    try d.imports();
}

const Dumper = struct {
    w: *std.Io.Writer,
    source: [:0]const u8,
    comments: []const Token.Comment,
    bir: *const Bir,
    names: Names,
    /// The declaration being printed: instruction numbers are relative to
    /// its first instruction.
    base: u32 = 0,
    locals: []const Bir.Local = &.{},

    fn sym(d: *const Dumper, index: Bir.SymbolIndex) []const u8 {
        return d.names.text(d.bir.symbol(index));
    }

    fn symRaw(d: *const Dumper, index: u32) []const u8 {
        return d.sym(@enumFromInt(index));
    }

    fn declName(d: *const Dumper, index: u32) []const u8 {
        return d.sym(d.bir.decls[index].name);
    }

    fn ctorName(d: *const Dumper, index: u32) []const u8 {
        return d.sym(d.bir.ctors[index].name);
    }

    /// `%n` relative to the declaration.
    fn ref(d: *Dumper, index: u32) !void {
        try d.w.print("%{d}", .{index - d.base});
    }

    fn refIndex(d: *Dumper, index: Index) !void {
        try d.ref(index.int());
    }

    fn refList(d: *Dumper, range: Bir.SubRange) !void {
        try d.w.writeByte('[');
        for (d.bir.extraSlice(range, Index), 0..) |index, i| {
            if (i != 0) try d.w.writeAll(", ");
            try d.refIndex(index);
        }
        try d.w.writeByte(']');
    }

    fn fieldList(d: *Dumper, range: Bir.SubRange, comptime sep: []const u8) !void {
        try d.w.writeByte('{');
        for (d.bir.extraSlice(range, Bir.Field), 0..) |f, i| {
            try d.w.writeAll(if (i == 0) " " else ", ");
            try d.w.print("{s}" ++ sep, .{d.sym(f.name)});
            try d.refIndex(f.value);
        }
        try d.w.writeAll(if (range.len() == 0) "}" else " }");
    }

    /// `local 3 (name)`, or `3 (name)` right after the `local` tag itself.
    fn local(d: *Dumper, index: u32, with_word: bool) !void {
        if (with_word) try d.w.writeAll("local ");
        try d.w.print("{d}", .{index});
        if (index < d.locals.len) {
            if (d.locals[index].name.unwrap()) |_| try d.w.print(" ({s})", .{d.sym(d.locals[index].name)});
        }
    }

    /// `Module.name`, and the alias when a qualified reference went
    /// through one that differs from the module path.
    fn moduleName(d: *Dumper, module: u32, name: u32, qualified: bool) !void {
        try d.w.print("{s}.{s}", .{ d.symRaw(module), d.symRaw(name) });
        if (!qualified) return;
        const module_symbol = d.bir.symbols[module];
        for (d.bir.imports) |imp| {
            if (d.bir.symbol(imp.module) == module_symbol) {
                if (imp.alias != imp.module and d.bir.symbol(imp.alias) != module_symbol) {
                    try d.w.print(" via {s}", .{d.sym(imp.alias)});
                }
                return;
            }
        }
    }

    /// A string in double quotes, escaped where a byte would not show: the
    /// controls, and whitespace outside ASCII (a no-break space, say), which
    /// a reader could not tell from a space.
    fn quoted(d: *Dumper, bytes: []const u8) !void {
        try d.w.writeByte('"');
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const c = bytes[i];
            switch (c) {
                '"' => try d.w.writeAll("\\\""),
                '\\' => try d.w.writeAll("\\\\"),
                '\n' => try d.w.writeAll("\\n"),
                '\r' => try d.w.writeAll("\\r"),
                '\t' => try d.w.writeAll("\\t"),
                0...8, 11, 12, 14...31, 127 => try d.w.print("\\u{{{x}}}", .{c}),
                0x80...0xff => {
                    const n = markup_text.whitespaceAt(bytes, i);
                    if (n == 0) {
                        try d.w.writeByte(c);
                        continue;
                    }
                    const cp = std.unicode.utf8Decode(bytes[i..][0..n]) catch unreachable;
                    try d.w.print("\\u{{{x}}}", .{cp});
                    i += n - 1;
                },
                else => try d.w.writeByte(c),
            }
        }
        try d.w.writeByte('"');
    }

    fn char(d: *Dumper, scalar: u32) !void {
        if (scalar >= 0x20 and scalar < 0x7f and scalar != '\'' and scalar != '\\') {
            try d.w.print("'{c}'", .{@as(u8, @intCast(scalar))});
        } else {
            try d.w.print("U+{X:0>4}", .{scalar});
        }
    }

    fn docs(d: *Dumper, start: u32, end: u32) !void {
        for (d.comments[start..end]) |c| {
            if (c.kind != .doc) continue;
            const line_end = Tokenizer.tokenEnd(d.source, .multiline_line, c.start);
            var body = d.source[c.start + 3 .. line_end];
            if (body.len > 0 and body[0] == ' ') body = body[1..];
            try d.w.writeAll("  doc ");
            try d.quoted(body);
            try d.w.writeByte('\n');
        }
    }

    fn kindText(kind: Bir.Decl.Kind) []const u8 {
        return switch (kind) {
            .value => "value",
            .annotation_only => "annotation",
            .type => "type",
            .type_alias => "alias",
            .foreign_value => "foreign value",
            .foreign_type => "foreign type",
            .schema => "schema",
            .vocab_element => "element",
            .vocab_attribute => "attribute",
            .vocab_event => "event",
            .vocab_markup => "markup",
        };
    }

    fn decl(d: *Dumper, decl_: Bir.Decl, index: u32) !void {
        d.base = decl_.inst_start.int();
        d.locals = d.bir.declLocals(decl_);
        try d.w.print("decl {d}: ", .{index});
        try d.header(decl_);
        try d.w.writeByte('\n');
        try d.docs(decl_.doc_start, decl_.doc_end);

        var i = decl_.inst_start.int();
        while (i < decl_.inst_end.int()) : (i += 1) {
            try d.w.writeAll("  ");
            try d.ref(i);
            try d.w.writeAll(" = ");
            try d.writeInst(@enumFromInt(i));
            try d.w.writeByte('\n');
        }

        switch (decl_.kind) {
            .value, .annotation_only, .foreign_value => {
                if (decl_.annotation.unwrap()) |a| {
                    try d.w.writeAll("  annotation ");
                    try d.refIndex(a);
                    try d.w.writeByte('\n');
                }
                // `where k.compare : %3` — one row per constraint, in source
                // order (static-dispatch-spike.md §2.1).
                for (d.bir.declWhere(decl_)) |c| {
                    try d.w.print("  where {s}.{s} : ", .{ d.sym(c.variable), d.sym(c.method) });
                    try d.refIndex(c.type_inst);
                    try d.w.writeByte('\n');
                }
                if (decl_.kind == .value) {
                    try d.w.writeAll("  params ");
                    try d.refList(.{ .start = decl_.params_start, .end = decl_.params_end });
                    try d.w.writeByte('\n');
                    try d.w.writeAll("  body ");
                    try d.refIndex(decl_.body.unwrap().?);
                    try d.w.writeByte('\n');
                }
            },
            .type_alias => {
                try d.typeParams(decl_);
                try d.w.writeAll("  body ");
                try d.refIndex(decl_.annotation.unwrap().?);
                try d.w.writeByte('\n');
                try d.ctorRows(decl_);
            },
            .type => {
                try d.typeParams(decl_);
                try d.ctorRows(decl_);
            },
            .foreign_type => try d.typeParams(decl_),
            .schema => {
                try d.typeParams(decl_);
                try d.w.writeAll("  schema body ");
                try d.refIndex(decl_.schema_body.unwrap().?);
                try d.w.writeByte('\n');
            },
            // `facts on "input" property "value" via targetValue`, then the
            // type (language.md §11.14).
            .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => {
                const facts = d.bir.extraSlice(.{ .start = decl_.params_start, .end = decl_.params_end }, u32);
                if (facts.len != 0) {
                    try d.w.writeAll("  facts");
                    var f_at: usize = 0;
                    while (f_at < facts.len) : (f_at += Bir.extraLen(Bir.VocabFact)) {
                        const f = d.bir.extraData(@enumFromInt(@intFromEnum(decl_.params_start) + f_at), Bir.VocabFact);
                        try d.w.print(" {s}", .{f.word.spelling()});
                        if (f.arg.unwrap()) |_| {
                            try d.w.writeByte(' ');
                            if (f.word == .via) try d.w.writeAll(d.sym(f.arg)) else try d.quoted(d.sym(f.arg));
                        }
                    }
                    try d.w.writeByte('\n');
                }
                if (decl_.annotation.unwrap()) |a| {
                    try d.w.writeAll("  annotation ");
                    try d.refIndex(a);
                    try d.w.writeByte('\n');
                }
            },
        }

        if (d.locals.len != 0) {
            try d.w.writeAll("  locals\n");
            for (d.locals, 0..) |l, li| {
                try d.w.print("    {d} {s} {t} ", .{ li, if (l.name.unwrap()) |_| d.sym(l.name) else "_", l.kind });
                try d.refIndex(l.inst);
                try d.w.writeByte('\n');
            }
        }
        const refs = d.bir.declRefs(decl_);
        if (refs.len != 0) {
            try d.w.writeAll("  refs\n");
            for (refs) |r| {
                try d.w.writeAll("    ");
                switch (r.kind) {
                    .top_value => try d.w.print("top {d} ({s})", .{ r.a, d.declName(r.a) }),
                    .top_ctor => try d.w.print("ctor {d} ({s})", .{ r.a, d.ctorName(r.a) }),
                    .top_type => try d.w.print("type_top {d} ({s})", .{ r.a, d.declName(r.a) }),
                    .top_schema => try d.w.print("schema_top {d} ({s})", .{ r.a, d.declName(r.a) }),
                    .import_value => try d.w.print("import_value {s}.{s}", .{ d.symRaw(r.a), d.symRaw(r.b) }),
                    .import_ctor => try d.w.print("import_ctor {s}.{s}", .{ d.symRaw(r.a), d.symRaw(r.b) }),
                    .import_type => try d.w.print("import_type {s}.{s}", .{ d.symRaw(r.a), d.symRaw(r.b) }),
                    .import_schema => try d.w.print("import_schema {s}.{s}", .{ d.symRaw(r.a), d.symRaw(r.b) }),
                }
                try d.w.writeByte('\n');
            }
        }
        if (decl_.is_pub) {
            try d.w.writeAll("  interface ");
            try d.interfaceEntry(decl_);
            try d.w.writeByte('\n');
        }
    }

    fn ctorRows(d: *Dumper, decl_: Bir.Decl) !void {
        for (d.bir.declCtors(decl_), decl_.ctors_start..) |c, ci| {
            try d.w.print("  ctor {d} {s} ", .{ ci, d.sym(c.name) });
            try d.refList(.{ .start = c.args_start, .end = c.args_end });
            try d.w.writeByte('\n');
        }
    }

    fn typeParams(d: *Dumper, decl_: Bir.Decl) !void {
        if (decl_.params == 0) return;
        try d.w.writeAll("  type params");
        for (d.bir.declTypeParams(decl_)) |p| try d.w.print(" {s}", .{d.names.text(p)});
        try d.w.writeByte('\n');
    }

    /// `pub opaque type Token (foreign)` — the declaration's own line.
    fn header(d: *Dumper, decl_: Bir.Decl) !void {
        if (decl_.is_pub) try d.w.writeAll("pub ");
        if (decl_.is_opaque) try d.w.writeAll("opaque ");
        if (decl_.is_equatable) try d.w.writeAll("equatable ");
        try d.w.print("{s} ", .{kindText(decl_.kind)});
        // The rung a `foreign` value declares (transparent-effects-proposal.md §14.1).
        if (decl_.kind == .foreign_value) try d.w.print("{t} ", .{decl_.rung});
        try d.declHeading(decl_);
        if (decl_.kind == .value and decl_.annotation != .none) try d.w.writeAll(" (annotated)");
    }

    /// A declaration's name; an element's, attribute's or event's in quotes,
    /// since it is the text of a string and need not be an identifier.
    fn declHeading(d: *Dumper, decl_: Bir.Decl) !void {
        switch (decl_.kind) {
            .vocab_element, .vocab_attribute, .vocab_event => try d.quoted(d.sym(decl_.name)),
            else => try d.w.writeAll(d.sym(decl_.name)),
        }
    }

    /// The interface skeleton's view of a `pub` declaration.
    fn interfaceEntry(d: *Dumper, decl_: Bir.Decl) !void {
        switch (decl_.kind) {
            .value, .annotation_only => {
                try d.w.print("value {s}", .{d.sym(decl_.name)});
                if (decl_.annotation != .none) try d.w.writeAll(" (annotated)");
            },
            .foreign_value => try d.w.print("foreign value {s}", .{d.sym(decl_.name)}),
            .type => {
                if (decl_.is_opaque) {
                    try d.w.print("opaque type {s}", .{d.sym(decl_.name)});
                } else {
                    try d.w.print("type {s} =", .{d.sym(decl_.name)});
                    for (d.bir.declCtors(decl_), 0..) |c, i| {
                        try d.w.print("{s}{s}", .{ if (i == 0) " " else " | ", d.sym(c.name) });
                    }
                }
            },
            .type_alias => {
                try d.w.print("alias {s}", .{d.sym(decl_.name)});
                if (decl_.ctors_end > decl_.ctors_start) try d.w.writeAll(" (record constructor)");
            },
            .foreign_type => {
                try d.w.print("foreign type {s}", .{d.sym(decl_.name)});
                if (decl_.is_equatable) try d.w.writeAll(" (equatable)");
            },
            .schema => try d.w.print("schema {s}", .{d.sym(decl_.name)}),
            .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => {
                try d.w.print("{s} ", .{kindText(decl_.kind)});
                try d.declHeading(decl_);
            },
        }
    }

    fn interface(d: *Dumper) !void {
        try d.w.writeAll("interface\n");
        for (d.bir.interface) |di| {
            try d.w.writeAll("  ");
            try d.interfaceEntry(d.bir.decl(di));
            try d.w.writeByte('\n');
        }
    }

    fn imports(d: *Dumper) !void {
        try d.w.writeAll("imports\n");
        for (d.bir.imports) |imp| {
            if (imp.prelude) {
                try d.w.print("  prelude {s}\n", .{d.sym(imp.module)});
                continue;
            }
            try d.w.print("  import {s}", .{d.sym(imp.module)});
            if (imp.alias != imp.module) try d.w.print(" as {s}", .{d.sym(imp.alias)});
            const exposed = d.bir.importExposed(imp);
            if (exposed.len != 0) {
                try d.w.writeAll(" exposing (");
                for (exposed, 0..) |e, i| {
                    if (i != 0) try d.w.writeAll(", ");
                    try d.w.writeAll(d.sym(e.name));
                }
                try d.w.writeByte(')');
            }
            try d.w.writeByte('\n');
        }
    }

    fn writeInst(d: *Dumper, i: Index) std.Io.Writer.Error!void {
        const bir = d.bir;
        const tag = bir.instTag(i);
        const data = bir.instData(i);
        try d.w.print("{t}", .{tag});
        switch (tag) {
            .local => {
                try d.w.writeByte(' ');
                try d.local(data.lhs, false);
            },
            .top, .type_top => try d.w.print(" {d} ({s})", .{ data.lhs, d.declName(data.lhs) }),
            .ctor => try d.w.print(" {d} ({s})", .{ data.lhs, d.ctorName(data.lhs) }),
            .import_value, .import_ctor, .type_import => {
                try d.w.writeByte(' ');
                try d.moduleName(data.lhs, data.rhs, false);
            },
            // `dump --stage=bir` runs before resolution, so these never
            // appear in its output; printed as the pair of indices they
            // are so a future dump of a resolved module is still legible.
            .ext_value, .ext_ctor, .ext_type => try d.w.print(" module {d} #{d}", .{ data.lhs, data.rhs }),
            .schema_member_top, .schema_ctor_top, .schema_type_top, .schema_target_top => try d.w.print(" decl {d} #{d}", .{ data.lhs, data.rhs }),
            .ext_schema_member, .ext_schema_ctor, .ext_schema_type, .ext_schema_target => try d.w.print(" module {d} #{d}", .{ data.lhs, data.rhs }),
            .qualified, .qualified_ctor, .type_qualified => {
                try d.w.writeByte(' ');
                try d.moduleName(data.lhs, data.rhs, true);
            },
            .type_var => {
                const info = Bir.TypeVarInfo.unpack(data.rhs);
                try d.w.print(" {s}", .{d.symRaw(data.lhs)});
                if (info.param != Bir.TypeVarInfo.param_none) try d.w.print(" (param {d})", .{info.param});
                if (info.equatable) try d.w.writeAll(" (equatable)");
            },
            .schema_ref, .schema_expr_ref, .schema_type_ref, .schema_value_ref, .schema_ctor_ref => try d.w.print(" {s}", .{d.symRaw(data.lhs)}),
            .schema_parameter => try d.w.print(" param {d}", .{data.lhs}),
            .schema_primitive => try d.w.print(" {t}", .{@as(Bir.SchemaPrimitive, @enumFromInt(data.lhs))}),
            .schema_app => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeByte(' ');
                try d.refList(bir.subRange(@enumFromInt(data.rhs)));
            },
            .schema_paren, .schema_as, .schema_via => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
            },
            .schema_record => {
                try d.w.writeByte(' ');
                try d.refList(Bir.inlineRange(data));
            },
            .schema_field => {
                const field = bir.extraData(@enumFromInt(data.rhs), Bir.SchemaField);
                try d.w.print(" {s} : ", .{d.symRaw(data.lhs)});
                try d.refIndex(field.operand);
                try d.w.writeByte(' ');
                try d.refList(.{ .start = field.modifiers_start, .end = field.modifiers_end });
                const field_docs = if (field.doc_start <= field.doc_end and field.doc_end <= d.comments.len)
                    d.comments[field.doc_start..field.doc_end]
                else
                    &.{};
                for (field_docs) |comment| {
                    if (comment.kind != .doc) continue;
                    const line_end = Tokenizer.tokenEnd(d.source, .multiline_line, comment.start);
                    var body = d.source[comment.start + 3 .. line_end];
                    if (body.len > 0 and body[0] == ' ') body = body[1..];
                    try d.w.writeAll(" doc ");
                    try d.quoted(body);
                }
            },
            .schema_value => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeByte(' ');
                try d.refList(bir.subRange(@enumFromInt(data.rhs)));
            },
            .schema_tagged => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeByte(' ');
                try d.refList(bir.subRange(@enumFromInt(data.rhs)));
            },
            .schema_variant => {
                const variant = bir.extraData(@enumFromInt(data.rhs), Bir.SchemaVariant);
                try d.w.print(" {s}", .{d.symRaw(data.lhs)});
                if (variant.payload.unwrap()) |payload| {
                    try d.w.writeByte(' ');
                    try d.refIndex(payload);
                }
                if (variant.rename.unwrap()) |rename| {
                    try d.w.writeAll(" as ");
                    try d.refIndex(rename);
                }
            },
            .schema_optional, .schema_nullable => {},
            .type_app => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeByte(' ');
                try d.refList(bir.subRange(@enumFromInt(data.rhs)));
            },
            .type_fn => {
                try d.w.writeByte(' ');
                try d.refList(bir.subRange(@enumFromInt(data.lhs)));
                try d.w.writeAll(" -> ");
                try d.ref(data.rhs);
            },
            .type_unit, .unit, .pat_wild, .pat_unit => {},
            .type_tuple, .tuple, .list, .interp, .pat_tuple, .pat_list => {
                try d.w.writeByte(' ');
                try d.refList(Bir.inlineRange(data));
            },
            .type_record => {
                try d.w.writeByte(' ');
                try d.fieldList(Bir.inlineRange(data), " : ");
            },
            .type_record_ext => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeByte(' ');
                try d.fieldList(bir.subRange(@enumFromInt(data.rhs)), " : ");
            },
            .int, .float, .pat_int => try d.w.print(" {s}", .{bir.bytes(i)}),
            .char, .pat_char => {
                try d.w.writeByte(' ');
                try d.char(data.lhs);
            },
            .string, .chunk, .pat_string => {
                try d.w.writeByte(' ');
                try d.quoted(bir.bytes(i));
            },
            .record => {
                try d.w.writeByte(' ');
                try d.fieldList(Bir.inlineRange(data), " = ");
            },
            .record_update => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeByte(' ');
                try d.fieldList(bir.subRange(@enumFromInt(data.rhs)), " = ");
            },
            .field_access => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.print(" .{s}", .{d.symRaw(data.rhs)});
            },
            .tuple_index => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.print(" .{d}", .{data.rhs});
            },
            .call => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeByte(' ');
                try d.refList(bir.subRange(@enumFromInt(data.rhs)));
            },
            // `method_call %0 .insert [%1, %2]`, and for one of the six
            // operators the form it was written as: `method_call %0 .eq
            // [%1] (==)` (static-dispatch-spike.md §1.3, §3.1).
            .method_call => {
                const m = bir.extraData(@enumFromInt(data.rhs), Bir.MethodCall);
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.print(" .{s} ", .{d.sym(m.name)});
                try d.refList(.{ .start = m.args_start, .end = m.args_end });
                if (m.origin.spelling()) |op| try d.w.print(" ({s})", .{op});
            },
            .type_dispatch => {
                const t = bir.extraData(@enumFromInt(data.rhs), Bir.TypeDispatch);
                try d.w.print(" {s}.{s} ", .{ d.symRaw(data.lhs), d.sym(t.name) });
                try d.refList(.{ .start = t.args_start, .end = t.args_end });
            },
            .lambda => {
                try d.w.writeByte(' ');
                try d.refList(bir.subRange(@enumFromInt(data.lhs)));
                try d.w.writeAll(" -> ");
                try d.ref(data.rhs);
            },
            .let => {
                try d.w.writeByte(' ');
                try d.refList(bir.subRange(@enumFromInt(data.lhs)));
                try d.w.writeAll(" in ");
                try d.ref(data.rhs);
            },
            .let_def => {
                const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
                try d.w.writeByte(' ');
                try d.local(def.local, true);
                if (def.annotation.unwrap()) |a| {
                    try d.w.writeAll(" : ");
                    try d.refIndex(a);
                }
                try d.w.writeByte(' ');
                try d.refList(.{ .start = def.params_start, .end = def.params_end });
                try d.w.writeAll(" = ");
                try d.ref(data.rhs);
            },
            .let_pattern => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeAll(" = ");
                try d.ref(data.rhs);
            },
            .case => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeByte(' ');
                try d.refList(bir.subRange(@enumFromInt(data.rhs)));
            },
            .branch => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeAll(" -> ");
                try d.ref(data.rhs);
            },
            .@"try" => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                const target: Inst.OptionalIndex = @enumFromInt(data.rhs);
                if (target.unwrap()) |t| {
                    try d.w.writeAll(" (returns from let_def ");
                    try d.refIndex(t);
                    try d.w.writeByte(')');
                } else {
                    try d.w.writeAll(" (returns from the declaration)");
                }
            },
            .pat_var => {
                try d.w.writeByte(' ');
                try d.local(data.lhs, true);
            },
            .pat_ctor => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeByte(' ');
                try d.refList(bir.subRange(@enumFromInt(data.rhs)));
            },
            .pat_cons => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeAll(" :: ");
                try d.ref(data.rhs);
            },
            .pat_record => {
                try d.w.writeAll(" [");
                for (bir.extraSlice(Bir.inlineRange(data), u32), 0..) |li, k| {
                    if (k != 0) try d.w.writeAll(", ");
                    try d.local(li, true);
                }
                try d.w.writeByte(']');
            },
            .pat_as => {
                try d.w.writeByte(' ');
                try d.ref(data.lhs);
                try d.w.writeAll(" as ");
                try d.local(data.rhs, true);
            },
            .pat_spread => {
                try d.w.writeAll(" ...");
                try d.ref(data.lhs);
            },
            .@"error" => {
                const code: @import("diagnostic").Code = @enumFromInt(data.lhs);
                try d.w.print(" {t}", .{code});
            },
            .markup => try d.markupNode(@enumFromInt(data.lhs), 4),
        }
    }

    // ---- Markup trees (frontend.md §9.7) ----------------------------------
    //
    // The tree of a `markup` instruction follows its line, one node per
    // line, each level two spaces further in: its items, then its children.

    fn line(d: *Dumper, indent: usize) !void {
        try d.w.writeByte('\n');
        try d.w.splatByteAll(' ', indent);
    }

    fn markupNode(d: *Dumper, at: Bir.ExtraIndex, indent: usize) std.Io.Writer.Error!void {
        const bir = d.bir;
        try d.line(indent);
        switch (bir.markupKind(at)) {
            .element => {
                const e = bir.extraData(at, Bir.MarkupElement);
                try d.w.print("element {s}", .{d.sym(e.name)});
                try d.items(e.items_start, e.items_end, indent + 2);
                try d.markupChildren(e.children_start, e.children_end, indent + 2);
            },
            .fragment => {
                const f = bir.extraData(at, Bir.MarkupFragment);
                try d.w.writeAll("fragment");
                try d.markupChildren(f.children_start, f.children_end, indent + 2);
            },
            .text => {
                try d.w.writeAll("text ");
                try d.quoted(d.sym(bir.extraData(at, Bir.MarkupText).text));
            },
            .hole => {
                try d.w.writeAll("hole ");
                try d.refIndex(bir.extraData(at, Bir.MarkupHole).value);
            },
            .component => {
                const c = bir.extraData(at, Bir.MarkupComponent);
                try d.w.writeAll("component ");
                try d.refIndex(c.callee);
                if (c.spread.unwrap()) |s| {
                    try d.line(indent + 2);
                    try d.w.writeAll("spread ");
                    try d.refIndex(s);
                }
                try d.items(c.props_start, c.props_end, indent + 2);
                if (c.children_form != .absent) {
                    try d.line(indent + 2);
                    try d.w.print("children {t}", .{c.children_form});
                    try d.markupChildren(c.children_start, c.children_end, indent + 4);
                }
            },
            .@"for", .show => {
                const f = bir.extraData(at, Bir.MarkupForm);
                const is_for = bir.markupKind(at) == .@"for";
                try d.w.writeAll(if (is_for) "for" else "show");
                if (f.list.unwrap()) |v| {
                    try d.w.writeAll(if (is_for) " each " else " when ");
                    try d.refIndex(v);
                }
                switch (f.mode) {
                    .absent => {},
                    .key_function => {
                        try d.w.writeAll(" keyed key ");
                        try d.refIndex(f.keyed.unwrap().?);
                    },
                    .literal_true => try d.w.writeAll(" keyed True"),
                    .literal_false => try d.w.writeAll(" keyed False"),
                }
                if (f.fallback.unwrap()) |v| {
                    try d.w.writeAll(" fallback ");
                    try d.refIndex(v);
                }
                if (f.row != Bir.none_extra) try d.row(bir.extraData(@enumFromInt(f.row), Bir.MarkupRow), indent + 2);
            },
        }
    }

    fn markupChildren(d: *Dumper, start: Bir.ExtraIndex, end: Bir.ExtraIndex, indent: usize) !void {
        for (d.bir.extraSlice(.{ .start = start, .end = end }, Bir.ExtraIndex)) |c| try d.markupNode(c, indent);
    }

    /// `attr class = "row"`, `attr id = %1`, `attr tabindex = %2 (constant 0)`,
    /// `attr class = %6 entries ["row" = True, "danger" = %5]`,
    /// `escape "hx-get" = %3`.
    fn items(d: *Dumper, start: Bir.ExtraIndex, end: Bir.ExtraIndex, indent: usize) !void {
        const bir = d.bir;
        for (bir.extraSlice(.{ .start = start, .end = end }, Bir.ExtraIndex)) |at| {
            const item = bir.extraData(at, Bir.MarkupItem);
            try d.line(indent);
            switch (item.kind) {
                .attr => try d.w.print("attr {s} = ", .{d.sym(item.name)}),
                .escape => {
                    try d.w.writeAll("escape ");
                    try d.quoted(d.sym(item.name));
                    try d.w.writeAll(" = ");
                },
                .spread => try d.w.writeAll("spread "),
            }
            if (item.value.unwrap()) |v| {
                try d.refIndex(v);
                if (item.constant != .none) {
                    try d.w.writeAll(" (constant ");
                    try d.constant(item.constant, item.constant_offset, item.constant_len);
                    try d.w.writeByte(')');
                }
            } else try d.constant(item.constant, item.constant_offset, item.constant_len);
            const entries = bir.extraSlice(.{ .start = item.entries_start, .end = item.entries_end }, Bir.ExtraIndex);
            if (entries.len != 0) {
                try d.w.writeAll(" entries [");
                for (entries, 0..) |e_at, k| {
                    const e = bir.extraData(e_at, Bir.MarkupEntry);
                    if (k != 0) try d.w.writeAll(", ");
                    try d.quoted(bir.string_bytes[e.name_offset..][0..e.name_len]);
                    try d.w.writeAll(" = ");
                    if (e.constant != .none) {
                        try d.constant(e.constant, e.constant_offset, e.constant_len);
                    } else try d.refIndex(e.value);
                }
                try d.w.writeByte(']');
            }
        }
    }

    fn constant(d: *Dumper, c: Bir.Constant, offset: u32, len: u32) !void {
        switch (c) {
            .none => try d.w.writeAll("?"),
            .string => try d.quoted(d.bir.string_bytes[offset..][0..len]),
            .number => try d.w.writeAll(d.bir.string_bytes[offset..][0..len]),
            .true => try d.w.writeAll("True"),
            .false => try d.w.writeAll("False"),
        }
    }

    /// `row lambda %9 captures [0 (model)] inputs [model.selected, x]`, and
    /// for a row compiled in place its markup and the `let`s peeled off it.
    fn row(d: *Dumper, r: Bir.MarkupRow, indent: usize) !void {
        const bir = d.bir;
        try d.line(indent);
        try d.w.print("row {t} ", .{r.shape});
        try d.refIndex(r.function);
        if (r.body.unwrap()) |b| {
            try d.w.writeAll(" body ");
            try d.refIndex(b);
        }
        const lets: Bir.SubRange = .{ .start = r.lets_start, .end = r.lets_end };
        if (lets.len() != 0) {
            try d.w.writeAll(" lets ");
            try d.refList(lets);
        }
        if (r.shape == .function) return;
        try d.w.writeAll(" captures [");
        for (bir.extraSlice(.{ .start = r.captures_start, .end = r.captures_end }, u32), 0..) |captured, k| {
            if (k != 0) try d.w.writeAll(", ");
            try d.local(captured, false);
        }
        try d.w.writeAll("] inputs [");
        var at = @intFromEnum(r.inputs_start);
        var k: usize = 0;
        while (at < @intFromEnum(r.inputs_end)) : (at += Bir.extraLen(Bir.MarkupInput)) {
            const input = bir.extraData(@enumFromInt(at), Bir.MarkupInput);
            if (k != 0) try d.w.writeAll(", ");
            k += 1;
            const name = d.locals[input.local].name;
            try d.w.writeAll(if (name.unwrap()) |_| d.sym(name) else "_");
            for (0..input.len) |n| {
                const link = input.link(n);
                if (link & Bir.tuple_link != 0) {
                    try d.w.print(".{d}", .{link & ~Bir.tuple_link});
                } else try d.w.print(".{s}", .{d.symRaw(link)});
            }
        }
        try d.w.writeByte(']');
    }
};
