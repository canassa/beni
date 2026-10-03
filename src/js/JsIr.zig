//! The second IR (docs/design/backend.md §3, fast-compiler.md §9.2): a
//! JavaScript-shaped tree, flat, that `js/Lower.zig` builds from a checked
//! module's `Bir` and `js/Print.zig` turns into bytes.
//!
//! **Why a second IR at all** is §9.2: Elm's author measured lowering
//! straight to a byte builder as neutral for throughput and kept the
//! intermediate form anyway, because the peephole and specialisation passes
//! have to pattern-match on generated structure. The release optimiser is
//! that pass list; this IR's job is to give it something to match on.
//!
//! Shape, after `Bir` and `std.zig.Zir`: one `MultiArrayList(Node)` of
//! `{tag, pos, lhs, rhs}` records plus one `extra: []u32` sidecar for
//! everything variable-length, one `string_bytes` for literal text, and one
//! `names` column. Every reference is a `u32` index into a named array
//! wrapped in an `enum(u32)`; there is no pointer and no slice anywhere, so
//! a node is trivially copyable and a cache can map the whole thing.
//!
//! **Names are `Name`s, never strings** (§3). A `Name` is a pair of
//! interned `Symbol`s — an optional module qualifier and a base — plus a
//! disambiguator. Renaming under `--release` is then a rewrite of the `names` column
//! and of nothing else: no node holds text, and two names are equal exactly
//! when their `NameIndex`es are. The printer is the only thing that turns a
//! `Name` back into bytes.
//!
//! **Every node carries a source position from the start** (§9.6), a byte
//! offset into the module's source or `Node.no_pos` for a node the lowering
//! invented. It is what a development build's source map is made of
//! (backend.md §11.1, `js/SourceMap.zig`), and it was here before the maps
//! were: Elm never threaded positions through codegen and consequently
//! has no source maps at all, and retrofitting one means touching every
//! pass rather than only the printer. An offset and not a `{line, col}`
//! because §5 rule 4 says offsets, and the line table is already in the
//! `SourceStore`.
//!
//! Statements and expressions share one node array and one `Tag` enum, the
//! way `Ast` and `Bir` do; `Tag.isStatement` separates them, and `verify`
//! checks that a statement never appears where an expression belongs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");

const JsIr = @This();

pub const Symbol = InternPool.Symbol;

/// Owned. All nodes of one module, statements and expressions together.
nodes: NodeList.Slice,
/// Owned. Ranges and multi-word payloads, indexed from node data.
extra: []const u32,
/// Owned. Literal text: number spellings verbatim, decoded string bytes.
string_bytes: []const u8,
/// Owned. The one name column; every name-carrying slot is a `NameIndex`
/// into it, so `--release` renaming is a rewrite of this array alone.
names: []const Name,
/// The module's top-level statements, in emission order: the `import`s
/// first, then one declaration per emitted value, then one `export`.
body: SubRange,

pub const NodeList = std.MultiArrayList(Node);

pub const Node = struct {
    tag: Tag,
    /// Byte offset into the module's source, or `no_pos`.
    pos: u32,
    data: Data,

    /// Meaning depends on `tag`; see `Tag`. Unused halves are zero.
    pub const Data = struct {
        lhs: u32,
        rhs: u32,

        pub const unused: u32 = 0;
    };

    /// A node the lowering invented rather than found in the source: the
    /// temporaries a `case` needs, the `import` and `export` statements, the
    /// wrapper around a constructor used as a value. Printed the same; a
    /// source map skips it.
    pub const no_pos: u32 = std.math.maxInt(u32);

    /// `arrow`'s `rhs`: an ordinary arrow, or one whose last parameter
    /// defaults to `0`.
    pub const arrow_plain: u32 = 0;
    pub const arrow_depth: u32 = 1;
    /// `function () { … }`: a method, whose body may read `this_lit`
    /// (`Js.method`, `backend.md` §4, *`Js.method` is a `function`*). It
    /// takes no parameter and is always printed with a block body.
    pub const arrow_method: u32 = 2;

    pub const Index = enum(u32) {
        _,

        pub inline fn int(i: Index) u32 {
            return @backingInt(i);
        }

        pub inline fn toOptional(i: Index) OptionalIndex {
            const o: OptionalIndex = @fromBackingInt(@intCast(@backingInt(i)));
            std.debug.assert(o != .none);
            return o;
        }
    };

    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub inline fn unwrap(o: OptionalIndex) ?Index {
            return if (o == .none) null else @fromBackingInt(@intCast(@backingInt(o)));
        }
    };

    comptime {
        std.debug.assert(@sizeOf(Tag) == 1);
        std.debug.assert(@sizeOf(Data) == 8);
    }

    /// Every node kind. Statements come first so `isStatement` is a range
    /// test; each comment says what `lhs` and `rhs` hold. "Inline range"
    /// means a `SubRange` stored as `lhs..rhs`; "extra `T`" means the half
    /// is the `ExtraIndex` of a `T` record.
    pub const Tag = enum(u8) {
        // ---- Statements ------------------------------------------------

        /// `import { a, b } from "./M.mjs";`. `lhs` is extra `Import`.
        import_stmt,
        /// `export { a, b };`. Inline range of `NameIndex` words.
        export_stmt,
        /// `const name = value;`. `lhs` is a `NameIndex`, `rhs` the value.
        const_decl,
        /// `let name;` or `let name = value;`. `lhs` is a `NameIndex`,
        /// `rhs` an `OptionalIndex`. The `case` lowering needs the
        /// uninitialised form: one `let` above an `if`/`else` chain whose
        /// arms each assign it.
        let_decl,
        /// `function name(a, b) { … }`. `lhs` is a `NameIndex`, `rhs` is
        /// extra `Func`. A `let` whose bindings are mutually recursive
        /// becomes these (backend.md §4), because a `const` is not hoisted
        /// and the first body would close over a dead zone.
        func_decl,
        /// `function* name(a, b) { … }`: the STEPS twin of a derived `eq` or
        /// `compare` (`backend.md` §4, *Derived comparisons do not grow the
        /// native stack*), which the engine resumes instead of recursing.
        /// Payload as `func_decl`.
        gen_decl,
        /// `target = value;`. `lhs` target expression, `rhs` value.
        assign_stmt,
        /// `return;` or `return value;`. `lhs` is an `OptionalIndex`.
        return_stmt,
        /// `if (cond) { … } else { … }`. `lhs` condition, `rhs` extra `If`.
        if_stmt,
        /// `label: while (true) { … }` — the tail-call loop of §8. `lhs` is a `NameIndex` (the label, or `.none`), `rhs`
        /// is extra `SubRange` of statements.
        while_true,
        /// `for (const x of e) { … }`, which only the `Js.each` intrinsic
        /// writes. `lhs` is the loop variable's `NameIndex`, `rhs` extra
        /// `ForOf`.
        for_of,
        /// `break label;` / `continue label;`. `lhs` is a `NameIndex` or
        /// `.none`.
        break_stmt,
        continue_stmt,
        /// `switch (d) { … }`, the multi-way constructor test of §7. `lhs`
        /// discriminant, `rhs` extra `SubRange` of `switch_case` nodes.
        switch_stmt,
        /// `case test:` / `default:`. `lhs` is an `OptionalIndex` (`.none`
        /// is `default`), `rhs` is extra `SubRange` of statements.
        switch_case,
        /// `label: { … }`, or `{ … }` when `lhs` is `.none`. `lhs` is a
        /// `NameIndex`, `rhs` is extra `SubRange` of statements.
        ///
        /// Both halves of §7 need it: a shared leaf is reached by
        /// `break $j$<d>$<b>` out of the labelled block that ends just
        /// before it, and a `switch` case body is a block so that two
        /// sibling cases cannot redeclare one name in the single scope a
        /// `switch` gives all of them.
        block_stmt,
        /// `expr;`.
        expr_stmt,
        /// `throw expr;`.
        throw_stmt,
        /// `try { … } finally { … }`, which only the `Js.finally` intrinsic
        /// writes (`backend.md` §4, *`Js.finally` is `try … finally`*).
        /// `lhs` unused, `rhs` extra `Try`. Last of the statements, so
        /// `isStatement` stays a range test.
        try_stmt,

        // ---- Expressions -----------------------------------------------

        /// A name. `lhs` is a `NameIndex`.
        ident,
        /// A numeric literal, spelled exactly as the source spelled it
        /// (`lhs` offset, `rhs` length into `string_bytes`). beni's integer
        /// and float syntax is a subset of JavaScript's, so nothing
        /// re-formats a number and no rounding happens in the compiler.
        number,
        /// A string literal: raw decoded bytes (`lhs` offset, `rhs`
        /// length). The printer escapes; the IR holds the value.
        string,
        /// `` `a${b}c` ``. Inline range of parts in order, exactly as
        /// `Bir.interp` holds them: a `template_chunk` is literal text,
        /// anything else is an interpolated expression.
        template,
        /// A literal run inside a `template`; payload like `string`.
        template_chunk,
        /// `/pattern/flags`, which only the `Js.regExp` intrinsic writes
        /// (`backend.md` §4, *`Js.regExp` is a literal*): the literal's
        /// whole text, already escaped for a regular expression literal
        /// (`lhs` offset, `rhs` length into `string_bytes`), printed
        /// verbatim. Not a constant: each evaluation is a new object, so no
        /// pass folds, compares or copies it as one.
        regex,
        true_lit,
        false_lit,
        null_lit,
        undefined_lit,
        /// `globalThis`, which only the `Js.global` intrinsic writes (research
        /// 47). A literal and not an `ident`, so no pass renames it.
        global_this,
        /// `this`: the receiver of an `arrow_method` (`Js.method`, `backend.md`
        /// §4, *`Js.method` is a `function`*).
        this_lit,
        /// `f(a, b)`. `lhs` callee, `rhs` extra `SubRange` of arguments.
        call,
        /// `new C(a, b)`, which only the `Js.construct` intrinsic writes.
        /// Payload as `call`.
        new_call,
        /// `obj.name`. `lhs` object, `rhs` a `NameIndex`.
        member,
        /// `obj[index]`. `lhs` object, `rhs` index expression.
        index_get,
        /// `{ a: 1, b: 2 }`. Inline range of `property` nodes.
        object,
        /// One `key: value` of an `object`. `lhs` is a `NameIndex`, `rhs`
        /// the value.
        property,
        /// `...expr` inside an `object`: what record update lowers to
        /// (backend.md §4). Spreading the original FIRST and overriding
        /// after keeps the key order of the record being updated, which is
        /// what keeps one hidden class per record type (§9.4). `lhs` is the
        /// spread expression.
        spread_property,
        /// `[a, b]`. Inline range of elements.
        array,
        /// `(a, b) => …`. `lhs` is extra `Func`; `rhs` is `arrow_plain`, or
        /// `arrow_depth` for a derived comparison whose LAST parameter is
        /// its depth and prints `$d = 0` (`backend.md` §4, *Derived
        /// comparisons do not grow the native stack*).
        arrow,
        /// `test ? a : b`. `lhs` test, `rhs` extra `Cond`.
        cond,
        /// A binary operator. `lhs` is extra `Binary`, `rhs` is the
        /// `@intFromEnum` of a `BinaryOp`.
        binary,
        /// A prefix operator. `lhs` operand, `rhs` is the `@intFromEnum`
        /// of a `UnaryOp`.
        unary,

        /// Whether the tag is a statement (the leading run of this enum).
        pub fn isStatement(t: Tag) bool {
            return @backingInt(t) <= @backingInt(Tag.try_stmt);
        }
    };
};

