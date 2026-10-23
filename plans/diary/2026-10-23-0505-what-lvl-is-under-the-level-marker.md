## 2026-10-23 05:05 CEST — what `lvl` is under the level marker (§16.7 (d))

**What I did.** Worked out what #286's (d) `lvl` means now that the level marker `⟨T⟩` (#379)
exists, and wrote it as a dated §16.7 amendment before building. Two of `lvl`'s three facts (a
level apart from the levels below it, two regions apart) are already `sep` atoms of the deep
condition between places the marker keeps apart; the third (levels inside one region) is the
stated limit that (e) names. The missing part was a recursive member's fresh result:
`FoldLevels.build`'s rounds numbered their allocations in their own order, and §16.6's round
join merged the root's list with the left subtree's under one number. Built `freshKey`: inside a
recursive group a fresh number is a function of the result paths it names, the same in every
round. `FoldLevels.pushRoot` is accepted; `ownership/LevelFresh` pins it beside `pushDup`, whose
sharing is real and still refused. Thirty other ownership goldens change in summary lines only.
`bench/ownership-everywhere.mjs --no-cost` gives identical tables before and after (none of 1 001
programs rejected; browser-tea's modules 54 demands, none rejected).

**What I learned.** Dropping §16.6's one-cell-per-call merge as well (a cell per callee number)
is not needed for any verdict, and it made core `Schema`'s recursive group carry thousands of
result entries per round: core did not finish checking in half an hour. Every `zig build` checks
core with the new compiler, so a non-terminating ownership change shows as a `core_pack` process
that never ends and a watcher that never installs. A `FileBusy` from the watcher meant an old
`core_pack` was still running.
