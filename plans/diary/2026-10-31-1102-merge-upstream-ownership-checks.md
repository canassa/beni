## 2026-10-31 11:02 CET — merge upstream ownership checks

**What I did**

Integrated master f8ec23cbe into the accepted worker foundations to clear the
PR merge conflict. Kept upstream comparison diagnostics and generic entry
diagnostics. The only manual source conflict is the appended diagnostic enum;
upstream ordinals precede the new generic entry codes. Cache diagnostic integers
are scoped to the compiler build id in their keys, so no old cached diagnostic
is reinterpreted under this build.

Saved the complete unaccepted compact/typed entry integration, consumer correction
and nested-control regression in a full-index recovery patch and owned Git ref
before the merge. It will be reapplied after this accepted-base validation; no
candidate source or evidence was discarded.

**What I learned**

Master advanced through ownership checks while the worker checkpoints were under
review. The integration needs full gates on the resulting tree rather than a CI
claim inherited from the prior commit. This merge changes no decided worker
contract and grants no worker execution proof.
