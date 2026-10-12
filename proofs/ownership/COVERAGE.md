# T1–T59 coverage audit

The source is `docs/thesis/ownership/ch-soundness.tex`, Table 6.2, including
all named variants, and fifth-review/response. **This is core coverage, not complete thesis coverage.** The applicable pending
core examples from the previous audit are now implemented. Exclusions below
name the absent language/runtime boundary rather than replacing it with a claim.
“Projection tested” records a smaller ordinary-core ownership obligation and
never claims to test the omitted runtime/module/library boundary. No full
TEA/renderer example is an exact test of this core.

Tests are in `Ownership/Fixtures.lean`; each keeps the table's intended
accept/reject verdict. Accepted tests run both interpreters, comparing finalValue
and every ordinary read and external observer snapshot. Same-program reuse across projections is intentional and listed
here; it is not evidence for unimplemented wrappers/algorithms.

| ID | Status | Variants and exact boundary |
|---|---|---|
| T1 | projection tested | Argument alias, read-capture holder, fold with source=accumulator, and higher-order g callback capture all rejected. insertAt itself is projected to push (same consumed spine); no insertion primitive exists. |
| T2 | core tested | Read snapshot before push accepted; no optimizer exists in core, so A5 optimization claim untested. |
| T3 | core tested | Explicit shared root, ordinary publishing call and traversal publishing callback rejected. Frozen generated empty-list publishing regression also rejects; dropping traversal escape transfer produces an externalReads disagreement. |
| T4 | out of scope | Event payload/model handover P6 absent. |
| T5 | projection tested | Repeated consuming closure rejected; Result.andThen call-count positions absent. |
| T6 | out of scope | Task.join/runtime unknown retained results absent. |
| T7 | core tested | Returned mk closure reads captured list after push; rejected. Direct live read-only capture also rejected. |
| T8 | core tested | A returned factory once closure called twice; B once function captured by wrapper then mapped many times; C consuming closure stored at record field and called twice: all rejected. Earlier direct-call projections retained. |
| T9 | out of scope | Implicit eq dispatch and prohibition on writing eq declarations absent. |
| T10 | core tested | Duplicated record fields inside list rejected on scoped element write. |
| T11 | core tested | Ordinary concatRows traverses/pushes right-hand elements into left spine; focused write to transferred element while right source retained rejected. Earlier shallow-copy projection retained. |
| T12 | projection tested + recursion | Recursive appendTo scalar-counter/list-accumulator loop returns and consumes its list argument; original list retained, rejected. Original rest-pattern recursion is represented by scalar recursion, because list patterns are absent. |
| T13 | out of scope | View borrowed-entry protocol and concat alternative absent. |
| T14 | core tested; TEA excluded | Fresh init builds a record/list per ordinary call; two independent calls, one edited while the other retained, accepted. Reset and TEA entry contract absent. |
| T15 | core tested | Ordinary Library.foldl callback returns source element; later push with source live rejected. |
| T16 | out of scope | Module/interface cache invalidation absent. |
| T17 | core tested | compareLengths xs (push xs), retained tuple/record holder, and model.todos old/new record all rejected. Scalar compare is explicit because list comparison dispatch absent. |
| T18 | out of scope | List views, cached $plain and header representation absent. |
| T19 | out of scope | Opaque slot boundary absent. |
| T20 | out of scope | Command escape and TEA entry fixpoint absent. Traversal escape supplement is not this protocol. |
| T21 | projection tested | Explicit shared root rejects write; TEA init/reset model absent. |
| T22 | out of scope | Task.join wrapper and runtime retained values absent. |
| T23 | core tested | Closure returns captured list; later closure use blocks write through returned alias. |
| T24 | core tested | Ordinary map callback repeatedly returns capture; nested consuming focus rejected. |
| T25 | core tested | upTo scalar self-recursion returns captured acc then pushes recursive result; calling same closure again rejected (once recursive closure). |
| T26 | core tested | give returns captured consuming push1 closure; f call while give still live, then give/call again, rejected. |
| T27 | out of scope; many-call projection tested | Runtime handler entry contract absent. T8 B tests ordinary captured-once wrapper at map many-call position, not runtime handler retention. |
| T28 | out of scope | Markup opaque handler retention absent; ordinary closure projection covered T7. |
| T29 | out of scope | Command batch, send and reentrant update absent. |
| T30 | projection tested; TEA excluded | Independent init calls produce distinct record/list models; one written while second retained, accepted (same program as T14). Mounting, sandbox and update entry analysis absent. |
| T31 | projection tested | Consuming closure called twice rejected; source forward local binding not expressible in evaluation-order ANF. |
| T32 | projection tested | Dictionary key/value same cell modeled by two record fields in list; actual Dict algorithm absent. |
| T33 | projection tested | Retained old list rejects write, shallow copy of Int list accepted. Stack front/pattern/version loop absent. |
| T34 | out of scope | Borrowed send protocol P6 absent. |
| T35 | out of scope | Renderer reads/write invalidation P7 absent. |
| T36 | out of scope | Row rendering groups and event invalidation absent. |
| T37 | core tested; renderer excluded | Ordinary initialize creates three independent rows of three cells, ordinary update callback sets a row column, accepted. Earlier nested focus retained; rendering absent. |
| T38 | out of scope | Send, suspension and subsequent model write absent. |
| T39 | out of scope | DOM event bubbling and listener current-read protocol absent. |
| T40 | core tested | Distinct list-record fields; scoped callback constructs record with one pushed field, accepted. TEA entry iteration absent. |
| T41 | projection tested; TEA excluded | History list retains shallow-copied previous list; indexed restore alias then edit rejected, copying restored previous then editing accepted. Entry-state undo/history merging absent; these are ordinary restored-holder checks. |
| T42 | core tested | Ordinary map over id/tags records conditionally pushes tags or returns original card; independently built cells accepted, repeated tags cells rejected. |
| T43 | core tested with precision limit | Ordinary concat loop and foldl rows construction based on accumulator accepted. Consuming row-based fold with source retained rejected. Reverse-order foldr implemented by range/indexed reads and prepend concat, also rejected, but conservative many-call captured-consumption check fires before thesis Dead edge. |
| T44 | out of scope | Dictionary lookup/keyed update and Maybe data absent; no asserted Dict rule substituted. |
| T45 | out of scope | Command retained capture precision across TEA arms absent. |
| T46 | projection tested; summary row tested | Previously listed as "core tested" on one row, where the borrowed row is returned but never written, so owned and borrowed were indistinguishable. Now: shared and captured conditional accumulators rejected; borrowed element then later push rejected; the List.isEmpty projection runs over **two rows**, so the second step pushes onto the borrowed first row, retained afterwards (rejected; under `borrowed-supply` with the per-call checker it is accepted and the traces differ); a three-row variant `[r1, r2, r1]` that reads r1 again. The row the thesis repaired — foldl's accumulator supplied owned only if the callback returns owned — is the summary layer's supply bit, re-checked where the step ends; its mutants `supply-recheck` and `supply-edge` are required controls caught by generated programs (`fold-keep`, `apply-read`). Only ordinary foldl and two callbacks; no Dict/fiber/TEA variant. |
| T47 | projection tested; release/renderer excluded | Transparent one-field Column record under list focus edited by push and wrapped again, accepted. Erased constructor identity and renderer release protocol absent. |
| T48 | projections tested | Duplicate versus distinct transparent record slots in list rejected/accepted. Opaque module summaries and Conduit entry protocol absent. |
| T49 | out of scope | Recursive data representatives and across-level exclusivity absent. |
| T50 | out of scope | Borrowed send-message writes and parking absent. |
| T51 | out of scope | Dictionary algorithm and empty dictionary special representation absent; both variants untested. |
| T52 | projections tested | Retained spine alias rejected; shallow copied Int spine accepted. Exact filter identity and entry fixpoint absent. |
| T53 | core tested; TEA excluded | Explicit shared list rejects write; initializer-function alternative builds fresh record/list per call, accepted (T14 program). Top-level declaration/module and TEA entry protocol absent. |
| T54 | out of scope | Markup structure-hole invalidation absent. |
| T55 | projection tested; exact dispatch out of scope | Explicit declaration call with aliased operands rejected; where evidence/implicit static method dispatch absent. |
| T56 | projection tested; schema out of scope | Duplicate fields from record constructor rejected on focused write. Actual schema parse/mapping algorithm absent. |
| T57 | core tested | Distinct/repeated inner cells tested both by scoped focus and ordinary Library.update wrappers with bumpHead callback: accepted/rejected respectively. Separate repeated-outer-row case builds internally distinct row, rows=[row,row], then nested ordinary update: rejected. |
| T58 | projection tested; renderer excluded | Scalar at read computes index before set; accepted with equal traces. removeAt/indexOf and renderer protocol absent. |
| T59 | core tested; summary row tested; schema excluded | Initialize/map internally shared fresh results rejected, distinct variants accepted. Frozen v1 map/initialize and v3 deeper tower controls disagree under oldFreshRule and corrected rejects. Under summaries map's builder sees the callback's result through its `res`/`xres` guards; dropping `xres` (`callback-xres`) is a required control, caught by generated programs within 20 trials. Schema mapping absent. |

