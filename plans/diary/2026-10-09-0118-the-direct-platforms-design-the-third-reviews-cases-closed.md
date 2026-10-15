## 2026-10-09 01:18 CEST — The direct platform's design: the third review's cases closed

**What I did**
- Revised `docs/design/browser-direct.md` for the third review of PR #24. The one wrong page
  the N3 fix had introduced — an arm's derived list recomputed after the `For` that reads it —
  is closed by making step 3 per arm, outermost first: derived values, nested branches, edit
  scripts, groups, each arm as a whole under its liveness; the old flat step 4 is folded in and
  `LetInArm` gains a `let` feeding a nested `if` and a `For each` with no arm switch. The verify
  mode compares a derived value structurally (lists per element, records field by field) and
  skips every value that reaches `Debug` transitively, with `VerifyQuiet` covering a list-valued
  `let` and a helper that logs. The nested-list walk runs its buffer before a `stopPropagation`
  stops it (`StopInRow` asserts the stopper's own message), and `$r.list` is the list's per-mount
  identity. The reset sentinel is a module-level `unset = {}`, not `undefined`, which `⊤` is in
  release; §10.2 agrees with §4.3 that after-render sends apply in the same dispatch; a queued
  `e.target.value` read is stated beside `EventReadsModel`; §16 names the always-sends hang as
  the program's, as today; §5.2's size gate has a numeric default (24 B per call site, minified
  bytes).
- Gates green (docs only).

**What I learned**
- "Structure, then values" is the wrong axis once values can be structure's inputs; the right
  unit is the arm, and inside it derived values come first because everything else may read
  them.
- An oracle that recomputes derived values must compare the way the readers do — by what they
  can see — or it reports the recomputation itself as a defect.
