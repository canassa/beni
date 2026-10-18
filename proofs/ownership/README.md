# Ownership oracle

An executable Lean 4 core of the ownership thesis (`docs/thesis/ownership/`):
a typed ANF language, a value interpreter and an in-place interpreter, an
ownership checker built on the thesis's per-function summaries, a differential
oracle that runs every accepted generated program in both interpreters, and
proofs about the builder primitives plus the statements of the soundness
argument. This is **not a certified ownership checker**: of the soundness
statements three are `sorry` and the main theorem is proved only from one of
them. It does not change the beni compiler
or the thesis.

[Enumerator and diagnostic evidence](evidence/enumerator-links/README.md) records the 2026-10-16 finite checks.
[Constructions, views and the function-valued skip](CONSTRUCTIONS-RESULTS.md) records the 2026-10-15 results.
Those results include one confirmed shipping defect in `tests/pending/`.
[Result/recursive-payload/initialization results](ORACLE-EXTENSION-RESULTS.md)
and the earlier source-mutant matrix are indexed in [RESULTS.md](RESULTS.md).
The shipping-compiler differential bridge, counted skips, runtime boundary and
commands are specified in [BRIDGE.md](BRIDGE.md); `ownership ci` includes its bounded run.
[BRIDGE-RESULTS.md](BRIDGE-RESULTS.md) records the corrected 116,456-input campaign
and the oracle triage: 201 original divergences in six Zig defect clusters and
2,157 Lean precision leads. Every original and old minimum has both interpreter
traces in `evidence/bridge-triage/`; the persistent emitted runtime is not the judge.
The oracle has 133 original and 99 sync verdict fixtures, generators v5 and v6, a bounded-exhaustive
grammar plus 740 targeted programs, required negative controls (including `set-exclusive` and `once-live`),
and a falsifier that fails when summary coverage is excessively vacuous.
The sync models branch-local escapes, inductive model/container conditions,
fold accumulators, markup event slots, constructor callbacks and returns-owned
tagger obligations. Twenty-two holes are required through the seed-independent
targeted enumerator, including the retained-reader-after-append hole. The
case-lowered withDefault rule also has a required `branch-live` witness.
The §29 result/capture/fold/callee rules have six independent required holes. Six further holes cover
Err payloads, recursive payloads, shared initialization, retained entry captures,
repeated transfer authority and its frame boundary. Two more (`construct-disjoint`,
`view-alias`) cover constructions and list views. Result, Chain, construction and view fixtures
cross the shipping bridge; entry projections remain counted skips. `Sync.lean` and DESIGN.md
state the projections and their runtime boundaries.
`no-scope` is a checker-level probe: typed programs cannot reach an unbound
live variable. `hiddencopy` changes the interpreter to copy on every write;
value and in-place results then agree, so fixtures checking the intended
in-place observations, rather than differential campaigns, expose it.
The third search gap, `keepsep`, needs a focused list of records with two list
fields and concrete certificate checking; its written probe is in COVERAGE.md.
Finite campaigns and the small enumeration grammar are evidence, not proofs.

## Run

From the repository root:

```sh
nix develop .#ownership
cd proofs/ownership
lake build                                   # executable, kernel-checked library, axiom audit
lake exe ownership ci                        # fixtures and probes, one campaign (≥ 30 % write), every required control caught by the generator or targeted enumerator
lake exe ownership fixtures
node scripts/bridge-triage.mjs                # original leads and minima in both Lean interpreters
lake exe ownership oracle 20000 17           # one campaign (summary checker)
lake exe ownership oracle 20000 17 --cross-check   # also run the per-call checker
lake exe ownership oracle 20000 17 --reinfer       # the per-call checker alone
lake exe ownership controls 20000 17         # every negative control, generator alone
lake exe ownership verdict-diff 20000 17 --mutant=borrowed-supply   # verdicts a hole changes
lake exe ownership enumerate-targeted          # bounded capture/count/join/set/comparison/recursion templates
lake exe ownership enumerate 2                  # every program of the bounded grammar
lake exe ownership enumerate 3 --count-only     # size of the next bound (does not check it)
lake exe ownership oracle 20000 17 --mutant=supply-edge
lake exe ownership summaries --fixture="T43" # print published summaries
lake exe ownership reasons 20000 17 --family=general   # rejection reasons
lake env lean Axioms.lean                    # print the in-build axiom audit again
scripts/audit.sh                             # the authoritative audit: clean checkout, Lean parser, kernel replay
lake exe ownership falsify 100000 17         # try to falsify the unproved statements
```

