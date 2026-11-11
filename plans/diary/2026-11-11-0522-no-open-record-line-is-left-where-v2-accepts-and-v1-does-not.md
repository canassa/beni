## 2026-11-11 05:22 CET — no open record line is left where v2 accepts and v1 does not

Part of #2477. Part of #1018.

**What I did**

- 18 more open record lines of the parity net's known list have a reason: each line where v2 accepts an update that v1 refuses or holds pending, and the lines beside it. In each one v2 refuses the closure or the call beside the update, so neither checker accepts the write.
- One old reason of the list was no longer true, and I corrected it.
- The pinned number of open entries is 34. 227 of the 261 lines have a reason after twelve steps.

**What I learned**

- I wrote in the specification "no open line is left where v2 accepts a write that v1 refuses", and then I ran the search that the sentence needs. It found four lines. I had counted the lines of two programs and not the lines of the list. I classified the four and their neighbours before I kept the sentence. A sentence with "no" or "each" in it needs its own command.
- v2 prints an update inside a closure or a callback as accepted, on a condition, and puts the refusal on another line: the closure's creation, its call, or the call that hands a record over. A reader who sees only the update's line thinks that v2 is more permissive than v1. It is not. The parity net compares line with line, and the meaning is in the declaration.
- A reason in the known list can go out of date with no change of its key. The entry for `value <lambda>` said that v2 has no record demand yet. The stale check of the harness reads keys. Reasons that name a step ("not yet", "until S5") need a look when that step lands.
