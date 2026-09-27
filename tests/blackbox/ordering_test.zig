//! Declaration-order scenarios for own methods (`checker-v2.md` I9, §10.2–
//! §10.5): R7's permutation scenario `PERM` and its nesting scenarios
//! `NEST-OVER` and `NEST-DEEP`. They were written red into
//! `tests/blackbox/pending_test.zig` (R0's stubs, R7's programs), claimed
//! under `--checker=v2` by R7, and promoted here at the cut-over (R11), when
//! v2 became the checker the gates run (`plans/checker-rewrite.md` §2.5,
//! §2.6). Their timing twin `NEST-UNDER` went to `perf_test.zig`.
//!
//! They are not in `abuse_test.zig`, where §2.5 sends a promoted non-timing
//! scenario, only so that they run as a process of their own in parallel
//! (the reason `abuse_wide_test.zig` was split out, §2.4 *Parts*): `PERM`
//! alone builds and runs thousands of declaration orders. They run on the
//! Debug binary, as they did in `test-pending`. The code is moved verbatim;
//! only the harness changed: a scenario that is not GREEN fails the step.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const Io = std.Io;
const testing = std.testing;

// ┌─────────────────────────────────────────────────────────────────────────┐
// │ SCENARIOS                                                               │
// └─────────────────────────────────────────────────────────────────────────┘

