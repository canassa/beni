## 2026-11-23 17:01 CET — rebase the lent finaliser fix on master

**What I did**

- Rebased #2434 on `origin/master` `f84cdd28cc`. Every conflict was in a generated file.
- Took master's side of the seven `dedicated/` emit goldens, then wrote them again from the rebased code (`BENI_WRITE_EXPECTED=1 -Dcorpus=dedicated`). Only the worker fingerprints changed, as in the PR before.
- Wrote `tests/corpus/ownership/core.v2.unchecked` by hand: master moved `Task.beni` by 2 lines and the PR by 13 lines. The gates confirmed the numbers.
- `zig build gates -j2` through heavy-run: green in 12 minutes.

**What I learned**

- A blessing run with `-Dcorpus=` reports the step as failed when it writes a golden. Read `git status`, not the exit line.
- `core.v2.unchecked` is blessed only by an unfiltered ownership walk, so a hand merge plus the gates is the fast way.
