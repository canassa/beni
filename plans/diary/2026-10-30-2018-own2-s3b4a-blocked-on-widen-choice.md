## 2026-10-30 20:18 CET — own2 slice 4a: group rounds built, blocked on widen's choice

**What I did.** I started S3b slice 4a (#1354) on `own2-s3b4a`. The first commit gives a call of
the walk's own group its own `.v2.unchecked` reason, `recursion`: 218 lines in 104 files. The second,
a WIP commit, solves a recursive group:
- ports start at ⊥, and rounds are synchronous, in text order;
- a group call answers its port's class by reference and keeps `(member, version)` in the walk's
  read vector (the coarse rule);
- the port takes `widen(x ⊔ F)` where `F ⋢ x`, and any change wakes its readers;
- read-off labels are stable, with one `ι⋆` per group call, place and kind, and the class is
  renumbered at publication;
- the walk lanes are inference, then validation, then growth (`Account.walk`), and each member's
  joins are charged to its own account;
- a group is built whole or unbuilt whole, and an unbuilt member gets the pessimistic class;
- the cold re-check runs over a whole group, its earlier groups solved whole.

`Rot` refuses 7:13 `later-use`, as v1 does, after 3 walks. `go` settles with growth 0.

**What I learned.** Widen does not open a `choice` on a re-entry when the value's root is a `choice`.
§2.3 says it must. So every `case`-based recursive member nests the previous round's choice at the
recursive call, `leq` fails on the shape every round, and the group runs to the allowance
(`MarkerAcross`, `LevelRecursiveUpdates`, `LevelFresh`, `FoldLevels`). It is #1360, and 4a cannot
land before it is fixed. The plan's "`GroupSelfFold` takes two walks" is also off by one: round 2
adds `π1[*] A` through the call's view (v1's summary has it too), so it takes 3 walks, with G_f 0.
Also, perl's `s|…|…|` with `\|` in the pattern is an alternation and can silently rewrite the wrong
place. Use the Edit tool for multi-line Zig edits.
