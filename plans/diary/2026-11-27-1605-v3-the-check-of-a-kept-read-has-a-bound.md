## 2026-11-27 16:05 CET — v3: the check of a kept read has a bound

**What I did**

- Worker `own3-speed`, issue #2567, PR #2728, after its adversarial review. The reviewer found no verdict
  that the change alters and no unsound write, in about 9 700 generated programs with byte-equal dumps
  (base, change, safe build) and 332 programs that go from LIMIT to a verdict under the four-leg oracle.
  It reported three things.
- The safe build's check of a kept read (`checkOtherLeaves`) was outside every budget. It read the
  location again at each copy and compared the two runs in pairs. A synthetic record of 53 fields of 940
  lists took 3.5 s with the fast build and 141.8 s with the safe build. A record of 500 lists that the
  base stops on took 0.2 s and 9 s: the check did the walks that the base's budget refuses. Fix: the
  check reads again at the first 256 copies of a call, compares small runs in pairs and large runs in
  one pass over each. The two programs now take 7.3 s and 0.2 s with a ReleaseSafe LLVM build.
- The kernel's example was wrong: a loop over 13 constructors still ends in a limit. A group of `n`
  constructors takes `n` rounds where `n` is even and `2n` where it is odd. With the change the loop is
  judged at 11, 12, 14 and 16 and passes its budget at 13, 15 and from 17 on. On the base it was judged
  up to 10 and at 12. The kernel text and the comment of `constructor-loops.mjs` say that now. My first
  diary entry of this issue says "judged at n = 12 and passed the budget at n = 13" for the base; the
  base also passes it at 11.
- A copy now costs 1 unit and 1 for each atom and never more than the first read cost (`OtherHit.units`).
  The reviewer read one shape where a walk can yield more than 31 atoms for the 32 units of one step,
  and built no program for it. With the cap, no walk costs more units with the change than on the base.
- Not changed: a walk that ends at the same limit on the base and with the change takes up to 28 ms
  longer to get there (+22 % at most in the reviewer's numbers). A unit of a copy takes more time than a
  unit of a walk. The pull request says it.

**What I learned**

- A check that counts no work needs a bound of its own. I wrote "a safe build reads again at each copy"
  and did not ask what that costs where the change turns a limit into a verdict: there the check does,
  outside the budget, the work that the base refused to do. Each other check of kernel §9 says "for
  layouts of at most 64 entries" or the like, and that is why.
- My first fix made the check slower for small runs. One pass over each run needs a table, and a table
  for a run of one atom costs more than the one comparison. Small runs in pairs, large runs by a table.
- "13 constructors" in the kernel came from the base's first limit that I saw, not from a table of
  sizes. The reviewer ran each size from 9 to 42. One row for each size finds the odd sizes in a
  minute.
