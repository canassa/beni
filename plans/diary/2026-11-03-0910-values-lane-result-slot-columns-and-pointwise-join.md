## 2026-11-03 09:10 CET — values lane: result slot columns and a pointwise join

**What I did**

- Branch `own2-cost-onehelp`, two steps on session 15's. No PR.
- **Step 1.** The manager's directive was "no caches". So both memos of result slots are now columns (`Dests.zig`):
  - the read-off's `(from, q, slot)` memo (`ReadOff.destsOf`);
  - `feedBelow`'s `(root path, entry)` memo of caller slots.
  - A read has one column, with an entry per slot it meets, kept in the slots' order.
  - Each entry is made once, from its nearest ancestor in the column: that ancestor's slots plus the remaining steps, one record a step.
  - A leaf's slots, a key's items and the slots below a call's slot are entered as one batch, before they are read.
  - Every summary is the same. Growth is worse nowhere and better in 31 accounts. Totals are down 8 431.
  - `Schema.shapeOf` 258 000 → 220 738. `describedHost` 6 927 → 4 956. `oneOfHelp` 179 864 → 145 432.
- **Step 2.** `Forest.unite`'s `.join` mode is gone, and a draft's join is pointwise, as §2.10 says.
  - `oneOfHelp` now takes 4 rounds and has no inference defect. Its growth is 113 150, still past the limit (#1765).
  - 22 roots' summaries change, and 11 lose a `fresh` below an open arrival. In each of the 11, the parameter's arrival stays at that slot.
  - Seven sanitised probes of that shape (`slot-build/cv16/pj`) call the function and edit the result's lists in place, with the argument live and with it dead. All accept or refuse as before, with 0 TRAP and 0 DIFF.
  - The emitted JavaScript of conduit and bike-wars under v2 does not change.
- For both steps: no verdict moves, and the oracle is unchanged (1 440 probes: 0 TRAP, 0 DIFF; prober: the 15 filed). The corpus has the same 104 failing cases as the base. Unit tests, build_test, wasm and fmt pass.
- Test workloads moved with the cost: `nearLimitModule` 91² → 93 × 92 and `groupFieldShift` 120 → 136. The R-7.4 ring's bounds follow its new ratio of 1.32. The band is now [1.25, 1.5], tighter than the old [1.5, 3], so the old growth with K (1.62) fails. Its ceilings went down to 3 000 and 4 000.

**What I learned**

- A column filled ahead over `belowAll(from)` costs more than the reads it saves. `shapeOf` and `shapesOf` went past the limit. Most reads meet a few slots of a large subtree.
- A column per batch costs more again when the same read is met from many batches, for example a key's later deliveries. Index the column by the read and make each entry from its nearest ancestor. Then a miss costs the steps below that ancestor, not the whole replay.
- Look at where the extra records go before you trust the total. Here a per-category trace showed `path` up 1 184 in four read-offs. The cause was the key loop entering slots for items that `Held` skips.
- Path ids follow the order of interning, so the `below` lines of `--ownership-below` can change their order with no change in content. Compare them with each index replaced by its slot name (`cv16/belownorm.mjs`).