Counts and seeds are deterministic. Generator v5 is the default: three
quarters of its programs come from the general generator, 19 of every 33
of those after generating a table of declarations of their own (RESULTS.md).
`--generator-version=4` selects the older v4 families, `--generator-version=3` the v3
families (both use the current declaration table; exact historical streams require
their historical git revisions), `--generator-version=1` the frozen legacy one. A corrected-rule
accepted disagreement, ill-typed generated program or execution error fails a
run and is shrunk into `regressions/`. A negative control succeeds only if it
finds an accepted disagreement whose shrunk form the corrected checker
rejects. `scripts/run-mutants.sh` applies source-level checker edits
(`scripts/mutate.mjs`) and compares every verdict on each seeded stream with
indices from the unedited build (`ownership source-sweep`). It also enumerates
the seed-independent grammar (default bound 2) and all 740 targeted programs, saving per-seed counts, logs
and original counterexamples under `regressions/mutant-evidence/`. Run it on
Linux inside the ownership shell, which supplies Node 24 and taskset; `MUTANT_CORES` defaults to
`0-7` and refuses more than eight CPUs. `ENUMERATE_BOUND` sets the bound.

Lean **4.29.1** is pinned by `lean-toolchain` and locked nixpkgs; no Mathlib,
no network, no paid service. The Lean project is outside the Zig gates. The bridge invokes `zorg build`;
the ownership shell supplies pinned Zorg on Linux and Apple Silicon (Intel
macOS requires `zorg` on PATH).

## CI

The job `lean` of `.github/workflows/ci.yml` checks the proofs.
The guard `check` needs this job, so a failed proof blocks a merge.

- The job runs `scripts/audit.sh HEAD`, then `lake build`, in `nix develop .#ownership`.
  The audit runs first. Its source scan rejects `#eval` and the other banned commands before any audited code runs.
  An `#eval` in an audited module runs during `lake build` and can rewrite the audit files.
  After `lake build`, the job fails when the build changed or added a file that git does not ignore.
- On a push to `master`, and on a pull request whose base is not `master`, the job always runs these steps.
- On a pull request to `master`, the job runs them only when the pull request changes `proofs/ownership/`, `flake.nix`, `flake.lock`, `.github/workflows/ci.yml` or a `.gitattributes` file.
  For another pull request, the job skips the steps and passes.
- The job runs the audit files of the pull request itself: `Axioms.lean`, `Audit.lean`, `scripts/audit.sh`, `lakefile.toml`, `flake.nix` and the workflow.
  Thus a pull request that weakens them passes its own weaker audit, and the job does not catch it.
  #263 adds `.github/CODEOWNERS`, which names `@canassa` for these files.
  When the ruleset on `master` requires a review from code owners, a change to them needs the owner's review.
