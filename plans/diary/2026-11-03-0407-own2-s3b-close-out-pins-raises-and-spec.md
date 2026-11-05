## 2026-11-03 04:07 CET — own2 S3b close-out: pins, raises and spec

**What I did**

- On `own2-s3b-closeout` (from `own2-cost-resolve` `03136bfe8`), tests, fixtures and the spec only.
- Wrote the four pins that went with the shape domain's unit tests. Three are counted build_test tests:
  #1146's chain of knots through calls (4…1 024), a 400-call chain read at its end (100 and 400), and
  #1225's callee write paths (32…256). The fourth is a corpus fixture: `ownership/SlotJoinSharedRoutesCall`
  and its imported twin, a join under two shared-owner routes read through a call. `ownership/DeepWrittenPathCall`
  pins the callee write paths' verdicts.
- Removed the `@ownership_summary_size` raises from CrossDepthKids(+Imported), LevelPositionsWide,
  StepLanesInGrowth and MutualWritersMutualTypes. Re-blessed the goldens and shifted 68 known entries by the
  removed lines (a script over the `git diff` hunks).
- Restated §8's S3b row (an *As built (slot domain)* note) and each debt row and questions 8 and 9 in slot terms.
- Built `origin/master` with `-Downership-full-cross-check`: both panics are on master too, so they are v1's
  #1307 and #1567. I posted the repro on both.

**What I learned**

- The three counted pins fail on the base, with the old bounds. The knot chain and the 400-call chain are
  quadratic in one demand: `Holders.Keys.close` gives each leaf a sorted run copied from its kids' runs, so a
  chain of n holders makes n²/2 items. The callee write path is linear, but at 256 steps the caller's read-off
  replays the callee's path step by step and takes growth, because the continuation is sized by the caller's
  source. All three are on #1714 with profiles.
- The 64 KiB stack half of the 400-call pin cannot be reached through the binary: the check thread always gets
  `Check.stack_size` (64 MiB). The spec note says this.
- `@ownership_summary_size` lines are not free to delete: the v1 goldens and the v2 known list are keyed by line,
  so a deletion moves every later entry of the module.
- The inline chain `x_k = if c then x_{k-1} else [ 1 ]` has a quadratic walk (demands linear). I noted it on #1714
  and did not pin it.
