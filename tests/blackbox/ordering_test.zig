//! Declaration-order scenarios for own methods (`checker-v2.md` §10.2–
//! §10.5): whether a program checks, and what it prints or reports, never
//! depends on the order its declarations are written in; and the nesting
//! budget a check that nests another check spends.
//!
//! A process of its own so that it runs in parallel with the other
//! black-box binaries. A scenario that is not GREEN fails the step.

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const Io = std.Io;
const testing = std.testing;

// ┌─────────────────────────────────────────────────────────────────────────┐
// │ SCENARIOS                                                               │
// └─────────────────────────────────────────────────────────────────────────┘

// Every program below is a regression fixture of an order-dependence the
// checker once had. For each, a fixed set of orders of its top-level
// declarations — the written one, the reversed one and three shuffles seeded
// by the program's position in the list — must do what the program's oracle
// twin says:
//
//   - `prints`: build, exit 0 and print the twin's output ("every order
//     prints the same" would pass if every order failed alike);
//   - `checks`: `check` exits 0;
//   - `refused`: exactly one diagnostic, of the code named, byte-identical
//     in every order — the same message, and the same source text under its
//     span.
//
// For `prints` and `checks`, `dump --stage=types` must also be the same in
// every order tried (each declaration's block, whatever its position): a
// group nested at its first demand, however deep, gets the types it gets
// written first.
//
// The orders of one single-file program are packed into one build: each is a
// module `PermPxK` whose `main` became `pub lines : List String`, and a
// `Main` prints every module's lines in order, so one build and one run
// check them all (a failing order is named by the file its diagnostic is
// in). A project's module is permuted one build per order.
const perm_programs = [_]PermProgram{
    // An own method used before its definition, in three modules.
    .{ .name = "o1", .path = "tests/corpus/run/OwnMethodBeforeDefinition", .module = "O1.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodBeforeDefinition/_expected.expected" } },
    .{ .name = "row75", .path = "tests/corpus/run/OwnMethodBeforeDefinition", .module = "Row75.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodBeforeDefinition/_expected.expected" } },
    .{ .name = "box", .path = "tests/corpus/run/OwnMethodBeforeDefinition", .module = "Box.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodBeforeDefinition/_expected.expected" } },
    // Recursion with a comparison and its seven siblings, a miscount of
    // dead declarations, and a mutual group's evidence order.
    .{ .name = "recursion-with-comparison", .path = "tests/corpus/run/RecursionWithComparison.beni", .expect = .{ .prints = "tests/corpus/run/RecursionWithComparison.expected" } },
    .{ .name = "dead", .path = "tests/corpus/run/DeadMiscount.beni", .expect = .{ .prints = "tests/corpus/run/DeadMiscount.expected" } },
    .{ .name = "mutual-group-evidence-order", .path = "tests/corpus/run/MutualGroupEvidenceOrder.beni", .expect = .{ .prints = "tests/corpus/run/MutualGroupEvidenceOrder.expected" } },
    // An own method demanded early, through a value prefix, by a mutual
    // dispatch, and from a group variable outside its caller.
    .{ .name = "demanded-early", .path = "tests/corpus/run/OwnMethodDemandedEarly.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodDemandedEarly.expected" } },
    .{ .name = "twolets", .path = "tests/corpus/run/OwnMethodDemandedTwoLetsDeep.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodDemandedTwoLetsDeep.expected" } },
    .{ .name = "own-method-value-prefix", .path = "tests/corpus/run/OwnMethodValuePrefix.beni", .expect = .{ .prints = "tests/corpus/run/OwnMethodValuePrefix.expected" } },
    .{ .name = "mutual-dispatch", .path = "tests/corpus/run/MutualDispatchMethods.beni", .expect = .{ .prints = "tests/corpus/run/MutualDispatchMethods.expected" } },
    .{ .name = "group-variable-outside-caller", .path = "tests/corpus/run/GroupVariableOutsideCaller.beni", .expect = .{ .prints = "tests/corpus/run/GroupVariableOutsideCaller.expected" } },
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
    // A method on a scrutinee written later or first, a single-member
    // group's receiver, an annotated recursive group's receiver; and the
    // merge variant, whose nested group must not drain its demander's queue.
    .{ .name = "scrutinee-method-later", .path = "tests/corpus/run/ScrutineeMethodLater.beni", .expect = .{ .prints = "tests/corpus/run/ScrutineeMethodLater.expected" } },
    .{ .name = "scrutinee-method-first", .path = "tests/corpus/run/ScrutineeMethodFirst.beni", .expect = .{ .prints = "tests/corpus/run/ScrutineeMethodFirst.expected" } },
    .{ .name = "single-member-group-receiver", .path = "tests/corpus/run/SingleMemberGroupReceiver.beni", .expect = .{ .prints = "tests/corpus/run/SingleMemberGroupReceiver.expected" } },
    .{ .name = "scc-annotated", .path = "tests/corpus/run/RecursiveGroupAnnotatedReceiver.beni", .expect = .{ .prints = "tests/corpus/run/RecursiveGroupAnnotatedReceiver.expected" } },
    .{ .name = "scrutinee-merge-variant", .path = "tests/corpus/check/good/ScrutineeMethodMergeVariant/Later.beni", .expect = .checks },
    // An annotated member of a dispatch cycle instantiates (§6.6).
    .{ .name = "recursive-dispatch-annotated", .path = "tests/corpus/run/RecursiveDispatchAnnotated.beni", .expect = .{ .prints = "tests/corpus/run/RecursiveDispatchAnnotated.expected" } },
    // The refusals: one diagnostic, the same in every order.
    .{ .name = "recursive-dispatch-two-types", .path = "tests/corpus/check/bad/RecursiveDispatchTwoTypes.beni", .expect = .{ .refused = .type_mismatch } },
    .{ .name = "group-receiver-needs-annotation", .path = "tests/corpus/check/bad/RecursiveGroupReceiverNeedsAnnotation.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "group-evidence-receiver", .path = "tests/corpus/check/bad/RecursiveGroupEvidenceReceiver/FirstF.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "group-sub-wanted", .path = "tests/corpus/check/bad/RecursiveGroupSubWanted/FirstF.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "scrutinee-merge-refused", .path = "tests/corpus/check/bad/ScrutineeMethodMergeD14/Later.beni", .expect = .{ .refused = .kind_mismatch } },
    // A dot-call's field-or-method choice, the recursive-group refusal's
    // hint naming one member or the final class and none for rule (a), a
    // merge during the root's boundary, and a refusal whose message shows
    // a type mid-solve (the same code and region in every order).
    .{ .name = "field-call-through-member", .path = "tests/corpus/run/FieldCallThroughMember.beni", .expect = .{ .prints = "tests/corpus/run/FieldCallThroughMember.expected" } },
    .{ .name = "field-call-through-member-cycle", .path = "tests/corpus/run/FieldCallThroughMemberCycle.beni", .expect = .{ .prints = "tests/corpus/run/FieldCallThroughMemberCycle.expected" } },
    .{ .name = "field-call-through-value-recursion", .path = "tests/corpus/run/FieldCallThroughValueRecursion.beni", .expect = .{ .prints = "tests/corpus/run/FieldCallThroughValueRecursion.expected" } },
    .{ .name = "field-call-through-value-demand", .path = "tests/corpus/run/FieldCallThroughValueDemand.beni", .expect = .{ .prints = "tests/corpus/run/FieldCallThroughValueDemand.expected" } },
    .{ .name = "deferred-field", .path = "tests/corpus/run/DeferredReceiverFieldCall.beni", .expect = .{ .prints = "tests/corpus/run/DeferredReceiverFieldCall.expected" } },
    .{ .name = "group-field-call-two-types", .path = "tests/corpus/check/bad/RecursiveGroupFieldCallTwoTypes.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "group-refusal-rendering", .path = "tests/corpus/check/bad/RecursiveGroupRefusalRendering.beni", .expect = .{ .refused_region = .not_equatable } },
    .{ .name = "hint-one-member", .path = "tests/corpus/check/bad/RecursiveGroupHintOneMember.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "hint-all-members", .path = "tests/corpus/check/bad/RecursiveGroupHintAllMembers.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "rule-a-no-recursion-hint", .path = "tests/corpus/check/bad/RuleAMonomorphicNoRecursionHint.beni", .expect = .{ .refused = .type_mismatch } },
    .{ .name = "merge-at-boundary", .path = "tests/corpus/run/MergeAtBoundary", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/MergeAtBoundary/_expected.expected" } },
    // A dot-call joined with a scheme's requirement, both halves of the
    // rule, a `number` receiver's method in a group. A refusal's message
    // renders the record as it stood when met (§10.8).
    .{ .name = "joined-in-group", .path = "tests/corpus/check/bad/DeferredReceiverJoinedInGroup.beni", .expect = .{ .refused_region = .no_methods_on_shape } },
    .{ .name = "joined-p-first", .path = "tests/corpus/check/bad/DeferredReceiverJoinedRequirement/PFirst.beni", .expect = .{ .refused = .no_methods_on_shape } },
    .{ .name = "joined-q-first", .path = "tests/corpus/check/bad/DeferredReceiverJoinedRequirement/QFirst.beni", .expect = .{ .refused = .no_methods_on_shape } },
    .{ .name = "generalised", .path = "tests/corpus/check/bad/DeferredReceiverGeneralised.beni", .expect = .{ .refused = .no_methods_on_shape } },
    .{ .name = "recursive-twin", .path = "tests/corpus/run/DeferredReceiverRecursiveTwin.beni", .expect = .{ .prints = "tests/corpus/run/DeferredReceiverRecursiveTwin.expected" } },
    .{ .name = "number-receiver-in-group", .path = "tests/corpus/check/bad/NumberReceiverMethodInGroup.beni", .expect = .{ .refused = .unknown_method } },
    .{ .name = "number-receiver-in-group-dispatch", .path = "tests/corpus/check/bad/NumberReceiverMethodInGroupDispatch.beni", .expect = .{ .refused = .unknown_method } },
    // Derived contexts by fixpoint (checker-v2.md §11.2). A closed in-flight
    // method (with its nested and permuted twins), the parametric refusal, a
    // re-entrant query, the replayed wanted that merges the asker, a derived
    // query inside an own `eq`'s merged class, and `eq` and `compare`
    // computed jointly over one type-level SCC.
    .{ .name = "closed-own-method", .path = "tests/corpus/run/DerivedContextClosedOwnMethod", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextClosedOwnMethod/_expected.expected" } },
    .{ .name = "closed-own-method-nested", .path = "tests/corpus/run/DerivedContextClosedOwnMethod", .module = "Nested.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextClosedOwnMethod/_expected.expected" } },
    .{ .name = "closed-own-method-permuted", .path = "tests/corpus/run/DerivedContextClosedOwnMethodPermuted", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextClosedOwnMethodPermuted/_expected.expected" } },
    .{ .name = "derived-needs-annotation", .path = "tests/corpus/check/bad/DerivedContextNeedsAnnotation", .module = "Main.beni", .expect = .{ .refused = .method_needs_annotation } },
    .{ .name = "derived-reentrant", .path = "tests/corpus/check/bad/DerivedContextReentrant", .module = "Main.beni", .expect = .{ .refused = .type_mismatch } },
    .{ .name = "derived-merges-asker", .path = "tests/corpus/check/bad/DerivedContextMergesAsker", .module = "PickFirst.beni", .expect = .{ .refused = .kind_mismatch } },
    .{ .name = "in-flight-eq", .path = "tests/corpus/run/DerivedContextInFlightEq", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextInFlightEq/_expected.expected" } },
    .{ .name = "joint-eq-compare", .path = "tests/corpus/run/DerivedContextJointMethods", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextJointMethods/_expected.expected" } },
    // A pass that demands a group which merges down into the asker; a
    // private `eq` used inside its module and two modules away, permuting
    // the declaring and the wrapping module; schema
    // endpoints through the one fixpoint — an exclusion reached through a
    // `via` target that mentions the endpoint back, the same program
    // accepted, a record endpoint, and a comparison inside the schema's own
    // group.
    .{ .name = "pass-merges-down", .path = "tests/corpus/run/DerivedContextPassMergesDown", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/DerivedContextPassMergesDown/_expected.expected" } },
    .{ .name = "private-eq-inside-module", .path = "tests/corpus/run/PrivateEqInsideModule", .module = "M.beni", .expect = .{ .prints = "tests/corpus/run/PrivateEqInsideModule/_expected.expected" } },
    .{ .name = "private-eq-third-module-declaring", .path = "tests/corpus/check/bad/PrivateEqThroughThirdModule", .module = "A.beni", .refused_in = "C.beni", .expect = .{ .refused = .private_method } },
    .{ .name = "private-eq-third-module-wrapping", .path = "tests/corpus/check/bad/PrivateEqThroughThirdModule", .module = "B.beni", .refused_in = "C.beni", .expect = .{ .refused = .private_method } },
    .{ .name = "schema-exclusion-through-own-type", .path = "tests/corpus/check/bad/SchemaWrapperExclusionThroughOwnType.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "schema-endpoint-in-flight", .path = "tests/corpus/check/bad/SchemaEndpointInFlight.beni", .expect = .{ .refused = .method_needs_annotation } },
    // A closed endpoint compared while its schema is in
    // flight is deferred (accepted, or refused once the group is done), an
    // encoded one is never in flight, and a ring closed only through `via`s
    // is one unit.
    .{ .name = "schema-endpoint-in-flight-closed", .path = "tests/corpus/check/good/SchemaEndpointInFlightClosed.beni", .expect = .checks },
    .{ .name = "schema-endpoint-in-flight-function", .path = "tests/corpus/check/bad/SchemaEndpointInFlightFunction.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "schema-encoded-in-flight", .path = "tests/corpus/check/good/SchemaEncodedInFlight.beni", .expect = .checks },
    .{ .name = "schema-via-ring", .path = "tests/corpus/check/good/SchemaViaRing.beni", .expect = .checks },
    // The §11.4 gate demands the schemas it reaches and defers one in
    // flight — each use of the local fixture counted — and a run's own step
    // budget.
    .{ .name = "marker-wrapped-endpoint-local", .path = "tests/corpus/check/bad/EquatableMarkerThroughWrappedEndpointLocal.beni", .count = 2, .expect = .{ .refused = .not_equatable } },
    .{ .name = "marker-unchecked-schema", .path = "tests/corpus/check/bad/EquatableMarkerUncheckedSchema.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "marker-in-flight-schema", .path = "tests/corpus/check/bad/EquatableMarkerInFlightSchema.beni", .expect = .{ .refused = .not_equatable } },
    .{ .name = "schema-via-mutual-own-type", .path = "tests/corpus/check/good/SchemaViaMutualOwnType.beni", .expect = .checks },
    .{ .name = "schema-record-via-wrapped", .path = "tests/corpus/check/good/SchemaRecordViaWrapped.beni", .expect = .checks },
    // Constrained `let` helpers (checker-v2.md §8.4): a `let` helper with a
    // dot-call's own requirement inside a merged group keeps its field call;
    // `let` function bindings with evidence, recursive and mutual; a
    // polymorphic helper and a helper used at two types, across two modules.
    .{ .name = "let-field-call-merged", .path = "tests/corpus/run/LetFieldCallInMergedGroup.beni", .expect = .{ .prints = "tests/corpus/run/LetFieldCallInMergedGroup.expected" } },
    .{ .name = "let-evidence-capture", .path = "tests/corpus/run/LetEvidenceCapture.beni", .expect = .{ .prints = "tests/corpus/run/LetEvidenceCapture.expected" } },
    .{ .name = "let-constrained-helper", .path = "tests/corpus/run/LetConstrainedHelperPolymorphic", .module = "Main.beni", .expect = .{ .prints = "tests/corpus/run/LetConstrainedHelperPolymorphic/_expected.expected" } },
    // Two uses of an alias that drops its parameter,
    // met inside a recursive group, are one type in every order.
    .{ .name = "phantom-alias-mutual-group", .path = "tests/corpus/run/PhantomAliasMutualGroup.beni", .expect = .{ .prints = "tests/corpus/run/PhantomAliasMutualGroup.expected" } },
    // Uses of an alias that drops its parameter, met in a recursive group,
    // with the names they show compared too; and an unannotated helper whose
    // dot-call requirement is answered by a derived method at several
    // types, written above or below its uses.
    .{ .name = "phantom alias uses in a recursive group", .path = "tests/corpus/run/PhantomAliasUnifiesByExpansion.beni", .expect = .{ .prints = "tests/corpus/run/PhantomAliasUnifiesByExpansion.expected" } },
    .{ .name = "a dot-call helper answered by derived methods", .path = "tests/corpus/run/DotCallDerivedThroughHelper.beni", .expect = .{ .prints = "tests/corpus/run/DotCallDerivedThroughHelper.expected" } },
};

// The programs are split over four tests, each taking every fourth one, so
// that a sharded run of this binary spreads them over processes.
test "every order-dependence regression program does what its twin says in a fixed set of orders, first quarter" {
    try permuteQuarter(0);
}

test "every order-dependence regression program does what its twin says in a fixed set of orders, second quarter" {
    try permuteQuarter(1);
}

test "every order-dependence regression program does what its twin says in a fixed set of orders, third quarter" {
    try permuteQuarter(2);
}

test "every order-dependence regression program does what its twin says in a fixed set of orders, fourth quarter" {
    try permuteQuarter(3);
}

/// The programs of `perm_programs` whose index is `quarter` modulo four.
fn permuteQuarter(quarter: usize) !void {
    var s = try Scenario.init("declaration orders");
    defer s.deinit();
    var programs: usize = 0;
    var orders: usize = 0;
    for (perm_programs, 0..) |p, i| {
        if (i % 4 != quarter) continue;
        programs += 1;
        const outcome = try permuteProgram(&s, p, i);
        switch (outcome) {
            .orders => |n| orders += n,
            .red => |v| return s.finish(v),
        }
    }
    try s.finish(.{ .green = true, .signature = "", .detail = try std.fmt.allocPrint(s.arena(), "{d} programs, {d} orders", .{ programs, orders }) });
}

const PermProgram = struct {
    name: []const u8,
    /// A single-file fixture, or a project directory with `module` the file
    /// whose declarations are permuted.
    path: []const u8,
    module: ?[]const u8 = null,
    /// A project refused in ANOTHER file than the one permuted (a
    /// comparison two modules away from a private `eq`): the one
    /// diagnostic is asserted there, at the same text in every order.
    refused_in: ?[]const u8 = null,
    /// How many diagnostics the refusal is, all of the expected code:
    /// exactly that many in every order.
    count: u32 = 1,
    expect: union(enum) {
        /// The oracle twin's stdout, as a file.
        prints: []const u8,
        checks,
        refused: @import("diagnostic").Code,
        /// One diagnostic of this code at the same source text in every
        /// order; its message may show a type as it stood when the refusal
        /// was found (checker-v2.md §10.8).
        refused_region: @import("diagnostic").Code,
    },
};

/// Seeded shuffles tried per program, beside the written and the reversed
/// order.
const shuffles = 3;

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

/// The orders tried for `n` declarations: the written one, the reversed one,
/// and `shuffles` shuffles seeded by the program's index, without
/// repeats (a program of one or two declarations has fewer).
fn declOrders(arena: std.mem.Allocator, n: usize, seed: u64) ![]const []const usize {
    var out: std.ArrayList([]const usize) = .empty;
    const written = try arena.alloc(usize, n);
    for (written, 0..) |*slot, i| slot.* = i;
    try out.append(arena, written);
    const reversed = try arena.dupe(usize, written);
    std.mem.reverse(usize, reversed);
    try appendNew(arena, &out, reversed);
    var prng: std.Random.DefaultPrng = .init(seed);
    for (0..shuffles) |_| {
        const shuffled = try arena.dupe(usize, written);
        prng.random().shuffle(usize, shuffled);
        try appendNew(arena, &out, shuffled);
    }
    return out.items;
}

fn appendNew(arena: std.mem.Allocator, out: *std.ArrayList([]const usize), order: []const usize) !void {
    for (out.items) |seen| if (std.mem.eql(usize, seen, order)) return;
    try out.append(arena, order);
}

const PermOutcome = union(enum) { orders: usize, red: Verdict };

fn readRepo(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(world.max_stream_bytes));
}

/// Program `p`'s orders, tried (`perm_programs`' comment); `index` names its
/// modules and seeds its shuffles.
fn permuteProgram(s: *Scenario, p: PermProgram, index: usize) !PermOutcome {
    const a = s.arena();
    const source_path = if (p.module) |m| try std.fs.path.join(a, &.{ p.path, m }) else p.path;
    const split = try splitDecls(a, try readRepo(a, source_path));
    const orders = try declOrders(a, split.decls.len, index);
    const files = try a.alloc([]const u8, orders.len);
    const texts = try a.alloc([]const u8, orders.len);
    for (orders, files, texts, 0..) |order, *file, *text, k| {
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
    return .{ .orders = orders.len };
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

/// `dump --stage=types` of every order tried: each declaration's block the
/// same, wherever it is written.
fn sameTypes(s: *Scenario, p: PermProgram, files: []const []const u8, orders: []const []const usize) !?Verdict {
    const a = s.arena();
    var first: ?[]const u8 = null;
    for (0..files.len) |k| {
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

/// A permuted program's refusals in one file: exactly
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
            // A project's module refused in every order — one
            // diagnostic of `code` in that module (another module of the
            // project may say its own), at the same source text in every
            // order, with the same message unless `refused_region`.
            const same_text = p.expect == .refused;
            // The refusal may be in another file than the permuted one.
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

// The name an inferred type shows is the same in every declaration order
// ("agree or expand", checker-v2.md §7.1, §21.1). `x : Name` (`type alias
// Name = String`), `y : String`, and a recursive group `f` → `x`, `g` → `y`:
// its members' result is one flex that meets both `Name` and `String`, so it
// shows the expansion, `String`, whichever it meets first; and `x` still
// prints as its annotation is written.
test "an inferred type names the same alias in every declaration order" {
    var s = try Scenario.init("an inferred alias name");
    defer s.deinit();
    const head = "type alias Name =\n    String\n\n\nx : Name\nx =\n    \"x\"\n\n\ny : String\ny =\n    \"y\"\n\n\n";
    const f = "f n =\n    if n == 0 then\n        x\n\n    else\n        g (n - 1)\n\n\n";
    const g = "g n =\n    if n == 0 then\n        y\n\n    else\n        f (n - 1)\n\n\n";
    try s.w.write("FG.beni", head ++ f ++ g);
    try s.w.write("GF.beni", head ++ g ++ f);
    var types: [2][]const u8 = undefined;
    for ([_][]const u8{ "FG.beni", "GF.beni" }, &types) |file, *slot| {
        const run = try s.w.runWith(&.{ "dump", "--stage=types", "--diagnostics=json", file }, .{ .raw_diagnostics = true });
        if (run.exit_code != 0) return s.finish(try s.failed(run));
        // The annotation prints as written.
        if (std.mem.indexOf(u8, run.stdout, "\n  x : Name\n") == null) return s.finish(.{ .green = false, .signature = "stdout-differs", .detail = "`x : Name` is not printed as written" });
        // `f`'s line: the module line and the declaration order differ.
        const at = std.mem.indexOf(u8, run.stdout, "\n  f : ") orelse return s.finish(.{ .green = false, .signature = "stdout-differs", .detail = "no `f` in the dump" });
        const end = std.mem.indexOfScalarPos(u8, run.stdout, at + 1, '\n') orelse run.stdout.len;
        slot.* = run.stdout[at + 1 .. end];
    }
    const same = std.mem.eql(u8, types[0], types[1]);
    try s.finish(.{
        .green = same,
        .signature = if (same) "" else "order-dependent",
        .detail = try std.fmt.allocPrint(s.arena(), "f above g: `{s}`; g above f: `{s}`", .{ types[0], types[1] }),
    });
}

// An own method whose type fits no use of two types of its module is one
// mistake, said once at its declaration, after every use was checked
// (`Instances.ownSignatures`): `type T`, `type V`, `pub eq : T, Int -> Bool`
// and a `==` on each, in two declaration orders, print the same messages in
// the same order.
test "one own method's messages print the same in every declaration order" {
    var s = try Scenario.init("an own method's messages");
    defer s.deinit();
    const t = "type T\n    = T Int\n\n\n";
    const v = "type V\n    = V Int\n\n\n";
    const eq = "pub eq : T, Int -> Bool\neq (T a) b =\n    a == b\n\n\n";
    const one = "one =\n    T 1 == T 1\n\n\n";
    const two = "two =\n    V 2 == V 2\n\n\n";
    // One module name in both orders (a message names `Main.eq`): each order
    // is a project of its own.
    try s.w.write("tv/Main.beni", t ++ v ++ eq ++ one ++ two);
    try s.w.write("vt/Main.beni", two ++ one ++ eq ++ v ++ t);
    var texts: [2][]const u8 = undefined;
    for ([_][]const u8{ "tv", "vt" }, &texts) |file, *slot| {
        const run = try s.w.runWith(&.{ "check", "--no-cache", "--diagnostics=json", file }, .{ .raw_diagnostics = true });
        if (run.exit_code != 1) return s.finish(try s.failed(run));
        const trimmed = std.mem.trim(u8, run.stderr, " \r\n");
        const diags = std.json.parseFromSliceLeaky([]@import("diagnostic").Diagnostic, s.arena(), trimmed, .{}) catch return s.finish(try s.failed(run));
        var out: std.ArrayList(u8) = .empty;
        for (diags) |d| try out.print(s.arena(), "{t}: {s}\n", .{ d.code, d.message });
        slot.* = out.items;
    }
    const same = std.mem.eql(u8, texts[0], texts[1]);
    try s.finish(.{
        .green = same,
        .signature = if (same) "" else "order-dependent",
        .detail = if (same) "one text in both orders" else "the messages differ in text or in order between the two declaration orders",
    });
}

// The nesting budget (checker-v2.md §10.2): chains of own methods `m0 … mn`
// on one type, each calling the next, written in REVERSE dependency order
// (`m0`, which needs `m1`, first), so checking `m0` nests `m1`, which nests
// `m2`, and so on. The budget admits a nested check while the solver depth
// summed over the open groups, plus `nest_cost` (3) per nesting, leaves one
// declaration's worth (4 200) of the budget (8 400): a chain's link costs 4
// depth units and 3, so about 599 nest (`Groups.nest_cost`'s comment). The
// same chains below the budget are timed for linearity in `perf_test.zig`.
//
//   - A chain of 650 links, just past the budget, is refused exactly once —
//     the check that `m0` started runs out at about the 600th link and is
//     refused at that use, and the rest is checked from the next group in
//     SCC order, within the budget — with the hint, and no crash.
//   - A "pair of deep declarations" (§5.6), which the budget admits one at a
//     time (a demand at depth 2 500 leaves 5 900 units): what reaches the
//     refusal is a chain of TWO demands each about 2 150 levels deep. Written
//     with the user first, exactly one `nesting_too_deep`, at the second
//     use, with the hint; with the methods first, it checks (the stated
//     exception to order independence, §10.5).
test "a chain of own methods just past the nesting budget is one nesting_too_deep" {
    var s = try Scenario.init("nesting budget");
    defer s.deinit();
    try s.w.write("C.beni", try chains(s.arena(), 1, 650));
    const verdict = try s.exactlyOneHinted(&.{ "check", "--no-cache", "--diagnostics=json", "C.beni" }, .nesting_too_deep);
    try s.finish(verdict);
}

test "two deep demands in a row are refused once, and the other order checks" {
    var s = try Scenario.init("two deep demands");
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

    /// `args` as they are.
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
    /// different amounts, and can turn a cubic 87 s / 162 s into a
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