// R7's permutation scenario (plans/checker-rewrite.md §2.5, R7's exit
// criteria; checker-v2.md I9, §10.5): for every program below, every order of
// its top-level declarations — all of them up to 120, else 120 orders spread
// evenly over the whole permutation space by rank (the first and the
// reversed order among them) — must do what the program's oracle twin says:
//
//   - `prints`: build, exit 0 and print the twin's output (S13: "every
//     order prints the same" would pass if every order failed alike);
//   - `checks`: `check` exits 0;
//   - `refused`: exactly one diagnostic, of the code named, byte-identical
//     in every order — the same message, and the same source text under its
//     span (CK-70, CK-72, CK-76: D14's and §10.6's refusals with their hints).
//
// For `prints` and `checks`, `dump --stage=types` must also be the same in
// the written order, the reversed one and four orders between (each
// declaration's block, whatever its position): a group nested at its first
// demand, however deep, gets the types it gets written first (the reviewer
// focus "a nested check started two `let`s deep").
//
// The orders of one single-file program are packed into one build: each is a
// module `PermPxK` whose `main` became `pub lines : List String`, and a
// `Main` prints every module's lines in order, so one build and one run
// check them all (a failing order is named by the file its diagnostic is
// in). A project's module is permuted one build per order.
//
// R8a adds `cbA`/`cbB` (CK-77, the same `type_mismatch`) and `xm`/`xm2` (the
// guard `DerivedCrossMethodCycle`, the same refusal). On 8016030 v1 refuses
// every program that uses an own method above its definition with METHOD
// NEEDS AN ANNOTATION.
const perm_programs = [_]PermProgram{
    // Round 1: disp's `o1`, orch's `row75`, adv's `box` (CK-36).
    .{ .name = "o1", .path = "tests/corpus/run/OwnMethodBeforeDefinition", .module = "O1.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodBeforeDefinition/_expected.expected" } },
    .{ .name = "row75", .path = "tests/corpus/run/OwnMethodBeforeDefinition", .module = "Row75.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodBeforeDefinition/_expected.expected" } },
    .{ .name = "box", .path = "tests/corpus/run/OwnMethodBeforeDefinition", .module = "Box.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodBeforeDefinition/_expected.expected" } },
    // CK-30's `m1b` and its seven siblings, CK-30's miscount, CK-31's `p5`.
    .{ .name = "m1b", .path = "tests/corpus/run/RecursionWithComparison.beni", .expect = .{ .prints = "tests/corpus/run/RecursionWithComparison.expected" } },
    .{ .name = "dead", .path = "tests/corpus/run/DeadMiscount.beni", .expect = .{ .prints = "tests/corpus/run/DeadMiscount.expected" } },
    .{ .name = "p5", .path = "tests/corpus/run/MutualGroupEvidenceOrder.beni", .expect = .{ .prints = "tests/corpus/run/MutualGroupEvidenceOrder.expected" } },
    // CK-63 to CK-66.
    .{ .name = "ck63", .path = "tests/corpus/run/OwnMethodDemandedEarly.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodDemandedEarly.expected" } },
    .{ .name = "twolets", .path = "tests/corpus/run/OwnMethodDemandedTwoLetsDeep.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodDemandedTwoLetsDeep.expected" } },
    .{ .name = "ck64", .path = "tests/corpus/run/OwnMethodValuePrefix.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodValuePrefix.expected" } },
    .{ .name = "ck65", .path = "tests/corpus/run/MutualDispatchMethods.beni", .expect = .{ .prints = "tests/corpus/run/MutualDispatchMethods.expected" } },
    .{ .name = "ck66", .path = "tests/corpus/run/GroupVariableOutsideCaller.beni", .expect = .{ .prints = "tests/corpus/run/GroupVariableOutsideCaller.expected" } },
    // Merges of three and four methods, and a member that demands its
    // cycle at two nodes (§23 items 1 and 8).
    .{ .name = "three", .path = "tests/corpus/run/OwnMethodThreeCycle.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodThreeCycle.expected" } },
    .{ .name = "four", .path = "tests/corpus/run/OwnMethodFourCycle.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodFourCycle.expected" } },
    .{ .name = "twice", .path = "tests/corpus/run/OwnMethodCycleDemandedTwice.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodCycleDemandedTwice.expected" } },
    .{ .name = "value-back-edge", .path = "tests/corpus/run/OwnMethodValueBackEdge.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodValueBackEdge.expected" } },
    .{ .name = "nest-after-default", .path = "tests/corpus/check/good/NestAfterDefault.beni", .expect = .checks },
    // The §6 guards.
    .{ .name = "annotated-or-first", .path = "tests/corpus/run/OwnMethodAnnotatedOrFirst.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodAnnotatedOrFirst.expected" } },
    .{ .name = "value-prefix", .path = "tests/corpus/run/OwnMethodValuePrefixOrdered.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodValuePrefixOrdered.expected" } },
    .{ .name = "in-scrutinee", .path = "tests/corpus/run/OwnMethodInScrutineeOrdered.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodInScrutineeOrdered.expected" } },
    // Round 3: `rq1`, `rq2` (CK-73 and its guard), `capt`, the annotated
    // `sccA`/`sccB`; and CK-73's merge variant, whose nested group must not
    // drain its demander's queue.
    .{ .name = "rq1", .path = "tests/corpus/run/ScrutineeMethodLater.beni", .expect = .{ .prints = "tests/corpus/run/ScrutineeMethodLater.expected" } },
    .{ .name = "rq2", .path = "tests/corpus/run/ScrutineeMethodFirst.beni", .expect = .{ .prints = "tests/corpus/run/ScrutineeMethodFirst.expected" } },
    .{ .name = "capt", .path = "tests/corpus/run/SingleMemberGroupReceiver.beni", .expect = .{ .prints = "tests/corpus/run/SingleMemberGroupReceiver.expected" } },
    .{ .name = "scc-annotated", .path = "tests/corpus/run/RecursiveGroupAnnotatedReceiver.beni", .expect = .{ .prints = "tests/corpus/run/RecursiveGroupAnnotatedReceiver.expected" } },
    .{ .name = "rq1-merge", .path = "tests/corpus/check/good/ScrutineeMethodMergeVariant/Later.beni", .expect = .checks },
    // An annotated member of a dispatch cycle instantiates (§6.6).
    .{ .name = "ck70-annotated", .path = "tests/corpus/run/RecursiveDispatchAnnotated.beni", .expect = .{ .prints = "tests/corpus/run/RecursiveDispatchAnnotated.expected" } },
    // The refusals: one diagnostic, the same in every order.
    .{ .name = "ck70", .path = "tests/corpus/check/bad/RecursiveDispatchTwoTypes.beni", .expect = .{ .refused = .type_mismatch } },
    .{ .name = "ck72", .path = "tests/corpus/check/bad/RecursiveGroupReceiverNeedsAnnotation.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "evA", .path = "tests/corpus/check/bad/RecursiveGroupEvidenceReceiver/FirstF.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "subA", .path = "tests/corpus/check/bad/RecursiveGroupSubWanted/FirstF.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "rq1-d14", .path = "tests/corpus/check/bad/ScrutineeMethodMergeD14/Later.beni", .expect = .{ .refused = .kind_mismatch } },
    // R7's reviews: a dot-call's field-or-method choice (CK-105), D14's
    // hint naming one member or the final class and none for rule (a), a
    // merge during the root's boundary, and a refusal whose message shows
    // a type mid-solve (the same code and region in every order).
    .{ .name = "rec1", .path = "tests/corpus/run/FieldCallThroughMember.beni", .expect = .{ .prints = "tests/corpus/run/FieldCallThroughMember.expected" } },
    .{ .name = "rec1c", .path = "tests/corpus/run/FieldCallThroughMemberCycle.beni", .expect = .{ .prints = "tests/corpus/run/FieldCallThroughMemberCycle.expected" } },
    .{ .name = "rec2", .path = "tests/corpus/run/FieldCallThroughValueRecursion.beni", .expect = .{ .prints = "tests/corpus/run/FieldCallThroughValueRecursion.expected" } },
    .{ .name = "rec1v", .path = "tests/corpus/run/FieldCallThroughValueDemand.beni", .expect = .{ .prints = "tests/corpus/run/FieldCallThroughValueDemand.expected" } },
    .{ .name = "deferred-field", .path = "tests/corpus/run/DeferredReceiverFieldCall.beni", .expect = .{ .prints = "tests/corpus/run/DeferredReceiverFieldCall.expected" } },
    .{ .name = "t104", .path = "tests/corpus/check/bad/RecursiveGroupFieldCallTwoTypes.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "t102", .path = "tests/corpus/check/bad/RecursiveGroupRefusalRendering.beni", .expect = .{ .refused_region = .not_equatable } },
    .{ .name = "hint2", .path = "tests/corpus/check/bad/RecursiveGroupHintOneMember.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "hint1", .path = "tests/corpus/check/bad/RecursiveGroupHintAllMembers.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "p3n", .path = "tests/corpus/check/bad/RuleAMonomorphicNoRecursionHint.beni", .expect = .{ .refused = .type_mismatch } },
    .{ .name = "merge-at-boundary", .path = "tests/corpus/run/MergeAtBoundary", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/MergeAtBoundary/_expected.expected" } },
    // R7's round-2 review: a dot-call joined with a scheme's requirement (X1),
    // both halves of the rule (S2), a `number` receiver's method in a group
    // (CK-106).
    // Its message renders the record as it stood when met (§10.8, I9's scope).
    .{ .name = "joined-in-group", .path = "tests/corpus/check/bad/DeferredReceiverJoinedInGroup.beni", .expect = .{ .refused_region = .no_methods_on_shape } },
    .{ .name = "joined-p-first", .path = "tests/corpus/check/bad/DeferredReceiverJoinedRequirement/PFirst.beni", .expect = .{ .refused = .no_methods_on_shape } },
    .{ .name = "joined-q-first", .path = "tests/corpus/check/bad/DeferredReceiverJoinedRequirement/QFirst.beni", .expect = .{ .refused = .no_methods_on_shape } },
    .{ .name = "generalised", .path = "tests/corpus/check/bad/DeferredReceiverGeneralised.beni", .expect = .{ .refused = .no_methods_on_shape } },
    .{ .name = "recursive-twin", .path = "tests/corpus/run/DeferredReceiverRecursiveTwin.beni", .expect = .{ .prints = "tests/corpus/run/DeferredReceiverRecursiveTwin.expected" } },
    .{ .name = "ck106", .path = "tests/corpus/check/bad/NumberReceiverMethodInGroup.beni", .expect = .{ .refused = .unknown_method } },
    .{ .name = "ck106-dispatch", .path = "tests/corpus/check/bad/NumberReceiverMethodInGroupDispatch.beni", .expect = .{ .refused = .unknown_method } },
    // R8a: derived contexts by fixpoint (checker-v2.md §11.2). A closed
    // in-flight method (CK-67, its nested and permuted twins), the
    // parametric refusal (CK-69), a re-entrant query (CK-74), the replayed
    // wanted that merges the asker (CK-77), a derived query inside an own
    // `eq`'s merged class (R7's S6), and `eq` and `compare` computed jointly
    // over one type-level SCC (round 4 R8-2).
    .{ .name = "ck67", .path = "tests/corpus/run/DerivedContextClosedOwnMethod", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextClosedOwnMethod/_expected.expected" } },
    .{ .name = "ck67-nested", .path = "tests/corpus/run/DerivedContextClosedOwnMethod", .module = "Nested.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextClosedOwnMethod/_expected.expected" } },
    .{ .name = "ck67-permuted", .path = "tests/corpus/run/DerivedContextClosedOwnMethodPermuted", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextClosedOwnMethodPermuted/_expected.expected" } },
    .{ .name = "ck69", .path = "tests/corpus/check/bad/DerivedContextNeedsAnnotation", .module = "Main.beni", .expect = .{ .refused = .method_needs_annotation } },
    .{ .name = "ck74", .path = "tests/corpus/check/bad/DerivedContextReentrant", .module = "Main.beni", .expect = .{ .refused = .type_mismatch } },
    .{ .name = "ck77", .path = "tests/corpus/check/bad/DerivedContextMergesAsker", .module = "PickFirst.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "s6-in-flight-eq", .path = "tests/corpus/run/DerivedContextInFlightEq", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextInFlightEq/_expected.expected" } },
    .{ .name = "joint-eq-compare", .path = "tests/corpus/run/DerivedContextJointMethods", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextJointMethods/_expected.expected" } },
    // R8b: a pass that demands a group which merges down into the asker
    // (CK-117); D1 inside the module and two modules away from the private
    // `eq`, permuting the declaring and the wrapping module (CK-22); schema
    // endpoints through the one fixpoint — an exclusion reached through a
    // `via` target that mentions the endpoint back, the same program
    // accepted, a record endpoint, and a comparison inside the schema's own
    // group (CK-24, CK-118).
    .{ .name = "ck117", .path = "tests/corpus/run/DerivedContextPassMergesDown", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextPassMergesDown/_expected.expected" } },
    .{ .name = "d1-inside", .path = "tests/corpus/run/PrivateEqInsideModule", .module = "M.beni", .expect = .{ .prints = "tests/corpus/run/PrivateEqInsideModule/_expected.expected" } },
    .{ .name = "d1-declaring", .path = "tests/corpus/check/bad/PrivateEqThroughThirdModule", .module = "A.beni", .refused_in = "C.beni", .expect = .{ .refused = .private_method } },
    .{ .name = "d1-wrapping", .path = "tests/corpus/check/bad/PrivateEqThroughThirdModule", .module = "B.beni", .refused_in = "C.beni", .expect = .{ .refused = .private_method } },
    .{ .name = "ck24-through-own", .path = "tests/corpus/check/bad/SchemaWrapperExclusionThroughOwnType.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "ck24-in-flight", .path = "tests/corpus/check/bad/SchemaEndpointInFlight.beni", .expect = .{ .refused = .method_needs_annotation } },
    // R8b's review round: a closed endpoint compared while its schema is in
    // flight is deferred (accepted, or refused once the group is done), an
    // encoded one is never in flight, and a ring closed only through `via`s
    // is one unit (CK-119).
    .{ .name = "ck24-in-flight-closed", .path = "tests/corpus/check/good/SchemaEndpointInFlightClosed.beni", .expect = .checks },
    .{ .name = "ck24-in-flight-function", .path = "tests/corpus/check/bad/SchemaEndpointInFlightFunction.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "ck24-encoded-in-flight", .path = "tests/corpus/check/good/SchemaEncodedInFlight.beni", .expect = .checks },
    .{ .name = "ck119-ring", .path = "tests/corpus/check/good/SchemaViaRing.beni", .expect = .checks },
    // R8b's round-2 review: the §11.4 gate demands the schemas it reaches
    // and defers one in flight (CK-120) — each use of the local fixture
    // counted — and a run's own step budget (CK-125).
    .{ .name = "ck120-local", .path = "tests/corpus/check/bad/EquatableMarkerThroughWrappedEndpointLocal.beni", .count = 2, .expect = .{ .refused = .not_equatable } },
    .{ .name = "ck120-unchecked", .path = "tests/corpus/check/bad/EquatableMarkerUncheckedSchema.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "ck120-in-flight", .path = "tests/corpus/check/bad/EquatableMarkerInFlightSchema.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "ck118-joint", .path = "tests/corpus/check/good/SchemaViaMutualOwnType.beni", .expect = .checks },
    .{ .name = "ck118-record", .path = "tests/corpus/check/good/SchemaRecordViaWrapped.beni", .expect = .checks },
    // R14 (D5, checker-v2.md §8.4 *As built by R14*): a `let` helper with a
    // dot-call's own requirement inside a merged group keeps its field call;
    // `let` function bindings with evidence, recursive and mutual; the
    // row-76 helper and a helper used at two types, across two modules.
    .{ .name = "r14-field-merged", .path = "tests/corpus/run/LetFieldCallInMergedGroup.beni", .expect = .{ .prints = "tests/corpus/run/LetFieldCallInMergedGroup.expected" } },
    .{ .name = "r14-capture", .path = "tests/corpus/run/LetEvidenceCapture.beni", .expect = .{ .prints = "tests/corpus/run/LetEvidenceCapture.expected" } },
    .{ .name = "r14-polymorphic", .path = "tests/corpus/run/LetConstrainedHelperPolymorphic", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/LetConstrainedHelperPolymorphic/_expected.expected" } },
};

test "PERM: every declaration order of an own-method program does what its twin says" {
    var s = try Scenario.init("PERM");
    defer s.deinit();
    var orders: usize = 0;
    for (perm_programs, 0..) |p, i| {
        const outcome = try permuteProgram(&s, p, i);
        switch (outcome) {
            .orders => |n| orders += n,
            .red => |v| return s.finish(v),
        }
    }
    try s.finish(.{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(s.arena(), "{d} programs, {d} orders", .{ perm_programs.len, orders }) });
}

const PermProgram = struct {
    name: []const u8,
    /// A single-file fixture, or a project directory with `module` the file
    /// whose declarations are permuted.
    path: []const u8,
    module: ?[]const u8 = null,
    /// A project refused in ANOTHER file than the one permuted (R8b: D1's
    /// comparison two modules away from the private `eq`): the one
    /// diagnostic is asserted there, at the same text in every order.
    refused_in: ?[]const u8 = null,
    /// How many diagnostics the refusal is, all of the expected code:
    /// exactly that many in every order (R8b's round-2 review).
    count: u32 = 1,
    expect: union(enum) {
        /// The oracle twin's stdout, as a file.
        prints: []const u8,
        checks,
        refused: @import("diagnostic").Code,
        /// One diagnostic of this code at the same source text in every
        /// order; its message may show a type as it stood when the refusal
        /// was found (checker-v2.md §10.8, I9's scope).
        refused_region: @import("diagnostic").Code,
    },
};

/// Most orders tried per program.
const perm_cap = 120;

/// A source file split at its top-level declarations: the `import` lines, and
/// each declaration with its annotation. Top-level comments are dropped.
const Split = struct { imports: []const u8, decls: []const []const u8 };

fn splitDecls(arena: std.mem.Allocator, text: []const u8) !Split {
    var imports: std.ArrayList(u8) = .empty;
    var decls: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    // The name the current declaration's annotation names, while its
    // definition has not started.
    var annotated: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == ' ') {
            if (current.items.len != 0) {
                try current.appendSlice(arena, line);
                try current.append(arena, '\n');
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "--")) continue;
        if (std.mem.startsWith(u8, line, "import ")) {
            try imports.appendSlice(arena, line);
            try imports.append(arena, '\n');
            continue;
        }
        const rest = if (std.mem.startsWith(u8, line, "pub ")) line[4..] else line;
        const name = rest[0 .. std.mem.indexOfAny(u8, rest, " (=:") orelse rest.len];
        const is_annotation = std.mem.startsWith(u8, rest[name.len..], " : ");
        const joins = !is_annotation and annotated != null and std.mem.eql(u8, annotated.?, name);
        if (!joins and current.items.len != 0) {
            try decls.append(arena, std.mem.trimEnd(u8, current.items, "\n"));
            current = .empty;
        }
        annotated = if (is_annotation) name else null;
        try current.appendSlice(arena, line);
        try current.append(arena, '\n');
    }
    if (current.items.len != 0) try decls.append(arena, std.mem.trimEnd(u8, current.items, "\n"));
    return .{ .imports = imports.items, .decls = decls.items };
}

/// `main : Program` / `main = Node.printLines X` made `pub lines : List
/// String` / `lines = X`, so a packing `Main` can print it.
fn asLines(arena: std.mem.Allocator, decl: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, decl, "main ")) return decl;
    const a = try std.mem.replaceOwned(u8, arena, decl, "main : Program", "pub lines : List String");
    const b = try std.mem.replaceOwned(u8, arena, a, "\nmain =", "\nlines =");
    return std.mem.replaceOwned(u8, arena, b, "Node.printLines", "");
}

/// n!, saturating.
fn factorial(n: usize) u128 {
    var f: u128 = 1;
    var i: usize = 2;
    while (i <= n) : (i += 1) f = std.math.mul(u128, f, i) catch return std.math.maxInt(u128);
    return f;
}

/// The permutation of `0..out.len` of lexicographic rank `rank`.
fn permutationAt(out: []usize, rank: u128) void {
    var pool: [32]usize = undefined;
    for (0..out.len) |i| pool[i] = i;
    var left = out.len;
    var r = rank;
    for (out) |*slot| {
        const f = factorial(left - 1);
        const d: usize = @intCast(r / f);
        r %= f;
        slot.* = pool[d];
        std.mem.copyForwards(usize, pool[d .. left - 1], pool[d + 1 .. left]);
        left -= 1;
    }
}

/// The orders tried for `n` declarations: every one when there are at most
/// `perm_cap`, else `perm_cap` ranks spread evenly from the first to the last
/// (the reversed order).
fn orderRanks(arena: std.mem.Allocator, n: usize) ![]const u128 {
    const total = factorial(n);
    const count: usize = if (total <= perm_cap) @intCast(total) else perm_cap;
    const ranks = try arena.alloc(u128, count);
    for (ranks, 0..) |*r, k| r.* = if (count == 1) 0 else if (total <= perm_cap) k else (total - 1) * k / (count - 1);
    return ranks;
}

const PermOutcome = union(enum) { orders: usize, red: Verdict };

fn readRepo(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(world.max_stream_bytes));
}

/// Program `p`'s orders, tried (`perm_programs`' comment); `index` names its
/// modules.
fn permuteProgram(s: *Scenario, p: PermProgram, index: usize) !PermOutcome {
    const a = s.arena();
    const source_path = if (p.module) |m| try std.fs.path.join(a, &.{ p.path, m }) else p.path;
    const split = try splitDecls(a, try readRepo(a, source_path));
    const ranks = try orderRanks(a, split.decls.len);
    const order = try a.alloc(usize, split.decls.len);
    const files = try a.alloc([]const u8, ranks.len);
    const texts = try a.alloc([]const u8, ranks.len);
    const orders = try a.alloc([]const usize, ranks.len);
    for (ranks, files, texts, orders, 0..) |rank, *file, *text, *o, k| {
        permutationAt(order, rank);
        o.* = try a.dupe(usize, order);
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, split.imports);
        for (order) |d| {
            try out.appendSlice(a, "\n\n");
            try out.appendSlice(a, if (p.module == null and p.expect == .prints) try asLines(a, split.decls[d]) else split.decls[d]);
            try out.append(a, '\n');
        }
        text.* = out.items;
        file.* = if (p.module) |m| m else try std.fmt.allocPrint(a, "Perm{d}x{d}.beni", .{ index, k });
    }
    const red = if (p.module) |module|
        try permuteProject(s, p, module, files, texts, orders)
    else switch (p.expect) {
        .prints => |twin| try permutePrints(s, p, index, twin, files, texts, orders),
        .checks => try permuteChecks(s, p, files, texts, orders),
        .refused => |code| try permuteRefused(s, p, code, true, files, texts, orders),
        .refused_region => |code| try permuteRefused(s, p, code, false, files, texts, orders),
    };
    if (red) |v| return .{ .red = v };
    return .{ .orders = ranks.len };
}

fn redAt(s: *Scenario, p: PermProgram, order: []const usize, v: Verdict, total: usize) !Verdict {
    return .{ .green = false, .signature = v.signature, .detail = try std.fmt.allocPrint(s.arena(), "{s} (of {d} orders), order {any}: {s}", .{ p.name, total, order, v.detail[0..@min(v.detail.len, 600)] }) };
}

/// The order whose module a build's first diagnostic is in.
fn failingOrder(built: world.Result, files: []const []const u8) usize {
    var best: usize = 0;
    var at: usize = std.math.maxInt(usize);
    for (files, 0..) |f, k| {
        const pos = std.mem.indexOf(u8, built.stderr, f) orelse continue;
        if (pos < at) {
            at = pos;
            best = k;
        }
    }
    return best;
}

/// Every order of a single-file program in one build: `PermMain<i>` prints
/// each order's `lines`, so the run must print the twin's output once per
/// order.
fn permutePrints(s: *Scenario, p: PermProgram, index: usize, twin: []const u8, files: []const []const u8, texts: []const []const u8, orders: []const []const usize) !?Verdict {
    const a = s.arena();
    for (files, texts) |f, t| try s.w.write(f, t);
    var main: std.ArrayList(u8) = .empty;
    try main.appendSlice(a, "import Node exposing (Program)\n");
    for (0..files.len) |k| try main.print(a, "import Perm{d}x{d}\n", .{ index, k });
    try main.appendSlice(a, "\n\nmain : Program\nmain =\n    Node.printLines\n        (List.concat\n            [ ");
    for (0..files.len) |k| {
        if (k != 0) try main.appendSlice(a, "            , ");
        try main.print(a, "Perm{d}x{d}.lines\n", .{ index, k });
    }
    try main.appendSlice(a, "            ]\n        )\n");
    const entry = try std.fmt.allocPrint(a, "PermMain{d}.beni", .{index});
    try s.w.write(entry, main.items);
    const out_dir = try std.fmt.allocPrint(a, "out{d}", .{index});
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "build", "--no-cache", "--diagnostics=json", "--platform=node", try std.fmt.allocPrint(a, "--out={s}", .{out_dir}), entry });
    try args.appendSlice(a, files);
    const built = try s.w.runWith(try s.argv(args.items), .{ .raw_diagnostics = true, .timeout_ms = world.bulk_timeout_ms });
    if (built.exit_code != 0) {
        const k = failingOrder(built, files);
        return try redAt(s, p, orders[k], try s.failed(built), files.len);
    }
    const program = try s.w.nodeWith(try std.fmt.allocPrint(a, "{s}/_main.mjs", .{out_dir}), world.bulk_timeout_ms);
    if (program.exit_code != 0) return try redAt(s, p, orders[0], .{ .green = false, .signature = try std.fmt.allocPrint(a, "exit=0 program-exit={d}", .{program.exit_code}), .detail = std.mem.trim(u8, program.stderr[0..@min(program.stderr.len, 160)], " \r\n") }, files.len);
    const expected = try readRepo(a, twin);
    for (orders, 0..) |o, k| {
        const at = k * expected.len;
        if (program.stdout.len < at + expected.len or !std.mem.eql(u8, program.stdout[at..][0..expected.len], expected)) {
            return try redAt(s, p, o, .{ .green = false, .signature = "exit=0 stdout-differs", .detail = "" }, files.len);
        }
    }
    if (program.stdout.len != expected.len * files.len) return try redAt(s, p, orders[0], .{ .green = false, .signature = "exit=0 stdout-differs", .detail = "" }, files.len);
    return try sameTypes(s, p, files, orders);
}

