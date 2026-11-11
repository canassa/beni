## 2026-11-11 05:39 CET — a stored top-level value makes checker v2 refuse a record update

Part of #2477. Part of #1018. New issue #2494.

**What I did**

- The 10 open record lines of `run/ListPersistence` have a reason, and it is a new over-refusal of checker v2 (#2494): a call whose callee updates a record and stores a value that is a top-level value, or holds one, is refused. The same update written inline is accepted, and v1 accepts each form.
- New fixture `ownership/RecordStoresTopLevel` with its goldens: three calls that v1 accepts and v2 refuses, and two forms that both accept.
- The pinned number of open entries is 24. 237 of the 261 lines have a reason after thirteen steps.

**What I learned**

- Five probes failed before one worked, and each failure removed a guess: the dictionary, the dictionary in the values, the lambdas of the pipe, the recursion. I wrote each failed probe into my notes with its result. Without that list I would have tried the dictionary a second time.
- The thing that I had left out of each probe was the plainest thing in the program: a constant. The program stores `{ list = [], model = empty }`, and I had written a parameter in the place of `empty` each time, because a parameter is what a probe normally uses. A reduction must keep the program's own values until it has shown that they do not matter.
- The best check was on the program itself and not on a probe. I changed the constant into a function at four places and counted v2's refusals: 11 lines, then 0. A probe shows that a cause is possible. A change of one thing in the real program shows that it is the cause there.
- The refusal's text names "another path of the same argument". It does not name the top-level value. Twice in this classification the cause word of a refusal pointed away from the cause (#2480, and now this). The words of a refusal say which rule failed, and I look for the cause in the values.
- This is the second defect that the classification found (#2480 was the first), and both make common programs fail under v2: a page that validates a server's value, and a state that stores a default.
