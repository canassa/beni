## 2026-11-10 12:05 CET — a callee's contract says which field it reads

**What I did**

- The third step of records in the ownership checker v2 (#1018), stacked on #2427. After
  `q = { p | x = 1 }`, a call `getY p` with `getY p = p.y` was refused `later-use`: the callee's read of
  the record named no field, so every call with the old record was a whole use.
- A field read of a parameter's record is now a mark of that field at the record's slot in the callee's
  `reads` (`FieldReads.zig`, `FieldMark.zig`). A later call asks the read tree by field. A callee's reads
  that pass through another callee keep their fields.
- The mark is an ordinary arrival in the read tree's plain run, with the field's one-step slot. So the
  block's format did not change, and a grafted node keeps its marks.
- `ownership/RecordCalleeFields` gives the same five verdicts as v1.

**What I learned**

- A mark that names its position (a parameter and a slot) breaks when a node is grafted at another slot. A
  mark that names only the field does not. I chose the field's one-step slot for that reason.
- The first build lost the field when the reads went through a second callee. The read-off projects each
  entry of the callee's tree and adds a plain effect, and a plain effect is "the record whole". The fixture's
  case `through` showed it at once. A fixture with one more level of calls than the rule's example is cheap
  and finds this kind of loss.
- The fences of `rules_test` (line targets, the readers of a tree's kid, `indexOfScalar` on `u32`) each
  stopped one gates run. A filtered run of the unit tests before the full gates is faster.
