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

### 1.1 v1's six root causes — the acceptance table (added 2026-09-26, R8b's review round)

Every slice's reviewer fills in the row of a cause the slice touches: `closed`, `open (owner)` or
`regressed` (a regression blocks the slice). The classes are `checker-v2.md` §1's.

| # | v1 root cause | Mechanism in v2 | Status by slice |
|---|---|---|---|
| 1 | Evidence computed in many places | One evidence tree per site (§13.1), recorded when each requirement is created (§12.1); `Lower` stops counting (R2a); one calling convention (R2b); one elaboration pass, P6 (R6b) | R2a–R2b the backend's half; closed in v2 by R6b |
| 2 | Constraints repaired by side tables | Obligations and wanteds ride on their variables (§4.5, I15); unify joins and readies, never resolves (§7.1) | R4b–R5 obligations; closed by R6a (wanteds) |
| 3 | Own-method ordering | Nesting at demand, back-edge merges (§10.2–§10.4); `scenario/PERM` | closed by R7; held by R8a. R8b's first review round left two order dependences PERM did not see — the marker gate read an unchecked schema's `via` target (CK-120) and a derived context took its asker's step budget (CK-125) — both fixed in its round 2, with PERM counting every refusal |
| 4 | Capability computed several ways | One verdict (`Derivable`, R6a), one derived-context fixpoint (`Contexts`, R8a), published rows, no settle | R6a one verdict (its review caught two ways creeping back); R8a closed nominal `type`s; R8b closed schema endpoints and D1's rows; R8b's review rounds closed the marker gate (CK-120: it demands the schemas it walks and defers one in flight to P5) and made the fixpoint's graph exact and incremental (CK-119). Residue: a record the OLD checker wrote (another package's module) is read through v1's ABI and table bits, until R9 |
| 5 | Generalisation ignoring constraints | Ranked boundaries that decide obligations and promote requirements (§8.1, §8.5); the fixpoint frame discarded whole (§11.2, CK-117's assert since R8b) | closed for top-level groups by R4b–R6a; open for constrained `let` helpers (D5): R14 |
| 6 | Backend answering holes | The checker answers every wanted or says `internal` (I6–I8); `Lower` reads the record, fills nothing (§13.3); `refuseV2LibraryTypes` deleted (R8a) | closed in v2 by R6b and R8a; v1's path deleted at R12 |

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
a red fixture. *(R7, 2026-09-26:)* the scenarios run under `--checker=v2` too, in both
steps (the `perf` one after the default checker's, never beside it), so a claimed scenario
(`scenario/PERM`, `NEST-*`) is held to rule (c); a scenario red under v2 has a `v2` line in `RED`
(CK-40 and CK-88 are, and are R8a's and R12's).

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
  | NEST-UNDER | 40 chains of 250 / 500 methods (R7) | red by its codes, not by time | v2 on R7: 77 / 151 ms, 1.96 |
  | CK-88 (added by R2c) | 3 000 / 6 000 `case` branches, `build` | on R2c: 204 / 789 ms, 3.86 | none |

  The whole step takes about 22 s once its ReleaseFast compiler is built (and about 95 s more when
  `src/` changed since the last build). One finding of the recalibration: with CK-40's reference
  fix the schema program is linear only up to about 800 schemas — 1 000 / 1 600 take 77 / 158 ms —
  so CK-40's fix, when R8a writes it, should be measured past that too.
  *R8c (2026-09-26):* `scenario/CK-42` under `--checker=v2` takes 32 000 / 64 000 declarations and
  the best of 7 runs per point (v2's extra was about 10 ms at 4 000, so its ratio sampled noise);
  v1 keeps 4 000 / 8 000 and 3 runs. The step now takes about 40 s once its compiler is built.
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
  - Guard `check/bad/TryDefaultCycle` (§5.1) is green under v2. *(Amended by R5's review, S6: its v1 golden pins v1's place and text, so it is an expected difference, and its substance is gated under v2 by the claimed pending twin `check/bad/TryDefaultCycleAtBinder`.)*
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
- **As built (2026-09-25).** Spec first: `checker-v2.md` §4.1 *Decided by R5* (where `wants` and
  `obls` live), then *As built by R5* in §4.5, §5, §6.5 (amended), §8.1, §8.6 and §11.4;
  `checker.md` §6.5's pointer note says "effective at R11", and its new §8.6 holds the three `?`
  texts, written before the code.
  - **The decision.** `obls` is one new field of the shared `Flags` — an opaque `ObligationSet`
    naming a set in v2's `check2/Obligations.zig` — and `wants` is the `Flags.constraints` that
    `Schemes.Writer` and `Render` already read, so neither is forked or hooked; R6a pairs each entry
    with its `WantedId` by position. Side columns were refused because they are a second owner of
    "what rides on this variable", kept in step with `fresh`, `merge` and the journal by hand; a fork
    because §19.1 forbids copying the shared readers. `Flags` goes 12 → 16 bytes and `Content`
    stays 20 (a comptime assert). **v1 is byte-identical**: every v1 `Flags` is a literal that
    leaves `obls` at `.none`, and the new binary's `dump --stage=types`, `interface` and `dispatch`
    and `check` output equal 2bc9e22's on every fixture of `check/*`, `dispatch`, `run`, `emit/*`,
    `build/bad` and `regress` (1 888 comparisons, 0 differ), besides `test-blackbox`.
  - **Design as built.** Obligation rows `{kind, state, region, seq, vars[3], index}`, deciding
    variables first; decided at their node when a deciding variable is known (a `?` when EITHER
    side is), else attached to the deciding flex roots with all their variables lowered to one
    rank. `Walk.owned` (the one WALK that yields obligation variables as successors; `Walk.child(…, .owned)` no longer compiles)
    yields a variable's constraint method types and then its open rows' variables. `Unify.bind`
    readies a flex's rows onto the top-level frame's queue, a flex merge joins the sets and lowers
    again; `Solve` drains after every constraint node and at §8.1 step 1, defaults open `try` rows
    at step 3 (on adjusted ranks, looping), and closes at step 7 (`ambiguous_tuple`,
    `ambiguous_interpolation`, the `equatable` fold). The `equatable` marker is a flag plus, when
    the marker walk put it there, a row at the walk's region; `check2/Instances.zig` is the
    growable, payload-descending, text-ordered-on-failure walk (D10: `payload_params` of an own
    type computed now, of an imported one read from interface v3). The `?` shape goes into P9's
    `tries`. `Subset.zig` has one refusal left, R6a's. A record literal is one node whose order the
    solver chooses (§6.5 *Amended by R5*: pushdown when the expectation can take its field names,
    fields first otherwise), after the spec's fields-first-always turned two precise v1 messages
    (`FieldNamedMain`, `SchemaRecursivePayloadMismatch`) into whole-record mismatches.
  - **Files** (lines): new `Obligations` 283, `Instances` 221; `Solve` 470 → 878, `Unify` 554 → 617,
    `Walk` 497 → 528, `Report` 367 → 488, `Subset` 117 → 108, `Generalize` 288 → 297, `Module` 421 →
    429, `constrain/Tree` 341 → 389, `constrain/Expr` 248 → 295, `constrain/Decl` 526 → 532 — 7 254
    in all. Shared: `check/TypeStore.zig` (+`Flags.obls`, `ObligationSet`, the size asserts) and
    `check2/Publish.zig`'s `payloadParams` made public with a kind/arity signature.
  - **Claims.** CK-05, CK-06, CK-16, CK-51, CK-68 (their R0 fixtures), CK-62 through two new
    dispatch-free fixtures (`run/TryEscapesToLaterFact`, `run/TryEscapeLowersOnlyItsOwn`; the R0
    fixture compares with `==` and waits for R6a), and CK-09's new five-member fixture
    (`check/good/MutualGroupFiveMembers`): 8 lines appended to `CLAIMED`, the five green ones'
    `v2` lines deleted from `RED`, and v1 lines for the three new fixtures. CK-59: the generation
    half; its fixture stays red for the article (R13), `RED` unchanged. CK-18: structural (no
    `.equatable` node, no `Flags` rebuilt field by field). CK-17's class holds under v2 (the
    100 000-field record with a function last is one `not_equatable`).
  - **Reviewer-focus fixtures.** `tests/corpus/run/TryDefaultAtLetBoundary.beni` (a guard, green on
    v1: a `?` whose target is a `let` definition defaults at that definition's own boundary and it
    is used at two error types); `tests/pending/run/TryEscapesToLaterFact.beni` (its variables
    escape the `let` to the declaration, decided `Maybe` by a later fact);
    `tests/pending/run/TryEscapeLowersOnlyItsOwn.beni` (N-3: `twice`, beside `v = u?` whose target
    escapes, is still generalised); `tests/pending/check/good/MutualGroupFiveMembers.beni` (CK-09's
    shape, five members, shuffled parameters, obligation forms).
  - **Evidence.** The three gates green. `test-v2` (report) exits 0: 587 passes, every one of the
    355 fixtures the widened `v2-subset.sh` names passes, no drift; `v2-green.txt` gains 36
    (`check/args` 2, `check/bad` 8, `check/good` 4, `emit` 1, `run` 21 with the new guard) and loses
    three that CK-59's rule changes (`MissingField`, `UnknownField`, `RecordNotClosed`), which move
    to `v2-expected.md` with `TryMixedShapes` (CK-51's text) and `TryDefaultCycle`. That guard holds
    under v2 in substance — one `infinite_type`, the `?` defaulted to `Result` and the cycle
    reported — but at the parameter `x` and in v2's text (`a = Result b a`), which its v1 golden
    cannot match; R11 re-blesses it. The 72 green `run/` and `emit/app/` fixtures build
    byte-identical JavaScript under v1 and under `--checker=v2 --jobs=8 --roundtrip-interfaces
    --roundtrip-dispatch`, in the development and the release pass (144 of 144); the 154 green
    `check/*` fixtures print the same diagnostics and interfaces at `--jobs=1` and at `--jobs=8`
    with both round trips. `test-pending` green (28 claims); `test-pending-perf` green (all RED as
    recorded) and `test-perf` green (CK-41 1.41).
  - **Bench** (ReleaseFast, `check --no-cache --jobs=1 --self-profile`, the root package's `check`
    events, v1/v2 interleaved, medians of 7, two sets in opposite orders). A generated corpus of 90
    modules and 133 467 lines: R4b's eight shapes plus three obligation shapes — `"v=${p.0}
    w=${p.1}"` before `Basics.eq p ( i, j )` pins `p`, a `let v = m?` in an annotated `Maybe`
    function, and `Ok (r? * k)` beside `Basics.neq q.1 "x"` with `q` pinned by a `case` after it —
    which both checkers check clean with identical interfaces. **v1 110.9 / v2 110.0 ms (0.99×) and
    v1 110.9 / v2 111.0 ms (1.00×).** R4b's dispatch-free corpus: v1 102.9, v2 96.7 ms (0.94×).
  - **Doubts, for the reviewer.** (1) `Unify.lowerObligations` walks every open row on a merged
    flex, so a variable carrying k rows merged m times costs O(k·m); `Solve.defaults` re-walks every
    open `try` at every boundary of its group (O(tries × `let` boundaries)). Both are small in the
    corpus and the bench; neither is a scenario. (2) A row readied by `Solve.poison` during steps 4
    or 6 is never drained (the queue is the top-level frame's and is popped with it); its decision
    would only have poisoned a result, in a module already failing. (3) The order of a literal's two
    halves reads the expectation at the node (§6.5 *Amended by R5*): a program where the expectation
    becomes a record only later still gets v1's order. (4) `Instances` computes an own type's
    `payload_params` mid-solve with `Publish.payloadParams`, which makes scratch variables at rank
    `generalized` in the store; nothing reaches them. (5) No `frame` field on rows and one queue:
    R7's nesting must add both (§4.5 *As built by R5*).
- **As built, review round (2026-09-25).** Two reviews, structural and adversarial. The manager's
  list was done spec first: `checker-v2.md` §4.5 *Amended by R5's review* and *As built by R5,
  after its review*, the I15 row, §21.1's new D2 row, and *As built* notes in §6.5, §8.1, §8.6,
  §11.4 and §19.1.
  - **B1 (determinism, I13): one `equatable` question, one message.**
    - The marker walk flags only after a `yes`.
    - Every row it makes carries the question's `origin`, and an origin reports once.
    - A comparison's scheme flag meeting a call argument at the top of the unification makes the
      row there. So `Basics.eq r r` answers at the comparison (F7), and a function passed through
      a record field answers at the lambda (§6.5 now pushes a literal down into a record open on a
      flex).
    - A readied `equatable` row waits for the boundary's step 1, so its message shows the solved
      type (`number -> number`).
    - Fixtures: `pending/check/bad/EqOneQuestionMerged` (D), `EqOneQuestionPerSite` (F),
      `EqRecordFieldFunctionAtComparison` (F7a), all claimed; and the corpus guards
      `check/bad/EqOneQuestionRecord` with its symbol-order twin `…NamesFirst` (E),
      `EqFunctionFieldThroughCall` (F7b) and `InterpolatedAmbiguousTuple` (F6), green on v1 and
      v2.
  - **The three quadratic shapes are now CK-96, CK-97 and CK-98**, timing scenarios in
    `tests/blackbox/perf_test.zig` (`test-perf`), red on the reviewed tree and green now. Ratios,
    best of 3 on ReleaseFast, `--checker=v2`:

    | Scenario | Before | After |
    |---|---|---|
    | CK-96, rows on one variable, 2 000 / 4 000 | 92 / 356 ms, 3.86 | 8 / 9 ms, 1.12 |
    | CK-97, a merge chain, 2 000 / 4 000 | 58 / 216 ms, 3.72 | 11 / 20 ms, 1.81 |
    | CK-98, open `?` × boundaries, 1 500 / 3 000 | 107 / 397 ms, 3.71 | 10 / 19 ms, 1.90 |

    - Sets are in-place lists, merged by size.
    - A merge re-lowers only the rows owned by a side whose rank strictly dropped.
    - A set keeps the rows its variable owns apart from those it only decides.
    - Step 3 reads a per-frame open-`?` list, which a row leaves once per frame. That is the
      per-frame structure R7 needs; the `ready` queue stays the top-level frame's, owned by
      `Solve`, and `Unify` holds one pointer to it (N1).
    - §4.5 now states the cost claim precisely: O(R log R + R·D) for R rows at nesting depth D.
    - The adversarial review's other shapes also stay flat on ReleaseFast at 1 000 / 2 000: 14 /
      16 ms (`z = [ u?, … ]` with n plain bindings after it), 15 / 18 ms (an equatable merge
      chain), and 14 / 16 ms (an ambiguous `p.0` list).
  - **CK-99 (F4, valid-program-rejected): a `?`'s owner is its target.** D2 and I15 were amended:
    the subject and the value are lowered to the target's rank, never the target to the subject's.
    `run/TryTargetKeepsItsSuccessType` builds and prints v1's answer under both checkers.
  - **S1**: a kinded flex takes the fields first (`pending/check/bad/KindedExpectationShowsLiteral`,
    claimed).
  - **S2**: I15 now says what the code does. It is directional, owner to dependants, and §4.5 says
    why.
  - **S5**: `Solve.zig` split into `Decide.zig` (359 lines) and `Solve` (621); v2's texts moved into
    `Messages.zig` (198), leaving `Report` at 302.
  - **S6: exit criterion "`TryDefaultCycle` green under v2" amended to "gated under v2 by a pending
    twin".** The guard stays in `v2-expected.md`, because its golden pins v1's place and text.
    `pending/check/bad/TryDefaultCycleAtBinder` asserts the substance under v2 and is claimed:
    one `infinite_type`, at the binder `x`, containing `Result`.
  - **S7**: `poison` settles a flex's rows directly, so nothing is readied during steps 4 and 6, and
    popping the top-level frame asserts an empty queue.
  - **F5**: a variable subject beside a target of neither shape is the `neither` leg
    (`pending/check/bad/TryUnknownSubjectSaysNeither`, claimed).
  - **F6**: step 7 closes `tuple_index` rows first, and does not report the interpolation of a
    result they poisoned (I12).
  - **F8**: recorded under CK-94. The quantifier's name hint follows member order; the types are
    equal.
  - **Nits.**
    - N2: `Instantiate.mapped` copies `Flags` and changes two fields.
    - N3: the "only reader" wording is fixed here and in §4.5.
    - N4: the walk visits tuple elements in order.
    - N5: the drain sorts by `seq`.
    - N6: the `reopen` comment is fixed.
    - N7: `Obligations.tries` is gone; the per-frame lists replace it.
    - N8, N10: comments added.
    - N9: recorded in §8.1 for R6a.
  - **Evidence.**
    - The three gates are green.
    - `test-v2` exits 0 with 593 passes (was 587): the 5 new guards are appended to
      `v2-green.txt`, and nothing was lost.
    - `test-pending` is green with 33 claims (was 28): the 6 new claims above, minus none.
    - `test-pending-perf` is green (all RED as recorded). `test-perf` is green: CK-41 1.63,
      CK-96 1.12, CK-97 1.81, CK-98 1.90.
    - The 73 green `run/` and `emit/app/` fixtures build identical JavaScript under v1 and v2,
      146 of 146.
    - The 158 green `check/*` fixtures print the same at `--jobs=1` and at `--jobs=8` with both
      round trips.
    - `src/check/` is unchanged since the first round's 1 888-comparison v1 identity check.
  - **Bench**, with the first round's method and corpus, regenerated:
    - v1 110.6 / v2 114.2 ms, **1.03×**;
    - v1 114.0 / v2 115.4 ms, **1.01×**, in the reverse order;
    - R4b's corpus: v1 105.2 / v2 100.6 ms, 0.96×.

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
  - *(Added by R5, 2026-09-25.)* `wants` is the shared `Flags.constraints` (`checker-v2.md` §4.1
    *Decided by R5*): R6a writes down how an entry is paired with its `WantedId`, drops `Unify`'s
    `constrained` refusal, and shares `Obligations.seq` with wanteds (§9.1). A wanted readied by
    `Unify.bind` goes on the same `frames[0].ready` the obligations use (§4.5 *As built by R5*).

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
- **As built (2026-09-25).** Spec first: `checker-v2.md` gained *As built by R6a* notes in §4.2 (the
  position pairing, the tables), §5 (*Widened by R6a*: no gate; `build`/`dump --stage=dispatch`
  refuse what needs P6; R7's refusal at a use; v1's capability bits until R8a), §8.1 (wanteds at
  the boundary, N9, rule (a) with method types, step 7's restated assert), §9 (the resolver as
  built) and §19.1 (files). Found and fixed (claimed): **CK-100**, v1 leaving a method's result
  untied when its receiver is bound later.
  - **Design.** `Evidence.zig`: wanteds, answers, givens and the canonical order; an open wanted is
    one `Flags.constraints` entry of its flex receiver, paired by position (`slots`). `Resolve.zig`:
    §9.2's step, Rule U1's join on attach, the `number` bridge for flex and rigid (unifying the
    declared method type first, category `.where_clause`), the `rigid` row (a given, the bridge,
    `missing_where_constraint` or `type_dispatch_needs_annotation` at the use), sharing by receiver
    root (CK-80), the lineage rule, the step budget, promotion, the cap and the default.
    `Instances.zig`: lookup (the table, the P3 index or `findValue`, matching by instantiation with
    the requirements as sub-wanteds, derivation, `unknown_method`) and the derivability walk
    (three-colour, one pair of epochs, v1's verdicts and texts). `Unify` readies wanteds on a bind
    and joins them on a merge; `Instantiate` makes one wanted per copied or imported requirement;
    `constrain/Expr` emits the `method` node (Rule U0's order), keeps v1's operator-section
    pinning of the lambda's type and drops v1's saturated-section call shim (§6.4).
  - **Scope, as the brief set it.** `build` of a dispatching root module is `not_implemented`
    (R6b) from `js/Emit.zig`, and so is its `dump --stage=dispatch`; P9's table holds requirement
    lists and callee terms only, for `Cycles`. An own untyped method used before its group is R7's
    `not_implemented` at the use, and such a module keeps only its refusals. Derived contexts of
    own nominal types are v1's one-entry-per-parameter rule over the shared capability bits
    (`Types.settleDispatchCapabilities`), and the programs where v1's second settle answers
    otherwise are listed for R8a.
  - **Files** (lines): new `Evidence` 357, `Resolve` 502; `Instances` 242 → 864 (over its ~800:
    R8a splits it), `Solve` 621 → 795, `Unify` 648 → 776, `Walk` 532 → 546, `Instantiate` 338 →
    400, `Decide` 359 → 374, `Report` 302 → 388, `Module` 429 → 501, `Subset` 108 → 81,
    `constrain/Expr` 295 → 445, `constrain/Decl` 532 → 606, `constrain/Tree` 389 → 416: 9 709 in
    all.
  - **Evidence.** The three gates green. `test-v2` exits 0: every `check/*` fixture passes but the
    four `v2-expected.md` now lists for R6a (`CyclicReceiverReportedOnce` and
    `LetHelperCyclicReceiver` for CK-57's text, `LetConstrainedTwice` for eager draining,
    `SpecializedEqWrongReceiver` for R8a) — `check/good` 50, `check/bad` 125, `check/args` 40,
    `check/depth` 13; `v2-green.txt` +70 (`check/args` 6, `check/bad` 42, `check/good` 22, the two
    new guards among them); `v2-subset.sh` now holds every `check/*` fixture, 431 in all, each
    passing. No drift: `dispatch/` and every dispatching `run/`/`emit/` fixture is refused with
    R6b's `not_implemented`; `run/DerivedEqInPriorityGroup` and `run/DerivedEqThroughCustom` are
    listed for R8a. `check` of the 173 `run/` and `emit/app/` fixtures prints the same under both
    checkers for 170; the three others are R7's and R8a's (`ConstrainedBinderNotCyclic` and
    `LetHelperOuterArgument` among the 170). The 242 `check/*` fixtures print the same diagnostics
    and raw interfaces at `--jobs=1` and at `--jobs=8 --roundtrip-interfaces --roundtrip-dispatch`.
  - **N10.** `dump --stage=raw`'s `scheme`/`q`/`where` lines and `dump --stage=interface`'s `value`
    lines, v1 against v2, for every corpus fixture whose two checks exit alike: 471 identical, 49 of
    them with `where` blocks; 2 differ, neither in a `where` block v1 publishes as v1 means it:
    `RecordExtChain` (§4.1's normalised records, listed since R4b) and `MethodConstraintMismatch`,
    a failing module whose poisoned `render` requirement v2 publishes as `<error>` (the owned
    error scan of §14.1) where v1 wrote `where render` over an `err` term. `core`'s interfaces
    cannot be compared before R9: v2 does not check `core` (`Options.usesV2`), and a copy of core
    checked as an app collides with core's own `Bool`.
  - **Pending.** `test-pending` green. Claimed (9): CK-02 `OuterReceiverConstraintLevels`, CK-03
    `CyclicReceiverResolution` (its `.codes` pinned at the two `==`), CK-09 `MutualGroupLocals`,
    CK-20 `RigidInsideDerivedShape`, CK-21 `WhereClauseNumberReceiver` and the new
    `NumberBridgeRigidLyingWhere` (the rigid half), CK-48 `MissingWhereAtUse`, CK-100
    `MethodResultTooGeneral` and `check/good/EagerDrainInnerLet`. Two R0 `.codes` named the wrong
    code for their own message (`MutualGroupLocals`, `OuterReceiverConstraintLevels`: a literal
    against `String` is v1's `kind_mismatch`, which each oracle twin reports) and were corrected.
    Every `v2` line of `RED` is v2's new answer: R7's refusals, R8a's `exit=0`, R13's texts.
  - **Perf.** `test-pending-perf` green (all RED as recorded under v1, which is frozen);
    `test-perf` green with three v2 scenarios added: CK-03 (`infinite_type` in 6 ms against a
    500 ms bound), CK-42 (8 000 / 16 000 declarations, 64 / 121 ms, ratio 1.89) and CK-80 (depth 9 /
    18, 5 / 6 ms). CK-93's note: the coinductive `Unify.active` scan was measured on two
    2 000-deep `let` chains unified at the end — no difference from the same program without the
    unification (90 ms either way, best of 3, ReleaseFast) — so it stays a stack.
  - **Bench** (ReleaseFast, `check --no-cache --jobs=1 --self-profile`, the root package's `check`
    events, v1/v2 interleaved, medians of 7). A generated corpus of 90 modules and 124 377 lines:
    R5's eleven shapes plus five that dispatch — a nominal `==` on an own type, a record `==` with
    `<`, a `where`-constrained generic called across modules, an unannotated function whose `<`
    and constrained call are promoted, and own dot-calls on a concrete and an inferred receiver —
    1 080 `where` lines published, identical under both checkers. **v1 123.2 / v2 117.4 ms
    (0.95×), and in the reverse order v1 121.2 / v2 118.0 ms (0.97×).** R5's dispatch-free corpus:
    v1 109.8 / v2 116.0 ms in the same session, and this tree against `68186fa`'s v2 112.4 / 110.5
    ms (1.02×): a first cut cost 8 % there (Rule U1's bookkeeping on every flex merge), now a fast
    path when neither side carries a wanted.
  - **Doubts, for the reviewer.** (1) Derived contexts are v1's syntactic capability bits, so
    `check` accepts `Wrapper (Holder String) == …` where the payload's specialised `eq` does not
    answer (`SpecializedEqWrongReceiver`), until R8a; `build` is refused anyway. (2) Sharing by
    receiver root answers a wanted `alias` of one in another member of the same recursive group;
    R6b's elaboration must re-index such a `param` by the caller (§12.3). (3) The class flag of
    §9.5 is keyed by the receiver's root at the rejection, not OR-merged on union. (4) `Instances`
    is 864 lines. (5) `inst_evidence` is not recorded; R6b orders an instruction's instantiation
    wanteds by `Evidence.requirements`. (6) A `number` literal's name hint is still the scheme's
    `a` (CK-94).
- **Revised by the review (2026-09-25).** Two reviews (structure and adversarial) found an unsound
  acceptance (B1), a stack overflow (B2), a shared instantiation (B3), evidence out of canonical
  order (B4) and eleven lesser defects. Fixed structurally, spec first (`checker-v2.md` §4.2, §8.1,
  §9, §18 and §19.1, each *Revised by R6a's review*):
  - **One derivability verdict** (B1, B2): `Instances.derivability`, an iterative walk over
    `(node, method kind)` pairs coloured per pair, following aliases, with boundary requirements
    pushed as pairs of their own kind; the `walked` bit and `derivesNominal` are gone, and every
    derivation reads the verdict. Found **CK-101** (v1 overflows its stack on an alternating
    `eq`/`compare` cycle and is exponential on the same DAG without one).
  - **Sharing only what depends on the receiver alone** (B3): the memo holds derived answers; a
    module-rule method is instantiated per use; no unification is used as a test.
  - **Evidence order at creation** (B4, S1): `Instantiate` makes an instantiation's wanteds in
    `Evidence.requirements` order and `Solve.instantiated` records `inst_evidence`; promotion
    records `promoted(root, method)` and P6 computes the index per site (§12.3).
  - **No silent drops** (S2, S8): every unpaired constraint entry and the I14 checks are
    `Solve.expect` / `Unify.invariant` — `internal` in a release build, a stop in Debug.
  - **The class flag on every union** (S3, F3): `Unify.merge` OR-merges `Evidence.rejected`.
  - **One capability, fenced** (S4): `rules_test.zig` allows v1's capability API only in
    `Instances`, `Module` and `Incremental`; R8a's brief says it removes them. R7's brief owns
    per-frame queues (S5).
  - **S6** `Resolve.checkGivens`; **S7** `Resolve.State`; the marker walk is `Marker.zig`.
  - **F1** the step budget is per top-level group, with its own text; **F2** a context's method at
    the wrong type is v1's `type_mismatch`; **F4** one `missing_where_constraint` per rigid and
    method at a use; **F5** no lookup on a receiver already cyclic *when its wanted is resolved* (one
    still resolved while the cycle is open meets an honest `unknown_method` first, as in v1); **F6** no `ambiguous_method_receiver`
    over an `<error>` scheme, and a call's result mismatch fails its callee's requirements in
    silence.
  - **Fixtures.** Corpus (v1 passes, now in `v2-green.txt`): `check/bad/EqTupleHoldingFunctionType`,
    `…FunctionAlias` (B1), `check/bad/RequirementMethodWrongType` (F2),
    `check/good/MethodInstantiatedPerUse` (B3). Pending, claimed: `DerivabilityAlternatingCycle`
    (CK-101), `RejectedMethodClassWide` (CK-37), `RigidInDerivedShapeOncePerSite` (CK-20),
    `CyclicReceiverNoMethodLookup` (CK-03), `MethodResultMismatchOnce` (CK-100);
    `NumberBridgeRigidLyingWhere`'s golden gains the clause's own `type_mismatch` (S6).
    `perf_test.zig` gains CK-101's v2 timing twin. `MethodConstraintMismatch` moves from
    `v2-green.txt` to `v2-expected.md` (F6: v1's golden pins a warning printing `where a.render : ?`).
  - **Evidence.** The seven steps green. `test-v2`: `check/good` 51, `check/bad` 127 (17 skipped),
    `check/args` 40, `check/depth` 13, no ratchet failure. `test-pending`: 47 GREEN under v2, every
    RED as recorded. `test-perf`: CK-03 6 ms, CK-42 1.96, CK-80 1.00, CK-101 1.00.
  - **Bench** (as above, medians of 7): the dispatch corpus v1 121.6 / v2 123.9 ms (1.02×), reverse
    order 123.9 / 126.3 (1.02×); the dispatch-free corpus 111.0 / 117.4 (1.06×, as before the
    review). Disabling the cyclic-receiver walk changed nothing measurable (9 runs each).
- **Revised by the round-2 review (2026-09-25).** Every round-1 blocker was verified fixed at its
  cause; one new blocker and one should-fix, fixed spec first:
  - **N1: the lineage rule is gone.** §9.5's premise ("a sub-wanted's receiver is an image of a
    quantifier strictly inside its parent's") is false: a `where` clause may constrain ANOTHER
    parameter, so `bx.describe bx` with `describe : Box a, b -> String where b.describe : b, K ->
    String` repeats `(describe, Box Int)` with finite evidence, and the rule reported a false
    `infinite_type`. It is replaced by a cycle test (`Instances.cyclic`, run by `Resolve.step` for
    every wanted on a structure); a non-cyclic chain that grows is left to the per-group budget,
    which reports. Fixtures `check/good/WhereOnOtherParameterSameReceiver` and
    `check/bad/WhereOnOtherParameterListed` (`unknown_method`, as v1).
  - **S1: `failInstantiation` narrowed.** The callee's `inst_evidence` row is taken at the start of
    the call node, and only a requirement whose method type reaches a variable of the callee's
    result fails in silence; an independent requirement still reports. A failed wanted is never an
    alias target: `Resolve.attach` and `Unify.unionWants` let the live wanted take its place.
    Fixture `check/bad/CallResultIndependentRequirement` (`type_mismatch` and `unknown_method`, as
    v1).
  - **S2: crash signatures.** `world.zig`'s `drain` kills a child at Zig's crash banner and the run
    signs `crash=ABRT`, so CK-101's v1 line is `crash=ABRT`, not a race against the timeout.
  - **Nits.** F5's wording (above, §9, the fixture's comment); the budget's text says "group";
    `Instances.answered` and its unused parameter are gone; R6b's brief says an alias chain
    ending in `failed` is never elaborated.

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
- **Owed from R6a's round-2 review (nit 2).** A memo hit whose sub-wanted fails after it was shared
  leaves its `alias` wanteds `answered`. P6 follows an `alias` chain to its end and treats one that
  ends in `failed` as failed (`internal` if the module reported nothing) — it is never elaborated.
- **As built (2026-09-25).** Spec first: `checker-v2.md` §5 (*Widened by R6b*), §12.3 (*As built by
  R6b*), §13.1 (*Amended by R6b*: a term may be shared) and §19.1.
  - **Design.** `check2/Eager.zig` is P5 under v1's rule (which rows; one wanted per constructor
    argument over flex markers, resolved in a frame of its own with a quiet report).
    `check2/Elaborate.zig` is P6, the one place trees are built: per site (callee and roots) or
    row body, a UNIT — a DAG with one node per distinct wanted reached through its aliases —
    written in reverse post-order, so every argument follows every owner. It reads
    `inst_callee`, `inst_evidence` (moved from a reference to the `call` applying it), the answers
    through alias chains, `DeclInfo` requirements with the roots `Resolve.close` records beside
    them, and the givens' rigids for an annotated caller; `promoted(root, method)` and group calls
    (a `top` reference with requirements and no row, or a `group_call` answer) take the SITE's
    declaration's index (§12.3 cases 1 and 3). A root `undetermined` is `ext Basics eq` /
    `primitive num_compare` (v1's table); `open` is `internal` except on a P5 marker for the row's
    own method. A failed wanted, or an alias chain ending in one, keeps only a value callee (for
    `Cycles`), `internal` in a clean module. A row whose body fails is not written, nor any row
    naming it (one probe pass, one propagation); a use of such a row is `not_implemented` (R8a).
    After P9 a module's ADT capability bits are its rows (`restoreDerivedCapabilities`, now on a
    v2 cache hit too). The I7 assert runs last in P9. `Subset.zig` and the build/dump refusals are
    deleted.
  - **Shared code, for sharing.** `Dispatch.checkI7` judges each term once, bottom-up, and
    `Edges.termsEdges` walks each term once (a seen set); on a tree both answer as before. Without
    them CK-80 and CK-101 went exponential in `check` (test-perf red at 14.6 and 26.8); with them
    1.00. `Lower` and the dump still expand a shared term (CK-80's `build` half, unassigned).
  - **Found and fixed: CK-102** (v2's `refuseDerived` read its lineage root's state after failing
    it, so a derived shape refused at a position was accepted in silence;
    `check/bad/DerivedPositionMethodMismatch.beni`, which fails on e763e12). Also fixed on the way:
    P5's per-type scan for a `pub eq` (CK-42's test-perf went 3.3 → 1.97).
  - **Evidence.** The three gates, `test-v2`, `test-pending`, `test-pending-perf`, `test-perf`
    green. `test-v2`: `run` 166 pass (3 skipped: R7's `DerivedEqLocalCustom`, now listed, and
    R8a's two), `dispatch` 26 (3 `core` skipped), `check/*` 236, `emit` 15 pass and 13 R8a
    `--library` refusals; `v2-green.txt` +134 (run 96, dispatch 26, emit 7, emit/app 2,
    emit/release 1, check/bad 2); `v2-subset.sh` now every fixture but a `--library` build of a
    module with a `type`, 579, each passing. Every `dispatch/` golden is v1's byte for byte (no
    listed difference). v1 and v2 `build` every `run/` (dev and `--release --allow-debug`) and
    `emit/` fixture to identical output trees, 347 of 347 that both build, at `--jobs=1` and at
    `--jobs=8 --roundtrip-interfaces --roundtrip-dispatch`; the 19 v2 refuses are R8a's library
    types, R7's one fixture and v2-expected's R8a rows. `check --checker=v2 --jobs=8` with both
    round-trip flags over 486 corpus fixtures: no `internal`, so the I7 assert fires nowhere.
    Claimed (11): CK-08, 27, 28, 29, 32, 62's `TryDecidedByLaterFacts`, and — answered by the same
    elaborator — CK-30's two, CK-31's, CK-66's and CK-67's `run/` fixtures. CK-11 stays green.
    New corpus fixtures: `run/NestedEvidenceParam` and `dispatch/NestedEvidenceParam` (I5/I7 on
    `List (List (Box a))` with a parameter, annotated and promoted), `check/bad/SharedAnswerFailsLater`
    (an alias chain ending in a failed wanted: one message, no `internal`).
  - **Bench** (ReleaseFast, `--no-cache --jobs=1 --self-profile`, the root package's events,
    medians of 7 interleaved, both orders): R6a's 90-module corpus `check` v1 128.0 / v2 137.1 ms
    (1.07×), reversed 131.5 / 139.1 (1.06×); an app variant whose `main` reaches every dispatch
    shape (5 940 uses), `build`: check 165.1 / 176.8 (1.07×), lower 45.9 / 47.5, emit 53.0 / 54.0;
    the three together 1.05× (reversed 1.05×).
  - **Files** (lines): new `Elaborate` 942, `Eager` 185; `Module` 544, `Solve` 911, `Resolve` 598,
    `Report` 396, `Instances` 670; `Subset` deleted.
- **Revised by the reviews (2026-09-25).** A structural and an adversarial review (no wrong answer
  or wrong hidden argument at run time found anywhere); fixed spec first (`checker-v2.md` §12.3 and
  §13.1 *Revised by R6b's reviews*, §19.1; `backend.md` §5):
  - **B1** (v2 regression): an `undetermined` answer below a VALUE's evidence (`[ [] ] == [ [] ]`,
    `List.sort [ [] ]`, a user `eq where a.eq` over `Pair [] 1`) was the leaf, and `Lower` refused
    it. P6 now carries each node's nearest derived kind (`Unit.Ctx`) and writes the leaf only below
    a derived ancestor of the wanted's own method, the structural function everywhere else.
    Fixtures `run/UndeterminedUnderValueEvidence` and `dispatch/UndeterminedUnderValueEvidence`
    (v1's bytes). The I7 assert checks the placement (each slot's method from its owner's list).
  - **CK-103** (B1b, v1): a `compare` slot under an `eq` ancestor got the `eq` leaf
    (`List$compare(Basics$eq, …)`), harmless at run time only because no value of the slot's type
    exists. v2 writes `num_compare`; the placement rule makes v1's `check` refuse it
    (`tests/pending/run/UndeterminedCompareSlot`, claimed). No `run/` fixture can print a wrong
    answer: by parametricity the slot's function is applied to nothing.
  - **CK-104** (S5/F2, backend, both checkers): emission order and the value-cycle check now walk
    the bodies of the derived rows a declaration's sites name (`Edges.termsEdges` through rows,
    `Lower.siteTops`). `run/DerivedRowBodyEmissionOrder` (promoted; `ReferenceError` at load with
    the fix off) and the permuted CK-67 twin `run/DerivedContextClosedOwnMethodPermuted` (claimed).
  - **CK-80's `build` half** (N6/F3): `Lower` binds a shared evidence closure to a `const` once
    (`termValues`, `hoistEvidence`'s rule) and judges each term's shape once; `perf_test.zig`
    "CK-80 build" (6 / 10 ms; 8 / 873 ms, ratio 109, with the binding off). The dump still expands.
  - **S1** case 3 asserts unreachability from the site declaration's scheme, and a `promoted`
    answer its group; **S2** the givens-count fallback is `expect`; **S4** P6's `internal`s are
    reported with the I7 assert; **S3** R8a's brief lists every piece of the stopgap and
    `rules_test` fences it; **S6** R7's brief says what of CK-30/31/66 stays R7's. Nits: N1 (a
    failed unit takes back its structural rows), N2, N3 (a probe `internal` is said), N4 (P5's frame
    clears the derived memo), N5 (`Unit.zig`; P5's half moved to `Eager`; `Solve` 893). N6's
    `reported` bit was not added: `refuseDerived` reads the root's state before its own rejection,
    and a bit would hold only if every reporter set it, which would change v1-identical texts.
  - **Evidence.** The seven steps green. `test-v2`: `run` 168 (3 skipped), `dispatch` 27,
    `check/*` 236, `emit` 15 + 13 R8a refusals; `v2-green.txt` +3; `v2-subset.sh` 582, each
    passing. JS parity v1/v2: 351 of 351 builds identical at `--jobs=1` and at `--jobs=8` with both
    round-trip flags (19 refusals as before). `check` of 493 corpus fixtures under both checkers:
    no `internal`. The adversarial probes and 340 fuzz programs rebuilt: every v2 build prints v1's
    output; the only v1 program newly refused is CK-103's. `test-pending` 60 GREEN under v2.
  - **Bench** (as above): `check` v1 134.4 / v2 136.8 ms (1.02×), reversed 132.8 / 137.9 (1.04×);
    `build` of the app variant, check + lower + emit, 1.05× (reversed 1.06×).

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
  - *Narrowed by R6b's review (S6).* R6b already claims `run/RecursionWithComparison`,
    `run/DeadMiscount` (CK-30), `run/MutualGroupEvidenceOrder` (CK-31) and
    `run/GroupVariableOutsideCaller` (CK-66): P6 answers them by §12.3's cases 1 and 3, because
    every group there is checked before it is used. What stays R7's in those three findings is
    the demand-driven half: the same shapes with an own method or member used BEFORE its group
    (nesting at demand, in-flight links, merged frames), the §12.3 *As built* case-3 assert under
    nesting, and each fixture's place in the permutation scenario, which must hold in every
    declaration order. The other CKs of this list are R7's whole.
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
- **Owed from R6a's review (2026-09-25, S5).** Per-frame `ready` queues are this slice's to build,
  not a reviewer's check only: R6a has ONE queue (`Solve.ready`, which `Unify.queue` points at) and
  one top-level frame at a time, so every wanted and obligation a nested check readies would drain
  in its demander's frame. R7 gives each frame its own queue, routes a `let` frame's to its
  top-level frame as today, and makes `Decide.drain` take the frame; `Resolve.State.steps` stays
  per top-level group (the nested group counts against its demander's budget, §10.2's cumulative
  nesting budget).
- **As built (2026-09-26).** Spec first: `checker-v2.md` §10.8 (new: *As built by R7*, with two
  corrections), notes in §4.4, §8.1, §9.1, §10.2, §10.4, §12.3, §19.1 and §23; `language.md` §10's
  `method_needs_annotation` row amended (v2 never emits it for the ordering case; §11.2's case is
  R8a's).
  - **Design.** `check2/Groups.zig`: P4 is `Groups.checkAll`; `check(g)` generates a group at
    `frames.len + 1` into a per-level tree and solves it in a fresh top-level-kind frame
    (`solveGroup`, which saves and restores the demander's state); `demand(decl)` is the one entry
    for the module rule, a derived query's own `eq`/`compare`, and a `demand` node (a value or
    schema reference a nested group makes to a group not `done` at its generation). A `checking`
    group below the current top-level-kind frame is a back-edge: `merge` marks every
    top-level-kind frame above it merged and recursive and joins their groups (union find); a
    merged frame runs steps 1–2, lowers its pool to the root frame's rank, hands pool, `?` list,
    binders (copied), members and queue down, and re-points its items to the root's queue
    (`handDown`). The root's boundary runs once over all of it (step 4 sorted by kind and source
    position when binders were handed down), promotion over every member, one failure bit; P6
    reads groups as merge roots. Per-frame queues: `Generalize.Queue`, one per top-level-kind
    frame, reused once popped; wanteds and rows carry a `u16` `frame`; `Unify.enqueue` routes;
    `Decide.drain` takes the queue; the current queue's list is `Solve.ready`.
    `check2/Recursion.zig`: D14's hooks at the top of `Resolve.step` and where a row is attached
    or decided, free when no frame is recursive; the hint read at a mismatch (a recursive group's
    wanted or row on a group-level variable that reaches either side) with the member named from
    the Bir (the innermost `let` function around the node, its locals followed to their
    definitions or scrutinees); §10.6's cycle, breadth first in text order over Bir edges. The
    budget: `nest_cost` 3 (below). `Report`'s R7 refusal and `keepOnlyRefusals` are gone.
  - **Two corrections to the spec, and no design premise failed.** (1) §10.2's "pair of deep
    declarations" is admitted by the rule as written (no single demand can be refused: the parser
    bounds a declaration below what one demand leaves); two demands in a row, each about 2 150
    deep, reach it — `scenario/NEST-DEEP`. (2) Round 3's N-2 debug assert (no nesting after a
    default) rests on a false premise: a default `Result` asks its positions' methods, which may be
    this module's and unchecked (`pending/check/good/NestAfterDefault.beni`, claimed); not added.
    Also: the round 3/4 refusals are `kind_mismatch`, not `type_mismatch` (`q "s"` after `q 1`),
    and their `.codes` were amended.
  - **`nest_cost`.** Measured in a Debug build: 15 552 bytes of stack per nesting of a
    reverse-ordered method chain, of which 4 solver depth units are the method's own nodes; the
    rest is 7 360 bytes; one depth unit costs at most 2 528 bytes (`let` chains; 2 048 through
    `and_`); 7 360 / 2 528 = 2.9 → 3. A chain nests about 599 deep; 1 000 links are refused once.
  - **Files** (lines): new `Groups` 545, `Recursion` 466; `Solve` 951, `Generalize` 378,
    `Module` 518, `Decide` 386, `Unify` 853, `Instances` 691, `Report` 383, `Messages` 268,
    `constrain/Tree` 432, `constrain/Expr` 450: 12 727 in all. `Groups` is past its ~450 (the
    frames live there, as §19.1 says); `Recursion` is new to the table.
  - **Claims (23, `CLAIMED`).** CK-36 `run/OwnMethodBeforeDefinition`; CK-63
    `run/OwnMethodDemandedEarly`, `run/OwnMethodDemandedTwoLetsDeep` (new); CK-64
    `run/OwnMethodValuePrefix`; CK-65 `run/MutualDispatchMethods` and the new
    `run/OwnMethodThreeCycle`, `run/OwnMethodFourCycle`, `run/OwnMethodCycleDemandedTwice`,
    `run/OwnMethodValueBackEdge`, `check/good/NestAfterDefault`; CK-70 `RecursiveDispatchTwoTypes`
    (both orders); CK-72 `RecursiveGroupReceiverNeedsAnnotation` (both); CK-73
    `run/ScrutineeMethodLater`, `check/good/ScrutineeMethodMergeVariant`,
    `check/bad/ScrutineeMethodMergeD14`; CK-76 `RecursiveGroupEvidenceReceiver`,
    `RecursiveGroupSubWanted`; `scenario/PERM`, `NEST-OVER`, `NEST-DEEP`, `NEST-UNDER`. The demand
    halves of CK-30, 31 and 66 are PERM's `m1b`, `dead`, `p5` and `ck66`. New corpus guard:
    `run/RecursiveDispatchAnnotated` (CK-70 with `eq` annotated: instantiates, no merge).
  - **Evidence.** The three gates, `test-pending` (every v2 line of an R7 fixture deleted from
    `RED`), `test-v2` (`run` 170 pass, `check/*` 236, `dispatch` 27; `v2-green.txt` +2:
    `run/DerivedEqLocalCustom` left `v2-expected.md`, and the new guard), `test-pending-perf` and
    `test-perf` green. `scenario/PERM`: 30 programs, 2 390 orders, all as the twin says, the three
    D14 programs, CK-70 and CK-73's refusal byte-identical in every order, and `dump
    --stage=types` equal in six orders of each program that checks. NEST-UNDER 1.96 (77 / 151 ms);
    NEST-OVER one `nesting_too_deep` at the 601st link with the hint; NEST-DEEP refused once, and
    the other order checks. JS parity: 170 `run/` fixtures build identical trees under v1 and v2;
    v2 at `--jobs=1` and at `--jobs=8` with both round trips identical on every `run/` fixture and
    on 349 `check`-kind fixtures, with no `internal`.
  - **Bench** (ReleaseFast, R6b's 90-module dispatch corpus, `check --no-cache --jobs=1`, the root
    package's `check` events, medians of 7, interleaved): v1 131.6 / v2 143.5 ms (1.09×), reversed
    132.1 / 145.4 (1.10×); the app variant's `build`, check + lower + emit, 1.05× (reversed 1.06×).
    R6b's own binary, measured beside it in 21 interleaved runs: v1 127.9, R6b v2 139.8, R7 v2
    139.9 ms — R7 costs nothing measurable on this corpus (a first cut cost 3 %: the forwarded
    queues, a larger `Frame` and `Wanted`; fixed by reusing queues, re-pointing items, and moving
    hand-down data out of line). On 40 000 one-line groups R7 still reads 2–4 % over R6b.
  - **Doubts, for the reviewer.** (1) The hint's syntactic reading is my rule for R7-2's "came
    from exactly one such reference": the context is the innermost `let` function, which may be
    wider than the receiver's own expression. (2) The §10.6 cycle is read off Bir edges by name;
    a merge made through a derived query has no such edge and prints the members in text order.
    (3) A queue slot is reused after its frame pops, so the "readied for a gone frame" invariant
    now catches less. (4) `Groups.check` settles v1's capability bits after a merged group only
    when its root is done; a derived query in between reads the bits as they were (R8a's). (5)
    §23 item 1's Roc shapes were not ported.
- **Revised by the reviews (2026-09-26).** A structural and an adversarial review (the latter
  fuzzing about 99 000 declaration orders) found I9 violated in one family and D14's hint
  order-dependent; fixed spec first (`static-dispatch-spike.md` §1.2 and §11 *Deferred receiver*,
  amended; `checker-v2.md` §10.8 rewritten, §9.1, §23 item 9's lost number):
  - **CK-105 (adversarial F1, blocking).** `x.combine 1` was a field call or a method constraint
    depending on whether `x` was already a record when the node was solved; inside a recursive
    group that is the declaration order (dispatch or value recursion). The rule is now: a
    dot-call's own requirement whose receiver becomes a record before it is generalised is the
    field call (`Instances.onRecord`). Fixtures `run/FieldCallThroughMember`, `…MemberCycle`,
    `…ValueRecursion`, `…ValueDemand`, `run/DeferredReceiverFieldCall` (the rule in one
    declaration: v1 and the old rule refuse it), `check/bad/RecursiveGroupFieldCallTwoTypes`;
    the first three fail on the reviewed tree.
  - **Structural B1 (blocking).** A group nested by the root's steps 1–3 that back-edges into the
    root was dropped from the root's members: the boundary is split into `Solve.settle` (1–3) and
    `closeFrame` (4–7), the members are read between them, and a frame merged during its own
    settle stops defaulting and hands down. §10.8 corrects the "shares no variable" reason and
    says why the joiner's facts coming after the defaults is order-independent.
    `run/MergeAtBoundary` (five `internal`s on the reviewed tree).
  - **D14's hint (adversarial F2, F3, F4; structural S1, S5).** Whether a mismatch is D14's is
    read at the mismatch (`Recursion.involved`, from the lowest open recursive frame's items,
    excluding receivers rule (a) held); the text is written when the class is final
    (`Recursion.finish` at the root's boundary, `Report.appendToItem`), from the mismatch's own
    declaration (found from its region) and the final class: the context is the called `let`
    function's body for a call argument, else the innermost `let` function. Fixtures
    `check/bad/RecursiveGroupHintOneMember`, `…HintAllMembers`, `…RuleAMonomorphicNoRecursionHint`.
  - **Adversarial F5.** Stated as I9's scope in §10.8 (I9 is "whether a program checks, and what
    it computes"): a refused program's message may render a type as it stood mid-solve, and which
    FURTHER errors a first error's poison silences inside a recursive group can depend on the order
    (the re-run call-graph fuzz shows one or two `kind_mismatch`es by order, as on the reviewed
    tree). PERM holds `check/bad/RecursiveGroupRefusalRendering` to its code and region.
  - **S2** a Debug build never reuses a queue slot, `frame` is a `u32` again, a sentinel between
    frames is asserted at every creation; **S3** `Generalize.handQueueDown` with
    `Evidence.repoint`/`Obligations.repoint`; **S4** the frame primitives and the generality check
    moved to `Generalize`, the Bir reading to a new `Producers.zig`; **S5** a total order for
    handed-down binders; **S6** R8a's brief gains the in-flight capability case; **S7**
    `Resolve.position` recursion counted in the budget (2 496 bytes per level, one unit). Nits
    N1–N8 done (N6: no D14 scan in a quiet module).
  - **Evidence.** The seven steps green. `scenario/PERM`: 41 programs, 2 752 orders. The review's
    fuzzers re-run on the fixed tree: the in-flight fuzzer, 300 programs / 36 000 orders, 0 whose
    acceptance or output differs by order (1 on the reviewed tree); the call-graph fuzzer with a
    helper, 138 programs / 15 600 orders, acceptance identical everywhere and 57 programs whose
    refused orders report one or two errors by order (a first error's poison; never a different
    hint on the same error).
  - **Bench** (ReleaseFast, quiet machine, medians): `check` of R6b's dispatch corpus v1 131.5 / v2
    142.8 ms (1.09×), reversed 133.1 / 143.8 (1.08×); the app build, check + lower + emit, 1.04×
    (reversed 1.05×). Against R6b's own v2 in 21 interleaved runs: 137.0 → 140.4 ms (+2.5 %).
  - **Files** (lines): `Groups` 592, `Solve` 860, `Generalize` 534, `Recursion` 157, `Producers`
    393.
- **Revised by the round-2 review (2026-09-26).** One blocker, fixed spec first
  (`static-dispatch-spike.md` §11 *Deferred receiver*, one sentence; `checker-v2.md` §10.8, §21.1
  D5 row):
  - **X1.** A dot-call joined by Rule U1 with a scheme's requirement inherited the `.field` answer
    when the dot-call was the older wanted, and P6 reported I7 (in a group, order-dependent).
    `Wanted.field_ok` is set for a dot-call's own wanted and cleared by any join with another
    (`Evidence.joinField` in `Unify` and `Resolve.attach`); the refusal is reported at the joined
    requirement's use (`blocked_at`). Fixtures `check/bad/DeferredReceiverJoinedRequirement/` (both
    `let` orders) and `…JoinedInGroup` (the `Rec1` variant), both `internal` with the join rule off.
  - **S2.** Corpus guard `check/bad/DeferredReceiverGeneralised` (the refusing half; v1 agrees on
    code and place; v2 renders the record before the lambda is constrained, a `v2-expected.md` row) and
    `tests/pending/run/DeferredReceiverRecursiveTwin` (accepted, prints `2`; v1 miscompiles it — it
    passes `f` a `compare` evidence and the program prints `EQ` — so it is a claimed pending fixture
    with a v1 RED line, not a corpus guard).
  - **S3 → CK-106.** A `number` receiver's non-well-known method in a group: `unknown_method` at
    the use, in every order (`Resolve.undeterminedInGroup`); `check/bad/NumberReceiverMethodInGroup`
    and `…Dispatch` (two `internal`s each before).
  - **S4, S5** written in §10.8 (confluent default order; a refused group's one error may differ in
    code and declaration by order). **S1** in R14's brief and a dated D5 row, decided by the owner (yes, 2026-09-26),
    recommended yes. Nits: stale comments, `declOf`'s linear scan said, queue reuse's coverage said
    (and PERM run once under ReleaseSafe: green), the scratch-arena comment.
  - **Evidence.** The seven steps green; `scenario/PERM` 48 programs, 2 796 orders (and green under
    ReleaseSafe).

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
  - *(Added by R7's review, S6, 2026-09-26.)* A derived query made while an own `eq` is in flight
    (its group `checking`, or merged with its root not done) reads v1's capability bits as the
    last settle left them — the one place R7 leaves where check timing feeds a verdict. The
    permutation scenario gains such a program (a derived `Box T` query inside `T`'s merged `eq`
    class), and R8a's fixpoint must give it one answer in every order.
  - `test-pending` is green.
- **Owed from R6a's review (2026-09-25, S4): ONE capability.** Until R8a, `check2/Instances.zig`'s
  derivability verdict reads v1's capability bits (`Types.answersEq`/`answersCompare`,
  `hasFunction`, `methodParamRequirement`, `hasPublicDispatchMethod`), which `Module.zig` and
  `Incremental.zig` settle with `Types.settleDispatchCapabilities`, and `Marker.zig` reads
  `Types.isEquatable`. R8a **removes every one of them from `check2/`**: the settle call in P2 and
  in the install path, the gate bits in `Instances.gate`/`isBoundary`/`nextStep`, and any second
  opinion on a nominal type's derivability (R6a's first round had one, `derivesNominal`, and it
  answered "derivable" for every non-foreign type: review B1). The fixpoint's result is the one
  answer the verdict reads. `rules_test.zig`'s S4 test fences the API today with
  `capability_readers` = `Instances.zig`, `Module.zig`, `Incremental.zig`; R8a empties that list,
  and the test then fails on any reader.
- **Owed from R6b's review (2026-09-25, S3): R6b's stopgap, deleted whole.** R6b added a second path
  of the same v1 shape — settle, then rows, then restore — and R8a leaves ONE: the fixpoint's
  answer is what the verdict, P5 and every dependent read, the table's rows are that answer, and
  nothing restores bits. R8a deletes:
  1. `check2/Eager.zig`'s row choice: `answersEq`/`answersCompare` and v1's module-wide `ownPub`
     suppression (a `pub eq` anywhere suppresses every type's `eq` row), and its
     one-entry-per-parameter context;
  2. `Types.restoreDerivedCapabilities` in `Module.zig` (after P9) and in `Incremental.install`
     (which runs it for v2 since R6b);
  3. P5's probe pass and dead-row propagation (`Eager.elaborate`: `collecting`, `deps`), a
     capability computation over answers that the S4 fence cannot see because it calls no API;
  4. `Report.notImplementedR8a` and every `.r8a` failure in `Elaborate.zig`/`Eager.zig`;
  5. `js/Emit.zig`'s `refuseV2LibraryTypes`.

  `rules_test.zig`'s S3 test fences items 3 and 4 to `Eager.zig`, `Elaborate.zig` and `Report.zig`
  today; R8a deletes that test with the code, and the S4 fence (with `Eager.zig` now among its
  readers) with the capability API.
- **Reviewer focus.**
  - Re-entry: the `same`-first and `key`-first orders of CK-74 must give the same `key` scheme.
  - A context computed while a dependency was in flight must never be memoised past its generation.
    Use a trace counter in a unit test.
  - The fixpoint on mutually recursive types with a function payload behind a custom method
    boundary (`e10` shape).

- **As built (2026-09-26).** `checker-v2.md` §11.2 *As built by R8a*, §11.1, §14.2 *Amended by R8a*
  (written first: hidden rows, three-word entries), §14.3, §19.1, §20.3.
  - **New files.** `check2/Contexts.zig` (units, memo and generations, the joint fixpoint, the
    in-flight branch and replay, P5's settle) and `check2/Derivable.zig` (THE verdict, moved out of
    `Instances` and reading the contexts). `Instances.derivedNominal` gives one sub-wanted per
    context entry (D4); `Eager` reads the settled contexts, and a permanent run's last passes are
    the rows' bodies.
  - **Deleted**, every item of the list above: `Eager`'s `answersEq`/`answersCompare` row choice and
    `ownPub` suppression and its one-entry-per-parameter context; `restoreDerivedCapabilities` in
    `Module` and in `Incremental.install` (a hit of a v1-checked module rebuilds v1's bits on v1's
    side, `Check.restoreCapabilitiesOnHit`); the probe and dead-row propagation (`collecting`,
    `deps`); `Report.notImplementedR8a` and `.r8a`; `js/Emit.zig`'s `refuseV2LibraryTypes`; the
    settle in P2 and after a method group (`Groups`). `rules_test.zig`'s S4 fence has an EMPTY
    reader list and its S3 fence is deleted with the stopgap.
  - **Beyond the list.** CK-89 (hidden rows, `run/HiddenTypeDerivedRow`); CK-79/82 (no field cap in
    v2, `ContextEntry.param: u32`, dispatch format 4); CK-87 (`Lower`'s part cap removed, promoted);
    CK-85 (a constrained value's body runs once per evidence: two module-level `let`s, not the
    per-call-site hoist — `static-dispatch-spike.md` A.85 *as amended by R8a*); CK-40 (schema
    properties settled when read, not per group); `absent_private` (CK-22's cross-module half).
    New finding CK-107 (`cache_store` super-linear, both checkers), proposed for R10.
  - **Evidence.** The three gates; `test-v2` green with no R8a row left in `v2-expected.md` and
    `v2-green.txt` +21 (the 13 `--library` builds, the four expected differences, and R8a's new
    corpus fixtures); `test-pending` green (claims: CK-23, 25, 69 ×2, 74 ×2, 77, 22's half, 24,
    `DerivedContextInFlightEq`, `DerivedContextAcrossModules`, `scenario/CK-79`, `scenario/CK-82`);
    `scenario/PERM` 56 programs and 3 354 orders, R8a's eight among them (CK-67 ×3, 69, 74, 77, S6, the joint SCC);
    `test-pending-perf` and `test-perf` green (CK-40 and CK-75 v2 twins added); a cold/warm matrix
    in `cache_test.zig`.
  - **Bench** (ReleaseFast, `--no-cache --jobs=1`, the root package's `check` events, v1/v2
    interleaved, medians of 7; the repo's generator, `bench -- --generate=100000 [--dispatch]`):
    R8a's v2 is 4c70702's v2 within noise on both corpora, in two sessions (dispatch 108.2 / 108.2
    and 114.0 / 113.4 ms, plain 97.2 / 96.5 and 100.3 / 101.6). **The v2/v1 ratio is NOT at the
    1.10× the brief asks on these corpora: 1.16–1.21 at 4c70702 and 1.13–1.20 now** — the gap predates
    R8a (v2's generalisation, `adjustRanks`, `closeFrame`, `enter`, `Walk.owned`, leads its profile), and
    R7's own 1.09–1.10 was measured on R6b's 90-module corpus, which is not in the repository. The
    dispatch corpus's `--library` `build` (check + lower + emit), which v2 refused before, is
    1.10–1.12×. On CK-42's worst case (8 000 types, each compared) v2 is 8 % over 4c70702: a
    fixpoint frame per unit.
- **Review round (2026-09-26).** Two reviews (structural, adversarial); spec first
  (`checker-v2.md` §11.2 *Amended by R8a's review round*, §14.2 *amended again*, §14.3;
  `language.md` §6 and `static-dispatch-spike.md` A.85 narrowed).
  - **Blocking, fixed.** B1 = **CK-108** (a marker's `equatable` flag is an entry; three
    `check/bad/DerivedContextEquatableFlag*` fixtures blessed from v1, whose text v2 improves on:
    `v2-expected.md` + a v2 guard in `blackbox_test.zig`). The crash = **CK-109** (`Param.k` and
    Lower's indices `u32`; `Eager.markerKeys`; one row scheme per derived row instead of one per
    entry, which was n² × m words: 656 × 100 went from 74 s / 3.1 GB to 3.4 s on Debug, v1 8.9 s;
    `abuse_wide_test.zig` "CK-109", `scenario/CK-82` at 65 537 fields). CK-42: not a regression
    of the ratio — perf stat, 20 runs each, gives extra(2n)/extra(n) = 2.18 at 4c70702 and 2.16
    now; `test-pending-perf`'s 2.42 and the manager's > 2.5 are the noise of a 7 ms difference.
    The absolute cost is +9 % on E2 (8 000 types): `Contexts.run`, `readPayloads`,
    `resolvePayloads` and the verdict, one fixpoint per type, which P5 needs to publish rows.
  - **Should-fix, done.** S2 = **CK-110** (the hidden set closed over own alias bodies; the v1-ABI
    fallback only for another package's record, `Context.oldCheckerWrote`); S3 (`isEquatable(`
    fenced, `Marker.zig` its one reader); S4 (bodies per `Run`, committed with the answers); S5
    (the argument written in §11.2, a Debug `Walk.sameShape` assert);
    CK-85's text narrowed to evidence identity, the hoist filed as CK-113;
    the nits (`Derivable.foreignDerives` is the one foreign rule, the replay guard on `valid(u)`,
    Publish's status mapping commented, Lower's declaration evidence `u32`).
  - **Filed, not fixed.** CK-111 (quadratic nested-record `==` per use, v2), CK-112 (a type of n
    parameters is O(n²) in lowering and the reader, both checkers: the 32 769-parameter shape
    takes 18 s under v2 and 362 s under v1, Debug), CK-113, CK-114 (`Unify.max_depth` refuses a
    ≥ 2 100-deep literal), CK-115 (UNKNOWN METHOD after a TYPE MISMATCH, R13), CK-116 (the
    not_equatable hint when a payload method's requirement failed, R13: the reason must ride on
    the answer and the published row), CK-117 (the linear frame assert the review proposed was
    built and fails on three claimed fixtures and `scenario/PERM`: a pass that demands a group
    which merges into the asker's takes its variables below the fixpoint frame; the outputs are
    right, the assert is not shipped, R8b proposed).

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
- **As built (2026-09-26).** `checker-v2.md` §11.1 *amended by R8b*, §11.2 *amended by R8b*,
  §11.3 *as built by R8b*, §11.4 *amended by R8b*, §11.5 *as built by R8b*, §14.2 *amended by
  R8b*, §14.3; `schema.md` A.6 amended (written first).
  - **D1 end to end.** `Contexts.module_has` counts a value of the name `pub` or not
    (`module_pub` says which), so a private `eq` suppresses every derived `eq` row of its module.
    `absent_private`'s culprit is a `TypeId`; the record gains a `private_method` row status with
    a two-word culprit `(type_ref, method)` (interface format 4 → 5), which `Derivable.head` and
    `Instances.derivedNominal` read, so a third module is refused too. The use-site message
    (`Messages.privateMethod`, `Instances.refusePrivate`) names the private method, its type and
    the value that holds it; a direct receiver keeps v1's text.
  - **Schema endpoints through the one fixpoint.** Tagged endpoints are unit members
    (`Contexts.derives`); their payloads come from `Schema.State.payloads`, substituted with the
    markers; mentions follow `top_schema` references; a `via` mention the unit graph cannot see is
    joined lazily (`noteApprox`: the runs above partial, the pass below re-run); every schema a
    unit reads is demanded by the asker before the run (`demandSchemas`); a comparison inside the
    schema's own group is `method_needs_annotation` naming the schema; payload reads get fresh
    endpoint copies (`Schema.State.lookupFresh`). P5 writes endpoint rows, P8 publishes endpoint
    hidden rows with their §11.4 gate (`Marker.endpointEquatable`), P9 reads the plan's property
    bytes off the verdict (`Derivable.propertyBits`).
  - **Deleted from v2's path:** `Schema.settleProperties` (Module P1–P4), `Solve.settleSchemas`
    and `schemas_dirty`, `Groups`'s schema scan and its `types` field, `Derivable`'s
    `schemaPropertyBits` branch, `Instances`' `undetermined` endpoint answer, `Decide`'s settle
    before the marker walk, and the install path's schema-bit restore for a module v2 checked (a
    module v1 checked restores on v1's side, `Check.restoreSchemaPropertiesOnHit`).
    `rules_test.zig`'s S4 fence lists the settle, the bits and `settleSchemas`.
  - **CK-117.** A pass whose demand returns a method in flight takes §11.2's in-flight branch
    (`Instances.ownMethod`). The frame assert ships in the linear form that separates the real
    channel from the benign ground sharing R8a's pool assert tripped on: no unification changes,
    and no wanted rides on, a flex of an older frame while a fixpoint frame is current
    (`Unify.assertContained`, `Resolve.attach`; Debug).
  - **Found:** CK-118 (v1 refuses a type wrapping a record schema endpoint; claimed). An
    `internal` in v2 before the fix (a pass answered from an earlier pass's approximation through
    a shared endpoint root) is fixed by `lookupFresh` and pinned by
    `check/bad/SchemaWrapperExclusionThroughOwnType`.
  - **Evidence.** The three gates; `test-v2` green with `v2-expected.md` gaining only
    `dispatch/PrivateEqStillDerives` (D1) and `v2-green.txt` losing it; `test-pending` green with
    8 new claims (CK-22 ×2, CK-23's cross-module marker twin, CK-24 ×2, CK-117, CK-118 ×2);
    `scenario/PERM` 64 programs, 3 890 orders (R8b's eight among them); `test-pending-perf` and
    `test-perf` green. Bench (ReleaseFast, `perf stat -r 11`, whole process, `check --no-cache
    --jobs=1`, two rounds): v2/v1 = 1.04 on the plain corpus (161.0/154.6, 161.8/155.3 ms) and
    1.06 on the dispatch corpus (174.2/164.1, 175.1/164.8 ms); v2 at R8b is 2.4–3.3 % faster
    than v2 at `b64342b` on both.
- **Review round (2026-09-26).** Two reviews (structural, adversarial: ~60 D1 probes and 2 364
  fuzzed comparisons, no D1 hole). Spec first: `checker-v2.md` §11.4, §11.5 and §14.2 *amended by
  R8b's review round*; §1.1 above (the six root causes) added.
  - **Blocking, fixed.** CK-119: the lazy `via` join was exponential and at the step budget said a
    false `not_equatable`. `Contexts.complete` now makes the unit graph exact before a unit runs
    (the schemas it reads demanded, their `via` targets' mentions added as edges, the units rebuilt
    with their state carried by member); `partial` and the cross-run join are deleted (a cross-run
    read is `internal`); a budget in a pass is `absent_budget`, `nesting_too_deep` at the use; the
    worklist asserts it climbs and caps at 2²² passes; nested runs' internals are said by the
    outermost run (they were lost). `test-perf` "CK-119" (4 000 / 8 000: 38 / 72 ms, 1.89; red with
    `complete` disabled). CK-121: v2 panicked on a bodyless annotation with a `where` clause
    (`Module.elaborate`); corpus fixtures from v1's diagnostics.
  - **Should-fix, done.** CK-120: the marker's gate of an `adt` is `Marker.functionFree` (payloads,
    through own endpoints and `via` targets), published as `no_function` (a bit in the flag bytes;
    format 5). The in-flight refusal narrowed (rule 7): a closed type is deferred and checked in P5
    (`Contexts.checkDeferred`), an encoded endpoint is never in flight, only a parametric type is
    refused, with a hint naming the conversion. S4: the fence lists `isComparable(` and the
    settled bits read as fields, with `entry.equatable`'s readers. Nits: one copy routine in
    `Schema.State`, the message names `T`, declared in `A` (the value renders unqualified), the
    marker walk's flags covered by the CK-117 assert, comments.
  - **Filed, not fixed.** CK-122 (an alias of a schema endpoint: `internal` / false refusal, both
    checkers; an R8b follow-up proposed before R9), CK-123 (a polymorphic `via` target leaks a free
    variable; schema S3/S4), CK-124 (frontend quadratic in the number of schemas), and the F6
    message as CK-116's second program (R13).
  - **Evidence.** All seven steps green: `test-v2` 939 pass, 0 fail, 29 skipped (`v2-green.txt`
    +5: CK-121's two, the closed and encoded in-flight guards, the schema ring); `test-pending`
    with 122 fixtures green under v2 (+3 claims: CK-120 ×2, the in-flight function case) and
    `scenario/PERM` 68 programs, 4 146 orders; `test-pending-perf` as recorded (CK-88 red, R12);
    `test-perf` 12 scenarios green. Bench (ReleaseFast, `perf stat -r 11`, whole process, two
    rounds): v2/v1 = 1.04 on the plain corpus (161.3/155.5, 163.8/157.1 ms), 1.06–1.07 on the
    dispatch corpus (176.3/164.8, 175.3/165.3 ms).
- **Round-2 review (2026-09-26).** Spec first: `checker-v2.md` §11.4 and §11.5 *amended by R8b's
  round-2 review*; §1.1 rows 3–4 corrected.
  - **Blocking, fixed.** B1 (CK-120 again): `Marker.functionFree` takes the solver, completes the
    graph around the type (demanding every schema with a `via` it can reach) and is unknown while
    one is in flight — the walk passes for now and the type is asked again in P5
    (`Contexts.deferred_gates`); nothing is memoised across an unfilled target. Fixtures
    `check/bad/EquatableMarkerUncheckedSchema.beni` and `…InFlightSchema.beni` (claimed; red
    before); `scenario/PERM`'s `.refused` now takes an exact `count` of diagnostics, all of the
    code, and the local CK-120 fixture is in it with both uses counted.
  - **Should-fix, done.** S1 (CK-125): a run's own step budget; `absent_budget` never memoised;
    `internal` at P8 (`test-perf` "CK-125", both orders; red with the budget shared). S2:
    `complete` walks only types not yet `completed` and merges units locally (ids never
    renumbered, `ensure` walks members' edges, P5 invalidates and `ensure`s every unit), stamps
    in `viaEdges`; `test-perf` "CK-119 many" (the comparisons' cost over a no-comparison control,
    4 000 / 8 000 schemas: 10 / −1 ms; red at 1 031 / 4 103 ms with a whole-graph rebuild per
    call put back). Not done: completing from every type at the first `ensure` — an order
    dependence in merges (§11.5 *amended by R8b's round-2 review* says why). S3: the overclaims
    corrected. Nits: `climbs`' comment, `checkDeferred` deduplicates by a set, the fence's
    spellings (`e.equatable`, `).equatable`), CK-124's note extended (and `Schemes.Writer.typeRefOf`
    made a map, shared code).
  - **Evidence.** All seven steps green: `test-v2` 939 / 0 / 29; `test-pending` with 124 fixtures
    green under v2 (`CLAIMED` 125) and `scenario/PERM` 71 programs, 4 506 orders;
    `test-pending-perf` as recorded (CK-88 red, R12); `test-perf` 14 scenarios green. Bench
    (ReleaseFast, `perf stat -r 11`, two rounds): v2/v1 = 1.04 plain (168.4/162.1, 169.9/163.8
    ms), 1.04–1.06 dispatch (183.8/177.0, 184.7/174.5 ms).

### R8c — Performance and limits (added by the manager, 2026-09-26)

- **Goal.** Before R9 makes v2 check `core` under a strict ≤ 1.10× budget, remove v2's measured
  per-operation overhead and its known super-linear cases. R8a's structural review profiled v2 at
  1.15× on the generated corpora (the same work, more cycles per operation); the whole-process
  figure at `b64342b` is 1.07×, which leaves no headroom.
- **Scope.**
  - The profile's causes: rank adjustment (`Generalize.enter` pushing a frame per young leaf,
    `Walk.owned` decoding content repeatedly, the counting sort when every entry is young), `Unify`'s
    linear `active` scan (CK-93's note) and flex-flex fast path, P6 hashing every `.call` in modules
    without evidence, per-group instantiation of imported schemes; a self-profile span on P5–P9.
  - CK-111 (quadratic nested-record `==` per use: `Derivable`'s colour map re-walks non-ground
    subtrees), CK-114 (a record literal nested ≥ 2 100 deep refused by `Unify.max_depth`), CK-112
    (O(n²) in a type's parameter count, both checkers), CK-93 (growing `let` chains).
  - The `scenario/CK-42` v2 twin is flaky: v2's extra cost is 8–10 ms, so its ratio reads 1.7–2.4
    against a 2.5 bound and failed one of five runs at `3c09146`. Size it for v2 (larger n, or more
    runs per point) so the scenario measures, not samples noise.
  - CK-122 first, as its own commit: a `type alias` of a schema endpoint gives `internal` in both
    checkers, and wrapping it gives a false refusal. R9 must not start with an `internal` on valid
    code.
- **Exit criteria.** Gates, `test-pending`, `test-v2`, both perf steps green; each CK fixed is
  promoted with a `test-perf` scenario; v2/v1 ≤ 1.05× whole-process on both generated corpora
  (perf stat, ≥ 9 runs), and each change's gain measured separately.
- **As built (2026-09-26).** Spec first: `checker-v2.md` §5 *as built by R8c*, §7.3 *amended by
  R8c*, §8.2 *amended by R8c*, §11.5 *amended by R8c* (CK-122), §18 *as built by R8c*, §19.1
  *after R8c*.
  - **CK-122, its own commit.** The shared alias reader (`Types.Builder.aliasBody`) built its inner
    reader with no schema lookup and no interfaces, so an endpoint in an alias body was a silent
    `err`: a comparison was `internal`, a wrapper a false `not_equatable`, and any other use a hole
    (`r + 1` on an `RW` checked in both checkers). The body of the checked module's own alias now
    reads with the caller's lookup; another module's through that module's interface
    (`Types.schemaMemberOfDecl`, an index built with the table); a private tagged schema's endpoint
    as its nominal type. The interface's `alias RW` with no body row is not a defect: no alias row
    prints a body. Fixtures `check/good/SchemaEndpointAlias.beni`, `…AcrossModules/`,
    `check/bad/SchemaEndpointAliasKeepsItsType.beni` (red before under both checkers), `v2-green`
    +3. Found: **CK-126** — a private RECORD schema's endpoint through another module's `pub`
    alias is still a silent `err` in the importer (both checkers; the fix is an interface row;
    pending, `RED` lines under both).
  - **Performance, each change measured alone** (ReleaseFast, `perf stat -r 11`, whole process,
    `check --no-cache --jobs=1`, two interleaved rounds, the dispatch corpus's user cycles and
    instructions; the plain corpus moved alike):

    | Change | v2 cycles | v2 instructions |
    |---|---|---|
    | parent (`3c09146` + CK-122) | 549.0M (v1 509.4M, 1.08×) | 1 087.2M |
    | rank adjustment: successors on a stack, leaves answered at once, one-rank pools unsorted | −5.2M | −5.4M |
    | Unify: bounded pair scan, flex-flex fast path, `reportJoins` guard | −1.1M | −4.9M |
    | rank adjustment: successors answered from the parent's frame | −6.9M | −17.5M |
    | pool compacted to roots after step 2 | −1.8M | −10.6M |
    | P6: no call map without evidence, a dense one otherwise | −2.8M | −5.3M |
    | CK-111 (open derivability memo, positions' proofs, array hash map; first form) | −1.2M | +0.2M |
    | CK-112, CK-114 | noise | ±0 |
    | CK-93 (acyclicity stamps; first form) | +0.6M | +6.3M |
    | review round: the proofs in the store, voided by any edge (B1, B2; checked first on the cheap half) | +3.5M | +4.7M |
    | review round 2: the broad `err` rule, childless pairs unpushed | +6M | +3.7M |
    | **R8c** | **542–543M (v1 513–514M, 1.054–1.058×)** | **1 058.2M** |

    Whole process after the review round, against the parent, v1 from the same binary: plain
    corpus v2/v1 = 1.02 in cycles (485–486 / 475–476M), 1.02–1.03 in task-clock (162–163 / 158–160
    ms); dispatch corpus 1.05 in cycles (536 / 511M), 1.03–1.04 in task-clock (177–178 / 170–173
    ms). The parent: 1.05–1.06 and 1.07–1.08 in cycles. v1 moved +2.6M instructions (0.25 %: the
    shared CK-112 and CK-122 code and one branch per content write). Kept all; the proofs (stamps
    and their upkeep) cost about 1 % of instructions against a build that keeps none, and are
    CK-93's and CK-111's price. Not done: per-group memoisation of imported schemes (§18 says why). `--self-profile`
    gains `derived`, `elaborate`, `publish`, `finish` per module under v2 (`blackbox_test.zig`).
  - **CK-111** (`test-perf` "CK-111", d = 1 000 / 2 000, 64 uses: 10.5 / 44.3 s, ratio 4.20 on the
    parent; 0.29 / 0.58 s, 2.03, now). Three walks per nested position: derivability (a verdict over
    variables kept while no leaf it met is given successors, `Resolve.State.derivable_open`), the
    §9.5 cycle test (it proves every node it walks, so a position is proved already; Debug re-walks
    a proved receiver at depth < 64), and the new deep-pair hash map's tombstones (an array hash
    map popped in order).
  - **CK-114** (`abuse_test.zig`). The solver's per-declaration guard, not `Unify.max_depth`: a
    record literal spent two depth units a level. `Solve.solveFields` makes it one; 4 095 levels
    check and compare under both checkers, 4 096 is the parser's one `nesting_too_deep`. Found:
    **CK-128** — running such a comparison throws `RangeError` in node from about 4 000 levels
    (both checkers; the derived `eq` recurses a level at a time); the owner assigned it to R8d.
  - **CK-112** (`test-perf` "CK-112", 16 000 / 32 000 parameters: 253 / 913 ms, 3.60, on the
    parent; 42 / 78 ms, 1.85, now). Shared code: `Lower.type_param_index` past 8 parameters, and
    `Types.Builder.typeVar` reads the slot `TypeVarInfo.param` names. v1 keeps a quadratic of its
    own (frozen).
  - **CK-93** (`test-perf` "CK-93", 8 000 / 16 000 bindings, on the module's `check` event:
    602 / 2 359 ms, 3.92, on the parent; 6.3 / 12.5 ms, 1.97, now). Measured on the event because
    lowering the `let` is itself quadratic: **CK-127**, found (frontend, unassigned).
    `perf_test.zig` gains `eventRatio` for it.
  - **`scenario/CK-42` under v2** takes n = 32 000 and the best of 7 per point (v1 unchanged).
    Ten runs: 1.92–2.22, median 2.09 (at 16 000: 1.73–2.22; at 4 000 before: 1.7–2.4). The
    `test-pending-perf` step now takes about 40 s once its compiler is built (it was about 22 s).
  - **Review round (2026-09-26).** Spec first: `checker-v2.md` §8.2 *restated by R8c's review
    round* (its two R8c claims were false).
    - **Blocking, fixed.** B1: a merge that gave an `err` class structure (`Unify.flat` writes
      content read before the children were unified) added an edge no bind made; the stamp moved
      to the survivor, one INFINITE TYPE of two was lost (a cyclic type in a scheme, a 1.4 GB
      dump), and with CK-126's `err` an infinite type was accepted. B2: a position inherited its
      parent's proof across a Rule U1 join and a user instance's unification that closed
      `x = List x` with no demand in between (a Debug panic). Both have one fix: the proofs moved
      into `TypeStore` (`acyclic`, `prove`, `proved`), which sees every content write; a proved
      node with no successors given some voids every proof (`gains`), and a proving run records
      every leaf it meets (flex, rigid, `err`). Positions inherit nothing: §9.5's run records every
      node it blackens (`Occurs.interior`), so a position is proved already. `flat` still writes
      the structure (v1's and `5f18e23`'s behaviour; the write is now seen), so no golden moved.
      The open derivability memo is voided by the same epoch (the walk records the leaves it
      meets); `Unify.binds` and `Groups.demands_made` are gone. v1's stores do not track
      (`tracks_proofs`), one branch per write.
    - **Fixtures** (`blackbox_test.zig`, v2, the Debug binary): "R8c review B1: a merge that
      gives an `err` class structure …", "… an infinite type through a schema alias's `err` …",
      "R8c review B2: a cycle closed between a receiver's test and its positions' …", each the
      reviewer's repro with `5f18e23`'s v2 output; red with the voiding switched off (one
      INFINITE TYPE of two; exit 0; the Debug panic).
    - **Fuzz, against `5f18e23`'s v2** (ReleaseFast, `check --diagnostics=json` plus
      `dump --stage=types`; the position programs also on the Debug binary for panics): 3 000
      let-chain programs and 5 500 position programs (user `eq`/`compare` of five shapes, depths
      1–200, `x.eq y` interleaved): 0 differences, 0 panics. The same fuzz finds about 1 100 and
      2 900 differences with the voiding switched off. And 562 corpus and pending fixtures give
      identical `check` JSON and type dumps, bar the three CK-122 fixtures.
    - **Docs.** CK-125's `Slice` line restored; CK-128 rewritten with the review's measurements
      (3 747 levels, an 8 940-cell user list, Elm's explicit stack), its slice R8d (the owner,
      2026-09-26); R8d added below.
  - **Review round 2 (2026-09-26).** Spec first: `checker-v2.md` §8.2 *restated by R8c's two review
    rounds* (the invariant stated — *a proved node's graph is acyclic and every node without
    successors in it is proved* — and the first round's "an edge is added in exactly one way" and
    "`merge` only redirects a class to a survivor whose children were unified first" corrected;
    the nonexistent `TypeStore.leaf_binds` citation gone), §7.3 (childless pairs).
    - **Blocking, fixed.** Both through `err`, the one leaf that absorbs structure. B1: a record
      merge past a proved `err` row end — the extra fields merge into the `err` (no leaf gains
      successors), the merged record carries them unwalked, the proof moves to the survivor; an
      infinite type accepted again (exit 0, with CK-126's `err`). B2: an unproved interior node of a
      proved graph turned `err`, then `Unify.flat` wrote structure over it: a cyclic scheme reached
      `f`. Fix: **the `err` rule** (`TypeStore.touchesErr`), the reviewer's verified form — any write
      where one side is `err`, before or after, and any side has successors voids every proof. The
      implementer first shipped a narrower rule (only a node with successors turned `err`, which
      the invariant alone allows); **the manager chose the broad rule** (2026-09-26): two holes had
      already come from arguments that a narrower condition sufficed, and the broad rule is the one
      the review verified. It reads contents on every merge: +8.7M instructions on the dispatch
      corpus (0.8 %).
    - **Debug detector.** `Walk.assertProved`: wherever a walk stops at a proved node, a walk of its
      own that trusts no proof and touches no mark (≤ 1 024 nodes) panics if the node reaches a
      cycle. With the `err` rule switched off it panics on both programs.
    - **Nits.** A rollback voids the proofs (v2 never speculates). The derivability memo keys on
      `TypeStore.proof_voids`, a count that does not wrap as the epoch does. The `gains` and
      `TypeStore` comments say what the rules are.
    - **Fixtures** (`blackbox_test.zig`, v2, Debug): "R8c review round 2, B1: a record merge past a
      proved `err` row end …" (INFINITE TYPE at 21:9) and "… B2: an interior node that became `err`
      and then structure …" (one NAMING ERROR, `f : a -> ( ?, String )`); red before as a Debug
      panic of the detector, and in ReleaseFast as the reviewer reports.
    - **Fuzz** (my generators; the reviewer's were gone): 12 000 record-heavy programs with an
      `R Models.PrivRecW` err-row parameter (two in three), `case` binders and `List.length`
      hiding, against a build that trusts no proof (`np`); 3 000 let-chain programs (with `bogus`
      leaves) and 5 500 position programs against `5f18e23`'s v2; every program also on the Debug
      binary with the detector. 0 differences, 0 panics — before and after the childless-pair
      change below. With the `err` rule switched off the record fuzz finds 744 differences.
    - **Bench, by choice over the line.** Unify no longer pushes a coinduction pair for two
      childless structures (`isChildless`, §7.3): −5.8M instructions. With the broad `err` rule,
      `perf stat -r 11`, two rounds, v1 from the same binary: plain 1.031–1.033× in cycles
      (493 / 478M), 1.03× in task-clock; dispatch **1.054–1.058×** in cycles (542–543 / 513–514M)
      and 1.056–1.058× in task-clock (181–183 / 172–173 ms); v2 1 058.2M instructions (v1
      1 029.2M). R8c's ≤ 1.05× was the manager's own target, not a budget: R9's is 1.10× (§18). The
      manager accepted about 1.055× for the broad rule (the narrow rule measured 1.050×). With the
      narrow rule and no coinduction change the tree read 1.055×; the measured costs left are the
      proofs CK-93 and CK-111 need and Unify's own content loads.
  - **Evidence** (after review round 2). The three gates; `test-v2` 942 / 0 / 29; `test-pending`
    green (`scenario/PERM` 71 programs, 4 506 orders; CK-126 red under both, recorded);
    `test-perf` 17 scenarios green (CK-111 1.98, CK-112 1.92, CK-93 1.99), the three new ones red
    on the parent binary through the same harness; `test-pending-perf` green in 23 runs before the
    review rounds and 3 after each, and once more with the broad `err` rule (round 2:
    `scenario/CK-42` 2.04–2.21, then 2.05; CK-88 red, R12's). Fuzz with the broad rule: the three
    families again, 0 differences and 0 Debug panics.

### R8d — Derived `==` and `compare` never throw on deep data (added by the manager, 2026-09-26)

- **Goal.** CK-128, the owner's decision of 2026-09-26: a derived `eq` or `compare` must never
  throw on deep data. Fix it the way Elm does (`_Utils_eqHelp`): recurse to a depth threshold,
  then continue from an explicit stack, so the native stack does not grow with the data. No
  `RangeError` on any value the program can build.
- **Scope.** The emitted derived `eq` and `compare` (records, tuples, nominal types, their
  evidence), in development and `--release`, under both checkers while v1 emits. Spec first:
  `backend.md` states the rule and the threshold.
- **Exit criteria.**
  - A `run/` fixture that builds two 100 000-cell user linked lists (`type L = Cons Int L | Nil`)
    and compares them with `==` and `<`, and a record nested 10 000 deep compared with `==`,
    printing the right answers in dev and `--release`; red before the fix (`RangeError`).
  - An abuse test at the parser's limit (a record literal 4 095 deep, compared and run).
  - Small programs' emitted JavaScript byte-identical where possible; every golden that moves is
    listed with the reason.
  - The gates, `test-pending`, `test-v2` and both perf steps green.

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
  - *(Added by R7's round-2 review, S1, 2026-09-26; decided by the owner 2026-09-26: yes; recommended
    yes — `checker-v2.md` §21.1's D5 row of that date.)* A `let` whose constrained variables carry
    only dot-calls' own requirements stays monomorphic in them, so `run/DeferredReceiverFieldCall`'s
    `let call s = s.f 10 in call { f = … }` keeps its field call. R14's reviewer re-runs the
    in-flight probes of R7's reviews against a `let` that holds such a dot-call inside a merged
    member.
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
| R5 | CK-96, 97, 98 (into `perf_test.zig`, `test-perf`); CK-99 (a `run/` guard) — all four found by R5's reviews and fixed in R5 | CK-05, 06, 16, 51, 68; CK-62 (two dispatch-free fixtures; `run/TryDecidedByLaterFacts` waits for R6a); CK-09 (a five-member `check/good` fixture) | CK-18; CK-59 (the generation half); CK-94 gains F8 (the name hint follows member order) |
| R6a | — | CK-02, 03, 09 (`check/bad` half), 20, 21, 48; CK-100 (found and fixed by R6a); CK-101 (found and fixed by R6a's review); CK-03, 42, 80, 101 as v2 timing scenarios in `perf_test.zig` (`test-perf`); CK-62's `run/TryDecidedByLaterFacts` moves to R6b (it needs `build`) | CK-35; CK-37, 55 (part) |
| R6b | — | CK-08, 27, 28, 29, 32; CK-62's `run/TryDecidedByLaterFacts` (from R6a); the `run/` fixtures of CK-30 (`RecursionWithComparison`, `DeadMiscount`), CK-31, CK-66 and CK-67, which P6 answers ahead of R7 and R8a (their slices keep the rest of each finding); CK-102 (found and fixed by R6b); CK-103 (found by R6b's review, claimed); CK-80's `build` half (`perf_test.zig` "CK-80 build") | CK-104 (found by R6b's reviews; a backend fix, promoted: `run/DerivedRowBodyEmissionOrder`, with a claimed permuted CK-67 twin) |
| R7 | — | CK-30, 31, 36, 63, 64, 65, 66, 70, 72, 73, 76; CK-105 and CK-106 (found by R7's reviews, claimed) | — |
| R8a | CK-87 (promoted, `run/DerivedEqDeepRecord`); CK-85 (fixed in the shared emitter, its guard re-blessed) | CK-23, 25, 40, 67, 69, 74, 75, 77, 79 (the field cap lifts with D4's signature; manager 2026-09-24); CK-22's cross-module half and CK-24, green early (R8b's) | CK-107 found (`cache_store`, both checkers; R10 proposed); CK-108 to CK-110 found by its reviews and fixed in the slice; CK-111 to CK-114 found (CK-112 by R8a, the rest by its reviews; the perf and limits slice proposed); CK-115 and CK-116 found by its review (R13); CK-117 found by its review round (R8b proposed); CK-26; CK-82 (with CK-79); CK-85 (owner 2026-09-25); CK-89 (R8a, manager 2026-09-25: amend §14.2 so derived rows cover every nominal type reachable from a published scheme, before R8a reads them) |
| R8b | — | CK-22, 24, 117; CK-118 (found by R8b, claimed); CK-120 (found by its review round, claimed) | CK-119 and CK-121 (found and fixed by its review round), CK-125 (found and fixed by its round-2 review); CK-122 (R8b follow-up proposed, before R9), CK-123 (schema S3/S4 owner), CK-124 (frontend, unassigned) |
| R8c | CK-122 (fixed in shared code, both checkers: `check/good/SchemaEndpointAlias*`, `check/bad/SchemaEndpointAliasKeepsItsType`); CK-114 (`abuse_test.zig`) | — | CK-93, 111, 112 as v2 timing scenarios in `perf_test.zig` (`test-perf`); CK-42's v2 twin resized; CK-126 (found, pending, red under both), CK-127 (found, frontend) and CK-128 (found; R8d) |
| R8d | CK-128 (a `run/` fixture and an abuse test; the owner, 2026-09-26) | — | — |
| R9 | — | — | CK-15 (rest) |
| R11 | all claims above | — | — |
| R13 | CK-49, 50, 52, 53, 54, 55, 56, 58, 59, 60, 86 | — | — |
| R14 | CK-37 (rest) | — | — |
| (assigned 2026-09-24) | — | — | CK-81 is R2a's and CK-79 is R8a's (manager) |
| (assigned 2026-09-24) | — | — | CK-82 → R8a (with CK-79); CK-83 → R2c, a new backend slice after R2b (manager) |
| (found by R2c, 2026-09-25; assigned by the manager: CK-87 → R8a, CK-88 → R12) | — | — | CK-87 (derived `==` past 32 nested record levels is `internal`) and CK-88 (a `case` of many literal branches: quadratic emit, and past 65 046 a `switch` Firefox refuses): unassigned, for the manager |

Every one of the 128 entries appears in this table (CK-126 to CK-128 added by R8c, CK-118 added by R8b, CK-119 to CK-124 by its review round, CK-125 by its round-2 review, CK-100 added by R6a, CK-101 by R6a's review, 2026-09-25, CK-102 by R6b, CK-103 and CK-104 by R6b's reviews, CK-105 and CK-106 by R7's reviews, CK-107 and CK-112 by R8a, CK-108 to CK-111 and CK-113 to CK-117 by R8a's reviews and review round), CK-75 (a performance finding added after R0) included: the manager assigned it to R8a on 2026-09-24 (to R10 if R8a's profile shows the residue is `dep_digest`). CK-71 (R0's: `Session` symbol ids depend on thread timing) was assigned to R1 on 2026-09-24. *Updated 2026-09-24 for round 3: the slice
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
