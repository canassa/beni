## 2026-11-02 01:59 CET — test-pending reports exactly the open findings

**What I did**
- Removed the stale `WriteOneLevel` RED line: its fixture moved to `tests/corpus/ownership/` in cff3e39209 (CK-280 fixed).
- Graduated `scenario/CK-314` (green since #1494, which closed #1097) into `build_test.zig`.
- Promoted `PatternWideFresh1000` (CK-312, green since 5f77e96062) into the corpus.
- Re-recorded `DeepTupleDag` as `exit=0 node+everywhere.ownership-differs`: it no longer times out (about 12 s).

**What I learned**
- The first run showed three more problems than the issue named; the harness stops at the first failing test of each binary, so re-run after each fix.
