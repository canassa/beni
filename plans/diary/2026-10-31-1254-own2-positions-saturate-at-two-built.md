## 2026-10-31 12:54 CET — own2: positions saturate at two, built

**What I did**

- Built `ownership-v2.md` §2.3 *Saturation at two* in `Shape.positions`. When a member would occur three
  times or more, the constructor rebuilds the tree with each member at most twice, in first-occurrence
  order. `map`, view expansion and `BlockRead` keep their records.
- The cost design is built as the spec says. Each positions node keeps a count map (keys, twice), a
  persistent radix set. The test and the rebuild are a growth task, so each lane of `collect` holds only
  its own positions node. A unit test checks this on six laned items.
- The empty-κ-home argument is checked under `runtime_safety`. In `TransferConstruct`'s literal and
  construction, a node that a rebuild dropped has, at every position of the new snapshot, the entry
  that the operands' merged snapshot gives it, or no entry. The fixture `ownership/PositionsSaturate`
  runs the check in the gates.
- Added a counted `build_test` for `Rose [ r, r ]` at 10 / 40 / 160 levels. It gives 5 728 / 32 495 /
  315 927 records and fails on master, which takes 14 449 at 10 and refuses 160.
- Amended §2.3 (*As built*), the #1420 debt bullet and §5's line targets (Shape 3 780,
  TransferConstruct 390).

**What I learned**

- Count maps must be made eagerly or set only at birth. Suppose a node could get a map after a parent
  had read it as one member. Then the parent's keys and a later depth-first walk would not agree, and
  the rebuild would drop a member, which is unsound. So only a node that `positions` made is counted,
  and that is marked by a bit of its record. Every other positions node is one member.
- Charging the count maps eagerly on every construction pushed `doublingProduct` (64 lists, growth
  65 227 of 65 536) past the allowance. Lazy maps, with no work when both sides are plain members, fixed
  that. 600 spreads of one list still cost 20 records an item (18 before), because each level is a
  rebuild. Its counted ceiling went from 20 to 32, with the measurements in the comment.
- The byte-identity check matches the prototype: 2 044 roots, and only 7 blocks differ, all smaller.
  The full cross-check over `ownership/` fails the same set as master, plus master's eighth failure
  (the spreads ceiling) is now gone.
- `Rose [ r, r ]` is still above n log n (269 per n·log₂(n + 2) at 160, against 151 at 40). That is
  #1420's remaining debt.
