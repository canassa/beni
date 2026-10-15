## 2026-09-24 15:00 CEST — the checker is rewritten from the ground up; R0 lands its red fixtures

**What I did**

- Started on queue row 75 and stopped it: the owner asked how sound the checker was, and five
  read-only reviews at `7427828` (inference core, static dispatch, orchestration, adversarial
  black-box, and a study of Roc's Zig checker, now checked out under `references/roc` with the
  other uninitialised submodules) found about 30 confirmed defects. Half of them are programs
  that check and then misbehave, several in plain Elm code: mutual recursion typed against the
  last member's locals table (since M2b), an annotated `let` whose rigid variables escape, any
  warning switching off exhaustiveness, `f n = if n == 0 then True else f (n - 1)` failing to
  build, the record-alias constructor building a tagged object. The row 75 partial work was
  discarded (`master` reset; the patch stayed in that session's scratch only).
- The owner ordered a ground-up rewrite. A planner wrote `plans/checker-findings.md` (CK-01 …
  CK-77, each with program, observed output, cause, class K1–K15, fixture and slice),
  `docs/design/checker-v2.md` (normative architecture, invariants I1–I16, decisions D1–D14) and
  `plans/checker-rewrite.md` (slices R0–R15). Four design-review rounds each found real holes
  (a walk that made every receiver cyclic, order-dependence in four different mechanisms, a
  fixpoint that did not terminate); all are resolved in the text, round 4 cleared R4a–R8a.
  Pointer notes went into `checker.md`, `static-dispatch-spike.md` and `language.md`; nothing
  renumbered. Queue rows 78 (the rewrite) and 79 (`beni dump` writes at offset 0) added.
- Decisions: the owner took the planner's recommendations (D1–D13); I took D14 under that
  standing instruction and flagged it (a recursive group's ambiguous receiver is refused in both
  orders; an annotation lifts it). CK-71 → R1, CK-75 → R8a. Added R15, a structural audit.
- R0 landed: `tests/pending/` (73 red fixtures, each with a `-- CK-NN` line and a recorded red
  signature in `RED`), 9 timed scenarios, `zig build test-pending`, and 15 regression guards in
  `tests/corpus/` that v1 already passes. A read-only review found no blocker and seven
  should-fixes (loose `.codes`, a CK-42 scenario that could never go green, custom `eq`s that
  behaved structurally), all fixed. Gates: 468/468 unit, 289/289 black-box, fmt-check green;
  `test-pending` 82 RED, 0 GREEN.

**What I learned**

- A green suite and a sound checker were far apart: the corpus exercised features, not
  ordinary program shapes. The adversarial reviewer found a build failure on four-line
  recursion in minutes.
- Every design-review round found blocking holes in the previous round's fixes. The fixes that
  held were the ones that deleted machinery (nesting at demand replaced parking, pinning and
  prefix closures); the ones that added a mechanism each needed another round.
- Black-box fixtures cannot see structure. Two checkers can pass the same corpus while one
  counts evidence once and the other in twelve places that happen to agree; that is why R15
  exists.
