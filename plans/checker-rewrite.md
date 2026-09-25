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
- **Fail-first (rule 3).** Every CK the slice closes already has a red fixture in
  `tests/pending/`, written by R0. The slice's evidence is that fixture turning green, and then
  either being **promoted** into `tests/corpus/` or being **claimed** (§2.6).
- **Determinism (rule 5).** Any new order is by source position, group index, wanted id or name
  text.
- **Workflow** (`plans/queue.md` "How a slice runs"): an implementer and a read-only reviewer per
  slice; the manager validates, commits and writes the diary. The **reviewer focus** line of each
  slice says what that reviewer must try to break.

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
checker and timeout empty, meaning the defaults), `test-pending` and `test-v2`.

`corpus_test.zig` treats an empty value as unset. So a variable exported in the shell, left over
from running `test-v2` by hand, cannot turn a gate into report mode, point it at another root or
switch its checker. R0's exit criteria check it by hand: export
`BENI_CORPUS_MODE=report BENI_CORPUS_ROOT=tests/pending BENI_CHECKER=v2`, run `zig build
test-blackbox` with a deliberately broken corpus fixture in a scratch branch, and confirm it still
fails.

**In `build.zig`**, one step, `test-pending`, depending on install:

- **Run 1:** `corpus_test.zig` with `BENI_CORPUS_ROOT=tests/pending BENI_CORPUS_MODE=pending`, the
  default checker.
- **Run 2, from R4:** the same plus `BENI_CHECKER=v2`. Here rule (b) applies to v2 only after R11,
  when v2 is the default.
- **`tests/blackbox/pending_test.zig`:** the performance scenarios and the permutation scenario of
  §2.5, which follow the same four rules.

The step is **not** part of `test-blackbox`, so the three gates never run a red fixture.

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
- one Zig test per perf CK (CK-03's time bound, CK-40, CK-41, CK-42), each generating its program
  into a `World`;
- from R7, the permutation scenario.

- **Scaling findings** assert a **ratio**: time(2n) / time(n) ≤ 2.5. That is linear with head-room.
  Quadratic is about 4 and cubic about 8. A ratio is robust across machines, where an absolute bound
  is not.
  - **Each point is the best of 3 runs** (S13), so load on a CI machine cannot flake a ratio into a
    rule (c) failure.
  - CK-03's absolute bound, 5 s, uses the best of 3 too.
  - **Time is the child compiler's CPU time** (user + system, from `wait4`'s rusage), not the wall
    clock, and every run is `--jobs=1`. *Amended 2026-09-24 by the review of R2a:* a concurrent
    build stretched CK-40's two wall-clock points unequally (87 s / 162 s, ratio 1.85) into a
    false GREEN. The wall clock only kills a run, at twice the bound.
- **Calibration (R0).** Choose `n` so that a *fixed* build takes at least 0.5 s at `n`. orch's
  scratch fixes (per-group settling removed; `resetMemo` with amortised growth) are the reference.
- **The permutation scenario (R7)** asserts, for each program and each permutation of its
  top-level declarations (capped at 120):
  - **exit 0**;
  - **stdout equal to the program's oracle-twin output** (§2.7).

  Merely checking that every permutation prints the same thing would pass if every permutation
  failed the same way (S13). A program meant to be refused, such as §10.6's two-types example,
  instead asserts that every permutation gives the same single diagnostic code.
- **Reporting.** Each scenario prints RED/GREEN like §2.4, and fails the step only under rules
  (b)–(d).
- **Promotion** moves the scenario verbatim into `abuse_test.zig`.

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
- **Closes.** Promoted: CK-38, CK-39, CK-41 (perf scenario into `abuse_test.zig`).
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

### R4b — v2 foundation: store, walks, unify, generalise, obligation-free constraint generation

- **Goal.** v2 checks every program whose root modules need **no dispatch and no obligation**.
  - The subset is computed by `tests/pending/v2-subset.sh`: fixtures whose v1
    `dump --stage=dispatch` has no `site` and only `evidence=0` declarations for root modules, and
    whose root modules' `dump --stage=bir` contains no `tuple_index`, `interp`, `try` or
    `Basics.eq`/`neq` call (S-5).
  - A root module outside the subset reports `not_implemented`, naming the slice (R5 or R6a).
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

### R5 — Obligations: `tuple_index`, interpolation, the `equatable` marker, `?`

- **Goal.** Every non-method obligation, riding on its variables (§4.5), and §8.1's default step:
  - `tuple_index`, `interpolatable` and the `equatable` marker (the growable, payload-descending
    walk);
  - `?` as a deferred obligation (D2 as amended).
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
  events.
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
| R3 | CK-38, 39, 41 | — | — |
| R4a | — | — | CK-15 (the cutoff protocol leaves `Check.zig`) |
| R4b | — | CK-01, 04, 07, 13, 57; CK-09 (`check/good` half) | CK-10, 14, 15 (pipeline part) |
| R5 | — | CK-05, 06, 16, 51, 62, 68 | CK-18; CK-59 (part) |
| R6a | — | CK-02, 03, 09 (`check/bad` half), 20, 21, 42, 48, 80 | CK-35; CK-37, 55 (part) |
| R6b | — | CK-08, 27, 28, 29, 32 | — |
| R7 | — | CK-30, 31, 36, 63, 64, 65, 66, 70, 72, 73, 76 | — |
| R8a | — | CK-23, 25, 40, 67, 69, 74, 75, 77, 79 (the field cap lifts with D4's signature; manager 2026-09-24) | CK-26; CK-82 (with CK-79); CK-85 (owner 2026-09-25) |
| R8b | — | CK-22, 24 | — |
| R9 | — | — | CK-15 (rest) |
| R11 | all claims above | — | — |
| R13 | CK-49, 50, 52, 53, 54, 55, 56, 58, 59, 60, 86 | — | — |
| R14 | CK-37 (rest) | — | — |
| (assigned 2026-09-24) | — | — | CK-81 is R2a's and CK-79 is R8a's (manager) |
| (assigned 2026-09-24) | — | — | CK-82 → R8a (with CK-79); CK-83 → R2c, a new backend slice after R2b (manager) |

Every one of the 86 entries appears in this table, CK-75 (a performance finding added after R0) included: the manager assigned it to R8a on 2026-09-24 (to R10 if R8a's profile shows the residue is `dep_digest`). CK-71 (R0's: `Session` symbol ids depend on thread timing) was assigned to R1 on 2026-09-24. *Updated 2026-09-24 for round 3: the slice
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
