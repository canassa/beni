## 2026-10-31 16:03 CET — Strengthen imported-layout test authority

**What I did**

After full unfiltered gates passed on frozen cursor tree6cb0a4797ffa96a59853aba30d0fffda3b5d1f19
(318steps,2173passed,17skipped), strengthened the hermetic missing-imported-layout
fixture. Its own Program nominal now has a real phantom-parameter anchor scheme,
matching owner/constructor/declaration/kind metadata and a passing ordinary layout
validator. Only imported Hidden's layout is absent. This fixture has no BIR and
makes no claim to rerun current-source coverage. Production behavior is unchanged.

The exact registered target passes after the refinement. Final source/Debug binary
are re-frozen for manager integration and final integrated gates; the earlier full
gate receipt is deliberately NOT claimed for this test-text/diary-only tree.

**What I learned**

A semantic authority-loss test should start with valid own authority, not merely
present metadata. Checking the ordinary artifact predicate makes the intended
single missing imported-layout boundary explicit without inventing source types.
