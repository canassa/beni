## 2026-11-22 04:30 CET — v3: a later run's write of what an earlier run shared

**What I did**

- Lane fix174, #2598 (a soundness fault the code reader CR1 found at 8a70bc34cd). A closure that a
  callee runs twice (`List.map [ ⊤, ⊤ ] g`, a helper `twice`) writes the contents of a `Ref` it
  captured, then stores a list it made and lets it escape (`Deferred.complete`, a spawned fiber,
  `Queue.offer`). The second run pushed onto the first run's list in place. The fault is older than
  the precision lane: the binary of cb0b57f8e1 traps on all three programs too.
- Cause: `storedAtoms` dropped every `fresh` source of the renewal without its escape bit. Fix: a
  later run's write is refused (`escaped`) where the source has the bit, at a call that runs the
  closure within (item 11) and in a writer's run (item 12). `holderGivesNone` now reads the escape
  bit, renewals and supplies, as `freshOwn` does.
- One read-only Opus reviewer, four rounds. Round 1: 5 programs where one new list is at two parts
  of the contents (`( l, l )`), no escape at all. Round 2: 7 where the written part's old list is at
  a second part too (`( a, a )`). Round 3: 4 where the written part gets another part's old list
  (`( b, b )`). Round 4: no fault in 22 programs. Base accepts all of rounds 1 and 2: older holes. Each
  is now refused (`disjoint`): `freshElsewhere` for a new cell, `namesOld` for an old one, with
  `sameCellAt` to skip a list above or below the written one (a row's `fresh` names a list and its
  elements with one site; a dictionary's renewal names its values' old cells at the dictionary).
- Fixtures: `run/CellClosureStoredEscapes` (dead, accepted, runs in place) and its live twin (10
  programs, 10 refusals), each check proven by reverting it. `cells.mjs` gets `esc.*` (216) and
  `esc2.*` (60). Kernel §13 item 11 (three amendments), item 12 and §3.4 amended.

**What I learned**

- The class was wider than the escape bit. "A cell the closure made in its run" is safe for a later
  run only where no other location the contract names holds it, and "the cell's own old contents" is
  safe only where no other location holds them. The reviewer needed three rounds to walk the three
  directions; one pass over "where can the written cell be after the run" would have found them.
- Narrowing a refusal by layout (nested lists, field slots) brought the sweep's new refusals of
  safe-looking `dict` programs from 499 to 75 changed programs.
- Evidence: root dumps 0 verdict changes (2 508 roots); ledger 309 of 319; 133 511 sweep programs
  dump-diffed base vs fix: 75 changed (48 `esc.*`, 26 `dict.*.closOther` already refused, the new fixture), under the
  four legs: base 25 TRAP, fix 0 faults; 24 `esc.*.once.dead` newly refused (no rule counts a
  callee's runs).
