# Schema ownership v2 coverage after the compiled rewrite (#1928)

Base: workers-hostfree `2f599566c9`. V1 enforcement, ownership words, budgets,
wire formats and the clean-module/publication rule are unchanged. No Browser.Host
or native-catalogue source changes. The dated ownership-v2.md §2.6 amendment
preceded the implementation.

## What the narrow fix does

`nodeRef body = Node (Js.pure λ⊤ → Js.ref body)` already emits its body directly
(backend.md §4). V2 formerly stopped at the wrapper lambda. It now walks that
literal unit/wildcard body in the enclosing frame, forwards its answer, and
keeps its reads, escapes and writes. It absorbs only the wrapper, with the
body's answer consumed at the call. The existing `Js.ref` row still escapes the
supplied body; no hidden aliases become fresh merely because their outer
reference is fresh. This is immediate execution, not general closure analysis.
Stored thunks, nested returned lambdas, named-unit parameters and same-spelled
user functions keep their existing unsupported rules. Resolved declaration
aliases of the real primitive retain its identity.

## The nineteen declarations

The first unsupported construct is the original exact-base v2 report's reason;
its dependency column follows that reason to the actual unsupported operation.
A `local` here is a lambda parameter in an unbuilt inner callable frame, not a
missing source binding.

| Declaration | First unsupported construct on base | Dependency / remaining justification | Result |
|---|---|---|---|
| `fields` | lambda, `λ_ → emptyProduct` | Stored `Fields.build` function; `emptyProduct` itself stores six workers. None is an immediate pure body. Needs S4 callable construction, captures and invocation. | remains #1928 |
| `nullary` | call, `nullaryWorkers injectE injectA` | Worker construction calls stored injection/project functions (`inject ⊤`, `project item`), retains them in returned worker closures and composes `nullaryWrite`/`nullaryTyped`. Requires actual callable classes and capture flow. | remains #1928 |
| `describedList` | call, `nList child` | `nList → nodeRef →` literal immediate pure body | restored |
| `describedNullable` | call, `nNullable child` | `nNullable → nodeRef` | restored |
| `describedRecord` | call, `nRecord fs` | `nRecord → nodeRef`; field-list cells still escape through the existing reference row | restored |
| `describedTagged` | call, `nTagged discriminator variants` | `nTagged → nodeRef`; variant-list cells still escape | restored |
| `describedRecursive` | call, `nRef (cellOf name build)` | `cellOf` already has a class retaining `build`; the unsupported outer `nRef → nodeRef` now has one. This does not analyse invocation of `build`. | restored |
| `describedHost` | call, `nHost child` | `nHost → nodeRef` | restored |
| `describedTuple` | call, `nTuple nodes` | `nTuple → nodeRef`; nodes remain escaped, not invented exclusive | restored |
| `describedMaybe` | call, `nMaybe child mode` | `nMaybe → nodeRef` | restored |
| `describedMaybeField` | call in `.node`, `nMaybe child mode` | Same `nMaybe` dependency inside a fresh field-description record | restored |
| `describedConverted` | call, `nConverted child` | `nConverted → nodeRef` | restored |
| `shapeString` | local `input` in stored `ShapePlan` lambda | `(Js.Value, Int → Js.Value)` is a retained validator, called later by `shapeRun`; its own parameters and body require a callable frame. It is not a `Js.pure` body. | remains #1928 |
| `shapeBool` | local `input` in stored lambda | Same callable-frame requirement, with the boolean type test | remains #1928 |
| `shapeFloat` | local `input` in stored lambda | Same callable-frame requirement, with the number type test | remains #1928 |
| `shapeNull` | local `input` in stored lambda | Same requirement; its null check and returned host value run later | remains #1928 |
| `shapeValue` | local `input` in stored identity lambda | Even the identity is stored and invoked later. Substituting its answer now would lose the distinction between a callable and its future input. Needs the general lambda class, not a selector exemption. | remains #1928 |
| `shapeInt32` | local `input` in stored lambda | The number/int32 tests run on that callable's later argument | remains #1928 |
| `shapeNever` | lambda `λ_ _ → shapeFail` | No parameter read precedes the lambda, hence this reason rather than `local`. Still a stored callable, not immediate execution. | remains #1928 |

The cohort restores **10 of 19**, with **9 remaining** and individually justified.
The other fourteen restorations are `nodeRef`, `nPrim`, `nList`, `nNullable`,
`nConverted`, `nHost`, `nBroken`, `nRecord`, `nTagged`, `nRef`, `nTuple`, `nCtors`,
`nMaybe`, and `describedConstructors`. No unsupported body is reclassified merely
because its name belongs to Schema.

