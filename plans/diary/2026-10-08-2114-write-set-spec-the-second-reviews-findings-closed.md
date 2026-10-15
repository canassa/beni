## 2026-10-08 21:14 CEST — Write-set spec: the second review's findings closed

**What I did**
- Amended `docs/design/write-sets.md` for the second review of PR #18 (branch
  `write-sets-spec`, not pushed). N1: a keyed `Alt` has one alternative per arm carrying the
  arm's whole pattern, and selection keeps every alternative not contradicted by a full match
  against the known shape, aligned with §3.2's `Con`-scrutinee rule and proved in §5.2. N3:
  every split of the key tree gets a default child for the constructors no arm names, folded
  into the L-cap join, so §9.2's "an unknown tag is a defect" is true. N2: a `kept` list's
  element result is diffed against the callback's root εⱼ as the placement root and rewritten
  to `p[κ]`, for that root only, so `Toggle` is `node ρ.todos[*]; value …completed` and `Fill`
  stays `value`. N4: baking narrowed to plain, non-empty, escape-free strings standing alone in
  their text position, not in `pre`/`textarea`. N5: index symbols in summaries are terms over
  the callee's roots, substituted by `inst`, equal only as instantiated terms. N6: W counts node
  visits only; joins and interning priced; the W fixture runs under a hidden test-only
  `--writes-work`. N7: §3.4 gained a full-record row (`node p` plus its fields) and golden 7
  matches it. Four fixtures added to §8.3. Gates green (docs only).

**What I learned**
- "Select the one alternative that holds" is only right when the shape decides every step of
  every pattern; a refutable sub-pattern against an undecided part leaves several arms live,
  and the fix is to drop only what a full match refutes.
- A root that unifies with nothing (εⱼ, from the A5 fix) needs an explicit rebasing at the
  one place its position is known — the written slot of a `kept` list — or every map loses
  its field precision.
