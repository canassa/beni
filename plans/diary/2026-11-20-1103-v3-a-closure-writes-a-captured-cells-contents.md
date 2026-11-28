## 2026-11-20 11:03 CET — v3: a closure writes a captured cell's contents

**What I did**

- Lane ref167, the checker lane of v3's cells and fibers (research report 165, slice 4). Landed its
  closure half: kernel §13 item 11 (`b7b23c6ba5`, `63674b3317`). A capture's cells are followed as a
  parameter's are; the holder judges the closure where it runs it: a direct call as before, a call that
  runs it within (`runsWithin`) as a demand at the call on the cell's latest version with its renewal kept
  beside the old contents (`maybe`), any other holder shares the handle and refuses the write. A store into
  a captured cell lets what the holder cannot name escape; a cell kept in a renewed cell is no answer of
  the function's own (`freshOwn`, `paramOwn`).
- `SanitiserCellReentryApart`, `SanitiserScopeHost` and `SanitiserNestedCallbackWrite` are wholly accepted
  and run in place (`.sanitize-lists-v3`). New `run/CellClosureWrites` (dead, 8 shapes) and
  `run/CellClosureWritesLive` (12 shapes, 13 refusals). `CellContentsInPlaceLive`'s closure twin was safe
  (it read the cell through the handle): it now captures a loan.
- `cells.mjs` has four closure writers (2 376 programs).
- The final review found a second class (thirteen programs): a callee that runs the closure again
  while it holds what an earlier run handed it. Refused (`handsContents`, `ab6e2b0ed2`), four more live
  twins.
- Evidence: v3 dumps of 2 486 roots, 0 accepted to refused, three programs newly wholly accepted;
  ledger 309 of 319; 43 sweeps, 101 199 programs, four legs: only the known `ListSanitiserTrieHolder`,
  `dom`/`tea` `ShowAndBranches` and `worded-bodies twice.unjudged-stored.live` trap; mutants of the new
  tests let 576 and 418 live closure-writer programs of `cells.mjs` through, each TRAP.
- Not built: the loan rule for a cell two fibers hold (#2581). Precision items filed: #2582, #2583, #2584.

**What I learned**

- An impure call that does not suspend can run other fibers: `Task.fromHost` drains the queue when its
  callback returns (`core/Task.beni:321`). So a fiber switch point is impure ∪ suspends, every `Ref`
  operation is one, and the loan rule needs new names at switch points and a published mark.
- A rule judged once at a call must hold for every run of the function within it: the second review
  broke the single demand with a callee that runs the closure twice.
- The first review found sixteen accepted programs that trap from one cause: a closure's renewal and its
  answer named one list it made by two keys. A renewal applied at a use must name the code's cells by the
  key its answer uses (`answerOfCode`).
- Sharing a captured handle where the closure is made hid a safe program (`k = λ⊤ → ints (Ref.get r)`
  before an update): a closure is no holder until it runs.
