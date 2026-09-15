//! The abstract syntax tree (docs/design/frontend.md §3.5, language.md §3).
//!
//! Shaped like `std.zig.Ast`: one `MultiArrayList` of fixed-size nodes —
//! a tag, a main token and two `u32`s — plus one shared `extra` sidecar for
//! everything variable-length, plus the parse errors in source order. There
//! is no pointer and no slice into the source anywhere in it: every
//! reference is a `u32` index into `nodes`, `extra`, the token list or the
//! comment list, so the whole thing is three flat arrays that copy, cache
//! and (in M4) mmap without a fixup pass.
//!
//! The tree is LOSSLESS together with the token and comment arrays and the
//! line-start table: every construct keeps a node, including grouping
//! parentheses (`paren`, `type_paren`, `pat_paren`) which lowering ignores
//! but the formatter and the AST dump need in order to reflect the source.
//!
//! The tree is always STRUCTURALLY COMPLETE, errors or not (fast-compiler.md
//! §5): a syntax error produces an `error_*` placeholder node where the
//! missing construct would be, every list is closed, every `case` has a
//! branch list, so downstream passes treat a broken file like any other and
//! `beni dump --stage=ast` can show what the parser made of it.
//!
//! What `Data.lhs`/`Data.rhs` mean is documented per tag on `Node.Tag`,
//! and — like `std.zig.Ast.full*` — every composite kind has a typed
//! accessor view (`fullDefinition`, `fullIf`, …) so nobody decodes the two
//! words by hand. Ranges (`SubRange`) are half-open `[start, end)` index
//! pairs into `extra`; `extraData` reads a named struct out of `extra` the
//! way `std.zig.Ast.extraData` does.
//!
//! Doc comments (language.md §2.3) are not in the tree: they stay in the
//! comment array, and each declaration's header records the RANGE of
//! comment indices attached to it (`DeclHeader.doc_start..doc_end`), with
//! the module doc's range on the `Ast` itself. Attachment is a syntactic
//! fact decided by the parser, which is why its two diagnostics are parse
//! errors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("../lex/Token.zig");
const Diagnostics = @import("Diagnostics.zig");

const Ast = @This();

/// Owned. `nodes[0]` is always `root`.
nodes: NodeList.Slice,
/// Owned. Ranges and multi-word payloads, indexed from node data.
extra: []const u32,
/// Owned. Parse diagnostics in source order (of their start offset), each
/// with the payload `Diagnostics.message` needs.
errors: []const Diagnostics.Item,
/// Comment indices `[start, end)` of the `--!` block(s) attached to the
/// module; plain comments inside the range are trivia and are skipped by
/// consumers. Empty when `start == end`.
module_doc: CommentRange,

pub const NodeList = std.MultiArrayList(Node);
pub const TokenIndex = u32;

/// A half-open range of comment indices.
pub const CommentRange = struct {
    start: u32,
    end: u32,

    pub const empty: CommentRange = .{ .start = 0, .end = 0 };
};

/// Index into `extra`.
pub const ExtraIndex = enum(u32) {
    _,
};

/// A half-open range `[start, end)` of `extra`, whose elements are `u32`
/// values of a kind the owning tag documents (node indices unless stated).
pub const SubRange = struct {
    start: ExtraIndex,
    end: ExtraIndex,

    pub fn len(r: SubRange) u32 {
        return @intFromEnum(r.end) - @intFromEnum(r.start);
    }
};

/// Index into the token list, or null.
pub const OptionalTokenIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(i: OptionalTokenIndex) ?TokenIndex {
        return if (i == .none) null else @intFromEnum(i);
    }

    pub fn fromToken(t: TokenIndex) OptionalTokenIndex {
        return @enumFromInt(t);
    }
};

