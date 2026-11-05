## 2026-11-05 16:18 CET — S4 callback fixtures and cost tests

**What I did.** Wrote the missing Appendix B S4 rows as `run/` fixtures (28 reds with a `.sanitize-lists-v2-refuses`, 14 greens run under the v2 sanitiser, 42 fixtures), the greens v2 refuses as six red `tests/pending/ownership/` fixtures (one issue each: #2028 to #2032 and #1978), and `build_test.zig`'s callback cost tests (CallbackWrapperDag, ClosureTower, WideCallbackResult, CallbackUnionComposition, mutual carried lambdas, a chain of feeding folds). Lane issue #2027. No change under `src/`.

**What I learned.**
- No red was accepted: v2 refuses all 28, so there is no new soundness finding. Fourteen greens are refused (precision), by six causes.
- Checking `CallbackWrapperDag` as written is exponential in the type checker, not the ownership pass (k = 20: 8 s, 776 MB; k = 24 in a dump: 3 min). The depth-24 test uses the list form; the tuple form stops at depth 10 (#2034).
- The fresh-only shortcut of WideCallbackResult does not exist: a fresh M-field actual costs what a supplied one does (#2035).
- A returned closure is opaque, so ClosureTower never trips the growth limit; the test allows either outcome (#2028).
- The run-hash cache is outside the repository now (`~/.cache/beni-run-hashes`): there is no `test-run-hashes` step and no hash file to commit.