/// Every order checks, and has the same types.
fn permuteChecks(s: *Scenario, p: PermProgram, files: []const []const u8, texts: []const []const u8, orders: []const []const usize) !?Verdict {
    const a = s.arena();
    for (files, texts) |f, t| try s.w.write(f, t);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "check", "--no-cache", "--diagnostics=json", "--platform=node" });
    try args.appendSlice(a, files);
    const run = try s.w.runWith(try s.argv(args.items), .{ .raw_diagnostics = true, .timeout_ms = world.bulk_timeout_ms });
    if (run.exit_code != 0 or std.mem.trim(u8, run.stderr, " \r\n").len != 0) {
        return try redAt(s, p, orders[failingOrder(run, files)], try s.failed(run), files.len);
    }
    return try sameTypes(s, p, files, orders);
}

/// `dump --stage=types` of the written order, the reversed one and four
/// between: each declaration's block the same, wherever it is written.
fn sameTypes(s: *Scenario, p: PermProgram, files: []const []const u8, orders: []const []const usize) !?Verdict {
    const a = s.arena();
    const picks = [_]usize{ 0, files.len / 5, 2 * files.len / 5, 3 * files.len / 5, 4 * files.len / 5, files.len - 1 };
    var first: ?[]const u8 = null;
    for (picks) |k| {
        const run = try s.w.runWith(try s.argv(&.{ "dump", "--stage=types", "--platform=node", files[k] }), .{ .raw_diagnostics = true });
        if (run.exit_code != 0) return try redAt(s, p, orders[k], try s.failed(run), files.len);
        const blocks = try declBlocks(a, run.stdout);
        if (first) |f| {
            if (!std.mem.eql(u8, f, blocks)) {
                var at: usize = 0;
                while (at < f.len and at < blocks.len and f[at] == blocks[at]) at += 1;
                const from = std.mem.lastIndexOfScalar(u8, f[0..at], '\n') orelse 0;
                const detail = try std.mem.replaceOwned(u8, a, try std.fmt.allocPrint(a, "dump --stage=types differs from the written order's: {s} vs {s}", .{ f[from..@min(f.len, from + 90)], blocks[from..@min(blocks.len, from + 90)] }), "\n", " | ");
                return try redAt(s, p, orders[k], .{ .green = false, .signature = "exit=0 types-differ", .detail = detail }, files.len);
            }
        } else first = blocks;
    }
    return null;
}

