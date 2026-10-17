## 2026-10-17 13:34 CEST — pin the missing ownership fixtures

**What I did**

- Added the fixtures that issue #272 lists as missing: `AliasWriter` (rule 9: a writer called through a top-level alias, and the eight-name cap), `NeedLabels` (rule 11: one exact and two approximate `need` lines), a rejected twin in `HostValueOnePlace` (`stale`), `SplitCap` (the eight-cell probe of a supply and its whole fallback) and `LimitOwnedAtoms` (the `owned-atoms` limit, end to end).
- Added the build option `-Downership-full-cross-check`: it compares the indexed spine condition with the pairwise one for every value, not only for values of eight entries or fewer. The gates refuse it. The whole black-box suite passed it (`-Dtest-budget=0`, 1 min 40 s), with no difference.
- Measured the `conditions` limit: a list literal of n list parameters costs O(n⁴) time and memory in `storedCond` (n = 200: 203 G instructions, 2.75 GB; n = 300: killed at the 10 GB cap). Opened #293.

**What I learned**

- `value-cells` is pinned by #290. `entries`, `path-entries` and `conditions` have no end-to-end fixture: a program that reaches `conditions` passes 10 GB first (#293), and `entries` needs 2¹⁸ use entries. The unit test "a summary past a limit says which and what it measured" still pins all three.
- A probe of beni on a generated input is a heavy job: an unlocked, uncapped run at n = 1500 started an out-of-memory kill of the whole machine. Run every such probe under the lock and `MemoryMax=10G`, and start small.
- With the full cross-check, `WideModel` costs 4 711 M instructions, over the budget; that is why the option needs `-Dtest-budget=0`.
