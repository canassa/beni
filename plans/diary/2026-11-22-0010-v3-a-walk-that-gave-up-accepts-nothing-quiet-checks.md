## 2026-11-22 00:10 CET — v3: a walk that gave up accepts nothing; quiet safe-build checks

**What I did**

- Lane fix173, #2597 (an ultrareview of the v3 cells branch). Base d5851425e6.
- Item 1: a send refused during the walk for a cause of its own (`unknown`: a top-level list in the
  message) was turned into an accepted `entry` line even when the walk then gave up. It authorised
  nothing: a send is no row of the lowering channel, and a module with a limit publishes no write.
  `finishDemands` now tests the give-up itself. The reviewer then showed the same in other lines: a
  lambda whose own walk ended well inside a declaration that gave up, a demand judged before a later
  step passed the budget, an entry line, a group that did not settle. `Check.gaveUp` refuses at the
  limit every accepted line a walk made once it gives up. Enforced, a line refused at the limit is no
  `list_still_used` error where the module has a limit: the limit is the error.
- Item 3: `overlapIndexed` charges at most what the scan it replaces charges, per caller.
- Item 4: `typeStep` shared by `typeAt`/`typeAtPath`; `Loc.placeAt` has its doc.
- Item 2: every safe-build check runs quiet (`Mod.quiet`, `Frame.quiet`): it restores every count,
  and a safe build panics where a check builds an entry of the location table, a place, or grows a
  list or map of the frame (kernel §9, last row).
- Fixture: `check_test` "a walk that gave up accepts no send" (three files; each part proven by
  reverting its fix). The root dumps script joins chunks as bytes.

**What I learned**

- The drift of item 2 was latent: two mutants (one that panics when a check changes a count the old
  code did not restore, one that panics when a check grows frame state) found nothing on 2 508 roots,
  and a third (panic on entry) showed the checks run on 1 851 of them. So no module near its budget
  differed between ReleaseSafe and release; the guard keeps it so.
- `s += chunk` in a Node dump script splits a multi-byte character at a chunk boundary: two dumps of
  one program differed only by U+FFFD.
- Evidence: root dumps differ only in `WideModelArms` (a module past its budget: 512 lines now
  refused at the limit); ledger 309 of 319; 133 293 sweep programs dump-diffed, 4 changed (all
  `bounded-walk` LIMIT programs, LIMIT under the four legs); `row-words` 27 013 rows, 0 crashes.