/// A types dump's declaration blocks, sorted and joined, without its
/// `module` line.
fn declBlocks(a: std.mem.Allocator, dump: []const u8) ![]const u8 {
    var blocks: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, dump, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "module ") or std.mem.trim(u8, line, " ").len == 0) continue;
        if (line.len > 2 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ') {
            if (current.items.len != 0) try blocks.append(a, current.items);
            current = .empty;
        }
        try current.appendSlice(a, line);
        try current.append(a, '\n');
    }
    if (current.items.len != 0) try blocks.append(a, current.items);
    std.mem.sort([]const u8, blocks.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    for (blocks.items) |b| try out.appendSlice(a, b);
    return out.items;
}

/// Every order refused with one diagnostic of `code`, byte-identical: the
/// same message, and the same text under its span.
fn permuteRefused(s: *Scenario, p: PermProgram, code: @import("diagnostic").Code, same_text: bool, files: []const []const u8, texts: []const []const u8, orders: []const []const usize) !?Verdict {
    const a = s.arena();
    for (files, texts) |f, t| try s.w.write(f, t);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "check", "--no-cache", "--diagnostics=json", "--platform=node" });
    try args.appendSlice(a, files);
    const run = try s.w.runWith(try s.argv(args.items), .{ .raw_diagnostics = true, .timeout_ms = world.bulk_timeout_ms });
    const trimmed = std.mem.trim(u8, run.stderr, " \r\n");
    const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, a, trimmed, .{}) catch return try redAt(s, p, orders[0], try s.failed(run), files.len);
    var reference: ?Refusals = null;
    for (files, texts, orders) |f, t, o| {
        const got = (try refusals(a, diags, f, t, code, p.count)) orelse return try redAt(s, p, o, try s.failed(run), files.len);
        if (reference) |r| {
            if ((same_text and !std.mem.eql(u8, r.message, got.message)) or !std.mem.eql(u8, r.text, got.text)) {
                return try redAt(s, p, o, .{ .green = false, .signature = try std.fmt.allocPrint(a, "exit=1 codes={t}×{d} differs", .{ code, p.count }), .detail = "the diagnostics differ from the written order's" }, files.len);
            }
        } else reference = got;
    }
    return null;
}

