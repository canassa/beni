## 2026-10-31 05:21 CET — own2: towers counted, the push chain n log n

**What I did.** S3b 5d1 (#1419, #1420). I used a scratch build that charged each record to its
call stack, symbolized with `llvm-symbolizer`, and compared the profile at n and 2n. It showed
what is quadratic in each family:

- In a push chain over a parameter, each read of the chain joins its views again at the read's
  new position (`chainStored`, memoised per `(position, view)`).
- In K, each level reads the earlier levels' union DAGs again at its new position
  (`machine`'s `dag`/`inner` memo has the same key). Read-off also maps every entry of every
  position of a snapshot. K's snapshot has Θ(n²) entries in O(n log n) map nodes.

The fixes stay inside the design. A read depends only on what its one position stores at the
keys of the node's region and on the position's fold kind. So a read at a new position takes
the entry from the node's *home*, the last position it was stored at, when the two positions
read alike: `diffKeys ∩ region` is empty and the fold kind is the same. I specified this in
§2.11 *Part 2* as *A read at another position*. Read-off now maps entry maps per radix node,
memoised (`relabelMap`), which is §2.9's "κ submaps once". Results:

- The chain is 3 363 / 14 613 / 62 601 records at 10 / 40 / 160 (it was 3 464 / 21 444 /
  214 792), and 1 000 is accepted (424 909).
- K came to 10 172 / 22 952 / 49 894 at 10 / 20 / 40, and 1 000 was accepted (1 574 608).

Then I rebased onto #1408. Its `leafEntries` keys every node of the joined DAG at each level,
which makes K quadratic again: 15 751 / 54 772 / 204 833 on master, refused at 200. That is a
design question between #1399's rule and §4.1's bound, so I filed #1428 and did not count K.
The tests now count seven families at 10 / 40 / 160 and the parameter push chain
(`expectTowerNLogN`). The chain test fails on master. The diff of v2 dumps over all 2 009
roots, master against the branch, has no change in any verdict, summary or block. 693 roots
differ only in their `account` lines.

**What I learned.** Records are not time. K's walk was n log n, but the block writer's
`entries`, the safety check `kappaHoldsView` and the summary printer walk the Θ(n²) entries.
`dump` at K 200 prints a 13.9 MB summary line (#1426). W and T at 1 000 take about 5 s in the
ReleaseSafe self-hosted binary even with linear records, about 4 µs a record, so the counted
sizes stop at 160. T's block is quadratic, because it publishes one `apart` group per level
(#1427).

`Rose [r, r]` is still quadratic (14 449 / 54 449 / 215 175, refused at 80). Its
together-join and its widen walk the tower's depth, and each projection of a `positions`
chain of depth d makes d new nodes. One trial linked the member's snapshot below a
together-join of one value twice. It cut the walk but changed two published blocks, and the
widen was still quadratic. I dropped it. The fix needs widen, and the literal's walk, to work
on the shared graph and not along projected paths (§4.1). How to do that is a design question,
so #1420 stays open.
