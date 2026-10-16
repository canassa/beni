# Ownership soundness proof plan

This plan covers [issue #165](https://github.com/canassa/beni/issues/165).
The source baseline is `927b7dcd4` on `origin/master`, dated 2026-10-15.
The branch then advanced to `f1ab9cc87`; those four commits changed no Lean model rule.
The branch later advanced to `23e571c18`; the later commits also changed no Lean model rule.
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

Track the required owner decision in [issue #169](https://github.com/canassa/beni/issues/169).
The premise and postcondition proofs are in [ViewLinks.lean](Ownership/StatementChecks/ViewLinks.lean).

`Invariant` constrains the heap and naming, but it does not constrain `State.links`.
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
- Names for linked storage reflect every array that a linked write changes.
- Concrete certificate reasoning accounts for the model's distinct view addresses.

One candidate naming clause closes every origin under the linked storage component:

```text
c ∈ γ o ∧ Linked hs.links c d -> d ∈ γ o
```

Together with `Separating`, this clause excludes distinct non-aliasing names for linked addresses.

Cesar narrowed the enumerator condition on 2026-10-16 at 09:01 UTC (dashboard q4).
Check that no accepted program writes one side of a view/source split while the other side remains live.
A read-only split, such as `readBoth(rest, xs)`, is legal and is not a checker defect.
Inspect main-context states and call frames for this condition.
Also check arbitrary states admitted by the theorem.
A consistency check on link contents alone does not establish alias separation.
Cesar authorized stronger link premises in q1. Complete the enumerator check first and derive the premises at accepted callers.

### Summary observer permissions

Track the required owner decision in [issue #170](https://github.com/canassa/beni/issues/170).
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
- Observers, recorded escapes, private transfer authority, and view links satisfy their concrete contracts.

Construct fresh names for new arrays without invalidating surviving descriptions.
Use a relation between entry and exit namings rather than an unrestricted replacement.
Instantiate and discharge this relation at every call and scope boundary.

The current `CallSound` clauses do not provide this entire call contract.
Prove result descriptions, certificates, closure honesty, and outside-holder framing in the internal theorem.
Then project `CallSound` clauses 1–3 from it.
Do not assume clause 4 or add it as an axiom.
Add proof-only execution witnesses if callback-prefix permissions need explicit records.

Canonical inputs also require care for read-only aliasing.
Distinct parameter origins cannot share an address under `Separating`.
Use an alias-aware internal instantiation relation for such calls.
Show that every written path remains separate from protected paths.
Do not exclude legal read-only calls merely to fit the public summary statement.

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
Run `audit env` only when at least 12 GB remains available.
Record omitted checks and issue #160 in the PR.

Keep the witness imports in one dependency chain after the existing proof modules.
Later reductions then reuse imported equation lemmas and their private splitters.
[Issue #182](https://github.com/canassa/beni/issues/182) tracks the audit's general limitation for duplicate equation lemmas from independent modules.
Keep every audit check intact.

Fetch `origin/master` before each later branch.
If a model rule changes, add its cases and source baseline here before its proof.
