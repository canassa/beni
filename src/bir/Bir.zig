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

        // ---- Types -----------------------------------------------------

        /// A type variable. `lhs` is its `SymbolIndex`; `rhs` is the index
        /// of the declaring type parameter in a `type`/`type alias`/
        /// `foreign type` body, or `maxInt(u32)` in an annotation, where
        /// variables are implicitly quantified (§7).
        type_var,
        /// A type or alias of this module. `lhs` is the `DeclIndex`.
        type_top,
        /// A type from an `exposing` list or the prelude. `lhs` module
        /// `SymbolIndex`, `rhs` name.
        type_import,
        /// `Alias.Type`. `lhs` module, `rhs` name.
        type_qualified,
        /// A type applied to arguments, `Maybe a`. `lhs` is the type
        /// reference; `rhs` is extra `SubRange` of argument type insts.
        type_app,
        /// `a -> b`. `lhs` parameter, `rhs` result.
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
    };
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
    is_pub: bool,
    /// `pub opaque type`: the constructors are hidden from the interface.
    is_opaque: bool,
    /// Comment indices `[doc_start, doc_end)` of the attached `--|` block
    /// (plain comments inside the range are trivia).
    doc_start: u32,
    doc_end: u32,
    /// Values: the number of parameters. Types, aliases, foreign types: the
    /// number of type parameters.
    params: u32,
    /// Values: `SubRange` of parameter pattern instructions. Types: the
    /// range of parameter names in `symbols` (`type_params_start..end`).
    params_start: ExtraIndex,
    params_end: ExtraIndex,
    /// Type declarations: the parameter names as `symbols[start..end]`.
    type_params_start: u32,
    type_params_end: u32,
    /// `value` with an annotation, `annotation_only`, `foreign_value`: the
    /// annotation's type. `type_alias`: the aliased type. Else none.
    annotation: Inst.OptionalIndex,
    /// `value`: the body expression. Else none.
    body: Inst.OptionalIndex,
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

        /// True for the kinds that declare a name in the value namespace.
        pub fn isValue(k: Kind) bool {
            return switch (k) {
                .value, .annotation_only, .foreign_value => true,
                .type, .type_alias, .foreign_type => false,
            };
        }

        pub fn isForeign(k: Kind) bool {
            return k == .foreign_value or k == .foreign_type;
        }
    };

    pub fn hasAnnotation(d: Decl) bool {
        return d.annotation != .none;
    }
};

pub const Ctor = struct {
    name: SymbolIndex,
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

pub const Import = struct {
    module: SymbolIndex,
    /// The `as` alias, or the module itself when there is none (§5.2).
    alias: SymbolIndex,
    /// `symbols[exposed_start..exposed_end]` are the `exposing` names.
    exposed_start: u32,
    exposed_end: u32,
    /// One of the prelude rows (Appendix A) rather than a written import.
    prelude: bool,
};

/// A file that has not been lowered.
pub const empty: Bir = .{
    .insts = .{ .ptrs = undefined, .len = 0, .capacity = 0 },
    .extra = &.{},
    .string_bytes = &.{},
    .symbols = &.{},
    .decls = &.{},
    .ctors = &.{},
    .locals = &.{},
    .refs = &.{},
    .imports = &.{},
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

pub fn declCtors(bir: *const Bir, d: Decl) []const Ctor {
    return bir.ctors[d.ctors_start..d.ctors_end];
}

pub fn declTypeParams(bir: *const Bir, d: Decl) []const Symbol {
    return bir.symbols[d.type_params_start..d.type_params_end];
}

pub fn importExposed(bir: *const Bir, imp: Import) []const Symbol {
    return bir.symbols[imp.exposed_start..imp.exposed_end];
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
