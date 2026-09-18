//! `JsIr` to bytes (docs/design/backend.md §3, fast-compiler.md §9.2): one
//! pass over the tree, straight into a joiner, never a concatenation.
//!
//! **Assembly follows esbuild's `Joiner`** (§9.2): the pass accumulates
//! `{data, offset}` pieces and a running length, then allocates the output
//! buffer EXACTLY once and blits. Most pieces are borrowed — an identifier's
//! bytes live in the interner, a string literal's in the IR's
//! `string_bytes`, punctuation and indentation in `.rodata` — so the common
//! case copies nothing until the final blit. The few pieces the printer has
//! to compute (an escaped string, a disambiguator suffix) go into one
//! scratch buffer and are referenced BY OFFSET, because the scratch grows
//! and a slice into it would dangle.
//!
//! **This milestone prints readably** (backend.md §2: development output has
//! no elimination and readable names). Real indentation, `Module$name`
//! identifiers, string constructor tags, one statement per line. §9's
//! compact printing is one boolean on this pass and is M3c's, so nothing
//! here bakes the spacing into the IR.
//!
//! **Parenthesisation is computed, not stored.** `JsIr` holds structure;
//! there is no `paren` node. The printer knows JavaScript's precedence table
//! and brackets a child that binds less tightly than its parent. That keeps
//! M3c's peephole free to rewrite `a + (b * c)` into anything without having
//! to maintain parentheses as data.
//!
//! **Reserved words are escaped at the last moment.** beni's keyword set is
//! not JavaScript's — `foo new = new + 1` is a legal beni definition — so a
//! bare local whose text is a JavaScript reserved word is printed with a `$`
//! prefix. Top-level names are already `Module$base` and cannot collide, and
//! a property key or a name after `.` may be a reserved word in ES5 and
//! later, so neither is touched.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const JsIr = @import("JsIr.zig");
const Opt = @import("Opt.zig");

const Node = JsIr.Node;
const Index = Node.Index;

/// How the printer turns a `Symbol` into text: the session's global pool
/// after a run, or a worker's local pool in a hermetic test. Same shape as
/// `dump/bir.zig`'s `Names`, and for the same reason — the printer must not
/// depend on which pool it is reading.
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

/// What `--release` changes about one module's bytes (backend.md §9's
/// *The release optimiser*). All of it defaults to "what a dev build does",
/// so development output cannot move by accident: the flag adds a plan and
/// nothing else.
pub const Options = struct {
    /// §9 item 1's answer: the statements to skip and the names to
    /// substitute. The empty plan is a dev build.
    plan: *const Opt.Plan = &Opt.Plan.none,
};

/// Print `ir` as an ES module. The caller owns the returned bytes.
pub fn print(gpa: Allocator, ir: *const JsIr, names: Names, options: Options) Allocator.Error![]u8 {
    var p: Printer = .{ .joiner = .init(gpa), .ir = ir, .names = names, .plan = options.plan };
    defer p.joiner.deinit();
    try p.statements(ir.body, 0);
    return p.joiner.blit();
}

// ---------------------------------------------------------------------------
// The joiner (fast-compiler.md §9.2)
// ---------------------------------------------------------------------------

/// Accumulate pieces, allocate once, blit. A piece is either borrowed —
/// bytes that outlive the joiner, which is every identifier, literal and
/// punctuation string — or a range of the joiner's own scratch, held as an
/// OFFSET because the scratch reallocates as it grows.
pub const Joiner = struct {
    gpa: Allocator,
    pieces: std.ArrayList(Piece) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    length: usize = 0,

    const Piece = struct {
        /// Null means "the joiner's scratch at `offset`".
        borrowed: ?[*]const u8,
        offset: u32,
        len: u32,
    };

    pub fn init(gpa: Allocator) Joiner {
        return .{ .gpa = gpa };
    }

    pub fn deinit(j: *Joiner) void {
        j.pieces.deinit(j.gpa);
        j.scratch.deinit(j.gpa);
    }

    /// Append bytes that outlive the joiner. Nothing is copied.
    pub fn push(j: *Joiner, text: []const u8) Allocator.Error!void {
        if (text.len == 0) return;
        try j.pieces.append(j.gpa, .{ .borrowed = text.ptr, .offset = 0, .len = @intCast(text.len) });
        j.length += text.len;
    }

    /// Append bytes the printer computed. Copied into the scratch once.
    pub fn pushOwned(j: *Joiner, text: []const u8) Allocator.Error!void {
        if (text.len == 0) return;
        const offset: u32 = @intCast(j.scratch.items.len);
        try j.scratch.appendSlice(j.gpa, text);
        try j.pieces.append(j.gpa, .{ .borrowed = null, .offset = offset, .len = @intCast(text.len) });
        j.length += text.len;
    }

    /// Everything pushed so far, in one allocation. The caller owns it.
    pub fn blit(j: *Joiner) Allocator.Error![]u8 {
        const out = try j.gpa.alloc(u8, j.length);
        var at: usize = 0;
        for (j.pieces.items) |piece| {
            const source = if (piece.borrowed) |ptr| ptr[0..piece.len] else j.scratch.items[piece.offset..][0..piece.len];
            @memcpy(out[at..][0..piece.len], source);
            at += piece.len;
        }
        std.debug.assert(at == j.length);
        return out;
    }
};

// ---------------------------------------------------------------------------
// The pass
// ---------------------------------------------------------------------------

