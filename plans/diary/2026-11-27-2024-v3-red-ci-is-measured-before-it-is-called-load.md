## 2026-11-27 20:24 CET — v3: red CI is measured before it is called load

**What I did**

- Ran the reviewer's differential again on the head of #2735 (`ebd0a51835`)
  with the head's ReleaseFast and ReleaseSafe compilers: 28 322 programs in 51
  sweeps. No dump differs where the base has no limit, no program has a limit
  only with the head, and the safe compiler stops on none of the 5 421 programs
  that it ran. 145 programs go from a limit to a verdict.
- Ran the two mutations of `entry_read` again on the head. Each stops the safe
  compiler on 5 of 5 programs.
- CI failed three times on 10 s compiler guards. I had called that the load of
  the runner. Then I measured it: I wrote the programs of the tests that time
  out to files and ran the gates' safe compiler of the base and of the head on
  them, in turn. They take the same time (0.6 to 4.9 s for each program).
- Merged the new base (`5be50778de`, with #2720) into the branch, and corrected
  one sentence of kernel §8: a location that comes after a location of another
  entry takes no kept run. The text had said that such locations are one after
  another.

**What I learned**

- "The runner is slow" is a claim about my change too, until a measurement
  says that the change is not slower. The sets of failed tests of my branch and
  of the review branch were nearly equal, but my branch had four tests more.
  Only the timing of those programs with the two compilers settled it.
- A first run of the reviewer's own sweeps gave 5 301 tool errors: their `LIST`
  files have paths relative to the reviewer's directory. A tally that shows a
  class of result that nobody expected is a finding about the run, not a row
  to leave out.
- These budget tests take 3 to 5 s of a 10 s guard on a fast machine (#2737).
