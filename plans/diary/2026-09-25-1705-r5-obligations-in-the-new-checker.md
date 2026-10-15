## 2026-09-25 — R5: obligations in the new checker

**What I did**

- v2 now checks every program without method dispatch: tuple index, interpolation, the
  `equatable` marker walk (growable, payload-descending per D10) and `?` as a deferred
  obligation with §8.1's default step. Decided spec-first where the rows live: `obls` is one new
  field of the shared `Flags` (a link into v2's `Obligations` table), `wants` stays
  `Flags.constraints`, so `Schemes.Writer` and `Render` are neither forked nor hooked. v1
  byte-identical over 1 888 comparisons.
- Claimed CK-05, 06, 16, 51, 68, CK-62's dispatch-free form, CK-09 with five members, CK-59's
  generation half; 33 claims in all. `test-v2` 593 passes; the 73 green `run/`/`emit/app/`
  programs emit identical JavaScript under both checkers.
- Two reviews again. Structural: the equatable walk flagged before it knew the answer, so one
  question could report twice, the count depending on symbol ids. Adversarial: three quadratic
  blowups (up to 33 s where v1 took 0.5 s) and one valid program rejected, a spec gap: a `?`
  pinned its whole target to the subject's rank, so a `let` helper lost its polymorphism. All
  fixed: one report per question; obligation sets as growable lists merged smaller-into-larger,
  owned rows kept apart from decided ones, a per-frame open-`?` list; I15 amended so ranks run
  from an obligation's owner to its dependants only. New CK-96–98 as `test-perf` scenarios (now
  1.12–1.90), CK-99 for the `?` case. `Solve.zig` split into `Solve` and `Decide`.
- Bench: v2 1.01–1.03× v1 on a 133 000-line corpus with obligations. All seven steps green.

**What I learned**

- The adversarial tester is worth its cost on every checker slice: again no unsoundness, but the
  performance cliffs it found (thirty seconds on eight thousand interpolations) are the kind a
  user meets first and a corpus never does.
- A rank-sharing rule written as "all variables of an obligation share one rank" is too strong;
  sharing must follow the direction of the decision.
