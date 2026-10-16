## 2026-10-16 22:40 CEST — Add the written-storage premise to the summary theorems

**What I did**

- #169, second slice (R1): `summary_sound` and `map_summary_sound` take `linked : LinkedWritesCovered …`. For every input array at a permitted canonical path, every input array in its link component is at a permitted path. `WritePermitted` mirrors the two cases of `CallSound.writes`.
- Tracked the reviewer's R1 witness as `StatementChecks/LinkSummary.lean`: every old premise proved at the linked pre-state, the failed conclusion (`no_call_sound`), and the new premise's refusal (`not_covered`). The `sorryAx` composition to `False` is gone.
- `Falsify.checkCall` counts a call that fails the premise as vacuous (`vacuousLinked`); `preOf` carries `preLinks`.
- Recorded in the plan how an accepted caller derives the premise: `applyCall` demands each instantiated write row against the live cells after the call and the other operand paths, and `Invariant.linkNamed` makes linked protected arrays share origins.

**What I learned**

- The premise has to speak of input arrays only. A clause over every linked array would exclude the read-only split `readBoth(rest, xs)`, which the plan keeps legal, and would say nothing useful about garbage.
- `applyCall` runs one demand per write and consume row with `otherPaths` as the Disjoint operand set, so the caller-side derivation is a loop extraction over that list, like the fragment's push lemmas but over a summary.
