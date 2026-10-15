## 2026-10-15 11:44 CEST — Prepare the authorized nullary method merge

**What I did**

The owner authorized merging PR #126. GitHub refused the first attempt because
master had advanced with the ownership result-liveness fixes. Merged master
into the feature branch and resolved the sole conflict in ownership-checker.md
by keeping both the nullary-method invariant and the new result-liveness
section. No nullary implementation or fixture changed. Ran `zorg build test
test-blackbox fmt-check beni-fmt-check` on the combined branch: 1,302 passed,
15 skipped, and only the two known macOS case-folding failures. The complete
corpus, unit tests and both formatting checks pass. The branch is ready for
its refreshed CI checks and the authorized merge.

**What I learned**

The ownership result-liveness corrections compose with the checked-BIR nullary
rewrite: the copy result remains fresh, the plain field path remains shared,
and the existing ownership golden needs no update. The outstanding hardware
instruction-count gate remains an x86-64 Linux validation, unavailable on
this macOS host.
