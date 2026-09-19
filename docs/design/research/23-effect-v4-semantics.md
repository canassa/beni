# The semantics beni's effects must match, or deliberately decline — Effect v4 under failure, interruption and concurrency, case by case

**Commissioned by** the project owner, 2026-09-19 — *"Clone EffectTS locally. It's our gold
standard. I want to achieve EffectTS levels of quality and API coverage."* Report 21 read how v4
*executes* an effect and report 22 reads its *API surface*. This report answers the third question,
which is the one users feel: **what exactly happens when things fail, race, time out and get
cancelled.** Effect's answers were learned over years of production bugs. beni's spike should start
from them as executable facts rather than rediscover them.

**What this is.** A catalogue of **78 behavioural cases**. Each one is a program that was **run**,
its **verbatim output**, the rule in a sentence, the `references/effect` source line that explains
it, the Effect test that pins it where one exists, and a **for beni** paragraph saying what
[`transparent-effects-proposal.md`](../transparent-effects-proposal.md) — **P2** throughout — says
today: *same*, *different*, or *silent*, and the `tests/corpus/run/` fixture the spike would need.

**What this is not.** Not a design argument, not a runtime reading (report 21 owns that — **read it
first**, and this report builds on it rather than re-deriving it), not an API inventory (report 22).
Where report 21 already took a position, this report cites it rather than repeating it.

**Citations.** `effect:<path>:<line>` is `references/effect/<path>`, all against `3d59ae6`
(2026-09-19), `packages/effect` version `4.0.0-rc.116`. `test:<file>:<line>` is
`references/effect/packages/effect/test/<file>`. Bare document references are into this repository.

**Case numbers.** A case is `G.n` — group `G` (1 = sequencing, 2 = interruption, 3 = combinators,
4 = resources, 5 = schedules, 6 = coordination, 7 = streams, 8 = observability) and its number within
the group. Group `G` lives in section `§G+1`, so **case 3.7 is §4.7**. The case number is what §0 and
the conformance suite refer to; the section number is only where to find it.

**Read §0.** It is the scorecard, the conformance suite and the owner decisions. §1 is the method;
§2–§9 are the eight case groups; §10 is what is a wart; §11 is what could not be determined.

---

## 0. Findings

### 0.1 The scorecard

Each of the 78 cases was classified against P2 §5, §6 and §7 — the only sections that make
behavioural promises.

| verdict | cases | what it means |
|---|---:|---|
| **already specified by P2, and Effect agrees** | **21** | the spike copies Effect and P2 needs no change |
| **specified by P2, and Effect DIFFERS** | **6** | one of the two is wrong; §0.2 says which, per case |
| **SILENT in P2** | **51** | each one is a spec obligation for the spike: a sentence that has to be written before the code is |

**Two thirds of the observable behaviour of a fiber runtime is not in the proposal.** That is the
headline. P2 §6 is 120 lines and specifies a *record*, a *primitive list* and *four obligations*;
what a user of `Task.race` actually experiences — whether the loser's finaliser has finished when
`race` returns, whether a failure on one side ends the race, what a `bracket` release is told about
why it is running — is in none of it. None of the 51 is a surprise in the sense of being *wrong*;
they are unwritten, and `CLAUDE.md` rule 1 is that the document is written before the code.

The distribution is not even. Sections §2 (sequencing, 11 cases) and §3 (interruption, 17) are where
P2 is strongest: 13 of those 28 agree. Sections §7 (coordination, 12), §8 (streams, 6) and §9
(observability, 8) are **26 cases with 25 silences** — P2 names `Queue.take`/`Queue.put` and
`Semaphore.with` and says nothing about any of their behaviour, has no streams at all, and says
nothing about what a program prints or returns when it dies.

### 0.2 The six where P2 and Effect disagree, and who is right

| # | case | P2 says | Effect v4 does | who is right |
|---|---|---|---|---|
| 1 | **§5 case 4.1** — what a `bracket` release is told | `Task.bracket : (() -> r), (r -> ()), (r -> a) -> a` — the release takes only the resource | `release(resource, exit)`: the release is handed the `Exit`, so it can tell success from failure from cancellation (`effect:…/effect.ts:4346-4358`) | **Effect.** A release that cannot tell why it is running cannot commit-or-roll-back, which is the single most common thing a `bracket` is for. This is a **type change to P2 §6.5** and it is cheap now and expensive later |
| 2 | **§6 case 5.1** — what `retry` takes | `Task.retry : Int, (() -> Result x a) -> Result x a` — a *count* | a `Schedule`: `exponential`, `spaced`, `fibonacci`, `jittered`, `recurs`, composed with `concat`/`max`/`min`/`upTo` | **Effect**, and not narrowly. A retry with no backoff is a thundering herd, and `jittered` exists because three retrying clients synchronise. P2's `Int` is the API of a language that has not run anything in production |
| 3 | **§3 case 2.9** — what an interrupted fiber gives its joiner | `Fiber.join : Fiber a -> Result Cancelled a` — cancellation is an ordinary typed value at the join point | `Fiber.join` **propagates** the child's `Interrupt` into the joiner, which then dies of it unless it uses `catchCause`; `Fiber.await` returns the `Exit` as a value | **split.** P2's `Result Cancelled a` is the right *surface* for a language with no exceptions — it is `Fiber.await`, renamed. But P2 has no equivalent of `join`'s propagation, and propagation is what makes `Task.par2` cancel its sibling without the author writing anything. beni needs **both**, and report 21 §11.6's `Cause` decision is the prerequisite |
| 4 | **§3 case 2.10/2.11** — the order of a parent's own finalisers against its children's | §6.2 obligation 4: *"descendants are signalled **before** the parent unwinds"* | the opposite: the parent unwinds its **own** continuation stack first (every `ensuring`/`onExit` frame runs), and only then are the children interrupted and awaited (`effect:…/effect.ts:620-656` — `runLoop` completes, *then* `interruptChildren`) | **P2**, on the guarantee. A parent finaliser that closes a connection a child is still writing to is a use-after-free. Effect's order is an artefact of its implementation — `ensuring` is a stack frame and `children` is a set consulted at exit-publish time — not a decision it argues for. **beni should state children-first and test it** |
| 5 | **§3 case 2.12** — the fork family | `Task.spawn` and `Scope.spawn` | `forkChild`, `forkDetach`, `forkIn(scope)`, `forkScoped` — four, plus `startImmediately` and `uninterruptible` options | **Effect**, and report 21 §0.1 already said so. `forkDetach` is what a background task needs and P2 cannot express it; measured here, a `forkDetach`ed fiber keeps running after `runPromise` has resolved (case 2.12) |
| 6 | **§4 case 3.6** — what `timeout` returns | `Task.timeout : Int, (() -> a) -> Maybe a` | v4's `timeout` **fails** with a `TimeoutError`; `timeoutOption` returns the `Option` | **P2.** `Maybe a` is `timeoutOption` and it is the right default for a language whose errors are `Result` values: a `TimeoutError` in the error channel forces every caller to widen its error type for a condition most callers want to fold into a value. Effect ships both and its *default* is the loud one; beni should ship the quiet one and let `Result` do the rest |

Four of the six go to Effect, one to P2, one is split. Cases 1 and 2 are **type changes to P2 §6.5**
that should be made before E4 starts, because both are cheap now and are API breaks later.

### 0.3 The conformance suite

The single most useful artifact here. Each row is a `tests/corpus/run/` fixture: a beni program whose
*intent* is one behavioural rule and whose `.expected` is the text that proves it. The **kernel**
column is report 21 §11.3's ten pieces, so the spike can land them incrementally and each piece
arrives with the fixtures it unlocks. Ordering is by kernel piece, then by dependency.

Three harness facts constrain the list, and one of them is an obligation:

- `run/X.beni + X.expected` compares **stdout only**, and the emitted program **must exit 0**
  (`tests/blackbox/corpus_test.zig:677`). Every fixture below therefore prints its evidence and
  exits 0. **A fixture that asserts a non-zero exit code needs a new corpus kind** — see decision 7.
- The whole `run/` corpus is built and run **twice**, once with `--release`
  (`corpus_test.zig:18-22`). Every fixture below must be release-stable, which for a concurrency
  fixture means **no wall-clock number in the golden**: a fixture prints an *order*, not a duration.
- The determinism test runs the corpus at `--jobs=1` and `--jobs=8` and byte-compares
  (`CLAUDE.md` rule 5). A fixture whose output depends on scheduler timing is a bug. Every row below
  prints a sequence that is forced by the semantics, never one that happens to be fast.

