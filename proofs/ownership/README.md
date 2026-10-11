# Ownership oracle

An executable Lean 4 model of the ownership thesis, intended to find mistakes
before attempting its main proof. This does not implement ownership in the beni
compiler. The thesis files are unchanged.

**Stopped on a finding.** The default fixture suite is deliberately red:
traversal fails to propagate a callback's permanent escape into the enclosing
summary, so a later write is accepted. The required rejection is retained;
neither the checker nor the expectation has been weakened to hide it. This is
an implementation defect in this core, not evidence of a new thesis
counterexample. Further exploration and proofs stopped at its discovery.

## Run

From the repository root:

```sh
nix develop .#ownership
cd proofs/ownership
lake build
lake exe ownership 1000 20261011
```

The arguments are a program count and a deterministic seed. The executable runs
the fixed fixtures before generation. The known failure currently exits 1 before
generation. The explicit `--generator-only` option runs generation independently;
it does not claim the fixed suite passed. The old-rule switch deliberately restores
the missing recursive exclusivity premise behind T59; it is a negative control,
not a supported checking mode. [RESULTS.md](RESULTS.md) gives the measured runs,
negative-control commands, and retained finding; [COVERAGE.md](COVERAGE.md) audits
all T1–T59 identifiers and identifies the unfinished applicable fixtures.

Lean **4.29.1** is pinned twice: `lean-toolchain` selects it for Lake, and the
repository's locked nixpkgs provides it in the `ownership` shell. No global Lean
installation, download through elan, Mathlib, or external service is needed.
The project is deliberately separate from `zig build gates`.

## What executes

`Syntax.lean` defines strict, typed, evaluation-order syntax with numbered
variables. It has mathematical integers, immutable positional records, array
lists, closures with explicit captures, let, zero/nonzero branches, saturated
calls, and first-order self recursion. `typecheck` checks every declaration before
the ownership checker runs. The branch is the core's minimal exhaustive case;
there is no source parser or general algebraic pattern matching.

List literals allocate; `push` implements `[ …acc, x ]`; `set` replaces a
position; `at` takes an explicit default; `length` reads; `copy` is shallow.
Out-of-range `set` is a no-op but still a checking demand. Empty and negative
range traversals do no work. Callback invocation may be once or many times.

`Semantics.lean` contains two separate evaluators. One uses immutable recursive
values and builds a new array at every writer. The other uses addressed arrays
in an explicit heap and writes them in place. An observation includes the final
value and a snapshot at each explicit read, traversal element/length read, and
focus read. Snapshots expand lists and closure environments immediately; they
cannot change after a later write. Addresses are not observations. Integer
arithmetic and branch tests have no heap read to record. Both evaluators run with
fuel; exhaustion or an evaluation error is reported separately and never counted
as observational equality.

`Domain.lean` and `Checker.lean` track provenance at record, element, and capture
paths, residual-syntax liveness, fresh-site identities, once-closure cells, and
recursive exclusive contents. They infer and instantiate summaries of reads,
writes, result aliases, escapes, and exclusivity requirements. Recursive and
traversal summaries iterate to a fixpoint and reject when their limits are hit.
The checker specializes higher-order summaries at actual callback classes; it
does not implement the thesis's separately published guarded summary language.

## The four primitive contracts

These are the trusted inference boundary, specified in `DESIGN.md`, rather than
handwritten summaries for particular library names:

| Primitive | Obligation |
| --- | --- |
| Traversal | Visit each position once; keep the source and captures accounted for; distinguish previous and current exclusive element loans; infer the accumulator invariant. |
| Focus | Loan one element and store its answer before the container is used again. Consumption needs exclusive contents; preserving the certificate needs shape preservation. |
| Builder | Store only with the writer demand satisfied. Certifying contents also requires internal exclusivity, separation between stored paths and elements, and absence of outside holders. |
| Close | Return the builder, optionally using map's privileged identity shortcut. Both possible roots remain in the result provenance. |