/// The operators the printer knows. Deliberately short: §9 of backend.md
/// builds the peephole that turns a call of `Basics.add` into `+` at emit
/// time, and everything past this list is a call.
pub const BinaryOp = enum(u8) {
    add,
    sub,
    mul,
    div,
    rem,
    /// `===` and `!==`, never `==`: beni's `==` is structural and goes
    /// through core's `eq`, so the only identity test the emitter makes is
    /// against a tag or a primitive it produced itself.
    strict_eq,
    strict_ne,
    lt,
    le,
    gt,
    ge,
    logical_and,
    logical_or,
    /// `|`, which `Int32` needs (`x | 0`).
    bit_or,
    /// `&`, the `Js.bitAnd` intrinsic (research 47).
    bit_and,
    /// `==`, which only the `Js.isNullish` intrinsic writes, and only
    /// against `null` (research 47).
    loose_eq,
    /// `**`, which `Basics.pow` is (`backend.md` §4, *Arithmetic is an
    /// operator*). Right-associative, and its left operand may not be a
    /// unary expression — `-a ** b` is a syntax error — so it brackets
    /// unlike every other operator here (`leftPrecedence`).
    pow,
    /// `^`, `<<`, `>>` and `>>>`: `Int32`'s bitwise operations, written in
    /// place (`backend.md` §4).
    bit_xor,
    shl,
    sar,
    shr,
    /// `instanceof`, which only the `Js.instanceOf` intrinsic writes: the
    /// precise test a `Js.catchIf` predicate makes of what was thrown
    /// (`CLAUDE.md` rule 9).
    instance_of,

    /// JavaScript's precedence, higher binds tighter. The printer
    /// parenthesises on it rather than carrying `paren` nodes, so the IR
    /// holds structure and the bytes hold syntax.
    pub fn precedence(op: BinaryOp) u8 {
        return switch (op) {
            .pow => 14,
            .mul, .div, .rem => 13,
            .add, .sub => 12,
            .shl, .sar, .shr => 11,
            .lt, .le, .gt, .ge, .instance_of => 10,
            .strict_eq, .strict_ne, .loose_eq => 9,
            .bit_and => 8,
            .bit_xor => 7,
            .bit_or => 6,
            .logical_and => 5,
            .logical_or => 4,
        };
    }

    /// The least precedence the LEFT operand may have unbracketed. Every
    /// operator but `**` is left-associative, so its left operand may be of
    /// its own precedence. `**` is right-associative and refuses a unary
    /// left operand outright, so its left operand must bind tighter than a
    /// unary expression (the printer's `prec_unary`, 15): `(-a) ** b`,
    /// `(a ** b) ** c`.
    pub fn leftPrecedence(op: BinaryOp) u8 {
        return if (op == .pow) 16 else op.precedence();
    }

    /// The least precedence the RIGHT operand may have unbracketed: one
    /// above the operator's own for a left-associative operator, so
    /// `a - (b - c)` keeps its brackets; the operator's own for `**`, so
    /// `a ** b ** c` is `a ** (b ** c)` with none.
    pub fn rightPrecedence(op: BinaryOp) u8 {
        return if (op == .pow) op.precedence() else op.precedence() + 1;
    }

    pub fn text(op: BinaryOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .rem => "%",
            .strict_eq => "===",
            .strict_ne => "!==",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .logical_and => "&&",
            .logical_or => "||",
            .bit_or => "|",
            .bit_and => "&",
            .loose_eq => "==",
            .pow => "**",
            .bit_xor => "^",
            .shl => "<<",
            .sar => ">>",
            .shr => ">>>",
            .instance_of => "instanceof",
        };
    }
};

pub const UnaryOp = enum(u8) {
    /// `-x`.
    neg,
    /// `!x`.
    not,
    /// `typeof x`.
    type_of,
    /// `yield x`, inside a `gen_decl` only. It binds as loosely as an
    /// assignment, so the printer brackets it everywhere but a `const`'s
    /// value, a `return` and an argument (`Print.precedence`).
    yield,

    pub fn text(op: UnaryOp) []const u8 {
        return switch (op) {
            .neg => "-",
            .not => "!",
            .type_of => "typeof ",
            .yield => "yield ",
        };
    }

    /// The compact printer's spelling: a keyword without its space, which
    /// the adjacency guard puts back only where the next token needs it.
    pub fn compactText(op: UnaryOp) []const u8 {
        return switch (op) {
            .type_of => "typeof",
            .yield => "yield",
            else => op.text(),
        };
    }
};

/// An identifier, as two interned symbols and a disambiguator rather than
/// as text. The printer spells it `Module$base` (dots in the module name
/// become `$`, so `Json.Decode.map` is `Json$Decode$map`) and appends
/// `$<tag>` when `tag` is not `no_tag`.
///
/// Why a pair and not one interned `"Module$base"`: interning the
/// concatenation would put a string build on the hot path of every
/// reference, and would make `--release`'s rename a string rewrite instead of a
/// symbol swap. Why a disambiguator: two locals in sibling branches of one
/// function can share a source name, and JavaScript's scoping is not
/// beni's.
pub const Name = struct {
    module: Symbol.Optional,
    base: Symbol,
    tag: u32,

    pub const no_tag: u32 = 0;
    /// A beni record's field name, as a key or a read (`backend.md` §9,
    /// *Item 4, taken up*): printed as its text, and under `--release` as
    /// the short spelling the build gave the field, unless the field is
    /// pinned. No counter reaches it, so it disambiguates nothing.
    pub const field: u32 = std.math.maxInt(u32);

    pub fn isField(n: Name) bool {
        return n.module == .none and n.tag == field;
    }

    pub fn local(base: Symbol) Name {
        return .{ .module = .none, .base = base, .tag = no_tag };
    }

    pub fn qualified(module: Symbol, base: Symbol) Name {
        return .{ .module = module.toOptional(), .base = base, .tag = no_tag };
    }

    pub fn eql(a: Name, b: Name) bool {
        return a.module == b.module and a.base == b.base and a.tag == b.tag;
    }
};

/// Index into `names`.
pub const NameIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub inline fn int(i: NameIndex) u32 {
        return @backingInt(i);
    }

    pub inline fn unwrap(i: NameIndex) ?u32 {
        return if (i == .none) null else @backingInt(i);
    }
};

/// Index into `extra`.
pub const ExtraIndex = enum(u32) { _ };

/// A half-open range `[start, end)` of `extra`.
pub const SubRange = struct {
    start: ExtraIndex,
    end: ExtraIndex,

    pub const empty: SubRange = .{ .start = @fromBackingInt(@intCast(0)), .end = @fromBackingInt(@intCast(0)) };

    pub fn len(r: SubRange) u32 {
        return @backingInt(r.end) - @backingInt(r.start);
    }
};

/// Payload of `func_decl` and `arrow`: the parameter names and the body
/// statements, both ranges into `extra`.
pub const Func = struct {
    params_start: ExtraIndex,
    params_end: ExtraIndex,
    body_start: ExtraIndex,
    body_end: ExtraIndex,

    pub fn params(f: Func) SubRange {
        return .{ .start = f.params_start, .end = f.params_end };
    }

    pub fn body(f: Func) SubRange {
        return .{ .start = f.body_start, .end = f.body_end };
    }
};

/// Payload of `if_stmt`.
pub const If = struct {
    then_start: ExtraIndex,
    then_end: ExtraIndex,
    else_start: ExtraIndex,
    else_end: ExtraIndex,

    pub fn thenBody(i: If) SubRange {
        return .{ .start = i.then_start, .end = i.then_end };
    }

    pub fn elseBody(i: If) SubRange {
        return .{ .start = i.else_start, .end = i.else_end };
    }
};

/// Payload of `for_of`: what it iterates, and the body statements.
pub const ForOf = struct {
    iterable: Node.Index,
    body_start: ExtraIndex,
    body_end: ExtraIndex,

    pub fn body(f: ForOf) SubRange {
        return .{ .start = f.body_start, .end = f.body_end };
    }
};

