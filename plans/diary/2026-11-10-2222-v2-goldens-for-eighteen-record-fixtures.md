## 2026-11-10 22:22 CET — v2 goldens for eighteen record fixtures

Part of #1018 (S5).

**What I did**

- 33 of the 56 `ownership/Record*` fixtures had no `.v2` file, so nothing pinned v2's record lines for them, and the v2 check did not run. I compared v1's golden with v2's report for each, by line and by declaration.
- 18 fixtures, where both checkers refuse the same writes, have a `.v2` reason and a `.v2.ownership` golden now. No code changed.

**What I learned**

- A comparison by line overstates the difference. By line, 14 record lines are refused only by v1. By declaration, one is: the others are the same refusal at another line. v1 refuses the callback's update; v2 accepts the callback on a condition and refuses at the call that hands the container over.
- The one declaration that only v1 refuses (`RecordFoldBelow.twinFold`) is v2 being more exact, and a probe showed the edge: when the callback reads the second field after it writes the first, v2 refuses at the fold. A difference in the accepting direction needs a probe of that kind before a golden.
- The six declarations that only v2 refuses are three known kinds of over-refusal: an unknown function's answer holds its argument, the elements of a recursive container, and a decoder's answer.
- With a `.v2` file and no `.v2.ownership`, v2's lines must equal v1's golden. No record fixture can pass that way, because the record lines differ in text. So each record fixture needs both files.
