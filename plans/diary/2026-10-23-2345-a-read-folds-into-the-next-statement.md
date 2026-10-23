## 2026-10-23 23:45 CEST — a read folds into the next statement (#896, last part)

**What I did.** Every binding entry in a root factory kept ``let d=c.a;k(b[3],`Cups = ${d}`)``.
The binding functions before fix 7 had ``k(b[3],`Cups = ${c.a}`)``. `Opt` refuses to move a read
whose chain is rooted at a name the declaration writes through, and the factory's handlers write
the slice. Now a member chain of a name, or a value `pureValue` accepts with such names let in,
is written at its one read when that read is in the very next statement before anything there
that may write. Nothing runs between the two (`backend.md` §9 item 1, amended). S1 bindings are
back to the old shape. 25 release goldens moved, and pages, run hashes and `./rr check` (24/24)
are unchanged. Gates are green.

**What I learned.** My first version took any write-free value. That folded `a+1` into the next
statement, and `pureValue` declines that, because `a` may be a host value whose `valueOf` runs.
I restricted the rule to the licences the rules above already give, minus the scan past
statements. A `build_test` expectation caught the difference.