pub const Node = struct {
    tag: Tag,
    /// The token that best identifies the node: the literal or identifier
    /// for leaves, the operator for binary operators, the opening bracket
    /// for bracketed forms, the keyword for `if`/`let`/`case`, the name for
    /// declarations. Documented per tag.
    main_token: TokenIndex,
    data: Data,

    /// Meaning depends on `tag`; see `Tag`. `unused` fields are zero.
    pub const Data = struct {
        lhs: u32,
        rhs: u32,

        pub const unused: u32 = 0;
    };

    /// Index into `nodes`.
    pub const Index = enum(u32) {
        root = 0,
        _,

        pub fn toOptional(i: Index) OptionalIndex {
            const result: OptionalIndex = @enumFromInt(@intFromEnum(i));
            std.debug.assert(result != .none);
            return result;
        }

        pub fn int(i: Index) u32 {
            return @intFromEnum(i);
        }
    };

    /// Index into `nodes`, or null.
    pub const OptionalIndex = enum(u32) {
        root = 0,
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(i: OptionalIndex) ?Index {
            return if (i == .none) null else @enumFromInt(@intFromEnum(i));
        }
    };

    comptime {
        std.debug.assert(@sizeOf(Tag) == 1);
        std.debug.assert(@sizeOf(Data) == 8);
    }

    /// Every production of language.md §3. The comment on each tag states
    /// what `main_token`, `lhs` and `rhs` hold.
    pub const Tag = enum(u8) {
        // ---- Module ----------------------------------------------------

        /// The whole file. `main_token` is token 0. `lhs..rhs` is the
        /// `SubRange` of top-level nodes — `import`s and declarations, in
        /// source order (an `import` after a declaration is kept in place
        /// and reported).
        root,
        /// `import Json.Decode as D exposing (Decoder, string)`.
        /// `main_token` is `import`; `lhs` is the `ExtraIndex` of an
        /// `Import`; `rhs` unused.
        import,
        /// One name in an `exposing` list. `main_token` is the identifier
        /// (lower or upper); data unused.
        exposed,

        // ---- Declarations ----------------------------------------------
        //
        // Every declaration's `lhs` is the `ExtraIndex` of a struct that
        // BEGINS with `DeclHeader` (visibility tokens and the doc-comment
        // range), so `declHeader` works on any of them. `main_token` is the
        // declared name; the keywords in front of it (`type`, `alias`,
        // `foreign`) are the immediately preceding tokens.

        /// `name : Type`. `lhs` is the `ExtraIndex` of a `DeclHeader`;
        /// `rhs` is the type node.
        annotation,
        /// `name PatAtom* = Expr`. `lhs` is the `ExtraIndex` of a
        /// `Definition` (header, then the parameter pattern range); `rhs`
        /// is the body expression.
        definition,
        /// `type alias Name a b = Type`. `lhs` is the `ExtraIndex` of a
        /// `TypeAlias` (header, then the parameter token range); `rhs` is
        /// the body type.
        type_alias,
        /// `type Name a = A | B a`. `lhs` is the `ExtraIndex` of a
        /// `TypeDecl` (header, parameter token range, constructor node
        /// range); `rhs` unused.
        type_decl,
        /// One constructor of a `type`. `main_token` is the upper
        /// identifier; `lhs..rhs` is the `SubRange` of argument type nodes.
        constructor,
        /// `foreign name : Type` (language.md §5.4). `lhs` is the
        /// `ExtraIndex` of a `DeclHeader`; `rhs` is the type node.
        foreign_value,
        /// `foreign type Name a b`. `lhs` is the `ExtraIndex` of a
        /// `ForeignType` (header, then the parameter token range); `rhs`
        /// unused.
        foreign_type,

        // ---- Types -----------------------------------------------------

        /// A type variable. `main_token` is the lower identifier; `lhs` is
        /// the `OptionalTokenIndex` of an `equatable` marker written in
        /// front of it (checker.md Appendix A/B, core only), `none`
        /// otherwise. `rhs` unused.
        type_var,
        /// A named type, applied to zero or more atoms: `Int`, `Maybe a`,
        /// `Dict.Dict k v`. `main_token` is the upper or qualified upper
        /// identifier; `lhs..rhs` is the `SubRange` of argument type nodes.
        type_con,
        /// `a -> b`, right associative. `main_token` is the arrow; `lhs`
        /// is the parameter type, `rhs` the result type.
        type_fn,
        /// `()`. `main_token` is `(`.
        type_unit,
        /// `( Type )`, grouping. `main_token` is `(`; `lhs` is the inner
        /// type.
        type_paren,
        /// `( a, b )`, arity ≥ 2. `main_token` is `(`; `lhs..rhs` is the
        /// `SubRange` of element types.
        type_tuple,
        /// `{}` or `{ x : Int, y : Int }`. `main_token` is `{`; `lhs..rhs`
        /// is the `SubRange` of `record_type_field` nodes.
        type_record,
        /// `{ r | x : Int }`. `main_token` is `{`; `lhs` is the base
        /// variable's token; `rhs` is the `ExtraIndex` of a `SubRange` of
        /// `record_type_field` nodes.
        type_record_ext,
        /// `x : Int` inside a record type. `main_token` is the field name;
        /// `lhs` is the type.
        record_type_field,

        // ---- Expressions: leaves ---------------------------------------

        /// `main_token` is the literal.
        int,
        /// `main_token` is the literal.
        float,
        /// `main_token` is the literal.
        char,
        /// `"chunk ${expr} chunk"`. `main_token` is `str_start`; `lhs..rhs`
        /// is the `SubRange` of parts, each a `chunk` or an `interp`. An
        /// empty string has an empty range.
        string,
        /// A run of literal text inside a string. `main_token` is the
        /// `str_chunk`.
        chunk,
        /// `${ expr }` inside a string. `main_token` is `interp_start`;
        /// `lhs` is the expression.
        interp,
        /// One or more consecutive `\\` lines (language.md §2.7).
        /// `main_token` is the first `multiline_line`; `lhs` is the last
        /// one (the lines are the consecutive tokens between them).
        multiline_string,
        /// A value name, `x` or `List.map`. `main_token` is the identifier.
        ident,
        /// A constructor, `Just` or `Maybe.Just`. `main_token` is the
        /// identifier.
        ctor,
        /// `.field` as a function. `main_token` is the `dot_lower`.
        accessor,
        /// `(+)` — an operator as a function. `main_token` is the operator
        /// token (the parentheses are the neighbouring tokens).
        op_fn,
        /// `()`. `main_token` is `(`.
        unit,

        // ---- Expressions: composite ------------------------------------

        /// `-x`. `main_token` is `-`; `lhs` is the operand.
        negate,
        /// `( e )`, grouping. `main_token` is `(`; `lhs` is the inner
        /// expression.
        paren,
        /// `( a, b )`, arity ≥ 2. `main_token` is `(`; `lhs..rhs` is the
        /// `SubRange` of elements.
        tuple,
        /// `[ a, b ]`. `main_token` is `[`; `lhs..rhs` is the `SubRange` of
        /// elements.
        list,
        /// `{ a = 1 }`. `main_token` is `{`; `lhs..rhs` is the `SubRange` of
        /// `field` nodes.
        record,
        /// `{ r | a = 1 }`. `main_token` is `{`; `lhs` is the base name's
        /// token; `rhs` is the `ExtraIndex` of a `SubRange` of `field`
        /// nodes.
        record_update,
        /// `a = expr` inside a record. `main_token` is the field name;
        /// `lhs` is the value.
        field,
        /// `e.name`. `main_token` is the `dot_lower`; `lhs` is the target.
        field_access,
        /// `e.0`. `main_token` is the `dot_index`; `lhs` is the target.
        tuple_index,
        /// `f a b`. `main_token` is the function's first token; `lhs..rhs`
        /// is the `SubRange` whose element 0 is the function and whose
        /// remaining elements are the arguments (at least one).
        apply,
        /// `e?`. `main_token` is `?`; `lhs` is the operand.
        question,
        /// `_` in argument position of an `apply` (language.md §6.7): the
        /// argument the call does not supply, which lowering turns into a
        /// lambda over the innermost enclosing application. `main_token` is
        /// `_`; data unused. Anywhere else a `_` is a pattern, or
        /// `placeholder_outside_argument`.
        placeholder,

        // Binary operators (language.md §6.5): `main_token` is the
        // operator; `lhs` and `rhs` are the operands.

        /// `+`
        add,
        /// `-`
        sub,
        /// `*`
        mul,
        /// `/`
        div,
        /// `//`
        int_div,
        /// `^`
        pow,
        /// `++`
        append,
        /// `::`
        cons,
        /// `==`
        eq,
        /// `/=`
        neq,
        /// `<`
        lt,
        /// `>`
        gt,
        /// `<=`
        lte,
        /// `>=`
        gte,
        /// `&&`
        bool_and,
        /// `||`
        bool_or,
        /// `<|`
        pipe_left,
        /// `|>`
        pipe_right,

        /// `\a b -> e`. `main_token` is `\`; `lhs` is the `ExtraIndex` of
        /// a `SubRange` of parameter patterns; `rhs` is the body.
        lambda,
        /// `if c then a else b`. `main_token` is `if`; `lhs` is the
        /// condition; `rhs` is the `ExtraIndex` of an `If`.
        @"if",
        /// `let … in e`. `main_token` is `let`; `lhs` is the `ExtraIndex`
        /// of a `SubRange` of binding nodes (`let_def`, `let_annotation`,
        /// `let_pattern`); `rhs` is the body.
        let,
        /// `name PatAtom* = Expr` in a `let`. `main_token` is the name;
        /// `lhs` is the `ExtraIndex` of a `SubRange` of parameter patterns;
        /// `rhs` is the body.
        let_def,
        /// `name : Type` in a `let`. `main_token` is the name; `lhs` is the
        /// type.
        let_annotation,
        /// `( a, b ) = Expr` in a `let`. `main_token` is the pattern's first
        /// token; `lhs` is the pattern; `rhs` is the expression.
        let_pattern,
        /// `x <- f a` in a `let` (language.md §6.7): the rest-of-block bind,
        /// whose `rest` — the bindings after it and the `in` body — becomes
        /// the last argument of `f a`. `main_token` is the pattern's first
        /// token; `lhs` is the pattern; `rhs` is the application.
        let_bind,
        /// `case e of branches`. `main_token` is `case`; `lhs` is the
        /// scrutinee; `rhs` is the `ExtraIndex` of a `SubRange` of `branch`
        /// nodes (at least one, an `error_branch` if none was written).
        case,
        /// `Pattern -> Expr`. `main_token` is the pattern's first token;
        /// `lhs` is the pattern; `rhs` is the body.
        branch,

        // ---- Patterns --------------------------------------------------

        /// `_`. `main_token` is `_`.
        pat_wild,
        /// A variable. `main_token` is the lower identifier.
        pat_var,
        /// `Just x`, `Maybe.Just x`, or a nullary `Nothing`. `main_token`
        /// is the constructor; `lhs..rhs` is the `SubRange` of argument
        /// patterns.
        pat_ctor,
        /// `main_token` is the literal.
        pat_int,
        /// `-1`. `main_token` is `-`; the literal is the next token.
        pat_neg_int,
        /// `main_token` is the literal.
        pat_char,
        /// A string without interpolation. `main_token` is `str_start`; the
        /// tokens up to the matching `str_end` are the content.
        pat_string,
        /// `()`. `main_token` is `(`.
        pat_unit,
        /// `( p )`, grouping. `main_token` is `(`; `lhs` is the inner
        /// pattern.
        pat_paren,
        /// `( a, b )`. `main_token` is `(`; `lhs..rhs` is the `SubRange` of
        /// element patterns.
        pat_tuple,
        /// `[ a, b ]`. `main_token` is `[`; `lhs..rhs` is the `SubRange` of
        /// element patterns.
        pat_list,
        /// `{ a, b }`. `main_token` is `{`; `lhs..rhs` is the `SubRange` of
        /// field name TOKENS (not nodes).
        pat_record,
        /// `x :: xs`, right associative. `main_token` is `::`; `lhs` is the
        /// head, `rhs` the tail.
        pat_cons,
        /// `p as name`. `main_token` is `as`; `lhs` is the pattern; `rhs`
        /// is the name's token.
        pat_as,

        // ---- Error placeholders ----------------------------------------
        //
        // Where a construct was required and could not be parsed. `main_token`
        // is the token at which the error was detected; `lhs` is the
        // `@intFromEnum` of the `diagnostic.Code`; `rhs` is the index into
        // `errors` of the diagnostic, or `maxInt(u32)` when it was not
        // reported (the token came from the lexer already reported, or the
        // parser was resynchronising).

        error_decl,
        error_exposed,
        error_type,
        error_expr,
        error_pattern,
        error_constructor,
        error_binding,
        error_branch,
        error_field,

        pub fn isError(tag: Tag) bool {
            return @intFromEnum(tag) >= @intFromEnum(Tag.error_decl);
        }

        pub fn isBinop(tag: Tag) bool {
            return @intFromEnum(tag) >= @intFromEnum(Tag.add) and @intFromEnum(tag) <= @intFromEnum(Tag.pipe_right);
        }

        pub fn isDecl(tag: Tag) bool {
            return switch (tag) {
                .annotation, .definition, .type_alias, .type_decl, .foreign_value, .foreign_type => true,
                else => false,
            };
        }

        /// The node tag for a binary operator token, or null.
        pub fn fromOperator(token: Token.Tag) ?Tag {
            return switch (token) {
                .op_plus => .add,
                .op_minus => .sub,
                .op_star => .mul,
                .op_slash => .div,
                .op_slash_slash => .int_div,
                .op_caret => .pow,
                .op_plus_plus => .append,
                .op_colon_colon => .cons,
                .op_eq_eq => .eq,
                .op_slash_eq => .neq,
                .op_lt => .lt,
                .op_gt => .gt,
                .op_lte => .lte,
                .op_gte => .gte,
                .op_and_and => .bool_and,
                .op_or_or => .bool_or,
                .op_pipe_left => .pipe_left,
                .op_pipe_right => .pipe_right,
                else => null,
            };
        }
    };
};

