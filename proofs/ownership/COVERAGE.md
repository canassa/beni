# T1–T59 coverage audit

The #165 orientation found counterexamples to the current proof statements.
[PROOF-PLAN.md](PROOF-PLAN.md) records construction fuel (#168), linked-view naming (#169), and summary observer permissions (#170).
`Ownership/StatementChecks/` contains their regression witnesses.
The statements and their three `sorry` proofs remain unchanged.

Before the #168 fix, `accepted_traces_agree` was false for a closed accepted program.
At fuel 5, only its value run succeeded.
The in-place interpreter now uses the value interpreter's construction tick schedule.
The retained regression proves equal traces at fuel 5 and equal remaining fuel at fuel 6.
This fix closes that counterexample. All three general proof obligations remain open.

Current follow-up measurements are in [RESULTS.md](RESULTS.md) and its linked logs.
Historical numerical sensitivity measurements below are marked as such;
they do not establish final-head coverage. The executable theorem statements
still have three `sorry`s, including the step lemma on which the main theorem
is conditional.

The earlier sections' source-mutant numbers belong to round 6. The checker-sync
evidence is the final section and the opening section of RESULTS.md.

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
| T18 | out of scope | The core models list views. Cached `$plain` and JavaScript header identity remain outside this core. |
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
| T32 | projection tested | Dictionary key/value same cell modeled by two record fields in list; actual Dict algorithm absent. The dictionary model of 2026-10-21 (#522, `DictProbes.lean`) has integer keys, so a list as key cannot occur there; the projection stands. |
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
| T44 | modelled, checked on 1 program | `DictProbes.groups` (2026-10-21, #522): a traversal over `[1, 2, 3, 4]` from `dictEmpty` whose step focuses on the key `x < 3` and pushes `x` onto the group, or starts it with `[x]`; accepted, both runs end at the two groups in insertion order, four in-place writes. `Maybe v` is `Result Int v`; the lookup is `dictGet`. Not proved. |
| T45 | out of scope | Command retained capture precision across TEA arms absent. |
| T46 | projection tested; summary row tested | Previously listed as "core tested" on one row, where the borrowed row is returned but never written, so owned and borrowed were indistinguishable. Now: shared and captured conditional accumulators rejected; borrowed element then later push rejected; the List.isEmpty projection runs over **two rows**, so the second step pushes onto the borrowed first row, retained afterwards (rejected; under `borrowed-supply` with the per-call checker it is accepted and the traces differ); a three-row variant `[r1, r2, r1]` that reads r1 again. The row the thesis repaired — foldl's accumulator supplied owned only if the callback returns owned — is the summary layer's supply bit, re-checked where the step ends; its mutants `supply-recheck` and `supply-edge` are required controls caught by generated programs (`fold-keep`, `apply-read`). Only ordinary foldl and two callbacks; no Dict/fiber/TEA variant. |
| T47 | projection tested; release/renderer excluded | Transparent one-field Column record under list focus edited by push and wrapped again, accepted. Erased constructor identity and renderer release protocol absent. |
| T48 | projections tested | Duplicate versus distinct transparent record slots in list rejected/accepted. Opaque module summaries and Conduit entry protocol absent. |
| T49 | out of scope | The core includes the fixed recursive Chain type. The complete thesis variant for recursive data representatives and across-level exclusivity remains outside this core. |
| T50 | out of scope | Borrowed send-message writes and parking absent. |
| T51 | modelled, checked on 2 programs | `DictProbes.emptyFocus` (2026-10-21, #522): `dictEmpty` is a fresh root with no cell, and a focus on an absent key reads no value and writes the entries once (the added key); accepted, both runs agree. `DictProbes.reads`: a focus whose body reads the found value and stores a new list at the key writes the entries back in place (two counted writes, the insert and the write-back), so the old dictionary read afterwards is refused (Dead); both runs agree only because the old dictionary is read through its size, which a replace does not change; the Zig checker accepts `DictFocus.reads` today because core's `Dict.update` builds a new tree (the old fold, until #294 lands; #579). Not proved. |
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
The core includes fixed Result and recursive Chain types, list views, and construction primitives.
It excludes arbitrary opaque or recursive type declarations and record-update or list-pattern surface syntax.
It also excludes effects/fibers, TEA entry analysis, the renderer, release
identity rewriting, implicit method dispatch or dictionary/schema implementation.
The checker explicitly rejects higher-order recursive actuals and recursive
changes to tracked shape/exclusivity; these are implementation limits rather
than new thesis rules (Ch. 3 demand/summary contracts; Ch. 4 inference; Ch. 6
soundness/derived-contract obligations). No excluded runtime or language-boundary variant is reported as passed. The broadened campaigns reach higher-order-recursion `limit:` rejections,
reported separately; this does not prove recursive contracts universally derivable.
The `callbacks` limit (`ownership-checker.md` §16.7, #271; `Config.callbackLimit = 4`) is the one §16.7 limit the core states: a call of a function input whose arguments' callback-chain depth is already four (`Domain.rhsChain`: a binder bound to the result of such a call is one deeper than its arguments, any other binder is as deep as the deepest binder its value mentions) is the error `limit: callbacks`, in both checkers (`Checker.Context.chain`, `Reinfer.Context.chain`). The core cannot nest callbacks (a callback with a function-typed parameter or result is already a limit), so only the hand-on chain is counted. The limit does change verdicts, as the Zig checker's does: a read-only chain of five callbacks that the precise rule accepts (`chainRead 13`, accepted under `callbackLimit := 5`) is refused as `limit: callbacks`, in both checkers (`#guard`s); where a write follows the chain, the precise rule refuses it as well (`chainPushed 11` under `callbackLimit := 5` fails as `chainPushed 10` does). The bridge compares the same programs.

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

T6/T22 require runtime Task.join and unknown-origin values.
An explicit shared root tests Unescaped; it does not test Known. T44/T51 require dictionary/Maybe algorithms
and the empty-dictionary representation. T49 needs the complete recursive-data variant;
the fixed Chain projection does not establish that coverage. T59's schema variant requires schema
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

## Theorems (Soundness.lean, BuilderProof.lean, HeapProof.lean, LinkedWriteFrame.lean, KernelChecks.lean)

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
| `LinkedWriteFrame.writeLinked_preserves`, `writeLinked_changed_address` | proved; conditional on runtime success. Links and permanent registrations stay equal. Every changed address belongs to the receiver's initial undirected link component. |
| `LinkedWriteFrame.writeLinked_preserves_represents`, `writeLinked_preserves_representsMany`, `writeLinked_preserves_snapshot`, `writeLinked_preserves_observers` | proved; conditional on runtime success and complete finite representation footprints outside that component. The observer theorem covers every pre-write permanent registration. |
| `LinkedWriteFrame.writeCounted_preserves`, `writeCounted_preserves_represents` | proved; the real counter wrapper preserves the same heap frame and an individual representation under the stated success and separation premises. |
| `LinkedWriteFrame.example_run`, `example_observer_frame`, `example_all_observers_frame` | proved; a linked write changes source 0 and view 1 while the nonempty permanent observer list retains the independent array `[7]`. |
| `Invariant.linksValid`, `Invariant.linkNamed` — the link clauses (#169): every stored link is valid, and linked storage a live path or an observer protects is named as one array | **added to the invariant** (owner decisions q1 and q4). `LinkClauses.lean` proves `LinksValid` with the same heap and links, after an allocation, after a `set!` of a nonempty list and after a view; `LinkNamed` with the same heap, links and observers; and that the per-link closure `LinkClosed` gives `LinkNamed` and survives a naming that keeps old origins and names a new view by its source's origins. No theorem uses these lemmas yet; that an accepted execution keeps the clauses at a state with a link is not proved. |
| `summary_sound`, `map_summary_sound` — the written-storage premise `linked : LinkedWritesCovered` (#169, R1): an input array a link connects to an input array at a permitted path is at a permitted path | **added to both statements** (standing guidance: a stronger premise accepted callers establish). `LinkSummaryCounterexample.not_covered` proves the R1 pre-state fails it; `no_call_sound` keeps the record that every other premise held there and the conclusion failed. The derivation at accepted callers (from the call-site Disjoint test and `Invariant.linkNamed`) is the next obligation. |
| `LinkedCallControl.linked`, `trigger`, `concrete_run` — the control of the written-storage premise at a reachable call: every premise of `summary_sound` at the pre-state the in-place run logs for `w(rest)` with a dead source | proved, with `#guard`s that the checker accepts the program, both runs agree, and the run logs exactly that pre-state; `LinkSummaryCounterexample.pre_linksValid` puts the R1 witness in allocation order, so it fails the premise alone |
| `CallDerivation.linkedWritesCovered_of_applyCall` — the written-storage premise at a first-order call without captures, from the call-site invariant and the call's own `applyCall` demands | proved; the hypotheses are the call-site `Invariant`, the default configuration, the operands as live variables with their abstracts and values, first-order and known actuals, no closure argument, base rows, and the successful `applyCall` run. Calls with captures and calls with function-valued inputs are not covered, and the wiring from `inferExpr`'s `.app` case (`mapM`, `callKnown`, `summarise`) is open. |
| `CallDerivationInstance.covered` — the derivation applied at a reachable first-order call with a link: the call-site invariant (`invariant`, a kernel proof), the real `applyCall` run (`apply_run`) and every other hypothesis discharged | proved; the conclusion agrees with `LinkedCallControl.linked`. Still open: arguments that are not variables, captures, function-valued inputs, `known`, the `.app` wiring |
| `LinkedWriteStep.linkNamed_after_writeLinked`, `linkNamed_after_writeLinked_liveCells` — the naming clause after a successful demand-guarded linked write of a live receiver, with the same naming, for the continuation's uses | proved; from the pre-state invariant, the successful default demand, the receiver named by the demanded cells, the continuation's uses inside the pre-state's, `aenv` covering the continuation's live variables, and `later` holding the checker's `liveCells` of the continuation. `reaches_decompose`: a path in a heap that agrees with another outside a set either exists there or first meets the set. `namesAt_mem_paths_general`: the names at any path of any abstract are drawn from its recorded paths. `LinksValid` under `writeLinked` is not proved. |
| `LinkedWriteInstance.after_named`, `second_constrained` — the step lemma applied at a reachable state with two link components: the pre-state invariant (a kernel proof), the real demand and the real `writeLinked`; afterwards the live `ys` protects the second component, so the conclusion names arrays 2 and 3 alike | proved; the written component's dead source changes (`source_changed`) |
| `LinksValid.contents` — every view holds its source's suffix or prefix (#169, the first bullet's contents fact) | **added to the invariant** (2026-10-17); true on reachable states only with #284's hand-over, which this change depends on; `linksValid_of_same`, `linksValid_push`, `linksValid_viewed` and the kernel proofs of `LinksValid` extended; `linksValid_set` now asks that no link names the written array |
| `LinkedWriteValid.linksValid_after_writeLinked` — all four clauses after a successful `writeLinked c xs` with `old.length ≤ xs.length` at `c` | proved, with the run's success as a hypothesis; through `spliceUp_valid` (the splice stays below its top and does not shorten it) and `refreshDown_valid` (every link below the top consistent, only strict descendants changed), over the subtree order `Below` and the forest facts `source_unique`, `below_parent`, `below_child`, `below_disjoint` |
| `LinkedWriteValidInstance.chain_valid_after`, `pair_valid_after`, `shorten_breaks` — `linksValid_after_writeLinked` at two reachable states: the two-component push of `LinkedWriteInstance`, and a chain `xs ← rest ← tl` written through the inner view, where the splice climbs two levels and the refresh rewrites both views (`chain_write`, the real `writeLinked` by `cbv`; `chain_outer_contents` compares the conclusion with the computed heap); a shortening `writeLinked` of the root (`short_run`) empties a source and fails `sources`, so the non-shortening hypothesis is needed (`short_breaks`); a plain `set!` of a linked source makes a view stale (`shorten_breaks`) | proved (the review of PR #314, note 2); every theorem on the standard axioms |
| `ViewCounterexample.no_invariant`, `only_linkNamed`, `ordered_no_invariant` — the #169 pre-state admits no naming under the strengthened invariant, and the same witness in allocation order fails `LinkNamed` alone | proved; the live source protects the component, so the view must carry the source's origins, and the two sites do not alias. The original witness also fails `LinksValid` (its view address is below its source), so the ordered witness is the regression for `LinkNamed`. The old statement's `no_post_invariant` is kept for the record. |
| `FlatFragment.Preservation.accepted_flat_anf_traces_agree` (`FlatFragment/Trace.lean`) — the main theorem's conclusion for an accepted program whose main expression is in the first flat fragment (`FlatFragment.Support.FlatANF0`) | proved; no `sorry` and no pinned dependency. The scope hypothesis `FlatANF0 p.main` is the only addition to `accepted_traces_agree`. |
| `FlatFragment.Preservation.flat_preserved` (`FlatFragment/Trace.lean`) — preservation of the strengthened flat relation `FlatInvariant` over the fragment, in both runtime directions | proved; structural induction over the fragment from the actual acceptance, typing, and shadow runs. The relation permits nonempty heaps, permanent observers, and stale dead aliases. |
| `FlatFragment.HeapFrame.flatInvariant_heap_frame` (`Frame.lean`), `FlatFragment.Push.push_preserved` (`Primitives.lean`), `FlatFragment.Let.let_preserved` (`Let.lean`) | proved; the push case derives the written array's separation from the real default demand, not from an alias prohibition. |
| `FlatFragment.Scalar.scalar_preserved` (`Primitives.lean`), `FlatFragment.Static.scalar_static` (`Static.lean`) — the integer primitives `add`, `sub`, `eq` and `lt` on two atoms, which typing fixes to `Int` (`Support.ScalarOp`) | proved (2026-10-18); both runtimes compute `scalarResult`, the checker returns a scalar and changes no state, and no read is recorded; the fragment's live-set lemmas have the case. Both interpreters compute on Lean's unbounded `Int`, where beni's `Int` is a JavaScript double: the two runs agree exactly, and the theorem says nothing about rounding. |
| `FlatFragment.Record.record_preserved` (`Primitives.lean`), `FlatFragment.Fields.flat_atom_values`, `describes_flat_frame`, `corresponds_flat_frame`, `live_path_apart` (`Fields.lean`), `FlatFragment.Let.flatInvariant_bind` (`Let.lean`) — field atoms and records: every atom, which typing fixes to an integer, a variable or a variable under a field path; a binding may hold a record of integers and integer lists, nested, and `record` builds one | proved (2026-10-18); `types` and `abstractShapes` keep their names and admit records (`FlatType.record`, `FlatAbstract.record`, `AllocatedFlatValue.record`, indexed field by field); an atom evaluates from its root binding through `projectObs`/`projectVal`, and the invariant's `bindings` and `described` clauses at the live path give its correspondence and description; the let binder's live paths are typed field paths (`flat_uses_typed`); the heap frame follows the value's structure instead of the integer-or-array split; the push's Dead test keeps every array of a live projected value apart from the written root through `inv.named` at the full path and the live cells. A `shared` of a value deeper than `observationDepth` fails on both sides at the observer epilogue (`shared_deep_failure`, `value_observeKept_ok_depth`); no program `check` accepts at its default inference fuel (200, one unit per `let`) reaches this case, because a record adds at most one level per `let` (a shared value is at most 199 deep, 197 records over a list; a final value can reach 200; the reviews of PRs #375 and #422 measured it), and the lemma holds for every fuel, which `flat_preserved` is generic in. |
| `FlatFragment.Branch.branch_preserved` (`Branch.lean`), `FlatFragment.Fields.flatAbstract_join`, `describes_join`, `flatInvariant_more_escapes`, `ty_equal_flat` (`Fields.lean`), `FlatFragment.InferBranch.infer_branch_success` (`Checker.lean`) — `branch` over two fragment expressions on an integer condition | proved (2026-10-19); the checker infers both arms from the same facts, restores them between the arms, and joins both arms' results and escapes (`Summary.join`, `Abstract.join`); the taken arm's induction hypothesis carries the runtime step, the other arm's static facts (`flat_static`) give the join its shape; the join of two flat abstracts of one type is flat, it describes what either side describes (the union of two lists' cells names either list's array), and the invariant holds with more escapes (`keptEscaped` is its only escapes clause); typing makes both arms' types equal through `Ty.equal`, which on a flat type is equality. The probe `branchOps` pushes onto the result of a branch between two lists, is accepted, makes one in-place write, and both runs end at `[2, 9]`; `branchAlias` keeps the other list live after that push, is rejected (Dead, because the branch's result names both lists), and its two runs differ. |
| `FlatFragment.Push.push_preserved` with any receiver atom (`Primitives.lean`, 2026-10-19), `FlatFragment.Fields.flat_atom_list_path`, `live_path_apart` (`Fields.lean`) — a write through a field: the push receiver is a variable under a field path | proved (2026-10-19); the receiver evaluates from its root binding through the live path, the demand is the real one on the projected list's cells, and the Dead test keeps every array of a live projected value apart from the written root as before; `FlatAtom` and `flat_atom_list` are gone. The probe `fieldWrite` pushes through two field levels with the record live at another field, is accepted, makes one in-place write, and both runs end at `{[1, 7], [2, 3]}`; `fieldWriteLive` keeps the written field live, is rejected (Dead), and its two runs differ. |
| `FlatFragment.ResultCase.resultCase_preserved` (`ResultCase.lean`), `FlatFragment.Result.ok_preserved`, `err_preserved` (`Primitives.lean`), `FlatFragment.InferResultCase.infer_resultCase_success` (`Checker.lean`), `FlatFragment.State.ResultTags` and the invariant fields `tags` and `liveTyped` (`Support.lean`), `FlatFragment.Fields.resultTags_join`, `resultTags_project`, `ty_equal_flat_right` (`Fields.lean`) — `ok`, `err` and `resultCase` over two fragment arms | proved (2026-10-20); a result is a record of a tag and two slots on both sides (`[1, 0, x]` for `ok x`, `[0, x, 0]` for `err x`), and in the checker a record of a scalar and two slots, the other one bottom; the checker skips a case arm whose slot is bottom (`Checker.lean`, `resultCase`), so the relation records, for every binding, that a success is described with a live success slot and an error with a live error slot (`ResultTags`), which survives joins, origin substitutions and field projections, and which `Preserved` carries for every expression result. The taken arm runs under the binder with the payload's facts, like a `let` body, and the other arm's static facts, or bottom, give the join its shape. Typing fixes the case input to a `result` and both arms to one type. The relation also records that every live use is a typed path of its binding (`liveTyped`), so a projection never enters a result's slots. The probes `resultOps` (an `ok` of a list, a case that binds it, a push onto the case's result: accepted, one write, both runs end at `[1, 9]`), `resultAlias` (the list read after that push: rejected by Dead, the runs differ) and `errOps` (an `err` of a list, a push in the error arm while the checker skips the success arm: accepted, one write, `[3, 4]`) check it at build time, and `bothWrite`/`bothWriteLive` (the #437 review's note: a branch on the condition `0` whose both arms push; accepted with `[1, 5]`, and rejected by Dead with differing runs when the list is read after) cover the `yes` arm of a branch. |
| `FlatFragment.ChainCase.chainCase_preserved` (`ChainCase.lean`), `FlatFragment.Chain.endChain_preserved`, `link_preserved` (`Primitives.lean`), `FlatFragment.InferChainCase.infer_chainCase_success` (`Checker.lean`), `FlatFragment.State.ChainTags` and the invariant field `chains`, `FlatAbstract.bottom` (`Support.lean`), `FlatFragment.Naming.origin_allocation_naming` (`Support.lean`), `FlatFragment.Fields.chainTags_join`, `chainTags_project`, `flat_atom_chain_path` (`Fields.lean`), `FlatFragment.Static.flat_type_of_typed`, `static_atom_shape` (`Static.lean`) — `endChain`, `link` and `chainCase` over two fragment arms | proved (2026-10-20); a chain is an integer array on the heap side and an integer list on the value side, like a list, and the checker describes it as a list (`FlatAbstract.chainBottom`, `chainScalar`). `endChain` and `link` allocate at the real address, like a literal, and the checker names the result by a fresh site root. The heap runtime copies the tail of a nonempty chain into a fresh array, which the checker names by the input's origins, so the naming extends at one of them (`origin_allocation_naming`; every origin aliases itself, `aliases_self`), and the invariant holds at the copy as at a literal (`tail_post_invariant`). The checker infers both arms from the incoming facts and binds the head to the element abstract: `endChain` builds a bottom element, so the link arm of a case on a statically empty chain is inferred with a bottom head, dead code. The static relation therefore admits bottom as the abstract of dead code at every type and inside records and result slots (`FlatAbstract.bottom`; a result's two slots are flat-or-bottom, with no live requirement), the static theorem takes every operand's abstract from the actual run (`static_atom_shape`, `infer_primitive_args_success`: a field of a dead record fails the read, a push onto a dead receiver returns bottom, a case on a dead input returns bottom), and the type of a well-typed fragment expression is flat from typing alone (`flat_type_of_typed`, for a case whose arms are both skipped). The runtime relation keeps non-bottom shapes through the tags (`ResultTags.int` is the scalar, `listInt` and `chainInt` are list descriptions; `resultTags_ne_bottom`), and a new relation `ChainTags ty abstract observation` says that a chain described with a bottom element is empty on the value side, through records and the live slot of a result; `FlatInvariant` records it for every binding (`chains`), `Preserved` carries it for every expression result, and it survives joins, origin substitutions and field projections. So the arm the runtime takes binds a scalar head, and the dead arm's result enters only the join (`flat_static` on the extended static environment). The probes `chainOps` (two links onto an empty chain, a case that builds a list of the head and pushes onto it: accepted, one write, both runs end at `[2, 7]`), `chainEnd` (a case on an empty chain whose link arm the checker infers with a bottom head; the end arm pushes: accepted, one write, `[9, 1]`), `chainAlias` (a push in the link arm onto a list read afterwards: rejected by Dead, the runs differ) and `chainResult` (a chain in `ok`, a result case, a chain case on the payload with a push: accepted, one write, `[3, 4]`) check it at build time. |
| `FlatFragment.ListPrimitives.at_preserved`, `set_preserved`, `copy_preserved`, `prepend_preserved` (`Primitives.lean`), `FlatFragment.Fields.primType_at_success`, `primType_set_success`, `primType_copy_success`, `primType_prepend_success` (`Fields.lean`) — `at`, `set`, `copy` and `prepend` on flat integer lists | proved (2026-10-20); `at` reads the element at the index, or the fallback for a negative or out-of-range index (`atResult`), and both runtimes record that integer as a read, like `length`; the checker records a read of the receiver's roots and element cells and returns the join of the element abstract and the fallback's, the scalar in live code. `set` is a counted write like `push`: the real demand on the receiver's cells, the heap frame at the written root, and the list after the write (`setResult`), unchanged for a negative or out-of-range index, in which case the counter does not move. `copy` allocates a copy at the real address, like a literal, and the checker names it by a fresh site root; `prepend` records a read of the base on both sides (the value runtime observes the list, the heap runtime its snapshot) and allocates the copy with the item in front, which the checker names by the fresh site root and the base's origins. The proof does not pin the base's origins: the heap model always copies, so `prepend_preserved` needs only the fresh root, and the theorem would hold if the checker dropped the base's origins, which protect the real runtime's re-cons; only the `prependAlias` guard pins them. A dead receiver (its abstract bottom) returns bottom in the checker, as for a push. The probes `atOps` (three reads, one at an out-of-range and one at a negative index, their sum pushed: accepted, one write, both runs end at `[4, 5, 8]` with the reads `5`, `0`, `3`), `setOps` (a write at `0`, then at `5` and at `-1`, which change nothing: accepted, one counted write, `[9, 2]`), `setAlias` (the written list read after the write: rejected by Dead, the runs read `1` and `9`), `copyOps` (a push onto a copy while the original stays live: accepted, one write, both runs end at `1`), `prependOps` (a push onto a prepend's result: accepted, one write, `[1, 2, 9]`, the read `[2]` on both sides) and `prependAlias` (the base read after that push: rejected by Dead, since the result is named by the base's origins; the runs agree) check it at build time. |
| `FlatFragment.Preservation.every`, `liveAlias`, `observed`, `arith`, `recordOps`, `fieldWrite`, `fieldWriteLive`, `branchOps`, `branchAlias`, `bothWrite`, `bothWriteLive`, `resultOps`, `resultAlias`, `errOps`, `chainOps`, `chainEnd`, `chainAlias`, `chainResult`, `atOps`, `setOps`, `setAlias`, `copyOps`, `prependOps`, `prependAlias` (`Trace.lean`, `#guard`) — the reviewer's probe programs of PR #267, the integer-primitive probe, the record probe, the field-write probes, the branch probes, the result probes, the chain probes and the list-primitive probes | checked at build time: `every` uses the six forms of PR #267, is accepted, both runs agree, and it makes one in-place write; `liveAlias` and `observed` are in the fragment, are rejected (Dead, Unescaped), and their two runs differ; `arith` uses `add`, `sub`, `eq` and `lt` on variables and literals before a push, is accepted, makes one in-place write, and both runs end at `[2, 1]` with the read `1`; `recordOps` builds a record of two lists and an integer, reads it through field atoms, binds a field to a variable and pushes onto it, is accepted, makes one in-place write, and both runs end at `[2, 3, 8]` with the read `1`; `fieldWrite` pushes through a field path two levels down with the record live at another field, is accepted, makes one in-place write, and both runs end at `{[1, 7], [2, 3]}`; `fieldWriteLive` keeps the written field live, is rejected (Dead), and its two runs end at different values; `branchOps` branches between two lists on a length and pushes onto the result, is accepted, makes one in-place write, and both runs end at `[2, 9]` with the read `1`; `branchAlias` reads the other list after that push, is rejected (Dead), and its two runs read different lengths; `bothWrite` pushes in both arms of a branch on the condition `0`, is accepted, makes one in-place write, and both runs end at `[1, 5]`; `bothWriteLive` reads the list after that branch, is rejected (Dead), and its two runs read different lengths; `resultOps` wraps `[1]` in `ok`, binds it in a case and pushes onto the case's result, is accepted, makes one in-place write, and both runs end at `[1, 9]`; `resultAlias` reads the list after that push, is rejected (Dead), and its two runs read different lengths; `errOps` wraps `[3]` in `err` and pushes onto it in the error arm, is accepted, makes one in-place write, and both runs end at `[3, 4]`. Kernel proofs put all twenty-four in `FlatANF0`. |
| kernel checks of `storeExclusive` and permanent escapes | proved (unchanged) |
| `DictProbes.grow`, `twice`, `valueLater`, `reads`, `groups`, `tupleShared`, `tupleFresh`, `valueWritten`, `emptyFocus`, `removeOps`, `replaceOps` (`DictPrograms.lean`, `DictProbes.lean`, `#guard`) — the dictionary model's probes (#522, 2026-10-21): `DictFocus.beni`, `DictValueWritten.beni` and #474 in the core's ANF | checked at build time, not proved: `grow`, `groups`, `tupleFresh`, `emptyFocus`, `removeOps` and `replaceOps` are accepted, both runs agree on every read and the final dictionary, and the in-place write counts are 3, 4, 3, 1, 4 and 3; `twice` (one list at two keys) and `tupleShared` (#474, one tuple at two keys) are refused by the certificate and their runs end at different dictionaries; `valueLater` and `valueWritten` are refused (the old dictionary holds the written value and is read afterwards) and their runs read different lengths; `reads` is refused (Dead) although its runs agree. No theorem names a dictionary form yet. |

The linked-write frame uses the undirected closure of the pre-state's actual stored links.
Its helper proofs follow the real `spliceUp` and `refreshDown` operations and their explicit depth bounds.
It requires no valid-link, acyclic-link, empty-link, or empty-observer premise.
Runtime success remains a premise. These lemmas do not establish success for arbitrary states.
Complete finite representations supply every protected footprint address at the stated snapshot depth.
The caller must still derive footprint separation from accepted demands.
These lemmas establish no result correspondence, certificate preservation, or `CallSound.noNewHolders` clause.
They do not cover allocation, plain builder `put`, or complete expression evaluation without further composition.
They do not resolve #169, #170, or any general proof obligation.

The first flat fragment (`Ownership/FlatFragment/`) is `FlatANF0`: atoms, `let`, integer list literals, `push`, `length`, `shared`, the integer primitives `add`, `sub`, `eq` and `lt` on two atoms, since 2026-10-18 the record constructor, since 2026-10-19 `branch` over two fragment expressions, since 2026-10-20 `ok`, `err` and `resultCase` over two fragment arms, since 2026-10-20 (later that day) `endChain`, `link` and `chainCase` over two fragment arms, and since 2026-10-20 (the third slice of that day) `at`, `set`, `copy` and `prepend`.
`FlatANF0` puts no condition on an atom; the theorem also needs `check`, and typing fixes every atom to an integer, a variable or a variable under a field path, the scalar operands, literal elements, push and set items, the `at` index and fallback, the set index and the link and prepend heads to `Int`, the `length`, `push`, `at`, `set`, `copy` and `prepend` receivers to `List Int`, the link tail to `Chain Int`, the branch condition to `Int`, a result case's input to a `result` and a chain case's input to a `Chain Int`; since 2026-10-19 the push receiver may be a field path (a write through a field); a binding holds an integer, an integer list, an integer chain, a record of such values, or a result over them, nested.
It excludes lists of lists, calls, closures, views, constructions (`construct`), builders, scopes, the loops (`traverse`), `focus`, and every other primitive.
`accepted_flat_anf_traces_agree` has the exact conclusion of `accepted_traces_agree` and one extra hypothesis, `FlatANF0 p.main`.
Its proof does not use `invariant_preserved`, `summary_sound`, or `map_summary_sound`.
The internal relation `FlatInvariant` extends `Invariant` with typed allocated bindings (integers, integer lists and integer chains whose contents the shape carries, records of them and results over them; since 2026-10-23 the relation says nothing about the arrays no binding holds, #522 slice 2a), empty links, aligned environments, a bounded naming, a complete finite observer witness, the result tags of every binding (a success is described with a live success slot, an error with a live error slot, and no live position is bottom), the chain tags of every binding (a chain described with a bottom element is empty), and typed live paths; the static shapes admit bottom as the abstract of dead code.
Each case derives its frame from the actual checker run: a push's demand excludes the continuation's live bindings and every permanent observer from the written array; a literal extends the naming at the real allocation address; `shared` records the value's roots as escapes; a branch joins both arms' results and escapes, so a push onto its result demands every list either arm could return; a result case runs the arm of the runtime tag, which the tags say the checker inferred, and joins it with the other arm's result or bottom; a chain case runs the arm of the runtime chain, the link arm under the head and the copied tail (named by the input's origins), and joins it with the other arm's result; `at` and `prepend` record the same read on both sides, `set` makes a push's demand and frame at the written root, and `copy` and `prepend` allocate at the real address.
The fragment proof establishes nothing for calls, views, linked storage, or the three general obligations, which remain open.

The link clauses (`LinksValid`, `LinkNamed`, 2026-10-16) answer #169's first obligation, for the main-context invariant.
`LinksValid` records the link structure: allocation order, nonempty sources, one source per view, and since 2026-10-17 the contents (`contents`: a view holds `viewOf front source`).
`LinkNamed` is the plan's narrowed clause: linked storage that a live path or a permanent observer protects is named as one array, so a demand's Dead, Disjoint and Unescaped tests on one side cover every holder of the other.
The clause is conditional on protection, not on a write. At a read-only split such as `readBoth(rest, xs)` both sides are live, so the clause names the view and its source alike, which the checker's view rule makes possible (a view gets its source's origins and a fresh site). Distinct canonical names exist only in a callee frame, where `Invariant` does not apply, so R1 states its premise on written storage. A component that nothing protects is unconstrained.
A view's contents are the fourth clause. It needs #284: a builder's `put` writes with `write`, so before the hand-over the garbage view of a closed and viewed builder went stale in an accepted program (`ViewLinks.lean`, *A stale garbage view*, checked by `#guard`; `LinkSummary.lean` checks that `linksValidB` reports that state). With the hand-over a builder is never linked, and every write that reaches a linked array is a `writeLinked`. `LinkedWriteValid.lean` proves `LinksValid` after a `writeLinked` that does not shorten the written array.
The summary theorems keep distinct canonical names for a view and its source. Their linked-input premise is `LinkedWritesCovered` (R1): it speaks only of input arrays at permitted paths, so a read-only split such as `readBoth(rest, xs)` stays inside both statements.
`CallDerivation.lean` derives it at a first-order call without captures from the call-site invariant and the call's demands; captures, function-valued inputs and the `.app` wiring remain open.
`invariant_preserved` keeps its `sorry`; its statement now carries the clauses. `LinkNamed` and `LinksValid` under a successful `writeLinked` are proved (`LinkedWriteStep.lean`, `LinkedWriteValid.lean`); both clauses under a call are the next obligation.
The falsifier tests both clauses (`linksValidB`, with the contents check, and `linkNamedB`) on generated states with links since 2026-10-18 (#274): a third of `Falsify.config`'s configurations hold a view of a nonempty leaf, and half of those a second view of the first when the first view is nonempty (a chain of two; the review of PR #347 counted 1,606 chains among the 6,320 linked configurations at seed 17), the view named by its source's origins and bound to variables as the checker describes it (the source's origins and a fresh site), beside variables bound to the source; `Falsify.expr` makes `.view`, and the write-heavy samples push through a fresh view. `rename` names a view by its source's new origins, a garbage view included, because the clause names every array of a protected component alike. `Protected`'s live half is tested in both directions (the review's Medium finding): `Falsify.sample` computes protection on its own and names a view of a component that nothing protects apart from its source (legal; `linkApart` counts the samples, which must stay clean), and names a quarter of the views a live path protects apart as an expected exclusion (`linkMisnamed`), which the invariant must refuse with the `LinkNamed` message; a protected view named apart that passes is a failure. The observer half is not tested: views an observer reaches keep their names (1,043 of the 6,320 linked configurations have such a component, the re-review counted), so a `Protected` that ignores observers passes clean (the re-review's `LiveOnly` mutant); naming a share of those views apart with an escaped fresh origin is issue #354. `lake exe ownership falsify 20000 17`: 6,320 of 20,000 configurations hold a link in the pre-state; 3,810 samples where both runs succeed hold a link in the post-state, and in 868 of them the step wrote a linked array (`postLinksWritten`: a post-state link whose view or source differs from the pre-state; the other post-state links did not change); 2,656 samples name an unprotected view apart and stay clean, and 2,251 of them reach and pass the `LinkNamed` check (the others stop earlier, 265 as uncovered and 140 at a mislabelled closure, the re-review counted); 660 name a protected view apart and are refused; `hypothesisFalse`, `observational`, `naming` and `linkClause` (failures a link check reported) are 0. With `protectedArrays` mutated to every array, 440 of 4,000 samples fail the hypothesis on the legal unprotected naming; mutated to no array, 153 protected views named apart pass the invariant and are reported (scratch runs, seed 17). The checker's `view-alias` control (the view forgets its source) is the first control the link evidence catches: `lake exe ownership falsify 20000 17 --mutant=view-alias` on `c41c56ccc` gives 353 observational and 77 naming failures (all 77 of them `linkClause`); the base campaign without links gave 0. The first run found `rename` leaving a garbage second view unnamed, fixed; no checker finding.

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

## Zig checker sync projections

The projections live in `Ownership/Sync.lean`, independently enumerated over
four integer values and the displayed boolean/depth products. The original
144 targeted programs remain; 204 sync programs bring the total to 348.
Accepted fixtures execute both interpreters. Every sync control is required
both as a fixed disagreement and through the targeted enumerator in `ci` and
`controls`; `Mutant.enumeratorRequired` cannot be omitted from the probe table.
`branch-live`, already required through the generator, also tests withDefault.

| Zig fixture / rule | Core projection and boundary |
|---|---|
| `ownership/BranchEscapes`, `BranchSoonEscapes` | `branchEscape`, `branchCall`: sibling escape accepted, earlier/joined escape, callee escape and recursive escape rejected. `shared` is a permanent reader, not an actual fiber. |
| `build/bad/direct/OwnershipRecursiveChildren`, `OwnershipRecursiveChildrenUpdate` | `invariant .model`, `modelUpdate`: distinct init and fresh replacement accepted; duplicate init, duplicate replacement arm and escaped update rejected. The core uses finite nested lists and records, not recursive types. |
| `ownership/FoldAccumulators`, browser `SubscriptionTapFold` | `invariant .range`, `badFold`, `taps`, `capturedAfter`: containers of shared opaque callbacks accepted; shared start, escapes, captured readers, duplicate positions, capture after append and nested captured writes rejected. List focus projects the selected container; dictionary keys/tree representatives are outside scope. |
| `ownership/Prepend`, `MaybeDefault`, `ResultDefault` | Copying prepend reads the base; map/default are exclusive integer-branch arms. Eager edits and a later default read reject. No re-cons backing view, Maybe/Result constructor or early-return lowering is tested. |
| `build/bad/direct/ConduitArticleErrors`, `ConduitHomeFeedErrors`, `ConduitProfileErrors`, `ConduitProfileFeedErrors`, `ConduitRetainedMarkup`, `ConduitCarriedHandler`, `ConduitWrappedMarkup` | `markup` over render/event positional slots at depths 0–3: render-only projection accepted; general alias and retained event-handler writes rejected. No HTML syntax, component lowering, wildcard opaque carrier or renderer protocol is tested. |
| `ConduitDirectTagger`, `ConduitIdentityTagger` | `constructor`: zero-capture record constructor carried through a higher-order helper; scalar crosses, list argument retained. No sum-constructor lowering is tested. |
| `ConduitLambdaTagger`, `ConduitBoundTagger`, `ConduitPassedTagger` | `owned` with an unseen-callback helper or retained captured message: shared list and nonempty capture reject; captured scalar passes. `owned` is an identity runtime boundary with a demand, not an ownership permission. |
| `ConduitForwardedTagger` | An ordinary helper calls its callback and checks `owned` on its result while retaining the callback. List capture rejects; a fresh result passes and remains distinct across calls. The requirement is carried by ordinary guarded summaries/supplies, not a separate `need` row. |

The soundness statements still have the same three unproved obligations.
`CertifiedExclusive` and the falsifier now check both deep certificates and
container certificates: every directly selected element container occurs once
in the concrete whole-list footprint, while unrelated opaque captures may
repeat. The proof of the empty builder establishes both. The in-build replay
uses the authoritative audit's per-module boundaries to avoid Lean-generated
private-name normalization collisions; no constant or recursor is exempted.

The publishing-wrapper generator move now begins with a shallow input copy.
The two wrapper calls consequently have identical canonical certificates, so
the existing forwarded-guard hole cannot hide behind a changed capability
shape. Historical seeds still require their historical source revisions.

`earlierCapture` adds two certificate-only regressions: append a record whose
handler captures an earlier position's list, or focus a later position and
construct that handler in its replacement. Both are legal sharing constructions
and stay accepted. Before the certificate-transfer fix, their returned lists
advertised a spine certificate although the earlier container occurred twice
in the concrete footprint (`regressions/certificate-before-sync.log`). The
corrected checker loses that certificate, and the concrete final-heap checks
pass. `result-positions` reintroduces each false certificate, independently of
its existing observational disagreement probe. Every accepted fixed fixture
and corrected targeted program now checks concrete certificates.

The third `earlierCapture` variant supplies the earlier container as a fold
source element. The source and accumulator get distinct canonical parameter
names even though their actual paths alias. Its old-container owned premise
must be false; otherwise a new handler can capture the earlier position while
the result falsely advertises separation. The regression fails its concrete
certificate check before that premise is enforced
(`regressions/certificate-canonical-before-sync.log`). The `result-positions`
certificate probes cover all three variants.

## Shipping compiler differential bridge

[BRIDGE.md](BRIDGE.md) specifies the public-source translation and observation
boundary; [BRIDGE-RESULTS.md](BRIDGE-RESULTS.md) gives corrected per-construct and
per-family coverage for all fixed programs, bound 2, and 20,000 programs at each
of three seeds. Every translated program has a real browser-tea value check.
Direct library output remains persistent, so the 2,358 paired runtime agreements
do not confirm an in-place guarantee. Repeated closure-body keys, canonical
declaration failures and unvisited sites are unknown; source expressions with
multiple obligations are grouped. Typed minima preserve the rejection class,
and final-frontier skips and full-message changes are counted and retained.

Unused explicit capture slots are skipped, and field captures are snapshotted
without their ancestors and siblings. `regressions/bridge/` and the CI black-box
self-test cover those contracts and the previously swallowed batch failure.
No proof statement or shipping ownership rule was weakened.

## The keep edge and the `callbacks` limit — 2026-10-17 (#291)

`Fixtures.lean` ports `tests/corpus/ownership/CallbackKeeps.beni` (CK-251, the keep edge, #281, §16.4) and `CallbackChain.beni` (CK-249, the `callbacks` limit, #271, §16.7): 16 of the two files' 18 programs (`secondKeep` at both arms of its branch), plus three dropping-callback controls the files do not have (`dropFresh` for `kFresh`, `secondDrop` for `pickSecond`, `listDrop` for `inList`) and two read-only chains, 22 verdict fixtures, checked by both checkers and exported to the bridge with the suite. `keepCtor` and `keepOne` (a constructor of a custom type as the callback) are the only programs not ported: the core has no custom types; the record cases cover the same rule. **The keep edge needs no new rule in the core.** The core answers a callback's class facts at the call site (`callSymbolic` asks `aliases k p q`; `answer` follows the frames to the actual closure), so under a callback that returns its argument the kept result `t = f xs` holds `xs`'s cells inside the callee's own summary, and the callee's later write of `xs` fails the Dead test with `t` live. That is the Zig checker's rejection of `keepParam` (`supply`), `keepFresh` (`call`, in the callee), `wrapKeep` (`need`), `returnKeep`, `secondKeep` and `listKeep` (`alias`: the kept result holds the list `b`, which the caller writes directly, through the branch that chose it, or out of the returned list); `handKeep` fails the supply edge (`supply`: the second callback writes a supply that is not owned). The dropping callbacks are accepted. Two of the Zig checker's verdicts are approximations by the spec's own words, and the core, being context-sensitive, does not share them: `writeFirst` (the callee writes `xs` before the call and only reads it after: Zig rejects `supply`, approximately; the core accepts, and the two interpreters agree) and `kFresh` under a callback that drops its argument (Zig rejects `kFresh` itself; the core accepts). Both are precision differences, not unsafe programs; the bridge classifies a program the core accepts and Zig rejects as such. `keepCtor` and `keepOne` (a constructor as the callback, a custom recursive type) have no core syntax and are not ported; the record cases cover the same rule. The chain fixtures: `four` and `kept4` are refused by the precise rule (`later-use` and `alias` in Zig); `five` and `kept5` are the `callbacks` limit in both checkers and in Zig; a read-only chain of five (`chainRead 13`) is the limit too, where the precise rule would accept, and a read-only chain of four is accepted. The fixture suite is 133 original fixtures (98 before #291; #291 added 15, #305 13, the follow-up of their reviews 7).
## Function values in the open, unidentified callees, schema runs and carried lambdas — 2026-10-17 (#305)

Issue #305 asks whether the core states the rules of `ownership-checker.md` §30.9, §30.10, §30.11 and §24.9 and the entry projections of §20 and §22, and to port nine fixtures. The core is context-sensitive: a callback's class facts are answered at the call site (`callSymbolic`, `answer`), every function value it calls is a known closure or a symbolic input the frames resolve, and a function below a list or record path is the limit `function value below an input path`. That decides each group:

- **§30.9 rules 6–7 (`need`, a lambda's own parameter relied on).** Subsumed: a callee that writes what a function it is handed returns demands the result's cells, which the call site's class answers — the shared root's cell for `NeedLabels`' `exactShared`, the join of a fresh list and the shared root for `approxEntry`. Both are refused by the Unescaped test, as the goldens say (`need`, exactly and approximately). `approxElement` and `LambdaParamNeed` call a function taken out of a list or a record of pairs, the core's limit. The lambda-parameter case needs nothing of its own in the core, because the lambda's class is summarised where it is handed on.
- **§30.9 rule 9 (a top-level value that names a function, through at most eight names).** Not reachable by the core: it has no top-level values. The four alias-chain fixtures bind the aliases by `let` in `main`, so they compare *local* aliasing, which both checkers follow precisely through any number of names (the Zig checker refuses the local chains of one, seven, eight and nine as `later-use`, with no cap); the cap of eight and the `⊤call` past it are never compared, and the corpus's `eight` and `nine` are refused there only through the module's `pending`.
- **§30.9 rule 11 (exact and approximate labels).** Diagnostics; the core has no labels.
- **§30.9 rules 1–2, 5, 8 and §24.9 (slots and lambdas).** The core carries closure values with their classes; a lambda that captures a function parameter is a limit (`capture affinity conditional on a function parameter`), so `RandomGenerate`'s carried generator lambda is outside the core, as are `Random`, `Cmd` and the entry's taggers (rule 10).
- **§30.11 (`⊤call`).** The core has no function it cannot identify, so it never reached §30.11's hole and cannot state the rule. The owner decided on 2026-10-17 (Cesar, dashboard `ownership-proofs-q6`) to record the gap here and in §26.7 rather than add an opaque function value to the core; the rule stays with the Zig fixtures. `UnknownCallee`'s `apply`, `make` and local-lambda shapes are decided precisely (the shared root refused, the fresh lists accepted); the ports `sharedThroughApply` and `sharedLocalLambda` are the core's analogues of its `badParam` and `badNamed`, not the programs (which take the function out of a list the declaration is handed, or call a top-level value). A function taken out of a local list of closures is identified by both checkers (`listOfFns`, accepted; the bridge agrees). Zig's `⊤call` arises for a list of functions a declaration is handed, which is the core's limit `function value below an input path`; its `Dict` and record-field shapes are outside the core.
- **§30.10 (what a schema's run answers)**, `SchemaAnswers`, `SchemaConversionTwice`, `HostValueOnePlace`: no schema in the core; nothing to state.
- **Entry projections (§20, §22).** `entry` models one initialization and the model updates with retained callback environments (§26.7's row); the renderer, effects and unbounded event delivery stay outside by design.

The portable shapes are verdict fixtures (`Fixtures.lean`, 13 fixtures appended after the bridge's fixed prefix), checked by both checkers and exported to the bridge: the local alias chains of one, seven, eight and nine names refused (the written list is read again, and the two runs differ), `exactShared`, both arms of `approxEntry`, `sharedLocalLambda` and `sharedThroughApply` refused (`Unescaped: shared cell`), `freshOnly`, `goodCall`, `goodParam` and `listOfFns` accepted, both checkers agreeing on every one.

## Result, recursive payload and initialization coverage — 2026-10-15

The newer executable set has 98 original plus 78 sync verdict fixtures and
508 targeted programs. The historical 348 programs retain their indices; 160
new targeted programs append to them. Historical sync fixture indices also
remain unchanged. Current counts and evidence are in RESULTS.md.

| Rule | Fixture / control | Boundary |
|---|---|---|
| Arm and block terminal result reads | `resultRead` / `arm-result`, `block-result` | Old terminal holders stay live across an earlier write; distinct-holder twins pass. Existing mutually exclusive branch twins still pass. |
| Capture creation reads | `resultRead` / `capture-read` | A later reader closure keeps its captured outer path live. |
| Recursive capture provenance | `recursiveResult` / `recursive-capture` | Recursive result substitution keeps the canonical environment and its captured write/once obligations. |
| Callee environment disjointness | `calleeEnvironment` / `callee-capture` | A written argument is checked against the callee's actual captures; a distinct capture passes. |
| Fold loan lifetime | `feedbackLoan` / `fold-loan` | An accumulator borrowed from a repeated source position must not be treated as an unconditional exclusive loan. |
| `?` / Result error return | `question`, `twoFrames`, `recursiveQuestion` / `early-err` | Typed sums and actual CPS question lowering; nested operand case, inner-vs-outer definition, recursive Result fixpoint, both runtime arms. Expected values are asserted independently of interpreter equality. The shipping bridge emits actual `?`. |
| Recursive types | `recursiveData`, `recursiveConsumer` / `recursive-payload` | Unbounded `Chain a = End | Link a (Chain a)`, list-bearing recursive payload retention, distinct payloads, recursive tail consumer. Native recursive ADT in the bridge. Arbitrary/mutually recursive type declarations and dictionary representatives remain outside this projection. |
| Init transfer and captured locals | `initialization` / `init-shared`, `init-retained` | Init-only local/private roots pass; exported/shared roots and retained direct or helper-returned reader environments fail. Runtime entry projections remain explicit bridge skips. |
| Init authority lifetime | `initializationRepublished` / `init-authority` | A subsequent module entry cannot clear a new publication using a previous entry's spent private-transfer authority. |
| Init authority frame | `initializationFrame` / `init-frame` | A callee's summary cannot borrow pending module authority, even when its allocation has the same relative site. The unescaped local-allocation twin passes. |
| Direct initializer reads | `initializationLoop` and direct-read guards | A free read in a traversal/focus/runtime-entry body is ineligible even with one syntactic occurrence. Repeated stored payloads reject; freshly allocated payloads pass. Direct source operands remain eligible. |
| Function-valued private sources | `initializationFunctionRoot` | A function-bearing private value stays shared under #116's explicit backstop; a copied returned spine remains writable. |

All twelve new holes are required twice: the fixed typed witness must be refused
by the corrected checker and accepted with a disagreeing trace under the hole;
the finite targeted product must independently find an accepted disagreement.
The counts never treat an interpreter error, a typing error or an ordinary
rejection as a caught hole. The baseline target campaign checks concrete result
certificates as well as observations. No additional unproved statement was added.

The bridge's Result-case RHS regression executes the actual emitted program:
it must bind the inner Err and still return Ok 99. With the tail guard absent
it returns Err 7, which fails the value check; the restored translator passes.
`initializationDuplicatedCapture` also rejects a closure returning the same
captured row in both model fields; the copied-result twin passes. Initialization
coverage is confined to the Lean model, since entry/private-root programs remain
explicit shipping-bridge skips. The zero-confirmed count covers the translated
common subset, not initialization transfer. The historical fixed-stream pin has
independent source/verdict/order/removal controls in the bridge CI self-test.
