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
            .left = try interner.getOrPut(gpa, "$x"),
            .right = try interner.getOrPut(gpa, "$y"),
            .cp_left = try interner.getOrPut(gpa, "$a"),
            .cp_right = try interner.getOrPut(gpa, "$b"),
            .code_point_at = try interner.getOrPut(gpa, "codePointAt"),
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
    // §9.1's primitive comparators are DISCOVERED the same way, and go in
    // front of the declarations rather than behind them: a module-level
    // constant whose initialiser is a call runs at module evaluation time,
    // so a `const` it names must already be initialised (§8.5, and the same
    // temporal dead zone `emissionOrder` exists for).
    const primitives = try l.primitiveValues();
    const import_statements = try l.importStatements();

    var body: std.ArrayList(Node.Index) = .empty;
    try body.appendSlice(scratch, import_statements);
    try body.appendSlice(scratch, primitives);
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
    /// The two operands of a synthesised comparator (§9.1), and the two
    /// code points `compare$char` hoists out of them.
    left: Symbol,
    right: Symbol,
    cp_left: Symbol,
    cp_right: Symbol,
    /// `codePointAt` — the one JavaScript method name the emitter spells,
    /// because `Char` ordering is a code-point comparison and not `<`
    /// (§8.3, §9.1, A.26).
    code_point_at: Symbol,
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
    /// Which of §9.1's primitive comparators this module has needed as a
    /// VALUE. A `primitive` target in evidence position is a function and
    /// not an operator (§8.2), so the module emits the two-or-three-line
    /// `const` once and every use names it.
    needs: Primitives = .{},
    /// The instruction being lowered, for a diagnostic raised by something
    /// that has no instruction of its own — the synthesised references of
    /// §9.1 and A.51's bridge. It is the INNERMOST instruction reached, not
    /// a span the reader chose, which is why only `internal` uses it.
    region: Inst.Index = @enumFromInt(0),

    const Needed = struct { module: Graph.Index, value: u32 };

    const Primitives = struct {
        eq_prim: bool = false,
        compare_prim: bool = false,
        compare_char: bool = false,
    };

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

    /// `$m$<k>`: the k-th evidence parameter of the ENCLOSING declaration
    /// (static-dispatch-spike.md §8.1). `module` is `.none` and the tag is
    /// `no_tag`, so the printer spells it exactly; `$` cannot start a beni
    /// identifier, so no source name collides.
    ///
    /// One level, no depth (A.31): only a top-level declaration has
    /// evidence parameters (§6.4 rule (a)), and a lambda in its body reads
    /// `$m$k` by ordinary lexical capture.
    fn evidenceName(l: *Lowerer, k: u16) !JsIr.NameIndex {
        var buf: [16]u8 = undefined;
        const spelled = std.fmt.bufPrint(&buf, "$m${d}", .{k}) catch unreachable;
        const base = try l.interner.getOrPut(l.gpa, spelled);
        return l.name(.{ .module = .none, .base = base, .tag = JsIr.Name.no_tag });
    }

    /// `<Module>$<base>` for a value this module SYNTHESISES rather than
    /// declares (§8.5): the primitive comparators of §9.1 today, the
    /// derived functions of §9 when S5 lands.
    fn synthesisedName(l: *Lowerer, base: []const u8) !JsIr.NameIndex {
        const symbol = try l.interner.getOrPut(l.gpa, base);
        return l.name(.{ .module = l.module_name.toOptional(), .base = symbol, .tag = JsIr.Name.no_tag });
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
    ///
    /// **`refs` is not the whole graph any more.** A `method_call` adds no
    /// `refs` edge, because which function it calls is not known before the
    /// checker runs (static-dispatch-spike.md §1.4) — so a constant whose
    /// initialiser is `(T 1).bump 2` would be emitted above `T`'s `bump`
    /// and throw on its own temporal dead zone. The dispatch table carries
    /// those edges: every site of this declaration's instructions whose
    /// target is `top d` is one more dependency, walked exactly like a
    /// `refs` row.
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
            try stack.append(l.scratch, .{ .decl = @intCast(root), .next = 0, .sites = l.declSiteRange(@intCast(root)) });
            state[root] = 1;
            while (stack.items.len != 0) {
                const frame = &stack.items[stack.items.len - 1];
                const d = l.bir.decls[frame.decl];
                const refs = l.bir.refs[d.refs_start..d.refs_end];
                // Found ONCE per frame, not once per edge: `declSites` is a
                // binary search plus a scan of the run it finds, and a
                // declaration with s sites would otherwise pay for it s
                // times over.
                const sites = l.in.dispatch.sites[frame.sites.start..][0..frame.sites.len];
                if (frame.next < refs.len + sites.len) {
                    const at = frame.next;
                    frame.next += 1;
                    const next: u32 = if (at < refs.len) blk: {
                        const ref = refs[at];
                        if (ref.kind != .top_value) continue;
                        break :blk ref.a;
                    } else switch (sites[at - refs.len].target) {
                        .top => |decl| decl.int(),
                        else => continue,
                    };
                    if (next >= count or state[next] != 0) continue;
                    state[next] = 1;
                    try stack.append(l.scratch, .{ .decl = next, .next = 0, .sites = l.declSiteRange(next) });
                    continue;
                }
                state[frame.decl] = 2;
                order.appendAssumeCapacity(frame.decl);
                _ = stack.pop();
            }
        }
        return order.items;
    }

    const Frame = struct { decl: u32, next: usize, sites: Dispatch.Range };

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
        // §8.1: the hidden leading parameters, one per entry of this
        // declaration's `decl_evidence` run, in the canonical order of
        // §7.2. A declaration of zero beni parameters that has evidence
        // would become a function and change its type across the module
        // boundary; the checker refuses it first (`constrained_constant`,
        // §6.4), so the constant path below is reached only with none.
        const evidence: u16 = @intCast(l.in.dispatch.declEvidence(index).len);
        if (d.params == 0 and evidence == 0) {
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
        const record = try l.functionOf(evidence, params, body, p);
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
    fn functionOf(l: *Lowerer, evidence: u16, params: []const Inst.Index, body: Inst.Index, p: u32) !JsIr.ExtraIndex {
        var names: std.ArrayList(JsIr.NameIndex) = .empty;
        var stmts: StmtList = .empty;
        // The evidence parameters come FIRST, before the declaration's own
        // (§8.1). `evidence` is zero for every lambda: §6.4 rule (a) keeps a
        // nested binding from being generalised over a constrained
        // variable, so only a top-level declaration ever has any (A.31).
        var k: u16 = 0;
        while (k < evidence) : (k += 1) try names.append(l.scratch, try l.evidenceName(k));
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
        l.region = inst;
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
                const record = try l.functionOf(0, params, @enumFromInt(d.rhs), p);
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
            .type_dispatch => return l.typeDispatchExpr(out, inst),
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
    /// constructor needs anything built, because it has no binding — and a
    /// CONSTRAINED value, which is its eta-expansion (§8.2, A.25): the bare
    /// name has the evidence parameters in front and therefore the wrong
    /// arity, so `let f = Dict.insert` is `(a, b, c) => Dict$insert(cmp, a,
    /// b, c)` and never `Dict$insert`.
    fn reference(l: *Lowerer, inst: Inst.Index) !Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        if (l.ctorRepOf(inst)) |rep_and_tag| {
            const rep, const tag = rep_and_tag;
            const arity = l.ctorArity(inst);
            if (arity == 0) return l.ctorValue(rep, tag, &.{}, p);
            return l.ctorLambda(rep, tag, arity, p);
        }
        const value = switch (l.bir.instTag(inst)) {
            .local => try l.ident(try l.localName(d.lhs), p),
            .top => try l.ident(try l.topName(d.lhs), p),
            .ext_value => blk: {
                const module: Graph.Index = @enumFromInt(d.lhs);
                try l.need(module, d.rhs);
                break :blk try l.ident(try l.externalName(module, d.rhs), p);
            },
            else => try l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
        };
        const sites = l.sitesOf(inst);
        if (sites.len == 0) return value;
        l.region = inst;
        if (try l.refuseEvidence(inst, sites, l.valueEvidence(inst))) {
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        return l.etaExpand(value, try l.evidenceArguments(sites, p), l.referenceArity(inst), p);
    }

    /// How many evidence parameters the value an instruction NAMES takes:
    /// from `decl_evidence` for a value of this module and from the
    /// interface scheme for an imported one — the same two records
    /// `targetEvidence` reads, keyed by instruction instead of by target.
    ///
    /// That count is exactly how many top-level evidence slots §7.2 puts on
    /// a bare reference to the value, and on a `call` of it, so it is what
    /// the wall of `evidenceShapeOk` measures those lists against. Anything
    /// else — a local, a lambda, a constructor — takes none: §6.4 rule (a)
    /// keeps a nested binding from being generalised over a constrained
    /// variable, so nothing but a top-level declaration has evidence.
    fn valueEvidence(l: *Lowerer, inst: Inst.Index) u16 {
        const d = l.bir.instData(inst);
        return switch (l.bir.instTag(inst)) {
            .top => @intCast(l.in.dispatch.declEvidence(d.lhs).len),
            .ext_value => l.externalEvidence(@enumFromInt(d.lhs), d.rhs),
            else => 0,
        };
    }

    /// The beni arity of the value a reference names: how many parameters
    /// its eta-expansion has to take.
    fn referenceArity(l: *Lowerer, inst: Inst.Index) u32 {
        const d = l.bir.instData(inst);
        return switch (l.bir.instTag(inst)) {
            .top => if (d.lhs < l.bir.decls.len) l.bir.decls[d.lhs].params else 0,
            .ext_value => l.externalArity(@enumFromInt(d.lhs), d.rhs),
            else => 0,
        };
    }

    // ---- Calls and dispatch (static-dispatch-spike.md §8) -----------------
    //
    // The checker decided which function every method call runs and which
    // value every polymorphic site passes; §7's table is that decision as
    // DATA, and everything below reads targets and never types
    // (`backend.md` §3). Three shapes come out of it: hidden leading
    // parameters on a declaration (§8.1), hidden leading arguments at a
    // call (§8.2), and the operator itself when the target is a primitive
    // (§8.3).

    /// The dispatch sites of one instruction, in `evidence_index` order.
    /// `dispatch.sites` is sorted by `(inst, evidence_index)` (§7.1), so
    /// this is one binary search and a slice — never a scan. It runs once
    /// for each instruction that can carry sites: every `call`,
    /// `method_call` and `type_dispatch`, and every REFERENCE too, because
    /// §7.2 gives a bare mention of a constrained value evidence of its own
    /// (§8.2's last row). A module has as many such instructions as it has
    /// calls and references, so a scan here would be quadratic in the size
    /// of a declaration and a search is not.
    fn sitesOf(l: *Lowerer, inst: Inst.Index) []const Dispatch.Site {
        return l.siteRange(inst.int(), inst.int() + 1);
    }

    /// The dispatch sites of one declaration: its instructions are
    /// contiguous (`Bir.Decl.inst_start`), so they are one slice too.
    fn declSiteRange(l: *Lowerer, decl: u32) Dispatch.Range {
        const d = l.bir.decls[decl];
        return l.siteRangeOf(d.inst_start.int(), d.inst_end.int());
    }

    fn siteRange(l: *Lowerer, start: u32, end: u32) []const Dispatch.Site {
        const r = l.siteRangeOf(start, end);
        return l.in.dispatch.sites[r.start..][0..r.len];
    }

    fn siteRangeOf(l: *Lowerer, start: u32, end: u32) Dispatch.Range {
        const sites = l.in.dispatch.sites;
        const lo = std.sort.lowerBound(Dispatch.Site, sites, start, siteBefore);
        var hi = lo;
        while (hi < sites.len and sites[hi].inst.int() < end) hi += 1;
        return .{ .start = @intCast(lo), .len = @intCast(hi - lo) };
    }

    fn siteBefore(inst: u32, s: Dispatch.Site) std.math.Order {
        return std.math.order(inst, s.inst.int());
    }

    /// How many evidence parameters a target's own JavaScript function
    /// takes. Nonzero means it is not a value of the arity its slot
    /// promises and must be eta-expanded (§8.2, A.25).
    fn targetEvidence(l: *Lowerer, target: Dispatch.Target) u16 {
        return switch (target) {
            .top => |decl| @intCast(l.in.dispatch.declEvidence(decl.int()).len),
            .ext => |e| l.externalEvidence(e.module, @intFromEnum(e.value)),
            // A primitive comparator and an evidence parameter are already
            // closures of the right arity; `derived` and `ext_derived` are
            // refused above this point until S5 emits them.
            else => 0,
        };
    }

    /// The beni arity of a target: how many parameters its eta-expansion
    /// takes, which is the arity the evidence slot promised.
    fn targetArity(l: *Lowerer, target: Dispatch.Target) u32 {
        return switch (target) {
            // No bounds test: a `top` target names a declaration of the
            // module being lowered, and `targetValue` asserts exactly that
            // before `topName` indexes the same table unguarded. One rule
            // for one invariant, rather than a guard here that invents a
            // zero and a panic there.
            .top => |decl| l.bir.decls[decl.int()].params,
            .ext => |e| l.externalArity(e.module, @intFromEnum(e.value)),
            else => 0,
        };
    }

    /// The JavaScript value a target names (§8.2's table), with the import
    /// recorded for an `ext` exactly as for any other cross-module
    /// reference.
    fn targetValue(l: *Lowerer, target: Dispatch.Target, p: u32) !Node.Index {
        return switch (target) {
            // `topName` and `externalName` index `bir.decls` and the
            // interface's value table without a bounds test, and so does
            // `targetArity`. A target naming neither is a malformed table
            // and not a program, so it is an assert: a guard here would
            // emit a name for a declaration that is not there.
            .top => |decl| blk: {
                std.debug.assert(decl.int() < l.bir.decls.len);
                break :blk try l.ident(try l.topName(decl.int()), p);
            },
            .ext => |e| blk: {
                std.debug.assert(e.module.int() < l.in.interfaces.len);
                std.debug.assert(@intFromEnum(e.value) < l.in.interfaces[e.module.int()].values.len);
                try l.need(e.module, @intFromEnum(e.value));
                break :blk try l.ident(try l.externalName(e.module, @intFromEnum(e.value)), p);
            },
            .evidence => |k| try l.ident(try l.evidenceName(k), p),
            .primitive => |prim| try l.primitiveValue(prim, p),
            // Unreachable: `field` and `err` cannot be evidence (§8.2), and
            // a `derived` target was refused before this was called.
            else => try l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
        };
    }

    fn externalScheme(l: *Lowerer, module: Graph.Index, value: u32) ?Interface.Scheme {
        if (module.int() >= l.in.interfaces.len) return null;
        const iface = &l.in.interfaces[module.int()];
        if (value >= iface.values.len) return null;
        const index = iface.values[value].scheme;
        if (index == .none or @intFromEnum(index) >= iface.schemes.len) return null;
        return iface.scheme(index);
    }

    /// The evidence count of an imported value, computed from its
    /// interface scheme the way §7.2's canonical order is: one slot per
    /// constraint of each quantifier, quantifiers in the order the scheme
    /// records them. Caller and callee derive it from the same record, so
    /// they agree.
    fn externalEvidence(l: *Lowerer, module: Graph.Index, value: u32) u16 {
        const s = l.externalScheme(module, value) orelse return 0;
        const iface = &l.in.interfaces[module.int()];
        var n: u32 = 0;
        var i: u32 = 0;
        while (i < s.quantified_count) : (i += 1) n += iface.quantified(s, i).constraints_len;
        return std.math.cast(u16, n) orelse 0;
    }

    /// The beni arity of an imported value: the parameter count of its
    /// scheme body when that body is a function type, and zero otherwise.
    fn externalArity(l: *Lowerer, module: Graph.Index, value: u32) u32 {
        const s = l.externalScheme(module, value) orelse return 0;
        const iface = &l.in.interfaces[module.int()];
        if (s.body == .none or s.body.int() >= iface.terms.len) return 0;
        const t = iface.term(s.body);
        if (t.tag != .func) return 0;
        return @intCast(iface.range(t.lhs).len);
    }

    /// The hidden leading arguments of one instruction (§8.2), in
    /// `evidence_index` order.
    ///
    /// The list is FLAT and the structure is a tree: a target that takes
    /// evidence of its own consumes the slots that follow it, which is the
    /// eta-expansion of A.25. So the walk is a pre-order over a cursor and
    /// not an index lookup — the indices order the slots, the counts shape
    /// them.
    fn evidenceArguments(l: *Lowerer, sites: []const Dispatch.Site, p: u32) ![]const Node.Index {
        var out: std.ArrayList(Node.Index) = .empty;
        var cursor: usize = 0;
        while (cursor < sites.len) {
            try out.append(l.scratch, try l.evidenceValue(sites, &cursor, p));
        }
        return out.items;
    }

    fn evidenceValue(l: *Lowerer, sites: []const Dispatch.Site, cursor: *usize, p: u32) Allocator.Error!Node.Index {
        const target = sites[cursor.*].target;
        cursor.* += 1;
        const wanted = l.targetEvidence(target);
        var bound: std.ArrayList(Node.Index) = .empty;
        var k: u16 = 0;
        while (k < wanted and cursor.* < sites.len) : (k += 1) {
            try bound.append(l.scratch, try l.evidenceValue(sites, cursor, p));
        }
        const value = try l.targetValue(target, p);
        if (wanted == 0) return value;
        return l.etaExpand(value, bound.items, l.targetArity(target), p);
    }

    /// `(a, b) => <name>(<bound…>, a, b)` — a constrained value in VALUE
    /// position (§8.2, A.25). The bare name has the evidence parameters in
    /// front of the beni ones, so it is a function of the wrong arity, and
    /// `backend.md` §6 requires every function-typed value in flight to be
    /// a closure of known arity.
    fn etaExpand(l: *Lowerer, callee: Node.Index, bound: []const Node.Index, arity: u32, p: u32) !Node.Index {
        var params: std.ArrayList(JsIr.NameIndex) = .empty;
        var args: std.ArrayList(Node.Index) = .empty;
        try args.appendSlice(l.scratch, bound);
        for (0..arity) |_| {
            const n = try l.fresh(l.well.param);
            try params.append(l.scratch, n);
            try args.append(l.scratch, try l.ident(n, p));
        }
        const stmts = [_]Node.Index{try l.returnStmt(try l.call(callee, args.items, p), p)};
        return l.arrowOf(params.items, &stmts, p);
    }

    /// A primitive comparison as a VALUE (§9.1): an operator is not a
    /// value, so the module emits the comparator once and every evidence
    /// slot names it. `String` routes to the core function instead, because
    /// `<` on JavaScript strings is UTF-16 code-unit order and
    /// `String.compare` is Unicode scalar order, and the two must agree
    /// (§3.2, A.26).
    fn primitiveValue(l: *Lowerer, prim: Dispatch.Target.Primitive, p: u32) !Node.Index {
        switch (prim) {
            .strict_eq => {
                l.needs.eq_prim = true;
                return l.ident(try l.synthesisedName("eq$prim"), p);
            },
            .num_compare => {
                l.needs.compare_prim = true;
                return l.ident(try l.synthesisedName("compare$prim"), p);
            },
            .char_compare => {
                l.needs.compare_char = true;
                return l.ident(try l.synthesisedName("compare$char"), p);
            },
            .string_compare => return l.stringCompare(p),
        }
    }

    /// `String.compare`, however this module reaches it.
    fn stringCompare(l: *Lowerer, p: u32) !Node.Index {
        return l.coreValue(.String, .compare, p);
    }

    /// The `const`s §9.1 asks for, in the emission order of §8.5 — by
    /// printed name text, which is `compare$char`, `compare$prim`,
    /// `eq$prim`. They are not exported: a structural comparison has no
    /// owning module, so each consumer emits its own (§8.5).
    fn primitiveValues(l: *Lowerer) ![]const Node.Index {
        var out: StmtList = .empty;
        if (l.needs.compare_char) try out.append(l.scratch, try l.compareCharDecl());
        if (l.needs.compare_prim) try out.append(l.scratch, try l.comparePrimDecl());
        if (l.needs.eq_prim) try out.append(l.scratch, try l.eqPrimDecl());
        return out.items;
    }

    fn operandNames(l: *Lowerer) ![2]JsIr.NameIndex {
        return .{
            try l.name(.{ .module = .none, .base = l.well.left, .tag = JsIr.Name.no_tag }),
            try l.name(.{ .module = .none, .base = l.well.right, .tag = JsIr.Name.no_tag }),
        };
    }

    /// `const M$eq$prim = ($x, $y) => $x === $y;`
    fn eqPrimDecl(l: *Lowerer) !Node.Index {
        const p = Node.no_pos;
        const x, const y = try l.operandNames();
        const body = try l.binary(.strict_eq, try l.ident(x, p), try l.ident(y, p), p);
        const stmts = [_]Node.Index{try l.returnStmt(body, p)};
        const arrow = try l.arrowOf(&.{ x, y }, &stmts, p);
        return l.add(.const_decl, p, @intFromEnum(try l.synthesisedName("eq$prim")), arrow.int());
    }

    /// `const M$compare$prim = ($x, $y) => ($x < $y ? "LT" : $x > $y ? "GT" : "EQ");`
    fn comparePrimDecl(l: *Lowerer) !Node.Index {
        const p = Node.no_pos;
        const x, const y = try l.operandNames();
        const body = try l.orderOf(try l.ident(x, p), try l.ident(y, p), p);
        const stmts = [_]Node.Index{try l.returnStmt(body, p)};
        const arrow = try l.arrowOf(&.{ x, y }, &stmts, p);
        return l.add(.const_decl, p, @intFromEnum(try l.synthesisedName("compare$prim")), arrow.int());
    }

    /// `const M$compare$char = ($x, $y) => { const $a = …; const $b = …; return … };`
    /// — a code POINT comparison, which is what `Char`'s order means and
    /// what `<` on the one-character strings a `Char` is would not give
    /// (§9.1, A.26).
    fn compareCharDecl(l: *Lowerer) !Node.Index {
        const p = Node.no_pos;
        const x, const y = try l.operandNames();
        const a = try l.name(.{ .module = .none, .base = l.well.cp_left, .tag = JsIr.Name.no_tag });
        const b = try l.name(.{ .module = .none, .base = l.well.cp_right, .tag = JsIr.Name.no_tag });
        var stmts: StmtList = .empty;
        try l.constDecl(&stmts, a, try l.codePointCall(try l.ident(x, p), p), p);
        try l.constDecl(&stmts, b, try l.codePointCall(try l.ident(y, p), p), p);
        const body = try l.orderOf(try l.ident(a, p), try l.ident(b, p), p);
        try stmts.append(l.scratch, try l.returnStmt(body, p));
        const arrow = try l.arrowOf(&.{ x, y }, stmts.items, p);
        return l.add(.const_decl, p, @intFromEnum(try l.synthesisedName("compare$char")), arrow.int());
    }

    /// `l < r ? "LT" : l > r ? "GT" : "EQ"` — the `Order` of two values
    /// JavaScript's relational operators order correctly. `Order` is
    /// all-nullary, so its constructors are bare tag strings (§9.1).
    fn orderOf(l: *Lowerer, left: Node.Index, right: Node.Index, p: u32) !Node.Index {
        const gt = try l.b.addRecord(JsIr.Cond{
            .consequent = try l.stringNode("GT", p),
            .alternate = try l.stringNode("EQ", p),
        });
        const inner = try l.add(.cond, p, (try l.binary(.gt, left, right, p)).int(), @intFromEnum(gt));
        const lt = try l.b.addRecord(JsIr.Cond{
            .consequent = try l.stringNode("LT", p),
            .alternate = inner,
        });
        return l.add(.cond, p, (try l.binary(.lt, left, right, p)).int(), @intFromEnum(lt));
    }

    fn codePointCall(l: *Lowerer, value: Node.Index, p: u32) !Node.Index {
        const callee = try l.member(value, l.well.code_point_at, p);
        return l.call(callee, &.{try l.numberNode("0", p)}, p);
    }

    /// `e.codePointAt(0)`, with `e` bound to a `const` first when it is not
    /// already a name so that each operand is evaluated exactly once
    /// (§8.3's `CP(e)`).
    fn codePointOf(l: *Lowerer, out: *StmtList, value: Node.Index, p: u32) !Node.Index {
        return l.codePointCall(try l.bindSubject(out, value, p), p);
    }

    /// **S5's wall.** Every row of §8 is lowered here except a `derived` or
    /// `ext_derived` target, whose function S5 emits and this slice does
    /// not — so a site that names one is refused rather than compiled into
    /// a call of a name that is not there. The one exception is A.51's
    /// bridge, kept exactly: `==` and `/=` against a structural answer
    /// still go through `core/Basics.js`'s `eq`, which IS that structural
    /// walk and gives the same answer.
    fn refuseEvidence(l: *Lowerer, inst: Inst.Index, sites: []const Dispatch.Site, expected: u16) !bool {
        for (sites) |site| {
            switch (site.target) {
                .derived, .ext_derived => {
                    try l.refuseDerived(inst);
                    return true;
                },
                else => {},
            }
        }
        if (!l.evidenceShapeOk(sites, expected)) {
            try l.reportEvidenceShape(inst);
            return true;
        }
        return false;
    }

    /// Whether `sites` is the tree §8.2 describes, `expected` slots wide —
    /// and the one place §7.2's promise is kept.
    ///
    /// The evidence list is FLAT, and the structure is implied by counts
    /// the backend works out for itself: from `decl_evidence` for a value
    /// of this module, from the interface scheme for an imported one. So
    /// two records have to agree about how many hidden arguments a callee
    /// takes, and §7.2 says the table exists so that a caller/callee
    /// disagreement is "a caught bug rather than a silent miscompile". If
    /// the counts did not consume the list exactly, the emitted call has
    /// the wrong number of arguments — and JavaScript RUNS a call with the
    /// wrong number of arguments, binding `undefined` and returning `NaN`.
    ///
    /// `field` and `err` are the other half: §8.2 says neither can stand in
    /// evidence position, so meeting one is a checker bug, not a program.
    ///
    /// **`expected` is the third half, and the one the nesting cannot give.**
    /// The nested counts say how the list is SHAPED; only the callee's own
    /// evidence count says how WIDE it is. A list that nests correctly and
    /// has one slot too many, or one too few, consumes itself just as
    /// happily — and both emit a call of the wrong arity that JavaScript
    /// runs: two slots for a one-evidence callee printed `NaN` and then
    /// recursed forever, none for a two-evidence callee threw
    /// `TypeError: $m$0 is not a function`, and the build exited 0 either
    /// way. So the walk counts the TOP-LEVEL slots it consumed and demands
    /// exactly `expected`.
    fn evidenceShapeOk(l: *Lowerer, sites: []const Dispatch.Site, expected: u16) bool {
        var cursor: usize = 0;
        var slots: u32 = 0;
        while (cursor < sites.len) : (slots += 1) {
            // Too long: a further top-level slot the callee has no
            // parameter for. Caught here rather than after the loop so a
            // long list cannot walk off into a nested one's counts.
            if (slots >= expected) return false;
            if (!l.evidenceShapeOne(sites, &cursor)) return false;
        }
        // Too short: the list ran out before the callee's parameters did.
        return slots == expected;
    }

    fn evidenceShapeOne(l: *Lowerer, sites: []const Dispatch.Site, cursor: *usize) bool {
        const target = sites[cursor.*].target;
        cursor.* += 1;
        switch (target) {
            .field, .err => return false,
            else => {},
        }
        const wanted = l.targetEvidence(target);
        var k: u16 = 0;
        while (k < wanted) : (k += 1) {
            if (cursor.* >= sites.len) return false;
            if (!l.evidenceShapeOne(sites, cursor)) return false;
        }
        return true;
    }

    /// `internal`, and not `not_implemented`: nothing is missing, two
    /// records disagree. The build stops rather than writing a call whose
    /// arguments are off by one — `backend.md` §1's rule that the half that
    /// is missing must say so, applied to a half that is WRONG.
    fn reportEvidenceShape(l: *Lowerer, inst: Inst.Index) !void {
        try l.report(
            .internal,
            inst,
            \\The hidden arguments of this call do not add up.
            \\
            \\`docs/design/static-dispatch-spike.md` §8.2 passes one hidden argument per
            \\evidence site, and each site that is itself constrained consumes the sites
            \\after it. The list the checker recorded does not fit that shape — either a
            \\site names something §8.2 cannot pass, or a callee's evidence count here
            \\disagrees with the one in its own module.
            \\
            \\That is a compiler bug. Please report it with this program; `beni dump
            \\--stage=dispatch` prints the table this reads.
        ,
            .{},
        );
    }

    /// `internal`, for a `Dispatch` table that does not describe a program
    /// this backend can emit. Same tone and same reason as
    /// `reportEvidenceShape`: nothing is MISSING — that is
    /// `not_implemented` — something is WRONG, and the only honest output
    /// is a stopped build. Every one of these is reachable exactly when the
    /// checker forgets or misplaces a site, and each used to return
    /// `undefined` and exit 0.
    fn reportDispatchBug(l: *Lowerer, inst: Inst.Index, detail: []const u8) !void {
        try l.report(
            .internal,
            inst,
            \\I cannot tell what this call dispatches to.
            \\
            \\{s}
            \\
            \\That is a compiler bug. Please report it with this program; `beni dump
            \\--stage=dispatch` prints the table this reads.
        ,
            .{detail},
        );
    }

    /// §7.2 gives every `method_call` and every `type_dispatch` a site at
    /// `evidence_index` 0 naming the function it runs. None means the
    /// checker did not record one, which no program can ask for.
    const no_callee_site =
        \\`docs/design/static-dispatch-spike.md` §7.2 gives every method call and every
        \\return-type dispatch a site at `evidence_index` 0 naming the function it runs,
        \\and the table has none here — so there is no function to call.
    ;

    /// §8.4 has no receiver, so §8.3's record-field row cannot appear.
    const field_without_receiver =
        \\The table dispatches this to a record field, but `docs/design/static-dispatch-spike.md`
        \\§8.4 has no receiver to read a field from: only a method call can answer `field`.
    ;

    /// §8.3's primitive rows are the binary comparison methods.
    const primitive_needs_two_operands =
        \\The table dispatches this to one of `docs/design/static-dispatch-spike.md` §8.3's
        \\primitive comparisons, and every one of those is binary — a receiver and exactly
        \\one argument. This call has a different number of arguments.
    ;

    /// Whether a derived `eq` answers exactly what `core/Basics.js`'s `eq`
    /// answers — which is the whole of A.51's bridge, and the reason it has
    /// to be RECURSIVE.
    ///
    /// `core/Basics.js`'s `eq` is one structural walk: it compares every
    /// reachable primitive with `===` and knows nothing about a user's own
    /// `pub eq`. A derived function does know, because the checker put that
    /// user method in the table as a part — so `{ k = Id 1 2 } == { k = Id
    /// 1 99 }`, whose `derived 0` has `part 0 ext Id eq`, is `True` by the
    /// table and `False` by the structural walk. Checking only the
    /// top-level target accepted exactly that program and printed the wrong
    /// answer.
    ///
    /// So every part must itself be structural: `primitive strict_eq`, or
    /// another derived `eq` all of whose parts are. A `top`, `ext` or
    /// `evidence` part is a FUNCTION the walk would not call, and refuses.
    ///
    /// Two halves per `derived`, because `parts` means two different things
    /// (§7.1): the `Derived` row's parts are the BODY's positions, where
    /// `evidence i` means "this function's own i-th parameter" and is
    /// answered by the use; the `Target`'s parts are what the use HANDS it,
    /// where `evidence k` would mean the enclosing declaration's parameter
    /// and is never structural.
    ///
    /// The residual gap, stated because S5 closes it rather than this
    /// slice: an `ext_derived` names another module's nominal type, whose
    /// body positions are that module's table and not ours (A.47) — so a
    /// user `pub eq` buried inside another module's type is invisible here
    /// and still reaches the structural walk. That is `master`'s behaviour
    /// for the same program, and §9's derived bodies are what fix it.
    fn structuralEq(l: *Lowerer, target: Dispatch.Target, seen: ?*const Seen) bool {
        switch (target) {
            .primitive => |prim| return prim == .strict_eq,
            // The checker could not name a function for this position —
            // today an element whose type is still a `number` variable at
            // generalisation. `master` compiled that program through the
            // structural walk and got the right answer (a `number` is an
            // `Int` or a `Float`, and `===` is both their `eq`), so the
            // bridge keeps it rather than refusing a program that worked.
            // It is not a licence to guess: `err` says "unknown", and the
            // one thing the walk gets wrong — a user's own `pub eq` — is a
            // `top` or `ext` part and refuses below.
            //
            // INVARIANT, and it is the CHECKER's to hold: an `err` part
            // means "a `number` still unresolved at generalisation" and
            // NOTHING else. The moment the checker starts writing `err` for
            // a position it could not resolve for some other reason — a
            // user's own method it failed to find, say — this line silently
            // routes that position through the structural walk and answers
            // the wrong `Bool`. Nothing in `run/` or `emit/` can see the
            // difference, because both readings compile and only one is
            // right; what pins it is a `dispatch/` golden over a `number`
            // element, showing `err` in the parts list and no other `err`
            // anywhere in the corpus.
            .err => return true,
            .derived => |use| {
                const table = l.in.dispatch;
                if (use.index >= table.derived.len) return false;
                const row = table.derived[use.index];
                if (row.kind != .eq) return false;
                // A recursive type's own derived function is a part of
                // itself; meeting it again adds no new part to judge.
                var walk = seen;
                while (walk) |node| : (walk = node.prev) {
                    if (node.index == use.index) return true;
                }
                const here: Seen = .{ .index = use.index, .prev = seen };
                for (table.partsAt(row.parts)) |part| {
                    // `evidence i` in a BODY is this function's own
                    // parameter, answered by the use's parts below.
                    if (std.meta.activeTag(part) == .evidence) continue;
                    if (!l.structuralEq(part, &here)) return false;
                }
                // `partsOf()` and not `use.parts`: `src/dump/dispatch.zig`
                // reads a target's evidence through it, and the emitter and
                // the dump have to read the table the same way or a dump
                // that looks right can sit over an emission that is not.
                for (table.partsAt(target.partsOf())) |part| {
                    if (!l.structuralEq(part, &here)) return false;
                }
                return true;
            },
            .ext_derived => |use| {
                if (use.kind != .eq) return false;
                for (l.in.dispatch.partsAt(target.partsOf())) |part| {
                    if (!l.structuralEq(part, seen)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    const Seen = struct { index: u32, prev: ?*const Seen };

    fn refuseDerived(l: *Lowerer, inst: Inst.Index) !void {
        try l.report(
            .not_implemented,
            inst,
            \\I cannot compile this comparison to JavaScript yet.
            \\
            \\The checker resolved it to a DERIVED `eq` or `compare`
            \\(`docs/design/static-dispatch-spike.md` §9) — a function generated from the
            \\shape of the type — and the code generator grows those in S5. Evidence
            \\parameters and every other target of §8 are lowered already.
            \\
            \\Hint: compare the parts by hand, or pass an ordering function, until then.
        ,
            .{},
        );
    }

    /// A method call (§8.3). The callee is site 0 of the instruction and
    /// every further site is one hidden argument in front of the receiver.
    fn methodCallExpr(l: *Lowerer, out: *StmtList, inst: Inst.Index) !Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        const m = l.bir.extraData(@enumFromInt(d.rhs), Bir.MethodCall);
        const args: Bir.SubRange = .{ .start = m.args_start, .end = m.args_end };
        const sites = l.sitesOf(inst);
        l.region = inst;
        // §7.2 gives every `method_call` a site 0 naming the callee. None
        // means the checker forgot one — a program that failed to check
        // never reaches here, because `beni build` refuses to emit a
        // project that has an error diagnostic — so it is a compiler bug
        // and says so rather than emitting `undefined(…)` and exiting 0.
        if (sites.len == 0 or sites[0].evidence_index != 0) {
            try l.reportDispatchBug(inst, no_callee_site);
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        const target = sites[0].target;
        const evidence_sites = sites[1..];
        switch (target) {
            // A record receiver: `language.md` §6.3's field call, unchanged.
            .field => {
                // A field call passes no evidence — the closure in the
                // field is already of the arity the call site wrote — so
                // this list is empty, and a non-empty one is the same
                // caught bug as any other wrong-length list. Checked rather
                // than dropped: a list here means the checker instantiated
                // a scheme it then dispatched to a field, and dropping it
                // silently emits a call short of its arguments.
                if (try l.refuseEvidence(inst, evidence_sites, 0)) {
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                const receiver = try l.expr(out, @enumFromInt(d.lhs));
                const callee = try l.member(receiver, l.bir.symbol(m.name), p);
                return l.call(callee, try l.exprList(out, args), p);
            },
            // The ONE silent `undefined` §8.3 documents: `err` is a site
            // the checker could not resolve, and it only makes one after
            // reporting why. A second diagnostic here would name the same
            // program twice, so this arm emits what the `error` instruction
            // emits and says nothing.
            .err => return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
            // A.51's bridge, and the only place S5's wall has a door.
            .derived, .ext_derived => {
                const bridged = switch (m.origin) {
                    .eq, .neq => l.structuralEq(target, null),
                    else => false,
                };
                const function = if (bridged) m.origin.basicsFunction().? else {
                    try l.refuseDerived(inst);
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                };
                const callee = try l.coreValue(.Basics, function, p);
                return l.receiverCall(out, callee, &.{}, @enumFromInt(d.lhs), args, p);
            },
            .primitive => |prim| {
                if (try l.refuseEvidence(inst, evidence_sites, l.targetEvidence(target))) {
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                const receiver = try l.expr(out, @enumFromInt(d.lhs));
                const rest = try l.exprList(out, args);
                if (rest.len != 1) {
                    try l.reportDispatchBug(inst, primitive_needs_two_operands);
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                // Lowering the operands moved `region` into them; the
                // operator's own instruction is what a diagnostic from here
                // is about.
                l.region = inst;
                return l.primitiveOperator(out, prim, m.origin, receiver, rest[0], p);
            },
            .top, .ext, .evidence => {
                if (try l.refuseEvidence(inst, evidence_sites, l.targetEvidence(target))) {
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                const evidence = try l.evidenceArguments(evidence_sites, p);
                const callee = try l.targetValue(target, p);
                const value = try l.receiverCall(out, callee, evidence, @enumFromInt(d.lhs), args, p);
                // An ordering operator against a non-primitive target is
                // the `Order` test of §8.3: the method answers `Order` and
                // the operator answers `Bool`.
                return l.orderTest(value, m.origin, p);
            },
        }
    }

    /// `callee(<evidence…>, receiver, args…)` — §8.3's shape, with the
    /// receiver in front of the written arguments because core is
    /// subject-first and a dot-call is the module function applied to its
    /// receiver.
    fn receiverCall(
        l: *Lowerer,
        out: *StmtList,
        callee: Node.Index,
        evidence: []const Node.Index,
        receiver_inst: Inst.Index,
        args: Bir.SubRange,
        p: u32,
    ) !Node.Index {
        const receiver = try l.expr(out, receiver_inst);
        const rest = try l.exprList(out, args);
        const all = try l.scratch.alloc(Node.Index, evidence.len + 1 + rest.len);
        @memcpy(all[0..evidence.len], evidence);
        all[evidence.len] = receiver;
        @memcpy(all[evidence.len + 1 ..], rest);
        return l.call(callee, all, p);
    }

    /// Return-type dispatch (§8.4): §8.3 with no receiver. Inside a
    /// constrained declaration the target is always `evidence k` (§6.7), so
    /// in practice this is `$m$k(args…)`.
    fn typeDispatchExpr(l: *Lowerer, out: *StmtList, inst: Inst.Index) !Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        const t = l.bir.extraData(@enumFromInt(d.rhs), Bir.TypeDispatch);
        const args: Bir.SubRange = .{ .start = t.args_start, .end = t.args_end };
        const sites = l.sitesOf(inst);
        l.region = inst;
        if (sites.len == 0 or sites[0].evidence_index != 0) {
            try l.reportDispatchBug(inst, no_callee_site);
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        const target = sites[0].target;
        switch (target) {
            .top, .ext, .evidence, .primitive => {},
            .derived, .ext_derived => {
                try l.refuseDerived(inst);
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
            // There is no receiver, so `field` cannot appear at all and is
            // a malformed table. `err` is the one silent case again: the
            // site the checker could not resolve, already reported.
            .field => {
                try l.reportDispatchBug(inst, field_without_receiver);
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
            .err => return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
        }
        if (try l.refuseEvidence(inst, sites[1..], l.targetEvidence(target))) {
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        const evidence = try l.evidenceArguments(sites[1..], p);
        const callee = try l.targetValue(target, p);
        const rest = try l.exprList(out, args);
        const all = try l.scratch.alloc(Node.Index, evidence.len + rest.len);
        @memcpy(all[0..evidence.len], evidence);
        @memcpy(all[evidence.len..], rest);
        return l.call(callee, all, p);
    }

    /// §8.3's operator table: a `primitive` target plus the surface origin
    /// of §1.3 is the JavaScript operator itself. This is the only place
    /// the marking reaches the backend, and the reason it exists.
    fn primitiveOperator(
        l: *Lowerer,
        out: *StmtList,
        prim: Dispatch.Target.Primitive,
        origin: Bir.WellKnown,
        left: Node.Index,
        right: Node.Index,
        p: u32,
    ) !Node.Index {
        switch (prim) {
            .strict_eq => return l.binary(if (origin == .neq) .strict_ne else .strict_eq, left, right, p),
            .num_compare => {
                if (relationalOp(origin)) |op| return l.binary(op, left, right, p);
                // `x.compare y` written by hand: an operator is not a
                // value, so this is the comparator of §9.1.
                return l.call(try l.primitiveValue(.num_compare, p), &.{ left, right }, p);
            },
            .char_compare => {
                if (relationalOp(origin)) |op| {
                    const a = try l.codePointOf(out, left, p);
                    const b = try l.codePointOf(out, right, p);
                    return l.binary(op, a, b, p);
                }
                return l.call(try l.primitiveValue(.char_compare, p), &.{ left, right }, p);
            },
            // Never `<`: `core/String.js`'s `compare` is Unicode scalar
            // order and `<` is UTF-16 code-unit order, and a language where
            // `"a" < "b"` and `String.compare a b` disagree is worse than
            // one with neither (§3.2, §9.1, A.26).
            .string_compare => {
                const callee = try l.stringCompare(p);
                return l.orderTest(try l.call(callee, &.{ left, right }, p), origin, p);
            },
        }
    }

    fn relationalOp(origin: Bir.WellKnown) ?JsIr.BinaryOp {
        return switch (origin) {
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => null,
        };
    }

    /// The `Order` test of §8.3: `a < b` is `compare(a, b) === "LT"`,
    /// `a <= b` is `… !== "GT"`, and `a /= b` is `!eq(a, b)`. `Order` is
    /// all-nullary, so its constructors are bare tag strings.
    fn orderTest(l: *Lowerer, value: Node.Index, origin: Bir.WellKnown, p: u32) !Node.Index {
        return switch (origin) {
            .none, .eq => value,
            .neq => try l.unary(.not, value, p),
            .lt => try l.binary(.strict_eq, value, try l.stringNode("LT", p), p),
            .le => try l.binary(.strict_ne, value, try l.stringNode("GT", p), p),
            .gt => try l.binary(.strict_eq, value, try l.stringNode("GT", p), p),
            .ge => try l.binary(.strict_ne, value, try l.stringNode("LT", p), p),
        };
    }

    /// A reference to a `pub` value of a CORE module by name, however this
    /// module reaches it — a plain top-level name when the module being
    /// lowered is that module itself, an import otherwise. This is what
    /// `Resolve` does for an `import_value` instruction; it is done by hand
    /// here because the two values §8 needs have no reference instruction
    /// at all: `String.compare` behind `primitive string_compare` (§9.1)
    /// and `Basics.eq` behind A.51's bridge.
    ///
    /// Each failure is REPORTED and not silently emitted as `undefined`.
    /// Before the operators stopped referencing `Basics`, a core package
    /// without `eq` failed in `Resolve` with a name error (`--core-root`
    /// makes that reachable); the reference moved here, so the failure has
    /// to be reported here too, or `a == b` compiles to `undefined(a, b)`.
    fn coreValue(l: *Lowerer, comptime owner: InternPool.WellKnown, function: InternPool.WellKnown, p: u32) !Node.Index {
        const spelling = l.interner.slice(function.symbol());
        const module = l.in.graph.lookup(.core, owner.symbol()) orelse
            return l.missingCoreValue(p, @tagName(owner), spelling, "there is no such module in the core package");
        if (module == l.in.module) {
            for (l.bir.decls, 0..) |d, i| {
                if (l.bir.symbol(d.name) != function.symbol()) continue;
                return l.ident(try l.topName(@intCast(i)), p);
            }
            return l.missingCoreValue(p, @tagName(owner), spelling, "this module IS that module, and it does not declare it");
        }
        if (module.int() >= l.in.interfaces.len) {
            return l.missingCoreValue(p, @tagName(owner), spelling, "its interface is not available here");
        }
        const index = l.in.interfaces[module.int()].findValue(l.interner, function.symbol()) orelse
            return l.missingCoreValue(p, @tagName(owner), spelling, "that module does not expose it");
        try l.need(module, @intFromEnum(index));
        return l.ident(try l.externalName(module, @intFromEnum(index)), p);
    }

    /// The one failure `coreValue` can hit: a core package that does not
    /// hold a value the emitter needs. `internal`, because a complete core
    /// package always does and the build cannot continue honestly.
    fn missingCoreValue(l: *Lowerer, p: u32, owner: []const u8, spelling: []const u8, why: []const u8) !Node.Index {
        // The position is a byte offset, not an instruction, so the
        // diagnostic is attached to the declaration being lowered through
        // the module it names; `region` is what `report` underlines and the
        // nearest instruction is the one the caller was handed.
        try l.report(
            .internal,
            l.region,
            \\I cannot find `{s}.{s}`, which the code generator needs.
            \\
            \\`docs/design/static-dispatch-spike.md` §8 emits a call of it for a
            \\comparison the checker resolved, but {s}.
            \\
            \\A core package replaced with `--core-root` must declare `Basics.eq`,
            \\`Basics.neq` and `String.compare`.
        ,
            .{ owner, spelling, why },
        );
        return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
    }

    fn callExpr(l: *Lowerer, out: *StmtList, inst: Inst.Index) !Node.Index {
        // §7.2: a `call`'s callee is already in the Bir, so every site on
        // this instruction is an evidence ARGUMENT and they are numbered
        // from 0.
        const sites = l.sitesOf(inst);
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        const callee_inst: Inst.Index = @enumFromInt(d.lhs);
        // The list has to be as wide as the CALLEE's own evidence, which is
        // the callee's record and not this call's; the two disagreeing is
        // the miscompile §7.2 says the table exists to catch.
        if (try l.refuseEvidence(inst, sites, l.valueEvidence(callee_inst))) {
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
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
        //
        // The evidence arguments (§8.2) go in front of the written ones.
        // They are names and closures with no statements of their own, so
        // building them between the callee and the arguments changes no
        // evaluation order.
        const callee = try l.expr(out, callee_inst);
        l.region = inst;
        const evidence = try l.evidenceArguments(sites, p);
        const written = try l.exprList(out, l.bir.subRange(@enumFromInt(d.rhs)));
        if (evidence.len == 0) return l.call(callee, written, p);
        const args = try l.scratch.alloc(Node.Index, evidence.len + written.len);
        @memcpy(args[0..evidence.len], evidence);
        @memcpy(args[evidence.len..], written);
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
                    const record = try l.functionOf(0, params, @enumFromInt(d.rhs), p);
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

test "the evidence wall counts the top-level slots, in both directions" {
    // A SYNTHETIC `Dispatch` table, and that is the whole reason this test
    // is in-source rather than in `tests/corpus/` (CLAUDE.md rule 3 makes
    // the corpus the coverage and this the supplement it cannot reach):
    // once the checker is right, NO beni program can produce a malformed
    // table, so the only way to prove the wall stops one is to build one by
    // hand.
    //
    // What it pins is §7.2's promise that a caller/callee disagreement is
    // "a caught bug rather than a silent miscompile". Before the count, a
    // list that merely NESTED correctly passed: two slots for a
    // one-evidence callee emitted a three-argument call of a two-parameter
    // function — JavaScript RUNS that — which printed `NaN` and then
    // recursed forever, and zero slots for a two-evidence callee threw
    // `TypeError: $m$0 is not a function`. The build exited 0 both times.
    const evidence = [_]Dispatch.Evidence{
        .{ .quantified = 0, .var_name = .none, .method = @enumFromInt(0) },
    };
    // Declaration 0 takes one evidence parameter of its own; declaration 1
    // takes none. Nothing else about either is read.
    const decl_evidence = [_]Dispatch.Range{ .{ .start = 0, .len = 1 }, .empty };
    const table: Dispatch = .{ .decl_evidence = &decl_evidence, .evidence = &evidence };

    // `evidenceShapeOk` is a predicate over the table and reads
    // `in.dispatch` and nothing else, which is what makes a synthetic table
    // enough and the rest of the `Lowerer` unnecessary.
    var l: Lowerer = undefined;
    l.in.dispatch = &table;

    const constrained: Dispatch.Target = .{ .top = @enumFromInt(0) };
    const plain: Dispatch.Target = .{ .top = @enumFromInt(1) };
    const site = struct {
        fn at(index: u16, target: Dispatch.Target) Dispatch.Site {
            return .{ .inst = @enumFromInt(0), .evidence_index = index, .target = target };
        }
    }.at;

    // One slot for a one-evidence callee, and none for a callee with none:
    // the two shapes §8.2 describes.
    try testing.expect(l.evidenceShapeOk(&.{site(0, plain)}, 1));
    try testing.expect(l.evidenceShapeOk(&.{}, 0));
    // TOO LONG: nests perfectly, one top-level slot more than the callee
    // has parameters for.
    try testing.expect(!l.evidenceShapeOk(&.{ site(0, plain), site(1, plain) }, 1));
    try testing.expect(!l.evidenceShapeOk(&.{site(0, plain)}, 0));
    // TOO SHORT: the list runs out before the callee's parameters do.
    try testing.expect(!l.evidenceShapeOk(&.{site(0, plain)}, 2));
    try testing.expect(!l.evidenceShapeOk(&.{}, 1));
    // NESTING is what the count cannot be inferred from: a constrained
    // target consumes the slot after it (A.25), so these two sites are ONE
    // top-level slot — accepted as one, refused as two.
    try testing.expect(l.evidenceShapeOk(&.{ site(0, constrained), site(1, plain) }, 1));
    try testing.expect(!l.evidenceShapeOk(&.{ site(0, constrained), site(1, plain) }, 2));
    // A nested slot that is not there at all.
    try testing.expect(!l.evidenceShapeOk(&.{site(0, constrained)}, 1));
    // §8.2's other half, unchanged: neither `field` nor `err` can stand in
    // evidence position, whatever the count says.
    try testing.expect(!l.evidenceShapeOk(&.{site(0, .field)}, 1));
    try testing.expect(!l.evidenceShapeOk(&.{site(0, .err)}, 1));
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
