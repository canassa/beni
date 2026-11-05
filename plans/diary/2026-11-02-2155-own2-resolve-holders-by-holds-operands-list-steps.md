## 2026-11-02 21:55 CET — own2 resolve: holders by their holds, operands by keys, list steps indexed

**What I did**

- Third session of #1714's resolve lane (branch `own2-cost-resolve`, rebased onto the values lane's
  `815eea2dc`). Three commits, each checked by the ledger, the oracle probes and the cost table.
- Built §2.8 *Holder entries judged by base leaves* in a new file `Sweep.zig`, split from `Holders.zig`:
  a holder's holds are listed once; a parameter's base key carries its position, so a parameter's target
  visits only the buckets at related positions; every other holder is aggregated and judged once.
- Added a use order: each bucket is a heap of holders by next use, read through a frontier that does not
  change it. A refused demand stops at its witness.
- Added `Worded.zig`, a module table of worded contracts by declaration and places. Under `--core`, each
  `List.push` call had its own contract, so no two calls shared a footprint.
- Added `Holders.Operands`: a call's argument leaves indexed by base keys. GroupRotate's cost was its
  operand check, not its holders, so I did not build the semi-naive round state.
- `Distinct.mayWithin` indexes list steps by kind below each ancestor instead of comparing pairs.
- build_test went from 32 to 27 failures: 144, 145, 137, 252 and the 30-arm choice flipped. 148 still fails.

**What I learned**

- The spec's "per-key count of live entries" for `T(t)` would over-approximate `req`. One aggregated hold
  used after the point gives the same union exactly.
- A logarithmic charge per heap operation makes a heap-based sweep n log n. That alone failed the 4.4×
  bound for sites. Charge sifts by their swaps, and do not pop and push a heap only to read it in order.
- A fixed contract built per call defeats every footprint share keyed by contract id. Look for that
  first when a liveness query costs one group per call.
- Sweep liveness (bound before, last use after) is not compatible liveness. In the `then` arm, the
  parameters the `else` arm reads are sweep-live, so ask one range query before a query per hold.
- 148 is now two separate quadratics. First, `distinct` expands one call root per round and regroups all
  entries. Second, `Walk.pendingRun` copies the operand stack at every call.
- Distinct.zig, Walk.zig, Groups.zig and Rows.zig are at their line targets. The next fixes need a split
  first.
- `ledger.mjs` reads split UTF-8 chunks as `��`. Strip it, and the characters around it, before you read
  a summary diff as a change.
