## 2026-09-18 18:35 CEST — unattended: the adoption's debts paid, M3b nearly closed, five exit-0 holes shut

**What I did** (manager; every implementation by an Opus agent, every unit
validated by me — fixtures proven to fail first, gates re-run on the combined
tree — before its commit; running order in `plans/queue.md`)

- **The five debts of the dispatch adoption are paid**: printer defects
  (`83ce553` — the `<error>`-in-an-interface cause was a 256-slot stack in the
  poisoned-type scan, not `Schemes.Writer.max_depth` as report 19 guessed),
  the `foreign` arity check as `boundary.md` §4 check 4 (`16b1c0d`, a token
  count, no JS parser), the warning-by-default and the cap of 64 (`9074538`),
  and **reachability DCE** (`dc311d0` spec, `22f7f2f` code): hello-world went
  from 68 794 bytes in 19 files to 2 061 in 5 — re-measured by me.
- **M3b**: tail-call loop (`bbfc869`), decision trees (`ebacb5b` spec,
  `cf7806f` code: worst path 17 → 2 on an enum-in-a-cons match, R1–R6 10–20 %
  faster, checksums identical). `?` codegen is in flight and is the last gap;
  `Int32` does not exist in the language at all — **owner decision**.
- **Five exit-0 wrong-answer paths found and closed**, none by the gates:
  a refutable pattern in a parameter was an unchecked destructure (`59e47f3`);
  a `case` the usefulness budget could not decide passed in silence and fell
  off a default-free tree (`f21ac4c`); a sibling that forgot its evidence
  parameter made `[1,2] == [1,2]` answer "different" (`16b1c0d`); `List.map`
  ran its callback right-to-left and `Dict.map` pre-order (`51ab217`); a
  `let` value naming a later one threw a TDZ error (`3c8fbf8`). Two more are
  queued: record literals evaluate fields in sorted-name order, and top-level
  value cycles throw at load.
- Evaluation order is normative at last (`language.md` §6, `f21ac4c`) with
  four `run/` guards for M3c's inlining; `--source-maps` is refused rather
  than swallowed (`b41e860`); `Render.Namer` is O(1) per name (`b48160b`).
- `plans/effects-plan.md` (`fe3cf8e`): the proposal corrected against what
  landed, slices E0–E6, and **eight decisions that are the owner's**. No
  effects code was written.

**Manager decisions taken with the owner offline** (each one commit, each
recorded where it lives, each reversible): the inferred-interface warning on by
default and the cap of 64 (A.83); irrefutable positions decided by usefulness,
`let` widened to admit single-constructor patterns (`language.md` §7);
budget exhaustion is an error; core callbacks run in list order and `foldr`
is the exception by contract; `let` keeps written order and refuses forward
value dependencies; `--library` as DCE's second root rule.

**What I learned**

- **My briefs were wrong four times and "verify the premise" caught each**:
  the bisect (morning), "evidence is loop-invariant" (polymorphic recursion),
  "parameters obey `let`'s syntactic rule" (40 sites broke, 27 in core — the
  implementer built it, counted, and argued for the type-directed rule), and
  the DCE spec's edge set (wrong three times: operators leave no `refs` row,
  `primitive string_compare` calls core, `err` calls `Basics.eq`). What
  saved DCE was a **compile-time self-check** — "I emitted a reference to X,
  which this build eliminated" — that fired before any fixture ran. For any
  pass whose failure mode is a runtime `ReferenceError`, build the check that
  turns it into a compiler error first.
- **An audit by experiment beats a list in a document.** `backend.md` §1's
  M3b list was stale in four of seven items, and the audit's headline was a
  miscompile nobody had listed. Same for "zero higher-order `foreign`
  values": true of signatures, false of `where` clauses.
- **Tests had been asserting two of the holes.** An abuse test pinned "a
  2000-deep single-branch `case` checks clean" and a `parse/good` fixture
  advertised "a binding used before its textual position". A fixture that is
  never RUN proves nothing about behaviour — rule 3's preference for `run/`
  is not a style note.
- **Worktree-per-building-agent scales to four agents on this machine**; the
  cost is a rebase + one gate run on the combined tree per landing, and that
  gate run is the real integration test (it is what ran every evaluation-order
  fixture under DCE). Docs shared between two in-flight slices in ONE checkout
  cannot be committed separately — give each slice its own files or its own
  worktree.
- Emit MB/s is a bad regression metric once a slice shrinks the output: decision
  trees made emit 13 % faster and the MB/s figure 9.6 % worse.