/// A permuted program's refusals in one file (R8b's round-2 review): exactly
/// `count` diagnostics, every one of `code`, as their messages and the source
/// text under their spans, sorted — so the same refusals in any order of
/// declarations compare equal. Null when the count or a code differs.
const Refusals = struct { message: []const u8, text: []const u8 };

fn refusals(a: std.mem.Allocator, diags: []const @import("diagnostic").Diagnostic, file: []const u8, source: []const u8, code: @import("diagnostic").Code, count: u32) !?Refusals {
    var pairs: std.ArrayList([2][]const u8) = .empty;
    for (diags) |d| {
        if (!std.mem.eql(u8, std.fs.path.basename(d.span.file), file)) continue;
        if (d.code != code) return null;
        try pairs.append(a, .{ spanText(source, d.span.start.line, d.span.start.col, d.span.end.line, d.span.end.col), d.message });
    }
    if (pairs.items.len != count) return null;
    std.mem.sort([2][]const u8, pairs.items, {}, struct {
        fn lessThan(_: void, x: [2][]const u8, y: [2][]const u8) bool {
            const o = std.mem.order(u8, x[0], y[0]);
            return if (o != .eq) o == .lt else std.mem.lessThan(u8, x[1], y[1]);
        }
    }.lessThan);
    var message: std.ArrayList(u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    for (pairs.items) |pr| {
        try text.appendSlice(a, pr[0]);
        try text.append(a, 0);
        try message.appendSlice(a, pr[1]);
        try message.append(a, 0);
    }
    return .{ .message = message.items, .text = text.items };
}

/// The source text from `line:col` to `end_line:end_col` (1-based, the end
/// exclusive).
fn spanText(text: []const u8, line: usize, col: usize, end_line: usize, end_col: usize) []const u8 {
    const start = offsetOf(text, line, col) orelse return "";
    const end = offsetOf(text, end_line, end_col) orelse return "";
    return if (end >= start) text[start..end] else "";
}

fn offsetOf(text: []const u8, line: usize, col: usize) ?usize {
    var at: usize = 0;
    var l: usize = 1;
    while (l < line) : (l += 1) at = (std.mem.indexOfScalarPos(u8, text, at, '\n') orelse return null) + 1;
    return @min(at + col - 1, text.len);
}

/// A project's module in every order, one build each: the project's other
/// files as they are.
fn permuteProject(s: *Scenario, p: PermProgram, module: []const u8, files: []const []const u8, texts: []const []const u8, orders: []const []const usize) !?Verdict {
    const a = s.arena();
    _ = files;
    var dir = try Io.Dir.cwd().openDir(testing.io, p.path, .{ .iterate = true });
    defer dir.close(testing.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".beni")) continue;
        const name = try a.dupe(u8, entry.name);
        try names.append(a, name);
        if (std.mem.eql(u8, name, module)) continue;
        try s.w.write(name, try readRepo(a, try std.fs.path.join(a, &.{ p.path, name })));
    }
    switch (p.expect) {
        .prints => |twin_path| {
            const twin = try readRepo(a, twin_path);
            var sources: std.ArrayList([]const u8) = .empty;
            try sources.appendSlice(a, &.{ "build", "--no-cache", "--diagnostics=json", "--platform=node", "--out=out" });
            try sources.appendSlice(a, names.items);
            for (texts, orders) |t, o| {
                try s.w.write(module, t);
                const built = try s.w.runWith(try s.argv(sources.items), .{ .raw_diagnostics = true });
                if (built.exit_code != 0) return try redAt(s, p, o, try s.failed(built), texts.len);
                const program = try s.w.node(world.entry_file);
                if (program.exit_code != 0 or !std.mem.eql(u8, program.stdout, twin)) {
                    return try redAt(s, p, o, .{ .green = false, .signature = "exit=0 stdout-differs", .detail = "" }, texts.len);
                }
            }
            return null;
        },
        .refused, .refused_region => |code| {
            // R8a: a project's module refused in every order — one
            // diagnostic of `code` in that module (another module of the
            // project may say its own), at the same source text in every
            // order, with the same message unless `refused_region`.
            const same_text = p.expect == .refused;
            // R8b: the refusal may be in another file than the permuted one.
            const target = p.refused_in orelse module;
            const target_text: ?[]const u8 = if (p.refused_in) |f| try readRepo(a, try std.fs.path.join(a, &.{ p.path, f })) else null;
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(a, &.{ "check", "--no-cache", "--diagnostics=json", "--platform=node" });
            try args.appendSlice(a, names.items);
            var reference: ?Refusals = null;
            for (texts, orders) |t, o| {
                try s.w.write(module, t);
                const run = try s.w.runWith(try s.argv(args.items), .{ .raw_diagnostics = true, .timeout_ms = world.bulk_timeout_ms });
                const trimmed = std.mem.trim(u8, run.stderr, " \r\n");
                const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, a, trimmed, .{}) catch return try redAt(s, p, o, try s.failed(run), texts.len);
                const got = (try refusals(a, diags, target, target_text orelse t, code, p.count)) orelse return try redAt(s, p, o, try s.failed(run), texts.len);
                if (reference) |ref| {
                    if ((same_text and !std.mem.eql(u8, ref.message, got.message)) or !std.mem.eql(u8, ref.text, got.text)) {
                        return try redAt(s, p, o, .{ .green = false, .signature = try std.fmt.allocPrint(a, "exit=1 codes={t}×{d} differs", .{ code, p.count }), .detail = "the diagnostics differ from the written order's" }, texts.len);
                    }
                } else reference = got;
            }
            return null;
        },
        .checks => unreachable,
    }
}