| # | fixture | kernel piece | intent | expected output |
|---|---|---|---|---|
| 1 | `run/SuspendFastPath` | 2, 3 | a `foreign suspends` primitive that answers synchronously resumes inline, in the same tick, with no scheduler turn | `before`, `value`, `after` |
| 2 | `run/SuspendInLoop` | 2 | a suspension inside the tail-call loop of `List.foldl` over 1 000 000 elements does not grow the JavaScript stack | `sum 500000500000` |
| 3 | `run/SuspendOneShot` | 3 | a primitive that calls its resume **twice** resumes the continuation exactly once (P2 §5 *one-shot*) | `resumed once`, `value a` |
| 4 | `run/SuspendInLoopClosure` | 2, 3 | a continuation must close over the iteration's prologue `const`s, never a `$in$<i>` slot (plan §6 row 3) | `0 1 2` |
| 5 | `run/CancelParked` | 4 | a fiber parked on an uncooperative primitive unwinds at **cancel** time, not at settle time | `parked`, `cancelled`, `done` — and the never-settling primitive's line absent |
| 6 | `run/CancelDropsLateResume` | 4 | the abandoned primitive's later resume is dropped (case 2.15) | `cancelled`, `late resume ignored` |
| 7 | `run/CancelCanceller` | 3, 4 | a primitive's canceller runs on interrupt and clears its timer (case 2.3) | `registered`, `canceller ran`, `exit cancelled` |
| 8 | `run/CancelReentrant` | 4 | a fiber interrupted from **inside its own continuation**, on the fast path, runs its finalisers once (report 21 §0.5 item 3) | `finalizer` once, `cancelled` |
| 9 | `run/CancelSyncLoop` | 4 | a `while` loop inside one `foreign` is **not** interruptible — the guarantee is stated, not pretended (case 2.1) | `loop finished`, `interrupt observed after` |
| 10 | `run/InterruptDoneFiber` | 4, 8 | interrupting a finished fiber is a no-op and its result is unchanged (case 2.7) | `value`, `still value` |
| 11 | `run/UninterruptibleLatch` | 5 | an interrupt arriving inside an uninterruptible region is **latched** and fires at the region's end (case 2.5) | `region start`, `region end`, `cancelled`, and no `after region` |
| 12 | `run/BracketAcquireUninterruptible` | 5, 9 | an interrupt during `acquire` does not abandon the resource: acquire completes, release runs (case 2.4) | `acquire`, `release`, `cancelled` |
| 13 | `run/BracketUseInterruptible` | 5, 9 | `use` is interruptible between two uninterruptible ends (case 2.6 / `test:Effect.test.ts:1897`) | `acquire`, `use started`, `release`, and no `use finished` |
| 14 | `run/BracketReleaseUninterruptible` | 5, 9 | a **second** interrupt during `release` does not cut the release short (case 2.13) | `release start`, `release end` |
| 15 | `run/BracketCancel` | 9 | finalisers run at cancel time, **LIFO**, before the program continues (case 1.3) | `inner`, `middle`, `outer` |
| 16 | `run/BracketReleaseSeesOutcome` | 7, 9 | the release is told **why** it is running — success, failure, cancellation (case 4.1; **this fixture does not compile under P2 §6.5's type**) | `release ok`, `release err`, `release cancelled` |
| 17 | `run/BracketNested` | 9 | an inner `Task.scope` closes at the end of its block, not at the outer's (case 4.6) | `acquire O`, `acquire I`, `release I`, `after inner`, `release O` |
| 18 | `run/FinalizerFailsWhileFailing` | 7, 9 | a finaliser that fails while the body already failed **loses neither** failure (case 1.4) | `body-error` and `fin-error`, both |
| 19 | `run/FinalizerSlowDelaysExit` | 9 | the program does not exit until the finalisers have finished (case 1.5) | `cancelled`, `finalizer done`, `exit` — in that order |
| 20 | `run/SpawnJoin` | 8 | `Task.spawn` + join returns the child's value | `child value` |
| 21 | `run/SpawnJoinCancelled` | 7, 8 | joining a **cancelled** child: what the joiner gets (case 2.9 — the fixture that pins decision 3) | `join saw Cancelled` |
| 22 | `run/ScopeChildren` | 8, 9 | leaving a `Task.scope` block cancels every fiber spawned into it and **waits** for them (case 4.4) | `tick a`, `tick b`, `closing`, `cancelled a`, `cancelled b`, `closed` |
| 23 | `run/ParentFinalizerOrder` | 8, 9 | children are signalled **before** the parent's own finalisers (P2 §6.2 obligation 4 — Effect does the opposite; decision 4) | `child cancelled`, `parent finalizer`, `done` |
| 24 | `run/SpawnDetached` | 8 | a detached task outlives its parent, and the program still exits (case 2.12) — **only if decision 5 adds `Task.spawnDetached`** | `parent done`, `detached tick`, `exit` |
| 25 | `run/Par2Both` | 8 | `Task.par2` runs both and returns both, in argument order (case 3.1) | `(a, b)` |
| 26 | `run/Par2FailCancelsSibling` | 4, 8 | a failure in one branch cancels the other **and waits for its finaliser** (case 3.2; decision 2) | `b failed`, `a cancelled`, `a finalizer`, `error b` |
| 27 | `run/ParAllOrder` | 8 | `Task.parAll` returns results in **argument** order regardless of completion order (case 3.1) | `[a, b, c]` with completion `b, c, a` logged first |
| 28 | `run/ParAllBounded` | 8 | the mandatory bound is respected: a peak-concurrency counter never exceeds it (case 3.8) | `peak 3` |
| 29 | `run/RaceLosersCancelled` | 8 | `Task.race` cancels the losers **and waits for their finalisers before returning** (case 3.4) | `loser finalizer`, `winner` — in that order |
| 30 | `run/RaceOneSideFails` | 8 | a failure on one side does **not** end the race; the other side may still win (case 3.5) | `slow success` |
| 31 | `run/RaceBothFail` | 7, 8 | when every branch fails, both failures reach the caller (case 3.5) | `e1 + e2` |
| 32 | `run/TimeoutAwaitsCleanup` | 8 | `Task.timeout` does not return until the timed-out work's finalisers have finished (case 3.7; decision 1) | `timed out`, but `cleanup done` printed **first** |
| 33 | `run/TimeoutUninterruptible` | 5, 8 | a timeout around an uninterruptible region is a **request**, not a guarantee (case 3.10) | `body finished`, `Nothing` |
| 34 | `run/RetryBackoff` | — | `Task.retry` with an exponential schedule attempts the right number of times (case 5.1) | `attempt 1..4`, `ok` |
| 35 | `run/RetryNotOnCancel` | 4 | a cancelled attempt is **not** retried (case 5.2) | `attempt 1`, `cancelled` |
| 36 | `run/QueueTakerCancelled` | 3, 4 | a cancelled `Queue.take` is removed from the waiter list and the next value is not lost (case 6.3) | `t1 cancelled`, `t2 took A`, `later take B` |
| 37 | `run/QueueBoundedBackpressure` | 3 | a producer blocks on a full queue and resumes when a slot frees (case 6.2) | `offered 1`, `offered 2`, `blocked`, `took 1`, `offered 3` |
| 38 | `run/SemaphorePermitsNotLeaked` | 3, 4, 9 | an interrupted waiter and a failing body both return their permits (case 6.4) | `acquired after` |
| 39 | `run/ListEqSuspendingElement` | 2, 3 | plan §6 row 1: `[x] == [y]` for a type whose `eq` suspends must not answer `true` through `core/List.js`'s JavaScript loop | under decision 6(a) this becomes `check/bad/SuspendingEqEvidence`; otherwise `false` |
| 40 | `run/MapEffectOrder` | — | plan §6 row 4: `List.map` runs its callback front to back — **writable today**, fails today | `visit a`, `visit b`, `visit c` |
| 41 | `run/ImpureNotDuplicated` | — | plan §6 row 6: an `impure` call behind a shared binding happens exactly once | `1` |
| 42 | `run/DefectFromForeign` | 7 | a throwing `foreign` produces a defect that `?` cannot catch (decision 6) | `uncaught: boom` on stderr, or a `Task.scope` result naming it |
| 43 | `run/MainFails` | 7, 10 | what `main` prints and what it exits with when its fiber dies (decision 7) | **needs a new corpus kind** |

Forty-three fixtures. **Twenty-two of them are unlocked by kernel pieces 3, 4, 5 and 9** — the
suspension primitive, interruption, interruptible regions and `Scope` — which is the same finding
report 21 §11.3 reached from the other side: those four are the kernel, and everything above row 20
is library code over them.

Landing order, as slices: rows 1–4 with E3 (no fibers needed at all); rows 5–11 with kernel pieces 3
and 4; rows 12–19 with 5 and 9; rows 20–24 with 8; rows 25–38 are library code and can land in any
order once 3/4/5/8/9 exist; rows 39–41 are **writable before any of this** and rows 40 and 41 fail
today.

### 0.4 The decisions this forces on the owner

Numbered from 10, since `plans/effects-plan.md` §5 owns 1–8 and report 21 §11.6 proposes 9
(`Cause`). Each has options and a recommendation.

**Decision 10 — does `Task.timeout` return before or after the timed-out work's cleanup?**
Measured (case 3.7): Effect's `timeout` returned at **255 ms** for a 50 ms budget, because the body's
200 ms finaliser ran first. Options: **(a)** wait, as Effect does; **(b)** return at the deadline and
let cleanup finish in the background; **(c)** wait, with a second bounded budget (Trio's shielded
cleanup timeout). **Recommendation: (a) for v1, and say so in the type's documentation.** (b) is the
`Promise.race` semantics P2 §6.5 already rejects for `race` — it hands back control while a socket is
still open — and the same argument applies. (c) is the right long-term answer and needs `bracket` to
carry a budget, which is more machinery than v1 needs. Whichever is chosen, **it is a sentence users
will rely on**: "`timeout 50` may take longer than 50 ms" is surprising and must be written down.
Fixture: row 32.

**Decision 11 — does `Task.parAll`/`par2` wait for interrupted siblings' finalisers before
returning the failure?** Measured (case 3.2): Effect waits — `Effect.all` returned only after both
siblings' 80 ms finalisers. Options: **(a)** wait; **(b)** return immediately. **Recommendation:
(a)**, and it is the same argument as decision 10 and as P2 §3.4's *"the group is a scope"*: a group
that has returned must own nothing. Note that (a) makes a group's latency the **max** of the
failure and the slowest sibling's cleanup, which is worth documenting. Fixture: row 26.

**Decision 12 — what is a defect in beni, and is it catchable?**
beni has no exceptions, so the only sources are a throwing `foreign`, `Debug.todo`, and a runtime
invariant break. Options: **(a)** report 21 §11.6(a) — a `Die` reason in a runtime `Cause`, not
catchable by `?`, surfacing only through `Fiber.join`/`Task.scope`; **(b)** fatal, the program dies;
**(c)** catchable, mapped to a `Result` failure the way `Effect.try` does (case 1.8).
**Recommendation: (a).** (c) is the one to reject explicitly: Effect *offers* it and its own
`Effect.try` produces the string `"An error occurred in Effect.try"` when no mapper is supplied
(case 1.8) — a typed error with no information in it, which is exactly the outcome `CLAUDE.md` rule 7
calls taste rather than a guarantee. (b) is defensible for v1 and makes `run/DefectFromForeign` a
build-time diagnostic instead. Fixture: row 42.

**Decision 13 — virtual time in tests.**
Half of this report's catalogue is untestable in beni's golden-output corpus without it: a fixture
that sleeps is a fixture that is slow and flaky, and the determinism test runs the corpus four times.
Effect's answer is `TestClock` — a `Clock` service the fiber reads, with `TestClock.adjust(duration)`
advancing it — and a 1-hour exponential retry schedule completed in **under 200 ms of wall clock**
with a deterministic attempt log (case 5.5). Options: **(a)** the platform exposes a swappable clock
from the first commit, as report 21 §8.4 already argues for the *scheduler*; **(b)** corpus fixtures
use real short sleeps and tolerate the flake; **(c)** no fixture may sleep, and every timing rule is
tested by ordering alone. **Recommendation: (a) plus (c).** (c) is the discipline §0.3 already
imposes — a golden records an *order*, never a duration — and (a) is what makes `run/RetryBackoff`
and `run/TimeoutAwaitsCleanup` possible at all. The clock is a **second** fiber-local beside the
scheduler (report 21 §7.3 lists three; this makes four).

**Decision 14 — what does a beni program print, and exit with, when `main`'s fiber dies?**
`boundary.md` §5 owns `Program` and is silent; `platforms/node/runtime.js` writes `program.out` and
sets `process.exitCode = program.code`, both read off a value, so there is nowhere for a *failure* to
go. Measured (case 8.8), `NodeRuntime.runMain` under `@effect/platform-node@4.0.0-rc.116`:
**0** for success, **1** for a typed failure, **1** for a defect, and **130** for an interrupt —
128 + SIGINT, the shell convention. Options: **(a)** copy that mapping; **(b)** 0/1 only; **(c)**
`main` cannot fail, enforced by `sync` (plan §5 decision 5(a)), and the question does not arise for
`main` but still arises for a spawned fiber nobody joined. **Recommendation: (a) for the exit codes
and (c) for `main` itself** — they are not exclusive, because plan §5 decision 5(a) constrains
`main`'s *body* and says nothing about a `Task.spawn` inside it. And note the corpus gap: a `run/`
fixture must exit 0, so **row 43 needs a new fixture kind** — the natural one is `build/bad/`'s shape
applied to a *running* program, `run/bad/X/` with an `_expected.out` and an expected exit code.

**Decision 15 — does beni have `Fiber.await` as well as `Fiber.join`?**
P2 §6.5 has only `join`, typed `Fiber a -> Result Cancelled a`, which is Effect's `await` with a
narrower payload. Effect has both and they differ (case 2.9): `await` hands back the `Exit` as a
value, `join` **propagates** the child's failure into the joiner. Options: **(a)** both, with `join`
propagating; **(b)** only the value-returning one, and every caller writes the propagation itself.
**Recommendation: (a)**, because propagation is what `Task.par2` and `Task.race` are built out of —
they are not primitives in v4, they are `callback` + `forkUnsafe` + observers over exactly this
(`effect:…/effect.ts:1606-1661`) — and a language whose users cannot write `par2` themselves has
withheld a capability (`CLAUDE.md` rule 7).

**Decision 16 — does beni ship streams, and when?**
§8's six cases are what "stream semantics" commits to: pull-based evaluation, a finaliser that runs
when the consumer stops early, interruption mid-element, backpressure, and sibling interruption on a
failed inner stream. All six work in v4 and all six are *derivable* from the kernel — a stream is a
`Queue`, a `Scope` and a fiber. Options: **(a)** not in v1, and say so; **(b)** v1. **Recommendation:
(a)**, with §8's cases recorded as the acceptance criteria for whenever it happens, because the
kernel is what makes them possible and the kernel is what is being built.

### 0.5 The ten cases whose behaviour is most worth knowing before writing any code

1. **`timeout` waits for cleanup** (3.7) — 255 ms for a 50 ms budget. Non-obvious, and the single
   most likely thing a first implementation gets wrong.
2. **A race does not end when one side fails** (3.5) — `race(failsAt20ms, succeedsAt80ms)` returns
   the **success**. Every hand-rolled `Promise.race` gets this wrong.
3. **A parent runs its own finalisers before interrupting its children** (2.10, 2.11) — the exact
   reverse of P2 §6.2 obligation 4, and the reverse of what a resource hierarchy wants.
4. **A `bracket` release is handed the `Exit`** (4.1) — P2's type cannot express it.
5. **A self-interrupt is catchable; an external one is not** (2.16) — two different mechanisms
   wearing one name.
6. **`retry` silently does not retry a defect or an interrupt** (5.2) — and in beni this falls out of
   `Result` for free, which is a point for P2.
7. **An unhandled failure from `runFork` is silent and exits 0** (8.4, 8.5) — a fiber can die
   unobserved and the process reports success. Effect's own answer is a log level
   (`effect:packages/effect/src/References.ts:551`), not a guarantee.
8. **`Effect.try` with no mapper produces the error string `"An error occurred in Effect.try"`**
   (1.8) — a typed failure carrying no information, which is what happens when a language without a
   value-level error type retrofits one.
9. **A finaliser that fails while the body failed keeps both failures** (1.4) — and `Result e a` has
   nowhere to put the second one.
10. **`TestClock` makes a ten-hour retry schedule run in under 200 ms, deterministically** (5.5) —
    this is what makes a golden-output corpus able to test concurrency at all.

---

## 1. Method

### 1.1 What was run

`effect@4.0.0-rc.116` and `@effect/platform-node@4.0.0-rc.116`, installed from npm into a session
scratchpad — the same versions as the vendored tree at `3d59ae6`, so the source read and the code
run are the same code. Node **v24.19.0**, Linux 6.12.110, Ryzen 9 5950X.

**78 scripts**, `cases/c101.mjs` … `cases/c808.mjs`, one behaviour per script, each at most 25
lines. Every one was run by `run.sh`, which prints the file, runs it under a 25 s `timeout`, and
prints its output and exit status; the full transcript is `transcript.txt` in the scratchpad.
**77 of 78 exit 0**; the one that exits 1 is case 8.6, where exiting 1 *is* the finding.

Two presentational conventions, stated so the outputs below are honest:

- **Absolute scratchpad paths in `Cause.pretty` output are shortened to `…/`.** Nothing else in any
  output block is edited; the text is otherwise verbatim, including spacing.
- Several scripts share a three-line helper that runs an effect and prints its `Exit`:

  ```js
  const show = async (label, eff) => {
    const e = await Effect.runPromiseExit(eff)
    console.log(label, e._tag, e._tag === "Success" ? e.value : e.cause.reasons.map((r) => `${r._tag}(${r.error})`).join(" + "))
  }
  ```

  Where a case's listing begins with `const show = …` it is this, possibly with the formatting of
  the failure branch adjusted for that case.

### 1.2 The machine was busy, and what that means for these numbers

Other agents were running `zig build` throughout. **These are semantics experiments, not
benchmarks.** No case asserts a duration; every timing claim is a *bracket* with a margin of at least
3× the thing being measured — a 5-second sleep interrupted at 30 ms is asserted as "returned in under
300 ms", a 200 ms finaliser as "at least 240 ms". Where a raw millisecond number appears in an output
block (cases 3.7 and 4.2) it is reported as observed and no conclusion rests on its exact value.

Report 21's performance figures are not re-taken here and nothing in this report contradicts them.

### 1.3 What was read

`packages/effect/src/internal/effect.ts` in the regions cited — `595-763` (fiber, evaluate,
interrupt), `903-963` (`fiberInterrupt`), `1148-1224` (`callback`), `1606-1800` (race family),
`3806-3905` (timeout family), `3900-4250` (`Scope`, `acquireRelease`, `onExit`), `4340-4580`
(`acquireUseRelease`, interruptibility), `4960-5130` (bounded concurrency) — plus
`internal/schedule.ts:51-190` (`retry`, `retryOrElse`, `repeat`), `Schedule.ts`, `Scope.ts`,
`Fiber.ts:60-130`, `Queue.ts`, `PubSub.ts:1083-1200`, `Cause.ts`, `Effect.ts` (signatures),
`testing/TestClock.ts`, and `migration/forking.md` and `migration/v3-to-v4.md` for renames.

`packages/effect/test/` was mined for the tests that pin each behaviour; test citations below are
`file:line` into that directory and were produced by a survey of the whole suite. Where a section
says *no test pins this*, that is a grep result, not an absence of effort.

### 1.4 What was not run

- **Nothing in a browser.** Node only, as reports 16 and 21 were.
- **No beni code.** Every "for beni" paragraph is a *proposal*, not a measurement; the one beni
  measurement quoted (`List.map`'s right-to-left order) is `plans/effects-plan.md` §2.4's, not mine.
- **No `@effect/platform-node` beyond `NodeRuntime.runMain`** (case 8.8).

---

## 2. Sequencing and failure

### 2.1 — case 1.1: a failure short-circuits the rest of the sequence

```js
import { Effect, Exit } from "effect"
const p = Effect.gen(function* () {
  yield* Effect.sync(() => console.log("step 1"))
  yield* Effect.fail("boom")
  yield* Effect.sync(() => console.log("step 2 (must not print)"))
  return "done"
})
console.log(JSON.stringify(await Effect.runPromiseExit(p).then((e) =>
  Exit.isFailure(e) ? { tag: "Failure", reasons: e.cause.reasons.map((r) => r._tag), error: e.cause.reasons[0].error } : e)))
```

```
step 1
{"tag":"Failure","reasons":["Fail"],"error":"boom"}
```

**Rule.** A failure abandons the rest of the sequence and becomes the effect's `Exit`.

**Pinned by** `effect:packages/effect/src/internal/core.ts:541-555` — `failCause`'s `[evaluate]`
walks `getCont(contE)`, skipping every success continuation.

**For beni: same, by a different mechanism.** `language.md` §6.6's `?` desugars to a `case` on a
fresh local, so short-circuiting is a `return` in emitted JavaScript and needs no runtime support at
all. This is the one place where having no exceptions makes the runtime *smaller*, and it is worth
saying in the spec: **beni's error channel is not the runtime's.** No fixture needed — the corpus
already covers `?`.

### 2.2 — case 1.2: `ensuring`, `onExit` and `onError` — which run, and in what order

```js
import { Effect } from "effect"
const probe = (label, body) =>
  body.pipe(
    Effect.onExit((exit) => Effect.sync(() => console.log(label, "onExit", exit._tag))),
    Effect.onError((cause) => Effect.sync(() => console.log(label, "onError", cause.reasons.map((r) => r._tag).join(",")))),
    Effect.ensuring(Effect.sync(() => console.log(label, "ensuring"))),
    Effect.exit
  )
console.log("-- success --"); await Effect.runPromise(probe("ok", Effect.succeed(1)))
console.log("-- failure --"); await Effect.runPromise(probe("ko", Effect.fail("boom")))
console.log("-- defect --");  await Effect.runPromise(probe("die", Effect.sync(() => { throw new Error("thrown") })))
```

```
-- success --
ok onExit Success
ok ensuring
-- failure --
ko onExit Failure
ko onError Fail
ko ensuring
-- defect --
die onExit Failure
die onError Die
die ensuring
```

**Rule.** `onExit` runs on every outcome and is told which; `onError` runs only on a failure and is
told the `Cause`; `ensuring` runs on every outcome and is told nothing. All three are the same
primitive, `onExitPrimitive` (`effect:…/effect.ts:4137-4174`), differing only in what they pass
through; the order is innermost-first because each is a frame on the continuation stack.

**Pinned by** `test:Effect.test.ts:2326` *fail ensuring*, `:2339` *fail on error*, `:2501`
*onResult - ensures that a cleanup function runs when an effect fails*, `:2518` *onExit - callback
observes interrupt exit when the fiber is interrupted*.

**For beni: SILENT.** P2 §6.3 has `Task.bracket` and nothing else. A bracket whose acquire is `()` is
`ensuring`, so the surface can be narrower than Effect's — but the **three-way split is a real
distinction** and a user who wants "log only if it failed" should not have to write a `case` on a
type the language does not have. Minimum for v1: `Task.bracket` with an outcome-carrying release
(decision in §0.2 row 1), out of which `ensuring` and `onError` are one-liners in `core/`.
Fixture: covered by rows 15 and 16.

### 2.3 — case 1.3: nested finalisers run LIFO, on both mechanisms

```js
import { Effect } from "effect"
const p = Effect.succeed("v").pipe(
  Effect.ensuring(Effect.sync(() => console.log("inner"))),
  Effect.ensuring(Effect.sync(() => console.log("middle"))),
  Effect.ensuring(Effect.sync(() => console.log("outer"))))
console.log("value:", await Effect.runPromise(p))
const scoped = Effect.gen(function* () {
  yield* Effect.addFinalizer(() => Effect.sync(() => console.log("scope A")))
  yield* Effect.addFinalizer(() => Effect.sync(() => console.log("scope B")))
  yield* Effect.addFinalizer(() => Effect.sync(() => console.log("scope C")))
}).pipe(Effect.scoped)
await Effect.runPromise(scoped)
```

```
inner
middle
outer
value: v
scope C
scope B
scope A
```

**Rule.** Both finaliser mechanisms are LIFO, and they are genuinely two mechanisms: the `ensuring`
frames unwind the *continuation stack* (so "inner" is the one nearest the body), the `Scope` runs its
keyed map **backwards**, `for (let i = arr.length - 1; i >= 0; i--)`
(`effect:…/effect.ts:3941-3962`).

**For beni: same.** P2 §6.2 obligation 2 says LIFO and report 21 §5.1 already says the two mechanisms
must both exist. Fixture: row 15.

### 2.4 — case 1.4: a finaliser that fails while the body already failed

```js
import { Effect } from "effect"
const q = Effect.fail("body-error").pipe(Effect.onExit(() => Effect.die(new Error("finalizer-died"))))
const exit = await Effect.runPromiseExit(q)
console.log("reasons:", exit.cause.reasons.map((r) => r._tag).join(" + "))
for (const r of exit.cause.reasons) console.log(" ", r._tag, r._tag === "Fail" ? r.error : String(r.defect))
const scopedExit = await Effect.runPromiseExit(Effect.gen(function* () {
  yield* Effect.addFinalizer(() => Effect.fail("fin-A-failed"))
  return yield* Effect.fail("body-error")
}).pipe(Effect.scoped))
console.log("scope reasons:", scopedExit.cause.reasons.map((r) => `${r._tag}(${r.error ?? r.defect})`).join(" + "))
```

```
reasons: Fail + Die
  Fail body-error
  Die Error: finalizer-died
scope reasons: Fail(body-error) + Fail(fin-A-failed)
```

**Rule.** Neither failure is lost. The body's cause comes first and the finaliser's is appended —
`combineFinalizerCause` (`effect:…/effect.ts:3935-3939`), and the `Cause` is a flat array precisely
so this is one concat (report 21 §6.1).

**Pinned by** `test:Effect.test.ts:2354` *finalizer errors merged*, `:2394` *scoped combines usage
and finalizer failures*, `:2455` *combines usage and release failures*.

**For beni: SILENT, and it is report 21 §11.6's decision in its sharpest form.** `Result e a` has
room for one error. Under P2 §6.5's `Fiber.join : Fiber a -> Result Cancelled a` the finaliser's
failure has nowhere to go and would be **dropped**, silently, at exactly the moment a user most needs
to know. The flat `Cause` of report 21 §11.6(a) is the only option on the table that can express
this. Fixture: row 18 — and note it cannot be written until the decision is taken.

### 2.5 — case 1.5: a slow finaliser delays the exit

```js
import { Effect } from "effect"
const t0 = Date.now()
const p = Effect.fail("boom").pipe(
  Effect.ensuring(Effect.sleep("150 millis").pipe(Effect.tap(() => Effect.sync(() => console.log("slow finalizer done at", Date.now() - t0 >= 140 ? ">=140ms" : "<140ms"))))),
  Effect.exit)
await Effect.runPromise(p)
console.log("runPromise resolved at", Date.now() - t0 >= 140 ? ">=140ms" : "<140ms")
```

```
slow finalizer done at >=140ms
runPromise resolved at >=140ms
```

**Rule.** A finaliser may suspend, and the effect does not complete until it has finished. This is
what makes decisions 10 and 11 matter: every "does X wait?" question below is this rule composed
with a cancellation.

**For beni: SILENT, and P2 §6.3 has an argument about it that points the other way.** §6.3 quotes
`research/16` §5.3 row 4 calling `sync` *"load-bearing"* for a release under native `async` and then
says the fiber lowering *"removes `bracket`'s demand for a non-suspending argument entirely"* — true
for **correctness**, false for **latency**. A suspending release delays a cancellation without
bound, and P2 §6.3 already names the answer (*"take Trio's bounded shield… and not Kotlin's
unbounded `withContext(NonCancellable)`"*) without adopting it. Fixture: row 19.

### 2.6 — case 1.6: a defect and an expected failure, and what catches which

```js
import { Effect, Cause } from "effect"
const show = async (label, eff) => { /* prints exit tag + reason tags */ }
const failed = Effect.fail("E")
const died = Effect.sync(() => { throw new Error("D") })
await show("fail + catch      ", failed.pipe(Effect.catch((e) => Effect.succeed("caught " + e))))
await show("die  + catch      ", died.pipe(Effect.catch((e) => Effect.succeed("caught " + e))))
await show("die  + catchDefect", died.pipe(Effect.catchDefect((d) => Effect.succeed("caught " + d.message))))
await show("fail + catchDefect", failed.pipe(Effect.catchDefect((d) => Effect.succeed("caught " + d))))
await show("die  + catchCause ", died.pipe(Effect.catchCause((c) => Effect.succeed("caught " + Cause.squash(c).message))))
await show("fail + catchCause ", failed.pipe(Effect.catchCause((c) => Effect.succeed("caught " + Cause.squash(c)))))
```

```
fail + catch       Success "caught E"
die  + catch       Failure Die
die  + catchDefect Success "caught D"
fail + catchDefect Failure Fail
die  + catchCause  Success "caught D"
fail + catchCause  Success "caught E"
```

**Rule.** Three handlers over one `Cause`: `catch` sees only `Fail` reasons, `catchDefect` only
`Die`, `catchCause` everything. A defect passes straight through an ordinary `catch` — which is the
whole point of the distinction. (v4 spellings: `catch` is exported as `catch_ as catch`,
`effect:packages/effect/src/Effect.ts:2694`; `catchDefect` is `:3312`; v3's `catchAllDefect` is gone.)

**For beni: SILENT, and this is the shape decision 12 takes.** beni's `?` is `catch` — it sees the
`Err` branch of a `Result` and nothing else. The question is whether `catchDefect` has any analogue.
**Recommendation: no.** A defect is a bug, not a condition, and the one place it must be observable
is at a fiber boundary, where report 21 §11.6(a) puts it. Making it catchable at every call site is
the road to `catch (e) {}`.

### 2.7 — case 1.7: `orDie` and `sandbox` — moving a failure between channels

```js
import { Effect, Cause } from "effect"
const exit = await Effect.runPromiseExit(Effect.fail("E").pipe(Effect.orDie))
console.log("orDie reasons:", exit.cause.reasons.map((r) => `${r._tag}(${r.defect ?? r.error})`).join(","))
const caught = await Effect.runPromise(Effect.fail("E").pipe(Effect.orDie,
  Effect.catch(() => Effect.succeed("catch saw it")), Effect.catchDefect((d) => Effect.succeed("catchDefect saw " + d))))
console.log("after orDie:", caught)
const sb = await Effect.runPromiseExit(Effect.fail("E").pipe(Effect.sandbox))
console.log("sandbox failure payload is a Cause:", Cause.isCause(sb.cause.reasons[0].error))
```

```
orDie reasons: Die(E)
after orDie: catchDefect saw E
sandbox failure payload is a Cause: true
```

**Rule.** `orDie` moves a typed failure into the defect channel ("I have decided this cannot
happen"); `sandbox` moves the whole `Cause` into the *typed* channel so it can be pattern-matched.
They are the two directions of one conversion.

**For beni: SILENT, and mostly not wanted.** `orDie` is a promise the type system cannot check and
`CLAUDE.md` rule 7's test — *what guarantee does this buy?* — answers "none". `sandbox` is different:
if report 21 §11.6(a) lands, *something* has to turn a runtime `Cause` into a beni value at the
fiber boundary, and `Task.scope`'s and `Fiber.join`'s result types are where it belongs — one
conversion, at two named places, rather than a combinator anyone may reach for.

### 2.8 — case 1.8: `Effect.try` and `Effect.tryPromise` at the JavaScript boundary

```js
import { Effect } from "effect"
const show = async (label, eff) => { /* prints exit tag + reason tags with .error.message */ }
await show("try ok        ", Effect.try(() => 41 + 1))
await show("try throws    ", Effect.try(() => { throw new Error("X") }))
await show("try + catch fn", Effect.try({ try: () => { throw new Error("X") }, catch: (e) => "mapped:" + e.message }))
await show("tryPromise ok ", Effect.tryPromise(() => Promise.resolve(7)))
await show("tryPromise rej", Effect.tryPromise(() => Promise.reject(new Error("R"))))
await show("promise rej   ", Effect.promise(() => Promise.reject(new Error("R"))))
```

```
try ok         Success 42
try throws     Failure Fail(An error occurred in Effect.try)
try + catch fn Failure Fail(mapped:X)
tryPromise ok  Success 7
tryPromise rej Failure Fail(An error occurred in Effect.tryPromise)
promise rej    Failure Die(Error: R)
```

**Rule.** `try`/`tryPromise` convert a throw or a rejection into a **typed** failure; without a
`catch` mapper the type is `UnknownError` and the message is the literal string *"An error occurred
in Effect.try"*. `Effect.promise` is the "this cannot reject" variant and a rejection becomes a
**defect**.

**Pinned by** `test:Effect.test.ts:324` *maps thrown values to UnknownError in direct-thunk form*,
`:347` *maps thrown values into typed failures*, `:360` *turns a throwing catch mapper into a
defect*, `:425` / `:485` for the promise forms.

**For beni: SILENT, and the case largely disappears.** `boundary.md` §2 says only platform packages
write `foreign`, so the "wrap a throwing JavaScript API" problem is the *platform author's*, once per
primitive, not the user's. A platform author writing `foreign suspends httpSend : Request -> Response`
writes the `try`/`catch` in the sibling `.js` and returns a `Result`. **The lesson to take is the
negative one**: Effect's mapper-less form produces a typed error with no information in it, and beni
should not offer a shortcut that does the same. `boundary.md` §4 could require it — a `foreign`
whose sibling may throw must declare a `Result` return — which is a check, not a combinator.

### 2.9 — case 1.9: `Effect.exit` and `Effect.result` reify the outcome as a value

```js
import { Effect } from "effect"
const r1 = await Effect.runPromise(Effect.fail("E").pipe(Effect.result))
console.log("result of a failure:", r1._tag, r1.failure ?? r1.success)
const r2 = await Effect.runPromise(Effect.succeed(3).pipe(Effect.result))
console.log("result of a success:", r2._tag, r2.failure ?? r2.success)
const e1 = await Effect.runPromise(Effect.sync(() => { throw new Error("D") }).pipe(Effect.exit))
console.log("exit of a defect:", e1._tag, e1.cause.reasons.map((r) => r._tag).join(","))
const r3 = await Effect.runPromiseExit(Effect.sync(() => { throw new Error("D") }).pipe(Effect.result))
console.log("result of a defect:", r3._tag, r3.cause?.reasons.map((r) => r._tag).join(","))
```

```
result of a failure: Failure E
result of a success: Success 3
exit of a defect: Failure Die
result of a defect: Failure Die
```

**Rule.** `result` reifies the **typed** failure as a `Result` value and lets a defect keep
propagating; `exit` reifies **everything**, defects and interrupts included. The line between them is
exactly the line between beni's `Result` and report 21's `Cause`.

**For beni: same, and already shipped.** `Result e a` **is** `Effect.result`, statically, with no
combinator. The half that is missing is `exit`, and it is missing for the same reason as case 1.4:
there is no beni type that can hold a `Die` or an `Interrupt`. Decision 12 and report 21 §11.6 are
the same decision seen from two sides.

### 2.10 — case 1.10: a throw inside a finaliser, while the body succeeded

```js
import { Effect } from "effect"
const exit = await Effect.runPromiseExit(
  Effect.succeed("v").pipe(Effect.ensuring(Effect.sync(() => { throw new Error("finalizer threw") }))))
console.log("exit:", exit._tag, exit._tag === "Failure" ? exit.cause.reasons.map((r) => `${r._tag}(${r.defect?.message})`).join(",") : exit.value)
const exit2 = await Effect.runPromiseExit(Effect.gen(function* () {
  yield* Effect.addFinalizer(() => Effect.sync(() => { throw new Error("scope fin threw") }))
  yield* Effect.addFinalizer(() => Effect.sync(() => console.log("second finalizer still ran")))
  return "v"
}).pipe(Effect.scoped))
console.log("scoped exit:", exit2._tag, exit2._tag === "Failure" ? exit2.cause.reasons.map((r) => r._tag).join(",") : exit2.value)
```

```
exit: Failure Die(finalizer threw)
second finalizer still ran
scoped exit: Failure Die
```

**Rule.** A failing finaliser turns a successful effect into a failing one — **and the remaining
finalisers still run.** That second half is the important one: `scopeCloseFinalizers` keeps going
through the list and combines the causes.

**Pinned by** `test:Effect.test.ts:2372` *finalizer errors reported*, `:2429` *error in just release*.

**For beni: SILENT.** The rule beni needs is the second half: **one finaliser's failure must not
strand the rest.** That is a one-line spec sentence and an easy thing to get wrong in a first
implementation that uses a `for` loop and lets an exception out of it. Fixture: an extension of
row 18 with two finalisers, the first of which fails.

### 2.11 — case 1.11: `catchTag` — recovering from one variant of a tagged error

```js
import { Effect, Data } from "effect"
class NotFound extends Data.TaggedError("NotFound") {}
class Timeout extends Data.TaggedError("Timeout") {}
const show = async (label, eff) => { /* prints exit tag + reason tags with .error._tag */ }
const handler = (eff) => eff.pipe(Effect.catchTag("NotFound", (e) => Effect.succeed("recovered from NotFound " + e.id)))
await show("NotFound ->", handler(Effect.fail(new NotFound({ id: "7" }))))
await show("Timeout  ->", handler(Effect.fail(new Timeout())))
```

```
NotFound -> Success recovered from NotFound 7
Timeout  -> Failure Fail(Timeout)
```

**Rule.** `catchTag` narrows the error channel by a discriminant and leaves the other variants
failing, with the *type* narrowed accordingly.

**For beni: same, and free.** A `Result HttpError a` whose `HttpError` is a custom type is caught by
an ordinary exhaustive `case`, with `checker.md`'s exhaustiveness doing what `catchTag`'s
conditional types do. **This is a case where beni is simply better**, and it is worth recording:
Effect needs ten `catch*` combinators (`catchTag`, `catchTags`, `catchReason`, `catchReasons`,
`catchIf`, `catchFilter`, `catchNoSuchElement`, `catchCauseIf`, `catchCauseFilter`, `catchEager`)
because TypeScript cannot pattern-match. beni needs `case`.

---

## 3. Interruption

The densest section, and the one P2 §6.2 is written about. From here on the listings elide the
`import` line and the shared `show` helper of §1.1; everything else is verbatim.

### 3.1 — case 2.1: an effect-level loop is interruptible; one JavaScript loop is not

```js
const spin = Effect.gen(function* () { let n = 0; while (true) { n = yield* Effect.sync(() => n + 1) } })
await Effect.runPromise(Effect.gen(function* () {
  const f = yield* Effect.forkChild(spin)
  yield* Effect.sleep("30 millis")
  const t0 = Date.now()
  yield* Fiber.interrupt(f)
  console.log("effect loop: interrupt returned in", Date.now() - t0 < 50 ? "<50ms" : ">=50ms",
              "exit", (yield* Fiber.await(f)).cause.reasons.map((r) => r._tag).join(","))
}))
const t1 = Date.now()
await Effect.runPromise(Effect.gen(function* () {
  const f = yield* Effect.forkChild(Effect.sync(() => { let n = 0; while (n < 6e8) n++; return n }))
  yield* Effect.sleep("30 millis")          // cannot even be armed until the loop ends
  console.log("js loop: the 30ms sleep actually took", Date.now() - t1 > 200 ? ">200ms" : "<200ms")
  yield* Fiber.interrupt(f)
  console.log("js loop: exit", (yield* Fiber.await(f))._tag)
}))
```

```
effect loop: interrupt returned in <50ms exit Interrupt
js loop: the 30ms sleep actually took >200ms
js loop: exit Success
```

**Rule.** A fiber whose loop passes through the runtime is interruptible at every op, because the op
budget forces a yield (`effect:packages/effect/src/Scheduler.ts:184-186`). A loop *inside one
primitive* is not interruptible at all — and worse, it blocks the interruptor too: the 30 ms sleep
took over 200 ms. `test:Effect.test.ts:1823` *sync forever is interruptible*.

**For beni: same, and P2 §6.2 says it** — *"Nobody interrupts a synchronous loop"*, unanimous across
six runtimes. What P2 does not say is the **positive** half measured here: a beni loop over a
suspending call *is* interruptible, and that is a property of §7.5's budget, not of the loop. Both
halves belong in the spec, because the second is the one users will assume and the first is the one
they will be bitten by. Fixture: row 9.

### 3.2 — case 2.2: interrupting a sleeping fiber clears the timer

```js
const t0 = Date.now()
await Effect.runPromise(Effect.gen(function* () {
  const fiber = yield* Effect.forkChild(Effect.sleep("5 seconds").pipe(Effect.tap(() => Effect.sync(() => console.log("SLEEP COMPLETED (must not print)")))))
  yield* Effect.sleep("40 millis")
  yield* Fiber.interrupt(fiber)
  console.log("interrupted after", Date.now() - t0 < 500 ? "<500ms" : ">=500ms")
  console.log("exit:", (yield* Fiber.await(fiber))._tag, (yield* Fiber.await(fiber)).cause.reasons.map((r) => r._tag).join(","))
}))
console.log("process kept alive by the abandoned timer:", Date.now() - t0 > 4000)
```

```
interrupted after <500ms
exit: Failure Interrupt
process kept alive by the abandoned timer: false
```

**Rule.** A parked fiber is resumed with a failure immediately (`interruptUnsafe`,
`effect:…/effect.ts:595-616`) **and** the primitive's canceller runs, so the `setTimeout` is cleared
and the process is free to exit.

**For beni: same on the first half, silent on the second.** P2 §6.2 obligation 1 is the resume; the
cleared timer is the *canceller*, which case 2.3 shows P2 has no way to express. Fixture: row 7.

### 3.3 — case 2.3: a suspension with and without a canceller

```js
const parked = (withCanceller) =>
  Effect.callback((resume) => {
    const t = setTimeout(() => resume(Effect.succeed("late value")), 3000)
    if (withCanceller) return Effect.sync(() => { clearTimeout(t); console.log("  canceller ran, timer cleared") })
    console.log("  registered with NO canceller")
  })
for (const withCanceller of [false, true]) { /* fork, sleep 30ms, Fiber.interrupt */ }
```

```
withCanceller = false
  registered with NO canceller
  interrupt returned at <300ms exit Failure
withCanceller = true
  canceller ran, timer cleared
  interrupt returned at <300ms exit Failure
```

**Rule.** The canceller is **optional and returned by the registration**: `callback`'s register
returns an `Effect` or nothing, and the returned effect is pushed as an `asyncFinalizer` frame that
runs on interrupt only (`effect:…/effect.ts:1148-1224`, `:1200-1215`). Without one the fiber still
unwinds promptly; what is left behind is the primitive's own resource.
`test:Effect.test.ts:1992` *callback cleanup effect runs on interrupt*, `:1954` *callback cannot
resume on interrupt*.

**For beni: SILENT, and it is a `boundary.md` §4 change.** P2 §6.1 says a suspension *"is handed the
fiber's resume callback"* and stops. A `foreign suspends` primitive must be able to hand **back** a
canceller, or every timer, socket and `AbortController` beni's platform owns leaks on cancellation.
Report 21 §4.1 already recommends v4's shape — a frame, not a fiber field. The declaration form does
not change; the **protocol** does, and `boundary.md` §4's shape (b) rewrite (plan §10 item 3) is
where it lands. Fixture: row 7.

### 3.4 — case 2.4: acquire is uninterruptible

```js
const res = Effect.acquireRelease(
  Effect.sleep("60 millis").pipe(Effect.tap(() => Effect.sync(() => console.log("acquire finished")))),
  () => Effect.sync(() => console.log("release ran")))
// fork `scoped(res; log "use starts"; sleep 5s)`, then interrupt at 20ms — inside acquire
```

```
interrupting during acquire
acquire finished
release ran
exit: Failure
```

**Rule.** An interrupt delivered during `acquire` does not abandon the acquisition: the acquire runs
to completion, the resource is registered, and then the release runs — `acquireRelease` is
`uninterruptibleMask` around the acquire (`effect:…/effect.ts:4106-4122`).
`test:Effect.test.ts:1027` *acquireRelease - releases on interrupt*, `:216` *acquireUseRelease
uninterruptible*.

**For beni: same.** P2 §6.3 states it. Note what the trace shows and P2 does not: `use` never
started, so the release ran on a resource nobody used — which is correct and is why `release` needs
the `Exit` (case 4.1). Fixture: row 12.

### 3.5 — case 2.5: an interrupt inside an uninterruptible region is latched

```js
const f = yield* Effect.forkChild(Effect.gen(function* () {
  yield* Effect.uninterruptible(Effect.gen(function* () {
    console.log("uninterruptible region: start")
    yield* Effect.sleep("80 millis")
    console.log("uninterruptible region: end (ran to completion)")
  }))
  console.log("after the region (must not print)")
}))
yield* Effect.sleep("20 millis"); console.log("interrupting"); yield* Fiber.interrupt(f)
```

```
uninterruptible region: start
interrupting
uninterruptible region: end (ran to completion)
exit: Interrupt
```

**Rule.** The interrupt is recorded in `_interruptedCause` and **not acted on**; the
`setInterruptibleTrue` sentinel's `contAll` fires it the moment the region ends
(`effect:…/effect.ts:4484-4504`). The code after the region never runs.
`test:Effect.test.ts:2005` *uninterruptibleMask defers a pending interrupt until the masked region
completes*.

**For beni: SILENT — this is report 21 §11.5's `interruptedCause` field.** P2 §6.3 has the flag and
not the latch. Without the latch a `bracket` release **swallows the cancellation** and the fiber
carries on past it, which is a silently-wrong program of exactly plan §6's class. Fixture: row 11.

### 3.6 — case 2.6: `uninterruptibleMask` and `restore`

```js
const f = yield* Effect.forkChild(Effect.uninterruptibleMask((restore) =>
  Effect.gen(function* () {
    console.log("masked prologue")
    yield* restore(Effect.sleep("5 seconds").pipe(Effect.tap(() => Effect.sync(() => console.log("restored body finished (must not print)")))))
    console.log("masked epilogue (must not print)")
  }).pipe(Effect.onInterrupt(() => Effect.sync(() => console.log("onInterrupt fired"))))))
yield* Effect.sleep("30 millis"); yield* Fiber.interrupt(f)
```

```
masked prologue
onInterrupt fired
interrupt landed inside restore(): true
```

**Rule.** `restore` re-opens interruptibility *inside* an uninterruptible region
(`effect:…/effect.ts:4550-4562`), which is the only way to write `acquireUseRelease`: uninterruptible
acquire, interruptible `use`, uninterruptible release, all in one expression
(`effect:…/effect.ts:4346-4358`). `test:Effect.test.ts:2045` *delivers a pending interrupt when
restore re-enables interruptibility*, `:1897` *acquireUseRelease use inherits interrupt status*.

**For beni: SILENT, and report 21 §4.2 already flagged it.** P2 §6.3's flag alone cannot express a
bracket whose `use` is cancellable, so a long download inside a `Task.bracket` would be
uncancellable. **`restore` is not optional machinery; it is what makes `bracket` usable.** Fixture:
row 13.

### 3.7 — case 2.7: interrupting a finished fiber

```js
const f = yield* Effect.forkChild(Effect.succeed("value"))
const before = yield* Fiber.await(f)
yield* Fiber.interrupt(f)
const after = yield* Fiber.await(f)
console.log("same Exit object:", before === after)
console.log("join still yields the value:", yield* Fiber.join(f))
```

```
before: Success value
after interrupt: Success value
same Exit object: true
join still yields the value: value
```

**Rule.** `interruptUnsafe` returns immediately if `_exit` is set; a completed fiber's outcome is
immutable and shared. **For beni: SILENT, and it is one line of spec plus one guard.** It matters
because a race's loser very often finishes just as the winner cancels it, and an implementation that
overwrites the exit reports "cancelled" for work that completed. Fixture: row 10.

### 3.8 — case 2.8: `Fiber.interrupt` waits for the finalisers; `interruptUnsafe` does not

```js
const body = Effect.never.pipe(Effect.ensuring(Effect.sleep("120 millis").pipe(Effect.tap(() => Effect.sync(() => console.log("  finalizer done"))))))
// A: fork, sleep 20ms, `yield* Fiber.interrupt(f)`, log "interrupt returned"
// B: fork, sleep 20ms, `f.interruptUnsafe()`, log "interruptUnsafe returned", sleep 200ms
```

```
Fiber.interrupt:
  finalizer done
  interrupt returned
fiber.interruptUnsafe:
  interruptUnsafe returned
  finalizer done
```

**Rule.** `Fiber.interrupt` is `interruptUnsafe` **plus** `fiberAwait`
(`effect:…/effect.ts:903-931`), so it does not return until the target has fully unwound.
`fiber.interruptUnsafe()` is the fire-and-forget form — and it is the **only** one in v4:
v3's `Fiber.interruptFork` and `interruptAsFork` were deleted in favour of calling the runtime hook
directly (`effect:migration/v3-to-v4.md:11019-11021`).

**For beni: SILENT, and P2 §6.5 has picked the wrong default by omission.** `Fiber.cancel : Fiber a
-> ()` says nothing about waiting, and "cancel" that has not finished cancelling is the source of
every flaky test in this class. **Recommendation: `Fiber.cancel` waits**, and a non-waiting form is
added only if something needs it — `CLAUDE.md` rule 7's reading is that waiting is the guarantee and
not-waiting is the optimisation. Fixture: rows 19 and 22.

### 3.9 — case 2.9: what an interrupted fiber gives its joiner

```js
const f = yield* Effect.forkDetach(Effect.never)
yield* Effect.sync(() => f.interruptUnsafe())
const exit = yield* Fiber.await(f)
console.log("Fiber.await ->", exit._tag, exit.cause.reasons.map((r) => `${r._tag}(by #${r.fiberId})`).join(","))
const joined = yield* Fiber.join(f).pipe(Effect.exit)
console.log("Fiber.join  ->", joined._tag, joined.cause.reasons.map((r) => r._tag).join(","))
const caught = yield* Fiber.join(f).pipe(Effect.catchCause(() => Effect.succeed("catchCause caught it")), Effect.exit)
console.log("join + catchCause ->", caught._tag, caught.value ?? "")
```

```
Fiber.await -> Failure Interrupt(by #undefined)
Fiber.join  -> Failure Interrupt
join + catchCause -> Success catchCause caught it
```

**Rule.** `Fiber.await` hands back the `Exit` as a **value** and never fails; `Fiber.join`
**propagates** it, so the joiner dies of its child's interrupt unless it handles the `Cause`
(`effect:…/effect.ts:812-867`). The `Interrupt` reason carries the interruptor's fiber id.

**For beni: DIFFERS — §0.2 row 3 and decision 15.** P2 §6.5's `Fiber.join : Fiber a -> Result
Cancelled a` is `await` under `join`'s name. Both are needed: `await` is what a supervisor wants,
`join`'s propagation is what `Task.par2` and `Task.race` are *built from* — in v4 they are ordinary
library code over `callback` + observers (`effect:…/effect.ts:1606-1661`), and without propagation a
beni user cannot write them. Fixture: row 21.

### 3.10 — case 2.10: interrupting the parent — are children interrupted, and does the parent wait?

```js
const child = (name, ms) => Effect.never.pipe(Effect.onInterrupt(() =>
  Effect.sleep(`${ms} millis`).pipe(Effect.tap(() => Effect.sync(() => console.log("  child", name, "finalizer done"))))))
const parent = yield* Effect.forkChild(Effect.gen(function* () {
  yield* Effect.forkChild(child("A", 100)); yield* Effect.forkChild(child("B", 40)); yield* Effect.never
}).pipe(Effect.ensuring(Effect.sync(() => console.log("  parent finalizer")))))
yield* Effect.sleep("30 millis"); const t0 = Date.now(); yield* Fiber.interrupt(parent)
```

```
  parent finalizer
  child B finalizer done
  child A finalizer done
parent interrupt returned after >=100ms (waited for slowest child): true
```

**Rule.** Children **are** interrupted and the parent **does** wait for all of them — but only
**after** the parent's own continuation stack has unwound. `evaluate` runs `runLoop` to an `Exit`
first, and only then consults `fiberMiddleware.interruptChildren`
(`effect:…/effect.ts:620-656`). The children then run concurrently, so the parent's total is the
**max**, not the sum. `test:Effect.test.ts:2207` *fork is interrupted with parent*, `:2148`
*awaitAllChildren*.

**For beni: DIFFERS — §0.2 row 4.** P2 §6.2 obligation 4 says descendants are signalled *before* the
parent unwinds, and that is the ordering beni should keep: a parent finaliser that closes what a
child is using is a use-after-free that Effect's order permits. Fixture: row 23 — and it is the only
fixture in the suite that would **fail against Effect**, which is why it has to be written.

### 3.11 — case 2.11: the ordering, isolated

```js
const parent = yield* Effect.forkChild(Effect.gen(function* () {
  yield* Effect.forkChild(Effect.never.pipe(Effect.onInterrupt(() => Effect.sync(() => console.log("3. child finalizer")))))
  yield* Effect.sleep("10 millis"); yield* Effect.never
}).pipe(
  Effect.ensuring(Effect.sync(() => console.log("1. parent ensuring (inner)"))),
  Effect.ensuring(Effect.sync(() => console.log("2. parent ensuring (outer)")))))
yield* Effect.sleep("40 millis"); yield* Fiber.interrupt(parent); console.log("4. parent interrupt returned")
```

```
1. parent ensuring (inner)
2. parent ensuring (outer)
3. child finalizer
4. parent interrupt returned
```

**Rule.** Confirms 2.10 with the numbering made explicit: **every** parent finaliser, LIFO, then the
children, then the interruptor resumes.

**For beni: DIFFERS**, same as 2.10. Stated separately because the *interleaving* is the thing to
specify — not "children are interrupted" but "children are interrupted at this point in the parent's
unwind". Fixture: row 23.

### 3.12 — case 2.12: `forkChild` vs `forkDetach` vs `forkScoped`

```js
const tick = (name, n) => Effect.gen(function* () {
  for (let i = 0; i < n; i++) { yield* Effect.sleep("25 millis"); console.log("  tick", name, i) }
}).pipe(Effect.onInterrupt(() => Effect.sync(() => console.log("  interrupted", name))))
// parent forks tick("child",99) with forkChild and tick("detached",4) with forkDetach, then sleeps 60ms and exits
// then, separately: scoped { forkScoped(tick("scoped",99)); sleep 60ms }
```

```
  tick child 0
  tick detached 0
  tick child 1
  tick detached 1
  interrupted child
-- parent done --
-- runPromise resolved; the detached fiber is still alive --
  tick detached 2
  tick detached 3
-- forkScoped --
  tick scoped 0
  tick scoped 1
  leaving the scope
  interrupted scoped
```

**Rule.** Four lifetimes from one `forkUnsafe` (`effect:…/effect.ts:5454-5474`): tied to the parent
(`forkChild`), tied to nothing (`forkDetach` — it outlives even `runPromise`'s resolution and keeps
the Node process alive), tied to a named scope (`forkIn`), tied to the ambient scope
(`forkScoped`). `test:Effect.test.ts:2233` *forkDaemon is not interrupted with parent*, `:2259`
*forkIn is interrupted when scope is closed*, `:2277` *forkScoped*.

**For beni: DIFFERS — §0.2 row 5.** P2 §6.5 has two of the four. `Task.spawn` is `forkChild`,
`Scope.spawn` is `forkIn`; **`forkDetach` has no analogue** and is what a background task needs. An
earlier run of this very case hung the harness forever because the detached fiber never stopped —
which is the argument *for* naming it something unmistakable and *against* making it the default.
Fixture: row 24.

### 3.13 — case 2.13: release is uninterruptible against a second interrupt

```js
const f = yield* Effect.forkChild(Effect.scoped(Effect.gen(function* () {
  yield* Effect.acquireRelease(Effect.succeed("r"), () => Effect.gen(function* () {
    console.log("release: start"); yield* Effect.sleep("100 millis"); console.log("release: finished despite a second interrupt")
  }))
  yield* Effect.sleep("20 millis")
})))
yield* Effect.sleep("40 millis"); f.interruptUnsafe(); yield* Effect.sleep("10 millis"); f.interruptUnsafe()
```

```
release: start
release: finished despite a second interrupt
exit: Failure
```

**Rule.** A release is uninterruptible, including against an interrupt that arrives *while it is
running* — `onExitPrimitive`'s `contAll` clears `interruptible` for the duration
(`effect:…/effect.ts:4148-4153`). `test:Effect.test.ts:1968` *closing scope is uninterruptible*.

**For beni: same.** P2 §6.3 says it, and `research/16` §4.1/§4.2 records that ZIO and Cats Effect
state it as a documented guarantee. The thing to keep is the **repeat-interrupt** case, which is what
an impatient supervisor does and what a naive flag gets wrong. Fixture: row 14.

### 3.14 — case 2.14: a fiber interrupting itself

```js
const exit = await Effect.runPromiseExit(Effect.gen(function* () {
  console.log("before"); yield* Effect.interrupt; console.log("after (must not print)")
}).pipe(Effect.ensuring(Effect.sync(() => console.log("finalizer")))))
console.log("exit:", exit._tag, exit.cause.reasons.map((r) => `${r._tag}(#${r.fiberId})`).join(","))
const swallowed = await Effect.runPromiseExit(Effect.interrupt.pipe(Effect.catchCause(() => Effect.succeed("swallowed"))))
```

```
before
finalizer
exit: Failure Interrupt(#1)
catchCause over a self-interrupt: Success swallowed
```

**Rule.** `Effect.interrupt` fails the current fiber with an `Interrupt` cause naming itself, runs
the finalisers, and **is catchable**.

**For beni: SILENT, and probably not wanted as a primitive.** A beni function that wants to stop
returns an `Err`. What does have an analogue is the *fiber id* in the cause — a supervisor that
cancels a worker and later reads "interrupted by #7" is the observability story P2 §11 Q11 asks
about, at the cost of one field.

### 3.15 — case 2.15: the abandoned primitive's later resume is dropped

```js
let lateResume
const parked = Effect.callback((resume) => { lateResume = resume })
const f = yield* Effect.forkChild(parked.pipe(Effect.tap((v) => Effect.sync(() => console.log("RESUMED with", v, "(must not print)")))))
yield* Effect.sleep("20 millis"); yield* Fiber.interrupt(f)
yield* Effect.sync(() => lateResume(Effect.succeed("late")))
yield* Effect.sleep("20 millis")
```

```
exit: Interrupt
after the late resume, exit is still: Interrupt
```

**Rule.** The one-shot disarm: `evaluate` calls the `_yielded` thunk before running, which sets the
suspension's `resumed = true`, so the primitive's later call is a no-op
(`effect:…/effect.ts:620-627`, `:1174-1176`). `test:Effect.test.ts:1954` *callback cannot resume on
interrupt*.

**For beni: same.** P2 §6.2 obligation 3 and P2 §5's *one-shot*. Report 21 §11.5 says the `yielded`
field is missing from P2's record; this is the fixture that catches its absence, and the symptom
without it is a cancelled fiber running the rest of its continuation on a closed scope. Fixture:
rows 3 and 6.

### 3.16 — case 2.16: a self-interrupt is catchable, an external one is not

```js
const swallow = (eff) => eff.pipe(Effect.catchCause(() => Effect.succeed("SWALLOWED")))
console.log("self-interrupt  :", (await Effect.runPromiseExit(swallow(Effect.interrupt)))._tag)
const f = yield* Effect.forkChild(swallow(Effect.never))
yield* Effect.sleep("20 millis"); yield* Fiber.interrupt(f)
```

```
self-interrupt  : Success
external interrupt: Failure Interrupt
```

**Rule.** An **external** interrupt sets `_interruptedCause` on the fiber, and `exitFailCause` keeps
popping `contE` frames while the fiber is interrupted, so no handler can swallow it
(`effect:packages/effect/src/internal/core.ts:548-551`). A **self**-interrupt is an ordinary
`failCause` with an `Interrupt` reason and the handler catches it. Two behaviours, one word.

**For beni: SILENT, and the distinction is worth keeping without the confusion.** The rule beni
needs is the strong one — **a cancelled fiber cannot be un-cancelled by user code** — and since beni
has no `catchCause`, it gets it for free provided `Task.scope`'s and `Fiber.join`'s conversion of a
`Cause` to a value does not resurrect the fiber. That is one sentence in the spec and one easy
mistake in the implementation.

### 3.17 — case 2.17: the `AbortSignal` handed to a promise-shaped primitive

```js
const f = yield* Effect.forkChild(Effect.tryPromise({
  try: (signal) => new Promise((resolve, reject) => {
    const t = setTimeout(() => resolve("late"), 3000)
    signal.addEventListener("abort", () => { clearTimeout(t); console.log("  abort listener fired, timer cleared"); reject(new Error("aborted")) })
  }),
  catch: (e) => "mapped:" + e.message }))
yield* Effect.sleep("30 millis"); yield* Fiber.interrupt(f)
```

```
  abort listener fired, timer cleared
  interrupt returned in <300ms
  exit: Interrupt
```

**Rule.** `callback`'s register is handed an `AbortSignal` and the canceller aborts it
(`effect:…/effect.ts:1180-1187`). The rejection that follows is **discarded** — the fiber's exit is
`Interrupt`, not the mapped error — because the resume was already disarmed.
`test:Effect.test.ts:1982` *AbortSignal is aborted*, `:498` *tryPromise aborts the provided
AbortSignal on interruption*.

**For beni: same, and P2 §6.4 has the right instinct.** §6.4 keeps the `AbortController` **off** the
fiber record (753 B and 0.98 µs each) and mints one *"only at the leaf where a platform primitive
demands one"*. This case is that leaf, and it shows the shape: the `AbortController` is the
canceller's business, not the fiber's. Fixture: row 7, in the variant whose primitive is an
`AbortController`-shaped Node API.

---

## 4. Structured concurrency combinators

Listings from here are trimmed to the lines that carry the behaviour; the full scripts are
`cases/c3*.mjs`.

### 4.1 — case 3.1: `Effect.all` — default concurrency, and result order

```js
const item = (n, ms) => Effect.sleep(`${ms} millis`).pipe(Effect.tap(() => Effect.sync(() => console.log("  finished", n))), Effect.as(n))
const xs = [item("a", 60), item("b", 20), item("c", 40)]
Effect.all(xs) ; Effect.all(xs, { concurrency: "unbounded" }) ; Effect.all(xs, { concurrency: 2 })
```

```
default (no options):
  finished a / finished b / finished c      result [ 'a', 'b', 'c' ]
concurrency "unbounded":
  finished b / finished c / finished a      result [ 'a', 'b', 'c' ]
concurrency 2:
  finished b / finished a / finished c      result [ 'a', 'b', 'c' ]
```

*(the three `finished` lines were one per line in the raw output; joined here with `/` for width)*

**Rule.** **Result order is argument order under every concurrency**, and the default is
**sequential** — `concurrency` defaults to 1 in the public API, over an internal
`iterateConcurrentImpl` whose bound is a required argument (`effect:…/effect.ts:4981-5128`).
`test:Effect.test.ts:697` *tuple*, `:527`–`:575` the `forEach` concurrency family.

**For beni: same, and P2 is stricter in the right way.** `Task.parAll : Int, List (() -> a) -> List
a` makes the bound **mandatory**, so there is no default to get wrong — `research/16` §3.4's *"901
MiB is one word away from 78.6 KiB"*. What P2 does not state is the order guarantee, and it must:
*results are in argument order, completion order is unspecified.* Fixture: row 27.

### 4.2 — case 3.2: the first failure interrupts the siblings, and `all` waits for them

```js
const slow = (n) => Effect.sleep("5000 millis").pipe(Effect.as(n),
  Effect.onInterrupt(() => Effect.sleep("80 millis").pipe(Effect.tap(() => Effect.sync(() => console.log("  sibling", n, "finalizer done"))))))
Effect.all([slow("a"), Effect.sleep("30 millis").pipe(Effect.andThen(Effect.fail("boom"))), slow("c")], { concurrency: "unbounded" })
```

```
  sibling a finalizer done
  sibling c finalizer done
exit: Failure Fail(boom)
all() returned only after the siblings' finalizers (>=100ms): true
```

**Rule.** The `callback`'s canceller sets `terminal` and interrupts every live child, and
`fiberInterruptAll` **awaits** them all (`effect:…/effect.ts:934-945`). So `all` returns only when
nothing it started is still running. `test:Effect.test.ts:800` *concurrency interrupts started
siblings on failure*.

**For beni: SILENT — decision 11.** P2 §3.4 says *"the group is a scope… every fiber in the group is
cancelled and its finalisers run"* for the `and` form and says nothing for `Task.parAll`. They are
the same construct and should get the same sentence. Fixture: row 26.

### 4.3 — case 3.3: `mode: "result"`, `discard`, and `validate`

```js
const xs = [Effect.succeed(1), Effect.fail("e2"), Effect.succeed(3), Effect.fail("e4")]
Effect.all(xs, { mode: "result", concurrency: "unbounded" })
Effect.all([Effect.succeed(1), Effect.succeed(2)], { discard: true })
Effect.validate([0, 1, 2, 3], (n) => n % 2 === 0 ? Effect.fail(`${n} is even`) : Effect.succeed(n))
```

```
mode:result -> Success(1), Failure(e2), Success(3), Failure(e4)
discard     -> undefined
validate ok -> Success [2,6,10]
validate bad-> Failure Fail(["0 is even","2 is even"])
```

**Rule.** Three ways to not short-circuit: `mode: "result"` gives a `Result` per element and never
fails; `validate` runs everything and fails with a **non-empty array** of the failures; `discard`
throws the values away. `test:Effect.test.ts:751` *tuple result mode*, `:921`–`:937` the `validate`
family.

**For beni: SILENT, and P2 §11 Q4 is exactly this question** — *"should a group's items be allowed
to fail independently, so one failure cancels its siblings, or should the group collect every
result?"* Effect's answer is **both, under different names**, and that is the right answer:
`Task.parAll` short-circuits and `Task.parAllResults : Int, List (() -> Result e a) -> List (Result
e a)` does not. The second is `mode: "result"`, it costs nothing extra over the first, and it is
what a "fetch 200 URLs and tell me which failed" program needs.

### 4.4 — case 3.4: `race` waits for the loser's finaliser

```js
const loser = Effect.sleep("5 seconds").pipe(Effect.onInterrupt(() =>
  Effect.sleep("120 millis").pipe(Effect.tap(() => Effect.sync(() => console.log("  loser finalizer done"))))))
Effect.race(Effect.sleep("30 millis").pipe(Effect.as("winner")), loser)
```

```
  loser finalizer done
race -> winner
race returned after the loser's finalizer (>=140ms): true
```

**Rule.** On a win, `raceAll` resumes with
`flatMap(uninterruptible(fiberInterruptAll(fibers)), () => exit)`
(`effect:…/effect.ts:1636-1641`) — the losers are interrupted **and awaited**, uninterruptibly,
before the winner's value is delivered. `test:Effect.test.ts:1107` *race interrupts the loser when
the other side succeeds*.

**For beni: partly specified.** P2 §6.5 says *"losers cancelled, finalisers run"*; it does not say
`race` **waits**, which is the observable half and the one that makes `race` safe for resources.
Fixture: row 29.

### 4.5 — case 3.5: a failure does not end a race

```js
const failsFast = Effect.sleep("20 millis").pipe(Effect.andThen(Effect.fail("fast-failure")))
const succeedsSlow = Effect.sleep("80 millis").pipe(Effect.as("slow-success"))
race(failsFast, succeedsSlow) ; raceFirst(failsFast, succeedsSlow)
race(failsFast, failsSlowly) ; raceAll([fail e1, fail e2])
```

```
race(failFast, succeedSlow)      Success slow-success
raceFirst(failFast, succeedSlow) Failure Fail(fast-failure)
race: both fail                  Failure Fail(fast-failure) + Fail(slow-failure)
raceAll: all fail                Failure Fail(e1) + Fail(e2)
```

**Rule.** `raceAll` resumes on the first **success**; a failing branch is pushed onto a `failures`
array and the race continues, and only when `doneCount >= len` does it resume with **every** failure
combined (`effect:…/effect.ts:1629-1636`). `raceFirst`/`raceAllFirst` resume on the first
**completion**, success or failure. `test:Effect.test.ts:1145` *raceFirst interrupts the loser when
the other side fails*.

**For beni: SILENT, and this is the most surprising case in the report.** P2 §6.5 has one
`Task.race : List (() -> a) -> a` and does not say which semantics it has. Both are needed and they
are different APIs: "first success, all failures if none" is what a redundant-fetch wants; "first
answer of any kind" is what a timeout wants — and indeed v4 builds `timeoutOption` out of
`raceFirst` (`effect:…/effect.ts:3865-3886`). Fixtures: rows 30 and 31.

### 4.6 — case 3.6: `timeout` vs `timeoutOption` vs `timeoutOrElse`

```js
const slow = Effect.sleep("300 millis").pipe(Effect.as("value"))
slow.pipe(Effect.timeout("50 millis"))
slow.pipe(Effect.timeoutOption("50 millis"))
slow.pipe(Effect.timeoutOrElse({ duration: "50 millis", orElse: () => Effect.succeed("fallback") }))
```

```
timeout        -> Failure Fail TimeoutError "TimeoutError: Operation timed out after '50ms'"
timeoutOption  -> {"_id":"Option","_tag":"None"}
timeoutOption ok-> {"_id":"Option","_tag":"Some","value":"v"}
timeoutOrElse  -> fallback
TimeoutError is a typed failure, not a defect: true
```

**Rule.** Three shapes over one mechanism. `timeout` fails with a `TimeoutError` in the **typed**
channel; `timeoutOption` returns `Option`; `timeoutOrElse` substitutes.
`test:Effect.test.ts:1771` *timeout produces a useful error message*.

**For beni: DIFFERS, and P2 is right — §0.2 row 6.** `Task.timeout : Int, (() -> a) -> Maybe a` is
`timeoutOption`, and for a language whose errors are `Result` values that is the right default: a
`TimeoutError` in the error channel widens every caller's error type for a condition most callers
fold into a value with one `case`. Offer `timeoutOrElse` too — it is three lines over `timeout` — and
do not offer the loud one.

### 4.7 — case 3.7: does `timeout` return before the cleanup finishes?

```js
const body = Effect.sleep("5 seconds").pipe(Effect.onInterrupt(() =>
  Effect.sleep("200 millis").pipe(Effect.tap(() => Effect.sync(() => console.log("  cleanup finished at", Date.now() - t0, "ms"))))))
const t0 = Date.now()
const exit = await Effect.runPromiseExit(body.pipe(Effect.timeout("50 millis")))
```

```
  cleanup finished at 253 ms
timeout returned at 255 ms; exit Failure
timeout WAITED for the cleanup (>=240ms): true
```

**Rule.** **No.** A 50 ms timeout took 255 ms, because `timeout` is a race and case 4.4's rule
applies: the loser is interrupted and awaited. **`timeout d` is a bound on when the work stops, not
on when the call returns.**

**For beni: SILENT — decision 10, and the one to write down in the doc comment.** It is the most
counter-intuitive rule in the whole catalogue and the one a user will file a bug about. Fixture:
row 32.

### 4.8 — case 3.8: `forEach` with a bound

```js
let live = 0, peak = 0
const work = (n) => Effect.gen(function* () { live++; peak = Math.max(peak, live); yield* Effect.sleep(...); live--; return n * 10 })
Effect.forEach(items, work, { concurrency: 3 }) ; { concurrency: "unbounded" } ; (no options)
```

```
concurrency 3 -> [0,10,20,30,40,50,60,70] peak 3
unbounded     -> [0,10,20,30,40,50,60,70] peak 8
default       -> [0,10,20,30,40,50,60,70] peak 1
```

**Rule.** The bound is a real bound: `iterateConcurrentImpl` sets `paused = true` at the limit and an
observer unpauses it (`effect:…/effect.ts:5081-5095`). Results are in input order in all three.

**For beni: same.** P2 §6.5's mandatory `Int` and `research/16` §5.3 row 5. Fixture: row 28.

### 4.9 — case 3.9: `Effect.disconnect` does not exist in v4

```js
console.log("Effect.disconnect is", typeof Effect.disconnect)
console.log("v3 names still present:", JSON.stringify(Object.keys(Effect).filter((k) => /disconnect|daemon|forkAll|forkWithErrorHandler/i.test(k))))
```

```
Effect.disconnect is undefined
Effect.forkDetach  is function
v3 names still present: []
```

**Rule.** v3's `disconnect` — "let this effect be interrupted in the background rather than blocking
its interruptor" — was **removed**, along with `forkDaemon`, `forkAll` and `forkWithErrorHandler`
(`effect:migration/forking.md:8-15`). Its job is done by `forkDetach` plus an explicit join.

**For beni: informational, and it is evidence for decision 11.** The gold standard removed the
escape hatch that lets a combinator *not* wait for its children. That is a point for "wait, always",
with `Task.spawnDetached` as the one explicit way out.

### 4.10 — case 3.10: a timeout around an uninterruptible region

```js
Effect.uninterruptible(Effect.sleep("250 millis").pipe(Effect.as("v"))).pipe(Effect.timeout("40 millis"))
```

```
exit: Failure TimeoutError
returned at >=240ms (waited for the whole body)
```

**Rule.** The timeout **fires** — the result is a `TimeoutError` — but it cannot take effect until
the region ends, so the call returns after 250 ms, not 40 ms. `test:Effect.test.ts:1763` *timeout in
uninterruptible region*.

**For beni: SILENT, and `CLAUDE.md` rule 7 says the sentence has to be written.** "`Task.timeout 40`
is a request delivered at the next interruption point; a `bracket`'s acquire or release has none"
is a guarantee stated honestly. Saying nothing, and letting users infer a hard 40 ms bound, is the
failure mode. Fixture: row 33.

### 4.11 — case 3.11: `raceAll` vs `raceAllFirst`

```js
const fastFail = Effect.sleep("20 millis").pipe(Effect.andThen(Effect.fail("fast-failure")))
raceAll([fastFail, slowOk, slowerOk]) ; raceAllFirst([fastFail, slowOk, slowerOk])
```

```
raceAll      Success slow-ok
raceAllFirst Failure Fail(fast-failure)
```

**Rule.** The two-name split of case 4.5, generalised to n branches. `raceAll` is "the first one that
works"; `raceAllFirst` is "the first one that finishes".

**For beni: SILENT.** One name cannot cover both. Recommendation: `Task.race` = `raceAll` (first
success, every failure if none succeeds), and `Task.raceFirst` only if something needs it — because
`Task.timeout` is the one caller that does, and it can be written against the runtime directly.

### 4.12 — case 3.12: sequential `all` never starts the later items

```js
const item = (n, eff) => Effect.sync(() => console.log("  starting", n)).pipe(Effect.andThen(eff))
Effect.all([item("a", succeed 1), item("b", fail "boom"), item("c", succeed 3)])
```

```
  starting a
  starting b
exit: Failure Fail(boom)
```

**Rule.** With the default (sequential) concurrency, a failure means the remaining items are never
evaluated at all — there is nothing to cancel because nothing was started.

**For beni: same, by P2 §5's source order.** Worth a fixture because the *thunk* discipline is what
makes it true: `Task.parAll` takes `List (() -> a)`, and an implementation that evaluated the list
eagerly would start everything. Covered by row 27's negative half.

---

## 5. Resources and scopes

### 5.1 — case 4.1: the release is handed the `Exit`

```js
const bracket = (use) => Effect.acquireUseRelease(
  Effect.sync(() => { console.log("  acquire"); return "R" }), () => use,
  (r, exit) => Effect.sync(() => console.log("  release sees", exit._tag, exit._tag === "Failure" ? exit.cause.reasons.map((x) => x._tag).join(",") : exit.value)))
// run with use = succeed("v") / fail("E") / throw / never-then-interrupt
```

```
success:   acquire / release sees Success v
failure:   acquire / release sees Failure Fail
defect :   acquire / release sees Failure Die
interrupt: acquire / release sees Failure Interrupt
```

**Rule.** The release's second parameter is the `Exit` of `use`, and it distinguishes all four
outcomes (`effect:…/effect.ts:4346-4358`). `test:Effect.test.ts:2406` *acquireUseRelease usage
result*, `:1917` *release runs when use is interrupted*.

**For beni: DIFFERS — §0.2 row 1, and it is a type change.** P2 §6.5's `Task.bracket : (() -> r), (r
-> ()), (r -> a) -> a` gives the release only the resource. A transaction that must commit on success
and roll back otherwise cannot be written. The replacement type depends on decision 12 — with report
21 §11.6(a) it is `(r, Outcome a -> ())` where `Outcome` is the beni-visible projection of a `Cause`.
**This is the single cheapest correction in the report and the most expensive one to defer.**
Fixture: row 16.

### 5.2 — case 4.2: a scope's finaliser execution strategy

```js
const fin = (name, ms) => Effect.sleep(`${ms} millis`).pipe(Effect.tap(() => Effect.sync(() => console.log("  done", name, "at", Date.now() - t0, "ms"))))
const scope = yield* Scope.make(strategy)   // "sequential" | "parallel"
// three 80ms finalizers A, B, C added, then Scope.close
```

```
sequential:  done C at 84 ms / done B at 165 ms / done A at 245 ms   total >=200ms
parallel:    done C at 80 ms / done B at 81 ms / done A at 81 ms     total <200ms
```

**Rule.** `Scope.make(strategy)` chooses; the default is `"sequential"`
(`effect:…/effect.ts:4050-4055`), and LIFO holds in both (C, B, A). `test:Scope.test.ts:7` *parallel
finalization - executes finalizers in parallel*.

**For beni: SILENT.** Sequential-LIFO is the right default because finalisers often depend on each
other (close the statement before the connection). Whether the parallel strategy is worth a knob is
an open question; **the default must be stated**, because a first implementation might use
`Task.parAll` over the list and silently change the meaning.

### 5.3 — case 4.3: `addFinalizer` on an already-closed scope

```js
const scope = yield* Scope.make()
yield* Scope.addFinalizer(scope, Effect.sync(() => console.log("  first finalizer ran")))
yield* Scope.close(scope, Exit.void)
yield* Scope.addFinalizer(scope, Effect.sync(() => console.log("  late finalizer ran")))
```

```
  first finalizer ran
  scope closed
  late finalizer ran
  addFinalizer after close did not throw
```

**Rule.** Registering on a closed scope **runs the finaliser immediately** rather than failing or
silently dropping it — the `Closed` state's `addFinalizer` executes it with the scope's exit. No test
in v4's suite pins this.

**For beni: SILENT, and it is a correctness rule disguised as an edge case.** The alternative —
dropping it — leaks a resource acquired in a race with the scope's close, which is exactly what
happens when an `acquire` completes just as the block exits. One sentence, one guard. Worth a
fixture only once `Task.scope` exists.

### 5.4 — case 4.4: one scope shared across fibers

```js
const scope = yield* Scope.make()
yield* Effect.forkIn(tick("in-scope"), scope) ; yield* Effect.forkIn(tick("also-in-scope"), scope)
yield* Effect.sleep("60 millis") ; yield* Scope.close(scope, Exit.void)
```

```
  tick in-scope 0 / tick also-in-scope 0 / tick in-scope 1 / tick also-in-scope 1
  closing the scope
  interrupted also-in-scope
  interrupted in-scope
  Scope.close returned
```

**Rule.** `forkIn` registers a scope finaliser that interrupts the fiber, **removed by an observer
when the fiber completes on its own** so a long-lived scope does not accumulate dead entries
(`effect:…/effect.ts:5560`, `:5648`). Close interrupts in LIFO order and waits.

**For beni: same.** P2 §6.5's `Scope.spawn : Scope, (() -> b) -> Fiber b` is this. The half to
specify is the **removal**: a scope that never forgets a completed child leaks one entry per task,
which is `research/16` §5.3 row 10's obligation in a second place. Fixture: row 22.

### 5.5 — case 4.5: a service-scoped resource

```js
class Conn extends Context.Service()("Conn") {}
const layer = Layer.effect(Conn)(Effect.acquireRelease(
  Effect.sync(() => { console.log("  open connection"); return { q: () => "rows" } }),
  () => Effect.sync(() => console.log("  close connection"))))
Effect.gen(function* () { const c = yield* Conn; console.log("  query ->", c.q()) }).pipe(Effect.provide(layer))
```

```
  open connection
  query -> rows
  close connection
  program done
```

**Rule.** A `Layer` built from an `acquireRelease` releases when the scope that built it closes;
`Effect.provide` at the root ties that to the program's lifetime.

**For beni: out of scope, and deliberately.** Report 21 §7.3 and P2 §9.3 both say beni should not
build a `Context`; the beni equivalent is a capability record threaded as an argument, acquired by a
`Task.bracket` at the root. **The pattern transfers and the machinery does not** — which is worth
one sentence in the spec so nobody builds a `Layer`.

### 5.6 — case 4.6: nested scopes

```js
Effect.scoped(gen {
  acquireRelease("OUTER"); Effect.scoped(gen { acquireRelease("INNER"); log "inner block body" }); log "back in the outer block" })
```

```
  acquire OUTER / acquire INNER / inner block body / release INNER / back in the outer block / release OUTER / outer block left
```

**Rule.** A scope's lifetime is its block, and nesting composes.

**For beni: same, and it is P2 §3.5's headline shape** — `let scope <- Task.scope` and
`let conn <- Task.bracket …` sitting flat at the top of a block, with the block *being* the extent.
Fixture: row 17.

---

## 6. Retry, repeat, schedule, and virtual time

### 6.1 — case 5.1: `retry` with a schedule

```js
let n = 0
const flaky = Effect.suspend(() => { n++; console.log("  attempt", n); return n < 4 ? Effect.fail("no") : Effect.succeed("yes") })
flaky.pipe(Effect.retry(Schedule.recurs(5))) ; Schedule.recurs(1) ; Schedule.exponential("20 millis")
```

```
  attempt 1 / attempt 2 / attempt 3 / attempt 4       recurs(5): yes attempts 4
  attempt 1 / attempt 2                               recurs(1): Failure no attempts 2
exponential(20ms): 3 retries took >=130ms (20+40+80)
```

**Rule.** `recurs(n)` means *n retries*, so the effect runs at most n+1 times; when the schedule is
exhausted the **last** failure is returned. `test:Effect.test.ts:1390` *retry/schedule - retries
according to the specified schedule*.

**For beni: DIFFERS — §0.2 row 2.** `Task.retry : Int, (() -> Result x a) -> Result x a` has no
backoff. The minimum viable replacement is a small schedule vocabulary — `Schedule.recurs`,
`Schedule.spaced`, `Schedule.exponential`, `Schedule.jittered`, `Schedule.upTo` — which is ordinary
beni over `Task.sleep` and needs nothing from the runtime. Fixture: row 34.

### 6.2 — case 5.2: `retry` does not retry a defect or an interrupt

```js
let d = 0 ; const dies = Effect.sync(() => { d++; throw new Error("defect") })
dies.pipe(Effect.retry(Schedule.recurs(5)))
let i = 0 ; const body = Effect.suspend(() => { i++; return Effect.never })
// fork body.pipe(Effect.retry(Schedule.forever)), sleep 30ms, interrupt
```

```
defect: exit Failure Die attempts 1
interrupt: exit Interrupt attempts 1
```

**Rule.** `retry` is `retryOrElse`, which is built on `effect.catch_`
(`effect:packages/effect/src/internal/schedule.ts:66-79`) — and `catch_` sees only `Fail` reasons.
Defects and interrupts walk straight past. No test pins this directly; it falls out of the
implementation.

**For beni: same, and by construction — a point for P2.** `Task.retry`'s argument is
`() -> Result x a`, so the only thing it can see is an `Err`; a defect is not a `Result` and an
interrupt is not a value. **beni gets for free the behaviour Effect had to build a three-channel
`Cause` to get.** Worth saying out loud in the spec, because "retry forever" plus "interrupt is
retryable" is an unkillable fiber. Fixture: row 35.

### 6.3 — case 5.3: `repeat`, and the `while`/`until` predicates

```js
Effect.sync(() => ++n).pipe(Effect.repeat(Schedule.recurs(3)))
Effect.sync(() => ++n).pipe(Effect.repeat({ times: 3 }))
Effect.sync(() => ++n).pipe(Effect.repeat({ until: (x) => x >= 3 }))
flaky.pipe(Effect.retry({ until: (err) => err >= 3 }))
```

```
repeat(recurs(3)) -> 3 runs 4
repeat({times:3}) -> 4 runs 4
repeat until      -> 3 runs 3
retry until err>=3-> Failure 3 attempts 3
```

**Rule.** `repeat` runs the effect **once and then repeats**, so `recurs(3)` is four runs; its result
is the *schedule's* output for `Schedule.recurs` and the *effect's* last value for `{ times }`. The
inconsistency in that first column — `3` against `4` — is a wart (§10).
`test:Effect.test.ts:1261` *repeat/schedule*, `:1178` *repeat/until*.

**For beni: SILENT.** `repeat` is worth having (polling, heartbeats) and the return value should be
the **effect's** last value, always: the schedule's output is an implementation detail no caller
asked for.

### 6.4 — case 5.4: schedule composition in v4

```js
console.log("v3 names present:", ["both","either","andThen","intersect","union"].filter((k) => k in Schedule))
const cap = (s, times) => Schedule.upTo(s, { times })
// print the observed inter-run gaps, rounded to 10ms, for each composed schedule
```

```
v3 names present: []
spaced(40)        x3  [0,40,40,40]
exponential(20)   x3  [0,20,40,80]
fibonacci(20)     x4  [0,20,40,60,100]
max(sp20, sp60)   x3  [0,60,60,60]
min(sp20, sp60)   x3  [0,20,20,20]
jittered(sp40)    x3  [0,40,30,40]
concat(recurs1,sp50)  [0,0,50,50,50]
```

**Rule.** **v4's composition vocabulary is `concat`, `concatResult`, `max`, `min`, `upTo`,
`addDelay`, `modifyDelay`, `jittered`, `passthrough`, `tap`, `map`** — v3's `both`/`either`/
`andThen`/`intersect`/`union` are all gone (`effect:packages/effect/src/Schedule.ts`). `max` takes an
**array** of schedules and yields the slowest delay; `min` the fastest; `upTo` bounds by `{ duration,
times }`. `test:Schedule.test.ts:84` *concat*, `:21`/`:51` *max*/*min*, `:450` *jittered keeps delays
within 80%-120%*.

**For beni: SILENT, and the vocabulary is a `core/` decision, not a runtime one.** Every schedule
above is a pure function from an attempt number to a delay — no fiber state, no scheduler hook — so
this is a beni module over `Task.sleep` and belongs in the spec as a library, written after the
kernel. The one that must not be omitted is `jittered`.

### 6.5 — case 5.5: `TestClock` — virtual time makes a ten-hour schedule a microsecond test

```js
import { TestClock } from "effect/testing"
const flaky = Effect.suspend(() => { n++; log.push("attempt " + n); return n < 4 ? Effect.fail("no") : Effect.succeed("ok") })
const program = Effect.gen(function* () {
  const f = yield* Effect.forkChild(flaky.pipe(Effect.retry(Schedule.exponential("1 hour"))))
  yield* TestClock.adjust("10 hours")
  return yield* Fiber.join(f)
})
await Effect.runPromise(program.pipe(Effect.provide(TestClock.layer())))
```

```
result: ok
log: ["attempt 1","attempt 2","attempt 3","attempt 4"]
wall-clock elapsed < 200ms: true
```

**Rule.** The `Clock` is a service the fiber reads; `TestClock` replaces it with one whose time only
moves when `TestClock.adjust` is called, releasing every sleeper whose deadline has passed
(`effect:packages/effect/src/testing/TestClock.ts`). `@effect/vitest`'s `it.effect` installs it by
default and `it.live` opts out (`references/effect/packages/vitest/src/index.ts:113-167`);
`test:TestClock.test.ts:8` *sleep - does not require passage of wall time*.

**For beni: SILENT — decision 13, and it is what makes half of §0.3's suite writable.** beni's corpus
is golden-output and runs four times under the determinism test; a fixture that really sleeps for
three seconds is three seconds × four. What beni needs is smaller than Effect's: a **clock on the
fiber**, inherited on fork, read by `Task.sleep` and `Task.timeout`, and one platform-level way to
install a deterministic one. That is one more slot on the record beside report 21 §7.3's three.

### 6.6 — case 5.6: a timeout under virtual time

```js
const f = yield* Effect.forkChild(Effect.sleep("30 seconds").pipe(Effect.timeout("10 seconds"), Effect.exit))
yield* TestClock.adjust("5 seconds") ; console.log("after 5 virtual seconds, done?", f.pollUnsafe() !== undefined)
yield* TestClock.adjust("6 seconds") ; const exit = yield* Fiber.join(f)
```

```
after 5 virtual seconds, done? false
after 11 virtual seconds: Failure TimeoutError
```

**Rule.** Nothing happens until time is advanced, and then exactly the right thing does. This is the
shape a beni fixture for `Task.timeout` would take.

**For beni: SILENT — decision 13.** Note what it buys the corpus specifically: the golden is
`after 5: pending` / `after 11: timed out`, which is an **order**, not a duration, so it satisfies
§0.3's release-stability and determinism constraints.

---

## 7. Coordination primitives under cancellation

Twelve cases, **eleven silences**. P2 §6.5 names `Semaphore.with`, `Queue.take`, `Queue.put` and
`RateLimiter.with` and specifies the behaviour of none of them.

### 7.1 — case 6.1: `Deferred` — completing twice, and an interrupted waiter

```js
const d = yield* Deferred.make()
console.log("first done  ->", yield* Deferred.done(d, Effect.succeed("first")))
console.log("second done ->", yield* Deferred.done(d, Effect.succeed("second")))
console.log("value       ->", yield* Deferred.await(d))
// then: two waiters, interrupt w1, complete d, observe w2
```

```
first done  -> true
second done -> false
value       -> first
  w1 interrupted
  w2 got value
  w1 exit: Interrupt
```

**Rule.** Completion is **once**, and the second attempt returns `false` rather than failing. An
interrupted waiter is removed from the observer set by the canceller the suspension returned, and the
remaining waiters are unaffected. `test:Deferred.test.ts:18` *complete - should memoize the result*,
`:102` *await - interrupting a suspended waiter removes it*, `:121` *interrupting a waiter after
completion does not die*.

**For beni: SILENT on `Deferred` itself, specified on the removal.** `research/16` §5.3 row 10 is the
removal obligation and P2 §6.5 repeats it for `Queue`. A `Deferred` is the natural beni primitive for
"one value, many waiters" and is about 30 lines over the kernel — worth having because `Fiber.join`,
`Latch` and `Queue` are all it in disguise.

### 7.2 — case 6.2: `Queue` — bounded backpressure, dropping, sliding

```js
const q = yield* Queue.bounded(2)   // producer offers 1,2,3,4; consumer takes after 30ms
const d = yield* Queue.dropping(2), s = yield* Queue.sliding(2)   // both offered 1,2,3
```

```
  offered 1 / offered 2 / (producer is parked on a full queue)
  offered 3 / take -> 1 / offered 4 / take -> 2 3 4
dropping keeps the OLDEST: [ 1, 2 ]
sliding  keeps the NEWEST: [ 2, 3 ]
```

**Rule.** Three overflow policies: block the producer, drop the new value, evict the oldest.
`test:Queue.test.ts:51` *bounded offerAll waits until capacity is released*, `:198` *offer dropping*,
`:208` *offer sliding*.

**For beni: SILENT.** P2 §6.5 has `Queue.take`/`Queue.put` and no constructor, so it has not chosen a
policy. All three are needed and they are the same data structure with three `offer`s. Fixture:
row 37.

### 7.3 — case 6.3: interrupt a blocked taker, then offer

```js
const q = yield* Queue.bounded(10)
const t1 = yield* Effect.forkChild(Queue.take(q)) ; const t2 = yield* Effect.forkChild(Queue.take(q))
yield* Effect.sleep("20 millis") ; yield* Fiber.interrupt(t1)
yield* Queue.offer(q, "A") ; yield* Fiber.await(t2) ; yield* Queue.offer(q, "B")
```

```
  t1 interrupted
  t2 took A
  queue size after: 0
  a later take still works: B
```

**Rule.** The cancelled taker is removed from the waiter list, so the next value goes to a **live**
waiter and is not handed to a dead one. `test:Queue.test.ts:239` *take can be interrupted without
losing offers*.

**For beni: same — `research/16` §5.3 row 10 and P2 §6.5's third obligation.** This is *the* fixture
the obligation was written for and it is the one that proves the suspension primitive returns a
canceller (case 2.3). Fixture: row 36.

### 7.4 — case 6.4: `Semaphore` — permits are not leaked

```js
const sem = yield* Semaphore.make(1)
// a holder takes the permit; three waiters queue; all three are interrupted; the holder is interrupted
const got = yield* sem.withPermits(1)(Effect.succeed("acquired after the leak test")).pipe(Effect.timeoutOption("200 millis"))
// separately: withPermits over an effect that FAILS, then acquire again
```

```
  3 waiters interrupted
  {"_id":"Option","_tag":"Some","value":"acquired after the leak test"}
  {"_id":"Option","_tag":"Some","value":"permit was released on failure"}
```

**Rule.** `withPermits` releases on **every** exit — success, failure, interrupt — and an interrupted
*waiter* is removed without ever having taken a permit
(`effect:packages/effect/src/Semaphore.ts:207-223`). `test:Semaphore.test.ts:189` *interruption
releases permits*, `:257` *take interruption does not leak permits*, `:308`/`:335`/`:386` the
`withPermits` family.

**For beni: same, and the mechanism is one mechanism.** Report 21 §5.6's finding — the canceller
returned by the suspension primitive discharges the removal obligation for `Semaphore`, `Latch`,
`Deferred`, `Queue` and `Fiber.await` alike — is what makes this one fixture cover five primitives.
Fixture: row 38.

### 7.5 — case 6.5: `Queue` shutdown versus end

```js
// A: a parked taker, then Queue.shutdown; then an offer
// B: one buffered value, then Queue.end; then two takes and an offer
```

```
shutdown: parked taker -> Failure Interrupt(undefined)
shutdown: later offer  -> false
end: buffered value drains -> Success "buffered"
end: the next take         -> Failure Fail(Done)
end: a later offer         -> false
```

**Rule.** Two different closes. `shutdown` **interrupts** parked takers and discards the buffer;
`end` lets the buffer drain and then fails takers with `Cause.Done`, a distinguished *typed* failure
(`effect:packages/effect/src/Queue.ts:1005`). Both make later offers return `false`.
`test:Queue.test.ts:382` *shutdown*, `:428` *end preserves Done for take*.

**For beni: SILENT, and `Done` is the interesting part.** A producer/consumer program needs
"there will be no more values" as a **value**, not a cancellation — which in beni is naturally
`Queue.take : Queue a -> Maybe a` or a `Result QueueClosed a`. That is a better answer than
Effect's distinguished error and it should be the one beni picks.

### 7.6 — case 6.6: `Latch`

```js
const latch = yield* Latch.make(false)
// two waiters; interrupt a; latch.open; observe b; latch.close; a third waiter parks
```

```
  waiter a interrupted
  latch.open -> true
  waiter b released
  latch.close -> true
  after close, waiter c is parked: true
  waiter a exit: Interrupt
```

**Rule.** `open` releases every current waiter and returns whether it changed state; `close` re-arms
it, and waiters registered after the close park again. An interrupted waiter is spliced out
(`effect:…/effect.ts:5818-5823`). `test:Latch.test.ts:6` *release wakes current waiters and keeps the
latch closed*, `:192` *await is interruptible and cleans up interrupted waiters*.

**For beni: SILENT.** A `Latch` is a `Deferred` that can be reset, ~40 lines, and it is what a
"pause the pipeline" control is. Low priority for v1; the removal obligation it shares with §7.1 and
§7.4 is not.

### 7.7 — case 6.7: `PubSub` — backpressure and unsubscribing by scope

```js
const hub = yield* PubSub.bounded(2) ; const scope = yield* Scope.make()
const sub = yield* Scope.provide(PubSub.subscribe(hub), scope)
// a publisher offers 1..4; the subscriber takes one after 30ms; then the scope is closed
```

```
  published 1 / published 2 / (publisher is backpressured by the slow subscriber)
  published 3 / subscriber takes 1 / published 4 / publisher finished
  subscription scope closed
  publisher exit: Success
```

**Rule.** A bounded `PubSub` backpressures the **publisher** on its slowest subscriber, and a
subscription's lifetime is a `Scope` — leaving the scope unsubscribes, which is what unblocks a
publisher stuck behind a dead consumer. `test:PubSub.test.ts:187` *backpressured concurrent
publishers and subscribers*, `:654` *shutdown interrupts suspended subscribers*.

**For beni: SILENT, and the transferable idea is the scope, not the `PubSub`.** "A subscription is a
resource and its extent is a block" is `Task.bracket` applied to a subscription, and it is how
`boundary.md` §5.4's subscriptions should be shaped whenever the browser platform arrives.

### 7.8 — case 6.8: `Ref.modify` atomicity and an interrupted `SynchronizedRef` update

```js
const r = yield* Ref.make(0)
yield* Effect.forEach([...Array(200).keys()], () => Ref.update(r, (n) => n + 1), { concurrency: "unbounded" })
// then: SynchronizedRef whose effectful update sleeps 300ms, interrupted at 30ms
```

```
Ref after 200 concurrent updates: 200
Ref.modify returns a result   : was 200 now 400
SynchronizedRef after an interrupted update: initial
a later update still works                : later
```

**Rule.** `Ref` is a plain mutable cell and `modify` is atomic because JavaScript is single-threaded
and the function is pure — no lock. `SynchronizedRef` serialises **effectful** updates behind a
semaphore; an interrupted update leaves the old value and **releases the lock**, so the next update
is not deadlocked. `test:Ref.test.ts:152` *modify returns a result*,
`test:SynchronizedRef.test.ts:92` *getAndUpdateSomeEffect - interrupt parent fiber and update*.

**For beni: not applicable, and that is the finding.** beni has no mutable references and should not
grow them for effects: the state a fiber needs is its parameters, and the state fibers share is a
`Queue` or a `Deferred`. The half that *does* transfer is the `SynchronizedRef` rule — **an
interrupted critical section must release its lock** — which is case 7.4's `withPermits` obligation
under another name.

### 7.9 — case 6.9: `FiberSet` — auto-removal and scope-bound interruption

```js
const set = yield* FiberSet.make()   // inside Effect.scoped
// three fibers: two sleep 20ms, one is Effect.never with an onInterrupt
```

```
  size with 3 running  : 3
  size after 2 finished: 1
  leaving the scope
  long fiber interrupted
  scope left
```

**Rule.** A completed fiber removes itself from the set, and closing the scope interrupts whatever is
left. `test:FiberSet.test.ts:13` *interrupts running fibers when the scope closes*.

**For beni: SILENT, and P2 §6.4 already has the data structure** — `children : ?Set(*Fiber)` on the
fiber record with *"the block cannot exit until these are empty"*. A `FiberSet` is that set made
addressable. The auto-removal is the same obligation as case 5.4's `forkIn`: without it a long-lived
scope grows one entry per completed task.

### 7.10 — case 6.10: `Cache` — N concurrent gets, one lookup

```js
const cache = yield* Cache.make({ capacity: 16, lookup: (k) => Effect.sleep("40 millis").pipe(Effect.as(`v(${k})`), tap(count)) })
yield* Effect.all([Cache.get(cache, "k"), Cache.get(cache, "k"), Cache.get(cache, "k")], { concurrency: "unbounded" })
// then: two requesters, interrupt the FIRST, see what the second gets
```

```
3 concurrent gets -> [ 'v(k)', 'v(k)', 'v(k)' ] lookups: 1
first requester interrupted; second gets: {"_id":"Option","_tag":"Some","value":"late"}
```

**Rule.** Lookups are de-duplicated per key, and **interrupting one requester does not interrupt the
lookup** while another is still waiting; the computation is owned by the cache, not by the first
caller. `test:Cache.test.ts:270` *multiple fibers getting same key only invoke lookup once*, `:315`
*interrupting the first consumer does not interrupt the second*, `:342` *interrupting the last
consumer interrupts the lookup*.

**For beni: SILENT, and the rule is subtle enough to be worth writing even if `Cache` is never
built.** "Shared work is cancelled when the **last** interested party goes away, not the first" is
the correct rule for any de-duplicating construct, and the naive implementation — the first caller
owns the fiber — gets it exactly wrong.

### 7.11 — case 6.11: `Pool`

```js
const pool = yield* Pool.make({ acquire: Effect.acquireRelease(makeItem, releaseItem), size: 2 })
yield* Effect.all([use(1), use(2), use(3), use(4)], { concurrency: "unbounded" })
```

```
  task 1 got item 1 / task 2 got item 2 / task 3 got item 1 / task 4 got item 2
  items created for 4 tasks with size 2: 2
  leaving the pool scope
  released item 1 / released item 2
```

**Rule.** Two items serve four tasks; each `Pool.get` is scoped, so the item returns to the pool when
the block ends; the items themselves are released when the **pool's** scope closes.
`test:Pool.test.ts:186` *max pool size*, `:598` *interrupts pending gets without leaking usage*,
`:671` *use releases the item on interruption*.

**For beni: SILENT, and it is a library over `Semaphore` + `Queue` + `Scope`.** P2 §6.5's
`RateLimiter.with` is the same shape (a bounded resource, acquired for a block); a `Pool` is a
`RateLimiter` whose permits carry a value. One construct, two names — worth noticing before both are
written.

### 7.12 — case 6.12: memoising one effect for many callers

```js
const memo = yield* Effect.cached(Effect.sleep("60 millis").pipe(tap(count), Effect.as("v")))
yield* Effect.all([memo, memo, memo], { concurrency: "unbounded" })
// then: an owner and a waiter; interrupt the waiter; join the owner
```

```
3 concurrent callers -> [ 'v', 'v', 'v' ] runs 1
owner after the waiter was interrupted -> v runs 1
```

**Rule.** Case 7.10's rule with one key. `test:Effect.test.ts:3704` *cached runs the effect once for
concurrent callers*, `:3735` *interrupting a waiter leaves the owner running*, `:3757` *replays the
owner's interrupted exit*.

**For beni: SILENT, and P2 §2 has a stake in it.** P2's `impure` bit exists so the optimiser knows
what may be *memoised*; this is memoisation at **run** time, of a suspending call, and it is where
`impure`'s rule ("never memoised") meets a user who explicitly asks for it. They do not conflict —
the user's memo is a data structure, not an optimisation — but the spec should say so.

---

## 8. Streams, minimally

Six cases, enough to state what committing to streams would commit beni to. **P2 has no streams**, so
every case is silent and decision 16 is whether that changes.

### 8.1 — case 7.1: pull-based, and `take(2)` stops the producer

```js
const source = Stream.fromIterable([1, 2, 3, 4, 5]).pipe(
  Stream.tap((n) => Effect.sync(() => console.log("  produced", n))),
  Stream.ensuring(Effect.sync(() => console.log("  source finalizer"))))
source.pipe(Stream.take(2), Stream.runCollect) ; source.pipe(Stream.take(0), Stream.runCollect)
```

```
  produced 1
  produced 2
  source finalizer
runCollect of take(2) -> [ 1, 2 ]
runCollect of take(0) -> []
```

**Rule.** Elements 3–5 are never produced, and the finaliser runs at the point the consumer stops.
`take(0)` produces nothing at all — the source is not even started.
`test:Stream.test.ts:790` *take - short-circuits stream evaluation*, `:800` *taking 0
short-circuits*.

**For beni: SILENT, and this is the commitment.** "Pull-based" is the whole contract: a stream is a
function the consumer drives, so laziness and early termination are the same property. A `List`-based
"stream" in beni would produce all five.

### 8.2 — case 7.2: interruption mid-element

```js
const slow = Stream.fromIterable([1,2,3]).pipe(
  Stream.mapEffect((n) => Effect.sleep("60 millis").pipe(Effect.as(n), Effect.onInterrupt(...))),
  Stream.tap(log), Stream.ensuring(log))
// drain it in a fiber, interrupt at 90ms
```

```
  emitted 1
  element 2 interrupted
  stream finalizer
  exit: Interrupt
```

**Rule.** The in-flight element's effect is cancelled where it stands, and the stream's finalisers
then run — a stream is a fiber with a `Scope`, so §3's rules apply unchanged.
`test:Stream.test.ts:2788` *debounce should interrupt fibers properly*.

**For beni: SILENT.** Nothing new is required: if the kernel is right, this behaviour is inherited.

### 8.3 — case 7.3: `buffer` decouples producer from consumer

```js
const src = Stream.fromIterable([1..6]).pipe(Stream.mapEffect((n) => Effect.sleep("10 millis").pipe(record(n), Effect.as(n))))
const consume = (s) => s.pipe(Stream.runForEach(() => Effect.sleep("40 millis")))
consume(src) ; consume(src.pipe(Stream.buffer({ capacity: 8 })))
```

```
unbuffered: produced within 100ms -> [1,2]
buffered  : produced within 100ms -> [1,2,3,4,5,6]
```

**Rule.** Without a buffer the producer runs in lockstep with the consumer; with one it runs ahead by
up to `capacity` and then blocks. `test:Stream.test.ts:1709` *buffer - fast producer progresses
independently*.

**For beni: SILENT.** The buffer is a `Queue`, which the kernel already needs. Worth recording that
the **bound is mandatory** here too, for `research/16` §3.4's reason.

### 8.4 — case 7.4: `flatMap` with concurrency, and a failing inner stream

```js
Stream.fromIterable([1,2,3]).pipe(Stream.flatMap(inner, { concurrency: 3 }), Stream.runCollect)
// inner(2) fails at 30ms; inner(1) and inner(3) would take 300ms
```

```
  inner 1 interrupted
  inner 3 interrupted
exit: Failure Fail(inner 2 failed)
```

**Rule.** Case 4.2's rule, applied per element: a failing inner stream interrupts its siblings and
the outer fails. `test:Stream.test.ts:1487` *interrupts all inner streams when the outer fails at the
concurrency limit*.

**For beni: SILENT**, and again inherited from `Task.parAll`'s decision 11.

### 8.5 — case 7.5: `merge` and a failing side

```js
const a = Stream.fromIterable([1,2,3]).pipe(Stream.mapEffect(sleep40), Stream.ensuring(log "A"))
const b = Stream.fromEffect(Effect.sleep("60 millis").pipe(Effect.andThen(Effect.fail("B failed")))).pipe(Stream.ensuring(log "B"))
Stream.merge(a, b).pipe(Stream.runCollect)
```

```
  B finalizer
  A finalizer
exit: Failure Fail(B failed)
```

**Rule.** A failure on either side ends the merged stream and the other side's finalisers run —
LIFO across the two, failing side first.

**For beni: SILENT.** Note the *partial results are discarded*: `runCollect` returns the failure, not
the two elements `a` had already produced. A user who wants those needs `mode: "result"`'s stream
analogue, which is another API, not another behaviour.

### 8.6 — case 7.6: a resource acquired inside a stream, with an early stop

```js
const s = Stream.unwrap(Effect.acquireRelease(openFile, closeFile).pipe(Effect.map((rows) => Stream.fromIterable(rows).pipe(Stream.tap(log)))))
s.pipe(Stream.take(2), Stream.runCollect) ; s.pipe(Stream.runCollect)
```

```
  open file / row 10 / row 20 / close file      take(2)  -> [ 10, 20 ]
  open file / row 10 / row 20 / row 30 / close file      collect  -> [ 10, 20, 30 ]
```

**Rule.** The resource's extent is the stream's, so an early `take` closes the file. This is the
case streams exist for, and it is `Task.bracket` composed with laziness.

**For beni: SILENT — decision 16.** If beni ever ships streams, these six are the acceptance
criteria. If it does not, the same program is `Task.bracket` plus a `Queue` and the user writes the
laziness by hand, which is a real capability gap and should be named as one (`CLAUDE.md` rule 7).

---

## 9. Observability of failure, and what a program returns

### 9.1 — case 8.1: `Cause.pretty` for a typed failure and for a defect

```js
const show = async (label, eff) => { const exit = await Effect.runPromiseExit(eff); console.log("--- " + label + " ---"); console.log(Cause.pretty(exit.cause)) }
await show("Fail with a string", Effect.fail("something went wrong"))
await show("Fail with an Error", Effect.fail(new Error("typed error object")))
await show("Die from a throw", Effect.sync(() => { const boom = () => { throw new Error("thrown from sync") }; boom() }))
```

```
--- Fail with a string ---
Error: something went wrong
    at causePrettyError (…/node_modules/effect/dist/internal/effect.js:249:13)
--- Fail with an Error ---
Error: typed error object
    at …/cases/c801.mjs:9:46
--- Die from a throw ---
Error: thrown from sync
    at boom (…/cases/c801.mjs:10:79)
```

**Rule.** `causePretty` builds one `Error` per non-interrupt reason and prints it
(`effect:…/effect.ts:492-496`, `:335-370`). **A failure carrying a plain string has no stack of its
own**, so what is printed is the pretty-printer's own frame — which is worse than useless. A failure
carrying an `Error`, and a defect, print the site that made them. `test:Cause.test.ts:590` *renders a
Fail cause as a string*, `:597` *renders a Die cause*.

**For beni: SILENT, and beni starts from a better place.** Report 21 §8.2 already found that beni's
compiler knows each continuation's span statically where Effect must discover it from a `new Error()`
at 7.2 µs a call. The rule this case adds: **the frame printed must never be the runtime's own.**
Effect's `cleanErrorStack` cuts its frames out with a regex (`:430-445`) and still leaks
`causePrettyError` into the first output above; beni's trampoline frames must be suppressible by
construction.

### 9.2 — case 8.2: `Cause.pretty` for an interrupt, a finaliser failure, and parallel failures

```js
// (a) fork Effect.never, interrupt it, print Cause.pretty of its exit
// (b) Effect.fail("body failed") with an onExit that dies
// (c) Effect.all([fail "left", fail "right"], { concurrency: "unbounded" })
```

```
--- interrupt ---
InterruptError: All fibers interrupted without error {
  [cause]: InterruptCause: The fiber was interrupted by:
      at fiber (#1)
}
--- failure + finalizer failure ---
Error: body failed
    at causePrettyError (…/node_modules/effect/dist/internal/effect.js:249:13)
Error: finalizer died
    at OnExitImpl.onExit (…/cases/c802.mjs:11:103)
--- two parallel failures ---
Error: left
    at causePrettyError (…/node_modules/effect/dist/internal/effect.js:249:13) 
reasons: Fail
```

**Rule.** An interrupt-only cause is rendered as one synthesised `InterruptError` naming the
interruptor fiber (`effect:…/effect.ts:455-464`). A multi-reason cause prints **one block per
reason**, in order. And the third block is the surprise: `Effect.all` with unbounded concurrency
reports **one** failure, because the first failure interrupts the sibling before it can fail — the
only ways to get two `Fail` reasons are `validate` (case 4.3) and a race where every branch fails
(case 4.5). `test:Cause.test.ts:576` *returns InterruptError for interrupt-only cause*, `:544`
*combines mixed reason types*.

**For beni: SILENT, and the one-block-per-reason shape is the thing to copy.** beni's diagnostic
culture is exactly this — `Render.zig` prints from a store, one item at a time — and a flat `Cause`
linearises trivially where v3's `Sequential`/`Parallel` tree had to be flattened first (report 21
§6.4).

### 9.3 — case 8.3: what `runPromise` rejects with

```js
const show = async (label, eff) => { try { … await Effect.runPromise(eff) } catch (e) { console.log(label, "rejected with", e.constructor.name + ":", …) } }
```

```
fail(string)    rejected with String: E
fail(Error)     rejected with Error: typed
die(Error)      rejected with Error: D
interrupt       rejected with Error: All fibers interrupted without error
fail + finalizer die rejected with String: E
```

**Rule.** `runPromise` rejects with `Cause.squash`: the first `Fail`'s error, else the first `Die`'s
defect, else a synthesised interrupt error (`effect:packages/effect/src/internal/core.ts:322-332`).
**It rejects with a bare `String` when the error is a string**, and the last line is the cost:
the finaliser's defect is *discarded* at the boundary, because squash picks one.
`test:Cause.test.ts:302`–`:320` the `squash` family.

**For beni: SILENT, and the lesson is about the boundary, not the API.** Any place beni converts a
runtime `Cause` into a single language-level value loses information, and the only honest answers are
(a) do not convert — hand back a structured outcome — or (b) convert and **print** the rest.
`boundary.md` §5's `Program` is the one place this happens for `main`, which is decision 14.

### 9.4 — case 8.4: an unhandled failure from `runFork`

```js
process.on("exit", (code) => console.log("process exit code:", code))
const fiber = Effect.runFork(Effect.gen(function* () { yield* Effect.sleep("10 millis"); return yield* Effect.fail("nobody is listening") }))
```

```
runFork returned a fiber; no observer attached
fiber exit: Failure Fail
process exit code: 0
```

**Rule.** **Nothing is reported and the process exits 0.** A forked root that fails with a typed
error is silent unless someone observes it; there is no unhandled-failure hook in v4's core, only a
`References.UnhandledLogLevel` used by specific constructs
(`effect:packages/effect/src/References.ts:551`).

**For beni: SILENT, and this is a defect in the gold standard, not a model.** A background task that
dies and reports nothing is the failure mode Elm's `_Scheduler_spawn` has and `research/16` §1.4
complains about. **Recommendation: beni's runtime reports an unobserved failing fiber on stderr**,
and `Task.spawn`'s documentation says so. It costs one branch in the exit path and it is a guarantee
in `CLAUDE.md` rule 7's sense.

### 9.5 — case 8.5: an unhandled defect from `runFork`

```js
Effect.runFork(Effect.sync(() => { throw new Error("defect in a forked root") }))
```

```
runFork of a throwing effect returned normally
still running 80ms later
process exit code: 0
```

**Rule.** The same: a defect in a forked root is swallowed. The `try` around the run loop turns it
into a `Die` in the fiber's exit (`effect:…/effect.ts:700-704`) and, with no observer, that exit is
never looked at.

**For beni: SILENT.** Same recommendation as 9.4, and this one is stronger: a defect is by definition
a bug, and a runtime that hides bugs is the thing `CLAUDE.md` rule 3's *"a fully green suite has
repeatedly coexisted with real defects"* is about.

### 9.6 — case 8.6: an unobserved `runPromise` failure

```js
Effect.runPromise(Effect.fail("unobserved runPromise failure"))
```

```
process exit code: 1
UnhandledPromiseRejection: … The promise rejected with the reason "unobserved runPromise failure".
    at throwUnhandledRejectionsMode (node:internal/process/promises:392:7)
```

**Rule.** Here the host does the reporting Effect does not: an unobserved rejected promise is Node's
problem and Node kills the process with exit 1. **The same failure is loud through `runPromise` and
silent through `runFork`**, which is an accident of which host primitive each uses.

**For beni: SILENT, and it is the argument for 9.4's recommendation.** beni's runtime will not hand
anything to a `Promise`, so there is no host to fall back on: whatever beni does not report is
unreported. Fixture: row 43, once the corpus can express it.

### 9.7 — case 8.7: `runSync` of an effect that would suspend

```js
Effect.runSync(Effect.succeed(1).pipe(Effect.map((x) => x + 1)))
Effect.runSync(Effect.fail("E")) ; Effect.runSync(Effect.sleep("10 millis")) ; Effect.runSyncExit(Effect.sleep("10 millis"))
```

```
runSync of a pure effect  -> 2
runSync of a failure     -> throws String: E
runSync of a sleep       -> throws AsyncFiberError: An asynchronous Effect was executed with Effect.runSync
runSyncExit of a sleep   -> Failure Die(AsyncFiberError: An asynchronous Effect was executed with Effect.runSync)
```

**Rule.** `runSync` is the boundary where "this must not suspend" is checked — **at run time**, by
noticing the fiber parked, and reported as a defect.

**For beni: SILENT, and it is plan §5 decision 1 and decision 5 in one place.** This is exactly the
check P2 §3.2's `sync` makes **at compile time**, and the output above is what beni's `main` would do
*without* it: `boundary.md` §5.4's promise that *"`update` and `view` are `sync`"* has no mechanism,
so a suspending `view` is an `AsyncFiberError` at best and a suspension object handed to a patcher at
worst (plan §6 row 2). **Effect's runtime check is the fallback beni should also have**, even after
`sync` lands, because a `foreign` sibling can call back into beni and check 4 cannot see it
(plan §2.1).

### 9.8 — case 8.8: exit codes under `NodeRuntime.runMain`

```js
// four child processes, one per cause, each running:
//   NodeRuntime.runMain(<body>)   with body = succeed("ok") | fail("expected failure") | sync(throw) | interrupt
```

```
--- success --- exit code: 0
--- fail --- exit code: 1
[15:07:21.202] ERROR (#2): Error: expected failure
    at causePrettyError (…/node_modules/effect/dist/internal/effect.js:249:13)
--- die --- exit code: 1
[15:07:22.147] ERROR (#2): Error: defect
--- interrupt --- exit code: 130
```

**Rule.** `runMain` is where the reporting that `runFork` omits actually lives: it logs the pretty
cause at `ERROR` with the fiber id, and maps the exit — **0 / 1 / 1 / 130**, where 130 is
128 + SIGINT, the shell convention for "terminated by interrupt".

**For beni: SILENT — decision 14.** `boundary.md` §5.2 says a platform declares `runtime`, the
JavaScript file whose `run` export receives `main`'s value, and `platforms/node/runtime.js` today
reads `program.out` and `program.code` off a *value*. There is no failure path because `main` cannot
fail. Once a fiber can, the mapping above is the one to copy, and **the corpus needs a new kind to
test it**: `run/` asserts exit 0 (`tests/blackbox/corpus_test.zig:677`) and `build/bad/` is about the
compiler, not the program.

---

## 10. Where Effect is a wart, or TypeScript-induced

Seven, with what beni should do instead.

1. **Ten `catch*` combinators** (`catch`, `catchTag`, `catchTags`, `catchReason`, `catchReasons`,
   `catchIf`, `catchFilter`, `catchNoSuchElement`, `catchCauseIf`, `catchCauseFilter`, plus
   `catchEager`). Every one exists because TypeScript cannot pattern-match a union and narrow the
   residual type. **beni: `case`, exhaustively checked.** Case 2.11.
2. **`Effect.try` without a mapper produces the error string `"An error occurred in Effect.try"`.**
   A typed failure with no information, offered as the convenient default. **beni: a `foreign` whose
   sibling may throw declares a `Result`; there is no convenient lossy form.** Case 1.8.
3. **`timeout` fails with a `TimeoutError` by default and `timeoutOption` is the opt-in.** The loud
   form widens every caller's error type for a condition most callers fold into a value. **beni:
   P2's `Maybe a` is the default and there is no error form.** Case 4.6, §0.2 row 6.
4. **`repeat`'s return value depends on which overload you used** — `Schedule.recurs(3)` returns the
   schedule's output `3`, `{ times: 3 }` returns the effect's last value `4`, for the same four runs.
   **beni: always the effect's last value.** Case 6.3.
5. **An unhandled failure from `runFork` is silent and exits 0**, while the same failure through
   `runPromise` is loud because *Node* reports it. Two behaviours decided by which host primitive the
   entry point happens to use. **beni: report it, once, from the runtime.** Cases 9.4–9.6.
6. **A parent runs its own finalisers before interrupting its children.** Not argued for anywhere;
   it falls out of `ensuring` being a stack frame and `children` being consulted at exit-publish
   time. **beni: children first, as P2 §6.2 obligation 4 already says.** Cases 3.10, 3.11, §0.2 row 4.
7. **`Cause.pretty` of a string failure prints the pretty-printer's own frame.** The single most
   common failure shape produces the single least useful trace. **beni: a continuation carries its
   span as a compile-time constant (report 21 §8.2), so every failure has a real site.** Case 9.1.

Two things that look like warts and are not, recorded so nobody "fixes" them:

- **`timeout` returning after the deadline** (case 4.7) is correct and is the alternative to leaking
  a socket. It needs documenting, not changing.
- **`race` continuing after one branch fails** (case 4.5) is correct for a redundant-request race and
  is why `raceFirst` exists separately.

---

## 11. Could not determine

- **Whether Effect ever argued about the parent-finaliser/child-interrupt order** (case 3.10). The
  behaviour is clear from the source and from the trace; there is no test that asserts the
  *interleaving*, no changelog entry and no migration note. So §0.2 row 4's verdict rests on my
  reasoning about resource hierarchies, not on Effect having considered and rejected the other order.
- **What `Effect.all`'s `mode: "result"` does under a *defect*.** Case 4.3 covers typed failures
  only; whether a defect in one element is collected as a `Failure` result or escapes the whole
  combinator was not tested.
- **Whether `Scope`'s `"parallel"` strategy also runs LIFO.** Case 5.2's parallel run printed C, B, A
  within one millisecond of each other, which is consistent with both "forked in LIFO order" and
  "forked in any order and they all finished together". The sequential run is unambiguous.
- **What happens to a `Queue` producer blocked on a full queue when the queue is `end`ed.** Case 7.5
  covers takers and later offers, not a producer already parked.
- **The browser.** Nothing here ran in one, and three cases would differ: the op budget's macrotask
  escape (report 21 §0.5 item 1), `AbortSignal` semantics under `fetch`, and whether an unhandled
  rejection is reported at all.
- **Whether `Cause.pretty`'s output is stable enough to golden.** Case 9.1's first block contains an
  absolute `node_modules` path and case 9.8's contains a wall-clock timestamp. If beni's equivalent
  is to be a corpus golden — and it should be — **the renderer must emit nothing machine-specific**,
  which is a constraint Effect's does not meet and beni's diagnostics already do.
- **How much of §7 is worth building at all.** Twelve coordination primitives were measured; P2 names
  four; report 22 owns the API-surface question and this report deliberately does not answer it. What
  is settled here is that **every one of them is library code over the kernel** — not one required a
  runtime capability beyond `callback`-with-canceller, `fork`, observers and `Scope`.

---

## 12. Evidence index

**Source**, `references/effect` at `3d59ae6`, `packages/effect@4.0.0-rc.116`. The lines this report
leans on, in `packages/effect/src/internal/effect.ts` unless said otherwise: `evaluate` and the
child-interrupt point `:620-656`; `interruptUnsafe` `:595-616`; `fiberInterrupt` = interrupt +
await `:903-931`, `fiberInterruptAll` `:934-945`; `callback` and its canceller frame `:1148-1224`;
`raceAll` `:1606-1661`; `timeout` family `:3806-3905`; `Scope` `:3900-4135`, LIFO close `:3941-3962`,
`combineFinalizerCause` `:3935-3939`; `onExitPrimitive` `:4137-4174`; `acquireUseRelease`
`:4346-4358`; interruptibility `:4484-4577`; bounded concurrency `:4981-5128`; `forkUnsafe`
`:5454-5474`, fork variants `:5418-5596`. Also `internal/core.ts:322-332` (`squash`), `:541-555`
(`failCause`'s unwind); `internal/schedule.ts:51-190` (`retry`, `retryOrElse`, `repeat`);
`Schedule.ts` (the whole composition vocabulary); `Queue.ts:1005` (`end`/`Done`);
`Semaphore.ts:207-223`; `testing/TestClock.ts`; `References.ts:551`.

**Tests**, `packages/effect/test/`. The richest files for this report's subject are
`Effect.test.ts` (the `interruption` block `:1822-2140`, the `forEach`/`all` block `:527-800`, races
`:1068-1145`, timeouts `:1600-1799`, brackets `:161-216` and `:2326-2501`, retry/repeat
`:1166-1459`), `Fiber.test.ts:99-188`, `Queue.test.ts`, `Semaphore.test.ts:189-386`,
`Deferred.test.ts:93-149`, `Cache.test.ts:270-368`, `Pool.test.ts`, `Stream.test.ts`,
`Cause.test.ts:302-604`, `Scope.test.ts:7`, `TestClock.test.ts`. The runner is `@effect/vitest`;
`it.effect` runs on a `TestClock` and `it.live` on the real one
(`references/effect/packages/vitest/src/index.ts:113-167`).

**Measurements.** 78 scripts, `cases/c101.mjs`–`cases/c808.mjs`, plus `run.sh` and `transcript.txt`,
in the session scratchpad. Node v24.19.0, `effect@4.0.0-rc.116`,
`@effect/platform-node@4.0.0-rc.116`, busy machine, generous timing margins (§1.2).

**beni documents.** [`transparent-effects-proposal.md`](../transparent-effects-proposal.md) §5, §6
and §7 are what every case is scored against; §3.4, §3.5, §9.1 and §11 Q4/Q11 are the open questions
several cases land on. [`plans/effects-plan.md`](../../../plans/effects-plan.md) §4's slices E3/E4,
§5's decisions 1, 3, 5 and 6, and §6's exit-0 table are what §0.3's suite feeds; this report's
decisions are numbered from 10 to continue §5's list, with 9 reserved for report 21 §11.6's `Cause`.
[`research/21`](21-effect-v4-runtime.md) is the prerequisite — §11.3's ten kernel pieces are §0.3's
`kernel` column, §11.5's three missing fields are cases 3.5 and 3.15, and §11.6's `Cause` decision is
cases 2.4, 2.9 and 9.3. [`research/16`](16-fibers-and-concurrency.md) §5.3's obligations are cases
3.2, 3.4, 3.15, 7.3 and 7.4. [`boundary.md`](../boundary.md) §4 owns the canceller protocol of case
3.3 and §5 owns case 9.8's exit codes. `tests/blackbox/corpus_test.zig:18-22` and `:677` are the
harness constraints §0.3 is written against.
