//! Pattern usefulness: does a `case` have a branch for every possibility, and
//! is any of its branches unreachable (docs/design/checker.md §6.6).
//!
//! The algorithm is Maranget's ("Warnings for Pattern Matching", §3 — the
//! `U(P, q)` usefulness relation and the `I(P, n)` missing-vector
//! construction), in the shape Elm gives it in
//! `Nitpick/PatternMatches.hs`, because the error message we want is Elm's.
//! Two relations, both over a MATRIX of pattern rows:
//!
//!   - `isUseful(matrix, vector)` — can `vector` match a value none of the
//!     rows above it match? A branch that is not useful is
//!     `redundant_pattern`.
//!   - `isExhaustive(matrix, n)` — the value vectors of width `n` that no
//!     row matches, i.e. the counterexamples. A non-empty answer is
//!     `missing_patterns`, and the answer itself is what the message prints.
//!
//! **Patterns are simplified first** (`simplify`), into three shapes and
//! nothing else: `anything` (a wildcard, a variable, a record pattern —
//! records have no alternatives, so matching one always succeeds), a
//! `literal`, or a `ctor` of a known *union*. Everything structural becomes
//! a constructor of a one- or two-alternative union invented here: `()` is
//! the sole constructor of a unit union, an n-tuple the sole constructor of
//! a tuple union, and a list is `[]`/`::`, which is what makes `[ a, b ]`
//! and `x :: xs` one language rather than two cases in the algorithm. The
//! three-way split is the whole reason the algorithm is short: a column
//! either has a finite set of alternatives (then "did we see all of them?"
//! is a count) or it has infinitely many (`Int`, `Float`, `Char`, `String`
//! literals — a wildcard is then the only way to be exhaustive).
//!
//! **A constructor's union comes from its type declaration**: for a
//! constructor of this module, from the declaring `type`'s `Bir.ctors`
//! range; for an imported one, from the importing side's `Interface`, which
//! keeps a type's constructors adjacent and in declaration order for
//! exactly this. Going through the interface and not the dependency's Bir is
//! the firewall of `fast-compiler.md` §8.1: in M4 a dependency's Bir may not
//! be in memory at all, and its interface always is.
//!
//! **Nothing here reads a solved type**, and that is not an oversight. The
//! only question the algorithm asks about a column is "what is the full set
//! of alternatives here?", and it asks it only of a column that already
//! contains a constructor pattern — from which the union is known exactly.
//! A column of nothing but wildcards is exhaustive whatever its type is, and
//! a column of literals is inexhaustive whatever its type is. The scrutinee's
//! `Var` would therefore change no answer, and reading it would mean
//! instantiating every constructor's argument types at every nested
//! position for no gain. What the solved types ARE needed for is the
//! PRECONDITION: this runs only over declarations that produced no type
//! error, so every column is known to be one type's constructors and the
//! "constructors and literals never align" invariant holds. A declaration
//! that failed to check is skipped, exactly as §6.6 requires.
//!
//! **An opaque imported type has no visible constructors**, so a `case` on
//! one can only use a variable or a wildcard — and both are `anything`, so
//! such a `case` is exhaustive and reports nothing. That falls out; there is
//! no special case for it.
//!
//! **The budget.** Usefulness is exponential in the worst case (Maranget
//! §3.3), and a `case` over many constructors with many branches reaches it.
//! Every recursive step and every row of every specialisation spends from a
//! fixed budget; when it runs out the analysis stops rather than hanging, and
//! it says so — `pattern_budget_exhausted`, an ERROR, at the `case` it could
//! not decide (checker.md §6.6). Silence was the old answer and it was the
//! one remaining exit-0 path to a wrong answer: `backend.md` §7's decision
//! tree emits no default arm because "the checker proved exhaustiveness", so
//! a `case` the checker never decided compiles to a tree that falls into its
//! last edge. Every other guard in this checker that gives up reports first
//! (checker.md §5); this one now does too.
//!
//! An undecided `case` is not the same as an UNREADABLE one. A poisoned
//! reference or a constructor whose arity does not match its declaration
//! means the matrix is not what this file thinks it is — a precondition
//! failure, not a cost — and those still report nothing, because the author
//! has already been told about them somewhere else.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Arena = @import("../Arena.zig");
const Artifacts = @import("../Artifacts.zig");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Diagnostics = @import("Diagnostics.zig");
const Render = @import("Render.zig");
const Types = @import("Types.zig");
const diagnostic = @import("diagnostic");

const Exhaustive = @This();

pub const Symbol = InternPool.Symbol;

/// How many counterexamples a `missing_patterns` message prints
/// (checker.md §6.6: "up to three example patterns").
pub const max_examples = 3;

/// Row visits and recursive steps one `case` may spend before it is
/// refused.
///
/// **Measured, not guessed**, and re-measured on 2026-09-18 when exhaustion
/// stopped being silent — a number that only ever cost a warning is one
/// nobody checks, and the old note here was wrong about the headroom. Turning
/// the budget down until the answers change:
///
///   - the costliest `case` in `core/` spends **70**;
///   - the costliest in `bench/corpus`, about **420**;
///   - the costliest fixture in `tests/corpus` — `parse/good/ManyBranches`,
///     100 branches on `Int` literals plus a wildcard — about **10,500**.
///
/// So nothing written in this repository is within a factor of nineteen of
/// the budget. The headroom above that is smaller than it looks, because the
/// cost is **quadratic in the branch count with no nesting at all**:
/// `isUseful` runs each branch against the matrix of the branches above it,
/// so n branches cost about 1.05·n² even when every column is one literal
/// wide. Measured: ~440 `Int`-literal branches, or ~310 constructors of one
/// type matched flat, reach 200,000. Maranget §3.3's exponent is real but it
/// is not what a table-driven program meets first.
///
/// Both searches stop early — `isUseful` at the first useful alternative and
/// `isExhaustive` at `max_examples` counterexamples — which is why the
/// quadratic term dominates in practice.
///
/// If the refusal starts firing on code people mean, **the budget is what to
/// fix** (Maranget §4's optimisations, or a bigger number here), not the
/// message: `--pattern-budget=<n>` exists so that an author who meets it is
/// not stuck while that happens.
pub const default_budget: u32 = 200_000;

