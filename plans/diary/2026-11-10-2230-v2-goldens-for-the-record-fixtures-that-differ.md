## 2026-11-10 22:30 CET — v2 goldens for the record fixtures that differ by declaration

Part of #1018 (S5). Part of #2470.

**What I did**

- Six `ownership/Record*` fixtures, where the two checkers differ by declaration, have a `.v2` reason and a `.v2.ownership` golden now. Five hold an over-refusal of v2, and I filed #2470 for the four kinds. One (`RecordFoldBelow`) holds a declaration that v2 accepts and v1 refuses.
- Two new `run/` fixtures are the evidence for that acceptance: `SanitiserRecordTwinFold` runs with its records in place under the sanitiser, and `SanitiserRecordTwinFoldRead` is the refused twin.

**What I learned**

- An acceptance that the old checker does not make is a claim, and a golden is not evidence for it. The evidence is a run with the records in place under the sanitiser, and a twin that moves one step past the limit and is refused. Here the limit is one read: the callback reads the second field after it wrote the first.
- v1 and v2 put the same refusal in different places. v1 accepts a function on a condition and refuses the caller that breaks it. For an unknown function's answer, v2 refuses in the function itself, for each caller. Both refuse the fixture's program, and the difference shows only for a caller that the fixture does not have.
- The platform fixtures of records are entry fixtures. Their rows differ by platform, and one `.v2.ownership` serves all rows of a fixture. They belong to the entry work.
