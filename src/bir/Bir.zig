//! The per-file, untyped, name-resolved IR (docs/design/frontend.md §3.6,
//! language.md §8, fast-compiler.md §6): what `Lower` makes of one file's
//! AST and what everything after the firewall consumes. It is a pure
//! function of the file's bytes — nothing in it depends on another module,
//! which is what makes it content-addressable and cacheable (§6).
//!
//! Shape, after `std.zig.Zir`: one `MultiArrayList(Inst)` of `{tag, lhs,
//! rhs}` records plus one shared `extra` sidecar for everything
//! variable-length (`SubRange`s and small records, read positionally like
//! `Ast.extraData`). Every reference is a `u32` index into a named array;
//! there is no pointer and no slice into the source anywhere. Instructions
//! are grouped per declaration: `Decl.inst_start..inst_end` is contiguous,
//! and every operand of an instruction lies in the same declaration's
//! range, so a declaration can be checked, cached or dumped on its own.
//!
//! Identifiers are `Symbol`s, but not inline: every symbol-carrying slot
//! holds a `SymbolIndex` into the ONE `symbols` column. Lowering runs on a
//! worker with a per-worker interner, so the symbols are local to that
//! worker until the session merges interners; `applyRemap` then rewrites
//! the file's symbols in one loop over that column and nothing else has to
//! know which instruction kinds carry names.
//!
//! Strings are decoded here: `string_bytes` holds the actual bytes of every
//! string literal (escapes resolved, multiline lines joined with `\n`) and
//! the spelling of every numeric literal, so no later phase re-lexes. Names
//! resolve into exactly the forms of language.md §8.1 — `local`, `top`,
//! `ctor`, `import_value`, `import_ctor`, `qualified` (plus their
//! constructor and type twins) — and prelude names take the same
//! `import_*` forms an explicit import would give (Appendix A).
//!
//! Per declaration there are also a `locals` table (what each local index
//! means), a `refs` list (the top-level names and imported names the
//! declaration mentions: the dead-code-elimination edges of
//! fast-compiler.md §9.1, a byproduct of resolution) and, through
//! `interface`, the module's interface skeleton (§8.1 of the design doc).
//!
//! `?` is the one desugaring that is not spelled out as ordinary
//! instructions: `try` (see its tag) stands for the `case` of language.md
//! §6.6 whose `Err`/`Nothing` branch returns from an enclosing function,
//! and the checker reads it as that case — the Maybe/Result choice is M2's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const InternPool = @import("../InternPool.zig");
const Diagnostics = @import("Diagnostics.zig");

const Bir = @This();

pub const Symbol = InternPool.Symbol;

/// Owned. Grouped per declaration (`Decl.inst_start..inst_end`).
insts: InstList.Slice,
/// Owned. Ranges and multi-word payloads, indexed from instruction data.
extra: []const u32,
/// Owned. Decoded string and character bytes, numeric spellings.
string_bytes: []const u8,
/// Owned. The one column of symbols; everything else refers to it by
/// `SymbolIndex`. Rewritten in place by `applyRemap`.
symbols: []Symbol,
/// Owned. One per top-level declaration, in source order.
decls: []const Decl,
/// Owned. Every constructor of every `type` in the file, in source order;
/// `ctor(index)` references index into it.
ctors: []const Ctor,
/// Owned. Per-declaration ranges (`Decl.locals_start..locals_end`).
locals: []const Local,
/// Owned. Per-declaration ranges (`Decl.refs_start..refs_end`).
refs: []const Ref,
/// Owned. Explicit imports in source order, then the prelude modules
/// (flagged), so the table lists every module this file resolves against.
imports: []const Import,
/// Owned. The `exposing` names of every explicit import, in source order
/// (`Import.exposed_start..exposed_end`). A table of its own rather than a
/// range of `symbols` because each entry needs its TOKEN too: whether the
/// named module really exposes the name is `Resolve`'s to decide, and the
/// diagnostic has to point at the name in the list, not at the import.
exposed: []const Exposed,
/// Owned. The interface skeleton: the indices of the `pub` declarations
/// (values, foreign values, types, opaque types, aliases, foreign types) in
/// source order. Everything an interface needs is on the `Decl`.
interface: []const DeclIndex,
/// Owned. Lowering diagnostics in the order they were found (which is
/// source order per declaration; the session sorts).
diagnostics: []const Diagnostics.Item,
/// Comment indices `[start, end)` of the module's `--!` block, copied from
/// the AST so the interface builder need not keep the tree.
module_doc_start: u32,
module_doc_end: u32,

pub const InstList = std.MultiArrayList(Inst);

