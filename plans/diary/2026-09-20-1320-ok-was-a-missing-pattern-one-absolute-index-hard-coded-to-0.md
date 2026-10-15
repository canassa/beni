## 2026-09-20 13:20 CEST — `Ok ()` was a missing pattern: one absolute index hard-coded to 0

**What I did**

The owner un-parked one fix — queue row 56, found during the browser synthesis — with the instruction
"red black box test before". One Opus implementer in a worktree; I validated and committed (`b160152`).

- The defect: `case m of Just () -> …; Nothing -> …` was rejected with MISSING PATTERNS `Just ()`, and
  the mirror image — `Just ()` then `Just _` — was NOT reported redundant.
- Root cause, `src/check/Exhaustive.zig`: a `Ctor`'s `alt` is an absolute index into `pats.alts`. Every
  arm computes it as `unionAt(un).alts_start + k`; `.pat_unit` alone wrote the literal `0`. That is
  right only when the unit union is the first one interned — a bare `()` or a top-level tuple — and
  wrong under any constructor, list or parameter pattern, where `0` names an alternative of `Maybe`.
  One arm changed; the `Flat` fast path never read it. `checker.md` §6.6 gained one sentence.
- Fixtures written and seen RED before any `src/` change: `run/UnitSubPattern` (18 printed lines —
  `Just ()`, `Ok ()`, unit in tuples, multi-field constructors, nested twice, lists, irrefutable
  parameter / `let` / lambda positions, a lookup table for the fast path) and
  `check/bad/RedundantPatternUnitArg`; `check/bad/MissingPatternsUnitArg` guards over-correction.
- My validation: reversed the `src` patch in the worktree, rebuilt, ran `test-blackbox` — exactly
  those two fixtures fail and nothing else; re-applied; three gates green; my original repro exits 0.

**What I learned**

- The bug hid for the whole life of the checker because the two obvious tests of `()` — a bare
  `case u of ()` and `( (), n )` — are precisely the two shapes where the wrong constant is right by
  luck. A fixture for a leaf pattern should always also put it UNDER something.
- It was found by a docs agent running `beni check` on a worked example for a plan. Examples in
  specs, compiled, keep finding real defects (the 305 doc examples did the same); `dump --stage=ast`
  would not have — it only parses.
- A false rejection breaks no guarantee, which is why nothing screamed; but `Result e ()` is the
  shape of every effect that can fail, so it would have been the first thing anyone hit in effects
  or browser work.