// R7's nesting scenarios (S-3, S-4; checker-v2.md §10.2): chains of own
// methods `m0 … mn` on one type, each calling the next, written in REVERSE
// dependency order (`m0`, which needs `m1`, first), so checking `m0` nests
// `m1`, which nests `m2`, and so on. The budget admits a nested check while
// the solver depth summed over the open groups, plus `nest_cost` (3) per
// nesting, leaves one declaration's worth (4 200) of the budget (8 400): a
// chain's link costs 4 depth units and 3, so about 599 nest (calibrated in
// a Debug build, 2026-09-26: `Groups.nest_cost`'s comment).
//
//   - NEST-UNDER, the same chains below the budget timed for linearity, is
//     `perf_test.zig`'s (ReleaseFast).
//   - NEST-OVER (Debug): one chain of 1 000 links is refused exactly once —
//     the check that `m0` started runs out at about the 600th link and is
//     refused at that use, and the rest is checked from the next group in
//     SCC order, within the budget — with the hint, and no crash.
//   - NEST-DEEP (Debug): round 4's "pair of deep declarations" (§5.6),
//     which the budget as specified admits (a demand at depth 2 500 leaves
//     5 900 units): what reaches the refusal is a chain of TWO demands each
//     about 2 150 levels deep. Written with the user first, exactly one
//     `nesting_too_deep`, at the second use, with the hint; with the
//     methods first, it checks (I9's stated exception, §10.5).
test "NEST-OVER: a chain past the nesting budget is one nesting_too_deep" {
    var s = try Scenario.init("NEST-OVER");
    defer s.deinit();
    try s.w.write("C.beni", try chains(s.arena(), 1, 1_000));
    const verdict = try s.exactlyOneHinted(&.{ "check", "--no-cache", "--diagnostics=json", "C.beni" }, .nesting_too_deep);
    try s.finish(verdict);
}

