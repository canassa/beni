## 2026-10-31 14:16 CET — own2: two positions of one image owe excl, not a repeat

**What I did**

- Found why 4d made `Result.combineHelp` read `lost` (#1472). The tail call's read-off imaged
  `first.Ok` and `rest[*].Ok` to one cell, `π1[*]#Ok.0`, and `apartImage` counted the second as a
  repeat. Master hid this: its kept history held an arm that carried the argument's own snapshot, and
  it keyed the class's entry on a projection node that no caller read.
- Built §2.9 *Two positions of one image* with two rules, in #1473:
  - The image (`apartImage`): another side of one list split at a met image is one more position. It
    owes `excl` of the image. The sides per image are kept in the aggregate, so each arrival is one
    lookup.
  - The frame (`sep` under a split): two parts at one non-summary path below two sides need `excl` of
    their one canonical cell, which the split's κ implies, not the split's whole-element κ.
- Added `o/CombinePositions` and its imported twin. At #1473's earlier head the edit was refused. The
  unsound twins stay refused: payloads shared through the list, the second list holding a payload of
  the first, one element twice, a payload held outside, and two matches of one rest.
- Measured: no `res` path weaker than master, six stronger. The only verdict change is `mergeSort`.
  Records are 6 049 652, +0.15 % over 4d alone. The re-walk shows 0 mismatches in 1 660 walks. The
  cross-check fails only v1's five panics, as on master. The six soundness families pass, and the gates
  are green.

**What I learned**

- Master v2 accepted `combineHelp [ Ok b ] [ b ]` with an in-place edit of the first element. That was
  unsound, and the fixture now pins it.
- My first version of the image rule scanned every earlier arrival. It was quadratic, and
  `build_test`'s flat-per-position family caught it. Keeping the sides per image in the aggregate fixed
  it.
- Before setting a positions arrival to "not a repeat", check that something still owes the `excl`.
  `aggCond` does not add `excl` for group members, so the first version silently dropped the
  requirement. `TwoCallsApart`'s summaries showed it.
- The corpus dump directory is indexed by root position. Adding fixtures shifts the indices, so diff
  by root name.
- `beni fmt --check` prints the files that fail. It does not print the files that pass.
