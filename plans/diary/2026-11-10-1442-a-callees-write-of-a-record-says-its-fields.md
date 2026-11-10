## 2026-11-10 14:42 CET — a callee's write of a record says its fields

**What I did**

- A step of #1018 (records in the ownership checker v2), on branch `own2-write-fields`, stacked on #2429.
- First I read the 78 record lines that v2 accepts and v1 refuses. 76 have a reason. Two lines of
  `ownership/RecordOnce` differed from R-4.8.2: a once closure writes its captured record, the frame reads a
  written field after the closure is made, and v2 accepted with one hoist. The write runs at the closure's
  call, so no read can be bound before it.
- To refuse that read and keep a read of an untouched field accepted, a once demand must know which fields
  the closure's code writes. So I built a write's field set: a record demand on a parameter's own record
  publishes a mark of each written field at the record's slot in `writes` (`FieldReads.writes`), a caller's
  demand reads the marks (`Update.fieldsAt`, `FieldMark.written`), and a once demand does the same for its
  closure's code.
- Then the once rule: for a `once` record demand a read of a written field after the creation is a whole use
  (`Update.after` with no hoist count).
- Fixture `ownership/RecordWriteFields` (R-4.8.7's refusal had no fixture), `RecordOnce.v2.ownership`, the
  mutants `write_fields_all` and `once_read_hoists`.

**What I learned**

- A `.v2.ownership` golden is read only when the fixture has a `.v2` file. I wrote two goldens without it, and
  both mutants survived: the corpus was green because nothing read the goldens. A mutant that survives a new
  fixture is first a question about the fixture's wiring.
- The whole-corpus diff did not move for the field sets: no line of the work list waited for them. Their
  value is the once rule and the hoist counts, which the lowering reads later.
- A member of a group that is being solved hears of a callee's write as it is found, with no field, and a
  second message for the same slot makes a second demand. So the publisher of field marks and the plain
  publisher must agree on "said once" (`FieldReads.told`).
- A demand that a graft groups over several routes has one field set for all its targets. The field set of
  its first route is wrong for the others, so such a demand names every field.
- Found for the next step: a record's write at a call relies on the callee's whole `req`. Where only two list
  slots of the argument meet, the record line is refused too (`ownership/CallerSide` `twin`). `CallReq` has
  the list half of the split; the record half is not built.