`Library.lean` defines map, initialize, foldl, and update as ordinary declarations
over these primitives. No checker opcode or name-based rule recognizes them.
The old flag changes the builder's recursive premise, allowing fresh results
with internal sharing, and propagates the resulting false certificate. Both
evaluators and the generator are otherwise the same.

The full library contracts are **not discharged**: the escape component of a
traversal summary fails derivation, and the pending cases in the coverage audit
have not been attempted. Its required contract remains asserted in `DESIGN.md`
and the red verdict test. There are no asserted map/initialize/foldl summary
overrides that make those obligations disappear.

## Deliberate boundary and thesis discrepancies

Section references below refer to the thesis of 11 October 2026. Limitations are
not claims that the corresponding beni programs should be rejected.

* **§3.1, cells and paths:** finite records and list element paths only. There are
  no recursive data types, list views, dictionaries, sets, opaque types, strings,
  release representations, or implicit evidence arguments. They need additional
  path/representation machinery and are not necessary to express T59.
* **§3.6 and §4.7, function values:** explicit capture atoms represent captures
  after path selection. Capturing an entire record retains the entire record;
  the core does not automatically trim it to the fields a body uses. Closures
  whose capture affinity depends on a function parameter are explicitly refused.
* **§4.4, reading off the summary; §6.3, summary soundness:** the retained failure
  violates escape propagation through traversal. The primitive contract and
  expected-reject regression still require it. An ordinary call propagates the
  same escape correctly; no asserted library summary has been added to mask the
  missing inference.
* **§3.7, summaries; §3.9, liveness; §4.8, generic code:** monomorphic declaration
  instances and callback specialization replace guarded polymorphic interfaces.
  Calls conservatively keep all their argument paths live, including paths that
  the inferred callee summary does not use. This can reject thesis positives.
* **§3.10, shared top-level values:** `shared` is an explicit program-lifetime
  holder marker for checking. It is a semantic identity operation, not a host API
  for storing and subsequently fetching globals. Escape verdict tests therefore
  matter in addition to the differential observations.
* **§4.5, recursion:** self recursion preserves entry capability shape and
  ownership assumptions. Mutual recursion, recursive closure groups, and
  higher-order recursive arguments are explicitly refused. This bounds the
  first oracle without assuming a recursive result is fresh or exclusive.
* **§3.8 and A11:** `close` optionally compares builder elements against the
  source by identity and can return the source. This is the sole privileged
  comparison. Ordinary core code cannot observe identity. `copy` allocates a
  fresh shallow root and does not manufacture exclusive contents.
* **§6.1–§6.3:** observations are all core reads and the final value, including
  recursively expanded closure captures, rather than JavaScript/DOM events.
  Suspension, fibers, TEA, the renderer, and host APIs are excluded. There is no
  proof yet that the executable checker maintains a configuration invariant.

The numeric limits (inference depth 80, fixpoint rounds 24, evaluation fuel
100,000, snapshot depth 256) are explicit failures, not silent acceptance.
Representing a full typed syntax in Lean does not itself prove progress,
termination, or checker soundness.

## Proof status

`lake build` checks `Ownership/BuilderProof.lean` with the Lean kernel, using only
Lean's standard library. Proof work began after the first generated oracle run.

* `Ownership.BuilderProof.builder_contract`: exclusive individual footprints,
  pairwise separation, and no outside holder imply exclusive builder contents.
* `Ownership.BuilderProof.close_contract`: adding an unaliased, unobserved root
  preserves exclusivity.
* `Ownership.BuilderProof.t59_missing_premise`: the footprint `[0, 1, 1]` is not
  exclusive, despite its fresh outer root.

Footprints preserve path multiplicity. Deduplicating them would make the T59
premise vacuous. These prove the concrete builder/close contract (step 5a), not
that `storeExclusive` computes that contract correctly for every heap.

**Remaining, unproved:** map's derived summary against the executable primitives
(5b), summary soundness including round 5's restriction of clause 2 to *new*
escaping holders (5c), and the execution-prefix correspondence with an explicit
configuration invariant (5d). Bridging the executable, fuelled evaluators and
the abstract domain is the next substantial proof obligation. No statements for
these obligations have been accepted as axioms. **There are zero `sorry`s.**
