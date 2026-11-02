## 2026-11-02 22:56 CET — own2: loans across fibers

**What I did**

- #1734, branch `own2-fiber-loans` on `own2-ref-loans`. Wrote 45 adversarial probes in which one fiber holds a loan
  of a cell's contents (or a captured list) across a suspension while another fiber edits the contents in place.
  The shapes are `spawn`, `spawnIn`, `scope`, `bracket`, `forever`, `par`, `parOk`, `race`, `raceAll`, `raceOk`,
  `timeout`, `Semaphore.withPermit`, a `Deferred` hand-off, nested cells, a record of closures, a helper that
  spawns, an edit through a callee and through `store r g = Ref.update r g`. Each was run plain and under
  `--ownership=v2 --sanitize-lists`. **No probe traps.** Every unsafe probe is refused, and the safe controls
  accepted by v2 print the same.
- Found why. v2 has no suspension rule, and two other rules keep it sound. (1) An escape reaches through a cell's
  `◆`: the spawn's escape of its closure, or a helper's `escapes π1ε*`, covers the contents of each cell reached,
  so the spawning frame's later edit in place is refused `escaped`. (2) An in-place edit of captured contents makes
  the closure `once`, refused where a fiber starter takes it.
- Showed that each rule is needed with an experiment binary (not committed). With the escape stopped at a cell
  callback's supply, the helper-spawns-a-reader probes trap. With the edit exempt from `once`, the
  `par`/`parOk`/`race`/`raceOk`/`timeout`/`spawnIn`/record-of-closures probes trap.
- Pinned both with `run/SanitiserFiberReader` and `run/SanitiserFiberBranch`
  (`.sanitize-lists-v2-refuses`), plus the accepted twin `run/SanitiserFiberReplace`. Each fails the harness under
  its experiment. Amended §2.13.7 and §2.11.4 in place.
- Opened #1736: `Task.join` escapes `⊤`, so after a join the frame edits nothing in place.

**What I learned**

- §2.13.7's "reach and Esc stop at ◆" is not what v2 builds for escapes, and v2 is sound because of that. Building
  that sentence without the suspension rule opens a stale read across fibers. The spec now says so.
- `Node.print` builds a `Program`, so a fiber cannot print with it. A fixture's fibers report through an output
  `Ref String`.
- The refuses-file harness checks v1/v2 parity first. A fixture that is accepted again fails on
  `OwnershipV2Differs` before its sanitised run, and the probe runner shows the stale read.
