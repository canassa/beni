## 2026-11-05 12:25 CET — Own a Ref.modify take and name each loan's cell

**What I did.** Built the first step of S8-ref (#1977, PR #1980). `Ref.modify`'s `.0` is now the callback's answer, owned when the stored `.1` keeps none of it, else a loan of the cell. `lent` rows are a `lent π1◆` arrival, read as `loan` leaves that hold only what they lend. §2.13.7 has the rule and the soundness argument. Four fixtures: `run/RefTakeOwned`, `RefTakeKeepsLoan`, `RefTakeWhileHeld`, `SanitiserLoanPerCell`. Oracle over 1 945 probe directories (1 917 judged): 0 TRAP, 0 DIFF, nothing accepted→refused. Every corpus dump matches master except three prerender roots that fail on both sides. The cost table is unchanged.

**What I learned.**
- A helper's edit of taken contents and a cell operation are the same slot, `π1◆`. Published shallow, the edit read as a cell operation and skipped the caller's loans, so the probe trapped. It has to be deep.
- `Cells.supply` looked only at the supply's root, so `Ref (Maybe (List Int))` labels were never cell labels and #1955's stored-answer escape missed them.
- Worded rows are published in blocks. Reverting the block format because "read-off never writes `lent`" made `Task`'s block unreadable: its importers read pessimistic contracts, and one probe went accepted→refused. Only the oracle comparison against master caught it; I reran gates after, and the block is now v20.
- `( steal r, old )` re-enters the cell through a helper, so `.0` looks like an unrelated capture. A capture's `◆` has to count as the contents. That one was a real trap, found only by probing.
- Running `beni build` inside `tests/corpus/run` leaves a `.beni-cache` there, and the corpus reads it as a fixture.
- `zig build test-run-hashes` does not exist on this head, and no `*.run-hash` file is tracked under `tests/corpus/run`, though CLAUDE.md says both. Digests go to the cache directory.
