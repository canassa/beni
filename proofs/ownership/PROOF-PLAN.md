# Ownership soundness proof plan

This plan covers [issue #165](https://github.com/canassa/beni/issues/165).
The source baseline is `927b7dcd4` on `origin/master`, dated 2026-10-15.
The branch then advanced to `f1ab9cc87`; those four commits changed no Lean model rule.
The branch later advanced to `23e571c18`; the later commits also changed no Lean model rule.
The branch rebased onto `0452a59c4` on 2026-10-16.
That base merges the audit repair and the emitter holder rule. It changes no Lean model rule.
The linked-write proof branch starts from merged master `a584b2ee4`.
Its runtime write helpers match the enumerator baseline. No additional expression or primitive case enters this proof slice.
This document specifies proof work. It does not certify the checker.

## Contract and current status

Read these sources before each dependent proof:

- [README.md](README.md), [DESIGN.md](DESIGN.md), and [COVERAGE.md](COVERAGE.md).
- [The thesis soundness chapter](../../docs/thesis/ownership/ch-soundness.tex), especially §6.3, Lemma 6.7, and Table 6.2.
- [Syntax.lean](Ownership/Syntax.lean), [Semantics.lean](Ownership/Semantics.lean), [Domain.lean](Ownership/Domain.lean), [Checker.lean](Ownership/Checker.lean), and [Soundness.lean](Ownership/Soundness.lean).

Three statements still use `sorry`: `invariant_preserved`, `summary_sound`, and `map_summary_sound`.
`accepted_traces_agree` depends on `invariant_preserved`.
The existing proofs establish heap operations and some conditional naming facts.
They do not construct the naming for an accepted execution.

Keep the checker, interpreter behavior, and theorem claims unchanged until each defect receives its required decision.
Never add an axiom or use a kernel bypass.
Do not remove a pinned obligation until its proof passes the audit.

## Check the statements before induction

The current source exposes these obstacles.
Preserve each concrete witness before the dependent proof starts.

### Construction fuel

Track this defect in [issue #168](https://github.com/canassa/beni/issues/168).
The executable witness is [ConstructionFuel.lean](Ownership/StatementChecks/ConstructionFuel.lean).

`ValueSemantics.prim` concatenates construction operands without extra ticks.
Before the #168 fix, `InPlaceSemantics.prim` ticked once per element of each later spread.
`Invariant.fuel` requires equal remaining fuel.
The public main theorem uses the same fuel bound for both runs.

Use this closed witness:

```text
let xs = [1]
let ys = [2]
construct [true, true] [xs, ys]
```

The checker accepts its two distinct allocation sites.
Five expression evaluations consume five value ticks.
The old in-place construction consumed a sixth tick.
At fuel 5, the value run succeeded and the in-place run failed.
At fuel 6, both runs succeeded but their remaining fuel differed.

This was a Lean interpreter defect against the equal-fuel contract.
It does not establish an unsafe ownership verdict in the Zig compiler.
Do not remove fuel equality or weaken the main theorem to hide it.
Cesar selected the value interpreter as the reference on 2026-10-15 (dashboard q3).
The in-place construction now spends no element ticks.
The regression proves equal traces at fuel 5 and one remaining tick in both states at fuel 6.
Both growth checks and the bounded construction loop remain intact.

### View links

Track the approved premise repair in [issue #169](https://github.com/canassa/beni/issues/169).
[ViewLinks.lean](Ownership/StatementChecks/ViewLinks.lean) proves `no_invariant` (no naming satisfies the strengthened invariant at the #169 pre-state) and, for the same witness in allocation order, `only_linkNamed` and `ordered_no_invariant` (the state fails `LinkNamed` alone); it keeps `no_post_invariant` for the record.

Before 2026-10-16, `Invariant` constrained the heap and naming but not `State.links`; since then it carries `linksValid` and `linkNamed` (as built below).
`writeLinked` can change another address through these links.
Separation by address alone cannot frame that change.

For example, let address 0 hold `[]` and address 1 hold `[0]`.
Link address 0 as the suffix view of address 1.
Give their variables distinct abstract sites and keep the source variable live.
A push through address 0 changes address 1 despite the distinct names.
The current arbitrary-state hypotheses do not connect the names to the link.

Propose a link invariant that includes these facts:

- Each link has valid addresses and the specified prefix or suffix contents.
- The link graph terminates and satisfies the nonempty-source condition.
- Each written storage component has a permission that covers every array that its linked write changes.
- Concrete certificate reasoning accounts for the model's distinct view addresses.

Use a conditional permission for written storage instead of global origin closure under links.
For each permitted write, cover its complete linked storage component with the concrete write permission.
Require that component to remain separate from live protected paths outside the consumed receiver path.
Protected paths include outer frames, permanent observers, and unfinished operand reads.
Derive this separation at accepted callers from actual live paths and the caller's alias-aware demand premises.
Do not infer a write permission from valid link contents alone.

A read-only component needs no write permission.
Keep legal read-only aliases, including distinct canonical names for a view and its source.
Do not require every `γ o` to contain the whole linked storage component.
Such a global requirement conflicts with `Separating` at legal `readBoth(rest, xs)` calls.

Cesar narrowed the enumerator condition on 2026-10-16 at 09:01 UTC (dashboard q4).
Check that no accepted program writes one side of a view/source split while the other side remains live.
A read-only split, such as `readBoth(rest, xs)`, is legal and is not a checker defect.
Cesar's q1 rule classifies a reachable accepted write-while-live split as a checker bug.
Inspect main-context states and call frames for this condition.
Also check arbitrary states admitted by the theorem.
A consistency check on link contents alone does not establish alias separation.
Cesar authorized stronger link premises in q1. Complete the enumerator check first and derive the premises at accepted callers.
The hash-attested grammar-2 run visited 226,103 program cases and completed every one of its 71,762 accepted runs.
It checked 91,214 attempted writes, including 837 writes with linked storage.
It found zero q1 hits and zero incomplete accepted runs.
The run includes all 105,150 bound-2 programs and both generators at three 20,000-candidate seeds.
This finite result does not prove the link clauses.
The review of #248 found a bound-2 coverage gap, tracked in [#253](https://github.com/canassa/beni/issues/253).
Grammar 2 did not reach a main-context view write while its source remained live.
Its campaign also omitted rejected-program diagnostics. Its accepted zero did not complete Cesar's enumerator prerequisite.
The grammar-3 follow-up adds a prelude-source observation and rejected-program diagnostics at fuel 5,000.
Its complete bound-2 run visits 157,824 programs and completes every one of its 84,037 accepted runs.
Accepted q1 hits and actual observer-storage changes both equal zero.
Rejected reach contains 28 main-view, 170 main-source, 54 call-view, and 114 call-source events.
The nonvacuity condition requires all four categories from enumeration itself.
[The complete capture](evidence/diagnostic-reach/README.md) separates rejected reach, execution errors, and accepted checks.
Complete the #253 follow-up before the #169 premise repair. These finite results do not prove the repaired premise.
[PR #245](https://github.com/canassa/beni/pull/245) supplies the #160 memory repair through sequential module processes.
Its committed-tree audit passed with every check intact. The expanded enumerator source also requires its complete audit before publication.
Inspect actual write events and their live readers, including outer call frames and unfinished operations.
Count incomplete executions separately. Interpreter agreement or final heap differences cannot replace this check.

As built (2026-10-16): `Invariant` has the clauses `linksValid : LinksValid hs` and `linkNamed : LinkNamed hs env live γ`.
`LinksValid` records the link structure every reachable state has: the view is allocated after its source, both exist, the source is nonempty, and no view has two sources.
`LinkNamed` is the narrowed clause: for every array a live path or a permanent observer protects, every array in its link component has exactly its origins.
The clause is conditional on protection, not on a write. At a read-only split such as `readBoth(rest, xs)` both sides are live, so the clause names the view and its source alike; that is possible because the checker's view rule gives a view its source's origins and a fresh site (`Checker.lean`, `primitive`, `.view`). Distinct canonical names for the two sides exist only in a callee frame, where `Invariant` does not apply, so R1 states its premise on written storage. A component that nothing protects is unconstrained.
`LinkClauses.lean` proves `LinksValid` with the same heap and links, after an allocation, after a `set!` of a nonempty list and after a view; `LinkNamed` with the same heap, links and observers; and that the per-link closure `LinkClosed` gives `LinkNamed` and survives a naming that keeps old origins and names a new view by its source's origins. No theorem uses these lemmas yet.
`Invariant` does not give `LinkClosed`: a dead split admits distinct names. So the step must keep `LinkNamed` itself: a component that nothing protects before a step becomes protected only through an operand, which the pre-state protects already; and the post-naming keeps the old arrays' origins and names a new view by its source's origins. `LinkClosed` is available in the main context only because of the view rule; it is a sufficient condition, not a clause.
The first bullet's contents fact is not a clause. The model's `put` writes with `write`, not `writeLinked`, so the garbage view of a closed and viewed builder goes stale while the program is accepted and both runs agree (`ViewLinks.lean`, *A stale garbage view*). A protected view is never stale: its cells include its source's, so the demand on the source fails.
`StatementChecks/ViewLinks.lean` proves that the #169 pre-state admits no naming under the clauses.
Open: preservation of `LinkNamed` under a successful `writeLinked` (the protected set changes with the heap) and under a call; the fourth bullet (certificate reasoning over view addresses); the written-storage premise of `summary_sound` and `map_summary_sound` (R1); the validity and snapshot premises (R2); and their derivation at accepted callers.
Three obligations of the step cases, named by the review of PR #273:
a post-naming must exist that keeps every old array's origins and names a new view by exactly its source's origins (`linkClosed_viewed`), and a write that moves a source's origins must move its views' origins with it;
every writer keeps arrays nonempty (`linksValid_set` takes `xs ≠ []`): `push`, `set`, `construct` and the focus write-back never shorten an array, and each step case shows it for its own write;
the view step splits on the source's emptiness: an empty source allocates a fresh `[]` with no link (`linksValid_push`), a nonempty one links (`linksValid_viewed`, with `lookup` and `nonempty` from the run).
#258 still leaves open the direct controls for `inCall` and `rawObservedWrites`, the rejected-error classes, generated accepted read-only linked calls, the `CallRecord.preKept` wording, and the historical strict-false result with its source-hash scope in the evidence README; none of them is a premise of the clauses.

### Local linked-write frame

[LinkedWriteFrame.lean](Ownership/LinkedWriteFrame.lean) proves the runtime frame for a successful `writeLinked` operation.
Its initial undirected link component contains every address that the operation changes.
The operation preserves links, permanent observer registrations, and heap lookups outside that component.
The proof follows the real ancestor splice and descendant refresh, including their explicit depth bounds.
Complete finite representations outside the component retain their observations at the supplied snapshot depth.
The observer corollary covers all permanent registrations, including repeated aliases, records, and closure captures.
The `writeCounted` lemmas preserve the same heap frame and an individual representation.
The example changes both a source and its view while an independent registered observer retains `[7]`.

These lemmas assume runtime success. They establish no general execution success or checker permission.
They need no valid-link or acyclic-link premise for this conditional frame.
They establish no link-validity preservation, result correspondence, certificate preservation, or `CallSound.noNewHolders` clause.
The accepted-caller proof must still derive component separation from the actual live paths and demand premises.
Do not replace that obligation with global origin closure under links.
Keep legal read-only view/source aliases within the planned contract.
All three general proof obligations remain open.

### Summary observer permissions

Track the approved premise repair in [issue #170](https://github.com/canassa/beni/issues/170).
The complete premise witness is [SummaryObservers.lean](Ownership/StatementChecks/SummaryObservers.lean).

`summary_sound` accepts arbitrary pre-call observers.
Its hypotheses do not connect observers to the summary's written inputs.
An observer of a written input can acquire another input through a store.
That store need not appear in the summary's `escapes` row.

Use a declaration `f(xs, ys) = push xs ys`.
Its inputs have types `xs : List (List Int)` and `ys : List Int`.
Publish its cached summary from an accepted caller with two empty literals at distinct sites.
Run its cached summary with `pre.heap = #[[], []]` and `pre.kept = #[.ref 0]`.
The push stores `.ref 1` into address 0.
The observer then reaches address 1 although no observer reached it before.
The summary records the outer write without an escape of the stored input.
This contradicts `CallSound.noNewHolders` if the stated input descriptions hold.
The extra observer belongs to the theorem witness, not the accepted caller.

Propose a call admissibility premise that excludes observer access to written storage.
Derive that premise from caller escapes and demand checks at actual accepted calls.
Check the same premise for called once environments and linked storage.
Cesar authorized observer-safety premises in q2. Complete the enumerator check first and derive the premises from accepted call demands.
The hash-attested scan checked 51,088 actual calls and found no dangling inputs or observers.
The public-premise filter matched 43,432 calls and left 7,656 unmatched under its selected witnesses.
Matched calls include 21,560 with canonical written or consumed targets; their direct and linked observer-hit counts are zero.
The raw scan found two direct-observer hits in unmatched cache candidates and zero linked-observer hits.
The worker interprets both native probe records as unsuitable cache-summary matches.
Both records show unchanged pre-existing observed arrays.
At `v6:20261011:11101`, call 3, entry 2 cannot describe the actual array capture through its empty callback environment.
At `v6:17:1707`, call 5, entry 1 expects a writing, non-escaping callback; the actual callback writes nothing and escapes its argument.
The strict raw result remains false. Keep both hits and the 10,336 unmatched candidates explicit.
The filter uses one canonical naming and one chosen closure-class interpretation.
A failed chosen witness does not exclude every possible theorem instance.
Do not infer complete theorem-instance coverage or a checker defect from these unmatched candidates.
The fresh diagnostic capture completed with unchanged source and executable hashes. Its strict result remains false.
The expanded source also requires its complete audit with the PR #245 repair before publication.
Check written and consumed input paths under the complete public premises, including the concrete closure descriptions in `classes`.
Report matched, unmatched, incomplete, direct-observer, and linked-observer counts separately.

### Summary pre-state links and validity

The review extended [#169 with R1](https://github.com/canassa/beni/issues/169#issuecomment-6213025667).
A linked write can change a second canonical input without its write row.
The current summary premises describe both inputs under distinct origins but impose no condition on `pre.links`.
An invariant repair alone cannot repair `summary_sound`, because that theorem has no invariant premise.

The review extended [#170 with R2](https://github.com/canassa/beni/issues/170#issuecomment-6213026741).
A dangling observer can name the next allocation address before the call.
Allocating `[input]` there creates a new observer path without writing the input or publishing an escape.
The written-input observer premise alone cannot exclude this state.
These arbitrary pre-states refute statements; they do not establish reachable checker defects.

As built (2026-10-17): both summary theorems take `linked : LinkedWritesCovered e.summary e.inputs (args ++ caps) args.length pre`.
It says: for every input array at a permitted canonical path (a `W` or consume row, or an `env` path with a `calls` row), every input array its link component holds is at a permitted path.
`StatementChecks/LinkSummary.lean` keeps the R1 witness: every old premise holds there, `CallSound.writes` fails, and the new premise refuses the state.
The premise constrains input arrays only, so a read-only split keeps its distinct canonical names inside both statements.
The falsifier's call check counts a call that fails it as vacuous (`vacuousLinked`) and carries `preLinks` into the pre-state.
As built (2026-10-17): `CallDerivation.linkedWritesCovered_of_applyCall` proves the derivation at a first-order call without captures. `applyCall` demands every published write and consume row against the live cells after the call and the other operand paths (`otherPaths`); the operands are live, so `Invariant.described` names each input array at every path by the actual's cells (`namesAt` of a first-order, known abstract is recorded at that path); `linkNamed` makes a linked input array share the written array's origins; and the Disjoint test refuses the overlap. The hypotheses name the operands as live variables with their abstracts and values, in elementwise form; the wiring from `inferExpr`'s `.app` case (`mapM`, `callKnown`, `summarise`, base rows from `normalized`) is open.
Residual: the hypothesis `known`, no `unknown` cell on any actual, is stronger than the Known test, which excludes `unknown` on the written cells only. The call case must establish it on its own, or the lemma must be restated for a holder whose `unknown` root names everything below it.
Open: calls with captures, and calls with function-valued inputs. There the permitted `env` path comes with a `calls` row, and the demands are `callKnown`'s once-callback demand and `demandCallbackCaptures`, whose Disjoint operand set is the captures only; whether an accepted higher-order call can write one side of a link held by another operand is a question for the enumerator before any premise is claimed there.
The validity and snapshot premises (R2) belong to #170 and are not stated here.
Add caller-derived link, validity, snapshot, and frame premises to the planned summary and map contracts.
Cover inputs, captures, observers, and every linked or protected heap region that the call can expose.
Require allocated references, valid links, and finite complete representations for the snapshots that the paired proof needs.
Derive these facts from accepted execution and preserve them through calls and allocations.
Do not assume them from `Describes` alone.
The hash-attested actual-call scan found zero dangling input and observer references.
Complete the expanded source's audit before the repairs.
Keep read-only observed inputs and legal read-only view/source calls within the internal contract.

## Induction measure

Use strong induction on `depth`, the first argument of both `eval` definitions.
Generalize the state fuel, heaps, environments, continuation uses, naming, and checker contexts.
The state fuel and the expression depth are separate quantities.

Every recursive expression evaluation uses `depth - 1`:

- The right-hand side and continuation of a `letE`.
- The selected branch or constructor arm.
- The callee body of an `app` or `recur`.
- The initialization and body of an `entry`.
- Each traversal step and each selected focus body.

Use a nested induction on completed iterations for a traversal or construction loop.
Carry the accumulator, unprocessed source, outside holders, observers, and remaining fuel through that induction.
Prove that a permitted write cannot grow a live traversal source.

Order the two theorem phases lexicographically as `(depth, phase)`:

1. Prove generalized expression preservation at `(depth, 0)`.
2. Derive the call contract at `(depth, 1)` from preservation of the callee body at `(depth, 0)`.

An expression at depth `d + 1` uses a call contract at depth `d`.
`callResult` enters its body at the supplied depth without another decrement.
The phase order therefore avoids a same-depth circular proof.
Checker inference fuel and fixpoint rounds do not measure runtime recursion.

This induction covers the finite fuelled Lean model.
It does not prove the thesis's full machine invariant for fibers, suspension, or an unbounded event protocol.

## Strengthened internal statement

Prove a generalized preservation theorem for validated main, declaration, and scope contexts.
Keep `invariant_preserved` as its main-context corollary after any approved statement repair.
`MainContext` alone cannot describe a callee or a traversal step.

Use this specification for the internal statement:

```text
ValidatedContext p accepted ctx checkerBefore
AcceptedInference ctx abstractEnv expression after site checkerBefore result checkerAfter
FrameInvariant ctx valueState heapState pairedEnv live abstractEnv escapes naming
AdmissibleTypesAndClosures declarations heapState pairedEnv abstractEnv expression
  ->
matched successful evaluations with:
  FrameInvariant on the continuation;
  corresponding, typed results;
  Describes result and HonestClosures result;
  a separating post-naming compatible with surviving names;
  a heap frame for all protected outside holders;
  recorded effects bounded by the validated summary;
or matched evaluation failure.
```

`live` includes expression uses and continuation uses.
Generalize the expression fuel and interpreter `self` arguments.
Connect `self` to the declaration and its captured values.
Preserve the current theorem's success and failure directions.

The internal premises must describe these facts:

- The checker state contains only validated cache entries under matching guards.
- Recursive calls use the final validated summary assignment.
- Owned canonical paths satisfy the caller's concrete demand permissions.
- Outside frames retain their protected paths throughout the callee body.
- Live values correspond and carry path descriptions and both certificates.
- Dead values retain valid types and immutable-path names for `close`.
- Closure descriptions agree recursively on code, captures, and once classification.
- Abstract bottom and constructor alternatives agree with concrete inhabitation.
- Binders preserve the ordinary typing and no-shadowing context.
- Observer snapshots correspond, and their reachable references remain valid.
- The callee observer clause protects observed storage from the call's permitted writes, including consumes, once environments, and linked effects.
- Read-only inputs can remain observed; do not require every canonical observer origin to satisfy the main-context `Invariant.keptEscaped` clause.
- Caller escapes and accepted demands establish the callee observer clause after instantiation.
- Valid links and finite snapshot witnesses cover the call's reachable and protected heap regions.
- Recorded escapes and private transfer authority satisfy their context-specific contracts.

Construct fresh names for new arrays without invalidating surviving descriptions.
Use a relation between entry and exit namings rather than an unrestricted replacement.
Instantiate and discharge this relation at every call and scope boundary.

The current `CallSound` clauses do not provide this entire call contract.
Prove result descriptions, certificates, closure honesty, and outside-holder framing in the internal theorem.
Do not assume clause 4 or add it as an axiom.
Add proof-only execution witnesses if callback-prefix permissions need explicit records.

### Projection to the public summary theorems

`summary_sound` starts from an in-place pre-state, not a supplied value run.
Construct the paired value configuration before applying expression preservation.
Use the finite representation witnesses to snapshot every argument, capture, and permanent observer in `pre.heap`.
Build the paired input environment from these snapshots and the concrete `args ++ caps`.
Set the value state's `kept` array to the observer snapshots.
Copy `pre.fuel`, `pre.reads`, and `pre.externalReads` to its corresponding fields.
Establish typing, closure honesty, and the callee frame invariant from the caller-derived premises.
Use the callee observer clause above, not the main-context `Invariant.keptEscaped` clause.

At the supplied expression depth, split on the total value evaluation.
The internal failure direction turns value failure into in-place failure.
That contradicts the supplied successful `callResult`.
The value success direction therefore supplies a matched successful in-place evaluation.
Determinism identifies its result and post-state with the supplied `r` and `post`.
Then project `CallSound` clauses 1–3 from the internal effect, result, and observer guarantees.
For `map_summary_sound`, also project the result certificate from the same internal contract.
Keep the expression depth and state fuel independent throughout this construction.
Prove every new premise at accepted callers; do not replace the public conclusions with weaker claims.

### Alias-aware instantiation for linked storage

Canonical inputs require care for read-only aliases and linked addresses.
Distinct parameter origins cannot share an address under `Separating`.
Closing each origin under linked storage also exposes this conflict for distinct view and source addresses.
Use an alias-aware internal instantiation relation for both equal addresses and linked storage components.
Carry the caller's concrete aliases and link relation through canonicalization and summary substitution.
Prove each accepted demand's separation from protected paths under that relation.
Account for every address changed by a complete linked write, not only its receiver.
Derive the public separating-naming premises for instances that satisfy them.
Use the internal call contract directly for other legal read-only aliases.
Do not add a public restriction that forbids read-only view/source calls or read-only observed inputs.

## First fragment

Define `Fragment : Expr -> Prop` structurally.
Include `atom`, `letE`, `prim`, `branch`, `resultCase`, and `chainCase`.
For `prim`, require an explicit primitive predicate that excludes `Prim.owned`.
Require every subexpression to satisfy `Fragment`.
Exclude `closure`, `app`, `recur`, `entry`, `traverse`, and `focus`.
Use function-free input types for the first theorem.
Defer `Prim.owned`, whose type requires a function operand, to the full theorem.

Keep constructions and views in the fragment's planned cases.
Resolve their contract obstacles before claiming the complete fragment.
Split the ordinary primitive proof from these cases if that keeps the PR reviewable.
State any smaller fragment explicitly in its theorem and coverage report.
Do not present a smaller fragment as the public step lemma.

Prove `invariant_preserved_fragment` as a separate theorem.
Do not remove `invariant_preserved` from `Axioms.lean` at this stage.

As built (2026-10-16): `Ownership/FlatFragment/` proves `accepted_flat_anf_traces_agree` for `FlatANF0`.
That fragment contains integer and variable atoms, `let`, integer list literals, `push`, `length`, and `shared`.
It is smaller than the planned fragment: it excludes `branch`, `resultCase`, `chainCase`, field atoms, and every other primitive.
The theorem states its scope explicitly. It is not the public step lemma, and `invariant_preserved` stays in `Axioms.lean`.
The internal relation `FlatInvariant` extends `Invariant` as the internal statement above requires: typed allocated bindings, empty links, a bounded naming, and a complete finite observer witness.
Each case derives its frame from the actual checker run. The push case uses the real default demand; no alias prohibition or permission oracle enters.
The modules form one import chain, because the audit rejects an equation lemma that two modules realize (#182).
`FlatInvariant` has four flat-only clauses, and each next step replaces one of them:
`heapInts` (every array holds integers) goes with records and nested literals, which put references into arrays;
`types` (`FlatType`: `int` or `list int`) goes with field atoms and records, which bind record types;
`abstractShapes` (`FlatAbstract`: a scalar or a flat list with empty element cells) goes with the same step, because a record abstract has fields and a nested list has element cells;
`links = []` goes with views, and it is where the #169 link invariant enters: the clause becomes the link clauses of `Invariant`.
The case lemmas use these clauses (a flat reference has the footprint `[root]`), so the next fragment needs a more general relation and restates part of the case work.
Order: the #169 link clauses on `Invariant` first (its prerequisite #253 is done), then field atoms, the scalar primitives, records, then `branch` and the case expressions, then views under the link clauses.
`invariant_preserved_fragment` in its planned form, the premises of `invariant_preserved` restricted to the fragment, stays open: `flat_preserved` proves the step under the stronger relation, and the trace corollary is proved from it.
`Trace.lean` records the reviewer's probe programs as `#guard`s: `every` (all six forms, accepted, equal traces, one in-place write), `liveAlias` and `observed` (in the fragment, rejected, different traces).

## Complete case inventory

The baseline contains 12 expression constructors and 25 primitive constructors.
It also contains three atom constructors and three traversal sources.

| Expression | Proof obligations |
|---|---|
| `atom` | Integer, variable, and nested field projection; correspondence and path descriptions. |
| `letE` | Strengthen RHS liveness; bind its result; preserve outer names and types; remove the local after its continuation. |
| `prim` | Prove each transfer and concrete operation in the table below. |
| `branch` | Select the same integer arm; restore incoming sibling facts; weaken to the joined result and facts. |
| `resultCase` | Match the tag and active payload; exclude impossible bottom arms; preserve the arm-local binder and joined escapes. |
| `chainCase` | Empty and nonempty cases; copied tail allocation; payload provenance and certificate preservation. |
| `closure` | Match declaration and captures; establish honest once roots; transfer written captures; reject consuming recursive closures. |
| `app` | Resolve known alternatives or symbolic guards; check supplies and call counts; instantiate the stronger call contract. |
| `recur` | Use the depth hypothesis with the final recursive summary; preserve entry capabilities; respect explicit recursion limits. |
| `entry` | Initializer liveness; retained observers; single-use private authority; initialization and runtime-body contexts. |
| `traverse` | List, range, and model sources; empty and repeated steps; source reads; position loans; accumulator and escape fixpoints. |
| `focus` | Negative, out-of-range, and selected indices; selected loan; body effects; reread and replace the container; retained positions. |

| Primitive constructors | Proof obligations |
|---|---|
| `add`, `sub`, `eq`, `lt` | Scalar operands, equal results, and no heap change. |
| `record`, `events` | Field descriptions, projection, closure data, and protected fields. |
| `ok`, `err` | Tag and active payload; inactive bottom; error and success types. |
| `endChain`, `link` | Fresh spine, copied tail, recursive payload descriptions, and both certificates. |
| `literal`, `builder` | Fresh allocation, joined elements, store conditions, and both certificates. |
| `length`, `at` | Equal reads; negative and out-of-range defaults; element-result join; snapshot depth failures. |
| `set`, `push`, `put` | Four demand conditions; protected heap frame; stored elements; deep and spine certificates; unchanged `set` cases. |
| `copy` | Fresh shallow spine with retained payload aliases; no unproved exclusivity. |
| `prepend` | Equal base read, fresh result, retained backing provenance, and separation in both directions. |
| `construct` | First-spread base; preceding items; later item and spread loops; every operand in Disjoint; certificates and equal fuel. |
| `view` | Empty allocation; prefix and suffix links; shared storage names; linked-write frame and certificates. |
| `close` | Builder-only result; equal and unequal source shortcuts; dead source validity; both possible result provenances. |
| `shared`, `privateRoot` | Observer registration or private publication; escape facts; no authority in callee or scope frames. |
| `owned` | Full result demand and certificates against the retained callback; no new runtime permission. |

Audit summary helpers as proof cases too:

- Prove join weakening for paths, descriptions, certificates, escapes, and closure alternatives.
- Prove canonicalization, `canonicalOwned`, substitution, normalization, and fresh-slot instantiation.
- Prove `isolated` restores outer facts without importing shape-only cache entries.
- Prove guard reuse, forwarded queries, supplies, consumes, and call-count bounds.
- Prove `inferScope`, `applyScope`, `transfer`, and `applyCall` preserve the outside frame.
- Prove recursive validation supplies a post-fixpoint contract without an unproved monotonicity assumption.
- Prove traversal shape discovery and the certificate meet establish both base and preservation obligations.

## Reviewable delivery

1. Publish this plan and reproducible statement findings.
2. Resolve the findings through their issues and owner decisions.
3. Prove the explicit call-free fragment with its helper lemmas.
4. Prove generalized preservation and the stronger call contract by the shared induction.
5. Derive `summary_sound` and then `map_summary_sound` with its result certificate.
6. Remove each proved obligation from `Axioms.lean` and change the associated proof-status documentation.

For the last step, change `COVERAGE.md`, the `Soundness.lean` header, and `ownership-checker.md` §13 and §26.7.
Keep every design section number unchanged.
Keep the shipping Zig checker outside the Lean certification claim.
Continue the bridge checks for that separate implementation boundary.

Before each push, run the required Lean build, ownership CI, audit steps, and Zig gates under the shared lock.
Check memory before each heavy command.
Start only when at least 6 GB remains available. Keep `MemoryMax=10G` and `MemorySwapMax=2G`.
Start the full independent audit only when at least 12 GB remains available.
Keep the merged PR #245 audit repair and every audit check intact.
Record omitted checks and capped failures in the PR.
Complete the expanded source's independent audit before publication. Record its result and commit in the PR.

Keep the witness imports in one dependency chain after the existing proof modules.
Later reductions then reuse imported equation lemmas and their private splitters.
[Issue #182](https://github.com/canassa/beni/issues/182) tracks the audit's general limitation for duplicate equation lemmas from independent modules.
PR #245 rejects duplicate declarations that involve audited modules before child replay.
It does not establish support for valid duplicate equation lemmas.
Keep every audit check intact.

Fetch `origin/master` before each later branch.
If a model rule changes, add its cases and source baseline here before its proof.