- An `export-ignore` in a `.gitattributes` file removes a file from the export of `scripts/audit.sh` (#262).
- The job restores `.lake` from the newest build on `master`.
  Lake builds a module again when the hash of its source, its imports, its options or Lean's commit changes.
- With a restored `.lake`, `lake build` does not run the source scan of `Axioms.lean` again when only a file outside its imports changes.
  For example, a new `sorry` in `Triage.lean` passes a warm `lake build`.
  `scripts/audit.sh` does not read `.lake`: it builds a clean export and scans every source, so CI catches that `sorry`.
- The job does not run `lake exe ownership ci` (#259).
  The bridge of that command builds the beni compiler, so it depends on `src/` too.
- On a GitHub runner, a cold run of the job took 9 to 14 minutes.
  `lake build` took 184 to 310 s, and `scripts/audit.sh` took 257 to 428 s.
- A restored `.lake` makes only `lake build` faster.
  The audit always builds from nothing, so its time does not change.
  Two warm runs took 7 min 45 s and 8 min 14 s: `lake build` took 1 s, and the audit took 410 s and 434 s.

## Audit memory and replay

Run audit commands from `proofs/ownership` inside the ownership shell.
The source scanners use the current directory. The in-build audit uses `.lake/build/bin/audit`.
Lake builds that executable before `AxiomCheck`.
Lake also restores cached artifacts locally, so child imports use the same module files.

Lean's imported compacted regions do not use ordinary reference counts.
The audits keep global axiom and compiler-attribute checks in the parent.
They replay each complete module in a sequential child with a fresh environment for its declared imports.
Every child checks the same declarations and regenerated recursors.
The parent requires an exact module/count receipt.
Process exit releases the child's imported regions.
The source, axiom, pinned-`sorry`, compiler-attribute, recursor, and kernel checks remain mandatory.

Before delegation, both audits reject duplicate declarations that involve audited modules.
This guard addresses the replacement-body risk in [#182](https://github.com/canassa/beni/issues/182).
Its independent-module regressions and remaining acceptance work remain open.
The memory repair addresses [#160](https://github.com/canassa/beni/issues/160).
A local build replayed all 4,842 constants under `MemoryMax=10G` and `MemorySwapMax=2G`.
Its scope reported a 3.7 GiB memory peak and a 345.1 MiB swap peak.
The expanded enumerator build now passes with 7,142 kernel replays across 74 jobs.
The complete independent audit remains a separate publication check. The PR records its result.
The complete independent audit remains mandatory and also checks the modules that `Main` imports.
Keep the shared lock and memory caps for every heavy check.

If any audit step fails or stops, `scripts/audit.sh` keeps its work directory and logs.
It removes them only after complete success. This fixes [#242](https://github.com/canassa/beni/issues/242).

After `lake build`, run the audit controls from this directory.
Start only with at least 6 GB of available memory.

```sh
free -g
flock /home/jayson/.local/state/beni-dispatch/heavy.lock \
  systemd-run --user --scope --quiet \
  -p MemoryMax=10G -p MemorySwapMax=2G -- \
  nix develop ../..#ownership --command bash scripts/audit-controls.sh
```

The suite checks one successful module receipt and seven negative controls.
It checks the module allowlist, both duplicate guards, both child-error paths, and both wrong-receipt paths.
It keeps sources, command arguments, checksums, and logs under `zig-out/scratch/audit-negative.*`.
The independent wrong-receipt control copies `Audit.lean` into that directory.
It replaces only the CLI `main` with a test dispatcher.
The real `Audit.checkModuleChild` body remains unchanged.
The dispatcher returns a wrong receipt with exit zero in child mode.
The parent mode calls the real helper and requires its refusal.
The native build uses the audit's recorded compiler and linker arguments.
It refuses unfamiliar trace formats or ambiguous paths.

## Opt-in write diagnostics

Run this mode from `proofs/ownership`.
The command checks available memory after it takes the shared lock.
It starts only with at least 6 GB available and keeps both memory caps:

```sh
flock /home/jayson/.local/state/beni-dispatch/heavy.lock \
  systemd-run --user --scope --quiet \
  -p MemoryMax=10G -p MemorySwapMax=2G -- \
  bash -eu -c '
    free -g
    available_gb=$(free -g | awk "/^Mem:/ {print \$7}")
    if test "$available_gb" -lt 6; then
      printf "%s\n" "Less than 6 GB available; command did not start." >&2
      exit 75
    fi
    exec "$@"
  ' bash nix develop ../..#ownership --command \
  lake exe ownership diagnostics 20000 20261011 --enumerate-bound=2 \
  --out=../../zig-out/scratch/ownership-diagnostics.log
```

The mode runs fixtures, the complete bounded grammar, and generators v5 and v6 at three seeds.
Grammar version 2 contains 105,150 programs at bound 2 and 200 at bound 1.
The added construction and view templates change flattened enumeration identifiers.
Keep the grammar version with every identifier and result.

The q1 check follows Cesar's q4 decision.
It inspects every attempted write in main expressions and nested calls.
It reports a hit when a protected reader reaches a distinct member of the receiver's linked storage component.
Protected readers include outer continuations, permanent observers, loop readers, and unfinished operands.
Continuation atom uses define the live paths. The diagnostic follows their reachable cells in the current heap at each write.
Live closure values contribute their captures. Explicit capture atom uses also contribute readers.
Traversal readers pin outer values before iteration; their heap reachability remains current at each write.
An eventual return adds no separate pre-existing observer.
Intercepted writes preserve `State.links`. Only `.view` adds links.
Read-only view/source splits remain legal.
The conservative check also reports no-op writes and writes that leave the counterpart unchanged.
Classify each hit before calling it a checker defect.

The q2 check scans canonical write and consume paths across every same-declaration cache candidate for each actual call.
It reports raw observer hits separately from the subset whose complete public premises match under selected witnesses.
That subset uses one canonical naming and one chosen closure-class interpretation.
A failed chosen witness does not exclude every possible theorem instance.
Cache presence alone proves neither actual-call admissibility nor complete effect coverage.
Matched demand counts expose an empty matched subset.
Linked-demand and observed-demand counts expose narrower coverage gaps.
Permanent-registration counts require a nonempty pre-call `kept` array; they do not require overlap with a written or consumed target.
Direct and linked observer-hit counts record that overlap separately.

The mode checks input and observer references for dangling addresses.
It counts failed executions, failed snapshots, unsupported reader contexts, and incomplete scans explicitly.
An incomplete execution cannot contribute a clean result.
Every complete execution requires exact ordinary/diagnostic equality for results, runtime states, errors, remaining fuel, final snapshots, and traces.

The fresh capture completed 71,762 accepted runs across 226,103 program cases.
It found zero q1 hits, divergent states or traces, incomplete accepted runs, or dangling input or observer references.
The strict q2 result remains false: two raw direct-observer hits and zero matched direct or linked hits.
Those zero matched hits cover one canonical naming and one chosen closure-class interpretation, not every theorem instance.
The worker interprets the native records as unsuitable cache-summary matches. Both records show unchanged pre-existing observed arrays.
The run retains 7,656 unmatched calls and 10,336 unmatched candidates as explicit coverage limits.
The six matched read-only linked calls compare distinct canonical input slots.
The metric excludes linked paths within one slot.
It requires empty summary write and consume rows and zero callback call counts.
Its source and executable hashes stay equal before and after execution.
[Enumerator evidence](evidence/enumerator-links/README.md) keeps compressed raw records, local-run attestations, worker interpretations, and replay commands.
The hashes identify local execution records. They do not establish complete build reproducibility.
The fresh CI run passed, including its bounded compiler bridge.
The complete independent audit remains a separate publication check. The PR records its result.

The `Aliasing.lean` campaign metric lacks `.construct`, `.view`, `.prepend`, `.events`, and `.owned` cases.
[#243](https://github.com/canassa/beni/issues/243) tracks this limit. Do not quote that metric as complete v6 write coverage.
The write diagnostics count actual runtime write events.

## Modules

| File | Content |
|---|---|
| `Syntax.lean` | typed strict ANF, type checker |
| `Semantics.lean` | value and in-place interpreters, observations, write count |
| `Domain.lean` | abstract values (incl. `symbolic` function inputs), liveness, summaries, guards, supplies |
| `Config.lean` | checker configuration and the mutants |
| `Checker.lean` | the summary-layer checker (default) |
| `Reinfer.lean` | the frozen per-call re-inference checker (cross-check) |
| `Library.lean` | map, initialize, foldl, update as ordinary declarations |
| `Cli.lean` | validates command names, numbers and applicable options before work |
| `Question.lean` | typed CPS lowering of `?`, with one error return per definition |
| `Sync.lean` | Zig-fixture projections for branch, model, fold and Conduit rules, with required holes |
| `Targeted.lean` | finite products exercising capture consumption, call counts, shape joins, set, comparisons and recursion |
| `Enumerate.lean` | every typed program of a bounded grammar; independent of random seeds |
| `Generator.lean` | general generator: v4 move chains, v5 conditionals and declaration tables, and v6 constructions and views |
| `Oracle.lean`, `OracleLegacy.lean` | template families, generator versions 1–6, campaigns, shrinking, controls, distinct and precision counts |
| `Aliasing.lean` | a campaign metric: does an accepted program write an array two names reach |
| `Fixtures.lean`, `GeneratedRegressions.lean`, `Smoke.lean` | verdict fixtures, frozen regressions, negative-control probes |
| `HeapProof.lean`, `BuilderProof.lean`, `KernelChecks.lean` | concrete heap and builder/close proofs, kernel checks |
| `LinkedWriteFrame.lean` | conditional heap and observer frames for successful linked writes |
| `FlatFragment/` | the first flat fragment: the strengthened relation, its heap frame, the expression cases, and the trace corollary, in one import chain |
| `LinkClauses.lean` | the invariant's link clauses under allocation, nonempty writes and view creation, and the per-link closure that gives the naming clause |
| `StatementChecks/LinkSummary.lean` | the R1 witness, in allocation order: every old premise of `summary_sound` at a linked pre-state, the failed conclusion, and the new premise's refusal |
| `StatementChecks/LinkedCallControl.lean` | the control of the written-storage premise: every premise of `summary_sound` at a reachable call with a link |
| `CallDerivation.lean` | the written-storage premise at a first-order call without captures, from the call-site invariant and the call's demands |
| `StatementChecks/CallDerivationInstance.lean` | the derivation applied at a reachable call with a link: the call-site invariant and the real `applyCall` run |
| `LinkedWriteStep.lean` | the naming clause after a demand-guarded linked write, with the same naming, and the live cells below a live use's path |
| `LinkedWriteValid.lean` | the validity clauses, contents included, after a linked write that does not shorten the written array: the splice, the refresh and the forest order of the links |
| `StatementChecks/LinkedWriteInstance.lean` | the step lemma applied at a reachable state with two link components, with a conclusion that is not vacuous |
| `Soundness.lean` | the bridge to concrete heaps and the soundness statements |
| `Falsify.lean` | executes the unproved statements on concrete configurations (`ownership falsify`) |
| `Report.lean` | printing summaries |
| `Triage.lean` | replay original leads and minima through both interpreters, including complete traces |
| `Bridge.lean`, `BridgeWire.lean` | existing-stream export, typed reducer and data-only wire decoder |
| `scripts/bridge*.mjs` | public-source translation, shipping verdict/runtime comparison and isolated Zig controls |

[DESIGN.md](DESIGN.md) specifies the boundary and the summary layer;
[COVERAGE.md](COVERAGE.md) audits T1–T59, says what is and is not tested,
lists every theorem with its status and the thesis discrepancies found.

## Proof status

Proved without `sorry`: the builder/close contracts against the executable
primitives and the concrete heap lemmas (unchanged). Proved but **conditional
on a naming** of origins that nothing yet constructs: the soundness of the
checker's overlap and demand tests, and the abstract builder value describing
the concrete allocation. Closure descriptions agree recursively on code and
captures, including closures inside captured records and arrays. Bookkeeping: the invariant's base case, and that the
review's counterexample to the earlier invariant is excluded by the restated
one. The main theorem is proved only **conditionally** on the step lemma. All
public soundness statements concern programs that the corrected checker accepts
(`check p = .ok _`). The local runtime frame lemmas require no checker-acceptance premise.

[LinkedWriteFrame.lean](Ownership/LinkedWriteFrame.lean) proves a local frame for successful real `writeLinked` and `writeCounted` operations.
Every changed address belongs to the receiver's initial undirected link component.
The operations preserve links, permanent observer registrations, and heap lookups outside that component.
Complete finite representations outside the component retain their observations at the supplied snapshot depth.
The `writeLinked` corollaries cover individual values, value lists, snapshots, and all permanent observers.
The `writeCounted` corollary preserves an individual representation under the same separation premise.
The example changes a source and its view while an independent registered observer retains `[7]`.
These conditional lemmas establish no general execution success, checker permission, link validity, result correspondence, or certificate preservation.
They establish no `CallSound.noNewHolders` clause or complete expression-evaluation theorem.
All three general proof obligations remain open.

[FlatFragment/Trace.lean](Ownership/FlatFragment/Trace.lean) proves `accepted_flat_anf_traces_agree`: the main theorem's conclusion for every accepted program whose main expression is in the first flat fragment.
`FlatANF0` contains integer and variable atoms, `let`, integer list literals, `push`, `length`, `shared`, and, since 2026-10-18, the integer primitives `add`, `sub`, `eq` and `lt` on two atoms, which typing fixes to `Int` (`ScalarOp`).
The proof uses no `sorry` and none of the three pinned obligations.
The generic theorem `flat_preserved` carries the strengthened relation `FlatInvariant` through every fragment expression, in both runtime directions, from the actual acceptance, typing, and shadow runs.
The fragment excludes field atoms, calls, closures, views, constructions, branches, cases, and scopes. The three general obligations remain open.

`Invariant` carries two link clauses since 2026-10-16 (#169, owner decisions q1 and q4): every stored link is valid (`LinksValid`, with the view's contents since 2026-10-17), and linked storage that a live path or an observer protects is named as one array (`LinkNamed`).
[ViewLinks.lean](Ownership/StatementChecks/ViewLinks.lean) proves that the #169 pre-state admits no naming under them, that the same witness in allocation order fails `LinkNamed` alone, and checks that a builder's `put` leaves a garbage view stale, which is why the contents clause needs #284's hand-over, and that the program whose garbage view went stale that way is refused since `close` hands the builder over.
[LinkClauses.lean](Ownership/LinkClauses.lean) proves `LinksValid` with the same heap and links, after an allocation, after a `set!` of an array no link names and after a view; `LinkNamed` with the same heap, links and observers; and that a per-link closed naming (`LinkClosed`) gives `LinkNamed`. No theorem uses these lemmas yet.
[LinkedWriteInstance.lean](Ownership/StatementChecks/LinkedWriteInstance.lean) applies it at a reachable state with two link components. [LinkedWriteStep.lean](Ownership/LinkedWriteStep.lean) proves that the naming clause survives a successful demand-guarded linked write of a live receiver with the same naming, for the continuation's uses; [LinkedWriteValid.lean](Ownership/LinkedWriteValid.lean) proves `LinksValid`, its contents clause included, after a linked write that does not shorten the written array. Both clauses under a call remain open.
`summary_sound` and `map_summary_sound` carry the written-storage premise `LinkedWritesCovered` (R1): an input array a link connects to an input array at a permitted path is at a permitted path. [LinkSummary.lean](Ownership/StatementChecks/LinkSummary.lean) proves that the R1 pre-state fails it and that, without it, every other premise held there while the conclusion failed. [LinkedCallControl.lean](Ownership/StatementChecks/LinkedCallControl.lean) proves every premise at a reachable call with a link, where the write changes a dead source that no input holds. [CallDerivation.lean](Ownership/CallDerivation.lean) derives it at a first-order call without captures, from the call-site invariant and the call's own demands. [CallDerivationInstance.lean](Ownership/StatementChecks/CallDerivationInstance.lean) applies it at a reachable call with a link. Calls whose arguments are not all variables, calls with captures, calls with function-valued inputs, and the wiring from `inferExpr`'s `.app` case remain open.

`sorry`: `summary_sound` (Lemma 6.7 clauses 1–3, clause 2 as repaired in
round 5), `map_summary_sound`, `invariant_preserved` (the step case of the
prefix induction). All three were restated after the second review showed the
step lemma false as stated; COVERAGE.md says what each now claims, why it is
believed true, and what `ownership falsify` (random configurations for the
step lemma, every call of generated programs for Lemma 6.7) found — including
checker defects now fixed and the nested-capture regression. Lemma 6.7's clause 4 is not stated (the
interpreters do not record callback invocations). No axiom is declared;
`lake build` fails if the set of `sorry`-dependent constants changes, if the
kernel rejects any constant on replay, or if any `sorry` beyond the three
statements, `admit`, `native_decide`, `axiom`, `skipKernelTC`, `addDecl`,
`run_cmd`, `implemented_by` or `extern` appears in the sources
(`Axioms.lean`). The third review found two more ways the step lemma was
false (shadowing, which both checkers mishandled and the core now refuses;
an abstract environment that does not cover the live uses) and both are
fixed in the statement or the checker.

## Limits

Result constructors and elimination, definition-local `?` lowering, recursive `Chain` types, and an
initialization/retained-entry projection, constructions (`++`, spread literals) and list views are
modelled (DESIGN.md, last section). Arbitrary user-defined or mutually recursive type
declarations, `pop`/`swap`/`insertAt`/`removeAt`, dictionaries, sets, opaque types, release representations, implicit evidence,
effects, fibers, TEA and rendering remain outside the model. Chain tails copy their immutable spine;
payload cells retain their identities. Private initialization uses a deliberately narrow single-read
allocation/alias/capture chain; unsupported dependency graphs stay shared.
Mutual recursion, higher-order recursion, recursion inside a traversal or
focus step, function values below an input path and callbacks with
function-typed parameters or results are explicit `limit:` rejections.
Inference depth 200, fixpoint rounds 24, evaluation fuel 100 000 and snapshot
depth 256 fail explicitly. A finite campaign is neither exhaustive nor a proof.

Commands and flags are validated before work. Inapplicable options (including
`ci --mutant=...`), unknown modes, malformed numbers, a missing verdict-diff
mutant and zero-size falsification fail. CI retains original and shrunk
campaign witnesses plus failing fixture ASTs; failed audits retain the exported
work directory and logs. `scripts/campaigns.sh` publishes logs only when every
child succeeds. `nofix1` is an alias of `oncethroughcall`, counted once.

## The tree fragment and the level marker (2026-10-18)

`Ownership/Tree/` is a self-contained fragment for `ownership-checker.md` §16.7's level marker `⟨T⟩` (#379):
one recursive type `Tree = Leaf | Node Tree (List Int) Tree`, pairs, `List.push`, cases and calls of earlier declarations.
It has its own value and in-place interpreters and a path-based checker in `src/own/`'s shape: symbolic cells `param(j, q)` with
the marker's fold, overlap, holding and projection as §16.7's amendment states them, and the call-site condition between two
paths of one parameter. `lake exe ownership tree [depth nodes]` checks the fixtures and every program of a bounded product
(127,484 at the default 2, 3), and requires each of its four holes to be caught; `ownership ci` runs it.
`lake exe ownership tree-export [depth nodes] --out=DIR` writes the product as beni modules with the oracle's verdicts, and
`node scripts/tree-bridge.mjs --dir=DIR --compiler=/abs/beni` compares them declaration by declaration. COVERAGE.md has the results.
