//! Typed `Bir` to `JsIr` (docs/design/backend.md §4): the mapping table of
//! §4, construct by construct, for the subset M3a needs.
//!
//! **Statements, not an IIFE per `let`.** beni's `let` and `case` are
//! expressions and JavaScript's are not, so every lowering function takes
//! the statement list it may append to and RETURNS an expression. A `let`
//! becomes `const`s in the enclosing list (§4); a `case` becomes an `if`/
//! `else` chain over a `let` the arms assign — or, when no arm needs a
//! statement and no pattern binds anything, one conditional expression, so
//! `if a then b else c` prints as `a ? b : c` and not as four lines.
//!
//! **There is no calling convention** (`backend.md` §6). Currying went on
//! 2026-09-14 (`fast-compiler.md` §9.3) and `language.md` §6.7 specifies
//! the result: every call is saturated, arity is part of the function type,
//! and function types of different arity do not unify. So:
//!
//!   - A declaration, a `foreign`, a lambda, a `let` definition or a
//!     constructor with *n* parameters emits an n-ary JavaScript function
//!     (or, for a constructor, an object literal).
//!   - A beni application of *n* arguments emits `f(a, b)`, whatever the
//!     callee is. No adapter, no property load, no arity comparison, no
//!     call-site curry wrapper — the +49% Chrome figure §9.3 measures for
//!     Elm's `A2` is simply not paid, and the direct-call share is 100% by
//!     construction rather than by measurement.
//!
//!   **The backend never meets a partial application.** The two ways to
//!   write one are front-end rewrites that are gone by the time Bir exists
//!   (`language.md` §8): `f a _` lowers to a lambda over the innermost
//!   enclosing application, and a pipe lowers to a call. A function-typed
//!   value in flight is therefore always a closure of known arity, never
//!   something waiting for more arguments — which is what lets this file
//!   emit a call without knowing anything about the callee.
//!
//! **Representation** is §9.4's, with three departures that `backend.md` §4
//! now records under "Corrections from M3a": `Basics.Bool` is a JavaScript
//! boolean, "nullary constructor is the bare tag" is split on whether the
//! TYPE has any payload at all, and `&&`/`||` are lowered here rather than
//! peepholed at print time because for those two it is the semantics and not
//! an optimisation. `CtorRep` and `logicalOp` carry the argument in full.
//!
//! **Positions.** Every node carries the byte offset of the token its `Bir`
//! instruction came from (§9.6). Maps are off in M3a; the offsets are here
//! because retrofitting them means touching this file, the printer and
//! every pass between.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const JsIr = @import("JsIr.zig");

const Inst = Bir.Inst;
const Node = JsIr.Node;
const Symbol = InternPool.Symbol;

/// What lowering could not translate. M3a implements every construct of
/// backend.md §4 except `?`, which §1 assigns to M3b; the guard reports
/// rather than falling through, because an unhandled tag that silently
/// emitted nothing would be a program that compiles and computes the wrong
/// answer.
pub const Item = struct {
    code: diagnostic.Code,
    module: Graph.Index,
    region: Inst.Index,
    /// Owned by the caller's allocator.
    message: []const u8,
};

pub const Result = struct {
    ir: JsIr,
    /// Owned; messages are gpa-owned.
    diagnostics: []const Item,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.ir.deinit(gpa);
        for (r.diagnostics) |d| gpa.free(d.message);
        gpa.free(r.diagnostics);
        r.* = undefined;
    }
};

/// Re-exported so a caller can name `Dispatch.empty` without reaching past
/// the backend into the checker.
pub const Dispatch = @import("../check/Dispatch.zig");

pub const Input = struct {
    bir: *const Bir,
    /// The module's token start offsets, for `Node.pos`.
    token_starts: []const u32,
    module: Graph.Index,
    graph: *const Graph,
    interfaces: []const Interface,
    /// What the checker decided about every method call of this module
    /// (static-dispatch-spike.md §7). S4 and S5 lower from it; the S4 shim
    /// below reads it only to REFUSE what it cannot honour.
    dispatch: *const Dispatch,
    /// One ESM specifier per graph module, relative to THIS module's output
    /// file: what an `import` from it is written as. A module that cannot
    /// be reached (never referenced) may be an empty string.
    specifiers: []const []const u8,
    /// The specifier of this module's sibling JavaScript file, if it
    /// declares any `foreign` value (`boundary.md` §4).
    sibling: []const u8,
    /// The declaration that is this build's entry point, when it is in this
    /// module: `main` (boundary.md §5). It is exported whether or not it is
    /// `pub`, because the entry file imports it and `main` is not something
    /// a program's own modules call — the same reason M3d's `lazy`
    /// declarations will be exported from their chunks.
    entry_decl: ?u32 = null,
};

/// Lower one checked module. `scratch` is the caller's arena — every
/// intermediate list below lives in it and nothing here frees individually.
/// `interner` gains the handful of compiler-owned names (`$t`, `$x`, `$`)
/// and is read for the field-order sort.
pub fn lower(
    gpa: Allocator,
    scratch: Allocator,
    interner: *InternPool.Global,
    input: Input,
) Allocator.Error!Result {
    var b: JsIr.Builder = .init(gpa);
    // `toOwned` hands the columns over and leaves the lists empty, so this
    // frees the name-dedup table and, on the failure path, everything else.
    defer b.deinit();

    var l: Lowerer = .{
        .gpa = gpa,
        .scratch = scratch,
        .b = &b,
        .interner = interner,
        .in = input,
        .bir = input.bir,
        .module_name = input.graph.moduleName(input.module),
        .well = .{
            .temp = try interner.getOrPut(gpa, "$t"),
            .ctor_arg = try interner.getOrPut(gpa, "$x"),
            .param = try interner.getOrPut(gpa, "$p"),
            .tag = try interner.getOrPut(gpa, "$"),
        },
    };
    defer l.diagnostics.deinit(gpa);
    errdefer for (l.diagnostics.items) |d| gpa.free(d.message);

    // Declarations first: the import list is what lowering DISCOVERS (the
    // §9.1 reference edges are a byproduct of resolution, not a pass), so
    // the statements that name those imports can only be built once every
    // body has been walked. They are then spliced in front, because an ES
    // module reads top to bottom and a reader wants the imports first.
    var declarations: std.ArrayList(Node.Index) = .empty;
    try l.declarations(&declarations);
    try l.exports(&declarations);
    const import_statements = try l.importStatements();

    var body: std.ArrayList(Node.Index) = .empty;
    try body.appendSlice(scratch, import_statements);
    try body.appendSlice(scratch, declarations.items);

    const range = try b.addRange(body.items);
    const ir = try b.toOwned(range);
    const diagnostics = try l.diagnostics.toOwnedSlice(gpa);
    return .{ .ir = ir, .diagnostics = diagnostics };
}

/// The compiler's own identifiers, interned once per module. They all start
/// with `$`, which beni's identifier syntax cannot produce, so no source
/// name can collide with one.
const WellKnown = struct {
    temp: Symbol,
    ctor_arg: Symbol,
    param: Symbol,
    tag: Symbol,
};

/// How a constructor of one type is represented in JavaScript.
///
/// Three decisions live here and two of them depart from backend.md §4:
///
///  1. **`Basics.Bool` is JavaScript's `true`/`false`.** §4 has no entry for
///     it and its general rule (a nullary constructor is the bare tag) would
///     make `True` the string `"True"`, so `if` would compare strings and
///     `&&` could not be `&&`. Every compiler in the survey special-cases
///     its boolean type for exactly this reason, and the type is core's, so
///     the special case is keyed on core's `Basics.Bool` and not on a name.
///  2. **A type whose constructors are ALL nullary is a bare string tag**
///     (`Order` is `"LT"`, `"EQ"`, `"GT"`); a type with any argument-taking
///     constructor pads EVERY constructor to `{$: tag, a, b, …}` with
///     `null` in the unused slots. §4's table says "nullary constructor →
///     the bare tag" flatly, and §9.4 says "shape consistency is mandatory"
///     and measures 11% on Firefox for padding; the two cannot both hold for
///     `Maybe`. Splitting on whether the type has any payload at all
///     satisfies §9.4 where it matters (a type that is actually tested by
///     shape) and §4 where it costs nothing (an enumeration).
///  3. **`List` is cons cells**, `{$: 1, a: head, b: tail}` and a padded
///     empty cell, as §4 requires. `List` is a `foreign type`, so it has no
///     beni constructors and the representation is the emitter's, shared
///     with `core/List.js` by contract.
const CtorRep = union(enum) {
    /// `Basics.Bool`.
    boolean: bool,
    /// Every constructor of the type is nullary: the bare tag string.
    bare_tag,
    /// `{$: "Tag", a, b, …}`, padded to `fields` slots.
    tagged: struct { fields: u32 },
};

const StmtList = std.ArrayList(Node.Index);

