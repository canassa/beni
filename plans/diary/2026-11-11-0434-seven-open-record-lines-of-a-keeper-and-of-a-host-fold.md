## 2026-11-11 04:34 CET — seven open record lines of a keeper and of a host fold

Part of #2477. Part of #1018.

**What I did**

- 7 more open record lines of the parity net's known list have a reason: 5 in `run/SanitiserRecordKeptThenWritten` (a keeper holds a record that the function then writes; both checkers refuse, at other lines), and 2 in `ownership/core/RecordKeepJs` (a fold whose callee hands the record to the host).
- The pinned number of open entries is 61. 200 of the 261 lines have a reason after nine steps.

**What I learned**

- Two lines said "v1 refuses, v2 accepts" for a fold whose callee gives its record to JavaScript. That is the shape of a soundness defect: the host keeps the record of one step, and the next step writes it in place. I read v2's whole report for the declaration before I wrote a word. v2 refuses the fold at its call, as v1 does, and the two lines were only the callback's own line. A line that v2 accepts and v1 refuses is the first one to check against the whole declaration, not against its own key.
- The parity net shows only the lines that differ. The line where both checkers refuse the same fold is not in the list, because it is no difference. To read one difference, I need the lines that agree around it.
- 200 of 261. The 61 that are left have no fixture with an analysis, no twin and no partner line that I found. They are the real work of #2477.
