## 2026-10-26 23:55 CET — the lazy merge broke identity

**What I did**

- I built the lazy merge position as specified. Its reads were correct (every block hash unchanged), but it made the K tower slower, so I stopped and reported it.
- On the manager's decision I dropped it and added a per-pair memo on the eager `kappaMerge` to #1123 instead (K: 66 562 at N = 40). The rest of K's quadratic cost moved to #1121.

**What I learned**

- Hash-consing gives identity only to normal forms. A lazy view whose links name unresolved merges is not a normal form, so two equal meanings get two ids. Every memo keyed by ids then misses: the join memo went from 154 states to 460 states with 0 hits.
- A memo on the eager operation keeps normal forms and reuses work. Try it before making an operation lazy.
- In the K tower, the cost that grows with the level is in reading cells and union sides, not in merging. Measure where the work goes before choosing a fix.
