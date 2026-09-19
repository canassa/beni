# Effects spike — implementation plan

**Status:** plan, 2026-09-19. Not started, and it must not start before M4 slices 1–3 land
(owner, 2026-09-19; `plans/m4-plan.md` D5).
**Branch:** `spike/effects`, cut from `master` after M4-3. The branch never merges on its own: it
produces numbers and a research report, and the decision whether to adopt is taken on `master`
afterwards, exactly as static dispatch was.
**Commissioned by** the owner, 2026-09-19 — *"We need a full-blown spike and investigation. Clone
EffectTS locally. It's our gold standard. I want to achieve EffectTS levels of quality and API
coverage."*

**What this is.** The work-up that folds four documents into one order of work:
[`transparent-effects-proposal.md`](../docs/design/transparent-effects-proposal.md) — **P2** — is the
design; [`plans/effects-plan.md`](effects-plan.md) — **the plan** — is P2 corrected against the
repository; [`research/21`](../docs/design/research/21-effect-v4-runtime.md), **r21**, is the runtime
as built and measured; [`research/22`](../docs/design/research/22-effect-v4-api-surface.md), **r22**,
is what "API coverage" means; [`research/23`](../docs/design/research/23-effect-v4-semantics.md),
**r23**, is what a user feels when things fail. Nothing below repeats them; every claim points into
one of them.

**What this is not.** It is not the decision sheet. Every question the owner owns is in
[`plans/effects-decisions.md`](effects-decisions.md), and this plan is written against a stated
default for each so that it is usable the moment those are answered. A default is marked
**PENDING(An)** and the item number is the sheet's.

---

## 0. Decisions already taken, and the defaults this plan assumes

### 0.1 Taken by the owner

| Decision | Choice | Date |
|---|---|---|
| Effects gets a full spike | Not built straight to spec. Branch, build, measure, report, then decide — the dispatch shape. `references/effect` is vendored as the gold standard | 2026-09-19 |
| Ordering | **M4 first.** The spike starts after M4 slices 1–3. `plans/m4-plan.md` D5: `--release` → M4-0..M4-3 → effects → M3d | 2026-09-19 |
| `lazy` | **Parked.** It leaves M3d and returns when a browser platform and a real application want it; effects will be in by then and make it cheaper | 2026-09-19 |
| `--release` refuses `Debug` | Landed. The `run/` corpus's order-observing fixtures keep working through a hidden `--allow-debug` | 2026-09-19 |
| `Int32` | Built, inside the wall | 2026-09-19 |
| The test for every restriction | `CLAUDE.md` rule 7. A rule stays only if it protects a guarantee; a capability gap is filled inside the wall; where no guarantee is at stake, warn rather than refuse | 2026-09-19 |
| The interface bits and M4's cache | `plans/m4-plan.md` D4: **do not reserve them**; the cache header carries a format version, so adding them is a version bump and a cache discard, not a migration | 2026-09-19 |

### 0.2 Taken earlier, and not reopened here

The lowering is **CPS onto a fiber runtime this language owns**, not native `async` (P2, 2026-09-15,
on `research/16` §2.4). r21 §4.4 re-ran the deciding experiment on the rewritten v4 runtime and got
**57 ms against v3's 56 ms and native `async`'s 301 ms**. Confirmed, not reopened.

### 0.3 Defaults this plan is written against, pending the sheet

Each is the sheet's recommendation or, where the sources disagree, the stronger evidence. **None is
decided.** If an answer differs, the affected slices are named in the last column.

| PENDING | Default assumed here | Slices that change |
|---|---|---|
| **A1** the failure value | r21 §11.6(a): a flat, multi-reason failure value, surfaced to beni only at `join`/`await`/`scope`/`bracket`'s release | S8, S9, S10 |
| **A2** join vs await | both; `join` propagates, `await` returns the outcome | S10 |
| **A3** `bracket`'s release | receives the outcome | S8 |
| **A4** `retry` | takes a `Schedule`; `Schedule` is pure data and lands in `core/` **before** the runtime | pre-spike, S13 |
| **A5** `impure` | inferred **and used**: `language.md` §6's optimiser licence gains the exception it already anticipates | S2, S4, S12 |
| **A6** `sync` | ships in the first cut | S3 |
| **A7** services / `R` | R-A + R-C for services (both already exist, cost zero); **two hard-wired fiber slots**, scheduler and clock, instead of a general `Context`; `R = never` conceded in writing | S11, S12, S13 |
| **A8** `main` | `main : Program` stays and its body is `sync`; v4's exit-code mapping 0/1/1/130; keep-alive in the runtime; a new `run/bad/` corpus kind | S5, S9, S15 |
| **A9** suspending `eq` evidence | a `must_not_suspend` obligation on well-known evidence — **but S1 writes and measures the alternative first** | S1, S3 |
| **A10** combinators and cleanup | they wait for their losers' finalisers | S13 |
| **A11** finaliser order | children first, as P2 §6.2 obligation 4 says, diverging from Effect | S10 |
| **A12** the three amendments | `uninterruptible`/`interruptible`/`restore`, three fork forms with `startImmediately`, `Duration` not `Int` | S7, S10, S12 |
| **A13** deterministic time | swappable clock and scheduler from the first commit; **no fixture may sleep** | S11 |
| **A14** kernel scope | `spawn`/`join`/`scope`/`bracket` for the spike; the full list for the adoption | S5–S13 |
| **A15** chain diagnostic | one hop per module | S3 |
| **A16** logging | a minimal platform logger lands on `master` **before** the spike | pre-spike |
| **branch** | everything on `spike/effects`; S2 and S3 written so they can be cherry-picked if the owner adopts the inference half only | §2 |

---

## 1. Objective and non-objectives

### 1.1 What the spike must tell the owner

The closing report (S15) answers exactly these, with numbers, and **offers no verdict** — report 19's
discipline, which worked.

1. **Does compiling beat interpreting?** beni emits the continuation as a closure; Effect walks an
   array of primitives. r21 §12 calls this *"the single assumption the whole 'compiling beats
   interpreting' claim rests on"* and says nothing measures it. E-M4.
2. **What do two bits per function type cost a program that has none?** Dispatch's precedent is
   **+20.3 % of check and +48 % of emit on code that never uses the feature** (report 19 §2.1). The
   plan proposes the bound up front: **≤ 10 % of check, 0 % of emit, every `emit/` golden
   byte-identical**. E-M1, E-M2.
3. **Is the runtime affordable?** Against v4's own numbers on the same machine: 82 ns per
   flatMap-equivalent op, 472 ns per immediate fork+join pair, **57 ms** cancellation latency,
   **419/659 B** per parked fiber, 2 076 ns to install a finaliser and 199 ns to run it, and
   **~5 kB gzip** for the whole concurrency surface. E-M4 to E-M11.
4. **Does a program that uses none of it pay nothing?** The claim to test, not assert. E-M2, E-M11.
5. **Is the quality there?** The 43-fixture conformance suite of r23 §0.3 green; the T0 and T1 API of
   r22 §8 implemented; the ten-piece kernel of r21 §11.3 complete; deterministic time so a fixture
   that would sleep an hour runs in milliseconds; and diagnostics — the `sync` violation chain, the
   failure renderer — at the house standard, printed beside Effect's for the same programs the way
   report 19 §7 printed them beside Roc's.