## Explicit general limits

The core has integer zero/nonzero branches, positional record constructor and
projection, scalar self-recursion, closures and four structured primitives.
There is no record-update surface syntax, opaque/recursive type, list view or
list-pattern syntax, effects/fibers, TEA entry analysis, renderer, release
identity rewriting, implicit method dispatch or dictionary/schema implementation.
The checker explicitly rejects higher-order recursive actuals and recursive
changes to tracked shape/exclusivity; these are implementation limits rather
than new thesis rules (Ch. 3 demand/summary contracts; Ch. 4 inference; Ch. 6
soundness/derived-contract obligations). No excluded runtime or language-boundary variant is reported as passed. The broadened campaigns reach higher-order-recursion `limit:` rejections,
reported separately; this does not prove recursive contracts universally derivable.

The fixed suite has 76 intended verdict tests (74 transcribed, plus the recursion-in-a-step finding and the three-row T46 variant), checked by both checkers. Each independently typechecks;
accepted tests compare the complete Trace, including externally retained roots.
The traversal escape defect is repaired. Frozen controls demonstrate both
freshness-only and missing-transfer implementations accept an actual mismatch,
while the corrected checker rejects. No verdict was changed to match a checker.

## Positive/library observations and remaining exclusions

Ordinary declarations for map, initialize, foldl and update run in the fixtures
and generated pipelines; no library-aware checker branch was added. The suite
now includes fresh independent initialization (T14/T30/T53), conditional map
editing (T42), construction folds (T43), exact empty-accumulator conditional
(T46), scalar recursion (T12/T25), returned/captured once wrappers (T8/T26),
and ordinary nested update calls (T57). These are executable observations,
not universal library theorems. T43 reverse fold is rejected by a conservative
many-call rule before the intended final Dead edge, an explicit precision limit.