const Lowerer = struct {
    gpa: Allocator,
    scratch: Allocator,
    b: *JsIr.Builder,
    interner: *InternPool.Global,
    in: Input,
    bir: *const Bir,
    module_name: Symbol,
    well: WellKnown,
    diagnostics: std.ArrayList(Item) = .empty,
    /// Names the module has to import from another module, in first-use
    /// order so the import list is a function of the source.
    needed: std.ArrayList(Needed) = .empty,
    /// The declaration being lowered: its locals and its parameter count.
    locals: []const Bir.Local = &.{},
    /// The JavaScript name of each local, parallel to `locals`, filled the
    /// first time one is asked for. It has to be REMEMBERED and not derived:
    /// a local made by desugaring (`>>`, `<<`, `.field`) has no source name
    /// at all, so its name is invented — and inventing it twice would bind
    /// one name in the parameter list and read another in the body.
    local_names: []JsIr.NameIndex = &.{},
    /// Counter behind every compiler-made name in this module.
    next_tag: u32 = 1,

    const Needed = struct { module: Graph.Index, value: u32 };

    // ---- Small helpers ----------------------------------------------------

    fn pos(l: *Lowerer, inst: Inst.Index) u32 {
        if (inst.int() >= l.bir.insts.len) return Node.no_pos;
        const token = l.bir.insts.items(.main_token)[inst.int()];
        if (token >= l.in.token_starts.len) return Node.no_pos;
        return l.in.token_starts[token];
    }

    fn text(l: *Lowerer, symbol: Symbol) []const u8 {
        return l.interner.slice(symbol);
    }

    fn add(l: *Lowerer, tag: Node.Tag, p: u32, lhs: u32, rhs: u32) !Node.Index {
        return l.b.addNode(.{ .tag = tag, .pos = p, .data = .{ .lhs = lhs, .rhs = rhs } });
    }

    fn name(l: *Lowerer, n: JsIr.Name) !JsIr.NameIndex {
        return l.b.intern(n);
    }

    /// A fresh compiler-made name from `base`, unique in this module.
    fn fresh(l: *Lowerer, base: Symbol) !JsIr.NameIndex {
        const tag = l.next_tag;
        l.next_tag += 1;
        return l.name(.{ .module = .none, .base = base, .tag = tag });
    }

    fn ident(l: *Lowerer, n: JsIr.NameIndex, p: u32) !Node.Index {
        return l.add(.ident, p, @intFromEnum(n), Node.Data.unused);
    }

    fn stringNode(l: *Lowerer, bytes: []const u8, p: u32) !Node.Index {
        const offset, const len = try l.b.addString(bytes);
        return l.add(.string, p, offset, len);
    }

    fn numberNode(l: *Lowerer, bytes: []const u8, p: u32) !Node.Index {
        const offset, const len = try l.b.addString(bytes);
        return l.add(.number, p, offset, len);
    }

    fn nullNode(l: *Lowerer, p: u32) !Node.Index {
        return l.add(.null_lit, p, Node.Data.unused, Node.Data.unused);
    }

    fn call(l: *Lowerer, callee: Node.Index, args: []const Node.Index, p: u32) !Node.Index {
        const range = try l.b.addRange(args);
        const record = try l.b.addRecord(range);
        return l.add(.call, p, callee.int(), @intFromEnum(record));
    }

    fn member(l: *Lowerer, target: Node.Index, field: Symbol, p: u32) !Node.Index {
        const n = try l.name(.{ .module = .none, .base = field, .tag = JsIr.Name.no_tag });
        return l.add(.member, p, target.int(), @intFromEnum(n));
    }

    fn binary(l: *Lowerer, op: JsIr.BinaryOp, left: Node.Index, right: Node.Index, p: u32) !Node.Index {
        const record = try l.b.addRecord(JsIr.Binary{ .left = left, .right = right });
        return l.add(.binary, p, @intFromEnum(record), @intFromEnum(op));
    }

    fn unary(l: *Lowerer, op: JsIr.UnaryOp, operand: Node.Index, p: u32) !Node.Index {
        return l.add(.unary, p, operand.int(), @intFromEnum(op));
    }

    fn object(l: *Lowerer, properties: []const Node.Index, p: u32) !Node.Index {
        const range = try l.b.addRange(properties);
        return l.add(.object, p, @intFromEnum(range.start), @intFromEnum(range.end));
    }

    fn property(l: *Lowerer, key: Symbol, value: Node.Index, p: u32) !Node.Index {
        const n = try l.name(.{ .module = .none, .base = key, .tag = JsIr.Name.no_tag });
        return l.add(.property, p, @intFromEnum(n), value.int());
    }

    fn constDecl(l: *Lowerer, out: *StmtList, n: JsIr.NameIndex, value: Node.Index, p: u32) !void {
        try out.append(l.scratch, try l.add(.const_decl, p, @intFromEnum(n), value.int()));
    }

    fn returnStmt(l: *Lowerer, value: Node.Index, p: u32) !Node.Index {
        return l.add(.return_stmt, p, @intFromEnum(value.toOptional()), Node.Data.unused);
    }

    /// The `a`, `b`, `c`… slot names constructors, tuples and cons cells
    /// use. Positional and not the field's own name, because a constructor
    /// argument has no name and a tuple element has no name either.
    fn slotName(l: *Lowerer, index: u32) !Symbol {
        var buf: [8]u8 = undefined;
        const spelled = if (index < 26)
            std.fmt.bufPrint(&buf, "{c}", .{@as(u8, 'a') + @as(u8, @intCast(index))}) catch unreachable
        else
            std.fmt.bufPrint(&buf, "a{d}", .{index}) catch unreachable;
        return l.interner.getOrPut(l.gpa, spelled);
    }

    fn report(l: *Lowerer, code: diagnostic.Code, region: Inst.Index, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(l.gpa, fmt, args);
        errdefer l.gpa.free(message);
        try l.diagnostics.append(l.gpa, .{
            .code = code,
            .module = l.in.module,
            .region = region,
            .message = message,
        });
    }

    // ---- Module structure -------------------------------------------------

    fn declarations(l: *Lowerer, out: *StmtList) !void {
        const order = try l.emissionOrder();
        for (order) |index| try l.declaration(out, index);
    }

    /// Declarations in dependency order: a declaration is emitted after
    /// every declaration of this module it references.
    ///
    /// Function bodies do not need it — they run after every `const` is
    /// initialised — but a CONSTANT does: `const M$a = M$b + 1` above
    /// `const M$b = 1` is a temporal-dead-zone throw, which is a well-typed
    /// program crashing at runtime. A depth-first post-order over the
    /// `refs` table (already the §9.1 dependency graph) puts each
    /// dependency first, and a cycle — which the checker allows only
    /// through functions — falls back to source order for its members.
    fn emissionOrder(l: *Lowerer) ![]const u32 {
        const count: u32 = @intCast(l.bir.decls.len);
        const state = try l.scratch.alloc(u8, count);
        @memset(state, 0); // 0 = unvisited, 1 = on stack, 2 = done
        var order: std.ArrayList(u32) = .empty;
        try order.ensureTotalCapacity(l.scratch, count);
        // An explicit stack: a module may have tens of thousands of
        // declarations and recursion here would be bounded by the C stack
        // rather than by the input (`bench --wide` builds exactly that).
        var stack: std.ArrayList(Frame) = .empty;
        for (0..count) |root| {
            if (state[root] != 0) continue;
            try stack.append(l.scratch, .{ .decl = @intCast(root), .next = 0 });
            state[root] = 1;
            while (stack.items.len != 0) {
                const frame = &stack.items[stack.items.len - 1];
                const d = l.bir.decls[frame.decl];
                const refs = l.bir.refs[d.refs_start..d.refs_end];
                if (frame.next < refs.len) {
                    const ref = refs[frame.next];
                    frame.next += 1;
                    if (ref.kind != .top_value) continue;
                    if (ref.a >= count or state[ref.a] != 0) continue;
                    state[ref.a] = 1;
                    try stack.append(l.scratch, .{ .decl = ref.a, .next = 0 });
                    continue;
                }
                state[frame.decl] = 2;
                order.appendAssumeCapacity(frame.decl);
                _ = stack.pop();
            }
        }
        return order.items;
    }

    const Frame = struct { decl: u32, next: usize };

    fn declaration(l: *Lowerer, out: *StmtList, index: u32) !void {
        const d = l.bir.decls[index];
        switch (d.kind) {
            .value => {},
            // A type, an alias and a foreign type emit nothing: a
            // constructor is an object literal at its use site and a type
            // has no runtime existence at all.
            .type, .type_alias, .foreign_type => return,
            // Bound by the sibling import, not by a declaration here.
            .foreign_value => return,
            // The parser already reported it and there is no body.
            .annotation_only => return,
        }
        const body = d.body.unwrap() orelse return;
        l.locals = l.bir.declLocals(d);
        l.local_names = try l.scratch.alloc(JsIr.NameIndex, l.locals.len);
        @memset(l.local_names, .none);

        const n = try l.name(.{
            .module = l.module_name.toOptional(),
            .base = l.bir.symbol(d.name),
            .tag = JsIr.Name.no_tag,
        });
        const p = l.pos(body);
        if (d.params == 0) {
            var stmts: StmtList = .empty;
            const value = try l.expr(&stmts, body);
            // A constant whose lowering needed statements cannot be a bare
            // `const`: wrap it in a called arrow, which is the one place
            // M3a emits an IIFE and the one place §9.2's peephole exists to
            // remove later.
            if (stmts.items.len == 0) {
                try l.constDecl(out, n, value, p);
                return;
            }
            try stmts.append(l.scratch, try l.returnStmt(value, p));
            const arrow = try l.arrowOf(&[_]JsIr.NameIndex{}, stmts.items, p);
            try l.constDecl(out, n, try l.call(arrow, &.{}, p), p);
            return;
        }
        const params = l.bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Inst.Index);
        const record = try l.functionOf(params, body, p);
        const arrow = try l.add(.arrow, p, @intFromEnum(record), Node.Data.unused);
        try l.constDecl(out, n, arrow, p);
    }

    fn exports(l: *Lowerer, out: *StmtList) !void {
        var names: std.ArrayList(JsIr.NameIndex) = .empty;
        if (l.in.entry_decl) |index| {
            if (index < l.bir.decls.len and !l.bir.decls[index].is_pub) {
                try names.append(l.scratch, try l.topName(index));
            }
        }
        for (l.bir.interface) |decl_index| {
            const d = l.bir.decl(decl_index);
            if (!d.kind.isValue()) continue;
            if (d.kind == .annotation_only) continue;
            if (d.kind == .value and d.body == .none) continue;
            try names.append(l.scratch, try l.name(.{
                .module = l.module_name.toOptional(),
                .base = l.bir.symbol(d.name),
                .tag = JsIr.Name.no_tag,
            }));
        }
        if (names.items.len == 0) return;
        const range = try l.b.addNames(names.items);
        try out.append(l.scratch, try l.add(.export_stmt, Node.no_pos, @intFromEnum(range.start), @intFromEnum(range.end)));
    }

    /// The `import` statements, built once the reference list is complete
    /// and spliced in front of the declarations by `lower`.
    fn importStatements(l: *Lowerer) ![]const Node.Index {
        var out: std.ArrayList(Node.Index) = .empty;
        // Foreign values first: `import { add as Basics$add } from "./Basics.js"`.
        var siblings: std.ArrayList(JsIr.Specifier) = .empty;
        for (l.bir.decls) |d| {
            if (d.kind != .foreign_value) continue;
            const base = l.bir.symbol(d.name);
            try siblings.append(l.scratch, .{
                .imported = try l.name(.{ .module = .none, .base = base, .tag = JsIr.Name.no_tag }),
                .local = try l.name(.{ .module = l.module_name.toOptional(), .base = base, .tag = JsIr.Name.no_tag }),
            });
        }
        if (siblings.items.len != 0 and l.in.sibling.len != 0) {
            try out.append(l.scratch, try l.importStatement(l.in.sibling, siblings.items));
        }
        // Then one statement per other module, in first-reference order.
        // References to one module are not contiguous in `needed` — a
        // declaration mentions whatever it mentions — so the modules are
        // walked once and each one collects every entry that names it. A
        // second statement for a module already emitted would be a
        // duplicate binding, which is a syntax error and not a warning.
        var emitted: std.ArrayList(Graph.Index) = .empty;
        for (l.needed.items) |first| {
            var already = false;
            for (emitted.items) |module| already = already or module == first.module;
            if (already) continue;
            try emitted.append(l.scratch, first.module);

            var specs: std.ArrayList(JsIr.Specifier) = .empty;
            for (l.needed.items) |entry| {
                if (entry.module != first.module) continue;
                const n = try l.externalName(first.module, entry.value);
                try specs.append(l.scratch, .{ .imported = n, .local = n });
            }
            const specifier = if (first.module.int() < l.in.specifiers.len) l.in.specifiers[first.module.int()] else "";
            if (specifier.len == 0) continue;
            try out.append(l.scratch, try l.importStatement(specifier, specs.items));
        }
        return out.items;
    }

    fn importStatement(l: *Lowerer, specifier: []const u8, specs: []const JsIr.Specifier) !Node.Index {
        const source_start, const source_len = try l.b.addString(specifier);
        const range = try l.b.addExtra(@ptrCast(specs));
        const record = try l.b.addRecord(JsIr.Import{
            .source_start = source_start,
            .source_len = source_len,
            .specs_start = range.start,
            .specs_end = range.end,
        });
        return l.add(.import_stmt, Node.no_pos, @intFromEnum(record), Node.Data.unused);
    }

    fn externalName(l: *Lowerer, module: Graph.Index, value: u32) !JsIr.NameIndex {
        const iface = &l.in.interfaces[module.int()];
        const base = iface.symbols[@intFromEnum(iface.values[value].name)];
        return l.name(.{ .module = l.in.graph.moduleName(module).toOptional(), .base = base, .tag = JsIr.Name.no_tag });
    }

    fn need(l: *Lowerer, module: Graph.Index, value: u32) !void {
        for (l.needed.items) |existing| {
            if (existing.module == module and existing.value == value) return;
        }
        try l.needed.append(l.scratch, .{ .module = module, .value = value });
    }

    // ---- Functions --------------------------------------------------------

    /// The `Func` record for `params` and `body`: what both an `arrow` and
    /// a `func_decl` carry, built once so a `let` binding can choose which
    /// of the two it becomes without lowering the body twice.
    fn functionOf(l: *Lowerer, params: []const Inst.Index, body: Inst.Index, p: u32) !JsIr.ExtraIndex {
        var names: std.ArrayList(JsIr.NameIndex) = .empty;
        var stmts: StmtList = .empty;
        for (params) |param| {
            // A bare variable pattern IS the JavaScript parameter; anything
            // else (a tuple, a record, a constructor) needs a name of its
            // own and a destructuring statement at the top of the body.
            if (l.bir.instTag(param) == .pat_var) {
                const local = l.bir.instData(param).lhs;
                try names.append(l.scratch, try l.localName(local));
                continue;
            }
            if (l.bir.instTag(param) == .pat_wild) {
                try names.append(l.scratch, try l.fresh(l.well.param));
                continue;
            }
            const fresh_name = try l.fresh(l.well.param);
            try names.append(l.scratch, fresh_name);
            const subject = try l.ident(fresh_name, l.pos(param));
            try l.bindings(&stmts, param, subject);
        }
        const value = try l.expr(&stmts, body);
        try stmts.append(l.scratch, try l.returnStmt(value, p));
        return l.funcRecord(names.items, stmts.items);
    }

    fn funcRecord(l: *Lowerer, params: []const JsIr.NameIndex, body: []const Node.Index) !JsIr.ExtraIndex {
        const param_range = try l.b.addNames(params);
        const body_range = try l.b.addRange(body);
        return l.b.addRecord(JsIr.Func{
            .params_start = param_range.start,
            .params_end = param_range.end,
            .body_start = body_range.start,
            .body_end = body_range.end,
        });
    }

    fn arrowOf(l: *Lowerer, params: []const JsIr.NameIndex, body: []const Node.Index, p: u32) !Node.Index {
        const record = try l.funcRecord(params, body);
        return l.add(.arrow, p, @intFromEnum(record), Node.Data.unused);
    }

    /// `((x1, x2) => Ctor(x1, x2))` — an n-ary constructor used as a VALUE
    /// rather than called. The only wrapper this file emits, and only
    /// because a constructor has no JavaScript binding of its own: it is an
    /// object literal at each use site (§4), so there is nothing to name.
    fn ctorLambda(l: *Lowerer, rep: CtorRep, tag: Symbol, arity: u32, p: u32) !Node.Index {
        var params: std.ArrayList(JsIr.NameIndex) = .empty;
        var args: std.ArrayList(Node.Index) = .empty;
        for (0..arity) |_| {
            const n = try l.fresh(l.well.ctor_arg);
            try params.append(l.scratch, n);
            try args.append(l.scratch, try l.ident(n, p));
        }
        const value = try l.ctorValue(rep, tag, args.items, p);
        const stmts = [_]Node.Index{try l.returnStmt(value, p)};
        return l.arrowOf(params.items, &stmts, p);
    }

    // ---- Names and references ---------------------------------------------

    fn localName(l: *Lowerer, index: u32) !JsIr.NameIndex {
        if (index >= l.locals.len) return l.fresh(l.well.param);
        if (l.local_names[index] != .none) return l.local_names[index];
        const local = l.locals[index];
        // The local INDEX is the disambiguator: two sibling branches may
        // each bind `x`, and JavaScript's block scoping would hide one
        // behind the other in the shapes M3b's decision trees produce.
        // Distinct indices therefore get distinct names, and the source
        // name is still the prefix so a stack trace reads.
        const n = if (local.name.unwrap()) |symbol| try l.name(.{
            .module = .none,
            .base = l.bir.symbols[symbol],
            .tag = index + 1,
        }) else try l.fresh(l.well.param);
        l.local_names[index] = n;
        return n;
    }

    fn topName(l: *Lowerer, decl: u32) !JsIr.NameIndex {
        return l.name(.{
            .module = l.module_name.toOptional(),
            .base = l.bir.symbol(l.bir.decls[decl].name),
            .tag = JsIr.Name.no_tag,
        });
    }

    /// How many fields a CONSTRUCTOR reference takes. The one arity this
    /// file still has to know, because a constructor is an object literal
    /// and not a function: used as a value it needs a wrapper of the right
    /// width. Every other callee is called with the arguments written at
    /// the call site and nothing else.
    fn ctorArity(l: *Lowerer, inst: Inst.Index) u32 {
        const d = l.bir.instData(inst);
        switch (l.bir.instTag(inst)) {
            .ctor => {
                if (d.lhs >= l.bir.ctors.len) return 0;
                const c = l.bir.ctors[d.lhs];
                return Bir.SubRange.len(.{ .start = c.args_start, .end = c.args_end });
            },
            .ext_ctor => {
                const module: Graph.Index = @enumFromInt(d.lhs);
                if (module.int() >= l.in.interfaces.len) return 0;
                const iface = &l.in.interfaces[module.int()];
                if (d.rhs >= iface.ctors.len) return 0;
                return iface.ctors[d.rhs].arity;
            },
            else => return 0,
        }
    }

    // ---- Constructors -----------------------------------------------------

    fn ctorRepLocal(l: *Lowerer, ctor_index: u32) CtorRep {
        const c = l.bir.ctors[ctor_index];
        const owner = l.bir.decls[c.decl.int()];
        var max: u32 = 0;
        for (l.bir.ctors[owner.ctors_start..owner.ctors_end]) |sibling| {
            max = @max(max, Bir.SubRange.len(.{ .start = sibling.args_start, .end = sibling.args_end }));
        }
        if (l.in.graph.module(l.in.module).package == .core and
            l.module_name == InternPool.WellKnown.Basics.symbol() and
            l.bir.symbol(owner.name) == InternPool.WellKnown.Bool.symbol())
        {
            return .{ .boolean = l.bir.symbol(c.name) == InternPool.WellKnown.True.symbol() };
        }
        if (max == 0) return .bare_tag;
        return .{ .tagged = .{ .fields = max } };
    }

    fn ctorRepExternal(l: *Lowerer, module: Graph.Index, ctor_index: u32) CtorRep {
        const iface = &l.in.interfaces[module.int()];
        const c = iface.ctors[ctor_index];
        const owner = iface.types[@intFromEnum(c.type)];
        var max: u32 = 0;
        for (iface.ctors[owner.ctors_start..owner.ctors_end]) |sibling| max = @max(max, sibling.arity);
        if (l.in.graph.module(module).package == .core and
            l.in.graph.moduleName(module) == InternPool.WellKnown.Basics.symbol() and
            iface.symbols[@intFromEnum(owner.name)] == InternPool.WellKnown.Bool.symbol())
        {
            return .{ .boolean = iface.symbols[@intFromEnum(c.name)] == InternPool.WellKnown.True.symbol() };
        }
        if (max == 0) return .bare_tag;
        return .{ .tagged = .{ .fields = max } };
    }

    fn ctorRepOf(l: *Lowerer, inst: Inst.Index) ?struct { CtorRep, Symbol } {
        const d = l.bir.instData(inst);
        switch (l.bir.instTag(inst)) {
            .ctor => {
                if (d.lhs >= l.bir.ctors.len) return null;
                return .{ l.ctorRepLocal(d.lhs), l.bir.symbol(l.bir.ctors[d.lhs].name) };
            },
            .ext_ctor => {
                const module: Graph.Index = @enumFromInt(d.lhs);
                if (module.int() >= l.in.interfaces.len) return null;
                const iface = &l.in.interfaces[module.int()];
                if (d.rhs >= iface.ctors.len) return null;
                return .{ l.ctorRepExternal(module, d.rhs), iface.symbols[@intFromEnum(iface.ctors[d.rhs].name)] };
            },
            else => return null,
        }
    }

    /// The value of a constructor applied to `args` (which must be exactly
    /// its arity).
    fn ctorValue(l: *Lowerer, rep: CtorRep, tag: Symbol, args: []const Node.Index, p: u32) !Node.Index {
        switch (rep) {
            .boolean => |value| return l.add(if (value) .true_lit else .false_lit, p, Node.Data.unused, Node.Data.unused),
            .bare_tag => return l.stringNode(l.text(tag), p),
            .tagged => |t| {
                var properties: std.ArrayList(Node.Index) = .empty;
                try properties.append(l.scratch, try l.property(l.well.tag, try l.stringNode(l.text(tag), p), p));
                for (0..t.fields) |i| {
                    const slot = try l.slotName(@intCast(i));
                    const value = if (i < args.len) args[i] else try l.nullNode(p);
                    try properties.append(l.scratch, try l.property(slot, value, p));
                }
                return l.object(properties.items, p);
            },
        }
    }

    // ---- Lists ------------------------------------------------------------
    //
    // `List` is a `foreign type`, so it has no beni constructors and the
    // representation is the emitter's: `{$: 1, a: head, b: tail}` for a
    // cell and `{$: 0, a: null, b: null}` for the empty list, padded to one
    // shape as §9.4 requires. `core/List.js` and `core/String.js` build and
    // walk the same shape by contract; that contract is what `backend.md`
    // §4's "the empty singleton" names without saying where it comes from.

    fn nilNode(l: *Lowerer, p: u32) !Node.Index {
        const zero = try l.numberNode("0", p);
        const a = try l.slotName(0);
        const bslot = try l.slotName(1);
        return l.object(&.{
            try l.property(l.well.tag, zero, p),
            try l.property(a, try l.nullNode(p), p),
            try l.property(bslot, try l.nullNode(p), p),
        }, p);
    }

    fn consNode(l: *Lowerer, head: Node.Index, tail: Node.Index, p: u32) !Node.Index {
        const one = try l.numberNode("1", p);
        const a = try l.slotName(0);
        const bslot = try l.slotName(1);
        return l.object(&.{
            try l.property(l.well.tag, one, p),
            try l.property(a, head, p),
            try l.property(bslot, tail, p),
        }, p);
    }

    // ---- Expressions ------------------------------------------------------

    fn exprList(l: *Lowerer, out: *StmtList, range: Bir.SubRange) ![]Node.Index {
        const items = l.bir.extraSlice(range, Inst.Index);
        const result = try l.scratch.alloc(Node.Index, items.len);
        for (items, result) |inst, *slot| slot.* = try l.expr(out, inst);
        return result;
    }

    fn expr(l: *Lowerer, out: *StmtList, inst: Inst.Index) Allocator.Error!Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        switch (l.bir.instTag(inst)) {
            .int, .float => return l.numberNode(l.bir.bytes(inst), p),
            .char => {
                // A `Char` is a JavaScript string holding the one scalar:
                // §4 says strings are native and core's API exposes
                // codepoints, and a one-character string is what
                // `String.fromChar` and `Char.toCode` are written against.
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(std.math.cast(u21, d.lhs) orelse 0xFFFD, &buf) catch
                    std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
                return l.stringNode(buf[0..len], p);
            },
            .string, .chunk => return l.stringNode(l.bir.bytes(inst), p),
            .interp => {
                const parts = l.bir.extraSlice(Bir.inlineRange(d), Inst.Index);
                var nodes: std.ArrayList(Node.Index) = .empty;
                for (parts) |part| {
                    if (l.bir.instTag(part) == .chunk) {
                        const offset, const len = try l.b.addString(l.bir.bytes(part));
                        try nodes.append(l.scratch, try l.add(.template_chunk, l.pos(part), offset, len));
                        continue;
                    }
                    try nodes.append(l.scratch, try l.expr(out, part));
                }
                const range = try l.b.addRange(nodes.items);
                return l.add(.template, p, @intFromEnum(range.start), @intFromEnum(range.end));
            },
            .unit => return l.nullNode(p),
            .tuple => {
                const elements = try l.exprList(out, Bir.inlineRange(d));
                var properties: std.ArrayList(Node.Index) = .empty;
                for (elements, 0..) |element, i| {
                    try properties.append(l.scratch, try l.property(try l.slotName(@intCast(i)), element, p));
                }
                return l.object(properties.items, p);
            },
            .list => {
                const elements = try l.exprList(out, Bir.inlineRange(d));
                var node = try l.nilNode(p);
                var i: usize = elements.len;
                while (i > 0) {
                    i -= 1;
                    node = try l.consNode(elements[i], node, p);
                }
                return node;
            },
            .record => return l.recordNode(out, Bir.inlineRange(d), p),
            .record_update => {
                const base = try l.expr(out, @enumFromInt(d.lhs));
                const fields = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Bir.Field);
                var properties: std.ArrayList(Node.Index) = .empty;
                try properties.append(l.scratch, try l.add(.spread_property, p, base.int(), Node.Data.unused));
                for (fields) |f| {
                    const value = try l.expr(out, f.value);
                    try properties.append(l.scratch, try l.property(l.bir.symbol(f.name), value, p));
                }
                return l.object(properties.items, p);
            },
            .field_access => {
                const target = try l.expr(out, @enumFromInt(d.lhs));
                return l.member(target, l.bir.symbols[d.rhs], p);
            },
            .tuple_index => {
                const target = try l.expr(out, @enumFromInt(d.lhs));
                return l.member(target, try l.slotName(d.rhs), p);
            },
            .call => return l.callExpr(out, inst),
            .method_call => return l.methodCallExpr(out, inst),
            .lambda => {
                const params = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.lhs)), Inst.Index);
                const record = try l.functionOf(params, @enumFromInt(d.rhs), p);
                return l.add(.arrow, p, @intFromEnum(record), Node.Data.unused);
            },
            .let => {
                try l.letBindings(out, l.bir.subRange(@enumFromInt(d.lhs)));
                return l.expr(out, @enumFromInt(d.rhs));
            },
            .case => return l.caseExpr(out, inst),
            .local, .top, .ctor, .ext_value, .ext_ctor => return l.reference(inst),
            .@"try" => {
                try l.report(
                    .not_implemented,
                    inst,
                    \\I cannot compile `?` to JavaScript yet.
                    \\
                    \\The question mark desugars to a `case` with an early return, and the code
                    \\generator grows that in M3b (`docs/design/backend.md` §1). Write the `case`
                    \\out by hand for now — it is the same program.
                ,
                    .{},
                );
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
            // S4: dispatch on a type variable (static-dispatch-spike.md §4,
            // §8.4) needs the dispatch table, which S3 fills in. It is
            // reported rather than swallowed, because an `else` arm here is
            // how `const M$decode = (s) => undefined;` shipped with exit
            // code 0 (the checker refuses it first, and this is the second
            // wall).
            .type_dispatch => {
                try l.report(
                    .not_implemented,
                    inst,
                    \\I cannot compile a dispatch on a type yet.
                    \\
                    \\`a.decode s` calls a method of whatever type `a` stands for at the call
                    \\(`docs/design/static-dispatch-spike.md` §4), and the table that says which
                    \\function that is arrives with the checker's dispatch pass. Pass the
                    \\function as an argument for now.
                ,
                    .{},
                );
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
            // A poisoned instruction: the name did not resolve or the
            // parser could not build a node. `beni build` refuses to emit a
            // project with any error diagnostic, so this is unreachable
            // from a successful build; emitting `undefined` rather than
            // asserting keeps a bug in that gate from becoming a crash.
            .@"error" => return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
            // Every remaining tag is a TYPE or a PATTERN, which no
            // expression position holds: patterns are lowered by
            // `bindings`, types never reach the backend at all
            // (`backend.md` §3), and the four unresolved name forms are
            // rewritten by `Resolve` before this runs. Listed rather than
            // caught by an `else`, so a new expression tag is a compile
            // error here instead of a silent `undefined`.
            .type_var,
            .type_top,
            .type_import,
            .type_qualified,
            .ext_type,
            .type_app,
            .type_fn,
            .type_unit,
            .type_tuple,
            .type_record,
            .type_record_ext,
            .import_value,
            .import_ctor,
            .qualified,
            .qualified_ctor,
            .pat_wild,
            .pat_var,
            .pat_ctor,
            .pat_int,
            .pat_char,
            .pat_string,
            .pat_unit,
            .pat_tuple,
            .pat_list,
            .pat_cons,
            .pat_record,
            .pat_as,
            .let_def,
            .let_pattern,
            .branch,
            => return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
        }
    }

    /// A record literal, keys in a canonical order (§4: one hidden class per
    /// record type). Sorted by the NAME TEXT, not by symbol: a symbol's
    /// number depends on which worker interned which file, and two modules
    /// building the same record type have to agree on the key order or V8
    /// sees two shapes.
    fn recordNode(l: *Lowerer, out: *StmtList, range: Bir.SubRange, p: u32) !Node.Index {
        const fields = l.bir.extraSlice(range, Bir.Field);
        const sorted = try l.scratch.alloc(Bir.Field, fields.len);
        @memcpy(sorted, fields);
        const Sorter = struct {
            lower: *Lowerer,
            fn lessThan(s: @This(), a: Bir.Field, b: Bir.Field) bool {
                return std.mem.lessThan(u8, s.lower.text(s.lower.bir.symbol(a.name)), s.lower.text(s.lower.bir.symbol(b.name)));
            }
        };
        std.mem.sort(Bir.Field, sorted, Sorter{ .lower = l }, Sorter.lessThan);
        var properties: std.ArrayList(Node.Index) = .empty;
        for (sorted) |f| {
            const value = try l.expr(out, f.value);
            try properties.append(l.scratch, try l.property(l.bir.symbol(f.name), value, p));
        }
        return l.object(properties.items, p);
    }

    /// A reference in VALUE position: the JavaScript binding itself. Only a
    /// constructor needs anything built, because it has no binding.
    fn reference(l: *Lowerer, inst: Inst.Index) !Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        if (l.ctorRepOf(inst)) |rep_and_tag| {
            const rep, const tag = rep_and_tag;
            const arity = l.ctorArity(inst);
            if (arity == 0) return l.ctorValue(rep, tag, &.{}, p);
            return l.ctorLambda(rep, tag, arity, p);
        }
        return switch (l.bir.instTag(inst)) {
            .local => try l.ident(try l.localName(d.lhs), p),
            .top => try l.ident(try l.topName(d.lhs), p),
            .ext_value => blk: {
                const module: Graph.Index = @enumFromInt(d.lhs);
                try l.need(module, d.rhs);
                break :blk try l.ident(try l.externalName(module, d.rhs), p);
            },
            else => try l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
        };
    }

    // ---- Calls ------------------------------------------------------------

    /// **S4 SHIM** (static-dispatch-spike.md §8.3 replaces it with the
    /// dispatch table the checker fills in).
    ///
    /// S2 changed what LOWERING emits, not what the backend knows, so this
    /// emits exactly what the two forms a `method_call` replaced emitted: a
    /// dot-call `x.m a` is the field call `x.m(a)` it used to be, and one
    /// of the six operators is the call of the `Basics` function it used to
    /// desugar to — `Basics$eq(a, b)`, the structural walk in
    /// `core/Basics.js`, not `===`. The reference is rebuilt here because
    /// lowering no longer emits one (§1.4): the operator has no callee
    /// instruction any more.
    fn methodCallExpr(l: *Lowerer, out: *StmtList, inst: Inst.Index) !Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        const m = l.bir.extraData(@enumFromInt(d.rhs), Bir.MethodCall);
        if (try l.refuseUnsupportedDispatch(inst, m.origin)) {
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        const args_range: Bir.SubRange = .{ .start = m.args_start, .end = m.args_end };
        if (m.origin.basicsFunction()) |function| {
            const callee = try l.basicsValue(function, inst);
            const receiver = try l.expr(out, @enumFromInt(d.lhs));
            const rest = try l.exprList(out, args_range);
            const args = try l.scratch.alloc(Node.Index, rest.len + 1);
            args[0] = receiver;
            @memcpy(args[1..], rest);
            return l.call(callee, args, p);
        }
        const target = try l.expr(out, @enumFromInt(d.lhs));
        const callee = try l.member(target, l.bir.symbol(m.name), p);
        const args = try l.exprList(out, args_range);
        return l.call(callee, args, p);
    }

    /// **S4 SHIM, the wall half.** The shim below emits `Basics$eq` for
    /// every `==` and `Basics$lt` and friends for every `<`, and passes no
    /// evidence at all. That is exactly right for what `master` accepted
    /// and exactly wrong for what this branch newly accepts: `T 1 < T 2`,
    /// `( a, b ) < ( c, d )` and `"a" < "b"` all reach `Basics$lt`, which
    /// compares JavaScript objects and strings and answers nonsense.
    ///
    /// So every site of this instruction is checked against what the shim
    /// can honour, and anything else is `not_implemented` — the same wall
    /// `?` and `type_dispatch` already stand behind (`backend.md` §1: the
    /// half of the language that is missing must SAY so). S4 lowers the
    /// evidence parameters and S5 the derived functions, and this function
    /// goes with them.
    ///
    /// What survives:
    ///
    ///   - `field` — a dot-call on a record, which is `language.md` §6.3
    ///     unchanged and what the shim already emits;
    ///   - `==` and `/=` against a STRUCTURAL answer (`primitive
    ///     strict_eq`, a derived function, or `Basics.eq` reached through
    ///     the `equatable` bridge), because `core/Basics.js`'s `eq` is that
    ///     structural walk and gives the same answer;
    ///   - `<`, `<=`, `>`, `>=` against `primitive num_compare`, which is
    ///     `Int` and `Float` and is what `Basics.lt` does.
    ///
    /// Everything else refuses, including every evidence site: a call that
    /// needs a hidden argument the shim does not pass would run with one
    /// argument too few.
    fn refuseUnsupportedDispatch(l: *Lowerer, inst: Inst.Index, origin: Bir.WellKnown) !bool {
        var refused = false;
        for (l.in.dispatch.sites) |site| {
            if (site.inst != inst) continue;
            if (site.evidence_index == 0 and l.shimCanEmit(origin, site.target)) continue;
            refused = true;
            break;
        }
        if (!refused) return false;
        try l.report(
            .not_implemented,
            inst,
            \\I cannot compile this method call to JavaScript yet.
            \\
            \\The checker resolved it (`docs/design/static-dispatch-spike.md` §6.3), but the
            \\code generator still emits every `==` as `Basics.eq` and every `<` as
            \\`Basics.lt`, and neither is the function this call needs. Hidden evidence
            \\arguments and derived `eq`/`compare` land with S4 and S5 (§8, §9).
            \\
            \\Hint: compare the parts by hand, or pass an ordering function, until then.
        ,
            .{},
        );
        return true;
    }

    fn shimCanEmit(l: *Lowerer, origin: Bir.WellKnown, target: Dispatch.Target) bool {
        return switch (target) {
            .field => origin == .none,
            .primitive => |prim| switch (prim) {
                .strict_eq => origin == .eq or origin == .neq,
                .num_compare => origin == .lt or origin == .le or origin == .gt or origin == .ge,
                .char_compare, .string_compare => false,
            },
            // A derived `eq` is a structural walk and so is `Basics.eq`.
            .derived => |dd| origin != .none and l.in.dispatch.derived[dd.index].kind == .eq,
            .ext_derived => |dd| origin != .none and dd.kind == .eq,
            // The `equatable`-marker bridge of §3.4, which core still leans
            // on until §5.5 rewrites `List.member`: the target IS
            // `Basics.eq`, so the shim's own call is the right one.
            .ext => |e| (origin == .eq or origin == .neq) and l.isBasicsEq(e),
            .top => false,
            .evidence, .err => false,
        };
    }

    fn isBasicsEq(l: *Lowerer, e: Dispatch.Target.Ext) bool {
        const basics = l.in.graph.lookup(.core, InternPool.WellKnown.Basics.symbol()) orelse return false;
        if (e.module != basics or e.module.int() >= l.in.interfaces.len) return false;
        return l.in.interfaces[e.module.int()].valueName(e.value) == InternPool.WellKnown.eq.symbol();
    }

    /// **S4 SHIM**: a reference to a `pub` value of `core/Basics.beni` by
    /// name, however this module reaches it — a plain top-level name when
    /// the module BEING lowered is `Basics` itself, an import otherwise.
    /// This is what `Resolve` does for an `import_value` instruction; the
    /// shim does it by hand because the operators no longer produce one.
    ///
    /// Each failure is REPORTED and not silently emitted as `undefined`.
    /// Before the operators stopped referencing `Basics`, a core package
    /// without `eq` failed in `Resolve` with a name error (`--core-root`
    /// makes that reachable); the reference moved here, so the failure has
    /// to be reported here too, or `a == b` compiles to `undefined(a, b)`.
    fn basicsValue(l: *Lowerer, function: InternPool.WellKnown, inst: Inst.Index) !Node.Index {
        const p = l.pos(inst);
        const spelling = l.interner.slice(function.symbol());
        const module = l.in.graph.lookup(.core, InternPool.WellKnown.Basics.symbol()) orelse
            return l.missingBasics(inst, spelling, "there is no `Basics` module in the core package");
        if (module == l.in.module) {
            for (l.bir.decls, 0..) |d, i| {
                if (l.bir.symbol(d.name) != function.symbol()) continue;
                return l.ident(try l.topName(@intCast(i)), p);
            }
            return l.missingBasics(inst, spelling, "this module IS `Basics`, and it does not declare it");
        }
        const index = l.in.interfaces[module.int()].findValue(l.interner, function.symbol()) orelse
            return l.missingBasics(inst, spelling, "`Basics` does not expose it");
        try l.need(module, @intFromEnum(index));
        return l.ident(try l.externalName(module, @intFromEnum(index)), p);
    }

    /// The one failure `basicsValue` can hit: a core package that does not
    /// hold the function an operator needs. `internal`, because a complete
    /// core package always does and the build cannot continue honestly.
    fn missingBasics(l: *Lowerer, inst: Inst.Index, spelling: []const u8, why: []const u8) !Node.Index {
        try l.report(
            .internal,
            inst,
            \\I cannot find `Basics.{s}`, which this operator needs.
            \\
            \\Every comparison operator is emitted as a call of the matching function in
            \\`core/Basics.beni` (`docs/design/static-dispatch-spike.md` §3.1), but
            \\{s}.
            \\
            \\A core package replaced with `--core-root` must declare `eq`, `neq`, `lt`,
            \\`le`, `gt` and `ge`.
        ,
            .{ spelling, why },
        );
        return l.add(.undefined_lit, l.pos(inst), Node.Data.unused, Node.Data.unused);
    }

    fn callExpr(l: *Lowerer, out: *StmtList, inst: Inst.Index) !Node.Index {
        // A call of a constrained value needs hidden arguments the shim
        // does not pass (§8.2); `refuseUnsupportedDispatch` refuses every
        // site here, because none of them is a `method_call`'s callee.
        if (try l.refuseUnsupportedDispatch(inst, .none)) {
            return l.add(.undefined_lit, l.pos(inst), Node.Data.unused, Node.Data.unused);
        }
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        const callee_inst: Inst.Index = @enumFromInt(d.lhs);
        const arg_insts = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);

        // `&&` and `||` before anything else, because they are the one place
        // where lowering an operator to a CALL would change the answer.
        // `language.md` §6.5 desugars `a && b` into `and a b`, and a call
        // evaluates both arguments — but `Basics.and` is `foreign` precisely
        // so that it does not (Basics.beni's header says so). §9.4 puts this
        // peephole at print time as an optimisation; it is brought forward
        // to here because for these two operators it is not an optimisation,
        // it is the semantics.
        if (arg_insts.len == 2) {
            if (l.logicalOp(callee_inst)) |op| {
                return l.logicalExpr(out, op, arg_insts[0], arg_insts[1], p);
            }
        }

        // A constructor is an object literal and never a call (§4); the
        // checker has already refused any application of one that is not
        // saturated, so `args` is exactly its field list.
        if (l.ctorRepOf(callee_inst)) |rep_and_tag| {
            const rep, const tag = rep_and_tag;
            const args = try l.exprList(out, l.bir.subRange(@enumFromInt(d.rhs)));
            return l.ctorValue(rep, tag, args, p);
        }

        // Everything else is one direct n-ary call (`backend.md` §6). The
        // callee is lowered FIRST because JavaScript evaluates it first,
        // and either side may need statements hoisted ahead of the call.
        const callee = try l.expr(out, callee_inst);
        const args = try l.exprList(out, l.bir.subRange(@enumFromInt(d.rhs)));
        return l.call(callee, args, p);
    }

    /// `Basics.and` / `Basics.or`, however the reference reached here: an
    /// `ext_value` from another module, or a `top` when the module being
    /// lowered IS core's `Basics`. Keyed on the core package and on the
    /// well-known symbols, never on the spelling, so a user's own `and` is
    /// an ordinary function.
    fn logicalOp(l: *Lowerer, inst: Inst.Index) ?JsIr.BinaryOp {
        const d = l.bir.instData(inst);
        const base: Symbol = switch (l.bir.instTag(inst)) {
            .top => blk: {
                if (l.in.graph.module(l.in.module).package != .core) return null;
                if (l.module_name != InternPool.WellKnown.Basics.symbol()) return null;
                if (d.lhs >= l.bir.decls.len) return null;
                break :blk l.bir.symbol(l.bir.decls[d.lhs].name);
            },
            .ext_value => blk: {
                const module: Graph.Index = @enumFromInt(d.lhs);
                if (module.int() >= l.in.interfaces.len) return null;
                if (l.in.graph.module(module).package != .core) return null;
                if (l.in.graph.moduleName(module) != InternPool.WellKnown.Basics.symbol()) return null;
                const iface = &l.in.interfaces[module.int()];
                if (d.rhs >= iface.values.len) return null;
                break :blk iface.symbols[@intFromEnum(iface.values[d.rhs].name)];
            },
            else => return null,
        };
        if (base == InternPool.WellKnown.@"and".symbol()) return .logical_and;
        if (base == InternPool.WellKnown.@"or".symbol()) return .logical_or;
        return null;
    }

    /// `a && b` / `a || b`, with the right side evaluated only when the left
    /// one decides it must be. When the right side needs statements of its
    /// own — a `case` inside a guard, say — `&&` cannot hold them, so the
    /// pair becomes the `if`/`else` a short-circuit really is.
    fn logicalExpr(l: *Lowerer, out: *StmtList, op: JsIr.BinaryOp, left_inst: Inst.Index, right_inst: Inst.Index, p: u32) !Node.Index {
        const left = try l.expr(out, left_inst);
        var right_stmts: StmtList = .empty;
        const right = try l.expr(&right_stmts, right_inst);
        if (right_stmts.items.len == 0) return l.binary(op, left, right, p);

        const n = try l.fresh(l.well.temp);
        try out.append(l.scratch, try l.add(.let_decl, p, @intFromEnum(n), @intFromEnum(Node.OptionalIndex.none)));
        const shortcut = try l.add(if (op == .logical_and) .false_lit else .true_lit, p, Node.Data.unused, Node.Data.unused);
        var evaluated: StmtList = .empty;
        try evaluated.appendSlice(l.scratch, right_stmts.items);
        try evaluated.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(n, p)).int(), right.int()));
        const skipped = [_]Node.Index{try l.add(.assign_stmt, p, (try l.ident(n, p)).int(), shortcut.int())};

        const then_items = if (op == .logical_and) evaluated.items else @as([]const Node.Index, &skipped);
        const else_items = if (op == .logical_and) @as([]const Node.Index, &skipped) else evaluated.items;
        const then_range = try l.b.addRange(then_items);
        const else_range = try l.b.addRange(else_items);
        const record = try l.b.addRecord(JsIr.If{
            .then_start = then_range.start,
            .then_end = then_range.end,
            .else_start = else_range.start,
            .else_end = else_range.end,
        });
        try out.append(l.scratch, try l.add(.if_stmt, p, left.int(), @intFromEnum(record)));
        return l.ident(n, p);
    }

    // ---- `let` ------------------------------------------------------------

    /// Every binding of one `let`, into the enclosing statement list (§4).
    /// A binding WITH parameters becomes a `function` declaration rather
    /// than a `const`: declarations are hoisted, so two bindings of one
    /// `let` may call each other, which beni allows ("all bindings are in
    /// scope in all bodies") and `const` would turn into a dead-zone throw.
    fn letBindings(l: *Lowerer, out: *StmtList, range: Bir.SubRange) !void {
        const defs = l.bir.extraSlice(range, Inst.Index);
        for (defs) |def| {
            const d = l.bir.instData(def);
            const p = l.pos(def);
            switch (l.bir.instTag(def)) {
                .let_def => {
                    const payload = l.bir.extraData(@enumFromInt(d.lhs), Bir.LetDef);
                    const params = l.bir.extraSlice(
                        .{ .start = payload.params_start, .end = payload.params_end },
                        Inst.Index,
                    );
                    const n = try l.localName(payload.local);
                    if (params.len == 0) {
                        const value = try l.expr(out, @enumFromInt(d.rhs));
                        try l.constDecl(out, n, value, p);
                        continue;
                    }
                    const record = try l.functionOf(params, @enumFromInt(d.rhs), p);
                    try out.append(l.scratch, try l.add(.func_decl, p, @intFromEnum(n), @intFromEnum(record)));
                },
                .let_pattern => {
                    const value = try l.expr(out, @enumFromInt(d.rhs));
                    const subject = try l.bindSubject(out, value, p);
                    try l.bindings(out, @enumFromInt(d.lhs), subject);
                },
                else => {},
            }
        }
    }

    // ---- `case` -----------------------------------------------------------

    const Branch = struct {
        /// The refutable half of the pattern, or `.none` when it always
        /// matches.
        test_expr: Node.OptionalIndex,
        /// Bindings, then whatever the body needed, then the result.
        stmts: []const Node.Index,
        value: Node.Index,
        pos: u32,
    };

    /// A `case`, compiled naively: one test per branch, in order. §7's
    /// decision tree is M3b's; what M3a needs is that the answer is right.
    ///
    /// The LAST branch is emitted unconditionally. That is not an
    /// optimisation and not an assumption about the patterns: the checker
    /// has already proved the match exhaustive (checker.md §6.6), so if
    /// none of the earlier branches matched, the last one does — which is
    /// exactly backend.md §7's "the tree needs no default arm for a
    /// well-typed match".
    fn caseExpr(l: *Lowerer, out: *StmtList, inst: Inst.Index) !Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        const scrutinee = try l.expr(out, @enumFromInt(d.lhs));
        const subject = try l.bindSubject(out, scrutinee, p);
        const branch_insts = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
        if (branch_insts.len == 0) return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);

        var branches: std.ArrayList(Branch) = .empty;
        var simple = true;
        for (branch_insts) |branch_inst| {
            const bd = l.bir.instData(branch_inst);
            const pattern: Inst.Index = @enumFromInt(bd.lhs);
            var stmts: StmtList = .empty;
            const test_expr = try l.patternTest(pattern, subject);
            try l.bindings(&stmts, pattern, subject);
            const value = try l.expr(&stmts, @enumFromInt(bd.rhs));
            if (stmts.items.len != 0) simple = false;
            try branches.append(l.scratch, .{
                .test_expr = test_expr,
                .stmts = stmts.items,
                .value = value,
                .pos = l.pos(branch_inst),
            });
        }

        if (simple) {
            // Nested conditionals, built from the last branch backwards —
            // `if a then b else c` is `a ? b : c` and nothing more.
            var result = branches.items[branches.items.len - 1].value;
            var i: usize = branches.items.len - 1;
            while (i > 0) {
                i -= 1;
                const branch = branches.items[i];
                const condition = branch.test_expr.unwrap() orelse {
                    // An irrefutable branch before the end: everything
                    // after it is dead, and the checker already said so
                    // (`redundant_pattern`).
                    result = branch.value;
                    continue;
                };
                const record = try l.b.addRecord(JsIr.Cond{ .consequent = branch.value, .alternate = result });
                result = try l.add(.cond, branch.pos, condition.int(), @intFromEnum(record));
            }
            return result;
        }

        const result_name = try l.fresh(l.well.temp);
        try out.append(l.scratch, try l.add(
            .let_decl,
            p,
            @intFromEnum(result_name),
            @intFromEnum(Node.OptionalIndex.none),
        ));

        // Build the `if`/`else` chain backwards; the last branch is the
        // final `else` body.
        var tail: []const Node.Index = try l.branchBody(branches.items[branches.items.len - 1], result_name);
        var i: usize = branches.items.len - 1;
        while (i > 0) {
            i -= 1;
            const branch = branches.items[i];
            const body = try l.branchBody(branch, result_name);
            const condition = branch.test_expr.unwrap() orelse {
                tail = body;
                continue;
            };
            const then_range = try l.b.addRange(body);
            const else_range = try l.b.addRange(tail);
            const record = try l.b.addRecord(JsIr.If{
                .then_start = then_range.start,
                .then_end = then_range.end,
                .else_start = else_range.start,
                .else_end = else_range.end,
            });
            const node = try l.add(.if_stmt, branch.pos, condition.int(), @intFromEnum(record));
            const one = try l.scratch.alloc(Node.Index, 1);
            one[0] = node;
            tail = one;
        }
        for (tail) |statement| try out.append(l.scratch, statement);
        return l.ident(result_name, p);
    }

    fn branchBody(l: *Lowerer, branch: Branch, result: JsIr.NameIndex) ![]const Node.Index {
        var body: StmtList = .empty;
        try body.appendSlice(l.scratch, branch.stmts);
        const target = try l.ident(result, branch.pos);
        try body.append(l.scratch, try l.add(.assign_stmt, branch.pos, target.int(), branch.value.int()));
        return body.items;
    }

    /// Bind the scrutinee to a name unless it is already something that can
    /// be re-read for free. A pattern match reads its subject once per
    /// test, so a call — or anything else with work in it — has to be
    /// evaluated exactly once.
    fn bindSubject(l: *Lowerer, out: *StmtList, value: Node.Index, p: u32) !Node.Index {
        switch (l.b.nodes.items(.tag)[value.int()]) {
            .ident, .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => return value,
            else => {},
        }
        const n = try l.fresh(l.well.temp);
        try l.constDecl(out, n, value, p);
        return l.ident(n, p);
    }

    // ---- Patterns ---------------------------------------------------------

    /// The condition under which `pattern` matches `subject`, or `.none`
    /// when it always does.
    fn patternTest(l: *Lowerer, pattern: Inst.Index, subject: Node.Index) Allocator.Error!Node.OptionalIndex {
        const d = l.bir.instData(pattern);
        const p = l.pos(pattern);
        switch (l.bir.instTag(pattern)) {
            .pat_wild, .pat_var, .pat_unit, .pat_record => return .none,
            .pat_as => return l.patternTest(@enumFromInt(d.lhs), subject),
            .pat_tuple => {
                var condition: Node.OptionalIndex = .none;
                for (l.bir.extraSlice(Bir.inlineRange(d), Inst.Index), 0..) |element, i| {
                    const slot = try l.member(subject, try l.slotName(@intCast(i)), p);
                    condition = try l.andTest(condition, try l.patternTest(element, slot), p);
                }
                return condition;
            },
            .pat_int => return (try l.binary(
                .strict_eq,
                subject,
                try l.numberNode(l.bir.bytes(pattern), p),
                p,
            )).toOptional(),
            .pat_char => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(std.math.cast(u21, d.lhs) orelse 0xFFFD, &buf) catch
                    std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
                return (try l.binary(.strict_eq, subject, try l.stringNode(buf[0..len], p), p)).toOptional();
            },
            .pat_string => return (try l.binary(
                .strict_eq,
                subject,
                try l.stringNode(l.bir.bytes(pattern), p),
                p,
            )).toOptional(),
            .pat_ctor => {
                const ctor_inst: Inst.Index = @enumFromInt(d.lhs);
                const rep_and_tag = l.ctorRepOf(ctor_inst) orelse return .none;
                const rep, const tag = rep_and_tag;
                var condition: Node.OptionalIndex = switch (rep) {
                    // `x === true` is `x`, and `x === false` is `!x`: the
                    // one place a readable `if` is worth a special case,
                    // because every `if` in the language goes through here.
                    .boolean => |value| if (value)
                        subject.toOptional()
                    else
                        (try l.unary(.not, subject, p)).toOptional(),
                    .bare_tag => (try l.binary(.strict_eq, subject, try l.stringNode(l.text(tag), p), p)).toOptional(),
                    .tagged => (try l.binary(
                        .strict_eq,
                        try l.member(subject, l.well.tag, p),
                        try l.stringNode(l.text(tag), p),
                        p,
                    )).toOptional(),
                };
                for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index), 0..) |arg, i| {
                    const slot = try l.member(subject, try l.slotName(@intCast(i)), p);
                    condition = try l.andTest(condition, try l.patternTest(arg, slot), p);
                }
                return condition;
            },
            .pat_cons => {
                var condition = (try l.binary(
                    .strict_eq,
                    try l.member(subject, l.well.tag, p),
                    try l.numberNode("1", p),
                    p,
                )).toOptional();
                const head = try l.member(subject, try l.slotName(0), p);
                const tail = try l.member(subject, try l.slotName(1), p);
                condition = try l.andTest(condition, try l.patternTest(@enumFromInt(d.lhs), head), p);
                return l.andTest(condition, try l.patternTest(@enumFromInt(d.rhs), tail), p);
            },
            .pat_list => {
                const elements = l.bir.extraSlice(Bir.inlineRange(d), Inst.Index);
                var condition: Node.OptionalIndex = .none;
                var walk = subject;
                for (elements) |element| {
                    condition = try l.andTest(condition, (try l.binary(
                        .strict_eq,
                        try l.member(walk, l.well.tag, p),
                        try l.numberNode("1", p),
                        p,
                    )).toOptional(), p);
                    const head = try l.member(walk, try l.slotName(0), p);
                    condition = try l.andTest(condition, try l.patternTest(element, head), p);
                    walk = try l.member(walk, try l.slotName(1), p);
                }
                // …and nothing after the last element.
                return l.andTest(condition, (try l.binary(
                    .strict_eq,
                    try l.member(walk, l.well.tag, p),
                    try l.numberNode("0", p),
                    p,
                )).toOptional(), p);
            },
            else => return .none,
        }
    }

    fn andTest(l: *Lowerer, left: Node.OptionalIndex, right: Node.OptionalIndex, p: u32) !Node.OptionalIndex {
        const a = left.unwrap() orelse return right;
        const b = right.unwrap() orelse return left;
        return (try l.binary(.logical_and, a, b, p)).toOptional();
    }

    /// The `const`s a pattern introduces, given the expression its subject
    /// is reachable through.
    fn bindings(l: *Lowerer, out: *StmtList, pattern: Inst.Index, subject: Node.Index) Allocator.Error!void {
        const d = l.bir.instData(pattern);
        const p = l.pos(pattern);
        switch (l.bir.instTag(pattern)) {
            .pat_wild, .pat_unit, .pat_int, .pat_char, .pat_string => {},
            .pat_var => try l.constDecl(out, try l.localName(d.lhs), subject, p),
            .pat_as => {
                try l.bindings(out, @enumFromInt(d.lhs), subject);
                try l.constDecl(out, try l.localName(d.rhs), subject, p);
            },
            .pat_tuple => {
                for (l.bir.extraSlice(Bir.inlineRange(d), Inst.Index), 0..) |element, i| {
                    try l.bindings(out, element, try l.member(subject, try l.slotName(@intCast(i)), p));
                }
            },
            .pat_ctor => {
                for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index), 0..) |arg, i| {
                    try l.bindings(out, arg, try l.member(subject, try l.slotName(@intCast(i)), p));
                }
            },
            .pat_cons => {
                try l.bindings(out, @enumFromInt(d.lhs), try l.member(subject, try l.slotName(0), p));
                try l.bindings(out, @enumFromInt(d.rhs), try l.member(subject, try l.slotName(1), p));
            },
            .pat_list => {
                var walk = subject;
                for (l.bir.extraSlice(Bir.inlineRange(d), Inst.Index)) |element| {
                    try l.bindings(out, element, try l.member(walk, try l.slotName(0), p));
                    walk = try l.member(walk, try l.slotName(1), p);
                }
            },
            .pat_record => {
                // Each element is the LOCAL INDEX bound, and the local's
                // name is the field name (`Bir.Tag.pat_record`).
                for (l.bir.extraSlice(Bir.inlineRange(d), u32)) |local| {
                    if (local >= l.locals.len) continue;
                    const field = l.locals[local].name.unwrap() orelse continue;
                    const value = try l.member(subject, l.bir.symbols[field], p);
                    try l.constDecl(out, try l.localName(local), value, p);
                }
            },
            else => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
