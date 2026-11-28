## 2026-11-20 02:45 CET — The record sanitiser compares with Object.is

**What I did.** The adversarial reader of research report 165's oracle wrote 79 programs on the
mutant v3 and found one blind spot of the sanitised leg: a record field written from `0` to `-0`
was never poisoned, because `record` in `sanitize_runtime.mjs` skipped a field whose old and new
values were `===`. The same test poisoned an unwritten `NaN` field, a false alarm on a program
the base accepts. The test is `Object.is` now; `run/SanitiserRecordNaNField` traps before the
fix and passes after. Report 165 §7 has the review.

**What I learned.** `--mode=both` matters: the in-place leg caught the `-0` write that the
sanitiser missed, so a sweep run with the sanitiser alone would have called it SAME.
