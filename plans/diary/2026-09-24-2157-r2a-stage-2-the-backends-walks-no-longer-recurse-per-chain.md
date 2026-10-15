## 2026-09-24 — R2a stage 2: the backend's walks no longer recurse per chain link (CK-81)

**What I did**

- CK-81 closed: a derived `eq` over a 60 000-field record payload segfaulted the printer, which
  recursed once per `&&` (and once per cell of a long list literal). `js/Print.zig` recurses for
  256 levels and then switches to an explicit work stack; the release walkers in `Opt` and
  `Rename` use an explicit stack (`JsIr.pushOperands`); `Rename.verify` is linear. All three
  switches list every node tag, and a seeded test prints 400 random declarations through both
  printer paths at several switch-over depths and compares bytes.
- Past 4 096 evidence parameters a derived function takes one array (`static-dispatch-spike.md`
  §9.2, A.87): V8 threw `RangeError` at a 60 002-argument call and refuses functions over 65 535
  parameters. The threshold is the backend's own constant; R2b's `Convention` will own the choice.
- Every `run/`, `emit/` and `emit/release/` golden unchanged; the reviewer compared 179 fixtures
  in four build modes. Emit time unchanged.
- New findings: CK-82 (65 536+ fields: a Debug panic, a false refusal in ReleaseFast) → R8a with
  CK-79, which I moved there from R2a because D4 already changes the derived signature; CK-83
  (accepted programs whose JavaScript nests past Node's parser: ~1 700-element lists, long `++`
  chains, ~2 000 nested calls) → a new backend slice R2c.
- Owner-approved: `CLAUDE.md` now says cache entry v3 since R2a; an earlier session's 2.6 GB
  scratch was deleted (`/tmp` had filled to 98 % with review worktrees).
- Gates green; `test-pending` 77 RED, 0 GREEN.

**What I learned**

- Fixing a crash at one layer moved the limit to the next: the printer fix exposed V8's argument
  limit, which exposed the checker's `u16` count. Probe the new extreme end to end each time.
- Two implementations of one function stay equal only if the compiler forces it: an `else`
  branch would have hidden a new node kind in exactly the programs the corpus never builds.
