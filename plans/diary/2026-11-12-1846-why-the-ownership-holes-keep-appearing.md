## 2026-11-12 18:46 CET — Why the ownership holes keep appearing (report 116)

**What I did**

- Read reports 110 to 115, the three fault folders and the generators of `bench/ownership-sweeps/`, the v2 and
  v1 designs' relevant sections, the requirements, the v2 and v1 issues, and all of `src/own3/` at
  `4bd9066196`. Wrote `docs/design/research/116-ownership-why-holes-keep-appearing.md` on branch
  `ownership-v2-design-review` (PR #2451).
- Ran, on a ReleaseSafe compiler of the branch head: the three fault folders under v3 (113 and 114 closed, 115's
  five programs still trap); four cross-module probes under v1, v2 and v3 (all three refuse all three live
  programs and accept the dead twin); `core/` under v3 (no failed walk, no refusal). Measured v1, v2 and v3 on
  the 32 real roots with a ReleaseFast compiler (§8.4 of the report).
- Verdict: one root cause across v1, v2 and v3 — the holder side of a verdict ("nobody else observes the old
  value") is computed by enumeration over a value model with "don't know" states that read as "holds nothing";
  report 110's permissions fixed the writer side only and §6.8 named this residue. v3's idea holds for what it
  claimed (names, permissions, routes) and is not a dead end; going back to v1 or v2 keeps the same shape at a
  larger size. The path: a normative text for the holder side with five concrete forms (named fresh cells; "no
  claim" and "no cell" as two values with a reason; `twice` by default on summary locations; one clock; no fact
  by a name) and exhaustive switches, landed as one slice before any further hole-by-hole fix, then two fresh
  readers as the convergence test, then the Lean model of the first-order kernel.

**What I learned**

- A generator written by the fixer has found nothing four rounds in a row (49 743, 9 792, 1 202, 417
  programs); a reader of the code who did not write it finds two or three classes a day, at a flat rate. The
  review of the last fix is the main detector for v3, as report 110 §3.7 said of v2.
- v3's permissive states are enumerable: 14 `return v_shared` sites, a nameless `Src.fresh`, a bare
  `Src.shared` supply, four by-name rules, two silent depth limits on the permissive side. v2's was one
  function (`Forest.kidAt`). The shape is the same; the size is a tenth.
- v1 refuses two of 115's classes by principle (`fresh_k` names, a walk-order clock) and one by coarseness;
  v2 refuses three by principle. Each principle is one of the five forms.
- `run.mjs` reads the `LIST` names relative to the current directory, not the directory given; run it from
  the sweep's directory. `exposing (T(..))` is refused: list the constructors.
