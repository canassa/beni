## 2026-10-15 02:17 CEST — Close the initialization-transfer review boundaries

**What I did**

Answered PR #116's review by extending the class fixture with initializer arms
and chains, local-function reads, schema/markup second references and hidden
evidence parameters. Excluded evidence/identity-parameterized consumers and
sources using solved Dispatch rows, then bumped ownership blocks to version 6.
Stashing this guard changes the evidence twins from rejected to accepted.
Documented that ordinary top-level suspension is already rejected and that
ownership's lazy count memo relies on its current serial walk. The final local
gates again pass 1,297 tests with 15 skipped and only the same two known macOS
failures. The first pushed revision's Linux CI passed. No merge was performed.

**What I learned**

An annotated constant with where evidence may recompute when that evidence
changes, so written arity zero alone does not establish one-shot evaluation.
The consumer needs no hidden runtime parameters. Excluding an evidence-bearing
source is conservative; its empty-list test is not proof of real sharing.
Known private names inside schema conversions and markup still lower to top
instructions and count toward the single-read condition. The full applications'
sharing conclusions are unchanged.
