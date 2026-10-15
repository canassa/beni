## 2026-09-25 — R4a: the v2 harness; v1 is frozen

**What I did**

- R4a landed everything around the new checker with v1 unchanged: v1's scheduler, core gate and
  cutoff protocol moved (a pure move, checked line by line) into `src/check2/Check.zig`,
  `Driver.zig` and `Incremental.zig`; a hidden `--checker=v1|v2` (v2 checks the app package's
  modules, v1 core and dependencies); the checker id in every module's cache key (`key_version`
  3), with a test that neither checker reads the other's cache; a v2 stub reporting
  `not_implemented` ("checker v2: R4b"); and `zig build test-v2`, the corpus in report mode
  under v2 with the `v2-green.txt` ratchet (seeded with the 143 fixtures where v2 correctly stays
  silent on an already-poisoned module) and a validated `v2-expected.md`.
- The review confirmed v1 byte-identical over 397 fixtures in five modes, and 0aedf0a's own
  cache, cutoff, matrix and determinism tests pass against the new binary. It found that the
  ratchet files accepted lines naming no fixture; now refused, and every listed line must be
  visited.
- Owner decision: master need not keep working during the conversion. I kept v1 only as the
  oracle (it checks `core` and dependencies, which use dispatch v2 cannot check before R6–R8, so
  without it no program builds and the ~740 corpus goldens go dark) and froze it: no more fixes
  on v1; it is deleted once v2 checks `core` and passes the corpus.
- Gates green; `test-pending` 67 v1 + 64 v2 RED lines; `test-v2` 297 pass / 445 fail / 13 skip.

**What I learned**

- An escape hatch in a ratchet needs the same validation as the ratchet: a line that names
  nothing silently checks nothing.
