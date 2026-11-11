## 2026-11-11 04:27 CET — six open record lines are worker programs at their constructor

Part of #2477. Part of #1018.

**What I did**

- 6 more open record lines of the parity net's known list have a reason: three worker programs at `Worker.program`. v2 refuses at the constructor's call, and v1 holds the update of `handle` pending. The entry protocol is S7.
- One reason of #2487 has the clause that its review asked for.
- The pinned number of open entries is 68. 193 of the 261 lines have a reason after eight steps.

**What I learned**

- The first entry script found the program constructors by v2's text `rejected call: <constructor> still holds it`. A worker's constructor has another text (`rejected unknown`), so its lines stayed open. One fact can have two texts, and a rule that reads one text finds half of the fact.
- v1 says `pending` for the update in `handle`, with the words "it is stored in a record". That is v1's way to say that the function's caller is not known here. v2 says the same thing at the constructor's call. The two lines are far apart in the report, and near in meaning.
- A note of a review that does not block is still owed. I put the clause for #2487 into this step and did not start CI for one clause.
