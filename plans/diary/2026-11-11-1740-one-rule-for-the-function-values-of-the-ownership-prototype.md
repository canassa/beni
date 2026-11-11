## 2026-11-11 17:40 CET — One rule for the function values of the ownership prototype

**What I did.** Worker `ownership-v3-round2`. The owner asked for round 2 of the prototype of research
report 111 (`plans/ownership-v3-round2-prompt.md`): do function values converge under one rule, or do they
need a new case for each new shape? Research report 112 has the rule, the measurements and the verdict. The
function-value part of `src/own3/Frame.zig` is rebuilt around one operation, `flow`: a function value is
judged against the use of the location that it is in (a parameter of a callee, a capture of a known
function, or the default). A location that no contract describes has the default, which refuses a function
that writes its parameter. No file of `src/own/` or `src/own2/` changed. The gate holds: 0 traps,
differences and crashes on the 49 743 programs of the four sweeps, on 44 000 programs of report 111's
generators and on the 345 sanitiser fixtures; 299 of the 308 real writes; more than 500 000 lines per
second. Four generators are new in `bench/ownership-sweeps/`: `function-values.mjs` (1 960 programs, the
convergence test), `wider-functions.mjs` (354), `answers-beside.mjs` (240) and `aliased-arguments.mjs`
(3 870, a blind sweep for the corner where the hand search found faults). Two black-box tests are new,
and one changed.

**What I learned.**

- Each of the 153 traps had one cause: a known function reached a consumer by a way on which the walk
  dropped its code, and a fact that was not recorded was read as "nothing happens". The fix is a default, not
  a case: a consumer that no contract describes is the `top` use.
- A rule that has an invariant gives a list to check. "A known function becomes a default value only through
  `flow` to `top`" gave seven probes before any generator ran, and each one trapped on the old prototype: a
  function in an arm of a `case`, a `case` as callee, a local function that is called before it is bound, a
  local function that hands itself on, a closure that puts a captured list into a cell, and one answer at
  two elements of a list.
- A parameter of a function type needs a contract also when the body does nothing with it. The rounds of a
  recursive group start from "does nothing with it". If they start from "no contract", the first round reads
  the function as lost, and lost does not go away, because contracts only grow.
- A new family that passes is not the end. The family of 1 960 programs found no fault in its one run, and
  the old prototype traps on 371 of them. Then 97 programs written by hand, in five rounds, found three
  faults (15 programs trap). The family has flat lists, no result with two parts and no call with one list at
  two arguments. Vary the types and the arguments in a family, not only the shapes.
- The call map goes from the wider type to the narrower one. A known function and its holder are two readings
  of one type, and either can be the wider one. A wide location of one reading holds each cell of the other
  reading's locations at or below its place.
- A claim of a contract that two sources of its result are two cells rests on things that the callee cannot
  know: the answers of the functions that it was handed, and its arguments. `keep2 ( q, q )` answers one list
  at two places with no function value at all, and report 111's prototype accepted the write. The caller
  must check both.
- I fixed that fault with a case two times, and each time the next round of probes found a form that the
  case did not cover. The third fix states the claim one time: for each pair of sources of a result, the
  caller reads what the two are in its own frame. When a second fix of one corner is again a case, stop and
  write the claim that the two cases are instances of.
- A check of pairs cannot see one source that stands for many values. `[ f x, f y ]` has one answer source,
  and with one list as `x` and `y` it has that list at two elements.
- After the last fix of a corner, write a generator for the corner and run it one time before the report
  says anything about the corner. The blind sweep of 3 870 programs found no fault in the final code, and the
  two earlier prototypes trap on 146 of its programs. Without it the verdict for that corner was "unclear".
- A fix for soundness can cost precision in a corner that the fix was not about. The check of pairs costs 84
  safe programs of `recursive-levels.mjs`, a first-order sweep. Compare each program's verdict with the run
  before, not only the count of traps.
- A speed figure that is measured while two sweeps run on the same machine is not a figure. Measure the
  speed on a quiet machine, or say that it was not.
- A more exact reading can open a hole. The old prototype read the answer of a captured function as "no
  claim", and that refused a program. The rebuild reads that answer exactly, and the same program was
  accepted, because the bit above was still trusted. Each place that gets more exact needs a look at each
  fact that rested on the coarse form.
- A reviewer's question is worth a probe. The review asked if two parts of one wide value are always apart.
  The first probe for it trapped, and the next one was the first-order form of the same fault.
- A fix that is too strict shows on real code at once. The first version of the check of that bit cost one
  of the 299 real writes (`Tea.tableFoldl`). Measure the 32 roots after each fix.
- A refusal can be right for the wrong cause. One probe was refused as `disjoint` while the checker had lost
  the innermost lists of an answer. A variant with a pattern in place of `List.update` trapped. Read the cause
  of a refusal, not only the verdict.
- Do not change a shell script while a job runs it. The running shell reads the file again at the next
  command, and the job ended with a parse error.
- A force push and a kill of a job are denied in this session. A local branch that holds the pull request's
  head merged with `master` and a small worktree for the pull request's branch give fast-forward pushes of a
  tree that is the tested one (`git merge-tree --write-tree` gives the same hash).