// ---------------------------------------------------------------------------
// Extra-data records. Every field is a u32-sized enum or integer so
// `extraData` can read them back positionally.
// ---------------------------------------------------------------------------

/// The front of every declaration's extra record.
pub const DeclHeader = struct {
    /// The `pub` token, if any.
    pub_token: OptionalTokenIndex,
    /// The `opaque` token, if any (legal only on `type_decl`; kept on the
    /// others so the misuse is visible to the formatter).
    opaque_token: OptionalTokenIndex,
    /// The `equatable` token, if any: `pub equatable foreign type List a`
    /// (checker.md Appendix A/B). The grammar allows it only directly
    /// before `foreign type`; whether the file may write it at all is a
    /// package fact lowering decides (`equatable_outside_core`).
    equatable_token: OptionalTokenIndex,
    /// Comment indices `[doc_start, doc_end)` of the attached `--|` block.
    doc_start: u32,
    doc_end: u32,

    pub const none: DeclHeader = .{ .pub_token = .none, .opaque_token = .none, .equatable_token = .none, .doc_start = 0, .doc_end = 0 };

    pub fn docs(h: DeclHeader) CommentRange {
        return .{ .start = h.doc_start, .end = h.doc_end };
    }
};

pub const Import = struct {
    /// The module path token (`upper_ident` or `qualified_upper`), or none
    /// when it was missing.
    name: OptionalTokenIndex,
    /// The `as` alias token, if any.
    alias: OptionalTokenIndex,
    /// `SubRange` of `exposed` nodes; empty with no `exposing`. Whether
    /// `exposing` was written at all is `exposing_token`.
    exposed_start: ExtraIndex,
    exposed_end: ExtraIndex,
    exposing_token: OptionalTokenIndex,
};

