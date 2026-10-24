## 2026-10-24 17:00 CEST — F6 and c7, and what c6 and F2 measured

**What I did.** #936's fixed items F6 and c7, kept; c6 and F2 measured, then dropped.
- F6: `Inline.beni`'s `keyedRow` no longer cuts the filtered rows with `.slice(0,1)`. A keyed table's keys
  are one `case`'s string patterns, and a repeated pattern is `redundant_pattern`, so at most one row
  matches.
- c7: a subscription's remover is handed to `own` where the start returns it. One declaration's
  send is `a=>e(l,a)`, not `a=>{e(l,a)}` (`inline.zig`).
- `browser-inline.md` §3 and §8.4 have the dated amendments. 14 release goldens moved. No page
  transcript changed.

One-file brotli of unique-components, seeds 1–3, with E2 and E5 as the base: N = 1 −11/−8/−3,
N = 16 −10/−36/−47, N = 64 −6/−69/−51, N = 256 0/−47/−55.

**Dropped, with measurements.**
- c6 runs the list `first` returns, not `passes(table.flat())`, when every entry is in a bucket.
  As built it is N = 1 −2/+1/−11, N = 64 +24/+46/+59, N = 256 −55/+72/+29: the short names shift
  across the whole mount, and Opt leaves a copy `let Sa=Ua`. The patch is at
  `~/worktree-evidence/s1-936/c6-dropped.patch` on dagon.
- F2 is default parameters for `prop`'s and `on`'s optional argument. I measured it first as a
  hand edit of the real outputs, which is the best case: N = 1 −3/−8/−12, N = 16 −16/+7/+4,
  N = 64 +16/−3/−16, N = 256 +52/+31/+16. It needs a new Opt and Print feature and does not pay
  past N = 1.

**What I learned.** A fixed-cost change that renames a top-level binding is noise under brotli at
large N, because every later short name moves. Price it on the real outputs before building it.
