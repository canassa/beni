## 2026-10-22 00:23 CEST — the sweeps of facts 1, 2, 4 and 5 deleted

**What I did.** The second half of #637, stacked on #647: `sweeps`, `walkAll`, `checkedSweeps`,
`checkedSolve`, `count_logs` and `max_sweeps` go, with the `spec_sweeps` and
`spec_analyses_declined` counters. The rewrite's own walk of a stale statement stays until slice 6.

**What I learned.** Without `count_logs` the rewrite counts each statement it walks afresh. That
costs under 1% of the safety compiler's instructions on the measurement set, so no cache took its
place.