/// How deeply the recursion may nest. `budget` alone bounds the total work
/// but not the STACK, and the failure mode of an unbounded stack is a
/// segfault rather than a missing warning.
///
/// It is refused like the budget: a `case` that nests deeper than this is one
/// the analysis did not decide, so it is `pattern_budget_exhausted` and not
/// silence. It gets that code's OTHER message, the one that does not mention
/// `--pattern-budget` — the budget is not what stopped it and raising it
/// would not help. The depth is a nesting depth of PATTERNS — 512 `Just (Just
/// (…))` — so no program a person writes comes near it.
const max_depth: u32 = 512;

/// Why the analysis stopped early. Three answers, not one:
///
///   - `OverBudget` — the work budget ran out. The matrix was fine; the exact
///     answer was too expensive. `pattern_budget_exhausted`, and the message
///     offers `--pattern-budget=<n>`, which really would help.
///   - `TooDeep` — a pattern nested past `max_depth`. Also
///     `pattern_budget_exhausted`, because it is the same thing to the
///     author (a `case` that was not decided) — but a DIFFERENT message,
///     because raising the budget would not help and saying so would be a
///     lie. The two share a code and not a sentence.
///   - `Malformed` — the patterns do not describe a matrix this algorithm
///     can read: a poisoned reference, a constructor whose type is unknown,
///     an arity that does not match the declaration, a column mixing
///     literals with constructors. Every one of those is a precondition
///     failure that some earlier phase already reported, so this one stays
///     silent rather than adding a second, misleading message about budget.
///
/// An irrefutable position collapses all three into its own refusal: there
/// the answer that matters is "not proven", however it failed to be proven.
const Abort = error{ OverBudget, TooDeep, Malformed };

pub const Error = Allocator.Error;
const Fail = Allocator.Error || Abort;

// ---------------------------------------------------------------------------
// The simplified pattern language
// ---------------------------------------------------------------------------

/// Index into `Patterns.nodes`.
pub const PatIndex = enum(u32) {
    _,

    pub fn int(p: PatIndex) u32 {
        return @intFromEnum(p);
    }
};

pub const Tag = enum(u8) {
    /// `_`, a variable, a record pattern: matches everything.
    anything,
    /// One of infinitely many values; `lhs` indexes `literals`.
    literal,
    /// One alternative of a finite union. `lhs` indexes `unions`, `rhs` is
    /// an `extra` offset holding `[alt, arg_count, args…]`.
    ctor,
};

/// One node. Three fixed-size columns and one shared sidecar, like every
/// other IR here.
pub const Node = struct {
    tag: Tag,
    lhs: u32,
    rhs: u32,
};

/// Which surface form a union came from, so the renderer can print `( a, b )`
/// and `x :: xs` rather than the invented constructor names Elm uses.
pub const Shape = enum(u8) { adt, unit, tuple, list };

/// A finite set of alternatives: `alts[alts_start..alts_end]`.
pub const Union = struct {
    shape: Shape,
    /// The declared type, for identity. `.none` only for the invented
    /// unions, which are identified by `shape` and arity instead.
    type: Types.TypeId,
    alts_start: u32,
    alts_end: u32,

    pub fn count(u: Union) u32 {
        return u.alts_end - u.alts_start;
    }
};

pub const Alt = struct {
    /// The constructor's name; `.none` for an invented union's alternative,
    /// which the renderer prints structurally.
    name: Symbol.Optional,
    arity: u32,
};

pub const Literal = struct {
    kind: enum(u8) { int, char, string },
    /// `int`: the value, when the spelling fits. `char`: the scalar.
    value: i128 = 0,
    /// `string`, and an `int` whose spelling did not fit `value`: the bytes
    /// in the module's `string_bytes`, as an offset and a length (never a
    /// slice — `Bir`'s rule, and this store outlives no one).
    off: u32 = 0,
    len: u32 = 0,
    /// False for an `int` whose spelling overflowed `value`: compare the
    /// spelling instead. Two spellings of one number then look different,
    /// which can only ever cost a warning, never invent one.
    parsed: bool = true,

    /// Through `Patterns.bytesOf` and never `string_bytes` directly:
    /// `off`/`len` come from `Bir`, and the invariant that they stay inside
    /// the module's `string_bytes` (`Lower.checkBytes`, fuzz-asserted) is
    /// one held a file away. `bytesOf` re-checks it here, so a spelling
    /// comparison cannot become an out-of-bounds slice if that invariant
    /// ever moves.
    pub fn eql(a: Literal, b: Literal, p: *const Patterns) bool {
        if (a.kind != b.kind) return false;
        return switch (a.kind) {
            .char => a.value == b.value,
            .int => if (a.parsed and b.parsed)
                a.value == b.value
            else
                a.parsed == b.parsed and std.mem.eql(u8, p.bytesOf(a), p.bytesOf(b)),
            .string => std.mem.eql(u8, p.bytesOf(a), p.bytesOf(b)),
        };
    }
};

