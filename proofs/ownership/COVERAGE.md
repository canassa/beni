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

The fixed suite has 78 intended verdict tests (74 transcribed, plus the recursion-in-a-step finding, the three-row T46 variant, and the env-through-a-wrapper fixture with its rejected reverse), checked by both checkers. Each independently typechecks;
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
pairs. About half of the accepted programs write an array that two names
reach.

**Controls.** Every required control has a fixed probe that disagrees under
its mutant and is rejected without it, and the generator alone catches it
in one 20000-trial campaign on each of seeds 20261011, 17 and 271828;
`ownership ci` requires both. Required: the two historical controls and
seventeen flags (disjoint, traversal-exclusive, many-calls, copy-exclusive,
close-source, keeps-shape, guard-reuse, callback-xres, supply-edge,
supply-recheck, calls-edge, callback-writes, callback-aliases, callback-env,
once-through-call, branch-live; borrowed-supply against the per-call
checker). callback-escapes is caught on 2 seeds of 3 and forward-guards on
none; both are required through their probe only. Of the source-level
edits (`scripts/mutate.mjs`), the generator catches 26 of 43 on all three
seeds (including six of the second review's nine) and two more on two
(callbackescapes, and recwritesown, which removes a mask);
RESULTS.md has every index.

**Rows exercised.** `withWrites` counts executions, not which rows a write
depends on. The checker records the rows each check exercised; over the
accepted programs that write (three seeds, RESULTS.md): callback W 1214,
callback argument in res 2420, env in res 279, fresh in res 2063, xres yes
4211 / no 75, E on a callback argument 162, xreq on one 187 and its edge
187, guards forwarded and supplies transferred to the caller's input 194
each, supply owned bit cleared at a step end 323 and at the caller 770, a
summary reused after re-asking its guards 856. Never hit: ⊤ in a callback's
res, E on a callback's environment.

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

## Known gaps

Holes no generated program distinguished in 3 × 20000 v5 trials. For each,
either what would reach it, or why we believe no program can (an argument,
not a proof).

| Mutant | What it weakens | Evidence | Analysis |
|---|---|---|---|
| `recwrites` (review) | a recursive call's W rows are not demanded at the call | probe `Rec` still rejected under it, by "recursive call does not preserve entry ownership assumptions"; 0/3 seeds | **Masked.** A recursive call re-checks that every input path owned at entry is still owned at the call (`canonicalOwned`: individually owned, not live later, not another operand's) — the same Unescaped/Dead/Disjoint test the W demand makes. A W row the summary publishes on a path not owned at entry is demanded at the outermost caller, whose canonical-ownership test of that same actual failed for the same reasons, so the program is rejected there. Removing both rules (`recwritesown`) is caught on 2 seeds of 3 (2717, 1176), so the generator does reach recursive writes. |
| `symenv` (review) | a callback's own environment is not an "other operand" when its supplies are marked owned | probe `SymEnv` still rejected under it, by "supply edge"; 0/3 | **Masked.** Every supply is re-checked where its call is known (`recheckSupplies` at `callKnown`, against `otherPaths`, which include the callback's capture paths), so a supplied argument that the callback's environment also holds loses its owned bit there and the W ⇒ owned edge rejects. The summary-side test is redundant with that re-check, which `supply-recheck` (caught 3/3) controls. |
| `keepsany` (review) | focus keeps exclusivity when the result's paths name *any* parameter path | 0/3; no hand-written program found | **Argued equivalent.** A focus scope has one parameter (the element), so the weakened test accepts a result whose path `p` holds the element's cells from another path `q` of the same type: a permutation of the element's own arrays (e.g. swapping two list fields of a record). `keepsShape` still requires the result deep-exclusive and its paths separated, so no array repeats inside it, and the arrays all came from the replaced element, so none is shared with another position. A later consuming focus meets the joined element, whose fields now name both origins, and fails separation. |
| `forward-guards` (flag) | a callee's guards on our input are not re-asked | probe only; v4 caught it on 1 seed, v5 changes no verdict in 20000 trials (row hit 194 times) | reached by `mapVia` publishing a row in v4; v5 dilutes those programs. A wrapper whose callee's cached summary is reused for a callback of a different class |
| `callback-requires`, `requires-edge` (flags) | a callback's xreq not published / xreq ⇒ exclusive supply unchecked | change no verdict (xreq rows hit 187 times) | the published xreq and the edge reject the same programs; reaching either alone needs a callback requiring exclusivity of an argument whose outside holders only the caller sees, with the other also weakened |
| `transfer-supplies` (flag) | a callee's supplies to our own input dropped | changes no verdict (194 hits) | a wrapper whose callee supplies a borrowed cell to the forwarded callback, observable only through the edge (forwarded W guards already cover the callee's writes) |
| `borrowedsupply` (source) | borrowed source elements dropped from a step's re-check | 0/3 under summaries; caught under the per-call checker | see "Borrowed supply under summaries" |
| source `xres`, `once`, `nestedsep`, `reqexcloutside`, `recvalidate`, `tsupplyexcl`, `escapeowned` | the first review's other seven | 0/3 under v4 and v5 | `xres`/`nestedsep`: storing a non-exclusive nested value into a three-level container and consuming two levels down; `once`: a once closure called twice where the creation demand does not already reject; `recvalidate`: recursion whose candidate changes in the last round; the rest: not analysed |

## Summary layer: rows and their controls