//
// Lowering is exercised through the REAL pipeline over sources in memory and
// asserted on the emitted JavaScript, the same shape `check/Check.zig` uses
// for types and for the same reason: the bytes are the only thing a person
// can read, and asserting the `JsIr` node graph instead would test an
// implementation that M3b and M3c are going to rewrite.
//
// What is asserted here is SHAPE — that a saturated call became a direct
// call, that `if` became a conditional expression, that a constructor of a
// payload-carrying type is padded. What the program COMPUTES is asserted by
// `tests/corpus/run/`, under Node, because that is the boundary that cannot
// be fooled by a shape that happens to match.
// ---------------------------------------------------------------------------

const testing = std.testing;
const TestProject = @import("../resolve/TestProject.zig");
const Session = @import("../Session.zig");
const Print = @import("Print.zig");

/// A core package small enough to read and big enough for the scenarios.
/// The embedded core would work and costs ~2,800 lines of parsing per test.
const test_core = [_]TestProject.Module{
    .{ .path = "Basics.beni", .package = .core, .source =
    \\pub equatable foreign type Int
    \\
    \\
    \\pub equatable foreign type Float
    \\
    \\
    \\pub type Bool
    \\    = True
    \\    | False
    \\
    \\
    \\pub type Order
    \\    = LT
    \\    | EQ
    \\    | GT
    \\
    \\
    \\pub foreign add : number, number -> number
    \\
    \\
    \\pub foreign sub : number, number -> number
    \\
    \\
    \\pub foreign mul : number, number -> number
    \\
    \\
    \\pub foreign lt : number, number -> Bool
    \\
    \\
    \\pub foreign eq : equatable a, a -> Bool
    \\
    \\
    \\pub foreign and : Bool, Bool -> Bool
    \\
    \\
    \\pub foreign or : Bool, Bool -> Bool
    \\
    \\
    \\pub foreign append : appendable, appendable -> appendable
    \\
    \\
    \\pub identity : a -> a
    \\identity a =
    \\    a
    \\
    },
    .{ .path = "List.beni", .package = .core, .source =
    \\pub equatable foreign type List a
    \\
    \\
    \\pub foreign cons : a, List a -> List a
    \\
    \\
    \\pub foreign foldl : (a, b -> b), b, List a -> b
    \\
    },
    .{ .path = "Maybe.beni", .package = .core, .source =
    \\pub type Maybe a
    \\    = Just a
    \\    | Nothing
    \\
    },
    .{ .path = "Result.beni", .package = .core, .source =
    \\pub type Result x a
    \\    = Ok a
    \\    | Err x
    \\
    },
    .{ .path = "String.beni", .package = .core, .source = "pub equatable foreign type String\n\n\npub foreign fromInt : Int -> String\n" },
    .{ .path = "Char.beni", .package = .core, .source = "pub equatable foreign type Char\n\n\npub foreign isDigit : Char -> Bool\n" },
    .{ .path = "Debug.beni", .package = .core, .source = "pub foreign todo : String -> a\n" },
};