## False coverage found by the audit (#1966)

`Groups.callee`'s catch-all treated a `Dispatch.Term.field` as composed comparison
evidence. A field invocation with one explicit argument looked like a two-operand
comparison and received a comparison class, losing the actual callable behavior.
`FieldCallUnbuilt` pins the direct field call, the same call inside `Js.pure`, and
a caller using its result. Those operations now remain unchecked under the
existing S4 rule. This withdraws false coverage; it is not a new publication rule.

Six core declarations formerly reported as checked now honestly remain unchecked:

| Declaration | First unsupported operation | Attribution |
|---|---|---|
| `Schema.nodeOf` | `state.node ⊤`, a stored function field | #1966 |
| `Schema.argumentsAnalysis` | `supplied.analyse ⊤` | #1966 |
| `Schema.fieldNode` | call of `nodeOf` | #1966 |
| `Schema.argumentProblem` | `supplied.analyse ⊤` | #1966 |
| `Schema.describedOf` | call of `nodeOf` | #1966 |
| `Task.findEnded` | `item.stop ⊤` | #1966; not a change to the Task kernel |

Three previously unchecked declarations move their first reason without changing
coverage: `Schema.resolve` reaches the real `cell.build` field invocation once
`nRef` is checked; `Schema.memoArguments` and `Schema.argument` now encounter their
unsupported dependency calls before their wrapper lambdas. Their dependencies
remain pessimistic, with no optimistic result class.

The core inventory is **880 → 862**: **24 restored**, **6 false-coverage entries
withdrawn**, **0 other new entries**. The inherited 56 Browser.Host wrapper losses
remain attributed to #1961; no files in that lane were touched.

The existing ownership fixtures that expose the field-call correction are
`ConditionalCallbackKeep` (`Keep.keepThenEdit`, then its wrappers), `DotFieldCall`
(`dottedLater`, `extDotted`), `UnknownCallee` (`load`), `UnknownCalleeTagger`
(`fetch`'s first reason), `GrowingFunctionSlot` (`loop`'s first reason), and
`GrowingCast` (`applySlot`). They must not claim a comparison class for a function
call. Every golden change is attributable to that rule, not a blanket blessing.
The obsolete `DotFieldCall 15:10` parity exception is removed: its declaration
now stops at the unsupported field call, so v2 no longer invents that later
writer verdict. No new parity exception is added.

## Cache, bounds and validation

V2 reads/writes no per-module cache (`Session.zig` disables it under
`ownership_v2`). V1 cached interface facts and the v2 serialized format are
unchanged, so no version bump is needed. The imported-source fixture checks
returned aliasing and writes across modules; jobs 1/8 and cold/warm v1-cache
reports are compared separately in evidence. Canonical Js resolution uses the
existing named dependency and never reads its type facts on an unrelated call.

No module or budget was added: `CellSelectors` remains below 100 lines,
`TransferFrame` below 260, `Transfer` at 660 and `Groups` at 2350. The module
count remains 43. The new cases pin accepted immediate writes, rejected later
uses/returned aliases, nested immediate execution, stored/ref-contained aliases,
unsupported stored/returned callables, wildcard support and a same-spelled user
function. Validation results and the complete inventory/corpus verdict audit
are saved under dagon `~/worktree-evidence/wd-fiber/schema-1928/` and summarized
in the PR.


Final validation: all 535 ownership, 749 run and 811 browser cases pass; Zig
and Beni formatting, own2 units and the literal-reader cache regression pass.
Both new regression fixture groups fail against the base binary and pass on the
candidate. The complete v1 core report is byte-identical; all 59 existing v2
core demand verdicts match. Import reports match at jobs 1/8, and cold/warm v1
cache checks match with four cache files produced.

The complete metadata ledger (`golden-audit.json` in evidence) also lists eight
withdrawn false-coverage entries and two first-reason changes in six ownership
fixtures; ten withdrawn entries and eight reason changes in twelve run
fixtures; and four reason changes with no coverage withdrawal in the two
browser fixtures BallMachine and ModelCallback. These all follow #1966's field
call rule. Runtime transcripts and existing v1 ownership goldens did not change.

The full candidate gates ran once: 143 inherited failing cases in build/bad
(4), check/bad (1), and emit (138), exactly matching the saved b8 base failure
case list, with no added failures. The base is 2f599566c9, whose tree equals
#1964 head 4915c8280; that PR's saved full run and final targeted corrections
account for the already-fixed base ownership inventory. No full base suite was
repeated. `gate-comparison.json` records the exact set comparison.