test "NEST-DEEP: two deep demands in a row are refused once, and the other order checks" {
    var s = try Scenario.init("NEST-DEEP");
    defer s.deinit();
    const a = s.arena();
    const user = try deepUse(a, "use u =\n    ", "(T 0).m ()", 2_150);
    const method = try deepUse(a, "pub m (T x) u =\n    ", "(T x).m2 ()", 2_150);
    const last = "pub m2 (T x) u =\n    x\n";
    try s.w.write("First.beni", try std.mem.concat(a, u8, &.{ "type T\n    = T Int\n\n\nf x =\n    x\n\n\n", user, "\n\n", method, "\n\n", last }));
    try s.w.write("Last.beni", try std.mem.concat(a, u8, &.{ "type T\n    = T Int\n\n\nf x =\n    x\n\n\n", last, "\n\n", method, "\n\n", user }));
    const refused = try s.exactlyOneHinted(&.{ "check", "--no-cache", "--diagnostics=json", "First.beni" }, .nesting_too_deep);
    if (!refused.green) return s.finish(refused);
    const run = try s.timed(&.{ "check", "--no-cache", "--diagnostics=json", "Last.beni" }, world.bulk_timeout_ms) orelse
        return s.finish(.{ .green = false, .signature = "timeout", .detail = "Last.beni did not finish" });
    if (run.result.exit_code != 0) return s.finish(try s.failed(run.result));
    try s.finish(.{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(a, "{s}; the other order checks", .{refused.detail}) });
}

/// `head` then `f (f (… inner …))`, `depth` calls deep.
fn deepUse(arena: std.mem.Allocator, head: []const u8, inner: []const u8, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, head);
    for (0..depth) |_| try out.appendSlice(arena, "f (");
    try out.appendSlice(arena, inner);
    for (0..depth) |_| try out.append(arena, ')');
    try out.append(arena, '\n');
    return out.items;
}