### 1.2 The outcomes that must all be reportable

Report 19 §15 offered four options and no verdict, and that is what made the adoption decision
takeable. The equivalents here, and every one must be a live possibility when the report is written:

| Option | Roughly |
|---|---|
| **(a) Do not adopt** | `master` keeps no bit. The cost is that the boundary check `boundary.md` §5.4 promised has no mechanism, `core/List.js`'s suspending-evidence hole stays open, and beni has no concurrency story beyond `Program` |
| **(b) Adopt the inference half only** — S2 + S3 | The two bits, `sync`, the boundary checks, the diagnostics; no lowering, no runtime. This is `boundary.md` §5.4's promise kept and plan §2.1's hole closed, for a check-time tax and nothing else. **It must stay a real option, which is why §2 keeps S2 and S3 cherry-pickable** |
| **(c) Adopt the lowering without the batteries** — through S11 | The kernel, the ten pieces, T0. `Queue`, `Semaphore`, `Schedule` and the rest land later as ordinary beni |
| **(d) Adopt all** | Through S13, T0 + T1, the conformance suite green |

A fifth row, as report 19's (d) was: **adopt nothing but the corrections the spike proves** — the
`core/` order fixes, `run/ImpureNotDuplicated`, `Schedule` as data, the platform logger. Those are
landable on `master` whatever is decided, and §2 lands them first.

### 1.3 Non-objectives

- **The Elm Architecture.** P2 §6.6 makes exactly one language-level claim about TEA — that `update`
  stays pure and a command stays an inert value — and says everything else is a platform package's
  API. There is no browser platform. **Out of scope**, and the spike does not design `Cmd`;
  `boundary.md` §5.4 already names the four policies and r22 D7 recommends fiber-level cancellation
  only for the spike. If the owner wants it, it is a late slice after S13 and it is a *browser*
  slice, not an effects slice.
- **Streams, STM, `Pool`, `Cache`, `PubSub`, spans, metrics, `Config`.** Sheet tier C. Every one is
  library code over the kernel (r22 §4.3, r23 §11), and the kernel forecloses none of them provided
  it keeps `uninterruptible` and a per-cell waiter list.
- **Surface sugar.** P2 §3.3's bare `let` items and §3.4's `and` groups are independent of everything
  here, P2 §3.3 says so, and bare items are what `Debug.log` wants today. They can land on `master`
  at any time and are not on this critical path.
- **Source maps.** M5's, not this spike's — but S4's lowering must not foreclose them, which is the
  whole of P2 §7.4's warning about Koka's synthesised `_mlift_` functions.
- **Beating Effect at bundling, and a supervision tree.** r21 §8.4: v4 shipped by *deleting* its
  supervision surface. Determinism yes; fiber observability no.

---

## 2. Branching and landing strategy

### 2.1 What lands on `master` before the branch is cut

Five things, none of which needs a decision about effects, and each of which makes the spike cheaper
or `master` better on its own. They are the "adopt nothing" row of §1.2 paid in advance.

1. **`run/ImpureNotDuplicated`** (r23 row 41, plan §6 row 6). A counter-shaped call behind a shared
   binding, asserted to happen exactly once. Writable today; DCE and `--release` have both landed, so
   it is the fixture that decides PENDING(A5) and it should exist before the argument.
2. **A minimal platform logger** — PENDING(A16), `plans/queue.md` item 51. A shipped beni program
   cannot log: `Debug` is the only way to write a line and `--release` refuses it. Rule 7 says a
   capability gap is filled inside the wall. Whatever shape it takes, **it must not be a `pure`
   `foreign` returning `()`** — without A5 the optimiser is licensed to delete it.
3. **`Schedule` in `core/`** — PENDING(A4). Pure data with a step function; r22 §5.A says it needs
   **no runtime support at all**, and it replaces the weakest signature in P2 §6.5. One open design
   question comes with it (r22 §10 item 2: how the state is carried without existentials).
4. **`Duration` in `core/`** — PENDING(A12). So no signature written later spells a delay as a bare
   `Int` of milliseconds.
5. **`Result.combineAll` / `Result.partition`** — sheet C7, r22 D4(a). Twenty lines, useful today.

### 2.2 Where the bits land, and the M4 trade-off the owner asked for

**The question.** `plans/effects-plan.md` §4 argued E1 and E2 (here S2 and S3) *"go straight to
master"*, because nothing about them is unmeasured in a way a branch would settle and because E2 is
independently useful. Two things have happened since: the owner fixed the order (**M4 first**), and
M4 slice zero shipped a serialized interface with a content hash.

**The trade-off, with `plans/m4-plan.md` D4 in view.**

- **Before M4-2/M4-3.** The bits would be in the interface record before the on-disk BIR/AST format
  and the firewall are built, so nothing is re-blessed twice. But it contradicts the owner's
  ordering; it means M4-2's corrupt-cache fixtures and M4-3's incremental-determinism matrix are
  written against a record that is still moving; and it delays the warm number M4 exists to produce.
- **After M4-3**, which is what D5 says. The cost is **one format-version bump, one cache discard,
  and one re-blessing of every `.iface` and `--stage=raw` golden** — and D4 chose not to reserve the
  bits *precisely so that this is the cost*: *"adding them is a version bump and a cache discard, not
  a migration."* The mechanism was built for this.

**Recommendation: after, as D5 says.** The one-off cost is named above so nobody is surprised by a
golden re-bless in the middle of a slice.

**Whether S2 and S3 land on `master` or on the branch — PENDING.** The plan is written against
**branch**, for one reason: option (b) of §1.2, *adopt the inference half only*, has to stay a real
outcome, and it stops being one the moment `master` carries two bits nobody voted for and a format
bump that cannot be undone without a second one. The mitigation is discipline, not structure: **S2
and S3 are written as self-contained commits that touch no lowering and no runtime**, so a
cherry-pick to `master` is the adoption of option (b) rather than a rescue operation. If the owner
prefers the plan's original reading, S2 and S3 move to `master` and everything from S4 stays on the
branch; nothing else in this document changes. Note that S3 cannot land without S2 — `sync` is a
check over a bit that has to exist.

### 2.3 How `master` keeps moving underneath

The dispatch lessons, from the diary:

- **Rebase the branch onto `master` at the end of every slice**, never in the middle of one. The
  dispatch branch went three days without one and paid for it in S6b.
- **A worktree per building agent.** It worked at four agents (2026-09-18 18:35) and it is what makes
  a fail-first proof possible without `git stash` — and the diary's warning stands: the harness moves
  the session's cwd into the worktree when its agent reports, so **never use bare `git stash` from
  there, the stack is shared**.
- **The three gates green on the branch after every slice**, `master` untouched.
- The spike will run for days while `master` takes M4-4 and M3d. The document that drifts is the
  spec, not the code — §3's Appendix A is the mechanism that keeps the drift visible.

---

## 3. The spec-first obligation

`CLAUDE.md` rule 1: the document is written before the code, and it is what nothing downstream of the
2026-09-14 no-currying decision could be implemented without. The spike writes
**`docs/design/effects-spike.md`** on the branch — normative, the file name historical if it is
adopted, exactly as `docs/design/static-dispatch-spike.md` is — and **renumbers no section anywhere**
(rule 2).

