## 2026-11-09 15:26 CET — fix the perf generators' removed tuple spelling (#2379)

**What I did.** `tests/blackbox/perf_test.zig`'s `aliasDag` and `argumentDag` wrote the removed
tuple type `( A, B )`; both now write `A × B` (language.md §12.7). I searched `perf_test.zig`,
`pending_test.zig` and every `.beni` under `tests/pending/` for the other removed spellings
(`->`, `::`, `let`, `\\x ->`, `()`, `Never`): none. The whole `zig build test-perf` then ran: both
alias-DAG scenarios are GREEN (ratio 1.00 and 1.39). Two others fail, and their generators are current:
`the ? default step` (ratio 3.95) and `merging variables that carry obligation rows` (120 s hang
guard). Both are the default ownership pass (v1); under `--ownership=v2` they take 20 ms and 122 ms.
Opened #2390 with the numbers; no bound changed.

**What I learned.** `test-perf` is not a gate, so a syntax removal breaks its generators silently;
`check --self-profile` names the phase in one run, which separates a stale generator from a slow pass.
