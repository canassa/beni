## 2026-10-22 13:22 CEST — Preserve recursive validator reproduction

**What I did**

Added a red browser fixture for a recursive function returning a validator
lambda. Its caller appends to fresh validation errors; current master rejects
that append as an unidentified function result. The expected page shows two
errors. Confirmed the pending fixture is red before changing the checker.

Investigated retaining function slots and read-only returned lambda classes in
recursive summary joins. The candidate cleared all fourteen list demands in
`bench/corpus`, but introduced rejected callback-supply demands at two call
sites in the existing `RecursiveHolds` fixture that had only accepted call
lines. Reported the result on #210 and #223 and stopped under the owner's
verdict-preservation instruction. Discarded the checker experiment and its
spec amendment; no existing ownership golden was blessed.

**What I learned**

Stable slot tables let the recursive validator retain the ownership of each
supplied callback's result. They also move some refusals from a generic body
to the supplied callback. That changes the reports at existing accepted sites
and requires an owner decision before proceeding. An unavailable returned
function class must also remain an unknown alternative; treating it as the
empty recursive approximation can wrongly accept a captured shared result.

The earlier cause fixes merged as #710, #715 and #721, each with green
self-hosted gates on dagon. Five recursive-validator list refusals and two
additional Ref-sharing writes remain; #210 has their inventory. Record-update
reports stay with #315's later record work. No local Zig, LLVM build, budget
change or performance measurement was used.
