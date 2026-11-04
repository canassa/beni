## 2026-11-04 12:33 CET — Schema guard and nullary coverage

**What I did**

Finished the review fixes for #1850: kept its allocation golden narrow, moved the core-source anchor out of the corpus executable, and made missing-accessor checks distinguish dangling references from dead-code elimination. Added constant-comparison coverage. Took #1856 after the new assertion exposed unsafe nullary sharing. The sharing pass chooses a literal covering every copy, breaks ties by module name, and writes that literal at the earliest declaration; conflicting or incomparable copies stay separate. Added a runtime regression and field-coverage unit tests.

**What I learned**

The old compiler prints two empty objects in NullaryCoverage: identity-only use prunes an early Nothing to {}, and later host readers incorrectly share it. The covering literal restores both reads. Jobs 1 and 8 emit byte-identical trees, including when two full copies tie. The repaired fixture grows from 302 to 320 raw bytes and 164 to 172 brotli-11 bytes. A symmetric null-padding assertion was insufficient: pruning can remove the tag too, so the invariant is that the kept literal covers every field of every dropped copy. An unused schema accessor may likewise disappear legitimately; source anchors and emitted-reference checks protect different facts.
