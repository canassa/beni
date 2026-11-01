## 2026-11-01 16:37 CET — reconcile upstream write accounting

**What I did**

Retained the first merged-tree gate failure and replayed its failed unit shard
with the identical ELF and unchanged 1000 ms CPU budget. The shard passed
95 tests with one skip; native attestation used 597 ms CPU, compared with
1019 ms during the full concurrent run. No budget or test was changed.

Compared the complete TodoMVC write report from the other gate failure.
Only four work/reset pairs changed by three. Upstream adds Dom.found, and
Writes allocates and charges three reset arrays per original declaration.
Updated those four pairs and verified the complete actual report matches the
new golden byte for byte. No verdict or proof changed. Removed the lone
stray diff3 marker inherited unchanged from upstream's comparison ledger.
The complete unfiltered gates must pass before this merge is accepted.

**What I learned**

Structural work accounting correctly includes new upstream declarations even
when all user-program write facts remain unchanged. A passing isolated unit
is diagnostic evidence; it does not replace the full gate acceptance.