pub const Inst = struct {
    tag: Tag,
    /// The token this instruction came from, into the file's token list.
    /// Every diagnostic after lowering — the resolver's, the checker's —
    /// points at an INSTRUCTION (checker.md §6.1: "regions are the Bir
    /// instruction index"), and a token index is the cheapest thing that
    /// turns one back into a span: four bytes, and the exact extent comes
    /// from `Tokenizer.tokenEnd` on the token the parser already produced.
    /// Storing the two offsets instead would cost twice as much on the most
    /// numerous record in the IR to buy nothing the token does not give.
    main_token: u32,
    data: Data,

    /// Meaning depends on `tag`; see `Tag`. Unused halves are zero.
    pub const Data = struct {
        lhs: u32,
        rhs: u32,

        pub const unused: u32 = 0;
    };

    /// Index into `insts`.
    pub const Index = enum(u32) {
        _,

        pub fn int(i: Index) u32 {
            return @intFromEnum(i);
        }

        pub fn toOptional(i: Index) OptionalIndex {
            const o: OptionalIndex = @enumFromInt(@intFromEnum(i));
            std.debug.assert(o != .none);
            return o;
        }
    };

    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(o: OptionalIndex) ?Index {
            return if (o == .none) null else @enumFromInt(@intFromEnum(o));
        }
    };

    comptime {
        std.debug.assert(@sizeOf(Tag) == 1);
        std.debug.assert(@sizeOf(Data) == 8);
    }

    /// Every instruction kind. Each comment states what `lhs` and `rhs`
    /// hold. "Range" means a `SubRange` stored inline as `lhs..rhs`; "extra
    /// `T`" means `lhs` or `rhs` is the `ExtraIndex` of a `T` record.
    pub const Tag = enum(u8) {
        // ---- Name references (language.md §8.1) ------------------------

        /// A local binding of this declaration. `lhs` is the local index
        /// (into the declaration's `locals` range).
        local,
        /// A top-level value of this module. `lhs` is the `DeclIndex`.
        top,
        /// A constructor of this module. `lhs` is the `CtorIndex`.
        ctor,
        /// A value from an `exposing` list, or a prelude value. `lhs` is
        /// the module's `SymbolIndex`, `rhs` the name's.
        import_value,
        /// A constructor from an `exposing` list, or a prelude constructor.
        /// `lhs` module, `rhs` name.
        import_ctor,
        /// `Alias.name`, the alias resolved to its module. `lhs` module,
        /// `rhs` name.
        qualified,
        /// `Alias.Ctor` in expression or pattern position. `lhs` module,
        /// `rhs` name.
        qualified_ctor,

        // ---- Resolved references (checker.md §4.5) ---------------------
        //
        // What `resolve/Resolve.zig` REWRITES the four `import_*` /
        // `qualified*` forms into once the module graph exists: a name is
        // looked up once, in topological order, and every later phase
        // reads a pair of dense indices instead of two symbols. A
        // reference to the module's OWN declarations becomes `top`,
        // `ctor` or `type_top` instead, and one that does not resolve
        // becomes `error` — so after resolution no name lookup remains.

        /// A value of another module. `lhs` is the `resolve.Graph`
        /// module index, `rhs` the index into that module's interface
        /// `values`.
        ext_value,
        /// A constructor of another module. `lhs` module index, `rhs`
        /// index into its interface `ctors`.
        ext_ctor,

        // ---- Types -----------------------------------------------------

        /// A type variable. `lhs` is its `SymbolIndex`; `rhs` is a
        /// `TypeVarInfo` — the index of the declaring type parameter in a
        /// `type`/`type alias`/`foreign type` body (or `param_none` in an
        /// annotation, where variables are implicitly quantified, §7) plus
        /// the `equatable` marker of checker.md Appendix B.
        type_var,
        /// A type or alias of this module. `lhs` is the `DeclIndex`.
        type_top,
        /// A type from an `exposing` list or the prelude. `lhs` module
        /// `SymbolIndex`, `rhs` name.
        type_import,
        /// `Alias.Type`. `lhs` module, `rhs` name.
        type_qualified,
        /// A type of another module, resolved (see `ext_value`). `lhs`
        /// module index, `rhs` index into its interface `types`.
        ext_type,
        /// A type applied to arguments, `Maybe a`. `lhs` is the type
        /// reference; `rhs` is extra `SubRange` of argument type insts.
        type_app,
        /// `a, b -> c` (language.md §6.7): n-ary. `lhs` is an extra
        /// `SubRange` record of parameter types, `rhs` the result type.
        type_fn,
        /// `()`.
        type_unit,
        /// `( a, b )`. Range of element types.
        type_tuple,
        /// `{ x : Int }`. Range of `Field` pairs (name `SymbolIndex`, type).
        type_record,
        /// `{ r | x : Int }`. `lhs` is the base `type_var`; `rhs` is extra
        /// `SubRange` of `Field` pairs.
        type_record_ext,

        // ---- Unresolved schema plan (schema.md §4, S1) -----------------

        /// A schema operand name. `lhs` is its SymbolIndex.
        schema_ref,
        /// A schema operand applied to schema arguments. `lhs` is the head
        /// instruction and `rhs` is an extra SubRange of argument roots.
        schema_app,
        /// Explicit grouping around a schema operand. `lhs` is the child.
        schema_paren,
        /// Record schema. Range of schema_field instruction roots.
        schema_record,
        /// Field schema. `lhs` is its SymbolIndex; `rhs` extra SchemaField.
        schema_field,
        /// Declaration-level operand plus modifiers. `lhs` operand; `rhs`
        /// extra SubRange of modifier roots.
        schema_value,
        /// Tagged union. `lhs` is the decoded discriminator string
        /// instruction; `rhs` extra SubRange of variants.
        schema_tagged,
        /// Tagged variant. `lhs` name SymbolIndex; `rhs` extra SchemaVariant.
        schema_variant,
        /// External-name modifier. `lhs` is a decoded string instruction.
        schema_as,
        /// Conversion modifier. `lhs` is the retained Atom expression root.
        schema_via,
        schema_optional,
        schema_nullable,
        /// An unresolved nonlocal leaf inside a `via` Atom. `lhs` is its
        /// SymbolIndex and the instruction token retains lower/upper/qualified.
        schema_expr_ref,

        // ---- Expressions: literals -------------------------------------

        /// An integer literal. `lhs..` is its spelling in `string_bytes`
        /// (`lhs` offset, `rhs` length), decimal or `0x`, as written: the
        /// same spelling is a JavaScript literal, so nothing re-lexes.
        int,
        /// A float literal, spelling in `string_bytes` like `int`.
        float,
        /// A character literal. `lhs` is the Unicode scalar value.
        char,
        /// A string without interpolation, escapes decoded (multiline
        /// strings joined with `\n`). `lhs` offset, `rhs` length in
        /// `string_bytes`.
        string,
        /// A literal run inside an interpolated string; same payload as
        /// `string`. Only ever an element of `interp`.
        chunk,
        /// `"a ${e} b"` (§2.6, §8.2). Range of parts in order: `chunk`
        /// instructions are literal text, anything else is an interpolated
        /// expression the checker must constrain.
        interp,
        /// `()`.
        unit,

        // ---- Expressions: composite ------------------------------------

        /// `( a, b )`. Range of elements.
        tuple,
        /// `[ a, b ]`. Range of elements.
        list,
        /// `{ a = 1 }`. Range of `Field` pairs (name `SymbolIndex`, value).
        record,
        /// `{ r | a = 1 }`. `lhs` is the resolved base name (a reference
        /// instruction); `rhs` is extra `SubRange` of `Field` pairs.
        record_update,
        /// `e.name`. `lhs` target, `rhs` field `SymbolIndex`.
        field_access,
        /// `e.0`. `lhs` target, `rhs` the index.
        tuple_index,
        /// `f a b`, and every desugared operator: `a + b` is
        /// `call(import_value(Basics, add), [a, b])`. `lhs` callee; `rhs`
        /// extra `SubRange` of arguments (at least one).
        call,
        /// `x.m a b` where the field access is the HEAD of an application
        /// (static-dispatch-spike.md §1.1, §1.4), and what the six
        /// comparison operators desugar to (§3.1). `lhs` is the receiver;
        /// `rhs` is the `ExtraIndex` of a `MethodCall`. Which function it
        /// calls is not known before the checker runs, so — unlike `call` —
        /// it adds no `refs` edge (§1.4).
        method_call,
        /// `a.decode s` inside a declaration whose `where` clause
        /// constrains the type variable `a` (§4.1): a call on a TYPE, with
        /// no receiver value. `lhs` is the variable's `SymbolIndex`; `rhs`
        /// is the `ExtraIndex` of a `TypeDispatch`.
        type_dispatch,
        /// `\a b -> e`, n-ary. `lhs` extra `SubRange` of parameter patterns;
        /// `rhs` body. Also what `.field`, `>>` and `<<` desugar to.
        lambda,
        /// `let … in e`. `lhs` extra `SubRange` of `let_def`/`let_pattern`
        /// instructions; `rhs` body. All bindings are in scope in all
        /// bodies (§7).
        let,
        /// `name args = e` in a `let`. `lhs` extra `LetDef`; `rhs` body.
        let_def,
        /// `pattern = e` in a `let`. `lhs` pattern, `rhs` value.
        let_pattern,
        /// `case e of …`, and what `if` desugars to (branches on
        /// `import_ctor(Basics, True)` / `False`). `lhs` scrutinee; `rhs`
        /// extra `SubRange` of `branch` instructions.
        case,
        /// `pattern -> e`. `lhs` pattern, `rhs` body.
        branch,
        /// `e?` (§6.6). Stands for `case e of Ok v -> v; Err x -> return
        /// (Err x)` (or the `Maybe` shape): `lhs` is the scrutinee; the
        /// instruction's value is the unwrapped `v`; `rhs` is the
        /// `Inst.OptionalIndex` of the enclosing `let_def` the failure
        /// branch returns from, or `none` for the declaration itself. The
        /// choice of shape is the checker's, on this instruction.
        @"try",

        // ---- Patterns --------------------------------------------------

        /// `_`.
        pat_wild,
        /// A variable. `lhs` is the local index it binds.
        pat_var,
        /// `Just x`. `lhs` is the constructor reference (`ctor`,
        /// `import_ctor`, `qualified_ctor`, or `error`); `rhs` extra
        /// `SubRange` of argument patterns (its length is the arity used).
        pat_ctor,
        /// An integer literal pattern, `-1` included; spelling in
        /// `string_bytes` like `int`.
        pat_int,
        /// `lhs` is the scalar value.
        pat_char,
        /// Decoded bytes in `string_bytes` like `string`.
        pat_string,
        /// `()`.
        pat_unit,
        /// `( a, b )`. Range of element patterns.
        pat_tuple,
        /// `[ a, b ]`. Range of element patterns.
        pat_list,
        /// `x :: xs`. `lhs` head, `rhs` tail.
        pat_cons,
        /// `{ a, b }`. Range of the local indices bound, one per field; the
        /// field name is the local's name.
        pat_record,
        /// `p as name`. `lhs` pattern, `rhs` the local index bound.
        pat_as,

        // ---- Placeholder -----------------------------------------------

        /// Where an expression, pattern or type could not be produced: a
        /// parser placeholder node, or a name that did not resolve. `lhs`
        /// is the `@intFromEnum` of the `diagnostic.Code` (already reported
        /// by whoever produced it). Downstream treats it as a poisoned
        /// value that unifies with anything.
        @"error",

        pub fn isPattern(tag: Tag) bool {
            return @intFromEnum(tag) >= @intFromEnum(Tag.pat_wild) and @intFromEnum(tag) <= @intFromEnum(Tag.pat_as);
        }

        pub fn isType(tag: Tag) bool {
            return @intFromEnum(tag) >= @intFromEnum(Tag.type_var) and @intFromEnum(tag) <= @intFromEnum(Tag.type_record_ext);
        }

        /// The unresolved `(module symbol, name symbol)` forms lowering
        /// produces, which `Resolve` rewrites and nothing after it sees.
        pub fn isUnresolved(tag: Tag) bool {
            return switch (tag) {
                .import_value, .import_ctor, .qualified, .qualified_ctor, .type_import, .type_qualified => true,
                else => false,
            };
        }
    };
};

