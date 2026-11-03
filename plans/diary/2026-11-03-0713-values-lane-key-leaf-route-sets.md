## 2026-11-03 07:13 CET — Values lane: a key's leaf keeps its route set

**What I did**

- Defined the key-leaf route set in `ownership-v2.md` §2.3.5 and posted it on #1714 before writing code. It adopts `Value.Leaf.routes` as the resolve lane proposed. `expand` writes the sets out, and `expandRouted` keeps them.
- Built the values lane's side of the fold certificate through a shared DAG (`2aa8a316e9`):
  - The routed walk moved to `RouteWalk.zig` (L8). `⟲` is now one of its shared steps: descent items are merged under route sets.
  - `arrivalLeaves` uses the walk through `Eval.routed`, with no literal routes.
  - The distinct check's expansion, the read-off and `AtomSets` read the sets.
  - `Distinct`'s apart/plain helpers moved to `ApartPlain.zig`. `Routed` (L9) keeps the write targets.
- d_N went from 2 762 / 8 236 to 2 295 / 5 723 records. Without the holder index's demands it is near linear. The test is still red: `Holders.Walker.open` reads the key written out, and that half is the resolve lane's.
- Checks: the ledger moves no verdict and no summary; no account is worse in growth and 48 are better; every row of the cost table is down; the oracle is unchanged; wasm, the unit tests and fmt pass.
- Steps 3–5 are not built. Their causes and measurements are on #1714. Step 3 needs a manager decision: `Graft.fullAt` on a cyclic place, or grouping demands that have the same targets.

**What I learned**

- A walk item copied from the item being read keeps `read = true` and `more`. Every arrival at the copy then made a new item, so nothing merged. Copies need both reset (`withKid`).
- Charging each arrival and also each `project` call doubled the cost of every terminal item. The rule that kept the ledger flat: a merge is charged when it arrives, a walked item when it is read, and an emitted item by `project`.
- `emit`'s whole-value fast path interned every element twice. That cost one record per field ("call cost is flat in its argument's width").
- Writing a route set out costs O(depth) a route, because `RouteIter` merges a `pre` chain from front to back. A set that is cheap to keep can be costlier to write out than the leaves it replaced, so the readers must read the sets themselves.
