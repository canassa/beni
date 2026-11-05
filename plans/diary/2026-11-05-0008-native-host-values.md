## 2026-11-05 00:08 CET — Native siblings return host values

**What I did**

Specified the native host projection boundary before implementation. Generated public beni wrappers now construct Maybe and Result, while their private siblings return host payloads and individually recognized exceptions. Optional inputs and callback arguments are adapted in beni. Native validation checks both the original public recipe and its host projection. Expanded byte-exact regeneration coverage to map and form-control modules.

Added a black-box release-tag regression, proved red against the preserved base and green with the change, plus a runtime fixture for missing/null/undefined map entries, headers, JSON null and syntax errors. Native regeneration and focused tests pass; skill API regeneration changes nothing. Measured all 316 emit goldens and the size harness's pages before and after. Updated only five goldens that matched the base exactly; existing red goldens remain untouched.

**What I learned**

Returning the original nullable host value is smaller than normalizing it in JavaScript before the beni match. The final emit total recovers 723 brotli bytes (312297 → 311574), and the empty mounted browser and tea pages recover eight bytes each (1299 → 1291). HTTP (+30), effects (+26), and native message data (+36) retain local wrapper costs. The manager accepted those costs as explicit debt in #1923. Map membership and checked-data sentinels must distinguish valid undefined from absence without allocating an intermediate result object.
