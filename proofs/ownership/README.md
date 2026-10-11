# Ownership oracle

An executable Lean 4 core of the ownership thesis, with a differential oracle
and a concrete heap proof for builder/close. This is **not a certified ownership
checker** and does not change the beni compiler or thesis.

The repaired default suite is green: **74 fixed verdict fixtures**, including
19 accepted trace comparisons. Three deterministic campaigns generated 60,000
typed candidates, accepted 19,105 and found no corrected-rule mismatch. These are
trials, not 60,000 distinct ASTs; [RESULTS.md](RESULTS.md) records duplicates,
family/depth metrics, limits, timings and negative controls.

## Run and check proofs

From the repository root:

```sh
nix develop .#ownership
cd proofs/ownership
lake build                         # executable AND kernel-checked proof library
lake exe ownership all 1000 20261011
lake exe ownership fixtures
lake exe ownership oracle 20000 17
```

The executable defaults to `all`: fixtures, then generation. `oracle` explicitly
selects only generation; `--generator-only` remains a compatibility spelling.
Counts and seeds are deterministic. A corrected-rule accepted disagreement,
ill-typed generated program or execution error fails the command. Inference
limits count separately among rejections. Counterexamples are saved and greedily
shrunk while retaining typing, acceptance and disagreement; this is bounded local
reduction, not a global minimality proof.

Two deliberate negative controls test the oracle itself:

```sh
lake exe ownership oracle 20 20261011 --old-escape-rule
lake exe ownership oracle 100 20261011 --generator-version=1 --old-rule
```

A negative-control command succeeds only when it finds an accepted mismatch under
its old rule and the corrected checker rejects the minimized result. No mismatch,
or one still accepted by the corrected checker, fails. `--old-rule` restores the
pre-T59 freshness-only builder premise. `--old-escape-rule` drops traversal escape
transfer. The legacy generator is frozen solely for reproducing the original
map/initialize counterexamples; current generation is v3.

Lean **4.29.1** is pinned by `lean-toolchain` and locked nixpkgs. The ownership
shell asserts that the two versions agree. There is no global install, elan
fetch, Mathlib or paid service dependency. This project is outside the Zig gates;
validation of this repair used Lean only, as explicitly requested by the owner.

## Executable boundary

[Syntax.lean](Ownership/Syntax.lean) contains strict, monomorphic, typed
ANF: mathematical integers, positional records, array lists, explicit closure
captures, let, zero/nonzero branches, saturated calls and scalar self-recursion.
The zero/nonzero branch is the minimal exhaustive case; there is no source parser,
list-pattern syntax or general tagged data. Every declaration is ordinarily
typechecked before ownership inference, including negative fixtures.

List literals allocate; `push` implements `[ …acc, x ]`; `set` replaces a position;
`at` takes a default; `length` reads; `copy` is shallow. Out-of-range writes are
semantic no-ops but remain ownership demands. Callbacks run once or many times.

[Semantics.lean](Ownership/Semantics.lean) has independent value and heap
interpreters. The value interpreter builds a new list at each writer. The heap
interpreter mutates addressed arrays. Complete observations contain the final
value, snapshots of every explicit/traversal/focus read, and **external reads**.
`shared x` retains an immutable value in one interpreter and actual references
in the other; permanent observers read all retained values after each completed
expression. Thus a retained old value can reveal an intervening mutation even
when the program's final answers agree. Snapshots recursively expand closure
captures and never retain mutable references themselves.

The type checker, abstract-domain operations, ownership inference, interpreters
and their equality comparisons are total Lean definitions. Recursion is structural
or uses explicit decreasing fuel. Nested `BEq` is implemented explicitly because
Lean's automatic derivation would introduce opaque partial comparisons.
The frozen legacy generator is the only remaining explicit `partial def`;
it is outside the proof boundary. Current generation and reduction are total.

[Domain.lean](Ownership/Domain.lean) and [Checker.lean](Ownership/Checker.lean)
track provenance at record/element/capture paths, residual-syntax liveness,
operand holders, once closures, recursive exclusive contents, and inferred
read/write/result/escape summaries. Traversal propagates callback escapes,
compares permanent escapes without temporary position partitions, and includes
escape growth in convergence. Recursive summaries receive final validation.

## Library derivation and primitive contracts

[Library.lean](Ownership/Library.lean) defines map, initialize, foldl and update
as ordinary core declarations. The checker has no branch for their names. Their
summaries are inferred at concrete callback classes, including conditional edits,
returned captures, nested updates and repeated callbacks.

The trusted inference boundary is specified in [DESIGN.md](DESIGN.md):

