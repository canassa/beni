## 2026-10-24 23:50 CEST — S1 closed at 1.16× tea-inline

**What I did**

- Managed the S1 lanes to the end: #934, #936, then #946 (step B #948, E7 #949, E6 measured and
  dropped #950). Measured the 12-build fit after each merge and kept the report's table current.
- S1 went from 241.0 B/widget (2026-10-23 morning) to 168.0; N = 1 1 461 → 1 383, N = 256 63 980 →
  45 321. The owner closed S1 at `2556986c6` with the bar not met: 1.12× tea-inline at N = 1, 1.16× on
  the slope. #297 is closed with the record.

**What I learned**

- Quote ratios against tea-inline as well as against the bar. "1.06× the bar" reads as "under 1.1"
  and hides that the bar already includes the 1.1; I also once mis-typed the N = 256 bar (46 857 for
  42 857) and claimed a pass that never happened.
- A hand-minify pass on the output alone, with no compiler source, was the best planning tool of the
  run: every item it priced that we built landed close to its estimate (E7 −3.0 against an estimate of
  −3).
- A size rule that looks at raw bytes cannot decide a transform whose brotli effect has the opposite
  sign (E6 at N = 16). Dropping it beat a benchmark-tuned threshold.
- The Claude Code Review workflow posted nothing on every PR since 2026-10-23 14:23 UTC; independent
  subagent reviews found real bugs in #942, #945, #948 and #949. Keep the fallback until it is fixed.
