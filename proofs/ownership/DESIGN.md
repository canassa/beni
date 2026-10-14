# Executable core contract

This file specifies the implementation boundary before its implementation. The
thesis is unchanged. Chapter/section numbers refer to the 11 October 2026 thesis.

The input is typed evaluation-order syntax, with numbered local variables,
integer constants, immutable positional records, array lists and explicit
closure captures. All primitive operands are atoms. A let binds its entire
right-hand side before its continuation. Both arms of a conditional are checked.
Functions are a finite declaration table; closures reference declarations.
Self recursion uses an explicit recursive call. Mutually recursive declarations
and recursive data types are outside this first core.

Two fuelled interpreters execute the same syntax. The value interpreter allocates
a new array for each writer; the update interpreter replaces the existing heap
array. Copy is always shallow. Read observations are immutable, recursively
expanded snapshots at the instant of the read, not references into either heap.
Fuel exhaustion and invalid input are explicit outcomes, never acceptance or
equivalence. Function observations expose a declaration and captured values, not
heap addresses. Arithmetic is mathematical Int; machine overflow is irrelevant
to the ownership property.

The checker uses finite per-path sets of symbolic origins, including parameter,
capture, fresh allocation and shared origins. Lists merge positions at [*] but
retain an independent recursive exclusivity certificate. Liveness is computed
from residual syntax, retaining evaluated operands until their consuming
instruction. A write checks known provenance, unescaped/nonshared storage,
deadness after the demand and disjointness with other operand paths. Calls infer
and instantiate summaries; recursive summaries ascend by join and receive a final
validation pass. Limits reject explicitly.

Four structured primitives expose the ownership facts ordinary array indexing
cannot express:

* Traversal folds over a list or an integer range, once per position. When its
  step consumes an element it requires a dead, exclusive source and supplies
  separated elements. Captured values remain live across iterations. Its
  accumulator invariant is inferred by iteration, including result provenance
  and exclusivity; no arbitrary callback result is assumed owned.
* Focus scopes a single element loan and replaces that position with the body's
  result before the container is usable again. A consuming body requires an
  exclusive container. A shape-preserving result retains exclusivity.
* Builder starts empty and accepts one value at a time. Its exclusive-contents
  certificate requires exclusive elements, separation within and between stored
  values, and no outside live holder. The old-rule flag deliberately omits the
  recursive-element premise for fresh per-call results, solely as a negative
  control for T59.
* Close hands over the builder. Its optional source permits the thesis's map
  identity shortcut, after comparing corresponding element identities. The
  checker includes both provenances regardless of which branch the runtime takes.

Map, initialize and foldl must be declaration-table programs over these forms,
never checker opcodes. Any contract that this inference cannot derive is to be
recorded, rather than patched with an unlabelled special case.

## Executable proof boundary

The interpreters, ordinary type checker and ownership checker are total Lean
definitions. Syntax/domain walks use structural recursion; evaluation and summary
inference use explicit decreasing fuel. Fuel exhaustion is an error, not a
successful finite execution. The existing shared execution budget also bounds
wide traversals. Definitions used by proofs must be reducible in the kernel;
`partial def`, `unsafe` and axioms are not a shortcut around this boundary.

`shared x` registers a permanent external holder of the value of `x`. The value
interpreter retains its immutable value, and the in-place interpreter retains
the actual reference. After each completed expression the observer reads every
registered holder, recording its recursively expanded value in a separate trace
stream. These are observations of execution prefixes, so a write followed by a
restoring write cannot hide an intervening violation. This is a small adversarial
context for the shared-value rule, not an implementation of a host platform.

Escapes persist independently of a callback's result. Every call, focus and
traversal instantiates them into the enclosing state. Permanent escape facts
compare underlying cells, not temporary current/previous position loans. Traversal
validates against all accumulated escape facts before accepting its fixpoint.
A named negative-control flag retains the old missing-escape transfer solely to
prove that the oracle can now observe that defect.

The builder proof must refer to concrete heap values and the actual `put`/`close`
operations: a list of cell numbers alone is only an auxiliary set lemma. Every
claimed certificate theorem must name the executable operation it certifies.

A concrete closure description must agree with its abstract declaration and
with the descriptions of its captures recursively, including closures inside
captured records or arrays. A shallow footprint match is insufficient: a read-only
abstract callback and a concrete writing callback can have the same footprint.
Symbolic inputs remain abstract over code, with their behaviour constrained by
the guards; unknown joins cannot be called. The once/many honesty test must also descend into captures; a once outer
closure cannot hide a writing inner closure falsely marked as many. The
executable falsifier must check this same recursive agreement and deliberately mislabel inner closures as well
as outer ones. This repairs a hypothesis of the unproved soundness statements;
it does not certify them or change the executable ownership checker.

The step lemma's environment typing applies to both sides: value observations
and finite expansions of the actual heap values have the same declared types.
Dead bindings may have stale contents, but their actual shapes and references
must still be valid. In particular, `close` reads its source without making it
live; value-side typing alone admitted an integer or dangling reference there
and made one interpreter fail while the other succeeded. This is a premise on
valid configurations, not a new language restriction.

Consuming a known once callback demands every capture write it may perform,
including writes made by called once closures captured inside it. Resolve the
captured calls recursively; forward calls of symbolic captured inputs into the
parent's call row, and enforce their multiplicity when the actual code is known.
A closure's own synthetic root is not a substitute for its written arrays.
`close` can revive one of those arrays without a syntactic use at creation, so
the call must check the actual written cells against its continuation.

## The summary layer (thesis §3.7, §4.4–§4.7)

`Checker.lean` summarises each declaration once per guard valuation and uses
only the published summary at a call. The per-call re-inference checker that
preceded it is frozen as `Reinfer.lean` (`--reinfer`, `--cross-check`).

