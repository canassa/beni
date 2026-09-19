# Where beni stands — parked 2026-09-19

**The owner parked implementation on 2026-09-19.** No new agents are to be launched after the one
in flight (M4-3) finishes. This file is the single place to resume from; the running order is
`plans/queue.md`, the history is `plans/diary.md`, the numbers are
`plans/state-of-the-compiler.md`.

## 0. Un-parked for RESEARCH only, 2026-09-20

The owner said "Let's do 1": a read-and-measure design pass on **what a beni browser program is**.
Three docs-only research agents were launched on 2026-09-20, each writing ONE new file and committing
nothing: report 24 (`docs/design/research/24-elm-browser-runtime.md` — Elm's browser runtime as
built, piece by piece, and which pieces exist because of the browser versus Elm's effect model),
report 25 (`25-ui-architecture-design-space.md` — the UI architectures open to a language where an
effectful call is just a call, one running example across all of them), report 26
(`26-browser-host-measured.md` — scheduling primitives, the yield budget, input latency, the `sync`
list, cancellation, loading and the test harness, measured in headless Chrome 153). After the manager
validates and commits them, a synthesis produces `plans/browser-decisions.md` (the owner's decision
sheet) and `plans/browser-platform.md`. **Implementation stays parked**; no code changes in this pass.
If a session finds the reports absent or half-written, the briefs are in `plans/queue.md`'s last
section (rows B-R1..B-R3, B-P) and the transcript; re-launch from there.

## 1. No implementation is in flight

**M4-3 — the firewall cutoff — landed after work was parked** (`92cfca8`..`ed8385f`; validated by the
manager, no new agent): rebased, four gates green on the tip, and exercised by hand — a comment in a
leaf re-checked 1 module of 15 (it was 3 under M4-1), a body edit likewise, and the demonstrated
miscompile (a private type's payload becoming a function) correctly re-checked the importer and
reported `NOT EQUATABLE`, byte-identical to `--no-cache`.

**It changes what every user sees: the cache is now ON BY DEFAULT.** `beni check`/`build` create
`.beni-cache/` in the working directory (git-ignored here); `--no-cache` opts out, `rm -rf
.beni-cache` is the remedy, an unwritable location degrades silently. The flip is one commit
(`9136953`) and reverts cleanly to M4-2 behaviour.

Two honest misses, recorded as queue 55 and in `plans/m4-3.md` §16: a `pub` SIGNATURE edit still
re-checks 624 of 634 modules (127–134 ms against the 41–47 predicted — the interface-hash term in the
digest chain is load-bearing, so it is slow rather than wrong), and the no-edit warm floor went
41 → 44 ms. Measured wins: a comment / whitespace / private value / private type in a leaf, 117 → 45 ms;
warm `build --library` 106 ms (`< 120 ms` met).

## 2. What is on `master` (all pushed, gates green)

- **Language**: Elm 0.19 with the listed departures; static dispatch adopted; `core/` of ten
  modules including `Int32`; every doc example compiled and run (305).
- **Backend (M3)**: tail-call loop, decision trees, `?`, reachability DCE (always on),
  `--release` (dead bindings, narrow inlining, short names, compact printing), `--release` refuses
  `Debug`. Left in M3: static multi-entry chunking and the single-file release bundle (M3d, specified
  in `backend.md` §10, not built). Field ambiguation specified and declined on measurement.
- **Incrementality (M4)**: M4-0 serialized interfaces + hash + the round-trip acceptance matrix;
  M4-1 the persistent cache; M4-2 front-end artifacts on disk; **M4-3 the firewall cutoff, cache ON by default**. On 100k
  lines: warm `check` with no edit ≈ 44 ms (131 cold), after a comment in a leaf ≈ 45 ms (it was 117),
  warm `build --library` 106 ms — the `< 120 ms` budget is met; a `pub` signature edit is still ≈ 130 ms.
- **Tooling**: `check --platform`, `beni check .`, `fmt` keeps modes and symlinks, `dump` exits 1
  over an error, diagnostics point into the file whose text is wrong.
- **Rule 7** in `CLAUDE.md`: guarantees, not restrictions.

## 3. Owner decisions taken (all recorded in `plans/queue.md` with dates)

M4 first, then effects, then M3d · `lazy` parked until a browser platform and a large app want it ·
`--release` refuses `Debug` · `Int32` built · effects gets a full spike with Effect-TS v4
(`references/effect`, 4.0.0-rc.116) as the gold standard.

**Effects decision sheet (`plans/effects-decisions.md`) — answered so far:**

| Item | Decision |
|---|---|
| A1 | Defects (a throwing `foreign`, a stack overflow) are **fatal**, reported well; preventing them is the wall's job. Finalisers are infallible (`-> ()`). `Exit a = Done a \| Cancelled`. No `Cause`. |
| A1 (interruption) | Invisible to the interrupted code; both `await` and `join`; the interrupter waits for cleanup by default; uninterruptible = acquire/release, finalisers, explicit `uninterruptible` + `restore`; children are interrupted before the parent's finalisers run (the reverse of Effect). |
| A2, A3, A10, A11 | Settled by the above (`join` ≠ `await`; `bracket`'s release receives the outcome; combinators return after losers' cleanup; children first). |
| A5 | `impure` is **used** from the slice that infers it — the optimiser consults it before dropping, inlining, merging or reordering. |
| A6 | `sync` ships in the first cut. |
| A8 | `main : Program` stays, body must not suspend; keep-alive while any fiber is parked; exit 0 / 1 / 130; never a silent exit 0. |
| A7 | Services: records of functions and `where` clauses now; three fixed per-fiber slots (clock, scheduler, log context) with the runtime — not a general service locator; the "everything provided at the entry point" proof is conceded in writing. |

**All five shortlist questions are answered, and folded into `plans/effects-spike.md` §0.1 and the
block at the top of `plans/effects-decisions.md`.** Note what A1 changed in the plan: no multi-reason
failure value exists, so slice S9 shrinks to `Exit` plus the crash reporter and the conformance rows
that expected a captured cause now expect a crash with a known report.

**Still open in tier A**: A4 (`retry` takes a `Schedule` — recommended yes), A9, A12–A16; tiers B
(settled by the spike's measurements) and C (can wait).

**Manager decisions taken while the owner was offline** (each one commit, reversible; the owner has
not yet confirmed them): warning-by-default for an unannotated `pub` that infers a `where`, and the
cap of 64 inferred constraints (`9074538`); type-directed irrefutable patterns, `let` widened
(`59e47f3`); an undecidable `case` is an error, budget 5 M (`f21ac4c`, `992ab59`); core callbacks in
list order (`51ab217`); **`sortBy` computes each key once — differs from Elm, awaiting the owner's
word** (`128002b`); `let` refuses forward value references (`3c8fbf8`); top-level value cycles
refused (`a9b77c9`); `String.indexes` non-overlapping like Elm, `contains s ""` is `True`
(`3edc718`, `0c6ef7b`); `dump` exits 1 over an error (`77e003a`); starting M4 slice zero.

## 4. What would come next, in order — nothing here is started

**Re-weight everything below by the owner's statement of 2026-09-19: beni is primarily a BROWSER
language and the browser platform comes before Node.** `plans/queue.md`'s last section lists what that
changes: platform order (browser and its UI architecture first), the effects spike (a platform-neutral
kernel whose first real host is the browser; the Elm-Architecture question becomes central; A8's exit
codes are the Node half only), runtime measurements (all Node-only so far), output size / the
single-file bundle / chunking / `lazy`, source maps, and a browser test harness.

1. ~~Land M4-3~~ — done. Its two misses are queue 55.
2. **M4-4** — whole-program passes made incremental and the emit-side cutoff; `decode`'s 10 ms;
   the 4.68 ms serial floor. Needs a spec (not written).
3. **M4-5** — the daemon. Owner decisions D6–D9 in `plans/m4-plan.md` (protocol, memory ceiling,
   watching, cancellation) are PENDING; the `stat` fast path lives here.
4. **Effects**: finish the decision sheet (A7 first), fold the answers into
   `plans/effects-spike.md`, then the spike (S0 baselines, S1 the hand-written kernel probe against
   Effect v4's 82 ns/op, …).
5. **M3d** reduced: static multi-entry chunking + the single-file `--release` bundle (−22 % brotli on
   `Dictionaries` from concatenation alone).
6. Small, independent, specified by their queue rows: 51 a platform logger (a shipped program
   cannot log), 52 a fifth boundary check (`throw` in a sibling), 53 the hostile-input suite for
   platforms, 54 the crash reporter, 44 the check-tax leads, 9 re-take the runtime measurements
   without the 4×500 split, 10 a stale sentence in the effects proposal.

## 5. How to resume

Read, in this order: `CLAUDE.md` (rules 1–7), this file, the last three entries of
`plans/diary.md`, `plans/queue.md` from the most recent "Owner decision" heading down. The working
arrangement that produced all of the above: the main session plans, briefs and validates; Opus
agents implement from written briefs, one worktree per building agent, at most five agents; every
unit is validated by the manager (fail-first proven, gates on the combined tree, numbers re-run)
before it is committed and pushed; measurements are taken ABBA on a quiet machine and any number
taken otherwise is labelled. `../beni-s1` (the pre-dispatch compiler at `c870e9a`, ReleaseFast) is
the C0 baseline for measurements — leave it in place or rebuild it per
`plans/static-dispatch-resume.md`.