### 3.1 The section list

| § | Subject | Extends |
|---|---|---|
| 0 | How to read this, what it supersedes, and what it declines | — |
| 1 | The two bits: the lattice, inference, generalisation, subsumption, the extraction hazard | P2 §2, §4.1–§4.4 |
| 2 | `foreign` bit declarations, and the evidence rule | P2 §3.1; `boundary.md` §4 checks 1 and 4 |
| 3 | `sync`: the declaration form, the argument position, the chain | P2 §3.2, §8; `boundary.md` §5.4 |
| 4 | Semantics: order, one-shot, and what `impure` takes from the optimiser | P2 §5; `language.md` §6 *Evaluation order* |
| 5 | The lowering: the suspendable form, join points, the fast path, traces | P2 §7.1–§7.4; `backend.md` §7, §8, §9 |
| 6 | The fiber record and the run loop | r21 §11.3 pieces 1–2 |
| 7 | The suspension primitive and its canceller | piece 3 |
| 8 | Interruption, including the re-entrant interrupt | piece 4 |
| 9 | Interruptible regions, and `restore` | piece 5 |
| 10 | The scheduler, the op budget, and the clock | piece 6 |
| 11 | The failure value and its boundaries | piece 7 |
| 12 | Fork, join, await, children | piece 8 |
| 13 | `Scope`, `onExit`, `bracket` | piece 9 |
| 14 | Rendering a failure | piece 10 |
| 15 | The T0 and T1 API, signature by signature | r22 §8 |
| 16 | Diagnostics, one subsection per code | — |
| 17 | What is deliberately declined, and why | r22 §7, r23 §10 |
| A | Decisions made while writing — **append-only** | — |
| B | The conformance suite, row by row, mapped to sections | r23 §0.3 |

Appendix A takes the dispatch format unchanged, because it worked and it reached 84 rows:
`**A.N — <the decision in one line>.**` then the choice, then `*Why:*` and `*Alternative:*`. A row is
never rewritten; it gains `**Amended <date>:**` or `**Superseded <date> by A.M:**`.

### 3.2 Where r23's 51 silences and 6 disagreements go

r23 scored 78 executed cases against P2 and found **21 agree, 6 differ, 51 silent** — *"two thirds of
the observable behaviour of a fiber runtime is not in the proposal."* Each silence is a sentence that
has to be written before the code. The assignment, by case group:

| r23 group | cases | goes to § | note |
|---|---|---|---|
| 1 sequencing and failure (11) | 1.1–1.11 | §4, §11, §13 | case 1.4 — a finaliser failing while the body failed — is PENDING(A1) in its sharpest form |
| 2 interruption (17) | 2.1–2.17 | §8, §9, §12 | cases 2.10/2.11 are the A11 divergence; 2.16's self-interrupt-catchable/external-not is two mechanisms wearing one name |
| 3 combinators (12) | 3.1–3.12 | §15 | 3.7 (`timeout` waits) and 3.2 (the group waits) are PENDING(A10); 3.5 (a failure does not end a race) is the one *"every hand-rolled `Promise.race` gets wrong"* |
| 4 resources (6) | 4.1–4.6 | §13 | 4.1 is PENDING(A3) and its fixture does not compile under P2's type |
| 5 schedules and virtual time (6) | 5.1–5.6 | §15, §10 | 5.5 is why §10 owns the clock |
| 6 coordination (12) | 6.1–6.12 | §15 | **11 of 12 silent.** Every one is library code over the kernel |
| 7 streams (6) | 7.1–7.6 | §17 | declined for v1; recorded as the acceptance criteria for whenever |
| 8 observability (8) | 8.1–8.8 | §14, §11 | 8.8's exit codes are PENDING(A8); 8.4/8.5's *"an unhandled failure is silent and exits 0"* is a wart not to copy |

The six disagreements are **§0's first obligation**: each gets a paragraph saying which way beni goes
and why, because four of them favour Effect, one favours P2, and one is split.

### 3.3 The documents this one extends, and what changes in each

- **`language.md` §6 *Evaluation order*** already ends by anticipating this: *"when effects land,
  `transparent-effects-proposal.md` §5 adds a clause exempting `impure`-tagged calls."* Under
  PENDING(A5) that clause is written, and `src/js/Opt.zig` and `src/js/Reach.zig` learn it. This is
  the one place where the optimiser's licence narrows, and it narrows in a document that already
  reserved the space.
- **`checker.md` §5–§7** for where the bits live, how they ride beside unification as obligations
  rather than inside it, and what the interface carries. The precedent and the warning are the same:
  dispatch's per-variable constraint set cost 20.3 % of check.
- **`backend.md` §7, §8, §9.** The lowering must compose with the decision trees' labelled blocks —
  and the spec must say that **a labelled block is not a join point**, or the first implementation
  will try to reuse them (plan §2.3). It must compose with §8's `while(true)` and `$in$<i>` slots —
  plan §2.2 found the loop composes unusually well, because *the loop's state is the parameter list*,
  so a continuation is an ordinary call of the same function, with the one rule that **a continuation
  captures the prologue `const`s and never an `$in$<i>` slot**. And §9's DCE is what keeps a program
  that never spawns from shipping the runtime — including v4's trick of making child interruption
  reachable-only middleware (r21 §5.2), which `Reach.zig` can do and which needs an `emit/` fixture
  that does *not* reach it or the elimination is untested.
- **`boundary.md` §4** — shape (b)'s `Task e a` is replaced by a `foreign` with bits (P2 §10 item 3,
  still open), and check 4 gains a statement about what a sibling may do with an evidence parameter.
  **§5.4's promise that `update` and `view` are `sync` finally gets a mechanism.**
- **`fast-compiler.md` §3.1**'s Decided-2026-09-13 bullet must be marked reversed (P2 §10 item 4,
  still open), in the style §3.1 already carries for the dispatch reversal.

---

## 4. Slices

Discipline, unchanged from the dispatch spike because it worked: **spec section written or confirmed
first → implement → fixtures that fail before and pass after, proved by stashing → the three gates →
read-only review → commit on the branch → diary entry.** A slice that cannot be finished is not
half-landed. Fixture row numbers are r23 §0.3's; kernel piece numbers are r21 §11.3's.

Ordering is by **risk, not by dependency**: S1 and S2 exist to hit the two unknowns that can end the
spike before eleven slices of work are spent on them.

**S0 — branch, spec skeleton, instruments, baselines.**
- *Goal.* Nothing can be measured later that was not measured before the first change.
- *Spec first.* `docs/design/effects-spike.md` §0–§4 written in full; §5–§17 as headings with their
  obligations from §3.2 listed under each. Appendix A opened.
- *Touches.* Docs; `bench/`; `plans/effects-spike-results.md` (new, append-only, the dispatch results
  file's shape: a dated `##` entry per session, a `###` per instrument row, the `uptime` line before
  each reading, the verbatim command and its raw JSON, then a *Reading* paragraph; corrections are
  new entries, never edits; every later citation is `results:<line>`).
