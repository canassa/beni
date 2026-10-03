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
//! **Patterns are simplified first** (`simplify`), into four shapes and
//! nothing else: `anything` (a wildcard, a variable, a record pattern —
//! records have no alternatives, so matching one always succeeds), a
//! `literal`, a `ctor` of a known *union*, or a `list`. Everything structural
//! but a list becomes a constructor of a one-alternative union invented
//! here: `()` is the sole constructor of a unit union and an n-tuple the
//! sole constructor of a tuple union. A column either has a finite set of
//! alternatives (then "did we see all of them?" is a count) or it has
//! infinitely many (`Int`, `Float`, `Char`, `String` literals — a wildcard
//! is then the only way to be exhaustive).
//!
//! **A list is split by length** (checker.md §6.6, amended 2026-10-01).
//! It was the union `[]`/`::`, which cannot say "the last element is 0"
//! (`[ ...init, 0 ]`, language.md §6.8), so a list pattern is its leading
//! items, its trailing items and whether it has a spread, and a list
//! column's alternatives — `exact ℓ` below a length `L` and `at least L` —
//! are computed from that column when it is specialised (`LenSplit`),
//! as Rust's slice patterns do. `[ a, b ]`, `[ x, ...rest ]` and the old
//! `x :: rest` are one language there too.
//!
//! **A constructor's union comes from its type declaration**: for a
//! constructor of this module, from the declaring `type`'s `Bir.ctors`
//! range; for an imported one, from the importing side's `Interface`, which
//! keeps a type's constructors adjacent and in declaration order for
//! exactly this. Going through the interface and not the dependency's Bir is
//! the firewall of `fast-compiler.md` §8.1: with the on-disk cache a dependency's Bir may not
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
//! **A lookup table does not go through either relation** (`Flat`). A `case` whose every branch is a KEY — `_`, a literal,
//! a nullary constructor, or a tuple/single-constructor wrapper of those — is
//! a lookup table, and for one of those "is this row useful?" is set
//! membership rather than a matrix specialisation — Maranget §4's
//! observation, and what makes an n-branch table cost O(n) steps instead of
//! 1.05·n² (a single key) or 2·n² (a pair). It decides nothing the general
//! relation would decide otherwise and steps aside for every other shape;
//! `Flat`'s own comment says where the cut is and where that equivalence is
//! asserted.
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
const reads = @import("reads.zig");
const Diagnostics = @import("Diagnostics.zig");
const Render = @import("Render.zig");
const Types = @import("Types.zig");
const PatternStore = @import("PatternStore.zig");
const ColumnIndex = @import("ColumnIndex.zig");
const Flat = @import("Flat.zig").Flat;
const diagnostic = @import("diagnostic");

const Exhaustive = @This();

pub const Symbol = InternPool.Symbol;

/// How many counterexamples a `missing_patterns` message prints
/// (checker.md §6.6: "up to three example patterns").
pub const max_examples = 3;

