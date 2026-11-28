## 2026-11-22 12:27 CET — v3 cells: two ifs, exact cell writes, reader fibers

**What I did**

- Lane prec177, the second precision lane of v3's cells, on `ownership-v2-design-review` after #2600's
  and #2601's fixes. Three commits, each with a `run/` live/dead twin pair proven on the base.
- **Two `if`s in a row** that write one cell, then `Ref.get` (blind round BM's `twoIfsOneCell`; not a
  regression of #2599, refused at its parent too). An atom found through an arm of a join inside
  another join kept only the inner arm. It now keeps a meeting of the innermost and the outermost arm
  (kernel §6 rule 7, amended). A meeting of every arm on the way made `check_test.zig`'s chains of
  `case`s blow up (26 s and 2.6 GB at 30 levels), so it keeps two; a write in the middle one of three
  `if`s stays refused. `run/CellWrittenInTwoIfs` and its live twin.
- **A cell's row hands the write what is at its place** (kernel §13 item 2, amended). `Ref.update`'s
  function parameter is a type variable, so the supply read every part of the contents at each
  written one: a push onto a list of lists wrote the elements too, and a writer fiber that inserts a
  fresh list into a `Dict` in a fold was refused at its later runs (AZ's `cacheFiber`, the `Dict`
  writers of #2594). `ownSupply` now reads exactly, as `answerOfParam` did for the answer, for a
  cell's row only. The first adversarial reviewer found seven wholly accepted programs that trapped:
  `List.push d el` with `el` a loan of an element of `d`, then a write of the element. The call's
  other operands are compared again with every cell below the written place (`DemandIn.reach`).
  `run/CellWriterStoresFresh` and its live twin.
- **A fiber that only reads a cell** is a reader (kernel §13 item 12, amended): it runs at the switch
  points as a writer does, shares nothing and is never revoked. Before, it shared the handle and
  every writer fiber of the cell was revoked (AZ's `p5/w6`). `run/CellReaderFiber` and its live twin.
- Evidence: root dumps on the base and the head, only the new fixtures and
  `CellContentsAtTheirPlace(Live)` change (two duplicate refusals at one position gone), none accepted
  to refused; the ledger 309 of 319, unchanged; `cells.mjs` dump-diffed (5 081 of 34 736 programs
  change, none whole to part) and the changed ones through the four legs: 0 faults (two timer-order
  differences of `park` programs, SAME on three reruns each); `dicts`, `records`, `nested-arms`: no
  dump changes. Two Opus reviewers: the first found the seven programs above, the second (85 programs
  on the final head) none.

**What I learned**

- A worded row over a type variable reads every cell of the instance at its one entry. Making the
  write exact is right for what the function writes, and wrong for what it can store: aliasing comes
  from stores, so the operands must still meet the deep reading.
- Contexts as single arms lose facts in sequences of joins; as full conjunctions they multiply atoms
  by the ways through a DAG of joins. A bounded meeting is the cheap middle.
- Left open: the mark `noteParked` puts on a handle whenever the body stored anything before a park,
  fresh lists included (AZ's `p5/w3`, `apps/counter`, a fold writer that pushes a fresh list and
  parks); BN's undo app, whose `case`-joined renewal makes two parts of one cell look shared (the
  `disjoint` refusal, and the per-function limit when a `List.copy` is removed); #2580, #2587, #2582,
  #2589 and the BM/BN/BK shapes the manager listed.