- *Instruments that exist.* `zig build bench -- --generate=100000` (per-phase, ReleaseFast),
  `bench/size.mjs` (raw/gzip/brotli per program, plus derived-function bytes), `bench/runtime.mjs`
  (ns/op with an ESM-load floor subtracted, plus a checksum), `bench/churn.sh` (now by interface
  hash, since M4 slice zero), `bench/gen.zig --generate/--pathological`, `Solve.Counters`.
- *Instruments to build.* **`bench/fiber/`** — a beni-side micro-benchmark harness comparable to
  r21's nine scripts, and **`bench/fiber/ref/`**, those nine scripts re-run against
  `effect@4.0.0-rc.116` on *this* machine on *this* day, because r21's absolutes were taken on a
  machine at load average 16–45 and only its ratios are defensible. Plus a **retained-bytes gate** on
  the model of `effect:packages/effect/benchmark/http/serverAllocations.ts:4-12`: a hard per-fiber
  budget, sampled, `exit(1)` on breach.
- *Fixtures.* A smoke scenario in `build_test.zig` that runs each new script on one tiny program and
  checks the JSON shape — the dispatch S1 rule.
- *Self-check.* The new `Solve.Counters` fields are declared **now**, reading zero, so that the
  before/after comparison is of one instrument.
- *Measurement.* E-M1, E-M2, E-M3, E-M11, E-M15 baselines, plus the whole of `bench/fiber/ref/`.
- *Exit.* Every baseline in the results file with its load average; gates green; nothing else changed.

**S1 — the kernel probe: does compiled closure-CPS beat an interpreted loop?**
- *Goal.* The riskiest unknown, answered before any compiler change. r21 §12: *"the first thing E3
  should measure."*
- *Spec first.* §6 and §7 of the spec, written against r21 §11.3 pieces 1–3 and §3.1's field table,
  including the three fields P2's record does not have (`running`, `deferredInterrupt`,
  `interruptedCause`).
- *Touches.* A hand-written JavaScript kernel in the shape `platforms/node/` would hold, driven by
  **hand-written CPS JavaScript** standing in for what the compiler will emit. No Zig. Nothing ships.
- *Fixtures.* None in the corpus — this is `bench/fiber/`. But **write `run/ListEqSuspendingElement`
  (row 39) here, in both variants**: the A9(a) shape and the A9(c) shape where `core/List.js`'s loop
  re-enters through an observer the way v4's `fiberAwaitAll` does. r21 §0.5 item 4 asks for exactly
  this before A9 is decided.
- *Self-check.* A dev-build assertion that a continuation is never invoked twice, and that a fiber is
  never resumed twice — the one-shot guarantee is the thing whose failure is silent.