/// Row visits and recursive steps one `case` may spend before it is
/// refused.
///
/// **Measured, not guessed** (2026-09-18). `Flat` takes the quadratic out of
/// one-column and KEYED lookup tables, so the default does not refuse
/// ordinary code.
///
/// What a lookup table costs, by turning the budget down until the answer
/// changes (`n` branches plus a wildcard, except where the key is a complete
/// product and needs none):
///
/// | shape | steps |
/// |---|---|
/// | 500 `Int` literals | **1 002** |
/// | 2 000 `Int` literals | **4 002** |
/// | 10 000 `Int` literals | **20 002** |
/// | 320 nullary constructors | **640** |
/// | 2 000 nullary constructors | **4 000** |
/// | 500 `( Int, Int )` pairs | **3 002** |
/// | 1 580 `( Int, Int )` pairs | **9 482** |
/// | 5 000 `( Int, Int )` pairs | **30 002** |
/// | 500 pairs of two 40-ctor enums | **3 002** |
/// | 1 580 pairs of two 40-ctor enums | **9 482** |
/// | 5 000 pairs of two 80-ctor enums | **30 002** |
///
/// So a one-column table costs **2 per branch** and a pair **6** — three to
/// simplify `( 1, 2 )` and three to walk and hash it — and neither squares.
/// End to end in a Debug build, the 5 000-row pair checks in **0.15 s** and
/// the 5 000-row enum pair in **0.22 s**.
///
/// **What still squares** is a row the key path is not allowed to decide,
/// which means one wildcard CELL in an otherwise concrete row:
/// `case ( a, b ) of ( 1, _ ) -> …`, a table with a per-row default. That is
/// `Flat`'s CUT, it is still 2n², and 1 580 rows of it come to **5 087 257**
/// steps. That is the shape this number is now sized for.
///
/// And what the repository spends, the same way. Leaving out the two fixtures
/// that exist to BE tables, the costliest `case` in `core/` is **71**, in
/// `bench/corpus` **402**, and in `tests/corpus` **529** —
/// `check/depth/PatternNestOk`, 511 levels of `Just`, which exists to sit one
/// under the depth guard. `parse/good/ManyBranches`, 100 `Int` branches and
/// the old champion at ~10 500, spends **202**. The two tables themselves:
/// `check/good/LookupTable`, 460 `Int` branches, **922**, and
/// `check/good/PairLookupTable`, 1 800 pair rows, **10 802**. (`Flat` charges
/// for the node it looks at before it discovers it cannot read the shape:
/// work done is work charged.)
///
/// **The default is 5 000 000**, by the rule "a budget a `case` a person
/// wrote never meets, that still bounds an adversarial one to well under a
/// second". It is ~9 500× the costliest `case` here that is not a table; it
/// admits a one-column table of 2.5 million branches, a pair-keyed one of
/// 830 000, and a pair-keyed one with a per-row default of ~1 570; and a
/// `case` that spends all of it takes **0.65 s in a Debug build and 0.07 s in
/// ReleaseFast** (measured end to end on the 1 580-row open-pair table,
/// ~9 M steps/s Debug and ~90 M/s ReleaseFast).
///
/// Both searches stop early — `isUseful` at the first useful alternative and
/// `isExhaustive` at `max_examples` counterexamples — which is why the
/// exponent of Maranget §3.3 is not what a real program meets first.
///
/// If the refusal starts firing on code people mean again, **the algorithm is
/// what to fix** before the number: the next one to take is the CUT itself —
/// a row with an open cell covers a slice of the key space, and deciding
/// slices against points is a different structure than a hash set.
/// `--pattern-budget=<n>` exists so that an author who meets it is not stuck
/// while that happens.
pub const default_budget: u32 = 5_000_000;

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
pub const max_depth: u32 = 512;

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
// The simplified pattern language, in `PatternStore.zig`
// ---------------------------------------------------------------------------

pub const PatIndex = PatternStore.PatIndex;
pub const Tag = PatternStore.Tag;
pub const Node = PatternStore.Node;
pub const Shape = PatternStore.Shape;
pub const Union = PatternStore.Union;
pub const Alt = PatternStore.Alt;
pub const Literal = PatternStore.Literal;
pub const Patterns = PatternStore.Patterns;

// ---------------------------------------------------------------------------
// The entry point
// ---------------------------------------------------------------------------