/// 64 spaces: indentation is pushed as a borrowed slice of this, so nesting
/// costs no allocation. Deeper than 32 levels repeats the slice.
const spaces = " " ** 64;

/// Precedence used for "this needs no brackets at all": above every
/// operator, below a call's callee position.
const prec_primary: u8 = 20;
/// A call, a member access and an index are all left-binding postfix forms.
const prec_call: u8 = 18;
const prec_unary: u8 = 14;
const prec_cond: u8 = 3;
const prec_arrow: u8 = 2;

const Printer = struct {
    joiner: Joiner,
    ir: *const JsIr,
    names: Names,
    /// §9 item 1's plan. `Opt.Plan.none` for a development build, where every
    /// test below is a compare against an empty slice.
    plan: *const Opt.Plan = &Opt.Plan.none,

    fn indent(p: *Printer, level: u32) Allocator.Error!void {
        var left: usize = @as(usize, level) * 2;
        while (left > spaces.len) : (left -= spaces.len) try p.joiner.push(spaces);
        try p.joiner.push(spaces[0..left]);
    }

    // ---- Names ------------------------------------------------------------

    /// `Module$base`, with the module's dots turned into `$`, plus a
    /// `$<tag>` suffix when the name carries a disambiguator.
    fn name(p: *Printer, index: JsIr.NameIndex, escape_reserved: bool) Allocator.Error!void {
        const n = p.ir.name(index);
        if (n.module.unwrap()) |module| {
            const text = p.names.text(module);
            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, text, start, '.')) |dot| {
                try p.joiner.push(text[start..dot]);
                try p.joiner.push("$");
                start = dot + 1;
            }
            try p.joiner.push(text[start..]);
            try p.joiner.push("$");
        }
        const base = p.names.text(n.base);
        if (n.module == .none and escape_reserved and isReservedWord(base)) try p.joiner.push("$");
        try p.joiner.push(base);
        if (n.tag != JsIr.Name.no_tag) {
            var buf: [12]u8 = undefined;
            try p.joiner.pushOwned(std.fmt.bufPrint(&buf, "${d}", .{n.tag}) catch "$x");
        }
    }

    // ---- Statements -------------------------------------------------------

    fn statements(p: *Printer, range: JsIr.SubRange, level: u32) Allocator.Error!void {
        for (p.ir.extraSlice(range, Index)) |node| {
            // §9 item 1: a binding nothing reads, or one whose single use
            // reads its initialiser instead. Skipped before the indentation,
            // so the line goes whole.
            if (p.plan.isDropped(node)) continue;
            try p.statement(node, level);
        }
    }

    fn statement(p: *Printer, node: Index, level: u32) Allocator.Error!void {
        const d = p.ir.data(node);
        try p.indent(level);
        switch (p.ir.tag(node)) {
            .import_stmt => {
                const imp = p.ir.extraData(@enumFromInt(d.lhs), JsIr.Import);
                try p.joiner.push("import { ");
                const specs = p.ir.extraSlice(imp.specs(), JsIr.Specifier);
                for (specs, 0..) |spec, i| {
                    if (i != 0) try p.joiner.push(", ");
                    try p.name(spec.imported, false);
                    if (spec.imported != spec.local) {
                        try p.joiner.push(" as ");
                        try p.name(spec.local, false);
                    }
                }
                try p.joiner.push(" } from \"");
                try p.joiner.push(p.ir.string_bytes[imp.source_start..][0..imp.source_len]);
                try p.joiner.push("\";\n");
            },
            .export_stmt => {
                try p.joiner.push("export { ");
                for (p.ir.extraSlice(JsIr.inlineRange(d), JsIr.NameIndex), 0..) |n, i| {
                    if (i != 0) try p.joiner.push(", ");
                    try p.name(n, false);
                }
                try p.joiner.push(" };\n");
            },
            .const_decl => {
                try p.joiner.push("const ");
                try p.name(@enumFromInt(d.lhs), true);
                try p.joiner.push(" = ");
                try p.expression(@enumFromInt(d.rhs), 0, level);
                try p.joiner.push(";\n");
            },
            .let_decl => {
                try p.joiner.push("let ");
                try p.name(@enumFromInt(d.lhs), true);
                if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |value| {
                    try p.joiner.push(" = ");
                    try p.expression(value, 0, level);
                }
                try p.joiner.push(";\n");
            },
            .func_decl => {
                try p.joiner.push("function ");
                try p.name(@enumFromInt(d.lhs), true);
                const f = p.ir.extraData(@enumFromInt(d.rhs), JsIr.Func);
                try p.params(f);
                try p.joiner.push(" {\n");
                try p.statements(f.body(), level + 1);
                try p.indent(level);
                try p.joiner.push("}\n");
            },
            .assign_stmt => {
                try p.expression(@enumFromInt(d.lhs), 0, level);
                try p.joiner.push(" = ");
                try p.expression(@enumFromInt(d.rhs), 0, level);
                try p.joiner.push(";\n");
            },
            .return_stmt => {
                try p.joiner.push("return");
                if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |value| {
                    try p.joiner.push(" ");
                    try p.expression(value, 0, level);
                }
                try p.joiner.push(";\n");
            },
            .if_stmt => {
                const branches = p.ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                try p.joiner.push("if (");
                try p.expression(@enumFromInt(d.lhs), 0, level);
                try p.joiner.push(") {\n");
                try p.statements(branches.thenBody(), level + 1);
                try p.indent(level);
                if (branches.elseBody().len() == 0) {
                    try p.joiner.push("}\n");
                } else {
                    try p.joiner.push("} else {\n");
                    try p.statements(branches.elseBody(), level + 1);
                    try p.indent(level);
                    try p.joiner.push("}\n");
                }
            },
            .while_true => {
                if (@as(JsIr.NameIndex, @enumFromInt(d.lhs)) != .none) {
                    try p.name(@enumFromInt(d.lhs), true);
                    try p.joiner.push(": ");
                }
                try p.joiner.push("while (true) {\n");
                try p.statements(p.ir.subRange(@enumFromInt(d.rhs)), level + 1);
                try p.indent(level);
                try p.joiner.push("}\n");
            },
            .break_stmt, .continue_stmt => {
                try p.joiner.push(if (p.ir.tag(node) == .break_stmt) "break" else "continue");
                if (@as(JsIr.NameIndex, @enumFromInt(d.lhs)) != .none) {
                    try p.joiner.push(" ");
                    try p.name(@enumFromInt(d.lhs), true);
                }
                try p.joiner.push(";\n");
            },
            .switch_stmt => {
                try p.joiner.push("switch (");
                try p.expression(@enumFromInt(d.lhs), 0, level);
                try p.joiner.push(") {\n");
                for (p.ir.extraSlice(p.ir.subRange(@enumFromInt(d.rhs)), Index)) |c| {
                    try p.statement(c, level + 1);
                }
                try p.indent(level);
                try p.joiner.push("}\n");
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |test_expr| {
                    try p.joiner.push("case ");
                    try p.expression(test_expr, 0, level);
                    try p.joiner.push(":\n");
                } else {
                    try p.joiner.push("default:\n");
                }
                try p.statements(p.ir.subRange(@enumFromInt(d.rhs)), level + 1);
            },
            .block_stmt => {
                if (@as(JsIr.NameIndex, @enumFromInt(d.lhs)) != .none) {
                    try p.name(@enumFromInt(d.lhs), true);
                    try p.joiner.push(": ");
                }
                try p.joiner.push("{\n");
                try p.statements(p.ir.subRange(@enumFromInt(d.rhs)), level + 1);
                try p.indent(level);
                try p.joiner.push("}\n");
            },
            .expr_stmt => {
                try p.expression(@enumFromInt(d.lhs), 0, level);
                try p.joiner.push(";\n");
            },
            .throw_stmt => {
                try p.joiner.push("throw ");
                try p.expression(@enumFromInt(d.lhs), 0, level);
                try p.joiner.push(";\n");
            },
            // An expression where a statement belongs is a builder bug, not
            // a possible consequence of user input (`JsIr.verify` is the
            // instrument that proves it). Printing it as an expression
            // statement keeps the output valid JavaScript rather than
            // truncating the file, so a bug shows up as a test failure with
            // readable bytes instead of as a panic.
            else => {
                try p.expression(node, 0, level);
                try p.joiner.push(";\n");
            },
        }
    }

    fn params(p: *Printer, f: JsIr.Func) Allocator.Error!void {
        try p.joiner.push("(");
        for (p.ir.extraSlice(f.params(), JsIr.NameIndex), 0..) |n, i| {
            if (i != 0) try p.joiner.push(", ");
            try p.name(n, true);
        }
        try p.joiner.push(")");
    }

    // ---- Expressions ------------------------------------------------------

    /// Print `node`, bracketing it when its own precedence is below
    /// `min_prec`. `level` is the statement indentation a nested block body
    /// continues from.
    fn expression(p: *Printer, node: Index, min_prec: u8, level: u32) Allocator.Error!void {
        // §9 item 1's substitution happens BEFORE the precedence is read, so
        // the brackets are computed from what is actually printed. An inlined
        // initialiser is an atom or a member chain, so this can only ever
        // relax a bracket — except for a number, which `precedence` puts below
        // a member access on purpose.
        const resolved = p.resolve(node);
        const own = p.precedence(resolved);
        const bracket = own < min_prec;
        if (bracket) try p.joiner.push("(");
        try p.raw(resolved, level);
        if (bracket) try p.joiner.push(")");
    }

    /// Follow §9 item 1's substitutions to the node that is really printed.
    /// A chain of them — `const x = p.a; const y = x.b;` — collapses here, so
    /// the pass itself needs neither a fixpoint nor a backward walk. The
    /// budget makes a malformed plan a wrong spelling rather than a hang.
    fn resolve(p: *Printer, node: Index) Index {
        var n = node;
        var budget: u32 = 64;
        while (budget > 0 and p.ir.tag(n) == .ident) : (budget -= 1) {
            n = p.plan.replacement(n) orelse return n;
        }
        return n;
    }

    fn precedence(p: *Printer, node: Index) u8 {
        return switch (p.ir.tag(node)) {
            .binary => JsIr.BinaryOp.precedence(@enumFromInt(p.ir.data(node).rhs)),
            .unary => prec_unary,
            .cond => prec_cond,
            .arrow => prec_arrow,
            .call, .member, .index_get => prec_call,
            // A numeric literal is not a primary expression for the purpose
            // of what may follow it: `1.a` is a syntax error, because the dot
            // reads as a decimal point. Below `prec_call` is exactly the rule
            // — bracketed in a member, index or callee position and nowhere
            // else, since no other position asks for more than `prec_unary`.
            // Nothing in a dev build reaches it; §9 item 1 can, by inlining a
            // literal into the object position of a member access.
            .number => prec_call - 1,
            else => prec_primary,
        };
    }

    fn raw(p: *Printer, node: Index, level: u32) Allocator.Error!void {
        const d = p.ir.data(node);
        switch (p.ir.tag(node)) {
            .ident => try p.name(@enumFromInt(d.lhs), true),
            .number => try p.joiner.push(p.ir.bytes(node)),
            .string => try p.quoted(p.ir.bytes(node)),
            .template => {
                try p.joiner.push("`");
                for (p.ir.extraSlice(JsIr.inlineRange(d), Index)) |part| {
                    if (p.ir.tag(part) == .template_chunk) {
                        try p.templateChunk(p.ir.bytes(part));
                        continue;
                    }
                    try p.joiner.push("${");
                    try p.expression(part, 0, level);
                    try p.joiner.push("}");
                }
                try p.joiner.push("`");
            },
            .template_chunk => try p.templateChunk(p.ir.bytes(node)),
            .true_lit => try p.joiner.push("true"),
            .false_lit => try p.joiner.push("false"),
            .null_lit => try p.joiner.push("null"),
            .undefined_lit => try p.joiner.push("undefined"),
            .call => {
                try p.expression(@enumFromInt(d.lhs), prec_call, level);
                try p.joiner.push("(");
                for (p.ir.extraSlice(p.ir.subRange(@enumFromInt(d.rhs)), Index), 0..) |arg, i| {
                    if (i != 0) try p.joiner.push(", ");
                    try p.expression(arg, prec_arrow, level);
                }
                try p.joiner.push(")");
            },
            .member => {
                // A numeric literal needs a bracket before `.` (`1.a` is a
                // syntax error), and so does an arrow or a conditional.
                try p.expression(@enumFromInt(d.lhs), prec_call, level);
                try p.joiner.push(".");
                try p.name(@enumFromInt(d.rhs), false);
            },
            .index_get => {
                try p.expression(@enumFromInt(d.lhs), prec_call, level);
                try p.joiner.push("[");
                try p.expression(@enumFromInt(d.rhs), 0, level);
                try p.joiner.push("]");
            },
            .object => {
                const props = p.ir.extraSlice(JsIr.inlineRange(d), Index);
                if (props.len == 0) {
                    try p.joiner.push("{}");
                    return;
                }
                try p.joiner.push("{ ");
                for (props, 0..) |prop, i| {
                    if (i != 0) try p.joiner.push(", ");
                    try p.raw(prop, level);
                }
                try p.joiner.push(" }");
            },
            .property => {
                try p.name(@enumFromInt(d.lhs), false);
                try p.joiner.push(": ");
                try p.expression(@enumFromInt(d.rhs), prec_arrow, level);
            },
            .spread_property => {
                try p.joiner.push("...");
                try p.expression(@enumFromInt(d.lhs), prec_arrow, level);
            },
            .array => {
                try p.joiner.push("[");
                for (p.ir.extraSlice(JsIr.inlineRange(d), Index), 0..) |e, i| {
                    if (i != 0) try p.joiner.push(", ");
                    try p.expression(e, prec_arrow, level);
                }
                try p.joiner.push("]");
            },
            .arrow => {
                const f = p.ir.extraData(@enumFromInt(d.lhs), JsIr.Func);
                try p.params(f);
                try p.joiner.push(" => ");
                try p.arrowBody(f, level);
            },
            .cond => {
                const c = p.ir.extraData(@enumFromInt(d.rhs), JsIr.Cond);
                try p.expression(@enumFromInt(d.lhs), prec_cond + 1, level);
                try p.joiner.push(" ? ");
                try p.expression(c.consequent, prec_arrow, level);
                try p.joiner.push(" : ");
                try p.expression(c.alternate, prec_arrow, level);
            },
            .binary => {
                const op: JsIr.BinaryOp = @enumFromInt(d.rhs);
                const b = p.ir.extraData(@enumFromInt(d.lhs), JsIr.Binary);
                const prec = op.precedence();
                try p.expression(b.left, prec, level);
                try p.joiner.push(" ");
                try p.joiner.push(op.text());
                try p.joiner.push(" ");
                // Right operand at `prec + 1`: every operator here is
                // left-associative, so `a - (b - c)` must keep its brackets.
                try p.expression(b.right, prec + 1, level);
            },
            .unary => {
                const op: JsIr.UnaryOp = @enumFromInt(d.rhs);
                try p.joiner.push(op.text());
                try p.expression(@enumFromInt(d.lhs), prec_unary, level);
            },
            // A statement in expression position: see `statement`'s `else`.
            else => try p.joiner.push("undefined"),
        }
    }

    /// `(a) => expr` when the body is one `return`, else a braced block.
    /// An object literal returned concisely has to be bracketed, or the
    /// brace reads as the block.
    fn arrowBody(p: *Printer, f: JsIr.Func, level: u32) Allocator.Error!void {
        // The LIVE statements: §9 item 1 can leave a body that was a prologue
        // and a `return` holding only the `return`, and a body that prints
        // concisely should print concisely however it got that way. For a dev
        // build the plan is empty and this is the length of the slice.
        if (p.onlyLive(f.body())) |only| {
            if (p.ir.tag(only) == .return_stmt) {
                if (@as(Node.OptionalIndex, @enumFromInt(p.ir.data(only).lhs)).unwrap()) |value| {
                    const resolved = p.resolve(value);
                    if (p.ir.tag(resolved) == .object) {
                        try p.joiner.push("(");
                        try p.raw(resolved, level);
                        try p.joiner.push(")");
                        return;
                    }
                    try p.expression(resolved, prec_arrow, level);
                    return;
                }
            }
        }
        try p.joiner.push("{\n");
        try p.statements(f.body(), level + 1);
        try p.indent(level);
        try p.joiner.push("}");
    }

    /// The one statement of `range` that survives §9 item 1, or null when it
    /// holds none or more than one. For a dev build the plan is empty, so this
    /// is "the slice has exactly one element".
    fn onlyLive(p: *Printer, range: JsIr.SubRange) ?Index {
        var found: ?Index = null;
        for (p.ir.extraSlice(range, Index)) |node| {
            if (p.plan.isDropped(node)) continue;
            if (found != null) return null;
            found = node;
        }
        return found;
    }

    // ---- Literal text -----------------------------------------------------

    /// A double-quoted JavaScript string. The IR holds decoded bytes, so
    /// every escape is decided here. Non-ASCII bytes pass through: the
    /// output is UTF-8 and so is the input.
    fn quoted(p: *Printer, text: []const u8) Allocator.Error!void {
        try p.joiner.push("\"");
        var run_start: usize = 0;
        for (text, 0..) |c, i| {
            const escape: ?[]const u8 = switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                // U+2028 and U+2029 are line terminators in JavaScript but
                // not in JSON; they arrive here as UTF-8 bytes and are
                // handled by the 0x00..0x1f rule not applying, so they are
                // left alone — a double-quoted string literal admits them
                // since ES2019.
                0...8, 11, 12, 14...31, 127 => blk: {
                    var buf: [6]u8 = undefined;
                    break :blk std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                },
                else => null,
            };
            const e = escape orelse continue;
            try p.joiner.push(text[run_start..i]);
            // A computed escape lives in a stack buffer that is gone by the
            // time the joiner blits, so it has to be copied.
            if (c < 0x20 or c == 127) try p.joiner.pushOwned(e) else try p.joiner.push(e);
            run_start = i + 1;
        }
        try p.joiner.push(text[run_start..]);
        try p.joiner.push("\"");
    }

    /// The literal half of a template: backticks, backslashes and `${` are
    /// the only sequences that end it.
    fn templateChunk(p: *Printer, text: []const u8) Allocator.Error!void {
        var run_start: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const escape: []const u8 = switch (text[i]) {
                '`' => "\\`",
                '\\' => "\\\\",
                '$' => if (i + 1 < text.len and text[i + 1] == '{') "\\$" else continue,
                '\r' => "\\r",
                else => continue,
            };
            try p.joiner.push(text[run_start..i]);
            try p.joiner.push(escape);
            run_start = i + 1;
        }
        try p.joiner.push(text[run_start..]);
    }
};

