## 2026-11-11 04:08 CET — 18 open record lines are callbacks of maps and folds

Part of #2477. Part of #1018.

**What I did**

- 18 more open record lines of the parity net's known list have a reason: a callback's update of a container's element or of a fold's accumulator. v1 refuses the update in the callback, and v2 refuses at the call. `ownership/RecordContents` and `ownership/RecordFoldBelow` have the analysis.
- The pinned number of open entries is 74. 187 of the 261 lines have a reason after seven steps.

**What I learned**

- This step had no rule. I tried one: pair v1's refused callback line with v2's refused call line when the call is at most eight lines above. It paired an update in one `List.map` with a fold three lines above it. Two calls that are near in the source are not one call. I wrote the 18 keys by hand from the source.
- The pair "v1 in the callback, v2 at the call" has a third line in some calls: v1 accepts a line at the call that v2 refuses, and v1 has no refusal for that base in the callback. That line is not "the same refusal at another place". It can be an over-refusal of v2. I left those lines open and named them in the pull request.
- The steps get smaller and slower: 57, 46, 23, 14, 25, 4, 18. The first ones were rules over the list. The last ones are reading. The 74 lines that are left are the ones where the two checkers can truly disagree.
