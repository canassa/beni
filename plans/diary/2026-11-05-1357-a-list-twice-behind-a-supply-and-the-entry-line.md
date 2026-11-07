## 2026-11-05 13:57 CET — A list twice behind a supply, and the entry line

**What I did.** Answered the re-review of #1981. `SupplyRead.zig` reads a supply's family from its argument, so `[ a, a ]`
behind `app` or `Maybe.map` is two entries; that fixed master's `List.update` twin as well. `EntryHeld.zig` keeps a
traversal's write reached from an `entry` argument refused until S7. `taken_write` came back for it: I removed the same
flag earlier because the cell rule did not need it, and this rule does.

**What I learned.** The bug was not where a condition was asked but in how a value is read: `expand` gives each object
once on purpose, for cost, and a check that counts objects cannot use it. My reported bar missed both findings because
no probe or root had those shapes; sweeps over a cross of shapes are what found nothing further. My own generated known
rows gave four accepted programs the reason "both refuse": a reason written by a script is still a claim, and has to be read.
A probe refused with `UNKNOWN TYPE` on both sides looks like a pass; check the line it stops at.
