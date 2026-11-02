## 2026-11-02 23:26 CET — F4: trees through the read-off (work in progress)

**What I did**
- #1714, values lane, F4, on the work-in-progress branch `own2-cost-values-f4-wip` (six commits on `7e7874ab3`).
- A contract's results are trees only: drafts hold arrivals and whole subtrees, a commit unites them into one hash-consed tree, and every reader walks the tree. The flat result entries are gone.
- New files, a new layer under the contracts: `Forest.zig` (L3: tree readers, union, graft, text, effect-tree helpers) and `Conds.zig` (L3: conditions, split from `Contract`). The read-off moved out of `Eval` into `ReadOff.zig` (L10). Every layer from `Contract` up moved one place.
- Where nothing the frame reads grows and no place below the slot is on a cycle, the read-off describes a value once per (value, place) and a call once per callee node and place. Deliveries read a subtree by the slots each key asks.
- Reads are one tree a parameter; a call use of a parameter's subtree of more than 16 objects takes the callee's read tree whole.
- A parameter's whole subtree of more than 16 objects, read at its own acyclic place, is one open arrival; a caller describes the argument's value there.
- `Subtree.below` counts object slots over an acyclic place graph instead of walking paths.
- Text prints a kid equal to an earlier sibling as `.1 = .0` (also for reads: `π1.1 = π1.0`).

**What I learned**
- Base defect: a contract's `res` kept the draft's label numbers while its labels were sorted, so a `cb` arrival could name the wrong label (CallbackKeeps.keepThenHand: `.0.0 cb(π2…)` for `f`'s answer). The trees made the order visible. Fixed (renumbered with the sorted labels). The ledger moves no verdict; 41 summaries change, every one traced to the fix. Needs its own issue and fixture.
- An open arrival's projection must be judged by the whole subtree it names: the slot's own objects are empty for a record or a constructor, and the old "uniform/calls" tests were vacuously true there, so a by-structure arrival lost everything below it.
- By-structure continuation is exact only where no cycle is below the place: with `⟲` the result's level paths fold differently from the parameter's.
- Measured (Debug): w5 287, w8 1 575, w10 5 991 (linear in the depth 2^(k-1)); d12 105 (was a limit); wrapw 10/160: 328/64; width one−zero 25/100: 25/−50; doubling record and use-shape DAG pass. `Schema.shapeOf` 257 028 (base 256 618). Ledger vs `cv3/ledger/s1b`: 0 a2r, 0 r2a, 11 limit lines gone, none new.
- build_test: 53 → 53 failing; 5 flipped (doubling record, width, wide record, use-shape DAG, write beside a doubling DAG); 5 new, 1 fixed by a text update. The near-limit tests use `w4` as their cost generator, which is now cheap: they need another generator.

**Not done:** block v17 (the block still writes a tree's entries flat), the else-if chain call (≈1 968 at D = 8), best hold (resolve/liveness cost), writes/escapes/kept as trees, the spec's *as built* notes, the oracle probes.