/// Everything one module's check needs to reach a constructor's union. A
/// copy of fields the module's check already holds, passed explicitly so
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
            const at: Bir.Inst.Index = @fromBackingInt(@intCast(inst));
            const data = bir.instData(at);
            switch (bir.instTag(at)) {
                .case => {
                    scratch.reset(.retain_capacity);
                    try one(gpa, scratch.allocator(), cx, reporter, at, budget);
                },
                .lambda => for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.lhs))), Bir.Inst.Index)) |param| {
                    scratch.reset(.retain_capacity);
                    try irrefutable(gpa, scratch.allocator(), cx, reporter, param, .refutable_parameter_pattern, budget);
                },
                .let_def => {
                    const def = bir.extraData(@fromBackingInt(@intCast(data.lhs)), Bir.LetDef);
                    for (bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Bir.Inst.Index)) |param| {
                        scratch.reset(.retain_capacity);
                        try irrefutable(gpa, scratch.allocator(), cx, reporter, param, .refutable_parameter_pattern, budget);
                    }
                },
                .let_pattern => {
                    scratch.reset(.retain_capacity);
                    try irrefutable(gpa, scratch.allocator(), cx, reporter, @fromBackingInt(@intCast(data.lhs)), .refutable_let_pattern, budget);
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
/// **An answer that could not be computed is a refusal**, here and at a
/// `case` too. The two messages differ because the two
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
        .pat_as => hasCtor(bir, @fromBackingInt(@intCast(data.lhs)), depth + 1),
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
    const branches = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(case).rhs))), Bir.Inst.Index);
    if (branches.len == 0) return; // `case_without_branches` already reported

    var pats: Patterns = .{ .string_bytes = bir.string_bytes };
    var an: Analysis = .{ .arena = arena, .cx = cx, .pats = &pats, .budget = budget };

    // Elm's `toNonRedundantRows`: add one branch at a time and stop at the
    // first that is not useful given the ones above it. Stopping is Elm's
    // behaviour and it is the right one — once a row is dead the rows after
    // it are being judged against a matrix the author did not mean.
    var matrix: std.ArrayList([]const PatIndex) = .empty;
    // The key set of `Flat`, while the `case` is still a lookup table. Once
    // a branch is a shape it cannot decide, it is abandoned for good and
    // every remaining branch goes through the general relation with the
    // matrix built so far — which is the same matrix either way, so the
    // answers are the same answers.
    var flat: Flat = .{ .arena = arena };
    var flat_column = true;
    // Every admitted row by its head, for `usefulRow`.
    var heads: ColumnIndex.Heads = .{};
    for (branches, 0..) |b, i| {
        // The PATTERN, not the branch: a redundant branch is a statement
        // about what it matches, so the caret belongs under the pattern.
        const pattern: Bir.Inst.Index = @fromBackingInt(@intCast(bir.instData(b).lhs));
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
        if (flat_column) {
            const answer = flat.admit(&an, p) catch |err| switch (err) {
                error.OverBudget => return reporter.patternBudgetExhausted(case, .budget, budget),
                else => |e| return e,
            };
            switch (answer) {
                .useful => {
                    try heads.add(arena, &pats, matrix.items.len, p);
                    try matrix.append(arena, row);
                    continue;
                },
                .redundant => return reporter.redundantPattern(pattern, @intCast(i + 1)),
                // Not a shape the set can decide. The general relation
                // takes this branch and every one after it.
                .general => flat_column = false,
            }
        }
        const useful = an.usefulRow(&heads, matrix.items, row) catch |err| switch (err) {
            error.OverBudget => return reporter.patternBudgetExhausted(case, .budget, budget),
            error.TooDeep => return reporter.patternBudgetExhausted(case, .depth, max_depth),
            error.Malformed => return, // silent, by the argument above
            else => |e| return e,
        };
        if (!useful) return reporter.redundantPattern(pattern, @intCast(i + 1));
        try heads.add(arena, &pats, matrix.items.len, p);
        try matrix.append(arena, row);
    }

    // A key space with every point taken is exhaustive, and saying so here
    // is what keeps `isExhaustive`'s arm that specialises by every
    // alternative (linear through `split`, but still a matrix built
    // per alternative) off a `case` that lists a hundred constructors, or
    // ten thousand pairs of them.
    // Every other answer is delegated, witnesses and all, so there is one
    // place that builds a counterexample and it is not this one.
    if (flat_column and flat.exhaustive(&an)) return;

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