/// Lower `source` as the module `M` and return the printed JavaScript.
/// Owned by `gpa`.
fn emitModule(gpa: Allocator, project: *TestProject, name: []const u8) ![]u8 {
    const session = &project.session;
    const m = project.module(name) orelse return error.NoSuchModule;
    const count = session.graph.count();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const specifiers = try arena.alloc([]const u8, count);
    for (specifiers, 0..) |*specifier, i| {
        const index: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
        specifier.* = try std.fmt.allocPrint(arena, "./{s}.mjs", .{session.store.moduleName(session.graph.moduleFile(index))});
    }
    const file = session.graph.moduleFile(m);
    const tokens = session.artifacts.tokens(file);

    var result = try lower(gpa, arena, &session.interner, .{
        .bir = session.artifacts.bir(file),
        .token_starts = tokens.items(.start),
        .module = m,
        .graph = &session.graph,
        .interfaces = session.resolution.interfaces,
        .dispatch = if (m.int() < session.checked.dispatch.len)
            &session.checked.dispatch[m.int()]
        else
            &Dispatch.empty,
        .specifiers = specifiers,
        .sibling = "./M.foreign.mjs",
    });
    defer result.deinit(gpa);
    // The in-bounds invariants of `JsIr`, on every tree the tests build.
    try result.ir.verify();
    return Print.print(gpa, &result.ir, .fromGlobal(&session.interner));
}