/// Payload of `try_stmt`: the guarded statements, the statements that
/// run after them however they end, and the `catch` clause. The layout of
/// `If` for the first two ranges, so a pass that rewrites a list in place
/// finds the second range two words in and the third four words in.
///
/// `Js.finally` writes a `try` with no `catch` (`catch_name` is `.none` and
/// the range empty); `Js.catchIf` one with an empty `finally` range, which
/// prints no `finally` (`backend.md` §4, *`Js.catchIf` is `try … catch`*).
pub const Try = struct {
    body_start: ExtraIndex,
    body_end: ExtraIndex,
    final_start: ExtraIndex,
    final_end: ExtraIndex,
    catch_start: ExtraIndex,
    catch_end: ExtraIndex,
    /// The `catch` binding, or `.none` when there is no `catch` clause.
    catch_name: NameIndex,

    pub fn body(t: Try) SubRange {
        return .{ .start = t.body_start, .end = t.body_end };
    }

    pub fn finalBody(t: Try) SubRange {
        return .{ .start = t.final_start, .end = t.final_end };
    }

    pub fn catchBody(t: Try) SubRange {
        return .{ .start = t.catch_start, .end = t.catch_end };
    }

    /// Whether the statement has a `catch` clause.
    pub fn catches(t: Try) bool {
        return t.catch_name != .none;
    }

    /// Whether the statement has a `finally` clause: a `try` with a `catch`
    /// and an empty cleanup writes none.
    pub fn hasFinally(t: Try) bool {
        return !t.catches() or t.final_start != t.final_end;
    }
};

/// Payload of `cond`.
pub const Cond = struct {
    consequent: Node.Index,
    alternate: Node.Index,
};

/// Payload of `binary`. The operator rides in the node's `rhs`, so a
/// binary node costs two `extra` words and not three.
pub const Binary = struct {
    left: Node.Index,
    right: Node.Index,
};

/// Payload of `import_stmt`: the module specifier as an offset into
/// `string_bytes` (rule 4 — an offset, not a slice) and the imported
/// bindings as a range of `Specifier` pairs.
pub const Import = struct {
    source_start: u32,
    source_len: u32,
    specs_start: ExtraIndex,
    specs_end: ExtraIndex,

    pub fn specs(i: Import) SubRange {
        return .{ .start = i.specs_start, .end = i.specs_end };
    }
};

/// One `import { imported as local }` binding. The pair exists because a
/// sibling JavaScript file exports a foreign value under its BARE name
/// (`add`, boundary.md §4) while the emitted module refers to it by its
/// module-qualified one (`Basics$add`). When the two are equal the printer
/// writes the name once.
pub const Specifier = struct {
    imported: NameIndex,
    local: NameIndex,

    pub const words = 2;
};

/// A module that emitted nothing.
pub const empty: JsIr = .{
    .nodes = .empty,
    .extra = &.{},
    .string_bytes = &.{},
    .names = &.{},
    .body = .empty,
};

pub fn deinit(ir: *JsIr, gpa: Allocator) void {
    ir.nodes.deinit(gpa);
    gpa.free(ir.extra);
    gpa.free(ir.string_bytes);
    gpa.free(ir.names);
    ir.* = undefined;
}

// ---- Raw access -------------------------------------------------------------

// Every pass asks these per node, so they are `inline`: Zig's own backend,
// which builds the compiler the test suites run, inlines nothing on its own,
// and a call per ask was a tenth of emitting a wide module. `tag` and `data`
// read the column pointer directly, since `Slice.items` builds a whole
// slice for each ask; the bounds check stays.

pub inline fn tag(ir: *const JsIr, node: Node.Index) Node.Tag {
    if (node.int() >= ir.nodes.len) unreachable;
    const tags: [*]const Node.Tag = @ptrCast(ir.nodes.ptrs[@backingInt(NodeList.Field.tag)]);
    return tags[node.int()];
}

pub inline fn data(ir: *const JsIr, node: Node.Index) Node.Data {
    if (node.int() >= ir.nodes.len) unreachable;
    const datas: [*]const Node.Data = @ptrCast(@alignCast(ir.nodes.ptrs[@backingInt(NodeList.Field.data)]));
    return datas[node.int()];
}

pub inline fn pos(ir: *const JsIr, node: Node.Index) u32 {
    return ir.nodes.items(.pos)[node.int()];
}

pub inline fn name(ir: *const JsIr, index: NameIndex) Name {
    return ir.names[index.int()];
}

/// Replace one row of the name column, which this IR owns. For a pass that
/// re-interns a name's symbols into another pool, with the same text: the
/// emitter moves a module's whole-program names from the module's overlay
/// into the session's pool before `--release` numbers them.
pub fn setName(ir: *JsIr, index: NameIndex, n: Name) void {
    const names: []Name = @constCast(ir.names);
    names[index.int()] = n;
}

/// The bytes of a `number`, `string` or `template_chunk` node.
pub fn bytes(ir: *const JsIr, node: Node.Index) []const u8 {
    const d = ir.data(node);
    return ir.string_bytes[d.lhs..][0..d.rhs];
}

/// The elements of a range, viewed as `T` (`Node.Index`, `NameIndex`, `u32`).
pub inline fn extraSlice(ir: *const JsIr, range: SubRange, comptime T: type) []const T {
    comptime std.debug.assert(@sizeOf(T) % 4 == 0 and @alignOf(T) == 4);
    const words = ir.extra[@backingInt(range.start)..@backingInt(range.end)];
    return @ptrCast(@alignCast(words));
}

/// Read a record out of `extra` starting at `index`, field by field.
pub inline fn extraData(ir: *const JsIr, index: ExtraIndex, comptime T: type) T {
    var i: usize = @backingInt(index);
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| {
        @field(result, field_name) = switch (@typeInfo(field_type)) {
            .@"enum" => @fromBackingInt(@intCast(ir.extra[i])),
            .int => ir.extra[i],
            else => @compileError("unexpected extra field type: " ++ @typeName(field_type)),
        };
        i += 1;
    }
    return result;
}

pub fn extraLen(comptime T: type) u32 {
    return @intCast(@typeInfo(T).@"struct".field_names.len);
}

/// The `SubRange` stored at `index`.
pub inline fn subRange(ir: *const JsIr, index: ExtraIndex) SubRange {
    return ir.extraData(index, SubRange);
}

/// The range stored inline in `lhs..rhs`.
pub inline fn inlineRange(d: Node.Data) SubRange {
    return .{ .start = @fromBackingInt(@intCast(d.lhs)), .end = @fromBackingInt(@intCast(d.rhs)) };
}

/// Push the operand expressions of expression `node` onto `stack` in
/// REVERSE print order, so that popping them visits them in print order.
///
/// This is how a pass walks an expression without one stack frame per link:
/// the tree is as deep as the longest chain the compiler built — a
/// derived `eq` over a 60 000-field record is one `&&` 60 000 deep — so every walker keeps its own
/// explicit stack and asks this for the children. A leaf pushes nothing, and
/// so does an `arrow`: its body is a statement list, which each caller walks
/// in its own way (or, for `Opt.exprUses`, deliberately not at all).
pub inline fn pushOperands(ir: *const JsIr, gpa: Allocator, stack: *std.ArrayList(Node.Index), node: Node.Index) Allocator.Error!void {
    const d = ir.data(node);
    switch (ir.tag(node)) {
        .member, .unary, .spread_property => try pushAll(gpa, stack, &.{@fromBackingInt(@intCast(d.lhs))}),
        .index_get => try pushAll(gpa, stack, &.{ @fromBackingInt(@intCast(d.rhs)), @fromBackingInt(@intCast(d.lhs)) }),
        .property => try pushAll(gpa, stack, &.{@fromBackingInt(@intCast(d.rhs))}),
        .call, .new_call => {
            try pushReversed(gpa, stack, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Node.Index));
            try pushAll(gpa, stack, &.{@fromBackingInt(@intCast(d.lhs))});
        },
        .object, .array, .template => try pushReversed(gpa, stack, ir.extraSlice(inlineRange(d), Node.Index)),
        .cond => {
            const c = ir.extraData(@fromBackingInt(@intCast(d.rhs)), Cond);
            try pushAll(gpa, stack, &.{ c.alternate, c.consequent, @fromBackingInt(@intCast(d.lhs)) });
        },
        .binary => {
            const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), Binary);
            try pushAll(gpa, stack, &.{ b.right, b.left });
        },
        // Leaves; an `arrow`, whose body each caller walks itself; and the
        // statements, which are no expression's operand. Listed, not `else`,
        // so a new tag is a compile error here and in both printers.
        .ident, .number, .string, .template_chunk, .regex, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .this_lit, .arrow => {},
        .import_stmt, .export_stmt, .const_decl, .let_decl, .func_decl, .gen_decl, .assign_stmt, .return_stmt, .if_stmt, .while_true, .for_of, .break_stmt, .continue_stmt, .switch_stmt, .switch_case, .block_stmt, .expr_stmt, .throw_stmt, .try_stmt => {},
    }
}

// The walkers push and pop a node at a time, a million times over a wide
// module, so these write the stack's items in place: `append` is three
// calls deep, none of which Zig's own backend inlines.

/// Push `items` in order.
inline fn pushAll(gpa: Allocator, stack: *std.ArrayList(Node.Index), items: []const Node.Index) Allocator.Error!void {
    const at = stack.items.len;
    if (stack.capacity - at < items.len) try stack.ensureUnusedCapacity(gpa, items.len);
    stack.items.len = at + items.len;
    // One to three nodes: element by element, where `@memcpy` is a call.
    for (items, 0..) |item, i| stack.items.ptr[at + i] = item;
}

pub inline fn pushReversed(gpa: Allocator, stack: *std.ArrayList(Node.Index), items: []const Node.Index) Allocator.Error!void {
    const at = stack.items.len;
    if (stack.capacity - at < items.len) try stack.ensureUnusedCapacity(gpa, items.len);
    stack.items.len = at + items.len;
    const into = stack.items[at..];
    for (items, 0..) |item, i| into[items.len - 1 - i] = item;
}

/// Push one node onto a walker's stack: `append` without its calls.
pub inline fn pushOperand(gpa: Allocator, stack: *std.ArrayList(Node.Index), node: Node.Index) Allocator.Error!void {
    const at = stack.items.len;
    if (stack.capacity == at) try stack.ensureUnusedCapacity(gpa, 1);
    stack.items.len = at + 1;
    stack.items.ptr[at] = node;
}

