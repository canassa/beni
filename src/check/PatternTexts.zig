//! The texts of pattern analysis (docs/design/checker.md §6.6): a `case`
//! with a missing possibility, one the analysis could not decide, a
//! refutable pattern in an irrefutable position, and a redundant branch.
//! Kept apart from `Diagnostics.zig` to hold both under
//! `checker-v2.md` §19.1's 1 500 lines; they are still
//! `Diagnostics.Reporter`'s methods, re-exported there by name.

const std = @import("std");
const diagnostic = @import("diagnostic");
const Bir = @import("../bir/Bir.zig");
const Diagnostics = @import("Diagnostics.zig");

const Reporter = Diagnostics.Reporter;
const Error = Reporter.Error;
const ordinalSuffix = Diagnostics.ordinalSuffix;

/// A `case` with no branch for some possibility. `examples` are
/// counterexample patterns already rendered as source syntax by
/// `Render.allocPattern` — at most three of them, because a list of
/// twenty is a wall and the first three say the same thing.
///
/// The patterns arrive rendered rather than as a structure because the
/// store they name constructors from is the module's, and this message
/// is the last thing that will ever read it.
pub fn missingPatterns(r: *Reporter, region: Bir.Inst.Index, examples: []const []const u8) Error!void {
    if (examples.len == 0) return;
    var out = r.writer();
    defer out.deinit();
    const w = &out.writer;
    w.writeAll(
        \\This `case` does not have branches for all possibilities:
        \\
        \\Missing possibilities include:
        \\
        \\
    ) catch return error.OutOfMemory;
    for (examples) |e| w.print("    {s}\n", .{e}) catch return error.OutOfMemory;
    w.writeAll(
        \\
        \\I would have to crash if I saw one of those. Add branches for them!
        \\
        \\Hint: if you want to write a branch's code later, `Debug.todo "…"` holds the
        \\place and has whatever type the branch needs.
        \\
    ) catch return error.OutOfMemory;
    try r.emit(.missing_patterns, region, &out);
}

/// A `case` the usefulness analysis could not decide inside its work
/// budget (checker.md §6.6). An ERROR, not a warning and not silence:
/// `backend.md` §7 compiles a `case` to a decision tree with no default
/// arm, on the strength of "the checker proved exhaustiveness", so a
/// `case` nobody proved anything about is the one remaining way to a
/// wrong answer at exit 0.
///
/// `why` picks between two messages under the one code, because the two
/// ways out differ and a wrong hint is worse than none: the analysis
/// spends WORK, which `--pattern-budget` buys more of, and it spends
/// STACK, which it does not. The author sees one code — "this `case` was
/// not decided" — and the sentence that is true of their program.
///
/// `limit` is whichever of the two ran out, as it was in force and not as
/// what is left of it, so the author can see what they met.
pub fn patternBudgetExhausted(
    r: *Reporter,
    region: Bir.Inst.Index,
    why: enum { budget, depth },
    limit: u32,
) Error!void {
    var out = r.writer();
    defer out.deinit();
    const w = &out.writer;
    switch (why) {
        .budget => w.print(
            \\This `case` is too big for me to prove anything about:
            \\
            \\Deciding whether a `case` covers every possibility can cost exponentially
            \\much, so I spend at most a fixed amount of work on it — {d} steps here — and
            \\this one ran out. I do not know whether a possibility is missing or a branch
            \\is unreachable, and I will not compile a `case` I could not check: the
            \\JavaScript I generate has no fallback branch to land in.
            \\
            \\Splitting the match makes it cheap, because the cost is in the COMBINATIONS:
            \\a helper function per group of constructors, or one `case` per column instead
            \\of one `case` over all of them at once.
            \\
            \\Hint: `--pattern-budget=<n>` raises the limit if the `case` really is meant
            \\to be this big.
            \\
        , .{limit}) catch return error.OutOfMemory,
        .depth => w.print(
            \\This `case` matches on a pattern nested deeper than I can analyse:
            \\
            \\I read {d} levels of nesting and gave up, so I do not know whether a
            \\possibility is missing or a branch is unreachable — and I will not compile a
            \\`case` I could not check: the JavaScript I generate has no fallback branch
            \\to land in.
            \\
            \\Give the inner part a function of its own and match on what that returns.
            \\`--pattern-budget` will not help here; it buys work, and this ran out of
            \\depth.
            \\
        , .{limit}) catch return error.OutOfMemory,
    }
    try r.emit(.pattern_budget_exhausted, region, &out);
}

/// A pattern in an **irrefutable** position — a parameter, a `let`
/// pattern, a `<-` bound pattern — that does not match every value of
/// its type (`language.md` §7). The parser rejects the shapes no type
/// can rescue; this is the other half, where the answer needed the
/// types: a constructor of a type that has more than one.
///
/// `code` picks which position is being talked about, and it is one of
/// the parser's two codes on purpose — the rule is one rule, so the
/// author sees one code for it wherever it was decided. `examples` are
/// rendered by `Render.allocPattern` exactly as `missingPatterns`'
/// are; an EMPTY slice means the analysis ran out of budget, which in
/// this position is a refusal and not silence (checker.md §6.6).
pub fn refutablePattern(
    r: *Reporter,
    region: Bir.Inst.Index,
    code: diagnostic.Code,
    examples: []const []const u8,
) Error!void {
    const what: []const u8 = if (code == .refutable_let_pattern) "A pattern binding" else "A parameter";
    var out = r.writer();
    defer out.deinit();
    const w = &out.writer;
    if (examples.len == 0) {
        w.print(
            \\I cannot prove that this pattern matches every value of its type.
            \\
            \\{s} has to match whatever it is given, and the search that decides
            \\that ran out of budget here (`--pattern-budget`). An answer I could not
            \\compute is a refusal in this position, because there is no branch to fall
            \\through to. Match on the value with `case`, which may be as big as it likes.
            \\
        , .{what}) catch return error.OutOfMemory;
        return r.emit(code, region, &out);
    }
    w.print(
        \\This pattern does not match every value of its type:
        \\
        \\Missing possibilities include:
        \\
        \\
    , .{}) catch return error.OutOfMemory;
    for (examples) |e| w.print("    {s}\n", .{e}) catch return error.OutOfMemory;
    w.print(
        \\
        \\{s} has to match whatever it is given, so there is nowhere for those to
        \\go and I would have to crash. Take the value whole and `case` on it:
        \\
        \\    un m =
        \\        case m of
        \\            Just n ->
        \\                n
        \\
        \\            Nothing ->
        \\                0
        \\
    , .{what}) catch return error.OutOfMemory;
    try r.emit(code, region, &out);
}

/// A branch no value can reach: every shape it matches is taken by a
/// branch above it. `index` is 1-based, as the reader counts them.
pub fn redundantPattern(r: *Reporter, region: Bir.Inst.Index, index: u32) Error!void {
    var out = r.writer();
    defer out.deinit();
    out.writer.print(
        \\The {d}{s} pattern is redundant:
        \\
        \\Any value with this shape is matched by a branch above it, so this branch
        \\never runs. Remove it, or make it more specific than the one that shadows it.
        \\
    , .{ index, ordinalSuffix(index) }) catch return error.OutOfMemory;
    try r.emit(.redundant_pattern, region, &out);
}
