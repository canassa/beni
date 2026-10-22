## 2026-10-22 22:10 CEST — a record merge writes two sorted runs merged

**What I did**

- On the research dashboard, the largest self cost of `Main.beni`'s check was
  `TypeStore.sortKeyed`/`sortById`: every record unification that adds a field
  writes `a`'s fields followed by `only_b` and `addFields` radix-sorts the row
  again, although both parts are already in symbol order (#798, part of #464).
- Added `TypeStore.addFieldsMerged`, which writes two sorted runs merged in one
  pass and takes the left run's field first on an equal id: the row a stable
  sort of their concatenation writes. `Unify.record` writes its merged row with
  it, and `freshRecord` writes its split-off run without a copy and a scan.
- An in-source test checks the merge against `addFields` on 200 random pairs of
  runs, equal ids within and across them included.

**What I learned**

- The radix sort is linear, so this is a constant factor, not a change of
  order; but it is paid on the whole row at every record update, which made it
  the largest single item of a 64-field model's check.
- Equal ids cannot occur across the two runs here (`only_b` holds what `a`
  lacks), but the merge keeps the stable order anyway, so the claim "the same
  row" does not rest on that.
