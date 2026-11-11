## 2026-11-11 03:32 CET — 14 open record lines are the run twins of two analysed fixtures

Part of #2477. Part of #1018.

**What I did**

- 14 more open record lines of the parity net's known list have a reason. 9 are the update of a record that an unknown function's answer can hold, in the `run/` twins of `ownership/RecordInnerKept` and `ownership/RecordKeptInLiteral`. 5 are one call that both checkers refuse under two names.
- The pinned number of open entries is 121. It was 261 when the record lines came into the net.

**What I learned**

- A `run/` fixture and an `ownership/` fixture of one rule are two programs with the same declarations. The analysis of the `ownership/` one was in its `.v2` file since #2471, and the lines of the `run/` one were open. The first entry script joined an entry to a `.v2` file by the fixture's own path only. A join by the twin's name would have classified these 9 at once.
- For "both refuse the program" I read v1's report and did not trust the fixture's marker. v1 refuses each of the nine callers with a line whose operation is `value`, not `update`. That is the same kind of line as in #2473.
- In four steps, 140 of 261 lines have a reason, and no step changed the compiler. Three of the four reasons were known before (a list line of the same call, a `.v2` file, a twin). One was new, and it is a defect that makes fourteen pages fail (#2480). The classification paid for itself with that one finding.