| Primitive | Obligation |
| --- | --- |
| Traversal | Visit positions once; account for source/captures and permanent escapes; distinguish exclusive element loans; infer the accumulator invariant. |
| Focus | Loan one position and replace it before the container is used again; consumption requires exclusive contents. |
| Builder (`builder`, `put`) | Satisfy the writer demand; certify contents only with internally exclusive, disjoint elements and no outside holder. |
| Close | Hand over the builder; the optional identity shortcut retains both possible root provenances. |

No map/initialize/foldl summary is hand asserted. The primitive inference rules
remain trusted until the abstract/concrete soundness bridge is proved. The
checker cannot derive higher-order recursive contracts and explicitly refuses
those actual arguments; it also requires stable recursive capability shape.
These are listed limits, not silently asserted library contracts.

## Proof status

[HeapProof.lean](Ownership/HeapProof.lean) relates actual heap values to the exact
observations computed by `snapshot`. Its footprint counts every reachable path,
including repeated cells inside records, lists and closure captures. It proves
snapshot correctness, bounds, allocation framing, and preservation of represented
values when writes change only cells outside their footprints. It also proves
the soundness of the executable identity comparison used by `close`.

[BuilderProof.lean](Ownership/BuilderProof.lean) proves **step 5a against the actual
executable primitives**, rather than merely a theorem about lists of numbers:

* `builder_alloc_contract`: allocation creates a fresh exclusive empty root and
  preserves all permanent outside observations.
* `builder_put_contract`: actual `prim .put` appends the represented element,
  preserves existing elements and outside readers, and preserves exclusivity
  when internal exclusivity and cross-element separation hold.
* `close_contract` and `close_choice_contract`: actual close preserves the
  representation/certificate, including the optional source-identity branch
  under the stated root obligations.
* `t59_concrete_sharing` and `t59_not_exclusive`: the concrete heap containing
  `[cell, cell]` has a repeated reachable cell despite its fresh outer root.

[KernelChecks.lean](Ownership/KernelChecks.lean) additionally checks actual
checker definitions with kernel proofs: the repaired builder rejects the shared
result certificate, the old rule grants it, and permanent escapes cannot be
separated by current/previous position tags. No `native_decide` is used.

**Stopped at step 5b.** The above does not prove that `storeExclusive` soundly
approximates all concrete heaps. Map's general derived-summary soundness (5b),
summary soundness with round 5 clause 2 restricted to **new** escaping holders
(5c), and execution-prefix equivalence with a maintained whole-configuration
invariant (5d) remain unproved. They require a concretization relation for
provenance, liveness, open call frames and traversal loans, followed by an
induction showing inference maintains it. Total executable definitions now
support that work; it has not been replaced by axioms or a claim of certification.
**Zero `sorry`s; no additional axioms.**

## Scope and thesis discrepancies

[COVERAGE.md](COVERAGE.md) audits every T1–T59 identifier and named variant,
distinguishing exact core tests, smaller projections and exclusions. No pending
applicable fixture from the earlier audit remains.

* **§3.1:** no recursive data types, list views, dictionaries, sets, opaque types,
  release representations or implicit evidence arguments. Their representation
  machinery is outside this small heap model.
* **§3.6, §4.7:** captures are explicit paths, not automatically trimmed from a
  larger captured record; callback-dependent capture affinity is refused.
* **§3.7, §3.9, §4.8:** monomorphic callback specialization replaces published
  guarded polymorphic summaries. Calls conservatively retain argument paths.
  T43's reverse-fold rejection fires earlier than the thesis's Dead edge, under
  a conservative captured-consumption/many-call rule.
* **§3.10:** `shared` is an explicit adversarial permanent observer, not a host
  API or a TEA entry protocol. It now has observable retention semantics.
* **§4.4, §6.3:** discarded traversal escapes were a defect of this implementation,
  now repaired and retained as an executable negative control; not a new thesis
  counterexample. Two initial negative fixtures also had an incorrect result
  annotation and now reach ownership checking with their original verdicts.
* **§4.5:** scalar self-recursion is supported; mutual recursion, recursive
  closure groups, higher-order recursive actuals and changing recursive
  capability shape are explicit limits.
* **§3.8/A11, §6.1–§6.3:** observations include recursively expanded captures and
  outside readers; only close may compare immediate element identities. Fibers,
  suspension, TEA, the renderer and release representation are excluded.

Inference depth 80, fixpoint rounds 24, evaluation fuel 100,000 and snapshot
depth 256 fail explicitly. A finite campaign is neither exhaustive nor a proof
of checker soundness. The thesis is unchanged.