/// The flat store every simplified pattern lives in. Arena-backed and
/// thrown away with the `case` it was built for.
pub const Patterns = struct {
    nodes: std.MultiArrayList(Node) = .empty,
    /// Constructor argument lists, as `[alt, arg_count, args…]`.
    extra: std.ArrayList(u32) = .empty,
    unions: std.ArrayList(Union) = .empty,
    alts: std.ArrayList(Alt) = .empty,
    literals: std.ArrayList(Literal) = .empty,
    /// The module's decoded literal bytes, which `Literal.off` points into.
    string_bytes: []const u8 = &.{},

    pub fn tag(p: *const Patterns, i: PatIndex) Tag {
        return p.nodes.items(.tag)[i.int()];
    }

    pub fn literal(p: *const Patterns, i: PatIndex) Literal {
        return p.literals.items[p.nodes.items(.lhs)[i.int()]];
    }

    /// The union, absolute alternative index and argument RANGE of a `ctor`
    /// node. A range and not a slice, because `extra` grows as the search
    /// builds counterexamples and a slice taken before one of those
    /// appends would point into a freed block. `args` re-slices at the
    /// moment of use, which is the only time it is valid.
    pub fn ctor(p: *const Patterns, i: PatIndex) Ctor {
        const at = p.nodes.items(.rhs)[i.int()];
        return .{
            .un = p.nodes.items(.lhs)[i.int()],
            .alt = p.extra.items[at],
            .args_start = at + 2,
            .args_len = p.extra.items[at + 1],
        };
    }

    /// The arguments of `c`, valid until the next append to `extra`.
    pub fn args(p: *const Patterns, c: Ctor) []const PatIndex {
        return @ptrCast(p.extra.items[c.args_start..][0..c.args_len]);
    }

    pub fn unionAt(p: *const Patterns, index: u32) Union {
        return p.unions.items[index];
    }

    pub fn alt(p: *const Patterns, index: u32) Alt {
        return p.alts.items[index];
    }

    /// The bytes a literal spells, or empty when its range is not inside
    /// this module's. The bound is widened to `u64` first: `off` and `len`
    /// are both `u32` straight out of `Bir`, and adding them in `u32` is
    /// itself a trap in a safe build — the check may not be the thing that
    /// panics.
    pub fn bytesOf(p: *const Patterns, lit: Literal) []const u8 {
        const end = @as(u64, lit.off) + lit.len;
        if (end > p.string_bytes.len) return "";
        return p.string_bytes[lit.off..][0..lit.len];
    }

    pub const Ctor = struct { un: u32, alt: u32, args_start: u32, args_len: u32 };
};

// ---------------------------------------------------------------------------
// The entry point
// ---------------------------------------------------------------------------

/// Everything one module's check needs to reach a constructor's union. A
/// copy of the fields `Constrain.Env` already holds, passed explicitly so
/// this file depends on the module's DATA and not on the constraint
/// generator.
pub const Context = struct {
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []const Interface,
    types: *const Types,
    interner: *const InternPool.Global,
    module: Graph.Index,
    bir: *const Bir,
};

/// Check every `case` of every declaration of `cx.module` that is not
/// skipped, and every pattern of that declaration that sits in an
/// **irrefutable** position (`language.md` §7), reporting through
/// `reporter`.
///
/// `skip` is one flag per declaration: true when an earlier phase or the
/// solver already reported on it, in which case its patterns may not even be
/// well typed and are not analysed (checker.md §6.6). `scratch` is reset
/// once per `case`, so the peak is one `case`'s matrices and not the
/// module's.
///
/// The irrefutable positions are the declaration's own parameters, a
/// `lambda`'s parameters, a `let_def`'s parameters and a `let_pattern`'s
/// pattern. That list is complete because lowering has already run: a `<-`
/// bound pattern IS a lambda parameter by the time BIR exists
/// (`language.md` §6.7, §8), and a `_` placeholder's lambda has a parameter
/// lowering invented, which is a `pat_var` and passes for free.
pub fn run(
    gpa: Allocator,
    scratch: *Arena,
    cx: Context,
    reporter: *Diagnostics.Reporter,
    skip: []const bool,
    budget: u32,
) Error!void {
    if (reporter.quiet) return;
    const bir = cx.bir;
    for (bir.decls, 0..) |d, i| {
        if (i < skip.len and skip[i]) continue;
        // `params_start..params_end` means the TYPE parameter names on a
        // type declaration and pattern instructions only on a value, so
        // the kind is asked first (`Bir.Decl.params_start`).
        if (d.kind == .value) {
            for (bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index)) |param| {
                scratch.reset(.retain_capacity);
                try irrefutable(gpa, scratch.allocator(), cx, reporter, param, .refutable_parameter_pattern, budget);
            }
        }
        var inst = d.inst_start.int();
        while (inst < d.inst_end.int() and inst < bir.insts.len) : (inst += 1) {
            const at: Bir.Inst.Index = @enumFromInt(inst);
            const data = bir.instData(at);
            switch (bir.instTag(at)) {
                .case => {
                    scratch.reset(.retain_capacity);
                    try one(gpa, scratch.allocator(), cx, reporter, at, budget);
                },
                .lambda => for (bir.extraSlice(bir.subRange(@enumFromInt(data.lhs)), Bir.Inst.Index)) |param| {
                    scratch.reset(.retain_capacity);
                    try irrefutable(gpa, scratch.allocator(), cx, reporter, param, .refutable_parameter_pattern, budget);
                },
                .let_def => {
                    const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
                    for (bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Bir.Inst.Index)) |param| {
                        scratch.reset(.retain_capacity);
                        try irrefutable(gpa, scratch.allocator(), cx, reporter, param, .refutable_parameter_pattern, budget);
                    }
                },
                .let_pattern => {
                    scratch.reset(.retain_capacity);
                    try irrefutable(gpa, scratch.allocator(), cx, reporter, @enumFromInt(data.lhs), .refutable_let_pattern, budget);
                },
                else => {},
            }
        }
    }
}

