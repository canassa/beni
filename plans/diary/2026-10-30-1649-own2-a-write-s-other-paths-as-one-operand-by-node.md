## 2026-10-30 16:49 CET — own2: a write's other paths as one operand, by node

**What I did**

- Answered the re-review's blocker on #1329. A function that writes one field of a parameter and reads many paths of the same parameter through helpers (`top r = rall r.w.w + List.length (List.push r.l 1)`) put its caller past the `call_view` lane's ceiling. That is `ownership_accounting_invariant`, a defect: at 64 read fields, or beside a doubling DAG of depth 5. On master the same lane already failed with the reads written inline from 48 fields, and for a write 74 steps below its argument (`f74`).
- Cause: Transfer added one Disjoint operand per path the callee marked (§2.11 item 3), listed path by path by `Calls.marked`, all on the call's lane. §4.1's row for the call view forbids that: "Descending a group/graph requires corresponding original path atoms or pre-reserved growth tasks … do not eagerly copy their paths at every call." So this was a code defect, not a spec one.
- Fix:
  - `Transfer.otherPaths` walks the callee's use node for the written parameter, paired with the argument's value, each `(use node, value node, state)` once.
    - It keeps item 3's rules per path. Above the write: only when `A`/`E`. Never the write itself. Below it: only through `[*]`/`⟲`. The fold flag: `leafDepth(write) ≤` the depth where the paths part. `along`'s stay-on-failure is kept, as is `positionsAt`'s drop under `⟲`.
    - It adds one operand of the union of kept cells, plus the `excl` reliances. Demands reads an operand only through its reach, so the union is the same check.
    - A leaf of parameter cells, none of whose positions the base reaches, is not walked below.
  - That walk and the write path's own walk (`positionsAt`, `extendPath`) are growth chosen before the work.
  - `Calls.marked` lists `W` and `E` paths only; `touched` is gone.
- Counts, caller's records, no limit:
  - `top`: 132 at 64 and at 256 fields.
  - DAG beside a write: 134 at depth 5, 139 at depth 10.
  - Push chain (records of `f_n`): `f74` 4,168, `f100` 5,546. That is about 53 records per level of the write's depth.
- Three counted build tests pin these; all fail on the previous head with the invariant. Verdicts over the ownership and `run/` corpus: unchanged; only the PR's fixtures differ from master.

**What I learned**

- A per-path list built in growth (`Calls.marked`) and then consumed on a lane (Transfer's loop) is the shape the accounting invariant catches. The invariant means value-sized work on a fixed lane, and the cure is growth chosen before the work, plus not listing paths at all.
- The chain at 100 takes 1.3 s with the ReleaseSafe beni: 0.7 s checking (master is as slow at the same size) and 0.6 s printing a 478 KB dump. Its counted test uses one module of 80 and compares `f80` with `f40`, in 0.83 s.
