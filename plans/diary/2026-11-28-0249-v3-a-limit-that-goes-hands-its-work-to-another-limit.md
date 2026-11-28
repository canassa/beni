## 2026-11-28 02:49 CET — v3: a limit that goes hands its work to another limit

**What I did**

- Answered the adversarial review of PR #2738 (three rules of work for a wide
  record through calls). It ran about 12 950 new programs and found no verdict
  that the change alters. One doubt needed code: each call that writes two
  locations cleared the index of kept reads, also a call that has none. Only a
  call with an index clears it now.
- Measured a second doubt of that review. A walk that holds more items than
  the units it counted stops its module, and the PR counts fewer units. Over
  all 2 950 ownership roots the least margin is 2.6, in a module whose units
  the PR does not move; the PR's wide shapes have more than 4.
- CI of #2738 failed three times on compiler guards of 10 s, each time another
  subset, and passed the fourth time. I timed each program that failed with
  the safe compiler of the base and of the PR. They are equal, at 37 to 46 %
  of the guard on this machine (#2737).
- Opened PR #2739, which removes the bound of 64 rounds of a recursive group
  (#2513). Its adversarial review broke it. I marked it not to merge and now
  recommend to keep the bound. This entry corrects my entry of 01:34 on that
  branch, which says that the budget is a good bound for the rounds.
- Added the test that was not there: a group that does not settle is a limit
  of the group, not of its module.

**What I learned**

- The bound of 64 rounds and the budget of a declaration both end a group that
  does not settle, but they do not stop the same things. The bound stops the
  group, and the module goes on. A declaration past its budget stops its whole
  module: no other declaration is walked and no contract is published. With
  the bound gone, a library with one function over 300 lists that nobody calls
  lost the contracts of its other functions, and an app that the base accepts
  was refused.
- My evidence did not see it, and each part looked complete: the dumps of
  2 949 roots were equal, the oracle had no fault, the gates were green. No
  root has such a group, and each test of mine called only members of the
  group. A test of a limit needs a neighbour that the limit must not touch.
- I had the hint and did not read it. A mutation that kept the contracts of an
  unsettled round changed no test. I wrote that the rule "holds twice". The
  second place was the stop of the module, and I did not ask what else it
  stops.
- The live twins of my first rotation sweep read a list that no run writes.
  "0 faults" of an oracle is a claim only where a fault can happen. The
  advisor review found it; I had changed the read for one variant and broken
  the other.
- An answer on the dashboard came five hours before I read it, and its label
  and its text disagreed. I asked once and built the reading of the text as a
  draft. The review then gave the reason for the label.
