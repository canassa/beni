## 2026-11-02 01:32 CET — own2 data-oriented S0: counters, census, trace replay

**What I did.** Added the measurement S1–S6 are judged by (#1646). `-Downership-v2-counters`
(hidden, off by default, refused by `gates`) counts per table-resident dictionary, column and pool
what is asked of it, and prints a census at the end of a module's v2 dump: set and κ-map
cardinalities, per-node attribute demand, and whether `Shape.Table.tie` changes a kind.
`-Downership-v2-trace=<dir>` also writes each dictionary's operation trace, which
`bench/own2-dict/` replays. All of it lives in `src/own2/Counters.zig`; the hooks are one-line
`inline` calls that compile to nothing when off. With it off, the v2 dump of all 356 ownership
corpus targets and of core is byte for byte master's, accounts included.

**What I learned.** `tie` always writes onto a fresh placeholder (leaf to the real kind), never
re-ties, and no reader asks a placeholder's kind first. `widen`'s class nodes behave the same
way. So a kind is write-once before first read, but it is not known when the id is made.
Most cell sets in a node are empty or single. Numbers are in the pull request.
