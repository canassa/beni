## 2026-09-25 — R2b: one calling convention

**What I did**

- `src/check/Convention.zig` is now the only place that decides how a constrained value is
  defined, called and treated at load time (`checker-v2.md` §12.5), for `Lower`, `Cycles` and
  `Emit`'s `foreign` check 4, and whether a derived function takes its evidence positionally or
  as one array. Dispatch bytes v3 carry the `convention` column; importers derive theirs from
  the interface through aliases.
- Closed CK-33 (`same = (==)` and cross-module constrained function constants emitted with the
  wrong shape), CK-34, and CK-84, which R2b found: an imported constrained function typed through
  an alias was eta-expanded at arity 0 and threw.
- The review found that R2b, following §12.5, let a `where` exempt a point-free value from
  `cyclic_value`: `h = compose h g` checked and overflowed at its first call. I ruled for
  `language.md` §7 (a guarantee-protecting refusal must not depend on an annotation); the fix
  changed only the cycle reading.
- Also from the review: `constrained_constant` no longer refuses `pub same = (==)` (rule 7);
  `foreign` check 4 reads `Convention`, which un-refused a correct `foreign` typed through a
  concrete alias. The body of a zero-parameter `where` value now runs per use: documented in
  `language.md` §6, pinned by a fixture, and CK-85 schedules one-evaluation-per-call-site for R8a
  (owner, 2026-09-25). New CK-86 (the `exposing (Box, Box)` hint) for R13. Catalogue: 86 entries.
- Gates: 482/482 unit, 299/299 black-box, fmt-check; `test-pending` 76 RED, 0 GREEN. No existing
  `run/` or `emit/` golden moved.

**What I learned**

- The design document itself was the bug here: §12.5 prescribed a reading that contradicted
  `language.md` §7. Reviewers must check the spec against the other specs, not only the code
  against the spec.
- I timed the suites (`84e3cb1`, machine partly loaded): `test` 23 s, `test-blackbox` 5.1 min
  (bounded by `corpus_test`'s 5 min), `test-pending` 12.2 min, of which 11 min are timing
  scenarios running the old super-linear code in a Debug build, three times at n and 2n. A
  harness slice comes next.