- *Measurement.* **E-M4** (op cost vs v4's 82 ns), **E-M5** (the sync fast path vs a direct call and
  vs v4's `callback` at 186 ns), **E-M6** (fork+join), **E-M8** (retained bytes vs 419/659 B),
  **E-M9** (finaliser install/unwind vs 2 076/199 ns), and the B10 answer for A9.
- *Exit.* A results entry and a one-page note to the owner. **If beni's op cost does not beat 82 ns,
  stop and report before S2** — the lowering argument needs re-opening, and eleven more slices should
  not be spent first.

**S2 — the two bits: inferred, generalised, published.**
- *Goal.* The second riskiest unknown: what the bits cost a program that has none.
- *Spec first.* §1, §2 and §4. P2 §3.1's `foreign pure | impure | suspends` keyword — frozen by
  report 17 §6.5 — plus the correction P2 §3.1 already carries: a `foreign` may now have a `where`
  clause, so a declaration keyword *does* describe a signature with a function type in it, in the
  evidence position, and the keyword says nothing about the evidence's bits.
- *Touches.* `Parse`, `Ast`, formatter, `Bir`, `TypeStore.Func`, `Solve` (`unifyFlat`, a `flag_le`
  obligation, `generalize`), `Schemes`, `Interface`, `Render`, `dump --stage=types|interface|raw`.
- *The one rule that must not be got wrong.* **The bits must never be compared inside `unifyFlat`**
  (plan §2.1). A `Func`/`Func` unification records a `flag_le` obligation in the per-rank list and the
  fixpoint is taken post-solve beside `dischargeEquatable`; comparing by equality makes a variable
  used once with a pure callback and once with a suspending one a hard error exactly where P2 §4.4
  wants `false ⊑ true`.
- *Encoding.* Plan §3's **two-word `extra` header before the parameter range**, which keeps `Func` at
  12 bytes and `Descriptor` at 40 and is the only encoding that holds a flag *variable*. The
  alternative — two bits stolen from `params.len` — holds constants only.
- *Fixtures.* `check/good/ForeignEffectLadder` + `.types` golden; `check/good/SuspendsAcrossModules` +
  `.iface` golden; `check/bad/ForeignEffectMissing`; `check/bad/FlagMonomorphised` (P2 §4.3's
  extraction hazard, whose silent half is the dangerous one); a `--stage=raw` determinism module set.
- *Self-check.* A compile-time assertion that `@sizeOf(Descriptor)` has not moved — the dispatch
  lesson about passes whose failure mode is silent, applied to a size claim.
- *Measurement.* **E-M1** (check), **E-M2** (emit, and every `emit/` golden byte-identical),
  **E-M3** (interface bytes and churn by hash), **E-M14** (determinism).
- *Exit.* ≤ 10 % of check, 0 % of emit, `Descriptor` size stated. **Over the bound, report before
  S3.** Cherry-pickable to `master` as half of option (b).

**S3 — `sync`, and the boundary it closes.** *(PENDING(A6); the other half of option (b))*
- *Goal.* `boundary.md` §5.4's written promise gets a mechanism, and plan §2.1's `List.eq` hole
  becomes a diagnostic instead of a wrong answer.
- *Spec first.* §3 and §16. Report 17 §6.3's Branch B: one bool on the function type, one
  `Interface.Term.Tag` value, one obligation kind, one witness. Plus `boundary.md` §4's new clause:
  **a `foreign`'s `where`-constraint types are `sync` by construction unless the platform writes
  otherwise**, which is what closes check 4's blind spot — check 4 counts a sibling's parameters and
  cannot see that `core/List.js` calls `m0` from inside a `while` loop.
- *Touches.* Grammar, `Solve` (a fifth obligation kind and its discharge arm), `Interface`,
  `boundary.md`, `check/Diagnostics.zig`.
- *Fixtures.* `check/bad/SyncSuspends` (the one-hop chain, PENDING(A15));
  `check/bad/SyncBoundaryArgument`; `check/bad/SuspendingEqEvidence` — **row 39 turned into a
  diagnostic**; `check/bad/MainSuspends`.
- *Self-check.* Every new code has a `check/bad/` golden, and the well-known-evidence rule has a
  positive fixture too: a user-written `where a.fetch : …` that *does* suspend must still compile,
  or the rule is too wide and has become a restriction rather than a guarantee (rule 7).
- *Measurement.* **E-M6d** — the diagnostics themselves, in the report, beside Effect's and Roc's for
  the same programs (report 19 §7's shape).
- *Exit.* Gates green; the goldens read by a human; cherry-pickable with S2.

**S4 — the CPS lowering, synchronous only.**
- *Goal.* Emitted JavaScript that suspends and resumes inline, with no scheduler in the picture.
- *Spec first.* §5, extended with plan §2.2 (the loop) and §2.3 (the trees), and P2 §7.4's trace
  rules. The three sentences that must be in it: a labelled block is not a join point; a continuation
  captures the prologue `const`s and never an `$in$<i>` slot; the scrutinee of a `case` that is itself
  a suspending call is bound once whatever the read count is.
- *Touches.* `src/js/Lower.zig` (`tailStmts`, `caseExpr`, `functionOf`), `JsIr`, `src/js/Print.zig`.
- *Fixtures.* **rows 1–4**: `run/SuspendFastPath`, `run/SuspendInLoop` (1 000 000 elements, the stack
  must not grow), `run/SuspendOneShot`, `run/SuspendInLoopClosure` (which prints `0 1 2` and prints
  `0 0 0` when the continuation closed over a slot). Plus `emit/SuspendableLoop` as a shape golden.
- *Self-check.* **A debug assertion that a function whose `suspends` bit is false never receives a
  continuation argument** — this is the pass whose failure mode is a plausible wrong number, and the
  dispatch lesson is to build the check that turns it into a compiler error first.
- *Measurement.* E-M2 again (emit throughput, and `js_bytes` for a program with no suspension
  unchanged), E-M4 against S1's hand-written baseline — **does the compiler emit what the probe
  measured?**
- *Exit.* Rows 1–4 green; E-M4 within noise of S1.

**S5 — the kernel lands: the fiber record, the run loop, the suspension primitive.**
- *Goal.* r21 §11.3 pieces 1, 2 and 3, in a platform package.
- *Where it lives, and why.* **In `platforms/node/`, as JavaScript, beside `runtime.js`.** Three
  reasons: `boundary.md` §5.2 already has a platform declaring its output shape through a `runtime`
  manifest key and `platforms/node/runtime.js` is that file today; `research/16` §5.5 says the op
  budget *"should be a `foreign`-configurable platform constant rather than a language decision,
  since a server platform wants it large and a browser platform wants it small"*, which is only true
  if the scheduler is the platform's; and rule 6 keeps the privileged surface narrow — r22 §4.0 found
  that **the whole of Effect's concurrency is library code over one primitive plus a mutable cell**,
  so what must be privileged is the suspension protocol and a `Ref`, not a runtime the compiler
  emits. The emitted copy follows `backend.md` §5's existing `platform/<name>.foreign.mjs` route, and
  `Reach.zig` is what keeps a program that never spawns from shipping it.
- *Spec first.* §6, §7 confirmed from S1; §2's `foreign` bit declarations for the primitive.
- *Touches.* `platforms/node/`, `boundary.md` §4's shape-(b) rewrite, `src/js/Emit.zig` for the entry
  point, PENDING(A8)'s `main`.
- *Fixtures.* Rows 1 and 3 re-run against the real kernel; a new `emit/` fixture for a program that
  reaches **none** of it, asserting the runtime is eliminated.
- *Self-check.* The dev build asserts a fiber is never resumed twice and that the resume callback is
  one-shot — r21 §11.5 names the symptom of getting it wrong as *"a cancelled fiber resuming later
  and running the rest of its continuation on a dead scope."*
- *Measurement.* E-M8 (the retained-bytes gate becomes a build gate here), E-M11 (the runtime's own
  gzip against the 5 kB budget).
- *Exit.* Gates green; the gate fails a deliberately-fattened fiber.

**S6 — interruption, and the re-entrant interrupt.**
- *Goal.* Kernel piece 4 — r21 §0.3 item 1 calls it *"the largest thing P2's runtime specification is
  missing"*, and it is not optional: P2 §7.2 makes synchronous resumption the headline, and
  synchronous resumption is precisely what creates the re-entrancy.
- *Spec first.* §8. v4's design, not v3's: **the canceller is a continuation frame, not a fiber
  field**, found by the same unwinding walk that runs `bracket`'s releases, uninterruptible while it
  runs, and running only on an interrupt. Plus the disarm thunk, the latch, and the deferred-interrupt
  continuation. P2 §6.4's `interruptor` row is rewritten here.
- *Touches.* The platform kernel.
- *Fixtures.* **rows 5–10**: `CancelParked`, `CancelDropsLateResume`, `CancelCanceller`,
  **`CancelReentrant`**, `CancelSyncLoop` (the guarantee is *stated*, not pretended — nobody
  interrupts a synchronous loop, under any lowering), `InterruptDoneFiber`.
- *Self-check.* An assertion that two run loops are never walking one continuation stack — the
  condition `running`/`deferredInterrupt` exist to prevent, whose symptom is *a finaliser running
  twice or a value delivered after cancellation*.
- *Measurement.* **E-M7** — cancellation latency against v4's 57 ms. Anything above ~60 ms means the
  resume callback is not actually owned, which is the whole of what 2026-09-15 bought.
- *Exit.* Rows 5–10 green; E-M7 ≤ 60 ms.

**S7 — interruptible regions, `uninterruptible`, and `restore`.**
- *Goal.* Kernel piece 5, and PENDING(A12) item 1 — r22 §6 item 9: *"the highest-value item that the
  proposal argues about and does not fix."*
- *Spec first.* §9. P2 §6.3 has the flag and none of the other three pieces: the latched cause, the
  re-arm at the region's end, and `restore` — **without which `acquireUseRelease` cannot be written
  at all**, because a long `use` would inherit the acquire's uninterruptibility.
- *Fixtures.* **rows 11–14**: `UninterruptibleLatch`, `BracketAcquireUninterruptible`,
  `BracketUseInterruptible`, `BracketReleaseUninterruptible`.
- *Self-check.* An assertion that the interruptibility flag is balanced at fiber exit — an unbalanced
  region is an uncancellable fiber and nothing else reports it.
- *Measurement.* none beyond the gates.
- *Exit.* Rows 11–14 green, including the one asserting `use` is interruptible between two
  uninterruptible ends.

**S8 — `Scope`, `onExit`, and `bracket` with the outcome.** *(PENDING(A3))*
- *Goal.* Kernel piece 9, and r21 §5.1's correction: **two finaliser mechanisms, not one.** P2 §6.3
  and `research/16` §5.2 have one list on the fiber; a `Scope` is a value with an identity that
  outlives the expression, an `onExit` frame dies with it, and *"building only the fiber-level list
  makes `Task.scope` impossible to implement correctly."*
- *Spec first.* §13, including the release's outcome argument — the type change r23 §0.2 row 1 calls
  *cheap now and an API break later*.
- *Fixtures.* **rows 15–19**: `BracketCancel` (LIFO), **`BracketReleaseSeesOutcome`** — *which does
  not compile under P2 §6.5's type, which is the point* —, `BracketNested`,
  `FinalizerFailsWhileFailing` (blocked on PENDING(A1)), `FinalizerSlowDelaysExit`.
- *Self-check.* A dev assertion that every registered finaliser is run exactly once, on every exit
  path — a skipped finaliser is the leak class, and the program exits 0 having leaked what it held.
- *Measurement.* **E-M9** — install and unwind at depth 20 000 against v4's 2 076 / 199 ns. beni's
  `bracket` should be an order of magnitude cheaper to install because it is a frame, not a keyed map
  entry with a fresh key object; r21 §11.4 says *prove it*.
- *Exit.* Rows 15–19 green (18 may wait on A1); E-M9 recorded.

**S9 — the failure value, and rendering it.** *(PENDING(A1))*
- *Goal.* Kernel pieces 7 and 10.
- *Spec first.* §11 and §14. The mapping must be explicit: what a `Result` failure is, what a
  throwing `foreign` becomes, what an interrupt is, and the four boundaries where the runtime's value
  reaches beni.
- *Touches.* The kernel; `platforms/node/runtime.js` for the exit-code mapping; a new corpus kind.
- *Fixtures.* **rows 42 and 43**: `DefectFromForeign`, and `MainFails` — which **needs a corpus kind
  that does not exist**, because `run/X` compares stdout only and the program must exit 0
  (`corpus_test.zig:677`). The natural shape is `build/bad/`'s, applied to a running program:
  `run/bad/X/` with an expected stream and an expected exit code. **That harness change is part of
  this slice, not a prerequisite someone else does.**
- *Self-check.* **The renderer must emit nothing machine-specific.** r23 §11 could not determine
  whether `Cause.pretty` is stable enough to golden, and found an absolute `node_modules` path in one
  case and a wall-clock timestamp in another. beni's diagnostics already meet this bar and the
  failure renderer must too, or it cannot be a golden at all.
- *Measurement.* **E-M13** — a failure inside a suspended fiber reports a logical stack, and what a
  continuation's span costs. Effect pays 7.2 µs per call to *discover* a call site from a
  `new Error()`; beni's compiler knows the span statically, with no `Error`, no `stackTraceLimit`
  fiddling and no lazy stringification. r21 §8.2: *"the single clearest place where compiling beats
  interpreting."*
- *Exit.* Rows 42, 43 green; a rendered failure in the report beside v4's for the same program.

**S10 — fork, join, await, children.** *(PENDING(A2), (A11), (A12) item 2)*
- *Goal.* Kernel piece 8.
- *Spec first.* §12, including **children-first unwinding** — the deliberate divergence from Effect —
  and the fork forms with `startImmediately`, which is a 6.7× knob P2 does not have and, read
  literally, specifies the expensive side of.
- *Fixtures.* **rows 20–24**: `SpawnJoin`, `SpawnJoinCancelled`, `ScopeChildren`,
  **`ParentFinalizerOrder`** — written to fail against Effect's order — `SpawnDetached`.
- *Self-check.* An assertion that a fiber's children set is empty when its scope block returns, which
  is the whole content of the scope rule and is invisible otherwise.
- *Measurement.* **E-M6** — fork+join, immediate and scheduled, against 472 / 3 172 ns.
- *Exit.* Rows 20–24 green.

**S11 — the scheduler, the op budget, and virtual time.** *(PENDING(A13), (A7))*
- *Goal.* Kernel piece 6, and the thing that makes half of r23's catalogue testable at all.
- *Spec first.* §10. The scheduler and the clock are **replaceable from the first commit** — r21 §8.4
  is explicit that retrofitting means threading a parameter through every primitive. Two fiber slots,
  inherited by pointer on fork, not a service locator: r21 §7.3 prices v4's 500-line `Context` at
  three slots' worth of value to the run loop.
- *Touches.* The kernel; the test harness, which needs a way to install the test clock.
- *Fixtures.* Rows 34 and 35 become writable (`RetryBackoff`, `RetryNotOnCancel`) without a golden
  that records a duration. **The discipline is absolute: a golden records an order, never a
  duration**, because the determinism test runs the corpus at `--jobs=1` and `--jobs=8`, twice.
- *Self-check.* A dev assertion that no fixture-visible code path reads the wall clock directly.
- *Measurement.* **E-M10** — the budget sweep at 16 / 64 / 512 / 2048 / never, reporting throughput
  *and* armed-timer latency, **in Node and in a browser**. The browser half is `research/16` §6's
  missing experiment, still unrun, and r21 §0.5 item 1 calls it *"the most valuable unrun thing in
  the whole effects file"* — with a new reason: v4's escape is `setImmediate` where available and
  `setTimeout(f,0)` otherwise, which a browser clamps to 4 ms after five nested levels, so v4's
  default scheduler is a Node design and must not be copied blind.
- *Exit.* A number for the budget, per platform, with the sweep in the results file. This also opens
  the B11 probe: whether a fiber-local `Key a` can be typed soundly, which is r22 §10 item 1's
  *"the one item in this report that needs a spike rather than an argument."*

**S12 — T0 in beni, over the kernel.** *(PENDING(A5), (A7), (A12))*
- *Goal.* r22 §8's T0: `Duration`, `Task` (spawn, scope, bracket, sleep, yield, uninterruptible,
  interruptible), `Fiber`, `Scope`, `Deferred`, `Ref` — about 35 signatures, all ordinary beni except
  the primitive and the cell.
- *Spec first.* §15's T0 half. Two rules shape every signature and the spec says them once rather
  than letting every user discover them: **subject first, function last**, and **a nullary method
  cannot be dot-called** — `fiber.join` is a field access (`static-dispatch-spike.md` §1.1), so it is
  `Fiber.join fiber`, and the API should prefer operations that take an argument.
- *The slice that forces A5.* `Ref.get` must carry `impure` or the optimiser may memoise two reads
  into one. r22 §4.1: *"a `Ref` makes 'not using it' a miscompile."*
- *Fixtures.* Rows 25, 36–38 partially; `run/ImpureNotDuplicated` re-run with a real `Ref`.
- *Self-check.* An `emit/` golden showing that a `Ref` read is not eliminated under `--release`.
- *Measurement.* E-M11 — output size of a program using T0, against one using none of it.
- *Exit.* T0 complete; the whole `run/` corpus still green under both passes.

**S13 — T1: what makes it feel like Effect.** *(PENDING(A4), (A10))*
- *Goal.* r22 §8's T1: `par2`/`par3`/`parAll`, `race`/`raceFirst`, `timeout`, `retry`/`repeat` over
  the `Schedule` that landed pre-spike, `cached`, `Queue`, `Semaphore`, `Latch`, `Clock`, `Log` —
  about 60 signatures, **every one library code over the kernel**, which is the claim r22 §4.3 and
  r23 §11 both make and this slice tests.
- *Spec first.* §15's T1 half, with the three deliberate divergences written down: **`parAll`'s bound
  is mandatory and `"unbounded"` is not offered** (901 MiB against 78.6 KiB for the same 200 000
  operations); **only the scoped `Semaphore` forms exist**, because Effect's bare `take`/`release`
  pair is documented as not interruption-safe and rule 7 says that is a guarantee, not taste; and
  **`timeout` returns `Maybe`**, which is the one row where P2 beats the gold standard.
- *Fixtures.* **rows 25–38** — thirteen of the forty-three, and the largest single block.
- *Self-check.* A dev assertion that a cancelled waiter is removed from every waiter list — the
  obligation `research/16` §5.3 row 10 names, which v4 discharges with three lines in five modules
  through one mechanism (the canceller returned by the suspension primitive).
- *Measurement.* E-M11, E-M15; the black-box gate's wall time (see §6 risk 8).
- *Exit.* Rows 25–38 green at `--jobs=1` and `--jobs=8`, twice, under both build modes.

**S14 — double translation, or the argument for not building it.**
- *Goal.* Answer P2 §11 Q7, which already frames it as *"whether double translation is worth building
  at all"* — the 2026-09-15 decision made the fallback a predictable branch rather than a microtask
  turn.
- *Spec first.* §5's last subsection, written **after** S13's numbers.
- *Fixtures.* `run/BitPolymorphicBothWays` — one `List.map` called with a pure and a suspending
  callback in the same program, both answers asserted. This is the fixture for the failure mode where
  a site whose flag is still a variable takes the direct body.
- *Measurement.* **E-M12** — output size against S4's floor. Plan §3's bound: **the floor may not
  grow at all for a program with no suspending call.** DCE has landed, which is what makes the
  question answerable rather than academic.
- *Exit.* Either it lands and E-M12 holds, or the slice is a written argument and a measurement
  showing the single-body fallback's cost. **Both are acceptable outcomes; a silent skip is not.**

**S15 — measure, and write the report.**
- *Goal.* `docs/design/research/24-effects-spike-results.md`, in report 19's shape: findings,
  method (two machines if two were used, interleaving, what is comparable), a section per measurement
  row, what the review found, known limits that turn a decision, what landing this would require, the
  **options table of §1.2 with no verdict**, and *could not determine*.
- *Touches.* Docs only. `fast-compiler.md` §3.1 is **not** edited on the branch; the decision is taken
  on `master` after the report is read.
- *Exit.* Every number cites a line in `plans/effects-spike-results.md`; three gates green; the
  final diary entry.

---

## 5. Measurement plan

**Discipline.** Best of 5 after a warm-up, on a quiet machine, `uptime` recorded immediately before
each instrument and **no number recorded above a 1-minute load average of 2.0** (`bench/README.md`).
Before/after runs **ABBA-interleaved** — the dispatch diary is blunt about why: *"keep the ABBA
interleaving — it is what made M1a's 20 % trustworthy where S6b's 8 % was not."* Raw lines verbatim
into `plans/effects-spike-results.md`, append-only, corrections as new entries.

| # | Question | Instrument | Baseline | Disqualifying |
|---|---|---|---|---|
| **E-M1** | What do the bits cost code that has none? | `zig build bench -- --generate=100000`, `check` line, plus `Solve.Counters` | S0, on `master` | **> +10 % of `check`.** Today: 77.95 ms for 100 159 lines, 1 285 k LOC/s per core, 5.1× the `fast-compiler.md` §2 budget. Dispatch's precedent is +20.3 %, and a second one is most of the headroom |
| **E-M2** | Does emit move, and does any existing output? | the `emit` line; `tests/corpus/emit/` byte-comparison, dev **and** `--release` | S0 | **any byte of any existing `emit/` golden**, and > 0 % of emit throughput. Dispatch cost emit +48 % |
| **E-M3** | What do the bits do to the interface and to churn? | `bench/churn.sh`, now by interface hash | S0 | an edit that does not change effectfulness moving an interface. Report 19 §4 measured dispatch at 4.4–6.5× worse churn on unannotated `pub` declarations |
| **E-M4** | Does compiled closure-CPS beat an interpreted loop? | `bench/fiber/` against `bench/fiber/ref/` | S1 | **slower than v4's 82 ns per flatMap-equivalent op** (and note v4's generator step is 67 ns). This is the claim the whole lowering rests on |
| **E-M5** | What does the synchronous fast path cost? | same | S1 | worse than v4's 186 ns per `callback` resuming inline. The target is a static branch, against a direct call at 0.75 ns |
| **E-M6** | Fork and join | same | S1 | worse than v4's 472 ns immediate / 3 172 ns scheduled per pair |
| **E-M7** | Cancellation latency | `research/16` §2.4's script, in beni | S1 | **> ~60 ms.** v4 is 57 ms; native `async` + `AbortController` is 301 ms. Above 60 ms means the resume callback is not actually owned |
| **E-M8** | Retained bytes per parked fiber | the allocation gate, sampled, `exit(1)` on breach | S1 | **> 659 B**, or no answer to *can the record be lazy?* `research/16`'s 692 B projection was called 0.2× an Effect fiber on v3; **on v4 the ratio is 1.05**, so size is no longer an advantage |
| **E-M9** | Finaliser install and unwind at depth 20 000 | `bench/fiber/` | S8 | not beating v4's 2 076 ns install. 199 ns unwind is the floor to match |
| **E-M10** | The op budget | the sweep, 16/64/512/2048/never, throughput **and** armed-timer latency, **Node and browser** | S11 | no browser number. P2 §7.5 says 64; r21 §9.3 measured 512 as the knee on Node, and that number is not transferable |
| **E-M11** | Output size, and does a program with no effects pay? | `bench/size.mjs` over `bench/corpus` and the whole `run/` corpus | S0 | the floor moving at all for a program with no suspending call. Today: floor 2 147 raw / 833 brotli dev, 1 880 / 789 release; `bench/corpus` 126 436 / 21 840 dev, 55 593 / 15 017 release. The runtime's own budget is **≤ 5 kB gzip** |
| **E-M12** | Double translation | `bench/size.mjs` with a bit-polymorphic `core/List` | S4's floor | any growth in the no-effects floor |
| **E-M13** | Stack traces | a failure inside a suspended fiber, rendered | S9 | no logical stack, or a per-continuation cost approaching Effect's 7.2 µs — which would mean beni is paying for something it already knows |
| **E-M14** | Determinism | the existing gate, `--jobs=1` and `--jobs=8`, twice, with effects fixtures in the corpus | every slice | any byte difference (`CLAUDE.md` rule 5) |
| **E-M15** | Compiler cost | `git diff --stat master` by directory; cold ReleaseFast build; binary size; each gate's wall time | S0 | the black-box gate, already **78.4 s warm and 2.5× its C0 value**, is the slowest thing a contributor waits for — see risk 8 |

