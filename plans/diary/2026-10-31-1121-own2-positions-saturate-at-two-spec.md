## 2026-10-31 11:21 CET — own2: positions saturate at two, spec

**What I did**

- Specified #1368's proposal in `ownership-v2.md` §2.3 *Saturation at two*, with a sentence in §2.9's
  multiplicity bullet, the #1368 debt row and question 9. It is a merged positions node. A `positions`
  constructor keeps each member at most twice, and the κ home question has an empty answer: no snapshot
  keys a side that the constructor drops.
- Prototyped it in scratch copies of master `f8ec23cbe`, with and without #1459 (5a). All 2 043 roots
  have byte-identical verdicts and summaries, and six blocks are smaller. The full cross-check of the
  ownership corpus fails the same set as master.
- Measured `mergeSort`'s walks with a per-walk, per-reader attribution and a port DAG dump (scratch
  only).

**What I learned**

- The issue's diagnosis is stale on master. Since #1384, no positions node in `mergeSort`'s walks holds
  a member three times, so the cap never fires there: 168 829 records, unchanged. With 5a it fires:
  255 549 → 227 295. `mergeSort` stays loud either way.
- A reader-side cap cannot help. The readers already aggregate in `{absent, one, repeated}` and memoise
  per node. A DAG's read joins every node's stored entry, so it cannot stop early.
- The real cost is one branch-join `propagate` over two states (46 644 of walk 4's 88 640 records),
  reading a port DAG that grows about 3× a round (15 / 67 / 183 nodes). Choices made by `proj` or `map`
  are not flattened, which accounts for 183 → 86. Rounds that nest `res[*]` in place at a place on no
  cycle account for the rest. Neither needs S4.
- The cap is a large win for #1420: `Rose [ r, r ]` 215 175 → 31 620 records at 40 levels, and it is
  accepted at 80 and 160.
- `std.c.getenv` needs libc, which beni does not link, so a scratch debug switch is a `pub var`.
