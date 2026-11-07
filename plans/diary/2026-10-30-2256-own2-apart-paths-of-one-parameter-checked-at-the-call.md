## 2026-10-30 22:56 CET — own2: apart paths of one parameter, checked at the call (#1383)

**What I did.** #1382's review found a soundness regression: `rightLeft (Br t [] t)`, with `rightLeft t =
case t of Br l _ r → ( kids r, l )`, was accepted although the answered `l` holds the list `kids r` pushes in
place. The cause was #1383, already open on master for `Pair b b` and `callerT`. I fixed it in two commits
ahead of the B change (§2.11 item 3 rule (c), amended; `Transfer.keepBeside`), with `ApartPaths` and
`ApartPathsImported` covering `g`, `gRead`, `gDeep`, `callerT`, `b8`/`c8`, the two-routes variants and
distinct twins, every line at v1's verdict. Then I replayed the B commits on top. I also restored the
build test's folded `M` repeat with `k` at depths 1 and 2, below the first return.

**What I learned.**

- The callee's marks already publish both paths, the `W` at `q` and the `A`/`R` at `q′`. Its apartness is
  discharged by the call's walk of the paths beside the write, so no new atom was needed. The walk missed
  two readings of the actual:
  - a symbolic leaf's reach is its own cell, so `b` answered at `#Pair.0` did not hold the written
    `π1#Box.0`; now a held or deep value whose cell is above the base holds it;
  - a pattern-refined base (`ys` of `Br _ ys _`) was compared by cell identity; now its `unrefined`
    cell matches too.
- `( kidsBox r, l == l )` was a third hole of the same kind on master: a deep read (a leaf use or `D`)
  above the base.
- Imported `b8` was already accepted on master. Only the same-module one was refused, through `⟲`.
- No ownership fixture changed verdict from the fix alone on master.
- A worktree's commits hit `MERGE_RR.lock` while rerere was in use elsewhere; `-c rerere.enabled=false`
  avoids it.
