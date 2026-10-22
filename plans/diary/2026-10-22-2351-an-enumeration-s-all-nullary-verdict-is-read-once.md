## 2026-10-22 23:51 CEST — an enumeration's all-nullary verdict is read once

**What I did**

- Probed how `check` scales in shapes other than record width, with the record
  fixes of #795, #798 and #800 in: case arms, call chains, list literals of
  records, top-level constants and `==` were all linear except `==` on an
  enumeration: n comparisons of an n-constructor all-nullary type cost O(n²)
  (877M instructions at n = 8 000), because `Instances.allNullary` read every
  constructor at each comparison (#808, part of #464).
- Kept the verdict per type in `Resolve.State.nullary`; added a `test-perf`
  scenario at n = 4 000 / 8 000 (ratio 2.9 before, 1.9 after).

**What I learned**

- A type with a payload on its first constructor never showed it: the loop
  stops at the first constructor with arguments, so only enumerations pay.
- 8 000 comparisons: 877.3M → 301.6M; the dashboards and the 100k corpus do not
  move.
