## 2026-10-26 03:15 CET — The positions kind through leq, widen and proj

**What I did**

- Answered the re-review of #1038 in §2.3, §2.9, §3.3, §3.4 and Appendix B of `docs/design/ownership-v2.md`:
  - `leq` puts a union on the right as "below either side" and compares `positions` as multisets.
  - `widen` emits a mixed-kind class as a `union` and sets a `folded` bit when it ties a `positions` node's sides together. A repeat across folded sides is `lost`, never `shared` (`FoldedPositionsLost`).
  - `proj` keeps the `positions` kind.
  - κ keys are relative to the value's root, so a snapshot is a trie whose child subtrees are the children's snapshots, linked rather than re-keyed.

**What I learned**

- A new node kind has to be threaded through every shape operation (`proj`, `leq`, `widen`, `map`) in the same pass, or one of them silently turns it back into the old kind.
