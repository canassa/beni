## 2026-10-23 09:28 UTC — a pure, total value waits for its write

**What I did.** #844 step 3, the follow-up #840 left: `Context.valueSafe` (which values a
binding function may evaluate at their write instead of before every write) now accepts every
value `valuePureTotal` proves, total calls and comparisons included. Only `emit/release/inline`
goldens moved (ArmOperators, CounterLocal, SingleValueModel); every page transcript stayed, and
`ThrowBeforeWrite`/`SelectedThrows` still throw before any write. Merged #846 (`132300c51`)
and #866 (step 2) first, each rebased and gated again.

**What I learned.** `valueSafe` read only `.inst` and `.let_value` values and answered
"may throw" for a field read handed as `.read`; asking `valuePureTotal` first closes that too.
A gate run under load average 27 tripped the 120 s hang guard on an ownership fixture that checks
in 25 ms alone: read the load before reading the failure.