pub const Definition = struct {
    header: DeclHeader,
    /// `SubRange` of parameter pattern nodes.
    params_start: ExtraIndex,
    params_end: ExtraIndex,
};

pub const TypeAlias = struct {
    header: DeclHeader,
    /// `SubRange` of type-parameter TOKENS (lower identifiers).
    params_start: ExtraIndex,
    params_end: ExtraIndex,
};

pub const TypeDecl = struct {
    header: DeclHeader,
    /// `SubRange` of type-parameter TOKENS.
    params_start: ExtraIndex,
    params_end: ExtraIndex,
    /// `SubRange` of `constructor` nodes (an `error_constructor` when the
    /// list was empty or broken).
    ctors_start: ExtraIndex,
    ctors_end: ExtraIndex,
};

pub const ForeignType = struct {
    header: DeclHeader,
    /// `SubRange` of type-parameter TOKENS.
    params_start: ExtraIndex,
    params_end: ExtraIndex,
};

pub const If = struct {
    then_expr: Node.Index,
    else_expr: Node.Index,
};

// ---------------------------------------------------------------------------
// Typed accessor views. Each mirrors a `std.zig.Ast.full.*` struct: the
// caller asks for a node of a known tag and gets every part by name.
// ---------------------------------------------------------------------------

pub const full = struct {
    pub const Import = struct {
        import_token: TokenIndex,
        name: ?TokenIndex,
        alias: ?TokenIndex,
        exposing_token: ?TokenIndex,
        exposed: []const Node.Index,
    };

    pub const Annotation = struct {
        header: DeclHeader,
        name: TokenIndex,
        type_expr: Node.Index,
    };

    pub const Definition = struct {
        header: DeclHeader,
        name: TokenIndex,
        params: []const Node.Index,
        body: Node.Index,
    };

    pub const TypeAlias = struct {
        header: DeclHeader,
        name: TokenIndex,
        params: []const TokenIndex,
        body: Node.Index,
    };

    pub const TypeDecl = struct {
        header: DeclHeader,
        name: TokenIndex,
        params: []const TokenIndex,
        ctors: []const Node.Index,
    };

    pub const ForeignValue = struct {
        header: DeclHeader,
        name: TokenIndex,
        type_expr: Node.Index,
    };

    pub const ForeignType = struct {
        header: DeclHeader,
        name: TokenIndex,
        params: []const TokenIndex,
    };

    pub const Constructor = struct {
        name: TokenIndex,
        args: []const Node.Index,
    };

    pub const TypeCon = struct {
        name: TokenIndex,
        args: []const Node.Index,
    };

    pub const TypeRecordExt = struct {
        brace: TokenIndex,
        base: TokenIndex,
        fields: []const Node.Index,
    };

    pub const RecordUpdate = struct {
        brace: TokenIndex,
        base: TokenIndex,
        fields: []const Node.Index,
    };

    pub const Apply = struct {
        function: Node.Index,
        args: []const Node.Index,
    };

    pub const Binop = struct {
        op_token: TokenIndex,
        lhs: Node.Index,
        rhs: Node.Index,
    };

    pub const Lambda = struct {
        backslash: TokenIndex,
        params: []const Node.Index,
        body: Node.Index,
    };

    pub const If = struct {
        if_token: TokenIndex,
        cond: Node.Index,
        then_expr: Node.Index,
        else_expr: Node.Index,
    };

    pub const Let = struct {
        let_token: TokenIndex,
        bindings: []const Node.Index,
        body: Node.Index,
    };

    pub const LetDef = struct {
        name: TokenIndex,
        params: []const Node.Index,
        body: Node.Index,
    };

    pub const LetPattern = struct {
        pattern: Node.Index,
        value: Node.Index,
    };

    pub const Case = struct {
        case_token: TokenIndex,
        scrutinee: Node.Index,
        branches: []const Node.Index,
    };

    pub const Branch = struct {
        pattern: Node.Index,
        body: Node.Index,
    };

    pub const String = struct {
        start_token: TokenIndex,
        parts: []const Node.Index,
    };

    pub const MultilineString = struct {
        first_line: TokenIndex,
        last_line: TokenIndex,
    };

    pub const PatCtor = struct {
        name: TokenIndex,
        args: []const Node.Index,
    };

    pub const PatRecord = struct {
        brace: TokenIndex,
        fields: []const TokenIndex,
    };

    pub const PatAs = struct {
        pattern: Node.Index,
        name: TokenIndex,
    };

    pub const ErrorNode = struct {
        token: TokenIndex,
        code: @import("diagnostic").Code,
        /// Index into `errors`, or null when the error was not reported.
        error_index: ?u32,
    };
};

