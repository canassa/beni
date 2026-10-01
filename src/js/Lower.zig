//! Typed `Bir` to `JsIr` (docs/design/backend.md §4): the mapping table of
//! §4, construct by construct.
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
//! now records under its corrections: `Basics.Bool` is a JavaScript
//! boolean, "nullary constructor is the bare tag" is split on whether the
//! TYPE has any payload at all, and `&&`/`||` are lowered here rather than
//! peepholed at print time because for those two it is the semantics and not
//! an optimisation. `CtorRep` and `logicalOp` carry the argument in full.
//!
//! **Positions.** Every node carries the byte offset of the token its `Bir`
//! instruction came from (§9.6). Maps are not written yet; the offsets are here
//! because retrofitting them means touching this file, the printer and
//! every pass between.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Bir = @import("../bir/Bir.zig");
const Decision = @import("Decision.zig");
const CtorEq = @import("CtorEq.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const JsIr = @import("JsIr.zig");
const Reach = @import("Reach.zig");
const Fields = @import("Fields.zig");
const Edges = @import("../check/Edges.zig");
const U32Set = @import("../u32_set.zig").U32Set;
const stamped = @import("../stamped.zig");
const Types = @import("../check/Types.zig");
const MarkupTree = @import("MarkupTree.zig");
const Suspend = @import("Suspend.zig");
const JsIntrinsic = @import("JsIntrinsic.zig");
const Operator = @import("Operator.zig");
const beni_markup = @import("beni_markup");

const Inst = Bir.Inst;
const Node = JsIr.Node;
const Symbol = InternPool.Symbol;

/// What lowering could not translate. Every construct of backend.md §4 is
/// implemented; the guard reports
/// rather than falling through, because an unhandled tag that silently
/// emitted nothing would be a program that compiles and computes the wrong
/// answer.
pub const Item = struct {
    code: diagnostic.Code,
    module: Graph.Index,
    region: Inst.Index,
    /// Where to report instead of `region`'s token: a markup node's own
    /// token, for what a markup lowering reports (`boundary.md` §9.4.7).
    token: ?u32 = null,
    /// Owned by the caller's allocator.
    message: []const u8,
};

pub const Result = struct {
    ir: JsIr,
    /// Owned; messages are gpa-owned.
    diagnostics: []const Item,
    /// Whether the module imports the engine from `Input.derived_runtime`,
    /// which the build then has to write (`derivedRuntime`).
    uses_runtime: bool = false,
    /// Whether the module imports the markup runtime (`boundary.md` §9.4.5).
    uses_markup_runtime: bool = false,
    /// The markup runtime's exports the module imports, by name, in the
    /// caller's scratch arena.
    markup_exports: []const []const u8 = &.{},
    /// The runtime exports the module took from the runtime module instead
    /// (`boundary.md` §9.2), by name, in the caller's scratch arena.
    markup_module_uses: []const []const u8 = &.{},
    /// The program start data the markup lowering contributed, in the
    /// caller's scratch arena.
    start: []const StartPair = &.{},
    /// Bindings the release optimiser keeps though nothing reads them
    /// (`let _ = <an impure call>`, transparent-effects-proposal.md §16.3),
    /// in the caller's scratch arena.
    effect_keep: []const Node.Index = &.{},
    /// Statements the release optimiser drops: those of a `let _ = e`
    /// whose `e` cannot have an effect (`Lowerer.discard`).
    pure_discards: []const Node.Index = &.{},
    /// The arrows of declarations whose result nothing reads
    /// (`Lowerer.findUnobserved`): the printer leaves out what they return
    /// (`backend.md` §4, *A result nothing reads*).
    unobserved: []const Node.Index = &.{},
    /// The names of the `Js.Ref` bindings written as a `let`
    /// (`Lowerer.findRefs`), in the caller's scratch arena: the release
    /// optimiser folds no read of one, since a write elsewhere may move it.
    mutable: []const JsIr.NameIndex = &.{},

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
const Convention = @import("../check/Convention.zig");

pub const Input = struct {
    bir: *const Bir,
    /// The module's token start offsets, for `Node.pos`.
    token_starts: []const u32,
    module: Graph.Index,
    graph: *const Graph,
    interfaces: []const Interface,
    /// What the checker decided about every method call of this module
    /// (static-dispatch-spike.md §7). Lowering reads it; what it cannot
    /// honour is REFUSED rather than emitted wrongly.
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
    /// **And one more field than a name service needs.**
    /// `derivedBodyExists` reads `Entry.kind` to answer whether the module
    /// that owns an `ext_derived` target actually emitted a body for it — a
    /// `foreign type` has no constructors and so no module wrote one (A.55,
    /// A.60); the rest is the owner's published row.
    /// After §5.2 no program can make
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
    /// a program's own modules call — the same reason a chunked build's
    /// `lazy` declarations will be exported from their chunks.
    entry_decl: ?u32 = null,
    /// `--release`: what JavaScript sees (`Fields.close`), which decides
    /// the types whose constructors have integer tags (`backend.md` §9,
    /// *Item 4, taken up*). Null in a development build: every tag is a
    /// string.
    boundary: ?*const Fields.Boundary = null,
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
    /// The specifier of `_core/_derived.mjs`, the one engine a build's derived
    /// comparisons continue in past the depth limit (`backend.md` §4,
    /// *Derived comparisons do not grow the native stack*), relative
    /// to THIS module's output file.
    derived_runtime: []const u8 = "./_core/_derived.mjs",
    /// The build's markup lowering (`boundary.md` §9.4), when it has one.
    markup: ?Markup = null,
    /// `--release`: a function of this module called from one place is
    /// written at that place (`backend.md` §9, *A function called once is
    /// written where it is called*).
    inline_once: bool = false,
    /// `--release`: a function whose result is `()` writes no result
    /// (`backend.md` §4, *A `()` result is not written*).
    unit_results: bool = false,
    /// What `Js.development` is: `false` under `--release` (`backend.md`
    /// §4, *`Js.development` is the build's mode*).
    development: bool = true,
};

pub const Markup = struct {
    lowering: *const beni_markup.Lowering,
    /// The vocabulary module's interface, whose rows the dispatch table's
    /// markup section indexes.
    vocabulary: *const Interface,
    /// The markup runtime's specifier, relative to this module's output
    /// file.
    runtime: []const u8,
    build: beni_markup.Build,
    /// The runtime module (`boundary.md` §9.2, *A runtime module*), and the
    /// runtime exports it supplies in the file's place.
    module: ?Graph.Index = null,
    supplied: []const Supplied = &.{},

    /// A runtime export the module supplies: its name, its declaration in
    /// the module, and its row among the module's interface values.
    pub const Supplied = struct { name: []const u8, decl: u32, value: u32 };
};

/// Lower one checked module. `scratch` is the caller's arena — every
/// intermediate list below lives in it and nothing here frees individually.
/// `interner` is this module's overlay on the session's pool: the names
/// lowering invents (`$m$3`, `Main$eq$Point`) go into it and never into the
/// shared pool, which is what lets several modules lower at once. It is read
/// for the field-order sort, and the printer reads it to spell every name.
pub fn lower(
    gpa: Allocator,
    scratch: Allocator,
    interner: *InternPool.Overlay,
    input: Input,
) Allocator.Error!Result {
    var b: JsIr.Builder = .init(gpa);
    // `toOwned` hands the columns over and leaves the lists empty, so this
    // frees the name-dedup table and, on the failure path, everything else.
    defer b.deinit();
    try b.reserve(input.bir.insts.len);

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
            .push = try interner.getOrPut(gpa, "push"),
            .length = try interner.getOrPut(gpa, "length"),
        },
    };
    defer l.diagnostics.deinit(gpa);
    errdefer for (l.diagnostics.items) |d| gpa.free(d.message);
    try l.readTable();
    try l.findDeadArms();
    try l.findUnobserved();
    try l.findRefs();
    try l.findInlines();

    // Declarations first: the import list is what lowering DISCOVERS (the
    // §9.1 reference edges are a byproduct of resolution, not a pass), so
    // the statements that name those imports can only be built once every
    // body has been walked. They are then spliced in front, because an ES
    // module reads top to bottom and a reader wants the imports first.
    // The markup lowering's `module` runs before any root (`boundary.md`
    // §9.4.3), so what it hoists is known before the first declaration.
    try l.beginMarkup();
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
    // The nullary constructors' constants, after every body and every
    // synthesised value that could name one has been built, and in front of
    // all of them (`backend.md` §4, *A nullary constructor is one object*).
    const nullary = try l.nullaryDecls();

    var body: std.ArrayList(Node.Index) = .empty;
    try body.appendSlice(scratch, import_statements);
    try body.appendSlice(scratch, nullary);
    // What the markup lowering hoisted: after the imports, before the first
    // declaration, in hoist order (`backend.md` §15.1).
    if (l.mk) |st| try body.appendSlice(scratch, st.hoisted.items);
    try body.appendSlice(scratch, synthesised);
    try body.appendSlice(scratch, declarations.items);

    const range = try b.addRange(body.items);
    const ir = try b.toOwned(range);
    const diagnostics = try l.diagnostics.toOwnedSlice(gpa);
    return .{
        .ir = ir,
        .diagnostics = diagnostics,
        .uses_runtime = l.needs.deep or l.needs.list_eq or l.needs.list_compare,
        .uses_markup_runtime = l.markup_imports.items.len != 0,
        .markup_exports = l.markup_exports.items,
        .markup_module_uses = l.markup_module_uses.items,
        .start = if (l.mk) |st| st.start.items else &.{},
        .effect_keep = l.effect_keep.items,
        .pure_discards = l.pure_discards.items,
        .unobserved = l.unobserved_arrows.items,
        .mutable = l.mutable_names.items,
    };
}

/// Intern into the session's pool, before any module is lowered, every
/// name lowering spells from a fixed string: `WellKnown`'s, the slot names
/// `a` to `z`, and the rest below. A lowering then finds each of them there
/// instead of adding it to its module's overlay, which is one insertion per
/// name per module saved. What a name is interned as reaches no output.
pub fn internFixedNames(gpa: Allocator, global: *InternPool.Global) Allocator.Error!void {
    const fixed = [_][]const u8{
        "$t", "$x", "$p", "$",  "$y", "$a",    "$b",       "codePointAt", "push",     "length",
        "$l", "$h", "$d", "$e", "$m", "apply", "_derived", "$markup",     "children",
    };
    for (fixed) |text| _ = try global.getOrPut(gpa, text);
    inline for (@typeInfo(Lowerer.Runtime).@"enum".fields) |field| _ = try global.getOrPut(gpa, field.name);
    for (0..26) |i| _ = try global.getOrPut(gpa, &.{@as(u8, 'a') + @as(u8, @intCast(i))});
    // Whether the names above grew the pool depends on the program; a
    // safety build always moves it, so a slice of it the emitter kept from
    // before fails in every test rather than in the rare one that fills it.
    try global.moveBytesForSafety(gpa);
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
    /// `push`: a building loop's destination is a plain array the loop
    /// pushes its heads onto (§8, *Tail calls modulo cons, onto an array*).
    push: Symbol,
    /// `length`: what a list pattern tests (§7, *List patterns over
    /// arrays*), the one field every form of a list answers.
    length: Symbol,
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
///  3. **`List` is array-backed** (§4, *Lists are arrays*): a literal is an
///     array literal, and everything else about a list — views, tries — is
///     `core/List.js`'s. `List` is a `foreign type`, so it has no beni
///     constructors, and it is not a `CtorRep` at all.
const CtorRep = union(enum) {
    /// `Basics.Bool`.
    boolean: bool,
    /// Every constructor of the type is nullary: the bare tag string, or
    /// under `--release` the constructor's declaration index when the type
    /// has integer tags (`backend.md` §9, *Item 4, taken up*).
    bare_tag: Tag,
    /// `{$: "Tag", a, b, …}`, padded to `fields` slots; `$` is `int` when
    /// the type has integer tags.
    tagged: struct { fields: u32, int: Tag = null },
    /// A record alias's implicit constructor (backend.md §4's row, the
    /// owner's decision): the RECORD it builds, keys sorted by name text as
    /// every record literal's are (`recordNode`), and no tag. A pattern over
    /// it reads the fields by name (`argMember`). Where the names come from
    /// is `RecordRep`'s.
    record: RecordRep,

    /// A constructor's declaration index when its type's tags are
    /// integers, else null and the tag is its name.
    const Tag = ?u32;

    fn int(rep: CtorRep) Tag {
        return switch (rep) {
            .bare_tag => |t| t,
            .tagged => |t| t.int,
            .boolean, .record => null,
        };
    }
};

/// Where a record alias's field names are read, in argument order.
const RecordRep = union(enum) {
    /// This module's alias declaration, whose body is the `type_record`
    /// that names the fields.
    local: u32,
    /// Another module's: its interface constructor row, which carries the
    /// names since interface v3 (`checker-v2.md` §14.2) — the
    /// declaring module's Bir is not this backend's to read.
    imported: struct { module: Graph.Index, ctor: u32 },
};

const StmtList = std.ArrayList(Node.Index);

/// Which body of a declaration is being lowered (transparent-effects-
/// proposal.md §16.2).
const Variant = enum { direct, twin };

/// How many terms of a derived `&&` print as one flat run before the next
/// run starts inside parentheses (`backend.md` §4): the JavaScriptCore of
/// WebKit loads 53 620 flat terms and no more, and a derived `eq` has one
/// term per field — 65 535 at most.
const derived_group = 1024;

/// How deep a derived `eq` or `compare` recurses on the native stack before
/// it continues from an explicit one (`backend.md` §4, *Derived comparisons
/// do not grow the native stack*). One unit is one hop from a
/// derived body to the comparison it calls — a derived function, an
/// evidence closure, `List.eq` — and costs a few hundred bytes of stack;
/// 400 of them stay well inside the scarcest engine's default stack while
/// leaving the program that asked for the comparison most of it.
const derived_depth_limit = "400";

/// The depth argument that means "do not compare: hand back your steps"
/// (`deep`'s request). Any depth at or past it is one, so a forwarder that
/// adds its weight to it still asks; no real depth comes near. Spelled as
/// `src/js/derived_runtime.mjs` spells it, because the two must agree.
const derived_request = "2**30";

/// A derived function whose frame is wide — positional evidence in the
/// thousands (`Convention.derivedEvidence`) — charges its callees one unit
/// per this many evidence parameters on top of the one every hop costs,
/// so a type of 4 096 parameters reaches the explicit stack after a few
/// levels and not after 400 (static-dispatch-spike.md §9.2's measurements:
/// a 4 096-parameter frame recursed 13 deep on Node's default stack).
const derived_weight_per = 32;

/// The most evidence parameters a derived function's STEPS form takes one by
/// one, and the most arguments one of its calls passes that way: past it
/// they travel as one array, because a generator saves its whole frame at
/// every `yield` (`derivedForm`, `depthCall`).
const steps_positional = 16;

/// How many `case`s — the outermost, and each nested in the LAST branch of the
/// one before (every `if` of an `else if` chain) — an expression-position
/// chain needs before it is written as one flat block (`Lowerer.chainedLeaf`,
/// `backend.md` §4). Each `if` of the nested form is a block that declares a
/// temporary, which is a scope; 16 of them are an eighth of
/// `nesting.scope_budget`. Shorter chains keep the nested form they always had.
const chain_min = 16;

/// The most `case` labels one `switch` is written with.
/// SpiderMonkey — Firefox and its shell alike — refuses a `switch` of more
/// than 65 046 (`backend.md` §4's table), and every other engine measured
/// takes 300 000; this is four times under the one that refuses. A fan with
/// more labels is written as consecutive `switch`es over the same
/// discriminant (`emitFan`): every case body leaves, so a value no label of
/// one `switch` names falls through to the next, and only the last carries
/// the `default:`. They follow one another, so nothing nests deeper.
const max_switch_cases = 16_384;

/// How many closures deep an evidence value may nest before it is bound to a
/// `const` (`Lowerer.hoistEvidence`, `backend.md` §4): each is a call inside
/// an arrow, `(x, y) => List$eq(<next>, x, y)`, about 11 of `nesting`'s
/// units, so 20 of them are under `nesting.spill`.
const evidence_spill = 20;

/// How tall a lambda's body may be before the closure is bound to a `const`
/// where it is made (`backend.md` §4): half of `nesting.spill`, so a lambda
/// nested in a lambda never carries more than that into its parent. Making a
/// closure evaluates nothing, so the binding moves nothing (`onlyClosures`).
const lambda_spill = 128;

const Lowerer = struct {
    gpa: Allocator,
    scratch: Allocator,
    b: *JsIr.Builder,
    interner: *InternPool.Overlay,
    in: Input,
    bir: *const Bir,
    module_name: Symbol,
    well: WellKnown,
    /// The last record alias `recordNames` answered for, and its names: a
    /// pattern reads its arguments one `argName` at a time, and computing
    /// the names once per argument would make a k-field pattern O(k²)
    /// scratch. The slice lives in `scratch`, which outlives the
    /// module's lowering.
    record_names: ?struct { rep: RecordRep, names: []const Symbol } = null,
    diagnostics: std.ArrayList(Item) = .empty,
    /// Names the module has to import from another module, in first-use
    /// order so the import list is a function of the source.
    needed: std.ArrayList(Needed) = .empty,
    /// The declaration being lowered: what a `local`'s index is relative to.
    decl_index: ?u32 = null,
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
    /// The padded nullary constructors this module has written in value
    /// position, each one module-level constant (`backend.md` §4, *A
    /// nullary constructor is one object*). Discovered like `needs`, so
    /// only a surviving body's constructors are written; keyed by the
    /// constructor, in `scratch`.
    nullary: std.AutoArrayHashMapUnmanaged(NullaryKey, Nullary) = .empty,
    /// How many `case` instructions of the function being lowered enclose
    /// the one being lowered now: the `<d>` of §7's `$j$<d>$<b>` and
    /// `$c$<d>` labels. It is reset at every function boundary, because a
    /// `break` cannot cross one and an inner function's labels are a fresh
    /// set — which is what keeps the names structural rather than a counter
    /// (CLAUDE.md rule 5).
    case_depth: u32 = 0,
    /// The body roots of the `case` arms no value can take: each names a
    /// constructor elimination did not reach (`backend.md` §9, *A `case`
    /// arm on a constructor nothing builds*). Lowered as `undefined`.
    /// Empty when there is none, which is every module of most builds.
    dead_arms: std.DynamicBitSetUnmanaged = .{},
    /// The body roots of the arms an `if Js.maySuspend f` drops in one
    /// body of a declaration and not in the other (`backend.md` §4,
    /// *`Js.maySuspend` is the body's answer*): `Reach` followed nothing out
    /// of them for that body. Indexed by `Variant`.
    probe_dead: [2]std.DynamicBitSetUnmanaged = .{ .{}, .{} },
    /// The instruction being lowered, for a diagnostic raised by something
    /// that has no instruction of its own — the synthesised references of
    /// §9.1, and `partEq`'s `err` arm. It is the INNERMOST instruction
    /// reached, not a span the reader chose, which is why only `internal`
    /// uses it.
    region: Inst.Index = @enumFromInt(0),
    /// Set while the body of a WIDE derived function is lowered
    /// (`Convention.derivedEvidence`): its one evidence parameter, the
    /// array `$m`, which `$m$k` then reads as `$m[k]` (static-dispatch
    /// §9.2).
    wide_evidence: ?JsIr.NameIndex = null,
    /// Set while the body of a derived function is lowered: which of its
    /// two forms is being built, and whether the direct one calls anything
    /// that takes a depth (`backend.md` §4, *Derived comparisons do not
    /// grow the native stack*).
    derived_body: ?*DerivedBody = null,
    /// The index of the derived row being lowered (`selfLoopParts`).
    derived_row: ?u32 = null,
    /// Per derived row of this module, whether it is a LEAF (`leafRows`):
    /// it cannot recurse, so it is emitted directly, with no depth, and a
    /// call of it passes no depth.
    leaf: []const bool = &.{},
    /// Where a tall evidence closure is bound (`hoistEvidence`): the
    /// statement list of the expression being lowered, set by `expr` and
    /// `tailStmts`. Null while a derived function's body is built, whose
    /// evidence is one level of its own type deep.
    evidence_out: ?*StmtList = null,
    /// The tallest expression lowered so far inside the one `expr` is
    /// lowering, in `nesting`'s units (`expr`).
    expr_height: u32 = 0,
    /// The same for an evidence term, in closures (`termValues`).
    term_depth: u32 = 0,
    /// Per term of the table, whether more than one owner names it: a table
    /// may SHARE a term (checker-v2.md §13.1). A shared
    /// evidence closure is bound to a `const` once and read by name
    /// (`termValues`), so the JavaScript of `==` on a type that is a doubling
    /// DAG is linear in its distinct nodes.
    shared: []const bool = &.{},
    /// Per term, whether it and everything below it add up
    /// (`termShapeOk`), judged once, bottom-up.
    shape_ok: []const bool = &.{},
    /// Per term, whether every derived term at or below it has a body
    /// (`derivedBodiesExist`), judged once, bottom-up.
    bodies_ok: []const bool = &.{},
    /// The shared terms already bound in `bound_out`, by term index: a
    /// column over the table's terms, emptied by one increment when the
    /// statement list changes.
    bound: stamped.Column(u32, JsIr.NameIndex) = .{},
    bound_out: ?*StmtList = null,
    /// `slotName`'s answers by slot, interned once: a wide constructor
    /// asks for each of its slots per use and per derived position.
    slot_names: std.ArrayList(Symbol.Optional) = .empty,
    /// The three primitive comparators' names (`primitiveValue`), interned
    /// the first time: a wide type names one per evidence slot.
    prim_names: [3]JsIr.NameIndex = @splat(.none),
    /// `apply`, interned the first time a steps form spreads a call.
    apply_symbol: Symbol.Optional = .none,
    /// This module's markup, while a lowering compiles it.
    mk: ?*MarkupState = null,
    /// Which body of the declaration being lowered this is
    /// (transparent-effects-proposal.md §16.2): the direct one, where a
    /// `poly` answer is no, or the suspendable one, `<name>$s`, where it is
    /// yes.
    variant: Variant = .direct,
    /// The function being lowered is in the suspendable form (§16.3): a
    /// call that may suspend is a marker for `Suspend` to split at.
    suspendable: bool = false,
    /// How many markers the function being lowered has written.
    markers: u32 = 0,
    /// The join a non-tail `case` of a suspendable function sends its leaves
    /// to (§16.3), or `.none`: `tailReturn` writes `return $j(value)`.
    join: JsIr.NameIndex = .none,
    /// `--release`: the name the next `case` in expression position writes
    /// its value into instead of a temporary of its own — a `let`
    /// binding's, declared by that `case` when `declare` says so, or the
    /// temporary of the `case` whose leaf it is (`backend.md` §9, *Compact
    /// statements*). `caseExpr` takes it on entry, so no `case` nested in
    /// its scrutinee or its leaves sees it.
    case_into: struct { name: JsIr.NameIndex = .none, declare: bool = false } = .{},
    /// `--release`: the `let` binding of local `local` is written as an
    /// assignment of `name`, which it then is — the temporary of the `case`
    /// whose leaf ends in a read of it (`leafBody`).
    bind_into: struct { local: u32 = std.math.maxInt(u32), name: JsIr.NameIndex = .none } = .{},
    /// The two core values the suspendable form calls, imported the first
    /// time a function needs them.
    fiber_names: ?Suspend.Names = null,
    /// Which body a dispatch target named now takes: the choice of the site
    /// whose callee and evidence are being lowered (§16.2).
    term_choice: Dispatch.Suspend = .no,
    /// The bindings of `let _ = <an impure call>` the release optimiser must
    /// not drop, though nothing reads them (§16.3).
    effect_keep: std.ArrayList(Node.Index) = .empty,
    /// The statements of a `let _ = e` whose `e` cannot have an effect
    /// (`discard`): evaluated by a development build, dropped by the
    /// release optimiser.
    pure_discards: std.ArrayList(Node.Index) = .empty,
    /// Per declaration: whether nothing reads what a call of it returns
    /// (`findUnobserved`).
    unobserved: []bool = &.{},
    unobserved_arrows: std.ArrayList(Node.Index) = .empty,
    /// The `Js.Ref` bindings written as a plain `let` (`findRefs`;
    /// `backend.md` §4, *A `Js.Ref` that does not escape is a `let`*): per
    /// local of the module, indexed from its declaration's `locals_start`,
    /// and per declaration.
    unboxed_locals: []bool = &.{},
    unboxed_tops: []bool = &.{},
    /// The JavaScript names of those bindings. A read of one is not an
    /// atom (`isAtom`): a write may come between it and where it lands.
    mutable_names: std.ArrayList(JsIr.NameIndex) = .empty,
    /// Per declaration: a function called from one place, written there
    /// under `--release` (`findInlines`), and whether a call took it in.
    inline_candidate: []bool = &.{},
    inlined: []bool = &.{},
    /// Per declaration: a candidate that calls itself, in tail position
    /// only, and so is written in place as its loop, where its call is in
    /// tail position of a function that is no loop.
    inline_loops: []bool = &.{},
    /// The declarations whose bodies are being written in place, innermost
    /// last: none is written inside itself.
    inline_stack: std.ArrayList(u32) = .empty,
    /// Added to a local's disambiguator (`localName`): 0 for the
    /// declaration's own, past every local already named for a body
    /// written in place, so two declarations' `x$1` never meet in one
    /// function. `local_tag_next` is the next free base.
    local_tag_base: u32 = 0,
    local_tag_next: u32 = 0,
    /// How many functions enclose what is being lowered: 0 in a top-level
    /// constant, where a body written in place would need a called arrow.
    function_depth: u32 = 0,
    /// Per local: whether any instruction reads it (`localRead`), made the
    /// first time a list pattern asks whether its tail is read.
    read_locals: ?std.DynamicBitSetUnmanaged = null,
    /// The declaration `read_locals` is of: a body written in place
    /// (`enterInline`) switches the locals under it.
    read_locals_decl: u32 = std.math.maxInt(u32),
    /// The list locals of the loops being lowered that hold an OFFSET into
    /// a base array rather than a list (§8, *Scalar views*), innermost
    /// last: each loop's parameters that the rule applies to, and every
    /// `rest` a pattern binds of them.
    scalars: std.ArrayList(Scalar) = .empty,
    /// The `local` instructions written as the offset they hold, not
    /// built into a list: a tail self-call's argument to its own slot, and
    /// the scrutinee of a `case` on one.
    scalar_raw: std.ArrayList(Inst.Index) = .empty,
    /// Per local of `list_binds_decl`: where a list pattern binds it — the
    /// pattern, the item's index, and whether it is the spread — for §7's
    /// re-consing rule (`reconsOf`), made the first time a call asks.
    list_binds: []?ListBind = &.{},
    list_binds_decl: u32 = std.math.maxInt(u32),
    /// The markup runtime's exports this module imports, in first-use
    /// order: the lowering's and the markup primitives'.
    markup_imports: std.ArrayList(JsIr.Specifier) = .empty,
    /// The same exports by name, for `--release`'s cut of the runtime
    /// file to what the build imports (`backend.md` §9).
    markup_exports: std.ArrayList([]const u8) = .empty,
    /// The runtime exports this module took from the runtime module
    /// (`markupRuntime`), by name, in first-use order.
    markup_module_uses: std.ArrayList([]const u8) = .empty,

    /// A constructor, this module's (`ext` false: a `Bir.ctors` index) or
    /// another's (an interface constructor row of `module`).
    const NullaryKey = struct { ext: bool, module: u32, ctor: u32 };

    /// One nullary constructor's constant: its name, and the object it holds.
    const Nullary = struct {
        base: []const u8,
        name: JsIr.NameIndex,
        rep: CtorRep,
        tag: Symbol,
    };

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
        /// The exports of `_core/_derived.mjs` this module imports
        /// (`runtimeImport`): the engine a derived function past
        /// `derived_depth_limit` continues in, and `List`'s two loops.
        deep: bool = false,
        list_eq: bool = false,
        list_compare: bool = false,
    };

    /// One derived function being lowered (`derivedArrow`).
    const DerivedBody = struct {
        /// `direct` is the function every caller calls; `steps` is its
        /// generator twin, `function* <base>$$steps`, which yields each call
        /// it would have made to the engine (`_derived$deep`) instead of making it.
        /// `forward` is the direct form of a FORWARDER, a function whose
        /// every depth-taking call is in tail position: it has no steps and
        /// no prologue, and hands a tail call past the limit to the engine as
        /// a request (`forwardTail`).
        mode: enum { direct, forward, steps } = .direct,
        /// The direct and forward forms' depth-taking calls, by node.
        calls: U32Set = .{},
        /// How many depth-taking calls the direct form made, and how many
        /// of them it returned (`derivedReturn`): equal makes a forwarder.
        depth_calls: u32 = 0,
        tail_calls: u32 = 0,
        /// `$d`, the direct form's depth parameter.
        depth: JsIr.NameIndex,
        /// What a call from this body adds to the depth.
        weight: u32,
        /// `weight` as its decimal text, spelled once for every call.
        weight_text: []const u8 = "",
        /// Whether the direct form made a call that takes a depth. A body
        /// that made none — every position a primitive, or a hand-written
        /// method — cannot recurse and is emitted exactly as before.
        passes: bool = false,
        /// The printed base of the function, `<base>$$steps` its twin's.
        base: []const u8,
        /// How many leading parameters the direct form packs into one array
        /// when it calls its steps (`steps_positional`); 0 for none.
        pack: u32 = 0,
        /// `$e`, the steps form's one temporary (`awaitRequest`), once used.
        temp: ?JsIr.NameIndex = null,
        /// The steps form's requests (`depthCall`), by node.
        requests: U32Set = .{},
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
        return l.b.addParts(tag, p, lhs, rhs);
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

    /// A beni record's field, as a key or a read: the name carries
    /// `Name.field`, which is what `--release` renames and nothing else is
    /// (`backend.md` §9, *Item 4, taken up*). A development build prints it
    /// as its text, exactly as a plain name.
    fn fieldName(l: *Lowerer, field: Symbol) !JsIr.NameIndex {
        return l.name(.{ .module = .none, .base = field, .tag = JsIr.Name.field });
    }

    fn fieldMember(l: *Lowerer, target: Node.Index, field: Symbol, p: u32) !Node.Index {
        return l.add(.member, p, target.int(), @intFromEnum(try l.fieldName(field)));
    }

    fn fieldProperty(l: *Lowerer, key: Symbol, value: Node.Index, p: u32) !Node.Index {
        return l.add(.property, p, @intFromEnum(try l.fieldName(key)), value.int());
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
        if (index < l.slot_names.items.len) {
            if (l.slot_names.items[index].unwrap()) |known| return known;
        } else try l.slot_names.appendNTimes(l.scratch, .none, index + 1 - l.slot_names.items.len);
        const symbol = try l.spellSlot(index);
        l.slot_names.items[index] = symbol.toOptional();
        return symbol;
    }

    fn spellSlot(l: *Lowerer, index: u32) !Symbol {
        var buf: [16]u8 = undefined;
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
    /// A lambda never has evidence parameters: it reads its enclosing
    /// declaration's `$m$k`, and any enclosing `let`'s `$l<inst>$<k>`
    /// (`letEvidenceName`), by ordinary lexical capture.
    fn evidenceName(l: *Lowerer, k: u32) !JsIr.NameIndex {
        var buf: [16]u8 = undefined;
        const spelled = std.fmt.bufPrint(&buf, "$m${d}", .{k}) catch unreachable;
        const base = try l.interner.getOrPut(l.gpa, spelled);
        return l.name(.{ .module = .none, .base = base, .tag = JsIr.Name.no_tag });
    }

    /// `$l<inst>$<k>`: the k-th evidence parameter of the `let` function
    /// binding generalised at `let_def` `inst` (checker-v2.md §8.4,
    /// backend.md §4). The instruction makes it unique in the
    /// declaration, so an inner binding never shadows an outer name a
    /// closure inside it also captures.
    fn letEvidenceName(l: *Lowerer, inst: Inst.Index, k: u32) !JsIr.NameIndex {
        var buf: [32]u8 = undefined;
        const spelled = std.fmt.bufPrint(&buf, "$l{d}${d}", .{ inst.int(), k }) catch unreachable;
        const base = try l.interner.getOrPut(l.gpa, spelled);
        return l.name(.{ .module = .none, .base = base, .tag = JsIr.Name.no_tag });
    }

    /// The k-th evidence parameter of a declaration (`ev_let` none) or of
    /// the `let` function binding at `ev_let`.
    fn evidenceNameOf(l: *Lowerer, ev_let: Inst.OptionalIndex, k: u32) !JsIr.NameIndex {
        const inst = ev_let.unwrap() orelse return l.evidenceName(k);
        return l.letEvidenceName(inst, k);
    }

    /// `$in$<i>`: the loop slot of the i-th parameter of a function that
    /// has a tail self-call (`backend.md` §8), *i* counting evidence
    /// first. Positional and never a counter, so two nested loops both
    /// using `$in$0` are safe — neither ever reads the other's — and the
    /// name is a function of the source and not of thread timing
    /// (CLAUDE.md rule 5).
    fn inSlotName(l: *Lowerer, index: u32) !JsIr.NameIndex {
        var buf: [16]u8 = undefined;
        return l.fixedName(std.fmt.bufPrint(&buf, "$in${d}", .{index}) catch unreachable);
    }

    /// `<Module>$<base>` for a value this module SYNTHESISES rather than
    /// declares (§8.5): the primitive comparators of §9.1 and the
    /// derived functions of §9.
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

    /// Every `case` arm of the module whose pattern names a constructor
    /// elimination did not reach, by its body's root (`backend.md` §9, *A
    /// `case` arm on a constructor nothing builds*). `Reach` follows an
    /// edge inside an arm only when every constructor of the arm's pattern
    /// was reached, so the arms left out here are exactly the ones whose
    /// names may be gone — and ones whose names are all there too, which
    /// no value takes either.
    fn findDeadArms(l: *Lowerer) !void {
        const tags = l.bir.insts.items(.tag);
        const data = l.bir.insts.items(.data);
        // The arm of an `if Js.development` the build does not take
        // (`backend.md` §4, *`Js.development` is the build's mode*): `Reach`
        // followed nothing out of it, with or without a survivor set.
        for (tags, 0..) |tag, i| {
            if (tag != .case) continue;
            const branch = JsIntrinsic.droppedArm(l.in.graph, l.in.interfaces, l.bir, @enumFromInt(@as(u32, @intCast(i))), l.interner, !l.in.development) orelse continue;
            const body = l.bir.instData(branch).rhs;
            if (l.dead_arms.bit_length == 0) try l.dead_arms.resize(l.scratch, l.bir.insts.len, false);
            if (body < l.dead_arms.bit_length) l.dead_arms.set(body);
        }
        // The arm an `if Js.maySuspend f` drops, per body: `True`'s where the
        // answer is no there, `False`'s where it is yes.
        for (tags, 0..) |tag, i| {
            if (tag != .case) continue;
            const case_inst: Inst.Index = @enumFromInt(@as(u32, @intCast(i)));
            const probe = JsIntrinsic.probeCall(l.in.graph, l.in.interfaces, l.bir, case_inst, l.interner) orelse continue;
            const answer = l.in.dispatch.effectAt(probe).body;
            for ([_]Variant{ .direct, .twin }) |variant| {
                const taken = answer == .yes or (answer == .poly and variant == .twin);
                const branch = JsIntrinsic.armOf(l.in.graph, l.in.interfaces, l.bir, case_inst, l.interner, !taken) orelse continue;
                const body = l.bir.instData(branch).rhs;
                const set = &l.probe_dead[@intFromEnum(variant)];
                if (set.bit_length == 0) try set.resize(l.scratch, l.bir.insts.len, false);
                if (body < set.bit_length) set.set(body);
            }
        }
        const r = l.in.live orelse return;
        for (tags, data) |tag, d| {
            if (tag != .branch) continue;
            if (!l.patternDead(r, @enumFromInt(d.lhs), 0)) continue;
            if (l.dead_arms.bit_length == 0) try l.dead_arms.resize(l.scratch, l.bir.insts.len, false);
            if (d.rhs < l.dead_arms.bit_length) l.dead_arms.set(d.rhs);
        }
    }

    /// Whether `pattern` names, at any depth, a constructor this build
    /// never builds. `core`'s are always reached.
    fn patternDead(l: *Lowerer, r: *const Reach.Result, pattern: Inst.Index, depth: u32) bool {
        if (depth > 64 or @intFromEnum(pattern) >= l.bir.insts.len) return false;
        const d = l.bir.instData(pattern);
        switch (l.bir.instTag(pattern)) {
            .pat_ctor => {
                const ref: Inst.Index = @enumFromInt(d.lhs);
                if (@intFromEnum(ref) < l.bir.insts.len) {
                    const rd = l.bir.instData(ref);
                    switch (l.bir.instTag(ref)) {
                        .ctor => if (!r.ctor(l.in.module, rd.lhs)) return true,
                        .ext_ctor => if (!r.extCtor(@enumFromInt(rd.lhs), rd.rhs)) return true,
                        else => {},
                    }
                }
                for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index)) |arg| {
                    if (l.patternDead(r, arg, depth + 1)) return true;
                }
                return false;
            },
            .pat_tuple, .pat_list => {
                for (l.bir.extraSlice(Bir.inlineRange(d), Inst.Index)) |e| if (l.patternDead(r, e, depth + 1)) return true;
                return false;
            },
            .pat_as => return l.patternDead(r, @enumFromInt(d.lhs), depth + 1),
            else => return false,
        }
    }

    /// The arm an `if Js.maySuspend f` drops in the body being written
    /// (`backend.md` §4, *`Js.maySuspend` is the body's answer*): `True`'s
    /// where the call's answer is no here, `False`'s where it is yes.
    fn probeDroppedArm(l: *Lowerer, inst: Inst.Index) ?Inst.Index {
        const probe = JsIntrinsic.probeCall(l.in.graph, l.in.interfaces, l.bir, inst, l.interner) orelse return null;
        const taken = l.suspendsHere(l.in.dispatch.effectAt(probe).body);
        return JsIntrinsic.armOf(l.in.graph, l.in.interfaces, l.bir, inst, l.interner, !taken);
    }

    /// The body of the arm an `if Js.development` takes in this build, when
    /// `inst` is one whose other arm binds nothing (`backend.md` §4,
    /// *`Js.development` is the build's mode*): the `case` is written as
    /// that body alone, with no test, and the dropped arm not at all.
    fn developmentArm(l: *Lowerer, inst: Inst.Index) ?Inst.Index {
        const dropped = JsIntrinsic.droppedArm(l.in.graph, l.in.interfaces, l.bir, inst, l.interner, !l.in.development) orelse
            l.probeDroppedArm(inst) orelse return null;
        const branches = l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(inst).rhs)), Inst.Index);
        for (branches) |branch| {
            if (branch == dropped) continue;
            const b = l.bir.instData(branch);
            switch (l.bir.instTag(@enumFromInt(b.lhs))) {
                .pat_ctor, .pat_wild => return @enumFromInt(b.rhs),
                else => return null,
            }
        }
        return null;
    }

    /// Whether `inst` is the body of an arm no value takes.
    fn deadArm(l: *const Lowerer, inst: Inst.Index) bool {
        const i = @intFromEnum(inst);
        if (i < l.dead_arms.bit_length and l.dead_arms.isSet(i)) return true;
        const probe = &l.probe_dead[@intFromEnum(l.variant)];
        return i < probe.bit_length and probe.isSet(i);
    }

    /// Whether a declaration's suspendable body survived (§16.2).
    fn liveTwin(l: *Lowerer, index: u32) bool {
        // No survivor set (a unit test): no suspendable body is asked for.
        const r = l.in.live orelse return false;
        return r.twin(l.in.module, index);
    }

    /// `<base>$s`, the base of a declaration's suspendable body
    /// (transparent-effects-proposal.md §16.2). `$` cannot appear in a beni
    /// name, so no declaration can be called that.
    fn twinBase(l: *Lowerer, base: Symbol) !Symbol {
        const spelled = try std.fmt.allocPrint(l.scratch, "{s}$s", .{l.text(base)});
        return l.interner.getOrPut(l.gpa, spelled);
    }

    /// The base the body being lowered is spelled with.
    fn variantBase(l: *Lowerer, base: Symbol) !Symbol {
        return switch (l.variant) {
            .direct => base,
            .twin => l.twinBase(base),
        };
    }

    /// `<Module>$<base>$s`.
    fn twinName(l: *Lowerer, module: Symbol, base: Symbol) !JsIr.NameIndex {
        return l.name(.{ .module = module.toOptional(), .base = try l.twinBase(base), .tag = JsIr.Name.no_tag });
    }

    /// A reference to this module's declaration `decl`, taking the body the
    /// answer `body` chooses (§16.2).
    fn topNameChoosing(l: *Lowerer, decl: u32, body: Dispatch.Suspend) !JsIr.NameIndex {
        if (!l.suspendsHere(body) or !l.in.dispatch.effectDecl(decl).twin) return l.topName(decl);
        const base = l.bir.symbol(l.bir.decls[decl].name);
        try l.requireLive(l.liveTwin(decl), l.text(base));
        return l.twinName(l.module_name, base);
    }

    /// The same for another module's value: its suspendable body is exported
    /// from its module under `<Module>$<base>$s`.
    fn externalNameChoosing(l: *Lowerer, module: Graph.Index, value: u32, body: Dispatch.Suspend) !JsIr.NameIndex {
        if (l.suspendsHere(body) and l.externalTwin(module, value)) {
            const iface = &l.in.interfaces[module.int()];
            const base = iface.symbols[@intFromEnum(iface.values[value].name)];
            const twin = try l.twinBase(base);
            if (std.debug.runtime_safety) if (l.in.live) |r| try l.requireLive(r.extTwin(module, value), l.text(base));
            try l.needName(.{ .module = module, .base = twin.toOptional() });
            return l.name(.{ .module = l.in.graph.moduleName(module).toOptional(), .base = twin, .tag = JsIr.Name.no_tag });
        }
        try l.need(module, value);
        return l.externalName(module, value);
    }

    /// Whether another module's value has a suspendable body: its effect
    /// block has a sensitive class (§16.2).
    fn externalTwin(l: *Lowerer, module: Graph.Index, value: u32) bool {
        if (module.int() >= l.in.interfaces.len) return false;
        const iface = &l.in.interfaces[module.int()];
        if (value >= iface.values.len) return false;
        const scheme = iface.values[value].scheme;
        if (scheme == .none) return false;
        const block = iface.effectBlock(iface.scheme(scheme)) orelse return false;
        return block.twin();
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
        // Every declaration is lowered where it stands, a function called
        // from one place (`findInlines`) too: whether its call takes it in
        // is known only once its caller is lowered, and lowering it here
        // first keeps every order lowering discovers — the imports, the
        // hoisted templates, the constants — exactly the one a build that
        // takes nothing in has. Its statements are left out afterwards when
        // a call did take it in; what they referenced, the body written in
        // place references too.
        const parts = try l.scratch.alloc([]const Node.Index, order.len);
        for (order, parts) |index, *part| part.* = try l.declarationPart(index);
        for (order, parts) |index, part| {
            if (index < l.inlined.len and l.inlined[index]) continue;
            try out.appendSlice(l.scratch, part);
        }
    }

    /// One declaration's statements, measured against the nesting budget.
    fn declarationPart(l: *Lowerer, index: u32) ![]const Node.Index {
        var part: StmtList = .empty;
        const nodes = l.b.nodes.len;
        try l.declaration(&part, index);
        // Fewer nodes than this cannot be over either budget, and
        // measuring is a walk of every node: most declarations skip it.
        if (l.b.nodes.len - nodes >= JsIr.nesting.could_exceed) try l.refuseTooDeep(part.items, index);
        return part.items;
    }

    /// The one nesting `Lower` cannot take out (`backend.md` §4, *Emitted
    /// JavaScript nests only as deep as the source*): scopes the source
    /// itself nests — a function in a function, a `case` inside a `case`'s
    /// branch — several hundred deep. Every chain the source writes flat is
    /// emitted flat and every tall expression is bound to a `const`, so what
    /// is left over `nesting.budget` is that, and JavaScript nests it as the
    /// source does. Refused by name rather than written: a module an engine
    /// will not parse is a `RangeError` at load, after `build` said yes.
    fn refuseTooDeep(l: *Lowerer, stmts: []const Node.Index, index: u32) !void {
        const h = try l.b.measure(l.gpa, stmts);
        if (h.whole <= JsIr.nesting.budget and h.scopes <= JsIr.nesting.scope_budget) return;
        const d = l.bir.decls[index];
        // A declaration with no body lowers to no statements, so it never
        // reaches the measurement: `declarations` skips anything under
        // `nesting.could_exceed` nodes.
        const region = d.body.unwrap() orelse unreachable;
        try l.report(
            .nesting_too_deep,
            region,
            \\`{s}` nests too deeply to run in a browser.
            \\
            \\Its JavaScript would nest about {d} levels and {d} scopes deep. Browser engines
            \\parse nested code by recursion and give up not far past that — Chrome at 1 290
            \\nested calls, 644 nested `if` blocks and 553 nested functions, Firefox at 251
            \\nested scopes — so I write at most {d} levels and {d} scopes
            \\(`docs/design/backend.md` §4).
            \\
            \\Long lists, operator chains, pipelines and `else if` chains come out flat
            \\however long they are. What cannot is nesting the program writes itself,
            \\hundreds deep: functions inside functions, or `case`s and `if`s inside one
            \\another through the arguments of calls. Moving the inner parts into
            \\top-level declarations of their own fixes it.
        ,
            .{
                l.text(l.bir.symbol(d.name)),
                h.whole / JsIr.nesting.call,
                h.scopes,
                JsIr.nesting.budget / JsIr.nesting.call,
                JsIr.nesting.scope_budget,
            },
        );
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
            if (!l.liveDecl(@intCast(root)) and !l.liveTwin(@intCast(root))) continue;
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
    /// sites reach: the sites' own targets, the evidence they hand over and,
    /// through every derived row they name, what that row's body names (a
    /// derived function runs its body when it is called). Flat, in
    /// site order, so `emissionOrder` walks it with one index like the `refs`
    /// run beside it. `Edges.termsEdges` visits each term once, so a table
    /// that shares terms costs its distinct terms (checker-v2.md §13.1).
    fn siteTops(l: *Lowerer, decl: u32) ![]const u32 {
        const d = l.bir.decls[decl];
        var roots: std.ArrayList(Dispatch.TermIndex) = .empty;
        defer roots.deinit(l.scratch);
        for (l.in.dispatch.sitesIn(d.inst_start.int(), d.inst_end.int())) |site| {
            if (site.callee.unwrap()) |callee| try roots.append(l.scratch, callee);
            try roots.appendSlice(l.scratch, l.in.dispatch.argsAt(site.evidence));
        }
        if (roots.items.len == 0) return &.{};
        var edges: std.ArrayList(Edges.Edge) = .empty;
        defer edges.deinit(l.scratch);
        try Edges.termsEdges(&edges, l.scratch, l.in.dispatch, roots.items, true);
        var out: std.ArrayList(u32) = .empty;
        for (edges.items) |edge| switch (edge) {
            .top => |t| try out.append(l.scratch, t),
            else => {},
        };
        return out.items;
    }

    fn declaration(l: *Lowerer, out: *StmtList, index: u32) !void {
        const d = l.bir.decls[index];
        switch (d.kind) {
            .value => {},
            // A type, an alias and a foreign type emit nothing: a
            // constructor is an object literal at its use site and a type
            // has no runtime existence at all.
            .type, .type_alias, .foreign_type, .schema => return,
            // A vocabulary declaration is data for the checker and the
            // markup lowering, and has no value of its own to emit.
            .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => return,
            // Bound by the sibling import, not by a declaration here.
            .foreign_value => return,
            // The parser already reported it and there is no body.
            .annotation_only => return,
        }
        if (d.body == .none) return;
        // Its direct body, then — a declaration with two (transparent-
        // effects-proposal.md §16.2) — its suspendable one, each when it
        // survived elimination.
        if (l.liveDecl(index)) try l.declarationAs(out, index, .direct);
        if (l.in.dispatch.effectDecl(index).twin and l.liveTwin(index)) try l.declarationAs(out, index, .twin);
    }

    fn declarationAs(l: *Lowerer, out: *StmtList, index: u32, variant: Variant) !void {
        const d = l.bir.decls[index];
        const body = d.body.unwrap() orelse return;
        l.locals = l.bir.declLocals(d);
        l.decl_index = index;
        l.read_locals = null;
        l.local_names = try l.scratch.alloc(JsIr.NameIndex, l.locals.len);
        @memset(l.local_names, .none);
        l.local_tag_base = 0;
        l.local_tag_next = @intCast(l.locals.len);
        l.variant = variant;
        defer l.variant = .direct;

        const n = switch (variant) {
            .direct => try l.name(.{
                .module = l.module_name.toOptional(),
                .base = l.bir.symbol(d.name),
                .tag = JsIr.Name.no_tag,
            }),
            .twin => try l.twinName(l.module_name, l.bir.symbol(d.name)),
        };
        const p = l.pos(body);
        // The binding itself is where the definition's name is written,
        // which is what a source map names it by (§11); its value keeps the
        // body's position.
        const decl_p: u32 = if (d.name_token < l.in.token_starts.len) l.in.token_starts[d.name_token] else p;
        // The declaration's own arrow: suspendable, or not (§16.3).
        const own_suspends = l.suspendsHere(l.in.dispatch.effectDecl(index).own);
        // §8.1: the hidden leading parameters, one per entry of this
        // declaration's `DeclInfo.requirements` (checker-v2.md §13.1), in
        // the canonical order of §7.2. HOW the value is defined around them
        // is `Convention`'s (checker-v2.md §12.5) — the same answer every
        // call, every reference and the cycle check read, so the definition
        // and its uses cannot disagree.
        const use = Convention.ofDecl(l.in.dispatch, l.bir, index);
        const evidence: u32 = use.evidence;
        switch (Convention.definitionOf(l.in.dispatch, l.bir, index)) {
            .params => {
                const params = l.bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Inst.Index);
                const record = try l.functionOrLoop(n, .{ .top = index }, evidence, .none, params, body, p, own_suspends);
                const arrow = try l.add(.arrow, p, @intFromEnum(record), Node.Data.unused);
                if (variant == .direct and (l.unobserved[index] or l.unitResult(index, own_suspends))) try l.unobserved_arrows.append(l.scratch, arrow);
                try l.constDecl(out, n, arrow, decl_p);
            },
            // §8's narrow rule: a `lambda` that is the ENTIRE body of a
            // parameterless declaration inherits its name, because `f x = e`
            // and `f = \x -> e` emit byte-identical JavaScript today and two
            // spellings of one program must not differ in stack behaviour.
            // A lambda anywhere else never does. With evidence the lambda's
            // parameters follow it, as a written parameter list would.
            .lambda => {
                const ld = l.bir.instData(body);
                const lambda_params = l.bir.extraSlice(l.bir.subRange(@enumFromInt(ld.lhs)), Inst.Index);
                const record = try l.functionOrLoop(n, .{ .top = index }, evidence, .none, lambda_params, @enumFromInt(ld.rhs), p, l.functionSuspends(body));
                const arrow = try l.add(.arrow, p, @intFromEnum(record), Node.Data.unused);
                if (variant == .direct and (l.unobserved[index] or l.unitResult(index, l.functionSuspends(body)))) try l.unobserved_arrows.append(l.scratch, arrow);
                try l.constDecl(out, n, arrow, decl_p);
            },
            .applied => try l.constDecl(out, n, try l.appliedArrow(out, try l.variantBase(l.bir.symbol(d.name)), evidence, use.arity, body, p), decl_p),
            // `($m…) => value`, its value kept per evidence.
            .thunk => try l.constDecl(out, n, try l.memoArrow(out, try l.variantBase(l.bir.symbol(d.name)), evidence, &.{}, body, p), decl_p),
            .constant => {
                var stmts: StmtList = .empty;
                // A module-level `Js.Ref` that does not escape is a
                // module-level `let` of its value (§4).
                if (l.unboxed_tops.len > index and l.unboxed_tops[index]) {
                    try l.markMutable(n);
                    const init_inst = l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(body).rhs)), Inst.Index)[0];
                    const init = try l.expr(&stmts, init_inst);
                    const value = if (stmts.items.len == 0) init else blk: {
                        try stmts.append(l.scratch, try l.returnStmt(init, p));
                        break :blk try l.call(try l.arrowOf(&[_]JsIr.NameIndex{}, stmts.items, p), &.{}, p);
                    };
                    try out.append(l.scratch, try l.add(.let_decl, decl_p, @intFromEnum(n), @intFromEnum(value.toOptional())));
                    return;
                }
                const value = try l.expr(&stmts, body);
                // A constant whose lowering needed statements cannot be a
                // bare `const`: wrap it in a called arrow, which is the one
                // place lowering emits an IIFE and the one place §9.2's
                // peephole exists to remove.
                if (stmts.items.len == 0) {
                    try l.constDecl(out, n, value, decl_p);
                    return;
                }
                try stmts.append(l.scratch, try l.returnStmt(value, p));
                const arrow = try l.arrowOf(&[_]JsIr.NameIndex{}, stmts.items, p);
                try l.constDecl(out, n, try l.call(arrow, &.{}, p), decl_p);
            },
        }
    }

    /// `($m…, $p1…$pn) => body($p1…$pn)` — a value with evidence and no
    /// parameters whose TYPE is a function of `arity` (checker-v2.md §12.5's
    /// `applied`): `h = maxOf` under a `where`. It is defined over its
    /// type's parameters so that it is called flat, `h(ev, a, b)`, like
    /// every other constrained function, and so that an importer, which
    /// sees only the type, calls it the same way.
    ///
    /// When the body is a reference to a function that takes evidence of its
    /// own — the common `h = maxOf` — the call goes straight to it,
    /// `maxOf(ev…, $p1…$pn)`, rather than through its eta-expansion: there
    /// is nothing to compute. Any other body is computed once per evidence
    /// (`memoArrow`) and the value it gives is called.
    fn appliedArrow(l: *Lowerer, out: *StmtList, decl_name: Symbol, evidence: u32, arity: u32, body: Inst.Index, p: u32) !Node.Index {
        const args = try l.scratch.alloc(Node.Index, arity);
        const names = try l.scratch.alloc(JsIr.NameIndex, arity);
        for (args, names) |*arg, *param| {
            param.* = try l.fresh(l.well.param);
            arg.* = try l.ident(param.*, p);
        }
        if (try l.referenceApplied(body, args)) |value| {
            var all: std.ArrayList(JsIr.NameIndex) = .empty;
            var k: u16 = 0;
            while (k < evidence) : (k += 1) try all.append(l.scratch, try l.evidenceName(k));
            try all.appendSlice(l.scratch, names);
            const stmts = [_]Node.Index{try l.returnStmt(value, p)};
            return l.arrowOf(all.items, &stmts, p);
        }
        return l.memoArrow(out, decl_name, evidence, names, body, p);
    }

    /// `($m…, $p…) => { … return D$ev$v($p…); }` — a constrained value with
    /// no parameters whose body is not a lambda (an `applied` function value,
    /// or a `thunk`), defined so that its body runs ONCE PER EVIDENCE and not
    /// at every read or call (`language.md` §6 *Evaluation
    /// order*). The value is a function of its evidence alone, so the last
    /// evidence and the value it gave are kept in two module-level `let`s,
    /// `D$ev$k<i>` and `D$ev$v`, declared above the definition:
    ///
    ///   let D$ev$k0, D$ev$v;
    ///   const D = ($m$0, $p$1) => {
    ///     if ($m$0 !== D$ev$k0) { …; D$ev$v = <body>; D$ev$k0 = $m$0; }
    ///     return D$ev$v($p$1);
    ///   };
    ///
    /// Evidence is a function and never `undefined`, so the first read
    /// computes. One instantiation — the common case, and the one a module
    /// whose evidence arguments are all module-level names always has — runs
    /// the body once, at its first use; a read with other evidence computes
    /// again, which is what every read did before. Nothing else changes: the
    /// convention, the arity and what an importer calls are `Convention`'s,
    /// so no interface bit is needed and no initialisation order moves (the
    /// body runs at the first use, exactly where it ran before).
    fn memoArrow(l: *Lowerer, out: *StmtList, decl_name: Symbol, evidence: u32, params: []const JsIr.NameIndex, body: Inst.Index, p: u32) !Node.Index {
        const keys = try l.scratch.alloc(JsIr.NameIndex, evidence);
        const decl_text = l.text(decl_name);
        for (keys, 0..) |*key, k| {
            key.* = try l.synthesisedName(try std.fmt.allocPrint(l.scratch, "{s}$ev$k{d}", .{ decl_text, k }));
            try out.append(l.scratch, try l.add(.let_decl, p, @intFromEnum(key.*), @intFromEnum(Node.OptionalIndex.none)));
        }
        const cached = try l.synthesisedName(try std.fmt.allocPrint(l.scratch, "{s}$ev$v", .{decl_text}));
        try out.append(l.scratch, try l.add(.let_decl, p, @intFromEnum(cached), @intFromEnum(Node.OptionalIndex.none)));

        var names: std.ArrayList(JsIr.NameIndex) = .empty;
        var k: u16 = 0;
        while (k < evidence) : (k += 1) try names.append(l.scratch, try l.evidenceName(k));
        try names.appendSlice(l.scratch, params);

        // A new function is a new label scope (§7).
        const depth = l.case_depth;
        l.case_depth = 0;
        defer l.case_depth = depth;
        var compute: StmtList = .empty;
        const value = try l.expr(&compute, body);
        try compute.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(cached, p)).int(), value.int()));
        var changed: ?Node.Index = null;
        for (keys, 0..) |key, i| {
            const ev = try l.ident(names.items[i], p);
            try compute.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(key, p)).int(), ev.int()));
            const differs = try l.binary(.strict_ne, try l.ident(names.items[i], p), try l.ident(key, p), p);
            changed = if (changed) |c| try l.binary(.logical_or, c, differs, p) else differs;
        }
        var stmts: StmtList = .empty;
        try l.ifStatement(&stmts, changed.?, compute.items, p);
        const result = if (params.len == 0) try l.ident(cached, p) else blk: {
            const args = try l.scratch.alloc(Node.Index, params.len);
            for (args, params) |*arg, param| arg.* = try l.ident(param, p);
            break :blk try l.call(try l.ident(cached, p), args, p);
        };
        try stmts.append(l.scratch, try l.returnStmt(result, p));
        return l.arrowOf(names.items, stmts.items, p);
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
            // A markup primitive is the markup runtime's, not this module's.
            if (d.kind == .vocab_markup) continue;
            if (d.kind == .value and d.body == .none) continue;
            if (l.liveDecl(decl_index.int())) try names.append(l.scratch, try l.name(.{
                .module = l.module_name.toOptional(),
                .base = l.bir.symbol(d.name),
                .tag = JsIr.Name.no_tag,
            }));
            // Its suspendable body, when it has one that survived (§16.2).
            if (d.kind == .value and l.in.dispatch.effectDecl(decl_index.int()).twin and l.liveTwin(decl_index.int())) {
                try names.append(l.scratch, try l.twinName(l.module_name, l.bir.symbol(d.name)));
            }
        }
        // `core/List`'s core-private values the emitter calls from other
        // modules (`corePrivate`, `backend.md` §4): in no interface, so no
        // program names them, and exported when they survive — which is
        // exactly when some module's code calls one.
        if (l.in.graph.lookup(.core, InternPool.WellKnown.List.symbol()) == l.in.module) {
            for (l.bir.decls, 0..) |d, i| {
                if (d.is_pub or d.kind != .foreign_value) continue;
                const symbol = l.bir.symbol(d.name);
                if (symbol != InternPool.WellKnown.unsafeGet.symbol() and symbol != InternPool.WellKnown.view.symbol() and
                    symbol != InternPool.WellKnown.close.symbol() and symbol != InternPool.WellKnown.base.symbol() and
                    symbol != InternPool.WellKnown.offset.symbol()) continue;
                if (l.liveDecl(@intCast(i))) try names.append(l.scratch, try l.topName(@intCast(i)));
            }
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
        // The runtime, when this module's derived functions reach it.
        if (try l.runtimeImport()) |statement| try out.append(l.scratch, statement);
        // The markup runtime: the lowering's exports and the markup
        // primitives this module uses, one binding each (`backend.md` §15.1).
        if (l.markup_imports.items.len != 0) if (l.in.markup) |mk| {
            try out.append(l.scratch, try l.importStatement(mk.runtime, l.markup_imports.items));
        };
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
    fn functionOf(l: *Lowerer, evidence: u32, ev_let: Inst.OptionalIndex, params: []const Inst.Index, body: Inst.Index, suspendable: bool) !JsIr.ExtraIndex {
        var names: std.ArrayList(JsIr.NameIndex) = .empty;
        var stmts: StmtList = .empty;
        // A new function is a new label scope (§7).
        const depth = l.case_depth;
        l.case_depth = 0;
        defer l.case_depth = depth;
        // And a function of its own for the suspendable form (§16.3).
        const outer = l.enterFunction(suspendable);
        defer l.leaveFunction(outer);
        // The evidence parameters come FIRST, before the declaration's own
        // (§8.1): `$m$<k>` for a declaration, `$l<inst>$<k>` for a `let`
        // function binding that generalised (`ev_let`, backend.md §4). A lambda
        // never has any, and reads its enclosing binders' by capture.
        var k: u16 = 0;
        while (k < evidence) : (k += 1) try names.append(l.scratch, try l.evidenceNameOf(ev_let, k));
        for (params[0..l.writtenParams(params)]) |param| {
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
        const split = try l.splitSuspensions(stmts.items, null, .closure);
        return l.funcRecord(names.items, split);
    }

    /// How many trailing arguments of a call of `callee` are a `()` literal
    /// in the position of a parameter the callee's JavaScript does not hold
    /// (`writtenParams`), and so need not be passed. Known for a declaration
    /// of this module defined with its parameters; any other callee is
    /// passed every argument, which is always right, `null` being ignored.
    fn unwrittenArgs(l: *Lowerer, callee: Inst.Index, args: []const Inst.Index) usize {
        if (l.bir.instTag(callee) != .top) return 0;
        const index = l.bir.instData(callee).lhs;
        if (index >= l.bir.decls.len) return 0;
        const d = l.bir.decls[index];
        // A `foreign`'s sibling is written by hand, and reads what it reads.
        if (d.kind != .value) return 0;
        const params: []const Inst.Index = switch (Convention.definitionOf(l.in.dispatch, l.bir, index)) {
            .params => l.bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Inst.Index),
            .lambda => blk: {
                const body = d.body.unwrap() orelse return 0;
                break :blk l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(body).lhs)), Inst.Index);
            },
            else => return 0,
        };
        if (params.len != args.len) return 0;
        var n: usize = 0;
        var i = args.len;
        while (i > l.writtenParams(params)) : (i -= 1) {
            if (l.bir.instTag(args[i - 1]) != .unit) break;
            n += 1;
        }
        return n;
    }

    /// How many of `params` the JavaScript parameter list holds: all but a
    /// trailing run of `()` patterns (`backend.md` §6, *A parameter of type
    /// `()`*). Such a parameter binds nothing and its argument is `null`, so
    /// `f () = …` is `() => …`, and every caller still passing `null` is
    /// passing an argument JavaScript ignores.
    fn writtenParams(l: *Lowerer, params: []const Inst.Index) usize {
        var n = params.len;
        while (n != 0 and l.bir.instTag(params[n - 1]) == .pat_unit) n -= 1;
        return n;
    }

    // ---- The suspendable form (transparent-effects-proposal.md §16) -----

    const FunctionState = struct { suspendable: bool, markers: u32, join: JsIr.NameIndex };

    fn enterFunction(l: *Lowerer, suspendable: bool) FunctionState {
        const outer: FunctionState = .{ .suspendable = l.suspendable, .markers = l.markers, .join = l.join };
        l.suspendable = suspendable;
        l.markers = 0;
        l.function_depth += 1;
        l.join = .none;
        return outer;
    }

    fn leaveFunction(l: *Lowerer, outer: FunctionState) void {
        l.suspendable = outer.suspendable;
        l.markers = outer.markers;
        l.join = outer.join;
        l.function_depth -= 1;
    }

    /// Whether an answer of §16.2 is yes in the body being lowered.
    fn suspendsHere(l: *const Lowerer, a: Dispatch.Suspend) bool {
        return a == .yes or (a == .poly and l.variant == .twin);
    }

    /// Whether the function a lambda or a `let` definition makes is
    /// suspendable.
    fn functionSuspends(l: *const Lowerer, inst: Inst.Index) bool {
        return l.suspendsHere(l.in.dispatch.effectAt(inst).own);
    }

    /// A call that may suspend, in a suspendable function: bound to a
    /// temporary behind a marker (§16.3), which `Suspend` turns into the
    /// continuation of everything lowered after it into `out`.
    fn suspension(l: *Lowerer, out: *StmtList, inst: Inst.Index, value: Node.Index) !Node.Index {
        if (!l.suspendable) return value;
        if (!l.suspendsHere(l.in.dispatch.effectAt(inst).own)) return value;
        const p = l.pos(inst);
        const temp = try l.fresh(l.well.temp);
        const marker = try l.ident(try l.fixedName("$$suspend"), p);
        const node = try l.call(marker, &.{ value, try l.ident(temp, p) }, p);
        try out.append(l.scratch, try l.add(.expr_stmt, p, node.int(), Node.Data.unused));
        l.markers += 1;
        return l.ident(temp, p);
    }

    /// The function body `stmts` with its markers split (`Suspend`), or
    /// `stmts` itself when it has none — every function that does not
    /// suspend.
    fn splitSuspensions(l: *Lowerer, stmts: []const Node.Index, loop: ?Suspend.Loop, mode: Suspend.Mode) ![]const Node.Index {
        if (l.markers == 0) return stmts;
        const names = try l.fiberNames(mode == .loop);
        var pass: Suspend.Pass = .{ .b = l.b, .scratch = l.scratch, .names = names, .loop = loop, .keep = &l.effect_keep };
        return pass.rewrite(stmts, mode) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FallsThrough => {
                try l.report(
                    .not_implemented,
                    l.region,
                    \\A call here may suspend, in a position whose code runs on after it in a way
                    \\the suspendable form cannot yet continue (`docs/design/transparent-effects-proposal.md`
                    \\§16.3). Bind its result with `let` first, and use the name here.
                ,
                    .{},
                );
                return stmts;
            },
            error.InsideTry => {
                try l.report(
                    .internal,
                    l.region,
                    "A call that may suspend was lowered inside `Js.finally`, whose arguments are `sync` (`backend.md` §4, *`Js.finally` is `try … finally`*).",
                    .{},
                );
                return stmts;
            },
        };
    }

    /// What a join closes (`joinAround`).
    const Joined = union(enum) {
        case: Inst.Index,
        logical: struct { op: JsIr.BinaryOp, first: Node.Index, right: Inst.Index },
    };

    /// A `case`, or a short circuit, whose branches may suspend, in a
    /// suspendable function (§16.3): lowered in tail position with every
    /// leaf returning `$j(value)`, between the two markers `Suspend` turns
    /// into `const $j = ($t) => { the rest }` — the join point §7.1 makes
    /// mandatory. The value is `$t`.
    fn joinAround(l: *Lowerer, out: *StmtList, region: Inst.Index, what: Joined, p: u32) !Node.Index {
        const j = try l.name(.{ .module = .none, .base = try l.interner.getOrPut(l.gpa, "$k"), .tag = l.nextTag() });
        const t = try l.fresh(l.well.temp);
        try out.append(l.scratch, try l.markerStmt("$$join", &.{try l.ident(j, p)}, p));
        const saved = l.join;
        l.join = j;
        switch (what) {
            .case => |inst| try l.tailCase(out, inst, null),
            .logical => |g| {
                var taken: StmtList = .empty;
                try l.tailStmts(&taken, g.right, null);
                const constant = try l.add(if (g.op == .logical_and) .false_lit else .true_lit, p, Node.Data.unused, Node.Data.unused);
                const other = [_]Node.Index{try l.returnStmt(try l.call(try l.ident(j, p), &.{constant}, p), p)};
                const then_list: []const Node.Index = if (g.op == .logical_and) taken.items else &other;
                const else_list: []const Node.Index = if (g.op == .logical_and) &other else taken.items;
                const then_range = try l.b.addRange(then_list);
                const else_range = try l.b.addRange(else_list);
                const record = try l.b.addRecord(JsIr.If{
                    .then_start = then_range.start,
                    .then_end = then_range.end,
                    .else_start = else_range.start,
                    .else_end = else_range.end,
                });
                try out.append(l.scratch, try l.add(.if_stmt, p, g.first.int(), @intFromEnum(record)));
            },
        }
        l.join = saved;
        l.region = region;
        try out.append(l.scratch, try l.markerStmt("$$joined", &.{ try l.ident(j, p), try l.ident(t, p) }, p));
        l.markers += 1;
        return l.ident(t, p);
    }

    fn markerStmt(l: *Lowerer, spelled: []const u8, args: []const Node.Index, p: u32) !Node.Index {
        const marker = try l.ident(try l.fixedName(spelled), p);
        const node = try l.call(marker, args, p);
        return l.add(.expr_stmt, p, node.int(), Node.Data.unused);
    }

    fn nextTag(l: *Lowerer) u32 {
        const tag = l.next_tag;
        l.next_tag += 1;
        return tag;
    }

    /// Whether evaluating `value`, a `let` binding's right-hand side, may
    /// have an effect: a call under it, outside any function it makes, whose
    /// callee may be impure or may suspend — always, or when the enclosing
    /// declaration is used with something that is (§16.2's `impure` answer).
    /// The release optimiser keeps such a binding however few read it
    /// (`language.md` §6, *What an optimiser may assume*; `backend.md` §9
    /// item 1, as amended 2026-09-30), whatever its pattern binds.
    fn mayHaveEffect(l: *Lowerer, value: Inst.Index) bool {
        return l.reaches(value, .effect);
    }

    /// Whether a branch of `case` `inst` may suspend here.
    fn branchesYield(l: *Lowerer, inst: Inst.Index) bool {
        return l.branchesReach(inst, .suspension);
    }

    /// Whether evaluating `inst` may suspend the function being lowered: a
    /// call under it that may, outside any function it makes.
    fn yields(l: *Lowerer, inst: Inst.Index) bool {
        return l.reaches(inst, .suspension);
    }

    /// What `reaches` looks for at a call.
    const Probe = enum {
        /// A call that may suspend in the body being lowered.
        suspension,
        /// A call that may be impure or suspend in some use of the body.
        effect,
    };

    fn callHits(l: *Lowerer, inst: Inst.Index, comptime probe: Probe) bool {
        const site = l.in.dispatch.effectAt(inst);
        return switch (probe) {
            .suspension => l.suspendsHere(site.own),
            .effect => site.impure or site.own != .no,
        };
    }

    fn branchesReach(l: *Lowerer, inst: Inst.Index, comptime probe: Probe) bool {
        for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(inst).rhs)), Inst.Index)) |branch| {
            if (l.bir.instTag(branch) != .branch) continue;
            if (l.reaches(@enumFromInt(l.bir.instData(branch).rhs), probe)) return true;
        }
        return false;
    }

    /// Whether evaluating `inst` reaches a call `probe` hits, outside any
    /// function it makes.
    fn reaches(l: *Lowerer, inst: Inst.Index, comptime probe: Probe) bool {
        const d = l.bir.instData(inst);
        switch (l.bir.instTag(inst)) {
            .call => {
                if (l.callHits(inst, probe)) return true;
                if (l.reaches(@enumFromInt(d.lhs), probe)) return true;
                return l.anyReaches(l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index), probe);
            },
            .method_call => {
                if (l.callHits(inst, probe)) return true;
                if (l.reaches(@enumFromInt(d.lhs), probe)) return true;
                const m = l.bir.extraData(@enumFromInt(d.rhs), Bir.MethodCall);
                return l.anyReaches(l.bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Inst.Index), probe);
            },
            .type_dispatch => {
                if (l.callHits(inst, probe)) return true;
                const t = l.bir.extraData(@enumFromInt(d.rhs), Bir.TypeDispatch);
                return l.anyReaches(l.bir.extraSlice(.{ .start = t.args_start, .end = t.args_end }, Inst.Index), probe);
            },
            .let => {
                for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.lhs)), Inst.Index)) |def| {
                    const dd = l.bir.instData(def);
                    switch (l.bir.instTag(def)) {
                        .let_def => {
                            const payload = l.bir.extraData(@enumFromInt(dd.lhs), Bir.LetDef);
                            if (payload.params_end != payload.params_start) continue;
                            if (l.reaches(@enumFromInt(dd.rhs), probe)) return true;
                        },
                        .let_pattern => if (l.reaches(@enumFromInt(dd.rhs), probe)) return true,
                        else => {},
                    }
                }
                return l.reaches(@enumFromInt(d.rhs), probe);
            },
            .case => {
                if (l.reaches(@enumFromInt(d.lhs), probe)) return true;
                return l.branchesReach(inst, probe);
            },
            .@"try", .field_access, .tuple_index => return l.reaches(@enumFromInt(d.lhs), probe),
            .tuple, .list, .interp => return l.anyReaches(l.bir.extraSlice(Bir.inlineRange(d), Inst.Index), probe),
            .record => {
                for (l.bir.extraSlice(Bir.inlineRange(d), Bir.Field)) |f| if (l.reaches(f.value, probe)) return true;
                return false;
            },
            .record_update => {
                if (l.reaches(@enumFromInt(d.lhs), probe)) return true;
                for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Bir.Field)) |f| if (l.reaches(f.value, probe)) return true;
                return false;
            },
            // Markup is not walked. For a suspension the answer stays no, as
            // it always was: a hole whose lowering would nest a suspension
            // point is refused (§16.3). For an effect it is yes, which costs
            // a release build only the binding of a view nothing reads.
            .markup => return probe == .effect,
            else => return false,
        }
    }

    fn anyReaches(l: *Lowerer, insts: []const Inst.Index, comptime probe: Probe) bool {
        for (insts) |inst| if (l.reaches(inst, probe)) return true;
        return false;
    }

    /// The names `Suspend` writes, each core value imported the first time a
    /// function needs it: `Task.isWaiting` only for a loop's fast path.
    fn fiberNames(l: *Lowerer, waiting: bool) !Suspend.Names {
        var names = l.fiber_names orelse blk: {
            const and_then = try l.coreValue(.Task, .andThen, Node.no_pos);
            break :blk Suspend.Names{
                .marker = try l.fixedName("$$suspend"),
                .join = try l.fixedName("$$join"),
                .joined = try l.fixedName("$$joined"),
                .and_then = @enumFromInt(l.b.nodes.items(.data)[and_then.int()].lhs),
                .is_waiting = .none,
            };
        };
        if (waiting and names.is_waiting == .none) {
            const is_waiting = try l.coreValue(.Task, .isWaiting, Node.no_pos);
            names.is_waiting = @enumFromInt(l.b.nodes.items(.data)[is_waiting.int()].lhs);
        }
        l.fiber_names = names;
        return names;
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
        evidence: u32,
        /// The `let_def` whose `$l…` names the evidence slots are, or `.none`
        /// for a declaration's `$m…` (backend.md §4).
        ev_let: Inst.OptionalIndex = .none,
        slots: []Slot,
        /// Whether the function has a CONS STEP — a `[ h, ...t ]` in tail
        /// position whose tail reaches a tail self-call — and so builds its
        /// result front to back in `root` (§8, *Tail calls modulo cons,
        /// onto an array*). Set by `markTails`.
        builds: bool = false,
        /// `$root`, the fresh array every step pushes its heads onto and
        /// every exit hands over. `.none` unless `builds`.
        root: JsIr.NameIndex = .none,
        /// What the jumps wrote that `functionOrLoop` rewrites when the loop
        /// reassigns its parameters in place (§8, *In place, when nothing
        /// captures*).
        jumps: *Jumps,
        /// Whether the body may turn out to make no function, so that the
        /// jumps are written ready to reassign the parameters in place
        /// (`mayGoInPlace`). Only a hint: `functionOrLoop` decides on the
        /// JavaScript, and a jump written ready is right either way.
        ready: bool = false,
        /// Where an exit's value goes: `return` for a function's loop, or
        /// — for a loop written where its value is bound or discarded (§9,
        /// *A function called once is written where it is called*) — the
        /// binding, and then `break`.
        exit: Exit = .@"return",

        const Exit = union(enum) {
            @"return",
            /// The value evaluated for its effect alone.
            discard,
            /// `name = value`.
            assign: JsIr.NameIndex,
            /// A tuple literal's elements, each into its name (`.none` for
            /// `_`, evaluated for its effect alone): no tuple is built.
            tuple: []const JsIr.NameIndex,
        };

        const Jumps = struct {
            /// The `ident` each assignment writes, and the slot it is.
            targets: std.ArrayList(struct { node: Node.Index, slot: u32 }) = .empty,
            continues: std.ArrayList(Node.Index) = .empty,
            /// The `break`s an exit that does not return writes.
            breaks: std.ArrayList(Node.Index) = .empty,
            /// The assignments an exit that binds writes, `name = value`.
            exits: std.ArrayList(Node.Index) = .empty,
        };

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
            /// A trailing `()` parameter, which the JavaScript parameter list
            /// does not hold (`writtenParams`): its argument is evaluated
            /// and never stored.
            unwritten: bool = false,
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

    /// A list local a loop carries as an offset into a base array (§8,
    /// *Scalar views*): a parameter the rule applies to, or a `rest` a
    /// pattern binds of it. Its JavaScript binding holds the integer.
    const Scalar = struct {
        /// The declaration whose local it is: a body written in place has
        /// locals of its own under the same indices (`enterInline`).
        decl: u32,
        local: u32,
        /// `$s`, the base array every offset of the slot indexes.
        base: JsIr.NameIndex,
        /// The loop the slot belongs to, and which slot.
        label: JsIr.NameIndex,
        slot: u32,
        /// For the parameter itself, the list the call was entered with,
        /// which a read at the entry offset is (§4, *Identity*); `.none`
        /// for a `rest`, which never is.
        entry: JsIr.NameIndex = .none,
        /// Whether some read built the parameter as a list, which needs
        /// `entry` bound before the loop.
        entry_read: bool = false,
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
        evidence: u32,
        ev_let: Inst.OptionalIndex,
        params: []const Inst.Index,
        body: Inst.Index,
        p: u32,
        suspendable: bool,
    ) !JsIr.ExtraIndex {
        const slots = try l.scratch.alloc(Loop.Slot, @as(usize, evidence) + params.len);
        for (slots[0..evidence]) |*slot| slot.* = .{};
        const written = l.writtenParams(params);
        for (params, slots[evidence..], 0..) |param, *slot, i| {
            slot.* = .{ .pattern = param.toOptional(), .unwritten = i >= written };
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
        var jumps: Loop.Jumps = .{};
        var loop: Loop = .{ .label = label, .self = self, .evidence = evidence, .ev_let = ev_let, .slots = slots, .jumps = &jumps };
        if (!l.markTails(body, &loop)) return l.functionOf(evidence, ev_let, params, body, suspendable);
        loop.ready = l.mayGoInPlace(params, body);

        // A new function is a new label scope (§7).
        const depth = l.case_depth;
        l.case_depth = 0;
        defer l.case_depth = depth;
        const outer = l.enterFunction(suspendable);
        defer l.leaveFunction(outer);
        const built = try l.loopOf(&loop, body, p);
        return l.funcRecord(built.names, built.stmts);
    }

    /// A loop's parameter names and its statements (§8): `functionOrLoop`'s
    /// function, or the loop a function called once is written as in its
    /// caller (§9, *A function called once is written where it is called*).
    fn loopOf(l: *Lowerer, loop: *Loop, body: Inst.Index, p: u32) !struct { names: []const JsIr.NameIndex, stmts: []const Node.Index } {
        const slots = loop.slots;
        const evidence = loop.evidence;
        const ev_let = loop.ev_let;
        const label = loop.label;
        const jumps = loop.jumps;
        var names: std.ArrayList(JsIr.NameIndex) = .empty;
        for (slots, 0..) |*slot, i| {
            const index: u32 = @intCast(i);
            if (slot.unwritten) continue;
            slot.body = if (index < evidence)
                try l.evidenceNameOf(ev_let, @intCast(index))
            else if (slot.local != Loop.no_local)
                try l.localName(slot.local)
            else if (l.bir.instTag(slot.pattern.unwrap().?) == .pat_wild)
                .none
            else
                try l.fresh(l.well.param);
            slot.param = if (slot.carried) try l.inSlotName(index) else slot.body;
            try names.append(l.scratch, slot.param);
        }

        // The prologue. One `const` per carried slot rather than one
        // comma-separated declaration: joining them is §9 item 5's variable
        // joining, a printer decision and not lowering's. Written only when
        // the loop keeps its copies (below).
        var prologue: StmtList = .empty;
        for (slots) |slot| {
            if (!slot.carried or slot.body == .none) continue;
            try l.constDecl(&prologue, slot.body, try l.ident(slot.param, p), p);
        }
        var loop_body: StmtList = .empty;
        // A parameter whose pattern is not a bare variable destructures
        // INSIDE the loop, because it reads this iteration's value (§8).
        for (slots[evidence..]) |slot| {
            if (slot.unwritten) continue;
            const pattern = slot.pattern.unwrap().?;
            switch (l.bir.instTag(pattern)) {
                .pat_var, .pat_wild => {},
                else => try l.bindings(&loop_body, pattern, try l.ident(slot.body, l.pos(pattern))),
            }
        }
        // A building loop's destination (§8, *Tail calls modulo cons, onto
        // an array*): one fresh array, a builder in §4's sense (invariant
        // 5) — pushed onto by the steps, handed over once by an exit.
        var before: Node.Index = undefined;
        if (loop.builds) {
            loop.root = try l.fixedName("$root");
            before = try l.add(.const_decl, p, @intFromEnum(loop.root), (try l.arrayNode(&.{}, p)).int());
        }
        // Scalar views (§8): each walked list slot is read through its
        // base array by an offset. Not in a suspendable body, whose
        // re-entry passes the slots as lists.
        const scalar_mark = l.scalars.items.len;
        defer l.scalars.shrinkRetainingCapacity(scalar_mark);
        const scalar_at = try l.scratch.alloc(?usize, slots.len);
        @memset(scalar_at, null);
        if (!l.suspendable) try l.scalarSlots(loop, body, scalar_at);
        try l.tailStmts(&loop_body, body, loop);
        // A suspension point in the loop's body: the fast path stays in the
        // loop, and the slow path re-enters the function with its slots
        // (§16.3). A building loop's slow path goes on writing into the same
        // destination: its re-entry builds the rest as a list of its own,
        // which a continuation adds after what this call pushed (§8, *Tail
        // calls modulo cons, onto an array*; transparent-effects-proposal.md
        // §16.3's amendment of 2026-10-01).
        var reentry: Suspend.Loop = .{ .label = label, .callee = label, .params = names.items };
        if (loop.builds and l.markers != 0) {
            reentry.root = loop.root;
            reentry.close = try l.closeName(p);
            reentry.built = try l.fixedName("$built");
        }
        // **In place, when nothing captures** (§8): a body that makes no
        // function cannot hold a closure over this iteration's parameters,
        // so the jumps may write the parameters themselves and the prologue
        // copies go. The test is on the JavaScript just built, which is
        // exactly the set of functions the body makes — a lambda, a `let`
        // function, a placeholder, an eta-expansion of evidence alike. A
        // loop with a suspension point keeps its copies: its re-entry
        // passes the slots. The label goes too unless a loop is nested.
        const held = try l.b.holds(l.scratch, loop_body.items, .none);
        const in_place = loop.ready and l.markers == 0 and !held.closure;
        var statements: StmtList = .empty;
        // A `continue` reaches the innermost loop of its own function, and
        // a body with no loop of its own leaves only this one: the label is
        // needed by nothing but a suspension's re-entry (§16.3).
        // A jump or an exit is never inside a loop the body holds — that
        // loop is a `Js.each`'s, whose body is discarded, or one written
        // where its value is bound, whose body is another function's — but
        // an exit's `break` with no label would leave a `switch` it is in
        // rather than this loop, so there it keeps the label.
        var loop_label = label;
        const datas = l.b.nodes.items(.data);
        if (l.markers == 0 and !(held.switch_ and jumps.breaks.items.len != 0)) {
            loop_label = .none;
            for (jumps.continues.items) |c| datas[c.int()].lhs = @intFromEnum(loop_label);
        }
        for (jumps.breaks.items) |b| datas[b.int()].lhs = @intFromEnum(loop_label);
        if (in_place) {
            const tags = l.b.nodes.items(.tag);
            for (jumps.targets.items) |t| {
                const slot = slots[t.slot];
                if (slot.body == .none) continue;
                std.debug.assert(tags[t.node.int()] == .ident);
                datas[t.node.int()].lhs = @intFromEnum(slot.body);
            }
            names.clearRetainingCapacity();
            for (slots) |slot| {
                if (slot.unwritten) continue;
                try names.append(l.scratch, if (slot.carried and slot.body != .none) slot.body else slot.param);
            }
            try statements.appendSlice(l.scratch, loop_body.items);
        } else {
            try statements.appendSlice(l.scratch, prologue.items);
            try statements.appendSlice(l.scratch, try l.splitSuspensions(loop_body.items, reentry, .loop));
        }

        const range = try l.b.addRange(statements.items);
        const record = try l.b.addRecord(range);
        // Control leaves by `return` or by `continue`, so nothing follows
        // the loop and there is no `break` (§8).
        const while_node = try l.add(.while_true, p, @intFromEnum(loop_label), @intFromEnum(record));
        // Before the loop, each scalar slot's base, and its offset written
        // into the slot: `const $v = xs;` when a read builds the list the
        // call was entered with, `const $s = List$base(xs); xs =
        // List$offset(xs);`.
        var head: StmtList = .empty;
        for (slots, scalar_at) |slot, at| {
            const k = at orelse continue;
            const scalar = l.scalars.items[k];
            const param = if (in_place and slot.carried and slot.body != .none) slot.body else slot.param;
            if (scalar.entry_read) try l.constDecl(&head, scalar.entry, try l.ident(param, p), p);
            const base = try l.call(try l.corePrivate(.base, p), &.{try l.ident(param, p)}, p);
            try l.constDecl(&head, scalar.base, base, p);
            const offset = try l.call(try l.corePrivate(.offset, p), &.{try l.ident(param, p)}, p);
            try head.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(param, p)).int(), offset.int()));
        }
        if (loop.builds) try head.append(l.scratch, before);
        try head.append(l.scratch, while_node);
        return .{ .names = names.items, .stmts = head.items };
    }

    /// §8's *Scalar views*: which list slots of `loop` are walked — every
    /// tail self-call passes the slot the parameter itself or a `rest` a
    /// list pattern bound of it, and some `case` matches the parameter
    /// with a list pattern — and so can be carried as an offset into a
    /// base array fixed for the call. Registers each such slot's
    /// parameter and every `rest` of it in `scalars`, and `at[i]` the
    /// parameter's entry.
    fn scalarSlots(l: *Lowerer, loop: *const Loop, body: Inst.Index, at: []?usize) !void {
        var start = @intFromEnum(body);
        for (loop.slots) |slot| {
            if (slot.pattern.unwrap()) |pattern| start = @min(start, @intFromEnum(pattern));
        }
        const decl = l.decl_index orelse std.math.maxInt(u32);
        var tails: std.ArrayList(u32) = .empty;
        for (loop.slots, 0..) |slot, i| {
            if (i < loop.evidence or slot.local == Loop.no_local or !slot.carried or slot.unwritten) continue;
            tails.clearRetainingCapacity();
            try tails.append(l.scratch, slot.local);
            if (!try l.walkedSlot(@enumFromInt(start), body, &tails)) continue;
            if (!try l.selfArgsIn(body, loop, i - loop.evidence, tails.items)) continue;
            const base = try l.fresh(l.well.temp);
            at[i] = l.scalars.items.len;
            for (tails.items, 0..) |local, j| {
                try l.scalars.append(l.scratch, .{
                    .decl = decl,
                    .local = local,
                    .base = base,
                    .label = loop.label,
                    .slot = @intCast(i),
                    .entry = if (j == 0) try l.fresh(l.well.temp) else .none,
                });
            }
        }
    }

    /// Whether some `case` from `start` to `body` matches a local of
    /// `tails` with a list pattern, adding every `rest` those patterns
    /// bind to `tails` until none is new. False, too, when one of those
    /// patterns has an item after its spread, whose end the rule does not
    /// read by an offset.
    fn walkedSlot(l: *Lowerer, start: Inst.Index, body: Inst.Index, tails: *std.ArrayList(u32)) !bool {
        var walked = false;
        var grew = true;
        while (grew) {
            grew = false;
            var inst = @intFromEnum(start);
            while (inst <= @intFromEnum(body)) : (inst += 1) {
                const case_inst: Inst.Index = @enumFromInt(inst);
                if (l.bir.instTag(case_inst) != .case) continue;
                const d = l.bir.instData(case_inst);
                const scrutinee: Inst.Index = @enumFromInt(d.lhs);
                const branches = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
                // The roots `planCase` reads: the scrutinee, or the elements
                // of a tuple literal every row matches element-wise.
                const elements: []const Inst.Index = if (l.bir.instTag(scrutinee) == .tuple)
                    l.bir.extraSlice(Bir.inlineRange(l.bir.instData(scrutinee)), Inst.Index)
                else
                    &.{};
                const spread = elements.len != 0 and l.rowsAreTuples(branches, elements.len);
                const roots: []const Inst.Index = if (spread) elements else &.{scrutinee};
                for (roots, 0..) |root, r| {
                    if (l.bir.instTag(root) != .local) continue;
                    if (std.mem.indexOfScalar(u32, tails.items, l.bir.instData(root).lhs) == null) continue;
                    for (branches) |branch| {
                        var pattern: Inst.Index = @enumFromInt(l.bir.instData(branch).lhs);
                        if (spread) {
                            if (l.bir.instTag(pattern) != .pat_tuple) continue;
                            pattern = l.bir.extraSlice(Bir.inlineRange(l.bir.instData(pattern)), Inst.Index)[r];
                        }
                        while (l.bir.instTag(pattern) == .pat_as) pattern = @enumFromInt(l.bir.instData(pattern).lhs);
                        if (l.bir.instTag(pattern) != .pat_list) continue;
                        walked = true;
                        const items = l.bir.extraSlice(Bir.inlineRange(l.bir.instData(pattern)), Inst.Index);
                        for (items, 0..) |item, k| {
                            if (l.bir.instTag(item) != .pat_spread) continue;
                            if (k + 1 != items.len) return false;
                            const operand: Inst.Index = @enumFromInt(l.bir.instData(item).lhs);
                            if (l.bir.instTag(operand) != .pat_var) continue;
                            const local = l.bir.instData(operand).lhs;
                            if (std.mem.indexOfScalar(u32, tails.items, local) != null) continue;
                            try tails.append(l.scratch, local);
                            grew = true;
                        }
                    }
                }
            }
        }
        return walked;
    }

    /// Whether every tail self-call under `inst` — cons steps included —
    /// passes argument `arg` a local of `tails`, or a re-cons of one
    /// (`reconsOf`).
    fn selfArgsIn(l: *Lowerer, inst: Inst.Index, loop: *const Loop, arg: usize, tails: []const u32) Allocator.Error!bool {
        const d = l.bir.instData(inst);
        switch (l.bir.instTag(inst)) {
            .let => return l.selfArgsIn(@enumFromInt(d.rhs), loop, arg, tails),
            .case => {
                for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index)) |branch| {
                    if (l.bir.instTag(branch) != .branch) continue;
                    if (!try l.selfArgsIn(@enumFromInt(l.bir.instData(branch).rhs), loop, arg, tails)) return false;
                }
                return true;
            },
            .call => {
                if (l.isSelfCall(inst, loop)) {
                    const value = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index)[arg];
                    const local = if (l.bir.instTag(value) == .local)
                        l.bir.instData(value).lhs
                    else if (try l.reconsOf(value)) |recons|
                        recons.tail
                    else
                        return false;
                    return std.mem.indexOfScalar(u32, tails, local) != null;
                }
                const tail = l.consTail(inst) orelse return true;
                return l.selfArgsIn(tail, loop, arg, tails);
            },
            else => return true,
        }
    }

    /// The entry of `scalars` for local `index` of the declaration being
    /// lowered, innermost first; null when it holds a list.
    fn scalarOf(l: *const Lowerer, index: u32) ?usize {
        const decl = l.decl_index orelse std.math.maxInt(u32);
        var k = l.scalars.items.len;
        while (k > 0) {
            k -= 1;
            const s = l.scalars.items[k];
            if (s.local == index and s.decl == decl) return k;
        }
        return null;
    }

    const ListBind = struct { pattern: Inst.Index, index: u32, spread: bool };

    /// §7's re-consing rule over a scalar view: `[ h1, …, hm, ...t ]`
    /// whose `t` is a spread's local and whose heads are the locals bound
    /// by the `m` items just before that spread in the same pattern is
    /// the list that pattern matched from item `s - m`: at a scalar view,
    /// the offset `t - m`. Answers `t` and `m`, or null.
    fn reconsOf(l: *Lowerer, inst: Inst.Index) Allocator.Error!?struct { tail: u32, back: u32 } {
        if (l.bir.instTag(inst) != .call) return null;
        const d = l.bir.instData(inst);
        if (!l.isListCons(@enumFromInt(d.lhs)) or l.rootsOf(inst).len != 0) return null;
        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
        if (args.len != 2 or l.bir.instTag(args[0]) != .local) return null;
        const binds = try l.listBinds();
        var tail: u32 = undefined;
        var back: u32 = undefined;
        if (l.bir.instTag(args[1]) == .local) {
            tail = l.bir.instData(args[1]).lhs;
            back = 0;
        } else {
            const inner = try l.reconsOf(args[1]) orelse return null;
            tail = inner.tail;
            back = inner.back;
        }
        const t = (if (tail < binds.len) binds[tail] else null) orelse return null;
        const head = l.bir.instData(args[0]).lhs;
        const h = (if (head < binds.len) binds[head] else null) orelse return null;
        if (!t.spread or h.spread or h.pattern != t.pattern or h.index + back + 1 != t.index) return null;
        return .{ .tail = tail, .back = back + 1 };
    }

    fn listBinds(l: *Lowerer) Allocator.Error![]const ?ListBind {
        const decl = l.decl_index orelse return &.{};
        if (l.list_binds_decl == decl) return l.list_binds;
        l.list_binds_decl = decl;
        l.list_binds = try l.scratch.alloc(?ListBind, l.locals.len);
        @memset(l.list_binds, null);
        const range = l.bir.decls[decl];
        var inst = range.inst_start.int();
        while (inst < range.inst_end.int() and inst < l.bir.insts.len) : (inst += 1) {
            const at: Inst.Index = @enumFromInt(inst);
            if (l.bir.instTag(at) != .pat_list) continue;
            for (l.bir.extraSlice(Bir.inlineRange(l.bir.instData(at)), Inst.Index), 0..) |item, i| {
                const spread = l.bir.instTag(item) == .pat_spread;
                const bound: Inst.Index = if (spread) @enumFromInt(l.bir.instData(item).lhs) else item;
                if (l.bir.instTag(bound) != .pat_var) continue;
                const local = l.bir.instData(bound).lhs;
                if (local < l.list_binds.len) l.list_binds[local] = .{ .pattern = at, .index = @intCast(i), .spread = spread };
            }
        }
        return l.list_binds;
    }

    /// Whether the `local` instruction `inst` is written as the offset it
    /// holds (`scalar_raw`).
    fn isScalarRaw(l: *const Lowerer, inst: Inst.Index) bool {
        return std.mem.indexOfScalar(Inst.Index, l.scalar_raw.items, inst) != null;
    }

    /// The list at offset `offset` of scalar `k`'s base, built where a
    /// list is read as a value: `List$view($s, offset)`, and for the
    /// parameter itself the list the call was entered with when the offset
    /// is still the entry one (§8: a walk that took no step gives back the
    /// very list it was given). A suffix of the base is at the entry
    /// offset exactly when it is as long as the entry list.
    fn materialise(l: *Lowerer, k: usize, offset: Node.Index, p: u32) !Node.Index {
        const scalar = &l.scalars.items[k];
        const base = try l.ident(scalar.base, p);
        const view = try l.call(try l.corePrivate(.view, p), &.{ base, offset }, p);
        if (scalar.entry == .none) return view;
        scalar.entry_read = true;
        const entry = try l.ident(scalar.entry, p);
        const left = try l.binary(.sub, try l.lengthOf(base, p), offset, p);
        const at_entry = try l.binary(.strict_eq, left, try l.lengthOf(entry, p), p);
        return l.condOf(at_entry, entry, view, p);
    }

    /// `offset + k`, or `offset` itself at 0.
    fn offsetPlus(l: *Lowerer, offset: Node.Index, k: u32, p: u32) !Node.Index {
        if (k == 0) return offset;
        return l.binary(.add, offset, try l.intNode(k, p), p);
    }

    /// The bindings of `pattern` matched against scalar `k` at `offset`
    /// (`bindings` for a list the loop holds as an offset): an element is
    /// `$s[offset + i]`, a `rest` the rule registered is the integer
    /// `offset + i`, and anything bound as a list is built
    /// (`materialise`).
    fn scalarBindings(l: *Lowerer, out: *StmtList, pattern: Inst.Index, k: usize, offset: Node.Index) Allocator.Error!void {
        const d = l.bir.instData(pattern);
        const p = l.pos(pattern);
        switch (l.bir.instTag(pattern)) {
            .pat_wild => {},
            .pat_var => try l.constDecl(out, try l.localName(d.lhs), try l.materialise(k, offset, p), p),
            .pat_as => {
                try l.scalarBindings(out, @enumFromInt(d.lhs), k, offset);
                try l.constDecl(out, try l.localName(d.rhs), try l.materialise(k, offset, p), p);
            },
            .pat_list => {
                const base = try l.ident(l.scalars.items[k].base, p);
                for (l.bir.extraSlice(Bir.inlineRange(d), Inst.Index), 0..) |element, i| {
                    const at = try l.offsetPlus(offset, @intCast(i), p);
                    if (l.bir.instTag(element) == .pat_spread) {
                        const operand: Inst.Index = @enumFromInt(l.bir.instData(element).lhs);
                        if (!try l.bindsRead(operand)) continue;
                        if (l.bir.instTag(operand) == .pat_var and l.scalarOf(l.bir.instData(operand).lhs) != null) {
                            try l.constDecl(out, try l.localName(l.bir.instData(operand).lhs), at, p);
                        } else {
                            try l.bindings(out, operand, try l.call(try l.corePrivate(.view, p), &.{ base, at }, p));
                        }
                        continue;
                    }
                    if (l.bindCount(element.toOptional()) == 0) continue;
                    try l.bindings(out, element, try l.add(.index_get, p, base.int(), at.int()));
                }
            },
            else => try l.bindings(out, pattern, try l.materialise(k, offset, p)),
        }
    }

    /// Whether no `lambda` and no `let` function lies among the instructions
    /// from the first parameter's to the body's: a function the body makes
    /// is one of those, and `Bir` writes a function's instructions after its
    /// parameters and before its body's root. A hint (`Loop.ready`): what it
    /// misses — an eta-expansion of evidence, a constructor used as a value —
    /// the walk over the JavaScript catches, and what it sees outside the
    /// body costs the jumps their order and nothing else.
    fn mayGoInPlace(l: *Lowerer, params: []const Inst.Index, body: Inst.Index) bool {
        const start = if (params.len != 0) @min(@intFromEnum(params[0]), @intFromEnum(body)) else @intFromEnum(body);
        const tags = l.bir.insts.items(.tag);
        const data = l.bir.insts.items(.data);
        for (tags[start .. @intFromEnum(body) + 1], data[start .. @intFromEnum(body) + 1]) |tag, d| switch (tag) {
            .lambda => return false,
            .let_def => {
                const payload = l.bir.extraData(@enumFromInt(d.lhs), Bir.LetDef);
                if (payload.params_end != payload.params_start) return false;
            },
            else => {},
        };
        return true;
    }

    /// A name the loop writes with no counter, like `$in$<i>` (§8): input
    /// derived, and safe to repeat in a nested function because neither
    /// reads the other's.
    fn fixedName(l: *Lowerer, spelled: []const u8) !JsIr.NameIndex {
        const base = try l.interner.getOrPut(l.gpa, spelled);
        return l.name(.{ .module = .none, .base = base, .tag = JsIr.Name.no_tag });
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
                if (l.isSelfCall(inst, loop)) {
                    l.markCarried(inst, loop);
                    return true;
                }
                // `a || b` and `a && b`: `b` is in tail position, the
                // `if` a short-circuit is (§8, amended 2026-10-02).
                if (l.logicalRight(inst)) |right| return l.markTails(right, loop);
                // A cons step: the tail of a `::` in tail position is a tail
                // position again, and one that reaches a self-call makes the
                // function build (§8, *Tail calls modulo cons*).
                const tail = l.consTail(inst) orelse return false;
                if (!l.markTails(tail, loop)) return false;
                loop.builds = true;
                return true;
            },
            else => return false,
        }
    }

    /// The right operand of `a || b` or `a && b` — a saturated call of
    /// core's `Basics.or` or `and` — or null for any other instruction.
    /// In tail position it is a tail position too: `a || go x` is `if a
    /// then True else go x` (§8, amended 2026-10-02).
    fn logicalRight(l: *Lowerer, inst: Inst.Index) ?Inst.Index {
        if (l.bir.instTag(inst) != .call) return null;
        const d = l.bir.instData(inst);
        _ = l.logicalOp(@enumFromInt(d.lhs)) orelse return null;
        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
        if (args.len != 2) return null;
        return args[1];
    }

    /// The tail argument of a call of core's `List.cons` — what `::`
    /// desugars to — or null for any other instruction. Keyed on the core
    /// package, core's `List` module and the well-known `cons`, never on
    /// the spelling, exactly as `logicalOp` is.
    fn consTail(l: *Lowerer, inst: Inst.Index) ?Inst.Index {
        if (l.bir.instTag(inst) != .call) return null;
        const d = l.bir.instData(inst);
        if (!l.isListCons(@enumFromInt(d.lhs))) return null;
        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
        if (args.len != 2 or l.rootsOf(inst).len != 0) return null;
        return args[1];
    }

    fn isListCons(l: *Lowerer, callee: Inst.Index) bool {
        const d = l.bir.instData(callee);
        const base: Symbol = switch (l.bir.instTag(callee)) {
            .top => blk: {
                if (l.in.graph.module(l.in.module).package != .core) return false;
                if (l.module_name != InternPool.WellKnown.List.symbol()) return false;
                if (d.lhs >= l.bir.decls.len) return false;
                break :blk l.bir.symbol(l.bir.decls[d.lhs].name);
            },
            .ext_value => blk: {
                const module: Graph.Index = @enumFromInt(d.lhs);
                if (module.int() >= l.in.interfaces.len) return false;
                if (l.in.graph.module(module).package != .core) return false;
                if (l.in.graph.moduleName(module) != InternPool.WellKnown.List.symbol()) return false;
                const iface = &l.in.interfaces[module.int()];
                if (d.rhs >= iface.values.len) return false;
                break :blk iface.symbols[@intFromEnum(iface.values[d.rhs].name)];
            },
            else => return false,
        };
        return base == InternPool.WellKnown.cons.symbol();
    }

    /// Whether a tail self-call is reachable through `inst`'s tail
    /// positions, cons steps included: the test that makes a `::` in tail
    /// position a step rather than an ordinary returned value. Pure, unlike
    /// `markTails`, which has already marked every slot by the time the
    /// lowering asks.
    fn reachesSelf(l: *Lowerer, inst: Inst.Index, loop: *const Loop) bool {
        var at = inst;
        while (true) {
            const d = l.bir.instData(at);
            switch (l.bir.instTag(at)) {
                .let => at = @enumFromInt(d.rhs),
                .case => {
                    for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index)) |branch| {
                        if (l.bir.instTag(branch) != .branch) continue;
                        if (l.reachesSelf(@enumFromInt(l.bir.instData(branch).rhs), loop)) return true;
                    }
                    return false;
                },
                .call => {
                    if (l.isSelfCall(at, loop)) return true;
                    at = l.logicalRight(at) orelse l.consTail(at) orelse return false;
                },
                else => return false,
            }
        }
    }

    /// Whether `inst`, in tail position of a building loop, is a cons step.
    fn isConsStep(l: *Lowerer, inst: Inst.Index, loop: *const Loop) bool {
        if (!loop.builds) return false;
        const tail = l.consTail(inst) orelse return false;
        return l.reachesSelf(tail, loop);
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
        return l.rootsOf(inst).len == loop.evidence;
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
        const roots = l.rootsOf(inst);
        for (roots[0..@min(roots.len, loop.evidence)], 0..) |root, k| {
            const forwarded = switch (l.in.dispatch.term(root)) {
                .param => |p| p.k == k and switch (p.binder) {
                    .decl => loop.ev_let == .none,
                    .let => |at| loop.ev_let == at.toOptional(),
                    .derived => false,
                },
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
        const saved = l.evidence_out;
        l.evidence_out = out;
        defer l.evidence_out = saved;
        const d = l.bir.instData(inst);
        if (l.deadArm(inst)) {
            const nothing = try l.add(.undefined_lit, l.pos(inst), Node.Data.unused, Node.Data.unused);
            return l.tailReturn(out, nothing, loop, l.pos(inst));
        }
        switch (l.bir.instTag(inst)) {
            .let => {
                try l.letBindings(out, l.bir.subRange(@enumFromInt(d.lhs)));
                return l.tailStmts(out, @enumFromInt(d.rhs), loop);
            },
            .case => return l.tailCase(out, inst, loop),
            .tuple => if (loop) |lp| switch (lp.exit) {
                .tuple => |names| if (Bir.inlineRange(d).len() == names.len) return l.tupleExit(out, inst, lp, names),
                else => {},
            },
            .call => {
                if (loop) |lp| {
                    if (l.isSelfCall(inst, lp)) return l.tailJump(out, inst, lp);
                    if (l.isConsStep(inst, lp)) return l.consStep(out, inst, lp);
                    // `a || go x` that reaches the loop: `if (a) return
                    // true;`, then `go x` in tail position — a jump, not a
                    // call (§8, amended 2026-10-02). `&&` is `if (!a)
                    // return false;`.
                    if (l.logicalRight(inst)) |right| if (l.reachesSelf(right, lp)) {
                        const p = l.pos(inst);
                        const op = l.logicalOp(@enumFromInt(d.lhs)).?;
                        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
                        const left = try l.expr(out, args[0]);
                        var exit: StmtList = .empty;
                        const answer = try l.add(if (op == .logical_or) .true_lit else .false_lit, p, Node.Data.unused, Node.Data.unused);
                        try l.tailReturn(&exit, answer, loop, p);
                        try l.ifStatement(out, if (op == .logical_or) left else try l.negate(left, p), exit.items, p);
                        return l.tailStmts(out, right, loop);
                    };
                }
                if (try l.tailInline(inst, loop)) |index| {
                    if (!l.inline_loops[index]) return l.inlineTail(out, inst, index, loop);
                    if (try l.inlineLoop(out, inst, index, .@"return", &.{})) return;
                }
                // A `Js.finally` in tail position returns from inside the
                // guard: `try { …; return v; } finally { … }`. Not in a loop,
                // whose jump would run the cleanup before the next turn,
                // nor where a leaf calls a join.
                if (loop == null and l.join == .none) if (l.finallyArgs(inst)) |fa| {
                    _ = try l.finallyTry(out, fa[0], fa[1], .tail, l.pos(inst));
                    return;
                };
                // A `Js.catchIf` likewise: both blocks return.
                if (loop == null and l.join == .none) if (l.catchArgs(inst)) |ca| {
                    _ = try l.catchTry(out, ca[0], ca[1], ca[2], .tail, l.pos(inst));
                    return;
                };
                // `Js.pure`'s body is in tail position itself.
                if (l.pureBody(inst)) |body| return l.tailStmts(out, body, loop);
            },
            else => {},
        }
        const value = try l.expr(out, inst);
        // `Js.throw` in tail position ends the block itself: its value is
        // the `undefined` no `return` can reach (research 47 §6 item 2).
        if (out.items.len != 0 and l.b.nodes.items(.tag)[out.items[out.items.len - 1].int()] == .throw_stmt and
            l.b.nodes.items(.tag)[value.int()] == .undefined_lit) return;
        try l.tailReturn(out, value, loop, l.pos(inst));
    }

    /// Leave the function with `value`. A building loop (§8, *Tail calls
    /// modulo cons, onto an array*) hands over its destination: `return
    /// $root` when the value is the literal `[]`, and otherwise `return
    /// List$close($root, value)` — the value's elements pushed after what
    /// the steps pushed, or the value itself when they pushed nothing;
    /// everything else is `return value`.
    fn tailReturn(l: *Lowerer, out: *StmtList, value: Node.Index, loop: ?*const Loop, p: u32) !void {
        // A leaf of a `case` that joins (transparent-effects-proposal.md
        // §16.3): the rest of the function is the join, called with it.
        if (loop == null and l.join != .none) {
            return out.append(l.scratch, try l.returnStmt(try l.call(try l.ident(l.join, p), &.{value}, p), p));
        }
        const lp = loop orelse return out.append(l.scratch, try l.returnStmt(value, p));
        switch (lp.exit) {
            .@"return" => {},
            .discard => {
                try l.discardValue(out, value, p);
                return l.exitBreak(out, lp, p);
            },
            .assign => |n| {
                try l.exitAssign(out, lp, n, value, p);
                return l.exitBreak(out, lp, p);
            },
            // A value that is not a tuple literal (`tailStmts` writes those
            // element by element): its elements read from the tuple. An
            // arm nothing can reach has none.
            .tuple => |names| {
                if (l.b.nodes.items(.tag)[value.int()] != .undefined_lit) {
                    const tuple = try l.bindSubject(out, value, p);
                    for (names, 0..) |n, i| {
                        if (n == .none) continue;
                        const element = try l.member(tuple, try l.slotName(@intCast(i)), p);
                        try l.exitAssign(out, lp, n, element, p);
                    }
                }
                return l.exitBreak(out, lp, p);
            },
        }
        if (!lp.builds) return out.append(l.scratch, try l.returnStmt(value, p));
        const root = try l.ident(lp.root, p);
        if (l.isEmptyArray(value)) return out.append(l.scratch, try l.returnStmt(root, p));
        const closed = try l.call(try l.ident(try l.closeName(p), p), &.{ root, value }, p);
        try out.append(l.scratch, try l.returnStmt(closed, p));
    }

    /// `name = value` at an exit of a loop whose value is bound, recorded
    /// for `inlineLoop`, which may find the name is a loop variable's.
    fn exitAssign(l: *Lowerer, out: *StmtList, loop: *const Loop, n: JsIr.NameIndex, value: Node.Index, p: u32) !void {
        const stmt = try l.add(.assign_stmt, p, (try l.ident(n, p)).int(), value.int());
        try loop.jumps.exits.append(l.scratch, stmt);
        try out.append(l.scratch, stmt);
    }

    /// The `break` that ends an exit of a loop written where its value is
    /// bound or discarded; `loopOf` gives it the loop's label when it needs
    /// one.
    fn exitBreak(l: *Lowerer, out: *StmtList, loop: *const Loop, p: u32) !void {
        const brk = try l.add(.break_stmt, p, @intFromEnum(loop.label), Node.Data.unused);
        try loop.jumps.breaks.append(l.scratch, brk);
        try out.append(l.scratch, brk);
    }

    /// A tuple literal at an exit of a loop whose value a tuple pattern
    /// binds: each element evaluated in order and written into its name, no
    /// tuple built.
    fn tupleExit(l: *Lowerer, out: *StmtList, inst: Inst.Index, loop: *const Loop, names: []const JsIr.NameIndex) !void {
        const p = l.pos(inst);
        const elements = l.bir.extraSlice(Bir.inlineRange(l.bir.instData(inst)), Inst.Index);
        // The names are the caller's, bound by the pattern, and no element
        // can read one: they are written in order, as the elements are
        // evaluated.
        const values = try l.orderedExprs(out, elements, false);
        for (values, names) |value, n| {
            if (n == .none) {
                try l.discardValue(out, value, p);
                continue;
            }
            try l.exitAssign(out, loop, n, value, p);
        }
        return l.exitBreak(out, loop, p);
    }

    /// A cons step and every cons step directly under it, `[ a, b, ...go
    /// rest ]`: one `$root.push(h)` per head, then whatever the innermost
    /// tail is — a jump, a `case`, a `let` — lowered in tail position.
    ///
    /// **Each head is evaluated in its own statement, before the next head
    /// and before the self-call's arguments**, which is the order the
    /// recursive version evaluates them in. A head that hoists statements
    /// (a `case`) emits them here, after the pushes written before it.
    fn consStep(l: *Lowerer, out: *StmtList, inst: Inst.Index, loop: *const Loop) !void {
        var at = inst;
        while (true) {
            const p = l.pos(at);
            const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(at).rhs)), Inst.Index);
            const head = try l.expr(out, args[0]);
            const push = try l.call(try l.member(try l.ident(loop.root, p), l.well.push, p), &.{head}, p);
            try out.append(l.scratch, try l.add(.expr_stmt, p, push.int(), Node.Data.unused));
            if (l.isConsStep(args[1], loop)) {
                at = args[1];
                continue;
            }
            return l.tailStmts(out, args[1], loop);
        }
    }

    /// A tail self-call: the argument expressions, the assignments to the
    /// carried slots in parameter order, and `continue <label>`. The
    /// `continue` is LABELLED and not bare, because §7's decision trees put
    /// a `switch` and a shared-branch loop between the jump and this one.
    fn tailJump(l: *Lowerer, out: *StmtList, inst: Inst.Index, loop: *const Loop) !void {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        l.region = inst;
        const evidence = try l.evidenceArguments(l.rootsOf(inst), p);
        // An argument that is a scalar slot's own list — its parameter or a
        // `rest` of it — is passed as the offset it holds (§8, *Scalar
        // views*).
        const raw_mark = l.scalar_raw.items.len;
        defer l.scalar_raw.shrinkRetainingCapacity(raw_mark);
        for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index), 0..) |arg, j| {
            const local = if (l.bir.instTag(arg) == .local)
                l.bir.instData(arg).lhs
            else if (try l.reconsOf(arg)) |recons|
                recons.tail
            else
                continue;
            const k = l.scalarOf(local) orelse continue;
            const scalar = l.scalars.items[k];
            if (scalar.label == loop.label and scalar.slot == loop.evidence + j) try l.scalar_raw.append(l.scratch, arg);
        }
        const written = try l.exprList(out, l.bir.subRange(@enumFromInt(d.rhs)));
        const values = try l.scratch.alloc(Node.Index, loop.slots.len);
        for (loop.slots, values, 0..) |slot, *value, i| {
            if (!slot.carried) continue;
            value.* = if (i < evidence.len) evidence[i] else written[i - evidence.len];
        }
        if (loop.ready) try l.jumpInPlace(out, loop, values, p) else {
            // The copies stay, and the assignments read nothing they write:
            // parameter order, no temporary (§8's original shape).
            for (loop.slots, values, 0..) |slot, value, i| {
                if (!slot.carried) continue;
                if (slot.unwritten) {
                    try l.discardValue(out, value, p);
                    continue;
                }
                try l.jumpAssign(out, loop, @intCast(i), value, p);
            }
        }
        const jump = try l.add(.continue_stmt, p, @intFromEnum(loop.label), Node.Data.unused);
        try loop.jumps.continues.append(l.scratch, jump);
        try out.append(l.scratch, jump);
    }

    /// A jump's assignments written ready to reassign the parameters in
    /// place (`Loop.ready`).
    fn jumpInPlace(l: *Lowerer, out: *StmtList, loop: *const Loop, values: []const Node.Index, p: u32) !void {
        // The assignments may become writes of the parameters themselves
        // (`functionOrLoop`, §8 *In place, when nothing captures*). Then a
        // value that reads a parameter an EARLIER assignment rebinds would
        // read the new one, so that earlier value goes through a temporary
        // and its assignment moves after the rest. Every value is still
        // evaluated in parameter order, and every parameter is read before
        // it is rebound. With the copies kept, the temporary is harmless.
        //
        // When no value makes a call, evaluating one before another is not
        // observable, so the assignments are ordered instead: each parameter
        // is rebound once no value still to come reads it, and only a cycle
        // (`f b a`) takes a temporary. `count (n - 1) (acc + n)` is
        // `acc = acc + n; n = n - 1;`.
        const n_slots = loop.slots.len;
        // `reads[m * n_slots + i]`: whether value `m` reads parameter `i`.
        const reads = try l.scratch.alloc(bool, n_slots * n_slots);
        @memset(reads, false);
        var movable = true;
        for (loop.slots, values, 0..) |slot, value, m| {
            if (!slot.carried) continue;
            if ((try l.b.holds(l.scratch, &.{value}, .none)).call) movable = false;
            for (loop.slots, 0..) |other, i| {
                if (i == m or !other.carried or other.body == .none) continue;
                reads[m * n_slots + i] = (try l.b.holds(l.scratch, &.{value}, other.body)).reads;
            }
        }
        const deferred = try l.scratch.alloc(?JsIr.NameIndex, n_slots);
        @memset(deferred, null);
        const done = try l.scratch.alloc(bool, n_slots);
        for (loop.slots, done) |slot, *x| x.* = !slot.carried;
        // Whether a value not yet evaluated, other than `i`'s own, reads `i`.
        const Pending = struct {
            fn readBy(r: []const bool, finished: []const bool, n: usize, i: usize) bool {
                for (finished, 0..) |f, m| if (!f and m != i and r[m * n + i]) return true;
                return false;
            }
        };
        var left: usize = 0;
        for (done) |x| left += @intFromBool(!x);
        while (left != 0) : (left -= 1) {
            // The first slot, in parameter order, that may go now: any, in
            // order, when a value may call; otherwise one nothing pending
            // reads, or failing that — a cycle — the first, through a
            // temporary.
            var pick: usize = 0;
            var free = false;
            for (done, 0..) |x, i| {
                if (x) continue;
                if (!movable) {
                    pick = i;
                    free = !Pending.readBy(reads, done, n_slots, i);
                    break;
                }
                if (!Pending.readBy(reads, done, n_slots, i)) {
                    pick = i;
                    free = true;
                    break;
                }
            } else {
                for (done, 0..) |x, i| if (!x) {
                    pick = i;
                    break;
                };
            }
            done[pick] = true;
            if (loop.slots[pick].unwritten) {
                try l.discardValue(out, values[pick], p);
                continue;
            }
            if (free) {
                try l.jumpAssign(out, loop, @intCast(pick), values[pick], p);
                continue;
            }
            const t = try l.fresh(l.well.temp);
            try l.constDecl(out, t, values[pick], p);
            deferred[pick] = t;
        }
        for (deferred, 0..) |temp, i| {
            const t = temp orelse continue;
            try l.jumpAssign(out, loop, @intCast(i), try l.ident(t, p), p);
        }
    }

    /// `slot = value;` in a jump, the target recorded for `functionOrLoop`.
    fn jumpAssign(l: *Lowerer, out: *StmtList, loop: *const Loop, slot: u32, value: Node.Index, p: u32) !void {
        const target = try l.ident(loop.slots[slot].param, p);
        try loop.jumps.targets.append(l.scratch, .{ .node = target, .slot = slot });
        try out.append(l.scratch, try l.add(.assign_stmt, p, target.int(), value.int()));
    }

    // ---- Names and references ---------------------------------------------

    fn localName(l: *Lowerer, index: u32) !JsIr.NameIndex {
        if (index >= l.locals.len) return l.fresh(l.well.param);
        if (l.local_names[index] != .none) return l.local_names[index];
        const local = l.locals[index];
        // The local INDEX is the disambiguator: two sibling branches may
        // each bind `x`, and JavaScript's block scoping would hide one
        // behind the other in the shapes the decision trees produce.
        // Distinct indices therefore get distinct names, and the source
        // name is still the prefix so a stack trace reads.
        const n = if (local.name.unwrap()) |symbol| try l.name(.{
            .module = .none,
            .base = l.bir.symbols[symbol],
            .tag = l.local_tag_base + index + 1,
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
        if (owner.kind == .type_alias) return .{ .record = .{ .local = c.decl.int() } };
        const int: CtorRep.Tag = if (l.integerTags(l.in.types.ofDecl(l.in.module, c.decl))) ctor_index - owner.ctors_start else null;
        if (max == 0) return .{ .bare_tag = int };
        return .{ .tagged = .{ .fields = max, .int = int } };
    }

    /// Whether `id`'s constructors have integer tags in this build
    /// (`backend.md` §9, *Item 4, taken up*): never in a development build.
    fn integerTags(l: *const Lowerer, id: Dispatch.TypeId) bool {
        const b = l.in.boundary orelse return false;
        return b.integerTags(id);
    }

    /// A constructor's tag as a literal: its declaration index when its
    /// type has integer tags, else its name.
    fn tagLiteral(l: *Lowerer, rep: CtorRep, tag: Symbol, p: u32) !Node.Index {
        if (rep.int()) |i| return l.intNode(i, p);
        return l.stringNode(l.text(tag), p);
    }

    /// The field names of a record alias's constructor, in argument order:
    /// the body of a local declaration, or an imported constructor row's
    /// names (`RecordRep`).
    fn recordNames(l: *Lowerer, r: RecordRep) ![]const Symbol {
        if (l.record_names) |last| {
            if (std.meta.eql(last.rep, r)) return last.names;
        }
        const names = try l.recordNamesOf(r);
        l.record_names = .{ .rep = r, .names = names };
        return names;
    }

    fn recordNamesOf(l: *Lowerer, r: RecordRep) ![]const Symbol {
        switch (r) {
            .local => |decl| {
                const body = l.bir.decls[decl].annotation.unwrap() orelse return &.{};
                if (l.bir.instTag(body) != .type_record) return &.{};
                const fields = l.bir.extraSlice(Bir.inlineRange(l.bir.instData(body)), Bir.Field);
                const names = try l.scratch.alloc(Symbol, fields.len);
                for (fields, names) |f, *n| n.* = l.bir.symbol(f.name);
                return names;
            },
            .imported => |at| {
                const iface = &l.in.interfaces[at.module.int()];
                const words = iface.range(iface.ctors[at.ctor].fields);
                const names = try l.scratch.alloc(Symbol, words.len);
                for (words, names) |word, *n| n.* = iface.symbol(@enumFromInt(word));
                return names;
            },
        }
    }

    /// The canonical key order of a record whose fields are `names`: a
    /// permutation of their indices, sorted by NAME TEXT (`recordNode`).
    fn fieldOrder(l: *Lowerer, names: []const Symbol) ![]u32 {
        const order = try l.scratch.alloc(u32, names.len);
        for (order, 0..) |*slot, i| slot.* = @intCast(i);
        const Sorter = struct {
            lower: *Lowerer,
            names: []const Symbol,
            fn lessThan(s: @This(), a: u32, b: u32) bool {
                return std.mem.lessThan(u8, s.lower.text(s.names[a]), s.lower.text(s.names[b]));
            }
        };
        std.mem.sort(u32, order, Sorter{ .lower = l, .names = names }, Sorter.lessThan);
        return order;
    }

    fn isPermuted(order: []const u32) bool {
        for (order, 0..) |field, k| {
            if (field != k) return true;
        }
        return false;
    }

    /// The property a constructor's argument `i` is read from: the alias's
    /// field `i` (declaration order) for a record alias's constructor, whose
    /// value IS the record (backend.md §4), and the positional `a`, `b`, …
    /// for every other one — `via` null included, which is a tuple's or a
    /// list cell's occurrence.
    ///
    /// A record alias's constructor PATTERN (`nameOf (User n _) = n`) is
    /// accepted by the front end, and it is irrefutable — one constructor —
    /// so it compiles to these reads with no test (decided 2026-09-24 under
    /// rule 7).
    fn argMember(l: *Lowerer, target: Node.Index, via: ?Inst.Index, i: u32, p: u32) !Node.Index {
        if (via) |ref| {
            if (l.ctorRepOf(ref)) |rep_and_tag| switch (rep_and_tag[0]) {
                .record => |r| {
                    const names = try l.recordNames(r);
                    if (i < names.len) return l.fieldMember(target, names[i], p);
                },
                else => {},
            };
        }
        return l.member(target, try l.slotName(i), p);
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
        // A record alias's constructor builds the record, whichever module
        // declared it (backend.md §4's row; interface v3 carries the
        // names).
        if (c.result == .record_alias) return .{ .record = .{ .imported = .{ .module = module, .ctor = ctor_index } } };
        // The interface lists a type's constructors in declaration order,
        // so the index is the one the declaring module writes.
        const int: CtorRep.Tag = if (l.integerTags(l.in.types.ofInterface(module, c.type))) ctor_index - owner.ctors_start else null;
        if (max == 0) return .{ .bare_tag = int };
        return .{ .tagged = .{ .fields = max, .int = int } };
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
            .bare_tag => return l.tagLiteral(rep, tag, p),
            .tagged => |t| {
                var properties: std.ArrayList(Node.Index) = .empty;
                try properties.append(l.scratch, try l.property(l.well.tag, try l.tagLiteral(rep, tag, p), p));
                for (0..t.fields) |i| {
                    const slot = try l.slotName(@intCast(i));
                    const value = if (i < args.len) args[i] else try l.nullNode(p);
                    try properties.append(l.scratch, try l.property(slot, value, p));
                }
                return l.object(properties.items, p);
            },
            .record => |r| {
                // `args` are already in written order, pinned by the caller
                // wherever the key order below would move an evaluation.
                const names = try l.recordNames(r);
                const order = try l.fieldOrder(names);
                var properties: std.ArrayList(Node.Index) = .empty;
                for (order) |field| {
                    const value = if (field < args.len) args[field] else try l.nullNode(p);
                    try properties.append(l.scratch, try l.fieldProperty(names[field], value, p));
                }
                return l.object(properties.items, p);
            },
        }
    }

    /// The module-level constant that holds nullary constructor `inst` of a
    /// `tagged` type (`backend.md` §4, *A nullary constructor is one
    /// object*): `<Module>$<Ctor>` for this module's own constructor,
    /// `<Module>$<Declaring$Module>$<Ctor>` for an imported one. The name
    /// is asked for at every use and the constant is written once, by
    /// `nullaryDecls`.
    fn nullaryConstant(l: *Lowerer, inst: Inst.Index, rep: CtorRep, tag: Symbol) !JsIr.NameIndex {
        const d = l.bir.instData(inst);
        const key: NullaryKey = switch (l.bir.instTag(inst)) {
            .ctor => .{ .ext = false, .module = 0, .ctor = d.lhs },
            else => .{ .ext = true, .module = d.lhs, .ctor = d.rhs },
        };
        const slot = try l.nullary.getOrPut(l.scratch, key);
        if (slot.found_existing) return slot.value_ptr.name;
        const base = if (key.ext) blk: {
            const path = l.text(l.in.graph.moduleName(@enumFromInt(key.module)));
            const out = try std.fmt.allocPrint(l.scratch, "{s}${s}", .{ path, l.text(tag) });
            for (out[0..path.len]) |*c| {
                if (c.* == '.') c.* = '$';
            }
            break :blk out;
        } else l.text(tag);
        slot.value_ptr.* = .{ .base = base, .name = try l.synthesisedName(base), .rep = rep, .tag = tag };
        return slot.value_ptr.name;
    }

    /// Every constant `nullaryConstant` named, sorted by printed name so the
    /// order is the source's and not the order of discovery (CLAUDE.md
    /// rule 5). Each is an object literal of strings and `null`s, so it
    /// reads nothing and may go first.
    fn nullaryDecls(l: *Lowerer) ![]const Node.Index {
        const values = l.nullary.values();
        const Sorter = struct {
            fn before(_: void, a: Nullary, b: Nullary) bool {
                return std.mem.lessThan(u8, a.base, b.base);
            }
        };
        const sorted = try l.scratch.dupe(Nullary, values);
        std.mem.sort(Nullary, sorted, {}, Sorter.before);
        const out = try l.scratch.alloc(Node.Index, sorted.len);
        for (sorted, out) |c, *slot| {
            const value = try l.ctorValue(c.rep, c.tag, &.{}, Node.no_pos);
            slot.* = try l.add(.const_decl, Node.no_pos, @intFromEnum(c.name), value.int());
        }
        return out;
    }

    // ---- Lists ------------------------------------------------------------
    //
    // `List` is array-backed (`backend.md` §4, *Lists are arrays*): a
    // literal is an array literal, `[]` a fresh empty one at each use, and
    // every other form a list takes — a view, a trie — is `core/List.js`'s.
    // The emitter reads a list through `.length` and calls `core/List` for
    // the rest: `unsafeGet` and `view` for a pattern (§7), `slice` for a
    // spread with items after it, `close` for a building loop's exit (§8).

    /// An array literal of `elements`, evaluated left to right. It nests at
    /// no length (§4's list row), so a written list of any size is flat.
    fn arrayNode(l: *Lowerer, elements: []const Node.Index, p: u32) !Node.Index {
        const range = try l.b.addRange(elements);
        return l.add(.array, p, @intFromEnum(range.start), @intFromEnum(range.end));
    }

    /// Whether `value` is the literal `[]`: an array literal of nothing.
    fn isEmptyArray(l: *Lowerer, value: Node.Index) bool {
        if (l.b.nodes.items(.tag)[value.int()] != .array) return false;
        const d = l.b.nodes.items(.data)[value.int()];
        return d.lhs == d.rhs;
    }

    /// `List$close`, core-private (`core/List.beni`): a building loop's
    /// exit, and a suspended building loop's continuation.
    fn closeName(l: *Lowerer, p: u32) !JsIr.NameIndex {
        return l.identName(try l.corePrivate(.close, p));
    }

    /// The name an `ident` node spells.
    fn identName(l: *Lowerer, n: Node.Index) JsIr.NameIndex {
        std.debug.assert(l.b.nodes.items(.tag)[n.int()] == .ident);
        return @enumFromInt(l.b.nodes.items(.data)[n.int()].lhs);
    }

    /// One of `core/List`'s values the emitter calls by well-known symbol:
    /// `coreValue` names a `pub` one, this the core-private `unsafeGet`,
    /// `view` and `close` (§4, *The emitter's imports of the core-private
    /// exports*). They are in no interface — no program may name them — so
    /// another module imports each by its printed name, as it imports a
    /// derived function (`needDerived`), and `core/List` exports what
    /// survives of them (`exports`).
    fn corePrivate(l: *Lowerer, function: InternPool.WellKnown, p: u32) !Node.Index {
        const module = l.in.graph.lookup(.core, InternPool.WellKnown.List.symbol()) orelse
            return l.missingCoreValue(p, "List", l.interner.slice(function.symbol()), "there is no such module in the core package");
        if (module == l.in.module) {
            for (l.bir.decls, 0..) |d, i| {
                if (l.bir.symbol(d.name) != function.symbol()) continue;
                return l.ident(try l.topName(@intCast(i)), p);
            }
            return l.missingCoreValue(p, "List", l.interner.slice(function.symbol()), "this module IS that module, and it does not declare it");
        }
        const entry: Needed = .{ .module = module, .base = function.symbol().toOptional() };
        try l.needName(entry);
        return l.ident(try l.neededName(entry), p);
    }

    /// Whether `pattern`, a spread's operand, binds a name something reads:
    /// §7's rule that a tail is bound only on a leaf that reads it, since a
    /// view is an allocation.
    fn bindsRead(l: *Lowerer, pattern: Inst.Index) Allocator.Error!bool {
        return switch (l.bir.instTag(pattern)) {
            .pat_wild => false,
            .pat_var => l.localRead(l.bir.instData(pattern).lhs),
            else => true,
        };
    }

    /// Whether any `local` instruction of the declaration being lowered reads
    /// its local `index` (a local index is the declaration's own).
    fn localRead(l: *Lowerer, index: u32) Allocator.Error!bool {
        const decl = l.decl_index orelse return true;
        if (l.read_locals == null or l.read_locals_decl != decl) {
            l.read_locals_decl = decl;
            var set = try std.DynamicBitSetUnmanaged.initEmpty(l.scratch, l.locals.len);
            const d = l.bir.decls[decl];
            const start = d.inst_start.int();
            const end = @min(d.inst_end.int(), l.bir.insts.len);
            const tags = l.bir.insts.items(.tag)[start..end];
            const datas = l.bir.insts.items(.data)[start..end];
            for (tags, datas) |tag, data| {
                if (tag == .local and data.lhs < set.bit_length) set.set(data.lhs);
            }
            l.read_locals = set;
        }
        const set = l.read_locals.?;
        return index >= set.bit_length or set.isSet(index);
    }

    /// `List$unsafeGet(list, index)`: an element a pattern reads.
    fn listElement(l: *Lowerer, list: Node.Index, index: Node.Index, p: u32) !Node.Index {
        return l.call(try l.corePrivate(.unsafeGet, p), &.{ list, index }, p);
    }

    /// The integer `k` as a node.
    fn intNode(l: *Lowerer, k: u32, p: u32) !Node.Index {
        var buf: [10]u8 = undefined;
        return l.numberNode(std.fmt.bufPrint(&buf, "{d}", .{k}) catch unreachable, p);
    }

    /// `list.length`, which every form answers (§4's protocol).
    fn lengthOf(l: *Lowerer, list: Node.Index, p: u32) !Node.Index {
        return l.member(list, l.well.length, p);
    }

    /// `list.length - count`: where the last `count` elements start.
    fn lengthMinus(l: *Lowerer, list: Node.Index, count: u32, p: u32) !Node.Index {
        return l.binary(.sub, try l.lengthOf(list, p), try l.intNode(count, p), p);
    }

    // ---- Expressions ------------------------------------------------------

    /// The elements of one written-order list — a call's arguments, a
    /// tuple's or a list's elements. Ordered, because any of them may hoist
    /// statements (a `case`, a `?`) that would otherwise run in front of the
    /// elements written before it.
    fn exprList(l: *Lowerer, out: *StmtList, range: Bir.SubRange) ![]Node.Index {
        return l.orderedExprs(out, l.bir.extraSlice(range, Inst.Index), false);
    }

    /// A callee or a receiver and then its arguments, as ONE written-order
    /// sequence: `f a b` evaluates `f` first (`language.md` §6), so a `?`
    /// among the arguments may not hoist its early return in front of it.
    /// Element 0 of the result is the head.
    fn exprListWithHead(l: *Lowerer, out: *StmtList, head: Inst.Index, range: Bir.SubRange) ![]Node.Index {
        const items = l.bir.extraSlice(range, Inst.Index);
        const insts = try l.scratch.alloc(Inst.Index, items.len + 1);
        insts[0] = head;
        @memcpy(insts[1..], items);
        return l.orderedExprs(out, insts, false);
    }

    /// Lower a run of sub-expressions in the order they are WRITTEN, and
    /// keep their evaluation in that order however the caller emits the
    /// values (`language.md` §6, *Evaluation order*).
    ///
    /// Two things move an evaluation once the values are back in the
    /// caller's hands. The caller may emit them in another order — a record
    /// literal sorts its keys so that one record type has one hidden class
    /// (§4) — and a LATER element may hoist statements of its own, which
    /// run before the expression the earlier values are still sitting
    /// inside. The answer to both is the same: pin the value that would
    /// move to a `const` where it was written, and hand the caller the
    /// name.
    ///
    /// **A temporary is bought only where one is needed**, so the emitted
    /// bytes do not change under a caller that reorders nothing:
    ///
    ///   - an ATOM is never pinned. A literal, a name, or the `$t$<n>` a
    ///     `case` has already assigned costs nothing to re-read and has
    ///     nothing to observe, so no order over it is visible;
    ///   - when the caller reorders, the non-atoms are pinned only if there
    ///     are **two or more** of them: one evaluation cannot be reordered
    ///     against pure atoms;
    ///   - a hoist pins everything non-atomic written before the LAST
    ///     element that hoists, and nothing after it.
    fn orderedExprs(l: *Lowerer, out: *StmtList, insts: []const Inst.Index, reordered: bool) ![]Node.Index {
        const values = try l.scratch.alloc(Node.Index, insts.len);
        const held = try l.scratch.alloc([]const Node.Index, insts.len);
        var movable: usize = 0;
        // Each element into a list of its own: whether it hoists is not
        // known until it is lowered, and what it hoists may not be written
        // out before the elements in front of it are pinned.
        for (insts, 0..) |inst, i| {
            var stmts: StmtList = .empty;
            values[i] = try l.expr(&stmts, inst);
            held[i] = stmts.items;
            if (!l.isAtom(values[i])) movable += 1;
        }
        var last_hoist: usize = 0;
        for (held, 0..) |stmts, i| {
            if (stmts.len != 0 and !l.onlyClosures(stmts)) last_hoist = i;
        }
        const pin_all = reordered and movable >= 2;
        for (insts, 0..) |inst, i| {
            try out.appendSlice(l.scratch, held[i]);
            if (l.isAtom(values[i])) continue;
            if (!pin_all and i >= last_hoist) continue;
            const p = l.pos(inst);
            const n = try l.fresh(l.well.temp);
            try l.constDecl(out, n, values[i], p);
            values[i] = try l.ident(n, p);
        }
        return values;
    }

    /// Whether every statement is `const $t = (…) => …`: a closure bound
    /// ahead of its use (`backend.md` §4). Making a closure evaluates
    /// nothing, so binding one early moves no evaluation, and the values
    /// written before it need no pinning.
    fn onlyClosures(l: *Lowerer, stmts: []const Node.Index) bool {
        const tags = l.b.nodes.items(.tag);
        const datas = l.b.nodes.items(.data);
        for (stmts) |stmt| {
            if (tags[stmt.int()] != .const_decl) return false;
            if (tags[datas[stmt.int()].rhs] != .arrow) return false;
        }
        return true;
    }

    /// Whether a value can be re-read wherever it lands: no work to repeat,
    /// nothing to observe, and therefore no order to keep. `bindSubject`
    /// and `orderedExprs` ask this of the same node tags for the same
    /// reason.
    fn isAtom(l: *Lowerer, value: Node.Index) bool {
        return switch (l.b.nodes.items(.tag)[value.int()]) {
            // A `Js.Ref` written as a `let` is a name a write may rebind
            // (`findRefs`): a read of one keeps its place like any work.
            .ident => l.mutable_names.items.len == 0 or !l.isMutable(value),
            .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this => true,
            else => false,
        };
    }

    /// Whether `value` is an `ident` of the name `n`.
    fn isIdentOf(l: *Lowerer, value: Node.Index, n: JsIr.NameIndex) bool {
        return l.b.nodes.items(.tag)[value.int()] == .ident and l.b.nodes.items(.data)[value.int()].lhs == @intFromEnum(n);
    }

    /// Whether `value` is an `ident` naming a `Js.Ref` written as a `let`.
    fn isMutable(l: *Lowerer, value: Node.Index) bool {
        if (l.b.nodes.items(.tag)[value.int()] != .ident) return false;
        const n: JsIr.NameIndex = @enumFromInt(l.b.nodes.items(.data)[value.int()].lhs);
        return std.mem.indexOfScalar(JsIr.NameIndex, l.mutable_names.items, n) != null;
    }

    /// Lower one expression, and keep what it emits as shallow as the
    /// engines need (`backend.md` §4, *Emitted JavaScript nests only as deep
    /// as the source*): a value that has grown `nesting.spill` tall is bound
    /// to a `const $t$<n>` in `out` and the name stands in for it.
    ///
    /// **Binding it there moves nothing.** `out` is where every statement an
    /// expression hoists goes — a `case`'s, a `?`'s — so it runs exactly
    /// where the value would have been evaluated, and every caller that
    /// holds a run of written-order values already pins what was written
    /// before a hoist (`orderedExprs`). A spill is one more hoist; the
    /// machinery that makes `?` evaluate in written order makes this do so
    /// too. A branch of a short circuit or of a `case` has an `out` of its
    /// own, so nothing is ever evaluated that the source would not have.
    fn expr(l: *Lowerer, out: *StmtList, inst: Inst.Index) Allocator.Error!Node.Index {
        const saved = l.evidence_out;
        l.evidence_out = out;
        defer l.evidence_out = saved;
        // `expr_height` is the running maximum of the expressions lowered
        // inside this one — each nested `expr` raises it on the way out — so
        // it is this expression's height without one frame per node.
        const outer = l.expr_height;
        l.expr_height = 0;
        const value = try l.exprValue(out, inst);
        var height = l.expr_height +| l.exprWeight(inst);
        if (l.isAtom(value)) {
            height = 0;
        } else if (height >= JsIr.nesting.spill) {
            const p = l.pos(inst);
            const n = try l.fresh(l.well.temp);
            try l.constDecl(out, n, value, p);
            l.expr_height = outer;
            return l.ident(n, p);
        }
        l.expr_height = @max(outer, height);
        return value;
    }

    /// What one instruction's own JavaScript adds to the expression it
    /// stands in, in `nesting`'s units — the construct's weight, the same
    /// table `JsIr.Builder.measure` reads, looked up by the instruction and
    /// not by the nodes it became: an estimate made where it is cheap, which
    /// `refuseTooDeep`'s exact measurement backs.
    fn exprWeight(l: *Lowerer, inst: Inst.Index) u32 {
        const w = JsIr.nesting;
        return switch (l.bir.instTag(inst)) {
            .call, .method_call, .type_dispatch => w.object,
            .record, .record_update, .tuple => w.object,
            .list => w.array,
            .field_access, .tuple_index, .interp => w.member,
            .case => w.cond,
            .lambda => w.arrow,
            else => 0,
        };
    }

    fn exprValue(l: *Lowerer, out: *StmtList, inst: Inst.Index) Allocator.Error!Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        l.region = inst;
        if (l.deadArm(inst)) return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
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
                // Segment by segment, left to right (`language.md` §6); a
                // literal chunk evaluates nothing, so only the expression
                // segments are a sequence and the chunks are threaded back
                // into their places afterwards.
                const parts = l.bir.extraSlice(Bir.inlineRange(d), Inst.Index);
                var holes: std.ArrayList(Inst.Index) = .empty;
                for (parts) |part| {
                    if (l.bir.instTag(part) == .chunk) continue;
                    try holes.append(l.scratch, part);
                }
                const values = try l.orderedExprs(out, holes.items, false);
                var nodes: std.ArrayList(Node.Index) = .empty;
                var next: usize = 0;
                for (parts) |part| {
                    if (l.bir.instTag(part) == .chunk) {
                        const offset, const len = try l.b.addString(l.bir.bytes(part));
                        try nodes.append(l.scratch, try l.add(.template_chunk, l.pos(part), offset, len));
                        continue;
                    }
                    try nodes.append(l.scratch, values[next]);
                    next += 1;
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
            .list => return l.arrayNode(try l.exprList(out, Bir.inlineRange(d)), p),
            .record => return l.recordNode(out, Bir.inlineRange(d), p),
            .record_update => {
                // The base, then the updated fields in written order
                // (`language.md` §6). Nothing is sorted — a spread carries
                // the key order of the record it spreads — so the only
                // thing that can move an evaluation here is a later field
                // that hoists statements, which is what `orderedExprs`
                // pins against.
                const fields = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Bir.Field);
                const insts = try l.scratch.alloc(Inst.Index, fields.len + 1);
                insts[0] = @enumFromInt(d.lhs);
                for (fields, insts[1..]) |f, *slot| slot.* = f.value;
                const values = try l.orderedExprs(out, insts, false);
                var properties: std.ArrayList(Node.Index) = .empty;
                try properties.append(l.scratch, try l.add(.spread_property, p, values[0].int(), Node.Data.unused));
                for (fields, values[1..]) |f, value| {
                    try properties.append(l.scratch, try l.fieldProperty(l.bir.symbol(f.name), value, p));
                }
                return l.object(properties.items, p);
            },
            .field_access => {
                const target = try l.expr(out, @enumFromInt(d.lhs));
                return l.fieldMember(target, l.bir.symbols[d.rhs], p);
            },
            .tuple_index => {
                const target = try l.expr(out, @enumFromInt(d.lhs));
                return l.member(target, try l.slotName(d.rhs), p);
            },
            .call => return l.callExpr(out, inst),
            .method_call => return l.methodCallExpr(out, inst),
            .lambda => {
                const params = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.lhs)), Inst.Index);
                // The body is bound inside itself, so no expression of it is
                // taller than `nesting.spill` — but it still nests INSIDE
                // whatever this lambda is an argument of, so its tallest
                // expression counts toward this one, and past the spill the
                // expression holding the lambda is bound to a `const` where
                // it stands, like any other (`backend.md` §4). Without this
                // a `view` of `List.map`s twenty deep would be refused.
                const height = l.expr_height;
                l.expr_height = 0;
                const suspends = l.functionSuspends(inst);
                const record = try l.functionOf(0, .none, params, @enumFromInt(d.rhs), suspends);
                const body = l.expr_height;
                const arrow = try l.add(.arrow, p, @intFromEnum(record), Node.Data.unused);
                if (l.in.unit_results and !suspends and l.unitValued(@enumFromInt(d.rhs))) try l.unobserved_arrows.append(l.scratch, arrow);
                if (body < lambda_spill) {
                    l.expr_height = @max(height, body);
                    return arrow;
                }
                // A tall body: the closure itself is bound where it is
                // made, so what it is an argument of nests nothing of it.
                l.expr_height = height;
                const n = try l.fresh(l.well.temp);
                try l.constDecl(out, n, arrow, p);
                return l.ident(n, p);
            },
            .let => {
                // Each binding is a statement of its own; only the body is
                // this expression.
                const height = l.expr_height;
                try l.letBindings(out, l.bir.subRange(@enumFromInt(d.lhs)));
                l.expr_height = height;
                return l.expr(out, @enumFromInt(d.rhs));
            },
            .case => return l.caseExpr(out, inst),
            .local, .top, .ctor, .ext_value, .ext_ctor => return l.reference(inst),
            .@"try" => return l.tryExpr(out, inst),
            .type_dispatch => return l.typeDispatchExpr(out, inst),
            // A poisoned instruction: the name did not resolve or the
            // parser could not build a node. `beni build` refuses to emit a
            // project with any error diagnostic, so this is unreachable
            // from a successful build; emitting `undefined` rather than
            // asserting keeps a bug in that gate from becoming a crash.
            .@"error" => return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
            // Markup compiles through the build's markup lowering. `Emit`
            // refuses a build in which markup survives and no lowering is
            // named (`unknown_markup_lowering`), so with none this is
            // unreachable and, like `error`, `undefined` rather than a crash.
            .markup => return l.markupExpression(out, inst),
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
            .pat_spread,
            .pat_record,
            .pat_as,
            .let_def,
            .let_pattern,
            .branch,
            .schema_ref,
            .schema_app,
            .schema_paren,
            .schema_record,
            .schema_field,
            .schema_value,
            .schema_tagged,
            .schema_variant,
            .schema_as,
            .schema_via,
            .schema_optional,
            .schema_nullable,
            .schema_expr_ref,
            .schema_type_ref,
            .schema_value_ref,
            .schema_ctor_ref,
            .schema_member_top,
            .ext_schema_member,
            .schema_ctor_top,
            .ext_schema_ctor,
            .schema_type_top,
            .ext_schema_type,
            .schema_parameter,
            .schema_primitive,
            .schema_target_top,
            .ext_schema_target,
            => return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
        }
    }

    /// A record literal, keys in a canonical order (§4: one hidden class per
    /// record type). Sorted by the NAME TEXT, not by symbol: a symbol's
    /// number depends on which worker interned which file, and two modules
    /// building the same record type have to agree on the key order or V8
    /// sees two shapes.
    ///
    /// **The sort moves the KEYS and never an initialiser.** It is the
    /// permutation that is sorted here and not the fields, so the
    /// initialisers are lowered in written order (`language.md` §6,
    /// *Evaluation order*) and `orderedExprs` pins whichever of them the
    /// key order — or a later initialiser's statements — would otherwise
    /// move. Sorting the fields first and lowering each one, which is what
    /// this did until 2026-09-18, dragged the evaluation along with the key
    /// and ran `{ zed = p, alpha = q }` as `q` then `p`.
    fn recordNode(l: *Lowerer, out: *StmtList, range: Bir.SubRange, p: u32) !Node.Index {
        const fields = l.bir.extraSlice(range, Bir.Field);
        const names = try l.scratch.alloc(Symbol, fields.len);
        for (fields, names) |f, *n| n.* = l.bir.symbol(f.name);
        const order = try l.fieldOrder(names);
        const reordered = isPermuted(order);
        const insts = try l.scratch.alloc(Inst.Index, fields.len);
        for (fields, insts) |f, *slot| slot.* = f.value;
        const values = try l.orderedExprs(out, insts, reordered);
        var properties: std.ArrayList(Node.Index) = .empty;
        for (order) |field| {
            try properties.append(l.scratch, try l.fieldProperty(l.bir.symbol(fields[field].name), values[field], p));
        }
        return l.object(properties.items, p);
    }

    // ---- `?` (backend.md §4, language.md §6.6) ----------------------------

    /// `e?`: three statements' worth of JavaScript and no `case` at all.
    ///
    ///     const $t$1 = <e>;
    ///     if ($t$1.$ === "Nothing") return $t$1;
    ///     …$t$1.a…
    ///
    /// **The subject is evaluated once** (`language.md` §6), so it is bound
    /// unless it is already an atom; the test reads the failing
    /// constructor's representation, which is `Nothing` for the `Maybe`
    /// shape and `Err` for the `Result` one; and the value of the whole
    /// expression is the payload slot of the succeeding constructor, which
    /// is slot 0 for `Just` and for `Ok` alike.
    ///
    /// **The failure is RETURNED, not rebuilt.** `Err x` going out of a
    /// function whose result is `Result e b` is the same JavaScript object
    /// that came in as `Result e a`: it carries an `e` and never an `a`, so
    /// nothing in it depends on the type that changed. `Nothing` is the
    /// same argument with an empty hand — the padded `{$:"Nothing",a:null}`
    /// of one `Maybe` is the padded `{$:"Nothing",a:null}` of every other.
    /// So the failure path allocates nothing, names nothing, and adds no
    /// edge for §9's reachability to follow.
    ///
    /// **The `return` is the enclosing FUNCTION's**, which is what §6.6
    /// asks for and what the emitted statement means wherever it lands: a
    /// `return` inside §7's labelled block or `switch` leaves the function
    /// and not the block, and inside §8's `while (true)` it leaves the
    /// loop. The front end has already made the two agree — a `?` may only
    /// name the nearest enclosing definition with parameters, and a lambda
    /// in between is `question_in_lambda` — and a `let` definition with
    /// parameters is its own JavaScript function here (§8's cases table),
    /// so "the nearest enclosing definition" and "the nearest enclosing
    /// `function`" are the same place.
    fn tryExpr(l: *Lowerer, out: *StmtList, inst: Inst.Index) !Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        const subject = try l.bindSubject(out, try l.expr(out, @enumFromInt(d.lhs)), p);
        const shape = l.in.dispatch.tryShape(inst) orelse {
            try l.reportMissingTryShape(inst);
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        };
        const rep, const tag = switch (shape) {
            .maybe => try l.coreCtor(.Maybe, .Nothing, p),
            .result => try l.coreCtor(.Result, .Err, p),
        } orelse return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        // Every representation of §4 is written out rather than assumed.
        // `Maybe` and `Result` each have a constructor that carries a
        // payload, so both are `tagged` today and the other two arms are
        // what the emitter would have to do if that changed — an emitter
        // that guesses at a representation is how a wrong answer ships.
        const failed = switch (rep) {
            .tagged => try l.binary(.strict_eq, try l.member(subject, l.well.tag, p), try l.tagLiteral(rep, tag, p), p),
            .bare_tag => try l.binary(.strict_eq, subject, try l.tagLiteral(rep, tag, p), p),
            .boolean => |value| if (value)
                subject
            else
                try l.unary(.not, subject, p),
            // `Nothing` and `Err` are constructors of `type`s in the
            // embedded core, never of a record alias.
            .record => unreachable,
        };
        try l.ifStatement(out, failed, &.{try l.returnStmt(subject, p)}, p);
        return l.member(subject, try l.slotName(0), p);
    }

    /// The representation and tag of a CONSTRUCTOR of a core type, by name,
    /// however this module reaches it. `?` is the one construct that needs
    /// this: its failure test names a constructor the program never wrote,
    /// so there is no `ctor` instruction anywhere in it to read a
    /// representation off. `coreValue` is the same lookup for a value, and
    /// each failure is reported for the same reason.
    fn coreCtor(
        l: *Lowerer,
        comptime owner: InternPool.WellKnown,
        ctor: InternPool.WellKnown,
        p: u32,
    ) !?struct { CtorRep, Symbol } {
        const spelling = l.interner.slice(ctor.symbol());
        const module = l.in.graph.lookup(.core, owner.symbol()) orelse {
            _ = try l.missingCoreValue(p, @tagName(owner), spelling, "there is no such module in the core package");
            return null;
        };
        if (module == l.in.module) {
            for (l.bir.ctors, 0..) |c, i| {
                if (l.bir.symbol(c.name) != ctor.symbol()) continue;
                return .{ l.ctorRepLocal(@intCast(i)), l.bir.symbol(c.name) };
            }
            _ = try l.missingCoreValue(p, @tagName(owner), spelling, "this module IS that module, and it does not declare it");
            return null;
        }
        if (module.int() >= l.in.interfaces.len) {
            _ = try l.missingCoreValue(p, @tagName(owner), spelling, "its interface is not available here");
            return null;
        }
        const iface = &l.in.interfaces[module.int()];
        const index = iface.findCtor(l.interner.global, ctor.symbol()) orelse {
            _ = try l.missingCoreValue(p, @tagName(owner), spelling, "that module declares no such constructor");
            return null;
        };
        // A constructor is an object literal or a tag string at every use
        // site (§4), so nothing is imported for it and §9 has no edge to
        // follow.
        return .{
            l.ctorRepExternal(module, @intFromEnum(index)),
            iface.symbols[@intFromEnum(iface.ctors[@intFromEnum(index)].name)],
        };
    }

    /// `internal`, and for `reportDispatchBug`'s reason: a `?` the checker
    /// solved has a row in the table, a `?` it did not solve is `try_shape`
    /// and refuses the build, and there is no third case — so a `?` here
    /// with no row is two records disagreeing and not a missing feature.
    fn reportMissingTryShape(l: *Lowerer, inst: Inst.Index) !void {
        try l.report(
            .internal,
            inst,
            \\I cannot tell whether this `?` is a `Maybe` or a `Result`.
            \\
            \\`docs/design/checker.md` §6.5 settles that by trying both shapes and
            \\records the one that fit, because the failure test is the `Nothing` tag
            \\for one and the `Err` tag for the other and nothing in this expression
            \\says which. The table has no row for this `?`.
            \\
            \\That is a compiler bug. Please report it with this program; `beni dump
            \\--stage=dispatch` prints the table this reads.
        ,
            .{},
        );
    }

    /// A reference in VALUE position: the JavaScript binding itself. Only a
    /// constructor needs anything built, because it has no binding — and a
    /// CONSTRAINED value, which is its eta-expansion (§8.2, A.25): the bare
    /// name has the evidence parameters in front and therefore the wrong
    /// arity, so `let f = Dict.insert` is `(a, b, c) => Dict$insert(cmp, a,
    /// b, c)` and never `Dict$insert`.
    fn reference(l: *Lowerer, inst: Inst.Index) !Node.Index {
        const p = l.pos(inst);
        // A list a loop holds as an offset (§8, *Scalar views*): the offset
        // where the loop reads it so, the list built anywhere else.
        if (l.bir.instTag(inst) == .local) if (l.scalarOf(l.bir.instData(inst).lhs)) |k| {
            const offset = try l.ident(try l.localName(l.bir.instData(inst).lhs), p);
            return if (l.isScalarRaw(inst)) offset else l.materialise(k, offset, p);
        };
        if (l.jsIntrinsicOf(inst)) |which| switch (which) {
            .null => return l.nullNode(p),
            .undefined => return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
            .development => return l.add(if (l.in.development) .true_lit else .false_lit, p, Node.Data.unused, Node.Data.unused),
            // A function passed as a value is the sibling's (`core/Js.js`).
            else => {},
        };
        if (l.ctorRepOf(inst)) |rep_and_tag| {
            const rep, const tag = rep_and_tag;
            const arity = l.ctorArity(inst);
            if (arity == 0 and rep == .tagged) return l.ident(try l.nullaryConstant(inst, rep, tag), p);
            if (arity == 0) return l.ctorValue(rep, tag, &.{}, p);
            return l.ctorLambda(rep, tag, arity, p);
        }
        const value = try l.referenceName(inst);
        const site = l.in.dispatch.siteOf(inst) orelse return value;
        const roots = l.in.dispatch.argsAt(site.evidence);
        const expected = l.in.dispatch.referenceCount(l.bir, l.in.interfaces, l.decl_index, inst);
        if (roots.len == 0 and expected == 0) return value;
        l.region = inst;
        if (try l.refuseEvidence(inst, roots, expected)) {
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        // How many parameters the eta-expansion takes is `Convention`'s
        // (checker-v2.md §12.5): a thunk's read is the evidence applied, a
        // function's is a closure over its type's arity. `refuseEvidence`
        // has just proved the value takes evidence, so it is not `plain`.
        const use = l.referenceUse(inst);
        const arity = Convention.referenceArity(use) orelse use.arity;
        const saved_choice = l.term_choice;
        l.term_choice = l.in.dispatch.effectAt(inst).body;
        defer l.term_choice = saved_choice;
        return l.etaExpand(value, try l.evidenceArguments(roots, p), arity, p);
    }

    /// The JavaScript binding a `local`, `top` or `ext_value` reference
    /// names, with the import recorded for the last.
    fn referenceName(l: *Lowerer, inst: Inst.Index) !Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        return switch (l.bir.instTag(inst)) {
            .local => try l.ident(try l.localName(d.lhs), p),
            // A markup primitive is the markup runtime's export of its name
            // (`boundary.md` §9.3), in its own module as in any other.
            .top => if (d.lhs < l.bir.decls.len and l.bir.decls[d.lhs].kind == .vocab_markup)
                try l.ident(try l.primitiveName(l.module_name, l.bir.symbol(l.bir.decls[d.lhs].name)), p)
            else
                try l.ident(try l.topNameChoosing(d.lhs, l.in.dispatch.effectAt(inst).body), p),
            .ext_value => blk: {
                const module: Graph.Index = @enumFromInt(d.lhs);
                if (module.int() < l.in.interfaces.len) {
                    const iface = &l.in.interfaces[module.int()];
                    if (d.rhs < iface.values.len and iface.values[d.rhs].is_markup_primitive) {
                        const base = iface.symbols[@intFromEnum(iface.values[d.rhs].name)];
                        break :blk try l.ident(try l.primitiveName(l.in.graph.moduleName(module), base), p);
                    }
                }
                break :blk try l.ident(try l.externalNameChoosing(module, d.rhs, l.in.dispatch.effectAt(inst).body), p);
            },
            else => try l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
        };
    }

    /// The calling convention of the value a reference names (§12.5): this
    /// module's `DeclInfo`, or the interface of the module it comes from.
    fn referenceUse(l: *Lowerer, inst: Inst.Index) Convention.Use {
        const d = l.bir.instData(inst);
        return switch (l.bir.instTag(inst)) {
            .top => Convention.ofDecl(l.in.dispatch, l.bir, d.lhs),
            .ext_value => Convention.ofImport(l.in.interfaces, @enumFromInt(d.lhs), d.rhs),
            .local => if (l.decl_index) |decl| (if (l.in.dispatch.localLet(l.bir, decl, d.lhs)) |i| Convention.ofLet(l.in.dispatch, l.bir, i) else Convention.Use{ .convention = .plain, .evidence = 0, .arity = 0 }) else .{ .convention = .plain, .evidence = 0, .arity = 0 },
            else => .{ .convention = .plain, .evidence = 0, .arity = 0 },
        };
    }

    /// A reference to a constrained FUNCTION applied to `args`, as one flat
    /// call `f(ev…, args…)` — what a written call of it lowers to — or null
    /// when `inst` is anything else. `appliedArrow`'s body `h = maxOf` is
    /// the reason: without this it would call `maxOf`'s eta-expansion.
    fn referenceApplied(l: *Lowerer, inst: Inst.Index, args: []const Node.Index) !?Node.Index {
        switch (l.bir.instTag(inst)) {
            .top, .ext_value => {},
            else => return null,
        }
        if (l.ctorRepOf(inst) != null) return null;
        const site = l.in.dispatch.siteOf(inst) orelse return null;
        const roots = l.in.dispatch.argsAt(site.evidence);
        const use = l.referenceUse(inst);
        if (roots.len == 0 or use.convention != .function or use.arity != args.len) return null;
        const p = l.pos(inst);
        l.region = inst;
        if (try l.refuseEvidence(inst, roots, use.evidence)) {
            return try l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        const saved_choice = l.term_choice;
        l.term_choice = l.in.dispatch.effectAt(inst).body;
        const evidence = try l.evidenceArguments(roots, p);
        l.term_choice = saved_choice;
        const all = try l.scratch.alloc(Node.Index, evidence.len + args.len);
        @memcpy(all[0..evidence.len], evidence);
        @memcpy(all[evidence.len..], args);
        return try l.call(try l.referenceName(inst), all, p);
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

    /// The evidence ROOTS of one instruction (checker-v2.md §13.1): one term
    /// per requirement of the scheme it instantiates, each carrying its own
    /// arguments. `dispatch.sites` has at most one row per instruction and is
    /// ascending, so this is one binary search — never a scan. It runs once
    /// for each instruction that can carry evidence: every `call`,
    /// `method_call` and `type_dispatch`, and every REFERENCE too, because
    /// §7.2 gives a bare mention of a constrained value evidence of its own
    /// (§8.2's last row).
    fn rootsOf(l: *Lowerer, inst: Inst.Index) []const Dispatch.TermIndex {
        const site = l.in.dispatch.siteOf(inst) orelse return &.{};
        return l.in.dispatch.argsAt(site.evidence);
    }

    /// How many evidence arguments the function a term names takes — the
    /// one counting function, `Dispatch.requirementCount`. `Lower` only
    /// ASSERTS with it (every term has as many arguments as its callee has
    /// requirements, checker-v2.md §13.3): the arguments themselves
    /// are the term's own `args`.
    fn requirementCount(l: *Lowerer, t: Dispatch.Term) u32 {
        return l.in.dispatch.requirementCount(t, l.in.interfaces, l.in.types, l.interner.global);
    }

    /// The beni arity of a term: how many parameters its eta-expansion
    /// takes, which is the arity the evidence slot promised.
    ///
    /// A `top` or an `ext` asks `Convention` (checker-v2.md §12.5), exactly
    /// as a reference to the same value does.
    fn termArity(l: *Lowerer, t: Dispatch.Term) u32 {
        const use: Convention.Use = switch (t) {
            .top => |u| Convention.ofDecl(l.in.dispatch, l.bir, u.decl.int()),
            .ext => |e| Convention.ofImport(l.in.interfaces, e.module, @intFromEnum(e.value)),
            // A derived `eq` or `compare` is binary: the two values being
            // compared, after whatever evidence it takes (§9).
            .derived, .ext_derived => return 2,
            else => return 0,
        };
        return Convention.referenceArity(use) orelse use.arity;
    }

    /// The JavaScript value a term NAMES (§8.2's table), before any of its
    /// own arguments are applied, with the import recorded for an `ext`
    /// exactly as for any other cross-module reference.
    fn termName(l: *Lowerer, t: Dispatch.Term, p: u32) !Node.Index {
        return switch (t) {
            // `topName` and `externalName` index `bir.decls` and the
            // interface's value table without a bounds test, and so does
            // `termArity`. A term naming neither is a malformed table and
            // not a program, so it is an assert.
            // A target with two bodies takes the one the site's callee takes
            // (transparent-effects-proposal.md §16.2): `term_choice`.
            .top => |use| blk: {
                std.debug.assert(use.decl.int() < l.bir.decls.len);
                break :blk try l.ident(try l.topNameChoosing(use.decl.int(), l.term_choice), p);
            },
            .ext => |e| blk: {
                std.debug.assert(e.module.int() < l.in.interfaces.len);
                std.debug.assert(@intFromEnum(e.value) < l.in.interfaces[e.module.int()].values.len);
                break :blk try l.ident(try l.externalNameChoosing(e.module, @intFromEnum(e.value), l.term_choice), p);
            },
            // A declaration's `$m$k` and a derived function's are spelled
            // alike: each is the parameter list of the function the term
            // sits in (§8.1, §9).
            .param => |param| switch (param.binder) {
                .let => |at| try l.ident(try l.letEvidenceName(at, param.k), p),
                else => try l.ownEvidence(param.k, p),
            },
            .primitive => |prim| try l.primitiveValue(prim, p),
            // Unreachable: `field` cannot be evidence (§8.2), `undetermined`
            // is answered by `termValue`, and a derived term goes through
            // `derivedName`.
            else => try l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
        };
    }

    /// The hidden leading arguments of one instruction (§8.2): one value
    /// per root, in the order the site lists them. Nothing is counted
    /// here — each root carries its own arguments (checker-v2.md §13.3) —
    /// and `refuseEvidence` has already asserted that the counts agree.
    fn evidenceArguments(l: *Lowerer, roots: []const Dispatch.TermIndex, p: u32) ![]const Node.Index {
        return l.termValues(roots, null, p);
    }

    /// One value per term. `kind` is the method of the nearest enclosing
    /// derived term — the one thing a term alone cannot say, and what an
    /// `undetermined` leaf has to be answered by: `Basics.eq` in a
    /// `compare` slot is a `Bool` where an `Order` was promised. `null`
    /// outside any derived term.
    fn termValues(
        l: *Lowerer,
        terms: []const Dispatch.TermIndex,
        kind: ?Dispatch.Derived.Kind,
        p: u32,
    ) Allocator.Error![]const Node.Index {
        const out = try l.scratch.alloc(Node.Index, terms.len);
        for (terms, out) |t, *slot| {
            // A shared term already bound in this statement list is read by
            // name (`shared`).
            const shared = if (l.evidence_out) |into| l.sharedIn(t, into) else false;
            if (shared) if (l.bound.get(t.int())) |n| {
                slot.* = try l.ident(n, p);
                continue;
            };
            // `term_depth`, like `expr_height`, is the deepest term lowered
            // inside this one, in closures.
            const outer = l.term_depth;
            l.term_depth = 0;
            const value = try l.termValue(t, kind, p);
            const depth = l.term_depth + 1;
            slot.* = if (shared) try l.bindShared(t, value, p) else try l.hoistEvidence(value, depth, p);
            l.term_depth = if (slot.* == value) @max(outer, depth) else outer;
        }
        return out;
    }

    /// Whether term `t` is shared and may be bound in `into`, the statement
    /// list evidence is bound in now: what was bound in another list is
    /// forgotten when the list changes, so a name is never read outside the
    /// scope that declares it.
    fn sharedIn(l: *Lowerer, t: Dispatch.TermIndex, into: *StmtList) bool {
        if (t.int() >= l.shared.len or !l.shared[t.int()]) return false;
        if (l.bound_out != into) {
            l.bound.clear();
            l.bound_out = into;
        }
        return true;
    }

    /// A shared evidence closure, bound to a `const` the first time it is
    /// lowered. Only an `arrow` moves (`hoistEvidence`'s rule): a CALL runs a
    /// constant and stays where it is.
    fn bindShared(l: *Lowerer, t: Dispatch.TermIndex, value: Node.Index, p: u32) !Node.Index {
        const into = l.evidence_out orelse return value;
        if (l.b.nodes.items(.tag)[value.int()] != .arrow) return value;
        const n = try l.fresh(l.well.temp);
        try l.constDecl(into, n, value, p);
        try l.bound.put(l.scratch, t.int(), n);
        return l.ident(n, p);
    }

    /// Read the table once: which terms are shared, and which add up.
    fn readTable(l: *Lowerer) !void {
        const d = l.in.dispatch;
        l.leaf = try l.leafRows();
        if (d.terms.len == 0) return;
        const count = try l.scratch.alloc(u8, d.terms.len);
        @memset(count, 0);
        for (d.args) |a| if (a.int() < count.len) {
            count[a.int()] +|= 1;
        };
        for (d.sites) |s| if (s.callee.unwrap()) |c| if (c.int() < count.len) {
            count[c.int()] +|= 1;
        };
        const shared = try l.scratch.alloc(bool, d.terms.len);
        for (shared, count) |*s, c| s.* = c > 1;
        l.shared = shared;
        const ok = try l.scratch.alloc(bool, d.terms.len);
        var i = d.terms.len;
        while (i > 0) {
            i -= 1;
            ok[i] = l.termOkLocal(ok, @intCast(i));
        }
        l.shape_ok = ok;
        // The same one pass for `derivedBodiesExist`. A walk from each root
        // visited a SHARED term once per path to it, and a table shares
        // terms: `==` on a type that doubles 32 times would be 2³² visits
        // and a build that never finished. A term's answer depends
        // only on the terms after it, so judging each once from the last is
        // linear in the table.
        const bodies = try l.scratch.alloc(bool, d.terms.len);
        i = d.terms.len;
        while (i > 0) {
            i -= 1;
            bodies[i] = l.bodiesLocal(bodies, @intCast(i));
        }
        l.bodies_ok = bodies;
    }

    /// `derivedBodiesExist` for one term, given the answer for every later
    /// one. An argument that does not follow its owner is skipped, as the
    /// walk always skipped it: that table is `termOkLocal`'s to refuse.
    fn bodiesLocal(l: *Lowerer, bodies: []const bool, i: u32) bool {
        const d = l.in.dispatch;
        const t = d.terms[i];
        switch (t) {
            .derived, .ext_derived => if (!l.derivedBodyExists(t)) return false,
            else => {},
        }
        const r = t.argsOf();
        if (@as(u64, r.start) + r.len > d.args.len) return true;
        for (d.argsAt(r)) |arg| {
            if (arg.int() > i and arg.int() < bodies.len and !bodies[arg.int()]) return false;
        }
        return true;
    }

    /// How long a chain of leaves may be: a leaf nominal row may call
    /// another leaf, and 16 of those nest 16 frames, which no engine
    /// notices. Past it the row counts depth like any other.
    const leaf_rank_limit = 16;

    /// Which derived rows of this module are LEAVES (`backend.md` §4,
    /// *Derived comparisons do not grow the native stack*): rows whose
    /// comparison cannot come back to a derived function, and so need no
    /// depth, no steps and no engine. They are emitted directly, and they
    /// are most of what a program compares: a record
    /// of primitives, a `type Shape = Circle Point Float | …`.
    ///
    /// - A record, tuple or `()` row is a leaf when EVERY use of it in this
    ///   module passes it only primitive comparators and hand-written
    ///   methods as evidence: its positions call nothing else. A derived
    ///   function as evidence is not flat — that is how a record literal
    ///   nests 4 095 shapes deep, one row passed to itself.
    /// - A nominal row is a leaf when every position is a primitive, a
    ///   hand-written method, or a call of a leaf row of this module, and
    ///   the chain of such calls is at most `leaf_rank_limit` long. A
    ///   position that is its own evidence (`Maybe a`'s `a`), another
    ///   module's derived function, or `List`'s `eq` is not: what it runs
    ///   is decided elsewhere. A type whose recursion stays among derived
    ///   functions never becomes a leaf, because its rank never becomes finite.
    ///
    /// A hand-written method is flat even though it may compare deep data
    /// itself: it is a function like any other and starts its own depth. So a
    /// type that recurses only THROUGH one — `type T = T (Box T) | E` with a
    /// hand-written `Box.eq … where a.eq` — IS a leaf, and still throws on
    /// deep data: the method cannot hand back steps. That is the exclusion
    /// `backend.md` §4 states and `abuse_test.zig` pins.
    fn leafRows(l: *Lowerer) ![]const bool {
        const d = l.in.dispatch;
        const n = d.derived.len;
        const flat_uses = try l.scratch.alloc(bool, n);
        @memset(flat_uses, true);
        for (d.terms) |t| switch (t) {
            .derived => |use| {
                if (use.index >= n) continue;
                for (d.argsAt(use.args)) |a| {
                    if (!l.flatArg(d.term(a))) flat_uses[use.index] = false;
                }
            },
            else => {},
        };
        const infinite = std.math.maxInt(u32);
        const rank = try l.scratch.alloc(u32, n);
        @memset(rank, infinite);
        for (d.derived, 0..) |row, r| switch (row.shape) {
            .record, .tuple, .unit => if (flat_uses[r]) {
                rank[r] = 1;
            },
            .nominal => {},
        };
        // A fixpoint over the nominal rows, one rank a round: a row's rank is
        // one more than its deepest callee's, so `leaf_rank_limit` rounds
        // settle every chain that can be a leaf and leave every cycle
        // infinite.
        var round: u32 = 0;
        while (round < leaf_rank_limit) : (round += 1) {
            var changed = false;
            for (d.derived, 0..) |row, r| {
                if (row.shape != .nominal or rank[r] != infinite) continue;
                var deepest: u32 = 0;
                // A tail self-call is a loop, not a call: `L = Cons Int L`
                // is a leaf.
                const loops = try l.selfLoopParts(@intCast(r), row);
                const ok = for (d.argsAt(row.body), loops) |part, loops_here| {
                    if (loops_here) continue;
                    switch (d.term(part)) {
                        .primitive, .undetermined => {},
                        .top, .ext => if (l.takesDepth(d.term(part))) break false,
                        .derived => |use| {
                            if (use.index >= n or rank[use.index] == infinite) break false;
                            deepest = @max(deepest, rank[use.index]);
                        },
                        .param, .ext_derived, .field => break false,
                    }
                } else true;
                if (!ok or deepest + 1 > leaf_rank_limit) continue;
                rank[r] = deepest + 1;
                changed = true;
            }
            if (!changed) break;
        }
        const leaf = try l.scratch.alloc(bool, n);
        for (leaf, rank) |*x, k| x.* = k != infinite;
        return leaf;
    }

    /// Evidence a leaf record or tuple may be handed: something that calls
    /// no derived function (`leafRows`).
    fn flatArg(l: *Lowerer, t: Dispatch.Term) bool {
        return switch (t) {
            .primitive, .undetermined => true,
            .top, .ext => !l.takesDepth(t),
            else => false,
        };
    }

    /// Whether derived row `index` of this module is a leaf.
    fn isLeaf(l: *Lowerer, index: u32) bool {
        return index < l.leaf.len and l.leaf[index];
    }

    /// An evidence closure `evidence_spill` closures deep, bound to a
    /// `const` in the statement list of the expression being lowered
    /// (`evidence_out`) and read by name (`backend.md` §4, *Emitted
    /// JavaScript nests only as deep as the source*). Evidence nests as deep
    /// as the TYPE it compares, one closure per level —
    /// `(x, y) => List$eq((x, y) => List$eq(…, x, y), x, y)` for a list of
    /// lists — and a type is not bounded by anything the engines know about.
    ///
    /// Only an `arrow` moves: making a closure runs nothing, so making it
    /// once, ahead of the call, rather than inside the closure that uses it
    /// is unobservable. A CALL — the evidence applied to a constant of no
    /// parameters (A.85) — stays where it is, because it runs the constant.
    fn hoistEvidence(l: *Lowerer, value: Node.Index, depth: u32, p: u32) !Node.Index {
        const into = l.evidence_out orelse return value;
        if (depth < evidence_spill) return value;
        if (l.b.nodes.items(.tag)[value.int()] != .arrow) return value;
        const n = try l.fresh(l.well.temp);
        try l.constDecl(into, n, value, p);
        return l.ident(n, p);
    }

    /// One term in VALUE position (§8.2's table).
    ///
    /// A `top`/`ext` with arguments of its own is eta-expanded around them
    /// (A.25) — in a site's tree and inside a derived function's alike, the
    /// two places §7.1's amendment (A.64) used to tell apart. A derived
    /// term is its function, eta-expanded around its own arguments.
    fn termValue(l: *Lowerer, i: Dispatch.TermIndex, kind: ?Dispatch.Derived.Kind, p: u32) Allocator.Error!Node.Index {
        const t = l.in.dispatch.term(i);
        switch (t) {
            .derived, .ext_derived => return l.derivedValue(i, p),
            .primitive => |prim| return l.primitiveValue(prim, p),
            // The proven-undetermined default (checker-v2.md §13.1): the
            // structural answer, as a function of the enclosing method.
            .undetermined => {
                const k = kind orelse {
                    try l.reportDispatchBug(l.region, undetermined_without_method);
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                };
                return switch (k) {
                    .eq => l.coreValue(.Basics, .eq, p),
                    .compare => l.primitiveValue(.num_compare, p),
                };
            },
            .top, .ext => {
                const args = l.in.dispatch.argsAt(t.argsOf());
                if (args.len != l.requirementCount(t)) {
                    try l.reportEvidenceShape(l.region);
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                // `List`'s `eq` and `compare` as derived code calls them: the
                // runtime's, which take a depth (`listRuntime`).
                const value = if (l.listRuntime(t)) |which| try l.runtimeValue(which, p) else try l.termName(t, p);
                if (args.len == 0) return value;
                const arity = l.termArity(t) + @intFromBool(l.takesDepth(t));
                return l.etaExpand(value, try l.termValues(args, kind, p), arity, p);
            },
            .param => return l.termName(t, p),
            .field => {
                try l.reportDispatchBug(l.region, field_inside_derived);
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
        }
    }

    /// `(a, b) => <name>(<bound…>, a, b)` — a constrained value in VALUE
    /// position (§8.2, A.25). The bare name has the evidence parameters in
    /// front of the beni ones, so it is a function of the wrong arity, and
    /// `backend.md` §6 requires every function-typed value in flight to be
    /// a closure of known arity.
    ///
    /// **At `arity == 0` the expansion is the CALL** — `<name>(<bound…>)`
    /// and not `() => <name>(<bound…>)` (A.85). A.25's reason
    /// is a statement about FUNCTION-typed values, and a declaration of no
    /// parameters is not one: `blank : List a where a.eq : …` is a list, so
    /// a closure around it is a value of the wrong TYPE rather than a
    /// function of the right arity. Wrapping it anyway is how
    /// `blankInts = () => blank(eq$prim)` reached `List.length` in a
    /// program that built with exit 0 and threw at load.
    ///
    /// The evidence is applied where the reference stands, so a top-level
    /// constant evaluates once at load like any other: §7's initialisation
    /// rule and `cyclic_value` already order top-level constants and refuse
    /// circles, and `boundary.md` §4 confines a `foreign` to a total pure
    /// function, so re-evaluating one inside a lambda body is unobservable.
    fn etaExpand(l: *Lowerer, callee: Node.Index, bound: []const Node.Index, arity: u32, p: u32) !Node.Index {
        var params: std.ArrayList(JsIr.NameIndex) = .empty;
        var args: std.ArrayList(Node.Index) = .empty;
        try args.appendSlice(l.scratch, bound);
        if (arity == 0) return l.call(callee, args.items, p);
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
    fn primitiveValue(l: *Lowerer, prim: Dispatch.Primitive, p: u32) !Node.Index {
        switch (prim) {
            .strict_eq => {
                l.needs.eq_prim = true;
                return l.ident(try l.primName(0, "eq$prim"), p);
            },
            .num_compare => {
                l.needs.compare_prim = true;
                return l.ident(try l.primName(1, "compare$prim"), p);
            },
            .char_compare => {
                l.needs.compare_char = true;
                return l.ident(try l.primName(2, "compare$char"), p);
            },
            .string_compare => return l.stringCompare(p),
        }
    }

    fn applySymbol(l: *Lowerer) !Symbol {
        if (l.apply_symbol.unwrap()) |s| return s;
        const s = try l.interner.getOrPut(l.gpa, "apply");
        l.apply_symbol = s.toOptional();
        return s;
    }

    fn primName(l: *Lowerer, slot: usize, base: []const u8) !JsIr.NameIndex {
        if (l.prim_names[slot] == .none) l.prim_names[slot] = try l.synthesisedName(base);
        return l.prim_names[slot];
    }

    /// `String.compare`, however this module reaches it.
    fn stringCompare(l: *Lowerer, p: u32) !Node.Index {
        return l.coreValue(.String, .compare, p);
    }

    // ---- Derived functions (static-dispatch-spike.md §9) ------------------
    //
    // A well-known method the checker resolved to a SHAPE rather than to a
    // value. The function is generated here, against the representation of
    // `backend.md` §4 and the `parts` contract of §9.
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
    /// them reads.
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
            l.derived_row = @intCast(index);
            const made = (try l.derivedArrow(row, base, l.isLeaf(@intCast(index)))) orelse continue;
            const bound = try l.synthesisedName(base);
            try list.append(l.scratch, .{
                .base = base,
                .node = try l.add(.const_decl, Node.no_pos, @intFromEnum(bound), made.arrow.int()),
            });
            if (made.steps) |steps| try list.append(l.scratch, .{ .base = try l.stepsBase(base), .node = steps });
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
        // An integer tag IS the declaration index the table would map it
        // to (`orderLookup`), so there is no table.
        if (l.integerTags(id)) return null;
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
        if (l.integerTags(id)) return subject;
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
    fn derivedArrow(l: *Lowerer, row: Dispatch.Derived, base: []const u8, leaf: bool) !?DerivedPair {
        const outer = l.derived_body;
        defer l.derived_body = outer;
        // A leaf (`leafRows`) is lowered with no body state at all, which is
        // exactly as a function that cannot recurse needs.
        if (leaf) {
            l.derived_body = null;
            return .{ .arrow = (try l.derivedForm(row)) orelse return null, .steps = null };
        }
        // A frame's size grows with its parameters, which a caller also
        // pushes, and with its positions, one `const $o$<i>` each in a
        // `compare` (`derived_weight_per`).
        const evidence: u32 = switch (Convention.derivedEvidence(row.context.len)) {
            .array => 0,
            .positional => @intCast(row.context.len),
        };
        const positions: u32 = switch (row.shape) {
            .nominal => @intCast(l.in.dispatch.argsAt(row.body).len),
            .record => |names| @intCast(l.in.dispatch.shapeNames(names).len),
            .tuple => |arity| arity,
            .unit => 0,
        };
        var body: DerivedBody = .{
            .depth = try l.name(.{ .module = .none, .base = try l.interner.getOrPut(l.gpa, "$d"), .tag = JsIr.Name.no_tag }),
            .weight = 1 + (2 * evidence + positions) / derived_weight_per,
            .pack = if (evidence > steps_positional) evidence else 0,
            .base = base,
        };
        body.weight_text = try std.fmt.allocPrint(l.scratch, "{d}", .{body.weight});
        l.derived_body = &body;
        const arrow = (try l.derivedForm(row)) orelse return null;
        // A body that passed no depth is a leaf: it is what it always was,
        // byte for byte, and has no twin.
        if (!body.passes) return .{ .arrow = arrow, .steps = null };
        // Every depth-taking call in tail position makes a
        // FORWARDER — no prologue, no steps (`forwardTail`).
        if (body.depth_calls == body.tail_calls) {
            body.mode = .forward;
            return .{ .arrow = (try l.derivedForm(row)) orelse return null, .steps = null };
        }
        body.mode = .steps;
        const steps = (try l.derivedForm(row)) orelse return null;
        return .{ .arrow = arrow, .steps = steps };
    }

    const DerivedPair = struct {
        /// The function itself, `(…, $x, $y, $d = 0) => …`.
        arrow: Node.Index,
        /// Its `function* <base>$$steps`, when it has one.
        steps: ?Node.Index,
    };

    /// `<base>$$steps`: the generator twin's base. The double separator is
    /// the one no record field, type or module name can spell (A.61).
    fn stepsBase(l: *Lowerer, base: []const u8) ![]const u8 {
        return std.fmt.allocPrint(l.scratch, "{s}$$steps", .{base});
    }

    /// The function a derived body ends in. Outside a derived body, or for a
    /// leaf, the arrow it always was. For a body that passes a depth, the
    /// direct form gains `$d = 0` and the prologue that hands the rest of
    /// the comparison to the engine (`_derived$deep`) past `derived_depth_limit`; the
    /// steps form is the same statements as a `function*` (`gen_decl`).
    fn derivedFunction(l: *Lowerer, params: []const JsIr.NameIndex, stmts: []const Node.Index, p: u32) !Node.Index {
        const body = l.derived_body orelse return l.arrowOf(params, stmts, p);
        switch (body.mode) {
            .direct => {
                if (!body.passes) return l.arrowOf(params, stmts, p);
                l.needs.deep = true;
                // if ($d > limit) return _derived$deep(M$<base>$$steps(params…), $d);
                // Past `steps_positional` the evidence goes to the steps as one
                // array (`derivedForm`).
                var args: std.ArrayList(Node.Index) = .empty;
                var boxed: std.ArrayList(Node.Index) = .empty;
                for (params, 0..) |n, i| {
                    if (i < body.pack) try boxed.append(l.scratch, try l.ident(n, p)) else try args.append(l.scratch, try l.ident(n, p));
                }
                if (body.pack > 0) {
                    const range = try l.b.addRange(boxed.items);
                    try args.insert(l.scratch, 0, try l.add(.array, p, @intFromEnum(range.start), @intFromEnum(range.end)));
                }
                const steps_name = try l.synthesisedName(try l.stepsBase(body.base));
                const steps = try l.call(try l.ident(steps_name, p), args.items, p);
                const deep = try l.deepName(p);
                const handoff = try l.call(deep, &.{ steps, try l.ident(body.depth, p) }, p);
                const over = try l.binary(.gt, try l.ident(body.depth, p), try l.numberNode(derived_depth_limit, p), p);
                var all: StmtList = .empty;
                const then = [_]Node.Index{try l.returnStmt(handoff, p)};
                try l.ifStatement(&all, over, &then, p);
                try all.appendSlice(l.scratch, stmts);
                var names: std.ArrayList(JsIr.NameIndex) = .empty;
                try names.appendSlice(l.scratch, params);
                try names.append(l.scratch, body.depth);
                const record = try l.funcRecord(names.items, all.items);
                return l.add(.arrow, p, @intFromEnum(record), Node.arrow_depth);
            },
            .forward => {
                // A forwarder: the depth, and no prologue (`forwardTail`).
                var names: std.ArrayList(JsIr.NameIndex) = .empty;
                try names.appendSlice(l.scratch, params);
                try names.append(l.scratch, body.depth);
                const record = try l.funcRecord(names.items, stmts);
                return l.add(.arrow, p, @intFromEnum(record), Node.arrow_depth);
            },
            .steps => {
                // `let $e;` ahead of everything, when a request was awaited.
                var all: StmtList = .empty;
                if (body.temp) |e| try all.append(l.scratch, try l.add(.let_decl, p, @intFromEnum(e), @intFromEnum(Node.OptionalIndex.none)));
                try all.appendSlice(l.scratch, stmts);
                const record = try l.funcRecord(params, all.items);
                const steps_name = try l.synthesisedName(try l.stepsBase(body.base));
                return l.add(.gen_decl, p, @intFromEnum(steps_name), @intFromEnum(record));
            },
        }
    }

    /// `callee(args…)` at one position of a derived body, for a callee that
    /// takes a depth. The direct form appends `$d + weight`. The steps form
    /// appends the REQUEST instead: the callee answers at once if it cannot
    /// recurse — a primitive comparator, a hand-written method, a leaf —
    /// and otherwise hands back its own steps, unstarted, which the caller
    /// yields to the engine (`awaitRequest`) or, in tail position, returns.
    fn depthCall(l: *Lowerer, callee: Node.Index, args: []const Node.Index, p: u32) !Node.Index {
        const body = l.derived_body orelse return l.call(callee, args, p);
        const all = try l.scratch.alloc(Node.Index, args.len + 1);
        @memcpy(all[0..args.len], args);
        switch (body.mode) {
            .direct, .forward => {
                body.passes = true;
                body.depth_calls += 1;
                const weight = try l.numberNode(body.weight_text, p);
                all[args.len] = try l.binary(.add, try l.ident(body.depth, p), weight, p);
                const made = try l.call(callee, all, p);
                _ = try body.calls.insert(l.scratch, made.int());
                return made;
            },
            .steps => {
                all[args.len] = try l.numberNode(derived_request, p);
                // Past `steps_positional` arguments the call is `f.apply(null,
                // [args…])`: a call of n arguments takes n registers of the
                // frame, which every `yield` would then save.
                const request = if (all.len > steps_positional) blk: {
                    const range = try l.b.addRange(all);
                    const array = try l.add(.array, p, @intFromEnum(range.start), @intFromEnum(range.end));
                    const apply = try l.member(callee, try l.applySymbol(), p);
                    break :blk try l.call(apply, &.{ try l.nullNode(p), array }, p);
                } else try l.call(callee, all, p);
                _ = try body.requests.insert(l.scratch, request.int());
                return request;
            },
        }
    }

    /// Whether the derived body is being lowered in its steps form.
    fn inSteps(l: *Lowerer) bool {
        const body = l.derived_body orelse return false;
        return body.mode == .steps;
    }

    /// Whether `value` is a steps-form call made by `depthCall`: its answer
    /// may be steps the engine has to run.
    fn isRequest(l: *Lowerer, value: Node.Index) bool {
        const body = l.derived_body orelse return false;
        return body.mode == .steps and body.requests.contains(value.int());
    }

    /// `if (typeof n === "object") { n = yield n; }` — steps handed back by
    /// a request go to the engine, which resumes this frame with their
    /// answer; an answer is used as it is.
    fn yieldIfSteps(l: *Lowerer, out: *StmtList, n: JsIr.NameIndex, p: u32) !void {
        const resumed = try l.unary(.yield, try l.ident(n, p), p);
        const then = [_]Node.Index{try l.add(.assign_stmt, p, (try l.ident(n, p)).int(), resumed.int())};
        try l.ifStatement(out, try l.isObject(n, p), &then, p);
    }

    /// A term's answer in the steps form, as an expression: the term itself,
    /// or — for a request — a `let $e$<i>` bound to it and awaited
    /// (`yieldIfSteps`).
    fn awaitRequest(l: *Lowerer, out: *StmtList, value: Node.Index, p: u32) !Node.Index {
        if (!l.isRequest(value)) return value;
        const e = try l.stepsTemp();
        try out.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(e, p)).int(), value.int()));
        try l.yieldIfSteps(out, e, p);
        return l.ident(e, p);
    }

    /// `$e`: the steps form's ONE temporary, declared once at the top
    /// (`derivedFunction`). One and not one a position, because a generator
    /// saves every register of its frame at every `yield`.
    fn stepsTemp(l: *Lowerer) !JsIr.NameIndex {
        const body = l.derived_body.?;
        if (body.temp) |e| return e;
        const e = try l.name(.{ .module = .none, .base = try l.interner.getOrPut(l.gpa, "$e"), .tag = JsIr.Name.no_tag });
        body.temp = e;
        return e;
    }

    /// The value a derived body RETURNS. In the steps form a request in
    /// tail position is returned as it is: steps handed back replace the
    /// finished frame in the engine (`_core/_derived.mjs`'s `deep`), so a long list costs the
    /// explicit stack nothing.
    fn derivedReturn(l: *Lowerer, value: Node.Index, p: u32) !Node.Index {
        const body = l.derived_body orelse return l.returnStmt(value, p);
        switch (body.mode) {
            .direct => if (body.calls.contains(l.rightmost(value).int())) {
                body.tail_calls += 1;
            },
            .forward => return l.returnStmt(try l.forwardTail(value, p), p),
            .steps => {},
        }
        return l.returnStmt(value, p);
    }

    /// The last operand of a `&&` chain, or `value` itself: what a
    /// returned conjunction answers with when every term before it passed.
    fn rightmost(l: *Lowerer, value: Node.Index) Node.Index {
        var at = value;
        while (true) {
            const d = l.b.nodes.items(.data)[at.int()];
            if (l.b.nodes.items(.tag)[at.int()] != .binary or
                @as(JsIr.BinaryOp, @enumFromInt(d.rhs)) != .logical_and) return at;
            at = @enumFromInt(l.b.extra.items[d.lhs + 1]);
        }
    }

    /// A forwarder's returned value with its tail call `f(args…, $d + w)`
    /// made `$d > limit ? _derived$deep([f, args…], $d) : f(args…, $d + w)`.
    /// Past the limit — or given the REQUEST, which is past every limit —
    /// the call becomes a request the engine makes on its explicit stack:
    /// a chain of forwarders nested as deep as a TYPE (`Just (Just (…))`)
    /// grows the native stack no more than a derived function does.
    fn forwardTail(l: *Lowerer, value: Node.Index, p: u32) !Node.Index {
        const body = l.derived_body.?;
        const tags = l.b.nodes.items(.tag);
        const d = l.b.nodes.items(.data)[value.int()];
        if (tags[value.int()] == .binary and @as(JsIr.BinaryOp, @enumFromInt(d.rhs)) == .logical_and) {
            const left: Node.Index = @enumFromInt(l.b.extra.items[d.lhs]);
            const right: Node.Index = @enumFromInt(l.b.extra.items[d.lhs + 1]);
            const tail = try l.forwardTail(right, p);
            return if (tail == right) value else l.binary(.logical_and, left, tail, p);
        }
        if (!body.calls.contains(value.int())) return value;
        // `[f, args…]`: the call's callee and every argument but the depth.
        const callee: Node.Index = @enumFromInt(d.lhs);
        const range = l.b.extra.items[d.rhs..][0..2];
        const args: []const Node.Index = @ptrCast(l.b.extra.items[range[0]..range[1]]);
        const all = try l.scratch.alloc(Node.Index, args.len);
        all[0] = callee;
        @memcpy(all[1..], args[0 .. args.len - 1]);
        const request_range = try l.b.addRange(all);
        const request = try l.add(.array, p, @intFromEnum(request_range.start), @intFromEnum(request_range.end));
        l.needs.deep = true;
        const handoff = try l.call(try l.deepName(p), &.{ request, try l.ident(body.depth, p) }, p);
        const over = try l.binary(.gt, try l.ident(body.depth, p), try l.numberNode(derived_depth_limit, p), p);
        return l.condOf(over, handoff, value, p);
    }

    fn derivedForm(l: *Lowerer, row: Dispatch.Derived) !?Node.Index {
        const p = Node.no_pos;
        const x, const y = try l.operandNames();
        var params: std.ArrayList(JsIr.NameIndex) = .empty;
        // A wide function takes its evidence as ONE parameter, an array
        // (§9.2's wide form): a JavaScript call with a parameter per field
        // overflows the engine's stack, and past 65 535 parameters V8
        // refuses the function outright. `Convention` decides it from the
        // count, and every caller packs by the same answer
        // (`derivedEvidenceArguments`).
        const outer_array = l.wide_evidence;
        defer l.wide_evidence = outer_array;
        l.wide_evidence = null;
        // The steps form takes more than `steps_positional` evidence as one
        // array too, whatever `Convention` says: a generator saves its
        // whole frame at every `yield`, so a frame of thousands of
        // parameters would make every suspension, and V8's code for it,
        // that big. Only the direct form packs for it (`derivedFunction`).
        const steps_array = l.inSteps() and row.context.len > steps_positional;
        switch (if (steps_array) .array else Convention.derivedEvidence(row.context.len)) {
            .array => {
                const array = try l.evidenceArrayName();
                try params.append(l.scratch, array);
                l.wide_evidence = array;
            },
            .positional => {
                var k: u32 = 0;
                while (k < row.context.len) : (k += 1) try params.append(l.scratch, try l.evidenceName(k));
            },
        }
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
                return l.structuralArrow(row.kind, params.items, x, y, fields, true, p);
            },
            // §9.3: the same, over the slot names `a`, `b`, `c`… of
            // `backend.md` §4. Keyed on the arity alone, so `( Int, Int )`
            // and `( String, String )` share one function (A.46).
            .tuple => |arity| {
                if (arity == 0) return try l.emptyArrow(row.kind, params.items, p);
                try params.appendSlice(l.scratch, &[_]JsIr.NameIndex{ x, y });
                const slots = try l.scratch.alloc(Symbol, arity);
                for (slots, 0..) |*slot, i| slot.* = try l.slotName(@intCast(i));
                return l.structuralArrow(row.kind, params.items, x, y, slots, false, p);
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
        /// The slots are a record's field names, not a tuple's `a`, `b`, ….
        fields: bool,
        p: u32,
    ) !?Node.Index {
        const read = struct {
            fn at(lo: *Lowerer, target: Node.Index, slot: Symbol, is_field: bool, at_p: u32) !Node.Index {
                return if (is_field) lo.fieldMember(target, slot, at_p) else lo.member(target, slot, at_p);
            }
        }.at;
        if (kind == .eq) {
            var value: Conjunction = .{};
            for (slots, 0..) |slot, i| {
                const left = try read(l, try l.ident(x, p), slot, fields, p);
                const right = try read(l, try l.ident(y, p), slot, fields, p);
                try value.add(l, try l.evidenceCall(@intCast(i), left, right, p), p);
            }
            var out: StmtList = .empty;
            try l.returnConjunction(&out, &value, p);
            return try l.derivedFunction(params, out.items, p);
        }
        var stmts: StmtList = .empty;
        var counter: u32 = 0;
        for (slots, 0..) |slot, i| {
            const left = try read(l, try l.ident(x, p), slot, fields, p);
            const right = try read(l, try l.ident(y, p), slot, fields, p);
            const one = try l.evidenceCall(@intCast(i), left, right, p);
            try l.lexicographic(&stmts, one, i + 1 == slots.len, &counter, p);
        }
        return try l.derivedFunction(params, stmts.items, p);
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
            try out.append(l.scratch, try l.derivedReturn(value, p));
            return;
        }
        // The steps form binds every position to its one temporary `$e`,
        // awaited when it is a request (`awaitRequest`), and keeps no
        // `const` a position: a generator saves its whole frame at a `yield`.
        const bound = if (l.inSteps()) blk: {
            if (!l.isRequest(value)) {
                const e = try l.stepsTemp();
                try out.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(e, p)).int(), value.int()));
                break :blk e;
            }
            _ = try l.awaitRequest(out, value, p);
            break :blk try l.stepsTemp();
        } else blk: {
            const o = try l.orderName(counter.*);
            counter.* += 1;
            try l.constDecl(out, o, value, p);
            break :blk o;
        };
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
        const stmts = [_]Node.Index{try l.derivedReturn(value, p)};
        return l.derivedFunction(params, &stmts, p);
    }

    /// `$m$k(left, right)` — the derived function's own k-th evidence
    /// parameter applied to one position.
    fn evidenceCall(l: *Lowerer, k: u32, left: Node.Index, right: Node.Index, p: u32) !Node.Index {
        return l.depthCall(try l.ownEvidence(k, p), &.{ left, right }, p);
    }

    /// The derived function's own k-th evidence parameter as a value:
    /// `$m$k`, or `$m[k]` inside a wide one (§9.2).
    fn ownEvidence(l: *Lowerer, k: u32, p: u32) !Node.Index {
        const array = l.wide_evidence orelse return l.ident(try l.evidenceName(k), p);
        var buf: [12]u8 = undefined;
        const index = try l.numberNode(std.fmt.bufPrint(&buf, "{d}", .{k}) catch unreachable, p);
        return l.add(.index_get, p, (try l.ident(array, p)).int(), index.int());
    }

    /// `$m`: the one evidence parameter of a wide derived function (§9.2).
    fn evidenceArrayName(l: *Lowerer) !JsIr.NameIndex {
        const base = try l.interner.getOrPut(l.gpa, "$m");
        return l.name(.{ .module = .none, .base = base, .tag = JsIr.Name.no_tag });
    }

    /// The arguments a call of a derived function passes for its evidence:
    /// `values` as they are, or — for a wide function, where `derivedArrow`
    /// wrote it to take one array — `[values…]`. `Convention.derivedEvidence`
    /// decides by the COUNT, which the caller and the declaring module
    /// agree on (it is the row's context length either way), so a
    /// cross-module nominal needs no flag in any table.
    fn derivedEvidenceArguments(l: *Lowerer, values: []const Node.Index, p: u32) ![]const Node.Index {
        if (Convention.derivedEvidence(values.len) == .positional) return values;
        const range = try l.b.addRange(values);
        const array = try l.add(.array, p, @intFromEnum(range.start), @intFromEnum(range.end));
        const one = try l.scratch.alloc(Node.Index, 1);
        one[0] = array;
        return one;
    }

    /// A derived `eq`'s `&&` of one term per position, built left to right
    /// in runs of `derived_group`: `a && b && … && (c && d && …) && (…)`.
    /// A run prints flat; the next one sits in parentheses as the right
    /// operand, so an engine that nests a flat chain (JavaScriptCore) nests
    /// no more than one run and the number of runs. Up to `derived_group`
    /// terms this is exactly the one flat chain it always was.
    const Conjunction = struct {
        whole: ?Node.Index = null,
        run: ?Node.Index = null,
        count: u32 = 0,
        /// Every term, in order: the steps form's statements
        /// (`returnConjunction`) — a `&&` cannot suspend in the middle — and a
        /// looping arm's guards (`guardConjunction`).
        terms: std.ArrayList(Node.Index) = .empty,

        fn add(c: *Conjunction, l: *Lowerer, term: Node.Index, p: u32) !void {
            try c.terms.append(l.scratch, term);
            if (l.inSteps()) return;
            c.run = try l.conjoin(c.run, term, p);
            c.count += 1;
            if (c.count < derived_group) return;
            c.whole = try l.conjoin(c.whole, c.run.?, p);
            c.run = null;
            c.count = 0;
        }

        fn finish(c: *Conjunction, l: *Lowerer, p: u32) !?Node.Index {
            const run = c.run orelse return c.whole;
            return try l.conjoin(c.whole, run, p);
        }
    };

    /// `return a && b && …;` — or, in the steps form, one statement a term:
    /// `if (!a) return false;`, a comparison that may be steps bound and
    /// yielded first (`awaitRequest`), and the last term returned, so that
    /// steps in tail position replace the frame (`_core/_derived.mjs`'s `deep`).
    fn returnConjunction(l: *Lowerer, out: *StmtList, c: *Conjunction, p: u32) !void {
        if (!l.inSteps()) {
            try out.append(l.scratch, try l.derivedReturn((try c.finish(l, p)).?, p));
            return;
        }
        const terms = c.terms.items;
        for (terms[0 .. terms.len - 1]) |term| {
            const answer = try l.awaitRequest(out, term, p);
            const then = [_]Node.Index{try l.returnStmt(try l.add(.false_lit, p, Node.Data.unused, Node.Data.unused), p)};
            try l.ifStatement(out, try l.negate(answer, p), &then, p);
        }
        try out.append(l.scratch, try l.returnStmt(terms[terms.len - 1], p));
    }

    /// `if (!a) { return false; }` for every term a looping arm compares
    /// before it continues (`nominalArrow`): the direct form tests the
    /// term, the steps form awaits it first (`awaitRequest`).
    fn guardConjunction(l: *Lowerer, out: *StmtList, c: *Conjunction, p: u32) !void {
        for (c.terms.items) |term| {
            const answer = try l.awaitRequest(out, term, p);
            const then = [_]Node.Index{try l.returnStmt(try l.add(.false_lit, p, Node.Data.unused, Node.Data.unused), p)};
            try l.ifStatement(out, try l.negate(answer, p), &then, p);
        }
    }

    /// `while (true) { stmts }` when an arm loops, else `stmts`.
    fn loopIf(l: *Lowerer, looped: bool, stmts: []const Node.Index, p: u32) ![]const Node.Index {
        if (!looped) return stmts;
        const range = try l.b.addRange(stmts);
        const record = try l.b.addRecord(range);
        const one = try l.scratch.alloc(Node.Index, 1);
        one[0] = try l.add(.while_true, p, @intFromEnum(JsIr.NameIndex.none), @intFromEnum(record));
        return one;
    }

    /// Per position of nominal derived row `r`'s body: whether it is
    /// the LAST position of its constructor and compares the row's own type
    /// with the row's own evidence, unchanged — `Cons Int L`'s `L`, a tree's
    /// right child. Such a position is a tail self-call, and the function
    /// loops there instead (`nominalArrow`): the same comparisons in the same
    /// order, on no new frame. A position that changes the evidence
    /// (polymorphic recursion) is a call like any other.
    fn selfLoopParts(l: *Lowerer, r: u32, row: Dispatch.Derived) ![]const bool {
        const d = l.in.dispatch;
        const parts = d.argsAt(row.body);
        const out = try l.scratch.alloc(bool, parts.len);
        @memset(out, false);
        const id = switch (row.shape) {
            .nominal => |id| id,
            else => return out,
        };
        const entry = l.in.types.entry(id);
        if (entry.module != l.in.module or entry.decl.int() >= l.bir.decls.len) return out;
        const ctors = l.bir.declCtors(l.bir.decls[entry.decl.int()]);
        var cursor: usize = 0;
        for (ctors) |ctor| {
            const arity = Bir.SubRange.len(.{ .start = ctor.args_start, .end = ctor.args_end });
            cursor += arity;
            if (arity == 0 or cursor > parts.len) continue;
            const t = d.term(parts[cursor - 1]);
            const use = switch (t) {
                .derived => |u| u,
                else => continue,
            };
            if (use.index != r) continue;
            const args = d.argsAt(use.args);
            if (args.len != row.context.len) continue;
            const identity = for (args, 0..) |a, k| {
                switch (d.term(a)) {
                    .param => |param| if (param.k != k) break false,
                    else => break false,
                }
            } else true;
            out[cursor - 1] = identity;
        }
        return out;
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
        const parts = l.in.dispatch.argsAt(row.body);

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
            return try l.derivedFunction(params, stmts.items, p);
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
        // An arm whose LAST position is the function itself with its
        // own evidence loops instead of calling (`selfLoopParts`).
        const loops = try l.selfLoopParts(l.derived_row orelse std.math.maxInt(u32), row);
        var looped = false;
        for (ctors, 0..) |ctor, i| {
            const arity = Bir.SubRange.len(.{ .start = ctor.args_start, .end = ctor.args_end });
            var body: StmtList = .empty;
            var value: Conjunction = .{};
            var arm_loops = false;
            var arg: u32 = 0;
            while (arg < arity) : (arg += 1) {
                if (cursor >= parts.len) {
                    try l.reportDispatchBug(region, derived_parts_short);
                    return null;
                }
                const part = parts[cursor];
                const loops_here = loops[cursor];
                cursor += 1;
                const slot = try l.slotName(arg);
                const left = try l.member(try l.ident(x, p), slot, p);
                const right = try l.member(try l.ident(y, p), slot, p);
                if (loops_here) {
                    // `if (!a) return false; …` for what came before, then
                    // `$x = $x.b; $y = $y.b; continue;`.
                    if (row.kind == .eq) try l.guardConjunction(&body, &value, p);
                    try body.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(x, p)).int(), left.int()));
                    try body.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(y, p)).int(), right.int()));
                    try body.append(l.scratch, try l.add(.continue_stmt, p, @intFromEnum(JsIr.NameIndex.none), Node.Data.unused));
                    arm_loops = true;
                    looped = true;
                    continue;
                }
                switch (row.kind) {
                    .eq => {
                        const one = (try l.partEq(part, left, right, region, p)) orelse return null;
                        try value.add(l, one, p);
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
            } else if (row.kind == .eq and !arm_loops) {
                try l.returnConjunction(&body, &value, p);
            }
            if (ctors.len == 1) return try l.derivedFunction(params, try l.loopIf(looped, body.items, p), p);
            const body_range = try l.b.addRange(body.items);
            const record = try l.b.addRecord(body_range);
            // The LAST constructor is the `default` arm and gets no `case`:
            // a well-typed match needs no default (`backend.md` §7) and
            // `x.$` has already been proved equal to `y.$`.
            const test_expr: Node.OptionalIndex = if (i + 1 == ctors.len)
                .none
            else if (l.integerTags(id))
                (try l.intNode(@intCast(i), p)).toOptional()
            else
                (try l.stringNode(l.text(l.bir.symbol(ctor.name)), p)).toOptional();
            try arms.append(l.scratch, try l.add(.switch_case, p, @intFromEnum(test_expr), @intFromEnum(record)));
        }
        const arm_range = try l.b.addRange(arms.items);
        const arms_record = try l.b.addRecord(arm_range);
        const discriminant = try l.member(try l.ident(x, p), l.well.tag, p);
        try stmts.append(l.scratch, try l.add(.switch_stmt, p, discriminant.int(), @intFromEnum(arms_record)));
        return try l.derivedFunction(params, try l.loopIf(looped, stmts.items, p), p);
    }

    /// `!test`, written `a !== b` for `a === b` and the other way round.
    fn negate(l: *Lowerer, test_expr: Node.Index, p: u32) !Node.Index {
        if (l.b.nodes.items(.tag)[test_expr.int()] == .binary) {
            const d = l.b.nodes.items(.data)[test_expr.int()];
            const flipped: ?JsIr.BinaryOp = switch (@as(JsIr.BinaryOp, @enumFromInt(d.rhs))) {
                .strict_eq => .strict_ne,
                .strict_ne => .strict_eq,
                else => null,
            };
            if (flipped) |op| {
                const pair = l.b.extra.items[d.lhs..][0..2];
                return l.binary(op, @enumFromInt(pair[0]), @enumFromInt(pair[1]), p);
            }
        }
        return l.unary(.not, test_expr, p);
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
    /// two concrete expressions, so a `primitive` term is the JavaScript
    /// operator itself and not the comparator of §9.1 — that is the
    /// difference from §8.2, where the same term is in value position and
    /// must be a function.
    fn partEq(
        l: *Lowerer,
        part: Dispatch.TermIndex,
        left: Node.Index,
        right: Node.Index,
        region: Inst.Index,
        p: u32,
    ) !?Node.Index {
        const t = l.in.dispatch.term(part);
        switch (t) {
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
            .param => |param| return try l.evidenceCall(param.k, left, right, p),
            .top, .ext => return l.namedPartCall(part, .eq, left, right, region, p),
            // The proven-undetermined default (checker-v2.md §13.1): a slot
            // nothing ever inhabits, or a `number` still unresolved at
            // generalisation whose `eq` is `===` whichever of `Int` and
            // `Float` it settles on. `Basics.eq` IS that answer.
            //
            // INVARIANT, and it is the CHECKER's to hold: `undetermined`
            // means exactly that and nothing else. What pins which programs
            // make one is `tests/corpus/dispatch/ErrParts`.
            .undetermined => return try l.call(try l.coreValue(.Basics, .eq, p), &.{ left, right }, p),
            .derived, .ext_derived => {
                if (!l.derivedBodyExists(t)) {
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
    fn partCompare(
        l: *Lowerer,
        out: *StmtList,
        part: Dispatch.TermIndex,
        left: Node.Index,
        right: Node.Index,
        region: Inst.Index,
        p: u32,
    ) !?Node.Index {
        const t = l.in.dispatch.term(part);
        switch (t) {
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
                    // The steps form binds no `const`s (`stepsTemp`): it
                    // calls `compare$char` (§9.1) instead.
                    if (l.inSteps()) return try l.call(try l.primitiveValue(.char_compare, p), &.{ left, right }, p);
                    // The CODE POINTS are bound, not the operands: an
                    // `Order` reads each of them twice.
                    const a = try l.bindSubject(out, try l.codePointCall(left, p), p);
                    const b = try l.bindSubject(out, try l.codePointCall(right, p), p);
                    return try l.orderOf(a, b, p);
                },
                // Never `<`: `core/String.js`'s `compare` is Unicode scalar
                // order and `<` is UTF-16 code-unit order (§3.2, A.26).
                .string_compare => return try l.call(try l.stringCompare(p), &.{ left, right }, p),
            },
            .param => |param| return try l.evidenceCall(param.k, left, right, p),
            .top, .ext => return l.namedPartCall(part, .compare, left, right, region, p),
            // A position nothing ever inhabits — `Nothing < Nothing` at an
            // element type no use constrains. There is no ordering to get
            // wrong, and `"EQ"` is the one answer that leaves a
            // lexicographic sequence reading the position after it.
            .undetermined => return try l.stringNode("EQ", p),
            .derived, .ext_derived => {
                if (!l.derivedBodyExists(t)) {
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
        part: Dispatch.TermIndex,
        kind: Dispatch.Derived.Kind,
        left: Node.Index,
        right: Node.Index,
        p: u32,
    ) !Node.Index {
        const t = l.in.dispatch.term(part);
        const callee = try l.derivedName(t, p);
        const evidence = try l.termValues(l.in.dispatch.argsAt(t.argsOf()), kind, p);
        return l.applyEvidence(callee, try l.derivedEvidenceArguments(evidence, p), left, right, !l.leafTerm(t), p);
    }

    /// Whether a derived term names a leaf row of this module: it takes no
    /// depth, so a call passes none and its eta-expansion forwards none.
    /// Another module's derived function may take one, so it is always
    /// handed one; a leaf ignores it.
    fn leafTerm(l: *Lowerer, t: Dispatch.Term) bool {
        return switch (t) {
            .derived => |use| l.isLeaf(use.index),
            else => false,
        };
    }

    /// `M$m(<its evidence…>, l, r)` — a `top` or `ext` value at one body
    /// position, applied to its own arguments (§7.1's amendment, A.64).
    ///
    /// A term whose argument count and requirement count disagree has no
    /// honest call at all, so it is refused rather than guessed at — the
    /// evidence-count assert, again, where it is cheap (checker-v2.md §13.3).
    fn namedPartCall(
        l: *Lowerer,
        part: Dispatch.TermIndex,
        kind: Dispatch.Derived.Kind,
        left: Node.Index,
        right: Node.Index,
        region: Inst.Index,
        p: u32,
    ) !?Node.Index {
        const t = l.in.dispatch.term(part);
        const args = l.in.dispatch.argsAt(t.argsOf());
        if (l.requirementCount(t) != args.len) {
            try l.refuseConstrainedPart(region);
            return null;
        }
        l.assertFlatCall(t);
        const evidence = try l.termValues(args, kind, p);
        const callee = if (l.listRuntime(t)) |which| try l.runtimeValue(which, p) else try l.termName(t, p);
        return try l.applyEvidence(callee, evidence, left, right, l.takesDepth(t), p);
    }

    /// `callee(<evidence…>, left, right)`: a FLAT call (`Convention.call`).
    /// Its callers are a derived function, flat by construction, and
    /// `namedPartCall`, which asserts it. With `depth`, the callee takes a
    /// depth too (`depthCall`): a derived function, or `List`'s `eq` and
    /// `compare`.
    fn applyEvidence(
        l: *Lowerer,
        callee: Node.Index,
        evidence: []const Node.Index,
        left: Node.Index,
        right: Node.Index,
        depth: bool,
        p: u32,
    ) !Node.Index {
        const args = try l.scratch.alloc(Node.Index, evidence.len + 2);
        @memcpy(args[0..evidence.len], evidence);
        args[evidence.len] = left;
        args[evidence.len + 1] = right;
        if (depth) return l.depthCall(callee, args, p);
        return l.call(callee, args, p);
    }

    /// Whether a `top` or `ext` comparison takes a depth: `List`'s `eq` and
    /// `compare`, called as the runtime's `listEq` and `listCompare`
    /// (`listRuntime`), the two hand-written comparisons that sit
    /// between derived functions — a `type T = T (List T)` recurses through
    /// them (`backend.md` §4, *Derived comparisons do not grow the native
    /// stack*). A hand-written beni method does not: it is a function like
    /// any other, and its own recursion is its own.
    fn takesDepth(l: *Lowerer, t: Dispatch.Term) bool {
        return l.listRuntime(t) != null;
    }

    /// Which runtime loop stands in for `List.eq` or `List.compare` when
    /// derived code calls it, or null for any other value.
    /// `core/List.js` stays as it was; the runtime's copies take the depth.
    fn listRuntime(l: *Lowerer, t: Dispatch.Term) ?Runtime {
        const list = l.in.graph.lookup(.core, InternPool.WellKnown.List.symbol()) orelse return null;
        const eq = InternPool.WellKnown.eq.symbol();
        const compare = InternPool.WellKnown.compare.symbol();
        const spelled: Symbol = switch (t) {
            .ext => |e| blk: {
                if (e.module != list or e.module.int() >= l.in.interfaces.len) return null;
                const iface = &l.in.interfaces[e.module.int()];
                const v = @intFromEnum(e.value);
                if (iface.findValue(l.interner.global, eq)) |i| if (@intFromEnum(i) == v) break :blk eq;
                if (iface.findValue(l.interner.global, compare)) |i| if (@intFromEnum(i) == v) break :blk compare;
                return null;
            },
            .top => |use| blk: {
                if (l.in.module != list or use.decl.int() >= l.bir.decls.len) return null;
                break :blk l.bir.symbol(l.bir.decls[use.decl.int()].name);
            },
            else => return null,
        };
        if (spelled == eq) return .listEq;
        if (spelled == compare) return .listCompare;
        return null;
    }

    /// A derived function in VALUE position: the bare name when it takes no
    /// evidence, its eta-expansion around its own arguments when it does
    /// (§8.2, A.25).
    ///
    /// **A term with no body is a table the checker did not write.** Every
    /// shape §9 describes has a body for both methods and `List a` has its
    /// own `pub foreign eq` and `pub foreign compare` (§5.2), so nothing is
    /// MISSING here any more; something would be WRONG, so it reports
    /// `internal` rather than `not_implemented`. Not reachable by any
    /// program: the checker refuses `eq` and `compare` on a type whose
    /// method has no body before the backend is asked (§3.3, A.54), so only
    /// a hand-built table gets here, and the in-source test below is what
    /// holds it.
    ///
    /// **No depth cap**: the tree cannot point back at itself
    /// (checker-v2.md §13.1: every argument follows its owner), so the old
    /// 32-level `parts` cap guarded no cycle, and refused an unannotated
    /// record literal 33 levels deep. The recursion is as deep as the type,
    /// which the parser's own depth bounds.
    fn derivedValue(l: *Lowerer, i: Dispatch.TermIndex, p: u32) Allocator.Error!Node.Index {
        const t = l.in.dispatch.term(i);
        const kind = l.derivedTermKind(t);
        if (!l.derivedBodyExists(t)) {
            try l.reportDispatchBug(l.region, derived_body_missing);
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        const args = l.in.dispatch.argsAt(t.argsOf());
        if (args.len != l.requirementCount(t)) {
            try l.reportEvidenceShape(l.region);
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        const callee = try l.derivedName(t, p);
        if (args.len == 0) return callee;
        return l.etaExpand(callee, try l.derivedEvidenceArguments(try l.termValues(args, kind, p), p), if (l.leafTerm(t)) 2 else 3, p);
    }

    /// Which of §9's two methods a derived term is.
    ///
    /// **Ask it only about a `derived` or an `ext_derived`.** Every other
    /// term gets `.eq`, and that is a default and not an answer: a `top` or
    /// an `ext` names a value whose kind lives in its signature, which this
    /// file does not read (§8.0).
    fn derivedTermKind(l: *Lowerer, t: Dispatch.Term) Dispatch.Derived.Kind {
        return switch (t) {
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
    fn derivedName(l: *Lowerer, t: Dispatch.Term, p: u32) !Node.Index {
        switch (t) {
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
            // Unreachable by the contract: every caller tests the term is
            // one of the two derived variants first.
            else => {
                try l.reportDispatchBug(l.region, derived_name_of_non_derived);
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
        }
    }

    /// Whether the module that owns this term EMITS the function §8.5
    /// names it. Three ways it does not, and each is a wall rather than a
    /// call to a name that is not there:
    ///
    ///   - a derived row index past this module's table;
    ///   - a `foreign type`'s method: there are no constructors to walk, so
    ///     no module derives one (A.55, A.60);
    ///   - a nominal type whose own module supplies a `pub` value of that
    ///     name: the module rule won there and the eager pass wrote
    ///     nothing (§3.3 step 1, §6.3.1 step 4).
    ///
    /// **It has to be the same questions `Solve.deriveOne` asks, in the
    /// same order**, or the emitter names a row the declaring module did not
    /// write — and §3.2's table comes FIRST (A.63).
    fn derivedBodyExists(l: *Lowerer, t: Dispatch.Term) bool {
        switch (t) {
            .derived => |use| return use.index < l.in.dispatch.derived.len,
            .ext_derived => |use| {
                const entry = l.in.types.entry(use.type);
                if (entry.kind != .adt) return false;
                // The declaring module's published row says whether it emits
                // the function (checker-v2.md §14.2): the
                // one answer. A record the checker wrote has a row for every
                // type it can reach, so no row is a table the checker did not
                // write, and a wall.
                const published = Dispatch.publishedContext(l.in.interfaces, l.in.types, l.interner.global, use.type, use.kind) orelse return false;
                return published.row.status == .present;
            },
            else => return false,
        }
    }

    fn operandNames(l: *Lowerer) ![2]JsIr.NameIndex {
        return .{
            try l.name(.{ .module = .none, .base = l.well.left, .tag = JsIr.Name.no_tag }),
            try l.name(.{ .module = .none, .base = l.well.right, .tag = JsIr.Name.no_tag }),
        };
    }

    /// The three exports of `_core/_derived.mjs`
    /// (`src/js/derived_runtime.mjs`): the engine and `List`'s two loops as
    /// derived code calls them, with a depth.
    const Runtime = enum {
        deep,
        listEq,
        listCompare,
    };

    /// The engine, as a value: imported from `_core/_derived.mjs`.
    fn deepName(l: *Lowerer, p: u32) !Node.Index {
        return l.runtimeValue(.deep, p);
    }

    /// One export of the runtime, imported by this module
    /// (`importStatements`) under `_derived$<name>`: `_derived` is no module
    /// name (a module segment is an upper identifier), so the local name
    /// collides with nothing, and `--release` renames it like any other.
    fn runtimeValue(l: *Lowerer, which: Runtime, p: u32) !Node.Index {
        switch (which) {
            .deep => l.needs.deep = true,
            .listEq => l.needs.list_eq = true,
            .listCompare => l.needs.list_compare = true,
        }
        return l.ident(try l.runtimeLocal(which), p);
    }

    fn runtimeLocal(l: *Lowerer, which: Runtime) !JsIr.NameIndex {
        return l.name(.{
            .module = (try l.interner.getOrPut(l.gpa, "_derived")).toOptional(),
            .base = try l.interner.getOrPut(l.gpa, @tagName(which)),
            .tag = JsIr.Name.no_tag,
        });
    }

    /// `import { deep as _derived$deep, … } from "…/_core/_derived.mjs";`
    fn runtimeImport(l: *Lowerer) !?Node.Index {
        var specs: std.ArrayList(JsIr.Specifier) = .empty;
        const wanted = [_]struct { Runtime, bool }{
            .{ .deep, l.needs.deep },
            .{ .listEq, l.needs.list_eq },
            .{ .listCompare, l.needs.list_compare },
        };
        for (wanted) |w| {
            if (!w[1]) continue;
            try specs.append(l.scratch, .{
                .imported = try l.name(.{ .module = .none, .base = try l.interner.getOrPut(l.gpa, @tagName(w[0])), .tag = JsIr.Name.no_tag }),
                .local = try l.runtimeLocal(w[0]),
            });
        }
        if (specs.items.len == 0) return null;
        return try l.importStatement(l.in.derived_runtime, specs.items);
    }

    /// `typeof name === "object"`.
    fn isObject(l: *Lowerer, n: JsIr.NameIndex, p: u32) !Node.Index {
        const kind = try l.unary(.type_of, try l.ident(n, p), p);
        return l.binary(.strict_eq, kind, try l.stringNode("object", p), p);
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

    /// **The evidence-count assert, again, where it is cheap** (checker-v2.md §2, §13.3).
    /// `Dispatch.finish`'s caller already refused a table that does not add
    /// up — on every module that reported no error — so this is the second
    /// line: a table that reached the backend some other way (a cache entry,
    /// a hand-built test table) is refused here rather than emitted as a call
    /// JavaScript would run with the wrong number of arguments.
    ///
    /// Two checks, in the order they were always made: every derived term
    /// in the trees names a function some module writes, and the trees are
    /// what checker-v2.md §2's invariant says — `expected` roots, each term's `args` as long as its
    /// callee's requirement count, no `field` among them.
    fn refuseEvidence(l: *Lowerer, inst: Inst.Index, roots: []const Dispatch.TermIndex, expected: u32) !bool {
        for (roots) |root| {
            if (l.derivedBodiesExist(root)) continue;
            try l.reportDispatchBug(inst, derived_body_missing);
            return true;
        }
        if (!l.evidenceShapeOk(roots, expected)) {
            try l.reportEvidenceShape(inst);
            return true;
        }
        return false;
    }

    /// Whether every derived term in the tree under `i` names a function
    /// some module writes: `readTable` judged each term once.
    fn derivedBodiesExist(l: *Lowerer, i: Dispatch.TermIndex) bool {
        return i.int() < l.bodies_ok.len and l.bodies_ok[i.int()];
    }

    /// Whether `roots` is the tree §8.2 describes, `expected` roots wide.
    ///
    /// **`expected` is the half the tree cannot give.** The nested counts
    /// say how each root is SHAPED; only the callee's own requirement count
    /// says how many roots there are. Two roots for a one-evidence callee
    /// printed `NaN` and then recursed forever, none for a two-evidence
    /// callee threw `TypeError: $m$0 is not a function`, and the build
    /// exited 0 either way — which is why the count is demanded exactly.
    fn evidenceShapeOk(l: *Lowerer, roots: []const Dispatch.TermIndex, expected: u32) bool {
        if (roots.len != expected) return false;
        for (roots) |root| {
            if (!l.termShapeOk(root)) return false;
        }
        return true;
    }

    fn termShapeOk(l: *Lowerer, i: Dispatch.TermIndex) bool {
        return i.int() < l.shape_ok.len and l.shape_ok[i.int()];
    }

    /// `termShapeOk` for one term, given the answer for every later one: the
    /// pre-order rule (an argument that does not follow its owner is a table
    /// that points back at itself) makes one pass from the last term enough,
    /// and a shared term is judged once.
    fn termOkLocal(l: *Lowerer, ok: []const bool, i: u32) bool {
        const d = l.in.dispatch;
        const t = d.terms[i];
        if (t == .field) return false;
        const r = t.argsOf();
        if (@as(u64, r.start) + r.len > d.args.len) return false;
        const args = d.argsAt(r);
        if (args.len != l.requirementCount(t)) return false;
        for (args) |arg| {
            if (arg.int() <= i or arg.int() >= d.terms.len) return false;
            if (!ok[arg.int()]) return false;
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
            \\`docs/design/checker-v2.md` §13.1 gives every call one evidence root per
            \\requirement of the function it calls, and every term as many arguments as
            \\the function it names has requirements. The tree the checker
            \\recorded here does not — either a term names something §8.2 cannot pass,
            \\or a callee's evidence count here disagrees with the one in its own module.
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

    /// checker-v2.md §13.1 gives every `method_call` and every
    /// `type_dispatch` a site with a callee term naming the function it
    /// runs. None means the checker did not record one — or recorded an
    /// `err` there, which the converter turns into no term — and no program
    /// that checked clean can ask for either.
    const no_callee_site =
        \\`docs/design/checker-v2.md` §13.1 gives every method call and every return-type
        \\dispatch a callee naming the function it runs, and the table has none here — so
        \\there is no function to call.
    ;

    /// An `undetermined` leaf with no enclosing derived function: nothing
    /// says which method it answers, so there is no honest structural
    /// answer to give (checker-v2.md §13.1). The old converter never wrote
    /// one, because a legacy `err` SITE becomes no
    /// term at all.
    const undetermined_without_method =
        \\The table answers a hidden argument with the `undetermined` default outside any
        \\derived method, so nothing says whether it stands for an `eq` or a `compare`
        \\(`docs/design/checker-v2.md` §13.1).
    ;

    /// §8.4 has no receiver, so §8.3's record-field row cannot appear.
    const field_without_receiver =
        \\The table dispatches this to a record field, but `docs/design/static-dispatch-spike.md`
        \\§8.4 has no receiver to read a field from: only a method call can answer `field`.
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

    /// The callee term of a `method_call` or `type_dispatch`, or null with
    /// `no_callee_site` reported.
    fn calleeOf(l: *Lowerer, inst: Inst.Index) !?struct { Dispatch.TermIndex, []const Dispatch.TermIndex } {
        const site = l.in.dispatch.siteOf(inst) orelse {
            try l.reportDispatchBug(inst, no_callee_site);
            return null;
        };
        const callee = site.callee.unwrap() orelse {
            try l.reportDispatchBug(inst, no_callee_site);
            return null;
        };
        return .{ callee, l.in.dispatch.argsAt(site.evidence) };
    }

    /// The evidence a derived CALLEE passes: its own arguments, after the
    /// evidence-count assert over them, with the site's roots required empty (a derived
    /// function's evidence rides on the term, A.46). Null when refused.
    fn derivedCalleeEvidence(
        l: *Lowerer,
        inst: Inst.Index,
        callee: Dispatch.TermIndex,
        roots: []const Dispatch.TermIndex,
        p: u32,
    ) !?[]const Node.Index {
        if (try l.refuseEvidence(inst, roots, 0)) return null;
        // One root, the callee itself: the same assert, over its own
        // arguments — and `derived_body_missing` when no module writes it.
        if (try l.refuseEvidence(inst, &.{callee}, 1)) return null;
        const t = l.in.dispatch.term(callee);
        return try l.derivedEvidenceArguments(try l.termValues(l.in.dispatch.argsAt(t.argsOf()), l.derivedTermKind(t), p), p);
    }

    /// A `top`/`ext`/`param` callee: its evidence is the site's roots, as
    /// many as its requirement count, and it carries no arguments of its
    /// own. Null when refused.
    fn namedCalleeEvidence(
        l: *Lowerer,
        inst: Inst.Index,
        callee: Dispatch.TermIndex,
        roots: []const Dispatch.TermIndex,
        p: u32,
    ) !?[]const Node.Index {
        const t = l.in.dispatch.term(callee);
        if (t.argsOf().len != 0) {
            try l.reportEvidenceShape(inst);
            return null;
        }
        if (try l.refuseEvidence(inst, roots, l.requirementCount(t))) return null;
        l.assertFlatCall(t);
        return try l.evidenceArguments(roots, p);
    }

    /// A method call, a return-type dispatch and a derived body position
    /// all put the evidence in front of the written arguments in ONE call
    /// (`receiverCall`, `typeDispatchExpr`, `applyEvidence`): the `flat`
    /// shape of `Convention.call`. It is the only shape they can meet — a
    /// method has a function type, and a `thunk`'s type is not a function
    /// (a function type has no methods) — and this is where that is
    /// asserted rather than assumed (checker-v2.md §12.5).
    fn assertFlatCall(l: *Lowerer, t: Dispatch.Term) void {
        const use: Convention.Use = switch (t) {
            .top => |u| Convention.ofDecl(l.in.dispatch, l.bir, u.decl.int()),
            .ext => |e| Convention.ofImport(l.in.interfaces, e.module, @intFromEnum(e.value)),
            else => return,
        };
        std.debug.assert(Convention.call(use.convention) == .flat);
    }

    /// A method call (§8.3). The callee is the site's callee term and every
    /// root is one hidden argument in front of the receiver.
    fn methodCallExpr(l: *Lowerer, out: *StmtList, inst: Inst.Index) !Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        const m = l.bir.extraData(@enumFromInt(d.rhs), Bir.MethodCall);
        const args: Bir.SubRange = .{ .start = m.args_start, .end = m.args_end };
        l.region = inst;
        const saved_choice = l.term_choice;
        l.term_choice = l.in.dispatch.effectAt(inst).body;
        defer l.term_choice = saved_choice;
        // checker-v2.md §13.1 gives every `method_call` a callee. None
        // means the checker forgot one — or wrote an `err` site, which the
        // converter turns into no term — and a program that failed to check
        // never reaches here, because `beni build` refuses to emit a project
        // that has an error diagnostic; so it is a compiler bug and says so
        // rather than emitting `undefined(…)` and exiting 0.
        const callee, const roots = (try l.calleeOf(inst)) orelse
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        const target = l.in.dispatch.term(callee);
        switch (target) {
            // A record receiver: `language.md` §6.3's field call, unchanged.
            .field => {
                // A field call passes no evidence — the closure in the
                // field is already of the arity the call site wrote — so
                // this list is empty, and a non-empty one is the same
                // caught bug as any other wrong-length list.
                if (try l.refuseEvidence(inst, roots, 0)) {
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                const values = try l.exprListWithHead(out, @enumFromInt(d.lhs), args);
                const field_fn = try l.fieldMember(values[0], l.bir.symbol(m.name), p);
                return l.suspension(out, inst, try l.call(field_fn, values[1..], p));
            },
            // Never a callee: an `err` site becomes no term at all.
            .undetermined => {
                try l.reportDispatchBug(inst, no_callee_site);
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
            // §9's derived function, applied to the evidence THIS use
            // passes and then to the two values (§8.3).
            .derived, .ext_derived => {
                // `x == Just y`: the tag and the fields tested in place,
                // with no constructor built and no call (§4).
                if (roots.len == 0 and Bir.SubRange.len(args) == 1) {
                    const right: Inst.Index = l.bir.extraSlice(args, Inst.Index)[0];
                    if (try l.ctorEquality(out, callee, @enumFromInt(d.lhs), right, m.origin, p)) |tested| return tested;
                }
                const evidence = (try l.derivedCalleeEvidence(inst, callee, roots, p)) orelse
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                const callee_name = try l.derivedName(target, p);
                const value = try l.receiverCall(out, callee_name, evidence, @enumFromInt(d.lhs), args, p);
                // `a /= b` is `!eq(a, b)`; an ordering operator wraps the
                // `Order` the method answers in §8.3's test.
                return l.orderTest(value, m.origin, p);
            },
            .primitive => |prim| {
                if (try l.refuseEvidence(inst, roots, 0)) {
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                const values = try l.exprListWithHead(out, @enumFromInt(d.lhs), args);
                const receiver = values[0];
                const rest = values[1..];
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
            .top, .ext, .param => {
                const evidence = (try l.namedCalleeEvidence(inst, callee, roots, p)) orelse
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                const callee_name = try l.termName(target, p);
                const called = try l.receiverCall(out, callee_name, evidence, @enumFromInt(d.lhs), args, p);
                const value = try l.suspension(out, inst, called);
                // An ordering operator against a non-primitive target is
                // the `Order` test of §8.3: the method answers `Order` and
                // the operator answers `Bool`.
                return l.orderTest(value, m.origin, p);
            },
        }
    }

    // ---- `==` against a constructor (backend.md §4) ---------------------
    //
    // `a == C e1 … en` whose `eq` is a derived function is what that
    // function computes, written in place: the tag, then each field in
    // declaration order — `a.$ === "C" && a.a === e1 && …` — with no
    // constructor built and no call. A field is tested with `===` only when
    // its own `eq` is `primitive strict_eq`, or recursively when it is
    // derived and the operand in that field is itself a constructor
    // application; anything else keeps the call, so the test is the
    // derived function's answer exactly. Every operand is evaluated once, in
    // written order, before any test: one that is not a read is bound first,
    // so a test that fails early skips no evaluation.

    /// The one decision this shares with `Reach`, which must not keep a
    /// derived `eq` alive for a test that never calls it: `CtorEq`.
    fn ctorEqContext(l: *Lowerer) CtorEq.Context {
        return .{
            .bir = l.bir,
            .dispatch = l.in.dispatch,
            .interfaces = l.in.interfaces,
            .types = l.in.types,
            .interner = l.interner.global,
        };
    }

    fn ctorApplication(l: *Lowerer, inst: Inst.Index) ?CtorEq.Application {
        return CtorEq.application(l.ctorEqContext(), inst);
    }

    fn fieldEq(l: *Lowerer, t_index: Dispatch.TermIndex, ctor: Inst.Index, j: usize) CtorEq.FieldEq {
        return CtorEq.fieldEq(l.ctorEqContext(), t_index, ctor, j);
    }

    /// The operands a test compares, in written order: each field's, or a
    /// nested constructor's own.
    fn ctorLeaves(l: *Lowerer, out: *std.ArrayList(Inst.Index), t_index: Dispatch.TermIndex, inst: Inst.Index) !void {
        const app = l.ctorApplication(inst).?;
        for (app.args, 0..) |arg, j| switch (l.fieldEq(t_index, app.ctor, j)) {
            .nested => |n| try l.ctorLeaves(out, n, arg),
            else => try out.append(l.scratch, arg),
        };
    }

    fn ctorTest(l: *Lowerer, subject: Node.Index, t_index: Dispatch.TermIndex, inst: Inst.Index, leaves: []const Node.Index, cursor: *usize, p: u32) !Node.Index {
        const app = l.ctorApplication(inst).?;
        const rep, const tag = l.ctorRepOf(app.ctor).?;
        var acc = try l.binary(.strict_eq, try l.member(subject, l.well.tag, p), try l.tagLiteral(rep, tag, p), p);
        for (app.args, 0..) |arg, j| {
            const field = try l.member(subject, try l.slotName(@intCast(j)), p);
            const one = switch (l.fieldEq(t_index, app.ctor, j)) {
                .nested => |n| try l.ctorTest(field, n, arg, leaves, cursor, p),
                else => blk: {
                    const leaf = leaves[cursor.*];
                    cursor.* += 1;
                    break :blk try l.binary(.strict_eq, field, leaf, p);
                },
            };
            acc = try l.binary(.logical_and, acc, one, p);
        }
        return acc;
    }

    /// `left == right` (or `/=`) as a tag and field test, when one side is
    /// a constructor application the test can compare; null otherwise.
    fn ctorEquality(l: *Lowerer, out: *StmtList, callee: Dispatch.TermIndex, left: Inst.Index, right: Inst.Index, origin: Bir.WellKnown, p: u32) !?Node.Index {
        const on_right = switch (CtorEq.side(l.ctorEqContext(), callee, origin, left, right) orelse return null) {
            .right => true,
            .left => false,
        };
        const ctor = if (on_right) right else left;
        var insts: std.ArrayList(Inst.Index) = .empty;
        if (on_right) try insts.append(l.scratch, left);
        try l.ctorLeaves(&insts, callee, ctor);
        if (!on_right) try insts.append(l.scratch, right);
        const values = try l.orderedExprs(out, insts.items, false);
        for (values, insts.items) |*v, inst| {
            if (l.isRead(v.*)) continue;
            const n = try l.fresh(l.well.temp);
            try l.constDecl(out, n, v.*, l.pos(inst));
            v.* = try l.ident(n, p);
        }
        const subject = if (on_right) values[0] else values[values.len - 1];
        const leaves = if (on_right) values[1..] else values[0 .. values.len - 1];
        var cursor: usize = 0;
        const tested = try l.ctorTest(subject, callee, ctor, leaves, &cursor, p);
        return if (origin == .neq) try l.negate(tested, p) else tested;
    }

    /// `callee(<evidence…>, receiver, args…)` — §8.3's shape, with the
    /// receiver in front of the written arguments because core is
    /// subject-first and a dot-call is the module function applied to its
    /// receiver. A FLAT call, asserted by `namedCalleeEvidence`
    /// (`assertFlatCall`).
    fn receiverCall(
        l: *Lowerer,
        out: *StmtList,
        callee: Node.Index,
        evidence: []const Node.Index,
        receiver_inst: Inst.Index,
        args: Bir.SubRange,
        p: u32,
    ) !Node.Index {
        const values = try l.exprListWithHead(out, receiver_inst, args);
        const receiver = values[0];
        const rest = values[1..];
        const all = try l.scratch.alloc(Node.Index, evidence.len + 1 + rest.len);
        @memcpy(all[0..evidence.len], evidence);
        all[evidence.len] = receiver;
        @memcpy(all[evidence.len + 1 ..], rest);
        return l.call(callee, all, p);
    }

    /// Return-type dispatch (§8.4): §8.3 with no receiver. Inside a
    /// constrained declaration the callee is always `param k` (§6.7), so
    /// in practice this is `$m$k(args…)`.
    fn typeDispatchExpr(l: *Lowerer, out: *StmtList, inst: Inst.Index) !Node.Index {
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        const t = l.bir.extraData(@enumFromInt(d.rhs), Bir.TypeDispatch);
        const args: Bir.SubRange = .{ .start = t.args_start, .end = t.args_end };
        l.region = inst;
        const saved_choice = l.term_choice;
        l.term_choice = l.in.dispatch.effectAt(inst).body;
        defer l.term_choice = saved_choice;
        const callee, const roots = (try l.calleeOf(inst)) orelse
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        const target = l.in.dispatch.term(callee);
        const evidence = switch (target) {
            .top, .ext, .param, .primitive => (try l.namedCalleeEvidence(inst, callee, roots, p)) orelse
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
            // §6.7 makes a return-type dispatch's callee `param k` inside a
            // constrained declaration, so in practice this is a concrete
            // receiver-less call of a shape's own method: the same call
            // §8.3 makes, minus the receiver.
            .derived, .ext_derived => (try l.derivedCalleeEvidence(inst, callee, roots, p)) orelse
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
            // There is no receiver, so `field` cannot appear at all and is
            // a malformed table.
            .field => {
                try l.reportDispatchBug(inst, field_without_receiver);
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
            .undetermined => {
                try l.reportDispatchBug(inst, no_callee_site);
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
        };
        const callee_name = switch (target) {
            .derived, .ext_derived => try l.derivedName(target, p),
            else => try l.termName(target, p),
        };
        const rest = try l.exprList(out, args);
        const all = try l.scratch.alloc(Node.Index, evidence.len + rest.len);
        @memcpy(all[0..evidence.len], evidence);
        @memcpy(all[evidence.len..], rest);
        return l.suspension(out, inst, try l.call(callee_name, all, p));
    }

    /// §8.3's operator table: a `primitive` target plus the surface origin
    /// of §1.3 is the JavaScript operator itself. This is the only place
    /// the marking reaches the backend, and the reason it exists.
    fn primitiveOperator(
        l: *Lowerer,
        out: *StmtList,
        prim: Dispatch.Primitive,
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
        const index = l.in.interfaces[module.int()].findValue(l.interner.global, function.symbol()) orelse
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
        const roots = l.rootsOf(inst);
        const d = l.bir.instData(inst);
        const p = l.pos(inst);
        const callee_inst: Inst.Index = @enumFromInt(d.lhs);
        // The list has to be as wide as the CALLEE's own evidence, which is
        // the callee's record and not this call's; the two disagreeing is
        // the miscompile §7.2 says the table exists to catch.
        if (try l.refuseEvidence(inst, roots, l.in.dispatch.referenceCount(l.bir, l.in.interfaces, l.decl_index, callee_inst))) {
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        const arg_insts = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);

        // A re-cons of a list a loop holds as an offset (§7's re-consing
        // rule, §8's *Scalar views*): the offset it was matched at, or the
        // list there, and nothing is prepended.
        if (try l.reconsOf(inst)) |recons| if (l.scalarOf(recons.tail)) |k| {
            const tail = try l.ident(try l.localName(recons.tail), p);
            const offset = try l.binary(.sub, tail, try l.intNode(recons.back, p), p);
            if (l.isScalarRaw(inst)) return offset;
            // Built, it may be the list the call was entered with: the
            // parameter's entry answers for it.
            const s = l.scalars.items[k];
            for (l.scalars.items, 0..) |other, j| {
                if (other.label == s.label and other.slot == s.slot and other.entry != .none) return l.materialise(j, offset, p);
            }
            return l.materialise(k, offset, p);
        };

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

        // A `++` the checker solved to lists calls `List.append`, as `==`
        // on a list calls `List.eq` (`Dispatch.appends`; backend.md §4), so
        // `a ++ b` costs what `[ ...a, ...b ]` does. `Basics.append` is a
        // reference with nothing to evaluate, so dropping it changes no
        // order.
        if (arg_insts.len == 2 and roots.len == 0 and l.in.dispatch.isListAppend(inst)) {
            const values = try l.exprList(out, l.bir.subRange(@enumFromInt(d.rhs)));
            return l.suspension(out, inst, try l.call(try l.coreValue(.List, .append, p), values, p));
        }
        // Under `--release`, a `++` one of whose operands is a string —
        // a literal, an interpolation, or another such `++` — is on
        // strings, since both operands have one type, and `Basics.append`
        // of two strings is `+` (`backend.md` §9, *Compact statements*): the
        // hand-written `append`, whose list half is most of it, then ships
        // only for a `++` whose type the lowering cannot see.
        if (arg_insts.len == 2 and roots.len == 0 and l.in.unit_results and
            Operator.isBasicsAppend(l.in.graph, l.in.interfaces, l.bir, l.in.module, callee_inst, l.interner) and
            (l.stringy(arg_insts[0], 0) or l.stringy(arg_insts[1], 0)))
        {
            const v = try l.orderedExprs(out, arg_insts, false);
            return l.binary(.add, v[0], v[1], p);
        }

        // A `Js` intrinsic is the JavaScript it names, written in place,
        // with no call and no import (research 47).
        if (l.jsIntrinsicOf(callee_inst)) |which| {
            // `Js.maySuspend f` is its answer in this body (`backend.md` §4,
            // *`Js.maySuspend` is the body's answer*); `f` is evaluated for
            // what it does, which for the reference it always is is nothing.
            if (which == .maySuspend) {
                for (arg_insts) |a| try l.discard(out, a, p);
                const yes = l.suspendsHere(l.in.dispatch.effectAt(inst).body);
                return l.add(if (yes) .true_lit else .false_lit, p, Node.Data.unused, Node.Data.unused);
            }
            return l.jsIntrinsicCall(out, which, arg_insts, p);
        }

        // Arithmetic, `not` and `Int32`'s bit operations are the JavaScript
        // operators they compute (§4, *Arithmetic is an operator*).
        if (l.operatorOf(callee_inst)) |which| {
            if (which.arity() == arg_insts.len and roots.len == 0) return l.operatorCall(out, which, arg_insts, p);
        }

        // A constructor is an object literal and never a call (§4); the
        // checker has already refused any application of one that is not
        // saturated, so `args` is exactly its field list.
        if (l.ctorRepOf(callee_inst)) |rep_and_tag| {
            const rep, const tag = rep_and_tag;
            // A record alias's constructor sorts its keys like any record
            // literal, so its arguments are pinned exactly as `recordNode`
            // pins a literal's initialisers (`language.md` §6).
            const reordered = switch (rep) {
                .record => |r| isPermuted(try l.fieldOrder(try l.recordNames(r))),
                else => false,
            };
            const args = try l.orderedExprs(out, l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index), reordered);
            return l.ctorValue(rep, tag, args, p);
        }

        // A function called from this one place is written here (§9, *A
        // function called once is written where it is called*).
        // Only a body that is an expression itself: one that needs
        // statements would need a temporary assigned in each arm, which
        // costs more than the call it replaces.
        if (l.inlineTarget(inst)) |index| if (!l.inline_loops[index] and l.isExpressionBody(index) and l.atomArguments(inst)) return l.inlineExpr(out, inst, index);

        // Everything else is one direct n-ary call (`backend.md` §6). The
        // callee and the arguments are ONE sequence, because JavaScript
        // evaluates the callee first and so does beni, and either side may
        // need statements hoisted ahead of the call.
        //
        // The evidence arguments (§8.2) go in front of the written ones.
        // They are names and closures with no statements of their own, so
        // building them after the sequence changes no evaluation order.
        const values = try l.exprListWithHead(out, callee_inst, l.bir.subRange(@enumFromInt(d.rhs)));
        const callee = values[0];
        // A trailing `()` the callee does not take is not passed (§6, *A
        // parameter of type `()`*): `f ()` is `f()`.
        const written = values[1 .. values.len - l.unwrittenArgs(callee_inst, arg_insts)];
        l.region = inst;
        // The evidence takes the body its callee takes (§16.2).
        const saved_choice = l.term_choice;
        l.term_choice = l.in.dispatch.evidenceChoice(l.bir, inst);
        const evidence = try l.evidenceArguments(roots, p);
        l.term_choice = saved_choice;
        if (evidence.len == 0) return l.suspension(out, inst, try l.call(callee, written, p));
        // How the evidence is passed is the callee's convention
        // (checker-v2.md §12.5), the answer its definition was built from.
        switch (Convention.call(l.referenceUse(callee_inst).convention)) {
            .flat => {},
            .applied => return l.suspension(out, inst, try l.call(try l.call(callee, evidence, p), written, p)),
        }
        const args = try l.scratch.alloc(Node.Index, evidence.len + written.len);
        @memcpy(args[0..evidence.len], evidence);
        @memcpy(args[evidence.len..], written);
        return l.suspension(out, inst, try l.call(callee, args, p));
    }

    /// `Basics.and` / `Basics.or`, however the reference reached here: an
    /// `ext_value` from another module, or a `top` when the module being
    /// lowered IS core's `Basics`. Keyed on the core package and on the
    /// well-known symbols, never on the spelling, so a user's own `and` is
    /// an ordinary function.
    /// The `Js` intrinsic `inst` names, or null (research 47).
    fn jsIntrinsicOf(l: *Lowerer, inst: Inst.Index) ?JsIntrinsic.Which {
        return JsIntrinsic.of(l.in.graph, l.in.interfaces, l.bir, inst, l.interner);
    }

    /// A saturated call of a `Js` intrinsic, as the JavaScript it names.
    /// Every operand is evaluated once, in written order (`orderedExprs`);
    /// a property name written as a literal identifier is `.name`, any
    /// other `[name]`; a list literal of arguments is spread into the call.
    /// `Js.each xs f` (`boundary.md` §4.2): `for (const x of xs) …`, the
    /// statement, its value `()`. With a lambda of one parameter that cannot
    /// suspend, the lambda's body, discarded, is the loop's body and its
    /// parameter the loop variable — `for(const f of fs)f()`; with any other
    /// function, the loop calls it, `for(const x of xs)g(x)`. `xs` is
    /// evaluated first, then `f`, then the loop runs, as the call would.
    fn eachLoop(l: *Lowerer, out: *StmtList, xs: Inst.Index, f: Inst.Index, p: u32) !Node.Index {
        if (l.bir.instTag(f) == .lambda and !l.functionSuspends(f)) {
            const ld = l.bir.instData(f);
            const params = l.bir.extraSlice(l.bir.subRange(@enumFromInt(ld.lhs)), Inst.Index);
            if (params.len == 1) {
                const iterable = try l.expr(out, xs);
                var body: StmtList = .empty;
                const param = params[0];
                const n = switch (l.bir.instTag(param)) {
                    .pat_var => try l.localName(l.bir.instData(param).lhs),
                    .pat_wild => try l.fresh(l.well.param),
                    else => blk: {
                        const bound = try l.fresh(l.well.param);
                        try l.bindings(&body, param, try l.ident(bound, l.pos(param)));
                        break :blk bound;
                    },
                };
                try l.discard(&body, @enumFromInt(ld.rhs), p);
                return l.forOf(out, n, iterable, body.items, p);
            }
        }
        const v = try l.orderedExprs(out, &.{ xs, f }, false);
        const n = try l.fresh(l.well.param);
        const applied = try l.call(v[1], &.{try l.ident(n, p)}, p);
        const stmt = try l.add(.expr_stmt, p, applied.int(), Node.Data.unused);
        return l.forOf(out, n, v[0], &.{stmt}, p);
    }

    /// Where a `Js.finally`'s value goes (`backend.md` §4, *`Js.finally` is
    /// `try … finally`*): a temporary the body assigns, nowhere, or out of
    /// the function by the body's own `return`s.
    const FinallyUse = enum { value, discard, tail };

    /// The two arguments of `inst` when it is a saturated `Js.finally`.
    fn finallyArgs(l: *Lowerer, inst: Inst.Index) ?[2]Inst.Index {
        if (l.bir.instTag(inst) != .call) return null;
        const d = l.bir.instData(inst);
        if ((l.jsIntrinsicOf(@enumFromInt(d.lhs)) orelse return null) != .finally) return null;
        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
        if (args.len != 2) return null;
        return .{ args[0], args[1] };
    }

    /// The body of `f` when it is a lambda written in place: one parameter
    /// that binds nothing (`\() ->`, `\_ ->`) and a body that cannot
    /// suspend. A lambda holds no `?` of its own (`question_in_lambda`), so
    /// nothing in the body can leave it but a throw.
    fn thunkBody(l: *Lowerer, f: Inst.Index) ?Inst.Index {
        if (l.bir.instTag(f) != .lambda or l.functionSuspends(f)) return null;
        const d = l.bir.instData(f);
        const params = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.lhs)), Inst.Index);
        if (params.len != 1) return null;
        switch (l.bir.instTag(params[0])) {
            .pat_unit, .pat_wild => {},
            else => return null,
        }
        return @enumFromInt(d.rhs);
    }

    /// `Js.finally body cleanup` (`backend.md` §4, *`Js.finally` is `try …
    /// finally`*): `try { body } finally { cleanup }`, the statement. A
    /// lambda argument written in place (`thunkBody`) is its body, with no
    /// closure made; any other argument is evaluated first, in written
    /// order as the call would, and called inside its block. `use` says
    /// where the body's value goes: `value` assigns a temporary declared
    /// before the `try` and returns it, `discard` drops it, `tail` lowers
    /// the body in tail position — its `return`s leave the function from
    /// inside the guard, and the caller has checked that nothing is to be
    /// done after them (no loop to jump in, no join to call). The cleanup's
    /// value is always discarded.
    fn finallyTry(l: *Lowerer, out: *StmtList, body_fn: Inst.Index, cleanup_fn: Inst.Index, use: FinallyUse, p: u32) !?Node.Index {
        const body = l.thunkBody(body_fn);
        const cleanup = l.thunkBody(cleanup_fn);
        // The arguments that are values, evaluated before the guard; a
        // lambda written in place makes nothing, so evaluating the others
        // around it keeps their order.
        var values: [2]Inst.Index = undefined;
        var n: usize = 0;
        if (body == null) {
            values[n] = body_fn;
            n += 1;
        }
        if (cleanup == null) {
            values[n] = cleanup_fn;
            n += 1;
        }
        const v = try l.orderedExprs(out, values[0..n], false);
        // Each is bound where it stands, in order, unless it is a name or a
        // literal: a call written in its block would run after the guard
        // began, and the body's own effects before the cleanup's maker.
        for (v) |*value| value.* = try l.bindSubject(out, value.*, p);
        const body_value: ?Node.Index = if (body == null) v[0] else null;
        const cleanup_value: ?Node.Index = if (cleanup == null) v[n - 1] else null;

        var guarded: StmtList = .empty;
        var result: JsIr.NameIndex = .none;
        switch (use) {
            .value => {
                result = try l.fresh(l.well.temp);
                try out.append(l.scratch, try l.add(.let_decl, p, @intFromEnum(result), @intFromEnum(Node.OptionalIndex.none)));
                const value = if (body) |b| try l.expr(&guarded, b) else try l.call(body_value.?, &.{}, p);
                // A body that ends in `Js.throw` has no value to assign.
                const ended = guarded.items.len != 0 and l.b.nodes.items(.tag)[guarded.items[guarded.items.len - 1].int()] == .throw_stmt and
                    l.b.nodes.items(.tag)[value.int()] == .undefined_lit;
                if (!ended) try guarded.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(result, p)).int(), value.int()));
            },
            .discard => if (body) |b|
                try l.discard(&guarded, b, p)
            else
                try guarded.append(l.scratch, try l.add(.expr_stmt, p, (try l.call(body_value.?, &.{}, p)).int(), Node.Data.unused)),
            .tail => if (body) |b|
                try l.tailStmts(&guarded, b, null)
            else
                try l.tailReturn(&guarded, try l.call(body_value.?, &.{}, p), null, p),
        }
        var final: StmtList = .empty;
        if (cleanup) |c|
            try l.discard(&final, c, p)
        else
            try final.append(l.scratch, try l.add(.expr_stmt, p, (try l.call(cleanup_value.?, &.{}, p)).int(), Node.Data.unused));
        const body_range = try l.b.addRange(guarded.items);
        const final_range = try l.b.addRange(final.items);
        const none_range = try l.b.addRange(&[_]Node.Index{});
        const record = try l.b.addRecord(JsIr.Try{
            .body_start = body_range.start,
            .body_end = body_range.end,
            .final_start = final_range.start,
            .final_end = final_range.end,
            .catch_start = none_range.start,
            .catch_end = none_range.end,
            .catch_name = .none,
        });
        try out.append(l.scratch, try l.add(.try_stmt, p, Node.Data.unused, @intFromEnum(record)));
        return switch (use) {
            .value => try l.ident(result, p),
            .discard, .tail => null,
        };
    }

    /// `Js.regExp pattern flags` (`backend.md` §4, *`Js.regExp` is a
    /// literal*): `/pattern/flags`, from two string literals. The pattern is
    /// written as it is, but for what a literal cannot hold — a `/` not
    /// already escaped is `\/`, a line terminator its escape, and an empty
    /// pattern `(?:)` (`//` would begin a comment) — none of which changes
    /// what it matches. The flags are any of `d i m s u v`, each once: `g`
    /// and `y` make a literal stateful (`lastIndex`), and a value written
    /// once and read by every caller must not be.
    fn regExpLiteral(l: *Lowerer, args: []const Inst.Index, p: u32) !Node.Index {
        if (args.len != 2 or l.bir.instTag(args[0]) != .string or l.bir.instTag(args[1]) != .string) {
            try l.report(.internal, if (args.len != 0) args[0] else @enumFromInt(0), "`Js.regExp` takes its pattern and its flags as string literals.", .{});
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        const pattern = l.bir.bytes(args[0]);
        const flags = l.bir.bytes(args[1]);
        for (flags, 0..) |f, i| {
            if (std.mem.indexOfScalar(u8, "dimsuv", f) == null or std.mem.indexOfScalar(u8, flags[0..i], f) != null) {
                try l.report(.internal, args[1], "`Js.regExp`'s flags are any of `d i m s u v`, each once: `{s}` is not.", .{flags});
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            }
        }
        var lit: std.ArrayList(u8) = .empty;
        try lit.append(l.scratch, '/');
        if (pattern.len == 0) try lit.appendSlice(l.scratch, "(?:)");
        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            const c = pattern[i];
            // An escape is copied whole, so the `/` or the backslash after a
            // backslash is never escaped twice; an escaped line terminator
            // is that terminator, written as its escape.
            if (c == '\\' and i + 1 < pattern.len) {
                const next = pattern[i + 1];
                if (next == '\n' or next == '\r') {
                    try lit.appendSlice(l.scratch, if (next == '\n') "\\n" else "\\r");
                } else {
                    try lit.appendSlice(l.scratch, pattern[i .. i + 2]);
                }
                i += 1;
                continue;
            }
            // A lone backslash at the end would escape the closing `/`.
            if (c == '\\') {
                try l.report(.internal, args[0], "`Js.regExp`'s pattern ends in a backslash that escapes nothing.", .{});
                return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            }
            switch (c) {
                '/' => try lit.appendSlice(l.scratch, "\\/"),
                '\n' => try lit.appendSlice(l.scratch, "\\n"),
                '\r' => try lit.appendSlice(l.scratch, "\\r"),
                else => if (c == 0xE2 and i + 2 < pattern.len and pattern[i + 1] == 0x80 and (pattern[i + 2] == 0xA8 or pattern[i + 2] == 0xA9)) {
                    try lit.appendSlice(l.scratch, if (pattern[i + 2] == 0xA8) "\\u2028" else "\\u2029");
                    i += 2;
                } else try lit.append(l.scratch, c),
            }
        }
        try lit.append(l.scratch, '/');
        try lit.appendSlice(l.scratch, flags);
        const offset, const len = try l.b.addString(lit.items);
        return l.add(.regex, p, offset, len);
    }

    /// The body of `Js.pure (\() -> body)` (`backend.md` §4, *`Js.pure` is
    /// its body*): `inst` a saturated call of `Js.pure` whose argument is a
    /// lambda written in place (`thunkBody`), or null. Wherever the call
    /// stands — a value, a tail, a discarded position — the body stands
    /// there instead, lowered as it would be.
    fn pureBody(l: *Lowerer, inst: Inst.Index) ?Inst.Index {
        if (l.bir.instTag(inst) != .call) return null;
        const d = l.bir.instData(inst);
        if ((l.jsIntrinsicOf(@enumFromInt(d.lhs)) orelse return null) != .pure) return null;
        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
        if (args.len != 1) return null;
        return l.thunkBody(args[0]);
    }

    /// The three arguments of `inst` when it is a saturated `Js.catchIf`.
    fn catchArgs(l: *Lowerer, inst: Inst.Index) ?[3]Inst.Index {
        if (l.bir.instTag(inst) != .call) return null;
        const d = l.bir.instData(inst);
        if ((l.jsIntrinsicOf(@enumFromInt(d.lhs)) orelse return null) != .catchIf) return null;
        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
        if (args.len != 3) return null;
        return .{ args[0], args[1], args[2] };
    }

    /// `f` when it is a lambda of one parameter that cannot suspend: a
    /// `Js.catchIf` test or handler written in place, its parameter the
    /// `catch` binding and its body in the `catch` block.
    fn caughtLambda(l: *Lowerer, f: Inst.Index) ?Inst.Index {
        if (l.bir.instTag(f) != .lambda or l.functionSuspends(f)) return null;
        const d = l.bir.instData(f);
        if (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.lhs)), Inst.Index).len != 1) return null;
        return f;
    }

    /// `Js.catchIf body test handler` (`backend.md` §4, *`Js.catchIf` is
    /// `try … catch`*): `try { body } catch (e) { if (!test) throw e;
    /// handler }`, the statement. What is thrown is caught only when `test`
    /// holds of it, and thrown on unchanged otherwise (`CLAUDE.md` rule 9).
    /// Written in place, as `finallyTry` writes `Js.finally`: a body lambda
    /// is its block (`thunkBody`), a test or handler lambda of one parameter
    /// is its body in the `catch` block with the parameter the `catch`
    /// binding (`caughtLambda`), and any other argument is evaluated first,
    /// in written order, and called there. `use` is `finallyTry`'s; the
    /// handler's value goes where the body's does.
    fn catchTry(l: *Lowerer, out: *StmtList, body_fn: Inst.Index, test_fn: Inst.Index, handler_fn: Inst.Index, use: FinallyUse, p: u32) !?Node.Index {
        const body = l.thunkBody(body_fn);
        const test_l = l.caughtLambda(test_fn);
        const handler_l = l.caughtLambda(handler_fn);
        var values: [3]Inst.Index = undefined;
        var n: usize = 0;
        if (body == null) {
            values[n] = body_fn;
            n += 1;
        }
        if (test_l == null) {
            values[n] = test_fn;
            n += 1;
        }
        if (handler_l == null) {
            values[n] = handler_fn;
            n += 1;
        }
        const v = try l.orderedExprs(out, values[0..n], false);
        for (v) |*value| value.* = try l.bindSubject(out, value.*, p);
        var next: usize = 0;
        const body_value: ?Node.Index = if (body == null) blk: {
            next += 1;
            break :blk v[next - 1];
        } else null;
        const test_value: ?Node.Index = if (test_l == null) blk: {
            next += 1;
            break :blk v[next - 1];
        } else null;
        const handler_value: ?Node.Index = if (handler_l == null) v[next] else null;

        // The `catch` binding: the name a lambda's parameter already has,
        // the test's first, so neither block renames what it reads.
        var caught: JsIr.NameIndex = .none;
        for ([_]?Inst.Index{ test_l, handler_l }) |maybe| {
            const f = maybe orelse continue;
            const param = l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(f).lhs)), Inst.Index)[0];
            if (l.bir.instTag(param) != .pat_var) continue;
            const local = l.bir.instData(param).lhs;
            if (caught == .none) {
                caught = try l.localName(local);
            } else if (local < l.local_names.len and l.local_names[local] == .none) {
                l.local_names[local] = caught;
            }
        }
        if (caught == .none) caught = try l.fresh(l.well.param);

        var guarded: StmtList = .empty;
        var result: JsIr.NameIndex = .none;
        if (use == .value) {
            result = try l.fresh(l.well.temp);
            try out.append(l.scratch, try l.add(.let_decl, p, @intFromEnum(result), @intFromEnum(Node.OptionalIndex.none)));
        }
        try l.catchArm(&guarded, if (body) |b| b else null, body_value, &.{}, use, result, p);

        var handler: StmtList = .empty;
        // A parameter that is a pattern binds from the caught value.
        for ([_]?Inst.Index{ test_l, handler_l }) |maybe| {
            const f = maybe orelse continue;
            const param = l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(f).lhs)), Inst.Index)[0];
            switch (l.bir.instTag(param)) {
                .pat_var => {
                    const named = try l.localName(l.bir.instData(param).lhs);
                    if (named != caught) try l.constDecl(&handler, named, try l.ident(caught, p), p);
                },
                .pat_wild, .pat_unit => {},
                else => try l.bindings(&handler, param, try l.ident(caught, p)),
            }
        }
        const holds = if (test_l) |f| try l.expr(&handler, @enumFromInt(l.bir.instData(f).rhs)) else try l.call(test_value.?, &.{try l.ident(caught, p)}, p);
        const rethrow = try l.add(.throw_stmt, p, (try l.ident(caught, p)).int(), Node.Data.unused);
        try l.ifStatement(&handler, try l.negate(holds, p), &.{rethrow}, p);
        const caught_arg = [_]Node.Index{try l.ident(caught, p)};
        try l.catchArm(&handler, if (handler_l) |f| @as(Inst.Index, @enumFromInt(l.bir.instData(f).rhs)) else null, handler_value, &caught_arg, use, result, p);

        const body_range = try l.b.addRange(guarded.items);
        const final_range = try l.b.addRange(&[_]Node.Index{});
        const catch_range = try l.b.addRange(handler.items);
        const record = try l.b.addRecord(JsIr.Try{
            .body_start = body_range.start,
            .body_end = body_range.end,
            .final_start = final_range.start,
            .final_end = final_range.end,
            .catch_start = catch_range.start,
            .catch_end = catch_range.end,
            .catch_name = caught,
        });
        try out.append(l.scratch, try l.add(.try_stmt, p, Node.Data.unused, @intFromEnum(record)));
        return switch (use) {
            .value => try l.ident(result, p),
            .discard, .tail => null,
        };
    }

    /// One arm of a `Js.catchIf`, the body or the handler, into `block`:
    /// the lambda's body `inline_body` lowered in place, or the function
    /// value `called` called with `args`, its value assigned to `result`,
    /// dropped, or returned, as `use` says.
    fn catchArm(l: *Lowerer, block: *StmtList, inline_body: ?Inst.Index, called: ?Node.Index, args: []const Node.Index, use: FinallyUse, result: JsIr.NameIndex, p: u32) !void {
        switch (use) {
            .value => {
                const value = if (inline_body) |b| try l.expr(block, b) else try l.call(called.?, args, p);
                // An arm that ends in `Js.throw` has no value to assign.
                const ended = block.items.len != 0 and l.b.nodes.items(.tag)[block.items[block.items.len - 1].int()] == .throw_stmt and
                    l.b.nodes.items(.tag)[value.int()] == .undefined_lit;
                if (!ended) try block.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(result, p)).int(), value.int()));
            },
            .discard => if (inline_body) |b|
                try l.discard(block, b, p)
            else
                try block.append(l.scratch, try l.add(.expr_stmt, p, (try l.call(called.?, args, p)).int(), Node.Data.unused)),
            .tail => if (inline_body) |b|
                try l.tailStmts(block, b, null)
            else
                try l.tailReturn(block, try l.call(called.?, args, p), null, p),
        }
    }

    fn forOf(l: *Lowerer, out: *StmtList, n: JsIr.NameIndex, iterable: Node.Index, body: []const Node.Index, p: u32) !Node.Index {
        const range = try l.b.addRange(body);
        const record = try l.b.addRecord(JsIr.ForOf{ .iterable = iterable, .body_start = range.start, .body_end = range.end });
        try out.append(l.scratch, try l.add(.for_of, p, @intFromEnum(n), @intFromEnum(record)));
        return l.nullNode(p);
    }

    fn jsIntrinsicCall(l: *Lowerer, out: *StmtList, which: JsIntrinsic.Which, args: []const Inst.Index, p: u32) !Node.Index {
        const W = JsIntrinsic.Which;
        // A `Js.Ref` written as a `let` (§4, *A `Js.Ref` that does not
        // escape is a `let`*): a read is its name, a write assigns it. The
        // name is not an atom, so whatever holds a read pins it before a
        // later write.
        if ((which == .read or which == .write) and args.len != 0 and l.unboxedRef(args[0])) {
            const target = try l.expr(out, args[0]);
            if (l.b.nodes.items(.tag)[target.int()] == .ident) {
                try l.markMutable(@enumFromInt(l.b.nodes.items(.data)[target.int()].lhs));
                if (which == .read) return target;
                const value = try l.expr(out, args[1]);
                try out.append(l.scratch, try l.add(.assign_stmt, p, target.int(), value.int()));
                return l.nullNode(p);
            }
            // `findRefs` said a `let`, and the name is not one.
            try l.report(.internal, args[0], "a `Js.Ref` written as a `let` was lowered as something other than its name.", .{});
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        }
        if (which == .each and args.len == 2) return l.eachLoop(out, args[0], args[1], p);
        if (which == .finally and args.len == 2) return (try l.finallyTry(out, args[0], args[1], .value, p)).?;
        if (which == .catchIf and args.len == 3) return (try l.catchTry(out, args[0], args[1], args[2], .value, p)).?;
        if (which == .regExp) return l.regExpLiteral(args, p);
        if (which == .pure and args.len == 1) if (l.thunkBody(args[0])) |body| return l.expr(out, body);
        // Where the property name is, and where the list literal is.
        const name_at: ?usize = switch (which) {
            .global => 0,
            .get, .set, .call => 1,
            else => null,
        };
        const list_at: ?usize = switch (which) {
            .call => 2,
            .apply, .construct => 1,
            .array => 0,
            else => null,
        };
        // The operands, flattened: a literal name contributes nothing, a
        // list literal its elements.
        var insts: std.ArrayList(Inst.Index) = .empty;
        var literal_name: ?[]const u8 = null;
        var list_start: usize = 0;
        var list_len: usize = 0;
        for (args, 0..) |arg, i| {
            if (name_at != null and name_at.? == i and l.bir.instTag(arg) == .string and isIdentifier(l.bir.bytes(arg))) {
                literal_name = l.bir.bytes(arg);
                continue;
            }
            if (list_at != null and list_at.? == i) {
                if (l.bir.instTag(arg) != .list) {
                    try l.report(.internal, arg, "`Js.{s}` takes its arguments as a list literal, `[ a, b ]`, which it spreads into the JavaScript call.", .{@tagName(which)});
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                }
                const elements = l.bir.extraSlice(Bir.inlineRange(l.bir.instData(arg)), Inst.Index);
                list_start = insts.items.len;
                list_len = elements.len;
                try insts.appendSlice(l.scratch, elements);
                continue;
            }
            try insts.append(l.scratch, arg);
        }
        const v = try l.orderedExprs(out, insts.items, false);
        const rest = v[list_start..][0..list_len];
        // The property read `name_at` names, on `target`: `v[k]` is the
        // name when it was not a literal.
        const Prop = struct {
            fn of(lw: *Lowerer, target: Node.Index, literal: ?[]const u8, computed: Node.Index, at: u32) !Node.Index {
                if (literal) |bytes| return lw.member(target, try lw.interner.getOrPut(lw.gpa, bytes), at);
                return lw.add(.index_get, at, target.int(), computed.int());
            }
        };
        const named = literal_name != null;
        return switch (which) {
            W.null => l.nullNode(p),
            W.undefined => l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
            W.from, W.to => v[0],
            W.same => l.binary(.strict_eq, v[0], v[1], p),
            W.isNull => l.binary(.strict_eq, v[0], try l.nullNode(p), p),
            W.isUndefined => l.binary(.strict_eq, v[0], try l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused), p),
            W.isNullish => l.binary(.loose_eq, v[0], try l.nullNode(p), p),
            W.bitAnd => l.binary(.bit_and, v[0], v[1], p),
            W.bitOr => l.binary(.bit_or, v[0], v[1], p),
            W.bitXor => l.binary(.bit_xor, v[0], v[1], p),
            W.shiftLeft => l.binary(.shl, v[0], v[1], p),
            W.shiftRight => l.binary(.sar, v[0], v[1], p),
            W.shiftRightZero => l.binary(.shr, v[0], v[1], p),
            W.rem => l.binary(.rem, v[0], v[1], p),
            W.typeOf => l.unary(.type_of, v[0], p),
            W.instanceOf => l.binary(.instance_of, v[0], v[1], p),
            W.global => blk: {
                const this = try l.add(.global_this, p, Node.Data.unused, Node.Data.unused);
                break :blk Prop.of(l, this, literal_name, if (named) this else v[0], p);
            },
            W.get => Prop.of(l, v[0], literal_name, if (named) v[0] else v[1], p),
            W.set => blk: {
                const target = try Prop.of(l, v[0], literal_name, if (named) v[0] else v[1], p);
                try out.append(l.scratch, try l.add(.assign_stmt, p, target.int(), v[v.len - 1].int()));
                break :blk l.nullNode(p);
            },
            W.call => l.call(try Prop.of(l, v[0], literal_name, if (named) v[0] else v[1], p), rest, p),
            W.apply => l.call(v[0], rest, p),
            // A saturated `each` is `eachLoop`, a saturated `finally`
            // `finallyTry`, a `catchIf` `catchTry` and a `regExp`
            // `regExpLiteral`, above.
            W.each, W.finally, W.catchIf, W.regExp => l.nullNode(p),
            // `Js.pure` with a function that is not a lambda written in
            // place calls it.
            W.pure => l.call(v[0], &.{}, p),
            W.construct => blk: {
                const range = try l.b.addRange(rest);
                const record = try l.b.addRecord(range);
                break :blk l.add(.new_call, p, v[0].int(), @intFromEnum(record));
            },
            W.at => l.add(.index_get, p, v[0].int(), v[1].int()),
            W.setAt => blk: {
                const target = try l.add(.index_get, p, v[0].int(), v[1].int());
                try out.append(l.scratch, try l.add(.assign_stmt, p, target.int(), v[2].int()));
                break :blk l.nullNode(p);
            },
            // A `Js.Ref` that escapes is a cell, `{ v }` (§4).
            W.ref => l.object(&.{try l.property(try l.interner.getOrPut(l.gpa, "v"), v[0], p)}, p),
            W.read => l.member(v[0], try l.interner.getOrPut(l.gpa, "v"), p),
            W.write => blk: {
                const target = try l.member(v[0], try l.interner.getOrPut(l.gpa, "v"), p);
                try out.append(l.scratch, try l.add(.assign_stmt, p, target.int(), v[1].int()));
                break :blk l.nullNode(p);
            },
            W.development => l.add(if (l.in.development) .true_lit else .false_lit, p, Node.Data.unused, Node.Data.unused),
            // Answered at the call, before it gets here (`callExpr`).
            W.maySuspend => l.add(.true_lit, p, Node.Data.unused, Node.Data.unused),
            W.throw => blk: {
                try out.append(l.scratch, try l.add(.throw_stmt, p, v[0].int(), Node.Data.unused));
                break :blk l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            },
            W.array => blk: {
                const range = try l.b.addRange(rest);
                break :blk l.add(.array, p, @intFromEnum(range.start), @intFromEnum(range.end));
            },
        };
    }

    /// The core function `inst` names that is written as an operator, or null
    /// (`Operator`).
    /// Whether `inst` is a `String` by its shape alone: a string literal, an
    /// interpolation, or a `++` of which an operand is one.
    fn stringy(l: *Lowerer, inst: Inst.Index, depth: u32) bool {
        if (depth > 16) return false;
        return switch (l.bir.instTag(inst)) {
            .string, .interp => true,
            .call => blk: {
                const d = l.bir.instData(inst);
                const callee: Inst.Index = @enumFromInt(d.lhs);
                if (!Operator.isBasicsAppend(l.in.graph, l.in.interfaces, l.bir, l.in.module, callee, l.interner)) break :blk false;
                const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
                if (args.len != 2) break :blk false;
                break :blk l.stringy(args[0], depth + 1) or l.stringy(args[1], depth + 1);
            },
            else => false,
        };
    }

    fn operatorOf(l: *Lowerer, inst: Inst.Index) ?Operator.Which {
        return Operator.of(l.in.graph, l.in.interfaces, l.bir, l.in.module, inst, l.interner);
    }

    /// A saturated call of an `Operator` as the JavaScript it computes. The
    /// operands are evaluated once each, in written order (`orderedExprs`),
    /// which is the order the call evaluated them in.
    fn operatorCall(l: *Lowerer, out: *StmtList, which: Operator.Which, args: []const Inst.Index, p: u32) !Node.Index {
        const v = try l.orderedExprs(out, args, false);
        const zero = struct {
            fn node(lw: *Lowerer, at: u32) !Node.Index {
                return lw.numberNode("0", at);
            }
        };
        return switch (which) {
            .add => l.binary(.add, v[0], v[1], p),
            .sub => l.binary(.sub, v[0], v[1], p),
            .mul => l.binary(.mul, v[0], v[1], p),
            .fdiv => l.binary(.div, v[0], v[1], p),
            .pow => l.binary(.pow, v[0], v[1], p),
            .lt => l.binary(.lt, v[0], v[1], p),
            .gt => l.binary(.gt, v[0], v[1], p),
            .le => l.binary(.le, v[0], v[1], p),
            .ge => l.binary(.ge, v[0], v[1], p),
            .not => l.unary(.not, v[0], p),
            // `callExpr` wrote these as a short circuit before asking.
            .@"and" => l.binary(.logical_and, v[0], v[1], p),
            .@"or" => l.binary(.logical_or, v[0], v[1], p),
            .negate => l.binary(.sub, try zero.node(l, p), v[0], p),
            .int32_fromInt => l.binary(.bit_or, v[0], try zero.node(l, p), p),
            .int32_toInt => v[0],
            .int32_toUnsignedInt => l.binary(.shr, v[0], try zero.node(l, p), p),
            .int32_add => l.binary(.bit_or, try l.binary(.add, v[0], v[1], p), try zero.node(l, p), p),
            .int32_sub => l.binary(.bit_or, try l.binary(.sub, v[0], v[1], p), try zero.node(l, p), p),
            .int32_and => l.binary(.bit_and, v[0], v[1], p),
            .int32_or => l.binary(.bit_or, v[0], v[1], p),
            .int32_xor => l.binary(.bit_xor, v[0], v[1], p),
            .int32_shiftLeft => l.binary(.shl, v[0], v[1], p),
            .int32_shiftRight => l.binary(.sar, v[0], v[1], p),
            .int32_shiftRightZero => l.binary(.bit_or, try l.binary(.shr, v[0], v[1], p), try zero.node(l, p), p),
            .list_at => l.add(.index_get, p, v[0].int(), v[1].int()),
            .list_identical => l.binary(.strict_eq, v[0], v[1], p),
            .list_kept => l.condOf(v[0], v[1], v[2], p),
            .list_half => l.binary(.shr, v[0], try l.numberNode("1", p), p),
            .list_length => l.member(v[0], try l.interner.getOrPut(l.gpa, "length"), p),
            // `b[i] = x;` where the call was, then `b`: the builder is read
            // twice, so a builder that is not a name is bound first, and
            // the store runs where the call ran, after its operands.
            .list_put => blk: {
                var builder = v[0];
                if (!l.isAtom(builder)) {
                    const n = try l.fresh(l.well.temp);
                    try l.constDecl(out, n, builder, p);
                    builder = try l.ident(n, p);
                }
                const slot = try l.add(.index_get, p, builder.int(), v[1].int());
                try out.append(l.scratch, try l.add(.assign_stmt, p, slot.int(), v[2].int()));
                break :blk builder;
            },
        };
    }

    fn isIdentifier(bytes: []const u8) bool {
        if (bytes.len == 0) return false;
        for (bytes, 0..) |c, i| {
            const ok = std.ascii.isAlphabetic(c) or c == '_' or c == '$' or (i != 0 and std.ascii.isDigit(c));
            if (!ok) return false;
        }
        return true;
    }

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
    /// pair becomes the `if` a short-circuit really is (`logicalRest`).
    ///
    /// **A written chain is one flat run** (`backend.md` §4, *Emitted
    /// JavaScript nests only as deep as the source*). beni's `&&` groups to
    /// the right, `a && (b && c)`, and printing it that way nested one level
    /// per term — past Chrome's parser at about a thousand. JavaScript's `&&`
    /// is associative in both value and evaluation (the first falsy operand,
    /// or the last; nothing after the first falsy one runs), so the right
    /// spine of one operator is collected here without recursing and built
    /// to the LEFT, `a && b && c`, which every engine parses as one run.
    fn logicalExpr(l: *Lowerer, out: *StmtList, op: JsIr.BinaryOp, left_inst: Inst.Index, right_inst: Inst.Index, p: u32) !Node.Index {
        // A right operand that may suspend is a branch like a `case`'s
        // (transparent-effects-proposal.md §16.3): `a && b` evaluates `a`,
        // then `b` or `false`, into a join.
        if (l.suspendable and l.yields(right_inst)) {
            const first = try l.expr(out, left_inst);
            return l.joinAround(out, left_inst, .{ .logical = .{ .op = op, .first = first, .right = right_inst } }, p);
        }
        var operands: std.ArrayList(Inst.Index) = .empty;
        var positions: std.ArrayList(u32) = .empty;
        try operands.append(l.scratch, left_inst);
        try positions.append(l.scratch, p);
        var rest = right_inst;
        while (l.sameLogical(rest, op)) |pair| {
            try operands.append(l.scratch, pair[0]);
            try positions.append(l.scratch, l.pos(rest));
            rest = pair[1];
        }
        try operands.append(l.scratch, rest);
        const first = try l.expr(out, operands.items[0]);
        return l.logicalRest(out, op, first, operands.items[1..], positions.items);
    }

    /// The operands after the first, joined to `acc` left to right. From the
    /// first one that needs statements on, the chain is a temporary and ONE
    /// flat `if` per such operand (`backend.md` §4):
    ///
    ///     let $t = a && b;
    ///     if ($t) { …c's statements; $t = c && d; }
    ///     if ($t) { …e's statements; $t = e; }
    ///
    /// (`if (!$t)` for `||`). Each `if` runs its operand's statements only
    /// when every operand before it said so, and the operands without
    /// statements that follow it ride in its assignment, still short
    /// circuited — the evaluation of `a && (b && (c && …))`, without one
    /// nested block per operand, which SpiderMonkey counts as a scope each.
    fn logicalRest(l: *Lowerer, out: *StmtList, op: JsIr.BinaryOp, first: Node.Index, operands: []const Inst.Index, positions: []const u32) Allocator.Error!Node.Index {
        var acc = first;
        var result: ?JsIr.NameIndex = null;
        // The statements of the operand that opened the current `if`, or
        // null while no operand has needed any.
        var pending: ?[]const Node.Index = null;
        var pending_p: u32 = 0;
        for (operands, positions[0..operands.len]) |operand, p| {
            var right_stmts: StmtList = .empty;
            const right = try l.expr(&right_stmts, operand);
            if (right_stmts.items.len == 0) {
                acc = try l.binary(op, acc, right, p);
                continue;
            }
            // Close what came before: the first time, bind it; after that,
            // the pending `if` assigns it.
            if (result) |n| {
                try l.guardedAssign(out, op, n, pending.?, acc, pending_p);
            } else {
                const n = try l.fresh(l.well.temp);
                try out.append(l.scratch, try l.add(.let_decl, p, @intFromEnum(n), @intFromEnum(acc.toOptional())));
                result = n;
            }
            pending = right_stmts.items;
            pending_p = p;
            acc = right;
        }
        const n = result orelse return acc;
        try l.guardedAssign(out, op, n, pending.?, acc, pending_p);
        return l.ident(n, pending_p);
    }

    /// `if ($t) { stmts; $t = value; }`, or `if (!$t)` for `||`.
    fn guardedAssign(l: *Lowerer, out: *StmtList, op: JsIr.BinaryOp, n: JsIr.NameIndex, stmts: []const Node.Index, value: Node.Index, p: u32) !void {
        var body: StmtList = .empty;
        try body.appendSlice(l.scratch, stmts);
        try body.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(n, p)).int(), value.int()));
        const current = try l.ident(n, p);
        const test_expr = if (op == .logical_and) current else try l.unary(.not, current, p);
        try l.ifStatement(out, test_expr, body.items, p);
    }

    /// The two operands of `inst` when it is a saturated call of the same
    /// short-circuit operator `op` — the next link of a written chain.
    fn sameLogical(l: *Lowerer, inst: Inst.Index, op: JsIr.BinaryOp) ?[2]Inst.Index {
        if (l.bir.instTag(inst) != .call) return null;
        const d = l.bir.instData(inst);
        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
        if (args.len != 2) return null;
        if (l.logicalOp(@enumFromInt(d.lhs)) != op) return null;
        if (l.rootsOf(inst).len != 0) return null;
        return .{ args[0], args[1] };
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
                    const named_before = payload.local < l.local_names.len and l.local_names[payload.local] != .none;
                    const n = try l.localName(payload.local);
                    const self: Loop.Self = .{ .local = payload.local };
                    // A function binding that generalised takes its evidence
                    // first, named `$l<inst>$<k>` (backend.md §4).
                    const evidence: u32 = if (l.in.dispatch.letIndex(def)) |i| l.in.dispatch.lets[i].requirements.len else 0;
                    const ev_let: Inst.OptionalIndex = if (evidence != 0) def.toOptional() else .none;
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
                                evidence,
                                ev_let,
                                lambda_params,
                                @enumFromInt(ld.rhs),
                                lambda_p,
                                l.functionSuspends(value_inst),
                            );
                            const lambda = try l.add(.arrow, lambda_p, @intFromEnum(lambda_record), Node.Data.unused);
                            if (l.in.unit_results and !l.functionSuspends(value_inst) and l.unitValued(@enumFromInt(ld.rhs))) try l.unobserved_arrows.append(l.scratch, lambda);
                            try l.constDecl(out, n, lambda, p);
                            continue;
                        }
                        // A `Js.Ref` that does not escape is a `let` of
                        // its value (§4).
                        const local = if (l.decl_index) |index| l.bir.decls[index].locals_start + payload.local else std.math.maxInt(u32);
                        if (local < l.unboxed_locals.len and l.unboxed_locals[local]) {
                            try l.markMutable(n);
                            const init_inst = l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(value_inst).rhs)), Inst.Index)[0];
                            const init = try l.expr(out, init_inst);
                            try out.append(l.scratch, try l.add(.let_decl, p, @intFromEnum(n), @intFromEnum(init.toOptional())));
                            if (l.mayHaveEffect(init_inst)) try l.effect_keep.append(l.scratch, out.items[out.items.len - 1]);
                            continue;
                        }
                        // A loop called once, its value bound here: the
                        // loop, whose exits write the name (§9).
                        // The binding a `case` leaf ends in a read of: an
                        // assignment of the `case`'s temporary (`bind_into`).
                        if (l.bind_into.local == payload.local and !named_before and payload.local < l.local_names.len) {
                            const into = l.bind_into.name;
                            l.bind_into = .{};
                            l.local_names[payload.local] = into;
                            if (l.bir.instTag(value_inst) == .case) l.case_into = .{ .name = into };
                            const value = try l.expr(out, value_inst);
                            l.case_into = .{};
                            if (!l.isIdentOf(value, into)) {
                                try out.append(l.scratch, try l.add(.assign_stmt, p, (try l.ident(into, p)).int(), value.int()));
                            }
                            continue;
                        }
                        if (try l.boundLoop(out, value_inst, .{ .assign = n }, if (named_before) &.{} else &.{payload.local})) continue;
                        // `--release`: a `case` whose value is bound writes
                        // the binding itself, declared a `let`, rather than
                        // a temporary the binding then copies.
                        if (l.in.unit_results and l.bir.instTag(value_inst) == .case) l.case_into = .{ .name = n, .declare = true };
                        const value = try l.expr(out, value_inst);
                        l.case_into = .{};
                        if (l.isIdentOf(value, n)) continue;
                        // `--release`: a binding of a name nothing
                        // reassigns — `y = Js.to x` — is that name, as a
                        // parameter passed one is (`enterInline`).
                        if (l.in.unit_results and !l.suspendable and l.b.nodes.items(.tag)[value.int()] == .ident and
                            !l.isMutable(value) and !named_before and payload.local < l.local_names.len)
                        {
                            l.local_names[payload.local] = @enumFromInt(l.b.nodes.items(.data)[value.int()].lhs);
                            continue;
                        }
                        try l.constDecl(out, n, value, p);
                        // Read by nothing or not, a binding that may have an
                        // effect is evaluated: the release optimiser keeps it.
                        if (l.mayHaveEffect(value_inst)) try l.effect_keep.append(l.scratch, out.items[out.items.len - 1]);
                        continue;
                    }
                    // A `let_def` with parameters is already its own hoisted
                    // `function` (§8's cases table), so the loop is
                    // contained; excluding it would leave the language's
                    // most natural loop idiom overflowing.
                    const record = try l.functionOrLoop(n, self, evidence, ev_let, params, @enumFromInt(d.rhs), p, l.functionSuspends(def));
                    const func = try l.add(.func_decl, p, @intFromEnum(n), @intFromEnum(record));
                    // A `function` whose result is `()` is listed like an
                    // arrow: the printer reads the list for both.
                    if (l.in.unit_results and !l.functionSuspends(def) and l.unitValued(@enumFromInt(d.rhs))) try l.unobserved_arrows.append(l.scratch, func);
                    try out.append(l.scratch, func);
                },
                .let_pattern => {
                    // `let _ = e` is `e` as a statement (§4, *A discarded
                    // value is a statement*).
                    if (l.bir.instTag(@enumFromInt(d.lhs)) == .pat_wild) {
                        try l.discard(out, @enumFromInt(d.rhs), p);
                        continue;
                    }
                    // `( a, b ) = <a loop called once>`: the loop, whose
                    // exits write each element into its name (§9).
                    if (l.bir.instTag(@enumFromInt(d.lhs)) == .pat_tuple) {
                        // Which names are new, asked before they are made.
                        const locals = try l.tupleLocals(@enumFromInt(d.lhs));
                        if (try l.tupleNames(@enumFromInt(d.lhs))) |names| {
                            if (try l.boundLoop(out, @enumFromInt(d.rhs), .{ .tuple = names }, locals)) continue;
                        }
                    }
                    const value = try l.expr(out, @enumFromInt(d.rhs));
                    const before = out.items.len;
                    const subject = try l.bindSubject(out, value, p);
                    // `let _ = <an impure call>` is written for its effect, and a
                    // pattern whose names nothing reads evaluates its right-hand
                    // side all the same: the release optimiser keeps the subject
                    // (transparent-effects-proposal.md §16.5).
                    if (out.items.len == before + 1 and l.mayHaveEffect(@enumFromInt(d.rhs))) {
                        try l.effect_keep.append(l.scratch, out.items[before]);
                    }
                    try l.bindings(out, @enumFromInt(d.lhs), subject);
                },
                else => {},
            }
        }
    }

    /// Which declarations' results nothing can read (`backend.md` §4, *A
    /// result nothing reads*): a function of this module that is not `pub`,
    /// so no other module names it, that no dispatch answer names — a
    /// private `eq` is still the method `==` calls inside its module — that
    /// has no second body and takes no evidence, and whose every reference
    /// is the callee of a
    /// call in DISCARDED position: the right-hand side of a `let _ =`, a
    /// branch of a `case` or the body of a `let` in one — or in TAIL
    /// position of a declaration whose own result nothing reads, since what
    /// it returns goes where that result goes. A reference anywhere else, a
    /// value passed or returned, counts as a read. The second rule is a
    /// greatest fixpoint: every candidate starts unread, and one read
    /// anywhere takes it out, and with it what its tail positions call.
    fn findUnobserved(l: *Lowerer) !void {
        const decls = l.bir.decls;
        l.unobserved = try l.scratch.alloc(bool, decls.len);
        const all = try l.scratch.alloc(u32, decls.len);
        const discarded = try l.scratch.alloc(u32, decls.len);
        @memset(all, 0);
        @memset(discarded, 0);
        const tags = l.bir.insts.items(.tag);
        const data = l.bir.insts.items(.data);
        var stack: std.ArrayList(Inst.Index) = .empty;
        for (tags, data) |tag, d| switch (tag) {
            .top => if (d.lhs < decls.len) {
                all[d.lhs] += 1;
            },
            .let_pattern => if (l.bir.instTag(@enumFromInt(d.lhs)) == .pat_wild) try stack.append(l.scratch, @enumFromInt(d.rhs)),
            else => {},
        };
        while (stack.pop()) |inst| {
            if (l.tailCallee(inst)) |callee| {
                discarded[callee] += 1;
                continue;
            }
            try l.pushTails(&stack, inst);
        }
        // The calls each declaration makes in its own tail positions.
        const Tail = struct { from: u32, to: u32 };
        var tails: std.ArrayList(Tail) = .empty;
        for (decls, 0..) |d, i| {
            if (d.kind != .value) continue;
            const body = d.body.unwrap() orelse continue;
            const start: Inst.Index = switch (Convention.definitionOf(l.in.dispatch, l.bir, @intCast(i))) {
                .params => body,
                .lambda => @enumFromInt(l.bir.instData(body).rhs),
                else => continue,
            };
            try stack.append(l.scratch, start);
            while (stack.pop()) |inst| {
                if (l.tailCallee(inst)) |callee| {
                    try tails.append(l.scratch, .{ .from = @intCast(i), .to = callee });
                    continue;
                }
                try l.pushTails(&stack, inst);
            }
        }
        const dispatched = try l.scratch.alloc(bool, decls.len);
        @memset(dispatched, false);
        for (l.in.dispatch.terms) |t| switch (t) {
            .top => |u| if (@intFromEnum(u.decl) < decls.len) {
                dispatched[@intFromEnum(u.decl)] = true;
            },
            else => {},
        };
        // What the module exports — its interface, and the entry point the
        // build calls — is read by somebody this module cannot see.
        for (l.bir.interface) |decl_index| {
            if (decl_index.int() < decls.len) dispatched[decl_index.int()] = true;
        }
        if (l.in.entry_decl) |index| if (index < decls.len) {
            dispatched[index] = true;
        };
        for (decls, 0..) |d, i| {
            const index: u32 = @intCast(i);
            l.unobserved[i] = d.kind == .value and !d.is_pub and !dispatched[i] and
                !l.in.dispatch.effectDecl(index).twin and l.in.dispatch.effectDecl(index).own == .no and
                Convention.ofDecl(l.in.dispatch, l.bir, index).evidence == 0 and
                switch (Convention.definitionOf(l.in.dispatch, l.bir, index)) {
                    .params, .lambda => true,
                    else => false,
                };
        }
        const reached = try l.scratch.alloc(u32, decls.len);
        var changed = true;
        while (changed) {
            changed = false;
            @memcpy(reached, discarded);
            for (tails.items) |t| {
                if (l.unobserved[t.from]) reached[t.to] += 1;
            }
            for (l.unobserved, reached, all) |*u, r, a| {
                if (u.* and r != a) {
                    u.* = false;
                    changed = true;
                }
            }
        }
    }

    /// Which `Js.Ref` bindings are written as a plain `let` (`backend.md`
    /// §4, *A `Js.Ref` that does not escape is a `let`*). A candidate is a
    /// `let` binding without parameters, or a top-level constant, whose
    /// right-hand side is a saturated `Js.ref e`. It stays one when every
    /// reference to it is the first argument of a saturated `Js.read` or
    /// `Js.write` — its cell position — and anything else, a value passed,
    /// stored, returned or compared, is an escape. A reference inside a
    /// closure is not one: the closure captures the `let` itself. A
    /// top-level candidate must also be one no other module can name (not
    /// `pub`, not the entry, no dispatch answer's). A suspension needs no
    /// rule: its continuation is a closure too (§16.3), and a re-entered
    /// loop is a new iteration, which evaluates its `Js.ref` again.
    fn findRefs(l: *Lowerer) !void {
        const tags = l.bir.insts.items(.tag);
        const data = l.bir.insts.items(.data);
        const decls = l.bir.decls;
        l.unboxed_locals = try l.scratch.alloc(bool, l.bir.locals.len);
        @memset(l.unboxed_locals, false);
        l.unboxed_tops = try l.scratch.alloc(bool, decls.len);
        @memset(l.unboxed_tops, false);
        // The cell positions, and whether the module makes a ref at all.
        var any = false;
        const cell = try l.scratch.alloc(bool, tags.len);
        @memset(cell, false);
        for (tags, data) |tag, d| {
            if (tag != .call) continue;
            const which = l.jsIntrinsicOf(@enumFromInt(d.lhs)) orelse continue;
            const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
            switch (which) {
                .read, .write => if (args.len != 0 and args[0].int() < cell.len) {
                    cell[args[0].int()] = true;
                },
                .ref => any = true,
                else => {},
            }
        }
        if (!any) return;
        const named = try l.scratch.alloc(bool, decls.len);
        @memset(named, false);
        for (l.in.dispatch.terms) |t| switch (t) {
            .top => |u| if (@intFromEnum(u.decl) < decls.len) {
                named[@intFromEnum(u.decl)] = true;
            },
            else => {},
        };
        if (l.in.entry_decl) |index| if (index < decls.len) {
            named[index] = true;
        };
        for (decls, 0..) |d, i| {
            const index: u32 = @intCast(i);
            if (d.kind != .value) continue;
            if (d.body.unwrap()) |body| {
                if (!d.is_pub and !named[i] and l.isRefCall(body) and
                    Convention.definitionOf(l.in.dispatch, l.bir, index) == .constant)
                {
                    l.unboxed_tops[i] = true;
                }
            }
            var at = d.inst_start.int();
            while (at < d.inst_end.int()) : (at += 1) {
                if (tags[at] != .let_def) continue;
                const payload = l.bir.extraData(@enumFromInt(data[at].lhs), Bir.LetDef);
                if (payload.params_start != payload.params_end) continue;
                if (!l.isRefCall(@enumFromInt(data[at].rhs))) continue;
                const local = d.locals_start + payload.local;
                if (local < l.unboxed_locals.len) l.unboxed_locals[local] = true;
            }
        }
        // The escapes.
        for (decls) |d| {
            var at = d.inst_start.int();
            while (at < d.inst_end.int()) : (at += 1) {
                if (cell[at]) continue;
                switch (tags[at]) {
                    .local => {
                        const local = d.locals_start + data[at].lhs;
                        if (local < l.unboxed_locals.len) l.unboxed_locals[local] = false;
                    },
                    .top => if (data[at].lhs < decls.len) {
                        l.unboxed_tops[data[at].lhs] = false;
                    },
                    else => {},
                }
            }
        }
    }

    /// Which declarations are written where their one call is, under
    /// `--release` (`backend.md` §9, *A function called once is written where
    /// it is called*): a live function of this module, not `pub`, not the
    /// entry, named by no dispatch answer, with no evidence, no second body
    /// and nothing in it that may suspend, whose every reference in the
    /// module — and nothing outside the module can name it — is ONE call,
    /// saturated, with no evidence, that cannot suspend, in another
    /// declaration that has no second body.
    fn findInlines(l: *Lowerer) !void {
        const decls = l.bir.decls;
        l.inline_candidate = try l.scratch.alloc(bool, decls.len);
        @memset(l.inline_candidate, false);
        l.inlined = try l.scratch.alloc(bool, decls.len);
        @memset(l.inlined, false);
        if (!l.in.inline_once) return;
        const tags = l.bir.insts.items(.tag);
        const data = l.bir.insts.items(.data);
        // The call each callee instruction is the callee of.
        const call_of = try l.scratch.alloc(Inst.OptionalIndex, tags.len);
        @memset(call_of, .none);
        for (tags, data, 0..) |tag, d, i| {
            if (tag == .call and d.lhs < call_of.len) call_of[d.lhs] = @as(Inst.Index, @enumFromInt(i)).toOptional();
        }
        const named = try l.scratch.alloc(bool, decls.len);
        @memset(named, false);
        for (l.in.dispatch.terms) |t| switch (t) {
            .top => |u| if (@intFromEnum(u.decl) < decls.len) {
                named[@intFromEnum(u.decl)] = true;
            },
            else => {},
        };
        if (l.in.entry_decl) |index| if (index < decls.len) {
            named[index] = true;
        };
        const uses = try l.scratch.alloc(u32, decls.len);
        @memset(uses, 0);
        const self_uses = try l.scratch.alloc(u32, decls.len);
        @memset(self_uses, 0);
        const good = try l.scratch.alloc(bool, decls.len);
        @memset(good, false);
        l.inline_loops = try l.scratch.alloc(bool, decls.len);
        @memset(l.inline_loops, false);
        for (decls, 0..) |caller, c| {
            const caller_twin = l.in.dispatch.effectDecl(@intCast(c)).twin;
            var at = caller.inst_start.int();
            while (at < caller.inst_end.int()) : (at += 1) {
                if (tags[at] != .top or data[at].lhs >= decls.len) continue;
                const callee = data[at].lhs;
                // A reference of a function to itself: every one must be a
                // tail self-call, which the loop it is written as takes.
                if (callee == c) {
                    self_uses[callee] += 1;
                    continue;
                }
                uses[callee] += 1;
                const site = call_of[at].unwrap() orelse continue;
                if (caller_twin) continue;
                const args = l.bir.subRange(@enumFromInt(l.bir.instData(site).rhs)).len();
                if (args != l.paramsOf(callee).len) continue;
                if (l.rootsOf(site).len != 0) continue;
                if (l.in.dispatch.effectAt(site).own != .no) continue;
                good[callee] = true;
            }
        }
        for (decls, 0..) |d, i| {
            const index: u32 = @intCast(i);
            if (d.kind != .value or d.is_pub or named[i] or uses[i] != 1 or !good[i]) continue;
            if (!l.liveDecl(index)) continue;
            const ed = l.in.dispatch.effectDecl(index);
            if (ed.twin or ed.own != .no) continue;
            if (Convention.ofDecl(l.in.dispatch, l.bir, index).evidence != 0) continue;
            switch (Convention.definitionOf(l.in.dispatch, l.bir, index)) {
                .params, .lambda => {},
                else => continue,
            }
            const suspends = for (l.in.dispatch.effectsIn(d.inst_start.int(), d.inst_end.int())) |site| {
                if (site.own != .no or site.body != .no) break true;
            } else false;
            if (suspends) continue;
            // A `?` that returns from the declaration returns from wherever
            // its body is written, which is the caller.
            // Markup would be lowered twice (`declarations`), its templates
            // hoisted twice.
            const returns = for (tags[d.inst_start.int()..d.inst_end.int()], data[d.inst_start.int()..d.inst_end.int()]) |tag, x| {
                if (tag == .@"try" and @as(Inst.OptionalIndex, @enumFromInt(x.rhs)) == .none) break true;
                if (tag == .markup) break true;
            } else false;
            if (returns) continue;
            if (self_uses[i] != 0) {
                if (self_uses[i] != l.tailSelfCalls(index, l.bodyOf(index))) continue;
                l.inline_loops[i] = true;
            }
            l.inline_candidate[i] = true;
        }
    }

    /// How many calls of declaration `index` stand in the tail positions of
    /// `inst` (§8: a `let`'s body, a `case`'s branches).
    fn tailSelfCalls(l: *Lowerer, index: u32, inst: Inst.Index) u32 {
        const d = l.bir.instData(inst);
        switch (l.bir.instTag(inst)) {
            .let => return l.tailSelfCalls(index, @enumFromInt(d.rhs)),
            .case => {
                var n: u32 = 0;
                for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index)) |branch| {
                    if (l.bir.instTag(branch) != .branch) continue;
                    n += l.tailSelfCalls(index, @enumFromInt(l.bir.instData(branch).rhs));
                }
                return n;
            },
            .call => {
                const callee: Inst.Index = @enumFromInt(d.lhs);
                return @intFromBool(l.bir.instTag(callee) == .top and l.bir.instData(callee).lhs == index);
            },
            else => return 0,
        }
    }

    /// The parameter patterns and the body of a declaration defined with
    /// parameters or as a lambda (`Convention.definitionOf`), or none.
    fn paramsOf(l: *Lowerer, index: u32) []const Inst.Index {
        const d = l.bir.decls[index];
        return switch (Convention.definitionOf(l.in.dispatch, l.bir, index)) {
            .params => l.bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Inst.Index),
            .lambda => l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(d.body.unwrap().?).lhs)), Inst.Index),
            else => &.{},
        };
    }

    /// Whether every argument of call `site` is an atom of `Bir`: a name
    /// of a local or a declaration, or a literal — nothing a body written
    /// in place would have to bind first.
    fn atomArguments(l: *Lowerer, site: Inst.Index) bool {
        for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(site).rhs)), Inst.Index)) |arg| {
            switch (l.bir.instTag(arg)) {
                .local, .int, .float, .string, .char, .unit => {},
                else => return false,
            }
        }
        return true;
    }

    /// Whether declaration `index`'s body is neither a `let` nor a `case`
    /// (an `if` is one): what may be written in place of a call in
    /// expression position.
    fn isExpressionBody(l: *Lowerer, index: u32) bool {
        return switch (l.bir.instTag(l.bodyOf(index))) {
            .let, .case => false,
            else => true,
        };
    }

    fn bodyOf(l: *Lowerer, index: u32) Inst.Index {
        const d = l.bir.decls[index];
        const body = d.body.unwrap().?;
        return switch (Convention.definitionOf(l.in.dispatch, l.bir, index)) {
            .lambda => @enumFromInt(l.bir.instData(body).rhs),
            else => body,
        };
    }

    /// The declaration `site` calls, when it is to be written in place
    /// here: a candidate (`findInlines`) not already being written.
    fn inlineTarget(l: *Lowerer, site: Inst.Index) ?u32 {
        if (l.inline_candidate.len == 0) return null;
        const callee: Inst.Index = @enumFromInt(l.bir.instData(site).lhs);
        if (l.bir.instTag(callee) != .top) return null;
        const index = l.bir.instData(callee).lhs;
        if (index >= l.inline_candidate.len or !l.inline_candidate[index]) return null;
        if (std.mem.indexOfScalar(u32, l.inline_stack.items, index) != null) return null;
        if (l.decl_index == null or l.function_depth == 0) return null;
        return index;
    }

    /// What a body written in place saves of the declaration around it.
    const InlineSaved = struct {
        locals: []const Bir.Local,
        local_names: []JsIr.NameIndex,
        decl_index: ?u32,
        tag_base: u32,
    };

    /// Evaluate call `site`'s arguments in order, as the call would, bind them to
    /// declaration `index`'s parameters, and enter its body's context: its
    /// locals, named past every local named so far in this function.
    fn enterInline(l: *Lowerer, out: *StmtList, site: Inst.Index, index: u32) !InlineSaved {
        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(site).rhs)), Inst.Index);
        // Each argument lowered and bound before the next is lowered: the
        // order the call evaluated them in, with nothing left to pin.
        const values = try l.scratch.alloc(Node.Index, args.len);
        for (args, values) |arg, *value| {
            value.* = try l.expr(out, arg);
            if (l.isAtom(value.*)) continue;
            const n = try l.fresh(l.well.temp);
            try l.constDecl(out, n, value.*, l.pos(arg));
            // Read by nothing or not, an argument that may have an effect is
            // evaluated: the release optimiser keeps it.
            if (l.mayHaveEffect(arg)) try l.effect_keep.append(l.scratch, out.items[out.items.len - 1]);
            value.* = try l.ident(n, l.pos(arg));
        }
        const saved: InlineSaved = .{
            .locals = l.locals,
            .local_names = l.local_names,
            .decl_index = l.decl_index,
            .tag_base = l.local_tag_base,
        };
        const d = l.bir.decls[index];
        l.locals = l.bir.declLocals(d);
        l.local_names = try l.scratch.alloc(JsIr.NameIndex, l.locals.len);
        @memset(l.local_names, .none);
        l.decl_index = index;
        l.local_tag_base = l.local_tag_next;
        l.local_tag_next += @intCast(l.locals.len);
        try l.inline_stack.append(l.scratch, index);
        l.inlined[index] = true;
        const p = l.pos(site);
        for (l.paramsOf(index), values) |param, value| {
            switch (l.bir.instTag(param)) {
                // Every argument is an atom now: a name — an immutable one,
                // a temporary or the caller's own — is the parameter, and a
                // literal is bound once, here.
                .pat_var => {
                    const local = l.bir.instData(param).lhs;
                    const tags = l.b.nodes.items(.tag);
                    if (tags[value.int()] == .ident and local < l.local_names.len) {
                        l.local_names[local] = @enumFromInt(l.b.nodes.items(.data)[value.int()].lhs);
                    } else try l.constDecl(out, try l.localName(local), value, p);
                },
                .pat_wild, .pat_unit => {},
                else => try l.bindings(out, param, value),
            }
        }
        return saved;
    }

    fn leaveInline(l: *Lowerer, saved: InlineSaved) void {
        l.locals = saved.locals;
        l.local_names = saved.local_names;
        l.decl_index = saved.decl_index;
        l.local_tag_base = saved.tag_base;
        _ = l.inline_stack.pop();
    }

    /// A call of a function written in place, in expression position: its
    /// body's value.
    fn inlineExpr(l: *Lowerer, out: *StmtList, site: Inst.Index, index: u32) Allocator.Error!Node.Index {
        const saved = try l.enterInline(out, site, index);
        defer l.leaveInline(saved);
        return l.expr(out, l.bodyOf(index));
    }

    /// A call, in tail position of a function that is no loop, of a
    /// function written in place that is one: its arguments bound to `let`s
    /// the loop reassigns, then the loop, whose exits return for the caller
    /// (§8's shape, `loopOf`). False, with nothing written, when it is not a
    /// loop this can write — one that builds a list — or the caller may
    /// suspend.
    /// The loop a looping candidate is written as at call `site`, before
    /// anything is lowered, or null when it is not one `inlineLoop` writes:
    /// the caller may suspend, the loop builds a list, or a variable the loop
    /// reassigns would first be given a name the caller already has — a copy
    /// of it, where the call is the shorter form.
    fn inlineLoopPlan(l: *Lowerer, site: Inst.Index, index: u32, exit: Loop.Exit) Allocator.Error!?Loop {
        if (l.suspendable) return null;
        const params = l.paramsOf(index);
        const slots = try l.scratch.alloc(Loop.Slot, params.len);
        const written = l.writtenParams(params);
        for (params, slots, 0..) |param, *slot, i| {
            slot.* = .{ .pattern = param.toOptional(), .unwritten = i >= written };
            if (l.bir.instTag(param) == .pat_var) slot.local = l.bir.instData(param).lhs else slot.carried = true;
        }
        const jumps = try l.scratch.create(Loop.Jumps);
        jumps.* = .{};
        var loop: Loop = .{ .label = .none, .self = .{ .top = index }, .evidence = 0, .slots = slots, .jumps = jumps, .exit = exit };
        if (!l.markTails(l.bodyOf(index), &loop) or loop.builds) return null;
        // Where the value is bound or discarded, the call is no shorter
        // than the copies: the loop is taken in whatever its arguments are.
        if (exit != .@"return") return loop;
        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(site).rhs)), Inst.Index);
        for (slots, args) |slot, arg| {
            if (!slot.carried or slot.unwritten) continue;
            switch (l.bir.instTag(arg)) {
                .local, .top => return null,
                else => {},
            }
        }
        return loop;
    }

    /// The candidate a call in tail position is written in place of, or
    /// null: `tailStmts` and `condChainPossible` ask the one question. A
    /// body written in place binds each argument that is not an atom, which
    /// costs what the call saved, so only a call of atoms is taken in —
    /// except a loop's, whose arguments are its variables' first values,
    /// bound either way, and only in a function that is no loop itself.
    fn tailInline(l: *Lowerer, site: Inst.Index, loop: ?*const Loop) Allocator.Error!?u32 {
        const index = l.inlineTarget(site) orelse return null;
        if (!l.inline_loops[index]) return if (l.atomArguments(site)) index else null;
        if (loop != null) return null;
        return if (try l.inlineLoopPlan(site, index, .@"return") != null) index else null;
    }

    /// A call of a loop written in place (`findInlines`) whose value is
    /// bound to a name, bound by a tuple pattern of names, or discarded:
    /// the loop, its exits writing the binding and leaving by `break`, and
    /// the rest of the caller after it. False, with nothing written, when
    /// `site` is no such call or the loop is not one this writes.
    fn boundLoop(l: *Lowerer, out: *StmtList, site: Inst.Index, exit: Loop.Exit, locals: []const u32) Allocator.Error!bool {
        if (l.bir.instTag(site) != .call) return false;
        const index = l.inlineTarget(site) orelse return false;
        if (!l.inline_loops[index]) return false;
        switch (exit) {
            .@"return" => return false,
            .discard, .assign => {},
            // Every exit a tuple literal of the pattern's size, or no tuple
            // is saved.
            .tuple => |names| if (!l.tuplesAtExits(l.bodyOf(index), index, names.len)) return false,
        }
        return l.inlineLoop(out, site, index, exit, locals);
    }

    /// The names a tuple pattern of names binds, `.none` for each `_`, or
    /// null for any other pattern.
    fn tupleNames(l: *Lowerer, pattern: Inst.Index) Allocator.Error!?[]const JsIr.NameIndex {
        if (l.bir.instTag(pattern) != .pat_tuple) return null;
        const elements = l.bir.extraSlice(Bir.inlineRange(l.bir.instData(pattern)), Inst.Index);
        const names = try l.scratch.alloc(JsIr.NameIndex, elements.len);
        for (elements, names) |element, *n| n.* = switch (l.bir.instTag(element)) {
            .pat_var => try l.localName(l.bir.instData(element).lhs),
            .pat_wild => .none,
            else => return null,
        };
        return names;
    }

    /// The locals a tuple pattern of names binds, `Loop.no_local` for each
    /// `_` and for a local something lowered earlier already named — a
    /// `let` function may read a binding written after it — so that
    /// `inlineLoop` gives a new name only to a local nothing has read
    /// (`tupleNames`' order).
    fn tupleLocals(l: *Lowerer, pattern: Inst.Index) Allocator.Error![]const u32 {
        const elements = l.bir.extraSlice(Bir.inlineRange(l.bir.instData(pattern)), Inst.Index);
        const locals = try l.scratch.alloc(u32, elements.len);
        for (elements, locals) |element, *local| {
            local.* = Loop.no_local;
            if (l.bir.instTag(element) != .pat_var) continue;
            const index = l.bir.instData(element).lhs;
            if (index < l.local_names.len and l.local_names[index] == .none) local.* = index;
        }
        return locals;
    }

    /// Whether every tail position of `inst` that is not declaration
    /// `index`'s own tail call is a tuple literal of `arity` elements.
    fn tuplesAtExits(l: *Lowerer, inst: Inst.Index, index: u32, arity: usize) bool {
        const d = l.bir.instData(inst);
        switch (l.bir.instTag(inst)) {
            .let => return l.tuplesAtExits(@enumFromInt(d.rhs), index, arity),
            .case => {
                for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index)) |branch| {
                    if (l.bir.instTag(branch) != .branch) continue;
                    if (!l.tuplesAtExits(@enumFromInt(l.bir.instData(branch).rhs), index, arity)) return false;
                }
                return true;
            },
            .call => {
                const callee: Inst.Index = @enumFromInt(d.lhs);
                return l.bir.instTag(callee) == .top and l.bir.instData(callee).lhs == index;
            },
            .tuple => return Bir.inlineRange(d).len() == arity,
            else => return false,
        }
    }

    fn inlineLoop(l: *Lowerer, out: *StmtList, site: Inst.Index, index: u32, exit: Loop.Exit, locals: []const u32) Allocator.Error!bool {
        var loop = try l.inlineLoopPlan(site, index, exit) orelse return false;
        const slots = loop.slots;
        const params = l.paramsOf(index);
        const body = l.bodyOf(index);
        const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(site).rhs)), Inst.Index);
        loop.ready = l.mayGoInPlace(params, body);
        loop.label = try l.topName(index);
        // As `enterInline`: each argument lowered, and bound when it is not
        // an atom, before the next — kept when it may have an effect.
        const values = try l.scratch.alloc(Node.Index, args.len);
        // The `const` each argument that is not an atom was bound by, which
        // becomes its slot's own binding below.
        const bound = try l.scratch.alloc(?Node.Index, args.len);
        for (args, values, bound) |arg, *value, *stmt| {
            stmt.* = null;
            value.* = try l.expr(out, arg);
            if (l.isAtom(value.*)) continue;
            const n = try l.fresh(l.well.temp);
            try l.constDecl(out, n, value.*, l.pos(arg));
            stmt.* = out.items[out.items.len - 1];
            if (l.mayHaveEffect(arg)) try l.effect_keep.append(l.scratch, stmt.*.?);
            value.* = try l.ident(n, l.pos(arg));
        }
        const saved: InlineSaved = .{
            .locals = l.locals,
            .local_names = l.local_names,
            .decl_index = l.decl_index,
            .tag_base = l.local_tag_base,
        };
        const d = l.bir.decls[index];
        l.locals = l.bir.declLocals(d);
        l.local_names = try l.scratch.alloc(JsIr.NameIndex, l.locals.len);
        @memset(l.local_names, .none);
        l.decl_index = index;
        l.local_tag_base = l.local_tag_next;
        l.local_tag_next += @intCast(l.locals.len);
        try l.inline_stack.append(l.scratch, index);
        l.inlined[index] = true;
        defer l.leaveInline(saved);
        const p = l.pos(site);
        // A parameter no jump reassigns, passed a name of the caller that is
        // immutable, is that name, as `enterInline` makes it.
        const aliased = try l.scratch.alloc(bool, slots.len);
        for (slots, values, bound, aliased) |slot, value, stmt, *alias| {
            alias.* = stmt == null and !slot.carried and !slot.unwritten and slot.local != Loop.no_local and slot.local < l.local_names.len and
                l.b.nodes.items(.tag)[value.int()] == .ident and !l.isMutable(value);
            if (alias.*) l.local_names[slot.local] = @enumFromInt(l.b.nodes.items(.data)[value.int()].lhs);
        }
        const built = try l.loopOf(&loop, body, p);
        var k: usize = 0;
        for (slots, values, bound, aliased) |slot, value, stmt, alias| {
            if (slot.unwritten) continue;
            defer k += 1;
            if (alias) continue;
            // The argument's own binding becomes the slot's: a `const`, or
            // the `let` a jump reassigns.
            if (stmt) |node| {
                l.b.nodes.items(.data)[node.int()].lhs = @intFromEnum(built.names[k]);
                if (slot.carried) l.b.nodes.items(.tag)[node.int()] = .let_decl;
                continue;
            }
            if (!slot.carried) {
                try l.constDecl(out, built.names[k], value, p);
                continue;
            }
            try out.append(l.scratch, try l.add(.let_decl, p, @intFromEnum(built.names[k]), @intFromEnum(value.toOptional())));
        }
        // The names the exits write, declared before the loop — but for a
        // name every exit gives the value of one loop variable, which IS
        // that variable from here on: its exits' writes are dropped.
        const names: []const JsIr.NameIndex = switch (exit) {
            .@"return", .discard => &.{},
            .assign => |n| &.{n},
            .tuple => |ns| ns,
        };
        const none = @intFromEnum(Node.OptionalIndex.none);
        for (names, 0..) |n, i| {
            if (n == .none) continue;
            if (i < locals.len) if (l.exitVariable(&loop, built.names, n)) |variable| {
                if (locals[i] < saved.local_names.len) {
                    saved.local_names[locals[i]] = variable;
                    // Each exit's write becomes `variable = variable`,
                    // which a release build prints as nothing (`Print`'s
                    // `skipped`) wherever the statement ends up.
                    const datas = l.b.nodes.items(.data);
                    for (loop.jumps.exits.items) |stmt| {
                        const target = datas[stmt.int()].lhs;
                        if (datas[target].lhs == @intFromEnum(n)) datas[target].lhs = @intFromEnum(variable);
                    }
                    continue;
                }
            };
            try out.append(l.scratch, try l.add(.let_decl, p, @intFromEnum(n), none));
        }
        try out.appendSlice(l.scratch, built.stmts);
        return true;
    }

    /// The loop variable every exit of `loop` writes into `n`, when there is
    /// one: a slot the loop reassigns in place (`loopOf`'s `names` are then
    /// the slots' own), the same at every exit.
    fn exitVariable(l: *Lowerer, loop: *const Loop, names: []const JsIr.NameIndex, n: JsIr.NameIndex) ?JsIr.NameIndex {
        const tags = l.b.nodes.items(.tag);
        const datas = l.b.nodes.items(.data);
        var found: ?JsIr.NameIndex = null;
        for (loop.jumps.exits.items) |stmt| {
            const target = datas[stmt.int()].lhs;
            if (datas[target].lhs != @intFromEnum(n)) continue;
            const value = datas[stmt.int()].rhs;
            if (tags[value] != .ident) return null;
            const v: JsIr.NameIndex = @enumFromInt(datas[value].lhs);
            if (found) |f| if (f != v) return null;
            found = v;
        }
        const v = found orelse return null;
        // A carried slot's variable, written in place: its name in the
        // list is the name the body reads.
        var k: usize = 0;
        for (loop.slots) |slot| {
            if (slot.unwritten) continue;
            defer k += 1;
            if (!slot.carried or slot.body == .none) continue;
            if (names[k] == v and slot.body == v) return v;
        }
        return null;
    }

    /// A call of a function written in place, in tail position: its body in
    /// tail position, returning — or jumping — for the caller.
    fn inlineTail(l: *Lowerer, out: *StmtList, site: Inst.Index, index: u32, loop: ?*const Loop) Allocator.Error!void {
        const saved = try l.enterInline(out, site, index);
        defer l.leaveInline(saved);
        return l.tailStmts(out, l.bodyOf(index), loop);
    }

    /// Whether `inst` is a saturated `Js.ref e`.
    fn isRefCall(l: *Lowerer, inst: Inst.Index) bool {
        if (l.bir.instTag(inst) != .call) return false;
        const d = l.bir.instData(inst);
        if (l.jsIntrinsicOf(@enumFromInt(d.lhs)) != .ref) return false;
        return l.bir.subRange(@enumFromInt(d.rhs)).len() == 1;
    }

    /// Whether the reference `inst` names a `Js.Ref` binding written as a
    /// `let` (`findRefs`).
    fn unboxedRef(l: *Lowerer, inst: Inst.Index) bool {
        const d = l.bir.instData(inst);
        switch (l.bir.instTag(inst)) {
            .local => {
                const index = l.decl_index orelse return false;
                const local = l.bir.decls[index].locals_start + d.lhs;
                return local < l.unboxed_locals.len and l.unboxed_locals[local];
            },
            .top => return d.lhs < l.unboxed_tops.len and l.unboxed_tops[d.lhs],
            else => return false,
        }
    }

    /// Record `n` as the name of a `Js.Ref` written as a `let`.
    fn markMutable(l: *Lowerer, n: JsIr.NameIndex) !void {
        if (std.mem.indexOfScalar(JsIr.NameIndex, l.mutable_names.items, n) == null) {
            try l.mutable_names.append(l.scratch, n);
        }
    }

    /// The declaration `inst` calls when it is a call of one of this
    /// module's declarations, which is what a discarded or tail position
    /// can make unread.
    /// `--release`: whether declaration `index`'s result is `()` by its
    /// annotation — `…, … -> ()` — so its function need write no result
    /// (`backend.md` §4, *A `()` result is not written*). Not for a body
    /// that may suspend, whose value the fiber runtime reads, nor for one
    /// with a second body.
    fn unitResult(l: *Lowerer, index: u32, suspends: bool) bool {
        if (!l.in.unit_results or suspends) return false;
        if (index >= l.bir.decls.len) return false;
        if (l.in.dispatch.effectDecl(index).twin) return false;
        const ty = l.bir.decls[index].annotation.unwrap() orelse return false;
        if (l.bir.instTag(ty) != .type_fn) return false;
        return l.bir.instTag(@enumFromInt(l.bir.instData(ty).rhs)) == .type_unit;
    }

    /// Whether every value `inst` can end in is `()`: each of its tails
    /// (`pushTails`) is the literal `()`, a call of a declaration of this
    /// module whose annotation's result is `()`, or a `Js.write`, `Js.set`
    /// or `Js.throw`. Anything else — a call this module cannot see the
    /// type of — says no.
    fn unitValued(l: *Lowerer, inst: Inst.Index) bool {
        var stack: [64]Inst.Index = undefined;
        var len: usize = 1;
        stack[0] = inst;
        while (len > 0) {
            len -= 1;
            const at = stack[len];
            const d = l.bir.instData(at);
            switch (l.bir.instTag(at)) {
                .unit => {},
                .let => {
                    stack[len] = @enumFromInt(d.rhs);
                    len += 1;
                },
                .case => for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index)) |branch| {
                    if (l.bir.instTag(branch) != .branch) return false;
                    if (len == stack.len) return false;
                    stack[len] = @enumFromInt(l.bir.instData(branch).rhs);
                    len += 1;
                },
                .call => {
                    const callee: Inst.Index = @enumFromInt(d.lhs);
                    switch (l.bir.instTag(callee)) {
                        .top => {
                            const index = l.bir.instData(callee).lhs;
                            if (index >= l.bir.decls.len) return false;
                            const ty = l.bir.decls[index].annotation.unwrap() orelse return false;
                            if (l.bir.instTag(ty) != .type_fn) return false;
                            if (l.bir.instTag(@enumFromInt(l.bir.instData(ty).rhs)) != .type_unit) return false;
                        },
                        .ext_value => switch (l.jsIntrinsicOf(callee) orelse return false) {
                            .write, .set, .setAt, .throw, .each => {},
                            // `Js.finally`'s value is its body's: a lambda's
                            // body, whose tails are asked in turn.
                            .finally => {
                                const args = l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index);
                                if (args.len != 2 or l.bir.instTag(args[0]) != .lambda) return false;
                                if (len == stack.len) return false;
                                stack[len] = @enumFromInt(l.bir.instData(args[0]).rhs);
                                len += 1;
                            },
                            else => return false,
                        },
                        else => return false,
                    }
                },
                else => return false,
            }
        }
        return true;
    }

    fn tailCallee(l: *Lowerer, inst: Inst.Index) ?u32 {
        if (l.bir.instTag(inst) != .call) return null;
        const callee: Inst.Index = @enumFromInt(l.bir.instData(inst).lhs);
        if (l.bir.instTag(callee) != .top) return null;
        const index = l.bir.instData(callee).lhs;
        return if (index < l.bir.decls.len) index else null;
    }

    /// The positions under `inst` whose value is `inst`'s: a `let`'s body
    /// and each branch of a `case`.
    fn pushTails(l: *Lowerer, stack: *std.ArrayList(Inst.Index), inst: Inst.Index) !void {
        const d = l.bir.instData(inst);
        switch (l.bir.instTag(inst)) {
            .let => try stack.append(l.scratch, @enumFromInt(d.rhs)),
            .case => for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index)) |branch| {
                if (l.bir.instTag(branch) == .branch) try stack.append(l.scratch, @enumFromInt(l.bir.instData(branch).rhs));
            },
            else => {},
        }
    }

    /// `let _ = inst`: evaluated for its effect and nothing else, so
    /// written as statements with no binding (`backend.md` §4, *A discarded
    /// value is a statement*). A right-hand side that cannot have an effect
    /// is still evaluated in a development build, exactly as its `const` was,
    /// and its statements are listed for the release optimiser, which drops
    /// them as it dropped the `const` (`language.md` §6).
    fn discard(l: *Lowerer, out: *StmtList, inst: Inst.Index, p: u32) Allocator.Error!void {
        // A `let` is its bindings, then its body discarded in turn.
        var at = inst;
        while (l.bir.instTag(at) == .let) {
            const d = l.bir.instData(at);
            try l.letBindings(out, l.bir.subRange(@enumFromInt(d.lhs)));
            at = @enumFromInt(d.rhs);
        }
        // An arm no value takes writes nothing, and an `if Js.development`
        // is the arm the build takes (`backend.md` §4, *`Js.development` is
        // the build's mode*) — as in `exprValue` and `tailCase`.
        if (l.deadArm(at)) return;
        if (l.developmentArm(at)) |body| return l.discard(out, body, p);
        // A `case` (and an `if`) is the tree, each leaf discarded: no
        // temporary assigned in every arm.
        if (l.bir.instTag(at) == .case and !(l.suspendable and l.branchesYield(at))) {
            const before = out.items.len;
            try l.discardCase(out, at);
            if (!l.mayHaveEffect(at)) try l.pure_discards.appendSlice(l.scratch, out.items[before..]);
            return;
        }
        // A call of a function written in place whose value nothing reads:
        // its body, discarded in turn (`backend.md` §9, *A function called
        // once is written where it is called*) — statements or not, since
        // no value has to come out of them.
        // A `Js.finally` whose value nothing reads: the `try` with the body
        // discarded in it, no temporary.
        if (l.finallyArgs(at)) |fa| {
            _ = try l.finallyTry(out, fa[0], fa[1], .discard, l.pos(at));
            return;
        }
        if (l.catchArgs(at)) |ca| {
            _ = try l.catchTry(out, ca[0], ca[1], ca[2], .discard, l.pos(at));
            return;
        }
        if (l.pureBody(at)) |body| return l.discard(out, body, p);
        if (l.bir.instTag(at) == .call) if (l.inlineTarget(at)) |index| {
            if (l.inline_loops[index] and try l.boundLoop(out, at, .discard, &.{})) return;
            if (!l.inline_loops[index] and l.atomArguments(at)) {
                const saved = try l.enterInline(out, at, index);
                defer l.leaveInline(saved);
                return l.discard(out, l.bodyOf(index), p);
            }
        };
        const value = try l.expr(out, at);
        const before = out.items.len;
        try l.discardValue(out, value, p);
        if (l.mayHaveEffect(at)) return;
        try l.pure_discards.appendSlice(l.scratch, out.items[before..]);
    }

    /// A `case` whose value nothing reads, as statements: the decision tree
    /// with each leaf's body discarded (`discard`), no result temporary.
    fn discardCase(l: *Lowerer, out: *StmtList, inst: Inst.Index) Allocator.Error!void {
        var c = try l.planCase(out, inst) orelse return;
        const depth = l.case_depth;
        l.case_depth += 1;
        defer l.case_depth = depth;
        c.sink = .{ .discard = .{ .result = .none } };
        if (try l.condChainPossible(&c)) {
            try l.lowerReady(&c);
            if (l.readyIsClean(&c)) return l.discardValue(out, try l.condChain(&c, c.tree.root), c.p);
        }
        const wrapped = c.tree.hasSwitch() or c.tree.hasShared();
        if (!wrapped) return l.emitCase(&c, out);
        const wrapper = try l.caseLabel(&c);
        c.sink = .{ .discard = .{ .result = .none, .wrapper = wrapper } };
        var inner: StmtList = .empty;
        try l.emitCase(&c, &inner);
        l.trimTrailingBreak(&inner, wrapper);
        try out.append(l.scratch, try l.blockStmt(wrapper, inner.items, c.p));
    }

    /// The statements that evaluate `value` and throw its result away:
    /// nothing for a read (a name, a literal, a field of one), an `if`
    /// statement for a conditional, whose arms are discarded in turn, and
    /// the expression statement `value;` for anything else.
    fn discardValue(l: *Lowerer, out: *StmtList, value: Node.Index, p: u32) Allocator.Error!void {
        if (l.isRead(value)) return;
        if (l.b.nodes.items(.tag)[value.int()] != .cond) {
            return out.append(l.scratch, try l.add(.expr_stmt, p, value.int(), Node.Data.unused));
        }
        const d = l.b.nodes.items(.data)[value.int()];
        const arms = l.b.extra.items[d.rhs..][0..2];
        const test_expr: Node.Index = @enumFromInt(d.lhs);
        var then: StmtList = .empty;
        try l.discardValue(&then, @enumFromInt(arms[0]), p);
        var otherwise: StmtList = .empty;
        try l.discardValue(&otherwise, @enumFromInt(arms[1]), p);
        if (then.items.len == 0 and otherwise.items.len == 0) return l.discardValue(out, test_expr, p);
        if (then.items.len == 0) return l.ifStatement(out, try l.negate(test_expr, p), otherwise.items, p);
        const then_range = try l.b.addRange(then.items);
        const else_range = try l.b.addRange(otherwise.items);
        const record = try l.b.addRecord(JsIr.If{
            .then_start = then_range.start,
            .then_end = then_range.end,
            .else_start = else_range.start,
            .else_end = else_range.end,
        });
        try out.append(l.scratch, try l.add(.if_stmt, p, test_expr.int(), @intFromEnum(record)));
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
        if (l.isAtom(value)) return value;
        const n = try l.fresh(l.well.temp);
        try l.constDecl(out, n, value, p);
        return l.ident(n, p);
    }

    /// An atom, or a field read of one: evaluating it changes nothing and
    /// cannot throw, since every beni value is initialised before it is
    /// read and a field of a well-typed value exists.
    fn isRead(l: *Lowerer, value: Node.Index) bool {
        var at = value;
        while (l.b.nodes.items(.tag)[at.int()] == .member) at = @enumFromInt(l.b.nodes.items(.data)[at.int()].lhs);
        // A read of a `Js.Ref` written as a `let` changes nothing either.
        return l.isAtom(at) or l.isMutable(at);
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
        /// **Discarded** (`discardCase`, `backend.md` §4, *A discarded value
        /// is a statement*): each leaf's body is discarded in turn, and
        /// breaks out of the block when there is one. `result` is `.none`.
        discard: Value,
    };

    const Value = struct {
        result: JsIr.NameIndex,
        /// `.none` for a pure `if`/`else` chain: the arms fall out of it and
        /// there is nothing to break out of (§7's third row).
        wrapper: JsIr.NameIndex = .none,
        /// A `case` in a leaf's body is lowered into this same sink
        /// (`chainedLeaf`). Only ever set together with a `wrapper`.
        chained: bool = false,
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
        /// Every two-way test writes its `else` AFTER the `if` rather than
        /// inside it (`emitFan`): set for a long `else if` chain, whose
        /// leaves all jump.
        flat_else: bool = false,
        /// Per root: the `scalars` entry of a list a loop holds as an
        /// offset (§8, *Scalar views*), whose root node is that offset;
        /// empty when no root is one.
        scalar: []const ?usize = &.{},
        /// A nested `case` may be one arm of a conditional chain
        /// (`condChainPossible`): `--release`, in a value position.
        nested_conds: bool = false,
    };

    /// A `case` in expression position: §7's last three rows.
    fn caseExpr(l: *Lowerer, out: *StmtList, inst: Inst.Index) !Node.Index {
        if (l.developmentArm(inst)) |body| return l.expr(out, body);
        const into = l.case_into;
        l.case_into = .{};
        const p = l.pos(inst);
        // A branch that may suspend: the rest of the function is a join the
        // leaves call (transparent-effects-proposal.md §16.3).
        if (l.suspendable and l.branchesYield(inst)) return l.joinAround(out, inst, .{ .case = inst }, p);
        var c = try l.planCase(out, inst) orelse
            return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        const depth = l.case_depth;
        l.case_depth += 1;
        defer l.case_depth = depth;

        // The conditional-expression shape: no `switch`, no shared leaf,
        // nothing bound, every leaf one expression — `a ? b : c` and nothing
        // more, exactly as today.
        c.nested_conds = l.in.unit_results;
        // `--release`: the result's name is chosen first, so that a leaf
        // that is a `case` needing statements writes it (`case_into`).
        var early: JsIr.NameIndex = .none;
        if (try l.condChainPossible(&c)) {
            if (l.in.unit_results) early = if (into.name != .none) into.name else try l.fresh(l.well.temp);
            try l.lowerReadyInto(&c, early);
            if (l.readyIsClean(&c)) return l.condChain(&c, c.tree.root);
        }

        const result = if (early != .none) early else if (into.name != .none) into.name else try l.fresh(l.well.temp);
        if (into.name == .none or into.declare) try out.append(l.scratch, try l.add(
            .let_decl,
            c.p,
            @intFromEnum(result),
            @intFromEnum(Node.OptionalIndex.none),
        ));
        // A long `else if` chain — `chain_min` `case`s, each in the last
        // branch of the one before — is written as ONE block of flat tests
        // that all assign this temporary (`chainedLeaf`), not one nested
        // `case` per arm with a temporary and a block of its own each.
        const chained = l.leafCaseDepth(inst) + 1 >= chain_min;
        const wrapped = c.tree.hasSwitch() or c.tree.hasShared() or chained;
        c.sink = .{ .value = .{
            .result = result,
            .wrapper = if (wrapped) try l.caseLabel(&c) else .none,
            .chained = chained,
        } };
        c.flat_else = chained;

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
        if (l.developmentArm(inst)) |body| return l.tailStmts(out, body, loop);
        const p = l.pos(inst);
        var c = try l.planCase(out, inst) orelse {
            const value = try l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            try l.tailReturn(out, value, loop, p);
            return;
        };
        const depth = l.case_depth;
        l.case_depth += 1;
        defer l.case_depth = depth;
        c.sink = .{ .tail = loop };
        c.flat_else = l.leafCaseDepth(inst) + 1 >= chain_min;

        // A chain of two-way tests over expression leaves stays the
        // conditional expression it is today: `return a ? b : c` is shorter
        // than two `return`s and says the same thing.
        if (try l.condChainPossible(&c)) {
            try l.lowerReady(&c);
            if (l.readyIsClean(&c)) {
                const value = try l.condChain(&c, c.tree.root);
                try l.tailReturn(out, value, loop, c.p);
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
        // A pattern with items after its spread reads the scrutinee's end
        // through `List.length` and `List.drop` (§7, *List patterns with
        // elements after the spread*): more than once, so it is bound.
        var list_end = false;
        for (branches) |branch| {
            if (l.hasListEnd(@enumFromInt(l.bir.instData(branch).lhs))) list_end = true;
        }

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
        const scalar = try l.scratch.alloc(?usize, roots);
        var any_scalar = false;
        for (root_nodes, scalar, 0..) |*root, *root_scalar, r| {
            // A list a loop holds as an offset is matched at that offset
            // over its base (§8, *Scalar views*), never built.
            const source = if (spread) elements[r] else scrutinee;
            root_scalar.* = if (l.bir.instTag(source) == .local) l.scalarOf(l.bir.instData(source).lhs) else null;
            const raw_mark = l.scalar_raw.items.len;
            defer l.scalar_raw.shrinkRetainingCapacity(raw_mark);
            if (root_scalar.* != null) {
                any_scalar = true;
                try l.scalar_raw.append(l.scratch, source);
            }
            // Each tuple element is evaluated in source order, so the
            // elements keep running left to right whatever the tree tests
            // first — which is also why an element read once is still bound.
            const value = try l.expr(out, source);
            var reads = tree.fanReads(@intCast(r), max_switch_cases);
            for (0..branches.len) |i| {
                if (tree.uses[i] == 0) continue;
                reads += l.bindCount(pats[i * roots + r]);
            }
            if (list_end) reads += 2;
            root.* = if (reads == 0) blk: {
                // Nothing reads it — one constructor, or `_` — and it is
                // still evaluated, once and here (§7, dated note
                // 2026-09-29). A statement and not a `const`: no binding is
                // written, so §9 item 1 has none to drop, and a
                // `case Debug.log m "m" of Inc ->` logs in both builds. A
                // name or a field read has nothing to evaluate and is left
                // out whole.
                if (!l.isRead(value)) try out.append(l.scratch, try l.add(.expr_stmt, p, value.int(), Node.Data.unused));
                break :blk value;
            } else if (reads == 1 and !spread)
                value
            else
                try l.bindSubject(out, value, p);
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
            .scalar = if (any_scalar) scalar else &.{},
        };
    }

    /// Whether `pattern` holds a list pattern with an item after its spread.
    fn hasListEnd(l: *Lowerer, pattern: Inst.Index) bool {
        const d = l.bir.instData(pattern);
        return switch (l.bir.instTag(pattern)) {
            .pat_as => l.hasListEnd(@enumFromInt(d.lhs)),
            .pat_tuple, .pat_list => for (l.bir.extraSlice(Bir.inlineRange(d), Inst.Index), 0..) |el, i| {
                if (l.bir.instTag(pattern) == .pat_list and l.bir.instTag(el) == .pat_spread and
                    i + 1 < Bir.inlineRange(d).len()) break true;
                if (l.hasListEnd(el)) break true;
            } else false,
            .pat_ctor => for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index)) |el| {
                if (l.hasListEnd(el)) break true;
            } else false,
            else => false,
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
            .pat_spread => l.bindCount(@as(Inst.Index, @enumFromInt(d.lhs)).toOptional()),
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
            if (c.scalar.len != 0) if (c.scalar[r]) |k| {
                try l.scalarBindings(out, pattern, k, root);
                continue;
            };
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
            .value => |v| {
                if (v.chained and try l.chainedLeaf(out, body, c.sink)) return;
                // `--release`: a leaf that is — under its `let`s — a `case`
                // of its own writes this tree's temporary, where it would
                // write one of its own and this leaf copy it. Not behind a
                // wrapper, whose leaves break out of it after writing.
                var at = body;
                if (l.in.unit_results and v.wrapper == .none and !l.deadArm(body)) {
                    // A leaf `let … x = e … in x`: `x` is the temporary,
                    // written where it is bound (`letBindings`).
                    var fin = body;
                    while (l.bir.instTag(fin) == .let) fin = @enumFromInt(l.bir.instData(fin).rhs);
                    const saved_bind = l.bind_into;
                    defer l.bind_into = saved_bind;
                    l.bind_into = if (l.bir.instTag(fin) == .local) .{ .local = l.bir.instData(fin).lhs, .name = v.result } else .{};
                    while (l.bir.instTag(at) == .let) {
                        const d = l.bir.instData(at);
                        try l.letBindings(out, l.bir.subRange(@enumFromInt(d.lhs)));
                        at = @enumFromInt(d.rhs);
                    }
                    if (l.bir.instTag(at) == .case) l.case_into = .{ .name = v.result };
                }
                const value = try l.expr(out, at);
                l.case_into = .{};
                if (l.isIdentOf(value, v.result)) return;
                try l.finishLeaf(c, out, value, p);
            },
            .discard => |v| {
                try l.discard(out, body, p);
                if (v.wrapper != .none) {
                    try out.append(l.scratch, try l.add(.break_stmt, p, @intFromEnum(v.wrapper), Node.Data.unused));
                }
            },
        }
    }

    /// A leaf of a `chained` value `case` whose body — under any `let`s —
    /// is another `case`: that `case` is lowered into the SAME sink,
    /// assigning the outer temporary and breaking out of the outer block, so
    /// the whole chain is one block and one temporary (`backend.md` §4,
    /// *Emitted JavaScript nests only as deep as the source*). False when
    /// the body is not a `case`, and the leaf lowers as any other.
    ///
    /// Nothing moves: the `let` bindings run where they did, in the leaf,
    /// and the inner `case`'s scrutinee is bound where its own `caseExpr`
    /// would have bound it, at the top of the leaf. Every leaf of the inner
    /// tree breaks out of the outer block, which skips the inner tree's
    /// shared leaves exactly as its own block would have. The inner `case`
    /// is chained in turn, so the chain is flat at any length.
    fn chainedLeaf(l: *Lowerer, out: *StmtList, body: Inst.Index, sink: Sink) Allocator.Error!bool {
        if (l.deadArm(body)) return false;
        var inst = body;
        while (l.bir.instTag(inst) == .let) inst = @enumFromInt(l.bir.instData(inst).rhs);
        if (l.bir.instTag(inst) != .case) return false;
        inst = body;
        while (l.bir.instTag(inst) == .let) {
            const d = l.bir.instData(inst);
            try l.letBindings(out, l.bir.subRange(@enumFromInt(d.lhs)));
            inst = @enumFromInt(d.rhs);
        }
        const p = l.pos(inst);
        var c = try l.planCase(out, inst) orelse {
            // A `case` with no branches, which the parser reported.
            const target = try l.ident(sink.value.result, p);
            const nothing = try l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
            try out.append(l.scratch, try l.add(.assign_stmt, p, target.int(), nothing.int()));
            return true;
        };
        const depth = l.case_depth;
        l.case_depth += 1;
        defer l.case_depth = depth;
        c.sink = sink;
        c.flat_else = true;
        if (try l.condChainPossible(&c)) {
            try l.lowerReady(&c);
            if (l.readyIsClean(&c)) {
                try l.finishLeaf(&c, out, try l.condChain(&c, c.tree.root), c.p);
                return true;
            }
        }
        try l.emitCase(&c, out);
        return true;
    }

    /// How many `case`s deep `inst` nests another in one of its branches —
    /// the last such branch, under any `let`s — counted up to `chain_min`:
    /// one less than the number of `if`s in an `else if` chain, or in `if`s
    /// nested in `then` branches.
    fn leafCaseDepth(l: *Lowerer, inst: Inst.Index) u32 {
        var at = inst;
        var n: u32 = 0;
        walk: while (n < chain_min) : (n += 1) {
            const branches = l.bir.extraSlice(l.bir.subRange(@enumFromInt(l.bir.instData(at).rhs)), Inst.Index);
            var i = branches.len;
            while (i > 0) {
                i -= 1;
                var next: Inst.Index = @enumFromInt(l.bir.instData(branches[i]).rhs);
                while (l.bir.instTag(next) == .let) next = @enumFromInt(l.bir.instData(next).rhs);
                if (l.bir.instTag(next) != .case) continue;
                at = next;
                continue :walk;
            }
            return n;
        }
        return n;
    }

    fn finishLeaf(l: *Lowerer, c: *Case, out: *StmtList, value: Node.Index, p: u32) !void {
        switch (c.sink) {
            .tail => |loop| try l.tailReturn(out, value, loop, p),
            .value => |v| {
                // A leaf `case` that wrote the result itself (`case_into`).
                if (!l.isIdentOf(value, v.result)) {
                    const target = try l.ident(v.result, p);
                    try out.append(l.scratch, try l.add(.assign_stmt, p, target.int(), value.int()));
                }
                if (v.wrapper != .none) {
                    try out.append(l.scratch, try l.add(.break_stmt, p, @intFromEnum(v.wrapper), Node.Data.unused));
                }
            },
            .discard => |v| {
                try l.discardValue(out, value, p);
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
            const then_start = l.b.nodes.len;
            try l.emitNode(c, &then_stmts, edges[0].child);
            var else_stmts: StmtList = .empty;
            const else_start = l.b.nodes.len;
            try l.emitNode(c, &else_stmts, if (fan.default != Decision.no_node)
                fan.default
            else
                edges[1].child);
            const p = l.edgePos(c, edges[0]);
            // **In a long `else if` chain one branch follows the `if`
            // instead of sitting inside it** (`backend.md` §4, *Emitted
            // JavaScript nests only as deep as the source*): every path
            // through either branch leaves — a `return` or a `continue` in
            // tail position, a `break` out of the chain's one block in a
            // `chained` value `case`, a `break` to a shared leaf — so
            // `if (a) { … }` and then the `else` statements is the same
            // program one level shallower. It is what keeps the chain from
            // nesting one `if` per arm, which Chrome stops parsing at 644.
            // The branch that follows is the larger, which is the one the
            // chain goes on in: the `else` of an `else if`, the `then` of an
            // `if` nested in a `then` — whose test is then negated. A chain
            // shorter than `chain_min` nests as it always did.
            if (c.flat_else) {
                const nested_then = l.b.nodes.len - else_start < else_start - then_start;
                const test_expr = if (nested_then) try l.negate(condition, p) else condition;
                const inside = if (nested_then) else_stmts.items else then_stmts.items;
                const after = if (nested_then) then_stmts.items else else_stmts.items;
                try l.ifStatement(out, test_expr, inside, p);
                try out.appendSlice(l.scratch, after);
                return;
            }
            const then_range = try l.b.addRange(then_stmts.items);
            const else_range = try l.b.addRange(else_stmts.items);
            const record = try l.b.addRecord(JsIr.If{
                .then_start = then_range.start,
                .then_end = then_range.end,
                .else_start = else_range.start,
                .else_end = else_range.end,
            });
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
        // At most `max_switch_cases` labels a `switch`: a longer fan
        // is consecutive `switch`es, the `default:` in the last. Every case
        // body leaves — a `return`, a `continue`, a `break` out of the
        // `case`'s block or to a shared leaf — which one `switch` already
        // relies on, since a case that did not would fall into the next.
        var from: usize = 0;
        while (from < cases.items.len) {
            const to = @min(from + max_switch_cases, cases.items.len);
            const cases_range = try l.b.addRange(cases.items[from..to]);
            const cases_record = try l.b.addRecord(cases_range);
            const discriminant = try l.fanDiscriminant(c, fan);
            try out.append(l.scratch, try l.add(.switch_stmt, c.p, discriminant.int(), @intFromEnum(cases_record)));
            from = to;
        }
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
            // Two alternatives, so an `if` (`edgeTest`) and never a switch.
            .list => return l.lengthOf((try l.listPos(c, fan.occ)).base, c.p),
            .ctor => {
                const rep = l.fanRep(c, fan) orelse return subject;
                return switch (rep) {
                    .tagged => try l.member(subject, l.well.tag, c.p),
                    // `.record`: a record alias has ONE constructor, so it
                    // never fans out and nothing reads this for it.
                    .boolean, .bare_tag, .record => subject,
                };
            },
            .int, .char, .string => return subject,
        }
    }

    /// The `===` an `if` tests one alternative with. `x === true` is `x` and
    /// `x === false` is `!x`: the one place a readable `if` is worth a
    /// special case, because every `if` in the language goes through here.
    fn edgeTest(l: *Lowerer, c: *Case, fan: Decision.Fan, edge: Decision.Edge) !Node.Index {
        const p = l.edgePos(c, edge);
        // A list occurrence is a list and a depth, `(r, k)` (§7, *List
        // patterns over arrays*): `[]` is `r.length === k` and `::` is
        // `r.length > k`, the two complementary on every path that reaches
        // `(r, k)`, which has already found `r` at least `k` long.
        if (fan.kind == .list) {
            const at = try l.listPos(c, fan.occ);
            const op: JsIr.BinaryOp = if (edge.order == 0) .strict_eq else .gt;
            return l.binary(op, try l.lengthOf(at.base, p), try l.posIndex(at, p), p);
        }
        const subject = try l.occNode(c, fan.occ);
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
            // Never a `case` label: a list node is always an `if`.
            .list => return l.numberNode(if (edge.order == 0) "0" else "1", p),
            .ctor => {
                const ref = edge.ref.unwrap() orelse return l.nullNode(p);
                const rep_and_tag = l.ctorRepOf(ref) orelse return l.nullNode(p);
                return l.tagLiteral(rep_and_tag[0], rep_and_tag[1], p);
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
    /// re-reading costs nothing and there is no live binding for the release
    /// optimiser's dead-binding pass to fail to remove (§7).
    fn occNode(l: *Lowerer, c: *Case, occ: u32) Allocator.Error!Node.Index {
        if (c.occ_nodes[occ].unwrap()) |node| return node;
        const o = c.tree.occs[occ];
        const node = if (o.parent == Decision.Occ.no_parent)
            c.roots[o.root]
        else switch (o.kind) {
            .slot => try l.argMember(try l.occNode(c, o.parent), o.via.unwrap(), o.slot, c.p),
            // An element: `List$unsafeGet(r, k)`, O(1) on a plain list or
            // a view, and near O(1) on a trie.
            .head => blk: {
                const at = try l.listPos(c, o.parent);
                // Over a scalar view's base, a plain array: indexed.
                if (at.start != null) break :blk try l.add(.index_get, c.p, at.base.int(), (try l.posIndex(at, c.p)).int());
                break :blk try l.listElement(at.base, try l.posIndex(at, c.p), c.p);
            },
            // A list the tree only tests is never built (`listPos`); one a
            // column needs as a value is a view of it.
            .tail, .last => blk: {
                const at = try l.listPos(c, occ);
                break :blk try l.call(try l.corePrivate(.view, c.p), &.{ at.base, try l.posIndex(at, c.p) }, c.p);
            },
        };
        c.occ_nodes[occ] = node.toOptional();
        return node;
    }

    /// Where a list occurrence is (§7, *List patterns over arrays*): the
    /// list `base` without its first `k` elements — or, with `from_end`
    /// not 0, the last `from_end` elements of `base` without their first
    /// `k`, where a pattern's items after its spread are read. A chain of
    /// tails is a position in the list it started from, so nothing is
    /// built for a tail the tree only tests: `(x :: y :: rest)` is `r` at
    /// 0, 1 and 2.
    /// A list a loop holds as an offset (§8, *Scalar views*) is its base
    /// array from `start`, the offset, on.
    const ListPos = struct { base: Node.Index, k: u32, from_end: u32 = 0, start: ?Node.Index = null };

    fn listPos(l: *Lowerer, c: *Case, occ: u32) Allocator.Error!ListPos {
        const o = c.tree.occs[occ];
        if (o.parent == Decision.Occ.no_parent) {
            if (c.scalar.len != 0) if (c.scalar[o.root]) |k| {
                return .{ .base = try l.ident(l.scalars.items[k].base, c.p), .k = 0, .start = c.roots[o.root] };
            };
            return .{ .base = try l.occNode(c, occ), .k = 0 };
        }
        return switch (o.kind) {
            .tail => blk: {
                var at = try l.listPos(c, o.parent);
                at.k += 1;
                break :blk at;
            },
            .last => .{ .base = (try l.listPos(c, o.parent)).base, .k = 0, .from_end = o.slot },
            .slot, .head => .{ .base = try l.occNode(c, occ), .k = 0 },
        };
    }

    /// The index a position's first element is at: `k`, or, counted from
    /// the end, `base.length - (from_end - k)`.
    fn posIndex(l: *Lowerer, at: ListPos, p: u32) !Node.Index {
        if (at.start) |start| return l.offsetPlus(start, at.k, p);
        if (at.from_end == 0) return l.intNode(at.k, p);
        return l.lengthMinus(at.base, at.from_end - at.k, p);
    }

    // ---- Shapes and labels -------------------------------------------------

    /// Whether the tree can be one conditional expression: no `switch`, no
    /// shared leaf, nothing bound, and no branch body that is a `let`, a
    /// `case` or a tail self-call — the three that need statements of their
    /// own. Whether the bodies really lower without statements is only known
    /// after they are lowered, which is what `readyIsClean` answers.
    fn condChainPossible(l: *Lowerer, c: *Case) Allocator.Error!bool {
        if (c.tree.hasSwitch() or c.tree.hasShared()) return false;
        // A loop's exits whose tuples are written element by element: a
        // conditional would build the tuple.
        switch (c.sink) {
            .tail => |loop| if (loop) |lp| if (lp.exit == .tuple) return false,
            else => {},
        }
        for (c.branches, 0..) |branch, i| {
            if (c.tree.uses[i] == 0) continue;
            for (0..c.roots.len) |r| {
                if (l.bindCount(c.pats[i * c.roots.len + r]) != 0) return false;
            }
            const body: Inst.Index = @enumFromInt(l.bir.instData(branch).rhs);
            switch (l.bir.instTag(body)) {
                // Under `--release`, a nested `case` whose value is wanted
                // may be a conditional itself (`backend.md` §9, *Compact
                // statements*): `c ? a : d ? b : e` for an `else if` chain.
                // `readyIsClean` says whether it came out as one; when it
                // did not, its statements are this arm's, as for any arm.
                .case => if (!c.nested_conds) return false,
                .let => return false,
                // A call written in place is statements of its own, in the
                // leaf's position (§9, *A function called once is written
                // where it is called*).
                .call => switch (c.sink) {
                    .tail => |loop| {
                        if (loop) |lp| if (l.isSelfCall(body, lp) or l.isConsStep(body, lp)) return false;
                        if (try l.tailInline(body, loop) != null) return false;
                        // A `try` in tail position returns from its blocks
                        // (`tailStmts`), and `Js.pure`'s body is in tail
                        // position itself.
                        if (loop == null and l.join == .none and (l.finallyArgs(body) != null or l.catchArgs(body) != null)) return false;
                        if (l.pureBody(body) != null) return false;
                    },
                    // A loop written where its value is discarded.
                    .discard => if (l.inlineTarget(body)) |index| {
                        if (l.inline_loops[index]) return false;
                    },
                    .value => {},
                },
                else => {},
            }
        }
        return true;
    }

    fn lowerReady(l: *Lowerer, c: *Case) !void {
        return l.lowerReadyInto(c, .none);
    }

    /// `lowerReady`, where a leaf that is itself a `case` writes `into`
    /// when it needs statements (`case_into`), unless `into` is `.none`.
    fn lowerReadyInto(l: *Lowerer, c: *Case, into: JsIr.NameIndex) !void {
        const ready = try l.scratch.alloc(Ready, c.branches.len);
        @memset(ready, .{});
        for (c.branches, 0..) |branch, i| {
            if (c.tree.uses[i] == 0) continue;
            var stmts: StmtList = .empty;
            const body: Inst.Index = @enumFromInt(l.bir.instData(branch).rhs);
            if (into != .none and l.bir.instTag(body) == .case and !l.deadArm(body)) l.case_into = .{ .name = into };
            const value = try l.expr(&stmts, body);
            l.case_into = .{};
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
                const ref: Inst.Index = @enumFromInt(d.lhs);
                for (l.bir.extraSlice(l.bir.subRange(@enumFromInt(d.rhs)), Inst.Index), 0..) |arg, i| {
                    try l.bindings(out, arg, try l.argMember(subject, ref, @intCast(i), p));
                }
            },
            .pat_list => {
                // By index (§7, *List patterns over arrays*): item `i` before
                // the spread is element `i`, item `j` after it element
                // `length - s + j`. `...rest` with nothing after it is the
                // view from its index — O(1), but an object, so written only
                // when the leaf reads `rest` (§7: a tail is bound only where
                // it is read) — and with items after it the elements
                // between, a `slice`.
                const elements = l.bir.extraSlice(Bir.inlineRange(d), Inst.Index);
                const spread: ?usize = for (elements, 0..) |element, i| {
                    if (l.bir.instTag(element) == .pat_spread) break i;
                } else null;
                const after: u32 = if (spread) |s| @intCast(elements.len - s - 1) else 0;
                for (elements, 0..) |element, i| {
                    if (spread) |s| if (i == s) {
                        const operand: Inst.Index = @enumFromInt(l.bir.instData(element).lhs);
                        if (!try l.bindsRead(operand)) continue;
                        const from = try l.intNode(@intCast(s), p);
                        const value = if (after == 0)
                            try l.call(try l.corePrivate(.view, p), &.{ subject, from }, p)
                        else
                            try l.call(try l.coreValue(.List, .slice, p), &.{ subject, from, try l.lengthMinus(subject, after, p) }, p);
                        try l.bindings(out, operand, value);
                        continue;
                    };
                    if (l.bindCount(element.toOptional()) == 0) continue;
                    const index = if (spread != null and i > spread.?)
                        try l.lengthMinus(subject, @intCast(elements.len - i), p)
                    else
                        try l.intNode(@intCast(i), p);
                    try l.bindings(out, element, try l.listElement(subject, index, p));
                }
            },
            .pat_record => {
                // Each element is the LOCAL INDEX bound, and the local's
                // name is the field name (`Bir.Tag.pat_record`).
                for (l.bir.extraSlice(Bir.inlineRange(d), u32)) |local| {
                    if (local >= l.locals.len) continue;
                    const field = l.locals[local].name.unwrap() orelse continue;
                    const value = try l.fieldMember(subject, l.bir.symbols[field], p);
                    try l.constDecl(out, try l.localName(local), value, p);
                }
            },
            else => {},
        }
    }

    // ---- Markup (backend.md §15.1; boundary.md §9.4) ----------------------
    //
    // The compiler's part around the build's markup lowering: the tree is
    // built once per module, the lowering's `module` runs before the first
    // declaration, and at each `markup` instruction the root's values are
    // evaluated here — each a `const`, in `language.md` §6's order — before
    // the lowering's `root` is asked for the expression the root evaluates
    // to. Everything the lowering writes goes through `markup_vtable`, whose
    // functions are the `Context` of `boundary.md` §9.4.3 and nothing more.

    /// Build this module's tree and run the lowering's `module`, when the
    /// build has a lowering and a surviving declaration writes markup.
    fn beginMarkup(l: *Lowerer) Allocator.Error!void {
        const mk = l.in.markup orelse return;
        var live: std.ArrayList(u32) = .empty;
        for (0..l.bir.decls.len) |i| {
            if (l.liveDecl(@intCast(i))) try live.append(l.scratch, @intCast(i));
        }
        const built = try MarkupTree.build(l.scratch, .{
            .bir = l.bir,
            .module = l.in.module.int(),
            .dispatch = l.in.dispatch,
            .vocabulary = mk.vocabulary,
            .interner = l.interner.global,
            .live = live.items,
            .interfaces = l.in.interfaces,
            .comparison = .{ .ctx = l, .classify = classifyComparison },
        }) orelse return;
        const st = try l.scratch.create(MarkupState);
        st.* = .{
            .built = built,
            .lowering = mk.lowering,
            .bound = try l.scratch.alloc(Bound, built.values.len),
            .cx = .{
                .build = mk.build,
                .js = .{ .impl = l, .vtable = &markup_vtable },
                .arena = l.scratch,
                .impl = l,
                .vtable = &markup_vtable,
            },
        };
        @memset(st.bound, .none);
        l.mk = st;
        // A hoisted name is `<Module>$<hint>`, which a declaration of the
        // same name is too.
        const names = try l.scratch.alloc(u32, l.bir.decls.len);
        for (l.bir.decls, names) |d, *n| n.* = @intFromEnum(l.bir.symbol(d.name));
        std.mem.sort(u32, names, {}, std.sort.asc(u32));
        st.decl_names = names;
        // A tree that uses a feature newer than the lowering was written
        // against would meet a node the lowering cannot render (§9.4.6).
        // Every feature of version 1.0 is available to every lowering, so
        // this cannot happen until a later minor version gates one.
        if (!mk.lowering.targets.covers(built.tree.requires)) {
            try l.report(.internal, @enumFromInt(built.root_insts[0]), "The markup lowering `{s}` targets interface {d}.{d}, and this module's markup needs {d}.{d}.", .{
                mk.lowering.name,
                mk.lowering.targets.major,
                mk.lowering.targets.minor,
                built.tree.requires.major,
                built.tree.requires.minor,
            });
            return;
        }
        mk.lowering.module(&st.cx, &st.built.tree) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Reported => {},
        };
    }

    /// A `markup` instruction of kind `expression`: its values, then the
    /// lowering's expression for it.
    fn markupExpression(l: *Lowerer, out: *StmtList, inst: Inst.Index) Allocator.Error!Node.Index {
        const p = l.pos(inst);
        const st = l.mk orelse return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        const index = st.built.rootAt(inst.int()) orelse return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
        const root = st.built.tree.root(index);
        try l.markupValues(out, root);
        const saved = st.pos;
        st.pos = p;
        defer st.pos = saved;
        const result = st.lowering.root(&st.cx, &st.built.tree, index) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Reported => return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
        };
        return @enumFromInt(@intFromEnum(result));
    }

    /// Evaluate a root's instruction values into `out`, in order, each
    /// bound where the lowering can name it. The other slots evaluate
    /// nothing and are spelled where they are asked for.
    fn markupValues(l: *Lowerer, out: *StmtList, root: beni_markup.Root) Allocator.Error!void {
        return l.markupValuesSplit(out, out, root, &.{});
    }

    /// `markupValues`, the values `apart` marks evaluated into `apart_out`,
    /// in order among themselves.
    fn markupValuesSplit(l: *Lowerer, main_out: *StmtList, apart_out: *StmtList, root: beni_markup.Root, apart: []const bool) Allocator.Error!void {
        const st = l.mk.?;
        for (root.values.start..root.values.start + root.values.len, 0..) |v, k| {
            const inst = switch (st.built.values[v]) {
                .inst => |i| i,
                else => continue,
            };
            const out = if (k < apart.len and apart[k]) apart_out else main_out;
            const value = try l.expr(out, inst);
            const tag = l.b.nodes.items(.tag)[value.int()];
            st.bound[v] = switch (tag) {
                .ident => if (l.isMutable(value)) blk: {
                    const n = try l.fresh(l.well.temp);
                    try l.constDecl(out, n, value, l.pos(inst));
                    break :blk .{ .name = n };
                } else .{ .name = @enumFromInt(l.b.nodes.items(.data)[value.int()].lhs) },
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => .{ .node = value },
                else => blk: {
                    const n = try l.fresh(l.well.temp);
                    try l.constDecl(out, n, value, l.pos(inst));
                    break :blk .{ .name = n };
                },
            };
        }
    }

    /// A value's expression, fresh at every use.
    fn markupValue(l: *Lowerer, v: beni_markup.Value.Index) Allocator.Error!Node.Index {
        const st = l.mk.?;
        const p = st.pos;
        const at = @intFromEnum(v);
        switch (st.built.values[at]) {
            .inst => switch (st.bound[at]) {
                .name => |n| return l.ident(n, p),
                .node => |node| {
                    const d = l.b.nodes.items(.data)[node.int()];
                    return l.add(l.b.nodes.items(.tag)[node.int()], p, d.lhs, d.rhs);
                },
                // Asked for outside the root or row that evaluates it: a
                // defect of the lowering, which gets a value that says so
                // rather than one of another render.
                .none => {
                    try l.report(.internal, l.region, "The markup lowering asked for a value its root has not evaluated.", .{});
                    return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
                },
            },
            .capture => |local| return l.ident(try l.localName(local), p),
            .input => |record| return l.markupInput(record, p),
            .probe => |probe| {
                // `s`, or `s.$ === "Just" ? s.a : s`: the key a selector's
                // comparisons can hold for, else the value itself, which
                // is an object and so no key (backend.md §15.5).
                const ctor = probe.ctor.unwrap() orelse return l.markupInput(probe.input, p);
                const rep, const tag = l.ctorRepOf(ctor) orelse return l.markupInput(probe.input, p);
                const tested = try l.binary(.strict_eq, try l.member(try l.markupInput(probe.input, p), l.well.tag, p), try l.tagLiteral(rep, tag, p), p);
                const field = try l.member(try l.markupInput(probe.input, p), try l.slotName(0), p);
                return l.condOf(tested, field, try l.markupInput(probe.input, p), p);
            },
            .entries => |range| {
                // The list written in place, rebuilt from its entries'
                // values: each already evaluated, so this is data only.
                const tree = &st.built.tree;
                var cells: std.ArrayList(Node.Index) = .empty;
                for (tree.entriesOf(range)) |entry| {
                    const name_node = try l.stringNode(tree.string(entry.name), p);
                    const value_node = switch (entry.value.kind) {
                        .constant => try l.markupConstant(entry.value.constant, p),
                        else => try l.markupValue(entry.value.dynamic.?),
                    };
                    try cells.append(l.scratch, try l.object(&.{
                        try l.property(try l.slotName(0), name_node, p),
                        try l.property(try l.slotName(1), value_node, p),
                    }, p));
                }
                return l.arrayNode(cells.items, p);
            },
            .string => |bytes| return l.stringNode(bytes, p),
            .true => return l.add(.true_lit, p, Node.Data.unused, Node.Data.unused),
            .callee => |inst| return l.reference(inst),
            .call => |c| {
                const args = try l.scratch.alloc(Node.Index, c.args.len);
                for (args, 0..) |*a, k| a.* = try l.markupValue(c.args.at(@intCast(k)));
                return l.call(try l.markupValue(@enumFromInt(c.callee)), args, p);
            },
        }
    }

    /// A row input: its captured local, then its field path.
    fn markupInput(l: *Lowerer, record: Bir.ExtraIndex, p: u32) Allocator.Error!Node.Index {
        const input = l.bir.extraData(record, Bir.MarkupInput);
        var node = try l.ident(try l.localName(input.local), p);
        for (0..input.len) |k| {
            const link = input.link(k);
            node = if (link & Bir.tuple_link != 0)
                try l.member(node, try l.slotName(link & ~Bir.tuple_link), p)
            else
                try l.fieldMember(node, l.bir.symbols[link], p);
        }
        return node;
    }

    /// `MarkupTree.Comparison`: how the `==` or `/=` at `cmp` compares its
    /// operand `other` with the other one — `===`, or `other`'s one-field
    /// constructor's tag and `===` on its field, as `ctorEquality` writes
    /// it (backend.md §4) — so a row input read only that way against the
    /// row's key is a selector (language.md §11.9).
    fn classifyComparison(ctx: *anyopaque, cmp: Inst.Index, other: Inst.Index) MarkupTree.Comparison.Test {
        const l: *Lowerer = @ptrCast(@alignCast(ctx));
        const site = l.in.dispatch.siteOf(cmp) orelse return .none;
        const callee = site.callee.unwrap() orelse return .none;
        if (l.in.dispatch.argsAt(site.evidence).len != 0) return .none;
        switch (l.in.dispatch.term(callee)) {
            .primitive => |prim| return if (prim == .strict_eq) .strict else .none,
            .derived, .ext_derived => {
                const app = l.ctorApplication(other) orelse return .none;
                if (app.args.len != 1) return .none;
                return switch (l.fieldEq(callee, app.ctor, 0)) {
                    .strict => .{ .ctor = app.ctor },
                    else => .none,
                };
            },
            else => return .none,
        }
    }

    fn markupConstant(l: *Lowerer, c: beni_markup.Constant, p: u32) Allocator.Error!Node.Index {
        const tree = &l.mk.?.built.tree;
        return switch (c.kind) {
            .string => l.stringNode(tree.string(c.text), p),
            .number => l.numberNode(tree.string(c.text), p),
            .bool => l.add(if (c.bool) .true_lit else .false_lit, p, Node.Data.unused, Node.Data.unused),
            else => l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
        };
    }

    /// `cx.rowValues`: the row's root's values, placed in `block` inside a
    /// function the lowering builds, with the lambda's parameters bound to
    /// the names it chose.
    fn markupRowValues(
        l: *Lowerer,
        block: beni_markup.Block,
        apart_block: ?beni_markup.Block,
        row_index: beni_markup.Row.Index,
        item: beni_markup.Name,
        position: ?beni_markup.Name,
        captures: []const beni_markup.Name,
        apart: []const beni_markup.Value.Index,
    ) Allocator.Error!?Node.Index {
        const st = l.mk.?;
        const row = st.built.tree.row(row_index);
        const source = st.built.rows[@intFromEnum(row_index)];
        var stmts: StmtList = .empty;
        // A new function is a new label scope (§7).
        const depth = l.case_depth;
        l.case_depth = 0;
        defer l.case_depth = depth;
        const p = st.pos;

        const lambda = l.bir.instData(source.function);
        const params = l.bir.extraSlice(l.bir.subRange(@enumFromInt(lambda.lhs)), Inst.Index);
        for (params, 0..) |param, k| {
            const bound: JsIr.NameIndex = if (k == 0)
                @enumFromInt(@intFromEnum(item))
            else if (position) |n| @enumFromInt(@intFromEnum(n)) else try l.fresh(l.well.param);
            switch (l.bir.instTag(param)) {
                .pat_var => {
                    const local = l.bir.instData(param).lhs;
                    if (local < l.local_names.len) l.local_names[local] = bound;
                },
                .pat_wild => {},
                else => try l.bindings(&stmts, param, try l.ident(bound, p)),
            }
        }
        // The captured locals read under the names the lowering gave them,
        // for this function only.
        const saved = try l.scratch.alloc(JsIr.NameIndex, captures.len);
        if (captures.len == row.captures.len) {
            for (captures, saved, 0..) |n, *s, k| {
                const local = st.built.values[row.captures.start + k].capture;
                if (local >= l.local_names.len) continue;
                s.* = l.local_names[local];
                l.local_names[local] = @enumFromInt(@intFromEnum(n));
            }
        }
        defer if (captures.len == row.captures.len) for (saved, 0..) |s, k| {
            const local = st.built.values[row.captures.start + k].capture;
            if (local < l.local_names.len) l.local_names[local] = s;
        };
        for (l.bir.extraSlice(source.lets, Inst.Index)) |let| {
            try l.letBindings(&stmts, l.bir.subRange(@enumFromInt(l.bir.instData(let).lhs)));
        }
        const body = st.built.tree.root(row.body);
        var apart_stmts: StmtList = .empty;
        // A value named apart goes to `apart_block` only when it reads
        // nothing but the item; any other stays where it was asked for.
        const moved = try l.scratch.alloc(bool, body.values.len);
        for (moved, 0..) |*mv, k| {
            const v = body.values.at(@intCast(k));
            mv.* = apart_block != null and st.built.tree.itemOnly(v) and std.mem.indexOfScalar(beni_markup.Value.Index, apart, v) != null;
        }
        try l.markupValuesSplit(&stmts, &apart_stmts, body, moved);
        try st.blocks.items[@intFromEnum(block)].appendSlice(l.scratch, stmts.items);
        if (apart_block) |ab| try st.blocks.items[@intFromEnum(ab)].appendSlice(l.scratch, apart_stmts.items);
        if (row.kind != .lambda) return null;
        return try l.markupValue(body.values.at(body.values.len - 1));
    }

    /// `cx.componentCall`: the props record, built as a record literal is —
    /// keys sorted by name text — or as a record update over the spread,
    /// then the call, with its evidence.
    fn markupComponentCall(l: *Lowerer, node: beni_markup.Node.Index, children: ?Node.Index) Allocator.Error!Node.Index {
        const st = l.mk.?;
        const tree = &st.built.tree;
        const p = st.pos;
        const at = tree.nodes[@intFromEnum(node)].payload;
        const c = tree.components[at];
        const source = st.built.components[at];
        const props = tree.propsOf(c.props);
        var names: std.ArrayList(Symbol) = .empty;
        var values: std.ArrayList(Node.Index) = .empty;
        for (props) |prop| {
            try names.append(l.scratch, try l.interner.getOrPut(l.gpa, tree.string(prop.field)));
            try values.append(l.scratch, try l.markupValue(prop.value));
        }
        const children_value: ?Node.Index = if (c.children) |v| try l.markupValue(v) else children;
        if (children_value) |v| {
            try names.append(l.scratch, try l.interner.getOrPut(l.gpa, "children"));
            try values.append(l.scratch, v);
        }
        var properties: std.ArrayList(Node.Index) = .empty;
        if (c.spread) |spread| {
            try properties.append(l.scratch, try l.add(.spread_property, p, (try l.markupValue(spread)).int(), Node.Data.unused));
            for (names.items, values.items) |n, v| try properties.append(l.scratch, try l.fieldProperty(n, v, p));
        } else {
            for (try l.fieldOrder(names.items)) |i| try properties.append(l.scratch, try l.fieldProperty(names.items[i], values.items[i], p));
        }
        const args = [_]Node.Index{try l.object(properties.items, p)};
        if (try l.referenceApplied(source.callee, &args)) |called| return called;
        return l.call(try l.reference(source.callee), &args, p);
    }

    /// A markup runtime export the lowering declared, imported under
    /// `$markup$<name>`, or a markup primitive, imported under the name its
    /// module gives it: `boundary.md` §9.4.5's union, one import per export
    /// used.
    fn markupImport(l: *Lowerer, export_name: Symbol, local: JsIr.Name) Allocator.Error!JsIr.NameIndex {
        const imported = try l.name(.{ .module = .none, .base = export_name, .tag = JsIr.Name.no_tag });
        const n = try l.name(local);
        for (l.markup_imports.items) |spec| {
            if (spec.imported == imported) return spec.local;
        }
        try l.markup_imports.append(l.scratch, .{ .imported = imported, .local = n });
        // A copy: the pool the name is in may grow and move before the
        // list is read.
        try l.markup_exports.append(l.scratch, try l.scratch.dupe(u8, l.interner.slice(export_name)));
        return n;
    }

    /// The runtime module's value that supplies the runtime export
    /// `export_name`, recorded as used, or null when the file supplies it
    /// (`backend.md` §15.1, *The runtime module*).
    fn suppliedName(l: *Lowerer, export_name: []const u8) Allocator.Error!?JsIr.NameIndex {
        const mk = l.in.markup orelse return null;
        const module = mk.module orelse return null;
        for (mk.supplied) |s| {
            if (!std.mem.eql(u8, s.name, export_name)) continue;
            var known = false;
            for (l.markup_module_uses.items) |u| known = known or std.mem.eql(u8, u, s.name);
            if (!known) try l.markup_module_uses.append(l.scratch, s.name);
            if (module == l.in.module) return try l.topName(s.decl);
            try l.need(module, s.value);
            return try l.externalName(module, s.value);
        }
        return null;
    }

    fn markupRuntime(l: *Lowerer, export_name: []const u8) (Allocator.Error || error{Reported})!JsIr.NameIndex {
        const st = l.mk.?;
        // An export the runtime module supplies is that module's value
        // (`backend.md` §15.1, *The runtime module*).
        if (try l.suppliedName(export_name)) |n| return n;
        for (st.lowering.runtime) |declared| {
            if (!std.mem.eql(u8, declared.name, export_name)) continue;
            const base = try l.interner.getOrPut(l.gpa, export_name);
            const module = try l.interner.getOrPut(l.gpa, "$markup");
            return l.markupImport(base, JsIr.Name.qualified(module, base));
        }
        try l.report(.internal, l.region, "The markup lowering `{s}` imports `{s}`, which it does not declare among its runtime's exports.", .{ st.lowering.name, export_name });
        return error.Reported;
    }

    /// The name a use of a markup primitive reads: the markup runtime's
    /// export of that name (`boundary.md` §9.3), never the vocabulary
    /// module's — the runtime module's value when it supplies the
    /// primitive (§9.2, *A runtime module*).
    fn primitiveName(l: *Lowerer, module: Symbol, base: Symbol) Allocator.Error!JsIr.NameIndex {
        if (try l.suppliedName(l.interner.slice(base))) |n| return n;
        return l.markupImport(base, JsIr.Name.qualified(module, base));
    }

    fn reportRestructured(l: *Lowerer, node: beni_markup.Node.Index, message: []const u8) Allocator.Error!void {
        const st = l.mk.?;
        const owned = try l.gpa.dupe(u8, message);
        errdefer l.gpa.free(owned);
        try l.diagnostics.append(l.gpa, .{
            .code = .markup_restructured,
            .module = l.in.module,
            .region = l.region,
            .token = st.built.node_tokens[@intFromEnum(node)],
            .message = owned,
        });
    }
};

/// What the compiler keeps while it lowers one module's markup.
const MarkupState = struct {
    built: MarkupTree.Built,
    lowering: *const beni_markup.Lowering,
    cx: beni_markup.Context,
    /// Per value slot, what an evaluated instruction is bound to.
    bound: []Bound,
    /// The lowering's statement lists, by `Block` handle.
    blocks: std.ArrayList(StmtList) = .empty,
    /// The module-level declarations the lowering hoisted, in hoist order.
    hoisted: std.ArrayList(Node.Index) = .empty,
    /// The start data the lowering contributed.
    start: std.ArrayList(StartPair) = .empty,
    /// The names earlier hoists took, by name index.
    taken: std.DynamicBitSetUnmanaged = .{},
    /// The module's declarations' names, as sorted symbols: a hoist's
    /// untagged name may not be one of theirs.
    decl_names: []const u32 = &.{},
    /// Where the JavaScript being built is positioned (`cx.at`).
    pos: u32 = Node.no_pos,
};

/// One pair of program start data (`boundary.md` §9.4.5).
pub const StartPair = struct { key: []const u8, value: []const u8 };

const Bound = union(enum) {
    none,
    /// A name the value is read by.
    name: JsIr.NameIndex,
    /// A literal, copied at every use.
    node: Node.Index,
};

/// The `Context` and `Js` of `boundary.md` §9.4.3, over one `Lowerer`.
const markup_vtable: beni_markup.VTable = struct {
    const M = beni_markup;
    const E = M.Error;

    fn lowerer(impl: *anyopaque) *Lowerer {
        return @ptrCast(@alignCast(impl));
    }

    fn expr(n: Node.Index) M.Expr {
        return @enumFromInt(n.int());
    }

    fn node(e: M.Expr) Node.Index {
        return @enumFromInt(@intFromEnum(e));
    }

    fn nameOf(n: M.Name) JsIr.NameIndex {
        return @enumFromInt(@intFromEnum(n));
    }

    fn pos(l: *Lowerer) u32 {
        return l.mk.?.pos;
    }

    fn symbolOf(l: *Lowerer, text: []const u8) E!Symbol {
        return l.interner.getOrPut(l.gpa, text);
    }

    fn at(impl: *anyopaque, n: M.Node.Index) void {
        const l = lowerer(impl);
        const st = l.mk.?;
        const token = st.built.node_tokens[@intFromEnum(n)];
        st.pos = if (token < l.in.token_starts.len) l.in.token_starts[token] else Node.no_pos;
    }

    fn fresh(impl: *anyopaque, hint: []const u8) E!M.Name {
        const l = lowerer(impl);
        return @enumFromInt(@intFromEnum(try l.fresh(try symbolOf(l, hint))));
    }

    /// A module-level name `<Module>$<hint>`, told apart by a tag when the
    /// module already declares or hoisted that name — a declaration called
    /// `k7` is `<Module>$k7` too.
    fn hoistName(l: *Lowerer, hint: []const u8) E!JsIr.NameIndex {
        const st = l.mk.?;
        const base = try symbolOf(l, hint);
        const declared = std.sort.binarySearch(u32, st.decl_names, @intFromEnum(base), struct {
            fn order(key: u32, item: u32) std.math.Order {
                return std.math.order(key, item);
            }
        }.order) != null;
        var tag: u32 = if (declared) 1 else JsIr.Name.no_tag;
        while (true) : (tag += 1) {
            const n = try l.name(.{ .module = l.module_name.toOptional(), .base = base, .tag = tag });
            if (n.int() < st.taken.bit_length and st.taken.isSet(n.int())) continue;
            try takeName(l, n);
            return n;
        }
    }

    fn takeName(l: *Lowerer, n: JsIr.NameIndex) E!void {
        const st = l.mk.?;
        if (n.int() >= st.taken.bit_length) try st.taken.resize(l.scratch, @max(n.int() + 1, st.taken.bit_length * 2), false);
        st.taken.set(n.int());
    }

    fn hoist(impl: *anyopaque, hint: []const u8, init: M.Expr) E!M.Name {
        const l = lowerer(impl);
        const n = try hoistName(l, hint);
        try l.mk.?.hoisted.append(l.scratch, try l.add(.const_decl, pos(l), @intFromEnum(n), node(init).int()));
        return @enumFromInt(@intFromEnum(n));
    }

    fn hoistFunction(impl: *anyopaque, hint: []const u8, params: []const M.Name, body: M.Block) E!M.Name {
        const l = lowerer(impl);
        const n = try hoistName(l, hint);
        const record = try l.funcRecord(@ptrCast(params), l.mk.?.blocks.items[@intFromEnum(body)].items);
        try l.mk.?.hoisted.append(l.scratch, try l.add(.func_decl, pos(l), @intFromEnum(n), @intFromEnum(record)));
        return @enumFromInt(@intFromEnum(n));
    }

    fn hoisted(impl: *anyopaque, hint: []const u8) ?M.Name {
        const l = lowerer(impl);
        const base = l.interner.find(hint) orelse return null;
        for (l.mk.?.hoisted.items) |stmt| {
            const n: JsIr.NameIndex = @enumFromInt(l.b.nodes.items(.data)[stmt.int()].lhs);
            const hoist_name = l.b.names.items[n.int()];
            if (hoist_name.module == l.module_name.toOptional() and hoist_name.base == base) return @enumFromInt(@intFromEnum(n));
        }
        return null;
    }

    fn runtime(impl: *anyopaque, export_name: []const u8) E!M.Name {
        const l = lowerer(impl);
        return @enumFromInt(@intFromEnum(try l.markupRuntime(export_name)));
    }

    fn value(impl: *anyopaque, v: M.Value.Index) E!M.Expr {
        const l = lowerer(impl);
        return expr(try l.markupValue(v));
    }

    fn rowValues(impl: *anyopaque, into: M.Block, row: M.Row.Index, item: M.Name, position: ?M.Name, captures: []const M.Name) E!?M.Expr {
        const l = lowerer(impl);
        const result = try l.markupRowValues(into, null, row, item, position, captures, &.{});
        return if (result) |n| expr(n) else null;
    }

    fn rowValuesApart(impl: *anyopaque, into: M.Block, apart_into: M.Block, row: M.Row.Index, item: M.Name, position: ?M.Name, captures: []const M.Name, apart: []const M.Value.Index) E!?M.Expr {
        const l = lowerer(impl);
        const result = try l.markupRowValues(into, apart_into, row, item, position, captures, apart);
        return if (result) |n| expr(n) else null;
    }

    fn componentCall(impl: *anyopaque, n: M.Node.Index, children: ?M.Expr) E!M.Expr {
        const l = lowerer(impl);
        return expr(try l.markupComponentCall(n, if (children) |c| node(c) else null));
    }

    /// An event's payload extractor, as a `foreign` of the vocabulary
    /// module, imported as any other module's value is. Reachability keeps
    /// it alive through the markup leg of `check/Edges.zig`
    /// (`checker-v2.md` §25.7).
    fn extractor(impl: *anyopaque, item_index: u32) E!?M.Expr {
        const l = lowerer(impl);
        const st = l.mk.?;
        const it = st.built.tree.items[item_index];
        if (it.kind != .event or it.event == .none) return null;
        if (!st.built.tree.eventFacts(it.event).has_extractor) return null;
        const extractor_value = st.built.extractors[item_index];
        const module = l.in.graph.markup.vocabulary orelse return null;
        if (extractor_value == Dispatch.Markup.no_row) return null;
        try l.need(module, extractor_value);
        return expr(try l.ident(try l.externalName(module, extractor_value), pos(l)));
    }

    /// `Maybe`'s representation is `{ $: "Just" | "Nothing", a }` with the
    /// payload slot padded to `null` in `Nothing` (`CtorRep.tagged`), so the
    /// payload is `.a`, and `Just ()` — whose payload is `null` too — is
    /// told from `Nothing` only by the tag.
    fn maybe(impl: *anyopaque, e: M.Expr) E!M.Expr {
        const l = lowerer(impl);
        return expr(try l.member(node(e), try l.slotName(0), pos(l)));
    }

    fn isJust(impl: *anyopaque, e: M.Expr) E!M.Expr {
        const l = lowerer(impl);
        const p = pos(l);
        const tag = try l.member(node(e), l.well.tag, p);
        // `Just`'s tag as the build writes it: its name, or its index when
        // `Maybe` has integer tags (`backend.md` §9, *Item 4, taken up*).
        const just = if (l.integerTags(l.in.types.well_known.maybe)) try l.intNode(0, p) else try l.stringNode("Just", p);
        return expr(try l.binary(.strict_eq, tag, just, p));
    }

    fn start(impl: *anyopaque, key: []const u8, val: []const u8) E!void {
        const l = lowerer(impl);
        try l.mk.?.start.append(l.scratch, .{ .key = try l.scratch.dupe(u8, key), .value = try l.scratch.dupe(u8, val) });
    }

    fn report(impl: *anyopaque, n: M.Node.Index, message: []const u8) error{ OutOfMemory, Reported } {
        const l = lowerer(impl);
        try l.reportRestructured(n, message);
        return error.Reported;
    }

    fn literal(impl: *anyopaque, which: M.Literal, bytes: []const u8) E!M.Expr {
        const l = lowerer(impl);
        const p = pos(l);
        return expr(switch (which) {
            .string => try l.stringNode(bytes, p),
            .number => try l.numberNode(bytes, p),
            .true => try l.add(.true_lit, p, Node.Data.unused, Node.Data.unused),
            .false => try l.add(.false_lit, p, Node.Data.unused, Node.Data.unused),
            .null => try l.nullNode(p),
            else => try l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused),
        });
    }

    fn template(impl: *anyopaque, parts: []const M.TemplatePart) E!M.Expr {
        const l = lowerer(impl);
        const p = pos(l);
        var nodes: std.ArrayList(Node.Index) = .empty;
        for (parts) |part| switch (part) {
            .text => |bytes| {
                const offset, const len = try l.b.addString(bytes);
                try nodes.append(l.scratch, try l.add(.template_chunk, p, offset, len));
            },
            .expr => |e| try nodes.append(l.scratch, node(e)),
        };
        const range = try l.b.addRange(nodes.items);
        return expr(try l.add(.template, p, @intFromEnum(range.start), @intFromEnum(range.end)));
    }

    fn name(impl: *anyopaque, n: M.Name) E!M.Expr {
        const l = lowerer(impl);
        return expr(try l.ident(nameOf(n), pos(l)));
    }

    fn call(impl: *anyopaque, callee: M.Expr, args: []const M.Expr) E!M.Expr {
        const l = lowerer(impl);
        return expr(try l.call(node(callee), @ptrCast(args), pos(l)));
    }

    fn member(impl: *anyopaque, target: M.Expr, field: []const u8) E!M.Expr {
        const l = lowerer(impl);
        return expr(try l.member(node(target), try symbolOf(l, field), pos(l)));
    }

    fn index(impl: *anyopaque, target: M.Expr, at_: M.Expr) E!M.Expr {
        const l = lowerer(impl);
        return expr(try l.add(.index_get, pos(l), node(target).int(), node(at_).int()));
    }

    fn object(impl: *anyopaque, properties: []const M.Property) E!M.Expr {
        const l = lowerer(impl);
        const p = pos(l);
        var nodes: std.ArrayList(Node.Index) = .empty;
        for (properties) |prop| try nodes.append(l.scratch, try l.property(try symbolOf(l, prop.key), node(prop.value), p));
        return expr(try l.object(nodes.items, p));
    }

    fn array(impl: *anyopaque, elements: []const M.Expr) E!M.Expr {
        const l = lowerer(impl);
        const range = try l.b.addRange(@ptrCast(elements));
        return expr(try l.add(.array, pos(l), @intFromEnum(range.start), @intFromEnum(range.end)));
    }

    fn arrow(impl: *anyopaque, params: []const M.Name, body: M.Block) E!M.Expr {
        const l = lowerer(impl);
        return expr(try l.arrowOf(@ptrCast(params), l.mk.?.blocks.items[@intFromEnum(body)].items, pos(l)));
    }

    fn cond(impl: *anyopaque, test_: M.Expr, consequent: M.Expr, alternate: M.Expr) E!M.Expr {
        const l = lowerer(impl);
        return expr(try l.condOf(node(test_), node(consequent), node(alternate), pos(l)));
    }

    fn binary(impl: *anyopaque, op: M.BinaryOp, left: M.Expr, right: M.Expr) E!M.Expr {
        const l = lowerer(impl);
        const js_op: JsIr.BinaryOp = switch (op) {
            .strict_eq => .strict_eq,
            .strict_ne => .strict_ne,
            .logical_and => .logical_and,
            .logical_or => .logical_or,
            .add => .add,
            _ => .strict_eq,
        };
        return expr(try l.binary(js_op, node(left), node(right), pos(l)));
    }

    fn unary(impl: *anyopaque, op: M.UnaryOp, operand: M.Expr) E!M.Expr {
        const l = lowerer(impl);
        const js_op: JsIr.UnaryOp = switch (op) {
            .not => .not,
            .type_of => .type_of,
            _ => .not,
        };
        return expr(try l.unary(js_op, node(operand), pos(l)));
    }

    fn block(impl: *anyopaque) E!M.Block {
        const l = lowerer(impl);
        const st = l.mk.?;
        try st.blocks.append(l.scratch, .empty);
        return @enumFromInt(st.blocks.items.len - 1);
    }

    fn statement(impl: *anyopaque, into: M.Block, s: M.Statement) E!void {
        const l = lowerer(impl);
        const st = l.mk.?;
        const p = pos(l);
        const stmt: Node.Index = switch (s) {
            .constant => |c| try l.add(.const_decl, p, @intFromEnum(nameOf(c.name)), node(c.value).int()),
            .let => |c| try l.add(.let_decl, p, @intFromEnum(nameOf(c.name)), if (c.value) |v| node(v).int() else @intFromEnum(Node.OptionalIndex.none)),
            .assign => |a| try l.add(.assign_stmt, p, node(a.target).int(), node(a.value).int()),
            .@"if" => |i| blk: {
                const then_range = try l.b.addRange(st.blocks.items[@intFromEnum(i.then)].items);
                const else_range = if (i.otherwise) |o| try l.b.addRange(st.blocks.items[@intFromEnum(o)].items) else JsIr.SubRange.empty;
                const record = try l.b.addRecord(JsIr.If{
                    .then_start = then_range.start,
                    .then_end = then_range.end,
                    .else_start = else_range.start,
                    .else_end = else_range.end,
                });
                break :blk try l.add(.if_stmt, p, node(i.condition).int(), @intFromEnum(record));
            },
            .@"return" => |r| try l.add(.return_stmt, p, if (r) |v| @intFromEnum(node(v).toOptional()) else @intFromEnum(Node.OptionalIndex.none), Node.Data.unused),
            .expression => |e| try l.add(.expr_stmt, p, node(e).int(), Node.Data.unused),
            .block => |inner| blk: {
                const range = try l.b.addRange(st.blocks.items[@intFromEnum(inner)].items);
                const record = try l.b.addRecord(range);
                break :blk try l.add(.block_stmt, p, @intFromEnum(JsIr.NameIndex.none), @intFromEnum(record));
            },
        };
        try st.blocks.items[@intFromEnum(into)].append(l.scratch, stmt);
    }

    const vtable: beni_markup.VTable = .{
        .at = at,
        .fresh = fresh,
        .hoist = hoist,
        .hoist_function = hoistFunction,
        .hoisted = hoisted,
        .runtime = runtime,
        .value = value,
        .row_values = rowValues,
        .row_values_apart = rowValuesApart,
        .component_call = componentCall,
        .extractor = extractor,
        .maybe = maybe,
        .is_just = isJust,
        .start = start,
        .report = report,
        .literal = literal,
        .template = template,
        .name = name,
        .call = call,
        .member = member,
        .index = index,
        .object = object,
        .array = array,
        .arrow = arrow,
        .cond = cond,
        .binary = binary,
        .unary = unary,
        .block = block,
        .statement = statement,
    };
}.vtable;

// ---------------------------------------------------------------------------
// Tests
//
// Lowering is exercised through the REAL pipeline over sources in memory and
// asserted on the emitted JavaScript, the same shape `check/Check.zig` uses
// for types and for the same reason: the bytes are the only thing a person
// can read, and asserting the `JsIr` node graph instead would test an
// implementation that the optimiser is free to rewrite.
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
    \\pub foreign pure add : number, number -> number
    \\
    \\
    \\pub foreign pure sub : number, number -> number
    \\
    \\
    \\pub foreign pure mul : number, number -> number
    \\
    \\
    \\pub foreign pure lt : number, number -> Bool
    \\
    \\
    \\pub foreign pure eq : equatable a, a -> Bool
    \\
    \\
    \\pub foreign pure and : Bool, Bool -> Bool
    \\
    \\
    \\pub foreign pure or : Bool, Bool -> Bool
    \\
    \\
    \\pub foreign pure append : appendable, appendable -> appendable
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
    \\pub foreign pure cons : a, List a -> List a
    \\
    \\
    \\pub foreign pure foldl : (a, b -> b), b, List a -> b
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
    .{ .path = "String.beni", .package = .core, .source = "pub equatable foreign type String\n\n\npub foreign pure fromInt : Int -> String\n" },
    .{ .path = "Char.beni", .package = .core, .source = "pub equatable foreign type Char\n\n\npub foreign pure isDigit : Char -> Bool\n" },
    .{ .path = "Debug.beni", .package = .core, .source = "pub foreign pure todo : String -> a\n" },
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
    const tokens = session.artifacts.spans(file);

    var overlay: InternPool.Overlay = .init(&session.interner);
    defer overlay.deinit(gpa);
    var result = try lower(gpa, arena, &overlay, .{
        .bir = session.artifacts.bir(file),
        .token_starts = tokens.starts,
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
    return Print.print(gpa, arena, &result.ir, .fromOverlay(&overlay), .{});
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
        \\const M$one = 1;
        \\const M$plus = (a$1, b$2) => a$1 + b$2;
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
        \\const M$plus = (a$1, b$2) => a$1 + b$2;
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
    // still gets the slot, in the one module-level constant every use of it
    // reads (`backend.md` §4, *A nullary constructor is one object*).
    try expectJs(
        \\const M$None = { $: "None", a: null };
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
        \\const M$none = M$None;
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

test "a record's keys are sorted, and a list is an array" {
    try expectJs(
        \\const M$point = { x: 1, y: 2 };
        \\const M$xs = [1, 2];
        \\const M$none = [];
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
        \\const M$f = (n$1) => {
        \\  const doubled$2 = n$1 * 2;
        \\  function step$3(x$4) {
        \\    return x$4 + doubled$2;
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
        \\const M$apply = (f$1, x$2) => f$1(x$2);
        \\const M$answer = M$apply((a$1) => a$1 + 1, 1);
        \\const M$twice = M$apply((b$1) => b$1 * 2, 21);
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
        \\    apply (λa -> a + 1) 1
        \\
        \\
        \\pub twice : Int
        \\twice =
        \\    apply (λb -> b * 2) 21
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
    // Both bodies make a function — `inner`, and the lambda inside it — so
    // both keep §8's copies (*In place, when nothing captures*); neither
    // needs a label, since each `continue` reaches its own function's loop.
    try expectJs(
        \\const M$outer = ($in$0, $in$1) => {
        \\  for (;;) {
        \\    const n$1 = $in$0;
        \\    const acc$2 = $in$1;
        \\    if (n$1 < 1) {
        \\      return acc$2;
        \\    } else {
        \\      function inner$3($in$0, $in$1) {
        \\        for (;;) {
        \\          const i$4 = $in$0;
        \\          const total$5 = $in$1;
        \\          if (i$4 < 1) {
        \\            return total$5;
        \\          } else {
        \\            $in$0 = i$4 - 1;
        \\            $in$1 = ((x$6) => x$6 + i$4)(total$5);
        \\          }
        \\        }
        \\      }
        \\      $in$0 = n$1 - 1;
        \\      $in$1 = inner$3(3, acc$2);
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
        \\                    inner (i - 1) ((λx -> x + i) total)
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
        \\pub foreign pure now : Float
        \\
        \\
        \\pub foreign pure twice : Int -> Int
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

test "a `?` the table has no shape for is a bug, not a wrong answer" {
    // The one `?` path no program can reach, and therefore the one this
    // suite owns: `checker.md` §6.5 records the shape its speculation
    // settled on, a `?` that settled on neither is `try_shape` and refuses
    // the build, so a `?` reaching the emitter with no row means two
    // records disagree. A SYNTHETIC empty table is the only way to produce
    // one, which is why this is in-source (CLAUDE.md rule 3); the shapes it
    // does record are `run/Question*.beni` and `emit/QuestionShape.js`.
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
    var overlay: InternPool.Overlay = .init(&session.interner);
    defer overlay.deinit(gpa);
    var result = try lower(gpa, arena, &overlay, .{
        .bir = session.artifacts.bir(file),
        .token_starts = session.artifacts.spans(file).starts,
        .module = m,
        .graph = &session.graph,
        .interfaces = session.resolution.interfaces,
        .dispatch = &Dispatch.empty,
        .types = &session.checked.types,
        .specifiers = specifiers,
        .sibling = "",
    });
    defer result.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try testing.expectEqual(diagnostic.Code.internal, result.diagnostics[0].code);
}

test "the evidence-count assert counts the roots and every term's arguments, in both directions" {
    // A SYNTHETIC `Dispatch` table, and that is the whole reason this test
    // is in-source rather than in `tests/corpus/` (CLAUDE.md rule 3 makes
    // the corpus the coverage and this the supplement it cannot reach):
    // once the checker is right, NO beni program can produce a malformed
    // table, so the only way to prove the wall stops one is to build one by
    // hand (checker-v2.md §13.3: `evidenceShapeOk` is the evidence-count assert).
    //
    // What it pins is §7.2's promise that a caller/callee disagreement is
    // "a caught bug rather than a silent miscompile". Two roots for a
    // one-evidence callee once emitted a three-argument call of a
    // two-parameter function — JavaScript RUNS that — which printed `NaN`
    // and then recursed forever, and zero roots for a two-evidence callee
    // threw `TypeError: $m$0 is not a function`. The build exited 0 both
    // times.
    const requirements = [_]Dispatch.Requirement{
        .{ .quantified = 0, .var_name = .none, .method = @enumFromInt(0) },
    };
    // Declaration 0 takes one evidence parameter of its own; declaration 1
    // takes none. Nothing else about either is read.
    const decls = [_]Dispatch.DeclInfo{ .{ .requirements = .{ .start = 0, .len = 1 } }, .{} };
    // Term 0: `top 1`, no arguments — right. Term 1: `top 0` applied to
    // term 2 — right. Term 2: `top 1`. Term 3: `top 0` with NO argument —
    // one short. Term 4: `field`, which is never evidence. Term 5:
    // `undetermined`. Term 6: `top 0` whose argument points BACK at itself.
    const terms = [_]Dispatch.Term{
        .{ .top = .{ .decl = @enumFromInt(1) } },
        .{ .top = .{ .decl = @enumFromInt(0), .args = .{ .start = 0, .len = 1 } } },
        .{ .top = .{ .decl = @enumFromInt(1) } },
        .{ .top = .{ .decl = @enumFromInt(0) } },
        .field,
        .undetermined,
        .{ .top = .{ .decl = @enumFromInt(0), .args = .{ .start = 1, .len = 1 } } },
    };
    const args = [_]Dispatch.TermIndex{ @enumFromInt(2), @enumFromInt(6) };
    const table: Dispatch = .{ .terms = &terms, .args = &args, .decls = &decls, .requirements = &requirements };
    const types: Types = .empty;

    // `evidenceShapeOk` is a predicate over the table and reads
    // `in.dispatch`, `in.interfaces` and `in.types` and nothing else, which
    // is what makes a synthetic table enough and the rest of the `Lowerer`
    // unnecessary.
    var l: Lowerer = undefined;
    l.in.dispatch = &table;
    l.in.interfaces = &.{};
    l.in.types = &types;
    // Handed through to the table's queries and never read for this table.
    const global: InternPool.Global = .{};
    var overlay: InternPool.Overlay = .init(&global);
    l.interner = &overlay;
    // `termShapeOk` reads what `readTable` judged once, bottom-up.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    l.scratch = arena.allocator();
    try l.readTable();

    const t = struct {
        fn at(i: u32) Dispatch.TermIndex {
            return @enumFromInt(i);
        }
    }.at;

    // One root for a one-evidence callee, and none for a callee with none.
    try testing.expect(l.evidenceShapeOk(&.{t(0)}, 1));
    try testing.expect(l.evidenceShapeOk(&.{}, 0));
    // TOO MANY roots: each is well formed, one more than the callee has
    // parameters for.
    try testing.expect(!l.evidenceShapeOk(&.{ t(0), t(0) }, 1));
    try testing.expect(!l.evidenceShapeOk(&.{t(0)}, 0));
    // TOO FEW.
    try testing.expect(!l.evidenceShapeOk(&.{t(0)}, 2));
    try testing.expect(!l.evidenceShapeOk(&.{}, 1));
    // NESTING: a constrained term carries its own argument (A.25), and the
    // count is the callee's — accepted with its one argument, refused
    // without it.
    try testing.expect(l.evidenceShapeOk(&.{t(1)}, 1));
    try testing.expect(!l.evidenceShapeOk(&.{t(3)}, 1));
    // `field` cannot stand in evidence position, whatever the count says;
    // `undetermined` can (checker-v2.md §13.1).
    try testing.expect(!l.evidenceShapeOk(&.{t(4)}, 1));
    try testing.expect(l.evidenceShapeOk(&.{t(5)}, 1));
    // An argument that does not follow its owner is a cycle, refused
    // before any walk could spin on it.
    try testing.expect(!l.evidenceShapeOk(&.{t(6)}, 1));
}

test "a derived function with no body is a table bug in value position, either kind" {
    // A SYNTHETIC `Dispatch` table, for the reason the test above gives and
    // one more: no beni program reaches this arm. The checker refuses `eq`
    // and `compare` on a type no module writes a body for before the
    // backend is ever asked (§3.3, A.54 —
    // `tests/corpus/check/bad/CompareOnTypeHoldingFunction` and
    // `check/bad/core/CompareOnWrappedForeign` are the fixtures), so a
    // term with no body can only come from a table the checker did not
    // write, and only a hand-built one can show what the emitter does with
    // it. That is why there is no corpus fixture beside this test.
    //
    // **What changed with S6b.** This used to assert A.51's door: a missing
    // `eq` whose parts were all structural was answered with
    // `core/Basics.js`'s walk instead of refused. §5.2 gives `List` both
    // methods, `equatable` is core's alone, and the door has no customer
    // left. Both kinds are now `internal` — nothing is MISSING, the table
    // is WRONG — and the test asserts that symmetry.
    const gpa = testing.allocator;
    const terms = [_]Dispatch.Term{
        .{ .ext_derived = .{ .module = @enumFromInt(0), .type = .none, .kind = .compare } },
        // A `derived` row that is not in the table at all.
        .{ .derived = .{ .index = 0 } },
        // The `eq` that used to go through A.51's door.
        .{ .ext_derived = .{ .module = @enumFromInt(0), .type = .none, .kind = .eq } },
    };
    const table: Dispatch = .{ .terms = &terms };
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
    l.shared = &.{};
    l.shape_ok = &.{};
    l.bodies_ok = &.{};
    l.bound = .{};
    l.bound_out = null;
    l.in.interfaces = &.{};
    l.in.module = @enumFromInt(0);
    l.diagnostics = .empty;
    l.region = @enumFromInt(0);
    defer {
        for (l.diagnostics.items) |d| gpa.free(d.message);
        l.diagnostics.deinit(gpa);
    }

    _ = try l.derivedValue(@enumFromInt(0), Node.no_pos);
    try testing.expectEqual(@as(usize, 1), l.diagnostics.items.len);
    try testing.expectEqual(diagnostic.Code.internal, l.diagnostics.items[0].code);
    try testing.expect(std.mem.indexOf(
        u8,
        l.diagnostics.items[0].message,
        "a derived method of a type whose module emits no",
    ) != null);

    _ = try l.derivedValue(@enumFromInt(1), Node.no_pos);
    try testing.expectEqual(@as(usize, 2), l.diagnostics.items.len);
    try testing.expectEqual(diagnostic.Code.internal, l.diagnostics.items[1].code);

    _ = try l.derivedValue(@enumFromInt(2), Node.no_pos);
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
