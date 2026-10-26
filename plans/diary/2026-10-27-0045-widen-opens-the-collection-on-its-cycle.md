## 2026-10-27 00:45 CET — widen opens the collection on its cycle

**What I did**

- #1123: fixed `Shape.rank`'s leftover marks after a refusal (the in-progress set is now local to the call) and swept the other own2 memos for the same pattern. The tower test now catches the removal of each memo by its ratio.
- #1120 (PR #1125): `widen` opens a `union` or `positions` node met at a `⟲`, so its sides join its class. An empty side is no position, and a literal whose other elements are nothing is a link. The W block is now linear (56 452 bytes at N = 1 000) and reads exactly what the unwidened value reads. Folded #1124 in (`flat` charges its memo hits).

**What I learned**

- The old W summary read `lost` everywhere because widen kept the whole tower beside the knot. That loss of precision was a side effect of how widen was built, not what folding requires: opened, the reads match the unwidened ones.
- Comparing every corpus summary before and after (2 698 of them) is cheap with `xargs -P8`. It found the one change (an `Int` list's empty `[*]`) that no golden pinned.
- Growth in W, K and the new-object tower now all comes from the same place: a literal's or a join's root rebuilds `apart` over the whole reach at every level (#1121).
