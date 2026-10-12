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

Current state ([RESULTS.md](RESULTS.md)): 82 fixed verdict fixtures, checked by
both checkers; three 20 000-trial campaigns of generator v5 (which generates
declarations, recursion and closures of its own) with no corrected-rule
mismatch: 12 077 accepted programs, 8 718 of them distinct, 7 687 with an
in-place write, half of them writing an array two names reach; precision
62 % (accepted among programs whose two runs agree). Nineteen required
negative controls (two historical, the first review's seven, eight
summary-row mutants, `once-through-call` and `branch-live`) each have a
fixed probe, and the generator alone catches each of them on each of three
seeds (borrowed-supply only against the per-call checker); `ci` requires
both. Two more are required through their probe only; three are known gaps.
Of 43 source-level edits, including the second review's nine planted holes,
the generator catches 26 on all three seeds; the misses are analysed in
COVERAGE.md.

## Run

From the repository root:

```sh
nix develop .#ownership
cd proofs/ownership
lake build                                   # executable, kernel-checked library, axiom audit
lake exe ownership ci                        # fixtures and probes, one campaign (≥ 30 % write), every required control caught by the generator
lake exe ownership fixtures
lake exe ownership oracle 20000 17           # one campaign (summary checker)
lake exe ownership oracle 20000 17 --cross-check   # also run the per-call checker
lake exe ownership oracle 20000 17 --reinfer       # the per-call checker alone
lake exe ownership controls 20000 17         # every negative control, generator alone
lake exe ownership verdict-diff 20000 17 --mutant=borrowed-supply   # verdicts a hole changes
lake exe ownership oracle 20000 17 --mutant=supply-edge
lake exe ownership summaries --fixture="T43" # print published summaries
lake exe ownership reasons 20000 17 --family=general   # rejection reasons
lake env lean Axioms.lean                    # print the axiom audit again
lake exe ownership falsify 100000 17         # try to falsify the unproved statements
```

Counts and seeds are deterministic. Generator v5 is the default: three
quarters of its programs come from the general generator, 19 of every 33
of those after generating a table of declarations of their own (RESULTS.md).
`--generator-version=4` reproduces v4, `--generator-version=3` the v3
generator, `--generator-version=1` the frozen legacy one. A corrected-rule
accepted disagreement, ill-typed generated program or execution error fails a
run and is shrunk into `regressions/`. A negative control succeeds only if it
finds an accepted disagreement whose shrunk form the corrected checker
rejects. `scripts/run-mutants.sh` applies source-level checker edits
(`scripts/mutate.mjs`) and runs the unmodified generator on each.

Lean **4.29.1** is pinned by `lean-toolchain` and locked nixpkgs; no Mathlib,
no network, no paid service. The project is outside the Zig gates.

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
| `Generator.lean` | the general generator: v4's chains of moves, and v5's conditional arms and generated declaration tables |
| `Oracle.lean`, `OracleLegacy.lean` | template families, generator versions 1–5, campaigns, shrinking, controls, distinct and precision counts |
| `Aliasing.lean` | a campaign metric: does an accepted program write an array two names reach |
| `Fixtures.lean`, `GeneratedRegressions.lean`, `Smoke.lean` | verdict fixtures, frozen regressions, negative-control probes |
| `HeapProof.lean`, `BuilderProof.lean`, `KernelChecks.lean` | concrete heap and builder/close proofs, kernel checks |
| `Soundness.lean` | the bridge to concrete heaps and the soundness statements |
| `Falsify.lean` | executes the unproved statements on concrete configurations (`ownership falsify`) |
| `Report.lean` | printing summaries |

[DESIGN.md](DESIGN.md) specifies the boundary and the summary layer;
[COVERAGE.md](COVERAGE.md) audits T1–T59, says what is and is not tested,
lists every theorem with its status and the thesis discrepancies found.

## Proof status

Proved without `sorry`: the builder/close contracts against the executable
primitives and the concrete heap lemmas (unchanged). Proved but **conditional
on a naming** of origins that nothing yet constructs: the soundness of the
checker's overlap and demand tests, and the abstract builder value describing
the concrete allocation. Bookkeeping: the invariant's base case, and that the
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
two checker defects, now fixed. Lemma 6.7's clause 4 is not stated (the
interpreters do not record callback invocations). No axiom is declared;
`lake build` fails if the set of `sorry`-dependent constants changes, or if any
`sorry`, `admit`, `native_decide` or `axiom` appears in the sources beyond the
three statements (`Axioms.lean`).

## Limits

No recursive data types, list views, dictionaries, sets, opaque types, release
representations, implicit evidence, effects, fibers, TEA or renderer.
Mutual recursion, higher-order recursion, recursion inside a traversal or
focus step, function values below an input path and callbacks with
function-typed parameters or results are explicit `limit:` rejections.
Inference depth 200, fixpoint rounds 24, evaluation fuel 100 000 and snapshot
depth 256 fail explicitly. A finite campaign is neither exhaustive nor a proof.
