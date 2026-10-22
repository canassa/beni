## 2026-10-22 19:15 CEST — a guard is no second choice under records-lost (#773)

**What I did.** While checking the bar for #754 and #763, found that
`zig build test-records-lost` passes at 7329b19ea and fails from c65cc73ec
(#720) on: four corpus programs (CallbackKeeps, InitializationTransfer,
OpaqueSlots, WideResult) had list lines that moved from `alias` to an
approximate `call` once every record condition failed. The minimal case is
`w1 x = ( x, x )` and an edit of `t.0`. `instRes` counts the entries at a
result path to decide whether they are approximate, and `spineAnnotation`
left a construction guard out of the count only while its record condition
was empty. The count now reads the guard's deep condition alone. A gated
black-box test in `check_test.zig` runs the minimal case with and without
`--ownership-records-lost`; it fails without the fix.

**What I learned.** `test-records-lost` is not a gate, so a regression in it
can sit on master unseen; the bar for the ownership PRs asks for it, and the
new gated test pins the one shape that broke.