pub const Analysis = struct {
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
    /// a wrong warning, a compiler that does not terminate, or silence,
    /// which hands an unproven
    /// `case` to a decision tree that carries no default arm.
    /// `error{OverBudget}` and not `Abort`: running out of budget is the
    /// only way this can fail, and `Flat.admit` — which cannot go too deep
    /// or meet a malformed matrix — needs to say so in its own signature.
    pub fn spend(an: *Analysis, amount: usize) error{OverBudget}!void {
        const cost = std.math.cast(u32, amount) orelse return error.OverBudget;
        if (an.budget < cost) {
            an.budget = 0;
            return error.OverBudget;
        }
        an.budget -= cost;
    }

    fn node(an: *Analysis, n: Node) Error!PatIndex {
        const i: PatIndex = @fromBackingInt(@intCast(an.pats.nodes.len));
        try an.pats.nodes.append(an.arena, n);
        return i;
    }

    fn anything(an: *Analysis) Error!PatIndex {
        return an.node(.{ .tag = .anything, .lhs = 0, .rhs = 0 });
    }

    /// A byte key two literals share exactly when `Literal.eql` says they
    /// are the same literal, for `Flat`'s set. The kind leads, so a `Char`
    /// and an `Int` of one scalar value never collide; an `int` whose
    /// spelling overflowed `value` gets its own tag, because `eql` compares
    /// those by spelling and never to a parsed one.
    pub fn literalKey(an: *Analysis, lit: Literal) Error![]const u8 {
        const tag: u8 = switch (lit.kind) {
            .char => 'c',
            .int => if (lit.parsed) 'i' else 'I',
            .string => 's',
        };
        const body: []const u8 = switch (lit.kind) {
            .char => std.mem.asBytes(&lit.value),
            .int => if (lit.parsed) std.mem.asBytes(&lit.value) else an.pats.bytesOf(lit),
            .string => an.pats.bytesOf(lit),
        };
        const key = try an.arena.alloc(u8, 1 + body.len);
        key[0] = tag;
        @memcpy(key[1..], body);
        return key;
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
                .unit => return @intCast(i),
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

    fn makeList(an: *Analysis, prefix: []const PatIndex, suffix: []const PatIndex, spread: bool) Error!PatIndex {
        const at: u32 = @intCast(an.pats.extra.items.len);
        try an.pats.extra.appendSlice(an.arena, &.{ @intCast(prefix.len), @intCast(suffix.len), @intFromBool(spread) });
        try an.pats.extra.appendSlice(an.arena, @ptrCast(prefix));
        try an.pats.extra.appendSlice(an.arena, @ptrCast(suffix));
        return an.node(.{ .tag = .list, .lhs = 0, .rhs = at });
    }

    /// A `pat_list` as one `list` node: its items before the spread, its
    /// items after it, and whether it has one (language.md §6.8).
    fn simplifyList(an: *Analysis, inst: Bir.Inst.Index, depth: u32) Fail!PatIndex {
        const bir = an.cx.bir;
        var prefix: std.ArrayList(PatIndex) = .empty;
        var suffix: std.ArrayList(PatIndex) = .empty;
        var spread = false;
        for (bir.extraSlice(Bir.inlineRange(bir.instData(inst)), Bir.Inst.Index)) |el| {
            if (el.int() >= bir.insts.len) return error.Malformed;
            if (bir.instTag(el) == .pat_spread) {
                // The parser refused a second one.
                if (spread) return error.Malformed;
                spread = true;
                continue;
            }
            const item = try an.simplify(el, depth + 1);
            try (if (spread) &suffix else &prefix).append(an.arena, item);
        }
        return an.makeList(prefix.items, suffix.items, spread);
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
            .pat_as => return an.simplify(@fromBackingInt(@intCast(data.lhs)), depth + 1),
            // `alt` is an ABSOLUTE index into `pats.alts`, so the unit's sole
            // alternative is `alts_start` and not `0` — which they are equal
            // to only when the unit union happens to be the first one interned.
            // A `()` nested under anything (`Just ()`, `A () n`, `[ () ]`) is
            // interned after that thing's union, so the literal `0` used to
            // name an alternative of a DIFFERENT union and the relation could
            // neither specialise the row nor count it.
            .pat_unit => {
                const un = try an.unitUnion();
                return an.makeCtor(un, an.pats.unionAt(un).alts_start, &.{});
            },
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
            .pat_list => return an.simplifyList(inst, depth),
            .pat_ctor => {
                const found = try an.ctorUnion(@fromBackingInt(@intCast(data.lhs)));
                const arg_insts = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Inst.Index);
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
                    .arity = @backingInt(sibling.args_end) - @backingInt(sibling.args_start),
                };
                const un = try an.internUnion(.adt, id, alts);
                return .{ .un = un, .alt = an.pats.unionAt(un).alts_start + (data.lhs - d.ctors_start) };
            },
            // A constructor of another module: through that module's
            // interface, which groups a type's constructors and keeps them
            // in declaration order for this (see `Interface.findCtor`).
            .ext_ctor => {
                if (data.lhs >= an.cx.interfaces.len) return error.Malformed;
                const module: Graph.Index = @fromBackingInt(@intCast(data.lhs));
                // §3.2 row 17: the sibling constructor set, which is `R` —
                // the importer's exhaustiveness is a function of the
                // declaring module's published `types`/`ctors` tables.
                reads.note(.iface, module);
                const iface = &an.cx.interfaces[data.lhs];
                if (data.rhs >= iface.ctors.len) return error.Malformed;
                const type_index = iface.ctors[data.rhs].type;
                if (@backingInt(type_index) >= iface.types.len) return error.Malformed;
                const t = iface.types[@backingInt(type_index)];
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
            .schema_ctor_top => {
                const decl: Bir.DeclIndex = @fromBackingInt(@intCast(data.lhs));
                if (decl.int() >= bir.decls.len) return error.Malformed;
                const d = bir.decl(decl);
                const root = d.schema_body.unwrap() orelse return error.Malformed;
                var at = root;
                var budget = bir.insts.len + 1;
                while (budget > 0 and at.int() < bir.insts.len) : (budget -= 1) switch (bir.instTag(at)) {
                    .schema_value, .schema_paren => at = @fromBackingInt(@intCast(bir.instData(at).lhs)),
                    else => break,
                };
                if (bir.instTag(at) != .schema_tagged) return error.Malformed;
                const variants = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(at).rhs))), Bir.Inst.Index);
                const ref = Bir.SchemaCtorRef.unpack(data.rhs);
                if (ref.variant >= variants.len) return error.Malformed;
                const alts = try an.arena.alloc(Alt, variants.len);
                for (variants, alts) |vi, *a| {
                    const vd = bir.instData(vi);
                    const v = bir.extraData(@fromBackingInt(@intCast(vd.rhs)), Bir.SchemaVariant);
                    const variant_name = bir.symbol(@fromBackingInt(@intCast(vd.lhs)));
                    a.* = .{ .name = an.schemaCtorDisplay(bir.symbol(d.name), ref.encoded, variant_name).toOptional(), .arity = if (v.payload == .none) 0 else 1 };
                }
                const endpoint: Interface.SchemaCtor.Endpoint = if (ref.encoded) .encoded else .type;
                const id = an.cx.types.ofSchemaDecl(an.cx.module, decl, endpoint);
                const un = try an.internUnion(.adt, id, alts);
                return .{ .un = un, .alt = an.pats.unionAt(un).alts_start + ref.variant };
            },
            .ext_schema_ctor => {
                if (data.lhs >= an.cx.interfaces.len) return error.Malformed;
                const module: Graph.Index = @fromBackingInt(@intCast(data.lhs));
                const iface = &an.cx.interfaces[data.lhs];
                if (data.rhs >= iface.schema_ctors.len) return error.Malformed;
                const ctor = iface.schema_ctors[data.rhs];
                const si = @backingInt(ctor.schema);
                if (si >= iface.schemas.len) return error.Malformed;
                const schema = iface.schemas[si];
                const from = if (ctor.endpoint == .type) schema.program_ctors_start else schema.encoded_ctors_start;
                const to = if (ctor.endpoint == .type) schema.program_ctors_end else schema.encoded_ctors_end;
                if (data.rhs < from or data.rhs >= to) return error.Malformed;
                const alts = try an.arena.alloc(Alt, to - from);
                for (iface.schema_ctors[from..to], alts) |sibling, *a| a.* = .{
                    .name = an.schemaCtorDisplay(iface.symbol(schema.name), ctor.endpoint == .encoded, iface.symbol(sibling.name)).toOptional(),
                    .arity = sibling.arity,
                };
                const id = an.cx.types.ofSchema(module, ctor.schema, ctor.endpoint);
                const un = try an.internUnion(.adt, id, alts);
                return .{ .un = un, .alt = an.pats.unionAt(un).alts_start + (data.rhs - from) };
            },
            else => return error.Malformed,
        }
    }

    fn schemaCtorDisplay(an: *Analysis, schema: Symbol, encoded: bool, variant: Symbol) Symbol {
        const text = std.fmt.allocPrint(an.arena, "{s}{s}.{s}", .{
            an.cx.interner.slice(schema),
            if (encoded) ".Encoded" else "",
            an.cx.interner.slice(variant),
        }) catch return variant;
        return an.cx.interner.find(text) orelse variant;
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
            // A list pattern stands for every alternative it covers.
            .list => {
                const lens = an.lenSplit(matrix, first);
                var alt: u32 = 0;
                while (alt < lens.count()) : (alt += 1) {
                    const cells = (try an.listCells(first, lens, alt)) orelse continue;
                    const sub = try an.specializeList(matrix, lens, alt);
                    if (try an.isUseful(sub, try an.concat(cells, rest), depth + 1)) return true;
                }
                return false;
            },
            .anything => {
                // A wildcard over lists: every alternative of the column,
                // which together are every list.
                if (an.listColumn(matrix)) {
                    const lens = an.lenSplit(matrix, null);
                    var alt: u32 = 0;
                    while (alt < lens.count()) : (alt += 1) {
                        const sub = try an.specializeList(matrix, lens, alt);
                        const v = try an.concat(try an.anythings(lens.arity(alt)), rest);
                        if (try an.isUseful(sub, v, depth + 1)) return true;
                    }
                    return false;
                }
                if (try an.complete(matrix)) |un| {
                    // Every alternative is covered above, so this wildcard
                    // adds nothing for the HEADS — but an alternative's
                    // arguments may still be narrower above than here.
                    const u = an.pats.unionAt(un);
                    const by_alt = try an.split(matrix, un);
                    var alt = u.alts_start;
                    while (alt < u.alts_end) : (alt += 1) {
                        const arity = an.pats.alt(alt).arity;
                        const sub = try an.specializeMerged(matrix, by_alt.headed(alt), by_alt.wild, arity);
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

        // A list column: every alternative, each counterexample rebuilt
        // from its alternative's cells.
        if (an.listColumn(matrix)) {
            const lens = an.lenSplit(matrix, null);
            var out: std.ArrayList([]const PatIndex) = .empty;
            var alt: u32 = 0;
            while (alt < lens.count()) : (alt += 1) {
                const arity = lens.arity(alt);
                const sub = try an.specializeList(matrix, lens, alt);
                const rows = try an.isExhaustive(sub, arity + n - 1, depth + 1);
                for (rows) |row| {
                    if (row.len < arity) return error.Malformed;
                    const recovered = try an.listOf(lens, alt, row[0..arity]);
                    try out.append(an.arena, try an.concat(&.{recovered}, row[arity..]));
                    if (out.items.len >= max_examples) return out.items;
                }
            }
            return out.items;
        }

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
        const by_alt = try an.split(matrix, seen.un);
        var alt = u.alts_start;
        while (alt < u.alts_end) : (alt += 1) {
            const arity = an.pats.alt(alt).arity;
            const sub = try an.specializeMerged(matrix, by_alt.headed(alt), by_alt.wild, arity);
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

    /// `specializeByCtor(matrix, alt, arity)` when the caller already knows
    /// which rows it keeps (`ColumnIndex`): `headed`, the rows headed by
    /// `alt`, and `wild`, those headed by a wildcard, both ascending. Built
    /// in matrix order, so the result is the same matrix.
    fn specializeMerged(an: *Analysis, matrix: []const []const PatIndex, headed: []const u32, wild: []const u32, arity: u32) Fail![]const []const PatIndex {
        try an.spend(headed.len + wild.len + 1);
        const out = try an.arena.alloc([]const PatIndex, headed.len + wild.len);
        var h: usize = 0;
        var w: usize = 0;
        for (out) |*slot| {
            if (w == wild.len or (h < headed.len and headed[h] < wild[w])) {
                const row = matrix[headed[h]];
                slot.* = try an.concat(an.pats.args(an.pats.ctor(row[0])), row[1..]);
                h += 1;
            } else {
                const row = matrix[wild[w]];
                slot.* = try an.concat(try an.anythings(arity), row[1..]);
                w += 1;
            }
        }
        return out;
    }

    /// `isUseful(matrix, row, 0)`, through `heads` when it can answer: the
    /// ctor arm's first specialisation reads only the rows `heads` names.
    fn usefulRow(an: *Analysis, heads: *const ColumnIndex.Heads, matrix: []const []const PatIndex, row: []const PatIndex) Fail!bool {
        if (row.len != 0 and an.pats.tag(row[0]) == .ctor) {
            const c = an.pats.ctor(row[0]);
            if (heads.headedBy(c)) |headed| {
                // `isUseful`'s own charge at depth 0, sized by what it reads.
                try an.spend(headed.len + heads.wild.items.len + 1);
                const sub = try an.specializeMerged(matrix, headed, heads.wild.items, c.args_len);
                return an.isUseful(sub, try an.concat(an.pats.args(c), row[1..]), 1);
            }
        }
        return an.isUseful(matrix, row, 0);
    }

    fn collect(an: *Analysis, matrix: []const []const PatIndex) Fail!ColumnIndex.Seen {
        return ColumnIndex.collect(an.arena, an.pats, matrix);
    }

    fn split(an: *Analysis, matrix: []const []const PatIndex, un: u32) Fail!ColumnIndex.Split {
        try an.spend(matrix.len + 1);
        return ColumnIndex.split(an.arena, an.pats, matrix, un);
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
                .literal, .list => return error.Malformed,
            }
        }
        return out.items;
    }

    // ---- Lists: the length split (checker.md §6.6, amended 2026-10-01) ---

    /// A list column's alternatives: `exact ℓ` for every ℓ below `len`,
    /// of arity ℓ, and `at least len` — alternative `len` — of arity
    /// `prefix + suffix`, its first `prefix` and its last `suffix`
    /// elements, which cannot overlap because `len >= prefix + suffix`.
    /// Together they are every list, each exactly once.
    const LenSplit = struct {
        prefix: u32,
        suffix: u32,
        len: u32,

        fn count(s: LenSplit) u32 {
            return s.len + 1;
        }

        fn arity(s: LenSplit, alt: u32) u32 {
            return if (alt < s.len) alt else s.prefix + s.suffix;
        }
    };

    /// Whether column zero holds a list pattern.
    fn listColumn(an: *const Analysis, matrix: []const []const PatIndex) bool {
        for (matrix) |row| {
            if (row.len != 0 and an.pats.tag(row[0]) == .list) return true;
        }
        return false;
    }

    /// Column zero's split, `extra` counted as one more row (Rust's
    /// `Slice::split`): the longest exact pattern `F`, the most leading
    /// items `P` and trailing items `S` of a pattern with a spread, and
    /// `len = max(P + S, F + 1)` — `P` raised when `F + 1` is the larger,
    /// so an `at least` alternative is never shorter than an exact one.
    fn lenSplit(an: *const Analysis, matrix: []const []const PatIndex, extra: ?PatIndex) LenSplit {
        var fixed: ?u32 = null;
        var prefix: u32 = 0;
        var suffix: u32 = 0;
        var i: usize = 0;
        while (i <= matrix.len) : (i += 1) {
            const p = if (i < matrix.len) (if (matrix[i].len != 0) matrix[i][0] else continue) else (extra orelse break);
            if (an.pats.tag(p) != .list) continue;
            const l = an.pats.list(p);
            if (l.spread) {
                prefix = @max(prefix, l.prefix);
                suffix = @max(suffix, l.suffix);
            } else fixed = @max(fixed orelse 0, l.prefix);
        }
        var len = prefix + suffix;
        if (fixed) |f| if (f + 1 > len) {
            prefix = f + 1 - suffix;
            len = f + 1;
        };
        return .{ .prefix = prefix, .suffix = suffix, .len = len };
    }

    /// The cells list pattern `p` has under alternative `alt`, or null when
    /// `p` does not cover it. Under `exact ℓ` a pattern with a spread is its
    /// leading items, `ℓ - p - s` wildcards and its trailing items; under
    /// `at least`, its leading items padded to `P` and its trailing items
    /// padded, in front, to `S`.
    fn listCells(an: *Analysis, p: PatIndex, lens: LenSplit, alt: u32) Error!?[]const PatIndex {
        const l = an.pats.list(p);
        const items = try an.arena.dupe(PatIndex, an.pats.items(l));
        if (!l.spread) return if (alt < lens.len and l.prefix == alt) items else null;
        if (alt < lens.len and l.prefix + l.suffix > alt) return null;
        const arity = lens.arity(alt);
        const out = try an.arena.alloc(PatIndex, arity);
        @memcpy(out[0..l.prefix], items[0..l.prefix]);
        for (out[l.prefix .. arity - l.suffix]) |*c| c.* = try an.anything();
        @memcpy(out[arity - l.suffix ..], items[l.prefix..]);
        return out;
    }

    /// Maranget's specialisation by one alternative of a list column.
    fn specializeList(an: *Analysis, matrix: []const []const PatIndex, lens: LenSplit, alt: u32) Fail![]const []const PatIndex {
        try an.spend(matrix.len + 1);
        var out: std.ArrayList([]const PatIndex) = .empty;
        const arity = lens.arity(alt);
        for (matrix) |row| {
            if (row.len == 0) return error.Malformed;
            switch (an.pats.tag(row[0])) {
                .anything => try out.append(an.arena, try an.concat(try an.anythings(arity), row[1..])),
                .list => if (try an.listCells(row[0], lens, alt)) |cells| {
                    try out.append(an.arena, try an.concat(cells, row[1..]));
                },
                .ctor, .literal => return error.Malformed,
            }
        }
        return out.items;
    }

    /// The counterexample of alternative `alt`, from its cells: `[ _, _ ]`
    /// for `exact 2`, `[ _, ..._, _ ]` for an `at least` of one leading and
    /// one trailing element.
    fn listOf(an: *Analysis, lens: LenSplit, alt: u32, cells: []const PatIndex) Error!PatIndex {
        if (alt < lens.len) return an.makeList(cells, &.{}, false);
        return an.makeList(cells[0..lens.prefix], cells[lens.prefix..], true);
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
                .ctor, .list => return error.Malformed,
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

test "a flat column's key says the same thing about two literals that `eql` does" {
    // `Flat` replaces `specializeByLiteral` with a set, so its key has to
    // agree with `Literal.eql` in BOTH directions: a key that collided where
    // `eql` says the literals differ would report `redundant_pattern` on a
    // branch that runs, and one that differed where `eql` says they are the
    // same would miss one. Every reading `eql` distinguishes is here — the
    // kinds, the two `int` spellings, and the unparsed fallback.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var pats: Patterns = .{ .string_bytes = "1  0x1nopealso" };
    var an: Analysis = .{ .arena = arena.allocator(), .cx = undefined, .pats = &pats, .budget = 0 };

    const lits = [_]Literal{
        .{ .kind = .int, .value = 1, .off = 0, .len = 1 }, // `1`
        .{ .kind = .int, .value = 1, .off = 3, .len = 3 }, // `0x1`, the same number
        .{ .kind = .int, .value = 2, .off = 0, .len = 1 }, // a different number
        .{ .kind = .int, .off = 6, .len = 4, .parsed = false }, // a spelling that did not parse
        .{ .kind = .int, .off = 10, .len = 4, .parsed = false }, // a different one
        .{ .kind = .char, .value = 1, .off = 0, .len = 0 }, // the scalar 1, not the Int 1
        .{ .kind = .string, .off = 0, .len = 1 }, // "1", not the Int either
        .{ .kind = .string, .off = 6, .len = 4 },
    };
    for (lits) |a| {
        for (lits) |b| {
            const same_key = std.mem.eql(u8, try an.literalKey(a), try an.literalKey(b));
            try testing.expectEqual(a.eql(b, &pats), same_key);
        }
    }
}

test "a key row's bytes are a prefix code, so two different rows never collide" {
    // The other half of the same argument, one level up: `Flat` decides a
    // whole ROW by one hash probe, so the concatenation of its cells' keys
    // has to be injective over cell sequences. Two rows that collide would
    // be `redundant_pattern` on a branch that runs, which is the wrong
    // answer this fast path exists to not give. The length prefix is what
    // makes the concatenation a prefix code, and without it `( "ab", "c" )`
    // and `( "a", "bc" )` are the same bytes.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var pats: Patterns = .{ .string_bytes = "abc" };
    var an: Analysis = .{ .arena = arena.allocator(), .cx = undefined, .pats = &pats, .budget = 0 };
    var f: Flat = .{ .arena = arena.allocator() };

    const ab = try an.newLiteral(.{ .kind = .string, .off = 0, .len = 2 });
    const c = try an.newLiteral(.{ .kind = .string, .off = 2, .len = 1 });
    const a = try an.newLiteral(.{ .kind = .string, .off = 0, .len = 1 });
    const bc = try an.newLiteral(.{ .kind = .string, .off = 1, .len = 2 });

    // Copied, because `rowKey` builds into a buffer the next row reuses —
    // which is the aliasing `admit` handles by duping a key it keeps.
    const left = try arena.allocator().dupe(u8, try f.rowKey(&an, &.{ ab, c }));
    try testing.expect(!std.mem.eql(u8, left, try f.rowKey(&an, &.{ a, bc })));
    // A row is not its own prefix either: widths differ, and so do the bytes.
    try testing.expect(!std.mem.eql(u8, left, try f.rowKey(&an, &.{ab})));
    // And two rows that match the same value do share their bytes, which is
    // the direction that finds the redundant branch at all.
    try testing.expectEqualSlices(u8, left, try f.rowKey(&an, &.{ ab, c }));
}
