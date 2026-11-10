## 2026-11-10 16:58 CET — a later callee's write below an untouched field is no use

**What I did**

- A step of #1018 (records in the ownership checker v2), on branch `own2-callee-writes-below`, stacked on
  #2441.
- I sorted the record lines that v2 refuses and v1 accepts, and started with the real programs. In
  `browser/tea/BallMachine`, `( { model | atOnce = n }, knob model f )` was refused `later-use`. `knob` reads
  `model.machine` and writes a cell below it.
- The cause: `Later.footprintReads` asked the later callee's read tree by field (#2428), and asked its write
  tree with `writeMeets`, which says yes for any write at or below the record.
- `FieldMark.writes` is the write tree's query by field. A write of the record's own object stays a whole use,
  also of a field that the first update does not write: it is another update of the old record. A write below
  a written field stays a whole use. A write below an untouched field is none.
- Fixture `ownership/RecordCalleeWritesBelow`; mutant `callee_write_whole`.

**What I learned**

- A rule that has a read half and a write half needs both from the start. #2428 gave the read half a fixture
  and a mutant, and nothing asked for the write half until a real program did.
- The real programs find what the fixtures do not. The fixtures of `ownership/` were written for v1's rules,
  one rule a file. A page such as BallMachine puts three rules into one line.
- The sorted list of refused record lines is short now. Outside the entry, schemas, `Dict` and the list
  domain's own limits, about twenty lines are left, and each is one program to read.
- Reading those programs found a hole too (#2443): the record pass accepts an update of a record that another
  slot of the same parameter holds. A change that I had ready for this branch (an update that keeps no field
  makes no event) made a fixture that must be refused accepted, and that is how I saw it. I took the change
  out of this branch. The moved lines of the whole-corpus diff must each be read: one of the three was wrong.
