## 2026-10-14 16:03 CEST — Harden ownership calls, audit and search evidence

**What I did**

Added explicit call-shape premises to the two summary statements and a concrete
wrong-split regression. Rejected nested executable audit syntax before
elaboration and checked every recursor against the kernel-regenerated metadata.
Validated CLI options, preserved failures and supplied Node/taskset in ownership.
Extended supported capture/count/consume/join generation and added all 144
targeted programs to CI. Completed the 65-unique-edit sweep on three seeds with
every Linux descendant pinned to CPUs 0–7: 50 caught, 12 argued equivalent or
masked, three documented search gaps. Retained logs, verdict deltas and ASTs;
updated the proof and coverage limits. Preparing the final committed-head checks
and another review request on PR #65; no merge.

**What I learned**

Naming from a proposed argument/capture split can conceal a false summary
statement; derive it from the declaration and check lengths independently.
Lean regenerates nested auxiliary recursors in the kernel even when its
higher-level replay metadata omits them, so compare complete kernel recursor
values rather than exempting declarations by name. Captured function values in
supported shapes reach the missed rules without broadening higher-order limits.
The main theorem still depends on the unproved step lemma alone.
