# Checker rewrite — the slice plan

Written 2026-09-24 at `master` = `7427828`. It executes
[`docs/design/checker-v2.md`](../docs/design/checker-v2.md), the normative architecture, against
[`checker-findings.md`](checker-findings.md), the bug catalogue CK-01 … CK-61. Queue row 78 tracks
it. The owner's decisions D1–D13 were taken on 2026-09-24 (`checker-v2.md` §21), and every slice
below assumes them.

## 1. Rules for every slice

- **Spec first (rule 1).** A slice changes code only where `checker-v2.md`, or a document it points
  to, already says what the code must do. A slice that finds the spec wrong amends the spec first,
  in its own commit.
- **Gates (rule 4).** `zig build test && zig build test-blackbox && zig build fmt-check` pass at
  every commit.
- **The two tracking steps (§2, `checker-v2.md` §22.2).** From R0, `zig build test-pending` passes
  at every commit. From R4, `zig build test-v2` runs at every commit: report mode until R8, strict
  from R9.
- **The perf step (§2.5, split out 2026-09-25).** `zig build test-pending-perf` times the
  performance scenarios on a ReleaseFast compiler; it is not run at every commit. It must pass (all
  RED as recorded, or the finding's scenario turned GREEN and promoted) in:
  - every slice that touches the code a perf scenario covers — **R3** (CK-41), **R6a** (CK-42,
    CK-80), **R8a** (CK-40, CK-75), R6a/R14 for CK-03, R7 for `NEST-UNDER` — run by the implementer
    before hand-off and again by the reviewer;
  - any other slice whose diff touches `src/check/` hot paths (`Check.zig`, `Solve.zig`,
    `Schemes.zig`, `Schema.zig`, `Types.zig`, `Dispatch.zig`) or `src/js/Lower.zig`, since a
    scenario can turn red for a new reason (rule (d));
  - **the manager's pre-commit check**, for every slice from R3 on, whatever it touches: about 22 s
    when `src/` is unchanged since the last ReleaseFast build, about two minutes when the
    ReleaseFast compiler has to be rebuilt first.
- **The fixed-perf step (§2.5, the manager's decision of 2026-09-25).** `zig build test-perf` times
  the timing scenarios a slice FIXED and promoted (`tests/blackbox/perf_test.zig`, CK-41 the first),
  on the same ReleaseFast compiler by the same method, and a red one fails it. It is not a gate
  (rule 4 names three). It runs wherever `test-pending-perf` runs, beside it: every slice above
  that must run the perf step runs both, and the manager runs both before every commit.
- **Fail-first (rule 3).** Every CK the slice closes already has a red fixture in
  `tests/pending/`, written by R0. The slice's evidence is that fixture turning green, and then
  either being **promoted** into `tests/corpus/` or being **claimed** (§2.6).
- **Determinism (rule 5).** Any new order is by source position, group index, wanted id or name
  text.
- **Workflow** (`plans/queue.md` "How a slice runs"): an implementer and a read-only reviewer per
  slice; the manager validates, commits and writes the diary. The **reviewer focus** line of each
  slice says what that reviewer must try to break.
- **v1 is frozen** (the owner, 2026-09-25). Master does not have to keep working during the
  conversion. v1 stays only as the **oracle**: it checks `core` and the dependencies, so the
  corpus goldens keep running while v2 grows. **No further fixes or features land on v1.** v1's
  remaining bugs are fixed by v2 only, and v1 is deleted as soon as v2 can check `core` and
  pass the corpus (R9–R11). A slice that meets a v1 defect records it as a CK for v2; it does
  not patch v1 (`checker-v2.md` §22, *Amendment of 2026-09-25*).

---

## 2. Red fixtures without red gates: `tests/pending/`

The harness today (`tests/blackbox/corpus_test.zig`):
- walks the constant root `tests/corpus`, one `test` per kind;
- requires each kind's directory to exist;
- fails the step on any fixture failure;
- runs the installed binary with a 60 s default timeout (`world.zig:62`).

The mechanism below adds as little as possible to it.

### 2.1 Layout

`tests/pending/` mirrors `tests/corpus/`'s layout and conventions exactly: the same kind
directories, files, project directories with `_expected.*`, and the `core/` sub-directory rule.
Only the kinds that are needed exist: `run/`, `check/bad/`, `check/good/` and `parse/bad/`.

It also holds:
- `tests/pending/README.md`, pointing here;
- `tests/pending/CLAIMED`, one repo-relative path per line (§2.6).

### 2.2 Every pending fixture names its finding

The first line of a single-file fixture, or of the alphabetically first `.beni` in a project, is
`-- CK-NN: <what it proves>`. In pending mode the harness refuses a fixture without one, and groups
its report by the ID. The line stays when the fixture is promoted, as the corpus's usual intent
comment.

### 2.3 `.codes`: the pending form of a `.diag`

A red fixture's correct diagnostic text often does not exist yet: a message R13 will write, or a
region only the fixed checker computes. Requiring an exact `.diag` would mean inventing JSON. So a
bad-kind fixture in `tests/pending/` may carry `<name>.codes` (or `_expected.codes`) instead:

```
# one line per expected diagnostic, in output order; '#' lines are comments
rigid_mismatch 7:13 contains "ANY type"
not_equatable 12:31
missing_patterns 9:9 lacks "neither"
```

`code line:col` asserts the code and the primary span's start. Each `contains "…"` or `lacks "…"`
asserts a substring of the message. The harness also asserts:
- exit 1;
- exactly as many diagnostics as lines, **warnings included**;
- nothing on stdout.

`.codes` is accepted **only** under `tests/pending/`. On promotion the implementer blesses the full
`.diag` (`BENI_WRITE_EXPECTED=1 BENI_BLESS_ONLY=<path>`), and the reviewer checks it against the
`.codes` lines before the `.codes` file is deleted.

### 2.4 Harness changes (R0)

**In `corpus_test.zig`**, four environment variables, each defaulting to today's behaviour:

| Variable | Default | Effect |
|---|---|---|
| `BENI_CORPUS_ROOT` | `tests/corpus` | the root `Kind.dir()` joins onto. Under a non-default root a missing kind directory is skipped, not an error |
| `BENI_CORPUS_MODE` | unset | `pending`: see below. `report`: print PASS/FAIL per fixture and never fail on a fixture's result. That is `test-v2`'s mode R4–R8. Unset is today's strict behaviour |
| `BENI_CHECKER` | unset | when set, `Case.argv` appends `--checker=<value>` to `check`, `build` and `dump` (the flag exists from R4) |
| `BENI_CASE_TIMEOUT_MS` | 60 000 | per compiler run. Pending mode defaults to 20 000, so a hang is a fast RED(timeout) |

In pending mode `walk` never fails on a fixture's own result. It prints one line per fixture:

```
PENDING  RED    v1  CK-03  check/bad/CyclicReceiverResolution.beni  timeout after 20000 ms
PENDING  GREEN  v2  CK-01  check/bad/LetAnnotationRigidEscape.beni
```

It fails the step only for:
- **(a)** a malformed fixture: no `CK-NN` line, no golden, or both `.diag` and `.codes`;
- **(b)** a fixture that is **GREEN under the default checker**. It is fixed on the gated checker
  and must be promoted now ("promote it: `git mv …`");
- **(c)** a fixture listed in `CLAIMED` that is RED under `v2` (§2.6);
- **(d)** a RED fixture whose **red signature** differs from the recorded one (S13).
  - `tests/pending/RED` holds one line per fixture: `<path> <checker> <signature>`. The signature is
    `exit=<n> codes=<code>×<k>,…` for a failed compile (every code, sorted, with its count), with
    `why=code|count|position|message` for a `.codes` fixture and a `dev:`/`release:` prefix for a
    `run/` fixture, `exit=0 stdout-differs` for a wrong answer, `timeout`, or `crash=<signal>`
    (R0 follow-up; `tests/pending/README.md` has the full list).
  - Rule (d) holds under **every** checker: a fixture red under `v2` needs a `v2` line too, and a
    `v2` line for a fixture green under v2 is stale.
  - A slice that changes *why* a fixture is red must update its line in the same commit. The
    reviewer checks the new reason.
  - So a fixture cannot drift from "red for the bug" to "red for a typo" unnoticed.

**The environment never leaks into the gates** (S11). Every `addRunArtifact` for `corpus_test.zig`
in `build.zig` sets all four variables **explicitly**, to the values of that step, with
`run.setEnvironmentVariable`. That covers `test-blackbox` (`BENI_CORPUS_ROOT=tests/corpus`, mode,
checker and timeout empty, meaning the defaults), `test-pending` and `test-v2`. *Amended
2026-09-25:* three more variables decide what a run means, and are pinned the same way on every
black-box binary (`build.zig`'s `Blackbox.run`, one place): `BENI_CORPUS_PART` (below),
`BENI_PENDING_SCENARIOS` (§2.5) and `BENI_EXE`, the binary under test (`world.zig`'s `exePath`;
empty is `zig-out/bin/beni`, and only `test-pending-perf` sets it).

`corpus_test.zig` treats an empty value as unset. So a variable exported in the shell, left over
from running `test-v2` by hand, cannot turn a gate into report mode, point it at another root or
switch its checker. R0's exit criteria check it by hand: export
`BENI_CORPUS_MODE=report BENI_CORPUS_ROOT=tests/pending BENI_CHECKER=v2`, run `zig build
test-blackbox` with a deliberately broken corpus fixture in a scratch branch, and confirm it still
fails. Re-checked 2026-09-25 with all seven variables exported (`BENI_CORPUS_PART=build`,
`BENI_EXE` at the ReleaseFast binary, `BENI_PENDING_SCENARIOS=perf` besides R0's three) and one broken
golden in every kind: all 17 failed, `run/`'s in both passes.

**Parts** (added 2026-09-25). `test-blackbox` no longer runs the walker as one process: it was one
binary walking every fixture, and `run/` twice, so its two minutes bounded the whole step.
`tests/blackbox/corpus_parts.zig` lists the parts, and `build.zig` imports that file and adds one
run of `corpus_test.zig` per part, with `BENI_CORPUS_PART=<part>`, in parallel:

| Part | Kinds | Fixtures | Alone (Debug) |
|---|---|---|---|
| `parse` | `parse/good`, `parse/bad`, `fmt`, `bir`, `regress` | 277 | 32 s |
| `check` | `check/good`, `check/bad`, `check/args`, `check/depth`, `dispatch` | 267 | 42 s |
| `build` | `build/bad`, `build/bad-release`, `emit` (with `app/`, `release/`) | 44 | 6 s |
| `run_dev` | `run/`, the development pass | 155 | 27 s |
| `run_release` | `run/`, the `--release --allow-debug` pass | 155 | 27 s |

`corpus_test.zig` maps each kind, and each of `run/`'s passes, to a part with an **exhaustive
switch** (`Kind.partOf`), so a kind cannot fall out of every process, and a part cannot exist
without a run. An empty `BENI_CORPUS_PART` is every part in one process. Pending mode refuses a
part: a `run/` fixture's red signature names the first pass that failed, so it needs both. R4a's
`test-v2` is the same loop with `.checker = "v2"` (and `.mode = "report"` until R9).

For the same reason `abuse_test.zig` was split (about 80 s alone, the longest binary once the
corpus was split): its five wide-input scenarios — CK-17's 100 000-field records, CK-79's cap, CK-81's
65 535-field payloads, the 200 000-element list and the operator chains, about 47 s — moved
verbatim into `abuse_wide_test.zig`, its helpers into `abuse_support.zig` (no tests), 29 + 5 = 34
tests as before. Measured on an idle 16-core (32-thread) machine, `test-blackbox` went from
2 min 36 s to 1 min 30 s of wall time, and in two interleaved pairs from 2 min 57 s to 1 min 42 s. It is now bounded by the machine's CPU, not by one
binary: the 17 processes saturate every core, so each takes about twice its time alone, and the
single-test `matrix_test.zig` and `cutoff_test.zig` (about 45–60 s alone) are among the longest.

**In `build.zig`**, two steps, both depending on install (split 2026-09-25; one step until then):

- **Run 1:** `corpus_test.zig` with `BENI_CORPUS_ROOT=tests/pending BENI_CORPUS_MODE=pending`, the
  default checker.
- **Run 2, from R4:** the same plus `BENI_CHECKER=v2`. Here rule (b) applies to v2 only after R11,
  when v2 is the default.
- **`tests/blackbox/pending_test.zig` with `BENI_PENDING_SCENARIOS=fast`:** the scenarios of §2.5
  that measure no time (`PERM`, `NEST-OVER`, CK-82, CK-83) and the check that `CLAIMED` and `RED`
  name things that exist. On the Debug binary, beside Run 1.
- **`test-pending-perf`:** `pending_test.zig` with `BENI_PENDING_SCENARIOS=perf` and `BENI_EXE` at
  a ReleaseFast `beni` installed as `zig-out/perf/bin/beni`: the timing scenarios, alone, one
  after another. §1 says which slices run it.

Rules (a)–(d) apply in both steps. *(R4a:)* the scenarios of `pending_test.zig` run under the default checker only; only the
pending corpus has a run 2 under `--checker=v2`. Neither is part of `test-blackbox`, so the three gates never run
a red fixture.

R4a adds **`test-v2`**: `corpus_test.zig` over `tests/corpus` with `BENI_CHECKER=v2`. Its modes:
- **R4a–R8b, `report`.** The fixtures listed in `tests/pending/v2-expected.md` are skipped and
  printed.
- **A ratchet** (S12). `tests/pending/v2-green.txt` lists the corpus fixtures a landed slice has made
  green under v2. Report mode **fails** when a listed fixture is red. Each slice appends what it
  turned green, in the same commit, so a v2 regression is caught at the next commit, not at R9.
- **From R9, strict** (mode unset).
- **Deleted at R12.**

### 2.5 Performance and permutation scenarios

`pending_test.zig` holds:
- one Zig test per perf CK (CK-03's time bound, CK-40, CK-41, CK-42, CK-75, CK-80, CK-88, and R7's
  `NEST-UNDER`), each generating its program into a `World`: **`test-pending-perf`**;
- the scenarios about what the compiler says rather than how long it takes (R7's permutation
  scenario `PERM` and `NEST-OVER`, CK-82): **`test-pending`** (CK-83 was promoted by R2c).

The file's `scenarios` table assigns each scenario to its step; `Scenario.init` refuses an id the
table lacks at compile time. The fast ones stay on the Debug binary because its safety checks are
part of their claim (CK-82 is red as a Debug panic; in ReleaseFast the same overflow is undefined
behaviour). The timing ones run on **ReleaseFast** (added 2026-09-25): the budgets they guard are
ReleaseFast budgets (`fast-compiler.md` §2), and a Debug build's constant factors made R0's sizes
cost eleven minutes a run. A timing scenario refuses to run on `zig-out/bin/beni`.

- **Scaling findings** assert a **ratio**: time(2n) / time(n) ≤ 2.5. That is linear with head-room.
  Quadratic is about 4 and cubic about 8. A ratio is robust across machines, where an absolute bound
  is not.
  - **Each point is the best of 3 runs** (S13), so load on a CI machine cannot flake a ratio into a
    rule (c) failure.
  - CK-03's absolute bound, 500 ms of CPU on ReleaseFast (5 s on Debug until 2026-09-25), uses
    the best of 3 too.
  - **Time is the child compiler's CPU time** (user + system, from `wait4`'s rusage), not the wall
    clock, and every run is `--jobs=1`. *Amended 2026-09-24 by the review of R2a:* a concurrent
    build stretched CK-40's two wall-clock points unequally (87 s / 162 s, ratio 1.85) into a
    false GREEN. The wall clock only kills a run, at twice the bound.
- **Calibration (R0).** Choose `n` so that a *fixed* build takes at least 0.5 s at `n`. orch's
  scratch fixes (per-group settling removed; `resetMemo` with amortised growth) are the reference.
  *Recalibrated 2026-09-25 for ReleaseFast:* each `n` is the smallest at which (i) `050cd2d` is
  RED with a clear margin over 2.5 on three consecutive runs and (ii) `050cd2d` with the reference
  fix, where one exists, reads GREEN through the same harness. The 0.5 s floor is dropped: in
  ReleaseFast a fixed build of CK-40 or CK-41 takes 10–30 ms at any size the unfixed one can run in
  seconds, and an empty module takes about 6 ms, so the floor would have cost minutes. The price is
  that a fixed build's ratio sits a little under its true slope (start-up is paid at both points),
  which is why (ii) is checked and recorded, not assumed. Each scenario's comment carries its
  numbers:

  | Scenario | n / 2n | `050cd2d` (best of 3, CPU) | with the reference fix |
  |---|---|---|---|
  | CK-03 | bound 500 ms | never finishes (3 kills at 1 s) | — |
  | CK-40 | 300 / 600 schemas | 295–304 ms; 2n over 2.5× on 3 of 3 (≈2.4 s, about 8×) | 11–12 / 21 ms, 1.75–1.90 |
  | CK-41 | 4 000 / 8 000 ctors | 389–393 / 1 431–1 460 ms, 3.64–3.71 | 11–12 / 17 ms, 1.41–1.54 |
  | CK-42 | 4 000 / 8 000 decls | extra 70–76 / 272–286 ms, 3.76–3.88 | no reference fix |
  | CK-75 | 6 000 / 12 000 decls | 201–205 / 714 ms, 3.48–3.55 | none; CK-40/41's fixes leave it at 3.5 |
  | CK-80 | depth 9 / 18 | 6 / 188–191 ms, about 31 | no reference fix |
  | NEST-UNDER | 200 / 400 methods | red by its codes, not by time; R7 sizes it | — |
  | CK-88 (added by R2c) | 3 000 / 6 000 `case` branches, `build` | on R2c: 204 / 789 ms, 3.86 | none |

  The whole step takes about 22 s once its ReleaseFast compiler is built (and about 95 s more when
  `src/` changed since the last build). One finding of the recalibration: with CK-40's reference
  fix the schema program is linear only up to about 800 schemas — 1 000 / 1 600 take 77 / 158 ms —
  so CK-40's fix, when R8a writes it, should be measured past that too.
- **The permutation scenario (R7)** asserts, for each program and each permutation of its
  top-level declarations (capped at 120):
  - **exit 0**;
  - **stdout equal to the program's oracle-twin output** (§2.7).

  Merely checking that every permutation prints the same thing would pass if every permutation
  failed the same way (S13). A program meant to be refused, such as §10.6's two-types example,
  instead asserts that every permutation gives the same single diagnostic code.
- **Reporting.** Each scenario prints RED/GREEN like §2.4, and fails the step only under rules
  (b)–(d).
- **Promotion** moves a TIMING scenario verbatim into `tests/blackbox/perf_test.zig`, run by
  **`zig build test-perf`** on the same ReleaseFast compiler (`zig-out/perf/bin/beni`, `BENI_EXE`)
  with the same method — best of 3, CPU time, `--jobs=1`, time(2n) / time(n) ≤ 2.5 — where a red
  verdict fails the step; any other scenario moves into `abuse_test.zig`. *Decided by the manager on
  2026-09-25*, when CK-41 (R3) became the first timing scenario to be promoted, closing the item
  left open here: `abuse_test.zig` runs the Debug binary and a timing scenario's sizes are
  ReleaseFast sizes, and a Debug gate would measure another compiler. `test-perf` is not one of
  the three gates; it runs beside `test-pending-perf` wherever that runs (§1).

### 2.6 Promotion and claims

- **Promotion** (`git mv tests/pending/<p> tests/corpus/<p>`, `.codes` → blessed `.diag`) happens
  in the slice that turns a fixture green under the **default** checker. That is v1 before R11 and
  v2 after. Rule (b) makes it compulsory.
- **A claim** covers a fixture that turns green under **v2 only**, before the cut-over. Its slice
  appends the path to `tests/pending/CLAIMED`. From then on, rule (c) turns a v2 regression on it
  into a red `test-pending`.
- **At the cut-over (R11)** every claimed fixture is promoted and `CLAIMED` is emptied.

### 2.7 Writing an expected output nobody has seen

For a `run/` fixture of a wrong answer or a rejected valid program, the expected stdout is written
by reasoning. It is confirmed by an **oracle twin**: the same program in a form `7427828` compiles
correctly. The reviews found one for almost every entry:
- annotating the recursive function (CK-30: `ie9`);
- reordering the declarations (CK-36: `o2`, `row75b`);
- the unannotated version (CK-20: `p12`);
- the direct comparison (CK-27).

The R0 author runs the twin and records it in the fixture's intent comment. Where no twin exists
(CK-25, CK-33), the reasoning is written in the comment.

### 2.8 Harness and fixture items from the design review (2026-09-24), for R0

| Item | What R0 does |
|---|---|
| **S11** | `build.zig` sets all four `BENI_*` variables explicitly on every `corpus_test.zig` run (§2.4). `corpus_test.zig` treats an empty value as unset. A hand check proves an exported variable cannot weaken `test-blackbox` |
| **S13** | `tests/pending/RED` with one red signature per fixture, and rule (d). Perf points are the best of 3. The permutation scenario asserts exit 0 plus the oracle-twin stdout (R7 writes it; R0 only provides the harness hook) |
| **S12** | `tests/pending/v2-green.txt` exists (empty) so that R4's `test-v2` ratchet has a file to read |
| **S4** | CK-04's `.codes` is `infinite_type` ×3, one per self-applied lambda parameter `y` (two in Omega, one in CR1). `checker-v2.md` §6.3's `binders_end` occurs check makes that the v2 output, so the expectation is correct as written. It is red on v1: `Omega` builds, and `CR1` is a `type_mismatch` |
| **N2** | CK-22's `M.beni` writes `inside : T, T -> Bool` annotated, as `dr/c1` does. Unannotated, D1 would make `M.inside …` a `private_method` in `Main` |
| **Round 2** | Also write §5: the eight regression guards into `tests/corpus/` (they pass on v1) and the nine new pending fixtures CK-62 to CK-70 |
| **Round 3** | Also write §5.4: the three guards, the pending fixtures of CK-72 to CK-74 (both declaration orders each), and the R7 scenario stubs, which may start red |

---

## 3. Slices

Order and dependencies:

```
R0 → R1 → R2a → R2b → R3 → R4a → R4b → R5 → R6a → R6b → R7 → R8a → R8b → R9 → R10 → R11 → R12 → R13 → R14
```

The order is strict. R1, R2 and R3 all touch `Lower`, `Dispatch` or the interface, so none runs beside another (S8). R13 can start after R11. Round 3 split R2, R4, R6 and R8 into a and b halves. The IDs keep their numbers, and every older reference to "R6" (say) means the pair.

### R0 — Red fixtures for every finding, and the pending harness

- **Goal.** Every CK with a planned fixture exists red in `tests/pending/`. `test-pending` exists
  and passes on `master`, which proves them red. This slice lands no checker code.
- **Files.**
  - `tests/blackbox/corpus_test.zig` and `build.zig` (§2.4).
  - New: `tests/blackbox/pending_test.zig`, `tests/pending/**`, and `tests/pending/README.md`.
  - The CK "Fixture" lines of `checker-findings.md`: about 55 fixtures and 4 perf scenarios.
- **Closes** nothing. It *records* every CK except the structural ones: CK-10, CK-12, CK-14, CK-15,
  CK-18, CK-26, CK-35 and CK-61. Those have no black-box fixture, by the reasons in their entries.
- **Relies on** `checker-rewrite.md` §2 and `write-tests` skill discipline.
- **Exit criteria.**
  - The three gates are green. `test-pending` is green and prints RED for every fixture.
  - Each RED's reason matches the CK's **Observed** line: the same code, timeout or wrong stdout,
    checked by the reviewer, not only "it failed". A fixture that is red *for a different reason*,
    such as a typo, is a defect of this slice.
  - Each `run/` expectation carries its oracle-twin note (§2.7).
- **Reviewer focus.**
  - Try to make a fixture pass for the wrong reason: loosen a `.codes` line or drop a `contains`.
  - Confirm that pending mode cannot leak into `test-blackbox`, by running it with the variables
    unset.
  - Confirm that rule (b) fires, by pointing one fixture at a passing corpus program.

### R1 — Shared-code fixes and v1 one-liners

- **Goal.** Stop the worst bleeding on `master` where the fix is outside the checker, or trivially
  small inside it. Every fixture turned green here is promoted into `tests/corpus/`, so v2 must
  keep it green later.
- **Files.**
  - `js/Lower.zig`: the record-alias constructor representation only.
  - `bir/Lower.zig`: the `lowerTypeFields` duplicate check, and the `let`-cycle `.self` case.
  - `parse/Parse.zig`: the float pattern message, and `exposing (T(..))` recovery.
  - `Session.zig`: quiet counts errors.
  - `check/Check.zig:1675-1686`: skip on `severity == .error`.
  - `Session.zig:577-590` (and `InternPool`): merge the per-worker intern pools in file-path order,
    so symbol ids are input-derived (CK-71, rule 5).
  - `check/Solve.zig`:
    - `walkDerivableMode` uses a **growable** stack, so it never answers `.unknown` on width;
    - delete `builtinRigidTarget`'s `equatable` arm.

  *Revised 2026-09-24 (S9).* Turning `.unknown` into a refusal would falsely refuse
  `Basics.eq r r` on a valid 300-field all-`Int` record from R1 to R11.
- **Closes.**
  - Promoted: CK-11, CK-17, CK-19, CK-43, CK-44, CK-45, CK-46, CK-47, CK-71 (its `pending_test.zig` scenario moves to `blackbox_test.zig`'s determinism tests).
  - CK-12 by an in-source unit test.
  - CK-33 and CK-34 moved to R2 (S8).
- **Relies on**
  - D8 and D12;
  - `backend.md` §4, where this slice adds the record-alias-constructor row;
  - `checker.md` §6.7, whose "has evidence parameters" sentence was already corrected with this plan
    (N8).
- **Exit criteria.**
  - The gates are green, and the eight fixtures are promoted with blessed goldens.
  - `test-pending` is green. No other fixture has turned green by accident; if one has, it is
    promoted with a note. `tests/pending/RED` signatures are updated where R1 changed a reason.
  - `bench` check phase within noise (±3 %) of `7427828`.
- **Reviewer focus.**
  - CK-19's deletion must not change any other `dispatch/` golden. `Basics.eq` stays structural
    (`check/bad/BasicsEqStillStructural`).
  - The growable walk: a 100 000-field record, and one with a function at field 99 999.
- **Ordering.** R1 lands **before** R2, strictly. Both touch `Lower`.

### R2a — The contract: evidence trees; `Lower` stops counting

*Split from R2 on 2026-09-24 (review round 3).*

- **Goal.** `checker-v2.md` §13 becomes the live checker→backend contract.
  - v1 produces it through a converter in `Dispatch.finish`: flat sites and parts become trees, an
    `err` part becomes `undetermined`, and an `err` site becomes no term.
  - `Lower`, `Edges` and `Reach` consume trees.
  - The emitted JavaScript of the whole corpus is **byte-identical**.
- **Files.**
  - `check/Dispatch.zig`: the tree record, with `DeclInfo` (including `value_arity`, filled by v1,
    and not yet read) and the empty `lets` column; the converter; the I7 assert as `internal`,
    never a panic (§13.1, S10).
  - `dump/dispatch.zig` (format v2).
  - `cache/dispatch_bytes.zig` (v2) and `cache/entry_bytes.zig` (v3).
  - `js/Lower.zig`: delete `targetEvidence`, `externalEvidence`, `ownEvidence`, `valueEvidence` and
    the pre-order cursor. `evidenceShapeOk` becomes the assert.
  - `check/Edges.zig` and `js/Reach.zig`.
  - Spec text: `static-dispatch-spike.md` §7.1–§7.3 and §8.1–§8.2 notes updated to "effective";
    `checker.md` §6.6's sentence (CK-61).
- **Closes.** CK-61. CK-20 is deliberately **unchanged** on v1.
- **Exit criteria.**
  - The gates are green.
  - Every `run/` and `emit/` golden is unchanged **without re-blessing**.
  - `tests/corpus/dispatch/*` is re-blessed once, in the v2 format, and reviewed golden by golden.
  - The I7 assert, run over the whole corpus with `check` and `build`, fires on no fixture that
    passes today. Any fixture where it does is listed and explained.
  - Cache and matrix tests are green with the version bumps.
  - `test-pending` is green, with `RED` signatures updated where needed.
- **Reviewer focus.** The converter is the one place v1's flat pre-order is interpreted
  (`TwoSlotsNested`, `NestedEvidenceIndices`). The I7 assert reports on a hand-corrupted table.
- **As built (stage 1, 2026-09-24).** The points the brief left open are settled in
  `checker-v2.md` §13.1–§13.2 and §14.3, amended before the code:
  - `DeclInfo` is `{ requirements, value_arity }`; `convention` is R2b's, with `dispatch_bytes` 3.
    The dump's `decl` line is `evidence=<n> arity=<a>` until R2b appends `convention=`.
  - The converter counts exactly as `Lower` did (a target's consumed slots from `decl_evidence` or
    the interface), so the emitted JavaScript cannot move; terms are allocated in pre-order and
    `dispatch_bytes` refuses a table whose argument does not follow its owner.
  - I7 also covers roots and MISSING sites (a `method_call`/`type_dispatch` with no callee, a
    `call` of a constrained callee with no site), and runs only on a module that reported no
    error. It moved six pending red reasons from `build` to `check`; `tests/pending/RED` records
    each (CK-28, CK-30 unchanged in count, CK-32, CK-72 ×2, CK-76 ×2).
  - Review fixes: no converter depth cap that writes a term (B1, pinned by the blackbox scenario
    "evidence nested past a thousand levels…"); the assert runs last, after `Cycles` and the round
    trip (S2, `check/bad/CycleNoEvidenceNoise`); `check` now refuses a v1 miscount in dead code,
    kept on purpose (S1, `tests/pending/run/DeadMiscount.beni`, CK-30). Derived callees' own
    arguments print as `arg` lines. Pending perf scenarios measure CPU time.
  - Stage 2 (CK-79, CK-81) is a separate brief.
- **As built (stage 2, 2026-09-24): CK-81.** CK-79 moved to R8a before the brief.
  - What recursed once per link of a chain the compiler builds as long as its input is wide (a
    derived record body's `&&`, one per field; a list literal's nested `{ $: 1, a, b }`, one per
    element): `Print.expression`/`raw` in every build, and `Opt.countExpr`, `planExpr`, `exprUses`
    and `Rename.collectExpr` under `--release`. `Lower` builds both chains in loops, `JsIr.verify`
    is flat, and `Reach`/`Edges` walk dispatch terms, not `JsIr`.
  - The printer recurses as before for 256 levels and past them expands through an explicit
    work stack (the stack for everything cost emit 3–8 %). Two in-source tests print both ways and
    compare bytes, one a generated module over every expression kind at switch-over limits 0, 3, 7
    and 256; and `rawRecursive`, `expand` and `JsIr.pushOperands` list every tag with no `else`,
    so a new node kind does not compile until all three handle it. The four release walks pop
    operands from one stack (`JsIr.pushOperands`). Past the limit the only recursion left is an
    `arrow`'s block body. Bench (ReleaseFast, `--generate=100000`, medians of 7 interleaved): emit
    52.23 ms against 52.21 on 7fd409e. Every `run/`, `emit/` and `emit/release/` golden is
    byte-identical without re-blessing.
  - Running, not only building, at 60 000 fields took two more changes. First,
    `static-dispatch-spike.md` §9.2's **wide form** (spec amended first; A.87): past 4 096
    evidence parameters a derived function of any shape takes one array `$m`, and every caller
    packs the same count. 4 096 is the backend's own ABI constant, equal to CK-79's cap today, so
    no narrower output moves. It was needed because Node threw `RangeError` at the 60 002-argument
    call and V8 refuses more than 65 535 parameters. Second, a linear `Rename.verify` (the
    all-pairs check took 46 s of a Debug `--release` build at 65 535 fields).
  - End to end, Debug binary: 60 000 and 65 535 fields build in about 9 s (dev and `--release`)
    and print all five answers correctly; 65 536 and up panic the checker (**CK-82**, new). A
    200 000-element list literal builds; it and several other accepted programs then throw
    `RangeError` while Node parses them, from about 1 700 levels (**CK-83**, new). Both are pending
    scenarios; the manager assigned CK-82 to R8a and CK-83 to R2c. A written operator chain is
    bounded by the parser first: 100 000 terms is one `nesting_too_deep`.
  - Red proof, on the Debug binary the harness runs (a ReleaseSafe 7fd409e builds the 60 000-field
    program without crashing): the two new `abuse_test.zig` CK-81 scenarios die of `SIGSEGV` on
    7fd409e; with the walkers fixed and no wide form, the 60 000-field program builds and prints
    nothing.

### R2b — One calling convention

- **Goal.** `check/Convention.zig` (§12.5) decides a constrained value's definition, call and
  load-time behaviour for `Lower`, `Cycles`, `Edges` and `Reach`, reading `DeclInfo.convention` and
  `value_arity`.
  - It also owns the fourth reading R2a stage 2 added: whether a DERIVED function takes its evidence
    positionally or as one array (`static-dispatch-spike.md` §9.2 *The wide form*, A.87), decided
    today by the entry count against `Lower.max_positional_evidence` in two places, `derivedArrow`
    and `packEvidence` (three call sites).
  - Nit, recorded by R2a stage 2's review, not required: a wide call's evidence array whose every
    element is a module-level name is rebuilt on every call; it could be hoisted to one
    module-level `const`.
- **Files.** New: `check/Convention.zig`. Also `js/Lower.zig` (the three zero-parameter readings
  replaced), `check/Cycles.zig`, `check/Edges.zig`, `js/Reach.zig`, and `cache/dispatch_bytes.zig`
  (v3, for the convention column).
- **Closes.** Promoted: CK-33, CK-34.
- **Exit criteria.**
  - The gates are green.
  - Every other `run/` and `emit/` golden is unchanged.
  - `test-pending` is green.
- **Reviewer focus.** `Convention` is the **only** place the three readings are decided: grep for
  `params == 0` in `Lower`, `Cycles` and `Reach`. And the wide form: grep for
  `max_positional_evidence`, `evidence_array` and `packEvidence` outside `Convention`.
- **As built (2026-09-24).** `checker-v2.md` §12.5 was amended first with what it left open:
  - The column is the tag alone (`enum(u8) { plain, function, thunk }`, byte 10 of a `decls` row,
    `dispatch_bytes` 3, refused on load when `plain` disagrees with the requirement count); the
    counts stay in `requirements` and `value_arity`.
  - An import computes its convention with the same `of` from its interface (requirement count and
    the scheme body's arity through `alias` terms), so the interface needs no column. Looking
    through aliases is CK-84, found here: `pub same : Pred a` was eta-expanded at arity 0 in an
    importer, a `TypeError` after exit 0. Fixed and promoted with its own fixture.
  - The readings are `definition` (`constant`, `params`, `lambda`, `applied`, `thunk`), `defers`,
    `call` and `referenceArity`, plus `derivedEvidence` for the wide form; `max_positional_evidence`
    moved into `Convention.zig`, and `Lower` keeps only the mechanics (`wide_evidence`,
    `derivedEvidenceArguments`). `applied` is `($m…, $p1…$pn) => body($p1…$pn)`, with a direct call
    when the body is a constrained reference of that arity (`h = maxOf` →
    `($m$0, $p$1, $p$2) => maxOf($m$0, $p$1, $p$2)`). A lambda body with evidence now takes the
    lambda's parameters after the evidence, which fixed `same = (==)`.
  - `Edges` and `Reach` needed nothing: no edge depends on when a body runs. `Lower.externalArity`
    and `externalScheme` are deleted.
  - Fixtures: CK-33 and CK-34 promoted; new `run/ConstrainedFunctionConstantRoutes/`,
    `run/ConstrainedAliasFunctionImported/` (CK-84), `check/bad/EvidenceConstantCycleMutual.beni`,
    `dispatch/Conventions.beni`, and `cache_test.zig`'s warm-rebuild scenario. All red on 84e3cb1
    except the dispatch dump (a new format). The nit (hoisting a wide call's all-name evidence
    array) is not done.
- **As built, review round (2026-09-24).** The manager's decisions on the review, spec first
  (`checker-v2.md` §12.5's second amendment, `checker.md` §6.7, `language.md` §6 and §7,
  `static-dispatch-spike.md` §10.10 and A.85, `boundary.md` §4 check 4):
  - B1: `Convention.defers` is true for `params` and `lambda` only; an `applied` value RUNS for
    `Cycles`, so `h = compose h g` under a `where` is `cyclic_value` like its twin without it. The
    routes fixture's `biggest = go` became `biggest = \xs acc -> go xs acc`; four
    `check/bad/EvidenceFunctionConstantCycle*.beni` and `run/EvidenceFunctionRecursionAccepted.beni`
    added. The `cyclic_value` message names a per-use member when the circle has one.
  - S1: per-call evaluation documented; `run/EvidenceFunctionBodyPerCall.beni` pins it; CK-85.
  - S2: `Emit`'s check 4 reads `Convention.ofDecl` (`build_test.zig`, an alias-typed `foreign`).
  - S3: `constrained_constant` narrowed to non-function types (`check/good/ConstrainedPubFunctionConstant/`,
    a `build_test.zig` run, `check/bad/ConstrainedConstant.beni` rewritten to `Dict.fromList []`).
  - N1–N3: `dispatch_bytes` refuses a thunk row with an arity (in-source test);
    `Convention.bodyIsLambda`/`definitionOf` are the one place; `assertFlatCall`. N7: CK-86, pending.

### R2c — Emitted JavaScript nests only as deep as the source (added by the manager, 2026-09-24)

- **Goal.** Close CK-83: a program the compiler accepts must not lower to JavaScript that Node (or
  a browser engine) refuses to parse. List literals, `+`/`++` chains and nested calls that the
  parser admits today reach about 1 700–2 000 levels of emitted nesting, past V8's parser.
- **Approach.** Spec first in `backend.md` §4: decide the emitted shape for each long form (e.g.
  a list literal as a flat array handed to one constructor call, a long operator chain split into
  bounded helpers), or a named refusal where no shape exists, with the engine measurements
  (V8 and at least one of JavaScriptCore/SpiderMonkey, browser first). Small programs' output
  should stay byte-identical where the representation allows.
- **Also measure** the wide form's threshold (`static-dispatch-spike.md` §9.2, A.87): that a
  4 096-argument call is safe in JavaScriptCore and SpiderMonkey on a browser-sized stack. Only
  Node was measured; lower `Convention.max_positional_evidence` if a browser engine needs it.
- **Closes.** CK-83, promoted from `scenario/CK-83`; the existing abuse test that builds 4 000
  nested calls must then also RUN.
- **Exit criteria.** The gates are green; `test-pending` green; every `run/`/`emit/` golden that
  moves is listed and justified; emit phase within ±3 %.
- **As built (2026-09-25).** Spec first: `backend.md` §4 gained *Emitted JavaScript nests only as
  deep as the source* (the measurements, the unit, the shapes, the refusal and its rule-7 case);
  `language.md` §10's depth limits a row for the emitter; `static-dispatch-spike.md` §9.2 and A.87
  the browser numbers for the wide form.
  - **Measured** in headless Chrome 153, Firefox 144 (Playwright) and WebKit (WPE MiniBrowser), in
    Node 24, the SpiderMonkey 140 shell and Bun 1.3.13 — all from the nix store; no mobile engine.
    Two limits, not one: every engine's stack (scarcest: Chrome at 644 nested `if` blocks and 1 290
    calls, Firefox at 1 263 objects and 497 IIFEs) and SpiderMonkey's hard limit of 251 nested
    scopes, 171 functions with declaring bodies in a module, whatever the stack. JavaScriptCore
    nests even a flat `&&` (53 620 terms). The wide form's 4 096 is fourteen times under the
    scarcest browser's argument limit (59 610) and stays.
  - **Shapes** (`js/Lower.zig`, `js/JsIr.zig`): a list literal past 32 elements is
    `[…].reduceRight(($l, $h) => ({ $: 1, a: $h, b: $l }), nil)`; `&&`/`||` chains are collected
    iteratively and built to the left, one run; `Lower.expr` keeps a running `expr_height` and binds
    anything `nesting.spill` (256 units) tall to a `const $t$<n>` in its `out` — the hoist `?` and
    `case` use, so `orderedExprs` keeps written order; `else if` chains of 16 `if`s or more
    (`chain_min`, counted by `leafCaseDepth` down any branch holding a `case`) splice the larger
    branch after the `if` (negating the test when that is the `then`), in tail position and — via
    a shared sink, `chainedLeaf` — in expression position as one `$c$<d>` block and one temporary;
    evidence closures 20 deep (`evidence_spill`) are bound ahead of the call; derived `&&` runs in
    groups of 1 024.
  - **Refused**: `refuseTooDeep` measures every declaration of at least 128 nodes exactly
    (`JsIr.Builder.measure`, one iterative walk) and reports `nesting_too_deep` past 2 048 units or
    128 scopes. What reaches it (after the review round below): 120 nested functions, a `view` of about 65 `List.map`s, about 150 `if`s nested through call
    arguments.
  - **First design, dropped**: a height per node computed in `Builder.addNode` cost the emit phase
    5.5 %; the cheap accumulator plus the gated exact walk costs 0.4–1.9 %.
  - **Tests.** Promoted `scenario/CK-83` into `abuse_wide_test.zig`; the 4 000-nested-call abuse test
    now runs (dev and `--release`), as do the 200 000-element list (length, sum, head), the widest
    operator chains the parser admits (`+` 4 095, `++` 2 048, `&&` 1 365) and the 1 024-level
    evidence blackbox test (it gained an app build that prints `same`). New: `abuse_test.zig` "functions
    nested past what Firefox parses…" (119 run, 120 refused with the whole diagnostic, nothing
    written); `run/NestingFlatList`, `NestingChains`, `NestingElseIf`, `NestingEvidence` (every
    operand logged; each matches its oracle twin built by 7ae452f, dev and `--release`);
    `emit/NestingShapes`; two hermetic `measure` tests. Red on 7ae452f (scratch worktree): the
    `emit/` golden and the five blackbox/abuse tests fail, the four `run/` fixtures pass as pins.
  - **Goldens.** None moved: every existing `run/`, `emit/` and `emit/release/` golden is
    byte-identical. `bench/corpus` changed by 6 bytes raw (a three-term `&&`).
  - **Numbers.** Emit (ReleaseFast, `--generate=100000`, medians of 7 interleaved, two sets): 52.13
    ms against 51.17 (+1.9 %), and 51.55 against 51.34 (+0.4 %). Size: `emit/` corpus 41 145 raw / 15 842 brotli before and after; `bench/corpus`
    brotli 22 478 → 22 483, release 15 651 → 15 643. Every accepted long form of the corpus of
    probes (lists to 200 000, chains at the parser's widths, `else if` to 2 000 in both positions,
    nesting at each budget's edge) loads in all six engines.
  - **Found**: CK-87 (derived `==` on a record type nested past 32 levels is `internal`: the
    `max_part_depth` cap) and CK-88 (one `case` of n literal branches emits in O(n²), and past 65 046
    a `switch` SpiderMonkey refuses), both with pending fixtures, unassigned.
- **As built, review round (2026-09-25).** No blockers; the two should-fixes were refusals of
  programs 7ae452f builds and every browser loads:
  - S1: the `.lambda` arm discarded its body's height, so nothing bounded the path across function
    boundaries and a TEA `view` of 20 nested `List.map`s (30 children a level) was refused. The body's
    height now flows into the expression holding the lambda, and a body `lambda_spill` (128 units)
    tall binds its closure to a `const` where it is made; a hoist of nothing but closure `const`s
    pins nothing before it (`onlyClosures`, which also answers N4 for evidence). Views with a
    `List.map` at every level now run to 64 (30 children) and 68 (12) levels; nested applied
    lambdas to 119 (one scope more every dozen levels, for the bound closure's declaring body).
    `run/ViewMap20x30`, `ViewMap40x12`, `ViewMapEvery3` (80 levels, a lambda every third) build and
    run dev and `--release` and load in Chrome, Firefox and WebKit; each matches 7ae452f's stdout.
  - S2: `logicalRest` nested one `if` (a scope) per statement-needing operand. It is now
    `let $t = a; if ($t) { …; $t = b; } …` — one flat `if` per such operand, `if (!$t)` for `||`.
    `run/NestingLogicalStatements` (300 operands each way, logged) runs in all three browsers.
  - N1 the message says 553 (Chrome's `(() => …)()`); N2 §4 now names what moved in the emitted
    JavaScript; N3 emit re-measured, −0.3 % and +1.7 % in two more sets (the review saw +2.9 %);
    N5 the recursion caveat for the wide form is in §9.2, A.87 and `Convention.zig`, 4 096 kept; N6
    `refuseTooDeep` asserts a body.
  - CK-88 looked at and left recorded: `Decision.compile` is quadratic in three places — the key
    de-duplication, `chooseColumn`'s distinct count, and Maranget's specialisation of every row per
    key — so a fix groups rows by literal (a sort or a map) through the matrix code, which is not a
    one-line scan.

### R3 — Interface v3

- **Goal.** `checker-v2.md` §14.2 on v1.
  - `u16` arity.
  - Record-alias constructor rows, and `Schemes.instantiateCtor` builds the alias.
  - Derived-context rows, which v1 writes as "one entry per type parameter, method = the derived
    method".
  - `Schemes.Writer` on epoch marks (CK-41).
- **Files.**
  - `resolve/Interface.zig`, `resolve/iface_bytes.zig` (v3), `cache/Digest.zig` (v2).
  - `check/Types.zig` (`arity: u16`) and `check/Schemes.zig`.
  - `dump/interface.zig` and the `raw` stage.
  - `js/Lower.zig` (*added by R1's review, 2026-09-24*): `ctorRepExternal` returns `CtorRep.record`
    for a `record_alias` row, reading the field names the row now carries, and `argName` reads an
    imported alias pattern's arguments by them; `refuseAliasCtors`' `.ext_ctor` arm is deleted.
    `tests/corpus/build/bad/RecordAliasConstructorImported/` then builds, so R3 moves it to
    `tests/corpus/run/` with its expected output (`P 1 "a"` through `Debug.toString` prints the
    record), and `run/RecordAliasConstructorImported/` (CK-39) is promoted beside it.
- **Closes.** Promoted: CK-38, CK-39, CK-41 (perf scenario into `perf_test.zig`, `test-perf`; into `abuse_test.zig` as first planned, until the manager's decision of 2026-09-25, §2.5).
- **Relies on** `checker-v2.md` §14.2.
- **Exit criteria.**
  - The gates are green.
  - `raw` goldens re-blessed for the new columns only, reviewed.
  - `--jobs=1`/`--jobs=8` byte-identical `raw`.
  - `iface` text goldens unchanged.
  - `test-pending` is green.
- **Reviewer focus.**
  - A v2 interface read by a v2 importer, with the cache warm, cold, and partially hit (the matrix
    test).
  - The context rows are sorted by `(param, method text)`, never by symbol.
- **As built (2026-09-25).** `checker-v2.md` §14.2 gained an *As built by R3* paragraph first (row
  layout, the status vocabulary, `payload_params` through alias expansions, the new code, CK-89);
  `checker.md` §7 the v3 layout and the digest's `u16`; `language.md` §10 the code;
  `backend.md` §4's record-alias row and `static-dispatch-spike.md` §9.2 the imported cases.
  - **Arity.** `Interface.Type.arity` and `Types.Entry.arity` are `u16`. Lowering refuses a
    65 536th type parameter with a NEW code, `too_many_type_parameters`, at that parameter, and keeps
    the first 65 535 — §14.2's "becomes an error" named no code, and every existing one means
    something else. Lowering's duplicate-parameter check was pairwise (35 s of a Debug build at
    65 536); it sorts a copy now, reporting each repeat against its first occurrence as before.
  - **Record-alias constructors.** The skeleton (`Interface.build`) writes `result` and the field
    names, which are lexical; `Entry.matchesShell` compares them on a cache install.
    `Schemes.instantiateCtor` builds `alias(T, params, { fields = args })`. In `js/Lower.zig`,
    `CtorRep.record` is `local` (a declaration) or `imported` (an interface row) and
    `recordNames` gives either's names; `ctorRepExternal` answers `record` for a `record_alias` row,
    so `argName` reads an imported alias pattern's arguments by name, and `refuseAliasCtors` is
    deleted.
  - **Derived rows and `payload_params`** are filled by `Check.fillTypeFacts` at `fillInterface`,
    after v1's eager derivation: `present` exactly when the dispatch builder has the nominal row,
    with its evidence count as the context (one `(i, m)` per parameter, v1's ABI); otherwise
    `own_method`, `foreign`, `function` or `unanswerable` by the facts v1 already has. The bitset
    reads every constructor through the annotation reader — an opaque type's hidden ones too — and
    names a parameter by `root − first`, the parameters being fresh in one run, so there is no map
    and no store-sized array per type. Nothing in v1 reads either row; they exist for R8a.
  - **Versions.** `iface_bytes` 3 (`types` rows 16 → 32 bytes, `ctors` 20 → 28; `verify` refuses a
    bitset of the wrong length or with a bit past the arity, a context entry past the arity, a
    context on an absent row, a `record_alias` row whose names do not number its arguments, and
    nonzero padding), `digest_version` 2. With the build id pinned (`--cache-build-id`) R3 reads
    none of 3487c12's entries (14 of 14 re-checked) and hits all 14 on its own second run.
  - **CK-41.** `Schemes.Writer` on epoch marks (`stamp`/`epoch`, growth at least ×2, `touched`
    gone). Promoted into `perf_test.zig` / `zig build test-perf` (§2.5's promotion rule, the
    manager's decision): 12 / 18 ms at 4 000 / 8 000 constructors, ratio 1.50; red through
    `test-perf` on 3487c12 at 400 / 1 476 ms, 3.69.
  - **Fixtures.** Promoted `check/good/WideTypeArity/` (its hand-written golden held 255 parameter
    names, the saturated width; re-blessed at 256 — the only `.iface` golden that moved) and
    `run/RecordAliasConstructorImported/`; `build/bad/RecordAliasConstructorImported/` became
    `run/RecordAliasConstructorImportedToString/`. New: `run/WideTypeArityEq/` (256 parameters,
    `==` and `<` across modules; on 3487c12 exit 0 then `TypeError`), `cache_test.zig`'s wide-form
    scenario (4 097 parameters: cold, warm, `--release` warm, `Main` edited, `--release` again —
    each run, each pass's checked/hit counts asserted; on 3487c12 `TypeError: $m[0] is not a
    function`), `abuse_wide_test.zig`'s 65 535 / 65 536 scenario, `blackbox_test.zig`'s raw-rows
    test, two hermetic tests (`iface_bytes`, `bir/Lower`). `digest_test.zig`'s row 13 moved to a
    TUPLE alias: a record alias's field names are now in the record, so its premise ("an alias body
    in no record") no longer holds for a record alias. All red on 3487c12 in a scratch worktree
    with this slice's tests, except the digest row (a re-scoped premise, green on both).
  - **Numbers.** No raw golden files exist to re-bless (`--stage=raw` is compared, not goldened);
    `--jobs=1` and `--jobs=8` raw dumps are byte-identical over core and all 41 multi-module
    corpus projects. Bench (ReleaseFast, `--generate=100000`, medians of 7 interleaved against
    3487c12): check 90.81 ms against 91.37 (−0.6 %), emit 52.75 against 52.48.
  - **Found:** CK-89 — the rows are per EXPORTED type, but an importer can compare a PRIVATE type
    reached through a `pub` scheme; v1 is right, v2's "resolve against the published context" has
    nothing to resolve against. Assigned to R8a by the manager, spec amendment first.
- **As built, review round (2026-09-25).** No blockers.
  - S1: `payload_params` read its payloads with a bare `Types.Builder`, with no schema lookup, so a
    parameter under `Page.Type a` or `Models.Page.Type a` read as `err` and was left out
    (`payload={}`, the unsafe side for D10). It uses `env.builder` now, whose schema expansion
    substitutes and never unifies, and an `err` payload sets every bit. Both declarations are in
    `blackbox_test.zig`'s raw-rows test, red with the old reader (`payload={}`) and green now.
  - N1: one status vocabulary, spec first (§14.2 *As built*, `checker.md` §7, the
    `Derived.Status` comments): `primitive` is new (§3.2's operator answers, where `own_method` had
    covered them and `Char` read `foreign`); the order is v1's own — primitive, own method,
    foreign (any arity), function, unanswerable. Pinned by the raw-rows test, on the program and
    on core's `Bool`, `Order`, `Char`, `List` and `Schema.Conversion`.
  - N2: `verify` takes the interner and checks the full `(param, method text)` order, refusing a
    pair twice, and ties `record_alias` to an alias row; the hermetic test covers each.
  - N3: `recordNames` caches the last alias's names. N4: the code's text names `schema` too.
    N6: the wide-form cache test edits `Wide` with `Main` cached — a private value (cut off,
    one module checked) and a new `pub` value (both checked), each run and its counts asserted.

### R4a — The v2 harness: moved driver, flag, cache key, `test-v2`, a stub checker

*Split from R4 on 2026-09-24 (review round 3). Nothing in this slice type-checks.*

- **Goal.** Everything v2 needs around it, landed with **no behaviour change**:
  - the driver is moved: `check2/Check.zig`, `Driver.zig` and `Incremental.zig` hold v1's scheduler,
    core gate and cutoff protocol, and v1's `Check.zig` calls the moved copy, so there is one
    scheduler;
  - the hidden `--checker=v1|v2` flag, where `v2` checks root-package modules and `v1` checks every
    non-root package (`checker-v2.md` §22.1);
  - the checker id in the cutoff key (`cache/Key.zig`, §14.3, S22);
  - the `test-v2` step (§2.4) with the `v2-green.txt` ratchet;
  - a v2 **stub** that reports `not_implemented` ("checker v2: R4b") for every root module.
- **Files.** `check2/Check.zig`, `Driver.zig`, `Incremental.zig`; `Cli.zig`, `Session.zig`;
  `cache/Key.zig`; `build.zig` (`test-v2`); `tests/pending/v2-expected.md`.
- **Closes.** Nothing. CK-15 in part: the cutoff protocol leaves `Check.zig`.
- **Exit criteria.**
  - The gates are green, and v1's behaviour is byte-identical: the whole corpus, the determinism
    test and the cache matrix.
  - `test-v2` runs, and reports every root-module fixture as `not_implemented`.
  - A cache-test scenario: a v1-written cache is never read by a `--checker=v2` build.
- **Reviewer focus.** The moved driver is a move, not a rewrite (`git diff -M`). The cache key
  really changes with the flag.
- **As built (2026-09-25).** Spec first: `checker-v2.md` §14.3 and §22.1 gained *As built by R4a*
  paragraphs, `fast-compiler.md` §8 the key amendment, `checker.md` §4.4 the scheduler's new home.
  - **The move.** `check2/Check.zig` is the public API (`run`, `Module`, `Options`, `Cutoff`,
    `stack_size`, moved whole from `check/Check.zig`); `check2/Driver.zig` the scheduler and core gate
    (a file-struct: `go`, `serial`, `buildSchedule`, `openCoreGate`, `worker`, `finish`, `check`,
    `checkInner`); `check2/Incremental.zig` `claim`, `compareKey`, `publish`, `verifyReads`,
    `install` and `closeCoreSurface`, as free functions over `*Driver` that `Driver` re-exports, so
    every call site still reads `d.claim(…)`. Bodies are byte-identical but for the 4-space dedent
    and `pub` (`git diff --color-moved --color-moved-ws=allow-indentation-change`); of the moved
    files' non-comment lines, only imports, the aliases and the v2 branch are not in 0aedf0a's
    `Check.zig`. `check/Check.zig` keeps v1's per-module check (`pub ModuleCheck`) and its tests;
    `Session` and `dump/types.zig` import `check2/Check.zig`. `checkInner` is the one place the
    checkers part: `Options.usesV2` — `--checker=v2`, the module's package `app`, and no `--core`.
  - **The flag.** `--checker=v1|v2` on `Cli.Common` (so `dump` takes it, like the round-trip flags),
    hidden, default v1; `Session.Options.checker`, `Check.Options.checker` and `root_is_core`.
  - **The key.** `checker_len: u32, checker` right after the build id in `writeOwn`, every module's
    key including core's; `key_version` 3. `cache_test.zig`: *row 10b* (`--checker=v2` moves every
    key, core's included; `--checker=v1` moves none) and *a cache written under one checker is
    never read under the other* (v1 cold, v2 twice, v1 again over one directory — v2 hits 0 then
    reads back only its own core entries, v1 hits all of its own; and a v2-first directory, over
    which v1 hits 0 and writes its own beside v2's). Both red with the two `writeOwn` lines removed.
  - **The stub** (`check2/Module.zig`): `not_implemented`, "checker v2: R4b", at the module's first
    token, on every root module that reaches it clean; silent on a module an earlier phase reported
    on or the graph poisoned, as v1 is (`checker.md` §4.3). It fills `Types.ref_ids` and, for
    `dump --stage=types`, `none`-filled tables; no scheme, so dumps print `<error>`. Deterministic
    at `--jobs=1` and `8`.
  - **`test-v2`** is `test-blackbox`'s part loop with `mode=report, checker=v2`. Report mode skips
    `tests/pending/v2-expected.md`'s fixtures (the four `core/` directories, N13; §20.4's two R11
    rows), prints `REPORT PASS/FAIL/SKIP` and a `REPORT TOTAL` per kind, and fails only for a red
    fixture of `v2-green.txt` (proved with a planted red fixture) or a `v2-green.txt` line that names
    nothing or a skipped fixture. At R4a: **297 pass, 445 fail, 13 skipped** of 755 fixtures
    (`run/`'s 166 counted once; both passes fail all 166). Every FAIL is the stub: each one's
    compiler output holds `not_implemented` and nothing it did not hold under v1 (32 generic
    `BuildFailed` lines re-run by hand, all `not_implemented` alone). The passes are the kinds that
    never check (`parse/good`, `fmt`, `bir`: 154) and the fixtures whose every root module is
    reported on first (`parse/bad` 119, `check/bad` 21, `check/depth` 2, `regress` 1). Those 143,
    which run the checker, are `v2-green.txt`'s first lines: v2 must stay silent where v1 is.
  - **`test-pending` run 2** (`BENI_CHECKER=v2`) is wired. Every one of the 64 pending fixtures is
    red under the stub, so rule (d) needed a `v2` line each; they are recorded wholesale in `RED`
    under a comment saying so (`not_implemented`, plus whatever an earlier phase reports), and
    R4b rewrites them. The scenarios of `pending_test.zig` still run v1 only.
  - **Evidence.** The three gates green; `test-pending`, `test-pending-perf` (all RED as recorded)
    and `test-perf` (CK-41 1.50) green. Bench (ReleaseFast, `--generate=100000`, medians of 7
    interleaved against 0aedf0a, two sets in opposite orders): check 92.75 against 91.08 (+1.8 %) and
    92.11 against 91.88 (+0.3 %); emit, untouched, 54.05 / 51.92 and 53.66 / 53.04.
- **As built, review round (2026-09-25).** No blockers.
  - S1: a `v2-green.txt` line must name a fixture: a `.beni` file or a project directory directly
    under a kind directory (or its `core/`, `emit/app/`, `emit/release/`). After each kind's walk,
    every line of either file that sits in that kind's directories must have been visited
    (`REPORT  STALE`). Planted lines fail the step: a golden (`….iface`), a `README.md`, a file inside
    a project (`Cycle/A.beni`), and the non-fixture directory `check/bad/core`.
  - S2: a `v2-expected.md` entry must be an existing fixture, or an existing `<kind>/core/` written
    with a trailing `/`, and it is validated before `v2-green.txt`. Planted entries fail the step: a
    stale fixture, the kind root `tests/corpus/check/`, and a project written as a directory.
  - S3: `checker-v2.md` §22.2 has an *As built by R4a* line on the ratchet. N1: every report-mode
    build or exit failure now carries the first diagnostic's message head
    (`build exit 1: NOT IMPLEMENTED YET: checker v2: R4b`). N2, N3: stale comments. N5: an *R9
    note* in §14.3 and a line in R9's goal. N8: §2.4 notes the scenarios run v1 only.
  - N4 is not a pure move, so it is recorded in R4b's goal instead. v1 round-trips the record
    before it fills `ref_ids`, and the table before `Cycles` and I7.
  - The owner's decision that v1 is frozen is recorded in §1 and in `checker-v2.md` §22.
  - Rerun: the three gates, `test-pending` (67 RED v1 lines including scenarios, 64 RED v2),
    `test-pending-perf` (all RED as recorded) and `test-perf` (CK-41 1.50) are green. `test-v2`
    exits 0: 297 pass, 445 fail, 13 skipped.

### R4b — v2 foundation: store, walks, unify, generalise, obligation-free constraint generation

- **Goal.** v2 checks every program whose root modules need **no dispatch and no obligation**.
  - The subset is computed by `tests/pending/v2-subset.sh`: fixtures whose v1
    `dump --stage=dispatch` has no `site` and only `evidence=0` declarations for root modules, and
    whose root modules' `dump --stage=bir` contains no `tuple_index`, `interp`, `try` or
    `Basics.eq`/`neq` call (S-5).
  - A root module outside the subset reports `not_implemented`, naming the slice (R5 or R6a).
  - *(Added by R4a's review, N4.)* `--roundtrip-interfaces` and `--roundtrip-dispatch` are applied
    inside v1's `ModuleCheck.run`, not in the shared driver, so they do nothing for a v2 module.
    They could not move into `Driver.check` as a pure move: v1 round-trips the record BEFORE it
    fills `Types.ref_ids`, and the dispatch table before `Cycles` and the I7 assert, so that those
    passes read bytes that went through the format. v2's `Module.zig` must call the same two hooks
    at the same points (§5: after P8 for the record, in P9 before `Cycles` for the table), or
    `iface_test`/`matrix_test` under `--checker=v2` will not round-trip v2's output.
- **Files.**
  - `check2/TypeStore.zig`, `Walk.zig`, `Unify.zig`, `Generalize.zig`, `Instantiate.zig` (explicit
    rank and pool, round 3 S-2).
  - `check2/constrain/Expr.zig`, `Pattern.zig`, `Decl.zig`: **every obligation-free form**, including
    `binders_end` and `.local` resolution (S-5: constraint generation is no longer R5's alone).
  - `check2/Solve.zig`: calls, `let`, groups, and §8.1's boundary without the default step.
  - `check2/Publish.zig`, `Report.zig`, `Module.zig`: P1, P2, P4 without resolution, P7, P8, P9.
  - The per-frame `touched` lists and `ready` queues (the queues are empty until R6a).
- **Closes.**
  - Claimed: CK-01, CK-04, CK-07, CK-13, CK-57.
  - `check/good/MutualGroupLocalTypes` (CK-09's dispatch-free half, moved here from R5: it has no
    obligation).
  - Structural: CK-10, CK-14, CK-15 (rest of the pipeline part).
- **Relies on** `checker-v2.md` §4.1, §4.3, §5, §6, §7, §8.1–§8.4, §14.1, §14.3, §15.1–§15.2, and
  I1–I4, I11–I16.
- **Exit criteria.**
  - The gates are green.
  - `test-v2` (report) is green on the v2-subset, and `v2-green.txt` is seeded with it.
  - `test-pending` is green, and the claims above are recorded.
  - `bench`: `--checker=v2` on a dispatch-free generated corpus is ≤ 1.10× v1 on the same.
  - The occurs-at-binders cost is measured and recorded (`checker-v2.md` §18): flat, and nested
    200-deep.
  - The CK-01 and CK-57 texts are specified in `checker.md` §8 first, then blessed (S20).
  - Guard `run/AnnotatedPolymorphicRecursion` (§5.1) is green under v2.
- **Reviewer focus.**
  - I2: grep for payload access outside `Walk.zig`, and check each walk's successor choice against
    `checker-v2.md` §4.1's table.
  - I1: an escape through a row variable, a nested `let`, a lambda-bound variable (`sk6` must stay
    an error), and a rigid unified with an outer rigid.
  - I4: a 100 000-deep type through every walk.
  - The failure bit: an error in one member of an SCC must skip exhaustiveness for all members.
  - §6.6 (N8): a recursive reference to an annotated binding instantiates its scheme.
- **As built (2026-09-25).** Spec first: `checker-v2.md` gained *As built by R4b* paragraphs in §4.1
  (the store is the shared type, `Flags` unchanged, I2 as enforced), §5 (the subset gate P0, the
  phases run, P9's order), §6.2 (generation in solving order; a `let` pattern is an SCC target),
  §7.1 (captures of structures, one module list), §8.1/§8.2 (binders only — §18's fallback), §15.1
  (v1's texts through a staging reporter) and §18 (the occurs measurement); `checker.md` §8.5 the
  two new texts. Found and fixed (claimed): **CK-90**, **CK-91**.
  - **The subset** is `tests/pending/v2-subset.sh`: the definition above plus **no `derived` row
    and no `type` declaration** (the eager rows of A.23 are P5, R8a's; a `--library` build exports
    them, so v2 without them would build a library silently smaller) and no `method_call`,
    `type_dispatch` or `where` in a root module's Bir (dispatch v1 wrote no site for because the
    module failed first). v2 applies the same rule itself (`Subset.zig`) and reports ONE
    `not_implemented` naming the latest slice the module needs (R5, R6a or R8a) at its first
    construct. 266 corpus fixtures after the three expected differences below.
  - **Files** (new, lines): `Context` 83, `Subset` 138, `Walk` 348, `Unify` 500, `Generalize` 283,
    `Instantiate` 330, `Solve` 428, `Report` 336, `Publish` 289, `Module` 399 (the stub replaced),
    `constrain/Tree` 338, `Expr` 255, `Pattern` 130, `Decl` 525 — 4 382 in all. `Driver.checkInner`
    passes v2 what v1 gets and records its counters. No `check2/TypeStore.zig` (§4.1 *As built*).
  - **Reused, not copied**: the store, `Render`, `Schemes`, `Types.Builder`, `Schema.State`,
    `SchemaPlanBuild`, `Exhaustive`, `Cycles`, `Convention`, `Constrain.sccGroups` (Tarjan) and
    `Diagnostics.Reporter`'s texts. Ported (rules verbatim, new structure): unification, the arity
    suite, `adjustRank` (now iterative), `makeCopy` (now iterative, two passes), `fillInterface`.
  - **Behaviour that differs from v1, all by the spec**: CK-01's escape, CK-04's binders, CK-07's
    text order, CK-13's one publication routine, CK-57's rendering, I12's failure bits (an error in
    one member of an SCC skips exhaustiveness for every member), §4.1's normalised records, CK-90's
    SCC edge, CK-91's tail loop. Three corpus goldens pin v1's side and are listed in
    `tests/pending/v2-expected.md` (R11 re-blesses them): `check/bad/InfiniteType.beni` (the region
    and text), `check/good/RecordExtChain.beni` and `check/depth/RecordExtTruncatedDeep.beni` (a
    record merge leaves no 65-link chain for the printer to truncate).
  - **Evidence.** The three gates green. `test-v2` (report): 295 checking fixtures pass (was 143;
    152 appended to `v2-green.txt`: `build/bad` 12, `build/bad-release` 4, `check/args` 27,
    `check/bad` 40, `check/depth` 11, `check/good` 14, `emit` 1, `emit/app` 1, `run` 42 — every
    subset fixture, plus 29 outside it that pass because v2 refuses or stays silent where v1 fails
    first). The 42 `run/` fixtures build byte-identical JavaScript under v1 and under `--checker=v2
    --jobs=8 --roundtrip-interfaces --roundtrip-dispatch`, and the 235 `check`-kind green fixtures
    print the same under v2 at `--jobs=1` and at `--jobs=8` with both round trips. `test-pending`
    green with 10 claims (CK-01 ×2, 04, 07, 09's good half, 13, 57, 90, 91 — all green under v2);
    every `v2` line of `RED` rewritten to v2's real answer. `test-pending-perf` and `test-perf`
    green (CK-41 1.50). `run/AnnotatedPolymorphicRecursion` green under v2, both passes.
  - **Bench** (ReleaseFast `zig-out/perf/bin/beni`, `check --no-cache --jobs=1 --self-profile`, the
    sum of the root package's `check` events, v1/v2 interleaved, medians of 7). The corpus is
    generated by a scratch script: 90 modules, 131 127 lines, each module a `type alias` of a record
    and 200 declarations cycling through eight shapes — an annotated arithmetic function with a
    nested `let`, a record update, `List.foldl`/`List.map` over lambdas, a `case` on `Maybe`, a record
    literal, a `let`-bound higher-order helper, a cross-module call and a `case` on a list — with no
    `==`, `<`, interpolation, `?`, tuple index or `type`; both checkers check it clean and publish
    identical interfaces. **v1 99.7 ms, v2 93.6 ms: 0.94×.** Also measured: 5 000 flat lambda
    declarations v1 24.6 / v2 22.2 ms; the nested 200-`let` program v1 126.3 / v2 162.0 ms (1.28×,
    not a criterion — the copying of 200 growing generalised records dominates it).
  - **The occurs cost** is `checker-v2.md` §18's *As built* table: as first written (binders and
    `touched`) it cost 11.8 % of bench, so R4b took §18's fallback (binders only, no walk into a
    leaf, no `binders_end` for a declaration's or `let` definition's own parameters): **2.8 %** of
    bench, 4.5 % flat, 2.7 % nested (medians of 15).
  - **Doubts, for the reviewer.** (1) The fallback gives up detecting a cycle no binder reaches
    (§8.2 *As built*). (2) The flat scenario stays at 4.5 %. (3) A `let` of 100 000 bindings whose
    types nest 100 000 deep takes about 75 s under BOTH checkers (each header's occurs walk is a
    fresh epoch over a type as deep as its position): Elm's placement is quadratic there, as v1's
    was. (4) `Flags.wants`/`obls` have no home yet (§4.1 *As built*). (5) `schemas.settleProperties`
    is still v1's (CK-40's cubic), called at v1's points, so plans match v1's byte for byte.
- **As built, review round (2026-09-25).** Two reviews (structural, adversarial); the manager's
  list, spec first (`checker-v2.md` §4.1, §5, §7.3, §8.2, §15.1, §15.2, §18, §19.1 *As built by R4b's
  review*; `checker.md` §8.2's third bound; the R5 and R6a briefs above):
  - **B1 / F2 (cycles in `unify`)**: `unify` is coinductive — a pair of non-variables already on
    its stack is assumed equal — so a cyclic or twice-built cyclic graph terminates in linear time
    and unifies; link-first was not taken, for the message quality children-first buys (§7.3 says
    why). `unifyRecord` stops at a field that fails `too_deep`; a `too_deep` looks for a cycle from
    both sides and reports `infinite_type`. `List.map2 [ c ] [ c ] same` is accepted again
    (`check/good/CyclicArgumentsUnify.beni`).
  - **S1**: a form the gate should have refused is `internal` (`Tree.Node.internal`), never a silent
    poison; `unify` refuses a constrained variable as `internal`. **S2**: `Category`, `Env`
    (+`Monomorphic`, `PlainMethod`) and `Scc` moved to shared files (pure moves, re-exported by v1's
    `Constrain.zig`), `Counters` to `check2/Check.zig`; `Diagnostics.zig` no longer imports
    `Constrain.zig`; `check2/rules_test.zig` refuses an import of v1's `Constrain.zig`/`Solve.zig`.
    **S3**: `Walk.constraints` is the one reading of a variable's constraints. **S4**: §8.2's text
    corrected; R6a owes occurs from wanted receivers and obligation variables. **S5**: the cycle
    drawn is found in field-name order (`Walk.firstCycle`). **S6**: children only through `Walk`
    (`Walk.function`, `fieldIn`, `.payload` successors), enforced by `rules_test.zig`. **S7**: P0's
    refusal goes through `Report.appendTo`. **S8 (the manager's decision)**: a module that declares
    a `type` is checked; its derived rows say `unchecked`; `js/Emit.zig` refuses a `--library` build
    of one under v2 (R8a); `v2-subset.sh` follows, and `test-v2` has a drift check (`REPORT DRIFT`:
    a fixture v2 does not refuse passes or is in `v2-expected.md`). **S9**: the flat case accepted
    in §18 with the reason. **S10**: an `infinite_type` and an escape are attributed to their own
    declaration; too-deep notes carry theirs and are reported before P7. Nits N1–N4 done (captures
    cleared per group, no `orelse 0`, `Report.failGroup`, the rank-is-depth assert); N5–N8 left.
  - **Adversarial**: F3 (every cycle reachable from a binder poisoned, one report), F4 (a cycle whose
    drawing shows a poisoned node is silent), F5 (the escaped rigid is poisoned too), F9 (an
    `infinite_type` does not gate exhaustiveness: `failed_patterns`), each with a pending fixture,
    claimed. F1 is **CK-92**, fixed in `Render` (a node budget per message; dumps unlimited): 300 MB
    → 37 KB on both checkers, pinned in `blackbox_test.zig`. F6 is **CK-93** (with the 75 s nit),
    F7 **CK-94**, F8 **CK-95**.
  - **Evidence.** The three gates, `test-pending` (20 claims), `test-v2` (331 checking fixtures
    pass; 36 appended to `v2-green.txt`; every one of the 313 subset fixtures passes; no drift),
    `test-pending-perf` and `test-perf` (CK-41 1.50) are green. The 51 green `run/`/`emit/app/`
    fixtures build byte-identical JavaScript under v1 and v2 (`--jobs=8`, both round trips); the 263
    green `check` fixtures print the same at `--jobs=1` and `--jobs=8`. Bench: v1 102.7 ms, v2
    96.8 ms, **0.94×**. Occurs cost: §18's re-measured row.

### R5 — Obligations: `tuple_index`, interpolation, the `equatable` marker, `?`

- **Goal.** Every non-method obligation, riding on its variables (§4.5), and §8.1's default step:
  - `tuple_index`, `interpolatable` and the `equatable` marker (the growable, payload-descending
    walk);
  - `?` as a deferred obligation (D2 as amended).
  - *(Added by R4b's review, S3.)* **Decide first, spec first: where `wants` and `obls` live.** v2
    reads v1's per-variable `Flags.constraints` today, through ONE accessor (`Walk.constraints`, and
    `Walk.child(.owned)`). v1 is frozen, so `Flags` cannot gain fields; v2-owned side columns indexed
    by root would leave `Schemes.Writer` and `Render` — shared, and reading `Flags.constraints`
    themselves — unable to publish or print requirements, forcing a fork of both. The choice (fork
    the store type with the writer and printer, extend `Flags` as a shared change, or side columns
    plus writer/printer hooks) is written into `checker-v2.md` §4.1 before any obligation code.
- **Files.** `check2/constrain/*` (the obligation-emitting forms); `check2/Solve.zig`
  (obligations, the default step); `check2/Instances.zig`, the marker-walk part only.
- **Closes.**
  - Claimed: CK-05, CK-06, CK-16, CK-51, CK-62, CK-68. CK-59 in part (generation order).
  - Structural: CK-18.
- **Relies on** `checker-v2.md` §4.5, §6, §8.1, §8.5, §8.6, §11.4, D2 (as amended) and D10.
- **Exit criteria.**
  - The gates are green.
  - `test-v2` is green on the widened subset, which now includes the obligation forms. `v2-green.txt`
    is updated.
  - Guard `check/bad/TryDefaultCycle` (§5.1) is green under v2.
  - `test-pending` is green, with the claims recorded.
  - `checker.md` §6.5's pointer note becomes "effective at R11".
- **Reviewer focus.**
  - D2's default (as amended, §8.6): a `?` whose both sides stay flex defaults to `Result` at **the
    boundary that owns its variables**, and only there. Try a `?` whose target is a `let_def` inside
    a declaration, and one whose variables escape its `let` to the declaration.
  - N-3 (round 3): a `let`-local `?` whose target escapes and whose subject is otherwise young must
    not over-lower the subject's success type.
  - I11: the solver must not see `local_var`. Use CK-09's `u`/`v` shape with 5 members and shuffled
    locals.

### R6a — The resolver, for `check`

*Split from R6 on 2026-09-24 (review round 3).*

- **Goal.** Everything a `check` needs to type a dispatching program:
  - wanteds and givens;
  - instance lookup by head matching, the well-known table, the `number` bridge (flex and rigid,
    with unification), structural shapes;
  - promotion and the proven-undetermined default;
  - cycle-safe walks and the lineage rule;
  - per-frame `ready` queues **drained after every constraint node** (round 3, B-1).
  - *(Added by R4b's review, S4.)* §8.1 step 4 also occurs-checks the receiver of every wanted riding
    on the frame's pool, and every variable of every obligation (R5): the CK-03 / row 76 coverage
    R4b's binders-only fallback (§8.2 *As built*) no longer gives; and step 7's debug assert is
    restated over the receivers it defaults.

  Not covered: an unannotated own method used before its group (R7), derived contexts of own
  nominal types (R8a; until then, v1's one-entry-per-parameter rule), and P6 (R6b). A dispatching
  root module under `build` reports `not_implemented (R6b)`.
- **Files.** `check2/Resolve.zig`, `check2/Instances.zig` (lookup, matching, and spike §1.2's **direct** `private_method` only; D1's reach through derivation is R8b's, round 4 S4-5),
  `check2/Evidence.zig` (tables, canonical order), `check2/Module.zig` (P3).
- **Closes.**
  - Claimed (`check` fixtures): CK-02, CK-03, CK-20, CK-21, CK-48, and CK-09's
    `check/bad/MutualGroupLocals`.
  - CK-55 in part (the category).
  - CK-37 in part: the class flag, and `RejectedReceiverDoesNotSilence`.
  - Structural: CK-35. Perf scenario CK-42.
- **Relies on** `checker-v2.md` §4.2–§4.3, §9, §12.1, I5–I8, D9.
- **Exit criteria.**
  - The gates are green.
  - `test-v2` (report) is green on every `check/*` fixture whose root modules use no unannotated own
    method early and no own derived context that differs from v1's.
  - The `where` blocks of every `core` and corpus interface (`--stage=raw`) are byte-identical under
    both checkers (N10).
  - Guards `ConstrainedBinderNotCyclic` and `LetHelperOuterArgument` (§5.1) are green under
    `check`.
  - `test-pending` is green, with the claims recorded.
- **Reviewer focus.**
  - Matching with specialised receivers (row 72's `ConstructorSpecialized*`).
  - The lineage rule: row 76's growth must be `infinite_type`, with no false hit on a deep
    `List (List (Box a))`.
  - No resolver walk without colours, and none over `owned` successors.
  - The `number` bridge on a **rigid** (`abs`, `max`, `DecodeInto`'s `sameNum`), with and without a
    lying `where` clause.
  - Eager draining: `rq2` (§5.1) and a wanted readied by an inner `let`'s unification.

### R6b — Elaboration, `dispatch/` parity, `build`

- **Goal.** P6 elaboration into the §13 trees, so v2 builds dispatching programs.
- **Files.** `check2/Evidence.zig` (elaboration), `check2/Module.zig` (P6).
- **Closes.** Claimed (`run/` fixtures, which need `build`): CK-08, CK-27, CK-28, CK-29, CK-32.
  CK-11 stays green under v2 (S7).
- **Relies on** `checker-v2.md` §12.2, §13, I6, I7.
- **Exit criteria.**
  - The gates are green.
  - `test-v2` (report) is green on every fixture R6a covers, now including `run/` and `dispatch/`.
  - The `dispatch/` goldens under v2 are identical to v1's except in the listed CK fixtures.
  - The dispatch-heavy medians of `checker-v2.md` §18 are ≤ 1.10× v1.
  - `test-pending` is green, with the claims recorded.
- **Reviewer focus.** I5 and I7 on nested evidence (`TwoSlotsNested`, `NestedEvidenceIndices`,
  `List (List (Box a))`). An `open` wanted at P6 must be `internal`, never a structural answer.

### R7 — Own methods without a scheme; evidence inside binding groups

- **Goal.** Everything priority groups did, done without them:
  - `checker-v2.md` §10: **nesting at demand** (a use of an unchecked own group checks it at once,
    in a fresh frame), in-flight links for unannotated members, and merging of **top-level** frames
    on dispatch or value back-edges, with no defaults in merged frames;
  - §12.3: group-call elaboration with per-member lists and the `undetermined` case 3;
  - §10.2's cumulative nesting budget (S-4), per-frame `touched` lists (S-3), and a `checkGroup`
    that returns merged sending the demand down the in-flight path (S-1);
  - **D14**, §10.7: canonical pessimism in recursive groups, with the annotation hint.
- **Files.** `check2/Groups.zig` (effective status, frames, nesting, merge), `check2/Resolve.zig`
  (in-flight links), `check2/Evidence.zig` (group calls), `check2/Solve.zig` (frames, reference
  recording).
- **Closes.**
  - Claimed: CK-30, CK-31, CK-36, CK-63, CK-64, CK-65, CK-66, CK-70, CK-72, CK-73.
  - `method_needs_annotation` is emitted by v2 only for §11.2's case, which is R8a's. `language.md`
    §10's catalogue row is amended in this slice to say so. The enum entry is kept.
- **Relies on** `checker-v2.md` §6.6, §8.1, §9.1, §10 (including §10.7), §12.3, D3, D11 as amended
  (§21.1), and D14.
- **Exit criteria.**
  - The gates are green.
  - `test-v2` (report) is green on everything except derived-context differences (R8), and
    `v2-green.txt` is updated.
  - The **permutation scenario** (§2.5), new in `pending_test.zig` and claimed. For each program,
    every permutation of the top-level declarations (capped at 120) under v2 exits 0 and prints the
    oracle-twin output (I9, S13). The programs:
    - `o1`, `row75`, `box`, `m1b`, `p5`;
    - four mutually dispatching own methods;
    - every `run/` fixture of CK-63 to CK-66;
    - the §6 guards `OwnMethodAnnotatedOrFirst`, `OwnMethodValuePrefixOrdered` and
      `OwnMethodInScrutineeOrdered`;
    - round 3's `rq1`/`rq2` (CK-73 and its guard), `capt`, and the annotated `sccA`/`sccB`
      (`RecursiveGroupAnnotatedReceiver`);
    - a 3-cycle of own methods, and a member that demands the cycle at two nodes (§23 item 8).

    `RecursiveDispatchTwoTypes` (CK-70) and `RecursiveGroupReceiverNeedsAnnotation` (CK-72, the
    D14 refusal with its hint) instead give the same single diagnostic, byte-identical, in every
    permutation.
  - **Nesting scenarios** in `pending_test.zig` (S-3, S-4):
    - a generated chain of *n* own methods written in reverse dependency order, checked with a
      best-of-3 ratio t(2n)/t(n) ≤ 2.5 below the nesting budget;
    - the same chain above the budget, which must report exactly one `nesting_too_deep` (with the
      annotation hint), never crash, and finish within the ratio bound;
    - `nest_cost` calibrated from a measured stack-per-nesting figure and recorded in the diary.
  - `test-pending` is green.
- **Reviewer focus.**
  - §10.4's merge: construct a chain `A`'s method → `B` → `C` → a use of `A`'s method, and confirm
    one generalisation. Confirm that a `let` frame inside a merged frame still generalises its own
    variables (CK-65's `g`).
  - A merged frame must not default a `?` (CK-65's `am`/`bm`).
  - A reference to an **annotated** member of a `checking` group must instantiate its scheme and
    must not merge (`AnnotatedPolymorphicRecursion`, §6).
  - A nested check started from a `let` two levels deep: the nested group's `--stage=types` must be
    byte-identical to the one produced when the group is written first.
  - `checker-v2.md` §23 items 1, 7, 8 and 9.
  - D14: the hint names the member the receiver came from. With that member annotated, the program
    is accepted in both orders.
  - Per-frame queues: a nested group must never drain its demander's queue (round 3's merge variant
    of `rq1`, CK-73).

### R8a — Derived contexts: the fixpoint, D4, P5, publication, install

*Split from R8 on 2026-09-24 (review round 3).*

- **Goal.** `checker-v2.md` §11.1–§11.2: the memoised fixpoint (D4) replaces R6a's temporary rule.
  This covers:
  - the in-flight branches, the closed payload filled like a group call, and the parametric one
    refused;
  - fresh fixpoints on re-entry (round 3, B-2);
  - memo generations (S-6);
  - eager rows in P5;
  - contexts published in the interface, which the install path reads without recomputing.
- **Files.** `check2/Instances.zig` (the fixpoint), `check2/Module.zig` (P5), `check2/Publish.zig`,
  `check2/Incremental.zig` (install).
- **Closes.**
  - Claimed: CK-23, CK-25, CK-67, CK-69, CK-74.
  - Structural: CK-26.
  - Perf scenario CK-40.
  - Row 72's fixtures stay green: they are the regression controls for "a payload's public method is
    a boundary".
- **Relies on** `checker-v2.md` §11.1–§11.2, §14.2, D3 and D4 as amended.
- **Exit criteria.**
  - The gates are green.
  - `test-v2` (report) differs from v1 only on `tests/pending/v2-expected.md`'s list: the `emit/`
    goldens of phantom or nested-requirement types, each with a reason.
  - A cold-versus-warm cache matrix under v2 is byte-identical.
  - CK-67, CK-69 and CK-74 are in the permutation scenario (both declaration orders).
  - `test-pending` is green.
- **Reviewer focus.**
  - Re-entry: the `same`-first and `key`-first orders of CK-74 must give the same `key` scheme.
  - A context computed while a dependency was in flight must never be memoised past its generation.
    Use a trace counter in a unit test.
  - The fixpoint on mutually recursive types with a function payload behind a custom method
    boundary (`e10` shape).

### R8b — Privacy (D1) and schema endpoints

- **Goal.**
  - §11.3: the private-method rule.
  - §11.4–§11.5: `payload_params` in the marker walk, and schema endpoints and wrappers through the
    same fixpoint. `Schema.settleProperties` is deleted from v2's path.
- **Files.** `check2/Instances.zig` (privacy; endpoints), `check/Schema.zig` (properties from the
  memo).
- **Closes.** Claimed: CK-22, CK-24.
- **Relies on** `checker-v2.md` §11.3–§11.5, D1, D10; `schema.md` §3–§4.
- **Exit criteria.**
  - The gates are green.
  - `test-v2`'s expected-difference list gains only fixtures whose expectation D1 changes, each with
    a reason.
  - `test-pending` is green.
- **Reviewer focus.**
  - D1 coherence across three modules: a private `eq` in `A`, a wrapper in `B`, a comparison in `C`.
  - The absent reason shown at the use.
  - `payload_params` for an imported opaque type with a phantom parameter.

### R9 — v2 checks `core`; `test-v2` strict; parity

- **Goal.** `--checker=v2` covers every package. `test-v2` becomes **strict**: failure on anything
  outside `v2-expected.md`. The determinism test (`--jobs` 1 and 8, twice) and the 600-module
  scenario run under v2 too. Pipeline cleanup: `schema_plan_ok` after `Cycles`, named profile
  events. The cache key's checker text changes, or `key_version` bumps (`checker-v2.md` §14.3,
  *R9 note*).
- **Files.** `check2/*` (whatever `core` exposes), `tests/blackbox/*` (the v2 variants of the
  determinism scenarios, behind `BENI_CHECKER`).
- **Closes.** CK-15 (rest). Every claim from R4b–R8b now also holds with `core` under v2.
- **Relies on** `checker-v2.md` §17, §18.
- **Exit criteria.**
  - The gates are green. `test-v2` is strict and green.
  - `bench` check phase and the three medians are ≤ 1.10× v1.
  - `core`'s interfaces under v2 are byte-identical to v1's except for the context rows of types
    D4 changes. Expected: none in `core`, per `checker-v2.md` §23 item 4.
- **Reviewer focus.**
  - Byte-compare every `core` interface (`raw`).
  - Run `bench/corpus` under both checkers and diff the emitted JavaScript. The diff must be empty
    except D4's listed functions.

### R10 — Incrementality under v2

- **Goal.** The M4 machinery under v2: cutoff keys, dependency digests, the install path, and the
  cold/warm × jobs matrix.
- **Files.** `check2/Incremental.zig` and the `cache_test`, `cutoff_test` and `matrix_test` v2
  variants.
- **Closes.** No new CK. It proves I10 on the hit path.
- **Relies on** `fast-compiler.md` §8, `checker-v2.md` §14.3.
- **Exit criteria.**
  - The gates are green.
  - Every cache, cutoff and matrix scenario is green with `BENI_CHECKER=v2`.
  - adv's `k1`–`k8` cache probes are identical under v2, warm and cold.
- **Reviewer focus.** A dependency whose derived context changes (a function payload added) must
  invalidate dependents' evidence, not only their types.

### R11 — Cut-over

- **Goal.**
  - `--checker` defaults to `v2`.
  - Every `CLAIMED` fixture is promoted (`.codes` → blessed `.diag`, reviewed) and `CLAIMED` is
    emptied.
  - Every fixture in `v2-expected.md` is re-blessed with its reason in the commit.
  - `checker.md` and `static-dispatch-spike.md` pointer notes switch from "superseded when R11
    lands" to "superseded".
- **Files.** `Cli.zig` (default), `tests/corpus/**` (promotions and re-blesses), `tests/pending/**`,
  `docs/design/*`.
- **Closes.** Promoted: every CK claimed in R4b–R8b.
- **Exit criteria.**
  - The gates are green **under v2**, and `test-pending` is green.
  - `test-pending` rule (b) now applies to v2, so nothing green is left in `tests/pending/` except
    what R13 and R14 own.
- **Reviewer focus.** Every re-blessed golden has a CK or D reason, and no golden was re-blessed in
  bulk.

### R12 — Delete v1

- **Goal.**
  - Delete v1's `Solve.zig`, `Constrain.zig`, the capability code in `Types.zig`, and `Check.zig`'s
    `ModuleCheck`.
  - Rename `check2/` to `check/`.
  - Delete `--checker`, `BENI_CHECKER`, `test-v2`, run 2 of `test-pending`, and the checker id in the
    cutoff key.
  - Re-measure `bench`.
- **Files.** `src/check/**`, `build.zig`, `Cli.zig`, and the design documents' layout sections
  (`checker.md` §3).
- **Exit criteria.**
  - The gates are green.
  - `bench` check phase ≤ 1.0× the `7427828` figure is the target. Anything over 1.10× is a finding
    for the queue.
  - No file in `src/check/` over about 1 500 lines.
  - A diary entry with the final numbers.

### R13 — Diagnostic quality

- **Goal.** `checker-v2.md` §15.3–§15.4's message work. Each message is specified first as an
  amendment to `checker.md` §8 or `static-dispatch-spike.md` §10, then implemented.
- **Closes.** Promoted: CK-49, CK-50, CK-52, CK-53, CK-54, CK-55 (text), CK-56, CK-58, CK-59 (text),
  CK-60.
- **Relies on** `checker.md` §8 (amended by this slice).
- **Exit criteria.** The gates are green. Each fixture is promoted, and each other `.diag` whose text
  changed is re-blessed with the CK in the commit.
- **Reviewer focus.** Every changed message against Elm's for the same mistake.
  `references/talks/` has none of this; use `elm/compiler`'s reporting when it is vendored.

### R14 — Constrained `let` helpers generalise (D5)

- **Goal.**
  - Delete the `let_constrained_monomorphic` switch.
  - A `let` binder gets evidence parameters (`Binder.let_def`, `LetInfo`, `$l<inst>$<k>`).
  - `backend.md` §4's constrained-declaration row and `static-dispatch-spike.md` §8.1 are amended
    first.
- **Files.** `check/Generalize.zig`, `check/Evidence.zig`, `check/Dispatch.zig` (`lets`),
  `js/Lower.zig` (`let` functions with evidence), `dump/dispatch.zig`.
- **Closes.**
  - CK-37 (rest: row 76's trigger is gone).
  - `check/bad/LetConstrainedTwice` and `check/bad/LetHelperCyclicReceiver` change expectation
    (`checker-v2.md` §20.4).
  - The `abuse_test.zig` row-76 scenario now expects exit 0 within the bound.
- **Relies on** `checker-v2.md` §8.4, §13, D5.
- **Exit criteria.**
  - The gates are green.
  - New `run/LetConstrainedHelperPolymorphic.beni` (the row-76 program printing both results, and
    `show` at two types that both have `render`), fail-first.
  - `emit/` gains one golden showing `$l<inst>$0`.
- **Reviewer focus.**
  - CK-02's program must **stay** a `type_mismatch`: its requirement sits on an outer receiver.
  - An inner binder's evidence captured by a lambda, two closures down (the `EvidenceCapture`
    shape, at `let` level).

### R15 — Structural audit (added by the manager, 2026-09-24)

- **Goal.** Black-box fixtures prove behaviour, not structure: a checker that counts evidence in
  twelve places that happen to agree passes the same corpus as one that counts it once. After
  R12 (v1 deleted) and R14, re-run the five original reviews (core, static dispatch,
  orchestration, adversarial, and the Roc comparison) against v2, fresh, read-only.
- **Checks.** Every root-cause class K1–K15 is absent by construction: each invariant I1–I16
  has one owner in the code and, where §2 of `checker-v2.md` says so, a Debug assert; no module
  outside `Resolve` creates evidence; `unify` resolves and reports nothing; one capability
  fixpoint; one publication routine; no fixed stack that answers "yes"; file sizes as
  `checker-v2.md` sets them. The adversarial pass writes new probe programs, not the old ones.
- **Exit.** Every finding becomes a CK entry (next free ID) with a fixture and a slice; the
  audit closes when none is structural or unsound.

---

## 4. CK → slice index

| Slice | Promotes into `tests/corpus/` | Claims (v2, promoted at R11) | Structural / no fixture |
|---|---|---|---|
| R0 | — | — | records everything |
| R1 | CK-11, 17, 19, 43, 44, 45, 46, 47, 71 | — | CK-12 (unit test); CK-78 (a decision, with a guard) |
| R2a | CK-81 (v1 `Print`, manager 2026-09-24) | — | CK-61 |
| R2b | CK-33, 34, 84 (found and fixed by R2b) | — | CK-85 (guard only; fixed in R8a, owner 2026-09-25), CK-86 → R13 (pending fixture) |
| R3 | CK-38, 39; CK-41 (into `perf_test.zig`, `test-perf`) | — | CK-89 found (a private type's derived context is published nowhere) → R8a |
| R4a | — | — | CK-15 (the cutoff protocol leaves `Check.zig`) |
| R4b | — | CK-01, 04, 07, 13, 57; CK-09 (`check/good` half); CK-90, 91 (found and fixed by R4b) | CK-10, 14, 15 (pipeline part); CK-92 (fixed in `Render`, in the gates); CK-93 → manager, CK-94 → R13, CK-95 → R12 (found by R4b's reviews) |
| R5 | — | CK-05, 06, 16, 51, 62, 68 | CK-18; CK-59 (part) |
| R6a | — | CK-02, 03, 09 (`check/bad` half), 20, 21, 42, 48, 80 | CK-35; CK-37, 55 (part) |
| R6b | — | CK-08, 27, 28, 29, 32 | — |
| R7 | — | CK-30, 31, 36, 63, 64, 65, 66, 70, 72, 73, 76 | — |
| R8a | — | CK-23, 25, 40, 67, 69, 74, 75, 77, 79 (the field cap lifts with D4's signature; manager 2026-09-24) | CK-26; CK-82 (with CK-79); CK-85 (owner 2026-09-25); CK-89 (R8a, manager 2026-09-25: amend §14.2 so derived rows cover every nominal type reachable from a published scheme, before R8a reads them) |
| R8b | — | CK-22, 24 | — |
| R9 | — | — | CK-15 (rest) |
| R11 | all claims above | — | — |
| R13 | CK-49, 50, 52, 53, 54, 55, 56, 58, 59, 60, 86 | — | — |
| R14 | CK-37 (rest) | — | — |
| (assigned 2026-09-24) | — | — | CK-81 is R2a's and CK-79 is R8a's (manager) |
| (assigned 2026-09-24) | — | — | CK-82 → R8a (with CK-79); CK-83 → R2c, a new backend slice after R2b (manager) |
| (found by R2c, 2026-09-25; assigned by the manager: CK-87 → R8a, CK-88 → R12) | — | — | CK-87 (derived `==` past 32 nested record levels is `internal`) and CK-88 (a `case` of many literal branches: quadratic emit, and past 65 046 a `switch` Firefox refuses): unassigned, for the manager |

Every one of the 95 entries appears in this table, CK-75 (a performance finding added after R0) included: the manager assigned it to R8a on 2026-09-24 (to R10 if R8a's profile shows the residue is `dep_digest`). CK-71 (R0's: `Session` symbol ids depend on thread timing) was assigned to R1 on 2026-09-24. *Updated 2026-09-24 for round 3: the slice
splits and CK-72 to CK-74. `checker-findings.md`'s per-entry "Slice" fields name the unsplit slice.
This table is authoritative.*

---

## 5. Fixtures from the design reviews' counterexamples

Every counterexample from review rounds 1 and 2 (`review-design.md`, `review-design-2.md`) that is a
**valid** program, or a program that **must be refused**, is a planned fixture. Each was run on the
`7427828` binary. Its sources are in the session scratchpad at `ck/r2/<probe>/Main.beni`, written in
valid beni:
- a method call takes at least one argument besides its receiver, because `x.m` alone is a field
  access, so the programs use `.size ()`;
- `Maybe.withDefault` is subject-first;
- recursive examples are made to terminate.

### 5.1 v1 gets it right: regression guards for v2, straight into `tests/corpus/`

These are green on v1, so they go into the live corpus now, which the gates run. From R4, `test-v2`
holds v2 to them. R0 adds them. The **slice** column is the first slice whose `test-v2` subset must
include each one, and the `v2-green.txt` ratchet protects it from then on.

| Fixture (`tests/corpus/…`) | Probe | Asserts | Slice |
|---|---|---|---|
| `run/ConstrainedBinderNotCyclic.beni` | `b1eq` | `f x y = x == y`, and `Basics.eq x y` under `x == y`, are not cyclic and not "a function inside" (B1) | R6 |
| `check/bad/TryDefaultCycle.beni` + `.diag` | `b3cyc` | `f x = let y = x? in if True then y else x` is `infinite_type` (B3) | R5 |
| `run/OwnMethodAnnotatedOrFirst.beni` | `b6box`, `b6boxU2` | the `let`-nested `size` use checks when `size` is annotated, or written first | R7 |
| `run/OwnMethodValuePrefixOrdered.beni` | `b7R` | CK-64's program in the order `eq`, `helper`, `use` | R7 |
| `run/OwnMethodInScrutineeOrdered.beni` | `n3boxR` | CK-63's `makeBox`/`map2` program, with the methods first | R7 |
| `run/AnnotatedPolymorphicRecursion.beni` | `n8rec` | `depth : List a -> Int` using `depth [ 1 ]`, top-level and in a `let` (N8) | R4 |
| `run/WideRecordEqInts.beni` | `s9` (= `WideEq2`) | `Basics.eq` on a 300-field all-number record prints `eq` (S9) | R1 |
| `run/LetHelperOuterArgument.beni` | `snew4` | `g y = y.combine x` used twice at `T` (S-new-4; stays green through R14) | R6 |

### 5.2 v1 gets it wrong: new CK entries, into `tests/pending/`

| CK | Fixture (`tests/pending/…`) | Probe(s) | Slice |
|---|---|---|---|
| CK-62 | `run/TryDecidedByLaterFacts.beni` | `b3ready`, `n2try` | R5 |
| CK-63 | `run/OwnMethodDemandedEarly.beni` | `b6boxU`, `b6letann`, `n3box` | R7 |
| CK-64 | `run/OwnMethodValuePrefix.beni` | `b7prefix` | R7 |
| CK-65 | `run/MutualDispatchMethods.beni` | `n4ambm`/`n4R`, `n5sw`/`n5R` | R7 |
| CK-66 | `run/GroupVariableOutsideCaller.beni` | `n7grp` | R7 |
| CK-67 | `run/DerivedContextClosedOwnMethod/` | `s1n`, `s1n2` | R8 |
| CK-68 | `check/bad/TupleIndexOuterResult.beni` (`.codes`) | `n1tup` | R5 |
| CK-69 | `check/bad/DerivedContextNeedsAnnotation/` (`.codes`) | `s1p` | R8 |
| CK-70 | `check/bad/RecursiveDispatchTwoTypes.beni` (`.codes`) | `s17` | R7 |

R0 writes these nine with the rest of the pending set, and records their red signatures in
`tests/pending/RED`.

### 5.3 Not a fixture

- **Round 1 S1's original example** (`type U a = U (T a)` beside an unannotated `T.eq`). It cannot
  occur under the module rule: `U`'s `eq` is `T.eq`. CK-69 replaces it.
- **Round 2's programs as literally written**, with nullary dot-calls. They are field accesses, and
  v1 refuses them correctly. The corrected forms above are the fixtures.

### 5.4 Round 3 (`review-design-3.md`; probes in the scratchpad at `ck/r3/` and `ck/r3x/`)

These were run on the `7427828` binary.

**Guards (v1 correct), into `tests/corpus/`:**

| Fixture | Probe | Asserts | Slice |
|---|---|---|---|
| `run/ScrutineeMethodFirst.beni` | `rq2` | a `case` scrutinee's own method, written before its use, lets a later `let` helper generalise: `{ a = 3, b = 3 }` for `f 3` | R6a (`check`), R6b (`run`) |
| `run/SingleMemberGroupReceiver.beni` | `capt` | D14 leaves single-member groups alone: prints `{ a = 4, b = 4 }` | R6b |
| `run/RecursiveGroupAnnotatedReceiver.beni` | `sccA`/`sccB` with `g : Int -> Box Int` | the annotated form is accepted in both orders, printing `{ a = Box 1, b = Box 1 }` | R7 |

**New CK entries (v1 wrong), into `tests/pending/`:**

| CK | Fixture | Probe(s) | Slice |
|---|---|---|---|
| CK-72 | `check/bad/RecursiveGroupReceiverNeedsAnnotation.beni` (`.codes`: one `type_mismatch` at `q "s"` containing "Annotate `g`"), plus its reordered twin `…ReceiverNeedsAnnotationB.beni` | `sccA`, `sccB` | R7 |
| CK-73 | `run/ScrutineeMethodLater.beni` (prints `rq2`'s output), plus `check/good/ScrutineeMethodMergeVariant/` for the merge variant, whose second `(Box "s").g ()` must check in both orders | `rq1` | R7 |
| CK-74 | `check/bad/DerivedContextReentrant/` (`H.beni`, `Main.beni`; `.codes`: one `type_mismatch` at `"s"` in `other`), plus the twin with `same` written first | `reentK`, `reentS` | R8a |

**Scenarios, in `tests/blackbox/pending_test.zig`:**
- **R7:** the reverse-ordered method chain, under and over the nesting budget (S-3, S-4).
- **R7:** the extended permutation scenario (see R7's exit criteria).

### 5.5 Round 4 (after R0; 2026-09-24)

- **New guards into `tests/corpus/`** (v1 already correct; probes in the scratchpad at `ck/r4/`):
  - `run/PrivateEqInsideModule/`: CK-22's inside half, D1 as amended. It prints `true`, `true`.
    Slice R8b keeps it green.
  - `check/bad/CyclicReceiverReportedOnce.beni`: one `infinite_type` at 2:7 of the probe, 7:7 in the
    fixture after its intent comment (`checker-v2.md` §9.5).
    R6a keeps it green.
  - `check/bad/RejectedReceiverDoesNotSilence.beni`: two `unknown_method`s and one `type_mismatch`.
    R6a keeps it green.
- **CK-73's merge variant is split** (see its entry). R0's `check/good/ScrutineeMethodMergeVariant/`
  becomes:
  - `check/bad/ScrutineeMethodMergeD14/`, the modules as written, refused by D14 with the hint;
  - `check/good/ScrutineeMethodMergeVariant/` without the `q` helper.

  R7 does this, or R0 in a follow-up. *Done by the R0 follow-up, with the three guards above.*
- **CK-47's `.codes` is confirmed** as written (D8 as amended).

### 5.6 Design review round 4 (`review-design-4.md`; probes in the scratchpad at `ck/r4rev/`)

These were re-run on the `7427828` binary. The first line of each fixture names its CK, as usual.

| Probe(s) | v1 | Expected under v2 | Where | CK | Slice |
|---|---|---|---|---|---|
| `evA` / `evB` (instantiation evidence on another member's result) | INTERNAL / runs | in both orders, one `type_mismatch` at `q "s"` with the D14 hint "annotate `g`" | `tests/pending/check/bad/RecursiveGroupEvidenceReceiver/` (both orders as two modules; `.codes`) | CK-76 (CK-72 family) | R7 |
| `subA` / `subB` (sub-wanted of an inline resolution on a young receiver) | INTERNAL / runs | the same | `tests/pending/check/bad/RecursiveGroupSubWanted/` | CK-76 | R7 |
| `xm` / `xm2` (derived contexts that depend across `eq` and `compare`) | refused in both orders (NOT EQUATABLE, NO METHODS HERE) | stays refused, with the same codes | `tests/corpus/check/bad/DerivedCrossMethodCycle/` (**guard**, `.diag` blessed from v1) | — | R8a keeps it green |
| `cbA` / `cbB` (a closed in-flight derived query from another group) | NOT EQUATABLE in both | in both orders, one `type_mismatch` at `pick "s"` | `tests/pending/check/bad/DerivedContextMergesAsker/` (`.codes`) | CK-77 (CK-67 family) | R8a |

The R7 permutation scenario gains `evA`/`evB` and `subA`/`subB`, each the same single diagnostic in
every order. R8a's permutation list gains `cbA`/`cbB` (the same `type_mismatch` in both orders) and
`xm`/`xm2` (the same refusal in both orders).

The R7 nesting scenarios gain **a pair of deep declarations**: a method about 2 500 levels deep,
used about 2 500 levels deep in another declaration. In the order that nests, it must give exactly
one `nesting_too_deep`, at the use and with the hint, and never a crash. In the other order it must
check (`checker-v2.md` §10.2, R7-3).