pub fn deinit(tree: *Ast, gpa: Allocator) void {
    tree.nodes.deinit(gpa);
    gpa.free(tree.extra);
    gpa.free(tree.errors);
    tree.* = undefined;
}

/// A tree with only a root, for an artifact slot that has not been parsed.
pub const empty: Ast = .{
    .nodes = .empty,
    .extra = &.{},
    .errors = &.{},
    .module_doc = .empty,
};

// ---- Raw access -------------------------------------------------------------

pub fn nodeTag(tree: *const Ast, node: Node.Index) Node.Tag {
    return tree.nodes.items(.tag)[node.int()];
}

pub fn nodeMainToken(tree: *const Ast, node: Node.Index) TokenIndex {
    return tree.nodes.items(.main_token)[node.int()];
}

pub fn nodeData(tree: *const Ast, node: Node.Index) Node.Data {
    return tree.nodes.items(.data)[node.int()];
}

/// The elements of a range, viewed as `T` (`Node.Index` or `TokenIndex`).
pub fn extraSlice(tree: *const Ast, range: SubRange, comptime T: type) []const T {
    comptime std.debug.assert(@sizeOf(T) == 4);
    return @ptrCast(tree.extra[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}

/// Read a record out of `extra` starting at `index`, field by field. Nested
/// structs (`DeclHeader` inside a `Definition`) are flattened in order.
pub fn extraData(tree: *const Ast, index: ExtraIndex, comptime T: type) T {
    var i: usize = @intFromEnum(index);
    return readExtra(tree.extra, &i, T);
}

fn readExtra(extra: []const u32, i: *usize, comptime T: type) T {
    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        @field(result, field.name) = switch (@typeInfo(field.type)) {
            .@"struct" => readExtra(extra, i, field.type),
            .@"enum" => blk: {
                const v: field.type = @enumFromInt(extra[i.*]);
                i.* += 1;
                break :blk v;
            },
            .int => blk: {
                const v: field.type = extra[i.*];
                i.* += 1;
                break :blk v;
            },
            else => @compileError("unexpected extra field type: " ++ @typeName(field.type)),
        };
    }
    return result;
}

/// Number of `u32` words `T` occupies in `extra`.
pub fn extraLen(comptime T: type) u32 {
    var n: u32 = 0;
    inline for (std.meta.fields(T)) |field| {
        n += switch (@typeInfo(field.type)) {
            .@"struct" => extraLen(field.type),
            else => 1,
        };
    }
    return n;
}

fn rangeOf(data: Node.Data) SubRange {
    return .{ .start = @enumFromInt(data.lhs), .end = @enumFromInt(data.rhs) };
}

fn rangeAt(tree: *const Ast, index: u32) SubRange {
    return tree.extraData(@enumFromInt(index), SubRange);
}

// ---- Views ------------------------------------------------------------------

/// The top-level items in source order.
pub fn rootItems(tree: *const Ast) []const Node.Index {
    return tree.extraSlice(rangeOf(tree.nodeData(.root)), Node.Index);
}

/// The element list of any tag whose `lhs..rhs` is a `SubRange` of node
/// indices: `constructor`, `type_con`, `type_tuple`, `type_record`,
/// `string`, `tuple`, `list`, `record`, `apply`, `pat_ctor`, `pat_tuple`,
/// `pat_list`.
pub fn children(tree: *const Ast, node: Node.Index) []const Node.Index {
    switch (tree.nodeTag(node)) {
        .root, .constructor, .type_con, .type_tuple, .type_record, .string, .tuple, .list, .record, .apply, .pat_ctor, .pat_tuple, .pat_list => {},
        else => unreachable, // not a range node; use the tag's view
    }
    return tree.extraSlice(rangeOf(tree.nodeData(node)), Node.Index);
}

/// The `equatable` marker token in front of a `type_var`, or null
/// (checker.md Appendix B). Stored in `lhs` rather than as a separate node
/// so the marker costs nothing on the overwhelmingly common unmarked
/// variable, and so the formatter still has the TOKEN to print — comments
/// attach to tokens, and a bool would lose the one in `-- why\nequatable a`.
pub fn typeVarMarker(tree: *const Ast, node: Node.Index) ?TokenIndex {
    std.debug.assert(tree.nodeTag(node) == .type_var);
    const o: OptionalTokenIndex = @enumFromInt(tree.nodeData(node).lhs);
    return o.unwrap();
}

/// The visibility and doc range of any declaration tag.
pub fn declHeader(tree: *const Ast, node: Node.Index) DeclHeader {
    std.debug.assert(tree.nodeTag(node).isDecl());
    return tree.extraData(@enumFromInt(tree.nodeData(node).lhs), DeclHeader);
}

pub fn fullImport(tree: *const Ast, node: Node.Index) full.Import {
    std.debug.assert(tree.nodeTag(node) == .import);
    const d = tree.extraData(@enumFromInt(tree.nodeData(node).lhs), Import);
    return .{
        .import_token = tree.nodeMainToken(node),
        .name = d.name.unwrap(),
        .alias = d.alias.unwrap(),
        .exposing_token = d.exposing_token.unwrap(),
        .exposed = tree.extraSlice(.{ .start = d.exposed_start, .end = d.exposed_end }, Node.Index),
    };
}

pub fn fullAnnotation(tree: *const Ast, node: Node.Index) full.Annotation {
    std.debug.assert(tree.nodeTag(node) == .annotation);
    const data = tree.nodeData(node);
    return .{
        .header = tree.extraData(@enumFromInt(data.lhs), DeclHeader),
        .name = tree.nodeMainToken(node),
        .type_expr = @enumFromInt(data.rhs),
    };
}

pub fn fullDefinition(tree: *const Ast, node: Node.Index) full.Definition {
    std.debug.assert(tree.nodeTag(node) == .definition);
    const data = tree.nodeData(node);
    const d = tree.extraData(@enumFromInt(data.lhs), Definition);
    return .{
        .header = d.header,
        .name = tree.nodeMainToken(node),
        .params = tree.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Node.Index),
        .body = @enumFromInt(data.rhs),
    };
}

