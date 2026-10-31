## 2026-10-30 19:01 CET — own2: a callee's deep read crosses a call as D

**What I did**

- #1328. A callee's deep read (`str r = Debug.toString r.x`) was `R` at the
  argument's path only, so v2 accepted `viaHelper`'s push of a list that
  `g.x.a` held; v1 refuses it. Specified first (`ownership-v2.md` §2.10,
  *A deep read across a call*, with §2.7, §2.11 item 3, §2.13.6, §3.5, §3.6):
  a deep read has its own mark, `D`, in a node with `R`. `W` never takes it.
  The spec says what `marksAt`, liveness, the callsite demands, the print
  and the block read for it. The block version is 13.
- Built it: `Cell.Mark.deep_read`, the graft in `Walk.readOff` writes
  `{R, D}` where the callee has a leaf of marks or a `D`, the holder index's
  cursor is free below a `D`, `marksAt`/`usedAt` see it, and the print shows
  it as `R` (v1's spelling). No `Transfer` change.
- Fixtures `ownership/DeepReadAcrossCall` and `DeepReadAcrossCallImported`:
  `viaHelper`, two helper levels, a deep read beside a write at a sibling
  path, a whole recursive value, and a shallow write beside a deep read that
  stays accepted. Each refusal fails on master's `src/`.
- Dumped v2 over the whole ownership and run corpus and core with master's
  and this branch's binary: no verdict and no printed summary changed outside
  the two new fixtures. A build that printed `D` shows it at 148 parameter
  paths in 122 summaries; 39 have a `W` beside it that stays `W`, and the 2
  with `S` (core's `update`) print the same on master. `deepGeneric` is
  `π1 RDAW`, so `CastCallHolds` 25:9 stays accepted.
- Opened #1345: a deep read at a path on a cycle of the place graph misses
  holds folded into `⟲` (`r.kids` against `r⟲.v`), inline as well; it is on
  master and independent of `D`.

**What I learned**

- `Summary.zig` sits at its §5 line target (1 680): the change fitted only
  after the print shared `R`'s switch arm.
- The first `zig build gates` in a fresh worktree took 2 min 16 s.
