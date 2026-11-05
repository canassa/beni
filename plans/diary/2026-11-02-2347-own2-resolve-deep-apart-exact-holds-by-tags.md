## 2026-11-02 23:47 CET — own2 resolve lane: deep apart read exactly, holds read by their tags

**What I did**

- Issue #1714, resolve lane, branch `own2-cost-resolve` (no PR). Three commits:
  - `af3171d18`: a condition that asks a parameter deep apart and plain below
    it (`π1{ε*~,[*]#0.0}`) is now read as its slots written out are. The
    call's instantiation projects that parameter part by part, so each part
    of a literal is at its own route. The apart entries then lose what the
    plain ones reach at the same leaf and route, counted, never by leaf
    alone. A reference loses the plain slots by `Subtree.without`. With the
    values lane's place-graph `below` rule applied locally, the 29 positions
    it moved to refused stay accepted, and no probe traps. New fixture
    `ownership/DeepApartPlainBelow` (the negative control stays refused).
  - `db8ea5fc5`: test 21 expected `( incAll v, ignore v )` refused, but
    `ignore` reads nothing. A sanitiser probe showed the acceptance is sound,
    and v1 accepts it too. The test now reads `v` for real (`count v`) with
    the same cost bound. New fixture `ownership/CallReadsNothingAfter`.
  - `059672188`: a holder with more than eight holds reads them as the tree
    of their tag lists by shared tail (new L2 file `TagTree.zig`). A target
    meets only the holds whose tags can hold with its own. A judgement asks
    the liveness of a holder's path once, not once per target. A tag list has
    a jump pointer, so a conflict test is logarithmic. Test 21 flips: 169 231
    → 3 974 demand records at D = 32.
- After each step: ledger 0 verdict changes, limits and summaries equal,
  oracle (1 298 runs) equal, cost table growth 0. build_test: 26 → 25.

**What I learned**

- The cost of test 21 was the number of pairs, not the cost of one merge.
  A faster merge took 169 k to 108 k; skipping the pairs whose tags part
  took it to 8 k; asking each liveness once took it to 4 k. Count the calls
  before you make one call cheaper.
- Test 8 and test 10 have one cause: `Relation.project` walks a choice DAG
  once per path, because a value reached through two different choices gets
  two tag lists. The fix is a projection by route sets, each node once, as
  the leaf sets already are. Grouping the arms of one choice does not help,
  because the two arms belong to two choices.
- A `beni check` run inside `tests/corpus/ownership/` leaves a `.beni-cache`
  directory there, and `bench/ownership-roots.mjs` then fails. Run probes
  from a scratch directory.
- New fixtures shift the ledger's root indices. Align the ledgers by root
  name (`scripts-below/align.sh`) before you compare them.

**Not done**: step 3 (doubling DAG holds, tests 5 and 26), step 4 (test 10,
profiles of 25 and 20), step 5 (GroupRotate's semi-naive rounds). The
designs are on #1714.
