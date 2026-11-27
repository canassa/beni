## 2026-11-27 23:52 CET — v3: a unit is work that the walk did

**What I did**

- Measured the three open limit issues with every budget lifted, by the caller
  of the counter.
  - #2535 (a record of 250 fields through 10 calls of a function that writes
    each field): the walk of the caller needs 38.0 million units and earns 2.19
    million. 24.0 are the pairs of a written location and another location of
    the operand, 4.0 the copies of the kept reads, 1.3 the scans of every
    location, 6.7 the tests of the runs of a record that are all old names,
    0.86 the two steps of each pair of a write and a later read.
  - #2534 (a record of n lists pushed by one update): judged up to 229 fields.
  - #2513 (a rotation of an n-tuple): the group "did not settle" from 66
    positions on. With the bound of 64 rounds lifted it is judged up to 200 and
    reaches its budget at 400. That bound is the owner's decision (question
    `own3-speed-q2`).
- Built three rules of work for #2535 (kernel §8, each with a check of a safe
  build in §9). A call that writes 4 locations or more keeps an index of its
  kept reads by root and entry, and a write passes only the kept reads that it
  marked and the locations with no kept read. The runs of a root that are all
  old names are one step. A later read that its root's facts settle is no step.
- Result with a ReleaseFast build: the shape of #2535 is judged (1.4 million
  units), up to 400 fields through 10 calls. The record of lists is judged up
  to 500 fields. The constructor loops of #2567 are judged at 18 and 20
  constructors too. The 33 real roots take 2 076 ms where they took 2 082 ms.
- Checked rule 1 of the brief directly: a base with every budget lifted gives
  the same dump as the change for each of the 2 943 roots with no limit, and
  for each of 60 generated programs that the base stops on.
- Ran 13 mutations, one for each condition of the three rules. Four passed
  the 910 programs. Three have a test now: a write with two entries of one
  root, a location that the callee only answers and that a later write is,
  and a later read of a function parameter's answer. For the fourth (the
  highest time of a root's runs in place of the lowest) I found no program:
  in each of 678 decisions of the one-step rule the two are equal.

**What I learned**

- My first version looked up each atom of a kept read and charged one unit.
  The dumps were right and the limit moved, and it was still wrong: a walk at
  its limit took 30 % more time for the same units. The advisor review found
  it. A unit that is not work moves the limit and breaks what the limit is for.
  The test for it is cheap: time a program that is at its limit with both
  compilers.
- The fix was to turn the test around. A write looks up its own atoms once in
  an index of the kept reads. Then a kept read that the write did not mark
  costs nothing, because nothing is done for it.
- "Never more units than before" has to hold at each point of the walk, not
  only for a whole write. My second version passed the marked kept reads in
  the order of the marks. A refused write then did work before the location
  that refuses it which the scan never did. The few locations are now passed
  in the order of the operand's map, and their count has a cap.
- A program at its limit with both compilers can show another count of pending
  demands. The walk stops at another point. That is not a verdict.
- I restarted a three-hour evidence job four times in one evening: the design
  changed twice after it started, and the base moved once. The cheap probes (a
  Debug build with the counter, a dump of ten shapes) belong before the long
  job, and the advisor call belongs before both.