**Two figures to re-take before quoting.** P2 §7.2's `await`-on-a-non-promise at 122–135 ns against
r21 §9.1's 55 ns, and `research/16` §3.8's 481 B parked async frame against r21 §9.4's 50 B. Both
were Node v24.19.0 on the same machine; r21 §12 could not reconcile either. S0's `bench/fiber/ref/`
re-takes them, because P2's §7.2 argument is quoted with a 70× multiplier that may be 25×.

---

## 6. Risks, ranked

Report 19 §11's finding is the frame: *"the recurring failure mode was exit-0 wrongness — a program
that compiled, ran and printed the wrong answer, which a fully green suite coexisted with every
time."* Rows 1–7 are that shape.

1. **A continuation resumed twice, or a fiber resumed after cancellation.** *Sign:* a finaliser runs
   twice, or a value arrives after a cancel. *Revealed by:* S6's `CancelReentrant` and the dev
   assertion in S1. *Why it is first:* it is the failure mode of the three fields P2's record does
   not have, and P2 §7.2's synchronous fast path is what creates the re-entrancy in the first place.
2. **A suspension object threaded through a hand-written JavaScript loop.** `core/List.js`'s `eq`
   returns `true` for any two single-element lists whose element `eq` suspends, at exit 0
   (plan §2.1). *Sign:* none — `!suspension` is `false` and the loop terminates. *Revealed by:* S1's
   two variants of row 39 and S3's `check/bad/SuspendingEqEvidence`. This is `foldl`'s miscompile in
   the position static dispatch created, and report 17's grep cannot see it.