fn expectJs(expected: []const u8, source: [:0]const u8) !void {
    const gpa = testing.allocator;
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    try modules.append(gpa, .{ .path = "M.beni", .source = source });

    var p = try TestProject.initWith(gpa, modules.items, .{ .phases = Session.check_phases });
    defer p.deinit();
    if (p.stderr.written().len != 0) {
        std.debug.print("the fixture did not check clean:\n{s}\n", .{p.stderr.written()});
        return error.FixtureHasDiagnostics;
    }
    const text = try emitModule(gpa, &p, "M");
    defer gpa.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "a top-level constant and a top-level function" {
    try expectJs(
        \\import { Basics$add } from "./Basics.mjs";
        \\const M$one = 1;
        \\const M$plus = (a$1, b$2) => Basics$add(a$1, b$2);
        \\export { M$one, M$plus };
        \\
    ,
        \\pub one : Int
        \\one =
        \\    1
        \\
        \\
        \\pub plus : Int, Int -> Int
        \\plus a b =
        \\    a + b
        \\
    );
}

test "every call is a direct n-ary call and a function value is the binding itself" {
    // `backend.md` §6: there is no calling convention. A 2-ary beni call
    // emits `f(a, b)`, a function used as a VALUE emits its own name, and
    // the one argument a call leaves open is written `_` — which is a
    // lambda by the time the backend sees it (`language.md` §6.7).
    try expectJs(
        \\import { Basics$add } from "./Basics.mjs";
        \\const M$plus = (a$1, b$2) => Basics$add(a$1, b$2);
        \\const M$six = M$plus(2, 4);
        \\const M$addTwo = ($p$1) => M$plus(2, $p$1);
        \\const M$asValue = M$plus;
        \\export { M$plus, M$six, M$addTwo, M$asValue };
        \\
    ,
        \\pub plus : Int, Int -> Int
        \\plus a b =
        \\    a + b
        \\
        \\
        \\pub six : Int
        \\six =
        \\    plus 2 4
        \\
        \\
        \\pub addTwo : Int -> Int
        \\addTwo =
        \\    plus 2 _
        \\
        \\
        \\pub asValue : Int, Int -> Int
        \\asValue =
        \\    plus
        \\
    );
}

test "if becomes a conditional expression and `&&` becomes `&&`" {
    // `language.md` §6.5 desugars `&&` into a CALL of `Basics.and`, and a
    // call evaluates both sides. Emitting `&&` is not an optimisation here,
    // it is the semantics.
    try expectJs(
        \\const M$pick = (a$1, b$2) => {
        \\  const $t$1 = a$1 && b$2;
        \\  return $t$1 ? 1 : 2;
        \\};
        \\export { M$pick };
        \\
    ,
        \\pub pick : Bool, Bool -> Int
        \\pick a b =
        \\    if a && b then
        \\        1
        \\    else
        \\        2
        \\
    );
}

test "a constructor of a payload-carrying type is padded to one shape" {
    // `fast-compiler.md` §9.4: Elm's own `List` violates shape consistency
    // and padding it measured ~11% on Firefox. `None` has no argument and
    // still gets the slot.
    try expectJs(
        \\const M$some = { $: "Some", a: 1 };
        \\const M$none = { $: "None", a: null };
        \\const M$unwrap = (v$1) => {
        \\  let $t$1;
        \\  if (v$1.$ === "Some") {
        \\    const n$2 = v$1.a;
        \\    $t$1 = n$2;
        \\  } else {
        \\    $t$1 = 0;
        \\  }
        \\  return $t$1;
        \\};
        \\export { M$some, M$none, M$unwrap };
        \\
    ,
        \\pub type Box
        \\    = Some Int
        \\    | None
        \\
        \\
        \\pub some : Box
        \\some =
        \\    Some 1
        \\
        \\
        \\pub none : Box
        \\none =
        \\    None
        \\
        \\
        \\pub unwrap : Box -> Int
        \\unwrap v =
        \\    case v of
        \\        Some n ->
        \\            n
        \\
        \\        None ->
        \\            0
        \\
    );
}

test "a type whose constructors are all nullary is a bare tag, and Bool is a JavaScript boolean" {
    try expectJs(
        \\const M$first = "Red";
        \\const M$isRed = (c$1) => c$1 === "Red" ? true : false;
        \\const M$yes = true;
        \\export { M$first, M$isRed, M$yes };
        \\
    ,
        \\pub type Colour
        \\    = Red
        \\    | Green
        \\
        \\
        \\pub first : Colour
        \\first =
        \\    Red
        \\
        \\
        \\pub isRed : Colour -> Bool
        \\isRed c =
        \\    case c of
        \\        Red ->
        \\            True
        \\
        \\        Green ->
        \\            False
        \\
        \\
        \\pub yes : Bool
        \\yes =
        \\    True
        \\
    );
}

test "a record's keys are sorted, and a list is cons cells" {
    try expectJs(
        \\const M$point = { x: 1, y: 2 };
        \\const M$xs = { $: 1, a: 1, b: { $: 1, a: 2, b: { $: 0, a: null, b: null } } };
        \\const M$none = { $: 0, a: null, b: null };
        \\const M$first = M$point.x;
        \\export { M$point, M$xs, M$none, M$first };
        \\
    ,
        \\pub point : { y : Int, x : Int }
        \\point =
        \\    { y = 2, x = 1 }
        \\
        \\
        \\pub xs : List Int
        \\xs =
        \\    [ 1, 2 ]
        \\
        \\
        \\pub none : List Int
        \\none =
        \\    []
        \\
        \\
        \\pub first : Int
        \\first =
        \\    point.x
        \\
    );
}

test "let bindings become const, and a let binding with parameters becomes a hoisted function" {
    try expectJs(
        \\import { Basics$mul, Basics$add } from "./Basics.mjs";
        \\const M$f = (n$1) => {
        \\  const doubled$2 = Basics$mul(n$1, 2);
        \\  function step$3(x$4) {
        \\    return Basics$add(x$4, doubled$2);
        \\  }
        \\  return step$3(1);
        \\};
        \\export { M$f };
        \\
    ,
        \\pub f : Int -> Int
        \\f n =
        \\    let
        \\        doubled =
        \\            n * 2
        \\
        \\        step x =
        \\            x + doubled
        \\    in
        \\    step 1
        \\
    );
}

test "a lambda is an n-ary function expression, of exactly its parameters" {
    try expectJs(
        \\import { Basics$add, Basics$mul } from "./Basics.mjs";
        \\const M$apply = (f$1, x$2) => f$1(x$2);
        \\const M$answer = M$apply((a$1) => Basics$add(a$1, 1), 1);
        \\const M$twice = M$apply((b$1) => Basics$mul(b$1, 2), 21);
        \\export { M$apply, M$answer, M$twice };
        \\
    ,
        \\pub apply : (Int -> Int), Int -> Int
        \\apply f x =
        \\    f x
        \\
        \\
        \\pub answer : Int
        \\answer =
        \\    apply (\a -> a + 1) 1
        \\
        \\
        \\pub twice : Int
        \\twice =
        \\    apply (\b -> b * 2) 21
        \\
    );
}

test "string interpolation becomes a template literal" {
    try expectJs(
        \\import { String$fromInt } from "./String.mjs";
        \\const M$label = (n$1) => `n is ${String$fromInt(n$1)}!`;
        \\export { M$label };
        \\
    ,
        \\import String
        \\
        \\
        \\pub label : Int -> String
        \\label n =
        \\    "n is ${String.fromInt n}!"
        \\
    );
}

test "a foreign value is imported from the sibling file under its bare name" {
    const gpa = testing.allocator;
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    try modules.append(gpa, .{
        .path = "M.beni",
        .package = .core,
        .source =
        \\pub foreign now : Float
        \\
        \\
        \\pub foreign twice : Int -> Int
        \\
        ,
    });

    var p = try TestProject.initWith(gpa, modules.items, .{ .phases = Session.check_phases });
    defer p.deinit();
    const text = try emitModule(gpa, &p, "M");
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\import { now as M$now, twice as M$twice } from "./M.foreign.mjs";
        \\export { M$now, M$twice };
        \\
    , text);
}

