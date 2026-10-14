# T1–T59 coverage audit

Current follow-up measurements are in [RESULTS.md](RESULTS.md) and its linked logs.
Historical numerical sensitivity measurements below are marked as such;
they do not establish final-head coverage. The executable theorem statements
still have three `sorry`s, including the step lemma on which the main theorem
is conditional.

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

The original transcribed suite had 78 intended verdict tests (74 transcribed, plus the recursion-in-a-step finding, the three-row T46 variant, and the env-through-a-wrapper fixture with its rejected reverse), checked by both checkers. The final fixed suite has 98 verdict fixtures (RESULTS.md); each independently typechecks.
Accepted tests compare the complete Trace, including externally retained roots.
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

**Tested by generated programs** (generator v5, numbers in RESULTS.md):
in-place writes in accepted programs of every family except `captures`,
`escape-traversal` and the limit family; declarations the generator builds
itself — functions over lists, nested lists and records returning fresh,
aliasing or captured values, higher-order functions calling a callback that
may capture the very list it is passed, counter-driven self-recursion
(including reads, after the recursive call, of the lists passed to it),
factories returning closures that are called later, calls between generated
declarations; conditionals whose arms are chains of moves; closures with
shared captures called once and many times; list and range traversals that
consume elements, accumulators or captures; focus that keeps or breaks
shape; shallow and nested copies; literals with repeated elements; spine
writes after `map`; two calls of one library function with different
callback classes (summary reuse); the fixed table's wrappers and callbacks
(`applyThenRead`, `foldKeep`, `mapVia`, `twiceVia`, `applyN`, `publish`,
`headBump`, a once list callback), and initialize over shared and distinct
pairs. Since the third review: declarations that write one of their
parameters first, and declarations that only read two lists of one type;
the declaration family's programs end by calling their own declarations
(current counts are in RESULTS.md);
shadowing lets, refused by `typecheck`; `shared` on nested lists and
records; closures created in conditional arms; a list pushed twice onto a
nested list then pushed through each element; a once closure over a list
aliased by `close` and called by a callee; an element of a shallow copy
edited. Since the fourth review: a once closure handed to `foldl` or `map`
over two rows; a record holding a closure over a list, published with
`shared`, then the list pushed; a loop over a nested list repeating a row
that keeps a row as its accumulator and edits it; one wrapper (`mapVia`)
called twice over the same rows, the second time with a callback that
publishes its argument, then the row written; a shallow copy of a nested
list repeating a row, edited inside and the original read back. Round 6 also
revives an inner once closure's capture through `close`, then calls its outer
closure through a higher-order callee. Aliased-write counts are in RESULTS.md.

**Controls.** Every required control has a fixed probe that disagrees under
its mutant and is rejected without it, and the generator alone catches it
in one 20000-trial campaign on each of seeds 20261011, 17 and 271828;
`ownership ci` requires both. Required: the two historical controls and
twenty-six flags (disjoint, traversal-exclusive, many-calls, copy-exclusive,
close-source, keeps-shape, guard-reuse, callback-xres, supply-edge,
supply-recheck, calls-edge, callback-writes, callback-aliases, callback-env,
callback-escapes, forward-guards, once-through-call, branch-live,
branch-closure, shared-roots, shadowing, and the fourth review's many-off
and shared-fn, plus set-exclusive and once-live; borrowed-supply against the per-call checker). `no-scope` is
required through its checker-level probe only: no typed program has a live
variable its environment does not bind, so no generated program can reach
it, and the probe runs the checker on such a configuration directly.
All 65 unique source-level edits in `scripts/mutate.mjs` were tested against
independent baseline verdicts, on all three seeded streams and by bounded
enumeration. RESULTS.md gives the complete matrix, and the arguments and
search gaps below account for uncaught edits.

**Rows exercised.** `withWrites` counts executions, not which rows a write
depends on. The checker records row hits in each current campaign log
(`regressions/campaign-followup-*.log`). A row hit is evidence of execution,
not that a test distinguishes dropping it; the source edits and masking
arguments below are the sensitivity evidence.

**Tested only by fixtures or not at all:**
* recursion inside a traversal or focus step — one hand-written fixture; the
  generator never produces it (both checkers refuse it as a limit);
* mutual recursion — generated (a pair recursing through each other's
  closures), always rejected, as a limit when the checker reaches the cycle;
* higher-order recursion, function values below an input path, callbacks with
  function-typed parameters or results — explicit limits, never accepted;
* the `need` row, as a separate fact (DESIGN.md: argued, not checked, to be
  carried by guarded `xres`);
* everything outside the core listed in the table above.

## Equivalent (argued)

