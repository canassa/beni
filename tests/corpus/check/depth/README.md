# check/depth — the guard sweep

Every guard that can stop the checker reading a type, with **two** fixtures:
one level under it, which must check clean, and one level over it, which
must produce a diagnostic. The pairing is the assertion, and the walker
enforces it by name — a `…Ok.beni` with a `.diag`, or a `…Deep.beni`
without one, is a failure.

| Fixture pair | Guard | Measured boundary |
|---|---|---|
| `AnnotationOk` / `AnnotationDeep` | `Types.Builder.max_depth` (512) | 510 clean, 511 reports |
| `AliasChainOk` / `AliasChainDeep` | the same guard, reached by expanding aliases | 509 clean, 510 reports |
| `InferredOk` / `InferredDeep` | `Schemes.Writer.max_depth` (512) | 511 clean, 512 reports |
| `PatternNestOk` / `PatternNestDeep` | `Exhaustive.max_depth` (512), how deep a **pattern** the usefulness analysis walks | 512 clean, 513 reports |
| `ParserOk` / `ParserDeep` | `Parse.max_depth` (4096) | 4095 clean, 4096 reports |
| `TypeParensOk` / `TypeParensDeep` | the same guard, reached through a **type** | 4095 clean, 4096 reports |
| `RenderTruncatedDeep` | `Render.max_depth` (24) | truncates one type to `…` |
| `RecordExtTruncatedDeep` | `Render.max_ext_links` (64), which the checker never reaches: its records are one node (`checker-v2.md` §4.1) | prints all 65 fields and stays OPEN, never eliding the tail as `… \| ` |

## Why this kind exists

`Types.Builder.read` and `Schemes.Writer.writeVar` used to return an `err`
past 512 levels **with no diagnostic**. An `err` unifies with anything, so
the declaration became a hole and a caller's mistake compiled clean — and
the parser's own limit is 4096, so there was an eightfold band of inputs the
front end accepted and the checker silently mis-typed:

```
depth=300 exit=1      # error correctly reported
depth=511 exit=0      # error silently lost
depth=600 exit=0
```

That is a silent wrong answer, which is the one failure mode a compiler may
not have. Every guard here was asserted only by its absence before this
kind existed; the sweep would have caught it on the day it was written.

## One guard joined the sweep late, and the reason it was outside it was a bug

`Exhaustive`'s depth and work budgets used to report **nothing** on purpose,
and this README used to list them here as deliberately excluded. That
argument — a half-searched pattern matrix can no more prove a branch
redundant than prove one missing, so there is no partial answer worth
printing — is still true, and it is why the refusal carries no examples. It
stopped being a reason for *silence* when `backend.md` §7 landed decision
trees: a `case` now compiles to a tree with **no default arm**, on the
strength of the checker having proved it exhaustive, so a `case` the checker
declined to decide does not lose a warning — it takes the tree's last edge
and prints the wrong answer at exit 0.

`PatternNestDeep.beni` is exactly that program: one branch, `Nothing`
unmatched, and it must never compile clean. The **work** budget
has no pair here because the corpus walker cannot pass a flag per fixture and
no `case` a file can hold comes near the default: a flat column is set
membership, so a table costs 2 steps a branch and the
default is 5 000 000 (`checker.md` §6.6). The pair for it is
`blackbox_test.zig`'s `--pattern-budget` scenarios, which say the same thing
in four lines. `PatternNestOk.beni` is now the costliest `case` in the whole
corpus at **528** steps, which is what that number is doing in §6.6's table.

## Two guards are deliberately NOT in the sweep

- **`Constrain`'s and `Solve`'s 4200-level recursion guards.** They sit
  *above* `Parse.max_depth`, so a file the front end accepted cannot reach
  them — `ParserDeep` is the fixture that pins that argument, and it asserts
  the message comes from the **parser**. The guards are written as
  `Parse.max_depth + 104` rather than as a constant so the relation cannot
  rot.
- **`Exhaustive`'s WORK budget**, for the size reason above and not for a
  reason of principle: it reports, like everything else here, and
  `check/Check.zig`'s budget tests plus `blackbox_test.zig`'s scenarios turn
  it down instead of carrying a huge fixture that reaches it.

## Regenerating

The boundaries are measured against the binary, not derived — how many
`read` levels one source level costs is an implementation detail, and a
change to it is exactly what this sweep should catch. If a guard moves:

```sh
sh tests/corpus/check/depth/generate.sh
BENI_WRITE_EXPECTED=1 BENI_BLESS_ONLY=check/depth zig build test-blackbox
```

Everything here is a few kilobytes. A guard that needs a megabyte-scale file
to reach is generated on demand by `bench/gen.zig` instead, the way
`bench/pathological/` splits the same way at 256 KB.