/// The `rhs` of a `type_var`. The marker rides in the top bit rather than
/// in a tag or a column of its own: it is one bit on a node kind that is
/// among the most numerous in any annotation, and every consumer already
/// reads `rhs` to ask which parameter the variable is.
pub const TypeVarInfo = packed struct(u32) {
    /// The declaring type parameter's index, or `param_none`.
    param: u31,
    /// `equatable a` at this occurrence (checker.md Appendix A, core only).
    equatable: bool,

    /// Not a parameter of an enclosing type declaration: an annotation's
    /// implicitly quantified variable (language.md §7).
    pub const param_none: u31 = std.math.maxInt(u31);

    pub fn pack(info: TypeVarInfo) u32 {
        return @bitCast(info);
    }

    pub fn unpack(rhs: u32) TypeVarInfo {
        return @bitCast(rhs);
    }
};

/// Index into `extra`.
pub const ExtraIndex = enum(u32) {
    _,
};

/// A half-open range `[start, end)` of `extra`.
pub const SubRange = struct {
    start: ExtraIndex,
    end: ExtraIndex,

    pub const empty: SubRange = .{ .start = @enumFromInt(0), .end = @enumFromInt(0) };

    pub fn len(r: SubRange) u32 {
        return @intFromEnum(r.end) - @intFromEnum(r.start);
    }
};