pub fn fullTypeAlias(tree: *const Ast, node: Node.Index) full.TypeAlias {
    std.debug.assert(tree.nodeTag(node) == .type_alias);
    const data = tree.nodeData(node);
    const d = tree.extraData(@enumFromInt(data.lhs), TypeAlias);
    return .{
        .header = d.header,
        .name = tree.nodeMainToken(node),
        .params = tree.extraSlice(.{ .start = d.params_start, .end = d.params_end }, TokenIndex),
        .body = @enumFromInt(data.rhs),
    };
}

pub fn fullTypeDecl(tree: *const Ast, node: Node.Index) full.TypeDecl {
    std.debug.assert(tree.nodeTag(node) == .type_decl);
    const d = tree.extraData(@enumFromInt(tree.nodeData(node).lhs), TypeDecl);
    return .{
        .header = d.header,
        .name = tree.nodeMainToken(node),
        .params = tree.extraSlice(.{ .start = d.params_start, .end = d.params_end }, TokenIndex),
        .ctors = tree.extraSlice(.{ .start = d.ctors_start, .end = d.ctors_end }, Node.Index),
    };
}

pub fn fullForeignValue(tree: *const Ast, node: Node.Index) full.ForeignValue {
    std.debug.assert(tree.nodeTag(node) == .foreign_value);
    const data = tree.nodeData(node);
    return .{
        .header = tree.extraData(@enumFromInt(data.lhs), DeclHeader),
        .name = tree.nodeMainToken(node),
        .type_expr = @enumFromInt(data.rhs),
    };
}