/// One pattern in an irrefutable position: is this single row exhaustive on
/// its own? That is the question a `case` asks of all its rows at once, so
/// it is the same two relations over a one-row, one-column matrix — and
/// single-constructor types, nesting (`Pair (Box a) b`), a type with no
/// constructors at all and an opaque imported type all fall out of it,
/// with no second "how many constructors has this type?" test to disagree
/// with the first.
///
/// **An answer that could not be computed is a refusal**, here and — since
/// queue slice 14 — at a `case` too. The two messages differ because the two
/// ways out differ: this position has no branch to fall through to, so the
/// advice is "`case` on it instead", while a `case` can be split or given a
/// bigger budget. A matrix this file cannot READ (`error.Malformed`) is still
/// a refusal here, because the guarantee `backend.md` §4's unchecked
/// destructure stands on is not one to give away on a defensive path.
fn irrefutable(
    gpa: Allocator,
    arena: Allocator,
    cx: Context,
    reporter: *Diagnostics.Reporter,
    pattern: Bir.Inst.Index,
    code: diagnostic.Code,
    budget: u32,
) Error!void {
    // Almost every parameter ever written is a name, and the parser has
    // already refused every shape that is refutable whatever its type is
    // (`language.md` §7), so a pattern with no constructor anywhere in it
    // is irrefutable and needs no matrix. Skipping those keeps this off the
    // per-declaration cost of a file that never destructures.
    if (!hasCtor(cx.bir, pattern, 0)) return;

    var pats: Patterns = .{ .string_bytes = cx.bir.string_bytes };
    var an: Analysis = .{ .arena = arena, .cx = cx, .pats = &pats, .budget = budget };
    const p = an.simplify(pattern, 0) catch |err| switch (err) {
        error.OverBudget, error.TooDeep, error.Malformed => return reporter.refutablePattern(pattern, code, &.{}),
        else => |e| return e,
    };
    const row = try arena.dupe(PatIndex, &.{p});
    const rows = try arena.dupe([]const PatIndex, &.{row});
    const missing = an.isExhaustive(rows, 1, 0) catch |err| switch (err) {
        error.OverBudget, error.TooDeep, error.Malformed => return reporter.refutablePattern(pattern, code, &.{}),
        else => |e| return e,
    };
    if (missing.len == 0) return;

    var texts: std.ArrayList([]const u8) = .empty;
    defer {
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    for (missing) |m| {
        if (m.len == 0) continue;
        const text = try Render.allocPattern(gpa, &pats, cx.interner, m[0]);
        errdefer gpa.free(text);
        try texts.append(gpa, text);
    }
    // Every row `isExhaustive` returned was empty, which cannot happen for
    // width 1 — but if it ever did, an error with no witness would read as
    // the budget refusal, so say nothing rather than mislead.
    if (texts.items.len == 0) return;
    try reporter.refutablePattern(pattern, code, texts.items);
}

/// Does `pattern` contain a constructor anywhere? The pre-filter above.
/// Too deep counts as yes: the full analysis then abandons and refuses,
/// which is the safe answer for this position.
fn hasCtor(bir: *const Bir, pattern: Bir.Inst.Index, depth: u32) bool {
    if (depth > max_depth) return true;
    if (pattern.int() >= bir.insts.len) return false;
    const data = bir.instData(pattern);
    return switch (bir.instTag(pattern)) {
        .pat_ctor => true,
        .pat_as => hasCtor(bir, @enumFromInt(data.lhs), depth + 1),
        .pat_tuple => for (bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index)) |el| {
            if (hasCtor(bir, el, depth + 1)) break true;
        } else false,
        // The parser rejects these in an irrefutable position whatever the
        // types are, so reaching one means it already reported; there is
        // nothing left for this pass to add.
        else => false,
    };
}

