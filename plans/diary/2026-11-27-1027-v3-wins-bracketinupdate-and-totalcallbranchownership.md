## 2026-11-27 10:27 CET — v3 wins BracketInUpdate and TotalCallBranchOwnership

**What I did**

- Kernel §11 item 11, *A closure writes a field of a record it captured*: a closure's write of a captured record's slot is published at the capture and judged by the holder that runs it — a direct call, or a call that runs it once within as its own argument; every other holder refuses. With it, *The order of a callee's runs*: a walked body publishes `Fn.before` (parameter i runs only before parameter k) from the points its walk runs its function parameters (`Frame.sights`), and at the caller the earlier argument is an operand only through what its runs leave (`capAfter`). `Task.bracket` publishes acquire before use. Wins `browser/inline/BracketInUpdate`.
- Interface 1.44, `Lowering.evaluates_hole_once` (`boundary.md` §9.4.8, *A hole evaluated once*; kernel §6 rule 12): `inline` names the holes a root reaches through elements, in a root with no `let`. In markup that is a declaration's whole body, or an arm's markup of such a hole, the markup no longer holds a value whose every cell the hole's own evaluation wrote at a call that is not pure and total. Wins `browser/inline/TotalCallBranchOwnership`.
- The second reviewer found two faults in the first form of the hole rule: `Dict` writers are pure and total, so `inline` evaluates them eagerly in an arm not taken, or again at an event. The rule now counts only writes at calls not proven total (`Enforce.notTotalCalls`); both pages are refusal fixtures (`HoleOnceDispatchLive`, `HoleOnceEagerArmsLive`).
- Merged `origin/ownership-v2-design-review` (e22c75218e, fix224) into the branch on the manager's order; `tests/blackbox/ownership-v2-known.txt` resolved as a union (git's remembered resolution left a diff3 marker in it).

**What I learned**

- A lowering's "evaluated once" fact is about values that can write: a pure, total value may be evaluated more than once, and a `Dict` write is pure and total by Totality.
- `git rerere` can replay a resolution that still holds a conflict marker; check the resolved file.
- Running `beni` inside `tests/corpus/run/` leaves a `.beni-cache/` that the corpus reads as a fixture.
- The gates lock is contended by other lanes: an LLVM build can wait 20 minutes; never wait for "no zig process" by user, other lanes run zig too.
