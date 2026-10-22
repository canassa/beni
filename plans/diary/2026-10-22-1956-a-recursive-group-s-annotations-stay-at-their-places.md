## 2026-10-22 19:56 CEST — a recursive group's annotations stay at their places (#754)

**What I did.** Bisected #754 with safe builds of each `src/own` commit since
7f1135d4b, measured with `perf stat -e instructions:u` on core's ownership
dump: 7329b19ea 4 799M, **c65cc73ec** (#720) 11 051M; the `src/own`
commits right after it moved it by under 3%. A user's `beni build` and `build --release` of
`examples/conduit` and `examples/sternhalma` cost the same before and after
c65cc73ec (1 238M and 4 340M for Conduit): core's ownership summaries are
computed once, when beni is built, and carried in the embedded core pack.

Then per module: `core/Result.beni` went from 624M to 2 775M, `List` from
755M to 2 266M. A 20-line copy of `Result.partitionHelp` reproduced it.
Printing the summary per round of its recursive group showed guards at
`[*]` (on a tuple) and `.0[*][*]`, one level deeper every two rounds, until
the cut, in 18 rounds. The cause is §16.6's merge: inside the group, a
call makes one fresh cell for all of a member's fresh numbers, annotations
included. Merged, an annotation stands at every path any of them stood at
and carries all their container conditions, and `annotationSpines` puts
each condition's guards under every one of those paths. The fix keeps one
annotation per result path for entries with a `sep_root` atom, numbered
above every fresh and callback number. Rounds went 18 → 3 for
`Result.partitionHelp` and `List.unzipHelp`. No verdict of the corpus or of
core moved; 15 goldens lost their deep guard entries or renumbered them.

Two cheaper changes ride along: `condAnd` merges two ordered conditions in
one pass instead of sorting their union (a guard's spine grows with every
call that passes the same argument), and `annotationSpines` takes the call's
grown arguments instead of computing them per atom. An entry's deep
condition is kept within one `instRes` while no condition outside the call's
own results changed; a build that recomputed every kept one and panicked on
a difference passed the whole black-box suite.

**What I learned.** `pdq` (`std.mem.sortUnstable`) is slower than the block
sort for `norm` and `sortWAtoms` here: their input is sorted runs end to
end, and Conduit went up 6% before I put the stable sort back. A merged
cell is sound for an allocation, since it only adds aliasing. It is not
harmless for a condition that names a place, because the condition then
lands at places it was never about. Measure a module on its own
(`beni dump --stage=ownership core/X.beni`) before profiling all of core: it
pointed at two 20-line functions in minutes.
