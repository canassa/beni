## 2026-09-26 — R8a: one derived-context computation

**What I did**

- v1's root cause #4 ("can T derive eq/compare", answered 4–5 ways) is closed in v2:
  `check2/Contexts.zig` runs one joint eq+compare fixpoint per type-level SCC; `Derivable.zig` is
  the one verdict reading it; interface v4 publishes each row's context as `(param, method,
  slot)` triples plus rows for private types reachable from published terms (CK-89); a cache hit
  installs rows and recomputes nothing. R6a/R6b's stopgaps are deleted, including
  `refuseV2LibraryTypes`, so `--library` works under v2. D4: a derived function takes one
  evidence parameter per context entry. Also CK-40 (schema settling linear), CK-79 (field cap
  lifted), CK-85 (a `where` value memoised per evidence identity; the promise narrowed in
  `language.md` §6), CK-87.
- Reviews: the structural one found the fixpoint dropping a payload's `equatable` requirement, so
  v2 compared functions and printed `True` (CK-108); both found a `u16` evidence index panicking
  past 65 535 (CK-109, widened end to end). The adversarial review's ~1 800 fuzzed programs gave
  0 wrong answers; v2 accepted 163 programs v1 refuses. My perf run flagged CK-42 as regressed;
  20-run perf stat showed noise (2.16 vs 2.18).
- New CKs 107–117, among them CK-111 (quadratic nested-record `==` per use) and CK-114 (a record
  literal 2 100 deep refused), for a performance slice I am adding before R9; CK-117 records that
  §11.2's "nothing escapes a fixpoint frame" is false when a pass demands a group that merges.
- Bench (whole process, perf stat): v2 1.07× v1 on both generated corpora.

**What I learned**

- Measure a small ratio of differences with many runs before calling it a regression: the
  scenario's 7 ms difference turned one noisy run into a false alarm.
- A proposed invariant assert that fails on real fixtures is information, not an obstacle: it
  showed a spec claim was false, which is now a CK instead of a comment.
