## 2026-10-15 13:18 CEST — Finish the ownership oracle review boundaries

**What I did**

Answered the explicit review on PR #132. A single syntactic read in a deferred
initializer body no longer qualifies for private transfer. Added a repeated-row
refusal and fresh-payload twin, plus checker-level direct-read guards. Removing
the fix makes those guards fail. Function-bearing private sources remain shared
under #116's explicit backstop; removing that guard makes its refusal fail,
while a copied returned spine still passes. Liveness controls now thread through
Result cases, Chain cases and entry expressions.

Scoped pending transfer authority to the module initializer, excluding callees,
traversal/focus summaries and runtime-entry bodies. The new init-frame hole
catches four interpreter disagreements if a cached callee borrows that authority
across relative allocation sites. The final set has 173 verdict fixtures,
496 targeted programs, twelve new required holes and 23 caught targeted controls.
The source-removal failures and restored results are retained with the evidence.

Repeated both bridge bounds on the reviewed implementation bd580027d. CI:
945 inputs, 462 value checks, 6 forward / 8 reverse leads, zero confirmed unsafe
originals. Full: 116,635 inputs, 43,180 value checks, 1,725 forward / 401 reverse
leads, zero confirmed unsafe originals. Historical generator/enumeration hashes
match, and all 401 historical reverse refusals remain unchanged. The 179 added
fixed programs contribute 114 translated agreements and 65 counted skips.

The in-build audit passes with 3,258 constants. The independent clean-checkout
audit passes with 32 parsed sources and 4,718 replayed constants, only the four
pinned dependencies on the three existing unproved statements. Hosted Linux
tests pass without hardware budgets. The hardware-budget gate remains owed on
supported x86-64 Linux; the local constituents retain the two documented macOS
case-folding failures. The evidence is updated before the follow-up review
request; PR #132 remains unmerged.

**What I learned**

Removing a private publication never grants an exclusivity certificate: the
review's duplicated-row scenario was already blocked by separation checking.
The direct-read eligibility contract still needed an independent guard. Transfer
authority must also be absent from a callee's summary environment, so caching
cannot make a result depend on the module's pending permission. A planted hole
that changes a verdict but agrees on its finite input is precision evidence,
not a caught unsafe execution.
