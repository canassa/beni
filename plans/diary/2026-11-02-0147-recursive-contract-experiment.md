## 2026-11-02 01:47 CET — recursive contract experiment

**What I did**

- Built a scratch prototype of the astra review's alternative A on branch `exp-recursive-contracts`, behind
  the hidden `--ownership-contracts` flag. A recursive group's port is rebuilt every round from the result
  place's canonical slots. A non-duplication predicate over occurrence tokens is inferred and validated from
  the BIR. v2's own walk checks everything else.
- Ran the review's §7 test set: the probes, the imported caller, reversed declarations, the scaling families,
  and the sanitiser runs, plus a forced-unsafe control.
- Diffed every verdict line of the ownership corpus against master, for four variants.
- Summarised the result in `ownership-v2.md` §8, beside Q8.

**What I learned**

- The contract's inventory is fixed and it settles in 4 rounds.
- `removeMin`'s walk 2 is no cheaper than on master: the cost is the body's `case` joins over `balance`'s
  summary.
- Three defects of the prototype were each caught by a corpus control or a core summary:
  - per-slot fresh renaming;
  - a derived `yes` read through the instantiated cell set;
  - built nodes at type variables and at approximate cells.

  Each is a requirement for a design of this kind.
- The fold-certificate witnesses depend on `widen`'s fold classes, not just on the certificate bit.
