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
const Decision = @import("Decision.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const JsIr = @import("JsIr.zig");
const Reach = @import("Reach.zig");
const Types = @import("../check/Types.zig");

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
    /// (static-dispatch-spike.md §7). S4 and S5 lower from it; what S5
    /// cannot honour is still REFUSED rather than emitted wrongly.
    dispatch: *const Dispatch,
    /// The session's type table, read as a **name, declaration and
    /// derivability service** and as nothing else.
    ///
    /// `backend.md` §3 says the backend sees no types, and every DECISION
    /// about which function a call runs is still the checker's: this file
    /// reads targets and never a value's type. But §7.1 spells two of those
    /// targets with a `Types.TypeId` — `Shape.nominal` and `ext_derived` —
    /// and §8.5 spells the function they name `<Module>$<Type>$$<kind>`, so
    /// the emitter has to be able to turn an id into the type's NAME, its
    /// declaration (for the constructor table §9.4 walks) and its parameter
    /// count. `Types.Entry` is the only record that answers, and
    /// `dump --stage=dispatch` already takes it for the same reason
    /// (`src/dump/dispatch.zig:34`).
    ///
    /// **And two more fields than a name service needs.**
    /// `derivedBodyExists` reads `Entry.kind` and `Entry.equatable` to
    /// answer whether the module that owns an `ext_derived` target actually
    /// emitted a body for it — a `foreign type` has no constructors and so
    /// no module wrote one (A.55, A.60). After §5.2 no program can make
    /// that answer `false`, so what is left is the guard against a table
    /// the checker did not write. That is still a question about the TABLE
    /// and not about a value, but it is a judgement and not a lookup, and
    /// pretending otherwise in this comment hid it. §8.0 records it.
    ///
    /// Nothing below asks it a question about a VALUE's type, which is the
    /// ignorance §3 is about.
    types: *const Types,
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
    /// §9's survivor sets, for the WHOLE program: what this module lowers,
    /// exports and imports is restricted to them, and the debug self-check
    /// below reads the other modules' to prove that no reference leaves the
    /// set.
    ///
    /// `null` means "eliminate nothing", which is not a build mode —
    /// elimination is always on (`backend.md` §2) — but the state of the
    /// in-source tests below, which lower one module with no whole-program
    /// graph to walk.
    live: ?*const Reach.Result = null,
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
    // §9's derived functions and §9.1's primitive comparators, one pass
    // sorted by printed name text (§8.5), in front of the declarations
    // rather than behind them: a module-level constant whose initialiser is
    // a call runs at module evaluation time, so a `const` it names must
    // already be initialised (and the same temporal dead zone
    // `emissionOrder` exists for). It runs AFTER the declaration walk
    // because a primitive comparator is DISCOVERED, and BEFORE
    // `importStatements` because a derived body can name another module's.
    const synthesised = try l.synthesisedValues();
    const import_statements = try l.importStatements();

    var body: std.ArrayList(Node.Index) = .empty;
    try body.appendSlice(scratch, import_statements);
    try body.appendSlice(scratch, synthesised);
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
    /// How many `case` instructions of the function being lowered enclose
    /// the one being lowered now: the `<d>` of §7's `$j$<d>$<b>` and
    /// `$c$<d>` labels. It is reset at every function boundary, because a
    /// `break` cannot cross one and an inner function's labels are a fresh
    /// set — which is what keeps the names structural rather than a counter
    /// (CLAUDE.md rule 5).
    case_depth: u32 = 0,
    /// How deep the evidence walk of §8.2 is. The `parts` of a target nest
    /// (A.46) and the walk that reads them is recursive, so a poisoned
    /// table whose range pointed back at itself would recurse until the
    /// stack ran out. `dump/dispatch.zig` caps its own walk for the same
    /// reason; this one reports and stops.
    part_depth: u8 = 0,
    /// The instruction being lowered, for a diagnostic raised by something
    /// that has no instruction of its own — the synthesised references of
    /// §9.1, and `partEq`'s `err` arm. It is the INNERMOST instruction
    /// reached, not a span the reader chose, which is why only `internal`
    /// uses it.
    region: Inst.Index = @enumFromInt(0),

    /// One name this module has to import. `value` indexes the other
    /// module's interface; `base` is set instead for a SYNTHESISED name —
    /// a derived function (§8.5) is not an interface value, but it is
    /// exported from its module and imported through this same list.
    const Needed = struct {
        module: Graph.Index,
        value: u32 = no_value,
        base: Symbol.Optional = .none,

        const no_value = std.math.maxInt(u32);
    };

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

    /// `$in$<i>`: the loop slot of the i-th parameter of a function that
    /// has a tail self-call (`backend.md` §8), *i* counting evidence
    /// first. Positional and never a counter, so two nested loops both
    /// using `$in$0` are safe — neither ever reads the other's — and the
    /// name is a function of the source and not of thread timing
    /// (CLAUDE.md rule 5).
    fn inSlotName(l: *Lowerer, index: u32) !JsIr.NameIndex {
        var buf: [16]u8 = undefined;
        const spelled = std.fmt.bufPrint(&buf, "$in${d}", .{index}) catch unreachable;
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

    // ---- §9's survivor set ------------------------------------------------
    //
    // Three questions and one wall. The questions restrict what this module
    // lowers, exports and imports; the wall is a DEBUG check that nothing
    // which survived names something that did not, because over-elimination
    // is a `ReferenceError` at load or a wrong answer at a call, where
    // under-elimination is only bytes.

    fn liveDecl(l: *Lowerer, index: u32) bool {
        const r = l.in.live orelse return true;
        return r.decl(l.in.module, index);
    }

    fn liveDerived(l: *Lowerer, index: u32) bool {
        const r = l.in.live orelse return true;
        return r.derivedRow(l.in.module, index);
    }

    /// The wall. Compiled away outside a safety build (`runtime_safety` is
    /// comptime-known), and one bitset test where it is compiled in — the
    /// cheapest place to turn "the graph missed an edge" from a Node
    /// `ReferenceError` in somebody's program into a stopped build with the
    /// name in it.
    fn requireLive(l: *Lowerer, alive: bool, what: []const u8) !void {
        if (!std.debug.runtime_safety) return;
        if (l.in.live == null or alive) return;
        try l.report(
            .internal,
            l.region,
            \\I emitted a reference to `{s}`, which this build eliminated.
            \\
            \\`docs/design/backend.md` §9 decides what a build ships by walking a graph of
            \\top-level declarations, and every reference the code generator writes has to
            \\be an edge of that graph. This one is not, so the name would have been
            \\missing from the output and the program would have failed to load.
            \\
            \\That is a compiler bug — a missing edge, not a missing feature. Please report
            \\it with this program.
        ,
            .{what},
        );
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
    /// `refs` row — and so is every `top` INSIDE a site's evidence, because
    /// `{ k = Id 1 2 } == { k = Id 1 99 }` in a module-level constant hands
    /// `M$eq` to a derived function as a value (§9.2), and a value read
    /// before its `const` is initialised is the same dead-zone throw.
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
            // §5: the outer loop is restricted to the survivors, and it can
            // reach nothing else — every edge it walks (a `top_value` ref,
            // a site's `top` target, a `top` inside one's evidence) is also
            // a §9 reachability edge, so the survivors come out in the same
            // relative order they have today and the temporal dead zone
            // stays closed. `requireLive` is the proof, not this loop.
            if (!l.liveDecl(@intCast(root))) continue;
            if (state[root] != 0) continue;
            try stack.append(l.scratch, .{ .decl = @intCast(root), .next = 0, .tops = try l.siteTops(@intCast(root)) });
            state[root] = 1;
            while (stack.items.len != 0) {
                const frame = &stack.items[stack.items.len - 1];
                const d = l.bir.decls[frame.decl];
                const refs = l.bir.refs[d.refs_start..d.refs_end];
                // Found ONCE per frame, not once per edge: `siteTops` is a
                // binary search plus a walk of the run it finds, and a
                // declaration with s sites would otherwise pay for it s
                // times over.
                const tops = frame.tops;
                if (frame.next < refs.len + tops.len) {
                    const at = frame.next;
                    frame.next += 1;
                    const next: u32 = if (at < refs.len) blk: {
                        const ref = refs[at];
                        if (ref.kind != .top_value) continue;
                        break :blk ref.a;
                    } else tops[at - refs.len];
                    if (next >= count or state[next] != 0) continue;
                    state[next] = 1;
                    try stack.append(l.scratch, .{ .decl = next, .next = 0, .tops = try l.siteTops(next) });
                    continue;
                }
                state[frame.decl] = 2;
                order.appendAssumeCapacity(frame.decl);
                _ = stack.pop();
            }
        }
        return order.items;
    }

    const Frame = struct { decl: u32, next: usize, tops: []const u32 };

    /// Every declaration of this module that one declaration's dispatch
    /// sites reach: the sites' own targets and, recursively, the evidence
    /// they hand over. Flat, in site order, so `emissionOrder` walks it
    /// with one index like the `refs` run beside it.
    fn siteTops(l: *Lowerer, decl: u32) ![]const u32 {
        const range = l.declSiteRange(decl);
        var out: std.ArrayList(u32) = .empty;
        for (l.in.dispatch.sites[range.start..][0..range.len]) |site| {
            try l.collectTops(site.target, &out, 0);
        }
        return out.items;
    }

    fn collectTops(l: *Lowerer, target: Dispatch.Target, out: *std.ArrayList(u32), depth: u8) Allocator.Error!void {
        if (depth > 32) return; // a poisoned table cannot spin here
        switch (target) {
            .top => |use| try out.append(l.scratch, use.decl.int()),
            else => {},
        }
        for (l.in.dispatch.partsAt(target.partsOf())) |part| try l.collectTops(part, out, depth + 1);
    }

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
            // §8's narrow rule: a `lambda` that is the ENTIRE body of a
            // parameterless declaration inherits its name, because `f x = e`
            // and `f = \x -> e` emit byte-identical JavaScript today and two
            // spellings of one program must not differ in stack behaviour.
            // A lambda anywhere else never does.
            if (l.bir.instTag(body) == .lambda) {
                const ld = l.bir.instData(body);
                const lambda_params = l.bir.extraSlice(l.bir.subRange(@enumFromInt(ld.lhs)), Inst.Index);
                const lambda_record = try l.functionOrLoop(
                    n,
                    .{ .top = index },
                    0,
                    lambda_params,
                    @enumFromInt(ld.rhs),
                    p,
                );
                const lambda = try l.add(.arrow, p, @intFromEnum(lambda_record), Node.Data.unused);
                try l.constDecl(out, n, lambda, p);
                return;
            }
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
        const record = try l.functionOrLoop(n, .{ .top = index }, evidence, params, body, p);
        const arrow = try l.add(.arrow, p, @intFromEnum(record), Node.Data.unused);
        try l.constDecl(out, n, arrow, p);
    }

    fn exports(l: *Lowerer, out: *StmtList) !void {
        var names: std.ArrayList(JsIr.NameIndex) = .empty;
        // The derived methods of this module's NOMINAL types, first
        // because that is where they are emitted (§8.5). They are exported
        // whether or not anything here uses them: derivation is eager and
        // the module that declares the type is the only one that may write
        // the body, so every other module reaches it by import. A
        // structural shape has no owning module and each consumer emits its
        // own, so those stay local.
        //
        // **Including the rows of a type that is not `pub`**, which looks
        // like a leak and is not. `Solve.targetFor` reaches a nominal type
        // through the VALUE's type and never through a written name, so a
        // module that cannot spell `Wrapped` can still hold one — `type
        // Wrapped = Wrapped Int` with a `pub wrap : Int -> Wrapped` beside
        // it — and `Hidden.wrap 1 == Hidden.wrap 1` in that module is an
        // `ext_derived Hidden.Wrapped eq` whose function only `Hidden` may
        // write. Exporting on `is_pub` would make that build emit an import
        // of a name the declaring module kept to itself. The type stays
        // unnameable either way: what crosses is the method, not the type.
        //
        // **Each of the three sources is filtered by §9's survivor set**,
        // so an export list shrinks to exactly the surviving names it used
        // to hold (§5). It does NOT shrink to what someone imports: a `pub`
        // value that survives stays exported under its own name, because an
        // export costs the name once and a consumer-driven export list
        // would make one module's bytes depend on another's.
        for (l.in.dispatch.derived, 0..) |row, index| {
            if (row.shape != .nominal) continue;
            if (!l.liveDerived(@intCast(index))) continue;
            try names.append(l.scratch, try l.synthesisedName(try l.derivedBase(row.kind, row.shape)));
        }
        if (l.in.entry_decl) |index| {
            if (index < l.bir.decls.len and !l.bir.decls[index].is_pub and l.liveDecl(index)) {
                try names.append(l.scratch, try l.topName(index));
            }
        }
        for (l.bir.interface) |decl_index| {
            const d = l.bir.decl(decl_index);
            if (!d.kind.isValue()) continue;
            if (d.kind == .annotation_only) continue;
            if (d.kind == .value and d.body == .none) continue;
            if (!l.liveDecl(decl_index.int())) continue;
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
        for (l.bir.decls, 0..) |d, index| {
            if (d.kind != .foreign_value) continue;
            // §5: the one import leg that is not use-driven. Every other
            // `import` shrinks for free with the declaration that wanted
            // it; this loop walks `bir.decls` and would otherwise import
            // every `foreign` whether anything reached it or not.
            if (!l.liveDecl(@intCast(index))) continue;
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
                const n = try l.neededName(entry);
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

    /// Every cross-module VALUE reference goes through here — an
    /// `ext_value` instruction, an `ext` dispatch target, `coreValue`'s
    /// import path — which makes it §9's wall for leg 2.
    fn need(l: *Lowerer, module: Graph.Index, value: u32) !void {
        if (std.debug.runtime_safety) {
            if (l.in.live) |r| {
                try l.requireLive(r.extValue(module, value), l.externalText(module, value));
            }
        }
        try l.needName(.{ .module = module, .value = value });
    }

    /// The printed base of another module's interface value, for the wall's
    /// message. Empty when the interface is not available, which is a
    /// module that failed to lower and has its own diagnostic.
    fn externalText(l: *Lowerer, module: Graph.Index, value: u32) []const u8 {
        if (module.int() >= l.in.interfaces.len) return "";
        const iface = &l.in.interfaces[module.int()];
        if (value >= iface.values.len) return "";
        return l.text(iface.symbols[@intFromEnum(iface.values[value].name)]);
    }

    /// A derived function of another module (§8.5): named by its base text
    /// rather than by an interface index, because the declaring module
    /// SYNTHESISES it and no interface records it (A.47).
    fn needDerived(l: *Lowerer, module: Graph.Index, base: Symbol) !void {
        try l.needName(.{ .module = module, .base = base.toOptional() });
    }

    fn needName(l: *Lowerer, entry: Needed) !void {
        for (l.needed.items) |existing| {
            if (existing.module == entry.module and existing.value == entry.value and existing.base == entry.base) return;
        }
        try l.needed.append(l.scratch, entry);
    }

    /// The local (and imported) spelling of one needed name.
    fn neededName(l: *Lowerer, entry: Needed) !JsIr.NameIndex {
        if (entry.base.unwrap()) |base| {
            return l.name(.{
                .module = l.in.graph.moduleName(entry.module).toOptional(),
                .base = base,
                .tag = JsIr.Name.no_tag,
            });
        }
        return l.externalName(entry.module, entry.value);
    }

    // ---- Functions --------------------------------------------------------

    /// The `Func` record for `params` and `body`: what both an `arrow` and
    /// a `func_decl` carry, built once so a `let` binding can choose which
    /// of the two it becomes without lowering the body twice.
    fn functionOf(l: *Lowerer, evidence: u16, params: []const Inst.Index, body: Inst.Index) !JsIr.ExtraIndex {
        var names: std.ArrayList(JsIr.NameIndex) = .empty;
        var stmts: StmtList = .empty;
        // A new function is a new label scope (§7).
        const depth = l.case_depth;
        l.case_depth = 0;
        defer l.case_depth = depth;
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
        // §7 removes §8's gate on the statement form: a `case` in tail
        // position becomes statements whether or not the function loops, so
        // a function whose body is one returns from each arm instead of
        // assigning a `let $t$n` and returning that. The position of the
        // `return` is the body's own, which `tailStmts` reads from the
        // instruction — so this no longer takes one.
        try l.tailStmts(&stmts, body, null);
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

    // ---- Tail calls (backend.md §8) ---------------------------------------
    //
    // Direct self-recursion becomes `label: while (true)`, and §8 makes that
    // MANDATORY rather than an optimisation: no JavaScript engine reliably
    // eliminates a tail call, so a beni `foldl` over a list longer than a
    // few thousand cells would otherwise overflow the stack.
    //
    // A parameter is CARRIED when some tail self-call passes it anything
    // other than a reference to that same parameter. A carried parameter is
    // renamed to `$in$<i>` in the JavaScript parameter list and re-bound to
    // its ordinary name by a `const` at the top of the loop body; one that
    // is not carried keeps its name and gets neither slot nor copy.
    //
    // **There are no temporaries, and that is the load-bearing invariant.**
    // `$in$<i>` is written by the assignments and read by the prologue
    // `const` and nowhere else, so every argument expression is written
    // against the ordinary names, which hold this iteration's values and are
    // never assigned. The stores may therefore run in parameter order with
    // no `$temp$` anywhere and an argument swap is right by construction —
    // where Elm reassigns the parameters in place and needs one temporary
    // per argument per call site. The per-iteration `const` is also what
    // makes a closure built inside the loop capture THIS iteration's value:
    // a `while` body block gets a fresh declarative environment on every
    // evaluation, and in-place reassignment gives every closure the last
    // value instead (§8, "Closures, and the one way to get this wrong").

    /// The function being lowered as a loop: what a self-call has to name,
    /// and one slot per JavaScript parameter, evidence first (§8.1).
    const Loop = struct {
        /// The label, which is the function's own emitted name — input
        /// derived, no counter, and it cannot collide because labels are a
        /// separate namespace from bindings (§8).
        label: JsIr.NameIndex,
        self: Self,
        evidence: u16,
        slots: []Slot,

        /// Which reference, syntactically, names this function.
        const Self = union(enum) {
            /// A declaration of this module: the callee must be `top d`.
            top: u32,
            /// A `let` binding: the callee must be `local i`.
            local: u32,
        };

        const Slot = struct {
            /// The parameter's pattern; `.none` for an evidence parameter.
            pattern: Inst.OptionalIndex = .none,
            /// The local a `pat_var` pattern binds, else `no_local`.
            local: u32 = no_local,
            carried: bool = false,
            /// The name in the JavaScript parameter list: `$in$<i>` when
            /// carried, the ordinary name when not.
            param: JsIr.NameIndex = .none,
            /// The name the body reads. The prologue `const` binds it from
            /// `$in$<i>` when the slot is carried; `.none` for `_`, which
            /// nothing can read.
            body: JsIr.NameIndex = .none,
        };

        const no_local: u32 = std.math.maxInt(u32);
    };

    /// The `Func` record for a function that may loop: §8's shape when it
    /// has at least one tail self-call, and byte for byte what `functionOf`
    /// emits when it has none. `label` is the function's emitted name and
    /// `self` is the reference a self-call has to name.
    ///
    /// The analysis allocates no name and builds no node, so falling back
    /// leaves the emitted bytes — and the `fresh` counter behind them —
    /// exactly where they were.
    fn functionOrLoop(
        l: *Lowerer,
        label: JsIr.NameIndex,
        self: Loop.Self,
        evidence: u16,
        params: []const Inst.Index,
        body: Inst.Index,
        p: u32,
    ) !JsIr.ExtraIndex {
        const slots = try l.scratch.alloc(Loop.Slot, @as(usize, evidence) + params.len);
        for (slots[0..evidence]) |*slot| slot.* = .{};
        for (params, slots[evidence..]) |param, *slot| {
            slot.* = .{ .pattern = param.toOptional() };
            if (l.bir.instTag(param) == .pat_var) {
                slot.local = l.bir.instData(param).lhs;
            } else {
                // A parameter whose pattern is not a bare variable has no
                // name a call site could write, so no argument can be a
                // reference to it and §8's test makes it carried. `_` is
                // carried for the same reason: the argument is still
                // evaluated and still stored, because deciding that a beni
                // expression is dead is not this pass's job.
                slot.carried = true;
            }
        }
        var loop: Loop = .{ .label = label, .self = self, .evidence = evidence, .slots = slots };
        if (!l.markTails(body, &loop)) return l.functionOf(evidence, params, body);

        // A new function is a new label scope (§7).
        const depth = l.case_depth;
        l.case_depth = 0;
        defer l.case_depth = depth;

        var names: std.ArrayList(JsIr.NameIndex) = .empty;
        for (slots, 0..) |*slot, i| {
            const index: u32 = @intCast(i);
            slot.body = if (index < evidence)
                try l.evidenceName(@intCast(index))
            else if (slot.local != Loop.no_local)
                try l.localName(slot.local)
            else if (l.bir.instTag(slot.pattern.unwrap().?) == .pat_wild)
                .none
            else
                try l.fresh(l.well.param);
            slot.param = if (slot.carried) try l.inSlotName(index) else slot.body;
            try names.append(l.scratch, slot.param);
        }

        var loop_body: StmtList = .empty;
        // The prologue. One `const` per carried slot rather than one
        // comma-separated declaration: joining them is §9 item 5's variable
        // joining, a printer decision and M3c's, not this slice's.
        for (slots) |slot| {
            if (!slot.carried or slot.body == .none) continue;
            try l.constDecl(&loop_body, slot.body, try l.ident(slot.param, p), p);
        }
        // A parameter whose pattern is not a bare variable destructures
        // INSIDE the loop, because it reads this iteration's value (§8).
        for (slots[evidence..]) |slot| {
            const pattern = slot.pattern.unwrap().?;
            switch (l.bir.instTag(pattern)) {
                .pat_var, .pat_wild => {},
                else => try l.bindings(&loop_body, pattern, try l.ident(slot.body, l.pos(pattern))),
            }
        }
        try l.tailStmts(&loop_body, body, &loop);

        const range = try l.b.addRange(loop_body.items);
        const record = try l.b.addRecord(range);
        // Control leaves by `return` or by `continue`, so nothing follows
        // the loop and there is no `break` (§8).
        const while_node = try l.add(.while_true, p, @intFromEnum(label), @intFromEnum(record));
        return l.funcRecord(names.items, &.{while_node});
    }

    /// Walk the TAIL POSITIONS of `inst` — §8: the body itself, every branch
    /// body of a `case` in tail position (which covers `if` and `?`, both a
    /// `case` by the time the backend sees them), and the `in` body of a
    /// `let` in tail position, and nothing else — marking every slot a tail
    /// self-call passes something other than itself. Answers whether there
    /// was one at all.
    ///
    /// Nothing here descends into a lambda: that is a different function,
    /// and a self-call inside one is an ordinary call (§8's cases table).
    fn markTails(l: *Lowerer, inst: Inst.Index, loop: *Loop) bool {
        const d = l.bir.instData(inst);
        switch (l.bir.instTag(inst)) {
            .let => return l.markTails(@enumFromInt(d.rhs), loop),
            .case => {
                var found = false;
                for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index)) |branch| {
                    if (l.bir.instTag(branch) != .branch) continue;
                    if (l.markTails(@enumFromInt(l.bir.instData(branch).rhs), loop)) found = true;
                }
                return found;
            },
            .call => {
                if (!l.isSelfCall(inst, loop)) return false;
                l.markCarried(inst, loop);
                return true;
            },
            else => return false,
        }
    }

    /// Whether a `call` is a tail self-call: the callee is, syntactically,
    /// the reference that names the function being lowered, and the
    /// argument and evidence counts are the function's own.
    ///
    /// Both equalities hold by construction — every call is saturated
    /// (`language.md` §6.7) and the checker fixes evidence at every site —
    /// and are checked anyway, because a wrong loop is a wrong answer where
    /// a missing one is only a deep stack (§8).
    fn isSelfCall(l: *Lowerer, inst: Inst.Index, loop: *const Loop) bool {
        const d = l.bir.instData(inst);
        const callee: Inst.Index = @enumFromInt(d.lhs);
        const named = switch (loop.self) {
            .top => |decl| l.bir.instTag(callee) == .top and l.bir.instData(callee).lhs == decl,
            .local => |index| l.bir.instTag(callee) == .local and l.bir.instData(callee).lhs == index,
        };
        if (!named) return false;
        if (l.bir.subRange(@enumFromInt(d.rhs)).len() != loop.slots.len - loop.evidence) return false;
        return l.topLevelSites(l.sitesOf(inst)) == loop.evidence;
    }

    /// How many top-level evidence ARGUMENTS a site list holds: the same
    /// pre-order walk `evidenceArguments` makes, counting its roots.
    fn topLevelSites(l: *Lowerer, sites: []const Dispatch.Site) usize {
        var cursor: usize = 0;
        var count: usize = 0;
        while (cursor < sites.len) : (count += 1) l.skipEvidence(sites, &cursor);
        return count;
    }

    /// One top-level evidence argument and the sites its own evidence
    /// consumes underneath it — `evidenceValue`'s walk with nothing built.
    /// The cursor only ever advances, so the recursion is bounded by the
    /// length of the list.
    fn skipEvidence(l: *Lowerer, sites: []const Dispatch.Site, cursor: *usize) void {
        const target = sites[cursor.*].target;
        cursor.* += 1;
        switch (target) {
            .derived, .ext_derived => return,
            else => if (target.partsOf().len != 0) return,
        }
        const wanted = l.targetEvidence(target);
        var k: u16 = 0;
        while (k < wanted and cursor.* < sites.len) : (k += 1) l.skipEvidence(sites, cursor);
    }

    /// Mark the slots this tail self-call passes something other than
    /// themselves. Conservative by design: when in doubt, carried.
    ///
    /// **"Evidence is loop-invariant" is not a rule**, and stating it as one
    /// would be a miscompile (§8). Polymorphic recursion is typeable with an
    /// annotation, and the checker then writes a different evidence
    /// expression at the site rather than `$m$k` — so the same syntactic
    /// test carries the evidence parameter like any other.
    fn markCarried(l: *Lowerer, inst: Inst.Index, loop: *Loop) void {
        const sites = l.sitesOf(inst);
        var cursor: usize = 0;
        var k: u16 = 0;
        while (cursor < sites.len and k < loop.evidence) : (k += 1) {
            const target = sites[cursor].target;
            l.skipEvidence(sites, &cursor);
            const forwarded = switch (target) {
                .evidence => |index| index == k,
                else => false,
            };
            if (!forwarded) loop.slots[k].carried = true;
        }
        const d = l.bir.instData(inst);
        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
        for (args, loop.slots[loop.evidence..]) |arg, *slot| {
            if (slot.carried) continue;
            if (l.bir.instTag(arg) == .local and l.bir.instData(arg).lhs == slot.local) continue;
            slot.carried = true;
        }
    }

    /// Lower `inst` in TAIL position straight into a statement list — the
    /// second entry point beside `expr` that §8 needs, because `continue`
    /// cannot appear in a ternary or in an IIFE.
    ///
    /// §8 reached it only from inside a function that has a tail self-call,
    /// so that every `emit/` golden of that slice stayed byte-identical.
    /// **§7 removes that gate**: `loop` is `null` for a function that does
    /// not loop, and a `case` in tail position becomes statements either
    /// way, which is what deletes the `let $t$n` / assign / `return $t$n`
    /// triple from every function whose body is a `case`. `a ? b : c`
    /// survives wherever it is still correct, in `tailCase`.
    fn tailStmts(l: *Lowerer, out: *StmtList, inst: Inst.Index, loop: ?*const Loop) Allocator.Error!void {
        const d = l.bir.instData(inst);
        switch (l.bir.instTag(inst)) {
            .let => {
                try l.letBindings(out, l.bir.subRange(@enumFromInt(d.lhs)));
                return l.tailStmts(out, @enumFromInt(d.rhs), loop);
            },
            .case => return l.tailCase(out, inst, loop),
            .call => {
                if (loop) |lp| {
                    if (l.isSelfCall(inst, lp)) return l.tailJump(out, inst, lp);
                }
            },
            else => {},
        }
        const value = try l.expr(out, inst);
        try out.append(l.scratch, try l.returnStmt(value, l.pos(inst)));
    }

    /// A tail self-call: the argument expressions, the assignments to the
    /// carried slots in parameter order, and `continue <label>`. The
    /// `continue` is LABELLED and not bare, because §7's decision trees put
    /// a `switch` and a shared-branch loop between the jump and this one.
    fn tailJump(l: *Lowerer, out: *StmtList, inst: Inst.Index, loop: *const Loop) !void {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        l.region = inst;
        const evidence = try l.evidenceArguments(l.sitesOf(inst), p);
        const written = try l.exprList(out, l.bir.subRange(@enumFromInt(d.rhs)));
        for (loop.slots, 0..) |slot, i| {
            if (!slot.carried) continue;
            const value = if (i < evidence.len) evidence[i] else written[i - evidence.len];
            const target = try l.ident(slot.param, p);
            try out.append(l.scratch, try l.add(.assign_stmt, p, target.int(), value.int()));
        }
        try out.append(l.scratch, try l.add(.continue_stmt, p, @intFromEnum(loop.label), Node.Data.unused));
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

    /// Every reference to a declaration of THIS module goes through here —
    /// a `top` instruction, a `top` dispatch target, a `foreign_value`
    /// bound by the sibling import, `coreValue`'s self-module path — which
    /// is what makes it the one place §9's wall has to stand for leg 1 and
    /// leg 3.
    fn topName(l: *Lowerer, decl: u32) !JsIr.NameIndex {
        const base = l.bir.symbol(l.bir.decls[decl].name);
        try l.requireLive(l.liveDecl(decl), l.text(base));
        return l.name(.{
            .module = l.module_name.toOptional(),
            .base = base,
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
                const record = try l.functionOf(0, params, @enumFromInt(d.rhs));
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

    /// The dispatch sites of one instruction, in the pre-order of §7.2's
    /// evidence tree. `dispatch.sites` is grouped by `inst` (§7.1), so
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

    /// How many further SITES a target consumes: the evidence of a value
    /// with a scheme of its own, which §7.2 numbers into the same flat list
    /// (§8.2, A.25). It is not `ownEvidence` — a derived function takes
    /// evidence too, and carries it on the target instead — and the
    /// difference is what `evidenceShapeOk` measures the site list against.
    fn targetEvidence(l: *Lowerer, target: Dispatch.Target) u16 {
        return switch (target) {
            .top => |use| @intCast(l.in.dispatch.declEvidence(use.decl.int()).len),
            .ext => |e| l.externalEvidence(e.module, @intFromEnum(e.value)),
            // A primitive comparator and an evidence parameter are already
            // closures of the right arity; a `derived` or `ext_derived`
            // target takes its evidence from its own `parts` range and
            // consumes no site at all (A.46).
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
            .top => |use| l.bir.decls[use.decl.int()].params,
            .ext => |e| l.externalArity(e.module, @intFromEnum(e.value)),
            // A derived `eq` or `compare` is binary: the two values being
            // compared, after whatever evidence it takes (§9).
            .derived, .ext_derived => 2,
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
            .top => |use| blk: {
                std.debug.assert(use.decl.int() < l.bir.decls.len);
                break :blk try l.ident(try l.topName(use.decl.int()), p);
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

    /// The hidden leading arguments of one instruction (§8.2), in the
    /// order the site list is in.
    ///
    /// The list is FLAT and the structure is a tree: a target that takes
    /// evidence of its own consumes the slots that follow it, which is the
    /// eta-expansion of A.25. So the walk is a pre-order over a cursor and
    /// not an index lookup — the ORDER shapes the slots and the counts
    /// measure them, and no index but the callee's own 0 is ever read.
    /// `Dispatch.finish` is what puts the list in that order, which the
    /// numbering alone does not give (A.68).
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
        // A target that carries its own `parts` is a leaf HERE and a tree
        // of its own underneath: a derived function always (A.46), and a
        // constrained `top`/`ext` in a part position since §7.1's
        // amendment (A.64). Either way it consumes no further site.
        switch (target) {
            .derived, .ext_derived => return l.derivedValue(target, p),
            else => if (target.partsOf().len != 0) {
                // **A `top`/`ext` target with parts, on a SITE.** The
                // checker fills those parts in `targetFor`, and `targetFor`
                // is reached two ways, not one: from inside a parts tree
                // (`constrainedParts`, depth > 0), and from `finishDerived`
                // at depth 0 (`Solve.zig`'s "receiver's own derived
                // target"), whose answer goes straight onto a site. The
                // depth-0 route cannot produce this shape today —
                // `methodOnApp` answers a nominal type's own module rule
                // and the imported-value rule BEFORE it derives, so by the
                // time `finishDerived` runs, `appTarget`'s `top` and `ext`
                // arms cannot match — but that is a fact about the ORDER of
                // two tables, not an invariant of the parts range, so this
                // stays handled.
                //
                // Handled by REFUSING, and that is the change: the kind of
                // the method a slot answers is what an `err` part inside it
                // has to be answered by (A.67), and a site carries no kind
                // — `derivedTargetKind` says `.eq` for a `top` or an `ext`
                // because it has nothing else to say. Guessing `.eq` here
                // would put `Basics.eq` into an `Order` slot exactly as
                // `derivedValue` used to. The slot's own method name is
                // recoverable — it is the callee's `where` clause, in
                // §7.2's order — and threading it through this walk is what
                // this arm needs the day it becomes reachable.
                try l.reportDispatchBug(l.region, parts_on_site_target);
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
        }
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

    // ---- Derived functions (static-dispatch-spike.md §9) ------------------
    //
    // A well-known method the checker resolved to a SHAPE rather than to a
    // value. The function is generated here, against the representation of
    // `backend.md` §4 and the `parts` contract of §9. S5 emits `eq`; the
    // `compare` half is S6's, so its rows are skipped and a site that names
    // one is still refused.
    //
    // Two things vary and the table keeps them apart (A.46): a `Derived`
    // ROW is the function — keyed on its shape, one evidence parameter per
    // field, element or type parameter — and a `derived` TARGET is one USE
    // of it, carrying the evidence that use hands over. So one
    // `eq$r$x$y` serves `{ x : Int, y : Int }` and `{ x : Id, y : String }`
    // alike, and what tells them apart is the two arguments each use passes.

    /// One module-level `const` this file SYNTHESISES rather than lowers: a
    /// derived function (§9) or a primitive comparator (§9.1). It carries
    /// its printed base text because §8.5 orders the pass by NAME and not
    /// by the order the two were discovered in — request order is
    /// deterministic today but not obviously so, and CLAUDE.md rule 5 asks
    /// for an order a reader can check.
    const Synth = struct {
        base: []const u8,
        node: Node.Index,

        fn before(_: void, a: Synth, b: Synth) bool {
            return std.mem.lessThan(u8, a.base, b.base);
        }
    };

    /// §8.5's separate pass, emitted in front of the declaration loop:
    /// every `$order` table first, then every function, each run sorted by
    /// printed name text. Ordering WITHIN the function run never matters —
    /// every derived function is an arrow, so a reference from one to
    /// another is resolved when it is called — and the `$order` tables are
    /// the one exception, being object literals the `compare` that indexes
    /// them reads. S5 emits no `$order` table because it emits no
    /// `compare`; the run is where S6 puts them.
    fn synthesisedValues(l: *Lowerer) ![]const Node.Index {
        var tables: std.ArrayList(Synth) = .empty;
        var list: std.ArrayList(Synth) = .empty;
        // The derived functions FIRST, before the comparators are built:
        // building one can need a primitive comparator as a value (§9.1),
        // and `needs` has to be complete before `eqPrimDecl` and friends
        // are asked for.
        // A derived function has no instruction of its own, so a
        // diagnostic raised while building one has no span the reader
        // chose. `nominalArrow` moves this to the type's declaration;
        // resetting it here keeps a leftover from the declaration pass out
        // of the message.
        l.region = @enumFromInt(0);
        for (l.in.dispatch.derived, 0..) |row, index| {
            // §5: only the surviving rows, and the `$$order` table goes
            // with its own `compare` because it is built inside this
            // iteration and nowhere else.
            if (!l.liveDerived(@intCast(index))) continue;
            const base = try l.derivedBase(row.kind, row.shape);
            const arrow = (try l.derivedArrow(row)) orelse continue;
            const bound = try l.synthesisedName(base);
            try list.append(l.scratch, .{
                .base = base,
                .node = try l.add(.const_decl, Node.no_pos, @intFromEnum(bound), arrow.int()),
            });
            // The `$order` table of §9.4 goes in the OTHER run, and only
            // after its function was written: it is a plain object literal
            // and not an arrow, so unlike every function here it has to
            // precede the `compare` that indexes it (§8.5).
            if (try l.orderTable(row)) |table| try tables.append(l.scratch, table);
        }
        if (l.needs.compare_char) try list.append(l.scratch, .{ .base = "compare$char", .node = try l.compareCharDecl() });
        if (l.needs.compare_prim) try list.append(l.scratch, .{ .base = "compare$prim", .node = try l.comparePrimDecl() });
        if (l.needs.eq_prim) try list.append(l.scratch, .{ .base = "eq$prim", .node = try l.eqPrimDecl() });
        std.mem.sort(Synth, tables.items, {}, Synth.before);
        std.mem.sort(Synth, list.items, {}, Synth.before);
        const out = try l.scratch.alloc(Node.Index, tables.items.len + list.items.len);
        for (tables.items, out[0..tables.items.len]) |synth, *slot| slot.* = synth.node;
        for (list.items, out[tables.items.len..]) |synth, *slot| slot.* = synth.node;
        return out;
    }

    /// §9.4's tag-order table, `const <M>$<T>$$order = { A: 0, B: 1 };` —
    /// the one thing that makes `compare` follow DECLARATION order, since
    /// the tags themselves are strings and `"EQ" < "GT" < "LT"` is not
    /// `LT < EQ < GT`.
    ///
    /// Only for a nominal `compare` of two or more constructors: a
    /// one-constructor type has nothing to disagree about (§9.4) and a
    /// structural shape has no tags at all.
    ///
    /// **The malformed-table case is `nominalArrow`'s to report, not this
    /// one's.** A `derived` row whose nominal type another module declares
    /// is a bug in the table (A.47), and `null` here would be a `compare`
    /// body emitted beside no `$$order` object — `M$T$$order[x]` against an
    /// undefined name, a `ReferenceError` after a build that exited 0.
    /// What makes the silence safe is an ORDERING in `synthesisedValues`:
    /// `derivedArrow` runs for the row first and `orelse continue` skips
    /// the rest of the iteration, so a row this would refuse never reaches
    /// it — `nominalArrow` has already raised `derived_not_declared_here`
    /// on exactly the same test, and the build emits nothing. Call this
    /// without `derivedArrow` in front of it, or make that `orelse` keep
    /// going, and it needs the report itself.
    fn orderTable(l: *Lowerer, row: Dispatch.Derived) !?Synth {
        if (row.kind != .compare) return null;
        const id = switch (row.shape) {
            .nominal => |id| id,
            else => return null,
        };
        const entry = l.in.types.entry(id);
        if (entry.module != l.in.module or entry.decl.int() >= l.bir.decls.len) return null;
        const ctors = l.bir.declCtors(l.bir.decls[entry.decl.int()]);
        if (ctors.len < 2) return null;
        const p = Node.no_pos;
        var properties: std.ArrayList(Node.Index) = .empty;
        for (ctors, 0..) |ctor, i| {
            const index = try std.fmt.allocPrint(l.scratch, "{d}", .{i});
            try properties.append(l.scratch, try l.property(l.bir.symbol(ctor.name), try l.numberNode(index, p), p));
        }
        const base = try l.orderBase(id);
        const bound = try l.synthesisedName(base);
        const value = try l.object(properties.items, p);
        return .{
            .base = base,
            .node = try l.add(.const_decl, Node.no_pos, @intFromEnum(bound), value.int()),
        };
    }

    /// `<T>$$order`, the same double separator §8.5 gives `<T>$$compare`
    /// and for the same reason (A.61).
    fn orderBase(l: *Lowerer, id: Dispatch.TypeId) ![]const u8 {
        return std.fmt.allocPrint(l.scratch, "{s}$$order", .{l.text(l.in.types.entry(id).name)});
    }

    /// `<T>$$order[subject]` — the tag's rank.
    fn orderLookup(l: *Lowerer, id: Dispatch.TypeId, subject: Node.Index, p: u32) !Node.Index {
        const table = try l.ident(try l.synthesisedName(try l.orderBase(id)), p);
        return l.add(.index_get, p, table.int(), subject.int());
    }

    /// §8.5's names: `<Type>$$eq` for a nominal type, `eq$r$<f1>$<f2>$…`
    /// for a record shape, `eq$t<n>` for a tuple and `eq$unit` for `()`.
    /// The same strings §7.3 prints a shape as, with the kind in front —
    /// which is what makes the sort above readable and what keeps two
    /// shapes with the same field names from ever being two functions.
    ///
    /// **The nominal base takes a DOUBLE separator**, and that is the whole
    /// of why it cannot collide. A printed name is `<module path with dots
    /// as `$`>$<base>`, so module `Shapes` with a `pub type Box` and the
    /// submodule `Shapes.Box` with a `pub eq` would both spell
    /// `Shapes$Box$eq` and the consumer that imports both gets
    /// `SyntaxError: Identifier 'Shapes$Box$eq' has already been declared`.
    /// `Shapes$Box$$eq` is a name no module path can reach: a beni
    /// identifier holds no `$` and a module path has no empty segment, so
    /// the empty one between the two `$` is unspellable. The structural
    /// bases need no such guard — they are lower-case, and a beni module
    /// segment is upper-case.
    fn derivedBase(l: *Lowerer, kind: Dispatch.Derived.Kind, shape: Dispatch.Shape) ![]const u8 {
        switch (shape) {
            .nominal => |id| return std.fmt.allocPrint(l.scratch, "{s}$${s}", .{
                l.text(l.in.types.entry(id).name),
                @tagName(kind),
            }),
            .record => |names| {
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(l.scratch, @tagName(kind));
                try out.appendSlice(l.scratch, "$r");
                for (l.in.dispatch.shapeNames(names)) |symbol| {
                    try out.append(l.scratch, '$');
                    try out.appendSlice(l.scratch, l.text(symbol));
                }
                return out.items;
            },
            .tuple => |arity| return std.fmt.allocPrint(l.scratch, "{s}$t{d}", .{ @tagName(kind), arity }),
            .unit => return std.fmt.allocPrint(l.scratch, "{s}$unit", .{@tagName(kind)}),
        }
    }

    /// The arrow of one derived method, or `null` when the body could not
    /// be written and a diagnostic has been reported.
    ///
    /// The evidence parameters come first and are the function's OWN
    /// (§9.2–§9.4): inside a derived body `$m$k` is the k-th element,
    /// field or type parameter, never the enclosing declaration's — a
    /// derived function has no enclosing declaration.
    ///
    /// The two kinds share every parameter list and differ only in what a
    /// position becomes: `eq` conjoins its positions, `compare` is
    /// LEXICOGRAPHIC and therefore a statement sequence with an early
    /// return (§9.2, §9.3).
    fn derivedArrow(l: *Lowerer, row: Dispatch.Derived) !?Node.Index {
        const p = Node.no_pos;
        const x, const y = try l.operandNames();
        var params: std.ArrayList(JsIr.NameIndex) = .empty;
        var k: u16 = 0;
        while (k < row.evidence_count) : (k += 1) try params.append(l.scratch, try l.evidenceName(k));
        switch (row.shape) {
            // §9.3: `(x, y) => true` / `(x, y) => "EQ"`. `()` is `null` at
            // runtime, so the two operands hold the same value and there is
            // nothing to test.
            .unit => {
                try params.appendSlice(l.scratch, &[_]JsIr.NameIndex{ x, y });
                return try l.emptyArrow(row.kind, params.items, p);
            },
            // §9.2: one evidence parameter per field, fields in name-text
            // order, applied to the two values' fields position by
            // position. The empty record derives `() => true` and
            // `() => "EQ"`, which is §9.2's own spelling: there is no field
            // to read and so no operand to name.
            .record => |names| {
                const fields = l.in.dispatch.shapeNames(names);
                if (fields.len == 0) return try l.emptyArrow(row.kind, params.items, p);
                try params.appendSlice(l.scratch, &[_]JsIr.NameIndex{ x, y });
                return l.structuralArrow(row.kind, params.items, x, y, fields, p);
            },
            // §9.3: the same, over the slot names `a`, `b`, `c`… of
            // `backend.md` §4. Keyed on the arity alone, so `( Int, Int )`
            // and `( String, String )` share one function (A.46).
            .tuple => |arity| {
                if (arity == 0) return try l.emptyArrow(row.kind, params.items, p);
                try params.appendSlice(l.scratch, &[_]JsIr.NameIndex{ x, y });
                const slots = try l.scratch.alloc(Symbol, arity);
                for (slots, 0..) |*slot, i| slot.* = try l.slotName(@intCast(i));
                return l.structuralArrow(row.kind, params.items, x, y, slots, p);
            },
            .nominal => |id| {
                try params.appendSlice(l.scratch, &[_]JsIr.NameIndex{ x, y });
                return l.nominalArrow(row, id, params.items, x, y, p);
            },
        }
    }

    /// `(params…) => true` / `(params…) => "EQ"` — the empty shapes of
    /// §9.2 and §9.3, and the arm of a nullary constructor.
    fn emptyArrow(l: *Lowerer, kind: Dispatch.Derived.Kind, params: []const JsIr.NameIndex, p: u32) !Node.Index {
        return l.returnArrow(params, try l.emptyValue(kind, p), p);
    }

    fn emptyValue(l: *Lowerer, kind: Dispatch.Derived.Kind, p: u32) !Node.Index {
        return switch (kind) {
            .eq => l.add(.true_lit, p, Node.Data.unused, Node.Data.unused),
            .compare => l.stringNode("EQ", p),
        };
    }

    /// A record or a tuple (§9.2, §9.3): position `i` is answered by the
    /// function's own `$m$i`, and the two kinds combine those answers
    /// differently.
    fn structuralArrow(
        l: *Lowerer,
        kind: Dispatch.Derived.Kind,
        params: []const JsIr.NameIndex,
        x: JsIr.NameIndex,
        y: JsIr.NameIndex,
        slots: []const Symbol,
        p: u32,
    ) !?Node.Index {
        if (kind == .eq) {
            var value: ?Node.Index = null;
            for (slots, 0..) |slot, i| {
                const left = try l.member(try l.ident(x, p), slot, p);
                const right = try l.member(try l.ident(y, p), slot, p);
                value = try l.conjoin(value, try l.evidenceCall(@intCast(i), left, right, p), p);
            }
            return try l.returnArrow(params, value.?, p);
        }
        var stmts: StmtList = .empty;
        var counter: u32 = 0;
        for (slots, 0..) |slot, i| {
            const left = try l.member(try l.ident(x, p), slot, p);
            const right = try l.member(try l.ident(y, p), slot, p);
            const one = try l.evidenceCall(@intCast(i), left, right, p);
            try l.lexicographic(&stmts, one, i + 1 == slots.len, &counter, p);
        }
        return try l.arrowOf(params, stmts.items, p);
    }

    /// One position of a LEXICOGRAPHIC comparison (§9.2): the last is
    /// returned outright, and every earlier one is bound to a `const` and
    /// returned unless it is `"EQ"`.
    ///
    /// The `const` is numbered by a counter the whole function shares, and
    /// not per block, because the printer gives a `switch` arm no braces of
    /// its own (`backend.md` §7's shape): two arms of one `switch` are one
    /// block scope in JavaScript, so `const $o$0` in each would be
    /// `SyntaxError: Identifier '$o$0' has already been declared`. The
    /// spec's listings show the arms braced; the names here are what makes
    /// the same program legal without them.
    fn lexicographic(
        l: *Lowerer,
        out: *StmtList,
        value: Node.Index,
        last: bool,
        counter: *u32,
        p: u32,
    ) !void {
        if (last) {
            try out.append(l.scratch, try l.returnStmt(value, p));
            return;
        }
        const bound = try l.orderName(counter.*);
        counter.* += 1;
        try l.constDecl(out, bound, value, p);
        const differs = try l.binary(.strict_ne, try l.ident(bound, p), try l.stringNode("EQ", p), p);
        const then = [_]Node.Index{try l.returnStmt(try l.ident(bound, p), p)};
        try l.ifStatement(out, differs, &then, p);
    }

    /// `$o$<i>`: one intermediate `Order` inside a derived `compare`.
    fn orderName(l: *Lowerer, index: u32) !JsIr.NameIndex {
        var buf: [16]u8 = undefined;
        const spelled = std.fmt.bufPrint(&buf, "$o${d}", .{index}) catch unreachable;
        const base = try l.interner.getOrPut(l.gpa, spelled);
        return l.name(.{ .module = .none, .base = base, .tag = JsIr.Name.no_tag });
    }

    fn returnArrow(l: *Lowerer, params: []const JsIr.NameIndex, value: Node.Index, p: u32) !Node.Index {
        const stmts = [_]Node.Index{try l.returnStmt(value, p)};
        return l.arrowOf(params, &stmts, p);
    }

    /// `$m$k(left, right)` — the derived function's own k-th evidence
    /// parameter applied to one position.
    fn evidenceCall(l: *Lowerer, k: u16, left: Node.Index, right: Node.Index, p: u32) !Node.Index {
        return l.call(try l.ident(try l.evidenceName(k), p), &.{ left, right }, p);
    }

    /// `a && b`, or `b` when there is no `a` yet.
    fn conjoin(l: *Lowerer, left: ?Node.Index, right: Node.Index, p: u32) !Node.Index {
        const first = left orelse return right;
        return l.binary(.logical_and, first, right, p);
    }

    fn condOf(l: *Lowerer, test_expr: Node.Index, consequent: Node.Index, alternate: Node.Index, p: u32) !Node.Index {
        const record = try l.b.addRecord(JsIr.Cond{ .consequent = consequent, .alternate = alternate });
        return l.add(.cond, p, test_expr.int(), @intFromEnum(record));
    }

    /// §9.4's nominal body: the tag test, then a `switch` whose last
    /// constructor is the `default` arm.
    ///
    /// The parts are the type's constructor arguments in DECLARATION order,
    /// arguments left to right, so the walk keeps one cursor over them and
    /// never indexes by constructor.
    fn nominalArrow(
        l: *Lowerer,
        row: Dispatch.Derived,
        id: Dispatch.TypeId,
        params: []const JsIr.NameIndex,
        x: JsIr.NameIndex,
        y: JsIr.NameIndex,
        p: u32,
    ) !?Node.Index {
        const entry = l.in.types.entry(id);
        // A `derived` row is exactly what THIS module emits (A.47), so its
        // nominal shape names a type declared here. Anything else is a
        // malformed table, and emitting a body over another module's
        // constructors would be a `pub opaque type`'s insides in the wrong
        // file.
        if (entry.module != l.in.module or entry.decl.int() >= l.bir.decls.len) {
            try l.reportDispatchBug(@enumFromInt(0), derived_not_declared_here);
            return null;
        }
        const d = l.bir.decls[entry.decl.int()];
        const region = d.inst_start;
        l.region = region;
        const ctors = l.bir.declCtors(d);
        const parts = l.in.dispatch.partsAt(row.parts);

        var widest: u32 = 0;
        for (ctors) |c| widest = @max(widest, Bir.SubRange.len(.{ .start = c.args_start, .end = c.args_end }));
        // An all-nullary type is a BARE TAG STRING (`backend.md` §4), so
        // `eq` is `===` and there is nothing to walk (§9.4, A.18). The
        // checker gives a use `primitive strict_eq` directly; the row is
        // still emitted, because §8.5 derives every declared nominal type
        // eagerly and another module may name it as evidence.
        if (ctors.len == 0 or widest == 0) {
            if (row.kind == .eq) {
                return try l.returnArrow(params, try l.binary(.strict_eq, try l.ident(x, p), try l.ident(y, p), p), p);
            }
            // `compare` on the same shape cannot be `<`: the tags are
            // strings and alphabetic order is not declaration order, so it
            // reads the `$order` table (§9.4). With fewer than two
            // constructors there is no table and every value is the same
            // one.
            if (ctors.len < 2) return try l.returnArrow(params, try l.stringNode("EQ", p), p);
            var stmts: StmtList = .empty;
            const a = try l.name(.{ .module = .none, .base = l.well.cp_left, .tag = JsIr.Name.no_tag });
            const b = try l.name(.{ .module = .none, .base = l.well.cp_right, .tag = JsIr.Name.no_tag });
            try l.constDecl(&stmts, a, try l.orderLookup(id, try l.ident(x, p), p), p);
            try l.constDecl(&stmts, b, try l.orderLookup(id, try l.ident(y, p), p), p);
            const lt = try l.condOf(
                try l.binary(.lt, try l.ident(a, p), try l.ident(b, p), p),
                try l.stringNode("LT", p),
                try l.stringNode("GT", p),
                p,
            );
            const body = try l.condOf(
                try l.binary(.strict_eq, try l.ident(a, p), try l.ident(b, p), p),
                try l.stringNode("EQ", p),
                lt,
                p,
            );
            try stmts.append(l.scratch, try l.returnStmt(body, p));
            return try l.arrowOf(params, stmts.items, p);
        }

        var cursor: usize = 0;
        var counter: u32 = 0;
        var arms: std.ArrayList(Node.Index) = .empty;
        var stmts: StmtList = .empty;
        // A one-constructor type emits no tag test: there is nothing to
        // disagree about (§9.4).
        if (ctors.len > 1) {
            const tag_left = try l.member(try l.ident(x, p), l.well.tag, p);
            const tag_right = try l.member(try l.ident(y, p), l.well.tag, p);
            const differs = try l.binary(.strict_ne, tag_left, tag_right, p);
            // Two different constructors are ordered by the DECLARATION
            // order the `$order` table records, and never by their tags.
            const answer = switch (row.kind) {
                .eq => try l.add(.false_lit, p, Node.Data.unused, Node.Data.unused),
                .compare => try l.condOf(
                    try l.binary(
                        .lt,
                        try l.orderLookup(id, tag_left, p),
                        try l.orderLookup(id, tag_right, p),
                        p,
                    ),
                    try l.stringNode("LT", p),
                    try l.stringNode("GT", p),
                    p,
                ),
            };
            const then = [_]Node.Index{try l.returnStmt(answer, p)};
            try l.ifStatement(&stmts, differs, &then, p);
        }
        for (ctors, 0..) |ctor, i| {
            const arity = Bir.SubRange.len(.{ .start = ctor.args_start, .end = ctor.args_end });
            var body: StmtList = .empty;
            var value: ?Node.Index = null;
            var arg: u32 = 0;
            while (arg < arity) : (arg += 1) {
                if (cursor >= parts.len) {
                    try l.reportDispatchBug(region, derived_parts_short);
                    return null;
                }
                const part = parts[cursor];
                cursor += 1;
                const slot = try l.slotName(arg);
                const left = try l.member(try l.ident(x, p), slot, p);
                const right = try l.member(try l.ident(y, p), slot, p);
                switch (row.kind) {
                    .eq => {
                        const one = (try l.partEq(part, left, right, region, p)) orelse return null;
                        value = try l.conjoin(value, one, p);
                    },
                    .compare => {
                        const one = (try l.partCompare(&body, part, left, right, region, p)) orelse return null;
                        try l.lexicographic(&body, one, arg + 1 == arity, &counter, p);
                    },
                }
            }
            // A padded nullary constructor carries only `null`s, and
            // padding slots are NOT compared (§9.4, A.12): one slot can
            // hold a different type in a different constructor, and a
            // part's target is per POSITION and not per slot.
            if (arity == 0) {
                try body.append(l.scratch, try l.returnStmt(try l.emptyValue(row.kind, p), p));
            } else if (row.kind == .eq) {
                try body.append(l.scratch, try l.returnStmt(value.?, p));
            }
            if (ctors.len == 1) return try l.arrowOf(params, body.items, p);
            const body_range = try l.b.addRange(body.items);
            const record = try l.b.addRecord(body_range);
            // The LAST constructor is the `default` arm and gets no `case`:
            // a well-typed match needs no default (`backend.md` §7) and
            // `x.$` has already been proved equal to `y.$`.
            const test_expr: Node.OptionalIndex = if (i + 1 == ctors.len)
                .none
            else
                (try l.stringNode(l.text(l.bir.symbol(ctor.name)), p)).toOptional();
            try arms.append(l.scratch, try l.add(.switch_case, p, @intFromEnum(test_expr), @intFromEnum(record)));
        }
        const arm_range = try l.b.addRange(arms.items);
        const arms_record = try l.b.addRecord(arm_range);
        const discriminant = try l.member(try l.ident(x, p), l.well.tag, p);
        try stmts.append(l.scratch, try l.add(.switch_stmt, p, discriminant.int(), @intFromEnum(arms_record)));
        return try l.arrowOf(params, stmts.items, p);
    }

    fn ifStatement(l: *Lowerer, out: *StmtList, condition: Node.Index, then: []const Node.Index, p: u32) !void {
        const then_range = try l.b.addRange(then);
        const else_range = try l.b.addRange(&[_]Node.Index{});
        const record = try l.b.addRecord(JsIr.If{
            .then_start = then_range.start,
            .then_end = then_range.end,
            .else_start = else_range.start,
            .else_end = else_range.end,
        });
        try out.append(l.scratch, try l.add(.if_stmt, p, condition.int(), @intFromEnum(record)));
    }

    /// `EQ(l, r)` for one BODY position (§9's parts table): a comparison of
    /// two concrete expressions, so a `primitive` part is the JavaScript
    /// operator itself and not the comparator of §9.1 — that is the
    /// difference from §8.2, where the same target is in value position and
    /// must be a function.
    fn partEq(
        l: *Lowerer,
        part: Dispatch.Target,
        left: Node.Index,
        right: Node.Index,
        region: Inst.Index,
        p: u32,
    ) !?Node.Index {
        switch (part) {
            .primitive => |prim| {
                // `eq` has one primitive answer and the three ordering ones
                // belong to `compare`; meeting one here is a table that
                // crossed its two kinds.
                if (prim != .strict_eq) {
                    try l.reportDispatchBug(region, derived_wrong_primitive);
                    return null;
                }
                return try l.binary(.strict_eq, left, right, p);
            },
            .evidence => |k| return try l.evidenceCall(k, left, right, p),
            .top, .ext => return l.namedPartCall(part, .eq, left, right, region, p),
            // The checker could not name a function for this position: a
            // slot nothing ever inhabits, or a `number` still unresolved at
            // generalisation whose `eq` is `===` whichever of `Int` and
            // `Float` it settles on. `Basics.eq` IS that answer, and the
            // one the S4 shim gave the whole comparison.
            //
            // INVARIANT, and it is the CHECKER's to hold: `err` means
            // exactly that and nothing else. The moment the checker writes
            // `err` for a position it could not resolve for some OTHER
            // reason — a user's own method it failed to find, say — this
            // line silently answers the wrong `Bool`. What pins it is
            // `tests/corpus/dispatch/ErrParts`, which shows every `err` a
            // clean program makes.
            .err => return try l.call(try l.coreValue(.Basics, .eq, p), &.{ left, right }, p),
            .derived, .ext_derived => {
                if (!l.derivedBodyExists(part)) {
                    try l.reportDispatchBug(region, derived_body_missing);
                    return null;
                }
                return try l.derivedPartCall(part, .eq, left, right, p);
            },
            .field => {
                try l.reportDispatchBug(region, field_inside_derived);
                return null;
            },
        }
    }

    /// `CMP(l, r)` for one BODY position (§9's parts table), the `compare`
    /// column of the same row.
    ///
    /// It takes a statement list and `partEq` does not, because one row
    /// needs it: `primitive char_compare` is a comparison of CODE POINTS,
    /// and reading each operand's once means binding it (§8.3's `CP(e)`).
    /// The two consts land in whatever block this position is in — the
    /// function's own, or one `switch` arm's — ahead of the `const` the
    /// lexicographic sequence then binds the `Order` to.
    fn partCompare(
        l: *Lowerer,
        out: *StmtList,
        part: Dispatch.Target,
        left: Node.Index,
        right: Node.Index,
        region: Inst.Index,
        p: u32,
    ) !?Node.Index {
        switch (part) {
            .primitive => |prim| switch (prim) {
                // `strict_eq` is `eq`'s one answer and has no ordering
                // meaning at all; meeting it here is a table that crossed
                // its two kinds.
                .strict_eq => {
                    try l.reportDispatchBug(region, derived_wrong_primitive);
                    return null;
                },
                .num_compare => return try l.orderOf(left, right, p),
                .char_compare => {
                    // The CODE POINTS are bound, not the operands: an
                    // `Order` reads each of them twice (§9.1's own
                    // `compare$char` is this function inlined), so binding
                    // the operand alone would still call `codePointAt`
                    // four times.
                    const a = try l.bindSubject(out, try l.codePointCall(left, p), p);
                    const b = try l.bindSubject(out, try l.codePointCall(right, p), p);
                    return try l.orderOf(a, b, p);
                },
                // Never `<`: `core/String.js`'s `compare` is Unicode scalar
                // order and `<` is UTF-16 code-unit order (§3.2, A.26).
                .string_compare => return try l.call(try l.stringCompare(p), &.{ left, right }, p),
            },
            .evidence => |k| return try l.evidenceCall(k, left, right, p),
            .top, .ext => return l.namedPartCall(part, .compare, left, right, region, p),
            // A position nothing ever inhabits — `Nothing < Nothing` at an
            // element type no use constrains. There is no ordering to get
            // wrong, and `"EQ"` is the one answer that leaves a
            // lexicographic sequence reading the position after it.
            // (A `number` is NOT this case: A.59 answers it with
            // `num_compare` before the checker gives up.)
            .err => return try l.stringNode("EQ", p),
            .derived, .ext_derived => {
                if (!l.derivedBodyExists(part)) {
                    try l.reportDispatchBug(region, derived_body_missing);
                    return null;
                }
                return try l.derivedPartCall(part, .compare, left, right, p);
            },
            .field => {
                try l.reportDispatchBug(region, field_inside_derived);
                return null;
            },
        }
    }

    /// `<name>(<its evidence…>, l, r)` — a derived function applied at one
    /// body position.
    fn derivedPartCall(
        l: *Lowerer,
        part: Dispatch.Target,
        kind: Dispatch.Derived.Kind,
        left: Node.Index,
        right: Node.Index,
        p: u32,
    ) !Node.Index {
        const callee = try l.derivedName(part, p);
        return l.applyEvidence(callee, try l.partValues(part.partsOf(), kind, p), left, right, p);
    }

    /// `M$m(<its evidence…>, l, r)` — a `top` or `ext` value at one body
    /// position.
    ///
    /// **A constrained one is answered by its own `parts`** (§7.1's
    /// amendment, A.64): `List.eq` takes one hidden argument, and before
    /// the range existed the emitted call was one argument short. A target
    /// whose evidence count and part count disagree has no honest call at
    /// all, so it is refused rather than guessed at.
    fn namedPartCall(
        l: *Lowerer,
        part: Dispatch.Target,
        kind: Dispatch.Derived.Kind,
        left: Node.Index,
        right: Node.Index,
        region: Inst.Index,
        p: u32,
    ) !?Node.Index {
        const wanted = l.targetEvidence(part);
        const parts = part.partsOf();
        // Equal, or there is no honest call: one range says how many hidden
        // arguments the callee takes and the other says which values they
        // are, and a disagreement is a call of the wrong arity — which
        // JavaScript runs.
        if (wanted != parts.len) {
            try l.refuseConstrainedPart(region);
            return null;
        }
        const evidence = try l.partValues(parts, kind, p);
        return try l.applyEvidence(try l.targetValue(part, p), evidence, left, right, p);
    }

    fn applyEvidence(
        l: *Lowerer,
        callee: Node.Index,
        evidence: []const Node.Index,
        left: Node.Index,
        right: Node.Index,
        p: u32,
    ) !Node.Index {
        const args = try l.scratch.alloc(Node.Index, evidence.len + 2);
        @memcpy(args[0..evidence.len], evidence);
        args[evidence.len] = left;
        args[evidence.len + 1] = right;
        return l.call(callee, args, p);
    }

    /// The evidence a USE hands a derived function, one value per position
    /// (§7.1, A.46). Ranges nest: a position that is itself a derived
    /// function carries its own.
    ///
    /// `kind` is the method the OWNING target is, and the one thing a
    /// `Target` alone cannot say: an `err` position has to be answered by a
    /// function of the right return type, and `Basics.eq` in a `compare`
    /// slot is a `Bool` where an `Order` was promised.
    fn partValues(
        l: *Lowerer,
        range: Dispatch.Range,
        kind: Dispatch.Derived.Kind,
        p: u32,
    ) Allocator.Error![]const Node.Index {
        const parts = l.in.dispatch.partsAt(range);
        const out = try l.scratch.alloc(Node.Index, parts.len);
        for (parts, out) |part, *slot| slot.* = try l.partValue(part, kind, p);
        return out;
    }

    /// One position's evidence, in VALUE position.
    ///
    /// The `top`/`ext` arm passes the target's OWN parts as evidence and
    /// eta-expands, exactly as `namedPartCall` does in body position —
    /// §7.1's amendment (A.64). Before the range existed this arm could
    /// only refuse, and before THAT it emitted `Main$eq$r$k(Lib$eq, …)`
    /// against a `Lib$eq` of arity three: a `TypeError` at run time, which
    /// is the one outcome `backend.md` §1 forbids.
    fn partValue(
        l: *Lowerer,
        part: Dispatch.Target,
        kind: Dispatch.Derived.Kind,
        p: u32,
    ) Allocator.Error!Node.Index {
        return switch (part) {
            .derived, .ext_derived => l.derivedValue(part, p),
            .primitive => |prim| l.primitiveValue(prim, p),
            // A position nothing inhabits, in value position: the same
            // answer `partEq`/`partCompare` give it, as a function.
            .err => switch (kind) {
                .eq => l.coreValue(.Basics, .eq, p),
                .compare => l.primitiveValue(.num_compare, p),
            },
            .top, .ext => blk: {
                const wanted = l.targetEvidence(part);
                const parts = part.partsOf();
                if (wanted != parts.len) {
                    try l.refuseConstrainedPart(l.region);
                    break :blk l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                const value = try l.targetValue(part, p);
                if (wanted == 0) break :blk value;
                break :blk l.etaExpand(value, try l.partValues(parts, kind, p), l.targetArity(part), p);
            },
            else => l.targetValue(part, p),
        };
    }

    /// A derived function in VALUE position: the bare name when it takes no
    /// evidence, its eta-expansion when it does (§8.2, A.25).
    ///
    /// **A target with no body is a table the checker did not write.** Every
    /// shape §9 describes has a body for both methods, `List a` has its own
    /// `pub foreign eq` and `pub foreign compare` (§5.2), and `equatable` is
    /// core's alone — so the A.51 bridge that used to answer a missing `eq`
    /// with `core/Basics.js`'s structural walk has no customer left and is
    /// gone with S6b. Nothing is MISSING here any more; something would be
    /// WRONG, so it reports `internal` rather than `not_implemented`.
    ///
    /// **Not reachable by any program**: the checker refuses `eq` and
    /// `compare` on a type whose method has no body before the backend is
    /// asked (§3.3, A.54 — `check/bad/CompareOnTypeHoldingFunction`,
    /// `check/bad/core/CompareOnWrappedForeign`), so only a hand-built table
    /// gets here, and the in-source test below is what holds it.
    fn derivedValue(l: *Lowerer, target: Dispatch.Target, p: u32) Allocator.Error!Node.Index {
        if (l.part_depth > max_part_depth) {
            try l.reportDispatchBug(l.region, parts_too_deep);
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        l.part_depth += 1;
        defer l.part_depth -= 1;
        const kind = l.derivedTargetKind(target);
        if (!l.derivedBodyExists(target)) {
            try l.reportDispatchBug(l.region, derived_body_missing);
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        const callee = try l.derivedName(target, p);
        if (l.ownEvidence(target) == 0) return callee;
        return l.etaExpand(callee, try l.partValues(target.partsOf(), kind, p), 2, p);
    }

    /// Which of §9's two methods a derived target is.
    ///
    /// **Ask it only about a `derived` or an `ext_derived`.** Every other
    /// target gets `.eq`, and that is a default and not an answer: a `top`
    /// or an `ext` names a value whose kind lives in its signature, which
    /// this file does not read (§8.0). The one caller that used to ask
    /// about a `top`/`ext` — the site whose target carries `parts` — now
    /// refuses instead, because `.eq` there is a `Bool` in an `Order` slot
    /// (A.67).
    fn derivedTargetKind(l: *Lowerer, target: Dispatch.Target) Dispatch.Derived.Kind {
        return switch (target) {
            .derived => |use| if (use.index < l.in.dispatch.derived.len)
                l.in.dispatch.derived[use.index].kind
            else
                .eq,
            .ext_derived => |use| use.kind,
            else => .eq,
        };
    }

    /// The NAME §8.5 gives a derived function: `<Type>$$<kind>` in the
    /// module that declares the type for a nominal one, the shape key in
    /// this module for a structural one. A nominal method of another module
    /// is imported through the same path as any other cross-module value.
    fn derivedName(l: *Lowerer, target: Dispatch.Target, p: u32) !Node.Index {
        switch (target) {
            .derived => |use| {
                const row = l.in.dispatch.derived[use.index];
                const base = try l.derivedBase(row.kind, row.shape);
                try l.requireLive(l.liveDerived(use.index), base);
                return l.ident(try l.synthesisedName(base), p);
            },
            .ext_derived => |use| {
                const entry = l.in.types.entry(use.type);
                // The same double separator `derivedBase` writes: the
                // importer and the emitter must spell one name.
                const base = try l.interner.getOrPut(l.gpa, try std.fmt.allocPrint(l.scratch, "{s}$${s}", .{
                    l.text(entry.name),
                    @tagName(use.kind),
                }));
                if (std.debug.runtime_safety) {
                    if (l.in.live) |r| {
                        try l.requireLive(r.extDerived(entry.module, use.type, use.kind), l.text(base));
                    }
                }
                const module_name = l.in.graph.moduleName(entry.module);
                try l.needDerived(entry.module, base);
                return l.ident(try l.name(.{
                    .module = module_name.toOptional(),
                    .base = base,
                    .tag = JsIr.Name.no_tag,
                }), p);
            },
            // Unreachable by the contract: every caller tests the target
            // is one of the two derived variants first. A silent
            // `undefined` here would be a name that is not a function in
            // call position, exit 0 and a `TypeError` at runtime, which is
            // the failure `reportDispatchBug` exists to replace.
            else => {
                try l.reportDispatchBug(l.region, derived_name_of_non_derived);
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
        }
    }

    /// Whether the module that owns this target EMITS the function §8.5
    /// names it. Three ways it does not, and each is a wall S5 leaves
    /// standing rather than a call to a name that is not there:
    ///
    ///   - a derived `compare`, which is S6's half of §9;
    ///   - a `foreign type`'s method: there are no constructors to walk, so
    ///     no module derives one (A.55, A.60). `List a` is the live case,
    ///     and §5.2 gives it a `pub foreign compare` of its own in S6b;
    ///   - a nominal type whose own module supplies a `pub` value of that
    ///     name: the module rule won there and the eager pass wrote
    ///     nothing (§3.3 step 1, §6.3.1 step 4).
    ///
    /// **It has to be the same three questions `Solve.deriveOne` asks, in
    /// the same order**, or the emitter names a row the declaring module
    /// did not write — and §3.2's table comes FIRST (A.63). `core/Basics`
    /// declares a `pub compare` of its own, so asking the module rule first
    /// would say that `Basics$Order$$compare` is not there while the eager
    /// pass writes it.
    fn derivedBodyExists(l: *Lowerer, target: Dispatch.Target) bool {
        switch (target) {
            .derived => |use| return use.index < l.in.dispatch.derived.len,
            .ext_derived => |use| {
                const entry = l.in.types.entry(use.type);
                if (entry.kind != .adt) return false;
                if (!l.wellKnownDerivedRow(use.type, use.kind)) {
                    if (entry.module.int() >= l.in.interfaces.len) return false;
                    const spelling = switch (use.kind) {
                        .eq => InternPool.WellKnown.eq,
                        .compare => InternPool.WellKnown.compare,
                    };
                    if (l.in.interfaces[entry.module.int()].findValue(l.interner, spelling.symbol()) != null) return false;
                }
                return switch (use.kind) {
                    .eq => entry.equatable,
                    .compare => entry.comparable,
                };
            },
            else => return false,
        }
    }

    /// Whether §3.2's table answers `(T, kind)` with a DERIVED function
    /// rather than a primitive — the two rows that do: `Order`'s `compare`,
    /// which cannot be alphabetic on its own tags, and both of `Never`'s.
    /// The declaring module writes these whatever else it declares, which
    /// is the whole point of the table being consulted first (§3.2, A.63).
    fn wellKnownDerivedRow(l: *Lowerer, id: Dispatch.TypeId, kind: Dispatch.Derived.Kind) bool {
        const wk = l.in.types.well_known;
        if (id == .none) return false;
        if (id == wk.order) return kind == .compare;
        return id == wk.never;
    }

    /// How many evidence parameters the function a target NAMES takes —
    /// which is not `targetEvidence`, whose answer is how many SITES the
    /// target consumes. A derived function's evidence rides on the target's
    /// own `parts` (A.46) and never on the site list.
    fn ownEvidence(l: *Lowerer, target: Dispatch.Target) u16 {
        return switch (target) {
            .derived => |use| if (use.index < l.in.dispatch.derived.len)
                l.in.dispatch.derived[use.index].evidence_count
            else
                0,
            // One per type parameter, used or not: the uniform rule of
            // §9.4 and A.20, which is what keeps the order a function of
            // the type's own declaration.
            .ext_derived => |use| l.in.types.entry(use.type).arity,
            else => l.targetEvidence(target),
        };
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

    /// **The wall is down.** Every row of §8 is lowered and every shape of
    /// §9 has a body for both methods, so what this checks is no longer a
    /// slice that has not landed: a target with no body, or a site list
    /// that is not the tree §8.2 describes, is a table the checker did not
    /// write. Both say `internal`.
    fn refuseEvidence(l: *Lowerer, inst: Inst.Index, sites: []const Dispatch.Site, expected: u16) !bool {
        for (sites) |site| {
            switch (site.target) {
                .derived, .ext_derived => {
                    if (l.derivedBodyExists(site.target)) continue;
                    try l.reportDispatchBug(inst, derived_body_missing);
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
        // A target holding its own `parts` is answered by them and takes
        // nothing from the site list (§7.1's amendment, A.64).
        if (target.partsOf().len != 0) return true;
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

    /// A SITE whose target carries its own `parts` (§7.1's amendment,
    /// A.64). The amendment is about a part POSITION, where there is no
    /// instruction to number a site against; a site has one, so its
    /// target's evidence is the sites that follow it and its `parts` range
    /// is empty. A non-empty one means the two ways of carrying evidence
    /// were both used for one slot, and the walk cannot tell which method
    /// the slot answers — which is what an `err` inside it would need
    /// (A.67).
    const parts_on_site_target =
        \\This call's evidence is carried twice over: `docs/design/static-dispatch-spike.md`
        \\§7.1's `parts` range belongs to a target in a PART position, and this one is on
        \\a site, whose evidence is the sites that follow it instead (§7.2, A.64).
    ;

    /// §8.4 has no receiver, so §8.3's record-field row cannot appear.
    const field_without_receiver =
        \\The table dispatches this to a record field, but `docs/design/static-dispatch-spike.md`
        \\§8.4 has no receiver to read a field from: only a method call can answer `field`.
    ;

    /// How far the nested `parts` of §7.1 may go. A type nested 32 deep in
    /// another is already past what `Types.Builder.max_depth` lets an
    /// annotation say, so this is a guard against a malformed table and not
    /// a limit on a program.
    const max_part_depth: u8 = 32;

    const parts_too_deep =
        \\The evidence of this call nests deeper than
        \\`docs/design/static-dispatch-spike.md` §7.1's `parts` can describe, which
        \\means a range in the table points back at itself.
    ;

    /// §7.1: a `derived` row is exactly what THIS module emits (A.47), so
    /// a nominal one names a type declared here.
    const derived_not_declared_here =
        \\This module's table holds a derived method for a type another module declares,
        \\and `docs/design/static-dispatch-spike.md` §7.1 says a `derived` row is exactly
        \\what this module emits — another module's is an `ext_derived` target (A.47).
    ;

    /// §9's two kinds do not mix: `eq` has one primitive answer and the
    /// three ordering ones belong to `compare`.
    const derived_wrong_primitive =
        \\A position inside a derived `eq` is answered by an ordering primitive, and
        \\`docs/design/static-dispatch-spike.md` §9's parts table gives `eq` exactly one
        \\primitive answer: `strict_eq`.
    ;

    /// §8.3's record-field row needs a receiver, and a derived body's
    /// positions are values.
    const field_inside_derived =
        \\A position inside a derived method is dispatched to a record field, and
        \\`docs/design/static-dispatch-spike.md` §9 has no field to read there: a body
        \\position is a pair of values, not a method call on a receiver.
    ;

    /// §8.5 names a derived function and nothing else, so asking for the
    /// name of a target that is neither `derived` nor `ext_derived` is a
    /// table the emitter walked into the wrong arm of.
    const derived_name_of_non_derived =
        \\The table asks for the NAME of a derived method at a position whose target is
        \\not a derived one, and `docs/design/static-dispatch-spike.md` §8.5 names only
        \\a `derived` or an `ext_derived` target.
    ;

    /// §9's parts contract: one target per constructor argument.
    const derived_parts_short =
        \\A derived method has fewer parts than the type has constructor arguments, and
        \\`docs/design/static-dispatch-spike.md` §9's parts contract gives it exactly one
        \\per argument, constructors in declaration order.
    ;

    /// §8.3's primitive rows are the binary comparison methods.
    const primitive_needs_two_operands =
        \\The table dispatches this to one of `docs/design/static-dispatch-spike.md` §8.3's
        \\primitive comparisons, and every one of those is binary — a receiver and exactly
        \\one argument. This call has a different number of arguments.
    ;

    /// A derived target the emitting module writes no function for.
    ///
    /// **Nothing reaches this from a program.** Every shape §9 describes
    /// has a body for both methods, `List a` has its own `pub foreign eq`
    /// and `pub foreign compare` (§5.2), and `equatable` — the marker that
    /// let a `foreign type` answer `eq` without one — is core's alone, so
    /// core is the only place that could declare such a type and core no
    /// longer does. The A.51 bridge that answered a missing `eq` with
    /// `core/Basics.js`'s structural walk went with it in S6b: keeping it
    /// would mean keeping a recursive test of whether the walk happens to
    /// agree with the table, for a case no program can produce.
    const derived_body_missing =
        \\The table resolves this to a derived method of a type whose module emits no
        \\function for it, and after `docs/design/static-dispatch-spike.md` §5.2 there is
        \\no such type: every shape §9 describes has a body, and `List a` has a
        \\`pub foreign eq` and a `pub foreign compare` of its own.
    ;

    /// A constrained value in a PART position (§7.1): a `top` or `ext`
    /// target with evidence parameters of its own, which the `parts` tree
    /// has no room to carry the evidence for.
    fn refuseConstrainedPart(l: *Lowerer, inst: Inst.Index) !void {
        try l.report(
            .not_implemented,
            inst,
            \\I cannot compile this comparison to JavaScript yet.
            \\
            \\One position inside it is answered by a value that takes evidence of its
            \\own, and `docs/design/static-dispatch-spike.md` §7.1's `parts` tree has
            \\nowhere to put that evidence: a `Target.ext` carries no range of its own,
            \\so the call would be one argument short.
            \\
            \\That is a gap in the table rather than in this program. Please report it;
            \\`beni dump --stage=dispatch` prints what the checker recorded.
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
            // §9's derived function, applied to the evidence THIS use
            // passes and then to the two values (§8.3). A derived target
            // carries its evidence in its own `parts` (A.46), so the
            // instruction's further sites must be empty.
            .derived, .ext_derived => {
                if (try l.refuseEvidence(inst, evidence_sites, 0)) {
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                if (!l.derivedBodyExists(target)) {
                    // A.51's door, closed with S6b: every shape of §9 has a
                    // body for both methods and `List a` has its own
                    // `pub foreign eq`/`compare` (§5.2), so there is no
                    // method left that no module writes a function for.
                    try l.reportDispatchBug(inst, derived_body_missing);
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                const evidence = try l.partValues(target.partsOf(), l.derivedTargetKind(target), p);
                const callee = try l.derivedName(target, p);
                const value = try l.receiverCall(out, callee, evidence, @enumFromInt(d.lhs), args, p);
                // `a /= b` is `!eq(a, b)`; an ordering operator wraps the
                // `Order` the method answers in §8.3's test.
                return l.orderTest(value, m.origin, p);
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
                // §6.7 makes a return-type dispatch's target `evidence k`
                // inside a constrained declaration, so in practice this is
                // a concrete receiver-less call of a shape's own method.
                // It is the same call §8.3 makes, minus the receiver: the
                // evidence the USE passes rides on the target's parts
                // (A.46) and the written arguments follow.
                if (!l.derivedBodyExists(target)) {
                    try l.reportDispatchBug(inst, derived_body_missing);
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                if (try l.refuseEvidence(inst, sites[1..], 0)) {
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                const evidence = try l.partValues(target.partsOf(), l.derivedTargetKind(target), p);
                const callee = try l.derivedName(target, p);
                const rest = try l.exprList(out, args);
                const all = try l.scratch.alloc(Node.Index, evidence.len + rest.len);
                @memcpy(all[0..evidence.len], evidence);
                @memcpy(all[evidence.len..], rest);
                return l.call(callee, all, p);
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
    /// and `Basics.eq` behind `partEq`'s `err` arm, the position nothing
    /// ever inhabits (A.66).
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
            \\A core package replaced with `--core-root` must declare `Basics.eq` and
            \\`String.compare`.
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
                    const self: Loop.Self = .{ .local = payload.local };
                    if (params.len == 0) {
                        // §8 again: `go = \i acc -> …` inherits the binding's
                        // name exactly as `go i acc = …` does.
                        const value_inst: Inst.Index = @enumFromInt(d.rhs);
                        if (l.bir.instTag(value_inst) == .lambda) {
                            const ld = l.bir.instData(value_inst);
                            const lambda_p = l.pos(value_inst);
                            const lambda_params = l.bir.extraSlice(l.bir.subRange(@enumFromInt(ld.lhs)), Inst.Index);
                            const lambda_record = try l.functionOrLoop(
                                n,
                                self,
                                0,
                                lambda_params,
                                @enumFromInt(ld.rhs),
                                lambda_p,
                            );
                            const lambda = try l.add(.arrow, lambda_p, @intFromEnum(lambda_record), Node.Data.unused);
                            try l.constDecl(out, n, lambda, p);
                            continue;
                        }
                        const value = try l.expr(out, value_inst);
                        try l.constDecl(out, n, value, p);
                        continue;
                    }
                    // A `let_def` with parameters is already its own hoisted
                    // `function` (§8's cases table), so the loop is
                    // contained; excluding it would leave the language's
                    // most natural loop idiom overflowing.
                    const record = try l.functionOrLoop(n, self, 0, params, @enumFromInt(d.rhs), p);
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

    /// Bind a value to a name unless it is already something that can be
    /// re-read for free. A `let` pattern reads its subject once per binding
    /// and a comparator reads each operand twice, so a call — or anything
    /// else with work in it — has to be evaluated exactly once.
    ///
    /// A `case` calls this only when the tree reads the root more than once
    /// (§7, `planCase`): a two-alternative boolean node reads it once, and
    /// binding it there is the 41 scrutinee temporaries §7 measures.
    fn bindSubject(l: *Lowerer, out: *StmtList, value: Node.Index, p: u32) !Node.Index {
        switch (l.b.nodes.items(.tag)[value.int()]) {
            .ident, .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => return value,
            else => {},
        }
        const n = try l.fresh(l.well.temp);
        try l.constDecl(out, n, value, p);
        return l.ident(n, p);
    }

    // ---- `case` — the decision tree (backend.md §7) ------------------------
    //
    // One tree over ALL the branches at once, so nothing re-tests what the
    // branches above it already disproved. `js/Decision.zig` builds the tree
    // out of `Bir` patterns and knows no representation; everything below
    // turns it into JavaScript: §4's `subj` / `subj.$` discriminants, the
    // `switch` at three labels and the `if` at two, the bindings at the leaf
    // as member chains, and the labelled block a leaf reached from two paths
    // is written once behind.

    /// Where a `case`'s leaves send their answers.
    const Sink = union(enum) {
        /// **Tail position**: each leaf lowers its body straight into
        /// statements, so a leaf ends in `return` or — inside a loop, and
        /// only when the body is a tail self-call — §8's assignments and
        /// `continue <label>`. Both terminate a `switch` case and escape
        /// every labelled block, which is why tail position needs no
        /// wrapper. `null` is a function with no loop at all: §8's gate on
        /// this form is removed (§7), so a `case` in tail position becomes
        /// statements whether or not the function loops.
        tail: ?*const Loop,
        /// **Expression position**: each leaf assigns the result temporary
        /// and, when the tree needed a `$c$<d>` block, breaks out of it.
        value: Value,
    };

    const Value = struct {
        result: JsIr.NameIndex,
        /// `.none` for a pure `if`/`else` chain: the arms fall out of it and
        /// there is nothing to break out of (§7's third row).
        wrapper: JsIr.NameIndex = .none,
    };

    /// A branch body already lowered as an expression, for the shapes that
    /// turned out not to need statements. Lowering happens exactly once
    /// either way: a leaf reached from one path is inlined there and a leaf
    /// reached from two or more is written once, so no body is ever lowered
    /// twice and no `$t$<n>` is ever allocated and thrown away.
    const Ready = struct {
        stmts: []const Node.Index = &.{},
        value: Node.OptionalIndex = .none,
    };

    /// Everything one `case` needs to emit itself.
    const Case = struct {
        tree: Decision.Tree,
        /// The JavaScript expression each root is read through. One root
        /// normally; §7's tuple-literal rule gives one per element.
        roots: []const Node.Index,
        /// The member chain of each occurrence, built on first use and
        /// reused: `JsIr` is immutable, so one node may be referenced from
        /// as many tests as read that occurrence.
        occ_nodes: []Node.OptionalIndex,
        /// `branch * roots.len + r`: the pattern whose bindings root `r`
        /// supplies for that branch, or `.none` when it supplies none.
        pats: []const Inst.OptionalIndex,
        branches: []const Inst.Index,
        /// The number of enclosing `case` instructions, which is the `<d>`
        /// of `$j$<d>$<b>` and `$c$<d>` (§7). Structural, so a golden does
        /// not renumber when an unrelated declaration is added above it.
        depth: u32,
        /// Branches reached from two or more paths, ascending — §7's shared
        /// leaves, nested lowest-index-innermost so their bodies read in
        /// source order.
        shared: []const u32,
        /// Pre-lowered leaf values, or empty when the leaves lower
        /// themselves as they are emitted.
        ready: []Ready,
        sink: Sink,
        p: u32,
    };

    /// A `case` in expression position: §7's last three rows.
    fn caseExpr(l: *Lowerer, out: *StmtList, inst: Inst.Index) !Node.Index {
        const p = l.pos(inst);
        var c = try l.planCase(out, inst) orelse
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        const depth = l.case_depth;
        l.case_depth += 1;
        defer l.case_depth = depth;

        // The conditional-expression shape: no `switch`, no shared leaf,
        // nothing bound, every leaf one expression — `a ? b : c` and nothing
        // more, exactly as today.
        if (l.condChainPossible(&c)) {
            try l.lowerReady(&c);
            if (l.readyIsClean(&c)) return l.condChain(&c, c.tree.root);
        }

        const result = try l.fresh(l.well.temp);
        try out.append(l.scratch, try l.add(
            .let_decl,
            c.p,
            @intFromEnum(result),
            @intFromEnum(Node.OptionalIndex.none),
        ));
        const wrapped = c.tree.hasSwitch() or c.tree.hasShared();
        c.sink = .{ .value = .{
            .result = result,
            .wrapper = if (wrapped) try l.caseLabel(&c) else .none,
        } };

        if (!wrapped) {
            try l.emitCase(&c, out);
            return l.ident(result, c.p);
        }
        // One `$c$<d>` block, which every leaf but the textually last one
        // breaks out of to skip the shared leaves written below the tree.
        var inner: StmtList = .empty;
        try l.emitCase(&c, &inner);
        l.trimTrailingBreak(&inner, c.sink.value.wrapper);
        try out.append(l.scratch, try l.blockStmt(c.sink.value.wrapper, inner.items, c.p));
        return l.ident(result, c.p);
    }

    /// A `case` in TAIL position (§7's first row): the branch bodies are
    /// lowered as statements, so each arm returns — or jumps — for itself
    /// and there is no result temporary at all.
    fn tailCase(l: *Lowerer, out: *StmtList, inst: Inst.Index, loop: ?*const Loop) !void {
        const p = l.pos(inst);
        var c = try l.planCase(out, inst) orelse {
            const value = try l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            try out.append(l.scratch, try l.returnStmt(value, p));
            return;
        };
        const depth = l.case_depth;
        l.case_depth += 1;
        defer l.case_depth = depth;
        c.sink = .{ .tail = loop };

        // A chain of two-way tests over expression leaves stays the
        // conditional expression it is today: `return a ? b : c` is shorter
        // than two `return`s and says the same thing.
        if (l.condChainPossible(&c)) {
            try l.lowerReady(&c);
            if (l.readyIsClean(&c)) {
                const value = try l.condChain(&c, c.tree.root);
                try out.append(l.scratch, try l.returnStmt(value, c.p));
                return;
            }
        }
        try l.emitCase(&c, out);
    }

    /// Build the tree, evaluate the scrutinee and decide which leaves are
    /// shared. `null` is a `case` with no branches, which the parser already
    /// reported.
    fn planCase(l: *Lowerer, out: *StmtList, inst: Inst.Index) !?Case {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        const scrutinee: Inst.Index = @enumFromInt(d.lhs);
        const branches = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
        if (branches.len == 0) return null;

        // §7's tuple-literal rule: a `case` on a tuple LITERAL every row
        // matches with a tuple pattern (or a bare `_`) starts as an n-column
        // matrix over the elements, and no tuple object is built. A row that
        // binds the tuple as a whole, by name or by `as`, needs the object
        // and turns the rule off.
        const elements: []const Inst.Index = if (l.bir.instTag(scrutinee) == .tuple)
            l.bir.extraSlice(Bir.inlineRange(l.bir.instData(scrutinee)), Inst.Index)
        else
            &.{};
        const spread = elements.len != 0 and l.rowsAreTuples(branches, elements.len);
        const roots: usize = if (spread) elements.len else 1;

        const pats = try l.scratch.alloc(Inst.OptionalIndex, branches.len * roots);
        @memset(pats, .none);
        const rows = try l.scratch.alloc(Decision.Row, branches.len);
        for (branches, 0..) |branch, i| {
            const pattern: Inst.Index = @enumFromInt(l.bir.instData(branch).lhs);
            const slots = pats[i * roots ..][0..roots];
            if (!spread) {
                slots[0] = pattern.toOptional();
            } else if (l.bir.instTag(pattern) == .pat_tuple) {
                for (l.bir.extraSlice(Bir.inlineRange(l.bir.instData(pattern)), Inst.Index), slots) |element, *slot| {
                    slot.* = element.toOptional();
                }
            }
            rows[i] = .{ .branch = @intCast(i), .pats = slots };
        }

        const tree = try Decision.build(
            l.scratch,
            .{ .bir = l.bir, .interfaces = l.in.interfaces },
            @intCast(roots),
            rows,
            @intCast(branches.len),
        );

        // The scrutinee is evaluated exactly once, and §7 binds it to a name
        // only when the tree READS it more than once: a two-alternative
        // boolean node reads it once, so `const $t$1 = n$1 <= 0; if ($t$1)`
        // becomes `if (n$1 <= 0)` — and every `if` in the language is a
        // `case` (`language.md` §8).
        const root_nodes = try l.scratch.alloc(Node.Index, roots);
        if (!spread) {
            const value = try l.expr(out, scrutinee);
            var reads = tree.fanReads(0);
            for (0..branches.len) |i| {
                if (tree.uses[i] == 0) continue;
                reads += l.bindCount(pats[i]);
            }
            root_nodes[0] = if (reads == 1) value else try l.bindSubject(out, value, p);
        } else {
            // Each element is bound in source order, so the elements keep
            // being evaluated left to right whatever the tree tests first.
            for (elements, root_nodes) |element, *root| {
                root.* = try l.bindSubject(out, try l.expr(out, element), p);
            }
        }

        var shared: std.ArrayList(u32) = .empty;
        for (tree.uses, 0..) |uses, i| {
            if (uses >= 2) try shared.append(l.scratch, @intCast(i));
        }
        const occ_nodes = try l.scratch.alloc(Node.OptionalIndex, tree.occs.len);
        @memset(occ_nodes, .none);
        return .{
            .tree = tree,
            .roots = root_nodes,
            .occ_nodes = occ_nodes,
            .pats = pats,
            .branches = branches,
            .depth = l.case_depth,
            .shared = shared.items,
            .ready = try l.scratch.alloc(Ready, 0),
            .sink = .{ .tail = null },
            .p = p,
        };
    }

    /// Whether every row of `branches` matches a tuple of `arity` elements
    /// or is a bare `_`. A row that names the tuple — `t ->`, `( a, b ) as
    /// t ->` — needs the object, and one of another arity is a type error
    /// that never reaches here.
    fn rowsAreTuples(l: *Lowerer, branches: []const Inst.Index, arity: usize) bool {
        for (branches) |branch| {
            const pattern: Inst.Index = @enumFromInt(l.bir.instData(branch).lhs);
            switch (l.bir.instTag(pattern)) {
                .pat_wild => {},
                .pat_tuple => if (Bir.inlineRange(l.bir.instData(pattern)).len() != arity) return false,
                else => return false,
            }
        }
        return true;
    }

    /// How many times `bindings` would read the subject of `pattern`: one
    /// per `const` it emits.
    fn bindCount(l: *Lowerer, pattern: Inst.OptionalIndex) u32 {
        const pat = pattern.unwrap() orelse return 0;
        const d = l.bir.instData(pat);
        return switch (l.bir.instTag(pat)) {
            .pat_var => 1,
            .pat_as => 1 + l.bindCount(@as(Inst.Index, @enumFromInt(d.lhs)).toOptional()),
            .pat_record => Bir.inlineRange(d).len(),
            .pat_tuple, .pat_list => blk: {
                var total: u32 = 0;
                for (l.bir.extraSlice(Bir.inlineRange(d), Inst.Index)) |element| {
                    total += l.bindCount(element.toOptional());
                }
                break :blk total;
            },
            .pat_ctor => blk: {
                var total: u32 = 0;
                for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index)) |arg| {
                    total += l.bindCount(arg.toOptional());
                }
                break :blk total;
            },
            .pat_cons => l.bindCount(@as(Inst.Index, @enumFromInt(d.lhs)).toOptional()) +
                l.bindCount(@as(Inst.Index, @enumFromInt(d.rhs)).toOptional()),
            else => 0,
        };
    }

    // ---- The emitted shape ------------------------------------------------

    /// The tree, and the shared leaves behind it: `$j$<d>$<b>` labels the
    /// block whose exit is branch *b*, and the blocks nest with the lowest
    /// branch index innermost so their bodies read in source order (§7).
    fn emitCase(l: *Lowerer, c: *Case, out: *StmtList) !void {
        var stmts: StmtList = .empty;
        try l.emitNode(c, &stmts, c.tree.root);
        for (c.shared) |branch| {
            const block = try l.blockStmt(try l.sharedLabel(c, branch), stmts.items, c.p);
            var next: StmtList = .empty;
            try next.append(l.scratch, block);
            try l.leafBody(c, &next, branch);
            stmts = next;
        }
        try out.appendSlice(l.scratch, stmts.items);
    }

    fn emitNode(l: *Lowerer, c: *Case, out: *StmtList, node: u32) Allocator.Error!void {
        if (node == Decision.no_node) return;
        switch (c.tree.node(node)) {
            .leaf => |branch| try l.emitLeaf(c, out, branch),
            .fan => |index| try l.emitFan(c, out, index),
        }
    }

    /// A leaf: inlined when one path reaches it, and a `break` to the block
    /// it is written behind when two or more do (§7's counted rule — Elm's
    /// `countTargets`/`createChoices`).
    fn emitLeaf(l: *Lowerer, c: *Case, out: *StmtList, branch: u32) !void {
        if (c.tree.uses[branch] >= 2) {
            const label = try l.sharedLabel(c, branch);
            try out.append(l.scratch, try l.add(.break_stmt, c.p, @intFromEnum(label), Node.Data.unused));
            return;
        }
        try l.leafBody(c, out, branch);
    }

    /// The bindings of a branch and then its body. **An occurrence is a
    /// member chain and not a name**, so it is the same expression on every
    /// path that reaches the leaf — which is what lets the leaf own its
    /// bindings even when it is shared.
    fn leafBody(l: *Lowerer, c: *Case, out: *StmtList, branch: u32) !void {
        for (c.roots, 0..) |root, r| {
            const pattern = c.pats[branch * c.roots.len + r].unwrap() orelse continue;
            try l.bindings(out, pattern, root);
        }
        const body: Inst.Index = @enumFromInt(l.bir.instData(c.branches[branch]).rhs);
        const p = l.pos(c.branches[branch]);
        // A pre-lowered leaf: the shape decided it was an expression before
        // the bodies were lowered, and then one of them needed a statement
        // after all.
        if (c.ready.len != 0) {
            try out.appendSlice(l.scratch, c.ready[branch].stmts);
            const value = c.ready[branch].value.unwrap() orelse return;
            return l.finishLeaf(c, out, value, p);
        }
        switch (c.sink) {
            .tail => |loop| try l.tailStmts(out, body, loop),
            .value => {
                const value = try l.expr(out, body);
                try l.finishLeaf(c, out, value, p);
            },
        }
    }

    fn finishLeaf(l: *Lowerer, c: *Case, out: *StmtList, value: Node.Index, p: u32) !void {
        switch (c.sink) {
            .tail => try out.append(l.scratch, try l.returnStmt(value, p)),
            .value => |v| {
                const target = try l.ident(v.result, p);
                try out.append(l.scratch, try l.add(.assign_stmt, p, target.int(), value.int()));
                if (v.wrapper != .none) {
                    try out.append(l.scratch, try l.add(.break_stmt, p, @intFromEnum(v.wrapper), Node.Data.unused));
                }
            },
        }
    }

    /// One fan-out. **Three or more case labels is a `switch`; two or fewer
    /// is `if`/`else`** (§7) — a threshold that is representation
    /// independent, and that makes a boolean and a list node, which have
    /// exactly two alternatives, always an `if`.
    fn emitFan(l: *Lowerer, c: *Case, out: *StmtList, index: u32) !void {
        const fan = c.tree.fans[index];
        const edges = c.tree.edges[fan.edges_start..fan.edges_end];
        const labels = fan.labels();
        // One alternative and no default: the type has one constructor here,
        // so there is nothing to test and no impossible arm to name.
        if (labels <= 1) {
            if (fan.default != Decision.no_node) return l.emitNode(c, out, fan.default);
            if (edges.len != 0) return l.emitNode(c, out, edges[0].child);
            return;
        }
        if (labels == 2) {
            const condition = try l.edgeTest(c, fan, edges[0]);
            var then_stmts: StmtList = .empty;
            try l.emitNode(c, &then_stmts, edges[0].child);
            var else_stmts: StmtList = .empty;
            try l.emitNode(c, &else_stmts, if (fan.default != Decision.no_node)
                fan.default
            else
                edges[1].child);
            const then_range = try l.b.addRange(then_stmts.items);
            const else_range = try l.b.addRange(else_stmts.items);
            const record = try l.b.addRecord(JsIr.If{
                .then_start = then_range.start,
                .then_end = then_range.end,
                .else_start = else_range.start,
                .else_end = else_range.end,
            });
            const p = l.edgePos(c, edges[0]);
            try out.append(l.scratch, try l.add(.if_stmt, p, condition.int(), @intFromEnum(record)));
            return;
        }

        // **The last alternative of an exhaustive fan-out is `default:`**,
        // not a `case` of its own, and nothing is emitted for the impossible
        // arm: it saves a label and a `throw` per `switch`, and it is
        // byte-for-byte what the chain did when it emitted its last branch
        // unconditionally.
        const tail_is_default = fan.default == Decision.no_node;
        const named = edges[0 .. edges.len - @intFromBool(tail_is_default)];
        var cases: std.ArrayList(Node.Index) = .empty;
        for (named) |edge| {
            const p = l.edgePos(c, edge);
            var body: StmtList = .empty;
            try l.emitNode(c, &body, edge.child);
            // **Each case body is a block.** Two sibling cases may both
            // bind, and a `switch`'s cases share one scope; local indices
            // keep the names apart today, and one block per case ends that
            // class of bug for two bytes that compress to nothing.
            const one = [_]Node.Index{try l.blockStmt(.none, body.items, p)};
            const range = try l.b.addRange(&one);
            const record = try l.b.addRecord(range);
            const key = try l.edgeKey(c, fan, edge);
            try cases.append(l.scratch, try l.add(
                .switch_case,
                p,
                @intFromEnum(key.toOptional()),
                @intFromEnum(record),
            ));
        }
        {
            const child = if (tail_is_default) edges[edges.len - 1].child else fan.default;
            var body: StmtList = .empty;
            try l.emitNode(c, &body, child);
            const one = [_]Node.Index{try l.blockStmt(.none, body.items, c.p)};
            const range = try l.b.addRange(&one);
            const record = try l.b.addRecord(range);
            try cases.append(l.scratch, try l.add(
                .switch_case,
                c.p,
                @intFromEnum(Node.OptionalIndex.none),
                @intFromEnum(record),
            ));
        }
        const cases_range = try l.b.addRange(cases.items);
        const cases_record = try l.b.addRecord(cases_range);
        const discriminant = try l.fanDiscriminant(c, fan);
        try out.append(l.scratch, try l.add(.switch_stmt, c.p, discriminant.int(), @intFromEnum(cases_record)));
    }

    /// The conditional-expression form of a chain: `a ? b : c`, built from
    /// the same tree. Reached only when `condChainPossible` held and every
    /// leaf lowered without a statement.
    fn condChain(l: *Lowerer, c: *Case, node: u32) Allocator.Error!Node.Index {
        switch (c.tree.node(node)) {
            .leaf => |branch| return c.ready[branch].value.unwrap().?,
            .fan => |index| {
                const fan = c.tree.fans[index];
                const edges = c.tree.edges[fan.edges_start..fan.edges_end];
                if (fan.labels() <= 1) {
                    return l.condChain(c, if (fan.default != Decision.no_node) fan.default else edges[0].child);
                }
                const condition = try l.edgeTest(c, fan, edges[0]);
                const consequent = try l.condChain(c, edges[0].child);
                const alternate = try l.condChain(c, if (fan.default != Decision.no_node)
                    fan.default
                else
                    edges[1].child);
                const record = try l.b.addRecord(JsIr.Cond{ .consequent = consequent, .alternate = alternate });
                return l.add(.cond, l.edgePos(c, edges[0]), condition.int(), @intFromEnum(record));
            },
        }
    }

    // ---- Tests, discriminants and occurrences ------------------------------

    /// What a `switch` switches on: `subj` for `.boolean` and `.bare_tag`,
    /// `subj.$` for `.tagged` and for a list cell, and the scrutinee itself
    /// for a literal node (§7).
    fn fanDiscriminant(l: *Lowerer, c: *Case, fan: Decision.Fan) !Node.Index {
        const subject = try l.occNode(c, fan.occ);
        switch (fan.kind) {
            .list => return l.member(subject, l.well.tag, c.p),
            .ctor => {
                const rep = l.fanRep(c, fan) orelse return subject;
                return switch (rep) {
                    .tagged => try l.member(subject, l.well.tag, c.p),
                    .boolean, .bare_tag => subject,
                };
            },
            .int, .char, .string => return subject,
        }
    }

    /// The `===` an `if` tests one alternative with. `x === true` is `x` and
    /// `x === false` is `!x`: the one place a readable `if` is worth a
    /// special case, because every `if` in the language goes through here.
    fn edgeTest(l: *Lowerer, c: *Case, fan: Decision.Fan, edge: Decision.Edge) !Node.Index {
        const subject = try l.occNode(c, fan.occ);
        const p = l.edgePos(c, edge);
        if (fan.kind == .ctor) {
            if (edge.ref.unwrap()) |ref| {
                if (l.ctorRepOf(ref)) |rep_and_tag| switch (rep_and_tag[0]) {
                    // `True` and `False` are the alternative itself.
                    .boolean => |value| return if (value) subject else try l.unary(.not, subject, p),
                    else => {},
                };
            }
        }
        return l.binary(.strict_eq, try l.fanDiscriminant(c, fan), try l.edgeKey(c, fan, edge), p);
    }

    /// The value a `case` label compares against: the constructor's tag, the
    /// `0`/`1` of a list cell, or the literal the pattern spells.
    fn edgeKey(l: *Lowerer, c: *Case, fan: Decision.Fan, edge: Decision.Edge) !Node.Index {
        const p = l.edgePos(c, edge);
        switch (fan.kind) {
            .list => return l.numberNode(if (edge.order == 0) "0" else "1", p),
            .ctor => {
                const ref = edge.ref.unwrap() orelse return l.nullNode(p);
                const rep_and_tag = l.ctorRepOf(ref) orelse return l.nullNode(p);
                return l.stringNode(l.text(rep_and_tag[1]), p);
            },
            .int => return l.numberNode(l.bir.bytes(edge.ref.unwrap().?), p),
            .char => {
                var buf: [4]u8 = undefined;
                const scalar = l.bir.instData(edge.ref.unwrap().?).lhs;
                const len = std.unicode.utf8Encode(std.math.cast(u21, scalar) orelse 0xFFFD, &buf) catch
                    std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
                return l.stringNode(buf[0..len], p);
            },
            .string => return l.stringNode(l.bir.bytes(edge.ref.unwrap().?), p),
        }
    }

    /// How the constructors of a `.ctor` fan are represented. Every edge of
    /// one fan is a constructor of one type, so the first answers for all.
    fn fanRep(l: *Lowerer, c: *Case, fan: Decision.Fan) ?CtorRep {
        for (c.tree.edges[fan.edges_start..fan.edges_end]) |edge| {
            const ref = edge.ref.unwrap() orelse continue;
            const rep_and_tag = l.ctorRepOf(ref) orelse continue;
            return rep_and_tag[0];
        }
        return null;
    }

    fn edgePos(l: *Lowerer, c: *Case, edge: Decision.Edge) u32 {
        const ref = edge.ref.unwrap() orelse return c.p;
        return l.pos(ref);
    }

    /// An occurrence as a member chain down from its root, built once and
    /// reused. The chain is rebuilt rather than bound to a `const $p$k` per
    /// edge: every value is immutable and every step is a property read, so
    /// re-reading costs nothing and there is no live binding for M3c's
    /// dead-binding pass to fail to remove (§7).
    fn occNode(l: *Lowerer, c: *Case, occ: u32) Allocator.Error!Node.Index {
        if (c.occ_nodes[occ].unwrap()) |node| return node;
        const o = c.tree.occs[occ];
        const node = if (o.parent == Decision.Occ.no_parent)
            c.roots[o.root]
        else
            try l.member(try l.occNode(c, o.parent), try l.slotName(o.slot), c.p);
        c.occ_nodes[occ] = node.toOptional();
        return node;
    }

    // ---- Shapes and labels -------------------------------------------------

    /// Whether the tree can be one conditional expression: no `switch`, no
    /// shared leaf, nothing bound, and no branch body that is a `let`, a
    /// `case` or a tail self-call — the three that need statements of their
    /// own. Whether the bodies really lower without statements is only known
    /// after they are lowered, which is what `readyIsClean` answers.
    fn condChainPossible(l: *Lowerer, c: *Case) bool {
        if (c.tree.hasSwitch() or c.tree.hasShared()) return false;
        for (c.branches, 0..) |branch, i| {
            if (c.tree.uses[i] == 0) continue;
            for (0..c.roots.len) |r| {
                if (l.bindCount(c.pats[i * c.roots.len + r]) != 0) return false;
            }
            const body: Inst.Index = @enumFromInt(l.bir.instData(branch).rhs);
            switch (l.bir.instTag(body)) {
                .let, .case => return false,
                .call => switch (c.sink) {
                    .tail => |loop| if (loop) |lp| {
                        if (l.isSelfCall(body, lp)) return false;
                    },
                    .value => {},
                },
                else => {},
            }
        }
        return true;
    }

    fn lowerReady(l: *Lowerer, c: *Case) !void {
        const ready = try l.scratch.alloc(Ready, c.branches.len);
        @memset(ready, .{});
        for (c.branches, 0..) |branch, i| {
            if (c.tree.uses[i] == 0) continue;
            var stmts: StmtList = .empty;
            const value = try l.expr(&stmts, @enumFromInt(l.bir.instData(branch).rhs));
            ready[i] = .{ .stmts = stmts.items, .value = value.toOptional() };
        }
        c.ready = ready;
    }

    fn readyIsClean(l: *Lowerer, c: *Case) bool {
        _ = l;
        for (c.ready, 0..) |ready, i| {
            if (c.tree.uses[i] == 0) continue;
            if (ready.stmts.len != 0) return false;
        }
        return true;
    }

    /// `$j$<d>$<b>`: the block whose exit is branch *b*. Structural, so two
    /// cases at one depth are siblings and never nested and the names cannot
    /// collide.
    fn sharedLabel(l: *Lowerer, c: *Case, branch: u32) !JsIr.NameIndex {
        var buf: [32]u8 = undefined;
        const spelled = std.fmt.bufPrint(&buf, "$j${d}${d}", .{ c.depth, branch }) catch unreachable;
        const base = try l.interner.getOrPut(l.gpa, spelled);
        return l.name(.{ .module = .none, .base = base, .tag = JsIr.Name.no_tag });
    }

    /// `$c$<d>`: the block an expression-position tree assigns its result
    /// inside and breaks out of.
    fn caseLabel(l: *Lowerer, c: *Case) !JsIr.NameIndex {
        var buf: [24]u8 = undefined;
        const spelled = std.fmt.bufPrint(&buf, "$c${d}", .{c.depth}) catch unreachable;
        const base = try l.interner.getOrPut(l.gpa, spelled);
        return l.name(.{ .module = .none, .base = base, .tag = JsIr.Name.no_tag });
    }

    fn blockStmt(l: *Lowerer, label: JsIr.NameIndex, body: []const Node.Index, p: u32) !Node.Index {
        const range = try l.b.addRange(body);
        const record = try l.b.addRecord(range);
        return l.add(.block_stmt, p, @intFromEnum(label), @intFromEnum(record));
    }

    /// The `break $c$<d>` on the textually last leaf is omitted (§7): there
    /// is nothing below it to skip. Only at the top level of the block — a
    /// `break` inside a `switch` case is what keeps it from falling through
    /// and is never dead.
    fn trimTrailingBreak(l: *Lowerer, out: *StmtList, label: JsIr.NameIndex) void {
        if (out.items.len == 0) return;
        const last = out.items[out.items.len - 1];
        if (l.b.nodes.items(.tag)[last.int()] != .break_stmt) return;
        if (l.b.nodes.items(.data)[last.int()].lhs != @intFromEnum(label)) return;
        _ = out.pop();
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
        .types = &session.checked.types,
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
    // The scrutinee keeps no temporary of its own: §7 binds it only when
    // the tree reads it more than once, and a two-alternative boolean node
    // reads it once.
    try expectJs(
        \\const M$pick = (a$1, b$2) => a$1 && b$2 ? 1 : 2;
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
        \\const M$Box$$order = { Some: 0, None: 1 };
        \\const M$Box$$compare = ($x, $y) => {
        \\  if ($x.$ !== $y.$) {
        \\    return M$Box$$order[$x.$] < M$Box$$order[$y.$] ? "LT" : "GT";
        \\  }
        \\  switch ($x.$) {
        \\    case "Some":
        \\      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
        \\    default:
        \\      return "EQ";
        \\  }
        \\};
        \\const M$Box$$eq = ($x, $y) => {
        \\  if ($x.$ !== $y.$) {
        \\    return false;
        \\  }
        \\  switch ($x.$) {
        \\    case "Some":
        \\      return $x.a === $y.a;
        \\    default:
        \\      return true;
        \\  }
        \\};
        \\const M$some = { $: "Some", a: 1 };
        \\const M$none = { $: "None", a: null };
        \\const M$unwrap = (v$1) => {
        \\  if (v$1.$ === "Some") {
        \\    const n$2 = v$1.a;
        \\    return n$2;
        \\  } else {
        \\    return 0;
        \\  }
        \\};
        \\export { M$Box$$compare, M$Box$$eq, M$some, M$none, M$unwrap };
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
        \\const M$Colour$$order = { Red: 0, Green: 1 };
        \\const M$Colour$$compare = ($x, $y) => {
        \\  const $a = M$Colour$$order[$x];
        \\  const $b = M$Colour$$order[$y];
        \\  return $a === $b ? "EQ" : $a < $b ? "LT" : "GT";
        \\};
        \\const M$Colour$$eq = ($x, $y) => $x === $y;
        \\const M$first = "Red";
        \\const M$isRed = (c$1) => c$1 === "Red" ? true : false;
        \\const M$yes = true;
        \\export { M$Colour$$compare, M$Colour$$eq, M$first, M$isRed, M$yes };
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

test "two nested loops each own their $in$ slots, so the inner shadows the outer" {
    // `backend.md` §8: the label is the function's own emitted name and the
    // slot names are parameter POSITIONS, so a `let`-bound looping function
    // inside a looping declaration uses `$in$0` twice. That is safe
    // precisely because neither ever reads the other's — the inner slots are
    // the inner function's own parameters and shadow the outer ones — and a
    // shape that got this wrong would be an infinite loop, not a diff.
    //
    // The corpus proves the ANSWER (`run/TailCallLetFunction.beni`); what is
    // here is the shape claim that no `run/` fixture can separate from it.
    try expectJs(
        \\import { Basics$sub, Basics$add } from "./Basics.mjs";
        \\const M$outer = ($in$0, $in$1) => {
        \\  M$outer: while (true) {
        \\    const n$1 = $in$0;
        \\    const acc$2 = $in$1;
        \\    if (n$1 < 1) {
        \\      return acc$2;
        \\    } else {
        \\      function inner$3($in$0, $in$1) {
        \\        inner$3: while (true) {
        \\          const i$4 = $in$0;
        \\          const total$5 = $in$1;
        \\          if (i$4 < 1) {
        \\            return total$5;
        \\          } else {
        \\            $in$0 = Basics$sub(i$4, 1);
        \\            $in$1 = Basics$add(total$5, 1);
        \\            continue inner$3;
        \\          }
        \\        }
        \\      }
        \\      $in$0 = Basics$sub(n$1, 1);
        \\      $in$1 = inner$3(3, acc$2);
        \\      continue M$outer;
        \\    }
        \\  }
        \\};
        \\export { M$outer };
        \\
    ,
        \\pub outer : Int, Int -> Int
        \\outer n acc =
        \\    if n < 1 then
        \\        acc
        \\
        \\    else
        \\        let
        \\            inner i total =
        \\                if i < 1 then
        \\                    total
        \\
        \\                else
        \\                    inner (i - 1) (total + 1)
        \\        in
        \\        outer (n - 1) (inner 3 acc)
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
        .types = &session.checked.types,
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

    const constrained: Dispatch.Target = .{ .top = .{ .decl = @enumFromInt(0) } };
    const plain: Dispatch.Target = .{ .top = .{ .decl = @enumFromInt(1) } };
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

test "a derived function with no body is a table bug in value position, either kind" {
    // A SYNTHETIC `Dispatch` table, for the reason the test above gives and
    // one more: no beni program reaches this arm. The checker refuses `eq`
    // and `compare` on a type no module writes a body for before the
    // backend is ever asked (§3.3, A.54 —
    // `tests/corpus/check/bad/CompareOnTypeHoldingFunction` and
    // `check/bad/core/CompareOnWrappedForeign` are the fixtures), so a
    // target with no body can only come from a table the checker did not
    // write, and only a hand-built one can show what the emitter does with
    // it. That is why there is no corpus fixture beside this test.
    //
    // **What changed with S6b.** This used to assert A.51's door: a missing
    // `eq` whose parts were all structural was answered with
    // `core/Basics.js`'s walk instead of refused, because `List a` had no
    // `pub foreign eq` and that walk was the only thing that could answer
    // `xs == ys`. §5.2 gives `List` both methods, `equatable` is core's
    // alone so no other module can declare a `foreign type` that derives
    // without a body, and the door has no customer left. Both kinds are now
    // `internal` — nothing is MISSING, the table is WRONG — and the test
    // asserts that symmetry.
    const gpa = testing.allocator;
    const table: Dispatch = .{};
    const types: Types = .empty;
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();

    // Only the fields this path reads, exactly as the test above does: the
    // table, the type service `derivedBodyExists` asks, and what `report`
    // and `add` need.
    var l: Lowerer = undefined;
    l.gpa = gpa;
    l.b = &b;
    l.in.dispatch = &table;
    l.in.types = &types;
    l.in.module = @enumFromInt(0);
    l.diagnostics = .empty;
    l.part_depth = 0;
    l.region = @enumFromInt(0);
    defer {
        for (l.diagnostics.items) |d| gpa.free(d.message);
        l.diagnostics.deinit(gpa);
    }

    const compare: Dispatch.Target = .{ .ext_derived = .{
        .module = @enumFromInt(0),
        .type = .none,
        .kind = .compare,
    } };
    _ = try l.derivedValue(compare, Node.no_pos);
    try testing.expectEqual(@as(usize, 1), l.diagnostics.items.len);
    try testing.expectEqual(diagnostic.Code.internal, l.diagnostics.items[0].code);
    try testing.expect(std.mem.indexOf(
        u8,
        l.diagnostics.items[0].message,
        "a derived method of a type whose module emits no",
    ) != null);

    // A `derived` row that is not in the table at all: the same answer.
    const missing_eq: Dispatch.Target = .{ .derived = .{ .index = 0 } };
    _ = try l.derivedValue(missing_eq, Node.no_pos);
    try testing.expectEqual(@as(usize, 2), l.diagnostics.items.len);
    try testing.expectEqual(diagnostic.Code.internal, l.diagnostics.items[1].code);

    // And the `eq` that used to go through A.51's door — an `ext_derived`
    // with no parts, exactly what `core/Basics.js`'s walk answered — is
    // refused now like any other, which is the whole of the change.
    const was_bridged: Dispatch.Target = .{ .ext_derived = .{
        .module = @enumFromInt(0),
        .type = .none,
        .kind = .eq,
    } };
    _ = try l.derivedValue(was_bridged, Node.no_pos);
    try testing.expectEqual(@as(usize, 3), l.diagnostics.items.len);
    try testing.expectEqual(diagnostic.Code.internal, l.diagnostics.items[2].code);
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
