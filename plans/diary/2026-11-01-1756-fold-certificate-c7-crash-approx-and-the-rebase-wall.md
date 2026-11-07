## 2026-11-01 17:56 CET — fold certificate: C7's crash, approx refusals, and the rebase wall

**What I did**
- Found the cause of C7's drop panic on producers whose base returns a raw parameter (`wrapN`, `acc8`, `accL`, `accA`, `accR`, `sw3`). `certKid` read a class one step below by the built side of `a | Node …` alone. So (d3) held, and an item at `K` dropped `a`'s lists. The check was right. The premise now fails at a member that may hold an object below it and has no child there. The six are in `o/FoldCertificateRawBase`.
- Made a refusal by cells inside a knot's view that (d) does not read `disjoint (approx)`. The view starts an occurrence of its own (`Occ.fail` 3), so its items are other items. Off the spine, this is only for an uncertified knot. A wrapper (`o/FoldCertificateWrapper`) and rows 3, 10 and 11 changed. Row 10's expected verdict is amended in place. Certifying a wrapper needs spec: #1558.
- Rebased onto master and resolved the conflicts. Then I found that #1538's atom rule splits `same`'s knot, and the witnesses turn red. I did not push the rebase: #1559, a decision. The fixes are on the old base, gated there.
- Oracle sweep: 57 programs, 11 725 runs, 0 unsafe. Forced to accept, 26 programs are UNSAFE.

**What I learned**
- A mutated build replaces `zig-out/safe/bin/beni`. A probe run after a `-Downership-v2-mutation` build reads the mutant. I nearly reported a regression from that. Rebuild without the option first.
- `git apply -R --3way` stages its result. `git checkout -- src` then restores that staged state, not HEAD's. Use `git restore --source=HEAD --staged --worktree`.
- `perl -i` with `my @l = <>` closes ARGV before `print`, so the output goes to stdout and the file is emptied.
- The fold fixtures take 2 to 12 s per case in the safety build: #1560.
