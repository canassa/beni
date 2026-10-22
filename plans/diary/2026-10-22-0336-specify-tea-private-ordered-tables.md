## 2026-10-22 03:36 CEST — Specify Tea private ordered tables

**What I did**

Amended the ordered-collection contract with the owner's Tea decision. Jobs
and subscriptions keep W47 keys in private sorted arrays, binary searched by
Hosted comparison and edited under ownership. Prefix cancellation removes a
contiguous range. Documented why Dict and Set no longer qualify as keys and
the diagnostic and custom-comparator fixture required by that change.

**What I learned**

The ordered Dict representation cannot stand in for Tea's comparator-based
tables. Keeping keys' own comparison preserves equality of distinct values,
without an encoding or a new platform API. The original spec PR #664 merged
with its unit-function empty builders and all checks green.
