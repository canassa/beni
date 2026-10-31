## 2026-10-31 04:36 CET — own2: a fold through a part owes excl

**What I did.** Fixed #1422, a regression from #1411. `h a`, with `a` from
`QN a b c d`, writes `a`'s four children at `π1#QN.k#QL.0`, and v2 refused it
`disjoint` 16 times. The cause is the parts. `a` is a `below` refinement, so its
projections are parts, and their canonical cell is the one `π1#QN.0⟲`. When two write
paths folded through a parameter's symbolic leaf, `keepBeside` owed `excl` of that cell.
A part is not `origin == .param`, so the part was kept as a second object, and
`splitBeside` kept the anchor that the write's spine met (`.yes`) as well. Both now owe
`excl` of the canonical cell in a fold (§2.2, *A fold through a part*), so the summary
has pre-#1411's `xreq excl π1#QN.k⟲#QL.0` again. The fixtures `ownership/QuadChildren`
and `QuadChildrenImported` have v1's goldens and fail on master. Twins stay refused:
`fTwice` (`h a` twice), `fSame` (`a` at two children of one argument) and a caller
whose grandchildren share one list. v2 names these writes by canonical path, one demand
per child path, so the parity keys needed entries in `ownership-v2-known.txt`.

**What I learned.**
- `Place.extend` keeps a first return as a plain step. A part's path is rooted at the
  anchor's place, so `part a·#QN.k` gives four distinct cells, where the canonical
  position folds them into one. That is precise, but `Calls.Routes` no longer merges the
  child routes. On 4a + master + this fix, the quadtree's growth is 147 576 (70 707 before
  #1411) and T3's is 100 764 (72 363), with v1's verdicts. Filed as #1423.
- The 4a programs need `@ownership_summary_size(module, 4194304)` to get past the default
  allowance, both before and after this fix.
