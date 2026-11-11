## 2026-11-11 04:57 CET — a stored function's update is judged at its receiver's call

Part of #2477. Part of #1018.

**What I did**

- 4 more open record lines of the parity net's known list have a reason: a function that is stored in a record updates the record that its receiver hands it. v1 holds that update pending, and v2 judges it at the receiver's call.
- `run/SanitiserRowChainApart` has the marker `.in-place-v2` now: the gates run it with its records in place under the sanitiser.
- The pinned number of open entries is 52. 209 of the 261 lines have a reason after eleven steps.

**What I learned**

- For a line that v2 accepts and v1 does not, a reason in words is half of the answer. The other half is a run. The accepted twin of the fixture was in the corpus, and one marker file makes the gates run it in place. I looked for that before I wrote the reason.
- The run proves less than I wanted, and the pull request says so. The update writes the field that it reads, so no wrong value is possible. The run shows that no stale read traps and that the three builds agree. An honest limit of the evidence is better than a strong word for it.
- The two programs of the pair have the same two record lines, and v2 refuses one of the programs for a list line in `main`. A record line that is accepted says nothing about the program. The marker for "refused" is on the program, and the parity net is on the line.
