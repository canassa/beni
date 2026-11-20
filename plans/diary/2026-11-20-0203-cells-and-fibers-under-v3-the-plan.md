## 2026-11-20 02:03 CET — Cells and fibers under v3: the plan and the oracle

**What I did.** Started the cells and fibers phase of the ownership checker v3 (#981, #2521) by
report 142's method. Research report 165 is the plan: what v3 does with `Ref` today (its layout
stops at the handle, so the contents have no location), which location each cell operation
reads, writes and renews, when a value taken out of a cell can be written in place, what a
handle with a second holder does, and what a park does. Proved the oracle with a mutant v3
(`Frame.ownSupply` accepting every supply, not committed): on the new sweep `cells.mjs` (720
programs) it let 288 live programs through, and every one is TRAP under the sanitiser and DIFF in
place, 72 of them a read in another fiber after a park. The base refuses all 720. No compiler
code changed; the base's v3 dumps of the 2 475 roots and the ledger (309 of 319) are taken for the
next lane.

**What I learned.** The oracle needs no code for cells: the write in place is a list, record or
dictionary write inside the function `Ref.update` is handed, and the lowering routes it by its
site. The checker needs one new contract fact, a renewal of a parameter's contents location,
because `set`, `update` and `modify` answer `⊤`. Two tempting shortcuts are unsound: reading a
handle with a second holder as `outside` (a loan taken before still overlaps nothing), and an
override of the handle root's own entries (reads are judged at the end of the walk, so a loan read
between two updates reads the last state). Version roots of the handle, and a shared handle whose
contents escape, close both. Descending into `◆` alone makes `Ref.make`'s row trip
`Check.core_phantoms`, so the layout and the rows change in one commit.