* **Inputs.** A declaration's parameters and captures are canonical: each path
  with cells is named `π_i.q` (or `◇_i.q`), keeping exclusivity flags. A
  function-typed input is `symbolic`: its alternatives (code and captures) are
  hidden; its environment is one origin `π_i.env`, its own cell `π_i` when the
  actual value may be once. A function value below an input path is a limit.
* **Guards.** The body learns a symbolic input's class only by asking `Fact`s
  about one call of it: `W`/`E`/`xreq` on each argument path, `π_k.p ∈ res(q)`,
  `env ∈ res(q)`, the fresh numbers in `res(q)`, `shared`/`⊤ ∈ res(q)`,
  `xres(q)`, `E` on its environment, once. A query carries σ, the argument
  state at that call: canonical argument shapes and the argument paths unique
  there. Every answer is recorded as a guard of the summary being computed.
  The answer comes from the call site: the actual closure's own summary under
  σ (its class), or, if the actual is itself a symbolic input of the caller,
  the caller's answer, recorded as the caller's guard.
* **Rows.** A summary publishes `use` (reads R, result cells A, escapes E,
  writes and consumes W), `res` and `xres` (the result value), `xreq`
  (`requiresExclusive`), and per function-typed input its `calls` (0, ≤1,
  many) and one `Supply` per call: what is passed, the callee's environment,
  σ, and the argument paths supplied owned (Known, Unescaped, Dead, Disjoint
  at that call) and exclusive. `consumes` is W through a supply: it becomes W
  on the declaration's parameters and is never demanded inside it.
* **Reuse.** The cache is keyed by declaration, canonical inputs and the owned
  set. A cached summary serves a call only if every guard it recorded answers
  the same there; this is the guarded value of §3.7 resolved at the call.
* **Call sites.** A call re-checks each supply against the caller's live
  holders and other operand paths; a supply to a symbolic input of the caller
  is transferred to the caller's rows; one to a known closure meets the edges:
  W ⇒ owned supply, xreq ⇒ exclusive supply, once ⇒ at most one call. The
  same re-check runs where a traversal or focus step ends, with the
  traversal's own holder sets.
* **Recursion.** A group starts from the bottom summary, joins each round
  into the previous one and is validated against the final assignment (§4.5).
  A recursive call inside a traversal or focus step is a limit (the step's
  vocabulary is not the declaration's).
* **No `need` row.** Where a declaration promises an exclusive result built
  from a callback's results, its `xres` is guarded on the callback's `res` and
  `xres` facts; no separate `need` fact was required by any fixture or mutant.

## Negative controls

`Config.mutant` names a deliberate hole: seven are the first review's missed
mutants, fourteen weaken a summary row (including `once-through-call`),
four weaken liveness (`branch-live`, `branch-closure`, `shadowing`,
`no-scope`), two weaken escapes (`shared-roots`, `shared-fn`) and one the
call count of a traversal step (`many-off`). Each required one has a fixed
probe in `Fixtures.lean` that disagrees under it and is rejected without it
(`no-scope`'s probe runs the checker on a configuration directly, because no
typed program reaches it); `ownership ci` requires the probes and that the
generator alone catch every required hole within its budget.
`ownership controls` runs one normal campaign (20000 trials) per hole and
fails unless each required hole is caught by the generator alone; the holes
argued equivalent in COVERAGE.md (`callback-requires`, `requires-edge`,
`transfer-supplies`) and `no-scope` are reported, not required.
`borrowed-supply` is reported under summaries (live but never seen to
disagree; COVERAGE.md) and required against the per-call checker.
`ownership verdict-diff --mutant=…` counts the verdicts a hole changes.
`scripts/run-mutants.sh` re-applies source-level edits (`scripts/mutate.mjs`)
and runs the unmodified generator on each build.

## Soundness statements

`Soundness.lean` names origins by arrays (`Naming`), calls a naming separating
when origins the checker calls non-aliasing name disjoint arrays, finds values
in a heap by path relationally (`AtPath`, `Reaches`; no fuel), relates an
abstract value to a concrete one path by path (`Describes`: the arrays at each
path named by the cells at that path, each exclusive list's value repeating no
array), states Lemma 6.7 (`CallSound`, clause 2 as repaired: the holders that
outlive a call are its result and the permanent observers) and the main
theorem over every fuel bound with an explicit `Invariant` that also relates
the permanent observers of the two runs and the checker's recorded escapes.
Both interpreters fail on observing a value deeper than `observationDepth`, so
correspondence itself has no depth bound. `Falsify.lean` executes the unproved
statements on concrete configurations. What is proved and what is `sorry`,
why each `sorry` is believed true and what the falsifier found is in
COVERAGE.md.

### Call shapes and verification failures

Summary soundness requires the concrete argument count to match the declaration,
the capture count to match its capture types, and the canonical input count to
match their concatenation. A falsifier must vary the args/caps boundary independently
of the naming, rather than assuming every configuration is a logged real call.

Audit command restrictions apply recursively through command wrappers. Executable
metaprogramming tactics are refused before elaboration; names do not exempt a
constant from kernel replay. Failed audits retain their exported work and logs.
CLI commands and options must be recognized and applicable to their mode; empty
falsification and ignored mutation requests cannot produce success. CI preserves
original and shrunk counterexamples. Campaign publication waits for every child
and leaves prior logs unchanged on failure.

Search includes a captured once callback called twice with both results retained,
a captured list passed to a captured writing callback (its effect is a consumes
row), and either arm of a function-shape join retained as data. CI's small complete
grammar is supplemented by a bounded targeted grammar covering these shapes,
set exclusivity, scalar comparisons, and first-order recursion. Source-mutant
counts refer to unique edits; historical aliases do not add another hole.