/// Push `items` in order onto a walker's stack: `appendSlice` without its
/// calls.
pub inline fn pushOperandSlice(gpa: Allocator, stack: *std.ArrayList(Node.Index), items: []const Node.Index) Allocator.Error!void {
    const at = stack.items.len;
    if (stack.capacity - at < items.len) try stack.ensureUnusedCapacity(gpa, items.len);
    stack.items.len = at + items.len;
    for (items, 0..) |item, i| stack.items.ptr[at + i] = item;
}

/// The top of a walker's stack, taken off; null when it is empty. What
/// `ArrayList.pop` does, without its calls.
pub inline fn popOperand(stack: *std.ArrayList(Node.Index)) ?Node.Index {
    const len = stack.items.len;
    if (len == 0) return null;
    stack.items.len = len - 1;
    return stack.items.ptr[len - 1];
}

// ---- Invariants -------------------------------------------------------------

pub const VerifyError = error{
    /// A node index, extra index, name index or string range pointed
    /// outside its array.
    OutOfBounds,
    /// A statement appeared where an expression belongs, or the reverse.
    WrongPosition,
};

/// Walk every node and check that each index it holds is in bounds and that
/// statements and expressions are not mixed up.
///
/// This is a TEST instrument and a debug assertion, not a pass the compiler
/// runs: `Lower` builds the graph bottom-up, so an out-of-bounds index would
/// be a bug in the builder, not a possible consequence of user input. It
/// exists because "the builder is correct" is exactly the claim the hermetic
/// suite has to be able to make about a structure that the fuzzers feed —
/// and because an index error found here is a message, where the same error
/// found in the printer is a crash.
pub fn verify(ir: *const JsIr) VerifyError!void {
    try ir.verifyRange(ir.body, .statement);
    for (0..ir.nodes.len) |i| try ir.verifyNode(@fromBackingInt(@intCast(i)));
}

const Position = enum { statement, expression, either };

fn verifyRange(ir: *const JsIr, range: SubRange, position: Position) VerifyError!void {
    if (@backingInt(range.start) > @backingInt(range.end)) return error.OutOfBounds;
    if (@backingInt(range.end) > ir.extra.len) return error.OutOfBounds;
    for (ir.extraSlice(range, Node.Index)) |child| try ir.verifyChild(child, position);
}

fn verifySpecs(ir: *const JsIr, range: SubRange) VerifyError!void {
    if (@backingInt(range.start) > @backingInt(range.end)) return error.OutOfBounds;
    if (@backingInt(range.end) > ir.extra.len) return error.OutOfBounds;
    if (range.len() % Specifier.words != 0) return error.OutOfBounds;
    for (ir.extraSlice(range, NameIndex)) |n| try ir.verifyName(n, false);
}

fn verifyNames(ir: *const JsIr, range: SubRange) VerifyError!void {
    if (@backingInt(range.start) > @backingInt(range.end)) return error.OutOfBounds;
    if (@backingInt(range.end) > ir.extra.len) return error.OutOfBounds;
    for (ir.extraSlice(range, NameIndex)) |n| try ir.verifyName(n, false);
}

fn verifyChild(ir: *const JsIr, child: Node.Index, position: Position) VerifyError!void {
    if (child.int() >= ir.nodes.len) return error.OutOfBounds;
    const is_statement = ir.tag(child).isStatement();
    switch (position) {
        .statement => if (!is_statement) return error.WrongPosition,
        .expression => if (is_statement) return error.WrongPosition,
        .either => {},
    }
}

fn verifyOptional(ir: *const JsIr, raw: u32, position: Position) VerifyError!void {
    const o: Node.OptionalIndex = @fromBackingInt(@intCast(raw));
    if (o.unwrap()) |child| try ir.verifyChild(child, position);
}

fn verifyName(ir: *const JsIr, n: NameIndex, optional: bool) VerifyError!void {
    if (n == .none) {
        if (optional) return;
        return error.OutOfBounds;
    }
    if (n.int() >= ir.names.len) return error.OutOfBounds;
}

fn verifyExtra(ir: *const JsIr, index: ExtraIndex, comptime T: type) VerifyError!T {
    const start: usize = @backingInt(index);
    if (start + extraLen(T) > ir.extra.len) return error.OutOfBounds;
    return ir.extraData(index, T);
}

fn verifyBytes(ir: *const JsIr, d: Node.Data) VerifyError!void {
    const end = @as(usize, d.lhs) + d.rhs;
    if (end > ir.string_bytes.len) return error.OutOfBounds;
}

fn verifyFunc(ir: *const JsIr, index: ExtraIndex) VerifyError!void {
    const f = try ir.verifyExtra(index, Func);
    try ir.verifyNames(f.params());
    try ir.verifyRange(f.body(), .statement);
}

fn verifyNode(ir: *const JsIr, node: Node.Index) VerifyError!void {
    const d = ir.data(node);
    switch (ir.tag(node)) {
        .import_stmt => {
            const imp = try ir.verifyExtra(@fromBackingInt(@intCast(d.lhs)), Import);
            if (@as(usize, imp.source_start) + imp.source_len > ir.string_bytes.len) return error.OutOfBounds;
            try ir.verifySpecs(imp.specs());
        },
        .export_stmt => try ir.verifyNames(inlineRange(d)),
        .const_decl => {
            try ir.verifyName(@fromBackingInt(@intCast(d.lhs)), false);
            try ir.verifyChild(@fromBackingInt(@intCast(d.rhs)), .expression);
        },
        .let_decl => {
            try ir.verifyName(@fromBackingInt(@intCast(d.lhs)), false);
            try ir.verifyOptional(d.rhs, .expression);
        },
        .func_decl, .gen_decl => {
            try ir.verifyName(@fromBackingInt(@intCast(d.lhs)), false);
            try ir.verifyFunc(@fromBackingInt(@intCast(d.rhs)));
        },
        .assign_stmt => {
            try ir.verifyChild(@fromBackingInt(@intCast(d.lhs)), .expression);
            try ir.verifyChild(@fromBackingInt(@intCast(d.rhs)), .expression);
        },
        .return_stmt => try ir.verifyOptional(d.lhs, .expression),
        .if_stmt => {
            try ir.verifyChild(@fromBackingInt(@intCast(d.lhs)), .expression);
            const branches = try ir.verifyExtra(@fromBackingInt(@intCast(d.rhs)), If);
            try ir.verifyRange(branches.thenBody(), .statement);
            try ir.verifyRange(branches.elseBody(), .statement);
        },
        .while_true => {
            try ir.verifyName(@fromBackingInt(@intCast(d.lhs)), true);
            try ir.verifyRange(try ir.verifyExtra(@fromBackingInt(@intCast(d.rhs)), SubRange), .statement);
        },
        .for_of => {
            try ir.verifyName(@fromBackingInt(@intCast(d.lhs)), false);
            const f = try ir.verifyExtra(@fromBackingInt(@intCast(d.rhs)), ForOf);
            try ir.verifyChild(f.iterable, .expression);
            try ir.verifyRange(f.body(), .statement);
        },
        .break_stmt, .continue_stmt => try ir.verifyName(@fromBackingInt(@intCast(d.lhs)), true),
        .switch_stmt => {
            try ir.verifyChild(@fromBackingInt(@intCast(d.lhs)), .expression);
            const cases = try ir.verifyExtra(@fromBackingInt(@intCast(d.rhs)), SubRange);
            if (@backingInt(cases.start) > @backingInt(cases.end) or @backingInt(cases.end) > ir.extra.len) {
                return error.OutOfBounds;
            }
            for (ir.extraSlice(cases, Node.Index)) |c| {
                if (c.int() >= ir.nodes.len) return error.OutOfBounds;
                if (ir.tag(c) != .switch_case) return error.WrongPosition;
            }
        },
        .switch_case => {
            try ir.verifyOptional(d.lhs, .expression);
            try ir.verifyRange(try ir.verifyExtra(@fromBackingInt(@intCast(d.rhs)), SubRange), .statement);
        },
        .block_stmt => {
            try ir.verifyName(@fromBackingInt(@intCast(d.lhs)), true);
            try ir.verifyRange(try ir.verifyExtra(@fromBackingInt(@intCast(d.rhs)), SubRange), .statement);
        },
        .expr_stmt, .throw_stmt => try ir.verifyChild(@fromBackingInt(@intCast(d.lhs)), .expression),
        .try_stmt => {
            const t = try ir.verifyExtra(@fromBackingInt(@intCast(d.rhs)), Try);
            try ir.verifyRange(t.body(), .statement);
            try ir.verifyRange(t.finalBody(), .statement);
            try ir.verifyRange(t.catchBody(), .statement);
        },

        .ident => try ir.verifyName(@fromBackingInt(@intCast(d.lhs)), false),
        .number, .string, .template_chunk, .regex => try ir.verifyBytes(d),
        .template => {
            const parts = inlineRange(d);
            if (@backingInt(parts.start) > @backingInt(parts.end) or @backingInt(parts.end) > ir.extra.len) {
                return error.OutOfBounds;
            }
            for (ir.extraSlice(parts, Node.Index)) |part| try ir.verifyChild(part, .expression);
        },
        .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .this_lit => {},
        .call, .new_call => {
            try ir.verifyChild(@fromBackingInt(@intCast(d.lhs)), .expression);
            try ir.verifyRange(try ir.verifyExtra(@fromBackingInt(@intCast(d.rhs)), SubRange), .expression);
        },
        .member => {
            try ir.verifyChild(@fromBackingInt(@intCast(d.lhs)), .expression);
            try ir.verifyName(@fromBackingInt(@intCast(d.rhs)), false);
        },
        .index_get => {
            try ir.verifyChild(@fromBackingInt(@intCast(d.lhs)), .expression);
            try ir.verifyChild(@fromBackingInt(@intCast(d.rhs)), .expression);
        },
        .object => {
            const props = inlineRange(d);
            if (@backingInt(props.start) > @backingInt(props.end) or @backingInt(props.end) > ir.extra.len) {
                return error.OutOfBounds;
            }
            for (ir.extraSlice(props, Node.Index)) |p| {
                if (p.int() >= ir.nodes.len) return error.OutOfBounds;
                if (ir.tag(p) != .property and ir.tag(p) != .spread_property) return error.WrongPosition;
            }
        },
        .property => {
            try ir.verifyName(@fromBackingInt(@intCast(d.lhs)), false);
            try ir.verifyChild(@fromBackingInt(@intCast(d.rhs)), .expression);
        },
        .spread_property => try ir.verifyChild(@fromBackingInt(@intCast(d.lhs)), .expression),
        .array => {
            const parts = inlineRange(d);
            if (@backingInt(parts.start) > @backingInt(parts.end) or @backingInt(parts.end) > ir.extra.len) {
                return error.OutOfBounds;
            }
            for (ir.extraSlice(parts, Node.Index)) |e| try ir.verifyChild(e, .expression);
        },
        .arrow => try ir.verifyFunc(@fromBackingInt(@intCast(d.lhs))),
        .cond => {
            try ir.verifyChild(@fromBackingInt(@intCast(d.lhs)), .expression);
            const c = try ir.verifyExtra(@fromBackingInt(@intCast(d.rhs)), Cond);
            try ir.verifyChild(c.consequent, .expression);
            try ir.verifyChild(c.alternate, .expression);
        },
        .binary => {
            const b = try ir.verifyExtra(@fromBackingInt(@intCast(d.lhs)), Binary);
            try ir.verifyChild(b.left, .expression);
            try ir.verifyChild(b.right, .expression);
            if (d.rhs >= @typeInfo(BinaryOp).@"enum".field_names.len) return error.OutOfBounds;
        },
        .unary => {
            try ir.verifyChild(@fromBackingInt(@intCast(d.lhs)), .expression);
            if (d.rhs >= @typeInfo(UnaryOp).@"enum".field_names.len) return error.OutOfBounds;
        },
    }
}

