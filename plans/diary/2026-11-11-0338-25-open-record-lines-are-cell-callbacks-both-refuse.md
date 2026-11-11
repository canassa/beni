## 2026-11-11 03:38 CET — 25 open record lines are cell callbacks that both checkers refuse

Part of #2477. Part of #1018.

**What I did**

- 25 more open record lines of the parity net's known list have a reason: a cell callback's update of the contents' own record. v1 refuses it in the callback, and v2 at the cell operation. `ownership/RecordCellEdit` has the analysis since S5a.
- The pinned number of open entries is 96. 165 of the 261 lines have a reason after five steps.

**What I learned**

- "Both refuse it at two places" needs a check for each line, not for the group. I looked for the partner line of the other checker on the same source line. Seven lines had none there, and each had it two or three lines away, because a cell operation's callback is written below it. One had a partner under another name. A rule by line number alone would have left eight lines out or put them in with a false sentence.
- `browser/tea/BallMachine` is an example program that both checkers refuse to edit in place at its cell operations. Nineteen of its lines are this one fact. A large program in a list of differences looks like much work, and most of its lines are one cause.
- The texts of the two checkers are the fastest key for a group: `Ref.update` in a `supply` line of v1 and in a `call` line of v2. The failure output of the net prints both lines since #2478, and without that I had only keys.
