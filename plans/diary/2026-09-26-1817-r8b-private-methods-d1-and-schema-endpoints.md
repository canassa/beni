## 2026-09-26 — R8b: private methods (D1) and schema endpoints

**What I did**

- D1 end to end in v2: a private method answers dispatch only inside its own module; reached from
  another module, directly or through any wrapper and across any number of modules, it is
  `private_method` naming the type that hides it (interface v5 row status). ~60 hand probes and
  2 364 fuzzed comparisons found no hole. Schema endpoints go through the same derived-context
  fixpoint, and v1's schema property settle is gone from v2's path, fenced by `rules_test`.
  `plans/checker-rewrite.md` gains §1.1, the six-root-cause table with status by slice.
- Three review rounds again. Round 1: the lazy `via` join was exponential and ended in a false
  refusal (rings of schemas: 16 s, 1.3 GB, then "does not support =="), and v2 panicked on a
  definition followed by a separate `where` annotation. Round 2: the equality gate read an
  unchecked schema's unfilled `via` target as "no function", so `Basics.eq` on a function-holding
  type was accepted or refused by declaration order, and a heavy comparison elsewhere could spend
  an unrelated one's step budget. Fixed: an exact unit graph built from what each comparison
  reaches, a deferred gate checked in P5 once every group is done, a budget per fixpoint run.
  PERM (71 programs, 4 506 orders) now checks refusals by exact diagnostic count.
- New CKs 118–125; CK-122 (a `type alias` of a schema endpoint gives `internal` in both checkers)
  goes to a small follow-up before R8c, CK-123 (a polymorphic `via` target leaks a type variable)
  to the schema slices, CK-124 (frontend quadratic in schema count) unassigned.
- `test-pending-perf` failed once in five runs on `scenario/CK-42` under v2: its extra cost is
  8–10 ms, so the ratio is noise around the 2.5 bound. Added to R8c's scope. Bench 1.04–1.06× v1.

**What I learned**

- Two rounds found order dependence that the permutation scenario missed because it only checked
  that a refusal code appeared. A test that checks "some error" instead of "exactly these errors"
  hides the very bugs it is meant to catch.