// ---- Emitted nesting (backend.md §4, *Emitted JavaScript nests only as deep as the source*) ---

/// What one node costs a JavaScript engine's parser in nesting, in units of
/// a quarter of a nested call, measured (backend.md §4's table): every engine
/// parses — and V8 and JavaScriptCore compile — a nested expression or
/// statement by recursion, and gives up with `RangeError` or `InternalError`
/// past a depth that depends on the construct. The unit is fixed by the
/// scarcest browser: Chrome 153 loads 1 290 nested calls, so a call costs 4
/// and 5 160 units is the edge. Every other weight is 5 160 over the lowest
/// depth any of Chrome 153, Firefox 144, WebKit 605.1.15 and Node 24 loads
/// for that construct, rounded UP.
pub const nesting = struct {
    /// The most a top-level statement may cost (backend.md §4). Two and a
    /// half times under the browsers' edge, and one and a half times under
    /// the SpiderMonkey 140 shell's, the scarcest engine measured.
    pub const budget: u32 = 2048;
    /// An expression this tall is bound to a `const` where it stands
    /// (`Lower.expr`), so an expression chain costs at most about this much
    /// however long the source's chain is.
    pub const spill: u32 = 256;
    /// The most scopes a top-level statement may nest (`Height.scopes`).
    /// SpiderMonkey refuses 252 nested blocks that declare something with
    /// "function nested too deeply", in the shell and in Firefox alike,
    /// however much stack is left; half of that.
    pub const scope_budget: u32 = 128;
    /// The fewest nodes a statement needs before it could be over either
    /// budget: no node costs more than `if_stmt`, and no node adds more than
    /// one scope. `Lower` measures nothing smaller.
    pub const could_exceed: u32 = @min(budget / if_stmt, scope_budget);

    /// A call, `f(…)`: each argument and the callee one level in.
    pub const call: u32 = 4;
    /// `{ k: v }`: Firefox loads 1 263 nested object literals.
    pub const object: u32 = 5;
    /// `[a, b]`.
    pub const array: u32 = 4;
    /// `a.b`, `a[i]`, `-a`, a template's hole: not measured, and none of
    /// them nests past the source's own depth.
    pub const member: u32 = 2;
    /// The right operand of a binary operator, and a left operand that is
    /// not itself a binary operator of the same precedence: Chrome loads
    /// 997 levels of `a && (b && …)`.
    pub const operand: u32 = 6;
    /// The left operand of `a && b && c`, printed flat: V8's parser builds
    /// one n-ary node and SpiderMonkey's loops, so neither nests at all; the
    /// JavaScriptCore of WebKit loads 53 620 terms of `&&` and 40 144 of `+`,
    /// which no chain this compiler builds reaches (`Lower` groups a derived
    /// `&&` by `derived_group`).
    pub const flat: u32 = 0;
    /// The test or the consequent of `a ? b : c`: Chrome loads 1 263.
    pub const cond: u32 = 5;
    /// The alternate of `a ? b : c`, which is how an `else if` chain of
    /// expressions prints: Firefox loads 4 147, V8 has no limit.
    pub const alternate: u32 = 2;
    /// `(…) => body`: Firefox loads 497 nested `(() => …)()`, which costs a
    /// call as well.
    pub const arrow: u32 = 7;
    /// `if (…) { … } else { … }`: Chrome loads 644 nested.
    pub const if_stmt: u32 = 9;
    /// `{ … }`, labelled or not: Chrome loads 1 290.
    pub const block: u32 = 4;
    /// `switch (…) { case …: { … } }`, whose case bodies `Lower` braces:
    /// Chrome loads 595 nested, which costs this and a `block`.
    pub const switch_stmt: u32 = 5;
    /// `label: while (true) { … }`, the same as an `if`.
    pub const loop: u32 = 9;
    /// Every other statement: `const x = …`, `return …`, `x = …`.
    pub const statement: u32 = 1;
};

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------