/// `count` chains of `n + 1` own methods, chain `c` on type `Tc`:
/// `pub mc_0 (Tc x) u = (Tc x).mc_1 ()` … `pub mc_n (Tc x) u = x`, each
/// written BEFORE the one it calls.
fn chains(arena: std.mem.Allocator, count: usize, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..count) |c| {
        try out.print(arena, "type T{d}\n    = T{d} Int\n\n\n", .{ c, c });
        for (0..n) |i| try out.print(arena, "pub m{d}_{d} (T{d} x) u =\n    (T{d} x).m{d}_{d} ()\n\n\n", .{ c, i, c, c, c, i + 1 });
        try out.print(arena, "pub m{d}_{d} (T{d} x) u =\n    x\n\n\n", .{ c, n, c });
    }
    return out.items;
}

// ┌─────────────────────────────────────────────────────────────────────────┐
// │ HARNESS                                                                 │
// └─────────────────────────────────────────────────────────────────────────┘

/// A scenario's verdict, in `pending_test.zig`'s vocabulary: GREEN, or the
/// red signature and a detail naming the program and order that failed.
const Verdict = struct {
    green: bool,
    signature: []const u8,
    detail: []const u8,
};

/// `pending_test.zig`'s `Scenario`, cut to what these scenarios use.
const Scenario = struct {
    id: []const u8,
    w: World,
    arena_state: std.heap.ArenaAllocator,

    fn init(comptime id: []const u8) !Scenario {
        return .{
            .id = id,
            .w = try World.init(testing.allocator, testing.io),
            .arena_state = .init(testing.allocator),
        };
    }

    fn deinit(s: *Scenario) void {
        s.w.deinit();
        s.arena_state.deinit();
    }

    fn arena(s: *Scenario) std.mem.Allocator {
        return s.arena_state.allocator();
    }

    /// `args` as they are (the pending harness added `BENI_CHECKER`'s flag
    /// here until R12 deleted it).
    fn argv(_: *Scenario, args: []const []const u8) ![]const []const u8 {
        return args;
    }

    /// One compiler run, timed; null when it was killed at `kill_ms` of WALL
    /// time.
    ///
    /// `ms` is the child's own CPU time, user + system (`world.Result.cpu_ms`,
    /// from `wait4`'s rusage), and the wall clock only where the platform
    /// reports none. Every verdict below compares `ms`: a concurrent build on
    /// the same machine stretches the wall clock of the two points by
    /// different amounts, and once turned CK-40's cubic 87 s / 162 s into a
    /// ratio of 1.85 and a false GREEN. It cannot add CPU time the child did
    /// not spend, and `--jobs=1` everywhere keeps CPU time equal to work.
    fn timed(s: *Scenario, args: []const []const u8, kill_ms: i64) !?struct { ms: i64, wall_ms: i64, result: world.Result } {
        const start = Io.Timestamp.now(testing.io, .awake);
        const result = s.w.runWith(try s.argv(args), .{ .raw_diagnostics = true, .timeout_ms = kill_ms }) catch |err| switch (err) {
            error.CompilerTimeout => return null,
            else => return err,
        };
        const wall_ms = start.durationTo(Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
        return .{ .ms = result.cpu_ms orelse wall_ms, .wall_ms = wall_ms, .result = result };
    }

    /// The walker's `exit=<n> codes=<code>×<k>,…` for a run that did not end
    /// the way the scenario needs; the detail lists the first few
    /// diagnostics.
    fn failed(s: *Scenario, r: world.Result) !Verdict {
        const a = s.arena();
        const trimmed = std.mem.trim(u8, r.stderr, " \r\n");
        var detail: std.ArrayList(u8) = .empty;
        const codes = codes: {
            if (trimmed.len == 0) break :codes "none";
            const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, a, trimmed, .{}) catch {
                try detail.appendSlice(a, trimmed[0..@min(trimmed.len, 160)]);
                break :codes "unparsed";
            };
            for (diags[0..@min(diags.len, 4)], 0..) |d, i| {
                if (i != 0) try detail.appendSlice(a, ", ");
                try detail.print(a, "{t} {s}:{d}:{d}", .{ d.code, std.fs.path.basename(d.span.file), d.span.start.line, d.span.start.col });
            }
            if (diags.len > 4) try detail.print(a, " and {d} more", .{diags.len - 4});
            if (diags.len == 0) break :codes "none";
            const names = try a.alloc([]const u8, diags.len);
            for (diags, names) |d, *n| n.* = @tagName(d.code);
            std.mem.sort([]const u8, names, {}, struct {
                fn lessThan(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lessThan);
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < names.len) {
                var j = i;
                while (j < names.len and std.mem.eql(u8, names[j], names[i])) j += 1;
                if (i != 0) try out.append(a, ',');
                try out.print(a, "{s}×{d}", .{ names[i], j - i });
                i = j;
            }
            break :codes out.items;
        };
        return .{
            .green = false,
            .signature = try std.fmt.allocPrint(a, "exit={d} codes={s}", .{ r.exit_code, codes }),
            .detail = detail.items,
        };
    }

    /// `exactlyOne`, and its message says what to annotate (§10.2's hint).
    fn exactlyOneHinted(s: *Scenario, args: []const []const u8, code: @import("diagnostic").Code) !Verdict {
        const run = try s.timed(args, world.bulk_timeout_ms) orelse
            return .{ .green = false, .signature = "timeout", .detail = "did not finish" };
        const trimmed = std.mem.trim(u8, run.result.stderr, " \r\n");
        const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, s.arena(), trimmed, .{}) catch return s.failed(run.result);
        if (run.result.exit_code != 1 or diags.len != 1 or diags[0].code != code) return s.failed(run.result);
        if (std.mem.indexOf(u8, diags[0].message, "Hint: annotate `") == null) return .{ .green = false, .signature = "exit=1 no-hint", .detail = diags[0].message[0..@min(diags[0].message.len, 160)] };
        return .{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(s.arena(), "one {t} at {d}:{d}, with the hint, in {d} ms", .{ code, diags[0].span.start.line, diags[0].span.start.col, run.ms }) };
    }

    /// A verdict that is not GREEN fails the test, with its signature and
    /// detail.
    fn finish(s: *Scenario, v: Verdict) !void {
        if (v.green) return;
        std.debug.print("{s}: RED [{s}] {s}\n", .{ s.id, v.signature, v.detail });
        return error.ScenarioRed;
    }
};
