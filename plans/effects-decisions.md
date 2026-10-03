# Effects — the owner's decision sheet

**Status:** consolidation, 2026-09-19 — **and partly answered the same day; see the block below.**
The item texts are kept as written so the reasoning stays readable; an item's answer is in the block. Read this
before the spike starts; [`plans/effects-spike.md`](effects-spike.md) is written against a stated
default for each, so it is usable the moment these are answered.

**Why this file exists.** Four documents each grew a decision list and they overlap:
[`plans/effects-plan.md`](effects-plan.md) §5 numbers 1–8,
[`research/21`](../docs/design/research/21-effect-v4-runtime.md) (**r21**) §11.6 proposes a ninth,
[`research/22`](../docs/design/research/22-effect-v4-api-surface.md) (**r22**) §9 numbers D1–D9, and
[`research/23`](../docs/design/research/23-effect-v4-semantics.md) (**r23**) §0.4 numbers 10–16 —
**25 raw items**, four of them the same decision written three times, two already closed, and several
real decisions the reports raise without numbering. Deduplicated: **16 that gate the spec**,
**11 the spike's measurements answer**, **9 that can wait**. **P2** is
[`transparent-effects-proposal.md`](../docs/design/transparent-effects-proposal.md).

**Every item.** *Question · why it matters · options · what Effect v4 does · recommendation and whose
it is · what it blocks · reversibility.*

