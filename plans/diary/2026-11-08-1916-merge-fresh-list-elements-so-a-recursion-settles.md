## 2026-11-08 19:16 CET — merge Fresh list elements so a recursion settles

**What I did**

- Took #1004: `ff xs ys n = if n ≤ 0 then xs else ff (List.map xs λv → List.foldl ys v λy a → a + y) ys (n - 1)` dumped `summary ff (cap I)`. It still reproduced on master `42335951c7`.
- Wrote the fix that the issue asked for: compare deps sets as sets under the renaming. `ff` still capped. A debug print of each round showed the real cause.
- Added `foldFreshElem` to `src/writes/Writes.zig`. In a composed `kept` update, a callee element and one of the argument's elements, both at `[*]` and both `Fresh`, become one element. Its deps are the union. The callee element's own root is replaced by what the argument's elements depend on.
- Wrote a dated amendment to `docs/design/write-sets.md` (2026-11-06, #1004). The owner chose this fix over a change to the §3.6 deps rule (dashboard, 2026-11-08).
- Pinned the case as `addAll` in `tests/corpus/writes/UpdateRecursion`. Before the fix: `summary addAll (cap I)`, `value ρ.xs`. After: `node ρ.xs ⟨kept⟩; value ρ.xs[*]`. It is the only golden that moves.
- Opened #2102 for the two causes that this change does not fix.

**What I learned**

- The deps order that #1004 names is not the cause for `ff`. The fold's `Fresh` holds the closure's whole environment (§3.6), so the element depends on `xs`. When the update is composed, `xs ↦ map xs f` adds the new element root to the old element. The two deps sets have different sizes, so no comparison of sets can make them equal.
- A loop that maps its list in its base case (`h1`) also caps on master. An `Alt` keeps alternatives that are equal up to renaming. The deps-order defect is real, but it shows only after that fix. Both are #2102.
- Test a prescribed fix against the issue's own repro before you trust it. A debug print of each fixpoint round found the cause in minutes.
