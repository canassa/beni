# CK-233 fixed — evidence, 2026-10-15

`../../CONSTRUCTIONS-RESULTS.md`, *CK-233 fixed*, reports what these files measure.

- `ci/audit.json`: the CI-bound bridge on the fixed compiler (0 confirmed).
- `long/audit.json`, `long/base-audit.json`: the long campaign on the fixed compiler
  and on master `927b7dcd4`, the same inputs (0 and 1 confirmed).
- `long/base-vs-fixed.txt`: both reports' counters, every precision pattern whose
  count changed (none), and every lead case whose demand lines differ.

Compilers: ReleaseSafe, SHA-256 `3460d4ca…` (base) and `7ecf97f8…` (fixed).