/// Index into `symbols`, or none.
pub const SymbolIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(s: SymbolIndex) ?u32 {
        return if (s == .none) null else @intFromEnum(s);
    }
};

pub const DeclIndex = enum(u32) {
    _,

    pub fn int(i: DeclIndex) u32 {
        return @intFromEnum(i);
    }
};

pub const CtorIndex = enum(u32) {
    _,

    pub fn int(i: CtorIndex) u32 {
        return @intFromEnum(i);
    }
};

/// A `(name, inst)` pair as stored in `record`, `record_update`,
/// `type_record` and `type_record_ext` ranges: two words per field.
pub const Field = struct {
    name: SymbolIndex,
    value: Inst.Index,
};

/// Which surface form a `method_call` came from (static-dispatch-spike.md
/// §1.3): `none` is the dot-call `x.m a`, the other six name the operator
/// of `language.md` §6.5 that desugared into the node (§3.1). It is an
/// enum and not a flag because the typing rule differs — `a == b` pins both
/// operands to one type — and because every diagnostic about one of these
/// calls names the OPERATOR, not `eq`.
pub const WellKnown = enum(u8) {
    none,
    eq,
    neq,
    lt,
    le,
    gt,
    ge,

    /// How the operator is written, or null for a dot-call.
    pub fn spelling(w: WellKnown) ?[]const u8 {
        return switch (w) {
            .none => null,
            .eq => "==",
            .neq => "/=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
        };
    }

    /// The origin an operator TOKEN produces, or null for an operator that
    /// is still a call of its core function (`+`, `::`, `&&`, …).
    pub fn fromOperator(op: @import("../lex/Token.zig").Tag) ?WellKnown {
        return switch (op) {
            .op_eq_eq => .eq,
            .op_slash_eq => .neq,
            .op_lt => .lt,
            .op_lte => .le,
            .op_gt => .gt,
            .op_gte => .ge,
            else => null,
        };
    }

    /// The method the operator asks for: `eq` for equality, `compare` for
    /// the four orderings (§3.1). Null for a dot-call, whose method name is
    /// whatever was written.
    pub fn method(w: WellKnown) ?InternPool.WellKnown {
        return switch (w) {
            .none => null,
            .eq, .neq => .eq,
            .lt, .le, .gt, .ge => .compare,
        };
    }
};

/// Payload of `method_call` (§1.4).
pub const MethodCall = struct {
    /// The method name, without its dot.
    name: SymbolIndex,
    /// The surface form this call was written as.
    origin: WellKnown,
    /// The arguments, NOT counting the receiver.
    args_start: ExtraIndex,
    args_end: ExtraIndex,
};

/// Payload of `type_dispatch` (§4.1).
pub const TypeDispatch = struct {
    name: SymbolIndex,
    args_start: ExtraIndex,
    args_end: ExtraIndex,
};

/// One constraint of a declaration's `where` clause
/// (static-dispatch-spike.md §2.1), stored as a triple in `extra` between
/// `Decl.where_start` and `Decl.where_end`.
pub const WhereConstraint = struct {
    /// The constrained type variable.
    variable: SymbolIndex,
    /// The method name.
    method: SymbolIndex,
    /// The method's type at this constraint.
    type_inst: Inst.Index,
};

/// Payload of `let_def`.
pub const LetDef = struct {
    /// The local index the binding introduces.
    local: u32,
    /// The `let_annotation`'s type, if the binding has one.
    annotation: Inst.OptionalIndex,
    /// `SubRange` of parameter patterns; empty for a constant.
    params_start: ExtraIndex,
    params_end: ExtraIndex,
};

