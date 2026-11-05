## 2026-11-05 13:06 CET — Drop the traversal test on the cell rule

**What I did.** Removed `Flags.many_write`. Any write through a `◆` then a `[*]` relies on `no` now. This corrects my
previous entry and my first reply on #1981, which said that closing the `List.update` route would refuse more.

**What I learned.** I added the flag to spare `BallMachine` and never checked that it did. The ledgers with and without
it have the same two rows, so it bought nothing and left `List.update` through a cell trapping. A narrowing needs the
same before and after measurement as a widening. #1986 is now the field-sharing case only.
