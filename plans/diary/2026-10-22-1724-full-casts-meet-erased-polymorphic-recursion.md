## 2026-10-22 17:24 CEST — Full casts meet erased polymorphic recursion

**What I did**

Completed the resumed candidate's Schema precision fix, trailing-cast identity,
folded holder/condition preservation and portable variable-key audit. The final
constructor audit found the old nonrecursive head shortcut; a red nested-Maybe
test pins its removal. Rebased over current Task/schema/emitter work and the
owner's repository-wide retirement of instruction budgets. Ordinary gates,
run-hash recording and the additional core/cast cross-checks pass. The earlier
WebSocket delay was the existing #695; the unchanged isolated retry and complete
serial hash refresh pass. Three development DOM hashes were refreshed.

The final generality check found #760. A pure polymorphic recursive wrapper
returns Js.from [ xs ] and calls itself on [ xs ]. Unchanged base b8724f19e
accepts it; the exact-full-type candidate rejects it at the 32-round limit. Its
cast types grow from List a to List (List a) indefinitely, so the stipulated
repeated-full-type fold has no repetition to use. Stopped under the owner's
rule, reported on #286, kept PR #748 draft and preserved both binaries, the
source and logs on dagon. The candidate is not merged. No caps or assertions
were relaxed and no approximate first cast was introduced.

**What I learned**

Finite source text does not imply finitely many instantiated cast types under
erased polymorphic recursion. A shared type DAG fixes duplicated trees, not an
unbounded type vocabulary. This is a separate design boundary from Schema's
fixed first-entry precision bug; it needs an explicit rule rather than another
head fold or a raised round limit.
