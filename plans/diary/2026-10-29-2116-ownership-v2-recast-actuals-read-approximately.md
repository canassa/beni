## 2026-10-29 21:16 CET — Ownership v2: a recast actual is read approximately at a call (#1219)

**What I did**

- `Calls.Grafter` read a parameter's argument through `argAt`, and for a recast actual took the
  inner node's own cells, exactly. A recast stands for some value inside that node, not for the
  node. So `sep(π0, π1)` over `(recast@L(T [ L22 [ T k ] ]), k)` read no list cell and said `yes`.
- `argCells` is now the one read for all three sites: `cellsOf`'s `.param` arm, `imageCells` and
  `graftOne`'s node arm. Through `⟲` it reads the full preimage (`foldedCells`). A recast is read
  as its own cells and `⊤`, approximately, as `Pre.expand` reads one.
- The repro and a node image are in `Calls`'s tests. Both are red without the fix: the sep
  assertion with the whole fix removed, the image assertion with only the node arm's fix removed.
  The ownership corpus is unchanged.

**What I learned**

- Marking a recast's own cells approximate is not enough: a recast of a constructor with no
  object of its own has no cells, and an empty set compares apart from everything. A recast
  needs `⊤`.
