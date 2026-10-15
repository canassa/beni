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

Current [Result/recursive-payload/initialization results](ORACLE-EXTENSION-RESULTS.md)
and the earlier source-mutant matrix are indexed in [RESULTS.md](RESULTS.md).
The shipping-compiler differential bridge, counted skips, runtime boundary and
commands are specified in [BRIDGE.md](BRIDGE.md); `ownership ci` includes its bounded run.
[BRIDGE-RESULTS.md](BRIDGE-RESULTS.md) records the corrected 116,456-input campaign
and the oracle triage: 201 original divergences in six Zig defect clusters and
2,157 Lean precision leads. Every original and old minimum has both interpreter
traces in `evidence/bridge-triage/`; the persistent emitted runtime is not the judge.
The oracle has 98 original and 75 sync verdict fixtures, generator v5, a bounded-exhaustive
grammar plus 496 targeted programs, required negative controls (including `set-exclusive` and `once-live`),
and a falsifier that fails when summary coverage is excessively vacuous.
The sync models branch-local escapes, inductive model/container conditions,
fold accumulators, markup event slots, constructor callbacks and returns-owned
tagger obligations. Twenty-two holes are required through the seed-independent
targeted enumerator, including the retained-reader-after-append hole. The
case-lowered withDefault rule also has a required `branch-live` witness.
The §29 result/capture/fold/callee rules have six independent required holes. Six further holes cover
Err payloads, recursive payloads, shared initialization, retained entry captures and repeated transfer authority. Result and Chain
fixtures cross the shipping bridge; entry projections remain counted skips. `Sync.lean` and DESIGN.md
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
the seed-independent grammar (default bound 2) and all 496 targeted programs, saving per-seed counts, logs
and original counterexamples under `regressions/mutant-evidence/`. Run it on
Linux inside the ownership shell, which supplies Node 24 and taskset; `MUTANT_CORES` defaults to
`0-7` and refuses more than eight CPUs. `ENUMERATE_BOUND` sets the bound.

Lean **4.29.1** is pinned by `lean-toolchain` and locked nixpkgs; no Mathlib,
no network, no paid service. The Lean project is outside the Zig gates. The bridge invokes `zorg build`;
the ownership shell supplies pinned Zorg on Linux and Apple Silicon (Intel
macOS requires `zorg` on PATH).

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
| `Generator.lean` | the general generator: v4's chains of moves, and v5's conditional arms and generated declaration tables |
| `Oracle.lean`, `OracleLegacy.lean` | template families, generator versions 1–5, campaigns, shrinking, controls, distinct and precision counts |
| `Aliasing.lean` | a campaign metric: does an accepted program write an array two names reach |
| `Fixtures.lean`, `GeneratedRegressions.lean`, `Smoke.lean` | verdict fixtures, frozen regressions, negative-control probes |
| `HeapProof.lean`, `BuilderProof.lean`, `KernelChecks.lean` | concrete heap and builder/close proofs, kernel checks |
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
statements are about programs the corrected checker accepts
(`check p = .ok _`).

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
initialization/retained-entry projection are modelled. Arbitrary user-defined or mutually recursive type
declarations, list views, dictionaries, sets, opaque types, release representations, implicit evidence,
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
