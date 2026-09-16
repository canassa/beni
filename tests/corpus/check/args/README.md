# `check/args` — the arity suite

`checker.md` §8.3. Currying is gone (`fast-compiler.md` §9.3,
`language.md` §6.7), so **arity is a property of the type** and an arity
mistake is a local one: two function types unify only at equal arity, and a
call supplies exactly the arguments the callee takes. Three diagnostics
carry the class — `too_few_args`, `too_many_args`, `not_a_function` — and
all three fire before the generic `type_mismatch` and suppress it.

This kind exists on its own so its size and its pass rate are visible rather
than buried in `check/bad`.

The suite is cut around the shapes §8.3 names:

* **a lambda of the wrong arity in higher-order position**
  (`FoldlLambdaTooFewParams`, `AccessorWhereBinaryWanted`) — the case
  currying could not localise. Under currying `\x -> x` unified with
  `a -> b -> b` by making the accumulator a function, and the failure
  surfaced two arguments later on the list. With arity in the type the
  lambda is wrong where it is written, and the message says so.
* **a call one argument short** (`UpdateMissingModel`, `ViewMissingModel`,
  `PipelineStageMissingArg`, `WithDefaultMissingFallback`, the `Partial*`
  family) — the TEA papercut and its relatives. The library is subject
  first and function last (`language.md` §6.7), so the argument a call is
  short of is the trailing one, and that is what the message names.
* **a call with one too many** (`TooManyArgsToLocal`,
  `MissingParensAroundInnerCall`, `PipelineSubjectAlreadySupplied`,
  `MapTwoListsWithMap`).
* **a constructor applied to the wrong number of fields**
  (`PartialConstructor`, `TooManyArgsToConstructor`,
  `ConstructorTooFewInPattern`, `ConstructorTooManyInPattern`,
  `NullaryConstructorApplied`).
* **a call through a parameter of function type** (`CallThroughParameter`,
  `AppliedRecordField`) — no name to look up, so the arity comes from the
  parameter's own type.
* **the two `|>` shapes.** `|>` inserts its left operand as the callee's
  FIRST argument, so `PipelineStageMissingArg` is a stage that has its
  subject and is still short of a later argument, and
  `PipelineSubjectAlreadySupplied` is a stage that was already saturated
  and gets one too many — invisible in the pipeline's shape until the
  arity is in the type.

`ComposeMissingArg` went with `>>` and `<<` (`language.md` §6.5).

Each `.beni` carries its intent in a comment and each `.diag` is the WHOLE
diagnostic — code, severity, span, title and prose. A fixture without a
`.diag` is a failure, not a pass (the Elm gap, mechanically closed).