/// The growable form. `js/Lower.zig` owns one per module and calls
/// `toOwned` at the end; nothing else builds a `JsIr`.
///
/// Names are deduplicated through a hash map keyed by the `Name` VALUE and
/// not by a dense id, so the house rule of §5 is satisfied: a `Name` is a
/// sparse key (a pair of interner indices), exactly the case the rule
/// exempts. Deduplicating matters because the release renamer wants one row per
/// distinct identifier, and because a reference is then an integer compare.
pub const Builder = struct {
    gpa: Allocator,
    nodes: NodeList = .empty,
    extra: std.ArrayList(u32) = .empty,
    string_bytes: std.ArrayList(u8) = .empty,
    names: std.ArrayList(Name) = .empty,
    name_index: std.HashMapUnmanaged(NameKey, NameIndex, NameKeyContext, std.hash_map.default_max_load_percentage) = .empty,
    /// `nodes`' columns, refreshed whenever `nodes` grows: `addNode` writes
    /// through them. `MultiArrayList.append` recomputes every column's
    /// address for each node, and Zig's own backend does not fold that
    /// away; on a module of a million nodes it was a tenth of the build.
    cols: NodeList.Slice = .empty,
    /// Recent answers of `intern`, one per slot (`intern`).
    recent: [recent_slots]Recent = @splat(.{ .key = undefined, .index = .none }),
    /// A plain local name's index — no module and no tag, the case of every
    /// field, property and parameter name — by its base symbol, in an
    /// open-addressed table of `(symbol, index)` words: `std`'s map runs
    /// generic code Zig's own backend compiles poorly, and a wide record
    /// interns one such name per field. Never iterated, so its layout is
    /// never observable; `name_index` keeps every other name.
    locals: []u64 = &.{},
    locals_count: usize = 0,

    const local_empty: u64 = std.math.maxInt(u64);

    const recent_slots = 256;
    const Recent = struct { key: NameKey, index: NameIndex };

    const NameKey = struct { module: u32, base: u32, tag: u32 };

    /// Three words mixed by multiplication. The default hash runs Wyhash
    /// over the key's twelve bytes, a tenth of lowering a wide module.
    const NameKeyContext = struct {
        pub fn hash(_: NameKeyContext, k: NameKey) u64 {
            const a: u64 = (@as(u64, k.module) << 32) | k.base;
            const m = (a ^ (@as(u64, k.tag) *% 0xC2B2_AE3D_27D4_EB4F)) *% 0x9E37_79B9_7F4A_7C15;
            return m ^ (m >> 29);
        }

        pub fn eql(_: NameKeyContext, a: NameKey, b: NameKey) bool {
            return a.module == b.module and a.base == b.base and a.tag == b.tag;
        }
    };

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    /// Reserve room for a module lowered from `insts` Bir instructions, so
    /// its lists are allocated once instead of grown from empty a node at a
    /// time. Measured over the generated 100k-line corpus, bench/corpus and
    /// core, a module makes per instruction 0.87 nodes and 0.94 extra words
    /// at the median and 2.1 and 2.2 at the 99th percentile, 0.60 string
    /// bytes (1.4), and 0.12 names (0.25). A module past an estimate grows
    /// that list as before.
    pub fn reserve(b: *Builder, insts: usize) Allocator.Error!void {
        if (b.nodes.capacity < insts * 2 + 64) {
            try b.nodes.setCapacity(b.gpa, @max(b.nodes.len, insts * 2 + 64));
            b.cols = b.nodes.slice();
        }
        try b.extra.ensureTotalCapacityPrecise(b.gpa, insts * 2 + 64);
        try b.string_bytes.ensureTotalCapacityPrecise(b.gpa, insts * 3 / 2 + 64);
        try b.names.ensureTotalCapacityPrecise(b.gpa, insts / 4 + 16);
    }

    pub fn deinit(b: *Builder) void {
        b.nodes.deinit(b.gpa);
        b.extra.deinit(b.gpa);
        b.string_bytes.deinit(b.gpa);
        b.names.deinit(b.gpa);
        b.name_index.deinit(b.gpa);
        b.gpa.free(b.locals);
    }

    /// Hand the finished module over. The builder is empty afterwards.
    pub fn toOwned(b: *Builder, body: SubRange) Allocator.Error!JsIr {
        const ir: JsIr = .{
            .nodes = b.nodes.toOwnedSlice(),
            .extra = try b.extra.toOwnedSlice(b.gpa),
            .string_bytes = try b.string_bytes.toOwnedSlice(b.gpa),
            .names = try b.names.toOwnedSlice(b.gpa),
            .body = body,
        };
        b.name_index.clearRetainingCapacity();
        b.recent = @splat(.{ .key = undefined, .index = .none });
        @memset(b.locals, local_empty);
        b.locals_count = 0;
        b.cols = .empty;
        return ir;
    }

    /// Node `node`'s tag, read through `cols`: `nodes.items` recomputes
    /// every column's address for each ask, and Zig's own backend, which
    /// builds the tests' compiler, does not fold that away (`tag`).
    pub inline fn tagOf(b: *const Builder, node: Node.Index) Node.Tag {
        if (node.int() >= b.nodes.len) unreachable;
        const tags: [*]const Node.Tag = @ptrCast(b.cols.ptrs[@backingInt(NodeList.Field.tag)]);
        return tags[node.int()];
    }

    /// Node `node`'s data, read as `tagOf` reads its tag.
    pub inline fn dataOf(b: *const Builder, node: Node.Index) Node.Data {
        if (node.int() >= b.nodes.len) unreachable;
        const datas: [*]const Node.Data = @ptrCast(@alignCast(b.cols.ptrs[@backingInt(NodeList.Field.data)]));
        return datas[node.int()];
    }

    pub fn addNode(b: *Builder, node: Node) Allocator.Error!Node.Index {
        return b.addParts(node.tag, node.pos, node.data.lhs, node.data.rhs);
    }

    /// `addNode` from the node's fields, with no `Node` built on the way.
    pub fn addParts(b: *Builder, node_tag: Node.Tag, node_pos: u32, lhs: u32, rhs: u32) Allocator.Error!Node.Index {
        const index = b.nodes.len;
        if (index == b.nodes.capacity) {
            try b.nodes.ensureUnusedCapacity(b.gpa, 1);
            b.cols = b.nodes.slice();
        }
        b.nodes.len = index + 1;
        b.cols.len = index + 1;
        const tags: [*]Node.Tag = @ptrCast(b.cols.ptrs[@backingInt(NodeList.Field.tag)]);
        const positions: [*]u32 = @ptrCast(@alignCast(b.cols.ptrs[@backingInt(NodeList.Field.pos)]));
        const datas: [*]Node.Data = @ptrCast(@alignCast(b.cols.ptrs[@backingInt(NodeList.Field.data)]));
        tags[index] = node_tag;
        positions[index] = node_pos;
        datas[index] = .{ .lhs = lhs, .rhs = rhs };
        return @fromBackingInt(@intCast(index));
    }

    pub fn intern(b: *Builder, n: Name) Allocator.Error!NameIndex {
        if (n.module == .none and n.tag == Name.no_tag) return b.internLocal(n.base);
        const key: NameKey = .{ .module = @backingInt(n.module), .base = @backingInt(n.base), .tag = n.tag };
        // Most names a module interns are asked for again and again — the
        // parameters of a derived function once per position — so a small
        // table of recent answers, one slot per hash, is asked first. It
        // only ever holds answers the map gave, so it decides nothing.
        const slot = &b.recent[@intCast(NameKeyContext.hash(.{}, key) % recent_slots)];
        if (slot.index != .none and NameKeyContext.eql(.{}, slot.key, key)) return slot.index;
        const got = try b.name_index.getOrPut(b.gpa, key);
        if (got.found_existing) {
            slot.* = .{ .key = key, .index = got.value_ptr.* };
            return got.value_ptr.*;
        }
        const index: NameIndex = @fromBackingInt(@intCast(@as(u32, @intCast(b.names.items.len))));
        b.names.append(b.gpa, n) catch |err| {
            _ = b.name_index.remove(key);
            return err;
        };
        got.value_ptr.* = index;
        slot.* = .{ .key = key, .index = index };
        return index;
    }

    /// `intern` of `Name.local(base)`, through `locals`.
    fn internLocal(b: *Builder, base: Symbol) Allocator.Error!NameIndex {
        if ((b.locals_count + 1) * 2 > b.locals.len) try b.growLocals();
        const key: u32 = @backingInt(base);
        const mask = b.locals.len - 1;
        var i = localSlot(key, b.locals.len);
        while (true) : (i = (i + 1) & mask) {
            const word = b.locals[i];
            if (word == local_empty) break;
            if (@as(u32, @truncate(word >> 32)) == key) return @fromBackingInt(@intCast(@as(u32, @truncate(word))));
        }
        const index: u32 = @intCast(b.names.items.len);
        try b.names.append(b.gpa, Name.local(base));
        b.locals[i] = (@as(u64, key) << 32) | index;
        b.locals_count += 1;
        return @fromBackingInt(@intCast(index));
    }

    fn growLocals(b: *Builder) Allocator.Error!void {
        const len = @max(64, b.locals.len * 2);
        const slots = try b.gpa.alloc(u64, len);
        @memset(slots, local_empty);
        const mask = len - 1;
        for (b.locals) |word| {
            if (word == local_empty) continue;
            var i = localSlot(@truncate(word >> 32), len);
            while (slots[i] != local_empty) i = (i + 1) & mask;
            slots[i] = word;
        }
        b.gpa.free(b.locals);
        b.locals = slots;
    }

    fn localSlot(key: u32, len: usize) usize {
        return @intCast(((@as(u64, key) *% 0x9E37_79B9_7F4A_7C15) >> 32) & (len - 1));
    }

    /// Append `text` and return its `(offset, length)`. Literal bytes are
    /// never deduplicated: the win is small and the hash is not.
    pub fn addString(b: *Builder, text: []const u8) Allocator.Error!struct { u32, u32 } {
        const offset: u32 = @intCast(b.string_bytes.items.len);
        try b.string_bytes.appendSlice(b.gpa, text);
        return .{ offset, @intCast(text.len) };
    }

    /// Append `words` to `extra` and return the range they occupy.
    pub fn addExtra(b: *Builder, words: []const u32) Allocator.Error!SubRange {
        const start: u32 = @intCast(b.extra.items.len);
        try b.extra.appendSlice(b.gpa, words);
        return .{ .start = @fromBackingInt(@intCast(start)), .end = @fromBackingInt(@intCast(start + words.len)) };
    }

    /// Append a range of node indices to `extra`.
    pub fn addRange(b: *Builder, items: []const Node.Index) Allocator.Error!SubRange {
        return b.addExtra(@ptrCast(items));
    }

    pub fn addNames(b: *Builder, items: []const NameIndex) Allocator.Error!SubRange {
        return b.addExtra(@ptrCast(items));
    }

    /// Append a record field by field and return its `ExtraIndex`.
    pub fn addRecord(b: *Builder, value: anytype) Allocator.Error!ExtraIndex {
        const index: u32 = @intCast(b.extra.items.len);
        inline for (@typeInfo(@TypeOf(value)).@"struct".field_names, @typeInfo(@TypeOf(value)).@"struct".field_types) |field_name, field_type| {
            const v = @field(value, field_name);
            const word: u32 = switch (@typeInfo(field_type)) {
                .@"enum" => @backingInt(v),
                .int => v,
                else => @compileError("unexpected extra field type: " ++ @typeName(field_type)),
            };
            try b.extra.append(b.gpa, word);
        }
        return @fromBackingInt(@intCast(index));
    }

    /// How deep `stmts` nest, in `nesting`'s units, and how many scopes deep
    /// (`Height`): the longest path from any of them down to a leaf, each
    /// step costing what its construct costs an engine's parser. One walk
    /// over an explicit stack, so a tree of any depth is measured in constant
    /// Zig stack. `Lower` asks it only of a declaration with enough
    /// nodes to be over either budget (`nesting.could_exceed`).
    pub fn measure(b: *const Builder, gpa: Allocator, stmts: []const Node.Index) Allocator.Error!Height {
        const Entry = struct { node: u32, whole: u32, scopes: u32 };
        var stack: std.ArrayList(Entry) = .empty;
        defer stack.deinit(gpa);
        const tags = b.nodes.items(.tag);
        const datas = b.nodes.items(.data);
        const w = nesting;
        var most: Height = .zero;
        for (stmts) |stmt| try stack.append(gpa, .{ .node = stmt.int(), .whole = 0, .scopes = 0 });
        while (stack.pop()) |at| {
            most.whole = @max(most.whole, at.whole);
            most.scopes = @max(most.scopes, at.scopes);
            if (at.node >= tags.len) continue;
            const d = datas[at.node];
            // Push `node` one step of `weight` (and `scopes` scopes) below `at`.
            const Push = struct {
                fn one(s: *std.ArrayList(Entry), g: Allocator, from: Entry, node: u32, weight: u32, scopes: u32) Allocator.Error!void {
                    try s.append(g, .{ .node = node, .whole = from.whole +| weight, .scopes = from.scopes +| scopes });
                }
                fn optional(s: *std.ArrayList(Entry), g: Allocator, from: Entry, raw: u32, weight: u32) Allocator.Error!void {
                    const o: Node.OptionalIndex = @fromBackingInt(@intCast(raw));
                    const child = o.unwrap() orelse return;
                    try one(s, g, from, child.int(), weight, 0);
                }
                fn all(s: *std.ArrayList(Entry), g: Allocator, from: Entry, items: []const u32, weight: u32, scopes: u32) Allocator.Error!void {
                    for (items) |item| try one(s, g, from, item, weight, scopes);
                }
            };
            switch (tags[at.node]) {
                .ident, .number, .string, .template_chunk, .regex, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .this_lit => {},
                .import_stmt, .export_stmt, .break_stmt, .continue_stmt => {},
                .const_decl => try Push.one(&stack, gpa, at, d.rhs, w.statement, 0),
                .assign_stmt => {
                    try Push.one(&stack, gpa, at, d.lhs, w.statement, 0);
                    try Push.one(&stack, gpa, at, d.rhs, w.statement, 0);
                },
                .let_decl => try Push.optional(&stack, gpa, at, d.rhs, w.statement),
                .return_stmt => try Push.optional(&stack, gpa, at, d.lhs, w.statement),
                .expr_stmt, .throw_stmt => try Push.one(&stack, gpa, at, d.lhs, w.statement, 0),
                .func_decl, .gen_decl => try b.pushBlock(&stack, gpa, at, b.record(d.rhs, Func).body(), w.arrow, 1),
                .arrow => try b.pushBlock(&stack, gpa, at, b.record(d.lhs, Func).body(), w.arrow, 1),
                .if_stmt => {
                    const branches = b.record(d.rhs, If);
                    try Push.one(&stack, gpa, at, d.lhs, w.if_stmt, 0);
                    try b.pushBlock(&stack, gpa, at, branches.thenBody(), w.if_stmt, 0);
                    try b.pushBlock(&stack, gpa, at, branches.elseBody(), w.if_stmt, 0);
                },
                .while_true => try b.pushBlock(&stack, gpa, at, b.record(d.rhs, SubRange), w.loop, 0),
                .for_of => {
                    const f = b.record(d.rhs, ForOf);
                    try Push.one(&stack, gpa, at, f.iterable.int(), w.statement, 0);
                    try b.pushBlock(&stack, gpa, at, f.body(), w.loop, 1);
                },
                .switch_stmt => {
                    try Push.one(&stack, gpa, at, d.lhs, w.switch_stmt, 0);
                    try Push.all(&stack, gpa, at, b.rangeWords(b.record(d.rhs, SubRange)), w.switch_stmt, 0);
                },
                .switch_case => {
                    try Push.optional(&stack, gpa, at, d.lhs, 0);
                    try b.pushBlock(&stack, gpa, at, b.record(d.rhs, SubRange), 0, 0);
                },
                .block_stmt => try b.pushBlock(&stack, gpa, at, b.record(d.rhs, SubRange), w.block, 0),
                .try_stmt => {
                    const t = b.record(d.rhs, Try);
                    try b.pushBlock(&stack, gpa, at, t.body(), w.block, 0);
                    try b.pushBlock(&stack, gpa, at, t.finalBody(), w.block, 0);
                    try b.pushBlock(&stack, gpa, at, t.catchBody(), w.block, 0);
                },
                .template => try Push.all(&stack, gpa, at, b.rangeWords(inlineRange(d)), w.member, 0),
                .call, .new_call => {
                    try Push.one(&stack, gpa, at, d.lhs, w.call, 0);
                    try Push.all(&stack, gpa, at, b.rangeWords(b.record(d.rhs, SubRange)), w.call, 0);
                },
                .member, .unary => try Push.one(&stack, gpa, at, d.lhs, w.member, 0),
                .index_get => {
                    try Push.one(&stack, gpa, at, d.lhs, w.member, 0);
                    try Push.one(&stack, gpa, at, d.rhs, w.member, 0);
                },
                .object => try Push.all(&stack, gpa, at, b.rangeWords(inlineRange(d)), w.object, 0),
                .property => try Push.one(&stack, gpa, at, d.rhs, 0, 0),
                .spread_property => try Push.one(&stack, gpa, at, d.lhs, 0, 0),
                .array => try Push.all(&stack, gpa, at, b.rangeWords(inlineRange(d)), w.array, 0),
                .cond => {
                    const c = b.record(d.rhs, Cond);
                    try Push.one(&stack, gpa, at, d.lhs, w.cond, 0);
                    try Push.one(&stack, gpa, at, c.consequent.int(), w.cond, 0);
                    try Push.one(&stack, gpa, at, c.alternate.int(), w.alternate, 0);
                },
                .binary => {
                    const pair = b.record(d.lhs, Binary);
                    const op: BinaryOp = @fromBackingInt(@intCast(d.rhs));
                    const left = pair.left.int();
                    const flat = left < tags.len and tags[left] == .binary and
                        (@as(BinaryOp, @fromBackingInt(@intCast(datas[left].rhs)))).precedence() == op.precedence();
                    try Push.one(&stack, gpa, at, left, if (flat) w.flat else w.operand, 0);
                    try Push.one(&stack, gpa, at, pair.right.int(), w.operand, 0);
                },
            }
        }
        return most;
    }

    /// What a run of statements and expressions built so far holds, walked
    /// through every nested statement and expression of the one function
    /// they belong to.
    pub const Holds = struct {
        /// A function made here: an arrow, or a `function` declaration.
        closure: bool = false,
        /// A loop.
        loop: bool = false,
        /// A call, which may have an effect, or `yield`, which suspends.
        call: bool = false,
        /// A read of the name asked about.
        reads: bool = false,
        /// A `switch`, which a `break` with no label inside it leaves
        /// instead of the loop around it.
        switch_: bool = false,
    };

    /// `Holds` for `roots`, which may be statements or expressions; `read`
    /// is the name `reads` asks about, or `.none`. Iterative, over a stack
    /// of its own: a body is as deep as the longest chain the lowering
    /// built.
    pub fn holds(b: *const Builder, gpa: Allocator, roots: []const Node.Index, read: NameIndex) Allocator.Error!Holds {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        const tags = b.nodes.items(.tag);
        const datas = b.nodes.items(.data);
        var out: Holds = .{};
        for (roots) |root| try stack.append(gpa, root.int());
        while (stack.pop()) |at| {
            if (at >= tags.len) continue;
            const d = datas[at];
            switch (tags[at]) {
                .ident => if (read != .none and d.lhs == read.int()) {
                    out.reads = true;
                },
                .number, .string, .template_chunk, .regex, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .this_lit => {},
                .import_stmt, .export_stmt, .break_stmt, .continue_stmt => {},
                .const_decl, .property => try stack.append(gpa, d.rhs),
                .assign_stmt, .index_get => try stack.appendSlice(gpa, &.{ d.lhs, d.rhs }),
                .let_decl => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| try stack.append(gpa, v.int()),
                .return_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try stack.append(gpa, v.int()),
                .unary => {
                    if (@as(UnaryOp, @fromBackingInt(@intCast(d.rhs))) == .yield) out.call = true;
                    try stack.append(gpa, d.lhs);
                },
                .expr_stmt, .throw_stmt, .member, .spread_property => try stack.append(gpa, d.lhs),
                // A function made here is reported; what its body holds is
                // another function's, and not walked.
                .func_decl, .gen_decl, .arrow => out.closure = true,
                .if_stmt => {
                    const branches = b.record(d.rhs, If);
                    try stack.append(gpa, d.lhs);
                    try stack.appendSlice(gpa, b.rangeWords(branches.thenBody()));
                    try stack.appendSlice(gpa, b.rangeWords(branches.elseBody()));
                },
                .while_true => {
                    out.loop = true;
                    try stack.appendSlice(gpa, b.rangeWords(b.record(d.rhs, SubRange)));
                },
                .for_of => {
                    out.loop = true;
                    const f = b.record(d.rhs, ForOf);
                    try stack.append(gpa, f.iterable.int());
                    try stack.appendSlice(gpa, b.rangeWords(f.body()));
                },
                .switch_stmt => {
                    out.switch_ = true;
                    try stack.append(gpa, d.lhs);
                    try stack.appendSlice(gpa, b.rangeWords(b.record(d.rhs, SubRange)));
                },
                .switch_case => {
                    if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |t| try stack.append(gpa, t.int());
                    try stack.appendSlice(gpa, b.rangeWords(b.record(d.rhs, SubRange)));
                },
                .block_stmt => try stack.appendSlice(gpa, b.rangeWords(b.record(d.rhs, SubRange))),
                .try_stmt => {
                    const t = b.record(d.rhs, Try);
                    try stack.appendSlice(gpa, b.rangeWords(t.body()));
                    try stack.appendSlice(gpa, b.rangeWords(t.finalBody()));
                    try stack.appendSlice(gpa, b.rangeWords(t.catchBody()));
                },
                .template, .object, .array => try stack.appendSlice(gpa, b.rangeWords(inlineRange(d))),
                .call, .new_call => {
                    out.call = true;
                    try stack.append(gpa, d.lhs);
                    try stack.appendSlice(gpa, b.rangeWords(b.record(d.rhs, SubRange)));
                },
                .cond => {
                    const c = b.record(d.rhs, Cond);
                    try stack.appendSlice(gpa, &.{ d.lhs, c.consequent.int(), c.alternate.int() });
                },
                .binary => {
                    const pair = b.record(d.lhs, Binary);
                    try stack.appendSlice(gpa, &.{ pair.left.int(), pair.right.int() });
                },
            }
        }
        return out;
    }

    /// A braced run of statements below `at`: `weight` further down, and
    /// `scopes` scopes more — one more again when the run declares something,
    /// which is what makes braces a scope of their own.
    fn pushBlock(b: *const Builder, stack: anytype, gpa: Allocator, at: anytype, range: SubRange, weight: u32, scopes: u32) Allocator.Error!void {
        const items = b.rangeWords(range);
        const tags = b.nodes.items(.tag);
        var declares = false;
        for (items) |item| {
            if (item < tags.len) switch (tags[item]) {
                .const_decl, .let_decl, .func_decl, .gen_decl => declares = true,
                else => {},
            };
        }
        const more = scopes + @intFromBool(declares);
        for (items) |item| try stack.append(gpa, .{ .node = item, .whole = at.whole +| weight, .scopes = at.scopes +| more });
    }

    /// The words of `range`, or none when it is not inside `extra`.
    fn rangeWords(b: *const Builder, range: SubRange) []const u32 {
        const start: usize = @backingInt(range.start);
        const end: usize = @backingInt(range.end);
        if (start > end or end > b.extra.items.len) return &.{};
        return b.extra.items[start..end];
    }

    fn record(b: *const Builder, index: u32, comptime T: type) T {
        var result: T = undefined;
        var i: usize = index;
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| {
            const word = if (i < b.extra.items.len) b.extra.items[i] else 0;
            @field(result, field_name) = switch (@typeInfo(field_type)) {
                .@"enum" => @fromBackingInt(@intCast(word)),
                .int => word,
                else => @compileError("unexpected extra field type: " ++ @typeName(field_type)),
            };
            i += 1;
        }
        return result;
    }
};

