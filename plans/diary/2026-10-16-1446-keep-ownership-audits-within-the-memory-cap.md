## 2026-10-16 14:46 CEST — keep ownership audits within the memory cap

**What I did**

I changed both ownership audits to replay one complete module per child process.
The parents keep the global checks and require exact module/count receipts.
Both parents reject duplicate declarations before delegation.
Lake requires the current audit executable and restores local artifacts for child imports.
I added controls for duplicate declarations, child errors, and wrong receipts.
The audit script now keeps its work directory unless every step succeeds.

The first capped build passed all 66 jobs and replayed all 4,842 constants.
Ownership CI and Zig gates passed.
One positive module replay and all seven negative controls passed.
The controls check both parents against duplicate declarations, child errors, and wrong receipts.
The first two control runs exposed incomplete test artifact overlays. I kept their logs and corrected both overlays.
The three general soundness obligations remain open under #165.
The PR also requires a complete independent audit of the committed tree before publication.

**What I learned**

Lean keeps imported compacted memory regions until the process exits.
Repeated imports accumulated those regions during the previous replay loop.
Separate processes release them without a new kernel exemption.
Module-only replay also needs a duplicate guard: a later import can replace an earlier declaration body.
The fail-closed guard does not resolve valid duplicate equation lemmas under #182.