pub const Decl = struct {
    kind: Kind,
    name: SymbolIndex,
    /// The declared name's token, for diagnostics about the declaration
    /// itself (`recursive_alias`, `duplicate_module`).
    name_token: u32,
    is_pub: bool,
    /// `pub opaque type`: the constructors are hidden from the interface.
    is_opaque: bool,
    /// `equatable foreign type T`: values of this type may be compared with
    /// `==` (checker.md Appendix B). Only ever true on `foreign_type`; an
    /// ordinary `type` is equatable when its fields are, which is M2b's
    /// question, not a lexical one.
    is_equatable: bool,
    /// Comment indices `[doc_start, doc_end)` of the attached `--|` block
    /// (plain comments inside the range are trivia).
    doc_start: u32,
    doc_end: u32,
    /// Values: the number of parameters. Types, aliases, foreign types: the
    /// number of type parameters.
    ///
    /// A `foreign_value` has no definition, so its count is its
    /// ANNOTATION's — `n` for `T1, …, Tn -> R`, 0 for an annotation that is
    /// not a function type (`frontend.md` §3.6, `boundary.md` §4 check 4).
    params: u32,
    /// Values: `SubRange` of parameter pattern instructions. Types: the
    /// range of parameter names in `symbols` (`type_params_start..end`).
    ///
    /// **EMPTY on a `foreign_value` even when `params` is not.** A `foreign`
    /// declares an arity and binds no names: there are no patterns to hold.
    params_start: ExtraIndex,
    params_end: ExtraIndex,
    /// Type declarations: the parameter names as `symbols[start..end]`.
    type_params_start: u32,
    type_params_end: u32,
    /// `value` with an annotation, `annotation_only`, `foreign_value`: the
    /// annotation's type. `type_alias`: the aliased type. Else none.
    annotation: Inst.OptionalIndex,
    /// The annotation's `where` clause as `WhereConstraint` triples in
    /// `extra` (static-dispatch-spike.md §1.4, §2.1); empty when there is
    /// none, which is every declaration outside the spike's fixtures.
    where_start: ExtraIndex,
    where_end: ExtraIndex,
    /// `value`: the body expression. Else none.
    body: Inst.OptionalIndex,
    /// `schema`: root of the unresolved schema instruction graph. Else none.
    schema_body: Inst.OptionalIndex,
    /// The declaration's instructions, contiguous.
    inst_start: Inst.Index,
    inst_end: Inst.Index,
    /// `type`: its constructors in `ctors`.
    ctors_start: u32,
    ctors_end: u32,
    locals_start: u32,
    locals_end: u32,
    refs_start: u32,
    refs_end: u32,

    pub const Kind = enum(u8) {
        /// A definition, with or without an annotation (`annotation` says).
        value,
        /// An annotation whose definition the parser did not find (already
        /// reported as `annotation_without_definition`). Kept so its type
        /// is still resolved and its name is still declared once.
        annotation_only,
        /// `type T = …`.
        type,
        /// `type alias T = …`.
        type_alias,
        /// `foreign name : Type` (§5.4).
        foreign_value,
        /// `foreign type T a` (§5.4): a type with no constructors.
        foreign_type,
        /// `schema T = ...` (schema.md §2). It occupies its own namespace.
        schema,

        /// True for the kinds that declare a name in the value namespace.
        pub fn isValue(k: Kind) bool {
            return switch (k) {
                .value, .annotation_only, .foreign_value => true,
                .type, .type_alias, .foreign_type, .schema => false,
            };
        }

        pub fn isForeign(k: Kind) bool {
            return k == .foreign_value or k == .foreign_type;
        }
    };

    pub fn hasAnnotation(d: Decl) bool {
        return d.annotation != .none;
    }

    pub fn whereRange(d: Decl) SubRange {
        return .{ .start = d.where_start, .end = d.where_end };
    }
};

pub const SchemaField = struct {
    operand: Inst.Index,
    modifiers_start: ExtraIndex,
    modifiers_end: ExtraIndex,
    doc_start: u32,
    doc_end: u32,
};

pub const SchemaVariant = struct {
    payload: Inst.OptionalIndex,
    rename: Inst.OptionalIndex,
};

pub const Ctor = struct {
    name: SymbolIndex,
    /// The constructor name's token.
    name_token: u32,
    /// The `type` declaring it.
    decl: DeclIndex,
    /// `SubRange` of argument type instructions; its length is the arity.
    args_start: ExtraIndex,
    args_end: ExtraIndex,
};

pub const Local = struct {
    /// `none` for a compiler-made local (`fresh`).
    name: SymbolIndex,
    kind: Kind,
    /// The instruction that introduces it: the `pat_var`/`pat_as`/
    /// `pat_record` binding it, the `let_def` defining it, or the `lambda`
    /// a fresh local belongs to.
    inst: Inst.Index,

    pub const Kind = enum(u8) {
        /// A function or lambda parameter (a bare variable pattern).
        param,
        /// A `let` definition (`let_def`).
        let,
        /// A variable bound inside a pattern: `case` branches, destructuring
        /// parameters, `let` patterns, `as`.
        pattern,
        /// Made by desugaring (`>>`, `<<`, `.field`): has no name.
        fresh,
    };
};

/// One edge of the dependency graph (fast-compiler.md §9.1), recorded the
/// first time a declaration mentions the name; deduplicated per
/// declaration and kept in first-mention order, which is source order and
/// therefore the same at every `--jobs`. (Symbol ids, local or global, are
/// NOT scheduling-independent — which worker took which file decides them —
/// so nothing observable may be ordered by them.)
pub const Ref = struct {
    kind: Kind,
    /// `top_*`: the `DeclIndex` or `CtorIndex`. `import_*`: the module's
    /// `SymbolIndex`.
    a: u32,
    /// `import_*`: the name's `SymbolIndex`. Else unused.
    b: u32,

    pub const Kind = enum(u8) {
        top_value,
        top_ctor,
        top_type,
        import_value,
        import_ctor,
        import_type,
    };
};