/// Every reserved word and every contextually reserved word of ECMAScript,
/// plus `arguments` and `eval`, which cannot be bound in strict mode — and
/// an ES module is always strict. beni's keyword set is different, so any
/// of these can be a legal beni identifier.
pub fn isReservedWord(text: []const u8) bool {
    const words = [_][]const u8{
        "arguments", "await",      "break",     "case",    "catch",      "class",
        "const",     "continue",   "debugger",  "default", "delete",     "do",
        "else",      "enum",       "eval",      "export",  "extends",    "false",
        "finally",   "for",        "function",  "if",      "implements", "import",
        "in",        "instanceof", "interface", "let",     "new",        "null",
        "package",   "private",    "protected", "public",  "return",     "static",
        "super",     "switch",     "this",      "throw",   "true",       "try",
        "typeof",    "var",        "void",      "while",   "with",       "yield",
    };
    for (words) |word| {
        if (std.mem.eql(u8, word, text)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
//
// One scenario per node kind, built through `JsIr.Builder` and asserted on
// the bytes. This is the only place the printer's output is a golden, and it
// is narrow on purpose (`backend.md` §12): what a beni construct lowers to is
// `Lower.zig`'s, and what the program computes is `tests/corpus/run/`'s.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A tiny world: an interner, a builder, and `print` over what was built.
const Fixture = struct {
    gpa: Allocator,
    interner: InternPool.Local,
    b: JsIr.Builder,

    fn init(gpa: Allocator) !Fixture {
        return .{ .gpa = gpa, .interner = .empty, .b = .init(gpa) };
    }

    fn deinit(f: *Fixture) void {
        f.b.deinit();
        f.interner.deinit(f.gpa);
    }

    fn sym(f: *Fixture, text: []const u8) !InternPool.Symbol {
        return f.interner.getOrPut(f.gpa, text);
    }

    fn name(f: *Fixture, text: []const u8) !JsIr.NameIndex {
        return f.b.intern(.local(try f.sym(text)));
    }

    fn qualified(f: *Fixture, module: []const u8, base: []const u8) !JsIr.NameIndex {
        return f.b.intern(.qualified(try f.sym(module), try f.sym(base)));
    }

    fn node(f: *Fixture, tag: Node.Tag, lhs: u32, rhs: u32) !Index {
        return f.b.addNode(.{ .tag = tag, .pos = Node.no_pos, .data = .{ .lhs = lhs, .rhs = rhs } });
    }

    fn ident(f: *Fixture, text: []const u8) !Index {
        return f.node(.ident, @intFromEnum(try f.name(text)), 0);
    }

    fn number(f: *Fixture, text: []const u8) !Index {
        const offset, const len = try f.b.addString(text);
        return f.node(.number, offset, len);
    }

    fn string(f: *Fixture, text: []const u8) !Index {
        const offset, const len = try f.b.addString(text);
        return f.node(.string, offset, len);
    }

    fn binary(f: *Fixture, op: JsIr.BinaryOp, l: Index, r: Index) !Index {
        const record = try f.b.addRecord(JsIr.Binary{ .left = l, .right = r });
        return f.node(.binary, @intFromEnum(record), @intFromEnum(op));
    }

    fn constDecl(f: *Fixture, out: *std.ArrayList(Index), n: []const u8, value: Index) !void {
        try out.append(f.gpa, try f.node(.const_decl, @intFromEnum(try f.name(n)), value.int()));
    }

    fn func(f: *Fixture, params: []const JsIr.NameIndex, body: []const Index) !Index {
        const param_range = try f.b.addNames(params);
        const body_range = try f.b.addRange(body);
        const record = try f.b.addRecord(JsIr.Func{
            .params_start = param_range.start,
            .params_end = param_range.end,
            .body_start = body_range.start,
            .body_end = body_range.end,
        });
        return f.node(.arrow, @intFromEnum(record), 0);
    }

    /// Print `statements` as the module body. Owned by the caller.
    fn render(f: *Fixture, statements: []const Index) ![]u8 {
        const body = try f.b.addRange(statements);
        var ir = try f.b.toOwned(body);
        defer ir.deinit(f.gpa);
        try ir.verify();
        return print(f.gpa, &ir, .fromLocal(&f.interner), .{});
    }
};

fn expectPrinted(expected: []const u8, build: anytype) !void {
    const gpa = testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit();
    var statements: std.ArrayList(Index) = .empty;
    defer statements.deinit(gpa);
    try build(&f, &statements);
    const text = try f.render(statements.items);
    defer gpa.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "imports, exports and the three declaration forms" {
    try expectPrinted(
        \\import { add as Basics$add, pi as Basics$pi } from "./Basics.js";
        \\import { Other$f } from "../other/Other.mjs";
        \\const M$one = 1;
        \\let M$two;
        \\function M$f(a, b) {
        \\  return a;
        \\}
        \\export { M$one, M$f };
        \\
    , struct {
        fn go(f: *Fixture, out: *std.ArrayList(Index)) !void {
            const gpa = f.gpa;
            const sibling = [_]JsIr.Specifier{
                .{ .imported = try f.name("add"), .local = try f.qualified("Basics", "add") },
                .{ .imported = try f.name("pi"), .local = try f.qualified("Basics", "pi") },
            };
            try out.append(gpa, try importOf(f, "./Basics.js", &sibling));

            const other = try f.qualified("Other", "f");
            const cross = [_]JsIr.Specifier{.{ .imported = other, .local = other }};
            try out.append(gpa, try importOf(f, "../other/Other.mjs", &cross));

            const one = try f.qualified("M", "one");
            try out.append(gpa, try f.node(.const_decl, @intFromEnum(one), (try f.number("1")).int()));
            const two = try f.qualified("M", "two");
            try out.append(gpa, try f.node(.let_decl, @intFromEnum(two), @intFromEnum(Node.OptionalIndex.none)));

            const a = try f.name("a");
            const b = try f.name("b");
            const ret = try f.node(.return_stmt, @intFromEnum((try f.ident("a")).toOptional()), 0);
            const arrow = try f.func(&.{ a, b }, &.{ret});
            const fname = try f.qualified("M", "f");
            // A `func_decl` and an `arrow` share the `Func` payload, which
            // is why `Func` is a record rather than two inline halves.
            const record = f.b.nodes.items(.data)[arrow.int()].lhs;
            try out.append(gpa, try f.node(.func_decl, @intFromEnum(fname), record));

            const exported = try f.b.addNames(&.{ one, fname });
            try out.append(gpa, try f.node(.export_stmt, @intFromEnum(exported.start), @intFromEnum(exported.end)));
        }

        fn importOf(f: *Fixture, source: []const u8, specs: []const JsIr.Specifier) !Index {
            const offset, const len = try f.b.addString(source);
            const range = try f.b.addExtra(@ptrCast(specs));
            const record = try f.b.addRecord(JsIr.Import{
                .source_start = offset,
                .source_len = len,
                .specs_start = range.start,
                .specs_end = range.end,
            });
            return f.node(.import_stmt, @intFromEnum(record), 0);
        }
    }.go);
}

test "a module name's dots become dollars, so a stack trace reads" {
    try expectPrinted(
        \\const Json$Decode$map = 1;
        \\
    , struct {
        fn go(f: *Fixture, out: *std.ArrayList(Index)) !void {
            const n = try f.qualified("Json.Decode", "map");
            try out.append(f.gpa, try f.node(.const_decl, @intFromEnum(n), (try f.number("1")).int()));
        }
    }.go);
}

test "a local whose text is a JavaScript reserved word is escaped; a property key is not" {
    // beni's keyword set is not JavaScript's: `foo new = new + 1` is legal
    // beni and `new` is not a legal JavaScript binding.
    try expectPrinted(
        \\const $new = $class.new;
        \\
    , struct {
        fn go(f: *Fixture, out: *std.ArrayList(Index)) !void {
            const target = try f.ident("class");
            const key = try f.name("new");
            const access = try f.node(.member, target.int(), @intFromEnum(key));
            try out.append(f.gpa, try f.node(.const_decl, @intFromEnum(key), access.int()));
        }
    }.go);
}

test "if, labelled while, break, continue, switch and throw" {
    try expectPrinted(
        \\loop: while (true) {
        \\  if (a) {
        \\    continue loop;
        \\  } else {
        \\    break;
        \\  }
        \\}
        \\switch (t) {
        \\  case 1:
        \\    x = 2;
        \\  default:
        \\    throw t;
        \\}
        \\
    , struct {
        fn go(f: *Fixture, out: *std.ArrayList(Index)) !void {
            const gpa = f.gpa;
            const label = try f.name("loop");
            const cont = try f.node(.continue_stmt, @intFromEnum(label), 0);
            const brk = try f.node(.break_stmt, @intFromEnum(JsIr.NameIndex.none), 0);
            const then_body = try f.b.addRange(&.{cont});
            const else_body = try f.b.addRange(&.{brk});
            const branches = try f.b.addRecord(JsIr.If{
                .then_start = then_body.start,
                .then_end = then_body.end,
                .else_start = else_body.start,
                .else_end = else_body.end,
            });
            const if_stmt = try f.node(.if_stmt, (try f.ident("a")).int(), @intFromEnum(branches));
            const loop_body = try f.b.addRange(&.{if_stmt});
            const loop_record = try f.b.addRecord(loop_body);
            try out.append(gpa, try f.node(.while_true, @intFromEnum(label), @intFromEnum(loop_record)));

            const assign = try f.node(.assign_stmt, (try f.ident("x")).int(), (try f.number("2")).int());
            const case_body = try f.b.addRange(&.{assign});
            const case_record = try f.b.addRecord(case_body);
            const one_case = try f.node(.switch_case, @intFromEnum((try f.number("1")).toOptional()), @intFromEnum(case_record));
            const throw = try f.node(.throw_stmt, (try f.ident("t")).int(), 0);
            const default_body = try f.b.addRange(&.{throw});
            const default_record = try f.b.addRecord(default_body);
            const default_case = try f.node(.switch_case, @intFromEnum(Node.OptionalIndex.none), @intFromEnum(default_record));
            const cases = try f.b.addRange(&.{ one_case, default_case });
            const cases_record = try f.b.addRecord(cases);
            try out.append(gpa, try f.node(.switch_stmt, (try f.ident("t")).int(), @intFromEnum(cases_record)));
        }
    }.go);
}

test "objects, arrays, spreads, calls, member access and indexing" {
    try expectPrinted(
        \\const v = f(g(x), [1, 2])[0].field;
        \\const o = { ...base, a: 1 };
        \\const empty = {};
        \\
    , struct {
        fn go(f: *Fixture, out: *std.ArrayList(Index)) !void {
            const gpa = f.gpa;
            const inner = try callOf(f, try f.ident("g"), &.{try f.ident("x")});
            const elements = try f.b.addRange(&.{ try f.number("1"), try f.number("2") });
            const array = try f.node(.array, @intFromEnum(elements.start), @intFromEnum(elements.end));
            const call = try callOf(f, try f.ident("f"), &.{ inner, array });
            const indexed = try f.node(.index_get, call.int(), (try f.number("0")).int());
            const field = try f.node(.member, indexed.int(), @intFromEnum(try f.name("field")));
            try f.constDecl(out, "v", field);

            const spread = try f.node(.spread_property, (try f.ident("base")).int(), 0);
            const property = try f.node(.property, @intFromEnum(try f.name("a")), (try f.number("1")).int());
            const properties = try f.b.addRange(&.{ spread, property });
            const object = try f.node(.object, @intFromEnum(properties.start), @intFromEnum(properties.end));
            try f.constDecl(out, "o", object);

            const nothing = try f.b.addRange(&.{});
            const empty_object = try f.node(.object, @intFromEnum(nothing.start), @intFromEnum(nothing.end));
            try f.constDecl(out, "empty", empty_object);
            _ = gpa;
        }

        fn callOf(f: *Fixture, callee: Index, args: []const Index) !Index {
            const range = try f.b.addRange(args);
            const record = try f.b.addRecord(range);
            return f.node(.call, callee.int(), @intFromEnum(record));
        }
    }.go);
}

test "precedence decides the brackets, and every binary operator is left-associative" {
    try expectPrinted(
        \\const a = 1 + 2 * 3;
        \\const b = (1 + 2) * 3;
        \\const c = 1 - (2 - 3);
        \\const d = 1 - 2 - 3;
        \\const e = a === 1 && b === 2 || c;
        \\const g = -(1 + 2);
        \\const h = !a;
        \\
    , struct {
        fn go(f: *Fixture, out: *std.ArrayList(Index)) !void {
            const one = try f.number("1");
            const two = try f.number("2");
            const three = try f.number("3");

            try f.constDecl(out, "a", try f.binary(.add, one, try f.binary(.mul, two, three)));
            const plus = try f.binary(.add, one, two);
            try f.constDecl(out, "b", try f.binary(.mul, plus, three));
            try f.constDecl(out, "c", try f.binary(.sub, one, try f.binary(.sub, two, three)));
            try f.constDecl(out, "d", try f.binary(.sub, try f.binary(.sub, one, two), three));

            const eq_a = try f.binary(.strict_eq, try f.ident("a"), one);
            const eq_b = try f.binary(.strict_eq, try f.ident("b"), two);
            const both = try f.binary(.logical_and, eq_a, eq_b);
            try f.constDecl(out, "e", try f.binary(.logical_or, both, try f.ident("c")));

            try f.constDecl(out, "g", try f.node(.unary, plus.int(), @intFromEnum(JsIr.UnaryOp.neg)));
            try f.constDecl(out, "h", try f.node(.unary, (try f.ident("a")).int(), @intFromEnum(JsIr.UnaryOp.not)));
        }
    }.go);
}

test "an arrow with one return prints concisely; an object body is bracketed" {
    try expectPrinted(
        \\const f = (a) => a;
        \\const g = () => ({ a: 1 });
        \\const h = (a) => {
        \\  const b = a;
        \\  return b;
        \\};
        \\
    , struct {
        fn go(f: *Fixture, out: *std.ArrayList(Index)) !void {
            const a = try f.name("a");
            {
                const ret = try f.node(.return_stmt, @intFromEnum((try f.ident("a")).toOptional()), 0);
                try f.constDecl(out, "f", try f.func(&.{a}, &.{ret}));
            }
            {
                const property = try f.node(.property, @intFromEnum(a), (try f.number("1")).int());
                const properties = try f.b.addRange(&.{property});
                const object = try f.node(.object, @intFromEnum(properties.start), @intFromEnum(properties.end));
                const ret = try f.node(.return_stmt, @intFromEnum(object.toOptional()), 0);
                try f.constDecl(out, "g", try f.func(&.{}, &.{ret}));
            }
            {
                const b = try f.name("b");
                const bind = try f.node(.const_decl, @intFromEnum(b), (try f.ident("a")).int());
                const ret = try f.node(.return_stmt, @intFromEnum((try f.ident("b")).toOptional()), 0);
                try f.constDecl(out, "h", try f.func(&.{a}, &.{ bind, ret }));
            }
        }
    }.go);
}

test "conditionals, the four literals, and the disambiguator suffix" {
    try expectPrinted(
        \\const x$3 = a ? true : false;
        \\const y = null;
        \\const z = undefined;
        \\
    , struct {
        fn go(f: *Fixture, out: *std.ArrayList(Index)) !void {
            const gpa = f.gpa;
            const yes = try f.node(.true_lit, 0, 0);
            const no = try f.node(.false_lit, 0, 0);
            const record = try f.b.addRecord(JsIr.Cond{ .consequent = yes, .alternate = no });
            const cond = try f.node(.cond, (try f.ident("a")).int(), @intFromEnum(record));
            const tagged = try f.b.intern(.{ .module = .none, .base = try f.sym("x"), .tag = 3 });
            try out.append(gpa, try f.node(.const_decl, @intFromEnum(tagged), cond.int()));
            try f.constDecl(out, "y", try f.node(.null_lit, 0, 0));
            try f.constDecl(out, "z", try f.node(.undefined_lit, 0, 0));
        }
    }.go);
}

test "a string literal is escaped where it must be and left alone where it need not be" {
    try expectPrinted(
        "const s = \"a \\\"b\\\" c\\\\d\\ne\\tf\\u0000g \u{e9}\";\n",
        struct {
            fn go(f: *Fixture, out: *std.ArrayList(Index)) !void {
                const value = try f.string("a \"b\" c\\d\ne\tf\x00g \u{e9}");
                try f.constDecl(out, "s", value);
            }
        }.go,
    );
}

test "a template literal escapes only what would end it" {
    try expectPrinted(
        "const t = `a ${b} c\\` d\\${e} f`;\n",
        struct {
            fn go(f: *Fixture, out: *std.ArrayList(Index)) !void {
                const before_offset, const before_len = try f.b.addString("a ");
                const before = try f.node(.template_chunk, before_offset, before_len);
                const middle = try f.ident("b");
                const after_offset, const after_len = try f.b.addString(" c` d${e} f");
                const after = try f.node(.template_chunk, after_offset, after_len);
                const parts = try f.b.addRange(&.{ before, middle, after });
                const template = try f.node(.template, @intFromEnum(parts.start), @intFromEnum(parts.end));
                try f.constDecl(out, "t", template);
            }
        }.go,
    );
}

test "the joiner allocates once and blits, borrowed and owned pieces alike" {
    const gpa = testing.allocator;
    var j: Joiner = .init(gpa);
    defer j.deinit();
    try j.push("hello");
    try j.push("");
    var scratch: [8]u8 = " world!\n".*;
    try j.pushOwned(scratch[0..6]);
    @memset(&scratch, 'x'); // the joiner must have copied
    try j.push("!");
    const out = try j.blit();
    defer gpa.free(out);
    try testing.expectEqualStrings("hello world!", out);
}

test "reserved words are the ECMAScript set, the strict-mode ones included" {
    try testing.expect(isReservedWord("new"));
    try testing.expect(isReservedWord("class"));
    try testing.expect(isReservedWord("await"));
    try testing.expect(isReservedWord("arguments"));
    try testing.expect(isReservedWord("eval"));
    try testing.expect(!isReservedWord("map"));
    try testing.expect(!isReservedWord("newer"));
}
