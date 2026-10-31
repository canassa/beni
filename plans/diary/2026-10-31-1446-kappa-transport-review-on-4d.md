## 2026-10-31 14:46 CET — κ transport: 4d's review items (#1459)

**What I did**

- Rebased onto 4d's head `4c96357b6`.
- **Below the root.** `Summary.dropCovered` now carries a dropped choice's joined entries below the root too. It transports the snapshot through the projection correspondence, with each choice node of the dropped DAG mapped to the kept root (`DropCarry`). The reviewer's repro is a `Summary.zig` test: it read `yes`, and now fails as it must.
- **Filter reads.** Read-off's filter now charges its reads on the walk's own charge, so the lanes and the growth limit see them. Its answers are memoised by `(key, condition, position)`.
  - K inside a recursive function is quadratic in records (452 124 at 40 levels); it is so without the filter too (407 364).
  - It stops at `ownership_summary_size` at 80 levels in about 14 s on a ReleaseSafe beni. 4d alone refused it at 20.
  - A counted test at 10 / 20 pins it.
  - 4d's `mergeSort` test now allows growth up to 5 000: the filter's reads are 4 045.

**What I learned**

- With the members' snapshots merged first, no source wrapper I built has a verdict that depends on the template-origin transport. In a scratch build with template origins switched off, `GroupJoinShared` through a wrapper, `t2` through a wrapper, and the build test's summaries all read the same. The entries are implied by the sides, so the fix is pinned by unit tests only.
