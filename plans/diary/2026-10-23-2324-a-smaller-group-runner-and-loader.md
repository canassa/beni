## 2026-10-23 23:24 CEST — a smaller group runner and loader (#896, cause 4)

**What I did.** I checked cause 4's claim against the output. Dead-export removal already leaves
out each runtime function a page does not call (`CounterLocal` ships no `passes` and no loader).
S1's pages call all of them, even at N = 1: `ClearForm` selects two buckets, the push selects every
bucket, and the routes need the loader. So I made each one cost less:
- `passes` is `pass(Array.from(new Set(buckets.flat())).sort(byOrdinal))`, with no pass stamp.
- `entry` takes its ordinal from `push`, and one loop adds it to its buckets.
- `load` is `loadAll` of the one row its key finds, so `commit` is gone. `loadAll` maps its rows.
- A pass of every bucket of a row passes the row. A pass of every bucket of every row passes
  `table.flat()`, where the push used to list every bucket and grew with N.

The `ValidatedLoader` golden fell from 1 337 to 1 263 B brotli. Spec: §8.4 amendment.
`./rr check` passed 24/24.

**What I learned.** In each root factory, every binding still keeps `let d=c.a;k(…,d)` where the
old binding functions had `k(…,c.a)`. `Opt` refuses to move any read whose chain is rooted at a
name some statement of the declaration writes through. In a factory, the handlers write the slice
in place, so no slice read is folded, not even into the next statement. This costs bytes per
binding, so it costs on the slope. It is the next fix.