/// One `case`: simplify its branch patterns, find the first redundant one,
/// and otherwise look for counterexamples.
fn one(
    gpa: Allocator,
    arena: Allocator,
    cx: Context,
    reporter: *Diagnostics.Reporter,
    case: Bir.Inst.Index,
    budget: u32,
) Error!void {
    const bir = cx.bir;
    const branches = bir.extraSlice(bir.subRange(@enumFromInt(bir.instData(case).rhs)), Bir.Inst.Index);
    if (branches.len == 0) return; // `case_without_branches` already reported

    var pats: Patterns = .{ .string_bytes = bir.string_bytes };
    var an: Analysis = .{ .arena = arena, .cx = cx, .pats = &pats, .budget = budget };

    // Elm's `toNonRedundantRows`: add one branch at a time and stop at the
    // first that is not useful given the ones above it. Stopping is Elm's
    // behaviour and it is the right one — once a row is dead the rows after
    // it are being judged against a matrix the author did not mean.
    var matrix: std.ArrayList([]const PatIndex) = .empty;
    for (branches, 0..) |b, i| {
        // The PATTERN, not the branch: a redundant branch is a statement
        // about what it matches, so the caret belongs under the pattern.
        const pattern: Bir.Inst.Index = @enumFromInt(bir.instData(b).lhs);
        const p = an.simplify(pattern, 0) catch |err| switch (err) {
            // The `case` is abandoned WHOLE at any of these three sites, and
            // the reason decides what is said. An undecided `case` is
            // REPORTED: the answer was affordable in principle and nothing
            // downstream re-derives it, so silence would be `backend.md`
            // §7's default-free tree running on a `case` nobody checked.
            // `Malformed` stays silent, because the matrix is not what this
            // file thinks it is and some earlier phase has already said so.
            //
            // Neither ever reports a PARTIAL result. A half-searched matrix
            // can no more prove a branch redundant than prove one missing,
            // so what has been found so far is dropped along with the rest.
            error.OverBudget => return reporter.patternBudgetExhausted(case, .budget, budget),
            error.TooDeep => return reporter.patternBudgetExhausted(case, .depth, max_depth),
            error.Malformed => return,
            else => |e| return e,
        };
        const row = try arena.dupe(PatIndex, &.{p});
        const useful = an.isUseful(matrix.items, row, 0) catch |err| switch (err) {
            error.OverBudget => return reporter.patternBudgetExhausted(case, .budget, budget),
            error.TooDeep => return reporter.patternBudgetExhausted(case, .depth, max_depth),
            error.Malformed => return, // silent, by the argument above
            else => |e| return e,
        };
        if (!useful) return reporter.redundantPattern(pattern, @intCast(i + 1));
        try matrix.append(arena, row);
    }

    const missing = an.isExhaustive(matrix.items, 1, 0) catch |err| switch (err) {
        error.OverBudget => return reporter.patternBudgetExhausted(case, .budget, budget),
        error.TooDeep => return reporter.patternBudgetExhausted(case, .depth, max_depth),
        error.Malformed => return, // silent, by the argument above
        else => |e| return e,
    };
    if (missing.len == 0) return;

    var texts: std.ArrayList([]const u8) = .empty;
    defer {
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    for (missing) |row| {
        if (row.len == 0) continue;
        const text = try Render.allocPattern(gpa, &pats, cx.interner, row[0]);
        errdefer gpa.free(text);
        try texts.append(gpa, text);
    }
    try reporter.missingPatterns(case, texts.items);
}

// ---------------------------------------------------------------------------
// Simplification
// ---------------------------------------------------------------------------

const Analysis = struct {
    arena: Allocator,
    cx: Context,
    pats: *Patterns,
    budget: u32,

    /// Charge `amount` to the budget, abandoning the `case` when it runs
    /// out. **Abandoning is `error.OverBudget`, which is reported** (checker.md
    /// §6.6): the budget is only ever reached by a matrix whose exact answer
    /// needs exponential work (`default_budget`'s note measures how far away
    /// that is), and there is no partial answer to report — a half-searched
    /// matrix can no more prove a branch redundant than it can prove one
    /// missing. So the whole `case` is refused, with a message that names the
    /// budget and the two ways past it. The three alternatives are all worse:
    /// a wrong warning, a compiler that does not terminate, or — the one that
    /// was here until queue slice 14 — silence, which hands an unproven
    /// `case` to a decision tree that carries no default arm.
    fn spend(an: *Analysis, amount: usize) Abort!void {
        const cost = std.math.cast(u32, amount) orelse return error.OverBudget;
        if (an.budget < cost) {
            an.budget = 0;
            return error.OverBudget;
        }
        an.budget -= cost;
    }

    fn node(an: *Analysis, n: Node) Error!PatIndex {
        const i: PatIndex = @enumFromInt(an.pats.nodes.len);
        try an.pats.nodes.append(an.arena, n);
        return i;
    }

    fn anything(an: *Analysis) Error!PatIndex {
        return an.node(.{ .tag = .anything, .lhs = 0, .rhs = 0 });
    }

    fn makeCtor(an: *Analysis, un: u32, alt: u32, args: []const PatIndex) Error!PatIndex {
        const at: u32 = @intCast(an.pats.extra.items.len);
        try an.pats.extra.append(an.arena, alt);
        try an.pats.extra.append(an.arena, @intCast(args.len));
        try an.pats.extra.appendSlice(an.arena, @ptrCast(args));
        return an.node(.{ .tag = .ctor, .lhs = un, .rhs = at });
    }

    /// Intern a union. The invented ones are keyed by shape and arity, a
    /// declared one by its `TypeId` — the dense id of checker.md §5, so
    /// "same type" is one integer compare and never a name.
    fn internUnion(an: *Analysis, shape: Shape, id: Types.TypeId, alts: []const Alt) Error!u32 {
        for (an.pats.unions.items, 0..) |u, i| {
            if (u.shape != shape) continue;
            switch (shape) {
                .adt => if (u.type == id) return @intCast(i),
                .tuple => if (u.count() == 1 and an.pats.alt(u.alts_start).arity == alts[0].arity) return @intCast(i),
                .unit, .list => return @intCast(i),
            }
        }
        const start: u32 = @intCast(an.pats.alts.items.len);
        try an.pats.alts.appendSlice(an.arena, alts);
        const index: u32 = @intCast(an.pats.unions.items.len);
        try an.pats.unions.append(an.arena, .{
            .shape = shape,
            .type = id,
            .alts_start = start,
            .alts_end = @intCast(an.pats.alts.items.len),
        });
        return index;
    }

    fn tupleUnion(an: *Analysis, arity: u32) Error!u32 {
        return an.internUnion(.tuple, .none, &.{.{ .name = .none, .arity = arity }});
    }

    fn unitUnion(an: *Analysis) Error!u32 {
        return an.internUnion(.unit, .none, &.{.{ .name = .none, .arity = 0 }});
    }

    /// `[]` is alternative 0 and `::` alternative 1, in that order, because
    /// the missing-pattern search walks alternatives in order and `[]` is
    /// the example a reader wants first.
    fn listUnion(an: *Analysis) Error!u32 {
        return an.internUnion(.list, .none, &.{
            .{ .name = .none, .arity = 0 },
            .{ .name = .none, .arity = 2 },
        });
    }

    fn simplify(an: *Analysis, inst: Bir.Inst.Index, depth: u32) Fail!PatIndex {
        // Nesting guard; the whole `case` then reports nothing. Correct
        // here because a pattern this deep is not simplified at all, so
        // there is no matrix to judge — see `max_depth`.
        if (depth > max_depth) return error.TooDeep;
        try an.spend(1);
        const bir = an.cx.bir;
        if (inst.int() >= bir.insts.len) return error.Malformed;
        const tag = bir.instTag(inst);
        const data = bir.instData(inst);
        switch (tag) {
            // A record pattern binds names and cannot fail: a record has
            // exactly one shape (language.md §3).
            .pat_wild, .pat_var, .pat_record => return an.anything(),
            .pat_as => return an.simplify(@enumFromInt(data.lhs), depth + 1),
            .pat_unit => return an.makeCtor(try an.unitUnion(), 0, &.{}),
            .pat_int => return an.intLiteral(data),
            .pat_char => return an.newLiteral(.{ .kind = .char, .value = data.lhs }),
            .pat_string => return an.newLiteral(.{ .kind = .string, .off = data.lhs, .len = data.rhs }),
            .pat_tuple => {
                const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
                const args = try an.arena.alloc(PatIndex, elements.len);
                for (elements, args) |el, *a| a.* = try an.simplify(el, depth + 1);
                const un = try an.tupleUnion(@intCast(elements.len));
                return an.makeCtor(un, an.pats.unionAt(un).alts_start, args);
            },
            .pat_list => {
                const elements = bir.extraSlice(Bir.inlineRange(data), Bir.Inst.Index);
                const un = try an.listUnion();
                const nil_alt = an.pats.unionAt(un).alts_start;
                var acc = try an.makeCtor(un, nil_alt, &.{});
                var i = elements.len;
                while (i > 0) {
                    i -= 1;
                    const head = try an.simplify(elements[i], depth + 1);
                    acc = try an.makeCtor(un, nil_alt + 1, &.{ head, acc });
                }
                return acc;
            },
            .pat_cons => {
                const un = try an.listUnion();
                const head = try an.simplify(@enumFromInt(data.lhs), depth + 1);
                const tail = try an.simplify(@enumFromInt(data.rhs), depth + 1);
                return an.makeCtor(un, an.pats.unionAt(un).alts_start + 1, &.{ head, tail });
            },
            .pat_ctor => {
                const found = try an.ctorUnion(@enumFromInt(data.lhs));
                const arg_insts = bir.extraSlice(bir.subRange(@enumFromInt(data.rhs)), Bir.Inst.Index);
                const declared = an.pats.alt(found.alt).arity;
                // A constructor written with the wrong number of arguments
                // is a type error, so this declaration would have been
                // skipped; a mismatch here means the matrix cannot be
                // trusted.
                if (arg_insts.len != declared) return error.Malformed;
                const args = try an.arena.alloc(PatIndex, arg_insts.len);
                for (arg_insts, args) |ai, *a| a.* = try an.simplify(ai, depth + 1);
                return an.makeCtor(found.un, found.alt, args);
            },
            // A pattern the parser or the resolver could not make sense of.
            else => return error.Malformed,
        }
    }

    fn newLiteral(an: *Analysis, lit: Literal) Error!PatIndex {
        const i: u32 = @intCast(an.pats.literals.items.len);
        try an.pats.literals.append(an.arena, lit);
        return an.node(.{ .tag = .literal, .lhs = i, .rhs = 0 });
    }

    /// An integer pattern, by VALUE where the spelling fits: `1` and `0x1`
    /// are the same pattern, and two branches spelling one value differently
    /// really are redundant.
    fn intLiteral(an: *Analysis, data: Bir.Inst.Data) Error!PatIndex {
        const text = if (data.lhs + data.rhs <= an.pats.string_bytes.len)
            an.pats.string_bytes[data.lhs..][0..data.rhs]
        else
            "";
        const value = parseInt(text);
        return an.newLiteral(.{
            .kind = .int,
            .value = value orelse 0,
            .off = data.lhs,
            .len = data.rhs,
            .parsed = value != null,
        });
    }

    /// The union of the constructor `reference` names, and which alternative
    /// of it the constructor is.
    fn ctorUnion(an: *Analysis, reference: Bir.Inst.Index) Fail!struct { un: u32, alt: u32 } {
        const bir = an.cx.bir;
        if (reference.int() >= bir.insts.len) return error.Malformed;
        const data = bir.instData(reference);
        switch (bir.instTag(reference)) {
            // A constructor of this module: the declaring `type` lists them
            // all, opaque or not — opacity hides them from IMPORTERS, and
            // this is the declaring side.
            .ctor => {
                if (data.lhs >= bir.ctors.len) return error.Malformed;
                const c = bir.ctors[data.lhs];
                const d = bir.decl(c.decl);
                if (d.ctors_end <= d.ctors_start or data.lhs < d.ctors_start or data.lhs >= d.ctors_end) return error.Malformed;
                const id = an.cx.types.ofDecl(an.cx.module, c.decl);
                if (id == .none) return error.Malformed;
                const alts = try an.arena.alloc(Alt, d.ctors_end - d.ctors_start);
                for (bir.ctors[d.ctors_start..d.ctors_end], alts) |sibling, *a| a.* = .{
                    .name = bir.symbol(sibling.name).toOptional(),
                    .arity = @intFromEnum(sibling.args_end) - @intFromEnum(sibling.args_start),
                };
                const un = try an.internUnion(.adt, id, alts);
                return .{ .un = un, .alt = an.pats.unionAt(un).alts_start + (data.lhs - d.ctors_start) };
            },
            // A constructor of another module: through that module's
            // interface, which groups a type's constructors and keeps them
            // in declaration order for this (see `Interface.findCtor`).
            .ext_ctor => {
                if (data.lhs >= an.cx.interfaces.len) return error.Malformed;
                const module: Graph.Index = @enumFromInt(data.lhs);
                const iface = &an.cx.interfaces[data.lhs];
                if (data.rhs >= iface.ctors.len) return error.Malformed;
                const type_index = iface.ctors[data.rhs].type;
                if (@intFromEnum(type_index) >= iface.types.len) return error.Malformed;
                const t = iface.types[@intFromEnum(type_index)];
                if (t.ctors_end <= t.ctors_start or data.rhs < t.ctors_start or data.rhs >= t.ctors_end) return error.Malformed;
                const id = an.cx.types.ofInterface(module, type_index);
                if (id == .none) return error.Malformed;
                const alts = try an.arena.alloc(Alt, t.ctors_end - t.ctors_start);
                for (iface.ctors[t.ctors_start..t.ctors_end], alts) |sibling, *a| a.* = .{
                    .name = iface.symbol(sibling.name).toOptional(),
                    .arity = sibling.arity,
                };
                const un = try an.internUnion(.adt, id, alts);
                return .{ .un = un, .alt = an.pats.unionAt(un).alts_start + (data.rhs - t.ctors_start) };
            },
            else => return error.Malformed,
        }
    }

    // ---- The two relations ----------------------------------------------

    /// Maranget's `U(P, q)`: can `vector` match a value no row of `matrix`
    /// matches?
    fn isUseful(an: *Analysis, matrix: []const []const PatIndex, vector: []const PatIndex, depth: u32) Fail!bool {
        // Nesting guard. Reporting nothing is the only sound answer: a
        // truncated search cannot distinguish "not useful" (which would be
        // `redundant_pattern`) from "not searched far enough", and the
        // second spelled as the first is a warning about correct code.
        if (depth > max_depth) return error.TooDeep;
        try an.spend(matrix.len + 1);
        // Nothing above it matches the same values, so it is useful.
        if (matrix.len == 0) return true;
        // Nothing left to distinguish it by, and rows remain: not useful.
        if (vector.len == 0) return false;

        const first = vector[0];
        const rest = vector[1..];
        switch (an.pats.tag(first)) {
            .ctor => {
                const c = an.pats.ctor(first);
                const sub = try an.specializeByCtor(matrix, c.alt, c.args_len);
                return an.isUseful(sub, try an.concat(an.pats.args(c), rest), depth + 1);
            },
            .literal => {
                const sub = try an.specializeByLiteral(matrix, an.pats.literal(first));
                return an.isUseful(sub, rest, depth + 1);
            },
            .anything => {
                if (try an.complete(matrix)) |un| {
                    // Every alternative is covered above, so this wildcard
                    // adds nothing for the HEADS — but an alternative's
                    // arguments may still be narrower above than here.
                    const u = an.pats.unionAt(un);
                    var alt = u.alts_start;
                    while (alt < u.alts_end) : (alt += 1) {
                        const arity = an.pats.alt(alt).arity;
                        const sub = try an.specializeByCtor(matrix, alt, arity);
                        const v = try an.concat(try an.anythings(arity), rest);
                        if (try an.isUseful(sub, v, depth + 1)) return true;
                    }
                    return false;
                }
                return an.isUseful(try an.specializeByAnything(matrix), rest, depth + 1);
            },
        }
    }

    /// Maranget's `I(P, n)`: value vectors of width `n` that `matrix`
    /// leaves unmatched, at most `max_examples` of them.
    fn isExhaustive(an: *Analysis, matrix: []const []const PatIndex, n: u32, depth: u32) Fail![]const []const PatIndex {
        // Nesting guard. Reporting nothing is the only sound answer: the
        // counterexamples found so far are the ones above this point in the
        // tree, and a truncated branch may be exactly the one that is
        // covered — printing what we have would be `missing_patterns` on a
        // `case` that is complete.
        if (depth > max_depth) return error.TooDeep;
        try an.spend(matrix.len + 1);
        // No row matches anything: every value of width `n` is missing.
        if (matrix.len == 0) {
            const row = try an.anythings(n);
            const rows = try an.arena.alloc([]const PatIndex, 1);
            rows[0] = row;
            return rows;
        }
        // A row of width zero matches the empty value vector.
        if (n == 0) return &.{};

        const seen = try an.collect(matrix);
        if (seen.count == 0) {
            // Only literals and wildcards here. A wildcard row survives
            // `specializeByAnything`; a literal row does not, which is what
            // makes an all-literal column inexhaustive.
            const rest = try an.isExhaustive(try an.specializeByAnything(matrix), n - 1, depth + 1);
            return an.prependAll(try an.anything(), rest);
        }

        const u = an.pats.unionAt(seen.un);
        if (seen.count < u.count()) {
            const rest = try an.isExhaustive(try an.specializeByAnything(matrix), n - 1, depth + 1);
            var out: std.ArrayList([]const PatIndex) = .empty;
            var alt = u.alts_start;
            outer: while (alt < u.alts_end) : (alt += 1) {
                if (seen.has(alt)) continue;
                const example = try an.makeCtor(seen.un, alt, try an.anythings(an.pats.alt(alt).arity));
                for (rest) |row| {
                    try out.append(an.arena, try an.concat(&.{example}, row));
                    if (out.items.len >= max_examples) break :outer;
                }
            }
            return out.items;
        }

        // Every alternative appears: recurse into each one's arguments.
        var out: std.ArrayList([]const PatIndex) = .empty;
        var alt = u.alts_start;
        while (alt < u.alts_end) : (alt += 1) {
            const arity = an.pats.alt(alt).arity;
            const sub = try an.specializeByCtor(matrix, alt, arity);
            const rows = try an.isExhaustive(sub, arity + n - 1, depth + 1);
            for (rows) |row| {
                if (row.len < arity) return error.Malformed;
                const recovered = try an.makeCtor(seen.un, alt, row[0..arity]);
                try out.append(an.arena, try an.concat(&.{recovered}, row[arity..]));
                if (out.items.len >= max_examples) return out.items;
            }
        }
        return out.items;
    }

    /// The alternatives appearing in column zero. Every one of them belongs
    /// to the same union — the declaration type-checked — and a matrix that
    /// says otherwise is abandoned rather than trusted.
    const Seen = struct {
        un: u32,
        count: u32,
        /// Absolute alternative indices, `count` of them.
        alts: []const u32,

        fn has(s: Seen, alt: u32) bool {
            return std.mem.indexOfScalar(u32, s.alts, alt) != null;
        }
    };

    fn collect(an: *Analysis, matrix: []const []const PatIndex) Fail!Seen {
        var alts: std.ArrayList(u32) = .empty;
        var un: u32 = 0;
        for (matrix) |row| {
            if (row.len == 0) return error.Malformed;
            if (an.pats.tag(row[0]) != .ctor) continue;
            const c = an.pats.ctor(row[0]);
            if (alts.items.len != 0 and c.un != un) return error.Malformed;
            un = c.un;
            if (std.mem.indexOfScalar(u32, alts.items, c.alt) == null) try alts.append(an.arena, c.alt);
        }
        return .{ .un = un, .count = @intCast(alts.items.len), .alts = alts.items };
    }

    /// The union of column zero when every one of its alternatives appears,
    /// else null (Elm's `isComplete`).
    fn complete(an: *Analysis, matrix: []const []const PatIndex) Fail!?u32 {
        const seen = try an.collect(matrix);
        if (seen.count == 0) return null;
        if (seen.count != an.pats.unionAt(seen.un).count()) return null;
        return seen.un;
    }

    // ---- Specialisation --------------------------------------------------

    fn specializeByCtor(an: *Analysis, matrix: []const []const PatIndex, alt: u32, arity: u32) Fail![]const []const PatIndex {
        try an.spend(matrix.len + 1);
        var out: std.ArrayList([]const PatIndex) = .empty;
        for (matrix) |row| {
            if (row.len == 0) return error.Malformed;
            switch (an.pats.tag(row[0])) {
                .ctor => {
                    const c = an.pats.ctor(row[0]);
                    if (c.alt != alt) continue;
                    try out.append(an.arena, try an.concat(an.pats.args(c), row[1..]));
                },
                .anything => try out.append(an.arena, try an.concat(try an.anythings(arity), row[1..])),
                // Elm panics here ("constructors and literals should never
                // align"); a compiler may not. The precondition is that the
                // declaration type-checked, so reaching this means the
                // matrix is not what we think it is.
                .literal => return error.Malformed,
            }
        }
        return out.items;
    }

    fn specializeByLiteral(an: *Analysis, matrix: []const []const PatIndex, lit: Literal) Fail![]const []const PatIndex {
        try an.spend(matrix.len + 1);
        var out: std.ArrayList([]const PatIndex) = .empty;
        for (matrix) |row| {
            if (row.len == 0) return error.Malformed;
            switch (an.pats.tag(row[0])) {
                .literal => if (an.pats.literal(row[0]).eql(lit, an.pats)) {
                    try out.append(an.arena, row[1..]);
                },
                .anything => try out.append(an.arena, row[1..]),
                .ctor => return error.Malformed,
            }
        }
        return out.items;
    }

    fn specializeByAnything(an: *Analysis, matrix: []const []const PatIndex) Fail![]const []const PatIndex {
        try an.spend(matrix.len + 1);
        var out: std.ArrayList([]const PatIndex) = .empty;
        for (matrix) |row| {
            if (row.len == 0) return error.Malformed;
            if (an.pats.tag(row[0]) != .anything) continue;
            try out.append(an.arena, row[1..]);
        }
        return out.items;
    }

    // ---- Small helpers ---------------------------------------------------

    fn anythings(an: *Analysis, n: u32) Error![]const PatIndex {
        const row = try an.arena.alloc(PatIndex, n);
        for (row) |*p| p.* = try an.anything();
        return row;
    }

    fn concat(an: *Analysis, head: []const PatIndex, tail: []const PatIndex) Error![]const PatIndex {
        const row = try an.arena.alloc(PatIndex, head.len + tail.len);
        @memcpy(row[0..head.len], head);
        @memcpy(row[head.len..], tail);
        return row;
    }

    fn prependAll(an: *Analysis, p: PatIndex, rows: []const []const PatIndex) Error![]const []const PatIndex {
        var out: std.ArrayList([]const PatIndex) = .empty;
        for (rows) |row| {
            try out.append(an.arena, try an.concat(&.{p}, row));
            if (out.items.len >= max_examples) break;
        }
        return out.items;
    }
};

/// The value of an integer pattern's spelling, or null when it does not fit.
/// The spelling is what lowering kept (`Bir`'s `pat_int`): decimal or `0x`,
/// optionally negated, and never with a separator the lexer rejected.
fn parseInt(text: []const u8) ?i128 {
    if (text.len == 0) return null;
    var body = text;
    var negative = false;
    if (body[0] == '-') {
        negative = true;
        body = body[1..];
    }
    const value: i128 = blk: {
        if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) {
            break :blk std.fmt.parseInt(i128, body[2..], 16) catch return null;
        }
        break :blk std.fmt.parseInt(i128, body, 10) catch return null;
    };
    return if (negative) -value else value;
}