/// How deep a run of statements nests (`Builder.measure`, `nesting`):
///
///   - `whole`: the costliest path from a statement down to a leaf, in
///     `nesting`'s units — what an engine's parser recurses through, and what
///     `nesting.budget` bounds;
///   - `scopes`: the most scopes on one path — functions, and braces around
///     statements that declare something — which SpiderMonkey bounds on its
///     own, whatever the stack (`nesting.scope_budget`).
pub const Height = struct {
    whole: u32,
    scopes: u32,

    pub const zero: Height = .{ .whole = 0, .scopes = 0 };
};

// ---------------------------------------------------------------------------
// Tests
//
// The node graph and the in-bounds invariants only. What each node PRINTS is
// `Print.zig`'s, what each beni construct lowers TO is `Lower.zig`'s, and
// what the emitted program computes is `tests/corpus/run/`'s.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extraData reads records positionally and extraLen agrees" {
    try testing.expectEqual(@as(u32, 2), extraLen(SubRange));
    try testing.expectEqual(@as(u32, 4), extraLen(Func));
    try testing.expectEqual(@as(u32, 4), extraLen(Import));
    try testing.expectEqual(@as(u32, 2), extraLen(Specifier));

    const words = [_]u32{ 3, 4, 7, 9, 11, 12 };
    var ir: JsIr = empty;
    ir.extra = &words;
    const f = ir.extraData(@fromBackingInt(@intCast(0)), Func);
    try testing.expectEqual(@as(u32, 3), @backingInt(f.params_start));
    try testing.expectEqual(@as(u32, 9), @backingInt(f.body_end));
    try testing.expectEqual(@as(u32, 1), f.params().len());
    try testing.expectEqual(@as(u32, 2), f.body().len());
    const c = ir.extraData(@fromBackingInt(@intCast(4)), Cond);
    try testing.expectEqual(@as(u32, 11), c.consequent.int());
    try testing.expectEqual(@as(u32, 12), c.alternate.int());
}