T6/T22 need runtime Task.join and unknown-origin values; using shared would
exercise Unescaped instead of Known. T44/T51 require dictionary/Maybe algorithms
and the empty-dictionary representation. T49 needs recursive data representatives;
scalar recursion is not that boundary. T59's schema variant requires schema
parsing/mapping. The TEA/send/renderer/opaque/module/release exclusions in the
table remain excluded, and no full application is claimed to be reproduced.
There are no remaining applicable pending core fixtures from the previous audit.
The current generated higher-order recursion family intentionally exercises
`limit: higher-order recursive argument`; campaign logs count these separately.

## What the oracle tests now, and what it does not

**Tested by generated programs** (generator v4, numbers in RESULTS.md):
in-place writes in accepted programs of every family except `captures`,
`escape-traversal` and the limit family; closures with shared captures called once and many times;
list and range traversals that consume elements, accumulators or captures;
focus that keeps or breaks shape; shallow and nested copies; literals with
repeated elements; spine writes after `map`; two calls of one library function
with different callback classes (summary reuse); callbacks handed a list that
is read again (`applyThenRead`) and folds that read their rows after the loop
(`foldKeep`). Every one of the twelve mutants below and the two historical
controls is caught **by the generator alone** in one 20000-trial campaign on
each of seeds 20261011, 17 and 271828.

**Tested only by fixtures or not at all:**
* recursion inside a traversal or focus step — one hand-written fixture; the
  generator never produces it (both checkers now refuse it as a limit);
* higher-order recursion, function values below an input path, callbacks with
  function-typed parameters or results — explicit limits, never accepted;
* the `need` row, as a separate fact (DESIGN.md: subsumed by guarded `xres`);
* summary-row edge `xreq ⇒ exclusive supply`, and the `xreq` and `E` guards
  of callbacks: no callback in the tables requires its argument exclusive or
  publishes it, so their source mutants (`requiresedge`, `callbackrequires`,
  `callbackescapes`) are not caught;
* forwarding: no generated declaration passes its own function-typed input
  to another declaration, so forwarding a guard or a supply to the caller
  (`forwardguards`, `transfersupplies`) is untested; `callbackwrites` is
  caught on two seeds of three;
* the review's other seven missed source mutants (`xres`, `once`,
  `nestedsep`, `reqexcloutside`, `recvalidate`, `tsupplyexcl`,
  `escapeowned`) remain uncaught; none is claimed equivalent;
* everything outside the core listed in the table above.

## Summary layer: rows and their controls

