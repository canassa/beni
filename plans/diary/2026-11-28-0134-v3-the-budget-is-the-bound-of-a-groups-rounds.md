## 2026-11-28 01:34 CET — v3: the budget is the bound of a group's rounds

**What I did**

- Read the owner's answer to my question about #2513 five hours after it came.
  Its label says "Keep the bound of 64" and its text says "Remove the bound of
  64" with three conditions. I asked once which one is the decision, and built
  the pull request that the text describes, with a note at its top.
- Removed the bound of 64 rounds of `Check.solveGroup`. The rounds of a member
  already share its one step budget, and a member past it stops the rounds.
- Wrote the kernel text for the owner's second condition: each walk of a
  member counts against that member's budget and the module's, so the work of
  a group is at most the sum of its members' budgets.
- Measured with a ReleaseFast build. A rotation of 66 to 200 lists is judged
  where it was "the group did not settle". A group that never settles ends at
  the budget of a member after 94 to 298 ms (before: after 64 rounds, 56 to
  303 ms). The dumps of the 2 949 roots are byte-equal: no root has a group
  that takes more than 64 rounds.
- Added three tests and a sweep of 64 rotations (oracle: 0 faults, 24 programs
  from a limit to a verdict).

**What I learned**

- An answer on the dashboard has two parts, and they can disagree. I read
  only that there was no answer file line for hours, because I looked at the
  pull requests and not at the dashboard. Both belong in each status check.
- I tried to prove the owner's first condition with a mutation: keep the
  contracts of the last round of a group past its budget. No test saw it, also
  not one with an importing module. The rule holds twice: a module with a
  declaration past its budget walks no other declaration and publishes no
  contract. A test can hold the behaviour and still not hold one of the two
  places that give it. I said so in the pull request.
- A first run of the new tests with a filter printed nothing and exit 0. A
  build prints nothing when it passes, and a filter that matches nothing
  passes too. `--summary all` shows how many tests ran.
