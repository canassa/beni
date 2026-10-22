## 2026-10-22 23:30 CEST — TypeKeys sorts by text with the checker's one text sort

**What I did**

- After #795, #798 and #800 the synthetic dashboard of W fields of records was
  close to linear, and the largest cost left that grew with W was
  `TypeKeys.build`: every record key and every distinct row of the record
  facts sorted its fields by text with a comparison sort whose comparator
  compared the names' bytes, since a project under 16 384 names gets no text
  ranks (#806, part of #464).
- Routed every TypeKeys text sort through `TypeStore.sortByText`, which writes
  the same stable order, and skipped re-sorting a row that is in symbol order
  already.

**What I learned**

- The text-rank threshold keeps small projects — the dashboard is one — on byte
  comparisons; any comparison sort by text there is O(n log n) byte compares.
  `sortByText` is the one place that already does it in linear passes.
- W=512: 312.8M → 153.3M; N=64: 205.2M → 203.1M; the 100k corpus, which has
  ranks, does not move (967.2M → 966.9M).
