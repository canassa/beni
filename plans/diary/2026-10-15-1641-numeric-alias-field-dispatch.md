# Preserve numeric alias dispatch before defaulting

A final compatibility probe found that `(wrap 1).eq`, with a transparent
`Id a = a` alias, trapped in the deferred-dot implementation. Master emits
`too_few_args`. The legacy numeric well-known-method bridge must run before
reopening an undecided flex receiver, including at non-defaulting boundaries.
The deferred implementation now preserves that ordering.

`NullaryNumericAlias` pins both `eq` and `compare`. Its golden is from master.
The retained before/fixed comparison proves the previous reviewed compiler
aborts (exit -6), while master and the fixed LLVM ReleaseSafe compiler exit 1
with byte-identical streams. All 109 successful direct dump comparisons and
the cold/warm jobs-1/8 late-dispatch replay still match. The ReleaseFast
pending-read scaling test passes at 9/12 ms CPU, ratio 1.33.

Final full checks, sampling and three-way medians are refreshed before the PR
review request. The follow-up remains unmerged; its Linux instruction-budget
gate is still owed.
