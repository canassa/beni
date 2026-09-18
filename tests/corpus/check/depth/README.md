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
| `ParserOk` / `ParserDeep` | `Parse.max_depth` (4096) | 4095 clean, 4096 reports |
| `TypeParensOk` / `TypeParensDeep` | the same guard, reached through a **type** | 4095 clean, 4096 reports |
| `RenderTruncatedDeep` | `Render.max_depth` (24) | truncates one type to `…` |
| `RecordExtTruncatedDeep` | `Render.max_ext_links` (64) | elides the tail as `… \| ` and stays OPEN |

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

## Two guards are deliberately NOT in the sweep

- **`Constrain`'s and `Solve`'s 4200-level recursion guards.** They sit
  *above* `Parse.max_depth`, so a file the front end accepted cannot reach
  them — `ParserDeep` is the fixture that pins that argument, and it asserts
  the message comes from the **parser**. The guards are written as
  `Parse.max_depth + 104` rather than as a constant so the relation cannot
  rot.
- **`Exhaustive`'s depth and work budgets.** They report *nothing* on
  purpose (checker.md §6.6): a half-searched pattern matrix can no more
  prove a branch redundant than prove one missing, and there is no partial
  answer worth printing. `check/Check.zig`'s budget tests assert that by
  turning the budget down, which is a better test than a huge fixture.

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