/// One name in an `exposing` list (language.md §5.2).
pub const Exposed = struct {
    name: SymbolIndex,
    /// The name's token. Lower names are values; upper names are a type
    /// OR a constructor and the file cannot tell which.
    token: u32,
};

pub const Import = struct {
    module: SymbolIndex,
    /// The module path token, for `unknown_module` and `import_cycle`.
    /// Meaningless on a prelude row, which no source wrote.
    name_token: u32,
    /// The `as` alias, or the module itself when there is none (§5.2).
    alias: SymbolIndex,
    /// `exposed[exposed_start..exposed_end]` are the `exposing` names.
    exposed_start: u32,
    exposed_end: u32,
    /// One of the prelude rows (Appendix A) rather than a written import.
    prelude: bool,
};

/// A file that has not been lowered.
pub const empty: Bir = .{
    .insts = .empty,
    .extra = &.{},
    .string_bytes = &.{},
    .symbols = &.{},
    .decls = &.{},
    .ctors = &.{},
    .locals = &.{},
    .refs = &.{},
    .imports = &.{},
    .exposed = &.{},
    .interface = &.{},
    .diagnostics = &.{},
    .module_doc_start = 0,
    .module_doc_end = 0,
};

pub fn deinit(bir: *Bir, gpa: Allocator) void {
    bir.insts.deinit(gpa);
    gpa.free(bir.extra);
    gpa.free(bir.string_bytes);
    gpa.free(bir.symbols);
    gpa.free(bir.decls);
    gpa.free(bir.ctors);
    gpa.free(bir.locals);
    gpa.free(bir.refs);
    gpa.free(bir.imports);
    gpa.free(bir.exposed);
    gpa.free(bir.interface);
    gpa.free(bir.diagnostics);
    bir.* = undefined;
}

/// Rewrite every symbol from the producing worker's local numbering to the
/// session's global one (frontend.md §3.3). One loop, because `symbols` is
/// the only column that holds a symbol.
pub fn applyRemap(bir: *Bir, remap: []const Symbol) void {
    for (bir.symbols) |*s| s.* = remap[@intFromEnum(s.*)];
}

// ---- Invariants -------------------------------------------------------------

/// Whether every index this record holds points inside the array it names,
/// and whether the declaration ranges are the nested, ordered, non-
/// overlapping partition `Bir.zig`'s header promises.
///
/// **This is the whole of the defence for a Bir that did not come from
/// `Lower`** (`fast-compiler.md` §8, `plans/m4-2.md` §13 risk 1). `Reach`,
/// `js/Lower`, `Types.build` and `Emit` index `insts`, `decls`, `refs` and
/// `extra` DIRECTLY, with no bounds check — which is correct for a record the
/// builder just made and is a crash or a wrong answer for one that came off a
/// disk. A loaded artifact is checked here before it is installed; a lowered
/// one satisfies it by construction, which is what the in-source tests below
/// assert over the corpus's own fixtures.
///
/// It is a linear pass over the columns with no allocation, the shape
/// `js/JsIr.zig:529`'s `verify` already has. It checks the per-tag payloads
/// introduced for schema plans because those cached rows contain nested
/// `extra`, instruction and symbol indices. Historic expression/type payloads
/// remain the checker's responsibility. The guarantee here is the property
/// every direct reader needs — no schema plan index leaves its array — and not
/// that the program means what it meant.
///
/// `token_count` is the file's token count, because `main_token` and the
/// four `*_token` fields index the token list and not this record.
pub fn verify(bir: *const Bir, token_count: u32) bool {
    const insts_len: u32 = @intCast(bir.insts.len);
    const symbols_len: u32 = @intCast(bir.symbols.len);

    for (bir.insts.items(.main_token)) |token| {
        if (token >= token_count) return false;
    }

    var previous_end: u32 = 0;
    for (bir.decls) |d| {
        // Contiguous, in order, and inside the column: the partition
        // `Bir.zig:10-14` promises, which is what lets a declaration be
        // checked, cached or dumped on its own.
        if (d.inst_start.int() < previous_end) return false;
        if (d.inst_end.int() < d.inst_start.int()) return false;
        if (d.inst_end.int() > insts_len) return false;
        previous_end = d.inst_end.int();

        if (!inRange(d.locals_start, d.locals_end, bir.locals.len)) return false;
        if (!inRange(d.refs_start, d.refs_end, bir.refs.len)) return false;
        if (!inRange(d.ctors_start, d.ctors_end, bir.ctors.len)) return false;
        if (!inRange(d.type_params_start, d.type_params_end, bir.symbols.len)) return false;
        if (!inRange(@intFromEnum(d.params_start), @intFromEnum(d.params_end), bir.extra.len)) return false;
        if (!inRange(@intFromEnum(d.where_start), @intFromEnum(d.where_end), bir.extra.len)) return false;
        if (!validSymbol(d.name, symbols_len)) return false;
        if (!validOptionalInst(d.annotation, insts_len)) return false;
        if (!validOptionalInst(d.body, insts_len)) return false;
        if (!validOptionalInst(d.schema_body, insts_len)) return false;
        if (d.name_token >= token_count) return false;
        var schema_i = d.inst_start.int();
        while (schema_i < d.inst_end.int()) : (schema_i += 1) {
            if (!verifySchemaInst(bir, d, @enumFromInt(schema_i), symbols_len)) return false;
        }
    }

    for (bir.ctors) |c| {
        if (!validSymbol(c.name, symbols_len)) return false;
        if (c.decl.int() >= bir.decls.len) return false;
        if (!inRange(@intFromEnum(c.args_start), @intFromEnum(c.args_end), bir.extra.len)) return false;
        if (c.name_token >= token_count) return false;
    }
    for (bir.locals) |l| {
        if (!validSymbol(l.name, symbols_len)) return false;
        if (l.inst.int() >= insts_len) return false;
    }
    for (bir.imports) |i| {
        if (!validSymbol(i.module, symbols_len)) return false;
        if (!validSymbol(i.alias, symbols_len)) return false;
        if (!inRange(i.exposed_start, i.exposed_end, bir.exposed.len)) return false;
        // A prelude row names no token, because no source wrote it.
        if (!i.prelude and i.name_token >= token_count) return false;
    }
    for (bir.exposed) |e| {
        if (!validSymbol(e.name, symbols_len)) return false;
        if (e.token >= token_count) return false;
    }
    for (bir.interface) |d| {
        if (d.int() >= bir.decls.len) return false;
    }
    return true;
}

