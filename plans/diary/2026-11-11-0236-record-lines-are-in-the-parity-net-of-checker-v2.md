## 2026-11-11 02:36 CET — record lines are in the parity net of checker v2

Part of #1018 (S5). New issues #2476 and #2477.

**What I did**

- The parity net of the gates compares record lines (`update …`) now. Until this step it left out each record line of both checkers.
- Three rules: v2's one line of several bases is one demand for each base; a declaration past the record pass's limit has an `unchecked … (record-pass limit)` line that excuses only v1's record lines there; an entry that begins `open (#N):` is pinned and not justified.
- Checker v2 names the base of a demand `<record>` for an update and `<tuple>` for a tuple, as v1 does.
- The known list has 1 218 record entries: 834 entry rows and 25 constructor lines (S7), 98 lines of fixtures with a `.v2` file, 261 open (#2477).
- An unknown difference prints both checkers' lines under its key.

**What I learned**

- The number behind a blanket skip says little. 2 843 lines differed. 1 536 of them were two programs behind one limit, and 834 were one kind of row that a later step owns. 261 lines in 62 programs are the real work. I did not know that until I removed the skip and grouped the lines.
- Two missing cases in one `switch` had cost 58 entries of the known list. v2 named an update and a tuple `<expression>`, and v1 names them `<record>` and `<tuple>`. Earlier steps had written a pair of one-sided entries for each such demand, with the reason "the same demand under each checker's text". When a reason says that two lines are the same demand, the fix is the name, not the entry.
- The failure of the net printed only keys. A key has the verdicts and not the causes, so I could not group anything. I made the failure print both lines first. The tool that reports a difference must show what a person needs to classify it.
- A third program passed the record pass's limit (`WideModelArms`), and I had counted two. It passes the list pass's limit too, so its known line hid the second one. The new `unchecked` line made it visible on the first run.
- The whole-corpus diff tool of the specification does not end, because one root costs 4^depth under v2 (#2121). The gates' net does not read that directory. A check that the specification names as the last word before the switch-over must be able to end.
- I did not classify the 261 lines. I could have written a reason for each by its cause words, and many of those reasons would be guesses. An entry that says `open` and names both causes is true, and the gates still fail on each new difference. The cost is that 113 lines are errors under v2 where v1 accepts, and nobody has looked at them one by one.
- In #2475 I put a constant between a function and its doc comment. The compiler does not care which declaration a doc comment belongs to. I read my own diff by hunks and did not see it.