test "`?` is refused with a diagnostic rather than emitted wrongly" {
    // backend.md §1 puts `?` in M3b. The guard reports; it does not fall
    // through, because a construct that silently emitted nothing would be a
    // program that compiles and computes the wrong answer.
    const gpa = testing.allocator;
    var modules: std.ArrayList(TestProject.Module) = .empty;
    defer modules.deinit(gpa);
    try modules.appendSlice(gpa, &test_core);
    try modules.append(gpa, .{ .path = "M.beni", .source =
        \\pub unwrap : Maybe Int -> Maybe Int
        \\unwrap m =
        \\    Just (m? + 1)
        \\
    });

    var p = try TestProject.initWith(gpa, modules.items, .{ .phases = Session.check_phases });
    defer p.deinit();
    const session = &p.session;
    const m = p.module("M").?;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const count = session.graph.count();
    const specifiers = try arena.alloc([]const u8, count);
    for (specifiers) |*specifier| specifier.* = "./x.mjs";
    const file = session.graph.moduleFile(m);
    var result = try lower(gpa, arena, &session.interner, .{
        .bir = session.artifacts.bir(file),
        .token_starts = session.artifacts.tokens(file).items(.start),
        .module = m,
        .graph = &session.graph,
        .interfaces = session.resolution.interfaces,
        .dispatch = if (m.int() < session.checked.dispatch.len)
            &session.checked.dispatch[m.int()]
        else
            &Dispatch.empty,
        .specifiers = specifiers,
        .sibling = "",
    });
    defer result.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.not_implemented, result.diagnostics[0].code);
}

test "fuzz: arbitrary bytes reach the emitter without a panic" {
    // The whole front end plus this pass over whatever the smith produces.
    // Most inputs never type-check, which is the point: a poisoned
    // instruction, an unresolved name and a half-built tree all arrive here
    // and none of them may reach an `unreachable`.
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            const gpa = testing.allocator;
            var buf: [2048]u8 = undefined;
            const len = smith.sliceWithHash(&buf, 0x3E4117);
            const source = try gpa.dupeZ(u8, buf[0..len]);
            defer gpa.free(source);

            var modules: std.ArrayList(TestProject.Module) = .empty;
            defer modules.deinit(gpa);
            try modules.appendSlice(gpa, &test_core);
            try modules.append(gpa, .{ .path = "M.beni", .source = source });

            var p = try TestProject.initWith(gpa, modules.items, .{ .phases = Session.check_phases });
            defer p.deinit();
            const text = emitModule(gpa, &p, "M") catch |err| switch (err) {
                error.NoSuchModule => return,
                else => return err,
            };
            gpa.free(text);
        }
    }.testOne, .{});
}