pub fn fullForeignType(tree: *const Ast, node: Node.Index) full.ForeignType {
    std.debug.assert(tree.nodeTag(node) == .foreign_type);
    const d = tree.extraData(@enumFromInt(tree.nodeData(node).lhs), ForeignType);
    return .{
        .header = d.header,
        .name = tree.nodeMainToken(node),
        .params = tree.extraSlice(.{ .start = d.params_start, .end = d.params_end }, TokenIndex),
    };
}

pub fn fullConstructor(tree: *const Ast, node: Node.Index) full.Constructor {
    std.debug.assert(tree.nodeTag(node) == .constructor);
    return .{ .name = tree.nodeMainToken(node), .args = tree.children(node) };
}

pub fn fullTypeCon(tree: *const Ast, node: Node.Index) full.TypeCon {
    std.debug.assert(tree.nodeTag(node) == .type_con);
    return .{ .name = tree.nodeMainToken(node), .args = tree.children(node) };
}

pub fn fullTypeRecordExt(tree: *const Ast, node: Node.Index) full.TypeRecordExt {
    std.debug.assert(tree.nodeTag(node) == .type_record_ext);
    const data = tree.nodeData(node);
    return .{
        .brace = tree.nodeMainToken(node),
        .base = data.lhs,
        .fields = tree.extraSlice(tree.rangeAt(data.rhs), Node.Index),
    };
}

pub fn fullRecordUpdate(tree: *const Ast, node: Node.Index) full.RecordUpdate {
    std.debug.assert(tree.nodeTag(node) == .record_update);
    const data = tree.nodeData(node);
    return .{
        .brace = tree.nodeMainToken(node),
        .base = data.lhs,
        .fields = tree.extraSlice(tree.rangeAt(data.rhs), Node.Index),
    };
}

pub fn fullApply(tree: *const Ast, node: Node.Index) full.Apply {
    std.debug.assert(tree.nodeTag(node) == .apply);
    const all = tree.children(node);
    return .{ .function = all[0], .args = all[1..] };
}

pub fn fullBinop(tree: *const Ast, node: Node.Index) full.Binop {
    std.debug.assert(tree.nodeTag(node).isBinop());
    const data = tree.nodeData(node);
    return .{ .op_token = tree.nodeMainToken(node), .lhs = @enumFromInt(data.lhs), .rhs = @enumFromInt(data.rhs) };
}

pub fn fullLambda(tree: *const Ast, node: Node.Index) full.Lambda {
    std.debug.assert(tree.nodeTag(node) == .lambda);
    const data = tree.nodeData(node);
    return .{
        .backslash = tree.nodeMainToken(node),
        .params = tree.extraSlice(tree.rangeAt(data.lhs), Node.Index),
        .body = @enumFromInt(data.rhs),
    };
}

pub fn fullIf(tree: *const Ast, node: Node.Index) full.If {
    std.debug.assert(tree.nodeTag(node) == .@"if");
    const data = tree.nodeData(node);
    const d = tree.extraData(@enumFromInt(data.rhs), If);
    return .{
        .if_token = tree.nodeMainToken(node),
        .cond = @enumFromInt(data.lhs),
        .then_expr = d.then_expr,
        .else_expr = d.else_expr,
    };
}

pub fn fullLet(tree: *const Ast, node: Node.Index) full.Let {
    std.debug.assert(tree.nodeTag(node) == .let);
    const data = tree.nodeData(node);
    return .{
        .let_token = tree.nodeMainToken(node),
        .bindings = tree.extraSlice(tree.rangeAt(data.lhs), Node.Index),
        .body = @enumFromInt(data.rhs),
    };
}

pub fn fullLetDef(tree: *const Ast, node: Node.Index) full.LetDef {
    std.debug.assert(tree.nodeTag(node) == .let_def);
    const data = tree.nodeData(node);
    return .{
        .name = tree.nodeMainToken(node),
        .params = tree.extraSlice(tree.rangeAt(data.lhs), Node.Index),
        .body = @enumFromInt(data.rhs),
    };
}