fn verifySchemaInst(bir: *const Bir, d: Decl, inst: Inst.Index, symbols_len: u32) bool {
    const data = bir.instData(inst);
    return switch (bir.instTag(inst)) {
        .schema_ref, .schema_expr_ref => data.lhs < symbols_len,
        .schema_app => inDecl(d, data.lhs) and verifyInstRangeAt(bir, d, data.rhs),
        .schema_paren, .schema_as, .schema_via => inDecl(d, data.lhs),
        .schema_record => verifyInstRange(bir, d, inlineRange(data)),
        .schema_field => blk: {
            if (data.lhs >= symbols_len or data.rhs > bir.extra.len or extraLen(SchemaField) > bir.extra.len - data.rhs) break :blk false;
            const field = bir.extraData(@enumFromInt(data.rhs), SchemaField);
            break :blk inDecl(d, field.operand.int()) and verifyInstRange(bir, d, .{ .start = field.modifiers_start, .end = field.modifiers_end });
        },
        .schema_value, .schema_tagged => inDecl(d, data.lhs) and verifyInstRangeAt(bir, d, data.rhs),
        .schema_variant => blk: {
            if (data.lhs >= symbols_len or data.rhs > bir.extra.len or extraLen(SchemaVariant) > bir.extra.len - data.rhs) break :blk false;
            const variant = bir.extraData(@enumFromInt(data.rhs), SchemaVariant);
            if (variant.payload.unwrap()) |p| if (!inDecl(d, p.int())) break :blk false;
            if (variant.rename.unwrap()) |r| if (!inDecl(d, r.int())) break :blk false;
            break :blk true;
        },
        .schema_optional, .schema_nullable => true,
        else => true,
    };
}

fn inDecl(d: Decl, raw: u32) bool {
    return raw >= d.inst_start.int() and raw < d.inst_end.int();
}

fn verifyInstRangeAt(bir: *const Bir, d: Decl, raw: u32) bool {
    if (raw > bir.extra.len or extraLen(SubRange) > bir.extra.len - raw) return false;
    return verifyInstRange(bir, d, bir.subRange(@enumFromInt(raw)));
}

fn verifyInstRange(bir: *const Bir, d: Decl, range: SubRange) bool {
    const start = @intFromEnum(range.start);
    const end = @intFromEnum(range.end);
    if (!inRange(start, end, bir.extra.len)) return false;
    for (bir.extra[start..end]) |raw| if (!inDecl(d, raw)) return false;
    return true;
}

fn inRange(start: u32, end: u32, len: usize) bool {
    return start <= end and end <= len;
}

fn validSymbol(index: SymbolIndex, symbols_len: u32) bool {
    return index == .none or @intFromEnum(index) < symbols_len;
}

fn validOptionalInst(index: Inst.OptionalIndex, insts_len: u32) bool {
    const i = index.unwrap() orelse return true;
    return i.int() < insts_len;
}

// ---- Raw access -------------------------------------------------------------

pub fn instTag(bir: *const Bir, inst: Inst.Index) Inst.Tag {
    return bir.insts.items(.tag)[inst.int()];
}

pub fn instData(bir: *const Bir, inst: Inst.Index) Inst.Data {
    return bir.insts.items(.data)[inst.int()];
}

pub fn symbol(bir: *const Bir, index: SymbolIndex) Symbol {
    return bir.symbols[@intFromEnum(index)];
}

/// The elements of a range, viewed as `T` (`Inst.Index`, `u32`, `Field`…).
pub fn extraSlice(bir: *const Bir, range: SubRange, comptime T: type) []const T {
    comptime std.debug.assert(@sizeOf(T) % 4 == 0);
    const words = bir.extra[@intFromEnum(range.start)..@intFromEnum(range.end)];
    return @ptrCast(@alignCast(words));
}

/// Read a record out of `extra` starting at `index`, field by field.
pub fn extraData(bir: *const Bir, index: ExtraIndex, comptime T: type) T {
    var i: usize = @intFromEnum(index);
    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        @field(result, field.name) = switch (@typeInfo(field.type)) {
            .@"enum" => @enumFromInt(bir.extra[i]),
            .int => bir.extra[i],
            else => @compileError("unexpected extra field type: " ++ @typeName(field.type)),
        };
        i += 1;
    }
    return result;
}

/// Number of `u32` words `T` occupies in `extra`.
pub fn extraLen(comptime T: type) u32 {
    return @intCast(std.meta.fields(T).len);
}

/// The `SubRange` stored at `index`.
pub fn subRange(bir: *const Bir, index: ExtraIndex) SubRange {
    return bir.extraData(index, SubRange);
}

/// The range stored inline in `lhs..rhs`.
pub fn inlineRange(data: Inst.Data) SubRange {
    return .{ .start = @enumFromInt(data.lhs), .end = @enumFromInt(data.rhs) };
}

