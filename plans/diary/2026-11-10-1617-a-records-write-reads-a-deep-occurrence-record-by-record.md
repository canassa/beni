## 2026-11-10 16:17 CET — a record's write reads a deep occurrence record by record

**What I did**

- A step of #1018 (records in the ownership checker v2), on branch `own2-record-supply-req`, stacked on #2438.
- The case: `List.update [ { title = "b", kids = k, other = k } ] 0 grow`, where `grow` updates its record and
  pushes onto `kids`. The push is refused, which is correct. The update of the element was refused with it.
- My first design was wrong. I put a second reading into `FedWrite.relies`, for the supply's own conditions.
  The fixture stayed red. Three temporary prints showed that the failing condition is the taken row of
  `Outward` (`RowEnv.takenOccs`), and that it is one deep occurrence of the container. The kind reading of
  #2438 does not change a deep occurrence.
- So the step has two parts. For a record's write, a deep occurrence is the record objects at and below its
  slot, named one by one from the argument's place (`ReqKinds.zig`, new, which also holds #2438's reading).
  And a record's write reads the taken row a second time where the first reading fails.
- Fixture `ownership/RecordBesideListsSupplied`; mutants `record_supply_whole` and `record_deep_whole`.
- Then I sorted the 150 record lines that v2 refuses and v1 accepts. 10 stand beside a known refused list
  line at the same position, so their cause is in the list domain. 92 are the entry and schemas.

**What I learned**

- Print the failing condition before the design. The prints cost two builds; the wrong design cost a
  specification paragraph, a parameter and a mutant name that I took out again.
- A deep occurrence is the place where "lists independent of records" is hardest in the slot domain: one
  occurrence stands for objects of both kinds. Naming the records from the place keeps the change out of the
  projection code. It gives up where a kind can hide a record (a type variable, an opaque type, a closure).
- A refused record line beside a refused list line of the same call is usually one cause, and the cause is
  the list's. The known list already names it, so the comparison is a script.
- Found in a real program (`browser/tea/BallMachine`): `( { model | atOnce = n }, knob model f )` is refused
  `later-use`, because `knob` writes a cell below the untouched field `machine`. The later callee's read tree
  is asked by field, and its write tree is not. That is the next step.