The source-level edits not caught by the current generator or enumerator
(3 × 20000, bound 2 and all 144 targeted programs, RESULTS.md), for which we have a masking argument: each argument is ours, not a proof, and each is
backed by the edit's changed verdicts on the same programs
(`regressions/source-mutants-followup.log`: both newly accepted and newly
rejected programs, with newly accepted executions checked for disagreement).

| Edit | What it weakens | Changed verdicts (+/−; seeds 20261011 / 17 / 271828) | Why no program can tell |
|---|---|---|---|
| `once` | a direct call does not demand a once closure's own roots | 0/0; 0/0; 0/0 (no mismatch) | Every effect of calling a once closure is demanded anyway: its writes to its captures by `applyCall` at the call (a later holder of the closure names those captures through its capture paths), and a once value it captures and calls by the once-through-call demand at the same call (roots and written captures). So the closure stays usable only when calling it changed nothing anyone can observe. |
| `nestedsep` | an exclusive-contents certificate does not require the element's paths separated | 0/0; 0/0; 0/0 (no mismatch) | A list is exclusive only if every value stored in it passed `storeExclusive`, which requires its paths separated, or if it was granted by a focus or traversal from such a list. The one way abstract paths come to overlap with the flag still set is a join of two alternatives (a conditional), each separated on its own; concretely only one alternative is there, so the overlap is not an alias. |
| `reqexcloutside` | an exclusive-contents certificate ignores outside live holders of the elements | 0/0; 0/0; 0/0 (no mismatch) | A consuming focus or traversal also demands the element writes it makes, against the same live holders (`applyScope`, and a traversal's step writes re-demanded against `later`); a holder that the certificate check skips fails that Dead test, because a position-tagged element origin aliases the plain origin a holder names. |
| `recvalidate` | a recursive summary is not validated against its final assignment | 0/0; 0/0; 0/0 (no mismatch) | The fixpoint loop stops when a round's result, joined into the candidate, leaves it unchanged; that round's inference already ran with the final candidate. Validation reruns the same inference (same context, same candidate; the cache only adds summaries the round computed), so it cannot reach a different verdict. |
| `escapeowned` | a cell recorded as escaped counts as individually owned | 0/0; 0/0; 0/0 (no mismatch) | Individual ownership feeds exclusivity certificates, supply owned bits and recursion's entry-ownership test; every write is still a demand whose Unescaped test refuses an escaped cell. The earlier two changed verdicts were recursion whose base case publishes a parameter and never writes the published array. The final stream changes no verdict under this edit. |
| `requiresedge`, `callbackrequires` (flags `requires-edge`, `callback-requires`) | xreq ⇒ exclusive supply unchecked; a callback's xreq not published | 0/0; 0/0; 0/0 (no mismatch) | A callback that requires exclusivity of an argument is checked twice: its own published xreq makes the caller require the actual exclusive, and the edge checks the supply. Each covers what the other drops: a program passing a non-exclusive argument fails whichever remains. |
| `transfersupplies` (flag `transfer-supplies`) | a callee's supplies to our own input are dropped | 0/0; 0/0; 0/0 (no mismatch) | A supply to our input matters only through its owned bit at the edge, and every write it licenses is already a forwarded W guard on our input, demanded at our own caller; dropping the supply loses an edge check that the forwarded W demand makes again. |
| `keepsany` | focus keeps exclusivity when the result's paths name *any* parameter path | 0/0; 0/0; 0/0 (no mismatch) | A focus scope has one parameter (the element), so the weakened test only admits a result whose paths hold the element's own arrays rearranged (fields swapped); `keepsShape` still requires the result deep-exclusive and path-separated, and the arrays all came from the replaced element, so none is shared with another position. |
| `recwrites` | a recursive call's W rows are not demanded at the call | 0/0; 0/0; 0/0 (no mismatch) | **Masked.** A recursive call re-checks that every input path owned at entry is still owned at the call (individually owned, not live later, not another operand's) — the same Unescaped/Dead/Disjoint test the W demand makes; a W on a path not owned at entry is demanded at the outermost caller. With the mask removed too (`recwritesown`) the generator catches it on all three seeds (RESULTS.md). |
| `symenv` | a callback's own environment is not an "other operand" of its arguments | 0/0; 0/0; 0/0 (no mismatch) | **Masked.** Every supply is re-checked where its call is known (`recheckSupplies` at `callKnown`, against `otherPaths`, which include the callback's capture paths), so an argument the callback's environment also holds loses its owned bit there and the W ⇒ owned edge rejects; `supply-recheck` (required, 3/3) controls that re-check. |
| `borrowedsupply` (flag `borrowed-supply`) | borrowed source elements dropped from a step's re-check | 15/0; 18/0; 22/0 (no mismatch) | See "Borrowed supply under summaries": the line is live but not observable; its flag is a required control against the per-call checker. |

## Gaps

Holes the generator does not reach that are not equivalent:

| Edit | What it weakens | Why the generator cannot reach it | What catches it |
|---|---|---|---|
| `noscope` (flag `no-scope`) | an unbound live variable is read as dead instead of refused | A program that typechecks binds every variable it uses, and liveness only names used variables, so no generated program has a live variable missing from the abstract environment. The step lemma's `covered` hypothesis is exactly this. | `ci`: the fixtures run the checker on the third review's configuration (a live variable the abstract environment does not bind) and require the refusal; under the edit the checker accepts and the push changes the array the live variable holds. |
| `hiddencopy` | (interpreter) `writeCounted` allocates rather than mutating | Differential acceptance does not measure the promised in-place behaviour, and the source runner only executes changed verdicts; this interpreter-only edit changes no verdict. Builder put has its own implementation, so this is not a universal equivalence claim. | Fixed aliasing probes check the expected in-place observations directly. |
| `keepsep` | focus result exclusivity ignores separated paths | Neither search grammar currently focuses over a list of records with two list fields and returns the same fresh list in both fields. | The written `keepsep-probe.txt` produces a duplicate concrete footprint labelled exclusive under the edit; add this type shape and certificate checking to campaigns to reach it automatically. |

## Summary layer: rows and their controls

| Row (§3.7) | Implementation | Required control | Caught by |
|---|---|---|---|
| use W through a callback | `consumes` from `W∈use_g(k,p)` guards | `--mutant=callback-writes` | probe; generator 3/3 |
| use E through a callback | escapes from `E∈use_g(k,p)` | `--mutant=callback-escapes` | probe; generator 3/3 |
| res, A | result built from `π_k.p∈res(q)`, `env∈res(q)`, fresh, shared, ⊤ guards | `--mutant=callback-aliases`, `--mutant=callback-env` | probe; generator 3/3 |
| forwarding | a callee's guards on our input re-asked as ours | `--mutant=forward-guards` | probe; generator 3/3 |
| xres | `xres(q)` guards | `--mutant=callback-xres` | probe; generator 3/3 |
| supply owned | demand test at the call, re-checked where the scope ends and at the caller | `--mutant=supply-recheck` | probe; generator 3/3 |
| edge W ⇒ owned | at a call that knows the callback | `--mutant=supply-edge` | probe; generator 3/3 |
| calls, edge once ⇒ ≤1 | counted per slot, many in a step or recursion | `--mutant=calls-edge`, `--mutant=many-off` (a step's single call counted as one) | probes; generator 3/3 |
| once consumed at a callee's call | a once function actual the callee calls is demanded, with its written captures | `--mutant=once-through-call` | probes; generator 3/3 |
| guards | cache reused only where every guard answers the same | `--mutant=guard-reuse` | probe; generator 3/3 |
| xreq, edge xreq ⇒ exclusive | published xreq, and checked at a call that knows the callback | `callback-requires`, `requires-edge` | argued equivalent (current verdict deltas: 0 on all three seeds and both searches) |
| supply transfer | a callee's supplies to our input become ours | `transfer-supplies` | argued equivalent (current verdict deltas: 0 on all three seeds and both searches) |
| need | not a separate row | — | — |

Liveness has its own required control, `--mutant=branch-live` (a
conditional's nonzero arm contributes no uses; the second review's
`branchlive`): probe, generator 3/3. So do the third review's
`--mutant=branch-closure` (an arm's uses that are captures of the closures
it creates are dropped), `--mutant=shadowing` (shadowing allowed and a
`let`'s continuation uses resolved inside it) and, for escapes,
`--mutant=shared-roots` (`shared` escapes only its operand's spine): each a
probe, generator 3/3. The fourth review added `--mutant=shared-fn` (`shared` forgets a list captured by a closure held in a record field: probe, generator 3/3) and `--mutant=no-scope` (an unbound live variable read as dead: a checker-level probe only, see "Gaps").

## Borrowed supply under summaries

The review's `borrowed-supply` mutant drops the borrowed source's elements
from the holders a non-consuming traversal re-checks its step's writes and
supplies against. In the per-call checker it is load-bearing, and the
generator catches it on all three final seeded streams (control logs and CI).
Under summaries the line is **live**: the independent source sweep shows
15, 18 and 22 newly accepted programs per 20000 trials (seeds 20261011, 17,
271828), with no newly rejected programs and no trace disagreement. Bound 2
also has 98 newly accepted programs, all agreeing; the targeted space has no changed verdicts. A typical one folds
`borrowOrGrow` over three fresh rows: the borrowed row is written once and
never read again. The line is kept. That no program can distinguish it is
**argued, not checked**: a
written cell that was an element of the borrowed source is observed only
through (a) a holder live after the traversal, which is in `later`; (b) the
source itself at a later position, which for a non-exclusive source is the
same origin as the current element parameter, so the re-demand's Disjoint
against the other step inputs fails, and for an exclusive source is a
different array; or (c) the caller, where the summary's writes and supplies
are re-checked against the caller's live holders. The per-call checker lacked
(c) because it dropped position-tagged writes at the caller. `ownership
controls` prints both rows: NOT OBSERVABLE under summaries (with the
verdict-change counts) and the required catch against the per-call checker;
its fixed probe is T46 two rows, run against the per-call checker.

## Theorems (Soundness.lean, BuilderProof.lean, HeapProof.lean, KernelChecks.lean)

| Theorem | Status |
|---|---|
| `cellOverlap_sound`, `demandProblem_sound` — the overlap and demand tests exclude shared arrays | proved, **conditional on a separating naming** (`Separating γ`), which nothing yet constructs; the first conjunct of `demandProblem_sound` only restates checker booleans |
| `builder_alloc_describes` — abstract builder value describes the concrete allocation | proved, **conditional on the naming naming the new array** (`hsite`); re-proved for the path-wise `Describes` |
| `invariant_initial`, `invariant_observations`, `check_accepts_main`, `check_typed`, `typecheck_main`, `corrected_default` | proved; bookkeeping (`invariant_initial` is instantiated with the empty naming) |
| `old_invariant_counterexample` — the review's counterexample to the earlier invariant is excluded by the restated one | proved; `#guard`s beside it run both interpreters and show that the earlier statement's conclusion failed on it |
| `accepted_traces_agree` — main theorem: for `check p = .ok _` (corrected config), same final value, reads and external reads, for every fuel bound | proved **conditionally** on `invariant_preserved`: unfolding, plus the value run's depth check |
| `invariant_preserved` — the step case of the prefix induction over the whole configuration | **sorry**; restated (below) |
| `summary_sound` — Lemma 6.7 clauses 1–3, clause 2 as repaired in round 5 | **sorry**; restated (below) |
| `map_summary_sound` — map's derived summary, including its certificate | **sorry**; restated with `summary_sound` |
| Lemma 6.7 clause 4 (calls, supply) | **not stated**: the interpreters do not record callback invocations |
| builder/close contracts, footprint framing, close identity (`BuilderProof`, `HeapProof`) | proved (unchanged) |
| kernel checks of `storeExclusive` and permanent escapes | proved (unchanged) |

### The invariant, restated

The second review showed `invariant_preserved` false as stated: `Invariant`
related reads, external reads, fuel and live bindings, and nothing about the
permanent observers, so a pre-state whose in-place side had registered an
observer (`hs.kept = #[.ref 0]`) that the value side had not (`vs.kept =
#[]`) met every hypothesis and broke the conclusion at the next
`observeKept`. Working through the statements again, by hand and with the
falsifier below, found eleven more ways they were false or vacuous, listed
below; all are fixed in the statements, and two turned out to be defects of
the checker, not of the statement (below, "Defects the
restatement found").

`Invariant vs hs env live aenv escapes γ` now says, in words:

1. the reads, the external reads and the fuel left are equal;
2. **the observers are the same on both sides** — as many, each pair
   corresponding — and **every array an observer reaches is named only by
   origins the checker treats as escaped** (`shared`, ⊤, or overlapping the
   escapes the checker has recorded, `st.facts.escapes`), so no demand the
   checker passes can write one; the step lemma's hypothesis uses the escapes
   recorded before the expression and its conclusion those after it;
3. every **live use** — a variable and a field path, as `uses` produces them,
   not just a variable — corresponds, and is described by its abstract value
   at that path (a write to `r.1` while only `r.0` is live legitimately makes
   `r`'s value copy differ);
4. **description is path by path**: the arrays at each path of a value are
   named by the abstract value's cells at that path (`Covers`), and an
   exclusive list certifies the value at its path (`CertifiedExclusive`). A
   whole-footprint naming was too weak: an array named only by an element
   origin could be written through a root demand. **A closure is described
   by its own declaration** (`ClosuresDescribed`, fourth review, P7): every
   closure at a field or element path is one of the abstract alternatives
   there with the same declaration and described captures. Without it a
   closure of `capPush` (writes its capture) described as one of `capGet`
   (does not) satisfied every hypothesis, the checker accepted a call of it
   with the captured list live, and the step lemma's conclusion failed. A
   symbolic input describes any closure; its class is `GuardsHold`'s
   business. Round 6 found the same mislabeling through an inner capture:
   matching the outer declaration and the inner footprint was insufficient.
   `ClosureAgreement` now follows records, array contents and captures
   recursively, matching every known declaration and certifying its captures.
   The falsifier deliberately mislabels inner closures, and a guarded fixed
   configuration rejects the previously admitted case (both runs return,
   with different observations). Since the fifth review their arrays are named: `namesAt` walks the abstract value itself, so a capture step
   of a known function value goes into its alternatives' captures (before, it
   used `atPath`, which merges a capture step into a plain list, and a
   closure captured by a closure — accepted by the checker — could never be
   Covered: the review's `nested_not_covered`); a capture or `env` step of a
   symbolic input names its `env` row; and anything below the unknown value
   of mismatched shapes (`Abstract.join`'s fallback, which since the fifth
   round keeps every cell of both sides — a checker defect, below) names all
   its cells, and that value describes any closure (it cannot be called);
5. **every binding, live or dead, keeps its arrays at immutable paths (root,
   fields, captures) named by its abstract value**: `close b xs` reads `xs`
   without using it (`uses` omits a close's source), so `xs`'s naming must
   survive while `xs` is dead;
6. the naming is separating.

Besides `Invariant`, the step lemma now assumes, and concludes for its result:

* `Corresponds` is unbounded (`∀ n ≥ o.depth, snapshot heap n w = .ok o`).
  With the earlier fixed depth 256, `literal [x]` over an `x` of depth 256
  made the result uncorrespondable although both runs succeed. The value
  interpreter now fails explicitly on observing a value deeper than
  `observationDepth` (256), exactly where the in-place `snapshot` runs out of
  fuel, so a deep value is a failure of both runs (`Observation.depth` is
  checked against `snapshot` by a `#guard`);
* `WellTyped`: the expression is ordinarily typed, and every binding has
  that type both as a value-side observation and as an actual heap value.
  The latter uses an unbounded `Represents` witness (`ValueTyped`), not a
  fixed snapshot fuel. A dead close source could otherwise be a list on the
  value side and an int on the heap side: it met the old premises but one
  run returned and the other failed. A fixed guard now excludes it. Without it a branch whose arms have different
  shapes joins to an unknown list with no element cells, which describes
  nothing (the falsifier found this through a mistyped generator);
* `HonestClosures`: a function value described as not once (no roots) is one
  the checker itself would create as not once (re-creating it from its
  abstract captures gives no roots). `ContainsFunction` descends into
  records, lists and closure captures: an accurately labelled inner writing
  closure with falsely empty roots otherwise passed the old outer-only
  premise. A fixed guard now excludes that case. A writing closure described as not once
  is one no program builds, and with it the statement is false (falsifier);
* `covered` (third review, P1): every variable of the expression's and the
  continuation's uses that the environment binds has an abstract value.
  Without it, a live variable missing from `aenv` contributed no holders,
  since `liveCells` skipped it, and a write it still reached passed Dead. Both
  checkers now also refuse a live use of a variable the abstract environment
  does not bind (`liveScope`), and `liveCells` reads one as ⊤;
* no shadowing: `check` runs `typecheck`, which now refuses a binder that
  rebinds a variable in scope (third review, P2: both checkers had accepted
  `let 0 = [1]; let 6 = (let 5 = 0; let 0 = []; push 5 1); length 0`, value
  1, in place 2), and a `let` pins its continuation's uses of the variable it
  rebinds to the outer binding's cells, so liveness stays right if the rule
  is ever relaxed (`--mutant=shadowing` turns off both). The step lemma
  speaks about expressions of accepted programs' main context, so it needs no
  extra hypothesis for this; its `uses`-based live sets name each variable
  once.

`summary_sound` (and `map_summary_sound`) were restated too:

* **call shape**: the argument and capture counts must match the declaration,
  and their total must match `e.inputs`. Without these three premises, the
  same input bound as an argument in the summary but supplied as a capture
  to `callResult` made clause 1 false. The fixed guard executes that old
  counterexample; the falsifier now varies the split independently of the
  naming and checks its arity premises.
* **clause 3 named only parameters**, so a declaration returning a captured
  list (`capGet`) or its argument published as shared (`publish`) broke it:
  it now covers captures (`inputOrigin`) and admits `shared`/⊤ in `res(q)`;
* **clause 2 listed every array holding an argument cell** as a holder,
  including garbage and arrays the call writes; it was false for `map` with
  the identity callback (the new result array holds the rows). It now says
  what the repair means: the holders that outlive the call are the result
  (clause 3 names every array of it) and the permanent observers, which reach
  an input array only if they did before or the path escapes;
* **guards**: a summary speaks about the callbacks whose class its guards
  recorded; a call with other callbacks is outside it. The hypothesis
  `classes` asks for abstract closures resolving every guard as recorded and
  describing the actual closures;
* **paths**: clauses 1–3 range over the canonical input paths (a function
  input has `[]` and `[env]`), and `[env]` reaches every array the
  environment reaches (`AtPath.env`), as `π_i.env` stands for;
* description is path by path, as for the invariant; `pathCells`' fixed fuel
  of 64 is replaced by the relational `AtPath`, so no claim stops at a depth;
* **fifth review**: a symbolic input had only `[]` and `[env]` paths, so no
  closure capturing an array was ever described by one and the statement
  was vacuous for every such callback (the review's `symbolic_not_covers`);
  its capture paths now name its `env` row. A closure factory's result
  (a closure over a closure over the argument) is named through both levels
  (the review's P3). Clause 1 now admits a write to the environment of a
  function input the call calls (`calls` row ≥ 1): a once callback writes its
  own captures, which the summary does not record and the caller demands
  dead where it hands the callback over (`once-through-call`); the falsifier
  found this the moment such calls stopped being vacuous. And the `unique`
  hypothesis is gone: no clause needs it, and it counted garbage arrays as
  holders, which made most calls vacuous.

### Why each remaining sorry is believed true

* **`invariant_preserved`.** It is the checker's soundness for one
  main-context expression, from any related configuration. The demand test
  is sound under a separating naming (`demandProblem_sound`, proved): a
  written array is named by known, unescaped cells that no live use and no
  other operand names, so by (3)–(4) no live use and no other operand reaches
  it and by (2) no observer does; what the expression reads is live, hence
  corresponds; fresh arrays get fresh names, and the result's naming follows
  the abstract result the checker computed. Calls are `summary_sound`
  instantiated at the call; traversals and focus steps are the same argument
  over the step's summary with the position tags separating past and current
  elements. What is not argued: that every primitive's abstract transfer
  function names the arrays it returns (the falsifier checks it on every
  primitive and form it generates), and the inductive bookkeeping of nested
  scopes.
* **`summary_sound`.** The summary is the fixpoint of the body's inference
  over canonical inputs, validated once more with the final assignment. A
  write in the body is a demand on canonical cells, recorded as `W` on the
  input path (clause 1); a `shared` records its operand's cells in the escapes
  and normalisation keeps the input ones as `E` (clause 2); the result's
  cells are the instantiated abstract result, normalised to input origins,
  `fresh`, `shared` or ⊤ (clause 3). Callback effects enter through guarded
  facts, which `classes` makes the actual callbacks' facts. The statement is
  vacuous for calls that pass one array at two input paths (the canonical
  origins of distinct paths do not alias, so no separating naming describes
  such a call): there the caller's Disjoint test, not this lemma, is what
  makes a write safe, and a proof of the step lemma needs a coarser naming
  for read-only aliasing.
* **`map_summary_sound`.** `summary_sound` at `Library.map`, plus: where the
  published result is exclusive at a path, the concrete value there repeats
  no array. The builder's `put` stores only values certified exclusive and
  separated from each other and from outside holders (T59's premise,
  `builder_put_contract` proves the heap side), and `close` either returns the
  builder or, when contents are equal, the source, whose provenance the
  result includes.

### Falsification attempts (`ownership falsify <count> <seed>`, `Falsify.lean`)

Each unproved statement is executed on concrete configurations, its
hypotheses checked rather than assumed:

* **`invariant_preserved`**: random configurations (1–4 int lists, 0–2 nested
  lists, 1–5 variables bound to ints, lists, nested lists, records of lists
  and closures over lists; a random naming in which arrays sometimes share an
  origin; abstract values derived from it, sometimes with an extra origin or
  without an exclusivity flag; random observers and the escapes they imply;
  random continuation uses including field paths) and a random typed
  expression of depth 1–3 over them (push, set, indexed read, length, copy,
  literals, records, `shared`, spine push, element read, focus, list
  traversals reading or consuming, calls of closures, map, update, foldl,
  builder/close, a higher-order callee calling a list callback, lets,
  branches). When the checker accepts, both interpreters run and every part
  of the conclusion is checked; for the naming, one is constructed (each
  array named by every origin of a single base that every requirement
  mentions) and checked against every clause. Two thirds of the samples
  (since the third review) are write-heavy: every variable has arrays and an
  origin of its own, certificates where they hold, and the expression writes
  one variable the continuation does not use (push, set, a record field, a
  consuming focus or traversal, `update` or `map` with a writing callback);
  current accepted/write counts are in RESULTS.md. A sixth of all samples drop one variable from the
  abstract environment, so `covered` fails: the statement does not speak
  about them, and the checker must refuse them, which it did in every case.
  Since the fourth review: a fifth of `capPush`/`capGet` closures, including inner closures captured
  by an outer closure, are described as the other declaration (`ClosuresDescribed` must exclude them,
  and does; current counts are in RESULTS.md); a third of the write-heavy samples alias the
  written variable with another one, live afterwards half the time (current counts are in RESULTS.md); and a quarter of all samples run with fuel 1–8,
  so the error clause is exercised (counts are in RESULTS.md; no error-clause violation).
* **`summary_sound` / `map_summary_sound`**: every call the real in-place
  interpreter makes (its call log: heap and observers before and after) while
  running the accepted programs of a generated campaign, against every published summary
  of the called declaration whose hypotheses the call meets under the
  canonical naming (each canonical origin names the arrays at its path),
  guards resolved with abstract closures built from the actual ones. Every alternate split of those concrete inputs into arguments and captures is also checked, with naming derived independently from the declaration. The three explicit length premises exclude wrong splits; a fixed regression executes the review's wrong split and shows the old conclusion failed.

What it found, in order: the review's counterexample (on the earlier
statement), dishonest closures, ill-typed expressions, `env` paths of known
function values (`namesAt`), and, on the corrected statement, **the second
checker defect below**. After the fixes, the current 100 000-configuration runs and every call of
100 000 generated programs per seed are recorded in RESULTS.md and
`regressions/falsify-followup-*.log`. Those logs, rather than previous rounds'
counts, are the current evidence.

Vacuity fails a run if more than 0.5 % of calls are described by no summary
for a reason other than one array at two input paths, or more than 5 % for
that documented exception. It counts calls, not summary/call pairs. These
budgets expose a loss of exercised hypotheses; they are not correctness
criteria for the theorem. The step samples include closures over closures,
a factory, and a conditional returning a closure or its function argument.
The fixed inner-mislabel regression is checked by guards on every Lean build.

Historical sensitivity runs (before the final round 6 head; not re-run): under `--mutant=` holes the step-lemma check failed
(20 000 configurations, seed 17): once-through-call 22 on that mix
(40 and close-source 442 before the fourth review's additions; disjoint 2,
once-through-call 161, keeps-shape 1, close-source 209 with the all-random
mix). The aliased samples alias whole variables, which Dead, not Disjoint,
decides, so they do not reach the disjoint hole either. The
write-heavy samples give each variable its own arrays, which is what lets
writes pass and also why they rarely meet the disjoint and keeps-shape
holes; the random third still does. It does not see copy-exclusive or
many-calls at this size. The Lemma 6.7 check, over the summaries a mutated
checker publishes (20 000 programs, seed 17), reports callback-writes 721,
callback-aliases 466, callback-xres 323 and callback-escapes 69 violations,
and none under guard-reuse (a reused summary is wrong at the call that reuses
it, which the step lemma, not Lemma 6.7, sees). A clean run is evidence, not proof; the
configurations are small and the summary check sees only calls the
generator makes.

### Defects the restatement found (fixed with fixtures)

1. **A once callback called by a callee was not consumed.** Handing a closure
   that pushes onto its capture to a one-line wrapper that calls it, then
   returning the closure, was accepted by the summary checker; the runs
   disagree on the capture. The per-call checker rejects it. A callee's call
   count of at least one now demands the once closure's roots
   (`once-through-call`, fixture "once closure called by a callee, then
   observed"). Found while restating the invariant.
2. **…and its written captures were not demanded.** A callee's summary does
   not see the callback write its own environment; creation had made the
   capture dead, but `close` can return its (unused) source array, naming the
   capture again. The call now demands the captures the closure's class
   writes, as a direct call does (fixture "close returns a once closure's
   capture, a callee calls it"). Found by the falsifier on the restated step
   lemma.

3. **Written captures of a captured once closure were still hidden.** An
   outer closure captures a writing inner closure; `close` revives the inner
   array; a higher-order callee calls the outer closure. The old checker
   accepted and returned different observations. `demandCallbackCaptures`
   now follows captured function calls recursively, demands their writes
   and roots, forwards symbolic call counts, and checks multiplicity. The
   fixture failed before this fix, then passed; generator v5 and enumeration
   have the shape as well (`nested-once-callee-before.log`).

Generator v4 never built the original two shapes; v5 does, and `once-through-call` is a
required control caught by the generator on all three seeds (RESULTS.md).


**The authoritative audit is `scripts/audit.sh`** (fifth review: the in-build
audit below is the build being audited, and its hand-written tokeniser was
desynchronised by `s!"{ '"' }"` into missing a quote-free `#eval` that
rewrote `Axioms.lean` mid-build, so a `sorry` theorem built green). The
script exports the committed `proofs/ownership` into a fresh directory,
hashes every file, builds only the `audit` executable (`Audit.lean`, which
imports `Lean` and `Std` and no `Ownership` module, so no audited code runs),
and runs `audit sources`: **every source is parsed with Lean's own parser**
and every command and syntax node checked against an allow-list — only
declarations, namespaces, sections, `open`, `set_option maxRecDepth`/linters,
`mutual`, module docs and `#guard` (`#eval` only in `Axioms.lean`); no
`unsafe`; no attribute but `simp`; no `admit` or `native_decide`; no
identifier any part of which names a kernel or compiler bypass; only `Std`
and the package's own imports; exactly three `sorry`s, all in
`Soundness.lean`. It then builds everything, fails if any file changed (the
audit binary included), and runs `audit env` on the built modules: the
pinned `sorryAx` set and the allowed axioms over every constant, every
ordinary constant replayed through the kernel module by module in a fresh
environment of its imports (as lean4checker does), every recursor's complete
metadata compared with the kernel-regenerated value (including nested
auxiliaries absent from the higher-level replay metadata), and no compiler
attribute that swaps in an implementation. The review's payload is refused
at `audit sources` ("command Lean.Parser.Command.eval is not allowed").
Historical audit measurement (before the final round 6 additions):
2 756 constants, 2 750 replayed (the auxiliary recursors of nested inductives
are regenerated by the kernel), about a minute.

`Axioms.lean` is the `AxiomCheck` target of `lake build`, kept as a first line inside the build. It collects the
axioms of **every constant** declared in an `Ownership` module (historically 2 723: theorems, definitions, instances, structures and their
generated auxiliaries, not only the theorems) and fails unless exactly the
three `sorry`s above and the main theorem depend on `sorryAx` and nothing uses
an axiom beyond `propext`, `Classical.choice` and `Quot.sound`. It then sends
every one of them to the kernel again (`Lean.Environment.replay`, as
lean4checker does) in a fresh environment holding only `Std`; the auxiliary
recursors of nested inductives are regenerated by the kernel rather than
replayed. An `example` adds no constant, so it also scans every `.lean` file
under the package, subdirectories included, outside comments, strings and
character literals: exactly three `sorry` tokens; no `admit`, `axiom`,
`run_cmd`, `run_tac`, `run_elab`, `run_meta`, `elab`, `elab_rules`, `macro`,
`macro_rules`, `syntax`, `initialize`, `builtin_initialize`, `#eval` (outside
this audit file) or `unsafe` as a token; no `native_decide`,
`skipKernelTC`, `addDecl`, `addAndCompile`, `setEnv`, `modifyEnv`,
`implemented_by`, `implementedByAttr`, `extern`, `externAttr` or `setParam`
as any dot-separated part of one (so `Lean.addDecl` is caught); and no
import but `Std` and the package's own modules (`Lean` only in the audit).
Since the fourth review it also reads every constant's compiler attributes
from the environment: none may be `implemented_by` another constant,
`extern`, `csimp` or an initialiser. The fourth review's bypass (an `#eval`
calling `Lean.Compiler.implementedByAttr.setParam` to swap a definition's
compiled implementation, which the kernel never sees) fails the build in the
attribute audit and, with that removed, in the scan. Checked on scratch copies: adding
`def x : 1 + 1 = 3 := sorry`, `example : 1 + 1 = 3 := sorry`, an
`instance … := sorry`, `example … := by native_decide`, a character literal
holding a quote before an `example … := sorry`, or the third review's bypass
(a theorem of `False` added by `run_cmd` and `addDecl` under
`set_option debug.skipKernelTC true`, which `lake build Ownership` alone
accepts) each fails `lake build`. The bypass fails twice over: in the kernel
replay ("while replaying declaration Ownership.Bypass.bogus"), and, with the
replay removed, in the scan. No axiom is declared. All statements take `check p = .ok _`
under the default (corrected) config.

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
2. **`need` appears unnecessary as a separate row** in this core (argued,
   not checked): guarding the declaration's own `xres` on the callback's
   `res`/`xres` carries it in every fixture and generated program.
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

### Verification after the sixth independent review

The parser checks command nodes recursively, including `in` and `mutual`,
and refuses executable `run_tac`/`run_cmd`/`by_elab` syntax before elaboration.
There is no exemption for ordinary definitions or theorems named `rec_*`.
Recursor declarations are compared in full against the kernel's regenerated
`RecursorVal`s using its kernel environment, including nested auxiliaries
that Lean's higher-level replay metadata does not register. This avoids both
the broad name skip and the replay API's missing-auxiliary-recursors error.

The main theorem still uses only `invariant_preserved`: the step lemma carries
the soundness proof. `summary_sound` and `map_summary_sound` are separate
unproved obligations, not artificially inserted into that dependency chain.
Three sorries remain; no complete certification is claimed.

The 144-program targeted grammar enumerates its displayed Cartesian products:
constants -1/0/1/2, both comparison/branch outcomes, 1/2/3 calls of a captured
once callback, a consumed captured list supplied to a captured writer,
transitive capture revival, set indices 0/1, and small first-order recursion.
CI runs it alongside the original size-2 grammar. It is still a small grammar;
arbitrary declaration tables, type shapes and recursive structures remain
outside exhaustive coverage. RESULTS.md distinguishes the two searches.
