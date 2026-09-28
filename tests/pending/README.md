# tests/pending — red fixtures of the checker findings

Every fixture here is a program the compiler on `master` gets **wrong**: one finding of
[`plans/checker-findings.md`](../../plans/checker-findings.md) each (`CK-NN`), written with the
CORRECT expected output before the fix exists. The mechanism, the rules and the slice that owns
each fixture are [`plans/checker-rewrite.md`](../../plans/checker-rewrite.md) §2; this file is the
short version.

```sh
zig build test-pending        # NOT a gate: the fixtures here and the non-timing scenarios, on
                              # the Debug binary; passes when every one is red for its recorded
                              # reason
zig build test-pending-perf   # NOT a gate: the timing scenarios, on a ReleaseFast beni
                              # (zig-out/perf/bin/beni); same rules
zig build test-perf           # NOT a gate: the timing scenarios that were FIXED and promoted
                              # (tests/blackbox/perf_test.zig), same compiler, same method;
                              # a red one fails the step
```

`test-pending` runs at every commit. `test-pending-perf` (about 40 s since R8c, plus about 130 s when `src/`
changed and its ReleaseFast compiler must be rebuilt) runs in the slices that touch what a timing
scenario covers (CK-164 and CK-165 since R15's audit, and CK-143 until R15-fix-D promoted it; none was pending from R12, which promoted CK-88, to R15; before it R3, R6a, R7, R8a and R12 for theirs),
any slice touching the checker's hot paths — and in the manager's pre-commit check from R3 on
([`checker-rewrite.md`](../../plans/checker-rewrite.md) §1). Wherever `test-pending-perf` runs,
`test-perf` runs beside it (the manager's decision of 2026-09-25): a fixed timing scenario that
turns red again is a regression, not a pending finding.

## Layout

The same kinds, files and conventions as `tests/corpus/` (`run/`, `check/bad/`, `check/good/`,
`parse/bad/`; a directory is a project with `_expected.*` goldens), plus:

| File | What it is |
|---|---|
| `RED` | one line per fixture: `<path> <signature>` — why it is red today (a `<checker>` column between the two, and a second file, `CLAIMED`, of fixtures green under `--checker=v2` before the cut-over, went with v1 at R12) |
| `../blackbox/pending_test.zig` | the findings a file cannot state — time (`test-pending-perf`), or a generated width or depth (`test-pending`) — as scenarios `scenario/CK-NN`; its `scenarios` table says which step runs each. None is left since R12 promoted CK-88 into `perf_test.zig` (and its shape half into `abuse_wide_test.zig`): CK-41 was promoted into `perf_test.zig` by R3, CK-83 into `abuse_wide_test.zig` by R2c, and at R11 `NEST-UNDER` into `perf_test.zig`, CK-79 and CK-82 into `abuse_wide_test.zig`, and R7's `PERM`, `NEST-OVER` and `NEST-DEEP` into `ordering_test.zig`; CK-03, CK-40, CK-42, CK-75 and CK-80 were red under v1 only, with v2 twins already in `perf_test.zig`. R15's audit (2026-09-27) added CK-140, CK-144, CK-163, CK-166 and CK-167 (`test-pending`) and CK-143, CK-143-publish, CK-164 and CK-165 (`test-pending-perf`); R15-fix-A (2026-09-28) promoted CK-140 into `abuse_test.zig`; R15-fix-C (2026-09-28) added CK-171 (`test-pending-perf`) and promoted it into `perf_test.zig`; R15-fix-D (2026-09-28) promoted CK-143 and CK-143-publish into `perf_test.zig` |

## A fixture

- The first line of the fixture (of the alphabetically first `.beni` of a project) is
  `-- CK-NN: <what it proves>`. The rest of the comment says what 7427828 does instead, and for a
  `run/` fixture it quotes the **oracle twin** that confirms the expected output (§2.7).
- A bad kind may carry a `.codes` instead of a `.diag`, one line per expected diagnostic, in
  output order, warnings included:

  ```
  # comment
  rigid_mismatch 13:13 contains "ANY type"
  missing_field Main.beni:16:7 contains "`aa`" lacks "`bb`"
  type_mismatch 22:* contains "recursive through method calls"
  nesting_too_deep Deep.beni:*
  ```

  `code [file:]line:col` is the code and the start of the primary span; `file` is a path suffix,
  for projects. The code must be a `diagnostic.Code`: a misspelt one is malformed, never red.
  `line:*` fixes the line and leaves the column open; `*` leaves the whole position open. Both
  are used only where the spec does not yet say which region carries the diagnostic — the
  fixture's comment says why, and the slice that turns it green blesses the real `.diag`.
  `contains "…"` and `lacks "…"` are substrings of the message. The run must also exit 1 with
  nothing on stdout, and produce exactly as many diagnostics as lines. A `.codes` is refused for
  any fixture whose path is not under `tests/pending/`, whatever the mode.

## The rules

`test-pending` prints `PENDING RED` or `PENDING GREEN` per fixture and fails only for:

- **(a)** a malformed fixture: no `CK-NN` line (two digits or more), no golden, both `.diag` and
  `.codes`, a `.codes` that does not parse or names an unknown code, a red fixture with no `RED`
  line, or a duplicate line in `RED`;
- **(b)** a fixture GREEN: promote it now (`git mv` into
  `tests/corpus/`, `.codes` → blessed `.diag`; a TIMING scenario moves verbatim into
  `perf_test.zig`, run by `zig build test-perf` on the same ReleaseFast compiler, and any other
  scenario into `abuse_test.zig`) and delete its `RED` line;
- **(c)**, a `CLAIMED` fixture RED under `v2`, went with `CLAIMED` and v1 at R12;
- **(d)** a RED fixture whose signature differs from its `RED` line. A slice that changes why a
  fixture is red updates the line in the same commit, and the reviewer checks the new reason.

## Red signatures

```
timeout                          the compiler (or the emitted program) did not finish
                                 (20 s per run in pending mode)
crash=<signal>                   the compiler died of a signal; a run whose stderr shows Zig's crash
                                 banner (`panic:`, `Segmentation fault …`) is killed there and
                                 signs `crash=ABRT`, the abort Zig's handler ends in, so a slow
                                 stack trace never turns a crash into `timeout`
exit=<n> codes=<code>×<k>,…      the compiler exited n; every code it reported, sorted, with its
                                 count (`codes=none` when it reported none)
  … why=code|count|position|message|diag|stdout
                                 a bad fixture whose compiler exited 1 as expected: the part of
                                 its `.codes` (or `.diag`) that disagreed — other codes, as many
                                 of them, other positions, other text
dev: … / release: …              a `run/` fixture: which of its two builds failed
exit=0 stdout-differs            the emitted program printed something else
exit=0 program-exit=<n>          the emitted program threw
exit=0 iface-differs             a `check/good` interface differs
slow                             a scenario's ratio was over 2.5 on every run
superlinear                      a scenario's exact SIZE ratio (bytes, not time) was over 2.5
                                 (CK-144)
stale-files                      a build left files an earlier build wrote (CK-163)
nondeterministic                 a scenario's identical runs printed different things
```

The signature refines the plan's `exit=<n> first=<code>` (review of R0): the whole multiset of
codes, so a second bug or an extra diagnostic from a typo changes it, and `why=` for `.codes`
fixtures, so a fixture red for its message and the same fixture red for a typo in a line number do
not sign alike.

## Knobs

`BENI_PENDING_VERBOSE=1` prints each failure's full detail as the corpus does. The walker's three
variables (`BENI_CORPUS_ROOT`, `BENI_CORPUS_MODE`, `BENI_CASE_TIMEOUT_MS`; `BENI_CHECKER` went
with v1 at R12), and
`BENI_CORPUS_PART`, `BENI_PENDING_SCENARIOS` (`fast` or `perf`) and `BENI_EXE` (the binary under
test), are set by `build.zig` on every run, so nothing exported in a shell changes what a step
means.

## Timing scenarios

Measured on the ReleaseFast compiler, CPU time, each point the best of 3, `time(2n) / time(n) ≤
2.5` (CK-42: the same on the extra cost over a control). Sizes were recalibrated for ReleaseFast
on 2026-09-25: each is the smallest at which `050cd2d` is RED with a clear margin on three
consecutive runs and, where a reference fix exists (CK-40, and CK-41 before R3 fixed and
promoted it), `050cd2d` with the fix reads GREEN through the same harness. The numbers are in each scenario's comment and in
`checker-rewrite.md` §2.5. Resize a scenario only with both measurements in hand.

## Notes on particular fixtures

- **CK-73's merge variant was first written wrong** (planner's N-5). R0's original
  `check/good/ScrutineeMethodMergeVariant/` kept the `let q z = r.combine z` helper, and expected
  the modules to check. Under D14 (`checker-v2.md` §10.7) that program must be refused: `r` is the
  merged group's in-flight result. It is now split. `check/bad/ScrutineeMethodMergeD14/` holds the
  modules as written, with D14's `type_mismatch`. `check/good/ScrutineeMethodMergeVariant/` holds
  them without the helper, testing only that `g` is not merged. Its `.iface` is still written by
  reasoning, for R7 to confirm.
  *Confirmed by R7 (2026-09-26):* v2 checks both modules and prints that `.iface`. R7 also amended
  the `.codes` of `ScrutineeMethodMergeD14/` and of CK-72's and CK-76's fixtures from
  `type_mismatch` to `kind_mismatch`: `q 1` then `q "s"` is a number literal meeting `String`,
  which is `kind_mismatch` by v1's rule whatever made `q` monomorphic (`checker-v2.md` §10.8).
- **`scenario/CK-71` was promoted by R1** into the gates: `blackbox_test.zig`'s loaded
  determinism test and `Session.zig`'s `mergeInterners` test. The report-only rule it needed
  is gone with it.
- **`scenario/CK-42` measured the extra cost of nominal `==`** (until R11; its v2 twin is in
  `perf_test.zig`) over the same program with
  `x == x`; the control's own super-linearity is `scenario/CK-75`.
