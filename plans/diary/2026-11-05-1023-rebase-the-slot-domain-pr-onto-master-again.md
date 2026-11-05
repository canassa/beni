## 2026-11-05 10:23 CET — Rebase the slot-domain PR onto master again

**What I did**

- Rebased `own2-slot-pr` (#1954) onto `master` `e00cf1c6c`, 34 commits on,
  with `--rebase-merges` and the same exec step as last time: every file
  master did not touch is pinned to the original commit's version. Only
  generated v2 files (the known list, five `.v2.unchecked` goldens) and
  `build_test.zig` met master's changes. The goldens and the list took the
  branch's version and were regenerated at the end. `build_test.zig` merged
  cleanly, with master's change line for line.
- Master's eight new fixtures carried `.v2.unchecked` goldens that master's
  v2 wrote. The slot domain checks each one whole, so the goldens go. The
  known list gets 8 rows: `SuspendJoinEffect`'s six accepted cell demands,
  and core `Markdown` 1271:22.
- Gates green. Ledger against master's v2: a2r 2 (as before), r2a 62 (64
  before, because #1956's fix now refuses `PushedPositions`, as master
  does). Against the pre-rebase head: 0 verdict changes. Oracle: 1 657
  probes, 0 TRAP, 0 DIFF, every line the same as the pre-rebase binary.
- Force-pushed. The PR is MERGEABLE and CI runs. Updated the body's
  numbers and added #1955, #1963 and #1956's v2 side.

**What I learned**

- `Markdown.collect` folds onto a fresh `( [], refs )` and pushes elements
  of `Node`, a type that holds `List Node`. v2 refuses the fold's
  accumulator (`disjoint`, approx): the folded type's list reads as
  reachable from the folded list. v1 accepts. A probe without recursion in
  the callback is refused the same way, so the cause is the recursive type,
  not the recursive call. Master's v2 does not check the probe at all. This
  is #1713's kind, a refusal, so nothing is edited in place.
- An oracle runner must retry a failed plain build with `--core`: without
  it, 69 probes of the `i1963` set read as "does not build plain".
