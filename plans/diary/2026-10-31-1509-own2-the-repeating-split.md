## 2026-10-31 15:09 CET — own2: the repeating split

**What I did**

- Fixed the HIGH hole that #1473's review found (#1478). `List.push xs el`, with `el` taken from `xs`,
  makes a list that holds `el` twice. A second match on it records `shared` as its split's κ. But a
  deep read of `rest[*].0` gave `excl` of the refinement's canonical cell, `π1[*].0`. That cell names
  the parameter's positions, and the rest's positions repeat one of them. Master accepts the program,
  and so does v1. On #1473's head it was accepted only through §2.9's two rules.
- The fix is `KappaRead.repeatingSplit` and `exclOf` (§2.9 *The repeating split*). No `excl` of a
  frame cell stands for many positions (an `others` or `below` side) of a split whose κ fails. Every
  frame `excl` goes through it: `summaryExcl`, `shallow`, `classesRead`, `TransferBeside` and the
  read-off. Rules 1 and 2 also need the side's own split to hold.
- `dropCovered` now keeps a side whole when any of its choice nodes owes a fold condition, not only
  its root.
- Added `o/PushedPositions` and its imported twin: `List.push xs el`, `[ …xs, el ]`, the
  head-and-rest duplicate, an edit in the same frame, a `[ x ]` binding after the call, and two heads
  of `List.set xs 1 p`. All are refused. The copied prepend stays refused, and `bump` stays accepted.
- Results: no `res` path is weaker than the branch's base, and the records are 6 049 652, as before.
  The re-walk shows 0 mismatches in 1 677 walks. The cross-check fails only v1's five panics. The
  families and the gates are green. Opened #1478 for master and v1.

**What I learned**

- "Disjoint index ranges of one list" is true of the list that was split, not of the parameter that
  the canonical cell names. The two are one-to-one only while that list holds each position once.
- The first version of the guard also failed `elem` sides, and the corpus caught it: nine `res` paths
  went from `excl` to `shared` (`StoredBack`, `GroupAnswerCover`, `HeldElementWrites`). One position
  of a repeating list is one parameter position, and only a pair of positions, or a rest, can repeat.
- Master moved to `043a524b5` while I worked. A diff against the new master mixes its changes in. The
  numbers above are against the branch's own base, `6c8e43e6a`.
