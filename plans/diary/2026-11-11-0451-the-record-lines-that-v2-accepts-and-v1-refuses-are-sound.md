## 2026-11-11 04:51 CET — the record lines that v2 accepts and v1 refuses are sound

Part of #2477. Part of #1018.

**What I did**

- 5 more open record lines of the parity net's known list have a reason. Three are lines that v1 refuses and v2 accepts, with no partner line: the update of a new `Record.copy`, a map's write of elements whose list has only its length read after, and the update of two new record literals that share only a list. v2 is correct in each. Two are the lines that v2 prints for a once closure.
- The pinned number of open entries is 56. 205 of the 261 lines have a reason after ten steps.

**What I learned**

- I had left the most dangerous kind of line for late. A line that the new checker accepts and the old one refuses is the only kind that can make a wrong program. The other kinds make a correct program fail to build. The order of work must be by risk and not by the size of a group. I took these three as soon as I saw that they had no partner.
- Each of the three was v1 being less exact, and each for another cause: v1 takes a copy to be held by its source, v1 counts a read of a list's length as a read of its elements, and v1 refuses two distinct literals because their fields share a list. For the third one both checkers refuse the program anyway, on the list line.
- "v2 is more exact" is a claim about the language, so I wrote for each line why no stale read is possible, not only that v2 says `accepted`.