3. **A continuation closing over an `$in$<i>` slot.** The resumed computation reads the loop's *last*
   values and prints a plausible number. *Sign:* `0 0 0` where `0 1 2` is expected. *Revealed by:*
   S4's `run/SuspendInLoopClosure`. `backend.md` §8's rejected in-place reassignment would have been
   a miscompile here for a second reason.
4. **A finaliser skipped, or run late.** *Sign:* the program exits 0 having leaked what it held.
   *Revealed by:* S8's rows 15–19 and its run-exactly-once assertion.
5. **The optimiser's licence under `impure`.** `src/js/Opt.zig`'s single-use inlining and
   `Reach.zig`'s elimination both run today under `language.md` §6's unrestricted licence. *Sign:* a
   side effect happens twice or never; the value is right. *Revealed by:* `run/ImpureNotDuplicated`,
   which lands on `master` **before** the branch precisely so this is not discovered late.
6. **Evaluation order under CPS.** Every construct in `language.md` §6's table has to keep its order
   once a suspension can appear inside it — including the two already-fixed traps, record-literal
   field order and `List.map`'s direction, which were wrong and invisible until `Debug.log` could see
   them. *Sign:* only the sequence is wrong. *Revealed by:* the `run/` corpus's existing
   order-observing fixtures, which run under `--allow-debug`.
