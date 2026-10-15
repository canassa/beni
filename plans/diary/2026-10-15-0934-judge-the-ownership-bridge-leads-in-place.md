## 2026-10-15 09:34 CEST — Judge the ownership bridge leads in place

**What I did**

Replayed all 2,358 original Zig-accepted/Lean-refused programs and their old
minima through both Lean interpreters. Confirmed 201 original divergences in
six minimal Zig rule patterns and recorded 2,157 original Lean precision leads.
Added six pending refusals, their executable Lean twins, complete compressed
judgments and reproducible triage/precision tools. Replayed the 18,747 translated
Lean-accepted programs to recover all 401 reverse leads and a deduplicated top
five pattern summary (272, 95, 18, 11, 5). Neither checker was fixed or weakened.
Updated the bridge report, contract and findings ledger. `ownership ci`, the Lean
build, all six focused pending cases and Linux gates passed; macOS gates had
only the same two known case-folding failures (1,297 passed, 15 skipped). The
full pending run also found the pre-existing ValueCommands signature drift.

**What I learned**

Persistent direct lists cannot judge in-place soundness. Comparing complete
oracle traces finds fold corruption even when final values agree. The old
persistent-runtime reducer erases 94 original divergences and introduces 113
in changed minima, so original/minimum classifications must remain separate.
Case and block results can lose later-use facts; capture-frame liveness, fold
feedback ownership, recursive environment results and callee-capture Disjoint
each have distinct minimal witnesses. PR #115 stays unmerged.