| Row (§3.7) | Implementation | Required control | Caught by |
|---|---|---|---|
| use W through a callback | `consumes` from `W∈use_g(k,p)` guards | source `callbackwrites` | generator, 2 of 3 seeds |
| res, A | result built from `π_k.p∈res(q)`, `env∈res(q)`, fresh, shared, ⊤ guards | source `callbackaliases`, `callbackenv` | generator |
| xres | `xres(q)` guards | `--mutant=callback-xres` | generator + fixture |
| supply owned | demand test at the call, re-checked where the scope ends and at the caller | `--mutant=supply-recheck` | generator + fixture |
| edge W ⇒ owned | at a call that knows the callback | `--mutant=supply-edge` | generator + fixture |
| calls, edge once ⇒ ≤1 | counted per slot, many in a step or recursion | `--mutant=calls-edge` | generator + fixture |
| guards | cache reused only where every guard answers the same | `--mutant=guard-reuse` | generator + fixture |
| edge xreq ⇒ exclusive | at a call that knows the callback | none (source `requiresedge` reported) | not reached |
| need | not a separate row | — | — |

## Borrowed supply under summaries

The review's `borrowed-supply` mutant drops the borrowed source's elements
from the holders a non-consuming traversal re-checks its step's writes and
supplies against. In the per-call checker it is load-bearing, and the
generator catches it (first indices 131–2555). Under summaries no generated or
hand-written program distinguishes it, and we argue none can in this core: a
written cell that was an element of the borrowed source is observed only
through (a) a holder live after the traversal, which is in `later`; (b) the
source itself at a later position, which for a non-exclusive source is the
same origin as the current element parameter, so the re-demand's Disjoint
against the other step inputs fails, and for an exclusive source is a
different array; or (c) the caller, where the summary's writes and supplies
are re-checked against the caller's live holders. The per-call checker lacked
(c) because it dropped position-tagged writes at the caller. The control is
therefore run against the per-call checker (`ownership controls` labels it),
and its fixture is T46 two rows.

## Theorems (Soundness.lean, BuilderProof.lean, HeapProof.lean, KernelChecks.lean)

| Theorem | Status |
|---|---|
| `cellOverlap_sound`, `demandProblem_sound` — the overlap and demand tests exclude shared arrays under a separating naming | proved |
| `builder_alloc_describes` — abstract builder value describes the concrete allocation | proved |
| `invariant_initial`, `invariant_observations` — the configuration invariant at the start, and what it fixes | proved |
| `accepted_traces_agree` — main theorem: accepted ⇒ same final value, reads and external reads, for every fuel bound | proved **from** `invariant_preserved`; inherits its `sorry` |
| `invariant_preserved` — the step case of the prefix induction over the whole configuration | **sorry** |
| `summary_sound` — Lemma 6.7 clauses 1–3, clause 2 as repaired in round 5 | **sorry** |
| `map_summary_sound` — map's derived summary, including its certificate | **sorry** |
| Lemma 6.7 clause 4 (calls, supply) | **not stated**: the interpreters do not record callback invocations |
| builder/close contracts, footprint framing, close identity (`BuilderProof`, `HeapProof`) | proved (unchanged) |
| kernel checks of `storeExclusive` and permanent escapes | proved (unchanged) |

`Axioms.lean` prints the axioms of each: the proved ones use only `propext`,
`Classical.choice` and `Quot.sound`; the three above and the main theorem use
`sorryAx`. No axiom is declared.

## Thesis discrepancies found (the thesis is not edited)

1. **Supply bits must be re-checked where a step ends** (§3.7, §4.7). The
   thesis computes a supply's ownership bit at the call of the callback, with
   "returns owned" decided at the caller. Inside a traversal step the bit is
   computed against the step's holders only; the holders the loop retains
   across iterations (the borrowed source, captures) are outside it. The
   implementation re-checks every supply where its step ends and again at the
   caller; `supply-recheck` shows the re-check is load-bearing (fixture
   "fold reads its rows after the loop"). The thesis's text does not say where
   the bit is established for an accumulator that is a step input.
2. **`need` is not needed as a separate row** in this core: guarding the
   declaration's own `xres` on the callback's `res`/`xres` carries it.
3. **Guard count.** §4.6 proposes capping a summary at about eight atoms. With
   atoms at the granularity the rows need (one per argument path and result
   path), foldl's summary asks 14 distinct facts per argument state and the
   fixtures' summaries up to 28 guards. Either the atoms are coarser than the
   rows (and §4.6 must say how `returns owned` is decided from them) or the cap
   is too low.
4. **Lemma 6.7 clause 2 needs a notion of holder.** Stating it over heaps
   required choosing what a holder is: another array, or a program-lifetime
   observer; frame locals are not holders after return. "Closures reachable
   from the result" are values, not heap objects, in this model; a closure
   holding a cell is covered only when stored in an array of the result.
5. **Clause 4 needs instrumented calls.** It quantifies over the callback
   invocations a call makes; neither semantics records them, so the clause has
   no statement here.
6. **Recursion inside a loop body** (§4.5) is analysed through the group's
   summary in the thesis; the earlier executable checker used an empty summary
   there and accepted an unsound program. This is an implementation defect,
   not a thesis one; both checkers now refuse it as a limit.