7. **A bit lost crossing a module boundary**, so a caller compiles the direct body against a
   suspending callee. *Sign:* single-module tests all pass. *Revealed by:* S2's `.iface` golden and
   the `--stage=raw` determinism module set.
8. **The black-box gate.** It is already **78.4 s warm, 2.5× its value before dispatch**, and it is
   the slowest thing a contributor waits for. The whole `run/` corpus is built and run **twice**,
   once under `--release`; adding 43 conformance fixtures adds 86 builds and 86 runs. *Sign:* the
   gate crossing two minutes. *Revealed by:* E-M15, measured every slice, not at the end. A
   concurrency fixture that sleeps would be far worse, which is a second reason for S11's
   no-durations rule.
9. **Scope creep from "API coverage."** r22's answer is quantitative and reassuring — beni needs
   about **2 %** of Effect's 4 783 exports to cover what its `Effect`, concurrency, resource and
   scheduling families do, because direct style, `Result` + `?`, ADTs with exhaustive matching,
   derived `eq`/`compare` and `|>`-as-syntax delete the other 98 % at the *language* level. The risk
   is reading "Effect-level coverage" as the 139 modules rather than the T0+T1 ~95 signatures. *Sign:*
   a slice that is not in §4. *Mitigation:* §1.3's non-objectives are a list, not a gesture.
10. **Spec drift between the branch and `master`.** M4-4 and M3d will move underneath. *Sign:* a §
    reference in the spec that no longer resolves. *Mitigation:* rebase at every slice boundary, and
    Appendix A as the record of what was decided when.
11. **The closing decision is harder than dispatch's.** Dispatch changed how a comparison is written;
    effects change **what every program's `main` is**, what the optimiser may do, and what the
    interface carries — and unlike dispatch it has an option (b) that is genuinely separable. *Sign:*
    a report that recommends. *Mitigation:* §1.2's four outcomes, each with what it buys, what it
    measurably costs and what it forecloses, and **no verdict** — which is exactly what made report
    19 usable.
12. **Two research reports already contradict each other** on the failure value and on the op budget
    (decisions sheet §C items 1 and 2). *Sign:* a spec section written against one and a fixture
    against the other. *Mitigation:* PENDING(A1) and PENDING(B1) are blockers for S9 and S11
    respectively, not things to resolve while writing code.

---

## 7. Staffing and cadence

### 7.1 The pattern that worked

From the dispatch spike, and it is the arrangement the owner left in place on 2026-09-18 —
*"continue, don't stop; you are manager, planner and validator; Opus agents implement."*

- **One manager**, who writes the briefs, validates, commits and writes the diary. A manager does not
  implement.
- **One implementer building at a time**, from a written brief, in **its own `git worktree`**. The
  OOM of 2026-09-17 is the reason: *"two concurrent implementers plus a long manager transcript is
  over the machine's memory."* On a bigger machine this relaxes — four agents worked on 2026-09-18 —
  but **no concurrent `zig build`, and no ReleaseFast inside an agent**.
- **Read-only reviewers alongside**, and they are not optional: S0's spec review found **5 blocking
  and 15 must-fix defects before a line of code existed**, including a worked example in the spec
  that miscompiled.
- **Research and spec agents are docs-only** and run beside the one builder.
- **≤ 5 agents.**
- **Manager validation of every slice**: the fail-first proof re-run by stashing, the three gates,
  and the measurement re-taken — not accepted from the implementer's transcript.

Four discipline rules the dispatch diary paid for:

- **Pins are not proofs.** A fixture that cannot be made to fail first is useful and must not be
  cited as evidence.
- **Build the compile-time self-check first**, for any pass whose failure mode is a runtime
  `ReferenceError` or a plausible wrong number. It is what saved DCE, and §4 names one per slice.
- **Fix at the obligation, not at the output.** Removing a dedup band-aid immediately surfaced the
  real duplication source.
- **A bisect over a continuous quantity finds where that quantity crossed the threshold you bisected
  on, not where its growth rate changed.** The cubic checker was cubic in the "good" parent commit
  too.

### 7.2 Pace, honestly

The dispatch spike planned "10–11 sessions" for S0–S8 and landed nine planned slices plus one
unplanned fix between 2026-09-16 10:26 and 2026-09-18 13:04 — **about three calendar days, peaking at
five or six slice-sized commits in one day** with full attention and agents.

This spike is **sixteen slices** and it is larger per slice: S5–S11 are seven pieces of a runtime
with no beni precedent, S13 is sixty signatures, and S9 changes the test harness. At the dispatch
pace that is **four to five days of full attention**; a realistic estimate with the owner intermittent
is **six to eight**. The honest statement for the owner is: *the inference half (S0–S3) is a day and
a half and is decidable on its own; the runtime is the rest.*

### 7.3 What the owner is asked, and when

| When | Asked for |
|---|---|
| **Now, before S0** | The five questions of [`plans/effects-decisions.md`](effects-decisions.md) §D — A1, A7, A5, A8, A6 — plus the rider on A3 and A4. Without A1 the spec cannot be written past §11; without A7 no T0 signature can be |
| Before S0 | Whether S2/S3 go to `master` or stay on the branch (§2.2), and whether the five `master`-first items of §2.1 land |
| **After S1** | A one-page note: does compiled closure-CPS beat 82 ns? If not, the lowering argument reopens and the owner decides whether the spike continues |
| **After S2** | Does the check tax hold at ≤ 10 %? If not, the owner decides on the same evidence dispatch's +20.3 % was decided on |
| Before S9 | A1 again if it was deferred; it cannot be deferred past here |
| Before S11 | Nothing — B1 is answered by the sweep, not by the owner |
| Before S13 | A10, A4 |
| **After S15** | The adoption decision, on `master`, on the report, with all four outcomes of §1.2 live |
