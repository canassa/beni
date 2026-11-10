## 2026-11-10 17:33 CET — an update reads by field only the hold that is the written record

**What I did**

- The fix of #2443, on branch `own2-record-sibling-holds`, stacked on #2444.
- The hole: the record pass accepted an update of a record that another slot of the same parameter holds.
  `c = acc.cur; r = { c | … }; ( r, acc.cur )` was accepted, and `( r, acc.hist )` asked nothing of its
  caller. It was in the stack since #2426. Nothing was miscompiled, because record verdicts are not enforced.
- I found it by accident. A change that I had ready (an update that keeps no field makes no event) moved
  three lines of the whole-corpus diff. Two were the lines that I wanted. The third was a fixture that must
  be refused, and it was accepted. The event that I removed had hidden the hole there.
- Two causes, both found with temporary prints and not by reading:
  1. The use index asks a filter once for a group of uses of one path and kind. My filter of #2426 read a
     use's point. The first use of the group answered for a later one.
  2. Every hold that a judgement asks was read by the written record's fields. The rest of a parameter's
     slots is another object, and a use below its path is a real use.
- The fix: a use kind `read` for a field access's use of its base record (record pass only), and a flag from
  `HoldAt.holdsAt` that says whether a hold is the target itself.
- Fixture `ownership/RecordSiblingHolds`, red before the fix; mutants `sibling_holds_by_field` and
  `field_read_by_point`.

**What I learned**

- Read every moved line of the whole-corpus diff, also when the total moves the right way. The count went
  from 148 to 145, which looked like progress. One of the three lines was a wrong acceptance.
- A contract of a data structure that is written in a comment ("a filter judges a use by its kind, callee use
  node and path") is easy to break from another file. The seven fixtures of #2426 and its eight mutants did
  not see it, because no fixture had two uses of one path with different points on the two sides of a write.
- A rule that is right for the written object is not right for every object that a judgement looks at. I
  wrote "for a holder that holds a target at path q" in the specification and then applied the rule to every
  path that the query returns.
- The list pass was the reference again: the list twin of the function had the requirement, and the record
  function did not. Compare a record line with its list twin before v1.
- I stopped twice to reason about the cause from the code, and was wrong twice. The prints took two builds.