// ---------------------------------------------------------------------------
// Tests
//
// The algorithm's behaviour is asserted through the real pipeline in
// `Check.zig`'s tests and the `check/bad` corpus — a diagnostic is the only
// thing a person sees. Here only the pieces with no visible output.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "integer pattern spellings compare by value, not by text" {
    try testing.expectEqual(@as(?i128, 1), parseInt("1"));
    try testing.expectEqual(@as(?i128, 1), parseInt("0x1"));
    try testing.expectEqual(@as(?i128, 255), parseInt("0xFF"));
    try testing.expectEqual(@as(?i128, -7), parseInt("-7"));
    try testing.expectEqual(@as(?i128, 0), parseInt("0"));
    // Nothing the lexer accepts looks like this, but a poisoned spelling
    // must fall back rather than trap.
    try testing.expectEqual(@as(?i128, null), parseInt(""));
    try testing.expectEqual(@as(?i128, null), parseInt("-"));
    try testing.expectEqual(@as(?i128, null), parseInt("nope"));
}

test "a literal compares by value where it parsed and by spelling where it did not" {
    const pats: Patterns = .{ .string_bytes = "1  0x1nope" };
    const decimal: Literal = .{ .kind = .int, .value = 1, .off = 0, .len = 1 };
    const hex: Literal = .{ .kind = .int, .value = 1, .off = 3, .len = 3 };
    try testing.expect(decimal.eql(hex, &pats));

    const a: Literal = .{ .kind = .int, .off = 6, .len = 4, .parsed = false };
    const b: Literal = .{ .kind = .int, .off = 6, .len = 4, .parsed = false };
    try testing.expect(a.eql(b, &pats));
    try testing.expect(!a.eql(decimal, &pats));

    const text: Literal = .{ .kind = .string, .off = 0, .len = 1 };
    try testing.expect(!text.eql(decimal, &pats));

    // A range that runs off the end reads as empty rather than trapping —
    // the bound `bytesOf` adds. Nothing lowering produces looks like this;
    // the point is that the check lives next to the slice.
    const past_end: Literal = .{ .kind = .string, .off = 8, .len = 99 };
    try testing.expect(past_end.eql(.{ .kind = .string, .off = 50, .len = 1 }, &pats));
}
