## 2026-09-19 22:02 CEST — M4-3 landed after parking; nothing is in flight

**What I did**

- Landed **M4-3, the firewall cutoff** (`92cfca8`..`ed8385f`) without a new
  agent, as `plans/resume.md` said I would: rebased, four gates green, and by
  hand — a comment in a leaf re-checks 1 module (3 under M4-1), and the
  demonstrated miscompile (a private type's payload becoming a function)
  re-checks the importer and reports `NOT EQUATABLE`, identical to
  `--no-cache`. **The cache is now on by default** (`.beni-cache/`).
- Updated `plans/resume.md` §1 (nothing in flight) and the queue.

**What I learned**

- **The slice's own report named its two misses before I looked**: a `pub`
  signature edit still re-checks 624 of 634 modules (the spec predicted
  41–47 ms; it is 127–134), and the warm floor regressed 41 → 44 ms. The first
  is the design being SOUND rather than fast — the interface-hash term is
  load-bearing because the solver reads records of modules never imported —
  and the spec's prediction was wrong because it missed that the digest chain
  propagates a hash move transitively. Two predictions held within 5 %; the
  third was off 3×, and that is the one worth re-reading before M4-4.
- Incremental ≠ cold was never observed, across 180 edit scenarios; every
  discrepancy was a counter mismatch in the harness. The self-check, the
  coarsening assertion and the differential harness each earned their place by
  finding nothing in the product and four bugs in the tests.