| Row (§3.7) | Implementation | Required control | Caught by |
|---|---|---|---|
| use W through a callback | `consumes` from `W∈use_g(k,p)` guards | `--mutant=callback-writes` | probe; generator 3/3 |
| use E through a callback | escapes from `E∈use_g(k,p)` | `--mutant=callback-escapes` | probe; generator 2/3 |
| res, A | result built from `π_k.p∈res(q)`, `env∈res(q)`, fresh, shared, ⊤ guards | `--mutant=callback-aliases`, `--mutant=callback-env` | probe; generator 3/3 |
| forwarding | a callee's guards on our input re-asked as ours | `--mutant=forward-guards` | probe; generator 0/3 (v4: 1/3) |
| xres | `xres(q)` guards | `--mutant=callback-xres` | probe; generator 3/3 |
| supply owned | demand test at the call, re-checked where the scope ends and at the caller | `--mutant=supply-recheck` | probe; generator 3/3 |
| edge W ⇒ owned | at a call that knows the callback | `--mutant=supply-edge` | probe; generator 3/3 |
| calls, edge once ⇒ ≤1 | counted per slot, many in a step or recursion | `--mutant=calls-edge` | probe; generator 3/3 |
| once consumed at a callee's call | a once function actual the callee calls is demanded, with its written captures | `--mutant=once-through-call` | probes; generator 3/3 |
| guards | cache reused only where every guard answers the same | `--mutant=guard-reuse` | probe; generator 3/3 |
| xreq, edge xreq ⇒ exclusive | published xreq, and checked at a call that knows the callback | `callback-requires`, `requires-edge` | known gaps (hit 187 times, no verdict change) |
| supply transfer | a callee's supplies to our input become ours | `transfer-supplies` | known gap (hit 194 times, no verdict change) |
| need | not a separate row | — | — |

Liveness has its own required control, `--mutant=branch-live` (a
conditional's nonzero arm contributes no uses; the second review's
`branchlive`): probe, generator 3/3.

## Borrowed supply under summaries

The review's `borrowed-supply` mutant drops the borrowed source's elements
from the holders a non-consuming traversal re-checks its step's writes and
supplies against. In the per-call checker it is load-bearing, and the
generator catches it (first indices 182–830 under v5; 249–1692 under v4). Under summaries the line is
**live**: `ownership verdict-diff --mutant=borrowed-supply` shows it rejects
33, 40 and 35 programs per 20000 v5 trials (seeds 20261011, 17, 271828; 21, 28, 17 under v4) that its
removal would accept, and none of those disagree when run. A typical one folds
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
   origin could be written through a root demand;
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
* `WellTyped`: the expression is ordinarily typed in a typing of the
  environment its values have. Without it a branch whose arms have different
  shapes joins to an unknown list with no element cells, which describes
  nothing (the falsifier found this through a mistyped generator);
* `HonestClosures`: a function value described as not once (no roots) is one
  the checker itself would create as not once (re-creating it from its
  abstract captures gives no roots). A writing closure described as not once
  is one no program builds, and with it the statement is false (falsifier).

`summary_sound` (and `map_summary_sound`) were restated too:

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
  of 64 is replaced by the relational `AtPath`, so no claim stops at a depth.

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
  mentions) and checked against every clause.
* **`summary_sound` / `map_summary_sound`**: every call made while running the
  accepted programs of a generated campaign, against every published summary
  of the called declaration whose hypotheses the call meets under the
  canonical naming (each canonical origin names the arrays at its path),
  guards resolved with abstract closures built from the actual ones.

What it found, in order: the review's counterexample (on the earlier
statement), dishonest closures, ill-typed expressions, `env` paths of known
function values (`namesAt`), and, on the corrected statement, **the second
checker defect below**. After the fixes, on 100 000 configurations and the
calls of 100 000 generated programs per seed:

| Seed | Step configurations | Accepted | Accepted with a write | Failures | Calls checked against a summary | of which map | Vacuous | Failures |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 20261011 | 100 000 | 83 577 | 5 155 | 0 | 64 827 | 5 055 | 28 875 | 0 |
| 17 | 100 000 | 83 539 | 4 993 | 0 | 65 001 | 5 182 | 28 715 | 0 |
| 271828 | 100 000 | 83 649 | 5 255 | 0 | 65 031 | 5 096 | 28 862 | 0 |

The falsifier has teeth: under `--mutant=` holes the step-lemma check fails
(20 000 configurations, seed 17): disjoint 2, once-through-call 161,
keeps-shape 1, close-source 209 failures. It does not see copy-exclusive or
many-calls at this size. The Lemma 6.7 check, over the summaries a mutated
checker publishes (20 000 programs, seed 17), reports callback-writes 721,
callback-aliases 466, callback-xres 323 and callback-escapes 69 violations,
and none under guard-reuse (a reused summary is wrong at the call that reuses
it, which the step lemma, not Lemma 6.7, sees). A clean run is evidence, not proof; the
configurations are small and the summary check sees only calls the
generator makes.

### Defects the restatement found (both fixed, both fixtures)

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

The generator never built either shape; the `once-through-call` control is
reported, and required once the generator reaches it.


`Axioms.lean` is the `AxiomCheck` target of `lake build`. It collects the
axioms of **every constant** declared in an `Ownership` module (2 644 at the
time of writing: theorems, definitions, instances, structures and their
generated auxiliaries, not only the theorems) and fails unless exactly the
three `sorry`s above and the main theorem depend on `sorryAx` and nothing uses
an axiom beyond `propext`, `Classical.choice` and `Quot.sound`. An `example`
adds no constant, so it also scans the source of every module, outside
comments and strings: exactly three `sorry` tokens, and no `admit`,
`native_decide` or `axiom`. Checked on a scratch copy: adding
`def x : 1 + 1 = 3 := sorry`, `example : 1 + 1 = 3 := sorry`, an
`instance … := sorry` or `example … := by native_decide` each fails
`lake build`. No axiom is declared. All statements take `check p = .ok _`
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