/// The bytes of a `string`, `chunk`, `pat_string`, `int`, `float` or
/// `pat_int` instruction.
pub fn bytes(bir: *const Bir, inst: Inst.Index) []const u8 {
    const d = bir.instData(inst);
    return bir.string_bytes[d.lhs..][0..d.rhs];
}

pub fn decl(bir: *const Bir, index: DeclIndex) Decl {
    return bir.decls[index.int()];
}

pub fn declLocals(bir: *const Bir, d: Decl) []const Local {
    return bir.locals[d.locals_start..d.locals_end];
}

pub fn declRefs(bir: *const Bir, d: Decl) []const Ref {
    return bir.refs[d.refs_start..d.refs_end];
}

/// The operator a `lambda` instruction is the desugaring of
/// (static-dispatch-spike.md §3.1, Appendix A.22: `(==)` is
/// `\a b -> a == b`), or null for a lambda someone wrote.
///
/// Matched on SHAPE, with nothing stored on the instruction: two
/// parameters, both COMPILER-MADE locals (`Local.Kind.fresh` — a
/// hand-written `\a b -> a == b` binds named locals and is not this), over
/// a `method_call` whose origin is an operator. Both the checker (which
/// pins such a lambda's type, and reads a saturated one as the operator
/// call it stands for) and the diagnostics (which name the operator) ask
/// this one question, so they cannot drift apart.
///
/// `locals_base` is where the enclosing declaration's locals start in the
/// module-wide table, because a `pat_var`'s index is relative to its
/// declaration.
pub fn operatorSection(bir: *const Bir, inst: Inst.Index, locals_base: u32) ?WellKnown {
    if (inst.int() >= bir.insts.len or bir.instTag(inst) != .lambda) return null;
    const data = bir.instData(inst);
    const params = bir.extraSlice(bir.subRange(@enumFromInt(data.lhs)), Inst.Index);
    if (params.len != 2) return null;
    const body: Inst.Index = @enumFromInt(data.rhs);
    if (body.int() >= bir.insts.len or bir.instTag(body) != .method_call) return null;
    for (params) |p| {
        if (p.int() >= bir.insts.len or bir.instTag(p) != .pat_var) return null;
        const local = locals_base + bir.instData(p).lhs;
        if (local >= bir.locals.len or bir.locals[local].kind != .fresh) return null;
    }
    const m = bir.extraData(@enumFromInt(bir.instData(body).rhs), MethodCall);
    return if (m.origin == .none) null else m.origin;
}

/// The constraints of a declaration's `where` clause, in source order.
pub fn declWhere(bir: *const Bir, d: Decl) []const WhereConstraint {
    return bir.extraSlice(d.whereRange(), WhereConstraint);
}

pub fn declCtors(bir: *const Bir, d: Decl) []const Ctor {
    return bir.ctors[d.ctors_start..d.ctors_end];
}

pub fn declTypeParams(bir: *const Bir, d: Decl) []const Symbol {
    return bir.symbols[d.type_params_start..d.type_params_end];
}

pub fn importExposed(bir: *const Bir, imp: Import) []const Exposed {
    return bir.exposed[imp.exposed_start..imp.exposed_end];
}

// ---------------------------------------------------------------------------
// Tests. `Lower.zig` exercises every kind against real trees; here only the
// record machinery and the remap are checked in isolation.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extraData reads records positionally and extraLen agrees" {
    try testing.expectEqual(@as(u32, 2), extraLen(SubRange));
    try testing.expectEqual(@as(u32, 4), extraLen(LetDef));
    const words = [_]u32{ 3, std.math.maxInt(u32), 7, 9, 5, 6 };
    var bir: Bir = empty;
    bir.extra = &words;
    const d = bir.extraData(@enumFromInt(0), LetDef);
    try testing.expectEqual(@as(u32, 3), d.local);
    try testing.expectEqual(@as(?Inst.Index, null), d.annotation.unwrap());
    try testing.expectEqual(@as(u32, 7), @intFromEnum(d.params_start));
    try testing.expectEqual(@as(u32, 9), @intFromEnum(d.params_end));
    const r = bir.subRange(@enumFromInt(4));
    try testing.expectEqual(@as(u32, 1), r.len());
    const fields = bir.extraSlice(.{ .start = @enumFromInt(2), .end = @enumFromInt(4) }, Field);
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqual(@as(u32, 7), @intFromEnum(fields[0].name));
    try testing.expectEqual(@as(u32, 9), fields[0].value.int());
}

test "applyRemap rewrites the symbol column and nothing else needs to know" {
    var symbols = [_]Symbol{ @enumFromInt(0), @enumFromInt(2), @enumFromInt(1) };
    var bir: Bir = empty;
    bir.symbols = &symbols;
    bir.applyRemap(&.{ @enumFromInt(10), @enumFromInt(11), @enumFromInt(12) });
    try testing.expectEqual(@as(Symbol, @enumFromInt(10)), bir.symbol(@enumFromInt(0)));
    try testing.expectEqual(@as(Symbol, @enumFromInt(12)), bir.symbol(@enumFromInt(1)));
    try testing.expectEqual(@as(Symbol, @enumFromInt(11)), bir.symbol(@enumFromInt(2)));
}

test "pattern and type tag ranges" {
    try testing.expect(Inst.Tag.pat_var.isPattern());
    try testing.expect(Inst.Tag.pat_as.isPattern());
    try testing.expect(!Inst.Tag.@"error".isPattern());
    try testing.expect(Inst.Tag.type_record_ext.isType());
    try testing.expect(!Inst.Tag.int.isType());
}