/// Both binding forms that pair a `LetPattern` with a right-hand side:
/// `p = e` (`let_pattern`) and `p <- f a` (`let_bind`, §6.7).
pub fn fullLetPattern(tree: *const Ast, node: Node.Index) full.LetPattern {
    std.debug.assert(tree.nodeTag(node) == .let_pattern or tree.nodeTag(node) == .let_bind);
    const data = tree.nodeData(node);
    return .{ .pattern = @enumFromInt(data.lhs), .value = @enumFromInt(data.rhs) };
}

pub fn fullCase(tree: *const Ast, node: Node.Index) full.Case {
    std.debug.assert(tree.nodeTag(node) == .case);
    const data = tree.nodeData(node);
    return .{
        .case_token = tree.nodeMainToken(node),
        .scrutinee = @enumFromInt(data.lhs),
        .branches = tree.extraSlice(tree.rangeAt(data.rhs), Node.Index),
    };
}

pub fn fullBranch(tree: *const Ast, node: Node.Index) full.Branch {
    std.debug.assert(tree.nodeTag(node) == .branch);
    const data = tree.nodeData(node);
    return .{ .pattern = @enumFromInt(data.lhs), .body = @enumFromInt(data.rhs) };
}

pub fn fullString(tree: *const Ast, node: Node.Index) full.String {
    std.debug.assert(tree.nodeTag(node) == .string);
    return .{ .start_token = tree.nodeMainToken(node), .parts = tree.children(node) };
}

pub fn fullMultilineString(tree: *const Ast, node: Node.Index) full.MultilineString {
    std.debug.assert(tree.nodeTag(node) == .multiline_string);
    return .{ .first_line = tree.nodeMainToken(node), .last_line = tree.nodeData(node).lhs };
}

pub fn fullPatCtor(tree: *const Ast, node: Node.Index) full.PatCtor {
    std.debug.assert(tree.nodeTag(node) == .pat_ctor);
    return .{ .name = tree.nodeMainToken(node), .args = tree.children(node) };
}

pub fn fullPatRecord(tree: *const Ast, node: Node.Index) full.PatRecord {
    std.debug.assert(tree.nodeTag(node) == .pat_record);
    return .{ .brace = tree.nodeMainToken(node), .fields = tree.extraSlice(rangeOf(tree.nodeData(node)), TokenIndex) };
}

pub fn fullPatAs(tree: *const Ast, node: Node.Index) full.PatAs {
    std.debug.assert(tree.nodeTag(node) == .pat_as);
    const data = tree.nodeData(node);
    return .{ .pattern = @enumFromInt(data.lhs), .name = data.rhs };
}

pub fn fullError(tree: *const Ast, node: Node.Index) full.ErrorNode {
    std.debug.assert(tree.nodeTag(node).isError());
    const data = tree.nodeData(node);
    return .{
        .token = tree.nodeMainToken(node),
        .code = @enumFromInt(data.lhs),
        .error_index = if (data.rhs == std.math.maxInt(u32)) null else data.rhs,
    };
}

/// The single child of the one-operand tags: `type_paren`, `record_type_field`,
/// `interp`, `negate`, `paren`, `field`, `field_access`, `tuple_index`,
/// `question`, `let_annotation`, `pat_paren`.
pub fn operand(tree: *const Ast, node: Node.Index) Node.Index {
    switch (tree.nodeTag(node)) {
        .type_paren, .record_type_field, .interp, .negate, .paren, .field, .field_access, .tuple_index, .question, .let_annotation, .pat_paren => {},
        else => unreachable, // not a one-operand node
    }
    return @enumFromInt(tree.nodeData(node).lhs);
}

// ---------------------------------------------------------------------------
// Tests. The parser's tests exercise every view against real trees; here
// only the extra-record machinery is checked in isolation.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extraData flattens nested headers and extraLen agrees" {
    try testing.expectEqual(@as(u32, 5), extraLen(DeclHeader));
    try testing.expectEqual(@as(u32, 7), extraLen(Definition));
    try testing.expectEqual(@as(u32, 9), extraLen(TypeDecl));
    try testing.expectEqual(@as(u32, 5), extraLen(Import));

    const none_token = std.math.maxInt(u32);
    const words = [_]u32{ 7, none_token, 3, 2, 5, 10, 12 };
    var tree: Ast = empty;
    tree.extra = &words;
    const d = tree.extraData(@enumFromInt(0), Definition);
    try testing.expectEqual(@as(?TokenIndex, 7), d.header.pub_token.unwrap());
    try testing.expectEqual(@as(?TokenIndex, null), d.header.opaque_token.unwrap());
    try testing.expectEqual(@as(?TokenIndex, 3), d.header.equatable_token.unwrap());
    try testing.expectEqual(@as(u32, 2), d.header.doc_start);
    try testing.expectEqual(@as(u32, 5), d.header.doc_end);
    try testing.expectEqual(@as(u32, 10), @intFromEnum(d.params_start));
    try testing.expectEqual(@as(u32, 12), @intFromEnum(d.params_end));
}

test "every operator token maps to a binop tag and back" {
    inline for (@typeInfo(Token.Tag).@"enum".fields) |field| {
        const token: Token.Tag = @enumFromInt(field.value);
        const mapped = Node.Tag.fromOperator(token);
        try testing.expectEqual(token.isOperator(), mapped != null);
        if (mapped) |tag| try testing.expect(tag.isBinop());
    }
}
