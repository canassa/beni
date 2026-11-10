## 2026-11-10 11:11 CET — a pending argument holds what its consumer reads

**What I did**

- The next step of records in the ownership checker v2 (#1018), stacked on the pull request of the record
  pass (#2426). Requirement R-4.8.5: `changed model (List.map model.todos λt → { t | done = True })` must
  accept the edit of the todos, because `changed` only replaces `model.todos` and reads none of them.
- v2 refused it `held-operand`: the argument `model` waits on the operand stack while the map runs, and a
  pending operand held its whole value.
- The specification's step 5 of the write rule already says "at a path its consumer touches". I built that
  for a call's argument, in the record pass: the argument holds the leaves that the callee's contract reaches
  (reads, writes, escapes), read when the pending index is built (`PendingArg.zig`, 56 lines). A virtual
  call, a pessimistic contract and a member of the group that is being solved hold the argument whole.
- Result: `ownership/RecordWriteOnlyCall` accepts `toggle`, as v1, and `toggleBoth`, where v1 refuses.
  TodoMVC's refused record lines go from 4 to 1. The list pass does not use the rule, so no list line moves.
- Before that I read the whole-corpus diff of v1 and v2 for record lines: 223 lines where v2 refuses and v1
  accepts, 77 the other way. The largest groups are the entry and schemas (a later slice), this rule (30
  lines), a callee's field reads, and a list's elements in a fold.

**What I learned**

- The work list by cause was the right first step. I had planned "field sets in contracts" as the next
  slice. The largest group that field sets were meant for needs no field set: `changed` reads its record's
  own object and nothing below it, and the contract says that already.
- A callee's plain read of a list (`List.length model.todos`) reads the array and no element. So an edit of
  the elements before that call changes nothing that the call sees. v1 reads the list whole there.
- A footprint of a callee in the group that is being solved still grows. A rule that reads it once, when an
  index is built, must not use it: there is no later judgement that would see the growth.
- The diff tool has no time limit for one dump, and one program of the corpus never ends under v2 (#2121).
  A whole-corpus run needs a limit for each dump.
