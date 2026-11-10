## 2026-11-10 12:49 CET — a closure that reads a field holds its value

**What I did**

- The fourth step of records in the ownership checker v2 (#1018), stacked on #2428. Requirement R-5.4.6: a
  closure that captures a field path reads the field when the closure is made, and holds the field's value,
  not the record.
- In the record pass a frame that names a captured local only as the base of a field access is a field
  capture (`FieldCapture.zig`). At the creation each field is a read event and a use of the field's value,
  and the closure's kid for that capture is a record of those values with no object of its own.
- The rule is read off the text of the frame, as v1's is, because the lowering must find the same captures.
- The report prints the hoist count after an acceptance, `accepted param [hoisted 1]`, as v1 does. The
  record pass counted hoists since its first step and never printed them.
- `ownership/RecordFieldCapture` gives v1's six verdicts and its hoist. The update lines of
  `ownership/RecordHoistChannel` now equal v1's lines in full text.

**What I learned**

- I created `Captures.zig` and overwrote a module of that name in the working tree. Nothing was committed,
  and `git checkout` restored it. I list the directory before I create a file from now on.
- The specification text of the first step said that the hoist count is the report's `[hoisted n]`. The
  code did not print it, and no golden had it, so nothing failed. A sentence of a specification that no
  fixture pins is not built until one checks it.
- A value with no object of its own (a record with no site) is the right model for what a closure holds of
  a field capture. The closure's contract reads the capture by its field steps, and the kid answers them.
