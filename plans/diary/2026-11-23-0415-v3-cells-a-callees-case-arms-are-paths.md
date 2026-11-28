## 2026-11-23 04:15 CET — v3 cells: a callee's case arms are paths

**What I did**

- Lane prec182, the fourth precision lane of v3's cells, on `own3-prec179` (aaeaef9233).
- **A callee's paths** (kernel §13 item 13, new). A body that answers a `case` publishes, for each arm,
  what it writes and what it leaves in a cell argument. At a direct call the caller judges each write
  on the runs of the arms that make it (`judge_set`), makes one version of the cell whose cells that
  one arm alone (or two arms, at their first call) put somewhere carry that arm (`tagPaths`, chained
  over calls by `meetPath`), and the later-read test compares a holder with a written cell only where
  both can be on one run (`pairLive`). `apply r Undo`, whose `Add` arm writes `present` and whose
  `Undo` arm moves it to `future`, then reads and writes of `future`, is accepted and runs in place
  (`run/CellCalleePaths`, live twins `run/CellCalleePathsLive`; `cells.mjs` gains `paths*`).
- Three repairs the dumps of blind rounds BN to BP found on the way, each an accepted write the base
  had and the change lost: a path that leaves a cell published nothing, so the caller read its old
  cells as they were, not as the union's new names; a chain of paths took the two places `meet` keeps
  for the frame's own `if` arms (contexts now have the chain and the arms apart, `splitCtx`); the
  copies of two-path cells. And four cost cuts (copy a path's cells where it leaves what another
  does, one climb for a call's paths, nothing added by an arm around the chain).
- Evidence on c5b34112c4: root dumps of 2 545 roots, base and head, differ only in summaries and
  the two new fixtures (0 accepted → refused); the ledger is 309 of 319, as on the base; v3 on the
  real roots 3 300 and 3 981 ms against the base's 3 185 and 3 834 (two paired runs under load); a
  twelfth of `cells.mjs` with all 546 `paths*` programs, a twelfth of the other 42 generators with
  the whole corpus, and an eightieth of blind rounds BC to BR dumped on both: 0 accepted → refused
  but 20 near-budget copies of BN's undo app (`dup3`, `dup4`, `undo100`, `undo300`) now at their
  limit; every newly accepted program SAME under the four legs; a mutant (`pairLive` false for two
  tagged cells) accepts 70 of 933 sampled live programs and traps on 26; three adversarial reviewers
  (5 388, about 1 300 and about 6 600 programs) found no fault; `zig build gates` exit 0.

**What I learned**

- BN's undo app with only the copies v3 needs (`save`'s, and `Undo`'s and `Redo`'s copy of the
  list they take out of `past`/`future`) is still refused: the `Just`/`Nothing` arms of the callback
  in `Ref.update r λh → case List.last h.past of …` are one union in the callee's `Undo` path. The
  next step is paths with per-path results on a closure, a split at a cell row whose function has
  paths, and paths refined through split calls in tail position.
- A function of twelve or more calls of `apply` passes its budget: work grows about as n^2.8 in n
  calls on the base too (14 644, 28 723, 55 960, 104 784 units for 1 to 4 calls; 2 246 748 for 12).
- Precision costs work where it accepts: a write judged on fewer runs is compared with every later
  holder before it is accepted. The undo app's thirteen-call copy (`dup3`) and its kin, which the
  base accepts near their budget, pass it with the paths.
- One context names no set of arms: an atom of several paths must be untagged or copied, and copies
  at every call of a chain multiply past the budget.
- The host `/tmp` was full (another session's 7.3 GB): every command ran with its output in a file.
