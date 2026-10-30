## 2026-10-29 21:26 CET — Ownership v2: a recast among an actual's sides is read approximately too

**What I did**

- The review of #1242 found that `argCells` added `⊤` only when the actual itself was a recast. A
  recast that was one side of a union, choice or positions actual (`if c then f a else xs`) was
  still read shallowly, so `sep` said `yes`.
- `recastAmong` now walks the actual's union, choice and positions sides at its own path, in a
  growth task (`Shape.dagWalk`). When any side is a recast, the read is approximate and holds `⊤`.
- Added union and choice twins, and the reviewer's cyclic fixture,
  `U = union(leaf{π0}, delta(U, {[*]: site}))`, which reaches `imageCells` through `graftTied`.
  The twins are red with the shallow check, and the cyclic image is red with `imageCells`' old read.

**What I learned**

- "Is this node a recast?" has to be asked of every side at the same path, the question
  `Pre.unionSides` and `Cond.innersOf` already ask.
