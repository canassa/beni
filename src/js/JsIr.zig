//! The second IR (docs/design/backend.md §3, fast-compiler.md §9.2): a
//! JavaScript-shaped tree, flat, that `js/Lower.zig` builds from a checked
//! module's `Bir` and `js/Print.zig` turns into bytes.
//!
//! **Why a second IR at all** is §9.2: Elm's author measured lowering
//! straight to a byte builder as neutral for throughput and kept the
//! intermediate form anyway, because the peephole and specialisation passes
//! have to pattern-match on generated structure. M3c's optimiser is that
//! pass list; M3a's job is to give it something to match on.
//!
//! Shape, after `Bir` and `std.zig.Zir`: one `MultiArrayList(Node)` of
//! `{tag, pos, lhs, rhs}` records plus one `extra: []u32` sidecar for
//! everything variable-length, one `string_bytes` for literal text, and one
//! `names` column. Every reference is a `u32` index into a named array
//! wrapped in an `enum(u32)`; there is no pointer and no slice anywhere, so
//! a node is trivially copyable and M4 can map the whole thing.
//!
//! **Names are `Name`s, never strings** (§3). A `Name` is a pair of
//! interned `Symbol`s — an optional module qualifier and a base — plus a
//! disambiguator. Renaming in M3c is then a rewrite of the `names` column
//! and of nothing else: no node holds text, and two names are equal exactly
//! when their `NameIndex`es are. The printer is the only thing that turns a
//! `Name` back into bytes.
//!
//! **Every node carries a source position from the start** (§9.6), a byte
//! offset into the module's source or `Node.no_pos` for a node the lowering
//! invented. Source maps are off in M3a and the field is still here on
//! purpose: Elm never threaded positions through codegen and consequently
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
/// into it, so M3c's renaming is a rewrite of this array alone.
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
        /// `target = value;`. `lhs` target expression, `rhs` value.
        assign_stmt,
        /// `return;` or `return value;`. `lhs` is an `OptionalIndex`.
        return_stmt,
        /// `if (cond) { … } else { … }`. `lhs` condition, `rhs` extra `If`.
        if_stmt,
        /// `label: while (true) { … }` — the tail-call loop of §8, which
        /// M3b fills. `lhs` is a `NameIndex` (the label, or `.none`), `rhs`
        /// is extra `SubRange` of statements.
        while_true,
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
        true_lit,
        false_lit,
        null_lit,
        undefined_lit,
        /// `f(a, b)`. `lhs` callee, `rhs` extra `SubRange` of arguments.
        call,
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
        /// `(a, b) => …`. `lhs` is extra `Func`.
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
            return @intFromEnum(t) <= @intFromEnum(Tag.throw_stmt);
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
    /// `|`, which M3b's `Int32` needs (`x | 0`).
    bit_or,

    /// JavaScript's precedence, higher binds tighter. The printer
    /// parenthesises on it rather than carrying `paren` nodes, so the IR
    /// holds structure and the bytes hold syntax.
    pub fn precedence(op: BinaryOp) u8 {
        return switch (op) {
            .mul, .div, .rem => 13,
            .add, .sub => 12,
            .lt, .le, .gt, .ge => 10,
            .strict_eq, .strict_ne => 9,
            .bit_or => 6,
            .logical_and => 5,
            .logical_or => 4,
        };
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

    pub fn text(op: UnaryOp) []const u8 {
        return switch (op) {
            .neg => "-",
            .not => "!",
            .type_of => "typeof ",
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
/// reference, and would make M3c's rename a string rewrite instead of a
/// symbol swap. Why a disambiguator: two locals in sibling branches of one
/// function can share a source name, and JavaScript's scoping is not
/// beni's.
pub const Name = struct {
    module: Symbol.Optional,
    base: Symbol,
    tag: u32,

    pub const no_tag: u32 = 0;

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

    pub fn int(i: NameIndex) u32 {
        return @intFromEnum(i);
    }

    pub fn unwrap(i: NameIndex) ?u32 {
        return if (i == .none) null else @intFromEnum(i);
    }
};

/// Index into `extra`.
pub const ExtraIndex = enum(u32) { _ };

/// A half-open range `[start, end)` of `extra`.
pub const SubRange = struct {
    start: ExtraIndex,
    end: ExtraIndex,

    pub const empty: SubRange = .{ .start = @enumFromInt(0), .end = @enumFromInt(0) };

    pub fn len(r: SubRange) u32 {
        return @intFromEnum(r.end) - @intFromEnum(r.start);
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

pub fn tag(ir: *const JsIr, node: Node.Index) Node.Tag {
    return ir.nodes.items(.tag)[node.int()];
}

pub fn data(ir: *const JsIr, node: Node.Index) Node.Data {
    return ir.nodes.items(.data)[node.int()];
}

pub fn pos(ir: *const JsIr, node: Node.Index) u32 {
    return ir.nodes.items(.pos)[node.int()];
}

pub fn name(ir: *const JsIr, index: NameIndex) Name {
    return ir.names[index.int()];
}

/// The bytes of a `number`, `string` or `template_chunk` node.
pub fn bytes(ir: *const JsIr, node: Node.Index) []const u8 {
    const d = ir.data(node);
    return ir.string_bytes[d.lhs..][0..d.rhs];
}

/// The elements of a range, viewed as `T` (`Node.Index`, `NameIndex`, `u32`).
pub fn extraSlice(ir: *const JsIr, range: SubRange, comptime T: type) []const T {
    comptime std.debug.assert(@sizeOf(T) % 4 == 0 and @alignOf(T) == 4);
    const words = ir.extra[@intFromEnum(range.start)..@intFromEnum(range.end)];
    return @ptrCast(@alignCast(words));
}

/// Read a record out of `extra` starting at `index`, field by field.
pub fn extraData(ir: *const JsIr, index: ExtraIndex, comptime T: type) T {
    var i: usize = @intFromEnum(index);
    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        @field(result, field.name) = switch (@typeInfo(field.type)) {
            .@"enum" => @enumFromInt(ir.extra[i]),
            .int => ir.extra[i],
            else => @compileError("unexpected extra field type: " ++ @typeName(field.type)),
        };
        i += 1;
    }
    return result;
}

pub fn extraLen(comptime T: type) u32 {
    return @intCast(std.meta.fields(T).len);
}

/// The `SubRange` stored at `index`.
pub fn subRange(ir: *const JsIr, index: ExtraIndex) SubRange {
    return ir.extraData(index, SubRange);
}

/// The range stored inline in `lhs..rhs`.
pub fn inlineRange(d: Node.Data) SubRange {
    return .{ .start = @enumFromInt(d.lhs), .end = @enumFromInt(d.rhs) };
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
    for (0..ir.nodes.len) |i| try ir.verifyNode(@enumFromInt(i));
}

const Position = enum { statement, expression, either };

fn verifyRange(ir: *const JsIr, range: SubRange, position: Position) VerifyError!void {
    if (@intFromEnum(range.start) > @intFromEnum(range.end)) return error.OutOfBounds;
    if (@intFromEnum(range.end) > ir.extra.len) return error.OutOfBounds;
    for (ir.extraSlice(range, Node.Index)) |child| try ir.verifyChild(child, position);
}

fn verifySpecs(ir: *const JsIr, range: SubRange) VerifyError!void {
    if (@intFromEnum(range.start) > @intFromEnum(range.end)) return error.OutOfBounds;
    if (@intFromEnum(range.end) > ir.extra.len) return error.OutOfBounds;
    if (range.len() % Specifier.words != 0) return error.OutOfBounds;
    for (ir.extraSlice(range, NameIndex)) |n| try ir.verifyName(n, false);
}

fn verifyNames(ir: *const JsIr, range: SubRange) VerifyError!void {
    if (@intFromEnum(range.start) > @intFromEnum(range.end)) return error.OutOfBounds;
    if (@intFromEnum(range.end) > ir.extra.len) return error.OutOfBounds;
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
    const o: Node.OptionalIndex = @enumFromInt(raw);
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
    const start: usize = @intFromEnum(index);
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
            const imp = try ir.verifyExtra(@enumFromInt(d.lhs), Import);
            if (@as(usize, imp.source_start) + imp.source_len > ir.string_bytes.len) return error.OutOfBounds;
            try ir.verifySpecs(imp.specs());
        },
        .export_stmt => try ir.verifyNames(inlineRange(d)),
        .const_decl => {
            try ir.verifyName(@enumFromInt(d.lhs), false);
            try ir.verifyChild(@enumFromInt(d.rhs), .expression);
        },
        .let_decl => {
            try ir.verifyName(@enumFromInt(d.lhs), false);
            try ir.verifyOptional(d.rhs, .expression);
        },
        .func_decl => {
            try ir.verifyName(@enumFromInt(d.lhs), false);
            try ir.verifyFunc(@enumFromInt(d.rhs));
        },
        .assign_stmt => {
            try ir.verifyChild(@enumFromInt(d.lhs), .expression);
            try ir.verifyChild(@enumFromInt(d.rhs), .expression);
        },
        .return_stmt => try ir.verifyOptional(d.lhs, .expression),
        .if_stmt => {
            try ir.verifyChild(@enumFromInt(d.lhs), .expression);
            const branches = try ir.verifyExtra(@enumFromInt(d.rhs), If);
            try ir.verifyRange(branches.thenBody(), .statement);
            try ir.verifyRange(branches.elseBody(), .statement);
        },
        .while_true => {
            try ir.verifyName(@enumFromInt(d.lhs), true);
            try ir.verifyRange(try ir.verifyExtra(@enumFromInt(d.rhs), SubRange), .statement);
        },
        .break_stmt, .continue_stmt => try ir.verifyName(@enumFromInt(d.lhs), true),
        .switch_stmt => {
            try ir.verifyChild(@enumFromInt(d.lhs), .expression);
            const cases = try ir.verifyExtra(@enumFromInt(d.rhs), SubRange);
            if (@intFromEnum(cases.start) > @intFromEnum(cases.end) or @intFromEnum(cases.end) > ir.extra.len) {
                return error.OutOfBounds;
            }
            for (ir.extraSlice(cases, Node.Index)) |c| {
                if (c.int() >= ir.nodes.len) return error.OutOfBounds;
                if (ir.tag(c) != .switch_case) return error.WrongPosition;
            }
        },
        .switch_case => {
            try ir.verifyOptional(d.lhs, .expression);
            try ir.verifyRange(try ir.verifyExtra(@enumFromInt(d.rhs), SubRange), .statement);
        },
        .block_stmt => {
            try ir.verifyName(@enumFromInt(d.lhs), true);
            try ir.verifyRange(try ir.verifyExtra(@enumFromInt(d.rhs), SubRange), .statement);
        },
        .expr_stmt, .throw_stmt => try ir.verifyChild(@enumFromInt(d.lhs), .expression),

        .ident => try ir.verifyName(@enumFromInt(d.lhs), false),
        .number, .string, .template_chunk => try ir.verifyBytes(d),
        .template => {
            const parts = inlineRange(d);
            if (@intFromEnum(parts.start) > @intFromEnum(parts.end) or @intFromEnum(parts.end) > ir.extra.len) {
                return error.OutOfBounds;
            }
            for (ir.extraSlice(parts, Node.Index)) |part| try ir.verifyChild(part, .expression);
        },
        .true_lit, .false_lit, .null_lit, .undefined_lit => {},
        .call => {
            try ir.verifyChild(@enumFromInt(d.lhs), .expression);
            try ir.verifyRange(try ir.verifyExtra(@enumFromInt(d.rhs), SubRange), .expression);
        },
        .member => {
            try ir.verifyChild(@enumFromInt(d.lhs), .expression);
            try ir.verifyName(@enumFromInt(d.rhs), false);
        },
        .index_get => {
            try ir.verifyChild(@enumFromInt(d.lhs), .expression);
            try ir.verifyChild(@enumFromInt(d.rhs), .expression);
        },
        .object => {
            const props = inlineRange(d);
            if (@intFromEnum(props.start) > @intFromEnum(props.end) or @intFromEnum(props.end) > ir.extra.len) {
                return error.OutOfBounds;
            }
            for (ir.extraSlice(props, Node.Index)) |p| {
                if (p.int() >= ir.nodes.len) return error.OutOfBounds;
                if (ir.tag(p) != .property and ir.tag(p) != .spread_property) return error.WrongPosition;
            }
        },
        .property => {
            try ir.verifyName(@enumFromInt(d.lhs), false);
            try ir.verifyChild(@enumFromInt(d.rhs), .expression);
        },
        .spread_property => try ir.verifyChild(@enumFromInt(d.lhs), .expression),
        .array => {
            const parts = inlineRange(d);
            if (@intFromEnum(parts.start) > @intFromEnum(parts.end) or @intFromEnum(parts.end) > ir.extra.len) {
                return error.OutOfBounds;
            }
            for (ir.extraSlice(parts, Node.Index)) |e| try ir.verifyChild(e, .expression);
        },
        .arrow => try ir.verifyFunc(@enumFromInt(d.lhs)),
        .cond => {
            try ir.verifyChild(@enumFromInt(d.lhs), .expression);
            const c = try ir.verifyExtra(@enumFromInt(d.rhs), Cond);
            try ir.verifyChild(c.consequent, .expression);
            try ir.verifyChild(c.alternate, .expression);
        },
        .binary => {
            const b = try ir.verifyExtra(@enumFromInt(d.lhs), Binary);
            try ir.verifyChild(b.left, .expression);
            try ir.verifyChild(b.right, .expression);
            if (d.rhs >= @typeInfo(BinaryOp).@"enum".fields.len) return error.OutOfBounds;
        },
        .unary => {
            try ir.verifyChild(@enumFromInt(d.lhs), .expression);
            if (d.rhs >= @typeInfo(UnaryOp).@"enum".fields.len) return error.OutOfBounds;
        },
    }
}

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------

/// The growable form. `js/Lower.zig` owns one per module and calls
/// `toOwned` at the end; nothing else builds a `JsIr`.
///
/// Names are deduplicated through a hash map keyed by the `Name` VALUE and
/// not by a dense id, so the house rule of §5 is satisfied: a `Name` is a
/// sparse key (a pair of interner indices), exactly the case the rule
/// exempts. Deduplicating matters because M3c's renamer wants one row per
/// distinct identifier, and because a reference is then an integer compare.
pub const Builder = struct {
    gpa: Allocator,
    nodes: NodeList = .empty,
    extra: std.ArrayList(u32) = .empty,
    string_bytes: std.ArrayList(u8) = .empty,
    names: std.ArrayList(Name) = .empty,
    name_index: std.AutoHashMapUnmanaged(NameKey, NameIndex) = .empty,

    const NameKey = struct { module: u32, base: u32, tag: u32 };

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        b.nodes.deinit(b.gpa);
        b.extra.deinit(b.gpa);
        b.string_bytes.deinit(b.gpa);
        b.names.deinit(b.gpa);
        b.name_index.deinit(b.gpa);
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
        return ir;
    }

    pub fn addNode(b: *Builder, node: Node) Allocator.Error!Node.Index {
        const index: u32 = @intCast(b.nodes.len);
        try b.nodes.append(b.gpa, node);
        return @enumFromInt(index);
    }

    pub fn intern(b: *Builder, n: Name) Allocator.Error!NameIndex {
        const key: NameKey = .{ .module = @intFromEnum(n.module), .base = @intFromEnum(n.base), .tag = n.tag };
        const got = try b.name_index.getOrPut(b.gpa, key);
        if (got.found_existing) return got.value_ptr.*;
        const index: NameIndex = @enumFromInt(@as(u32, @intCast(b.names.items.len)));
        b.names.append(b.gpa, n) catch |err| {
            _ = b.name_index.remove(key);
            return err;
        };
        got.value_ptr.* = index;
        return index;
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
        return .{ .start = @enumFromInt(start), .end = @enumFromInt(start + words.len) };
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
        inline for (std.meta.fields(@TypeOf(value))) |field| {
            const v = @field(value, field.name);
            const word: u32 = switch (@typeInfo(field.type)) {
                .@"enum" => @intFromEnum(v),
                .int => v,
                else => @compileError("unexpected extra field type: " ++ @typeName(field.type)),
            };
            try b.extra.append(b.gpa, word);
        }
        return @enumFromInt(index);
    }
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
    const f = ir.extraData(@enumFromInt(0), Func);
    try testing.expectEqual(@as(u32, 3), @intFromEnum(f.params_start));
    try testing.expectEqual(@as(u32, 9), @intFromEnum(f.body_end));
    try testing.expectEqual(@as(u32, 1), f.params().len());
    try testing.expectEqual(@as(u32, 2), f.body().len());
    const c = ir.extraData(@enumFromInt(4), Cond);
    try testing.expectEqual(@as(u32, 11), c.consequent.int());
    try testing.expectEqual(@as(u32, 12), c.alternate.int());
}

test "names are deduplicated by value, so a reference is an integer compare" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();
    const a = try b.intern(.local(@enumFromInt(7)));
    const again = try b.intern(.local(@enumFromInt(7)));
    const other = try b.intern(.local(@enumFromInt(8)));
    const tagged = try b.intern(.{ .module = .none, .base = @enumFromInt(7), .tag = 1 });
    const qualified = try b.intern(.qualified(@enumFromInt(3), @enumFromInt(7)));
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

    const x = try b.intern(.local(@enumFromInt(0)));
    const one_offset, const one_len = try b.addString("1");
    const one = try b.addNode(.{ .tag = .number, .pos = 0, .data = .{ .lhs = one_offset, .rhs = one_len } });
    const decl = try b.addNode(.{ .tag = .const_decl, .pos = 0, .data = .{ .lhs = @intFromEnum(x), .rhs = one.int() } });
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
    ir.nodes.items(.data)[decl.int()].lhs = @intFromEnum(x);

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

    const x = try b.intern(.local(@enumFromInt(0)));
    const ident = try b.addNode(.{ .tag = .ident, .pos = Node.no_pos, .data = .{ .lhs = @intFromEnum(x), .rhs = 0 } });
    const ret = try b.addNode(.{ .tag = .return_stmt, .pos = Node.no_pos, .data = .{
        .lhs = @intFromEnum(ident.toOptional()),
        .rhs = 0,
    } });
    // `const x = return x;` — a statement where the value belongs.
    const bad = try b.addNode(.{ .tag = .const_decl, .pos = Node.no_pos, .data = .{
        .lhs = @intFromEnum(x),
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

    const x = try b.intern(.local(@enumFromInt(0)));
    const ident = try b.addNode(.{ .tag = .ident, .pos = Node.no_pos, .data = .{ .lhs = @intFromEnum(x), .rhs = 0 } });
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
