## 2026-11-10 08:30 CET — checker v2 reads a record update in a second pass

**What I did**

- S5a of #1018 (records in the ownership checker v2), on branch `own2-record-update`.
- First build: one model for lists and records. An update wrote its base's object, and one evaluation judged
  both. 70 list lines of the corpus moved in 41 fixtures, 3 programs reached `ownership_summary_size`, and the
  near-limit counted test grew from 77 222 to 227 081 records. I wrote six filters, one for each place where a
  list judgement read a record fact. 24 lines still moved.
- Then I read R-8.6 again ("Lists independent of records") and v1's §31.4 item 6 ("No list verdict reads a
  record condition", the owner's choice of the parallel domain, 2026-10-19). The one model cannot meet it.
- Second build: two passes (`Ownership.run`). The list pass reads an update as a new record, which is the
  analysis of master. The record pass reads it as a write of its base's object, and only its `update` lines
  are taken. A refusal that only the record pass has is reported as an `update` line. A module's block holds
  both passes' contracts (`Block.both`, `Block.part`). A module with no update, no record pattern and no
  import whose passes differ skips the record pass.
- The record pass has: the `update` demand, liveness by field with field events (`Update.zig`), a record
  pattern that reads the fields it binds, record demands at calls, callbacks, once closures, needs and
  closures that leave, the cell rule (a cell callback's update of the contents' own record copies), and
  `Record.copy` with the word `copyof` (the owner's answer to `ownership-v2-fable-q1`).
- Found on the way and fixed apart: #2418 (a chain of calls that thread one record cost 2ⁿ checks, PR #2419).

**What I learned**

- A requirement that names a test ("byte-identical under `--ownership-records-lost`") is also a statement
  about the architecture. I read R-8.6 as a test to add in a later step. It decides the design of the first
  step.
- In the slot domain a record fact enters the list analysis at eleven places at least: an arrival, a write
  and a read at a record's own slot, an occurrence in `req`, a need, the marks `taken_write`, `kept` and
  `once`, a deep write at a cell, an open row read whole, and the cost of the demands. A filter for each is a
  list line that moves for each one missed. Two passes need none.
- The record pass judges as if every update were in place. That is more sharing than any run has, so its
  list verdicts are too strict and are dropped. But a refusal that exists only there is real for the record
  that caused it. So the pass split needs the rule "a refusal that only the record pass has is a record
  line". Without it the report loses, for example, the entry's hold on the model.
- A cell callback's edit is "deep at `◆`" for a list. For the contents' own record that makes every caller's
  demand a list demand. v1's answer is simpler: the update in the callback copies.
- The second pass costs about as many account records as the first. The skip rule keeps core's modules at one
  pass.