**Already closed.** Plan decision 8 (`List.map`'s right-to-left order) — fixed, `queue.md` item 15.
Plan decision 2 (interleave with M3c/M3d) — superseded by the owner's **M4 first** and
`m4-plan.md` D5. r23 §0.2 row 6 (`timeout` returns `Maybe`) — P2 is right and Effect is the odd one
out; recorded, not decided. `lazy` — parked.

**If you read one section, read §D**: five questions.

## Answered by the owner, 2026-09-19

All five of §D's questions, and what they settle. Recorded in `plans/queue.md` and folded into
`plans/effects-spike.md` §0.1.

| Item | Answer |
|---|---|
| **A1** | **Defects are fatal, and preventing them is the wall's job** — not option (a) or (b). A throwing `foreign` is a bug in `core/` or a platform, a stack overflow is resource exhaustion; neither is a condition beni code handles, and JS fibers share a heap, so containing one means running on state nobody can vouch for. The process dies with a good report and a non-zero exit. **Finalisers are infallible** (`-> ()`), which removes the two-failures-at-once case. **`Exit a = Done a \| Cancelled`.** Interruption: invisible to the interrupted code; the interrupter waits for cleanup by default; uninterruptible = acquire/release, finalisers, explicit `uninterruptible` + `restore`. Follow-ups queued: a boundary check refusing `throw` in a sibling, a hostile-input suite required of every platform, a crash reporter (queue 52–54) |
| **A2, A3, A10, A11** | Settled with A1: two operations (`join` propagates, `await` observes); `bracket`'s release receives the outcome; combinators return after their losers' cleanup; children are interrupted before the parent's finalisers run |
| **A5** | **(a)** — `impure` is used from the slice that infers it |
| **A6** | **(a)** — `sync` ships in the first cut |
| **A7** | **(b) now, a LIMITED (c) with the runtime**: records of functions and `where` clauses for services; three fixed per-fiber slots (clock, scheduler, log context), not a general `Context`; the `R = never` concession written down |
| **A8** | **(a) + (d)** with keep-alive: `main : Program` stays, its body must not suspend; exit 0 / 1 / 130; never a silent exit 0 |

**Still open in tier A:** A4 (`retry` takes a `Schedule` — recommended yes), A9, A12, A13, A14, A15, A16. *Overtaken 2026-10-03: each has since been built or specified (`transparent-effects-proposal.md` §15–§17); see `plans/handover-2026-10-02.md` §2a.*
Tiers B and C are unchanged.

---

## Tier A — must be decided before the spike starts

These shape `docs/design/effects-spike.md`, which rule 1 says is written before the code.

### A1. What is the runtime's failure value — a `Cause`, an `Exit`, and what is a defect?

**Q.** When a fiber dies, what value says why, and can beni code see it? **Why.** beni has no
exceptions; errors are `Result` values. Three things happen at run time that a `Result` cannot
express: a `foreign` throws, a fiber is interrupted, and **a finaliser fails while the body was
already failing** (r23 case 1.4, measured — Effect keeps both, `Fail + Die`). Under P2 §6.5's
`Fiber.join : Fiber a -> Result Cancelled a` the second failure is **dropped silently** at the moment
a user most needs it: rule 7's silent-wrong-answer class. **Options.** (a) r21 §11.6a — a flat
`Fail | Die | Interrupt`, `Die`/`Interrupt` reaching beni only at `join`/`await`/`scope`/`bracket`'s
release, ~90 lines. (b) r22 D2 — `Exit a = Done a | Failed String | Cancelled`, no tree, because the
error channel is already inside `a`. (c) P2 as written. (d) defects are fatal. **Effect v4.** (a),
flattened in v4 from a six-variant recursive tree; no rationale for the flattening is recorded
anywhere in its tree (r21 §12). **Rec.** *Owner's, and the reports disagree* — §C item 1. A synthesis
neither proposes: `Failed (List Reason)`, which is (b)'s size with (a)'s multiplicity.
**Blocks.** Kernel piece 7 (S9); rows 18, 21, 31, 42; A2, A3. **Reversibility: low** — it is in the
signature of `join`, `await`, `bracket` and `scope`.

### A2. `Fiber.join` and `Fiber.await` — one operation or two?

**Q.** Does joining a cancelled or failed child *propagate* into the joiner, or hand back a value?
**Why.** Propagation is what makes `Task.par2` cancel its sibling and `race` cancel its losers
**without the author writing anything** — in v4 neither is a primitive; both are `callback` +
`forkUnsafe` + observers over exactly this. A language whose users cannot write `par2` themselves has
withheld a capability (rule 7). **Options.** (a) both, `join` propagates, `await` returns the
outcome. (b) only the value-returning one. **Effect v4.** Both, differing exactly this way (r23 case
2.9). **Rec.** r23 D15 says (a). *Owner's.* **Blocks.** S10; rows 21, 26, 29, 30. Depends on A1.
**Reversibility: medium** — adding `await` later is additive; making `join` propagate later is not.

### A3. Does `bracket`'s release receive the outcome?

**Q.** P2 §6.5's `Task.bracket : (() -> r), (r -> ()), (r -> a) -> a` tells the release *what* to
release, never *why* it is running. **Why.** Commit-or-roll-back is the commonest thing a bracket is
for and it needs success/failure/cancellation. r23 §0.2 row 1 calls it **a type change to P2 §6.5,
cheap now and an API break later**; withholding it buys no guarantee (rule 7). **Options.**
(a) `(r, Exit a) -> ()`. (b) keep P2's type — users can wrap the body in a `case` and still cannot
observe cancellation at all. **Effect v4.** `release(resource, exit)`. **Rec.** r23 gives it to
Effect without qualification. *Owner's*, since it depends on A1 for what the outcome is.
**Blocks.** S8; **row 16, which does not compile under P2's type**. **Reversibility: low.**

### A4. Does `retry` take a `Schedule` instead of an `Int`?

**Q.** P2 §6.5 has `Task.retry : Int, …` — a count. **Why.** A retry with no backoff is a thundering
herd, and `jittered` exists because three retrying clients synchronise; r23 §0.2 row 2 calls the
`Int` *"the API of a language that has not run anything in production."* A `Schedule` is **pure data
with a step function and needs no runtime support at all** (r22 §5.A), so it can land in `core/`
*before* the runtime — the cheapest yes on this sheet. **Options.** (a) a `Schedule a` with v4's
`min`/`max` names (r22 §8 T1). (b) keep the `Int`. (c) the `Int` now, a `Schedule` later.
**Effect v4.** (a) — and v4 **deleted about twenty-five v3 `Schedule` combinators**, replacing them
with one metadata record, which is evidence for the small shape. **Rec.** r22 §6 item 3 and r23 §0.2
row 2 both say (a). *Owner's.* One sub-question r22 §10 item 2 could not settle: **how the state is
carried**, since `s` is existential and beni has none — a fixed `Int`+`Duration` state covers
`recurs`/`spaced`/`exponential`/`fibonacci`, but `while`/`tap`/`min`/`max` compose schedules of
different states. **Blocks.** S13, row 34; `Schedule` itself blocks nothing. **Reversibility: medium**
— (c) is the escape hatch.

### A5. Is `impure` **used** in v1, or only inferred?

**Q.** Plan decision 4 recommends inferring both bits and using only `suspends`, because `impure`'s
only consumer is an optimiser that does not exist. **Why.** **That ground is now false.** r22 §4.1:
`Ref.get` must carry `impure` or the optimiser may memoise two reads into one — and `Ref` is **T0**,
one `foreign type` and four functions. `language.md` §6 *Evaluation order* licenses dropping,
duplicating, reordering and memoising every expression (its only exceptions are `Debug.log` and a
platform `foreign`), and `src/js/Opt.zig`'s single-use inlining already exercises it under
`--release`. So "infer but do not use" is a **miscompile the day `Ref` lands**, not a deferral —
rule 7's silent wrong answer. §6 already closes by anticipating the fix: *"when effects land, P2 §5
adds a clause exempting `impure`-tagged calls from all three licences."* The space is reserved; the
question is whether it is filled in v1. **Options.** (a) infer both and use `impure` from the first
slice. (b) plan decision 4 as written, and `Ref` leaves T0. (c) one bit, the optimiser conservative
about anything reaching a `foreign` — which P2 §2 argues saturates. **Effect v4.** No analogue; it
has no optimiser. **Rec.** r22's evidence is concrete and later; the plan's recommendation should be
withdrawn rather than re-argued. *Owner's.* **Blocks.** S2, S12, and `language.md` §6's paragraph.
`run/ImpureNotDuplicated` (row 41) is **writable on `master` today** and is the fixture that settles
it. **Reversibility:** high for (a); **low** for (b)→(a), because a shipped optimiser must be audited.

### A6. Does `sync` ship in the first cut?

**Q.** P2 §3.2 drafts `sync` and postpones it. **Why.** Without it there is **no boundary check at
all**: a suspending function reaching a synchronous JavaScript caller is a runtime failure, not a
compile error. `boundary.md` §5.4 has already promised in writing that `update` and `view` are
checked, and §4's check 4 counts a sibling's parameters and cannot see that `core/List.js` calls its
evidence from inside a `while` loop. Rule 7: this one **is** a guarantee — well-typed code cannot
crash. **Options.** (a) yes, right after the bits: one bool on the function type, one
`Interface.Term.Tag`, one obligation kind, one witness (report 17 §6.3 Branch B, priced in plan
§2.5). (b) no. **Effect v4.** No analogue; its `Effect` type does this work. **Rec.** Plan decision 1
says (a) and its argument has only strengthened. *Owner's.* **Blocks.** S3, and A9 — under (b) there
is no way to say "this evidence must not suspend". **Reversibility: high** — it adds a check and
changes nothing that compiles.

### A7. Services and `R` — what is beni's dependency injection, and can it wait?

**Q.** Effect's third type parameter is the set of services a computation needs and does not have,
proven empty at the entry point. beni has no counterpart. **Why.** r22 §5.E: *"D1 must be taken
before the first platform capability is designed, because every capability is either a record
argument, a `where` constraint or an ambient reference, and changing that later rewrites every
signature."* **Options.** (a) R-A — capability records as arguments (Elm's answer, P2 §9.3).
(b) R-A + R-C — records where a bag of functions is wanted, `where` clauses where a handle with
methods is wanted; **both already exist and cost zero**. (c) (b) plus R-B, a fiber-local `Context` —
the only one needing new machinery and the only one serving a test clock, log level, log annotations
and the op budget. (d) R-D — the platform is the environment; the status quo. **Effect v4.**
`Context.Service` + `Layer`, memoised by object identity, with `Context.Reference` as the *defaulted*
case that never appears in `R`. v4 deleted `FiberRef`/`FiberRefs`/`Differ` and moved ambient values
out of `R` — i.e. Effect itself separates (b) from (c). **Rec.** r22 D1: **(b) now, (c) with the
runtime**, and the deferral is real *if* the clock and scheduler are hard-wired fiber slots rather
than a general `Context` (r21 §7.3: three slots, not a service locator). Under every option one thing
**must be conceded in writing**: beni will not have `R = never` at the entry point. *Owner's.*
**Blocks.** Every T0/T1 signature (S12, S13); A13's clock; A16's `Log`, since r22 §2 S18 says
*designing `Log` is what will tell you whether R-B is needed*. **Reversibility: lowest on the sheet.**

### A8. What is `main` under effects, and what does a dying program print and exit with?

**Q.** Asked from three sides: plan decision 5 (`main : Program` stays and its body is `sync`?),
r22 D9 (Effect's whole program *is* an effect, plus process keep-alive), r23 decision 14 (what a beni
program prints and exits with when `main`'s fiber dies). **Why.** `main` is emitted today as a
module-level constant evaluated at import time, outside any fiber, with no scheduler to park on.
Whatever is decided touches the ~70 `run/` fixtures that write `main : Program`. And there is a
**corpus gap**: `run/X` compares stdout only and the program must exit 0
(`corpus_test.zig:677`), so asserting a non-zero exit needs a new fixture kind. **Options.** For
`main`: (a) `main : Program` stays, body `sync`, checked by A6. (b) `main : () -> Program` and the
platform calls the thunk. (c) `Program` gains a thunk field and `main` may perform. For exit codes:
(d) v4's mapping — 0 success, 1 typed failure, 1 defect, **130** interrupt. (e) 0/1 only.
**Effect v4.** Exactly (d), measured (r23 case 8.8). Separately, v4 built **reference-counted process
keep-alive into the core runtime** because in v3 a program parked on `Deferred.await` exited silently
with the work undone (r22 D9). r23 §10 item 5 records a wart not to copy: an unhandled failure from
`runFork` is silent and exits 0. **Rec.** Plan decision 5 says (a); r23 decision 14 says **(a)+(d)**,
noting they are not exclusive because (a) constrains `main`'s *body* and says nothing about a
`Task.spawn` inside it. r22 D9 adds that **keep-alive has a right answer and is not optional**.
*Owner's.* **Blocks.** S5, S9, S15; row 43 and the new corpus kind; `boundary.md` §5.
**Reversibility:** low for `main`'s type (corpus-wide churn); high for the exit codes.

### A9. May a well-known `eq` or `compare` suspend?

**Q.** `core/List.beni` declares `foreign eq`/`compare` with a `where` clause and `core/List.js:37`
is **a JavaScript `while` loop that calls beni evidence**. If that evidence suspends, `!suspension`
is `false`, the loop walks to the end, and `[x] == [y]` is **`true` for any x and y, at exit 0, with
no diagnostic** (plan §2.1). Same hole in `compare`. **Why.** It is `foldl`'s miscompile in the
position static dispatch created, and report 17's grep for a parenthesised arrow in a `foreign`
signature cannot see it because the function type is in the `where` clause. Rule 7: silent wrong
answer. **Options.** (a) a `must_not_suspend` obligation where a **well-known** constraint is
resolved — a user-written `where a.fetch : …` still suspends freely. (b) move `List.eq`/`compare`
into beni over a new uncons primitive. (c) teach `core/List.js` the suspension protocol.
**Effect v4.** It has this exact class of boundary and closes it with (c)'s shape: `fiberAwaitAll`'s
`loop()` re-enters through `addObserver` rather than the stack, and **every hand-written JavaScript
loop in v4 that touches an effect is written this way** (r21 §0.3 item 4). **Rec.** Plan decision 6
says (a), (b) in reserve, and rejects (c) as widening the privileged surface against rule 6.
**r21 §0.5 item 4 disagrees on the evidence**: write the (c) variant and measure it first — *"if (c)
is 10 lines and costs nothing, decision 6's 'widens the privileged surface' objection is weaker than
it looks."* That measurement is B10, in S1. *Owner's, after S1.* **Blocks.** S3, and whether derived
`eq`/`compare` need a second body (under (a) they stay single-bodied, ~198 B each not doubled).
**Reversibility:** (a)→(c) easy; (c)→(a) a breaking narrowing.

### A10. Does a combinator return before its losers' cleanup has finished?

**Q.** May `Task.timeout 50` take 255 ms? Does `par2` return before the cancelled sibling's finaliser
has run? **Why.** r23 §0.5 ranks this **the single most likely thing a first implementation gets
wrong.** Measured: Effect's 50 ms timeout returned at **255 ms** (case 3.7); `Effect.all` returned
only after both siblings' 80 ms finalisers (case 3.2). The alternative is `Promise.race`'s semantics,
which P2 §6.5 already rejects for `race` because *"`Promise.race` forgets its losers"* and a loser
holding a socket holds it until the process dies. **Options.** (a) wait, for both. (b) return at the
deadline and let cleanup finish in the background. (c) wait, with a second bounded budget — Trio's
shielded cleanup timeout, which needs `bracket` to carry a budget. **Effect v4.** (a), for both.
**Rec.** r23 decisions 10 and 11 both say **(a) for v1**, and both add that *it is a sentence users
will rely on*: "`timeout 50` may take longer than 50 ms" is surprising and belongs in the doc
comment. (c) is the right long-term answer. *Owner's.* **Blocks.** S13; rows 26, 32.
**Reversibility: high** — a behaviour with a fixture, not a type.

### A11. Do a parent's own finalisers run before or after its children are interrupted?

**Q.** P2 §6.2 obligation 4 says *"descendants are signalled before the parent unwinds."* **Why.** A
parent finaliser that closes a connection a child is still writing to is a use-after-free.
**Options.** (a) P2's order, children first. (b) Effect's. **Effect v4.** **The opposite of P2**: the
parent unwinds its own continuation stack first — every `ensuring`/`onExit` frame runs — and only
then are children interrupted and awaited (r23 cases 2.10, 2.11). **Rec.** r23 §0.2 row 4 gives it to
**P2**: Effect's order *"is an artefact of its implementation … not a decision it argues for"*, and
r23 §11 confirms no test, changelog entry or migration note argues the interleaving either way.
*Owner's*, because it means deliberately diverging from the gold standard. **Blocks.** S10; row 23,
written to fail against Effect's order. **Reversibility: high.**

### A12. Three smaller amendments to P2 §6.5's primitive list

**Q.** Three additions the reports make that P2 does not have. **(1) `uninterruptible` /
`interruptible` over a thunk** — r22 §6 item 9 calls it *"the highest-value item that the proposal
argues about and does not fix."* P2 §9.1's own accepted risk is a maintainer adding a log line and
creating an interruption point inside someone else's charge-then-reserve sequence, and P2 concedes
`bracket`'s implicit version *"is the right answer for a resource and no answer at all for a
sequence."* `uninterruptible (\() -> …)` is a **runtime answer to a runtime hazard**: no bit in any
type, no `sync`, no annotation. r21 §4.2 adds that P2 is also missing **`restore`**, without which
`acquireUseRelease` cannot be written at all, because a long `use` would inherit the acquire's
uninterruptibility. **(2) The fork family** — P2 has `Task.spawn` and `Scope.spawn`; Effect has
`forkChild`, `forkDetach`, `forkIn`, `forkScoped`, and `forkDetach` is what a background task needs
and P2 cannot express (r23 case 2.12). Plus **`startImmediately`**: a scheduled fork costs a
macrotask turn, measured at **6.7×** (472 vs 3 172 ns), and P2's `Task.spawn` read literally
specifies the expensive one. **(3) `Duration`, not a bare `Int`** of milliseconds (r22 §7.7).
**Rec.** All three are additive and cheap; the only real choice is how many fork forms ship first.
*Owner's*, and they can be taken as one yes. **Blocks.** S7 (`restore`), S10, S12; rows 11, 13, 14,
24. **Reversibility:** high for 1 and 2, medium for 3.

### A13. Deterministic time: a swappable clock and scheduler, from the first commit

**Q.** Does the runtime read the clock and the scheduler from a replaceable slot? **Why.** r22 §0
finding 8 calls deterministic time *"the highest-value thing Effect has that the proposal never
mentions"*, and r23 decision 13 says **half of its 78-case catalogue is untestable in beni's golden
corpus without it**: a fixture that sleeps is slow and flaky, and the determinism test runs the
corpus four times. Measured: a ten-hour retry schedule completes in **under 200 ms of wall clock**
with a deterministic attempt log (r23 case 5.5). Rule 7: "your concurrent code is testable" is a
claim Elm has never been able to make. **Options.** (a) the platform exposes a swappable clock and
scheduler from the first commit — two fiber slots, inherited by pointer on fork. (b) real short
sleeps in fixtures, tolerating the flake. (c) no fixture may sleep; every timing rule is tested by
ordering alone. **Effect v4.** Its scheduler **is** a fiber-local and `runSync` installs a different
one; `Clock` is a reference with a default, which is the whole of `TestClock`. r21 §8.4 is blunt: a
swappable scheduler **is not deferrable, because retrofitting it means threading a parameter through
every primitive.** **Rec.** r23 decision 13: **(a) plus (c)**; (c) is already the discipline the
conformance suite imposes. *Owner's.* **Blocks.** S11; rows 32, 34, 35 and the practicality of S13.
**Reversibility: low** — r21 §8.4 says so explicitly.

### A14. What is in the kernel's first cut?

**Q.** How much of P2 §6.5's eleven primitives does the spike build? **Why.** Cancellation is the
whole reason the lowering was chosen, so a spike omitting `bracket` measures the wrong thing; but
`race`, `timeout`, `parAll`, `Queue` and `RateLimiter` are library code over the same record and
prove nothing new. **Options.** (a) all fifteen signatures. (b) the eight `research/16` §5.6 calls
free under both lowerings, plus `bracket`. (c) `spawn`/`join`/`scope`/`bracket` only. **Effect v4.**
r21 §0.4 sizes its kernel at **ten pieces, ~2 161 v4 lines, ~1 260 estimated for beni** (no
interpreter, no dual API, no variance phantoms, no `Pipeable`), with **~5 kB gzip** for the whole
concurrency surface; seven of P2's eleven are library code over it in v4 too. **Rec.** Plan decision
3: **(c) for the spike, (a) for the adoption**, endorsed by r21 §11.3 from the other side — *"the ten
above are the only pieces whose cost is unknown."* *Owner's.* **Blocks.** The slice boundary between
S5–S10 and S12–S13. **Reversibility: high.**

### A15. How far does the `must_not_suspend` chain reach?

**Q.** When a `sync` function suspends, does the diagnostic name the whole cross-module chain or stop
at the module boundary? **Why.** `checker.md` §7 keeps `Interface.Provenance` **out** of the record
on purpose — it must never be hashed with what M4 caches — and M4 slice zero has now shipped that
hash, so a full chain is a live M4 cache-key question (plan §2.5). **Options.** (a) one hop per
module: *"`view` is `sync`, but it suspends. `view` calls `renderRow` (View.beni:12); `renderRow`
suspends."* Needs nothing beyond the bit already in the interface. (b) the full chain, from a side
artifact excluded from the hash. **Rec.** Plan decision 7: **(a) for v1** — (b) *"is an M4 cache-key
design decision wearing a diagnostic's clothes."* *Owner's.* **Blocks.** S3's diagnostics.
**Reversibility: high** — (a)→(b) is additive.

### A16. May a minimal platform logger land on `master` before the spike?

**Q.** `queue.md` item 51: `core/Debug.beni` is the only way to write a line, and `--release` now
refuses any build reaching `Debug`. **So a shipped beni program cannot log.** **Why.** A rule-7 gap
on `master` **today**, not a spike item: no guarantee is at stake, it is a missing library, and rule 7
says a capability gap is filled inside the wall because only `core/` and the platforms may write
`foreign` (r22 §0 finding 5). **Options.** (a) a `Node.log`-shaped step now, composing with today's
`Program`. (b) a `pure` `foreign` returning `()` — **a lie until `impure` exists, and `Opt.zig` may
legally delete it.** (c) wait, and ship `Log.info`/`warn`/`error` with the effects work.
**Effect v4.** Levels, annotations and a pluggable logger, implemented over the fiber-local
environment — which is why r22 §8 says **designing `Log` is what will tell you whether A7 needs
option (c)**. **Rec.** (b) should be rejected explicitly. Between (a) and (c) this is a judgement
about how long `master` carries the gap. *Owner's.* **Blocks.** Nothing in the spike; it unblocks
`master`, and its design is an early probe of A7. **Reversibility: high.**

---

## Tier B — decided by the spike's own measurements

Each names the measurement in [`plans/effects-spike.md`](effects-spike.md) §5 that answers it.

| # | Question | By | Reference point, and what would be disqualifying |
|---|---|---|---|
| **B1** | The yield budget: 16, 64, 512, 2048, never? | E-M10 | P2 §7.5 says 64; r21 §9.3 measured **512 as the knee** on Node — fastest *and* 1.7 ms latency, where 64 costs 1.4× for 0.7 ms. §C item 2: two reports disagree. The **browser** half is `research/16` §6's missing experiment and r21 §0.5 item 1 calls it the most valuable unrun thing in the file |
| **B2** | Does compiled closure-CPS beat an interpreted op array? | E-M4 | r21 §12: *"the single assumption the whole 'compiling beats interpreting' claim rests on"* and *"the first thing E3 should measure."* v4: **82 ns** per `flatMap` step, **67 ns** per generator step. Failing to beat 82 ns reopens the lowering |
| **B3** | Can the fiber record be lazy? | E-M8, a retained-bytes gate on the model of Effect's `serverAllocations.ts` | v4's parked fiber is **419 B** / **659 B** with a canceller. `research/16`'s 692 B projection was *"0.2× an Effect fiber"* on v3; **on v4 the ratio is 1.05**, so size is no longer an advantage and P2 §11 Q3(b) is the only place left to win |
| **B4** | What do two bits per function type cost at check time? | E-M1 | Dispatch cost **+20.3 % of check on code that never uses it**. Plan §3's proposed bound: **≤ 10 % of check, 0 % of emit**. Today: 77.95 ms for 100 159 lines, 1 285 k LOC/s per core |
| **B5** | What do the bits cost the interface, and do they move churn? | E-M3 | Constant bits are three spare `Tag` values and cost zero words; a flag *variable* needs one word from a two-word `extra` header. Report 19 §4 measured dispatch at **4.4–6.5× worse** unannotated-`pub` churn. An edit that does not change effectfulness must not move an interface |
| **B6** | Is double translation worth building? | E-M12 | P2 §11 Q7 already frames it that way, because the fallback became a predictable branch rather than a microtask turn. Plan §3's bound: the floor may not grow at all for a program with no suspending call — which is answerable now that DCE has landed |
| **B7** | Do traces through a suspended fiber work, and cost what? | E-M13 | Effect pays **7.2 µs per call** to discover a call site from a `new Error()`; beni's compiler knows the span statically. r21 §8.2: *"the single clearest place where compiling beats interpreting"* |
| **B8** | What does a `bracket` cost to install and unwind at depth? | E-M9 | v4: **2 076 ns install, 199 ns unwind**, install dominating by 10× because `acquireRelease` is a mask + `contextWith` + a `Map.set` with a fresh key. A beni `bracket` that is a frame should beat it by an order of magnitude; r21 §11.4 says *prove it* |
| **B9** | Does code using none of it pay nothing? | E-M2, E-M11 | The claim to **test**, since dispatch's precedent is that it does not. Acceptance: every `emit/` golden byte-identical, the floor and `bench/corpus` unmoved. The runtime's own budget is **≤ 5 kB gzip**, and `Reach.zig` is what keeps a program that never spawns from paying it |
| **B10** | Is A9's option (c) really ten lines? | a written variant in S1 | r21 §0.5 item 4 asks for it **before** A9 is decided |
| **B11** | Can a fiber-local `Key a` be typed soundly without a language feature? | a probe in S11 | r22 §10 item 1: *"the one item in this report that needs a spike rather than an argument."* Feeds A7 option (c) |

**Two figures need re-taking before they are quoted again**, because two reports on the same machine
do not reproduce each other: P2 §7.2's `await`-on-a-non-promise at 122–135 ns against r21 §9.1's
55 ns (2.4×), and `research/16` §3.8's 481 B parked async frame against r21 §9.4's 50 B (9.6×).

---

## Tier C — can wait until after the spike

None constrains the kernel **provided** it keeps `uninterruptible` (A12) and a per-cell waiter list.

| # | Question | Source | The source's recommendation |
|---|---|---|---|
| **C1** | `Stream` — and when? | r22 D5, r23 D16 | Not v1. The smallest honest version is a pull source plus combinators, **no `Channel`**, whose generality serves `Stream`, `Sink`, RPC framing and HTTP bodies at once and beni will have none of the last three for years. Keep the representation opaque; r23 §8's six cases are the acceptance criteria |
| **C2** | STM (`Tx*`) | r22 D3 | Not in the first release — but it is **the only family that constrains the runtime** rather than sitting on it, since a transaction must be able to retry. Say so in the kernel spec rather than discover it at T2 |
| **C3** | The T2 batteries: `PubSub`, `Pool`, `Cache`, `RcRef`/`RcMap`, `FiberSet`/`Map`/`Handle`, `SubscriptionRef`, `Request`/`RequestResolver` | r22 §4.3, §6 item 7 | All library code over the kernel. Batching (the n+1 problem) is *"a genuinely differentiating feature"* needing nothing from the language; the `FiberSet` family is what v4 named when it deleted `Supervisor`, and it needs A1 |
| **C4** | Spans and tracing | r22 D8 | (b) a `Tracer` in `core/` with `withSpan` over a thunk, with (c) — a build flag wrapping every `suspends` function in a span — **recorded as the thing to revisit**, because beni owns the emitter and Effect does not. Deciding late is fine; forgetting is not |
| **C5** | Naming — keep Effect's? | r22 D6 | Effect's names where the semantics match, bounded by two beni rules: **subject first** (`Queue.offer q x`), and **a nullary method cannot be dot-called** — `fiber.join` is a field access, so it is `Fiber.join fiber`. The effects API is the first large consumer of that rule and the spec should say so once |
| **C6** | `Cmd`-level cancellation, and the browser | r22 D7 | Fiber-level only for the spike; `boundary.md` §5.4's `Cmd.keyed` with its four policies before the browser platform ships. Naming them costs nothing — §5.4 already did |
| **C7** | Error accumulation | r22 D4 | (a) `Result.combineAll`/`partition` in `core/` now — twenty lines, **landable on `master` before the spike**; (b) a `mode` on the parallel primitives later, answered once together with P2 §11 Q4's question about `and` groups. Open: `List e` or a non-empty list beni does not have (r22 §10 item 3) |
| **C8** | Surface sugar: bare `let` items, `and` groups | P2 §3.3, §3.4 | **Independent of everything else** — P2 §3.3 says so, and bare items are what `Debug.log` wants today. Landable on `master` at any time; not on the spike's critical path |
| **C9** | `lazy` | owner, 2026-09-19 | **Parked.** Returns when a browser platform and a real application want it; effects will be in by then and make it cheaper |

---

## §C. Where the inputs disagree, and which evidence is stronger

1. **The failure value: r21 §11.6(a)'s flat multi-reason value against r22 D2's
   `Exit a = Done | Failed String | Cancelled`.** Written the same day against the same tree; the
   same decision (A1) with two answers. r22 argues the error channel is already inside `a`, so no
   tree is needed. r21 argues a **finaliser failing while the body already failed produces two
   causes** and (b) has nowhere to put the second — which r23 case 1.4 then measured happening
   (`Fail + Die`, both kept) and called *"report 21 §11.6's decision in its sharpest form."*
   **r21 + r23 are stronger**: they name an executed case r22's shape cannot represent. r22's size
   argument is untouched, and neither proposes the synthesis in A1. *Unresolved — question 1 of five.*
2. **The yield budget: P2 §7.5's 64 against r21 §9.3's measured 512.** P2 reasoned from
   `research/16` §2.3's v3 measurement of a 361 ms freeze. **That is now historical**: v4 deleted the
   microtask path, every yield is a macrotask, and the same experiment on v4 gives **8.9 ms**. Swept
   on Node, 512 is fastest *and* gives 1.7 ms latency. **r21 is stronger — it measured v4, P2
   reasoned about v3.** r22 §0 says the opposite (*"beni's proposed 64 … should stay"*) on the same
   superseded figure, so **r21 supersedes r22 here too.** The browser settles it (B1), and
   `research/16` §5.5 already says the number is a **platform constant, not a language decision**.
3. **`impure`: plan decision 4 against r22 §4.1's `Ref` finding.** The plan's ground — no optimiser
   exists — is false as of `--release`. **r22 is stronger and the plan's recommendation should be
   withdrawn**, not re-argued. A5.
4. **Parent/child finaliser order: P2 §6.2 obligation 4 against Effect's measured behaviour.**
   **P2 is stronger on the guarantee**, and r23 §11 found no evidence Effect ever *argued* the order
   — no test asserts the interleaving, no changelog entry, no migration note. A deliberate divergence
   from the gold standard, and it should be written down as one. A11.
5. **P2 §6.4's `interruptor` field against v4's canceller-as-a-stack-frame.** P2 put
   `interruptor : ?fn(Exit a)` on the record on the strength of v3's `_asyncInterruptor`; **that
   identifier returns zero hits in v4.** **r21 is stronger and the design is better**: one mechanism
   instead of two, nesting for free, uninterruptible while it runs, and it runs *only* on an
   interrupt — a distinction P2 §6.3 does not draw. Plus three fields P2's record lacks entirely
   (`running`, `deferredInterrupt`, `interruptedCause`), each a silent-wrongness class (r21 §11.5).
6. **`research/16` §5.2's split `conts: ByteStack` + `objectState: ArrayStack`.** That layout exists
   because Cats Effect stores a continuation's *kind* as a byte; beni's continuations are **closures
   the compiler emitted**, so the stack is an `Array<fn>` and there is no kind to store. **r21 §2.2
   is stronger**; the recommendation does not apply.
7. **Where E1/E2 land: plan §4's "straight to master" against the owner's M4-first ordering.** The
   plan's argument is good, but `m4-plan.md` D5 fixed the order and D4 chose *not* to reserve the
   bits precisely so that adding them is *"a version bump and a cache discard, not a migration."*
   **The ordering is settled; the residual is whether the bits land on `master` or on the branch**,
   and it turns on whether "adopt the inference half only" must stay a reportable outcome.
   `plans/effects-spike.md` §2.2 argues it and marks it PENDING.

---

## §D. If you only answer five questions, answer these

1. **A1 — what is the runtime's failure value?** It is in the signature of `join`, `await`, `bracket`
   and `scope`; it blocks kernel piece 7 and four conformance fixtures; and it is the one place two
   of the three reports contradict each other. Nothing about the kernel can be specified around it.
2. **A7 — services and `R`.** r22 §5.E: *changing it later rewrites every signature.* Even the
   minimal answer has to be taken now, because every T0 and T1 signature, the test clock and `Log`
   all resolve differently under it — and the concession that **beni will not have `R = never` at the
   entry point** belongs in the spec rather than in a user's bug report.
3. **A5 — is `impure` used in v1?** The plan says no; the evidence says that is a miscompile the day
   `Ref` lands. It decides what `language.md` §6 licenses the optimiser to do, and `Opt.zig` already
   shipped under the old licence. `run/ImpureNotDuplicated` is writable on `master` today.
4. **A8 — what is `main`, and what does a dying program print and exit with?** It touches the ~70
   `run/` fixtures that write `main : Program`, it needs a corpus kind that does not exist, and the
   keep-alive half has a right answer — a program parked on a `Deferred` must not exit silently with
   the work undone — that no beni document covers.
5. **A6 — does `sync` ship in the first cut?** The only guarantee-bearing item in tier A: without it
   there is no boundary check, `boundary.md` §5.4's written promise has no mechanism, and
   `core/List.js`'s suspending-evidence hole (A9) stays a silent wrong answer rather than a
   diagnostic.

**One rider.** A3 (`bracket`'s release receives the outcome) and A4 (`retry` takes a `Schedule`) are
**type changes to P2 §6.5 that are cheap today and API breaks later**, and neither needs new
machinery — `Schedule` is pure data and can land in `core/` before the runtime exists. If both are
the obvious yes, say so in the same breath and the spec is written once.
