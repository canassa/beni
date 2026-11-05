## 2026-11-03 08:14 CET — values lane: one name per key item's slot

**What I did**

- Branch `own2-cost-onehelp`, from `own2-cost-joined` at `3168413f9e`. Two steps were pushed. No PR.
- **Step 1** (`10d5b103ca`). The read-off names a key item's result slot once per `(from, q, slot)` (`ReadOff.destsOf`).
  - Before, each item of a key below a prefix walked up to the prefix and replayed the steps below the result slot, one record a step, twice.
  - A hit costs one record. A miss costs what the replay cost before.
  - `oneOfHelp`: 251 712 → 182 461. `Fields16`: 149 250 → 137 922.
- **Step 2** (`96b18e5b59`). Where the prefix is the result slot itself, a slot whose canonical steps extend it is that slot. It is read off its name.
  - First I checked that over the ledger roots and core with a test binary. No slot differs.
  - Growth went to 0 for `shapesOf`, `fieldList` and `describedOf`. `boxOf` 6 384 → 1 708. `oneOfHelp` → 179 864.
- Both steps: every summary is identical, no account grows, and the oracle is unchanged. Unit tests, wasm, build_test and the corpus are the same as the base.
  - Three limit tests moved their workloads because the cost went down: `nearLimitModule` 88 → 91 fields, `groupFieldShift` 112 → 120.
- **Not built:** `callNode`/`canNode` on cyclic places (the brief's step 2). Measured and posted on #1714.
- **Found:** the cause of `oneOfHelp`'s inference defect is `Forest.unite`'s `.join` mode, not the deliveries. A one-line pointwise join saves a round (→ 140 599). It changes 22 roots' summaries and moves no verdict. That is a decision for the manager, on #1714.

**What I learned**

- A node memoised by its place is exact only where the subtree's names do not depend on the path. Being "off cycles" (no cycle spans the slot) is not hereditary: a slot below such a slot can still be on a cycle. So nested slots must be said inline in the enclosing node.
- Even inline, an open param arrival on a cycle must be read slot by slot (§2.10). For `oneOfHelp`, a node with one does all its work and then falls back. The node path saved nothing there.
- Look for repeated work by distinct keys before redesigning:
  - `oneOfHelp`'s 519 items sat on a few dozen slots. Each slot was translated per item, and a per-slot name removed 69 k records.
  - Its projections were already distinct within a round. Nothing could be saved there.
- `Contract.join` with ⊥ is not the identity. It reshapes the other side's nodes (plain → open where a node has open arrivals). Then a validation round reads a coarser candidate than the inference wrote, and it fails `within`.
- `addr2line` cannot read Zig's DWARF 5. The nix store's `llvm-binutils`' `llvm-addr2line` can, with its warnings sent to `/dev/null`.