test "names are deduplicated by value, so a reference is an integer compare" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    const a = try b.intern(.local(@fromBackingInt(@intCast(7))));
    const again = try b.intern(.local(@fromBackingInt(@intCast(7))));
    const other = try b.intern(.local(@fromBackingInt(@intCast(8))));
    const tagged = try b.intern(.{ .module = .none, .base = @fromBackingInt(@intCast(7)), .tag = 1 });
    const qualified = try b.intern(.qualified(@fromBackingInt(@intCast(3)), @fromBackingInt(@intCast(7))));
    try testing.expectEqual(a, again);
    try testing.expect(a != other);
    try testing.expect(a != tagged);
    try testing.expect(a != qualified);
    try testing.expectEqual(@as(usize, 4), b.names.items.len);
}

test "verify accepts a well-formed module and finds every kind of dangling index" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();

    const x = try b.intern(.local(@fromBackingInt(@intCast(0))));
    const one_offset, const one_len = try b.addString("1");
    const one = try b.addNode(.{ .tag = .number, .pos = 0, .data = .{ .lhs = one_offset, .rhs = one_len } });
    const decl = try b.addNode(.{ .tag = .const_decl, .pos = 0, .data = .{ .lhs = @backingInt(x), .rhs = one.int() } });
    const body = try b.addRange(&.{decl});

    var ir = try b.toOwned(body);
    defer ir.deinit(gpa);
    try ir.verify();

    // A node index past the end.
    ir.nodes.items(.data)[decl.int()].rhs = 99;
    try testing.expectError(error.OutOfBounds, ir.verify());
    ir.nodes.items(.data)[decl.int()].rhs = one.int();
    try ir.verify();

    // A name index past the end.
    ir.nodes.items(.data)[decl.int()].lhs = 42;
    try testing.expectError(error.OutOfBounds, ir.verify());
    ir.nodes.items(.data)[decl.int()].lhs = @backingInt(x);

    // A string range past the end.
    ir.nodes.items(.data)[one.int()].rhs = 100;
    try testing.expectError(error.OutOfBounds, ir.verify());
    ir.nodes.items(.data)[one.int()].rhs = one_len;
    try ir.verify();
}

test "verify refuses a statement where an expression belongs" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();

    const x = try b.intern(.local(@fromBackingInt(@intCast(0))));
    const ident = try b.addNode(.{ .tag = .ident, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(x), .rhs = 0 } });
    const ret = try b.addNode(.{ .tag = .return_stmt, .pos = Node.no_pos, .data = .{
        .lhs = @backingInt(ident.toOptional()),
        .rhs = 0,
    } });
    // `const x = return x;` — a statement where the value belongs.
    const bad = try b.addNode(.{ .tag = .const_decl, .pos = Node.no_pos, .data = .{
        .lhs = @backingInt(x),
        .rhs = ret.int(),
    } });
    const body = try b.addRange(&.{bad});

    var ir = try b.toOwned(body);
    defer ir.deinit(gpa);
    try testing.expectError(error.WrongPosition, ir.verify());
}

test "verify refuses an expression where a statement belongs" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();

    const x = try b.intern(.local(@fromBackingInt(@intCast(0))));
    const ident = try b.addNode(.{ .tag = .ident, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(x), .rhs = 0 } });
    const body = try b.addRange(&.{ident});

    var ir = try b.toOwned(body);
    defer ir.deinit(gpa);
    try testing.expectError(error.WrongPosition, ir.verify());
}

test "an empty module verifies and frees" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    var ir = try b.toOwned(.empty);
    defer ir.deinit(gpa);
    try ir.verify();
    try testing.expectEqual(@as(usize, 0), ir.nodes.len);
}

test "operator precedence is JavaScript's, so the printer can bracket on it" {
    try testing.expect(BinaryOp.precedence(.mul) > BinaryOp.precedence(.add));
    try testing.expect(BinaryOp.precedence(.add) > BinaryOp.precedence(.lt));
    try testing.expect(BinaryOp.precedence(.lt) > BinaryOp.precedence(.strict_eq));
    try testing.expect(BinaryOp.precedence(.strict_eq) > BinaryOp.precedence(.logical_and));
    try testing.expect(BinaryOp.precedence(.logical_and) > BinaryOp.precedence(.logical_or));
}

test "statements and expressions are separated by a range test" {
    try testing.expect(Node.Tag.import_stmt.isStatement());
    try testing.expect(Node.Tag.throw_stmt.isStatement());
    try testing.expect(!Node.Tag.ident.isStatement());
    try testing.expect(!Node.Tag.unary.isStatement());
}

test "measure: a path costs what its constructs cost, a function and declaring braces are scopes" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    const x = try b.intern(.local(@fromBackingInt(@intCast(1))));
    const leaf = try b.addNode(.{ .tag = .ident, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(x), .rhs = 0 } });
    try testing.expectEqual(Height.zero, try b.measure(gpa, &.{leaf}));

    // f(f(f(x))): three calls.
    var inner = leaf;
    for (0..3) |_| {
        const args = try b.addRange(&.{inner});
        const record = try b.addRecord(args);
        inner = try b.addNode(.{ .tag = .call, .pos = Node.no_pos, .data = .{ .lhs = leaf.int(), .rhs = @backingInt(record) } });
    }
    try testing.expectEqual(Height{ .whole = 3 * nesting.call, .scopes = 0 }, try b.measure(gpa, &.{inner}));

    // `const y = (x) => { const x = f(f(f(x))); return x; };`: one scope for
    // the function and one for the braces its `const` declares in.
    const decl = try b.addNode(.{ .tag = .const_decl, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(x), .rhs = inner.int() } });
    const ret = try b.addNode(.{ .tag = .return_stmt, .pos = Node.no_pos, .data = .{ .lhs = leaf.int(), .rhs = 0 } });
    const params = try b.addNames(&.{x});
    const body = try b.addRange(&.{ decl, ret });
    const func = try b.addRecord(Func{ .params_start = params.start, .params_end = params.end, .body_start = body.start, .body_end = body.end });
    const arrow = try b.addNode(.{ .tag = .arrow, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(func), .rhs = 0 } });
    const top = try b.addNode(.{ .tag = .const_decl, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(x), .rhs = arrow.int() } });
    try testing.expectEqual(Height{
        .whole = nesting.statement + nesting.arrow + nesting.statement + 3 * nesting.call,
        .scopes = 2,
    }, try b.measure(gpa, &.{top}));
}

test "measure: `a && b && c` built to the left is flat, `a && (b && c)` is not" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    const x = try b.intern(.local(@fromBackingInt(@intCast(1))));
    const leaf = try b.addNode(.{ .tag = .ident, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(x), .rhs = 0 } });
    const op = @backingInt(BinaryOp.logical_and);
    var left = leaf;
    var right = leaf;
    for (0..10) |_| {
        const l_pair = try b.addRecord(Binary{ .left = left, .right = leaf });
        left = try b.addNode(.{ .tag = .binary, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(l_pair), .rhs = op } });
        const r_pair = try b.addRecord(Binary{ .left = leaf, .right = right });
        right = try b.addNode(.{ .tag = .binary, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(r_pair), .rhs = op } });
    }
    // The first link's left operand is a name; every later one's is the
    // chain so far, which prints without parentheses and nests nothing.
    try testing.expectEqual(nesting.operand, (try b.measure(gpa, &.{left})).whole);
    try testing.expectEqual(10 * nesting.operand, (try b.measure(gpa, &.{right})).whole);
}
