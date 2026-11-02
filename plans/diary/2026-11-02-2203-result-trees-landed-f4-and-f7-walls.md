## 2026-11-02 22:03 CET — Result trees landed; F4's rest and F7 hit walls

**What I did**
- #1714, values lane, third session, on `own2-cost-values`.
- Built the first F4 step. A contract's `res` and each supply's `res` are also a result tree. Its nodes are hash-consed by content in a new L2 file, `Trees.zig`. Every reader that asks one slot walks the slot's steps:
  - `instAt` and the key feed
  - `throughCall`
  - the uniform-atom test
  - a known label's answer at a slot that no place names
- The first cut charged one inspection per node. That broke the R-7.4 ring test's floor of 1.5 (the ratio became 1.48), so the walk is now charged the same as the scan it replaces.
- Checks at the head:
  - Ledger: no verdict, limit or summary changes, and the accounts are unchanged.
  - Oracle: all 1 659 runs are the same as base.
  - build_test: the same failures as base.
- Measured the owner's F4 question with a bounded experiment. A parameter's subtree read by structure becomes one open entry, and a call in a frame with nothing growing is described node by node.
  - Width test: passes, −779 at 100 fields.
  - `Schema.shapeOf`: 265 082 → 282 439.
  - Ledger: 15 positions accepted→refused. Most are cross-module `unknown`, because the block does not round-trip the new entries.
  - Not landed.
- Built F7's decided rule, a per-place saturating count over the place graph. It moves 29 positions to `disjoint (approx)` on small recursive types, so I stopped.
- Built a root-path variant. It moves no verdict and makes discovery cheaper, but it breaks test 132's plain half, because written out at K = 8 costs more than the symbol at 16. Not landed.

**What I learned**
- F4 cannot land reader by reader past the slot lookups. Every reader that needs all the slots re-expands the tree into flat entries, and the exponential comes back. The draft, the read-off, both instantiation paths, join, `within`, text and the block have to move together.
- Inside a solved group, the read-off reads a member's draft by flat slot, and each new fact is delivered by slot. A lazy by-structure reader that keeps `Schema.shapeOf` flat needs trees there too.
- `↓p` is coarser than the same slots written out in the distinct check's family reads. Every rule that makes more of `below` symbolic (F7) waits on that.
- A lower-bound cost test (R-7.4's "at least 1.5×") catches charge changes that only add constant work, so a new charge needs that test run too.
